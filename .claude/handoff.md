# Handoff

Commit: 06adafc (Main = v1.0.5-alpha.2; the session branch has the 1.0.6 plan docs and the audit fixes)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Publish with app.yml's workflow_dispatch (installables + release) on Main. Each release needs a CHANGELOG.md entry, copied to app/assets/CHANGELOG.md.

## Goal
Finish and release 1.0.6-alpha.1, the usability release (owner, 2026-11-18). Then build the 1.0.7 groundwork (#239), everything that needs no owner input, so only the last decisions remain. Wake-ups are set for 05:07 and 05:40 MT (12:07 and 12:40 UTC), after the usage reset.

## Done and verified
- v1.0.5-alpha.2 published (PR #243).
- Roadmap renumbered: 1.0.7 security and companion, 1.0.8 FX consolidation, and so on.

## Open
- **Done, not yet merged:** `device-select` 6688d5d (#242, the tap-along fix, audio-take learning) and `smooth-zoom` 747844a (zoom, the #235 frame pass).
- **In progress** (resumed after a container restart, with WIP commits pushed):
  - `settings-rework` (#244, from device-select, C API 35, WIP at 92b6399);
  - `quick-wins` (from smooth-zoom, WIP at afa5a95).
- **Merge order:** settings-rework, then quick-wins (which contains smooth-zoom), into the session branch.
- **Release:** merge all, full checks, bump to 1.0.6-alpha.1+10 (pubspec, version.dart, docs/app.md and architecture.md, 4 version goldens), then PR, CI, merge, release.
- **1.0.7 groundwork:** docs/plugin-hosting-plan.md ("Least privilege and the companion app"), decisions 2026-11-18, and #239.
  - Owner answers: updater and trust first; the full AutoStacc look (brand assets still needed from the owner).
- **Audit (2026-11-18):** 10 issues closed; #245 collects the performance leftovers. CI build jobs are capped (f8805d3).
- **Owner phone checks with 1.0.6:** #20 (keyboard Backspace), #31 (one USB and one BLE MIDI keyboard), #204 (power, heat and frames baseline).
- **Owner questions:** Windows x86-64-v3 (a second DLL, or the minimum CPU); the AutoStacc brand; the pack's 4th device; routing and hosting plan questions; TERMS governing law; store accounts.

## Next
1. Collect the settings-rework and quick-wins reports, then merge.
2. Release 1.0.6-alpha.1, then the 1.0.7 groundwork.
