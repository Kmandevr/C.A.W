---
title: Modular engine implementation status
summary: Evidence-based status of the unified engine build, what is implemented, what is only a contract, and the next engineering stages.
updated: 2026-10-30
---

# Modular engine implementation status

This is the implementation ledger for the unified modular engine. A documented contract is not the same thing as a running feature. Status below separates code that exists from code that still needs integration or verification.

## Implemented in the current branch

- Portable deterministic workload policy for audition, preview, background generation, offline render and idle workloads.
- Hardware profile input and C ABI adapter for workload planning. The host supplies the profile; automatic platform capability detection is not implemented yet.
- First-class internal module descriptors with stable IDs, typed ports, parameter metadata and validation.
- Stereo-native borrowed-buffer processor contract. This is an interface contract; it is not yet wired into the existing VM/mixer as a universal processor path.
- Typed DSP graph validation and deterministic topological ordering, including cycle, direction, port type, channel layout and duplicate-input checks.\n- Bounded, fixed-capacity non-real-time worker pool with priority scheduling, worker-budget controls, queue rejection and pending-job cancellation. It is not yet connected to app/render/analysis jobs or the adaptive workload policy.\n- Exact, scope-aware dependency resolver for project-local, user-global, factory and add-on assets, including pinned version, content hash, interface version, optional references and ambiguity detection. Project JSON serialization and the library UI do not yet call this resolver.
- Public native module C ABI header and SDK contract for trusted add-ons. Dynamic loading, host adapter, state lifecycle and package signing remain unimplemented.
- Existing note model already supports fractional MIDI pitches and per-note bend, pressure, timbre and vibrato curves. Existing MIDI import/export handles Standard MIDI Files and MIDI 2.0 Clip Files.
- Synth patch compiler now supports three oscillators, sub/noise, unison, two filters, three ADSR envelopes, four tempo-synced LFOs, four macros, modulation routing to oscillator position/level/pitch, filter cutoff/resonance and master volume, plus effect chains. Drawn LFO curves, warp modes and custom/imported wavetable authoring remain unimplemented.

## Not yet implemented

- A real-time-safe graph executor that runs compiled graph plans through the existing engine and VM.
- Universal state transfer, graph hot-swap and dependency-aware retirement for native module instances.
- Scheduling integration: the pool and workload policy exist, but platform pressure is not yet fed into the pool automatically and engine jobs do not yet use it.
- Automatic Android/Windows/macOS/Linux hardware, SIMD, memory, thermal and battery capability probes.
- A true adaptive quality ladder with measurable preview-quality modes and guaranteed unchanged offline exports.
- Drawn LFO curves, oscillator warp modes and the complete custom/imported table draw/render pipeline.
- MIDI 2.0 live input/output and full per-note controller/attribute mapping. File/clip support is not equivalent to live MIDI 2.0 device support.
- Project manifest serialization, dependency snapshots, content-hash storage and library/app integration for the new resolver.
- Declarative and custom module UI schema/runtime.
- Dynamic native module loading, package verification, crash containment and optional out-of-process isolation.
- CLAP/VST3 export wrappers.

## Engineering order

1. Make the module graph executable and safely hot-swappable.
2. Add the bounded non-real-time worker scheduler and platform capability providers.
3. Expand the synth parser/code generator with modulation primitives while retaining the readable patch format.
4. Connect graph/module identity and pinned dependencies to project serialization and the asset library.
5. Complete the native SDK host adapter and module UI contract.
6. Add MIDI 2.0 device I/O and full controller mapping.
7. Profile low-end Android and desktop hardware; use measured results to tune adaptive policies.
8. Add plugin wrappers only after the module lifecycle and state contract are stable.

## Verification

The new native CMake workflow builds the engine without a device backend and runs the full CTest suite on pushes and pull requests. CI must pass before the new foundation is treated as verified. Device profiling remains a separate requirement; cloud CI cannot prove phone latency, thermal behavior, battery use or drop-out resistance.
