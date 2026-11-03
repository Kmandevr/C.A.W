# Handoff

Commit: 4aac1d4
Branch: claude/caw-engine-foundation-skpirb (reset to Main after #75; F4.3 next)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28) F4 → F5 → F6 → F7 → F8; F9 deferred to Release 1 (no project compatibility needed yet). One small PR per step, now targeting `Main` directly (the #28 branch merged into Main in PR #73 and was deleted on merge); Claude merges when CI is green. Rules: no allocation/locks/IO in the callback; exports bit-identical across platforms; stereo stays low-overhead (callgrind via `caw_bench SECONDS -1`); never weaken tests; bug fixes start with a failing test; audio-reviewer on each engine change; release-check before each PR; update the roadmap Foundation row + `docs/engine-build-status.md` per PR. Owner (2026-11-03): reliability over old-engine compatibility; golden hashes may be re-recorded for intended engine changes (state why, with a measurement). Ask before: SDK ABI changes, new dependencies, app/ changes beyond F4.

## Done and verified
- On Main: F3 (PR #72), F4.1 fan-in (#74), old #28 branch (#73), F4.2 float routing + 8 mixer goldens + saturating route_math.h (#75 → e2bb9b6). Full CI green on each.

## Open
- F4.3 chosen design (2026-11-03): Engine owns ONE GraphExecutor prepared at construction: kSlots slot nodes + master node, each with a summing stereo input whose source capacity is reserved for every slot. New executor API: control-thread reserve of dynamic summing capacity; realtime `setRouting(edges, order)` that validates (each node once, sources before destinations, channel counts) using preallocated scratch and rebuilds sum source lists without allocation. Engine re-derives edges (child → parentSlot bus, else → master) and order (legacy pass order: processOrder_ then remaining slots by index; a bus waits until its children ran; master last) on the audio thread when routing changed, then calls graph process per chunk. Slot node = processSlot or bus gain/pan into a float output; master node = existing master stage. Exports stay the double side channel. Must keep golden.txt and mix_golden_test.cpp hashes; add test for issue #76 (child removed from folder fades out: no step above normal fade).
- F10 (owner, 2026-11-03): seeded randomness everywhere; per-module seeds follow the project unless pinned; seeding switchable off per module/project; native plugins need a seed (SDK ABI change, ask owner). In docs/decisions.md and the roadmap.
- F4.4 later: split each slot's chain into source and effect nodes.

## Next
Build F4.3 on claude/caw-engine-foundation-skpirb (reset to Main e2bb9b6): executor dynamic routing + tests first, then Engine integration, then remove the old pass loop.

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `engine/src/graph.h`
- `engine/src/engine.cpp`
