# Handoff

Commit: b350bf8

Branch: ccr-56285e11-0xrj3h (PR #138 open; everything below is in it)

## Goal
Owner (2026-11-09): write, compile and use a C++ effect in the app, offline, without workarounds (#137).
- It behaves like a CLAP in REAPER, in C.A.W's format, in-process. UI is on hold: build everything else and ask before UI.
- UI decisions so far: `docs/decisions.md` (2026-11-09), #137, #139.

## Done and verified
- Engine (Release and ASan CTest pass locally): `engine/src/component_chain.h`.
  - Inserts with params, bypass, state, automation, tails, latency compensation, crossfaded swaps, reload. Audio-review fixes are in.
- Toolchain bundle layout: checked with the NDK r30 clang++ driver via `engine/compiler/test.sh`.
- CI: Compiler (Android ARM64) passes. LLVM is cached, and `engine/compiler/package-android.sh` works.
- Dart has CI only, no local Flutter:
  - `app/lib/platform/cpp_compiler.dart`, `app/lib/model/native_trust.dart`, `app/lib/model/native_components.dart`;
  - the Kotlin side is in `app/android/app/src/main/kotlin/com/kmandevr/caw/`.

## Next
- The Linux compiler test (first run 42695179714) is still building LLVM. When it ends:
  - re-run Compiler on the head, then fix `engine/compiler/caw_compiler.cpp` if it fails;
  - re-run the APK job so the compiler is in the APK.
- Cancel duplicate Compiler runs started before the host cache existed. A check-in is set for 22:50 UTC.
- Merge #138 when all CI is green.
- Follow-ups: #17 dual mono; #121.

## Open (owner)
- UI pass (#137, #139), #20 phone check, deleting old branches.

## Read first
- `docs/decisions.md`
- `engine/compiler/caw_compiler.cpp`
