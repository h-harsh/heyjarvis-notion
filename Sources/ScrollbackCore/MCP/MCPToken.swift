import Foundation

/// The per-connection capability token for the daemon recall socket. `mode 0600`
/// on the socket already restricts connections to the same UID; the token is
/// defense-in-depth so a *different* same-UID process (a compromised app) can't
/// read memory without also holding the token, which lives in a `mode 0600` file
/// only the authorized proxy reads (CLAUDE.md: "Unix-socket API, mode 0600 +
/// per-client token").
///
/// 128 bits of system randomness → brute force over a one-guess-per-connection
/// handshake is hopeless. Comparison is constant-time so a co-resident process
/// can't recover the token a byte at a time via response-timing.
public struct MCPToken: Sendable, Equatable {
    public let hex: String

    public init(hex: String) { self.hex = hex }

    /// 16 random bytes (128 bits) as lowercase hex. `SystemRandomNumberGenerator`
    /// is CSPRNG-backed on Apple platforms.
    public static func random() -> MCPToken {
        var rng = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: UInt8.min...UInt8.max, using: &rng) }
        return MCPToken(hex: bytes.map { String(format: "%02x", $0) }.joined())
    }

    /// Constant-time equality. The length check is not a leak — the token length is
    /// fixed and public (32 hex chars); only the *contents* are secret, and those are
    /// compared with no data-dependent early exit.
    public func matches(_ candidate: String) -> Bool {
        let expected = Array(hex.utf8)
        let provided = Array(candidate.utf8)
        guard expected.count == provided.count else { return false }
        var diff: UInt8 = 0
        for i in expected.indices { diff |= expected[i] ^ provided[i] }
        return diff == 0
    }
}
