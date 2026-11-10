# AgentKit Interactive Design Previews

This directory indexes self-contained interactive design previews used to review
AgentKit and host-app capabilities before or alongside native implementation.

## Index

| Preview | Canonical entry | Status | Evidence |
| --- | --- | --- | --- |
| DreamLog Duo Creation Home | [`dreamlog-duo-creation-home/current.html`](dreamlog-duo-creation-home/current.html) | Accepted — packaged AgentKit preview | [`evidence/r4d/`](dreamlog-duo-creation-home/evidence/r4d/) |

## Placement rules

- Preview artifacts belong in this design-preview tree, not in `Sources/AgentKit`
  runtime resources or `Web/ConversationWorkbench/src`.
- `current.html` is the stable entry point. Milestone snapshots live in
  `revisions/`; screenshots and geometry proofs live under `evidence/`.
- Each preview must be self-contained and remain below the AgentKit interactive
  preview limit of 2 MiB.
- Record status, source baseline, size, SHA-256, validation widths, and known
  limitations in the preview's `README.md` and `manifest.json`.
- Revalidate and update the manifest whenever `current.html` changes.
