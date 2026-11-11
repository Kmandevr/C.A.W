---
title: Performance
summary: How C.A.W is measured for low-end devices, the audit's ranked bottlenecks with evidence, fixes with before/after numbers, and what remains.
covers: [engine/bench/, app/lib/model/poller.dart, app/lib/model/settings.dart, app/lib/ui/motion.dart, app/test/poller_test.dart, app/test/rebuild_test.dart, app/test/perf_*]
updated: 2026-11-11
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
- **MIDI files:** a `.mid` import is read and converted on another isolate (the Dart converter, `lib/ui/midi_file_actions.dart`); exports are built in Dart, and the engine's MIDI 2.0 clip converter runs in `Isolate.run`.
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
- **[Fact]** Windows budgets from available physical memory. Linux/Android take the tighter of system-available memory (`MemAvailable` in `/proc/meminfo`, not free pages: Android keeps those low, and First loop, which charges 16–32 MiB of project state, was refused on a phone, 2026-11-11) and a finite cgroup limit minus current usage; an exhausted finite cgroup limit produces the minimum 1 MiB budget instead of being mistaken for an unavailable signal. Positive measurements are quartered, capped at 8192 MiB, and no longer rounded up to a 16 MiB floor. macOS/iOS still use half of total physical memory as a fallback, not a live available-memory reading. A zero profile field means unknown; the policy uses a one-worker fallback.
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


- The Arranger's 30 Hz playhead uses a dedicated overlay painter driven by the engine meter tick. It does not rebuild the clip grid, headers or track layout for every playhead update.
- Engine Lab reads a fixed 512-sample window from the existing master scope only on meter ticks; its Hann window, FFT scratch buffers and 128-bin spectrum buffer are retained between ticks. A 512-point radix-2 FFT is performed at the existing 30 Hz meter cadence; the UI does not allocate new sample buffers each frame.
- Mixer meters and Builder controls listen to the existing state notifiers rather than introducing a second audio-state polling loop.
- Peak meters (`PeakMeter` in `app/lib/ui/widgets.dart`) read on a dB scale from -60 to 0 dBFS: they rise at once to each sample peak and fall on wall-clock time at the **Meter fall** setting (Settings → Look: Slow 48, Medium 96, Fast 144 or Very fast 192 dB a second; Medium by default, `meter_fall`; owner, 2026-11-10: faster than the old 24, REAPER-like, and the earlier "Very fast" 96 is the right medium), with a peak line held 1.5 s and pink for 3 s at 0 dBFS or over. Given a right channel, a meter is stereo: two thin bars (side by side when upright); the master meters are stereo, a track's or folder's is one bar because the engine reports one peak per track (`caw_layer_meter`). Each meter runs its own ticker only while it shows something, so it falls the same at any refresh rate or meter cadence, and doesn't freeze when the engine goes quiet. The engine's meters are sample peaks of what each track or folder sends on (after volume and pan, the louder channel) and of the master output. The hold and fall are presentation-only.
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
  - A note list is 360 KB per instrument track (1,024 held notes, 4,096 events a block): 4,096 notes and 16,384 events took 1.5 MB, about 94 MB at 64 tracks (second audio review, 2026-11-10).
  - Note lists and voice pools walk only the notes and voices in use, so the larger capacities (1,024 notes, 128 voices) cost nothing per block.
