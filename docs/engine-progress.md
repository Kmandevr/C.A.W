---
title: Native engine refactor progress
summary: Live milestone ledger and exact continuation point for the native engine refactor.
covers: [engine/, app/lib/engine/]
updated: 2026-11-06
---

# Native engine refactor progress

## Current state

- **Main checkpoint:** `38820aded14aa9e4c079a6e8cc8cb5c887557120` (base of the current CP.1 branch; includes the merged public SDK PR #118).
- **Issue #28:** remains open for the larger native engine/runtime integration. Its scope now follows the owner's 2026-11-05 decision: ordinary C++ is the authoring language; old `.caw` source and pre-release-project compatibility are not required. The previously referenced `feature/native-engine-refactor-integration` branch no longer exists; no open PR is attached to #28.
- **Public SDK foundation:** issue #117 / PR #118 is merged. The existing `ModuleProcessor`/typed descriptor/parameter/event/state contract is exposed through `engine/include/caw/module.hpp`; the follow-on CP.1 task makes `CAW::SDK` installable and adds a manifest-driven component shared-library build path, exported entry points and structured diagnostics.
- **Runtime boundary:** publishing the source-level SDK does not make native modules production playback nodes and does not implement the C++ project builder, editor, visual scripting or generated UI. Those remain separate roadmap work.
- **Environment:** connector-only sessions cannot run local builds/tests; GitHub Actions Quick Check is the compiler/test runner. CI does not prove real-device audio performance.
- **Active C++ platform task:** issue #119, PR #125 on `gpt/119-cpp-build-pipeline`, with the stacked continuation `gpt/119-native-component-host` based on its head. The app now persists C++ sources/dependency pins, materializes a safe private workspace, invokes local CMake, reuses the build directory and returns a verified artifact path. The Engine `ModuleRegistry` and C API can load the artifact only with an explicit trust argument; Blocked refuses, Isolated is unsupported until process isolation exists, and Trusted loads in-process. The Dart FFI load/unload wrapper now runs on a background isolate; the per-component trust UI/store and live playback-chain insertion remain incomplete. The Android-hosted compiler/toolchain package is not yet implemented. The owner requirement is fully local/offline user builds; internet is optional for dependency/toolchain acquisition and cache population; GitHub Actions is repository CI only.

## CP.1 continuation — native C++ integration

1. Verify the current Quick Check on `gpt/119-native-component-host` and all required PR #125 checks for the exact `gpt/119-cpp-build-pipeline` head. Do not merge queued checks as if they passed.
2. Once the SDK/build PR is merged, open the stacked native-host work against updated Main. Add the per-component trust UI/store on top of the existing Dart FFI load/unload wrapper. Build completion must never load or authorize code; Blocked remains the safe initial state, and Isolated must stay unavailable until a real separate-process host exists.
3. Connect `ModuleRegistry.create()` processors to the existing Engine chain and live `MixGraph`. The current `Chain` stores VM `Instance` objects and `runModuleNode` executes `.caw` programs; start with one minimal stereo effect component, then generalize typed ports/parameters. Preserve no allocation, locks, waits or frees on the audio callback.
4. Package and validate an Android-hosted C++ toolchain that can run offline after installation; do not mistake the Android NDK cross-compiler (which runs on desktop hosts) for an on-device compiler. Then add optional dependency detection/pre-acquisition and local cache verification.

## M0 — repository recovery and architecture audit

<badge color="success">VERIFIED</badge>

- Read AGENTS/CLAUDE, applicable .claude rules and skills, engine blueprint, decisions/log/roadmap/architecture/status docs, relevant source, tests and workflows.
- Confirmed PR #68 is merged into Main at `20fd3da`; project parameter/global automation is part of the baseline.
- Confirmed there were no open PRs at the start of this task. The foundation branch was the correct base; the implementation branch preserves it and is still 0 commits behind Main.
- Inspected the native VM/compiler, synth, project parser, layer/chain mixer, voice engine, pattern parser, automation, graph compiler/executor/runtime, module descriptors/registry, worker scheduler, hardware policy, MIDI decoder/queue, C API and Flutter bridge.
- Inspected native tests for engine routing/automation/hot swap, graph, module/registry, MIDI 2.0, patterns/voices, scheduler/execution, dependencies, plus app project/pattern/engine tests.
- Inspected Engine, App and Docs workflows and the current branch's successful CI results.

## Verified architecture and integration gaps

- Existing foundations include the current transitional .caw compiler/VM, synth patch translation, layer/chain mixer, folder buses, module import/export wiring, project parameter/global automation, MIDI file import/export, MIDI 2.0 UMP decoding/queue, typed module descriptors, static module registry, graph compiler/executor/publication helper, dependency resolver, hardware policy and bounded background worker pool. The public C++ SDK header `engine/include/caw/module.hpp` exposes the existing module processor contract; `CAW::SDK` is now an installable CMake package with a manifest-driven component build helper and exported entry points. It is still not a runtime loader or production host.
- **Integration (updated 2026-11-03, F4.3):** `Engine::setProject` compiles programs and creates `Chain` instances. `Engine::process` runs each chunk through the Engine-owned mix graph (`GraphExecutor`), with a node per track module (`runModuleNode` → `runModule`/`runVoices`), a track node, folder bus nodes and a master node; `planChunk` handles loop restarts and code swaps between chunks (F4.4). Stopped, it runs preview chunks for note previews (#103, 2026-11-05): only the previewing tracks, with the transport left in place. Play can start mid-loop (`Engine::play(from)`, 2026-11-05): `planTrack` works out each track's loop pass from that position. Track and folder bus nodes record their meters' sample peaks after volume and pan. `GraphRuntime` and `ModuleRegistry` have no production references from Engine, VM, C API or Flutter.
- The graph compiler now has no arbitrary fixed node/connection count cap. `GraphResourceBudget` requires a non-zero `maxWorkingBytes`; optional `maxNodes`/`maxConnections` ceilings default to unlimited. Compile and executor preparation estimate their internal working set before allocating; the estimate excludes caller-owned graph input and processor instances, and actual allocator failure remains a separate `OutOfMemory` result. Tests now cover both compiler and executor working-set rejection. Node references remain `uint32_t` (a representation boundary); the executor's former 8,192-frame cap is removed. This budget is not yet derived from hardware or passed by the active Engine.
- **Graph runtime is still limited:** since Foundation F3 (PR #72) it runs planar N-channel audio of any layout (mono … 7.1, Discrete, up to 64 channels per port) with a prepared-buffer byte budget, with any number of audio, modulation, control and event ports per node since F5.1/F5.2, 8–192 kHz. Since F4.1 a summing input takes any number of connections (fan-in, summed in connection order; events merged by frame); other inputs take one driver. No custom channel mapping, cross-domain conversion or delayed feedback edges, and nothing yet routes MIDI devices or patterns into graph events. Processors receive resolved parameter values (F6.1/F6.2), including modulation links from other nodes (F6.3), automation lanes (F6.4) and MIDI CC mappings from host events (F6.5), and the Engine's .caw params resolve through the same model (F6.6); nothing feeds those host events from MIDI devices yet.
- `ModuleProcessor` has the generic borrowed planar `process(AudioProcessBlock)` with a stereo adapter (F2/F3), and the executor calls only that. Port descriptors identify audio/control/modulation/event types, but typed descriptors do not provide runtime buffers for those domains.
- `ModuleRegistry` is static/in-process only. No dynamic loader, production host adapter, capability negotiation or native crash isolation exists. Trusted native code is not sandboxed; the .caw VM remains the constrained untrusted-code path.
- MIDI 2.0 decoding/queue are primitives only. `Midi2Event` has no sample timestamp, there is no live USB/Bluetooth device adapter, and events are not routed into Engine voices. Queue overflow is counted but not surfaced through the app.
- The app C API/FFI remains API v1. The app submits project compilation, source checks and offline WAV renders to the native worker pool; it does not submit graph execution or native module work.
- Existing synth modulation, sidechain ducking effects, per-note expression and project automation are partial foundations, not the unified parameter/routing system requested.

## Latest implementation slice — parser failure-state safety (unverified)

- `parseProject` now clears its output object and error string before applying the 8 MiB JSON input budget. A rejected oversized document cannot leave a caller's previous project appearing valid. Regression test pre-populates project state and verifies it is cleared on rejection. Commit `5bd40eb` contains implementation; `1c88f05` adds the regression. CI runs `41503176374` / `41503176276` pending at documentation update.

## Latest implementation slice — dynamic effect-chain length

- Removed the fixed nine-module/eight-effect limit from ProjectSpec, project JSON chain parsing, Engine chain preparation and synth patch parsing.
- The project parser now preserves every string module ID in a chain; Engine no longer warns and truncates the chain after its ninth entry; synth patch translation no longer rejects the ninth effect.
- Added regression tests for a 12-entry project chain and a nine-effect synth patch. Updated engine, synth, decisions and log documentation.
- This is a targeted removal only. Fixed layer slots, export buffers, voice arrays and automation arrays remain separate work.
- **Verification:** no fresh Engine/App/Docs workflow result has yet been inspected for the dynamic chain and content-cap changes. The previously green runs at 1269019 predate these changes and do not verify them.

## Latest implementation slice — remove silent content ceilings

- Project JSON parsing now preserves more than 256 modules and more than 512 arrangement clips; the 256-binding cutoff for project parameter automation was removed.
- Arrangement compilation no longer silently stops adding notes at 4096. Added an audio regression with 520 clips × 9 notes and checks that a late clip beyond the former cutoff is audible.
- Pattern parsing no longer rejects the 4097th note. MIDI import's default note allowance is now caller-configurable instead of inheriting the former 4096-note constant. Added a 4097-note parser test.
- Added project parser coverage for 300 modules and 520 clips. Dynamic signal-chain tests cover 12 project modules and nine synth effects.
- These changes remove specific fixed ceilings; they do not yet establish a complete hardware-derived project memory budget. MIDI file byte/event safety bounds, pattern step length, layer slots, voices, exports, automation point arrays and other limits remain.
- **Verification:** the current Engine/App/Docs push-triggered runs have not been readable through the available commit-workflow result view, which only returns pull-request-triggered runs. Do not claim these changes passed CI until the actual checks are inspected.

## Latest implementation slice — dynamic project automation

- Removed the 256 project-level parameter/global automation-lane rejection and the 128-point silent skip. Both collections are already vector-backed; all valid lanes and points now survive parsing.
- Added a parser regression with 257 lanes and 129 points per lane.
- Layer volume/pan automation is now dynamically stored in prepared AutomationData vectors; VM parameter automation tables are dynamically sized per chain. Both are prepared off callback and avoid callback allocation during note/parameter processing.
- **Verification:** fresh CI results for the implementation commits remain uninspected. Earlier green runs predate these changes.

## Latest implementation slice — dynamic layer automation and command failure handling

- Replaced the per-slot and command 128-point volume/pan arrays with an immutable AutomationData object containing vectors. The control thread prepares it; the audio thread adopts the pointer without allocation; old data is sent through the retirement path and freed off callback.
- Removed the parser's 128-point rejection. Added an end-to-end regression that parses and renders 129 volume automation points and checks that point 128 affects audio.
- Engine::send now returns whether the bounded command queue accepted a command. Project updates propagate failures for transport, bus configuration, automation, routing, pattern/chain installs, layer length/removal, ordering and audition mode. Failed installs are not recorded as the active LayerState; failed layer removals remain retryable. Slot exhaustion and project-state budget overflow now produce explicit project errors/warnings.
- Remaining command-path gap: standalone setMaster/play/stop/clearOverload methods still ignore the bool result. Retirement reclamation now reserves capacity before processing commands or completing callback-side swaps/removals. If both the 1,024-entry retirement queue and 256-entry preallocated pending list are exhausted, the callback defers those transitions rather than dropping ownership; stress verification remains pending.
- **Verification:** no inspectable fresh Engine/App/Docs workflow result is available for this slice. Prior green runs predate it.

## Latest implementation slice — dynamic VM parameters and imports

- Removed the 32-parameter module cap, 64-generated-parameter synth cap and 32-import cap.
- BlockCtx now exposes a borrowed pointer table, count and sample offset for parameter automation. Each prepared Chain allocates its parameter sample buffers and pointer table off callback; VM reads use bounds-checked count and the per-voice offset.
- Program imports remain vector-backed and now have no arbitrary compiler count cap; VM receives the prepared pointer array for the exact import list.
- Tests cover 40 parameters with runtime setParam, 40 imports through actual VM processing, Engine automation of parameter 40, and a synth patch exposing more than 64 generated parameters.
- **Verification:** fresh CI is not inspectable through the current commit workflow reader. Earlier green runs predate these changes.

## Latest implementation slice — hardware-derived Engine memory budget

- Added EngineResourceBudget with total, project-state, graph-working, compile-working and retirement shares. The platform's conservative memoryBudgetMiB is the source; the shares are 1/2, 1/4, 1/8 and 1/8. Unknown memory uses a documented 128 MiB total fallback, preserving the previous 64 MiB project-state allowance.
- Engine's default constructor probes hardware on the control thread; hosts/tests can inject an explicit EngineResourceBudget. Project state is now checked in bytes against the per-Engine project-state share instead of the removed fixed 64 MiB constant.
- Added tests for budget partitioning, unknown-memory fallback and project rejection when delay state exceeds a 2 MiB hardware budget.
- Graph/compile/retirement shares are defined but are not yet enforced by those subsystems. The Engine's mix graph uses a fixed 4 MiB budget floor of its own rather than the graph share.
- **Verification:** fresh CI for these changes is not yet inspectable.

## Latest implementation slice — graph budget sourced from Engine policy

- Added makeGraphResourceBudget(EngineResourceBudget), mapping the Engine's graph-working share to GraphResourceBudget.maxWorkingBytes. The Engine budget is now the common policy source for project state and future graph/compile/retirement allocations.
- This is a conversion seam, not active graph integration: Engine still does not instantiate GraphExecutor, and graph/compile/retirement shares are not yet consumed by the runtime.
- Added a regression test for the conversion from a 16 MiB hardware budget to a 4 MiB graph working budget.

## Latest implementation slice — dynamic pattern step lengths and note curves

- Removed the 4096-step pattern/MIDI import cap. Pattern length, note positions and MIDI import are now bounded by the signed 32-bit step representation and explicit file/event safety limits, not a fixed 4096-step product ceiling.
- Replaced fixed 16-point bend/pressure/timbre arrays with dynamic curve vectors. Pattern parsing/evaluation uses vector points; Engine computes the maximum curve capacity for each prepared pattern and reserves each voice's curve storage before playback.
- Chain rebuilds reserve at least the prior chain's expression capacity, so hot-swapping voices copies existing expressions without allocating on the audio callback. A larger new pattern forces preparation of a larger capacity before activation. Pattern publication is ordered after successful chain installation so a failed install cannot expose larger curves to an undersized old chain.
- Added tests for 5000-step patterns, 20-point note curves, and Engine playback of a 20-point expression.
- **Verification:** fresh CI for these changes is not yet inspectable.

## Latest implementation slice — dynamic exports with stable pointers

- Removed the compiler's 16-export ceiling and replaced each Slot's fixed export array with a stable per-slot pointer table backed by an Engine-owned ExportPool.
- Pointer-table capacity is derived from EngineResourceBudget.graphWorkingBytes. Individual 64-sample export buffers are allocated lazily on the control thread and never moved, so existing import pointers remain valid across later project updates. Allocation failure or a project exceeding the per-slot budget returns an explicit project error.
- Engine tracks the high-water export count per slot, clears inactive/muted sources so consumers do not read stale values, and avoids clearing active buffers twice before the producer writes them.
- Added compiler and end-to-end routing tests for 20 exports, plus a low-memory test that confirms an actionable budget error.
- **Verification:** fresh CI for this slice is not yet inspectable.

## Fixed limits and correctness risks

Graph compile/prepare now require an explicit working-memory budget and preflight internal storage estimates; allocator overhead is implementation-dependent, so actual allocation failure is still handled. The budget is not yet derived from hardware or passed by the active Engine. The following limits and loss paths remain in the current source and must be converted to explicit, configurable resource budgets or dynamic storage:

- **Project structure:** (the app's matching lane, point and pattern caps went in F7.1, 2026-11-04) layer slots that grow past 64 within the memory budget (F7.3); module chains, project module lists, arrangement clip lists and project-level parameter/global automation lanes/points are now dynamically stored; layer volume/pan automation is now vector-backed and dynamically sized, with control-thread preparation and off-callback retirement; dependency records above 4,096 are rejected. The 64-bar arrangement clamp is gone (F7.2): song positions up to the 32-bit step count are kept, and out-of-range ones are refused.
- **VM/module:** parameters, imports and exports are dynamically sized; export buffers are bounded by the Engine's graph-working memory share; 6 call arguments; 1,024 VM registers; 64 KiB source; 8 MiB state per module; 32 voices; compiler depth/call budgets.
- **Pattern/MIDI:** pattern note arrays are dynamic; pattern step indices use the signed 32-bit representation boundary; note-expression curves are dynamically sized; MIDI file size is limited to 16 MiB and MIDI event count to 65,536; MIDI import note allowance is caller-configurable; MIDI 2.0 input queue capacity is 1,024 (drop-newest with a counter).
- **Runtime queues/state:** 1,024-entry command queue; 1,024-entry retirement queue; 256 pending retirements; 2 MiB state-takeover threshold; hardware-derived project-state budget (64 MiB fallback when memory is unknown). Worker pool has a maximum of 16 workers and a 256-job queue.
- **Confirmed silent/lossy behavior:** no free layer slot now returns an explicit project error; bounded command submission can still time out after about two seconds, but project updates propagate failures and keep failed installs retryable (standalone transport controls still ignore the result); retirement reclamation is capacity-guarded and defers transitions rather than dropping pointers; sustained queue saturation still requires stress verification; project-state overflow returns an explicit error and does not install the over-budget layer. The known chain/module/clip/arrangement-note/pattern-note/project-automation truncations have been removed. Layer volume/pan automation and VM parameter/import collections are dynamic.
- Some limits are legitimate sandbox/parser safety budgets. They must remain explicit, configurable within host policy where practical, and fail clearly. Project content must never be silently truncated or a track silently omitted. Real-time event queues may be bounded, but overflow must be visible and recoverable.

## Latest ownership-safety change — retirement backpressure (CI pending)

- Added non-consuming SPSC `peek()` and producer-side `writable()` inspection.
- `Engine::applyCommands` now reserves worst-case retirement capacity before popping a command (including the multi-slot `Play` case).
- Callback-side crossfade completion, pending swaps and layer removal check capacity before changing ownership. When the retirement queue and fixed pending list are full, transitions are deferred; the callback does not allocate, wait, lock or delete.
- Added SPSC capacity/peek regression coverage. Commits: `9540553`, `d5c3330`, `7577f0e`, `d00472f`, `ecc5482`, `c0dbeeb`. Engine/App/Docs CI for checkpoint `c0dbeeb` was pending when recorded.

## Milestones

| ID | Objective | Status | Evidence / remaining work |
|---|---|---|---|
| M0 | Repository recovery and architecture audit | **VERIFIED** | Instructions, design/status docs, source, tests, workflows, branch/PR/issue state and app bridge inspected. Confirmed PR #68 merged, no open PRs, current branch ancestry and CI. |
| M1 | Core execution foundations, lifecycle, buffers, ownership and graph publication | **IN PROGRESS (PARTIAL)** | Graph scaling and explicit working-memory budgets passed Engine/App/Docs CI at 1269019. Follow-up compiler-budget and later content-cap regression tests exist, but their CI is not yet inspectable. Hardware-derived Engine budget wiring, prepared processor ownership/lifecycle, project snapshot publication, safe retirement and Engine/VM integration remain. Hardware-derived Engine budget wiring, prepared processor ownership/lifecycle, project snapshot publication, safe retirement and Engine/VM integration remain. Still needs hardware-derived Engine budget wiring, prepared processor ownership/lifecycle, project snapshot publication, safe retirement and Engine/VM integration. |
| M2 | Universal typed routing | **NOT STARTED (FOUNDATION PARTIAL)** | Descriptors exist and the runtime is planar N-channel (F3), but still audio-only with one input and one output port per node (fan-in through summing inputs since F4.1). Add fan-out to multiple ports, buses/sends/returns, sidechains, control/modulation/events/MIDI and delayed feedback. |
| M3 | Unified parameters/modulation/automation | **IN PROGRESS (PARTIAL)** | Synth modulation and project parameter/global automation exist. Unify manual controls, automation, modulation, MIDI/controller mappings, note expression and sidechain-derived control across VM/native modules/tracks/buses. |
| M4 | Extensibility and mathematical processing | **IN PROGRESS (PARTIAL)** | .caw VM and static registry exist. Add capability declarations, stable API/state versioning, ownership, failure/bypass and advanced extension paths. Native in-process code remains trusted, not sandboxed. |
| M5 | MIDI and event integration | **IN PROGRESS (PARTIAL)** | UMP decoder, bounded queue, note expression and MIDI files exist. Add timestamped events, live device I/O, voice routing and MIDI 1.0/2.0 scheduling. |
| M6 | Adaptive concurrency and batching | **IN PROGRESS (PARTIAL)** | Adaptive non-real-time pool and hardware policy exist. Remove arbitrary worker ceiling; integrate dependency-aware graph/voice/offline scheduling, batching and measured SIMD paths. |
| M7 | Application/project integration | **IN PROGRESS (PARTIAL)** | Flutter uses C API v1 and native worker jobs. Graph/project serialization, richer routing/parameter controls, module lifecycle and migrations remain. |
| M8 | Optimization and validation | **NOT STARTED** | Profile the integrated runtime; stress-test resource pressure, compatibility, parity, sanitizers, deadlines and weak/strong hardware; remove obsolete paths only after verified migration. |

## Verification record

- **Last live compare before this ledger refresh:** 108 commits ahead and 0 behind Main. Latest code/test checkpoint: `8f43d76036cadcc3998eed6747a94d9e0c3f0480`.
- **Verified graph-budget implementation:** code commit `07c796f8` at branch checkpoint `1269019` passed Engine workflow `41403872524` on Linux x64, Linux Arm64, Windows x64 and Linux sanitizers; all four CTest shards passed. The compiler-budget follow-up and all later content/VM-capacity tests await fresh CI. The earlier docs-only checkpoint `1370a43` also eventually passed all four Engine jobs in run `41402930328`; Windows was delayed but did not fail.
- **Docs/hygiene:** workflow `41403872717` passed at checkpoint `1269019`; the follow-up test/status commit will trigger a fresh Docs check.
- **App:** workflow `41403872504` at checkpoint `1269019` — Dart analysis, Dart tests, Windows app and Android APK all **SUCCESS**. Earlier App run `41401179166` also passed at `eb465f4`. Fresh App CI is required for the subsequent chain-cap removal commits.
- **Earlier Engine/Docs:** `41401179084` and `41401179017` at `eb465f4` both passed.
- **Earlier Docs failure:** `41401014639` failed because progress/recovery docs were not linked from `docs/index.md`; fixed in `d1677c7`, later Docs workflows passed. Do not repeat this omission.
- **Local build/tests:** unavailable in this connector-only workflow. GitHub Actions is the compiler/test runner; never claim local reproduction.
- **Hardware validation:** no physical-device performance/audio-latency test has run. CI does not prove phone latency, thermal behavior, battery use or dropout resistance.

## Exact next actions

1. Inspect actual push-triggered Engine/App/Docs CI for the latest code checkpoint before relying on these changes. The current workflow-run reader exposes PR-triggered runs only, so use an alternate supported way to inspect the push runs or wait until checks are visible.
2. Remove the 16-export ceiling by replacing per-slot fixed export buffers with prepared dynamically sized storage and safe source-pointer rebinding; preserve the audio callback's no-allocation/no-free rule.
3. Establish prepared project/runtime snapshots as the publication unit. Build modules, graph, routing, schedules, buffers and migration plans off callback; publish atomically at a block boundary; reclaim old snapshots off callback. Replace per-layer partial command submission with transactional updates. Fix command timeout/drop and slot-exhaustion loss; retirement overflow now has callback-safe capacity backpressure, which still needs stress verification.
4. Wire hardware-derived Engine resource budgets into graph compile/prepare and project/state allocation. Validate estimates against actual allocation behavior and profile on weak and strong targets.
5. Generalize the graph executor beyond F3's planar N-channel one-in/one-out audio (fan-in exists since F4.1): custom channel mapping, multiple input/output ports, audio/control/modulation/event/MIDI buffers, timestamp ordering and delayed feedback boundaries.
6. Integrate the prepared graph with existing VM instances, voices, patterns, imports/exports, automation, folder buses, offline rendering and state migration. Do not create a second engine. Since F4.2 the mixer routes in float and `engine/tests/mix_golden_test.cpp` hashes multi-track mixes; those hashes must hold when routing moves into the graph.
7. Replace remaining fixed project/voice/export/curve/event caps with resource-derived storage and actionable errors; remove the 64 MiB layer-silencing behavior (the 64-bar clamp went in F7.2). Surface standalone transport command failures and stress-verify callback-safe retirement backpressure and make remaining command failures explicit. Continue unified parameters, native module lifecycle, MIDI device/event routing, adaptive scheduling/batching and Flutter integration. Update docs/tests and open one coherent PR only when all acceptance criteria are met.

## Non-negotiable decisions

- One portable C++20 engine; no competing second engine or duplicate module model.
- Existing .caw VM remains first-class and sandboxed; no filesystem/network/system calls. Trusted native code is not sandboxed without process isolation.
- Audio callback remains allocation-free, lock-free, I/O-free, logging-free, bounded and independent of UI/Dart. Never wait for workers in callback.
- Prepare topology, schedules, buffers, parameter resolution, state migration plans and resource requirements before activation. Reclaim retired state off callback.
- Preserve deterministic semantics, golden audio, project/module compatibility and live/offline parity.
- Adaptive concurrency uses bounded resource-aware scheduling and serial fast paths; no thread-per-task, oversubscription or speculative GPU path.
- No arbitrary product caps. Use explicit budgets, actionable errors and no silent project-content truncation. Bounded real-time queues require visible overflow diagnostics and safe recovery.
- No GPL dependency without owner approval. No in-app AI or cloud-audio integration. Recording remains deferred.
