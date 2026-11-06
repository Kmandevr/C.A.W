---
title: C++ creation platform
summary: Owner-approved C++ authoring direction and implementation status for the shared SDK, component model and code, visual and performance interfaces.
covers: [engine/include/caw/, engine/cmake/, examples/cpp/minimal/, scripts/caw-component-build.js, .github/workflows/cpp-components.yml]
updated: 2026-11-06
---

# C++ creation platform

**Status (2026-11-06):** The public C++ processor contract is exposed through `engine/include/caw/module.hpp`. CP.1 now includes an installable `CAW::SDK` CMake package, versioned `caw.component` manifest/helper, descriptor/create/destroy exports, and a minimal stereo fixture. The app persists component source and exact dependency pins, materializes them into a private workspace, builds locally with CMake, reuses a persistent build directory and returns a verified artifact path. The Engine's `ModuleRegistry` and C API can load a built shared library only with an explicit trust value: Blocked refuses to open it, Isolated is rejected because no process sandbox exists, and Trusted loads it in-process. The first audio playback slice is implemented: `ProjectDoc.masterComponents` routes zero-parameter stereo effects through the live master chain, with the safety limiter after native code. Parameter mapping and track-chain integration remain outstanding. The Dart FFI load/unload wrapper exists; the per-component trust UI/store is still missing. The app-local compiler/toolchain provisioning (especially an Android-hosted compiler), proactive dependency manager, full Library coverage, editor, visual scripting, generated/custom UI and self-contained project handoff remain incomplete. The Linux x64, Windows x64 and Android ARM64 GitHub Actions matrix is repository CI only; it is not a CAW user build service. **The product requirement remains local/offline C++ compilation.** This note supports the single [C.A.W. roadmap](roadmap.md), not a second feature roadmap.

## 1. The four distinct layers

C.A.W. must keep four concepts separate. They cooperate, but none is a substitute for another.

1. **Programming language — ordinary C++.** C++ is the actual authoring language. It is general-purpose: users can write audio components, tools, data processing, utilities or other programs. It is not a music-only language or a restricted C.A.W. DSL. The repository currently uses C++20, which is the proposed starting standard; changing the standard later is a toolchain decision.
2. **C.A.W. Library/SDK.** A comprehensive set of documented, reusable C++ APIs, algorithms, data types and built-in components. It makes common work convenient without limiting what ordinary C++ can express. It is not a wrapper around the engine and not the language itself.
3. **Shared component model.** A common description and lifecycle for reusable processors, instruments, effects, generators, tools and other components. It makes a component discoverable and usable through every C.A.W. interface.
4. **Native engine/runtime.** The execution infrastructure that prepares and runs components, routes audio and events, resolves parameters, manages resources and exposes host/device services. It remains separate from editor, visual graph and UI code.

The same implementation must serve every interface. A filter written as a C++ component is not reimplemented as a visual block or a special mixer effect.

## 2. One shared component contract

A component has an implementation plus a descriptor. The descriptor is the machine-readable contract used by the component browser, code tools, visual scripting, generated UI, mixer, automation, MIDI routing, presets and plugin adapters.

A descriptor should cover:

- **Identity and discovery:** stable component ID, display name, version, description, category, tags, author and capability declarations.
- **Role:** instrument/voice, generator, effect, utility processor, event processor, analysis tool or other declared role. A component may support more than one role where its behavior genuinely allows it.
- **Typed ports:** named inputs and outputs, direction, type, channel layout, units, rate, multiplicity, optional/default behavior and sidechain designation.
- **Parameters:** stable parameter ID, name, description, value type, default, minimum/maximum, step, unit, display format, curve, choices, smoothing and visibility.
- **Parameter capabilities:** whether a parameter supports automation, modulation, MIDI mapping, host exposure, sample-accurate changes or block-rate changes.
- **Assets and data:** declared sample, wavetable, impulse-response, table, preset and other resource inputs; ownership, lifetime, version and missing-resource behavior.
- **Events and MIDI:** accepted/emitted event kinds, MIDI 1.0 and MIDI 2.0 UMP support, note identity, per-note expression and timestamp/frame semantics.
- **Lifecycle and state:** construction, prepare, reset, processing, release, state save/load, state schema version and safe reconfiguration rules.
- **Runtime requirements:** sample-rate and block-size constraints, latency, tail behavior, resource estimates, threading model, real-time requirements and failure/bypass behavior.
- **UI metadata:** parameter grouping, labels, ordering, control hints, units, ranges, meter types, visibility and optional custom-view identifiers.
- **Export capabilities:** whether it can be used as an instrument/effect/node in C.A.W. and which standalone or plugin-host adapter capabilities it supports.

