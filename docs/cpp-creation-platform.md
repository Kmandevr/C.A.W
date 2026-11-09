---
title: C++ creation platform
summary: Owner-approved C++ authoring direction and implementation status for the shared SDK, component model and code, visual and performance interfaces.
covers: [engine/include/caw/, engine/cmake/, examples/cpp/minimal/, scripts/caw-component-build.js, .github/workflows/cpp-components.yml]
updated: 2026-11-09
---

# C++ creation platform

**Status (2026-11-06):** The public C++ processor contract is exposed through `engine/include/caw/module.hpp`. The first CP.1 code slice is present: an installable `CAW::SDK` CMake package, a versioned `caw.component` project manifest, a CMake shared-library helper, exported descriptor/factory entry points, a minimal stereo fixture, and a Node build driver with structured diagnostics. The Linux x64, Windows x64 and Android ARM64 GitHub Actions matrix is repository CI only; it tests the component build path and is not a CAW user build service. Its component jobs were still queued at the last status check. **The product requirement is local/offline C++ compilation**; the app-local compiler/toolchain packaging, proactive local dependency manager, project/source storage, app build integration, runtime registration/loading and user-configured trust host are not yet implemented. Full Library coverage, C++ editor, both visual workspaces, generated/custom UI and self-contained project handoff remain incomplete. Faust, Pure Data/libpd and Tracktion Engine are evaluated in [visual creation and signal routing](visual-routing-and-library-integration.md); none is an adopted dependency. This note supports the single [C.A.W. roadmap](roadmap.md), not a second feature roadmap.

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
- **Parameters:** stable parameter ID, name, description, value type, default, minimum/maximum, step, unit, display format, curve, choices, smoothing, visibility and control scope (project, track, channel, voice or note).
- **Parameter capabilities:** whether a parameter supports automation, modulation, MIDI mapping, host exposure, sample-accurate changes or block-rate changes.
- **Assets and data:** declared sample, wavetable, impulse-response, table, preset and other resource inputs; ownership, lifetime, version and missing-resource behavior.
- **Events and MIDI:** accepted/emitted event kinds, MIDI 1.0 and MIDI 2.0 UMP support, note identity, per-note expression and timestamp/frame semantics.
- **Lifecycle and state:** construction, prepare, reset, processing, release, state save/load, state schema version and safe reconfiguration rules.
- **Runtime requirements:** sample-rate and block-size constraints, latency, tail behavior, resource estimates, threading model, real-time requirements and failure/bypass behavior.
- **UI metadata:** parameter grouping, labels, ordering, control hints, units, ranges, meter types, visibility and optional custom-view identifiers.
- **Export capabilities:** whether it can be used as an instrument/effect/node in C.A.W. and which standalone or plugin-host adapter capabilities it supports.

The descriptor is not a second implementation. It describes the actual C++ component and is validated against it. A component that omits optional UI metadata still works; it receives a useful generated interface.

**Binary boundary (owner decision, 2026-11-09):** compiled components and the host talk through a small, versioned C interface (plain structs, function pointers, fixed-size types; no `std::` types, C++ classes or exceptions across the library boundary), the way CLAP plugins do. The SDK's C++ classes sit on top of it inside the component. This keeps old and shared components working when the app, compiler or C++ standard library changes. **[Fact, checked 2026-11-09]** today's `engine/include/caw/component.hpp` exports `extern "C"` entry points, but they return C++ objects (`caw::ModuleDescriptor` with `std::string_view` fields, the virtual `caw::ModuleProcessor` class from `module.hpp`), so the boundary still has to be converted.

### Typed connections

The component system must support at least:

- **Audio:** mono, stereo, quad, 5.1, 7.1 and discrete N-channel layouts. Channel layout is explicit; stereo remains the low-overhead default.
- **MIDI and events:** notes, note-off, velocity, pitch, pressure, per-note expression, CC, program changes, clock, transport and timestamped application events.
- **Control:** scalar or structured control values with defined update rate and hold/default behavior.
- **Modulation:** per-frame or declared-rate modulation signals with explicit source-combination and scaling rules.
- **Data and tables:** typed buffers, sample data, wavetable data, lookup tables, envelopes, analysis results and other declared data objects.

Connections are type-checked before execution. No silent reinterpretation between domains is allowed. A conversion is an explicit component or adapter with declared cost and semantics. Port contracts define channel layouts, rates, ownership, buffer lifetime and whether a port may fan in or fan out.

### Native note, voice and channel processing

Per-note, per-voice and per-channel processing are native processing scopes in the shared component/runtime contract, not separate APIs that individual instruments or effects must invent.

