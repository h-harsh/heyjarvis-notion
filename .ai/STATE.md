# STATE — Scrollback — 2026-07-11

## Now
M1 capture core. Capture spike + perf pass shipped. Next concrete step: **Apple Vision OCR fallback** behind the `CapturedText` / `TextSnapshotProvider` seam — for AX-opaque surfaces (Electron quirks, remote desktops, canvases), with a per-app capability matrix. OCR text must be labelled `source: .ocr` (the seam already supports it), never `.ax`.

## Just finished
- Capture perf pass (the deferred review findings): batched AX reads via `AXUIElementCopyMultipleAttributeValues` (2 IPC/node instead of 5); short-TTL focused-window cache (kills the double window-fetch per window change); `kAXTitleChanged` debounced 0.5s so title-ticking apps don't churn an episode + full AX walk per tick. Batched-read parse extracted to a pure, unit-tested `AXAttributes.stringValues`. 31 tests green; `simulate` exact; networking clean.
- Prior: event-driven capture spike + 8-angle review hardening (secure-field subrole fix, idle vs content separation, resume-after-idle, tsEnd guard, SIGINT flush).

## Blocked / Open questions
- **Founder actions, time-critical:** register getscrollback.com (squattable); enroll Apple Developer Program (lead time).
- **Dated:** Otter.AI MTD hearing Jul 15 — tripwire task in TODO Now.
- **Live-AX verification pending a re-granted binary:** rebuilds drop the dev binary's Accessibility TCC grant, so `ax-dump` / live capture and the CPU-trace confirmation of the perf pass need a manual granted run (folds into the M1 gate run task). Automation stays on `simulate`.

## Next up
- OCR fallback (above) → redact-mode stage → chunker + capture-time dedup + volume/vector counters → encrypted store (SQLCipher + SE key) before real dogfood data persists.
