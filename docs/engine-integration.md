---
title: Engine integration contract
summary: How CAW's shared native engine is consumed by projects, add-ons, the app, the library and external build targets.
updated: 2026-10-30
---

# Engine integration contract

This document makes one rule explicit: **engine capabilities belong to the product ecosystem, not only to the engine implementation.** A feature is not complete merely because a C++ class exists. It must have a supported route into projects, add-ons, the asset library, the app UI and external consumers where relevant.

## One engine, modular by construction

The owner's direction (2026-10-30) is explicit: the engine is one coherent system, and its modularity is foundational—not an afterthought, optional plugin layer or set of disconnected sub-engines. Every host uses the same module identity, typed-port, parameter, state, processing and dependency contracts. Build configurations may omit unused modules for size, but must not fork their behavior or project semantics.

The portable C++ core is the single source of processing behavior. Hosts must not reimplement DSP or invent a parallel project format.

- **CAW app:** authors projects, browses the library, edits module parameters, previews and exports.
- **Project runtime:** resolves dependencies, instantiates modules and stores user-visible state.
- **Add-ons:** call the versioned C ABI and use the same module, parameter, render and capability contracts as the app. Add-ons do not reach into private C++ classes.
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

The engine owns parameter values, state validation, graph preparation and processing. A custom UI is only a view/controller over the public parameter/event interface. A module must remain usable with generated controls if its custom UI is unavailable. UI code never runs on the audio callback.

Third-party native add-ons are executable code and therefore a separate trust boundary. Do not load them into the core process by default. Require explicit user installation/approval, signature/hash verification where available, declared permissions, compatibility checks and a crash-isolation strategy. Downloaded .caw source remains sandboxed with bounded CPU, memory, loops, source size and call depth.

## Connected library model

The library is not just a static list of bundled templates. It is a versioned catalog over factory, local, global and installed add-on scopes. The same search and metadata model should cover sounds, drum kits, instruments, effects, waveforms, wavetables, MIDI patterns, reusable modules and complete project starters.

Library results should expose documentation, previews, dependencies, compatible engine versions, origin/trust and update status. Offline use remains first-class: the local index and installed assets remain usable without network access. Sync is an optional transport for a user's chosen remote source; it must not be a runtime dependency for creating or rendering sound.

## Shared adaptive execution

The native core now exposes `caw_hardware_profile_detect` for a best-effort core-count, conservative memory-budget and CPU SIMD snapshot on supported desktop and Android platforms. The host supplies live battery/thermal pressure and passes the resulting profile to `caw_execution_plan`. The app, CLI and add-ons should all use the same workload vocabulary rather than each inventing a different policy. The current C ABI planner is pure advice only: it does not probe the OS or run worker threads.

The current native core now includes a bounded worker pool with fixed-capacity submission, foreground/offline/background priorities, worker-budget controls and pending-job cancellation. The workload planner and pool are still separate primitives: the host does not yet feed live platform pressure into the pool, and compile/render/analysis jobs are not all routed through it. The eventual integration adds memory limits, cache budgets and progress reporting. A project render, library preview, waveform analysis, module compile and package build are jobs with explicit workload classes. Interactive audio remains on its real-time-safe path. Background work yields to foreground use and thermal/battery pressure. Offline export can use more resources when the user permits it.

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
