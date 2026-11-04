# Handoff

Commit: 66cb6bf
Branch: claude/caw-engine-foundation-skpirb (F7.1 on top of Main 6c73567; PR to Main)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
- One small PR per step, targeting `Main`. Claude merges when CI is green, and updates the #28 progress comment (id 6609966082).
- Rules: no allocation, locks or I/O in the callback; exports bit-identical across platforms; stereo low-overhead (callgrind, `caw_bench 1|2 N` difference / 250); never weaken tests, and a bug fix starts with a failing test; audio-reviewer (engine) or code-reviewer (app) and release-check before each PR; each PR updates the roadmap row and `docs/engine-build-status.md`.
- Ask the owner before SDK ABI changes or new dependencies. app/ changes are approved for F7.
- F7 owner choices (2026-11-04, `docs/decisions.md`): remove the app caps (F7.1); remove the 64-bar arrangement limit (F7.2); dynamic layers, re-preparing the mix graph off the audio thread (F7.3); safety bounds from the hardware budget, host-overridable within a ceiling, each with a clear message (F7.4).

## Done and verified
- F1–F6 are on Main (F6.6 #87; F7 caps audit #88).
- F7.1 on the branch: the app keeps every automation lane, point and pattern note; `Steps` arithmetic is exact near 2^31 (BigInt). `flutter analyze` clean, `flutter test` 162 pass, docs-test --strict PASS; code-reviewer: no defects.

## Open
- Issue #78: swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.
- Open: `smoothingFrames` counts frames, not time. Open (owner): MIDI 1.0 CC centre (v/127) vs MIDI 2.0 upscaling.

## Next
1. Open the F7.1 PR, merge when green, update #28.
2. F7.2: remove the 64-bar limit in `engine/src/project.cpp` and the app (`maxArrangementSteps` clamps in project.dart and app_state.dart, the arranger's 4096 drag bounds, the clip-normalize test in `app/test/project_test.dart`). Then F7.3, F7.4, F8, F10.

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `docs/engine-build-status.md`
- `app/lib/model/project.dart`