The descriptor is not a second implementation. It describes the actual C++ component and is validated against it. A component that omits optional UI metadata still works; it receives a useful generated interface.

### Typed connections

The component system must support at least:

- **Audio:** mono, stereo, quad, 5.1, 7.1 and discrete N-channel layouts. Channel layout is explicit; stereo remains the low-overhead default.
- **MIDI and events:** notes, note-off, velocity, pitch, pressure, per-note expression, CC, program changes, clock, transport and timestamped application events.
- **Control:** scalar or structured control values with defined update rate and hold/default behavior.
- **Modulation:** per-frame or declared-rate modulation signals with explicit source-combination and scaling rules.
- **Data and tables:** typed buffers, sample data, wavetable data, lookup tables, envelopes, analysis results and other declared data objects.

Connections are type-checked before execution. No silent reinterpretation between domains is allowed. A conversion is an explicit component or adapter with declared cost and semantics. Port contracts define channel layouts, rates, ownership, buffer lifetime and whether a port may fan in or fan out.

### One parameter definition everywhere

A parameter's descriptor is the source of truth for:

- generated knobs, sliders, switches, selectors, meters and other controls;
- visual graph parameter nodes and exposed component controls;
- automation lanes, modulation targets and MIDI/controller mappings;
- preset/state serialization; and
- CLAP/VST3 host parameter exposure.

Manual changes, automation, modulation and MIDI must use the same parameter-resolution path. UI controls must update the running component without reopening its source or rebuilding unrelated parts of the graph. Internal parameters may remain hidden; every exposed parameter remains directly controllable.

## 3. The three coordinated authoring interfaces

These are three views of the same project and component model, not three engines.

### A. C++ code editor

The editor is a practical integrated C++ development environment, not a replacement for a heavyweight IDE in every specialist workflow. It must provide:

- syntax highlighting, indentation and formatting;
- completion and signature help aware of the C.A.W. SDK and the current project;
- fast live syntax/semantic diagnostics, a Problems list, clickable errors and source locations, with the earliest actionable cause prioritized over cascades;
- project-aware dependency detection while files are opened and edited; when online, missing packages may be downloaded and installed in the background before the user requests a build;
- go-to-definition, find references, project-wide search and find/replace;
- tabs, multiple files, a project tree and imported source folders;
- build, run, component validation, preview and useful build output;
- refactoring, folding, snippets and navigation; and
- debugging support appropriate to the target, including breakpoints and inspection for ordinary non-real-time code.

Users can add or drop in existing C++ files and projects. C.A.W. should respect supported build configuration and dependencies, explain unsupported build requirements, and make the resulting component available through the shared registry when it supplies a valid descriptor. C++ remains general-purpose; code is not restricted to producing an audio component.

The editor should catch inexpensive syntax and semantic errors before full compilation, resolve includes/configuration and linker requirements early, and keep diagnostics attached to their source locations. Do not launch a full compile for every keystroke. Use incremental compilation and a local cache so unchanged translation units are reused; perform expensive linking and validation after earlier checks pass. All compilation and linking happen locally, including when the device is offline.

### B. Visual scripting and composition

The visual editor is a typed composition surface for built-in Library functions and user-created components.

- Drag components onto a graph and connect compatible ports.
- Show audio, MIDI/event, modulation, control and data connections distinctly.
- Validate incompatible types, channel layouts and rates before execution; offer explicit conversion components where appropriate.
- Expose component parameters and allow subgraphs to be grouped and saved as reusable components.
- A C++ component with a valid descriptor automatically becomes a visual block; no duplicate block implementation is required.
- Keep code and graph authoring interoperable: components and their parameters remain inspectable, reusable and editable through their C++ source.
- Compile/prepare graphs into the same native execution infrastructure used by C++ components. Do not create a separate interpreted visual-graph runtime.

