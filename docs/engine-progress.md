---
title: Native engine refactor progress
summary: Live milestone ledger and exact continuation point for the native engine refactor.
covers: [engine/, app/]
updated: 2026-11-02
---

# Native engine refactor progress

## Current state

- **Branch:** `feature/native-engine-refactor-integration`
- **Base:** `Main` at `20fd3da9a37f8936f1c3ff6069878978d064ae37`; branch is 29 commits ahead and 0 behind.
- **Starting point:** `refactor/native-engine-foundation` at `49ba277f91bc9349f70d492c32e5f498d692e9b3`, which was 15 commits ahead and 0 behind Main when selected.
- **Current branch tip at this status record:** 32 commits ahead and 0 behind Main; the accompanying native code commit is `07c796f8e745cd44e7be37992747b8263ac27e9a`.
- **Previous fully verified native code checkpoint:** `eb465f4a1489d30beb34801e52bc1e7ddc2e7577`. The new graph-budget code commit `07c796f8e745cd44e7be37992747b8263ac27e9a` is implemented but awaits CI.
- **Issue:** #28, open and `status: in progress`.
- **PR:** none. Open one coherent PR only when the complete refactor is genuinely reviewable. Do not merge or approve it.
- **Current milestone:** M1 — core execution foundations (**IN PROGRESS**). M0 is **VERIFIED**.
- **Last implementation step:** introduced mandatory `GraphResourceBudget.maxWorkingBytes` for graph compilation and executor preparation; optional node/connection ceilings default to `size_t` maximum rather than imposing product caps. Preflight estimates internal working memory, returns distinct invalid-budget/budget-exceeded/size-overflow errors, and still reports real allocation failure as `OutOfMemory`. Duplicate IDs now use deterministic sorted lookup; adjacency and ready-heap storage are reserved before use.
- **Implementation commits:** `979d25abcd7794731c58fbce72c7522bc442612e` (graph caps); `37d75466cf1b58944aa5e4be8a0d91ecd9834c2a` (scalable validation/OOM); `eb465f4a1489d30beb34801e52bc1e7ddc2e7577` (large graph/block tests); `07c796f8e745cd44e7be37992747b8263ac27e9a` (explicit graph working-memory budget and boundary tests).
- **Current code changed:** `engine/src/graph.h`, `engine/src/graph.cpp`, `engine/tests/graph_test.cpp`. No graph/VM playback integration has been implemented yet.

## M0 — repository recovery and architecture audit

<badge color="success">VERIFIED</badge>

- Read AGENTS/CLAUDE, applicable .claude rules and skills, engine blueprint, decisions/log/roadmap/architecture/status docs, relevant source, tests and workflows.
- Confirmed PR #68 is merged into Main at `20fd3da`; project parameter/global automation is part of the baseline.
- Confirmed there were no open PRs at the start of this task. The foundation branch was the correct base; the implementation branch preserves it and is still 0 commits behind Main.
- Inspected the native VM/compiler, synth, project parser, layer/chain mixer, voice engine, pattern parser, automation, graph compiler/executor/runtime, module descriptors/registry, worker scheduler, hardware policy, MIDI decoder/queue, C API and Flutter bridge.
- Inspected native tests for engine routing/automation/hot swap, graph, module/registry, MIDI 2.0, patterns/voices, scheduler/execution, dependencies, plus app project/pattern/engine tests.
- Inspected Engine, App and Docs workflows and the current branch's successful CI results.

## Verified architecture and integration gaps

- Existing foundations include the .caw compiler/VM, synth patch translation, layer/chain mixer, folder buses, module import/export wiring, project parameter/global automation, MIDI file import/export, MIDI 2.0 UMP decoding/queue, typed module descriptors, static module registry, graph compiler/executor/publication helper, dependency resolver, hardware policy and bounded background worker pool.
- **Critical integration gap:** `Engine::setProject` compiles programs and creates legacy `Chain` instances. `Engine::process` calls `processChunk`, which manually schedules layers/buses; `processSlot`/`runChain` execute the VM. `GraphExecutor`, `GraphRuntime` and `ModuleRegistry` have no production references from Engine, VM, C API or Flutter.
- The graph compiler now has no arbitrary fixed node/connection count cap. `GraphResourceBudget` requires a non-zero `maxWorkingBytes`; optional `maxNodes`/`maxConnections` ceilings default to unlimited. Compile and executor preparation estimate their internal working set before allocating; the estimate excludes caller-owned graph input and processor instances, and actual allocator failure remains a separate `OutOfMemory` result. Node references remain `uint32_t` (a representation boundary); the executor's former 8,192-frame cap is removed. This budget is not yet derived from hardware or passed by the active Engine.
- **Graph runtime is still limited:** stereo audio only, one input and one output per node, one driver per input port, 8–192 kHz. No multi-input mixing, multiple outputs, custom/multichannel channel mapping, control/modulation/event/MIDI runtime buffers, timestamped event scheduling, cross-domain conversion or delayed feedback edges. There is no explicit prepared-buffer byte budget yet.
- `ModuleProcessor` is still a borrowed stereo-block contract. Port descriptors identify audio/control/modulation/event types, but typed descriptors do not provide runtime buffers for those domains.
- `ModuleRegistry` is static/in-process only. No dynamic loader, production host adapter, capability negotiation or native crash isolation exists. Trusted native code is not sandboxed; the .caw VM remains the constrained untrusted-code path.
- MIDI 2.0 decoding/queue are primitives only. `Midi2Event` has no sample timestamp, there is no live USB/Bluetooth device adapter, and events are not routed into Engine voices. Queue overflow is counted but not surfaced through the app.
- The app C API/FFI remains API v1. The app submits project compilation, source checks and offline WAV renders to the native worker pool; it does not submit graph execution or native module work.
- Existing synth modulation, sidechain ducking effects, per-note expression and project automation are partial foundations, not the unified parameter/routing system requested.

