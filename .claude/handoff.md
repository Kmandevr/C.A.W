# Handoff

Commit: 655839e

Branch: ccr-56285e11-0xrj3h (PR #167 open, subscribed, CI green at aa1ee28)

## Goal
Owner (2026-11-10): work through everything discussed toward the open beta, without the owner's input except where a call is genuinely theirs; don't message them unless something is on fire.

## Done and verified (on this branch, pushed)
- Bend-in-clips fix; decisions (polyphony, landscape, inefficient plug-ins).
- Logo C5 (owner-approved) in app, Android adaptive icon, Windows icon, SVGs in `app/assets/logo/`. Logo changes need the owner's explicit yes.
- GitHub Releases in `.github/workflows/app.yml` (tag v* or Run workflow + release); APK native libs compressed. No release made yet.
- Library kernels: lfo/wavetable/reverb/smoothing headers + tests (not yet used by any built-in).
- MIDI file import/export in Dart (`app/lib/model/midi_file.dart`, `app/lib/model/midi_clips.dart`, `app/lib/ui/midi_file_actions.dart`).

## Open
- #175 agents all merged (polish-pass, mod-ux, routing-ducker); app 815 tests and engine ctest pass at 655839e. APK at c8a9bef sent to the owner.
- Running: `settings-redesign` (worktree `.claude/worktrees/settings`; owner chose a category list + search, every setting, full audio device/buffer control, nothing hidden; new C API goes in as API 10), `engine-133` (worktree `.claude/worktrees/e133`, #133), and an audio review of the routing/ducker engine code.
- Owner choices from the agents to batch at the end: Build start page vs last tab, Try-it replaces an instrument without confirm, sheets under 600 dp, Files toggle vs slider; new-route amount 25 %, bipolar defaults, Flagship tabs, EQ double-tap = reset; routing defaults (decisions.md 2026-11-11).

## Next after merges
- reaper-flow gaps 5-10 (sends/buses, render parity, actions, MIDI editor flow, mixer parity, templates), #161 modulators/routing, testing-suite and sample-pack screens, mixer label shows instrument name, #133 leftovers, then #160/#159 (.caw removal, .caw project extension).
- Then build an APK (Run workflow on this branch) and send it to the owner.

## Owner's calls pending
- Confirm MIDI storage (pattern text + SMF exchange); Android developer verification (2027, see vision.md).

## Read first
- `docs/decisions.md`, `docs/app.md`
