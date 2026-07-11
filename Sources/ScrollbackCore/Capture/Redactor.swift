import Foundation

/// What kind of sensitive content a redaction masked. Persisted as a bitmask in
/// `events.redaction_flags` — it records WHAT was masked, never the value, so the
/// UI/telemetry-free counters can say "3 secrets masked today" without storing
/// any secret. Purely additive; a user/exclusion-supplied rule contributes `.custom`.
public struct RedactionFlags: OptionSet, Sendable, Equatable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let apiKey     = RedactionFlags(rawValue: 1 << 0) // tokens, access keys
    public static let privateKey = RedactionFlags(rawValue: 1 << 1) // PEM private-key blocks
    public static let creditCard = RedactionFlags(rawValue: 1 << 2) // Luhn-valid PANs
    public static let custom     = RedactionFlags(rawValue: 1 << 3) // user/exclusion rule
}

extension RedactionFlags: Codable {
    // Serialize as a bare Int to mirror the `redaction_flags INT` column.
    public init(from decoder: Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(Int.self))
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// The outcome of redacting one span of text: the masked text plus which flags
/// fired. Pure value type so the whole redaction pass is deterministic + testable.
public struct RedactionResult: Sendable, Equatable {
    public let text: String
    public let flags: RedactionFlags
    public init(text: String, flags: RedactionFlags) {
        self.text = text
        self.flags = flags
    }
    public var didRedact: Bool { !flags.isEmpty }
}

/// One redaction rule: a compiled pattern, the flag it contributes, and an
/// optional validator to cut false positives (e.g. Luhn on card-number-shaped
/// digit runs). Matching spans are replaced by `[redacted:<name>]`, leaving the
/// surrounding text intact (the M1 DoD).
///
/// `@unchecked Sendable`: `NSRegularExpression` is documented immutable + thread
/// safe and `validate` is `@Sendable`, so a rule can live in a `static let`.
public struct RedactionRule: @unchecked Sendable {
    public let name: String
    public let flag: RedactionFlags
    private let regex: NSRegularExpression
    private let validate: (@Sendable (String) -> Bool)?
    /// Cheap literal pre-gate: the (potentially expensive) regex only runs if the
    /// span contains ALL of these substrings. This makes a rule fail fast on the
    /// common no-match case and — critically — defuses the private-key rule's
    /// worst case: a span with thousands of `-----BEGIN…PRIVATE KEY-----` markers
    /// but no `-----END` (attacker-controlled on-screen text) is skipped by an
    /// O(n) `contains` scan instead of triggering the O(n²) regex backtrack.
    private let guardSubstrings: [String]

    public init(
        name: String,
        flag: RedactionFlags,
        pattern: String,
        options: NSRegularExpression.Options = [],
        guardSubstrings: [String] = [],
        validate: (@Sendable (String) -> Bool)? = nil
    ) throws {
        self.name = name
        self.flag = flag
        self.regex = try NSRegularExpression(pattern: pattern, options: options)
        self.guardSubstrings = guardSubstrings
        self.validate = validate
    }

    private var mask: String { "[redacted:\(name)]" }

    /// Masks every (validated) match, returning the new text and whether anything
    /// fired. Replacements run last-to-first so earlier match ranges stay valid.
    func apply(to text: String) -> (text: String, didHit: Bool) {
        for required in guardSubstrings where !text.contains(required) {
            return (text, false) // pre-gate: rule cannot match, skip the regex scan
        }
        let source = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: source.length))
        guard !matches.isEmpty else { return (text, false) }

        var result = source
        var hit = false
        for match in matches.reversed() {
            let matched = source.substring(with: match.range)
            if let validate, !validate(matched) { continue }
            result = result.replacingCharacters(in: match.range, with: mask) as NSString
            hit = true
        }
        return (result as String, hit)
    }
}

/// Capture-time redactor: the `capture → redact → chunk` stage. Applies a set of
/// rules to every captured span before it is stored, masking high-risk secrets
/// (credentials/tokens/PEM keys + Luhn-valid card numbers) so they never persist,
/// while leaving ordinary content — including the emails/names/context that ARE
/// the product's value — untouched. This is defense-in-depth, NOT a
/// perfect-redaction promise (see PRD): the store's real guarantee is on-device
/// encryption; this cuts the obvious secret leaks on top of that.
///
/// Not `Sendable` and not thread-safe by contract: it is driven synchronously by
/// the `CaptureEngine` on the main run loop, same as the rest of capture.
public final class Redactor {
    private let rules: [RedactionRule]

    public init(rules: [RedactionRule] = Redactor.defaultRules) {
        self.rules = rules
    }

