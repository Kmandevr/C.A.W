---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-10-28
---

# Decisions

Newest first. A later entry wins over an earlier one on the same topic.

## 2026-10-28: A light halfway DAW (owner); UI proposal (Claude)

- **Owner:** C.A.W becomes a halfway DAW, without recording or other hard features yet. It must be easy to understand and use on phone and PC, and light on CPU and RAM.
- **Claude's proposal, based on how other apps solve this** ([UI design](ui.md)):
  - a session grid of layers × scenes, with launches queued to the loop
  - a drag-from library, and a Unity-style inspector as a bottom sheet
  - one gesture vocabulary, undo/redo always on screen, and 48 dp targets
  - a piano roll with a mode bar and two-finger navigation
  - grids drawn by painters, and meters that sleep when stopped
- **Still to confirm:** the owner hasn't confirmed this layout yet.

## 2026-10-28: Variables and patterns for v2 (owner, answering Claude's questions)

- **Variables:** all three kinds, like Unity's Inspector:
  - local `param`s with tooltips, headers, dropdowns and toggles
  - project-wide `global`s
  - `export`ed signals that other modules read
- **Pattern editor:** a drum grid and a piano roll, switchable per pattern.
- **Procedural patterns:**
  - pattern code in the module language, plus generator buttons that write notes you can edit
  - code can be frozen into a drawn pattern
- **Release:** both features ship in v2 with the house synth, because chord patterns need its voice engine.
- **Details, from a second round of questions:**
  - Patterns come in two shapes, single-sound and kit (rows routed to layers), and can be 1 step to 64 bars long.
  - Notes carry probability, ratchets, slide and custom values.
  - Any note can carry curves for pitch and for any value. The piano roll draws a bent note as a curve, drawn freehand and then refined with points and handles.
  - Notes snap to a grid (1/16, 1/32 or triplets) or are placed off-grid.
  - Procedural patterns may vary between loop repeats, deterministically.
  - Globals get automation lanes.
  - No note recording in v2: patterns are drawn or generated.
  - **Scenes move from Stage 5 into v2.**
  - **MIDI 2.0 is the project's own note model.** MPE export stays possible, but exporting MIDI to a DAW isn't a priority yet.
