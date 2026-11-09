# Handoff

Commit: 54f57c8 (on branch wt-133, based on PR #132's head)

Branch: ccr-56285e11-0xrj3h (the session branch). #133's commit is on the local worktree branch `wt-133` until PR #132 merges; then reset the session branch to Main, cherry-pick it and open its PR.

## Goal
Owner (2026-11-09): Claude builds the engine; GPT is paused. The order is #120 → #17 → #121 → #122 (issue #123). Claude merges its own engine PRs once CI is green and an independent audio review finds nothing blocking. Decisions are in `docs/decisions.md` (2026-11-09).

## Done and verified
- PR #132 (#120, CP.2 parts 1 and 2):
  - The descriptor gains identity, role, latency/tail, state size, choice parameters and modulation/automation/MIDI flags, which the graph executor enforces.
  - Components cross the plain-C interface v2 in `engine/include/caw_component.h`, through one export, `caw_get_component_v2`.
  - `CAW_EXPORT_COMPONENT` (`engine/include/caw/component.hpp`) builds that interface from C++.
  - The registry (`engine/src/module_registry.cpp`) copies the descriptor and wraps instances.
  - Release and ASan/UBSan CTest pass 5/5. The architect review and two audio reviews are applied.
- #133 part 1 (commit 54f57c8): export buffers are held to `exportBufferBudget()`, the slot export table fields are atomic, and `CAW_API_VERSION` is 2 (the app's `cawApiVersion` too). Release and ASan pass 5/5. The audio review is not run yet.

## Next
- Merge #132 when green, then ship #133 part 1 as its own PR, after an audio review.
- #133 items 2 and 3, per-callback loops over active slots only and right-sized export pointer segments, need callgrind before and after.
- #17, stereo end to end. Blocked on an owner question (below).
- The C API that lists descriptors for the app (#38 item 3).

## Open (owner)
- #17: a `.caw` module is mono (the VM makes one signal). On a stereo track, should a mono effect run once per channel with its own state ("dual mono", double the CPU), or be refused? Generators duplicate to both channels either way.
- One component per library, or bundles (`caw_get_component_v2(index)`)?
- The docs guard makes README change on every PR (README covers the whole repo). Narrow it?
- Old branches to delete by hand (session git deletes are blocked); the list is in the session summary.

## Read first
- `docs/native-module-sdk.md` (C interface v2)
- `docs/engine-build-status.md`
- `engine/src/engine.cpp` (`runModuleNode`/`runTrackNode` for #17)
