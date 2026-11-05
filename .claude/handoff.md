# Handoff

Commit: fdd8d2e (plus review fixes in the next commit)

Branch: claude/caw-engine-foundation-skpirb (on Main 0af9f06; note previews #103 in progress, PR next)

## Goal
Owner (2026-11-04): Claude does the UI from `docs/ui-plan.md`, in small PRs to `Main`. Claude merges each once CI is green.
- Claude makes the small engine changes the UI needs (the note preview C API is built, #103). The large ones wait for GPT: several instruments per track, parent tracks with their own sound, and Bezier curves.
- GPT owns the rest of the engine (#94, F7.3 part C, F7.4, F8, F10; #28).

## Done and verified
- U0 and U1 PRs 1–3 are merged (#98–#101).
- Piano roll part 1 (#102): stretch both ends, end zones, second-finger bypass, auto-scroll, ghost note, and the arrangement grid at full height.
- Piano roll part 2 (#104): one snap magnet with a time and value grid.
- Note previews (#103):
  - Engine: `caw_engine_note_on` and the pitch/off calls in `engine/include/caw.h`, stopped preview chunks, `endPlayback`, `restartChain`.
  - App: `previewOn` in `app/lib/model/app_state.dart`, and the "hearing notes" section in `app/lib/ui/pattern_editor.dart`.
  - Tests: `app/test/roll_preview_test.dart`, plus the engine preview tests.

## Next
- Open the #103 PR, then merge it when CI is green.
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
