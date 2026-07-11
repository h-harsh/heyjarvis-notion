import XCTest
@testable import ScrollbackCore

/// Guards the ISO-week shard math that makes purge a provable whole-file delete.
final class WeekShardTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private lazy var cal = WeekShardCalendar(timeZone: utc)
    private lazy var iso: Calendar = {
        var c = Calendar(identifier: .iso8601); c.timeZone = utc; return c
    }()
    private func d(_ y: Int, _ m: Int, _ day: Int, _ h: Int = 12) -> Date {
        iso.date(from: DateComponents(year: y, month: m, day: day, hour: h))!
    }

    // MARK: id formatting / parsing

    func testIdFormatAndRoundTrip() {
        let shard = WeekShard(year: 2026, week: 7)
        XCTAssertEqual(shard.id, "2026-W07")
        XCTAssertEqual(shard.fileName, "scrollback-2026-W07.sqlite")
        XCTAssertEqual(WeekShard.from(id: "2026-W07"), shard)
        XCTAssertEqual(WeekShard.from(id: "scrollback-2026-W07.sqlite"), shard)
        XCTAssertNil(WeekShard.from(id: "not-a-shard"))
        XCTAssertNil(WeekShard.from(id: "2026-07"))
    }

    func testLexicalOrderIsChronological() {
        XCTAssertLessThan(WeekShard(year: 2026, week: 2), WeekShard(year: 2026, week: 10))
        XCTAssertLessThan(WeekShard(year: 2025, week: 52), WeekShard(year: 2026, week: 1))
        // Zero-padding keeps string order aligned with chronological order.
        XCTAssertLessThan(WeekShard(year: 2026, week: 2).id, WeekShard(year: 2026, week: 10).id)
    }

    // MARK: date → shard (ISO rules)

    func testShardForDateUsesISOWeek() {
        // 2026-01-05 is a Monday; ISO week 1 is Dec 29 2025–Jan 4 2026, so this is W02.
        XCTAssertEqual(cal.shard(for: d(2026, 1, 5)), WeekShard(year: 2026, week: 2))
    }

    func testYearForWeekCrossesCalendarYear() {
        // 2025-12-31 (Wed) falls in the ISO week that owns Jan 1 2026 → 2026-W01,
        // NOT 2025-W53. This is the year-FOR-week subtlety.
        XCTAssertEqual(cal.shard(for: d(2025, 12, 31)), WeekShard(year: 2026, week: 1))
    }

    // MARK: shard → range

    func testRangeIsTheMondayToMondayWeek() {
        let range = cal.range(of: WeekShard(year: 2026, week: 2))
        XCTAssertEqual(range.lowerBound, d(2026, 1, 5, 0)) // Monday 00:00
        XCTAssertEqual(range.upperBound, d(2026, 1, 12, 0)) // next Monday 00:00
    }

    // MARK: routing

    func testShardsIntersectingRange() {
        let existing = [WeekShard(year: 2026, week: 1), WeekShard(year: 2026, week: 2), WeekShard(year: 2026, week: 3)]
        // A range wholly inside W02.
        let hit = cal.shards(intersecting: d(2026, 1, 6)...d(2026, 1, 8), among: existing)
        XCTAssertEqual(hit, [WeekShard(year: 2026, week: 2)])
        // nil range → all shards.
        XCTAssertEqual(cal.shards(intersecting: nil, among: existing), existing)
    }

    func testDroppableBeforeCutoff() {
        let existing = [WeekShard(year: 2026, week: 1), WeekShard(year: 2026, week: 2), WeekShard(year: 2026, week: 3)]
        // Cutoff at the start of W03 → W01 and W02 are fully before it; W03 straddles/after.
        let cutoff = cal.range(of: WeekShard(year: 2026, week: 3)).lowerBound
        XCTAssertEqual(cal.droppable(before: cutoff, among: existing),
                       [WeekShard(year: 2026, week: 1), WeekShard(year: 2026, week: 2)])
        // A cutoff mid-W02 keeps W02 (its week isn't ENTIRELY before the cutoff).
        XCTAssertEqual(cal.droppable(before: d(2026, 1, 7), among: existing),
                       [WeekShard(year: 2026, week: 1)])
    }
}
