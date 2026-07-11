import Foundation
import ApplicationServices
import ScrollbackCore

/// Reads visible text from the frontmost window via the Accessibility tree.
/// Requires the Accessibility TCC grant (attributed to the responsible process —
/// for `swift run` that's your terminal app).
///
/// Never-rule enforced here: secure text fields are skipped subtree-and-all —
/// password content is never read. The decision lives in
/// `AXCapturePolicy.isSecureField` (pure, unit-tested) because a password field
/// reports "AXSecureTextField" as its *subrole* (role stays "AXTextField").
final class AXTextExtractor: TextSnapshotProvider, AmbientAXReader {

    private let maxNodes: Int
    private let maxDepth: Int
    private let maxTotalChars: Int

    /// Short-lived cache of the resolved focused window per pid. A window change
    /// fetches the title then, moments later, the text — both go through
    /// `focusedWindow(pid:)`, so caching for one run-loop turn removes the
    /// second redundant `kAXFocusedWindow` round-trip without risking staleness
    /// (a real window switch fires a notification that supersedes this anyway).
    private var windowCache: (pid: pid_t, window: AXUIElement, at: Date)?
    private let windowCacheTTL: TimeInterval = 0.2

    init(maxNodes: Int = 2500, maxDepth: Int = 40, maxTotalChars: Int = 200_000) {
        self.maxNodes = maxNodes
        self.maxDepth = maxDepth
        self.maxTotalChars = maxTotalChars
    }

    func snapshot(for context: FrontmostContext) -> CapturedText? {
        // Runtime suppressors (secure input active, NSWindowSharingNone) — read
        // nothing rather than the window's text. Pattern exclusions are handled
        // upstream in the engine's ExclusionSet.
        guard !CaptureGuards.shouldSuppressCapture(pid: context.pid) else { return nil }
        guard let window = focusedWindow(pid: context.pid) else { return nil }
        var parts: [String] = []
        var nodesVisited = 0
        var charsCollected = 0
        var sawSecureField = false
        walk(window, depth: 0, parts: &parts, nodes: &nodesVisited, chars: &charsCollected, sawSecure: &sawSecureField)
        let joined = parts.joined(separator: "\n")
        guard !joined.isEmpty else { return nil }
        // Carry the secure-field signal so the layered provider won't OCR-fallback
        // a window whose password field we just declined to read.
        return CapturedText(text: joined, source: .ax, confidence: 1.0, containedSecureField: sawSecureField)
    }

    func focusedWindowTitle(pid: pid_t) -> String? {
        guard let window = focusedWindow(pid: pid) else { return nil }
        // Strip loading-spinner/progress glyphs so an animated title doesn't churn
        // episode boundaries (the episode key includes the window title).
        return WindowTitleNormalizer.normalize(stringAttribute(window, kAXTitleAttribute))
    }

    /// Reads a specific BACKGROUND window (for the all-windows sweep) — the app
    /// window whose normalized AX title matches `context.windowTitle`, not the
    /// focused window. Same subtree walk as `snapshot`, so the never-read-secure-
    /// fields guard and the `containedSecureField` signal carry through unchanged.
    ///
    /// Returns a RESOLUTION-AWARE result, not a bare `CapturedText?`, because the
    /// caller MUST distinguish "walked this window, it's AX-opaque (empty) but has no
    /// secure field → safe to OCR" from "couldn't resolve this window at all → NOT
    /// vetted, must NOT OCR". Conflating the two (a nil `CapturedText`) is what let an
    /// untitled/ title-mismatched secure-field window get screenshotted.
    func readWindow(_ context: AmbientWindowTarget) -> AmbientAXReading {
        let pid = context.context.pid
        guard !CaptureGuards.shouldSuppressCapture(pid: pid) else { return .unresolved }
        guard let window = windowMatchingTitle(pid: pid, title: context.context.windowTitle) else {
            return .unresolved
        }
        var parts: [String] = []
        var nodesVisited = 0
        var charsCollected = 0
        var sawSecureField = false
        walk(window, depth: 0, parts: &parts, nodes: &nodesVisited, chars: &charsCollected, sawSecure: &sawSecureField)
        let joined = parts.joined(separator: "\n")
        let text = joined.isEmpty
            ? nil
            : CapturedText(text: joined, source: .ax, confidence: 1.0, containedSecureField: sawSecureField)
        return AmbientAXReading(windowResolved: true, containedSecureField: sawSecureField, text: text)
    }

