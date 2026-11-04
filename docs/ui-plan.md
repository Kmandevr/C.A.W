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

- **Track headers:** name, colour, mute, solo, record-arm (later), the automation button, and a meter. They are drag handles for reordering and nesting.
  - Add a track with "+" or by double-tapping below the last track.
  - A folder collapses, and can act as a bus as today.
- **Making MIDI clips:**
  - Drag on empty track space with the Draw tool (a long-press, then drag, on touch) to make a clip as long as the drag.
  - Tapping a clip selects it; double-tapping, or the clip's piano-roll button, opens it in the docked Piano roll.
  - Clips move, resize and duplicate as today (linked or independent).
- **Drag and drop onto the arrangement:**
  - Drop an instrument or pattern from Files/Code onto a track: an instrument goes into that track's chain, and a pattern becomes a clip.
  - Drop on empty space below the tracks to create a new track.
- **Automation lanes:**
  - The track's automation button drops lanes down under the track.
  - Each lane has a parameter dropdown listing volume, pan and every instrument or effect parameter in the chain. Several lanes can be open.
  - One tap collapses them all.
  - Points are edited in the lane, with the existing curves and undo.
- **Reactive colour:** each clip and its header glow with their own track's level while playing, read from the meters the app already polls at 30 Hz.
  - Settings switch it off.
  - The Minimal profile turns it off.
- **Empty tracks are silent.** Loading a project or a template turns each clip-less looping layer into one clip across the song.

### Track chain (instruments and effects)

- **The Inspector shows the selected track's chain as an ordered list:** instruments and effects, each with bypass, remove and its parameters folded open. Dragging reorders it.
- **Several instruments per track needs engine work.** Today a layer is exactly one generator followed by effects (see [engine](engine.md) and [engine status](engine-build-status.md)).
  - **[Proposal]** The rule: each instrument in a chain receives the track's MIDI, and its output is **added** to the audio arriving at it. Each effect processes everything above it.
  - That gives stacking (two instruments then a shared reverb) and placement (an effect on the first instrument only, then a second instrument).
  - This is an engine and C API change, so it goes to GPT as an issue. The UI step waits for it, or shows one instrument until then.

### Piano roll

- **It opens docked below the arrangement,** following the selected clip, and can be resized or made full screen. It replaces the 200 px inline roll in the Builder.
- **#7:** a one-finger drag on empty grid scrolls, and drawing is deliberate.
- **#21:** with a selection, Copy and Paste buttons appear, and dragging any selected note moves the group.
- **#15:** curve points snap to the grid, the handles can't be confused, and a curve never lengthens its note.
- **#9:** check the existing look and size settings.
- **Note stretching:**
  - The resize handles at both ends get a touch zone of at least 48 dp. The zone reaches outside the note when the note is narrow.
  - The new length shows while you drag.
  - The end eases onto the grid (see Feel). Several selected notes stretch together.

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

- **Motion:**
  - Short ease-out animations (about 120–200 ms) for panels, lanes, sheets and selection.
  - Nothing animates while audio-critical work runs.
  - The Minimal profile and the system's reduce-motion setting turn animations off.
- **Smooth snapping:**
  - While dragging, the item follows your finger. On release, a short spring settles it onto the grid line, with a light haptic tick on Android.
  - Snap targets highlight while you approach them.
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
