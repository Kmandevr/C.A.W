---
title: Task 1 UI implementation handoff
summary: Current implementation state, branch and CI evidence for the C.A.W. Master Task 1 UI overhaul.
updated: 2026-11-01
---

# Task 1 UI implementation handoff

## Current GitHub state

- Repository: `Kmandevr/C.A.W`
- Implementation branch: `feature/task-1-ui-workflow`
- Current recorded head: `b390c45e8520798613fcb10c508825f26e587364`
- PR: [#56 — Task 1 UI workspaces](https://github.com/Kmandevr/C.A.W/pull/56), open and draft.
- PR base: `ccr-395682a8-dthizd` (the repository default branch used when this workstream began).
- PR remains unmerged. Do not merge without explicit authorization.
- The repository's `main` branch was previously found to be substantially divergent and does not contain the authoritative master plan or current arrangement-first UI. Re-check branch relationships before changing the PR base; do not silently rebase or switch.

## Implemented workspaces and workflows

- **Builder:** existing code-first generator/effect/pattern authoring, parameter editing, audition and common track controls; remains the fast creation workspace.
- **Arranger:** horizontal arrangement-first timeline, stacked tracks, reusable MIDI clips, clip selection/editing/splitting/duplication, snapping, zoom, track-height presets, folder hierarchy and a playhead overlay that updates independently of the clip grid.
- **Mixer / Editor:** dedicated channel strips, track volume/pan/mute/solo, generator/effect chain selection, existing folder-bus routing, master output, independent left/right master peaks and compiled-module parameter inspector. Desktop has a draggable channel/inspector split. Mobile has a focused channel list and separate focused editor instead of compressing the desktop grid.
- **Master gain boundary:** a dedicated `caw_engine_set_master` native command updates gain on the audio thread with a 5 ms ramp. The Mixer no longer serializes/recompiles the whole project for every master-slider movement.
- **Meters:** peak bars attack immediately, hold for approximately 400 ms at the 30 Hz meter cadence, then release smoothly. Presentation smoothing does not modify engine measurements.
- **Engine Lab:** CPU/peak/playback/overload telemetry, existing track MIDI/audio paths and outputs, compiler diagnostics, a read-only mono master scope and a 512-point Hann-window FFT spectrum (0–24 kHz). This is an inspector, not an editable universal processing graph or sample/buffer debugger.
- **Automation:** edits the existing serialized track volume/pan lanes and points shared with Arranger and the engine. Parameter/modulation/processing-behavior automation remains dependent on Task 2 graph APIs.
- **Exporter:** Quick and Advanced modes; existing WAV loop/free/one-shot/wavetable render paths plus native MIDI pattern export. Render progress, cancellation, busy-state locking, actionable errors and temporary-file cleanup are implemented. It does not advertise unsupported formats.
- **Plugin Builder:** guided blank/template creation and advanced selection/cloning of existing native modules; validates with the existing engine, exposes generated parameters and packages native `.caw` source. CLAP/VST3 binary builds, sandboxing and host I/O testing require a native plugin SDK/host backend not present in the repository.
- **Files:** portable `.cawproj` project and `.caw` module import/export; project-local nested folders, tags, saved searches, name/type sorting, duplicate-source indicators, bulk move and bulk tag operations, and bounded in-session undo/redo (50 metadata snapshots). Imports get a new project identity and malformed/future project versions are rejected.
- **Navigation:** eight workspaces are available on desktop and mobile; mobile uses focused More navigation. Global shortcuts cover Builder, Arranger, Exporter, Mixer, Engine Lab, Automation, Files and Plugin Builder.
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

The UI documents these boundaries rather than simulating functionality. These capabilities belong to Task 2 and should be integrated through stable interfaces when available.

## Verification status

- Earlier Engine CI passed Linux x64, Linux Arm64, Windows x64 and Linux sanitizers before the latest master-gain API change.
- Earlier Docs/hygiene CI passed after the master-plan metadata/index issue was fixed.
- An App CI run exposed three real compile/analyzer problems: an invalid Engine Lab scope callback variable, unsupported `Wrap.mainAxisSize`, and missing `ActionRef` import in workspace tests. All three were fixed.
- Additional tests now cover master-gain update isolation, native smooth master gain, peak hold/release timing, mobile focused Mixer navigation, shared Mixer state, Arranger playhead/track sizing, Engine Lab signal/spectrum, Exporter navigation, Plugin Builder cloning, library folder/tag/search operations, bulk move/tag undo/redo, project import identity and malformed library metadata bounds.
- Audio export now catches render/save failures and cleans temporary files; MIDI export has independent busy/error handling.
- CI workflow files now cancel superseded runs per branch/PR to avoid wasting runner time on stale commits.
- **Latest App, Engine and Docs/hygiene workflows have been queued but have not yet produced final results.** Do not claim the latest head passes until those exact runs complete.
- The GitHub Actions queue contained a large backlog of earlier runs when checked. Re-check current head statuses and inspect failure logs before considering the branch verified.
- No local Flutter SDK execution, physical Android/desktop interaction audit, accessibility audit, screenshot comparison or current-device performance benchmark has been completed in this GitHub-only session.

## Remaining Task 1 work

- Finish Mixer capabilities only where the native engine API supports them; the missing routing, stereo analysis and master-FX features above remain Task 2 dependencies.
- Integrate universal editable Engine Lab graphs, low-level data inspection and programmable engine modules after Task 2 provides stable APIs.
- Extend automation to parameters, modulation connections and processing behavior on the shared engine graph.
- Extend Exporter with queues/history/profiles, stems, additional formats/bit depths/channel layouts, normalization/dither and dependency portability only when backend support exists.
- Complete CLAP plugin build/validation/packaging after native host/SDK integration and license review.
- Complete Files audio/MIDI previews and preview caching, durable version history/restore points, dependency collection/relinking, project consolidation and OS-level folder browsing.
- Complete desktop docking/panel persistence and full responsive/touch/keyboard/accessibility review.
- Verify all workspaces on physical mobile and desktop hardware; capture frame-time, CPU, memory, thermal and audio-dropout measurements before making performance claims.
- Run the latest queued CI for the current PR head, fix any remaining failures, then update this handoff and PR description with exact results.

## Continuation rules

1. Read `docs/CAW_MASTER_DEVELOPMENT_PLAN.md` before changing scope.
2. Inspect the current branch head and PR state before every significant change; preserve work already on the branch.
3. Continue Task 1 only. Task 2 is architectural context and dependency work, not permission to replace the engine with a parallel implementation.
4. Keep the PR draft and do not merge without authorization.
5. Update this handoff with exact commits, tests and blockers whenever the context is nearing its limit.