## Fixed limits and correctness risks

Graph compile/prepare now require an explicit working-memory budget and preflight internal storage estimates; allocator overhead is implementation-dependent, so actual allocation failure is still handled. The budget is not yet derived from hardware or passed by the active Engine. The following limits and loss paths remain in the current source and must be converted to explicit, configurable resource budgets or dynamic storage:

- **Project structure:** 64 layers/slots; 9 modules per layer chain; project module parsing stops at 256; clips stop at 512 per layer; project automation lanes stop at 256; automation points stop at 128; dependency records above 4,096 are rejected; arrangement length/loop is clamped to 64 bars.
- **VM/module:** 32 parameters; 64 synth parameters; 16 exports; 32 imports; 6 call arguments; 1,024 VM registers; 64 KiB source; 8 MiB state per module; 32 voices; compiler depth/call budgets.
- **Pattern/MIDI:** 4,096 pattern notes/steps; 16 points per note curve; 16 MiB JSON/MIDI file limits; 65,536 MIDI events; 4,096 MIDI notes/steps; MIDI 2.0 input queue capacity 1,024 (drop-newest with a counter).
- **Runtime queues/state:** 1,024-entry command queue; 1,024-entry retirement queue; 256 pending retirements; 2 MiB state-takeover threshold; 64 MiB project-state budget. Worker pool has a maximum of 16 workers and a 256-job queue.
- **Confirmed silent/lossy behavior:** arrangement compilation stops adding notes at 4,096; export collection stops at 16; automation arrays stop at 128; no free layer slot causes a planned layer to be skipped; command submission retries for about two seconds then can drop an install/pattern without propagating failure; retirement overflow can leak after the pending list fills; project-state overflow warns while leaving a layer silent. Parser module/clip/automation/chain excess may be truncated or skipped; other limits return errors.
- Some limits are legitimate sandbox/parser safety budgets. They must remain explicit, configurable within host policy where practical, and fail clearly. Project content must never be silently truncated or a track silently omitted. Real-time event queues may be bounded, but overflow must be visible and recoverable.

## Milestones

| ID | Objective | Status | Evidence / remaining work |
|---|---|---|---|
| M0 | Repository recovery and architecture audit | **VERIFIED** | Instructions, design/status docs, source, tests, workflows, branch/PR/issue state and app bridge inspected. Confirmed PR #68 merged, no open PRs, current branch ancestry and CI. |
| M1 | Core execution foundations, lifecycle, buffers, ownership and graph publication | **IN PROGRESS (PARTIAL)** | Graph scaling, explicit working-memory budget, deterministic ID validation and large-size/budget tests are implemented in code commit 07c796f8; CI is pending. Still needs hardware-derived Engine budget wiring, prepared processor ownership/lifecycle, project snapshot publication, safe retirement and Engine/VM integration. |
| M2 | Universal typed routing | **NOT STARTED (FOUNDATION PARTIAL)** | Descriptors exist, but runtime remains stereo audio one-in/one-out. Add multichannel, fan-in/fan-out, buses/sends/returns, sidechains, control/modulation/events/MIDI and delayed feedback. |
| M3 | Unified parameters/modulation/automation | **IN PROGRESS (PARTIAL)** | Synth modulation and project parameter/global automation exist. Unify manual controls, automation, modulation, MIDI/controller mappings, note expression and sidechain-derived control across VM/native modules/tracks/buses. |
| M4 | Extensibility and mathematical processing | **IN PROGRESS (PARTIAL)** | .caw VM and static registry exist. Add capability declarations, stable API/state versioning, ownership, failure/bypass and advanced extension paths. Native in-process code remains trusted, not sandboxed. |
| M5 | MIDI and event integration | **IN PROGRESS (PARTIAL)** | UMP decoder, bounded queue, note expression and MIDI files exist. Add timestamped events, live device I/O, voice routing and MIDI 1.0/2.0 scheduling. |
| M6 | Adaptive concurrency and batching | **IN PROGRESS (PARTIAL)** | Adaptive non-real-time pool and hardware policy exist. Remove arbitrary worker ceiling; integrate dependency-aware graph/voice/offline scheduling, batching and measured SIMD paths. |
| M7 | Application/project integration | **IN PROGRESS (PARTIAL)** | Flutter uses C API v1 and native worker jobs. Graph/project serialization, richer routing/parameter controls, module lifecycle and migrations remain. |
| M8 | Optimization and validation | **NOT STARTED** | Profile the integrated runtime; stress-test resource pressure, compatibility, parity, sanitizers, deadlines and weak/strong hardware; remove obsolete paths only after verified migration. |

