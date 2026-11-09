---
title: Engine integration contract
summary: How CAW's shared native engine is consumed by projects, add-ons, the app, the library and external build targets.
covers: [engine/, app/lib/engine/]
updated: 2026-11-09
---

# Engine integration contract

**Status:** this is a target contract/blueprint. It deliberately describes some future ecosystem behavior. The current native implementation and integration gaps are recorded in [engine implementation status](engine-build-status.md); a C++ class or interface alone does not mean the app/library/plugin workflow is complete.

This document makes one rule explicit: **engine capabilities belong to the product ecosystem, not only to the engine implementation.** A feature is not complete merely because a C++ class exists. It must have a supported route into projects, add-ons, the asset library, the app UI and external consumers where relevant.

## One engine, modular by construction

The owner's direction (2026-10-30) is explicit: the engine is one coherent system, and its modularity is foundational—not an afterthought, optional plugin layer or set of disconnected sub-engines. Every host uses the same module identity, typed-port, parameter, state, processing and dependency contracts. Build configurations may omit unused modules for size, but must not fork their behavior or project semantics.

The portable C++ core is the single source of processing behavior. Hosts must not reimplement DSP or invent a parallel project format.

- **CAW app:** authors projects, browses the library, edits module parameters, previews (modules and single notes) and exports.
- **Project runtime:** resolves dependencies, instantiates modules and stores user-visible state.
- **Add-ons:** call the versioned C ABI (`caw.h`, `CAW_API_VERSION` 2; compiled components use the component interface v2 in `caw_component.h`) and use the same module, parameter, render and capability contracts as the app. Add-ons do not reach into private C++ classes.
- **CLI and CI:** validate, render, package and test the same project/module formats without launching the UI.
- **Future plugin wrappers:** adapt host audio/MIDI buffers to the engine's documented processing contract. They are generated/packaged products, not a requirement to run CAW itself.

Every public capability needs a stable identifier, documented input/output contract, versioning behavior, error reporting and a test. The C ABI remains the compatibility boundary; additive functions and structs must be size/version guarded before any future ABI-breaking redesign.

## Projects, add-ons and shared workflows

A project is a portable dependency graph, not a folder of unrelated files. It should be able to reference:

1. **Project-local assets** that travel with that project.
2. **User-global library assets** reusable from multiple projects.
3. **Factory assets** shipped read-only with CAW.
4. **Add-on modules** installed by the user or supplied by a trusted package.

The native core now has an exact, scope-aware dependency resolver (`dependency.*`) for stable asset IDs, source scope, pinned version, content hash and interface version, including optional and ambiguous dependency outcomes. Project JSON parsing now stores the pinned dependency records on `ProjectSpec`. Project JSON writing/round-tripping, embedded snapshots, installed-library lookup and repair UI still need to invoke the resolver. Updating a global library item must never silently alter the sound of an already-pinned project.

The in-app file manager and library browser are two views of the same asset model. They must support search, categories/tags, preview, dependency inspection, version history, duplicate/fork, local-to-global publish, global-to-project copy/link, missing-dependency repair and safe delete. Factory content is never overwritten in place; edits become project-local copies or user forks.

A single action should be able to move through the workflow: find asset → inspect docs/dependencies → audition → add to project → customize → save as local or global → package/share/export. Avoid separate disconnected asset stores for presets, modules, samples, MIDI and add-ons.

## Module and add-on contract

A module package needs:
- stable module ID, semantic version, author/source and license metadata;
- module API/ABI compatibility range;
- typed ports (audio, control, modulation, events), channel layouts and parameter metadata;
- default state, state serialization and migration hooks;
- resource hints and declared processing constraints;
- optional generated UI schema, plus an optional custom UI extension;
- source and documentation alongside the module;
- dependency manifest and content hash;
- test vectors or deterministic render fixtures where practical.

