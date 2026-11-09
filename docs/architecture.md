---
title: Architecture
summary: Technical architecture, verified engine/app boundaries and clearly labelled future design proposals.
updated: 2026-11-06
covers: [engine/, app/lib/engine/, app/lib/ui/shell.dart, app/pubspec.yaml]
---

# Architecture

The technical plan for the owner's brief in [vision](vision.md). The C++ language, SDK and shared component architecture are specified in [C++ creation platform](cpp-creation-platform.md). Build order: [roadmap](roadmap.md). Why each choice was made: [decisions](decisions.md).

Labels used below:
- **[Fact]** is verified, either in this repo or from a primary source. The date is noted when it matters.
- **[Proposal]** is a recommendation that is open to change.
- **[Assumption]** has not been verified yet and needs checking.

## Product focus and capability

C.A.W. is not a conventional DAW and doesn't have to work like one, but it must be able to do everything a good DAW can do, because there is no good DAW for mobile ([vision](vision.md)). Architecture choices serve that capability through C.A.W.'s own model (code, patterns, one shared project and engine) on a lightweight, phone-first core. Audio recording is not implemented yet; it is roadmap Stage 7, before the first release ([roadmap](roadmap.md)).

## C++ creation platform direction

**[Owner decision, 2026-11-05]** C.A.W. will use ordinary general-purpose C++ as its programming language, a comprehensive C.A.W. Library/SDK, and one shared component model for code, visual scripting and generated/custom performance interfaces. The current .caw language/VM is transitional and will be retired after its useful capabilities have been migrated and verified; old source/project compatibility is not required. The detailed design, component contract, library scope, authoring interfaces, real-time boundaries, versioning and migration gates are in [C++ creation platform](cpp-creation-platform.md).

## 0. Current state

**[Fact, checked 2026-11-05]** The Flutter app has eight workspaces, shown as docking panels (`lib/ui/shell.dart`, `lib/ui/dock/`) with a glass look behind a Settings switch (`lib/ui/glass.dart`). It opens straight into the last project, with no startup screen, and its transport takes a typed or tapped tempo, undoes and redoes project edits, and pauses and resumes (Space) where it paused; Settings has a key bindings editor. There are CI build artifacts for Android and Windows. Linux is used for app analysis/tests and has a local runner, but is not a shipped app artifact. The portable C++20 engine is built/tested by CI on Linux x64, Linux Arm64 and Windows x64, plus Linux sanitizers. iOS and macOS app builds are not currently in the app workflow.

