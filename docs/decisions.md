---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-11-02
---

# Decisions

## 2026-11-02: Prepared project snapshots are the project-publication unit

- Build the complete project runtime on a control/worker thread as one owned prepared snapshot: module instances, VM chains, graph topology, routing, buffers, schedules, parameters, automation, event storage and a bounded state-migration plan.
- Publish one pending snapshot atomically and let the audio callback adopt it only at a block boundary. The callback must not allocate, lock, compile, wait for workers or call the UI.
- Keep the active snapshot alive while it is processed; retire superseded snapshots through preallocated/intrusive retirement records and reclaim them only on a control thread. Replacing an unconsumed pending snapshot must be safe and must not leak.
- Treat project replacement as a transaction. Do not send hundreds of independent layer-install commands that can partially apply when the fixed command queue fills. Keep any remaining live-control queue bounded, coalesced where appropriate, and report overflow to the caller.
- Prepare migration metadata off-thread. Apply only bounded, preallocated state-transfer work at safe block boundaries; if a migration cannot fit the configured real-time budget, defer activation or return an actionable error rather than blocking or silently resetting state.
- This is the target M1 architecture; it is a decision, not a claim that the current Engine already implements it. The current command queue can drop installs after its timeout, the retirement pending list can leak on overflow, and slot exhaustion can skip a layer.

## 2026-11-02: Reopen and complete native engine integration

- The owner explicitly authorizes the full native engine refactor and integration, superseding the earlier note that graph-to-Engine integration was paused.
- Start from the verified native-engine-foundation branch history, but integrate into the existing Engine/VM/mixer. Do not create a second engine or stop at interfaces and documentation.
- Keep the permanent engine blueprint, milestone ledger and recovery guide current; one coherent review PR is the delivery target.
- The graph compiler must not impose arbitrary node/connection/block caps. Resource limits must reflect actual memory, hardware and host safety budgets, with explicit errors and no silent content loss.


## 2026-11-02: Adaptive concurrency and batching

