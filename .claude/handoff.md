# Handoff

Commit: a6e5374

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
Agents for #174 (owner's evening feedback), each in its own worktree; merge each when done (full engine + app tests):
- `.claude/worktrees/onesynth` (one-synth-perf): Morph/Bass/Acid/Basic become Flagship presets with migration; CPU "optimize to hell"; Quality and Buffer settings.
- `.claude/worktrees/plugui` (plugin-uis): plugin UIs for every built-in device, modern vector, more colorful.
- `.claude/worktrees/lanes` (arrange-lanes): MIDI notes in clips, unlimited folder nesting, automation lanes under tracks.
- `.claude/worktrees/framefeel` (frame-feel): top bars hide only on a pull, touch feedback, HD haptics, resizable landscape panel (2/3), desktop mode, UI perf.

## Next after merges
- reaper-flow gaps 5-10 (sends/buses, render parity, actions, MIDI editor flow, mixer parity, templates), #161 modulators/routing, testing-suite and sample-pack screens, mixer label shows instrument name, #133 leftovers, then #160/#159 (.caw removal, .caw project extension).
- Then build an APK (Run workflow on this branch) and send it to the owner.

## Owner's calls pending
- Confirm MIDI storage (pattern text + SMF exchange); Android signing secrets.

## Read first
- `docs/decisions.md`, `docs/app.md`