    public func redact(_ text: String) -> RedactionResult {
        var masked = text
        var flags: RedactionFlags = []
        for rule in rules {
            let (next, hit) = rule.apply(to: masked)
            masked = next
            if hit { flags.insert(rule.flag) }
        }
        return RedactionResult(text: masked, flags: flags)
    }

    /// High-precision default rules. Deliberately narrow — every pattern is
    /// anchored to a recognizable secret shape (specific prefixes, PEM markers,
    /// or Luhn-validated PANs) to avoid masking ordinary text. PII (emails,
    /// phones, names) is intentionally NOT redacted: it is the ambient-memory
    /// signal the product exists to keep.
    public static let defaultRules: [RedactionRule] = [
        // PEM private-key blocks (RSA/EC/OpenSSH/PGP). The header classes and the
        // body gap are BOUNDED (not `*`) and the rule is pre-gated on both markers
        // so a BEGIN-flood with no END can't drive an O(n²) scan-to-EOF; a real key
        // body (a few KB) fits comfortably in 8192 chars.
        try! RedactionRule(
            name: "privateKey", flag: .privateKey,
            pattern: #"-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----[\s\S]{0,8192}?-----END [A-Z0-9 ]{0,40}PRIVATE KEY-----"#,
            guardSubstrings: ["-----BEGIN", "-----END"]
        ),
        // OpenAI/Anthropic-style secret keys (sk-…, sk-ant-…).
        try! RedactionRule(name: "apiKey", flag: .apiKey, pattern: #"\bsk-[A-Za-z0-9_-]{16,}\b"#),
        // GitHub personal/OAuth/app tokens.
        try! RedactionRule(name: "githubToken", flag: .apiKey, pattern: #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        // AWS access key IDs.
        try! RedactionRule(name: "awsAccessKey", flag: .apiKey, pattern: #"\bAKIA[0-9A-Z]{16}\b"#),
        // Google API keys.
        try! RedactionRule(name: "googleApiKey", flag: .apiKey, pattern: #"\bAIza[0-9A-Za-z_-]{35}\b"#),
        // Slack tokens.
        try! RedactionRule(name: "slackToken", flag: .apiKey, pattern: #"\bxox[baprs]-[A-Za-z0-9-]{10,}\b"#),
        // JWTs (three base64url segments; the eyJ prefix is base64 of `{"`).
        try! RedactionRule(
            name: "jwt", flag: .apiKey,
            pattern: #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"#
        ),
        // Card-number-shaped digit runs (13–19 digits, optional space/dash groups),
        // masked ONLY if they contain a Luhn-valid PAN — cuts order numbers/IDs.
        try! RedactionRule(
            name: "creditCard", flag: .creditCard,
            pattern: #"\b\d(?:[ -]?\d){12,18}\b"#,
            validate: { Redactor.isRedactableCardRun($0) }
        ),
    ]

    /// True if the digits in `candidate` (separators ignored) are 13–19 long and
    /// satisfy the Luhn checksum.
    public static func isLuhnValid(_ candidate: String) -> Bool {
        luhnCheck(candidate.compactMap { $0.wholeNumberValue })
    }

    /// Whether a matched digit run should be masked as a card. If its length is a
    /// standard PAN length (13/14/15/16/19) it must Luhn-validate as-is — keeping
    /// precision high for exact-length runs (a 16-digit non-card ID is left alone).
    /// A non-standard length (17/18) means the greedy regex absorbed 1–2 adjacent
    /// digits, so we also check the standard-length prefixes/suffixes; this masks
    /// "4111 1111 1111 1111 2" (card + stray digit) instead of leaking the PAN.
    static func isRedactableCardRun(_ candidate: String) -> Bool {
        let digits = candidate.compactMap { $0.wholeNumberValue }
        let standardLengths: Set<Int> = [13, 14, 15, 16, 19]
        if standardLengths.contains(digits.count) {
            return luhnCheck(digits)
        }
        // Card with a few stray adjacent digits: does a standard-length window at
        // either end validate?
        for length in [16, 15, 13] where length < digits.count {
            if luhnCheck(Array(digits.prefix(length))) || luhnCheck(Array(digits.suffix(length))) {
                return true
            }
        }
        return false
    }

    private static func luhnCheck(_ digits: [Int]) -> Bool {
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (index, digit) in digits.reversed().enumerated() {
            if index % 2 == 1 {
                let doubled = digit * 2
                sum += doubled > 9 ? doubled - 9 : doubled
            } else {
                sum += digit
            }
        }
        return sum % 10 == 0
    }
}
