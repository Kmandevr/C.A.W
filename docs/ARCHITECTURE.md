# Architecture

Labels used below:
- **[Fact]** is verified, either in this repo or from a primary source. The date is noted when it matters.
- **[Proposal]** is a recommendation that is open to change.
- **[Assumption]** has not been verified yet and needs checking.

## 0. Current state

- **[Fact]** As of 2026-10-28 the repository was empty: no commits, no code. Nothing exists to reuse.

## 1. Technology stack

| Layer | Choice | Why |
| --- | --- | --- |
| UI | **Kotlin + Jetpack Compose** | Native Android, current Google standard, good for compact, panel-based touch UIs |
| Audio I/O | **Oboe** (C++, via NDK) | Low-latency standard on Android. Picks AAudio or OpenSL ES per device |
| Sound engine | **Custom C++ core** (C++20), no Android dependencies | Real-time safe, sandboxed by design, and the same core builds for Android, a Linux CLI (CI/AI validation) and later WASM |
| Bridge | Thin JNI layer | Only control messages cross it. No audio data and no per-sample calls |
| Build | Gradle + CMake, **built in GitHub Actions** | You work from a phone: CI builds the APK and you install it from the artifact |

- **[Fact]** Oboe is Apache-2.0, supports API 16+, and uses AAudio on API 27+. ([github.com/google/oboe](https://github.com/google/oboe))
- **[Proposal]** `minSdk 27` (Android 8.1) so that every device gets AAudio. This keeps the audio path simpler.

### Rejected alternatives

- **WebView + Web Audio:** fastest to prototype, but latency on Android WebView is higher and less predictable, and JS garbage collection causes audio dropouts. Not good enough for an instrument.
- **Embedded JS or Lua (QuickJS, LuaJIT) running user code:** both have garbage collection, unbounded loops and a large attack surface. They can't run safely on the audio thread. Rendering ahead into a buffer adds latency and still glitches.
- **Flutter / React Native:** these add a second runtime on top of the native audio code they still need. That's extra complexity for no gain here.

## 2. Audio and code execution

The central decision: **user code is compiled into bytecode for our own small VM, and that VM runs inside the C++ engine.** The source is never interpreted on the audio thread.

```
 source text ──► parser/compiler (worker thread) ──► Program (bytecode + constants)
                                                        │ atomic pointer swap
 Oboe callback (audio thread) ◄── VM runs Program ◄─────┘   (+ short crossfade)
```

- **The sandbox comes from what the language can't do.** It has no I/O, no filesystem, no network and no system calls. Memory is fixed-size and allocated before playback. Loops are bounded and the call depth is capped. Downloaded modules are therefore no more dangerous than local ones.
- **Audio-thread rules:** no allocation, no locks, no JNI and no logging inside the callback. Programs are handed over through a single-slot atomic swap, and old programs are freed off the audio thread.
- **Block processing:** the VM runs each opcode over a block of samples (for example 64) rather than one sample at a time. This cuts interpreter overhead a lot.
- **Cost guard:** the engine measures time spent per callback. If it overruns repeatedly, it fades out and reports "too expensive" instead of stuttering.
- **Ear and speaker safety:** NaN/Inf values are replaced with 0, DC is blocked, and a hard safety limiter runs last. Default output gain is low. Glitch audio can go to full-scale noise instantly.
- **Defined arithmetic:** bitwise operations use int32 with wraparound, division or modulo by 0 returns 0, and other math uses float. Output has two modes: *byte* (`v & 255` mapped to −1…1, classic bytebeat) and *float* (clamped to −1…1). This makes renders deterministic and portable across devices.
- **Sample rates:** a bytebeat `t` counts at the *formula rate* (8 kHz by default, user-selectable). The engine upsamples to the device rate with zero-order hold, which keeps the crunch. Procedural instruments run at the device rate. WAV export runs at 44.1 or 48 kHz.
- **Offline render = same VM.** WAV export runs the identical program on a worker thread, faster than real time, so the export matches what you heard.
- **Background playback:** use a foreground service with the `mediaPlayback` type, which Android 14+ requires. Device changes such as headphones being unplugged trigger a stream restart.

### Language direction **[Proposal]**

- Accept the **JS-style bytebeat expression subset** first (`t`, `>> << & | ^ % * / + -`, ternary, `sin`, `floor`…), so formulas from the community paste in and work.
- Then add, in this order: `let` bindings, user functions, `param` declarations (these generate UI sliders), `use` imports of library modules, and stateful built-ins (delay lines, filters, envelopes, noise).
- Add a sequencing mini-language in Stage 5, designed for phone typing, e.g. `kck p8 snr p16 hat*3 @ 140`. It compiles into the same VM. Polyrhythm comes from independent loop lengths against a shared clock.

### NKIDO evaluation

- **[Fact]** As of 2026-10-28: [mlaass/nkido](https://github.com/mlaass/nkido) is MIT-licensed, C++20/CMake, and pairs a stack-based bytecode synthesis VM ("Cedar") with a Tidal-style language ("Akkado"). It supports hot-swap with crossfade and runs natively and in the browser via WASM. The project is small: 8 stars and essentially one developer.
- **[Assumption]** Unverified: an Android/NDK build, a stable embedding API, and long-term maintenance.
- **[Proposal]** Don't depend on it for Stage 1. A bytebeat VM is small enough to own. NKIDO uses the same architecture recommended here, which supports the design. At Stage 2, do a 1-day spike to judge whether Cedar could serve as the graph/DSP layer. Keep our engine behind an interface (`compile(source) → Program`, `process(Program, buffer)`) so we can swap the backend either way.

## 3. Source and module structure

### This repo (Repository A — app) **[Proposal]**

```
engine/        C++ core: lexer, parser, compiler, VM, DSP built-ins, WAV writer (no Android deps)
engine/cli/    Linux/macOS CLI: `caw check`, `caw render` (used by CI and AI agents)
engine/tests/  Golden-render tests (hash of rendered output per example)
android/       Gradle project: Compose UI, JNI bridge, Oboe stream, storage, sync
docs/          These docs + language reference
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
- **Separate updates:** APK updates come from releases or the Play Store. Library updates come from git. Neither requires the other.

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
| Developing from a phone (no Android Studio) | GitHub Actions builds signed debug APKs (fixed keystore in CI secrets so updates install over each other). The engine is tested on Linux in CI |
| Device audio differences | Oboe, float output, restart on disconnect, early testing on your actual phone |
| Touch code editing is clumsy | Symbol row (`t >> << & \| ^ ( ) ? :`), short files, live error line, Compose `BasicTextField` with lightweight highlighting |
| Token leakage or over-broad access | Device flow, GitHub App limited to selected repos, Keystore storage, no shipped secrets |
| Licensing | Use only permissive dependencies (Oboe Apache-2.0, any NKIDO use MIT), avoid GPL. Don't bundle community bytebeat formulas without permission. Choose the app license and library license (e.g. CC0/MIT for modules) **before** accepting outside contributions |
| Play Store policy | Foreground-service type declarations, target SDK deadlines and a privacy policy (the app stores GitHub tokens) |

## Sources

- Oboe: https://github.com/google/oboe
- NKIDO: https://github.com/mlaass/nkido · [ADC Japan 2026 talk listing](https://adcjapan26.sched.com/event/2KCfA)
