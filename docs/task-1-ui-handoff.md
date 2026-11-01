---
title: Task 1 UI implementation handoff
summary: Current implementation state, branch and CI evidence for the C.A.W. Master Task 1 UI overhaul.
updated: 2026-11-01
---

# Task 1 UI implementation handoff

## Current GitHub state

- Repository: `Kmandevr/C.A.W`
- Implementation branch: `feature/task-1-ui-workflow`
- Latest implementation-code head before this checkpoint update: `bc021ea92164e0b3998488527d71693e3121656c`.
- PR: [#56 — Task 1 UI workspaces](https://github.com/Kmandevr/C.A.W/pull/56), open and draft.
- PR base: `ccr-395682a8-dthizd`; the branch is 276 commits ahead and 2 behind at the latest comparison (status: diverged). GitHub reported it mergeable. Do not rebase or change its base silently.
- PR remains unmerged. Do not merge without explicit authorization.
- The repository's `main` branch was previously found to be substantially divergent and does not contain the authoritative master plan or current arrangement-first UI. Re-check branch relationships before changing the PR base.

## Implemented workspaces and workflows

- **Builder:** fast creation workspace with existing code-first generator/effect/pattern authoring, parameter editing, audition and common track controls.
- **Arranger:** horizontal arrangement-first timeline, stacked tracks, reusable MIDI clips, selection/editing/splitting/duplication, snapping, zoom, track-height presets, folder hierarchy and a playhead overlay that updates independently of the clip grid.
- **Mixer / Editor:** dedicated channel strips, track volume/pan/mute/solo, generator/effect chain selection, existing folder-bus routing, master output, independent left/right master peaks and compiled-module parameter inspector. Desktop has a draggable channel/inspector split. Mobile has a focused channel list and separate focused editor instead of compressing the desktop grid.
- **Master gain boundary:** a dedicated `caw_engine_set_master` native command updates gain on the audio thread with a 5 ms ramp. The Mixer no longer serializes/recompiles the whole project for every master-slider movement.
- **Meters:** peak bars attack immediately, hold for approximately 400 ms at the 30 Hz meter cadence, then release smoothly. Presentation smoothing does not modify engine measurements.
- **Engine Lab:** CPU/peak/playback/overload telemetry, existing track MIDI/audio paths and outputs, compiler diagnostics, live signal pulses driven by the meter tick, a read-only mono master scope and a 512-point Hann-window FFT spectrum (0–24 kHz). This is an inspector, not an editable universal processing graph or sample/buffer debugger.
- **Automation:** edits the existing serialized track volume/pan lanes and points shared with Arranger and the engine. Curve taps add points, direct drags move them, and point rows expose delete plus precise sliders. Parameter/modulation/processing-behavior automation remains dependent on Task 2 graph APIs.
- **Exporter:** Quick and Advanced modes; existing WAV loop/free/one-shot/wavetable render paths plus native MIDI pattern export. Render progress, cancellation, busy-state locking, actionable errors and temporary-file cleanup are implemented. MIDI generation runs in a worker isolate.
  - Up to 50 export jobs can be queued in-session; each snapshots the project and options at queue time. Jobs run sequentially, can be removed/cancelled, and pause on render/save failure. The queue is not persisted across restarts.
  - Up to 32 named export profiles and the last 20 successful exports persist in settings. History records kind, sample rate, bit depth, length/frame settings, target and parameter so settings can be reapplied when the target still exists.
- **Plugin Builder:** guided blank/template creation and advanced selection/cloning of existing native modules; validates with the existing engine, exposes generated parameters and packages native `.caw` source. CLAP/VST3 binary builds, sandboxing and host I/O testing require a native plugin SDK/host backend not present in the repository.
- **Files:** portable `.cawproj` project and `.caw` module import/export; project-local nested folders, tags, saved searches, name/type sorting, duplicate-source indicators, bulk move and bulk tag operations, and bounded in-session undo/redo (50 metadata snapshots). Imports get a new project identity and malformed/future project versions are rejected. Non-library modules can be sent to the existing Builder Solo preview path.
- **Navigation and touch:** eight workspaces are available on desktop and mobile; mobile uses focused More navigation. Global shortcuts cover all eight workspaces. Custom toggle targets are at least 48 dp.
- **Performance profiles:** Full Experience, Balanced, Lightweight and Minimal. Visual effects are reduced before feedback cadence; meter polling remains at 30 Hz in every profile. Arranger playhead and scope/FFT work use retained buffers and scoped update paths.

## Shared architecture and explicit engine boundaries

All UI work uses the existing `AppState`, `ProjectDoc`, `LayerDoc`, `ModuleDoc`, native engine C API and existing automation representation. No second project, mixer, DSP, processing or automation system has been introduced.

The current engine still does not expose:
- Universal typed editable graph connections across audio, MIDI, parameters and data.
- Low-level sample/buffer mutation or programmable `.cawengine` modules.
- Parameter/modulation graph automation and processing-behavior automation.
- Flexible sends, arbitrary buses beyond the existing folder-bus model, stereo width, correlation/phase and loudness analysis.
- Master effect-chain editing, limiter/compressor configuration or alternate output routing.
- CLAP/VST3 hosting and binary plugin building.

The UI documents these boundaries rather than simulating them. These capabilities belong to Task 2 and should be integrated through stable interfaces when available.

## Verification status

- Earlier Engine CI passed Linux x64, Linux Arm64, Windows x64 and Linux sanitizers before the latest master-gain API change.
- Earlier Docs/hygiene CI passed after the master-plan metadata/index issue was fixed.
- An App CI run exposed three real problems: an invalid Engine Lab scope callback variable, unsupported `Wrap.mainAxisSize`, and missing `ActionRef` import in workspace tests. All three were fixed. Exporter failure/save handling, MIDI busy-state handling, temporary-file cleanup and render-option locking were also tightened. Plugin Builder now clones existing native modules as independent copies. Files library operations have bounded in-session undo/redo, safe import-filter reset and validated saved-search limits. Global Ctrl+1 through Ctrl+8 shortcuts navigate all eight workspaces.
- Regression/widget tests cover master-gain update isolation, native smooth master gain, peak hold/release timing, 48 dp toggle targets, mobile focused Mixer navigation, shared Mixer state, Arranger playhead/track sizing, Engine Lab signal/spectrum, Exporter queue/profile/history/navigation, Plugin Builder cloning, library folder/tag/search operations, bulk move/tag undo/redo, project import identity and malformed library metadata bounds.
- Audio export catches render/save failures and cleans temporary files; MIDI export has independent busy/error handling and worker-isolate generation.
- CI workflow files cancel superseded runs per branch/PR to avoid spending runner time on stale commits.
- **The latest App, Engine and Docs/hygiene workflows for head `bc021ea9` (run IDs `41320549040`, `41320549038` and `41320549049`) were queued when checked; all their individual jobs were still queued. These runs do not verify the subsequent handoff-document commit. Re-check the newest exact-head runs before claiming success.** Do not claim the latest head passes until those exact runs complete.
- The GitHub Actions queue had a large backlog of older runs when checked, and rapid commits caused superseded runs to be cancelled. Allow the newest runs to execute, then inspect any failed job logs before considering the branch verified.
- No local Flutter SDK execution, physical Android/desktop interaction audit, accessibility audit, screenshot comparison or current-device performance benchmark has been completed in this GitHub-only session.


## Checkpoint additions after the earlier handoff

- Added Ctrl+4 Mixer, Ctrl+5 Engine Lab, Ctrl+6 Automation, Ctrl+7 Files and Ctrl+8 Plugin Builder actions and routing; updated action/keymap tests and shortcut documentation.
- Added an in-session library metadata undo/redo stack (maximum 50 snapshots) covering folder creation/rename/delete, module moves, tags and saved searches. This is not general project undo and does not persist across restarts.
- Added the undo/redo controls to the Files workspace and tests for restoring module folder placement.
- Hardened project import by clearing stale search/folder/selection UI state; imported saved-search metadata is length-bounded using safe string handling.
- Hardened WAV/MIDI export error handling, busy states, temporary-file cleanup and render-option locking while a job is active.
- Added an advanced Plugin Builder action to clone an existing module into an independent module; added a widget test.
- Engine Lab now renders a 512-point Hann-window FFT spectrum from the existing 512-sample native master scope. FFT scratch/window/output buffers are retained; the scope remains a mono-sum inspection and does not replace separate L/R peak meters.
- Latest exact-head CI observed before this documentation update: App run 41320549040, Engine run 41320549038, Docs/hygiene run 41320549049; all jobs queued, no final results yet. A new documentation commit will trigger newer runs, which must be checked separately.

## Remaining Task 1 work

- Finish Mixer capabilities only where the native engine API supports them; missing routing, stereo analysis and master-FX features above remain Task 2 dependencies.
- Integrate universal editable Engine Lab graphs, low-level data inspection and programmable engine modules after Task 2 provides stable APIs.
- Extend automation to parameters, modulation connections and processing behavior on the shared engine graph.
- Extend Exporter with durable queue persistence if needed, stems/batch rendering, additional formats/bit depths/channel layouts, normalization/dither and dependency portability only when backend support exists.
- Complete CLAP plugin build/validation/packaging after native host/SDK integration and license review.
- Complete Files audio/MIDI previews and preview caching, durable version history/restore points, dependency collection/relinking, project consolidation and OS-level folder browsing. Current Solo preview is a handoff to Builder, not a background preview player.
- Complete desktop docking/panel persistence and full responsive/touch/keyboard/accessibility review.
- Verify all workspaces on physical mobile and desktop hardware; capture frame-time, CPU, memory, thermal and audio-dropout measurements before making performance claims.
- Run the latest queued CI for the current PR head, fix remaining failures, then update this handoff and PR description with exact results.

## Continuation rules

1. Read `docs/CAW_MASTER_DEVELOPMENT_PLAN.md` before changing scope.
2. Inspect the current branch head and PR state before every significant change; preserve work already on the branch.
3. Continue Task 1 only. Task 2 is architectural context and dependency work, not permission to replace the engine with a parallel implementation.
4. Keep the PR draft and do not merge without authorization.
5. Update this handoff with exact commits, tests and blockers whenever the context is nearing its limit.
