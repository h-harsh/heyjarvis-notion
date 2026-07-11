import Foundation

/// The decision returned when an operation needs the DB key.
public enum KeyAccessResult: String, Sendable, Equatable {
    case granted      // session valid → the in-memory key may be used
    case locked       // never unlocked or session expired → biometric re-unlock required (MCP: LOCKED)
}

public struct KeyCustodyConfig: Sendable {
    /// How long an unlock lasts before a fresh biometric re-unlock is required.
    public var sessionTimeout: TimeInterval
    /// Max biometric/SE unwrap ATTEMPTS allowed within `attemptWindow` — the
    /// anti-hammering limit on the (expensive, biometric-gated) unwrap surface.
    public var maxUnwrapAttempts: Int
    public var attemptWindow: TimeInterval

    public init(sessionTimeout: TimeInterval = 12 * 3600, maxUnwrapAttempts: Int = 5, attemptWindow: TimeInterval = 60) {
        self.sessionTimeout = sessionTimeout
        self.maxUnwrapAttempts = maxUnwrapAttempts
        self.attemptWindow = attemptWindow
    }
}

/// The pure, clock-injected policy layer of DB-key custody: session lifetime,
/// unwrap rate-limiting, and the locked/granted access decision. It holds NO key
/// material — the Secure-Enclave wrapping/unwrapping lives in the daemon's
/// hardware layer (needs SE + biometry + entitlements, so it's live-only). Keeping
/// the policy pure means the load-bearing behaviors the tech-spec calls out —
/// "expired session returns LOCKED" and "hammering trips the limit" — are
/// regression-tested here instead of depending on the untestable hardware path.
///
/// Not thread-safe by contract (confine to the daemon's key actor/queue).
public final class KeyCustodyPolicy {
    private let config: KeyCustodyConfig
    private var unlockedAt: Date?
    private var attempts: [Date] = []

    public init(config: KeyCustodyConfig = KeyCustodyConfig()) {
        self.config = config
    }

    /// Gate a biometric/SE unwrap ATTEMPT before it is made. Returns false — and
    /// records nothing — once `maxUnwrapAttempts` have occurred within
    /// `attemptWindow`, defeating a process hammering the unwrap surface. Callers
    /// must NOT invoke the SE unwrap when this returns false.
    public func permitUnlockAttempt(at now: Date) -> Bool {
        attempts = attempts.filter { now.timeIntervalSince($0) < config.attemptWindow }
        guard attempts.count < config.maxUnwrapAttempts else { return false }
        attempts.append(now)
        return true
    }

    /// Record a successful biometric unlock — starts a fresh session and clears the
    /// attempt history (a legitimate unlock shouldn't count toward the next lockout).
    public func recordUnlock(at now: Date) {
        unlockedAt = now
        attempts.removeAll(keepingCapacity: true)
    }

    /// Drop the session (manual lock / pause / shutdown). The next access is LOCKED.
    public func lock() {
        unlockedAt = nil
    }

    /// The access decision for a key-requiring operation. LOCKED if never unlocked
    /// or if the session has aged past `sessionTimeout`.
    public func access(at now: Date) -> KeyAccessResult {
        guard let unlockedAt, now.timeIntervalSince(unlockedAt) < config.sessionTimeout else {
            return .locked
        }
        return .granted
    }

    public func isUnlocked(at now: Date) -> Bool {
        access(at: now) == .granted
    }

    /// Seconds until the session expires (0 if already locked). For a UI countdown.
    public func secondsRemaining(at now: Date) -> TimeInterval {
        guard let unlockedAt else { return 0 }
        return max(0, config.sessionTimeout - now.timeIntervalSince(unlockedAt))
    }
}
