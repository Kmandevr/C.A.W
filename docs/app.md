---
title: App
summary: The built Flutter app: eight workspaces, shared engine state, portable files, performance profiles, storage and CI.
covers: [app/, engine/include/caw.h, engine/src/worker_api.cpp, engine/src/hardware.*, engine/src/execution.*, engine/src/scheduler.*]
updated: 2026-11-10
---

# App

The Flutter app in `app/`. The engine it drives is described in [engine](engine.md), and v1's scope is in [roadmap](roadmap.md). Everything here is **[Fact]**, checked in the code and by its tests.

## Engine integration

The app calls the shared native engine only through the versioned C API in `lib/engine/bindings.dart` (`cawApiVersion` 3, equal to `CAW_API_VERSION`; the app refuses a library reporting another version). Project compilation, asynchronous source checks and offline WAV renders are submitted as native jobs to the bounded C++ `AdaptiveWorkerPool`; the app owns opaque job handles and polls status/progress, reads the result/error and releases each handle. Project submissions retain the engine handle until completion, so disposing an engine waits for its accepted project jobs rather than invalidating a worker pointer. Inputs are copied before the FFI call returns. No Dart callback is invoked from a native worker thread, and no job runs on the audio callback. `lib/engine/execution.dart` binds the native hardware-profile probe, workload planner and job API. Jobs carry foreground/offline priorities; the app starts the pool with an interactive-preview budget so a foreground job can run alongside a single offline export, and the host can apply updated workload/pressure plans through the same native policy API.

Settings shows the detected logical cores, conservative work-memory budget, SIMD capability, GPU-compute capability and the interactive workload plan. The engine splits that work-memory budget into internal shares for project state, graph working memory, compilation and retirement (`EngineResourceBudget` in `engine/src/execution.h`; a 128 MiB total is assumed when memory cannot be measured). Settings does not show the shares. On Android, the host reads `PowerManager` thermal status (Android 10+) and battery-saver state, then listens for thermal and power-save changes without polling. Foreground/background and audio-playing transitions also refresh the active worker budget. Unsupported platforms remain explicitly `Unknown` rather than assuming normal pressure; background/offline work reserves one host core where possible, and GPU work is disabled while pressure is unknown. The current engine reports GPU compute unavailable. Native project/check/render jobs now use the C++ pool; generation and analysis jobs remain future integration work.

## C++ project sources

The project model stores C++ component entries alongside existing project modules. Each entry keeps its project-relative `CMakeLists.txt`, `caw.component`, source/header files and exact dependency-version pins in project JSON. `CppComponentBuildService` (`lib/platform/cpp_build.dart`) saves the project, validates and materializes sources into an app-private workspace, reuses a persistent CMake build directory, invokes the locally installed CMake/compiler/SDK tools without a shell, parses structured Clang/GCC/MSVC/CMake diagnostics and returns an artifact only after verifying its path. This is a local build path; it does not contact a remote compiler. On Android the build runner refuses with `CAW_ANDROID_TOOLCHAIN_UNAVAILABLE`, because Android needs the bundled compiler library ([C++ creation platform](cpp-creation-platform.md) §6); `lib/platform/cpp_toolchain.dart` validates `caw.toolchain` manifests for that bundled compiler, which is not bundled yet. The caller still has to provision the local tools and target SDKs: automatic package/toolchain installation and proactive dependency acquisition are not implemented. The Engine C API and Dart FFI wrapper support loading/unloading a native library with an explicit per-call trust value and listing the loaded components' descriptors (`Engine.nativeComponents()`, typed in `lib/engine/component_info.dart`; no screen shows them yet), but the app's persisted per-component trust UI and a process-isolated host are not complete. The project model places loaded stereo effects with parameter values on tracks (`LayerDoc.components`) and the master (`ProjectDoc.masterComponents`, `ComponentUseDoc`), and `Engine.setComponentParam` changes a value while playing; no screen places them yet.

## Areas

- **Frame** (`lib/ui/shell.dart`, `lib/ui/frame/`; owner's layout, `docs/decisions.md`): three sections, **Build**, **Files** and **Arrange** (`SectionController`, which also holds Build's open tabs and the track Arrange is focused on).
  - **Phone portrait:** a slim status row on top (crow, project name for the project menu, tempo, CPU, ⋮ More for the Mixer, Automation, Export, Engine Lab and Plugin Builder as pages), the section in the middle, then the bottom transport (undo, redo, the position, stop, play, record) and the section bar. Both hide while the keyboard is open. Dragging sideways on the transport scrubs the playhead a bar at a time (`AppState.seekTo`); a downward swipe on the section bar brings the status row down within reach until the next tap.
  - **Phone landscape:** a slim rail on the left instead of the section bar, the transport at the bottom.
  - **Desktop and tablets** (900 dp wide, or a shortest side of 600 dp or more): the rail, the transport bar below, and the docking panels; the rail shows its section's panel.
  - **Record:** while a MIDI keyboard is connected (Android), Record arms the selected track and starts playback; Stop writes the take as a new pattern clip (`lib/model/live_midi.dart`). Notes from the keyboard play the armed or selected track at any time.
  - **Glass under strain:** after an audio overrun (for 20 s) or while the device is hot or saving power, floating surfaces drop the blur and redraw (`GlassStrainWatcher`).
