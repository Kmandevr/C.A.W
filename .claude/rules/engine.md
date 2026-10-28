---
paths:
  - "engine/**"
---

# Sound engine (C++)

The design is in `docs/architecture.md` ("Audio and code execution"); this is the checklist for touching it.

- **Portable core.** No Android, JNI or OS headers outside `engine/platform/`. The same core builds for Android (NDK), the Linux CLI used by CI and AI agents, and later WASM.
- **Audio thread.** In the callback and everything it calls: no allocation, no locks, no logging, no I/O, no JNI, no exceptions, no unbounded loops. Programs arrive through a lock-free swap and are freed off the audio thread.
- **Sandbox by construction.** The language has no I/O or system access. Enforce limits on source size, AST depth, program size, memory, loop bounds and per-block cost; when one is exceeded, fail closed (silence that module, report an error), never crash.
- **Defined arithmetic.** Int32 wraparound for bitwise ops, division and modulo by 0 give 0, NaN/Inf become 0, and the safety limiter is always last. Same source and settings give the same samples on every device (golden-render tests check this).
- **Tests.** Every language feature or DSP built-in gets a unit test and, where it makes sound, a golden render. A bug fix starts with a failing test. Never skip or weaken a test to get green.
- Start each file with a one-line `//` comment saying what it is for (the repo map reads it).
