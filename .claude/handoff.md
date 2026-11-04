# Handoff

Commit: b19c500
Branch: claude/caw-engine-foundation-skpirb (F5.1 on top of Main 011d495; audio review, then PR to Main)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F5 → F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
- One small PR per step, targeting `Main`. Claude merges when CI is green, and updates the #28 progress comment (id 6609966082).
- Rules:
  - No allocation, locks or I/O in the callback.
  - Exports stay bit-identical across platforms.
  - Stereo stays low-overhead: measure with callgrind, `caw_bench 1|2 N` difference / 250.
  - Never weaken tests; a bug fix starts with a failing test.
  - Run audio-reviewer and release-check before each PR.
  - Each PR updates the roadmap row and `docs/engine-build-status.md`.
- Ask the owner before SDK ABI changes, new dependencies, or app/ changes.

## Done and verified
- On Main: F3 (#72), F4.1–F4.4 (#74, #75, #77, #79). F4 is complete.
- F5.1 is on the branch (`1ac3a64`, docs `b19c500`): typed audio, modulation and control ports per node, with per-port executor tables, `processPorts`/`usesProcessPorts` checked at prepare, and only the first audio input fed by the host.
  - Tests: caw_tests 240/240, caw_rt_tests 40/40, sanitizers clean.
  - Callgrind: playback +0.05–0.09%, graph bench +0.8%.

## Open
- The F5.1 audio review is done: no defects; both hardening items are fixed test-first (held control values saturate; reserveRouting after process unbinds stale host buffers). Tests: caw_rt_tests 42/42.
- F5.2 event format: owner decision needed. The architect recommends a C.A.W event with a note id, carrying raw UMP; see `docs/decisions.md` (2026-11-04).
- Issue #78: the swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.

## Next
1. The F5.1 PR to Main is open; merge it when CI is green.
2. Ask the owner about the event format, then F5.2 (event ports).

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `engine/src/module.h`
- `engine/src/graph.h`
