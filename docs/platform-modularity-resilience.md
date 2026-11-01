---
title: Platform, modularity, resilience and optimization plan
summary: Cross-application architecture requirements for interchangeable platform backends, fault isolation, low-latency audio, modular algorithms and measured whole-app optimization.
covers: [engine/, app/]
updated: 2026-11-01
---

# Platform, modularity, resilience and optimization plan

**Status:** Owner-directed architecture plan. This document records requirements and proposals; it does not claim the proposed architecture is implemented.
**Scope:** The complete C.A.W. application: native engine, audio I/O, DSP, platform services, Flutter UI, project model, asset system, scheduling, build and diagnostics.
**Relationship to existing plans:** This extends [the master development plan](CAW_MASTER_DEVELOPMENT_PLAN.md), [architecture](architecture.md), [engine integration contract](engine-integration.md) and [performance](performance.md). Those documents remain authoritative for their existing topics. This note owns the cross-cutting requirements below.

## Verified repository baseline (2026-11-01)

The plan must build on the current implementation rather than restate existing work as a future proposal.

- **[Fact]** The engine is a portable C++20 core hosted by the Flutter app, CLI and offline renderer. The current device output path is miniaudio in `engine/platform/audio_miniaudio.cpp`; this is not yet evidence of a fully interchangeable per-platform backend framework. See [engine](engine.md) and [how it works](how-it-works.md).
- **[Fact]** The public engine C API is version 1. A native module SDK contract exists in `engine/include/caw_module_sdk.h`, with stable IDs, typed ports, parameter/UI metadata, state limits and callback rules. Dynamic loading, the host adapter, package signing and process isolation are not yet complete. In-process native modules are trusted code, not sandboxed. See [native module SDK](native-module-sdk.md).
- **[Fact]** A bounded native worker pool, workload classes, a hardware-profile snapshot and an additive C API for non-real-time jobs already exist. Android supplies observed thermal/battery-saver signals; other platform pressure values may remain unknown. Live memory-pressure adaptation and bounded cache budgets are still listed as later work. See [engine integration](engine-integration.md).
- **[Fact]** Project restore points already use atomic temporary-file writes and retain a bounded history per project. This is not the same as a complete autosave journal or guaranteed crash-recovery workflow. See the [Task 1 handoff](task-1-ui-handoff.md).
- **[Fact]** MIDI 2.0 Channel Voice UMP decoding and a bounded input queue exist, but the documented implementation is not live USB/Bluetooth MIDI device I/O or complete engine voice routing. See [how it works](how-it-works.md) and the engine implementation ledger.
- **[Fact]** Performance documentation already defines callback benchmarks and UI rebuild/polling controls, but physical-device CPU, battery, thermal, frame-time and real dropout measurements remain incomplete. See [performance](performance.md).

The following sections distinguish these existing foundations from the additional contracts and verification still required.

## 1. Owner's objective

C.A.W. must be extremely well optimized and modular at every level. New features, backends, algorithms and platform integrations should be addable or replaceable with minimal changes to unrelated systems.

A failure in one component should remain confined to that component wherever technically possible. A device backend failure must not corrupt the project; an optional effect failure must not take down the mixer; a UI panel failure must not stop audio; and an unavailable platform service must not disable unrelated functionality.

The architecture should make unrelated side effects difficult to introduce. Opening a panel must not unexpectedly change audio routing; changing an audio device must not mutate a project; adding an effect must not require edits to unrelated UI workspaces.

The design target is not maximum abstraction or maximum process separation. It is the smallest practical dependency surface, clear ownership, measurable performance and graceful recovery with minimal overhead.

## 2. Non-negotiable principles

1. **One responsibility per component.** Each subsystem owns a clearly bounded job and exposes a documented contract.
2. **Stable interfaces, replaceable implementations.** Consumers depend on contracts, not implementation details or platform-specific types.
3. **Minimal dependency direction.** Dependencies point toward stable contracts. Avoid circular dependencies and cross-layer reach-through.
4. **Shared state, not duplicated systems.** Workspaces and tools operate on the same project and engine state through supported APIs.
5. **Explicit side effects.** Device changes, project mutations, audio graph changes, file operations and UI navigation are distinct operations.
6. **Independent lifecycle.** Components can initialize, configure, stop, recover, replace and shut down without resetting unrelated components.
7. **Fault containment.** Validate boundaries, contain failures, bypass or disable only the affected capability, and preserve recoverable state.
8. **Real-time safety.** The audio callback performs only bounded, prepared, real-time-safe work. No allocation, blocking locks, file/network I/O, logging or UI calls.
9. **Performance is a requirement, not a later cleanup.** Measure CPU, memory, latency, deadline misses, startup, frame time, battery and thermal behavior on representative devices.
10. **No speculative framework layers.** Introduce an abstraction only when it removes real coupling, enables a real capability, or improves testability/replacement.
11. **Portable fallback.** Optimized paths must have correct portable fallbacks where practical.
12. **Facts, proposals and assumptions stay distinct.** Verify platform and library behavior against current primary documentation before implementation.

