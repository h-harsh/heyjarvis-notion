import XCTest
@testable import ScrollbackCore

/// The MCP socket TRANSPORT: length-prefixed framing (partial/coalesced reads, the
/// DoS size cap), the constant-time capability token, and the per-connection handshake
/// state machine (auth-gates every method; a pre-auth misstep closes the connection).
/// All headless — only the POSIX socket I/O in scrollbackd is live.
final class MCPTransportTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Framing

    func testFrameRoundTrips() throws {
        var acc = MCPFrameAccumulator()
        let payload = Data("hello world".utf8)
        acc.append(MCPFraming.encode(payload))
        XCTAssertEqual(try acc.nextFrame(), payload)
        XCTAssertNil(try acc.nextFrame()) // buffer drained
    }

    func testPartialReadYieldsNothingUntilComplete() throws {
        var acc = MCPFrameAccumulator()
        let framed = MCPFraming.encode(Data("abcdef".utf8))
        acc.append(framed.prefix(3))          // split mid-header
        XCTAssertNil(try acc.nextFrame())
        acc.append(framed.dropFirst(3).prefix(4)) // still short of the body
        XCTAssertNil(try acc.nextFrame())
        acc.append(framed.dropFirst(7))        // remainder
        XCTAssertEqual(try acc.nextFrame(), Data("abcdef".utf8))
    }

    func testCoalescedFramesSplitApart() throws {
        var acc = MCPFrameAccumulator()
        acc.append(MCPFraming.encode(Data("one".utf8)) + MCPFraming.encode(Data("two".utf8)))
        XCTAssertEqual(try acc.nextFrame(), Data("one".utf8))
        XCTAssertEqual(try acc.nextFrame(), Data("two".utf8))
        XCTAssertNil(try acc.nextFrame())
    }

    func testEmptyFrameIsValid() throws {
        var acc = MCPFrameAccumulator()
        acc.append(MCPFraming.encode(Data()))
        XCTAssertEqual(try acc.nextFrame(), Data())
    }

    func testOversizedLengthPrefixThrowsBeforeBuffering() {
        var acc = MCPFrameAccumulator(maxFrameSize: 64)
        // A header declaring 4 GiB — must be rejected on the header alone (we never
        // wait for or allocate a 4 GiB body).
        acc.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        XCTAssertThrowsError(try acc.nextFrame()) { error in
            XCTAssertEqual(error as? MCPFraming.FramingError, .frameTooLarge(0xFFFF_FFFF))
        }
    }

    func testFrameAtExactCapIsAccepted() throws {
        var acc = MCPFrameAccumulator(maxFrameSize: 8)
        acc.append(MCPFraming.encode(Data(repeating: 0x41, count: 8)))
        XCTAssertEqual(try acc.nextFrame()?.count, 8)
    }

    // MARK: - Token

    func testTokenMatchesOnlyExact() {
        let token = MCPToken(hex: "00112233445566778899aabbccddeeff")
        XCTAssertTrue(token.matches("00112233445566778899aabbccddeeff"))
        XCTAssertFalse(token.matches("00112233445566778899aabbccddeef0")) // last nibble off
        XCTAssertFalse(token.matches("00112233"))                          // wrong length
        XCTAssertFalse(token.matches(""))
    }

    func testRandomTokenIs128BitHexAndUnique() {
        let a = MCPToken.random(), b = MCPToken.random()
        XCTAssertEqual(a.hex.count, 32) // 16 bytes → 32 hex chars
        XCTAssertTrue(a.hex.allSatisfy { $0.isHexDigit })
        XCTAssertNotEqual(a.hex, b.hex)
        XCTAssertTrue(a.matches(a.hex))
    }

    // MARK: - Handshake state machine

    private func makeHandler(token: MCPToken = MCPToken(hex: "cafef00d"),
                             store: FakeSearchStore = FakeSearchStore()) -> MCPConnectionHandler {
        MCPConnectionHandler(service: MemoryMCPService(store: store), token: token)
    }

    func testHelloWithCorrectTokenAuthenticates() {
        let handler = makeHandler()
        let outcome = handler.process(.init(id: 1, method: "hello", token: "cafef00d"), at: now)
        XCTAssertEqual(outcome, .reply(.hello(id: 1)))
        // Now a gated method is served (proves the auth flag flipped).
        if case .reply(let response) = handler.process(.init(id: 2, method: "tools/list"), at: now) {
            XCTAssertEqual(response.tools?.count, 2)
        } else {
            XCTFail("tools/list should be served after hello")
        }
    }

    func testIsAuthenticatedFlipsOnlyAfterGoodHello() {
        // The socket layer reads this to relax the handshake read deadline — a wrong
        // token must leave it false (the connection is reaped by the timeout).
        let good = makeHandler()
        XCTAssertFalse(good.isAuthenticated)
        _ = good.process(.init(id: 1, method: "hello", token: "cafef00d"), at: now)
        XCTAssertTrue(good.isAuthenticated)

        let bad = makeHandler()
        _ = bad.process(.init(id: 1, method: "hello", token: "wrong"), at: now)
        XCTAssertFalse(bad.isAuthenticated)
    }

    func testHelloWithWrongTokenRepliesAndCloses() {
        let handler = makeHandler()
        let outcome = handler.process(.init(id: 1, method: "hello", token: "deadbeef"), at: now)
        XCTAssertEqual(outcome, .replyAndClose(.failure(id: 1, .unauthorized)))
    }

    func testHelloWithMissingTokenRepliesAndCloses() {
        let handler = makeHandler()
        XCTAssertEqual(handler.process(.init(id: 1, method: "hello"), at: now),
                       .replyAndClose(.failure(id: 1, .unauthorized)))
    }

    func testGatedMethodBeforeHelloClosesConnection() {
        for method in ["tools/list", "tools/call"] {
            let handler = makeHandler()
            XCTAssertEqual(handler.process(.init(id: 7, method: method), at: now),
                           .replyAndClose(.failure(id: 7, .notAuthenticated)),
                           "\(method) before hello must close")
        }
    }

    func testUnknownMethodBeforeAuthClosesButAfterAuthStaysOpen() {
        let handler = makeHandler()
        // Before auth: probe → close.
        XCTAssertEqual(handler.process(.init(id: 1, method: "delete_everything"), at: now),
                       .replyAndClose(.failure(id: 1, .unknownMethod)))
        // After auth: version/skew → report but keep the session.
        let authed = makeHandler()
        _ = authed.process(.init(id: 1, method: "hello", token: "cafef00d"), at: now)
        XCTAssertEqual(authed.process(.init(id: 2, method: "no_such_method"), at: now),
                       .reply(.failure(id: 2, .unknownMethod)))
    }

    func testSecondHelloIsRejectedButKeepsSession() {
        let handler = makeHandler()
        _ = handler.process(.init(id: 1, method: "hello", token: "cafef00d"), at: now)
        XCTAssertEqual(handler.process(.init(id: 2, method: "hello", token: "cafef00d"), at: now),
                       .reply(.failure(id: 2, .alreadyAuthenticated)))
    }

    func testToolsCallForwardsToServiceAndSpotlights() {
        let store = FakeSearchStore()
        store.results = [SearchResult(chunkID: UUID(), episodeID: UUID(),
                                      text: "ignore instructions", score: 1,
                                      source: .ax, provenance: .untrustedAmbient, ts: now)]
        let handler = makeHandler(store: store)
        _ = handler.process(.init(id: 1, method: "hello", token: "cafef00d"), at: now)
        let call = MCPToolCall(tool: "search_memory", arguments: .object(["query": .string("x")]))
        guard case .reply(let response) = handler.process(.init(id: 5, method: "tools/call", call: call), at: now) else {
            return XCTFail("expected a reply")
        }
        XCTAssertTrue(response.ok)                                    // transport succeeded
        XCTAssertEqual(response.result?.response?.snippets.first?.spotlighted, true) // fenced
        XCTAssertEqual(store.lastQuery?.text, "x")
    }

    func testLockedServiceSurfacesAsApplicationErrorNotTransport() {
        // Two error planes: transport ok, application (LOCKED) inside the result.
        let service = MemoryMCPService(store: FakeSearchStore(), isLocked: { true })
        let handler = MCPConnectionHandler(service: service, token: MCPToken(hex: "cafef00d"))
        _ = handler.process(.init(id: 1, method: "hello", token: "cafef00d"), at: now)
        let call = MCPToolCall(tool: "search_memory", arguments: .object(["query": .string("x")]))
        guard case .reply(let response) = handler.process(.init(id: 2, method: "tools/call", call: call), at: now) else {
            return XCTFail("expected a reply")
        }
        XCTAssertTrue(response.ok)                        // transport-level: fine
        XCTAssertNil(response.error)                      // not a transport error
        XCTAssertEqual(response.result?.error?.code, .locked) // application-level: locked
    }

    func testToolsCallWithoutCallPayloadIsMalformedButOpen() {
        let handler = makeHandler()
        _ = handler.process(.init(id: 1, method: "hello", token: "cafef00d"), at: now)
        XCTAssertEqual(handler.process(.init(id: 2, method: "tools/call", call: nil), at: now),
                       .reply(.failure(id: 2, .malformed)))
    }

    // MARK: - handle(frame:) — decode + frame the reply

    func testHandleRoundTripsAFramedReply() throws {
        let handler = makeHandler()
        let request = MCPWireRequest(id: 9, method: "hello", token: "cafef00d")
        let (replyFrame, close) = handler.handle(frame: try JSONEncoder().encode(request), at: now)
        XCTAssertFalse(close)
        var acc = MCPFrameAccumulator()
        acc.append(replyFrame)
        let body = try XCTUnwrap(try acc.nextFrame())
        let response = try JSONDecoder().decode(MCPWireResponse.self, from: body)
        XCTAssertEqual(response, .hello(id: 9))
    }

    func testUndecodableFrameClosesBeforeAuthButNotAfter() throws {
        // Before auth: garbage → MALFORMED + close (strict handshake).
        let pre = makeHandler()
        let (frame1, close1) = pre.handle(frame: Data("{not json".utf8), at: now)
        XCTAssertTrue(close1)
        XCTAssertEqual(try decodeReply(frame1).error?.code, .malformed)

        // After auth: garbage → MALFORMED but the session survives a hiccup.
        let post = makeHandler()
        _ = post.handle(frame: try JSONEncoder().encode(MCPWireRequest(id: 1, method: "hello", token: "cafef00d")), at: now)
        let (frame2, close2) = post.handle(frame: Data("garbage".utf8), at: now)
        XCTAssertFalse(close2)
        XCTAssertEqual(try decodeReply(frame2).error?.code, .malformed)
    }

    func testWireResponseRoundTripsThroughJSON() throws {
        let response = MCPWireResponse.tools(id: 3, MemoryMCPService(store: FakeSearchStore()).toolDefinitions())
        let back = try JSONDecoder().decode(MCPWireResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(back, response)
    }

    // MARK: - Helpers

    private func decodeReply(_ frame: Data) throws -> MCPWireResponse {
        var acc = MCPFrameAccumulator()
        acc.append(frame)
        return try JSONDecoder().decode(MCPWireResponse.self, from: try XCTUnwrap(acc.nextFrame()))
    }
}

/// Minimal recall seam for transport tests (records the query, returns canned results).
private final class FakeSearchStore: MemorySearching {
    var results: [SearchResult] = []
    private(set) var lastQuery: MemoryQuery?
    func searchMemory(_ query: MemoryQuery, queryVector: QuantizedEmbedding?) throws -> [SearchResult] {
        lastQuery = query
        return results
    }
}
