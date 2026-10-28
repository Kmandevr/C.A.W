#!/bin/bash
# Stop hook: when this branch changed code that a note covers (the project's DOCS_STALE_CMD lists such notes, one
# "note<TAB>changed files" line each; default: node scripts/docs-test.js --stale) but not the note itself,
# Claude is asked once to check those notes before finishing. Asks again only when the set of stale notes changes,
# so a note that truly needs no change never loops. Silent when nothing is stale or the check can't run.
set -uo pipefail
cd "${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}" || exit 0
input=$(cat)
case "$input" in *'"stop_hook_active":true'*|*'"stop_hook_active": true'*) exit 0 ;; esac
cmd=${DOCS_STALE_CMD:-node scripts/docs-test.js --stale}
[ -f "$(printf '%s' "$cmd" | awk '{print $2}')" ] || exit 0

stale=$($cmd 2>/dev/null) || exit 0
[ -n "$stale" ] || exit 0
session=$(printf '%s' "$input" | sed -n 's/.*"session_id" *: *"\([^"]*\)".*/\1/p')
mark="${TMPDIR:-/tmp}/claude-docs-reminder-${session:-none}"
sum=$(printf '%s' "$stale" | cksum | cut -d' ' -f1)
[ "$(cat "$mark" 2>/dev/null)" = "$sum" ] && exit 0
echo "$sum" > "$mark"

notes=$(printf '%s\n' "$stale" | cut -f1 | tr '\n' ' ')
reason="Docs check: this branch changed code covered by ${notes}but not the note(s). Read each note's part about the changed files ($cmd lists them) and update it if it no longer matches the code, following the project's rules for notes. If a note is still accurate, say so and finish; you won't be asked again for the same notes."
printf '{"decision":"block","reason":"%s"}\n' "$(printf '%s' "$reason" | sed 's/\\/\\\\/g; s/"/\\"/g')"
exit 0
