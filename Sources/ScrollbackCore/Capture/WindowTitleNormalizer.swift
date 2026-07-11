import Foundation

/// Strips animated-indicator glyphs (loading spinners, progress bars) from a window
/// title so an animation can't churn episode boundaries. A terminal like Warp shows a
/// braille spinner in its tab title (`⠂ Build…` → `⠐ Build…` → …); because the episode
/// key includes the window title, each spinner FRAME looked like a new window and
/// opened a junk episode (52 of them in the first dogfood run). Normalizing collapses
/// every frame to one stable title, so the key stops thrashing.
///
/// Pure + deterministic. Conservative: only glyph ranges that essentially never appear
/// in real titles are stripped (Braille — the CLI-spinner block — plus a curated set of
/// circle/quadrant/block spinner glyphs), so legitimate titles are untouched.
public enum WindowTitleNormalizer {

    /// Normalize a raw AX window title. Returns nil for nil/all-glyph input so an
    /// empty title stays nil (not "").
    public static func normalize(_ title: String?) -> String? {
        guard let title else { return nil }
        let stripped = String(String.UnicodeScalarView(title.unicodeScalars.filter { !isAnimationGlyph($0) }))
        let collapsed = stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// True for glyphs used as animation frames (spinners / progress). These ranges
    /// are astral to normal titles: Braille Patterns are the standard CLI spinner set,
    /// and the others are circle/quadrant/block "throbber" glyphs.
    static func isAnimationGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x2800...0x28FF: return true // Braille Patterns (⠂⠐⣾⣽… — most CLI spinners)
        case 0x25D0...0x25D3: return true // ◐◑◒◓
        case 0x25E2...0x25E5: return true // ◢◣◤◥
        case 0x25F4...0x25F7: return true // ◴◵◶◷
        case 0x2580...0x259F: return true // Block Elements (▁…█ ▖▗ ░▒▓ — progress/spinner frames)
        default: return false
        }
    }
}
