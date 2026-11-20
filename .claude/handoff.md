# Handoff

Commit: 03f36ce (Main: v1.1.0-alpha.1 released 2026-11-19, PR #258; the sanitizer table PR #259 merged)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. **The owner's standing instructions and the full plan** are in the private Kmandevr/AutoStacc-Hub, docs/caw/sound-plan.md ("The owner's standing instructions…" and "After 1.1.0: the owner's feedback (2026-11-20)"); the roadmap is docs/caw/roadmap.md. Read those first.

## Goal
1. **1.1.1 (fixes):** the spikes (while playing, opening menus, device pages open), device visuals slowing the app, the echo in older Flagship patches, and Bits' new bitwise modes.
2. **1.1.2 (realism):** Timber fully simulated (mechanical noises, transients); Rook's kit modes from synthesized to polished EDM to a simulated real kit (not a morph knob; build each kind quickly). Plan it with the owner's answers in the Hub before building.

## Done and verified
- 1.1.0-alpha.1 released with APK, Windows zip and update files. The owner's Benchmark after it: the stabilizer on, 0 xruns live, low-latency at 192 frames.
- CI lessons: bits are per build. The drums compat test has tables for x86-64 Release, Arm64, Windows x64 and x86-64 Debug, each from 20bcb8b's own code. Cost tests run RUN_SERIAL. Carve, Mimic and Raven's files build strict-FP.

## Running (worktrees under .claude/worktrees; push them to caw-backup-* at check-ins)
- fix-spikes (perf: engine timing, header CPU readout, visuals, menus), fix-raven-echo, bits-modes.

## Open (owner)
- Branch cleanup: this session can't delete branches (the proxy refuses); the owner deletes merged ones on GitHub.
- Logo designs to approve; Rook groove look-ahead question (docs/decisions.md).
- Follow-ups: arming clicks (Lark's dry ring, Ducker/Talon look-ahead jumps); Magpie keyboard zoom; back up a project before its first conversion; Timber at medium+20 % (owner may prefer optimising).

## Rules for continuing
- **No lost work:** push after every commit; agents can't push, so the main session pushes their branches to `caw-backup-*`.
- **Loop guard:** never repeat a failed attempt; one CI re-run per failure; block only when approaches run out or the owner is needed.
- **Efficiency:** 2–3 well-briefed agents at a time; short output.

## Next
Merge the three agents after tests, then the 1.1.1 version bump, CHANGELOG, PR, CI, merge and release (dispatch app.yml with installables and release on Main). Then plan 1.1.2.
