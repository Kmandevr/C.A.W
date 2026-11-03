# Handoff

Commit: 0ace730
Branch: claude/caw-engine-foundation-skpirb

## Goal
Owner (2026-11-03): build the roadmap Foundation stage (issue #28, `docs/roadmap.md` F1–F9) in order F3 → F9 → F4 → F5 → F6 → F7 → F8, one smallest complete PR each against `feature/native-engine-refactor-integration`, full CI green before the next. Never push to that branch or Main. Rules: no allocation/locks/IO in the callback; exports bit-identical; stereo stays low-overhead (measure with `caw_bench`, callgrind); never weaken tests; bug fixes start with a failing test; audio-reviewer on every engine change; release-check before each PR; update the roadmap Foundation row and `docs/engine-build-status.md` in the same PR; keep the #28 progress comment current. Ask before: SDK ABI changes, project format changes beyond F9, any golden-hash change (never `--update-golden` to pass), new dependencies, app/ changes beyond F4/F9. Owner approved a 64-channel port ceiling.

## Done and verified
- F3 planar N-channel executor: PR #72 (open, subscribed). `ctest --test-dir engine/build` 5/5 (caw_tests 229, caw_rt_tests 18) Release and `-DCAW_SANITIZE=ON`. Callgrind stereo wrapper 4,640 → 5,086 Ir/callback.
- Progress comment posted on #28 (issuecomment-6609966082).

## Open
- Engine/App/Docs CI on PR #72 not yet reported.
- F4 must keep golden hashes unchanged; stop and ask if one would change.
- Native SDK (`engine/include/caw_module_sdk.h`) is still left/right with no channel count; ABI change needs the owner.

## Next
Watch PR #72 CI and fix failures; after merge, start F9: project format version bump plus migration framework and tests (old projects must open), before F4.

## Read first
- `docs/roadmap.md`
- `docs/engine-build-status.md`
- `engine/src/graph.h`
- `engine/src/module.h`
- `engine/src/project.cpp`
