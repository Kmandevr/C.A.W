<!-- covers: [engine/, app/, examples/, docs/, scripts/, .github/] -->
# C.A.W — Code Auditioning Workspace

An experimental, code-driven sound-design and music workspace. The current Flutter app ships Android and Windows builds; the portable C++20 engine and CLI are also built/tested on Linux and Windows CI targets. The app opens straight into your last project and currently provides eight workspaces (docked panels, compact on phones) for code-based sound creation, pattern editing (a piano roll whose notes stretch from either end and whose notes and curves snap to a time and value grid, and that sound while you place, move or bend them), arrangement (songs of any length; the 64-bar limit went in Foundation F7.2, and the engine takes more than 64 layers within its memory budget since F7.3), mixing (Reaper-style channel strips with chain slots and dB peak meters per track, folder and master), inspection (parameter values set by drag or by typing), automation, file management and export. Audio runs locally; WAV and MIDI exports support handoff to other music tools.

Project automation supports song-time lanes for module parameters and shared globals, with any number of lanes and points; track volume and pan keep their existing lanes.

**Current status:** Android and Windows app builds are produced by CI. The app has eight workspaces, but not every planned capability is implemented. See [App](docs/app.md) for shipped behavior, [Engine status](docs/engine-build-status.md) for native implementation boundaries, the [engine blueprint](docs/engine-next.md) for the target engine design, and the [permanent roadmap](docs/roadmap.md) for planned work and sequencing: the engine graph Foundation stage first (in progress: one graph now runs playback and export, with every module of a track as its own node and typed sidechain, modulation, control and event/MIDI ports; one parameter model now resolves manual values, automation, modulation and MIDI CC mappings; resource budgets are partly done, with layer growth merged unfinished (#94); the remaining engine work is paused while the UI is redesigned), then Stages 0–7, then the first release. The UI redesign (the arrangement as home, docking panels, a Unity-like code workspace) is specified in the [UI plan](docs/ui-plan.md); its first step (shared motion rules and settings, a glass look, design tokens, a shared toolbar, screenshot tests) is built, and the docking shell is under way.

## Where things are

| Path | What it is |
| --- | --- |
| `engine/` | The C++20 sound engine: module language, standard library, mixer, WAV exports, C API, the `caw` CLI and tests ([reference](docs/engine.md), [functions](docs/library.md), [agent guide](docs/agent-guide.md)) |
| `app/` | Flutter app for Android and Windows with eight workspaces ([app](docs/app.md)) |
| `examples/` | Starter sound modules (`.caw`), built into the engine as templates |
| `docs/` | Project documentation: current app/engine facts, decisions, architecture and the permanent roadmap ([index](docs/index.md)) |
| `scripts/` | Repository tooling. `node scripts/docs-test.js` checks that the docs match the repository; `agent-run.js` runs a chat agent's requested commands and writes its report, `agent-context.js` its start file |
| `.github/` | Issue and PR templates, CODEOWNERS, Dependabot, and the workflows below |
| `.claude/` | Setup for Claude Code sessions: rules, skills, review agents, and hooks that make Graphify and Serena the default way to navigate code ([.claude/README.md](.claude/README.md)) |
| `CLAUDE.md` | Instructions every AI session follows |

Workflows:
- `.github/workflows/docs.yml`: runs the docs guard and repo hygiene checks on every push (except `gpt/**`) and pull request; superseded runs are cancelled per branch/PR.
- `.github/workflows/app.yml`: runs Dart analysis, Dart tests, Android APK and Windows app as independent jobs. Flutter SDK and Dart packages are cached; native test builds use ccache; Dart tests run with bounded parallelism. The APK (`caw-android-apk`) and Windows app (`caw-windows`) are downloadable artifacts; superseded runs are cancelled.
- `.github/workflows/engine.yml`: on every push (except `gpt/**`) and pull request, builds and tests Linux x64, Linux Arm64, Windows x64 and Linux sanitizers in a four-job matrix. Linux native builds cache compiler outputs; CTest runs the native suite in four deterministic parallel shards. The Linux x64 job also checks generated function docs and renders each example except patterns (they need a sound to play); superseded runs are cancelled.
- `.github/workflows/quick-check.yml`: the chat-agent route. Pushes to `gpt/**` branches run the commands named by `run:` lines in the commit message (targeted tests, sanitizer runs, builds, renders, widget-test screenshots, git diff/log/show/blame, search and Graphify; `scripts/agent-run.js`) or, with none, the docs guard, a Linux x64 engine build and tests, the example checks and (when `app/` changed) Dart analysis and tests. No app builds. It writes one short report per branch to `quick-check/<branch with / as -->.md` on the `agent-results` branch (RUNNING as soon as a run starts, with `quick-check/INDEX.md` listing every branch; screenshots under `screens/`) ([AGENTS.md](AGENTS.md)). Full CI runs once the branch opens a pull request.
- `.github/workflows/agent-context.yml`: on pushes to `Main` that change `AGENTS.md`, `CLAUDE.md`, `docs/vision.md` or a rule, rebuilds `START.md` on `agent-results`: one file bundling everything a chat agent reads first (`scripts/agent-context.js`).
- `.github/workflows/publish-agent-results.yml`: reusable step the two workflows above use to commit their file to `agent-results`; it is the only job with write access and never runs branch code.
- `.github/workflows/clear-status-on-close.yml`: removes `status:` labels when an issue closes.

## Working on it

Tasks and bugs are GitHub Issues. Security problems: [SECURITY.md](SECURITY.md).

## Licence

Proprietary: the source is visible, but all rights are reserved ([LICENSE](LICENSE)).
