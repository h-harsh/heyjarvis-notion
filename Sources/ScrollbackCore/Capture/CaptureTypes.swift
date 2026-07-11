import Foundation
import CryptoKit

/// The frontmost app/window context a capture is attributed to.
public struct FrontmostContext: Sendable, Equatable {
    public let pid: Int32
    public let bundleID: String
    public let appName: String
    public let windowTitle: String?

    /// Episode identity: a change of this key opens a new episode.
    public var key: String { bundleID + "|" + (windowTitle ?? "") }

    public init(pid: Int32, bundleID: String, appName: String, windowTitle: String?) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

/// A text snapshot plus how it was obtained. Returning `source`/`confidence`
/// (rather than a bare `String`) lets the imminent OCR-fallback provider label
/// its output honestly instead of the engine hardcoding `.ax` — OCR/ASR text
/// carries semantic noise and must be distinguishable for ranking.
public struct CapturedText: Sendable, Equatable {
    public let text: String
    public let source: CaptureSource
    public let confidence: Double

    public init(text: String, source: CaptureSource, confidence: Double = 1.0) {
        self.text = text
        self.source = source
        self.confidence = confidence
    }
}

/// Reads the current on-screen text for a context. The real implementation is
/// the AX-tree walker in scrollbackd; tests and `scrollbackd simulate` inject
/// fixtures — that split is what makes the capture engine verifiable headless
/// (no TCC grant in CI).
public protocol TextSnapshotProvider: AnyObject {
    func snapshot(for context: FrontmostContext) -> CapturedText?
}

/// Receives the engine's output. JSONL file in the spike; the encrypted store later.
public protocol CaptureEventSink: AnyObject {
    func episodeOpened(_ episode: Episode)
    func episodeClosed(_ episode: Episode)
    func event(_ event: CaptureEvent)
}

public struct CaptureConfig: Sendable {
    /// Quiet period after the last text-change signal before capturing.
    public var typingDebounce: TimeInterval
    /// No user activity for this long → idle: close the episode, suppress capture.
    public var idleThreshold: TimeInterval
    /// While the user is active, allow at most one capture attempt this often
    /// even without a text-change signal — and ONLY if there was real user
    /// activity since the last capture (see CaptureEngine.tick). This keeps it
    /// event/activity-driven, never a bare fixed-interval poll.
    public var fallbackInterval: TimeInterval
    /// Clipboard/raw text length cap.
    public var maxTextLength: Int

    public init(
        typingDebounce: TimeInterval = 2.0,
        idleThreshold: TimeInterval = 300,
        fallbackInterval: TimeInterval = 30,
        maxTextLength: Int = 200_000
    ) {
        self.typingDebounce = typingDebounce
        self.idleThreshold = idleThreshold
        self.fallbackInterval = fallbackInterval
        self.maxTextLength = maxTextLength
    }
}

/// Counters the engine maintains — the observable surface `scrollbackd simulate`
/// self-asserts against and the volume instrumentation builds on.
public struct CaptureStats: Sendable, Equatable {
    public var episodesOpened = 0
    public var episodesClosed = 0
    public var screenEvents = 0
    public var clipboardEvents = 0
    public var dedupSkips = 0
    public var providerCalls = 0
    /// Provider calls made while idle. Invariant: stays 0 — idle runs zero capture cycles.
    public var idleProviderCalls = 0

    public init(
        episodesOpened: Int = 0,
        episodesClosed: Int = 0,
        screenEvents: Int = 0,
        clipboardEvents: Int = 0,
        dedupSkips: Int = 0,
        providerCalls: Int = 0,
        idleProviderCalls: Int = 0
    ) {
        self.episodesOpened = episodesOpened
        self.episodesClosed = episodesClosed
        self.screenEvents = screenEvents
        self.clipboardEvents = clipboardEvents
        self.dedupSkips = dedupSkips
        self.providerCalls = providerCalls
        self.idleProviderCalls = idleProviderCalls
    }

    public var summary: String {
        "episodes_opened=\(episodesOpened) episodes_closed=\(episodesClosed) "
            + "screen_events=\(screenEvents) clipboard_events=\(clipboardEvents) "
            + "dedup_skips=\(dedupSkips) provider_calls=\(providerCalls) "
            + "idle_provider_calls=\(idleProviderCalls)"
    }
}

/// Policy for which AX nodes' text may be read. Pure + public so the
/// never-read-secure-fields invariant has an automated regression test
/// (the AX walker itself needs a TCC grant and can't run in CI).
public enum AXCapturePolicy {
    /// A password/secure field reports "AXSecureTextField" as its SUBROLE
    /// (role stays "AXTextField"); some native fields report it as ROLE. Treat
    /// either as secure and never read the value or its subtree.
    public static let secureTextFieldMarker = "AXSecureTextField"

    public static func isSecureField(role: String?, subrole: String?) -> Bool {
        role == secureTextFieldMarker || subrole == secureTextFieldMarker
    }
}

/// Whitespace-normalization + hashing used for capture-time dedup.
public enum TextNormalizer {
    /// Collapses all whitespace runs to single spaces and trims.
    public static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }

    /// SHA-256 hex of the normalized text (`events.text_hash`).
    public static func hash(_ normalizedText: String) -> String {
        SHA256.hash(data: Data(normalizedText.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
