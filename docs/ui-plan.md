---
title: UI plan
summary: The owner's UI overhaul (2026-11-04), what the app looks like today, and the order of the work; nothing here is built yet.
updated: 2026-11-04
---

# UI plan

**Owner (2026-11-04):** Claude does the UI. The plan covers all of the following:
- the overall look and layout
- the ready app bugs (#19 tap tempo, #20 Android keyboard)
- the arranger (#40)
- the piano roll (#7, #9, #15, #21)
- touch quick actions (#23)

The owner said not to build yet. Everything below is a **[Proposal]** until the owner approves it. Current behaviour is in [app](app.md), and the design rules are in [UI design](ui.md).

## What the app looks like today

**[Fact, 2026-11-04]** These findings come from the Linux debug build run under Xvfb on the "First loop" template, at 390×844 (phone portrait) and 1280×800 (desktop).

1. **The quick-action strip covers content.** On every phone screen it floats over the bottom of the page: piano-roll rows, mixer cards and the Files list.
2. **The inline piano roll is about 200 px tall on a phone.** The track card, the pattern header and the pattern description take the space above it.
3. **The timeline hides sound that plays.** A layer with no clips plays its module all song long (`project.dart` sends its pattern directly), but its timeline row says "Add MIDI clip with +". In the template that is four of five tracks.
4. **The transport has only play, BPM and CPU.** It has no stop or position readout and no loop toggle. Undo and redo are missing too, although [UI design](ui.md) says they are always on screen.
5. **Track headers are cramped.** The M and S chips, the module name and the menu share about 180 px, so names are cut off. A clip's label ("MIDI · LOOP") is clipped at the default track height.
6. **The workspaces don't look like one app.** Each uses its own accent colour (Mixer pink, Exporter yellow, Files cyan, Builder green) and its own card and header style. Several show developer notes as body text: Plugin Builder's "Build boundary" paragraph, Exporter's reproducibility note, and the Builder's modulation panel with "Missing source" in the template.
7. **Phone navigation shows only one label.** The bottom bar labels only the selected destination. The Builder (`<>`) and Mixer icons are hard to tell apart.
8. **Desktop has spare room it doesn't use.** The arranger leaves the space below the tracks empty, and the ruler shows bars only.

Not checked yet: landscape phone, the code editor with an on-screen keyboard (#20, which needs a real device or an IME test), and the roll's full-screen mode.

## Order of work

Each step is one small PR to `Main`. It includes widget tests, a code-reviewer pass and release-check, and updates [app](app.md) and [UI design](ui.md). The engine is GPT's (#94, #28), so these steps don't touch `engine/`.

1. **U0, shared foundations.** Everything after this builds on it.
   - **Design tokens:** spacing, radii and a type scale, plus colour by role (action, selection, warning, meter) rather than by screen. They live in `theme.dart` and stay editable in the theme editor.
   - **Shared widgets:** section header, card, toolbar row, mute/solo buttons, and an info button that shows help text on demand instead of printing it in the page.
   - **Screen layout:** a phone scaffold that reserves room for the quick-action strip instead of overlapping, and navigation labels on every destination.
   - **Screenshot tests:** golden tests of each workspace at phone portrait, phone landscape and desktop, so later steps show what they changed.
2. **U1, transport and shell.**
   - Controls: play/stop, a bar.beat position, a loop toggle, and undo and redo always visible.
   - BPM: tap to type a value; long-press for tap tempo.
   - **#19:** one tap-tempo implementation. `AppState.tapTempo` and the `transport.tap` key already exist, but the arranger's settings sheet keeps its own `_taps` copy.
3. **U2, text input (#20).**
   - The fix: on-screen-keyboard Backspace, selection replacement and IME composing work in the code editor and in plain fields.
   - The tests: widget tests drive `TestTextInput`.
   - The owner confirms on the S22+.
4. **U3, arranger (#40 follow-ups).**
   - A layer with no clips shows a "plays all song" bar instead of "Add MIDI clip".
   - Readable track headers.
   - Clip labels that fit.
   - A beat-level ruler when zoomed in.
   - The add-track buttons still stop at 64. That is F7.3 part C, GPT's (#94).
5. **U4, piano roll (#7, #21, #15, #9).**
   - **Layout:** on a phone, opening a pattern gives the roll most of the height. The track card folds into one line, and full screen stays a button.
   - **#7:** a one-finger drag on empty grid scrolls.
   - **#21:** Copy and Paste buttons appear with a selection, and dragging any selected note moves the whole group.
   - **#15:** curve points snap to the grid, handles are unambiguous, and a curve never lengthens its note.
   - **#9:** check the existing size and look settings (row height, lanes, grid strength, key labels).
   - Several of these are partly built (the copy/paste toolbar icons, the time snapping in `note_expression.dart`, the settings). Each one is verified before new work.
6. **U5, touch quick actions (#23).** `touch_quick_actions.dart` and its editor exist. This step docks the strip into the U0 layout, checks per-area defaults, and checks that choices persist in `keys.txt` after a restart.
7. **U6, workspace polish.** Builder (controls first; modulation folded away until used), Mixer, Automation, Exporter, Files, Engine Lab and Plugin Builder move onto the U0 widgets. Each gets a checked layout for portrait, landscape and desktop.

## Open questions for the owner

- **Accent colours:** keep one accent colour per workspace, or use colour only for its role (with Calm neon's green as the main accent)?
- **Quick-action strip:** dock it above the bottom navigation, or merge it into the navigation bar?
- **Clip-less layers:** draw them as "plays all song" bars, or turn them into one whole-song clip when a project loads? No project compatibility is needed before Release 1 ([decisions](decisions.md)).
- **Font for goldens:** stable golden screenshots need a bundled font. JetBrains Mono is already proposed in [UI design](ui.md), but it is a new dependency, so it needs your approval.
