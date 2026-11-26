# Handoff

Commit: aad8d6f on Main, merged into ccr-bd7ac4df-86w0bh (no open PR).
1.1.3-alpha.4 released 2026-11-26 (Main 93ad17a, PR #269 squash-merged; app.yml release run 45756483102, pre-release
v1.1.3-alpha.4 with APK, Windows zip, patches). Branch ccr-bd7ac4df-86w0bh has Main merged in (no diff); next work
goes here as a new PR, one release's worth at a time (don't keep adding to a PR that is ready: the advisor's note).
The owner (2026-11-26): Claude merges and releases when ready (docs/decisions.md). Issue #268: Starling strings'
Windows-only -91 dB difference. A 5-hourly scheduled wake-up resumes this session. Standing rules:
`.claude/rules/done.md`, docs/decisions.md 2026-11-25.

## Goal
Make 1.1.3 usable from the owner's feedback, then 1.1.4+ toward 1.2.0.

## Done and verified
- alpha.4 (the owner's alpha.3 notes): Starling's stray sounds, Woodpecker's notes, Bittern's stops/Chimes/Swell/
  Weight/Spread and each key its own pipe, Curlew's brass measured against VSCO and built strict, Nightingale's bodies
  refit (no band over 12 kHz). Two audio reviews' findings fixed. All 22 CI checks green on 7793461.
- Measurement scratch tools (scratchpad tools_scripts): brass_cmp.py, brass_sim.py, piano_diff.py; VSCO checkout in
  scratchpad vsco/repo (strings, brass sus).

## Open
- Owner questions: the two playing modes' look (realistic / keyboard, "wonky" parameters); what is off on the main
  panel while playing; Hub #33 (Bittern vision: where the rock organ lives, the tonewheel question; the controls' look).
- Organ reed stops: spectra still modelled (no recording); waiting on the owner's ear.

## Next
1. Bittern stage 1 merged (#270: division reservoirs, pallets, hall low cut, presets; not released yet). The
   Antiphonal's rear placement is not built: Bittern's one Antiphonal stop, the Tuba, stands in the front case [S1]
   (docs/organ-research-tabernacle.md); it needs the division's rear stops first (asked the owner, Hub #33).
   Issue #271: the Windows mix-pool timing test (hypothesis there).
2. Curlew: more winds (piccolo, alto flute, oboe, bassoon, saxes, tuba); Starling treble/top zones.
3. Older: live-path gate test branch; undo CI loosening (Curlew in the stress mix match); performance p99; Rook
   optimisation and kick tools (last).
