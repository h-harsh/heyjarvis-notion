import XCTest
@testable import ScrollbackCore

/// Guards dual-timestamp extraction: a chunk captured on day X that refers to an
/// event on day Y must resolve `ts_event` = Y (relative to the CAPTURE time, not
/// wall-clock now), while text with no date reference resolves nil.
final class EventTimeExtractorTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private lazy var calendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return cal
    }()
    private lazy var extractor = EventTimeExtractor(timeZone: utc)

    /// Local-midnight date.
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    // 2026-01-05 is a Monday; capture at 10:00 so start-of-day differs from capture.
    private lazy var capturedMonday = calendar.date(
        from: DateComponents(year: 2026, month: 1, day: 5, hour: 10)
    )!

    private func event(_ text: String) -> Date? {
        extractor.eventTime(in: text, capturedAt: capturedMonday)
    }

    // MARK: The DoD case — weekday relative to capture

    func testWeekdayResolvesRelativeToCaptureDay() {
        // "moved to Friday" said Monday Jan 5 → Friday Jan 9.
        XCTAssertEqual(event("let's move standup to Friday"), day(2026, 1, 9))
    }

    func testWeekdayTodayResolvesToToday() {
        // Captured Monday; "Monday" → today (soonest occurrence ≥ capture day).
        XCTAssertEqual(event("ship it Monday"), day(2026, 1, 5))
    }

    func testNextWeekdayIsFollowingWeek() {
        XCTAssertEqual(event("demo next Friday"), day(2026, 1, 16))
    }

    func testLastWeekdayIsPreviousOccurrence() {
        // From Monday Jan 5, "last Friday" is Jan 2.
        XCTAssertEqual(event("we discussed this last Friday"), day(2026, 1, 2))
    }

    // MARK: Relative day words

    func testTomorrowAndYesterdayAndToday() {
        XCTAssertEqual(event("due tomorrow"), day(2026, 1, 6))
        XCTAssertEqual(event("filed yesterday"), day(2026, 1, 4))
        XCTAssertEqual(event("do it today"), day(2026, 1, 5))
    }

    // MARK: Absolute dates

    func testISODate() {
        XCTAssertEqual(event("hearing on 2026-07-15 downtown"), day(2026, 7, 15))
        XCTAssertEqual(event("hearing on 2026/07/15 downtown"), day(2026, 7, 15))
    }

    func testMonthNameDateWithAndWithoutYear() {
        XCTAssertEqual(event("kickoff July 15, 2027"), day(2027, 7, 15))
        XCTAssertEqual(event("kickoff on Jul 15"), day(2026, 7, 15)) // undated, still future this year
        XCTAssertEqual(event("kickoff 15 July"), day(2026, 7, 15))   // day-then-month order
    }

    func testUndatedMonthNameRollsToNextYearWhenPast() {
        // Captured Jan 5 2026; "January 3" already passed this year → next year.
        XCTAssertEqual(event("renewal January 3"), day(2027, 1, 3))
    }

    // MARK: Precision — no false positives

    func testNoDateReferenceReturnsNil() {
        XCTAssertNil(event("just some notes about the build"))
        XCTAssertNil(event("call 5 people about 3 things"))
        XCTAssertNil(event("version 2.0.1 and port 8080"))
        XCTAssertNil(event("the 2020s were a wild decade"))
    }

    func testInvalidDateIsRejected() {
        // Round-trip validation kills impossible dates; no other pattern matches → nil.
        XCTAssertNil(event("code 2026-13-45 error"))
        XCTAssertNil(event("Feb 30 never happens"))
    }

    // MARK: Reading order — earliest reference wins

    func testEarliestReferenceWins() {
        // "tomorrow" precedes the ISO date → the event time is tomorrow.
        XCTAssertEqual(event("see you tomorrow, deadline is 2026-07-15"), day(2026, 1, 6))
    }

    func testAbsoluteWinsTieByPriority() {
        // Both anchored at the very start conceptually; the ISO (absolute) date is
        // earlier in the string here, so it simply wins by location.
        XCTAssertEqual(event("2026-07-15 is the Friday deadline"), day(2026, 7, 15))
    }

    // MARK: Determinism

    func testDeterministicAcrossCalls() {
        let a = event("move it to Friday")
        let b = event("move it to Friday")
        XCTAssertEqual(a, b)
        XCTAssertNotNil(a)
    }
}
