# C.A.W

**C.A.W** (Code Auditioning Workspace; the logo is a crow) is an experimental, code-driven glitch-sound instrument for Android, iOS, Windows, macOS and Linux (Android first): bytebeat, procedural synthesis, raw byte and audio mangling, and compact sequencing. Code is the source of truth, all audio renders locally on the phone, and WAV export feeds the owner's Reaper projects. Sound modules live as plain files in git, so any AI agent can make sounds without driving the phone's UI. It will be sold only through AutoStacc; until then it's the owner's tool for making AutoStacc samples. The owner's brief: [docs/vision.md](docs/vision.md). The plan: [docs/architecture.md](docs/architecture.md) and [docs/roadmap.md](docs/roadmap.md). **Status:** v1 is built: engine ([docs/engine.md](docs/engine.md)) and app ([docs/app.md](docs/app.md)).

## Start of every session

Tasks and bugs live in GitHub Issues: use the `tasks` skill to find, claim and finish work, and don't keep a task list anywhere else. The `docs/` folder holds permanent project knowledge (an Obsidian vault); its notes list is [docs/index.md](docs/index.md).

## Rules

- Keep facts, proposals, assumptions and open questions apart, as `docs/vision.md` and `docs/architecture.md` label them. Never present a proposal as built, and never build an open question as settled: ask the owner.
- Never invent facts about libraries, versions, licences, platform behaviour or devices. Check a primary source and date it, or label it an assumption.
- The audio callback never allocates, locks, logs, does I/O or calls into the UI layer (details: `.claude/rules/engine.md`).
- Downloaded and AI-written modules are untrusted: they run only inside the engine's sandbox, with no I/O and fixed limits. Never ship a GitHub token or other secret in the app.
- Dependencies must have permissive licences (no GPL) unless the owner decides otherwise. Record each new one in `docs/decisions.md`.
- The owner works from an Android phone (Galaxy S22+): every build, test and installable comes from GitHub Actions, and no step needs a PC or IDE.
- Record decisions and new facts in `docs/` before ending a session, and rewrite superseded text where it stands instead of appending (details: `.claude/rules/docs.md`).

## Layout

`docs/` is the plan and memory, `scripts/` holds repository tooling and `.claude/` the agent setup ([.claude/README.md](.claude/README.md)). Code: `engine/` (C++ engine and `caw` CLI), `app/` (Flutter) and `examples/` (starter modules). Conventions for each kind of file load from `.claude/rules/` when you touch it.

## Read in layers

Don't read every file. Go deeper only when the layer above doesn't answer, and never re-read a file already in context.

1. **Map:** the session-start hook prints the top level. `.claude/tools/tree.sh <dir>` lists one directory's files with their purposes.
2. **Skill:** for a repeatable task, use its skill (`tasks`, `release-check`, `code-nav`, `handoff`). Skills name the files; don't re-derive them.
3. **Graphify** for orientation across files: `.claude/tools/graph.sh query "<keywords>"`, `explain "<name>"`, `affected "<name>"` (the `code-nav` skill).
4. **Serena** for symbols in Dart and C++ (overview, find with body, references, symbol edits) instead of reading a whole file (see `.claude/README.md`).
5. **File:** open only what the layers above named, with Grep or Read `offset`/`limit`.

## Workflow

One-file changes: just do them. Every file (code, notes, Claude config) has one purpose; change only the files the task needs. Independent review goes to an agent in `.claude/agents/` (`architect` before structural changes, the reviewers after), asking for findings only. Changes across areas: the saved workflow `change` (plan, build in parallel on disjoint files, verify, update docs; never commits).

**Parallel by default.** Independent tool calls go in one message. Spawn subagents only for several sizeable independent parts or an independent review; small or single-area work is done inline, to keep usage down. Parallel subagents work on disjoint files, each in a worktree from the current branch (`git worktree add -b <name> .claude/worktrees/<name> HEAD`), briefed with what you already know (changed files, diff range, findings, checks run and their results) so they don't re-explore.

## Context

Keep context while it helps; clean up only at a task boundary (task done, PR opened or merged, before `/clear`) or when context is crowded. Drop the superseded: reads of files since edited, outputs of re-run checks, finished subtasks' detail. Carry into any compaction or summary: the owner's requirements and decisions, security constraints, unresolved issues, verified results (with the command that showed them), branch and next step. Multi-step task at a boundary: the `handoff` skill. A handoff is never the only copy of a requirement or decision (those go in `docs/` or Issues first).

## Checking changes

Run `node scripts/docs-test.js` after touching any note, `README.md`, `CLAUDE.md` or `.claude/`. Before calling a change ready, run the `release-check` skill. CI (`.github/workflows/docs.yml`) runs the same checks on every push and pull request. Engine: build `engine/` with CMake and run `caw_tests` (commands in [docs/engine.md](docs/engine.md); golden hashes change only with an intended sound change: `--update-golden`). App: `flutter analyze` and `flutter test` in `app/` (`CAW_LIB=<built libcaw.so>` adds the engine integration test). CI (`engine.yml`, `app.yml`) runs both.

## Git

Develop on the branch the session names. Put `Closes #N` in pull requests that finish an issue.
