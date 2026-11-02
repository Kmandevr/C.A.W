---
title: C.A.W. roadmap
summary: Permanent product roadmap: verified current state, ordered implementation stages, future production capabilities, performance gates and explicit scope boundaries.
updated: 2026-11-02
---

# C.A.W. roadmap

This is the **permanent, canonical roadmap** for C.A.W. It records the product direction, the order of work and the capabilities intended for the long term. Keep it as a living document: update implementation status only after code, tests and CI establish that a feature works.

The roadmap is the single source for feature sequencing. [App](app.md), [Engine](engine.md) and [Engine implementation status](engine-build-status.md) remain the factual sources for what is implemented today. The [music workflow feature-gap note](music-workflow-feature-gap-plan.md) is a factual gap reference, not a second roadmap. The [lightweight creative audio systems note](lightweight-creative-audio-systems.md) contains supporting technical designs for its roadmap stage.

## Product direction

C.A.W. is a phone-first, code-driven sound-design and music-production workspace. It should support serious, useful music-production workflows—including arrangement, recording, editing, instruments, mixing and delivery—without requiring a heavyweight conventional-DAW architecture.

- **One product and project model:** code, visual editors, instruments, patterns, audio assets and automation share the same underlying project and engine state.
- **Phone-first, desktop-capable:** practical touch workflows on phones, with full keyboard/mouse access on desktop.
- **Local and offline first:** core creation, playback, editing and rendering work locally. Optional collaboration or synchronization must never make the core application cloud-dependent.
- **Lightweight by default:** weak phones remain a first-class target; stronger hardware may use additional cores and resources when the active workload benefits.
- **Native stereo by default:** preserve stereo throughout the normal workflow. Additional channel layouts are a later capability, not a reason to burden ordinary stereo projects.
- **No in-app AI for now:** no AI generation, AI editing, source separation, model inference or cloud audio processing.
- **Video synchronization is not on the roadmap at present.** Do not schedule video tracks, picture playback or video-sync workflows unless the owner revisits this decision.

## Status language

- **[Implemented]** verified in the current app/engine and covered by relevant tests.
- **[Partial]** a usable foundation exists, but the complete workflow is not integrated.
- **[Planned]** intended future work; not a claim that code exists.
- **[Later]** planned after earlier dependencies or release-critical work.
- **[Conditional]** included as a direction, but detailed implementation depends on platform capability, licensing, measured cost or a focused design review.
- **[Not planned]** explicitly outside current scope.

A feature appearing in this roadmap is not evidence that it has shipped. Verify the owning code and tests before changing its status.

## Current implementation snapshot

Checked against the repository on 2026-11-01; re-check before each implementation task.

| Area | Implemented today | Remaining work |
|---|---|---|
| App/platforms | Eight Flutter workspaces; Android and Windows app CI artifacts | iOS/macOS release builds; Linux app is not a shipped CI artifact |
| Engine | Portable C++20 engine, constrained module VM, stereo playback/mixer, offline renderer, worker pool and adaptive workload policy | Modular graph/native-module foundations are not all integrated into the active playback/mixer path |
| Patterns | Piano roll, drum grid, note expressions, lane curves, generators, MIDI file import/export | Kit-row routing, code-generated procedural patterns/Freeze and advanced groove/quantize extensions |
| Arrangement | MIDI clip timeline, linked/independent clips, nested folders, stereo folder buses, track/folder volume-pan automation | Audio clips, clip automation, tempo map, markers/sections and consolidation |
| Mixer | Track volume/pan/mute/solo, generator/effect chains, folder buses and master output | Sends, general sidechain routing, parallel paths and master effect chain |
| Sound/synth | Code generators/effects, house synth patch compiler/playback, built-in wavetable morph/phase warp, LFOs and modulation matrix | Custom/imported wavetable authoring, drawn LFO curves and additional warp modes |
| MIDI | MIDI pattern import/export and MIDI 2.0 UMP decoder/input-queue primitive | USB/Bluetooth device I/O, controller learn, clock and live Engine voice routing |
| Export | WAV loop/free-length/one-shot/wavetable, MIDI, profiles/history and bounded in-memory queue | SFZ multisample workflow, stems, persistent queue and broader batch delivery |
| Audio assets | Generated audio and module/effect processing | Audio import, non-destructive audio clips, sample editor and multisample mapping |
| Recording | No audio or live MIDI recording workflow | MIDI/audio recording, monitoring, latency compensation, punch, loop recording, takes and comping |
| Plugins | Plugin Builder validates/packages native .caw source; native SDK/graph foundations exist | Dynamic native loading/isolation and external CLAP/VST3/AU hosting |
| AI/video | No in-app AI; video sync is not planned | AI remains excluded; video sync remains off-roadmap |

## Roadmap sequence

The stages are ordered by dependency and product value. Work may be split into smaller issues and pull requests, but keep the stage dependencies and exit conditions. The owner can reprioritize explicitly.

