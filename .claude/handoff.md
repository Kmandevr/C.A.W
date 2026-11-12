# Handoff

Commit: b8422d8
Branch: ccr-56285e11-0xrj3h (PR #178 open into Main, watched; Main protected: PRs only, owner said merge yourself when CI is green)

## Goal
Owner (2026-11-12, newest): optimise the engine (engine/) for speed. Decision recorded (decisions.md top entry "Perceptually identical, not bit-identical"). Order: tolerance tests replace golden hashes → CI bench baseline (done: `docs/engine-performance.md`, `.github/workflows/bench.yml`) → phases, one PR each: 1 free wins (LTO, quiet/sleep everywhere, Eco lowers oversampling/FFT), 2 floating point (FTZ everywhere incl. offline, FMA/fast-math where tolerance passes, keep NaN/inf guards), 3 maths (detmath out of per-sample paths; keep bit ops for bitcrush/glitch), 4 precision/layout (float signal paths, double for phase/low-cutoff feedback; block-wise stages for NEON), 5 parallel mixer (architect review first; lock-free worker pool, fixed-order sum, big/little, fallback). audio-reviewer after each phase, code-reviewer before each PR. Ask owner if audible or a phase gains <5%. Done when all merged, tests green, before/after table per scenario (target ≈3–4x headroom on a typical song; report real number). No UI changes; C API only if needed (bump + app).
Then: earlier goal (v1.0.0-beta.1: fit-and-finish, docs pass, version bump, pre-release).

## Done and verified (pushed)
- Merged: default-project (owner's mid tempo is default/template), keyboard-a, track-headers (one `RevealStartRequest` back-to-start hook kept), latency-comp (C API 23; UI reads heard playhead/meters), engine-bench (baseline: flagship_heavy 64v ≈103% and song32_heavy ≈100% of budget on Android-arm64 target).
- Fixed: decisions.md conflict markers (ee40c08 had them), bench MSVC `__VERSION__`.

## Open (agents in worktrees `.claude/worktrees/<name>`; on restart read `git log ccr-56285e11-0xrj3h..<name>` and finish/merge)
- `tolerance-tests`: replace goldens with tolerance tests (−120 dBFS residual stable; loudness 0.1 dB + band spectrum chaotic; discrete exact; broken-case tests).
- `speed-free-wins`: phase 1 (must keep existing goldens passing; new tests in engine/tests/speed_free_wins_test.cpp).
- Owner questions open: latency badge placement; compensation default off for wired?; keyboard batch B WASD clash; per-note FX look/over-budget; plugin page state in project?; Reset curve meaning; layout-file custom labels/packages/one file.
- Next waves after speed: keyboard batch B (spec in decisions "The whole app works from the keyboard"), layout file phase 1, phone ⋯ More/search/hints, desktop look batch C, midi_clips learned-CC, platform-modularity plan.

## Next
- #178 green on 3bd5bd7 → merge into Main, dispatch app.yml with installables, send APK link.
- Merge tolerance-tests, then phase 1 (rebase on it), each its own PR into Main.

## Read first
- `docs/decisions.md` (top entry)
- `docs/engine-performance.md`
- `.claude/rules/engine.md`
