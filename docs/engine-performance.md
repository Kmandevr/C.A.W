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

**What changed (2026-11-12, branch `speed-free-wins`):** link-time optimisation by default for Clang (the Android build) and MSVC ([engine](engine.md)); Flagship's FM and fold warps read their tables in three passes as the unwarped copies do, its filters' drive runs two samples at a time (`lib::Saturator::process2`), and its reverb runs a block at a time (the Library's block form), all giving the same bits; silent work skipped in the master loudness and correlation meters, silent tracks, settled silent sends and settled buses (the same bits); the master DC blocker settles at 0 below −240 dBFS, so the master chain sleeps within a second of a tail; Eco renders Flagship's FM and fold warps without oversampling and runs the clipper's chosen factor one stage lower ([engine](engine.md)). Every reference render passes without re-recording, and every golden hash passed unchanged before the DC blocker's settling (the one change below the last bit, at −240 dBFS).

**[Fact, Bench run [43143114934](https://github.com/Kmandevr/C.A.W/actions/runs/43143114934), commit `05abbe1`, 10 s × 3 runs]** mean µs against the baseline above, on the arm64 targets (the same Neoverse-N2 cores both times). The Linux x64 runners differed between runs (baseline Xeon 8573C; this run EPYC 9V74), so its numbers are not compared.

| Scenario | Android arm64 before | after | change | Linux arm64 before | after | change |
|---|---:|---:|---:|---:|---:|---:|
| Typical song (8 tracks) | 859 | 854 | −0.6% | 891 | 901 | +1.1% |
| Typical song + extras | 1,199 | 1,187 | −1.0% | 1,203 | 1,224 | +1.7% |
| Flagship heavy, 64 voices held | 5,501 | 4,869 | −11.5% | 5,697 | 4,817 | −15.4% |
| Flagship heavy, 16 voices held | 1,425 | 1,264 | −11.3% | 1,464 | 1,249 | −14.7% |
| Drums kit, 16 pads busy | 339 | 336 | −0.9% | 372 | 373 | +0.3% |
| Song, 16 tracks | 1,609 | 1,600 | −0.6% | 1,669 | 1,690 | +1.3% |
| Song, 32 tracks + heavy FX | 5,311 | 5,250 | −1.2% | 5,525 | 5,694 | +3.1% |
| Tail: silence after | 40 | 19 | −53% | 40 | 20 | −51% |
| Tail project, no notes | 29 | 10 | −64% | 31 | 11 | −63% |

**[Fact, callgrind, 2026-11-12]** instructions per second of audio (M Ir/s) in `Engine::process`, `caw_bench 2 500 --runs 1`, Linux x64 GCC 13.3 Release (no LTO: GCC's default), base `3f75be6`; tail phases as fixed windows (notes 0–2 s, ringing 2–16 s, silence 16–30 s). Instruction counts don't depend on the machine's load, so they show changes of under 1% that the CI timings' noise hides.

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| First loop (6 tracks) | 245.9 | 246.1 | +0.1% |
| Three tracks | 399.1 | 400.3 | +0.3% |
| Typical song (8 tracks) | 1,150.9 | 1,147.8 | −0.3% |
| Typical song + extras | 1,551.7 | 1,548.9 | −0.2% |
| Flagship heavy, 64 voices held | 6,805.1 | 6,214.5 | −8.7% |
| Flagship heavy, 16 voices held | 1,786.1 | 1,637.9 | −8.3% |
| Drums kit, 16 pads busy | 399.4 | 400.2 | +0.2% |
| Song, 16 tracks | 2,049.3 | 2,045.1 | −0.2% |
| Song, 32 tracks + heavy FX | 6,549.7 | 6,542.3 | −0.1% |
| Tail: notes | 352.3 | 352.3 | 0.0% |
| Tail: ringing out | 241.3 | 239.2 | −0.9% |
| Tail: silence after | 79.9 | 38.9 | −51.3% |
| Tail project, no notes | 62.8 | 24.0 | −61.8% |

- **LTO:** with GCC 13 it adds instructions (on the base: song8 +1.9%, song32 +2.8%, Drums +3.2%), and the first Bench run with it on ([43142179871](https://github.com/Kmandevr/C.A.W/actions/runs/43142179871)) had Linux arm64's song32 at 5,660 µs; with Clang 18 it is neutral by callgrind (song8 −0.4%, song32 −0.6%, Flagship 16 voices −0.6%, Drums +0.8%). So it is on by default for Clang and MSVC only. **[Assumption]** Android's ThinLTO helps a little on the phone; the arm64 differences above are within the runners' noise for the scenarios it alone touches.
- **Typical song:** the phase gains under 5% on a typical song (−0.6% on Android, −0.3% by callgrind), so the owner is asked before it counts as done ([decisions](decisions.md), 2026-11-12). The gains are in Flagship's FM and fold warps and drive (11–15% on arm64) and in silence (50–65%). The heavy song's +3% on Linux arm64 is noise: its instructions fell 0.1%, and its run-to-run worst cases differ by 20%.

### 2. Floating point

**What changed (2026-11-12, branch `speed-fp`, on phase 1's head with `speed-free-wins` a58f91e):** flush-to-zero in every `Engine::process` call and sample-pack render (`ScopedFlushDenormals`, x86 FTZ+DAZ, Arm64 FPCR.FZ), and the engine's own code built with `-ffp-contract=fast -fno-math-errno -fno-trapping-math -fno-signed-zeros -fassociative-math` (GCC and Clang; MSVC unchanged; `CAW::SDK` stays strict). Never `-ffinite-math-only`. Every reference render passes unchanged (the tightened comparators of `f151501`), on x86-64 GCC 13 and Clang 18 and Arm64 GCC 13 under qemu ([engine](engine.md), "Determinism").

**[Fact, Bench runs, 10 s × 3 runs, the same Neoverse-N2 cores in every run]** mean µs. Before: [43151692751](https://github.com/Kmandevr/C.A.W/actions/runs/43151692751) (commit `9642466`, phase 1 + a58f91e, strict flags). Per flag: [43153040577](https://github.com/Kmandevr/C.A.W/actions/runs/43153040577) (flush-to-zero alone) and [43153509392](https://github.com/Kmandevr/C.A.W/actions/runs/43153509392) (with `-ffp-contract=fast` only). After: [43152503064](https://github.com/Kmandevr/C.A.W/actions/runs/43152503064) (all). Linux x64 ran on different CPUs (AMD EPYC 9V45, Intel Xeon 8573C, EPYC 9V74), so it is not compared; its instruction counts are below.

| Scenario | Android arm64 before | FTZ | + FMA | after (all) | change | Linux arm64 before | after | change |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| Typical song (8 tracks) | 855 | 856 | 800 | 789 | −7.7% | 894 | 809 | −9.6% |
| Typical song + extras | 1,192 | 1,188 | 1,103 | 1,089 | −8.6% | 1,212 | 1,080 | −10.8% |
| Flagship heavy, 64 voices held | 4,873 | 4,879 | 4,421 | 4,199 | −13.8% | 4,817 | 4,128 | −14.3% |
| Flagship heavy, 16 voices held | 1,265 | 1,265 | 1,145 | 1,091 | −13.7% | 1,247 | 1,072 | −14.0% |
| Drums kit, 16 pads busy | 337 | 336 | 301 | 296 | −12.0% | 374 | 324 | −13.3% |
| Song, 16 tracks | 1,609 | 1,600 | 1,506 | 1,484 | −7.7% | 1,681 | 1,525 | −9.3% |
| Song, 32 tracks + heavy FX | 5,367 | 5,287 | 5,016 | 4,782 | −10.9% | 5,563 | 5,009 | −10.0% |
| Tail: ringing out | 134 | 133 | 123 | 120 | −9.8% | 130 | 114 | −12.5% |
| Tail: silence after | 19 | 19 | 18 | 18 | −6.2% | 20 | 18 | −7.4% |
| Tail project, no notes | 10 | 10 | 10 | 10 | −0.7% | 11 | 11 | +0.3% |

The 64-voice Flagship and the 32-track song, over budget in the baseline (about 100% of a core), now take 79% and 90% on Android arm64. Worst cases fell with the means (Android song32 8,824 → 5,627 µs; Flagship heavy 5,235 → 4,459 µs).

**[Fact, callgrind, 2026-11-12]** M Ir/s in `Engine::process` (the method of phase 1: `caw_bench 2 500 --runs 1 --only ID`; tail phases as fixed windows: notes 0–2 s, ringing 2–16 s, silence 16–30 s), Linux x64 GCC 13.3 Release, `9642466` against `8bce5ab`. Per flag, cumulative, on `7678418` (the same engine code but a58f91e's 11 lines): flush-to-zero 0.00% everywhere; `-ffp-contract=fast` 0.00% (no FMA in the x86-64 baseline); `-fno-math-errno` Drums −0.8%, others within ±0.05%; `-fno-signed-zeros` about −1% (Flagship +1.5%); `-freciprocal-math` within ±0.1% of that (dropped); `-fassociative-math` a further 1–3%. Clang 18 on the same code, strict against the chosen flags: song8 −1.9%, Drums −3.6%, Flagship heavy −0.6%, song32 −1.8%.

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| First loop (6 tracks) | 246.3 | 234.1 | −5.0% |
| Three tracks | 400.5 | 384.2 | −4.1% |
| Typical song (8 tracks) | 1,148.5 | 1,124.2 | −2.1% |
| Typical song + extras | 1,549.6 | 1,511.3 | −2.5% |
| Flagship heavy, 64 voices held | 6,216.8 | 6,266.3 | +0.8% |
| Flagship heavy, 16 voices held | 1,638.5 | 1,645.0 | +0.4% |
| Drums kit, 16 pads busy | 400.3 | 382.8 | −4.4% |
| Song, 16 tracks | 2,046.4 | 2,009.0 | −1.8% |
| Song, 32 tracks + heavy FX | 6,544.8 | 6,438.1 | −1.6% |
| Tail: notes | 353.1 | 340.8 | −3.5% |
| Tail: ringing out | 239.8 | 228.9 | −4.6% |
| Tail: silence after | 39.4 | 38.0 | −3.6% |
| Tail project, no notes | 24.1 | 24.2 | +0.4% |

- **Typical song:** −7.7% on Android arm64 (−9.6% Linux arm64), over the 5% the owner asked about; most of it is fused multiply-adds (−6.5%), which only Arm64 has, so x86-64 gains only the 2% the fast-math subsets give.
- **Flush-to-zero** costs nothing measurable and gains little in these scenarios (−1.5% on the 32-track song, else within ±0.6%): the kernels' own guards already settle decays at 0, so the bench meets few subnormals. It is kept for what the guards miss (third-party components, new code) at a few cycles per callback; the guards stay ([engine](engine.md), "Determinism").
- **Flagship on x86-64 GCC:** +0.4–0.8% instructions, all in its unison oscillator loop (`addTwice<6, false>`, +4.3%, GCC's code after reassociation), while its filter and the rest fall. Not acted on: on Arm64, where it ships, Flagship gains 14%.

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