The engine owns parameter values, state validation, graph preparation and processing; the app keeps every automation lane, point and pattern note it accepts (F7.1, 2026-11-04), and songs of any length the 32-bit step count holds (F7.2). The Engine grows past 64 layers within its memory budget (F7.3), and the C API names the master and audition scopes by id (`CAW_SCOPE_MASTER`, `CAW_SCOPE_AUDITION`). The transport can start anywhere in the loop (`caw_engine_play_at`, 2026-11-05), so the app's pause resumes where it stopped. A prepared planar N-channel graph executor (with summing inputs for fan-in) now runs native processors in topological order without allocating or locking in `process`; the current runtime supports any number of audio ports (any channel layout, planar N-channel since F3), modulation ports (one float per frame) and control ports (one value per block) per node since F5.1, and event ports (timed events with a note id and raw UMP) since F5.2; a parameter resolver (F6.1, `params.h`) combines manual, automation and modulation values, and the graph executor passes resolved values to processors (F6.2), with manual values queued lock-free from the control thread and modulation links from other nodes' modulation outputs (F6.3) and automation lanes read at the transport position, bit-identical to the Engine's (F6.4), and MIDI CC mappings from host events (F6.5); the Engine's .caw params and globals resolve through the same resolver (F6.6); summing inputs take many connections (F4.1). Since F4.3/F4.4 the Engine's live playback and offline render run through one such graph (`GraphExecutor::prepareRouted`): a node per module of each track, a track node, folder bus nodes and a master node, re-routed on the audio thread. A separate graph runtime helper publishes prepared graphs at callback boundaries and defers old-graph reclamation to the control thread. `ModuleRegistry` creates static processors and now also loads shared libraries through `LoadLibraryW`/`dlopen`, validates descriptors and stable IDs, and retains each library until its processor wrappers are destroyed. The C++ contract is public at `engine/include/caw/module.hpp`; `CAW::SDK` is an installable CMake package. The app persists C++ source and exact dependency pins, builds locally, and receives an artifact path. The Engine C API requires an explicit trust value; Dart FFI invokes load/unload off the UI isolate. `ProjectDoc.masterComponents` now routes zero-parameter stereo effects through the live master chain, with the safety limiter after native code. The first adapter is intentionally narrow: parameter mapping, track-chain insertion, native/bytecode interoperation, full state migration and the per-component trust UI/store remain future work. A custom UI is only a view/controller over the public parameter/event interface. A module must remain usable with generated controls if its custom UI is unavailable. UI code never runs on the audio callback.

Third-party native add-ons are executable code and therefore a separate trust boundary. The current Engine loader requires an explicit trust argument: Blocked refuses before opening the library, Isolated is rejected until a real separate-process host exists, and Trusted loads in-process. Build success never authorizes execution. The UI must make that choice visible and keep trust local to the device/user, not in a portable project file. Signature/hash verification, declared permissions and crash isolation remain future safeguards; Trusted native code can access process memory and must obey the audio callback contract. Downloaded .caw source remains sandboxed with bounded CPU, memory, loops, source size and call depth.

## Connected library model

The library is not just a static list of bundled templates. It is a versioned catalog over factory, local, global and installed add-on scopes. The same search and metadata model should cover sounds, drum kits, instruments, effects, waveforms, wavetables, MIDI patterns, reusable modules and complete project starters.

Library results should expose documentation, previews, dependencies, compatible engine versions, origin/trust and update status. Offline use remains first-class: the local index and installed assets remain usable without network access. Sync is an optional transport for a user's chosen remote source; it must not be a runtime dependency for creating or rendering sound.

## Shared adaptive execution

The native core now exposes `caw_hardware_profile_detect` for a best-effort core-count, conservative memory-budget and CPU SIMD snapshot on supported desktop and Android platforms. The Android app host supplies observed thermal and battery-saver pressure through `PowerManager`; other platforms remain explicitly `Unknown` until a verified adapter exists. The app also feeds foreground/background and audio-playing transitions into the shared scheduler. The app, CLI and add-ons should all use the same workload vocabulary rather than each inventing a different policy. The `caw_execution_plan` C ABI function remains pure advice: it does not probe the OS or run worker threads. A separate additive C ABI now exposes pool creation, workload-plan application, prioritized job submission, status/progress, cancellation, result/error retrieval and explicit handle release. The first native job types are module source checks and offline WAV renders; render progress and cancellation use the existing render path. Job inputs are copied at submission, result strings are caller-owned via `caw_free`, and destroying the pool waits for accepted work to finish.

The current native core includes a bounded worker pool with fixed-capacity submission, foreground/offline/background priorities, worker-budget controls and pending-job cancellation. `AdaptiveWorkerPool` applies the workload planner's worker budget to that pool. The Flutter host now submits project compilation, module checks and offline WAV renders through these native handles. Dart polls the versioned status structure and owns/releases each job handle; native workers never call into Dart. Project jobs retain their `CawEngine` handle until completion, and engine destruction waits for accepted project jobs. Generation and analysis jobs are not yet routed through the pool. The app must feed only observed platform pressure and preserve foreground responsiveness. Live memory-pressure adaptation and bounded cache budgets remain later work. A project render, library preview, waveform analysis, module compile and package build are jobs with explicit workload classes. Interactive audio remains on its real-time-safe path. Background work yields to foreground use and thermal/battery pressure. Offline export can use more resources when the user permits it.

No scheduler may silently lower quality or alter deterministic output. If a job cannot fit the available budget, report the constraint and offer a deliberate choice. GPU use is per-kernel and measured; a GPU flag is not proof that a task has an efficient GPU implementation.

## Completion criteria

A capability is ecosystem-ready only when:
- it is reachable through the public engine API used by the app and add-ons;
- project serialization preserves its state and dependencies;
- the library can find, preview, version and reuse it where applicable;
- generated and custom UIs can operate it without private engine access;
- CLI/CI can validate or render it headlessly where applicable;
- compatibility, failure, cancellation and low-resource tests cover it;
- documentation distinguishes implemented behavior from planned behavior.

This is the standard for the modular engine: native capabilities, connected workflows and portable assets—not isolated demos.
