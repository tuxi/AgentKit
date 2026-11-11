# code-agent view_image wire fixtures

Captured from the frozen code-agent baseline:

- code-agent commit: `80329b140806b68ddfab2483fab414e3d0241454`
- AgentKit consumer checkpoint: `80f9d00535a256d096f8f9144b6448131a163644`
- capture date: 2026-11-11

Capture method: ran the real `agent.Runner` with `imageview.NewTool()` through a
temporary `go test -overlay` file, then serialized the emitted `tool_finished`
with code-agent's production `toWire` mapping. The code-agent worktree was not
modified. Only `event_id` values were made deterministic for fixture identity.

Fixtures:

- `source-only.wire.json`: real `view_image` source-only result.
- `source-and-crop.wire.json`: real source + generated crop result.
- `workspace/`: the exact source/crop PNG bytes produced during capture.

The asset SHA-256 values in the JSON match the bytes under `workspace/`.
Absolute paths in the payload are the capture-machine paths; AgentKit resolves
the fixture files through `workspace_relative_path` and the fixture workspace
root, matching production behavior.
