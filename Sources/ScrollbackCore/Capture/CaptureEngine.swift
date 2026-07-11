import Foundation

/// The event-driven capture core. Pure logic, deterministic, clock-injected —
/// NO fixed-interval polling: a capture happens only in response to an event
/// (app/window change, debounced text-change signal, clipboard change) or, at
/// most every `fallbackInterval`, when there has been real user activity since
/// the last capture.
///
/// Key distinction (fixes the "always-on app defeats idle" class of bug):
///   - USER ACTIVITY (app switch, clipboard, real input reported via
///     `noteUserActivity`) resets the idle clock and can (re)open an episode.
///   - A CONTENT-CHANGE signal (`handleTextChangeSignal`, from AXValueChanged)
///     is NOT activity — an app updating its own content (a log tail, an
///     incoming chat message) must not keep the session alive forever.
///
/// Not thread-safe by design: the daemon confines it to the main run loop;
/// tests and the simulator drive it synchronously with synthetic dates.
public final class CaptureEngine {

    private let provider: TextSnapshotProvider
    private let sink: CaptureEventSink
    private let config: CaptureConfig
    private let redactor: Redactor
    private let exclusions: ExclusionSet
    /// Reads background (non-focused) windows during an all-windows sweep. `nil`
    /// (the default, and what `simulate`/most tests use) makes `sweepAmbientWindows`
    /// a no-op — so the fixture never sweeps and the `simulate` golden is unchanged.
    private let ambientProvider: AmbientWindowProvider?

    /// Stored in place of content for a `.redact`-mode exclusion: the episode
    /// (app/window/time) is recorded, the on-screen text is not.
    static let redactedContentPlaceholder = "[content excluded by redact rule]"

    public private(set) var stats = CaptureStats()
    /// Counters for the all-windows sweep — kept out of `stats`/`CaptureStats.summary`
    /// so the `simulate` golden line stays byte-identical.
    public private(set) var ambientStats = AmbientSweepStats()

    /// Cross-sweep dedup for ambient windows, keyed by `windowID`: re-sweeping an
    /// unchanged background window (you switch focus a lot) must not re-store it.
    /// Deliberately separate from `lastHashByContext` (the focused stream's
    /// per-episode dedup) — the sweep never touches focused state.
    private var lastAmbientHashByWindow: [UInt32: String] = [:]

    private(set) var currentEpisode: Episode?
    /// Last known frontmost context. Retained across idle-close so activity can
    /// reopen an episode for the same window without an app/window event.
    private(set) var currentContext: FrontmostContext?
    private var lastActivity: Date?
    private var isIdle = false
    private var lastCaptureAttempt: Date?
    private var pendingTyping: (context: FrontmostContext, deadline: Date)?

    /// Per-episode dedup: reset on every episode open, so a new episode always
    /// records its opening content even if identical to the previous episode's,
    /// while re-reads within one episode are collapsed.
    private var lastHashByContext: [String: String] = [:]

    public init(
        provider: TextSnapshotProvider,
        sink: CaptureEventSink,
        config: CaptureConfig = CaptureConfig(),
        redactor: Redactor = Redactor(),
        exclusions: ExclusionSet = ExclusionSet(),
        ambientProvider: AmbientWindowProvider? = nil
    ) {
        self.provider = provider
        self.sink = sink
        self.config = config
        self.redactor = redactor
        self.exclusions = exclusions
        self.ambientProvider = ambientProvider
    }

    // MARK: - Triggers

    /// App switch or window/title change (user activity).
    public func handleAppOrWindowChange(_ context: FrontmostContext, at now: Date) {
        noteActivity(at: now)
        // Excluded app/window: close any open episode, remember where we are (so
        // stray content signals for it are ignored), but open nothing. Checked
        // BEFORE the same-key branch so a re-entered excluded window can't reopen.
        if exclusions.mode(for: context) == .neverCapture {
            pendingTyping = nil
            closeEpisode(at: now)
            currentContext = context
            return
        }
        if currentContext?.key == context.key {
            currentContext = context
            if currentEpisode == nil {           // resuming in the same window after idle
                openEpisode(context, at: now)
                capture(context, at: now)
            }
            return
        }
        pendingTyping = nil // stale: it belonged to the previous window
        closeEpisode(at: now)
        openEpisode(context, at: now)
        capture(context, at: now)
    }

