import Foundation

/// The structured errors the MCP recall surface returns — never a silent partial
/// result (tech-spec §3a). The MCP proxy maps these to MCP protocol errors; the app
/// UI reacts (e.g. prompts for biometric re-unlock on `.locked`).
public enum MCPError: String, Error, Sendable, Equatable, Codable {
    case locked = "LOCKED"                    // biometric session expired — needs re-unlock
    case rateLimited = "RATE_LIMITED"         // anti-hammering throttle tripped
    case emptyRange = "EMPTY_RANGE"           // the query's time range is empty/inverted
    case invalidArguments = "INVALID_ARGUMENTS" // missing/malformed tool args or unknown tool

    public var message: String {
        switch self {
        case .locked: return "Memory is locked — a biometric re-unlock is required."
        case .rateLimited: return "Too many memory queries — retry shortly."
        case .emptyRange: return "The requested time range is empty."
        case .invalidArguments: return "The tool call was missing required arguments or was not recognized."
        }
    }
}

/// Anti-hammering throttle on the MCP QUERY surface (tech-spec §4 D5: "MCP query
/// surface throttled"). This is SEPARATE from `KeyCustodyPolicy`'s unwrap rate-limit:
/// that guards the biometric key-unwrap surface, this guards recall queries so a
/// compromised MCP client can't exfiltrate the whole memory by rapid-fire search.
///
/// Pure + clock-injected (sliding window). Not thread-safe by contract (confine to
/// the daemon's request queue).
public final class QueryThrottle {
    private let maxQueries: Int
    private let window: TimeInterval
    private var recent: [Date] = []

    public init(maxQueries: Int = 30, window: TimeInterval = 60) {
        self.maxQueries = max(1, maxQueries)
        self.window = window
    }

    /// Record a query attempt at `now`. Returns true if permitted, false (→
    /// `RATE_LIMITED`) once `maxQueries` have occurred within the trailing `window`.
    /// A rejected query is NOT recorded, so the window only counts served queries.
    public func permit(at now: Date) -> Bool {
        recent = recent.filter { now.timeIntervalSince($0) < window }
        guard recent.count < maxQueries else { return false }
        recent.append(now)
        return true
    }
}
