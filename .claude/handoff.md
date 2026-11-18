# Handoff

Commit: bc98be7+ (Main = v1.0.6-alpha.1 published + the 1.0.7 groundwork, PR #247 merged)
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
  - v1.0.6-alpha.1 published with all six assets; the release job now also needs analysis and the Dart tests.
- **1.0.7 groundwork:** docs/plugin-hosting-plan.md ("Least privilege and the companion app"), decisions 2026-11-18, and #239.
  - Owner answers: updater and trust first; the full AutoStacc look (brand assets still needed from the owner).
- **Audit (2026-11-18):** 10 issues closed; #245 collects the performance leftovers. CI build jobs are capped (f8805d3).
- **Owner phone checks with 1.0.6:** #20 (keyboard Backspace), #31 (one USB and one BLE MIDI keyboard), #204 (power, heat and frames baseline).
- **Owner questions:** where the companion's code lives (you called it private and closed-source, but C.A.W is open source, and its APK can't come from a private repo without a token); Windows x86-64-v3 (a second DLL, or the minimum CPU); the AutoStacc brand; the pack's 4th device; routing and hosting plan questions; TERMS governing law; store accounts.

## Next
1. The AutoStacc Hub (owner, 2026-11-18, decisions): private `Kmandevr/AutoStacc-Hub` (cloned to /home/user/autostacc-hub; PLAN.md, CLAUDE.md), option A: the site in a WebView over a Kotlin core and a Windows helper; own key, certificates pinned both ways; APK on C.A.W's releases via a fine-grained token (the owner adds it).
2. Next build step, the owner to confirm: the Hub's Kotlin core (the service answering C.A.W's protocol, reusing CompanionCallerCheck's logic), then C.A.W's signer check switched to the Hub's pinned digest.
