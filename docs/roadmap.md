---
title: Roadmap
summary: Staged plan from the first phone-testable bytebeat instrument to commercial release, with Milestone 1's scope and acceptance test.
updated: 2026-10-28
---

# Roadmap

How the plan in [architecture](architecture.md) gets built. Each stage ends with something you can install and use. Stages are provisional.

## Milestone 1 — "Bytebeat pocket instrument" (Stage 1)

**Goal:** type a formula on the phone, hear it right away, and export a WAV that drops into Reaper.

### In scope

- Android APK built by GitHub Actions (Flutter app plus the C++ engine). You install it on the S22+ from the run's artifact, with no PC needed. CI also builds the Linux desktop app, which costs little and proves the cross-platform setup from day one.
- One screen:
  - Code editor (monospace, basic highlighting, symbol key row)
  - **Play / Stop / Restart (t=0)**
  - Formula rate (8k / 11k / 22k / 32k / 44.1k)
  - Byte or float output mode
  - Volume
  - One-line error display
  - Simple oscilloscope
- C++ engine: bytebeat expression compiler + VM, played through miniaudio. **Hot-swaps on Run without stopping audio**, with a short crossfade.
- Safety limiter, NaN guard, cost guard.
- Save / load / duplicate `.caw` files in app storage, plus 5–10 bundled original examples.
- **Export WAV:** choose a length, 44.1 or 48 kHz, 24-bit or 32-bit float. You choose where it's saved through the system file picker (e.g. Drive or Downloads).
- `caw render` Linux CLI. CI renders every example and checks that the output hasn't changed.

### Not in scope yet

Modules, parameters, GitHub sync, sequencer, spectrum display, audio import.

### Acceptance test on your phone

1. Install the APK from CI. Open it, tap Play on an example, and sound starts with no audible delay.
2. Edit the formula and tap Run. The sound changes without a click or dropout.
3. Type a broken formula. You get a clear error, and the previous sound keeps playing.
4. Type something absurdly expensive. The app fades out and warns you instead of crashing or stuttering.
5. Export 30 s to WAV. It opens in Reaper and sounds identical to playback.
6. Close the app, reopen it, and your saved file is still there.

### Build order (each step is one reviewable PR)

1. Project skeleton: Flutter app and CMake engine, CI that builds the Android APK and the Linux app. (Repository tooling, docs and agent setup are done.)
2. Engine core and CLI: lexer → parser → compiler → VM, WAV writer, golden tests (Linux only).
3. Audio output: the engine's C API over `dart:ffi`, a miniaudio stream, program hot-swap, limiter.
4. UI: editor, transport, errors, scope.
5. Files and WAV export.

## Stage 2 — Modular sound library

Module format v1 (header + code), `param` declarations that generate sliders, `use` imports, stateful DSP built-ins (envelopes, filters, delay, noise, waveshaper, bitcrush), procedural instruments (e.g. a kick built from pitch decay, sine body, distortion and a noise click), and hot reload. Includes a 1-day NKIDO/Cedar spike.

## Stage 3 — GitHub integration

GitHub App with device-flow sign-in, a library repo template, tree-diff sync, atomic commits, conflict branches, and branch/PR source picker.

## Stage 4 — AI-assisted editing

`AGENTS.md` language guide in the library repo, library CI running `caw check` / `caw render` with preview WAVs on PRs, and in-app preview, merge and revert.

## Stage 4b — More platforms and plugins

Windows and macOS desktop builds (handy beside Reaper), then iOS once its distribution question is settled. The engine and UI are shared, so the work is packaging, signing, file access and per-platform audio testing. A CLAP plugin of the engine, wrapped into VST3 and AU by clap-wrapper, follows the desktop builds.

## Stage 5 — Advanced instrument

Sequencing mini-language with a shared clock and polyrhythms, audio import with nondestructive byte/bit mangling chains (originals are never modified), spectrum display, performance work, and preparing to sell through AutoStacc (signed release builds, privacy policy, install steps, how a purchase unlocks the app).

## Before Milestone 1 starts

The owner confirms Flutter (the open question in [vision](vision.md#open-questions) that blocks step 1).
