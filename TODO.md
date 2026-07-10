# TODO — Scrollback

Milestones are sequenced by deliverable (not calendar), per the PRD. Each gates the next.

## Now (M1 — Capture core + memory index: "it remembers")
- [ ] Event-driven AX-tree capture spike: AX notifications + NSWorkspace app-switch + typing-pause triggers on the frontmost window; **no fixed-interval polling**. DoD: frontmost-window text captured on change at <5% avg CPU over a real hour; replace verify check #4 with a real capture assertion (fixture AX tree → CaptureEvents in store).
- [ ] Apple Vision OCR fallback for AX-opaque surfaces + per-app capability matrix. DoD: an Electron/canvas app that yields empty AX still produces text.
- [ ] Default-on exclusions (password managers, banking, incognito, Claude window, secure-input, `NSWindowSharingNone`). DoD: excluded apps provably absent from the store.
- [ ] Instrument deduplicated AX-text volume/hour (the derived-not-measured storage number).
- [ ] Local embedding pipeline: bundled llama.cpp + EmbeddingGemma-300m Q4_0 (512d) behind `RetrievalStore`; first-launch model download. DoD: a captured chunk round-trips to a vector.
- [ ] Encrypted store: SQLite + FTS5 + sqlite-vec, weekly shards, SQLCipher, SE-wrapped key (`.biometryCurrentSet`). DoD: DB unreadable without live Touch ID; purge = drop shard.
- [ ] Hybrid retrieval: FTS5 + vector + recency via RRF; episode segmentation; MinHash dedup. DoD: "what did I do today?" answerable from the raw index.

## Next (on deck)
- [ ] **M2 — MCP server + recall via Claude:** stdio server, `.mcpb` bundle, `claude mcp add` one-liner, provenance-carrying + spotlighted snippets. Gate: Claude answers "what did I do / decide / promise" ≥80% first-try over 5 workdays.
- [ ] **M3 — Filing agents + approval queue (the hero):** Notion work-log/task/reading recipes, quarantined extraction → schema-validated fields → draft-then-approve queue → append-only idempotent writes + undo ledger; earned autonomy; runner = user's Claude subscription (API-key fallback). Gate: 5 consecutive workdays of zero-manual-entry work-log at ≥80% unedited approvals.

## Later (M4–M6 + Phase 3)
- [ ] **M4 — Product shell + trust surface:** menu-bar app, 3-permission onboarding + first-recall moment, timeline/transparency view, purge, egress ledger, consent mode, Sparkle, notarized DMG. Gate: 3 non-founder users activate unassisted.
- [ ] **M5 — Open-core + security hardening:** open-source `scrollbackd`+`scrollback-mcp` (FSL-1.1-MIT) with `gh attestation verify`; prompt-injection red-team harness (poisoned captures, sleeper payloads, hidden text) as a release blocker; Little Snitch IAP; trust page with verification commands. Gate: external dev verifies zero-egress independently.
- [ ] **M6 — Private beta → Launch:** ~20 P1/P2 users (run the churn-interview script on displaced Rewind users); pricing validation; ScrollbackBench + defensive BEAM run; "what really happened to Rewind" page; Show HN + Product Hunt same week; Pro tier live; Limitless-export importer for the ~Dec 2026 orphan wave.
- [ ] **Phase 3:** Teams/MDM policies + SEC/FINRA compliance docs; more filing targets (Linear, Slack, calendar); diarization polish; proactive surfacing for the ADHD segment; paid Cure53-class audit; possible iOS recall companion (never capture).