## 3. Application-wide modularity

### 3.1 Core and subsystem boundaries

**[Proposal]** Define small contracts for the major application capabilities, including:

- Audio device discovery, stream lifecycle, configuration and callbacks.
- Engine processing, transport, parameter access, state snapshots and diagnostics.
- DSP algorithms and processing nodes.
- Project persistence, migration, validation and undoable mutations.
- Asset registration, metadata, preview, import/export and drag/drop actions.
- Platform services such as files, lifecycle, MIDI, permissions and device notifications.
- UI workspace registration, navigation, state subscriptions and commands.
- Scheduling, worker budgets, memory budgets and performance telemetry.

Each contract should specify ownership, threading, lifecycle, error behavior, compatibility and performance expectations. Do not expose implementation-owned mutable objects across boundaries without an explicit lifetime and synchronization contract.

### 3.2 Adding and replacing features

A new instrument, effect, editor, asset type, device backend or algorithm should normally require:
- Implementing its contract.
- Registering its capability and metadata.
- Supplying tests and diagnostics.
- Adding only the integration points that actually consume it.

Existing unrelated workspaces and subsystems should not need edits. If a feature requires broad changes, document the actual dependency and consider whether the boundary is wrong.

### 3.3 Capability-based architecture

**[Proposal]** Use explicit capability descriptions and negotiation as the common way to decide what a device, host, module, algorithm or UI workspace can do. Do not scatter platform-name checks or infer support from a version string alone.

A capability record should identify:
- A stable capability ID and schema/version.
- Whether it is available, unavailable, temporarily unavailable or unknown.
- Supported values and constraints (for example sample-rate ranges, block sizes, channel layouts, MIDI protocols, bus counts, SIMD variants or state limits).
- Required permissions, dependencies and trust level.
- Runtime conditions that can change availability (device connected, permission granted, thermal pressure, backend initialized).
- A reason code and user-actionable explanation when it cannot be used.

Negotiation should produce a concrete, immutable execution/configuration choice before real-time use. The callback must never query the registry or perform negotiation. Examples:
- Audio backend + device + project negotiate sample rate, format, channel layout and buffer size.
- A module's declared input/output buses are matched to the actual host and graph layouts; unsupported mappings are explicit.
- An algorithm selector chooses a portable or SIMD implementation only after checking semantic compatibility and measured suitability.
- MIDI input reports protocol, port, timestamp precision and expression support independently; a decoder existing does not imply a live device route exists.
- A platform service may be absent without disabling unrelated product features.

Avoid turning this into a central runtime service that every subsystem polls. Capability providers publish snapshots; consumers request a scoped negotiation when configuration changes. Cache the result with a clear invalidation trigger. Unknown is not equivalent to supported, and fallback is allowed only when it preserves documented semantics.

### 3.4 Module and extension contract

The existing native SDK is a useful starting contract, not a completed plugin ecosystem. Keep one shared module identity, typed-port, parameter, state and processing model across built-in modules, bytecode modules and future native add-ons.

The contract should define:
- Stable module, port and parameter IDs; semantic version; source/origin and license metadata.
- API/ABI compatibility range and declared capabilities.
- Typed input/output ports, layouts, bus counts, event/control/modulation semantics and conversion rules.
- Parameter descriptors with units, ranges, defaults, automation behavior and stable IDs.
- State schema/version, maximum size, serialization and migration behavior.
- Lifecycle: validate, create, prepare, activate, process, deactivate, serialize, destroy; identify which calls may run on the audio thread.
- Borrowed-buffer ownership/lifetime, alignment, maximum block size, in-place/out-of-place rules and latency reporting.
- Resource hints and hard host-enforced limits; hints must not be treated as security enforcement.
- Optional generated UI metadata and optional custom UI extension, neither of which may be required to process audio.
- Dependency manifest, content hash, package provenance and deterministic test vectors where practical.