- **Status row / transport bar contents:**
  - the crow mark
  - the project name, which opens the project menu: rename, new blank project, new from a template, duplicate, open, delete and **Settings…**
  - undo and redo of project edits (`lib/model/history.dart`): one step per burst of edits (until a 600 ms pause, so a drag or a run of typing is one step), up to 100 steps; a project opened fresh starts with none. A burst that changed nothing (Run on unedited code) adds no step and keeps redo, and an undo also drops the library and automation undo steps and the time selection, which described the project before it. Ctrl+Z and Ctrl+Shift+Z do the same outside the piano roll, which keeps its own history, and outside a focused text field such as the code editor, which keeps its own text undo; the code editor shows the undone code
  - the tempo, the playhead as bar.beat while playing, and CPU. Tap the tempo to type it (20 to 400 BPM, to 0.1); long-press it for a tap-tempo pad. The T key taps too, with the same timing (taps over two seconds apart start a new measurement, #19)
  - Play/Pause (Space): a pause keeps the playhead as a step in the loop, which the transport shows with "paused", and the next play resumes there with a 10 ms fade in (`caw_engine_play_at`), on the same beat even after a tempo change. A note that began before that spot isn't heard, and a module's trig waits for its next pass. While playing or paused a Stop button (Shift+Space) appears; after a stop, play starts from the beginning. Space and Stop go by what they last asked for, not the lagging meters, so a quick second press still pauses
- **Build** (`lib/ui/cpp/`, `lib/model/cpp_*.dart`; the C++ Builder, owner's plan in `docs/decisions.md`): its tabs are project C++ components and .caw modules (a .caw tab hosts the Builder below). With none open, a start view offers New effect (the blank pass-through template) and New instrument (the blank polyphonic sine, `CppComponentDoc.blankInstrument`), both trusted as the user's own, and lists the project's C++ components and .caw modules.
  - **Editor:** `re_editor` with C++ colours, line numbers with problem marks, squiggles on Clang's exact ranges, per-file undo and redo, 12.5 sp mono text. The message of the error at the cursor (or the one just jumped to) is drawn over the next line; others show dim at their line's end.
  - **Top row:** the file ▾ menu (the component's files, Versions, open tabs, Start page), an error count only when there are errors (tap: next error), the status and ▶ Build (Ctrl+B).
  - **Key row** (soft keyboard open): ⌖ moves the cursor like a trackpad (hold, then drag, to select), `⇥ { } ( ) ; = < > "` with `:: & * [ ] + - / % !` on its swipe page, hold a key for variants (`==` `!=`, `<=` `<<` `->`), undo and redo. Keyboard closed: Problems, Ref (the SDK and `caw::lib` with Insert), Snippets and ♪ Test as half sheets; in landscape and on desktop Problems and Ref sit in a side panel.
  - **Checking:** a check-only compile about 1 s after typing stops (cancelled by more typing) feeds the squiggles and Problems (by file, errors first, warnings dimmed; tap to jump). **Completion** opens after `.`, `::`, `->` or a short pause in a word (Ctrl+Space): keywords, the SDK and `caw::lib` names, the file's identifiers and the built effect's knobs at once, with Clang's own results merged in when they arrive.
  - **Build** saves, marks the code as the user's own, builds and loads it, so tracks using the effect switch to the new build while playing; code from elsewhere asks "Trust and build" first. Each successful build keeps a version (the last 20 per component, in app-private storage) to view or restore. Edits autosave into the project about 0.8 s after typing stops, when the app goes to the background and when a tab closes, outside project undo. An editing session belongs to its project, so a duplicated project's copy of an effect keeps its own code.
  - **Test** (♪): on a track that uses the effect: Play/Stop with that track soloed (restored after), A/B bypass and the effect's knobs; with no such track it plays nothing. Knob values show dim after the lines that declare them while the effect is on a track.
  - **Desktop:** without the in-app compiler, Build uses a local CMake (on PATH, with `CAW_SDK_DIR`), and checking and completion fall back to the instant list.
- **Builder** (`lib/ui/builder_screen.dart`, the .caw module editor):
  - a row of module chips (generators green, effects pink, libraries blue, patterns yellow)
  - a compact active-track panel shared with the Mixer for track selection, volume, pan, mute and solo; below 900 px wide it is one row (track, M, S) and the tune button opens level, pan and route
  - **New:** a blank Sound, Effect, Pattern or Library first, then the templates (including the Acid synth and the Acid line and Chords patterns)
    - A blank module is a truly empty file. A faint hint shows an example header for the chosen kind until you type.
    - The chosen kind isn't saved, so after a restart an empty file shows the Sound hint. With no header the engine plays it as a bytebeat.
  - a code editor with highlighting and the symbol key row
  - **completion chips** above the key row: typing two or more letters offers matching functions and constants (`adsr` finds `env.adsr`), and a tap types the call with its arguments selected to type over
  - **Library** (the book button, or F1): every function from the engine's `caw_library()` plus the project's own library modules, grouped by category and searchable from the word at the cursor. Each shows its signature, description, arguments and example, with **Insert call** and **Insert example**
  - a one-line status: the error (tap it to jump to the spot), "edited, tap Run", or the module's summary
  - a scope, and a Controls panel built from the module's `param`s and `global`s:
    - sliders (with steps), toggles, and dropdowns (buttons when there are 4 or fewer choices)
    - grouped under `// --- Headers ---`, with tips and doc comments on long-press or hover
    - tap a number's value to type one (clamped to its range and snapped to its step; an entry that isn't a number is refused); a double-tap resets it
    - a "Shares" line naming the module's exports (`kick.env`), and warnings in yellow
    - for a library module, the functions other modules can call
  - **Run** (Ctrl+Enter) sends the code and hot-swaps it. Code that fails keeps the old sound and puts the cursor on the error
  - **Solo preview** plays only this module. An effect is heard through the generator of a layer that uses it, or the project's first generator. A generator plays the pattern of a layer that uses it, and a pattern plays through the sound of a layer that plays it (or the first generator)
  - a pattern opens in the piano roll (`app/lib/ui/pattern_editor.dart`), with a **Text** button for its source; its panel says how many notes it has and which layers play it
    - tools: draw (B), select (V), erase (X); undo/redo; grid resolution 1 to 1/128 (Alt+1..8); snap (N); fixed grid (Alt+F); drum grid (G); full screen
    - the snap magnet shows the time grid; a tap turns snapping on or off for notes and every curve, and its ▾ sheet sets the time grid, triplets, adaptive and the value grid (1/4, 1/8, 1/16, 10%, 5%; saved). Velocity, chance (lane and extras slider), lane curves and the extras panel's volume and timbre snap to the value grid; pitch points snap to semitones and, along the note, to the time grid. Shift or a resting second finger skips snapping for one drag of any kind
    - the grid adapts to zoom, down to the resolution; rows in the project's key are lit; velocity lane underneath; layer colour, brighter when louder
    - keys: WASD move the selection, Ctrl+WASD the cursor, Ctrl+Shift+WASD jump to the next note; Q inserts at the cursor, E copies the selection after itself; Shift+A/D length, Shift+W/S invert; +/- velocity; P, R, L cycle chance, ratchet, slide
    - one finger edits, two fingers zoom and scroll; edits reach the text and the engine after 150 ms (one write per pause, light on slow phones); saving keeps comments
    - stretching: drag a note's end to change its length, or its start to move the start and keep the end; a selection stretches by the same amount. The edge follows the finger, a faint ghost shows the snapped length with the length as a number (`1/4`, `3/8`), and on release the edge springs onto the ghost (150 ms, none when motion is reduced). Each end's touch zone reaches 24 dp each side of the edge for a finger (the grab setting for a mouse); a narrow note keeps a middle for moving, and a drag from just outside a selected note's end stretches it (a tap there still draws, so step entry stays quick)
    - snap bypass: Shift, or a second finger resting on the roll during a note drag, frees the drag from the grid until it lifts; if the second finger moves first, it is a pinch after all and the edit is dropped
    - drawing: a finger down on empty grid shows where its note lands before it lifts; a drag held near the grid's edge scrolls the view; a new note takes the last length and the last velocity set (velocity lane, extras or keys)
    - hearing notes (on by default; "Hear notes" in ⋮): a note sounds while it is placed, moved, held or bent, on the layer that plays the pattern (the selected one if it does), through its effects and mix, stopped or playing, at the note's velocity. A tapped-in note plays its own length (at most 4 s); anything held stops when the finger lifts. A pitch change retriggers, a move in time doesn't; a selection sounds its first-starting notes; a pitch point being dragged sounds at its pitch; holding a note until its extras open ends its preview. A preview reopens the audio device if it was closed while idle
    - holding a note (or I, or the ⋮ menu) opens its extras: velocity, chance, ratchet 1–8 and slide, as one undo step
    - lanes: velocity (Alt+V, on) and chance with ratchet and slide marks (Alt+X); drag in a lane to set the notes starting there
    - triplets (Alt+0) make every grid size 2/3 as long
    - the ⋮ menu imports a MIDI file (.mid or MIDI 2.0 clip) in place of the notes (one undo step; its tempo isn't applied) and exports the pattern as `.mid` or `.midi2` at the project's tempo
    - Curve mode edits velocity/chance lane curves and per-note expression curves (pitch bend, pressure/volume and timbre); point and segment-bend editing is implemented, with no cap on notes or curve points (F7.1, 2026-11-04). Pattern actions include Euclid, random-in-key, arpeggiate, humanize, chord stamp, legato, reverse and pitch inversion.
- **Arranger** (`lib/ui/arranger_screen.dart`):
  - the main workspace is a horizontal timeline with a bar ruler and one lane per track (no 64-bar limit since F7.2, 2026-11-04; the ruler and grid paint only the visible span; the Builder's audition scope uses the engine's `CAW_SCOPE_AUDITION` id since F7.3); the former layer-card list has been replaced
  - track headers are compact (owner, 2026-11-09): a colour strip, the name, M, S, a live dB meter and an FX button (a dot when the track has effects); the selected or focused track glows in its own colour. A long press (right-click on desktop) opens the track menu: Effects, Record arm (with a MIDI keyboard connected, `lib/model/live_midi.dart`), Input (the connected keyboards), the instrument (`Instrument · …`: the project's .caw generators, then the C++ instruments: the engine's built-ins and the project's loaded, trusted ones; choosing one replaces the other, `LayerDoc.instrument` / `setNativeInstrument`), add a clip, rename, colour, move, folders, bus, automation lanes, spacer and delete. Long-press menus are a compact list near the finger, or a ring (Settings: `long_press_menu`); they open with a haptic tick when Haptic ticks is on
  - **focus view** (`lib/ui/arrange/focus_panel.dart`): tapping a track pins it at the top (phone portrait, about a fifth of the height, still editable) or keeps the tracks full height with a right side panel (landscape, about 40%; desktop, 34% within 320–480 dp). The panel has **FX**, **Mixer** (the track's channel strip, volume and pan), **Clip** (the selected clip's piano roll, a clip chooser, or Add clip) and **Automation** (the track's lanes). A sideways swipe on the pinned track's header or ‹ › moves to the neighbouring track; swiping the panel down, tapping the pinned track, × or Back returns to all tracks
  - **FX stack** (`lib/ui/arrange/fx_stack.dart`, `lib/model/arrange_fx.dart`): a track with a C++ instrument shows it first, as an Instrument card (knobs, bypass, reset, remove; the same card as a native effect, addressed with the engine's instrument index). Then the track's .caw effects and its native C++ effects as two labelled groups of cards with knobs (native knobs from the engine's descriptors, sent live with `caw_engine_set_component_param` and saved when the drag ends; double-tap resets). Native effects have bypass (live and saved); .caw effects don't yet. Cards reorder by handle or menu and can be removed; "+ effect" opens the effect picker. A project C++ effect that isn't loaded shows why: needs trust (a greyed card with Trust / Block, remembered), blocked, build failed (Open code), load failed or loading. Tapping a C++ or .caw effect's title opens its source in Build. A Routing toggle shows the chain as a read-only left-to-right node view
  - effects and patterns dropped from Files onto a lane or the FX stack join the chain or become a clip at the snapped drop step
  - **mixer card** (phones): the toolbar's mixer button opens a glass card of narrow strips over the tracks; tap a strip to widen it. Wide screens keep the docked mixer
  - below 760 px wide the toolbar is one row of icon buttons (add track, zoom, track height, snap, add folder, mixer, settings, track cards) that scrolls sideways, with no heading
  - track height can be set to 54, 76, 96 or 120 px from the timeline toolbar, and the same menu sets the gap between tracks (none, 3, 6, 12 or 20 px; 6 by default, saved in Settings)
  - one grid runs behind every track, through the gaps and spacers and down to the bottom of the view below the last track
  - a track's menu adds or removes a spacer below it: an empty row that only separates tracks on screen. Drag its bottom grip to resize it (8–160 px), or tap × to remove it. It is saved with the project (`space_below`) and never sent to the engine
  - clips are instances of reusable pattern sources; they can be selected, moved and resized (the drag visibly snaps to the grid, with a haptic tick; Shift moves freely), and their long-press menu edits notes, opens the sound, selects, duplicates independently or as a linked copy, loops, splits and deletes. Double-tap opens the clip's notes in the focus view's Clip tab
  - the separate Mixer panel edits the same track volume and pan values as the engine; it does not maintain duplicate mix state
  - project settings and global controls are available from the settings button rather than permanently occupying the timeline
  - folders can be nested, collapsed and moved; bus folders sum child stereo audio and apply group volume/pan, while organization-only folders simply group tracks
  - track volume/pan lanes and project-level module-parameter/global lanes are serialized separately; project lanes (any number, with any number of points; F7.1, 2026-11-04) have song-time point editing, curve previews and automation undo/redo, and the native VM evaluates parameter curves per sample
  - empty-lane drags make time selections; selected clips can be split, snapped, moved, resized or source-offset shifted with Alt-drag
  - Shift-tap selects companion clips; their notes appear as references in the existing piano roll. Explicit multi-edit mode mirrors note edits to selected independent sources while preserving local note IDs; clips sharing a pattern source stay linked
  - the playhead overlay reads the 30 Hz meter tick independently, so the moving line repaints without rebuilding the clip grid or track layout
  - a banner appears when the engine muted layers to keep audio clean, with Unmute
- **Mixer / Editor** (`lib/ui/mixer_screen.dart`):
  - Reaper-style upright channel strips in a row that scrolls sideways, the master first, on every screen size. Each track strip, top to bottom: the name, the .caw chain as slots (instrument then effects; a track with a C++ instrument and no .caw chain shows the instrument's name; a folder shows its bus switch instead), the output (master or a folder), pan, an upright fader with an upright meter, the held peak in dB, the level, M and S
  - tapping a slot opens that module's parameters in the inspector: beside the strips when the panel is 1200 px wide or more (drag the divider to resize), in a sheet otherwise
  - the level and pan values under the controls can be typed: the level in percent, the pan as C, 30L or 30R; an entry that doesn't parse is refused and changes nothing. Module parameters in the inspector can be typed the same way as in Builder
  - the master strip has its fader, upright left and right meters (dB scale, -60 to 0 dBFS) and held dB readouts; track and folder meters read what they send on, after volume and pan
  - parameter edits use the same module parameter map and engine calls as Builder; the Mixer does not own a separate state model
  - the current engine does not yet expose sends, arbitrary buses, stereo width, correlation, loudness, phase or master effect chains through this screen
- **Engine Lab** (`lib/ui/engine_lab_screen.dart`):
  - live CPU, left/right peak (held, in dB), playback and overload telemetry; each track's path shows its peak in dB
  - track signal-chain inspection from the project's generator/effect assignments, with live signal pulses driven by the existing meter tick and direct navigation to the selected module in Builder
  - a read-only 512-sample native master scope (mono sum) and a 512-point Hann-window FFT spectrum spanning 0–24 kHz; left/right peak readouts remain independent
  - compiler summaries, errors, warnings, imports and exports from the engine's module information
  - it is an inspector for existing engine capabilities, not yet an editable universal processing graph or sample/buffer debugger
- **Automation** (`lib/ui/automation_screen.dart`):
  - edits the existing track volume and pan lanes stored on each `LayerDoc`; tracks with no lanes are one row each in a single list, with + to add one
  - adds/removes lanes; tap the curve to add points, drag existing points directly, remove individual points or use precise step/value sliders
  - the same serialized points are consumed by the Arranger and native engine; plugin parameter, modulation-link and processing-behavior automation remain engine/API dependencies
- **Exporter** (`lib/ui/exporter_screen.dart`):
  - Quick Export renders the current project loop; Advanced offers loop, free-length, one-shot, wavetable and MIDI pattern exports
  - saving copies the finished file to the place picked, in chunks (`lib/platform/save_copy.dart`; Android through the system's create-document picker), so a long WAV never has to fit in memory
  - audio renders use the native offline render job, with progress and cancellation, at 44.1 or 48 kHz and 24-bit or 32-bit float
  - MIDI pattern import/export uses the native C API synchronously from the UI isolate and preserves the project tempo and time signature. These conversions are not currently routed through the native worker pool; measure large-file responsiveness before claiming they are off-thread.
  - named export profiles persist in settings; the last 20 successful exports are recorded with reproducible settings that can be reapplied
  - a sequential in-memory queue holds up to 50 snapshot jobs, supports removal/clear, runs one render at a time and can cancel the current job while preserving remaining items
  - each queued item uses the native offline renderer or MIDI writer and asks for its own destination; the queue itself is not persisted across restarts. Batch/stem rendering and multi-destination automation remain incomplete
  - the system file picker saves each completed output; unsupported formats are not offered
- **Files** (`lib/ui/file_manager_screen.dart`, `lib/ui/files/`, `lib/model/files_catalog.dart`), like Unity's Project window:
  - a folder tree (Favourites; Effects & instruments: Built-in, My C++ effects, .caw modules; Code: each C++ component's files and the .caw modules with their library folders; Audio & MIDI: patterns) beside an asset grid with type badges, a size slider (a list at the smallest), a breadcrumb, search across all folders and type filters. Below 560 dp wide the tree is a drawer. Packs are hidden until the app has packs.
  - tap selects and shows the inspector (type, place, a C++ component's build state, parameters, the tracks using it, ▶ Solo preview, Open, favourite); double-tap opens a C++ component or .caw module in Build; a long press (or right-click) opens its menu: Open, Preview, Favourite, Rename, Duplicate (a C++ copy gets a new component id), Edit tags, Export .caw, Delete (which names the tracks using it first). Folder menus add a new C++ effect (blank pass-through) or C++ instrument (blank polyphonic sine), trusted as the user's own code and opened in Build, .caw effect, module or pattern, import a .caw module, and library folders.
  - favourites are app-wide, in `files-favourites.json` next to `settings.json`
  - effects, instruments and patterns can be dragged (`AssetDrag`); "+ effect" opens the same catalogue as a half sheet (`showAssetPicker`)
  - the ⋯ menu keeps the earlier tools (`lib/ui/files/library_manager.dart`):
  - import/export portable `.cawproj` projects and `.caw` module source to user-chosen operating-system locations
  - project-local virtual folders support nested create, rename, safe delete, module moves and tags; deleting a folder moves modules to its parent rather than deleting source
  - search by module name/type/tags, saved searches, sort by name/type and flag identical module source
  - bulk-select modules and move them together between user-defined folders
  - imported projects receive a new ID so they cannot overwrite an existing saved project; imported modules are added as new items
  - validates the project format version and reports malformed or future-version files instead of opening them
  - WAV, MIDI and wavetable exports remain in Exporter
  - non-library modules can be sent directly to the existing Builder Solo preview path; audio/MIDI file preview caching remains incomplete
  - virtual folders, tags and saved searches are stored in the project; bulk move/tag and folder/tag/search operations have bounded in-session undo/redo (50 snapshots). Audio/MIDI preview caching, durable version history, dependency relinking and OS-level folder browsing remain incomplete
- **Plugin Builder** (`lib/ui/plugin_builder_screen.dart`):
  - guided creation from blank generators/effects or existing generator/effect templates; advanced workflow can select, clone, validate and package project modules
  - validates/runs through the existing engine, exposes generated parameters and packages native `.caw` source; cloning preserves the original and creates an independent project module
  - CLAP/VST3 binary targets, host sandboxing and per-plugin CPU/memory tests are not available until a native plugin SDK/host backend is integrated
- **Docking (desktop and tablets):** the workspaces are docking panels (`lib/ui/dock/`). A panel can also float in a window over the layout (⧉ on its tab strip): drag the title bar to move it, the corner to resize it, and dock it back from its title bar; floating windows are saved with the layout. Each screen shape keeps its own layout in Settings, saved shortly after a change. The Arrange preset shows the arrangement in one group and the other panels as tabs in a second: stacked in portrait, side by side otherwise. The transport's layout button offers the Arrange, Mix and Code presets and shows any panel. The keyboard area follows the panel touched last. All workspaces share the same AppState. Global shortcuts show a workspace's panel: Ctrl+1 Builder, Ctrl+2 Arranger, Ctrl+3 Exporter, Ctrl+4 Mixer, Ctrl+5 Engine Lab, Ctrl+6 Automation, Ctrl+7 Files and Ctrl+8 Plugin Builder.
- **Key:** stored with the project and sent to the engine as `key_root` and `key_scale`, so `scale`, `chord` and `arp` follow it. "None" leaves the engine's default, A minor.
- **Library and pattern modules** make no sound of their own: layers, the Exporter and Solo preview don't use them as generators.

## How it works

- **Engine access:** `lib/engine/bindings.dart` binds the C API by hand. `lib/engine/engine.dart` wraps it:
  - Project compilation, asynchronous source checks and offline WAV rendering run through the native bounded C++ worker pool. MIDI pattern import/export currently calls the native conversion API synchronously from the UI isolate; it is not routed through the pool. Project jobs are ordered by the AppState update path; native job status/progress/cancellation are exposed through owned handles. None of the worker-pool work runs on the audio callback.
  - Meters and scopes are read about 30 times a second, but only while playing and for 1 s after stopping, and never in the background (`lib/model/poller.dart`). Stopped and settled, the app does no periodic work, and after 30 s it closes the audio device; Play reopens it.
  - Slider drags and typing update only the widgets that show them, not the whole app ([performance](performance.md#app-audit-2026-10-28)).
  - Volume, pan, mute, solo and param changes go straight to the engine. Everything else re-sends the project, and the engine applies only what changed.
- **Model:** `lib/model/project.dart` holds the project.
  - Each module keeps its editor text (`source`) and the code last run (`run_source`). The engine only ever gets the code last run, so other edits never compile half-typed code.
  - The app's file format adds colours, the key, per-layer generator/effect fields, nested folder metadata, automation lanes and arrangement clip instances. The engine receives clip source references and song-time automation points.
  - The saved project model also carries C++ component entries (`CppComponentDoc`): each keeps its stable SDK component ID, project-relative file contents and exact pinned dependency versions in the project JSON. Autosave and restore points therefore retain those sources. `ProjectStorage.materializeCppComponent` recreates those files in an app-private, disposable `cpp-workspaces/<project>/<component>` directory for a local build. It validates every relative path before touching the workspace and removes a partial workspace if a write fails; the project JSON remains authoritative. The app also has a local CMake runner (`lib/platform/cpp_build.dart`): it invokes the caller-supplied CMake executable directly with an argument list (no shell), uses the installed SDK prefix, supports an optional toolchain file/Android ABI and an explicit parallel-job budget, and parses Clang/GCC/MSVC/CMake output into structured diagnostics. `CppComponentBuildService` now connects the saved project to that runner: it requires the selected component to be an entry in that project, saves the project first, materializes the selected component, and uses a stable app-private `cpp-builds/<project>/<component>` directory so CMake's cache survives rebuilds. The Linux integration test uses the repository's actual `CAWComponent.cmake` manifest helper and a local CMake/C++ compiler to build a module, edit its source and rebuild in the same directory; parser tests cover Clang/GCC, MSVC and CMake diagnostics. The helper also emits a configuration-specific artifact-path file; the service verifies the artifact exists and returns its exact path as `CppBuildResult.artifactPath` for the later explicit load step. The runner does not install/provision a compiler or SDK, and the Android-hosted compiler package remains unimplemented and unverified. The Engine C API now accepts the verified artifact path for explicit-trust loading; the Dart FFI binding now calls the Engine load/unload API on a background isolate and requires a `NativeComponentTrust` argument; native stereo effects run with their parameters on tracks (`LayerDoc.components`, after the track's chain and before volume and pan) and on the master (`ProjectDoc.masterComponents`, before the safety limiter). The local build service and FFI exist, but C++ source/build/trust controls are not yet wired into PluginBuilderScreen; `NativeTrustStore` (`lib/model/native_trust.dart`) applies the owner's trust rules:
  - sources the user wrote here (`markAuthored`) load Trusted;
  - other code asks once, and the answer is remembered for exactly that source or library fingerprint (SHA-256, `lib/model/sha256.dart`), so changed code asks again;
  - `forget` resets a choice;
  - trust is never stored in a project.
The in-app build and toolchain install exist (see the C++ platform note). When a project opens, `NativeComponentManager` (`lib/model/native_components.dart`) handles its C++ components in the background, so the project plays at once:
  - Each component's trust decision comes first: own code is Trusted, blocked code never builds, and other code waits in `AppState.nativeStatus.needsTrust`.
  - A trusted component builds in-app, or reuses its cached build while the sources are unchanged.
  - The build then loads, or reloads if the component was already loaded from other sources.
  - The project is sent again. Components that aren't loaded are left out of what the engine gets (`toEngineJson(playableComponents:)`), and their automation lanes are renumbered, so the rest of the song plays.
`CppComponentDoc.blankEffect` makes a new effect from the one blank template (owner, 2026-11-09). It is a stereo pass-through with its manifest, checked to build warning-free with the bundle. `CppComponentDoc.blankInstrument` makes a new instrument: a polyphonic sine on `caw::InstrumentProcessor` (#156; checked to compile against the SDK headers with GCC, not yet with the bundled Clang on a phone). A track's C++ instrument is `LayerDoc.instrument`; `toEngineJson` sends it only while it is playable under the trust rules (built-ins always), with its `instrument` lanes; one that is waiting leaves the track silent. Piano-roll previews and MIDI keyboards play it through `caw_engine_note_on`. Still to come: the trust prompt UI, and any screen that places components on tracks.
- **Storage:** projects are JSON files in the app's private support folder, under `projects/`. They're written 0.5 s after each change, and right away when the app goes to the background or quits. The app reopens the last project.
- **Audio:** the device opens at start-up (48 kHz stereo, low-latency profile). When the app goes to the background while stopped, it closes the device, and it reopens it on return. Playing on in the background (an Android foreground service) is not in v1.
- **Opening:** the app opens straight into the last project (`AppState.openStorage`) with the arrangement in front (the shell brings it forward once at launch, whatever the saved layout showed), or the "First loop" template on a first run or when the last project is gone. If the last project's file is damaged, or opening it fails, the template opens and a pink line under the transport says why; the damaged file stays in the projects folder. There is no startup screen. The project menu offers a new blank project, a new one from the template, and every saved project.
  - "First loop" (`AppState.starterProject`) is made only of the engine's built-in C++ instruments, each playing its own pattern in a clip over the 4-bar loop at 140 BPM: Kick (four on the floor), Hats (16ths, open on the off-beat), Bass (an A minor 16th line), Lead (the morph synth playing a 2-bar hook into the ping-pong delay), and, muted, Acid (the acid synth playing the Acid line through the distortion) and Pad (the morph synth playing Chords through the chorus). Its patterns are written in the app, so it doesn't depend on the .caw templates; projects saved from the earlier .caw First loop are not converted.
- **Settings** (`lib/model/settings.dart`, `lib/ui/theme_editor.dart`): saved as `settings.json` next to `projects/`. Density is compact by default. The page opens with the open-beta version (`lib/version.dart`, 0.9.0-beta.1, equal to `pubspec.yaml`) and **Report a problem**, which copies a plain report (version, platform, the last 20 uncaught errors kept on the device by `ProblemLog`) to paste into a GitHub issue; the app sends nothing itself.
  - **Theme**, with a theme editor: each colour can be set with hue, saturation and brightness sliders or as hex, with a live preview and a glow switch. Themes can be saved, duplicated, imported and exported.
    - The built-in themes are Calm neon (the default), Night (dimmer, no glow) and Amber terminal.
    - Each theme has eight track colours (`layer1`–`layer8`), and new tracks cycle through all eight. A theme file without the newer slots takes them from Calm neon.
    - Custom themes are `kind: theme` text files in `themes/`.
  - **Density:** comfortable or compact.
  - **Motion and feel** (`lib/ui/motion.dart`):
    - **Motion:** Full, Reduced (fades only) or Off. The Minimal profile turns it off, and the system's reduce-motion setting caps it at Reduced.
    - **Haptic ticks:** on by default.
    - **Glass** (`lib/ui/glass.dart`): on by default; glass off, or the Minimal profile, brings back the solid look. **Frosted blur** (on by default) blurs behind sheets and overlays; off, or the Lightweight profile, keeps the glass look with a denser tint and no blur, which costs far less.
      - A soft ambient background (faint glows of the accent colours) sits behind every screen, and the docked panels, cards, track headers and transport are see-through over it, with no blur.
      - Bottom sheets slide up as frosted glass (a real blur); dialogs and menus are translucent with a bright edge.
      - Sliders, level bars, switches, filled and segmented buttons, M/S toggles and clips have a light see-through fill and a thin solid outline. Slider knobs are opaque (their colour mixed into the panel), so the track doesn't show through them.
      - Pushed pages (Settings, the theme editor, the full-screen roll) have their own glass background, so the page below doesn't show through while they slide in.
    - **Music-reactive glow:** a 0–100% slider, 35% by default.
    - The slider shows a change while it is dragged and saves when the drag ends.
    - The motion rules (distance-aware settle times, a small overshoot, snapping maths) are in place, but no screen animates with them yet. The [UI plan](ui-plan.md) adds that step by step.
  - **Shared building blocks for the redesign:**
    - `lib/ui/tokens.dart`: spacing, radii, type sizes, touch targets (48 dp, or 36 dp compact) and colours by role (accent, selection, warning, danger, automation, track).
    - `lib/ui/kit.dart`: the context-aware toolbar row (fixed tools, a middle part that slides and fades when its context changes, ⋮), tool buttons and the ⓘ info button.
    - The existing screens don't use them yet.
  - **Docking layout model** (`lib/ui/dock/layout.dart`):
    - The model is a tree of splits and tab groups holding panels by string id.
    - Edits are dock (into a group, or split off on any edge), remove, reveal and activate. Split shares keep a 12% minimum, after every edit and load; ids are checked and deduplicated on any tree.
    - Presets: Arrange, Mix and Code, for phone portrait, phone landscape and desktop.
    - The JSON form drops unknown or repeated panels and damaged parts.
    - The view (`lib/ui/dock/dock_view.dart`) draws it in the shell: draggable dividers (a narrow grab zone, so scrolls near a panel's edge still reach the panel), glass tab strips, a long-press drag of a tab onto one of five drop zones, and maximise. A panel keeps its state when it moves or is maximised, and hidden tabs keep theirs with tickers off. Each panel's size stands in for the screen's, so a screen lays out for its panel.
  - **Performance profiles:** Full Experience (full glow), Balanced (55% glow), Lightweight (no glow, 4 voices per pattern layer) and Minimal (Lightweight plus hidden scope panels). All profiles keep meter polling at 30 Hz; Minimal does not slow down editing or meters.
    - Existing `light_mode` settings migrate to Lightweight/ Balanced; the legacy key is still written for older builds.
    - Automatic overload response selects Lightweight once, unless disabled.
    - Lightweight/Minimal retain the existing behavior of pausing auto-update while playback is running.
  - **Live coding:** auto-update (on by default) runs code that compiles the set pause (100–2000 ms) after the last edit. Code with an error waits for the next edit. Swaps land at the swap timing: now, the next beat or the next bar.
  - **Vim keys in the code editor:** off by default.
- **Keys** (`lib/ui/key_router.dart`): with a keyboard, every key goes through the action system in [actions](actions.md): per-area keymaps, Vim modes, counts, `:` commands, `.` and macros.
  - A badge at the bottom right shows the mode, a recording macro, pending keys, key hints and short toasts.
  - `?` opens the action list: search, keys and run. Its **Edit keys**, Settings → Key bindings, or the `view.keys` action open the key bindings editor (`lib/ui/key_bindings.dart`): press or type a key for any action, see what it would replace or clash with, remove keys, reset one action or all.
  - Recorded macros are saved in `keys.txt` next to `settings.json`; a user `keys.txt` is merged over the default keys.
  - Text fields keep plain typing and their own Ctrl+Z/Y/A/C/V/X. Backspace, Delete, arrows, Home/End, Enter and Tab in a focused text field go to the field even in the code editor's Vim normal mode (`shouldDeferTextEditingKey`). The project seed field keeps what is typed until Enter and re-syncs only when the project's seed changes.
  - The roll, the Builder and the code editor's Vim mode each run their area's actions; the Arranger's actions work on a keyboard-selected layer.
  - **Not built yet:** keymap-driven long-press menu entries, and binding macros from the editor (macros are bound in `keys.txt`). The piano-roll toolbar and phone Quick Actions strips are configurable.
- **Fonts:** the UI uses the system font. Code and numbers use the bundled JetBrains Mono (Regular and Bold, about 550 KB), whose licence (SIL OFL 1.1) is shown in the app's licence page.

## Build

- **Flutter:** 3.47.7, pinned in `.github/workflows/app.yml`.
- **Dependencies, all permissive:**
  - `ffi` 2.2.0 (BSD-3-Clause)
  - `path_provider` 2.1.6 (BSD-3-Clause)
  - `file_picker` 13.1.0 (MIT)
  - `re_editor` 0.10.0 and `re_highlight` 0.0.3 (MIT), with `isolate_manager` 4.1.5+1 (MIT): the C++ Builder's editor
  - JetBrains Mono 2.304 (SIL Open Font License 1.1), the font files in `assets/fonts/` with `OFL.txt`
- **Android:** `android/app/build.gradle.kts` builds `engine/CMakeLists.txt` into `libcaw.so` for arm64-v8a only (the phones C.A.W targets; CI builds the APK with `--target-platform android-arm64`), with `minSdk` 26. When CI supplies `CAW_COMPILER_PACKAGE`, the on-device compiler library and its data bundle are packed in too, and `CAW_CCACHE` reuses compiled engine files.
  - The application id is `com.kmandevr.caw`. It becomes permanent once a release is installed, because updates only install over the same id and key.
- **Windows and Linux:** `windows/CMakeLists.txt` and `linux/CMakeLists.txt` add the engine and bundle `caw.dll` or `libcaw.so` next to the app. The Linux folder is for local testing; it isn't shipped in v1.
- **CI** (`.github/workflows/app.yml`) runs on changes to `app/`, `engine/` or `examples/`, or on demand. Pushes to `gpt/**` branches skip it until they open a pull request; their Dart analysis and tests run in the Quick check (`README.md`). It runs:
  - `flutter analyze` and `flutter test` against a Linux build of the engine
  - the release APK, as artifact `caw-android-apk`
  - the Windows app folder, as artifact `caw-windows`. Run `caw.exe` from it.
- **Android signing:** the repository secrets `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD` give every build the same key, so each APK installs over the last. Without them, CI signs with a throwaway debug key, and each new APK needs the old one uninstalled first.

## Tests

`flutter test`:
- model round-trips and the engine JSON
- highlighting, editor helpers and completion
- the pattern model (`lib/model/pattern_doc.dart`): exact step fractions, parsing with the engine's errors, comment-keeping write-back and every note edit
- the actions core (`lib/actions/`): keymap files, conflicts, macros with their recursion guard, counts, `:` commands, `.` repeat and recording
- settings, theme files, and opening into the last project or the template (`test/opening_test.dart`)
- the motion rules and the motion, haptics and glow settings (`test/motion_test.dart`), the Glass setting and surfaces (`test/glass_test.dart`), and the docking model, view and shell (`test/dock_layout_test.dart`, `test/dock_view_test.dart`, `test/dock_shell_test.dart`: every panel at the three sizes without overflow, with goldens)
- golden (screenshot) tests, which compare a screen with a PNG in `test/goldens/`:
  - `test/golden_util.dart` loads real fonts (the bundled JetBrains Mono, and the Roboto and Material icons from the Flutter SDK), so layouts measure as they do on a phone. It pumps screens at the plan's sizes: phone 390×844, landscape 844×390, desktop 1280×800.
  - After an intended visual change, run `flutter test --update-goldens` and review the new PNGs.
  - CI renders them on Ubuntu with the pinned Flutter (`app.yml`). After a Flutter upgrade, re-run `flutter test --update-goldens` and check the new PNGs.
- integration tests through `dart:ffi`: templates, checks, a project sync, a loop export, and the function library with a project library module. It runs when `CAW_LIB` points at a built engine library; CI sets it.
