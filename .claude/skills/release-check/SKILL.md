---
name: release-check
description: Final check for C.A.W before calling a change ready, opening a pull request or merging. Runs the docs guard and repo hygiene checks, reviews diff scope, and reports PASS/WARN/FAIL with a verdict.
---

# Release check

The shell checks are independent: start them together in one Bash call. Launch the reviewer agents the diff calls for (none for a small or single-area change; at most one per area) in the same message, and do the reading below while they run.

```sh
L=$(mktemp -d)
node scripts/docs-test.js > $L/docs-test.txt 2>&1 & p1=$!
.claude/skills/release-check/check.sh > $L/hygiene.txt 2>&1 & p2=$!
git diff origin/HEAD --stat > $L/diff-scope.txt 2>&1 & p3=$!
wait $p1; e1=$?; wait $p2; e2=$?; wait $p3; e3=$?
for n in "docs-test $e1" "hygiene $e2" "diff-scope $e3"; do set -- $n; echo "== $1 (exit $2)"; cat $L/$1.txt; done
```

1. **Docs:** `node scripts/docs-test.js`. A FAIL blocks. Each `WARN stale` names a note whose covered files changed: read its part about them and update it, or confirm it still holds. If behaviour or a decision changed, `docs/log.md` and `docs/decisions.md` are updated, and superseded text is rewritten, not left beside the new (`.claude/rules/docs.md`).
2. **Repo hygiene:** `.claude/skills/release-check/check.sh`: purpose lines for the repo map, note frontmatter, generated folders or secrets that would be committed, uncommitted changes, and the context check (`.claude/skills/handoff/check.sh`).
3. **Diff scope:** flag files that don't belong to the stated change.
4. **Reviewers:** `audio-reviewer` for `engine/` or the audio path, `security-reviewer` for module loading, sync, auth, permissions or `.github/`, `code-reviewer` for other code, `architect` for structural changes. Brief each with the diff range, changed files and check results already in hand.
5. **Engine and app checks:** none yet. When `engine/` and `android/` land, their test commands are added here and to `CLAUDE.md` ("Checking changes").

Report `PASS|WARN|FAIL <check> - <detail> (<file>)` lines and one verdict line: READY, READY WITH WARNINGS or NOT READY.
