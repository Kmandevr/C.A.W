---
title: Native engine refactor progress
summary: Live milestone ledger and exact continuation point for the native engine refactor.
covers: [engine/, app/]
updated: 2026-11-02
---

# Native engine refactor progress

## Current state

- **Branch:** feature/native-engine-refactor-integration
- **Base:** Main at 20fd3da9a37f8936f1c3ff6069878978d064ae37 (verified ancestor; planning branch was 15 commits ahead and 0 behind).
- **Starting checkpoint:** 49ba277f91bc9349f70d492c32e5f498d692e9b3 on refactor/native-engine-foundation; implementation branch created directly from it.
- **PR:** none yet.
- **Current milestone:** M0 — repository recovery and architecture audit (**IN PROGRESS**).
- **Last completed step:** verified repository instructions, architecture blueprint, implementation status, branch ancestry, open PR search and relevant issues; created this implementation branch.
- **Current files/systems being changed:** continuity documentation only (docs/engine-progress.md, docs/engine-recovery.md). No engine code changed yet.
- **Completed commits on this branch:** none after branch creation; starting checkpoint above is inherited.

## Verified repository baseline

- The default branch is Main (capital M).
- No open PRs were returned by the repository-scoped open-PR search at audit time.
- Existing implementation is not a blank slate. docs/engine-build-status.md records a bounded adaptive worker pool and C ABI job APIs, hardware/workload policy, typed DSP graph validation and prepared stereo executor, graph publication helper, module descriptors/registry, dependency resolver, MIDI 2.0 UMP decoder/SPSC queue, existing note-expression model, synth modulation and current app integration.
- Important incomplete boundary: prepared graph executor/publication helper are not integrated into the existing Engine/VM mixer. Native dynamic module loading/isolation, full graph state migration, live MIDI device I/O/voice routing, general native routing and app declarative UI runtime are not implemented.
- Existing v2 automation work is described as PR #68 in the implementation ledger; recheck its current PR/commit state before treating it as merged or complete.
- Existing docs say Stage 5 graph-to-Engine integration is paused. The owner's current 2026-11-02 instruction explicitly reopens and authorizes the full native engine integration assignment. Follow this instruction while retaining existing product boundaries (no in-app AI, no assumption of recording, no full DAW parity requirement).
- Permissive dependencies only unless owner approves otherwise. C++20 portable core; Flutter remains a host via versioned C API. Trusted native extensions are not sandboxed. The .caw VM is the constrained untrusted-code path.

## Milestones

| ID | Objective | Status | Evidence / remaining work |
|---|---|---|---|
| M0 | Recover repository, audit implementation and dependencies | **IN PROGRESS** | Instructions and top-level implementation ledger read; inspect engine graph/VM/mixer/C API and app bridge in detail; verify PR #68, issues and CI. |
| M1 | Core execution foundations and lifecycle | **IN PROGRESS (PARTIAL BASE EXISTS)** | Descriptors, typed ports, borrowed stereo buffers, prepared graph executor and publication helper exist. Prove ownership, activation, state lifetime and real Engine/VM integration; avoid duplicate engine. |
| M2 | Universal typed routing | **NOT STARTED (FOUNDATION PARTIAL)** | Graph validation supports typed ports, but runtime mixer integration and project routing are missing. Add audio/control/event/sidechain/bus/send/return/feedback support with prepared bounded execution. |
| M3 | Unified parameters/modulation/automation | **IN PROGRESS (PARTIAL BASE EXISTS)** | Synth modulation and parameter/global automation work exists; verify single shared parameter semantics across VM/native modules, tracks, effects and routing. |
| M4 | Extensibility and mathematical processing | **IN PROGRESS (PARTIAL BASE EXISTS)** | .caw VM and static native module registry exist. Verify capability negotiation, stable API/state versions and failure/bypass behavior; dynamic native loading remains unsafe without isolation. |
| M5 | MIDI/events | **IN PROGRESS (PARTIAL BASE EXISTS)** | MIDI 2.0 UMP decoder/SPSC queue and MIDI file support exist. Live device adapter, event graph/voice integration and output scheduling remain. |
| M6 | Adaptive concurrency/batching | **IN PROGRESS (PARTIAL BASE EXISTS)** | Adaptive worker pool exists for non-RT jobs. Need graph scheduler/voice/offline batching integration, reproducible benchmarks and evidence-based tuning. Never parallelize live callback by waiting on workers. |
| M7 | Application integration | **IN PROGRESS (PARTIAL BASE EXISTS)** | App uses native worker APIs for selected jobs; graph/module runtime and richer routing still not connected. Verify project persistence and UI integration. |
| M8 | Optimization and validation | **NOT STARTED** | Full stress, parity, compatibility, sanitizers, CI and real-device validation after integration. |

## Verification record

- **CI:** no workflow result has been checked for this implementation branch yet. Do not claim a pass.
- **Workflow run IDs:** none recorded.
- **Local build/tests:** unavailable in connector-only workflow; use GitHub Actions as compiler/test runner and state this limitation accurately.
- **Baseline test commands:** CMake build plus caw_tests / CTest; app flutter analyze and flutter test; Docs node scripts/docs-test.js. Inspect workflow definitions and current required checks before release.
- **Known failures / failed approaches:** none established for this branch. Do not repeat repository-wide exploratory reads; use this ledger and docs/engine-build-status.md as the starting map.

## Exact next actions

1. Finish M0 by reading remaining sections of docs/engine-next.md, then inspect actual graph, module, execution, Engine/VM/mixer, parameter, MIDI, C API, Flutter bridge and relevant tests. Verify #68 and all open PR/branch/CI state.
2. Trace the prepared graph executor and runtime publication helper to determine the smallest correct integration seam into existing Engine/VM. Record concrete file/function names and ownership/lifetime findings.
3. Implement one vertical integration slice with tests (do not add a parallel engine); prioritize connecting prepared graph processing to existing engine execution while preserving legacy project behavior.
4. Run affected workflows; inspect job logs on failure before changing code. Update this ledger after every coherent milestone and record commit/workflow IDs.
5. Continue routing, parameters, modules, events, scheduler, app bridge and validation only after each dependency is verified. Open one coherent PR when work is reviewable; never merge or approve it.

## Decisions and constraints that must not be reversed

- One portable C++20 engine; no competing second engine or duplicate module model.
- Existing .caw VM stays first-class and sandboxed; no filesystem/network/system calls.
- Native SDK code is trusted in-process unless real process isolation is implemented; never imply it is sandboxed.
- Audio callback stays allocation-free, lock-free, I/O-free, logging-free, bounded and independent of UI/Dart. Never wait for worker jobs from callback.
- Prepared graphs/scheduling/buffers are validated and allocated before activation; graph traversal/compilation stays off callback.
- Preserve deterministic semantics, golden audio, project/module compatibility and playback/offline parity.
- Adaptive concurrency uses one bounded scheduler with serial fast paths; no thread-per-task, oversubscription or speculative GPU path.
- No arbitrary object-count caps; explicit resource budgets and clear failure behavior instead. Never silently truncate project data.
- No GPL dependency without owner approval. No in-app AI or cloud-audio integration.
- Do not change wider product scope (recording remains deferred; app should be useful for music creation but is not required to clone a conventional DAW).