### Stage 0 — Complete already-approved v2 commitments

These commitments remain first unless the owner changes their order.

1. Complete automation for module parameters and project globals, including serialization and native engine integration.
2. Complete the WAV/SFZ multisample workflow.
3. Complete stems export and integrate it with the native export pipeline.

**Exit gate:** each feature is usable through the app, tested, documented and verified by CI. A partial engine API or design does not count as complete integration.

### Stage 1 — Finish the existing pattern and piano-roll workflow

Preserve and extend the existing shared text-backed pattern model, piano roll and drum grid.

- Complete kit-row routing and the planned code-generated procedural patterns/Freeze workflow.
- Refine expression curves, stacked lanes, points/handles, snap and live preview.
- Add useful advanced quantization, groove/swing templates, note chop/glue/strum and related editing utilities.
- Keep chord stamping, Euclidean/random-in-key/arpeggiate/humanize generators and existing note-expression tools integrated rather than rebuilding them.
- Preserve touch-first editing, keyboard/action access, linked/independent clip behavior and phone/desktop parity.

**Exit gate:** pattern operations preserve project compatibility and have model, serialization, engine and UI regression tests where relevant.

### Stage 2 — Complete the mixer and signal routing

- Flexible sends and returns.
- General sidechain routing and modulation connections.
- Parallel routing and effect paths.
- A complete master effect chain and practical master controls.
- Track, folder, bus and master routing visualization.
- Useful metering: level, peak, clipping, stereo width/correlation, phase and loudness where measurement cost is justified.

Extend the existing folder-bus and engine processing models. Do not create a second mixer or a UI-only routing graph.

**Exit gate:** tests prove actual audio routing, send levels, sidechain behavior, parallel paths, master processing, channel isolation, stereo behavior and overload handling.

### Stage 3 — Audio assets and non-destructive arrangement clips

- Import and locally preview common audio formats.
- Show waveform summaries and place audio clips on the existing arrangement timeline.
- Trim, split, move, duplicate, source-offset, loop, fade, adjust clip gain and reverse.
- Preserve original source assets; save edits as non-destructive clip operations.
- Support practical audio clip selection, snapping, grouping and undo/redo.
- Reuse the same asset identity and effect/module processing path for generated and imported audio.

**Exit gate:** project save/reopen preserves asset references and edits; missing assets are reported; originals remain unchanged; phone playback and editing stay responsive.

### Stage 4 — Sample editing and multisample instruments

- Sample editor for crop/trim, fades, gain/normalization, reverse and loop points.
- Sampler zones with key ranges, velocity layers, round-robin groups and audition.
- WAV and SFZ multisample authoring/interchange.
- Shared asset model for generated sounds, imported samples and multisample zones.
- Transient slicing and sample-to-pattern workflows after basic editing and mapping are reliable.

**Exit gate:** sample projects save/load correctly, mapping and velocity selection are deterministic, and WAV/SFZ interchange and memory limits are tested.

### Stage 5 — Live MIDI hardware and external control

- Real USB and Bluetooth MIDI device discovery, connection, selection, status and reconnect.
- Note and CC routing, controller learn and editable mappings.
- MIDI clock input/output and synchronization.
- External control-surface support, with assignable controls and clear feedback.
- On-screen performance keys, metronome and count-in.
- Test timing, device loss, duplicate events, lifecycle cleanup and supported real devices.

**Exit gate:** supported hardware connects reliably, events reach the intended tracks/voices, reconnect is safe and timing is verified on real devices.

### Stage 6 — Complete arrangement, timing and delivery

- Song markers, named sections and navigation across longer arrangements.
- Tempo maps and time-signature changes within a project.
- Clip-following automation and complete parameter/modulation automation.
- Consolidation/bounce and rendering of selected tracks, folders and groups.
- Complete stems export, batch export, persistent/recoverable export queues and reusable delivery presets.
- Useful quantization and audio/MIDI alignment tools across the arrangement.
- Robust export progress, cancellation, errors, cleanup and output-location handling.

**Exit gate:** tempo/meter changes, automation and arrangement edits survive save/reopen; stems and batch renders have correct routing, alignment, naming and duration; cancellation and failure cleanup are tested.

### Stage 7 — Recording and performance workflow

Recording is part of the long-term product direction. It is not implemented today; the earlier decision to leave it out of the initial lightweight workflow is superseded by this roadmap.

- MIDI recording from connected devices and on-screen performance controls.
- Audio input/device selection, channel configuration and input monitoring.
- Multitrack audio recording directly to arrangement tracks.
- Input latency measurement and compensation.
- Punch-in/punch-out and loop recording.
- Take lanes, take management and comping.
- Recording count-in, metronome options and practical monitoring controls.
- Safe recording recovery after app interruption, device disconnect or low-storage conditions.

