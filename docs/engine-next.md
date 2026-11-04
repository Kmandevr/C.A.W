---
title: Modular adaptive engine blueprint
summary: Complete native-engine architecture and implementation requirements; actual progress and recovery are tracked separately.
updated: 2026-11-04
covers: [engine/, app/]
---

# Modular adaptive engine blueprint

**Status: owner direction and implementation blueprint.** This combines earlier CAW decisions with the clarified 2026-10-30 direction. It describes planned work, not features already built. Actual implementation status is documented in [engine implementation status](engine-build-status.md), [milestone progress](engine-progress.md), [recovery instructions](engine-recovery.md), [engine](engine.md), [app](app.md) and [performance](performance.md).

## 1. Product boundary

C.A.W (Code Auditioning Workspace) is a programmable sound-design and content-creation environment. It creates sound assets and reusable audio capabilities for other applications.

C.A.W.'s primary purpose is sound design and music-content creation, not reproducing a traditional DAW as its main identity. That focus is not a ban on DAW capabilities: the app should include useful arranging, editing, mixing, recording and export tools where they help users make complete music, and should work as a useful lightweight DAW in a pinch. It does not need full feature parity with a dedicated DAW or a feature-rich live-performance environment. External plugins can be hosted under the user-chosen trust modes in §10 (roadmap Stage 9). Recording is not implemented; it is scheduled in [roadmap](roadmap.md) Stage 7. The purpose is to create, audition, refine, package and export content, with enough integrated production capability to stand on its own when needed.

CAW should natively create bytebeat and deterministic mathematical audio; procedural sounds, drums, instruments, effects, samples and wavetables; custom synthesizers and processing modules; MIDI patterns and expressive per-note data including MPE; reusable building blocks; and eventually distributable plugins. It should export content other software can consume, rather than recreate those applications' entire workflows.

## 2. Earlier principles that remain in force

1. **Code remains first-class.** Readable .caw source is a source of truth for people and AI. Visual tools are additional creation/editing routes, not replacements or mandatory gates.
2. **Code → hear → tweak.** Fast audition matters when requested, but not every operation needs ultra-low latency.
3. **Phone-first, not phone-limited.** Touch-first Android use with the same underlying creative capability on desktop. Adapt UI to screen/input, not feature availability.
4. **Deterministic experimentation.** Seeded procedural and bitwise sound remains repeatable. Optimizations preserve defined semantics; golden renders protect intentional sound.
5. **Native and local.** Core creation works offline and does not require a server, account, AI provider or DAW.
6. **Reusable and composable.** A waveform, LFO, envelope, filter, effect, MIDI curve or generator can be reused outside its first intended purpose.
7. **No in-app AI integration in current scope.** External coding assistants may be used as development tools, but do not add an LLM, model inference, AI generation/editing or cloud-audio feature to the shipped product without a new owner decision.
8. **Starter content is a starting point.** The current repository ships starter modules under examples/. A separate factory asset hierarchy is a proposed future organization, not an existing caw/factory path. Users can start blank, modify a template, write code or use the current visual editors.
9. **Local/global assets are explicit.** Local assets belong to a project; global assets are reusable across projects. Stable IDs and versions prevent path changes breaking projects.
10. **Other applications are a destination.** C.A.W. creates portable content for DAWs, games and custom software. External plugin formats/hosting remain future work, not a current capability.
11. **Permissive dependencies only** unless the owner approves an exception. The proprietary project licence remains unchanged.
12. **Low-end hardware is a first-class target.** Every feature needs a resource budget and graceful behavior on weak devices. The floor is budget phones (Galaxy A1x-class, 3–4 GB RAM, Android 10+; owner, 2026-11-03).

## 3. Engine architecture

**Owner decision (2026-11-03): one graph runs everything.** The typed module graph is the eventual core: .caw layers, synth voices, effects, folder buses, sends and master all become graph nodes, replacing the fixed layer → effects → bus → master mixer through migration. It is the roadmap's first stage (Foundation, issue #28; owner, 2026-11-03). Progress: the planar N-channel executor (F3), fan-in (F4.1) and float routing (F4.2) are built, and since F4.3 one mix graph runs live playback and offline render, with a node per track and a master node. Splitting tracks into source and effect nodes is F4.4 (see the [implementation ledger](engine-build-status.md)).

**Owner decision (2026-10-30): one engine, modular by construction.** The engine must behave as one coherent system; modularity is not a bolt-on option or a collection of loosely connected sub-engines. Its module boundaries are the architecture itself. The app, project runtime, synth, add-ons, CLI and future plugin wrappers all use the same module identities, typed ports, parameter/state model, processing semantics and dependency rules. Hosts may omit unused capabilities from a build, but they do not get separate competing implementations or incompatible module models.

