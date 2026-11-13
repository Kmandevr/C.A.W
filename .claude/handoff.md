# Handoff

Commit: Main c6cf7ee (PR #195 merged) + session branch decision edit.
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. The owner wants ONE combined APK at the end.

## Goal
v1.0.0-alpha.1 "Open alpha". The plan is in docs/beta-readiness-plan.md (#187), and the owner's answers are in docs/decisions.md.

## Done
In Main: startup screen and updates (#194); music video round 2 and smaller updates (#195). The owner chose to keep the APK's native libraries compressed (recorded).

## Engine work (all pushed, not yet in Main)
- **origin/benchmark (084eede):** audio-integration dcf7ec9 (audio-resilience, bt-clicks, speed-parallel; C API 28) + the Benchmark (C API 29) + engine-a345 (A3/A4, reviewed clean) + session branch. All checks green.
- **origin/audio-integration:** review fixes 7e58422, fcde317, f7c0712 (done, green). An agent was building a tail-based Auto fallback (the pool turns off when its tail is worse than serial's). Check the branch for a newer commit.

## Next
1. Merge origin/audio-integration (the fixes, plus the tail guard if committed) into benchmark. Rebuild, then run ctest, the sanitizer and TSan (mix_pool, shed, overload, stress_), flutter analyze/test and docs-test --strict.
2. Merge benchmark into the session branch, PR to Main with Closes #133, and merge when green.
3. Fit-and-finish, the docs pass, the bump to 1.0.0-alpha.1, then dispatch app.yml installables and send the owner the one APK. Tag on the owner's go.

## Owner questions open
- Governing law for TERMS.md.
- Windows engine with clang-cl / x86-64-v3 (A5, decisions.md).
- Whether music video project packages carry their images.
- Benchmark tuning on the S22+: the 70% "comfortable" line; live mode.
