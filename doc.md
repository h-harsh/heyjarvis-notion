# PRD — Smriti (working name)

**A local-first, Claude-native ambient memory for your Mac. It remembers everything you see, say, and hear — and files it into the tools you already use. Nothing leaves your machine unless you ask a question.**

> *Working codename "Smriti" (Sanskrit: memory). Placeholder — rename before launch. Alternatives worth testing: Recall, Mnemo, Trace, Keep.*

---

## 0. TL;DR

The category leader in local memory (Rewind) just died into Meta. The new entrant built for Claude (minimi) leaks your captured text to Google's cloud to embed it. The open-source option (Screenpipe) is infrastructure, not a product. There is an open lane for a **polished, truly on-device, Claude-native memory that also acts** — reading your day back to Claude *and* keeping your Notion, tasks, and notes current on their own.

We build it for one user first (me), dogfood it against my real workflow, then ship a Mac app and launch it as **"the private one."**

The single sentence that defines the product: *Claude should already know what you did today — without your data ever leaving your Mac.*

---

## 1. Why now

Three things are true at the same time, which is rare:

1. **The trusted incumbent vanished.** Rewind pioneered local-first, on-device Mac memory and built real trust (an EFF audit found zero privacy leaks). It rebranded to Limitless, pivoted to cloud + a wearable pendant, was acquired by Meta (Dec 5 2025), and had capture disabled Dec 19 2025. Its privacy-first base is now stranded and shopping for a replacement they can trust — and "owned by Meta, in the cloud" is the opposite of what drew them in.
2. **The Claude-native entrant has a privacy hole.** minimi (by Shram) nailed the positioning — "ambient memory for Claude," MCP-native, zero-setup. But by its own privacy page, capture is embedded via **Gemini's cloud API**, meaning the raw captured text (your screen, your meeting transcripts) is transmitted off-device at capture time. That undercuts the "on-device" promise for exactly the users who care most.
3. **MCP made "memory for the assistant" a real product surface.** A local app can expose memory to Claude Desktop, Claude Code, and Cowork over MCP with zero bespoke integration. The plumbing that used to be the hard part is now standard.

The window: privacy-conscious users are actively migrating, the assistant-native framing is validated, and no one yet offers *local-first + Claude-native + acts-on-your-behalf* in one trustworthy package.

---

## 2. Goals & non-goals

### Goals
- **G1 — Kill the briefing.** Claude answers "what did I do / decide / promise / read" from real captured context, with zero manual input.
- **G2 — Keep my systems current on their own.** The Notion work-log, task list, and reading log we already designed update themselves from captured activity, append-only.
- **G3 — Earn trust by architecture, not by promise.** Default 100% on-device. The privacy story is provable, not marketing.
- **G4 — Ship a real Mac app** that a stranger can install, connect to Claude, and get value from in under 10 minutes.

