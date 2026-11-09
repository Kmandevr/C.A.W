# Handoff

Commit: b276cc4

Branch: ccr-56285e11-0xrj3h (PR #138 open; contains everything below)

## Goal
Owner (2026-11-09): a C++ effect is written, compiled and used in music, all in the app, offline, with no workarounds (#137).
- It behaves like a CLAP plugin in REAPER, in C.A.W's own format, in-process for now.
- UI is on hold ("needs a little more work"). Build everything else; ask before UI.
- The UI decisions so far are in `docs/decisions.md` (2026-11-09) and #137/#139:
  - three tab types: C++ Builder, project file browser, Arrangement;
  - a C++ Builder with a side-drawer of files, inline errors plus a list, a test strip and a blank template;
  - trust: own builds load Trusted, others ask once;
  - "+ C++ effect" in the FX chains.

## Done in PR #138 (Release and ASan CTest pass locally; Dart only in CI)
- Engine:
  - `ComponentChain` (`engine/src/component_chain.*`): track inserts and the master chain, params through the F6 resolver.
  - Bypass, state (save while playing, load at build), automation lanes, tails after Stop (`Mode::Tail`), latency compensation (`DelayLine`), crossfaded chain swaps.
  - `reloadNativeComponent` (rebuild while playing).
  - C API version 3: `caw_engine_set_component_param`/`_bypass`/`_states`, `caw_engine_reload_component`.
- Compiler:
  - `engine/compiler/`: `caw_compiler.cpp` (driver, then cc1 and LLD in-process), JNI, `build-llvm.sh`, `bundle.sh`, `package-android.sh`, `test.sh`, licences.
  - `.github/workflows/compiler.yml`: LLVM is cached per version; a newer push doesn't cancel a run.
  - app.yml packages the compiler into the APK when the cache exists.
- Android: `CompilerService` (`:compiler` process), `CompilerClient`, `ToolchainInstaller`, and the `caw/compiler` channel (`run`, `installToolchain`).
- Dart:
  - `lib/platform/cpp_compiler.dart` (`CppSourceBuilder`, manifest, read-only results) and `buildInApp`.
  - `lib/model/native_trust.dart` and `sha256.dart`.
  - `ComponentUseDoc` (params, bypass, state), with states stored on every save.

## Next
- Wait for the first Compiler run (42695179714, commit 0c1ec4c) to cache LLVM.
  - Then re-run Compiler on the head, and re-run the APK job.
  - Fix build-llvm/wrapper/test failures (the wrapper has never compiled yet).
  - Cancel duplicate Compiler runs that start before the cache exists.
  - A check-in is scheduled for 22:50 UTC.
- An audio review of e4ed26f..HEAD is running. Fix what it finds, then merge #138 when CI is green.
- Later: components between .caw modules (#17 dual mono), and #121 pan/width.

## Open (owner)
- UI pass (#137, #139). #20 phone check. Old branches deleted by hand.

## Read first
- `docs/decisions.md` (top entries)
- `engine/src/component_chain.h`
- `engine/compiler/caw_compiler.cpp`