Keep a portable C++20 engine independent of Flutter, OS APIs, audio backends and external hosts. The app, CLI, offline renderer and future plugin wrappers are hosts of the same engine.

Core layers:
- **Audio/signal core:** sample formats, channel layouts, block processing, mixing, routing and output protection.
- **Synthesis primitives:** oscillators, custom waveforms, wavetable readers, noise, sample playback, additive/FM/AM/phase/subtractive and procedural sources.
- **DSP modules:** filters, envelopes, LFOs, distortion, dynamics, delay, reverb, modulation and user-defined processors.
- **Typed graph/runtime:** audio, control, modulation and event connections; validation, compilation, scheduling and prepared runtime state.
- **Voice/expression engine:** polyphony, per-note state, MIDI events, MPE-style expression and shared post-voice processing.
- **Existing .caw compiler and VM:** preserve as a first-class, sandboxed creation path. Do not replace it with a mandatory visual graph.
- **Asset/project layer:** versioned serialization, local/global references, dependency resolution and portability.
- **Host/API layer:** versioned C ABI for Flutter, CLI, future plugins and other clients. No UI types or C++ ABI cross this boundary.
- **Unified module contract:** typed port metadata, stable IDs, parameter descriptors, state/version rules and a borrowed-buffer processing contract shared by built-in and third-party modules.

### Stereo and typed connections

Stereo is native, not an effect bolted onto mono output. Signal ports declare channel layout and conversion behavior. **Owner decision (2026-11-03):** ports and buses are N-channel by design (never hard-coded to two); only mono and stereo are implemented until surround. Every built-in node must also be plugin-exportable (no app or OS dependencies). Projects set their own render sample rate (default 48 kHz); live playback resamples to the device when needed. Pan, width, left/right and mid/side processing are explicit. Never silently collapse or duplicate channels.

Audio buffers are 32-bit float, with 64-bit where accuracy needs it (phase/time accumulators, sensitive filter state); the .caw VM keeps 64-bit JavaScript number semantics (owner, 2026-11-03). The live mixer already routes in 32-bit float between tracks, buses and master (F4.2), so the graph can take over routing bit-exactly.

Keep connection types distinct:
- **Audio:** continuous audio buffers.
- **Control:** scalar or block-rate parameter values.
- **Modulation:** time-varying signals driving parameters.
- **Events:** note-on/off, gate, trigger, transport and timestamped events.

**[Fact, 2026-11-04]** Audio (including several inputs for sidechains), modulation, control (Foundation F5.1) and event (F5.2) ports execute in the graph ([decisions](decisions.md)).

Modules declare ports, parameters, supported layouts, state, cost hints and serialization version. Validate graphs off the audio thread.

## 4. Modular creation and UI

A module is a portable, versioned unit with identity, metadata, typed ports, parameters, processing implementation, state serialization, optional UI description, optional custom UI, resource requirements and documentation. It can be a waveform, processor, instrument voice, drum generator or composite graph.

A curve may serve as a waveform, LFO, envelope, MIDI expression curve or parameter map where types permit. A filter can be inside a synth, a standalone effect or part of a custom processor.

Three creation routes must coexist:
- **Code-defined:** .caw source and native APIs provide exact control, procedural generation and repeatability. External coding tools may edit text files; no in-app AI editing feature is included.
- **Visually assembled:** optional graph and parameter tools.
- **Hand-built:** specialized native processing and custom interfaces when generated controls are insufficient.

A module may describe its interface through a UI schema: controls, groups, ranges, units, tooltips, actions, visual editors and meters. The app can generate an interface from that schema. Developers can instead hand-build a specialized UI. Generated UI is a starting point, never a requirement. Both routes use the same engine parameter/event API. UI code never runs in the audio callback, and the engine never depends on Flutter.

Interactive editors should include waveform drawing, curve/Bezier editing, envelopes, LFO shaping, filter response, modulation assignment, tables and step editors.

## 5. Synthesis scope

Preserve the current readable kind:synth patch and translator while evolving them into reusable modules. The synth is a customizable creation system, not a fixed preset instrument.

