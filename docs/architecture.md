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

- **[Fact]** As of 2026-10-28 there is no application code. The repository holds this plan in `docs/`, the docs guard in `scripts/`, CI in `.github/` and the agent setup in `.claude/`. The `engine/`, `app/` and `examples/` folders below are planned, not built.

## 1. Technology stack

**Targets (owner, 2026-10-28):** Android, iOS, Windows, macOS and Linux, with the web as a later extra. Android comes first, because the owner's phone (a Galaxy S22+) is the test device.

| Layer | Choice | Why |
| --- | --- | --- |
| Sound engine | **Custom C++20 core** (owner, 2026-10-28), no platform dependencies | Real-time safe and sandboxed by design. The same code runs on every target, in a Linux CLI for CI and AI agents, and later as WASM for the web |
| Audio I/O | **miniaudio**, behind a small `engine/platform/` interface | One C library for every target: AAudio on Android, Core Audio on iOS and macOS, WASAPI on Windows, ALSA/PulseAudio on Linux. Public domain or MIT-0 |
| UI | **Flutter** [Proposal, owner to confirm] | One UI codebase for all five targets. One bridge to the engine everywhere (`dart:ffi`). Dart never touches audio samples, so its garbage collector can't cause dropouts |
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
| Audio output on every platform | [miniaudio](https://github.com/mackron/miniaudio) | Public domain / MIT-0 | Milestone 1 |
| WAV (and FLAC) writing, lock-free FIFOs, sinc interpolation | [CHOC](https://github.com/Tracktion/choc) | ISC | Milestone 1 |
| Catching allocations and locks on the audio thread | Clang [RealtimeSanitizer](https://clang.llvm.org/docs/RealtimeSanitizer.html) (`[[clang::nonblocking]]`, `-fsanitize=realtime`) in CI | Part of LLVM | Milestone 1 |
| Crash-hunting the parser and compiler | libFuzzer with AddressSanitizer and UBSan in CI | Part of LLVM | Milestone 1 |
| Dart bindings to the engine's C API | `ffigen` (generates them from the C header) | **[Assumption: check licence]** | Milestone 1 |
| Filters, delays, FFT, envelopes, spectral tools | [Signalsmith DSP](https://github.com/Signalsmith-Audio/dsp) | MIT | Stage 2 |
| Oscillators, filters, effects, synthesized drum voices | [DaisySP](https://github.com/electro-smith/DaisySP) (the MIT library only, never DaisySP-LGPL) | MIT | Stage 2 |
| Reference DSP algorithms | [Soundpipe](https://github.com/PaulBatchelor/Soundpipe) (archived January 2024: read and port, don't depend on it) | MIT | Stage 2 |
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
- **Defined arithmetic:** bitwise operations use int32 with wraparound, division or modulo by 0 returns 0, and other math uses float. Output has two modes: *byte* (`v & 255` mapped to −1…1, classic bytebeat) and *float* (clamped to −1…1). This makes renders deterministic and portable across devices.
- **Sample rates:** a bytebeat `t` counts at the *formula rate* (8 kHz by default, user-selectable). The engine upsamples to the device rate with zero-order hold, which keeps the crunch. Procedural instruments run at the device rate. WAV export runs at 44.1 or 48 kHz.
- **Offline render = same VM.** WAV export runs the identical program on a worker thread, faster than real time, so the export matches what you heard.
- **Background playback:** each platform has its own rule. Android needs a foreground service with the `mediaPlayback` type (required on Android 14+), and iOS needs the audio background mode. Desktop has no restriction. Device changes such as headphones being unplugged trigger a stream restart.

### Language direction **[Proposal]**

- Accept the **JS-style bytebeat expression subset** first (`t`, `>> << & | ^ % * / + -`, ternary, `sin`, `floor`…), so formulas from the community paste in and work.
- Then add, in this order: `let` bindings, user functions, `param` declarations (these generate UI sliders), `use` imports of library modules, and stateful built-ins (delay lines, filters, envelopes, noise).
- Add a sequencing mini-language in Stage 5, designed for phone typing, e.g. `kck p8 snr p16 hat*3 @ 140`. It compiles into the same VM. Polyrhythm comes from independent loop lengths against a shared clock.

### NKIDO evaluation

- **[Fact]** As of 2026-10-28: [mlaass/nkido](https://github.com/mlaass/nkido) is MIT-licensed, C++20/CMake, and pairs a stack-based bytecode synthesis VM ("Cedar") with a Tidal-style language ("Akkado"). It supports hot-swap with crossfade and runs natively and in the browser via WASM. The project is small: 8 stars and essentially one developer.
- **[Assumption]** Unverified: Android and iOS builds, a stable embedding API, and long-term maintenance.
- **[Proposal]** Don't depend on it for Stage 1. A bytebeat VM is small enough to own. NKIDO uses the same architecture recommended here, which supports the design. At Stage 2, do a 1-day spike to judge whether Cedar could serve as the graph/DSP layer. Keep our engine behind an interface (`compile(source) → Program`, `process(Program, buffer)`) so we can swap the backend either way.

## 3. Source and module structure

### This repo (Repository A — app) **[Proposal]**

Already in place: `docs/`, `scripts/`, `.github/`, `.claude/`. Planned:

```
engine/          C++ core: lexer, parser, compiler, VM, DSP built-ins, WAV writer (no platform deps)
engine/platform/ Audio output (miniaudio) and the C API the app calls
engine/cli/      Desktop CLI: `caw check`, `caw render` (used by CI and AI agents)
engine/tests/    Golden-render tests (hash of rendered output per example)
app/             Flutter app for every target: UI, editor, files, sync; per-platform folders inside
docs/          These notes + language reference (exists)
examples/      Bundled starter sounds in the module format (later mirrored to the library)
```

### Sound library (Repository B, created in Stage 2/3)

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

### Module file **[Proposal]**

One plain-text file per module: a small metadata header followed by code. Single files are easy for AI agents to edit and produce clean git diffs.

```
---
caw: 1                 # module format version
kind: effect           # instrument | effect | function | pattern | project
name: bitcrush
params:
  bits: { default: 6, min: 1, max: 16, step: 1 }
---
<code>
```

- Modules are referenced by path (`use effects/bitcrush`). Projects pin the library to a **commit SHA**, so an old project always sounds the same.
- The app declares which format versions it supports. It lists incompatible modules but never loads them.

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
| Apple builds | iOS and macOS builds need macOS runners, which bill private repositories at a higher per-minute rate **[Assumption: check current GitHub pricing]**. Distributing them needs a paid Apple Developer membership. Build Apple targets only on release branches or on demand |
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
