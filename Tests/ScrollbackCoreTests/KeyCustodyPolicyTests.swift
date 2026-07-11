import XCTest
@testable import ScrollbackCore

/// Regression guard for the DB-key custody policy — the testable half of the
/// infostealer defense. (The "stolen key file alone cannot unwrap" half is the
/// Secure-Enclave hardware property, verified manually on a signed build.)
final class KeyCustodyPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ s: TimeInterval) -> Date { t0.addingTimeInterval(s) }

    func testStartsLocked() {
        let policy = KeyCustodyPolicy()
        XCTAssertEqual(policy.access(at: t0), .locked)
        XCTAssertFalse(policy.isUnlocked(at: t0))
    }

    func testGrantedWithinSession() {
        let policy = KeyCustodyPolicy(config: KeyCustodyConfig(sessionTimeout: 100))
        policy.recordUnlock(at: t0)
        XCTAssertEqual(policy.access(at: at(50)), .granted)
        XCTAssertEqual(policy.access(at: at(99)), .granted)
    }

    func testExpiredSessionReturnsLocked() {
        // DoD: "expired session returns LOCKED".
        let policy = KeyCustodyPolicy(config: KeyCustodyConfig(sessionTimeout: 100))
        policy.recordUnlock(at: t0)
        XCTAssertEqual(policy.access(at: at(100)), .locked) // boundary is exclusive
        XCTAssertEqual(policy.access(at: at(101)), .locked)
    }

    func testManualLockDropsSession() {
        let policy = KeyCustodyPolicy(config: KeyCustodyConfig(sessionTimeout: 1000))
        policy.recordUnlock(at: t0)
        policy.lock()
        XCTAssertEqual(policy.access(at: at(1)), .locked)
    }

    func testHammeringTripsRateLimit() {
        // DoD: "hammering trips the limit".
        let policy = KeyCustodyPolicy(config: KeyCustodyConfig(maxUnwrapAttempts: 3, attemptWindow: 60))
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(0)))
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(1)))
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(2)))
        XCTAssertFalse(policy.permitUnlockAttempt(at: at(3))) // 4th within window → blocked
    }

    func testRateLimitWindowSlidesOpen() {
        let policy = KeyCustodyPolicy(config: KeyCustodyConfig(maxUnwrapAttempts: 2, attemptWindow: 60))
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(0)))
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(1)))
        XCTAssertFalse(policy.permitUnlockAttempt(at: at(2)))
        // Once the earliest attempts age out of the window, attempts are allowed again.
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(61)))
    }

    func testSuccessfulUnlockClearsAttemptHistory() {
        let policy = KeyCustodyPolicy(config: KeyCustodyConfig(maxUnwrapAttempts: 3, attemptWindow: 60))
        _ = policy.permitUnlockAttempt(at: at(0))
        _ = policy.permitUnlockAttempt(at: at(1))
        policy.recordUnlock(at: at(2)) // legitimate unlock resets the counter
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(3)))
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(4)))
        XCTAssertTrue(policy.permitUnlockAttempt(at: at(5)))
    }

    func testSecondsRemainingCountsDown() {
        let policy = KeyCustodyPolicy(config: KeyCustodyConfig(sessionTimeout: 100))
        XCTAssertEqual(policy.secondsRemaining(at: t0), 0) // locked
        policy.recordUnlock(at: t0)
        XCTAssertEqual(policy.secondsRemaining(at: at(30)), 70, accuracy: 0.001)
        XCTAssertEqual(policy.secondsRemaining(at: at(200)), 0, accuracy: 0.001)
    }
}
