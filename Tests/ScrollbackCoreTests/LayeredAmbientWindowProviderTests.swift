import XCTest
@testable import ScrollbackCore

/// Regression tests for the security fixes an adversarial review found in the ambient
/// (all-windows-sweep) capture provider: an unresolved/secure-field window must never
/// be OCR'd (screenshotted), and OCR is rationed per sweep to bound main-thread stall.
final class LayeredAmbientWindowProviderTests: XCTestCase {

    private final class FakeAX: AmbientAXReader {
        var byWindow: [UInt32: AmbientAXReading] = [:]
        func readWindow(_ target: AmbientWindowTarget) -> AmbientAXReading {
            byWindow[target.windowID] ?? .unresolved
        }
    }

    private final class FakeOCR: AmbientOCRReader {
        var byWindow: [UInt32: String] = [:]
        private(set) var calls: [UInt32] = []
        func ocrWindow(_ target: AmbientWindowTarget) -> CapturedText? {
            calls.append(target.windowID)
            guard let text = byWindow[target.windowID] else { return nil }
            return CapturedText(text: text, source: .ocr, confidence: 0.7)
        }
    }

    private func target(_ id: UInt32, bundle: String = "com.google.Chrome") -> AmbientWindowTarget {
        AmbientWindowTarget(
            context: FrontmostContext(pid: 10, bundleID: bundle, appName: "App", windowTitle: "W\(id)"),
            windowID: id, area: 480_000
        )
    }

    private func make(ax: FakeAX, ocr: FakeOCR, maxOCR: Int = 4) -> LayeredAmbientWindowProvider {
        LayeredAmbientWindowProvider(ax: ax, ocr: ocr, maxOCRPerSweep: maxOCR)
    }

    // MARK: secure-field / unresolved must NEVER be OCR'd (the HIGH bypass fixes)

    func testUnresolvedWindowIsNeverOCRd() {
        // AX couldn't resolve the window (untitled / title mismatch) → NOT vetted →
        // must not screenshot it, even though it's an axThenOCR app with "thin" AX.
        let ax = FakeAX() // window 1 → .unresolved (default)
        let ocr = FakeOCR(); ocr.byWindow = [1: "secret login form contents"]
        let provider = make(ax: ax, ocr: ocr)

        let result = provider.snapshot(of: target(1))
        XCTAssertNil(result)
        XCTAssertTrue(ocr.calls.isEmpty, "an unresolved (unvetted) window must never be OCR'd")
    }

    func testSecureFieldWindowIsNeverOCRd() {
        // AX resolved the window and saw a secure field → never OCR-fallback it (a
        // screenshot would recapture the credential surface).
        let ax = FakeAX()
        ax.byWindow = [1: AmbientAXReading(windowResolved: true, containedSecureField: true, text: nil)]
        let ocr = FakeOCR(); ocr.byWindow = [1: "password field pixels"]
        let provider = make(ax: ax, ocr: ocr)

        XCTAssertNil(provider.snapshot(of: target(1)))
        XCTAssertTrue(ocr.calls.isEmpty)
    }

    func testSecureFieldWindowReturnsAXPartialWithoutOCR() {
        // A secure-field window can still have safe non-secret AX text — return it, no OCR.
        let ax = FakeAX()
        let partial = CapturedText(text: "Username label and other page chrome", source: .ax, confidence: 1.0, containedSecureField: true)
        ax.byWindow = [1: AmbientAXReading(windowResolved: true, containedSecureField: true, text: partial)]
        let ocr = FakeOCR(); ocr.byWindow = [1: "should not be used"]
        let provider = make(ax: ax, ocr: ocr)

        XCTAssertEqual(provider.snapshot(of: target(1))?.text, "Username label and other page chrome")
        XCTAssertTrue(ocr.calls.isEmpty)
    }

    // MARK: legit OCR still works for vetted AX-opaque windows

    func testVettedAXOpaqueWindowIsOCRd() {
        // Resolved, no secure field, empty AX (AX-opaque dashboard) → OCR is safe.
        let ax = FakeAX()
        ax.byWindow = [1: AmbientAXReading(windowResolved: true, containedSecureField: false, text: nil)]
        let ocr = FakeOCR(); ocr.byWindow = [1: "ahrefs backlinks 12,340 domains"]
        let provider = make(ax: ax, ocr: ocr)

        XCTAssertEqual(provider.snapshot(of: target(1))?.text, "ahrefs backlinks 12,340 domains")
        XCTAssertEqual(provider.snapshot(of: target(1))?.source, .ocr)
    }

    func testRichAXWindowIsNotOCRd() {
        // Resolved with rich AX text → keep AX, never pay for OCR.
        let ax = FakeAX()
        let rich = CapturedText(text: String(repeating: "meaningful accessible text ", count: 5), source: .ax, confidence: 1.0)
        ax.byWindow = [1: AmbientAXReading(windowResolved: true, containedSecureField: false, text: rich)]
        let ocr = FakeOCR(); ocr.byWindow = [1: "unused"]
        let provider = make(ax: ax, ocr: ocr)

        XCTAssertEqual(provider.snapshot(of: target(1))?.source, .ax)
        XCTAssertTrue(ocr.calls.isEmpty)
    }

    func testOCRNeverRegressesBelowAX() {
        // AX thin but non-empty; OCR returns less → keep AX.
        let ax = FakeAX()
        let thin = CapturedText(text: "Dashboard", source: .ax, confidence: 1.0) // <= thin threshold
        ax.byWindow = [1: AmbientAXReading(windowResolved: true, containedSecureField: false, text: thin)]
        let ocr = FakeOCR(); ocr.byWindow = [1: "x"] // shorter than AX
        let provider = make(ax: ax, ocr: ocr)

        XCTAssertEqual(provider.snapshot(of: target(1))?.text, "Dashboard")
        XCTAssertEqual(ocr.calls, [1]) // it tried, then kept AX
    }

    func testOcrOnlyAppGoesStraightToOCR() {
        let ax = FakeAX() // never consulted for ocrOnly
        let ocr = FakeOCR(); ocr.byWindow = [1: "remote desktop pixels"]
        let provider = make(ax: ax, ocr: ocr)
        let t = target(1, bundle: "com.microsoft.rdc.macos") // seeded ocrOnly

        XCTAssertEqual(provider.snapshot(of: t)?.text, "remote desktop pixels")
        XCTAssertEqual(ocr.calls, [1])
    }

    // MARK: per-sweep OCR budget (CPU bound)

    func testOCRBudgetLimitsScreenshotsPerSweep() {
        let ax = FakeAX()
        var ocrText: [UInt32: String] = [:]
        for id: UInt32 in 1...6 {
            ax.byWindow[id] = AmbientAXReading(windowResolved: true, containedSecureField: false, text: nil)
            ocrText[id] = "opaque window \(id)"
        }
        let ocr = FakeOCR(); ocr.byWindow = ocrText
        let provider = make(ax: ax, ocr: ocr, maxOCR: 3)

        for id: UInt32 in 1...6 { _ = provider.snapshot(of: target(id)) }
        XCTAssertEqual(ocr.calls.count, 3, "OCR is capped at the per-sweep budget")

        provider.beginSweep() // next sweep refills the budget
        for id: UInt32 in 1...6 { _ = provider.snapshot(of: target(id)) }
        XCTAssertEqual(ocr.calls.count, 6)
    }
}
