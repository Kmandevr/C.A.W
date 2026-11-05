---
title: Music workflow implementation gaps
summary: Factual snapshot of implemented and incomplete music-workflow capabilities; sequencing belongs to the permanent roadmap.
covers: [engine/, app/lib/model/app_state.dart, app/lib/model/lane_curve.dart, app/lib/model/pattern_doc.dart, app/lib/model/poller.dart, app/lib/model/project.dart, app/lib/model/storage.dart]
updated: 2026-11-05
---

# Music workflow implementation gaps

The owner's UI redesign (2026-11-04) is in the [UI plan](ui-plan.md). Where this note and the UI plan disagree about the UI, the UI plan holds.

This note records the current implementation gaps in C.A.W.'s music-production workflows. It is a factual companion to the permanent [roadmap](roadmap.md), not a separate plan or implementation sequence. The app and engine references remain authoritative for implementation details.

## Existing foundations

### Pattern editor and piano roll

- **[Implemented]** Pattern files, piano-roll editor, draw/select/erase tools, adaptive grid, snapping/free timing (with a second-finger bypass), note stretching from either end, triplets, keyboard navigation, note preview, velocity lane, and per-note velocity, chance, ratchet and slide editing.
- **[Implemented]** Patterns hold any number of notes and curve points in the app as in the engine (F7.1, 2026-11-04).
- **[Implemented]** Opening straight into the last project; New, New from template and Open are in the project menu.
- **[Implemented]** Pause and resume (Space) on the same beat, and Stop (Shift+Space) back to the start (2026-11-05, `caw_engine_play_at`).
- **[Implemented]** Project-wide undo and redo in the transport (whole-project snapshots, one per burst of edits, 100 steps). The piano roll, library and automation keep their own histories too.
- **[Implemented]** MIDI pattern import/export (.mid, .midi2) through the pattern editor. Imported MIDI tempo is not applied to project tempo.
- **[Implemented]** Curve tool for velocity and chance lane curves; per-note expression editors support pitch bend, pressure/volume, timbre and vibrato, including editable points and segment bends.
- **[Implemented]** Pattern actions include Euclidean, random-in-key, arpeggiate, humanize, chord stamp, legato, reverse and pitch inversion.
- **[Incomplete]** Kit-row routing, code-generated procedural patterns/Freeze, advanced quantization and groove/swing utilities remain future work.

### Arrangement

- **[Implemented]** Songs of any length the 32-bit step count holds, with no 64-bar limit (F7.2, 2026-11-04).
- **[Implemented in the engine]** More than 64 layers, bounded by the memory budget (F7.3); the app's add buttons still stop at 64 until F7.3 part C.
- **[Implemented]** Arrangement-first horizontal timeline, track lanes, reusable MIDI clip sources, linked and independent duplicates, move/resize/split, source-offset shift, time selection, multi-selection/reference notes, nested folders and optional stereo folder buses. An adjustable gap between tracks and app-only spacer rows separate tracks on screen.
- **[Implemented]** Track and folder-bus volume/pan automation is serialized and played by the native engine.
- **[Implemented]** Project/timeline automation lanes target module parameters by module ID or named project globals; the app edits song-time points and the native VM evaluates them per sample. Track volume/pan lanes remain separate.
- **[Incomplete]** Audio clips, clip-following automation, tempo/time-signature maps, song markers/sections and consolidation/bounce.

### Mixer and signal flow

- **[Implemented]** Track volume/pan/mute/solo, generator/effect chains, nested folder buses, folder routing and group volume/pan, master output level, and peak meters for the master (stereo), each track and each folder, on a dB scale. Routing between tracks, buses and master carries 32-bit float since 2026-11-03 (Foundation F4.2).
- **[Partial]** Exported module signals and sidechain concepts exist in the engine/module system, but full user-facing routing and modulation connections are not integrated as a general mixer workflow.
- **[Incomplete]** Sends, arbitrary buses, parallel routing/effects, master effect chain and full plugin/global parameter automation.

### Export and file workflow

- **[Implemented]** Native offline WAV rendering, loop/free-length/one-shot/wavetable export, MIDI pattern export, named export profiles, export history and a sequential in-memory queue (up to 50 jobs).
- **[Partial]** Queue state is not persisted across restarts; batch/stem rendering and multi-destination automation are incomplete.
- **[Incomplete]** SFZ multisample workflow, stems export, persistent/recoverable export queue and broader batch delivery.

### Modules and plugins

- **[Implemented]** Code-defined generators/effects, parameter metadata, reusable functions and Plugin Builder for validating/packaging native .caw modules.
- **[Partial]** Native module SDK and graph-processing foundations exist (planar N-channel executor with fan-in since Foundation F3/F4.1). Since F4.3/F4.4 the mixer itself runs as one graph: each module of a track is a node, then the track, folder buses and master. Since F5.1/F5.2 graph nodes can take sidechain audio, modulation, control and event (note/MIDI) inputs, and F6.1–F6.6 add the shared parameter resolver, with resolved values (with modulation links between nodes, automation lanes and MIDI CC mappings) passed to every node, and the Engine's .caw params on it; the app does not yet use modulation links or CC mappings.
- **[Incomplete]** Dynamic native loading/isolation and external CLAP/VST3/AU hosting.

### Audio assets and sampling

- **[Incomplete]** Audio-file import, local asset preview, waveform-backed audio clips, non-destructive clip editing, sample editor, sampler zones, velocity layers, round-robin and complete WAV/SFZ multisample authoring.
- The current engine can generate audio and process it through module/effect chains; that does not constitute an audio-file editing or sampling workflow.

### MIDI hardware and recording

- **[Implemented foundation]** MIDI 2.0 UMP decoding and bounded input-queue primitives, plus MIDI pattern file import/export.
- **[Incomplete]** Physical USB/Bluetooth MIDI discovery/connection, live Engine voice routing, controller learn/mapping, external clock/sync and control-surface support.
- **[Incomplete]** MIDI/audio recording, input monitoring, latency compensation, punch-in/out, loop recording, take lanes and comping.

## Implementation constraints

- Extend the shared project, pattern, clip, asset, module and engine models; avoid parallel incompatible editors or duplicate state.
- Keep arrangement-first composition; the retired session/clip-launcher grid is not an alternate view.
- Maintain phone and desktop parity, touch targets, keyboard/action access and accessible editing gestures.
- Preserve local/offline operation and low CPU/RAM overhead on weak devices.
- Keep audio callback work bounded, allocation-free, lock-free and free of I/O, logging, UI calls and unbounded loops.
- Perform file access, waveform generation, analysis, stretching and export off the audio callback using bounded background work.
- Verify current code and tests before opening implementation work. A listed gap is not permission to invent a parallel architecture; follow the relevant stage in the [roadmap](roadmap.md).
