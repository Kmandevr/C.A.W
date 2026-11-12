# Handoff

Commit: d932771
Branch: ccr-56285e11-0xrj3h. PR #193 is open: telemetry, frames follow-ups and Flagship tests. Merge it when CI is green. Main is protected, so changes go in by PR. The owner wants ONE combined APK at the end, with no test builds in between.

## Goal
Finish everything for v1.0.0-alpha.1, the "Open alpha".
- The plan is in docs/beta-readiness-plan.md (#187), and the owner's answers are in docs/decisions.md.
- Already given: privacy minimum age 16; yes to smaller update downloads; the Benchmark is the top priority.
- Render-ahead is planned for 1.2.0.

## Done and verified
In Main: speed phases 1-4, Flagship A2, frames up to 240 Hz, smooth meters, the music video editor and render fix, editing cues, gestures, project folders.

## Open (branches in .claude/worktrees/<name>; check git log and status in each)
- **audio-resilience:** fixes the mic. Separate devices plus a foreground service; the owner confirmed it on the phone. Still doing: the mic clock-drift review fixes, a battery row, and merging origin/Main.
- **bt-clicks:** overload shed and restore, the block FIFO, the ducker fix, and C API 26. Fixing the FIFO review items. Its merge notes are in docs/engine.md.
- **speed-parallel:** phase 5a-5d is built and measured (C API 24). Check that the worst case is no worse than serial before merging.
- **Merge order:** integrate audio-resilience, then bt-clicks, then speed-parallel in one go. Follow the "Merge notes": FIFO always on, bridge input inside the render lambda, pool timing before reportLoad's early returns. Reconcile the C API version.
- **startup-screen:** the startup screen plus the updates system. An agent is merging the session branch into it after conflicts in about 10 files; merge it afterwards.
- **Still in progress:**
  - benchmark: section C, phases P1-P7, C API 27; top priority.
  - delta-updates: built on startup-screen.
  - engine-a345: A3 first callback, A4 #133, A5 CPU features.
  - music-video-v2: tabs, text, images, transitions, camera, render speed.

## Next
1. Merge PR #193, then startup-screen.
2. Integrate the three audio branches, then benchmark, delta-updates, engine-a345 and music-video-v2.
3. Fit-and-finish, the docs pass, bump to 1.0.0-alpha.1, then one APK to the owner and the tag once the owner says go.

## Read first
- docs/beta-readiness-plan.md, docs/decisions.md (top entries), .claude/rules/engine.md
