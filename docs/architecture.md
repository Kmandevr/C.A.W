---
title: Architecture
summary: Technical plan for every target platform: stack, audio engine and code execution, module format, GitHub sync, AI workflow, risks.
updated: 2026-10-28
---

# Architecture

The technical plan for the owner's brief in [vision](vision.md). Build order: [roadmap](roadmap.md). Why each choice was made: [decisions](decisions.md).

Labels used below:
- **[Fact]** is verified, either in this repo or from a primary source. The date is noted when it matters.
- **[Proposal]** is a recommendation that is open to change.
- **[Assumption]** has not been verified yet and needs checking.

## 0. Current state

- **[Fact]** As of 2026-10-28, v1 is built: the C++ engine (`engine/`, described in [engine](engine.md)), the Flutter app for Android and Windows (`app/`) and the starter modules (`examples/`). CI builds and tests all of it. The plugin, GitHub sync, AI library editing and the v2 synth are still plans.

## 1. Technology stack

**Targets (owner, 2026-10-28):** Android, iOS, Windows, macOS and Linux, with the web as a later extra. Android comes first, because the owner's phone (a Galaxy S22+) is the test device.

| Layer | Choice | Why |
| --- | --- | --- |
| Sound engine | **Custom C++20 core** (owner, 2026-10-28), no platform dependencies | Real-time safe and sandboxed by design. The same code runs on every target, in a Linux CLI for CI and AI agents, and later as WASM for the web |
| Audio I/O | **miniaudio**, behind a small `engine/platform/` interface | One C library for every target: AAudio on Android, Core Audio on iOS and macOS, WASAPI on Windows, ALSA/PulseAudio on Linux. Public domain or MIT-0 |
| UI | **Flutter** (owner, 2026-10-28) | One UI codebase for all five targets. One bridge to the engine everywhere (`dart:ffi`). Dart never touches audio samples, so its garbage collector can't cause dropouts |
| Bridge | Thin C API over the engine, called through `dart:ffi` | Only control messages cross it (play, stop, swap program, set parameter, read meters). No audio data, no per-sample calls |
| Build | CMake for the engine, Flutter for the app, **all built in GitHub Actions** | The owner works from a phone, so CI builds every installable and the owner downloads it |

