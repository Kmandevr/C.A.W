---
title: Task 1 UI implementation handoff
summary: Current UI implementation pointer and verified outstanding workflow gaps; no stale branch or CI snapshot.
updated: 2026-11-27
covers: [app/lib/ui/, app/lib/model/cpp_component.dart, app/lib/model/project.dart, app/test/project_test.dart]
---

# Task 1 UI implementation handoff

This file is a concise handoff, not a live Git branch/CI tracker. Previous commit-specific handoff entries and PR states are historical and have been removed because they no longer describe the current repository state.

## Current implementation

The Flutter app has three sections, Build, Files and Arrange (the mixer and automation are part of Arrange; Export is a page from the project menu). They share one AppState and the same native engine/project model (whose devices, sends, lanes and points have stable ids, so history, lanes and links follow a reordered device; [app](app.md)). The app opens straight into the last project, with the arrangement in front; while it loads, the startup screen (the waveform reveal, `lib/ui/startup_screen.dart`) shows the real loading steps and goes the moment the project is open. The transport's tempo is typed with a tap or tapped on a pad (#19), and its undo and redo walk one project history. Space pauses and resumes where it paused; Shift+Space stops. Settings → Key bindings changes what each key does.

The app reference [App](app.md) is the authoritative inventory of implemented screens and behavior. The [UI design](ui.md) describes the design direction and current editor state. The ordered work sequence is planned privately.

