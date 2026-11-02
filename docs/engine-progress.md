---
title: Native engine refactor progress
summary: Live milestone ledger and exact continuation point for the native engine refactor.
covers: [engine/, app/]
updated: 2026-11-02
---

# Native engine refactor progress

## Current state

- **Branch:** feature/native-engine-refactor-integration
- **Base:** Main at 20fd3da9a37f8936f1c3ff6069878978d064ae37. Planning branch refactor/native-engine-foundation was 15 commits ahead and 0 behind Main when selected.
- **Code checkpoint:** eb465f4a1489d30beb34801e52bc1e7ddc2e7577 (22 commits ahead, 0 behind Main before this documentation update).
- **PR:** none. Keep one coherent PR for the completed refactor; do not merge or approve it.
- **Current milestone:** M0 — repository recovery and architecture audit (**IN PROGRESS**).
- **Last implementation step:** removed fixed 1024-node/8192-connection graph compiler caps; duplicate-ID validation is now hash-based; allocation/length failures return OutOfMemory; removed the executor's fixed 8192-frame cap; corrected node-source sentinel width; added large-graph/large-block tests.
- **Files changed:** engine/src/graph.h, engine/src/graph.cpp, engine/tests/graph_test.cpp, and continuity/status docs.
- **Implementation commits:** 979d25abcd7794731c58fbce72c7522bc442612e (graph caps); 37d75466cf1b58944aa5e4be8a0d91ecd9834c2a (scalable validation/OOM); eb465f4a1489d30beb34801e52bc1e7ddc2e7577 (tests).
- **Continuity commits:** 0a6d551a935d7df618740d88e113342195b9f105 (progress); e01e06a68c1f6e246d8a5676bff7dbbee8e76d6e (recovery); d1677c7b3e2d06fd90d3d4ff31d51af0ba6b23a5 (index); cfcd78826b1489ac6ba361333eeba13e5369c21b (log).
- **Inherited planning history:** 15 commits from refactor/native-engine-foundation, including the approved Sections 15–17 blueprint and permanent roadmap changes.

## Verified architecture

- PR #68 (project parameter/global automation) is merged into Main at 20fd3da9a37f8936f1c3ff6069878978d064ae37.
- GraphExecutor/GraphRuntime exist only in graph.h/graph.cpp and their tests/docs. They have no production references from Engine, VM, C API or Flutter. ModuleRegistry likewise has no production Engine integration.
- The active Engine still processes VM instances through Engine::runChain, runVoices and processChunk, with separate chain sequencing, import/export pointer wiring, voice handling, per-sample automation and folder-bus parentSlot routing. This must migrate into one prepared execution model, not a parallel engine.
- GraphExecutor is currently stereo-audio-only, one input/output per node, one driver per input port, and 8–192 kHz. Multichannel, multiple ports/sources/outputs, control/modulation/event/MIDI processing, sidechains and feedback runtime are not implemented.
- ModuleRegistry is static/in-process only. The native SDK header has no production host/loader or process isolation. Trusted native code is not sandboxed; the .caw VM remains the constrained untrusted-code path.
- The owner explicitly reopened the full refactor on 2026-11-02, superseding the older paused-integration note. Preserve product boundaries: no in-app AI; recording remains deferred; practical DAW usefulness remains in scope.

## Remaining fixed limits and silent-loss audit

The graph caps and executor 8192-frame cap are removed. Remaining limits to replace with explicit budgets, dynamic storage or surfaced errors include:
- Project/runtime: 64 layers/slots; 9 modules per chain; 32 voices; 16 exports; 128 volume/pan automation points; 16 note splits per block; 2 MiB state-takeover threshold; 256 pending retirements and 1024-entry command/retirement queues.
- VM/data: 4096 pattern notes/steps; 16 curve points; 32 parameters/imports; 64 synth parameters; 8 MiB per-module state and 64 MiB project state; 64 KiB source; 1024 registers; compiler depth/call limits.
- MIDI/JSON/jobs: 16 MiB JSON/MIDI file limits; 65536 MIDI events; MIDI 2.0 input queue capacity 1024 (drops newest with a counter); worker pool maximum 16 and queue capacity 256.
- Confirmed silent/lossy paths: arrangement compilation stops adding notes at 4096; export collection stops at 16; automation arrays stop at 128; when no layer slot is free, a planned layer is skipped; command submission retries then drops an install/pattern; retirement overflow can leak after the pending list fills. Project parser note/layer limits return errors, chain overflow warns before truncation, and project-state overflow warns while leaving layers silent.
- Some limits are necessary for untrusted VM safety or fixed-width formats, but must be explicit, configurable within host safety policy where possible, and must not silently discard project content.

## Milestones