- **[Fact]** miniaudio is public domain or MIT-0 (your choice). Its backends are AAudio (Android 8.0+) and OpenSL ES on Android, Core Audio on macOS and iOS, WASAPI on Windows, and ALSA on Linux. ([github.com/mackron/miniaudio](https://github.com/mackron/miniaudio), 2026-10-28)
- **[Fact]** Flutter 3.47 supports Android API 24–37, iOS 15+, Windows 10/11, macOS 12+, Debian 10+ and Ubuntu 20.04+ on x64 and Arm64, plus the web. ([docs.flutter.dev](https://docs.flutter.dev/reference/supported-platforms), 2026-10-28)
- **[Fact]** The Galaxy S22+ runs Android 16 (One UI 8), its last major update. ([mezha.media](https://mezha.media/en/news/one-ui-8-for-galaxy-s22-305386))
- **[Proposal]** Android `minSdk 26` (Android 8.0): every device gets AAudio, and Flutter's floor is lower anyway.
- **[Proposal]** Android is the only platform where Oboe would matter. Keep miniaudio unless latency tests on the S22+ fall short. If they do, add an Oboe backend behind the same `engine/platform/` interface. Oboe is Apache-2.0, [github.com/google/oboe](https://github.com/google/oboe).

### Engine shape: one core, three hosts

The owner may also ship C.A.W as a VST3/CLAP plugin. So the core is plugin-shaped from day one and knows nothing about who drives it:

- **Hosts:** miniaudio in the standalone app; a DAW such as Reaper through the plugin; the CLI for checks and offline WAV renders.
- **Interface:** `prepare(sampleRate, maxBlock)`, `process(block, events)`, automatable parameters, MIDI note input, the host's tempo and transport (so the sequencer follows the DAW), and state save/load (the sound code plus parameter values).
- **Fully standalone (owner):** every build runs on its own and offline. No server, account or network is needed to make sound; GitHub sync is optional.
- **Plugin UI:** later. Flutter doesn't embed in plugin windows, so a plugin starts with the host's generic parameter controls.

### Ready-made building blocks

The language, compiler and VM are ours, because they are the product and the sandbox. Everything around them comes from permissive, maintained libraries. All facts checked 2026-10-28.

| Job | Library | Licence | When |
| --- | --- | --- | --- |
| Audio output on every platform | [miniaudio](https://github.com/mackron/miniaudio) | Public domain / MIT-0 | v1 |
| FLAC writing, sinc interpolation, if needed | [CHOC](https://github.com/Tracktion/choc) | ISC | Later (v1 writes WAV and passes messages with its own small code) |
| Catching allocations and locks on the audio thread | Clang [RealtimeSanitizer](https://clang.llvm.org/docs/RealtimeSanitizer.html) (`[[clang::nonblocking]]`, `-fsanitize=realtime`) in CI | Part of LLVM | v2 (v1 CI runs AddressSanitizer and UBSan) |
| Crash-hunting the parser and compiler | libFuzzer with AddressSanitizer and UBSan in CI | Part of LLVM | v2 |
| Filters, delays, FFT, envelopes, spectral tools | [Signalsmith DSP](https://github.com/Signalsmith-Audio/dsp) | MIT | v2 (v1's filter and envelope are our own, for exact repeatability) |
| Oscillators, filters, effects, synthesized drum voices | [DaisySP](https://github.com/electro-smith/DaisySP) (the MIT library only, never DaisySP-LGPL) | MIT | v2 |
| Reference DSP algorithms | [Soundpipe](https://github.com/PaulBatchelor/Soundpipe) (archived January 2024: read and port, don't depend on it) | MIT | v1 onward |
| Plugin format | [CLAP](https://cleveraudio.org/) | MIT | Stage 4b |
| VST3, AUv2, AUv3 (macOS and iOS) and standalone builds from one CLAP plugin | [clap-wrapper](https://github.com/free-audio/clap-wrapper) | MIT (skip its AAX and ASIO options: GPL or commercial) | Stage 4b |
| VST3 itself | VST 3 SDK, MIT since version 3.8 ([Steinberg, October 2025](https://sonicstate.com/news/2025/10/30/vst-3-now-available-under-mit-license)) | MIT | Stage 4b |

Avoid: JUCE (revenue-capped free tier), Tracktion Engine (GPL or commercial, needs JUCE), DaisySP-LGPL, and Cmajor (**[Assumption: GPL or commercial; check before reconsidering]**).

### Rejected alternatives

- **Compose Multiplatform:** stable on Android, iOS and desktop, with the web in beta ([kotlinlang.org](https://kotlinlang.org/docs/multiplatform/supported-platforms.html), 2026-10-28). It's the strongest alternative to Flutter, but it needs two engine bridges (JNI on Android and desktop, cinterop on iOS) and ships a JVM on desktop.
- **JUCE:** built for audio apps on every platform, but its free Starter tier only covers up to $20,000 a year in revenue ([JUCE forum](https://forum.juce.com/t/important-changes-to-the-juce-end-user-licence-agreement-for-juce-8/61265)). Its touch text editing is weak, and the code editor is the heart of this app.
- **Qt:** LGPL or commercial. LGPL obligations are awkward for a closed app on iOS.
- **WebView or browser-only app:** latency is higher and less predictable, and garbage collection sits on the audio path. The web stays a later extra (engine as WASM in an AudioWorklet), not the main app.
- **Embedded JS or Lua running user code:** both have garbage collection, unbounded loops and a large attack surface. They can't run safely on the audio thread.

## 2. Audio and code execution

The central decision: **user code is compiled into bytecode for our own small VM, and that VM runs inside the C++ engine.** The source is never interpreted on the audio thread.

```
 source text ──► parser/compiler (worker thread) ──► Program (bytecode + constants)
                                                        │ atomic pointer swap
 audio callback (audio thread) ◄── VM runs Program ◄─────┘   (+ short crossfade)
```

- **The sandbox comes from what the language can't do.** It has no I/O, no filesystem, no network and no system calls. Memory is fixed-size and allocated before playback. Loops are bounded and the call depth is capped. Downloaded modules are therefore no more dangerous than local ones.
- **Audio-thread rules:** no allocation, no locks, no calls into the UI layer and no logging inside the callback. Programs are handed over through a single-slot atomic swap, and old programs are freed off the audio thread.
- **Block processing:** the VM runs each opcode over a block of samples (for example 64) rather than one sample at a time. This cuts interpreter overhead a lot.
- **Cost guard:** the engine measures time spent per callback. If it overruns repeatedly, it fades out and reports "too expensive" instead of stuttering.
- **Ear and speaker safety:** NaN/Inf values are replaced with 0, DC is blocked, and a hard safety limiter runs last. Default output gain is low. Glitch audio can go to full-scale noise instantly.
- **Defined arithmetic:** every operation has one defined result on every device (see [Bits and determinism](#bits-and-determinism)). Output has two modes: *byte* (`v & 255` mapped to −1…1, classic bytebeat) and *float* (clamped to −1…1).
- **Sample rates:** a bytebeat `t` counts at the *formula rate* (8 kHz by default, user-selectable). The engine upsamples to the device rate with zero-order hold, which keeps the crunch. Procedural instruments run at the device rate. WAV export runs at 44.1 or 48 kHz.
- **Offline render = same VM.** WAV export runs the identical program on a worker thread, faster than real time, so the export matches what you heard.
- **Background playback:** each platform has its own rule. Android needs a foreground service with the `mediaPlayback` type (required on Android 14+), and iOS needs the audio background mode. Desktop has no restriction. Device changes such as headphones being unplugged trigger a stream restart.

### Bits and determinism

The owner's requirement: code works directly on the bits, so sounds come out chaotic and noise-like, yet **exactly repeatable**, the way `t>>6<<5%t` is. The same code, seed and settings give the same samples, bit for bit, on every platform, in playback, in the plugin and in WAV export.

- **[Fact]** **JavaScript's number semantics**, so pasted formulas sound identical: values are 64-bit floats, and bitwise operators work on 32-bit wrapping integers. Shift counts are masked to 0–31. `>>` is arithmetic and `>>>` logical. `%` keeps the sign of the left side, and `x/0` and `x%0` give 0. Operator precedence follows C and JavaScript, so `t>>6<<5%t` reads as `(t>>6) << (5%t)`. The full reference is in [engine](engine.md).
- **No undefined behaviour inside:** bit operations convert through unsigned 32-bit values, so C++'s signed-overflow and oversized-shift traps can't leak into the sound.
- **Bit tools as built-ins**, using C++20's `<bit>`: rotate (`rotl`, `rotr`), `popcount`, count leading/trailing zeros, bit reverse, byte swap, and reinterpreting a float's bits as an integer and back (`bits(x)`, `float(i)`). Later, the same tools work on the bytes of imported audio (Stage 5).
- **Randomness is seeded, never live:** `hash(x)` and `noise(seed, t)` are counter-based hash functions (no hidden state, so jumping to any `t` gives the same value), and a project-level `seed` changes all of them at once. There's no clock or system randomness anywhere in the language.
- **Floats are made repeatable too:** compile with strict IEEE behaviour (no fast-math), and use the engine's own `sin`/`exp` approximations rather than each platform's maths library, whose last bits differ between systems. Golden-render tests in CI compare the exact bits.

### Instruments, wavetables and samples **[Proposal]**

The owner's requirement: any sound code can become a **playable synth**, a **waveform for other synths** or a **sample**. All of them come from the same code and the same deterministic VM, so they're simply different ways of running it.

- **Voice mode (playable synth):** the program runs once per note, from a fixed pool of pre-allocated voices (no allocation on note-on; the oldest voice is stolen when the pool is full). Each voice sees:
  - `t`: samples since note-on, scaled so pitch follows the note. Classic bytebeat runs at its formula rate when the note is the module's base note (default C4), and an octave up doubles the rate.
  - `phase`: 0–1 through one cycle at the note's frequency, for waveform-style code.
  - `freq`, `note`, `vel`, `gate` (1 while held, 0 after release), `rel` (samples since release).

  A voice ends after it has been silent for a while following release, or when the code's envelope reaches zero. Notes come from the on-screen keyboard, MIDI on the device, or the host when it runs as a plugin.
- **Waveform export (wavetables for other synths):** render single cycles of 2048 samples. Sweeping a parameter, the seed or a "frame" variable over 1–256 frames makes a morphing wavetable, saved as one WAV of back-to-back frames. **[Assumption: Serum and Vital read this layout, and Serum wants an extra `clm ` chunk marking 2048-sample frames. Verify before building.]**
- **Sample export:** one-shots and loops as WAV (24-bit or 32-bit float). Loops get loop points in a `smpl` chunk, set at exactly repeating lengths where the code repeats. Multisample sets render a range of notes and velocities, plus an SFZ mapping file (an open text format).
- **Aliasing is a choice:** bit-twiddled waveforms alias when pitched up, which is part of their sound. Voice mode and export offer optional oversampling (2× or 4×) for a cleaner result.

### Synthesis, MIDI and musical helpers **[Proposal]**

The owner's requirement: proper synthesis and MIDI, and helpers that make musical results (such as a loop that fits a beat) easy, without taking away raw bit code.

- **Synthesis built-ins** (basics in v1, the rest in v2, on top of Signalsmith DSP and DaisySP):
  - oscillators: sine, saw, square, triangle, band-limited and raw
  - noise, filters, envelopes (ADSR, decay) and LFOs
  - FM and phase modulation, additive partials, wavetable playback of our own exported tables, and later granular

  They mix freely with bytebeat expressions: `saw(freq) * (t>>8 & 1)` is valid code.
- **MIDI:**
  - notes in from the on-screen keyboard, USB/Bluetooth MIDI devices or the plugin host, driving voice mode
  - CC and pitch bend mapped to `param`s ("MIDI learn")
  - MIDI clock in, so the tempo follows external gear
  - MIDI files imported to play a sound, and the sequencer's patterns exported as MIDI files for Reaper
  - MPE later
- **Musical time is built in:** `bpm` (project setting, or the host's when it's a plugin), `beat`, `bar`, `step` (16ths), and `pos` (0–1 through the loop). Code can say `(beat & 1) ? kick : 0` instead of working out sample counts.
- **Loops that repeat cleanly:** a project has a loop length in bars at its BPM. Playback wraps at exactly that length, the waveform shows the loop, and export cuts at exactly that length, with loop points set. A bytebeat formula that doesn't repeat on its own gets a short crossfade at the seam, which can be turned off. For classic formulas the engine can also *find* their natural repeat length (powers of two of `t`) and offer it.
- **Notes and scales:** note names (`C4`, `A#2`) and `mtof()`, plus `scale("minor", i)` and `chord("m7", i)` helpers. Quantizing a pitch to the project's key is one call.
- **Approachable defaults in the app:**
  - starter templates (a bytebeat loop, a kick, a bass synth, a pad, a glitch fx)
  - auto-generated sliders for every `param`
  - BPM tap, a bar-length picker, and one-tap "export this loop"

  Beginners can start from a template and a few sliders, and every helper is still plain code that can be edited.

### Variables and patterns **[Proposal]**

The owner's requirement (2026-10-28): Unity-style variables (local, global and readable elsewhere, with sliders and tooltips), and a pattern builder whose patterns any sound can play, drawn or procedural. All of it ships in v2 ([roadmap](roadmap.md)).

**Variables**, like Unity's Inspector. **[Fact]** Built in v2 step 1 (2026-10-28), except automation lanes; reference in [engine](engine.md#statements):

```
// --- Tone ---                                        a header groups the controls below it
param cutoff = 900 in 100..4000 step 10 "How bright"   slider with step and tooltip
param wave = saw in [saw, square, tri]                 dropdown
param filter = on                                      toggle
global swing = 0.1 in 0..0.5 "Swing for every layer"   one project-wide control
export let env = ad(trig, 0.001, 0.3)                  a signal other modules read
```

- **Local** `param`s gain a step, a tooltip, dropdowns (`in [a, b, c]`), toggles (`on`/`off`) and headers (`// --- Name ---`). The Builder lays them out like an inspector.
- **Global** `global`s live on the project. A Project Controls panel shows each one once, and every module that declares the same name reads the same value. Changing one doesn't recompile anything; it's a parameter write.
  - **Automation lanes** (owner) let a global move across the loop, for example a filter that opens over 4 bars. The lane is part of the project, so playback and export follow it exactly. A global with no lane stays where it is set.
- **Exports:** `export let` makes a value readable as `module.name`, for example `bass * (1 - kick.env)` for sidechain ducking.
  - The mixer runs layers in dependency order, so a reader hears the current block.
  - A cycle, where two modules read each other, is broken by reading the other side's previous block, 64 samples late. This is reported as a warning, not an error.
  - Exports stay inside the sandbox: they are only numbers passed between modules.

**Patterns** are modules of `kind: pattern` in the same `.caw` format, so they diff cleanly in git and an AI agent can write them. Details set by the owner on 2026-10-28 ([decisions](decisions.md)):
- **Two shapes:**
  - A **single-sound pattern** drives one layer.
  - A **kit pattern** has named rows (kick, snare, hats …), and each row is routed to a layer, so one pattern can drive a whole kit.
- **Length:** 1 step to 64 bars, independent of the layer's length.
- **Timing:** notes snap to 1/16 by default, can switch to 1/32 or triplets, or go anywhere with snap off. Swing comes from a global.
- **Notes:** each note has a start, length, pitch and velocity, plus:
  - **probability**, repeatable by seed
  - **ratchets**: 2–4 repeats inside the note
  - **slide** into the next note
  - **custom values** that the playing module reads by name (for example `timbre`, `crush`)
- **Curves on notes:** any note can carry curves over its length, for pitch (bends and slides) and for any value.
  - The piano roll draws the note itself bent along its pitch curve, so a slide is visible as a curved note.
  - Value curves show as lines under the note.
  - You draw freehand with a finger, and it smooths into a curve with points and handles you can then drag.
- **Note model:** stored the MIDI 2.0 way: per-note pitch and per-note controllers at high resolution, not 7-bit channel messages. The owner chose MIDI 2.0 for the project's own data.
- **Procedural patterns:** code in the module language, run once per step, deciding whether a note starts and its pitch, velocity, length and extras.
  - New built-ins: `euclid(hits, steps, step)`, `scale(name, degree)`, `chord(name, root)`, `key`, and `loop` (how many times the pattern has repeated).
  - `hash`/`noise` with the seed make every repeat identical. A pattern can use `loop` to vary between repeats; playback and export still agree because it is deterministic.
  - "Freeze" turns the code's output into an editable drawn pattern.
- **Editor:**
  - a drum grid (rows, steps, a velocity lane) and a piano roll (pitch × time, note lengths and curves), switchable on any pattern
  - chord stamping in the project's key
  - generator buttons that write notes you can edit: Euclid, random in key, arpeggiate, humanize
  - no recording in v2: notes are drawn or generated
- **Playing a pattern:** drag a pattern onto a layer and that layer's generator plays it through new variables:
  - `trig` (1 on the first sample of a note), `gate`, `note`, `freq`, `vel` and `rel`
  - the current value of each note curve: `bend` for pitch, and custom values by name

  Polyphony (chords) uses the voice pool from the house synth's voice mode ([Instruments, wavetables and samples](#instruments-wavetables-and-samples)), each voice with its own curves. The templates switch from `step % 4 == 0` to `trig`, with a built-in default pattern, so a layer without a pattern still plays.
- **Scenes** (owner, moved from Stage 5 into v2): a scene is a saved set of which pattern each layer plays, plus global values. Switching scenes happens at the next loop boundary, so it stays in time.
- **MIDI files** are not a priority (owner: no DAW export yet), but the plan stays open for them:
  - import of `.mid` into a drawn pattern
  - export as **MPE**, one channel per note, so per-note curves survive
  - **[Assumption]** MIDI 2.0 clip files (SMF2) would carry the note model directly, but DAW support for them, Reaper included, is unverified. Check before choosing the export format.
  - On desktop, dropping a `.mid` file onto the app needs a drag-and-drop package with a permissive licence: **[Assumption]** check one before choosing it.

### Standard library and connectors **[Proposal]**

The owner's requirement (2026-10-28): a built-in library of documented building blocks for the hard audio jobs, such as envelopes, connectors and MIDI input. A person or an AI agent should be able to see what each one does and how it works.

- **Two layers, one namespace style** (`env.adsr(…)`, `midi.cc(74)`):
  - **Built-ins in C++** for speed and exact repeatability (like v1's `ad`, `lpf` and `sine`).
  - **Library modules in the C.A.W language**, built from those, so anyone can open one and see how it works.
- **Categories in v2** (owner chose all four):
  - **Envelopes and LFOs:** `env.adsr`, `env.ar`, multi-stage envelopes, `lfo.sine/tri/saw/square/random` synced to the tempo, `slew` and smoothing.
  - **Filters and effects:** more filter types, `fx.delay` (tempo-synced), a reverb, distortion and saturation, a compressor, `fx.crush`.
  - **MIDI and music theory:**
    - MIDI in: `midi.note`, `midi.vel`, `midi.cc(n)`, `midi.bend`, `midi.clock`
    - `scale`, `chord`, `arp`, `euclid`, `quantize(note, key)`
  - **Glitch and bit tools:** `glitch.stutter`, `glitch.fold`, sample-and-hold, bit masks, and seeded random helpers built on `hash`.
- **Your own functions** (owner: "yes, but simpler"):
  - `fn name(args) = expression` in library files works like the built-ins and can be shared through the library repo.
  - Only the app's own library gets generated reference pages and in-app help.
  - A user function's doc comment still shows as its tooltip.
- **Documentation from one source.** Each library function carries a doc comment: what it does, each argument with its unit and range, the output, and a short example. The build turns that into:
  - **a reference page** in `docs/`
  - **an agent guide**: a compact list of every function with its signature and one line on what it does, for any AI agent
  - **in-app help**: autocomplete in the code editor, and a long-press (hover on desktop) on a name to show its docs and play its example
  - **inspector tips**: the sliders a function's arguments become carry the argument's description as their tooltip
- **CI checks the docs:** `caw docs --check` fails when a library function has no doc comment or an argument isn't described. Every example must compile and render non-silent audio (golden-hashed), so the docs can't drift from the code.
- **Connectors.** The owner wants every kind of connector eventually.
  - **v2 builds what is already in scope:**
    - **Sidechain** between layers, through `export` signals ([Variables and patterns](#variables-and-patterns-proposal)).
    - **Modulation links:** connect an LFO, envelope or pattern curve to any `param` or `global` with an amount, like Bitwig's modulators. You drag from the source onto a slider; in code, it's `mod(target, source, amount)`.
    - **MIDI ports:** USB and Bluetooth MIDI devices feed `midi.*`, and MIDI clock can drive the tempo.
  - **Later:** sends, returns and buses (Stage 5), and free module patching like a modular synth, beyond the fixed generator → effects chain.

### Language direction **[Proposal]**

- Accept the **JS-style bytebeat expression subset** first (`t`, `>> >>> << & | ^ ~ % * / + -`, comparisons, ternary, `sin`, `floor`…), with the semantics above, so formulas from the community paste in and sound the same.
- **[Fact]** v1 has `let`, `param` and the stateful built-ins (envelope, filter, oscillators, noise).
- Next (v2): user functions (`fn`), `use` imports of library modules, and the standard library ([above](#standard-library-and-connectors-proposal)).
- Add a sequencing mini-language in Stage 5, designed for phone typing, e.g. `kck p8 snr p16 hat*3 @ 140`. It compiles into the same VM. Polyrhythm comes from independent loop lengths against a shared clock.

### NKIDO evaluation

- **[Fact]** As of 2026-10-28: [mlaass/nkido](https://github.com/mlaass/nkido) is MIT-licensed, C++20/CMake, and pairs a stack-based bytecode synthesis VM ("Cedar") with a Tidal-style language ("Akkado"). It supports hot-swap with crossfade and runs natively and in the browser via WASM. The project is small: 8 stars and essentially one developer.
- **[Assumption]** Unverified: Android and iOS builds, a stable embedding API, and long-term maintenance.
- **[Proposal]** Don't depend on it for v1. A bytebeat VM is small enough to own. NKIDO uses the same architecture recommended here, which supports the design. In v2, do a 1-day spike to judge whether Cedar could serve as the graph/DSP layer. Keep our engine behind an interface (`compile(source) → Program`, `process(Program, buffer)`) so we can swap the backend either way.

## 3. Source and module structure

### This repo (Repository A — app)

**[Fact]** Built as of v1:

```
engine/src/      C++ core: compiler, VM, built-ins, mixer, exports, WAV writer, C API (no platform deps)
engine/platform/ Audio output (miniaudio)
engine/cli/      Desktop CLI: `caw check`, `caw render` (used by CI and AI agents)
engine/tests/    Unit tests and golden renders (hash of rendered output per template)
app/             Flutter app: lib/ (engine bindings, model, screens), android/, windows/, linux/ (local testing)
docs/            These notes and the language reference
examples/        Bundled starter sounds in the module format (later mirrored to the library)
```

### Sound library (Repository B, created in Stage 3)

```
caw-library.json       library name, module format version
instruments/  kick-grit.caw, bass-xor.caw …
effects/      bitcrush.caw, bytefold.caw, stutter.caw …
functions/    reusable helpers
patterns/     sequences
presets/      parameter sets for modules
projects/     full pieces that reference modules
AGENTS.md     language + format guide for any AI agent
```

### Module file

One plain-text file per module: a small metadata header followed by code. Single files are easy for AI agents to edit and produce clean git diffs.

- **[Fact]** Built in v1: the header holds `caw: 1`, `kind` (`generator` or `effect`), `name`, `summary`, `mode` and `rate`. Sliders come from `param` lines in the code, so a module's whole interface lives in one place. Format and language: [engine](engine.md).
- **[Proposal]** Later kinds (`function`, `pattern`, `project`), referencing modules by path (`use effects/bitcrush`), and projects that pin the library to a **commit SHA**, so an old project always sounds the same.
- The engine reads only format version 1 and rejects others with a clear error, so incompatible modules are listed but never played.

## 4. GitHub sync

GitHub stores and versions files. It never executes audio code.

- **Auth [Proposal]:** a **GitHub App** with **device flow** sign-in. Device flow needs no embedded secret. The user enters a short code on github.com. Permissions are limited to *Contents: read/write* on **repositories the user selects**. Tokens are stored encrypted with the Android Keystore. The app never ships with a privileged token.
  - **[Assumption]** Whether refreshing an expiring GitHub App user token needs the client secret must be verified. If it does, the fallback is to repeat the device flow when the token expires, or to add a tiny token-refresh endpoint later.
- **Per-user repos:** each user owns their library repo, for example one created from a public template. This gives the user ownership of their data and costs us no central storage.
- **Read:** one request to the Git Trees API (recursive) lists the library at a ref. The app compares blob SHAs (git hashes, also computed locally) and downloads only the changed files. A public library needs no sign-in to read.
- **Write:** the Git Data API (blobs → tree → commit → non-force ref update) gives **one atomic commit per save batch**. No git client is bundled.
- **Conflicts:** if the ref update fails because the remote moved, the app re-fetches and merges files that only one side changed. When both sides changed a file, the app pushes local work to a branch (`caw/conflict-<timestamp>`) and shows a "pick one" choice. Nothing is lost silently.
- **Offline-first:** the local copy is the working copy. Playback never waits on the network.
- **Separate updates:** App updates come from release builds (later delivered through AutoStacc). Library updates come from git. Neither requires the other.

## 5. AI-assisted editing (no phone UI control)

1. You ask Claude (or another agent) for a sound.
2. The agent edits `.caw` files in the library repo on a branch or PR, guided by `AGENTS.md`.
3. **CI on the library repo** runs the same engine as a Linux CLI: `caw check` (parse, compile, enforce limits) and `caw render` (a short WAV plus checks for silence, clipping, NaN and CPU cost). The agent can verify its own work without a phone, and the PR includes a preview WAV.
4. In the app, a **source picker** chooses `main` or any branch or PR. You hear the change, then merge or discard. Reverting means picking an earlier commit or using `git revert`.

Any agent that can edit files in git works with this setup. There's no provider-specific integration.

## 6. Biggest risks and simplest mitigations

| Risk | Mitigation |
| --- | --- |
| User code glitches the audio thread | Own VM, no allocation or locks, bounded execution, cost guard (§2) |
| Malicious or broken downloaded modules | No I/O by design; limits on source size, AST depth, program size and memory; failures mute only that module |
| Hearing or speaker damage from harsh output | Safety limiter, NaN guard, low default gain, fade on start/stop |
| Language scope creep | Ship the bytebeat expression subset first and grow it one feature per milestone |
| Developing from a phone (no PC or IDE) | GitHub Actions builds every target. Android debug APKs are signed with a fixed keystore in CI secrets so updates install over each other. The engine is tested on Linux in CI |
| Apple builds | iOS and macOS builds need macOS runners. The repository is public, so standard GitHub-hosted runners cost nothing; check this if it goes private again **[Assumption: check current GitHub pricing]**. Distributing them needs a paid Apple Developer membership. Build Apple targets only on release branches or on demand |
| Device audio differences | miniaudio's per-platform backends, float output, restart on disconnect, early testing on the S22+ and each new platform; Oboe as an Android fallback |
| Touch code editing is clumsy | Symbol row (`t >> << & \| ^ ( ) ? :`), short files, live error line, a Flutter code editor with lightweight highlighting (pick a permissively licensed package, or write a small one) |
| Token leakage or over-broad access | Device flow, GitHub App limited to selected repos, platform secure storage (Android Keystore, Apple Keychain, Windows Credential Manager, Linux Secret Service), no shipped secrets |
| Licensing | Use only permissive dependencies (miniaudio public domain/MIT-0, Flutter BSD-3, any NKIDO use MIT), avoid GPL. Don't bundle community bytebeat formulas without permission. Choose the app license and library license (e.g. CC0/MIT for modules) **before** accepting outside contributions |
| Selling only through AutoStacc (owner) | **[Proposal]** Android: one release signing key kept for good in repository secrets (every update must be signed with it), plus clear install steps on the AutoStacc page. Windows: code-sign installers so SmartScreen doesn't block them. macOS: sign and notarize with an Apple Developer account. A privacy policy is needed everywhere (the app stores GitHub tokens) |
| iOS can't be sold only through AutoStacc | **[Fact]** Outside the App Store, iOS apps can only be distributed through alternative marketplaces in the EU (and now Japan). That requires Apple's approval, notarization and an organization account ([Apple](https://developer.apple.com/support/alternative-app-marketplace-in-the-eu), 2026-10-28). iOS realistically means the App Store, so it's an open question in [vision](vision.md#open-questions) |

## Sources

- miniaudio: https://github.com/mackron/miniaudio
- Flutter platforms: https://docs.flutter.dev/reference/supported-platforms
- Compose Multiplatform stability: https://kotlinlang.org/docs/multiplatform/supported-platforms.html
- Oboe (Android fallback): https://github.com/google/oboe
- NKIDO: https://github.com/mlaass/nkido · [ADC Japan 2026 talk listing](https://adcjapan26.sched.com/event/2KCfA)
