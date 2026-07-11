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

    public private(set) var stats = CaptureStats()

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

    public init(provider: TextSnapshotProvider, sink: CaptureEventSink, config: CaptureConfig = CaptureConfig()) {
        self.provider = provider
        self.sink = sink
        self.config = config
    }

    // MARK: - Triggers

    /// App switch or window/title change (user activity).
    public func handleAppOrWindowChange(_ context: FrontmostContext, at now: Date) {
        noteActivity(at: now)
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
        ensureEpisode(context, at: now)
        let capped = String(content.prefix(config.maxTextLength))
        // Store the copied text verbatim (formatting can matter for a later
        // paste); dedup on its normalized form.
        emit(
            storeText: capped,
            hashText: TextNormalizer.normalize(capped),
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
        let episode = Episode(
            tsStart: now,
            tsEnd: now,
            bundleID: context.bundleID,
            appName: context.appName,
            windowTitle: context.windowTitle
        )
        currentEpisode = episode
        currentContext = context
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
        lastCaptureAttempt = now
        stats.providerCalls += 1
        if isIdle { stats.idleProviderCalls += 1 } // invariant: never happens

        guard let snapshot = provider.snapshot(for: context) else { return }
        let capped = String(snapshot.text.prefix(config.maxTextLength))
        let normalized = TextNormalizer.normalize(capped)
        emit(
            storeText: normalized,
            hashText: normalized,
            type: .screenText,
            source: snapshot.source,
            confidence: snapshot.confidence,
            dedupKey: context.key,
            at: now
        )
    }

    /// Single emit path shared by screen and clipboard capture: empty-guard →
    /// hash → per-episode dedup → sink → stats → advance tsEnd.
    private func emit(
        storeText: String,
        hashText: String,
        type: CaptureEventType,
        source: CaptureSource,
        confidence: Double,
        dedupKey: String,
        at now: Date
    ) {
        guard let episode = currentEpisode, !hashText.isEmpty else { return }
        let hash = TextNormalizer.hash(hashText)
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
            rawText: storeText,
            textHash: hash
        ))
        switch type {
        case .clipboard: stats.clipboardEvents += 1
        case .screenText, .audio: stats.screenEvents += 1
        }
        currentEpisode?.tsEnd = now
    }
}
