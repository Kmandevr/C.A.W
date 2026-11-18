# Handoff

Commit: 8de3295 (session branch = hotfix 1.0.5-alpha.2 plus Main's #239 plan docs; Main has v1.0.5-alpha.1)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish with app.yml's workflow_dispatch (installables + release) on Main. Each release needs a CHANGELOG.md entry, copied to app/assets/CHANGELOG.md.

## Goal
Ship hotfix 1.0.5-alpha.2 (#241). Next is 1.0.6, plug-in security and the companion app (#239, in docs/plugin-hosting-plan.md). Then 1.0.7: FX consolidation and the device UI (#227, #231). Silent 1.1.0 groundwork rides along.

## Done and verified
- Merged into the session branch:
  - settings drop-downs;
  - automation-fix (point drag, Automation tab);
  - startup-smooth;
  - drift-ui (scroll window, playhead, the 300 ms double count, slider beat, Bluetooth quality hint);
  - drift-audio (drift tests found no engine drift, a clock readout in Engine diagnostics, latency counts AAudio's queue).
- Before drift-audio was merged: flutter test 2163 passed (no CAW_LIB).

## Open
- **Final checks on 8de3295:** the engine ctest plus CAW_LIB flutter test, running in the background. Then:
  1. bump to 1.0.5-alpha.2 (pubspec +9, version.dart, docs/app.md and architecture.md, 4 goldens);
  2. CHANGELOG;
  3. PR, merge, release.
- **#242 device selection:** an agent is working on branch `device-select`. It ships after the hotfix.
- **Owner questions:**
  - #239's open points (updater-only first or hub, its look);
  - the AutoStacc pack's 4th device;
  - routing and hosting plan questions;
  - the TERMS governing law;
  - store accounts.
- **Device checks on the S22+ after the hotfix:**
  - Engine diagnostics with the mic on and off (drift);
  - the Latency breakdown (300 ms);
  - scroll;
  - the slider beat.

## Next
1. Release 1.0.5-alpha.2.
2. Start 1.0.6 (#239). Ask the owner its open points first.