Keep the boundaries distinct:
1. Internal C++ interfaces are implementation details.
2. The versioned C ABI is the stable host/add-on boundary.
3. The .caw bytecode VM is the constrained untrusted-code route.
4. A future out-of-process native module protocol is the stronger trust boundary.
5. CLAP/VST3 wrappers are external host adapters, not a second engine or a general plugin-host subsystem.

Do not claim dynamic loading, binary compatibility, sandboxing, signing or third-party plugin hosting until each is implemented and tested. Reuse [native module SDK](native-module-sdk.md) and [engine integration](engine-integration.md); update those owning notes when the SDK itself changes.

### 3.3 Compatibility and evolution

- Version public/native interfaces where external modules or plugins depend on them.
- Provide explicit project schema migrations and reject unsupported future versions safely.
- Keep optional capabilities discoverable; do not assume every platform implements every capability.
- Preserve unknown optional metadata where safe, rather than silently deleting it.
- Avoid breaking changes to module formats and C APIs without migration plans and tests.

- Treat compatibility as a matrix, not a single version number: project schema, module source format, engine C ABI, native module SDK, package manifest, UI schema and persisted parameter/state formats can evolve independently.
- Every persisted or externally consumed format must declare its own version and supported range. Additive optional fields should have defined unknown-field behavior; required unknown fields must fail clearly rather than be misread.
- Use stable IDs for modules, ports and parameters. Display names and file paths are editable labels/locations, never compatibility keys.
- Keep migrations deterministic, one-way only when explicitly documented, and tested from representative older fixtures through the current format. Preserve originals or create a restore point before destructive migration.
- A host must negotiate the intersection of its supported API, module requirements, platform capabilities and project requirements before instantiation. Report the exact incompatible item and remediation path.
- Maintain compatibility tests for old projects, modules and add-on packages; test both forward rejection and backward-compatible loading where promised.

## 4. Platform backend architecture

### 4.1 One engine, platform-specific adapters

**[Proposal]** Keep the core engine independent of operating-system audio APIs. Each platform adapter implements the same narrow device/stream contract and translates native device events, formats, timestamps and callback behavior into that contract.

The existing architecture document identifies miniaudio behind `engine/platform/` as the current audio-I/O approach. Treat that as the current design baseline, not proof that every desired backend or low-latency behavior is already available. Audit the actual build configuration and supported backends before changing it.

Target families:

| Platform | Native low-latency direction | Requirement |
|---|---|---|
| Windows | WASAPI shared/exclusive; investigate a dedicated ASIO backend | Offer appropriate driver/device choices, expose buffer/latency information and recover from device changes. |
| Android | AAudio, with Oboe considered as a maintained abstraction over Android audio APIs | Target low-latency callback operation, USB audio where supported, device-change handling and thermal-aware operation. |
| iOS | Core Audio / RemoteIO or current supported Audio Unit route | Use native low-latency audio and handle route/session interruptions. |
| macOS | Core Audio | Device discovery, aggregate/device changes and stream recovery. |
| Linux | ALSA, PipeWire and JACK where supported by the selected backend | Respect server/device configuration and recover from disconnects. |

**Important ASIO distinction:** Traditional ASIO is a Windows driver/API ecosystem, not a phone audio API. Android and iOS cannot simply load desktop ASIO drivers. The requirement for phones is comparable low-latency performance and external USB audio-interface support where the OS, interface and driver stack permit it, using native mobile APIs. Do not advertise literal ASIO support on phones.

**Windows ASIO remains an open implementation choice:** Verify whether the selected current audio-I/O library and build configuration support ASIO. If not, compare a separate ASIO adapter against replacing the I/O library. Evaluate licensing, maintenance, device enumeration, sample formats, channel layouts, latency, CI coverage and coexistence with WASAPI. Do not force ASIO into the common engine core.

### 4.2 Device and stream lifecycle

The audio-device subsystem must handle:
- Device enumeration, selection, default-device changes and unplug/replug.
- Stream start/stop, suspend/resume and application foreground/background transitions.
- Sample-rate, channel-count, sample-format and buffer-size changes.
- USB interface connection and removal, subject to platform support.
- Bluetooth route changes, with honest reporting of their latency and limitations.
- Driver/API initialization errors, callback errors and device invalidation.
- Safe fallback to another compatible device when policy allows.

