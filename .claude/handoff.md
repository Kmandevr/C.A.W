# Handoff

Commit: 32ca79d on Main (1.1.3 maintenance merged: #277 engine.cpp, #278 piano roll and Arrange, #279 AppState, #280 Flagship and Drums, #281 big engine tests, #282-#284 CI split and Dart balance, #285-#286 compat tables recorded for every build, #287 one list for bench modes and C API versions, #288 changelog per change); this branch: `scripts/worktree-tidy.js` (worktree backup by hand, scratch-build cleanup; security-reviewed). 1.1.3-alpha.6 released 2026-11-26 (#275 Curlew's piccolo, oboe and
tuba; #276 version; app.yml release run 45892645407; APK, Windows zip, patches). The owner (2026-11-26): Claude
merges and releases when ready, and takes its own recommended option for any question (docs/decisions.md). A
5-hourly scheduled wake-up resumes this session. Standing rules: `.claude/rules/done.md`, docs/decisions.md 2026-11-25.

## Goal
Finish 1.1.3, then 1.1.4 (automation choices and VCA groups #210, receives/parallel/multi-out #217, MIDI out and
clock #211).

## Done and verified
- alpha.6: Curlew variants 6-8 (piccolo G5-A7, oboe B3-F6, tuba B1-D4), bassoon not built (decisions.md); all CI
  green on dd8846b and a10b18d.

## Open
- Owner: Hub #33 (rear Antiphonal stops, where the rock organ lives); otherwise my recommendations stand.

## Next
1. The rest of 1.1.3: per-build references for chaotic devices (agent in worktree perbuild-refs); the hidden
   collaboration groundwork (agents: G1+G2 in worktree g1-g2-uids, G3 in g3-collab; Hub
   docs/caw/collaboration-design.md). Back each up with `node scripts/worktree-tidy.js backup` after a dry run.
   Then a 1.1.3 release (`scripts/changelog-join.js` first). Two playing modes
   (#11) and the main panel (#10) move to 1.1.4.
2. Issue #271 (close after green Windows runs), #268.
