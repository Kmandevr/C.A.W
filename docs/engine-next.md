---
title: Modular adaptive engine blueprint
summary: Owner direction for CAW's native sound engine, reusable modules, interactive creation interfaces, portable assets, expressive MIDI, exports and adaptive hardware use.
covers: [engine/, app/, caw/factory/, examples/]
updated: 2026-10-30
---

# Modular adaptive engine blueprint

**Status: owner direction and implementation blueprint.** This combines earlier CAW decisions with the clarified 2026-10-30 direction. It describes planned work, not features already built. Current implementation remains documented in [engine](engine.md), [app](app.md) and [performance](performance.md).

## 1. Product boundary

C.A.W (Code Auditioning Workspace) is a programmable sound-design and content-creation environment. It creates sound assets and reusable audio capabilities for other applications.

**CAW is not a DAW and must not gradually turn into one.** It does not need a full arrangement, recording, mixing or mastering environment, general plugin hosting, or feature-rich live-performance workflow. Lightweight preview and combination tools are useful. Recording/capturing generated audio while sound is playing remains supported. The purpose is to create, audition, refine, package and export content—not replace REAPER or another DAW.

CAW should natively create bytebeat and deterministic mathematical audio; procedural sounds, drums, instruments, effects, samples and wavetables; custom synthesizers and processing modules; MIDI patterns and expressive per-note data including MPE; reusable building blocks; and eventually distributable plugins. It should export content other software can consume, rather than recreate those applications' entire workflows.

## 2. Earlier principles that remain in force

1. **Code remains first-class.** Readable .caw source is a source of truth for people and AI. Visual tools are additional creation/editing routes, not replacements or mandatory gates.
2. **Code → hear → tweak.** Fast audition matters when requested, but not every operation needs ultra-low latency.
3. **Phone-first, not phone-limited.** Touch-first Android use with the same underlying creative capability on desktop. Adapt UI to screen/input, not feature availability.
4. **Deterministic experimentation.** Seeded procedural and bitwise sound remains repeatable. Optimizations preserve defined semantics; golden renders protect intentional sound.
5. **Native and local.** Core creation works offline and does not require a server, account, AI provider or DAW.
6. **Reusable and composable.** A waveform, LFO, envelope, filter, effect, MIDI curve or generator can be reused outside its first intended purpose.
7. **AI is optional.** The longer-term goal may let an LLM/agent work directly with CAW projects and files (Claude-Code/GitHub-like), rather than copy/paste prompts. CAW remains fully useful without AI.
8. **Factory is a starting point.** Starter content remains under caw/factory. Users can start blank, modify a template, write code, use visual tools or hand-build a specialized implementation.
9. **Local/global assets are explicit.** Local assets belong to a project; global assets are reusable across projects. Stable IDs and versions prevent path changes breaking projects.
10. **Other applications are the destination.** CAW creates portable content for DAWs, games, custom software and plugin formats. It is not a general plugin host.
11. **Permissive dependencies only** unless the owner approves an exception. The proprietary project licence remains unchanged.
12. **Low-end hardware is a first-class target.** Every feature needs a resource budget and graceful behavior on weak devices.

## 3. Engine architecture

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

### Stereo and typed connections

Stereo is native, not an effect bolted onto mono output. Signal ports declare channel layout and conversion behavior. Support mono and stereo first, with room for additional layouts. Pan, width, left/right and mid/side processing are explicit. Never silently collapse or duplicate channels.

Keep connection types distinct:
- **Audio:** continuous audio buffers.
- **Control:** scalar or block-rate parameter values.
- **Modulation:** time-varying signals driving parameters.
- **Events:** note-on/off, gate, trigger, transport and timestamped events.

Modules declare ports, parameters, supported layouts, state, cost hints and serialization version. Validate graphs off the audio thread.

## 4. Modular creation and UI

A module is a portable, versioned unit with identity, metadata, typed ports, parameters, processing implementation, state serialization, optional UI description, optional custom UI, resource requirements and documentation. It can be a waveform, processor, instrument voice, drum generator or composite graph.

A curve may serve as a waveform, LFO, envelope, MIDI expression curve or parameter map where types permit. A filter can be inside a synth, a standalone effect or part of a custom processor.

Three creation routes must coexist:
- **Code-defined:** .caw and native APIs for exact control, procedural generation, repeatability and AI editing.
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

The previously accepted starting synth configuration remains a useful first implementation: three wavetable oscillators, sub/noise, unison up to 16, warp modes, two serial/parallel filters, three envelopes, four drawn LFOs, four macros, modulation matrix, drive/chorus/delay/reverb/EQ/compressor. These are not architectural ceilings. Voice, unison and resource limits must be explicit and workload-aware, not arbitrary product caps.

## 6. MIDI and expression

MIDI is a native event and asset model, not a DAW arrangement feature. Preserve and extend the existing pattern engine:
- Independent polyphonic voices and per-note expression.
- Pitch bend (editor default ±12 semitones; file range up to ±48), pressure/volume, timbre and vibrato curves.
- Multiple editable expression lanes, bounded by explicit resource budgets.
- Shared curve representation for note expression, LFOs, envelopes and parameter modulation.
- MPE-compatible export and MIDI 2.0-oriented internal precision, including fractional pitches.
- Shared expensive effects after voices are summed where routing permits, rather than duplicating reverb/delay per note.
- Equation-generated modulation and procedural MIDI generation.
- Pattern editing and preview, not a full DAW timeline or live-performance workstation.