Device loss must not corrupt project state or terminate unrelated UI. Preserve transport/project intent where possible, but resume audio only after the new stream is successfully prepared. Do not silently switch to an unsuitable output or claim that recovery succeeded when it did not. Expose clear status and a user-controlled retry/device-selection path.

### 4.3 Audio capability negotiation

Represent channel layouts, sample formats, rates, block sizes and input/output buses explicitly. Query capabilities and negotiate a supported configuration. Do not assume stereo, 44.1/48 kHz, a fixed buffer size or a fixed number of channels.

Keep logical engine channel routing separate from physical device channel mapping. Logical channels are individually addressable; channels 1 and 2 are conventional stereo left/right by default, not a hard-coded restriction on all other channels. Any logical channel may be mapped to a compatible plugin, bus, sidechain, hardware output or other destination.

### 4.4 Clock, timestamp and latency management

**[Proposal]** Treat time as an explicit domain at every audio/MIDI/capture boundary. Sample position, device clock, host transport time, musical beat time and wall-clock time are not interchangeable.

Define:
- A monotonic engine sample timeline for deterministic processing and offline rendering.
- Explicit timestamps and clock-domain identifiers for audio devices, MIDI input, host transport and capture sources.
- A conversion/estimation layer that maps external timestamps into engine time, including measured offset and drift.
- A bounded drift-correction strategy for independent input/output devices. Where clock rates differ, use controlled asynchronous resampling or another measured correction method; never periodically drop/duplicate arbitrary samples.
- Sample-accurate event placement within a processing block, including note-on/off, automation, modulation and transport changes. If an external source provides only coarse timestamps, preserve that precision honestly.
- Latency accounting for device buffers, converters, module/plugin processing, lookahead, resampling and capture paths. Distinguish known, reported and estimated latency.
- Delay compensation at the relevant routing/recording boundary, with explicit behavior for live monitoring and feedback paths.
- MIDI clock, MTC/host transport and external sync only where supported by a real adapter; a decoded MIDI message is not proof of a synchronized device connection.
- Deterministic offline render behavior: external live clocks are frozen into a defined render timeline or rejected with a clear explanation.

Tests should simulate clock-rate mismatch, timestamp jitter, missing/out-of-order events, device restart and sample-rate changes. Verify long-run drift, event alignment, loop boundaries, capture alignment and no callback blocking. Do not promise multi-device sync or universal automatic delay compensation until physical-device tests establish it.

## 5. DSP and algorithm interchangeability

**[Proposal]** Algorithms should be replaceable behind typed, narrow interfaces where implementations have the same semantic contract.

Candidate algorithm families include:
- Resampling and interpolation.
- FFT and spectral analysis.
- Oscillators, waveform generation and anti-aliasing.
- Filters and filter topologies.
- Envelopes, modulation and control-rate conversion.
- Mixing, summing, panning and channel conversion.
- Compression, limiting, saturation and distortion.
- Time-stretching and pitch-shifting.
- Metering, loudness and stereo analysis.
- Buffer transforms, bit/byte operations and sample-format conversion.

For each family:
- Define input/output format, latency, state, reset and determinism behavior.
- Offer a portable reference implementation where feasible.
- Permit optimized SIMD or platform-specific implementations behind the same semantics.
- Select quality/performance modes explicitly; never silently change sound semantics.
- Validate numerical behavior, denormals, clipping, channel handling and edge cases.
- Benchmark in representative real workloads, not isolated synthetic loops alone.
- Keep algorithm selection deterministic and project/preset state reproducible when required.

A faster algorithm is not automatically equivalent. Audio-quality and determinism tests must accompany performance comparisons.

## 6. Fault isolation and recovery

### 6.1 Failure domains

Design explicit failure boundaries for:
- Audio device backends and stream instances.
- Individual optional DSP/effect modules.
- Third-party or untrusted plugin/module execution.
- File import/export and preview jobs.
- Asset decoders and thumbnail/waveform generation.
- UI workspaces and optional visualization.
- Background compilation, analysis and rendering jobs.
- Platform services and permissions.

A failure should disable or restart the smallest component that can safely be isolated. Report the component, operation and recoverability without flooding logs or hiding the cause.

### 6.2 Isolation proportional to risk

