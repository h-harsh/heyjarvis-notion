# PRD — Scrollback

**A local-first, Claude-native ambient memory for your Mac that files your day for you. It captures what you see, say, and hear — 100% on-device — and keeps your Notion work-log, tasks, and daily summaries current on their own. Claude can ask it anything; nothing leaves your machine except the snippets you query.**

*Name committed: **Scrollback** ("scroll back through your day" — the terminal scrollback buffer is the text history of everything that happened on your screen). `getscrollback.com` unregistered as of 2026-07-10; `scrollback.app`/`.ai` parked, no live product; sole prior use is a defunct 2014 community-chat startup in an unrelated category.* <!-- TODO: formal trademark screen (US + EU + IN classes 9/42) before public launch -->

*Every market/competitor claim below was verified against primary sources (July 2026) by an adversarial research pass. Corrections to earlier drafts are baked in — notably: the "EFF audited Rewind" story is fabricated SEO content and must never be cited.*

---

## Overview

### The problem

Claude is a brilliant assistant with total amnesia about *your* life. Connectors (MCP) gave it hands — it can touch Notion, email, databases — but a connector only sees what you already typed into a tool. The bottleneck is **capture**: what you read, what was said in meetings, what you promised in Slack, what you decided at 4pm — evaporates. So knowledge workers pay three daily taxes: **briefing tax** (re-explaining context to AI every session), **reconstruction tax** ("what did I do / decide / promise / where did I see that"), and **bookkeeping tax** (hand-updating Notion, work-logs, timesheets). Combined: 30–60 min/day of pure friction.

### The product

Scrollback is a native macOS app that:

1. **Captures** screen text (Accessibility-tree first, OCR fallback — text, not video) and meeting/mic audio (on-device transcription), continuously and event-driven.
2. **Remembers** — embeds and indexes everything locally (bundled embedding model, encrypted SQLite, hybrid keyword+vector+time retrieval). Nothing leaves the device at capture time. Ever.
3. **Serves Claude** — a local MCP server (`search_memory`, `recent_activity`, `daily_summary`, `timeline`, `search_audio`) for Claude Desktop, Claude Code, and Cowork-via-Desktop.
4. **Files for you** — scheduled filing agents draft append-only updates to your Notion work-log, task list, and reading log; you approve from a review queue until each destination has earned auto-file trust.

**One sentence:** *Your work log writes itself — and Claude finally knows what you did today — without your data ever leaving your Mac.*

### Why now (verified July 2026)