### C. Performance and mixer interface

The performance surface is the live control face of the same components. The user chooses which parameters are exposed and how they are presented.

- Generate useful controls automatically from parameter metadata: knobs, sliders, switches, selectors, buttons, pads, keyboards, XY controls and meters.
- Support custom labels, grouping, ordering, ranges, units and layout.
- Apply parameter changes live through the shared parameter system.
- Provide MIDI keyboards/pads and controller mappings where relevant.
- Show component status, meters, bypass and declared latency/resource information where useful.
- Keep the interface lightweight on phones and adaptable to desktop layouts.

The existing Mixer remains a workspace for track and signal-flow control. This design extends it so components can be loaded, controlled and reused like normal plugins; it does not require a second processing path.

## 4. Generated, custom and hybrid interfaces

A valid component gets a usable generated UI by default. The component author does not have to hand-design an interface just to make its parameters accessible.

The generated renderer chooses controls from metadata and parameter type:

- continuous numeric values: knob or slider, with unit/range and optional numeric entry;
- boolean values: switch or button;
- enumerations: selector or menu;
- trigger/action values: button or pad;
- incoming/outgoing levels and diagnostics: meter or status display;
- note-oriented components: keyboard, pads or note controls when declared.

Authors may optionally provide a fully custom interface in C++ or through a visual UI designer. A hybrid interface can retain generated controls and replace or augment selected sections with custom controls. UI code runs outside the audio callback and communicates through the same parameter/event contracts. The processor remains independent of its UI.

A plugin host may have different UI requirements from C.A.W. The shared metadata feeds host-specific UI/parameter adapters; do not assume a Flutter view can be embedded unchanged in every host.

## 5. C.A.W. Library/SDK scope

The Library is a broad, practical toolbox, not just a thin wrapper around the current engine. Prefer one canonical implementation of each algorithm and expose it to C++ components, visual blocks and generated controls where applicable. Use the C++ standard library for standard general-purpose facilities instead of needlessly cloning it.

Make the Library the easiest and fastest route into the engine: built-in, Library and user-authored components use the same registration, descriptor, typed-port, parameter and lifecycle contracts. A user should be able to add or insert a component and use its declared inputs/outputs without manually recreating engine integration. Preinstall the common packages most CAW projects are likely to use; keep less common packages modular and locally cached. Predict requirements from project files and install missing dependencies in the background when connected, while keeping already-installed projects buildable offline.

### Audio and DSP

Provide reusable implementations and building blocks for:

- oscillators, waveform functions, band-limited and raw waveforms, noise and wavetable generation;
- interpolation, resampling, window functions, table construction and lookup;
- filters, EQ, DC removal, saturation, distortion, waveshaping, bit crushing and clipping;
- compression, limiting, gating, transient shaping and dynamics;
- delay, feedback delay, reverb, convolution, chorus, flanger, phaser and modulation effects;
- FFT and other spectral/time-frequency analysis;
- granular, additive, FM/AM, wavetable and physical-modeling building blocks; and
- stereo and multichannel processing, channel mapping and explicit format conversion.

### Instruments, samples and musical systems

Provide reusable synth voices, oscillators, envelopes, LFOs, modulation sources, samplers, drum generators, sample buffers, wavetable tools, sample/zone mapping, MIDI event utilities, sequencers, note generators, arpeggiators, chord/scale/rhythm helpers and per-note expression tools.

Support MIDI 1.0, MIDI 2.0 UMP and MPE-style expression through one event model. Device input/output adapters feed that same model; a C++ component, visual block and performance UI must not each invent separate MIDI routing.

### Math, bits and data

Provide numerical utilities, vectors, matrices, complex numbers, transforms, interpolation, deterministic random distributions, hashing, bit masks, shifts, rotations, packing/unpacking, byte operations, float-bit reinterpretation, lookup tables and buffer/data algorithms. Preserve direct access to ordinary C++ bit manipulation and low-level operations.

