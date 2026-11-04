# Handoff

Commit: 57aa9d9
Branch: claude/caw-engine-foundation-skpirb (F7.3 part A on top of Main 83556f2; PR to Main)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
- One small PR per step, targeting `Main`. Claude merges when CI is green, and updates the #28 progress comment (id 6609966082).
- Rules: no allocation, locks or I/O in the callback; exports bit-identical across platforms; stereo low-overhead (callgrind, `caw_bench 1|2 N` difference / 250); never weaken tests, and a bug fix starts with a failing test; audio-reviewer (engine) or code-reviewer (app) and release-check before each PR; each PR updates the roadmap row and `docs/engine-build-status.md`.
- Ask the owner before SDK ABI changes or new dependencies. app/ changes are approved for F7.
- F7 owner choices (2026-11-04, `docs/decisions.md`): remove the app caps (F7.1); remove the 64-bar arrangement limit (F7.2); dynamic layers, re-preparing the mix graph off the audio thread (F7.3); safety bounds from the hardware budget, host-overridable within a ceiling, each with a clear message (F7.4).

## Done and verified
- F1–F6 on Main; F7 caps audit #88, F7.1 #89, F7.2 #92 (no 64-bar limit, streamed exports).
- F7.3 part A on the branch: runtime slot capacity (still 64), slots by pointer with `Slot::index`, capacity-sized MixGraph, out-of-line SetOrder list. caw_tests 267, caw_rt_tests 73, sanitizers clean, goldens unchanged, callgrind 1 layer -1.0%. Audio review: no findings.

## Open
- Issue #78: swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.
- Open: `smoothingFrames` counts frames, not time. Open (owner): MIDI 1.0 CC centre (v/127) vs MIDI 2.0 upscaling.
- #90 arranger float32 drawing far into long songs; #91 the app save step reads the whole WAV for the picker (may need a new dependency: ask the owner).

## Next
1. Open the part A PR, merge when green, update #28.
2. F7.3 part B (plan in `docs/decisions.md`): `Cmd::Grow` swaps a bigger slot table and MixGraph built off-thread; budget from graphWorkingBytes with a clear error; per-slot export segments; size the retired queue and pending list from the largest capacity (replace the static_assert); lift the parser cap; growth and alloc-counter tests.
3. Part C: the C API reports the audition index (the app hard-codes 64 in `app/lib/engine/engine.dart`); remove the app's layer caps.

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `docs/engine-build-status.md`
- `app/lib/model/project.dart`