1. **The incumbent is dead.** Meta acquired Limitless/Rewind (announced Dec 5, 2025); Rewind's capture was hard-disabled Dec 19, 2025. Its privacy-conscious desktop base is orphaned and actively shopping ("Rewind alternative 2026" is a live SEO war). A second orphan wave hits ~Dec 2026 when Meta's one-year Pendant support lapses.
2. **The Claude-native rival has a provable privacy hole.** minimi (Shram; PH #2 of day, Jun 5 2026) admits on its own site that embeddings are computed via **Google Gemini's cloud API**, meeting audio via **Deepgram**, relayed through their backend — and its legal privacy policy never mentions screen capture at all. "On-device" is their marketing, not their architecture.
3. **The local option is infra, not product.** Screenpipe (YC S26) validated our exact capture architecture but relicensed from MIT to source-available commercial (Jun 10, 2026, $25/mo+), has **no local embeddings** (FTS5 keyword search only), encryption **off by default**, and its agents default to *their* cloud. Developer tool, not consumer product.
4. **The giants validated the category and vacated the private lane.** OpenAI Chronicle (Apr 2026): screenshots processed on OpenAI servers, memories stored as unencrypted local markdown. Microsoft Recall: locally processed but trust-destroyed and under internal rework. Apple's Siri AI (macOS 27, late 2026): momentary on-screen awareness only — no persistent history, no filing.
5. **MCP matured into real distribution.** One-click `.mcpb` bundles into Claude Desktop, `claude mcp add` for Claude Code, and Anthropic's documented policy (Mar 2026) that **MCP tool results are excluded from model training**.

**No shipping product combines: truly on-device capture+embedding + consumer polish + agents that act.** That is Scrollback's lane, and it is contested from every side — the window is roughly 12–24 months before minimi fixes its architecture, Screenpipe adds embeddings, or Anthropic ships ambient context first-party.

### The core strategic insight (from demand-side research)

Rewind proved awareness ≠ revenue: ~$2M peak ARR against a $350M valuation, and its own early adopters admit they *rarely used search*. What retained users: meeting recall and rare "recovered something otherwise lost" moments. What churned them: resource drain (20–40% battery, fans), $20/mo against infrequent use, and bad transcription. What displaced users spontaneously ask for: **automatic work logs, billables reconstruction, standup summaries** — pushed value on days with zero searches.

Therefore: **filing agents are the hero feature; recall is the safety net.** Marketing, activation metrics, and the paywall all anchor on filed output, not search.

### Positioning

*"Rewind died. minimi ships your screen to Google. Scrollback keeps it on your Mac — and does the filing."*

| | On-device capture+embed | Claude/MCP-native | Acts (files for you) | Polished consumer app |
|---|---|---|---|---|
| **Scrollback** | **Yes — provable** | **Yes** | **Yes (append-only + approval)** | **Yes** |
| minimi | No (Gemini/Deepgram cloud, own admission) | Yes | No (recall only) | Partial |
| Screenpipe | Yes (capture; FTS-only, no embeddings; encryption opt-in) | Minimal (2 MCP tools) | DIY pipes (cloud default) | No (dev infra) |
| OpenAI Chronicle | No (cloud processing) | No | No | Pro-only preview |
| Microsoft Recall | Yes (NPU) | No | No | Trust-destroyed, Windows-only |
| Apple Siri AI (macOS 27) | Yes (momentary only) | No | No | No persistent history |
| Highlight / Granola / LUCI | No (cloud) | Partial | Yes (meetings lane) | Yes |

**Trust is architecture, not promise:** split-process design (the process that sees your screen has no network code path — verifiable with Little Snitch/LuLu), open-source capture core, bundled Internet Access Policy, in-app egress ledger, GitHub build attestations, third-party audit when revenue supports it. Never cite the "EFF audited Rewind" claim — it is fabricated.

### Monetization & distribution

**Model: Free + Pro subscription** (committed; hybrid one-time license deferred — see Open Questions).

- **Free:** full capture + recall via Claude + 30-day retention + manual filing (approve-from-queue). The trust magnet and dev-distribution fuel. Generous by design — Rewind's data says the pay gate belongs at the *activation* moment, not the door.
- **Pro — $15/mo or $144/yr** *(assumed within the evidenced $12–19 band; validate in beta)*: unlimited retention, scheduled/auto filing agents, all filing recipes, priority model options, encrypted export. Undercuts Screenpipe ($25/mo) and the $20/mo price point that churned Rewind users.
- **Ongoing user cost note:** filing agents run on the user's **existing Claude subscription by default (no extra cost)**; an optional API-key mode (≈$1.6–7/mo at Haiku-tier) exists for those who prefer it or exceed plan limits — disclosed transparently in-app.
- **Later — Teams** (Phase 3): MDM/admin exclusion policies, compliance documentation (SEC/FINRA books-and-records posture), per-app AI permissions.

**Distribution:** Developer ID + notarized direct download (Mac App Store is technically impossible for AX-tree capture — verified); one-click `.mcpb` extension for Claude Desktop; `claude mcp add` one-liner for Claude Code; launch = Show HN + Product Hunt same week (Hyprnote/minimi playbooks both verified effective in this category); "Rewind alternative" + "minimi alternative" SEO pages; sustained presence in r/ClaudeAI (~750K–1M) and r/LocalLLaMA; EU beachhead angle (Rewind abandoned the EU; Chronicle launched there late; local-first has zero cloud-transfer surface); timed campaign for the ~Dec 2026 Limitless support cliff.

---

## Users

### Personas (in order of strategic priority)

| Wave | Persona | Why them |
|---|---|---|
| **P0 — design compass** | The founder: eng lead at a trading firm, privacy-sensitive, already keeps a manual Notion work-log | Dogfood target; if it doesn't survive his workflow it ships nowhere |
| **P1 — beachhead & distribution** | Claude power users / developers (Claude Code + Desktop, MCP-literate) | They write the launch tweets and HN threads; they can verify the no-egress claim themselves — which is the marketing |
| **P2 — willingness-to-pay** | Rewind orphans + regulated professionals (finance, legal, healthcare-adjacent) + hourly billers | Verified demand: lawyers in public threads begging for automatic billables reconstruction; clinicians left Limitless when Meta killed HIPAA-adjacent protections; a local-only tool is the only installable option on their machines |
| **P3 — expansion** | Back-to-back-meeting professionals; ADHD users wanting proactive time-awareness | Meeting recall was Rewind's actual PMF; ADHD users are the loudest demanders of proactive surfacing (verified in DoneThat/Dayflow threads) |

### Jobs-to-be-done

1. **"Keep my systems current so I don't have to."** Auto-drafted Notion work-log, task list with extracted commitments, reading log — append-only, reviewed then trusted. *(Hero job — the one users described unprompted.)*
2. **"Answer from my life, not from a blank slate."** Claude answers "what did I promise Rahul?", "where did I see that sqlite-vec benchmark?", "write my weekly update" — with citations to the moment.
3. **"Reconstruct my day/week for money or accountability."** Billables, standups, weekly reviews — generated, not remembered.
4. **"Remember the meeting."** On-device transcript, decisions and commitments extracted, filed with consent handled properly.
5. **"Do all of this without making me a data source."** No cloud capture, no vendor access, provable egress story, exclusions for what must never be seen.

---

## MVP Scope

The MVP is the **complete committed product** (user decision: native from day one, no borrowed capture engine), built in dependency order — see Milestones. "Done" for the MVP means a stranger can install it, connect Claude, get a correct recall in <10 minutes, and wake up to a current work-log.

### 1. Native capture engine (macOS 15+, Apple Silicon)
- Event-driven capture: AX notifications + app/window-switch + typing-pause + clipboard triggers, idle fallback — **no fixed-interval polling** (this is the verified anti-Rewind battery architecture; Screenpipe's v2 converged on the same pattern).
- Accessibility-tree text as primary source; Apple Vision OCR fallback for AX-opaque surfaces (Electron quirks, remote desktops, canvases); per-app capability matrix.
- Mic + system-audio (Core Audio process taps) meeting capture with on-device Whisper-class transcription; speaker diarization **opt-in** with ephemeral voice embeddings (BIPA risk is live litigation — verified).
- **Default-on exclusions:** password managers, banking, incognito windows, the Claude window itself (Anthropic directory policy requires it), secure-input fields, apps flagging `NSWindowSharingNone` — honored and *advertised*.
- Definition of done: 8-hour workday captured with **<5% average CPU, no fan spin-up, zero frames stored by default**; excluded apps provably absent from the store.

### 2. Local memory index
- Chunk → embed on-device (bundled model, zero external dependencies — no Ollama requirement) → encrypted SQLite (SQLCipher; key wrapped by Secure Enclave, biometric-gated).
- Hybrid retrieval: FTS5 keyword + vector + recency fused via RRF; episode segmentation (app/window/idle boundaries); dual timestamps (capture time + extracted event time); near-duplicate collapse.
- Retention: text + embeddings kept (30 days Free / unlimited Pro); optional opt-in frame retention with TTL (user decision D2: text-first).
- Definition of done: "that pricing doc I saw Tuesday"-class queries return the right episode in top-3; one year of use fits in single-digit GB.

### 3. MCP memory server
- Local stdio server shipped as one-click `.mcpb` for Claude Desktop + `claude mcp add` one-liner for Claude Code.
- Tools: `search_memory(query, time_range?, app?, entities?)`, `recent_activity(window)`, `daily_summary(date)`, `search_audio(query)`, `timeline(start, end)` — all returning **snippets with provenance** (app, title, timestamp, URL), never dumps; untrusted captured text spotlighted/datamarked in every tool result (prompt-injection hygiene, verified necessary).
- Definition of done: fresh Mac → installed → Claude answers "what did I do in the last hour?" correctly in <10 minutes.

### 4. Filing agents (the hero)
- v1 recipes: **daily work-log** (Notion, append-only), **task/commitment extraction** (meetings + screen), **reading log**.
- Architecture: quarantined extraction (captured text → schema-validated fields only, never free text/URLs) → fixed write path → **draft-then-approve review queue** (approve/edit/dismiss, daily digest) → per-destination *earned autonomy* (offer auto-file after N unedited approvals). Never silent writes on day one — every shipping analog (Highlight, Granola, LUCI) and 68% consumer-trust data says so.
- Writes are append-only, idempotent (client-side external-ID dedup — Notion API has no idempotency keys), logged in a local write ledger, and one-click undoable (API archive). No agent-emitted URLs/images in Notion output (verified exfiltration channel).
- Runner (default committed): the user's **existing Claude subscription** via Agent SDK / `claude -p` headless / Claude Desktop scheduled task — **$0 marginal cost**. API-key mode (Haiku-tier, ≈$1.6–7/mo) is the built-in fallback, one setting away, for users who hit plan limits or if Anthropic changes subscription-SDK billing (they've paused-but-signaled it). Runner stays swappable by design.
- Definition of done: 5 consecutive workdays where the Notion work-log stayed current with zero manual entry and ≥80% of drafts approved unedited.

### 5. Trust & control surface
- Menu-bar app: status, pause (one keystroke), today's timeline, "what's captured" transparency view, exclusion manager, per-range/per-app purge.
- **Egress ledger:** append-only log of every outbound byte (timestamp, destination, byte count, trigger), surfaced in-app — no competitor ships this.
- Split-process architecture: capture/index daemon has no network capability; only a separate "courier" process talks to Anthropic/Notion. Bundled Little Snitch Internet Access Policy naming every endpoint.
- Consent mode for meeting capture: default ON, per-meeting prompt, timestamped local consent log (13-14 all-party US states; Germany criminalizes non-consensual recording).
- Onboarding: permissions explained one at a time (Screen & System Audio Recording, Accessibility, Microphone), graceful handling of macOS's recurring screen-recording re-authorization prompt, "ask Claude what you did in the last 10 minutes" first-recall moment.

### 6. Open-core release (user decision D4)
- Open-source (permissive-with-care license — see tech-spec) the capture + embedding + MCP server core; keep the app shell, filing agents, recipes, and updater proprietary.
- GitHub Actions releases with artifact attestations (`gh attestation verify`); documented airplane-mode demo; published verification instructions.

---

## Non-goals

- **No Windows/Linux** (Mac-first; the orphaned base is Mac; the capture stack is macOS-specific).
- **No hardware/wearable** (that's the grave Limitless is buried in).
- **No chat UI** — Claude is the interface. We are memory + hands, never a chatbot.
- **No cloud sync, no accounts, no server-side anything in v1** — the anti-differentiator. (No backend also means nothing to breach: Cluely's 83K-user screenshot leak is the cautionary tale.)
- **No video timeline by default; no raw-frame retention by default** (D2). Text-first is the battery, storage, and privacy story.
- **No meeting-notes-app feature war** with Granola/LUCI — meeting capture is an input stream, not the product.
- **No team/enterprise features in v1** (Phase 3), but never architecturally precluded: detect MDM enrollment and default to disabled on managed machines from day one (the verified Recall enterprise playbook).
- **No speaker voiceprint storage by default; no emotion/sentiment inference ever** (BIPA litigation wave + EU AI Act Art. 5 prohibitions are live).
- **No engagement/analytics SDKs in the binary. None.** (Bartender's acquisition blowup was triggered by the mere presence of Amplitude.)
- **No perfect-redaction promise** — Recall proves NPU-grade filters miss unlabeled secrets. Our guarantee is "nothing leaves the device," with redaction as defense-in-depth.

---

## Metrics

**North star: auto-filed days per active week** — days the work-log/task list was correct with **zero manual entry** (pushed value; measured locally, reported only via opt-in anonymous aggregates). *(Chosen over Rewind's implicit "searches/week," which is the metric that killed it.)*

- **Activation:** % of installs reaching (a) first correct recall <10 min AND (b) first approved filed entry <24h. Target: ≥60% of completed onboardings. *(assumed — calibrate in beta)*
- **The Siroker gate:** % reaching "recovered something otherwise lost" within 14 days (self-reported prompt in-app).
- **Filing quality:** draft approval rate (target ≥80% unedited), edit-before-approve rate, undo rate, duplicate rate (target ~0 — idempotency is by construction). These metrics are also the earned-autonomy trigger and, aggregated, marketable proof.
- **Retention:** % still capturing at D7/D30 (D30 ≥40% of activated users *(assumed)*); % of Pro conversions occurring after the activation gate rather than before.
- **Performance (launch gate, not aspiration):** <5% average CPU over an 8h day, <8% battery impact, no thermal complaints in beta; storage <1GB/month text-only.
- **Trust:** ≥1 independent third-party "I verified zero egress" write-up post-launch; exclusion-rule adoption rate; uninstall-reason taxonomy with "creepy/perf/price" tracked separately.
- **Recall quality (internal CI):** top-3 episode hit rate on the ScrollbackBench golden set; defensive BEAM run published with full methodology (minimi markets 54%; SOTA systems report 64–74% — beat or don't publish).

---

## Milestones

*(User decision: sequenced by deliverable, not calendar. Each milestone gates the next; the founder dogfoods from M1 onward.)*

### M1 — Capture core + memory index ("it remembers")
Native event-driven capture daemon (AX-first, OCR fallback, exclusions, encrypted store, SE-bound key) + embedding pipeline + hybrid index. **Gate:** founder's real workday captured at <5% CPU; week-1 instrumentation of deduped text volume/hour; "what did I do today?" answerable from raw index.

### M2 — MCP server + recall via Claude ("Claude knows")
Stdio MCP server, `.mcpb` bundle, Claude Desktop + Claude Code integration, provenance-carrying snippets, spotlighting. **Gate:** doc.md's original bar — Claude correctly answers "what did I do / decide / promise" ≥80% first-try over 5 workdays.

### M3 — Filing agents + approval queue ("it files") — *the product becomes the product here*
Notion work-log/task/reading recipes, quarantined extraction, review queue, write ledger + undo, earned autonomy, dual runner (API key / Claude subscription). **Gate:** 5 consecutive workdays of zero-manual-entry work-log at ≥80% unedited approvals — the founder stops updating Notion by hand, permanently.

### M4 — Product shell + trust surface ("a stranger can trust it")
Menu-bar app, onboarding flow (3 TCC permissions, first-recall moment), timeline/transparency view, purge, egress ledger, consent mode, Sparkle updates, notarized DMG. **Gate:** 3 non-founder users reach activation unassisted.

### M5 — Open-core + security hardening ("provable")
Capture/embed/MCP core open-sourced with attestations; injection red-team harness (seeded poisoned captures, sleeper payloads, hidden-text) passing as a release blocker; Little Snitch IAP; trust page with verification commands. **Gate:** an external MCP-literate dev verifies zero-egress independently.

### M6 — Private beta → Launch
~20 beta users from P1/P2 (including displaced Rewind users — run the 6-question churn interview script from research); pricing validation; ScrollbackBench + defensive BEAM run; "what really happened to Rewind" content page; Show HN + Product Hunt same week; Pro tier live; Limitless-export importer shipped for the ~Dec 2026 orphan wave.

### Phase 3 (post-launch, coarse)
Teams/MDM policies + compliance docs (SEC/FINRA posture), more filing targets (Linear, Slack, calendar), diarization polish, proactive surfacing for the ADHD segment, paid Cure53-class audit, possible iOS recall companion (never capture).

---

## Risks & Open Questions

### Top risks (with mitigations)

| Risk | Evidence | Mitigation |
|---|---|---|
| **Retention, not acquisition, kills the category** — users stop searching after week 2 | Rewind's own numbers ($2M peak ARR); founder admissions; churn threads | Filing agents = pushed daily value with zero user action; activation metric measures filed days, not searches |
| **Perf/battery reputation death** | Every major churn quote in the category is a perf quote; Rewind 20–40% battery | Event-driven text-first capture; <5% CPU as a *launch gate*; publish measured numbers |
| **Prompt injection / memory poisoning → filing agent exfiltrates** | Notion AI attack (PromptArmor) did exactly this; OWASP ASI06; "lethal trifecta" | Provenance tagging, quarantined extraction, approve-before-commit, no agent URLs, spotlighting, red-team harness as release blocker |
| **Local DB is an infostealer honeypot** | AMOS/Atomic = ~40% of 2025 macOS malware detections; targets AI power users | SQLCipher + Secure-Enclave-wrapped key, biometric-gated (`.biometryCurrentSet`), rate-limited MCP unlock; honest docs that macOS has no Recall-style compute enclave |
| **Anthropic sherlocks us (12–24 mo clock)** | Screenshot hotkey, free memory, Cowork, Claude Tag ambient mode all shipped in 8 months | Ship fast into what a cloud-AI vendor is structurally slow to do (continuous local capture = their liability minefield); keep MCP server client-agnostic as the hedge |
| **minimi fixes cloud embedding / Screenpipe adds embeddings** | Both technically straightforward | The durable moat is polish + filing agents + trust brand, not embedding location; move first, own the audit/verification story |
| **Meeting-consent legal exposure** (13-14 all-party US states; Germany criminal; Otter litigation pending) | In re Otter.AI MTD hearing Jul 15, 2026 | Consent mode default-ON, per-meeting prompts, local consent log, no voiceprints by default; zero vendor data access structurally defeats the "third-party interceptor" theory |
| **Solo founder + full product scope** | — | Milestone gates are kill-switches; M1–M3 each deliver personal value even if later stages slip |
| **Apple platform friction** (monthly screen-recording re-prompt, Tahoe TCC regressions) | Verified current through macOS 26.4 | AX-primary capture avoids the worst prompt; self-test that capture is actually flowing + recovery UX; QA matrix across 26.x point releases |

### Open questions

1. **Pricing point & annual/monthly mix** — $15/mo *(assumed)*; validate against beta willingness-to-pay; revisit one-time "local license" (+paid upgrades) if beta users echo the verified buy-once Mac preference. <!-- TODO: pricing survey in beta -->
2. **macOS floor** — 15 (Sequoia, WhisperKit STT) vs 26-only (SpeechAnalyzer, simpler) — decided in tech-spec (recommendation: 15+ floor, one STT path first).
3. **Open-core license** — MIT vs Fair-Source/BUSL-style for the open core (Screenpipe's MIT→commercial retreat is the cautionary input). Decided in tech-spec.
4. **Otter MTD ruling** (hearing Jul 15, 2026) — litigation tripwire; revisit consent UX + marketing claims when it lands.
5. **sqlite-vec longevity** — single-maintainer, pre-v1; retrieval layer is interface-wrapped so the store is swappable (usearch / SQLite core's Vec1 as hedges). Re-evaluate at ~1M vectors.
6. **Does Claude's auto-memory absorb MCP tool results into Anthropic-hosted summaries?** Undocumented; affects the privacy fine print. <!-- TODO: test empirically + monitor Privacy Center changelog -->
7. **Trademark clearance for "Scrollback"** and acquisition of scrollback.app/.ai (both parked). <!-- TODO: before launch -->
8. **India/EU consent defaults** — region-aware capture defaults (e.g., mic-off default in criminal all-party states)? Decide before EU push.

---

## Stack Preferences

*(User-committed constraints; full options/tradeoffs in tech-spec.md)*

- Native macOS app (Swift/SwiftUI + AppKit for the shell; capture daemon native — no Electron), Apple Silicon, distributed via Developer ID + notarization + Sparkle (Mac App Store is impossible for AX capture — verified).
- On-device embedding via a bundled runtime (llama.cpp-class) with first-launch model download — **no Ollama dependency** (dev-tool pattern, not consumer).
- SQLite-centric store: FTS5 + sqlite-vec behind a swappable retrieval interface; SQLCipher encryption; Secure-Enclave key custody.
- MCP: local stdio server, `.mcpb` packaging, Node runtime that ships inside Claude Desktop; Streamable HTTP behind a flag only.
- Filing via Notion REST API directly (official local Notion MCP server is maintenance-mode); append-only with client-side idempotency.
- Filing-agent LLM: user's Claude subscription (Agent SDK / headless) as the default runner; Anthropic API key (Haiku-tier) as the swappable fallback.
- Open-core: capture + embedding + MCP server public; shell/agents/recipes proprietary.
