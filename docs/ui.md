---
title: UI design
summary: How the app should look and feel as a light "halfway DAW" on phone and desktop: layout, one gesture vocabulary, the session grid, editors, inspector, and the performance budget.
updated: 2026-10-28
---

# UI design

The owner's goal (2026-10-28): a halfway DAW that is easy to understand and use on a phone and a PC. It should stay light on CPU and RAM, and leave out recording and other hard features for now. Everything here is a **[Proposal]** for v2 unless it is marked otherwise. It builds on the v1 app ([app](app.md)) and the v2 features ([architecture](architecture.md#variables-and-patterns-proposal)).

## Owner's choices (2026-10-28)

- **Phone orientation:** portrait and landscape matter equally, so every screen gets a proper layout for both.
- **Mix view:** the session grid (layers × scenes).
- **Look:** neon but calm. The colours stay, glow is used sparingly, and transitions are short and simple.
- **Audience:** built for the owner first. It should be fast for someone who knows it, with tooltips and tips but no onboarding tour yet.
- **PC:** mouse and keyboard, and **everything must also be reachable with the keyboard alone**. Shortcuts follow Reaper's where they overlap.
- **Library:** folders (matching the library repo) plus tags and search across them, with favourites pinned.
- **Opening a sound** shows its controls (the inspector) first. The code editor is one tap away.

## What other apps teach

- **Stay in flow.**
  - Koala Sampler's stated goal is keeping you making music instead of "getting bogged down by pages of parameters and micro-editing" ([App Store](https://apple.co/2NwcL8m)). Reviewers call it simple and SP-404-like ([DJTechTools](https://djtechtools.com/2023/02/07/meet-the-koala-sampler-app-a-mobile-production-powerhouse-now-with-stems)).
  - Teenage Engineering's EP-133 is praised for speed. Its main move, Commit, copies the current scene and moves you into the copy, so trying a variation is one action ([Sound On Sound](https://www.soundonsound.com/reviews/teenage-engineering-ep-133-ko-ii?amp)).
