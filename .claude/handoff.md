# Handoff

Commit: aa867c8
Branch: claude/caw-engine-foundation-skpirb (F6.6 on top of Main 477510c; PR to Main)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
- One small PR per step, targeting `Main`. Claude merges when CI is green, and updates the #28 progress comment (id 6609966082).
- Rules: no allocation, locks or I/O in the callback; exports bit-identical across platforms; stereo low-overhead (callgrind, `caw_bench 1|2 N` difference / 250); never weaken tests, and a bug fix starts with a failing test; audio-reviewer and release-check before each PR; each PR updates the roadmap row and `docs/engine-build-status.md`.
- Ask the owner before SDK ABI changes, new dependencies, or app/ changes.

## Done and verified
- On Main: F3 (#72), F4 (#74, #75, #77, #79), F5 (#80, #81), F6.1 (#82, `ParameterResolver`) and F6.2 (#83: the executor passes resolved parameters; `queueParameter`/`queueClearTouch`/`setInitialParameter`).
- F6.3 (#84), F6.4 (#85) and F6.5 (#86, MIDI CC mappings) on Main.
- F6.6 on the branch: the Engine's .caw params/globals resolve through `ParameterResolver` (per-chain `paramSlots`, `resolveParams`). Touches come only from setParam/setGlobal (engine-wide stamps), end at Play, survive rebuilds; the compiler refuses non-finite params. Goldens unchanged; callgrind +0.3%. Two audio-review rounds fixed. F6 complete once merged.
  - Tests: caw_tests 261/261, caw_rt_tests 73/73, sanitizers clean.

## Open
- Issue #78: swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.
- Open: `smoothingFrames` counts frames, not time (matters once a smoothed param reaches the Engine).
- Open (owner): MIDI 1.0 CC centre (v/127) vs MIDI 2.0 upscaling.

## Next
1. Merge the F6.6 PR when CI is green, update #28 (F6 complete).
2. F7: explicit resource budgets (including the caps audit); then F8, then F10 (native seeds need owner ABI approval).

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `docs/engine-next.md` ("One parameter model")
- `engine/src/module.h`
- `engine/src/graph.h`
