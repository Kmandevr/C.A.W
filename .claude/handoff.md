# Handoff

Commit: 387b7f0 (session branch: 1.0.3-alpha.1 ready for its PR; Main has v1.0.2-alpha.1, published)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish a release with app.yml's workflow_dispatch (installables + release) on Main, which creates the tag. Each release needs a CHANGELOG.md entry (copied to app/assets/CHANGELOG.md).

## Goal
The 1.1.0 plan (#215): batches ship as 1.0.x-alpha.1. 1.1.0 is the big one: plug-in hosting goes live, play-ahead (#191), AutoStacc (#221), Play and iOS stores (#222).

## Done and verified
- v1.0.1-alpha.1 and v1.0.2-alpha.1 are published (Benchmark 2, plug-in benchmark, changelog, clang-cl, 120 Hz fix).
- 1.0.3 is on the session branch: the tempo map, time signatures, sections and markers (#207), C API 31. The audio review was done and all nine findings fixed.
- Checks on 90eda97: Release ctest 11/11; flutter test 2075 passed with 3 skipped; docs-test --strict passes at 387b7f0.

## Open
- **Next batch, 1.0.4 (#208):** audio stretching with Signalsmith Stretch (confirm its licence first), slice to MIDI, a sample editor, and long-song precision (#90). Ask the owner how it should look first.
- **Owner questions:**
  - the 6/8 metronome (eighths vs dotted quarters);
  - the look choices for 1.0.3, recorded in decisions.md;
  - governing law for TERMS.md;
  - what AutoStacc is technically;
  - the store accounts;
  - #20 and #31 device checks.
- **The S22+ 120 Hz check:** the owner pastes the Display modes block if 120 Hz still doesn't appear.

## Next
1. Open the PR for 1.0.3 and merge it when CI is green, then publish v1.0.3-alpha.1.
2. Start 1.0.4.