- **Fingers need big targets and no hidden clicks.**
  - Google's Android guidance is at least 48dp touch targets (about 9 mm), spaced 8dp apart ([Android accessibility](https://support.google.com/accessibility/android/answer/7101858)).
  - Clip launchers built for a mouse are too small for fingers. Bitwig sizes buttons for a fingertip and puts options on tap-and-hold ([Ardour forum](https://discourse.ardour.org/t/adapt-clip-launcher-cue-view-so-it-is-better-adapted-for-touch-screens/108603)).
  - Griid Pro triggers scenes only from one edge of a button, so scrolling never launches one by accident ([Crossfadr](https://crossfadr.com/2011/06/29/review-griid-pro/)).
- **Piano rolls are the hardest part on a phone.**
  - Fingers aren't as accurate as a mouse, and touch has no right-click. Apps need bigger notes and a tool bar instead of modifier keys. Users liked hearing a chord when they move a note, and selecting several notes at once ([Loopy Pro forum](https://forum.loopypro.com/discussion/comment/359423/)).
  - Research on mobile piano rolls points the same way ([ISMIR 2022](https://archives.ismir.net/ismir2022/latebreaking/000034.pdf)).
- **Per-step values without menus.** Elektron's parameter locks let any step carry its own sound settings. Steps that carry them blink, so you can see where they are ([Elektron quick start](https://www.elektron.se/wp-content/uploads/2024/09/Know-How-Mono-Quick-Start.pdf), [Elektronauts](https://www.elektronauts.com/t/see-what-trigs-are-parameter-locked/231976)). Our per-note custom values work the same way.
- **Curves drawn on the note.**
  - Bitwig draws micro-pitch on the note itself. Its curves are edited by adding points, moving them and bending the segments between them ([Bitwig user guide](https://www.bitwig.com/userguide/latest/inspecting_note_clips), [Admiral Bumblebee](https://www.admiralbumblebee.com/music/2017/06/16/bitwig-feature-review-note-expression)).
  - Bitwig Studio 6 edits gain and the other expressions on the notes too ([Plugin Boutique](https://www.pluginboutique.com/products/16950-Bitwig-Studio-6)). This is the model for curved notes here.

## Layout

The same pieces fit both screens. On a phone they stack and slide in; on a wide screen they sit side by side.

**Phone (portrait):**

```
┌──────────────────────────────┐
│ ▶  140 BPM  Scene B ▾   ↶ ↷  │  transport + undo/redo, always visible
├──────────────────────────────┤
│                              │
│   main view (one at a time)  │  session grid · pattern editor · sound editor
│                              │
├──────────────────────────────┤
│ ▔▔ inspector sheet (drag ↑) ▔│  controls for what's selected; peek / half / full
├──────────────────────────────┤
│  Mix   Patterns   Sounds  Export │  bottom tabs, in the thumb's reach
└──────────────────────────────┘
```

**Phone (landscape):** two-handed, like a groovebox. The tabs move to a narrow side rail. The main view gets the full width, which suits the grid and the piano roll. The inspector opens as a side panel instead of a bottom sheet.

**Desktop / wide (≥ 900 px):**

```
┌────────┬───────────────────────────────┬─────────────┐
│Library │  session grid (layers × scenes)│  Inspector  │
│sounds  │                               │  (params,   │
│patterns│                               │   globals)  │
│        ├───────────────────────────────┤             │
│ drag → │  editor drawer: pattern / code │             │
└────────┴───────────────────────────────┴─────────────┘
```

- **Mix** is the session grid. Rows are layers and columns are scenes. Each cell holds the pattern that layer plays in that scene.
  - Tapping a cell's big area plays it. A scene is launched from the narrow strip on its left edge only (the Griid lesson).
  - Launches are queued to the next loop boundary, so they're always in time.
  - "Commit" copies the current scene into a new one to try a variation (the EP-133 lesson).
- **Library:** sounds and patterns are cards you drag onto a layer or a grid cell. They're organised in folders, matching the library repo's layout, with tags and a search box across all folders and favourites pinned at the top.
  - On a phone the library is a tray that slides up from the bottom. Long-press a card to pick it up.
  - On desktop the library is a side column, and `.mid` or `.caw` files can be dropped onto the window.
- **Inspector:** the Unity-style panel for whatever is selected: a module's params, a layer's mix or a note's extras.
  - Headers fold. Tooltips show on long-press on a phone and on hover on desktop.
  - On a phone it's a bottom sheet: peek shows 3–4 controls, half shows a section, full shows everything.
- **Progressive disclosure:**
  - At most two levels deep.
  - Advanced settings sit in a folded "More" section.
  - Defaults should already sound good, as v1's templates do.

## One gesture vocabulary

The same meaning everywhere, so nothing has to be learned twice:

| Gesture (touch) | Desktop | Meaning |
| --- | --- | --- |
| Tap | Click | Select, or toggle a step or cell |
| Long-press | Right-click | Options menu, or pick up to drag |
| Drag | Drag | Move a note or card, or change a value |
| Double-tap | Double-click | Reset a value to its default; open an item |
| Two-finger pinch / pan | Wheel, Ctrl+wheel | Zoom and scroll a grid or roll |
| Swipe up on the sheet | — | Show more of the inspector |

- **Value controls:** a phone uses full-width sliders, never small knobs.
  - Dragging further away from the slider (up or down) gives finer control, like scrubbing a video.
  - Double-tap resets the value.
  - The value is always shown as a number, and tapping the number lets you type one.
- **Undo and redo** are always on screen. On touch they're the safety net that makes experimenting feel safe.

## Editors

- **Owner's answers (2026-10-28), not built yet; the owner has more input before building starts:**
  - The piano roll comes next, inside today's app (before the session-grid redesign), together with the drum grid.
  - The piano roll and the drum grid edit the same pattern files, which stay readable text.
  - **Scale:** rows in the project's key are highlighted. Notes can go anywhere, with no lock to the key.
  - **Velocity:** a lane under the roll.
  - **New notes:** a tap makes a note as long as the last one you sized; dragging while drawing sets the length directly.
  - **Extras** (probability, ratchet, slide): both a long-press panel (right-click or the Menu key on PC) and lanes you can switch on under the roll. Notes with extras show a dot.
  - **Saving:** the editor rewrites the pattern's text but keeps the header and comment lines; note lines are rewritten in time order, and a comment at the end of a note line stays with that note.
  - **Where:** selecting a pattern in Builder shows the roll or grid in place of the code, with the text one tap away, plus a button to go full screen.
- **Drum grid:**
  - cells at least 48 dp, scrolling one bar at a time, with a velocity lane under the steps
  - notes with extras (probability, ratchets, custom values) show a small dot, like Elektron's blinking locked steps
- **Piano roll:**
  - **Modes:** a thumb tool bar switches between Draw, Select, Curve and Erase. That replaces the modifier keys a phone doesn't have.
  - **Zoom:** two fingers zoom and scroll. One finger always edits, so editing and navigating never clash.
  - **Feedback:** moving a note plays it, and moving a chord plays the chord.
  - **Snap:** follows the grid setting, with a magnet toggle for free timing.
  - **Curve mode:** draw on a note freehand, and it smooths into points and handles. Pitch bends show as a bent note. Other value curves are lines in a lane under the roll.
- **Sound editor:** opens on the inspector (sliders, toggles, tips). The code editor from v1's Builder is a tab or drawer one tap away, for changing the sound itself.

## Keyboard (PC)

- **Everything without a mouse:**
  - Tab and arrow keys move focus between panels and inside grids, with a visible neon focus ring.
  - Enter opens or plays. The Menu key or Shift+F10 opens the same options as a long-press.
  - Every control can be adjusted from the keyboard: arrows for steps, Shift+arrows for fine steps, typing a number to set it.
- **Shortcuts like Reaper's where they overlap:** Space for play/stop, Ctrl+Z for undo, and Ctrl+S for save. **[Assumption]** Reaper's default keymap must be checked against its current action list before the shortcuts are fixed.
- **Shortcut overlay:** `?` shows every shortcut for the current screen.

## Light on CPU and RAM

- **The audio never depends on the UI.** The C++ engine runs on its own thread ([engine](engine.md)), so a slow frame can't cause a dropout.
- **Repaint only what moves:**
  - Meters, the playhead and scopes each sit in a small repaint region of their own, driven by one 30 fps ticker. The ticker runs only while playing and visible, and stops when the app is in the background.
  - **[Fact]** In v1 the meter ticker runs even while stopped; v2 should fix that.
  - Community advice warns that a repaint boundary around something that changes every frame only adds cost, so measure ([blog](https://omr.it.com/blog/flutter-engine-raster-cache-tuning/)).
- **Draw grids, not widgets:** the session grid, drum grid and piano roll are each one painter that draws only the visible area, not one widget per cell. Lists are built lazily.
- **No heavy assets:**
  - system fonts and no images; icons come from the built-in icon font
  - animations limited to short state changes, with glow used sparingly (the owner's "neon, calm")
- **Compact data:** patterns are flat arrays of note events in the engine. A layer's memory is fixed when it is set up, never while playing.
- **Budgets (targets to measure, not facts yet):**
  - near 0% CPU from the UI when stopped
  - RAM under 150 MB on the S22+ with a 16-layer project
  - an APK under 30 MB (v1's artifact zip is about 25 MB)
- **Measure with:** Flutter DevTools, and Perfetto on Android.

## Not yet

Recording audio or MIDI, audio clips and a timeline arranger stay out until the owner says otherwise ([roadmap](roadmap.md)).
