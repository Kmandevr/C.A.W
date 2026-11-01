---
title: Task 1 UI implementation handoff
summary: Current implementation state, branch, verification evidence and remaining dependencies for the C.A.W. Master Task 1 UI overhaul.
updated: 2026-11-01
---

# Task 1 UI implementation handoff

## Current GitHub state

- Repository: `Kmandevr/C.A.W`
- Implementation branch: `feature/task-1-ui-workflow`
- Pull request: [#56 — Task 1 UI workspaces](https://github.com/Kmandevr/C.A.W/pull/56), open and draft
- PR base: `ccr-395682a8-dthizd`; inspect branch divergence before changing the base
- Latest implementation commit at the time of this handoff: update this value from the branch ref before relying on it
- No merge has been performed. Do not merge without explicit authorization.

The PR base is intentionally not silently changed to `main`: the existing default/main branch is substantially divergent and does not contain the approved master plan or the arrangement-first UI work. Compare the branches and ask before any base migration or merge.

## Implemented in the current Task 1 slice

- **Builder:** existing module editor and quick active-track controls share project state with the Mixer.
- **Arranger:** horizontal arrangement timeline, reusable MIDI clips, selection/editing, snapping, zoom, track-height presets and a dedicated 30 Hz playhead painter that does not repaint the clip grid.
- **Mixer / Editor:** detailed channel strips, shared volume/pan/mute/solo, module chains and parameter inspector, master level, independent L/R peak meters, folder buses and track-to-folder routing. Desktop has a draggable channels/inspector split. Mobile has a channel-list view and a focused selected-channel editor rather than a compressed desktop grid.
- **Engine Lab:** live engine telemetry, module/compiler diagnostics, track signal-chain inspection, native mono-sum master scope and a retained-buffer 512-point Hann-window FFT spectrum (0–24 kHz). The FFT is display analysis only; it does not modify audio.
- **Automation:** volume and pan lanes are edited in the existing serialized `LayerDoc` automation model and consumed by Arranger/native engine. Lane and point editing share state; no second automation model exists.
- **Exporter:** Quick Export and Advanced modes; native offline WAV renders for loop/free-length/one-shot/wavetable plus native MIDI pattern export. Audio and MIDI progress states are separate; render errors and temporary-file cleanup are handled, and controls are locked during export.
- **Files:** portable `.cawproj` and `.caw` import/export; project-local nested folders; tags; saved searches; name/type sorting; duplicate-source indicators; bulk module moves; and bounded in-session undo/redo for folder, tag, search and move operations. Project switches clear this in-memory library history. Imported projects receive a new ID and malformed/future versions are rejected safely.
- **Plugin Builder:** guided blank/template-based creation and advanced selection of existing modules; clone as an independent module; validate/run through the native engine; expose generated parameters; package native `.caw` source.
- **Navigation/accessibility:** all eight workspaces have global Ctrl+1 through Ctrl+8 shortcuts; touch targets in Mixer/Automation and the Arranger folder disclosure were enlarged. Mobile shell uses a four-item bottom navigation with a More destination.
- **Performance profiles:** Full Experience, Balanced, Lightweight and Minimal. Meter cadence remains 30 Hz; decorative effects are reduced before useful responsiveness. Lightweight/Minimal use the existing reduced voice budget; Minimal hides scope panels.

All new editing uses existing `AppState`, `ProjectDoc`, `LayerDoc`, `ModuleDoc`, native engine calls and existing automation data. No duplicate DSP, project, mixer or automation engine has been added.

## Verification evidence and current status

- Engine CI passed on earlier current-branch heads, including Linux x64, Linux Arm64, Windows x64 and Linux sanitizers.
- Docs/hygiene CI passed on earlier current-branch heads.
- The App workflow on commit `3f62e11d166bdd7274e4419f7a828932656724d6` failed with three compile/analyzer issues:
  - scope painter was passed a wildcard callback parameter instead of the tick revision;
  - Flutter `Wrap` was given the unsupported `mainAxisSize` argument;
  - workspace tests used `ActionRef` without importing its defining `macro.dart`.
- Those issues were corrected in subsequent commits. A duplicate test import was also removed.
- Additional tests now cover the mobile Mixer focused-editor transition, Engine Lab spectrum presence, plugin module cloning, saved-search field synchronization, bulk folder moves and library undo/redo, alongside existing shared-state and export navigation tests.
- The latest App/Engine/Docs workflows are queued for the newest branch commits; their results have not yet been verified. Do not claim that the current head passes until the latest head's workflows complete.
- No local Flutter SDK execution, physical Android/mobile interaction audit, Windows interactive test, accessibility audit, screenshot comparison or quantitative device performance benchmark has been completed in this GitHub-only session.

## Remaining Task 1 work and engine dependencies

- **Mixer:** engine does not currently expose stereo width/channel configuration, correlation/phase, loudness, arbitrary sends/buses, master FX, limiter/compressor or configurable output routing. Existing folder buses and master gain are exposed honestly.
- **Engine Lab / universal graph:** current API exposes module diagnostics, signal chains, mono scope, meter values and parameter declarations, but no editable typed audio/MIDI/parameter/data graph, low-level buffer mutation, or `.cawengine` execution.
- **Automation:** current native automation supports track volume/pan only. Parameter/modulation-link/processing-behavior automation needs the shared engine graph contract from Task 2.
- **Stereo visualization:** engine exposes independent L/R peak values but the scope API returns a mono-sum sample buffer. Independent stereo scopes/correlation require a native stereo-scope interface; do not fake it in the UI.
- **Exporter:** supported current outputs are WAV render modes and MIDI patterns. FLAC, multichannel, stems, queue/history/profiles, normalization/dither, dependency portability and richer render-range controls require actual engine/backend support.
- **Plugin Builder:** CLAP/VST3 binary build, host/sandbox, SDK licensing, crash isolation and per-plugin audio-thread/CPU/memory testing require a native plugin host/SDK backend. Current available build target is the native C.A.W. module format.
- **Files:** OS-level folder browsing is provided only by import/export pickers; preview generation/cache, persistent version history/restore points, dependency relinking/consolidation, bulk export/delete and deeper external-file management remain incomplete. Current library undo/redo is bounded and in-session, not durable version history.
- **Responsive/UI validation:** desktop docking beyond the Mixer split, full portrait/landscape interaction checks, keyboard traversal/semantics audit and real device performance measurements remain to be done.
- **Audio-reactive visuals:** master mono scope and spectrum, L/R peak meters, layer meters and playhead are present; stereo scopes, waveform previews and phase/correlation displays depend on future engine interfaces or preview infrastructure.

## Next actions

1. Check GitHub Actions for the newest branch head; fix analyzer, widget-test, Android APK and Windows build failures before adding more UI.
2. Verify the new FFT implementation and export error paths through CI tests/builds; add focused tests if a failure exposes gaps.
3. Continue responsive and accessibility review across Builder, Arranger, Mixer, Engine Lab, Automation, Exporter, Files and Plugin Builder.
4. Implement only capabilities the current engine exposes. Record Task 2 dependencies for everything else rather than creating simulated controls or parallel processing systems.
5. Update this handoff after each major workstream with the exact branch SHA, commits, CI results and next action.
6. Keep PR #56 draft and do not merge without explicit authorization.
