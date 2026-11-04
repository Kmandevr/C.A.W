# Handoff

Commit: 84fb8c3
Branch: claude/caw-engine-foundation-skpirb (F6.1 on top of Main d453926; PR to Main)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28): F6 → F7 → F8, plus F10 (seeded randomness); F9 is deferred to Release 1, since no project compatibility is needed yet.
- One small PR per step, targeting `Main`. Claude merges when CI is green, and updates the #28 progress comment (id 6609966082).
- Rules: no allocation, locks or I/O in the callback; exports bit-identical across platforms; stereo low-overhead (callgrind, `caw_bench 1|2 N` difference / 250); never weaken tests, and a bug fix starts with a failing test; audio-reviewer and release-check before each PR; each PR updates the roadmap row and `docs/engine-build-status.md`.
- Ask the owner before SDK ABI changes, new dependencies, or app/ changes.

## Done and verified
- On Main: F3 (#72), F4 (#74, #75, #77, #79) and F5 (#80, #81).
- F6.1 is on the branch (`7604611`, review fixes `84fb8c3`): `engine/src/params.*` `ParameterResolver`, plus descriptor curve/step/smoothing/unit. Not wired in.
  - Tests: caw_tests 252/252, caw_rt_tests 51/51, sanitizers clean. The owner's four F6 choices are in `docs/decisions.md` ("F6 parameter model").

## Open
- Issue #78: swap-fade import buffers are renumbered (an older bug).
- F10 seeds for native plugins need an SDK ABI change, so the owner must approve it.
- F6.2 integration rules from the audio review: each parameter gets its own `out` buffer; `out` is required when anything varies; configure/setLinks reach the audio thread via a swap or queue; setBase runs on the audio thread (queue); host calls clearTouch at playback (re)start.

## Next
1. Merge the F6.1 PR when CI is green, and update #28.
2. F6.2: resolver per executor node, with values in `ProcessBlock` and base values queued from the control thread. Then F6.3–F6.6 (`docs/decisions.md`).

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `docs/engine-next.md` ("One parameter model")
- `engine/src/module.h`
- `engine/src/graph.h`
