---
paths:
  - "engine/**"
---

# Sound engine (C++)

The design is in `docs/architecture.md` ("Audio and code execution"); this is the checklist for touching it.

- **Portable core.** No OS, audio-API or UI headers outside `engine/platform/`. The core is currently CI-verified on Linux x64, Linux Arm64 and Windows x64, and is built into the Android app. iOS/macOS engine builds and WASM are portability targets, not currently verified CI targets. The desktop CLI is used by CI and external coding tools. Audio output goes through miniaudio in `engine/platform/`.
- **Audio thread.** In the callback and everything it calls: no allocation, no locks, no logging, no I/O, no calls into the app, no exceptions, no unbounded loops. Chains and patterns arrive through a lock-free queue and are freed off the audio thread.
- **Native code is trusted code.** Components run in-process, unsandboxed; one loads only under the user's explicit per-item trust choice. Do not claim third-party native modules are isolated or safe to load until process isolation and host validation exist. Project input (patterns, project JSON, WAV and MIDI files) is untrusted: parse it with explicit limits and fail closed, with an error that names the problem.
- **C API.** The app calls the engine only through a small, versioned C API (plain structs and functions, no C++ types across it), so `dart:ffi` and any future host can bind it.
- **Defined arithmetic.** Outputs are sanitised (NaN/Inf become 0) and the safety limiter is always last. Same project and settings sound perceptually identical on every device, live and in export, checked by tolerance tests against reference renders; note, clip and automation timing, seeded random choices and discrete behaviour stay exact (owner, 2026-11-12, `docs/decisions.md`).
- **Tests.** Every DSP built-in gets a unit test and, where it makes sound, a reference render: a tolerance test (`engine/tests/tolerance.h`; stable paths null below −120 dBFS, chaotic ones match in loudness, spectrum and onsets), re-recorded with `caw_tests --update-references` only for an intended sound change; engine tests play `org.caw.test.osc` (`engine/tests/test_signal.h`) or a built-in. A bug fix starts with a failing test. Never skip or weaken a test to get green.
- Start each file with a one-line `//` comment saying what it is for (the repo map reads it).
- **Bits are per build** (fast-math flags: Arm64 fuses multiply-adds, x86-64's baseline has none, Clang and GCC reassociate differently). Bit-exact compat tables need one per build (x86-64, Arm64, win64, x64 Debug; a missing one only prints). `_caw_fp_strict` on a file makes it identical everywhere but changes its x86-64 bits, breaking those tables; `-ffp-contract=off` alone keeps x86-64's bits but changes Arm64's. Chaotic devices (Timber's bowed string) differ by up to ~1 dB between compilers whatever the flags: compare per-device loudness before spending time on flags.
- **Reproduce off-CI:** `aarch64-linux-gnu-g++` + `qemu-aarch64` (a static Release build of `caw_core` and a small render harness) and `clang++` (its RelWithDebInfo `caw_core` is LTO bitcode: link with `-flto -fuse-ld=lld`) both work in the cloud container.
- **Cost ceilings:** cost tests are `RUN_SERIAL`; CI runners read 10–20 % slower than a local x86 box, Arm64 more: set a new ceiling about 1.4× the local x86 figure. A Debug sanitizer `libcaw` is over the pre-load scan's 256 MiB limit.
