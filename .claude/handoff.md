# Handoff

Commit: a20e99a
Branch: claude/caw-engine-foundation-skpirb (F4.2 + multi-track mixer goldens)

## Goal
Owner (2026-11-03): finish the roadmap Foundation stage (#28) F4 → F5 → F6 → F7 → F8; F9 deferred to Release 1 (no project compatibility needed yet). One small PR per step, now targeting `Main` directly (the #28 branch merged into Main in PR #73 and was deleted on merge); Claude merges when CI is green. Rules: no allocation/locks/IO in the callback; exports bit-identical across platforms; stereo stays low-overhead (callgrind via `caw_bench SECONDS -1`); never weaken tests; bug fixes start with a failing test; audio-reviewer on each engine change; release-check before each PR; update the roadmap Foundation row + `docs/engine-build-status.md` per PR. Ask before: SDK ABI changes, any golden-hash change other than F4.2's approved one, new dependencies, app/ changes beyond F4.

## Done and verified
- F3 merged (PR #72 → 7f06839). F4.1 fan-in merged (PR #74 → 2d27815).
- F4.2: mixer rounds track/bus outputs to float at routing and sums in float; owner-approved re-record of 10 golden hashes (CLI WAV diff <= 1 LSB of 24-bit).
- Multi-track mixer goldens (engine/tests/mix_golden_test.cpp, 6 projects) recorded on the F4.2 mixer: the bit-exact target for F4.3. Local caw_tests 231/0, caw_rt_tests 24/0.
- PR #73 merged: Main = old #28 branch + F3 + F4.1 (6cd8b5c). PR #75 (F4.2) was retargeted to Main.

## Open
- F4.3 design: slots (each a layer chain with its effects), folder buses and master become graph nodes; dual-run test must reproduce F4.2 output bit-for-bit. Undecided: publish a prepared graph from setProject alongside routing commands (needs the control thread to know every slot's parent, including removing slots), or add executor runtime routing with prepared capacity. Legacy quirk: a slot processed after its parent bus (pass 1) loses its signal that chunk.
- F4.3 constraints: create connections in the mixer processing order (processOrder_, then slot index); keep track-to-track exports (double exportBuf) as a side channel, not float edges, or every export project changes; fix issue #76 (removal fade lost in folders) with a test.
- F4.4 later: split each slot's chain into source and effect nodes.

## Next
Merge PR #75 when green; then build F4.3 (publish a prepared graph from setProject with node indices in legacy processing order; mix goldens must hold).

## Read first
- `docs/roadmap.md`
- `docs/decisions.md`
- `engine/src/graph.h`
- `engine/src/engine.cpp`
