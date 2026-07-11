import Foundation

/// Identifies one weekly shard file (`scrollback-2026-W28.sqlite`). Sharding by ISO
/// week is what makes "delete everything before X" a whole-file delete instead of a
/// row-by-row DELETE — instant and *provable* (the file is gone), which is the
/// privacy claim in CLAUDE.md / the PRD.
///
/// `year` is the ISO year-FOR-week (not the calendar year — the week of 2025-12-31
/// belongs to 2026-W01), so a shard id round-trips through `WeekShardCalendar`.
public struct WeekShard: Hashable, Comparable, Sendable, CustomStringConvertible {
    public let year: Int
    public let week: Int

    public init(year: Int, week: Int) {
        self.year = year
        self.week = week
    }

    /// `2026-W07` — zero-padded so lexical order == chronological order.
    public var id: String { String(format: "%04d-W%02d", year, week) }
    public var description: String { id }

    /// The shard's on-disk filename.
    public var fileName: String { "scrollback-\(id).sqlite" }

    /// Parse a shard id (or filename) back to a `WeekShard`.
    public static func from(id: String) -> WeekShard? {
        let core = id.hasPrefix("scrollback-")
            ? String(id.dropFirst("scrollback-".count)).replacingOccurrences(of: ".sqlite", with: "")
            : id
        let parts = core.split(separator: "-")
        guard parts.count == 2, parts[1].hasPrefix("W"),
              let year = Int(parts[0]), let week = Int(parts[1].dropFirst()) else { return nil }
        return WeekShard(year: year, week: week)
    }

    public static func < (lhs: WeekShard, rhs: WeekShard) -> Bool {
        (lhs.year, lhs.week) < (rhs.year, rhs.week)
    }
}

/// Maps dates ↔ ISO-week shards and answers the two routing questions the sharded
/// store needs: which shards a time range touches, and which shards are fully before
/// a purge cutoff (safe to drop). Pure + deterministic given the injected timezone
/// (tests pin UTC; the live store uses the user's zone so week boundaries fall at
/// the user's local midnight).
public struct WeekShardCalendar: Sendable {
    private let calendar: Calendar

    public init(timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .iso8601) // Monday-start, min 4 days in week 1
        calendar.timeZone = timeZone
        self.calendar = calendar
    }

    /// The shard a timestamp belongs to.
    public func shard(for date: Date) -> WeekShard {
        let parts = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        return WeekShard(year: parts.yearForWeekOfYear ?? 0, week: parts.weekOfYear ?? 0)
    }

    /// The `[Monday 00:00, next Monday 00:00)` half-open span the shard covers.
    public func range(of shard: WeekShard) -> Range<Date> {
        var components = DateComponents()
        components.weekOfYear = shard.week
        components.yearForWeekOfYear = shard.year
        components.weekday = calendar.firstWeekday // Monday
        let start = calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start
        return start..<end
    }

    /// Of `existing`, the shards whose week overlaps `range` (all of them when
    /// `range` is nil — an unscoped query must consult every shard).
    public func shards(intersecting range: ClosedRange<Date>?, among existing: [WeekShard]) -> [WeekShard] {
        guard let range else { return existing.sorted() }
        return existing.filter { shard in
            let span = self.range(of: shard)
            return span.lowerBound <= range.upperBound && span.upperBound > range.lowerBound
        }.sorted()
    }

    /// Of `existing`, the shards whose ENTIRE week is before `cutoff` — safe to drop
    /// for "purge before X". The boundary shard that straddles `cutoff` is retained
    /// (purge granularity is the week; a dropped shard's data is provably gone).
    public func droppable(before cutoff: Date, among existing: [WeekShard]) -> [WeekShard] {
        existing.filter { range(of: $0).upperBound <= cutoff }.sorted()
    }
}
