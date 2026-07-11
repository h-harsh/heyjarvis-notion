import XCTest
@testable import ScrollbackCore

/// Regression guard for the capture-time redact stage: high-risk secrets are
/// masked before storage while ordinary content — including the PII that is the
/// product's value — is left intact, and the surrounding text always survives.
final class RedactorTests: XCTestCase {

    private let redactor = Redactor()

    private func assertMasked(_ text: String, flag: RedactionFlags, mustNotContain: String, file: StaticString = #filePath, line: UInt = #line) {
        let result = redactor.redact(text)
        XCTAssertTrue(result.flags.contains(flag), "expected flag not set", file: file, line: line)
        XCTAssertFalse(result.text.contains(mustNotContain), "secret survived redaction", file: file, line: line)
    }

    // MARK: Secret types

    func testMasksOpenAIStyleKey() {
        assertMasked("token is sk-abcDEF0123456789gh␟".replacingOccurrences(of: "␟", with: "XYZ"),
                     flag: .apiKey, mustNotContain: "sk-abcDEF0123456789")
    }

    func testMasksGitHubToken() {
        assertMasked("export GH=ghp_0123456789abcdefABCDEF0123456789wxyz done",
                     flag: .apiKey, mustNotContain: "ghp_0123456789")
    }

    func testMasksAWSAccessKey() {
        assertMasked("key AKIAIOSFODNN7EXAMPLE here", flag: .apiKey, mustNotContain: "AKIAIOSFODNN7EXAMPLE")
    }

    func testMasksJWT() {
        let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N"
        assertMasked("Authorization: Bearer \(jwt)", flag: .apiKey, mustNotContain: jwt)
    }

    func testMasksPrivateKeyBlock() {
        let pem = """
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAA
        -----END OPENSSH PRIVATE KEY-----
        """
        let result = redactor.redact("here it is\n\(pem)\nthanks")
        XCTAssertTrue(result.flags.contains(.privateKey))
        XCTAssertFalse(result.text.contains("b3BlbnNzaC"))
        XCTAssertTrue(result.text.contains("here it is"))   // surrounding text persists
        XCTAssertTrue(result.text.contains("thanks"))
    }

    // MARK: Credit card — Luhn gating

    func testMasksLuhnValidCard() {
        assertMasked("card 4111 1111 1111 1111 exp", flag: .creditCard, mustNotContain: "4111")
    }

    func testDoesNotMaskLuhnInvalidNumber() {
        // 16-digit but fails Luhn (e.g. an order/reference id) → left intact.
        let result = redactor.redact("order 4111111111111112 shipped")
        XCTAssertFalse(result.flags.contains(.creditCard))
        XCTAssertTrue(result.text.contains("4111111111111112"))
    }

    func testLuhnValidator() {
        XCTAssertTrue(Redactor.isLuhnValid("4111111111111111"))
        XCTAssertTrue(Redactor.isLuhnValid("4111 1111 1111 1111")) // separators ignored
        XCTAssertFalse(Redactor.isLuhnValid("4111111111111112"))
        XCTAssertFalse(Redactor.isLuhnValid("123"))                // too short
    }

    func testMasksCardAtLengthBoundaries() {
        // All-zeros is Luhn-valid at any length (checksum 0); pins the 13- and
        // 19-digit ends of the card rule (a narrowing regression stops masking).
        assertMasked("pan 0000000000000 end", flag: .creditCard, mustNotContain: "0000000000000")
        assertMasked("pan 0000000000000000000 end", flag: .creditCard, mustNotContain: "0000000000000000000")
    }

    func testMasksCardWithAdjacentStrayDigit() {
        // Greedy match absorbs the trailing " 2" into a 17-digit run that fails
        // Luhn as a whole; the embedded 16-digit PAN must still be masked, not leaked.
        let result = redactor.redact("charge 4111 1111 1111 1111 2 today")
        XCTAssertTrue(result.flags.contains(.creditCard))
        XCTAssertFalse(result.text.contains("4111"))
        XCTAssertTrue(result.text.contains("charge "))
        XCTAssertTrue(result.text.contains(" today"))
    }

