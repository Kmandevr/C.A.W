# C.A.W

An experimental, code-driven glitch-sound instrument for Android: bytebeat,
procedural synthesis, raw byte/audio mangling and compact sequencing. Code is
the source of truth, audio renders locally on the phone, and WAV export feeds
Reaper.

**Status:** planning. There's no application code yet.

| Doc | What it covers |
| --- | --- |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | Stack, audio engine, code execution, module format, GitHub sync, AI workflow, risks |
| [docs/ROADMAP.md](docs/ROADMAP.md) | Staged plan and the concrete first milestone |

## Principles (short form)

1. Code is the source of truth.
2. Edit, then hear it right away.
3. All audio runs on the device and works offline.
4. Modules are reusable across projects.
5. Any AI agent can create sounds by editing plain files in git. No agent has to tap through the UI.
6. No lock-in to one AI provider or one engine.
7. Licensing, security and user data ownership are considered from day one.
