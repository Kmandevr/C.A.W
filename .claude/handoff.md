# Handoff

Commit: ed86bfa
Branch: ccr-56285e11-0xrj3h (session branch; Main protected: PRs only, merge yourself when CI green, then dispatch app.yml installables and send the owner the APK link)

## Goal
Owner, 2026-11-12: wrap everything up toward the v1.0.0-alpha.1 "Open alpha" release.
- The plan is docs/beta-readiness-plan.md (issue #187), and docs/decisions.md holds all the owner's answers.
- Every speed gain is kept. A gain is rejected only if it makes the engine unstable.

## Done and verified
- **In Main:**
  - speed phases 1-4
  - frame-rate setting
  - music video editor (#182, #183)
  - latency and atomic-save fixes
- **On the session branch, pushed and not yet in Main:**
  - Flagship A2: −20% on the heavy patch on Android arm64; audio review clean
  - ui-frames: cheap frames, profile frame caps, smooth meters fix, C API 25; engine ctest passed
  - Pending before its PR: the app test run (`flutter test` with CAW_LIB=scratchpad/build-main/libcaw.so).

## Open (worktrees in .claude/worktrees/<name>; on restart read `git log ccr-56285e11-0xrj3h..<name>`)
- **speed-parallel:** phase 5 review fixes plus A1/A6 scheduling. It took C API 24; reconcile with 25 on merge. Keep Auto off where the worst case is worse than serial.
- **telemetry-feedback:** security fixes in progress (USB iProduct dropped, screen and peripherals coarsened, a backup rule for the corrupt-file temp copy). The relay contract is in C.A.W-Telemetry's PLAN.md.
- **startup-screen:** startup screen plus the update system. Security fixes in progress: the receiver must not be exported, no Windows installer kind, a pinned download path, SHA-256 in release notes, timeouts, CI upload order.
- **editing-cues:** roll cursor and loop, loop collapse, drag guides and gestures are done. The zoomed-out thin note lines are in progress.
- **project-library:** select mode, folders and metadata.
- **audio-resilience:** the mic is opened only when needed; output survives other apps taking the mic and focus loss.
- **flagship-tests:** A2 review follow-ups (prune, wording, tests).
- **Not started:**
  - Stress test / Benchmark (C): plan in scratchpad stress_architect_plan.md; start after speed-parallel merges.
  - A3 (first callback), A4 (#133), A5 (CPU features).
  - A7: a reverb-bus proposal for the owner.
  - Delta updates: research done, ask the owner.
  - Fit-and-finish, the docs pass, G2 per-platform notes, the bump to 1.0.0-alpha.1, the release.

## Next
1. When the app tests pass, open a PR for the session branch into Main (frames, meters, Flagship), merge it when green, and send the APK.
2. Merge each open branch as its agent reports, with its checks run.
3. Then start the Benchmark, A3–A5 and the release steps.

## Read first
- docs/beta-readiness-plan.md
- docs/decisions.md (top entries)
- .claude/rules/engine.md
