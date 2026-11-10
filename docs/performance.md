---
title: Performance
summary: How C.A.W is measured for low-end devices, the audit's ranked bottlenecks with evidence, fixes with before/after numbers, and what remains.
covers: [engine/bench/, app/lib/model/poller.dart, app/lib/model/settings.dart, app/lib/ui/motion.dart, app/test/poller_test.dart, app/test/rebuild_test.dart]
updated: 2026-11-10
---

# Performance

The owner's requirement (2026-10-28): run as light as possible, down to low-end phones ([UI design](ui.md#light-on-cpu-and-ram)). This note records how performance is measured and what the audit found. The first native runtime slice now processes zero-parameter stereo effects on the live master path. The host uses fixed preallocated stereo stages, performs no host allocation/locking in the callback, sanitizes component output and keeps the safety limiter after native code; old chains are reclaimed off-thread. This path has not yet been benchmarked on low-end Android, and plugin-internal allocations/CPU remain the component author's responsibility and are not yet reported by ABI v1.

## How it's measured

**Callback cost at large layer counts (#133, open):** several per-callback loops (`applyCommands`, `planChunk`, `updateSolo`) still run over the whole layer capacity, which never shrinks, so a project that grew to many layers keeps paying for them after it shrinks. Bounding them to the active slots needs callgrind before and after.

**Native component measurement still required:** add a `caw_bench` scenario that runs a trusted test component in `ProjectDoc.masterComponents`, then record mean/p99/max callback time, component-chain count scaling, project-state memory and retained memory after clearing/unloading the chain. The two preallocated stereo scratch stages live inside MasterChain and are included in the project-state estimate, so projects without native effects do not pay their baseline memory cost. ABI v1 does not report plugin-private heap/state size, so that portion is currently unknown rather than silently treated as zero.

- **`caw_bench`** (`engine/bench/caw_bench.cpp`, built with the engine tools) plays scenarios through `Engine::process` in 192-frame callbacks at 48 kHz, a common Android low-latency burst. The budget is 4,000 µs per callback. For each scenario it reports:
  - the mean, p99 and maximum time per callback, and the load (mean time ÷ budget)
  - the time `setProject` takes
  - the compile time per template, the time to re-send an unchanged project, the speed of a loop export, and memory (RSS)
- **Instruction counts** are the reliable before/after numbers: `valgrind --tool=callgrind ./caw_bench 2 N` runs scenario N for 2 s. Timings on a shared cloud server vary by ±30% from run to run, and instruction counts don't vary at all.
- **Graph executor scenarios** (`caw_bench SECONDS -1`, also run at the end of a full run): 8-node chains through `GraphExecutor`, reported in nanoseconds: a stereo chain of legacy stereo-only processors through the stereo wrapper, and planar chains at 1, 2, 6 and 8 channels. On 2026-11-03 (F3, callgrind, 192-frame callbacks) the stereo-wrapper chain cost 4,640 instructions per callback on the old left/right executor (`9b2f059`) and 5,086 on the planar executor (+9.6%, about 56 per node, from the generic-to-stereo adapter). Since F4.3 the live mixer itself is a graph; the playback scenarios above measure it. Callgrind against the old mixer (192-frame callbacks): 1 layer 153,259 vs 152,343 instructions, 4 layers 590,041 vs 589,495, 16 layers 2,071,648 vs 2,072,626. The first F4.3 version ran all 65 slot nodes every chunk and cost +55,000 instructions per callback; leaving idle slots out of the routing order removed that. F4.4 (each track module its own node), 2026-11-04, before → after: 1 layer 152,390 → 132,831; 4 layers 589,489 → 577,970; 16 layers 2,072,610 → 2,070,932 (it no longer zeroes 65 slot buffers per chunk); 4 layers each with delay and reverb 974,775 → 999,238 (+2.5%: about 1,900 instructions per extra module node per 64-frame chunk, mostly float lane conversion). A playing track's loop restart or code-swap point also ends the chunk for every track, so each such point costs one extra pass over the routed nodes' fixed per-chunk work (bounded: about two per playing track per block). F5.1 (typed ports, per-port executor tables), before → after: 1 layer 132,861 → 132,983; 4 layers 577,972 → 578,344; 16 layers 2,070,985 → 2,072,078; `caw_bench SECONDS -1` graph scenarios +0.8%. F5.2 (event ports), before → after: 1 layer 132,966 → 132,990; 4 layers 578,287 → 578,302; 16 layers 2,071,925 → 2,071,941; graph scenarios +0.06% (nodes without event ports skip the event work). F6.1 (parameter resolver) added no audio-path work; F6.2 resolves parameters per node per block (one constant when nothing varies) and polls the parameter queue once per block; before → after: 1 layer 133,016 → 133,081; 4 layers 578,317 → 578,526; 16 layers 2,071,967 → 2,072,482; graph scenarios +0.5% (the per-node check, for nodes with no parameters). F6.3 (modulation links) is within noise: 1 layer 133,095 → 133,091, 16 layers 2,072,478 → 2,072,466, graph scenarios −0.05%. F6.4 (automation lanes) is within noise for graphs without lanes: 1 layer 133,094 → 133,104; 4 layers each with delay and reverb 1,000,087 → 1,000,078; graph scenarios +0.02%. F6.6 (the Engine's .caw params through the resolver), 1 layer 133,083 → 133,463 (+0.29%), 4 layers each with delay and reverb 1,000,169 → 1,002,141 (+0.20%), graph scenarios unchanged; a first version that resolved every param every chunk cost +0.64%, and the pass-through for params with no lane and an exact held value removed most of it. F6.5 (MIDI CC mappings) is within noise without mappings: 1 layer 133,115 → 133,152; 4 layers each with delay and reverb 1,000,094 → 1,000,074; graph scenarios +0.02%.
- **Scenarios:**
  1. 1 bytebeat layer
  2. the starter project (4 layers)
  3. 16 layers
  4. 64 layers
  5. two pattern layers (acid line and chords)
  6. the starter project with a delay and a reverb on every layer
  - Not numbered: stopped, a code edit every 0.25 s while 16 layers play, compiling, and a loop export.
- **Machine:** a 4-core Intel Xeon at 2.8 GHz in the cloud (2026-10-28), release build (`-O3`). A mid-range phone core is several times slower, so use these numbers to compare runs and to see each part's share. They are not phone timings.
- **Not measured, because no device is attached here:**
  - phone CPU, battery, heat and real audio dropouts
  - UI frame times on the device
  - startup time on the device
  - Check those on the S22+ with Android Studio's profiler or Perfetto from a release APK (see [Next steps](#remaining-bottlenecks-and-next-steps)).

## Engine audit (2026-10-28)

### Baseline (release, before fixes)

| Scenario | Mean / callback | p99 | Load |
| --- | --- | --- | --- |
| Stopped | 0.0 µs | 0.0 µs | 0% |
| 1 layer | 13.9 µs | 32 µs | 0.35% |
| Starter (4 layers) | 72.2 µs | 141 µs | 1.8% |
| 16 layers | 280 µs | 456 µs | 7.0% |
| 64 layers | 1,382 µs | 2,502 µs | 34.6% |
| Pattern layers | 66.6 µs | 138 µs | 1.7% |
| Starter + delay + reverb | 101 µs | 178 µs | 2.5% |
| 16 layers with a code edit every 0.25 s | 377 µs | 790 µs | 9.4% |

- **Other baseline numbers:**
  - Compiling a template takes about 0.3 ms; a pattern 0.005 ms. Re-sending an unchanged 16-layer project takes 0.07 ms.
  - A loop export of 16 layers runs 13× faster than real time.
  - RSS is about 14 MB, and setting up 64 small layers adds under 1 MB.

### Bottlenecks, ranked by measured share (callgrind, whole benchmark)

1. **The VM's integer conversion and `%`:** about 25% of all instructions, inside `Instance::process`.
   - `toUint32` (used by every bitwise operator) always ran `trunc`, plus `fmod` for negative values.
   - `%` always called `fmod`, even for whole numbers like `step % 4`.
   - Bytebeat code is mostly these operators.
2. **The VM's own dispatch:** about 20% (`vm.cpp`), plus 6% in the operators (`ops.h`). This is the interpreter's real work.
3. **The per-chain setup in `prepareLane`:** about 7–9%. It works out `step`, `beat`, `bar`, `pos` and `t` for every sample of every layer.
4. **Filter and envelope maths:** `detTan` 4–5%, `ad` 4–6%, `detExp` 2–3%. This is mostly modulated filter cutoffs. It's the sound itself, and it must stay bit-exact for determinism.
5. **`slotTarget`:** 1.5%, growing with the square of the layer count (the slot capacity is a runtime value since F7.3, whose parts A and B measured 1 layer −1.1%, 16 layers −0.3% and the graph −0.9% per callback together; process startup grew by about 24M instructions once, in the static table build). Every layer, every block, it scanned all 64 slots to see whether anything was soloed.

### Fixes (all bit-identical: golden hashes unchanged)

These fixes kept the golden hashes of their time. On 2026-11-03 Foundation F4.2 changed 10 template hashes on purpose (float routing, owner-approved, at most 1 LSB of a 24-bit WAV).

1. **`toUint32` fast path:** a value inside the int32 range is truncated straight to an integer, which gives the same bits as the full JavaScript rule.
2. **`%` fast path:** whole numbers use integer remainder, which gives exactly what `fmod` does, including the sign of a zero result.
3. **Solo checked once per callback,** and again whenever a layer's starting gain is set, instead of per layer per block.

Instructions for 2 s of playback, before → after:

| Scenario | Before | After | Change |
| --- | --- | --- | --- |
| Starter (4 layers) | 333.6 M | 280.2 M | −16% |
| 16 layers | 1,164.7 M | 944.6 M | −19% |
| 64 layers | 4,599.1 M | 3,673.4 M | −20% |
| Pattern layers | 266.4 M | 265.6 M | ±0 |
| Starter + delay + reverb | 549.2 M | 495.7 M | −10% |

Timed release run after the fixes (same server, a single run, so noisy):
- 64 layers: mean 769 µs, p99 1,193 µs, 19% load (was 34.6%)
- starter: 47 µs, 1.2% load
- code edits during 16 layers: 192 µs, 4.8% load

### Checked and fine

- **Stopped:** the callback just writes silence; costs about 0 µs.
- **Offline WAV exports:** run on their own `Engine` instance through the native bounded worker pool, so they never touch live playback state. They compete for CPU only; Android callback-thread priority still requires physical-device verification.
- **MIDI pattern import/export:** the native conversion API is currently called synchronously from the UI isolate. It is not routed through the native worker pool. Large-file responsiveness has not been benchmarked; move it off the UI isolate if measurements show a stall.
- **Live code edits:**
  - A swap compiles on the control thread, about 0.4–0.5 ms for 16 layers.
  - For 20 ms the audio thread runs both the old and the new code to crossfade.
  - Carrying state over copies at most 2 MB per swap.
- **Memory:**
  - Layer state is allocated when a chain is built, never in the callback.
  - Big effect buffers are cleared lazily ([engine](engine.md#built-ins-and-libraries)).
  - The project memory budget is 64 MB.

### Hardware limits used by the scheduler

- **[Fact]** The native profile is a startup snapshot, not a polling loop. It uses active/online logical CPUs, process affinity where exposed, and Linux/Android cgroup CPU quota where readable. The effective core count is the tightest available limit.
- **[Fact]** Windows budgets from available physical memory. Linux/Android take the tighter of system-available memory and a finite cgroup limit minus current usage; an exhausted finite cgroup limit produces the minimum 1 MiB budget instead of being mistaken for an unavailable signal. Positive measurements are quartered, capped at 8192 MiB, and no longer rounded up to a 16 MiB floor. macOS/iOS still use half of total physical memory as a fallback, not a live available-memory reading. A zero profile field means unknown; the policy uses a one-worker fallback.
- **[Fact]** The Android host reports thermal status (Android 10+) and battery-saver changes through event-driven platform channels. Foreground/background and audio-playing transitions also refresh the active worker budget. Unsupported platforms retain an explicit `Unknown` pressure state; background/offline work reserves one core where possible and GPU work is disabled.
- **[Assumption, F7.1, 2026-11-04]** With the app's lane, point and pattern caps gone, editing cost grows with content size; very large patterns or lanes are not yet measured on a phone. Since F7.2 the Arranger's ruler and grid paint only the visible span, so a long song costs no more per frame than a short one; callgrind playback was unchanged by F7.2 (1 layer +0.04%, effects and graph within noise).
- **Verification boundary:** policy unit tests cover unknown pressure, runtime foreground/audio changes, explicit CPU/memory caps and thermal/battery levels. CI verifies Android compilation and Dart mapping; actual thermal response, battery behavior and scheduling impact still require representative physical-device tests. The actual host probe remains platform-dependent and must be validated on representative Android and desktop devices.

## App audit (2026-10-28)

### Bottlenecks, ranked by evidence

1. **Every keystroke and slider step rebuilt the whole app.** Measured with Flutter's own rebuild hook (`debugOnRebuildDirtyWidget`) in `app/test/rebuild_test.dart`, which runs the real app shell with the starter project and a .caw kick track (the keystrokes and slider steps edit its code and knobs).
   - About **3,520 widgets** rebuilt per keystroke, per param step and per volume step.
   - Every change called `notifyListeners`, which rebuilt the shell. Its `IndexedStack` builds and lays out all three screens, the Arranger with every layer card included.
   - Slider drags send 60–120 events a second.
2. **The meter poll never stopped.** It ran on a Flutter `Ticker`, and a running `Ticker` asks for a frame on every screen refresh, 120 times a second on the S22+'s display.
   - So even when stopped with nothing moving, the UI thread woke up every frame. It read the meters over FFI 30 times a second and redrew every meter and scope.
   - This is from the code and Flutter's `Ticker` behaviour. Battery wasn't measured on a device here.
3. **The audio device stayed open while stopped.** It ran a callback writing silence for as long as the app was in the foreground.
4. **Historical baseline (superseded 2026-10-31):** each project update started a worker isolate, about 1.8 ms in the test VM. Project compilation, async source checks and offline WAV renders now use the native bounded worker pool; this is no longer the current execution path. Release-device latency still needs measurement.

### Fixes

1. **Scoped updates:**
   - Typing updates the app only when a module first becomes "edited" (the text lives in the editor).
   - Param, global, volume and pan changes bump a small `values` notifier that only the controls showing those values listen to.
   - Mute, solo and other structural changes still update everything.
   - Measured after: **10 widgets per keystroke** (was ~3,520) and **169 per slider step** (was ~3,520). The test fails if these grow back past 50 and 300.
2. **`Poller`** (`app/lib/model/poller.dart`) replaces the `Ticker`:
   - about 30 reads a second only while playing, plus 1 s after stopping; the meters fall on their own clock after that
   - then no timers, no frames and no FFI calls
   - nothing at all while the app is in the background
   - Tests in `app/test/poller_test.dart` check the rate, the settle, the idle and the background.
3. **The audio device closes after 30 s stopped and idle.** Play (or resuming a pause) reopens it, as the app already did after returning from the background. **[Assumption]** Reopening takes well under a second on Android; check it on the phone.

### Native worker-pool lifecycle (2026-10-31)

- **[Fact]** The pool previously started every thread allowed by the hardware-derived capacity at construction, even when no jobs were queued. The app's initial preview policy only allowed two concurrent jobs, so the extra threads could never help that initial workload.
- **[Fact]** The pool now creates threads only as outstanding queued + running demand grows, bounded by the active execution plan and pool capacity. One job starts one worker; simultaneous jobs can grow the pool; existing workers are reused rather than creating a new thread per job.
- **[Fact]** Creating the pool and applying an execution plan no longer starts OS worker threads. With no submitted work, worker-thread count remains zero.
- **[Fact]** Created workers sleep on the pool condition variable when idle; they do not poll. After the configurable idle timeout (30 seconds by default), an idle worker exits and releases its thread resources. Its completed thread handle is joined and its slot reused before later growth; queued or active work prevents retirement.
- **[Fact]** Worker retirement is entirely outside the audio callback. The pool remains lazy at startup, grows only to outstanding demand and the active budget, and can return to zero native workers after sustained idleness.
- **Verification boundary:** scheduler tests assert zero threads before work, worker reuse, scale-up to two workers for simultaneous demand, idle retirement and restart after retirement. CI can verify lifecycle logic, but not actual phone RSS, battery or thermal behavior.

## UI update isolation
- Mixer master gain now uses a dedicated native command (`caw_engine_set_master`) with a 5 ms audio-thread ramp. Dragging the master slider no longer serializes and recompiles the entire project; the UI updates through the scoped `values` notifier. This removes project-compilation work from the master-gain gesture, but device-level latency and CPU savings have not yet been benchmarked.
- MIDI pattern import/export is still synchronous on the UI isolate before/after the system file picker. This is a known potential UI stall for larger files; it has not been benchmarked or moved to the native worker pool.


- The Arranger's 30 Hz playhead uses a dedicated overlay painter driven by the engine meter tick. It does not rebuild the clip grid, headers or track layout for every playhead update.
- Engine Lab reads a fixed 512-sample window from the existing master scope only on meter ticks; its Hann window, FFT scratch buffers and 128-bin spectrum buffer are retained between ticks. A 512-point radix-2 FFT is performed at the existing 30 Hz meter cadence; the UI does not allocate new sample buffers each frame.
- Mixer meters and Builder controls listen to the existing state notifiers rather than introducing a second audio-state polling loop.
- Peak meters (`PeakMeter` in `app/lib/ui/widgets.dart`) read on a dB scale from -60 to 0 dBFS: they rise at once to each sample peak and fall 24 dB a second on wall-clock time, with a peak line held 1.5 s and pink for 3 s at 0 dBFS or over. Each meter runs its own ticker only while it shows something, so it falls the same at any refresh rate or meter cadence, and doesn't freeze when the engine goes quiet. The engine's meters are sample peaks of what each track or folder sends on (after volume and pan, the louder channel) and of the master output. The hold and fall are presentation-only.
- These are architectural reductions in unnecessary rebuild/allocation work; no frame-time, CPU or battery benchmark has yet been captured on physical hardware.

## UI performance profiles (Task 1)

The Settings page now offers four explicit profiles:

| Profile | Presentation | Audio/UI behavior |
| --- | --- | --- |
| Full Experience | Full-strength theme glow and available visual feedback | Full voice budget; meter polling remains 30 Hz |
| Balanced | Decorative glow scaled down to 55% | Full voice budget; meter polling remains 30 Hz |
| Lightweight | Decorative glow and glass blur disabled; the glass look stays, unblurred (`lib/ui/glass.dart`) | Existing reduced voice budget (4 per pattern layer); meter polling remains 30 Hz |
| Minimal | Decorative glow and glass disabled; scope panels hidden; motion off (`lib/ui/motion.dart`) | Reduced voice budget; meter polling remains 30 Hz |

The legacy `light_mode` setting is still read for migration: true maps to Lightweight and false maps to Balanced. New settings persist `performance_mode` by name and also write the legacy boolean for older builds. Editing settings (the roll's look and value grid, the arrangement's track gap) are the same in every profile.

**Important correction:** performance profiles do not lower meter polling to 15 Hz. Meter cadence stays at 30 Hz in every profile; visual simplification is preferred over slower feedback. Balanced only scales decorative glow, while Lightweight/Minimal apply the existing smaller voice budget. Minimal hides the Engine Lab master scope, whose data is a mono sum; independent left/right peak meters remain visible.

No phone frame-time, battery or thermal measurements have been made for these profiles yet. Verify them on physical Android hardware before claiming a quantified performance improvement.

## Native instruments: First loop (2026-11-10)

The owner's measure: the whole First loop (all six tracks, Acid and Pad unmuted) ran at 25–30% CPU on their Galaxy S22+, and the target is 15–20% (owner's words in [decisions](decisions.md)). `caw_bench SECONDS 100` plays it on the built-in instruments, each track alone, and each built-in under a busy pattern (`caw_bench S 100 K` plays case K only).

**Instructions for 4 s of playback** (callgrind, millions, the setup of a 0 s run subtracted; 192-frame callbacks at 48 kHz; GCC 13 `-O3`, x86-64):

| | Before (`dcb8a78`) | Instrument speed-ups (`f2a9856`) and review fixes | Plus the engine work below |
| --- | --- | --- | --- |
| First loop, all tracks | 1,624 | 818 | 757 |
| Kick | 196 | 123 | 115 |
| Hats | 152 | 127 | 119 |
| Bass | 156 | 113 | 104 |
| Lead (Morph ×3 + ping-pong) | 337 | 194 | 183 |
| Acid (+ distortion) | 322 | 175 | 160 |
| Pad (Morph ×7 + chorus) | 657 | 286 | 273 |

- **The engine work alone, on the old instruments** (the instrument code of `1fc4122` in both trees): the First loop 1,603 → 1,518 (−5.3%); Kick 193 → 183, Hats 150 → 140, Bass 154 → 142, Lead 334 → 313, Acid 318 → 304, Pad 655 → 632. On the new instruments: 818 → 757 (−7.5%).
- **Clang 18** (the Android NDK's compiler family; Clang already defaults to no trapping maths): the First loop 1,818 → 880 → 795 (the engine work −9.7%).
- **Time** (one 10 s run each on the shared server, noisy): the First loop's mean callback 167.6 µs (4.2% of the 4 ms budget) before, 85.6 µs after the instrument speed-ups, 71.9 µs (1.8%) now.
- **On the phone [Assumption: the phone's cost scales like these instruction counts; not measured on a device]:** 25–30% becomes about 12–14% with everything, which meets the target; the engine work alone on the old instruments gives about 24–28%, which does not. Most of the cost is inside the instruments and effects (about three quarters at the end); the host's own share fell from about 240 M to 178 M instructions per 4 s.
- **What the engine work did** (bit-identical: every golden render and the block-size test unchanged):
  - The track node has a fast path for the usual case (volume settled, no lanes), and skips the mono mix a stereo native instrument does not use.
  - The mixer's saturating route maths, the output sanitizer and the meters are written as selects and integer maxima, and the engine and SDK build with `-fno-trapping-math`, so GCC vectorizes them (it changes no result).
  - Components that have fallen silent sleep (`ModuleProcessor::quiet()`; [SDK](native-module-sdk.md); a declared tail alone no longer puts one to sleep, since that made the output depend on the buffer size, so effects keep running): the kick, hats, snare, kit and acid stop running between hits. In the First loop they are rarely silent long, so it gives about 6% on Kick and Hats alone; an idle track gains most.
  - Note lists and voice pools walk only the notes and voices in use, so the larger capacities (4,096 notes, 128 voices) cost nothing per block.
- **Bigger ideas, not built** (each needs the owner or an `architect` review first):
  - Run independent tracks on the worker pool's cores (the S22+ has 8): the callback's load falls, the total CPU does not.
  - Per-component CPU in the meters, with the decided auto-bypass on overruns, so a user sees which plug-in is costly.
  - SDK helpers that make plug-ins cheap by default: block-wise vectorized Library kernels, a control-rate helper (the built-ins' 16-frame grid), and a cost-per-voice figure in `caw test-component`.
  - Tell a component how long it slept when it wakes (an extension), so timed state such as an LFO can catch up and more instruments can sleep without changing their sound.
  - Flush-to-zero on the audio thread: cheaper denormals on x86, but it changes results below the smallest normal number and differs in detail between x86 and ARM, so it needs the owner's word on determinism.

## Remaining bottlenecks and next steps

- **Measure on the phone.** Build a release APK, then:
  - play the starter project and 16 layers for 5 minutes each, with the screen on and off
  - record CPU, the audio thread's time per callback (`caw_engine_meters` already reports the load), dropouts, frame times, battery and temperature
- **Compiling, about 0.3 ms per module.** Each compile re-reads and re-checks the three built-in libraries. Caching their parsed functions would cut this to almost nothing. It only matters for auto-update while typing.
- **Per-layer setup in `prepareLane`.** `step`, `beat` and `bar` are worked out with a division for every sample of every layer. They could be counted up incrementally, but only if the results stay bit-identical at step boundaries; that needs a careful proof and the golden tests.
- **The VM's dispatch.** Fusing common operator pairs, or compiling to a tighter form, is the next big win. It's a larger change, so measure on the phone first.
- **Measure native project-job latency on the phone.** Project compilation now uses the shared native worker pool rather than starting a Dart worker isolate per update. Measure queue wait, compile duration, UI responsiveness and audio callback impact in a release build.
- **The shell's `IndexedStack`** retains all eight workspace destinations and may rebuild/layout them on structural project changes. Measure this on device before changing it; preserving editor state is a constraint.
- **Scopes** read 512 samples over FFI and redraw a path about 30 times a second while playing. That's fine on the server; check the frame time on the phone.