### General-purpose utilities

Provide well-documented reusable facilities where they add value: parsing/serialization helpers, data transforms, search and sorting utilities, resource handles, diagnostics and common project/component helpers. This does not restrict users to the built-in catalogue; ordinary C++ and supported third-party libraries remain available subject to build and licence rules.

Library functions should have clear input/output contracts, units, defaults, error behavior, allocation behavior, thread-safety and real-time-safety declarations. A function may accept parameters, tables, buffers, events or other data and return generated audio, waveforms, transformed data, analysis results or events. Where algorithms have meaningful tradeoffs, expose the alternatives and their cost rather than claiming one universal best implementation.

## 6. Runtime, performance and trust boundaries

C++ is not restricted by the audio callback's rules. A user can write general-purpose C++ code. However, code that runs in the real-time audio callback must obey an explicit real-time contract:

- no dynamic allocation or deallocation;
- no blocking locks, waits or unbounded synchronization;
- no filesystem, network or device I/O;
- no UI calls, logging or blocking diagnostics;
- bounded processing with declared resource and latency behavior; and
- all memory, assets, tables, state and execution plans prepared before activation.

The SDK must distinguish real-time and non-real-time APIs and identify which callbacks may run on which threads. The host validates and prepares a component before activation and defines failure, bypass and recovery behavior.

Native C++ is not sandboxed because it uses the SDK. A native component can access process memory and operating-system services. The Engine now enforces an explicit trust argument at its loader boundary: Blocked refuses before opening the library; Isolated is rejected until a separate-process host is implemented; Trusted loads in-process. The C API requires the caller to pass one of these values, and build success never invokes the loader. The Dart FFI load/unload wrapper now exists; the Flutter trust UI/store, parameter mapping and track-chain integration are still outstanding. The current adapter supports zero-parameter stereo master effects. Sandboxed legacy .caw modules remain constrained only while the old VM still exists.

Performance requirements apply from the start: prepared execution, direct native processing, borrowed/zero-copy buffers where ownership permits, bounded pools, explicit lifetimes, lazy loading, serial fast paths for small workloads, adaptive scheduling for independent work, and SIMD/accelerators only when measurement shows a net benefit. Avoid unnecessary virtual dispatch, pointer chasing, copies, locks and abstractions on hot paths. Benchmark realistic low-end and desktop workloads; do not trade worse end-to-end performance for architectural neatness.

Resource use must be visible and user-configurable: show meaningful CPU, memory, audio and build usage, explain consequences, and allow users to override advisory budgets. Do not hide arbitrary caps behind the UI. Preserve real format/representation limits and the explicit real-time audio safety contract. Each native component's trust mode is chosen by the user; build success or package installation never changes it.

## 7. Extensibility and versioning without rewrites

Extensibility without broad rewrites is a permanent architecture requirement.

- New instruments, effects, generators and processors implement the shared component contract and register with the component system.
- New algorithms enter the Library once and can be surfaced as visual blocks or generated controls without duplicate processing code.
- New parameter types add a parameter contract and renderer/automation behavior without rewriting every component.
- New port/event types extend the typed connection model through explicit capability and conversion declarations.
- New UI controls add a renderer/control implementation; they do not require rewriting the parameter system.
- New MIDI capabilities extend the shared event model and adapters.
- New file formats, platforms and plugin formats use replaceable import/export or host adapters around stable internal contracts.
- New hardware backends implement replaceable interfaces with portable fallbacks.

Version public SDK/extension contracts and serialized component state. Declare capabilities and negotiate optional features explicitly. Keep experimental APIs separate from stable contracts until validated. Versioning is for extension boundaries and future evolution; it does not create a requirement to preserve the old .caw language or pre-release projects.

Plan stable component and serialized-state version identifiers now, but defer a comprehensive compatibility/migration framework until real prototype requirements justify it. Avoid speculative frameworks. Add an extension seam when a real feature needs it, define ownership/lifetime/error behavior, and test that a new component, parameter, port, control or adapter can be added without changing unrelated systems.

## 8. Migration from the current .caw language

