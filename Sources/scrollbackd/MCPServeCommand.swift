import Foundation
import ScrollbackCore

/// `~/Library/Application Support/Scrollback` — the base support dir (parent of
/// `store`). Holds the recall socket + its token file.
func scrollbackSupportDirectory() throws -> URL {
    try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Scrollback", isDirectory: true)
}

/// `scrollbackd mcp-serve` — serve read-only recall over the local AF_UNIX socket so
/// the `scrollback-mcp` proxy (and thus Claude) can query the captured store. NO TCC
/// needed (reads the store, no capture) and NO networking (local socket only), so the
/// founder can exercise the recall path independently of a live capture session.
///
/// Standalone by design this increment: it does not couple to the capture daemon's
/// lifecycle. Folding the same server into `runDaemon()` (serve-while-capturing) is a
/// follow-up once the transport proves out on the Mac.
@MainActor
func runMCPServe() -> Int32 {
    do {
        let support = try scrollbackSupportDirectory()
        let catalog = try ShardedCatalog(directory: try scrollbackStoreDirectory())

        // Clear the embedding backlog cheaply (lexical fallback) so recall works even
        // if no capture daemon ran a background pass — same rationale as `search`.
        let indexer = EmbeddingIndexer(provider: HashingEmbeddingProvider())
        _ = try? catalog.indexEmbeddings(indexer)

        // isLocked stays false for the plaintext walking skeleton; the Secure-Enclave
        // lock gate wires in here once key custody lands.
        let service = MemoryMCPService(store: catalog, embedder: HashingEmbeddingProvider())

        let token = MCPToken.random()
        let socketPath = support.appendingPathComponent("mcp.sock").path
        let tokenPath = support.appendingPathComponent("mcp.token").path
        try writeTokenFile(token, to: tokenPath)

        let server = MCPSocketServer(socketPath: socketPath, service: service, token: token)
        try server.start()

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
