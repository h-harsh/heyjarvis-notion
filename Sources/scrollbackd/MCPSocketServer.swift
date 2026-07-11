import Foundation
import Darwin
import ScrollbackCore

// The daemon's local recall transport. A POSIX AF_UNIX **stream** socket — local
// IPC, deliberately NOT Network.framework: `scrollbackd` must link no networking
// (CLAUDE.md Never #1 / verify check #5), and a Unix domain socket carries no packets
// off the machine. All egress still lives only in scrollback-courier.
//
// Topology: one accept thread; one dedicated thread per connection doing blocking
// reads; every request funneled through a single serial `requestQueue` because the
// shared `MemoryMCPService` (and its `QueryThrottle`) is single-threaded by contract.
// Per-connection handlers hold their own auth state, mutated only inside that queue.
//
// This is the ONE live edge of the MCP layer — its protocol logic is proven headless
// (MCPFraming / MCPConnectionHandler); here we only wire syscalls to it.
final class MCPSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let service: MemoryMCPService
    private let token: MCPToken
    private let requestQueue = DispatchQueue(label: "scrollback.mcp.request") // serializes service access
    private let stateLock = NSLock()
    private var listenFD: Int32 = -1
    private var liveConnections = 0
    private var stopped = false

    /// A same-UID cap so a misbehaving client can't exhaust threads/FDs. The real
    /// client is a single proxy; this is slack for reconnects.
    private let maxConnections = 8

    /// A silent peer must complete the `hello` handshake within this deadline or be
    /// reaped — otherwise an UNauthenticated slowloris (no token needed to connect)
    /// could pin every slot forever. Relaxed to blocking once authenticated (a legit
    /// proxy may idle between queries; and an authed peer already holds the token, so
    /// it has full read access regardless).
    private let handshakeTimeoutSeconds = 5

    init(socketPath: String, service: MemoryMCPService, token: MCPToken) {
        self.socketPath = socketPath
        self.service = service
        self.token = token
    }

    // MARK: - Lifecycle

    /// Bind + listen, then spawn the accept thread. Throws on any setup failure.
    func start() throws {
        // Backstop: never let a write() to a dead recall peer raise SIGPIPE and take
        // the whole daemon down. Per-fd SO_NOSIGPIPE (below) is the primary guard; this
        // covers any future write path too. Independent of the SIGINT/SIGTERM handlers.
        _ = signal(SIGPIPE, SIG_IGN)

        guard socketPath.utf8.count < 104 else { throw SocketError.pathTooLong } // sun_path is 104 bytes

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.syscall("socket", errno) }

        unlink(socketPath) // clear a stale socket from a prior run (ignore ENOENT)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutablePointer(to: &addr.sun_path) { raw in
            raw.withMemoryRebound(to: CChar.self, capacity: 104) { dst in
                socketPath.withCString { src in strncpy(dst, src, 103) }
            }
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else { let e = errno; close(fd); throw SocketError.syscall("bind", e) }

        // Restrict to the owner. Even though bind honors umask, set it explicitly so
        // the socket is owner-only regardless of the process umask.
        guard chmod(socketPath, 0o600) == 0 else { let e = errno; close(fd); throw SocketError.syscall("chmod", e) }
        guard listen(fd, 4) == 0 else { let e = errno; close(fd); throw SocketError.syscall("listen", e) }

        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "scrollback.mcp.accept"
        thread.start()
    }

    /// Close the listener and remove the socket file. In-flight connections drain on
    /// their own threads (their next blocked read returns 0 once the peer/FD closes).
    func stop() {
        stateLock.lock()
        stopped = true
        let fd = listenFD
        listenFD = -1
        stateLock.unlock()
        if fd >= 0 { close(fd) }
        unlink(socketPath)
    }

    // MARK: - Accept

    private func acceptLoop() {
        while true {
            stateLock.lock(); let fd = listenFD; let done = stopped; stateLock.unlock()
            guard !done, fd >= 0 else { return }

            let clientFD = accept(fd, nil, nil)
            if clientFD < 0 {
                let err = errno
                stateLock.lock(); let stopping = stopped; stateLock.unlock()
                if stopping { return } // listener closed by stop()
                switch err {
                case EINTR, ECONNABORTED:
                    continue // transient — a peer aborted mid-handshake; keep serving
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    usleep(10_000); continue // resource pressure — back off, don't die or busy-spin
                default:
                    return // genuinely fatal listener error
                }
            }

            stateLock.lock()
            let overCap = liveConnections >= maxConnections
            if !overCap { liveConnections += 1 }
            stateLock.unlock()

            if overCap { close(clientFD); continue } // shed load rather than pile threads

            let conn = Thread { [weak self] in self?.serve(clientFD) }
            conn.name = "scrollback.mcp.conn"
            conn.start()
        }
    }

    // MARK: - Per-connection

    private func serve(_ fd: Int32) {
        defer {
            close(fd)
            stateLock.lock(); liveConnections -= 1; stateLock.unlock()
        }
        configureConnection(fd) // SO_NOSIGPIPE + the handshake read deadline

        // Fresh handler = fresh auth state; the token/service are shared.
        let handler = MCPConnectionHandler(service: service, token: token)
        var accumulator = MCPFrameAccumulator()
        var readBuffer = [UInt8](repeating: 0, count: 16 * 1024)
        var authenticated = false // mirrors the handler; governs the read-timeout policy

        while true {
            let n = read(fd, &readBuffer, readBuffer.count)
            if n == 0 { return } // peer closed
            if n < 0 {
                let err = errno
                if err == EINTR { continue }
                // A receive-timeout fired. Reap a peer that stalled BEFORE the
                // handshake (the unauthenticated-slowloris DoS — no token needed to
                // open a connection); tolerate an authenticated idle peer (it already
                // holds the token → full read access, so pinning a slot buys nothing,
                // and the real proxy may sit idle between queries).
                if err == EAGAIN || err == EWOULDBLOCK { if authenticated { continue } else { return } }
                return
            }
            accumulator.append(Data(readBuffer[0..<n]))

            while true {
                let frame: Data?
                do {
                    frame = try accumulator.nextFrame()
                } catch {
                    return // frame too large — stream is unrecoverable, drop the connection
                }
                guard let frame else { break } // need more bytes

                // Confine service + handler-state access to the serial request queue
                // (contract: the service + throttle are single-threaded). `Date()` is
                // fine here — the daemon is a normal process, not the workflow sandbox.
                let (reply, shouldClose, nowAuthed): (Data, Bool, Bool) = requestQueue.sync {
                    let (r, c) = handler.handle(frame: frame, at: Date())
                    return (r, c, handler.isAuthenticated)
                }
                if !writeAll(fd, reply) { return } // peer went away mid-write
                if shouldClose { return }
                if nowAuthed && !authenticated { // handshake done → relax the read deadline
                    authenticated = true
                    setReadTimeout(fd, seconds: 0) // 0 = block indefinitely (a legit proxy may idle)
                }
            }
        }
    }

    /// Per-connection socket setup. SO_NOSIGPIPE is NOT inherited across `accept`, so
    /// it must be set on each accepted fd — without it a peer that closes its read half
    /// makes our `write` raise SIGPIPE and kill the whole daemon. Best-effort (the
    /// process-wide `SIG_IGN` in `start()` is the backstop). Plus a handshake read
    /// deadline so a silent peer can't pin a connection slot.
    private func configureConnection(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        setReadTimeout(fd, seconds: handshakeTimeoutSeconds)
    }

    /// Set SO_RCVTIMEO. `seconds == 0` means "block indefinitely" (the POSIX default).
    private func setReadTimeout(_ fd: Int32, seconds: Int) {
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Write every byte or report failure (a single `write` may be partial on a stream).
    private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written <= 0 {
                    if written < 0 && errno == EINTR { continue }
                    return false
                }
                offset += written
            }
            return true
        }
    }

    enum SocketError: Error, CustomStringConvertible {
        case pathTooLong
        case syscall(String, Int32)
        var description: String {
            switch self {
            case .pathTooLong: return "socket path exceeds the 104-byte sun_path limit"
            case .syscall(let call, let code): return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }
}
