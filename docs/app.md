---
title: App
summary: The built Flutter app: eight workspaces, shared engine state, portable files, performance profiles, storage and CI.
covers: [app/]
updated: 2026-11-01
---

# App

The Flutter app in `app/`. The engine it drives is described in [engine](engine.md), and v1's scope is in [roadmap](roadmap.md). Everything here is **[Fact]**, checked in the code and by its tests.

## Engine integration

The app calls the shared native engine only through the versioned C API in `lib/engine/bindings.dart`. Project compilation, asynchronous source checks and offline WAV renders are submitted as native jobs to the bounded C++ `AdaptiveWorkerPool`; the app owns opaque job handles and polls status/progress, reads the result/error and releases each handle. Project submissions retain the engine handle until completion, so disposing an engine waits for its accepted project jobs rather than invalidating a worker pointer. Inputs are copied before the FFI call returns. No Dart callback is invoked from a native worker thread, and no job runs on the audio callback. `lib/engine/execution.dart` binds the native hardware-profile probe, workload planner and job API. Jobs carry foreground/offline priorities; the app starts the pool with an interactive-preview budget so a foreground job can run alongside a single offline export, and the host can apply updated workload/pressure plans through the same native policy API.

Settings shows the detected logical cores, conservative work-memory budget, SIMD capability, GPU-compute capability and the interactive workload plan. On Android, the host reads `PowerManager` thermal status (Android 10+) and battery-saver state, then listens for thermal and power-save changes without polling. Foreground/background and audio-playing transitions also refresh the active worker budget. Unsupported platforms remain explicitly `Unknown` rather than assuming normal pressure; background/offline work reserves one host core where possible, and GPU work is disabled while pressure is unknown. The current engine reports GPU compute unavailable. Native project/check/render jobs now use the C++ pool; generation and analysis jobs remain future integration work.

## Areas

- **Top bar:**
  - the crow mark
  - the project name, which opens the project menu: rename, new blank project, new from a template, duplicate, open, delete and **Settings…**
  - BPM, beat and CPU readouts
  - Play/Stop (the space bar on desktop)
