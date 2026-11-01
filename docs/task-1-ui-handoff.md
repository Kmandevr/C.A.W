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

## Additional audit finding at head b95a4221

- The Arranger's project-settings master slider still used the general project-edit path, which schedules a full engine sync on every drag update. This bypassed the dedicated native master-gain API already used by Mixer.
- Corrected the Arranger slider to use `AppState.setMaster` and listen to the shared value notifier, preserving immediate UI feedback without full app notifications or project recompilation during the drag.
- Added a widget regression test asserting the Arranger control updates the shared project value, emits one value tick, emits no app-wide notification, and redraws the slider from the updated value.
- Verification for this correction is pending the new exact-head App workflow; no passing claim is made until that run completes.

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


## Additional audit finding at head c27ae853

- The desktop Mixer inspector splitter was mouse-draggable but did not expose an accessible adjustable semantic control.
- Added a named, focusable semantics node with current/increased/decreased width values and increase/decrease actions. Screen-reader users can adjust the inspector width in 2 percentage-point increments; mouse dragging remains available and uses the same bounded state update.
- Added a widget regression test that verifies the semantic control, both adjustment actions and the resulting width values. The test uses a wide test viewport to exercise the desktop layout.
- Verification is pending the exact-head App workflow for this commit.


## Additional audit finding at head ae043d13

- The Automation point editor placed two sliders, numeric readouts and a remove action in one fixed horizontal row. At common phone widths this could overflow and make point editing unusable.
- Reworked point rows responsively: narrow layouts stack time and value controls with clear labels, while wider layouts retain the compact horizontal editor.
- Added semantic slider value descriptions and a 360 px widget regression test covering layout, value edits and overflow detection.
- Verification is pending the exact-head App workflow for this commit.


## Performance and phone-layout fixes at head 3e47ed8a

- Replaced broad UI subscriptions to the shared value tick with scoped per-module and per-track ticks plus a master-output tick. Parameter drags now rebuild only the selected module's parameter controls; level/pan drags rebuild only that track's controls in Builder, Mixer and Arranger. The aggregate tick remains for compatibility but is no longer subscribed to by the workspaces.
- Moved MIDI clip creation into the existing track context menu and compacted the generator selector in the narrow track header. This removes the 3 px DropdownButton overflow found by the widget suite without removing the ability to assign generators or add clips.
- Added notifier disposal and project-switch cleanup. Exact-head widget tests and rebuild benchmark must verify the new scopes; not yet claimed passing.

## Analyzer style cleanup correction at head 785b1331

- The first automated brace pass was too broad and malformed nested Exporter callbacks. Restored the two affected UI files from the previous known-good commit and reapplied each lint fix with explicit block boundaries. The new exact-head App workflow must validate syntax and analyzer output before proceeding.

## Analyzer style cleanup at head f91797bd

- The analyzer then reported only style and deprecation infos. Converted the flagged single-statement conditionals in settings, Exporter and Files to explicit blocks. Replaced deprecated Semantics.focusable with the current focused property tied to the splitter FocusNode, and updated the accessibility test to verify the node can request focus.
- The next exact-head run must confirm a clean analyzer and proceed into widget tests; no test pass is claimed yet.

## Additional analyzer cleanup at head 7d46a1dd

- The second exact-head analyzer run confirmed the undefined identifiers, missing keyboard imports and theme token were fixed. It then found one remaining warning: an unused legacy key-event import in the workspace test. Removed it so analysis can proceed to the test step. Remaining analyzer findings are informational style/deprecation notices; recheck the new run.

## Additional CI audit and repair at head fa6c141e

- Exact-head Dart analysis failed before tests ran. The export-history deserializer referenced undefined rawTarget and rawParam; it now reads the serialized target_id and param fields directly with bounded string validation. Existing settings round-trip coverage checks both fields.
- Engine Lab referenced a nonexistent Neon.violet theme token. Added a dedicated violet theme slot across Calm neon, Night and Amber terminal palettes, and exposed it through Neon.violet; the theme round-trip test iterates every slot.
- Mixer keyboard resizing and its widget test used Flutter keyboard event types without importing flutter/services.dart. Added the required imports.
- Re-run App analysis and widget tests on the new head; the failed run did not reach the test step. Engine Linux x64, Linux Arm64, Windows x64 and Linux sanitizers passed on the preceding head; Docs/hygiene also passed there.

## Additional audit finding at head a8d9ef5d

- A narrow-screen audit found the Arranger toolbar kept its complete control set in a single horizontal row, which could overflow phone widths. It now wraps the controls beneath the section label below 760 px while retaining the desktop row.
- The Exporter's wavetable sweep and frame selectors also shared one fixed horizontal row. They now stack into full-width labelled selectors on narrow layouts and retain the compact desktop row.
- Added a 360 px Arranger regression test for toolbar layout and overflow. The existing Exporter phone-width test exercises format selection; the wavetable selector's narrow layout is covered by the new responsive implementation and will receive a dedicated interaction assertion in the next pass.
- Exact-head CI is pending for these changes; no pass is claimed yet.

## Additional audit finding at head 3a6593b6

- Extended the Mixer splitter beyond screen-reader actions: it now participates in keyboard focus traversal and responds to Left/Right arrow keys, with a regression test for focus-driven resizing.
- Replaced the Exporter's five-way horizontal format selector with a compact dropdown on narrow layouts while retaining the segmented desktop selector. One-shot, MIDI and wavetable target dropdowns expand to the available width.
- Added phone-width Exporter selection coverage and keyboard resizing coverage. Exact-head CI is pending.