- **Processing scopes:** a component descriptor declares whether processing applies to a complete stream/buffer, individual channels, individual sounding voices, individual notes, or a supported combination. Instruments, generators, effects and utility processors use the same capability model. A component may offer a simple whole-buffer fast path and a more specific note/voice/channel path.
- **Preserved context:** where a component declares that it consumes note/voice context, the runtime supplies stable note identity, voice identity, event/frame timing, expression values and channel identity/layout alongside the relevant audio/event data. That context remains correlated until an explicit mix, aggregation or conversion boundary. A component may intentionally combine voices or channels, but the boundary and resulting loss of granularity are explicit.
- **Per-note expression:** note identity and expression are not limited to the MIDI input edge. Pitch, pressure, timbre, gain, pan/spatial position and other typed expression/automation values can be addressed independently for simultaneous notes. MIDI 1.0, MIDI 2.0 UMP and MPE-style adapters translate at the boundary while the internal model retains stable note identity and higher-resolution values.
- **Per-voice processing:** synth voices and unison layers can be independently addressed for phase, detune, gain, pan/spread, modulation and processing before they are intentionally combined. The runtime must not force a synth to collapse its voices before a voice-aware processor can act.
- **Per-channel processing:** components can independently process channels in a declared layout, or operate on the complete layout when their algorithm requires it. Layouts include mono, stereo, standard surround and discrete N-channel configurations. Channel capacity is bounded by measured/declared CPU, memory and host/device budgets, not an arbitrary fixed product ceiling.
- **Native stereo generation:** instruments and generators can produce genuinely distinct left/right signals at the source. Stereo oscillators, independent or linked L/R modulation, unison voice distribution, phase/detune offsets, stereo effects and width/spatial controls are Library/SDK primitives. Stereo must not mean duplicating a mono signal and adding a workaround afterward.
- **Effects declare what they do:** descriptors state accepted/produced layouts and whether an effect processes a whole stream, channels independently, voices or notes. A stereo widener, stereo distortion, chorus or delay receives native stereo data; a note-aware effect can receive the relevant note/voice context. No effect silently converts stereo or N-channel audio to mono. Any downmix, channel remap, or loss of note/voice granularity is an explicit conversion/merge with defined semantics.
- **Track and output defaults:** new tracks use stereo by default. A track may carry more channels than the current physical output device; explicit mapping/downmix happens at the device/output boundary rather than restricting the internal track layout.
- **Simple connection behavior:** compatible layouts and processing scopes connect directly with sensible defaults. The host performs ordinary compatible wiring and exposes advanced pin/channel maps only when needed. It must explain incompatible layouts and offer an explicit conversion instead of requiring users to duplicate signals or discover obscure routing tricks.
- **Real-time contract:** note/voice/channel context, buffers and processing plans are prepared off the audio thread. The callback remains bounded and allocation-free; resource limits produce actionable errors rather than silent truncation.

### Native stereo synthesis and unison

A C++ instrument must be able to build stereo sound from its oscillators and voices, not merely pass a mono result through stereo effects. The SDK should make these common operations direct:

- independent or linked left/right oscillator signals and phase;
- per-voice detune, phase offsets, pan and stereo spread for unison stacks;
- per-note pitch glide/bend and modulation while other notes continue independently;
- stereo filters, distortion, chorus, phaser, delay, reverb and mid/side processing; and
- explicit split, merge, map and recombine operations for more elaborate channel structures.

A typical instrument—multiple detuned voices distributed across stereo, with per-note pitch expression and stereo chorus/distortion—must be straightforward to implement with the SDK's native building blocks. Advanced custom routing remains possible, but is not a prerequisite for ordinary stereo sound design.

### One parameter definition everywhere

A parameter's descriptor is the source of truth for:

- generated knobs, sliders, switches, selectors, meters and other controls;
- visual graph parameter nodes and exposed component controls;
- automation lanes, modulation targets and MIDI/controller mappings;
- preset/state serialization; and
- CLAP/VST3 host parameter exposure.

Manual changes, automation, modulation and MIDI must use the same parameter-resolution path. UI controls must update the running component without reopening its source or rebuilding unrelated parts of the graph. Internal parameters may remain hidden; every exposed parameter remains directly controllable.

## 3. The coordinated authoring interfaces

C.A.W. has a C++ code editor, two visual workspaces built on one shared visual framework, and generated/custom performance controls. These are coordinated views of the same project and component model, not separate engines.

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

### B. Component visual workspace — build instruments and effects

