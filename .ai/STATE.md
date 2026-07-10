# STATE — Scrollback — 2026-07-11

## Now
**M1 — Capture core.** Next concrete step: the event-driven Accessibility-tree capture spike in `scrollbackd` — subscribe to AX focus/value-change notifications + `NSWorkspace` app-switch, read the frontmost window's AX text on change (no fixed-interval polling), and write raw `CaptureEvent`s to a throwaway store. Requires the Accessibility TCC grant at dev time.

## Just finished
- SwiftPM skeleton builds + tests green: `ScrollbackCore` (models, `Provenance`/`CaptureSource`, `RetrievalStore` seam, pure `RankFusion.reciprocalRankFusion`) + `scrollbackd` stub + 6 XCTest cases (exact-value RRF + `.untrustedAmbient` default). `swift build`/`swift test`/`swift run scrollbackd` all verified; commands filled into CLAUDE.md.
- PRD, tech-spec, scaffold, and guardrails committed (2 commits on `main`).

## Blocked / Open questions
- Nothing blocking. `/verify-setup` was deferred until a build existed — that's now unblocked (it's the top task alongside the capture spike). Watch-list unchanged (pricing, FSL vs MIT, Otter ruling ~Jul 15, trademark).

## Next up
- Run `/verify-setup` → real run→observe checks incl. a fixture-driven capture harness.
- Apple Vision OCR fallback + per-app capability matrix.
- Local embedding pipeline (llama.cpp + EmbeddingGemma) behind `RetrievalStore`; then the encrypted SQLite store (SQLCipher + SE-wrapped key).