Planned capabilities:
- Multiple oscillators, sub/noise, built-in and user-drawn waveforms, imported/generated wavetables.
- Waveform drawing, mathematical definition, harmonic editing, combining, shaping, folding, quantization and procedural variation.
- Subtractive, additive, FM, AM, phase modulation, wavetable and sample-based synthesis.
- Multiple filter models/slopes, routing, resonance, drive, key tracking and modulation.
- ADSR, multi-stage, loopable and custom envelopes.
- LFOs with built-in, drawn, stepped, random, sample-and-hold and mathematical shapes; tempo sync and free-running.
- Flexible modulation matrix, macros, depth/polarity/scaling and multiple destinations.
- Reusable effects: distortion, saturation, wavefolding, bitcrushing, delay, reverb, chorus, phasing, filtering and dynamics.
- Stereo-native sources, filters, effects and routing.
- Custom modules in effect slots and composite instruments.

The implemented synth patch currently supports three wavetable oscillator slots, sub/noise, unison up to 16, two serial/parallel filters, three ADSR envelopes, four tempo-synced LFOs (built-in shapes plus four-point curve parameters; a graphical curve editor is not implemented), four macros and a modulation matrix. A single bounded phase-distortion warp parameter is implemented; additional warp modes, custom table authoring, built-in chorus and EQ are not. Voice and resource limits are explicit (voices 1–32, subject to project cap); see [Synth](synth.md).

## 6. MIDI and expression

MIDI is a native event and asset model. Preserve and extend the existing pattern engine, while supporting practical arranging and editing without requiring a traditional-DAW workflow:
- Independent polyphonic voices and per-note expression.
- Pitch bend (editor default ±12 semitones; file range up to ±48), pressure/volume, timbre and vibrato curves.
- Multiple editable expression lanes, bounded by explicit resource budgets.
- Shared curve representation for note expression, LFOs, envelopes and parameter modulation.
- MPE-compatible export and MIDI 2.0-oriented internal precision, including fractional pitches.
- Shared expensive effects after voices are summed where routing permits, rather than duplicating reverb/delay per note.
- Equation-generated modulation and procedural MIDI generation.
- Pattern editing and preview come first; a lightweight arrangement/timeline and practical audio editing can be added where they help complete music-making, without requiring full DAW parity. Recording is scheduled in [roadmap](roadmap.md) Stage 7.

## 7. Factory, projects and asset scope

The proposed factory catalog would use meaningful nested categories and keep substantial assets with their source/documentation. The current repository does not yet contain a caw/factory tree; starter examples remain under examples/. Project-wide documentation stays in docs/.

Proposed organization (adapt existing content; do not blindly move files):

    examples/  # current starter modules; a dedicated factory catalog is future work
      drums/kicks/<asset>/
      drums/snares/<asset>/
      drums/hats/<asset>/
      drums/kits/<asset>/
      instruments/<asset>/
      effects/<asset>/
      waveforms/<asset>/
      wavetables/<asset>/
      midi/<asset>/
      samples/<asset>/
      modules/<asset>/
      presets/<asset>/

The app file manager should reflect this conceptual hierarchy while allowing arbitrary user folders and categories.

- **Local:** stored within one project and travels with it.
- **Global:** stored in the user's library and reusable across projects.
- **Starter examples:** shipped under examples/ today. A future factory catalog should be read-only and never silently overwritten by user edits.

**Owner decision (2026-11-03):** a project is a folder that works like a repository: project file plus local assets, with links to the global library and a "package build" step that collects every dependency so the folder works on its own. Keep it compatible with a future, optional AutoStacc cloud library.

Use stable IDs, explicit versions, dependency manifests and portable references—not absolute paths. Support linked global assets, pinned versions and embedded snapshots. Detect missing dependencies and offer recovery. Never silently change old project sound when a global asset changes.

## 8. Export and external use

CAW is primarily a creator/exporter; external plugin hosting follows the trust modes in §10. Support WAV, wavetables, multisamples (WAV/SFZ where appropriate), standard MIDI and expressive MPE/MIDI 2.0-compatible exports, portable module packages and documented presets. Eventually generate CLAP plugins first, then VST3 and other formats where practical.

Plugin packages embed the required processing and state; CAW need not be running. A phone can author and validate while native compilation runs in GitHub Actions or another build service, with a desktop build path too. Define a supported exportable DSP subset and return precise validation errors for unsupported operations. Test generated plugins in target hosts.

## 9. Adaptive compute and hardware

**Do not force ultra-low latency on every operation.** The active audio callback remains real-time safe, but offline generation, compilation, analysis and asset preparation do not need to pretend to be live playback.

### Workload policies

