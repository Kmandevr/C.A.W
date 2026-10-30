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
- Typed DSP graph validation and deterministic topological ordering, including cycle, direction, port type, channel layout and duplicate-input checks.
- Public native module C ABI header and SDK contract for trusted add-ons. Dynamic loading, host adapter, state lifecycle and package signing remain unimplemented.
- Existing note model already supports fractional MIDI pitches and per-note bend, pressure, timbre and vibrato curves. Existing MIDI import/export handles Standard MIDI Files and MIDI 2.0 Clip Files.
- Existing synth patch compiler already supports three oscillators, sub/noise, unison, two filters, one amplitude envelope and effect chains. Several previously planned synth features remain unimplemented.

## Not yet implemented

- A real-time-safe graph executor that runs compiled graph plans through the existing engine and VM.
- Universal state transfer, graph hot-swap and dependency-aware retirement for native module instances.
- Bounded worker pool, job cancellation and scheduling integration. The workload policy currently returns advice only.
- Automatic Android/Windows/macOS/Linux hardware, SIMD, memory, thermal and battery capability probes.
- A true adaptive quality ladder with measurable preview-quality modes and guaranteed unchanged offline exports.
- Full synth modulation system: three envelopes, four drawn LFOs, four macros, modulation matrix, oscillator warp modes and complete table import/draw/render pipeline.
- MIDI 2.0 live input/output and full per-note controller/attribute mapping. File/clip support is not equivalent to live MIDI 2.0 device support.
- Project manifests with pinned module versions, dependency snapshots, content hashes and portable asset resolution.
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
