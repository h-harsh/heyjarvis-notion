import Foundation

/// Trust label carried by every captured item, end to end.
///
/// Load-bearing invariant: ambient capture is DATA, never instructions to the
/// filing agent. This tag flows through embedding, storage, retrieval, and into
/// MCP tool results (where untrusted spans are spotlighted). See CLAUDE.md and
/// docs/decisions.md (filing agents). The default for anything captured off the
/// screen or mic is `.untrustedAmbient` — never change that default lightly.
public enum Provenance: String, Codable, Sendable, CaseIterable {
    case untrustedAmbient = "untrusted_ambient"
    case userInput = "user_input"
    case system = "system"
}

/// Where a span of text came from. Used as a retrieval-ranking feature: AX text
/// is near-lossless, whereas OCR/ASR carry semantic noise that embeddings inherit,
/// so AX chunks are preferred when de-duplicating near-identical text.
public enum CaptureSource: String, Codable, Sendable, CaseIterable {
    case ax   // Accessibility tree (primary)
    case ocr  // Apple Vision fallback
    case asr  // audio transcription
}

public enum CaptureEventType: String, Codable, Sendable, CaseIterable {
    case screenText = "screen_text"
    case audio
    case clipboard
}

/// A contiguous span of activity in one app/window context. Episode boundaries
/// come from app/window switches, idle gaps, and content-shift signals.
public struct Episode: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var tsStart: Date
    public var tsEnd: Date
    public var bundleID: String
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    public var summary: String?
    public var entityKeys: [String]

    public init(
        id: UUID = UUID(),
        tsStart: Date,
        tsEnd: Date,
        bundleID: String,
        appName: String,
        windowTitle: String? = nil,
        url: String? = nil,
        summary: String? = nil,
        entityKeys: [String] = []
    ) {
        self.id = id
        self.tsStart = tsStart
        self.tsEnd = tsEnd
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.summary = summary
        self.entityKeys = entityKeys
    }
}

/// A single captured observation within an episode.
public struct CaptureEvent: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var episodeID: Episode.ID
    public var ts: Date
    public var type: CaptureEventType
    public var source: CaptureSource
    public var confidence: Double
    /// Text as stored — already redacted (high-risk secrets masked) at capture
    /// time. `rawText` is the persisted form, not the pre-redaction original.
    public var rawText: String
    /// SHA-256 (hex) of the normalized text — the capture-time dedup probe
    /// (mirrors `events.text_hash` in the schema).
    public var textHash: String?
    /// Which categories of secret were masked in `rawText` (mirrors
    /// `events.redaction_flags`). Empty = nothing redacted.
    public var redactionFlags: RedactionFlags
    /// Defaults to `.untrustedAmbient` — the security invariant. Callers that
    /// have genuinely trusted input must set it explicitly.
    public var provenance: Provenance

    public init(
        id: UUID = UUID(),
        episodeID: Episode.ID,
        ts: Date,
        type: CaptureEventType,
        source: CaptureSource,
        confidence: Double = 1.0,
        rawText: String,
        textHash: String? = nil,
        redactionFlags: RedactionFlags = [],
        provenance: Provenance = .untrustedAmbient
    ) {
        self.id = id
        self.episodeID = episodeID
        self.ts = ts
        self.type = type
        self.source = source
        self.confidence = confidence
        self.rawText = rawText
        self.textHash = textHash
        self.redactionFlags = redactionFlags
        self.provenance = provenance
    }
}

/// An embeddable unit of text derived from one or more events.
///
/// `modelID`/`dim` are nil until the chunk is embedded; recording them per-row
/// is what lets a future embedding-model change re-embed lazily instead of
/// rewriting history (see docs/decisions.md, embeddings).
public struct Chunk: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public var episodeID: Episode.ID
    public var eventID: CaptureEvent.ID
    public var text: String
    public var tokenCount: Int
    public var tsCapture: Date
    public var tsEvent: Date?
    public var source: CaptureSource
    public var modelID: String?
    public var dim: Int?

    public init(
        id: UUID = UUID(),
        episodeID: Episode.ID,
        eventID: CaptureEvent.ID,
        text: String,
        tokenCount: Int,
        tsCapture: Date,
        tsEvent: Date? = nil,
        source: CaptureSource,
        modelID: String? = nil,
        dim: Int? = nil
    ) {
        self.id = id
        self.episodeID = episodeID
        self.eventID = eventID
        self.text = text
        self.tokenCount = tokenCount
        self.tsCapture = tsCapture
        self.tsEvent = tsEvent
        self.source = source
        self.modelID = modelID
        self.dim = dim
    }

    /// True once this chunk has an embedding recorded.
    public var isEmbedded: Bool { modelID != nil && dim != nil }
}