- **Interactive audition:** low-latency path, small blocks where supported, bounded work and responsive controls.
- **Interactive editing/preview:** prioritize UI responsiveness and stable preview; allow larger blocks/buffering when timing is not critical.
- **Background generation/analysis:** worker threads, larger batches, caches and parallelism; throttle under foreground pressure, heat or low battery.
- **Offline render/export:** maximize throughput or quality within the selected power/thermal budget; parallelize where dependencies and deterministic behavior allow.
- **Idle/suspended:** release or reduce unnecessary resources and polling.

Switching policy must not change sound meaning or corrupt state. Task class is explicit and observable. Never assume every interaction needs low-latency playback.

### Hardware profile

Use supported platform information and measured probes for CPU architecture/SIMD, available cores, memory budget, GPU capabilities, audio backend/sample rate/block size/channel layout/output latency, power saver/battery/thermal hints, and actual engine throughput/headroom. Do not assume GPU is faster. Use GPU only when workload size amortizes transfer/setup costs, with CPU fallback. Use audio-interface or hardware offload only when a real supported path exists and is measured. Avoid fixed device tiers as the only decision.

### Adaptive scheduler/resource governor

A bounded worker pool schedules work by task class, foreground priority, available capacity, memory, thermal/power state, measured cost and user preference. It should reserve callback budget while auditioning; move compilation, graph building, waveform generation, analysis and export off callback; avoid spawning threads per task; scale parallelism without oversubscribing phones; cache programs, graph plans, tables and buffers; use SIMD paths with a portable fallback; batch offline work; yield background work under pressure; expose meaningful quality/speed/power/latency options; and report estimated/actual cost, memory and overload reasons.

Do not silently lower sound quality or change deterministic results to meet a budget. If work cannot fit, warn, offer explicit resource/quality choices, or fail in a controlled way. Existing overload protection is a safety net, not the scheduler.

### Latency and headphones

**Owner decision (2026-11-03):** latency is user-adjustable: a low-latency mode for live playing when timing matters, and a lighter, more stable mode when it doesn't.

Latency is a workload property, not a universal requirement. Report known/estimated output-route latency and support suitable buffering/compensation for preview, capture and export. Do not assume low-latency headphones. For timing-sensitive audition, minimize latency within the route's capability; otherwise favor stability and efficiency. Recording (roadmap Stage 7) must stay synchronized and independent of UI frame rate; it is not implemented today.

### Quality and determinism

**Owner decision (2026-11-03):** offline renders and exports are bit-identical on every platform. Live preview may use faster, non-identical paths only when they are labelled as preview modes.

Keep deterministic mode and golden-render contract. SIMD, multithreading and GPU paths must be bit-equivalent where promised, or explicitly identified as a different render mode with separate tests and a user-visible choice. Parallelize independent work; never introduce races or nondeterministic ordering into shared state. Optimization is not permission to change sound silently.

## 10. Safety, stability and security

The callback and everything it calls must avoid allocation, locks, I/O, logging, UI calls, exceptions and unbounded work. Prepare graphs, buffers, voice pools and state before publishing to audio. Use reviewed real-time-safe handoff; retire old graphs and free memory off callback.

Untrusted .caw source runs in the constrained module language, with no I/O, filesystem, network or system calls and explicit source/program/state/execution limits. Native SDK modules are not sandboxed. **Owner decision (2026-11-03):** each external plugin or third-party native module runs in a mode the user chooses: Isolated (separate process), Trusted (in-process) or Blocked.

## 11. Verification: what “without compromise” means

No one can promise bugs are impossible. The engineering commitment is explicit invariants, tests and measured results. Every meaningful change must preserve or add:
- Existing language semantics; golden renders change only for an intended sound change, with the reason and a measurement.
- Stereo correctness; no clipping or NaN propagation.
- Deterministic seeded output where promised.
- Audio-thread safety and sanitizer coverage.
- Graph validation, cycle handling, bounded resources and safe graph swaps.
- Stable project/asset serialization tests, and migration tests from Release 1 on (before it there are no projects to keep, owner 2026-11-03).
- C ABI/module API version compatibility.
- Benchmarks for low-end-like budgets and larger desktop workloads.
- Stress tests for voices, unison, module count, modulation fan-out, long renders and live edits.
- Cancellation/failure tests for compilation and export.
- UI responsiveness while background jobs run.
- Real Android hardware tests for heat, battery, latency and audio-route changes. CI alone is not proof of device performance.

## 12. Engine dependency order

This is the technical dependency order for the modular engine foundations. It is not the product schedule: [roadmap](roadmap.md) is the single source for sequencing, and the [implementation ledger](engine-build-status.md) records what is built; graph integration (step 3) is the roadmap's Foundation stage.

