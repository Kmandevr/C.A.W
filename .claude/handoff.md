# Handoff

Commit: 941fd77 (session branch: 1.0.4-alpha.1 in PR #225; Main has v1.0.3-alpha.1, published)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish a release with app.yml's workflow_dispatch (installables + release) on Main, which creates the tag. Each release needs a CHANGELOG.md entry (copied to app/assets/CHANGELOG.md).

## Goal
The 1.1.0 plan (#215): batches ship as 1.0.x-alpha.1. 1.1.0 is the big one: plug-in hosting goes live, play-ahead (#191), AutoStacc (#221), Play and iOS stores (#222).

## Done and verified
- v1.0.1-alpha.1 and v1.0.2-alpha.1 are published (Benchmark 2, plug-in benchmark, changelog, clang-cl, 120 Hz fix).
- v1.0.3-alpha.1 is published (tempo map, #207).
- 1.0.4 is on the session branch: Signalsmith stretching (live), the sample editor and slice to MIDI (#208), #90, C API 32. The audio review's 7 findings are fixed. Checks: Release ctest 11/11; flutter test 2114 passed with 3 skipped; docs-test --strict passes.

## Open
- **Next batch, 1.0.5:** store clips as MIDI first (#216), then comping, freeze, bounce and consolidate (#209). Ask the owner how it should look first.
- **Known flake:** stress_profile_parts_add_up_and_name_the_feature ("the largest part is metering") sometimes fails in a parallel shard under load.
- **Owner questions:**
    - the look choices for 1.0.3, recorded in decisions.md;
  - governing law for TERMS.md;
  - what AutoStacc is technically;
  - the store accounts;
  - #20 and #31 device checks.
- **The S22+ 120 Hz check:** the owner pastes the Display modes block if 120 Hz still doesn't appear.

## Next
1. Open the PR for 1.0.4, merge it when CI is green, and publish v1.0.4-alpha.1.
2. Start 1.0.5.
