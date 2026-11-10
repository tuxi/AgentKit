# DreamLog Duo Creation Home Preview

Status: **Accepted — packaged AgentKit preview**

Canonical entry: [`current.html`](current.html)
Latest milestone: [`revisions/r4d.html`](revisions/r4d.html)
Evidence: [`evidence/r4d/`](evidence/r4d/)
Machine-readable manifest: [`manifest.json`](manifest.json)
Testing guide: [`TESTING.md`](TESTING.md)

## Purpose

This self-contained interactive HTML preview validates the DreamLog Duo creation
home across three device forms:

- outer screen
- inner portrait
- inner landscape

It is a design/acceptance artifact for AgentKit's `interactive_html` preview
pipeline. It is not AgentKit runtime source code.

## Current validation

- DreamLog source baseline: `a0c78f7a85fc83b3af6a899bd580584be454494c`
- HTML size: `446779` bytes, below the `2 MiB` interactive preview limit
- HTML SHA-256: `23695af5fa0187abfed70046fc26a2920d35ee3313da33a52eee05180b300817`
- Inline SVG icons: `14`
- `data-lucide` placeholders: `0`
- Remote resources / fetch / XHR / WebSocket / bridge / iframe / form: none
- Browser console errors: `0`
- Validated browser widths: `500px`, `900px`
- Wide mode remains two-column at both widths
- Wide device is fixed internally at `700px` and is scaled as a whole when the
  host is narrower

The R4d correction addressed missing inline icons, wide-mode container collapse,
self-contained constraints, and scale/stage-height behavior.

## Validation rule

The canonical `current.html` must stay below `2 MiB`. Before replacing it:

1. Open all three forms at approximately 500px and 900px widths.
2. Confirm wide mode has two columns and no page-level horizontal overflow.
3. Confirm the stage height follows the scaled device height.
4. Confirm all inline icons remain visible.
5. Verify no remote resources, bridge calls, navigation, forms, iframe, fetch,
   XHR, or WebSocket usage.
6. Update `manifest.json`, this README, and `evidence/`.

## Revision policy

- Keep `current.html` as the stable entry point.
- Archive immutable milestone snapshots in `revisions/`.
- Keep each milestone's screenshots and geometry under `evidence/<revision>/`.
- Record product acceptance separately from technical HTML validation.
