# Handoff

Commit: b0228c1 (Main: v1.0.8-alpha.1 released 2026-11-19, PR #255 merged as 78c994b)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. Plans live in the private Kmandevr/AutoStacc-Hub (its caw folder); the 1.1.0 plan is its sound-plan note.

## Goal
1. **1.0.9:** a performance release (owner, 2026-11-19).
   - Keep the audio core fast on the S22+: its performance hint is unsupported, so live playback spikes at a 634 MHz clock.
   - Remove one-off spikes and the 13 ms cold first callback.
   - Make the Benchmark fair: warm-up, clock and heat recorded, results adjusted for clock.
   - Make Flagship, EQ and Compressor cheaper.
   - After release, ask the owner to rerun the S22+ Benchmark.
2. **1.1.0:** the effects and instruments suite, names, theme, personality and Easter eggs (all in the private sound plan). Engine work starts where it doesn't touch 1.0.9's files.

## Done and verified
- 1.0.8-alpha.1 released with 6 assets; checks: `ctest` 11/11 and CI green on PR #255.

## Open
- Owner: rerun the S22+ Benchmark after 1.0.9 and approve the 1.1.0 logo designs and instrument pages as they land.

## In progress
- **fix-109** (local worktree): the 1.0.9 audio-review fixes:
  - (high) an EQ band never returns after a Type or Channel change;
  - the stabilizer's epoch drift;
  - early-callback spin stacking;
  - spinning only under real load;
  - arm64 pair-log bits.
- **The 1.0.9 release itself:** the session branch has 1.0.9 merged, the version bumped and CHANGELOG written, the full app suite passing (2572) and `ctest` 11/11. Merge fix-109, then PR, CI, merge, release, and the owner reruns the Benchmark.
- **1.1.0 parts done and backed up (owner allowed backup branches):**
  - `caw-1.1.0-dsp-drive`: Delay, Reverb, Drive, Bits and Cab modes;
  - `caw-1.1.0-dsp-tools`: MIDI effects (C API 40), Meters, Lo-fi, Phase align.

  Merge them after 1.0.9 ships. The app fixture needs a fresh dump, and both may touch the same shared files.
- **The owner's minor questions, decided by Claude** (record them in the private plan):
  - Cab plays C.A.W's own cabinets only, with user IRs in Convolver variant 0;
  - the 2 MiB Reverse delay is fine;
  - Bitwise maps silence to silence;
  - CI should run caw_bench mode 300 for the cost ceilings, added with 1.1.0.

## Next
- Merge each finished part; run `ctest` and the full `CAW_LIB=… flutter test` (roll_preview flakes under load; rerun it alone).
- Then the 1.0.9 version bump, CHANGELOG, PR and release.
- The PR also fixes public `docs/decisions.md`: the Hub goes into use with 1.2.0, not 1.1.0.
- Then the rest of 1.1.0: Talon, Gate and Duck split with migration; Plume's dynamic EQ; Raven's synthesis; the instruments (Raven layout for all); the pages; names and tags.
- A recurring check-in (every 5 hours) resumes work after usage resets.
