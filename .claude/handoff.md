# Handoff

Commit: 81b1cab (branch ccr-bd7ac4df-86w0bh; 1.1.3-alpha.1 released, Woodpecker merged as #265 but NOT released)
A 5-hourly scheduled wake-up resumes this session. Owner's standing rules: `.claude/rules/done.md`, docs/decisions.md 2026-11-25.

## Goal
Make 1.1.3 usable: P0 knob fix first (ships alone as 1.1.3-alpha.2 with Woodpecker), then 1.1.3-alpha.3 with the
instrument fixes, pages, Timber removal, guitar/harp, Bittern rebuild and Rook. Then 1.1.4+ toward 1.2.0.

## Done and verified (each an agent branch; commit 81b1cab has every tip as a parent, so all are on GitHub)
- P0 knobs: worktree-agent-a07dd3b1b8a4ed5f8 (e253fc8, WIP, nearly done): gestureSettings slop 18 vs 8 root cause,
  long-press fold, DragStartBehavior.down, knob-face grab, 35 deg/250 ms, owner-use suite at 8 px.
- Pages: instrument-pages 00f0ec9 (five instrument pages; goldens sent to the owner).
- Timber removed: timber-removal 2be8f21 (mapping in timber_migrate.cpp; files moved to instrument_core.h etc.).
- Guitar + harp: worktree-agent-a7fa15840664e0054 df0139b (based on 1061175).
- Bittern rebuilt: worktree-agent-a2bd9b4251d2239fc d78ecb5 (agent now cutting cost to 24000 and fixing dead knobs).
- Rook: worktree-agent-a9a7423dda65ed684 a34a276 (kinds, Studio kit, presets, Randomness).
- Sound/knob fixes: worktree-agent-a3a048819bdc1da79 4f2770e (WIP: Starling knobs/characters, growl, peaks, bodies).
- Live-path gate test: worktree-agent-adafbe12bcaece343 f4ea097 (WIP; app wiring fine, all dead knobs are DSP).
Fixed on this branch: version.dart appBuild 18; rules done.md; decisions 2026-11-25.

## Open
- Owner decisions: tonewheel organ to Kestrel or Bittern (kTonewheelToKestrel); Bittern swell encloses only the Swell?;
  Rook kind cards' place and Studio as default; panel names; EP/tonewheel presets need listening.
- Undo my CI loosening: put Curlew back in the stress mix match; reconsider the Friction 1 dB class after the body refit.
- No steel-string guitar (no CC0/CC-BY source).

## Next
1. Merge the P0 branch, full flutter test, PR, release 1.1.3-alpha.2 (app.yml dispatch on Main, release=true).
2. Merge in order: timber-removal, sound fixes, instrument-pages, guitar/harp, Bittern, Rook, gate test; resolve
   conflicts (stress hash/refs, changelogs, CMakeLists, device_names); a branch already a parent of 81b1cab merges
   with `git merge -s recursive <tip>` only after reverting nothing: use `git cherry-pick <base>..<tip>` instead.
3. Full suites, audio-reviewer + code-reviewer agents, release 1.1.3-alpha.3 with screenshots to the owner.
