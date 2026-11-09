---
title: Task 1 UI implementation handoff
summary: Current UI implementation pointer and verified outstanding workflow gaps; no stale branch or CI snapshot.
updated: 2026-11-09
covers: [app/, app/lib/model/cpp_component.dart, app/lib/model/project.dart, app/test/project_test.dart]
---

# Task 1 UI implementation handoff

This file is a concise handoff, not a live Git branch/CI tracker. Previous commit-specific handoff entries and PR states are historical and have been removed because they no longer describe the current repository state.

## Current implementation

The Flutter app currently exposes eight workspaces: Builder, Arranger, Mixer, Engine Lab, Automation, Exporter, Files and Plugin Builder. They share one AppState and the same native engine/project model. The app opens straight into the last project, with the arrangement in front; there is no startup screen. The transport's tempo is typed with a tap or tapped on a pad (#19), and its undo and redo walk one project history. Space pauses and resumes where it paused; Shift+Space stops. Settings → Key bindings changes what each key does.

The app reference [App](app.md) is the authoritative inventory of implemented screens and behavior. The [UI design](ui.md) describes the design direction and current editor state. The [core development plan](core-and-feature-plan.md) gives the ordered work sequence.

Implemented UI/workflow foundations include:
- Builder for code-defined generators, effects, libraries, patterns and synth patches, with generated controls and code editing.
- Piano roll and drum grid, including note stretching from either end, snapping of notes and every curve to a time and value grid, note-expression editing, lane curves, pattern generators, multi-selection and MIDI pattern file import/export.
- Arrangement timeline (no 64-bar limit since F7.2; the engine takes more than 64 layers since F7.3, within its layer and export-buffer budgets, but the add buttons still stop at 64: F7.3 part C) with reusable MIDI clips, clip editing, nested folders and stereo folder buses.
- Mixer controls for tracks and master output, plus a read-only Engine Lab scope/spectrum and diagnostics.
- Track/folder volume-pan automation.
- Export of WAV loop/free-length/one-shot/wavetable outputs and MIDI patterns, with profiles, history and an in-memory queue.
- Files workspace for project/module import/export, project-local organization, tags, saved searches and project restore points.
- Plugin Builder for validating and packaging native .caw source modules.
- Motion rules and the Motion, Haptics and Glow settings (`lib/ui/motion.dart`), the Glass setting and the glass look across the app (`lib/ui/glass.dart`: ambient background, see-through panels and tracks, frosted sheets, outlined controls), and golden tests with real fonts (`test/golden_util.dart`). No screen animates with them yet.
- The docking shell (`lib/ui/shell.dart`, `lib/ui/dock/`): the eight workspaces are docking panels, on phones too.

The owner's UI redesign (2026-11-04) is specified in the [UI plan](ui-plan.md), with steps U0–U8.

## Verified UI/workflow gaps

- Correlation, phase and loudness meters: there are only peak meters (dB) and scopes.
- Sends, full sidechain routing, parallel mixer paths and master effect chains.
- Audio import, audio clips and non-destructive audio editing.
- Sample editing, mapping, multisample authoring and SFZ export.
- USB/Bluetooth MIDI device discovery/connection, controller mapping and live Engine voice routing.
- Stems export, persistent export queue and richer batch delivery.
- C++ component editing, local/offline compilation, dynamic loading and engine registration; project sources/dependency pins persist and materialize into an app-private workspace, and a local CMake runner now invokes an installed toolchain with structured diagnostics. The build service accepts only a component owned by the project being built and returns the verified artifact path; a Linux end-to-end test builds a manifest-driven component with the repository's CMake helper and verifies the CMake build directory survives a source edit/rebuild. Engine registry/C API loading now exists behind an explicit trust argument, and Dart FFI exposes load/unload on a background isolate; `ProjectDoc.masterComponents` now connects zero-parameter stereo effects to the live master chain; parameter mapping and track-chain integration remain outstanding. The per-component trust UI/store is still missing. A `caw.toolchain` manifest validator (`app/lib/platform/cpp_toolchain.dart`) describes the bundled compiler, and the CMake runner refuses to run on Android. Bundling the compiler (on Android a native library in a dedicated `:compiler` process) and the editor are still missing.
- External CLAP/VST3 binary build/hosting. (Native component loading exists behind an explicit trust choice; see the C++ line above.)
- Additional polish only where tests or real-device use demonstrate a gap.

The existing piano-roll curve tools and pattern generators are implemented, with no note or curve-point cap since F7.1; do not list them as missing.

## Verification rule

Do not infer current CI status from old commit hashes or historical handoff notes. Fetch workflow runs for the exact current PR head. The connector-only workflow cannot run Flutter/CMake commands locally; use CI logs as execution evidence and state that local reproduction was unavailable when applicable.

## Next steps

Follow [Core development plan and complete feature list](core-and-feature-plan.md) and [Engine implementation status](engine-build-status.md). Graph-to-Engine/VM integration is the roadmap's Foundation stage (issue #28); don't build UI on top of it before it lands. Don't introduce AI product integration without explicit owner authorization.
