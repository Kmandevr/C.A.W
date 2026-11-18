# Handoff

Commit: a7525d6 (session branch = 1.0.5-alpha.1, in PR #238; Main has v1.0.4-alpha.1)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish with app.yml's workflow_dispatch (installables + release) on Main. Each release needs a CHANGELOG.md entry, copied to app/assets/CHANGELOG.md.

## Goal
Ship 1.0.5-alpha.1 (#215). Then 1.0.7: FX consolidation and the device UI (#227, #231), with routing step S1 designed into it. Then 1.0.8. Silent 1.1.0 groundwork rides along (docs/routing-plan.md, docs/plugin-hosting-plan.md).

## Done and verified
- 1.0.5 holds everything since 1.0.4:
  - #216, #209, #226, #228, #229, #230, #234 and #236, and part of #237;
  - the audio review's fixes;
  - C API 34, project format v5.
- Checks on a7525d6's tree:
  - ctest 11/11 (965 tests);
  - flutter analyze clean;
  - flutter test 2134, or 2289 with CAW_LIB;
  - docs --strict;
  - no golden change apart from the version goldens.

## Open
- **PR #238:** wait for CI, merge, then run app.yml release for v1.0.5-alpha.1.
- **Owner questions:**
  - the AutoStacc pack's 4th device;
  - routing plan questions 3, 6 and 7;
  - hosting plan questions 2, 4, 5 and 6;
  - the TERMS governing law;
  - the store accounts.
- **Defaults chosen** (owner said "do what makes sense"): the buffer tuner stays hidden, MIDI ID 7D, looks as built.
- **Device checks:**
  - the S22+: hint_state, USAGE_GAME on Bluetooth (watch Game Booster), worstCallbackPct, linked cloud folders;
  - Windows: WASAPI's smallest period.
- **#235:** UI frames at 120 Hz (not started). The rest of #237 (Linux rtkit, exclusive tests) waits for the next batch.

## Next
1. Merge #238 and release.
2. Start 1.0.7: #227 consolidation plus #231 kit, Flagship, FX chain, React to… and live preset preview. Ask the owner for each device's look first.
