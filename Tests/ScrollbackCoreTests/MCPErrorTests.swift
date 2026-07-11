import XCTest
@testable import ScrollbackCore

/// Guards the MCP recall-surface safety: structured errors and the anti-hammering
/// query throttle (RATE_LIMITED), distinct from the key-unwrap rate limit.
final class MCPErrorTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testErrorRawValuesMatchTheContract() {
        XCTAssertEqual(MCPError.locked.rawValue, "LOCKED")
        XCTAssertEqual(MCPError.rateLimited.rawValue, "RATE_LIMITED")
        XCTAssertEqual(MCPError.emptyRange.rawValue, "EMPTY_RANGE")
        for error in [MCPError.locked, .rateLimited, .emptyRange] {
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testThrottleAllowsUpToLimitThenBlocks() {
        let throttle = QueryThrottle(maxQueries: 3, window: 60)
        XCTAssertTrue(throttle.permit(at: at(0)))
        XCTAssertTrue(throttle.permit(at: at(1)))
        XCTAssertTrue(throttle.permit(at: at(2)))
        XCTAssertFalse(throttle.permit(at: at(3))) // 4th within window → RATE_LIMITED
    }

    func testThrottleWindowSlidesOpen() {
        let throttle = QueryThrottle(maxQueries: 2, window: 60)
        XCTAssertTrue(throttle.permit(at: at(0)))
        XCTAssertTrue(throttle.permit(at: at(1)))
        XCTAssertFalse(throttle.permit(at: at(2)))
        // Once the earliest served query ages out of the window, capacity returns.
        XCTAssertTrue(throttle.permit(at: at(61)))
    }

    func testRejectedQueriesDoNotConsumeCapacity() {
        // A blocked query isn't recorded, so it can't push the window further out —
        // capacity frees exactly `window` after the last SERVED query.
        let throttle = QueryThrottle(maxQueries: 1, window: 10)
        XCTAssertTrue(throttle.permit(at: at(0)))
        XCTAssertFalse(throttle.permit(at: at(5)))  // blocked, not recorded
        XCTAssertFalse(throttle.permit(at: at(9)))  // still within 10s of the served query at 0
        XCTAssertTrue(throttle.permit(at: at(11)))  // 11s after the served query → allowed
    }
}
