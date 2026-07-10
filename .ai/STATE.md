# STATE — Scrollback — 2026-07-11

## Now
Kick off **M1 — Capture core + memory index**. First concrete step: create the SwiftPM workspace skeleton (`scrollbackd` daemon target + a `ScrollbackCore` lib) and spike event-driven Accessibility-tree text capture on the frontmost window (AX notifications + NSWorkspace app-switch), writing raw text to a throwaway store — before wiring embeddings or encryption.

## Just finished
- PRD.md and tech-spec.md written and research-backed (62-agent verified sweep, Jul 10–11).
- Product named **Scrollback**; 7 architecture decisions locked (see docs/decisions.md).
- Project scaffolded: CLAUDE.md, TODO.md, docs/decisions.md, guardrails (.claude/settings.json).

## Blocked / Open questions
- Nothing blocking. Watch-list (from PRD): pricing point ($15/mo assumed), FSL vs MIT for the open core, Otter MTD ruling (~Jul 15 2026), whether Claude auto-memory absorbs MCP tool results, "Scrollback" trademark clearance. None gate M1.

## Next up
- Instrument week-1 deduplicated AX-text volume per hour (the one storage number that's currently derived, not measured).
- Wire the local embedding pipeline (llama.cpp + EmbeddingGemma) behind the `RetrievalStore` protocol.
- Encrypted store: SQLCipher + Secure-Enclave-wrapped key (`.biometryCurrentSet`).
