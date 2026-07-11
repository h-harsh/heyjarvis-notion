import Foundation

/// What an exclusion rule matches against (mirrors `exclusions.rule_type`).
///
/// - `app`/`window`/`regex` are live: the engine supplies `bundleID`/`appName`/
///   `windowTitle` on every capture.
/// - `url` and `schedule` are defined for the schema/forward-compat but are
///   currently INERT in the live pipeline: `FrontmostContext` carries no URL yet
///   (browser address-bar extraction is a separate task) and `schedule` needs a
///   clock. A `.url`/`.schedule` rule therefore resolves to `.capture` in the
///   engine today — no default rule uses them, so shipped protections are
///   unaffected. See TODO (browser-URL extraction) before advertising URL rules.
public enum ExclusionRuleType: String, Sendable, Codable, CaseIterable {
    case app, url, window, regex, schedule
}

/// The capture decision for a context. Rules carry `.neverCapture` or `.redact`
/// (schema `mode CHECK(never_capture|redact)`); `.capture` is the result when no
/// rule matched.
public enum CaptureMode: String, Sendable, Codable, Equatable {
    case capture
    case neverCapture = "never_capture"
    case redact
}

/// One exclusion rule (persisted shape mirrors the `exclusions` table). A pure
/// value — the compiled regex for `.regex` rules lives in `ExclusionSet`.
public struct ExclusionRule: Sendable, Codable, Equatable {
    public let type: ExclusionRuleType
    public let pattern: String
    public let mode: CaptureMode

    public init(type: ExclusionRuleType, pattern: String, mode: CaptureMode) {
        self.type = type
        self.pattern = pattern
        self.mode = mode
    }

    /// Convenience for the common app/window/url never-capture defaults.
    static func never(_ type: ExclusionRuleType, _ pattern: String) -> ExclusionRule {
        ExclusionRule(type: type, pattern: pattern, mode: .neverCapture)
    }
}

/// Resolves a `FrontmostContext` to a `CaptureMode` against a set of exclusion
/// rules. Pure + regression-tested so the never-capture invariant (passwords,
/// banking, incognito, the Claude window) doesn't depend on the untestable daemon
/// wiring. `.neverCapture` is strictest and wins over `.redact` wins over `.capture`.
///
/// Runtime OS-state signals — `IsSecureEventInputEnabled` and `NSWindowSharingNone`
/// — are NOT pattern rules; they're checked in the daemon's capture providers
/// (they need process/window OS APIs). This type covers the data-driven rules.
///
/// `@unchecked Sendable`: immutable after init; the compiled `NSRegularExpression`s
/// are documented thread-safe.
public struct ExclusionSet: @unchecked Sendable {
    private let rules: [ExclusionRule]
    private let compiledRegexes: [Int: NSRegularExpression]

    public init(rules: [ExclusionRule] = ExclusionSet.defaultRules) {
        self.rules = rules
        var compiled: [Int: NSRegularExpression] = [:]
        for (index, rule) in rules.enumerated() where rule.type == .regex {
            compiled[index] = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])
        }
        self.compiledRegexes = compiled
    }

    /// The strictest mode among matching rules (`.capture` if none match).
    public func mode(for context: FrontmostContext, url: String? = nil) -> CaptureMode {
        var decision: CaptureMode = .capture
        for (index, rule) in rules.enumerated() where matches(rule, index: index, context: context, url: url) {
            if rule.mode == .neverCapture { return .neverCapture } // strictest — short-circuit
            if rule.mode == .redact { decision = .redact }
        }
        return decision
    }

    private func matches(_ rule: ExclusionRule, index: Int, context: FrontmostContext, url: String?) -> Bool {
        switch rule.type {
        case .app:
            return context.bundleID.caseInsensitiveCompare(rule.pattern) == .orderedSame
        case .window:
            return contains(context.windowTitle, rule.pattern)
        case .url:
            return contains(url, rule.pattern)
        case .regex:
            guard let regex = compiledRegexes[index] else { return false }
            let haystack = [context.bundleID, context.appName, context.windowTitle ?? "", url ?? ""]
                .joined(separator: "\n")
            return regex.firstMatch(in: haystack, range: NSRange(haystack.startIndex..., in: haystack)) != nil
        case .schedule:
            return false // time-based; evaluated with a clock elsewhere
        }
    }

    private func contains(_ haystack: String?, _ needle: String) -> Bool {
        guard let haystack else { return false }
        return haystack.range(of: needle, options: .caseInsensitive) != nil
    }

    /// Always-on defaults (PRD: "honored and advertised"). App-bundle rules are
    /// exact + reliable; the incognito window-title rules are best-effort (a
    /// browser doesn't always surface private mode in the AX title). Banking is
    /// mostly web and left to user URL rules + the future default URL set — a
    /// bundle-id list would be arbitrary and incomplete. Secure-input fields and
    /// `NSWindowSharingNone` are handled as runtime signals in the daemon, not here.
    public static let defaultRules: [ExclusionRule] = [
        // Password managers.
        .never(.app, "com.1password.1password"),
        .never(.app, "com.agilebits.onepassword7"),
        .never(.app, "com.agilebits.onepassword-osx"),
        .never(.app, "com.bitwarden.desktop"),
        .never(.app, "org.keepassxc.keepassxc"),
        .never(.app, "com.lastpass.LastPass"),
        .never(.app, "in.sinew.Enpass-Desktop"),
        .never(.app, "com.dashlane.Dashlane"),
        .never(.app, "com.apple.keychainaccess"),
        // The Claude Desktop app (Anthropic directory policy). Claude Code inside a
        // terminal/editor can't be distinguished by bundle id — out of scope here.
        .never(.app, "com.anthropic.claudefordesktop"),
        // Incognito / private-browsing windows (best-effort, by window title).
        .never(.window, "Incognito"),
        .never(.window, "Private Browsing"),
        .never(.window, "InPrivate"),
    ]
}