Do not put every operation in a separate process or thread. That would add scheduling, memory, IPC and synchronization overhead, especially on low-end phones.

Use the lightest safe boundary:
- In-process interfaces and local error results for trusted, low-risk components.
- Bounded job workers for expensive non-real-time tasks.
- Sandboxed execution for downloaded/untrusted modules, retaining existing memory/instruction/I/O limits.
- Stronger process isolation for third-party native plugins or components that cannot be safely contained in-process, where platform support and overhead justify it.
- A dedicated real-time audio execution boundary with strict callback rules.

An exception, invalid parameter or allocation failure must not escape across a public API or cross-language boundary. Convert it into a typed error/status result. Do not catch and ignore errors indiscriminately.

### 6.3 Audio failure behavior

- A failing optional effect should be bypassed or marked unavailable without corrupting other tracks.
- A failed plugin/module should not take down the host; use the strongest isolation practical for native third-party code.
- Device/backend failure should stop or reconfigure the stream safely, not corrupt the engine project.
- A failed background render should clean temporary outputs and leave live playback state untouched.
- A UI scope/spectrum/visualizer failure must not stop audio processing.
- If the core engine itself becomes invalid, stop audio safely and preserve the last valid project/state snapshot; do not continue processing corrupted state.

Define which failures permit automatic retry and which require user action. Avoid endless restart loops.

### 6.4 Security and trust boundaries

Fault isolation and security overlap, but they are not the same. A component can fail independently and still have excessive authority. Assign each executable component an explicit trust class and least-privilege capability set.

- **Built-in engine code:** trusted application code, still subject to validation, bounds, sanitizers and fault reporting.
- **Downloaded `.caw` source / bytecode:** untrusted. Preserve the VM's no-I/O/no-network/no-filesystem model and enforce source/program size, memory, instruction/loop/call-depth and per-block execution budgets. Validate before activation; stop or reject runaway work without affecting other tracks.
- **Third-party native modules:** trusted only after explicit installation/approval and integrity/provenance checks; an ABI contract does not make native code safe. Default to an isolated host process for untrusted native binaries when the platform supports it. If only in-process execution is available, clearly mark it as trusted-code-only and do not market it as sandboxed.
- **Project, preset, package and asset files:** untrusted input. Apply parser limits, schema validation, path traversal/symlink protections, size limits, decompression limits and safe handling of malformed or future-version content. Never execute content merely because it was imported.
- **UI extensions and custom views:** separate presentation privileges from audio processing; do not grant file/network/device access by default.
- **Platform services:** request only the permissions needed for the feature and handle revocation as a normal capability change.

A future native-module sandbox should define IPC messages, buffer ownership, process lifecycle, crash/restart policy, CPU/memory quotas, timeout semantics and audio transport. Measure IPC and buffering latency before choosing it for real-time DSP. If it cannot meet the deadline, do not silently fall back to unsafe in-process execution; disable that module or require explicit trusted mode.

Integrity checks and signatures establish package identity/provenance, not benign behavior. Keep permissions, trust decisions, compatibility validation and runtime containment as separate controls. Never embed privileged credentials in the app.

## 7. Real-time engine and scheduling

Retain the existing control-thread preparation / audio-thread execution principle.

**[Proposal]** Control-side work validates project state, resolves connections, negotiates layouts, compiles modules/curves, allocates and reuses buffers, builds routing and prepares bounded execution plans. The audio callback consumes a prepared immutable or safely published plan and performs only bounded operations.

- Never allocate, lock, log, perform file/network I/O, call UI code or wait for workers in the callback.
- Publish configuration changes at safe block boundaries using explicit lifetime/reclamation rules.
- Retire old plans and free resources off the audio thread.
- Bound event queues, graph complexity, voices, buffers, memory and processing time.
- Define overload behavior: voice stealing, optional-node bypass, quality reduction only when explicitly permitted, or safe silence rather than deadline overrun.
- Parallelize independent paths only when the work size justifies scheduling overhead and results can be synchronized before the deadline.
- Do not wait for a general-purpose worker pool from the real-time callback.
- Keep audio scheduling independent from UI refresh cadence and background export.

## 8. Whole-application optimization

Optimization covers the complete application, not just DSP.

### 8.1 Areas to measure and optimize

