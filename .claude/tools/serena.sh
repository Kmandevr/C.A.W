#!/bin/bash
# Starts the Serena MCP server for this project (used by .mcp.json). Installs Serena on first use.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"
command -v serena >/dev/null 2>&1 || uv tool install -p 3.13 serena-agent >&2
exec serena start-mcp-server --context claude-code --project-from-cwd
