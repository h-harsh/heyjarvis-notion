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
Observe: final line `Executed N tests, with 0 failures` (N ≥ 141 today) and exit 0.
This is where the load-bearing invariants are asserted with exact values:
- `RankFusion` fuses to exact RRF scores and a deterministic tie-break order.
- `CaptureEvent.provenance` defaults to `.untrustedAmbient` (the security invariant).
- `AXCapturePolicy.isSecureField` treats subrole `AXSecureTextField` as secure — the never-read-passwords guard (a broken guard fails here, not in production).
- `CaptureEngine`: episodes open/close on context change and idle, resume-after-idle reopen, app-driven content changes do NOT defeat idle, typing debounce (rolling + cleared-on-window-switch), per-episode hash dedup, clipboard verbatim capture, idle suppression (`idleProviderCalls == 0`), tsEnd never regresses, activity-gated fallback (never fixed-interval).
- **Key-custody policy:** `KeyCustodyPolicy` (pure, clock-injected) returns LOCKED before unlock and after `sessionTimeout` (12h), rate-limits unwrap attempts (sliding window trips the limit; a successful unlock resets it). The SE-hardware unwrap + SQLCipher key application are live-only (signed build), NOT covered here.
- **Catalog store:** `SQLiteCatalogStore` migrates the full schema (idempotent on reopen, `user_version`-gated), round-trips episodes/events/chunks, cascades deletes (episode → events → chunks → FTS via triggers), and FTS-searches chunk text. Parameterized queries throughout. Encryption-transparent (SQLCipher swap is one isolated spot).
- **Chunker:** `Chunker` splits event text into target-range chunks (sentence-packed, oversized sentences hard-split by word, no content lost) carrying event FKs + source; `ChunkingStage` dedups identical re-read text by normalized hash (stored once), collapses near-dups (below), and tracks volume counters (raw vs stored chars, chunks = vector count, per-hour buckets).
- **Near-dup collapse:** `MinHasher` signatures are deterministic across instances (fixed seed) and estimate Jaccard (identical→1.0, disjoint→~0); `NearDupCollapser` collapses a scrolled/edited re-read (≥0.85 estimated Jaccard) into its first-seen representative but retains genuinely distinct docs and below-threshold edits (the two-stage gate — LSH candidate then exact 0.85 verify — so distinct memory is never silently dropped); in `ChunkingStage` a near-dup increments `nearDupSkips` and isn't stored, while `nearDup: nil` reverts to exact-hash-only; a repetitive stream shows a 50–70% volume cut.
- **Dual timestamps:** `EventTimeExtractor` fills `ts_event` (the event a chunk refers to) resolved relative to the CAPTURE time — a weekday said Monday resolves to that week's day, `tomorrow`/`yesterday`/ISO/month-name dates resolve correctly, impossible dates (`2026-13-45`, `Feb 30`) and bare numbers/versions/ports resolve nil (precision over recall), the earliest reference in reading order wins, and results are deterministic (injected timezone); `Chunker` carries both `ts_capture` and `ts_event`, `eventTime: nil` disables it.
- **Exclusions:** `ExclusionSet` resolves a context to `neverCapture`/`redact`/`capture` (strictest wins); defaults exclude password managers, the Claude Desktop app, and incognito window titles, but NOT ordinary apps (`com.apple.Safari`/Slack stay capturable — guards the golden line); in `CaptureEngine`, a `neverCapture` app opens **no episode and stores nothing** across app-switch/clipboard/resume/fallback paths, and a `redact` app records the episode but stores a placeholder (provider never read).
- **Redact stage:** `Redactor` masks high-risk secrets (PEM keys, `sk-`/`gh_`/`AKIA`/`AIza`/`xox-`/JWT tokens, Luhn-valid cards) with `[redacted:<name>]` and sets `redaction_flags`, while surrounding text and PII (emails/phones/names) survive; Luhn gates card masking (valid masked, invalid kept) incl. length boundaries (13/19) and adjacency (`card + stray digit` still masked); redaction runs at the `CaptureEngine.emit` chokepoint (one pass drives rawText+hash+flags; clipboard stored normalized) so a captured/copied secret never reaches the sink unmasked, incl. tab/NBSP-separated cards; and the private-key rule is ReDoS-guarded (a `-----BEGIN`-flood with no `-----END` completes in <1s, not O(n²)).
- **OCR fallback matrix:** `AppCaptureCapabilities` strategy resolution; `OCRFallbackPolicy` fires OCR only on empty/thin AX (threshold boundary); `LayeredTextSnapshotProvider` — `ocrOnly` skips the AX walk, `axOnly` never screenshots, `axThenOCR` rescues a title-only window but never regresses below AX (prefer-longer, ties keep AX), and **refuses OCR when AX saw a secure field** (`containedSecureField` — the never-screenshot-a-password-window guard); OCR output labelled `.ocr`; `OCRTextAssembler` reading-order is a strict weak ordering — deterministic/permutation-independent on chained-within-epsilon staircases (the intransitive-comparator regression).
Adding capture/store/filing code MUST add tests here — a green build alone never counts.

