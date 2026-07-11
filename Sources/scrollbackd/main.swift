import Foundation
import ScrollbackCore

// scrollbackd — the capture + index daemon.
//
// Modes:
//   run       (default) live event-driven capture → throwaway JSONL spike store
//   simulate  deterministic fixture replay through the real engine (verify check #4)
//   ax-dump   one-shot diagnostic: extract the frontmost window's AX text
//   ocr-dump  one-shot diagnostic: screenshot + Vision-OCR the frontmost window
//
// By design this target links NO networking — all egress flows through
// scrollback-courier. See CLAUDE.md (Architecture) and verify check #5.

let arguments = CommandLine.arguments.dropFirst()

switch arguments.first {
case "simulate":
    exit(runSimulation())
case "ax-dump":
    exit(runAXDump())
case "ocr-dump":
    exit(runOCRDump())
case "--version", "version":
    print("scrollbackd \(scrollbackCoreVersion)")
    exit(0)
case nil, "run":
    runDaemon()
default:
    print("""
    scrollbackd \(scrollbackCoreVersion)
    usage: scrollbackd [run|simulate|ax-dump|ocr-dump|--version]
      run       (default) live event-driven capture → throwaway JSONL spike store
      simulate  deterministic fixture replay through the real engine
      ax-dump   one-shot: extract the frontmost window's AX text
      ocr-dump  one-shot: screenshot + Vision-OCR the frontmost window
    """)
    exit(64)
}
