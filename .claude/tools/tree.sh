#!/bin/bash
# Repo map in layers, built from each file's own purpose line (so it can't go stale).
#   tree.sh          compact top level: root files, then one line per directory
#   tree.sh --brief  shorter top level for the session-start hook: root file names only, directory purposes trimmed
#   tree.sh <dir>    every file in that directory with its purpose
#   tree.sh --all    every file in the repo
# A directory's purpose is the first line of its `.purpose` file.
set -euo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}"

SKIP='(^|/)\.|^(CLAUDE|README|SECURITY)\.md$|^LICENSE$|package-lock\.json$|gradle-wrapper\.jar$'

purpose() {
  case "$1" in
    *package.json) sed -n 's|^ *"description": *"\(.*\)",*$|\1|p' "$1" | head -1 ;;
    *.js|*.cjs|*.mjs|*.ts|*.json|*.jsonc|*.rs|*.kt|*.kts|*.java|*.c|*.cc|*.cpp|*.h|*.hpp) sed -n '1s|^//!* *||p' "$1" ;;
    *.sql)  sed -n '1s|^-- *||p' "$1" ;;
    *.toml|*.yml|*.yaml|*.sh|*.cmake|*CMakeLists.txt|*.properties|*Dockerfile|.gitignore|.graphifyignore) sed -n '1{/^#!/d;}; s|^# *||p' "$1" | head -1 ;;
    *.caw)  sed -n 's|^summary: *||p' "$1" | head -1 ;;
    *.css)  sed -n '1{s|^/\* *||; s| *\*/$||; /^\/\*/!p;}' "$1" | head -1 ;;
    *.html) { sed -n 's|.*<meta name="description" content="\([^"]*\)".*|\1|p' "$1"; sed -n 's|^<!-- *||p' "$1"; } | head -1 ;;
    *.md)   sed -n 's|^summary: *||p' "$1" | head -1 ;;
    _redirects|_headers|*.txt) sed -n '1s|^# *||p' "$1" ;;
    *.xml)  sed -n 's|^<!-- *\(.*\) *-->$|\1|p' "$1" | head -1 ;;
    *.png|*.jpg|*.jpeg|*.webp|*.svg|*.ico|*.wav) echo "Image. See $(dirname "$1")/.purpose" ;;
  esac
}

# A file that can't carry its own line (a generated lockfile, a binary, a JSON fixture) takes its folder's: the nearest
# `.purpose` above it.
inherited() {
  local d; d=$(dirname "$1")
  while [ "$d" != . ]; do
    [ -f "$d/.purpose" ] && { echo "Part of $d/: $(head -1 "$d/.purpose")"; return; }
    d=$(dirname "$d")
  done
}
purposeOf() { local p; p=$(purpose "$1"); [ -n "$p" ] && echo "$p" || inherited "$1"; }

# grep exits 1 on a dotfile-only directory; under pipefail that would end the map early.
files() { git ls-files "$@" | { grep -Ev "$SKIP" || true; } | sort; }
show()  { while read -r f; do printf '%-22s %s\n' "$f" "$(purposeOf "$f")"; done; }

case "${1:-}" in
  --all) files | show ;;
  ""|--brief)
    if [ "${1:-}" = --brief ]; then
      echo "Root files (with purposes: .claude/tools/tree.sh):"; files | grep -v / | tr '\n' ' ' | fold -s -w 118 | sed 's/^/  /; s/ *$//'; echo
    else files | grep -v / | show; fi
    for d in $(git ls-files | grep / | cut -d/ -f1 | sort -u | grep -v '^\.'); do
      n=$(files "$d" | wc -l)
      [ "$n" -gt 0 ] || continue
      p=$(head -1 "$d/.purpose" 2>/dev/null || true)
      [ "${1:-}" = --brief ] && [ ${#p} -gt 100 ] && p="${p:0:97}..."
      printf '%-22s %s\n' "$d/ ($n files)" "$p"
    done
    echo "Expand a directory: .claude/tools/tree.sh <dir>"
    ;;
  *) files "${1%/}" | show ;;
esac