    /// The app's on-screen window whose normalized title equals `title` — but ONLY if
    /// it's UNIQUE. Titles are normalized on both sides (the planner normalized the
    /// descriptor title; we normalize the live AX title) so a spinner glyph can't
    /// defeat the match. If two same-pid windows share the title we return nil (→
    /// `.unresolved` → never OCR'd): the secure-field vetting here resolves by title
    /// but the OCR screenshots by exact windowID, so an ambiguous title could vet a
    /// DIFFERENT physical window than the one captured. Refusing the ambiguous case
    /// keeps vetting and screenshot pinned to the same window (safe over coverage).
    private func windowMatchingTitle(pid: pid_t, title: String?) -> AXUIElement? {
        guard let title, !title.isEmpty else { return nil } // can't disambiguate untitled windows
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else {
            return nil
        }
        let matches = windows.filter { WindowTitleNormalizer.normalize(stringAttribute($0, kAXTitleAttribute)) == title }
        return matches.count == 1 ? matches.first : nil // unique match only
    }

    // MARK: - AX plumbing

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        if let cached = windowCache, cached.pid == pid,
           Date().timeIntervalSince(cached.at) < windowCacheTTL {
            return cached.window
        }
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref)
        guard err == .success, let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            windowCache = nil
            return nil
        }
        let window = (value as! AXUIElement)
        windowCache = (pid, window, Date())
        return window
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        parts: inout [String],
        nodes: inout Int,
        chars: inout Int,
        sawSecure: inout Bool
    ) {
        nodes += 1
        guard nodes <= maxNodes, depth <= maxDepth, chars <= maxTotalChars else { return }

        // One IPC round-trip for all four text attributes instead of four.
        let attrs = stringAttributes(element, [
            kAXRoleAttribute, kAXSubroleAttribute, kAXTitleAttribute, kAXValueAttribute,
        ])

        // Never read secure fields — skip the whole subtree. Checks BOTH role
        // and subrole (a password field's role is "AXTextField", subrole
        // "AXSecureTextField"). Record that we saw one so the OCR fallback can be
        // suppressed for this window (a screenshot would recapture it).
        if AXCapturePolicy.isSecureField(role: attrs[kAXRoleAttribute], subrole: attrs[kAXSubroleAttribute]) {
            sawSecure = true
            return
        }

        if let title = attrs[kAXTitleAttribute], !title.isEmpty {
            parts.append(title)
            chars += title.count
        }
        if let value = attrs[kAXValueAttribute], !value.isEmpty {
            parts.append(value)
            chars += value.count
        }

        for child in childElements(element) {
            walk(child, depth: depth + 1, parts: &parts, nodes: &nodes, chars: &chars, sawSecure: &sawSecure)
            if nodes > maxNodes || chars > maxTotalChars { return }
        }
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success else {
            return nil
        }
        return ref as? String
    }

    /// Fetches several attributes in one round-trip. Attributes with no value
    /// (or an error) come back as non-string placeholders and are dropped by the
    /// `as? String` cast, so the returned dict holds only present string values.
    private func stringAttributes(_ element: AXUIElement, _ attributes: [String]) -> [String: String] {
        var valuesRef: CFArray?
        let err = AXUIElementCopyMultipleAttributeValues(
            element, attributes as CFArray, AXCopyMultipleAttributeOptions(), &valuesRef
        )
        guard err == .success, let values = valuesRef as? [Any] else { return [:] }
        return AXAttributes.stringValues(attributes: attributes, values: values)
    }

    private func childElements(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement] else {
            return []
        }
        return array
    }
}