## 7. Factory, projects and asset scope

Factory source stays under caw/factory, with meaningful nested categories. Each substantial asset keeps its source and documentation together. Project-wide documentation stays in docs/.

Proposed organization (adapt existing content; do not blindly move files):

    caw/factory/
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
- **Factory:** shipped starter content, never silently overwritten by user edits.

Use stable IDs, explicit versions, dependency manifests and portable references—not absolute paths. Support linked global assets, pinned versions and embedded snapshots. Detect missing dependencies and offer recovery. Never silently change old project sound when a global asset changes.

## 8. Export and external use

CAW is a creator/exporter, not a plugin host. Support WAV, wavetables, multisamples (WAV/SFZ where appropriate), standard MIDI and expressive MPE/MIDI 2.0-compatible exports, portable module packages and documented presets. Eventually generate CLAP plugins first, then VST3 and other formats where practical.

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

Latency is a workload property, not a universal requirement. Report known/estimated output-route latency and support suitable buffering/compensation for preview, capture and export. Do not assume low-latency headphones. For timing-sensitive audition, minimize latency within the route's capability; otherwise favor stability and efficiency. Capture while generated sound plays must remain synchronized and independent of UI frame rate.

### Quality and determinism

Keep deterministic mode and golden-render contract. SIMD, multithreading and GPU paths must be bit-equivalent where promised, or explicitly identified as a different render mode with separate tests and a user-visible choice. Parallelize independent work; never introduce races or nondeterministic ordering into shared state. Optimization is not permission to change sound silently.

## 10. Safety, stability and security

The callback and everything it calls must avoid allocation, locks, I/O, logging, UI calls, exceptions and unbounded work. Prepare graphs, buffers, voice pools and state before publishing to audio. Use reviewed real-time-safe handoff; retire old graphs and free memory off callback.

Untrusted/downloaded code stays sandboxed: no I/O, filesystem, network or system calls; bounded source/program size, memory, call depth, loops and per-block cost; fail closed with clear errors. Native modules/plugins require a separate trust boundary and are not automatically safe because they implement the module API.

## 11. Verification: what “without compromise” means

No one can promise bugs are impossible. The engineering commitment is explicit invariants, tests and measured results. Every meaningful change must preserve or add:
- Existing language semantics and golden renders.
- Stereo correctness; no clipping or NaN propagation.
- Deterministic seeded output where promised.
- Audio-thread safety and sanitizer coverage.
- Graph validation, cycle handling, bounded resources and safe graph swaps.
- Stable project/asset serialization and migration tests.
- C ABI/module API version compatibility.
- Benchmarks for low-end-like budgets and larger desktop workloads.
- Stress tests for voices, unison, module count, modulation fan-out, long renders and live edits.
- Cancellation/failure tests for compilation and export.
- UI responsiveness while background jobs run.
- Real Android hardware tests for heat, battery, latency and audio-route changes. CI alone is not proof of device performance.

## 12. Implementation order

1. **Audit and contracts:** map runtime, synth, patterns, C API, app bridge, project serialization, benchmarks and tests. Define signal/port types, module contract, asset IDs/versioning, execution modes and capability profile before adding a graph.
2. **Adaptive execution foundation:** separate task scheduling from callback; establish workload policies, bounded workers, hardware profile, telemetry and benchmarks. Preserve current behavior by default.
3. **Typed native module graph:** graph description, validation, prepared plan, audio/control/modulation/event ports and safe graph publication. Keep existing layer/VM path working during migration.
4. **Reusable DSP/synthesis:** expand waveform, oscillator, envelope, LFO, filter, effect, stereo and modulation implementations behind module contracts.
5. **Voice/MIDI expression:** extend current voice/pattern architecture with reusable curves, MPE and shared effects.
6. **Interactive module UI:** schema-driven controls and custom-editor extension points; hand-built UI remains optional and app-side.
7. **Asset/factory integration:** deliberate factory migration, local/global scopes and portable references, then app file manager.
8. **Export/integration:** module packages, MIDI/audio exports, then CLAP and VST3 generation.
9. **Hardware tuning:** benchmark on actual low-end and target devices; tune per-platform policies and document measured results.

Do not attempt a one-shot rewrite. Keep existing project files, .caw modules and C API working through versioned migration. Each stage must leave a buildable, testable product.

## 13. Existing work to preserve

This blueprint does not supersede built v1 or other CAW decisions. Preserve bytebeat/bitwise language, deterministic math, compiler/VM, code-first editing, AI-friendly files, local/offline rendering, WAV export, preview/loop/pattern/hot-swap capabilities without expanding them into a full DAW, current synth patch format/translator, fractional pitches and note-expression curves, shared effects after voices where appropriate, touch-first phone controls and desktop keyboard support, customizable actions/macros, custom themes, Light mode, factory content under caw/factory, local/global assets, optional direct AI project editing, CLAP-first plugin generation, VST3 later, permissive licensing, and GitHub Actions as the build path so the owner can work from Android without a PC/IDE.

See [vision](vision.md), [architecture](architecture.md), [synth](synth.md), [performance](performance.md), [decisions](decisions.md) and [roadmap](roadmap.md). Where those notes conflict with this clarified product boundary and adaptive-engine direction, this blueprint records the newer owner direction; owning notes must be reconciled as implementation proceeds.
