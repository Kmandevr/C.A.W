---
title: Roadmap
summary: Staged plan from the bare-bones v1 (build sounds, stack them into loops, export) to commercial release, with v1's scope, acceptance test and build order.
updated: 2026-10-28
---

# Roadmap

How the plan in [architecture](architecture.md) gets built. Each stage ends with something you can install and use. Scope set by the owner on 2026-10-28 ([decisions](decisions.md)).

## v1 — Build, arrange, export

**Goal:** build sounds and effects in code, stack any number of them into a loop at your BPM, and export loops, one-shots and wavetables that drop straight into Reaper.

### Platforms

The Android app for the S22+, and a Windows app beside Reaper. Both are Flutter apps around the same C++ engine, and both are built by GitHub Actions. CI also builds the engine CLI on Linux for tests.

### Three areas

1. **Builder: make modules.** A module is a file of code, either a **generator** (makes sound) or an **effect** (processes the sound coming into it). The screen has:
   - code editor with highlighting, the symbol key row and a one-line error display
   - scope
   - auto-generated sliders for each `param`
   - Run, which hot-swaps the module without stopping audio
   - starter templates: bytebeat loop, kick, bass, hats, glitch fx, and bit-crush and fold effects
2. **Arranger: use modules (loop stack).** Any number of layers, each one a generator followed by a chain of effects.
   - Each layer loops at **its own length** in steps or bars against the shared BPM, so polyrhythms come free.
   - Per layer: volume, pan, mute and solo. A master safety limiter sits on the output.
   - Project settings: BPM (with tap), time signature, project loop length, key, and seed.
   - A CPU meter. When the phone runs out of headroom, the newest layer is flagged instead of letting audio glitch.
3. **Exporter:**
   - **loop WAV:** exact length at the BPM, with loop points
   - **free-length WAV:** any number of seconds
   - **one-shot WAV:** one layer until it goes silent, end trimmed
   - **wavetable:** 2048-sample single-cycle frames, sweeping a `param`, for Serum/Vital-style synths

   Everything exports at 44.1 or 48 kHz, 24-bit or 32-bit float. You pick where files are saved through the system file picker.

### Language in v1

