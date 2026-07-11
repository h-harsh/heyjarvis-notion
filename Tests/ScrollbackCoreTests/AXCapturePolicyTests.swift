import XCTest
@testable import ScrollbackCore

/// Automated regression guard for the never-read-secure-fields invariant.
/// The AX walker itself needs a TCC grant and can't run in CI, so the decision
/// lives in this pure policy — and a broken guard (the original bug: checking
/// role instead of subrole) fails here instead of leaking passwords to disk.
final class AXCapturePolicyTests: XCTestCase {

    func testPasswordFieldReportedViaSubroleIsSecure() {
        // The real shape of a password field: role AXTextField, subrole AXSecureTextField.
        XCTAssertTrue(AXCapturePolicy.isSecureField(role: "AXTextField", subrole: "AXSecureTextField"))
    }

    func testSecureRoleIsSecure() {
        XCTAssertTrue(AXCapturePolicy.isSecureField(role: "AXSecureTextField", subrole: nil))
    }

    func testOrdinaryTextFieldIsNotSecure() {
        XCTAssertFalse(AXCapturePolicy.isSecureField(role: "AXTextField", subrole: nil))
        XCTAssertFalse(AXCapturePolicy.isSecureField(role: "AXStaticText", subrole: "AXContentText"))
        XCTAssertFalse(AXCapturePolicy.isSecureField(role: nil, subrole: nil))
    }
}
