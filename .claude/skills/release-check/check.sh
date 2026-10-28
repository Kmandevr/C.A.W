#!/bin/bash
# Repo hygiene checks for release-check. Prints PASS/WARN/FAIL lines. Exit 1 on any FAIL.
cd "$(git rev-parse --show-toplevel)"
fail=0
report() { echo "$1 $2 - $3"; [ "$1" = FAIL ] && fail=1; return 0; }

blank=$(.claude/tools/tree.sh --all | awk 'NF==1' | tr '\n' ' ')
[ -n "$blank" ] && report FAIL repo-map "no purpose line for: $blank" || report PASS repo-map "every file has a purpose line"
for d in $(git ls-files | grep / | cut -d/ -f1 | sort -u | grep -v '^\.'); do
  [ -s "$d/.purpose" ] || report FAIL repo-map "$d/ has no .purpose file"
done

for f in docs/*.md; do
  grep -q '^summary:' "$f" || report FAIL notes-frontmatter "missing summary: ($f)"
  grep -q '^updated:' "$f" || report FAIL notes-frontmatter "missing updated: ($f)"
done

for d in graphify-out .serena/cache .serena/logs .serena/memories .claude/worktrees; do
  git ls-files --error-unmatch "$d" >/dev/null 2>&1 && report FAIL generated-tracked "$d is tracked"
done
git ls-files | grep -E '\.(jks|keystore|p12|pem|key)$|(^|/)(local\.properties|\.env)$' | grep -q . && report FAIL secrets-tracked "a keystore, key or local config file is tracked"
git grep -nE 'gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|sk-ant-[A-Za-z0-9_-]{20,}' >/dev/null 2>&1 && report FAIL secrets "a token-looking string is committed (git grep for ghp_/github_pat_/sk-ant-)" || report PASS secrets "no tokens committed"
[ -z "$(git status --porcelain)" ] && report PASS git-clean "working tree clean" || report WARN uncommitted "$(git status --porcelain | wc -l) uncommitted change(s)"

# Context hygiene: no requirement lost from CLAUDE.md or the rules, CLAUDE.md within budget, handoff sound.
ctx=$(.claude/skills/handoff/check.sh) || fail=1
echo "$ctx" | grep -v '^PASS context$' || true
exit $fail
