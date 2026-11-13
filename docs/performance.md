---
title: Performance
summary: How C.A.W is measured for low-end devices, the audit's ranked bottlenecks with evidence, fixes with before/after numbers, and what remains.
covers: [engine/bench/, engine/src/meters.cpp, app/lib/model/poller.dart, app/lib/model/settings.dart, app/lib/ui/motion.dart, app/lib/ui/devices/kit/param_watch.dart, app/lib/ui/devices/kit/repaint.dart, app/test/poller_test.dart, app/test/rebuild_test.dart, app/test/perf_*, app/test/music_video_profile_test.dart]
updated: 2026-11-12
---

# Performance

The owner's requirement (2026-10-28): run as light as possible, down to low-end phones ([UI design](ui.md#light-on-cpu-and-ram)). This note records how performance is measured and what the audit found. The first native runtime slice now processes zero-parameter stereo effects on the live master path. The host uses fixed preallocated stereo stages, performs no host allocation/locking in the callback, sanitizes component output and keeps the safety limiter after native code; old chains are reclaimed off-thread. This path has not yet been benchmarked on low-end Android, and plugin-internal allocations/CPU remain the component author's responsibility and are not yet reported by ABI v1.

## How it's measured

**Callback cost at large layer counts (#133, open):** several per-callback loops (`applyCommands`, `planChunk`, `updateSolo`) still run over the whole layer capacity, which never shrinks, so a project that grew to many layers keeps paying for them after it shrinks. Bounding them to the active slots needs callgrind before and after.

**Native component measurement still required:** add a `caw_bench` scenario that runs a trusted test component in `ProjectDoc.masterComponents`, then record mean/p99/max callback time, component-chain count scaling, project-state memory and retained memory after clearing/unloading the chain. The two preallocated stereo scratch stages live inside MasterChain and are included in the project-state estimate, so projects without native effects do not pay their baseline memory cost. ABI v1 does not report plugin-private heap/state size, so that portion is currently unknown rather than silently treated as zero.

- **`caw_bench`** (`engine/bench/caw_bench.cpp`, built with the engine tools) plays scenarios through `Engine::process` in 192-frame callbacks at 48 kHz, a common Android low-latency burst. The budget is 4,000 µs per callback. For each scenario it reports:
  - the mean, p99 and maximum time per callback, and the load (mean time ÷ budget)
  - the time `setProject` takes
  - the cost of a pattern edit every 0.25 s while 16 tracks play, the time to re-send an unchanged project, the speed of a loop export, and memory (RSS)
- **The CI suite** (`caw_bench SECONDS 500`, 256-frame callbacks, repeated runs, JSON and markdown output) and its per-target baseline are in [engine performance](engine-performance.md); the Bench workflow runs it.
- **Instruction counts** are the reliable before/after numbers: `valgrind --tool=callgrind ./caw_bench 2 N` runs scenario N (1-5: one track, First loop, 16 and 64 tracks, First loop with a delay and a reverb on each track) for 2 s; `caw_bench S 100 K` plays only First loop's case K (0 is the whole song; the rest each track and each built-in alone). Timings on a shared cloud server vary by ±30% from run to run, and instruction counts don't vary at all.
- **Song scenarios** (`caw_bench SECONDS 400 K`, timed; `caw_bench SECONDS 401 K`, profiled): K 0 First loop with every track unmuted, 1 a typical 8-track song, 2 the song with per-note FX, an audio clip and a sampler, 3 the owner's three-track project ([below](#song-scenarios-2026-11-11)). The profile mode plays K in 256-frame callbacks after a second's warm-up and prints each component's time per callback, summed by component id (`CAW_BENCH_EACH=1`: each instance), its share, how often it ran, and the host's own share (everything `Engine::process` does outside components). It times through `ChainProfile` (`engine/src/component_chain.h`), a benchmark-only hook that costs one relaxed load per chain per block when off. `cg.sh`-style callgrind runs (`--toggle-collect='caw::Engine::process(float*, float*, int)'`, `caw_bench 1 400 K`) give the exact counts below.
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

## Engine without the language (2026-11-11, #160)

The .caw VM, whose costs the 2026-10-28 engine audit measured (integer conversion, dispatch, per-lane setup), is gone: a track is its instrument and inserts, run as one mix-graph node (two graph nodes per slot instead of 34).

- **[Fact, callgrind 3.22, x86-64 Release, 2026-11-11]** `caw_bench 1 100 K` (one second of playback, instructions inside `Engine::process`), before and after the collapse: First loop (K 0) 260.5 M → 257.8 M; Kick alone (1) 100.6 M → 100.0 M; an idle instrument track (7) 55.3 M → 54.7 M; a busy kick (8) 103.6 M → 103.1 M; a busy bass (12) 66.5 M → 65.9 M; Morph and chorus (18) 93.8 M → 93.3 M. The built-ins' own DSP is nearly all of it; the engine's share fell by about 0.6 M a second per track.
- **[Fact, 2026-11-11]** The mix graph holds two nodes per slot, so `maxLayers()` (the layers a memory budget allows) is now 1,038 at 128 MiB, 3,634 at 1 GiB and 7,716 at 4 GiB.

### Checked and fine

- **Stopped:** the callback just writes silence; costs about 0 µs.
- **Offline WAV exports:** run on their own `Engine` instance through the native bounded worker pool, so they never touch live playback state. They compete for CPU only.
- **Chain changes:** a new instrument or effect list is built and activated on the control thread; for 20 ms the audio thread runs the old and the new one to crossfade.
- **Memory:** component state is allocated when a chain is built, never in the callback; each instrument also holds a note list of about 370 KB.

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
   - The screen's own rate is now the Frame rate setting's (2026-11-12; [app](app.md), Frame rate): Auto drops the display to its lowest rate after 1 s with no frame drawn, so a still screen also costs fewer refreshes where the system allows it. Saving settings (like any app file) goes through one queued write per path (`lib/model/atomic_file.dart`), off the UI's frame work.
3. **The audio device stayed open while stopped.** It ran a callback writing silence for as long as the app was in the foreground.
4. **Historical baseline (superseded 2026-10-31):** each project update started a worker isolate, about 1.8 ms in the test VM. Project updates and offline WAV renders now use the native bounded worker pool; this is no longer the current execution path. Release-device latency still needs measurement.

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


- The Arranger's playhead uses a dedicated overlay painter, redrawn on every frame while playing from the reads' extrapolation (`PlayheadClock`, `PlayheadFrames`; [app](app.md), Frame rate). It does not rebuild the clip grid, headers or track layout for any playhead update.
- Engine Lab reads a fixed 512-sample window from the existing master scope only on meter ticks; its Hann window, FFT scratch buffers and 128-bin spectrum buffer are retained between ticks. A 512-point radix-2 FFT is performed at the existing 30 Hz meter cadence; the UI does not allocate new sample buffers each frame.
- Mixer meters and Builder controls listen to the existing state notifiers rather than introducing a second audio-state polling loop.
- Peak meters (`PeakMeter` in `app/lib/ui/widgets.dart`) read on a dB scale from -60 to 0 dBFS: they rise over 15 ms to each sample peak and fall on wall-clock time at the **Meter fall** setting, never below a line between the last two reads (so a steady tone holds still at any frame rate; [app](app.md), Meters between reads; the rise at once on each read made a 30 Hz sawtooth at 120 Hz, owner's bug of 2026-11-12) (Settings → Look: Slow 48, Medium 96, Fast 144 or Very fast 192 dB a second; Medium by default, `meter_fall`; owner, 2026-11-10: faster than the old 24, REAPER-like, and the earlier "Very fast" 96 is the right medium), with a peak line held 1.5 s and pink for 3 s at 0 dBFS or over. Given a right channel, a meter is stereo: two thin bars (side by side when upright); the master meters are stereo, a track's or folder's is one bar because the engine reports one peak per track (`caw_layer_meter`). Each meter runs its own ticker only while a bar or its peak line moves (a timer for a hold or clip light to end), built again only when it would move a 500th of its height, so it moves the same at any refresh rate or meter cadence, asks for no frames once settled, and doesn't freeze when the engine goes quiet. The engine's meters are sample peaks of what each track or folder sends on (after volume and pan, the louder channel) and of the master output. The hold and fall are presentation-only.
- A light/dark Mode switch (or the system's change under Follow system) swaps the palette with one remount of the screens (`Settings.lookRevision`, as a theme change does) and no Material theme remade beyond the one switch: each theme keeps one object per mode (`CawTheme.shown`), and `main.dart` remakes the `ThemeData` only when that object changes (`test/theme_modes_test.dart`).
- These are architectural reductions in unnecessary rebuild/allocation work; no frame-time, CPU or battery benchmark has yet been captured on physical hardware.

## UI performance profiles (Task 1)

The Settings page now offers four explicit profiles:

| Profile | Presentation | Audio/UI behavior |
| --- | --- | --- |
| Full Experience | Full-strength theme glow and available visual feedback | Full voice budget; meter polling remains 30 Hz |
| Balanced | Decorative glow scaled down to 55% | Full voice budget; meter polling remains 30 Hz |
| Lightweight | Decorative glow, glass blur and the scopes' blurred glow disabled; the glass look stays, unblurred (`lib/ui/glass.dart`) | Existing reduced voice budget (4 per pattern layer); meter polling remains 30 Hz; frame rate capped at 60 Hz (owner, 2026-11-12) |
| Minimal | Decorative glow and glass disabled; scope panels hidden; motion off (`lib/ui/motion.dart`) | Reduced voice budget; meter polling remains 30 Hz; frame rate capped at 30 Hz (owner, 2026-11-12) |

The legacy `light_mode` setting is still read for migration: true maps to Lightweight and false maps to Balanced. New settings persist `performance_mode` by name and also write the legacy boolean for older builds. Editing settings (the roll's look and value grid, the arrangement's track gap, the music video's one-time Strobe warning, `strobe_warned`) are the same in every profile.

**Important correction:** performance profiles do not lower meter polling to 15 Hz. Meter cadence stays at 30 Hz in every profile; visual simplification is preferred over slower feedback. Balanced only scales decorative glow, while Lightweight/Minimal apply the existing smaller voice budget. Minimal hides the Engine Lab master scope, whose data is a mono sum; independent left/right peak meters remain visible.

No phone frame-time, battery or thermal measurements have been made for these profiles yet. Verify them on physical Android hardware before claiming a quantified performance improvement.

## Song scenarios (2026-11-11)

The owner's measure (2026-11-11): a project "without crazy effects" at 50–60 % CPU on the S22+, then a screenshot of one at 49 % with three tracks playing (90 BPM: Drums 4 bars, Bass 4 bars, "Track 3" 1 bar). The project itself isn't here, so `caw_bench` builds representative ones (`engine/bench/caw_bench.cpp`):

- **First loop**, every track unmuted.
- **Three tracks** (the screenshot, instruments assumed): org.caw.drums (the 808 kit, eight pads: kick, snare, clap, closed, pedal and open hats, tom, crash; 110 hits in 4 bars) with a compressor and an EQ; the Flagship bass preset (`org.caw.bass`) with a saturator; Flagship at its defaults (unison 7, ladder) with a delay and a reverb.
- **Typical song:** drums, Flagship bass, lead, pad, keys, pluck and stab (unison 3–7), percussion (a second kit), each with two or three of EQ, compressor, saturator, chorus, ensemble, filter, phaser, flanger, imager, transient, delay, reverb; a reverb bus and a delay bus fed by sends; the bass ducked by the drums (org.caw.ducker, keyed); a master EQ, compressor and limiter; two LFOs (one on the pad filter's cutoff, one on the bass's Flagship cutoff).
- **Typical song + extras:** the same, with per-note FX (a filter and a saturator, 8 slots) on the keys, an audio clip (a 100 BPM loop stretched to 124 BPM, WSOLA) and a sampler track (a looped zone, chords).

**Millions of instructions per second of audio** (callgrind, x86-64, GCC 13 `-O3`; before `46e6f46`, after branch `perf-pass`). "Steady" leaves out the master loudness meter, which now stops measuring 30 s after its last read (nothing in the app reads it):

| Scenario | Before | After | Change | After, steady | Change |
| --- | --- | --- | --- | --- | --- |
| Three tracks | 467.6 | 398.9 | −14.7 % | 371.3 | −20.6 % |
| First loop | 260.0 | 247.7 | −4.7 % | 220.4 | −15.2 % |
| Typical song | 1,247.2 | 1,069.5 | −14.2 % | 1,042.0 | −16.5 % |
| Typical song + extras | 1,613.6 | 1,394.7 | −13.6 % | 1,367.2 | −15.3 % |

**Per component** (the same runs, inclusive millions a second; the three tracks, then the typical song + extras):

| Component | Three tracks | Song + extras |
| --- | --- | --- |
| Drums (org.caw.drums) | 118.3 → 113.3 | 72.3 → 69.5 (two kits) |
| Flagship | 81.2 → 70.0 | 471.8 → 401.5 (six, with the keys' per-note FX) |
| Reverb (reverb.pro) | 73.4 → 47.4 | 128.2 → 82.6 (two) |
| Saturator | 52.4 → 42.4 | 197.6 → 153.0 (eleven, eight of them per note) |
| Master loudness meter | 36.6 → 27.6 (→ 0 steady) | 36.6 → 27.5 (→ 0 steady) |
| Delay (delay.pro) | 26.3 → 26.1 | 78.6 → 78.0 |
| Compressor | 14.1 → 13.3 | 52.9 → 50.4 |
| EQ | 14.3 → 12.3 | 144.5 → 126.4 (ten) |
| Effects' shared base (control grid, peaks, sleep) | 12.6 → 8.4 | 89.5 → 62.4 |
| Sends and routes | | 52.0 → 45.6 |
| Per-note FX host (its effects included) | | 195.2 → 162.3 |
| Filter, ensemble, imager, ducker, limiter, phaser, flanger, sampler, audio clip | | unchanged (70.9, 32.9, 21.1, 26.1, 23.4, 9.4, 5.9, 45.1, 43.4) |

- **Time** (`caw_bench 10 401 K`, after, one run on the shared server): three tracks 205 µs per 256-frame callback (3.8 % of one core; before, one noisy run, about 306 µs), First loop 126 µs, the song 708 µs (13 %), the song + extras 1,230 µs (23 %). Shares of the three tracks: Flagship ×2 27 %, drums 24 %, reverb 13 %, saturator 12 %, delay 9 %, host 9.5 %.
- **What changed** (every golden render, the block-size test and the rt allocation tests unchanged: the same bits throughout):
  - The Library reverb's block form keeps its state in locals and runs the eight lines and the two sides' all-passes as two-wide double vectors (GCC and Clang vector extensions, SSE2 or NEON; MSVC frame by frame); its Hadamard written out; the modulated read's cast through `int64_t`. reverb.pro uses it. A test against the frame-by-frame form gave identical output with GCC and Clang on x86-64 and aarch64 (under qemu).
  - The Library's 2x oversampler runs its two branches side by side (each lane an AllpassChain's arithmetic), and `MultiLadder::processPair` (Flagship's ladder pairs) as two-wide vectors; both checked bit for bit on the same four compilers and targets.
  - EQ: band by band over each 16-frame run instead of a switch per band per sample; its display analyser hears the audio only while a UI reads the display. Saturator: one loop per mode with the curve inlined, the curve's value at the bias worked out only when the bias moves. Compressor: a level more than 0.01 dB under the knee skips the log (the curve is exactly 0 dB there), and dB to gain is worked out only when the dB changes. EffectBase's peaks and silence count as integer maxima without a carried branch. Sends: a settled route's gain loop without the per-sample glide and tap checks. Project modulation of a held base value normalizes it once per block. The correlation meters work out their decay once per block size. The true-peak filter reads a doubled history without a modulo, its four phases side by side.
  - Memoryless effects (distortion, balance, width) say quiet, so the host skips them on silent input; drums capture a hit's display waveform only while a UI reads the display.
- **Silence, 2026-11-12 (speed phase 1):** the master meters, silent tracks, settled silent sends and settled buses skip their per-sample loops on silence with the same bits, and the master DC blocker settles at 0 below −240 dBFS so the master chain sleeps within a second of a tail ([engine performance](engine-performance.md#1-free-wins)).
- **Sleeping, checked:** every effect of the suite (EffectBase) clears its state and sleeps after its silent-input period, at a grid point (the same frame at any block size), and wakes on the first non-zero input sample; instruments sleep when nothing sounds (drums, Flagship, sampler). The legacy chorus and ping-pong delay have timed state (an LFO, a gliding time) and still always run.
- **Per-parameter work, checked:** org.caw.drums has 10,392 parameters, but the chain re-resolves nothing while no knob, lane or ramp moved (`resolveEntry` was 0.35 % of the three tracks) and the kit reads a pad's knobs only for pads that sound; no work grows with the parameter count per block.
- **What is left** (the three tracks, after): the drums' voices (bodies, the hats' and crash's six metal oscillators, the kick's 2x oversampled drive, a modal resonator), Flagship (the ladder, oscillators, per-voice control), the reverb's eight delay-line reads and writes, the saturator's 2x oversampling. All are per-voice or per-sample DSP; the exact rewrites above took the cheap part. Further cuts would change bits (a float reverb, a cheaper oversampler, ending drum voices earlier) and each needs the perceptual check (band levels within 0.01–0.3 dB) before it is taken.
- **Arm:** the same code, cross-built with GCC 13 for aarch64, ran `caw_tests` under qemu-user: every DSP and golden test passes with the same hashes (661 tests; only the native-component loading test fails there, as before, because it needs CTest's environment). qemu's wall times swung by ±20 % between identical runs, so they give no Arm before/after. **[Assumption]** Arm64 gains about as x86-64 does: the vector paths are NEON there (two doubles per vector, as SSE2).
- **The CPU meter** (`Engine::reportLoad`, `engine/platform/audio_miniaudio.cpp`): the wall time of the whole device callback (the engine's render in 512-frame chunks, the interleave, monitoring and the latency ping), divided by the callback's own length (its frames over the device's rate), smoothed (0.9 kept per 10.7 ms). Nothing in the callback waits or locks, and the budget is the frames that callback was given, so it is not miscounted. It is the audio thread's real-time load on one core at whatever core and clock it ran, not the phone's CPU use. On the server the three tracks took about 5.7 % of a core before this pass (one noisy run; 3.8 % after); the owner saw 49 % on the S22+, about 8.5 times that. **[Assumption]** That ratio is more than the S22+'s big cores need (a Cortex-X2 near 3 GHz should be within about 1.5 times of this Xeon), so the audio thread most likely runs on a little core or at a low clock: Android's schedutil raises a core's clock only as its use grows, and a callback that idles between 1024-frame buffers keeps it low. So the meter reads high at light loads and rises less than linearly as work grows; it does not mean the phone is half busy. **[Proposal]** To check and fix, on the device: log the callback's core (`sched_getcpu`) and the core's clock, and try Android's performance-hint API (ADPF `APerformanceHint`, Android 13+; **[Assumption]** from memory, check the NDK reference before building) with the buffer's length as the target, which tells the scheduler the audio thread's deadline.
- **The app's own share** is outside this meter: the meter polls at 30 Hz while playing, a peak meter's own ticker runs while it shows something (it falls per frame), the playhead's ticker runs only while it plays, and LiveIsland redraws on those (see [App audit](#app-audit-2026-10-28) and [app](app.md)). Not measured on the phone here.

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
- The ladder is a long chain of dependent operations per sample; running a voice's two sides in one loop let the CPU overlap them (1.7× faster), and several voices' filters now run side by side the same way (speed A2, [engine performance](engine-performance.md#a2-flagship-voices-side-by-side)). The reverb (the Library's, unchanged) is why the flagship's starts off.

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
- **The phone's hardware:** the device is opened with miniaudio's low-latency profile, which asks AAudio for its low-latency (MMAP) path ([engine](engine.md), the device buffer); the new buffer setting's Auto mode opens a 1024-frame buffer while not recording (about 47 callbacks a second instead of 250–500), and Battery also leaves the fast path. Flush-to-zero is on for every `Engine::process` call since speed phase 2 (2026-11-12, [engine](engine.md), "Determinism"); the kernels keep their own denormal guards.
- **Quality:** Eco caps unison at 4 copies, turns the saturator's oversampling off and thins the reverbs: the Pad −14 %, the First loop −5 % (the Lead has 3 copies, below the cap).

## Startup screen (2026-11-12, beta readiness D2)

The startup screen ([App](app.md), "Startup screen") adds no wait: the shell shows in the frame `AppState.ready` turns true and the screen fades out over it. What it can cost is UI-isolate time while launch loads, so `perf_startup_bench_test` now lists the 20 saved projects a second time while the reveal's painter records a frame every 8.3 ms (120 Hz). Linux x64 test host, JIT, five runs each (`flutter test test/perf_startup_bench_test.dart`):

| | List 20 projects | UI isolate blocked | Longest stall |
| --- | --- | --- | --- |
| Before (base 06186b5, one run) | 85.6 ms | 15.3 ms | 5.6 ms |
| After, the same listing (unchanged code; five runs) | 72.7–106.8 ms | 6.3–30.9 ms | 3.6–14.3 ms |
| After, while the reveal paints at 120 Hz | 77.1–114.0 ms | 9.2–46.3 ms | 6.0–34.9 ms |

- **Each reveal frame** records in 138–193 µs on average (longest 243 µs) once warm, so painting adds at most a few ms over a typical launch; the listing's spread run to run (about 35 ms) is larger than the difference, within the 50 ms budget.
- **[Assumption]** Rasterising (the raster thread) and the phone's own launch time are not measured here; check on the S22 in the APK.

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
  - `MotionClock` (device motion) asked for one frame per 33 ms step (superseded 2026-11-12: it runs on every frame while shown, in a layer of its own, [below](#frames-at-240-hz-2026-11-12)); it stops in the background and in sleeping sections (`TickerMode`). Device display polls skip their FFI read in the background.
  - Repaint boundaries in the arranger (tracks, timeline viewport, lanes, grid, ruler); a zoom rebuilds the lanes and keeps the headers (`_headersRev`).
  - `FileWords` (C++ completion) counts the file's words once and re-reads only an edit's span, widened to whole words; a randomized test checks it against a full scan. List ties sort by name.
  - Memory: undo history holds at most 48 M characters of snapshots (a project with large component states held up to a hundred copies of them).
- **Measured and left as they are:**
  - A knob step, the pinch zoom and device motion were taken on in [Frames at 240 Hz](#frames-at-240-hz-2026-11-12).
  - Each native job's wait spawns an `Isolate.run` (about 0.3 ms in the test VM); a project sync or live step pays it once.

### Release build

- **[Fact]** R8 is on for release: Flutter's Gradle plugin sets `isMinifyEnabled` and `isShrinkResources` on the release build type with its ProGuard rules (FlutterPlugin.kt in the Flutter SDK's Gradle plugin, Flutter 3.47.7, checked 2026-11-10); the APK's `classes.dex` is 0.59 MB.
- **[Fact]** Impeller is the Android renderer: "available and enabled by default on Android API 29+", with a fallback to OpenGL on older or non-Vulkan devices (docs.flutter.dev/perf/impeller, read 2026-11-10); the engine at Flutter 3.47.7 defaults `enable_impeller = true` on Android (common/settings.h in the Flutter SDK's engine sources), and the manifest has no `EnableImpeller` opt-out. **[Assumption]** The S22+ (Android 12 or later, a Vulkan GPU) runs Impeller on Vulkan.
- **`--split-debug-info`** (CI's `flutter build apk`): `libapp.so` for arm64, AOT-compiled from this branch with Flutter 3.47.7's `gen_snapshot` and stripped as AGP strips it: 10.22 MB → 8.85 MB (gzip 4.17 → 3.44 MB, so the APK is about 0.73 MB smaller: the last CI APK was 55.5 MB, of which `libapp.so` 3.97 MB compressed). It is safe with FFI (native symbols are looked up by name strings; only Dart stack-trace tables move out). Release stack traces become addresses: CI keeps `caw-android-symbols`, and the problem log keeps the trace's header that `flutter symbolize` needs.
- **No `--obfuscate`:** 0.13 MB more, and type names in the app's own error texts (shown to the user and in problem reports) would be garbled.
- Signing is unchanged. The APK's size after these changes is measured when CI builds this branch.

## Frames at 240 Hz (2026-11-12)

Beta readiness plan B3–B5 (owner, 2026-11-12, [beta readiness plan](beta-readiness-plan.md)): everything that moves at the screen's rate, up to 240 Hz, where a frame is 4.2 ms. The benches (`app/test/perf_arrange_bench_test.dart`, `perf_device_bench_test.dart`, helpers in `perf_util.dart`) count frames, widgets rebuilt and render objects painted, and time each pumped frame's build, layout, paint and compositing (the UI thread's share) and the screen's raster from its layer tree (`OffsetLayer.toImage`, from scratch with no raster cache, the test's software renderer: the GPU thread's share at most). Each asserts ceilings about 10 % over the numbers below, so they can't grow back; the counts are exact in the test VM, the times are noisy on the shared cloud server (runs varied 2× with other jobs) and get wide ceilings. The arranger project is the 16-track one plus an audio track of four 16 s clips; one second at 120 Hz while playing, 30 frames of each gesture. Before is `e5bb3aa`, after is branch `ui-frames`; the before rows ran the same benches on the old code.

| Bench (count over the run; ms is the mean UI-thread time a frame) | Before | After |
| --- | --- | --- |
| Arranger playing, 120 frames | 117 frames, 236 builds, 642 painted; raster 4.0–4.6 ms | the same (the playhead's live island); raster 4.5 ms |
| Arranger sideways scroll, 30 frames | 840 painted | 390 painted (waveforms in their own layers) |
| Arranger pinch zoom, 30 frames | 87,390 builds, 90,150 painted, 125–298 ms a frame | 5,856 builds, 7,259 painted (two rebases), 35–52 ms a frame; the release lays out once: 2,914 builds |
| Ping-pong delay editor stopped, one second | 30 frames, 990 painted (33 a motion frame) | 0 frames once idle (the battery rule); with a finger held on it 119 frames, 238 painted (2 a frame: motion on every frame in its own layer) |
| Phaser editor stopped | 30 frames, 990 painted | 0 frames once idle; a finger held: 119 frames, 238 painted |
| Flagship editor stopped | 30 frames, 8,040 painted (268 a frame: a modulated knob's ring laid out its whole card) | 0 frames once idle; a finger held: 119 frames, 238 painted |
| Ping-pong / phaser / Flagship editor playing | 30 frames | 120 / 120 / 119 frames, 1,410 / 1,380 / 238 painted |
| EQ / compressor editor stopped | 0 frames | 0 frames, a finger held too (no motion) |
| EQ / compressor editor playing | 30 frames, 750 / 450 painted | the same |
| Flagship, 20 steps of its first parameter | 30,028 builds, 16,509 painted | 14,627 builds, 11,694 painted (its cards rebuild on their own values) |
| EQ, 20 steps of its first parameter (`b1_on`: the page shows it) | 10,490 builds | 11,290 builds |
| Ping-pong `sync`, phaser `stages`, compressor `threshold`, 20 steps (first parameter) | 6,560; 8,460; 7,140 builds | 7,208 (the page picks its knobs by it); 1,860; 1,080 builds |
| First knob, 20 steps: EQ `b1_freq`, compressor `threshold`, ping-pong `feedback`, phaser `rate`, Flagship `osc1_frame` | 10,260; 7,140; 6,560; 8,460; 30,020 builds | 3,400; 1,080; 1,560; 1,100; 1,120 builds (the knob and the hero; at `bde0faa`, with only the controls watched: 10,420; 7,400; 6,720; 8,760; 31,180) |
| A knob step, every built-in (`perf_knobs_bench_test.dart`: widgets rebuilt per live step of each of its first six knobs, motion off, the most of any knob) | at `bde0faa`: 211–654 for effects (median 364 a step over all), drums 1,147, Flagship 1,570, racks 577–981 | 45–74 for most, bitcrush 100, ducker 114 (its curve's handles), EQ 173 (the curve, band strip, readout and band controls), drums 68, Flagship 56 (median 52); racks 603–1,013 (a rack's parameters choose its children, so its page rebuilds) |
| Device editors' raster, playing | 9.4–15 ms | 10–13 ms (the same picture) |

- **What changed** (details in [app](app.md), Frame rate):
  - Device motion is a Ticker (`MotionClock`) inside its own repaint boundary and build scope (`DevicePhase`, the knob's face as a `LiveIsland`): a motion frame repaints 2 render objects instead of the card or page around it. It asks for every frame (120 at 120 Hz, was 30) only while something moves: the engine sounds (`AppState.sounding`) or a finger is down on the editor (`MotionTouch`); stopped, silent and untouched the engine runs no modulator (`Engine::process`), so the clock holds its time and asks for none, and Auto's idle drop comes (the battery rule, 2026-11-12). Reduced or no motion, Minimal, the background and covered routes stop it.
  - Device display reads ride the shared meter tick instead of their own 33 ms timers, so they stop when the poller does.
  - Waveforms: cached 512 px tiles of one `drawRawPoints` batch each per clip, zoom and size (was a `drawLine` per pixel across the whole clip on every repaint), repainted only for their own file's peaks; track cards' playhead is a live island over its own layer.
  - `AppState._syncNow` notifies only on a real change; scopes read and redraw only on a new tick, as live islands; automation curves are cached in their own layer under a small live painter.
  - Device painters compare their inputs; controls, the preset chip, Flagship's cards and every editor's hero rebuild on their own values (`ParamWatch`): `HeroCanvas` watches its visual and its readout, a watch also counts what its subtree reads in layout and paint (a `LayoutBuilder`, a painter) and what a widget rebuilt on its own reads (found by its `DeviceScope` lookup), and editors read the values their hero draws inside it, not in the page. A knob step rebuilds the knob and the hero.
  - The meter poll reads all tracks in one C API call (API 25) into a kept native buffer.
  - The pinch transforms the laid-out lanes and lays out at its end (or past 0.6×/1.6×), landing exactly where a layout per move would (`arrange_test`, "a pinch scales the lanes").
- **Not measured here:** frame times on the S22+ and Windows in a release build (the plan's B5 asks the owner to check them and record them here).

## Music video render (2026-11-12)

The owner (2026-11-12): "really slow to build the video". Profiled first: every render now keeps a profile (`VideoRenderProfile` in `video_render.dart`: the audio render, the meters, and per frame the picture's recording, the raster thread's `toImage`, the read-back `toByteData` and the encoder's `addFrame`), shown when it ends and logged. `app/test/music_video_profile_test.dart` (opt-in: `CAW_VIDEO_PROFILE=1`, with `CAW_LIB` for the engine's real audio) renders two bars (4 s, 120 frames) of the test song at 1080 × 1920 and 30 fps, edited with three shots, a split layout and a beat glow, twice: **before** draws, rasterises and sends each frame one at a time with the StandardMessageCodec copy the method channel made (as the render did until now), **after** is this branch (three frames rasterising ahead, frames sent as raw bytes). Three runs on the 4-core Linux x86-64 cloud container, `flutter_tester` (Skia on the CPU, so rasterising is far slower than a phone's GPU); medians, other jobs share the machine:

| | Before | After |
| --- | --- | --- |
| **Seconds per second of video** | **2.84** (2.54–2.86) | **1.86** (1.50–2.13), −35 % |
| Wall time for 4 s | 11.3 s | 7.4 s |
| Audio render (engine worker pool) + meters | 0.2–0.5 s + 0.06 s | the same |
| A frame: recording (UI isolate) | 4.1 ms | 1.8 ms (laid-out text kept) |
| A frame: rasterising / reading back | 51 ms / 12 ms | overlapped (each stage's time includes waiting its turn: 51 / 125 ms) |
| A frame: the codec's copy of 8.3 MB | 10–20 ms | none (a binary message) |

- **What the profile shows:** rasterising on the single raster thread is the biggest share here; recording the picture is small; the method channel's codec copy was 10–20 ms a frame on the Dart side alone. The audio render is a fraction of a second for 4 s.
- **Android's encoder (not measured on a device; Kotlin isn't built here):** reading `VideoEncoder.kt`, every frame (1) arrived as a new 8.3 MB `ByteArray` from the codec, (2) was converted to YUV on the CPU a pixel at a time with an indexed `ByteBuffer.put` for every byte, and (3) waited up to 10 ms in `dequeueOutputBuffer` mid-stream (the H.264 output usually lags a frame or two, so it waited most frames: about 0.3 s of every second of 30 fps video). The same conversion loops on the JVM (HotSpot, this container; ART will differ) take 25 ms a frame with packed chroma and 32 ms with interleaved chroma, plus 4–23 ms for the new array; the row-at-a-time fallback 23–26 ms, so the fallback alone gains little. **Fixed:** frames go through the codec's input Surface (the GPU converts RGBA to YUV: one texture upload and draw through EGL, each frame stamped at its exact time with `eglPresentationTimeANDROID`; the first version drew a Bitmap on the hardware canvas, whose frame times came from when frames were posted), arrive on the `caw/video_frame` binary channel into two reused buffers (no codec copy, no 8.3 MB allocation a frame), and the encoder no longer waits mid-stream. [Assumption] On the S22+ this removes roughly 35–65 ms of CPU a frame at 1080p; the seconds per second there are for the owner's first render to record here.
- **Also done:** a draft (360 on the short side, 15 fps: about a fifteenth of the pixels of a 1080p 30 fps render) and the render in the background while the user works.
- **Not done:** more than one raster thread (Flutter rasterises on one, so rendering frames in parallel is bounded by it; the pipeline keeps it busy instead) and caching each shot's still layers as pictures (the views move every frame; recording is 2 ms of a frame).
- **To record on the phone:** the done notice and the log line (`Music video render: … s per second of video …`) give the device's own numbers; a 1080p 30 fps render of the starter song before and after this branch.

## Remaining bottlenecks and next steps

- **Measure on the phone.** Build a release APK, then:
  - play the starter project and 16 layers for 5 minutes each, with the screen on and off
  - record CPU, the audio thread's time per callback (`caw_engine_meters` already reports the load), dropouts, frame times, battery and temperature
- **Measure native project-job latency on the phone.** Project updates use the shared native worker pool rather than starting a Dart worker isolate per update. Measure queue wait, update duration, UI responsiveness and audio callback impact in a release build.
- **The shell's `IndexedStack`** retains all eight workspace destinations and may rebuild/layout them on structural project changes. Measure this on device before changing it; preserving editor state is a constraint.
- **Scopes** read 512 samples over FFI and redraw a path about 30 times a second while playing, in a live island, only on a new read. That's fine on the server; check the frame time on the phone.
