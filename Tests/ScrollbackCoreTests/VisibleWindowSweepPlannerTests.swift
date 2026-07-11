import XCTest
@testable import ScrollbackCore

/// The all-windows sweep is a WIDENED capture surface (every visible window, not
/// just the focused one), so the planner is a privacy gate: excluded windows must
/// never reach capture, the focused window isn't double-captured, junk (offscreen /
/// wrong-layer / tiny) is filtered, and the cap is deterministic.
final class VisibleWindowSweepPlannerTests: XCTestCase {

    private func win(
        _ id: UInt32, pid: Int32 = 10, bundle: String = "com.google.Chrome",
        app: String = "Chrome", title: String? = "Tab", layer: Int = 0,
        w: Double = 800, h: Double = 600, onScreen: Bool = true, sharingNone: Bool = false
    ) -> WindowDescriptor {
        WindowDescriptor(windowID: id, pid: pid, bundleID: bundle, appName: app,
                         title: title, layer: layer, width: w, height: h,
                         isOnScreen: onScreen, isSharingNone: sharingNone)
    }

    private func plan(
        _ windows: [WindowDescriptor], focused: FrontmostContext? = nil,
        exclusions: ExclusionSet = ExclusionSet(rules: []),
        config: VisibleWindowSweepConfig = VisibleWindowSweepConfig()
    ) -> [AmbientWindowTarget] {
        VisibleWindowSweepPlanner.plan(windows: windows, focused: focused, exclusions: exclusions, config: config)
    }

    func testCapturesAllVisibleNormalWindows() {
        let targets = plan([win(1, title: "A"), win(2, title: "B"), win(3, title: "C")])
        XCTAssertEqual(Set(targets.map { $0.windowID }), [1, 2, 3])
    }

    func testDropsOffscreenWrongLayerAndTinyWindows() {
        let targets = plan([
            win(1, title: "real"),
            win(2, title: "offscreen", onScreen: false),
            win(3, title: "menu", layer: 25),      // non-zero layer (menu/status/tooltip)
            win(4, title: "tooltip", w: 80, h: 40), // below min area
        ])
        XCTAssertEqual(targets.map { $0.windowID }, [1])
    }

    func testNeverCaptureExclusionIsDropped() {
        // A password manager window on a side monitor must never be swept.
        let rules: [ExclusionRule] = [.never(.app, "com.1password.1password")]
        let targets = plan([
            win(1, bundle: "com.1password.1password", app: "1Password", title: "Vault"),
            win(2, bundle: "com.google.Chrome", title: "Dashboard"),
        ], exclusions: ExclusionSet(rules: rules))
        XCTAssertEqual(targets.map { $0.windowID }, [2]) // 1Password dropped, Chrome kept
    }

    func testIncognitoWindowTitleExclusionIsDropped() {
        let rules: [ExclusionRule] = [.never(.window, "Incognito")]
        let targets = plan([
            win(1, title: "Bank of America — Incognito"),
            win(2, title: "News"),
        ], exclusions: ExclusionSet(rules: rules))
        XCTAssertEqual(targets.map { $0.windowID }, [2])
    }

    func testFocusedWindowIsSkipped() {
        let focused = FrontmostContext(pid: 10, bundleID: "com.google.Chrome", appName: "Chrome", windowTitle: "Docs")
        let targets = plan([
            win(1, pid: 10, title: "Docs"),   // the focused window — captured by focused stream
            win(2, pid: 10, title: "Gmail"),  // another Chrome window — swept
            win(3, pid: 11, bundle: "com.tinyspeck.slackmacgap", app: "Slack", title: "#general"),
        ], focused: focused)
        XCTAssertEqual(Set(targets.map { $0.windowID }), [2, 3])
    }

    func testFocusedSkipMatchesNormalizedTitle() {
        // The focused context title is already spinner-normalized; a descriptor's raw
        // title with a spinner glyph must still match and be skipped.
        let focused = FrontmostContext(pid: 10, bundleID: "com.google.Chrome", appName: "Chrome", windowTitle: "Building")
        let targets = plan([win(1, pid: 10, title: "⠂ Building")], focused: focused)
        XCTAssertTrue(targets.isEmpty)
    }

    func testUntitledFocusedWindowDoesNotDropWholeApp() {
        // No focused title ⇒ can't identify the focused window among same-pid windows,
        // so we must NOT drop the app's other windows (only accept a rare dup).
        let focused = FrontmostContext(pid: 10, bundleID: "com.google.Chrome", appName: "Chrome", windowTitle: nil)
        let targets = plan([win(1, pid: 10, title: "Gmail"), win(2, pid: 10, title: "Docs")], focused: focused)
        XCTAssertEqual(Set(targets.map { $0.windowID }), [1, 2])
    }

    func testTitleIsNormalizedInTarget() {
        let targets = plan([win(1, title: "⠂ Loading dashboard")])
        XCTAssertEqual(targets.first?.context.windowTitle, "Loading dashboard")
    }

    func testDeterministicAreaDescendingOrderWithWindowIDTieBreak() {
        let targets = plan([
            win(1, title: "small", w: 300, h: 300), // 90k
            win(2, title: "big", w: 1000, h: 1000), // 1M
            win(3, title: "mid", w: 500, h: 500),   // 250k
            win(4, title: "big2", w: 1000, h: 1000), // 1M — tie with 2, lower id first
        ])
        XCTAssertEqual(targets.map { $0.windowID }, [2, 4, 3, 1])
    }

    func testCapKeepsLargestWindows() {
        let windows = (1...20).map { win(UInt32($0), title: "w\($0)", w: Double($0) * 100, h: 100) }
        let targets = plan(windows, config: VisibleWindowSweepConfig(maxWindowsPerSweep: 3))
        // Largest three by area (w = id*100): ids 20, 19, 18.
        XCTAssertEqual(targets.map { $0.windowID }, [20, 19, 18])
    }

    func testSharingNoneWindowDropsTheWholePid() {
        // A pid with ANY sharing-none window (NSWindowSharingNone) has ALL its windows
        // dropped — the app's "don't record me" applied fail-safe across the sweep.
        let targets = plan([
            win(1, pid: 10, title: "shared doc"),           // same pid as a sharing-none window
            win(2, pid: 10, title: "private panel", sharingNone: true),
            win(3, pid: 11, title: "other app window"),     // different pid — kept
        ])
        XCTAssertEqual(targets.map { $0.windowID }, [3])
    }

    func testRedactWindowIsKeptForThePlaceholderEpisode() {
        // `.redact` (not `.neverCapture`) windows are kept — the engine records a
        // masked-placeholder episode for them.
        let rules: [ExclusionRule] = [ExclusionRule(type: .app, pattern: "com.google.Chrome", mode: .redact)]
        let targets = plan([win(1, title: "Dashboard")], exclusions: ExclusionSet(rules: rules))
        XCTAssertEqual(targets.map { $0.windowID }, [1])
    }
}
