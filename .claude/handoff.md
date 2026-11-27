# Handoff

Commit: d7d3587 on Main. 1.1.3 maintenance and groundwork merged on 2026-11-27: #288 changelog per change, #289
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
1. **Performance first (owner, 2026-11-27: "the DAW has gotten too heavy to worry about other features"; every other
   feature is paused).** The owner's S22+ benchmark: live song8 at 192 frames p99 134 %, every_effect worst 327 %,
   Kestrel 64 voices 122 %; the callback runs on little cores at ~43 % clock and the performance hint is unsupported.
   Optimize every instrument and effect, quality unchanged: bit-identical speedups first (render digests unchanged),
   then inaudible shortcuts (null below -120 dB or the existing tolerance tests), on Android, Windows and Linux; plus
   the scheduling side (consider play-ahead early). A profiling agent writes the hot-spot report to the session
   scratchpad (perf-report.md); optimizers follow by component group.
2. **Paused, saved as local WIP commits in worktrees (resume after the performance pass):** G5 op undo
   (`.claude/worktrees/collab-g5`, the review's seven fixes half done on 3ea0c4f), receives/@none/Split rack
   (`routing-receives-split`, started), drum multi-out (`drum-multi-out`, not started). #217 design: receives are a
   view over sends, `output: "@none"`, an `org.caw.rack.split` rack, drum out2..9 as route taps with a child layer
   `source`; choices taken: split modes full/LR/MS, children pre the drum fader, child latency compensated.
3. 1.1.4 screens wait on Hub #35 questions 1-9. Then G6, #217, 1.1.4 release.
