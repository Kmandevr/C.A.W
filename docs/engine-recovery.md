---
title: Native engine recovery
summary: Short resume guide for continuing the native engine refactor without repeating completed work.
updated: 2026-11-12
---

# Native engine recovery

**Goal:** complete the owner's native engine refactor/integration assignment in `Kmandevr/C.A.W`. Implement and integrate the existing engine; do not create a parallel engine.

## Current checkpoint

- **Main base for CP.1:** `38820aded14aa9e4c079a6e8cc8cb5c887557120`.
- **Issue #28:** still open for native engine/runtime integration. Its owner-approved scope now replaces the old compatibility requirement: ordinary C++ is the target authoring language; old `.caw` source and pre-release project compatibility are not required. The previously referenced `feature/native-engine-refactor-integration` branch no longer exists.
- **Public SDK foundation:** issue #117 / PR #118 is merged. The public contract header is `engine/include/caw/module.hpp`.
- **Active CP.1 work:** issue #119, PR #125 on `gpt/119-cpp-build-pipeline`, plus stacked continuation `gpt/119-native-component-host`. The user requires app-side C++ builds to run locally and offline; internet may optionally acquire dependencies/toolchains for local caching, and GitHub Actions is repository CI only. The app now persists component sources and exact dependency pins, materializes a safe private workspace, runs local CMake, reuses an incremental build directory and returns a verified artifact path. The Engine `ModuleRegistry` and C API now load shared libraries only after an explicit trust argument: Blocked refuses, Isolated is unsupported until a separate-process host exists, and Trusted loads in-process. The Dart FFI load/unload wrapper exists; native stereo effects run with their parameters on tracks (`LayerDoc.components`, after the track's chain and before volume and pan) and on the master (`ProjectDoc.masterComponents`, before the safety limiter). The per-component trust UI/store and an Android-hosted compiler package remain outstanding.
- **Build environment:** connector-only; local build/test is unavailable. GitHub Actions is the compiler/test runner.

## Immediate continuation — CP.1 component build

1. Inspect PR #125's Docs, Engine, App and C++ components checks for the exact head commit; fix every failure and re-run the full required CI.
2. Keep #119 open until its acceptance criteria include a buildable and registered component, structured diagnostics, target coverage and the required native-code trust boundary.
3. Continue with app-private project/source storage and the app-to-build-service submission/download path, then implement registration/loading only behind explicit Trusted or genuinely process-isolated Isolated modes. Never silently load native code.
4. Issue #94 is closed (PR #124 fixed offline exports); its remaining items are #133 (export buffers now held to a project-wide budget; per-callback loop cost and export pointer segments still open). Do not work on Main or revive stale branches.

## Immediate continuation — native C++ integration

1. Verify Quick Check for `gpt/119-native-component-host` and every required PR #125 check for the exact `gpt/119-cpp-build-pipeline` head. Do not merge while any required check is queued or failing.
2. After PR #125 merges, open the stacked native-host branch against updated Main. Add the per-component trust UI/store on top of the existing Dart FFI load/unload wrapper. Build success must never trigger loading. Keep Blocked as the safe initial state; keep Isolated unavailable until a real process-isolated audio host is implemented.
3. The Engine plays native stereo effects with their parameters on tracks (`LayerDoc.components`) and the master (`ProjectDoc.masterComponents`) (`ComponentChain`, `engine/src/component_chain.h`); the safety limiter remains after native code, chains are activated on the control thread and retired off the audio callback, and an update with the same components keeps the chain's running state. Bypass, saved state and automation lanes work too. Tails after Stop and latency compensation work too. A rebuild switches in while playing (`caw_engine_reload_component`). Next: components between .caw modules (dual mono after the stereo point, #17).
4. Build and validate a real Android-hosted compiler/toolchain package. The NDK's desktop-hosted cross-compiler is not an on-device compiler. Cache the installed toolchain and dependencies so builds remain offline.

## Latest ownership-safety change — retirement backpressure

The audio thread now checks available retirement capacity before consuming commands that can retire objects. The worst-case command counts include `Play` across every slot and `ConfigureBus` with automation. Callback-side crossfade completion, pending swaps and removal defer when the queue plus preallocated pending list cannot hold the retired objects. The audio callback still does not allocate, wait, lock or free. SPSC `peek()`/`writable()` have focused regression coverage. Verify latest Engine/App/Docs CI and add sustained saturation coverage before treating this risk as fully closed.

## What has actually been implemented

