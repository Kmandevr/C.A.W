# Handoff

Commit: f9cd21c (Main = v1.0.6-alpha.1 + the 1.0.7 groundwork; this branch: PR #248, plans moved private)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish with app.yml's workflow_dispatch (installables + release) on Main. Each release needs a CHANGELOG.md entry, copied to app/assets/CHANGELOG.md.

## Goal
Finish and release 1.0.6-alpha.1, the usability release (owner, 2026-11-18). Then the next batch's groundwork (#239), everything that needs no owner input. Planned work, release order and owner questions are kept in the private Kmandevr/AutoStacc-Hub (docs/caw/) since 2026-11-18. Wake-ups are set for 05:07 and 05:40 MT (12:07 and 12:40 UTC), after the usage reset.

## Done and verified
- v1.0.5-alpha.2 published (PR #243).
- Planning notes updated (private).

## Open
- **1.0.6-alpha.1** (all merged, PR #246):
  - #244 settings, C API 35;
  - #242 devices, the tap fix, audio-take learning;
  - smooth zoom and the #235 pass;
  - the quick wins.
  - Checks: ctest 11/11; CAW_LIB flutter test 2328 + 8 goldens re-recorded (the zoom note-preview levels); docs --strict.
  - v1.0.6-alpha.1 published with all six assets; the release job now also needs analysis and the Dart tests.
- **Companion groundwork:** [companion protocol](../docs/companion-protocol.md), decisions 2026-11-18, and #239; the plan is private.
- **Audit (2026-11-18):** 10 issues closed; #245 collects the performance leftovers. CI build jobs are capped (f8805d3).
- **Owner phone checks with 1.0.6:** #20 (keyboard Backspace), #31 (one USB and one BLE MIDI keyboard), #204 (power, heat and frames baseline).
- **Owner questions:** tracked privately (docs/caw/open-questions.md in the Hub).

## Next
1. The next build steps are in the private plans (Hub docs/caw/); the Hub is cloned to /home/user/autostacc-hub.
