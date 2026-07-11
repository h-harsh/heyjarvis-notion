import XCTest
@testable import ScrollbackCore

/// Guards the client-side idempotency key: the same logical filing (recipe + day +
/// destination) must derive the same key so re-filing dedups instead of creating a
/// second Notion page.
final class ExternalKeyTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let t = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00:00 UTC

    private func key(_ recipe: String = "daily_summary", _ date: Date? = nil, _ dest: String = "notion-db-1") -> String {
        ExternalKey.forDraft(recipe: recipe, date: date ?? t, destination: dest, timeZone: utc)
    }

    func testDeterministicForSameInputs() {
        XCTAssertEqual(key(), key()) // re-filing the same day → identical key → dedup
    }

    func testSameDayDifferentTimeYieldsSameKey() {
        // Two runs of the day's digest at different clock times → same key.
        let morning = t
        let evening = t.addingTimeInterval(9 * 3600)
        XCTAssertEqual(key("daily_summary", morning), key("daily_summary", evening))
    }

    func testDifferentDayYieldsDifferentKey() {
        XCTAssertNotEqual(key("daily_summary", t), key("daily_summary", t.addingTimeInterval(86_400)))
    }

    func testDifferentRecipeOrDestinationYieldsDifferentKey() {
        XCTAssertNotEqual(key("daily_summary"), key("weekly_review"))
        XCTAssertNotEqual(key("daily_summary", t, "notion-db-1"), key("daily_summary", t, "notion-db-2"))
    }

    func testTimezoneDeterminesTheDay() {
        // 23:30 UTC is still the NEXT day in a +05:30 zone — the key's day rolls over.
        let lateUTC = Date(timeIntervalSince1970: 1_800_000_000)
            .addingTimeInterval(TimeInterval((23 - 8) * 3600 + 30 * 60)) // 23:30 UTC
        let ist = TimeZone(identifier: "Asia/Kolkata")!
        let utcKey = ExternalKey.forDraft(recipe: "daily_summary", date: lateUTC, destination: "d", timeZone: utc)
        let istKey = ExternalKey.forDraft(recipe: "daily_summary", date: lateUTC, destination: "d", timeZone: ist)
        XCTAssertNotEqual(utcKey, istKey)
    }

    func testKeyCarriesReadablePrefix() {
        // recipe:YYYY-MM-DD:<hash> — the prefix makes the dedup debuggable.
        let k = key("daily_summary", t, "notion-db-1")
        XCTAssertTrue(k.hasPrefix("daily_summary:2027-01-15:"), "unexpected key: \(k)")
    }

    func testConcatenationCannotCollide() {
        // Unit-separator join prevents (recipe="a", dest="bc") colliding with
        // (recipe="ab", dest="c").
        let a = ExternalKey.forDraft(recipe: "a", date: t, destination: "bc", timeZone: utc)
        let b = ExternalKey.forDraft(recipe: "ab", date: t, destination: "c", timeZone: utc)
        XCTAssertNotEqual(a, b)
    }
}
