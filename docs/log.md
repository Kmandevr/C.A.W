---
title: Log
summary: Dated history of changes, newest first.
updated: 2026-10-28
---

# Log

Newest first.

- 2026-10-28: v2 step 3a built (owner's priority): text note patterns that any generator plays through 8 voices, with chords, off-grid notes, probability, ratchets and slide; a Pattern picker per layer; new Acid synth, Acid line and Chords templates ([engine](engine.md#patterns), [app](app.md)).

- 2026-10-28: v2 step 2 built: the standard library (69 documented built-ins, `drum`/`synth`/`util` libraries in the module language, project library modules, project key for music helpers), `caw docs` generating [library](library.md) and [agent guide](agent-guide.md) checked in CI, and the app's Library sheet and completion ([engine](engine.md#built-ins-and-libraries), [app](app.md)). After review: budgets for function expansion and project memory, lazy clearing of effect buffers, NaN-safe music helpers, and a clashing library now fails alone.

- 2026-10-28: v2 step 1 built: `fn` functions, rich params (step, tips, toggles, dropdowns, headers, doc comments), project `global`s, and `export`/`module.name` sharing between layers in dependency order. The app shows grouped Controls and Project controls; templates gained tips and `kick.env`. Templates sound unchanged (golden hashes equal).

- 2026-10-28: Owner asked for a documented standard library (envelopes, connectors, MIDI and more); planned for v2 with generated docs in four places ([decisions](decisions.md)).

- 2026-10-28: Owner set the direction: a light, easy halfway DAW without recording. Researched layouts and interactions; proposal in the new [UI design](ui.md) note, then refined with the owner's answers (orientation, keyboard-only PC use, library, controls-first sounds).

- 2026-10-28: Owner asked for Unity-style variables and a pattern (MIDI) builder, planned for v2 with the house synth ([decisions](decisions.md)); vision, architecture and roadmap updated. PR #2 (v1) merged to `main`. A second round of answers settled the pattern details: kit routing, note extras, curved notes, MIDI 2.0 note model, scenes in v2.

- 2026-10-28: v1 built: the C++ engine (`engine/`, [engine](engine.md)), the Flutter app for Android and Windows (`app/`, [app](app.md)), seven starter modules (`examples/`), and CI for engine tests (Linux x64 and Arm64, Windows, sanitizers) and app builds (APK, Windows). Build choices are in [decisions](decisions.md); architecture and roadmap now say what is built.

- 2026-10-28: Owner is making the repository public for free CI with the licence unchanged ([decisions](decisions.md)); proprietary `LICENSE` added and named in the README.

- 2026-10-28: Owner named C.A.W "Code Auditioning Workspace", with a crow logo ([decisions](decisions.md)); name question closed.

- 2026-10-28: Owner set the v1 scope in a round of questions ([decisions](decisions.md)); roadmap rewritten around v1 (Builder, Arranger, Exporter; Android and Windows) and v2 (house synth, MIDI); vision gained the layout and neon look; architecture stages renamed to match.

- 2026-10-28: Owner asked for synthesis, MIDI and user-friendly musical helpers ([decisions](decisions.md)); architecture gained the section, Milestone 1 gained exact-length musical loops, Stage 2 gained synthesis and MIDI.

- 2026-10-28: Owner added synth, wavetable and sample output as a core capability ([decisions](decisions.md)); architecture gained voice mode and the export formats, roadmap Stage 2 includes them.

- 2026-10-28: Flutter confirmed and the bit-exact, repeatable-chaos rules added to the architecture ([decisions](decisions.md)); the Flutter open question closed.

- 2026-10-28: Owner chose C++20 for the engine, a possible VST3/CLAP plugin and fully standalone builds; C.A.W is independent of AutoStacc ([decisions](decisions.md)). Architecture gained the one-core-three-hosts engine shape and the ready-made building blocks table.

- 2026-10-28: Owner set the targets: every platform, Android first on a Galaxy S22+ ([decisions](decisions.md)). Architecture, roadmap and vision rewritten for Flutter + miniaudio + the portable engine (Flutter awaits confirmation). iOS distribution added as an open question. Rules, agents and skills made platform-neutral (`android.md` rule became `app.md`).

- 2026-10-28: Owner decided the app is sold only through AutoStacc and is a sample-making tool until then ([decisions](decisions.md)); licence question closed, Play Store items replaced with AutoStacc-only selling, purchase delivery added as an open question. `main` branch pushed.

- 2026-10-28: Repository set up for agent work, adapted from AutoStacc ([decisions](decisions.md)): `CLAUDE.md`, `.claude/` (tools, hooks, rules, skills, agents, workflow), Serena and Graphify config, `scripts/docs-test.js`, GitHub issue and PR templates, CODEOWNERS, Dependabot and the docs CI. Docs moved into a vault with frontmatter and an index; the owner's brief became [vision](vision.md); open questions moved to its register.
- 2026-10-28: First assessment written: [architecture](architecture.md) and [roadmap](roadmap.md). The repository was empty.