- Concurrency and batching are foundational capabilities, selected automatically according to graph dependencies, workload size, deadlines and available hardware.
- Parallelize independent work across graph branches, tracks, voices, channels and offline tasks where it yields a net benefit; batch compatible operations and use SIMD/accelerators when transfer and setup costs justify them.
- Avoid arbitrary thread counts and unconditional parallelism. Use bounded worker pools, adaptive task granularity, serial fast paths and controls against oversubscription.
- Preserve sample accuracy, deterministic semantics where required, audio deadlines and stable fallbacks. The audio callback must not block waiting for workers or accelerators.
- Optimize measured end-to-end performance, including scheduling, synchronization, memory movement, power and worst-case deadline margin—not just throughput or thread utilization.
- Full requirements: [Native engine refactor, Section 17](engine-next.md#17-adaptive-concurrency-batching-and-minimum-overhead-execution).

## 2026-11-02: Universal creative capability and routing

- The engine must make any technically realizable music/audio idea straightforward to create and combine; standard workflows are defaults, not creative limits.
- Use a universal typed multi-domain graph for audio, multichannel streams, sidechains, control/modulation, MIDI 1.0/2.0, notes, per-note expression, transport and timestamped events. Support cross-domain routing and explicit feedback/delay boundaries.
- Sidechain is first-class and can accept any compatible source, including audio, buses, tracks, external inputs, MIDI/events, envelopes and control signals. It must work across channels, processors and buses through the shared routing model.
- Avoid arbitrary fixed caps on project objects or graph complexity. Real constraints are available resources, platform/format requirements and explicit safety budgets. Surface unavoidable limits and never silently truncate.
- Make resource budgets configurable within host safety policy; enforce real-time bounded work, isolation, diagnostics, graceful bypass/recovery and clear failure reporting.
- Keep common workflows simple and fast while providing advanced extension interfaces for unusual processing, routing and execution models.
- Full requirements: [Native engine refactor, Section 16](engine-next.md#16-universal-creative-capability-safe-extensibility-and-unrestricted-composition).

## 2026-11-02: Safe extensibility for unconventional engine behavior

- The standard engine path is the efficient default, not a creative limitation. Developers must be able to build unusual generators, processors, effects, routing, modulation, synthesis and execution behaviors through explicit extension points.
- Provide composable standard interfaces and advanced interfaces where a generic abstraction would constrain a technique or add unnecessary overhead.
- Extensions declare capabilities, channel/event types, latency, resource needs, state and real-time requirements; validate and prepare them before activation.
- Protect the audio thread with bounded work, preallocated resources, defined failure/bypass/recovery behavior and clear isolation boundaries. In-process native extensions are trusted, not sandboxed; sandboxed VM modules remain constrained.
- Version extension APIs and state, preserve project compatibility through migration/capability negotiation, and isolate experimental interfaces from stable core contracts.
- Full requirements and verification are in [Native engine refactor](engine-next.md#16-safe-extensibility-and-deliberate-departures-from-standard-engine-behavior).

## 2026-11-02: Unified parameter, modulation and mathematical processing model

- Manual controls, project automation and internal/hidden modulation must use one shared parameter model across instruments, effects, tracks, buses, native modules and the .caw VM.
- Parameters may be exposed as simple user controls or remain internal; advanced modulation must not clutter ordinary workflows, and every exposed parameter should remain manually controllable.
- Support conventional automation, MIDI/controller input, macros, envelopes, LFOs, note expression, modulation links and sidechain/audio-following sources where available.
- Define explicit, deterministic source-combination, precedence, scaling, clamping and smoothing rules. Evaluate sample-accurately only where required; use block/control-rate processing where it preserves behavior and saves work.
- Mathematical expressions are first-class generators, waveform sources, modulation/control sources and audio effects, with bounded sandboxed execution and the existing .caw VM retained.
- Keep the cheapest correct path: constants stay constant, shared modulation is computed once where possible, and tables/precomputation are used only when worthwhile with a correct fallback.
- Detailed requirements and tests are in [Native engine refactor](engine-next.md#15-unified-parameters-modulation-automation-and-mathematical-modules).

## 2026-11-01: Native engine refactor and efficiency-first architecture

- The next major engine work is a refactor and integration of the existing CAW engine, not a ground-up rewrite or a parallel engine.
- Use proven professional audio-engine foundations and integrate the existing VM, synth, mixer, automation, renderer, typed module/graph and adaptive execution work into one coherent system.
- Avoid unnecessary work and complexity. Use the simplest correct implementation, and introduce additional processing only when requirements justify it.
- Prefer efficient mathematical/procedural DSP for suitable operations; use tables, wavetables, caches and precomputation when repeated work makes them worthwhile and memory permits. Keep the normal calculation path as a safe fallback.
- Detect and use compatible CPU, SIMD, GPU, memory, audio-device, connected-device, power and thermal capabilities when they provide a measured benefit. Keep portable implementations and safe fallbacks; optional hardware must never be required for project correctness.
- Evaluate existing permissively licensed/commercially usable libraries and proven algorithms before writing replacements. No GPL/AGPL, revenue-capped or commercial-only dependency without an explicit owner exception. Review exact versions and transitive licences and record every adopted dependency.
- Keep stereo as the efficient default while making the architecture capable of explicit mono and future multichannel processing.
- Preserve existing projects, modules, sound semantics, deterministic behavior, real-time callback invariants and live/offline render parity.
- The detailed technical plan is [Native engine refactor](engine-next.md). The canonical sequencing is [Roadmap](roadmap.md).

## 2026-11-02: Permanent roadmap and full production direction

- The C.A.W. roadmap is the permanent, canonical plan. It owns feature scope, sequencing, long-term capabilities, performance gates and explicit exclusions.
- Do not maintain competing master plans or separate feature-sequencing documents. Supporting notes may record factual implementation gaps or detailed technical designs, but the roadmap controls ordering.
- The long-term product direction includes the DAW capabilities discussed: non-destructive audio editing, sample authoring, complete mixer/routing, live MIDI and control surfaces, tempo maps, audio/MIDI recording, monitoring, latency compensation, punch/loop recording, takes/comping, plugin hosting, platform support, practical mastering tools, optional collaboration and surround/immersive audio.
- These capabilities are planned in dependency order, not claimed as implemented or all scheduled for immediate work.
- Video synchronization is not a current priority and is excluded from the roadmap unless the owner changes this decision.
- No in-app AI integration remains the current direction.

## 2026-11-01: No in-app AI integration in current scope

- Do not add AI generation, AI editing, source separation, model inference, cloud audio processing or AI-dependent sound features to C.A.W. for now.
- AI coding assistants may still be used externally as development tools; that does not authorize AI functionality in the shipped app or engine.
- Keep GitHub library synchronization/source picking separate and deferred; it is not implemented as an app workflow.

## 2026-10-31: Arrangement-first composition replaces the session grid

- **The old session grid is retired completely.** The Arranger is a horizontal song timeline with track lanes and reusable MIDI clip instances; no clip-launcher/session-grid alternate mode is retained.
- **Track ownership:** generators, effects and mix controls belong to tracks. Clips reference reusable pattern sources and own their start, length, source offset and loop behavior.
- **Folder routing:** nested folders can be organizational or stereo group buses. A bus sums child audio once and applies group volume/pan before routing to its parent or master.
- **Automation:** track volume and pan lanes follow song time and are interpolated in the native callback. Global and module-parameter automation remain future work.
- **Piano-roll multi-clip behavior:** selected companion clips are visible as read-only references; linked clips that share a source edit together. Editing multiple independent sources as one operation remains a follow-up.


## 2026-11-02: Graph compile and preparation require an explicit working-memory budget

- Graph compilation and prepared execution require a non-zero GraphResourceBudget.maxWorkingBytes; the API does not silently choose an arbitrary fixed node or connection cap.
- Optional maxNodes and maxConnections ceilings default to the representational maximum and may be set by host policy when a specific count ceiling is justified.
- Preflight estimates cover internal compiler temporaries and prepared executor buffers; caller-owned graph input and processor instances are excluded. The estimate is a preflight guard, not a replacement for handling allocator failure, which remains a distinct OutOfMemory result.
- The active Engine must eventually derive this budget from the hardware-aware EngineResourceBudget and pass it when preparing the graph. Until that integration exists, the graph API is budget-safe only when callers supply a realistic budget.
- This is implemented in code commit 07c796f8 and passed Engine, App and Docs CI at checkpoint 1269019. Follow-up commit e815b495 adds direct compiler-budget rejection coverage and awaits CI.