- **Bigger ideas, not built** (each needs the owner or an `architect` review first):
  - Run independent tracks on the worker pool's cores (the S22+ has 8): the callback's load falls, the total CPU does not.
  - Per-component CPU in the meters, with the decided auto-bypass on overruns, so a user sees which plug-in is costly.
  - SDK helpers that make plug-ins cheap by default: block-wise vectorized Library kernels, a control-rate helper (the built-ins' 16-frame grid), and a cost-per-voice figure in `caw test-component`.
  - Tell a component how long it slept when it wakes (an extension), so timed state such as an LFO can catch up and more instruments can sleep without changing their sound.
  - Flush-to-zero on the audio thread: cheaper denormals on x86, but it changes results below the smallest normal number and differs in detail between x86 and ARM, so it needs the owner's word on determinism.

## Flagship synth (2026-11-10)

The flagship (#171, [engine](engine.md)) is built for the phone budget: everything but audio runs every 16 frames (and only for what moved or what a mod slot listens to), knobs that hold still over a block are read once per block, only sounding voices, oscillators, filters and effects run, and it says it is quiet when nothing sounds. `caw_bench SECONDS 200` times it with 8 notes held (straight through the instrument, best of 3); `caw_bench S 100 K` with K 21..26 plays it under the busy pattern.

**Held notes** (10 s, x86-64 server, GCC 13 `-O3`, microseconds of CPU per second of audio; 10,000 = 1 % of a core; one run on a shared machine):

| Part | Cost |
| --- | --- |
| A voice (one copy, no filter: envelope, control work, amp) | 520 |
| Each further unison copy, per voice | 140–155 |
| Filter: a ladder (stereo pair) per voice | 950 |
| Filter: an SVF (stereo pair) per voice | 490 |
| A mod slot (an LFO on a knob), per voice | 85 |
| The reverb (one per instrument) | 4,800 |
| The default patch (seven copies, ladder, env 2 on the cutoff), per voice | 2,540 |

- So 8 voices of the default patch take about 2 % of one server core, a 16-copy voice about 0.3 %. The Morph synth's busy pattern (seven copies, a shared filter) costs 59 M instructions a second of audio, the flagship's default 158 M (callgrind, the instrument alone); a voice of seven copies without a filter about the same as Morph's.
- [Assumption] On the owner's Galaxy S22+ these scale like the instruction counts (not measured on the phone).
- The ladder is a long chain of dependent operations per sample; running a voice's two sides in one loop let the CPU overlap them (1.7× faster), and voices could be interleaved the same way next. The reverb (the Library's, unchanged) is why the flagship's starts off.

## Effects suite (2026-11-10)

`caw_bench SECONDS 300` times each built-in effect (#173, [engine](engine.md)) alone on a busy stereo signal that never falls silent (so nothing sleeps), in the engine's 64-frame chain blocks, best of 3 runs. Microseconds of CPU per second of stereo audio (10,000 = 1 % of one core); 3 s runs on a shared x86-64 server (Intel Xeon 2.3 GHz, GCC 13 `-O3`), so ±30 % noise between runs (the existing chorus read 489 and 735 in two runs).

| Effect | Cost |
| --- | --- |
| EQ, default (bands at 0 dB are skipped) | 780–840 |
| EQ, 8 bands with gain, two 48 dB cuts | 8,000–9,200 |
| Compressor, default (peak, linked) | 2,300–3,100 |
| Compressor, RMS, unlinked, sidechain high-pass | 3,500–4,600 |
| Limiter, true peak / sample peak | 2,800–3,000 / 1,600–2,300 |
| Reverb, default (modulated) / no modulation | 6,700–8,300 / 5,450–5,600 |
| Delay, default / ping-pong with ducking | 3,700–4,500 / 4,900–6,300 |
| Saturator, default (tape, 2×) / no oversampling | 6,100–8,600 / 2,200–3,700 |
| Gate | 1,800 |
| Transient shaper | 2,200–2,400 |
| Filter, 24 dB SVF / ladder with LFO and envelope | 1,200–2,300 / 1,900–3,100 |
| Phaser, 6 / 12 stages | 2,100–2,700 / 3,300–4,400 |
| Flanger | 1,400–2,100 |
| Utility (bass mono, DC block, width) | 870–1,400 |
| For scale: the chorus, the ping-pong delay | 490–735, 1,270–1,490 |

- So a full mastering chain (EQ, compressor, saturator, limiter) costs about 2 % of one server core; [Assumption] the phone scales like these numbers (not measured on a device).
- The EQ's display spectrum (one 2048-point FFT per publish, about 60 a second) runs only while a UI reads (`DisplayBuffer::watched`), so it costs nothing in an export or with the editor closed.
- Found while timing: the gate cost 18,000 because its dB envelope settled on a steady target through subnormal numbers; the followers now land on a steady target (1,800).
- Next, if it matters: the EQ runs its bands sample by sample with a branch per band; a block loop per band (or stereo pairs interleaved, as the flagship's ladder) would cut the many-band case.

## One synth (2026-11-10)

The owner's measure after the evening round (#174): the basic project at 35–40 % CPU on the S22+. The bass, acid, morph and basic synths became Flagship presets ([engine](engine.md)); then two passes to make Flagship and the host cheaper, the second with the target of every preset at or below the synth it replaced and the whole First loop below the retired synths' 173 M, without an audible change. `caw_bench 1 100 K` under callgrind (`--toggle-collect='caw::Engine::process(float*, float*, int)'`: the audio path only, setup excluded), **millions of instructions per second of audio**, GCC 13 `-O3`, x86-64; columns: before the change (`a6e5374`, the retired synths), the presets before the passes, after the first pass (`426a0e5`) and after the second (`8c12953`, branch `flagship-perf`):

| | Retired synths | Presets, before | First pass | Second pass | Eco quality |
| --- | --- | --- | --- | --- | --- |
| First loop (6 tracks, all unmuted) | 173.0 | 381.7 | 276.4 | 172.3 | 164.4 |
| Kick | 27.9 | 28.1 | 27.6 | 27.6 | |
| Hats | 28.9 | 28.9 | 28.5 | 28.5 | |
| Bass (Mono bass) | 25.2 | 65.0 | 42.5 | 26.6 | |
| Lead (Morph pad ×3 + ping-pong) | 42.1 | 92.2 | 65.7 | 42.2 | 42.2 |
| Acid (Acid 303 + distortion) | 38.8 | 79.7 | 57.8 | 34.6 | |
| Pad (Morph pad ×7 + chorus) | 55.6 | 133.4 | 99.7 | 58.2 | 50.3 |
| An idle instrument track | 14.2 | 14.2 | 13.7 | 13.7 | |
| Busy Flagship default (×7, ladder, reverb) | 189.3 | 191.7 | 149.9 | 114.6 | |
| Busy Flagship ×1, no filter, no effects | 83.6 | 85.9 | 52.1 | 44.3 | |
| Busy Flagship ×16, no filter, no effects | 222.4 | 224.7 | 173.4 | 104.0 | |
| Busy Flagship 3 oscillators ×16, 2 filters, all effects | 771.3 | 774.5 | 648.9 | 374.5 | |

The instrument alone (callgrind's inclusive count of `processPorts`, so without the track, the mixer and the effects after it), retired synth → before the second pass → after: Bass 10.2 → 26.3 → 12.3, Lead 16.2 → 39.1 → 19.8, Acid 13.1 → 31.2 → 16.9, Pad 32.2 → 75.5 → 36.5. So the presets still cost 13–27 % more than the synths they replaced (Flagship's mod matrix, three oscillators and two filters, and a wavetable read where the Morph synth worked out its shapes in vectorized float); the tracks come out at or near the old ones because the second pass also made the distortion, chorus and ping-pong effects cheaper, which the retired synths' tracks would have gained too. Clang 18 (the Android NDK's compiler), the same counts on x86-64, retired → after the second pass: First loop 180.6 → 181.3, Bass 24.9 → 25.1, Lead 43.7 → 44.5, Acid 40.8 → 33.2, Pad 56.8 → 65.3 (Clang makes slower code of the oscillator than GCC; the table-read pass is written per compiler for this). `-O3` against `-O2`: Clang `-O2` costs about 3 % more, GCC `-O2` 36 % more; LTO gained nothing (the hot loops sit inside one file). [Assumption] the Android build's optimisation level is the NDK toolchain's default for the build type the Android Gradle plugin picks; not checked here.

**Flagship, 8 held notes** (`caw_bench 3 200`, µs of CPU per second of audio, shared server, noisy), before the passes → first → second: a voice 519 → 292 → 234; a unison copy 141 → 66 → 37; an SVF pair 523 → 197 → 46 (the held notes now share one filter); a ladder pair 951 → 909 → 879; a slot per voice 127 → 156 → 61; the default patch per voice 2,522 → 1,786 → 1,535. The effects (`caw_bench 3 300`) were not changed and measure as before.

- **What the one synth costs:** see the instrument-alone figures above. **[Assumption: the phone scales like these counts; not measured on a device]** on the owner's numbers the engine's audio work is a few % of the device's CPU: the callback's measured load is about 1.6 % of one server core for the whole First loop (`caw_bench 3 100 0`), so the 35–40 % the owner sees is mostly not the audio engine (the app's UI, meters and redraws are the next thing to measure on the phone).
- **The first pass** (all bit-identical but the oscillator phase): a component chain keeps last block's parameter values while nothing changed (First loop −18 %); the unwarped oscillator reads its table with a 32-bit fixed-point phase; a control works out again only the voice sections a knob or a slot moved; an SVF pair shares one tan; a centred voice (every copy in the middle) filters one side for both; the dry output in one vectorizable loop.
- **The second pass** (each measured alone and kept only if it won; bit-identical unless marked):
  - Off costs nothing: a Play no longer clears the 4 s delay line and the reverb (1.5 MB) of an instrument that never used them, nor rewrites all 64 voices (8 KB each; `VoicePool::clear` clears only the voices started since the last clear).
  - An unchanged block's knobs are not read again (a memcmp against the last block's), and the mod matrix, the free LFOs' rates and the effects' settings are worked out only when a knob, the tempo or the quality moved.
  - A voice section is worked out again only when a value a slot moves actually changed (a timbre slot at rest no longer re-runs the filter); a filter follows the pitch only through its key tracking; a frame sweep only re-points the frames; a glide only retunes the copies. A voice advances only the LFOs that are its own.
  - The unwarped copy in three passes: indices and fractions (vectorized), the table reads as 8-byte pairs (a gather: scalar), the interpolation, morph and mix (vectorized; NEON `ld2` on Arm64): 36 → 21 instructions per copy and sample.
  - An SVF pair as one two-wide double vector (GCC and Clang vector extensions, SSE2 or NEON; MSVC scalar), and the drive saturator two samples at a time the same way (`Saturator::process2`, used by Flagship's distortion and the distortion effect). A side identical to the other (a centred instrument) is driven once; silence passes the distortion without a tanh; the distortion alone runs in place before the vectorized dry loops; the output peak is an integer max of the bits (a float max does not vectorize without fast-math).
  - **Changed bits, perceptually the same:** poly voices whose filter 1 is set alike (a linear SVF without drive, no slot moving it for that voice, no key tracking, filter 2 off) share one filter with their level before it, as the Morph synth did; a voice whose filter is moved apart keeps its own to the note's end, which by linearity sums to the same signal (a test checks it doesn't click). The oscillator phases move on in 32-bit fixed point (the step rounded to 2^-32 of a cycle: under 0.001 cent). Measured on the perceptual references: levels within 0.001 dB, every band within 0.01 dB, bands 60 dB down within 0.3 dB; goldens re-recorded for flagship, bass, acid, morph and the Basic preset; `the_presets_sound_like_the_synths_they_replace` passes unchanged.
  - The chorus and ping-pong effects read their knobs once per block while none ramps; the distortion effect's Drive too.
  - Tried and dropped (no gain or a loss): an envelope filled per block while held at sustain, a fully unrolled 16-frame oscillator (GCC unrolls it before vectorizing), the gather unrolled by two, `-O2`, LTO.
- **SIMD:** the per-sample loops are written for the compiler to vectorize (fixed or small trip counts, no calls, selects): the oscillator's index and interpolation passes, the dry output, the voice sums, the mixer and meters; explicit two-wide double vectors for the SVF pair and the saturator. Checked for Arm64 with Clang 18 (`--target=aarch64`, `-Rpass=loop-vectorize`: the oscillator's first and third passes vectorize four wide) and by building the engine with GCC 13 for aarch64 and running `caw_tests` under qemu-user: every DSP and golden test passes there with the same hashes (the native-component loading test needs CTest's environment and was not run). The table reads stay scalar (NEON has no gather). No SIMD library was added.
- **Multi-core: not built.** The First loop's audio work is about 280 M instructions a second, about 375,000 per 64-frame chunk (the engine's step), split over six tracks of 30,000–130,000. Handing tracks to worker threads needs a wake-up and a barrier per chunk, 750 a second per worker; on Android a futex wake and the barrier's return take [Assumption, typical figures, not measured here] 5–20 µs, about what a whole track's chunk costs, and spinning instead keeps big cores awake, which costs battery. It would cut the callback's time on heavy projects (16+ busy tracks), not the CPU used; so it waits for a phone measurement showing the callback near its budget, and would be gated on the chunk's measured cost (more than about 200 µs) and on there being at least four heavy tracks.
- **The phone's hardware:** the device is opened with miniaudio's low-latency profile, which asks AAudio for its low-latency (MMAP) path ([engine](engine.md), the device buffer); the new buffer setting's Auto mode opens a 1024-frame buffer while not recording (about 47 callbacks a second instead of 250–500), and Battery also leaves the fast path. Flush-to-zero stays off (the owner has not decided; the kernels keep their own denormal guards).
- **Quality:** Eco caps unison at 4 copies, turns the saturator's oversampling off and thins the reverbs: the Pad −14 %, the First loop −5 % (the Lead has 3 copies, below the cap).

## App performance pass (2026-11-10)

The owner's evening round (#174): "optimize everything". Each hot path has a benchmark test that counts work (`app/test/perf_*_test.dart`, run with `flutter test`; the live-drag one needs `CAW_LIB`); they print `BENCH` lines, and the device editors' frame counts are asserted so they can't grow back. The project is the First loop grown to 16 tracks with 8 clips each, 64-note patterns, an effect and a volume lane per track (`test/perf_fixture.dart`). Numbers are from the Flutter test VM (JIT, debug asserts) on the cloud server, so compare before and after; [Assumption] release AOT on the S22+ is faster in absolute terms and keeps the ratios. Frame and meter work is in [app](app.md) (Frame performance, `test/frame_bench_test.dart`).

| Hot path | Before | After |
| --- | --- | --- |
| Piano-roll drag heard live, UI isolate per 30 Hz step (`perf_model_bench_test`) | 458 µs (the whole project JSON rebuilt) | 12–17 µs (spliced into a cached JSON) |
| The same step's round trip through the engine (`perf_live_bench_test`) | 3.0 ms | 1.8–2.2 ms |
| Project encodes per burst of edits (autosave + undo snapshot) | 825 µs indented + 564 µs compact | 564 µs, once |
| Device editor open, stopped, with full motion (ping-pong delay, frames asked for in one second at 120 Hz, `perf_device_bench_test`) | 119 | 30 |
| The same, playing (display data at 30 Hz) | 120 | 60 |
| Arranger sideways scroll, render objects painted in 30 frames (`perf_arrange_bench_test`) | 5,280 | 750 |
| Arranger vertical scroll, the same | 48,240 | 0 (the layers move) |
| Arranger pinch zoom, widgets rebuilt in 30 frames | 126,690 | 76,620 (the headers kept) |
| Startup project list, 20 saved projects of about 0.4 MB (`perf_startup_bench_test`) | 110 ms, UI isolate blocked 73.5 ms, longest stall 10.6 ms | 77 ms, blocked 11.6 ms, longest 4.4 ms |
| C++ completion per keystroke, 5,000-line file (`perf_cpp_bench_test`) | 5.5 ms | 2.2 ms |

- **What changed:**
  - `AppState.liveEngineJson` builds the engine JSON once around a marker and splices each step's text in; any save, sync, settings change or value tick (a knob moved live) drops the cache, and a test checks it against a full build after live knob and volume moves.
  - Autosave writes compact JSON and the undo step settled 100 ms later reuses that text; opening a project, a restore point and the project list decode in `Isolate.run` (the decoded map comes back without a copy).
  - `MotionClock` (device motion) asks for one frame per 33 ms step and reads the frame's time, instead of a Ticker that asked for every refresh; it stops in the background and in sleeping sections (`TickerMode`). Device display polls skip their FFI read in the background.
  - Repaint boundaries in the arranger (tracks, timeline viewport, lanes, grid, ruler); a zoom rebuilds the lanes and keeps the headers (`_headersRev`).
  - `FileWords` (C++ completion) counts the file's words once and re-reads only an edit's span, widened to whole words; a randomized test checks it against a full scan. List ties sort by name.
  - Memory: undo history holds at most 48 M characters of snapshots (a project with large component states held up to a hundred copies of them).
- **Measured and left as they are:**
  - A knob step in a device editor rebuilds the whole editor page (EQ about 450 widgets a step, the flagship about 1,100): every control and visual reads the values. Narrowing it means controls listening to their own values; not done.
  - The pinch zoom still lays out and paints every clip each frame (about 4,200 render objects). Scaling the painted lanes during the pinch and laying out once at the end would remove most of it.
  - The ping-pong and phaser editors' motion steps out of phase with display frames while playing (60 frames a second, not 30).
  - Each native job's wait spawns an `Isolate.run` (about 0.3 ms in the test VM); a project sync or live step pays it once.

### Release build

- **[Fact]** R8 is on for release: Flutter's Gradle plugin sets `isMinifyEnabled` and `isShrinkResources` on the release build type with its ProGuard rules (FlutterPlugin.kt in the Flutter SDK's Gradle plugin, Flutter 3.47.7, checked 2026-11-10); the APK's `classes.dex` is 0.59 MB.
- **[Fact]** Impeller is the Android renderer: "available and enabled by default on Android API 29+", with a fallback to OpenGL on older or non-Vulkan devices (docs.flutter.dev/perf/impeller, read 2026-11-10); the engine at Flutter 3.47.7 defaults `enable_impeller = true` on Android (common/settings.h in the Flutter SDK's engine sources), and the manifest has no `EnableImpeller` opt-out. **[Assumption]** The S22+ (Android 12 or later, a Vulkan GPU) runs Impeller on Vulkan.
- **`--split-debug-info`** (CI's `flutter build apk`): `libapp.so` for arm64, AOT-compiled from this branch with Flutter 3.47.7's `gen_snapshot` and stripped as AGP strips it: 10.22 MB → 8.85 MB (gzip 4.17 → 3.44 MB, so the APK is about 0.73 MB smaller: the last CI APK was 55.5 MB, of which `libapp.so` 3.97 MB compressed). It is safe with FFI (native symbols are looked up by name strings; only Dart stack-trace tables move out). Release stack traces become addresses: CI keeps `caw-android-symbols`, and the problem log keeps the trace's header that `flutter symbolize` needs.
- **No `--obfuscate`:** 0.13 MB more, and type names in the app's own error texts (shown to the user and in problem reports) would be garbled.
- Signing is unchanged. The APK's size after these changes is measured when CI builds this branch.

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
