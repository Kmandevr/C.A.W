# Handoff

Commit: 4f14faf (merged here: sound fixes, Timber removal, instrument pages; Unison per key)
A 5-hourly scheduled wake-up resumes this session. Owner's standing rules: `.claude/rules/done.md`, docs/decisions.md 2026-11-25.

## Goal
Make 1.1.3 usable: 1.1.3-alpha.3 with the instrument fixes, pages, Timber removal, guitar/harp, Bittern, Rook; then 1.1.4+.

## Done and verified (each an agent branch; commit 81b1cab has every tip as a parent, so all are on GitHub)
- Guitar + harp: worktree-agent-a7fa15840664e0054 df0139b (based on 1061175).
- Bittern rebuilt: worktree-agent-a2bd9b4251d2239fc d78ecb5 (agent now cutting cost to 24000 and fixing dead knobs).
- Rook: worktree-agent-a9a7423dda65ed684 a34a276 (kinds, Studio kit, presets, Randomness).
- Live-path gate test: worktree-agent-adafbe12bcaece343 f4ea097.

## Open
- Owner decisions: tonewheel organ to Kestrel or Bittern (kTonewheelToKestrel); Bittern swell only the Swell?; Rook cards/Studio; panels; EP/tonewheel by ear.
- Undo my CI loosening: put Curlew back in the stress mix match; reconsider the Friction 1 dB class after the body refit.
- S22+ Benchmark (docs/performance.md 2026-11-25): Every effect and extreme songs drop out; low-latency live p99 over
  budget; callback on little cores, low clocks; live parts unprofiled; sustained run never ran. Perf agent after merges.

## Next
- Owner (2026-11-25, on alpha.2): Starling Unison sounds weird, not out-of-tune; Noise/Resonance/Pitch glide/Sympathy/Phantom
  inaudible; Upright/Felt unrealistic; a high, distortion-like sound at note ends (probe: scratchpad zz_starling_probe.cpp).
  Strings: no low end or body (8 narrow bands): build a full measured body (convolution or many bands) per instrument.
  Woodpecker needs more settings: strike position, mallet type, bar material/ratios, resonator tuning, rolls,
  dead strokes, timpani pedal glide, stereo layout (each audible, in the knob test).
  Curlew: mono legato by default (a new note while held slurs: no re-attack; a gap re-tongues; Poly option), and
  most of the wind family (piccolo, alto flute, recorder, oboe, cor anglais, bassoon, bass clarinet, saxes, tuba...).
0. All agents were STOPPED by the owner (usage). Their tips are parents of b35881e (pushed). Resume work
   yourself, one piece at a time, pushing after each step; don't spawn many agents at once.
   Performance goal (owner): close the gap between the 1% high (p99) CPU and the mean, keeping the mean low
   (spikes cause drops); no frame-rate work. 1.1.2 didn't drop: find what 1.1.3 changed.
   Check first: RecordedBanks decoding/allocating when unused or while playing (prepare() mutex), body filters
   running per silent voice, shared code the 1.1.3 PRs touched; diff the S22+ rows vs 1.1.2 on one bench build.
1. Done: alpha.2 (#266); sound fixes merged here (starling/nightingale/curlew/woodpecker/audibility/glitch/stress pass).
   Next: timber-removal (expect rename conflicts with the sound fixes in timber_piano*/timber_mallet_wind.h).
2. Merge in order: timber-removal, sound fixes, instrument-pages, guitar/harp, Bittern, Rook, gate test; resolve
   conflicts (stress hash/refs, changelogs, CMakeLists, device_names); a branch already a parent of 81b1cab merges
   with `git merge -s recursive <tip>` only after reverting nothing: use `git cherry-pick <base>..<tip>` instead.
3. Full suites, audio-reviewer + code-reviewer agents, release 1.1.3-alpha.3 with screenshots to the owner.
