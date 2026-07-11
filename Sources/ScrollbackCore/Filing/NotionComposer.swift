import Foundation

/// A Notion block in the create-page payload. Deliberately a CLOSED set of
/// plain-text block kinds — there is no case that carries a link or an image, so
/// the composer structurally cannot emit the verified exfil channels (tech-spec §3c).
/// `encode(to:)` emits the Notion REST block shape (API 2025-09-03+).
public enum NotionBlock: Sendable, Equatable {
    case heading(String)
    case bulleted(String)
    case todo(text: String, checked: Bool)
    case paragraph(String)

    var notionType: String {
        switch self {
        case .heading: return "heading_2"
        case .bulleted: return "bulleted_list_item"
        case .todo: return "to_do"
        case .paragraph: return "paragraph"
        }
    }
}

extension NotionBlock: Encodable {
    private enum TopKeys: String, CodingKey { case object, type }
    private struct Dynamic: CodingKey {
        let stringValue: String
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        var intValue: Int? { nil }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        var top = encoder.container(keyedBy: TopKeys.self)
        try top.encode("block", forKey: .object)
        try top.encode(notionType, forKey: .type)

        var payload = encoder.container(keyedBy: Dynamic.self)
        var body = payload.nestedContainer(keyedBy: Dynamic.self, forKey: Dynamic(notionType))
        switch self {
        case .heading(let text), .bulleted(let text), .paragraph(let text):
            try body.encode([NotionRichText(text)], forKey: Dynamic("rich_text"))
        case .todo(let text, let checked):
            try body.encode([NotionRichText(text)], forKey: Dynamic("rich_text"))
            try body.encode(checked, forKey: Dynamic("checked"))
        }
    }
}

/// A Notion rich-text run. Plain text only — NO `link` field is ever set, so the
/// text renders as non-clickable content via the API even if it mentions a domain.
public struct NotionRichText: Encodable, Equatable {
    public let type = "text"
    public let text: Content
    public struct Content: Encodable, Equatable { public let content: String }
    public init(_ content: String) { self.text = Content(content: content) }
    private enum CodingKeys: String, CodingKey { case type, text }
}

/// The page the courier will create (title + children blocks). No parent/destination
/// here — that's the courier's concern.
public struct NotionPageDraft: Encodable, Equatable {
    public let title: String
    public let children: [NotionBlock]
}

/// The **privileged composer** (tech-spec §3d): turns a VALIDATED `FilingExtract`
/// into Notion blocks. It never sees raw captured text — its input is the schema
/// object the quarantined extractor produced and `FilingExtractValidator` cleared —
/// and it can only build the closed set of plain-text blocks above, so it cannot
/// introduce a URL/image. Pure + deterministic (injected timezone for due dates).
public enum NotionComposer {

    public static func compose(_ extract: FilingExtract, title: String, timeZone: TimeZone = .current) -> NotionPageDraft {
        var children: [NotionBlock] = []

        if !extract.commitments.isEmpty {
            children.append(.heading("Commitments"))
            for commitment in extract.commitments {
                let text = commitment.due.map { "\(commitment.text) (due \(dayString($0, timeZone: timeZone)))" } ?? commitment.text
                children.append(.todo(text: text, checked: false))
            }
        }
        if !extract.logEntries.isEmpty {
            children.append(.heading("Log"))
            for entry in extract.logEntries { children.append(.bulleted(entry.text)) }
        }
        if !extract.reading.isEmpty {
            children.append(.heading("Reading"))
            for item in extract.reading { children.append(.bulleted(item.title)) }
        }
        if children.isEmpty {
            children.append(.paragraph("No activity captured for this period."))
        }
        return NotionPageDraft(title: title, children: children)
    }

    private static func dayString(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