    /// A text-change signal (AXValueChanged etc.) — a CONTENT signal, not user
    /// activity. Debounced: capture fires on the first `tick` at/after the
    /// returned deadline; new signals roll it. If there's no open episode for
    /// this context (e.g. after idle), it is ignored — a real activity signal
    /// or an app switch reopens the episode, so an app mutating its own content
    /// while the user is away cannot resurrect capture.
    @discardableResult
    public func handleTextChangeSignal(_ context: FrontmostContext, at now: Date) -> Date {
        guard !isIdle, currentContext?.key == context.key, currentEpisode != nil else {
            return now
        }
        let deadline = now.addingTimeInterval(config.typingDebounce)
        pendingTyping = (context, deadline)
        return deadline
    }

    /// A clipboard change (user activity). The runtime is responsible for
    /// skipping concealed/transient pasteboard types (password managers).
    public func handleClipboard(_ content: String, context: FrontmostContext, at now: Date) {
        noteActivity(at: now)
        let mode = exclusions.mode(for: context)
        guard mode != .neverCapture else { return } // never store a copy from an excluded app
        ensureEpisode(context, at: now)
        // Store the NORMALIZED copy (whitespace collapsed): it feeds the same
        // single redaction pass as screen text, so a card/secret copied with tab,
        // newline, or NBSP separators can't slip past the space/dash-only patterns
        // by staying in a verbatim form the hash pass would have masked. A redact
        // rule stores only the placeholder.
        let storeText = (mode == .redact)
            ? CaptureEngine.redactedContentPlaceholder
            : TextNormalizer.normalize(String(content.prefix(config.maxTextLength)))
        emit(
            storeText: storeText,
            type: .clipboard,
            source: .ax,
            confidence: 1.0,
            dedupKey: "clipboard|" + context.key,
            at: now
        )
    }

    /// Real user activity observed by the runtime (keyboard/mouse/scroll).
    /// Resets the idle clock and, if the last episode was idle-closed, reopens
    /// one for the last-known window (resume-by-reading/scrolling).
    public func noteUserActivity(at now: Date) {
        noteActivity(at: now)
        if let context = currentContext, currentEpisode == nil {
            guard exclusions.mode(for: context) != .neverCapture else { return } // don't resume into an excluded window
            openEpisode(context, at: now)
            capture(context, at: now)
        }
    }

    /// Drives time-based behavior. Called by the runtime only when something is
    /// scheduled (debounce deadline) or on its slow heartbeat — never as a
    /// capture-by-timer mechanism.
    public func tick(at now: Date) {
        // Idle check first: it must win over the fallback capture.
        if !isIdle, let last = lastActivity, now.timeIntervalSince(last) >= config.idleThreshold {
            isIdle = true
            pendingTyping = nil
            closeEpisode(at: last) // the episode ended when activity ended
            return
        }
        guard !isIdle else { return }

        if let pending = pendingTyping, now >= pending.deadline {
            pendingTyping = nil
            capture(pending.context, at: now)
        } else if pendingTyping == nil,
                  let context = currentContext,
                  currentEpisode != nil,
                  let lastAttempt = lastCaptureAttempt,
                  let last = lastActivity,
                  last > lastAttempt, // only if the user did something since the last capture
                  now.timeIntervalSince(lastAttempt) >= config.fallbackInterval {
            capture(context, at: now)
        }
    }

    /// Shutdown: close any open episode.
    public func finish(at now: Date) {
        pendingTyping = nil
        closeEpisode(at: now)
    }