### 3. Lint (only if installed)
Run: `command -v swiftlint >/dev/null 2>&1 && swiftlint --quiet || echo "swiftlint absent — skipped"`
Observe: no violations if present; "skipped" if absent. Absence is NOT a failure.

## Dynamic drive

### 4. Capture engine drives correctly (fixture simulate — the real engine, no TCC needed)
Run: `swift run scrollbackd simulate`
Observe: exit 0 and the exact line
`simulate OK: episodes_opened=3 episodes_closed=3 screen_events=4 clipboard_events=1 dedup_skips=1 provider_calls=5 idle_provider_calls=0`
The binary replays a fixed workday fixture through the real `CaptureEngine` and self-asserts (any mismatch prints expected/actual and exits 1). `idle_provider_calls=0` is the "idle runs zero capture cycles" launch invariant, observed. This is the ONLY automated gate for capture — it always terminates.

**Do NOT run bare `swift run scrollbackd` (no args) in automation.** On a machine where Accessibility is already granted it enters the capture run loop and never exits (it hangs the verify); on an ungranted machine it prints guidance and exits 3. Neither is a usable automated assertion — use `simulate`.

**Manual (TCC-gated, founder's machine only, run by hand and reported explicitly):** `swift run scrollbackd ax-dump` → prints the frontmost window's extracted text (secure fields excluded — regression-guarded by the `AXCapturePolicyTests` unit test in gate #2); `swift run scrollbackd ocr-dump` → screenshots + Vision-OCRs the frontmost window and prints the text (needs the **Screen Recording** grant; the image is discarded post-extraction — zero frames stored); `swift run scrollbackd` → live JSONL capture in `~/Library/Application Support/Scrollback/spike/` (Ctrl-C flushes the final episode). State explicitly if these weren't run — never imply live capture/OCR was observed when only `simulate` ran. The ScreenCaptureKit+Vision path and the async→sync bridge's runtime behaviour are only observable here, not in CI.

### 5. Capture/index code links NO networking (Never rule #1)
Run: `grep -rnE 'URLSession|NWConnection|NWListener|NWBrowser|CFSocket|CFStream|getaddrinfo|SocketPort' Sources/scrollbackd Sources/ScrollbackCore`
Observe: **zero matches** (grep exits 1). Any hit = the privacy split is broken; all egress must live in `scrollback-courier` (a separate target), never in the capture/index code. Fail the verify.

## Critical flows — add each check when the flow lands (not applicable yet)

These are the product's crown jewels (PRD gates). They can't be observed until the code exists; when a `/build` adds the flow, replace the stub here with a real run→observe check:

- **Capture spike:** feed a fixture AX tree / drive a known window → observe `CaptureEvent`s land in the store; measure `<5% average CPU` over a real hour (the launch gate). <!-- TODO: add when capture loop exists -->
- **Recall via MCP:** call `search_memory` with a seeded corpus → observe the correct episode in top-3, snippets carry provenance + are spotlighted. <!-- TODO: add at M2 -->
- **Filing agent:** run a daily digest over fixtures → observe a draft appears in the queue, re-running does NOT duplicate (idempotent `external_key`), and undo archives the created page. <!-- TODO: add at M3 -->
- **Permission-gated bits** (Screen/AX/Mic TCC) can't be headless-verified — these stay manual-observation steps, stated as such, never silently skipped.
