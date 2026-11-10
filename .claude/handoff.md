# Handoff

Commit: 311a9df

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
Agents for #175 (polish round) plus one engine pass, each in its own worktree; merge each when done (full engine + app tests):
- `.claude/worktrees/flagperf` (flagship-perf): get each Flagship preset back to or below the retired synth's CPU.
- `.claude/worktrees/routing` (routing-ducker): sends, buses, sidechain, `org.caw.ducker`, routing UI.
- `.claude/worktrees/presets` (user-presets): save/load user presets and track presets.
- `.claude/worktrees/modux` (mod-ux): Vital-style modulation on touch, EQ usability, fewer separate screens.
- `.claude/worktrees/polish` (polish-pass): Builder clarity, polish audit of every other screen.

## Next after merges
- reaper-flow gaps 5-10 (sends/buses, render parity, actions, MIDI editor flow, mixer parity, templates), #161 modulators/routing, testing-suite and sample-pack screens, mixer label shows instrument name, #133 leftovers, then #160/#159 (.caw removal, .caw project extension).
- Then build an APK (Run workflow on this branch) and send it to the owner.

## Owner's calls pending
- Confirm MIDI storage (pattern text + SMF exchange); Android signing secrets.

## Read first
- `docs/decisions.md`, `docs/app.md`
