import Foundation
import AppKit
import ApplicationServices
import CoreGraphics
import ScrollbackCore

/// C callback for AXObserver — routes back into the runtime via refcon.
/// Registered on the app-level element; delivered on the main run loop.
private let axObserverCallback: AXObserverCallback = { _, _, notification, refcon in
    guard let refcon else { return }
    let runtime = Unmanaged<CaptureRuntime>.fromOpaque(refcon).takeUnretainedValue()
    let name = notification as String
    MainActor.assumeIsolated {
        runtime.handleAXNotification(name)
    }
}

/// Builds a FrontmostContext for whatever app is frontmost right now.
/// Shared by the live runtime and `ax-dump` so both see identical context.
@MainActor
func makeFrontmostContext(extractor: AXTextExtractor) -> FrontmostContext? {
    guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
    let pid = app.processIdentifier
    return FrontmostContext(
        pid: pid,
        bundleID: app.bundleIdentifier ?? "unknown.bundle",
        appName: app.localizedName ?? "Unknown",
        windowTitle: extractor.focusedWindowTitle(pid: pid)
    )
}

// Clean-shutdown plumbing: SIGINT/SIGTERM must flush the open episode via
// engine.finish before exit, or every session's JSONL ends with a dangling
// episode_open. The signal source runs on the main queue; the hook is set from
// a @MainActor context so capturing the (non-Sendable) engine is safe there.
nonisolated(unsafe) private var shutdownHook: (@MainActor () -> Void)?
nonisolated(unsafe) private var shutdownSources: [DispatchSourceSignal] = []

@MainActor
func installShutdownHandler(_ hook: @escaping @MainActor () -> Void) {
    shutdownHook = hook
    for sig in [SIGINT, SIGTERM] {
        signal(sig, SIG_IGN) // disable default terminate so our handler runs
        let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { shutdownHook?() }
            exit(0)
        }
        source.resume()
        shutdownSources.append(source)
    }
}

/// Wires real macOS event sources into the CaptureEngine, confined to the main
/// run loop. Event-driven by construction:
///   - NSWorkspace app-activation notifications → app switch
///   - AXObserver (focused window/title/value/focused-element changed) → window
///     change + debounced typing captures
///   - NSPasteboard changeCount probe (an int compare, NOT content capture) →
///     clipboard events, honoring ConcealedType/TransientType
///   - a slow heartbeat that only feeds the engine's idle/fallback logic from
///     real input recency (CGEventSource); the engine decides idle
@MainActor
final class CaptureRuntime: NSObject {

    private let engine: CaptureEngine
    private let extractor: AXTextExtractor
    private let idleThreshold: TimeInterval

    /// All-windows sweep: the same exclusion set the engine uses (so the planner's
    /// early drop and the engine's chokepoint agree), plus per-sweep bounds and a
    /// minimum gap between sweeps. The sweep is event-triggered (a focus/app change),
    /// throttled here so rapid switching can't run it faster than `minSweepInterval`.
    private let exclusions: ExclusionSet
    private let capabilities: AppCaptureCapabilities
    private let sweepConfig: VisibleWindowSweepConfig
    private let minSweepInterval: TimeInterval
    private var lastSweepAt: Date?
    /// The sweep provider, held here so we can refill its per-sweep OCR budget before
    /// each sweep. `nil` disables sweeping (e.g. a build without the provider wired).
    private let ambientProvider: LayeredAmbientWindowProvider?

    private var currentContext: FrontmostContext?
    private var axObserver: AXObserver?
    private var observedPID: pid_t = -1

    private var pasteboardChangeCount = NSPasteboard.general.changeCount
    private var pasteboardTimer: Timer?
    private var heartbeatTimer: Timer?
    private var debounceTimer: Timer?
    private var titleRefreshTimer: Timer?

    private let heartbeatInterval: TimeInterval = 30
    private let pasteboardProbeInterval: TimeInterval = 2
    private let titleRefreshDebounce: TimeInterval = 0.5

