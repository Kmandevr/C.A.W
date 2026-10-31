---
title: UI design
summary: Arrangement-first composition and editing on phone and desktop: timeline, tracks, MIDI clips, mixer, editors, inspector, and performance budget.
updated: 2026-10-28
---

# UI design

The owner's goal (2026-10-28): a halfway DAW that is easy to understand and use on a phone and a PC. It should stay light on CPU and RAM, and leave out recording and other hard features for now. Everything here is a **[Proposal]** for v2 unless it is marked otherwise. It builds on the v1 app ([app](app.md)) and the v2 features ([architecture](architecture.md#variables-and-patterns-proposal)).

## Owner's choices (2026-10-28)

- **Phone orientation:** portrait and landscape matter equally, so every screen gets a proper layout for both.
- **Composition view:** a horizontal arrangement timeline with tracks and reusable MIDI clips. The old session grid is retired, not retained as an alternate view.
- **Look:** neon but calm. The colours stay, glow is used sparingly, and transitions are short and simple.
- **New files and startup** (owner, 2026-10-28):
  - **New modules:** a new sound, effect, pattern or library starts as an empty file. A faint hint (not part of the file) shows an example header and first line until you start typing. Templates stay one choice away in the same New menu.
  - **Startup:** on launch, a small screen offers to continue the last project, start a new blank project, or start from a template project (such as today's "First loop"). It replaces opening the last project directly and the first-run demo project.
  - With no header, an empty file is a byte-mode generator. That is how the language already works ([engine](engine.md#module-files-caw)).
- **Look details** (owner, 2026-10-28):
  - **Calm neon** stays: near-black, thin neon lines, and glow only on what's active (playhead, selected notes, meters).
  - **Themes:** custom themes, with an in-app theme editor and live preview. It saves a readable theme file you can export, share or let an agent edit. Calm neon is the default, with a couple of starter themes.
  - **Fonts:** the system font for the UI, plus one bundled monospace font for code and numbers, so they look the same on phone and PC. The proposal is JetBrains Mono:
    - **[Fact]** licence: SIL Open Font License 1.1; the licence file and copyright must ship with the font. Seen in mirrors of its licence ([JetBrains Mono licence](https://maxibestof.one/fonts/coding/jetbrains-mono-LICENSE.txt)), 2026-10-28. Check the official repo before adding it and recording it in [decisions](decisions.md).
    - Size: about 550 KB for Regular and Bold ([decisions](decisions.md)).
  - **Density:** a setting to switch between comfortable (48 dp targets, the default on phones) and compact (more bars and layers on screen).
  - **Keyboard feedback:**
    - **Mode badge:** a small tag next to the BPM shows the Vim mode (NORMAL green, INSERT yellow, VISUAL pink), with a red dot while a macro records.
    - **Command line:** `:` opens a one-line bar only while you type a command. There is no permanent status line.
    - **Key hints:** after a prefix key, a small popup lists the keys that can follow.
    - **Toasts:** a brief label says what an action did ("Quantize 1/16").
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

## Arrangement workspace

The Arranger is the main composition view. It is a horizontal song timeline with one row per track, a bar ruler, reusable MIDI clips, and a separate mixer panel. It is not a session grid or clip launcher.

- A track owns its generator, effects, volume, pan, mute/solo and eventual routing. Clips reference pattern sources; they do not own instruments.
- A clip instance has a timeline start, visible length, source offset and loop setting. Moving a clip does not rewrite its source. Independent duplication clones the pattern source; linked duplication shares it.
- Drag the clip body to move it, Alt-drag to shift its source offset, drag its right edge to resize it, tap to select, Shift-tap to add clips to the selection, and double-tap to open the existing piano roll. Companion sources appear as faint, read-only references; clips sharing one pattern source remain linked and edit together.
- The track header keeps mute/solo and generator selection close to the timeline. The mixer panel edits the same track values, not a second copy of them.
- Folders nest, can collapse, and can be organization-only or enabled as stereo group buses. Children route through the nearest enabled ancestor bus; folder volume and pan act on the summed group.
- Volume and pan automation lanes are editable under a track. Points follow song time and are interpolated by the native engine. Clip automation and plugin/global parameter automation are not implemented yet.
- Empty timeline space creates a time selection; selected clips can be split at its end. Snap resolution is adjustable and Shift bypasses snapping. Audio clips remain deferred, but the clip model is kept type-extensible.

## Layout

The app keeps its three areas—Builder, Arranger and Exporter. The Arranger is the composition workspace; the old session grid is retired.

**Phone (portrait):** transport at the top, then the track headers beside a horizontally scrolling song timeline. The mixer opens as a panel below the timeline. Builder and Exporter remain separate bottom-navigation destinations.

**Phone (landscape):** the timeline gets the available width. Track headers stay aligned with their lanes while the song timeline scrolls horizontally. The mixer remains a separate panel.

**Desktop / wide:** navigation rail, persistent transport, and a full-width arrangement timeline. Track headers remain fixed beside the horizontally scrolling timeline; the Mixer panel can be opened without replacing the arrangement.

The track header is the quick-control surface (mute, solo, generator, folder and clip actions). The Mixer edits the same volume and pan values. Project settings and global controls stay behind the settings control to preserve timeline space.

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
  - The piano roll and the drum grid edit the same pattern files, which stay readable text. Selected arrangement clips can be shown as faint reference notes; notes in the active source retain ownership and remain the only directly editable notes unless the selected clips share a linked source.
  - **Scale:** rows in the project's key are highlighted. Notes can go anywhere, with no lock to the key.
  - **Velocity:** a lane under the roll.
  - **New notes:** a tap makes a note as long as the last one you sized; dragging while drawing sets the length directly.
  - **Extras** (probability, ratchet, slide): both a long-press panel (right-click or the Menu key on PC) and lanes you can switch on under the roll. Notes with extras show a dot.
  - **Saving:** the editor rewrites the pattern's text but keeps the header and comment lines; note lines are rewritten in time order, and a comment at the end of a note line stays with that note.
  - **Where:** selecting a pattern in Builder shows the roll or grid in place of the code, with the text one tap away, plus a button to go full screen.
  - **Adaptive grid:**
    - Zooming in adds finer grid lines between the existing ones, and zooming out removes them.
    - Ableton works the same way. It also has a fixed mode ([Live shortcuts](https://www.ableton.com/en/manual/live-keyboard-shortcuts)).
    - **Resolution:** you choose one, from 1 (a whole note) through 1/2, 1/4 and so on down to 1/128, or off. It's the finest the grid ever goes: with 1/8 chosen, zooming in stops adding lines at 1/8.
    - **Snapping:** moving notes and changing their length snap to the resolution. Holding Shift while dragging a length ignores the grid.
    - **Spacing:** tapping to place a note uses cells at least 48 dp wide, so on the phone a tap lands on the finest level that is still that wide. Dragging a length can use finer lines that are closer together, down to the chosen resolution. The owner confirmed this reading (2026-10-28).
    - **Fixed:** a switch fixes the grid at its current size, so zooming no longer changes it.
  - **Look:** notes glow in their layer's colour, and louder notes glow brighter. Selected notes get a white outline, and notes with extras get a dot.
  - **Keys on the roll** work the same on PC and with a keyboard on the phone. When no keyboard is connected, the phone shows its touch tools.
    - **W A S D** move the selected notes: A/D one grid step earlier or later, W/S one semitone up or down. The arrow keys do the same.
    - **Ctrl + W A S D** moves the cursor instead, like Reaper's or Ableton's: one grid step in time or one note in pitch. The note it lands on is selected. **[Assumption]** The owner also mentioned jumping to the next note in that direction; confirm which one they mean.
    - **Q** inserts a note at the cursor, with the last length used.
    - **E** copies the selected note or chord to start right where the selection ends, and selects the copy, so pressing E again keeps extending the line.
    - **Shift + A / D** shortens or lengthens the selected notes by one grid step.
    - **Shift + W / S** inverts a selected chord: W moves the lowest note up an octave above the highest, and S moves the highest note down an octave below the lowest. **[Proposal]** On a single note, Shift + W / S moves it an octave.
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
- **Customisable, like Reaper** (owner, 2026-10-28): every command is an action with keys you can change per area, plus macros and your own toolbars. The draft is in [actions](actions.md).
- **Vim-style** (owner, 2026-10-28): with a keyboard, the whole app works modally: modes, counts, `:` commands, `.` and recorded macros. The code editor has optional Vim editing. See [actions](actions.md#vim-style-control).

## Light on CPU and RAM

**Owner (2026-10-28):** C.A.W must run as light as possible, so it works on very low-end devices ("a potato"). Every feature is built with that limit.

- **[Assumption]** For testing, a "potato" means:
  - an Android 8 phone (the app's minimum, `minSdk` 26) with 2 GB of RAM and an old 4-core ARM CPU
  - an old dual-core Windows laptop
- **[Fact]** **Light mode** (owner OK and built, 2026-10-28): a setting that turns itself on at the first overload. It turns glow and scopes off, runs meters at 15 fps, plays 4 voices per pattern layer instead of 8, and pauses auto-update while playing, so swaps happen on Run only ([app](app.md)).
- **Editors:**
  - The piano roll and grid repaint only when something changes, plus the playhead's small region while playing.
  - The pattern model stays the source of truth while editing. It's turned into text only when saving or sending to the engine, not on every touch.
- **Keys:** a key press is a lookup in a per-area table. Search and completion run only while the action list or `:` is open.
- **Auto-update:** compiles off the UI thread after the pause you set. A change that doesn't compile costs nothing on the audio side.

- **The audio never depends on the UI.** The C++ engine runs on its own thread ([engine](engine.md)), so a slow frame can't cause a dropout.
- **Repaint only what moves:**
  - Meters, the playhead and scopes each sit in a small repaint region of their own, driven by one 30 fps ticker. The ticker runs only while playing and visible, and stops when the app is in the background.
  - **[Fact]** Fixed 2026-10-28: the meters are read only while playing, and the app does nothing periodic when stopped ([performance](performance.md)).
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

Recording audio or MIDI, audio clips, clip-following automation and automation of globals or module parameters remain out of scope for this slice ([roadmap](roadmap.md)).
