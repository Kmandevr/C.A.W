# Handoff

Commit: 4b125cb
Branch: claude/caw-engine-foundation-skpirb (F6.3 on top of Main 8e181a2; PR to Main)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
- One small PR per step, targeting `Main`. Claude merges when CI is green, and updates the #28 progress comment (id 6609966082).
- Rules: no allocation, locks or I/O in the callback; exports bit-identical across platforms; stereo low-overhead (callgrind, `caw_bench 1|2 N` difference / 250); never weaken tests, and a bug fix starts with a failing test; audio-reviewer and release-check before each PR; each PR updates the roadmap row and `docs/engine-build-status.md`.
- Ask the owner before SDK ABI changes, new dependencies, or app/ changes.

## Done and verified
- On Main: F3 (#72), F4 (#74, #75, #77, #79), F5 (#80, #81), F6.1 (#82, `ParameterResolver`) and F6.2 (#83: the executor passes resolved parameters; `queueParameter`/`queueClearTouch`/`setInitialParameter`).
- F6.3 is on the branch: `GraphExecutor::setModulationLinks()`, which applies links in id order. Links and routing exclude each other either way round.
  - Tests: caw_tests 252/252, caw_rt_tests 64/64, sanitizers clean. Callgrind within noise.

## Open
- Issue #78: swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.
- Open for F6.4: `smoothingFrames` counts frames, not time (not scaled by sample rate).

## Next
1. Merge the F6.3 PR when CI is green, and update #28.
2. F6.4: automation lanes as a resolver source; values must match the Engine's `automationValue` sample for sample, including seeks. Decide whether `smoothingFrames` scales with sample rate. Then F6.5 MIDI CC and F6.6 Engine .caw params (golden hashes unchanged). The Engine's graph uses routing, so links there need routing-aware ordering (F6.6).

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `docs/engine-next.md` ("One parameter model")
- `engine/src/module.h`
- `engine/src/graph.h`
