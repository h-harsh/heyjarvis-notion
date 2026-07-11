import Foundation
import ScrollbackCore

/// `~/Library/Application Support/Scrollback` — the base support dir (parent of
/// `store`). Holds the recall socket + its token file.
func scrollbackSupportDirectory() throws -> URL {
    try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Scrollback", isDirectory: true)
}

/// Build + start the read-only recall socket over `catalog` and return the running
/// server (the caller stops it on shutdown) plus the paths, so `mcp-serve` (standalone)
/// and `run` (serve-while-capturing) share one code path. Mints a fresh 128-bit token
/// into the mode-0600 token file. `isLocked` stays false for the plaintext walking
/// skeleton — the Secure-Enclave lock gate wires in here once key custody lands.
func startRecallSocket(catalog: ShardedCatalog) throws -> (server: MCPSocketServer, socketPath: String, tokenPath: String) {
    let support = try scrollbackSupportDirectory()
    let service = MemoryMCPService(store: catalog, embedder: HashingEmbeddingProvider())
    let token = MCPToken.random()
    let socketPath = support.appendingPathComponent("mcp.sock").path
    let tokenPath = support.appendingPathComponent("mcp.token").path
    try writeTokenFile(token, to: tokenPath)
    let server = MCPSocketServer(socketPath: socketPath, service: service, token: token)
    try server.start()
    return (server, socketPath, tokenPath)
}

/// Start the recall socket for the capture daemon (serve-while-capturing). Uses a
/// SECOND `ShardedCatalog` — its own SQLite connections — to READ the same WAL store
/// the capture path writes: WAL gives one writer + N readers, so recall never blocks
/// capture and there's no shared mutable Swift state across the two threads' access.
/// Failure is NON-fatal: capture is the priority, so if the socket can't bind the
/// daemon keeps capturing and the founder can run `mcp-serve` separately.
func startRecallServerForCaptureDaemon() -> MCPSocketServer? {
    do {
        let recallCatalog = try ShardedCatalog(directory: try scrollbackStoreDirectory())
        let started = try startRecallSocket(catalog: recallCatalog)
        print("recall: serving MCP at \(started.socketPath) (mode 0600) — point scrollback-mcp here.")
        print("        (run `scrollbackd run` OR `mcp-serve`, not both — they bind the same socket.)")
        return started.server
    } catch {
        FileHandle.standardError.write(Data(
            "recall: socket unavailable (\(error)) — capture continues; use `mcp-serve` separately.\n".utf8))
        return nil
    }
}

/// `scrollbackd mcp-serve` — serve read-only recall over the local AF_UNIX socket so
/// the `scrollback-mcp` proxy (and thus Claude) can query the captured store. NO TCC
/// needed (reads the store, no capture) and NO networking (local socket only), so the
/// founder can exercise recall WITHOUT a live capture session. `scrollbackd run` now
/// also serves recall while capturing (via `startRecallServerForCaptureDaemon`); this
/// standalone command is for recall-without-capture.
@MainActor
func runMCPServe() -> Int32 {
    do {
        let catalog = try ShardedCatalog(directory: try scrollbackStoreDirectory())

        // Clear the embedding backlog cheaply (lexical fallback) so recall works even
        // if no capture daemon ran a background pass — same rationale as `search`.
        let indexer = EmbeddingIndexer(provider: HashingEmbeddingProvider())
        _ = try? catalog.indexEmbeddings(indexer)

        let (server, socketPath, tokenPath) = try startRecallSocket(catalog: catalog)
        installShutdownHandler { server.stop() }

        print("scrollbackd \(scrollbackCoreVersion) — MCP recall socket")
        print("  socket : \(socketPath)   (mode 0600, local IPC — no networking)")
        print("  token  : \(tokenPath)     (mode 0600 — the proxy reads this)")
        print("Point scrollback-mcp at these two paths. Ctrl-C to stop.")
        print("(plaintext store for now — encryption + the real embedding model land next.)")
        RunLoop.main.run()
        return 0
    } catch {
        FileHandle.standardError.write(Data("scrollbackd mcp-serve: \(error)\n".utf8))
        return 1
    }
}

/// Write the token hex to a `mode 0600` file, creating it owner-only at birth (no
/// window where it exists world-readable).
private func writeTokenFile(_ token: MCPToken, to path: String) throws {
    let fm = FileManager.default
    if fm.fileExists(atPath: path) { try? fm.removeItem(atPath: path) }
    guard fm.createFile(atPath: path, contents: Data(token.hex.utf8),
                        attributes: [.posixPermissions: 0o600]) else {
        throw NSError(domain: "scrollbackd.mcp", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "could not write token file at \(path)"])
    }
}
