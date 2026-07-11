import XCTest
@testable import ScrollbackCore

/// Regression guard for the AX/OCR fallback matrix. The screenshot + Vision call
/// needs a Screen Recording grant and can't run in CI, so the *routing* decision
/// — when to reach for OCR, and never regressing below AX — is proven here.
final class CaptureCapabilitiesTests: XCTestCase {

    // MARK: Fakes

    /// Records call count so tests can assert a provider was (not) invoked.
    private final class SpyProvider: TextSnapshotProvider {
        let result: CapturedText?
        private(set) var callCount = 0
        init(_ result: CapturedText?) { self.result = result }
        func snapshot(for context: FrontmostContext) -> CapturedText? {
            callCount += 1
            return result
        }
    }

    private func context(_ bundleID: String) -> FrontmostContext {
        FrontmostContext(pid: 1, bundleID: bundleID, appName: "App", windowTitle: "W")
    }

    private func ax(_ text: String, secureField: Bool = false) -> CapturedText {
        CapturedText(text: text, source: .ax, containedSecureField: secureField)
    }
    private func ocr(_ text: String) -> CapturedText { CapturedText(text: text, source: .ocr, confidence: 0.7) }

    // MARK: Matrix resolution

    func testStrategyResolvesSeededAndDefault() {
        let caps = AppCaptureCapabilities()
        XCTAssertEqual(caps.strategy(for: "com.apple.Safari"), .axOnly)
        XCTAssertEqual(caps.strategy(for: "com.figma.Desktop"), .ocrOnly)
        XCTAssertEqual(caps.strategy(for: "com.unknown.app"), .axThenOCR) // demand-driven default
    }

    func testStrategyCustomTableAndDefault() {
        let caps = AppCaptureCapabilities(table: ["x": .ocrOnly], defaultStrategy: .axOnly)
        XCTAssertEqual(caps.strategy(for: "x"), .ocrOnly)
        XCTAssertEqual(caps.strategy(for: "y"), .axOnly)
    }

    // MARK: Fallback policy

    func testAxOnlyNeverOCRs() {
        XCTAssertFalse(OCRFallbackPolicy.shouldAttemptOCR(strategy: .axOnly, axText: nil))
        XCTAssertFalse(OCRFallbackPolicy.shouldAttemptOCR(strategy: .axOnly, axText: "short"))
        XCTAssertFalse(OCRFallbackPolicy.shouldAttemptOCR(strategy: .axOnly, axText: String(repeating: "a", count: 500)))
    }

    func testOcrOnlyAlwaysOCRs() {
        XCTAssertTrue(OCRFallbackPolicy.shouldAttemptOCR(strategy: .ocrOnly, axText: nil))
        XCTAssertTrue(OCRFallbackPolicy.shouldAttemptOCR(strategy: .ocrOnly, axText: String(repeating: "a", count: 500)))
    }

    func testAxThenOCRFiresOnlyWhenThin() {
        // nil / empty AX → thin → OCR.
        XCTAssertTrue(OCRFallbackPolicy.shouldAttemptOCR(strategy: .axThenOCR, axText: nil))
        XCTAssertTrue(OCRFallbackPolicy.shouldAttemptOCR(strategy: .axThenOCR, axText: ""))
        // At threshold (16 normalized chars) → still thin.
        XCTAssertTrue(OCRFallbackPolicy.shouldAttemptOCR(strategy: .axThenOCR, axText: String(repeating: "a", count: 16)))
        // Whitespace-heavy but normalizes below threshold → thin.
        XCTAssertTrue(OCRFallbackPolicy.shouldAttemptOCR(strategy: .axThenOCR, axText: "  a   b   c  "))
        // Above threshold → rich, no OCR.
        XCTAssertFalse(OCRFallbackPolicy.shouldAttemptOCR(strategy: .axThenOCR, axText: String(repeating: "a", count: 17)))
    }

    // MARK: Layered composition

    func testOcrOnlySkipsAX() {
        let axSpy = SpyProvider(ax("should not be read"))
        let ocrSpy = SpyProvider(ocr("figma canvas text"))
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.figma.Desktop"))
        XCTAssertEqual(result?.text, "figma canvas text")
        XCTAssertEqual(result?.source, .ocr)
        XCTAssertEqual(axSpy.callCount, 0) // AX walk skipped entirely
        XCTAssertEqual(ocrSpy.callCount, 1)
    }

    func testAxOnlyNeverCallsOCREvenWhenThin() {
        let axSpy = SpyProvider(ax("x")) // thin, but strategy forbids OCR
        let ocrSpy = SpyProvider(ocr("richer ocr text here"))
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.apple.Safari"))
        XCTAssertEqual(result?.text, "x")
        XCTAssertEqual(result?.source, .ax)
        XCTAssertEqual(ocrSpy.callCount, 0)
    }

    func testAxThenOCRKeepsRichAXWithoutOCR() {
        let rich = String(repeating: "word ", count: 20)
        let axSpy = SpyProvider(ax(rich))
        let ocrSpy = SpyProvider(ocr("unused"))
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.unknown.app"))
        XCTAssertEqual(result?.source, .ax)
        XCTAssertEqual(ocrSpy.callCount, 0) // rich AX → never screenshots
    }

    func testAxThenOCRFallsBackWhenAXEmpty() {
        let axSpy = SpyProvider(nil)
        let ocrSpy = SpyProvider(ocr("recovered from pixels"))
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.unknown.app"))
        XCTAssertEqual(result?.text, "recovered from pixels")
        XCTAssertEqual(result?.source, .ocr)
    }