**Exit gate:** recording is reliable on supported hardware, timing/latency behavior is measured, files recover safely after interruption, and the audio callback remains bounded.

### Stage 8 — Audio transformation and advanced production tools

- Time-stretching/warping and pitch-shifting, including beat-aware workflows.
- Transient detection/slicing and advanced sample-to-pattern tools.
- Expanded waveform, spectrum and on-demand asset/selection analysis.
- Spectrogram inspection and practical spectral selection where device cost permits.
- Useful audio repair/restoration tools, introduced incrementally and measured.
- A practical mastering toolset: metering, gain staging, EQ, dynamics, limiting, loudness targets and export checks. This does not require a heavyweight mastering suite.
- Expanded granular processing beyond the existing bounded stutter effect.
- Seeded sound variation, sound lineage/history, mathematical and cellular generators, waveform transformation and lightweight resonator/physical-model instruments, following the detailed [creative audio systems design](lightweight-creative-audio-systems.md).

**Exit gate:** each tool has a focused use case, bounded worst-case CPU/RAM, cancellation and failure handling, deterministic behavior where promised, and measured performance on weak Android hardware.

### Stage 9 — Plugins, platforms and extensibility

- Complete the native module host, lifecycle and isolation requirements before loading third-party native code.
- Support external CLAP hosting, then VST3 and AU where licensing, platform APIs and packaging permit.
- Support building/packaging C.A.W. as a plugin where a stable host-facing interface is available.
- Complete iOS, macOS and Linux app builds and platform-specific audio/device testing.
- Preserve the shared C++ engine and CLI across supported platforms.
- Keep Plugin Builder for .caw modules distinct from external binary plugin hosting.

**Exit gate:** each claimed plugin format and platform has real build, host/device and lifecycle tests; native third-party code has an explicit trust/isolation model.

### Stage 10 — Collaboration and expanded audio formats

- Optional project sharing and collaboration workflows.
- Conflict-aware project synchronization and shared asset handling.
- A collaboration model that supports offline work first and never makes network access necessary for core creation.
- Expanded channel layouts, including surround and immersive/spatial audio workflows, as supported by the engine and target devices.
- Interchange and delivery improvements based on real production workflows.

**Exit gate:** offline projects remain fully usable, sync conflicts are recoverable, shared assets are versioned safely, and multichannel processing is tested end-to-end. Stereo remains the default low-overhead path.

### Stage 11 — Release and commercial delivery

- Signed, reproducible release builds for supported platforms.
- Installation, update, privacy and support documentation.
- Licensing and dependency review for the app, modules and plugin formats.
- Commercial distribution and purchase/unlock flow through the owner's chosen channel.
- Release validation, migration/recovery testing and a clear support matrix.

**Exit gate:** release artifacts install on supported devices, project migration is tested, privacy/licensing requirements are met and distribution claims match actual platform support.

## Cross-cutting performance and quality requirements

These apply to every stage, not as a final optimization pass.

- Measure CPU, callback p99/max duration, memory, allocations, battery/thermal behavior, UI frame time and audio dropouts on weak and strong devices.
- Keep idle overhead near zero: no recurring analysis, polling or background search when features are closed or unused.
- Use the existing worker pool and adaptive workload planner for bounded background work. Parallelize independent preparation/render jobs only when it helps; avoid oversubscription and contention.
- Keep audio callback work bounded, allocation-free, lock-free and free of file I/O, logging, UI calls and unbounded loops. Prepare assets and state off the callback.
- Put analysis, rendering, waveform generation, stretching, file I/O and state reclamation off the audio callback.
- Set explicit limits for voices, buffers, FFT sizes, candidate counts, caches and processing complexity.
- Degrade optional preview/visual work gracefully under pressure; never silently reduce saved asset or final export quality.
- Test deterministic seeds, playback/export agreement, cancellation, project save/load, memory recovery and cleanup after failure.
- Require real low-end Android testing before claiming the weak-device target is met.

## Explicit scope boundaries

- **Not planned:** video tracks, picture playback and video synchronization at this time.
- **Not planned:** in-app AI generation/editing, AI source separation, model inference and cloud audio processing.
- **Not planned:** a return to the retired session/clip-launcher grid as an alternate composition view.
- Avoid heavyweight architecture for its own sake. Feature depth should come from extending the shared project, asset, pattern and engine systems.

## Maintaining this roadmap

- This file is permanent and is the canonical roadmap. Do not replace it with a temporary plan or create competing master roadmaps.
- Add new owner-approved capabilities here, in the correct dependency stage, before implementation begins.
- When priorities change, update the sequence and record the decision in [decisions](decisions.md).
- Keep implementation status factual and update it only after code, tests and CI verify the behavior.
- Detailed technical references may support a stage, but they do not create a separate competing roadmap.
- Each substantial feature still gets its own GitHub issue and implementation pull request.
