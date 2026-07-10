# Decisions — Scrollback

Append-only. Architectural decisions and non-obvious gotchas. Format: date — title / What / Why / Rejected (or: If you change it). Seeded from tech-spec.md at scaffold time.

## 2026-07-11 — Product name: Scrollback
**What:** The product is named Scrollback ("scroll back through your day"; the terminal scrollback buffer is the text history of the screen).
**Why:** Distinctive, English, memorable for the dev audience. `getscrollback.com` was unregistered on 2026-07-10; the only prior use is a defunct 2014 community-chat startup in an unrelated category. Doc.md's earlier candidates were dead: "Engram" is a $98M-funded AI-memory startup; "Mnemo" has ~6 claimants.
**If you change it:** rename before the trademark screen and before acquiring scrollback.app/.ai (both parked). Trademark clearance (US/EU/IN classes 9/42) is still an open pre-launch TODO.

## 2026-07-10 — Swift end-to-end, three-process trust topology
**What:** Native Swift app; capture/index daemon (`scrollbackd`) with zero network code; separate `scrollback-courier` for all egress; thin Node MCP proxy (`.mcpb`).
**Why:** OS APIs are Swift-first; the process split *is* the provable-privacy claim (the process that sees your screen has no network code path — verifiable with LuLu/Little Snitch); solo-dev velocity.
**Rejected:** Rust core (FFI tax; cross-platform is a non-goal), Electron/Tauri (a web runtime in an always-on trust product is disqualifying), monolith (unverifiable egress claim).