| Area | Measures and targets |
|---|---|
| Audio | Callback mean/p99/max, deadline misses, dropouts, latency, CPU, voice/polyphony scaling. |
| UI | Frame time, input-to-feedback latency, rebuild/layout/paint counts, scroll/timeline smoothness. |
| Memory | Startup/steady-state RSS, peak memory, allocation rate, retained caches, fragmentation and memory pressure. |
| Startup | Cold/warm startup, first sound, first workspace, device initialization and project-open time. |
| Battery/thermal | Idle draw, playback draw, export draw, temperature and sustained performance on real phones. |
| Background work | Worker count, wakeups, queue depth, CPU quota use, cancellation and idle retirement. |
| Files/assets | Scan/index time, preview generation, cache hit rate, import/export throughput and large-project behavior. |
| Graphics | GPU/CPU composition cost, overdraw, animation cost and behavior on weaker devices. |
| Platform integration | Device recovery time, audio route changes, permission/lifecycle handling and backend-specific stability. |

### 8.2 Hardware-aware execution

- Detect effective CPU and memory budgets using platform-appropriate signals; treat unknown values as unknown, not as unlimited resources.
- Use SIMD and optimized code paths only when supported and validated.
- Scale worker concurrency to actual queued demand, available cores, memory and thermal/battery pressure.
- Avoid creating idle workers or polling loops without work.
- Reuse buffers and scratch memory; avoid copies and repeated conversions.
- Cache expensive derived data with bounded memory and explicit invalidation.
- Keep expensive analysis, file access, compilation and offline rendering away from the audio callback.
- Reduce decorative rendering and nonessential background work before reducing essential interaction feedback.
- Adapt to thermal throttling and low-memory pressure without silently changing audio semantics.
- Ensure the app remains useful when advanced acceleration is unavailable.

### 8.3 Optimization acceptance

No performance improvement may be claimed without:
- A reproducible baseline and after measurement.
- The same project, workload, build mode, hardware and relevant settings.
- Mean and tail latency (at least p95/p99 where meaningful), not only averages.
- Correctness/audio regression tests.
- Memory and power/thermal impact where relevant.
- A record of trade-offs and platforms not tested.

Use the existing [performance note](performance.md) as the measurement baseline and update it when actual code changes or new measurements are made. Cloud benchmark numbers are not phone measurements.

### 8.4 Resource governance

The repository already has a hardware profile, workload planner and bounded worker pool. The missing direction is to make resource ownership and budgets consistent across the whole app without creating a synchronous global bottleneck.

**[Proposal]** Each workload declares its class, priority, estimated CPU/memory needs, concurrency, cancellation behavior, foreground sensitivity and whether it is deadline-bound. The scheduler combines that request with observed capacity and pressure, then returns an explicit grant, defer, reduce-concurrency or reject decision.

Coordinate budgets for:
- CPU time and worker concurrency.
- Memory, scratch buffers and retained caches.
- Audio callback headroom and voice/module execution limits.
- GPU use only when transfer/setup cost is amortized.
- Storage, temporary render space and preview caches.
- Battery, thermal and foreground/background state.

Rules:
- Reserve audio callback capacity first; background jobs never consume callback time or wait from the callback.
- Use one workload vocabulary across app, engine, CLI and add-ons; avoid each subsystem inventing its own thread pool.
- Account for shared resources and nested jobs so a render spawning analysis jobs cannot oversubscribe the device.
- Use bounded queues, explicit backpressure, cancellation and fair priority aging; prevent background starvation and foreground stalls.
- Cache budgets must be bounded and reclaimable. A cache entry needs an owner, size/cost, invalidation rule and eviction policy.
- Unknown capacity remains unknown and triggers conservative defaults, not an assumption of unlimited resources.
- Thermal/memory/battery pressure may defer or reduce background work. It must not silently change deterministic audio output or degrade a user's active sound without an explicit mode/choice.
- Record why work was deferred or constrained so the UI can explain it.

Resource decisions should be advisory/preparatory and observable; avoid a central lock or per-sample resource query. Measure policy overhead and verify it does not cost more than the work it coordinates.

### 8.5 Diagnostics and observability

Diagnostics should make performance and failure causes visible without becoming a source of overhead or instability.

