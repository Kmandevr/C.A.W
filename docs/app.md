---
title: App
summary: The built Flutter app: its three areas (Sounds, Tracks, Export), how it talks to the engine, where projects are saved, and how CI builds and signs it.
covers: [app/]
updated: 2026-10-30
---

# App

The Flutter app in `app/`. The engine it drives is described in [engine](engine.md), and v1's scope is in [roadmap](roadmap.md). Everything here is **[Fact]**, checked in the code and by its tests.

## Areas

- **Top bar:**
  - the crow mark
  - the project name, which opens the project menu: rename, new blank project, new from a template, duplicate, open, delete and **Settings…**
  - BPM, beat and CPU readouts
  - Play/Stop (the space bar on desktop)
- **Sounds** (the Builder area, `lib/ui/builder_screen.dart`):
  - a row of module chips (generators green, effects pink, libraries blue, patterns yellow)
  - **New:** a blank Sound, Effect, Pattern or Library first, then the templates (including the Acid synth, the Wavetable pad, the Init synth patch and the Acid line and Chords patterns)
  - a **synth patch** (`kind: synth`, [synth](synth.md)) plays wherever a sound can: its Controls panel lists every value in the patch (the effects' under Effects) and its Code view is the patch text. The Modulation links panel adds, edits and removes supported source-to-destination routes with signed depth/polarity.
    - A blank module is a truly empty file. A faint hint shows an example header for the chosen kind until you type.
    - The chosen kind isn't saved, so after a restart an empty file shows the Sound hint. With no header the engine plays it as a bytebeat.
  - **Controls | Code** (a pattern: **Notes | Text**): on a phone a module opens on its controls (a pattern on its piano roll), and the code is one tap away. A blank module, one that doesn't compile, or one with no controls opens on its code; the choice is remembered per module while the app runs. A tap on an error opens the code at it. On a wide screen code and controls sit side by side, so only patterns get the switch.
  - On phone layouts, Sounds, Tracks and Export show a customizable Quick Actions strip. Buttons invoke actions directly; use the tune button to add, remove, reorder or restore actions and macros. Choices are saved in `keys.txt`. Vim modes and command controls are for an attached physical keyboard, not a touchscreen keyboard.
  - In the piano-roll toolbar, selecting notes reveals on-screen Copy and Paste controls. Dragging any selected note moves the whole selection together; a multi-note drag does not resize notes.
  - the headphones button is **Solo preview** (below)
  - a code editor with highlighting and the symbol key row
  - **completion chips** above the key row: typing two or more letters (set in Settings) offers matching functions and constants (`adsr` finds `env.adsr`), and a tap types the call with its arguments selected to type over
  - **Library** (the book button, or F1): every function from the engine's `caw_library()` plus the project's own library modules, grouped by category and searchable from the word at the cursor. Each shows its signature, description, arguments and example, with **Insert call** and **Insert example**
  - a one-line status: the error (tap it to jump to the spot), "edited, tap Run", or the module's summary
  - a scope, and a Controls panel built from the module's `param`s and `global`s:
    - sliders (with steps), toggles, and dropdowns (buttons when there are 4 or fewer choices)
    - grouped under `// --- Headers ---`; tapping a header folds its group while the app runs; tips and doc comments on long-press or hover
    - a double-tap on a value resets it
    - a "Shares" line naming the module's exports (`kick.env`), and warnings in yellow
    - for a library module, the functions other modules can call
  - **Run** (Ctrl+Enter) sends the code and hot-swaps it. Code that fails keeps the old sound and puts the cursor on the error
  - **Solo preview** plays only this module. An effect is heard through the generator of a layer that uses it, or the project's first generator. A generator plays the pattern of a layer that uses it, and a pattern plays through the sound of a layer that plays it (or the first generator)
  - a pattern opens in the piano roll (`app/lib/ui/pattern_editor.dart`), with **Text** (the switch) for its source; its panel says how many notes it has and which layers play it
    - tools: draw (B), select (V), erase (X); undo/redo; grid resolution 1 to 1/128 (Alt+1..8); snap (N); fixed grid (Alt+F); drum grid (G); full screen
    - the grid adapts to zoom, down to the resolution; rows in the project's key are lit; velocity lane underneath; layer colour, brighter when louder
    - keys: WASD move the selection, Ctrl+WASD the cursor, Ctrl+Shift+WASD jump to the next note; Q inserts at the cursor, E copies the selection after itself; Shift+A/D length, Shift+W/S invert; +/- velocity; P, R, L cycle chance, ratchet, slide
    - one finger on a note, in a lane or with the select tool edits (a drag on a note moves it, near its end resizes it); on empty grid a tap draws (or erases) and a drag scrolls (Settings can make it select or draw instead); a **double tap on a note deletes it** (owner, 2026-10-28); two fingers zoom and scroll, and the wheel scrolls. The roll claims its touches, so it works the same inside Sounds as full screen. Edits reach the text and the engine after 150 ms (one write per pause, light on slow phones); saving keeps comments
    - holding a note (or I, or the ⋮ menu) opens its extras: velocity, chance, ratchet 1–8 and slide, as one undo step
    - lanes: velocity (Alt+V, on) and chance with ratchet and slide marks (Alt+X); drag in a lane to set the notes starting there
    - triplets (Alt+0) make every grid size 2/3 as long
    - the ⋮ menu imports a MIDI file (.mid or MIDI 2.0 clip) in place of the notes (one undo step; its tempo isn't applied) and exports the pattern as `.mid` or `.midi2` at the project's tempo
    - generators, from the ⋮ menu or a toolbar button, each one undo step: Euclid (hits, steps and rotation at the grid size, from the cursor), Random in key (density, range around the cursor, bars), Arpeggiate (each selected chord becomes a run at the grid size: up, down, up and down), Humanize (timing and velocity nudges), Chord stamp (3rd and 5th, or a seventh, in the project's key), Legato, Reverse and Invert pitch around the cursor. The last values are kept while the app runs
    - the toolbar is the keymap's pattern toolbar: ⋮ → Customise toolbar adds any action or macro, reorders, removes or goes back to the default, saved in `keys.txt`. Full screen and ⋮ always stay
    - **Curve tool** (C): over the velocity and chance lanes, tap to add a point, drag a point to move it, drag a segment to bend it (up eases in, down eases out), hold a point to delete it. The curve sets the selected notes, or every note when none is selected, between its first and last points; each gesture is one undo step. On the grid a tap picks or unpicks a note and a drag scrolls. The curves themselves are kept only while the roll is open (`app/lib/model/lane_curve.dart`)
    - **Note expression** (MPE style; owner, 2026-10-29), saved as the note's `bend`, `vib`, `press` and `timbre` extras ([engine](engine.md#patterns)):
      - a note with a bend or vibrato draws as a line following its pitch over time (MIDI Sketch style), its row faint behind it
      - with the Curve tool, a tap on a note selects it; then on that note a tap adds a pitch point, a drag moves one, a drag on the line bends that segment, and holding a point deletes it. Values snap to semitones (Shift or snap off: free), within ±12
      - the extras panel (hold a note, I, or ⋮ → Note extras) adds presets (scoop up, fall off, bend up 2, dive, vibrato, trill, swell, fade, clear), vibrato depth, rate and fade-in, and small editors for the pitch, volume and timbre curves; curve points snap in time to the piano-roll grid when snap is on, remain within the note, and the whole visit is one undo step
      - exported `.mid` files carry it as MPE (`app/lib/ui/note_expression.dart`)
    - not built yet: automation lanes for params and globals ([#11](https://github.com/Kmandevr/C.A.W/issues/11))
- **Tracks** (the Arranger area, `lib/ui/arranger_screen.dart`; a track is a layer):
  - a **project strip**: big BPM, time signature, loop length and key pills, and the master meter. A tap opens the project sheet: BPM with −/+ and tap, time signature 2/4 to 7/4, loop length of 1–16 bars, key, master volume, and under **More** the hex seed and the seam crossfade switch. **Project controls** (one per `global` declared by any module, saved with the project and sent to the engine without recompiling) are in the same sheet.
  - a **card per track**: its colour, name, sound (when the name doesn't already say it), pattern, cycle length and effect count, M and S, a peak meter, and a lane picturing one cycle: the pattern's notes, or a block per bar for a sound with no pattern, with the playhead while playing
  - a tap on a card opens the **track panel**: colour, rename, move and delete; **Sound** (pick one, with that sound's sliders right there); **Notes** (none or a pattern, and the length when there's no pattern); **Effects** (tap one to edit it, × to remove, + to add); **Mix** (volume, pan). **Edit** opens the sound or pattern in Sounds.
  - **Add track** (the last card) starts from a sound in the project, a new sound from a template, or an empty track
  - a banner when the engine muted tracks to keep audio clean, with Unmute
- **Export** (the Exporter area, `lib/ui/exporter_screen.dart`):
  - the four exports from [engine](engine.md#exports), at 44.1 or 48 kHz, 24-bit or 32-bit float
  - progress and cancel while it renders
  - then the system file picker saves the file
- **Layout:** phones get a bottom navigation bar (Sounds, Tracks, Export; Tracks opens first). Screens at least 900 px wide get a side rail, and Sounds shows code and controls side by side. Ctrl+1/2/3 switch areas. The code, keymaps and actions still name the areas `builder`, `arranger` and `exporter`.
- **Key:** stored with the project and sent to the engine as `key_root` and `key_scale`, so `scale`, `chord` and `arp` follow it. "None" leaves the engine's default, A minor.
- **Library and pattern modules** make no sound of their own: tracks, Export and Solo preview don't use them as generators.

## How it works

- **Engine access:** `lib/engine/bindings.dart` binds the C API by hand. `lib/engine/engine.dart` wraps it:
  - Project updates and exports run on worker isolates, so compiling never blocks the UI. Updates run one at a time, in order.
  - Meters and scopes are read about 30 times a second, but only while playing and for 1 s after stopping, and never in the background (`lib/model/poller.dart`). Stopped and settled, the app does no periodic work, and after 30 s it closes the audio device; Play reopens it.
  - Slider drags and typing update only the widgets that show them, not the whole app ([performance](performance.md#app-audit-2026-10-28)).
  - Volume, pan, mute, solo and param changes go straight to the engine. Everything else re-sends the project, and the engine applies only what changed.
- **Model:** `lib/model/project.dart` holds the project.
  - Each module keeps its editor text (`source`) and the code last run (`run_source`). The engine only ever gets the code last run, so other edits never compile half-typed code.
  - The app's file format adds colours, the key and per-layer generator and effect fields to the engine's project JSON.
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
  - **Light mode** for slow devices (owner OK, 2026-10-28). It:
    - turns glow and the Builder's scope off
    - reads meters 15 times a second instead of 30
    - caps every pattern layer at 4 voices (the project's `voices`; otherwise each sound plays its own count, 8 by default)
    - stops auto-update while playing
    - Unless that switch is off, it turns itself on the first time the engine reports an overload, and the Arranger's overload banner says so.
  - **Live coding:** auto-update (on by default) runs code that compiles the set pause (100–2000 ms) after the last edit. Code with an error waits for the next edit. Swaps land at the swap timing: now, the next beat or the next bar.
  - **Vim keys in the code editor:** off by default.
  - **Code editor:** the symbol key row's keys (add, reorder, remove, default; a key may end in a space), completion chips on or off with how many letters start them and how many show, the Library and Solo preview (headphones) buttons (Solo moves to the module's ⋮ menu when hidden), the scope, the key row and Run bar above the code instead of by the keyboard, and compact control rows.
  - **Piano roll:** row height, velocity and chance lane heights, grid line strength, key names (none, C only, all), the grab zone (how near a note's end a touch resizes it; short notes are easier to hit by this much), how long a hold takes to open a note's extras, and what a drag on empty grid does with the draw or erase tool: scroll (default), select, or the tool's own drag.
- **Keys** (`lib/ui/key_router.dart`): with a keyboard, every key goes through the action system in [actions](actions.md): per-area keymaps, Vim modes, counts, `:` commands, `.` and macros.
  - A badge at the bottom right shows the mode, a recording macro, pending keys, key hints and short toasts.
  - `?` opens the action list: search, keys and run.
  - Recorded macros are saved in `keys.txt` next to `settings.json`; a user `keys.txt` is merged over the default keys.
  - Focused text fields keep plain typing and their own Ctrl+Z/Y/A/C/V/X. In the code editor's Vim normal mode, Backspace, Delete, cursor/navigation keys, Enter and Tab still go to the text field; ordinary Vim letters remain actions.
  - The roll, the Builder and the code editor's Vim mode each run their area's actions; the Arranger's actions work on a keyboard-selected layer.
  - **Not built yet:** editing keys in the action list and the long-press menu entries from the keymap.
- **Fonts:** the UI uses the system font. Code and numbers use the bundled JetBrains Mono (Regular and Bold, about 550 KB), whose licence (SIL OFL 1.1) is shown in the app's licence page.

The piano roll's toolbar exposes **Copy (N)** and **Paste** while notes are selected. Copy stores the whole selection; Paste places that group at the roll cursor and selects the new notes. Dragging any selected note moves the complete selection as a block; group drags move pitch and timing together and do not resize notes. A single selected note can still be resized from its end.

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
- key routing (`test/key_router_policy_test.dart`): focused text fields keep editing/navigation keys and standard shortcuts; Vim retains its command keys
- settings, theme files and the startup choices
- the Tracks area on a phone: cards, the track panel and Edit opening the sound in Sounds (with `CAW_LIB`)
- integration tests through `dart:ffi`: templates, checks, a project sync, a loop export, and the function library with a project library module. It runs when `CAW_LIB` points at a built engine library; CI sets it.
