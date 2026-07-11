import Foundation

/// How to obtain on-screen text for a given app — the resolution of the PRD's
/// "Apple Vision OCR fallback for AX-opaque surfaces … per-app capability
/// matrix". Every frontmost app maps to one of these.
public enum CaptureStrategy: String, Sendable, Equatable, CaseIterable {
    /// Accessibility only — never screenshot/OCR. The privacy- and
    /// battery-cheapest path, correct for the majority of native apps whose AX
    /// tree is already near-lossless.
    case axOnly
    /// Try Accessibility first; fall back to OCR (a screenshot + Vision) ONLY if
    /// AX yields too little text. The default for unknown apps: a rich-AX app
    /// never pays the OCR cost, but a novel Electron/canvas app whose AX comes
    /// back empty still produces text.
    case axThenOCR
    /// Skip Accessibility entirely, go straight to OCR — for surfaces known to
    /// be AX-opaque (some Electron builds, remote desktops, raw canvases) where
    /// walking the AX tree only burns CPU for nothing.
    case ocrOnly
}

/// Per-app capture-strategy resolver (the capability matrix). Pure + `Sendable`
/// so the fallback policy is unit-tested without a Screen Recording grant.
///
/// The default is `axThenOCR`, deliberately: OCR is *demand-driven*, firing only
/// when a specific app's AX text is actually thin. That satisfies the M1 DoD
/// ("an Electron/canvas app with empty AX still produces text") for apps we
/// never enumerated, while keeping the "text-first, zero frames, <5% CPU"
/// promise for the common case (a rich-AX app never triggers a screenshot).
public struct AppCaptureCapabilities: Sendable {
    private let table: [String: CaptureStrategy]
    private let defaultStrategy: CaptureStrategy

    public init(
        table: [String: CaptureStrategy] = AppCaptureCapabilities.seededTable,
        defaultStrategy: CaptureStrategy = .axThenOCR
    ) {
        self.table = table
        self.defaultStrategy = defaultStrategy
    }

    public func strategy(for bundleID: String) -> CaptureStrategy {
        table[bundleID] ?? defaultStrategy
    }

    /// Seed of apps whose AX behaviour is known, so we skip the runtime
    /// self-selection for them. Rich-native-AX apps are pinned to `axOnly` (OCR
    /// would only duplicate their text at CPU cost); known AX-opaque surfaces to
    /// `ocrOnly` (the AX walk is wasted). Everything else takes the `axThenOCR`
    /// default and self-selects based on whether AX actually produced text.
    ///
    /// This is a starting seed, not the source of truth — the demand-driven
    /// default is what makes coverage correct for apps not listed here.
    public static let seededTable: [String: CaptureStrategy] = [
        // Rich native AX — trust it, never screenshot.
        "com.apple.Safari": .axOnly,
        "com.apple.TextEdit": .axOnly,
        "com.apple.dt.Xcode": .axOnly,
        "com.apple.finder": .axOnly,
        "com.apple.mail": .axOnly,
        "com.apple.Notes": .axOnly,
        "com.apple.Terminal": .axOnly,
        "com.googlecode.iterm2": .axOnly,
        // Known AX-opaque / canvas or remote-pixel surfaces — go straight to OCR.
        "com.microsoft.rdc.macos": .ocrOnly,       // Windows App / Remote Desktop
        "com.teamviewer.TeamViewer": .ocrOnly,
        "org.virtualbox.app.VirtualBox": .ocrOnly,
        "com.figma.Desktop": .ocrOnly,             // canvas-rendered
    ]
}

/// Decides whether OCR should be attempted, given an app's strategy and what (if
/// anything) Accessibility produced. Pure — the screenshot + Vision call itself
/// lives in `scrollbackd` behind the Screen Recording grant, but the *decision*
/// to reach for it is here, so it is regression-tested headless.
public enum OCRFallbackPolicy {
    /// Normalized (whitespace-collapsed) AX text at or below this many characters
    /// is "thin" enough that the surface is likely AX-opaque and OCR is worth a
    /// try. Tuned to skip title-only AX trees (e.g. a bare window title) without
    /// OCR-ing every app that happens to expose a short label.
    public static let thinTextThreshold = 16

    public static func shouldAttemptOCR(strategy: CaptureStrategy, axText: String?) -> Bool {
        switch strategy {
        case .axOnly:
            return false
        case .ocrOnly:
            return true
        case .axThenOCR:
            let count = axText.map { TextNormalizer.normalize($0).count } ?? 0
            return count <= thinTextThreshold
        }
    }
}

/// Composes the AX provider and the OCR provider via the capability matrix —
/// the concrete "AX-first, OCR-fallback" seam. Synchronous by design: the
/// `CaptureEngine` is synchronous and deterministic (so it can be driven headless
/// by `simulate` and the tests), and the rare OCR screenshot is bridged to sync
/// inside the OCR provider rather than forcing the whole engine async.
///
/// Never regresses: for `axThenOCR`, if OCR produces *less* text than the AX read
/// it was meant to rescue, the AX text is kept (AX is near-lossless; OCR carries
/// noise). Source labelling is honest — OCR output is `.ocr`, so retrieval can
/// down-weight it (see `CaptureSource`).
public final class LayeredTextSnapshotProvider: TextSnapshotProvider {
    private let ax: TextSnapshotProvider
    private let ocr: TextSnapshotProvider
    private let capabilities: AppCaptureCapabilities

    public init(
        ax: TextSnapshotProvider,
        ocr: TextSnapshotProvider,
        capabilities: AppCaptureCapabilities = AppCaptureCapabilities()
    ) {
        self.ax = ax
        self.ocr = ocr
        self.capabilities = capabilities
    }

    public func snapshot(for context: FrontmostContext) -> CapturedText? {
        let strategy = capabilities.strategy(for: context.bundleID)

        // Known AX-opaque: skip the AX walk entirely, don't burn CPU on it.
        if strategy == .ocrOnly {
            return ocr.snapshot(for: context)
        }

        let axResult = ax.snapshot(for: context)
        // Never OCR-fallback a window where AX saw a secure field: a whole-window
        // screenshot would recapture the exact credential surface the AX walker
        // declined to read. Keep the (secure-field-free) AX text instead.
        if axResult?.containedSecureField == true {
            return axResult
        }
        guard OCRFallbackPolicy.shouldAttemptOCR(strategy: strategy, axText: axResult?.text) else {
            return axResult
        }
        // AX was thin/empty and this app permits OCR — try it, but never regress
        // below what AX already had.
        guard let ocrResult = ocr.snapshot(for: context) else { return axResult }
        let axLen = axResult.map { TextNormalizer.normalize($0.text).count } ?? 0
        let ocrLen = TextNormalizer.normalize(ocrResult.text).count
        return ocrLen > axLen ? ocrResult : axResult
    }
}
