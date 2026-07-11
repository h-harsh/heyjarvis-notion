import Foundation
import CoreGraphics
import Carbon

/// OS-state capture suppressors that aren't pattern rules (those live in
/// `ScrollbackCore.ExclusionSet`). These need process/window APIs, so they sit in
/// the daemon and gate the real capture providers (AX + OCR). Can't be
/// headless-verified — observed manually, like the rest of the live capture path.
enum CaptureGuards {

    /// True while any app has secure event input enabled — a password field is
    /// focused somewhere (login windows, `sudo` in Terminal, secure text fields).
    /// While set, we read nothing at all, not just the field: the whole screen is
    /// treated as sensitive.
    static func secureInputActive() -> Bool {
        IsSecureEventInputEnabled()
    }

    /// True if ANY on-screen window owned by `pid` opted out of screen capture via
    /// `NSWindowSharingNone` (`kCGWindowSharingNone`). We honor the app's own
    /// "don't record me" flag for AX too, not just screenshots.
    ///
    /// Fail-safe by design: the AX walker reads the *focused* window
    /// (`kAXFocusedWindowAttribute`), which isn't necessarily the app's topmost
    /// window and can sit at any window level — so we can't cheaply identify
    /// "the window we're about to read" from the CGWindow list. Rather than risk
    /// reading a sharing-none window we failed to match, we suppress capture for
    /// the whole pid whenever it has any sharing-none window on screen. That
    /// over-suppresses an app that keeps a shared doc + a sharing-none panel, but
    /// erring toward "don't capture" is the right bias for a privacy backstop
    /// (and such an app is signalling sensitivity anyway).
    static func pidHasSharingNoneWindow(pid: pid_t) -> Bool {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return false
        }
        for window in windows {
            guard let owner = window[kCGWindowOwnerPID as String] as? pid_t, owner == pid else { continue }
            let sharing = window[kCGWindowSharingState as String] as? Int ?? 1 // default readOnly
            if sharing == 0 { return true } // kCGWindowSharingNone — any window, any level
        }
        return false
    }

    /// Suppress capture for this pid entirely if either runtime signal is active.
    static func shouldSuppressCapture(pid: pid_t) -> Bool {
        secureInputActive() || pidHasSharingNoneWindow(pid: pid)
    }
}
