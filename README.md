<!-- covers: [scripts/, .github/] -->
# C.A.W — Code Auditioning Workspace

An experimental, code-driven glitch-sound instrument for Android, iOS, Windows, macOS and Linux: bytebeat, procedural synthesis, raw byte and audio mangling, and compact sequencing. Code is the source of truth, audio renders locally on the phone, and WAV export feeds Reaper.

**Status:** planning and repository setup. There's no application code yet; v1 is defined in [docs/roadmap.md](docs/roadmap.md).

## Where things are

| Path | What it is |
| --- | --- |
| `engine/` | The C++20 sound engine: module language, mixer, WAV exports, C API, the `caw` CLI and tests ([reference](docs/engine.md)) |
| `examples/` | Starter sound modules (`.caw`), built into the engine as templates |
| `docs/` | The plan and project memory (an Obsidian vault): [vision](docs/vision.md), [architecture](docs/architecture.md), [roadmap](docs/roadmap.md), [decisions](docs/decisions.md), [log](docs/log.md) |
| `scripts/` | Repository tooling. `node scripts/docs-test.js` checks that the docs match the repository |
| `.github/` | Issue and PR templates, CODEOWNERS, Dependabot, and the workflows below |
| `.claude/` | Setup for Claude Code sessions: rules, skills, review agents, hooks ([.claude/README.md](.claude/README.md)) |
| `CLAUDE.md` | Instructions every AI session follows |

Workflows:
- `.github/workflows/docs.yml`: runs the docs guard and repo hygiene checks on every push and pull request.
- `.github/workflows/engine.yml`: builds the engine and runs its tests and golden renders on Linux (x64 and Arm64) and Windows, plus a sanitizer run.
- `.github/workflows/clear-status-on-close.yml`: removes `status:` labels when an issue closes.

## Working on it

Tasks and bugs are GitHub Issues. Security problems: [SECURITY.md](SECURITY.md).

## Licence

Proprietary: the source is visible, but all rights are reserved ([LICENSE](LICENSE)).
