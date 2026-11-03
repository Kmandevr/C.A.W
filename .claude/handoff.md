# Handoff

Commit: 125f1b8
Branch: claude/caw-engine-foundation-skpirb

## Goal
Owner (2026-11-03): build the roadmap Foundation stage (issue #28, `docs/roadmap.md`) in order F3 → F4 → F5 → F6 → F7 → F8 (F9 deferred to before Release 1: no project compatibility needed yet), one smallest complete PR each against `feature/native-engine-refactor-integration`, full CI green before the next. Never push to that branch or Main. Rules: no allocation/locks/IO in the callback; exports bit-identical; stereo stays low-overhead (measure with `caw_bench`, callgrind); never weaken tests; bug fixes start with a failing test; audio-reviewer on every engine change; release-check before each PR; update the roadmap Foundation row and `docs/engine-build-status.md` in the same PR; keep the #28 progress comment current. Claude may merge its PRs when CI is green: Foundation PR → #28 branch, then #28 branch → Main after each item. Ask before: SDK ABI changes, any golden-hash change (never `--update-golden` to pass), new dependencies, app/ changes beyond F4/F9. Owner approved a 64-channel port ceiling.

## Done and verified
- F3 planar N-channel executor: PR #72 (open, subscribed). `ctest --test-dir engine/build` 5/5 (caw_tests 229, caw_rt_tests 18) Release and `-DCAW_SANITIZE=ON`. Callgrind stereo wrapper 4,640 → 5,086 Ir/callback.
- Progress comment posted on #28 (issuecomment-6609966082).

## Open
- Engine/App/Docs CI on PR #72 not yet reported.
- F4 must keep golden hashes unchanged; stop and ask if one would change.
- Native SDK (`engine/include/caw_module_sdk.h`) is still left/right with no channel count; ABI change needs the owner.

## Next
Merge PR #72 into the #28 branch, PR the #28 branch into Main and merge when green, then restart this branch from the #28 branch and start F4 (migrate the live mixer into the graph, golden hashes unchanged).

## Read first
- `docs/roadmap.md`
- `docs/engine-build-status.md`
- `engine/src/graph.h`
- `engine/src/module.h`
- `engine/src/engine.cpp`