    // MARK: - All-windows sweep

    /// Capture a set of background (non-focused) windows, each as its own atomic
    /// episode. Called by the runtime on a focus/app change (event-triggered, never
    /// a poll) with the planner's selection. A no-op if no ambient provider is set.
    ///
    /// Deliberately isolated from the focused stream: it never reads or writes
    /// `currentEpisode`/`currentContext`/idle/activity/`lastHashByContext`, so an
    /// ambient sweep can't disturb the episode you're actively in (its debounce,
    /// idle timer, dedup). Each window opens → captures once → closes immediately.
    public func sweepAmbientWindows(_ targets: [AmbientWindowTarget], at now: Date) {
        guard let ambientProvider else { return }
        for target in targets {
            captureAmbientWindow(target, using: ambientProvider, at: now)
        }
        // Bound the cross-sweep dedup map to this sweep's windows: evict windows no
        // longer present so it can't grow unbounded over an always-on session. This
        // runs at sweep END, so it also drops the hash of a window that has closed by
        // now — which makes a recycled windowID far less likely to inherit a stale
        // hash (a windowID reused in the very NEXT sweep is still matched against the
        // prior hash during that sweep, so content-hash inequality is the final guard;
        // macOS CGWindowIDs are monotonic, so this window is vanishingly small).
        let live = Set(targets.map { $0.windowID })
        lastAmbientHashByWindow = lastAmbientHashByWindow.filter { live.contains($0.key) }
    }

    private func captureAmbientWindow(
        _ target: AmbientWindowTarget, using provider: AmbientWindowProvider, at now: Date
    ) {
        let context = target.context
        let mode = exclusions.mode(for: context)
        // Defense in depth — the planner already dropped never-capture windows, but
        // the engine is the authoritative exclusion chokepoint (as on the focused path).
        guard mode != .neverCapture else { return }

        // Resolve the text to store. A redact rule records the episode but not the
        // screen text — and, like the focused path, doesn't even read the window.
        let storeText: String
        let source: CaptureSource
        let confidence: Double
        if mode == .redact {
            storeText = CaptureEngine.redactedContentPlaceholder
            source = .ax
            confidence = 1.0
        } else {
            ambientStats.providerCalls += 1
            guard let snapshot = provider.snapshot(of: target) else { return }
            storeText = TextNormalizer.normalize(String(snapshot.text.prefix(config.maxTextLength)))
            source = snapshot.source
            confidence = snapshot.confidence
        }
        guard !storeText.isEmpty else { return }

        // Same redact chokepoint as `emit`: redact → hash → dedup. The dedup is
        // per-WINDOW across sweeps (unchanged background window ⇒ skip).
        let redaction = redactor.redact(storeText)
        let hash = TextNormalizer.hash(redaction.text)
        if lastAmbientHashByWindow[target.windowID] == hash {
            ambientStats.dedupSkips += 1
            return
        }
        lastAmbientHashByWindow[target.windowID] = hash

        // Atomic episode: open → one event → close. `provenance` defaults to
        // `.untrustedAmbient` (the security invariant), same as every capture.
        let episode = Episode(
            tsStart: now,
            tsEnd: now,
            bundleID: context.bundleID,
            appName: context.appName,
            windowTitle: (mode == .redact) ? CaptureEngine.redactedContentPlaceholder : context.windowTitle
        )
        sink.episodeOpened(episode)
        sink.event(CaptureEvent(
            episodeID: episode.id,
            ts: now,
            type: .screenText,
            source: source,
            confidence: confidence,
            rawText: redaction.text,
            textHash: hash,
            redactionFlags: redaction.flags
        ))
        var closed = episode
        closed.tsEnd = now
        sink.episodeClosed(closed)
        ambientStats.episodes += 1
        ambientStats.events += 1
    }

    // MARK: - Internals

    private func noteActivity(at now: Date) {
        lastActivity = now
        isIdle = false
    }

