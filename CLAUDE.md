# Scrollback

Local-first, Claude-native ambient memory for macOS. Captures screen text (Accessibility-tree first, OCR fallback) and meeting audio, embeds + indexes everything **100% on-device**, serves it to Claude over MCP, and files append-only updates into Notion. Nothing leaves the Mac at capture time.

Full product context: [PRD.md](PRD.md). Architecture & decisions: [tech-spec.md](tech-spec.md).

## Tech Stack
- **Language:** Swift end-to-end (SwiftUI + AppKit shell; native daemons). No Electron, no Rust core.
- **Embeddings:** EmbeddingGemma-300m Q4_0 on bundled llama.cpp (512d Matryoshka); Qwen3-Embedding-0.6B as quality tier / legal fallback. First-launch model download.
- **STT:** WhisperKit (ANE). FluidAudio for opt-in diarization. **macOS 15+ (Sequoia), Apple Silicon only.**
- **Store:** SQLite + FTS5 + sqlite-vec (int8) behind a `RetrievalStore` protocol; weekly shard files; SQLCipher encryption; DB key wrapped by Secure Enclave, `.biometryCurrentSet`-gated.
- **MCP:** local stdio server, packaged as `.mcpb` (thin Node proxy → daemon socket).
- **Filing:** Notion REST API directly (not the maintenance-mode Notion MCP). Runner = user's Claude subscription (Agent SDK) by default; Anthropic API key is the swappable fallback.
- **Distribution:** Developer ID + notarization + Sparkle 2. Mac App Store is impossible (AX API needs no-sandbox) — do not target it.
- **Open core:** `scrollbackd` + `scrollback-mcp` under FSL-1.1-MIT; app shell + filing agents proprietary.

## Commands
```
swift build                     # build SPM targets (ScrollbackCore lib, scrollbackd)
swift test                      # run the test suite (XCTest)
swift run scrollbackd simulate  # deterministic capture-engine drive (verify gate; no TCC)
swift run scrollbackd ax-dump   # one-shot: dump frontmost-window AX text (needs Accessibility grant)
swift run scrollbackd           # LIVE capture — hangs until Ctrl-C; needs Accessibility grant. Not for automation.
swiftlint                       # optional lint; PostToolUse hook runs it per-file if installed
# xcodebuild -scheme Scrollback # (later, M4) build the menu-bar app shell — not created yet
```

## Architecture (the trust topology — this IS the privacy claim)
- **`scrollbackd`** — capture + redact + chunk + embed + store daemon. **Has no network code path.** Holds the only unwrapped DB key. Serves a local Unix-socket API (mode 0600 + per-client token).
- **`scrollback-courier`** — the ONLY process that touches the network (Anthropic, Notion, Sparkle). Logs every request to `egress_ledger` before sending. Ships a Little Snitch Internet Access Policy naming exactly its endpoints.
- **`Scrollback.app`** — menu-bar UI: onboarding/TCC, timeline, filing approval queue, exclusions, egress-ledger view, pause.
- **`scrollback-mcp`** — thin Node stdio proxy forwarding MCP tool calls to the daemon socket. Key custody never leaves the daemon.
- **Filing pipeline:** `daily_summary` → quarantined extractor (sees ambient text, emits schema-validated JSON only) → privileged composer (never sees raw text) → draft → approval queue → courier commit → write ledger.

## Conventions
- **Provenance is load-bearing:** every captured item is tagged `untrusted_ambient` and carries that tag through embedding, retrieval, MCP results (spotlighted), and the filing gate. Ambient text is data, never instructions.
- **Retrieval goes through the `RetrievalStore` protocol** — never call sqlite-vec directly from feature code (it's pre-v1; the interface is the swap hedge).
- **Writes to Notion are append-only + idempotent** (client-side `external_key` dedup; Notion has no idempotency keys) and reversible via the write ledger.
- **Ledgers (`egress_ledger`, `write_ledger`, `consent_log`) are append-only** — no UPDATE/DELETE in their DAOs.
- Purge = drop the whole weekly shard file (not row DELETEs) — makes "delete everything before X" instant and provable.

## Verification
Never claim a task complete without observed-working proof. Run **`/verify`** (`.claude/skills/verify/SKILL.md`) — `/build` runs it automatically before reporting done. If `/verify` can't run, say so explicitly; never claim success on a clean compile alone. `<5% average CPU` is a launch gate, not an aspiration — measure it when the capture loop exists.

## Files to check first
- `.ai/STATE.md` — where work stands right now (read at session start).
- `docs/decisions.md` — before any architectural call (schema, dependency, API shape, key custody).
- `tech-spec.md` — the settled data model, MCP contracts, and process topology.

## Decision Protocol
Before any architectural decision (schema, dependency, API shape, infra, key custody): present options + the tradeoff that matters here + a recommendation, wait for approval, then log it in `docs/decisions.md`.

## Never
- Never give `scrollbackd` (capture/index daemon) network capability — all egress goes through `scrollback-courier`. This split is the entire privacy claim.
- Never capture the Claude window, password managers, banking, incognito, or secure-input fields (default exclusions + Anthropic directory policy).
- Never store raw video frames by default (text-first); never store speaker voiceprints/biometric embeddings by default; never do emotion/sentiment inference (BIPA + EU AI Act).
- Never let captured/ambient text act as instructions to the filing agent (quarantined extraction, schema-validated fields only).
- Never let a filing agent auto-commit to Notion without the approval queue in v1; never emit agent-generated URLs/images into Notion writes (verified exfiltration channel); approval always precedes commit.
- Never add analytics/telemetry SDKs to any binary (a trust-positioned Mac app dies on this — Bartender/Amplitude).
- Never store the raw DB key — SE-wrapped, `.biometryCurrentSet`, no passcode fallback.
- Never use fixed-interval polling capture (battery); event-driven only. Never depend on Ollama.
- Never cite the "EFF audited Rewind" claim — it is fabricated SEO content.
- Never commit secrets, API keys, `.env`, or a user's captured data / memory DB.
