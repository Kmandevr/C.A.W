---
title: Engine performance
summary: The CI bench suite (caw_bench SECONDS 500, the Bench workflow), its scenarios and targets, the baseline per target, and the speed phases' before/after tables.
covers: [engine/bench/, .github/workflows/bench.yml]
updated: 2026-11-12
---

# Engine performance

The owner asked for a faster engine, measured first (2026-11-12, [decisions](decisions.md)). This note holds the measurement: the suite, where CI runs it, the baseline, and one before/after table per speed phase. How the rest of the engine and app are measured (callgrind counts, profiles, per-effect costs) is in [performance](performance.md).

## The suite

`caw_bench SECONDS 500 [--frames N] [--runs N] [--only ID,ID] [--label TEXT] [--json PATH] [--md PATH]` (`engine/bench/caw_bench.cpp`, `runSuite`). Defaults: **256-frame callbacks at 48 kHz, a budget of 5,333 µs per callback**, 3 runs. Each run plays every scenario in turn on a fresh `Engine` (set the project, 0.25 s stopped so the project is applied, then Play) and times each `Engine::process` call. A scenario's result: the **median of the runs' means** (and p99s) and the **largest worst case of any run**, with the time after Play the worst case happened; load is time ÷ budget. `--json` writes every number, each run's mean and worst too (`format: 1`); `--md` writes a markdown table. The bench changes no engine code; it builds projects from built-in instruments and effects only.

| Id | Scenario |
|---|---|
| `first_loop` | The app's First loop, all six tracks unmuted (`caw_bench S 400 0`) |
| `three_tracks` | The owner's three-track project (`400 3`) |
| `song8` | The typical 8-track song: Drums, six Flagship tracks, percussion, reverb and delay buses, master EQ/compressor/limiter, two LFOs, a ducker (`400 1`) |
| `song8_extras` | The same with per-note FX, a stretched audio clip and a sampler (`400 2`) |
| `flagship_heavy` | One Flagship patch at its heaviest, **64 notes held (full polyphony)**: three oscillators at 16 unison copies (osc 1 through the 2x-oversampled fold warp), both filters with drive, all five effects, three LFO slots |
| `flagship_heavy16` | The same patch with 16 notes held |
| `drums_kit` | `org.caw.drums`, default kit with glue, drive, room and clipper on; all 16 pads of bank A in a 16th pattern, 3-4 hits a step, ratchets |
| `song16` | The typical song's tracks repeated to 16 |
| `song32_heavy` | 32 tracks, each with EQ, compressor and saturator or distortion, a reverb on every fourth and a delay on every third; two group buses (EQ, compressor, saturator); three send buses (reverb, delay, plate reverb + chorus + EQ): 37 layers |
| `tail_notes`, `tail_ringing`, `tail_silence` | A 2 s bar of chords (Flagship pad, release 1.5 s) and a pluck through an 8 s reverb, a feedback delay and a filter, sent to a reverb bus, then nothing for 30 s: the bar, the tail until the output stays below −100 dBFS, and the silence after it |
| `tail_floor` | The tail project playing with no notes at all: what a fully asleep project costs |

## Where CI runs it

`.github/workflows/bench.yml` (Bench), on Main and on pull requests that change engine code, or on demand (inputs: seconds per scenario, runs). Each target prints its table to the job summary and uploads JSON and markdown; a summary job puts all targets in one table.

- **Linux x64:** `ubuntu-24.04`, GCC 13.3 Release.
- **Linux arm64:** `ubuntu-24.04-arm`, GCC 13.3 Release.
- **Android arm64:** `caw_bench` cross-compiled on `ubuntu-24.04` with **NDK 28.2.13676358**, the NDK the APK's engine is built with (app.yml), for `arm64-v8a`, `android-29`, `c++_static`, linked `-static`; then run on `ubuntu-24.04-arm`. **[Fact, run 43135752152, 2026-11-12]** the static bionic executable runs on the Linux arm64 kernel (`ELF 64-bit LSB executable, ARM aarch64, statically linked`; all scenarios ran).
  - **Why not an emulator:** arm64 Android images on x86 runners are translated, so their timings say little about a phone and vary widely. This target measures the Android compiler, libc++ and bionic on real Arm64 cores.
  - **What it is not:** the runner's cores are Neoverse-N2 server cores, not the S22+'s Cortex-X2/A710/A510, and there is no Android scheduler, thermal limit or audio thread priority. **[Assumption]** relative gains carry over to the phone; absolute numbers do not.
- Shared runners are noisy (other tenants, frequency scaling): read worst cases as indicative and compare means. In the baseline run, each scenario's three means agreed within about 1%.

## Baseline (2026-11-12)

