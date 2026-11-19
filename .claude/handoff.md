# Handoff

Commit: 71866ec (Main 41f9c1b: v1.0.9-alpha.1 released 2026-11-19 with 6 assets, PR #257)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. **The owner's standing instructions and the full plan** are in the private Kmandevr/AutoStacc-Hub, in the caw folder's sound-plan note ("The owner's standing instructions…" at the top). Read that first.

## Goal
1. **1.0.9 is released.** The owner reruns the S22+ Benchmark; live rows should show the stabilizer on and the callback clock well above 634 MHz.
2. Build **1.1.0**, the effects and instruments suite, without the owner, except for logo designs and the pitch editor's look.

## Done and verified
- The session branch has the 1.0.9 work merged (the stabilizer and spike fixes, the fair Benchmark, the DSP pass), the version 1.0.9-alpha.1 with its CHANGELOG, and TRADEMARKS.md. `ctest` passes 11/11 and the full app suite passes (2572).

## Open
- The owner: rerun the Benchmark after 1.0.9; approve the logo designs; choose the pitch editor's look.

## In progress (pushed as backup branches)
- **1.1.0 integrated on the session branch** (a3a3bc7: Delay, Reverb, Drive, Bits, Cab, MIDI effects at API 41, Meters, Lo-fi, Phase align, the Talon/Hatch/Duck split, Plume, Wah). ctest 13/13, app suite 2580.
- **Running from a3a3bc7** (push them to `caw-backup-*` at check-ins): dsp-voice (Glint, Soar's Harmonizer and Octaver, Mimic), dsp-clean (Preen, Hush), ui-modes (pages for the new modes, by the approved device UI plan).
- **Follow-ups:** back up a project before its first conversion; Pedal gate's pre-FX key; an armed signal for effects.

## Rules for continuing
- **No lost work:** push after every commit. Agents can't push (their permissions refuse it), so the main session pushes their branches to `caw-backup-*` at each check-in and merge.
- **Loop guard:** never repeat a failed attempt; try different fixes or workarounds. Block an item only when the approaches run out or it needs the owner, and keep other work going. At most one CI re-run per failure.
- **Efficiency:** 2–3 well-briefed agents at a time, short output; the agents' common brief is in the plan's standing instructions.
- **Check-in:** a recurring check-in every 5 hours resumes work from this file.

## Blocked
- (none)

## Next
Merge fix-109 and review-109, then full tests, the PR, CI, merge and the release. Then 1.1.0 in the plan's order.
