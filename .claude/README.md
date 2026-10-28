# .claude/ tooling

Adapted from the AutoStacc repository's setup. `tools/`, `hooks/` and `workflows/` don't mention this project, so they're kept identical to AutoStacc's and can be refreshed from there. `skills/`, `agents/`, `rules/` and `.serena/` are specific to C.A.W.

| Piece | Loads | Purpose |
| --- | --- | --- |
| `hooks/session-start.sh` | every session | Prints the branch, last 5 commits, uncommitted count, the newest `docs/log.md` lines, `.claude/handoff.md` if one exists, and the brief repo map. Installs Serena, and refreshes the Graphify graph in the background. Runs again after a compaction. |
| `hooks/docs-reminder.sh` | when Claude stops (`Stop` hook) | Runs `node scripts/docs-test.js --stale`. When this branch changed files a note covers but not the note, it asks Claude once to check those notes before finishing. |
| `tools/tree.sh` | on call | Repo map built from each file's own purpose line. `<dir>` expands one directory, `--all` lists every file. A directory's purpose is the first line of its `.purpose` file; a `.caw` module's is its `summary:`. |
| `tools/graph.sh` | on call | Single entry to [Graphify](https://github.com/Graphify-Labs/graphify) (project and file level). Installs it and rebuilds the graph only when files were added, edited or deleted. |
| `tools/serena.sh`, `.mcp.json` | when Serena's tools are used | Starts the [Serena](https://github.com/oraios/serena) MCP server (symbol level). Config: `.serena/project.yml`, with the Kotlin and C++ language servers; its file, shell, memory and onboarding tools are off. |
| `tools/serena-hook.sh` | on Read/Grep, session end | Runs Serena's `remind` and `cleanup` hooks. Does nothing if Serena isn't installed. |
| `skills/tasks` | description every session, body when invoked | Find, claim, work and finish tasks through GitHub Issues and labels. The only task system. |
| `skills/release-check` | same | Final check before calling a change ready: docs guard, repo hygiene (`check.sh`), diff scope, and reviewers when the diff calls for them. |
| `skills/code-nav` | same | Using Graphify and Serena together, with `check.sh`, a self-test for both. |
| `skills/handoff` | same | Writes `.claude/handoff.md`, a short snapshot to resume a multi-step task from. `check.sh` keeps every line of `must-keep.txt` in place and CLAUDE.md within its word budget. |
| `agents/*.md` | description every session, body in the subagent's own context | Read-only reviewers that return findings only: `architect` (placement and boundaries), `code-reviewer` (defects), `audio-reviewer` (real-time safety, DSP correctness, determinism), `security-reviewer` (untrusted modules, auth, secrets, Android permissions). |
| `rules/*.md` | when matching files are touched | Conventions scoped by `paths:` globs: `claude`, `docs`, `scripts`, `ci`, `engine`, `android`, `modules`. |
| `workflows/change.js` | on call | Multi-agent plan, parallel build, parallel verify, then docs. Takes `args: { task, agents? }` and reads the project's checks from `CLAUDE.md`. Never commits. |
| `settings.json` | every session | Allow rules for the tools and checks above, hook registration, `enabledMcpjsonServers`, `MCP_TIMEOUT`. |

## Where instructions live

There's one home for each kind of instruction; the others point to it.

| Kind | Home |
| --- | --- |
| Project identity, global rules, how to work | `CLAUDE.md` |
| Conventions for certain files | `rules/`, loaded when matching files are touched |
| Repeatable procedures | `skills/` |
| Independent review, in its own context | `agents/` |
| Product direction, plan, decisions, history | `docs/` |
| Tasks and bugs | GitHub Issues |
| Project-wide map and relationships | Graphify through `tools/graph.sh` |
| Symbols and references | Serena |

## Graphify and Serena

They answer different questions, so don't use both for the same one.

| | Graphify | Serena |
| --- | --- | --- |
| Level | Project and file | Symbol |
| Use for | "What is in this repo, what depends on what, what breaks if I change this module?" | "Where is `compile` defined, who calls it, show just that function, rename it everywhere" |
| Tools | `.claude/tools/graph.sh` (`query`, `explain`, `affected`; no arguments prints the overview) | One tool, `serena_repl` (session id from `initial_instructions`), with `s.lsp.get_symbols_overview`, `find_symbol`, `find_referencing_symbols`, `rename_symbol`, `get_diagnostics_for_file` and `s.edit.replace_symbol_body`, `insert_before_symbol`, `insert_after_symbol` |
| Not for | Reading or editing code | Orientation, searching docs, plain text edits, shell commands (use the map, Grep, Edit and `docs/`) |

- Until `engine/` and `android/` exist, the graph holds only Markdown headings and scripts, and Serena has no symbols to index. Both start paying off with the first code.
- The project's memory stays in `docs/`. Serena's own memory and onboarding tools are off, so there's no second source of truth.
- `.mcp.json` registers Serena as a project-scoped MCP server; `enabledMcpjsonServers` in `settings.json` approves it.
- Graphify and Serena install through [uv](https://docs.astral.sh/uv/).
