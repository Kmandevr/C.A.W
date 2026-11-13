---
title: Engine performance
summary: The CI bench suite (caw_bench SECONDS 500, the Bench workflow), its scenarios and targets, the baseline per target, and the speed phases' before/after tables (phases 1-5, A2-A5).
covers: [engine/bench/, .github/workflows/bench.yml]
updated: 2026-11-13
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
- **Windows x64 (since 2026-11-13, A5):** `windows-2025` (the runner engine.yml tests Windows on), MSVC Release with its default link-time optimisation and `/fp:precise`: the Windows app's compiler. Its CPU varies between runs (AMD EPYC 7763 and 9V74 seen), so compare its numbers within one run.
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
- **Worst cases came at Play:** in most scenarios the worst callback was the first one after Play (worst at 0.00 s), 2–8 times the mean: two resets of every instrument and every parameter resolved for the first time (fixed in [A3](#a3-the-first-callback-after-play)).
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
- **Typical song:** the phase gains under 5% on a typical song (−0.6% on Android, −0.3% by callgrind); it is kept, as every measured gain is ([decisions](decisions.md), 2026-11-12). The gains are in Flagship's FM and fold warps and drive (11–15% on arm64) and in silence (50–65%). The heavy song's +3% on Linux arm64 is noise: its instructions fell 0.1%, and its run-to-run worst cases differ by 20%.

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

- **Typical song:** −7.7% on Android arm64 (−9.6% Linux arm64); most of it is fused multiply-adds (−6.5%), which only Arm64 has, so x86-64 gains only the 2% the fast-math subsets give.
- **Flush-to-zero** costs nothing measurable and gains little in these scenarios (−1.5% on the 32-track song, else within ±0.6%): the kernels' own guards already settle decays at 0, so the bench meets few subnormals. It is kept for what the guards miss (third-party components, new code) at a few cycles per callback; the guards stay ([engine](engine.md), "Determinism").
- **After the audio review (2026-11-12):** sample positions are computed strictly out of line (`src/sample_time.*`), `detmath`'s range reduction is kept from reassociation, `wrap01` normalises −0 in its bits and the flush guard is ordered ([engine](engine.md), "Determinism"). **[Fact, callgrind, x86-64 GCC 13.3 Release, 2 s of playback (a 3 s run minus a 1 s run of `caw_bench S 500 --runs 1 --only ID`), `6717492` against the fixes]** song8 2,394 → 2,403 M (+0.4%), Flagship heavy 16 voices 3,291 → 3,292 M (+0.03%), Drums kit 896 → 891 M (−0.6%). Contraction stays everywhere else, so the Arm64 gain above should hold; the Bench tables were measured before these fixes and are not re-run yet.
- **Flagship on x86-64 GCC:** +0.4–0.8% instructions, all in its unison oscillator loop (`addTwice<6, false>`, +4.3%, GCC's code after reassociation), while its filter and the rest fall. Not acted on: on Arm64, where it ships, Flagship gains 14%.

### 3. Maths

**What changed (2026-11-12, branch `speed-maths`, on phase 2's head `82ee8fe`):** the measured cost of `detmath` itself was small (callgrind, x86-64, song8: about 4% of `Engine::process` inlined from `detmath.hpp`, most of it `finiteOr0`; the Library's `fastmath.hpp` curves 6.6%), so the phase went after the per-sample curves as much as the control-rate calls.

- **Audio rate:** a new `lib::tanhApprox` (a rational fit, within 5e-9 of tanh, about half `fastTanh`'s cost, no branch) for every per-sample tanh in the built-ins: the saturator's curves (`builtin_effects_saturator.cpp`, `curve`), Delay Pro's feedback drive (`builtin_effects_space.cpp`, `DelayPro::run`), the drum drives, shapers and sub (`builtin_drums.cpp`), the filter drives (`builtin_fx_filters.cpp`), the analog drive, kit, freqshift, rotary and reverb loops; the `Saturator`'s `processApprox`/`process2Approx` for Flagship's voice-filter drive and distortion (`builtin_flagship.cpp`, `VoiceFilter`, `distortInPlace`) and the distortion component (`builtin_components.cpp`).
- **Control rate, cheaper:** Flagship's voice filters set their SVF and ladder with `setApprox` (`tanApprox`: two `fastSinCycles` instead of `detTan`'s two `detSin`; `builtin_flagship.cpp`, `VoiceFilter::configure`).
- **Control rate, only on a change (the same bits):** the compressor's attack and release coefficients (`builtin_effects_dynamics.cpp`, `Compressor::control`), the saturator's drive and output gains and its bit depth's `detPow` (`Saturator::control`), the Ensemble's per-voice pans and its mix's sin and cos (`builtin_fx_space_mod.cpp`, `Ensemble::control`).
- **Per sample, hoisted (the same bits):** an LFO on an exponential parameter computed `detLog(max / min)` (and a libm `frexp`) every sample; `denormalizeOffsets` (`params.cpp`) takes it once per block (`component_chain.cpp`, `modulated`). Its `detExp` stays: `note_fx_test.cpp`'s block-split test holds this path to `denormalizeParameter`'s bits (a `fastExp` there failed it).
- **Kept exact:** `detmath`'s functions, every older Library function and `caw_exact_tests`; bit operations, seeded random and hashes untouched. Every reference render passes unchanged: worst stable null −128.9 dBFS (Shimmer busy; most stay at the −132.5 dBFS storage floor) on x86-64 GCC 13 Release and on Arm64 GCC 13 with the engine's flags under qemu.

**[Fact, Bench runs, 10 s × 3 runs, Neoverse-N2 cores both times]** mean µs. Before: [43197482949](https://github.com/Kmandevr/C.A.W/actions/runs/43197482949) (`d6cbd65`: phase 2's head with only the Bench trigger). After: [43199779899](https://github.com/Kmandevr/C.A.W/actions/runs/43199779899) (`727c95d`).

| Scenario | Android arm64 before | after | change | Linux arm64 before | after | change |
|---|---:|---:|---:|---:|---:|---:|
| First loop (6 tracks) | 150.7 | 145.1 | −3.7% | 157.1 | 152.2 | −3.1% |
| Three tracks | 248.1 | 234.7 | −5.4% | 259.5 | 246.1 | −5.2% |
| Typical song (8 tracks) | 789.7 | 761.8 | −3.5% | 815.2 | 778.4 | −4.5% |
| Typical song + extras | 1,088.2 | 1,033.8 | −5.0% | 1,092.7 | 1,035.3 | −5.3% |
| Flagship heavy, 64 voices held | 4,194.2 | 3,960.8 | −5.6% | 4,143.2 | 3,920.9 | −5.4% |
| Flagship heavy, 16 voices held | 1,089.7 | 1,028.7 | −5.6% | 1,070.7 | 1,017.3 | −5.0% |
| Drums kit, 16 pads busy | 294.6 | 280.9 | −4.7% | 322.7 | 311.4 | −3.5% |
| Song, 16 tracks | 1,488.0 | 1,446.1 | −2.8% | 1,547.5 | 1,478.7 | −4.4% |
| Song, 32 tracks + heavy FX | 4,832.0 | 4,623.7 | −4.3% | 5,061.3 | 4,771.2 | −5.7% |
| Tail: notes | 197.7 | 192.5 | −2.6% | 188.6 | 184.3 | −2.3% |
| Tail: ringing out | 120.8 | 118.2 | −2.2% | 114.3 | 112.0 | −2.0% |
| Tail: silence after | 17.7 | 17.8 | +0.6% | 18.0 | 18.0 | 0.0% |
| Tail project, no notes | 10.3 | 10.3 | 0.0% | 11.4 | 11.4 | 0.0% |

**[Fact, callgrind, 2026-11-12]** M Ir per second of audio in `Engine::process`, x86-64 GCC 13.3 Release: a 3 s run minus a 1 s run of `caw_bench S 500 --runs 1 --only ID`, divided by 2 (the tail: its whole 30 s run, the phases together), `82ee8fe` against the changes.

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| First loop (6 tracks) | 250.3 | 246.4 | −1.6% |
| Three tracks | 389.8 | 380.2 | −2.5% |
| Typical song (8 tracks) | 1,201.3 | 1,170.3 | −2.6% |
| Typical song + extras | 1,663.2 | 1,611.0 | −3.1% |
| Flagship heavy, 64 voices held | 6,269.4 | 6,109.6 | −2.5% |
| Flagship heavy, 16 voices held | 1,646.0 | 1,603.8 | −2.6% |
| Drums kit, 16 pads busy | 445.3 | 441.5 | −0.8% |
| Song, 16 tracks | 2,157.2 | 2,107.3 | −2.3% |
| Song, 32 tracks + heavy FX | 6,869.8 | 6,665.5 | −3.0% |
| Tail (30 s: notes, ringing, silence) | 146.0 | 145.2 | −0.5% |
| Tail project, no notes | 24.2 | 24.2 | 0.0% |

- **Typical song:** −3.5% on Android arm64 (−4.5% Linux arm64); kept, as every measured gain is ([decisions](decisions.md), 2026-11-12). The heavy scenarios gain 4–6% on Arm64; the 32-track song is now at 87% of the budget on Android arm64.
- **Arm64 gains more than x86-64:** the rational tanh is multiply-adds and one divide, which Arm64 fuses (phase 2's contraction); on x86-64 without FMA it saves fewer instructions (Drums −0.8%: its tanh calls are out of line there).
- **What is left:** the remaining maths in song8 is the compressor's per-sample dB detection (`fastLog`, `fastExp`, about 0.8%), the delay's and saturator's curves, the modulation path's `detExp` (0.6%, held to its bits) and Drums' sines (`fastSinCycles`, 4% of the Drums kit); the rest of the cost is filters, delay lines, oversamplers and mixing, the subject of phase 4.

### 4. Precision and layout

**What changed (2026-11-12, branch `speed-layout`, on phase 3's head `d636c1e`):** callgrind on phase 3's head showed the remaining cost spread over filters, delay lines, oversamplers and mixing, each run sample by sample with its state loaded and stored per sample and its two sides one after the other. The phase stages those loops over the run (each stage over the whole run, its state in registers) and runs a stereo pair's two sides as one two-wide double vector (`src/stereo_pair.h`: `Pair`, SSE2 or NEON on GCC and Clang, a plain struct elsewhere; the filters' former `filters::Pair` moved there). Each sample meets each side's operations in the scalar order; the engine's flags let the compiler fuse multiply-adds (Arm64) and reassociate, so the vector and scalar code may differ in the last bits.

- **EQ** (`builtin_effects_eq.cpp`, `Eq::run`, `runMono`, `runStereo`): band by band over the run, each band's channel and fade worked out once per run; a stereo band's SVF stages two-wide (`EqFilter::stage`, `scale` added to `eq.hpp`).
- **Delay Pro** (`builtin_effects_space.cpp`, `DelayPro::run`): both sides as one vector: the time glide, the Hermite read, the tone filters (`Svf` accessors added to `filter.hpp`) and the feedback drive (`tanhApproxPair`).
- **Saturator** (`builtin_effects_saturator.cpp`, `runBlock<M>`): staged over the run per mode (ramps, drive and bias, oversampler up, the curve over every oversampled value, down, tape and DC filters, tone, dynamics, mix); the crusher and a mode change keep the per-sample path. The Library's `Oversampler2x` gained `upBlock` and `downBlock` (`oversample.hpp`: `up()`/`down()` over a block, state in registers).
- **Sends** (`engine.cpp`, `Engine::runRoutes`): a send's sum into its destination in float (`routeAdd`; a float sum of two floats is the double sum's rounding, the same bits). The send's and track's gains stay double: rounded to float they moved the mix reference's master crusher's steps (−77 dBFS residual against −120).
- **Kept double:** phase accumulators, the feedback filters (EQ, Delay Pro's tone, the DC blockers, the oversampler's allpasses), delay-line positions and the gains above. Flagship, Drums and the reverbs are unchanged in this phase.
- **Vectorised, checked with `-fopt-info-vec-optimized` and Arm64 disassembly (GCC 13, the engine's flags):** the EQ's per-run loops (`builtin_effects_eq.cpp` lines 142–205: 16-byte vectors on both targets), the send's float sum and settled gain (`engine.cpp` 3979, 3999), the Saturator's staged loops (15 loops in `runBlock`); the two-wide code is NEON on Arm64 (instructions on `.2d` vectors: `Eq::run` 287, `DelayPro::run` 161, each `Saturator::runBlock<M>` 148–549, `Oversampler2x::block` 60–65).
- **Every reference render passes unchanged:** worst stable null −128.9 dBFS (Shimmer busy, as before; the EQ, Delay Pro and Saturator references at −131.4 to −132.5 dBFS) on x86-64 GCC 13 Release, Debug with sanitizers, and Arm64 GCC 13 with the engine's flags under qemu.

**[Fact, Bench runs, 10 s × 3 runs, Neoverse-N2 cores both times]** mean µs. Before: [43199779899](https://github.com/Kmandevr/C.A.W/actions/runs/43199779899) (`727c95d`, the code of `d636c1e`). After: [43237437033](https://github.com/Kmandevr/C.A.W/actions/runs/43237437033) (`f6f2d00`).

| Scenario | Android arm64 before | after | change | Linux arm64 before | after | change |
|---|---:|---:|---:|---:|---:|---:|
| First loop (6 tracks) | 145.1 | 145.2 | +0.1% | 152.2 | 153.3 | +0.7% |
| Three tracks | 234.7 | 220.7 | −6.0% | 246.1 | 227.0 | −7.8% |
| Typical song (8 tracks) | 761.8 | 717.9 | −5.8% | 778.4 | 722.4 | −7.2% |
| Typical song + extras | 1,033.8 | 969.6 | −6.2% | 1,035.3 | 958.6 | −7.4% |
| Flagship heavy, 64 voices held | 3,960.8 | 3,970.7 | +0.2% | 3,920.9 | 3,937.3 | +0.4% |
| Flagship heavy, 16 voices held | 1,028.7 | 1,029.1 | 0.0% | 1,017.3 | 1,019.1 | +0.2% |
| Drums kit, 16 pads busy | 280.9 | 279.0 | −0.7% | 311.4 | 311.4 | 0.0% |
| Song, 16 tracks | 1,446.1 | 1,368.3 | −5.4% | 1,478.7 | 1,366.0 | −7.6% |
| Song, 32 tracks + heavy FX | 4,623.7 | 4,201.6 | −9.1% | 4,771.2 | 4,211.8 | −11.7% |
| Tail: notes | 192.5 | 188.6 | −2.0% | 184.3 | 183.0 | −0.7% |
| Tail: ringing out | 118.2 | 115.6 | −2.2% | 112.0 | 111.3 | −0.6% |
| Tail: silence after | 17.8 | 17.6 | −1.1% | 18.0 | 18.0 | 0.0% |
| Tail project, no notes | 10.3 | 10.3 | 0.0% | 11.4 | 11.4 | 0.0% |

**[Fact, callgrind, 2026-11-12]** M Ir per second of audio in `Engine::process`, x86-64 GCC 13.3 Release, measured as in phase 3; before is phase 3's after column (the unchanged scenarios, First loop, Flagship and Drums, count the same to the decimal).

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| First loop (6 tracks) | 246.4 | 246.4 | 0.0% |
| Three tracks | 380.2 | 358.1 | −5.8% |
| Typical song (8 tracks) | 1,170.3 | 1,084.0 | −7.4% |
| Typical song + extras | 1,611.0 | 1,500.2 | −6.9% |
| Flagship heavy, 64 voices held | 6,109.6 | 6,109.6 | 0.0% |
| Flagship heavy, 16 voices held | 1,603.8 | 1,603.8 | 0.0% |
| Drums kit, 16 pads busy | 441.5 | 441.5 | 0.0% |
| Song, 16 tracks | 2,107.3 | 1,955.5 | −7.2% |
| Song, 32 tracks + heavy FX | 6,665.5 | 5,896.1 | −11.5% |
| Tail (30 s: notes, ringing, silence) | 145.2 | 142.0 | −2.2% |
| Tail project, no notes | 24.2 | 24.2 | 0.0% |

- **Typical song:** −5.8% on Android arm64 (−7.2% Linux arm64); the effect-heavy 32-track song −9.1% (−11.7%), now at 79% of the budget on Android arm64.
- **What is left (callgrind, song8 after):** the reverbs (`lib::Reverb::process` 6.9%, `ReverbPro`), Flagship's voice filters (6.8%) and oscillators (`addStackWarp` 4.8%), the effects' silence scan in `EffectBase::process` (3.9%), the EQ's control-rate parameter reads (`Eq::control`, 3.3% inclusive) and Delay Pro (3.0%). Flagship's filters are high-Q feedback filters, which stay double; the parallel mixer (phase 5) is the next step.

### 5. Parallel mixer

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Song, 16 tracks | | | |
| Song, 32 tracks + heavy FX | | | |
| Typical song + extras | | | |
| Worst case, 32 tracks + heavy FX | | | |

### A2. Flagship voices side by side

**What changed (2026-11-12, branch `speed-flagship`, on `b0f8e08`: phases 1–4 merged; beta readiness plan item A2):** callgrind on `b0f8e08` (`caw_bench 2 500 --runs 1 --only flagship_heavy16`, instructions in `FlagshipInstrument::render`, 3,136 M) put the fold warp's oversampled stack at 50% (`addTwice`, its two decimators alone 10%), the other two oscillators' unwarped copies at 25% (`addStack`) and the voice filters with their drive at 12%. The filters are few instructions but a long chain of dependent operations per sample, so their share of the time is larger than their share of the instructions.

- **The fold decimators** (`builtin_flagship.cpp`, `Decimator2x`): a block at a time with the state in registers, and a stereo voice's left and right decimators in one loop (four all-pass chains: two two-wide vectors, each lane `lib::AllpassChain`'s arithmetic), instead of each side sample by sample with its state loaded and stored per stage. Callgrind: `addTwice` 1,580 → 1,265 M.
- **Fixed-length loops for a whole period** (`addTwice<W, Morph, N>`, `addTwiceWarp`): the usual 16-frame piece gets loops of a known length. The same for `addStack` made GCC vectorise its fixed-point phases worse (+66 M), so it stays at a run-time length.
- **Several voices' filters side by side** (`FlagshipInstrument::startVoice`, `finishVoices`, `filterStereo`, `filterMono`; `VoiceFilter::stereoSideBySide`, `monoSideBySide`; the Library's new `MultiLadder::processPairs<Mode, K>` and `Svf::lowpassPairs<K>` in `filter.hpp`, which `processPair` now calls): each voice's oscillators go into its own buffers and wait in a queue of up to 8 voices; voices whose filter 1 (then filter 2) is the same ladder or SVF low-pass run in one loop, K stereo pairs (two centred voices share one two-wide vector), and every voice's level and sum are then added in the voices' order, as the one-voice path adds them. A voice that ends in `finishVoices` (after the pool's walk has kept it in its list) is dropped from the list at the end of the period (`VoicePool::dropSilent`, audio review of A2, 2026-11-12). K is 4 on x86-64 and 2 on Arm64 (measured below; four voices' ladder state spills on Arm64: 62 q-register stack loads and stores in `processPairs<LowPass, 4>` against 15 for 2).
- **Measured and not kept (no gain):** the copies' high-rate frame offsets worked out once for every copy (`addTwice` 1,082 → 1,083 M), and two unison copies summed into the high-rate buffers in one pass (1,082 → 1,093 M). The unwarped and folded copies' per-sample work (indices, the table reads, which neither SSE2 nor NEON can gather, the interpolation and the fold) is already four-wide float; what is left there is the work itself.
- **Kept double:** the ladder and SVF states (resonant, low-cutoff feedback), the decimators' all-passes and the oscillators' 32-bit fixed-point phases. No float lanes were added.
- **Vectorised, checked:** GCC 13 for Arm64 with the engine's flags (`-fopt-info-vec-optimized`): `addCopy`'s passes (lines 819, 841) and `addTwice`'s (927, 952, 958) are vectorised loops; in the Arm64 disassembly `MultiLadder::processPairs<LowPass, 2>` has 69 instructions on `.2d` vectors, `Svf::lowpassPairs<2>` 23, `Decimator2x::downBlock<true>` 41 and `addTwice<Fold, false, 16>` 256 on `.4s`. Clang 18 for Arm64 (`-Rpass=loop-vectorize`) vectorises the same `addCopy` and `addTwice` loops.
- **The same within the tolerance tests; bit-identical on the builds checked:** the engine builds with `-ffp-contract=fast -fassociative-math`, so the scalar `Svf::lowpass` and the paired vector `step`, the ladder's `Lane::step` and `processPairs`, and `addTwice` with N = 16 and N = 0 where a block splits a period may be fused or reordered differently (about 1 ulp under FMA): the identity holds by the compiler's code generation, not by construction. Perceptual identity is the rule (owner, [decisions](decisions.md), 2026-11-12). `caw_exact_tests` checks `processPairs<Mode, K>` and `lowpassPairs<K>` (K = 2 and 4) bit for bit against 2K filters one at a time, built strict; `caw_tests` checks the same within one float step plus 1e-12 of the peak under the engine's flags, and that twelve Flagship notes played together (centred ladders two to four side by side, a stereo SVF pair, a lone ladder high-pass, an SVF high-pass, filter off, mono and stereo, notes starting and ending mid-period, uneven blocks) null below −120 dBFS against the sum of each note played alone (`flagship_test.cpp`; a primer voice from frame 0 in every run, since the instrument volume rises from 0 over the first period after a reset and so is not the same for a note that starts an instrument and one that joins it). On the builds checked: a scratch render of 15 Flagship patches (the heavy patch at 16 and 7 voices, the default, mixes below 1, parallel routing with ladder BP and SVF HP, ladder HP and SVF LP at mix 0.5, centred ladder and SVF voices, the shared SVF, stereo SVF, bypass, quantize, 2x FM, Osc FM with fold; uneven blocks, staggered notes and releases) gives bit-identical output against `b0f8e08` on x86-64 GCC 13 and on Arm64 GCC 13 with the engine's flags (FMA contraction on) under qemu. Every reference render passes unchanged on x86-64 GCC 13 Release, Debug with sanitizers, and Arm64 GCC 13 with the engine's flags under qemu.

**[Fact, Bench runs, 10 s × 3 runs, Neoverse-N2 cores both times]** mean µs (worst % of the budget). Before: [43260646583](https://github.com/Kmandevr/C.A.W/actions/runs/43260646583) (`b0f8e08`). After: [43267697713](https://github.com/Kmandevr/C.A.W/actions/runs/43267697713) (`49dca71`).

| Scenario | Android arm64 before | after | change | Linux arm64 before | after | change |
|---|---:|---:|---:|---:|---:|---:|
| Flagship heavy, 64 voices held | 3,960.3 (78.9%) | 3,173.9 (67.2%) | −19.9% | 3,941.9 (79.0%) | 3,424.7 (69.6%) | −13.1% |
| Flagship heavy, 16 voices held | 1,028.1 (21.5%) | 832.5 (18.1%) | −19.0% | 1,019.4 (21.2%) | 891.0 (18.6%) | −12.6% |
| Typical song (8 tracks) | 711.8 | 687.5 | −3.4% | 715.4 | 703.4 | −1.7% |
| Typical song + extras | 966.8 | 949.2 | −1.8% | 950.4 | 940.3 | −1.1% |
| Song, 16 tracks | 1,342.1 | 1,301.8 | −3.0% | 1,359.4 | 1,341.0 | −1.4% |
| Song, 32 tracks + heavy FX | 4,107.3 | 4,067.3 | −1.0% | 4,177.8 | 4,222.5 | +1.1% |

The other scenarios have no Flagship and moved within the runners' noise. The filters' group size, timed in one Bench run ([43266125720](https://github.com/Kmandevr/C.A.W/actions/runs/43266125720), 10 s, two runs each, Flagship heavy 64 voices, mean µs): one voice at a time (the decimators and fixed loops only) 3,319 / 3,590 / 3,594 on Android arm64 / Linux arm64 / Linux x64; two voices 3,171–3,194 / 3,407–3,420 / 3,329; four 3,178–3,186 / 3,425–3,428 / 3,249–3,260. So most of the gain is the decimators, and side by side adds 4–5% on Arm64 and 10% on x86-64.

**[Fact, callgrind, 2026-11-12]** M Ir per second of audio in `Engine::process`, x86-64 GCC 13.3 Release (`caw_bench 2 500 --runs 1 --only <scenario>`, divided by 2):

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Flagship heavy, 64 voices held | 6,108.4 | 5,666.6 | −7.2% |
| Flagship heavy, 16 voices held | 1,603.6 | 1,493.4 | −6.9% |

- **What is left (callgrind, flagship_heavy16 after):** the fold stack (`addTwice` with its table reads, 43%), the unwarped copies (`addStack`, 25%), the filter drive (`VoiceFilter::begin`, 5%) and the ladders (4%). **[Proposal]** the next step for the heavy patch is fewer table reads rather than wider vectors (for example a cheaper fold at the high rate).

### A3. The first callback after Play

**What changed (2026-11-13, branch `engine-a345`, on `d932771`; beta readiness plan A3):** callgrind of the first callback after Play (the bench's way: the project set, 0.25 s stopped, then Play; 256 frames) against the steady mean found two kinds of first-time work, both on the audio thread:

- **Two resets of every instrument:** `startPlay` reset each track's instrument, then its first `runInstrument` reset it again (`instrumentIdle`). For `org.caw.drums` that clears every voice and its room reverb (`DrumsProcessor::reset`, 6.6 M of song8's 12.2 M instructions). Now `ComponentChain::reset` is a no-op when nothing has run since the last one (`clean_`, set by `reset`, cleared by `process` and `runModulator`), and an instrument chain of built-ins is reset once when it is built, on the control thread (`ComponentChain::make`), so the audio thread's resets at Play find it clean. A component's `reset` puts it back as `activate` left it, so nothing heard changes. A chain holding a loaded (Trusted) component is not reset at build: the native ABI says nothing about which thread may call `reset`, and another instance may be running on the audio thread, so its reset stays on the audio thread (audio review, 2026-11-13). Every path that runs a processor clears `clean_` first; a debug assert at the call sites checks it.
- **Every parameter resolved for the first time:** a chain's first block resolved each component's every parameter (`resolveEntry`: song8's drums alone have thousands; 21,645 resolves, 2.3 M instructions in First loop's first callback). Now each component's values are resolved when the chain is built, and a block where only the play state changed (a Play, or stopped to playing) and no lane drives the component keeps its values, as the full pass would give them; a Play still ends knob overrides (`anyTouched`). `ComponentAutomation::anyLane` says which components a lane drives.

**[Fact, callgrind, 2026-11-13]** instructions in `Engine::process`, x86-64 GCC 13.3 Release, the first callback after Play and the mean of callbacks 40–139:

| Scenario | First callback before | after | Steady mean |
|---|---:|---:|---:|
| First loop (6 tracks) | 10.38 M | 1.45 M | 1.23 M |
| Typical song (8 tracks) | 12.23 M | 3.17 M | 5.26 M |

**[Fact, Bench runs, 10 s × 3 runs]** worst callback µs (worst ÷ mean; when not 0.00 s, the worst is no longer the first callback). Before: [43348511989](https://github.com/Kmandevr/C.A.W/actions/runs/43348511989) (`72724e6`, `d932771`'s engine). After: [43349254446](https://github.com/Kmandevr/C.A.W/actions/runs/43349254446) (`eb2b111`). Means moved within ±1% on the arm64 targets.

| Scenario | Android arm64 before | after | Linux arm64 before | after | Linux x64 before | after |
|---|---:|---:|---:|---:|---:|---:|
| First loop (6 tracks) | 996 at 0.00 s (6.8×) | 251 at 0.00 s (1.7×) | 847 at 0.00 s (5.5×) | 272 at 2.67 s (1.8×) | 866 at 0.00 s (6.8×) | 271 at 8.43 s (2.1×) |
| Three tracks | 559 at 0.00 s (2.6×) | 309 at 0.00 s (1.5×) | 515 at 0.00 s (2.4×) | 379 at 5.34 s (1.7×) | 471 at 0.00 s (2.4×) | 333 at 1.44 s (1.7×) |
| Typical song (8 tracks) | 1,170 at 0.00 s (1.7×) | 856 at 8.66 s (1.2×) | 1,072 at 0.00 s (1.6×) | 872 at 5.33 s (1.3×) | 1,043 at 0.00 s (1.7×) | 1,421 at 1.09 s (2.3×) |
| Typical song + extras | 1,544 at 0.00 s (1.6×) | 1,263 at 3.91 s (1.3×) | 1,353 at 0.00 s (1.5×) | 1,398 at 8.86 s (1.5×) | 1,374 at 0.00 s (1.7×) | 1,142 at 9.62 s (1.4×) |
| Song, 16 tracks | 2,323 at 0.00 s (1.8×) | 1,607 at 8.36 s (1.2×) | 2,020 at 0.00 s (1.5×) | 1,600 at 9.58 s (1.2×) | 2,254 at 0.00 s (2.1×) | 2,117 at 2.86 s (2.0×) |
| Song, 32 tracks + heavy FX | 5,690 at 0.00 s (1.4×) | 5,850 at 4.81 s (1.4×) | 4,767 at 3.91 s (1.2×) | 4,872 at 5.81 s (1.2×) | 5,493 at 0.00 s (1.7×) | 6,133 at 5.78 s (1.9×) |

- After the change the first callback is the worst only on Android arm64's two smallest projects, at 1.5–1.7× the mean (the first block's note-ons), and nowhere on Linux; the worst cases left come mid-play and move between runs (the shared runners' noise; Linux x64's song8 worst rose with no change in its mean). The Flagship-only scenarios were already at about 1.1× (Flagship's reset is cheap) and are unchanged.
- **Test:** `the_first_callback_after_play_allocates_nothing_and_costs_about_the_mean` (`caw_rt_tests`, `engine_rt_test.cpp`): drums with glue and room plus a Flagship through a chorus, set and left stopped for 0.25 s, then Play; the first callback allocates nothing and, the best of 7 fresh engines, costs at most 2× the mean of callbacks 20–120. It failed before the change (2.4× and 3.5× in two runs) and passes after (1.3×).
- Every reference render and golden passes unchanged (Release and Debug with sanitizers, x86-64 GCC 13).

### A4. Per-callback loops over the slots in use (#133)

**What changed (2026-11-13, branch `engine-a345`):** #133's item 2 (`c31b95c`, 2026-11-11) had already moved the per-chunk loops (`planChunk`, `updateSolo`, the preview and overload scans, routing) onto the ascending in-use list (`live_`). What still scanned the whole capacity: `startPlay`'s three loops, with `updateSolo` called once per active slot inside one of them (slots × in-use list), and `wakeMonitors`, which runs every stopped callback while input monitoring is wanted. They now walk `live_` (an active slot is always listed: Install and ConfigureBus list it, and a slot leaves only when inactive), and solo is worked out once per Play; a slot that leaves the list clears its tail flags, which `startPlay` used to clear for every slot. Still over the capacity, once per event and not per callback: `endPlayback` (Stop's fade end), the tempo change's note release, `ClearOverload` (the overload shedding work on branch `bt-clicks`), a device's all-notes-off and the previews' release-all.

**[Fact, callgrind, 2026-11-13]** M Ir per second of audio in `Engine::process`, x86-64 GCC 13.3 Release, `caw_bench 2 500 --runs 1 --only ID` divided by 2, `d932771` against `410f700` (A3 and A4 together; the difference is the first callback's, A3, since these scenarios run at capacity 64 with every per-chunk loop already bounded):

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Typical song (8 tracks) | 1,031.1 | 1,026.0 | −0.5% |
| Song, 32 tracks + heavy FX | 5,585.7 | 5,564.0 | −0.4% |
| Tail project, no notes | 24.3 | 24.1 | −0.8% |

### A5. CPU features

**What each build enables (checked 2026-11-13 in `engine/CMakeLists.txt`, `bench.yml`, `engine.yml` and `app/android/app/build.gradle.kts`):** no build passes `-march`, `-mcpu` or `/arch`. Linux x64 (GCC 13) and Windows x64 (MSVC) therefore target the x86-64 baseline: SSE2, no AVX and no FMA (MSVC's default `/arch:SSE2`). Linux arm64 (GCC 13) and Android (NDK 28.2 Clang, `arm64-v8a` only, the app's single ABI) target Armv8-A, where NEON (Advanced SIMD) and fused multiply-add are part of the baseline, so they already have both (phase 2's contraction uses them). The two-wide `Pair` code (`src/stereo_pair.h`) is SSE2 on x86-64 and NEON on Arm64.

**Measured: the whole engine built for x86-64-v3 (AVX2, FMA) against the baseline, on one runner, alternating, 3 runs each.** **[Fact, Bench run [43349254446](https://github.com/Kmandevr/C.A.W/actions/runs/43349254446), temporary jobs since removed; mean µs, the median of 3]**

| Scenario | GCC 13 baseline | `-march=x86-64-v3` | change | MSVC default | `/arch:AVX2` | change |
|---|---:|---:|---:|---:|---:|---:|
| Typical song (8 tracks) | 439.1 | 371.3 | −15.4% | 802.2 | 817.2 | +1.9% |
| Flagship heavy, 64 voices held | 2,013.4 | 1,428.8 | −29.0% | 6,273.2 | 6,194.1 | −1.3% |
| Drums kit, 16 pads busy | 202.8 | 166.3 | −18.0% | 312.8 | 314.4 | +0.5% |
| Song, 32 tracks + heavy FX | 2,322.6 | 1,932.7 | −16.8% | 4,344.7 | 4,413.3 | +1.6% |

GCC on AMD EPYC 9V45 (run 43349254446; an earlier run, [43337163191](https://github.com/Kmandevr/C.A.W/actions/runs/43337163191), on another x64 runner, gave −15%, −25%, −17% and −15%); MSVC on AMD EPYC 9V74. Every test, reference renders included, passes with `-march=x86-64-v3` (x86-64 GCC 13 Release, 2026-11-13).

- **GCC gains 15–29%** from AVX2 and FMA together (with `-ffp-contract=fast`, x86-64-v3 brings phase 2's fused multiply-adds to x86-64), spread over the whole engine rather than a few kernels.
- **MSVC gains nothing** from `/arch:AVX2` (±2%): it keeps `/fp:precise` (no contraction) and its vectoriser leaves the same loops scalar.
- **MSVC is the slow x86-64 build:** on the same CPU model in one run (EPYC 9V74, 43349254446), Windows x64 took 797 µs for the typical song against GCC's 615, and 6,274 µs for the heavy Flagship against 2,716 (2.3×).
- **Not built (no gain where it would ship):** runtime dispatch only pays on x86-64, whose shipped build is the Windows app's MSVC, where the wider instruction set measured no gain. GCC/Clang `target_clones` on a few kernels would not reach the engine-wide gain above (callees not inlined stay baseline) and does not exist in MSVC; a second AVX2 copy of the whole engine compiled into one binary breaks the one-definition rule (the linker may give baseline code an AVX2 copy of an inline Library function). Arm64 needs none: NEON and FMA are its baseline. **[Proposal]** for the owner: build the Windows engine DLL with clang-cl and the engine's GCC/Clang flags (contraction, the fast-math subsets), then measure x86-64-v3 for it, shipped either as a second DLL chosen at load by a CPU check or as the minimum Windows CPU (AVX2: Intel Haswell 2013, AMD Excavator 2015 and later); both change the Windows build, so neither is done here.

