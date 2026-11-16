# P1-F.2 Preview UI Stability Freeze

Status: PASS
Date: 2026-11-16
Scope: P1-F.2 only — the two stability debts recorded by the P1-F iOS
acceptance. No Talkify, code-agent, P1-F schema, preview backend, or P1-G
change.

## Merge

| Item | Value |
|---|---|
| Base | AgentKit `main` `b8ae046` |
| Merged feature | `p1-f2-preview-ui-stability@c00b7e9` |
| Merge commit | `006b634` |
| Merge resolution | `fb7323b` — shared `openToolResult` action on macOS and iOS |
| Test harness fix | `f1e2f2b` — warm the iOS hosting harness before layout assertions |

Feature commits: `5a27f6b`, `0e4c013`, `c00b7e9`.

`f1e2f2b` is a **steady-state performance test harness change only**: it warms a
trivial hosted view before the layout assertions so they measure post-warm-up
rendering. It is not evidence about real app cold start and must not be read as
such. The P1-F.2 before/after numbers (7.91 s → 0.51–0.80 s) come from app-level
acceptance; real cold start remains covered there, and the test-only warm-up
neither replaces nor masks that measurement.

`main`'s session-rail, background-job, pre-mutation, and Inspector workspace
changes are preserved. The merge was performed in an isolated scratch worktree;
the original dirty AgentKit checkout was not modified.

## Acceptance

| Metric | Result |
|---|---|
| Failed `ui_preview` group expansion, before | **7.91 s** (P1-F.1 iOS acceptance; main-thread spindump) |
| Failed `ui_preview` group expansion, after | **0.51–0.80 s** |
| Main-thread heartbeat | **0.15–0.30 s** |
| Main-thread block over 2 s | **none** |
| spindump | **none** |

Automated regression on the merged tree:

- 5 MB failed `ui_preview` group: summary-first, windowed SwiftUI layout under 1 s.
- 10 expand/collapse cycles plus 20 layout passes: each pass under 1 s, total under 10 s.
- Preparing the expanded row leaves the full payload unformatted (`payloads` empty).
- 5 MB summary ≈0.10 s; on-demand 64 KB JSON ≈0.01 s.

## Frozen behavior

- **Summary first.** Expanded failed rows show size, line/key count, a ≤400-character
  preview, and `error code · message · payload size · exit code`. No long text is
  constructed during the expansion animation.
- **Large payload on demand only.** The transcript disclosure caps at 64 KB. Complete
  JSON/text is formatted off the main actor, cached per call, and only loaded from the
  Inspector: 128 KB first render, explicit “Show complete” up to 4 MB, plus copy.
- **No repeated formatting.** Identical payloads reuse the cache; SwiftUI body
  recomputation does not encode JSON.
- **Registration-lag retry.** Viewer and asset resolution retry one HTTP 404 after
  **300 ms** with the same revision. Only registration-lag 404s retry;
  digest/security/other failures do not.
- **Real 404.** A persistent 404 still renders `Preview render failed + Retry +
  fallback`; Retry is explicit and keeps the exact revision.
- **One Block per revision.** Live+replay results dedupe, cards mount only after the
  artifact is registered, and revision 1/2 requests match the revision each result
  describes.
- **Switch/replay.** Fast session switches ignore stale in-flight results; replay
  first open survives the registration window; the fallback remains usable after a
  viewer failure.
- **Token safety.** The bearer token stays in the `Authorization` header only; viewer
  and asset URLs carry no token or query, and no token is logged.

## Platform matrix

| Platform | Result |
|---|---|
| macOS 15+ (SwiftPM) | `swift build` PASS; 35/35 required tests PASS |
| iOS Simulator 26.1 (iPhone 17 Pro) | test build PASS; 44/44 PASS |
| iOS Simulator 27.1 (iPhone Duo) | test build PASS; 44/44 PASS |

Suites: `ToolPayloadPerformanceTests` (7), `UIPreviewViewerTimingTests` (9, iOS),
`PreviewResolverRetryTests` (5), `UIPreviewPresentationTests` (23).

## Residual

- Compact summary background fill: **1.8–2.4 s** after expansion. It runs off the
  main actor, does not block expansion, and produces no spindump; tracked as residual
  for the next phase.
- No main-thread block over 2 s and no spindump were observed in P1-F.2 acceptance.

## Out of scope

- Talkify, code-agent, ClientToolsKit, P1-F schema/fixtures, preview backend.
- P1-G five-form matrix and matrix UI.

## Change policy

Any change to preview payload rendering, the viewer/asset retry policy, or preview
card mount order requires rerunning the suites above on iOS 26.1 and iOS 27.1. The
P1-F schema and preview backend remain frozen.
