# Handoff

Commit: f709ea6 on Main (1.1.3 maintenance: #277 engine.cpp, #278 piano roll and Arrange, #279 AppState, #280 Flagship and Drums, #281 the big engine test files, #282 the CI split: sanitizers 28 min, Dart 11 min). 1.1.3-alpha.6 released 2026-11-26 (#275 Curlew's piccolo, oboe and
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
1. The rest of 1.1.3's maintenance list: balance the Dart test shards by measured time (shard 1/4 takes 10.7 of
   the 11 minutes; decisions.md 2026-11-27), a hand-started job recording per-build compat tables, per-build
   references, changelog per change, one list for bench and C API numbers, worktree backup. Then the hidden
   collaboration groundwork G1-G3 (Hub docs/caw/collaboration-design.md). Two playing modes (#11) and the main
   panel (#10) move to 1.1.4.
2. Issue #271 (close after green Windows runs), #268.
