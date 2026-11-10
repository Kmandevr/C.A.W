# Handoff

Commit: 6f69fdc

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
Agents, each in its own worktree; merge into this branch when done:
- `.claude/worktrees/feel` (feel-pass): #168 feel pass + #170 piano roll + MIDI follow-ups + REAPER volume fader, double-tap reset, stepped-knob drag fix. Brief in the session scratchpad.
- `.claude/worktrees/fixes` (review-fixes): audio review findings 1-6 (block-size sleep, ping-pong level, Play CPU spike, note memory, replace-note motion, CLAP offs).
- `.claude/worktrees/flagship` (flagship-synth): #171 flagship synth, engine side (`org.caw.synth.flagship`).
- Merged already: Builder (#169), engine speed-up, ping-pong bounce fix, one audio output per process.

## Next after merges
- Built-ins using the new kernels (a reverb effect first), #161 modulators/routing, testing-suite and sample-pack screens, mixer label shows instrument name, #133 leftovers, then #160/#159 (.caw removal, .caw project extension).
- Then build an APK (Run workflow on this branch) and send it to the owner.

## Owner's calls pending
- Confirm MIDI storage (pattern text + SMF exchange); Android signing secrets.

## Read first
- `docs/decisions.md`, `docs/app.md`
