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

## The owner's standing instructions (2026-11-19, the owner is hands-off)
- **Finish without the owner** everything that can reasonably be done. Research and plan what needs it; question your own choices and check facts against primary sources and the current code, not old notes. Queue real owner decisions as one short question each.
- **Order of work:**
  1. **1.0.9, the performance release:**
     - the stabilizer and spike fixes, the fair Benchmark, and the DSP pass (all merged);
     - the audio-review fixes (fix-109);
     - the external-review fixes (review-109): the MIDI ring with reserved note-off slots, warming native libraries, Play/Stop status returning a value (C API 40), project-sized route and modulation caps, every `send` failure reported, ratchets up to 64 (app mirrors included).

     Then the version, PR, CI, merge and release. Afterwards the owner reruns the S22+ Benchmark.
  2. **1.1.0, the suite,** per the Hub's sound-plan note:
     - **Merge the finished parts:** `caw-1.1.0-dsp-drive` and `caw-1.1.0-dsp-tools`. Renumber the MIDI-effects C API above 1.0.9's 40.
     - **Write designs first** into the private plan: Timber (the piano kept clear of Pianoteq's patent), Lark (live correction plus a one-voice editor), Preen, the grain engine Murmur and Flock share, and Raven's synthesis.
     - **Then the engine work:**
       - the Talon/Hatch/Duck split with migration;
       - Plume's dynamic EQ, M/S, band solo, Match and Linear-phase;
       - Wah, Harmonizer, Octaver, Glint, Mimic, Preen and Hush;
       - the pack;
       - the instruments.
     - **Then the pages:**
       - effect pages by the approved device UI plan, instruments in Raven's layout;
       - names and search tags;
       - the subtle crow theme, the personality touches and the Easter eggs (all listed privately).
     - **Waits for the owner:** each logo design needs the owner's yes, and the pitch editor's look needs options shown to the owner.
- **Efficient and safe:**
  - the most work per token: 2–3 well-briefed agents, short output, no re-reading; a steady pace;
  - after every commit, push the session branch or a `caw-backup-*` branch, so a sudden stop loses nothing;
  - try genuinely different fixes before blocking anything, and never repeat an attempt;
  - every device is built efficiently from the start, with CPU and RAM ceilings in CI.
- **Brand:** the code stays Apache 2.0, and the brand is reserved (TRADEMARKS.md, which goes public with the 1.0.9 PR). Device names and presets avoid artists' names.

## Rules for continuing (owner, 2026-11-19; the owner is hands-off)
- **No lost work:** every branch is pushed after each commit, either the session branch or a `caw-backup-*` / `caw-1.1.0-*` backup branch.
- **Loop guard:**
  - never repeat the same attempt; try genuinely different fixes or reasonable workarounds instead (owner);
  - an item goes under "Blocked" only when the different approaches are used up or it needs the owner, and other work carries on meanwhile;
  - at most one CI re-run per failure;
  - no agent is restarted for the same item more than once.
- **Check-in:** a recurring check-in every 5 hours resumes work from this file.

- **Efficiency (owner):** the most work per token. Few, well-briefed agents (2–3 at once), short command output, no re-reading. Steady pace, no rushing.

## Blocked
- (none)

## Next
- Merge each finished part; run `ctest` and the full `CAW_LIB=… flutter test` (roll_preview flakes under load; rerun it alone).
- Then the 1.0.9 version bump, CHANGELOG, PR and release.
- The PR also fixes public `docs/decisions.md`: the Hub goes into use with 1.2.0, not 1.1.0.
- Then the rest of 1.1.0: Talon, Gate and Duck split with migration; Plume's dynamic EQ; Raven's synthesis; the instruments (Raven layout for all); the pages; names and tags.
- A recurring check-in (every 5 hours) resumes work after usage resets.
