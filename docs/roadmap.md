---
title: C.A.W. roadmap
summary: Permanent product roadmap: verified current state, ordered implementation stages, future production capabilities, performance gates and explicit scope boundaries.
updated: 2026-11-03
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
- **N-channel engine, stereo by default:** channel count and layout are part of the engine's core design from the Foundation stage, so surround and other layouts never need a rewrite. Users work in stereo (and mono) until Stage 10 exposes other layouts, and ordinary stereo projects stay as light as they are today.
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

An overview by area, checked against the repository on 2026-11-03. The stage tables below give the per-item status. Re-check before each implementation task.

| Area | Implemented today | Remaining work |
|---|---|---|
| App/platforms | Eight Flutter workspaces; Android and Windows app CI artifacts; autosave; per-editor undo/redo; project format version check | App-wide undo, crash recovery, project migrations, onboarding/help; iOS/macOS builds; Linux app is not a shipped CI artifact |
| Engine | Portable C++20 engine, constrained module VM, stereo playback/mixer, offline renderer, worker pool and adaptive workload policy | The typed graph and N-channel contract exist but don't run playback yet (Foundation stage, issue #28) |
| Patterns | Piano roll, drum grid, note expressions, lane curves, generators, MIDI file import/export | Kit-row routing, code-generated procedural patterns/Freeze and advanced groove/quantize extensions |
| Arrangement | MIDI clip timeline, linked/independent clips, nested folders, stereo folder buses, track/folder volume-pan automation, module-parameter and project-global automation | Audio clips, clip automation, tempo map, markers/sections and consolidation |
| Mixer | Track volume/pan/mute/solo, generator/effect chains, folder buses and master output | Sends, general sidechain routing, parallel paths and master effect chain |
| Sound/synth | Code generators/effects, house synth patch compiler/playback, built-in wavetable morph/phase warp, LFOs and modulation matrix | Custom/imported wavetable authoring, drawn LFO curves and additional warp modes |
| MIDI | MIDI pattern import/export and MIDI 2.0 UMP decoder/input-queue primitive | USB/Bluetooth device I/O, controller learn, clock and live Engine voice routing |
| Export | WAV loop/free-length/one-shot/wavetable, MIDI, profiles/history and bounded in-memory queue | SFZ multisample workflow, stems, persistent queue and broader batch delivery |
| Audio assets | Generated audio and module/effect processing | Audio import, non-destructive audio clips, sample editor and multisample mapping |
| Recording | No audio or live MIDI recording workflow | MIDI/audio recording, monitoring, latency compensation, punch, loop recording, takes and comping |
| Plugins | Plugin Builder validates/packages native .caw source; native SDK/graph foundations exist | Dynamic native loading/isolation and external CLAP/VST3/AU hosting |
| AI/video | No in-app AI; video sync is not planned | AI remains excluded; video sync remains off-roadmap |

## Roadmap sequence

The stages are ordered by dependency and product value (owner, 2026-11-03): **Foundation first**, then Stages 0–7, then **Release 1**. Stages 8–10 ship as updates after Release 1. Work may be split into smaller issues and pull requests, but keep the stage dependencies and exit gates. The owner can reprioritize explicitly.

Each stage is a table. **Where** says which part does the work: *engine* (`engine/`, C++), *app* (`app/`, Flutter) or *both*. **Depends on** names the items or stages that must exist first. **What's missing** is the gap between today's code and the item's exit gate. Statuses use the language above and were checked on 2026-11-03.

### Foundation — Engine graph and N-channel core (issue #28)

