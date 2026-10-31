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
| `docs/` | Project memory and plans: [vision](docs/vision.md), [current architecture](docs/architecture.md), [modular adaptive engine blueprint](docs/engine-next.md), [engine integration contract](docs/engine-integration.md), [native module SDK](docs/native-module-sdk.md), [engine build status](docs/engine-build-status.md), [roadmap](docs/roadmap.md), [decisions](docs/decisions.md), [log](docs/log.md) |
| `scripts/` | Repository tooling. `node scripts/docs-test.js` checks that the docs match the repository |
| `.github/` | Issue and PR templates, CODEOWNERS, Dependabot, and the workflows below |
| `.claude/` | Setup for Claude Code sessions: rules, skills, review agents, hooks ([.claude/README.md](.claude/README.md)) |
| `CLAUDE.md` | Instructions every AI session follows |

Workflows:
- `.github/workflows/docs.yml`: runs the docs guard and repo hygiene checks on every push and pull request.
- `.github/workflows/app.yml`: runs Dart analysis, Dart tests, Android APK and Windows app as independent jobs. Flutter SDK and Dart packages are cached; native test builds use ccache; Dart tests run with bounded parallelism. The APK (`caw-android-apk`) and Windows app (`caw-windows`) are downloadable artifacts.
- `.github/workflows/engine.yml`: builds and tests Linux x64, Linux Arm64, Windows x64 and Linux sanitizers in a four-job matrix. Linux native builds cache compiler outputs; CTest runs the native suite in four deterministic parallel shards. The Linux x64 job also checks generated function docs and renders each example except patterns (they need a sound to play).
- `.github/workflows/clear-status-on-close.yml`: removes `status:` labels when an issue closes.

Each workflow cancels its own superseded run for the same pull request or branch, so checks for an older commit do not continue consuming runner time. The three workflows remain independent and can run at the same time.
## Working on it

Tasks and bugs are GitHub Issues. Security problems: [SECURITY.md](SECURITY.md).

## Licence

Proprietary: the source is visible, but all rights are reserved ([LICENSE](LICENSE)).
