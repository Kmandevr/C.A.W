---
title: Performance
summary: How C.A.W is measured for low-end devices, the audit's ranked bottlenecks with evidence, fixes with before/after numbers, and what remains.
covers: [engine/bench/]
updated: 2026-10-28
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
- **Exports:** run on their own `Engine` instance in a worker isolate, so they never touch live playback state. They compete for CPU only, and the audio thread has the higher priority on Android.
  - **[Assumption]** That priority holds for AAudio's callback thread. Check it on the device under a long export.
- **Live code edits:**
  - A swap compiles on the control thread, about 0.4–0.5 ms for 16 layers.
  - For 20 ms the audio thread runs both the old and the new code to crossfade.
  - Carrying state over copies at most 2 MB per swap.
- **Memory:**
  - Layer state is allocated when a chain is built, never in the callback.
  - Big effect buffers are cleared lazily ([engine](engine.md#built-ins-and-libraries)).
  - The project memory budget is 64 MB.

## Remaining bottlenecks and next steps

- **Measure on the phone.** Build a release APK, then:
  - play the starter project and 16 layers for 5 minutes each, with the screen on and off
  - record CPU, the audio thread's time per callback (`caw_engine_meters` already reports the load), dropouts, frame times, battery and temperature
- **Compiling, about 0.3 ms per module.** Each compile re-reads and re-checks the three built-in libraries. Caching their parsed functions would cut this to almost nothing. It only matters for auto-update while typing.
- **Per-layer setup in `runChain`.** `step`, `beat` and `bar` are worked out with a division for every sample of every layer. They could be counted up incrementally, but only if the results stay bit-identical at step boundaries; that needs a careful proof and the golden tests.
- **The VM's dispatch.** Fusing common operator pairs, or compiling to a tighter form, is the next big win. It's a larger change, so measure on the phone first.
- **The app** is audited next: meter and scope polling, rebuilds and the ticker that runs while stopped.
