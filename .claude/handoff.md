# Handoff

Commit: 17a760e on ccr-bd7ac4df-86w0bh (PR #269 open; 1.1.3-alpha.3 released from Main 7d26f27). Next release's
changelog entry still to write when its version is set. Issue #268: Starling strings' Windows-only -91 dB difference.
A 5-hourly scheduled wake-up resumes this session. Owner's standing rules: `.claude/rules/done.md`, docs/decisions.md 2026-11-25.

## Goal
Make 1.1.3 usable: the owner's alpha.3 feedback, then 1.1.4+.

## Done and verified
The owner's feedback on alpha.3 (2026-11-25/26):
- Piano "weird transients/harmonics", "intended sound too present": done (bank stray harmonics, late release noise,
  phantom partials now stop with the dampers and sit 4 dB lower: 2a72b60).
- Woodpecker wrong notes: done. Organ stops, chimes, Swell knob, Weight (low end), Spread, strings: done.
- Organ "the note shouldn't just get lower, change like an organ would": done (509e331: tables every 2 semitones,
  per-pipe voicing, `bittern_each_key_has_its_own_colour`).
- Brass "too noisy, not genuine": Curlew done (17a760e, measured against VSCO; scratch tools brass_cmp.py,
  brass_sim.py in the scratchpad). Organ reeds: breath/puff cut earlier; their spectra are still modelled
  (no recording) - waiting on the owner's ear.

## Open
- Two modes per instrument (realistic / free keyboard, "wonky" parameters) - ask the owner how the switch
  should look; UI refinement of the main panel while playing - ask the owner first (screenshots).

Verified (2026-11-26, build-organ, x86 Release):
- `caw_tests` full: all pass but the env-only native-loader test (needs CAW_TEST_COMPONENT_PATH).
- `caw_rt_tests bittern|starling|curlew` pass. `caw_bench 3 321`: Bittern 19.7k/33.8k/36.3k us/s, Curlew trombone 3.35k.
- An audio-reviewer was run on 2a72b60..17a760e (see its findings in the session).

- The owner's Bittern vision (cinematic wall of sound, rock organ stage, hyper-organ; not urgent): staged plan in
  Hub #33, with two questions (where the rock organ lives: the tonewheel question; the controls' look).

## Next
1. Watch PR #269's CI (Windows mix_pool timing test is flaky).
2. Two-modes design question to the owner; then build.
3. Older: Curlew more winds; Starling treble/top zones; live-path gate test branch; undo CI loosening (Curlew in the
   stress mix match); performance p99; Rook optimisation and kick tools (last).
