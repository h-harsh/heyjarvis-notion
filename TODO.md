# TODO — Scrollback

Milestones sequenced by deliverable (not calendar); each gates the next. Fully decomposed after the 2026-07-11 plan audit (4-auditor coverage review — see docs/decisions.md entry). Ordering inside a section is dependency order.

## Now (time-critical ops + M1 — screen-memory lane: "it remembers")

**Ops — dated/squattable, do not defer:**
- [ ] **[USER]** Register `getscrollback.com` (~$10, was unregistered 2026-07-10 — squattable any day); open acquisition inquiries for parked scrollback.app/.ai. DoD: domain registered and parked on Cloudflare.
- [ ] **[USER]** Enroll in Apple Developer Program ($99/yr) + obtain Developer ID Application cert (lead time; gates M4's notarized DMG). DoD: a test binary signs + notarizes + passes Gatekeeper.
- [ ] **Dated (week of Jul 15):** Otter.AI MTD ruling tripwire — read the outcome, log consent-UX + marketing-claim implications in docs/decisions.md. DoD: entry exists stating impact or explicitly none.

**M1 engineering (dependency order):**
- [x] Redact-mode pipeline stage (capture → **redact** → chunk): regex/url/window redact rules + secure-input masking set `events.redaction_flags` before chunking. DoD: a fixture redact rule provably masks matching text in chunks/FTS while surrounding text persists. — Done: pure `Redactor` (high-precision secret rules + Luhn; PII deliberately preserved) at the `CaptureEngine.emit` chokepoint sets `CaptureEvent.redactionFlags`; masks the span, keeps surroundings; dedup hash over redacted text. Rules extensible (`.custom`). App/url/window *rule sourcing* comes with the exclusion manager (M1/UI); the redact ENGINE is here. Hardened by a 4-lens review (ReDoS guard, single-pass emit, clipboard normalization, card over-match fix). 23 tests.
- [x] Chunker + capture-time dedup + volume instrumentation: events → 512–1024-token chunks (FKs, token_count); exact `text_hash` dedup at capture; raw-vs-deduped chars/hour counters + total-vector counter (feeds the sqlite-vec ~1M re-eval trigger). DoD: fixture session yields in-range chunk rows; identical re-read text stored once; an hour of real use logs volume numbers. — Done: pure `Chunker` (sentence-pack + word hard-split, pluggable token estimate until the real tokenizer lands) + `ChunkingStage` (normalized-hash dedup + total/per-hour volume counters, chunksStored = vector count). Wired into the live daemon via `InstrumentedSink` (logs volume on shutdown; chunks not persisted until the store lands). 9 tests.
- [ ] Episode segmentation at capture: app/window/idle boundaries. DoD: a fixture day yields expected episode boundaries.
- [x] Encrypted store (a): SQLCipher DB + full schema + `user_version` forward-only migrations + `schema_meta` model/shard registry. DoD: schema creates; a migration round-trips. **(Before any real dogfood data persists.)** — Done: `SQLiteDatabase` (thin sqlite3-C wrapper, SQLCipher swap isolated to one `PRAGMA key` spot) + `CatalogSchema` (full tech-spec §2 schema as migration v1, minus `chunks_vec` which needs sqlite-vec → embedding task) + `SQLiteCatalogStore` (migrate + episode/event/chunk DAOs, FK cascade, FTS5 search). Built on system SQLite now; SQLCipher key + live-daemon wiring land with (b) so real data is encrypted from the first write. 7 tests.
- [~] Encrypted store (b): SE key custody — Secure-Enclave-wrapped key, `.biometryCurrentSet`, session timeout (12h default), rate-limited unwrap + throttled queries (anti-hammering), SE-wrapped passphrase path for non-Touch-ID Macs, hard FileVault-off warning. DoD: expired session returns LOCKED; hammering trips the limit; stolen key file alone cannot unwrap. — **Policy layer done + tested** (`KeyCustodyPolicy`: LOCKED-on-expiry + rate-limit — 2 of 3 DoD points, 8 tests). **REMAINING = environment-blocked** (needs a code-signed founder machine + network): SE key wrapping (`SecKeyCreateRandomKey` SE + biometry ACL + Keychain), interactive Touch ID unlock, FileVault check, **and the SQLCipher link + wiring the store as the live sink** (vendoring the amalgamation — the "encrypt before dogfood" step). Can't be built/verified from the headless shell.
- [ ] Encrypted store (c): weekly shards + catalog + purge-by-shard-drop. DoD: "purge before X" provably removes shard files.
- [ ] Embedding (a): statically bundle llama.cpp + EmbeddingGemma Q4_0 behind `RetrievalStore`; per-model query-prefix abstraction; `model_id`+`dim` recorded per chunk. DoD: known text → correct-dim 512d vector.
- [ ] Embedding (b) + **courier bootstrap**: first-launch GGUF download via a minimal `scrollback-courier` SPM target (NOT the daemon — verify check #5 must stay green) with `egress_ledger` table + ledger-row-BEFORE-send discipline + model host named in InternetAccessPolicy.plist. DoD: fresh install fetches the model; ledger row precedes the request; daemon still greps clean.
- [ ] Week-1 M-series embedding benchmark: EmbeddingGemma Q4_0 vs Qwen3-0.6B vs Granite R2 (quality on a sample set, tok/s, RAM, battery). DoD: results appended to docs/decisions.md; default confirmed or revised.
- [x] MinHash-LSH near-dup collapse pre-embedding (~0.85 Jaccard). DoD: repetitive fixture shows 50–70% volume cut. — Done: pure `MinHasher` (128 affine perms over FNV-1a-32 word-trigram shingles, fixed-seed deterministic) + streaming `NearDupCollapser` (LSH banding → exact signature-Jaccard ≥0.85 verify, first-seen-wins), wired into `ChunkingStage` after the exact-hash miss (`nearDupSkips`, default on). Mixed repetitive stream collapses 60%. 15 tests; overflow/determinism self-reviewed. AX-over-OCR collapse preference TODO'd (needs rep source threaded). decisions.md logged.
- [ ] Hybrid retrieval: RRF (FTS5 + vector + recency) with hard pre-filters (time/app/entity) + retrieval-time diversification (cap results/episode). DoD: "what did I do today?" returns correct episodes top-3; a one-episode-dominant query returns diversified episodes.
- [ ] Dual timestamps: extract `ts_event` distinct from `ts_capture` during chunking. DoD: "meeting moved to Friday" captured Monday is retrievable by both dates.
- [ ] LaunchAgent packaging for scrollbackd: install/uninstall, KeepAlive, log location. DoD: auto-starts at login, restarts after kill -9, captures a full day unattended.
- [x] Apple Vision OCR fallback + per-app capability matrix. DoD: an Electron/canvas app with empty AX still produces text; OCR input images discarded post-extraction. — Done: `LayeredTextSnapshotProvider` + `AppCaptureCapabilities`/`OCRFallbackPolicy` (pure, unit-tested, 20 tests) route AX→OCR; live `VisionOCRExtractor` (ScreenCaptureKit+Vision) discards the CGImage post-recognition; hardened by a 5-lens adversarial review (12 findings fixed: strict-weak-ordering assembler, timeout-race bridge, secure-field OCR suppression, Retina scale, focused-window match). Live OCR path verified via `scrollbackd ocr-dump` at the M1 gate run (needs Screen Recording grant; not CI-observable).
- [ ] Browser-URL extraction (AX address bar → `FrontmostContext.url` / `Episode.url`). Makes `.url` exclusion rules live (currently inert — no URL is plumbed) and enables URL-based banking exclusion + per-site retrieval filters. DoD: the frontmost browser tab's URL populates the episode and a `.url` neverCapture rule provably suppresses that site.
- [x] Default-on exclusions (password managers, banking, incognito, Claude window, secure-input, NSWindowSharingNone). DoD: excluded apps provably absent from the store. — Done: pure `ExclusionSet` (app/url/window/regex rules, neverCapture|redact) honored in `CaptureEngine` (neverCapture → no episode/events; redact → placeholder); defaults = password managers + Claude Desktop + incognito titles. Runtime signals `IsSecureEventInputEnabled` + `NSWindowSharingNone` gate the live AX/OCR providers (`CaptureGuards`, daemon-only). Banking left to user URL rules (mostly web). Hardened by a 4-lens review (sharing-none fail-safe, redact title masking, `.url` inert documented). Exclusion-manager UI is the later task (line 60).
- [ ] Seed ScrollbackBench golden set from founder dogfood data + wire top-3 episode-hit check into CI. DoD: "that pricing doc I saw Tuesday"-class queries hit top-3.
- [ ] **M1 gate run:** founder's full 8-hour workday — <5% avg CPU, no fan spin-up, battery impact measured (<8% target), zero image frames persisted (store audit), excluded apps absent, storage growth vs single-digit-GB/yr. DoD: measurements recorded in docs/ (these numbers later go on the trust page).

## Next (M1.5 audio lane → M2 recall → M3 filing)

**M1.5 — Audio lane (meetings). Must land before M2's gate ("what did I promise") and M3's extraction:**
- [ ] Audio schema + integrity: `meetings`, `audio_segments` (speaker_label only — schema-level no-voiceprints guarantee), append-only `consent_log`; startup sweep re-links/NULLs orphaned cross-shard segments. DoD: sweep repairs a fabricated orphan; consent_log DAO has no UPDATE/DELETE.
- [ ] **Consent mode ships WITH first audio capture (not M4):** per-meeting prompt, default ON, timestamped consent_log. DoD: no `audio_segments` row can exist without a consent_log row; declined consent stores nothing but the declination.
- [ ] Meeting audio capture: Core Audio process taps (system audio) + mic → WhisperKit on-device STT into audio_segments; FluidAudio diarization opt-in (ephemeral labels). DoD: a real meeting yields a searchable transcript, consent recorded, zero audio bytes leave the daemon, zero biometric embeddings stored.

**M2 — MCP server + recall via Claude ("Claude knows"):**
- [ ] Daemon Unix-socket API v1 (prerequisite of everything below): /search /timeline /summary /drafts /egress /health + POST approve/dismiss/pause/purge; socket mode 0600; per-client tokens minted on first-run, Keychain-stored. DoD: token-bearing client succeeds; token-less local process is rejected even pre-unlock.
- [ ] All five MCP tools per §3a: `search_memory`, `recent_activity`, `daily_summary`, `search_audio`, `timeline` — provenance-carrying, spotlighted snippets, readOnlyHint on all. DoD: each tool returns cited snippets; verify-skill stub replaced with a seeded-corpus top-3 check.
- [ ] Structured MCP error contract: LOCKED (expired biometric session), RATE_LIMITED (anti-hammering), EMPTY_RANGE — never partial silent results. DoD: locked DB yields LOCKED, never empty.
- [ ] `.mcpb` bundle (thin Node proxy → socket) + `claude mcp add` one-liner + fresh-Mac onboarding. DoD: fresh Mac → install → Claude correctly answers "what did I do in the last hour?" in <10 minutes.
- [ ] Empirical privacy test: does Claude auto-memory absorb Scrollback MCP tool results into Anthropic-hosted summaries? + recurring Privacy Center changelog check. DoD: finding in docs/decisions.md; privacy fine-print wording set accordingly.
- [ ] **M2 gate:** Claude answers "what did I do / decide / promise" ≥80% first-try over 5 workdays.

**M3 — Filing agents + approval queue (the hero: "it files"):**
- [ ] Courier full build-out: Anthropic + Notion REST clients, Keychain-ACL'd secrets, ledger-before-send on every request, InternetAccessPolicy.plist exhaustive host list. DoD: all outbound traffic observed from courier PID only; scrollbackd greps clean.
- [ ] Quarantined extraction pipeline: daily_summary → extractor (ambient text in, schema-validated JSON only out; rejected on violation) → privileged composer (never sees raw text). DoD: injection fixture in captured text cannot alter composed output fields.
- [ ] `FilingRunner` interface, three modes: user's Claude subscription (default, Agent SDK/headless), API-key Haiku (agent_runs token/cost logging + live est_cost_usd display), local-LLM offline (honest accuracy disclaimer). DoD: swappable via one setting.
- [ ] Notion recipes ×3 (work-log, tasks/commitments, reading log): append-only, `external_key` idempotency (query-before-write), write_ledger + archive-undo, no agent-emitted URLs/images. DoD: forced retry does NOT duplicate; undo archives the created page.
- [ ] Minimal approval surface (pre-M4): CLI or bare panel over /drafts — approve/edit/dismiss + daily digest; launchd-scheduled filing runs. DoD: founder approves a draft and a scheduled run fires unattended without the M4 shell.
- [ ] Earned autonomy per destination: N unedited approvals → offer auto-file (still logged + undoable); never "approve all forever" on risky classes. DoD: streak counter drives the offer; auto-filed rows appear in the activity feed.
- [ ] **M3 gate:** 5 consecutive workdays of zero-manual-entry work-log at ≥80% unedited approvals.

## Later (M4 shell → M5 provable → M6 launch → Phase 3)

**M4 — Product shell + trust surface ("a stranger can trust it"):**
- [ ] Menu-bar app: status, one-keystroke global pause (POST /pause), today's timeline, "what's captured" transparency view, per-range/per-app purge UI.
- [ ] Exclusion manager UI (app/url/window/regex/schedule; never_capture vs redact). DoD: a rule added in UI takes effect on the next capture event.
- [ ] Onboarding: 3 TCC permissions explained one-at-a-time, first-recall moment ("ask Claude what you did in the last 10 minutes").
- [ ] Capture-health self-test + recovery UX: GET /health drives stall detection, monthly screen-recording re-auth handling, Tahoe vanishing-TCC-grant recovery deep-link. DoD: revoking Screen Recording mid-session surfaces an actionable alert within a minute; QA across macOS 26.x point releases.
- [ ] Egress-ledger UI view (App Privacy Report pattern; table + before-send discipline already live since M1/M3).
- [ ] MDM-enrollment detection → capture disabled by default on managed machines with explanation (day-one commitment; must precede any non-founder install). DoD: MDM-enrolled test profile boots capture-off.
- [ ] Retention engine: scheduled sweep drops shards past policy (30-day Free default / unlimited Pro), opt-in frame retention with own TTL. DoD: a 31-day-old shard provably gone on schedule.
- [ ] Local metrics instrumentation: activation funnel events, auto-filed days/week (north star), approval/edit/undo/duplicate rates, D7/D30 capture-alive, 14-day Siroker self-report prompt — all local; opt-in anonymous aggregate path via courier (egress-logged). DoD: all PRD metrics queryable locally; zero egress without explicit opt-in.
- [ ] Website live on getscrollback.com (Cloudflare Pages): Sparkle appcast + .mcpb download hosted **before** the first notarized DMG. DoD: a Sparkle test update is consumed from the live appcast.
- [ ] Sparkle 2 updates + notarized DMG + Gemma Terms notice file + SQLCipher attribution in About. DoD: notices visible in the first DMG a non-founder receives.
- [ ] Local diagnostics-bundle generator (user reviews contents; no captured text included). DoD: produces a reviewable archive.
- [ ] **M4 gate:** 3 non-founder users reach activation unassisted.

**M5 — Open-core + security hardening ("provable"):**
- [ ] Repo split mechanics: scrollbackd + scrollback-mcp public (FSL-1.1-MIT, history scrubbed), shell/agents private; public repo builds standalone; GitHub Actions attestations (`gh attestation verify` documented).
- [ ] Prompt-injection red-team harness as release blocker: seeded poisoned captures, sleeper/delayed payloads, hidden-text (white-on-white/off-screen) fixtures. DoD: suite green before every release.
- [ ] Trust page: verification commands, airplane-mode demo (documented + recorded), Little Snitch IAP published, measured perf numbers from the M1 gate.
- [ ] Gemma Terms ToS flow-down (Prohibited-Use clause) — or execute Qwen3 fallback if legal rejects. DoD: legal checklist in repo.
- [ ] **M5 gate:** an external MCP-literate dev independently verifies zero-egress.

**M6 — Private beta → Launch:**
- [ ] Capture-specific privacy policy + ToS published (names capture, storage, every egress path: Anthropic/Notion/Sparkle/Paddle) — **before first beta invite**. (This is the exact gap we attack minimi for.)
- [ ] Beta: ~20 P1/P2 users incl. displaced Rewind users; run the 6-question churn-interview script; pricing validation ($15/mo assumption; one-time-license question).
- [ ] License + payments: Paddle/LemonSqueezy MoR onboarding (KYC/tax lead time), checkout → Ed25519 offline-verifiable keys, courier soft-validation (egress-logged), Free/Pro gates on retention + scheduled auto-filing. DoD: sandbox purchase unlocks Pro fully offline; validation failure degrades, never bricks.
- [ ] Uninstall-reason capture (exit survey / beta offboarding) coded creepy/perf/price. DoD: every beta churn has a category.
- [ ] ScrollbackBench full run + defensive BEAM run with published methodology (judge, tokens/query, mode).
- [ ] Trademark screen for "Scrollback" (US/EU/IN, classes 9/42) → clearance memo in docs/ before any public launch asset. **[Start early — lead time.]**
- [ ] Launch content: "what really happened to Rewind" page, "Rewind alternative" + "minimi alternative" SEO pages, Show HN + Product Hunt same week; support channel (support@ + GitHub issues policy).
- [ ] Region-aware consent/capture defaults decision (mic-off default in all-party/criminal-consent jurisdictions?) before the EU-angle push. DoD: decisions.md entry; implemented or explicitly deferred.
- [ ] Limitless-export (JSON) importer + Dec-2026 support-cliff campaign brief; sustained r/ClaudeAI + r/LocalLLaMA presence starting pre-launch.
- [ ] **M6 gate:** launched; Pro tier live.

**Phase 3 (post-launch):** Teams/MDM policies + SEC/FINRA compliance docs; more filing targets (Linear, Slack, calendar); SpeechAnalyzer adoption on macOS 26+; MLX backend experiment; diarization polish; proactive/ADHD surfacing; paid Cure53-class audit; iOS recall companion (never capture).

**Recurring ops:** quarterly sqlite-vec upstream health check (+ vector count vs ~1M trigger, exposed by M1 instrumentation); monitor Anthropic Privacy Center changelog + MCP spec (2026-07-28 stateless migration); watch minimi/Screenpipe for local-embedding moves.