- bytebeat semantics and bit tools ([architecture](architecture.md#bits-and-determinism))
- `let`, `param`, and `bpm`, `beat`, `bar`, `step`, `pos`
- synth basics: sine, saw, square and triangle oscillators, noise, one envelope, one multimode filter
- `in`, the incoming signal, so a module can work as an effect

### Look

Neon on near-black: neon green, pink, yellow and blue (owner), each layer in one neon colour.

### Not in v1

- the house-built synth, notes, on-screen keys and MIDI (the next version)
- multisamples, stems and MIDI export
- GitHub sync and AI library editing
- the plugin and other platforms
- audio import
- sends and advanced routing beyond the current nested folder buses

### Acceptance test

1. Install both apps from CI. Open a template and tap Play: sound starts with no audible delay.
2. Edit code and tap Run. The sound changes without a click or dropout. Broken code gives a clear error and the old sound keeps playing.
3. Stack layers at different lengths (for example a 3-bar layer against a 4-bar one). They stay in time at 140 BPM.
4. Add a bit-crush effect module to one layer. Only that layer changes.
5. Pile on layers until the phone runs out of headroom. You get a warning, not stuttering or a crash.
6. Export a 4-bar loop at 140 BPM. It lines up with Reaper's grid, loops without a click, and matches playback bit for bit. A one-shot ends cleanly. A wavetable loads into a wavetable synth.
7. Close and reopen the app: the project, modules and settings are all there.

### Status

**[Fact]** All seven build steps are done (2026-10-28):
1. skeleton and CI
2. engine core and CLI
3. synth basics, effects and the mixer
4. audio output and hot swap
5. Builder
6. Arranger
7. Exporter and project files

CI runs the engine tests and golden renders, and checks the acceptance test's timing claims (layer lengths at 140 BPM, exact loop length, export matching playback). Steps 1, 2 and 5 of the acceptance test, and how exports load in Reaper and a wavetable synth, need the owner on the S22+ and on Windows. The engine is described in [engine](engine.md), and the app in [app](app.md).

## v2 — Variables, patterns, house synth and MIDI

Scope set by the owner on 2026-10-28 ([decisions](decisions.md)); the design is in [architecture](architecture.md#variables-and-patterns-proposal).

- **Unity-style variables:**
  - local `param`s with steps, tooltips, dropdowns, toggles and headers
  - project `global`s in a Project Controls panel
  - `export`ed signals other modules read (sidechain)
  - **[Fact]** Built (step 1): params, globals, exports and functions, with the app's Controls and Project controls panels.
- **Automation lanes:** volume and pan automation are now supported on tracks and folder buses; automation for globals and module parameters remains future work.
- **Pattern builder:**
  - **[Fact]** Built first (step 3a, the owner's priority): text patterns that any generator plays through voices, with chords, off-grid notes, probability, ratchets and slide ([engine](engine.md#patterns)).
  - single-sound and kit patterns, 1 step to 64 bars long
  - a drum grid and a piano roll, with snap (1/16, 1/32, triplets) or free timing
  - notes with probability, ratchets, slide and custom values
  - curves on notes, drawn freehand and then refined with handles: bent pitch shows as a curved note
  - chord stamping, and generator buttons (Euclid, random in key, arpeggiate, humanize)
  - procedural pattern code with optional per-repeat variation, and Freeze
  - drag a pattern onto any layer
- **Scenes/session grid:** retired in favour of the arrangement timeline; no alternate launcher view is planned.
- **Standard library** ([architecture](architecture.md#standard-library-and-connectors-proposal)):
  - envelopes and LFOs, filters and effects, MIDI and music theory, glitch and bit tools
  - user `fn` functions
  - docs generated into `docs/`, an agent guide, in-app help and inspector tips, checked in CI
  - **[Fact]** Built (step 2): 69 documented built-in functions in ten categories, 12 more in the `drum`, `synth` and `util` libraries, project library modules, the [function library](library.md) and [agent guide](agent-guide.md) checked in CI, and the app's Library sheet (F1) and completion. MIDI functions come with MIDI ports.
- **Connectors:** sidechain, modulation links (LFOs and envelopes onto any param), and MIDI ports.
- **A UI for a light halfway DAW** ([UI design](ui.md)):
  - an arrangement-first timeline with reusable MIDI clips, nested folder buses, a separate mixer and track automation
  - one gesture vocabulary on both phone and desktop, and undo/redo
  - painted grids, with the CPU and RAM budgets
- **Notes stored the MIDI 2.0 way.** `.mid` import and MPE export come later; DAW export isn't a priority yet.
- **The house-built synth:** play any generator you built as an instrument (voice mode, [architecture](architecture.md#instruments-wavetables-and-samples)). Its voice pool also plays chords from patterns.
- on-screen keys
- USB/Bluetooth MIDI: notes, CC learn, clock, MIDI file import and export
- note and scale helpers
- multisample (WAV + SFZ) and stems export
- more synthesis built-ins ([architecture](architecture.md#synthesis-midi-and-musical-helpers))
- a 1-day NKIDO/Cedar spike

## Stage 3 — GitHub integration

GitHub App with device-flow sign-in, a library repo template, tree-diff sync, atomic commits, conflict branches, and a branch/PR source picker.

## Stage 4 — AI-assisted editing

`AGENTS.md` language guide in the library repo, library CI running `caw check` / `caw render` with preview WAVs on PRs, and in-app preview, merge and revert.

## Stage 4b — More platforms and plugins

macOS and Linux desktop apps, then iOS once its distribution question is settled. A CLAP plugin of the engine, wrapped into VST3 and AU by clap-wrapper.

## Stage 5 — Advanced instrument

- timeline arranger foundation is now in v2; remaining work includes more editing polish, clip-following automation and plugin/global parameter automation
- the sequencing mini-language
- audio import with nondestructive byte/bit mangling chains (originals are never modified)
- sends and buses
- free module patching (modular-style)
- spectrum display
- performance work
- preparing to sell through AutoStacc: signed release builds, privacy policy, install steps, and how a purchase unlocks the app
