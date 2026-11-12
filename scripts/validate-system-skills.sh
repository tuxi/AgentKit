#!/usr/bin/env bash
# Validate AgentKit's copied system-skill lock against a code-agent checkout.
# Usage: scripts/validate-system-skills.sh /path/to/code-agent
set -euo pipefail
cd "$(dirname "$0")/.."
CODE_AGENT_ROOT="${1:-../code-agent}"
cd "${CODE_AGENT_ROOT}"
go run ./cmd/system-skills \
  --root "$(pwd)" \
  --check \
  --agentkit-resources "$(cd - >/dev/null && pwd)/Sources/AgentKit/Resources/skills/.system"