**[Fact, Bench run [43135752152](https://github.com/Kmandevr/C.A.W/actions/runs/43135752152), commit `098722b`, 10 s × 3 runs, 256 frames at 48 kHz, budget 5,333 µs]** Mean µs / worst µs / mean load. CPUs: Linux x64 Intel Xeon Platinum 8573C (4 vCPU); both arm64 rows Neoverse-N2 (4 vCPU). Android row: Clang 19.0.1 (NDK 28.2).

| Scenario | Linux x64 | Linux arm64 | Android arm64 |
|---|---:|---:|---:|
| First loop (6 tracks) | 155 / 1,267 / 2.9% | 174 / 880 / 3.3% | 163 / 1,009 / 3.1% |
| Three tracks | 285 / 710 / 5.4% | 289 / 613 / 5.4% | 271 / 673 / 5.1% |
| Typical song (8 tracks) | 880 / 1,540 / 16.5% | 891 / 1,267 / 16.7% | 859 / 1,379 / 16.1% |
| Typical song + extras | 1,149 / 1,973 / 21.6% | 1,203 / 1,585 / 22.6% | 1,199 / 1,732 / 22.5% |
| Flagship heavy, 64 voices held | 4,781 / 6,132 / 89.6% | 5,697 / 5,993 / 106.8% | 5,501 / 5,878 / 103.1% |
| Flagship heavy, 16 voices held | 1,210 / 1,585 / 22.7% | 1,464 / 1,576 / 27.4% | 1,425 / 1,591 / 26.7% |
| Drums kit, 16 pads busy | 355 / 736 / 6.6% | 372 / 541 / 7.0% | 339 / 472 / 6.4% |
| Song, 16 tracks | 1,558 / 3,295 / 29.2% | 1,669 / 2,421 / 31.3% | 1,609 / 2,660 / 30.2% |
| Song, 32 tracks + heavy FX | 5,102 / 7,856 / 95.7% | 5,525 / 8,153 / 103.6% | 5,311 / 6,179 / 99.6% |
| Tail: notes (2 s) | 225 / 319 / 4.2% | 210 / 264 / 3.9% | 215 / 264 / 4.0% |
| Tail: ringing out (13.9 s) | 134 / 282 / 2.5% | 132 / 226 / 2.5% | 137 / 241 / 2.6% |
| Tail: silence after (14.1 s) | 36 / 122 / 0.7% | 40 / 114 / 0.8% | 40 / 116 / 0.8% |
| Tail project, no notes | 26 / 73 / 0.5% | 31 / 67 / 0.6% | 29 / 72 / 0.5% |

What it shows (for the phases to act on):

- **Over budget:** the heavy Flagship at full polyphony and the 32-track heavy-FX song use about 90–107% of one core per callback on every target; both would drop out on a single audio thread.
- **Worst cases come at Play:** in most scenarios the worst callback is the first one after Play (worst at 0.00 s), 2–8 times the mean: the first block's note-ons and first-time work.
- **Sleep mostly works:** the tail rang out for 13.9 s to −100 dBFS; the silence after it cost 36–40 µs a callback against 26–31 µs for a project that never played, but its p99 (about 100 µs) is three times the floor's (about 35 µs), so something still runs on some callbacks after the tail ends.
- **Android build:** on the same Arm64 cores the NDK's Clang build is 0–9% faster than the GCC build in most scenarios (3–4% in the heavy ones) and about 2% slower on the tail's notes.

No container numbers are recorded: the local run on 2026-11-12 shared 4 cores at a load average of 24, which made its timings meaningless.

## Before/after per phase

Each phase's pull request fills its table from the Bench workflow's summary on that pull request against this baseline (mean µs, Android arm64 unless a column says otherwise) and states the run id. The phases are in [decisions](decisions.md) (2026-11-12).

### 1. Free wins

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Typical song (8 tracks) | 859 | | |
| Flagship heavy, 64 voices held | 5,501 | | |
| Drums kit, 16 pads busy | 339 | | |
| Song, 32 tracks + heavy FX | 5,311 | | |
| Tail: silence after | 40 | | |

### 2. Floating point

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Typical song (8 tracks) | | | |
| Flagship heavy, 64 voices held | | | |
| Drums kit, 16 pads busy | | | |
| Song, 32 tracks + heavy FX | | | |
| Tail: silence after | | | |

### 3. Maths

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Typical song (8 tracks) | | | |
| Flagship heavy, 64 voices held | | | |
| Drums kit, 16 pads busy | | | |
| Song, 32 tracks + heavy FX | | | |
| Tail: silence after | | | |

### 4. Precision and layout

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Typical song (8 tracks) | | | |
| Flagship heavy, 64 voices held | | | |
| Drums kit, 16 pads busy | | | |
| Song, 32 tracks + heavy FX | | | |
| Tail: silence after | | | |

### 5. Parallel mixer

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Song, 16 tracks | | | |
| Song, 32 tracks + heavy FX | | | |
| Typical song + extras | | | |
| Worst case, 32 tracks + heavy FX | | | |
