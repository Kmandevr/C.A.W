---
paths:
  - "engine/**"
---

# Sound engine (C++)

The design is in `docs/architecture.md` ("Audio and code execution"); this is the checklist for touching it.

- **Portable core.** No OS, audio-API or UI headers outside `engine/platform/`. The same core builds for Android, iOS, Windows, macOS and Linux, the desktop CLI used by CI and AI agents, and later WASM. Audio output goes through miniaudio in `engine/platform/`.
- **Audio thread.** In the callback and everything it calls: no allocation, no locks, no logging, no I/O, no calls into the app, no exceptions, no unbounded loops. Programs arrive through a lock-free swap and are freed off the audio thread.
- **`.caw` language boundary.** The user module language has no filesystem, network or system-call access and is subject to explicit source/program/state/execution limits. This does not sandbox native SDK modules: they execute as trusted in-process code. Do not claim third-party native modules are isolated or safe to load until process isolation and host validation exist.
- **C API.** The app calls the engine only through a small, versioned C API (plain structs and functions, no C++ types across it), so `dart:ffi` and any future host can bind it.
- **Defined arithmetic.** Int32 wraparound for bitwise ops, division and modulo by 0 give 0, NaN/Inf become 0, and the safety limiter is always last. Same source and settings give the same samples on every device (golden-render tests check this).
- **Tests.** Every language feature or DSP built-in gets a unit test and, where it makes sound, a golden render. A bug fix starts with a failing test. Never skip or weaken a test to get green.
- Start each file with a one-line `//` comment saying what it is for (the repo map reads it).