This is the visual DSP/component editor: a typed composition surface for built-in Library operations, Faust-generated native components and user-created C++ components. It is for building or changing a component's internal behavior, not for routing whole song tracks.

- Drag components onto a graph and connect compatible ports.
- Show audio, MIDI/event, modulation, control and data connections distinctly.
- Validate incompatible types, channel layouts and rates before execution; offer explicit conversion components where appropriate.
- Expose component parameters and allow subgraphs to be grouped and saved as reusable components.
- A C++ component with a valid descriptor automatically becomes a visual block; no duplicate block implementation is required.
- Keep code and graph authoring interoperable: components and their parameters remain inspectable, reusable and editable through their C++ source.
- Compile/prepare graphs into the same native execution infrastructure used by C++ components. Do not create a separate interpreted visual-graph runtime.

### C. Project/track visual workspace — route and shape the song

This is a second visual workspace using the same canvas, node/port, connection, grouping, selection and inspector framework, but it edits the project routing model rather than a component's internal DSP graph.

- Keep the arrangement and piano roll as the normal song-making workflow; the visual track workspace is an additional page/inspector, not a replacement.
- Show track parameters, input/output, sends and destinations, buses, sidechains, channel maps and effect chains together. Users can adjust send level/destination and reorder or insert effects without navigating away from the track.
- Provide both a visual route view and conventional mixer controls. Every edit updates the same persisted project state and live engine routing; no UI-only routing copy.
- Support audio, MIDI/event, control, modulation, analysis and logic connections through typed contracts and explicit conversion nodes.
- Allow conditional branches and regional routes: e.g. MIDI from the kick track triggers a bass duck; a track's RMS crossing a threshold blends in a preloaded distortion path; entering a clip/region activates a parallel effect route.
- Project routes can connect component endpoints, but the project graph remains distinct from the component's internal DSP graph. The condition graph is a third model that selects/actions routes through declared endpoints.
- Track state such as highlight/selection may be an explicit UI event source for auditioning only; it never changes an export (owner, 2026-11-09).

### D. Performance and mixer interface

The performance surface is the live control face of the same components. The user chooses which parameters are exposed and how they are presented.

- Generate useful controls automatically from parameter metadata: knobs, sliders, switches, selectors, buttons, pads, keyboards, XY controls and meters.
- Support custom labels, grouping, ordering, ranges, units and layout.
- Apply parameter changes live through the shared parameter system.
- Provide MIDI keyboards/pads and controller mappings where relevant.
- Show component status, meters, bypass and declared latency/resource information where useful.
- Keep the interface lightweight on phones and adaptable to desktop layouts.

The existing Mixer remains a workspace for track and signal-flow control. The visual track workspace complements it and edits the same project graph; neither creates a second processing path. See [visual routing design](visual-routing-and-library-integration.md) for graph domains, conditional rules, scheduling and examples.

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
- native stereo generation and multichannel processing, per-channel/per-voice/per-note DSP, channel mapping and explicit format conversion.

### Instruments, samples and musical systems

Provide reusable synth voices, stereo-capable oscillators, envelopes, LFOs, modulation sources, samplers, drum generators, sample buffers, wavetable tools, sample/zone mapping, MIDI event utilities, sequencers, note generators, arpeggiators, chord/scale/rhythm helpers, unison/voice distribution and per-note expression tools.

Support MIDI 1.0, MIDI 2.0 UMP and MPE-style expression through one event model. Device input/output adapters feed that same model; a C++ component, visual block and performance UI must not each invent separate MIDI routing.

### Math, bits and data

Provide numerical utilities, vectors, matrices, complex numbers, transforms, interpolation, deterministic random distributions, hashing, bit masks, shifts, rotations, packing/unpacking, byte operations, float-bit reinterpretation, lookup tables and buffer/data algorithms. Preserve direct access to ordinary C++ bit manipulation and low-level operations.

### General-purpose utilities

Provide well-documented reusable facilities where they add value: parsing/serialization helpers, data transforms, search and sorting utilities, resource handles, diagnostics and common project/component helpers. This does not restrict users to the built-in catalogue; ordinary C++ and supported third-party libraries remain available subject to build and licence rules.

Library functions should have clear input/output contracts, units, defaults, error behavior, allocation behavior, thread-safety and real-time-safety declarations. A function may accept parameters, tables, buffers, events or other data and return generated audio, waveforms, transformed data, analysis results or events. Where algorithms have meaningful tradeoffs, expose the alternatives and their cost rather than claiming one universal best implementation.

