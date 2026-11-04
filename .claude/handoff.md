# Handoff

Commit: 0f46ef7
Branch: claude/caw-engine-foundation-skpirb (F4.4 on top of Main 94522a5; PR to Main next)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F4 → F5 → F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
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
- On Main: F3 (#72), F4.1 (#74), F4.2 (#75), F4.3 (#77).
- F4.4 is on the branch (`d593f3f`, `f6ed0f4`, `0f46ef7`): every track module is a graph node, connected by 3-lane float edges, with `planChunk` and `prepareRouted`.
  - Tests: caw_tests 240/240, caw_rt_tests 33/33.
  - The new hashes equal the old engine plus float rounding of each module's output (checked in a scratch worktree).
  - The audio review is addressed: forward same-layer imports are refused. Issue #78 is filed for the older swap-fade export renumbering.

## Open
- Issue #78: the swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.

## Next
1. Open the F4.4 PR to Main and merge when CI is green.
2. Then F5: typed control, modulation, event and MIDI ports in the executor.

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `engine/src/graph.h`
- `engine/src/engine.cpp` (MixGraph, planChunk, runModuleNode)