Comes first (owner, 2026-11-03), before the remaining Stage 0 and Stage 1 features, so they are built on the graph once instead of on the old mixer and then migrated. The detailed engine milestones (M0–M8) are tracked in the engine-progress note on the #28 branch (`feature/native-engine-refactor-integration`); the technical design is the [engine blueprint](engine-next.md).

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| F1 | Typed module graph: validation, stable order, prepared executor, safe publication and retirement | Partial | engine | — | Built and tested, but not used by live playback or offline render |
| F2 | N-channel processing contract: channel layouts (mono … 7.1, discrete), planar channel buffers, generic process block, stereo adapter | Partial | engine | — | On the #28 branch only (not on `Main`); not yet used by the executor |
| F3 | Planar N-channel graph executor | Planned | engine | F1, F2 | The executor still stores left/right buffers, calls only the stereo interface and rejects other layouts |
| F4 | One graph runs everything: .caw layers, synth voices, effects, folder buses and master migrated into the graph | Planned | engine | F3 | The fixed layer → effects → bus → master mixer is still the live path. Stereo projects must render bit-identically before and after (golden tests) |
| F5 | Typed control, modulation and event/MIDI ports in the runtime | Planned | engine | F3 | Only audio ports execute today |
| F6 | One parameter model for manual values, automation, modulation and MIDI mappings | Partial | engine | F4, F5 | Parameter and global automation work on the current engine (PR #68); not unified in the graph |
| F7 | Explicit resource budgets instead of fixed object caps | Partial | engine | — | Graph compile/prepare budgets exist on the #28 branch; the rest of the engine still uses fixed limits |
| F8 | Latency modes (low latency for live playing, stable for lighter CPU) and adaptive concurrency | Partial | both | F4 | Worker pool, workload planner and performance profiles exist; the per-mode buffer/latency behavior is not built |
| F9 | Project format versions and migration of older projects | Partial | app | — | Project files carry a version and newer versions are refused; there is no migration path or migration test suite yet. Needed before F4 changes the project model |

**Exit gate:** live playback and offline render both run through the one graph; existing stereo projects open and render bit-identically (golden hashes unchanged); N-channel buffers are tested with real processing beyond stereo; budgets fail with clear errors instead of silent truncation; older projects migrate under test; Engine, App and Docs CI are green.

### Stage 0 — Complete already-approved v2 commitments

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 0.1 | Automation for module parameters and project globals, with serialization and native engine integration | Implemented | both | — | Done (PR #68). Moves into the graph with F4/F6 |
| 0.2 | WAV/SFZ multisample: import WAV samples (own or third-party), map zones by hand (key ranges, velocity layers), play them in C.A.W, export WAV + SFZ | Planned | both | Foundation; project folders | No audio import, sampler zones or SFZ export exist. Samples live in the project folder or the global library; this pulls the needed parts of Stages 3 and 4 forward (owner, 2026-11-03) |
| 0.3 | Stems export through the native export pipeline | Planned | both | Foundation (per-bus graph renders) | No stems export exists |

**Exit gate:** each feature is usable through the app, tested, documented and verified by CI. A partial engine API or design does not count as complete integration.

### Stage 1 — Pattern workflow and editing safety

Preserve and extend the existing shared text-backed pattern model, piano roll and drum grid. Touch-first editing, keyboard/action access, linked/independent clips and phone/desktop parity are requirements for every item.

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 1.1 | Kit-row routing | Planned | both | Foundation | Not built |
| 1.2 | Code-generated procedural patterns and Freeze | Planned | both | — | Not built |
| 1.3 | Expression curves, stacked lanes, points/handles, snap and live preview | Partial | app | — | Velocity/chance lanes and pitch-bend/pressure/timbre curves with point and segment-bend editing exist; stacked lanes, handles and live preview need refinement |
| 1.4 | Advanced quantize, groove/swing templates, note chop/glue/strum | Planned | app | — | Not built |
| 1.5 | Pattern generators: Euclid, random-in-key, arpeggiate, humanize, chord stamp, legato, reverse, inversion | Implemented | app | — | Keep them integrated; don't rebuild |
| 1.6 | App-wide undo/redo history | Partial | app | — | Undo/redo exists per editor (piano roll, automation lanes, file manager); there is no shared history across workspaces (code, tracks, mixer, settings) |
| 1.7 | Autosave and crash recovery | Partial | app | — | Projects autosave; recovering unsaved work after a crash or forced close is not built |

**Exit gate:** pattern operations preserve project compatibility and have model, serialization, engine and UI regression tests where relevant; undo/redo and crash recovery are tested across workspaces.

### Stage 2 — Complete the mixer and signal routing

Built on the graph from the Foundation stage. Do not keep a second mixer or create a UI-only routing graph.

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 2.1 | Sends and returns (pre/post fader) | Planned | both | F4 | Not built |
| 2.2 | General sidechain routing and modulation connections | Planned | both | F4, F5 | Not built |
| 2.3 | Parallel routing and effect paths | Planned | both | F4 | Effects run in a fixed serial chain today |
| 2.4 | Master effect chain and master controls | Partial | both | F4 | Master output level exists; no master effect chain |
| 2.5 | Track, folder, bus and master routing view | Partial | app | 2.1–2.3 | Signal-chain inspection with live signal pulses exists; no routing editor for sends/sidechains |
| 2.6 | Metering: level, peak, clipping, stereo width/correlation, phase, loudness where cost is justified | Partial | both | F4 | Master and per-layer peak meters and a scope exist; no correlation, phase or loudness meters |

**Exit gate:** tests prove actual audio routing, send levels, sidechain behavior, parallel paths, master processing, channel isolation, stereo behavior and overload handling.

### Stage 3 — Audio assets and non-destructive arrangement clips

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 3.1 | Import and preview common audio formats | Planned | both | 0.2 (WAV import) | WAV import arrives with 0.2; other formats and preview are not built |
| 3.2 | Audio clips on the timeline, positions in beats; each clip *musical* (follows tempo, stretched) or *fixed* (original speed) (owner, 2026-11-03) | Planned | both | F4 | Not built; *musical* clips need time-stretching (8.1) |
| 3.3 | Waveform summaries | Planned | both | 3.1 | Not built |
| 3.4 | Trim, split, move, duplicate, source offset, loop, fade, clip gain, reverse; selection, snapping, grouping, undo | Planned | app | 3.2, 1.6 | Not built |
| 3.5 | Originals untouched: edits saved as non-destructive clip operations; one asset identity for generated and imported audio | Planned | both | 3.1 | Not built |

**Exit gate:** project save/reopen preserves asset references and edits; missing assets are reported; originals remain unchanged; phone playback and editing stay responsive.

### Stage 4 — Sample editing and multisample instruments

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 4.1 | Sample editor: crop/trim, fades, gain/normalize, reverse, loop points | Planned | both | 3.5 | Not built |
| 4.2 | Sampler zones beyond 0.2: round-robin groups and audition | Planned | both | 0.2 | Key ranges and velocity layers arrive with 0.2 |
| 4.3 | Shared asset model for generated sounds, imported samples and zones | Planned | both | 3.5 | Not built |
| 4.4 | Transient slicing and sample-to-pattern | Later | both | 4.1 | After basic editing and mapping are reliable |

**Exit gate:** sample projects save/load correctly, mapping and velocity selection are deterministic, and WAV/SFZ interchange and memory limits are tested.

### Stage 5 — Live MIDI hardware, audio devices and external control

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 5.1 | USB and Bluetooth MIDI device discovery, connection, status and reconnect | Planned | both | F5 | A MIDI 2.0 UMP decoder and input-queue primitive exist; no device I/O |
| 5.2 | Note/CC routing, controller learn and editable mappings | Planned | both | 5.1, F6 | Not built |
| 5.3 | MIDI clock in/out and sync | Planned | engine | 5.1 | Not built |
| 5.4 | Control surfaces with assignable controls and feedback | Planned | both | 5.2 | Not built |
| 5.5 | On-screen performance keys, metronome and count-in | Planned | app | — | Not built |
| 5.6 | Audio output settings: output device choice, buffer size/latency mode, and project render rate (48 kHz default, 44.1/96 selectable) with resampling to the device | Partial | both | F8 | Exports already render at 44.1 or 48 kHz; no output device choice, 96 kHz project rate, device resampling or latency setting in the app |

**Exit gate:** supported hardware connects reliably, events reach the intended tracks/voices, reconnect is safe, output settings take effect without glitches, and timing is verified on real devices.

### Stage 6 — Complete arrangement, timing and delivery

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 6.1 | Song markers, named sections and navigation | Planned | app | — | Not built |
| 6.2 | Tempo maps and time-signature changes | Planned | both | F4 | One tempo and meter per project today |
| 6.3 | Clip-following automation and complete parameter/modulation automation | Partial | both | F6 | Track and project automation lanes exist; clip automation does not |
| 6.4 | Consolidate/bounce and render selected tracks, folders and groups | Planned | both | 0.3 | Not built |
| 6.5 | Batch export, persistent/recoverable export queue, delivery presets | Partial | both | 0.3 | Export profiles, history and a bounded in-memory queue exist; the queue isn't persistent and there's no batch delivery |
| 6.6 | MIDI and audio quantize/alignment across the arrangement | Planned | both | 1.4, 3.2 | Not built |
| 6.7 | Export progress, cancellation, errors, cleanup and output location | Partial | both | — | Native jobs report progress and support cancellation; full cleanup and output-location handling need verification |

**Exit gate:** tempo/meter changes, automation and arrangement edits survive save/reopen; stems and batch renders have correct routing, alignment, naming and duration; cancellation and failure cleanup are tested.

### Stage 7 — Recording and performance workflow

Recording is part of the product direction and the last stage before Release 1. It is not implemented today.

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 7.1 | MIDI recording from devices and on-screen controls | Planned | both | 5.1, 5.5 | Not built |
| 7.2 | Audio input selection, channel configuration and input monitoring | Planned | both | 5.6 | No audio input path exists |
| 7.3 | Multitrack audio recording to arrangement tracks | Planned | both | 3.2, 7.2 | Not built |
| 7.4 | Input latency measurement and compensation | Planned | engine | 7.2 | Not built |
| 7.5 | Punch in/out and loop recording; take lanes and comping | Planned | both | 7.3 | Not built |
| 7.6 | Count-in, metronome options and monitoring controls | Planned | app | 5.5 | Not built |
| 7.7 | Recording recovery after interruption, device loss or low storage | Planned | both | 1.7, 7.3 | Not built |

**Exit gate:** recording is reliable on supported hardware, timing/latency behavior is measured, files recover safely after interruption, and the audio callback remains bounded.

### Release 1 — First release to other people (after Stage 7)

The owner's first public release comes after Stage 7 (owner, 2026-11-03). Supported platforms are the ones CI already builds: Android and Windows.

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| R.1 | Signed, reproducible release builds | Partial | CI | — | CI builds a release APK (signed with the repository key when the secrets are set) and the Windows app; no tagged, reproducible release process |
| R.2 | First-run onboarding and in-app help | Planned | app | Stages 0–7 | Not built |
| R.3 | Preset and template browser | Partial | app | — | Built-in example modules serve as templates; there is no browser for presets, templates and the user's own sounds |
| R.4 | Install, update, privacy and support documentation; support matrix | Planned | docs | — | Not written |
| R.5 | Licensing and dependency review for the app and modules | Partial | docs | — | Dependencies are recorded with licences in `docs/decisions.md`; no release review. The licence for user-created modules is an open owner question |
| R.6 | Distribution and purchase/unlock through the owner's chosen channel | Planned | both | — | The delivery/unlock method is an open owner question ([vision](vision.md#open-owner-decisions)) |
| R.7 | Release validation: migration and recovery tests, real low-end Android testing | Planned | both | F9, 1.7 | Needs the Foundation migration suite and real-device runs on the budget-phone class |

**Exit gate:** release artifacts install on supported devices, project migration is tested, privacy/licensing requirements are met, onboarding works on a fresh install, and distribution claims match actual platform support.

### After Release 1

These stages ship as updates. Their order still holds.

### Stage 8 — Audio transformation and advanced production tools

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 8.1 | Time-stretching/warping and pitch-shifting, beat-aware, non-destructive audio quantize | Planned | engine | 3.2 | Not built. Until then *musical* audio clips can't follow tempo changes |
| 8.2 | Transient detection/slicing and advanced sample-to-pattern | Planned | both | 4.4 | Not built |
| 8.3 | Waveform, spectrum, spectrogram and spectral selection where device cost allows | Planned | both | 3.3 | Not built |
| 8.4 | Audio repair/restoration, added incrementally and measured | Later | engine | 8.3 | Not built |
| 8.5 | Practical mastering: metering, gain staging, EQ, dynamics, limiting, loudness targets, export checks | Partial | both | 2.4, 2.6 | Code effects and a safety limiter exist; no mastering tool set |
| 8.6 | Expanded granular processing | Partial | engine | — | A bounded stutter effect exists |
| 8.7 | Seeded variation, sound lineage, mathematical/cellular generators, waveform transforms, resonator/physical-model instruments ([creative audio systems design](lightweight-creative-audio-systems.md)) | Planned | both | Foundation | Not built |

**Exit gate:** each tool has a focused use case, bounded worst-case CPU/RAM, cancellation and failure handling, deterministic behavior where promised, and measured performance on weak Android hardware.

### Stage 9 — Plugins, platforms and extensibility

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 9.1 | Native module host and lifecycle with three user-chosen modes per plugin/module: Isolated (separate process), Trusted (in-process) or Blocked (owner, 2026-11-03) | Partial | engine | F4 | The native SDK, static registry and module lifecycle contract exist; no dynamic loading, isolation or trust modes. The default mode for unseen code is an open owner question |
| 9.2 | External CLAP hosting, then VST3 and AU where licensing and platforms allow | Conditional | engine | 9.1 | Not built. **[Assumption]** Out-of-process isolation on Android is unverified and may be desktop-first |
| 9.3 | Export any C.A.W graph as a CLAP, then VST3 plugin (every built-in node is plugin-exportable) | Planned | engine | F4 | Not built |
| 9.4 | iOS, macOS and Linux app builds with platform audio/device testing | Conditional | both | — | Not configured in CI; iOS distribution is an open owner question |
| 9.5 | Plugin Builder for .caw modules stays distinct from binary plugin hosting | Implemented | app | — | Plugin Builder validates and packages native .caw source |

**Exit gate:** each claimed plugin format and platform has real build, host/device and lifecycle tests; all three trust modes work and a crash in an Isolated plugin cannot take down the app.

### Stage 10 — Collaboration, cloud library and expanded channel layouts

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 10.1 | Optional project sharing and collaboration, offline-first | Planned | both | F9 | Not built |
| 10.2 | Optional sync with the owner's AutoStacc cloud library, on the project-folder and global-library format | Planned | both | 0.2 (project folders) | How sync works is an open owner question |
| 10.3 | Conflict-aware sync and shared asset handling | Planned | both | 10.1 | Not built |
| 10.4 | Surround and immersive/spatial layouts (quad, 5.1, 7.1 and beyond) exposed to users: track/bus layouts, panning, up/downmix, multichannel export | Planned | both | F3, F4 | The engine is N-channel by design from the Foundation stage; only mono and stereo are offered until here |
| 10.5 | Interchange and delivery improvements from real production use | Later | both | — | Driven by use |

**Exit gate:** offline projects remain fully usable, sync conflicts are recoverable, shared assets are versioned safely, and multichannel processing is tested end-to-end. Stereo remains the default low-overhead path.

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
- Add new owner-approved capabilities here, as a row in the correct stage's table with its status, where, dependencies and what's missing, before implementation begins.
- When an item's status changes, update its row and the snapshot above in the same pull request that proves it (code, tests and green CI).
- When priorities change, update the sequence and record the decision in [decisions](decisions.md).
- Keep implementation status factual and update it only after code, tests and CI verify the behavior.
- Detailed technical references may support a stage, but they do not create a separate competing roadmap.
- Each substantial feature still gets its own GitHub issue and implementation pull request.
