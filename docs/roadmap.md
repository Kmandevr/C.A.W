---
title: C.A.W. roadmap
summary: Permanent product roadmap: verified current state, ordered implementation stages, future production capabilities, performance gates and explicit scope boundaries.
updated: 2026-11-11
---

# C.A.W. roadmap

This is the **permanent, canonical roadmap** for C.A.W. It records the product direction, the order of work and the capabilities intended for the long term. Keep it as a living document: update implementation status only after code, tests and CI establish that a feature works.

The roadmap is the single source for feature sequencing. [App](app.md), [Engine](engine.md) and [Engine implementation status](engine-build-status.md) remain the factual sources for what is implemented today. The [native engine refactor plan](engine-next.md) is the detailed technical plan for the current engine-foundation workstream. The [music workflow feature-gap note](music-workflow-feature-gap-plan.md) is a factual gap reference, not a second roadmap. The [lightweight creative audio systems note](lightweight-creative-audio-systems.md) contains supporting DSP designs. [Visual creation and signal routing](visual-routing-and-library-integration.md) details the two visual workspaces, typed routing/conditions and reuse candidates.

## Product direction

C.A.W. is a phone-first, code-driven sound-design and music-production workspace. It is not a conventional DAW and needn't work like one, but it must be able to do everything a good DAW can do, because there is no good DAW for mobile ([vision](vision.md), owner 2026-11-03). That covers arrangement, recording, editing, instruments, mixing and delivery, without a heavyweight conventional-DAW architecture.

