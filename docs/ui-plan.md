---
title: UI plan
summary: The owner's UI direction (2026-11-04): the arrangement is home and looks like a standard DAW, with docking panels, a Unity-like code workspace and a Reaper-like mixer; today's findings, the order of work and open questions. Nothing here is built yet.
updated: 2026-11-04
---

# UI plan

**Owner (2026-11-04):** Claude does the UI and plans before building. Everything in "Design" and "Order of work" is a **[Proposal]** until the owner approves it. The owner's own words are marked "(owner)". Current behaviour is in [app](app.md), and the existing design rules are in [UI design](ui.md).

## The owner's direction (2026-11-04)

- **The arrangement is home.** It is the screen the app opens on, and about 90% of building a song happens there. It looks more like a standard DAW.
- **Tracks:**
  - Add empty tracks, and nest them in folders.
  - Add instruments and effects to a track, in an order you choose. **A track can hold several instruments** (owner).
  - A track with no clips is silent, like a DAW (owner). Templates and loaded projects get their loops turned into clips.
- **Automation:**
  - It works like Reaper's, but differently. Each track has an automation button that drops lanes down under the track.
  - Each lane has a dropdown that picks its parameter. Several lanes can be open, and you edit them when you need to (owner).
- **MIDI:**
  - Make MIDI clips from the arrangement, as in Reaper.
  - Tapping a MIDI clip opens the piano roll in a docked panel below the arrangement. It can go full screen (owner).
- **Code workspace:**
  - Works like Unity's: a real coding environment with a searchable file system, not a text box.
  - Its tree shows the project's assets **and device folders the user picks** (owner).
- **Mixer:** the extras and fine-control screen. It lets you do everything, like editing effect amounts by hand, as in Reaper's mixer.
- **Docking:**
  - Panels dock and move like in Unity, **on the phone too** (owner).
  - Drag and drop onto the arrangement.
- **Feel:**
  - Everything has light animations, so it feels smooth.
  - Snapping is smooth, like in a game.
  - Note stretching (resizing) in the piano roll needs refining.
  - It must feel good to use.
- **Colour:**
  - Tracks and clips have their own colours, and the UI uses one main accent plus colours that carry meaning (owner).
  - Clips and track headers react to the music: each glows with its own track's level. This can be switched off (owner).

## What the app looks like today

**[Fact, 2026-11-04]** These findings come from the Linux debug build under Xvfb with the "First loop" template, at 390×844 (phone portrait) and 1280×800 (desktop).

1. **The quick-action strip covers content.** It floats over the bottom of every phone screen.
2. **The inline piano roll is about 200 px tall on a phone,** under the track card, the pattern header and the description.
3. **The timeline hides sound that plays.** A layer with no clips plays its module all song long (`project.dart` sends its pattern directly), but its row says "Add MIDI clip with +". That is four of five template tracks.
4. **The transport has only play, BPM and CPU.** There is no stop, no position, no loop toggle, and no undo or redo.
5. **Track headers are cramped.** Names are cut off, and clip labels are clipped at the default height.
6. **The workspaces don't look like one app.** Each has its own accent colour and card style. Developer notes appear as body text.
7. **Phone navigation labels only the selected destination.**
8. **The desktop arranger leaves the space below the tracks empty.**

## What other apps do

