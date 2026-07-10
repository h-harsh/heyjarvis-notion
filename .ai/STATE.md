# STATE — Scrollback — 2026-07-11

## Now
Plan-completeness audit done; TODO.md rewritten in full (complete decomposition, M1→M6 + ops). **Awaiting founder's go to start implementation.** First engineering task on go: the event-driven AX-tree capture spike (now incl. clipboard trigger + idle fallback). Requires the Accessibility TCC grant at dev time.

## Just finished
- 4-auditor coverage review of the plan: ~20 missing + ~20 partial commitments found and fixed. Biggest catches: entire audio lane unwritten (now M1.5 with consent bundled), model-download egress had no legal home (now a minimal courier bootstrap in M1, which also lands egress_ledger at first egress), encrypted store resequenced before dogfood data, daemon socket API + LaunchAgent + chunking/redact connective tissue added, oversized M1 tasks split. Corrections logged in docs/decisions.md.
- SwiftPM skeleton green (build/test/run verified); verify skill live (5 checks).

## Blocked / Open questions
- **Founder actions, time-critical:** register getscrollback.com (squattable — was unregistered 2026-07-10); enroll Apple Developer Program (lead time before M4).
- **Dated:** Otter.AI MTD hearing Jul 15 — tripwire task in TODO Now.
- Watch-list: pricing ($15/mo assumed), trademark screen (M6, start early), Claude auto-memory MCP-absorption test (M2).

## Next up (on go)
1. AX capture spike (+ clipboard/idle triggers) → 2. redact stage → 3. chunker + capture-time dedup + volume/vector counters — per the dependency-ordered M1 list in TODO.md.
