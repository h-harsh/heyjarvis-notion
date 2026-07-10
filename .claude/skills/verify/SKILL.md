---
name: verify
description: Prove a Scrollback change actually works — static gates, then observed behavior. /build runs this before it may report done.
---

# /verify — prove it works in Scrollback

Run in order, fail-fast (fastest first). Every check is **run X → observe Y**.
A clean compile is NOT verification. If a check can't run, say so — don't pass by omission.

## Static gates

### 1. Build
Run: `swift build`
Observe: ends with `Build complete!` and exit code 0. Any compile error → fail.

### 2. Tests
Run: `swift test`
Observe: final line `Executed N tests, with 0 failures` (N ≥ 6 today) and exit 0.
This is where the load-bearing invariants are asserted with exact values:
- `RankFusion` fuses to exact RRF scores and a deterministic tie-break order.
- `CaptureEvent.provenance` defaults to `.untrustedAmbient` (the security invariant).
Adding capture/store/filing code MUST add tests here — a green build alone never counts.

### 3. Lint (only if installed)
Run: `command -v swiftlint >/dev/null 2>&1 && swiftlint --quiet || echo "swiftlint absent — skipped"`
Observe: no violations if present; "skipped" if absent. Absence is NOT a failure.

## Dynamic drive

### 4. Daemon boots
Run: `swift run scrollbackd`
Observe: stdout is exactly `scrollbackd <version> — capture daemon (skeleton; capture loop pending)` and exit 0.
(Replace this with a real capture assertion once the capture loop exists — see below.)

### 5. Capture/index code links NO networking (Never rule #1)
Run: `grep -rnE 'URLSession|NWConnection|NWListener|NWBrowser|CFSocket|CFStream|getaddrinfo|SocketPort' Sources/scrollbackd Sources/ScrollbackCore`
Observe: **zero matches** (grep exits 1). Any hit = the privacy split is broken; all egress must live in `scrollback-courier` (a separate target), never in the capture/index code. Fail the verify.

## Critical flows — add each check when the flow lands (not applicable yet)

These are the product's crown jewels (PRD gates). They can't be observed until the code exists; when a `/build` adds the flow, replace the stub here with a real run→observe check:

- **Capture spike:** feed a fixture AX tree / drive a known window → observe `CaptureEvent`s land in the store; measure `<5% average CPU` over a real hour (the launch gate). <!-- TODO: add when capture loop exists -->
- **Recall via MCP:** call `search_memory` with a seeded corpus → observe the correct episode in top-3, snippets carry provenance + are spotlighted. <!-- TODO: add at M2 -->
- **Filing agent:** run a daily digest over fixtures → observe a draft appears in the queue, re-running does NOT duplicate (idempotent `external_key`), and undo archives the created page. <!-- TODO: add at M3 -->
- **Permission-gated bits** (Screen/AX/Mic TCC) can't be headless-verified — these stay manual-observation steps, stated as such, never silently skipped.
