import Foundation

/// TRANSPORT-level failures on the daemon socket — distinct from application-level
/// `MCPError` (LOCKED / RATE_LIMITED / …). A transport error means the request never
/// reached the recall service (bad handshake, malformed frame, unknown method); an
/// `MCPError` means the service ran and declined. Keeping the two planes separate
/// keeps the contract honest: the proxy can tell "you're not allowed to ask" from
/// "I looked and the answer is locked/empty".
public enum MCPTransportError: String, Error, Sendable, Equatable, Codable {
    case unauthorized = "UNAUTHORIZED"                 // bad/missing token on handshake
    case notAuthenticated = "NOT_AUTHENTICATED"        // a method before a successful `hello`
    case alreadyAuthenticated = "ALREADY_AUTHENTICATED" // a second `hello` on one connection
    case malformed = "MALFORMED"                       // frame wasn't a decodable request
    case unknownMethod = "UNKNOWN_METHOD"              // method not in the protocol

    public var message: String {
        switch self {
        case .unauthorized: return "Handshake token was missing or incorrect."
        case .notAuthenticated: return "Send `hello` with a valid token before any other method."
        case .alreadyAuthenticated: return "This connection has already completed its handshake."
        case .malformed: return "The request frame was not valid JSON for the wire protocol."
        case .unknownMethod: return "The requested method is not part of the recall protocol."
        }
    }
}

/// One request on the daemon socket. `method` is `hello` | `tools/list` | `tools/call`.
/// `token` accompanies `hello`; `call` accompanies `tools/call`. `id` is echoed back
/// so the proxy can correlate even if it pipelines.
public struct MCPWireRequest: Codable, Sendable, Equatable {
    public let id: Int
    public let method: String
    public let token: String?
    public let call: MCPToolCall?

    public init(id: Int, method: String, token: String? = nil, call: MCPToolCall? = nil) {
        self.id = id
        self.method = method
        self.token = token
        self.call = call
    }
}

public struct MCPWireError: Codable, Sendable, Equatable {
    public let code: MCPTransportError
    public let message: String
    public init(_ code: MCPTransportError) {
        self.code = code
        self.message = code.message
    }
}

/// One reply on the daemon socket. Exactly one of `tools` / `result` / `error` is set,
/// mirroring the "never a silent partial" rule at the transport layer too: a request
/// either produced a tool list, a (possibly-failed) tool result, or a transport error.
public struct MCPWireResponse: Codable, Sendable, Equatable {
    public let id: Int
    public let ok: Bool
    public let tools: [MCPToolDefinition]?
    public let result: MCPCallResponse?
    public let error: MCPWireError?

    private init(id: Int, ok: Bool, tools: [MCPToolDefinition]? = nil,
                 result: MCPCallResponse? = nil, error: MCPWireError? = nil) {
        self.id = id
        self.ok = ok
        self.tools = tools
        self.result = result
        self.error = error
    }

    static func hello(id: Int) -> MCPWireResponse { MCPWireResponse(id: id, ok: true) }
    static func tools(id: Int, _ defs: [MCPToolDefinition]) -> MCPWireResponse {
        MCPWireResponse(id: id, ok: true, tools: defs)
    }
    static func call(id: Int, _ result: MCPCallResponse) -> MCPWireResponse {
        MCPWireResponse(id: id, ok: true, result: result)
    }
    static func failure(id: Int, _ error: MCPTransportError) -> MCPWireResponse {
        MCPWireResponse(id: id, ok: false, error: MCPWireError(error))
    }
}

/// The per-connection protocol state machine. One instance per accepted connection
/// (it holds that connection's auth state); the shared `MemoryMCPService` it calls is
/// NOT thread-safe, so the socket layer funnels every `handle`/`process` call through
/// a single serial queue. Pure + clock-injected — fully tested without a socket.
///
/// Handshake discipline: the FIRST frame must be a valid `hello` carrying the correct
/// token. Any pre-auth misstep (wrong token, wrong method, or an undecodable frame)
/// closes the connection, bounding a probe/brute-force attacker to one attempt per
/// connect. After authentication, a malformed frame is tolerated (framing is intact;
/// an authorized client had a hiccup) and the connection stays open.
public final class MCPConnectionHandler {
    private let service: MemoryMCPService
    private let token: MCPToken
    private var authenticated = false

    public init(service: MemoryMCPService, token: MCPToken) {
        self.service = service
        self.token = token
    }

    /// Whether this connection has completed its handshake. Read only on the socket
    /// layer's serial request queue (the same queue that mutates it), so it needs no
    /// further synchronization. The transport uses it to relax the handshake read
    /// deadline once a peer is authenticated.
    public var isAuthenticated: Bool { authenticated }

    public enum Outcome: Equatable {
        case reply(MCPWireResponse)         // send, keep the connection open
        case replyAndClose(MCPWireResponse) // send, then close
    }

    /// Process one decoded request against the current auth state.
    public func process(_ request: MCPWireRequest, at now: Date) -> Outcome {
        switch request.method {
        case "hello":
            guard !authenticated else { return .reply(.failure(id: request.id, .alreadyAuthenticated)) }
            guard let candidate = request.token, token.matches(candidate) else {
                return .replyAndClose(.failure(id: request.id, .unauthorized))
            }
            authenticated = true
            return .reply(.hello(id: request.id))

        case "tools/list":
            guard authenticated else { return .replyAndClose(.failure(id: request.id, .notAuthenticated)) }
            return .reply(.tools(id: request.id, service.toolDefinitions()))

        case "tools/call":
            guard authenticated else { return .replyAndClose(.failure(id: request.id, .notAuthenticated)) }
            guard let call = request.call else { return .reply(.failure(id: request.id, .malformed)) }
            return .reply(.call(id: request.id, service.handle(call, at: now)))

        default:
            // An unknown method while unauthenticated is a probe → close; while
            // authenticated it's a client/version mismatch → report, stay open.
            let response = MCPWireResponse.failure(id: request.id, .unknownMethod)
            return authenticated ? .reply(response) : .replyAndClose(response)
        }
    }

    /// Decode one raw request frame and produce the raw reply frame + whether to close
    /// afterwards. A frame that won't decode is MALFORMED — closed before auth (strict
    /// handshake), tolerated after. This is the single entry point the socket layer calls.
    public func handle(frame: Data, at now: Date) -> (reply: Data, close: Bool) {
        guard let request = try? JSONDecoder().decode(MCPWireRequest.self, from: frame) else {
            let response = MCPWireResponse.failure(id: 0, .malformed)
            return (encode(response), close: !authenticated)
        }
        switch process(request, at: now) {
        case .reply(let response): return (encode(response), close: false)
        case .replyAndClose(let response): return (encode(response), close: true)
        }
    }

    private func encode(_ response: MCPWireResponse) -> Data {
        MCPFraming.encode((try? JSONEncoder().encode(response)) ?? Data())
    }
}
