---
title: Native module SDK
summary: C ABI host contract and C++ component SDK, validation, real-time rules, state and packaging.
updated: 2026-11-06
covers: [engine/include/caw_module_sdk.h, engine/include/caw/module.hpp, engine/include/caw/component.hpp, engine/CMakeLists.txt, engine/cmake/, examples/cpp/minimal/, scripts/caw-component-build.js, .github/workflows/cpp-components.yml, engine/src/module.*, engine/src/module_registry.*, engine/src/graph.*]
---

# Native module SDK v1

**Status [Fact, checked 2026-11-06]:** the versioned C ABI header, internal descriptor validation, static registry and graph/processor foundations exist. The C++ SDK is installable as a CMake package for standalone engine builds (the app's embedded engine build opts out); the manifest-driven component helper, exported descriptor/create/destroy entry points, structured diagnostics and Linux/Windows/Android CI workflow are implemented. The app now persists C++ source and pinned dependencies, runs a local CMake build, and receives a verified artifact path. `ModuleRegistry` now loads shared libraries through `Engine` and the C API only after an explicit trust value: Blocked refuses to open the library, Isolated is refused because no process sandbox exists, and Trusted loads in-process. The Flutter FFI/UI and playback-graph insertion are still outstanding; a successfully built component is not automatically loaded or authorized. Signing, crash isolation and runtime packaging remain future work.

## One module system

Built-in modules and add-on modules share the same stable identity, typed ports, parameter metadata, graph validation, state versioning and processing model: internally N-channel planar buffers with a stereo adapter, summing (mix-bus) inputs since F4.1 (2026-11-03) and audio-thread re-routing of summing inputs since F4.3 (`GraphExecutor::setRouting`), plus one-source routes into plain inputs since F4.4 (`prepareRouted`), which the Engine's mix graph uses (and whose `workingBytes()` estimate sets how many layers the Engine can grow to, F7.3), and since F5.1/F5.2 several audio ports, modulation, control and event ports for internal modules that implement `processPorts`; which saturate a processor's inf at ±FLT_MAX and treat NaN as 0 (`route_math.h`). The C ABI v1 below stays stereo with no channel count; `engine/src/sdk_layout.h` maps its layout values explicitly. The C ABI in `engine/include/caw_module_sdk.h` remains a separate C-only host boundary. The C++ component contract in `engine/include/caw/module.hpp` crosses the platform C++ ABI and therefore must be built with the matching CAW toolchain/runtime; C linkage on its entry points does not make the pointed-to C++ class compiler-neutral. Internal `engine/src/module.h` forwards to that canonical header. `engine/include/caw/component.hpp` declares `caw_component_descriptor`, `caw_component_create` and `caw_component_destroy`; the destroy export keeps allocation/deallocation inside the component runtime. A v1 `caw.component` manifest and CMake helper build an external shared library and emit a configuration-specific artifact path for the app build service.

## Entry point

The separate C ABI v1 module exports `caw_get_native_module_v1`, returning a static `CawNativeModuleV1`. The descriptor declares a stable reverse-domain ID, typed ports, parameters, a maximum serialized state size, optional generated UI controls (slider, toggle, dropdown, XY pad, button and curve) and an optional custom UI identifier. The internal module contract validates that UI controls refer to real parameters and stay within their ranges. The host validates the ABI version, struct sizes, pointer/count pairs, IDs, port directions/types/layouts, finite parameter ranges and resource limits before creating an instance.

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
- **Partial:** the registry returns a `ModuleProcessor` wrapper that delegates processing/state calls and retains the library lifetime. `ProjectDoc.masterComponents` now routes explicitly loaded zero-parameter stereo effects through the live Engine master chain, with the safety limiter remaining after native code. Arbitrary typed-port mapping, parameters and track-chain integration remain outstanding. The Dart FFI load/unload wrapper runs on a background isolate; the per-component trust UI/store is still missing.
- **Still required:** process isolation for Isolated mode, crash/timeout diagnostics, signed packages, dependency manifests and reproducible build metadata, and CI coverage for macOS in addition to the current Linux/Windows/Android matrix.

The current in-process SDK is for trusted native code only. A module package must never be described as sandboxed until process isolation is implemented and tested.