- **Status:** planning only. Nothing is built until the owner says so ([architecture](architecture.md#variables-and-patterns-proposal), [roadmap](roadmap.md)).

## 2026-10-28: How v1 was built (Claude's defaults, open to change)

The owner asked for v1 to be built. These are the choices made while building it; each can be changed.
- **Language values:** values are 64-bit floats with JavaScript's operator results, instead of pure int32 wrapping, so pasted bytebeat formulas give exactly what they give on the web. `x/0` and `x%0` stay defined as 0.
- **Params live in the code** (`param name = 6 in 1..12`), not in the header, so a module's interface is in one place. The header keeps `caw`, `kind` (`generator` or `effect` in v1), `name`, `summary`, `mode` and `rate`.
- **Fewer dependencies than planned:**
  - The engine writes WAV and reads JSON with its own small code, instead of CHOC.
  - v1's oscillators, envelope and filter are our own, which keeps them bit-exact. Signalsmith DSP and DaisySP move to v2.
  - Dart bindings are written by hand, not generated with ffigen, so its licence question no longer arises.
  - The only third-party code in the engine is miniaudio 0.11.25.
- **App dependencies, all permissive:** Flutter 3.47.7 (BSD-3-Clause), `ffi` 2.2.0 (BSD-3-Clause), `path_provider` 2.1.6 (BSD-3-Clause), `file_picker` 13.1.0 (MIT). Versions are pinned and were at least two weeks old when chosen.
- **Exports:**
  - A loop export renders two loops and keeps the second, so it matches repeating playback, seams included.
  - A one-shot is one pass of a layer with the silent end trimmed.
  - A wavetable frame is one cycle (`t` 0–2047, `sine(1)` is one cycle).
- **Overload:** the engine mutes the newest audible layer and shows a banner, instead of letting audio break up.
- **Android application id `com.kmandevr.caw`:** it can still change, but only until the first release build is installed.
- **Not in v1:** playing on in the background (an Android foreground service), RealtimeSanitizer and fuzzing in CI, and Serum's `clm ` wavetable chunk.
- **Delivery:** all of v1 is on the one session branch and PR, in separate commits, instead of one PR per build step.

## 2026-10-28: Public repository, proprietary licence (owner)

- **The repository goes public** (owner) so GitHub Actions minutes are free. This replaces "the repository stays private" in the entry below.
- **The licence stays the same** (owner): proprietary, all rights reserved. `LICENSE` says so explicitly, because a public repository with no licence file leaves visitors guessing.
- **What public means in practice:** anyone can read the code and the issues. Secrets, signing keys and unfixed security problems never go in the repository, issues or logs (`.claude/rules/ci.md`, the `tasks` skill, `SECURITY.md`), and fork pull requests never get secrets.

## 2026-10-28: Name and logo (owner)

- C.A.W stands for **Code Auditioning Workspace**, and the logo is a crow. The name question is closed.

## 2026-10-28: v1 scope (owner, answering Claude's questions)

- **Areas:** three of them. A **Builder** makes modules: generators, and effects that process an incoming signal. An **Arranger** uses them in a loop stack. An **Exporter** writes the files.
- **Layers:** unlimited, each looping at its own length against the shared BPM. Mixing is volume, pan, mute and solo, plus a master limiter.
- **Language:** bytebeat plus `param`, the time variables and synth basics (oscillators, noise, one envelope, one filter).
- **Exports:** loop WAV, free-length WAV, one-shot WAV and wavetable.
- **Platforms:** the Android app and a Windows app (the owner runs Reaper on Windows).
- **Look:** neon on black (green, pink, yellow, blue).
- **Later:** the house-built synth with notes and MIDI comes right after v1, in v2. Scenes and a timeline arranger, sends and buses come later still.
- **Claude's default, open to change:** effects attach to a layer as an ordered chain (generator → effect → effect).
- **Superseded:** this replaces the earlier single-sound "Milestone 1". The roadmap is rewritten around v1 and v2 ([roadmap](roadmap.md)).

## 2026-10-28: Synthesis, MIDI and musical helpers (owner)

- **Owner requirement:** proper synthesis and MIDI, and user-friendly helpers so things like a loop that fits the beat are easy.
- **How (proposal):**
  - Musical time is built into the language (`bpm`, `beat`, `bar`, `step`, `pos`), and loops are exact-length with seam crossfades.
  - Synthesis built-ins sit on Signalsmith DSP and DaisySP.
  - MIDI covers notes, CC learn, clock, and MIDI file import and export.
  - Note and scale helpers, plus starter templates.
- **Milestone 1 gains** the BPM and loop length, the time variables and exact-length loop export, because they're small and they're what the owner needs for making samples now ([architecture](architecture.md#synthesis-midi-and-musical-helpers)).

## 2026-10-28: Every sound can be a synth, a wavetable or a sample (owner)

- **Owner requirement:** any sound code can be played as a synth, exported as a waveform or wavetable for other synths, or exported as a sample (one-shot, loop, multisample).
- **How (proposal):** it's the same code run three ways. A fixed voice pool gives polyphony, with pitch-scaled `t`, plus `phase`, `freq`, `note`, `vel` and `gate`. Wavetables are 2048-sample single-cycle frames, samples are WAV with `smpl` loop points, and multisamples are WAV plus SFZ. Lands in Stage 2. The engine's core interface already plans MIDI input, so it stays as designed ([architecture](architecture.md#instruments-wavetables-and-samples)).

## 2026-10-28: Flutter confirmed; bit-exact, repeatable chaos (owner)

- **Flutter for the UI** on every platform (owner confirmed the proposal below).
- **The language works on raw bits and is exactly repeatable** (owner): 32-bit wrapping integers with JavaScript bytebeat semantics, bit built-ins, seeded counter-based randomness only, and floats kept repeatable (no fast-math, the engine's own maths functions). Same code and seed give the same samples on every platform and in export ([architecture](architecture.md#bits-and-determinism)).

## 2026-10-28: C++20 engine, plugin-shaped, fully standalone (owner)

- **C++20 for the engine** (owner, choosing between C++ and Rust). Plugin formats are C and C++ natively, every platform's own compiler supports it, and the audio libraries are C or C++. Memory safety while parsing untrusted code is covered by a small parser, fuzzing, sanitizers and hard limits.
- **C.A.W is independent of AutoStacc** (owner): a different engine with a different goal. AutoStacc is only where it will be sold, and where the agent setup came from.
- **Possible VST3/CLAP plugin** (owner), so the core is plugin-shaped (prepare, process blocks with events, parameters, MIDI, host transport, state) and driven by three hosts: the app, a DAW, the CLI.
- **Every build is fully standalone and offline** (owner).
- **Building blocks:** miniaudio, CHOC, RealtimeSanitizer, fuzzing, then Signalsmith DSP and DaisySP, and later CLAP with clap-wrapper. The language, compiler and VM stay our own ([architecture](architecture.md#ready-made-building-blocks)).

## 2026-10-28: Every platform; Flutter + miniaudio proposed (owner: platforms; Claude: stack, owner to confirm)

- **Targets:** Android, iOS, Windows, macOS and Linux (owner). Android first, on the owner's Galaxy S22+ (Android 16).
- **Replaces the Android-only stack below:** Kotlin + Compose and Oboe are dropped. The portable C++ engine stays, since it was built for this.
- **miniaudio for audio output on every platform:** one public-domain/MIT-0 C library with AAudio, Core Audio, WASAPI and ALSA backends. Oboe stays a fallback for Android if latency tests on the S22+ fall short.
- **Flutter proposed for the UI:** one codebase for all five targets and one `dart:ffi` bridge to the engine. Compose Multiplatform is the runner-up (two bridges, a JVM on desktop). JUCE was rejected for revenue-capped licensing and weak touch text editing, Qt for LGPL on iOS.
- **iOS conflicts with AutoStacc-only selling:** outside the EU and Japan, iOS apps can only be sold through the App Store. Left to the owner.

## 2026-10-28: Sold only through AutoStacc; samples first (owner)

- **Closed and commercial, sold only through AutoStacc**, not the Play Store or other stores. The repository stays private. Permissive dependencies remain the rule, since the app's own source isn't published.
- **Until then it's the owner's sample-making tool for AutoStacc**, so WAV export quality and speed of getting sounds out come first.
- **Default branch:** `main` was pushed at the current commit. Sessions can't change repository settings (the proxy blocks GitHub's write APIs for branches and settings), so the owner switches the default to `main` in GitHub settings.

## 2026-10-28: Repository and agent setup (owner)

- **Setup comes from AutoStacc**, the owner's other repository: `CLAUDE.md` with read-in-layers, the repo map from purpose lines (`.claude/tools/tree.sh`), Graphify for file-level orientation, Serena for symbols, path-scoped rules, skills, read-only review agents, the `change` workflow, the handoff, and GitHub Issues as the only task list. AutoStacc's project-agnostic `tools/`, `hooks/` and `workflows/` are kept identical so they can be refreshed from there (one exception: a `tree.sh` fix for a root with no files of its own, worth porting back).
- **Agents fit this project:** `architect`, `code-reviewer`, `audio-reviewer` (new: real-time safety and DSP) and `security-reviewer` (rewritten for module sandboxing, GitHub auth, Android and CI). AutoStacc's site, SEO and store agents and skills weren't brought over.
- **Docs stay clean and current:** one home per fact, superseded text rewritten where it stands, history only in this note and the [log](log.md). `scripts/docs-test.js` enforces frontmatter, links, named paths, the index and stale notes; CI runs it, and the Stop hook reminds Claude.
- **Note names are lowercase** (`architecture.md`, `roadmap.md`) to match the vault.

## 2026-10-28: Stack and engine direction (Claude, proposed; owner to confirm)

- **Kotlin + Jetpack Compose UI, Oboe for audio I/O, a custom portable C++ engine.** Oboe is the Android low-latency standard (Apache-2.0). A portable core also builds as a Linux CLI, so CI and AI agents can check and render sounds without a phone.
- **User code compiles to bytecode for our own VM** instead of embedding JavaScript or Lua: no garbage-collection pauses on the audio thread, and the sandbox comes from what the language can't do.
- **No NKIDO dependency for Stage 1.** It's MIT and architecturally similar, but small (one main developer) with no confirmed Android build. Re-evaluate with a one-day spike in Stage 2.
- **GitHub App with device-flow sign-in**, limited to repositories the user selects; no secret ships in the app.
- **APKs are built in GitHub Actions**, because the owner works from a phone.