    init(
        engine: CaptureEngine,
        extractor: AXTextExtractor,
        exclusions: ExclusionSet = ExclusionSet(),
        capabilities: AppCaptureCapabilities = AppCaptureCapabilities(),
        ambientProvider: LayeredAmbientWindowProvider? = nil,
        sweepConfig: VisibleWindowSweepConfig = VisibleWindowSweepConfig(),
        minSweepInterval: TimeInterval = 5.0,
        idleThreshold: TimeInterval = 300
    ) {
        self.engine = engine
        self.extractor = extractor
        self.exclusions = exclusions
        self.capabilities = capabilities
        self.ambientProvider = ambientProvider
        self.sweepConfig = sweepConfig
        self.minSweepInterval = minSweepInterval
        self.idleThreshold = idleThreshold
        super.init()
    }

    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        // int-compare probes + engine heartbeat — not capture-by-timer (see class doc)
        pasteboardTimer = Timer.scheduledTimer(
            timeInterval: pasteboardProbeInterval, target: self,
            selector: #selector(pasteboardProbe), userInfo: nil, repeats: true
        )
        heartbeatTimer = Timer.scheduledTimer(
            timeInterval: heartbeatInterval, target: self,
            selector: #selector(heartbeat), userInfo: nil, repeats: true
        )
        refreshFrontmost(isFocusChange: true) // initial sweep of the visible desktop
    }

    func shutdown() {
        engine.finish(at: Date())
    }

    // MARK: - Sources

    @objc private func appActivated(_ note: Notification) {
        refreshFrontmost(isFocusChange: true)
    }

    @objc private func pasteboardProbe() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardChangeCount else { return }
        pasteboardChangeCount = pasteboard.changeCount

        // Never capture concealed/transient pasteboard content (password managers).
        let types = pasteboard.types ?? []
        let concealed = types.contains(NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
            || types.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        guard !concealed, let text = pasteboard.string(forType: .string), !text.isEmpty else { return }

        guard let context = currentContext ?? makeFrontmostContext(extractor: extractor) else { return }
        engine.handleClipboard(text, context: context, at: Date())
    }

    @objc private func heartbeat() {
        // System-wide input recency (no TCC needed). Only counts as activity if
        // the last real input is within the idle window — otherwise the engine
        // is allowed to go idle. Timestamp is back-dated to the actual input so
        // idle onset / episode tsEnd don't drift by up to a heartbeat.
        let idleSeconds = [CGEventType.keyDown, .mouseMoved, .leftMouseDown, .rightMouseDown, .scrollWheel]
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? .greatestFiniteMagnitude
        if idleSeconds < idleThreshold {
            engine.noteUserActivity(at: Date().addingTimeInterval(-idleSeconds))
        }
        engine.tick(at: Date())
    }

    @objc private func debounceFired() {
        engine.tick(at: Date())
    }

    fileprivate func handleAXNotification(_ name: String) {
        switch name {
        case kAXFocusedWindowChangedNotification:
            refreshFrontmost(isFocusChange: true) // real window switch — act immediately + sweep
        case kAXTitleChangedNotification:
            scheduleTitleRefresh() // coalesce title ticks (unread counts, clocks, progress)
        case kAXValueChangedNotification, kAXFocusedUIElementChangedNotification:
            guard let context = currentContext else { return }
            let deadline = engine.handleTextChangeSignal(context, at: Date())
            scheduleDebounce(at: deadline)
        default:
            break
        }
    }

    @objc private func titleRefreshFired() {
        titleRefreshTimer = nil
        refreshFrontmost(isFocusChange: false) // same-window title tick — refresh, don't sweep
    }

    /// Collapse a burst of title changes into a single refresh after a quiet
    /// period, so a title-ticking app doesn't churn one episode + full AX walk
    /// per tick. The first tick in a burst schedules; the rest are dropped.
    private func scheduleTitleRefresh() {
        guard titleRefreshTimer == nil else { return }
        titleRefreshTimer = Timer.scheduledTimer(
            timeInterval: titleRefreshDebounce, target: self,
            selector: #selector(titleRefreshFired), userInfo: nil, repeats: false
        )
    }

    // MARK: - Wiring

    /// `isFocusChange` = a genuine app/window focus change (worth an all-windows
    /// sweep). A same-window title tick (a clock, unread count, progress) refreshes
    /// the episode/title but must NOT sweep — otherwise a title-ticking app would
    /// turn the event-triggered sweep into a periodic heavy loop.
    private func refreshFrontmost(isFocusChange: Bool) {
        titleRefreshTimer?.invalidate()
        titleRefreshTimer = nil
        let now = Date()
        guard let context = makeFrontmostContext(extractor: extractor) else { return }
        currentContext = context
        engine.handleAppOrWindowChange(context, at: now)
        attachAXObserver(to: context.pid)
        if isFocusChange {
            maybeSweepVisibleWindows(focused: context, at: now)
        }
    }

    /// The all-windows sweep, triggered by a focus/app change (NOT a timer). Enumerate
    /// every on-screen window across displays, let the planner pick which to capture
    /// (drops the focused window, excluded windows, offscreen/tiny/wrong-layer), and
    /// hand them to the engine — each becomes its own ambient episode. Throttled so
    /// rapid switching runs it at most once per `minSweepInterval`.
    private func maybeSweepVisibleWindows(focused: FrontmostContext, at now: Date) {
        if let last = lastSweepAt, now.timeIntervalSince(last) < minSweepInterval { return }
        lastSweepAt = now
        let descriptors = VisibleWindowEnumerator.enumerate()
        let targets = VisibleWindowSweepPlanner.plan(
            windows: descriptors, focused: focused, exclusions: exclusions,
            capabilities: capabilities, config: sweepConfig
        )
        ambientProvider?.beginSweep() // refill the per-sweep OCR budget
        engine.sweepAmbientWindows(targets, at: now)
    }

    private func attachAXObserver(to pid: pid_t) {
        guard pid != observedPID else { return }

        var observer: AXObserver?
        // Only tear down the old observer and stamp observedPID once creation
        // succeeds — otherwise a transient failure would strand us with no
        // observer and the pid-guard would block every retry.
        guard AXObserverCreate(pid, axObserverCallback, &observer) == .success, let observer else { return }

        if let old = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(old), .defaultMode)
        }
        axObserver = observer
        observedPID = pid

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [
            kAXFocusedWindowChangedNotification,
            kAXTitleChangedNotification,
            kAXValueChangedNotification,
            kAXFocusedUIElementChangedNotification,
        ] {
            AXObserverAddNotification(observer, appElement, notification as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func scheduleDebounce(at deadline: Date) {
        // Reuse the timer while it's still pending (rolling debounce during
        // sustained typing) instead of allocating one per keystroke.
        if let timer = debounceTimer, timer.isValid {
            timer.fireDate = deadline
        } else {
            debounceTimer = Timer.scheduledTimer(
                timeInterval: max(0.05, deadline.timeIntervalSinceNow),
                target: self,
                selector: #selector(debounceFired),
                userInfo: nil,
                repeats: false
            )
        }
    }
}

/// Entry point for `scrollbackd run` (the default mode).
@MainActor
func runDaemon() -> Never {
    print("scrollbackd \(scrollbackCoreVersion) — capture daemon (spike)")

    // "AXTrustedCheckOptionPrompt" is kAXTrustedCheckOptionPrompt's documented
    // value; the CFString global is imported as a Swift-6-unsafe mutable var.
    let trusted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    guard trusted else {
        print("""
        Accessibility permission not granted — live capture cannot start.
        For development: grant your terminal app Accessibility access
        (System Settings → Privacy & Security → Accessibility), then re-run.
        Fixture-driven verification works without it: `swift run scrollbackd simulate`.
        """)
        exit(3)
    }

    do {
        let supportDir = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        ).appendingPathComponent("Scrollback/spike", isDirectory: true)
        // Persist into the searchable weekly-shard store, forwarding to the JSONL
        // spike (human-inspectable). `scrollbackd search "..."` reads this store.
        let catalog = try ShardedCatalog(directory: try scrollbackStoreDirectory())
        let sink = CatalogStoreSink(catalog: catalog, inner: try JSONLSink(directory: supportDir))
        let config = CaptureConfig()
        let exclusions = ExclusionSet()
        let capabilities = AppCaptureCapabilities()
        let axExtractor = AXTextExtractor(maxTotalChars: config.maxTextLength)
        // One OCR extractor shared by the focused path and the sweep, so their
        // screenshots serialize (`inFlight`) — at most one capture at a time, honoring
        // the <5% CPU intent.
        let ocrExtractor = VisionOCRExtractor()
        // AX-first, OCR-fallback via the per-app capability matrix. OCR only
        // fires for AX-opaque surfaces (and only if Screen Recording is granted);
        // rich-AX apps never pay for a screenshot. See LayeredTextSnapshotProvider.
        let provider = LayeredTextSnapshotProvider(ax: axExtractor, ocr: ocrExtractor, capabilities: capabilities)
        // All-windows sweep: read each background window by exact identity (AX by
        // title, OCR by windowID) with the same secure-field rules as the focused path
        // plus a per-sweep OCR budget. Security logic lives in Core (tested headless).
        let ambientProvider = LayeredAmbientWindowProvider(ax: axExtractor, ocr: ocrExtractor, capabilities: capabilities)
        let engine = CaptureEngine(
            provider: provider, sink: sink, config: config,
            exclusions: exclusions, ambientProvider: ambientProvider
        )
        let runtime = CaptureRuntime(
            engine: engine, extractor: axExtractor, exclusions: exclusions,
            capabilities: capabilities, ambientProvider: ambientProvider, idleThreshold: config.idleThreshold
        )
        runtime.start()

        // Serve read-only recall over the local socket WHILE capturing — this is what
        // real usage looks like: Claude queries live memory. A SECOND ShardedCatalog
        // (its own connections) reads the same WAL store this path writes; non-fatal if
        // the socket can't bind (capture keeps running).
        let recallServer = startRecallServerForCaptureDaemon()

        // Flush the open episode on Ctrl-C / SIGTERM before exiting, then log the
        // session's capture volume (raw vs deduped chars, chunks/hour) + sweep counters.
        installShutdownHandler {
            recallServer?.stop()
            runtime.shutdown()
            print("volume: \(sink.summary)")
            print("sweep: \(engine.ambientStats.summary)")
        }

        if !CGPreflightScreenCaptureAccess() {
            print("note: Screen Recording not granted — OCR fallback inactive (AX-only). "
                + "Grant it to capture AX-opaque apps; run `scrollbackd ocr-dump` to test.")
        }
        print("capturing (event-driven, all visible windows across displays) → searchable store + JSONL spike")
        print("Ctrl-C to stop. Then try:  scrollbackd search \"something you saw\"")
        print("(plaintext for now — encryption + the embedding model land next.)")
        withExtendedLifetime((runtime, engine, recallServer)) {
            RunLoop.main.run()
        }
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("scrollbackd: failed to start: \(error)\n".utf8))
        exit(1)
    }
}

/// Entry point for `scrollbackd ax-dump` — one-shot diagnostic of the AX text path.
@MainActor
func runAXDump() -> Int32 {
    guard AXIsProcessTrusted() else {
        print("Accessibility permission not granted (grant it to your terminal app for dev). Nothing to dump.")
        return 3
    }
    let extractor = AXTextExtractor()
    guard let context = makeFrontmostContext(extractor: extractor) else {
        print("No frontmost application.")
        return 1
    }
    print("frontmost: \(context.appName) [\(context.bundleID)] — window: \(context.windowTitle ?? "<none>")")
    if let snapshot = extractor.snapshot(for: context) {
        let normalized = TextNormalizer.normalize(snapshot.text)
        print("extracted \(normalized.count) chars (normalized, source=\(snapshot.source)); first 400:")
        print(String(normalized.prefix(400)))
        return 0
    } else {
        print("no AX text (empty tree — likely an AX-opaque app; try `scrollbackd ocr-dump`).")
        return 2
    }
}
