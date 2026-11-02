---
title: Native engine recovery
summary: Short resume guide for continuing the native engine refactor without repeating completed work.
covers: [engine/, app/]
updated: 2026-11-02
---

# Native engine recovery

**Goal:** complete the owner's native engine refactor/integration assignment in `Kmandevr/C.A.W`. Implement and integrate the existing engine; do not create a parallel engine.

## Current checkpoint

- Branch: `feature/native-engine-refactor-integration`
- Base: `Main` at `20fd3da9a37f8936f1c3ff6069878978d064ae37`
- Last live comparison before this recovery refresh: **148 ahead, 0 behind Main**.
- Latest code/test checkpoint: `80e2664a5f9af2c3f6628ba94a0529ead4a42165`.
- Working tree/remote state is represented by GitHub branch commits; no local build/test environment is available through the current connector workflow.
- PR: none. Do not open a PR until the complete assignment is reviewable; do not merge, approve or delete branches.

## What has actually been implemented

1. **Graph foundation:** removed arbitrary 1,024-node/8,192-connection compile caps and the 8,192-frame executor cap; added large graph/block tests and explicit graph working-set estimation/rejection.
2. **Project/chain content:** removed the nine-module chain cap, 256-project-module cap, 512-clips-per-layer cap, 256 project parameter-automation binding cap, 256 project automation lane cap, 128 project automation point skip, 4,096 arrangement-note truncation and 4,096 pattern-note cap.
3. **Layer automation:** replaced fixed Slot/Cmd 128-point volume/pan arrays with immutable vector-backed AutomationData. Control thread prepares it; audio thread adopts the pointer without allocating; old data is retired and freed off callback. An end-to-end test verifies that point 129 changes rendered audio.
4. **Command failures:** Engine::send returns queue acceptance. Project updates propagate critical failures for bus configuration, automation, routing, pattern/chain installation, layer length/removal, ordering and audition mode. Failed installs remain retryable rather than being recorded as active. Slot exhaustion and project-state budget overflow return explicit errors. Standalone setMaster/play/stop/clearOverload methods still ignore the bool result.
5. **VM capacity:** removed the 32-parameter, 64-synth-parameter and 32-import ceilings. BlockCtx borrows a dynamic parameter pointer table/count/sample offset; each prepared Chain allocates parameter sample buffers off callback. Tests cover 40 parameters with automation, 40 imports through VM processing and more than 64 synth-generated parameters.
6. **Hardware budget:** added EngineResourceBudget, derived from HardwareProfile.memoryBudgetMiB. It partitions the conservative total into project-state (1/2), graph working (1/4), compile working (1/8) and retirement (1/8) shares. Unknown memory uses a 128 MiB total fallback, preserving the prior 64 MiB project-state allowance. Engine enforces project-state bytes and accepts an injected budget for hosts/tests. makeGraphResourceBudget maps the graph share into GraphResourceBudget; graph/compile/retirement shares are not yet enforced by the active runtime.
7. **Pattern lengths/curves:** removed the 4,096-step pattern/MIDI cap; signed 32-bit step representation and existing MIDI file/event budgets remain. Replaced fixed 16-point bend/pressure/timbre arrays with dynamic vectors. Engine reserves each voice's curve capacity off callback, preserving at least the prior chain capacity during hot swap. Pattern publication is ordered after successful chain installation so a failed install cannot expose larger curves to an undersized old chain.

Regression coverage added across these slices includes 8,195 graph nodes/8,194 connections, 8,193-frame processing, 12 chain modules, nine synth effects, 300 project modules, 520 clips, 520×9 arrangement notes, 4,097 pattern notes, 257 project automation lanes ×129 points, 129-point layer automation playback, 40 VM parameters/imports, more than 64 synth parameters, hardware budget partition/fallback, low-memory project-state rejection, graph-budget conversion, 5,000-step patterns and 20-point curves/Engine playback.

**Verification status:** the older graph-budget foundation passed Engine/App/Docs CI at its recorded checkpoint. The later content, automation, VM, hardware-budget and curve changes do not yet have an inspectable fresh CI result. The available workflow-run reader has not exposed the push-triggered runs; do not claim these changes pass CI until actual checks are inspected.

## Architecture facts that must not be rediscovered or contradicted

- The active Engine still uses `Engine::setProject`, `processChunk`, `processSlot`, `runChain` and `runVoices`.
- `GraphExecutor` and `ModuleRegistry` still have no production playback integration with Engine/VM.
- GraphExecutor remains stereo-only with one audio input and one audio output per node. It does not yet implement multiport/fan-in/fan-out, typed control/modulation/event/MIDI routing, sidechains, sends/returns, feedback boundaries or nested graphs.
- Do not create a second engine. Integrate existing VM Instances, voices, imports/exports, automation, folder buses, offline rendering and project migration into one prepared execution model.
- Audio callback must remain allocation-free, lock-free, I/O-free and logging-free. No worker waits on callback. Prepare data before activation and reclaim it off callback.
- Existing `.caw` VM remains the constrained untrusted-code path; trusted native code is not sandboxed without process isolation.
- Preserve deterministic semantics, project/module compatibility, live/offline parity and existing audio behavior.

## Remaining fixed capacities and correctness risks

- 64 layer slots; 32 voices; 6 VM call arguments; 1,024 VM registers; 64 KiB VM source; 8 MiB state per module; ratchets up to 8.
- Arrangement/transport still clamps to 64 bars.
- MIDI file size remains 16 MiB; MIDI event count remains 65,536; MIDI 2.0 input queue is 1,024 and drops newest with a counter.
- Command queue is bounded at 1,024; sender times out after about two seconds. Project updates propagate key failures, but standalone transport/control methods still ignore the result.
- Retirement queue is 1,024 and pending retirement list is 256; overflow can still leak.
- Project-state budget is hardware-derived and enforced; graph working share has a conversion helper but is not yet connected to active Engine graph compilation. Compile and retirement shares are not yet consumed.
- Exports/imports are dynamically sized. Per-slot export buffers use a stable pointer table and lazily allocated storage bounded by EngineResourceBudget.graphWorkingBytes; allocation/budget failures are explicit. The graph-working share is currently also the export-pool budget and will need a shared allocator when GraphExecutor is integrated.
- Fixed layer slots/voice pools and other budgets need to become explicit hardware/resource budgets with actionable failure paths, not silent project-content loss.

## Read first

1. `AGENTS.md`, `CLAUDE.md`, applicable `.claude/rules/*.md` and skills.
2. `docs/engine-progress.md` — exact status, evidence, fixed-limit audit and next actions.
3. `docs/engine-build-status.md` — existing code versus missing integration.
4. `docs/engine-next.md` — full owner requirements.
5. `docs/decisions.md`, `docs/log.md`, `docs/roadmap.md`, `docs/how-it-works.md`.

## Resume protocol

Check branch head, Main ancestry, open PRs/issues and latest CI before editing; this branch may advance between chats. Continue from the exact next action in `docs/engine-progress.md`. Never reset/discard changes. Connector-only sessions cannot run local builds: use GitHub Actions and inspect failed job logs; never report unobserved tests as passing. Update progress, status, log and recovery notes at each milestone boundary.
