# Handoff

Commit: 8b67c19 (Main after PR #196: v1.0.0-alpha.1)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. The owner wants ONE combined APK at the end.

## Goal
v1.0.0-alpha.1 "Open alpha". The plan is in docs/beta-readiness-plan.md (#187), and the owner's answers are in docs/decisions.md.

## Done and verified
v1.0.0-alpha.1 is in Main (PRs #194, #195 and #196, all CI green). The APK came from app.yml run 43364762201 (artifact caw-android-apk).

## Open
- The owner creates the tag v1.0.0-alpha.1 on GitHub; this session couldn't push tags. That publishes the GitHub Release.
- Auto's tail guard: unfinished in .claude/worktrees/audio-integration (local commit 1967852 plus uncommitted test changes). Run the full ASan and TSan suites, then PR.
- Owner questions: governing law for TERMS.md; the Windows engine with clang-cl/x86-64-v3; music video packages carrying images; Benchmark tuning on the S22+.
- The owner plans changes after testing the alpha.
