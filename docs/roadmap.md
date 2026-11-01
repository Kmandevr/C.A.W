---
title: Roadmap
summary: Product milestones with historical v1 acceptance scope, current v2 implementation status and clearly marked future work.
updated: 2026-11-01
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
   - auto-generated sliders for each param
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
   - **wavetable:** 2048-sample single-cycle frames, sweeping a param, for Serum/Vital-style synths

   Everything exports at 44.1 or 48 kHz, 24-bit or 32-bit float. You pick where files are saved through the system file picker.

### Language in v1

- bytebeat semantics and bit tools ([architecture](architecture.md#bits-and-determinism))
- let, param, and bpm, beat, bar, step, pos
- synth basics: sine, saw, square and triangle oscillators, noise, one envelope, one multimode filter
- in, the incoming signal, so a module can work as an effect

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

Owner-approved scope originating 2026-10-28 ([decisions](decisions.md)); the current implementation ledger is [engine-build-status](engine-build-status.md). This section separates what shipped from what remains.

**[Fact] Implemented:** module params/globals/exports/functions; code-defined pattern playback; piano roll and drum grid; note expressions and lane curves; pattern generator actions; house synth patch format and playback; MIDI pattern import/export; arrangement clips; nested folders and stereo folder buses; track/folder volume-pan automation; documented function library and in-app help.

**[Fact] Partial:** MIDI 2.0 UMP decoder and bounded input queue exist, but no USB/Bluetooth device connection or live Engine voice routing. Export includes WAV loop/free-length/one-shot/wavetable and MIDI; SFZ multisample authoring and stems export are not implemented. Module/global parameter automation is not implemented. Export queue is in-memory, not persistent.

**[Not implemented]:** kit-row pattern routing and procedural code patterns/Freeze. Scenes/session launcher are retired. **[Partial]:** module/global modulation tools and export-signal sidechain ducking exist, but a general routing/modulation connection workflow is incomplete. **[Not implemented]:** USB/Bluetooth MIDI device I/O, SFZ multisample workflow and stems export. The current app-usable v2 priority is module/global automation, then SFZ and stems export, unless the owner changes it.

For exact implementation boundaries, use [App](app.md), [Engine](engine.md) and [Engine implementation status](engine-build-status.md).

## Stage 3 — GitHub integration (proposal; not implemented)

A possible future GitHub App workflow: device-flow sign-in, a library repo template, tree-diff sync, atomic commits, conflict branches and a branch/PR source picker. The current app has no GitHub library-sync/source-picker workflow; local/offline project creation and file import/export remain the supported path.

## Stage 4 — GitHub/AI-assisted editing (deferred)

The earlier proposal for GitHub library synchronization, source picking and AI-assisted editing is **not implemented** and is **not in the current product scope**. The owner has explicitly directed no in-app AI integration for now. Do not add AI generation, editing, source separation, model inference or cloud audio processing. AI coding assistants remain external development tools, not a C.A.W. feature.

## Stage 4b — More platforms and plugins (proposal; not implemented)

Potential future targets are macOS and Linux desktop apps, then iOS once its distribution question is settled. CLAP/VST3/AU builds or hosting require a real native host/SDK, platform packaging, licensing review and tests; none is currently shipped.

## Stage 5 — Advanced instrument and complete workflow

The detailed order and implementation gaps are tracked in the [core development plan and complete feature list](core-and-feature-plan.md), supported by the [music workflow feature-gap plan](music-workflow-feature-gap-plan.md). In brief: complete approved v2 commitments; finish piano-roll expression/generator tools; complete mixer routing; add basic non-destructive audio clips; build sample editing and multisample mapping; complete USB/Bluetooth MIDI connectivity; improve arrangement, automation and export; then add lightweight creative sound systems after their performance gates.

The [lightweight creative audio systems plan](lightweight-creative-audio-systems.md) remains the detailed design reference for non-AI mathematical sound, cellular patterns, waveform transformation, variation, inspection and lightweight physical models. It is a filtered proposal, not an instruction to implement every idea at once.

## Release and performance direction

- Maintain local/offline operation, phone-first usability and a shared native engine.
- Support weak hardware with low idle overhead and bounded callback work; use stronger hardware only when extra resources improve the active workload.
- Use adaptive workload planning and the existing worker pool rather than introducing parallel schedulers.
- Measure real CPU, memory, callback timing, frame time, battery/thermal behavior and audio dropouts before making performance claims.
- Complete signing, privacy/install documentation and commercial distribution readiness before release.
