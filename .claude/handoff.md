# Handoff

Commit: 31be4a2 on Main (#277 split engine.cpp); this branch adds the split of the piano roll and Arrange screens. 1.1.3-alpha.6 released 2026-11-26 (#275 Curlew's piccolo, oboe and
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
1. The rest of 1.1.3 (my recommendation to the owner, 2026-11-26): the maintenance list. Done: engine.cpp (#277),
   the piano roll and Arrange screens (this branch). Left: `app/lib/model/app_state.dart`,
   `engine/src/builtin_flagship.cpp`, `engine/src/builtin_drums.cpp` (builtins: keep golden bits, as #277 did), the
   big test files, the long CI jobs, a hand-started job recording per-build compat tables, per-build references,
   changelog per change, one list for bench and C API numbers, worktree backup. Then the hidden collaboration
   groundwork G1-G3 (Hub docs/caw/collaboration-design.md). Two playing modes (#11) and the main panel (#10) move
   to 1.1.4.
2. Issue #271 (close after green Windows runs), #268.