    func testAxThenOCRNeverRegressesBelowAX() {
        // AX is thin (triggers OCR) but OCR comes back nil → keep the thin AX.
        let axSpy = SpyProvider(ax("some title"))
        let ocrSpy = SpyProvider(nil)
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.unknown.app"))
        XCTAssertEqual(result?.text, "some title")
        XCTAssertEqual(result?.source, .ax)
    }

    func testAxThenOCRPrefersLongerText() {
        // Thin AX triggers OCR, but OCR is even shorter → keep AX (prefer more text).
        let axSpy = SpyProvider(ax("sixteen chars ok")) // 16 chars → thin
        let ocrSpy = SpyProvider(ocr("tiny"))
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.unknown.app"))
        XCTAssertEqual(result?.source, .ax)
        XCTAssertEqual(result?.text, "sixteen chars ok")
    }

    func testAxThenOCRRescuesTitleOnlyWindow() {
        // The headline rescue path: thin BUT non-empty AX (a title-only Electron
        // window), OCR strictly longer → OCR wins and is labelled .ocr.
        let axSpy = SpyProvider(ax("some title")) // 10 chars → thin, non-nil
        let ocrSpy = SpyProvider(ocr("far more recovered text from an electron canvas"))
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.unknown.app"))
        XCTAssertEqual(result?.text, "far more recovered text from an electron canvas")
        XCTAssertEqual(result?.source, .ocr)
        XCTAssertEqual(ocrSpy.callCount, 1)
    }

    func testAxThenOCREqualLengthTieKeepsAX() {
        // On a tie, near-lossless AX (.ax) must win over lossy OCR (.ocr).
        let axSpy = SpyProvider(ax("sixteen chars ok")) // 16 normalized chars, thin
        let ocrSpy = SpyProvider(ocr("also-16-chars-ok"))  // also 16 normalized chars
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.unknown.app"))
        XCTAssertEqual(result?.source, .ax)
        XCTAssertEqual(result?.text, "sixteen chars ok")
    }

    func testSecureFieldSuppressesOCR() {
        // AX saw (and skipped) a secure field: even though its text is thin, OCR
        // must NOT fire — a screenshot would recapture the credential surface.
        let axSpy = SpyProvider(ax("Sign in", secureField: true)) // thin + secure
        let ocrSpy = SpyProvider(ocr("password hint and account details from pixels"))
        let provider = LayeredTextSnapshotProvider(ax: axSpy, ocr: ocrSpy)
        let result = provider.snapshot(for: context("com.unknown.app"))
        XCTAssertEqual(result?.text, "Sign in")
        XCTAssertEqual(result?.source, .ax)
        XCTAssertEqual(ocrSpy.callCount, 0) // never screenshotted the secure window
    }

    // MARK: OCR reading-order assembly

    func testAssembleEmpty() {
        XCTAssertEqual(OCRTextAssembler.assemble([]), "")
    }

    func testAssembleSingle() {
        XCTAssertEqual(OCRTextAssembler.assemble([OCRObservation(text: "hello", top: 0.5, left: 0.1)]), "hello")
    }

    func testAssembleOrdersTopToBottom() {
        // Given out of order; higher `top` (Vision bottom-left origin) is higher on screen.
        let obs = [
            OCRObservation(text: "bottom", top: 0.10, left: 0.1),
            OCRObservation(text: "top", top: 0.90, left: 0.1),
            OCRObservation(text: "middle", top: 0.50, left: 0.1),
        ]
        XCTAssertEqual(OCRTextAssembler.assemble(obs), "top\nmiddle\nbottom")
    }

    func testAssembleJoinsSameLineLeftToRight() {
        // Two runs within lineEpsilon of each other in `top` → one line, left-to-right.
        let obs = [
            OCRObservation(text: "world", top: 0.800, left: 0.6),
            OCRObservation(text: "hello", top: 0.805, left: 0.1),
            OCRObservation(text: "next", top: 0.50, left: 0.1),
        ]
        XCTAssertEqual(OCRTextAssembler.assemble(obs), "hello world\nnext")
    }

    func testAssembleChainedTopsAreDeterministic() {
        // Chained tops: consecutive diffs (0.010) ≤ epsilon but the span (0.020) >
        // epsilon — the exact input that made the old pairwise-epsilon comparator
        // intransitive, so `sorted` returned an input-order-dependent permutation.
        // With the total-order sort the output is fixed regardless of input order.
        let a = OCRObservation(text: "a", top: 0.500, left: 0.1)
        let b = OCRObservation(text: "b", top: 0.510, left: 0.5)
        let c = OCRObservation(text: "c", top: 0.520, left: 0.9)
        let expected = "b c\na" // anchor=c(0.520); b within ε → line1 (left-sorted b,c); a beyond ε → line2
        XCTAssertEqual(OCRTextAssembler.assemble([a, b, c]), expected)
        XCTAssertEqual(OCRTextAssembler.assemble([c, b, a]), expected) // permutation-independent
        XCTAssertEqual(OCRTextAssembler.assemble([b, a, c]), expected)
    }

    func testAssembleMultiRunLineLeftToRight() {
        // 3+ runs all within epsilon of each other → one line, ordered by `left`
        // regardless of input order and sub-pixel top jitter.
        let obs = [
            OCRObservation(text: "c", top: 0.502, left: 0.9),
            OCRObservation(text: "a", top: 0.505, left: 0.1),
            OCRObservation(text: "b", top: 0.500, left: 0.5),
        ]
        XCTAssertEqual(OCRTextAssembler.assemble(obs), "a b c")
    }
}
