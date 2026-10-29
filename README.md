<!-- covers: [scripts/, .github/] -->
# C.A.W — Code Auditioning Workspace

An experimental, code-driven glitch-sound instrument for Android, iOS, Windows, macOS and Linux: bytebeat, procedural synthesis, raw byte and audio mangling, and compact sequencing. Code is the source of truth, audio renders locally on the phone, and WAV export feeds Reaper.

**Status:** v1 is built ([docs/roadmap.md](docs/roadmap.md)): make sounds in code, stack them into loops and export WAVs, on Android and Windows. Installable builds are artifacts of the **App** workflow runs.

## Where things are

| Path | What it is |
| --- | --- |
| `engine/` | The C++20 sound engine: module language, standard library, mixer, WAV exports, C API, the `caw` CLI and tests ([reference](docs/engine.md), [functions](docs/library.md), [agent guide](docs/agent-guide.md)) |
| `app/` | The Flutter app for Android and Windows: Sounds, Tracks and Export ([app](docs/app.md)) |
| `examples/` | Starter sound modules (`.caw`), built into the engine as templates |
| `docs/` | The plan and project memory (an Obsidian vault): [vision](docs/vision.md), [architecture](docs/architecture.md), [roadmap](docs/roadmap.md), [decisions](docs/decisions.md), [log](docs/log.md) |
| `scripts/` | Repository tooling. `node scripts/docs-test.js` checks that the docs match the repository |
| `.github/` | Issue and PR templates, CODEOWNERS, Dependabot, and the workflows below |
| `.claude/` | Setup for Claude Code sessions: rules, skills, review agents, hooks ([.claude/README.md](.claude/README.md)) |
| `CLAUDE.md` | Instructions every AI session follows |

Workflows:
- `.github/workflows/docs.yml`: runs the docs guard and repo hygiene checks on every push and pull request.
- `.github/workflows/app.yml`: Dart checks and tests, then the Android APK (`caw-android-apk`) and the Windows app (`caw-windows`) as downloadable artifacts.
- `.github/workflows/engine.yml`: builds the engine and runs its tests and golden renders on Linux (x64 and Arm64) and Windows, plus a sanitizer run, checks that the generated function docs are current, and renders each example except patterns (they need a sound to play them).
- `.github/workflows/clear-status-on-close.yml`: removes `status:` labels when an issue closes.

## Working on it

Tasks and bugs are GitHub Issues. Security problems: [SECURITY.md](SECURITY.md).

## Licence

Proprietary: the source is visible, but all rights are reserved ([LICENSE](LICENSE)).
