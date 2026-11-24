# Handoff

Commit: 5065ba9 + this note. PR #261 is open for 1.1.2-alpha.1 on the session branch.
Branch: ccr-56285e11-0xrj3h. Main is protected, so changes go in by PR only; merge it yourself once CI is green. **The owner's standing instructions and the full plan** are in the private Kmandevr/AutoStacc-Hub: docs/caw/sound-plan.md ("After 1.1.1 (owner, 2026-11-24)"), docs/caw/roadmap.md and docs/caw/phone-performance-research.md. Read those first.

## Goal
Release **1.1.2** (realism plus playback fixes): merge PR #261, then dispatch app.yml on Main with installables and release.

## Done and verified
- 1.1.2 contents:
  - Timber Simulated (all models) and Rook's Synth, Produced and Acoustic kits.
  - Playback on the phone, applying the Hub research: no heat action, the busy-spin retired, workers unpinned, the buffer tuner on, path diagnostics, a Low-latency-only fast-path retry, and a device reopen within 1 s.
  - Freeze hint only on real dropouts; heat shown as a plain reading.
  - The Performance sheet (look approved by the owner) and scroll-safe device controls.
  - The Benchmark generated from the registry; the piano generator's overflow fixed.
- Local checks: ctest 24/24 and flutter test 2819 pass.
- The every_instrument cross-build match leaves out the bowed strings (owner OK, 2026-11-24).

## State
- **CI on 5065ba9:** Arm64 and x64 engine tests pass. The Dart job hit the timing-flaky startup reveal test (it passes locally alone and with its file), and its one re-run was triggered. The rest was still running.
- Lessons are saved in .claude/rules (engine, ci, app) and .claude/README.md ("Session quirks").
- 1.1.3 maintenance (big files and CI broken down, tooling) is Hub issue #29 and on the roadmap.

## Open (owner)
- Optional: lower the UI to 60 Hz while playing (always, as a setting, or no).
- Rook "Build a kit" card look; Acoustic piece and mic screens not designed.
- Branch cleanup: the proxy refuses branch deletes, so the owner deletes them on GitHub.

## Rules for continuing
- **No lost work:** push after every commit, and back up agent worktrees to `caw-backup-*`.
- **Loop guard:** one CI re-run per failure; never repeat a failed attempt.
- **Efficiency:** 2–3 agents at a time, short output, a recommendation with every question.

## Next
- When #261 is green: merge it, dispatch the 1.1.2 release, and ask the owner for a Full Benchmark (stream.path, callback_policy, buffer_frames growing).
- Follow-ups: the motion cap follows the Frame rate setting; the compat tables still to record (Hub #29).