    private func ensureEpisode(_ context: FrontmostContext, at now: Date) {
        if currentEpisode == nil {
            openEpisode(context, at: now)
        }
    }

    private func openEpisode(_ context: FrontmostContext, at now: Date) {
        // For a redact rule, the window title can itself be the sensitive datum the
        // rule matched on (a `.window` rule on "Chase — Acct 1234"), so mask it in
        // the stored metadata too — not just the on-screen content. The app is
        // still identifiable by bundleID/appName; the specific window is not.
        let redactTitle = exclusions.mode(for: context) == .redact
        let episode = Episode(
            tsStart: now,
            tsEnd: now,
            bundleID: context.bundleID,
            appName: context.appName,
            windowTitle: redactTitle ? CaptureEngine.redactedContentPlaceholder : context.windowTitle
        )
        currentEpisode = episode
        currentContext = context // real context retained for window-change/dedup matching
        lastHashByContext.removeAll(keepingCapacity: true) // per-episode dedup scope
        stats.episodesOpened += 1
        sink.episodeOpened(episode)
    }

    private func closeEpisode(at now: Date) {
        guard var episode = currentEpisode else { return }
        // Never regress below the episode's own last event/start.
        episode.tsEnd = max(now, episode.tsEnd)
        currentEpisode = nil
        // currentContext is intentionally retained as "last known window".
        stats.episodesClosed += 1
        sink.episodeClosed(episode)
    }

    private func capture(_ context: FrontmostContext, at now: Date) {
        guard currentEpisode != nil else { return }
        let mode = exclusions.mode(for: context)
        guard mode != .neverCapture else { return } // defense in depth (episode shouldn't exist)
        lastCaptureAttempt = now

        // Redact rule: record the episode but not the screen text — don't even read
        // the provider (no reason to pull pixels/AX we're going to throw away).
        guard mode != .redact else {
            emit(
                storeText: CaptureEngine.redactedContentPlaceholder,
                type: .screenText, source: .ax, confidence: 1.0,
                dedupKey: context.key, at: now
            )
            return
        }

        stats.providerCalls += 1
        if isIdle { stats.idleProviderCalls += 1 } // invariant: never happens

        guard let snapshot = provider.snapshot(for: context) else { return }
        let normalized = TextNormalizer.normalize(String(snapshot.text.prefix(config.maxTextLength)))
        emit(
            storeText: normalized,
            type: .screenText,
            source: snapshot.source,
            confidence: snapshot.confidence,
            dedupKey: context.key,
            at: now
        )
    }

    /// Single emit path shared by screen and clipboard capture: empty-guard →
    /// redact → hash → per-episode dedup → sink → stats → advance tsEnd.
    /// Redaction happens HERE, the one chokepoint every captured span passes
    /// through, so no path (screen, clipboard, future audio) can store an
    /// un-redacted secret. `storeText` is already whitespace-normalized by both
    /// callers, so one redaction pass drives rawText, the dedup hash, AND the
    /// flags — they can never disagree, and a secret never enters the hash.
    private func emit(
        storeText: String,
        type: CaptureEventType,
        source: CaptureSource,
        confidence: Double,
        dedupKey: String,
        at now: Date
    ) {
        guard let episode = currentEpisode, !storeText.isEmpty else { return }

        let redaction = redactor.redact(storeText)
        let hash = TextNormalizer.hash(redaction.text)
        if lastHashByContext[dedupKey] == hash {
            stats.dedupSkips += 1
            return
        }
        lastHashByContext[dedupKey] = hash

        sink.event(CaptureEvent(
            episodeID: episode.id,
            ts: now,
            type: type,
            source: source,
            confidence: confidence,
            rawText: redaction.text,
            textHash: hash,
            redactionFlags: redaction.flags
        ))
        switch type {
        case .clipboard: stats.clipboardEvents += 1
        case .screenText, .audio: stats.screenEvents += 1
        }
        currentEpisode?.tsEnd = now
    }
}