1. **Audit and contracts:** map runtime, synth, patterns, C API, app bridge, project serialization, benchmarks and tests. Define signal/port types, module contract, asset IDs/versioning, execution modes and capability profile before adding a graph.
2. **Adaptive execution foundation:** separate task scheduling from callback; establish workload policies, bounded workers, hardware profile, telemetry and benchmarks. Preserve current behavior by default.
3. **Typed native module graph:** graph description, validation, prepared plan, audio/control/modulation/event ports and safe graph publication. Keep existing layer/VM path working during migration.
4. **Reusable DSP/synthesis:** expand waveform, oscillator, envelope, LFO, filter, effect, stereo and modulation implementations behind module contracts.
5. **Voice/MIDI expression:** extend current voice/pattern architecture with reusable curves, MPE and shared effects.
6. **Interactive module UI:** schema-driven controls and custom-editor extension points; hand-built UI remains optional and app-side.
7. **Asset/factory integration:** deliberate factory migration, local/global scopes and portable references, then app file manager.
8. **Export/integration:** module packages, MIDI/audio exports, then CLAP and VST3 generation.
9. **Hardware tuning:** benchmark on actual low-end and target devices; tune per-platform policies and document measured results.

Do not attempt a one-shot rewrite. Each stage must leave a buildable, testable product. Until Release 1, project files need not stay loadable and the old engine's sound is not a target (owner, 2026-11-03); `.caw` modules and the C API change only through versioned, tested steps.

## 13. Implementation status

This blueprint describes direction and proposed architecture, not a claim that every capability is built. The [implementation ledger](engine-build-status.md) records what exists, what remains unintegrated, and the verification state. The [engine reference](engine.md) documents the established v1 runtime.

## 14. Existing work to preserve

This blueprint does not supersede built v1 or other CAW decisions. Preserve bytebeat/bitwise language, deterministic math, compiler/VM, code-first editing, plain-text files external coding tools can edit, local/offline rendering, WAV export, preview/loop/pattern/hot-swap capabilities while keeping sound design and content creation primary and adding useful lightweight DAW capabilities where they help, current synth patch format/translator, fractional pitches and note-expression curves, shared effects after voices where appropriate, touch-first phone controls and desktop keyboard support, customizable actions/macros, custom themes, Light mode, existing starter modules under examples/, local/offline project assets, no in-app AI integration, and future plugin work only after a real native host/SDK and release checks, permissive licensing, and GitHub Actions as the build path so the owner can work from Android without a PC/IDE.

See [vision](vision.md), [architecture](architecture.md), [synth](synth.md), [performance](performance.md), [decisions](decisions.md) and [roadmap](roadmap.md). Where those notes conflict with this clarified product focus and capability boundary or adaptive-engine direction, reconcile them as implementation proceeds.


## 15. Unified parameters, modulation, automation and mathematical modules

**Owner clarification:** standard audio parameter control must be a native engine capability, whether it is visible to the user or used internally. The same parameter and modulation machinery must support ordinary manual controls, conventional automation and hidden/internal modulation. Internal complexity must not force a complicated UI; expose simple controls by default and make advanced routing available when wanted.

### One parameter model

**[Fact, 2026-11-04]** The resolution stage exists as `ParameterResolver` (Foundation F6.1), and the graph executor passes every node its resolved parameters (F6.2), with modulation links (F6.3) automation lanes (F6.4) and MIDI CC mappings (F6.5); the Engine's .caw params are not connected yet: its order, operations and the owner's choices on touch, depth units, MIDI CC and native per-block values are in [decisions](decisions.md) ("F6 parameter model").

Use one typed, addressable parameter model across built-in instruments, effects, native modules, the .caw VM, tracks, buses and project-level controls. Each parameter defines a stable identity, value type, range, default, units, scaling/curve, smoothing behavior, automation eligibility and serialization/version rules.

A parameter must be controllable through any supported source without requiring a separate implementation for each module type. UI controls, MIDI/controller input, project automation, modulation links and mathematical expressions all resolve to the same parameter contract. Keep control and UI presentation separate: a parameter can be internally controllable without being displayed, while user-facing parameters can be exposed as knobs, sliders, text/numeric entry, curves or custom controls.

### Manual and conventional control

Support familiar hands-on workflows, including:
- Direct editing and live manipulation of exposed parameters.
- MIDI CC and supported controller mappings, macros and external control surfaces.
- Track, bus, instrument, effect and project-level parameter control.
- Automation lanes with editable points and curves, tempo/time positioning, interpolation, snapping and undo/redo.
- Envelopes, LFOs, note velocity, key tracking and per-note expression as reusable modulation sources.
- Modulation assignment/depth/polarity/scaling and multiple destinations.
- Sidechain/audio-following control where the routing graph supplies the required signal.

