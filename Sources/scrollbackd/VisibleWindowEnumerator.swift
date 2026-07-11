import Foundation
import AppKit
import CoreGraphics
import ScrollbackCore

/// Enumerates every on-screen window across all displays (the input to the
/// all-windows sweep planner). Uses `CGWindowListCopyWindowInfo`, which spans every
/// monitor in one call. Window TITLES (`kCGWindowName`) require the Screen Recording
/// grant — without it titles are nil (owner/geometry still resolve), so AX matching
/// degrades but the pipeline never crashes.
///
/// Pure selection/exclusion happens later in `VisibleWindowSweepPlanner`; this only
/// maps the window-server dictionaries into `WindowDescriptor`s.
enum VisibleWindowEnumerator {

    static func enumerate() -> [WindowDescriptor] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var bundleCache: [pid_t: String] = [:]
        var out: [WindowDescriptor] = []
        for info in infos {
            guard let number = info[kCGWindowNumber as String] as? Int,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t else { continue }

            let layer = info[kCGWindowLayer as String] as? Int ?? 0
            let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? true
            let appName = info[kCGWindowOwnerName as String] as? String ?? "Unknown"
            let title = info[kCGWindowName as String] as? String // nil without Screen Recording

            let bounds = info[kCGWindowBounds as String] as? [String: Any]
            let width = (bounds?["Width"] as? Double) ?? 0
            let height = (bounds?["Height"] as? Double) ?? 0

            // kCGWindowSharingState: 0 == none (the app opted out of capture). Absent
            // ⇒ default to shared (1), matching CaptureGuards' read-only default.
            let sharingNone = (info[kCGWindowSharingState as String] as? Int ?? 1) == 0

            let bundleID: String
            if let cached = bundleCache[pid] {
                bundleID = cached
            } else {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "unknown.bundle"
                bundleCache[pid] = bundleID
            }

            out.append(WindowDescriptor(
                windowID: UInt32(truncatingIfNeeded: number), pid: pid, bundleID: bundleID,
                appName: appName, title: title, layer: layer,
                width: width, height: height, isOnScreen: onScreen, isSharingNone: sharingNone
            ))
        }
        return out
    }
}

/// Entry point for `scrollbackd windows-dump` — shows what an all-windows sweep WOULD
/// capture right now (enumerate → plan), without capturing anything. The founder's
/// tool to see whether their side-monitor dashboards are in range. Window titles need
/// the Screen Recording grant; without it they show as `<no title>` and AX matching
/// degrades (so grant it before trusting the output).
@MainActor
func runWindowsDump() -> Int32 {
    let descriptors = VisibleWindowEnumerator.enumerate()
    let focused = makeFrontmostContext(extractor: AXTextExtractor())
    let targets = VisibleWindowSweepPlanner.plan(
        windows: descriptors, focused: focused, exclusions: ExclusionSet()
    )

    if !CGPreflightScreenCaptureAccess() {
        print("⚠︎ Screen Recording NOT granted — window titles are hidden and OCR is off. Grant it for a real picture.\n")
    }
    print("focused: \(focused.map { "\($0.appName) — \($0.windowTitle ?? "<no title>")" } ?? "<none>")")
    print("visible windows enumerated: \(descriptors.count)")
    print("would sweep \(targets.count) window(s) (largest-area first; focused + excluded + tiny/offscreen dropped):")
    for target in targets {
        let title = target.context.windowTitle ?? "<no title>"
        print("  • \(target.context.appName) — \(title)  [id \(target.windowID), \(Int(target.area))px², \(target.context.bundleID)]")
    }
    return 0
}