- **Builder** (`lib/ui/builder_screen.dart`):
  - a row of module chips (generators green, effects pink, libraries blue, patterns yellow)
  - a compact active-track panel shared with the Mixer for track selection, volume, pan, mute and solo
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
    - a double-tap on a value resets it
    - a "Shares" line naming the module's exports (`kick.env`), and warnings in yellow
    - for a library module, the functions other modules can call
  - **Run** (Ctrl+Enter) sends the code and hot-swaps it. Code that fails keeps the old sound and puts the cursor on the error
  - **Solo preview** plays only this module. An effect is heard through the generator of a layer that uses it, or the project's first generator. A generator plays the pattern of a layer that uses it, and a pattern plays through the sound of a layer that plays it (or the first generator)
  - a pattern opens in the piano roll (`app/lib/ui/pattern_editor.dart`), with a **Text** button for its source; its panel says how many notes it has and which layers play it
    - tools: draw (B), select (V), erase (X); undo/redo; grid resolution 1 to 1/128 (Alt+1..8); snap (N); fixed grid (Alt+F); drum grid (G); full screen
    - the grid adapts to zoom, down to the resolution; rows in the project's key are lit; velocity lane underneath; layer colour, brighter when louder
    - keys: WASD move the selection, Ctrl+WASD the cursor, Ctrl+Shift+WASD jump to the next note; Q inserts at the cursor, E copies the selection after itself; Shift+A/D length, Shift+W/S invert; +/- velocity; P, R, L cycle chance, ratchet, slide
    - one finger edits, two fingers zoom and scroll; edits reach the text and the engine after 150 ms (one write per pause, light on slow phones); saving keeps comments
    - holding a note (or I, or the ⋮ menu) opens its extras: velocity, chance, ratchet 1–8 and slide, as one undo step
    - lanes: velocity (Alt+V, on) and chance with ratchet and slide marks (Alt+X); drag in a lane to set the notes starting there
    - triplets (Alt+0) make every grid size 2/3 as long
    - the ⋮ menu imports a MIDI file (.mid or MIDI 2.0 clip) in place of the notes (one undo step; its tempo isn't applied) and exports the pattern as `.mid` or `.midi2` at the project's tempo
    - Curve mode edits velocity/chance lane curves and per-note expression curves (pitch bend, pressure/volume and timbre); point and segment-bend editing is implemented. Pattern actions include Euclid, random-in-key, arpeggiate, humanize, chord stamp, legato, reverse and pitch inversion.
- **Arranger** (`lib/ui/arranger_screen.dart`):
  - the main workspace is a horizontal timeline with a bar ruler and one lane per track; the former layer-card list has been replaced
  - tracks have a generator selector, mute/solo controls and a menu for adding MIDI clips from existing pattern modules
  - track height can be set to 54, 76, 96 or 120 px from the timeline toolbar
  - clips are instances of reusable pattern sources; they can be selected, moved, resized, duplicated independently or as linked copies, deleted, and opened in the existing Builder piano roll
  - the separate Mixer panel edits the same track volume and pan values as the engine; it does not maintain duplicate mix state
  - project settings and global controls are available from the settings button rather than permanently occupying the timeline
  - folders can be nested, collapsed and moved; bus folders sum child stereo audio and apply group volume/pan, while organization-only folders simply group tracks
  - volume and pan automation lanes are serialized and played by the native engine; the callback interpolates their points at song position
  - empty-lane drags make time selections; selected clips can be split, snapped, moved, resized or source-offset shifted with Alt-drag
  - Shift-tap selects companion clips; their notes appear as references in the existing piano roll. Explicit multi-edit mode mirrors note edits to selected independent sources while preserving local note IDs; clips sharing a pattern source stay linked
  - the playhead overlay reads the 30 Hz meter tick independently, so the moving line repaints without rebuilding the clip grid or track layout
  - a banner appears when the engine muted layers to keep audio clean, with Unmute
- **Mixer / Editor** (`lib/ui/mixer_screen.dart`):
  - a dedicated channel-strip workspace with shared track volume, pan, mute and solo controls
  - channel strips expose existing generator/effect chains, folder-bus enablement and track-to-folder routing
  - master output level with independent live left/right peak meters and an inspector for the selected compiled module's real engine parameters
  - desktop widths above 1200 px show channels and the module inspector side-by-side; drag the divider to resize. Mobile starts with a compact channel list and switches to a focused editor for the selected channel and module inspector
  - parameter edits use the same module parameter map and engine calls as Builder; the Mixer does not own a separate state model
  - the current engine does not yet expose sends, arbitrary buses, stereo width, correlation, loudness, phase or master effect chains through this screen
- **Engine Lab** (`lib/ui/engine_lab_screen.dart`):
  - live CPU, left/right peak, playback and overload telemetry
  - track signal-chain inspection from the project's generator/effect assignments, with live signal pulses driven by the existing meter tick and direct navigation to the selected module in Builder
  - a read-only 512-sample native master scope (mono sum) and a 512-point Hann-window FFT spectrum spanning 0–24 kHz; left/right peak readouts remain independent
  - compiler summaries, errors, warnings, imports and exports from the engine's module information
  - it is an inspector for existing engine capabilities, not yet an editable universal processing graph or sample/buffer debugger
- **Automation** (`lib/ui/automation_screen.dart`):
  - edits the existing track volume and pan lanes stored on each `LayerDoc`
  - adds/removes lanes; tap the curve to add points, drag existing points directly, remove individual points or use precise step/value sliders
  - the same serialized points are consumed by the Arranger and native engine; plugin parameter, modulation-link and processing-behavior automation remain engine/API dependencies
- **Exporter** (`lib/ui/exporter_screen.dart`):
  - Quick Export renders the current project loop; Advanced offers loop, free-length, one-shot, wavetable and MIDI pattern exports
  - audio renders use the native offline render job, with progress and cancellation, at 44.1 or 48 kHz and 24-bit or 32-bit float
  - MIDI patterns use the native MIDI writer in a worker isolate and preserve the project tempo and time signature
  - named export profiles persist in settings; the last 20 successful exports are recorded with reproducible settings that can be reapplied
  - a sequential in-memory queue holds up to 50 snapshot jobs, supports removal/clear, runs one render at a time and can cancel the current job while preserving remaining items
  - each queued item uses the native offline renderer or MIDI writer and asks for its own destination; the queue itself is not persisted across restarts. Batch/stem rendering and multi-destination automation remain incomplete
  - the system file picker saves each completed output; unsupported formats are not offered
- **Files** (`lib/ui/file_manager_screen.dart`):
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
- **Layout:** phones get a bottom navigation bar. Screens at least 900 px wide get a side rail; phones use a four-item bottom bar (Builder, Arranger, Mixer, More); More opens Engine Lab, Automation, Exporter, Files and Plugin Builder. Desktop uses a navigation rail for all eight destinations. All workspaces share the same AppState. Global shortcuts navigate all workspaces: Ctrl+1 Builder, Ctrl+2 Arranger, Ctrl+3 Exporter, Ctrl+4 Mixer, Ctrl+5 Engine Lab, Ctrl+6 Automation, Ctrl+7 Files and Ctrl+8 Plugin Builder.
- **Key:** stored with the project and sent to the engine as `key_root` and `key_scale`, so `scale`, `chord` and `arp` follow it. "None" leaves the engine's default, A minor.
- **Library and pattern modules** make no sound of their own: layers, the Exporter and Solo preview don't use them as generators.

## How it works

- **Engine access:** `lib/engine/bindings.dart` binds the C API by hand. `lib/engine/engine.dart` wraps it:
  - Project updates and exports run on worker isolates, so compiling never blocks the UI. Updates run one at a time, in order.
  - Meters and scopes are read about 30 times a second, but only while playing and for 1 s after stopping, and never in the background (`lib/model/poller.dart`). Stopped and settled, the app does no periodic work, and after 30 s it closes the audio device; Play reopens it.
  - Slider drags and typing update only the widgets that show them, not the whole app ([performance](performance.md#app-audit-2026-10-28)).
  - Volume, pan, mute, solo and param changes go straight to the engine. Everything else re-sends the project, and the engine applies only what changed.
- **Model:** `lib/model/project.dart` holds the project.
  - Each module keeps its editor text (`source`) and the code last run (`run_source`). The engine only ever gets the code last run, so other edits never compile half-typed code.
  - The app's file format adds colours, the key, per-layer generator/effect fields, nested folder metadata, automation lanes and arrangement clip instances. The engine receives clip source references and song-time automation points.
- **Storage:** projects are JSON files in the app's private support folder, under `projects/`. They're written 0.5 s after each change, and right away when the app goes to the background or quits. The app reopens the last project.
- **Audio:** the device opens at start-up (48 kHz stereo, low-latency profile). When the app goes to the background while stopped, it closes the device, and it reopens it on return. Playing on in the background (an Android foreground service) is not in v1.
- **Startup screen** (`lib/ui/startup_screen.dart`): continue the last project, start a new blank project, start from the "First loop" template, or open another saved project.
  - It works from the keyboard: the first choice has focus, and Tab and Enter move and pick.
  - "First loop" has Kick, Bass and Hats layers of 1 bar each and a 3-bar Byte lead with Bitcrush over a 4-bar loop at 140 BPM, plus a muted Acid layer that plays the Acid synth from the Acid line pattern.
- **Settings** (`lib/model/settings.dart`, `lib/ui/theme_editor.dart`): saved as `settings.json` next to `projects/`.
  - **Theme**, with a theme editor: each colour can be set with hue, saturation and brightness sliders or as hex, with a live preview and a glow switch. Themes can be saved, duplicated, imported and exported.
    - The built-in themes are Calm neon (the default), Night (dimmer, no glow) and Amber terminal.
    - Custom themes are `kind: theme` text files in `themes/`.
  - **Density:** comfortable or compact.
  - **Performance profiles:** Full Experience (full glow), Balanced (55% glow), Lightweight (no glow, 4 voices per pattern layer) and Minimal (Lightweight plus hidden scope panels). All profiles keep meter polling at 30 Hz; Minimal does not slow down editing or meters.
    - Existing `light_mode` settings migrate to Lightweight/ Balanced; the legacy key is still written for older builds.
    - Automatic overload response selects Lightweight once, unless disabled.
    - Lightweight/Minimal retain the existing behavior of pausing auto-update while playback is running.
  - **Live coding:** auto-update (on by default) runs code that compiles the set pause (100–2000 ms) after the last edit. Code with an error waits for the next edit. Swaps land at the swap timing: now, the next beat or the next bar.
  - **Vim keys in the code editor:** off by default.
- **Keys** (`lib/ui/key_router.dart`): with a keyboard, every key goes through the action system in [actions](actions.md): per-area keymaps, Vim modes, counts, `:` commands, `.` and macros.
  - A badge at the bottom right shows the mode, a recording macro, pending keys, key hints and short toasts.
  - `?` opens the action list: search, keys and run.
  - Recorded macros are saved in `keys.txt` next to `settings.json`; a user `keys.txt` is merged over the default keys.
  - Text fields keep plain typing and their own Ctrl+Z/Y/A/C/V/X.
  - The roll, the Builder and the code editor's Vim mode each run their area's actions; the Arranger's actions work on a keyboard-selected layer.
  - **Not built yet:** editing key bindings directly in the action list and keymap-driven long-press menu entries. The piano-roll toolbar and phone Quick Actions strips are configurable.
- **Fonts:** the UI uses the system font. Code and numbers use the bundled JetBrains Mono (Regular and Bold, about 550 KB), whose licence (SIL OFL 1.1) is shown in the app's licence page.

## Build

- **Flutter:** 3.47.7, pinned in `.github/workflows/app.yml`.
- **Dependencies, all permissive:**
  - `ffi` 2.2.0 (BSD-3-Clause)
  - `path_provider` 2.1.6 (BSD-3-Clause)
  - `file_picker` 13.1.0 (MIT)
  - JetBrains Mono 2.304 (SIL Open Font License 1.1), the font files in `assets/fonts/` with `OFL.txt`
- **Android:** `android/app/build.gradle.kts` builds `engine/CMakeLists.txt` into `libcaw.so` for arm64-v8a and x86_64, with `minSdk` 26.
  - The application id is `com.kmandevr.caw`. It becomes permanent once a release is installed, because updates only install over the same id and key.
- **Windows and Linux:** `windows/CMakeLists.txt` and `linux/CMakeLists.txt` add the engine and bundle `caw.dll` or `libcaw.so` next to the app. The Linux folder is for local testing; it isn't shipped in v1.
- **CI** (`.github/workflows/app.yml`) runs on changes to `app/`, `engine/` or `examples/`, or on demand:
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
- settings, theme files and the startup choices
- integration tests through `dart:ffi`: templates, checks, a project sync, a loop export, and the function library with a project library module. It runs when `CAW_LIB` points at a built engine library; CI sets it.
