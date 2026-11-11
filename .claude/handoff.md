# Handoff

Commit: e40d286

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
- Owner (2026-11-11): "make sure everything in the roadmap is done, including the routing and the hard stuff"; beta scope in decisions.md 2026-11-11 (audio clips, recording, sampler, per-note FX all IN). Audit with work packages WP-A..WP-O: scratchpad `roadmap_audit_v1.md` (summary: order A,H,I,K,L,M now; B then C; D (#160); E (#159), F (#161, reuse fx-racks modulator model), G (#127+#120 after drums merges module.hpp); J (audio clips/recording/sampler, after drums' sample API); N docs; O release).
- Running agents (worktrees under .claude/worktrees/): drums (engine first; then a UI agent), fx-creative, fx-filters, fx-space, fx-dynamics, fx-racks (racks + browser), adfix (audio-device review fixes), parity (WP-A), engine-leftovers (WP-L). API numbers: 10 = settings (merged), drums takes 11, leftovers next free; reconcile on merge.
- Closing done issues on GitHub was blocked by the auto-mode classifier: ask the owner to allow it or close them (#7 #21 #24 #36 #38 #40 #76 #123 #128 #137 #168 #170 #172 #175; superseded #32 #54). Draft comments in the audit §6.
- Owner choices to batch at the end: agents' "to confirm" items in decisions.md (Build start page, Try-it, sheets <600 dp, Files toggle, mod amount 25 %, bipolar, Flagship tabs, EQ double-tap, routing defaults, settings sections/defaults).

## Next
- Merge each agent as it reports (registries and API numbers conflict: keep all entries), audio-review engine merges, build an APK and send it with what's new.
- Then the next waves from the audit: WP-H MIDI devices, WP-I stems/render parity, WP-K screens; then WP-B/C/D (#160), WP-E (#159), WP-F (#161), WP-G (#127), WP-J (audio clips/recording/sampler); WP-N docs; WP-O release.

## Owner's calls pending
- Confirm MIDI storage (pattern text + SMF exchange); Android developer verification (2027, see vision.md).

## Read first
- `docs/decisions.md`, `docs/app.md`