## Verification record

- **Current branch tip at this status record:** 32 commits ahead, 0 behind Main; native code commit `07c796f8e745cd44e7be37992747b8263ac27e9a` is the implementation checkpoint recorded here.
- **Latest graph-budget code commit:** `07c796f8` has not yet completed CI. The preceding docs-only checkpoint `1370a43` had Engine workflow `41402930328`: Linux x64, Linux Arm64 and Linux sanitizers passed; Windows remained in the Build step for over 15 minutes. The identical native code at `eb465f4` had already passed Windows x64 in Engine run `41401179084`; the new graph-budget code must receive a fresh Windows result before it is considered verified.
- **Docs/hygiene:** workflow `41402930329` passed at the preceding docs-only checkpoint `1370a43`; the new status/code commit will trigger a fresh Docs check.
- **App:** workflow `41401179166` at code checkpoint `eb465f4` — Dart analysis, Dart tests, Windows app and Android APK all **SUCCESS**. No app source changed after that run.
- **Earlier Engine/Docs:** `41401179084` and `41401179017` at `eb465f4` both passed.
- **Earlier Docs failure:** `41401014639` failed because progress/recovery docs were not linked from `docs/index.md`; fixed in `d1677c7`, later Docs workflows passed. Do not repeat this omission.
- **Local build/tests:** unavailable in this connector-only workflow. GitHub Actions is the compiler/test runner; never claim local reproduction.
- **Hardware validation:** no physical-device performance/audio-latency test has run. CI does not prove phone latency, thermal behavior, battery use or dropout resistance.

## Exact next actions

1. Wire `GraphResourceBudget` into a hardware-derived `EngineResourceBudget`; validate estimates against real allocator behavior and add profiling/overflow tests. The lower-level graph API and budget-boundary tests are implemented but the current code commit still needs CI verification.
2. Establish a prepared project/runtime snapshot as the publication unit. Build modules, graph, routing, schedules, buffers and migration plan off the callback; publish atomically at a block boundary; reclaim old snapshots off the callback. Replace per-layer partial project command submission with a transactional update. Fix command timeout/drop, retirement overflow/leak and slot-exhaustion loss.
3. Generalize the module process contract and graph executor: multichannel/custom layouts, multiple inputs/outputs, fan-in/fan-out, channel mapping, audio/control/modulation/event/MIDI buffers, timestamp ordering and explicit delayed feedback boundaries.
4. Integrate the prepared graph with existing VM instances, voices, patterns, imports/exports, automation, folder buses, offline rendering and state migration. Do not create a second engine.
5. Replace fixed project/VM/voice/automation/event caps with resource-derived storage and actionable errors; remove silent truncation, 64-bar clamp and 64 MiB layer-silencing behavior. Update app model/parser tests that currently encode these caps.
6. Continue unified parameter resolution, native module lifecycle/extensibility, MIDI device/event routing, adaptive scheduling/batching and Flutter/project integration.
7. At each coherent milestone, add tests, update this ledger/status/log, push and wait for affected CI before the next code change. Open one coherent PR only when acceptance criteria are met.

## Non-negotiable decisions

- One portable C++20 engine; no competing second engine or duplicate module model.
- Existing .caw VM remains first-class and sandboxed; no filesystem/network/system calls. Trusted native code is not sandboxed without process isolation.
- Audio callback remains allocation-free, lock-free, I/O-free, logging-free, bounded and independent of UI/Dart. Never wait for workers in callback.
- Prepare topology, schedules, buffers, parameter resolution, state migration plans and resource requirements before activation. Reclaim retired state off callback.
- Preserve deterministic semantics, golden audio, project/module compatibility and live/offline parity.
- Adaptive concurrency uses bounded resource-aware scheduling and serial fast paths; no thread-per-task, oversubscription or speculative GPU path.
- No arbitrary product caps. Use explicit budgets, actionable errors and no silent project-content truncation. Bounded real-time queues require visible overflow diagnostics and safe recovery.
- No GPL dependency without owner approval. No in-app AI or cloud-audio integration. Recording remains deferred.
