#!/bin/bash
# Self-test for Graphify and Serena: installed, graph fresh and queryable, Serena's MCP server starts.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 1
fail=0
ok()  { echo "PASS  $1"; }
bad() { echo "FAIL  $1"; fail=1; }
graph=.claude/tools/graph.sh

command -v uv >/dev/null && ok "uv installed" || bad "uv missing (install from https://docs.astral.sh/uv/)"
$graph query "docs guard" >/dev/null 2>&1 && command -v graphify >/dev/null && ok "graphify installed and answers a query" || bad "graph.sh query failed"
[ "$($graph query "docs guard" 2>/dev/null | grep -c '^NODE')" -gt 0 ] && ok "graph has nodes for 'docs guard'" || bad "graph query returned no nodes"

probe=scripts/zz-code-nav-probe.js
trap 'rm -f "$probe"' EXIT
printf '// probe\nfunction zzCodeNavProbe() { return 1; }\n' > "$probe"
$graph explain "zzCodeNavProbe()" 2>/dev/null | grep -q "^Node:" && ok "graph picks up a new file" || bad "graph missed a new file (stale refresh)"
rm -f "$probe"
$graph explain "zzCodeNavProbe()" 2>/dev/null | grep -q "^Node:" && bad "graph kept a deleted file (stale refresh)" || ok "graph drops a deleted file"

command -v serena >/dev/null && ok "serena installed" || bad "serena missing (run .claude/hooks/session-start.sh)"
command -v serena-hooks >/dev/null && ok "serena-hooks installed" || bad "serena-hooks missing"
[ -f .serena/project.yml ] && ok ".serena/project.yml present" || bad ".serena/project.yml missing"
grep -q '"serena"' .mcp.json && grep -q '"serena"' .claude/settings.json && ok "serena registered in .mcp.json and enabled" || bad "serena not registered/enabled"

# Start the MCP server and complete an initialize handshake.
init='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"check","version":"0"}}}'
reply=$( (echo "$init"; sleep 20) | timeout 60 .claude/tools/serena.sh 2>/dev/null | head -1)
echo "$reply" | grep -q '"serverInfo"' && ok "serena MCP server starts and answers" || bad "serena MCP server did not answer initialize"

exit $fail