| ID | Objective | Status | Remaining work |
|---|---|---|---|
| M0 | Repository recovery and architecture audit | **IN PROGRESS** | Instructions and primary design/status docs read; branch/PR/CI and graph/Engine paths inspected. Finish parameter, MIDI, persistence, worker and cap/error audits. |
| M1 | Core execution foundations and lifecycle | **IN PROGRESS (PARTIAL)** | Typed graph, descriptors, borrowed stereo buffers, executor and publication helper exist but are not integrated into Engine/VM. Establish one prepared execution model, ownership, activation, state lifetime and retirement. |
| M2 | Universal typed routing | **NOT STARTED (FOUNDATION PARTIAL)** | Current runtime is stereo, audio-only, one-in/one-out. Add multichannel, multi-port, multi-source, buses/sends/returns, sidechains, control/modulation/events/MIDI and feedback. |
| M3 | Unified parameters/modulation/automation | **IN PROGRESS (PARTIAL)** | Synth modulation and project parameter/global automation exist; unify across VM/native modules/tracks/buses/routes. |
| M4 | Extensibility and mathematical processing | **IN PROGRESS (PARTIAL)** | .caw VM and static descriptors/registry exist; production integration, stable API/state, failure/bypass and native trust isolation remain. |
| M5 | MIDI/events | **IN PROGRESS (PARTIAL)** | UMP decoder/queue, MIDI files and note expression exist; device I/O, graph/voice routing, output scheduling and overflow diagnostics remain. |
| M6 | Adaptive concurrency/batching | **IN PROGRESS (PARTIAL)** | Adaptive non-RT pool exists; integrate graph/voice/offline scheduling, remove arbitrary worker ceiling and benchmark end-to-end cost. |
| M7 | Application integration | **IN PROGRESS (PARTIAL)** | App submits selected native jobs and edits automation; graph/module runtime and project routing/state migration remain unconnected. |
| M8 | Optimization and validation | **NOT STARTED** | Full stress, compatibility, parity, sanitizer, deadline, weak-device and real-device validation. |

## Verification record

- **Engine:** workflow 41401179084 at eb465f4 — Linux x64, Linux sanitizers, Windows x64 and Linux Arm64 all **SUCCESS**. Linux x64/Arm64 CTest each report 4/4 shards passed.
- **Docs/hygiene:** workflow 41401179017 at eb465f4 — **SUCCESS**.
- **App:** workflow 41401179166 — Dart analysis, Dart tests and Windows app **SUCCESS**; Android APK was still **IN PROGRESS** at checkpoint. Verify the run triggered by this documentation update before claiming the branch fully green.
- **Earlier docs failure:** workflow 41401014639 failed because progress/recovery docs were not linked in docs/index.md. Fixed by commit d1677c7; later docs workflow 41401179017 passed.
- **Local build/tests:** unavailable in connector-only workflow; GitHub Actions is the compiler/test runner. No physical-device performance/audio-latency test has run.

## Exact next actions

1. Finish M0: inspect parameter/automation, MIDI device/event, state persistence/migration, scheduler, project serialization, C API and app bridge. Map every fixed capacity and truncation/drop/fallback to its caller and tests.
2. Begin M1 without adding a second engine: design the prepared execution representation around existing VM Instance/BlockCtx, Engine::runChain/runVoices/processChunk, import/export signals, pattern voices, automation, folder routing and state migration. GraphExecutor's stereo one-in/one-out contract is insufficient; generalize it before audio-callback integration.
3. Implement a vertical migration slice with tests for old project behavior, deterministic output, callback safety and graph activation/retirement. Add app/C ABI exposure only after the native contract is stable.
4. Replace fixed project/voice/event/automation caps with resource-budgeted storage and explicit errors; first fix confirmed silent truncation/drop/leak paths.
5. Re-run affected CI after each coherent code change; inspect logs on failure. Update this ledger and decisions/log at each checkpoint. Open one PR only when the full refactor is reviewable and Main remains an ancestor.

## Non-negotiable decisions

- One portable C++20 engine; no competing second engine or duplicate module model.
- Existing .caw VM remains first-class and sandboxed; no filesystem/network/system calls. Trusted native code is not sandboxed without process isolation.
- Audio callback remains allocation-free, lock-free, I/O-free, logging-free, bounded and independent of UI/Dart. Never wait for workers from callback.
- Graphs/scheduling/buffers are prepared before activation; graph traversal/compilation stays off callback.
- Preserve deterministic semantics, golden audio, project/module compatibility and live/offline parity.
- Adaptive concurrency uses bounded resource-aware scheduling with serial fast paths; no thread-per-task, oversubscription or speculative GPU path.
- No arbitrary product caps. Use explicit budgets, actionable errors and no silent project-content truncation. Bounded real-time queues require visible overflow diagnostics and safe recovery.
- No GPL dependency without owner approval. No in-app AI or cloud-audio integration. Recording remains deferred.
