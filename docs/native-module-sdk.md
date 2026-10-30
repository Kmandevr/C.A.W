---
title: Native module SDK
summary: C ABI contract for trusted native CAW DSP modules, validation, real-time rules, state and packaging.
updated: 2026-10-30
---

# Native module SDK v1

**Status:** SDK contract drafted; dynamic loading, host-side adapter, signing and platform packaging are not yet implemented. This document does not claim that third-party binaries can already be loaded.

## One module system

Built-in modules and add-on modules share the same stable identity, typed ports, parameter metadata, graph validation, state versioning and stereo processing model. The C ABI in `engine/include/caw_module_sdk.h` is the native boundary; it intentionally avoids a C++ ABI so modules can be built with different compilers.

## Entry point

A module exports `caw_get_native_module_v1`, returning a static `CawNativeModuleV1`. The descriptor declares a stable reverse-domain ID, ports, parameters and a maximum serialized state size. The host validates the ABI version, struct sizes, pointer/count pairs, IDs, port directions/types/layouts, finite parameter ranges and resource limits before creating an instance.

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
- State size is capped by the host and declared maximum; the host rejects oversized state.
- Hosts must pin module version and preserve project snapshots or report missing/incompatible dependencies.
- Optional features may be omitted from a build, but a missing dependency must be reported explicitly rather than silently substituted.
- The v1 interface is stereo-native. Mono and discrete layouts are explicit port declarations, never inferred from buffer count.

## User interfaces

The SDK deliberately does not prescribe one UI. A module may provide a declarative control schema, a custom host-rendered view, or code-driven controls. The project/app stores UI metadata separately from DSP state so the same module works in the app, project tools and future plugin wrappers.

## Build stages still required

1. Validate the complete descriptor at load time, including string bounds and duplicate IDs.
2. Add platform-specific dynamic loading and unload only after all audio references are retired.
3. Add a host adapter that converts validated SDK descriptors into the shared internal module contract.
4. Add crash/timeout diagnostics and optional out-of-process hosting for untrusted modules.
5. Add signed packages, dependency manifests and reproducible build metadata.
6. Add example modules and CI builds for Android, Windows, macOS and Linux.

The current in-process SDK is for trusted native code only. A module package must never be described as sandboxed until process isolation is implemented and tested.
