# Handoff

Commit: 04f02cc on Main. 1.1.3 maintenance and groundwork merged on 2026-11-27: #288 changelog per change, #289
`scripts/worktree-tidy.js`, #290 and #293 per-build reference suites (`nightingale_overlap`, `curlew_tails`,
`stress_chaotic`; `x64_clang` for the ThreadSanitizer job), #291 `caw_collab` (G3), #292 stable instance ids (G1, G2);
Hub #34 marks G1-G3 built. 1.1.3-alpha.7 released 2026-11-27 (#294; app.yml run 46013321866). This branch: the release's log line. The owner (2026-11-26): Claude merges and
releases when ready, and takes its own recommended option for any question (docs/decisions.md). A 5-hourly
scheduled wake-up resumes this session. Standing rules: `.claude/rules/done.md`, docs/decisions.md 2026-11-25.
This session may push only `ccr-bd7ac4df-86w0bh` (in both repositories): bring agents' worktree commits onto it.

## Goal
Finish 1.1.3, then 1.1.4 (automation choices and VCA groups #210, receives/parallel/multi-out #217, MIDI out and
clock #211).

## Done and verified
- alpha.6: Curlew variants 6-8 (piccolo G5-A7, oboe B3-F6, tuba B1-D4), bassoon not built (decisions.md); all CI
  green on dd8846b and a10b18d.

## Open
- Owner: Hub #33 (rear Antiphonal stops, where the rock organ lives); otherwise my recommendations stand.

## Next
1. 1.1.4: automation choices and VCA groups #210, receives/parallel/multi-out #217, MIDI out and clock #211; two
   two playing modes and the main panel (Hub roadmap 1.1.4; looks: Hub #35 questions 8 and 9). UI work: ask the owner how it should look first.
2. Issue #271 (close after green Windows runs), #268.
