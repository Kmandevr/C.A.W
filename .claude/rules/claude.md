---
paths:
  - ".claude/**"
  - "CLAUDE.md"
---

# Claude configuration

- Every piece (skill, agent, rule, hook, tool) has one purpose and changes only when that purpose does. The table in `.claude/README.md` says where each kind of instruction lives; don't restate `CLAUDE.md`, another rule or another skill. Link or name it instead.
- Use the lightest mechanism: a path rule for file-scoped conventions, a skill for a repeatable procedure, a subagent for independent review, a tool script for deterministic work. Add to `CLAUDE.md` only what applies to every session; it has a word budget (`skills/handoff/check.sh`).
- Skill and agent descriptions are always in context, so keep them to one or two sentences about when to use them.
- `tools/`, `hooks/` and `workflows/` stay project-agnostic (identical to AutoStacc's). Project specifics go in `rules/`, `skills/`, `agents/` and `CLAUDE.md`.
- When adding, renaming or removing a piece, update the table in `.claude/README.md`. When moving a requirement, move its line in `skills/handoff/must-keep.txt` too.
