---
title: Modular engine implementation status
summary: Evidence-based status of the unified engine build, what is implemented, what is only a contract, and the next engineering stages.
covers: [engine/, app/]
updated: 2026-10-31
---

# Modular engine implementation status

This is the implementation ledger for the unified modular engine. A documented contract is not the same thing as a running feature. Status below separates code that exists from code that still needs integration or verification.

## Implemented in the current branch

- Portable deterministic workload policy for audition, preview, background generation, offline render and idle workloads.
- App-side native job integration: the Flutter host binds the native hardware probe and workload planner, then submits project compilation, async source checks and offline WAV renders to the C++ `AdaptiveWorkerPool`. Dart owns job handles, polls status/progress and reads results; native workers never call Dart. Project jobs retain their engine handle until completion. Live platform pressure is not yet supplied.
- Hardware profile input and C ABI adapter for workload planning, plus a native best-effort probe for active/online cores, process CPU affinity and Linux/Android cgroup CPU and memory limits, conservative available-memory budget and CPU SIMD support on Windows, macOS, Linux and Android. Missing CPU or memory signals are represented as unknown and policy falls back to one worker. Thermal/battery pressure remains host supplied; GPU compute is reported unavailable until a real kernel backend exists.
- First-class internal module descriptors with stable IDs, typed ports, parameter metadata and validation, plus framework-neutral generated UI controls and custom-view identifiers with parameter/range validation.
- Stereo-native borrowed-buffer processor contract. This is an interface contract; it is not yet wired into the existing VM/mixer as a universal processor path.
- Typed DSP graph validation, deterministic topological ordering and a prepared stereo executor. Topological compilation uses a stable min-heap; the executor allocates only during prepare and processes with preallocated buffers and no graph traversal or locks.
- A graph runtime publication helper that adopts prepared graphs on the audio thread and defers old-graph reclamation to the control thread. This helper is not yet connected to Engine/VM.
- Bounded, fixed-capacity non-real-time worker pool with priority scheduling, worker-budget controls, queue rejection and pending-job cancellation, plus an `AdaptiveWorkerPool` wrapper that applies the deterministic workload plan to actual worker concurrency. An additive public C ABI now exposes pool creation, plan application, prioritized source-check/project-compile/offline-render jobs, status/progress, cancellation and owned result/error handles. Native job inputs are copied, engine handles are retained across project jobs, and pool shutdown drains accepted work. Workers are created on demand, sleep on a condition variable and retire after a configurable idle timeout; completed thread slots are joined and reused when demand returns. Retirement never runs on the audio callback.
- Exact, scope-aware dependency resolver for project-local, user-global, factory and add-on assets, including pinned version, content hash, interface version, optional references and ambiguity detection. Project JSON now parses and stores these dependency references; matching them against the installed library and surfacing repair actions remain unimplemented.
- Native module registry with stable-ID lookup, factory creation, descriptor verification and reset/versioned state hooks. The registry is static/in-process only; dynamic loading, host adapter, state migration/serialization policy and package signing remain unimplemented.
- MIDI 2.0 Channel Voice UMP decoder for note, per-note pitch, pressure, CC and channel pitch events, plus a bounded lock-free SPSC input queue. This is a host bridge primitive, not live device I/O or Engine voice routing.
- Existing note model already supports fractional MIDI pitches and per-note bend, pressure, timbre and vibrato curves. Existing MIDI import/export handles Standard MIDI Files and MIDI 2.0 Clip Files.
- Synth patch compiler now supports three oscillators, sub/noise, unison, two filters, three ADSR envelopes, four tempo-synced LFOs, four macros, modulation routing to oscillator position/level/pitch, filter cutoff/resonance and master volume, plus effect chains. A deterministic phase-distortion amount is now available per wavetable oscillator. The Builder includes a synth modulation-matrix editor and a general numeric parameter/global modulation editor using `mod name = expression` and `util.mod`; dedicated sidechain ducking effects can be created, routed from active exports, retargeted and removed. Missing exports warn and read zero; dependency cycles remain bounded with one-block feedback and diagnostics. Drawn LFO curves, additional warp modes (hard sync/FM/fold), and custom/imported wavetable authoring remain unimplemented.

## Not yet implemented

- Integration of the prepared graph executor and graph runtime into the existing Engine/VM mixer path, including project graph representation and bytecode/native processor interoperation.
- Universal state transfer, graph hot-swap integration and dependency-aware retirement for native module instances; the graph helper currently provides only prepared-graph pointer publication and deferred reclamation.
- Native routing for remaining generation and analysis work, plus verified live thermal/battery pressure feeds from the app host. The current app uses the native worker pool for project compilation, source checks and offline WAV renders; platform pressure still defaults to normal until a real supported signal is connected.
- Verified live thermal/battery pressure feeds from the app host. The app consumes the native logical-core, conservative memory-budget and SIMD probe, but defaults to normal pressure until a real platform signal is connected; platform accuracy and device behavior still need validation.
- A true adaptive quality ladder with measurable preview-quality modes and guaranteed unchanged offline exports.
- Drawn LFO curves, additional oscillator warp modes (hard sync/FM/fold) and the complete custom/imported table draw/render pipeline.
- MIDI 2.0 device input/output, Engine voice routing, output scheduling and full per-note controller/attribute mapping. The decoder/queue do not by themselves provide device support.
- Project manifest writing/round-tripping, dependency snapshots, content-hash generation and library/app integration for the new resolver.
- App-side rendering/runtime for declarative and custom module interfaces.
- Dynamic native module loading, package verification, crash containment and optional out-of-process isolation.
- CLAP/VST3 export wrappers.

## Current implementation order

Stage 5 graph-to-Engine/VM/mixer integration is paused by the owner. The graph executor, runtime publication helper, native module lifecycle and their remaining integration work remain documented technical backlog, but they are not the active implementation sequence. Do not resume that work or add speculative framework layers unless the owner explicitly asks.

The current app-usable v2 order is:

1. Add automation lanes for module parameters and project globals.
2. Add SFZ and stems export.

Scenes and MIDI 2.0 device input/output remain deferred backlog items; the existing MIDI 2.0 decoder and bounded queue are not live device support.

Each item should be delivered as its own small PR, with app-facing functionality, tests and CI. Hardware validation must be documented separately from cloud CI. This sequence supersedes the older Stage 5-first order; the implementation ledger above still records what is built, what remains unintegrated and what is paused.

## Verification

The native CMake workflow builds the engine without a device backend and runs the full CTest suite on pushes and pull requests. The registered tests are divided into four deterministic, process-isolated shards; CTest runs those shards concurrently with four workers. Golden-file updates remain unsharded. The Engine platform/sanitizer matrix, App jobs and Docs/hygiene workflow run independently. Superseded runs are cancelled within each workflow so outdated commits do not occupy runners. Treat the checks on the current PR head as authoritative: queued or partial jobs are not passes, and a successful library build is not a test-suite pass. The modular foundation remains unverified until the complete Engine, App and Docs checks are green. Device profiling remains separate; cloud CI cannot prove phone latency, thermal behavior, battery use or drop-out resistance.
