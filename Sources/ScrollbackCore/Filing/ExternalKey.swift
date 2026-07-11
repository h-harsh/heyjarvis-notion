import Foundation
import CryptoKit

/// Client-side idempotency key for a filing draft (`filing_drafts.external_key
/// UNIQUE`). Notion has no idempotency keys (verified), so re-filing must dedup on
/// OUR side: the same logical write — one recipe's output for one calendar day to
/// one destination — must derive the SAME key every run, so the UNIQUE constraint
/// returns the prior draft instead of creating a second Notion page. The write
/// ledger's retry then appends to the existing page rather than re-creating it.
///
/// Pure + deterministic given the injected timezone (the "day" is the user's local
/// day — a digest at 00:30 belongs to that date, resolved in the user's zone).
public enum ExternalKey {

    /// The idempotency key for a draft. Human-readable `recipe:YYYY-MM-DD` prefix
    /// (so the dedup is debuggable) plus a hash suffix that folds in the destination
    /// (and the full canonical form) to disambiguate + bound the length.
    public static func forDraft(
        recipe: String,
        date: Date,
        destination: String,
        timeZone: TimeZone = .current
    ) -> String {
        let day = dayKey(date, timeZone: timeZone)
        // Unit-separator-joined canonical form — recipe/destination can't collide by
        // concatenation (e.g. "a"+"bc" vs "ab"+"c").
        let canonical = [recipe, day, destination].joined(separator: "\u{1F}")
        return "\(recipe):\(day):\(sha256Hex(canonical).prefix(16))"
    }

    /// `YYYY-MM-DD` in the given timezone — locale-independent (built from
    /// `DateComponents`, not a `DateFormatter`).
    static func dayKey(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func sha256Hex(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
