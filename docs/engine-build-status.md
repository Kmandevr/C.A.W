---
title: Modular engine implementation status
summary: Evidence-based status of the unified engine build, what is implemented, what is only a contract, and the next engineering stages.
covers: [engine/, app/]
updated: 2026-10-30
---

# Modular engine implementation status

This is the implementation ledger for the unified modular engine. A documented contract is not the same thing as a running feature. Status below separates code that exists from code that still needs integration or verification.

## Implemented in the current branch

- Portable deterministic workload policy for audition, preview, background generation, offline render and idle workloads.
- Hardware profile input and C ABI adapter for workload planning, plus a native best-effort probe for online cores, conservative available-memory budget and CPU SIMD support on Windows, macOS, Linux and Android. Thermal/battery pressure remains host supplied; GPU compute is reported unavailable until a real kernel backend exists.
- First-class internal module descriptors with stable IDs, typed ports, parameter metadata and validation, plus framework-neutral generated UI controls and custom-view identifiers with parameter/range validation.
- Stereo-native borrowed-buffer processor contract. This is an interface contract; it is not yet wired into the existing VM/mixer as a universal processor path.
- Typed DSP graph validation, deterministic topological ordering and a prepared stereo executor. Topological compilation uses a stable min-heap; the executor allocates only during prepare and processes with preallocated buffers and no graph traversal or locks.
- A graph runtime publication helper that adopts prepared graphs on the audio thread and defers old-graph reclamation to the control thread. This helper is not yet connected to Engine/VM.
- Bounded, fixed-capacity non-real-time worker pool with priority scheduling, worker-budget controls, queue rejection and pending-job cancellation, plus an `AdaptiveWorkerPool` wrapper that applies the deterministic workload plan to actual worker concurrency. The app/host still needs to feed live platform pressure and route real compile/render/analysis jobs through it.
- Exact, scope-aware dependency resolver for project-local, user-global, factory and add-on assets, including pinned version, content hash, interface version, optional references and ambiguity detection. Project JSON now parses and stores these dependency references; matching them against the installed library and surfacing repair actions remain unimplemented.
- Native module registry with stable-ID lookup, factory creation, descriptor verification and reset/versioned state hooks. The registry is static/in-process only; dynamic loading, host adapter, state migration/serialization policy and package signing remain unimplemented.
- MIDI 2.0 Channel Voice UMP decoder for note, per-note pitch, pressure, CC and channel pitch events, plus a bounded lock-free SPSC input queue. This is a host bridge primitive, not live device I/O or Engine voice routing.
- Existing note model already supports fractional MIDI pitches and per-note bend, pressure, timbre and vibrato curves. Existing MIDI import/export handles Standard MIDI Files and MIDI 2.0 Clip Files.
- Synth patch compiler now supports three oscillators, sub/noise, unison, two filters, three ADSR envelopes, four tempo-synced LFOs, four macros, modulation routing to oscillator position/level/pitch, filter cutoff/resonance and master volume, plus effect chains. A deterministic phase-distortion amount is now available per wavetable oscillator. Drawn LFO curves, additional warp modes (hard sync/FM/fold), and custom/imported wavetable authoring remain unimplemented.

## Not yet implemented

- Integration of the prepared graph executor and graph runtime into the existing Engine/VM mixer path, including project graph representation and bytecode/native processor interoperation.
- Universal state transfer, graph hot-swap integration and dependency-aware retirement for native module instances; the graph helper currently provides only prepared-graph pointer publication and deferred reclamation.
- Host scheduling integration: the adaptive pool now applies workload plans, but platform pressure is not yet fed into it automatically and engine/app jobs do not yet use it.
- Automatic host/app integration of the native hardware probe and live thermal/battery pressure feeds. The core already has a best-effort logical-core, memory-budget and SIMD probe; platform accuracy and real-device behavior still need validation.
- A true adaptive quality ladder with measurable preview-quality modes and guaranteed unchanged offline exports.
- Drawn LFO curves, additional oscillator warp modes (hard sync/FM/fold) and the complete custom/imported table draw/render pipeline.
- MIDI 2.0 device input/output, Engine voice routing, output scheduling and full per-note controller/attribute mapping. The decoder/queue do not by themselves provide device support.
- Project manifest writing/round-tripping, dependency snapshots, content-hash generation and library/app integration for the new resolver.
- App-side rendering/runtime for declarative and custom module interfaces.
- Dynamic native module loading, package verification, crash containment and optional out-of-process isolation.
- CLAP/VST3 export wrappers.

## Engineering order

1. Integrate the prepared graph into the existing Engine/VM path and add safe graph replacement/state migration.
2. Add the bounded non-real-time worker scheduler and platform capability providers.
3. Expand the synth parser/code generator with modulation primitives while retaining the readable patch format.
4. Connect graph/module identity and pinned dependencies to project serialization and the asset library.
5. Complete the native SDK host adapter and module UI contract.
6. Add MIDI 2.0 device I/O and full controller mapping.
7. Profile low-end Android and desktop hardware; use measured results to tune adaptive policies.
8. Add plugin wrappers only after the module lifecycle and state contract are stable.

## Verification

The native CMake workflow builds the engine without a device backend and runs the full CTest suite on pushes and pull requests. Treat the checks on the current PR head as authoritative: queued or partial jobs are not passes, and a successful library build is not a test-suite pass. The modular foundation remains unverified until the complete Engine, App and Docs checks are green. Device profiling remains separate; cloud CI cannot prove phone latency, thermal behavior, battery use or drop-out resistance.
