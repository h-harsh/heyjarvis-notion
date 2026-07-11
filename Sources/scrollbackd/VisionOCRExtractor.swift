import Foundation
import CoreGraphics
import ScreenCaptureKit
import Vision
import os
import ScrollbackCore

/// OCR fallback provider: screenshots the frontmost window via ScreenCaptureKit
/// and runs Apple Vision text recognition, entirely on-device. Invoked only when
/// Accessibility yields too little text for an AX-opaque surface — the routing
/// decision lives in `LayeredTextSnapshotProvider` + `OCRFallbackPolicy`.
///
/// Privacy invariants (PRD launch gate — "zero frames stored by default"):
///   - The captured `CGImage` feeds Vision and NOTHING else: never written to
///     disk, never handed to a sink, never cached. It drops out of scope the
///     instant recognition returns. Only recognized *text* leaves this type.
///   - Requires the Screen Recording TCC grant. Without it, `snapshot` returns
///     nil and capture degrades cleanly to AX-only — never a crash, never a block.
///   - Links NO networking (Never rule #1): Vision + ScreenCaptureKit are wholly
///     on-device. verify check #5 greps this target for egress symbols.
///
/// Secure-field caveat: unlike the AX walker, a whole-window screenshot has no
/// field-level secure-field guard. `LayeredTextSnapshotProvider` suppresses OCR
/// when AX reported a secure field in the window (via `CapturedText.containedSecureField`),
/// which covers the common credential-window case. The residual gap — an
/// all-canvas login whose AX is entirely empty, and `ocrOnly` apps (no AX probe)
/// — is closed by the app-level default-exclusions task (next), not here.
///
/// Concurrency: ScreenCaptureKit's screenshot APIs are async and run off the main
/// actor. This provider is synchronous (the seam is sync so the engine stays
/// deterministic), so it bridges via a detached task + a bounded semaphore wait.
/// Deadlock-safe: the async work runs on a DETACHED task (never the blocked main
/// actor) and is time-bounded. The result is read ONLY on the signaled path (the
/// semaphore establishes happens-before there); a timeout returns nil without
/// touching the shared slot, so there is no race with the still-running task. At
/// most one capture runs at a time (`inFlight`) so a timed-out-but-still-running
/// screenshot can't be piled on by the next capture. If the M1 CPU/latency gate
/// shows stalls, the fix is to move OCR off the engine's synchronous path (the
/// seam itself would not change).
final class VisionOCRExtractor: TextSnapshotProvider {

    private let recognitionLevel: VNRequestTextRecognitionLevel
    private let captureTimeout: TimeInterval
    /// Point→pixel multiplier. `SCWindow.frame` is in points but
    /// `SCStreamConfiguration.width/height` are pixels; without this an 800pt
    /// window is captured at 800px on a 2× Retina display, halving OCR resolution
    /// and dropping small UI text. Default 2.0 = built-in Apple-Silicon Retina;
    /// deriving the exact per-display scale is a gate-run refinement.
    private let pixelScale: CGFloat
    /// OCR text is lossy vs AX; a fixed sub-1.0 confidence lets retrieval
    /// down-rank it relative to near-lossless AX text of the same content.
    private let ocrConfidence: Double

    /// At most one OCR capture in flight. Guards against a timed-out-but-still-
    /// running screenshot being overlapped by the next capture (wasted CPU vs the
    /// <5% gate). If a prior capture is stuck, OCR degrades to AX-only until it
    /// clears — a safe failure mode, never a deadlock.
    private let inFlight = OSAllocatedUnfairLock(initialState: false)

    init(
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate,
        captureTimeout: TimeInterval = 3.0,
        pixelScale: CGFloat = 2.0,
        ocrConfidence: Double = 0.7
    ) {
        self.recognitionLevel = recognitionLevel
        self.captureTimeout = captureTimeout
        self.pixelScale = pixelScale
        self.ocrConfidence = ocrConfidence
    }

    func snapshot(for context: FrontmostContext) -> CapturedText? {
        // Runtime suppressors (secure input active, NSWindowSharingNone). A
        // sharing-none window is excluded from ScreenCaptureKit anyway, but check
        // up front so we never even take the screenshot.
        guard !CaptureGuards.shouldSuppressCapture(pid: context.pid) else { return nil }
        // Cheap gate: if Screen Recording isn't granted, don't attempt anything.
        guard CGPreflightScreenCaptureAccess() else { return nil }
        guard let image = captureWindowImage(pid: context.pid, title: context.windowTitle) else { return nil }
        let observations = recognizeText(in: image)
        // `image` is now unreferenced and deallocates here — never persisted.
        let text = OCRTextAssembler.assemble(observations)
        return text.isEmpty ? nil : CapturedText(text: text, source: .ocr, confidence: ocrConfidence)
    }