- **[Fact]** In Reaper, Ctrl/Cmd-drag on a track creates an empty MIDI item as long as the drag. Insert > New MIDI Item, or the pencil tool, also make one. Double-clicking a MIDI item opens the MIDI editor. Double-clicking below the last track adds a track. Sources: [reaper.blog](https://reaper.blog/2013/01/a-shortcut-for-creating-blank-midi-items), [KVR forum](https://www.kvraudio.com/forum/viewtopic.php?p=7318083), [REAPER Quick Start](https://www.reaper.fm/guides/REAPER%20Quick%20Start.pdf), checked 2026-11-04.
- **[Fact]** Reaper plays several instruments stacked in one track's FX chain. How a mid-chain instrument combines with the audio before it depends on the plugin's pins and routing. Sources: [KVR forum](https://www.kvraudio.com/forum/viewtopic.php?p=7458501), [Admiral Bumblebee](https://admiralbumblebee.com/music/2017/04/18/Reapers-Amazing,-but-Awful,-Almost-Anything-to-Anywhere-Routing.html), checked 2026-11-04.

## Design

### Shell and docking

- **One workspace window built from docked panels.** The panels are:
  - Arrangement, Piano roll, Mixer, Inspector (the selected track's chain and parameters), Code, Files, Engine Lab, Exporter and Automation overview.
  - Each panel is a tab that can be dragged to another dock area, split beside another panel, or stacked as tabs.
- **The layout is saved per device.** It includes a reset to default, and a few presets: Arrange, Mix, Code.
- **Default layout:**
  - **PC:** the arrangement fills the centre, with the Inspector on the right and the Piano roll docked below (it opens when needed). The Mixer and Code are tabs.
  - **Phone portrait:** the arrangement on top and one docked panel below, split by a draggable divider. A tab strip picks the bottom panel. Any panel can go full screen.
  - **Phone landscape:** two panes side by side.
  - Touch targets stay at least 48 dp.
- **Built in-house, with no new dependency.** fl_panel (MIT) and dock_panel (BSD-3) exist on pub.dev, but neither handles phone-sized split panes or C.A.W's touch rules, and both are young packages. A small layout tree (split, tabs, panel) in `app/lib/ui/` is cheaper to own.
- **Transport bar, always visible:** play/stop, position (bar.beat), loop on/off, BPM (tap to type, long-press for tap tempo, #19), and undo and redo.
- **The quick actions (#23)** become a toolbar that belongs to each panel. They no longer float over content.

### Arrangement (home)

**Owner's spec (2026-11-04).** The motion, ghost, snapping and haptics rules in Feel apply to everything here.

- **Toolbar:** one context-aware row, the same pattern as the piano roll.
  - **Fixed, left to right:**
    - the tools: Select, Draw (makes clips), Split, Erase
    - the snap magnet with its grid: Bar, Beat, 1/8, 1/16 and triplets. Tap toggles snapping, and holding Shift (PC) or a second finger (touch) bypasses it.
    - the ⋮ menu: zoom to fit, track heights, view, customise
  - **Middle part:**
    - **Nothing selected:** + Track and + Folder.
    - **Clips selected:** Duplicate, Linked duplicate, Split, Colour, Delete.
    - **A track selected:** + Instrument, + Effect, Duplicate, Colour, Delete.
- **Track headers:**
  - **Compact by default:** a colour strip, the name, M and S, the automation ▾ button and a meter.
  - **Wider:** drag the header column's edge wider, as in Reaper's track panel, to reveal volume and pan, the instrument name and the effect count.
  - Drag a header's bottom edge to set that track's height.
- **Nesting:**
  - Drag a header onto another track. It highlights, and the dragged track goes inside. Drag a child out to the left to take it out. An indent line shows the depth.
  - Or select several tracks and press Group to put them in a new folder.
  - **Any track can be a parent (owner):** a track with children still plays its own instrument and clips, as in Reaper. Today a folder is a bus with no sound of its own, so this needs engine work (GPT).
- **Clips:**
  - **Making one:** with the Draw tool, drag across a track to make a clip that long, snapped, with the ghost. A tap makes a clip the length of the last clip you made (1 bar at first). The new clip is selected, and the docked piano roll shows it.
  - **Editing:**
    - Tap selects, and dragging moves it, using the ghost and the settle motion.
    - A long-press opens the clip menu, and a double-tap opens it in the piano roll.
    - The left edge trims the start.
  - **Dragging the right edge** past the content repeats the pattern, with a faint line where each repeat starts. A corner handle, or the clip menu, switches the clip to extend instead, which adds empty space.
  - **Colour:** a clip takes its track's colour unless you give it its own.
- **Split tool:**
  - A tap on a clip splits it at the snapped point, with a ghost line showing where.
  - With several clips selected, all of them split there.
  - Dragging along a clip splits it at both ends of the drag.
- **Selecting:**
  - With the Select tool, dragging on empty space draws a box that selects the clips and automation points inside it.
  - A long-press then drag selects a time range across tracks, for split, copy, loop or export.
  - Tapping a header selects the track and shows it in the Inspector. Shift, or a second finger, adds to the selection.
- **Ruler:**
  - A tap moves the playhead there, with a glide.
  - Dragging along the ruler sets the loop region, and the loop button turns it on or off.
  - Named markers (Intro, Drop) can be added, jumped to and dragged.
  - While playing, the view follows the playhead, and a toggle turns that off.
- **Zoom and scroll:**
  - On touch, pinch horizontally to zoom time and vertically to change track heights. A one-finger drag on empty space scrolls.
  - On PC, Ctrl+wheel zooms time and Alt+wheel changes track heights.
  - Zoom glides. Zoom to fit is in ⋮.
- **Drag and drop:**
  - An instrument dropped on a track goes into its chain.
  - An effect dropped on a track or one of its clips goes to the end of that track's chain.
  - A pattern or MIDI file dropped on a track becomes a clip at the snapped drop point.
  - Anything dropped on the empty space below the tracks makes a new track with it.
- **Automation lanes:**
  - The track's automation ▾ button drops lanes down under the track. Each lane has a parameter dropdown listing volume, pan and every instrument or effect parameter in the chain. Several lanes can be open, and one tap collapses them all.
  - Lane points snap to the time and value grids (see Piano roll) and use the same handles: bend with detents, or Bezier once the engine supports it.
  - The Draw tool and freehand drawing work in lanes too.
- **Reactive glow:**
  - It is subtle and adjustable: a settings slider runs from off to strong.
  - Clips and headers brighten softly with their own track's level, and peaks flash briefly on hits like kicks.
  - It reads the meters the app already polls at 30 Hz. The Minimal profile turns it off.
- **Empty tracks are silent.** Loading a project or a template turns each clip-less looping layer into one clip across the song.

### Track chain (instruments and effects)

- **The Inspector shows the selected track's chain as an ordered list:** instruments and effects, each with bypass, remove and its parameters folded open. Dragging reorders it.
- **Several instruments per track needs engine work.** Today a layer is exactly one generator followed by effects (see [engine](engine.md) and [engine status](engine-build-status.md)).
  - **[Proposal]** The rule: each instrument in a chain receives the track's MIDI, and its output is **added** to the audio arriving at it. Each effect processes everything above it.
  - That gives stacking (two instruments then a shared reverb) and placement (an effect on the first instrument only, then a second instrument).
  - This is an engine and C API change, so it goes to GPT as an issue. The UI step waits for it, or shows one instrument until then.

### Piano roll

**[Fact, 2026-11-04, from `pattern_editor.dart` and `note_expression.dart`]** How it works today:
- **Stretching:** only a note's right end stretches, only for a single note, and the end jumps grid line to grid line.
- **Pitch curves on the roll:** values snap to semitones but times don't snap. A segment's bend is an invisible vertical drag, unsnapped, with no handle.
- **Volume and timbre curves:** edited in a 72 px box in the extras panel, with time snapping and no value snapping.
- **The engine evaluates note curves** (`engine/src/pattern.h`, shape `u^(4^bend)`).

**Owner's spec (2026-11-04):**
- **Placement:**
  - It opens docked below the arrangement, following the selected clip, and can be resized or made full screen.
  - It replaces the 200 px inline roll in the Builder.
- **One snap switch:**
  - A magnet button in the roll toolbar turns snapping on or off for notes and every curve.
  - While it is on, holding Shift (PC) or resting a second finger (touch) bypasses it for that drag.
- **Two grids:**
  - **Time:** the existing resolution: adaptive, fixed or triplets.
  - **Value:** a new value-grid setting beside it: 1/4, 1/8 (the default), 1/16, 10% or 5%. It applies to volume, timbre, velocity and chance.
  - Pitch snaps to semitones, or to a chosen cents step.
- **Stretching notes:**
  - Drag the right end to change the length, or the left end to move the start and keep the end.
  - With several notes selected, all of them stretch by the same amount.
  - The end follows your finger exactly. A faint ghost shows the snapped length, and on release the note springs onto the ghost (about 150 ms).
  - The new length shows as a number while you drag.
  - Each end has a touch zone of at least 48 dp, reaching outside the note when the note is narrow.
- **Curves on a stretched note:** a toolbar toggle (also saved as a setting) chooses what happens:
  - **Stretch with the note:** points keep their relative place. This is today's behaviour.
  - **Keep their timing:** points keep their absolute time. A longer note holds the last value, and a shorter one trims the curve.
- **What snaps:** pitch, volume and timbre curves on notes, the velocity and chance lanes, and the arrangement's automation lanes. Points snap to the time grid × the value grid while snap is on.
- **Handles (both kinds, selectable per point):**
  - **Bend handle (default):** a visible handle in the middle of each segment. Dragging it bends the segment, and it clicks into detents: straight, then gentle, medium and strong ease-in or ease-out. With snap off it moves freely. It uses the existing `bend` field, so no format change.
  - **Bezier:** a point can be switched to two Bezier handles that snap to grid intersections. The pattern file and the engine's curve evaluation don't support this yet, so it needs an engine issue (GPT) and a format change. No compatibility is needed before Release 1. The UI ships the bend handle first.
- **Freehand drawing:**
  - With the Curve tool, drag to draw a shape.
  - On release, the stroke is simplified to a few clean points on the grid, which the handles then refine.
  - With snap off, the points stay where you drew them, still simplified.
- **Animation:** snapping, ghosts, handles and detents use the motion rules in Feel. Points and handles grow slightly under the finger, and detents give a light haptic tick on Android.
- **Toolbar (owner: one context-aware row):**
  - **Fixed, left to right:**
    - the four tools: Draw, Select, Curve, Erase
    - the snap magnet with the time grid: tap toggles snapping. Its ▾ menu holds the time grid, the value grid, triplets and adaptive.
    - the ⋮ menu: generators, quantize, lanes, view, customise
  - **Middle part:** it changes with what you're doing and slides and fades between states (160 ms).
    - **Nothing selected:** the velocity-lane toggle and zoom to fit.
    - **Notes selected:** Copy, Paste, Duplicate, Delete (#21).
    - **Curve tool:** the curve target (Pitch, Volume, Timbre, Velocity, Chance), the handle type (bend or Bezier), the stretch-or-keep toggle for curves, and freehand.
  - **Moved elsewhere:**
    - Undo and redo live in the transport bar.
    - Full screen and the roll/drum switch live in the panel's header.
  - **Customising (#9):** the existing toolbar editor still chooses which actions fill the fixed and idle slots, and the contextual groups stay.
  - **Desktop:** the same row, with every group shown inline because there is room.
- **Existing issues folded in:**
  - **#7:** a one-finger drag on empty grid scrolls, and drawing is deliberate.
  - **#21:** with a selection, Copy and Paste buttons appear, and dragging any selected note moves the group.
  - **#15:** precise curve selection, handles that can't be confused with note resizing, and a curve that never lengthens its note.
  - **#9:** check the existing look and size settings.

### Code workspace

- **A file tree on the left (Unity's Project window), editor tabs in the middle and problems below.**
  - The tree has search, folders, tags and favourites. It shows the project's assets and the device folders the user has added.
  - Editor tabs keep unsaved marks.
  - The problems list jumps to errors.
  - Inspector-style controls show beside the code.
- **Device folders:**
  - **Windows:** read through `dart:io`.
  - **Android:** read through the Storage Access Framework. The user picks a folder, and the app keeps that permission.
  - **[Proposal]** Write this as a small Kotlin platform channel in the app, not a package. `shared_storage` (MIT) exists but has a reported bug where the permission is lost after a reboot, and `saf` has no stated licence.
  - Files from device folders are untrusted input: a `.caw` from a device folder runs under the same constrained-language rules as a downloaded module.
  - The security reviewer checks this step.
- **#20 (Android keyboard Backspace)** is fixed in this step, since the editor is rebuilt.
- **#10 (new control types)** stays blocked on its language-syntax review.

### Mixer (fine control)

- **One channel strip per track and folder:** a fader, pan, meter, mute, solo, and its chain as a list of instrument and effect slots, Reaper-style. Tapping a slot opens its parameters, with every value editable by drag or by typing.
- Sends and master effects show once the engine supports them. Until then they are not shown.

### Feel

- **Motion feel (owner, 2026-11-04):** smooth, with a tiny overshoot, and distance-aware. The farther something travels, the faster it moves, so a long move doesn't take proportionally longer (logarithmic).
  - **[Proposal] Duration:** `d = clamp(80 + 40·log2(1 + distance_px / 8), 80, 240)` ms. That is about 120 ms for 8 px, about 210 ms for 64 px, and 240 ms at most.
  - **Overshoot:** at most 2 px, or 4% of the distance, whichever is smaller. Then it settles.
  - **Fixed durations:** small feedback (press, a handle growing) takes 80 ms, standard changes (toolbar parts, selection, lanes opening) take 160 ms, and panels and sheets take 240 ms. Entering eases out, and leaving eases in.
- **Smooth snapping:**
  - While dragging, the item follows your finger exactly. A ghost shows where it will land, and the target grid line lights up as you get near it.
  - On release, it settles onto the ghost with the distance-aware motion above.
  - Points and handles grow slightly under the finger.
- **Haptics (owner):** on by default, and can be switched off. On Android a light tick plays when something snaps, a handle clicks into a detent, or a note is placed.
- **Motion setting (owner):** Full, Reduced or Off.
  - Reduced keeps fades only, with no springs or movement.
  - The Minimal profile sets Off, and the system's reduce-motion setting sets Reduced.
- **Cost:** animations run only while something moves, and an idle screen draws no frames.
- **Steady frame rate:** the existing rules hold. Dense views are drawn with painters and repaint only what changes ([UI design](ui.md#light-on-cpu-and-ram)).

## Order of work

Each step is one small PR to `Main`. It includes widget tests, screenshot (golden) tests at phone portrait, landscape and desktop, a code-reviewer pass and release-check. It updates [app](app.md) and [UI design](ui.md). Engine changes go to GPT as issues.

1. **U0, foundations:**
   - design tokens (spacing, type scale, one accent plus colours for meaning, track colours)
   - shared widgets
   - motion and snapping helpers
   - golden-test setup
2. **U1, the docking shell:**
   - the layout tree, panels, tabs and split dividers, on the phone too
   - saved layouts and presets
   - the transport bar with undo/redo and tap tempo (#19)
   - the arrangement as home
3. **U2, arrangement:**
   - track headers, nesting, add and reorder
   - drawing MIDI clips
   - empty tracks silent (with the app-side project conversion)
   - reactive colour
4. **U3, automation lanes:** the drop-down lanes and the parameter dropdown.
5. **U4, piano roll:** docked, with #7, #21, #15 and #9, plus note stretching.
6. **U5, track chain and Inspector:** reorder, bypass, drag and drop from files. Several instruments arrive when the engine issue lands.
7. **U6, mixer:** strips with chains and parameter editing.
8. **U7, code workspace:** the file tree, tabs, problems and device folders (security review), plus #20.
9. **U8, the remaining panels:** Exporter, Files, Engine Lab and Plugin Builder become panels with the U0 widgets.

## Open questions for the owner

- **Startup screen:** the 2026-10-28 choice was a startup screen (continue, new, template). Should the app now open straight into the last project's arrangement, with new, template and open in the project menu?
- **Font for goldens:** stable screenshot tests need a bundled font. JetBrains Mono (SIL OFL 1.1) is the proposal, but it is a new dependency, so it needs your approval.
- **Several instruments per track:** is "each instrument adds its output to the audio above it" the rule you want? It goes to GPT as an engine issue.
- **Docking:** build it in-house (proposed), or try a package?
