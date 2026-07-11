import XCTest
@testable import ScrollbackCore

/// Regression guard for the never-capture invariant (passwords, banking,
/// incognito, the Claude window). Pure policy so a broken rule fails here, not by
/// silently capturing a password manager in production.
final class ExclusionSetTests: XCTestCase {

    private func ctx(_ bundleID: String, title: String? = nil) -> FrontmostContext {
        FrontmostContext(pid: 1, bundleID: bundleID, appName: "App", windowTitle: title)
    }

    // MARK: Defaults

    func testDefaultsExcludePasswordManagersAndClaude() {
        let set = ExclusionSet()
        XCTAssertEqual(set.mode(for: ctx("com.1password.1password")), .neverCapture)
        XCTAssertEqual(set.mode(for: ctx("org.keepassxc.keepassxc")), .neverCapture)
        XCTAssertEqual(set.mode(for: ctx("com.anthropic.claudefordesktop")), .neverCapture)
    }

    func testDefaultsExcludeIncognitoByTitle() {
        let set = ExclusionSet()
        XCTAssertEqual(set.mode(for: ctx("com.google.Chrome", title: "My Bank - Google Chrome (Incognito)")), .neverCapture)
        XCTAssertEqual(set.mode(for: ctx("com.apple.Safari", title: "Private Browsing")), .neverCapture)
    }

    func testDefaultsDoNotExcludeOrdinaryApps() {
        // The simulate/test fixtures MUST stay capturable, or every golden count breaks.
        let set = ExclusionSet()
        XCTAssertEqual(set.mode(for: ctx("com.apple.Safari", title: "ANE docs")), .capture)
        XCTAssertEqual(set.mode(for: ctx("com.tinyspeck.slackmacgap", title: "#general")), .capture)
    }

    // MARK: Matching + precedence

    func testAppRuleIsCaseInsensitiveAndExact() {
        let set = ExclusionSet(rules: [ExclusionRule(type: .app, pattern: "com.Test.Vault", mode: .neverCapture)])
        XCTAssertEqual(set.mode(for: ctx("com.test.vault")), .neverCapture) // case-insensitive
        XCTAssertEqual(set.mode(for: ctx("com.test.vault.helper")), .capture) // exact, not prefix
    }

    func testWindowAndUrlRules() {
        let windowSet = ExclusionSet(rules: [ExclusionRule(type: .window, pattern: "1Password", mode: .neverCapture)])
        XCTAssertEqual(windowSet.mode(for: ctx("com.x", title: "Unlock 1Password")), .neverCapture)

        let urlSet = ExclusionSet(rules: [ExclusionRule(type: .url, pattern: "chase.com", mode: .neverCapture)])
        XCTAssertEqual(urlSet.mode(for: ctx("com.apple.Safari"), url: "https://secure.chase.com/login"), .neverCapture)
        XCTAssertEqual(urlSet.mode(for: ctx("com.apple.Safari"), url: "https://example.com"), .capture)
    }

    func testRegexRule() {
        let set = ExclusionSet(rules: [ExclusionRule(type: .regex, pattern: #"bank|banking"#, mode: .neverCapture)])
        XCTAssertEqual(set.mode(for: ctx("com.chase.banking")), .neverCapture)
        XCTAssertEqual(set.mode(for: ctx("com.apple.Notes")), .capture)
    }

    func testNeverCaptureWinsOverRedact() {
        let set = ExclusionSet(rules: [
            ExclusionRule(type: .app, pattern: "com.x", mode: .redact),
            ExclusionRule(type: .window, pattern: "secret", mode: .neverCapture),
        ])
        XCTAssertEqual(set.mode(for: ctx("com.x", title: "top secret")), .neverCapture)
        XCTAssertEqual(set.mode(for: ctx("com.x", title: "ordinary")), .redact)
    }

    func testScheduleRuleIsNotMatchedByPatternPass() {
        let set = ExclusionSet(rules: [ExclusionRule(type: .schedule, pattern: "09:00-17:00", mode: .neverCapture)])
        XCTAssertEqual(set.mode(for: ctx("com.anything")), .capture)
    }

    func testEmptyRuleSetAlwaysCaptures() {
        XCTAssertEqual(ExclusionSet(rules: []).mode(for: ctx("com.1password.1password")), .capture)
    }
}
