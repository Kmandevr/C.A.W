---
title: Native module SDK
summary: C ABI host contract and C++ component SDK, validation, real-time rules, state and packaging.
updated: 2026-11-09
covers: [engine/include/caw_component.h, engine/include/caw/module.hpp, engine/include/caw/component.hpp, engine/CMakeLists.txt, engine/cmake/, examples/cpp/minimal/, scripts/caw-component-build.js, .github/workflows/cpp-components.yml, engine/src/module.*, engine/src/module_registry.*, engine/src/graph.*]
---

# Native module SDK v1

**Status [Fact, checked 2026-11-06]:** the versioned C ABI header, internal descriptor validation, static registry and graph/processor foundations exist. The C++ SDK is installable as a CMake package for standalone engine builds (the app's embedded engine build opts out); the manifest-driven component helper, exported descriptor/create/destroy entry points, structured diagnostics and Linux/Windows/Android CI workflow are implemented. The app now persists C++ source and pinned dependencies, runs a local CMake build, and receives a verified artifact path. `ModuleRegistry` now loads shared libraries through `Engine` and the C API only after an explicit trust value: Blocked refuses to open the library, Isolated is refused because no process sandbox exists, and Trusted loads in-process. The Flutter FFI/UI and playback-graph insertion are still outstanding; a successfully built component is not automatically loaded or authorized. Signing, crash isolation and runtime packaging remain future work.

## One module system

Built-in modules and add-on modules share the same stable identity (with display name, component version and role), typed ports, parameter metadata (choices and modulation/automation/MIDI capability flags, CP.2; components export their SDK header revision and the registry refuses any other), graph validation, state versioning and processing model: internally N-channel planar buffers with a stereo adapter, summing (mix-bus) inputs since F4.1 (2026-11-03) and audio-thread re-routing of summing inputs since F4.3 (`GraphExecutor::setRouting`), plus one-source routes into plain inputs since F4.4 (`prepareRouted`), which the Engine's mix graph uses (and whose `workingBytes()` estimate sets how many layers the Engine can grow to, F7.3), and since F5.1/F5.2 several audio ports, modulation, control and event ports for internal modules that implement `processPorts`; which saturate a processor's inf at ±FLT_MAX and treat NaN as 0 (`route_math.h`). Compiled components cross a plain C boundary, `engine/include/caw_component.h` (interface v3, see below); the C++ contract in `engine/include/caw/module.hpp` is compiled into each component and into the engine separately (`CAW::SDK` passes the engine's floating-point flags, no fused multiply-add contraction and no fast-math, so the public deterministic maths in `caw/detmath.hpp` and the Library in `caw/library/` give the same bits in a component as in the engine), so the two can use different compilers and C++ standard libraries. Internal `engine/src/module.h` forwards to that canonical header. A v1 `caw.component` manifest and CMake helper build an external shared library and emit a configuration-specific artifact path for the app build service.

## Entry point

**C interface v3 (CP.2, 2026-11-09).** A component library exports one symbol, `caw_get_component_v3(index)`, returning a static `CawComponentV3` table for each component it holds (a bundle may hold several, owner 2026-11-09; NULL past the last): a size-tagged `CawComponentDescriptor` (id, name, version, role, latency, tail, maximum state size, ports, parameters with choices and capability flags, UI controls, custom UI id; arrays read with the strides it declares) and functions `create(host)`, `destroy`, `activate(sample rate, max frames)`, `deactivate`, `reset`, `process` (the full typed-port block), `save_state`/`load_state` (with a state version) and `get_extension`. Plain C only (`engine/tests/component_header_check.c` compiles it as C99). Growth rules: each top-level struct starts with `struct_size` and readers accept larger ones; arrays use the declared strides; new capabilities arrive through `get_extension` on the host and component sides (none are defined yet). Threads: create, activate, deactivate, state, extensions and destroy on a control thread; process and reset on the audio thread, only while active. In C++, `CAW_EXPORT_COMPONENT(Type, descriptor)` exports one component and `CAW_EXPORT_COMPONENTS(A, B, ...)` a bundle (`engine/include/caw/component.hpp`); each builds the table from a `ModuleProcessor` and catches exceptions at the boundary. `ModuleRegistry` resolves only that symbol, walks its entries to the one with the expected id (refusing another interface version at any entry), checks sizes and the required functions, copies the descriptor into engine-owned storage (the C descriptor is the wire format; the engine works only with `caw::ModuleDescriptor`), validates it, and wraps each instance in an adapter that fills a C process block without allocating. The stereo-only interface v1 (`caw_module_sdk.h`) and the C++-typed `caw_component_*` exports are gone (owner, 2026-11-09: no v1 compatibility). Hosts read the loaded components' descriptors through `caw_engine_components` (JSON, `moduleDescriptorJson`), which the app parses into `NativeComponentInfo` (`app/lib/engine/component_info.dart`) with `Engine.nativeComponents()`; no screen uses it yet.

## Real-time contract

The process callback may run on the audio thread. It must:
- allocate no memory and perform no file, network, logging or UI I/O;
- acquire no mutexes and wait on no other thread;
- process only the supplied bounded frame count;
- treat buffers and parameter arrays as borrowed for the duration of the call;
- return promptly and never throw across the C boundary;
- avoid unbounded loops and uncontrolled recursion.

Creation, destruction, state serialization, graph compilation and asset loading happen off the audio thread. A module that violates the contract can still stall or crash an in-process host: native modules are trusted code, **not a security sandbox**. Untrusted modules require process isolation, which is a separate future host feature.

## Resource and compatibility rules

- Stable IDs identify modules; display names are not identifiers.
- Parameter IDs and port IDs are stable within a module major version.
- Parameters arrive as one value per block: the block's first resolved value (owner, 2026-11-04). Internal modules get them from the graph executor as `AudioProcessBlock`/`ProcessBlock::parameters` (per-frame when a value varies, is modulated, automated or moved by a mapped MIDI CC, F6.2–F6.5); the C ABI does not change for that.
- State size is capped by the host and declared maximum; the host rejects oversized state.
- Hosts must pin module version and preserve project snapshots or report missing/incompatible dependencies.
- Optional features may be omitted from a build, but a missing dependency must be reported explicitly rather than silently substituted.
- The v1 interface is stereo-native. Mono and discrete layouts are explicit port declarations, never inferred from buffer count.

## User interfaces

The SDK deliberately does not prescribe one UI. A module may provide a declarative control schema, a custom host-rendered view identifier, or code-driven controls. This is metadata and validation only; the CAW app's UI renderer and custom-view runtime are still future integration work. The project/app stores UI metadata separately from DSP state so the same module works in the app, project tools and future plugin wrappers.

## Implemented loading and remaining stages

- **Implemented:** load a shared library on Windows with `LoadLibraryW`, and on Linux/macOS/Android with `dlopen`; validate the exported descriptor and expected stable ID; require descriptor, factory and component-owned destroy exports; keep the library loaded while any created processor wrapper exists; refuse unload while an instance is alive.
- **Implemented:** `ModuleRegistry` and the Engine control API expose this loader. The C API `caw_engine_load_component` requires an explicit `CAW_NATIVE_TRUST_BLOCKED`, `CAW_NATIVE_TRUST_ISOLATED` or `CAW_NATIVE_TRUST_TRUSTED` value. Invalid values are rejected. Blocked never opens the library; Isolated is explicitly unsupported; Trusted executes in the Engine process. Build success never calls this API.
- **Partial:** the registry returns a `ModuleProcessor` wrapper that delegates processing/state calls and retains the library lifetime. The Engine plays explicitly loaded native stereo effects with their parameters on tracks (`LayerDoc.components`) and the master (`ProjectDoc.masterComponents`), with the safety limiter after native code. Effects with other ports (control, modulation, events, more than one audio port) and latency compensation remain outstanding. The Dart FFI load/unload wrapper runs on a background isolate; the per-component trust UI/store is still missing.
- **Still required:** process isolation for Isolated mode, crash/timeout diagnostics, signed packages, dependency manifests and reproducible build metadata, and CI coverage for macOS in addition to the current Linux/Windows/Android matrix.

The current in-process SDK is for trusted native code only. A module package must never be described as sandboxed until process isolation is implemented and tested.