**[Fact, checked 2026-11-05]** The repository currently has a constrained .caw language with a lexer, parser, compiler, bytecode VM and C++ built-ins. It is an existing implementation, not the selected long-term programming language.

**[Owner decision, 2026-11-05]** Ordinary C++ replaces the custom .caw language as the authoring language. The owner is the only user and has waived backwards compatibility for old .caw source and pre-release projects. Do not preserve old syntax or old project behavior solely for compatibility.

Migration order:

1. Establish the C++ toolchain, project/source model and SDK/component contracts.
2. Port or replace useful built-in algorithms and sound capabilities into the C.A.W. Library and native components. Preserve useful functionality, not every implementation detail or old limitation.
3. Connect the C++ component model to the native engine graph, parameter resolver, MIDI/event routing, assets, presets and app surfaces.
4. Build the code editor, visual composition and generated/custom performance interfaces on that shared model.
5. Verify that every retained workflow and required feature has a working C++/Library path, with tests and documented behavior.
6. Remove the .caw lexer/parser/compiler/bytecode VM, legacy source templates and obsolete language documentation when no active product path depends on them.

Do not remove the old implementation before its replacement is usable. Do not keep the old VM indefinitely as a second product language. No source/project compatibility layer is required for the retired language.

### Self-contained project handoff

The current project-delivery goal is a REAPER-like handoff bundle, not cloud collaboration: package a project so it carries its source, required assets, build configuration, pinned dependency versions and required dependency payloads. The recipient should not need to find and install the project's dependencies manually. A bundled project must be usable offline once received. AutoStacc-based distribution or synchronization is a future direction, not a current implementation priority.

## 9. Plugin and standalone reuse

A component is authored and implemented once. C.A.W. loads it through the shared component model; visual scripting uses it as a block; the performance UI controls it from its descriptor; the component browser discovers it; and presets/state use the shared state contract.

External formats are adapters, not separate processors:

- CLAP is the first planned export target.
- VST3 follows when its adapter and host validation are ready.
- Standalone builds reuse the same component implementation and runtime.
- Host-specific parameter, MIDI, state, channel-layout, latency and UI requirements are translated at the adapter boundary.

Plugin export is a later roadmap stage. It must not block the initial SDK or the three C.A.W. authoring interfaces.

## 10. Prototype-first delivery

The immediate goal is a working prototype, not completion of every architecture layer. The first slices now prove project source persistence, safe app-private materialization, a local manifest-driven CMake build with incremental directory reuse, artifact discovery, and explicit-trust dynamic loading through the Engine registry/C API. The next vertical step is to place a loaded processor into a project chain and hear it through the existing live mix graph. Then wire the Flutter FFI/trust UI and validate the Android-hosted toolchain offline. Start with one minimal real component and add only what makes that slice reliable. Keep the larger shared component model, dependency/library strategy, trust choice, resource controls and handoff requirements documented, but defer full visual editing, comprehensive compatibility migration, AutoStacc integration, plugin export and other later systems until the prototype works.

## 11. Verification gates

The design is not complete merely because interfaces exist. Tests and CI should prove:

- one C++ component registers once and is discoverable in the code, visual, performance and plugin/component browsers;
- the same processor implementation produces the same processing result through direct use and a compiled visual graph;
- descriptor ports reject invalid type/channel connections and accept explicitly declared conversions;
- one parameter definition drives generated controls, automation, modulation, MIDI mapping and host exposure;
- generated UI works with no custom UI, and custom/hybrid UI does not change processor behavior;
- MIDI 1.0, MIDI 2.0 UMP, note identity and per-note expression traverse the shared event path;
- state/preset save and restore are versioned and deterministic within the declared contract;
- real-time processing performs no allocation, blocking lock, I/O or UI call and remains within declared bounds;
- untrusted native code is never silently loaded in-process;
- adding a new component, parameter, port, UI control or adapter does not require unrelated subsystem rewrites; and
- low-end performance is measured against realistic audio workloads, with no duplicate runtime or unnecessary background cost.

Until these tests and the relevant CI jobs pass, mark the capability planned or partial rather than implemented.