- **One product and project model:** C++ source, visual composition, instruments, patterns, audio assets, parameters, automation and performance controls share the same component, project and engine state.
- **Ordinary C++ and one SDK:** C++ is the primary general-purpose authoring language; the C.A.W. Library/SDK supplies reusable building blocks without restricting the language to audio. Faust is an optional specialist DSP authoring/backend that should compile to native C++ components; it does not replace C++. The current .caw DSL/VM is transitional and will be removed after its useful capabilities have migrated.
- **Two visual workspaces, one framework:** a component workspace builds instruments/effects/processors using C++, Faust and visual DSP composition; a project/track workspace visually edits track parameters, effect chains, sends, routing and conditional behaviors. The normal arrangement and piano-roll workflow remains the primary song-making surface.
- **Extensible without rewrites:** new components, algorithms, ports, parameters, UI controls, MIDI capabilities, formats and platform/plugin adapters plug into stable contracts rather than requiring unrelated systems to be rewritten.
- **Phone-first, desktop-capable:** practical touch workflows on phones, with full keyboard/mouse access on desktop.
- **Local and offline first:** core creation, playback, editing and rendering work locally. Optional collaboration or synchronization must never make the core application cloud-dependent.
- **Lightweight by default:** weak phones remain a first-class target; stronger hardware may use additional cores and resources when the active workload benefits.
- **Resource-scalable N-channel engine, stereo by default:** channel count and layout are part of the engine's core design from the Foundation stage. Capacity follows actual CPU, memory, device and host budgets rather than an arbitrary fixed product ceiling. New tracks default to stereo; internal tracks may carry more channels than the physical output device, with explicit mapping/downmix at the output boundary. Stage 10 exposes surround and spatial layouts to users, while ordinary stereo projects stay lightweight.
- **Native note/voice/channel expression:** per-note, per-voice and per-channel processing is part of the shared component and runtime model. Note identity, voice identity, expression and channel layout are preserved until an explicit processing or mix boundary.
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
| Engine | Portable C++20 engine, current constrained .caw module VM, stereo playback/mixer, offline renderer, worker pool and adaptive workload policy | The C++ authoring toolchain, shared component SDK and Library are not built; the typed graph and N-channel contract have integration gaps (Foundation, issue #28) |
| Patterns | Piano roll, drum grid, note expressions, lane curves, generators, MIDI file import/export | Kit-row routing, code-generated procedural patterns/Freeze and advanced groove/quantize extensions |
| Arrangement | MIDI clip timeline, linked/independent clips, nested folders, stereo folder buses, track/folder volume-pan automation, module-parameter and project-global automation | Audio clips, clip automation, tempo map, markers/sections and consolidation |
| Mixer | Track volume/pan/mute/solo, generator/effect chains, folder buses and master output | Sends, general sidechain routing, parallel paths, master effect chain and integrated visual track/routing inspector |
| Sound/synth | Code generators/effects, house synth patch compiler/playback, built-in wavetable morph/phase warp, LFOs and modulation matrix | Custom/imported wavetable authoring, drawn LFO curves and additional warp modes |
| MIDI | MIDI pattern import/export; USB, Bluetooth, UMP (Android) and WinMM (Windows) devices into instruments at their frame; controller learn | MIDI clock, MIDI-CI, MIDI output |
| Export | WAV loop/free-length/one-shot/wavetable, MIDI, profiles/history and bounded in-memory queue | SFZ multisample workflow, stems, persistent queue and broader batch delivery |
| Audio assets | Generated audio and module/effect processing | Audio import, non-destructive audio clips, sample editor and multisample mapping |
| Recording | No audio or live MIDI recording workflow | MIDI/audio recording, monitoring, latency compensation, punch, loop recording, takes and comping |
| Plugins | Plugin Builder currently validates/packages native .caw source; native SDK/graph foundations exist | Replace the legacy .caw packaging path with C++ component build/package; dynamic native loading/isolation and external CLAP/VST3/AU hosting |
| AI/video | No in-app AI; video sync is not planned | AI remains excluded; video sync remains off-roadmap |

## Roadmap sequence

**Current order (owner, 2026-11-10):** work goes issue by issue, bottom up (engine first, then the app), one area of the code per branch; UI work only where it is simple. Anything unclear, needing the owner's direction, or seeming to conflict with an earlier decision is not started: the owner gets a notification with the question, and work moves on to the next clear item. C++ replaces the .caw language first ([decisions](decisions.md)), then the owner's three new roles ([vision](vision.md)):
1. #156 C++ instruments, then #157 C++ built-in instruments and a starter project (with #122, the useful .caw built-ins ported to the Library), #17 and #127 (independent instances, per-note and per-channel processing for instruments).
2. #158 note clips as standard MIDI with a text form; #161 C++ modulators and routing anything anywhere (with #32).
3. #160 remove the .caw language, then #159 `.caw` project files.
4. #163 testing suite, #164 sample-pack maker, #162 plug-in builder (CLAP first).
5. Then the stages below, in order, skipping what the .caw removal makes obsolete.

The stages are ordered by dependency and product value: first the **C++ creation-platform foundation**, then the existing **Engine graph/N-channel Foundation**, then the **unified authoring interfaces**, then Stages 0–7 and **Release 1**. Stages 8–10 ship as updates after Release 1. Work may be split into smaller issues and pull requests, but keep the stage dependencies and exit gates. The owner can reprioritize explicitly.

### Creation-platform foundation — C++ language, Library/SDK and shared component model

This is the product's programming and extension foundation. It precedes dependent editor, visual, generated-UI and plugin work. It does not claim that the new toolchain or SDK already exists. The current engine remains C++20, but its .caw DSL/VM is only the present authoring implementation.

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| CP.1 | General-purpose C++ source, project and local/offline build toolchain integrated with C.A.W. | Partial | both | Existing C++20 engine/toolchain | The installable SDK, v1 manifest/helper, structured diagnostics and Linux/Windows/Android repository-CI fixture exist; the PR #125 component matrix is still being verified. The app now persists project-owned C++ sources and exact dependency pins, builds locally with CMake, reuses a build directory and returns a verified artifact path. The Engine has an explicit-trust dynamic loader/C API and Dart FFI; the Engine plays native stereo effects with their parameters on tracks (`LayerDoc.components`) and the master (`ProjectDoc.masterComponents`), before the limiter. Still missing: on-device compiler/toolchain bundling (Android: a native library in a dedicated `:compiler` process; a toolchain manifest validator exists and the CMake runner refuses on Android), dependency acquisition/cache and proactive prefetch, per-component trust UI/store, parameter mapping, track-chain integration and full project handoff. No remote build service; GitHub Actions is repository CI only |
| CP.2 | Shared component descriptor and lifecycle: identity, roles, typed ports, parameters, assets, events/MIDI, note/voice/channel processing scopes, channel layouts, state, capabilities, UI metadata and resource/real-time contracts | Partial | engine | CP.1; integrate with Foundation F1–F6 | Public C++ SDK exposes processor, typed ports, parameter descriptors, events, process blocks and versioned state; descriptor validation and explicit-trust dynamic loading are implemented. The Engine plays native stereo effects with their parameters on tracks (`LayerDoc.components`) and the master (`ProjectDoc.masterComponents`). The descriptor now carries name, component version, role, latency, tail, maximum state size, choice parameters and modulation/automation/MIDI flags that the executor enforces, with stereo-default port helpers. Assets/lifecycle metadata, the stable C interface v3 and app trust UI remain; explicit per-note/per-voice/per-channel processing semantics and preservation of note/voice/channel context also remain |
| CP.3 | Comprehensive C.A.W. Library/SDK for DSP, native stereo/multichannel synthesis, unison/voice processing, MIDI/per-note expression, tables/samples, math, bit manipulation, data and general-purpose utilities | Planned | engine | CP.1, CP.2 | Existing .caw built-ins and engine algorithms need to be catalogued, migrated or replaced behind shared C++ APIs; native stereo generation, per-channel DSP, per-note/per-voice processing and many requested facilities are not yet complete |
| CP.4 | Stable extension and registration contracts, capability negotiation, state/API versioning and explicit ownership/lifetime rules | Planned | engine | CP.2 | Existing native SDK v1 is a starting point, not the complete contract |
| CP.5 | Port useful existing .caw/VM algorithms and sound capabilities into the C++ Library/SDK and native components | Planned | engine | CP.1–CP.4 | No migration has been done; preserve useful capabilities, not old syntax or implementation details |

**Exit gate:** ordinary C++ components compile and register through the shared contracts; the SDK and Library expose useful documented APIs; typed ports, parameters, assets, events, state, lifecycle, processing scopes and real-time requirements have explicit contracts; simultaneous notes and unison voices retain independent expression until explicit merge; native stereo instruments and effects preserve left/right information; N-channel processing respects resource budgets without a fixed product ceiling; the selected existing capabilities have tested C++ paths. The old .caw editor and VM remain only as a temporary migration path until the later authoring-interface stage's retirement gate. No old-source or pre-release-project compatibility layer is required.

Each stage is a table. **Where** says which part does the work: *engine* (`engine/`, C++), *app* (`app/`, Flutter) or *both*. **Depends on** names the items or stages that must exist first. **What's missing** is the gap between today's code and the item's exit gate. Statuses use the language above and were checked on 2026-11-06.

### Foundation — Engine graph and N-channel core (issue #28)

Comes first (owner, 2026-11-03), before the remaining Stage 0 and Stage 1 features, so they are built on the graph once instead of on the old mixer and then migrated. The detailed engine milestones (M0–M8) are tracked in the engine-progress note on the #28 branch (`feature/native-engine-refactor-integration`); the technical design is the [engine blueprint](engine-next.md).

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| F1 | Typed module graph: validation, stable order, prepared executor, safe publication and retirement | Partial | engine | — | Built and tested; the Engine's mix graph runs playback and render (F4.3). The graph-runtime publication helper isn't used by the Engine yet |
| F2 | Resource-scalable N-channel processing contract: explicit layouts (mono, stereo, surround and discrete), planar channel buffers, generic process block, stereo fast path | Partial | engine | — | The current executor still has a 64-channel port ceiling, which is an implementation limit rather than the target contract; replace it with resource-budget-derived capacity and clear refusal when budgets are exceeded. The native C SDK is still left/right with no channel count; its layout contract must be extended explicitly |
| F3 | Planar N-channel graph executor | Implemented | engine | F1, F2 | Built and tested (1, 2, 4, 6, 8 and Discrete(3) channels, no allocation in `process()`; PR #72). Add resource-budget-derived capacity tests and remove the temporary fixed port ceiling as part of the channel-contract completion. Typed ports beyond one audio input and output came with F5.1 |
| F4 | One graph runs everything: .caw layers, synth voices, effects, folder buses and master migrated into the graph | Implemented | engine | F3 | F4.1 fan-in, F4.2 float routing, F4.3 one mix graph for playback and offline render, F4.4 every module of a track (its generator or voice pool, then each effect) as its own node, at most 32 per track with a clear error beyond. Golden hashes were re-recorded in F4.2 and F4.4 for the owner-approved float edges (at most 1 LSB of 24-bit) |
| F5 | Typed control, modulation and event/MIDI ports in the runtime | Implemented | engine | F3 | Any number of audio (sidechain), modulation, control and event ports per node, typed nodes checked at prepare, no implicit type conversion (F5.1). Event ports carry a C.A.W event with a note id and raw MIDI 2.0 UMP (owner, 2026-11-04), merge by frame, count overflow and fail out-of-order output (F5.2). This event identity is not yet a complete per-note/per-voice audio-processing context; connect note/voice identity and expression to the corresponding voice/audio path. MIDI devices and patterns do not feed graph events yet |
| F6 | One parameter model for manual values, automation, modulation and MIDI mappings | Implemented | engine | F4, F5 | F6.1: the parameter resolver (`params.h`: curves, step, smoothing, touch, modulation links in id order) and its descriptor fields. F6.2: the graph executor resolves every node's parameters each block and passes them to processors; manual values arrive from the control thread through a lock-free queue. F6.3: modulation links from a node's modulation output to another node's parameter, applied in link-id order. F6.4: automation lanes on node parameters, read at the transport position with the Engine's own lane algorithm (bit-identical values, seeks included); a touch overrides until playback restarts, and stopping holds the last played value. F6.5: MIDI CC mappings from the graph's host events (MIDI 1.0 and 2.0 UMP Control Changes), applied as the base at the event's frame, like a knob (smoothed, a touch). F6.6: the Engine's .caw params and globals resolve through it too (manual value, automation lane, touch until playback restarts), with golden hashes unchanged. Not wired yet: modulation links and CC mappings from projects or MIDI devices (stages 5 and 6) |
| F7 | Explicit resource budgets instead of fixed object caps | Partial | engine | — | Graph working memory, project state and export buffers are budgets. The caps audit (2026-11-04, [engine status](engine-build-status.md)) lists what remains. F7.1: the app keeps every automation lane and point and any pattern size the engine accepts. F7.2: no 64-bar limit; songs run to the 32-bit step count. F7.3: the slot capacity is a runtime value (part A), and the Engine grows past 64 layers within its budget (part B, merged unfinished; fixes in #94). F7.3 parts A and B: more than 64 layers, up to the memory budget. Still to do: silent clamps in the engine (render lengths), fixed structure (64 layers, 32 voices, 32 modules per track) and safety bounds to make configurable |
| F8 | Latency modes (low latency for live playing, stable for lighter CPU) and adaptive concurrency | Partial | both | F4 | Worker pool, workload planner and performance profiles exist; the per-mode buffer/latency behavior is not built |
| F9 | Project format versions and migration of older projects | Later | app | — | Deferred by the owner (2026-11-03): the app hasn't shipped and there are no projects to keep, so no backwards compatibility is promised before Release 1 and the format stays at version 2. Today files carry a version and the file-manager import refuses newer ones; storage loads don't check it. The migration framework and its tests are built before Release 1 (R.7) |
| F10 | Seeded randomness everywhere: a project seed, per-module seeds that follow it unless pinned, seeding switchable off per module or project, and native plugins given a seed and a deterministic random source | Planned | both | F6 | `.caw` randomness already uses the one project seed (`rand`, `randi`, `hash`, `noise`, note probability); no per-module seed or on/off switch exists, and the native SDK passes plugins no seed (needs an ABI change the owner approves). Owner, 2026-11-03 |

**Exit gate:** live playback and offline render both run through the one graph; golden hashes change only where the owner-approved float graph edges round (F4.2, F4.4), each change cross-checked against the old engine with the same rounding; N-channel buffers are tested with real processing beyond stereo; budgets fail with clear errors instead of silent truncation; Engine, App and Docs CI are green.

### Unified authoring interfaces — code, visual composition and performance UI

These are three interfaces to the same C++ components and project state, not separate engines or representations. They follow the C++ component contracts and native graph foundation.

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| UI.1 | Practical C++ code editor: project tree, tabs, highlighting, SDK-aware completion/docs, diagnostics, navigation, formatting, refactoring, build/run/preview and debugging | Planned | app | CP.1–CP.3 | The current editor targets .caw syntax and has no C++ IDE/toolchain integration |
| UI.2 | Import/drop existing C++ source and projects with supported build configuration/dependencies; register valid components automatically | Planned | both | CP.1, CP.2, UI.1 | Not built |
| UI.3 | Component visual editor: typed DSP composition using built-in Library operations, Faust-generated components and user C++ components; reusable subgraphs and visual editing of DSP behavior | Planned | both | CP.2–CP.3, Foundation F1–F6 | Not built; graphs must compile/prepare into the native runtime, not a separate interpreter |
| UI.3a | Shared visual framework and component workspace: touch/desktop canvas, typed ports, conversion nodes, groups, inspectors, undo/redo and reusable DSP sections | Planned | app | UI.3, CP.2–CP.4 | Not built; component graph remains distinct from project routing graph |
| UI.3b | Project/track visual workspace: track inspector, parameters, sends/destinations, buses, sidechains, channel maps and draggable effect chains alongside conventional mixer/arrangement views | Planned | both | Foundation F1–F6, 2.1–2.4, UI.3a | Not built; must edit the real project/engine routing model rather than maintain a UI-only graph |
| UI.3c | Conditional routing/workflow editor: event sources, predicates, branches, region/clip/note context and actions across tracks/components | Planned | app | UI.3b, 2.7 | Not built; requires bounded event/control scheduling, prepared routes, persistence, diagnostics and deterministic offline parity |
| UI.4 | Generated performance UI from parameter metadata: knobs, sliders, switches, selectors, pads, keyboards, XY controls and meters | Planned | app | CP.2, CP.4 | Existing parameter descriptors and framework-neutral generated-control metadata are partial foundations; full component UI generation is not integrated |
| UI.5 | Optional custom and hybrid component interfaces, with processing/UI separation | Planned | both | UI.4 | Not built |
| UI.6 | Mixer/component browser integration: load components like plugins, expose selected controls, change parameters live and reuse the same processors in tracks/chains/graphs | Planned | both | CP.2, UI.4, Foundation | Existing Mixer and native module/graph foundations are partial; the shared C++ component workflow is not built |
| UI.7 | Shared MIDI performance and routing across C++ components, visual graphs, on-screen keys/pads and external devices | Planned | both | CP.2, Foundation F5–F6, Stage 5 | MIDI file import/export and UMP decoding exist; USB/Bluetooth I/O and live Engine voice routing are not built |
| UI.8 | Remove old .caw editor paths, templates, parser/compiler/VM and obsolete docs after equivalent retained workflows pass tests | Planned | both | CP.5, UI.1–UI.7 | Not started; do not remove the old path before its replacements work |

**Exit gate:** one C++ component appears in the code/component browser, as a typed visual block and in the generated performance UI; all three use the same implementation, parameters, state and event routing. Generated UI works without custom code; custom/hybrid UI is optional. C++ and visual graphs use the same prepared native execution path. MIDI uses the shared event model. The old .caw path is removed only after retained workflows are verified.

### Stage 0 — Complete approved v2 commitments and the engine foundation

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 0.1 | Automation for module parameters and project globals, with serialization and native engine integration | Implemented | both | — | Done (PR #68). Moves into the graph with F4/F6 |
| 0.2 | WAV/SFZ multisample: import WAV samples (own or third-party), map zones by hand (key ranges, velocity layers), play them in C.A.W, export WAV + SFZ | Planned | both | Foundation; project folders | No audio import, sampler zones or SFZ export exist. Samples live in the project folder or the global library; this pulls the needed parts of Stages 3 and 4 forward (owner, 2026-11-03) |
| 0.3 | Stems export through the native export pipeline | Planned | both | Foundation (per-bus graph renders) | No stems export exists |

**Exit gate:** automation remains fully functional; the refactored engine uses one coherent execution model; retained capabilities have tests; the portable fallback works; callback safety, deterministic behavior, playback/export parity, performance budgets and CI are verified. Compatibility with old .caw source and pre-release projects is not required. Device performance claims require real-device evidence.

### Stage 1 — Pattern workflow and editing safety

Preserve and extend the existing shared text-backed pattern model, piano roll and drum grid. Touch-first editing, keyboard/action access, linked/independent clips and phone/desktop parity are requirements for every item.

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 1.1 | Kit-row routing | Planned | both | Foundation | Not built |
| 1.2 | Code-generated procedural patterns and Freeze | Planned | both | — | Not built |
| 1.3 | Expression curves and MIDI-Sketch-style per-note pitch editing: stacked lanes, points/handles, snap and live preview | Partial | app | — | Existing per-note pitch-bend/pressure/timbre curves and point/segment-bend editing are foundations. Make pitch slides/bends directly editable as continuous curves on the note, with the curve matching playback; direct selection must distinguish the curve from the underlying note, which remains visible. Moving, stretching and reshaping must follow touch continuously, with helpful snapping and no abrupt jumps. Separate slide events remain optional where musically useful. Refine stacked lanes, handles, touch targets and live preview |
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
| 2.5 | Track, folder, bus and master routing view | Partial | app | 2.1–2.3 | Signal-chain inspection with live signal pulses exists; the editable track/routing workspace is UI.3b |
| 2.6 | Metering: level, peak, clipping, stereo width/correlation, phase, loudness where cost is justified | Partial | both | F4 | Master and per-layer peak meters and a scope exist; no correlation, phase or loudness meters |
| 2.7 | Engine side of typed conditional routing and regional processing: event/condition/action rules, cross-track MIDI/audio triggers, clip/region/note context, preloaded effect paths and route actions (the editor is UI.3c). First rule: a kick MIDI note ducks the bass track | Planned | engine | F4–F6, 2.1–2.3 (external hardware sources wait for Stage 5) | Not built; design and real-time scheduling requirements are in [visual routing design](visual-routing-and-library-integration.md) |
| 2.8 | Native channel-aware and note/voice-aware effect processing, explicit channel mapping and conversion | Planned | both | CP.2–CP.3, F2–F5 | Components must declare processing scope and accepted/produced layouts; preserve note/voice/channel context until an explicit processing or mix boundary; compatible routing should work by default and conversions/downmixes must never be silent |

**Exit gate:** tests prove actual audio routing, send levels, sidechain behavior, parallel paths, master processing, channel isolation, stereo behavior and overload handling. Conditional routes must prove MIDI-triggered ducking, threshold-triggered preloaded effects, regional activation, bounded rule execution, cycle handling, persistence and identical live/offline semantics.

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
| 5.1 | USB and Bluetooth MIDI device discovery, connection, status and reconnect | Built, untested on hardware | both | F5 | Android USB, Bluetooth LE (in-app scan) and UMP devices, Windows WinMM ports; a device list with activity lights and on/off; frame-accurate engine input (API 14). Windows MIDI Services not used ([app](app.md)) |
| 5.2 | Note/CC routing, controller learn and editable mappings | Built, untested on hardware | both | 5.1, F6 | Learn MIDI CC on any knob's long-press sheet; mappings in the project, listed and removable in Settings › MIDI; MPE and bend range ([app](app.md)) |
| 5.3 | MIDI clock in/out and sync | Planned | engine | 5.1 | Not built |
| 5.4 | Control surfaces with assignable controls and feedback | Planned | both | 5.2 | Not built |
| 5.5 | On-screen performance keys, metronome and count-in | Built | both | — | Slide-up keys and 4×4 pads, the engine's click and a count-in ([app](app.md), Frame: Record; 2026-11-10) |
| 5.6 | Audio output settings: output device choice, buffer size/latency mode, and project render rate (48 kHz default, 44.1/96 selectable) with resampling to the device | Partial | both | F8 | Exports already render at 44.1 or 48 kHz; no output device choice, 96 kHz project rate, device resampling or latency setting in the app |

**Exit gate:** supported hardware connects reliably, events reach the intended tracks/voices, reconnect is safe, output settings take effect without glitches, and timing is verified on real devices.

### Stage 6 — Complete arrangement, timing and delivery

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 6.1 | Song markers, named sections and navigation | Planned | app | — | Not built |
| 6.2 | Tempo maps and time-signature changes | Planned | both | F4 | One tempo and meter per project today |
| 6.3 | Clip-following automation and complete parameter/modulation automation | Partial | both | F6 | Track and project automation lanes exist, drawn by hand or written from the controls (Automate: Touch, Latch, Write, Read); clip automation does not |
| 6.4 | Consolidate/bounce and render selected tracks, folders and groups | Planned | both | 0.3 | Not built |
| 6.5 | Batch export, persistent/recoverable export queue, delivery presets | Partial | both | 0.3 | Export profiles, history and a bounded in-memory queue exist; the queue isn't persistent and there's no batch delivery |
| 6.6 | MIDI and audio quantize/alignment across the arrangement | Planned | both | 1.4, 3.2 | Not built |
| 6.7 | Export progress, cancellation, errors, cleanup and output location | Partial | both | — | Native jobs report progress and support cancellation; full cleanup and output-location handling need verification |

**Exit gate:** tempo/meter changes, automation and arrangement edits survive save/reopen; stems and batch renders have correct routing, alignment, naming and duration; cancellation and failure cleanup are tested.

### Stage 7 — Recording and performance workflow

Recording is part of the product direction and the last stage before Release 1. It is not implemented today.

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 7.1 | MIDI recording from devices and on-screen controls | Partial | both | 5.1, 5.5 | Record writes a take from a MIDI device (placed at its timestamps) or the on-screen keys and pads, with loop passes as takes and a Keep take? toast ([app](app.md)); no record modes (overdub, replace) |
| 7.2 | Audio input selection, channel configuration and input monitoring | Planned | both | 5.6 | No audio input path exists |
| 7.3 | Multitrack audio recording to arrangement tracks | Planned | both | 3.2, 7.2 | Not built |
| 7.4 | Input latency measurement and compensation | Planned | engine | 7.2 | Not built |
| 7.5 | Punch in/out and loop recording; take lanes and comping | Planned | both | 7.3 | Not built |
| 7.6 | Count-in, metronome options and monitoring controls | Partial | app | 5.5 | Metronome off, while recording or always, and a 0–2 bar count-in on Record's long-press; no click sound choice or monitoring controls |
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
| 9.3 | Export any C.A.W graph/component as CLAP, then VST3, using adapters around the shared component and parameter contracts | Partial | engine | CP.2–CP.4, F4 | CLAP and VST3 export of component libraries is built for Linux and Windows (#162, `engine/plugin/clap/`, `engine/plugin/vst3/`); missing: graphs, macOS bundles, the app's Export button, a third-party host check |
| 9.4 | iOS, macOS and Linux app builds with platform audio/device testing | Conditional | both | — | Not configured in CI; iOS ships without C++ authoring (owner, 2026-11-09) |
| 9.5 | Plugin Builder packages C++ components; binary plugin hosting/export remains a separate adapter workflow | Partial | app | CP.1–CP.4, UI.1 | The current Plugin Builder validates/packages .caw source; it must move to the shared C++ component build and descriptor contract |

**Exit gate:** each claimed plugin format and platform has real build, host/device and lifecycle tests; all three trust modes work and a crash in an Isolated plugin cannot take down the app.

### Stage 10 — Collaboration, cloud library and expanded channel layouts

| # | Item | Status | Where | Depends on | What's missing |
|---|---|---|---|---|---|
| 10.1 | Optional project sharing and collaboration, offline-first | Planned | both | F9 | Not built |
| 10.2 | Optional sync with the owner's AutoStacc cloud library, on the project-folder and global-library format | Planned | both | 0.2 (project folders) | How sync works is an open owner question |
| 10.3 | Conflict-aware sync and shared asset handling | Planned | both | 10.1 | Not built |
| 10.4 | Surround and immersive/spatial layouts (quad, 5.1, 7.1 and discrete/custom N-channel layouts) exposed to users: track/bus layouts, spatial panning, explicit up/downmix and multichannel export | Planned | both | F3, F4 | The engine is N-channel by design from the Foundation stage; expose layout selection, spatial panning and multichannel delivery here. Channel capacity remains resource-limited, not capped at a fixed product channel count; stereo stays the default |
| 10.5 | Interchange and delivery improvements from real production use | Later | both | — | Driven by use |

**Exit gate:** offline projects remain fully usable, sync conflicts are recoverable, shared assets are versioned safely, and multichannel processing is tested end-to-end. Stereo remains the default low-overhead path.

See [visual creation and signal routing](visual-routing-and-library-integration.md) for the detailed component/project/condition graph separation, Faust integration path, Tracktion Engine reference strategy and open-source reuse/licence criteria.

## Cross-cutting performance and quality requirements

These apply to every stage, not as a final optimization pass.

- Measure CPU, callback p99/max duration, memory, allocations, battery/thermal behavior, UI frame time and audio dropouts on weak and strong devices.
- Keep one canonical implementation of each processor and algorithm; code, visual blocks, mixer controls and plugin adapters must not create duplicate processing paths.
- Preserve note identity, voice identity, per-note expression and channel layout through the signal chain until an explicit processing, aggregation or mix boundary; never silently discard expression or downmix channels.
- Make native stereo synthesis, unison voice distribution and per-channel/per-note/per-voice effects ordinary SDK capabilities. Compatible connections work with sensible defaults; advanced routing is optional, not a workaround for basic sound design.
- Treat extensibility without unrelated rewrites as a permanent acceptance criterion; test adding components, parameters, ports, UI controls and adapters against the stable contracts.
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
