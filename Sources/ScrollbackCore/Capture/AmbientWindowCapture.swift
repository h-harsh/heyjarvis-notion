import Foundation

/// Outcome of a targeted AX read of a background (swept) window. `windowResolved` is
/// the load-bearing bit: ONLY a resolved (actually walked) window has been vetted for
/// a secure field, so ONLY a resolved window may be OCR-fallback'd. A nil `text` with
/// `windowResolved == false` means "couldn't even find this window" (untitled /
/// title-mismatch) — which must NOT be treated as "AX-opaque, go ahead and screenshot".
public struct AmbientAXReading: Sendable, Equatable {
    public let windowResolved: Bool
    public let containedSecureField: Bool
    public let text: CapturedText?

    public init(windowResolved: Bool, containedSecureField: Bool, text: CapturedText?) {
        self.windowResolved = windowResolved
        self.containedSecureField = containedSecureField
        self.text = text
    }

    /// The window couldn't be resolved — unvetted, never OCR it.
    public static let unresolved = AmbientAXReading(windowResolved: false, containedSecureField: false, text: nil)
}

/// Targeted AX read of a specific background window (live impl: AX-tree walk of the
/// window matching the target's title). Split behind a protocol so the layering logic
/// below is unit-tested headless — the live AX walk needs a TCC grant.
public protocol AmbientAXReader: AnyObject {
    func readWindow(_ target: AmbientWindowTarget) -> AmbientAXReading
}

/// Targeted OCR of a specific background window (live impl: screenshot by exact
/// windowID + Vision). Behind a protocol for the same reason.
public protocol AmbientOCRReader: AnyObject {
    func ocrWindow(_ target: AmbientWindowTarget) -> CapturedText?
}

/// The ambient (all-windows-sweep) analog of `LayeredTextSnapshotProvider`: composes a
/// targeted AX read + targeted OCR via the capability matrix. It preserves every
/// security rule of the focused layered provider on the WIDENED surface, and closes
/// the gaps an adversarial review found on the naive version:
///
///   1. A window we could not resolve/walk (`windowResolved == false`) was never
///      vetted for a secure field, so we NEVER OCR it — a nil AX read is "unknown",
///      not "AX-opaque, screenshot it". (This is the fix for the untitled/mismatched
///      login-window OCR bypass.)
///   2. A window where AX saw a secure field is never OCR'd (return the AX partial).
///   3. OCR is rationed by a per-sweep budget so a sweep can't fire many synchronous
///      screenshots and wedge the main run loop.
///
/// Pure logic + injectable readers ⇒ headless regression tests for all three.
public final class LayeredAmbientWindowProvider: AmbientWindowProvider {
    private let ax: AmbientAXReader
    private let ocr: AmbientOCRReader
    private let capabilities: AppCaptureCapabilities

    /// Per-sweep OCR budget. OCR is a synchronous screenshot that blocks the run loop
    /// up to the extractor's timeout; a sweep can select many AX-opaque windows, so we
    /// cap screenshots per sweep to bound the worst-case main-thread stall. AX-readable
    /// windows are unaffected (cheap) — only OCR-fallback screenshots are rationed.
    private let maxOCRPerSweep: Int
    private var ocrRemaining: Int

    public init(
        ax: AmbientAXReader,
        ocr: AmbientOCRReader,
        capabilities: AppCaptureCapabilities = AppCaptureCapabilities(),
        maxOCRPerSweep: Int = 4
    ) {
        self.ax = ax
        self.ocr = ocr
        self.capabilities = capabilities
        self.maxOCRPerSweep = maxOCRPerSweep
        self.ocrRemaining = maxOCRPerSweep
    }

    /// Refill the OCR budget at the start of a sweep (the runtime calls this before
    /// handing the sweep to the engine).
    public func beginSweep() {
        ocrRemaining = maxOCRPerSweep
    }

    public func snapshot(of target: AmbientWindowTarget) -> CapturedText? {
        let strategy = capabilities.strategy(for: target.context.bundleID)

        // Known AX-opaque (curated set — no credential apps): straight to OCR, targeted
        // by exact windowID. Same no-field-level-vetting residual as the focused path's
        // ocrOnly branch — documented, not a regression introduced here.
        if strategy == .ocrOnly {
            return tryOCR(target)
        }

        let reading = ax.readWindow(target)
        // Unvetted window (couldn't resolve/walk it) — must NOT screenshot it.
        guard reading.windowResolved else { return nil }
        // Never OCR-fallback a window where AX saw a secure field.
        if reading.containedSecureField { return reading.text }
        guard OCRFallbackPolicy.shouldAttemptOCR(strategy: strategy, axText: reading.text?.text) else {
            return reading.text
        }
        // AX thin/empty on a vetted (no-secure-field) window — OCR is safe. Never
        // regress below what AX already had.
        guard let ocrResult = tryOCR(target) else { return reading.text }
        let axLen = reading.text.map { TextNormalizer.normalize($0.text).count } ?? 0
        let ocrLen = TextNormalizer.normalize(ocrResult.text).count
        return ocrLen > axLen ? ocrResult : reading.text
    }

    /// One OCR screenshot, if the per-sweep budget allows. Decrements on ATTEMPT (the
    /// cost is the screenshot, whether or not it yields text).
    private func tryOCR(_ target: AmbientWindowTarget) -> CapturedText? {
        guard ocrRemaining > 0 else { return nil }
        ocrRemaining -= 1
        return ocr.ocrWindow(target)
    }
}
