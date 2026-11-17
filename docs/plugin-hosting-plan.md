---
title: Plug-in hosting plan
summary: The isolation design and the silent staged plan for hosting CLAP/VST3 plug-ins (#212, live in 1.1.0), the verified facts and the owner's open questions; planned, not built.
updated: 2026-11-17
---

# Plug-in hosting plan

**[Proposal]** None of this is built. It is an architect review from 2026-11-17, laid down silently in steps (the owner's groundwork rule, [decisions](decisions.md)). It goes live in 1.1.0. The owner reviews the isolation design before step 1.

## Where things stand today **[Fact]**, checked 2026-11-17
- Isolated is refused: `engine/src/module_registry.cpp` and `app/lib/model/native_trust.dart`. The C API already has `CAW_NATIVE_TRUST_ISOLATED`.
- Trusted plug-ins run in the app's own process: the plug-in benchmark and the serial lanes (`ComponentChain::foreign`).
- The only separate process is Android's `:compiler` service. It is a plain `android:process` (not `isolatedProcess`), with one build per bind over a `Messenger`.
- `engine/plugin/{clap,vst3}` holds the export wrappers and test hosts, not a general host.

## Isolated mode: the design
- **A host process.** A small `caw_plugin_host` runs per plug-in instance by default. It links only the hosting code.
  - **Windows:** a child process in a Job Object (it is killed with the app, and its memory is capped), with a shared memory section.
  - **Android:** a `PluginHostService` in its own declared process, ideally `isolatedProcess`. It gets the plug-in `.so` and the shared memory as file descriptors, and it cannot read app storage itself.
  - **Linux CI:** the same POSIX code.
- **Audio exchange that never waits.** Each instance has one shared region holding input and output block slots, plus SPSC rings for events and parameter changes.
  - At each block, the audio callback writes the input and wakes the host without blocking. It then reads the previous block's output if it is ready; otherwise it plays silence or the last block and counts a miss.
  - So Isolated adds a fixed latency of **one block**, reported as the plug-in's latency so the delay compensation covers it.
  - Two missed blocks in a row bypass the node: effects pass the dry sound, instruments go silent.
- **Control:** state, activation, scanning and (later) GUIs go over a separate channel, never on the audio thread. That channel is Binder on Android and a named pipe on Windows.
- **Crashes:** a watchdog sees a stalled heartbeat or a dead process. It restarts the host with backoff and the last saved state, and gives up after 3 crashes, marking the node failed. The app itself never goes down.
- **Trusted** stays in-process. **Blocked** stays refused before the library is opened.
- **Cost on a phone:**
  - one more process, about 10–30 MB each **[Assumption]**;
  - one block of latency;
  - two context switches per block;
  - the host thread may not get real-time priority outside the audio callback **[Assumption]**.
  
  The Benchmark measures all of this.

## Silent steps
1. **1.0.6:** the shared-memory ring (a new isolation folder in the engine sources), with tests across two processes on Linux and Windows CI. Nothing calls it.
2. **1.0.7:** the host executable and an `IsolatedProcessor` proxy. These load a C.A.W component first (not CLAP), and are compiled only with the `CAW_ISOLATED_HOST` CMake option (OFF).
   - Tests: render parity against in-process at one block of offset; `kill -9` mid-render, which bypasses and restarts; a stalled host never makes the callback wait.
   - CI checks the binary size, so it is shown to cost nothing while off.
3. **1.0.8:** the Android service, a client and a JNI bridge. It is never bound unless a hidden dev flag is on. An emulator test (API 34+) loads a fixture `.so` from a file descriptor in an isolated process; **this settles the riskiest Android assumption, so run it early**.
4. **1.0.9:** the scan, run inside the host process only, with timeouts and a cache. It is reachable only from the CLI (`caw scan`), with tests for hanging and crashing plug-ins.
5. **1.0.10:** the CLAP and VST3 adapters, mapping their audio, sidechain and note ports to the graph's typed ports, ready for the 1.1.0 routing (#233). The UI comes in 1.1.0, after the owner reviews its look.

## Facts and checks
- **[Fact]** CLAP is MIT, v1.2.9 (verified 2026-11-10). VST3's `pluginterfaces` is MIT from 3.8.0 (verified 2026-11-11). Steinberg's VST logo and trademark guidelines are still to be checked if "VST3" appears in the UI.
- **[Fact] Google Play,** verified 2026-11-17 (support.google.com, Play policy answer 9888379): "an app may not download executable code (such as dex, JAR, .so files) from a source other than Google Play". The only exception is code run in a VM or interpreter.
  - This **conflicts with loading downloaded third-party plug-in `.so` files in a Play build** (#222).
  - It also conflicts with the in-app self-update in a Play build.
  - Plug-ins the user compiles on the device are not downloaded. That this makes them allowed is an interpretation **[Assumption]**.
- **[Fact]** With targetSdk 29+, an app can't `execve` files in its data (verified 2026-11-09).
- **[Assumption]** These are unverified:
  - `dlopen` of an app-data `.so` is still allowed at targetSdk 34+;
  - an isolated process can map a `.so` passed by file descriptor;
  - an isolated process can use futex or eventfd on shared memory.
  
  Step 3's emulator test checks them.
- **iOS:** built-ins only. Isolated and Trusted compile out.

## Open questions for the owner
1. **Settled** (owner, 2026-11-17): two Android builds. The GitHub build has everything; the Play build follows Play's rules. Open: whether an interpreted plug-in format (a bytecode or WebAssembly interpreter in the engine) could bring third-party plug-ins to the Play build at a CPU cost, and whether iOS can do the same.
2. One host process per plug-in instance (more memory, a crash takes down one instance) or one per plug-in?
3. **Settled** (owner, 2026-11-17): one block is fine, plus an optional no-delay mode that runs in the callback with a timeout.
4. What users see on a crash: bypass, mute, or a notice?
5. Are plug-in GUIs (VST3 editors, CLAP GUI embedding) in scope for 1.1.0?
6. Which trust a plug-in gets the first time it is seen (already open in [vision](vision.md)).
