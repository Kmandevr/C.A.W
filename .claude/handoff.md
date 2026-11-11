# Handoff

Commit: 4cfc5a3

Branch: ccr-56285e11-0xrj3h (PR #167 open, subscribed, CI green at aa1ee28)

## Goal
Owner (2026-11-11, latest): "Don't stop until everything in the roadmap is completely done. I want you continuously working. Restart when your limit goes out." After the roadmap: optimize everything (fast, quick, runs extremely well), then a user-friendliness pass that does NOT change the layout or things in the app, only makes everything fit well in the UI. Wake-up scheduled 2026-11-11T17:31Z (owner's 10:31 pm).
Owner (2026-11-10): work through everything discussed toward the open beta, without the owner's input except where a call is genuinely theirs; don't message them unless something is on fire.

## Done and verified (on this branch, pushed)
- Bend-in-clips fix; decisions (polyphony, landscape, inefficient plug-ins).
- Logo C5 (owner-approved) in app, Android adaptive icon, Windows icon, SVGs in `app/assets/logo/`. Logo changes need the owner's explicit yes.
- GitHub Releases in `.github/workflows/app.yml` (tag v* or Run workflow + release); APK native libs compressed. No release made yet.
- Library kernels: lfo/wavetable/reverb/smoothing headers + tests (not yet used by any built-in).
- MIDI file import/export in Dart (`app/lib/model/midi_file.dart`, `app/lib/model/midi_clips.dart`, `app/lib/ui/midi_file_actions.dart`).

## Open
- Merged and pushed on the session branch (4cfc5a3, API 17): settings, routing/ducker + fixes, #133, all four FX groups + racks/browser, drums engine + editor, parity ports + C++ starters, engine leftovers (meters, VST3), MIDI devices (API 15), build tools, piano roll (K2), arrange/mixer (K1), stems/export sheet (API 16), engine off .caw (WP-B, API 17).
- Running (worktrees): off-caw-app (WP-C), audio-engine (WP-J engine, API 18), modulators (WP-F #161, API 19); architect designing #127 (WP-G) into architecture.md.
- Next: WP-D delete the .caw language (after WP-C; pattern templates acid-line/chords need a Dart home first), WP-E (#159 .caw project extension), WP-G build from the architect's plan, WP-J app UI after the engine, then the optimization pass, the fit-and-finish pass (no layout changes), WP-N docs, version bump, release.
- Known flaky timing tests to fix in the cleanup pass: double-tap in pattern_editor and files, the cpp_builder live-check debounce. Fixed so far: tap tempo (fake clock), export queue wait.
- Closing done issues on GitHub was blocked by auto mode: ask the owner (#7 #21 #24 #36 #38 #40 #76 #123 #128 #137 #168 #170 #172 #175; superseded #32 #54).
- Owner choices to batch: every "to confirm" entry in decisions.md (2026-11-10/11), the Engine Lab placement, and the new screens' looks.

## Next
- Merge each agent as it reports (registries and API numbers conflict: keep all entries), audio-review engine merges, build an APK and send it with what's new.
- Then the next waves from the audit: WP-H MIDI devices, WP-I stems/render parity, WP-K screens; then WP-B/C/D (#160), WP-E (#159), WP-F (#161), WP-G (#127), WP-J (audio clips/recording/sampler); WP-N docs; WP-O release.

## Owner's calls pending
- Confirm MIDI storage (pattern text + SMF exchange); Android developer verification (2027, see vision.md).

## Read first
- `docs/decisions.md`, `docs/app.md`
