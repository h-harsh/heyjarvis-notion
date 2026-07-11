import XCTest
@testable import ScrollbackCore

/// Guards the spinner-title fix: animated window titles must collapse to one stable
/// title so a loading spinner can't spawn junk episodes (52 in the first dogfood run).
final class WindowTitleNormalizerTests: XCTestCase {

    private func norm(_ s: String?) -> String? { WindowTitleNormalizer.normalize(s) }

    func testBrailleSpinnerFramesCollapseToOneTitle() {
        // The exact case from the dogfood data: Warp's tab title flipping spinner frames.
        let frameA = norm("⠂ Define product scope and create PRD and tech-spec")
        let frameB = norm("⠐ Define product scope and create PRD and tech-spec")
        let frameC = norm("⣾ Define product scope and create PRD and tech-spec")
        XCTAssertEqual(frameA, "Define product scope and create PRD and tech-spec")
        XCTAssertEqual(frameA, frameB) // every frame → same normalized title
        XCTAssertEqual(frameB, frameC)
    }

    func testStableEpisodeKeyAcrossFrames() {
        // The whole point: the episode key stops thrashing once titles are normalized.
        func context(_ title: String) -> FrontmostContext {
            FrontmostContext(pid: 1, bundleID: "dev.warp.Warp", appName: "Warp", windowTitle: norm(title))
        }
        XCTAssertEqual(context("⠂ Building…").key, context("⠐ Building…").key)
    }

    func testRealTitlesAreUntouched() {
        XCTAssertEqual(norm("Dashboard - Ahrefs - Google Chrome"), "Dashboard - Ahrefs - Google Chrome")
        XCTAssertEqual(norm("main.swift — heyjarvis-notion"), "main.swift — heyjarvis-notion")
        XCTAssertEqual(norm("Zerodha Kite / Orders"), "Zerodha Kite / Orders") // slash/pipe kept (not stripped)
    }

    func testWhitespaceCollapsedAndTrimmed() {
        XCTAssertEqual(norm("⠂   spaced   out  "), "spaced out")
    }

    func testNilAndAllGlyphInputs() {
        XCTAssertNil(norm(nil))
        XCTAssertNil(norm("⠂⠐⣾"))    // only spinner glyphs → nil, not ""
        XCTAssertNil(norm("   "))
    }

    func testBlockAndCircleSpinnersStripped() {
        XCTAssertEqual(norm("▓ loading"), "loading")
        XCTAssertEqual(norm("◐ syncing"), "syncing")
    }
}
