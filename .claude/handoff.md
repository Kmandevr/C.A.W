# Handoff

Commit: a3f67b4 (session branch: 1.0.1-alpha.1, everything merged; PR to Main next)
Branch: ccr-56285e11-0xrj3h. Main is protected: PRs only; merge yourself when CI is green. The owner wants ONE combined APK at the end.

## Goal
Ship v1.0.1-alpha.1, the polish release. The app stays alpha until the owner calls the official release (docs/decisions.md).

## Done and verified
- v1.0.0-alpha.1 is in Main (PR #196).
- The session branch adds:
  - the layout fit pass and the decision-check fixes;
  - the tail guard;
  - Low latency at the device's burst size, plus the reroute and latency fixes;
  - Benchmark accuracy fixes;
  - Flagship #197: fold mode, the hybrid ADAA/2x fold and the float drive;
  - version 1.0.1-alpha.1+4.
- Checks on a3f67b4: Release ctest 11/11; flutter analyze clean; flutter test 1954 passed with 3 skipped; docs-test --strict PASS.

## Open
- The tag v1.0.0-alpha.1 (and later v1.0.1-alpha.1): the owner creates it on GitHub, because this session can't push tags.
- #197 (next update): the plug-in benchmark in the Builder, plus the full-coverage Benchmark with a per-engine-part breakdown. Ask the owner how the screens should look first.
- Owner questions:
  - governing law for TERMS.md;
  - the Windows engine with clang-cl/x86-64-v3;
  - whether music video packages carry their images;
  - the dead "Swap timing" setting;
  - an age line on the first-run page;
  - frame caps on Windows;
  - Minimal on a screen with no 30 Hz mode;
  - how to tell the user that shed layers came back.

## Next
1. Open a PR from the session branch to Main for 1.0.1-alpha.1, and merge it when CI is green.
2. Dispatch app.yml with installables on Main, and send the owner the APK link.
3. Start #197.