Do not require every parameter to have a visible automation lane. Users can reveal or create lanes when needed. Internal modulation may run without adding UI clutter.

### Modulation and automation execution

Treat automation and modulation as related inputs to a shared parameter-resolution stage, not as unrelated features bolted onto individual effects. Define deterministic combination and precedence rules. Support common operations such as replace, add, multiply, min/max and scaled/bipolar modulation, with explicit clamping, units and parameter-specific smoothing. Conflicting sources must have documented, testable behavior; no implicit ordering based on UI or graph traversal.

Use sample-accurate evaluation where audible timing or modulation rate requires it. Use block/control-rate evaluation for slower controls when it is measurably cheaper and does not change the intended behavior. Compile and prepare the control/modulation plan off the audio thread; preallocate its state and buffers. Do not allocate, lock, resolve strings, traverse arbitrary graphs or rebuild automation data in the callback. Reuse constant values and unchanged control signals rather than recalculating them every sample. Preserve the existing per-sample automation path where required for correctness and migrate incrementally.

### Mathematical expressions as first-class generators and effects

Mathematical expressions are not limited to bytebeat or hidden modulation. They must be usable as:
- Audio generators and oscillators.
- Waveform and wavetable definitions.
- Control/modulation sources and parameter curves.
- Complete effects/processors that transform incoming audio.
- Mathematical utility modules that combine signals, events and parameter values where the type system allows.

Keep the existing .caw language and VM as a first-class route for this work. Provide reusable, typed interfaces so a mathematical generator/effect can be used like any other instrument or processor in a track, bus or module chain. Do not force users to write code for ordinary controls or force code-defined modules into a visual graph.

Expression execution must be bounded and sandboxed: validate types and limits before playback, define operation/instruction budgets, prevent unbounded loops and unsafe access, and prepare reusable state outside the callback. Prefer direct formulas for cheap operations; use precomputed tables or compiled/specialized paths only when profiling demonstrates a benefit. Preserve deterministic seeded behavior and defined numerical semantics.

### Resource-aware implementation

The unified parameter system must avoid unnecessary work:
- Constant parameters should remain constants; do not create per-sample streams for values that never change.
- Block-rate controls should not be evaluated per sample unless required.
- Share a modulation source's computed output across destinations where semantics permit.
- Reuse curves, envelopes and expression results when their inputs and timing are unchanged.
- Smooth only parameters that need smoothing; do not add generic smoothing overhead to every value.
- Bound modulation fan-out and expression cost, and include them in graph preparation and workload estimates.
- If a prepared optimization or cache is unavailable, fall back to the ordinary correct calculation path.

### Required verification

Test parameter identity and serialization, manual edits during playback, MIDI/controller mapping, automation interpolation and tempo behavior, multiple-source combination/precedence, modulation fan-out, sample-accurate events, block-rate equivalence, smoothing, expression safety/budgets, deterministic output, project save/reopen and live/offline render parity. Include CPU and memory benchmarks for common cases (static parameters, one LFO, many lanes, high modulation fan-out and mathematical effects). Internal modulation must not add visible UI or recurring idle work when unused.


## 16. Universal creative capability, safe extensibility and unrestricted composition

The engine's goal is to make any technically realizable audio or music idea straightforward to express, connect, run, save and share. It must not be limited to the feature set or workflows its original designers anticipated. Standard workflows are convenient defaults and optimized fast paths, never creative boundaries.

A developer should be able to build a new instrument, effect, generator, processor, routing topology, control system, synthesis method, event behavior or complete custom signal-processing environment by composing documented capabilities or implementing an extension. The architecture should make common work easy and unusual work possible without requiring a fork or invasive core rewrite.

### Universal signal, event and routing model

Use a typed, multi-domain graph with explicit ports and connections. It must support, combine and route at minimum:
- Mono, stereo, multichannel and custom channel layouts, with explicit channel mapping, splitting, merging, encoding and conversion.
- Audio streams, sidechain/key inputs, control-rate signals, sample-accurate control signals, modulation, envelopes and parameter streams.
- MIDI 1.0, MIDI 2.0/UMP, note events, per-note expression, controller data, clock, transport, tempo and arbitrary timestamped events.
- Internal and external inputs/outputs, tracks, buses, groups, sends, returns, parallel paths, nested processing, instrument outputs and effect sidechains.
- Cross-domain routing where meaningful: audio to envelope/follower/control, MIDI or events to parameters and generators, control to audio processing, and custom extension-defined data types.
- Feedback and cyclic networks when explicitly declared and made schedulable through appropriate delay/state boundaries. Detect and explain instantaneous cycles that cannot be scheduled safely.