### Non-goals (v1)
- Not a Windows/Linux app (Mac-first; the orphaned Rewind base is Mac anyway).
- Not a wearable / hardware play (that's the Limitless grave).
- Not a general chat UI — Claude *is* the interface. We are the memory + the hands.
- Not a team/enterprise product yet (Phase 3), though the architecture must not preclude it.
- Not cloud sync in v1 (deliberately — it's the anti-differentiator early on).

---

## 3. Target users

| Wave | Persona | Core need | Why us |
|---|---|---|---|
| **P0 — dogfood** | Me: eng lead at a trading firm, privacy-sensitive, already runs a manual Notion work-log | Stop manually briefing Claude and hand-updating Notion | It's built around my exact workflow; work data never hits a cloud |
| **P1 — beachhead** | Privacy-conscious devs & Claude power users | Local memory that plugs into Claude Code / Desktop / Cowork via MCP | Truly local, scriptable, MCP-native; not DIY like Screenpipe |
| **P2 — expansion** | Rewind orphans + regulated pros (finance, legal, healthcare) | A trustworthy local replacement for the tool Meta killed | Local-only + per-app exclusion rules make it defensible at work |

The strategic bet: **P1 developers are the distribution engine** (they write the tweets, the HN posts, the "I built my second brain" threads), and **P2 regulated users are the willingness-to-pay.** P0 is the design compass.

---

## 4. Positioning & competitive landscape

| Product | Local-first | Claude/MCP-native | On-device embeddings | Acts / files for you | Status |
|---|---|---|---|---|---|
| **Rewind** | Yes (pioneer) | No | Yes | No (recall only) | **Dead** — Meta acq., capture off since Dec 2025 |
| **Limitless** | No (cloud) | No | No | Partial (meetings) | Meta-owned, pendant, new sales halted |
| **Screenpipe** | Yes | Yes (MCP) | Yes (Ollama) | No (DIY pipes) | Alive, source-available, infra-heavy; $25–150/mo commercial |
| **minimi (Shram)** | Partial | **Yes** | **No (Gemini cloud)** | Via Claude only | New, consumer, MCP-native |
| **ScreenMind** | Yes | Yes (MCP) | Yes (local Gemma) | No | OSS, hobbyist |
| **MemX** | Yes | Partial | Yes | No | Recall layer for docs/voice |
| **Smriti (us)** | **Yes** | **Yes** | **Yes** | **Yes (filing agents)** | To build |

**Our one-line position:** *The memory Claude should have had — 100% on your Mac, and it files for you.*

The two claims no competitor holds together: **(a) truly on-device** (our answer to minimi) and **(b) it acts, not just recalls** (our answer to everyone, including dead Rewind). Screenpipe can technically do both but only if you build it yourself; we make it a product.

**Anti-positioning to say out loud in marketing:** "Rewind died. Your memory shouldn't have to move to Meta's cloud to survive." and "On-device means on-device — we never send your screen to Google to remember it."

---

## 5. Product principles

1. **Local by default, cloud by consent.** Data leaves the device only when the user asks Claude a question, and only the relevant snippets, disclosed clearly. Never at capture time.
2. **Text-first, not video-first.** We primarily capture *structured text* (accessibility tree) and OCR fallback — not a 24/7 video reel. Lighter, more private, cheaper to store, and it fixes Rewind's worst flaw (20–30% battery drain).
3. **Append-only, never destructive.** The filing agents add and mark-done. They never delete a row. This rule is the seatbelt from day one.
4. **The user can always see and stop.** A visible menu-bar presence, a "what did you capture" timeline, one-click pause, and exclusion rules that are obvious, not buried.
5. **Claude is the interface.** We don't build a chat app. We make Claude omniscient about the user's own life and give it hands.
6. **Boring where it counts.** Memory you can't trust is worthless; we bias toward conservative capture, aggressive redaction, and provable claims.

---

## 6. Scope — phased

### Phase 0 — Personal MVP (bootstrap, ~days)
Goal: replace my manual briefing and Notion updates. Prove the value loop for one user before investing in native capture.

- **Capture (borrowed):** run Screenpipe locally as the capture engine (free for personal, non-commercial use) to avoid rebuilding OCR/accessibility/audio on day one.
- **Local embedding + index:** pipeline that reads Screenpipe's SQLite, chunks, embeds locally (Ollama `nomic-embed-text` or `mxbai-embed-large`), stores in SQLite + `sqlite-vec` with FTS5 keyword fallback.
- **MCP memory server:** exposes `search_memory`, `recent_activity`, `daily_summary` to Claude Desktop / Code.
- **Filing agent v0:** the scheduled Claude run that reads memory and updates the Notion work-log / task DB we already designed (append-only, ask-before-acting on).
- **Success gate:** for 5 straight workdays, my Notion stays current without manual entry, and Claude correctly answers "what did I do / promise / decide" ≥ 80% of the time.

> Phase 0 uses Screenpipe under its personal/non-commercial terms. It is a validation harness, **not** shippable IP. Native capture (Phase 1) must replace it before any commercial launch — see Open Decision D1.

### Phase 1 — Native capture & product shell
Replace the borrowed engine with owned IP and make it feel like an app.

- **Native capture engine:** `ScreenCaptureKit` for frames, macOS **Accessibility API** as the primary text source (faster and more accurate than OCR), **Apple Vision** OCR fallback, `WhisperKit`/`whisper.cpp` for on-device meeting/mic transcription, active-app + URL metadata.
- **Redaction & exclusion:** never-capture list (password managers, the trading terminal, banking, incognito), URL/domain rules, regex secret-stripping, a global pause and a "work mode" profile.
- **Storage & retention:** encrypted-at-rest (SQLCipher + Keychain-held key), text + embeddings retained, frames optional and TTL'd (default: discard frames after N days, keep text).
- **Menu-bar UX:** status, today's timeline, pause, exclusion settings, "what's captured" transparency view.
- **One-click Claude connector:** copy-MCP-link onboarding, verified with a first-recall success screen.

### Phase 2 — Launch
- **The filing recipes** (each a two-sentence prompt + a pre-built schema): self-updating task list, mini-CRM, reading log, second-brain wiki, and the daily work-log/standup.
- **Onboarding that earns trust fast:** the "ask Claude what you did in the last hour" moment within 10 minutes of install.
- **Launch:** Product Hunt + HN + dev-Twitter, positioned as the private, local, Claude-native successor to Rewind. Optional: open-source the capture core for trust and distribution (see D4).

### Phase 3 — Moat & scale
- Team/admin exclusion policies enforced at the OS level (the Screenpipe-Teams pattern), richer redaction, more connectors (Linear, Slack, calendar), possible iOS companion for recall (not capture).

---

## 7. Architecture (the local pipeline)

```
┌────────────────────────────────────────────────────────────────┐
│  ON DEVICE (your Mac)                                           │
│                                                                 │
│  Capture            Filter/Redact        Index                  │
│  ┌───────────┐      ┌────────────┐      ┌──────────────────┐    │
│  │ Screen     │      │ app/URL    │      │ chunk + embed    │    │
│  │ (Accessi-  │─────▶│ exclusion  │─────▶│ (local model)    │    │
│  │  bility +  │      │ secret     │      │ SQLite +         │    │
│  │  Vision)   │      │ redaction  │      │ sqlite-vec+FTS5  │    │
│  │ Audio      │      └────────────┘      └────────┬─────────┘    │
│  │ (Whisper)  │                                   │              │
│  └───────────┘                                    │              │
│                                                   ▼              │
│                        MCP server (stdio + localhost HTTP)       │
│                        search_memory · recent_activity ·         │
│                        daily_summary · search_audio · timeline   │
│                                                   │              │
│  Filing agents (scheduled)                        │              │
│  read memory ──▶ Claude ──▶ Notion/tasks (append-only)           │
└───────────────────────────────────────────────────┼─────────────┘
                                                     │  only at query time,
                                                     ▼  only relevant snippets
                                            Anthropic API (Claude)
```

**Key architectural decisions:**
- **Accessibility tree as primary text source.** Structured, fast, accurate, cheap — and avoids storing pixels. OCR (Apple Vision) is the fallback for remote desktops / canvases / games where the tree is empty.
- **Hybrid retrieval.** Vector similarity (`sqlite-vec`) for fuzzy recall + FTS5 keyword for exact terms (names, error strings, tickers). Rewind's edge was recall accuracy; ours has to match it.
- **Local embeddings are the moat vs minimi.** Content is embedded on-device. This is the single most important technical choice and the entire privacy claim rests on it (see D6 for model selection).
- **Frames are optional and ephemeral.** Default keeps text + embeddings, discards raw frames on a TTL. Users who want a visual timeline can opt into frame retention.

---

## 8. Core user flows

**Flow A — Recall (the daily magic).** User asks Claude, "what did I promise to send by Friday?" → Claude calls `search_memory` → MCP returns ranked snippets with source + timestamp → Claude answers with citations back to the moment. Success = first-try correct answer.

**Flow B — Morning shift (self-updating systems).** At a scheduled time, a Claude run calls `daily_summary` for the last 24h, diffs against the Notion task DB, appends new commitments, marks done ones, and never deletes. User opens the laptop to an already-current work-log. Ask-before-acting stays on until trusted.

**Flow C — Onboarding.** Install → grant screen + accessibility + mic permissions (explained one at a time) → copy MCP link into Claude's connector → "Ask Claude what you did in the last 10 minutes" → first-recall success screen. Time-to-value target: < 10 minutes.

**Flow D — Trust & control.** Menu-bar → "Today" timeline shows exactly what was captured → user excludes an app/URL, or hits pause → change takes effect immediately and visibly.

---

## 9. Privacy & security model (the moat, stated as spec)

- **Default no egress at capture.** Nothing is transmitted when capturing or embedding. (Direct contrast with minimi's cloud embedding.)
- **Egress only at query time.** When the user asks Claude something, only the retrieved snippets travel to Anthropic's API as context. Disclosed in-product; optionally gated behind a per-session toggle.
- **Exclusion-first for regulated work.** Denylist of apps/windows/URLs (trading terminal, password managers, banking, incognito) that are *never* captured. A stricter "work mode" profile. This is what makes it installable on a firm-issued machine (with sign-off).
- **Encryption at rest.** SQLCipher DB, key in the macOS Keychain, relies additionally on FileVault.
- **Transparency surface.** A "what's captured" view and a one-click purge (delete a time range / an app's history entirely).
- **Provable, not promised.** Publish the egress behavior, allow users to monitor localhost/API calls, and pursue an EFF-style third-party audit pre-launch (Rewind's trust came from exactly this).

---

## 10. Data model (local store)

- **`events`** — id, timestamp, source_app, window_title, url, event_type (screen_text | audio | file | browser), raw_text, redaction_flags.
- **`chunks`** — id, event_id, text, embedding (vector), token_count.
- **`frames`** (optional) — id, event_id, compressed_image_ref, ttl_expires_at.
- **`audio_segments`** — id, timestamp, transcript, speaker_guess, meeting_ref.
- **`exclusions`** — rule_type (app | url | window | regex), pattern, mode (never_capture | redact).
- **`filed_records`** — external_system (notion | linear …), external_id, source_event_ids, status — so filing agents dedupe and stay append-only.

---

## 11. MCP / Claude integration surface

Tools exposed to Claude:
- `search_memory(query, time_range?, source?)` → ranked snippets w/ citations.
- `recent_activity(window)` → chronological digest.
- `daily_summary(date)` → structured "what happened" for the filing agents.
- `search_audio(query)` → meeting/transcript recall.
- `timeline(start, end)` → raw event stream for reconstruction.

Design rule: tools return **snippets with provenance** (app, title, timestamp, url), never dumps — so Claude can cite the moment and the user can trust the answer. Works across Claude Desktop, Claude Code, and Cowork with the same server.

---

## 12. Success metrics

- **North star:** *successful recalls per active week* (Claude answered a memory question correctly on the first try) — this is the value the user feels.
- **Activation:** % of installs that connect Claude and get a first successful recall within 10 minutes.
- **Habit / retention:** % still capturing at D7 / D30 (Rewind's whole thesis: run it a week and you stop updating things by hand).
- **Filing value:** auto-filed rows/week and % of days the work-log stayed current with zero manual entry.
- **Trust:** uninstall reasons, % who enable (vs disable) exclusion rules, battery/CPU complaints (must beat Rewind's 20–30% drain — target < 8%).

---

## 13. Pricing (hypothesis, validate later)

- **Free:** local capture + recall via Claude + N days retention. This is the trust magnet and the dev-distribution fuel.
- **Pro (~$15–19/mo):** unlimited retention, scheduled filing agents, all recipes, encrypted export. Undercuts Screenpipe's $25 while being a finished product, not infra.
- **Later — Teams:** admin exclusion policies + per-app AI permissions for regulated orgs (highest willingness-to-pay, Phase 3).
- Consider a one-time "local license" option for the privacy crowd allergic to subscriptions; keep cloud sync as a separate opt-in line item so the base product stays honestly local.

---

## 14. Risks & mitigations

| Risk | Mitigation |
|---|---|
| "Always-on recording" feels creepy | Text-first (no video reel), visible controls, exclusion-first, publish egress behavior, pursue audit |
| Battery/perf (Rewind's fatal flaw) | Accessibility-tree over OCR, discard frames, throttle on battery; hard target < 8% drain |
| Built "for Claude" = single-vendor dependency | That dependency is the wedge; hedge by keeping the MCP server generic (works with any MCP client) |
| Screenpipe license if used commercially | Phase 0 personal only; native capture before any launch (D1) |
| Apple platform friction (permissions, notarization, ScreenCaptureKit changes) | Native APIs, proper entitlements, graceful permission onboarding |
| Solo build while employed full-time | Ruthless phasing; Phase 0 must deliver personal value before Phase 1 effort; dogfood is the roadmap |
| Regulated users can't install on work machines | Exclusion profiles + local-only + audit make it *defensible*, but position work use as "get sign-off," don't overpromise |
| Incumbent/Meta or minimi ships local + acting | Move fast on the "it files" layer + trust brand; open-sourcing the core (D4) raises the trust moat |

---

## 15. Open decisions (need your calls)

- **D1 — Capture engine path.** Recommend: bootstrap on Screenpipe for Phase 0 (personal, free), build native ScreenCaptureKit engine for launch. Agree, or build native from day one?
- **D2 — Frames: keep or text-only?** Recommend text-first with optional opt-in frame retention. Do you want a visual timeline at all, or is text recall enough?
- **D3 — Ship "acting" in v1 or recall-only first?** The filing agents are our biggest differentiator but also the most failure-prone (they write to real systems). Ship them at launch, or launch on recall and fast-follow with filing?
- **D4 — Open-source the core?** Open-sourcing the capture/MCP core buys trust + dev distribution (Screenpipe's playbook) but complicates monetization. Closed, open-core, or fully open?
- **D5 — Name.** Smriti / Recall / Mnemo / Trace / something else?
- **D6 — Local embedding model.** Ollama dependency (`nomic-embed`/`mxbai`, easy to build, but user must run Ollama) vs a bundled Core ML embedding (zero-dependency, better UX, harder to build). Which trade-off?

---

## 16. Rough roadmap

- **Week 1–2:** Phase 0 — Screenpipe + local embed + MCP + Notion filing agent. Dogfood.
- **Week 3–4:** Hit the Phase 0 success gate; decide D1–D6 from real usage.
- **Month 2:** Phase 1 — native capture engine, redaction/exclusion, menu-bar shell, encrypted store.
- **Month 3:** Phase 2 — recipes, onboarding, connector, private beta with ~20 dev users.
- **Month 4:** Launch (PH/HN), audit published, Pro tier live.

---

*Next step: answer D1–D6 (even rough calls) and I'll turn this into a build plan — the Phase 0 setup, the MCP server spec, and the exact capture/embedding stack — so you can start dogfooding this week.*