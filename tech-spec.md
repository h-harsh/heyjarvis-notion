# Technical Spec — Scrollback

*Derived from [PRD.md](PRD.md). Every major choice below is presented as options → the tradeoff that matters for this product → recommendation. All recommendations are marked **ADOPTED** per the founder's delegation ("define everything"); any can be vetoed before /setup. Research basis: 62-agent verified sweep, July 10, 2026.*

**PRD constraints that drive this architecture:** solo developer; macOS-native ambient capture (AX-tree primary); 100% on-device capture/embed/store (provable — split-process, zero-egress capture daemon); Claude via local MCP; filing agents with approval queue writing append-only to Notion; open-core; no backend/no accounts; <5% CPU launch gate; single-digit GB/year storage.

---

## 1. Stack

### D1 — Application language & architecture

| Option | Tradeoff |
|---|---|
| **A. Swift end-to-end** (SwiftUI/AppKit shell + Swift daemons, C libs linked directly) | All the load-bearing APIs (ScreenCaptureKit, AXUIElement, Vision, Core Audio taps, Keychain/Secure Enclave, LocalAuthentication, XPC) are Swift/ObjC-first. One language = solo-dev velocity. llama.cpp/whisper-family/SQLite are C — link natively. |
| B. Rust core + Swift shell (Screenpipe's shape) | Cross-platform optionality and Rust safety, but doubles the language surface, adds FFI plumbing for every OS API, and Windows/Linux is an explicit PRD non-goal. |
| C. Tauri/Electron shell | Disqualified: "no Electron" is in the PRD; an always-on trust product cannot carry a web runtime. |

**ADOPTED: A — Swift end-to-end.** Screenpipe's pre-relicense MIT snapshot (tag `app-v2.5.26`, excluding `ee/`) is legally reusable but it's Rust — we mine it for *design decisions* (event-trigger set, AX/OCR fallback matrix, ONNX pitfalls), not code.

### D2 — Process topology (the trust architecture)

Three processes, privilege-separated — this **is** the privacy claim, so it's a stack decision, not a detail:

```
┌──────────────────────────────────────────────────────────────┐
│ scrollbackd (capture + index daemon)          NO NETWORK CODE │
│  AX/SCK/audio capture → redact → chunk → embed (llama.cpp)   │
│  → SQLCipher store. Holds the only unwrapped DB key session. │
│  LaunchAgent. Serves a local Unix-socket API (read + filing  │
│  drafts) with per-client auth token.                          │
├──────────────────────────────────────────────────────────────┤
│ scrollback-courier (egress worker)          THE ONLY NETWORK  │
│  Anthropic API (filing runs), Notion REST, Sparkle update    │
│  check. Every request logged to egress_ledger BEFORE send.   │
│  Ships InternetAccessPolicy.plist naming exactly 3 hosts.    │
├──────────────────────────────────────────────────────────────┤
│ Scrollback.app (menu-bar UI, SwiftUI)                         │
│  Onboarding/TCC flows, timeline, approval queue, exclusions, │
│  egress ledger view, pause. Talks to daemon via Unix socket. │
└──────────────────────────────────────────────────────────────┘
   + scrollback-mcp (thin Node stdio proxy, packaged as .mcpb)
     → forwards MCP tool calls to scrollbackd's socket.
```

- The capture daemon cannot be sandboxed (Accessibility API is sandbox-incompatible — verified), so its no-egress guarantee is architectural (no networking code linked) and audited via LuLu/Little Snitch; helper processes that *can* be sandboxed (embedding worker if split out) get sandbox-without-network-entitlement for an OS-enforced proof.
- The MCP server is a **thin proxy**: key custody never leaves the daemon; the `.mcpb` bundle stays tiny; Node ships inside Claude Desktop so users install nothing.

**ADOPTED.**

### D3 — Embedding model + runtime

| Option | Quality (verified) | Size/RAM | License |
|---|---|---|---|
| **A. EmbeddingGemma-300m QAT Q4_0** | MTEB Mul. v2 61.15 / Eng 69.67; best all-round <500M | 239–278MB / <200MB RAM | Gemma Terms (commercial OK; flow-down + notice required; Google remote-restriction clause) |
| B. Qwen3-Embedding-0.6B Q8_0 | Mul. 64.33 / Eng 70.70 — best bundleable quality | 639MB; decoder-based, slower | Apache 2.0 |
| C. Granite Embedding R2 311M | Mul. Retrieval 65.2, LongEmbed 71.7 — beats A on retrieval | ~similar; llama.cpp GGUF confirmed | Apache 2.0 |

Runtime options: statically bundled **llama.cpp** (zero deps, Metal, single GGUF, the MacWhisper/Jan shipping pattern) vs MLX (~50% faster on embedding batches, less battle-tested Swift path) vs requiring Ollama (dev-tool pattern — disqualified by PRD).

**ADOPTED: EmbeddingGemma-300m Q4_0 on bundled llama.cpp, Matryoshka-truncated to 512d**, chunks 512–1024 tokens (its 2048 ctx never binds). First-launch model download keeps the DMG <50MB. **Qwen3-0.6B** ships as the user-selectable "higher quality" tier and is the drop-in primary if legal rejects Gemma Terms. **Granite R2 311M** is the benchmarked v2 candidate (in-house M-series benchmark is a week-1 task). Query prefixes/task prompts are abstracted per-model so models stay swappable; every chunk row records `model_id` + `dim` for lazy re-embedding. MLX backend is a post-launch experiment.

### D4 — Speech-to-text + diarization

| Option | Tradeoff |
|---|---|
| **A. WhisperKit (ANE)** | Works on macOS 15+, ~100 languages, word timestamps, proven; one code path everywhere |
| B. Apple SpeechAnalyzer (macOS 26+) | ~2.2× faster, free, but no diarization/custom vocab, macOS 26-only → forces dual STT paths at v1 |
| C. whisper.cpp Metal | Language breadth but worst battery (Rewind's mistake) |

**ADOPTED: A — WhisperKit as the single v1 path; macOS floor = 15 (Sequoia), Apple Silicon only.** Resolves PRD open question #2: the orphaned Rewind base skews Sequoia; one STT path beats two for a solo dev. SpeechAnalyzer gets adopted opportunistically on 26+ once the abstraction exists. Diarization: **FluidAudio** (MIT/Apache, ANE, built for always-on) — opt-in, ephemeral speaker embeddings only (BIPA).

### D5 — Store, retrieval, encryption

- **Store:** SQLite (one file per weekly shard + one catalog DB) with **FTS5** and **sqlite-vec** (int8; binary+rescore at scale) behind a `RetrievalStore` protocol. sqlite-vec is pre-v1/single-maintainer (verified 12.5-month 2025 gap) — the interface is the hedge; swap targets: **usearch** (Apache, Swift bindings, HNSW) or SQLite core's **Vec1** when it ships 1.0 with acceptable licensing. Re-evaluate at ~1M vectors.
- **Ranking:** multi-list RRF (k=60): FTS5 BM25 + vector KNN + recency list, after hard pre-filters (time range, app, entity). Episode-first retrieval, then temporally adjacent chunks (EM-LLM pattern). Time-partitioned shards make temporal filters shrink the ANN space.
- **Dedup:** exact `text_hash` within a window session at capture → MinHash-LSH (~0.85 Jaccard) before embedding (expect 50–70% volume cut) → retrieval-time diversification (cap results/episode).
- **Encryption:** **SQLCipher Community** (free, BSD, attribution in About) — upgrade path: SQLite SEE ($2,000 one-time perpetual) if commercial-grade support is ever needed; SQLite3MultipleCiphers (public domain, ChaCha20) is the free fallback if SQLCipher friction appears. Rejected: sqlite-vector (Elastic License → paid for us), hnswlib (dead), DuckDB VSS (experimental persistence), LanceDB/ObjectBox (second storage system).
- **Key custody (the infostealer answer, verified against AMOS-class malware):** DB key is random 256-bit, wrapped by a **Secure Enclave P-256 key** (`kSecAttrTokenIDSecureEnclave`), access-controlled with **`.biometryCurrentSet`** + `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` — no passcode fallback, so a phished login password + stolen keychain file still cannot unwrap it. Session-scoped unlock with timeout; rate-limited unwrap; MCP query surface throttled (anti-hammering). Macs without Touch ID: SE-wrapped app passphrase, documented as the weaker path. FileVault required (warn hard if off). Honest doc: macOS has no VBS-style compute enclave — we isolate the *key*, not the compute; say so to auditors.

**ADOPTED.**

### D6 — Open-core license

| Option | Tradeoff |
|---|---|
| A. MIT | Maximum trust; but Screenpipe's MIT→commercial retreat shows a funded competitor can fork the core (their words: "open source on its own is not a business model") |
| **B. FSL-1.1 (Functional Source License, converts to MIT after 2 years)** | Full source auditability (the trust requirement) + 2-year commercial-fork protection; each release eventually becomes MIT |
| C. Fully proprietary + audit | Cheapest, but forfeits the verifiability moat vs minimi |

**ADOPTED: B — FSL-1.1-MIT for `scrollbackd` + `scrollback-mcp`**; app shell, filing agents, recipes proprietary. Releases built on public GitHub Actions with **artifact attestations** (`gh attestation verify` in docs); reproducible builds are not feasible on macOS (verified) — attestations are the credible substitute.

---

## 2. Data model

All tables in the catalog DB unless marked (shard). `PRAGMA user_version` drives migrations.

```sql
episodes (shard)      id PK, ts_start, ts_end, bundle_id, app_name, window_title,
                      url, summary TEXT NULL, entity_keys TEXT NULL (json)
events (shard)        id PK, episode_id FK→episodes ON DELETE CASCADE, ts,
                      event_type CHECK(screen_text|audio|clipboard),
                      source CHECK(ax|ocr|asr), confidence REAL,
                      raw_text TEXT, text_hash BLOB, redaction_flags INT,
                      provenance TEXT DEFAULT 'untrusted_ambient'
chunks (shard)        id PK, episode_id FK CASCADE, event_id FK CASCADE,
                      text, token_count, ts_capture, ts_event NULL,
                      source, model_id, dim, minhash BLOB
chunks_fts (shard)    FTS5(text, content=chunks) -- triggers keep in sync
chunks_vec (shard)    vec0(chunk_id, embedding int8[512])
meetings              id PK, ts_start, ts_end, app, title,
                      consent_status CHECK(pending|granted|declined)
audio_segments (shard) id PK, meeting_id FK SET NULL, ts, transcript,
                      speaker_label TEXT NULL  -- label only; no voiceprints
consent_log           id PK, meeting_id FK, ts, method, note  -- append-only
exclusions            id PK, rule_type CHECK(app|url|window|regex|schedule),
                      pattern, mode CHECK(never_capture|redact), created_at
filing_drafts         id PK, recipe, created_at, payload TEXT (schema-validated json),
                      source_event_ids TEXT (json), content_hash BLOB,
                      external_key TEXT UNIQUE,       -- idempotency
                      status CHECK(draft|approved|committed|dismissed|undone),
                      committed_at NULL, external_system, external_id NULL
write_ledger          id PK, draft_id FK→filing_drafts, ts, action CHECK(create|append|archive),
                      target_id, payload_sha, diff TEXT   -- append-only, drives undo
egress_ledger         id PK, ts, process, destination_host, purpose,
                      byte_count, payload_sha, trigger    -- append-only, user-visible
agent_runs            id PK, recipe, ts, runner CHECK(api|subscription|local),
                      model, tokens_in, tokens_out, est_cost_usd, status, error NULL
destinations          id PK, system CHECK(notion), config TEXT,
                      autonomy CHECK(manual|earned_auto), unedited_streak INT DEFAULT 0
schema_meta           key PK, value  -- model registry, shard index, versions
```

**Self-review pass (findings applied):**

1. **Cardinality:** episode 1—N events 1—N chunks; `ON DELETE CASCADE` end-to-end so a time-range or per-app purge is one `DELETE FROM episodes WHERE …`. FTS/vec rows cleaned by trigger. *Caught:* sqlite-vec deletes have a known alpha-era leak → **TTL/purge prefers dropping whole weekly shard files**, which also makes "purge everything before X" instant and provable.
2. **Indexes for the PRD's queries:** `episodes(ts_start)`, `episodes(bundle_id, ts_start)`, `events(text_hash)` (capture-time dedup probe), `chunks(ts_capture)`, `chunks(ts_event)`, `filing_drafts(status, created_at)` (queue), `filing_drafts(external_key)` UNIQUE (idempotent retries return the prior row instead of double-writing Notion — Notion has no idempotency keys, verified), `egress_ledger(ts)`.
3. **Constraints:** ledgers are append-only (no UPDATE/DELETE grants in the DAO; enforced by code review + tests since SQLite lacks grants). `audio_segments.speaker_label` is a per-meeting label ("Speaker 2"), never a biometric embedding — schema makes the BIPA promise structural.
4. **Orphan risk caught:** `meetings` ↔ shard `audio_segments` crosses DB files, so no real FK — daemon runs a startup consistency sweep (orphaned segments → meeting NULL, logged).
5. **Migration strategy:** `user_version` + forward-only migration scripts; embedding model changes never rewrite history (rows carry `model_id`/`dim`; new shards use the new model; queries fan out per-model index and RRF-merge) → re-embedding is lazy and optional.
6. **Provenance column is load-bearing:** it flows into every MCP tool result (spotlighting) and gates the filing pipeline (ambient text is data, never instructions) — the prompt-injection defense is in the schema, not just the prompt.

---

## 3. API surface & contracts

### 3a. MCP tools (the public contract — Claude Desktop, Claude Code, Cowork-via-Desktop)

Stdio transport; spec target 2025-11-25 (stateless 2026-07-28 changes tracked; stdio OAuth explicitly not required — verified). All tools `readOnlyHint: true` except none in v1 (filing is initiated by Scrollback's scheduler, not by Claude — removes the write tool from the injection blast radius entirely).

```
search_memory(query, time_range?, app?, entities?, limit=8)
  → [{text, app, window_title, url?, ts, episode_id, source: ax|ocr|asr,
      provenance: "untrusted_ambient"}]   -- spotlighted/datamarked spans
recent_activity(window: "1h"|"today"|ISO-range)
  → chronological digest [{episode summary, apps, ts_start, ts_end}]
daily_summary(date) → {episodes[], meetings[], commitments[], reading[]}
search_audio(query, time_range?) → transcript snippets w/ meeting refs
timeline(start, end, granularity) → raw episode/event stream
```

Errors: structured MCP errors — `LOCKED` (biometric session expired; UI prompts), `RATE_LIMITED` (anti-hammering), `EMPTY_RANGE`. Never partial silent results.

### 3b. Daemon Unix-socket API (internal; token-authenticated per client)

`GET /search|/timeline|/summary` (mirrors MCP), `GET /drafts`, `POST /drafts/{id}/approve|dismiss`, `POST /pause`, `GET /egress`, `POST /purge {range|app}` (UI-only scope), `GET /health` (capture-flowing self-test — Tahoe TCC regressions verified real).

### 3c. Notion write path (courier only)

Notion REST API 2025-09-03+ directly (**official local Notion MCP server is maintenance-mode — rejected**): `POST /v1/pages` (data_source parent) to create; `PATCH /v1/blocks/{id}/children` to append; archive to undo. Rules: only Scrollback-created databases/pages are writable; `external_key` dedup before every write; no URLs/images in generated content (verified exfil channel); 429/5xx → exponential backoff, retry consults ledger first.

### 3d. Filing pipeline (internal contract)

`daily_summary` → **quarantined extractor** (runs on the default subscription runner, fast tier to conserve plan limits; sees ambient text; may emit ONLY schema-validated JSON: `{commitments[], log_entries[], reading[]}` — rejected on any schema violation) → **privileged composer** (never sees raw captured text; builds Notion blocks from validated fields) → draft row → approval queue → courier commit → ledger. Approval precedes commit unconditionally (the Notion-AI breach committed-before-approval — verified; we invert it).

---

## 4. Auth model

- **No user accounts, no server, no sessions.** Identity = possession of the Mac + biometric.
- **DB unlock:** Secure-Enclave-wrapped key, `.biometryCurrentSet`, session timeout (default 12h, configurable), rate-limited (D5).
- **Secrets:** Notion integration token in Keychain, ACL'd to the courier binary only (user-created internal integration token in v1 — no OAuth server to run; hosted-OAuth Notion MCP is a later option). Default subscription runner needs **no stored LLM credential** (it uses the user's already-authenticated Claude CLI/Desktop session); an Anthropic API key is stored in Keychain only if the user enables the fallback runner.
- **Process boundary:** Unix socket mode 0600 + per-client token minted by the daemon on app/mcp first-run (Keychain-stored); prevents other local processes from querying memory even pre-unlock.
- **License keys (Pro):** offline-verifiable Ed25519 signed keys (Hyprnote pattern — verified resonant with this audience); no phone-home requirement, periodic soft validation via Paddle/LS API from courier (logged in egress ledger like everything else).
- **TCC grants:** Screen & System Audio Recording, Accessibility, Microphone — onboarding explains each before prompting; health check detects Tahoe's vanishing-grant bug and deep-links recovery.

---

## 5. Third-party services & dependencies (bought vs built, with exit costs)

| Dependency | Role | Cost | Exit cost |
|---|---|---|---|
| User's Claude subscription (default) / Anthropic API (fallback) | Filing-agent LLM | $0 marginal on subscription; ≈$1.6–7/mo if user opts into API key (below) | Low — runner abstraction; any MCP-era LLM or local model slots in |
| Anthropic Claude Desktop/Code | Recall surface | user's existing plan | Medium — MCP is client-agnostic by design (hedge vs sherlocking) |
| Notion REST API | Filing target | free | Low — `destinations` abstraction; Linear/Slack next |
| llama.cpp + EmbeddingGemma GGUF | Embeddings | free (Gemma Terms flow-down) | Low — model registry + lazy re-embed designed in |
| WhisperKit + FluidAudio | STT + diarization | free (MIT/Apache) | Low — STT behind one interface |
| sqlite-vec / FTS5 / SQLCipher | Store | free (attribution) | Medium — `RetrievalStore` protocol; usearch/Vec1 hedges named |
| Sparkle 2 | Updates | free | Low |
| GitHub (repo, Actions, attestations, Releases) | Build/provenance/distribution | free (public repo) | Low |
| Paddle or LemonSqueezy | Payments/tax (MoR) | ~5% + fees, revenue-only | Low |
| Cure53-class audit (post-revenue) | Trust capstone | ~low-five-figures, deferred | n/a |

Explicitly **not** used: Ollama (dependency), Deepgram/any cloud STT, any analytics/telemetry SDK (Bartender lesson — verified), Screenpipe current builds (commercial license prohibits embedding — verified; MIT snapshot mined for design only).

---

## 6. Hosting / deploy target

**The product hosts nothing.** Everything user-facing runs on the user's Mac.

- **Distribution:** notarized DMG via GitHub Releases (+ `brew install --cask scrollback` later); Developer ID + hardened runtime; Sparkle appcast + `.mcpb` served from the website. Mac App Store: impossible (AX + sandbox — verified), not pursued.
- **Website/trust page/appcast:** static on Cloudflare Pages — $0.
- **CI:** public GitHub Actions (free) for the open core; small paid tier possible for private shell repo builds.
- **Founder's fixed costs:** Apple Developer $99/yr + domain ~$10–40/yr + (optional later) SEE $2,000 one-time + audit. That is the entire company infrastructure bill: **≈$140/yr until revenue.**

### Running-cost model & free alternatives (founder question, answered)

**Per-user recurring cost = the filing agent's LLM calls, and the committed default makes that $0.** Everything else is $0 forever (capture, embedding, STT, storage, recall retrieval are all local; recall's Claude calls ride the user's existing Claude plan).

| Filing runner | Cost | Quality impact |
|---|---|---|
| **User's Claude subscription — DEFAULT** (Agent SDK / `claude -p` / Claude Desktop scheduled task) | **$0 marginal** | Same models → same quality. Caveats surfaced in-app: draws on plan usage limits; Desktop-task variant needs the app open + machine awake; Anthropic paused-but-signaled splitting SDK billing from subscriptions — if that lands, the fallback is one setting away |
| Anthropic API, Haiku 4.5 (fallback) | ~50K tok/day digest ≈ **$1.6/mo**; heavy 200K tok/day ≈ $7/mo; halve with Batches, cut more with prompt caching | Baseline quality; fully reliable scheduling independent of plan limits — the mode for heavy users or a billing-policy shift |
| Sonnet-tier option | ~$15–25/mo | Marginally better extraction; not worth it for schema-validated filing — off by default |
| Local-LLM mode (bundled llama.cpp, Qwen-class 4–8B) | **$0, fully offline** | Real quality drop on extraction/summarization; schema validation catches format errors but not missed commitments — ship as "Local-only mode" with an honest accuracy disclaimer; also the ultimate no-cloud story |

All runners ship behind one `FilingRunner` interface. **Default = the user's Claude subscription** (founder decision, 2026-07-11): zero marginal cost, same model quality. The API-key fallback carries a live cost display (`agent_runs.est_cost_usd`) and exists precisely because subscription-SDK billing is the one dependency Anthropic has signaled it may change — so the switch must be frictionless, not a rebuild.

---

## 7. Scale checklist

**What breaks at 10× (and what's consciously deferred):**

| Pressure | Breaks | Plan |
|---|---|---|
| Vectors > ~1M (3+ yrs use or heavy users) | sqlite-vec brute-force latency | Time-partitioned shards already bound the scan; then int8→binary+rescore; then usearch/Vec1 swap behind `RetrievalStore`. **Deferred on purpose** — measured trigger, not speculation |
| sqlite-vec abandonment | Store roadmap | Interface + named swap targets; quarterly maintenance check |
| minimi ships local embeddings / Screenpipe ships embeddings | Differentiation | Moat migrates to filing agents + trust brand + audit — already the PRD's hero |
| Anthropic policy shift (SDK billing, directory, MCP spec 2026-07-28 statelessness) | Zero-key mode; distribution | Runner abstraction; direct `.mcpb` distribution independent of directory; stdio insulated but `server/discover` migration tracked |
| 10× support load (solo) | Founder time | No-accounts/no-server design keeps surface small; diagnostics bundle generator (local, user-reviewed before sending) |
| Teams demand (Phase 3) | Single-user architecture | MDM detection + disabled-by-default on managed machines already in v1; policy layer is additive, not a rewrite |
| EU/India launch | Consent defaults | Region-aware defaults staged post-launch; architecture (no vendor data access) already GDPR-favorable |
| **Deferred with eyes open** | Windows/Linux, cloud sync, iOS companion, team sharing, SpeechAnalyzer path, MLX backend, proactive/ADHD surfacing | Each has a named trigger in the PRD roadmap |

---

## Decisions log (for /setup to seed docs/decisions.md)

## 2026-07-10 — Swift end-to-end, three-process trust topology
**What:** Native Swift app; capture/index daemon with zero network code; separate courier for all egress; thin Node MCP proxy (.mcpb).
**Why:** OS APIs are Swift-first; the split *is* the provable-privacy claim; solo-dev velocity.
**Rejected:** Rust core (FFI tax, cross-platform is a non-goal), Electron/Tauri (trust + PRD), monolith (unverifiable egress claim).

## 2026-07-10 — EmbeddingGemma-300m Q4_0 on bundled llama.cpp, 512d Matryoshka
**What:** Primary on-device embedder; Qwen3-Embedding-0.6B as quality tier/legal fallback; Granite R2 311M tracked for v2; first-launch model download.
**Why:** Purpose-built for always-on/battery workloads, <200MB RAM, broadest runtime support; llama.cpp static bundle is the verified consumer shipping pattern.
**Rejected:** Ollama dependency (consumer-hostile), jina-v5 (CC BY-NC), LFM2.5 ($10M revenue poison pill), NLContextualEmbedding as primary (unbenchmarked).

## 2026-07-10 — WhisperKit STT, macOS 15+ floor, FluidAudio opt-in diarization
**What:** Single STT path at v1; Apple Silicon only; SpeechAnalyzer adopted later on 26+; ephemeral speaker labels, never voiceprints.
**Why:** One code path for a solo dev; Sequoia-heavy target base; BIPA litigation wave is live.
**Rejected:** SpeechAnalyzer-only (26-only floor cuts the orphaned base), whisper.cpp primary (battery).

## 2026-07-10 — SQLite + FTS5 + sqlite-vec (int8) behind RetrievalStore; RRF hybrid; weekly shards; SQLCipher + Secure-Enclave key custody
**What:** One encrypted embedded store; multi-list RRF (BM25+vector+recency); episode segmentation; MinHash dedup; SE-wrapped DB key gated by `.biometryCurrentSet`; purge = drop shard.
**Why:** Only stack keeping text/FTS/vectors/metadata in one transactional encrypted file at our scale; key custody defeats the verified AMOS infostealer playbook; shards make TTL/purge provable.
**Rejected:** sqlite-vector (Elastic license), hnswlib (dead), DuckDB VSS (corruption risk), LanceDB/ObjectBox (second store), `.userPresence` key flag (falls back to phishable password).

## 2026-07-10 — Filing agents: quarantined extraction → schema-validated fields → approve-before-commit → append-only idempotent Notion writes; read-only MCP surface
**What:** CaMeL-style split (extractor sees ambient text, emits schema JSON only; composer never sees raw text); draft queue with earned autonomy; client-side external_key idempotency; write ledger + archive-undo; no agent-emitted URLs; Claude gets read-only tools.
**Why:** The lethal trifecta is real and the Notion-AI exfil attack is the exact precedent; every shipping analog defaults human-in-the-loop; Notion API lacks idempotency keys.
**Rejected:** silent auto-commit (trust suicide), prompt-level guardrails as security (verified insufficient), Claude-invoked write tools in v1 (blast radius).

## 2026-07-11 — Filing runner defaults to the user's Claude subscription
**What:** Default `FilingRunner` = user's existing Claude subscription (Agent SDK / `claude -p` / Claude Desktop scheduled task), $0 marginal cost, no stored LLM credential. Anthropic API-key mode (Haiku-tier, ≈$1.6–7/mo, live cost display) is the built-in swappable fallback; local-LLM mode is the offline option.
**Why:** Founder decision — zero added user cost with identical model quality; API-key fallback is one setting away if plan limits bite or Anthropic changes subscription-SDK billing (paused-but-signaled).
**Rejected:** API key as default (adds cost for the common case), local-LLM as default (accuracy drop on extraction).

## 2026-07-10 — Open core under FSL-1.1-MIT + GitHub artifact attestations; Free + Pro $15/mo; Paddle/LS payments; no accounts, no backend, no telemetry
**What:** Daemon+MCP source-available converting to MIT after 2 years; shell/agents proprietary; offline-verifiable license keys; egress ledger as first-class UI.
**Why:** Auditability is the conversion lever for a capture daemon; MIT invited the fork that burned Screenpipe; no-backend = nothing to breach and ~$140/yr fixed costs.
**Rejected:** MIT core, fully-proprietary + audit-only, subscription-with-account infrastructure.

---

*Next step: run `/setup` — it reads PRD.md and this spec, scaffolds the project, and seeds `docs/decisions.md`, `TODO.md`, and `.ai/STATE.md`.*