Sidechain must be a first-class connection type, not a special case tied to one mixer layout. Any compatible source may feed a processor's declared sidechain input, including audio channels, buses, tracks, external inputs, MIDI/event streams, envelopes or control signals. Support multiple sidechain inputs and destinations, independent channel mapping, filtering and gain, and sidechain routing between buses and processors. Sidechain and ordinary routing must work through the same graph and project model.

Provide a discoverable routing UI and APIs that make connections easy to create, inspect, edit, save, validate and automate. The engine graph must not assume a fixed track/bus/master hierarchy.

### Extension surfaces

Provide documented, versioned extension points for:
- Custom generators, instruments, effects, processors, analyzers and complete module subgraphs.
- Custom signal, sidechain, control and event routing.
- Custom parameter types, modulation sources, mappings and resolution behaviors.
- Alternative synthesis and processing algorithms, including hybrid, physical, granular, spectral, physical-modeling, feedback-based and future approaches not yet anticipated.
- Custom control surfaces, UI presentations and module-specific workflows without coupling UI code to the audio callback.
- New processing domains, execution strategies, state models and specialized hardware paths.

Prefer composing existing primitives and registering modules over modifying core engine code. Do not force every technique into one generic processor abstraction when that would constrain the idea or add needless overhead. Offer simple common interfaces and advanced escape hatches with explicit contracts.

### No arbitrary architectural limits

Do not impose arbitrary fixed caps on tracks, buses, channels, routing connections, graph depth, module count, parameters, modulation links, automation lanes, events, voices, or project size merely for implementation convenience. Do not silently truncate or drop user content at an arbitrary threshold.

The real limits are available memory, CPU/GPU/DSP capacity, platform/API constraints, declared module requirements and the user's chosen resource budget. Discover and use available capacity; allocate and schedule according to actual needs; expose meaningful resource diagnostics; degrade gracefully where possible. Any unavoidable platform or format limit must be documented, surfaced before destructive action, and handled with a clear alternative. Avoid unlimited allocation or unbounded real-time work: scalable does not mean unchecked.

Resource budgets for untrusted or potentially runaway work must be configurable and enforceable, not hidden arbitrary product caps. Support sensible defaults, user/developer overrides within host safety policy, per-module budgets, global budgets, monitoring, graceful throttling/bypass and clear explanations when a requested graph exceeds the resources actually available. Never claim a configuration is safe if it cannot be bounded.

### Safety and real-time contracts

Every extension declares input/output types and channel layouts, sample-rate and block-size requirements, latency, tail behavior, state needs, parameter/event interfaces, resource estimates and real-time properties. Validate and prepare the graph before activation.

- Keep allocation, blocking locks, file/network I/O, logging, UI calls and unbounded work off the hard real-time audio thread.
- Preallocate or reserve resources during preparation; use bounded callback work and lock-free or otherwise real-time-safe communication where needed.
- Define handling for non-finite values, excessive gain, unstable feedback, denormals, deadline misses, resource exhaustion and processor failure.
- Provide safe bypass, mute, isolation, recovery and diagnostics without stalling the audio callback.
- Make feedback stability tools available (delay boundaries, gain/energy monitoring, optional limiting and cycle diagnostics) without forbidding intentional feedback designs.
- Use the strongest practical isolation for untrusted third-party code. In-process native extensions are trusted code, not sandboxed. Keep sandboxed .caw VM execution bounded and explicit.
- Where a hard safety boundary prevents a requested operation, explain the exact constraint and offer a safe supported route rather than silently changing behavior.

### Efficient execution without creative restrictions

Compile/prepare graph topology, routing, parameter resolution and scheduling away from the audio callback. Choose efficient execution paths based on measured benefit and available hardware. Support parallel independent branches, specialized processors, vectorization and accelerators where useful, while retaining portable CPU fallbacks. Do not impose advanced-path overhead on ordinary modules that do not use those features.

### Compatibility and evolution

Version extension APIs, graph data and serialized module state. From Release 1 on, preserve existing projects through migrations and defaults. Capability negotiation must identify unavailable modules or features and provide a clear fallback or actionable error rather than silently changing project behavior. Experimental interfaces may evolve, but isolate them from stable contracts and provide migration paths.

