# Handoff

Commit: 27ee13f (Main = v1.0.5-alpha.2, published 2026-11-18 via PR #243)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish with app.yml's workflow_dispatch (installables + release) on Main. Each release needs a CHANGELOG.md entry, copied to app/assets/CHANGELOG.md.

## Goal
Next is 1.0.6-alpha.1, the usability release: #242 devices, the tap-along fix, smooth zoom, #244 settings. Then 1.0.7, security and the companion app (#239). Then 1.0.8, the FX consolidation (#227, #231). Silent 1.1.0 groundwork rides along.

## Done and verified
- Merged into the session branch:
  - settings drop-downs;
  - automation-fix (point drag, Automation tab);
  - startup-smooth;
  - drift-ui (scroll window, playhead, the 300 ms double count, slider beat, Bluetooth quality hint);
  - drift-audio (drift tests found no engine drift, a clock readout in Engine diagnostics, latency counts AAudio's queue).
- Before drift-audio was merged: flutter test 2163 passed (no CAW_LIB).

## Open
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
1. Merge device-select, smooth-zoom, then the #244 settings rework (it starts after device-select), then release 1.0.6-alpha.1.
2. 1.0.7 (#239) once the owner sends the AutoStacc brand.
