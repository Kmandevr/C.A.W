#!/bin/bash
# Context hygiene check: no requirement lost when guidance is trimmed or moved (must-keep.txt), CLAUDE.md within its
# word budget, and .claude/handoff.md (if any) small, complete and pointing at a real commit and real files.
# Prints PASS/WARN/FAIL lines; exits 1 on any FAIL. Run by the release-check skill.
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel)}" || exit 1
dir=.claude/skills/handoff; fail=0
say() { echo "$1 $2"; [ "$1" = FAIL ] && fail=1; return 0; }

while IFS=$'\t' read -r file phrase; do
  case "$file" in ''|'#'*) continue ;; esac
  grep -qF -- "$phrase" "$file" 2>/dev/null || say FAIL "must-keep - \"$phrase\" missing from $file"
done < "$dir/must-keep.txt"

budget=${CLAUDE_MD_BUDGET:-900}
words=$(wc -w < CLAUDE.md)
[ "$words" -le "$budget" ] && say PASS "claude-md - $words words (budget $budget)" || say FAIL "claude-md - $words words, over the $budget-word budget: move specialised guidance to rules/ or skills/"

h=.claude/handoff.md
if [ -f "$h" ]; then
  lines=$(wc -l < "$h")
  [ "$lines" -le 40 ] || say FAIL "handoff - $lines lines (at most 40)"
  for s in '## Goal' '## Done and verified' '## Open' '## Next'; do grep -q "^$s" "$h" || say FAIL "handoff - missing \"$s\""; done
  c=$(sed -n 's/^Commit: *\([0-9a-f]\{7,40\}\).*/\1/p' "$h" | head -1)
  if [ -z "$c" ]; then say FAIL "handoff - no Commit: line"
  elif ! git cat-file -e "$c^{commit}" 2>/dev/null; then say WARN "handoff - commit $c is not in this clone"
  else n=$(git rev-list --count "$c..HEAD"); [ "$n" -gt 0 ] && say WARN "handoff - written $n commit(s) ago; check it against the repo"; fi
  for p in $(grep -o '`[^` ]*[/.][^` ]*`' "$h" | tr -d '`' | grep -E '^[A-Za-z0-9_.][A-Za-z0-9_./-]*$' | sort -u); do
    case "$p" in *.*|*/*) [ -e "$p" ] || say WARN "handoff - names $p, which doesn't exist" ;; esac
  done
  [ $fail = 0 ] && say PASS "handoff - $lines lines"
fi
[ $fail = 0 ] && echo "PASS context" || echo "FAIL context"
exit $fail