Implemented UI/workflow foundations include:
- Build: C++ effects and instruments in a code editor (checks, completion, the Library), patterns, a plug-in page per component (Write → Build → Test → Export: the test suite, CLAP/VST3 plug-in projects, sample packs; and its Needs, the capabilities it declares), the trust sheet with the pre-load scan's findings and the plug-in benchmark beside ▶ Build (checks, the code's own sections, curves; it needs the engine's C API 30 or later).
- Device pages for every 1.1.0 effect mode (the owner-approved device UI plan): Drive's Amp, Pedal and Bands, Bitwise, Tape, Reverse and Multi-tap delays, the new reverbs, Cab, the Compressor's Up and Bus, the Gate's Expand and Pedal gate, the Ducker's Level and Carve, Linear, Match and Wah, Meters, Lo-fi and Phase align; Pitch's Harmonizer and Octaver, Glint, Mimic, Preen and Hush have no page yet. Timber's page (2026-11-20) has the piano's Mode (Classic, Simulated), Quality and Noise in its existing choice and knob rows.
- Rook (Drums) 1.1.3: the kit's kind up front (Synth, Produced and Acoustic cards over the pads), a Randomness knob, the kit tools in a KIT TOOLS card; the Acoustic pieces' settings have no screens of their own yet ([app](app.md)).
- Piano roll and drum grid, including note stretching from either end, snapping of notes and every curve to a time and value grid, note-expression editing, lane curves, pattern generators, multi-selection and MIDI pattern file import/export.
- Arrangement timeline (no 64-bar limit since F7.2; the engine takes more than 64 layers since F7.3, within its layer and export-buffer budgets, but the add buttons still stop at 64: F7.3 part C) with reusable MIDI and audio clips, clip editing, nested folders and stereo folder buses; taps answer on the same frame. Clips and track headers share one gesture rule (owner, 2026-11-12): tap selects, double tap opens the editor, hold opens the menu, hold and move moves; a dragged clip shows guide lines and its bar.beat, and the piano roll's ruler moves the song's cursor and draws its loop. Over the lanes (batch 1.0.3, #207): the section bar (sections, which move, copy and delete with their contents, and markers; the old regions load as sections), the ruler with bars and signature flags from the time signatures, and a tempo lane once the song has a tempo change; the piano roll's bars follow the signatures ([app](app.md)).
- Mixer controls for tracks and master output; engine diagnostics (in the Play build there is no Updates card, and the privacy, feedback and My data pages reach the relay through the companion link when one is present, [companion protocol](companion-protocol.md); with copyable Display modes and Audio clock blocks: [app](app.md), Frame rate), What's new (the bundled changelog, also shown once after an update), Privacy (telemetry, My data) and Send feedback in Settings › About and beta, whose version row carries the startup screen's open-alpha line.
- Track/folder volume-pan automation.
- Freeze, Unfreeze and Bounce to audio from the track and clip hold menus (1.0.5, [app](app.md)).
- Export of WAV loop/free-length/one-shot/wavetable outputs and MIDI patterns, with profiles, history and an in-memory queue; saving copies the finished file to the picked place in chunks. The Music video sheet (Export page and project menu) renders the arrangement as an MP4, cut by an auto director or edited as shots on a lane with layouts, looks, effects, transitions, camera moves, text and images, in Shots, Look, Text & media and Export tabs with a pinned export bar ([app](app.md)).
- Timber's page (1.1.2, 2026-11-20): each model but the piano shows its new Sim choice and Noises knob in its existing rows on the approved page; no new layout ([app](app.md), Timber).
- 1.1.3 (2026-11-25): Starling, Nightingale, Curlew, Bittern and Woodpecker have pages of their own in Timber's layout (`lib/ui/devices/instruments/`, the owner's mockups; looks to confirm in the APK; 2026-11-26 Curlew's cards in two rows with the piccolo, oboe and tuba); knobs turn with a sideways drag, with the up-and-down drag as a setting; the UI is held to 60 Hz while a song plays ([app](app.md)).
- Devices: a merged effect device (FX consolidation, 1.0.8) opens its variant's old page with a variant picker under the header; its own new device UI is not built yet ([app](app.md)).
- Files: Projects first (cards with metadata, nested folders, search, sort, select mode with Move, Export and undoable Delete; [app](app.md)), then a Unity-style tree, grid and inspector over built-in effects, C++ components, patterns, audio and MIDI files, with drag and the effect picker; project (.caw) import and export, library folders, tags, saved searches and restore points stay in its ⋯ menu.
- Settings › Audio: the output and input device drop-downs (on Android `AudioManager`'s devices: the speaker, wired, Bluetooth, USB and the microphones, remembered across reconnects, the device in use under each; #242, [app](app.md)).
- Settings › Performance: the profile, Lightweight on overload, and the Frame rate row, which names the rate in force and why it is below the screen's best ([app](app.md), Frame rate).
- Motion rules and the Motion, Haptics and Glow settings (`lib/ui/motion.dart`), the Glass setting and the glass look across the app (`lib/ui/glass.dart`: ambient background, see-through panels and tracks, frosted sheets, outlined controls), and golden tests with real fonts (`test/golden_util.dart`). Themes come in five light-and-dark families with a theme editor that builds palettes and sets the feel, including the animation style that pages, sheets, panels and clip edits follow ([app](app.md), Theme).
- The frame (`lib/ui/shell.dart`, `lib/ui/frame/`): Build, Files and Arrange as sections on phones (bottom transport and section bar in portrait, a rail in landscape), and docking panels that can float on desktop and tablets ([app](app.md), Frame). The frame shows the crow logo, which is also the launcher icon. Moving parts (playhead, meters, scopes, device motion, a pinch, which lays the lanes out at its zoom on every frame since 2026-11-18) are kept cheap enough for 240 Hz frames, and device motion asks for none while the engine is stopped and silent and nothing is touched (beta plan B3–B4, 2026-11-12; [performance](performance.md#frames-at-240-hz-2026-11-12)). Every main screen and sheet is checked for fit at 360 dp, 412 dp with large text and tablet size (`test/layout_fit_test.dart`).

The owner's UI redesign (2026-11-04) is specified in the private UI plan, with steps U0–U8.

## Verified UI/workflow gaps

- MIDI out (2026-11-27): `LayerDoc.midiOut` and the engine's MIDI out and clock are built, with no screen to set them; ask the owner how they should look (Hub #35) before building one.

- Correlation, phase and loudness meters: there are only peak meters (dB) and scopes.
- Screens for general routing (output overrides, sends into tracks, feedback sends; the model holds them since 2026-11-18, [app](app.md) Routing), parallel mixer paths and master effect chains. Sends to buses and sidechain keys have screens.
- Input health shows only as the *Microphone in use by another app* note in place of the input meters (`audio_input_ui.dart`); background playback has no in-app control beyond the Android notification.
- Multisample mapping and authoring beyond the sampler's zones (the sample editor and Slice to MIDI are built, batch 1.0.4: [app](app.md)).
- USB/Bluetooth MIDI device discovery/connection, controller mapping and live Engine voice routing.
- Stems export, persistent export queue and richer batch delivery.
- C++ component editing, local/offline compilation, dynamic loading and engine registration; project sources/dependency pins persist and materialize into an app-private workspace, and a local CMake runner now invokes an installed toolchain with structured diagnostics. The build service accepts only a component owned by the project being built and returns the verified artifact path; a Linux end-to-end test builds a manifest-driven component with the repository's CMake helper and verifies the CMake build directory survives a source edit/rebuild. Engine registry/C API loading now exists behind an explicit trust argument, and Dart FFI exposes load/unload on a background isolate; the Engine plays native stereo effects with their parameters on tracks (`LayerDoc.components`) and the master (`ProjectDoc.masterComponents`), and native instruments that play a track's notes (`LayerDoc.instrument`, chosen in the track menu, knobs in the FX tab; #156). The trust store (`NativeTrustStore`) exists, but no screen asks for trust yet. On Android the CMake runner refuses to run; the bundled on-device compiler (`libcaw_compiler.so` in the `:compiler` process, driven by `AndroidCppCompiler`) is packaged into the Main APK by CI. No screen uses it yet, and the C++ editor is still missing (plan: `docs/decisions.md`, "The app's layout").
- External CLAP/VST3 binary build/hosting. (Native component loading exists behind an explicit trust choice; see the C++ line above.)
- Additional polish only where tests or real-device use demonstrate a gap.

The existing piano-roll curve tools and pattern generators are implemented, with no note or curve-point cap since F7.1; do not list them as missing.

## Verification rule

Do not infer current CI status from old commit hashes or historical handoff notes. Fetch workflow runs for the exact current PR head. The connector-only workflow cannot run Flutter/CMake commands locally; use CI logs as execution evidence and state that local reproduction was unavailable when applicable.

## Next steps

Follow the private plans and [Engine implementation status](engine-build-status.md). Don't introduce AI product integration without explicit owner authorization.
