---
title: Task 1 UI implementation handoff
summary: Current UI implementation pointer and verified outstanding workflow gaps; no stale branch or CI snapshot.
updated: 2026-11-12
covers: [app/lib/ui/, app/lib/model/cpp_component.dart, app/lib/model/project.dart, app/test/project_test.dart]
---

# Task 1 UI implementation handoff

This file is a concise handoff, not a live Git branch/CI tracker. Previous commit-specific handoff entries and PR states are historical and have been removed because they no longer describe the current repository state.

## Current implementation

The Flutter app has three sections, Build, Files and Arrange (the mixer and automation are part of Arrange; Export is a page from the project menu). They share one AppState and the same native engine/project model. The app opens straight into the last project, with the arrangement in front; there is no startup screen. The transport's tempo is typed with a tap or tapped on a pad (#19), and its undo and redo walk one project history. Space pauses and resumes where it paused; Shift+Space stops. Settings → Key bindings changes what each key does.

The app reference [App](app.md) is the authoritative inventory of implemented screens and behavior. The [UI design](ui.md) describes the design direction and current editor state. The [core development plan](core-and-feature-plan.md) gives the ordered work sequence.

Implemented UI/workflow foundations include:
- Build: C++ effects and instruments in a code editor (checks, completion, the Library), patterns, and a plug-in page per component (Write → Build → Test → Export: the test suite, CLAP/VST3 plug-in projects, sample packs).
- Piano roll and drum grid, including note stretching from either end, snapping of notes and every curve to a time and value grid, note-expression editing, lane curves, pattern generators, multi-selection and MIDI pattern file import/export.
- Arrangement timeline (no 64-bar limit since F7.2; the engine takes more than 64 layers since F7.3, within its layer and export-buffer budgets, but the add buttons still stop at 64: F7.3 part C) with reusable MIDI and audio clips, clip editing, nested folders and stereo folder buses; taps answer on the same frame.
- Mixer controls for tracks and master output; engine diagnostics in Settings › About and beta.
- Track/folder volume-pan automation.
- Export of WAV loop/free-length/one-shot/wavetable outputs and MIDI patterns, with profiles, history and an in-memory queue; saving copies the finished file to the picked place in chunks. The Music video sheet (Export page and project menu) renders the arrangement as an MP4, cut by an auto director or edited as shots on a lane with layouts, looks and effects ([app](app.md)).
- Files: a Unity-style tree, grid and inspector over built-in effects, C++ components, patterns, audio and MIDI files, with drag and the effect picker; project (.caw) import and export, library folders, tags, saved searches and restore points stay in its ⋯ menu.
- Motion rules and the Motion, Haptics and Glow settings (`lib/ui/motion.dart`), the Glass setting and the glass look across the app (`lib/ui/glass.dart`: ambient background, see-through panels and tracks, frosted sheets, outlined controls), and golden tests with real fonts (`test/golden_util.dart`). Themes come in five light-and-dark families with a theme editor that builds palettes and sets the feel, including the animation style that pages, sheets, panels and clip edits follow ([app](app.md), Theme).
- The frame (`lib/ui/shell.dart`, `lib/ui/frame/`): Build, Files and Arrange as sections on phones (bottom transport and section bar in portrait, a rail in landscape), and docking panels that can float on desktop and tablets ([app](app.md), Frame). The frame shows the crow logo, which is also the launcher icon.

The owner's UI redesign (2026-11-04) is specified in the [UI plan](ui-plan.md), with steps U0–U8.

## Verified UI/workflow gaps

- Correlation, phase and loudness meters: there are only peak meters (dB) and scopes.
- Sends, full sidechain routing, parallel mixer paths and master effect chains.
- Audio import, audio clips and non-destructive audio editing.
- Sample editing, mapping, multisample authoring and SFZ export.
- USB/Bluetooth MIDI device discovery/connection, controller mapping and live Engine voice routing.
- Stems export, persistent export queue and richer batch delivery.
- C++ component editing, local/offline compilation, dynamic loading and engine registration; project sources/dependency pins persist and materialize into an app-private workspace, and a local CMake runner now invokes an installed toolchain with structured diagnostics. The build service accepts only a component owned by the project being built and returns the verified artifact path; a Linux end-to-end test builds a manifest-driven component with the repository's CMake helper and verifies the CMake build directory survives a source edit/rebuild. Engine registry/C API loading now exists behind an explicit trust argument, and Dart FFI exposes load/unload on a background isolate; the Engine plays native stereo effects with their parameters on tracks (`LayerDoc.components`) and the master (`ProjectDoc.masterComponents`), and native instruments that play a track's notes (`LayerDoc.instrument`, chosen in the track menu, knobs in the FX tab; #156). The trust store (`NativeTrustStore`) exists, but no screen asks for trust yet. On Android the CMake runner refuses to run; the bundled on-device compiler (`libcaw_compiler.so` in the `:compiler` process, driven by `AndroidCppCompiler`) is packaged into the Main APK by CI. No screen uses it yet, and the C++ editor is still missing (plan: `docs/decisions.md`, "The app's layout").
- External CLAP/VST3 binary build/hosting. (Native component loading exists behind an explicit trust choice; see the C++ line above.)
- Additional polish only where tests or real-device use demonstrate a gap.

The existing piano-roll curve tools and pattern generators are implemented, with no note or curve-point cap since F7.1; do not list them as missing.

## Verification rule

Do not infer current CI status from old commit hashes or historical handoff notes. Fetch workflow runs for the exact current PR head. The connector-only workflow cannot run Flutter/CMake commands locally; use CI logs as execution evidence and state that local reproduction was unavailable when applicable.

## Next steps

Follow [Core development plan and complete feature list](core-and-feature-plan.md) and [Engine implementation status](engine-build-status.md). Graph-to-Engine/VM integration is the roadmap's Foundation stage (issue #28); don't build UI on top of it before it lands. Don't introduce AI product integration without explicit owner authorization.
