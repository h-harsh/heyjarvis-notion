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
final class AXTextExtractor: TextSnapshotProvider {

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
        return stringAttribute(window, kAXTitleAttribute)
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
