---
title: How it works
summary: The path a sound takes from a .caw file to the speaker and to a WAV, the file that owns each step, and where to make each kind of change.
covers: [engine/src/compile.h, engine/src/vm.h, engine/src/engine.h, engine/src/capi.cpp, engine/src/builtins.cpp, engine/src/module.*, engine/src/module_registry.*, engine/src/graph.*, engine/src/dependency.*, engine/src/execution.*, engine/src/hardware.*, engine/src/scheduler.*, engine/src/worker_api.cpp, engine/src/midi2.*, app/lib/engine/engine.dart, app/lib/engine/execution.dart, app/lib/engine/bindings.dart, app/lib/model/app_state.dart]
updated: 2026-11-04
---

# How it works

The map for an agent new to the repo. It shows how the parts connect; the details live in [engine](engine.md) (language, playback, C API), [app](app.md) (screens) and [agent guide](agent-guide.md) (writing modules). Every source file starts with a one-line comment saying what it is for, and `.claude/tools/tree.sh <dir>` lists them. The app's areas are called Sounds, Tracks and Export on screen, and `builder`, `arranger` and `exporter` in code (`app/lib/ui/builder_screen.dart`, `arranger_screen.dart`, `exporter_screen.dart`).

## From a keystroke to sound

1. **Text.** A module is plain `.caw` text: a header, then code ([engine](engine.md#module-files-caw)). In the app it is `ModuleDoc.source` (`app/lib/model/project.dart`). The piano roll edits pattern text through `app/lib/model/pattern_doc.dart`, so a pattern is still text.
2. **Edit to project JSON.** `AppState.editSource` (`app/lib/model/app_state.dart`) stores the text. On Run, or auto-update after a pause, the text becomes the module's `run_source`. `_syncNow` turns the whole project into the engine's project JSON (`Project.toEngineJson`) and sends it.
3. **Off the UI thread.** Project compilation, `Engine.checkAsync` source checks and offline WAV renders are native jobs submitted to the bounded C++ `AdaptiveWorkerPool`. The app owns each opaque job handle, polls its versioned status/progress and retrieves its result/error; no native worker calls Dart. Project jobs retain the engine handle until completion, so disposal waits safely for accepted work. Jobs use foreground or offline priority, and the app starts with an interactive-preview concurrency budget. Live auto-update uses the result of its one project compile rather than precompiling the same source twice. The native pool never touches the audio callback.
4. **C API.** `caw_engine_set_project` (`engine/src/capi.cpp`) hands the JSON to `Engine::setProjectJson` (`engine/src/engine.h`). `engine/include/caw.h` is the only door into the engine, for the app, the CLI's tests and any future plugin.
5. **Parse and diff.** `parseProject` (`engine/src/project.cpp`) validates and normalizes project data, but still applies fixed limits to layers, chains, modules, clips, automation and arrangement length. Some excess data is rejected; some is skipped or truncated. The app model also bounds automation and arrangement data. These are known migration targets, not intended product limits; see [engine progress](engine-progress.md).
6. **Compile.** A synth patch (`kind: synth`) is first translated to ordinary code by `translateSynth` (`engine/src/synth.cpp`): one generator for the voice and effect modules for its `fx` lines, which the engine runs after the voices as hidden modules (`ModuleState::expand`). `compileModule` (`engine/src/compile.cpp`) reads the header, lexes and parses in one pass, and emits register bytecode (`Program`, `engine/src/program.h`), folding constants with the same operator code the VM uses (`engine/src/ops.h`). Pattern modules go to `parsePattern` (`engine/src/pattern.cpp`) instead. Errors come back as one line with a position, and the old program keeps playing.
7. **Hand-over.** The current Engine sends per-layer commands through a bounded SPSC queue in `engine/src/spsc.h`. `send` retries for about two seconds and can drop an install/pattern command without propagating failure. Retired programs return through a bounded queue plus a fixed pending list; overflow can leak. This is a known correctness gap. The target is one prepared project snapshot published transactionally and reclaimed off the audio thread.
8. **Audio callback.** miniaudio (`engine/platform/audio_miniaudio.cpp`) calls `Engine::process`. For each layer in dependency order, the generator's `Instance::process` (`engine/src/vm.cpp`) runs every op over a whole block, then the effects run on its output. Pattern layers run the generator once per voice, with `note`, `gate` and the rest set per note. Then the mix, pan, the DC blocker and the limiter.
9. **Built-ins.** Every function a module calls is a row in `kBuiltins` (`engine/src/builtins.cpp`): its code, its state size and its docs. Library modules in `engine/lib/*.caw` are written in the module language and compiled in.
10. **Back to the screen.** The app reads meters and scopes through `caw_engine_meters`, `caw_engine_layer_meter` and `caw_engine_scope`, polled by `app/lib/model/poller.dart` only while something can change.

`AppState` also owns transport timing. Tap Tempo keeps up to five increasing tap timestamps, starts a new measurement after a pause longer than two seconds, averages the intervals and clamps the resulting project tempo to 20–400 BPM. The project update then follows the normal sync and save path.

## Modular engine foundation (PR #25)

The modular foundation is real native C++ code, but it is not yet the active playback path for ordinary projects. Its implementation status and remaining integration work are tracked in [engine build status](engine-build-status.md); the intended ecosystem contract is in [engine integration](engine-integration.md).

| Area | Implementation | What is true today |
| --- | --- | --- |
| Module contract | `engine/src/module.h`, `module.cpp` | Typed audio, control, modulation and event port descriptors; the `Event` record (note id, raw UMP); parameter metadata; generated/custom UI metadata; descriptor validation; the processor interface (`process`, `processPorts`). |
| Parameter resolver | `engine/src/params.h`, `params.cpp` | One parameter's value per block from its manual/MIDI base (smoothed), automation (unless touched) and modulation links in id order, on the descriptor's curve, then clamped and stepped (F6.1; not wired into the executor yet). |
| Module registry | `engine/src/module_registry.h`, `module_registry.cpp` | Static in-process registry with stable-ID lookup, factory creation, descriptor checks and reset/versioned-state hooks. It does not dynamically load third-party binaries. |
| Processing graph | `engine/src/graph.h`, `graph.cpp` | Typed graph validation and deterministic topological ordering. The compiler has no former fixed node/connection count caps; node indices remain `uint32_t`. Compile/prepare require `GraphResourceBudget.maxWorkingBytes`, with optional count ceilings defaulting to unlimited; internal working-set estimates are checked before allocation. The executor accepts caller-selected block sizes without the former 8,192-frame cap, is planar N-channel with summing inputs, and can be re-routed on the audio thread (`setRouting`). The Engine owns one such graph for its mix (F4.3). |
| Graph publication | `GraphRuntime` in `graph.*` | A control-thread publication helper lets the audio thread adopt a prepared graph and defers reclamation to the control thread. It is not connected to `Engine` or `VM`. |
| Workload policy | `engine/src/execution.*`, `execution_capi.cpp`, `app/lib/engine/execution.dart` | A deterministic native policy maps task class and host-supplied pressure to a bounded worker budget. The app applies an interactive-preview budget to its native pool. Android thermal/battery-saver events and app foreground/audio transitions update the active plan; other platform pressure adapters remain unknown/unimplemented. |
| Hardware profile | `engine/src/hardware.*`, `app/lib/engine/execution.dart` | Best-effort active/online logical-core probe, process affinity on supported hosts, Linux/Android cgroup CPU and memory limits, conservative available-memory budget and CPU-SIMD probe; Linux/Android account for cgroup headroom, including exhausted limits. macOS/iOS use a physical-memory fallback. Missing signals remain unknown and policy falls back conservatively. Android `PowerManager` thermal (Android 10+) and battery-saver signals feed the scheduler through event-driven channels; app foreground/audio transitions also refresh policy. Unsupported platforms remain `Unknown`, not normal. GPU compute is unavailable in this build. |
| Worker pool | `engine/src/scheduler.*`, `engine/src/worker_api.cpp`, `app/lib/engine/execution.dart` | The C++ pool is a bounded non-real-time queue (256 jobs), up to 16 workers, with priorities and an adaptive wrapper. It creates workers only for demand, sleeps on a condition variable, and retires idle workers after 30 seconds by default; completed slots are joined and reused. The public C API exposes job handles/status/progress/results/cancellation. The app submits project compilation, module checks and offline WAV renders to it; generation and analysis jobs remain to be routed. |
| Dependencies | `engine/src/dependency.*`, `engine/src/project.*` | Exact scope-aware resolution by stable ID, pinned version, optional hash and interface version. Project JSON parses and stores references; installed-library matching, project writing/round-tripping and repair UI are not complete. |
| MIDI 2.0 input primitive | `engine/src/midi2.*` | Channel Voice UMP decoding and a bounded lock-free input queue. This is not live USB/Bluetooth device I/O or Engine voice routing. |

**Important boundary:** since F4.3 live playback and offline render run through the Engine's mix graph, with a node per module of each track (generator or voice pool, then each effect), a track node, folder bus nodes and a master node (F4.4). The graph compiler cap-removal and low-level budget slices passed CI at checkpoint 1269019; follow-up commit e815b495 adds direct compiler-budget rejection coverage and awaits CI. The prepared executor is planar N-channel since F3 (any layout) and runs audio, modulation and control ports since F5.1 and event ports since F5.2. Native-pool routing is implemented for project compilation, source checks and offline WAV renders; generation/analysis routing remains incomplete. Android live thermal/battery-saver and lifecycle pressure feeds are connected; other platform adapters remain incomplete. Do not describe graph hot-swap integration, universal native-module execution, dynamic add-on loading or app-side custom UI rendering as complete.

The synth and built-in language also gained concrete capabilities in this branch: `lfo.curve(...)` is a tempo-synced four-point LFO, and `wt(..., warp)` / synth `warp` settings add bounded phase distortion to wavetable oscillators. Their user-facing signatures and examples are generated into [the function library](library.md) and described in [synth](synth.md).

## Export

`caw_render` (`engine/src/render.cpp`) drives the same `Engine` offline, so a file matches what was heard bit for bit, and writes it with `engine/src/wav.cpp`. The app submits it as an offline-priority native job with progress and cancellation (the Export area). The CLI (`engine/cli/main.cpp`) uses the same native render call.

## Where to change what

| To change | Edit | Then |
| --- | --- | --- |
| Add or change a built-in function | `engine/src/builtins.cpp` (and `builtins.h` for a new kind) | `caw docs` to regenerate [library](library.md) and [agent guide](agent-guide.md); `caw_tests` |
| Change module descriptors, ports or parameter/UI metadata | `engine/src/module.*` | `module_test.cpp`, `module_registry_test.cpp`; update [engine build status](engine-build-status.md) |
| Change graph validation, execution order or prepared N-channel processing | `engine/src/graph.*` | `graph_test.cpp`, `graph_channels_test.cpp`; preserve the no-allocation/no-lock process contract (checked by `alloc_counter.cpp`) and the shared float routing rule in `route_math.h` |
| Change hardware policy or background scheduling | `engine/src/execution.*`, `hardware.*`, `scheduler.*` | matching execution, hardware and scheduler tests; keep worker jobs off the audio callback |
| Change dependency identity or resolution | `engine/src/dependency.*`, `engine/src/project.*` | `dependency_test.cpp`, project tests; document what is parsed versus actually resolved |
| The synth's patch lines and the code they become | `engine/src/synth.cpp` | [synth](synth.md); `synth_test.cpp`; `caw check --code` |
| Add a built-in wavetable shape | `engine/src/tables.cpp` (and its `table.*` name in `builtins.cpp`) | `caw docs`; `synth_test.cpp` |
| Add a library function in the language | `engine/lib/*.caw` with `///` docs | `caw docs`; `caw_tests` |
| Language syntax (statements, params, operators) | `engine/src/compile.cpp`, `ops.h` for operators | [engine](engine.md) language section; `language_test.cpp` or `variables_test.cpp` |
| Pattern text format | `engine/src/pattern.cpp` and the app's `app/lib/model/pattern_doc.dart`, which must agree | `pattern_test.cpp`, `app/test/pattern_doc_test.dart` |
| Playback, mixing, voices, hot swap | `engine/src/engine.cpp` (real-time rules: `.claude/rules/engine.md`) | `engine_test.cpp`; ask `audio-reviewer` |
| A new C API call | `engine/include/caw.h`, `engine/src/capi.cpp` or `engine/src/worker_api.cpp`, `app/lib/engine/bindings.dart`, `app/lib/engine/engine.dart`, `app/lib/engine/execution.dart` | [engine](engine.md#c-api-engineincludecawh) |
| Something the app keeps (projects, settings) | `app/lib/model/` | [app](app.md) |
| A screen | `app/lib/ui/<screen>.dart`; a new command also gets an action in `app/lib/actions/catalogue.dart` | [app](app.md), [actions](actions.md) |
| A starter module | `examples/*.caw` | `caw_tests --update-golden` only for an intended sound change |

## Checks

- Engine: build with CMake and run `caw_tests` ([engine](engine.md#tests)); `caw check FILE.caw` and `caw render` check a module without listening.
- App: `flutter analyze` and `flutter test` in `app/`; `CAW_LIB=<built libcaw.so>` adds the tests that need the engine.
- Docs: `node scripts/docs-test.js`.
