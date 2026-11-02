---
title: Performance
summary: How C.A.W is measured for low-end devices, the audit's ranked bottlenecks with evidence, fixes with before/after numbers, and what remains.
covers: [engine/, app/]
updated: 2026-11-02
---

# Performance

The owner's requirement (2026-10-28): run as light as possible, down to low-end phones ([UI design](ui.md#light-on-cpu-and-ram)). This note records how performance is measured and what the audit found.

## How it's measured

- **`caw_bench`** (`engine/bench/caw_bench.cpp`, built with the engine tools) plays scenarios through `Engine::process` in 192-frame callbacks at 48 kHz, a common Android low-latency burst. The budget is 4,000 µs per callback. For each scenario it reports:
  - the mean, p99 and maximum time per callback, and the load (mean time ÷ budget)
  - the time `setProject` takes
  - the compile time per template, the time to re-send an unchanged project, the speed of a loop export, and memory (RSS)
- **Instruction counts** are the reliable before/after numbers: `valgrind --tool=callgrind ./caw_bench 2 N` runs scenario N for 2 s. Timings on a shared cloud server vary by ±30% from run to run, and instruction counts don't vary at all.
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
3. **The per-chain setup in `runChain`:** about 7–9%. It works out `step`, `beat`, `bar`, `pos` and `t` for every sample of every layer.
4. **Filter and envelope maths:** `detTan` 4–5%, `ad` 4–6%, `detExp` 2–3%. This is mostly modulated filter cutoffs. It's the sound itself, and it must stay bit-exact for determinism.
5. **`slotTarget`:** 1.5%, growing with the square of the layer count. Every layer, every block, it scanned all 64 slots to see whether anything was soloed.

### Fixes (all bit-identical: golden hashes unchanged)

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
- **Verification boundary:** policy unit tests cover unknown pressure, runtime foreground/audio changes, explicit CPU/memory caps and thermal/battery levels. CI verifies Android compilation and Dart mapping; actual thermal response, battery behavior and scheduling impact still require representative physical-device tests. The actual host probe remains platform-dependent and must be validated on representative Android and desktop devices.

## App audit (2026-10-28)

### Bottlenecks, ranked by evidence

1. **Every keystroke and slider step rebuilt the whole app.** Measured with Flutter's own rebuild hook (`debugOnRebuildDirtyWidget`) in `app/test/rebuild_test.dart`, which runs the real app shell with the starter project.
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
   - about 30 reads a second only while playing, plus 1 s after stopping so meters fall to zero
   - then no timers, no frames and no FFI calls
   - nothing at all while the app is in the background
   - Tests in `app/test/poller_test.dart` check the rate, the settle, the idle and the background.
3. **The audio device closes after 30 s stopped and idle.** Play reopens it, as the app already did after returning from the background. **[Assumption]** Reopening takes well under a second on Android; check it on the phone.

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
- Peak meters attack immediately, hold the recent peak for 12 meter ticks (about 400 ms), then decay smoothly. The hold/release is presentation-only and never changes the engine's peak samples.
- These are architectural reductions in unnecessary rebuild/allocation work; no frame-time, CPU or battery benchmark has yet been captured on physical hardware.

## UI performance profiles (Task 1)

The Settings page now offers four explicit profiles:

| Profile | Presentation | Audio/UI behavior |
| --- | --- | --- |
| Full Experience | Full-strength theme glow and available visual feedback | Full voice budget; meter polling remains 30 Hz |
| Balanced | Decorative glow scaled down to 55% | Full voice budget; meter polling remains 30 Hz |
| Lightweight | Decorative glow disabled | Existing reduced voice budget (4 per pattern layer); meter polling remains 30 Hz |
| Minimal | Decorative glow disabled; scope panels hidden | Reduced voice budget; meter polling remains 30 Hz |

The legacy `light_mode` setting is still read for migration: true maps to Lightweight and false maps to Balanced. New settings persist `performance_mode` by name and also write the legacy boolean for older builds.

**Important correction:** performance profiles do not lower meter polling to 15 Hz. Meter cadence stays at 30 Hz in every profile; visual simplification is preferred over slower feedback. Balanced only scales decorative glow, while Lightweight/Minimal apply the existing smaller voice budget. Minimal hides the Engine Lab master scope, whose data is a mono sum; independent left/right peak meters remain visible.

No phone frame-time, battery or thermal measurements have been made for these profiles yet. Verify them on physical Android hardware before claiming a quantified performance improvement.

## Remaining bottlenecks and next steps

- **Measure on the phone.** Build a release APK, then:
  - play the starter project and 16 layers for 5 minutes each, with the screen on and off
  - record CPU, the audio thread's time per callback (`caw_engine_meters` already reports the load), dropouts, frame times, battery and temperature
- **Compiling, about 0.3 ms per module.** Each compile re-reads and re-checks the three built-in libraries. Caching their parsed functions would cut this to almost nothing. It only matters for auto-update while typing.
- **Per-layer setup in `runChain`.** `step`, `beat` and `bar` are worked out with a division for every sample of every layer. They could be counted up incrementally, but only if the results stay bit-identical at step boundaries; that needs a careful proof and the golden tests.
- **The VM's dispatch.** Fusing common operator pairs, or compiling to a tighter form, is the next big win. It's a larger change, so measure on the phone first.
- **Measure native project-job latency on the phone.** Project compilation now uses the shared native worker pool rather than starting a Dart worker isolate per update. Measure queue wait, compile duration, UI responsiveness and audio callback impact in a release build.
- **The shell's `IndexedStack`** retains all eight workspace destinations and may rebuild/layout them on structural project changes. Measure this on device before changing it; preserving editor state is a constraint.
- **Scopes** read 512 samples over FFI and redraw a path about 30 times a second while playing. That's fine on the server; check the frame time on the phone.
