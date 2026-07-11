import Foundation

/// One on-screen window as enumerated from the window server (the live daemon fills
/// these from `CGWindowListCopyWindowInfo`). Pure value so the sweep PLAN — which
/// windows get captured, in what order — is decided and tested headless; the
/// TCC-gated enumeration + AX/OCR of each window live in `scrollbackd`.
public struct WindowDescriptor: Sendable, Equatable {
    public let windowID: UInt32
    public let pid: Int32
    public let bundleID: String
    public let appName: String
    /// Raw window title (may carry spinner/animation glyphs); normalized by the planner.
    public let title: String?
    /// Window level. 0 is the normal document/window layer; menus, the Dock, the
    /// wallpaper, status items, tooltips sit at non-zero levels — we sweep only 0.
    public let layer: Int
    public let width: Double
    public let height: Double
    public let isOnScreen: Bool
    /// `kCGWindowSharingState == none` — the window opted out of screen capture. We
    /// honor an app's own "don't record me" flag for the sweep too.
    public let isSharingNone: Bool

    public var area: Double { width * height }

    public init(
        windowID: UInt32, pid: Int32, bundleID: String, appName: String,
        title: String?, layer: Int, width: Double, height: Double,
        isOnScreen: Bool, isSharingNone: Bool = false
    ) {
        self.windowID = windowID
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.layer = layer
        self.width = width
        self.height = height
        self.isOnScreen = isOnScreen
        self.isSharingNone = isSharingNone
    }
}

/// A window the planner selected for an ambient (non-focused) capture. Carries the
/// `FrontmostContext` used everywhere else PLUS the exact `windowID` — so OCR can
/// screenshot precisely that window (not "the largest owned window") even when two
/// windows share a title, and the engine can dedup re-sweeps per window.
public struct AmbientWindowTarget: Sendable, Equatable {
    public let context: FrontmostContext
    public let windowID: UInt32
    public let area: Double

    public init(context: FrontmostContext, windowID: UInt32, area: Double) {
        self.context = context
        self.windowID = windowID
        self.area = area
    }
}

/// Reads on-screen text for a specific (background) window, addressed by its exact
/// `AmbientWindowTarget`. Separate from `TextSnapshotProvider` (which reads the
/// *focused* window) so the focused capture path is untouched: the live
/// implementation resolves the specific window by title (AX) / windowID (OCR).
/// `nil` in the engine → the sweep is a no-op (so `simulate`/tests never sweep).
public protocol AmbientWindowProvider: AnyObject {
    func snapshot(of target: AmbientWindowTarget) -> CapturedText?
}

/// Bounds on one sweep so capturing every visible window stays inside the <5% CPU
/// launch gate. The sweep is event-triggered (focus change), never a poll; these
/// cap the work each trigger does.
public struct VisibleWindowSweepConfig: Sendable {
    /// Hard cap on windows captured per sweep (largest-area first). A busy desktop
    /// with dozens of windows still bounds work; the salient (big) windows win.
    public var maxWindowsPerSweep: Int
    /// Skip windows smaller than this (px²) — tooltips, palettes, notification
    /// bubbles, thin toolbars. ~200×200 by default.
    public var minWindowArea: Double
    /// The window level we consider a real document window (see `WindowDescriptor.layer`).
    public var normalWindowLayer: Int

    public init(
        maxWindowsPerSweep: Int = 12,
        minWindowArea: Double = 40_000,
        normalWindowLayer: Int = 0
    ) {
        self.maxWindowsPerSweep = maxWindowsPerSweep
        self.minWindowArea = minWindowArea
        self.normalWindowLayer = normalWindowLayer
    }
}

/// Pure selection of which visible windows an ambient sweep captures. This is a
/// privacy-load-bearing gate on a WIDENED capture surface (all windows, not just
/// the focused one), so it is fully unit-tested: `never_capture` exclusions are
/// dropped here (and re-checked in the engine — defense in depth), the focused
/// window is skipped (the focused stream already captures it), and the result is
/// deterministic (area-desc, windowID tie-break) so the cap is stable.
public enum VisibleWindowSweepPlanner {

