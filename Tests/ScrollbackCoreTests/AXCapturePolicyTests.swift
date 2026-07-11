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

    // MARK: Batched AX read parsing (guards the multi-attribute round-trip)

    func testStringValuesKeepsOnlyStringsInRequestedOrder() {
        let attributes = ["AXRole", "AXSubrole", "AXTitle", "AXValue"]
        // A no-value/error placeholder comes back as a non-string object (here 0).
        let values: [Any] = ["AXTextField", 0, "My Title", "Body text"]
        let out = AXAttributes.stringValues(attributes: attributes, values: values)
        XCTAssertEqual(out, ["AXRole": "AXTextField", "AXTitle": "My Title", "AXValue": "Body text"])
        XCTAssertNil(out["AXSubrole"]) // placeholder dropped, not misindexed onto another key
    }

    func testStringValuesMisalignedArraysReturnEmpty() {
        XCTAssertTrue(AXAttributes.stringValues(attributes: ["a", "b"], values: ["x"]).isEmpty)
    }
}