### Required verification

Test complex mixed-domain routing; audio/MIDI/control sidechains; multichannel mapping; nested buses, sends and returns; feedback with and without valid delay boundaries; graph compilation and cycle diagnostics; large projects without arbitrary truncation; resource-budget exhaustion and recovery; extension/API version mismatch; malicious or runaway VM programs; processor failure and bypass; state migration; deterministic output; and live/offline parity. Benchmark graph compilation, routing, extension dispatch and callback costs across small and large projects. Confirm that standard paths remain lightweight while advanced projects remain possible within actual hardware and safety constraints.


## 17. Adaptive concurrency, batching and minimum-overhead execution

Concurrency is a foundational engine capability. The engine should automatically exploit useful parallelism and batching across the complete workload while minimizing scheduling, synchronization, memory movement, latency and power overhead. The goal is not maximum thread count; it is maximum useful work completed within the audio deadline and available resource budget.

### Dependency-aware execution

- Compile the typed signal/event graph into a dependency-aware execution plan. Run independent branches concurrently; preserve required ordering, sample accuracy and explicit feedback/delay boundaries.
- Schedule work at useful task sizes. Avoid creating tiny tasks whose dispatch and synchronization cost exceeds their processing cost.
- Support parallel work across independent tracks, buses, voices, instruments, effects, channels, generators, analysis tasks and offline render ranges where dependencies permit.
- Support nested or internally parallel modules through declared execution capabilities. Prevent uncontrolled nested thread pools and oversubscription.
- Use serial execution for small workloads or latency-critical paths when it is faster or more predictable.
- Use bounded worker pools and real-time-safe coordination. The audio callback must never wait on an unbounded queue, worker startup, blocking barrier or non-real-time task.
- Ensure tasks required for the next audio deadline are scheduled with appropriate priority; background analysis, waveform generation, indexing, asset preparation and UI work must not starve audio.

### Batching and vectorized processing

Batch wherever it reduces overhead without changing required timing or semantics:
- Process multiple voices, events, parameter updates, channels or compatible module instances together.
- Group similar operations and reuse prepared kernels, coefficient sets, lookup data and shared modulation results.
- Use SIMD/vector instructions and cache-friendly layouts when supported, with portable scalar fallbacks.
- Batch control/event dispatch while preserving timestamps, ordering, note-off safety and sample-accurate events.
- Batch graph preparation, project loading, asset work and offline rendering outside the real-time callback.
- Do not force batching where it adds latency, increases memory pressure, breaks dependencies or makes the workload less efficient.

### Adaptive hardware use

Detect available CPU cores, instruction sets, memory capacity and supported accelerators. Select CPU parallelism, SIMD, GPU/DSP or other hardware paths only when profiling and workload characteristics show a net benefit. Account for transfer, setup, synchronization, power and thermal costs. Keep a correct portable CPU fallback and avoid requiring any specific accelerator.

Choose worker count, task granularity, batch size, buffering and quality settings based on workload size, device capacity, current load and audio deadline. Adapt without audible discontinuities. Avoid excessive thread creation, context switching, busy waiting, cache contention, false sharing and unnecessary buffer copies.

### Determinism, stability and deadline safety

- Define deterministic ordering and reduction behavior wherever output depends on the order of operations. Parallel floating-point reductions must have documented reproducibility semantics.
- Never parallelize across a dependency that changes results or violates sample-accurate timing.
- Keep callback work bounded. If a worker or accelerator misses a deadline, use a defined safe fallback, previous valid state, bypass or controlled degradation rather than blocking the callback.
- Avoid races in shared module state; declare whether modules are serial, internally parallel or safely reentrant, and enforce those declarations in the execution plan.
- Make project save/load, graph changes, module replacement and resource reclamation safe across audio-thread boundaries.
- Prefer stable predictable execution over a small benchmark gain that increases glitches, jitter or failure risk.

### Measurement and validation

Profile real workloads on low-end phones, ordinary mobile devices, desktop CPUs and accelerator-equipped systems. Measure end-to-end audio deadline margin, worst-case and tail processing time, glitch/dropout rate, CPU utilization, memory use, power where measurable, scheduling overhead, synchronization cost, cache behavior and scaling efficiency.

Test serial versus parallel parity, deterministic modes, high voice counts, large routing graphs, mixed audio/MIDI/control workloads, simultaneous background tasks, CPU saturation, worker failure, thermal/resource pressure and live/offline rendering. Require evidence that each batching or parallel path improves total cost for its target workload; otherwise retain the simpler path.