The current app and native implementation are documented in [App](app.md), [Engine](engine.md) and [Engine implementation status](engine-build-status.md). The app keeps every automation lane, point and pattern note the engine accepts (F7.1, 2026-11-04); the Engine grows past 64 layers within its memory budget (F7.3). The house synth, piano-roll expression editing, pattern generators, MIDI file import/export, native worker pool, adaptive workload planner and Engine Lab spectrum view have working implementations. Project-level module/global parameter automation is implemented (PR #68); WAV/SFZ multisample and stems export follow it in [roadmap](roadmap.md) Stage 0. USB/Bluetooth device I/O, audio import/editing, complete mixer routing and external binary plugin hosting are not implemented. GitHub sync and in-app AI features are not implemented or in the current product scope. Since 2026-11-03 one mix graph runs live playback and offline render: a node per module of each track (its generator or voice pool, then each effect), a track node, folder bus nodes and a master node, routed on the audio thread (Foundation F4.3, F4.4); the executor also runs typed sidechain, modulation and control ports (F5.1) and event ports (F5.2). The shared parameter resolver (F6.1, `engine/src/params.*`) runs in the graph executor, which passes every node its resolved parameter values (F6.2), with modulation links between nodes (F6.3), automation lanes played at the transport position (F6.4) and MIDI CC mappings from host events (F6.5); the Engine's own .caw params and globals resolve through it too (F6.6).

## 1. Technology stack

**Product targets (owner, 2026-10-28):** Android, iOS, Windows, macOS and Linux, with Android first. Web is not a current release target. The Galaxy S22+ is the primary Android test device. Product targets are not evidence that a platform build is currently shipped or CI-verified.

| Layer | Choice | Why |
| --- | --- | --- |
| Sound engine | **Custom C++20 core** (owner, 2026-10-28), platform separation under engine/platform/ | Portable core; currently CI-verified on Linux x64, Linux Arm64 and Windows x64, and built into the Android app. iOS/macOS/WASM builds are not currently CI-verified |
| Audio I/O | **miniaudio**, behind `engine/platform/` | Current host backends are selected in the platform layer; upstream miniaudio supports AAudio/OpenSL ES, Core Audio, WASAPI and ALSA/PulseAudio. Do not infer every backend is currently built or tested by this repository |
| UI | **Flutter** (owner, 2026-10-28) | One UI codebase; current CI builds Android and Windows app artifacts. Linux analysis/tests run, but Linux is not a shipped artifact; iOS/macOS app builds are not configured |
| Bridge | Thin C API over the engine, called through `dart:ffi` | Only control messages cross it (play, stop, swap program, set parameter, note previews, read meters). No audio data, no per-sample calls |
| Build | CMake for the engine, Flutter for the app, GitHub Actions CI | CI currently produces Android and Windows app artifacts and verifies Linux/Windows engine targets; it does not produce every target's installable |

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

The C++ language and compiler are ordinary toolchain facilities; the C.A.W. Library/SDK and component model are the product-specific reusable layer. Use permissively licensed, maintained dependencies where they provide a measured benefit, and record exact licences and versions before adoption. The current .caw compiler/VM is transitional, not the target language. The dependency candidates below are proposals, not adopted dependencies.

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

JUCE (9: AGPLv3/commercial) and Tracktion Engine (GPL-3.0-or-later/commercial, depends on JUCE) are references only; C.A.W. takes no code from them, because it will use a permissive licence and permissive dependencies (owner, 2026-11-09). See [visual creation and signal routing](visual-routing-and-library-integration.md) for candidate roles and evaluation gates. DaisySP-LGPL and Cmajor remain subject to exact licence/version review before use.

### Rejected alternatives

- **Compose Multiplatform:** stable on Android, iOS and desktop, with the web in beta ([kotlinlang.org](https://kotlinlang.org/docs/multiplatform/supported-platforms.html), 2026-10-28). It's the strongest alternative to Flutter, but it needs two engine bridges (JNI on Android and desktop, cinterop on iOS) and ships a JVM on desktop.
- **JUCE:** built for audio apps on every platform, but JUCE 8 and 9 are AGPLv3 or commercial, and JUCE 9 kept the JUCE 8 terms ([JUCE forum](https://forum.juce.com/t/juce-9-no-pricing-or-eula-changes/69000), checked 2026-11-09). Its touch text editing is weak, and the code editor is the heart of this app.
- **Qt:** LGPL or commercial. LGPL obligations are awkward for a closed app on iOS.
- **WebView or browser-only app:** latency is higher and less predictable, and garbage collection sits on the audio path. The web stays a later extra (engine as WASM in an AudioWorklet), not the main app.
- **Embedded JS or Lua running user code:** both have garbage collection, unbounded loops and a large attack surface. They can't run safely on the audio thread.

## 2. Audio and code execution

**[Fact, current implementation checked 2026-11-05]** The existing .caw authoring language is compiled into bytecode for a small VM inside the C++ engine; source is not interpreted on the audio thread. **[Owner decision, 2026-11-05]** This VM is not the target language architecture. Ordinary C++ and the shared component SDK replace it after useful functionality and product workflows have migrated. See [C++ creation platform](cpp-creation-platform.md#migration-from-the-current-caw-language).

```
 source text ──► parser/compiler (worker thread) ──► Program (bytecode + constants)
                                                        │ atomic pointer swap
 audio callback (audio thread) ◄── VM runs Program ◄─────┘   (+ short crossfade)
```

- **The sandbox comes from what the language can't do.** It has no I/O, no filesystem, no network and no system calls. Memory is fixed-size and allocated before playback. Loops are bounded and the call depth is capped. Downloaded modules are therefore no more dangerous than local ones.
- **Audio-thread rules:** no allocation, no locks, no calls into the UI layer and no logging inside the callback. Programs are handed over through a single-slot atomic swap, and old programs are freed off the audio thread.
- **Block processing:** the VM runs each opcode over a block of samples (for example 64) rather than one sample at a time. This cuts interpreter overhead a lot.
- **Arrangement scheduling:** clips are immutable instances that reference reusable pattern sources. On the control thread, CAW compiles their note events into one sorted absolute-time stream per track. The audio callback uses the existing block-boundary engine; it never parses patterns, allocates clip data or relies on UI timers. This keeps note timing independent of Flutter frame rate and avoids a separate scheduler thread.
- **Folder buses:** the control thread resolves a validated folder tree into slot routing indices and a child-before-parent render order. The callback sums child stereo buffers into each bus (since 2026-11-03 each child is rounded to 32-bit float and summed in float, as graph edges will carry it; bus and master processing stays 64-bit), applies bus gain and stereo balance, then routes the result upward exactly once. Organization-only folders have no audio slot. No routing graph is allocated or walked in the callback.
- **Track automation:** volume and pan points are copied into fixed-size slot arrays through the command queue. The callback interpolates against the current song step for each sample. The supported lane targets are deliberately limited to volume and pan in this implementation slice; global and plugin-parameter automation remain future work.
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
- **Bit tools as built-ins**, using C++20's `<bit>`: rotate (`rotl`, `rotr`), `popcount`, count leading/trailing zeros, bit reverse, byte swap, and reinterpreting a float's bits as an integer and back (`bits(x)`, `float(i)`). Later, the same tools work on the bytes of imported audio (roadmap Stage 3).
- **Randomness is seeded, never live:** `hash(x)` and `noise(seed, t)` are counter-based hash functions (no hidden state, so jumping to any `t` gives the same value), and a project-level `seed` changes all of them at once. There's no clock or system randomness anywhere in the language.
- **Floats are made repeatable too:** compile with strict IEEE behaviour (no fast-math), and use the engine's own `sin`/`exp` approximations rather than each platform's maths library, whose last bits differ between systems. Golden-render tests in CI compare the exact bits.

### Instruments, wavetables and samples — current status and remaining design

The owner wants code-defined sounds to become playable instruments and exportable audio assets. **[Fact, checked 2026-11-01]** C.A.W. already has generator voice playback, a house synth patch format, built-in wavetable playback/frame morphing and WAV loop/free-length/one-shot/wavetable export. A sample editor, imported audio assets, multisample mapping and SFZ export are not implemented. The design details below are proposals for remaining extensions, not a claim that every output path exists.

- **Voice mode (playable synth):** the program runs once per note, from a fixed pool of pre-allocated voices (no allocation on note-on; the oldest voice is stolen when the pool is full). Each voice sees:
  - `t`: samples since note-on, scaled so pitch follows the note. Classic bytebeat runs at its formula rate when the note is the module's base note (default C4), and an octave up doubles the rate.
  - `phase`: 0–1 through one cycle at the note's frequency, for waveform-style code.
  - `freq`, `note`, `vel`, `gate` (1 while held, 0 after release), `rel` (samples since release).

  A voice ends after it has been silent for a while following release, or when the code's envelope reaches zero. Notes come from the on-screen keyboard, MIDI on the device, or the host when it runs as a plugin.
- **Waveform export (wavetables for other synths):** render single cycles of 2048 samples. Sweeping a parameter, the seed or a "frame" variable over 1–256 frames makes a morphing wavetable, saved as one WAV of back-to-back frames. **[Assumption: Serum and Vital read this layout, and Serum wants an extra `clm ` chunk marking 2048-sample frames. Verify before building.]**
- **Sample export:** one-shots and loops as WAV (24-bit or 32-bit float). Loops get loop points in a `smpl` chunk, set at exactly repeating lengths where the code repeats. Multisample sets render a range of notes and velocities, plus an SFZ mapping file (an open text format).
- **Aliasing is a choice:** bit-twiddled waveforms alias when pitched up, which is part of their sound. Voice mode and export offer optional oversampling (2× or 4×) for a cleaner result.

### Current synthesis and MIDI implementation; C++ target

**[Fact, checked 2026-11-05]** The current engine has a synth patch compiler/playback path, built-in wavetable playback and frame morphing, LFO/modulation primitives, MIDI pattern file import/export and a MIDI 2.0 UMP decoder/input queue. USB/Bluetooth device discovery, connection, MIDI clock and live Engine voice routing are not implemented. See [Engine](engine.md), [Engine implementation status](engine-build-status.md) and the [roadmap](roadmap.md).

The existing built-ins and algorithms are migration candidates for the C.A.W. C++ Library/SDK. The target is a shared C++ event model for MIDI 1.0, MIDI 2.0 UMP, note identity, MPE/per-note expression, CC, clock and transport, usable from C++ components, visual graphs, performance controls and device adapters. Do not create separate MIDI implementations for each interface. The broader Library scope is in [C++ creation platform](cpp-creation-platform.md).

### Current variables and patterns — transitional .caw implementation

**[Fact, current implementation]** The .caw VM supports module parameters, project globals, exported values, pattern modules, note events, velocity and per-note expression curves, MIDI file import/export, and the current piano-roll/drum-grid workflows. Project/module automation and the shared engine parameter resolver are documented in [Engine](engine.md) and [Engine implementation status](engine-build-status.md).

This section describes the existing .caw implementation only. The owner has chosen ordinary C++ as the future authoring language. Do not extend the old .caw syntax as a parallel product language. Migrate useful parameter, pattern, event and generator capabilities to the shared C++ component/parameter/event model; old .caw source and pre-release-project compatibility is not required. See [C++ creation platform](cpp-creation-platform.md#migration-from-the-current-caw-language).

### Live editing while playing — current behavior and C++ migration

The existing .caw editor/VM supports live code swaps and pattern updates while playback continues. The C++ component workflow should retain useful live-update behavior where safe, using prepared component replacement and bounded state transfer rather than depending on the old VM's bytecode/state-matching mechanism.

**[Fact]** The engine side is built: swap timing, pattern edits that let sounding notes finish, and state carried across code swaps ([engine](engine.md#playback)). The app also implements delayed auto-update, an enable/disable switch and selectable swap timing; see [App](app.md).

- **[Fact]** Built already:
  - Run hot-swaps code with a 20 ms crossfade, and code that fails keeps the old sound.
  - Params and globals change without recompiling.
  - A pattern edit reaches the audio thread without rebuilding the sound ([engine](engine.md#playback)).
- **Auto-update for code** (owner):
  - When you stop typing for a delay you can set, code that compiles swaps in by itself. Code with an error is skipped, so the music never breaks.
  - A switch turns auto-update off, leaving Run and Ctrl+Enter only.
- **When a swap lands** (owner: choosable): immediately, at the next beat, or at the next bar. The engine already finds beat and bar positions sample-exactly, so a swap waits for that sample.
- **Pattern edits** (owner): a note that is sounding finishes as it was, and the edit is heard the next time that note comes round.
  - Today, a pattern change releases held notes. That changes to: held voices keep playing until their own note-off, matched to the old pattern's note.
  - New and changed notes take effect from their next start.
- **Keeping sound continuous across code swaps** (owner: "keep where possible"):
  - The new program takes over the running state of each stateful call that is still the same in the new code: oscillator phases, envelope positions, filter memory, delay and reverb buffers. So changing one number doesn't restart notes or echoes.
  - Calls are matched by function and position in the code, including inside `fn` and library calls. A call that is new or changed starts fresh, and the 20 ms crossfade covers what can't be carried over.
  - **[Assumption]** Matching by function and order is enough for typical edits. Test it on real edits: a reordered or renamed line may not match.

### C.A.W. Library/SDK and shared components [Proposal]

The selected direction is a comprehensive C++ Library/SDK, not a growing set of functions in a music-only language. It provides reusable DSP, synthesis, MIDI, sample/table, math, bit-manipulation, data and general-purpose facilities. Components are registered once and reused by code, visual composition, generated UI, mixer controls and later plugin adapters.

The shared component descriptor defines stable identity, role/capabilities, typed audio/event/MIDI/control/modulation/data ports, parameter metadata, assets, lifecycle, state/presets, real-time and resource contracts, UI metadata and export capabilities. One parameter definition drives generated controls, automation, modulation, MIDI mappings and plugin-host exposure. One processor implementation serves all interfaces.

The Library should include waveform and wavetable generation, oscillators, noise, interpolation, filters, EQ, distortion, saturation, dynamics, delay, reverb, modulation effects, FFT, convolution and resampling; synth voices, envelopes, LFOs, FM/AM, additive, granular and physical-modeling building blocks; samplers and sample buffers; MIDI 1.0, MIDI 2.0 UMP, MPE/per-note expression, sequencing and music-theory utilities; tables, windows, random distributions, vectors, matrices, complex math, transforms, bit operations and data utilities. Functions accept declared parameters, tables, buffers, events or other data and return audio, waveforms, transformed data, analysis results or events. Use the standard C++ library for standard facilities rather than duplicating it.

The full proposed scope and contracts are in [C++ creation platform](cpp-creation-platform.md). The [visual creation and signal routing design](visual-routing-and-library-integration.md) defines the component editor, project/track workspace, conditional routing and reuse candidates. The current built-in function inventory remains [Function library](library.md); do not mark planned SDK functionality as built.

### Shared MIDI and event routing [Proposal]

C++ components, visual blocks, the performance UI and external device adapters use one event model. It covers MIDI 1.0, MIDI 2.0 UMP, note identity, note-on/off, velocity, pitch, pressure, per-note expression, CC, program changes, clock, transport and timestamped events. Device I/O remains a separate adapter/integration task; a component does not get a private MIDI implementation.

### Real-time boundary [Proposal]

C++ itself remains general-purpose. Only code scheduled in the audio callback must meet the explicit real-time contract: bounded work, no allocation/free, blocking locks, I/O, logging or UI calls. Native C++ is not sandboxed by the SDK; untrusted native code must be isolated, trusted in-process by explicit choice, or blocked. The current VM's restrictions are not a reason to restrict ordinary C++ globally.

## 3. Source and component package structure

### This repository (C.A.W.)

The current repository contains the portable C++20 engine and CLI, platform audio layer, Flutter app, tests, documentation and bundled examples. The existing .caw module files and VM remain current implementation facts until the migration exit gate is met.

### C++ component source

**[Fact, checked 2026-11-06]** The existing native module processor contract is exposed to C++ component authors through `engine/include/caw/module.hpp`; `CAW::SDK` is now an installable CMake package exporting this include directory and C++20. The internal `engine/src/module.h` forwards to the public declaration, and engine-internal `engine/src` headers are not propagated to consumers. CP.1 now includes a versioned `caw.component` manifest, a CMake helper that produces a component shared-library target, exported descriptor/factory entry points, a Node build driver with structured diagnostics and a Linux/Windows/Android CI matrix (PR #125; CI verification pending). This does not yet provide app-private project storage, remote build submission/download, runtime dynamic loading, trust-mode enforcement or editor integration. **[Proposal]** Components use ordinary C++ source and headers with supported project/build metadata and declared dependencies. A component may span multiple files and use ordinary C++ libraries. Its descriptor is registered with the shared component system; no special-purpose .caw syntax or separate component language is required. Existing CMake/native build conventions are the starting point, with supported imported-project/build configurations documented by the editor.

### Reusable library and project assets

The planned C.A.W. Library can contain reusable C++ components, functions, instruments, effects, generators, data utilities, presets, examples and assets. Project-local assets travel with the project; global-library references use stable IDs and explicit versions. Asset handles define ownership and lifetime so sample buffers, tables and impulse responses are not copied unnecessarily.

### Legacy .caw files

The current .caw format documents the existing VM implementation only. It is not the future component source format. No compatibility layer for old .caw source or pre-release project files is required. Retain the old parser/VM only until every capability selected for migration has a tested C++/Library path and the app no longer depends on it; then remove the obsolete format and documentation.

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

## 5. AI and GitHub integration — deferred, not implemented

**Current owner direction (2026-11-01): no in-app AI integration.** Do not build AI generation, editing, model inference, source separation or cloud audio processing. AI coding assistants may be used externally as development tools; that does not make them a C.A.W. product feature.

The GitHub library-sync/source-picker workflow described in earlier proposals is also not implemented. The app currently works with local project files and operating-system import/export. Any future GitHub integration requires a separate owner decision, security review and implementation plan.

## 6. Biggest risks and simplest mitigations

| Risk | Mitigation |
| --- | --- |
| Native code disrupts real-time audio | Explicit callback contract, prepared resources, bounded execution, tests and per-component trust policy; ordinary non-real-time C++ remains unrestricted |
| Untrusted native components | Native C++ is not sandboxed; Isolated, Trusted and Blocked modes are explicit, with no silent in-process loading |
| Hearing or speaker damage from harsh output | Safety limiter, NaN guard, low default gain, fade on start/stop |
| SDK and component complexity | Keep stable contracts small, add extension seams for real needs, and test that new components do not require unrelated rewrites |
| Developing from a phone (no PC or IDE) | GitHub Actions builds every target. Android debug APKs are signed with a fixed keystore in CI secrets so updates install over each other. The engine is tested on Linux in CI |
| Apple builds | iOS and macOS builds need macOS runners. The repository is public, so standard GitHub-hosted runners cost nothing; check this if it goes private again **[Assumption: check current GitHub pricing]**. Distributing them needs a paid Apple Developer membership. Build Apple targets only on release branches or on demand |
| Device audio differences | miniaudio's per-platform backends, float output, restart on disconnect, early testing on the S22+ and each new platform; Oboe as an Android fallback |
| Touch code editing is clumsy | Symbol row (`t >> << & \| ^ ( ) ? :`), short files, live error line, a Flutter code editor with lightweight highlighting (pick a permissively licensed package, or write a small one) |
| Token leakage or over-broad access | Device flow, GitHub App limited to selected repos, platform secure storage (Android Keystore, Apple Keychain, Windows Credential Manager, Linux Secret Service), no shipped secrets |
| Licensing | Use only permissive dependencies (miniaudio public domain/MIT-0, Flutter BSD-3, any NKIDO use MIT), avoid GPL. Don't bundle community bytebeat formulas without permission. Choose the app license and library license (e.g. CC0/MIT for modules) **before** accepting outside contributions |
| Selling only through AutoStacc (owner) | **[Proposal]** Android: one release signing key kept for good in repository secrets (every update must be signed with it), plus clear install steps on the AutoStacc page. Windows: code-sign installers so SmartScreen doesn't block them. macOS: sign and notarize with an Apple Developer account. A privacy policy is needed everywhere (the app stores GitHub tokens) |
| iOS can't be sold only through AutoStacc | **[Fact]** Outside the App Store, iOS apps can only be distributed through alternative marketplaces in the EU (and now Japan). That requires Apple's approval, notarization and an organization account ([Apple](https://developer.apple.com/support/alternative-app-marketplace-in-the-eu), 2026-10-28). iOS realistically means the App Store, so it's an open question in [vision](vision.md#open-questions) |

## C++ creation platform architecture

The earlier proposal to keep readable .caw source authoritative and add visual controls around that language is superseded by the owner's 2026-11-05 C++ decision. The target is ordinary C++, a comprehensive C.A.W. Library/SDK, and one shared component model across the code editor, visual composition and generated/custom performance UI. Components are authored once and reused through the native runtime, component browser, mixer and later CLAP/VST3/standalone adapters.

See [C++ creation platform](cpp-creation-platform.md) for the full component descriptor, typed port and parameter contracts, library categories, editor and visual-scripting requirements, generated/custom UI, MIDI/event model, real-time safety, trust boundaries, versioning, migration and verification gates.

## Sources

- miniaudio: https://github.com/mackron/miniaudio
- Flutter platforms: https://docs.flutter.dev/reference/supported-platforms
- Compose Multiplatform stability: https://kotlinlang.org/docs/multiplatform/supported-platforms.html
- Oboe (Android fallback): https://github.com/google/oboe
- NKIDO: https://github.com/mlaass/nkido · [ADC Japan 2026 talk listing](https://adcjapan26.sched.com/event/2KCfA)
