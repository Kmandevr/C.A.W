# Handoff

Commit: da5aa71

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
Agents, each in its own worktree; merge into this branch when done (run full engine + app tests after each):
- `.claude/worktrees/effects` (stock-effects): #173 engine effects + display API, then wire `app/lib/model/device_display.dart`.
- `.claude/worktrees/livebend` (live-bend-edit): sounding bent note follows edits during playback.
- `.claude/worktrees/bentnotes` (bent-notes): bent note drawn as a smoothed ribbon; note tool works on it.
- `.claude/worktrees/clipedit` (clip-editing): reaper-flow gaps 1-2 (clip bar, S split, multi-select, glue, loop range, markers, regions).
- `.claude/worktrees/recauto` (record-automate): reaper-flow gaps 3-4 (Touch automation writing, on-screen keys and pads, metronome, count-in, takes).
- Merged: feel pass, review fixes, flagship synth, REAPER arranger, curve tool, device editors, REAPER flow study (`docs/reaper-flow.md`).

## Next after merges
- Built-ins using the new kernels (a reverb effect first), #161 modulators/routing, testing-suite and sample-pack screens, mixer label shows instrument name, #133 leftovers, then #160/#159 (.caw removal, .caw project extension).
- Then build an APK (Run workflow on this branch) and send it to the owner.

## Owner's calls pending
- Confirm MIDI storage (pattern text + SMF exchange); Android signing secrets.

## Read first
- `docs/decisions.md`, `docs/app.md`
