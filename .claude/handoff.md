# Handoff

Commit: 313975b
Branch: ccr-56285e11-0xrj3h (PR #178 open into Main, watched; Main protected: PRs only, owner said merge yourself when CI is green)

## Goal
Owner (2026-11-11): keep working through everything planned toward v1.0.0-beta.1; build each request they gave today (all recorded in `docs/decisions.md`, newest first); then speed pass, fit-and-finish (every change animates: `.claude/rules/app.md`), docs pass, version bump, pre-release. Resume at 5:50 pm owner time (America/New_York) via a scheduled message.

## Done and verified (on the branch, pushed)
- Merged to Main via #176/#177: desktop batches, leftovers, track cards, Flagship extras, Plug-in page, instant taps, Windows UTF-8 fixes.
- On #178 (pushed, CI running): themes (5 families light/dark, theme editor, feel, animation style), music video (setup, auto director, preview, MP4 via MediaCodec / Media Foundation, encoders never compiled yet: first compile is the app.yml dispatch run at 313975b). Local: `flutter analyze` clean; `flutter test -j 4` 1358 passed on the theme merge; music_video + workspace tests pass.

## Open (agents in worktrees `.claude/worktrees/<name>`; if the session restarted, read each branch's `git log ccr-56285e11-0xrj3h..<name>` and finish/merge it)
- `track-headers` (+ endless scroll right, revealStart API): collapse states, per-track height, indent, upright meters, header tap=focus instantly / double tap=FX / hold=menu, selected-clip tap opens editor, follow pause + setting (2.5 s, off, never) + Smooth style, snappy move animation, resize reveals not stretch, header/panel animations in and out, empty-arrange hint centred, deep zoom out. Decisions: "Track headers that shrink…", "Every change animates".
- `keyboard-a` (⏮ double tap also scrolls views to start via an AppState hook; arranger side in track-headers): keyboard-only contexts (FX chain, devices, mixer, Files, Build, Settings, menus), hint strip, exit animations outside Arrange, ⏮ back-to-start button (tap loop start, double tap project start, Home/Ctrl+Home). Batch B (Arrange/roll keyboard) after track-headers.
- `video-smooth`: music video "Smooth follow" switch (off by default).
- `latency-comp`: output latency compensation (Bluetooth etc.): measured + per-device offset + calibration, audible playhead, recording placement, badge; new C API number; lists UI consumers to switch.
- `perf-pass`: engine/effects CPU pass (owner's "mid tempo" 3 tracks = 49% CPU); Flagship hotspots to fix after.
- Next waves: layout file phase 1 (decisions "A REAPER-style layout file"), phone ⋯ More / search / hints (decisions "Finding things on a phone"), desktop look batch C (`scratchpad` gone after restart: see decisions "Desktop plays to desktop strengths"), midi_clips learned-CC wire-up, platform-modularity plan fold-in (commit b10d640 if still present).
- Owner questions open: per-note FX look/over-budget; plugin pipeline state saved in project?; Reset curve meaning; layout-file custom labels/packages/one file.

## Next
- When #178 CI is green: merge into Main. Check the 313975b APK run (encoder compile); send the owner the APK link.
- Merge each agent as it reports (analyze, full `CAW_LIB=… flutter test`, docs-test --strict, push, PR).

## Read first
- `docs/decisions.md`
- `docs/app.md`
- `.claude/rules/app.md`
