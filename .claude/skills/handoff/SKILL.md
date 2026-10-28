---
name: handoff
description: Write or refresh .claude/handoff.md so a new or compacted session can resume a multi-step task without re-exploring. Use at a task boundary (task done, PR opened or merged, before /clear, end of session) when work is unfinished; skip for one-step tasks.
---

# Handoff

1. **Durable first.** Anything that must outlive the task goes where it lives for good before the handoff is written: decisions in `docs/decisions.md`, changes in `docs/log.md`, open work in GitHub Issues (`tasks` skill), facts in the note that owns them. The handoff may point at them; it never holds their only copy.
2. **Write `.claude/handoff.md`** (replace the old one; it's a snapshot, not a log), at most 40 lines, with these headings:
   - `# Handoff` then `Commit: <short sha>` and `Branch: <name>`.
   - `## Goal`: the owner's request and requirements, in their terms.
   - `## Done and verified`: what changed and the command that proved it.
   - `## Open`: unresolved issues, blockers, questions for the owner.
   - `## Next`: the next concrete step.
   - `## Read first`: only the files a successor needs (existing paths, in backticks).
3. **Drop** what the repository already shows, finished detail and anything superseded.
4. Run `.claude/skills/handoff/check.sh` and commit the handoff with the work it describes.

Reading a handoff (the session-start hook prints it): trust it only as far as the repository agrees. If commits came after it, check `git log <commit>..HEAD` and the files it names first. Delete it once its task is finished and its facts are recorded.
