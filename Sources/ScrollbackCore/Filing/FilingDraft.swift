import Foundation

/// A composed Notion write awaiting the user's approval. Persisted to `filing_drafts`;
/// its STATUS LIFECYCLE is a load-bearing trust guarantee: a draft can only reach
/// `committed` from `approved`, so a Notion write can never happen without the user
/// approving it first (CLAUDE.md "approval always precedes commit"; tech-spec §3d — we
/// invert the Notion-AI committed-before-approval breach).
///
/// `payloadJSON` is the already-composed, schema-validated `NotionPageDraft` (built by
/// `NotionComposer` from validated fields) — OPAQUE to the approval queue, which never
/// re-inspects or mutates it. The queue only persists, lists, and transitions it.
public struct FilingDraft: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable, Codable, CaseIterable {
        case draft        // composed, awaiting the user
        case approved     // user approved — the courier may now commit it
        case committed    // written to Notion
        case dismissed    // user rejected — it can never commit
        case undone       // committed then archived (reversed via the write ledger)
    }

    public let id: UUID
    public let recipe: String            // the filing recipe that produced it (e.g. "daily_summary")
    public let createdAt: Date
    public let payloadJSON: String       // encoded NotionPageDraft — the exact Notion request body
    public let sourceEventIDs: [UUID]    // provenance: the captured events this draft summarizes
    public let contentHash: String?
    public let externalKey: String       // client-side idempotency (recipe:day:destination)
    public var status: Status
    public var committedAt: Date?
    public var externalSystem: String?   // e.g. "notion"
    public var externalID: String?       // the created Notion page id (for undo)

    public init(id: UUID = UUID(), recipe: String, createdAt: Date, payloadJSON: String,
                sourceEventIDs: [UUID] = [], contentHash: String? = nil, externalKey: String,
                status: Status = .draft, committedAt: Date? = nil,
                externalSystem: String? = nil, externalID: String? = nil) {
        self.id = id
        self.recipe = recipe
        self.createdAt = createdAt
        self.payloadJSON = payloadJSON
        self.sourceEventIDs = sourceEventIDs
        self.contentHash = contentHash
        self.externalKey = externalKey
        self.status = status
        self.committedAt = committedAt
        self.externalSystem = externalSystem
        self.externalID = externalID
    }
}

public enum FilingDraftError: Error, Equatable {
    case notFound(UUID)
    /// A status transition the lifecycle forbids (e.g. committing a draft that was
    /// never approved — the guarantee this error protects).
    case illegalTransition(from: FilingDraft.Status, to: FilingDraft.Status)
}
