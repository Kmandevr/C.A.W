---
title: Log
summary: Dated history of changes, newest first.
updated: 2026-10-29
---

# Log

Newest first.

- 2026-10-29: Curve tool for the velocity and chance lanes (points and bendable segments; part of #11).
- 2026-10-29: Code editor layout in Settings (part of #10): key row, completion chips, which buttons and the scope show, Run bar position, Controls above the code, compact and foldable controls. Syntax for new controls and for curves proposed on #10 and #11 for the owner.
- 2026-10-29: Roll customisation (#9): Settings → Piano roll (sizes, grid strength, key names, grab zone, hold time, empty-grid drag), a toolbar you edit (actions and macros), and the generators (euclid, random in key, arpeggiate, humanize, chord stamp, reverse, invert pitch).
- 2026-10-29: The piano roll works inline in the Builder (it claims its touches; one finger on empty grid scrolls, a tap draws). New [how it works](how-it-works.md) note for agents. Owner's plan for roll, editor and curve work in [decisions](decisions.md).

- 2026-10-28: Light mode (owner OK), auto-update while typing, the key router (keymaps, Vim, counts, macros, action list, code-editor Vim), roll extras panel, lanes, triplets and MIDI import/export buttons; engine `voices` limit ([app](app.md)).
- 2026-10-28: Piano roll and drum grid built for pattern modules: adaptive grid, key rows, velocity lane, draw/select/erase, the owner's WASD/Q/E keys ([app](app.md)).
- 2026-10-28: Performance audit, app part. Each keystroke or slider step rebuilt about 3,520 widgets; now 10 and 169 (measured). The meter poll ran every frame even when stopped; now nothing runs when stopped or hidden, and the audio device closes after 30 s idle ([performance](performance.md)).

- 2026-10-28: Owner's performance audit, engine part. `caw_bench` plus callgrind found the bitwise and `%` conversions and a per-layer solo scan; exact fast paths cut 10–20% of instructions with output unchanged ([performance](performance.md)). Merged MIDI file import/export, the app's pattern model, the actions/keys/Vim core, and themes, fonts, density, settings, the startup screen and blank modules.

- 2026-10-28: Building the go'd plan. Engine live editing done: code swaps keep the running state of unchanged calls, can wait for the next beat or bar, and pattern edits let sounding notes finish ([engine](engine.md#playback)).

- 2026-10-28: Owner asked for blank new files (with a faint hint, and templates optional) and a startup choice: continue, blank or template ([UI design](ui.md)). Still waiting for the go.

- 2026-10-28: Owner confirmed the adaptive grid reading, and asked for live editing while playing: code auto-update with a delay you can set and an off switch, swap timing you can choose, pattern edits from a note's next play, and sound state carried across code swaps ([architecture](architecture.md#live-editing-while-playing-proposal)). Still waiting for the go.

- 2026-10-28: Owner set the adaptive grid: the chosen resolution (1 down to 1/128, or off) is its finest level and the snap, Shift-drag ignores it, and tapping keeps 48 dp cells ([UI design](ui.md#editors)). Still waiting for the go.

- 2026-10-28: Owner answered the remaining key questions (WASD in the code editor's Vim mode, Alt+Q to record, Ctrl+1/2/3 for areas, the cursor keys, the phone toolbar); updated [actions](actions.md). Still waiting for the go.

- 2026-10-28: Owner settled the visual details: calm neon, custom themes, a bundled mono font, a density switch, and a mode badge with key hints and toasts ([UI design](ui.md)). Still waiting for the go.

- 2026-10-28: Owner asked for Vim-style control across the app (modes, counts, `:` commands, `.` and recorded macros, optional Vim in the code editor); added to the [actions](actions.md) draft. Still waiting for the go.

- 2026-10-28: Owner asked for Reaper-style customisable keys and macros; drafted the action catalogue with default keys in [actions](actions.md) for review. Still waiting for the go.

- 2026-10-28: Owner set the roll's keys (WASD, Q/E, Shift and Ctrl), the note look and the MIDI 2.0 scope (internal plus files). Checked platform MIDI 2.0 support ([architecture](architecture.md#variables-and-patterns-proposal)). Still waiting for the go.

- 2026-10-28: Owner answered the pattern editor questions (piano roll and drum grid next, in today's app); recorded in [UI design](ui.md#editors). Building waits for the owner's go.

- 2026-10-28: v2 step 3a built (owner's priority): text note patterns that any generator plays through 8 voices, with chords, off-grid notes, probability, ratchets and slide; a Pattern picker per layer; new Acid synth, Acid line and Chords templates ([engine](engine.md#patterns), [app](app.md)). After the audio review: release fades for code that ignores gate, click-free voice stealing, no stuck notes on seed or tempo changes, a cap on block splits, and late-note warnings.

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
