# STATE — Scrollback — 2026-07-11

## Now
M1 capture core. Capture spike + perf pass + **OCR fallback** shipped. Next concrete step: **redact-mode stage** — a capture-time pass that flags/masks sensitive spans (see `events.redaction_flags` in tech-spec §2), feeding the upcoming default-exclusions and the chunker. After that: chunker + capture-time dedup + volume/vector counters → encrypted store (SQLCipher + SE key) BEFORE real dogfood data persists.

## Just finished
- **OCR fallback (AX-opaque surfaces):** `LayeredTextSnapshotProvider` composes AX + OCR behind the (synchronous) `TextSnapshotProvider` seam, routed by a per-app capability matrix (`AppCaptureCapabilities` → `CaptureStrategy`) and `OCRFallbackPolicy` (OCR only on empty/thin AX, never regressing below AX). Live path `VisionOCRExtractor` = ScreenCaptureKit window screenshot → Vision text recognition → `OCRTextAssembler` reading-order join; the CGImage is discarded post-recognition (zero frames stored). Degrades to AX-only without the Screen Recording grant. New `scrollbackd ocr-dump` diagnostic. Decision + secure-field-bypass gotcha logged in docs/decisions.md.
- **Adversarial 5-lens review → 12 confirmed findings, all fixed:** the `OCRTextAssembler` comparator was not a strict weak ordering (intransitive → `sorted` garbled reading order on dense/staggered layouts) — fixed to a total order + per-line left sort; a timeout-path data race on the async→sync bridge — fixed (read only on `.success`) plus an in-flight guard + task cancel; OCR bypassed the AX secure-field guard — added `CapturedText.containedSecureField` so OCR is refused for a window where AX skipped a secure field; Retina 1× undersampling — capture at pixel scale; `bestWindow` picked largest not focused — prefer title match. 51 tests green (+20 total for the increment); `simulate` exact; networking grep clean; permission-denied degradation observed (exit 3).
- Prior: capture perf pass (batched AX reads, focused-window cache, title debounce); event-driven capture spike + 8-angle review hardening.

## Blocked / Open questions
- **Founder actions, time-critical:** register getscrollback.com (squattable); enroll Apple Developer Program (lead time).
- **Dated:** Otter.AI MTD hearing Jul 15 — tripwire task in TODO Now.
- **Live-TCC verification pending a re-granted binary:** rebuilds drop the dev binary's Accessibility grant, and OCR additionally needs the Screen Recording grant — so `ax-dump` / `ocr-dump` / live capture and the perf/CPU trace need a manual granted run (folds into the M1 gate run). Automation stays on `simulate`.
- **OCR secure-field bypass (partially mitigated):** a screenshot has no field-level secure-field guard. Now suppressed for windows where AX saw a secure field (`containedSecureField`). Residual: all-canvas logins with empty AX + `ocrOnly` apps — closed by the NEXT tasks (default exclusions + redact). Must NOT ship to real dogfood before default exclusions land. (Logged in decisions.md.)

## Next up
- Redact-mode stage → default-on exclusions (password managers/banking/incognito/secure-input — closes the OCR secure-field gap at the app level) → chunker + capture-time dedup + volume/vector counters → encrypted store (SQLCipher + SE key) before real dogfood data persists.