## 2026-07-10 — EmbeddingGemma-300m Q4_0 on bundled llama.cpp, 512d Matryoshka
**What:** Primary on-device embedder; Qwen3-Embedding-0.6B as quality tier / legal fallback; Granite R2 311M tracked for v2; model downloads on first launch.
**Why:** Purpose-built for always-on/battery workloads, <200MB RAM, broadest runtime support; a statically bundled llama.cpp is the verified consumer shipping pattern (MacWhisper/Jan) and keeps the DMG <50MB.
**Rejected:** Ollama dependency (consumer-hostile; it's a dev-tool pattern), jina-v5 (CC BY-NC — cannot bundle), LFM2.5 ($10M-revenue license poison pill), NLContextualEmbedding as primary (unbenchmarked quality).
**Gotcha:** EmbeddingGemma is under Gemma Terms, NOT Apache — requires a notice file + Prohibited-Use flow-down in ToS, and Google retains a remote-restriction clause. If legal rejects it, Qwen3-0.6B (Apache 2.0) is the drop-in primary. Every chunk row stores `model_id`+`dim` so re-embedding is lazy.

## 2026-07-10 — WhisperKit STT, macOS 15+ floor, FluidAudio opt-in diarization
**What:** Single STT path at v1 (WhisperKit/ANE); Apple Silicon only; Apple SpeechAnalyzer adopted opportunistically on macOS 26+ later; ephemeral speaker labels, never voiceprints.
**Why:** One code path for a solo dev; the orphaned Rewind base skews to Sequoia; BIPA litigation over voiceprints is live.
**Rejected:** SpeechAnalyzer-only (a macOS-26 floor cuts the orphaned base), whisper.cpp primary (worst battery — Rewind's mistake).

## 2026-07-10 — SQLite + FTS5 + sqlite-vec behind RetrievalStore; RRF hybrid; weekly shards; SQLCipher + Secure-Enclave key
**What:** One encrypted embedded store; multi-list RRF (BM25 + vector + recency); episode segmentation; MinHash dedup; DB key wrapped by a Secure-Enclave P-256 key, gated by `.biometryCurrentSet`; purge = drop the weekly shard file.
**Why:** Only stack keeping text/FTS/vectors/metadata in one transactional encrypted file at our scale; SE key custody defeats the verified AMOS-class infostealer playbook (stolen keychain + phished password still can't unwrap it); shards make TTL/purge instant and provable.
**Rejected:** sqlite-vector (Elastic License → paid for us), hnswlib (unmaintained since 2023), DuckDB VSS (experimental persistence, corruption risk), LanceDB/ObjectBox (adds a second storage system), `.userPresence` key flag (falls back to the phishable login password).
**Gotcha:** sqlite-vec is pre-v1, single-maintainer (had a ~12.5-month 2025 gap). It sits behind a `RetrievalStore` protocol so the store is swappable — hedges are usearch (Apache, Swift bindings) and SQLite core's Vec1 once it ships 1.0 with acceptable licensing. Re-evaluate at ~1M vectors. macOS has NO VBS-style compute enclave — we isolate the key, not the compute; state that to auditors.

## 2026-07-10 — Filing agents: quarantined extraction → schema-validated fields → approve-before-commit → append-only idempotent Notion writes; read-only MCP surface
**What:** CaMeL-style split (extractor sees ambient text and emits schema JSON only; composer never sees raw text); draft-then-approve queue with earned autonomy; client-side `external_key` idempotency; write ledger + archive-undo; no agent-emitted URLs/images; Claude gets read-only MCP tools (filing is scheduler-initiated, not Claude-invoked, in v1).
**Why:** Scrollback holds the full "lethal trifecta" (private memory + untrusted captured content + a Notion-writing agent); the PromptArmor Notion-AI exfiltration attack is the exact precedent; every shipping analog (Highlight, Granola, LUCI) defaults human-in-the-loop; 68% of consumers won't trust unreviewed agent actions.
**Rejected:** silent auto-commit (trust suicide), prompt-level guardrails as security (verified insufficient — classifiers are probabilistic), Claude-invoked write tools in v1 (unnecessary blast radius).
**Gotcha:** the Notion API has no idempotency keys, so retried writes can duplicate — dedup is client-side (`external_key` + query-before-write + local ledger). Notion version history is plan-limited (7 days Free), so undo relies on our own write ledger (archive the page/block we created), which only works for append-only writes into Scrollback-owned surfaces.

## 2026-07-10 — Open core under FSL-1.1-MIT + GitHub artifact attestations; Free + Pro $15/mo; Paddle/LS payments; no accounts, no backend, no telemetry
**What:** `scrollbackd` + `scrollback-mcp` source-available under FSL-1.1 (converts to MIT after 2 years); app shell + filing agents + recipes proprietary. Offline-verifiable Ed25519 license keys; egress ledger as a first-class UI surface.
**Why:** Auditability is the conversion lever for an always-on capture daemon (Hyprnote/Bitwarden pattern); plain MIT invited the fork that Screenpipe blamed for its model ("open source on its own is not a business model"); no backend = nothing to breach (contrast Cluely's 83K-user leak) and ~$140/yr fixed costs.
**Rejected:** MIT core (fork-exposed), fully-proprietary + audit-only (forfeits the verifiability moat vs minimi), subscription-with-account infrastructure (adds a breachable backend).

## 2026-07-11 — Filing runner defaults to the user's Claude subscription
**What:** Default `FilingRunner` = user's existing Claude subscription (Agent SDK / `claude -p` / Claude Desktop scheduled task), $0 marginal cost, no stored LLM credential. Anthropic API-key mode (Haiku-tier, ≈$1.6–7/mo, with a live cost display) is the built-in swappable fallback; local-LLM mode is the offline option.
**Why:** Founder decision — zero added user cost with identical model quality; the API-key fallback is one setting away if plan limits bite or if Anthropic lands its paused-but-signaled split of SDK billing from subscriptions.
**Rejected:** API key as default (adds recurring cost for the common case), local-LLM as default (real accuracy drop on extraction/summarization).
**Gotcha:** the Desktop-scheduled-task variant needs the app open + machine awake; prefer the Agent SDK / headless CLI route as the primary within this default (more controllable, no foreground dependency).
