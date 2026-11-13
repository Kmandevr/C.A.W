---
title: Architecture
summary: Technical architecture, verified engine/app boundaries and clearly labelled future design proposals.
updated: 2026-11-12
covers: [app/pubspec.yaml, engine/CMakeLists.txt]
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

**[Owner decision, 2026-11-05]** C.A.W. will use ordinary general-purpose C++ as its programming language, a comprehensive C.A.W. Library/SDK, and one shared component model for code, visual scripting and generated/custom performance interfaces. The .caw language and VM it replaced were removed on 2026-11-11 (#160); old projects are not kept. The detailed design, component contract, library scope, authoring interfaces, real-time boundaries, versioning and migration gates are in [C++ creation platform](cpp-creation-platform.md).

## 0. Current state

**[Fact, checked 2026-11-11]** The Flutter app has three sections, Build, Files and Arrange, shown as docking panels (`lib/ui/shell.dart`, `lib/ui/dock/`) with a glass look behind a Settings switch (`lib/ui/glass.dart`). It opens straight into the last project, with no startup screen, and its transport takes a typed or tapped tempo, undoes and redoes project edits, and pauses and resumes (Space) where it paused; Settings has a key bindings editor. There are CI build artifacts for Android and Windows. Linux is used for app analysis/tests and has a local runner, but is not a shipped app artifact. The portable C++20 engine is built/tested by CI on Linux x64, Linux Arm64 and Windows x64, plus Linux sanitizers. iOS and macOS app builds are not currently in the app workflow.

The current app and native implementation are documented in [App](app.md), [Engine](engine.md) and [Engine implementation status](engine-build-status.md). The app keeps every automation lane, point and pattern note the engine accepts (F7.1, 2026-11-04); the Engine grows past 64 layers within its memory budget (F7.3), and their export buffers share one project-wide budget (#133). The house synth, piano-roll expression editing, pattern generators, MIDI file import/export, native worker pool, adaptive workload planner and Engine Lab spectrum view have working implementations. Project-level module/global parameter automation is implemented (PR #68); WAV/SFZ multisample and stems export follow it in [roadmap](roadmap.md) Stage 0. USB/Bluetooth device I/O, audio import/editing, complete mixer routing and external binary plugin hosting are not implemented. GitHub sync and in-app AI features are not implemented or in the current product scope. Since 2026-11-03 one mix graph runs live playback and offline render: a node per module of each track (its generator or voice pool, then each effect), a track node, folder bus nodes and a master node, routed on the audio thread (Foundation F4.3, F4.4); the executor also runs typed sidechain, modulation and control ports (F5.1) and event ports (F5.2). The shared parameter resolver (F6.1, `engine/src/params.*`) runs in the graph executor, which passes every node its resolved parameter values (F6.2), with modulation links between nodes (F6.3), automation lanes played at the transport position (F6.4) and MIDI CC mappings from host events (F6.5); the Engine's own .caw params and globals resolve through it too (F6.6).

## 1. Technology stack

**Product targets (owner, 2026-10-28):** Android, iOS, Windows, macOS and Linux, with Android first. Web is not a current release target. The Galaxy S22+ is the primary Android test device. Product targets are not evidence that a platform build is currently shipped or CI-verified.

| Layer | Choice | Why |
| --- | --- | --- |
| Sound engine | **Custom C++20 core** (owner, 2026-10-28), platform separation under engine/platform/ | Portable core; currently CI-verified on Linux x64, Linux Arm64 and Windows x64, and built into the Android app. iOS/macOS/WASM builds are not currently CI-verified |
| Audio I/O | **miniaudio**, behind `engine/platform/` | Current host backends are selected in the platform layer; upstream miniaudio supports AAudio/OpenSL ES, Core Audio, WASAPI and ALSA/PulseAudio. Do not infer every backend is currently built or tested by this repository |
| UI | **Flutter** (owner, 2026-10-28) | One UI codebase; current CI builds Android and Windows app artifacts. Linux analysis/tests run, but Linux is not a shipped artifact; iOS/macOS app builds are not configured |
| Bridge | Thin C API over the engine, called through `dart:ffi` | Only control messages cross it (play, stop, swap program, set parameter, note previews, read meters). No audio data, no per-sample calls |
| Build | CMake for the engine, Flutter for the app, GitHub Actions CI | The engine target also builds the offline component testing suite (`caw test-component`). Each engine test file is registered in `engine/CMakeLists.txt` and `ctest` runs them in shards, then again with the mix graph on three pool workers, checking every reference render's bits against the first pass (`caw_parallel_identity`; `CAW_TSAN` builds with ThreadSanitizer for the pool's CI job); optimised engine builds are link-time optimised with Clang and MSVC. CI currently produces Android and Windows app artifacts and verifies Linux/Windows engine targets; it does not produce every target's installable |

- **[Fact]** miniaudio is public domain or MIT-0 (your choice). Its backends are AAudio (Android 8.0+) and OpenSL ES on Android, Core Audio on macOS and iOS, WASAPI on Windows, and ALSA on Linux. ([github.com/mackron/miniaudio](https://github.com/mackron/miniaudio), 2026-10-28)
- **[Fact]** Flutter 3.47 supports Android API 24–37, iOS 15+, Windows 10/11, macOS 12+, Debian 10+ and Ubuntu 20.04+ on x64 and Arm64, plus the web. ([docs.flutter.dev](https://docs.flutter.dev/reference/supported-platforms), 2026-10-28)
- **[Fact]** The Galaxy S22+ runs Android 16 (One UI 8), its last major update. ([mezha.media](https://mezha.media/en/news/one-ui-8-for-galaxy-s22-305386))
- **[Proposal]** Android `minSdk 26` (Android 8.0): every device gets AAudio, and Flutter's floor is lower anyway.
- **[Proposal]** Android is the only platform where Oboe would matter. Keep miniaudio unless latency tests on the S22+ fall short. If they do, add an Oboe backend behind the same `engine/platform/` interface. Oboe is Apache-2.0, [github.com/google/oboe](https://github.com/google/oboe).

### Engine shape: one core, three hosts

The owner may also ship C.A.W as a VST3/CLAP plugin. So the core is plugin-shaped from day one and knows nothing about who drives it:

- **Hosts:** miniaudio in the standalone app; a DAW such as Reaper through the plugin; the CLI for checks and offline WAV renders.
- **Interface:** `prepare(sampleRate, maxBlock)`, `process(block, events)`, automatable parameters, MIDI note input, the host's tempo and transport (so the sequencer follows the DAW), and state save/load (the sound code plus parameter values).
- **Fully standalone (owner):** every build runs on its own and offline. No server, account or network is needed to make sound; GitHub sync is optional. The beta's anonymous telemetry and optional feedback, sent over HTTPS to the C.A.W-Telemetry relay ([app](app.md#privacy-telemetry-and-feedback)); audio processing stays local.
- **Plugin UI:** later. Flutter doesn't embed in plugin windows, so a plugin starts with the host's generic parameter controls.

### Ready-made building blocks

The C++ language and compiler are ordinary toolchain facilities; the C.A.W. Library/SDK and component model are the product-specific reusable layer. Use permissively licensed, maintained dependencies where they provide a measured benefit, and record exact licences and versions before adoption. The dependency candidates below are proposals, not adopted dependencies.

| Job | Library | Licence | When |
| --- | --- | --- | --- |
| Audio output on every platform | [miniaudio](https://github.com/mackron/miniaudio) | Public domain / MIT-0 | v1 |
| FLAC writing, sinc interpolation, if needed | [CHOC](https://github.com/Tracktion/choc) | ISC | Later (v1 writes WAV and passes messages with its own small code) |
| Catching allocations and locks on the audio thread | Clang [RealtimeSanitizer](https://clang.llvm.org/docs/RealtimeSanitizer.html) (`[[clang::nonblocking]]`, `-fsanitize=realtime`) in CI | Part of LLVM | v2 (v1 CI runs AddressSanitizer and UBSan, and ThreadSanitizer on the mix pool) |
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

**[Fact, 2026-11-11]** Sound is native C++: built-in components and the user's own, all on one component contract (`engine/include/caw/module.hpp`, the plain-C interface in `caw_component.h`). The .caw language, its compiler and VM were removed (#160, owner 2026-11-10). A track is an instrument component and its effect components; the control thread builds and activates them, and the audio thread runs them.

```
 project JSON ──► control thread: parse patterns, build + activate component chains
                                                        │ lock-free command queue
 audio callback (audio thread) ◄── mix graph: tracks, buses, master ◄─┘   (+ 20 ms crossfade on a change)
```

- **Trust, not a sandbox:** a component is in-process code. A third-party binary loads only with the user's per-item trust choice (Blocked, Isolated, Trusted; [decisions](decisions.md)); Isolated waits for a separate-process host. Project input (patterns, project JSON, audio and MIDI files) is parsed with explicit limits.
- **Audio-thread rules:** no allocation, no locks, no calls into the UI layer and no logging inside the callback. Chains, patterns and tables arrive through the command queue, and what they replace is freed off the audio thread.
- **Fixed blocks at the device (2026-11-12, the owner's idea):** a playback device's callback, whatever its size, takes frames from a preallocated FIFO that renders whole 64-frame engine blocks, so the engine sees the same blocks on every route as in an export; what it holds back (under a block) is in the reported output latency ([engine](engine.md), "Fixed engine blocks at the device").
- **Block processing:** components run blocks of up to 64 frames.
- **Arrangement scheduling:** clips are immutable instances that reference reusable pattern sources. On the control thread, CAW compiles their note events into one sorted absolute-time stream per track. The audio callback uses the existing block-boundary engine; it never parses patterns, allocates clip data or relies on UI timers. This keeps note timing independent of Flutter frame rate and avoids a separate scheduler thread.
- **Folder buses:** the control thread resolves a validated folder tree into slot routing indices and a child-before-parent render order. The callback sums child stereo buffers into each bus (since 2026-11-03 each child is rounded to 32-bit float and summed in float, as graph edges will carry it; bus and master processing stays 64-bit), applies bus gain and stereo balance, then routes the result upward exactly once. Organization-only folders have no audio slot. No routing graph is allocated or walked in the callback.
- **Track automation:** volume and pan points are copied into fixed-size slot arrays through the command queue. The callback interpolates against the current song step for each sample. The supported lane targets are deliberately limited to volume and pan in this implementation slice; global and plugin-parameter automation remain future work.
- **Cost guard:** the engine measures time spent per callback. If most callbacks overrun for about 0.3 s, it fades out the newest layer and reports it instead of stuttering; once the load has stayed low for 2 s, shed layers fade back one at a time, only where they fit ([engine](engine.md), "Overload, and coming back").
- **Ear and speaker safety:** NaN/Inf values are replaced with 0, DC is blocked, and a hard safety limiter runs last. Default output gain is low. Glitch audio can go to full-scale noise instantly.
- **Repeatable output** (see [Bits and determinism](#bits-and-determinism)).
- **Sample rates:** components run at the device rate. WAV export runs at 8 to 192 kHz (44.1 or 48 kHz in the app).
- **Offline render = same Engine.** WAV export runs the same mix graph on a worker thread, faster than real time, so the export matches what you heard.
- **Background playback:** each platform has its own rule. Android needs a foreground service with the `mediaPlayback` type (required on Android 14+); **[Fact, built 2026-11-12]** C.A.W runs one while playing or recording ([app](app.md)). iOS needs the audio background mode (not built). Desktop has no restriction. Device changes such as headphones being unplugged trigger a stream restart.

### Bits and determinism

The owner's requirement (2026-11-12, [decisions](decisions.md)): the same project, seed and settings sound **perceptually identical** on every platform, in playback, in the plugin and in WAV export, and on every run; identical bits are not required.

- **Exact:** note, clip and automation timing to the sample, every seeded random choice and discrete behaviour (triggers, step choices).
- **Randomness is seeded, never live:** a note's chance and the built-ins' noise come from the project seed and counter-based hashes, so jumping to any position gives the same result.
- **Floats may differ in the last bits:** tolerance tests against reference renders (a null residual below −120 dBFS on stable paths; loudness and per-band spectrum on chaotic ones) replace bit-exact golden hashes (**[Fact, 2026-11-12]** built: `engine/tests/tolerance.h`, references in `engine/tests/references/`; FMA and fast-math test builds pass them all), so faster maths (flush-to-zero, FMA, approximations, float paths, parallel mixing in a fixed order) is allowed where they pass. **[Fact, 2026-11-12]** Built (speed phase 2): the engine's own code builds with fast-math subsets (FMA contraction, reassociation, no signed zeros or errno; never finite-math-only, so the NaN/Inf guards hold) and its audio thread flushes subnormals to zero; `CAW::SDK` keeps the strict IEEE flags for components ([engine](engine.md), "Determinism"). The built-ins still use `caw/detmath.hpp` maths.

### Instruments, wavetables and samples — current status and remaining design

The owner wants code-defined sounds to become playable instruments and exportable audio assets. **[Fact, 2026-11-11]** C.A.W. has WAV loop, free-length, one-shot and wavetable export of C++ instruments. **[Fact, 2026-11-10]** Native C++ instruments (an event input and a stereo output, owning their voices) play a track's notes, with the built-in `org.caw.synth.basic` ([native module SDK](native-module-sdk.md#writing-an-instrument), #156). A sample editor, imported audio assets, multisample mapping and SFZ export are not implemented. The design details below are proposals for remaining extensions, not a claim that every output path exists.

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

### Patterns and parameters

**[Fact, 2026-11-11]** A project's modules are note patterns (the note-clip text the piano roll edits, #158): notes with velocity, chance, ratchets, slides and per-note expression curves, MIDI file import and export. They play a track's instrument as frame-accurate note events. Parameters are components' (and automation lanes target them); the shared parameter resolver is in [Engine implementation status](engine-build-status.md).

### Live editing while playing

**[Fact]** A pattern edit swaps in at the next block, and a sounding note follows it from the playhead ([engine](engine.md#patterns)); a changed instrument or chain is built off the audio thread and crossfaded in over 20 ms, held notes moving to a new instrument; a rebuilt user component replaces the old build the same way, keeping each instance's values and (where it accepts it) state.

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

The full proposed scope and contracts are in [C++ creation platform](cpp-creation-platform.md). The [visual creation and signal routing design](visual-routing-and-library-integration.md) defines the component editor, project/track workspace, conditional routing and reuse candidates. The current built-ins are listed in [engine](engine.md); do not mark planned SDK functionality as built.

### Shared MIDI and event routing [Proposal]

C++ components, visual blocks, the performance UI and external device adapters use one event model. It covers MIDI 1.0, MIDI 2.0 UMP, note identity, note-on/off, velocity, pitch, pressure, per-note expression, CC, program changes, clock, transport and timestamped events. Device I/O remains a separate adapter/integration task; a component does not get a private MIDI implementation.

### Real-time boundary [Proposal]

C++ itself remains general-purpose. Only code scheduled in the audio callback must meet the explicit real-time contract: bounded work, no allocation/free, blocking locks, I/O, logging or UI calls. The Engine host preallocates its master-chain buffers, performs no host allocation/locking in the callback, sanitizes component output and keeps the safety limiter after native processing; old component chains are retired off the callback. The current loader refuses Blocked before opening a library, rejects Isolated until a separate-process host exists, and loads Trusted in-process only after an explicit caller choice. Trusted component code can still violate real-time rules or access process memory; the host cannot sandbox it.

## 3. Source and component package structure

### This repository (C.A.W.)

The current repository contains the portable C++20 engine and CLI, platform audio layer, Flutter app (whose bundled assets are the code font, the crow logo and the default project), tests, documentation and bundled examples.

### C++ component source

**[Fact, checked 2026-11-06]** The existing native module processor contract is exposed to C++ component authors through `engine/include/caw/module.hpp`; `CAW::SDK` is now an installable CMake package exporting this include directory and C++20. The internal `engine/src/module.h` forwards to the public declaration, and engine-internal `engine/src` headers are not propagated to consumers. CP.1 now includes a versioned `caw.component` manifest, CMake shared-library helper, exported descriptor/create/destroy entry points, structured diagnostics and a Linux/Windows/Android repository-CI matrix (PR #125; the component matrix is still being verified). The working integration branch also persists project-owned C++ source/dependency pins, builds locally with CMake and returns a verified artifact path. `ModuleRegistry`/Engine C API load a component only after explicit trust; Dart FFI calls load/unload on a background isolate. native stereo effects run with their parameters on tracks (`LayerDoc.components`, after the track's chain and before volume and pan) and on the master (`ProjectDoc.masterComponents`, before the safety limiter). The per-component trust UI/store and Android-hosted compiler package remain outstanding. **[Proposal]** Components use ordinary C++ source and headers with supported project/build metadata and declared dependencies. A component may span multiple files and use ordinary C++ libraries. Its descriptor is registered with the shared component system; no special-purpose .caw syntax or separate component language is required. Existing CMake/native build conventions are the starting point, with supported imported-project/build configurations documented by the editor.

### Reusable library and project assets

The planned C.A.W. Library can contain reusable C++ components, functions, instruments, effects, generators, data utilities, presets, examples and assets. Project-local assets travel with the project; global-library references use stable IDs and explicit versions. Asset handles define ownership and lifetime so sample buffers, tables and impulse responses are not copied unnecessarily.

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

The GitHub library-sync/source-picker workflow described in earlier proposals is also not implemented. The app currently works with local project files and operating-system import/export; the beta's telemetry and feedback go to the C.A.W-Telemetry relay ([app](app.md#privacy-telemetry-and-feedback)). Any future GitHub integration requires a separate owner decision, security review and implementation plan.

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
| Licensing | Use only permissive dependencies (miniaudio public domain/MIT-0, Flutter BSD-3, the CLAP headers MIT for plug-in export, any NKIDO use MIT), avoid GPL. Don't bundle community bytebeat formulas without permission. The app is Apache-2.0 (owner, 2026-11-09); choose the licence for shared modules and bundle content **before** accepting outside contributions |
| Distributing through AutoStacc (owner) | **[Proposal]** Android: one release signing key kept for good in repository secrets (every update must be signed with it), plus clear install steps on the AutoStacc page. Windows: code-sign installers so SmartScreen doesn't block them. macOS: sign and notarize with an Apple Developer account. A privacy policy is needed everywhere (the app stores GitHub tokens) |
| iOS can't be distributed only through AutoStacc | **[Fact]** Outside the App Store, iOS apps can only be distributed through alternative marketplaces in the EU (and now Japan). That requires Apple's approval, notarization and an organization account ([Apple](https://developer.apple.com/support/alternative-app-marketplace-in-the-eu), 2026-10-28). iOS realistically means the App Store, so it's an open question in [vision](vision.md#open-questions) |

## C++ creation platform architecture

The earlier proposal to keep readable .caw source authoritative and add visual controls around that language is superseded by the owner's 2026-11-05 C++ decision. The target is ordinary C++, a comprehensive C.A.W. Library/SDK, and one shared component model across the code editor, visual composition and generated/custom performance UI. Components are authored once and reused through the native runtime, component browser, mixer and later CLAP/VST3/standalone adapters.

See [C++ creation platform](cpp-creation-platform.md) for the full component descriptor, typed port and parameter contracts, library categories, editor and visual-scripting requirements, generated/custom UI, MIDI/event model, real-time safety, trust boundaries, versioning, migration and verification gates.

## Per-note processing (#127) and descriptor domains (#120)

The owner put per-note effects in the beta ([decisions](decisions.md), 2026-11-11, "The beta's scope"). Steps 1–3 are built (branch `note-fx`, 2026-11-11) and steps 4–7 (branch `note-fx-host`, the same day); note sources in the app's mod matrix remain. Engine details: [engine](engine.md#descriptor-domains-and-the-voice-bus-120-127).

### Domains and capabilities (#120) [Fact]

- `ModuleDescriptor` and `CawComponentDescriptor` end with `domains` (Whole 1, PerChannel 2, PerVoice 4, PerNote 8), `capabilities` (NotesIn, MidiIn, EventsOut, SampleAssets, NeedsTransport, ExportClap) and `cpuClass` (unspecified, light, medium, heavy: a hint, not a measurement). They are appended under the v3 growth rules as **revision 3.1** (`CAW_COMPONENT_ABI_REVISION 1`); the v3 entry symbol stays. A descriptor whose `struct_size` stops at `custom_ui_id` (`CAW_COMPONENT_DESCRIPTOR_SIZE_3_0`) reads as whole-only, no capabilities, unspecified cost; a C descriptor's `domains` 0 also reads as whole.
- Validation: `InvalidDomains` (an unknown bit, or Whole missing: every component runs whole), `DomainPortMismatch` (PerChannel needs one mono audio input and one mono output; PerNote and PerVoice need the effect shape, one stereo input and one stereo output, or the instrument shape, no audio input, one stereo output and an event input), `InvalidCapabilities` (an unknown bit, NotesIn or MidiIn without an event input, EventsOut without an event output, an unknown cost class). `moduleDescriptorsMatch` compares all three.
- It is called "domain", not "scope": `CAW_SCOPE_*` is already the oscilloscope in `caw.h`.
- Built-ins: stereo effects declare Whole|PerNote; keyed effects (sidechain), the racks and the limiter stay whole-only. For an instrument, PerNote means it exposes a voice bus (the Flagship, the drums, the test signal). The C++ SDK default is whole-only, so a third-party component runs per note only when its author says it can.

### Layout rules [Fact]

- A mono output feeding a stereo input is duplicated (L = R = the mono signal, unity, no pan law), in plain, summing and routed graph connections.
- Stereo into mono is refused (`ChannelLayoutMismatch`); it needs the explicit downmix `org.caw.downmix` (Average (L+R)/2, Left, Right). `org.caw.utility`'s Mono mode is stereo in and out, so it cannot feed a mono port. The downmix is internal (not listed) while track chains take stereo only.
- A mono-in, mono-out effect that declares PerChannel runs as dual mono, one instance per channel, through `ModuleRegistry::createDualMono`. Every other mismatch stays `ChannelLayoutMismatch`.

### The voice bus [Fact]

- `ProcessBlock::voices` and `CawProcessBlock.voices` (3.1) carry a `CawVoiceBus {struct_size, lane_count, lane_stride, lanes, host_data, run(host_data, offset, frames)}` of `CawVoiceLane {struct_size, note_id, flags, channel_count, channels[2]}`. Flags: the host sets ASSIGNED; the instrument sets WRITTEN and ENDED.
- The host fills lanes with the note ids it has slots for. For each stretch it renders, the instrument clears the assigned lanes' stretch, renders a matching voice into its lane instead of its mix, calls `run()` (the host processes the lanes in place), then adds every lane into its mix **before** its own shared stage. So the Flagship's effects and volume still come after per-note FX, and without a bus (`voices` null) the sound is bit-identical. Every frame of a block goes through exactly one `run()`, in order, also while no voice sounds (a lane's FX tail keeps the instrument awake).
- A voice with no lane goes to the mix. ENDED: no voice plays the lane's note at the block's end (it finished, was stolen or never started); a steal in `VoicePool` raises it at once. Mono and legato lanes follow the note the voice plays now. PerVoice is treated as PerNote. Expression is not copied into the lane: the host already has it in its events.
- `caw::VoiceLanes` (`caw/instrument.hpp`) is the instrument's side: `bind`, `laneFor`, `begin`, `runAndSum`, `end`, `endBlock`. The Flagship renders lanes within each control period (16 frames, so `run()` is called that often); the drums give each hit its lane, summed back into the output that hit plays to (its room send stays dry); the test signal gives each note its lane.

### The per-note FX host (NoteFxHost) [Fact: steps 4–7, branch `note-fx-host`, 2026-11-11]

- **Racks.** Per layer, `NoteFxRack` (`engine/src/note_fx_host.*`) builds B + 2 slot `ComponentChain`s (B = `noteVoices`, 1–16, the High cap; two spares let a stolen slot fade out while the new note starts on a fresh chain) and one overflow chain, all built and activated on the control thread (`ComponentChain::buildNoteEffects`: stereo effects, at most one event input each, every one declaring PerNote or PerVoice). Knob moves, values and bypass fan out to every chain. `NoteFxManager` hands each layer's rack, links and automation to the audio thread as a lock-free plan, as modulation does, and takes back what it retires.
- **The bus.** `NoteFxHost` owns a lane per slot and an overflow lane (`CAW_LANE_REST`, note id 0): every voice without a lane of its own renders there (`VoiceLanes::laneFor`; an instrument that predates the bit plays those voices dry). Lanes are in slot order, then overflow, so the instrument's sum is slots in index order, then overflow, from +0.0f.
- **Slot choice** (deterministic, at the note-on's frame): the lowest free slot while fewer than the budget hold notes; over budget, the oldest ended slot fades out (10 ms) or else the oldest released note's slot fades out while its sound crossfades into the overflow chain, and the new note takes the lowest free chain; else the note goes to overflow. Held notes are never stolen.
- **Timing** is in the host's own frames, never in blocks: a slot's chain starts on its note's frame; after ENDED it rings for its tail past its last sound (the chain's declared tail, at least 128 frames, at most 2 s), then fades over 10 ms and frees; the overflow chain stops the same way once its input is silent. So live playback at any buffer size and an export give the same bits (tested).
- **Expression:** each slot's event inputs get only its note's events; per-note link sources (`note.pitch`, `.velocity`, `.pressure`, `.timbre`, `.gate`, `.age`; `modulation_links.*`) are worked out per slot and frame, global modulator links once per chunk (`ModChainKind::NoteFx`) and added. Latency is the same for every slot and counts with the instrument's in the layer's compensation.
- **Swaps:** a new rack (other components or voice count) crossfades in over 20 ms in the same slots; turning per-note FX off crossfades back to the dry voices.
- **Project JSON, C API, quality:** per layer `"noteComponents"` and `"noteVoices"`; automation and links of kind `"noteComponent"`; `CAW_NOTE_COMPONENT` component indices; `caw_engine_note_fx_stats` (API 22). Live budget: Eco min(B, 4), Normal B, High min(B, 16), read at each note; nothing changes on CPU overload; an export uses the same rules. A project with per-note FX on an instrument without a voice bus, or an effect that can't run per note, is refused with a clear error.
- **CPU:** about (active slots + overflow) × the chain's per-instance cost while notes sound; free slots don't run. Figures in [engine](engine.md#per-note-fx-host-127-steps-46); phone figures are **[Assumption]** until measured on the S22+. Memory is the limit with large effects (18 × reverb.pro for 16 voices).
- **App:** a "Per note" section above the track effects in the FX stack, with a voice-budget chip and a dot per slot, and "Run per note" in an effect card's menu (greyed out with a reason). The look and the overflow default are to confirm ([decisions](decisions.md)). Note sources in the mod matrix are not in the app yet.

## Sources

- miniaudio: https://github.com/mackron/miniaudio
- Flutter platforms: https://docs.flutter.dev/reference/supported-platforms
- Compose Multiplatform stability: https://kotlinlang.org/docs/multiplatform/supported-platforms.html
- Oboe (Android fallback): https://github.com/google/oboe
- NKIDO: https://github.com/mlaass/nkido · [ADC Japan 2026 talk listing](https://adcjapan26.sched.com/event/2KCfA)
