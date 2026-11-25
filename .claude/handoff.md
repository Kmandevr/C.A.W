# Handoff

Commit: 94afd84 pushed (Rook merged). Uncommitted on top (commits were refused by the permission check, 2026-11-25):
staged = Rook app fixes (hero on Simulated pads, owner-use test, Arrange FX golden); unstaged = Bittern as the
Tabernacle organ (engine, tests, refs, bench, page, fixture, docs). Commit both, push, then continue below.
A 5-hourly scheduled wake-up resumes this session. Owner's standing rules: `.claude/rules/done.md`, docs/decisions.md 2026-11-25.

## Goal
Make 1.1.3 usable: 1.1.3-alpha.3 with the instrument fixes, pages, Timber removal, guitar/harp, Bittern, Rook; then 1.1.4+.

## Done and verified (this session)
- Rook app fixes: flutter suite all green except the re-recorded Arrange FX golden (now passes).
- Bittern: 26 Tabernacle stops by division, enclosed Swell/Choir (box + tremulant), pedal on lowest key, 9
  registrations, hall 3.8 s, silent speech clips skipped. `caw_tests bittern` 22/22; full engine suite passes but the
  env-only native-loader test (needs CAW_TEST_COMPONENT_PATH); refs bittern + stress re-recorded. Cost x86 19.4k /
  32.9k / 35.1k µs/s (ceilings 27k/46k/50k). App: instrument_pages + use_like_owner (bittern) pass; full app suite
  was running with CAW_LIB=engine/build-organ/libcaw.so.
- Owner asked (UI look): is the 26-stop page (pills grouped by division) right, or real drawknob jambs?

## Open
- Owner decisions: tonewheel organ to Kestrel or Bittern (kTonewheelToKestrel); Rook cards/Studio; panels; EP/tonewheel by ear.
- Undo my CI loosening: put Curlew back in the stress mix match; reconsider the Friction 1 dB class after the body refit.
- S22+ Benchmark (docs/performance.md): drops in Every effect and extreme songs; low-latency p99 over budget.

## Next
1. Nightingale full measured body (low end, warmth); Woodpecker settings (strike position, mallet type, material,
   resonator tuning, rolls, dead strokes, timpani pedal, stereo), each audible in the knob test.
2. Curlew: most of the wind family (piccolo, alto flute, oboe, bassoon, saxes, tuba...).
3. Starling: treble decay, top zones (keys 105/108), the guitar's level jump above its range, the note-end "high note".
4. Merge the live-path gate test branch (worktree-agent-adafbe12bcaece343, f393ef7).
5. Reviewer agents (audio-reviewer, code-reviewer), release 1.1.3-alpha.3 with screenshots to the owner.
6. Performance (owner): close p99 vs mean, mean low; find what 1.1.3 changed vs 1.1.2 (banks decoding, silent bodies,
   little cores). 7. Last (owner): optimise Rook (~40 % CPU) without changing its sound; better kick tools.
