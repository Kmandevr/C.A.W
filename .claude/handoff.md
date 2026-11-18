# Handoff

Commit: 619dd5b (the session branch = 1.0.6-alpha.1, in PR #246; Main = v1.0.5-alpha.2)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish with app.yml's workflow_dispatch (installables + release) on Main. Each release needs a CHANGELOG.md entry, copied to app/assets/CHANGELOG.md.

## Goal
Finish and release 1.0.6-alpha.1, the usability release (owner, 2026-11-18). Then build the 1.0.7 groundwork (#239), everything that needs no owner input, so only the last decisions remain. Wake-ups are set for 05:07 and 05:40 MT (12:07 and 12:40 UTC), after the usage reset.

## Done and verified
- v1.0.5-alpha.2 published (PR #243).
- Roadmap renumbered: 1.0.7 security and companion, 1.0.8 FX consolidation, and so on.

## Open
- **1.0.6-alpha.1** (all merged, PR #246):
  - #244 settings, C API 35;
  - #242 devices, the tap fix, audio-take learning;
  - smooth zoom and the #235 pass;
  - the quick wins.
  - Checks: ctest 11/11; CAW_LIB flutter test 2328 + 8 goldens re-recorded (the zoom note-preview levels); docs --strict.
  - Next: CI green, then merge and release.
- **1.0.7 groundwork:** docs/plugin-hosting-plan.md ("Least privilege and the companion app"), decisions 2026-11-18, and #239.
  - Owner answers: updater and trust first; the full AutoStacc look (brand assets still needed from the owner).
- **Audit (2026-11-18):** 10 issues closed; #245 collects the performance leftovers. CI build jobs are capped (f8805d3).
- **Owner phone checks with 1.0.6:** #20 (keyboard Backspace), #31 (one USB and one BLE MIDI keyboard), #204 (power, heat and frames baseline).
- **Owner questions:** Windows x86-64-v3 (a second DLL, or the minimum CPU); the AutoStacc brand; the pack's 4th device; routing and hosting plan questions; TERMS governing law; store accounts.

## Next
1. Merge PR #246 when green and release 1.0.6-alpha.1.
2. 1.0.7 groundwork (#239): the companion skeleton, IPC, moving the updater, telemetry and trust behind it, the Play variant, the shm ring.
