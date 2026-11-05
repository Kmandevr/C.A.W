# Handoff

Commit: 90331d9

Branch: claude/caw-engine-foundation-skpirb (on Main 90331d9; Mixer strips, U6 part 1, PR open)

## Goal
Owner (2026-11-04): Claude does the UI from `docs/ui-plan.md`, in small PRs to `Main`. Claude merges each once CI is green.
- Claude makes the small engine changes the UI needs (the note preview C API is built, #103). The large ones wait for GPT: several instruments per track, parent tracks with their own sound, and Bezier curves.
- GPT owns the rest of the engine (#94, F7.3 part C, F7.4, F8, F10; #28).

## Done and verified
- U0, U1 PRs 1–3 (#98–#101), piano roll parts 1 and 2 (#102, #104: stretch, bypass, auto-scroll, ghost, snap magnet).
- Note previews (#103):
  - Engine: `caw_engine_note_on` and the pitch/off calls in `engine/include/caw.h`, stopped preview chunks, `endPlayback`, `restartChain`.
  - App: `previewOn` in `app/lib/model/app_state.dart`, and the "hearing notes" section in `app/lib/ui/pattern_editor.dart`.
  - Tests: `app/test/roll_preview_test.dart`, plus the engine preview tests.

  - Merged in #105.
- Accurate meters and the phone arrangement (#106): dB `PeakMeter`, track and folder peaks after pan, a one-row phone toolbar, compact track headers.
- Phone cleanup of the panels (#107): no repeated titles or developer notes, held dB readouts (`PeakReadout`), compact Automation, a one-row Code track card.
- Mixer strips, U6 part 1 (this branch): upright Reaper-style strips with chain slots, typed level and pan, `PeakMeter(vertical:)`.

## Next
- Merge the Mixer strips PR when CI is green.
- U6 part 2: typed module parameter values in the inspector (owner: "then work on the rest of the UI").
- Piano roll still to build: bend handles with detents, freehand curves, the context toolbar middle, scale highlight, snap to scale, ghost notes.
- Arrangement automation-lane snapping (U3).
- U1 PR4 (open straight into the arrangement) and PR5 (transport undo/redo, tap tempo #19).

## Open (owner)
- Should chance stay at 5% steps, or follow the value grid? It follows the value grid now.
- Holding a note opens its extras sheet, which ends its preview. Should the extras open on the lift instead?
- How several instruments on one track combine.
- The code-editor component: custom, or a package?

## Read first
- `docs/ui-plan.md`
- `docs/app.md`
- `app/lib/ui/pattern_editor.dart`