    public static func plan(
        windows: [WindowDescriptor],
        focused: FrontmostContext?,
        exclusions: ExclusionSet,
        capabilities: AppCaptureCapabilities = AppCaptureCapabilities(),
        config: VisibleWindowSweepConfig = VisibleWindowSweepConfig()
    ) -> [AmbientWindowTarget] {
        // A focused window with a known title is captured by the focused stream —
        // skip it here to avoid double-capture. When the focused window has no
        // title we can't identify it among same-pid windows, so we don't skip by
        // pid alone (that would drop the app's OTHER windows too); the rare
        // duplicate is collapsed downstream by near-dup chunking.
        let focusedTitle = focused?.windowTitle
        let skipFocused = focusedTitle != nil

        // Whole-pid fail-safe (mirrors CaptureGuards.pidHasSharingNoneWindow): if an
        // app has ANY sharing-none window, drop ALL its windows from the sweep. Done
        // here from the already-enumerated descriptors — one pass, no extra
        // window-server round-trips per window, and more precise than re-enumerating.
        let sharingNonePids = Set(windows.filter { $0.isSharingNone }.map { $0.pid })

        var targets: [AmbientWindowTarget] = []
        for window in windows {
            guard window.isOnScreen,
                  window.layer == config.normalWindowLayer,
                  window.area >= config.minWindowArea,
                  !sharingNonePids.contains(window.pid) else { continue }

            let normalizedTitle = WindowTitleNormalizer.normalize(window.title)

            // An untitled window can't be resolved by title, so for a non-ocrOnly app
            // it can NEVER actually be captured (AXTextExtractor.readWindow returns
            // .unresolved, and the provider then refuses to OCR an unvetted window).
            // Multi-process apps (Chrome/Notion/Electron) register several title-less
            // sub-window entries per visible window — dropping them declutters the plan
            // and stops them consuming the per-sweep cap. ocrOnly apps CAN capture an
            // untitled window (OCR targets by exact windowID), so those are kept.
            if normalizedTitle == nil, capabilities.strategy(for: window.bundleID) != .ocrOnly {
                continue
            }

            if skipFocused, let focused,
               window.pid == focused.pid, normalizedTitle == focusedTitle {
                continue // the focused window — already captured by the focused stream
            }

            let context = FrontmostContext(
                pid: window.pid, bundleID: window.bundleID,
                appName: window.appName, windowTitle: normalizedTitle
            )
            // Drop never-capture windows here so we never even AX/OCR a password
            // manager or banking window on a side monitor. `.redact` windows are
            // kept: the engine records the episode with a masked placeholder.
            guard exclusions.mode(for: context) != .neverCapture else { continue }

            targets.append(AmbientWindowTarget(context: context, windowID: window.windowID, area: window.area))
        }

        // Deterministic: biggest first (most salient survive the cap), windowID as a
        // stable tie-break so the cap picks the same set every run.
        targets.sort { lhs, rhs in
            lhs.area != rhs.area ? lhs.area > rhs.area : lhs.windowID < rhs.windowID
        }
        if targets.count > config.maxWindowsPerSweep {
            targets = Array(targets.prefix(config.maxWindowsPerSweep))
        }
        return targets
    }
}

/// Counters for the all-windows sweep, kept SEPARATE from `CaptureStats` so the
/// `scrollbackd simulate` golden line (built from `CaptureStats.summary`) is
/// unchanged — the fixture has no ambient provider, so it never sweeps.
public struct AmbientSweepStats: Sendable, Equatable {
    public var episodes = 0
    public var events = 0
    public var providerCalls = 0
    public var dedupSkips = 0

    public init(episodes: Int = 0, events: Int = 0, providerCalls: Int = 0, dedupSkips: Int = 0) {
        self.episodes = episodes
        self.events = events
        self.providerCalls = providerCalls
        self.dedupSkips = dedupSkips
    }

    public var summary: String {
        "ambient_episodes=\(episodes) ambient_events=\(events) "
            + "ambient_provider_calls=\(providerCalls) ambient_dedup_skips=\(dedupSkips)"
    }
}
