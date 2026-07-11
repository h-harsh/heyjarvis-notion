# STATE — Scrollback — 2026-07-11

## Now
M1 capture core underway. Capture spike shipped + hardened. Next concrete step: the **capture perf pass** (batch AX reads via `AXUIElementCopyMultipleAttributeValues`, stop double window-fetch, coalesce title-change churn) — required to hold the M1 <5% CPU gate on heavy-AX apps.

## Just finished
- Event-driven capture spike: `CaptureEngine` (episodes, typing debounce, per-episode hash dedup, idle, activity-gated fallback — no fixed-interval polling) in ScrollbackCore; AX-tree extractor + main-run-loop `CaptureRuntime` (NSWorkspace + AXObserver + pasteboard probe + CGEvent idle) + throwaway JSONL sink + self-asserting `simulate` in scrollbackd. 29 tests green; verify check #4 = the fixture drive.
- 8-angle code review (35 findings) run before commit. Fixed all correctness/security: **secure-field guard was checking role vs a subrole value → would have captured passwords** (now `AXCapturePolicy`, unit-tested); app-driven content changes no longer defeat idle; resume-after-idle reopens episodes; tsEnd can't regress; SIGINT flushes the open episode; observedPID set only on observer-create success; JSONL rotates per day; provider protocol widened (`CapturedText`) for the imminent OCR task. Deferred perf findings → new TODO task.

## Blocked / Open questions
- **Founder actions, time-critical:** register getscrollback.com (squattable); enroll Apple Developer Program (lead time).
- **Dated:** Otter.AI MTD hearing Jul 15 — tripwire task in TODO Now.
- Note: this dev machine already has the Accessibility grant, so bare `swift run scrollbackd` runs live/hangs — automation uses `simulate` only (verify skill enforces this).

## Next up
- Capture perf pass (above). Then: Apple Vision OCR fallback behind the new `CapturedText`/`TextSnapshotProvider` seam; redact-mode stage; chunker + capture-time dedup + volume/vector counters; encrypted store (SQLCipher + SE key) before real dogfood data persists.
