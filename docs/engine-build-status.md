---
title: Modular engine implementation status
summary: Evidence-based status of the unified engine build, what is implemented, what is only a contract, and the next engineering stages.
covers: [engine/, app/]
updated: 2026-11-02
---

# Modular engine implementation status

This is the implementation ledger for the unified modular engine. A documented contract is not the same thing as a running feature. Status below separates code that exists from code that still needs integration or verification.

## Implemented in the current repository snapshot

- Portable deterministic workload policy for audition, preview, background generation, offline render and idle workloads.
- App-side native job integration: the Flutter host binds the native hardware probe and workload planner, then submits project compilation, async source checks and offline WAV renders to the C++ `AdaptiveWorkerPool`. Dart owns job handles, polls status/progress and reads results; native workers never call Dart. Project jobs retain their engine handle until completion. Android thermal status and battery-saver changes are supplied by the app host; app lifecycle and audio-playing transitions refresh the native worker budget. Other platform adapters remain explicitly unknown.
- Hardware profile input and C ABI adapter for workload planning, plus a native best-effort probe for active/online cores, process CPU affinity and Linux/Android cgroup CPU and memory limits, conservative available-memory budgets and CPU SIMD support on Windows, macOS, Linux and Android. Linux/Android preserve exhausted finite cgroup limits as a minimal budget; positive budgets are quartered with a 1 MiB minimum and an 8192 MiB cap. macOS/iOS still use half of physical memory as a fallback, not live available memory. Missing CPU/memory signals remain unknown and policy falls back conservatively to one worker. Android thermal status (Android 10+) and battery-saver changes are supplied by the app host; unsupported platforms remain explicitly unknown. GPU compute is unavailable until a real kernel backend exists.
- First-class internal module descriptors with stable IDs, typed ports, parameter metadata and validation, plus framework-neutral generated UI controls and custom-view identifiers with parameter/range validation.
- Stereo-native borrowed-buffer processor contract. This is an interface contract; it is not yet wired into the existing VM/mixer as a universal processor path.
- Typed DSP graph validation, deterministic topological ordering and a prepared stereo executor. The compiler no longer imposes arbitrary 1024-node/8192-connection caps; node references retain a uint32 representational boundary, connection indices use size_t, duplicate-ID validation is hash-based, and allocation/length failures return OutOfMemory. The executor accepts host-selected nonzero block sizes without the old 8192-frame cap, allocates only during prepare and processes with preallocated buffers and no graph traversal or locks. Runtime remains limited to stereo audio with one input and one output per node.
- A graph runtime publication helper that adopts prepared graphs on the audio thread and defers old-graph reclamation to the control thread. This helper is not yet connected to Engine/VM.
- Bounded, fixed-capacity non-real-time worker pool with priority scheduling, worker-budget controls, queue rejection and pending-job cancellation, plus an `AdaptiveWorkerPool` wrapper that applies the deterministic workload plan to actual worker concurrency. An additive public C ABI now exposes pool creation, plan application, prioritized source-check/project-compile/offline-render jobs, status/progress, cancellation and owned result/error handles. Native job inputs are copied, engine handles are retained across project jobs, and pool shutdown drains accepted work. Workers are created on demand, sleep on a condition variable and retire after a configurable idle timeout; completed thread slots are joined and reused when demand returns. Retirement never runs on the audio callback.
- Exact, scope-aware dependency resolver for project-local, user-global, factory and add-on assets, including pinned version, content hash, interface version, optional references and ambiguity detection. Project JSON now parses and stores these dependency references; matching them against the installed library and surfacing repair actions remain unimplemented.
- Native module registry with stable-ID lookup, factory creation, descriptor verification and reset/versioned state hooks. The registry is static/in-process only; dynamic loading, host adapter, state migration/serialization policy and package signing remain unimplemented.
- MIDI 2.0 Channel Voice UMP decoder for note, per-note pitch, pressure, CC and channel pitch events, plus a bounded lock-free SPSC input queue. This is a host bridge primitive, not live device I/O or Engine voice routing.
- Existing note model already supports fractional MIDI pitches and per-note bend, pressure, timbre and vibrato curves. Existing MIDI import/export handles Standard MIDI Files and MIDI 2.0 Clip Files.
- Synth patch compiler now supports three oscillators, sub/noise, unison, two filters, three ADSR envelopes, four tempo-synced LFOs, four macros, modulation routing to oscillator position/level/pitch, filter cutoff/resonance and master volume, plus effect chains. A deterministic phase-distortion amount is now available per wavetable oscillator. The Builder includes a synth modulation-matrix editor and a general numeric parameter/global modulation editor using `mod name = expression` and `util.mod`; dedicated sidechain ducking effects can be created, routed from active exports, retargeted and removed. Missing exports warn and read zero; dependency cycles remain bounded with one-block feedback and diagnostics. Drawn LFO curves, additional warp modes (hard sync/FM/fold), and custom/imported wavetable authoring remain unimplemented.