## 5A. Optional DSP authoring backend: Faust [Proposal]

Faust is an optional specialist DSP language/compiler, not a replacement for general-purpose C++. The preferred first prototype compiles Faust source to generated C++ and passes that source through the existing local/offline C++ component build pipeline. An adapter maps Faust inputs/outputs, UI metadata, parameters, state, lifecycle and processing buffers to the C.A.W. component descriptor. The native C.A.W. engine remains the only runtime/scheduler.

There is no embedded libfaust/LLVM JIT path (owner, 2026-11-09): the bundled C++ compiler already builds Faust-generated code. Validate Faust's buffer/in-place semantics, vectorization, channel layouts, polyphony, MIDI/per-note expression and real-time behavior. Do not enable a parallel scheduler inside the audio callback. Audit the exact compiler, standard-library and architecture-file licences: the compiler is LGPL-2.1-or-later, while generated-code obligations depend on included inputs/libraries/architecture files. No integration or licence compatibility is assumed complete. Details and reuse evaluations: [visual routing design](visual-routing-and-library-integration.md).

## 6. Runtime, performance and trust boundaries

C++ is not restricted by the audio callback's rules. A user can write general-purpose C++ code. However, code that runs in the real-time audio callback must obey an explicit real-time contract:

- no dynamic allocation or deallocation;
- no blocking locks, waits or unbounded synchronization;
- no filesystem, network or device I/O;
- no UI calls, logging or blocking diagnostics;
- bounded processing with declared resource and latency behavior; and
- all memory, assets, tables, state and execution plans prepared before activation.

The SDK must distinguish real-time and non-real-time APIs and identify which callbacks may run on which threads. The host validates and prepares a component before activation and defines failure, bypass and recovery behavior.

Native C++ is not sandboxed because it uses the SDK. A native component can access process memory and operating-system services. Apply the existing per-item trust decision: Isolated in a separate process, Trusted in-process, or Blocked. Do not silently load untrusted native code. Sandboxed legacy .caw modules remain constrained only while the old VM still exists.

**Safe sharing (owner decision, 2026-11-09):** after .caw is removed, the safe format for sharing is a visual-graph component made only of built-in Library nodes: it contains no native code, so it loads without a trust choice. A shared component that contains C++ (source or binary) always goes through the Isolated/Trusted/Blocked choice.

**Overrun protection (owner decision, 2026-11-09):** the host cannot stop user C++ from breaking the real-time contract, but it measures each component's processing time against its block budget; a component that repeatedly misses it is bypassed (silenced or passed through) with a visible warning, and the user can re-enable it.

