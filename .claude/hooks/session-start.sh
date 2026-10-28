#!/bin/bash
# Session start. Stdout goes into the session's context, so it is kept to a short git, log and handoff status plus the brief top-level map.
# Serena is installed here (output to stderr) so the MCP server starts fast and the install is cached.
set -uo pipefail
command -v serena >/dev/null 2>&1 || uv tool install -p 3.13 serena-agent >&2 || true
# Node dependencies (if the project has a lockfile) install in the background so the session isn't held up.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" || exit 0
if [ -f package-lock.json ] && [ ! -d node_modules ]; then (npm ci --no-audit --no-fund >/dev/null 2>&1 &); fi

# The parts are independent: each writes its own file in the background, then they print in order.
LOG_NOTE=${SESSION_LOG_NOTE:-docs/log.md}
T=$(mktemp -d) || exit 0
trap 'rm -rf "$T"' EXIT
"$(dirname "$0")/../tools/tree.sh" --brief > "$T/map" 2>/dev/null &
if git rev-parse --git-dir >/dev/null 2>&1; then
  { printf 'Branch: %s; uncommitted changes: ' "$(git branch --show-current 2>/dev/null || echo detached)"; git status --porcelain 2>/dev/null | wc -l | tr -d ' '; } > "$T/branch" &
  git log -5 --format='  %h %<(72,trunc)%s' 2>/dev/null | sed 's/ *$//' > "$T/commits" &
fi
# The note's newest entries are its first bullet lines ("Newest first").
[ -f "$LOG_NOTE" ] && grep -m3 '^- ' "$LOG_NOTE" | cut -c1-200 | sed 's/^/  /' > "$T/log" &
wait

# Branch, log and handoff come first, then the short map: the whole output has to stay well under the size at which the
# harness moves hook output to a file and shows only a short preview.
if [ -s "$T/branch" ]; then cat "$T/branch"; echo 'Last commits:'; cat "$T/commits"; fi
if [ -s "$T/log" ]; then echo "Newest in $LOG_NOTE (trimmed):"; cat "$T/log"; fi
# A handoff from an earlier session (the handoff skill): printed at start and after compaction, with how far the
# repository has moved since, so it is checked before it is relied on.
H=.claude/handoff.md
if [ -f "$H" ]; then
  c=$(sed -n 's/^Commit: *\([0-9a-f]\{7,40\}\).*/\1/p' "$H" | head -1)
  n=$( [ -n "$c" ] && git rev-list --count "$c..HEAD" 2>/dev/null || echo "?")
  echo "Handoff ($H, written at ${c:-unknown}; $n commit(s) since: verify against the repo before relying on it):"
  head -40 "$H"
fi
echo 'Repo map, top level (layer 0). Stop here if it answers the task. Details: .claude/tools/tree.sh <dir>; questions: .claude/tools/graph.sh query "<keywords>", then Serena for symbols (code-nav skill).'
cat "$T/map" 2>/dev/null
# Install Graphify if needed and bring the graph up to date in the background, so the first graph.sh query of the
# session doesn't wait for either.
[ -x .claude/tools/graph.sh ] && (nohup .claude/tools/graph.sh refresh >/dev/null 2>&1 &)
exit 0