    // MARK: - Screenshot (async → sync bridge)

    private func captureWindowImage(pid: pid_t, title: String?) -> CGImage? {
        // Serialize: skip (degrade to AX) if a prior capture is still running.
        let acquired = inFlight.withLock { busy -> Bool in
            if busy { return false }
            busy = true
            return true
        }
        guard acquired else { return nil }

        let semaphore = DispatchSemaphore(value: 0)
        let lock = inFlight // shares the same underlying storage; Sendable to capture
        let scale = pixelScale
        // Written by the detached task, read by us ONLY after wait == .success, so
        // the semaphore signal→wait edge orders the write before the read. On the
        // timeout branch we never read it, so there is no race with the late write.
        nonisolated(unsafe) var result: CGImage?
        let task = Task.detached(priority: .userInitiated) {
            defer {
                lock.withLock { $0 = false }
                semaphore.signal()
            }
            if Task.isCancelled { return }
            result = await Self.captureWindowImageAsync(pid: pid, title: title, scale: scale)
        }

        if semaphore.wait(timeout: .now() + captureTimeout) == .success {
            return result
        }
        task.cancel() // best-effort; frees the in-flight slot when it unwinds
        return nil
    }

    private static func captureWindowImageAsync(pid: pid_t, title: String?, scale: CGFloat) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true
            )
            guard let window = bestWindow(for: pid, title: title, in: content.windows) else { return nil }

            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(1, Int(window.frame.width * scale))   // points → pixels
            config.height = max(1, Int(window.frame.height * scale))
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true

            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            return nil // permission denied, window gone, or capture failure → AX-only
        }
    }

    /// The window to OCR: the on-screen window of `pid` whose title matches the
    /// AX-focused window (so the OCR'd pixels match what AX read and the episode
    /// is attributed to), falling back to the largest on-screen window when no
    /// title matches (some windows expose no title).
    private static func bestWindow(for pid: pid_t, title: String?, in windows: [SCWindow]) -> SCWindow? {
        let owned = windows.filter { $0.owningApplication?.processID == pid && $0.isOnScreen }
        if let title, !title.isEmpty, let match = owned.first(where: { $0.title == title }) {
            return match
        }
        return owned.max { ($0.frame.width * $0.frame.height) < ($1.frame.width * $1.frame.height) }
    }

    // MARK: - Vision (synchronous)

    private func recognizeText(in image: CGImage) -> [OCRObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        guard let results = request.results else { return [] }
        return results.compactMap { observation -> OCRObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox // normalized, bottom-left origin
            return OCRObservation(text: candidate.string, top: Double(box.maxY), left: Double(box.minX))
        }
    }
}

/// Entry point for `scrollbackd ocr-dump` — one-shot diagnostic of the OCR path,
/// the manual counterpart to `ax-dump` (both need a TCC grant, so neither runs in
/// CI). Screenshots the frontmost window, OCRs it, prints the text, discards the
/// image. Founder-machine verification of the ScreenCaptureKit + Vision path.
@MainActor
func runOCRDump() -> Int32 {
    guard CGPreflightScreenCaptureAccess() else {
        print("""
        Screen Recording permission not granted — OCR fallback is inactive.
        For development: grant your terminal app Screen Recording access
        (System Settings → Privacy & Security → Screen Recording), then re-run.
        Requesting it now (approve, then re-run):
        """)
        _ = CGRequestScreenCaptureAccess()
        return 3
    }
    let extractor = AXTextExtractor()
    guard let context = makeFrontmostContext(extractor: extractor) else {
        print("No frontmost application.")
        return 1
    }
    print("frontmost: \(context.appName) [\(context.bundleID)] — window: \(context.windowTitle ?? "<none>")")
    let ocr = VisionOCRExtractor()
    if let snapshot = ocr.snapshot(for: context) {
        let normalized = TextNormalizer.normalize(snapshot.text)
        print("OCR extracted \(normalized.count) chars (normalized, source=\(snapshot.source)); first 400:")
        print(String(normalized.prefix(400)))
        return 0
    } else {
        print("no OCR text (empty window, capture failed, or permission mid-revoke).")
        return 2
    }
}