Define a small common event/metric vocabulary across engine, app, backend, scheduler and module host:
- Callback duration distribution, deadline misses, underruns/dropouts and current headroom.
- Device/backend state transitions, negotiated format, route changes and recovery outcomes.
- Per-module/per-track processing cost where it can be measured safely, plus voice and graph load.
- Worker queue depth, wait time, active workers, cancellation, starvation and rejected/deferred jobs.
- Memory usage, cache occupancy/evictions, allocation pressure and large project/import/export sizes.
- UI frame/build/paint cost, dropped frames and input-to-feedback latency.
- Battery/thermal/power-saver signals where the platform exposes them.
- Module validation failures, crashes/timeouts, project recovery and migration failures.

Implementation constraints:
- Audio callback writes only fixed-size counters or bounded lock-free telemetry records; no formatting, logging, allocation or I/O there.
- Drain and aggregate telemetry off the audio thread. Use sampling and configurable detail levels.
- Keep a low-overhead always-on health summary and opt-in deeper profiling; allow diagnostics to be disabled or reduced on low-end devices.
- Rate-limit repeated errors, preserve the first/root cause and attach component/operation IDs.
- Avoid collecting project source, user file paths, credentials or personal content in diagnostic records by default.
- Expose actionable states to the UI and CLI, but keep UI rendering independent from audio execution.
- Provide tests proving instrumentation can be disabled and that enabling it stays within a measured overhead budget.

Do not present an estimate as a measurement. Every metric should state its source, time window and whether it is measured, inferred or unavailable.

## 9. UI and backend independence

- UI code must not own audio-device or DSP implementation details.
- UI communicates through application services and stable engine APIs.
- Audio callbacks never call into Flutter/Dart or depend on widget lifecycle.
- Workspaces subscribe only to the state they display; scoped updates must not trigger unrelated rebuilds.
- Optional scopes, spectra, meters and animations must be independently pausable and must not affect audio correctness.
- A workspace can be replaced or redesigned without changing project serialization or engine execution.

- UI workspaces must consume capability and health snapshots through app services; they must not independently probe devices or infer support from platform names.
- Diagnostic overlays and advanced inspectors are optional consumers. They can be hidden or suspended without disabling the underlying instrumentation or audio engine.
- Commands that mutate project state should pass through one application command/state path so undo, dirty-state tracking, autosave and all workspaces observe the same change.
- Platform-specific UI behavior belongs in platform adapters or presentation policy, not scattered platform checks throughout feature logic.

## 10. Project integrity and crash recovery

**[Proposal]** Treat project durability as a cross-layer contract. The existing atomic restore-point feature is a foundation, not a substitute for a complete save/recovery design.

Define:
- One authoritative project mutation/command path shared by Builder, Arranger, Mixer, Engine Lab, automation, files and background jobs.
- Dirty-state tracking based on committed project mutations, not widget-local state.
- Autosave checkpoints with a documented cadence/trigger policy, coalescing rapid edits and never blocking the audio callback or UI thread.
- Atomic persistence: write to a temporary file in the same storage domain, flush/close as required, validate the completed artifact, then replace the prior version safely. Preserve the last known-good project on failure.
- A bounded recovery journal or checkpoint strategy that can replay/restore after process termination without replaying partially committed operations.
- Crash-safe export staging: write to temporary output, finalize only on success, and leave a recoverable/cleanable record after cancellation or interruption.
- Versioned schema migrations with a restore point before destructive conversion; reject malformed or unsupported future formats without overwriting the original.
- Explicit policies for storage-full, permission-revoked, disk-write failure, app termination, device reboot and concurrent edit attempts.
- Undo/redo history that remains consistent with saved state and is not silently discarded by autosave or project reload.
- Asset dependency snapshots and stable IDs so project recovery does not silently bind to a different global asset version.

Recovery must be testable through injected termination/failure points: during write, before atomic replace, after replace but before UI confirmation, during migration, during export and while a background job is cancelled. Verify last-known-good recovery, no half-written visible project, correct dirty state and clear user messaging. Do not promise zero data loss until the recovery-point objective is measured and documented.

This section supplements the file-management and restore-point scope in the [master development plan](CAW_MASTER_DEVELOPMENT_PLAN.md); it does not claim full autosave/journaling is implemented.

## 11. Testing and verification strategy

Add tests at the boundary where each contract can fail:

