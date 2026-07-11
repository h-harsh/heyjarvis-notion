import Foundation
import ScrollbackCore

/// The weekly-shard store directory the daemon writes to and `search` reads from.
/// `~/Library/Application Support/Scrollback/store`. Plaintext for the walking
/// skeleton; the SQLCipher key threads through `ShardedCatalog(key:)` unchanged once
/// the Secure-Enclave custody layer lands.
func scrollbackStoreDirectory() throws -> URL {
    try FileManager.default.url(
        for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
    ).appendingPathComponent("Scrollback/store", isDirectory: true)
}

/// `scrollbackd search "<query>"` — runs hybrid retrieval over the captured store and
/// prints spotlighted results. This is the "did it actually remember?" feedback loop:
/// capture with `scrollbackd` for a while, then search here. No TCC needed (reads the
/// local store); no networking.
func runSearch(_ query: String) -> Int32 {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        print(#"usage: scrollbackd search "your query""#)
        return 64
    }
    do {
        let directory = try scrollbackStoreDirectory()
        let catalog = try ShardedCatalog(directory: directory)
        let results = try catalog.search(MemoryQuery(text: trimmed, limit: 8))
        guard !results.isEmpty else {
            print("No matching memories yet. Capture some first: run `scrollbackd` for a while, then search.")
            return 0
        }
        print(MCPResultFormatter.format(results).rendered)
        return 0
    } catch {
        FileHandle.standardError.write(Data("scrollbackd search: \(error)\n".utf8))
        return 1
    }
}
