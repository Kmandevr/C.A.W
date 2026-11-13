# C.A.W

**C.A.W** (Code Auditioning Workspace; crow logo) is an experimental, code-driven sound-design and music workspace. The current Flutter app ships Android and Windows builds; the portable C++20 engine is also built and tested by Linux/Windows CI. The app has three sections: Build, Files and Arrange. Not every roadmap feature is built: [docs/app.md](docs/app.md) is shipped app behaviour, [docs/engine-build-status.md](docs/engine-build-status.md) the native side and its boundaries, [docs/core-and-feature-plan.md](docs/core-and-feature-plan.md) planned work. The beta sends anonymous telemetry and optional feedback through a relay; audio processing stays local, and there is no in-app AI or cloud audio. AI coding assistants are development tools, not a product feature. The owner's product direction is in [docs/vision.md](docs/vision.md).

**Data and services:** Kmandevr/C.A.W-Telemetry holds what C.A.W collects (telemetry, feedback Issues, privacy policy, terms) and the beta relay; its PLAN.md is the contract's other copy. Work cross-repo changes in one session (add_repo).

## Start of every session

Tasks and bugs live in GitHub Issues: use the `tasks` skill to find, claim and finish work, and don't keep a task list anywhere else. The `docs/` folder holds permanent project knowledge (an Obsidian vault); its notes list is [docs/index.md](docs/index.md).

## Rules

- Keep facts, proposals, assumptions and open questions apart, as `docs/vision.md` and `docs/architecture.md` label them. Never present a proposal as built, and never build an open question as settled: ask the owner.
- Never invent facts about libraries, versions, licences, platform behaviour or devices. Check a primary source and date it, or label it an assumption.
- The audio callback never allocates, locks, logs, does I/O or calls into the UI layer (details: `.claude/rules/engine.md`).
- Downloaded projects and modules are untrusted: parse them with limits. Native components are in-process code, not sandboxed: third-party binaries load only under the user's per-item choice of Isolated, Trusted or Blocked (`docs/decisions.md`), never silently. Never ship a GitHub token or other secret.
- Dependencies must have permissive licences (no GPL/AGPL; C.A.W. itself is Apache-2.0). Record each new one in `docs/decisions.md`.
- The owner works from Android (Galaxy S22+): every build, test and installable comes from GitHub Actions; do not assume a PC/IDE.
- Record decisions and new facts in `docs/` before ending a session, and rewrite superseded text where it stands instead of appending (details: `.claude/rules/docs.md`).

## Layout

`docs/` is the plan and memory ([docs/how-it-works.md](docs/how-it-works.md) shows how the code connects), `scripts/` holds repository tooling and `.claude/` the agent setup ([.claude/README.md](.claude/README.md)). Code: `engine/` (C++ engine and `caw` CLI), `app/` (Flutter) and `examples/` (C++ starters and example patterns). Conventions for each kind of file load from `.claude/rules/` when you touch it.

## Read in layers

Don't read every file. Go deeper only when the layer above doesn't answer, and never re-read a file already in context.

1. **Map:** the session-start hook prints the top level; `.claude/tools/tree.sh <dir>` lists a directory's files and purposes.
2. **Skill:** a repeatable task has a skill (`tasks`, `release-check`, `code-nav`, `handoff`) naming its files.
3. **Graphify** for orientation across files: `.claude/tools/graph.sh query "<keywords>"`, `explain "<name>"`, `affected "<name>"` (the `code-nav` skill).
4. **Serena** for Dart and C++ symbols (overview, bodies, references, symbol edits) instead of whole files (`.claude/README.md`).
5. **File:** open only what those named, with Grep or Read `offset`/`limit`.

## Workflow

**Roles (owner, 2026-11-09):** Claude builds the engine, using GPT's work as the baseline where it applies ([docs/decisions.md](docs/decisions.md)). Follow these rules, but stretch them or make small assumptions where that is best for the app; never change a whole direction without the owner. Fix hooks or tooling that get in the way. **Before any UI work, ask the owner how it should look.**


One-file changes: just do them. Every file (code, notes, Claude config) has one purpose; change only the files the task needs. Independent review goes to an agent in `.claude/agents/` (`architect` before structural changes, the reviewers after), asking for findings only. Changes across areas: the saved workflow `change` (plan, build in parallel on disjoint files, verify, update docs; never commits).

**Parallel by default.** Independent tool calls go in one message. Spawn subagents only for several sizeable independent parts or an independent review; do small or single-area work inline. Parallel subagents work on disjoint files, each in a worktree from the current branch (`git worktree add -b <name> .claude/worktrees/<name> HEAD`), briefed with what you already know (changed files, findings, checks and results) so they don't re-explore.

## Context

Keep context while it helps; clean up only at a task boundary (task done, PR opened or merged, before `/clear`) or when context is crowded. Drop the superseded (stale file reads, re-run check outputs, finished subtasks). Carry into any compaction or summary: the owner's requirements and decisions, security constraints, unresolved issues, verified results (with the command that showed them), branch and next step. Multi-step task at a boundary: the `handoff` skill. A handoff is never the only copy of a requirement or decision (those go in `docs/` or Issues first).

## Checking changes

Run `node scripts/docs-test.js` after touching any note, `README.md`, `CLAUDE.md` or `.claude/`. Before calling a change ready, run the `release-check` skill. CI (`.github/workflows/docs.yml`) runs the same checks on Main and every pull request. Engine: build `engine/` with CMake and run `caw_tests` (commands in [docs/engine.md](docs/engine.md); golden hashes change only with an intended sound change: `--update-golden`). App: `flutter analyze` and `flutter test` in `app/` (`CAW_LIB=<built libcaw.so>` adds the engine integration test). CI (`engine.yml`, `app.yml`) runs both.

## Git

Develop on the branch the session names. Put `Closes #N` in pull requests that finish an issue.
