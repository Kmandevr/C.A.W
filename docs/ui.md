---
title: UI design
summary: Arrangement-first creative UI across eight shared-state workspaces, with touch-first phone layouts and keyboard/mouse desktop access.
updated: 2026-11-02
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
  - Clip launchers built for a mouse are too small for fingers. Apps need touch-sized controls and options on tap-and-hold.
- **Piano rolls are the hardest part on a phone.**
  - Fingers aren't as accurate as a mouse, and touch has no right-click. Apps need bigger notes and a tool bar instead of modifier keys. Users liked hearing a chord when they move a note, and selecting several notes at once ([Loopy Pro forum](https://forum.loopypro.com/discussion/comment/359423/)).
  - Research on mobile piano rolls points the same way ([ISMIR 2022](https://archives.ismir.net/ismir2022/latebreaking/000034.pdf)).
- **Per-step values without menus.** Elektron's parameter locks let any step carry its own sound settings. Steps that carry them blink, so you can see where they are ([Elektron quick start](https://www.elektron.se/wp-content/uploads/2024/09/Know-How-Mono-Quick-Start.pdf), [Elektronauts](https://www.elektronauts.com/t/see-what-trigs-are-parameter-locked/231976)).
- **Curves drawn on the note.**
  - Bitwig draws micro-pitch on the note itself. Its curves are edited by adding points, moving them and bending the segments between them ([Bitwig user guide](https://www.bitwig.com/userguide/latest/inspecting_note_clips), [Admiral Bumblebee](https://www.admiralbumblebee.com/music/2017/06/16/bitwig-feature-review-note-expression)).

## Arrangement workspace

The Arranger is the main composition view. It is a horizontal song timeline with one row per track, a bar ruler, reusable MIDI clips, and a separate mixer panel. It is not a session grid or clip launcher.

- A track owns its generator, effects, volume, pan, mute/solo and eventual routing. Clips reference pattern sources; they do not own instruments.
- A clip instance has a timeline start, visible length, source offset and loop setting. Moving a clip does not rewrite its source. Independent duplication clones the pattern source; linked duplication shares it.
- Drag the clip body to move it, Alt-drag to shift its source offset, drag its right edge to resize it, tap to select, Shift-tap to add clips to the selection, and double-tap to open the existing piano roll. Companion sources appear as faint references by default. Explicit multi-edit mode mirrors note additions, deletions, moves, resizes and expression changes to selected independent pattern sources while keeping each source's note IDs local; linked clips still share one source.
- The track header keeps mute/solo and generator selection close to the timeline. The mixer panel edits the same track values, not a second copy of them.
- Folders nest, can collapse, and can be organization-only or enabled as stereo group buses. Children route through the nearest enabled ancestor bus; folder volume and pan act on the summed group.
- Volume and pan automation lanes are editable under a track. Points follow song time and are interpolated by the native engine. Clip automation and plugin/global parameter automation are not implemented yet.
- Tapping empty timeline space sets the edit cursor; long-press-drag creates a time selection without blocking horizontal scrolling. Selected clips can be split at the selection end. Snap resolution is adjustable and Shift bypasses snapping. Audio clips are planned for a later roadmap stage; they are not implemented in the current app.

## Layout

The application shell currently exposes eight destinations: Builder, Arranger, Mixer, Engine Lab, Automation, Exporter, Files and Plugin Builder. Builder includes shared active-track quick controls; Arranger exposes adjustable track heights and a playhead overlay that repaints independently of clip layout. Mixer uses a draggable desktop split between channel strips and the module inspector; the mobile view stacks them. The Files workspace imports/exports portable `.cawproj` and `.caw` files. Plugin Builder validates and packages native `.caw` modules; external CLAP/VST3 binaries remain blocked on a native plugin host/SDK. The Arranger remains the composition workspace; the old session grid is retired. Mixer, Engine Lab and Automation are separate destinations that read and edit the shared project state.

**Phone (portrait):** transport at the top, then the track headers beside a horizontally scrolling song timeline. The Arranger's compact mixer panel remains available below the timeline. Builder, Arranger and Mixer are primary bottom destinations; More opens Engine Lab, Automation, Exporter, Files and Plugin Builder.

**Phone (landscape):** the timeline gets the available width. Track headers stay aligned with their lanes while the song timeline scrolls horizontally. The mixer remains a separate panel.

**Desktop / wide:** navigation rail, persistent transport, and a full-width arrangement timeline. Track headers remain fixed beside the horizontally scrolling timeline; the Arranger's mixer panel can be opened without replacing the arrangement, and the dedicated Mixer remains a separate detailed workspace; Files exposes portable project/module import and export.

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

**Current implementation (checked 2026-11-01):** the pattern editor is implemented in Builder. It includes a piano roll and drum grid over the same text-backed pattern model, Draw/Select/Curve/Erase tools, adaptive grid and snapping, velocity/chance lanes, note extras, per-note expression editors, live note preview, multi-selection and generator actions. See [App](app.md) for the current interaction details and [music workflow gaps](music-workflow-feature-gap-plan.md) for what remains.

Implemented pattern editing includes:
- Draw, select, erase and curve tools; undo/redo; adaptive/fixed grid, triplets and snap/free timing.
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
- **Shortcuts like Reaper's where they overlap:** Space for play/stop, Ctrl+Z for undo, and Ctrl+S for save. **[Assumption]** Reaper's default keymap must be checked against its current action list before the shortcuts are fixed.
- **Workspace shortcuts:** Ctrl+1 Builder, Ctrl+2 Arranger, Ctrl+3 Exporter, Ctrl+4 Mixer, Ctrl+5 Engine Lab, Ctrl+6 Automation, Ctrl+7 Files and Ctrl+8 Plugin Builder.
- **Shortcut overlay:** `?` shows every shortcut for the current screen.
- **Customisable, like Reaper** (owner, 2026-10-28): every command is an action with keys you can change per area, plus macros and your own toolbars. The draft is in [actions](actions.md).
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
- **Repaint only what moves:** meters, the playhead and scopes use bounded repaint regions. Engine Lab's master scope and spectrum read from the native scope buffer; polling stops when stopped or hidden ([performance](performance.md)).
- **Draw grids, not widgets:** use painters for dense grids and lists built lazily; do not create a widget for every note or cell.
- **No heavy assets:** system fonts, built-in icons and restrained short animations.
- **Compact data:** patterns are flat arrays of note events in the engine. A layer's memory is fixed when it is set up, never while playing.
- **Budgets (targets to measure, not facts yet):**
  - near 0% CPU from the UI when stopped
  - RAM under 150 MB on the S22+ with a 16-layer project
  - an APK under 30 MB (v1's artifact zip is about 25 MB)
- **Measure with:** Flutter DevTools and Perfetto on Android.

## Not yet implemented

Audio recording, MIDI recording, audio clips, clip-following automation and module/global parameter automation are not part of the current implementation. They are planned at the later stages in the permanent [roadmap](roadmap.md).

## Performance profiles

Settings provides Full Experience, Balanced, Lightweight and Minimal. Profiles reduce decorative effects before useful responsiveness: meter polling stays at 30 Hz in every mode. Lightweight/Minimal use the existing reduced voice budget; Minimal hides scope panels. See [Performance](performance.md#ui-performance-profiles) for the exact behavior and remaining device measurements.
