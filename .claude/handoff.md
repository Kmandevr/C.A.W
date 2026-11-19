# Handoff

Commit: dab8d79 (Main: v1.0.8-alpha.1 released; the session branch holds 1.0.9, not yet in a PR)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. **The owner's standing instructions and the full plan** are in the private Kmandevr/AutoStacc-Hub, in the caw folder's sound-plan note ("The owner's standing instructions…" at the top). Read that first.

## Goal
1. Ship **1.0.9**, the performance release, then the owner reruns the S22+ Benchmark.
2. Build **1.1.0**, the effects and instruments suite, without the owner, except for logo designs and the pitch editor's look.

## Done and verified
- The session branch has the 1.0.9 work merged (the stabilizer and spike fixes, the fair Benchmark, the DSP pass), the version 1.0.9-alpha.1 with its CHANGELOG, and TRADEMARKS.md. `ctest` passes 11/11 and the full app suite passes (2572).

## Open
- The owner: rerun the Benchmark after 1.0.9; approve the logo designs; choose the pitch editor's look.

## In progress (pushed as backup branches)
- **fix-109** (`caw-backup-fix-109`): the audio-review fixes (the EQ band after a type change, the stabilizer's epoch drift, its load gate, arm64 bits).
- **review-109** (`caw-backup-review-109`): the external-review fixes (the MIDI ring, library warming, Play/Stop status at C API 40, project-sized caps, `send` failures reported, ratchets up to 64).
- **1.1.0 done, waiting for 1.0.9 to ship:** `caw-1.1.0-dsp-drive` and `caw-1.1.0-dsp-tools`. The MIDI effects' C API must be renumbered above 40.

## Rules for continuing
- **No lost work:** push after every commit (the session branch, or a `caw-backup-*` branch).
- **Loop guard:** never repeat a failed attempt; try different fixes or workarounds. Block an item only when the approaches run out or it needs the owner, and keep other work going. At most one CI re-run per failure.
- **Efficiency:** 2–3 well-briefed agents at a time, short output; the agents' common brief is in the plan's standing instructions.
- **Check-in:** a recurring check-in every 5 hours resumes work from this file.

## Blocked
- (none)

## Next
Merge fix-109 and review-109, then full tests, the PR, CI, merge and the release. Then 1.1.0 in the plan's order.
