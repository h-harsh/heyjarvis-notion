import Foundation
import ScrollbackCore

// scrollbackd — the capture + index daemon.
//
// Modes:
//   run       (default) live event-driven capture → throwaway JSONL spike store
//   simulate  deterministic fixture replay through the real engine (verify check #4)
//   ax-dump      one-shot diagnostic: extract the frontmost window's AX text
//   ocr-dump     one-shot diagnostic: screenshot + Vision-OCR the frontmost window
//   windows-dump one-shot diagnostic: what an all-windows sweep would capture now
//   mcp-serve    serve read-only recall over the local AF_UNIX socket (no TCC, no net)
//
// By design this target links NO networking — all egress flows through
// scrollback-courier. See CLAUDE.md (Architecture) and verify check #5.

let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "simulate":
    exit(runSimulation())
case "search":
    exit(runSearch(arguments.dropFirst().joined(separator: " ")))
case "ax-dump":
    exit(runAXDump())
case "ocr-dump":
    exit(runOCRDump())
case "windows-dump":
    exit(runWindowsDump())
case "mcp-serve":
    exit(runMCPServe())
case "--version", "version":
    print("scrollbackd \(scrollbackCoreVersion)")
    exit(0)
case nil, "run":
    runDaemon()
default:
    print("""
    scrollbackd \(scrollbackCoreVersion)
    usage: scrollbackd [run|search|simulate|ax-dump|ocr-dump|windows-dump|mcp-serve|--version]
      run           (default) live event-driven capture (all visible windows) → searchable store + JSONL spike
      search "..."   hybrid retrieval over the captured store (no TCC needed)
      simulate      deterministic fixture replay through the real engine
      ax-dump       one-shot: extract the frontmost window's AX text
      ocr-dump      one-shot: screenshot + Vision-OCR the frontmost window
      windows-dump  one-shot: what an all-windows sweep would capture right now
      mcp-serve     serve read-only recall over the local AF_UNIX socket (no TCC, no net)
    """)
    exit(64)
}