## Not yet implemented

- Integration of the prepared graph executor and graph runtime into the existing Engine/VM mixer path, including project graph representation and bytecode/native processor interoperation. The graph/runtime and ModuleRegistry currently have no production references from Engine, VM, C API or Flutter.
- Universal state transfer, graph hot-swap integration and dependency-aware retirement for native module instances; the graph helper currently provides only prepared-graph pointer publication and deferred reclamation.
- Multichannel and multi-port runtime processing, multiple sources per input, multiple outputs, cross-domain control/modulation/event/MIDI execution, general sidechains, sends/returns and feedback networks. The current prepared executor is stereo, audio-only, one-in/one-out per node, and accepts only 8–192 kHz.
- Native routing for remaining generation and analysis work; the app currently uses the native worker pool for project compilation, source checks and offline WAV renders. Android thermal/battery signals and app lifecycle/audio transitions now update the active worker budget; other platform adapters remain unimplemented.
- A true adaptive quality ladder with measurable preview-quality modes and guaranteed unchanged offline exports.
- Drawn LFO curves, additional oscillator warp modes (hard sync/FM/fold) and the complete custom/imported table draw/render pipeline.
- MIDI 2.0 device input/output, Engine voice routing, output scheduling and full per-note controller/attribute mapping. The decoder/queue do not by themselves provide device support.
- Project manifest writing/round-tripping, dependency snapshots, content-hash generation and library/app integration for the new resolver.
- App-side rendering/runtime for declarative and custom module interfaces.
- Dynamic native module loading, package verification, crash containment and optional out-of-process isolation.
- CLAP/VST3 export wrappers.

## Current implementation order

The owner's 2026-11-02 instruction explicitly reopens and prioritizes the complete native engine refactor/integration, superseding the older pause note. The active implementation branch is feature/native-engine-refactor-integration, based on Main through refactor/native-engine-foundation. This is one coherent engine migration, not a second engine. The first code slice removes arbitrary graph-size and executor-block caps; graph runtime integration is still incomplete.

PR #68 (project parameter/global automation) is merged into Main at 20fd3da9a37f8936f1c3ff6069878978d064ae37. Preserve that behavior and project compatibility. SFZ and stems export remain next after the refactor gate. Scenes and MIDI 2.0 device input/output remain later work; the decoder and bounded queue are not live device support.

## Verification

The native CMake workflow builds the engine without a device backend and runs the full CTest suite on pushes and pull requests. The registered tests are divided into four deterministic, process-isolated shards; CTest runs those shards concurrently with four workers. Golden-file updates remain unsharded. The Engine platform/sanitizer matrix, App jobs and Docs/hygiene workflow run independently. Superseded runs are cancelled within each workflow so outdated commits do not occupy runners. Treat the checks on the current PR head as authoritative: queued or partial jobs are not passes, and a successful library build is not a test-suite pass. For graph scaling commit eb465f4, Engine run 41401179084 passed Linux x64, Linux sanitizers, Windows x64 and Linux Arm64; Linux CTest reports all four shards passed. Docs/hygiene run 41401179017 passed. App run 41401179166 passed Dart analysis, Dart tests and Windows app; Android APK was still running at the checkpoint. Device profiling remains separate; cloud CI cannot prove phone latency, thermal behavior, battery use or drop-out resistance.
