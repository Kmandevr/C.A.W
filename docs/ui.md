---
title: UI design
summary: Arrangement-first creative UI across eight shared-state workspaces, with touch-first phone layouts and keyboard/mouse desktop access.
updated: 2026-11-10
covers: [app/lib/ui/, app/lib/actions/]
---

# UI design

The owner's goal (2026-10-28) is a capable, lightweight music-production workspace that is easy to understand and use on a phone and a PC. The original early UI slice left recording and other hard features for later; the permanent [roadmap](roadmap.md) now includes recording and the wider production workflow as later stages. This document describes current UI behavior and interaction design, not a separate feature roadmap. The app reference ([app](app.md)) is authoritative for shipped behavior.

## Owner's choices (2026-10-28)

- **Phone orientation:** portrait and landscape matter equally, so every screen gets a proper layout for both.
- **Composition view:** a horizontal arrangement timeline with tracks and reusable MIDI clips. The old session grid is retired, not retained as an alternate view.
- **Look:** neon but calm. The colours stay, glow is used sparingly, and transitions are short and simple.
- **New files and startup** (owner, 2026-10-28):
  - **New modules:** a new sound, effect, pattern or library starts as an empty file. A faint hint (not part of the file) shows an example header and first line until you start typing. Templates stay one choice away in the same New menu.
  - **Startup (owner, 2026-11-04, replacing the 2026-10-28 startup screen):** the app opens straight into the last project, or the "First loop" template on a first run. New, New from template and Open are in the project menu ([UI plan](ui-plan.md)).
  - With no header, an empty file is a byte-mode generator. That is how the language already works ([engine](engine.md#module-files-caw)).
- **Look details** (owner, 2026-10-28):
  - **Calm neon** stays: near-black, thin neon lines, and glow only on what's active (playhead, selected notes, meters).
  - **No repeated titles or developer notes (owner, 2026-11-05):** a panel doesn't repeat its tab name as a heading, and notes about how the engine works stay out of the screens. Accent colours and card styles are not yet unified.
  - **Themes:** custom themes, with an in-app theme editor and live preview. It saves a readable theme file you can export, share or let an agent edit. Calm neon is the default, with a couple of starter themes.
  - **Fonts:** the system font for the UI, plus the bundled JetBrains Mono 2.304 (SIL OFL 1.1, about 550 KB, licence shown in the app) for code and numbers, so they look the same on phone and PC ([app](app.md)).
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
  - Clip launchers built for a mouse are too small for fingers. Apps need touch-sized controls and options on tap-and-hold.
- **Piano rolls are the hardest part on a phone.**
  - Fingers aren't as accurate as a mouse, and touch has no right-click. Apps need bigger notes and a tool bar instead of modifier keys. Users liked hearing a chord when they move a note, and selecting several notes at once ([Loopy Pro forum](https://forum.loopypro.com/discussion/comment/359423/)).
  - Research on mobile piano rolls points the same way ([ISMIR 2022](https://archives.ismir.net/ismir2022/latebreaking/000034.pdf)).
- **Per-step values without menus.** Elektron's parameter locks let any step carry its own sound settings. Steps that carry them blink, so you can see where they are ([Elektron quick start](https://www.elektron.se/wp-content/uploads/2024/09/Know-How-Mono-Quick-Start.pdf), [Elektronauts](https://www.elektronauts.com/t/see-what-trigs-are-parameter-locked/231976)).
- **Curves drawn on the note** (any number of points; F7.1, 2026-11-04).
  - Bitwig draws micro-pitch on the note itself. Its curves are edited by adding points, moving them and bending the segments between them ([Bitwig user guide](https://www.bitwig.com/userguide/latest/inspecting_note_clips), [Admiral Bumblebee](https://www.admiralbumblebee.com/music/2017/06/16/bitwig-feature-review-note-expression)).

## REAPER reference (the arranger copies it)

The owner asked for the arranger to work like REAPER's (#172, [decisions](decisions.md)). **[Fact]** unless marked, from *Up and Running: A REAPER User Guide* v7.85, November 2026 ([PDF](https://www.reaper.fm/userguide/ReaperUserGuide785c.pdf); "UG" below, with section and page) and the [REAPER Quick Start](https://www.reaper.fm/guides/REAPER%20Quick%20Start.pdf) ("QS"), both checked 2026-11-10. These are REAPER's defaults; its mouse modifiers can be reassigned (UG 7.35, p. 149).

- **Moving items:** select and drag; Shift-drag ignores snap (UG 7.2, p. 124). A plain drag has no axis lock; a modifier can be assigned to move only horizontally or only vertically (UG 7.5, p. 132).
- **Copying items:** Ctrl-drag copies; Shift+Ctrl-drag copies ignoring snap (UG 7.2, p. 125; the "Media item, left drag" defaults, UG 7.5, p. 132). Shift+Ctrl+Alt-drag copies "pooling MIDI source data", so a plain Ctrl copy has its own notes (UG 7.2, p. 125).
- **Below the last track:** a razor selection dragged (move) or Ctrl-dragged (copy) to below the last track goes to a new track (UG 7.2, p. 125). Preferences › Editing Behavior has "automatically delete empty tracks created when dragging items below last track" (UG 22.8, p. 442), so dragging items there creates tracks. Double-clicking the track panel below the last track inserts a track at the end (UG 3.4, p. 59; QS).
- **Effects:** drag FX from the FX browser onto a track (track panel or mixer) or an item to add it; drag FX "to empty area of track panel" to create a new track with that FX; double-click an FX in the browser adds it (UG 2.10, p. 39; 6.1, p. 111). Each FX in the chain has a bypass check box; an FX is replaced by Alt-dragging the new one onto it, or with Ctrl+R in the chain (UG 2.12, p. 41).
- **Instruments are FX:** a VSTi goes in the track's FX chain, "usually the first item in the chain" (UG 2.8, p. 38). The FX browser lists instruments in its own folder too (UG 6.3, p. 113). Insert › Virtual instrument on new track creates a named track with the instrument, or "drag and drop the instrument from an open FX Browser window to an empty area of the track control panel" (UG 3.33, p. 73; 17.18, p. 357).
- **Media and MIDI files:** files are dragged in from the Media Explorer or the system's file browser (UG 4.10, p. 90). With "Allow drag import to insert tracks", a file dropped near the top of an item shows an "Insert track" tooltip and goes on a new track above it (UG 4.7, p. 88). **[Assumption]** a file dropped below the last track goes on a new track; the guide doesn't say so for files.
- **Folders:** a folder track is a track and can hold items itself (UG 5.13.4, p. 101: items move between a folder and its hidden child tracks).
- **Tracks are dragged:** drag a track panel up or down the list and release it inside the destination panel; its items go with it (UG 5.1, p. 93). Released in the folder drop zone, "roughly the vertical middle of the track panel", the tracks go into that track as a folder; the cursor shows a folder there and a hand elsewhere (UG 5.13.1, pp. 100–101).
- **Item edges:** dragging an item's edge moves that edge (trims it); Alt-drag stretches the item (UG 7.5, p. 132).
- **Split:** S splits the selected items at the edit cursor, or every item when none is selected (UG 7.2, p. 124); its action is "Split item at edit or play cursor" (UG 8.11, p. 167). "Allow trim of MIDI items when splitting" adds a note-off for any note spanning the split point (UG 22.9.1, p. 447), and "a new MIDI pool item is never created when an existing MIDI item is split" (UG 13.35, p. 270).
- **Selecting several items:** Ctrl+click adds items, Shift+click selects a range of adjacent items (UG 7.2.1, p. 124); a right-drag in the arrange view draws a marquee, Shift+right-drag adds to the selection, and touching an item with the marquee includes it (UG 7.5, p. 132; 7.2.2, p. 124). A drag of selected items moves them together (UG 7.2.2, p. 124).
- **Glue:** Glue items joins the selected items in a track into a new item without harming the originals; glued MIDI items open together in one MIDI editor (UG 7.33, p. 147).
- **Creating items:** Ctrl+drag in an empty area of the arrange view creates an empty item (UG 7.35, p. 149); in pencil mode, Ctrl+drag draws a copy of the selected item, snapped (UG 7.17, p. 138). A plain drag there makes a time selection (UG 7.35, p. 149).
- **Snapping:** Alt+S toggles snap; snap settings decide whether items snap to the grid, other items, markers or the cursor, within a snap distance in pixels (UG 7.26, p. 141).
- **Clicks on an item:** a click selects it and moves the edit cursor; Shift adds to the selection, Ctrl toggles it (UG 7.5, p. 132; 7.35, p. 149). A double-click opens the item's properties (UG 7.5, p. 132); on a MIDI item it opens the MIDI editor (UG 13.5, p. 242). Shift+double-click sets the time selection to the item, Ctrl+double-click the loop (UG 2.17, p. 46).
- **The rest of REAPER's flow** (templates, recording, takes, editing, the MIDI editor, routing, automation, the mixer, markers, actions, render, freeze) is in [REAPER's flow and C.A.W's](reaper-flow.md), with the gaps and a build plan.
- **[Assumption]** what the edit cursor does while an item is dragged, and how REAPER scrolls while dragging at the view's edge, are not described in the guide.

## Arrangement workspace

The Arranger is the main composition view. It is a horizontal song timeline (any length, since F7.2) with one row per track, a bar ruler, reusable MIDI clips, and a separate mixer panel. It is not a session grid or clip launcher.

- A track owns its instrument (a .caw generator or a C++ instrument), effects, volume, pan, mute/solo and eventual routing. Clips reference pattern sources; they do not own instruments.
- **Song end (owner, 2026-11-09: no length cap, loop back like Reaper):** the song ends at its last clip or automation point, rounded up to whole bars, and playback loops back to the start there; a pink line marks it. **Loop range (owner, 2026-11-10):** a drag along the ruler draws a loop range with a handle at each end, as in REAPER; while the loop button (⟳, R) has it on, playback loops over it instead. A long press on the ruler adds a named, coloured marker or region; a tap jumps to one, a drag moves it ([app](app.md), Loop range, markers and regions). The timeline always reaches 64 bars past the end, so a clip can go anywhere and the song grows with it. Project settings' **Length** (− / + or a typed number of bars, no fixed list) is only the shortest the song can be, for a project with few or no clips. The export and the seconds readout use the song end.
- A clip instance has a timeline start, visible length, source offset and loop setting. Moving a clip does not rewrite its source. Independent duplication clones the pattern source; linked duplication shares it.
- **Direct manipulation first (owner, 2026-11-10: "feel like a blueprint and not just like a list", #172).** Everything is grabbed and dropped where it sits, as in REAPER (reference above); long-press menus stay as the secondary path. Drag a clip to move it in time and to another track (a ghost and the lit target lane show where; Ctrl-drag, or a second finger on a phone, copies; Escape cancels; the view scrolls at its edges), Alt-drag to shift its source offset, drag either edge to trim it, tap to select, Ctrl-click to add or remove a clip, Shift-click for a range, right-drag in empty space for a marquee (Select mode on a phone: taps add, a long-press drag draws the box), drag one of several selected clips to move them all, and double-tap to open the existing piano roll. Split (S), Glue, Duplicate, Delete and Properties sit in the clip bar while clips are selected: docked near the bottom on a phone, in the toolbar when wide ([app](app.md), Clip editing). Ctrl+drag in empty lane space (or a double-tap on a phone) draws a new empty clip. Drag a track header to reorder it, or into a folder's middle. Anything dropped on the empty area below the last track makes a new track with it ([app](app.md), Arranger). Companion sources appear as faint references by default. Explicit multi-edit mode mirrors note additions, deletions, moves, resizes and expression changes to selected independent pattern sources while keeping each source's note IDs local; linked clips still share one source.
- The track header keeps mute, solo and the FX button close to the timeline; the rest (record arm, folders, automation, and an Instrument… entry that opens the FX browser) is in its long-press menu. Instruments are added like effects, from the same browser or by drag and drop, and sit first in the FX chain (REAPER). Tapping a track opens the **focus view**: the track pinned on top with its FX / Mixer / Clip / Automation panel below (phone portrait) or beside it (landscape, desktop). The FX tab is a plain FX stack of cards, with a Routing toggle ([app](app.md), Arranger). The mixer panel and card edit the same track values, not a second copy of them.
- Folders nest, can collapse, and can be organization-only or enabled as stereo group buses. Children route through the nearest enabled ancestor bus; folder volume and pan act on the summed group.
- Volume and pan automation lanes remain editable under each track. A separate project automation panel adds song-time lanes for module parameters and named globals, with curve previews, point editing and automation undo/redo. The native engine interpolates these lanes per sample; clip-following automation remains unimplemented.
- Tapping empty timeline space sets the edit cursor, and while stopped moves where play starts and Split cuts (double-tapping draws a one-bar clip); long-press-drag creates a time selection without blocking horizontal scrolling. Snap resolution is adjustable and Shift bypasses snapping. Audio clips are planned for a later roadmap stage; they are not implemented in the current app.

## Layout

The app has three sections, Build, Files and Arrange; the Mixer, Automation, Export, Engine Lab and Plugin Builder are pages from More on a phone and docking panels on desktop ([app](app.md), Frame). Build holds the C++ Builder and the .caw module Builder as tabs, laid out like VS Code: the Files browser as an explorer (a drawer on a phone, a resizable sidebar when wide), one 36 dp row of open tabs with + New (Pattern, Instrument, Effect, Text file), and the editor in the rest. Arrange exposes adjustable track heights, the focus view, and a playhead overlay that repaints independently of clip layout. Mixer shows Reaper-style upright channel strips (chain slots, pan, fader, meter, M and S) in a row that scrolls sideways; a tapped slot's parameters open beside the strips on wide panels (with a draggable split) and in a sheet otherwise. Files is the Unity-style browser; its ⋯ menu imports and exports portable `.cawproj` and `.caw` files. Export saves a finished file where the user picks, copied in chunks. Plugin Builder still validates and packages the constrained `.caw` modules; it goes with the .caw language (#160). External CLAP/VST3 hosting is not built.

**Docking (desktop and tablets):** each screen shape keeps its own saved layout. The Arrange preset puts the arrangement in one group and the other panels as tabs in a second. Tap a tab to show it. Long-press a tab and drag it onto another group to join it or split it, drag a divider to resize, maximise a panel to fill the view, or float it in a window over the layout. The layout button in the transport offers the Arrange, Mix and Code presets and shows any panel. Each screen lays out for its panel's size.

**Glass (on by default):** a soft ambient background behind see-through panels, cards, track headers and the transport; bottom sheets slide up as frosted glass; sliders, level bars, switches, buttons, M/S toggles and clips have a light fill and a solid outline ([App](app.md), Look).

**The frame (owner, 2026-11-09):** three sections, Build, Files and Arrange; the other workspaces fold into them or open from ⋮ More ([app](app.md), Frame).

**Phone (portrait):** a slim status row (project, tempo, CPU, More) on top; the section; then the transport in thumb reach (undo, redo, position, stop, play, record; drag sideways to scrub) and the section bar. Both hide while the keyboard is open, and a downward swipe on the section bar brings the status row within reach.

**Phone (landscape):** compact (owner, 2026-11-10): a narrow icon rail on the left (with the project and More), the section, the transport at the bottom with the tempo and CPU; edge to edge under the camera cutout, controls kept clear of it. In both orientations the top bars tuck away while the content scrolls down ([app](app.md), Frame).

**Desktop, tablets:** the rail, the transport bar and docking panels, which can also float in windows. Files is a Unity-style tree, grid and inspector here; on a phone the tree is a drawer.

The track header is the quick-control surface (mute, solo, generator, folder and clip actions). The Mixer edits the same volume and pan values. Project settings and global controls stay behind the settings control to preserve timeline space.

## Device editors

**Owner (2026-11-10, #173):** every device's UI is "completely visual, fun to use and easy to use"; today's knob pages are "strictly going to be a fallback if there's no UI built in". On a phone a device opens as a full-screen editor with tabs for its sections and Back returns; it keeps the app's glass look, neon accents and compact sizes ("don't make the UI too big"). Built so far: the frame, the fallback page and the flagship synth's editor, with grabbable visuals (wavetable, unison fan, filter curves, envelopes, LFOs, EQ nodes) and a Vital-style mod matrix: drag a source chip onto any knob, then drag the knob's coloured ring for the amount ([app](app.md), Arranger: Device editors). On wide screens it is a floating glass window rather than a docking panel, since the dock's panels are fixed screens. [Assumption] The tab names, the per-oscillator picker on phones, the ring drag starting on the knob's outer edge and a new route's 25 % amount are first choices for the owner to confirm.

## One gesture vocabulary

The same meaning everywhere, so nothing has to be learned twice:

| Gesture (touch) | Desktop | Meaning |
| --- | --- | --- |
| Tap | Click | Select, or toggle a step or cell |
| Long-press | Right-click | Options menu, or pick up to drag |
| Drag | Drag | Move a note or card, or change a value |
| A second finger resting during a drag | Shift | Free the drag from the grid (piano roll) |
| A second finger touched down during a clip or track drag | Ctrl | Copy instead of move (Arrange; touch it again to move) |
| Double-tap | Double-click | Reset a value to its default (every knob and slider with a meaningful default: a component's knob to its descriptor's default, a track's volume to 0 dB, pan to centre, zoom to its default; `ResetOnDoubleTap`); open an item |
| Two-finger pinch / pan | Wheel, Ctrl+wheel | Zoom and scroll a grid or roll |
| Swipe up on the sheet | — | Show more of the inspector |

- **Value controls:** a phone uses full-width sliders, never small knobs.
  - Dragging further away from the slider (up or down) gives finer control, like scrubbing a video.
  - Double-tap resets the value.
  - The value is always shown as a number, and tapping the number lets you type one: clamped to the range, snapped to the step, and refused when it isn't a number.
- **Undo and redo** are always on screen. On touch they're the safety net that makes experimenting feel safe.

## Editors

**Current implementation (checked 2026-11-01):** the pattern editor is implemented in Builder. It includes a piano roll and drum grid over the same text-backed pattern model, Draw/Select/Curve/Erase tools, adaptive grid and snapping, velocity/chance lanes, note extras, per-note expression editors, live note preview, multi-selection and generator actions. See [App](app.md) for the current interaction details and [music workflow gaps](music-workflow-feature-gap-plan.md) for what remains.

Implemented pattern editing includes:
- Draw, select, erase and curve tools; undo/redo; adaptive/fixed grid, triplets and snap/free timing, from one magnet button whose sheet also sets the value grid that lanes and curves snap to.
- Note velocity, chance, ratchet and slide extras.
- Per-note pitch bend, pressure/volume, timbre and vibrato; editable points and segment bends.
- Velocity and chance lane curves.
- Euclidean, random-in-key, arpeggiate, humanize, chord stamp, legato, reverse and pitch inversion actions.
- Multi-selection, linked/independent clip references and multi-edit behavior.
- MIDI pattern import/export through the pattern editor.

**Remaining pattern work:** kit-row pattern routing, code-generated procedural patterns/Freeze, advanced quantization and groove tools, and any further editing improvements justified by tested gaps. Do not describe the existing curve tools or pattern generators as unimplemented.

The broader UI specification below records design intent as well as current behavior. Where it differs from the app reference, [App](app.md) is authoritative for what currently ships.

## Keyboard (PC)

- **Everything without a mouse:**
  - Tab and arrow keys move focus between panels and inside grids, with a visible neon focus ring.
  - Enter opens or plays. The Menu key or Shift+F10 opens the same options as a long-press.
  - Every control can be adjusted from the keyboard: arrows for steps, Shift+arrows for fine steps, typing a number to set it.
- **Shortcuts like Reaper's where they overlap:** Space for play/pause (owner, 2026-11-05: Space pauses, and Shift+Space stops), Ctrl+Z for undo, and Ctrl+S for save. **[Assumption]** Reaper's default keymap must be checked against its current action list before the shortcuts are fixed.
- **Workspace shortcuts:** Ctrl+1 Builder, Ctrl+2 Arranger, Ctrl+3 Exporter, Ctrl+4 Mixer, Ctrl+5 Engine Lab, Ctrl+6 Automation, Ctrl+7 Files and Ctrl+8 Plugin Builder.
- **Shortcut overlay:** `?` shows every shortcut for the current screen.
- **Customisable, like Reaper** (owner, 2026-10-28): every command is an action with keys you can change per area, plus macros and your own toolbars. The keys are changed in the key bindings editor (Settings → Key bindings, built 2026-11-05); details in [actions](actions.md).
- **Vim-style** (owner, 2026-10-28): with a keyboard, the whole app works modally: modes, counts, `:` commands, `.` and recorded macros. The code editor has optional Vim editing. See [actions](actions.md#vim-style-control).

## Light on CPU and RAM

**Owner (2026-10-28):** C.A.W must run as light as possible, so it works on very low-end devices ("a potato"). Every feature is built with that limit.

- **[Assumption]** For testing, a "potato" means:
  - an Android 8 phone (the app's minimum, `minSdk` 26) with 2 GB of RAM and an old 4-core ARM CPU
  - an old dual-core Windows laptop
- **[Fact]** Performance profiles are Full Experience, Balanced, Lightweight and Minimal. All retain 30 Hz meter cadence; Lightweight/Minimal use the reduced voice budget, and Minimal hides scope panels. Overload auto-response selects Lightweight once when enabled ([app](app.md)).
- **Editors:**
  - The piano roll and grid repaint only when something changes, plus the playhead's small region while playing.
  - The pattern model stays the source of truth while editing. It's turned into text only when saving or sending to the engine, not on every touch.
- **Keys:** a key press is a lookup in a per-area table. Search and completion run only while the action list or `:` is open.
- **Auto-update:** compiles off the UI thread after the pause you set. A change that doesn't compile costs nothing on the audio side.
- **The audio never depends on the UI.** The C++ engine runs on its own thread ([engine](engine.md)), so a slow frame can't cause a dropout.
- **Repaint only what moves:** meters, the playhead and scopes use bounded repaint regions. Engine Lab's master scope and spectrum read from the native scope buffer; polling stops when stopped or hidden ([performance](performance.md)). Each peak meter falls on its own ticker only while it shows something, then stops.
- **Draw grids, not widgets:** use painters for dense grids and lists built lazily; do not create a widget for every note or cell.
- **No heavy assets:** system fonts, built-in icons and restrained short animations; the only images are the small crow logo (`assets/logo/`) and the launcher icons.
- **Compact data:** patterns are flat arrays of note events in the engine. A layer's memory is fixed when it is set up, never while playing.
- **Budgets (targets to measure, not facts yet):**
  - near 0% CPU from the UI when stopped
  - RAM under 150 MB on the S22+ with a 16-layer project
  - an APK under 30 MB (v1's artifact zip is about 25 MB)
- **Measure with:** Flutter DevTools and Perfetto on Android.

## Not yet implemented

Audio recording, audio clips and clip-following automation are not part of the current implementation; MIDI recording is limited to a connected USB keyboard ([app](app.md), Frame: Record). They are planned at the later stages in the permanent [roadmap](roadmap.md).

## Performance profiles

Settings provides Full Experience, Balanced, Lightweight and Minimal. Profiles reduce decorative effects before useful responsiveness: meter polling stays at 30 Hz in every mode. Lightweight/Minimal use the existing reduced voice budget; Minimal hides scope panels and turns motion off (Lightweight turns glass blur off and Minimal turns Glass off, which brings back solid panels and controls; the Motion, Haptics and Glow settings and the shared motion rules are in `lib/ui/motion.dart`; see [UI plan](ui-plan.md), "Feel"). See [Performance](performance.md#ui-performance-profiles) for the exact behavior and remaining device measurements.