    func testMasksCardWithNonSpaceSeparators() {
        // Tab / NBSP separators (spreadsheet or webpage copy) — after whitespace
        // normalization these must still be caught (regression guard for the
        // clipboard verbatim-vs-normalized leak).
        for separated in ["4111\t1111\t1111\t1111", "4111\u{00A0}1111\u{00A0}1111\u{00A0}1111"] {
            let normalized = TextNormalizer.normalize(separated)
            let result = redactor.redact(normalized)
            XCTAssertTrue(result.flags.contains(.creditCard), "not masked: \(separated.debugDescription)")
            XCTAssertFalse(result.text.contains("4111"))
        }
    }

    // MARK: Multiple matches of one rule (reverse-order replacement)

    func testTwoMatchesOfSameRuleBothMasked() {
        let result = redactor.redact("keys sk-AAAA0123456789bbbb and sk-CCCC0123456789dddd end")
        XCTAssertFalse(result.text.contains("sk-AAAA"))
        XCTAssertFalse(result.text.contains("sk-CCCC"))
        XCTAssertTrue(result.text.hasPrefix("keys "))
        XCTAssertTrue(result.text.hasSuffix(" end"))
        // Both spans replaced by the mask token.
        let maskCount = result.text.components(separatedBy: "[redacted:apiKey]").count - 1
        XCTAssertEqual(maskCount, 2)
    }

    // MARK: ReDoS guard — a BEGIN-flood with no END must not stall

    func testPrivateKeyRuleDoesNotBacktrackOnBeginFlood() {
        // ~200 KB of BEGIN markers with NO matching END — the O(n^2) trigger.
        // The contains(END) pre-gate must skip the regex entirely; assert it
        // completes far under any capture-cadence budget.
        let marker = "-----BEGIN A PRIVATE KEY-----\n"
        let flood = String(repeating: marker, count: 200_000 / marker.count)
        let start = Date()
        let result = redactor.redact(flood)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 1.0, "redact() stalled on a BEGIN-flood: \(elapsed)s")
        XCTAssertFalse(result.flags.contains(.privateKey)) // no END → nothing to mask
    }

    func testMasksWellFormedPrivateKeyDespiteGuard() {
        // The pre-gate must not suppress a legitimate key (both markers present).
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaGtleQ==\n-----END OPENSSH PRIVATE KEY-----"
        assertMasked("here \(pem) done", flag: .privateKey, mustNotContain: "b3BlbnNzaGtleQ")
    }

    // MARK: Surrounding text + flags

    func testSurroundingTextPersistsAndSpanOnlyMasked() {
        let result = redactor.redact("prefix sk-abcDEF0123456789ghXYZ suffix")
        XCTAssertTrue(result.text.hasPrefix("prefix "))
        XCTAssertTrue(result.text.hasSuffix(" suffix"))
        XCTAssertTrue(result.text.contains("[redacted:apiKey]"))
    }

    func testMultipleSecretsSetMultipleFlags() {
        let result = redactor.redact("key sk-abcDEF0123456789ghXYZ and card 4111 1111 1111 1111")
        XCTAssertTrue(result.flags.contains(.apiKey))
        XCTAssertTrue(result.flags.contains(.creditCard))
        XCTAssertFalse(result.text.contains("4111"))
        XCTAssertFalse(result.text.contains("sk-abcDEF"))
    }

    // MARK: PII is intentionally preserved (the product's value)

    func testDoesNotRedactPII() {
        let text = "Email alice@example.com or call 555-123-4567 about the Q3 roadmap with Bob."
        let result = redactor.redact(text)
        XCTAssertFalse(result.didRedact)
        XCTAssertEqual(result.text, text)
    }

    func testCleanTextIsUnchanged() {
        let text = "Reviewed the ANE performance guide and filed notes."
        let result = redactor.redact(text)
        XCTAssertEqual(result.text, text)
        XCTAssertTrue(result.flags.isEmpty)
    }

    // MARK: Custom rule + flag serialization

    func testCustomRuleContributesCustomFlag() throws {
        let rule = try RedactionRule(name: "employeeId", flag: .custom, pattern: #"\bE\d{6}\b"#)
        let result = Redactor(rules: [rule]).redact("ticket for E123456 assigned")
        XCTAssertTrue(result.flags.contains(.custom))
        XCTAssertFalse(result.text.contains("E123456"))
    }

    func testRedactionFlagsEncodeAsBareInt() throws {
        let flags: RedactionFlags = [.apiKey, .creditCard] // 1 | 4 = 5
        let data = try JSONEncoder().encode(flags)
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "5")
        XCTAssertEqual(try JSONDecoder().decode(RedactionFlags.self, from: data), flags)
    }
}
