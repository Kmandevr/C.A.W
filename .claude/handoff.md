# Handoff

Commit: a5bda39

Branch: claude/caw-engine-foundation-skpirb (on Main a5bda39; U1 PR1, the docking layout model, in review)

## Goal
Owner (2026-11-04): Claude does the UI. The arrangement is home and DAW-like: docking panels (the phone too), a Unity-like code workspace, a Reaper-like mixer, a docked piano roll, and smooth, distance-aware motion. The whole spec, the open questions and the order of work (U0–U8) are in `docs/ui-plan.md`, and the owner's choices are in `docs/decisions.md`.
- Each step is one small PR to `Main` with widget and golden tests, a code-reviewer pass and release-check. Claude merges when CI is green.
- Claude makes the small engine changes the UI needs, such as a note on/off C API for previews. The large ones wait for GPT: several instruments per track, parent tracks with their own sound, and Bezier curves.
- GPT owns the rest of the engine (#94, F7.3 part C, F7.4, F8, F10; #28).

## Done and verified
- The UI plan and specs are on Main: #96 and #97.
- U0 is merged (#98): part two adds `app/lib/ui/tokens.dart`, eight track colours and `app/lib/ui/kit.dart` (the context toolbar, tool and info buttons). Part one:
  - `app/lib/ui/motion.dart`
  - the Motion, Haptics and Glow settings, with saves run one after another
  - golden tests with real fonts (`app/test/golden_util.dart`)
  - Checks: `flutter analyze` is clean, and `flutter test` gives 191 passed, 19 skipped (without `CAW_LIB`).

## Next
U1 has five PRs (architect review, 2026-11-04; detail in `docs/ui-plan.md`, U1):
1. The layout model: in review.
2. `lib/ui/dock/dock_view.dart`, not wired in.
3. The shell switch: `DockController.reveal`, the focused panel's key area, hidden tabs under `TickerMode` that skip the tick, `dock_layouts` as raw JSON in Settings, and the panel's size used instead of the screen's.
4. Open straight into the arrangement.
5. The transport bar: undo/redo and tap tempo (#19).

## Open (owner)
- How several instruments on one track combine: is "each adds to the audio above it" the rule?
- The code-editor component for multi-cursor and folding: custom, or a package (which needs approval)?

## Read first
- `docs/ui-plan.md`
- `docs/ui.md`
- `docs/app.md`
- `app/lib/ui/theme.dart`
- `app/lib/ui/motion.dart`