1. **Graph foundation:** removed arbitrary 1,024-node/8,192-connection compile caps and the 8,192-frame executor cap; added large graph/block tests and explicit graph working-set estimation/rejection.
2. **Project/chain content** (the app's matching caps went in F7.1, 2026-11-04): removed the nine-module chain cap, 256-project-module cap, 512-clips-per-layer cap, 256 project parameter-automation binding cap, 256 project automation lane cap, 128 project automation point skip, 4,096 arrangement-note truncation and 4,096 pattern-note cap.
3. **Layer automation:** replaced fixed Slot/Cmd 128-point volume/pan arrays with immutable vector-backed AutomationData. Control thread prepares it; audio thread adopts the pointer without allocating; old data is retired and freed off callback. An end-to-end test verifies that point 129 changes rendered audio.
4. **Command failures:** Engine::send returns queue acceptance. Project updates propagate critical failures for bus configuration, automation, routing, pattern/chain installation, layer length/removal, ordering and audition mode. Failed installs remain retryable rather than being recorded as active. Slot exhaustion and project-state budget overflow return explicit errors. Standalone setMaster/play/stop/clearOverload methods still ignore the bool result.
5. **VM capacity:** removed the 32-parameter, 64-synth-parameter and 32-import ceilings. BlockCtx borrows a dynamic parameter pointer table/count/sample offset; each prepared Chain allocates parameter sample buffers off callback. Tests cover 40 parameters with automation, 40 imports through VM processing and more than 64 synth-generated parameters.
6. **Hardware budget:** added EngineResourceBudget, derived from HardwareProfile.memoryBudgetMiB. It partitions the conservative total into project-state (1/2), graph working (1/4), compile working (1/8) and retirement (1/8) shares. Unknown memory uses a 128 MiB total fallback, preserving the prior 64 MiB project-state allowance. Engine enforces project-state bytes and accepts an injected budget for hosts/tests. makeGraphResourceBudget maps the graph share into GraphResourceBudget; graph/compile/retirement shares are not yet enforced by the active runtime.
7. **Pattern lengths/curves:** removed the 4,096-step pattern/MIDI cap; signed 32-bit step representation and existing MIDI file/event budgets remain. Replaced fixed 16-point bend/pressure/timbre arrays with dynamic vectors. Engine reserves each voice's curve capacity off callback, preserving at least the prior chain capacity during hot swap. Pattern publication is ordered after successful chain installation so a failed install cannot expose larger curves to an undersized old chain.

Regression coverage added across these slices includes 8,195 graph nodes/8,194 connections, 8,193-frame processing, 12 chain modules, nine synth effects, 300 project modules, 520 clips, 520×9 arrangement notes, 4,097 pattern notes, 257 project automation lanes ×129 points, 129-point layer automation playback, 40 VM parameters/imports, more than 64 synth parameters, hardware budget partition/fallback, low-memory project-state rejection, graph-budget conversion, 5,000-step patterns and 20-point curves/Engine playback.

**Verification status:** the older graph-budget foundation passed Engine/App/Docs CI at its recorded checkpoint. The later content, automation, VM, hardware-budget and curve changes do not yet have an inspectable fresh CI result. The available workflow-run reader has not exposed the push-triggered runs; do not claim these changes pass CI until actual checks are inspected.

## Architecture facts that must not be rediscovered or contradicted

- The active Engine uses `Engine::setProject`, `processChunk`/`planChunk`, the mix-graph node functions (`runModuleNode`, `runTrackNode`, `runBusNode`, `runMasterNode`), `runModule` and `runVoices`.
- `GraphExecutor` and `ModuleRegistry` still have no production playback integration with Engine/VM.
- Note previews (#103) and track/folder meters (2026-11-05) run inside the Engine's existing mix-graph nodes; they add no graph features.
- GraphExecutor is planar N-channel (F3) with typed audio (several, for sidechains), modulation, control (F5.1) and event (F5.2) ports; summing inputs accept fan-in since F4.1 and audio ones can be re-routed on the audio thread (`setRouting`, F4.3). It does not yet implement dynamic routing of non-audio ports, sends/returns, feedback boundaries or nested graphs, or receive MIDI from devices (modulation links, automation lanes and CC mappings from host events feed its resolved parameters, F6.3–F6.5; the Engine's .caw params use the same resolver, F6.6).
- Do not create a second engine. Integrate existing VM Instances, voices, imports/exports, automation, folder buses, offline rendering and project migration into one prepared execution model. Keep the multi-track mixer's reference renders (`mix_reference_test.cpp`, tolerance tests since 2026-11-12) passing while doing so.
- Audio callback must remain allocation-free, lock-free, I/O-free and logging-free. No worker waits on callback. Prepare data before activation and reclaim it off callback.
- The current `.caw` VM remains a constrained transitional path while useful capabilities are migrated; it is not the target authoring language. Trusted native C++ is not sandboxed without process isolation, and old-source/pre-release-project compatibility is not required.
- Preserve deterministic behavior, live/offline parity and retained engine capabilities. Old `.caw` source and pre-release-project compatibility are not required.

## Remaining fixed capacities and correctness risks

- Layer slots grow within the memory budget (F7.3); 32 voices; 6 VM call arguments; 1,024 VM registers; 64 KiB VM source; 8 MiB state per module; ratchets up to 8.
- MIDI file size remains 16 MiB; MIDI event count remains 65,536; MIDI 2.0 input queue is 1,024 and drops newest with a counter.
- Command queue is bounded at 1,024; sender times out after about two seconds. Project updates propagate key failures, but standalone transport/control methods (play, play from a position, stop) still ignore the result.
- Retirement queue is 1,024 and pending retirement list is 256. Commands reserve worst-case retirement capacity before consumption; callback-side swaps/removals defer when capacity is exhausted rather than dropping pointers. Stress verification of sustained saturation remains.
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
