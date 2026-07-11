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
        walk(window, depth: 0, parts: &parts, nodes: &nodesVisited, chars: &charsCollected)
        let joined = parts.joined(separator: "\n")
        return joined.isEmpty ? nil : CapturedText(text: joined, source: .ax, confidence: 1.0)
    }

    func focusedWindowTitle(pid: pid_t) -> String? {
        guard let window = focusedWindow(pid: pid) else { return nil }
        return stringAttribute(window, kAXTitleAttribute)
    }

    // MARK: - AX plumbing

    private func focusedWindow(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &ref)
        guard err == .success, let value = ref, CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }
        return (value as! AXUIElement)
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        parts: inout [String],
        nodes: inout Int,
        chars: inout Int
    ) {
        nodes += 1
        guard nodes <= maxNodes, depth <= maxDepth, chars <= maxTotalChars else { return }

        // Never read secure fields — skip the whole subtree. Checks BOTH role
        // and subrole (a password field's role is "AXTextField", subrole
        // "AXSecureTextField").
        let role = stringAttribute(element, kAXRoleAttribute)
        let subrole = stringAttribute(element, kAXSubroleAttribute)
        if AXCapturePolicy.isSecureField(role: role, subrole: subrole) {
            return
        }

        if let title = stringAttribute(element, kAXTitleAttribute), !title.isEmpty {
            parts.append(title)
            chars += title.count
        }
        if let value = stringAttribute(element, kAXValueAttribute), !value.isEmpty {
            parts.append(value)
            chars += value.count
        }

        for child in childElements(element) {
            walk(child, depth: depth + 1, parts: &parts, nodes: &nodes, chars: &chars)
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

    private func childElements(_ element: AXUIElement) -> [AXUIElement] {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &ref) == .success,
              let array = ref as? [AXUIElement] else {
            return []
        }
        return array
    }
}
