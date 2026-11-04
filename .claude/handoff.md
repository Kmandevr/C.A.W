# Handoff

Commit: df4f719
Branch: claude/caw-engine-foundation-skpirb (F6.2 on top of Main c1801c6; PR to Main)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
- One small PR per step, targeting `Main`. Claude merges when CI is green, and updates the #28 progress comment (id 6609966082).
- Rules: no allocation, locks or I/O in the callback; exports bit-identical across platforms; stereo low-overhead (callgrind, `caw_bench 1|2 N` difference / 250); never weaken tests, and a bug fix starts with a failing test; audio-reviewer and release-check before each PR; each PR updates the roadmap row and `docs/engine-build-status.md`.
- Ask the owner before SDK ABI changes, new dependencies, or app/ changes.

## Done and verified
- On Main: F3 (#72), F4 (#74, #75, #77, #79), F5 (#80, #81) and F6.1 (#82, `ParameterResolver` in `engine/src/params.*`).
- F6.2 is on the branch (`744468b`, review fixes `df4f719`). The executor resolves node parameters into `AudioProcessBlock`/`ProcessBlock::parameters`; `queueParameter`/`queueClearTouch` (SPSC, 256 commands) carry changes; `setInitialParameter` handles rebuilds.
  - Tests: caw_tests 252/252, caw_rt_tests 59/59, sanitizers clean. Callgrind: playback +0.03–0.05%, graph +0.5%.

## Open
- Issue #78: swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.
- Open for F6.4: `smoothingFrames` counts frames, not time (not scaled by sample rate).

## Next
1. Merge the F6.2 PR when CI is green, and update #28.
2. F6.3: modulation links from modulation outputs to node parameters (link id order; test that permuting node or link order gives the same output). Then F6.4 automation lanes, F6.5 MIDI CC, F6.6 Engine .caw params (golden hashes unchanged).

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `docs/engine-next.md` ("One parameter model")
- `engine/src/module.h`
- `engine/src/graph.h`