1. **Contract tests:** each implementation conforms to the shared interface.
2. **Unit tests:** algorithms, conversion, lifecycle, state transitions and error mapping.
3. **Fault-injection tests:** device disappearance, invalid formats, backend initialization failure, effect exception, plugin timeout/crash, memory exhaustion and worker cancellation.
4. **Integration tests:** app ↔ native API, project ↔ engine, device backend ↔ engine, UI ↔ shared state.
5. **Audio tests:** golden renders, stereo/channel mapping, scheduling, sample-rate changes, buffer-size changes and deterministic behavior.
6. **Performance regression tests:** existing benchmarks plus representative project/UI scenarios with explicit budgets.
7. **Platform CI:** build and test every supported backend/platform configuration that CI can execute.
8. **Physical-device validation:** Android USB audio, built-in route changes, sustained playback, background/foreground, thermal pressure, battery and low-memory behavior; corresponding desktop device/driver tests.
9. **Recovery tests:** prove the affected feature fails safely and unrelated features remain functional.

CI cannot prove physical driver latency, battery use, thermal behavior or USB compatibility. Report those as unverified until tested on actual hardware.

## 12. Implementation sequence

This is a proposed order, not authorization to start a broad rewrite.

1. **Inventory and baseline:** map actual interfaces, dependencies, platform backends, build flags, error paths, callback rules and current performance measurements. Reconcile this plan against [engine-next](engine-next.md), [engine integration](engine-integration.md), [native module SDK](native-module-sdk.md), [master development plan](CAW_MASTER_DEVELOPMENT_PLAN.md) and [performance](performance.md); do not create duplicate systems.
2. **Boundary and capability map:** identify cross-layer reach-through, shared mutable state, cycles, implicit side effects, capability gaps and failure propagation. Document actual capability providers and consumers before introducing a registry.
3. **Contract gaps:** define only the smallest missing interfaces needed for interchangeability and testing. Reuse the existing C ABI, module SDK, worker pool and project restore-point work where they fit.
4. **Durability and trust audit:** inspect actual save paths, parsers, VM limits, package handling and native-module boundaries. Close the highest-risk project-corruption and untrusted-code gaps before broad extension support.
5. **Device lifecycle and time model:** verify miniaudio capabilities; test Android routes/USB, Windows WASAPI and ASIO as a separate decision; define timestamp/clock/latency behavior before claiming synchronized capture or external MIDI.
6. **Resource governance and diagnostics:** extend the existing worker scheduler with measured memory/cache pressure and bounded telemetry; do not replace the current pool with a second scheduler.
7. **Fault containment:** add typed errors, bounded recovery and fault-injection tests at real component boundaries.
8. **Algorithm interchangeability:** select one measured high-value algorithm family at a time; preserve semantics and compare implementations.
9. **Optimization passes:** profile real bottlenecks, fix one measurable bottleneck at a time and retain before/after evidence.
10. **Cross-platform verification:** validate CI and physical-device behavior, document unsupported capabilities and known limitations.
11. **Ongoing architecture review:** every new feature should state its module boundary, dependencies, capability requirements, lifecycle, trust level, failure behavior, resource budget and tests.

Do not resume paused Stage 5 graph-to-engine integration or create a parallel universal graph/framework merely because this document discusses modularity. Respect the existing owner pause and current task boundaries.

## 13. Definition of success

C.A.W. meets this direction when:
- A feature can be added or replaced without broad unrelated changes.
- Platform audio APIs are adapters, not dependencies of the sound engine.
- Android and iOS have native low-latency audio paths; Windows can offer WASAPI and a separately evaluated ASIO option.
- Device loss and optional component failures do not cascade through the application.
- Audio remains real-time safe and project state remains recoverable.
- Algorithms can be exchanged without changing consumers, with validated semantics.
- Hardware resources are used only when they benefit the current workload.
- Idle overhead is minimal, and weak devices remain supported.
- Performance claims are backed by repeatable measurements on the hardware named.
- Tests prove both that the failing component is contained and that unrelated functionality continues working.

## 14. Open technical decisions

These require repository/source verification and, where they affect product behavior, owner approval:

- Does the current miniaudio version/configuration expose every desired Windows backend, and what is the best licensed/maintained route to ASIO?
- Is Oboe materially better than the current Android AAudio path on supported target devices, measured on hardware?
- Which plugin/module types warrant process isolation versus in-process sandboxing?
- What recovery policy should be used when the current output disappears during playback?
- Which DSP algorithm families have enough measured cost to justify interchangeable implementations first?
- What performance budgets should be enforced for low-end Android, mid-range Android and desktop reference machines?
- Which platform/backend combinations can be tested in CI, and which require a physical-device release checklist?

Do not treat these open decisions as settled by this plan.
