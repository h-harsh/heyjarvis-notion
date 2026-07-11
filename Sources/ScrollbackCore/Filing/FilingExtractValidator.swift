import Foundation

/// The validated output of the **quarantined extractor** — the CaMeL-style split
/// where the extractor sees ambient text but may emit ONLY this schema, and the
/// privileged composer builds Notion blocks from these fields WITHOUT ever seeing
/// the raw captured text (tech-spec §3d). The three arrays are the entire contract.
public struct FilingExtract: Codable, Sendable, Equatable {
    public var commitments: [Commitment]
    public var logEntries: [LogEntry]
    public var reading: [ReadingItem]

    public init(commitments: [Commitment] = [], logEntries: [LogEntry] = [], reading: [ReadingItem] = []) {
        self.commitments = commitments
        self.logEntries = logEntries
        self.reading = reading
    }

    enum CodingKeys: String, CodingKey {
        case commitments
        case logEntries = "log_entries"
        case reading
    }

    // Missing arrays decode to empty (an extract with only commitments is valid).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        commitments = try container.decodeIfPresent([Commitment].self, forKey: .commitments) ?? []
        logEntries = try container.decodeIfPresent([LogEntry].self, forKey: .logEntries) ?? []
        reading = try container.decodeIfPresent([ReadingItem].self, forKey: .reading) ?? []
    }

    public struct Commitment: Codable, Sendable, Equatable {
        public let text: String
        public let due: Date?
        public init(text: String, due: Date? = nil) { self.text = text; self.due = due }
    }

    public struct LogEntry: Codable, Sendable, Equatable {
        public let text: String
        public let ts: Date?
        public init(text: String, ts: Date? = nil) { self.text = text; self.ts = ts }
    }

    public struct ReadingItem: Codable, Sendable, Equatable {
        public let title: String
        public let ts: Date?
        public init(title: String, ts: Date? = nil) { self.title = title; self.ts = ts }
    }

    var isEmpty: Bool { commitments.isEmpty && logEntries.isEmpty && reading.isEmpty }
}

public enum FilingValidation: Sendable, Equatable {
    case valid(FilingExtract)
    case rejected(reason: String)
}

/// Validates the quarantined extractor's raw JSON into a `FilingExtract`, fail-closed.
/// This is the write-side prompt-injection boundary: the extractor's output saw
/// untrusted ambient text, so it is treated as untrusted until it passes STRICT
/// schema validation — "rejected on any schema violation" (tech-spec §3d) — and it
/// must carry NO URLs/images, the verified Notion exfiltration channel (§3c). What
/// survives is plain structured fields the composer can safely render.
public enum FilingExtractValidator {

    public struct Limits: Sendable {
        public var maxItemsPerArray: Int
        public var maxTextLength: Int
        public init(maxItemsPerArray: Int = 200, maxTextLength: Int = 2000) {
            self.maxItemsPerArray = maxItemsPerArray
            self.maxTextLength = maxTextLength
        }
    }

    private static let allowedKeys: Set<String> = ["commitments", "log_entries", "reading"]

    public static func validate(json: String, limits: Limits = Limits()) -> FilingValidation {
        guard let data = json.data(using: .utf8) else {
            return .rejected(reason: "payload is not valid UTF-8")
        }

        // 1. Must be a JSON object; STRICT top-level keys (unknown key → reject whole
        //    extract). An extractor emitting anything outside the schema is untrusted.
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .rejected(reason: "payload is not a JSON object")
        }
        for key in object.keys where !allowedKeys.contains(key) {
            return .rejected(reason: "unknown field: \(key)")
        }

        // 2. Defense-in-depth: literal URL anywhere in the RAW payload. Catches a URL
        //    smuggled into a field Codable would ignore (never reaches the decoded
        //    scan below). NOT authoritative on its own — JSON `\uXXXX`/`\/` escapes let
        //    a URL hide from a raw-string scan yet decode into a live link, so the
        //    real gate is the DECODED-value scan in step 4.
        if let hit = firstURLLike(in: json) {
            return .rejected(reason: "contains a URL/exfil pattern: \(hit)")
        }

        // 3. Decode the known fields strictly (wrong types → reject).
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let extract: FilingExtract
        do {
            extract = try decoder.decode(FilingExtract.self, from: data)
        } catch {
            return .rejected(reason: "malformed schema: \(error)")
        }

        // 4. Bounds + non-empty content + AUTHORITATIVE exfil scan on the DECODED
        //    values — this is the string the composer actually renders, so a URL that
        //    survived JSON escaping as `https:\/\/evil.com` is caught here after the
        //    decoder resolves it to `https://evil.com`.
        if extract.commitments.count > limits.maxItemsPerArray
            || extract.logEntries.count > limits.maxItemsPerArray
            || extract.reading.count > limits.maxItemsPerArray {
            return .rejected(reason: "array exceeds \(limits.maxItemsPerArray) items")
        }
        for text in extract.commitments.map(\.text) + extract.logEntries.map(\.text) + extract.reading.map(\.title) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return .rejected(reason: "empty text field") }
            if text.count > limits.maxTextLength { return .rejected(reason: "text exceeds \(limits.maxTextLength) chars") }
            if let hit = firstURLLike(in: text) {
                return .rejected(reason: "decoded field contains a URL/exfil pattern: \(hit)")
            }
        }

        return .valid(extract)
    }

    // MARK: - Exfil scan

    private static let urlPattern = try! NSRegularExpression( // swiftlint:disable:this force_try
        pattern: #"(?i)(https?://|www\.|\bdata:[^\s]|\bjavascript:|\bfile:/|!\[|\]\()"#
    )

    /// The first URL/image/active-scheme fragment in `text`, or nil. Denylist +
    /// defense-in-depth (mirrors the redactor): occasional false-reject is fine —
    /// the extractor re-runs and no user data is lost (this is a digest, not capture).
    /// Residual: a BARE domain with no scheme/www (`evil.com`) is not matched — the
    /// composer renders these fields as plain Notion rich-text (non-clickable via the
    /// API unless a `link` is explicitly set, which it never is), and catching all
    /// bare domains would over-reject legitimate "reading" titles. Scheme/markdown/
    /// image forms — the clickable/loadable exfil shapes — ARE caught.
    static func firstURLLike(in text: String) -> String? {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard let match = urlPattern.firstMatch(in: text, range: range) else { return nil }
        return (text as NSString).substring(with: match.range)
    }
}