**iOS (owner decision, 2026-11-09):** iOS ships without C++ authoring or compilation: playing, arranging and visual building only, using components made elsewhere. **[Assumption: App Store rules forbid apps from downloading or compiling and running new executable code; verify against Apple's current App Review Guidelines before iOS work starts]**.

Performance requirements apply from the start: prepared execution, direct native processing, borrowed/zero-copy buffers where ownership permits, bounded pools, explicit lifetimes, lazy loading, serial fast paths for small workloads, adaptive scheduling for independent work, and SIMD/accelerators only when measurement shows a net benefit. Avoid unnecessary virtual dispatch, pointer chasing, copies, locks and abstractions on hot paths. Benchmark realistic low-end and desktop workloads; do not trade worse end-to-end performance for architectural neatness.

Resource use must be visible and user-configurable: show meaningful CPU, memory, audio and build usage, explain consequences, and allow users to override advisory budgets. Do not hide arbitrary caps behind the UI. Preserve real format/representation limits and the explicit real-time audio safety contract. Each native component's trust mode is chosen by the user; build success or package installation never changes it.

### On-device toolchain [Proposal; owner decisions marked]

**Nothing external is required (owner, 2026-11-09):** the app needs no set-up step, PC, charger, network or other outside connection to work. Optional connections and downloads may make things better or easier, but never required.

- **Compiler in the app (owner: one app, not two editions):** Clang and LLD (Apache-2.0 with LLVM exception), built by GitHub Actions for Android ARM64 and Windows and shipped inside the installer. **[Assumption: about 60–100 MB extra; measure in CI]**. **[Fact, Cxxdroid store listing, checked 2026-11-09]** an existing Android app compiles C/C++ on-device in about 47 MB.
- **Why it can't be a download:** **[Fact, Android 10 behavior changes, checked 2026-11-09]** apps targeting API 29+ cannot `execve()` files in their own data directory.
- **How it runs on Android (owner decision, 2026-11-09):** Clang/LLD are built as a native library inside the APK (no executable, so no `execve()`), and the app loads that library in a dedicated Android process (`android:process=":compiler"`), never in the audio/UI process. A compiler crash or `exit()` only fails the build. Desktop runs the compiler as an ordinary process. **[Fact, checked 2026-11-09]** `app/lib/platform/cpp_toolchain.dart` validates a `caw.toolchain` v1 manifest (per-host execution mode, SHA-256 and size per artifact, safe relative paths; Android requires an entry library and forbids executables), and `CppComponentBuildRunner` in `app/lib/platform/cpp_build.dart` refuses the CMake subprocess path on Android. The compiler library and its process host are not built yet.
- **Bundled with the compiler:** the C.A.W. SDK headers and the C++ standard library, so a first build works offline with no set-up. **[Assumption: the NDK sysroot parts shipped (bionic headers, libc++) are permissively licensed; check their licence files before bundling]**.
- **Optional packs:** set-up offers (and can be skipped) the Faust libraries and starter instruments/effects; anything else downloads on first use. Packs are data (headers, sources, libraries), versioned, hash-checked, cached and included in project handoff bundles.
- **Loading the result:** the built `.so` goes in app-private storage, is marked read-only (**[Fact, Android 14 summary, checked 2026-11-09]** dynamically loaded code must be read-only for apps targeting API 34+; whether this covers native libraries is undocumented, so always do it) and loads under the trust choice.
- **Cheap builds:** precompiled SDK headers, incremental rebuilds, a fast unoptimised audition build and an optimised build on export or request, at low priority so audio never stutters.

**Remote compiling (owner direction, 2026-11-09; future, [Proposal] for the details):** on-device compiling stays the default and must work offline. Later, a project may optionally be compiled elsewhere: on a free service if a suitable one exists, or on the user's own computer (for example a PC on the same network running a small C.A.W. build helper). The result comes back as a component like any other: it is checked against the descriptor and the C interface, and because it was built outside the app it goes through the user's Isolated/Trusted/Blocked choice. No C.A.W.-run paid build server and no shipped secret is assumed. Free services: the user's own GitHub account (Actions in their repository, through the existing GitHub sign-in) is the first candidate; other free build services are to be researched. The user's computer can be reached on the same network or over the internet. Open: which other free services can return a built Android/Windows library, and how the phone and computer pair and connect securely over the internet (relay or direct connection).

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

The immediate goal is a working prototype, not completion of every architecture layer. The first useful vertical slice should prove that a user can create/open a C++ component project, edit ordinary C++, receive early actionable diagnostics, build locally with the network disabled, register and use the resulting component in the engine, and preserve the project. Start with one minimal real component and the narrowest required path. Add only the code and interfaces needed to make that slice reliable. Keep the larger shared component model, dependency/library strategy, trust choice, resource controls and handoff requirements documented, but defer full visual editing, comprehensive compatibility migration, AutoStacc integration, plugin export and other later systems until the prototype works.

## 11. Verification gates

The design is not complete merely because interfaces exist. Tests and CI should prove:

- one C++ component registers once and is discoverable in the code, visual, performance and plugin/component browsers;
- the same processor implementation produces the same processing result through direct use and a compiled visual graph;
- descriptor ports reject invalid type/channel connections and accept explicitly declared conversions;
- one parameter definition drives generated controls, automation, modulation, MIDI mapping and host exposure;
- generated UI works with no custom UI, and custom/hybrid UI does not change processor behavior;
- MIDI 1.0, MIDI 2.0 UMP, note identity and per-note expression traverse the shared event path;
- multiple simultaneous notes retain independent pitch, pressure, timbre and other supported expression through note-aware components and the playback path;
- unison voices retain independent phase, detune, pan/spread and modulation until an explicit voice-mix boundary;
- a C++ instrument can generate distinct native left/right signals, and stereo effects preserve and process both channels without mono collapse;
- per-channel processors correctly handle multi-channel layouts within the declared resource budget, with explicit channel maps and conversions;
- a track defaults to stereo and may carry more channels than the physical output device, with any required output mapping/downmix explicit;
- state/preset save and restore are versioned and deterministic within the declared contract;
- real-time processing performs no allocation, blocking lock, I/O or UI call and remains within declared bounds;
- untrusted native code is never silently loaded in-process;
- adding a new component, parameter, port, UI control or adapter does not require unrelated subsystem rewrites; and
- low-end performance is measured against realistic audio workloads, with no duplicate runtime or unnecessary background cost.

Until these tests and the relevant CI jobs pass, mark the capability planned or partial rather than implemented.
