---
title: Decisions
summary: Dated record of what was chosen and why, newest first.
updated: 2026-11-12
---

# Decisions

## 2026-11-12: Perceptually identical, not bit-identical; speed first (owner)

**Decision (owner):** engine output must be **perceptually identical and consistent**, not bit-identical, across platforms, live playback against export, and repeated runs. This replaces every earlier promise of identical bits (the 2026-11-03 "Exports are always bit-identical" and golden-hash entries, and the 2026-11-10 "perceptually the same" entry, rewritten below to point here).

- **Still exact:** note, clip and automation timing to the sample; every seeded random choice (stutter, randomise, round robins, seeded noise); discrete behaviour (triggers, step choices).
- **Tests:** golden hashes are replaced by tolerance tests against the current renders, which stay as the references. Stable paths: the null residual against the reference stays below −120 dBFS peak. Chaotic paths (feedback near self-oscillation, self-resonant filters, free-running or unison phase): loudness over time within 0.1 dB and per-band spectrum within a stated tolerance. Discrete: identical note events, triggers and seeded choices. Real bugs (wrong gain, clicks, broken filters) must still fail, shown by a deliberately broken case.
- **Built (2026-11-12; Claude's choices within this decision, details in [engine](engine.md#tests), "Reference renders"):** the 141 former golden renders are references in `engine/tests/references/` (23.7 MB, every render's whole waveform), each sample rounded to 2^-21 (−132.4 dBFS), so a render within −122.4 dBFS of the recorded one always passes the −120 dBFS null. A case is chaotic when a probe (an FMA build, a fast-math build, or its input moved one float step) brings it within 6 dB of −120 dBFS: four high-gain non-linear effect settings; the other 137 are stable. Chaotic: bands (and below 20 Hz, for DC) within 0.5 dB, levels more than 60 dB down held at that floor, onsets within 2 frames.
- **Allowed for speed, where the tolerance tests pass:** flush-to-zero, FMA and fast-math (keeping the NaN/inf guards that protect the mix), system or approximate maths instead of `caw/detmath.hpp` on per-sample paths, float instead of double on signal paths (double stays for phase accumulators and low-cutoff feedback filters), and a parallel mixer that sums in a fixed order. `detmath`'s bit operations stay wherever exact bits are behaviour (bitcrush, glitch masks).
- **Built, speed phase 2 "floating point" (2026-11-12; Claude's choices, [engine](engine.md), "Determinism"; numbers in [engine performance](engine-performance.md#2-floating-point)):** flush-to-zero on the audio thread (every `Engine::process` call, so live, exports and renders alike, and sample-pack renders; an RAII guard that clears only what it set). The engine's own code builds with `-ffp-contract=fast -fno-math-errno -fno-trapping-math -fno-signed-zeros -fassociative-math` (GCC and Clang): each measured faster on Arm64 or x86-64, and every reference passes unchanged. Fused multiply-adds alone gave −6.5% of the typical song on Android arm64 and the subsets another −1.2% (−7.7% in all, −13.8% on the heaviest Flagship); flush-to-zero alone is within noise, kept as a guard. Not taken: `-ffinite-math-only` (it removes the NaN/Inf guards; a test now feeds NaN and Inf from a track), `-freciprocal-math` (no gain), a higher x86-64 baseline for FMA (it would need runtime dispatch) and MSVC's `/fp:fast` (Windows isn't the speed target; its NaN handling is unchecked). `CAW::SDK` keeps the strict flags, so the Library still gives the same bits in a component on every platform; the Library's exact-bit tests run in their own strict executable (`caw_exact_tests`), and every program that links `caw_core` builds with the engine's flags (the graph routing tests guard their expected values instead). Sample positions (`src/sample_time.cpp`) stay strict in every build, so note, clip, loop and MIDI-export timing is the same on every platform.
- **Built, speed phase 3 "maths" (2026-11-12; Claude's choices; numbers in [engine performance](engine-performance.md#3-maths)):** a rational `lib::tanhApprox` (within 5e-9) for every per-sample tanh in the built-ins, `tanApprox` for Flagship's voice-filter coefficients, and control-rate exps, pows and sin/cos worked out only when their inputs move; `detmath` and every older Library function keep their bits, and every reference passes unchanged. The typical song gains −3.5% on Android arm64 (−4.5% Linux arm64), under 5%: **[Open question]** whether the phase counts as done is the owner's call. Not taken: `fastExp` in the modulation path (a block-split bit test holds it to `denormalizeParameter`'s bits).
- **Built, speed phase 4 "precision and layout" (2026-11-12; Claude's choices; numbers in [engine performance](engine-performance.md#4-precision-and-layout)):** the EQ, Delay Pro and the Saturator staged over the run with a stereo pair's sides as one two-wide double vector (`src/stereo_pair.h`), the Library's `Oversampler2x` over a block, and a send's sum into its destination in float (the same bits). Gains, feedback filters, phases and delay positions stay double: the send and track gains in float moved a downstream crusher's steps (−77 dBFS against −120), so they were kept. Every reference passes unchanged; the typical song gains −5.8% on Android arm64 (−7.2% Linux arm64).
- **Built, speed phase 5a and 5b "serial groundwork for the parallel mixer" (2026-11-12; the architect's plan, [engine performance](engine-performance.md#5-parallel-mixer)):** per-node scratch, sends and keys pulled by their destinations in the old summing order, per-slot modulation output, retirements held per node until the graph has run, and the mix graph sorted into dependency levels and run level by level, still on the callback thread. The same bits as before (every reference's digest and 200 random routed mixes); the cost is within 0.2% (callgrind).
- **Built, speed phase 5d "audio-thread scheduling and core-aware pool sizing" (2026-11-12; the owner's plan A1 and A6 in `docs/beta-readiness-plan.md`, Claude's choices within it; facts in [engine](engine.md), "Audio threads", numbers in [engine performance](engine-performance.md#5-parallel-mixer)):** all platform code behind `engine/src/thread_tuning.h` with one file per platform in `engine/platform/` (the architect's 5d plan), loaded at run time with a silent fallback. Choices: **(1)** a worker's priority is never above the callback's (a spinning worker above it could starve it on a shared core), so Linux gets `SCHED_FIFO` workers only under a real-time callback (one step lower) and otherwise none; Android workers get nice −19 (`THREAD_PRIORITY_URGENT_AUDIO`) under AAudio's `SCHED_FIFO` callback; Windows workers join MMCSS "Pro Audio" only when the callback did, and C.A.W now asks miniaudio to put its WASAPI thread there (`wasapi.usage`). **(2)** Workers keep to the fast cores (a mask) on a hybrid CPU; the callback is never pinned. **(3)** ADPF's calls run on the hint's own thread, the callback only stores its duration (the NDK reference does not say `reportActualWorkDuration` is safe on a real-time thread). **(4)** Pool size: the fast cores less the callback's, at most cores − 2 on 4 or fewer cores, at most 4; cores within 15% of the slowest count as little. **(5)** Auto weighs the callback's wait for workers against the workers' task time: one worker fewer while the wait is over 10% of the budget and longer than the workers worked (0.5 s), none means one thread for 10 s, one more back after 2 s of little wait; the serial switch leaves the wait out of the load. **(6)** rtkit (D-Bus) is not used on Linux: it needs libdbus, a new dependency (**[Proposal]**). No new dependency; C API 24.
- **Process:** measure first (a CI bench on Linux and Android arm64 with a baseline in [engine performance](engine-performance.md)), then one pull request per phase (free wins, floating point, maths, precision and layout, parallel mixer), each with before/after numbers. Claude asks the owner before any audible change and when a phase gains less than 5%.

## 2026-11-12: Third-party native components in a serial lane (Claude, [Assumption])

- **[Assumption]** When the mixer runs nodes on several threads (speed phase 5c), a node holding a third-party native component (one the user loaded as Trusted) runs in a serial lane: on one thread, never at the same time as another such node, until the module format can declare a component parallel-safe. **[Fact, `engine/include/caw_component.h`, 2026-11-12]** the C component interface's thread rules speak of one audio thread (process and reset "run on the audio thread") and say nothing of two instances processing at once, so a library may keep shared state that is not safe across threads; those components are in-process, unsandboxed code. The built-ins are the engine's own code and can run in parallel. To check with the owner before 5c ships; the declaration in the module format is future work. Built with 5c (2026-11-12, branch `speed-parallel`): a node whose instrument, inserts, a chain fading out or per-note FX racks hold a loaded component (`ComponentChain::foreign`) runs on the callback thread, before the level's other nodes go to the pool, so no two such nodes ever run at once.

## 2026-11-12: Default project (owner, 2026-11-12)

- **Decision (owner):** "Here's the project I made, that will essentially be the default." The owner's "mid tempo" project (90 BPM, A minor; Track 3, Bass, Drums, Layer 4 on Flagship, the 808 kit and built-in effects) is what a first run, a deleted last project and the bundled project template open.
- **How:** the project.json from the owner's exported .caw package is bundled as `app/assets/projects/default.json`. Its unused C++ component and the package's device binary (.so) were left out: a bundled default must not carry native code (in-process, not sandboxed; see the trust decision) or depend on a compiler. Each copy gets fresh ids with references remapped, so two copies never collide (`lib/model/default_project.dart`). The bundled template keeps the id `builtin:first-loop`, now labelled *Mid tempo*, so a saved "New project starts from" setting still finds it.
- **Kept:** the code-built First loop stays as `AppState.demoProject()`, a test and benchmark fixture whose shape many tests depend on; the engine's First loop goldens and `caw_bench` scenario encode their own projects and do not change.

## 2026-11-11: one plug-in page per C++ component (owner's "the plug-in workflow is confusing"; Claude, a proposal for the owner's review)

**Problem:** a C++ component's Test suite, Export as plug-in and Make sample pack were three separate pages behind the editor's ⋯ menu, with build status only in the editor and nothing linking one step to the next.

**What established tools do (primary sources, read 2026-11-11):**
- **JUCE Projucer:** each project lists its *exporters* (one per IDE or build system), each carrying its own build configurations, Debug and Release by default; the generated IDE projects are rebuilt from the Projucer project on save, so settings live in one place ([JUCE tutorial "Manage your Projucer project"](https://docs.juce.com/master/tutorial_manage_projucer_project.html)). Lesson: one home per artefact, targets listed side by side.
- **iPlug2:** one plug-in codebase targets CLAP, VST2, VST3, AUv2, AUv3, AAX, WAM and standalone apps ([iPlug2 README](https://github.com/iPlug2/iPlug2)). Lesson: formats are targets of one source, not separate workflows.
- **Steinberg VST3 SDK:** the *validator* is a command-line host that checks a plug-in's VST3 conformity and suits build-server use; the *Plug-in Test Host* has a unit-tests window with Run All / Run Selected, errors in an Errors view and warnings and results in a Messages view ([VST3 portal: Validator](https://steinbergmedia.github.io/vst3_dev_portal/pages/What+is+the+VST+3+SDK/Validator.html), [Plug-in Test Host](https://steinbergmedia.github.io/vst3_dev_portal/pages/What+is+the+VST+3+SDK/Plug-in+Test+Host.html)). Lesson: validate before shipping, errors apart from warnings.
- **CLAP:** `clap-validator validate <plugin.clap>` runs an automatic test suite for common bugs, with `--only-failed` to show just failures ([clap-validator](https://github.com/free-audio/clap-validator)); `clap-host` is a reference host to load a plug-in and play it from the keyboard ([clap-host](https://github.com/free-audio/clap-host)). Lesson: a pass/fail summary first, the detail behind it.
- **DDMF Plugindoctor:** analysis modes (linear, harmonic, dynamics, performance…) behind tabs, two chains to compare or show the difference ([manual PDF](https://www.ddmf.eu/pdfmanuals/PlugindoctorManual.pdf)). Lesson: measurements grouped by question; compare A/B. (Our test suite already follows this.)
- **Xcode:** Archive, then the Organizer's **Validate App** (an automated check with feedback, before submitting) and **Distribute App** ([Apple: Distributing your app for beta testing and releases](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases)). Lesson: one place per build, a validation step before export, and export offered as the next button.
- **Max for Live:** Freeze bundles a device with every file it uses so it works when shared; it takes effect on save ([Cycling '74: Freezing Max for Live devices](https://docs.cycling74.com/legacy/max8/vignettes/live_freezing)). **Kilohearts Snap Heap:** a preset built from Snapins works for anyone it is shared with ([Kilohearts: Snap Heap](https://kilohearts.com/products/snap_heap)). **Bitwig:** the Grid device as a whole is the preset, loaded from the browser ([Bitwig user guide: devices](https://www.bitwig.com/userguide/latest/introduction_to_devices)). Lesson: "make it a thing you can share" is one action from where you made it. **[Assumption]** Bitwig's exact save steps were not found in its current guide.

**What makes them clear:** one place per artefact; status at a glance (pass, fail, not run); validation before export; a next-step button; readable errors that lead to the code.

**Design (built, for the owner's review in the APK):** one **plug-in page** per C++ component (instrument or effect): Write → Build → Test → Export as a strip and a card per step. Each step has a status (DONE, CHECK for warnings, FAILED, NOT RUN, OUT OF DATE after an edit, RUNNING), its key result in one line and a button; the next step's button is the filled one and the bottom bar repeats it. Build runs in place and lists errors that jump to their line; Test opens the existing test suite and shows its verdict and thresholds; Export offers CLAP, VST3 and (instruments) Sample pack as targets side by side, opening the existing pages. Export warns, never blocks, when the latest build is untested, failed its tests or the code isn't built (the owner's "warn, don't block"). Reached from **Plug-in** beside ▶ Build (not only ⋯) and from the component's card menu on a track. Why: it follows the shared lessons above with the screens we have, rewriting none of their logic. **[Assumption]** The pipeline's record (test verdicts, exports) lasts for the app session and isn't saved in the project; the owner may want it saved. **Open (owner):** the look in the APK; whether the record should persist.

## 2026-11-11: Build tools leftovers (#162, #163, #164, #11; Claude, proposals for the owner)

- **Test-suite thresholds:** three switches, sent as the engine's `checks`: Headroom (both peaks ≤ −0.3 dBFS) and Not silent (both RMS > −70 dBFS) on by default, Real time (median block < 50 % of real time) off and only sent with CPU timing on. Why: the commonest ways a component is wrong (clipping, silence, too slow) with values a user doesn't have to type; the engine takes any path, so more can follow.
- **Instrument notes:** four fixed sequences (C4 1 s, C major chord, C4 at 32/64/96/127, C2–C6) instead of a note editor. Why: they cover pitch range, polyphony and velocity response on a phone with one tap.
- **Sample pack out of the app:** a stored .zip through the save picker, not a folder picker. Why: Android's picker hands back a document, not a writable folder path, and one file is easier to share.
- **VST3 in the export page:** one format per package (CLAP or VST3), not both. Why: it keeps the page and the generated workflow simple; a second export makes the other format. Folders from Steinberg's "Plug-in Locations" page (read 2026-11-11).
- **Learned CCs in a .mid export:** a lane on a knob with a learned CC uses that CC and channel, values on the knob's travel; a CC learned by two lanes goes to the first. The "mod-wheel-mapped target" is read as a knob with CC1 learned; a mod-matrix route from the mod wheel is not turned into CC1, since the lane holds the knob's values, not the wheel's (open question for the owner).

## 2026-11-11: the master loudness meter measures only while read (Claude, performance pass)

The live master loudness meter (BS.1770-5 K-weighting and the 4x true-peak filter, every sample) cost about 6 % of a three-track project's audio work, and nothing in the app reads it (`caw_engine_loudness` has no caller in `app/lib`; [performance](performance.md#song-scenarios-2026-11-11)).

- **Decision (Claude, a small assumption for the app; the owner may reverse it):** the Engine's master meter measures from the start until 30 s pass with no read, then stops; the next read starts it over as a reset does (`LoudnessMeter::sleepWhenUnread`, `engine/src/meters.*`). Its momentary and short-term values are then those of the last 30 s it measured, and the integrated value counts only the time something was reading. Export loudness uses its own meter and is unchanged; a `LoudnessMeter` made outside the Engine measures always.
- **No sound changed:** every other speed-up of the pass gives the same bits (no golden render was re-recorded), so it needs no perceptual check.

## 2026-11-11: the .caw project file and its package format (#159; Claude, choices to confirm)

Carries out the owner's packaging bullets of "MIDI clip loops, clip automation and project packaging" (below); [App](app.md) has the flows.

**Decision (Claude, for the owner to confirm):**
- **One `.caw` file, two forms.** With nothing ticked besides the project itself it is the project JSON (as `.cawproj` was). Otherwise it is a **zip** holding `manifest.json`, `project.json`, `assets/` (audio and samples), `components/<component id>/<ABI>/` (C++ builds), `presets/*.cawpreset`, `theme.json` (`{"name", "theme": the .theme file text}`); `plugins/` is reserved and stays empty. The reader tells them apart by the zip signature. Import also takes `.cawproj` and `.json`.
- **The manifest** (`"format": "caw.package"`, version 1) lists every dependency the export found, packaged or not: `kind`, `name`, `used_by`, `size`, `packaged`, `path` in the archive, `sha256`, `reference` (what the project JSON calls it), and per kind `component`, `abi` and `source_fingerprint` (builds), `preset_kind`, `embedded` (C++ sources and convolver impulses, which live in the project JSON) and `licence` (plug-ins: "unknown: not packaged"). A packaged file's references in `project.json` become `package:assets/<name>`, so no device path of a packaged file travels with it; a file left out keeps its path and its hash, so Locate… can check a copy.
- **No new dependency:** the zip reader and writer are our own (`app/lib/model/zip_archive.dart`, stored and deflated entries through `dart:io`'s raw deflate, no zip64, no encryption) rather than the `archive` package ([Fact] MIT, its `LICENSE` in archive 3.6.1 on pub.dev, read 2026-11-11): the reader is small enough to check whole, and every limit is ours.
- **Untrusted on the way in:** every archive name must be relative, `/`-separated and plain (no `..`, `.`-leading parts, drive letters, backslashes, control characters or links; zip-slip), and names are never used as output paths: files are written under names made here, inside the project's own folders. Limits: 20,000 entries, 4 GiB in all, 1 GiB per audio file, 256 MiB per build, 64 MiB of project JSON, 4 MiB of manifest, presets at their own 4 MiB, 1 MiB of theme; a deflated entry stops at the size it declared (zip bombs), and size and CRC are checked. A packaged file whose hash differs from its manifest is left out and named. Only files the manifest lists in their kind's folder are read, each at most once (a manifest naming one twice, or listing more files than the archive holds, is refused), and the 4 GiB counts what is actually unpacked, so an import stops and removes its files once past it. Paths in a project are untrusted too: only plain local absolute paths are looked at (no network shares, device paths or URLs; they become missing files when a project opens), and an export packages or hashes only the project's own files; Locate… checks the copy it made, not the file picked.
- **Builds through the trust store:** a build is unpacked only for this device's ABI and for sources it was built from; it asks Trust or Block once per build fingerprint (`library:<sha256>` in `native-trust.json`, beside the sources' fingerprints), and it loads only while that Trust stands (`NativeComponentManager` checks again at each prepare); the sources' own trust is still asked as before. A blocked or unanswered build is deleted and the sources build here.
- **Defaults in the checklist:** audio and samples start ticked; builds, presets and the theme start unticked (device-specific or the user's own library); presets offered are those for a device the project uses (a track doesn't record which preset it came from); the theme is offered when the one in force is a custom one.
- **On import:** presets join the user's under a free name; the theme waits for **Add theme** (`Settings.addTheme`, which doesn't choose it); a file that is still missing shows the banner.
- **Open (owner):** whether the export should also offer to package recordings that no clip uses (they are listed under Files today and packaged when ticked); whether a plug-in's licence should be confirmable in the checklist once plug-in hosting exists.

## 2026-11-11: the .caw language is deleted from the engine (#160, WP-D)

Carries out the owner's decision of 2026-11-10 ("C++ replaces the .caw language"; old projects are dropped).

- **Deleted:** the compiler and VM (`compile.*`, `vm.*`, `builtins.*`, `synth.*`, `tables.*`, `program.h`, `ops.h`), the built-in libraries (`engine/lib/`), the function reference generator (`docs.cpp`, and with it `docs/library.md` and `docs/agent-guide.md`), the .caw example templates and their golden hashes, `language_test`, `variables_test`, `synth_test`, `library_test` and `golden_test`, the CLI's `check`, `templates`, `docs` and single-module `render`, and the C API's `caw_check`, `caw_library`, `caw_template_*`, `caw_engine_set_param`, `caw_engine_set_global` and `caw_worker_pool_submit_check`. The engine CI no longer checks or renders examples. `docs/synth.md` went with the patch compiler.
- **Kept:** pattern text (the note-clip format, #158) and the per-pattern result the pattern tab reads; the two example patterns (`examples/acid-line.caw`, `chords.caw`), because the app bundles them and its test reads them.
- **A track is its instrument and inserts:** `Engine::Chain` is gone (Install only makes a slot a track); one mix-graph node per track; no voices, seams, code swaps, swap timing, `.caw` params, globals, exports or imports (this ends #78 and #133's export budget). A layer without an instrument plays nothing. `LayerSpec.chain`, the project's `globals`, `voices`, `swap`, `seam_crossfade` and key fields are not read.
- **C API 21** (18 is audio, 19 modulation, 20 is not used, and per-note FX, merged after, is 22). A module that is not a pattern reports an error on line 1.
- **Tests play C++:** every engine test that used a .caw source as a signal plays `org.caw.test.osc` (`engine/tests/test_signal.h`) or a built-in. The mixer goldens moved onto it and were re-recorded on purpose; the Library parity tests keep frozen hashes of the ports' output, recorded while they still matched the .caw built-ins. Every other golden is unchanged.
- **Bug fixed on the way:** a track's instrument installed while nothing sounds counted as still ringing at the first Play, which mixed in 5 ms of a phantom tail (a free-running source started at twice its level); a new instrument now starts idle.
- **Open, for the owner:** an instrument track keeps running after a Stop until its output is quiet (or 30 s), and a never-quiet effect there now ends at that cap without the 20 ms fade buses get; a bus whose capped tail has faded comes back while a child track still rings out. The app still sends `voices`, `swap`, `seam_crossfade` and the key (Settings' light-mode voice cap and swap timing now change nothing): removing those settings is UI work.

## 2026-11-11: Latency compensation for Bluetooth and other outputs (owner)

**Decision (owner, 2026-11-11).** Compensate for output latency on Bluetooth speakers and headphones, and on any output with noticeable delay (USB, HDMI, casting).

The owner added (2026-11-11): inputs too (Bluetooth headsets' and USB microphones, a per-input offset, the ping split into input and output, takes placed by input + output), and meters, note highlights and the playhead in step with what is heard (a timeline of meter reads read at the heard time).

**Built (Claude, branch `latency-comp`; the look of the page and badge for the owner's review):**
- **Measure:** the engine reports each side's latency (C API 23, `caw_audio_latency`; [engine](engine.md#audio-input-and-recording)): AAudio's timestamps where it has them, else the queued buffers. The routed device comes from Android's `AudioManager` (`AudioRoute.kt`) and its device callback; on Windows from the endpoint's bus and form factor (WASAPI property store), else its name. Each device keeps an offset on top of the platform's figure, preset by its kind, typed in, tapped along (median of eight taps) or, for an input, split from the loopback ping.
- **Apply:** `AppState.playheadStep` is the heard position (so the playhead, follow, live MIDI and automation writing move with it); meters read `audibleMeters`/`audibleLayerMeters` everywhere (the arranger playhead and master meter, the mixer strips, track meters, track cards, the transport position and the music video preview; CPU, overload and `playing` stay on `meters`); MIDI takes are placed at the heard step, audio takes by output + input latency; the count-in countdown waits the output latency. The metronome and count-in clicks are rendered with the music, so they are heard with the same delay and need nothing.
- **Show:** `LatencyBadge` (+N ms, the tip on tap) while the output adds more than 50 ms.
- **Facts read 2026-11-11:** [Fact] the NDK's AAudio reference: `AAudioStream_getTimestamp` "returns the time at which a particular frame was played on a speaker or headset, or was recorded on a microphone"; `AAudioStream_get*()` may be called from the data callback (not done here: the engine reads it on the caller's thread); device types `AAUDIO_DEVICE_BLUETOOTH_A2DP`, `BLE_HEADSET`, `BLE_SPEAKER`, `BLE_BROADCAST` ([NDK audio reference](https://developer.android.com/ndk/reference/group/audio)). **[Fact, read 2026-11-12]** `AudioManager.getDevices` and `registerAudioDeviceCallback` were added in API level 23 and `getAudioDevicesForAttributes` in 33 ([AudioManager](https://developer.android.com/reference/android/media/AudioManager)); the `AudioDeviceInfo` TYPE_* values the app maps (A2DP 8, SCO 7, BLE headset 26, BLE speaker 27, BLE broadcast 30, BLE hearing aid 33 (API 37), USB headset 22, HDMI 9, eARC 29 and the rest) match the reference ([AudioDeviceInfo](https://developer.android.com/reference/android/media/AudioDeviceInfo)). [Fact, read 2026-11-12] Windows' `PKEY_AudioEndpoint_FormFactor` holds an `EndpointFormFactor` (Headphones, Headset, SPDIF, DigitalAudioDisplayDevice for HDMI or DisplayPort, …) ([Microsoft Learn](https://learn.microsoft.com/en-us/windows/win32/api/mmdeviceapi/ne-mmdeviceapi-endpointformfactor)); **[Assumption]** a Bluetooth endpoint's bus name is `BTHENUM` (classic) or `BTHLE…` (LE). **[Assumption]** whether A2DP's link delay is inside AAudio's timestamps is undocumented; a published phone test measured average Bluetooth latency from about 244 ms to 484 ms by handset ([Android Authority](https://androidauthority.com/smartphone-bluetooth-latency-973198/)), so presets are typical figures (Bluetooth 200 ms, LE 100 ms, a Bluetooth microphone 150 ms) meant to be calibrated. **[Assumption]** a tap along includes the finger's own touch delay (tens of ms on phones, not measured).
- **Open (owner):** the page's and badge's look in the APK, and where the badge sits (the transport row belongs to another branch: it places `LatencyBadge`); whether compensation should default off for wired outputs.

## 2026-11-11: Every change animates (owner)

**Decision (owner, 2026-11-11):** "As a rule of thumb, if anything changes it should animate to its changed state." That covers moves, size changes, things appearing and disappearing, and panels and pages opening and closing, both in and out. Each animation is short, follows the theme's animation tokens, and respects Off, Reduced and the per-kind switches. Motion that helps use the app (drags following the finger) stays immediate. The fit-and-finish pass audits the whole app against this rule.

## 2026-11-11: The whole app works from the keyboard (owner)

**Decision (owner, 2026-11-11).** "That's what I meant by vim": everything reachable with the keyboard alone, with the arrow keys or WASD, and the keys change with the context. Some examples:
- select, duplicate and move tracks and clips;
- select and edit notes in the piano roll;
- pick an effect in a chain, open it, move between its knobs and change them;
- the same in the mixer, Files, Build and Settings.

**[Proposal]** The design:
- every area has a visible keyboard focus and a context: Arrange tracks, Arrange clips, piano roll, FX chain, device knobs, mixer, Files, Build, a menu or sheet;
- arrows and WASD move within the context; Enter opens or edits; Esc goes up a level; Tab moves to the next area;
- the existing action keymap (`lib/actions/`) adds actions per context;
- a which-key style hint strip shows the keys that work in the current context, and can be turned off;
- the existing Vim mode stays as the alternative keymap.

**[Fact]** Batch A is built (2026-11-12, [actions](actions.md#keyboard-focus)): the section bar, FX chain, device controls, mixer, Files, Build, Settings, pages, menus, sheets and dialogs, with the focus ring, the hint strip, the transport's ⏮ (Home, Ctrl+Home) and exit animations outside Arrange.

**[Proposal]** Batch B, Arrange and the piano roll (after the track-headers work merges, since it owns `arranger_screen.dart`, `track_lanes.dart`, `clip_*.dart`, `audio_clip_view.dart` and `pattern_editor.dart`):
- **Tracks** (the Arranger area's keys stay: W/↑ ↓ select, A/D pan, = − volume, M, Alt+S, Alt+↑/↓ move, Enter the menu, Delete): the focused header wears the ring (`KeyRingBox`); Shift+↑/↓ extend the selection; Tab from the headers goes to the clips.
- **Clips** (a new context): ← → (A D) the previous or next clip on the track, ↑ ↓ the clip at the same time on the track above or below, Shift extends, Alt+← → move by a grid step, Ctrl+D duplicate, Delete, Enter opens a MIDI clip's notes in the focus panel's Clip tab (an audio clip its Clip tab), Esc back to the track; S, G and F2 as now. The ring sits on the focused clip.
- **Piano roll notes**: the roll's existing keys (its Ctrl+WASD cursor) stay; a focused-note ring, ← → the previous or next note in time, ↑ ↓ the nearest note above or below, Alt+↑/↓ transpose, Enter adds a note at the cursor, Delete removes; the hint strip shows the roll's keys.
- **⏮ in the views**: Arrange and the roll listen to `AppState.revealStartRequests` (scroll there when `always`, else only when the step is off screen) and the playhead's jump animates (`_PlayheadPainter`).
- **Clashes to settle with the owner**: WASD already pans and selects in the Arranger and moves the roll's cursor, so the clip context's A/D and W/S need the owner's choice.

## 2026-11-11: Track headers that shrink, collapse and open editors (owner)

**Decision (owner, 2026-11-11):**
- **Meters:** as a header gets narrower, its meter turns upright to save width.
- **Collapse states, as in REAPER:**
  - Normal;
  - Compact: as thin as possible while keeping the name, mute and solo. On a phone at the narrowest header width, mute and solo drop until the track is focused;
  - Thin bar: just a sliver showing a track is there.

  Ways to change them:
  - drag the track's own bottom edge, which snaps through the states;
  - the track menu's Collapse ▸, which also applies to all selected tracks;
  - a folder's chevron, which collapses its children to thin bars;
  - a vertical pinch on a header.
- **Height per track:** each track can be resized on its own, and the global height is the default.
- **Nested tracks are indented** under their parent, by depth, so the nesting is visible.
- **Header gestures:**
  - a tap selects at once, and the focus view follows;
  - a **double tap opens the track's effects**: the focus view's FX tab;
  - a **hold opens the track menu** when released without moving, and a hold followed by a drag reorders or nests the track as before;
  - right-click opens the menu with a mouse.
- **Clips:** a tap on an already selected clip opens its editor (the piano roll for MIDI, the audio editor for audio). A double tap still opens the clip menu.
- **Header taps, clarified (owner, 2026-11-11):** "a normal tap on the head would just focus it": a single tap focuses at once (selects, and opens or pins the focus view on its tab, in the same frame); a quick second tap switches that view to the FX tab, counted anywhere on the newly pinned track or at the first tap's place.
- **Following the playhead (owner, 2026-11-11):** while the user zooms, scrolls or drags, following never pulls the view; it resumes a set delay after the last interaction or selection change (Settings › Editing › **Resume after**, 0.5–10 s, 2.5 s by default, or Never: until the next Play). **Follow the playhead** off stops it in both editors; its style is **Page** (the default) or **Smooth** (the playhead stays a third in).
- **More from the owner the same day:** everything that animates in animates out; a moved note or clip slides there quickly (90–120 ms); the arrangement zooms out "a metric ton" and never ends on the right; moves the view makes on its own glide; clip edges change a clip's width, never its content's scale; the Arrange hint shows only while no track has a clip, centred in the view.

**How it is built (Claude, choices to confirm; [App](app.md), Arranger):**
- **Thin rows:** 8 px; a tap, double tap and hold work as on any header (no special "expand one step" double tap, so the gestures stay one rule); the whole bar is the bottom-edge grip, and the menu, a drag or a pinch opens it. Compact rows are 28 px. A row snaps thin below 18 px and compact below 34 px while dragged.
- **Every track's height at once:** Shift + drag on a bottom edge, the toolbar's height menu, the zoom bar's slider or an upright pinch on the lanes (the global default, which tracks without their own follow, as do the theme's header styles).
- **Collapse ▸ in the track menu** applies to the menu's track: the arranger selects one track at a time today. **[Open (owner)]** whether a multi-track selection should come.
- **A folder's chevron** draws its contents as thin bars instead of hiding them; their own states come back when it opens.
- **The upright meter** starts below a 120 px header.
- **The piano roll's playhead:** the roll draws the song's playhead while the song plays its clip (opened for a clip, along that clip's repeats; in Build, the first unmuted clip of the pattern under the playhead, wrapped to its loop) and follows it by the same rule (`FollowGate`) and style as Arrange. There is no follow control in the transport to put the style in; it is in Settings › Editing.
- **One glide for view moves:** `ViewGlide` (`lib/ui/view_glide.dart`) moves a view's left edge and zoom together (zoom on a log scale; a zoom with no new left keeps the view's middle still), for both editors; ⏮ reaches it through `AppState.requestRevealStart()` (a counter, `revealStartRequests`, that the arranger and the roll listen to). A clip or track selected while out of view (the keyboard, a paste) glides in; one partly in view stays put.
- **A header's second tap where the first was** counts whatever is there now (on a phone the first tap pins the track on top and the focus panel takes its old place) and opens the first track's effects (`ClickCounter.secondHere`).

## 2026-11-11: Arrangement music video (owner)

**Decision (owner, 2026-11-11).** A built-in tool that records the arrangement as a good-looking music video, made to look cool rather than to be useful.
- **Shots, each switchable on or off:** an arrangement flythrough (the camera follows the playhead and notes light up), the mixer with live meters, piano-roll close-ups, and device editors with knobs moving to the automation.
- **Auto director:** pick a style (for example Calm, Energetic or Minimal) and the range. It cuts between shots on the beat and at sections. Optional title card. It uses the current theme.
- **Any aspect ratio and any resolution,** with presets for 9:16, 16:9 and 1:1.
- **Preview:** a quick unrendered preview before recording.

**Built (Claude, 2026-11-11; choices to confirm; [App](app.md) "Music video" has the behaviour):**
- **Offline and deterministic.** Frames come from one painter drawn off screen at the chosen size, at song time N / fps (never wall time), in step with the engine's offline song render of the range; meters come from per-frame peak and RMS of the rendered mix and track stems. The same project, setup and seed give the same frames (a test compares frame hashes).
- **Shots are drawn by dedicated painters**, not by the editing screens: the flythrough, mixer, piano roll and device views are drawn from the project in the theme's colours. Why: the editing widgets read the live transport, meters and gestures and couldn't be driven by a render clock without changing screens other work owns; one painter also makes the preview and the render the same picture. Open (owner): whether the shots should look closer to the real screens.
- **The director is seeded and uses note energy, not rendered loudness,** to choose mixer shots, so the preview (before any audio is rendered) cuts exactly as the render.
- **Format:** MP4, H.264 video at about 0.1 bit per pixel per frame (2–80 Mbit/s) with a key frame a second (Android), AAC-LC at 160 kbit/s, 48 kHz stereo.
- **Encoders: the platforms' own, no new package.** [Fact] Android MediaCodec, MediaMuxer and MediaCodecList are Android SDK APIs (developer.android.com reference pages, read 2026-11-11); Windows' H.264 encoder (Mfh264enc.dll, input I420, IYUV, NV12, YUY2 or YV12) and AAC encoder (Mfaacenc.dll, 16-bit PCM at 44.1 or 48 kHz, 1, 2 or 6 channels, 12,000 to 24,000 bytes a second) are Media Foundation transforms that ship with Windows 7 and later (Microsoft Learn "H.264 Video Encoder" and "AAC Encoder", read 2026-11-11). Both are called through the SDKs the app already builds with; C.A.W adds and redistributes no codec library, so no licence enters the project. [Assumption] the largest Windows frame is 4096 × 2304 until an encoder reports less; the Android limit is the first H.264 encoder's reported widths and heights, and the encoder chosen must take the exact size. Open (owner): codec patent terms for distributing the videos are the platform vendors' and the user's, not checked here.
- **Linux and tests** write a list of frame hashes instead of a video; no MP4 encoder there yet.

## 2026-11-11: A REAPER-style layout file (owner; design, questions open)

**Request (owner, 2026-11-11).** As REAPER's theme files and WALTER layouts do ([Fact] reaper.fm/sdk/walter/walter.php, read 2026-11-11), a code-only file should be able to change the app's look completely: where panels and menus are, which menus show, how menus open and how they animate.

**[Proposal]** The architect's design:
- a declarative, versioned text file (`caw-layout 1`) with bounded conditions (`when screen == desktop`, `width < 160dp`, read-only UI state) and no loops or code;
- per element, flow layouts: ordered slots with priorities, not WALTER's pixel coordinates;
- dock presets, toolbars, and menus by id (items from the action catalogue, how they open, style, motion token);
- declared params that become a "theme adjuster" in the theme editor;
- the built-in layout shipped in the same format;
- a broken or unknown file falls back to the built-in layout with a banner, and the file can never hide Settings, Reset layout or the section switch;
- edited in Build with live reload, completion and diagnostics.

The phases:
1. the parser, the evaluator, dock presets, toolbars and menu style;
2. menus as data;
3. element layouts;
4. params;
5. motion;
6. completion and sharing.

**Owner's answers (2026-11-11):**
- **Both:** the layout is part of the theme file, which is the whole theme. The theme editor can still change everything a theme supports, in any theme, not only your own.
- **One home:** toolbars and menus move from the key bindings into the layout. Key bindings keep only keys and macros.
- **No hiding:** a layout may reorder and collapse things (into ⋯ or overflow) but never hide features.
- **Flow and priorities,** not coordinates.

Still open: custom labels, layouts inside project packages, and one file for every screen shape or one per shape. Until answered: no custom labels, a packaged layout is offered and never applied silently, and one file uses conditions.

## 2026-11-11: A theme editor that builds the theme for you (owner)

**Decision (owner, 2026-11-11).** Today's theme editor is detailed but hard to use.
- **Palette builder up front:** pick one or two colours, or a mood, and it generates a complete, good-looking palette for light and dark (surfaces, text, accents, track colours, meters). Contrast is kept readable, and the palette can be shuffled and tweaked.
- **Every colour stays editable** in an advanced section.
- **The theme also sets the feel:**
  - haptics (on, strength, style);
  - how sharp or soft corners and buttons are;
  - fonts and text size;
  - how tracks look (height, header style, clip shape);
  - glow, glass and motion.

  The aim is a workspace that feels like home.

**How it is built (Claude, 2026-11-11; choices for the owner to confirm):**
- **Meter colours** get no slots of their own: meters draw in their track's colour, the warning accent and the danger accent (`pink`, kept red to magenta by the builder) at 0 dB, so the builder's track ramp and accents colour them. New slots would need every old theme file to fall back.
- **Header style** is a preset of the existing header width and track height (Compact 112 px × 48 px, Roomy 200 px × 88 px), not a second header layout.
- **One radius token:** the corner roundness also squares off device knob caps below 100% and sets clip corners (Rounded = 5 px × roundness; Square and Round are the other clip shapes). Arrange's audio clips and many fixed corners don't follow it yet.
- **Haptic style** is Light (as designed), Firm (1.6×) or Off per kind, on top of the strength.
- **Animation style** (owner's follow-up of 2026-11-11): pace, curve, entrance and exit as theme tokens; Subtle and Playful became two of its looks, Standard keeps the app exactly as it was, and Reduced and Off keep their rules.

## 2026-11-11: Light and dark for every built-in theme (owner)

**Decision (owner, 2026-11-11).** The built-in themes become four families, each with a light and a dark version:
- **Neon** (today's Calm neon);
- **Dusk** (today's Night, renamed);
- **Dawn** (new, Dusk's light-hearted counterpart);
- **Amber** (today's Amber terminal).

One switch picks light or dark for whichever family is chosen, so nothing is set up colour by colour. The light and dark versions keep the family's character, and their accents stay recognisably the same, with no jarring colour differences. **[Proposal]** The switch also offers "Follow the system", which tracks Android's and Windows' dark mode. A custom theme profile can carry a light and a dark palette too, and it keeps its look and layout settings when the switch flips.

- Flat (owner, 2026-11-11): Neon's counterpart, a standard DAW look without glow or glass.
- **How it is built (Claude, 2026-11-11):** light palettes come from one generator (`lightFrom`, its reverse `darkFrom`; [App](app.md)) that keeps each hue and moves lightness until WCAG AA holds on every surface (4.5:1 text, dim and accents; 3:1 track colours), so a custom theme's "Make light version" is the same algorithm. Dawn is designed light first and its dark palette is generated. Dusk dark's dim text moved from #6C6C80 to #7E7E93 to pass 4.5:1 on its raised panels. Follow system is built. Flat's no-glow, no-glass and solid fills belong to the theme, not the profile, so the user's Glass switch and glow strength come back on leaving Flat.
- **Flat's references (read 2026-11-11), not copied:** [Fact] Ableton Live 12's manual (2.3.2 "Theme & Colors", ableton.com/en/live-manual/12/first-steps) offers colour schemes with a light or dark appearance or the OS's, a warm, cool or neutral tone, and high contrast. [Fact] Bitwig's user guide ("User Interfacing", bitwig.com/userguide/latest/user_interfacing): an active control is tinted orange, an inactive one uses a neutral colour such as white, grey or silver. [Fact] REAPER's theme development reference (reaper.fm/sdk/walter/images.php): a theme file controls the colours and fonts of much of the interface, with its default theme as the example. Flat takes the shared idea (neutral grey surfaces, one restrained accent per role, state shown by tint) with its own values; no theme file or exact colour of theirs is used.

## 2026-11-11: Finding things on a phone (owner)

**Decision (owner, 2026-11-11).** Too many views and menus can only be found on desktop; the owner found the Build and Files tools only there.
- **Back arrow:** full views such as Track cards get a ← Back in their header row, and Android's back gesture also returns to the arrangement.
- **⋯ More per section:** each section's top bar gets a visible ⋯ that lists every view and menu the section has.
- **Search everything:** on phones, a search finds any command or view by name, like the desktop command palette.
- **Hints on first use:** a one-time tip points out hidden gestures (hold, double-tap, swipe) the first time each screen opens, and Settings can turn the tips off.

## 2026-11-11: What agents may do on GitHub and in git (owner)

**Decision (owner, 2026-11-11):**
- **Merging is allowed:** agents may merge local branches into the session branch.
- **Issues:** agents may close, label and comment on issues in this repository when the work they track is done or superseded.
- **Deleting branches** needs the owner's express direction or approval every time, so those commands always ask.
- **Where it lives:** `.claude/settings.json`, in `permissions` and in the `autoMode` allow notes.
- **Main is protected** (owner, GitHub rules, 2026-11-11): changes reach Main only through a pull request, and Main cannot be deleted. Work goes on the session branch and into Main by pull request.

## 2026-11-11: Desktop plays to desktop strengths (owner)

**Decision (owner, 2026-11-11, after a desktop review with screenshots at 1366×768 and 1920×1080).** Phones stay exactly as they are; on desktop:
- **Ctrl+S saves everywhere.** Moving a track up or down becomes Alt+Up and Alt+Down. WASD stays for everything else.
- **A left-drag on empty space selects, at once.** In Arrange it draws a time selection; in the piano roll it draws a selection box. A middle-drag or Space+drag pans.
- **A click selects at once.** A double-click on a clip opens its notes, and a right-click opens the menu. On phones, a double tap still opens the menu.
- **Desktop look changes:**
  - a command palette (Ctrl+Shift+P);
  - the project menu as a dropdown that shows shortcut keys;
  - compact right-click menus (keys shown, never off screen);
  - device editors as non-modal, resizable floating windows (several open at once, sizes remembered);
  - the mixer as a dockable panel (Ctrl+M) with wider strips;
  - Settings and the theme editor at a readable width;
  - the full-screen piano roll fitting the pattern, with a title bar and close;
  - a bottom dock area, so the focus panel doesn't squeeze the lanes.
- **Behaviour fixes that need no look change:** a mouse drags at once, right-click does whatever a long press does, the wheel turns knobs, Esc closes pages, and Windows remembers its window and accepts files dropped from Explorer.

## 2026-11-11: MIDI clip loops and clip automation, how they are built (Claude, to confirm)

Carries out the first two bullets of the owner's decision below ([App](app.md)). the loop point is `ClipDoc.loopSteps` (`loop_steps` in the engine's project JSON, 0 = the pattern's length, so older projects play the same). Clip lanes keep points in clip time and the app unrolls them onto the timeline for the engine: inside a clip its lane plays, elsewhere the track's lane on the same target (or the control's value); where clips with lanes on one target overlap, the later-starting one wins until it ends. Move to clip takes the track lane's values over the clip's first loop and removes the track lane. Clip automation is not drawn in Arrange's clip bodies yet.

## 2026-11-11: MIDI clip loops, clip automation and project packaging (owner)

**Decision (owner, 2026-11-11, answers to Claude's questions):**
- **MIDI loops as in REAPER.** In REAPER, a looped item repeats at its source's length ([Fact] cockos.com/wiki "Loop Source", read 2026-11-11). Here each **clip** has its own loop point, a bar dragged in the piano roll. A clip longer than its loop repeats from that bar, so a pattern can be written at any length and looped at any point. Clips that share a pattern can loop at different points.
- **Clip automation** belongs to the clip. It loops with the clip's MIDI and moves and extends with it, so it never needs redrawing after the clip is lengthened or moved. Track automation along the timeline stays for song-wide moves. Lanes drawn on a clip are clip automation by default, and a menu moves a lane between the clip and the track.
- **Project packaging.** The `.caw` project file (#159) always carries the project's C++ source. On export, the user can also package samples and audio (clips, sampler and drum samples, impulse responses), built C++ binaries for this device, third-party plug-ins (only where their licence allows; otherwise they are listed as needed), user presets, and the theme profile.
- **Export shows a checklist** of every dependency: its type, what uses it, its size, and whether it was found. Each has a package box, and Package everything sits at the top.
- **A project opened with something missing** opens with a banner naming it, offering Locate… and Replace…. The parts that need it stay silent until they are fixed.

## 2026-11-11: Theme profiles and edit animations (owner)

**Decision (owner, 2026-11-11, answers to Claude's questions):**
- **A theme is a full profile:**
  - **look:** colours, fonts and size, corner roundness, glass, glow and density;
  - **layout:** track height and header width, panel sizes, the dock layout, and the toolbar buttons' order and visibility;
  - **behaviour:** gestures, menu style, haptics, motion and snap defaults.

  Switching theme switches all of it. Profiles can be saved, duplicated, imported and exported, as colour themes are today.
- **Edit animations:** anything an edit adds, deletes, moves or resizes animates. That covers notes, clips and tracks, lengths and sizes, and panels. The style is the user's choice, Subtle (the default) or Playful.
- **Turning animations off:** one switch turns off every animation except the ones that help use the app (drag ghosts, snapping, press feedback). Each kind of edit animation also has its own switch (`EditMotion` in `app/lib/ui/motion.dart`).

## 2026-11-11: Touch editing in Arrange and the piano roll (owner)

**Decision (owner, 2026-11-11, answers to Claude's questions):**
- **Clips:** a long press on a clip picks it up whole (no stretching) and drags it in time and onto any track, snapping to the grid (Shift or a resting second finger frees it, as elsewhere). It can't go before the project start. A **double tap** on a clip opens the menu the long press used to open; a tap on an already selected clip opens its editor (owner, 2026-11-11, "Track headers that shrink…").
- **Tracks:** a long press on a track header picks the track up for reordering. Following REAPER, a plain up and down drag only reorders. Dropping with the finger in the right-most third of a track nests the dragged track under it: any track can be a parent, and the routing follows (the child feeds its parent). A hold let go without moving opens the track menu; a double tap on a header opens its effects (owner, 2026-11-11, "Track headers that shrink…").
- **Piano roll paste** lands right after the end of the copied selection, and the pasted copy becomes the selection, so repeated pastes chain end to end.
- **Selection box:** a long press on empty grid (about 0.35 s, with a haptic tick), then a drag, draws a box that **adds** to the selection. A double tap on empty grid clears the selection, so a stray tap can't. Undo can take back a selection the box just made. The select tool stays as it is.
- **Tremolo and ratchet tools:** a ratchet count per note (2–8 even repeats with a velocity ramp), a **ratchet brush** (drag over notes to set their count), tremolo as a volume wobble, a **vibrato** tool (pitch), and curve handles on pitch bends.
- **Advanced menus** (the note menu, the piano roll's ⋯, the Arrange menus): grouped into sections with the most-used items first. Numbers get a big slider, a type-in field and a reset.
- **Build** can open anything text-based, but its focus is C++. It opens on C++, and it should be clear that C++ is what it is for.

**How Arrange does it (Claude, choices to confirm; [App](app.md)):**
- **A plain track becomes a parent by turning into a bus folder** (`makeParent`): it keeps its id, effects, sends, fader and volume and pan lanes, so what it nests plays through them as in REAPER, and its instrument and clips move to a new first track inside it of the same name. The engine's bus slots only sum and run effects; letting a bus also play an instrument is an engine change left for later, so the parent's own clips are not on its row as in REAPER.
- **A second finger frees a long-press lift from the grid**, as the owner asked; it still makes a copy during a quick drag (the earlier choice), and the clip menu duplicates.
- **The double tap replaces the clip's old double tap** (which opened its notes): the menu's first entry, Edit notes, does that. No tap waits for the double tap (owner, 2026-11-11: "significant delay between the selection and the track actually lighting up"): the first tap selects at once and a quick second tap adds the menu (`ClickCounter`, no double-tap recognizer in the gesture arena). A header's tap opens the focus view at once, and its second tap counts anywhere on the pinned track the first tap moved (owner, 2026-11-11). Only a finger's tap on an already selected clip holds back the editor it opens for the double-tap time, since the editor moves the clip out from under the second tap; the selection itself shows at once.
- **The menus' numbers:** the track menu's Volume (dB) and Pan apply live; the clip menu's Length (bars) applies when let go or entered, since it rebuilds the project.
- **Audio clips** (done, 2026-11-11, branch `clip-loops`) follow the same rule (`app/lib/ui/arrange/audio_clip_view.dart`): a long press lifts the clip whole (edges included) onto any track on the grid, never before the project start, a resting second finger freeing it; a double tap or a right-click opens the menu, whose first item opens the Clip tab.

## 2026-11-11: Audio review fixes: declick lengths (to confirm)

**Decision (Claude, for the owner to confirm; [engine](engine.md#audio-clips)):**
- **Clip voices declick over 4 ms** (to confirm): a voice cut by a seek, loop wrap, stop, mode change, mute or edit fades out over 4 ms while one starting mid-clip fades in over 4 ms; a clip's loop seam crossfades over 4 ms. A voice starting at its clip's start is left as authored (no fade), so a clip's own attack is unchanged. The review asked for 2–5 ms.
- **The sampler fades stolen voices and voices of replaced zones over 5 ms** (to confirm), and steals the oldest releasing voice before the oldest held one.
- **SFZ export copies only WAV, FLAC and MP3 files** (by extension and first bytes, up to 1 GB), named uniquely against `samples/` without regard to case: a project's zone paths are untrusted and could otherwise copy any readable file into the exported folder.
- **Recording splits a take into a new file before 4 GB** (WAV's 32-bit sizes) rather than writing RF64, so every take stays a plain WAV the decoders and other apps read.

## 2026-11-11: Audio assets, clips, sampler and input (WP-J; choices to confirm)

**Decision (Claude, for the owner to confirm; the owner put all three in the beta, see below; [engine](engine.md#audio-assets-clips-the-sampler-and-audio-input-api-18)):**
- **Decoders: miniaudio's bundled dr_wav, dr_flac and dr_mp3**, already vendored (miniaudio 0.11.25; [Fact] the file's licence block, read 2026-11-11: "a choice of public domain or MIT-0", which covers the dr_libs code it carries). No new dependency. They are compiled a second time inside the core with every function `static` (`platform/decode_miniaudio.c`), so the core decodes in builds without device audio and never clashes with the device copy.
- **Time-stretch: our own WSOLA** (Verhelst and Roelands, ICASSP 1993), not a library: [Fact] Rubber Band is GPL with a paid commercial licence (breakfastquay.com/rubberband, read 2026-11-11) and SoundTouch is LGPL v2.1 (surina.net/soundtouch, read 2026-11-11), both excluded by the licence rule. WSOLA is cheap and keeps transients; a phase vocoder for sustained tonal material is left for later. Varispeed (resampling) is the second mode.
- **An audio track is a layer with `audio_clips`/`input`, played by a built-in instrument** (`org.caw.audio-track`), so clips get the track's inserts, sends, buses, keys, latency compensation and every render path without new mix-graph code. A layer plays an instrument or audio clips, not both.
- **Assets are referenced by absolute path** (a project `assets` table, or a clip's `path`), shared process-wide within a 1 GiB budget; sampler zones name paths in the sampler's state JSON, whose keys mirror SFZ opcodes so import and export are one-to-one.
- **Monitoring goes through the track's chain**, in the same duplex callback; `auto` monitors while armed and stopped, or while recording.
- **Takes:** WAV float by default, one file per armed track per take, a new take at each loop wrap, placed by the round-trip latency (override, then the last good ping, then the device's buffer estimate, an [Assumption] until measured on the S22+).
- **App side (Claude, 2026-11-11, branch `audio-ui`; to confirm in the APK):** imports are **copied** into the project's own `audio/<project>/` folder (so a project never depends on a file elsewhere, and deleting the project deletes them); **recordings** go to its `recordings/` folder inside that, and a crash's takes are offered back when the project opens (or kept in Files). Audio dropped on a track with an instrument or MIDI clips goes on a **new audio track under it** rather than replacing anything. A **fixed** clip stores its length in seconds (`length_seconds`), so the app never has to re-fit lengths after a tempo change. New clips have **no edge fades** (as the engine); a loop recording's passes become **one clip with takes** (the newest playing), not stacked lanes, so comping is swapping whole takes for now. The input choice, latency override, punch and take format are **app-wide** (`audio-input.json`), not per project. The latency ping asks first every time until the user ticks *Don't ask again*. Mixed MIDI and audio selections split only their MIDI clips.
- **Open (owner):** a default edge fade (REAPER-style 1 ms or none); whether a musical clip's default stretch is WSOLA (it is); whether recordings should stay with the project (as now) or in a shared library; whether loop takes should show as stacked take lanes for comping; whether imports should be referenced in place instead of copied (saves storage, breaks if the file moves).

## 2026-11-11: the app stops using .caw (WP-C; choices made for the owner, to confirm)

- **Engine Lab moves to Settings › About and beta as "Engine diagnostics"** (to confirm with the owner; #139 says "Settings or a debug view"). It keeps the meters, the master scope and spectrum and each track's signal path; the .caw module report went with the language.
- **Mixer, Automation and Exporter are retired as workspaces** (#139 step 4). The mixer is Arrange's mixer card on every screen size, now with the master strip (master FX, level, meters) at its start; on desktop it replaces the docked volume/pan strip and the Mix layout preset. Track automation is the focus view's Automation tab and the lanes under tracks; the .caw module-parameter and global lanes are gone. Export is a page from the project menu (Export…, Ctrl+3) holding the Export song sheet and the loop, length, one-shot, wavetable and MIDI exports, profiles, history and queue; the wavetable export sweeps a track's C++ instrument (engine API 17). The phone's ⋮ More button went, having nothing left to list.
- **Old projects:** a project with .caw sound modules loads with them, their tracks' .caw chains, the globals and their lanes dropped, and a one-line yellow banner names them (owner, 2026-11-10: old projects are dropped; the app must not crash). Patterns stay (#158).
- **Settings › Code editor** drops the rows that only served the .caw editor (completion chips, the Library button, compact controls); their stored values stay in `settings.json` until WP-D.
- **Templates:** the C++ starters replace the .caw templates in Files (New from a starter…) and the track cards' Add track; the two pattern templates (acid line, chords) are bundled in Dart so the engine's `caw_templates` is no longer called.

## 2026-11-11: Per-note FX host, sources, C API and app (#127 steps 4–7; choices to confirm)

**Decision (Claude, from the architect's design; [architecture](architecture.md#the-per-note-fx-host-notefxhost-fact-steps-47-branch-note-fx-host-2026-11-11), [engine](engine.md#per-note-fx-host-127-steps-46)):**
- **Overflow is a lane, not a side path:** the voice bus gains `CAW_LANE_REST` (note id 0), the lane every voice without its own slot renders into, so the overflow chain hears exactly the unassigned voices. An instrument built before the bit plays those voices dry; it is a 3.1 addition, not a new revision.
- **B + 2 chains:** two spare slot chains let a stolen slot fade out for 10 ms while the new note starts on a fresh chain; with the spares busy the note goes to overflow. "Oldest released" is the released note that started first.
- **Time in frames, not blocks:** a slot's chain starts on its note's frame and its tail runs max(declared tail, 128 frames), capped at 2 s, past the note's last sound, then fades; so playback at any buffer size and an export give the same bits. `quiet()` alone doesn't free a slot (it is learnt at block ends).
- **Budget read at each note-on** (not at the next project update): a quality change applies to the next notes; slots are allocated for B.
- **API 22**, leaving 20 and 21 to parallel branches (delete-caw); per-note components are addressed with a bit on the component index (`CAW_NOTE_COMPONENT`) rather than new setter functions; per-note components keep no saved state.
- **Note sources as link sources** (`note.pitch` … `note.age`, target `noteComponent` only); pitch reads pitch / 127, age runs 0 to 1 over 2 s: first choices.
- **To confirm (owner, in the APK):** (1) the look: the PER NOTE section above the track effects with a voice-budget chip and slot dots, violet per-note cards, and Run per note / Run on whole track in the card menus (or a per-card toggle only); (2) over budget, overflow to one shared chain (built, the default) or steal the oldest held note; (3) the default budget per phone (8; Eco 4, High 16) after a CPU measurement on the S22+; (4) the name and range of the age source (0–2 s).

## 2026-11-11: Per-note FX steps 1–3 and descriptor domains (#127, #120; choices to confirm)

**Decision (Claude, from the architect's design; [architecture](architecture.md#per-note-processing-127-and-descriptor-domains-120)):**
- **No v4:** the new descriptor fields and the voice bus are C interface revision 3.1 under the v3 growth rules, so `caw_get_component_v3` and every 3.0 component keep working (they read as whole-only).
- **Named "domain", not "scope":** `CAW_SCOPE_*` is already the oscilloscope in `caw.h`.
- **Whole is always set**, and the C++ SDK default is whole-only: a third-party effect runs per note only when its author declares it (a silent opt-in could run unprepared state per note). The built-in stereo effects opt in; keyed effects, the racks and the limiter do not.
- **Lanes are summed before the instrument's shared stage**, so turning per-note FX on does not change the instrument's own effects and volume, and with no bus the sound is bit-identical. The Flagship calls `run()` once per control period (16 frames); step 4's host must handle such short runs cheaply.
- **ENDED means no voice plays the note at the block's end**, raised every such block (also for a lane assigned before its note starts), so the host never waits on a note the instrument dropped. Mono and legato lanes follow the note the voice plays now. A drum hit's room send stays dry.
- **`org.caw.downmix` is new and internal:** `org.caw.utility`'s Mono mode is stereo in and out and cannot feed a mono port; the downmix is unlisted while track chains take stereo only. Dual mono is `ModuleRegistry::createDualMono`, an adapter, not a graph feature.
- **The listing** adds `domains`, `capabilities` and `cpu_class` (snake_case like its other keys) to `caw_engine_components`; no new function, so the API number stays 17 (step 6 took 22).
- **Cost classes are judged, not measured** ([Assumption] until the S22+ measurement).
- **To confirm (owner):** the name "domain" in the UI (the app says "Run per note" / "Run on whole track"); the look and budget questions are in the steps 4–7 entry above.

## 2026-11-11: Modulators and routing anything to anywhere, #161 (choices to confirm)

**Decision (Claude, for the owner to confirm in the APK; [engine](engine.md#modulation-project-modulators-and-links-161), [ui](ui.md#modulation-on-touch)):**
- **One model.** Project links reuse the racks' and Flagship's route record and rules (amount and polarity of the knob's normalized travel, summed per knob, base value untouched), widened to (layer, component index, parameter) and to volume, pan, sends and other modulators, plus a per-link curve. The shared arithmetic is `engine/src/mod_route.h`; the FX rack calls it. A device's internal matrix stays (its per-voice sources, such as Flagship's envelopes, can't be project-level).
- **A project-level `modulators` list**, each with a `layer` (where it is shown) and an `input` (what it hears), rather than modulator components inside track chains: chains stay audio-only, and a modulator on one track can hear another.
- **Modulators live in a "Modulators" lane at the bottom of each track's FX stack** (the master's holds the project's), not on a separate strip. To confirm: the owner may prefer a strip in the mixer or the Arrange view.
- **Timing: a fixed 16-frame grid from Play and a 96-frame (2 ms) look-behind**, instead of ordering tracks so a source runs before its target in the same block: block-size independent, export equals playback, and the mix graph's order (sends, keys) is untouched. A follower is 2 ms late, which is below any envelope's attack. Modulators restart at each Play.
- **Loops are refused** like routing loops, through followers only (notes make none, so an envelope can move its own track); a follower moving its own track is refused (to confirm: self-ducking could be allowed later, it is stable with the look-behind).
- **Volume and send links move the fader's travel** (the app's REAPER-like taper, 0 dB three quarters up), pan its −1..1 travel; master volume takes no links yet.
- **Budgets:** 64 modulators, 256 links, 32 links per knob, 8 outputs per modulator.
- **C API version 19** (18 is the audio-engine branch's); merge both and keep 19.

## 2026-11-11: MIDI devices (WP-H; choices made for the owner)

- **The engine path:** device MIDI reaches a track's instrument through a new C API (API 15) into `Midi2InputQueue`, placed at the frame it was played from the device's timestamp, one callback late so the spacing is kept (Android's MIDI timestamps are `System.nanoTime`, the engine's `steady_clock` on Android). On-screen keys keep note previews. MIDI 1.0 is converted to MIDI 2.0 at the edge (`midi_device.cpp`, the UMP specification's min-centre-max upscaling written from the published algorithm, [Assumption] not re-read against the PDF).
- **Device notes are previews with their own id range**, so everything that ends previews (Stop's fade, mute) ends them, but the app's notes-off backstop for the on-screen keys does not.
- **Controller learn maps in the app, not through F6.5:** a mapped CC calls the knob's live path (`DeviceTarget.setLive`, the same as a drag) on the knob's curve, as F6.5's rule says, and is not passed on. F6.5's `setCcMappings` belongs to graphs that take host events, which the Engine's live mix graph does not get from devices; doing it there would mean re-preparing the graph while stopped. Revisit if CC timing must be sample-accurate.
- **Android facts [Fact, developer.android.com, checked 2026-11-11]:** `MidiManager.getDevicesForTransport` and `registerDeviceCallback(int, Executor, DeviceCallback)` are API 33 with `TRANSPORT_MIDI_BYTE_STREAM` (1) and `TRANSPORT_UNIVERSAL_MIDI_PACKETS` (2); a MIDI 2.0 USB device shows both interfaces; UMP bytes arrive 4 to a word in network order; `MidiDeviceInfo.getDefaultProtocol` (API 33) returns `PROTOCOL_UMP_USE_MIDI_CI` (0) or `PROTOCOL_UNKNOWN` (-1) when MIDI-CI is needed. C.A.W reads a UMP interface only with a pre-negotiated protocol and then leaves that USB device's MIDI 1.0 interface closed. BLE MIDI: scan filter on service UUID `03B80E5A-EDE8-4B33-A751-6CE34EC4C700`, then `openBluetoothDevice`, kept open (android.media.midi package summary and `MidiManager`). Permissions: on Android 12+ `BLUETOOTH_SCAN` (declared `neverForLocation`) and `BLUETOOTH_CONNECT` are runtime permissions; legacy `BLUETOOTH`, `BLUETOOTH_ADMIN` and `ACCESS_FINE_LOCATION` are declared with `maxSdkVersion 30` (Bluetooth permissions page). Asked only when the user starts a scan.
- **Windows: WinMM through dart:ffi**, not the runner: the binding compiles on every platform (so `flutter analyze` and the tests check it here) and needs no C++ in the runner. [Fact, learn.microsoft.com, checked 2026-11-11]: `midiInOpen` with `CALLBACK_FUNCTION`; `MIM_DATA`'s dwParam2 is milliseconds from `midiInStart`. Constant values and `MIDIINCAPSW` layout are from the SDK headers as known [Assumption]. **Windows MIDI Services is not used:** it needs its own SDK runtime and service on Windows 11, not a modest change; WinMM keeps working beside it.
- **Open (owner):** which device wins when several play at once (today every device not turned off plays the target track); whether a mapped CC should also reach the instrument; soft takeover for mapped knobs.

## 2026-11-11: Arrange and mixer leftovers, WP-K1 (choices to confirm)

**Decision (Claude, for the owner to confirm in the APK; [App](app.md), [REAPER flow](reaper-flow.md)):**
- **The master is a stand-in track** (`masterLayerOf`, id `\u0000master`) whose effect list *is* `ProjectDoc.masterComponents`, so the FX stack, device editors and live displays open master effects without a second code path; the engine gets the null layer. Sidechain keys and track presets are hidden on master effects ([Assumption] the engine's master chain takes no key; not checked).
- **Mixer strips now list C++ effects too** (they showed only the .caw chain), since FX drag between strips needs them; a C++ slot opens its device UI, a .caw slot the inspector as before.
- **FX drag copies by default, Alt or Shift moves** (REAPER, UG 11.5: drag copies, Alt-drag moves); on a phone the copy's toast offers **Move**. A copied .caw effect gets its own module so its knobs are its own.
- **Region drag:** a plain drag still moves the region alone (unchanged); Alt takes its clips, Ctrl or a second finger copies region and clips (the plan's phone gesture). "Clips in a region" are those that start inside it, moved whole. [Assumption] REAPER's exact default for a region drag was not checked.
- **1–0 take the digits from counts in the arranger:** a digit an area binds on its own runs that action unless a count is already being typed, so `4]` no longer works in the arranger while 1–0 are bound (unbinding them in Key bindings brings counts back). The roll and code editor keep digit counts.
- **Templates:** `new_project_template` replaces `new_project_start` (the old First loop choice carries over); saved templates are JSON files in `<app support>/templates/`; saving under an existing name replaces it; inserted track templates go at the end of the list with fresh ids and copied modules. Bundled starters: First loop and Song sketch; tracks Drums, Bass, Keys, Pad and Reverb bus.
- **Record modes:** a setting (`midi_record_mode`, default *New clip, takes*, the earlier behaviour) on Record's long-press. Overdub and Replace write into the clip under each note (its pattern, so linked clips change together, as REAPER's pooled items); notes outside any clip make a new clip; locked clips are left alone. Next/Previous take have no default keys because T is tap tempo.
- **Lane arm** is per lane and saved only when off (`armed: false`); a control with no lane is still written (REAPER's "add envelopes for controls tweaked in write mode").
- **No app track cap:** the engine's `maxLayers()` refusal (349 layers at the fallback budget) is the only limit, shown as the engine error.

## 2026-11-11: Song renders and stems (choices to confirm)

**Decision (Claude, for the owner to confirm; [engine](engine.md#song-renders), [app](app.md)):**
- **A stem is what a track or bus sends on** (after its effects, volume, pan and latency compensation), **with the master's volume, DC filter and start fade but not the master's effects or limiter** (`stems_through_master`, on by default). Why: the stems that reach the master then add up to the mix, and the levels match it, as REAPER's stems of the track outputs do; master effects can't be split per stem.
- **Normalising takes one gain from the mix for every file** (`normalize_each` off), so normalised stems still add up; LUFS normalising stops at a −1 dBTP true-peak ceiling by default.
- **One pass per range renders every file of it** through engine output taps (a small offline-only hook in `engine.cpp`), rather than one render per stem: the stems line up by construction, and a phone renders ten stems for the cost of one.
- **Results stay in the app's support folder until saved** (Save, or Save all into a folder through the system's folder picker); they don't appear in Files yet.
- **The sheet keeps the old Exporter** (Quick Export, one-shot, wavetable, MIDI) below its Export song button, rather than replacing it.

## 2026-11-11: VST3 interface headers for the plug-in builder (#162)

- **Licence [Fact, checked 2026-11-11]:** Steinberg's VST3 SDK is MIT. The `LICENSE.txt` of `steinbergmedia/vst3sdk`, `vst3_pluginterfaces`, `vst3_base` and `vst3_public_sdk` (default branches, read 2026-11-11) is the MIT License, "Copyright (c) 2026, Steinberg Media Technologies GmbH"; the `vst3_pluginterfaces` tag `v3.8.0_build_66` (commit `31d6eeba`, 2025-10-20) already carries it, so the change came with VST 3.8.0. No GPL or proprietary licence remains on the parts used.
- **Dependency:** `steinbergmedia/vst3_pluginterfaces` **v3.8.1_build_84** (commit `4f547e8e`, 2026-08-11, the latest tag on 2026-11-11), MIT. Only the interface headers and two of their files (`base/funknown.cpp`, `base/coreiids.cpp`) are compiled; the SDK's helper classes, VSTGUI and the validator are not fetched. Fetched at configure time by `caw_add_vst3_plugin` (`engine/cmake/CAWVst3.cmake`), not vendored, not in the app or the engine library; the build stops if the fetched `LICENSE.txt` is not MIT.
- **Why:** VST3 is the export target after CLAP (roadmap 9.3): the same component library builds as a `.vst3` bundle through a second wrapper around the C interface ([native module SDK](native-module-sdk.md#export-as-a-vst3-plug-in)).
- **[Assumption]** the "VST" name and logo are trademarks with their own usage guidelines (the repository README's "License & Usage guidelines"), separate from the code licence; C.A.W does not use the logo. Not checked further.

## 2026-11-11: The Drums editor (choices to confirm)

**Decision (Claude, for the owner to confirm; [UI](ui.md#device-editors), [app](app.md)):** the editor follows the owner's layout (stacked layer cards under a pad grid, a draggable hero, a Character strip). Choices made on the owner's behalf:
- **Pads** read MPC-style, pad 1 at the bottom left; the picked pad sets the engine's `view_pad`, which no longer marks a preset as edited (it is a view setting).
- **Explode moves the notes** out of the drums track's clips onto the new tracks (a clip's pattern is copied first, so a shared pattern is untouched); pattern notes count as channel 1 for a pad on a channel. **[Assumption]**
- **Per-layer randomize and mutate** take the engine's whole-pad result and apply only that layer's knobs (no new C API).
- **Samples picked from the device are copied** into app storage (`drum_samples/`); a project names them by that path.
- **A component entry keeps up to 16384 parameter values** (the drums' 10392 with room); 256 cut a kit short when a project or an undo step was read back.

## 2026-11-11: One drum instrument, built (choices to confirm)

**Decision (Claude, for the owner to confirm; [engine](engine.md#drums-orgcawdrums)):**
- **Flat parameter ids, 64 pads × 162** (`a1_body_freq` .. `d16_rnd_pos`, 10392 in all with the 24 kit-wide ones, each with a `group` tag). Why: every knob stays automatable, modulatable, MIDI-mappable and in presets and undo with no new machinery. The trade-off: a 2.9 MB descriptor for the app to parse, about 6 MB of parameter state per instance, and a knob page that must be built from the groups (no generic page can show 10392 knobs). The alternative, a pad's deep settings in the component's state with only a few automatable knobs per pad, keeps the descriptor small but loses automation of most knobs. **To confirm.**
- **The smallest descriptor extension:** `ParameterDescriptor::group` (a slash path, `"a1/body"`, `"kit/glue"`), emitted as `"group"` by `caw_engine_components` for built-ins only; the plain-C component interface is unchanged.
- **Explode to tracks, not multi-output (for now).** The instrument chain has one stereo output; carrying a component's extra outputs into child tracks needs the chain, the mixer graph and the project's routing changed. So the per-pad `out` is stored and the processor keeps nine buses (Out 2..9 skip the kit effects), and `caw_drums_explode` gives the app one Single-mode Drums per used pad, with the notes to move. Multi-output is a follow-up. **To confirm.**
- **Samples by reference in the project** (`"samples": [{"slot", "path"}]` or `{"slot", "builtin"}`), decoded by the engine on the control thread, instead of a call passing float data: the project then reloads and exports with its samples. Built-in samples are the library's sounds rendered by the engine (nothing to license). Mono, 30 s a slot, 64 MB an instance, WAV only. The app must copy a user's file somewhere it keeps (a `content://` file can't be opened by path). **[Assumption]**
- **Bank layout:** bank A's Auto notes are 36..51 (the General MIDI keys, so the kits' sounds sit where GM puts them), each bank the next 16, from a configurable `base_note`. The default kit (808) fills bank A; banks B..D start empty.
- **Defaults made for the owner:** the old drums' sounds carried over as closely as measured (their renders within 1 dB in level); centre-panned voices at full level on both sides (a balance, not constant power); the variation's sequence restarts at every Play, so a render repeats; a random sound is level-matched to about −1 dBFS; quality Eco/Normal/High sets the drives' oversampling (1/2/4×), the metal's band-limiting (none/polyBLEP/2× rate) and the resonator's modes (8/16/32).
- **API 11** (10 is the settings redesign's): `caw_drums_info`, `caw_drums_randomize`, `caw_drums_explode`, and the component entry's `samples`.
- **The deep settings ("Drums: deep settings and real quality", below), as built:**
  - **Extend, don't add a second instrument:** the new controls are new layers on every pad (`press`, `penv`, `sub`, and the effects split into `drive`, `filter`, `eq`, `dyn`, `space`), so a pad's ids went from 119 to 162; nothing shipped used the old layout, so `press_dest`/`press_amt` and `body_sub`/`body_sub_oct` were replaced (by one amount per pressure destination, and by the Sub layer) rather than kept beside them.
  - **The pitch-shape editor is four breakpoints** (time, semitones, curve per segment) next to the analog Curve mode, not a free-form drawing: it stays a set of automatable knobs. **To confirm** that four points are enough.
  - **The room is a send** now: each pad's `room_send` (default 1) feeds it, and `room` is its return level (it was a dry/wet mix on the whole bus); the Clean sub never reaches it. **To confirm.**
  - **Width keeps the low end mono** with a 4th-order high-pass on the side signal (`width_hz`, 200 Hz default), and a Clean sub is added after the pan, so it is always mono.
  - **The clipper's ceiling is exact** (a hard limit at full scale after the oversampled curve), on each pad and on the kit.
  - **Note learn is the app's job:** the engine reports the last note (key, channel, velocity, a count) in the display data; the app writes it into the pad's `note`.

## 2026-11-11: One drum instrument (owner)

**Decision (owner, verbatim):** "take all the drum plugs and make them in to one that can make any kick, hihat, snare, tom, crash, rimshot, etc. It should make all the drum sounds a drum can make and be extremely customisable. The kick should be more than it is, same with the hat, to the point that it's just crazy what it can do."
- **Structure:** "Make it work like a MIDI kit with pads, or just standalone, one sound per track": a Kit mode (pads on MIDI notes, a GM-style default map) and a Single mode (one sound per track, any note).
- **Sound source:** synthesis plus a sample layer. **Editor** (for the app): layers as stacked cards, a draggable waveform hero, a Character strip of macros.
- **Extras, all four:** randomize and mutate; per-hit variation (velocity layers and round-robin-style subtle changes); choke groups and per-pad outputs; pad and kit effects.
- **Later the same day:** 16 pads × 4 banks (A..D) = 64 pads, like an MPC; pads not used cost nothing and only sounding voices run. Pitch: "Both, switchable": a pitch tracking switch per sound (off a fixed pitch; on chromatic from the note, with a mono option and glide between overlapping notes, for 808 basslines), on Kit pads too. Samples: the user's files and a small built-in pack of one-shots the engine renders from presets (nothing to license), listed and loaded through the app. Outputs: "Each one will be routed to a specific note so you only really need one track to work it, but it should also allow an automatic create-per-track workflow. And have support for native pads and stuff like that, like hardware pads that use MIDI natively": one track by default with an editable note map per pad, an "explode to tracks" workflow, per-pad note learn, a channel option (e.g. 10), velocity, and polyphonic pressure as a modulation source (to choke or damp a cymbal by squeezing). The old kick, snare, hats and kit migrate to it.

## 2026-11-11: Drums: deep settings and real quality, every genre (owner)

**Owner's words:** "The drum instrument needs to have an in-depth set of settings and effects to make all the sounds extremely versatile and be actual good quality. Research how different kicks, snares, hats etc. are made and make sure it has all of the settings. You should be able to make a kick a legitimate dubstep kick, an 808 kick, or just a normal-sounding kick. Make it so it can even sound acoustic even though it's generated."

**What this requires of `org.caw.drums`:**
1. **Research per drum type, with sources.** Every control needed to build each sound must exist.
   - **Kicks:** dubstep/riddim (punch + sub + distorted mid, clipped, short click), 808 (long tuned boom with glide and saturation), techno rumble, trap, hardstyle, house/909, acoustic (beater, shell resonance, port, room).
   - **Snares:** 808/909; acoustic (head modes + wires, rimshot, ghost notes); claps; trap and dubstep layered snares.
   - **Hats:** closed, open and pedal; the 808 square bank; modal cymbals with choke and openness.
   - **Toms, cymbals (crash, ride, bell, china) and percussion.**
2. **Real acoustic realism:**
   - modal/physical layers with enough modes;
   - strike position and damping;
   - velocity changing the spectrum, not just the level;
   - per-hit micro-variation;
   - a room/body stage.
3. **Effects deep enough for these genres:**
   - multi-type distortion with pre/post filter;
   - a clipper, EQ, compressor and transient shaper;
   - a pitch-envelope shape editor;
   - a layered sub with its own envelope;
   - width that keeps the sub mono;
   - a room send.
4. **Quality checked numerically** against research targets (spectrum, pitch curve, decay, crest factor), with genre-accurate factory presets ("Dubstep kick", "808 kick" long and short, "Acoustic kick", "Acoustic snare", "Ride", "Crash", …).

## 2026-11-11: Finish the whole roadmap, then optimize, then a fit-and-finish pass (owner)

**Owner's words:** "Don't stop until everything in the roadmap is completely done. I want you continuously working… once everything in the roadmap is done, go and optimize everything so it's fast, it's quick and that it runs extremely well. Then make sure everything is user friendly. Don't change the layout or things in the app, just make sure it fits well in the UI."

**The order:**
1. Every roadmap item (beta scope above).
2. A performance pass across the engine and the app.
3. A user-friendliness pass that keeps the layout and features as they are and only fixes fit, spacing, overflow, labels and feedback.

## 2026-11-11: The beta's scope: the whole roadmap, plus drums, effects and audio (owner)

**The owner's words:** "Make sure everything in the roadmap is done. Including the routing and the hard stuff too."

**Owner's answers:**
- **Audio in the beta:** audio clips on tracks, audio recording, and a sampler instrument all ship in v1.0.0-beta.1. Before this, the roadmap put Stages 3, 4 and 7 after Release 1.
- **Per-note effects:** built for the beta (#127). Instruments expose per-voice audio, and effects can run per note.
- **New screens:** the modulator routing canvas, the testing suite, the sample-pack maker, CLAP export, the export sheet with stems, templates, and master FX slots. Each is designed in the existing device-kit style, and the owner reviews it in the APK; changes come after.
- **MIDI storage (#158), locked in:** clips are stored as pattern text in the project; standard MIDI files (.mid, including MPE) are used for import and export.

**Also decided today:**
- **Effects:** every Kilohearts-style effect is built in. That includes the multiband rack and the FX rack with modulators, and a browser with category tabs, search, favourites and recently used.
- **Drums:** one drum instrument (`org.caw.drums`) replaces Kick, Snare, Hats and Kit. Its structure:
  - two modes: a 16-pad × 4-bank kit, or a single sound per track;
  - layers: synthesis plus a sample layer;
  - pitch tracking per sound, switchable, with glide;
  - each pad on its own MIDI note, with an "explode to tracks" workflow;
  - hardware MIDI pads supported.

**Still the roadmap's call:** Stages 8–10 stay after Release 1: Faust, plug-in hosting, and iOS/macOS/Linux builds.

## 2026-11-11: Racks and the effect browser (fx-racks, choices to confirm)

**Decision (owner):** a multiband rack (as Multipass) and an FX rack with modulators (as Snap Heap); the browser's nine tabs, search, favourites, recents, a description and icon per effect. **Choices made on the owner's behalf, to confirm** ([engine](engine.md#racks-containers-fx-racks), [UI](ui.md#the-effect-browser)):
- **Children live in the rack's parameters** (`<slot>_fx` holds a 24-bit hash of the child's id, the child's knobs `s2.cutoff`), so the project file, presets, undo and automation needed no new format.
- **No racks inside racks**, so there is no depth to bound. **Sizes:** the FX rack holds 8 effects in one serial lane and has 16 routes; the multiband rack holds 4 effects a band. Snap Heap's parallel lanes, Multipass's Pre/Post FX lanes and per-lane mix, and modulators inside the multiband rack are not built; a multiband rack's knobs take automation, not modulation (a rack can't sit in an FX rack), until #161.
- **Fixed modulators** (4 LFOs, 2 followers, 2 note envelopes, random, 8 macros) instead of Kilohearts' free list of up to 32.
- **Modulation runs on a 16-frame grid**, as the Flagship's.
- **The modulation route record is meant to be reused for #161** (route anything anywhere): [Proposal] in [engine](engine.md#racks-containers-fx-racks); #161's design is still the owner's.
- **Browser:** an All tab before the nine; Favourites are the Files favourites; Recently used keeps the last 12 picks app-wide; an effect no catalog lists goes under Utility.
- **Factory presets:** FX rack Wobble filter, Dub space, Ducked delay, Drifting tape, Note sweep; multiband rack Multiband glue, Air exciter, Tight low end, Split space.

## 2026-11-11: Dynamics and Drive effects (fx-dynamics; choices to confirm)

**Decision (owner, 2026-11-11):** "any effect you would reasonably want is already there", Kilohearts-style; all four groups equally important. The Dynamics and Drive group added Dynamics, Multiband dynamics with an OTT mode, a De-esser, a Clipper and Phase distortion, and five curves, spread and dynamics to the saturator (see [engine reference](engine.md#dynamics-and-drive-research-and-technique-fx-dynamics-2026-11-11)). **Choices made on the owner's behalf, to confirm:**
- **Extend, don't duplicate:** the new distortion types are saturator modes (appended, so saved projects keep their mode), not a second distortion effect; expansion and upward compression live in Dynamics, not in the gate or compressor.
- **Multiband opens in OTT mode at 50 % depth.** OTT's per-band numbers are the commonly quoted ones for Ableton's OTT preset, not confirmed ([Assumption]).
- **Upward lift never spikes:** an instant-attack detector limits the lift, so the attack knob shapes only the downward side and expansion.
- **Clipper overshoot:** with oversampling and without Clip to 0 dB the output can pass the ceiling by a few dB (the IIR half-bands' phase); clipping again would bring the aliases back. Clip to 0 dB guarantees full scale. A linear-phase half-band would reduce the overshoot at the cost of latency (a follow-up if wanted).
- **Phase distortion's latency** is a fixed 48 frames (1 ms at 48 kHz), declared, so the swing is ±46 frames whatever the sample rate.
- **Not built:** an envelope follower as a modulation source (projects don't route modulation outputs yet); Bitcrush's ADC/DAC quality and dither, Faturator's color and stereo turbo, and Shaper's drawn curve as their own controls.

## 2026-11-11: Creative and Pitch & Time effects (fx-creative, choices to confirm)

**Decision (Claude, for the owner to confirm):** eight new built-ins (tape stop, reverser, stutter, pitch shifter, frequency shifter, trance gate, bitcrush, ring mod; [engine](engine.md#c-api-engineincludecawh)) with plugin UIs ([app](app.md)). No new dependency.
- **A ninth device family, Creative** (yellow → pink), for both browser tabs, so these read apart from the modulation family's pink → violet.
- **Tape stop's trigger is a knob** (`stop`, at or above 0.5 stops), so a lane or an LFO can trigger it, plus a hold-to-stop pad; Kilohearts has a Play switch. A start spins up from the tape under the head now (not where it stopped), and once at speed crossfades back to the live input over 12 ms, so the tape stop adds no lasting delay.
- **Reverser's longest chunk is 2 s** (a half note at 60 BPM), to keep its buffer modest on a phone (4 MB at 48 kHz, as the tape stop's 8 s; the stutter's 3 s slice takes 1.2 MB).
- **Pitch shifter: no formant-preserve mode.** It would need an FFT shifter with a spectral-envelope correction, or PSOLA with pitch detection: more latency and CPU. Its grain size sets its latency (half a grain), so the grain is not automatable or modulatable, as the ducker's look-ahead.
- **Frequency shifter's "Both"** puts the upper sideband on the left and the lower on the right (a stereo effect), rather than summing both (which is ring modulation, already the ring mod).
- **Trance gate:** one pattern (32 step levels saved with the device), not Kilohearts' eight pattern slots; Tie as a switch (a step after a sounding one doesn't retrigger) rather than per-step ties drawn by dragging.
- **Stutter** is not a Kilohearts snapin; built as a seeded beat repeat (Ableton's Beat Repeat is the model), with a hold pad for live use.
- **Ring mod** with a key: giving it a key turns its carrier to Sidechain, and removing the key turns it back to Sine. The sidechain key is the existing keyed-effect port (as the ducker's).
- **Bitcrush stays separate from the saturator's Crush mode**: it models a converter pair (anti-alias and anti-image filters, jitter, dither, fractional bits); the saturator's mode is unchanged.

## 2026-11-11: Space, Modulation and Utility effects (fx-space, choices to confirm)

**Decision (Claude, for the owner to confirm):** eleven new built-ins for the browser's Space, Modulation and Utility tabs (convolver, shimmer, Haas, ensemble, doubler, vibrato, tremolo, auto-pan, rotary, imager, channel mixer; [engine](engine.md#c-api-engineincludecawh)) with plugin UIs ([app](app.md)). No new dependency. One C API addition: `caw_engine_set_component_state`, API version 14 (the next free number after the drums and meters branches).
- **New effects beside the old ones, not extensions:** the ensemble is a separate multi-voice unit (`org.caw.chorus` stays the small three-knob chorus, its presets untouched); the imager is multiband with meters (`org.caw.utility` and `org.caw.stereo.width` stay); the shimmer reuses the reverb kernel as its own device rather than a mode of `org.caw.reverb.pro`.
- **Impulse responses are generated, not shipped:** nine types from seeded noise, chirps, combs and grains, so nothing is licensed. A user WAV is decoded on the control thread with every size checked, capped at 10 s and 16 MB, and stored in the project (base64 of the file) so it travels with it; a 10 s stereo file at 48 kHz adds up to about 5 MB to the project (the decoded floats, base64).
- **Loading a WAV rebuilds the chain:** the other effects on that track keep their values and saved state but restart their running sound (a delay's echoes) with a 20 ms crossfade. An undo of the load changes the project but not what plays until a reload.
- **Response length by quality:** 5 s at High, 3.5 s at Normal, 2 s at Eco (longer files are trimmed).
- **Other Kilohearts snapins of this area:** Stereo (Mid, Width, Pan) is covered by the existing utility and the imager; Gain by the utility; Chorus (delay, rate, depth, spread, taps) by the ensemble; Reverb's Early (early/late balance) is not a control of `org.caw.reverb.pro` (follow-up). Not built here: a "Trance gate" and "Ring mod" belong to fx-creative.

## 2026-11-11: EQ & Filter effects (fx-filters, choices to confirm)

**Decision (Claude, for the owner to confirm):** nine new built-ins for the browser's EQ & Filter tab (ladder, nonlinear filter, comb, resonator, formant, disperser, 3-band EQ, tilt EQ, graphic EQ; [engine](engine.md#c-api-engineincludecawh)) with plugin UIs ([app](app.md)). No new dependency, no C API change.
- **Slice EQ is the existing parametric EQ, extended:** `org.caw.eq` already had mid/side per band and an analyser, so Low cut 96 and High cut 96 (eight Butterworth stages) were appended to its types (saved projects keep their type numbers) instead of a second parametric EQ.
- **The 3-band EQ's id is `org.caw.eq.dj`**, beside the parametric EQ, with DJ kill switches Kilohearts' 3-Band EQ lacks.
- **The graphic EQ** stands in for Carve EQ (whose page lists only "a 31 band graphic EQ"): 31 third-octave bells corrected for their overlap, so the drawn curve is what you hear.
- **The tilt EQ** has no Kilohearts counterpart; it is the parametric EQ's Tilt band as its own small device, with mid/side.
- **The comb adds feedback** (positive and negative, with damping) to Kilohearts' feed-forward comb, and tunes to a note or Hz.
- **Not built:** Filter Table (a wavetable-driven filter; it needs a table editor and its own design) and the ladder's diode topology (its coupled stages need their own derivation). The resonator's modal ratios come from beam theory, not checked against a published table ([Assumption]).

## 2026-11-11: Settings as a category list, every setting real (choices to confirm)

**Decision (owner):** Settings opens on a list of sections with icons; a search finds any setting and jumps to it, highlighted; new Audio and MIDI, Editing, Projects and files and Export settings; full control of the audio device and buffer; nothing hidden. **Choices made on the owner's behalf, to confirm:**
- **Twelve sections** in this order: Audio, MIDI and input, Metronome and recording, Editing, Code editor, Look, Feel, Performance, Projects and files, Export, Keys and shortcuts, About and beta. Long-press menus moved to Feel, the Automate write mode to Metronome and recording, and the piano roll's look into Editing.
- **The sample rate** applies at the next start: the engine is made at one rate, and remaking it while running was judged too risky for this change.
- **Buffer sizes** offered: Auto (the buffer mode) or 16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 2048, 4096 and 8192 frames. miniaudio gives no list of the sizes a device allows, so the page shows what the device actually granted (Device now).
- **Exclusive mode** off by default; it is offered only on WASAPI and AAudio and falls back to shared when refused.
- **New project** defaults to Blank at 140 BPM, 4/4 (the earlier blank project's values); the menu item is now "New project" and says what it opens.
- **Defaults that keep today's behaviour:** autosave 0.5 s after an edit, 20 restore points, MIDI thru on, every keyboard and channel, velocity Linear, on-screen keys by touch at C3, click Classic at 100%, no pre-roll, a 0 ms recording offset, the roll at 1/16 with snap and Draw, the arrangement following the playhead (new: it pages when the playhead leaves the view), the wheel zooming only with Ctrl, deleting a track without asking.
- **Clear caches** empties the app's temporary folder (renders waiting for the save picker); nothing else is a cache today.
- **Not built (no engine or app path yet):** an audio input device and input monitoring (the engine has no audio input), keeping audio running in the background as a setting (background playback is not implemented, `.claude/rules/app.md`), normalize and tail length for exports (the renderer has neither).

## 2026-11-11: Routing and the ducker (#175, choices made for the owner)

**Decision (Claude, for the owner to confirm):**
- **Sends go to bus folders only.** A send's destination is a folder with its bus on; there is no separate "aux" track type. "New reverb bus" makes such a folder at the end of the track list, running the reverb fully wet, with the send at −6 dB. Why: one bus model (REAPER's folders) instead of two, and a bus already has volume, pan, mute, solo and now effects.
- **Routing loops are refused by the engine and never sent by the app.** The engine refuses the whole update naming the loop; the app leaves loop-making sends and keys out of the engine's copy (in track order, routes to parent buses first) and shows them faded, so moving a bus can't silence the project. The project keeps them.
- **Keys come from any track or bus, pre-fader by default, and keep their source running while it is muted.** A muted kick can drive a ducker, which is how sidechain ducking is usually set up. Keys are not delayed for latency compensation (they arrive early); the ducker's look-ahead covers a late one.
- **The ducker's three triggers in one device**, Tempo by default (it sounds with no setup); giving it a key switches it to Audio. Audio's default response is Trigger (the whole drawn shape per hit, re-arming 4 dB under the threshold), with Follow (classic envelope ducking) as the other choice. Look-ahead (up to 10 ms) adds latency only while it is on. A lows-only or highs-only duck through a Linkwitz-Riley crossover.
- **Mute and solo go to the engine as a project update** (40 ms debounce) instead of the one-layer live call, so solo and mute reach through folders, buses and sends correctly.
- **The master FX chain** already exists in the engine (`master_components`); strip slots for it are left for the master-chain step of gap 9.

## 2026-11-10: Polish round, night (owner)

**Decision (owner) (#175):**
- **User presets:** every effect and instrument gets an easy way to save the user's own presets.
- **Device screens:** more usable on mobile, with more inspiration from Vital. The EQ is singled out as confusing. "Everything doesn't need to be a separate screen."
- **Modulation:**
  - Routing an LFO or envelope to a knob is easy and mobile-friendly.
  - The amount can always be adjusted.
  - Several modulators can drive one knob, as in Vital.
- **Routing:** sends, buses and sidechain are easy and work correctly throughout.
- **A ducking plug-in** that works well ("there's literally no free one… that works well").
- **The Builder** is clearer about being for writing code, and easier to navigate.
- **Every screen** gets a polish pass for missing pieces, missing feedback and hard-to-use spots: super user friendly, and it looks cool.
- **Clarified (owner):**
  - The device that is confusing is the synth (the Flagship editor), not the EQ.
  - Saved presets live in a global library on the device and can be exported as files.
  - The public beta ships as a GitHub pre-release tagged `v1.0.0-beta.1` (APK and Windows zip).
  - The .caw language is removed before the beta (#160), and project files use the .caw extension (#159).
  - After this round the roadmap continues without the owner, who is asked only where a call is genuinely theirs.

## 2026-11-10: Release APK splits its Dart debug info out; no obfuscation (app performance pass)

**Decided on the owner's behalf ("optimize everything", #174), to confirm:** CI builds the APK with `--split-debug-info` and keeps the symbols as an artifact (and a release asset), about 0.73 MB off the download; release stack traces need `flutter symbolize` with them. `--obfuscate` is not used: it saves only 0.13 MB more and garbles type names in error texts users see. Project files are written as compact JSON (the indented form cost a second encode per save). Signing is unchanged. [performance](performance.md#release-build)

## 2026-11-10: Frame and feel, as built (choices to confirm)

**Built** from the evening round's frame decisions ([app](app.md), Frame; Motion and feel). **Choices made on the owner's behalf, to confirm:**
- **The bars' grip** sits at the top centre of the section, over the toolbar's top edge; a pull of 28 dp (half of 56) hides or shows, a flick counts, and a tap on the hidden tab shows them. In landscape only Arrange has one (its toolbar is the only bar). The hidden state stays across sections.
- **Haptic mapping:** a step is `PRIMITIVE_TICK`, a tap a softer `PRIMITIVE_CLICK`, a grab a click, a drop `PRIMITIVE_LOW_TICK`, a threshold a tick then a click, an error two clicks. Strength 50% plays the base scales (0.45–0.8); 0% halves them, 100% is 1.5 times. Ticks are limited to one per 35 ms and skip 35 ms after a tap.
- **Press feedback** is a dip to 92% and a glow; Reduced motion keeps only the glow.
- **The side panel** is resizable only on a phone in landscape (desktop keeps 34%), between 30% and 80%, snapping at ½ and ⅔; the panel moves on release, with a ghost while dragging, instead of resizing live.
- **Layout › Auto** uses the desktop frame at a shortest side of 600 dp or 900 × 480 dp (before: 900 dp wide alone, which a phone with a small display size could reach in landscape). Desktop on a small window starts with all panels as tabs of one group.
- **Floating windows** no longer blur what is under them.

## 2026-11-10: One synth: the presets, the migration and the quality knobs (built; choices to confirm)

**Built** from the owner's evening round (#174, below): "every instrument that can will be replaced by the better synth".
- **Presets are the engine's.** Named parameter sets of a built-in (`engine/src/presets.cpp`), listed with the components (`"presets"`) and named by an entry's `"preset"`; the app's preset browser reads that list first (`DevicePresets.engine`). Flagship has Init, Morph pad, Mono bass, Acid 303 and Basic; the app keeps four extra Dart starters (Supersaw lead, Soft pad, Pluck, Vowel keys).
- **Flagship grew what a 303 and a mono bass need, for every patch:** a voice mode (Poly, Mono, Legato) with glide, an Accent source (0 up to velocity 0.7, 1 at 1), a second source per mod slot that scales its amount (`via`), a Running LFO mode (synced rate, not locked to the song's position, as Morph's drift was) and a Classic table (Morph's four shapes). New parameters were appended after the mod slots, so saved slot destinations keep their meaning.
- **Old projects migrate in the engine** (one mapping, in C++): a project or sample-pack request naming a retired synth plays Flagship with its preset and its knobs mapped; lanes move to the Flagship knob in the same units and are dropped otherwise (choice made for the owner: the retired synths existed for a day, and a lane on, say, the bass's `env` has no single Flagship knob). The app asks the engine for the same migration (`caw_migrate_instrument`) when it opens a project, so its knobs show Flagship's values. The retired synths' code is deleted; their sound survives as measured references (`kRetiredSynthReferences`) the presets are compared with.
- **How close:** the mono and two-oscillator presets (Mono bass, Acid 303, Basic) are perceptually the same by the owner's bar (level within 0.5 dB, every band within 1 dB). Morph pad's unison starts each copy at a random phase, which neither synth repeats, so a 2 s render differs from the old one about as much as two old renders with another phase seed do: within 1.2 dB, bands within 2 dB RMS. A bright square through 16 kHz lacks the old polyBLEP square's aliases (up to 9 dB less between the harmonics). Numbers: [performance](performance.md#one-synth-2026-11-10).
- **Quality** (owner-approved): Eco, Normal (default), High, in Settings › Engine: Eco caps unison at 4 copies, turns the saturator's oversampling off, thins the reverbs and halves the effects' display updates; High oversamples the saturator 4x. **The audio buffer** (owner-approved): Auto (default: a 1024-frame buffer while not recording, the smallest while recording), Low latency, Battery. Choices made for the owner, to confirm: the Eco cap of 4 copies, the 1024-frame size, and that Auto keeps AAudio's low-latency path and Battery leaves it.
- **Second performance pass (choices made for the owner, under "perceptually the same"):** Flagship's poly voices whose filter 1 is set alike share one filter with their level before it (the Morph synth's way), and its oscillator phases move on in fixed point; both change bits inaudibly (every measured band within 0.01 dB), so the affected goldens were re-recorded. The First loop now costs what it did with the retired synths ([performance](performance.md#one-synth-2026-11-10)).
- **Not built, with reasons** ([performance](performance.md#one-synth-2026-11-10)): tracks on several cores (a wake-up and barrier per 64-frame chunk cost about what a track's chunk does; it waits for a phone measurement), an Android performance-hint session (binder calls from the audio thread), flush-to-zero (the owner's decision is open).

## 2026-11-10: Owner feedback, evening round (owner)

**Decision (owner), after trying the latest APK (#174):**
- **Top bars:** they hide only on a deliberate pull, using a visible handle that follows the finger. Scrolling never hides them.
- **Feedback:** every touch or drag gives feedback, visual and subtle haptic.
- **Haptics:** subtle everywhere, using the phone's high-definition haptic primitives, with a strength setting and an off switch.
- **Landscape side panel:** it is resizable, two thirds of the width by default.
- **Desktop mode on the phone:** Settings offers Auto, Phone or Desktop. Auto uses the desktop layout when the window is big enough (DeX, an external display).
- **Arranger:**
  - Clips show their MIDI notes, as in REAPER. Audio clips will show waveforms once audio clips exist.
  - Folders nest to any depth.
  - Each track's automation lanes sit under it, behind an arrow.
- **One synth:** "every instrument that can will be replaced by the better synth". Morph, Bass, Acid and Basic become Flagship presets, and old projects load them as the matching preset. The drum instruments stay.
- **Plugin UIs:** every instrument and effect gets a real plugin UI, modern vector, "in the theme of the app, but more colorful". Knob pages are only a fallback.
- **CPU:** the basic project sits at 35–40% on the S22+. The owner allows:
  - invisible optimizations;
  - a quality setting (Eco, Normal, High);
  - a bigger audio buffer when not recording;
  - "make the plugins take advantage of the hardware of the phone… optimize them to hell".

## 2026-11-10: Clip editing and the ruler, REAPER-style (built; choices to confirm)

**Built** from the owner's calls below and [REAPER's flow](reaper-flow.md) gaps 1 and 2 ([app](app.md), Clip editing; Loop range, markers and regions). **Choices made on the owner's behalf, to confirm:**
- **Phone multi-select is a Select mode**, from the clip bar's ☑ or a clip's long-press › Select several: taps add or remove clips and a long-press drag in empty lane space draws a box. A two-finger marquee was not used: two fingers already pinch-zoom and, during a drag, mean copy.
- **Keys:** S splits; next track keeps ↓ only (W and ↑ stay previous); G glues, Ctrl+D duplicates, F2 opens Properties. Delete removes the selected clips while any are selected and the track otherwise (REAPER's Delete acts on the selection).
- **Split of MIDI:** REAPER's "Allow trim of MIDI items when splitting" (a note-off at the split, UG 22.9.1) and its unpooled split parts (UG 13.35): the left clip keeps its pattern, the right gets its own pattern without the crossing note. Before, the right part shared the pattern and played the crossing note's tail again.
- **Where Split cuts:** the playhead; while stopped, a tap on empty lane space moves it (REAPER's edit cursor), shown as a dim line.
- **Glue** makes a non-looping clip and keeps the originals' patterns in the project (REAPER keeps the originals' media).
- **Lock** blocks drag, trim, split, glue and delete; **Mute** keeps the clip on the timeline and sends it to the engine as muted (so a track whose clips are all muted stays silent instead of free-running).
- **The loop button sits in Arrange's toolbar (⟳), not the transport**, which another branch is changing; R toggles it. Off, the whole song loops as before (C.A.W. has no "stop at the end"). Turned on with no range drawn, it takes the time selection, else four bars from the playhead's bar. A range past the last clip lengthens the song.
- **The loop export is the loop range while it is on** (Export's description says so); there is no separate range choice yet (build step 6).
- **The ruler** is 44 px on a phone (36 px wide), bar numbers and the loop range in its top half, markers and regions sharing its bottom half (one lane). A tap on it moves the playhead.
- **Marker keys:** REAPER's M, ] and [ are the layer's mute and length in Arrange, so markers take Shift+M (REAPER: insert marker with a name) and Ctrl+] / Ctrl+[; Shift+R adds a region over the time selection, else the loop range.
- **A new region** covers the time selection when the long press is inside it, else four bars from the bar pressed. **Dragging a region moves only the region**, not its clips (REAPER moves the contents with it, UG 9.8); moving or copying the clips is left for later.

## 2026-11-10: Match REAPER's whole flow, made easy (owner)

**Decision (owner):** "look at the flow of REAPER and match that as well", after the arranger (#172), and "The goal is to make it really easy to use." REAPER's flow is followed where it is simple and direct; where it is powerful but fiddly (deep dialogs, modifier gestures, the routing matrix) C.A.W. offers one obvious easy path with sensible defaults and keeps REAPER's depth behind it. The study, the gaps and the plan ranked by "makes a song easier to finish" are in [REAPER's flow and C.A.W's](reaper-flow.md); nothing in it is built, and the phone look of each new screen waits for the owner ([vision](vision.md#open-owner-decisions)).

## 2026-11-10: The effects suite's engine choices (on the owner's behalf, to confirm)

**Decision (made during #173's engine work; the owner has not confirmed it):**
- **Display data:** components publish a float block about 60 times a second through a lock-free two-slot seqlock (`caw/display.hpp`), read with `caw_engine_component_display` (API version 6), which never waits (it skips a busy control thread). Expensive display work (the EQ's FFT) runs only while a UI reads.
- **Look-ahead latency:** a descriptor declares one latency, so the compressor and limiter always delay by 240 frames (5 ms at 48 kHz) and their look-ahead knob moves the detector within that delay, instead of changing the latency the engine compensates.
- **External sidechain:** built 2026-11-11 (#175): the compressor and gate take a key from another track (Sidechain: External), as does the ducker.
- **References, all maths, no code or dependency taken:** the soft-knee curve (Giannoulis, Massberg and Reiss, "Digital Dynamic Range Compressor Design", JAES 2012); the polyphase IIR half-band design (Valenzuela and Constantinides, IEE Proc. G, 1983); trapezoidal SVF EQ bands as `eq.hpp` already used. Nothing from Airwindows, Vital, Surge or any GPL source.

## 2026-11-10: A complete built-in suite with visual device UIs (owner)

**Decision (owner):** the effects get the flagship synth's treatment, "everything you would need to make something, already built in" (#173).
- **Engine, in this order:** a parametric EQ, a compressor with sidechain, a master limiter, full reverb and delay, multi-mode saturation, then the rest of a stock kit.
- **Look:** every device's UI is "completely visual, fun to use and easy to use". Today's knob pages are "strictly a fallback if there's no UI built in".
- **Where it opens:** on the phone a device opens as a full-screen editor with tabs for its sections.
- **The flagship synth** gets its visual UI in the same work, mod matrix included.

## 2026-11-10: Recording flow and automation writing, as built (REAPER flow gaps 3 and 4)

**Built** from the owner's choices ("Touch, button in transport"; "Piano keys + pads toggle"; [app](app.md), Frame). **Choices made on the owner's behalf, to confirm:**
- **Automate's look:** a small lane icon in the transport between the position and the keys button: grey off, a red outline with the mode's letter (T, L, W, R) on, filled red while writing. The mode is saved in Settings.
- **Held means a finger down anywhere:** a move counts as held while any finger or mouse button is down, so every control is let go when the last finger lifts; a move with none down (a key, a typed value) is held for 0.4 s.
- **Write overwrites every lane in the project** (no per-lane arming yet) and then falls back to Read (REAPER's option, not its default).
- **Latch on a new lane keeps its last value after Stop**; on an existing lane it returns to what the lane had. Touch returns over a quarter step.
- **Thinning** keeps points that bend the line by more than 0.4% of the parameter's range (volume measured in dB).
- **Volume lanes reach +12 dB** like the faders (engine API 7); the automation screen draws them on the fader's taper in dB.
- **The click** is the engine's own (a 30 ms sine blip, higher and louder on the bar), not a hidden track: simpler and real-time safe. It clicks while recording by default; *always* and *off* are on Record's long-press, with the count-in (1 bar by default; none or 2).
- **Takes:** a loop recording keeps every pass as a take of one clip (`ClipDoc.takes`), the newest playing, picked from the clip menu's Takes; there is no take chip on the clip yet. A single pass is a plain clip.
- **"Keep take?"** is a toast with Undo for 5 s; Undo removes the clip and its take patterns.
- **Keys:** a piano from C1 to C8 with 30 dp white keys, opening on C3; velocity by where the key is struck (soft at the top, full at the bottom). **Pads:** General MIDI drums MPC-style on a drum track (found by its instrument or name), the project's key elsewhere. Record opens the keys when no USB keyboard is connected.
- **Keys:** Ctrl+R records and Alt+B shows the keys (REAPER's); Automate has no default key.

## 2026-11-10: Owner calls for the REAPER flow (owner)

**Decision (owner), from `docs/reaper-flow.md`'s top gaps:**
- **S splits** clips at the playhead, as in REAPER. Next track moves to another key.
- **Automation writes in Touch mode.** An Automate button in the transport turns it on, and moves made while playing are written. Latch, Write and Read are on a long-press.
- **Recording without a USB keyboard:** a slide-up on-screen keyboard (scrollable octaves) with a switch to a 4×4 drum pad grid, plus a metronome and count-in.
- **Loop range:** drag along the ruler to set it, as in REAPER, with handles to adjust it. The loop button toggles it, and a long-press on the ruler adds a marker or region.

## 2026-11-10: The arranger works like REAPER's (owner)

**Decision (owner):** "I would like the arranger to work like REAPER… Look at how REAPER does it and we're going to copy them" (#172). It covers:
- **Clips:** clips drag between tracks.
- **New tracks by dropping:** dropping below the last track creates a new track. The same applies to files, instruments and effects dropped on the empty area.
- **Instruments are added exactly like effects:** the same browser and drag and drop, as in REAPER, where an instrument is a plug-in in the track's FX chain. They are no longer picked from a long list on a held track.

- **A blueprint, not a list (owner, 2026-11-10):** "The goal is to make the arranger feel like a blueprint and not just like a list. It should work about the same way REAPER does." Clips, tracks, instruments, effects and files are grabbed and dropped where they sit; clips are created, moved, copied and trimmed on the timeline with ghosts and drop targets; long-press menus stay as the secondary path.

REAPER's behaviour is taken from its user guide ([UI design](ui.md#reaper-reference-the-arranger-copies-it)). Built in #172 ([app](app.md), Arranger). **Choices made on the owner's behalf, to confirm:**
- **Copy on a phone:** a second finger touched down during a clip drag toggles copy (REAPER's Ctrl); the piano roll's resting second finger still means Shift.
- **Folders:** REAPER's folder tracks hold items, but C.A.W.'s folders have no instrument, so a clip or asset dropped on a folder goes to its first track inside (a new one in an empty folder).
- **New tracks from a drop are empty but for the drop** (as in REAPER): a clip dragged below the last track gets a track with no instrument, named after its pattern; an instrument's or effect's track is named after it.
- **Copies have their own notes** (REAPER's plain Ctrl-drag doesn't pool MIDI); a linked copy stays in the clip menu.
- **Phone gestures where REAPER uses a mouse:** a track header is dragged after a long press (a long press released without moving opens the menu); a double-tap in empty lane space draws a one-bar clip in place of Ctrl+drag.
- **Not done:** Alt-drag stretch of a clip edge (Alt-drag shifts the source offset). S to split and dragging several selected clips together came with clip editing (below).

## 2026-11-10: A flagship synth that can do everything (owner)

**Decision (owner):** "the goal is to build one synth that can do all the things", with unison and detune that work "as it does in Vital". It is a new built-in instrument beside Morph, which stays as the simple one (#171).
- **First version, in order:** three wavetable oscillators with Vital-style unison (up to 16 voices, detune with a power curve, stereo spread, blend, random phase, stack modes); two filters; a mod matrix (envelopes, LFOs, random to any knob); a built-in effects rack reusing the Library kernels.
- **Not Vital's code:** Vital is GPL-3.0 and C.A.W. takes permissive dependencies only, so nothing of Vital's code, presets or wavetables is copied. The behaviour is reproduced from public descriptions in original code.
- The mod matrix's UI (owner, 2026-11-10, #173): Vital-style, a source dragged onto any knob makes a route, and the knob's ring shows and sets its amount.

## 2026-11-10: MIDI files are an import and export format (on the owner's behalf, to confirm)

**Decision (made on the owner's behalf during autonomous work on #158; the owner has not confirmed it):** note clips keep being stored as C.A.W.'s own text note form (pattern text, `app/lib/model/pattern_doc.dart`) inside the project; project storage does not change. C.A.W. imports and exports Standard MIDI Files (SMF format 0 and 1, MIDI 1.0; format 2 reads as format 1) so clips move to and from other DAWs. Per-note pitch bend and expression export as MIDI 1.0 pitch bend, channel pressure and CC74 on per-note channels (MPE lower zone: channel 1 manages, channels 2–16 carry one note each, with an MPE Configuration Message and each channel's bend range by RPN) when a clip has any; otherwise plain notes on channel 1. MIDI 2.0 clip files for clips are later.
- **Why:** the text form already maps notes, microtones and per-note curves one to one and is what the piano roll edits; a binary store would need a second editable form anyway. SMF is what other DAWs exchange, and MPE carries per-note bends in MIDI 1.0.
- **Where:** a Dart reader/writer (`app/lib/model/midi_file.dart`) and clip conversion (`app/lib/model/midi_clips.dart`), so files convert off the UI isolate and without engine changes. The engine's own converter (`engine/src/midifile.cpp`) stays for MIDI 2.0 clips (`.midi2`) only; the piano roll's `.mid` import and export moved to the Dart converter (2026-11-10, #168). Imported files are listed in Files by name with the patterns their parts became (`midi_files` in the project JSON, additive); the notes still live only in the patterns. [Assumption] A dropped multi-part file puts its first part on the target track and the others on new tracks under it. [Proposal] Whether to keep one converter (and which) is open in [vision](vision.md#open-owner-decisions).
- **Files are untrusted:** reading caps the file at 16 MB, 2 097 152 events, 1 048 576 notes and 4 194 304 expression changes, checks every length, and fails with a message instead of guessing.

## 2026-11-10: The logo is the faceted crow head, "C5" (owner)

**Decision (owner):** the placeholder outline crow and Flutter's default launcher icon are replaced. The owner wanted it abstract ("like a kernel"), glitchy and fun, coloured like a real crow and in the app's colours, and approved only after many rounds of drafts ("let's go with C5"): a tilted, faceted crow head in black glass with an iridescent feather sheen (green, cyan, purple), a large beak with a neon-green edge that doesn't reach the top of the head, a chin under it, a back that hangs a little lower, and a pink eye, on a frosted graphite tile. The chip "pins" and circuit traces were tried and dropped. It is the in-app mark and the Android and Windows launcher icon (`docs/app.md`); the source drawings are in `app/assets/logo/`. Logo changes need the owner's explicit yes.

## 2026-11-10: The engine carries inefficient plug-ins; efficient ones are easy to write (owner)

**Decision (owner):** "we have to build around people who aren't going to make very efficient plugins. We should also make it very easy to make them efficient as well." The performance goal for a whole project on the owner's phone (Galaxy S22+, 25–30% CPU on 2026-11-10) is 15–20%, reached by engine and host work with the existing instruments unchanged; the built-in instruments are optimized later and separately. The SDK and the testing suite should make the efficient path the easy one (for example block-based helpers, letting the host skip silent voices, and showing each component's CPU cost). [Proposal] Which helpers to build is not decided yet.

## 2026-11-10: No fixed polyphony cap; the program sets its own (owner)

**Decision (owner):** "remove the cap on how many notes a synth can play at once unless it's specified in the program; if someone wants to crash the program by abusing it, let them." The engine imposes no practical limit on held notes or note events: its note lists are sized very large when an instrument is set up (never grown on the audio thread, which would cause dropouts). A C++ instrument chooses its own voice count (`caw::VoicePool<Voice, N>`); the built-in instruments get generous counts. Overload is the user's responsibility, not a guarded limit.

Built (engine pass, 2026-11-10):
- **Polyphony (owner):** the host sets no practical cap; a program sets its own. Built: a native instrument's note list holds 1,024 notes and 4,096 events a block (360 KB a track; 4,096 and 16,384 took 1.5 MB, second audio review 2026-11-10), set aside when its chain is built (never grown on the audio thread); the built-in basic and Morph synths have 128 voices; a C++ instrument picks its own with `caw::VoicePool<Voice, N>`, which walks only the voices sounding.
- **CPU (owner, verbatim):** "if you can just change the engine to get 15 to 20% with the existing inefficient instruments that would be very impressive. Unfortunately we have to build around people who aren't going to make very efficient plugins. We should also make it very easy to make them efficient as well." The First loop measured 25–30% on the owner's Galaxy S22+; the target is 15–20%. Measured results and what is left: [performance](performance.md#native-instruments-first-loop-2026-11-10).
- **Chosen for that:** the host skips a component that has fallen silent. A component may say so (`ModuleProcessor::quiet()`; C interface extension `caw.quiet.v1`, read through `get_extension` so older hosts never see it, rather than a new `process` return code, which hosts that check for 1 would treat as a failure; CLAP export: `CLAP_PROCESS_SLEEP`), and only one that says so sleeps. The host used to put a component to sleep on its declared tail too (input silent past `tailFrames`, output all zeros), but it fell asleep on a block boundary with its timed state (an LFO, a control grid) frozen there, so after a pause the output depended on the device's buffer size and playback no longer matched the export (second audio review, 2026-11-10); that rule is gone. The engine and SDK build with `-fno-trapping-math` (no result changes; Clang's default), so GCC builds vectorize too.

## 2026-11-10: Owner feedback on the open beta (look and feel)

**Owner, after trying the APK:** most things feel okay for now. Changes asked for (not built unless marked):
- **Meters** work about the way REAPER's do, and fall faster than today's 24 dB/s while staying smooth. [Fact, 2026-11-10] REAPER sets meter decay in dB/s as a preference; its factory default is not confirmed here, so the app gets a decay setting with a faster default. Built (2026-11-10): Settings → Meter fall, 96 dB/s ("Medium") by default; the owner found the first default (48) slow and said the 96 then labelled "Very fast" should be medium. Master and stereo track meters show left and right.
- **Look** (built, #168): the whole app a little darker, with less green in the background (a grey-to-black frosted backdrop).
- **Arrange** (built, #168): track headers can be resized (drag their right edge for the width, a row's bottom edge for the height; saved). [Assumption] One height for every track, not per track.
- **Track headers, REAPER-style** (built, #168): the track's colour tints the header panel and its edge, instead of a thin colour stripe. Colours carry meaning by folder: tracks in a folder take shades of the folder's colour (a top-level track keeps its own); the user can still override a colour.
- **Phone landscape** (built, #168) feels bad and everything is too big (owner screenshot: the status row and the toolbar take a third of the height, the rail's icons and labels are large, the FX panel's knob labels are cut off). Make landscape compact: one combined top row, smaller icons, a narrow rail without labels, more height for the tracks. [Assumption] The "one combined top row" is built by moving the status row's contents into the rail (project, More) and the transport (tempo, CPU), so the section's toolbar is the only top row.
- **Bars hide on scroll** (built, #168): scrolling down tucks the top bars (status row, toolbar) away so the main content gets the screen; scrolling up brings them back, snapping fully shown or fully hidden.
- **Zoom** (built, #168) in Arrange and the piano roll: pinch with two fingers, on-screen buttons or a slider, time and height zoom separately, and Ctrl + scroll on desktop.
- **Build feels like VS Code** (built, #169): an explorer (the Files browser; a drawer on the phone, a resizable sidebar when wide) replaces the row of module chips, one slim row of open tabs with Build, and the code gets the rest of the space (the status line, bottom bar and the .caw Builder's track mix are gone from Build).
- **New files** (built, #169): + New offers Pattern, Instrument, Effect and Text file (owner: "JSON only where a project actually uses it": the component manifest is the one JSON file, so there is no JSON template; a text file of any name goes into the open C++ component). [Assumption] Text files belong to a C++ component because a project has no other place for loose files yet.
- **Pattern files** (built, #169): the header block is hidden from the text; name and length are fields beside the kind badge. [Assumption] `summary` and other header keys stay in the file unedited (no field yet), to keep the row small.
- **The Library reference** (built, #169) keeps the function Library's look and covers the C++ SDK (with instruments), `caw::lib`, the built-in components and C.A.W's text formats.
- A good sample pack comes later; the owner's focus now is how things feel and work.

## 2026-11-10: Native libraries in the APK are compressed

**Decision (Claude, the owner left it open):** the APK stores native libraries compressed (`useLegacyPackaging = true`). The on-device compiler alone is about 78 MB uncompressed, which made the APK 114 MB. Compressed, the download is much smaller, and Android unpacks the libraries once at install, so the installed size grows a little. For a beta handed out as a download, the download size matters more. Easy to revert if the owner prefers.

## 2026-11-10: Installables move to GitHub Releases once the current work is done (owner)

**Decision (owner):** once the current roadmap work is done, builds are published as GitHub Releases (a tagged version with the APK and the Windows build attached) instead of being picked up from Actions artifacts. Built (2026-11-10): `app.yml` publishes a release from a version tag or from Run workflow with **release** ticked (README). No release has been made yet; the first one waits for the current work. A release needs a stable signing key (the repository's Android signing secrets) so each APK installs over the last; the version comes from `app/pubspec.yaml` (`app/lib/version.dart` matches it).

## 2026-11-10: Sound need only be perceptually the same (owner)

**Decision (owner):** "so long as someone can't perceive the difference it's fine." Where bit-identical output is expensive, a cheaper way that sounds effectively the same is acceptable. Extended on 2026-11-12: output need only be perceptually identical everywhere, checked by tolerance tests (entry above).

## 2026-11-10: CLAP headers for the plug-in builder (#162)

- **Dependency:** the CLAP headers, free-audio/clap **1.2.9** (tag dated 2026-06-18, commit `cd94482b`; the latest tag on 2026-11-10, newer than the 1.2.6 first noted), **MIT** (its `LICENSE` read in the fetched tree, 2026-11-10). Fetched at configure time by `caw_add_clap_plugin` (`engine/cmake/CAWClap.cmake`), headers only, and the build stops if the fetched licence is not MIT. Not vendored, not in the app or the engine library.
- **Why:** CLAP is the first export target (roadmap 9.3): a C.A.W component library builds as a `.clap` plug-in other hosts load, through one wrapper around the C interface. VST3 follows later.

## 2026-11-10: C++ replaces the .caw language (owner)

**Decision (owner):** the .caw sound language is removed completely and replaced by C++. [Proposal, not built] Status: .caw still runs today; nothing below is built yet.
- **Order (owner):** C++ instruments come first, then .caw is removed. Today every instrument is a .caw module and C++ components are stereo effects only, so note-playing C++ instruments (and C++ built-ins for the starter sounds) must exist before the language goes, and the app never goes silent in between.
- **Patterns:** the owner asked for note clips stored as standard MIDI with a text form of C.A.W.'s own (#158). [Fact, 2026-11-10] a Standard MIDI File is binary, and so is MIDI 2.0's MIDI Clip File (midi.org M2-116-U, June 2023); midi.org publishes no official text form of either. How this was settled for now: "MIDI files are an import and export format" (2026-11-10, below the logo entry), pending the owner's confirmation.
- **Project files (owner):** the project file itself takes the `.caw` extension (built 2026-11-11, #159, below; old `.cawproj` files still import).
- **Old projects (owner):** dropped. Projects and the "First loop" template made of .caw sounds are not converted; this follows "no project compatibility before Release 1" (2026-11-03).
- **Sharing (owner):** shared sounds are C++, so each asks Trust / Block once per exact code, as now; Isolated (a separate process) stays planned. The sandbox that made a downloaded .caw module safe goes with the language.

## 2026-11-10: The C++ Builder's editor is re_editor

- **Dependency:** `re_editor` 0.10.0 (published 2026-07-01, MIT, Reqable; LICENSE read in the pub.dev archive 2026-11-10), with `re_highlight` 0.0.3 (MIT, Reqable; its C++ and JSON modes) and, through it, `isolate_manager` 4.1.5+1 (MIT; it runs the highlighter off the UI isolate).
- **Why re_editor over code_forge:** `code_forge` 11.7.1 (MIT) needs Dart 3.13.7 (the app's SDK is 3.13.5) and brings an LSP client stack (`http`, `web_socket_channel`, `markdown_widget`, a colour picker) the Builder doesn't use. `re_editor` is lean, keeps per-controller undo, draws only the visible lines, has Android selection handles and IME input, and its controller takes programmatic cursor moves and span decoration (squiggles), which the key row and checks need.
- **Built around it:** line numbers and error marks in our own gutter; error messages and knob values painted over the code from the editor's visible-line positions (re_editor's lines have one fixed height, so "under the line" is a band over the next line, shown for the cursor's or jumped-to error; other errors show dim after their line).
- **[Assumption]** speed on a few-thousand-line file and Samsung keyboard behaviour on the owner's S22+ are not yet measured; neither is the cost of a live check or a Clang completion per call on the phone.

## 2026-11-09: Faster CI: pull requests test, Main builds (owner)

- **Owner decision:** "we don't need to build the whole app in a PR, but we do need to test it."
  - Pull requests run Dart analysis and tests, the engine tests on every platform, the C++ component builds, the compiler test and the docs checks.
  - The Android APK and the Windows app are built on Main, or on any branch with Run workflow.
- A branch's own pushes no longer start the App, Engine and Docs workflows next to its pull request, so each commit is checked once. `gpt/**` branches keep the Quick check.
- **Owner decision:** run only the checks a change relates to, quickly and in parallel. Path filters:
  - Engine tests: engine code, not the compiler wrapper, plus `examples/`.
  - App checks: app code and the engine code the app embeds, not engine tests, benchmarks, CLI or compiler. On Main the APK also rebuilds for a compiler change.
  - Components and compiler: as before.
  - Docs checks run on everything (about 10 s).
- Jobs within a workflow already run in parallel. Measured on 2026-11-09:
  - Windows engine tests: 2–3 min;
  - Dart tests: about 2 min;
  - the rest: under 1 min;
  - the compiler test: minutes once its LLVM build is cached (built once per LLVM version).
- **Owner direction:** checks can run on a branch while it is being worked on, not only through a pull request.
  - Every workflow has Run workflow. The Quick check runs chosen commands on any branch. The App workflow's run can skip the installables for a quick test-only run.
  - Agents also run the engine tests and the Dart analysis and tests locally before pushing.
- **Faster app builds (owner: "builds are fast, not 10 min"):**
  - The APK is built for arm64 only, the owner's Galaxy S22+ and the phones C.A.W targets. Before, every build compiled the engine and the Dart code for 32-bit ARM and x86_64 too. **[Assumption]** No one needs a 32-bit or emulator build; one can be made on demand by adding a target platform.
  - Gradle's dependencies are cached, the engine's native build reuses compiled files (ccache), and the packaged compiler is cached until the compiler or the SDK changes.
- **The APK and the compiler cache:** GitHub scopes a cache to the branch (or pull request) that saved it, so Main's APK can only use an LLVM build cached on Main. When the Compiler workflow finishes on Main, the App workflow builds the APK again (only that job), so Main's APK always carries the compiler.
- **Owner direction:** split a job into parallel parts where the parts are really independent, keeping it readable and reliable.
  - Where it helps: the Windows build compiles each target's files in parallel (`/MP`), because nearly all of the Windows engine job was compiling.
  - Where it doesn't: the engine tests already run as 4 parallel shards. The Dart tests take under a minute themselves, so splitting them would add more runner setup than it saves.

## 2026-11-09: A C++ effect behaves like a CLAP plugin in REAPER (owner, #137)

- **Owner decision:** "the code will run like a CLAP does in REAPER": the same behaviour, in C.A.W's own component format; adopting the CLAP format is not part of this work. Effects run in-process for now; Isolated (a separate process) comes later.
- So an effect has, as built (2026-11-09):
  - an FX-chain place;
  - live, smoothed values;
  - automation lanes (a knob move overrides its lane until the next Play);
  - a click-free bypass that stops processing;
  - state saved into the project, read on every save.
- Also built: tails after Stop and latency compensation.
  - Effects with a declared tail ring out until quiet. They reuse the note-preview path, so the 10 ms stop fade dips the tail briefly.
  - The other tracks are delayed to match the most-delayed track, up to 32,768 frames.
    - A bypassed effect adds no latency.
    - A delay change while playing continues from the old line and crossfades.
    - Delays start each play from silence.
  - A tail that reaches its cap while still audible fades out over 20 ms.
- Also built: the host transport reaches components in each block, as a CLAP host gives it: tempo and beats per bar always, plus the beat position and `playing` while the song plays. It is a trailing `CawProcessBlock` field, read only when `struct_size` covers it; a component accepts a host whose block ends before it.
- Also built: a rebuild switches in while playing, crossfaded, keeping values and state; any chain swap crossfades. Still to come: custom GUIs.
- **Interface rule changed:** `save_state` may now run on the control thread while the instance processes (as in CLAP), so a playing project can be saved. A component that keeps state must make that safe; one without state needs nothing. `caw_component.h` says so.

## 2026-11-09: The app's layout (owner, #137, #139)

**A full DAW, closest to REAPER (owner):** dense and practical, "a DAW but better and more specialized". Every track header has record-arm and input, mute, solo and FX. There are mixer strips and long-press menus everywhere, and the layout can be customised. Research behind this layout (DAW conventions, Android window size classes, thumb reach, phone code editors) was presented to the owner on 2026-11-09; sources are in the session, not repeated here.

**Principles (owner-approved 2026-11-09).**
- Never lose your place: the tracks and playhead stay visible; a panel covers part of them, never all of them.
- Same thing, same place, same name on every screen size, so habits carry over.
- Select first, then act: the selection drives the inspector, FX and editors.
- Simple first, more on demand (an FX stack before the routing canvas).
- **Compact, not "grandma-sized":** rows 32-36 dp, code text 12-13 sp, icons about 18 dp, each control's touch area padded to about 40 dp without drawing it bigger. Icons over words; hold an icon for its name. Show only what matters now (no error count without errors). The neon theme stays, calmer: fewer glows and borders. The glass look and its transparency stay as they are (owner: "it works well"): see-through panels, sheets, cards and the transport over the ambient background (`docs/ui.md`, Glass). When the audio is under strain (overruns, thermal or power pressure, which the app already reads), the app lightens the blur on its own to protect the audio, and restores it after. The selected track, clip or effect glows in its track's own colour, brighter; errors stay pink and "built" green. Light haptics: a tick on grid snaps, a knob reaching centre and a long-press menu opening.

**The frame.**
- Three main tab types: **Build** (C++ Builder), **Files** and **Arrange**. Several tabs of one type (two Builders) switch from a small selector at the top of that section. The other workspaces fold into these three (#139).
- **Phone portrait:** a bottom bar holds the three; the transport (play, stop, record, undo) sits just above it, in thumb reach; the top shows only the song position and CPU. Dragging on the transport scrubs the playhead. Pulling down on the screen brings the top row within reach.
- **Landscape and desktop:** a slim icon rail on the left replaces the bottom bar, saving track height. Dragging a tab to the edge shows it beside the current one.
- **Desktop docking (owner: full docking, REAPER-style):** the mixer, inspector, browser and editors can dock to any side, share a dock as tabs, or float. The default dock is the inspector left, the browser right and the editor/mixer dock at the bottom.
- **Long-press menus:** a compact list near the finger by default; a Bitwig-style ring is a setting.
- **Tablets** use the desktop layout with touch: rail, docked panels, and the key row only without a hardware keyboard.
- **First run** and a missing last project open the "First loop" template, as now.
- **Undo is per area:** code undo is separate from project undo (tracks, clips, mixer).
- **Hardware:** Bluetooth/USB keyboard shortcuts work on the phone, USB and Bluetooth MIDI keyboards play and record notes, and the S Pen gives finer clip and note editing. [Fact, 2026-11-09] the engine has no MIDI device input or audio recording yet (`docs/engine-build-status.md`), so record-arm and MIDI input need engine work first.

**Arrange.**
- **Track headers (phone):** mute, solo and the FX button always show; record-arm, input and the rest are in the long-press menu.
- **Focus view (phone):** tapping a track moves it to the top of the screen and the lower ~80% becomes its panel, with tabs: FX, Mixer, Clip and Automation. Swipe sideways on the pinned track for the next or previous track; swipe the panel down, tap the pinned track or press Back to return to all tracks. In landscape the panel is a right side panel (about 40% wide) so the tracks keep their full height; on desktop it is docked.
- **Clip editing:** a clip's notes open in the Clip tab of the focus view.
- **Mixer (phone):** a card over the tracks with narrow strips you swipe through; tap a strip to widen it.
- **FX tab:** opens on a plain **FX stack**, a normal top-to-bottom insert list: cards with knobs, drag to reorder, "+ effect" and bypass. A **Routing** toggle switches to the free canvas, the project/track workspace of the visual plan (`docs/visual-routing-and-library-integration.md`). Both views edit the same chain.
- Export is in the project menu. Automation is edited as lanes under each track, REAPER-style: volume, pan and any effect knob, aligned with the clips. A long-press on a knob offers "Automate".
- **Song length:** no cap; the song ends at its last clip or automation point and playback loops back there, as in REAPER (built, `docs/ui.md`).

**The routing canvas.**
- **Layout:** a free canvas. A new effect is placed where its signal goes (after the chosen node, or on the chosen wire) and wired automatically; it can then be dragged anywhere. A light grid snap applies (hold to move freely), and "Tidy up" lays the graph out again.
- **Wiring:** drag from an output port to an input port. Ports are large touch targets coloured by type (audio, MIDI, control). Tap a wire to select it, then delete it or insert an effect on it.
- **Editing nodes:** tap a node to show its knobs.
- **Full page:** ⤢ expands the canvas to the whole project (every track, bus, send and the master) with the selected track centred. It is also in the Arrangement's menu.

**Adding an effect.**
- "+ effect", or + on a wire, slides up the file browser, filtered to effects: Built-in, My effects and Packs, with search and a ▶ preview.
- Tapping an effect inserts it there; it can also be dragged onto a wire or a track.
- A finished build is listed there at once. Tracks already using it switch to the new build while playing.

**Files (like Unity's Project window).**
- In landscape and on desktop: a folder tree on the left (Favourites, the project's Effects & instruments, Code, Audio & MIDI, and Packs) and an asset grid on the right. The grid shows icons with type badges and has a size slider, a breadcrumb and search with type filters.
- In portrait the tree becomes a drawer and the breadcrumb leads.
- **Tap selects** and shows the item's details and preview in the inspector; **double-tap opens** it (C++ source in a Builder, audio previews).
- Drag an asset onto a track or an effect slot, from the split view or from a browser sheet.

**Build (the C++ Builder).**
- **Editor core:** try an existing Flutter editor package first (re_editor or code_forge, both MIT; claims of large-file speed are the authors' own), benchmarked on the owner's S22+; write our own only if they fall short. The dependency is recorded here when adopted. The current `.caw` editor (`app/lib/ui/code_editor.dart`) stays for `.caw` modules.
- **Phone layout:** one thin top row (~36 dp): the file name ▾ (switches between open files), an error count only when there are errors (tap: next error) and ▶ Build. The app's bottom bar hides while the keyboard is open. Wide screens can split two files side by side.
- **Key row** above the keyboard, one row, swipe for more. First screen: a cursor key ⌖ (drag like a trackpad to move, hold and drag to select), `⇥ { } ( ) ;` and `= < > "`, with undo and redo at the right edge. Holding a key offers its variants (`=`: `==` `!=`; `<`: `<=` `<<` `->`). The other symbols (`:: & * [ ]`, arithmetic) are on the swipe page.
- **Keyboard closed:** a slim bar with Problems (count), Ref, Snippets and ♪ Test, each a half sheet with the code visible above. Landscape and desktop show Problems and Ref in a narrow side panel; with a hardware keyboard the key row hides (Ctrl+B builds, Ctrl+Space completes).
- **Checking:** a check-only compile (`-fsyntax-only`) runs about a second after typing stops and is cancelled by more typing; Build makes the library. Errors are a squiggle on their line with a one-line message under it. **Problems** lists errors and warnings (warnings dimmed) grouped by file; tap one to jump.
- **Completion:** automatic, after a short pause or after `.`, `::` or `->`, in a small box near the cursor (at most four rows) that shows a parameter's range and unit beside it. It comes from the in-app Clang (`-code-completion-at`), so it knows the SDK headers. [Assumption] this gives most of clangd's benefit without a separate server; to be measured on the phone.
- **Editor help:** syntax colours, a pull-up quick reference of the SDK and Library with an insert button for each, and snippets (a knob, a delay line, a tempo-synced time, a state save).
- **Saving:** autosave always, with an undo history; each successful build also keeps a named version to go back to.
- **Specialized extras (first version):** each parameter shows its current knob value in the code and editing the default moves the knob; a failed build marks that effect in the FX stack; the **test strip** plays the effect on the audio of the track it is on (or a track you choose) with A/B bypass and the effect's knobs; with nothing to play it plays nothing (owner: no default test sound); tapping an effect in a track's FX stack opens its source in Build.
- **New effects** start from one blank pass-through template.

**Build order (owner):** the frame and Arrange first (rail and bottom bar, bottom transport, focus view, mixer card), then Files, then the C++ Builder. Each step is a GitHub Issue under #139.

**Trust.**
- Effects the user wrote on this device are Trusted without asking.
- An effect from elsewhere shows as a greyed node on the canvas with "Native code from <source>: Trust / Block", while the rest of the song plays. The choice is remembered per exact code and can be changed in its settings.

**[Fact, 2026-11-09]** The engine routes each track as a linear chain into a folder bus or the master, without sends or sidechains (roadmap Stage 2). The canvas shows and edits what the engine supports; arbitrary connections arrive with the routing model.

## 2026-11-09: The on-device compiler is LLVM 23.1.5 as one library (#137)

- **Dependency:** LLVM, Clang and LLD 23.1.5 (`llvm-project-23.1.5.src.tar.xz`, SHA-256 `fb50b1ea…6a6e`, release checked 2026-11-09), Apache-2.0 with LLVM exception. Built by `.github/workflows/compiler.yml` with AArch64 code generation only; the build is cached per version.
- **Shape:** `engine/compiler/` wraps them as `libcaw_compiler.so` with three C functions (`caw_compiler_run`, `_free`, `_version`). Clang's driver plans each build; its compile steps run through cc1 and its link step through LLD, all in the calling process. So no executable is ever started, which Android forbids for app files. The Android app loads it in the `:compiler` process (§6 of the C++ platform note).
- **Offline data bundle** (`engine/compiler/bundle.sh`): Clang's headers, the NDK r30 sysroot for arm64 at API 26 (headers, `crtbegin_so.o`/`crtend_so.o`, `libc`/`libm`/`libdl`/`liblog` stubs, `libc++_static.a`, `libc++abi.a`), compiler-rt builtins and `libunwind.a`, the C.A.W SDK headers, and licence texts.
  - **[Assumption]** the redistributed NDK parts are permissive: bionic is BSD/Apache, while libc++, libunwind and compiler-rt are Apache-2.0 with LLVM exception. The bundle carries the NDK `NOTICE`, which must be read before the APK ships them.
- Components link the C++ library statically (`-static-libstdc++`), so a built `.so` needs only libc, libm and libdl.

## 2026-11-09: Where the C++ Library lives (#121, architect review)

- **Library kernels are public, header-only SDK code** in `engine/include/caw/library/` (installed with `CAW::SDK`), so built-in components and third-party components use one implementation, compiled into each; only `caw_component.h` crosses a binary boundary. Built-in components are thin wrappers in the engine (to come with #121). The first kernel is the pan law, `caw::lib::constantPowerPan` (`library/stereo.hpp`), which the mixer's track pan now calls.
- **The deterministic maths is public too** (`engine/include/caw/detmath.hpp`; `engine/src/detmath.h` forwards), moved unchanged: every golden render still matches.
- **Every component built against the SDK gets strict floating-point flags** (`-ffp-contract=off -fno-fast-math`; MSVC `/fp:precise`; clang-cl `/fp:precise /clang:-ffp-contract=off`, since its precise mode still fuses multiply-adds) as `CAW::SDK` interface options, chosen for the consumer's compiler in the installed `CAWConfig.cmake`, so Library code gives the same bits in a component on every platform. The engine itself no longer builds with these flags: since 2026-11-12 it takes `CAW_FP_FLAGS` and sounds the same rather than giving the same bits (see the 2026-11-12 entries above).

## 2026-11-09: Mono stays mono until it becomes stereo; packages; narrower doc coverage

- **Owner decision — mono processing (#17):** a mono source or effect is processed once and copied to both channels while its signal is mono. Once the signal has actually become stereo (a stereo source, pan or width upstream), a mono effect processes each channel separately ("dual mono"), from that point on. Mono work therefore costs one channel until something makes it stereo; there is no silent downmix.
- **Owner decision — packages:** a package is one of three things, of any size: a library that adds code functionality, a sample/MIDI pack, or built plugins/effects. So one component library may hold several components; the C interface lists them by index (`caw_get_component_v3(index)`; the version went to 3 for that signature change, so a library built against v2 is refused cleanly rather than called with an argument it ignores).
- **Owner decision — how Claude works:** follow `CLAUDE.md` for the most part, but stretch the rules or make small assumptions where that is best for the app (never a whole change of direction). Hooks and tooling that cause more problems than they solve may be changed to fit their intended use; first one: the Serena search reminder no longer fires on Bash commands (builds, tests, git), only on Read/Grep. Before building anything that needs UI work, ask the owner how it should look.
- **Owner decision — doc coverage:** notes that describe plans or the whole system no longer `covers:` all of `engine/`, so a code change requires re-checking only the notes that describe the changed files.

## 2026-11-09: Claude takes over engine building

- **Owner decision:** Claude builds the engine for now (replacing the 2026-10-31 split where GPT built features and Claude reviewed). GPT's merged work is the baseline where it applies; Claude asks the owner about open questions instead of deciding them.
- **Owner decisions (same day):** GPT is paused on the engine (Claude only). Work order stays #120 → #17 → #121 → #122 (issue #123), with the stable C interface built as part of #120. Claude merges its own engine PRs once CI is green and its independent audio review finds nothing blocking. The stereo-only C interface v1 (`caw_module_sdk.h`) is replaced by a full v2 with no v1 compatibility.

## 2026-11-09: Two visual workspaces and conditional signal/event routing

- **Owner decision — song workflow:** keep the ordinary arrangement, piano roll, clips and conventional mixer workflow for making songs. Visual routing is an additional workspace, not a replacement for arranging or note editing.
- **Owner decision — two visual workspaces:** use one reusable visual framework for two distinct editors: a component workspace to build/edit instruments, effects and processors (C++, Faust and visual DSP composition), and a project/track workspace to edit track controls, effect chains, sends/destinations, buses, sidechains and routing. The latter should let users adjust track parameters and send destinations while viewing the effect chain and routes together.
- **Owner decision — universal conditional routing:** add a native typed signal/event/control routing and workflow capability. Sources include audio analysis, MIDI/events, parameters, modulation, track/clip/region/note/transport state and explicit UI state such as highlight. Rules support conditions, branches and actions that can affect routes, sends, effects and component parameters across tracks. Regional FX/path activation should not require traditional automation lanes.
- **Architecture distinction:** component/DSP graphs, project routing graphs and condition/workflow graphs are separate domain models, connected through shared typed ports, events, parameters and component descriptors. They must not become three incompatible execution engines or a UI-only graph.
- **Safety and behavior:** prepare routes/effects off the audio callback; runtime rules must be bounded, deterministic, observable and safe for live/offline parity. Define cycle/feedback, hysteresis, debounce, retrigger and resource-budget behavior. Preserve channel and per-note identity unless explicitly converted/combined.
- **Owner decision — reuse scope:** evaluate existing open-source projects at every scale, including complete subsystems and applications, not only small libraries. Prefer adoption/adaptation when feature quality, workflow fit, architecture, performance, platforms, maintenance and licence obligations beat a rebuild. LMMS is source reference only; VCV Rack is interaction inspiration, not the target workflow.
- **Owner decision — DSP language:** C++ remains the primary general-purpose language. Faust is approved for evaluation as an optional specialist DSP authoring/compiler backend, preferably generated C++ through the local C++ build pipeline first. Not built (owner, 2026-11-09): an embedded Faust JIT (libfaust/LLVM) and a Pure Data/libpd runtime. Tracktion Engine and JUCE are engineering references only: C.A.W. studies them but copies no code (see the licence decision below).
- **Owner decision — order (2026-11-09):** conditional rules come after the routing basics (sends, sidechains, parallel paths: roadmap 2.1–2.3), still in Stage 2. The first rule to build is a MIDI note on one track (kick) triggering a ducking envelope on another (bass).
- **Owner decision — UI state as a trigger (2026-11-09):** a highlighted/selected track can only change what is heard while working (audition/monitor); it never changes an export.
- **Owner decision — workspaces (2026-11-09):** on the phone the track/routing workspace is both a slide-up panel for the selected track over the arrangement and a full page for the whole project. The component workspace is an ordinary, always-visible workspace for everyone.
- **Owner decision — component binary boundary (2026-11-09):** compiled components talk to the host through a small, versioned C interface, with the SDK's C++ classes on top, so components survive app, compiler and C++ library updates ([C++ creation platform](cpp-creation-platform.md) §2).
- **Owner decision — safe sharing (2026-11-09):** once .caw is removed, visual-graph components made only of built-in nodes are the safe share format; anything containing C++ needs the user's trust choice.
- **Owner decision — iOS (2026-11-09):** iOS ships without C++ authoring/compilation (play, arrange, build visually). The App Store rule behind this is an assumption to verify.
- **Owner decision — nothing external required (2026-11-09):** the app needs no set-up step, PC, charger, network or other connection to work; optional ones may improve things but are never required. The C++ compiler ships inside the one app (no separate edition), with the SDK and C++ standard library; set-up optionally offers Faust libraries and starter instruments/effects ([C++ creation platform](cpp-creation-platform.md) §6).
- **Owner decision — Android compiler process (2026-11-09):** on Android the bundled Clang/LLD run as a native library hosted in a dedicated `:compiler` process, so a compiler crash cannot take down the app or its audio.
- **Owner decision — overrun protection (2026-11-09):** a component that repeatedly misses its audio time budget is bypassed with a warning and can be re-enabled.
- **Owner direction — remote compiling (2026-11-09, future):** besides required on-device offline compiling, allow optional remote compiling through a free service (the user's own GitHub Actions first; research others) or the user's own computer, reachable on the same network or over the internet. Remote-built components go through the trust choice ([C++ creation platform](cpp-creation-platform.md) §6).
- **Owner decision — Faust timing (2026-11-09):** Faust work starts only after on-device C++ building works; it then uses that same local build step. No CI-only Faust path.
- **Licensing direction:** C.A.W. is intended to be free/open source, with optional support/donation bundles of prebuilt FX, instruments, presets, samples and sounds; core capabilities are not paywalled. No paid dependency or commercial licence is assumed. **Owner decision (2026-11-09):** C.A.W. is licensed under Apache-2.0, switched from all-rights-reserved on 2026-11-09 (chosen over MIT for its explicit patent grant and because it grants no use of the C.A.W. name). AutoStacc distributes the free app and the optional support bundles. Dependencies stay permissive: no GPL/AGPL code (so no Tracktion Engine or JUCE code). This keeps the iOS App Store, closed-source SDK components and later relicensing possible. Faust's compiler (LGPL) is a build tool, not shipped code, so generated components remain eligible subject to the audit. Verify exact versions and transitive/architecture-file licences before adoption.
- **Plan ownership:** the canonical [roadmap](roadmap.md) owns sequence and status. Technical detail lives in [visual creation and signal routing](visual-routing-and-library-integration.md), [C++ creation platform](cpp-creation-platform.md) and [architecture](architecture.md). This decision is not an implementation claim.

## 2026-11-08: Native note, voice and channel processing; direct pitch-expression editing

- **Owner decision — one native processing model:** per-note, per-voice and per-channel processing are first-class capabilities across the C++ SDK, component model, instruments, synthesis, effects, routing, automation, mixer and runtime. They are not separate feature islands and must not require users to duplicate signals or build manual workarounds.
- **Preserve identity until an intentional merge:** note identity, voice identity, per-note expression, channel identity/layout and event timing remain available to components that declare they use them. A component may explicitly transform, aggregate or discard a domain, but the engine must not silently lose note expression, collapse channels or reinterpret a layout.
- **Components declare their processing scope:** whole-stream, per-channel, per-voice and per-note processing are explicit capabilities alongside typed audio, event, MIDI, control and modulation ports. Components may support more than one scope. Effects and instruments use the same contract; an effect that needs individual note/voice context receives it through the native processing model rather than a special-case workaround.
- **Native stereo synthesis is required:** instruments can generate genuinely distinct left/right signals, distribute unison voices across the stereo field, and control per-voice phase, detune, gain, pan and modulation. Stereo oscillators, stereo modulation and stereo effects are native Library/SDK building blocks, not mono duplication followed by a widening workaround.
- **Stereo is the ordinary default; channel capacity follows resources:** new tracks default to stereo. The engine supports explicit mono, stereo and arbitrary N-channel layouts, with practical capacity limited by available CPU, memory, device and host budgets rather than an arbitrary fixed product ceiling. Track layouts are independent of physical output count; any required mapping or downmix is explicit at the output boundary.
- **No hidden channel or expression loss:** incompatible layouts require a visible, declared conversion. A stereo or multichannel effect must not silently collapse to mono, and a component that cannot preserve a processing domain must make the merge/conversion explicit.
- **Piano-roll direction — MIDISketch-inspired per-note pitch curves:** pitch slides and bends should primarily be drawn and edited as continuous curves on the note itself, with the curve representing the pitch the engine actually plays. The note remains visible and editable. A separate slide event remains available where it is musically useful, but it is not required for an ordinary glide.
- **Touch editing must be direct and smooth:** users can select the pitch curve/slide they intend to edit without accidentally selecting the underlying note; move, stretch and reshape it with continuous feedback; keep the underlying note visible; and use accessible handles and helpful snapping without abrupt jumps. Visual editing, note preview and playback use the same expression data.
- **Simple by default, deep when requested:** compatible components connect and work with sensible defaults. Ordinary stereo, unison, effects, panning and pitch expression must not require obscure routing, duplicated signals or manual channel plumbing. Advanced channel maps and per-note/per-voice controls remain available without burdening basic workflows.
- **Safety remains mandatory:** richer note/voice/channel processing stays within the resource budget and real-time callback rules; preparation and allocation happen off the audio thread.
- Detailed SDK contracts and tests: [C++ creation platform](cpp-creation-platform.md). Piano-roll interaction and sequencing: [roadmap](roadmap.md#stage-1-pattern-workflow-and-editing-safety), with current UI design in [UI plan](ui-plan.md#piano-roll).

## 2026-11-06: Offline-first C++ prototype and delivery requirements

- **Owner decision — offline operation:** No part of the C.A.W. app may require an internet connection. C++ project editing, dependency resolution for already-installed packages, compilation, linking, component registration/use, project/library management, saving and project packaging must work locally. There is no required cloud compiler, remote build service, GitHub account or GitHub workflow in the user's app experience. GitHub Actions remains repository CI only; its component matrix validates the code and is not the product build path.
- **Owner decision — local toolchain:** C++ components must compile on the user's device. The exact compiler distribution, target-toolchain packaging and Android implementation remain implementation questions to prove with a working prototype; do not substitute a remote build path. Compiler modules and target SDKs should be installed/cached locally and loaded only when needed.
- **Owner decision — optional dependency acquisition:** When internet is available, C.A.W. may proactively detect missing dependencies while the user writes or opens a project and install them in the background before Build. Ship a small core plus commonly used/preinstalled packages and the C.A.W. Library; obtain less common dependencies on demand. Verify package identity/integrity and licensing, pin project versions, retain installed packages for offline use, and never silently replace a version a project relies on.
- **Owner decision — prototype first:** Prioritize a working end-to-end prototype over a comprehensive framework. Prove the smallest useful vertical slice: create/open a C++ project, edit a component, surface inexpensive errors early, compile locally without network access, register/use the result in the engine, and show actionable diagnostics. Add only architecture needed by that slice; plan future compatibility seams without building a full migration system prematurely.
- **Owner decision — build feedback and speed:** Detect syntax/semantic problems and dependency/configuration issues before expensive compilation where practical. Prepare likely dependencies while the user codes; use incremental compilation and caching so unchanged source is not rebuilt unnecessarily. Full compilation and linking remain local.
- **Owner decision — Library integration:** The C.A.W. Library should be the easiest and fastest way to use components in the engine. Built-in, Library and user C++ components share the same registration, descriptor, ports, parameter and lifecycle contracts; users should be able to add or insert a component without manually recreating its integration.
- **Owner decision — project handoff:** Current priority is REAPER-like self-contained project/build packaging, not cloud collaboration. A handoff bundle should carry the project, required source/assets, pinned dependency versions and the required dependency payloads/configuration so the recipient does not have to hunt them down. Future AutoStacc distribution/synchronization is a later direction, not a current priority.
- **Owner decision — real-time safety:** Keep audio callback work bounded and free of allocation, blocking locks/waits, file/network I/O, logging and UI calls. Prepare memory, assets and execution state before activation.
- **Owner decision — trust:** The user explicitly chooses the trust level for each native component (Blocked, Isolated or Trusted). Building or installing a component never silently changes its trust level. A build process is not runtime isolation.
- **Owner decision — resource controls:** Make CPU, memory, audio load, compilation use and other meaningful resource consumption visible. Budgets and performance recommendations should be transparent and configurable; users may override advisory limits and accept the consequences. Do not impose arbitrary hidden ceilings. Retain genuine format, representation and real-time safety requirements.
- **Owner decision — reliability and security:** Provide practical autosave/recovery and protect projects from partial writes, failed builds and unsafe updates. Verify dependency origin/integrity and record licences, but keep safeguards proportionate; do not build an elaborate package-security framework before the prototype needs it.
- **Owner decision — compatibility:** Design component contracts and project/dependency metadata with future versioning in mind, but do not implement a comprehensive compatibility/migration framework yet.
- **Scope:** These are product requirements and sequencing decisions, not claims that the local compiler, dependency manager, project packager, trust host or recovery system is already implemented.

## 2026-11-05: Ordinary C++ and one shared creation platform

- **Owner decision:** C.A.W. uses ordinary, general-purpose C++ as its programming language. It is not a music-only DSL. The user can write anything ordinary C++ permits; the C.A.W. Library/SDK provides reusable building blocks rather than restricting the language.
- **The language, Library/SDK, component model and runtime are distinct.** The SDK is a broad toolbox of useful audio, DSP, synthesis, MIDI, sample/table, math, bit-manipulation, data and general-purpose functions and algorithms. Components expose one shared descriptor and lifecycle to the native runtime.
- **Three interfaces, one source of truth:** a practical C++ code editor; typed visual scripting/composition using built-in and user-created components; and a generated/custom performance UI and mixer surface. These are not separate engines. A C++ component is implemented once and reused in all three.
- **Shared metadata:** component descriptors cover stable identity, role/capabilities, typed audio/event/MIDI/control/modulation/data ports, channel layouts, parameters, assets/tables, lifecycle, state/presets, latency/resource/real-time requirements, UI metadata and plugin capabilities. One parameter definition drives generated controls, automation, modulation, MIDI mapping and host exposure.
- **Generated UI is the default.** A valid component receives usable controls from parameter metadata without hand-authored UI. Fully custom and hybrid interfaces are optional; processing remains independent of UI.
- **Visual graphs use the native runtime.** Built-in Library functions and user C++ components become typed blocks; graphs compile/prepare into the same native execution system. No separate visual interpreter or duplicated DSP implementation.
- **MIDI is shared.** C++ components, visual graphs, on-screen performance controls and device adapters use the same MIDI 1.0/MIDI 2.0 UMP/event model, including note identity and per-note expression.
- **Extensibility without rewrites is permanent.** New algorithms, components, parameter/port types, controls, MIDI capabilities, file formats, hardware backends and plugin targets use defined interfaces, registrations and adapters. Version extension contracts and component state; avoid speculative abstraction and hot-path overhead.
- **Real-time and trust boundaries remain explicit.** C++ is unrestricted in general-purpose code, but audio-callback code must be bounded and avoid allocation, blocking, I/O, logging and UI calls. Native C++ is not sandboxed by the SDK; use explicit Isolated/Trusted/Blocked policy for native code.
- **Plugin/standalone reuse:** components are C.A.W. components first; CLAP, VST3 and standalone support are host adapters around the same processor and metadata, planned after the SDK and authoring interfaces.
- **No backwards compatibility for the old .caw language or pre-release projects (owner).** The current .caw parser/compiler/bytecode VM is transitional. Migrate useful existing capabilities to C++/Library components and verify their workflows first, then remove the old language/VM. The owner is the only user and explicitly waives old-source and pre-release-project compatibility.
- Detailed technical requirements and migration gates: [C++ creation platform](cpp-creation-platform.md). Canonical sequencing remains in [roadmap](roadmap.md).

## 2026-11-04: UI direction, the arrangement is home

- **Owner:** the arrangement is the home screen, where about 90% of a song is built, and looks like a standard DAW. Empty, nestable tracks hold **several instruments** and effects in a chosen order. Automation lanes drop down under a track, each with a parameter dropdown. MIDI clips are made in the arrangement as in Reaper, and the piano roll opens docked below. The code workspace works like Unity's, with a searchable tree of project assets and user-picked device folders. The mixer is the fine-control screen, like Reaper's. Panels dock and move like Unity's **on the phone too**, with drag and drop onto the arrangement. Motion is light and snapping smooth. Clips and track headers glow with their track's level, and this can be switched off. Track colours plus one accent. A track without clips is silent.
- **Piano roll (owner, 2026-11-04):**
  - **Snapping:** one snap switch (with a hold-to-bypass) for notes and every curve. A value grid alongside the time grid.
  - **Stretching notes:** both ends stretch, and a group stretches together. The end follows the finger, and a ghost shows the snapped length.
  - **Curves on a stretched note:** a toggle chooses whether they stretch with the note or keep their timing.
  - **What snaps:** every curve kind, including automation.
  - **Handles:** bend handles with detents, plus optional per-point Bezier handles. Bezier needs engine and format work.
  - **Freehand:** freehand strokes simplified to grid points.
  - **Toolbar:** one context-aware row: tools, the snap magnet with its grids, a middle part that changes with the selection or curve tool, and ⋮. Undo and redo are in the transport bar.
  - **Motion:** smooth, with a tiny overshoot, and distance-aware (logarithmic: longer moves go faster).
  - **Haptics:** on by default, and can be switched off.
  - **Motion setting:** Full, Reduced or Off.
  - **Quick actions bar (owner, 2026-11-04):** off by default, because it isn't very useful yet; a Settings switch turns it on.
  - **Glass (owner, 2026-11-04):** a glassy look. Real frosted blur only on floating surfaces (toolbars, menus, sheets, drag previews, the transport), because blur is costly on a phone when many panels redraw. Docked panels get a cheap glass look with no blur: a translucent tint, a soft top highlight and a thin bright edge. A Glass switch in Settings, on by default; the Lightweight and Minimal profiles turn it off. Then (owner, same day): an ambient background instead of a flat two-tone look, glass track headers and clips, sheets that slide in as frosted glass, and sliders, bars and toggles with a light see-through fill and a solid outline. Later the same day (owner): glass must look good without blur, so a Frosted blur switch turns the blur off and keeps the glass look, and the Lightweight profile keeps glass without blur (only Minimal turns glass off). Thin outlines; slider knobs fake their transparency (opaque, mixed into the panel colour) so the track never shows through. The arrangement gets an adjustable gap between tracks and spacer rows that only separate tracks on screen.
  - **Detail:** [UI plan](ui-plan.md#piano-roll).
- **Arrangement (owner, 2026-11-04):**
  - **Layout:** the same context-aware toolbar row as the roll, with Select, Draw, Split and Erase. Compact track headers that widen to show volume, pan and the chain.
  - **Nesting:** by dragging onto a track, or Group. Any track can be a parent and still play, which needs engine work.
  - **Clips:** Draw makes clips (tap = the last length). The right edge repeats by default, and a handle switches it to extend. Split cuts under the finger.
  - **Selecting:** box, time range and tap on a header.
  - **Ruler:** playhead, loop region, markers, follow.
  - **Zoom and drag:** pinch both ways. Drag and drop adds instruments, effects (always to the track's chain), patterns and new tracks.
  - **Glow:** subtle and adjustable.
  - **Detail:** [UI plan](ui-plan.md#arrangement-home).
- **Piano roll, hearing and drawing (owner, 2026-11-04):**
  - **Hearing (2026-11-05):** a note plays while it is placed, moved, held or bent, through its track's instrument and effects at the track's volume and pan (mute and solo apply), on top of playback too, at the note's velocity. A tapped-in note plays its own length; a held or dragged note sounds until the finger lifts. A pitch change ends the old note before the new one starts; a move in time only doesn't retrigger. A selection plays its opening chord (the notes that start first). While a bend is edited the note follows the pitch at the edited point of the curve. "Hear notes" in ⋮ turns previews off. Claude built the note on/off C API for it (#103).
  - **Drawing:** drawing stays as today, plus the confirmed quality-of-life tweaks.
  - **Extras:** scale highlight, snap to scale and ghost notes.
- **Code workspace (owner, 2026-11-04):**
  - **Tree:** project assets plus picked device folders, showing C.A.W-related files.
  - **Search and files:** search covers names, tags and contents. Files support new, rename, duplicate, trash, drag to move, drag onto the arrangement, favourites and tags.
  - **Tabs and running:** tabs with autosave for project files. Code runs automatically after a pause, plus Run.
  - **Editor:** inline errors, hover docs, find and replace, go to definition, multi-cursor, folding, snippets and format.
  - **Side panels:** Controls, Problems, Scope and Library.
  - **Detail:** [UI plan](ui-plan.md#code-workspace).
- **Startup and engine changes (owner, 2026-11-04):**
  - **Startup:** the app opens straight into the last project's arrangement. New, template and open move to the project menu, replacing the 2026-10-28 startup screen.
  - **Small engine changes:** Claude makes those the UI needs, such as the note on/off call.
  - **Large engine changes:** these wait for GPT: several instruments per track, parent tracks with sound, and Bezier curves.
- **Why:** the owner wants one place to build a song that feels like a real DAW and good to use. The plan, today's findings and the open questions are in [UI plan](ui-plan.md).
- **Consequences:** several instruments per track and silent empty tracks change the engine and project model. The engine part goes to GPT as an issue, and the UI waits for it where it must.

## 2026-11-04: F7 resource budgets (owner, after the caps audit)

- **The app keeps everything the engine keeps.** The app-only caps go (automation points past 128 and project lanes past 256 dropped on load, patterns at 4,096 notes/steps and 16 curve points, notes dropped on paste); any bound that stays is a clear error, never a silent drop. The owner allowed app/ changes for this.
- **The 64-bar arrangement limit is removed** in the engine and the app: length is bounded only by the step representation and the project JSON budget, and nothing is moved or shortened.
- **Layers become dynamic:** the count is bounded by the memory budget, and the mix graph is re-prepared off the audio thread and swapped in when more slots are needed.
- **Safety bounds come from the hardware budget:** module source, nesting, registers, per-module state, queues, workers and MIDI file limits get defaults derived from `EngineResourceBudget`/the hardware profile, overridable by the host within a safety ceiling, and every one fails with a clear message.
- **F7.2 rules (Claude, within the owner's choice):** an out-of-range song position (loop bars, clip, layer length, automation point, audition) is refused with a message naming it, since clamping would move or shorten it; values past the 32-bit step count are pulled inside it only when the app loads a file, as the representation limit. Clip expansion counts toward the project-state budget and is checked, with room for the build's peak, before it is built. Loop and free exports stream to the file so their memory doesn't grow with the song (a free-RAM check would refuse the same export on one try and allow it on the next); a render longer than a WAV file holds is refused before rendering, not cut short. Automation editors reach the song's end, and at least 64 bars, so new points have room.
- **F7.3 plan (Claude, after an architect review):** three steps. A: slot capacity becomes a runtime value (slots held by pointer with a stored index, a capacity-sized mix graph, the order list sent out of line), still 64 layers, with identical sound. B: the Engine grows its slot table and mix graph off the audio thread and swaps them in by command, geometrically, never shrinking, bounded by the graph-working budget with a clear error, and the parser's 64-layer cap goes. C: the app's layer caps go. Done in B, because a grow moves the audition's slot: `scope()` takes ids for the master (-1) and the audition (-2), `CAW_SCOPE_MASTER`/`CAW_SCOPE_AUDITION` in the C API (no backwards compatibility needed, owner 2026-11-03). B's ceiling counts both graphs a grow holds at once.
- **Unfinished work goes to Main (owner, 2026-11-04):** F7.3 part B was merged with the audio review's findings still open, rather than held on a branch. The open items are recorded where the work stands (`engine-build-status.md`) and in #94. From the same date GPT does the remaining engine work (#94, F7.3 part C, F7.4, F8, F10) and Claude plans the UI; the owner said not to build UI yet.
- **Split:** F7.1 app caps; F7.2 the 64-bar limit; F7.3 dynamic layers; F7.4 safety bounds from the budget; the silent engine clamps (render lengths, unison, wavetable frames, splits, take-over) are reported or removed in the step that owns them.

## 2026-11-04: F6 parameter model: resolution order and owner choices

- **Owner choices (2026-11-04):**
  - A manual change while automation exists is a *touch*: the manual value wins until playback restarts, then the lane rules again.
  - Modulation depth is a fraction of the parameter's range on its curve (normalized 0..1), the same for every parameter.
  - A mapped MIDI CC sets the base like a knob, jumping straight to the controller's value. Soft takeover can come later.
  - Native SDK modules keep one value per block, the block's first frame, so the ABI does not change. Built-in and .caw modules get per-frame values when a parameter varies.
- **Resolution order (after an architect review).** Each frame resolves in this order:
  1. Base: automation, unless touched; otherwise the manual or MIDI value, smoothed linearly over `smoothingFrames` (at most 2^20) from the value last resolved, so touching during automation starts from what was playing.
  2. A link without a signal (disconnected, bypassed) is skipped. With no link carrying a signal, the base is only clamped and stepped, so plain values pass bit for bit, as on the Engine's automation path.
  3. Otherwise: normalize, apply the links in ascending link id (never graph or UI order), clamp to 0..1, denormalize, clamp and step.

  Links are `ModulationOp` Add, Multiply, Min, Max or Replace, each blended from the current value toward its target by depth (−1..1), at most 8 per parameter. A NaN or inf sample from a connected source reads 0. Exponential curves use `detLog`/`detExp` and their endpoints are exact. A block with nothing varying is one constant, which keeps stereo playback cheap.
- **F6.2 executor rules (after the audio review).** prepare() starts every parameter at its default, so a rebuild restores kept values with `setInitialParameter` (no ramp, no touch), never through the queue. The command queue (256) refuses when full rather than blocking, so the sender resends the latest value. A touch reset is one epoch step, whatever the graph size. `smoothingFrames` counts frames at the graph's rate; scaling it by sample rate is still open (see the F6.6 rules).
- **F6.4 automation lane rules.** The graph and the Engine read lanes through one function (`automationLaneValue`), so their values are bit-identical, seeks included. Lane points are borrowed and set while audio is stopped; the transport (position, samples per step, playing) is set on the audio thread and advances by each block's frames. A lane plays only while the transport plays and the parameter is untouched. When the lane stops, the parameter holds the last value played, rather than jumping back to the old manual value: the reliable choice, with no click on stop.
- **F6.5 CC mapping rules.** A CC's value (v / 127, or v / 0xFFFFFFFF for MIDI 2.0) is a position on the parameter's curve (denormalized), so a CC sweeps an exponential parameter like its knob does. One CC per parameter keeps the base unambiguous; one CC may drive several parameters. CCs take effect at their own frame (the block is resolved in segments), and come only from the graph's host events, never from other nodes' event outputs. Soft takeover is still later. **Open (owner):** a MIDI 1.0 CC scales as v / 127, so 64 is 0.504, not the exact centre a MIDI 2.0 0x80000000 gives; the MIDI 2.0 min-centre-max upscaling would make the two agree if bipolar parameters need an exact centre.
- **F6.6 Engine rules (after the audio review).** A .caw param's held value is its manual base. A touch is a knob move only (`setParam`/`setGlobal`): a project update that rewrites held values is a restore, never a touch, so the result doesn't depend on whether a module was recompiled. Play ends touches, including knob moves made while stopped, and a rebuilt chain (a code edit) keeps the touches made since the last Play. Non-finite param numbers are a compile error. Held values are stepped like any base, which leaves values already on the grid (every golden render) bit-identical. .caw params have no smoothing, so the Engine can resolve a module more than once per chunk (lanes, the swap shadow). Whether `smoothingFrames` should count time instead of frames stays open until a smoothed parameter reaches the Engine.
- **Split:**
  - F6.1: resolver and descriptor fields (curve, step, smoothing, unit).
  - F6.2: values to processors through the executor.
  - F6.3: modulation links.
  - F6.4: automation lanes.
  - F6.5: MIDI CC mappings.
  - F6.6: the Engine's .caw params and globals move onto the resolver, with golden hashes unchanged.

## 2026-11-04: F5.2 event ports in the graph executor

- **Event format (owner).** A C.A.W event with a stable note id: `{frame, kind, flags, noteId, data[4]}` (28 bytes). `data` carries the raw MIDI 2.0 UMP words, so MIDI 1.0/2.0 convert at the edges without loss. Chosen over raw UMP alone, which cannot tell two overlapping notes of the same pitch apart. The executor never interprets kind, flags, note id or data.
- **Bounded per block.** Each event output and each merging input holds `GraphResourceBudget::maxEventsPerPort` events (default 1024, counted in the working-memory budget). A summing event input merges its sources by frame, ties in connection order, keeps the earliest events and counts the rest (`eventsDropped()`). A processor's output must be in frame order and in range or the block fails, so later nodes never misread it.
- **Host events** go to each node's first unconnected event input, like host audio; dynamic routing stays audio-only.

## 2026-11-04: F5.1 typed ports in the graph executor

- **Port semantics (after an architect review).** Modulation is one float per frame and may sum like a mix bus; control is one value per block, takes one source, reads its port default when unconnected and holds its last value, saturated after each block like routing (NaN reads 0) so a bad value never latches. Only a node's first audio input reads the host input; other audio inputs (sidechains) and modulation read silence when unconnected. No type is ever converted implicitly: a follower or converter is its own node.
- **Typed nodes are checked at prepare.** A processor with more than one audio port or any other port opts in with `usesProcessPorts()`; otherwise `prepare()` fails, so a correct-looking graph never fails on its first block. One-in/one-out audio nodes keep the old call (callgrind: playback +0.05–0.09%).
- **Parameters are not ports.** F6 decides how a port binds to a parameter (base value plus modulation); F5 does not settle it.

## 2026-11-04: F4.4, every track module is a graph node

- **Done now, with float edges (owner).** Asked whether to split tracks into module nodes now or with parallel effects (2.3), the owner chose now, with 32-bit float edges between modules (the F4.2 rule). Each module's output rounds to float, so 9 template and 8 mixer golden hashes were re-recorded. **[Fact, 2026-11-04]** The old engine with only that rounding added renders the new hashes bit for bit, including new effect-chain, seam, pattern and code-swap cases; 24-bit renders differ from before by at most 1 LSB.
- **A track has 32 module nodes.** The mix graph is prepared once, at Engine construction, so each slot gets a fixed set of module nodes; a longer chain is refused with a layer error, never cut short. F7 may replace the number with a budget.
- **Seams and code swaps run as lanes, not extra graph shapes.** Module edges carry three lanes (current chain, seam shadow, replaced chain), and chunks end at each playing track's loop restarts and swap points, so every node runs whole segments and the order of state hand-overs stays as before.

## 2026-11-03: Seeded randomness everywhere, per project and per module

- **Every random source is seeded (owner).** Any randomness in `.caw` modules, built-in nodes and native plugins comes from a seed, so the same project gives the same result every time. **[Fact, 2026-11-03]** `.caw` already works this way for `rand`, `randi`, `hash`, `noise` and pattern note probability, all from the single project seed; there is no per-module seed, and the component C interface v2 (`caw_component.h`, 2026-11-09) passes components no seed and offers no random source yet (a seed would be a host extension).
- **Per-module seeds follow the project unless pinned (owner).** By default a module's seed is derived from the project seed with a per-module offset, so modules differ but all move when the project seed changes. A module can be pinned to its own seed, which then ignores project seed changes.
- **Seeding can be switched off per module or per project (owner).** Off means fresh randomness on each play or export.
- **[Proposal]** When seeding is off, the seed actually used is still recorded (shown and saved with each export), so a take you like can be pinned and reproduced; exports with seeding on stay bit-identical across platforms.
- **Open:** giving native plugins a seed needs a native SDK ABI change, which the owner approves when that step is built (roadmap F10).

## 2026-11-03: Reliability over old-engine compatibility

- **The old engine's sound and behavior carry no weight (owner).** The goal is the most reliable engine possible. There is no need to reproduce how the pre-Foundation engine sounded or worked, and no support for its quirks.
- **Reference renders guard regressions, not the old sound.** When an intended engine change alters output, the pull request re-records the references and states why, with a measurement; it does not need the owner's approval first. Since 2026-11-12 they are compared within a perceptual tolerance, not bit for bit (entry of that day).
- **Unchanged:** a real-time-safe callback; tests never weakened; bug fixes start with a failing test; the owner is asked before native SDK ABI changes and new dependencies.

## 2026-11-03: Merging, and no project compatibility before Release 1

- **Claude may merge (owner).** Claude may merge its own pull requests, including the #28 engine branch into `Main`, when CI is green and nothing breaks. The no-merge rule is for the chat-agent (GPT) route. Flow: each Foundation item reaches `Main` once its CI is green. Until 2026-11-03 that went through `feature/native-engine-refactor-integration`; that branch merged fully into `Main` in PR #73 and was then deleted by the repository's delete-on-merge setting, so Foundation pull requests now target `Main` directly.
- **No backwards compatibility before Release 1 (owner).** The app hasn't shipped and the owner, its only user, has no projects to keep, so older project files need not keep opening. The project file format stays at version 2; real versioning starts at Release 1, once adding features no longer needs core rework. Roadmap F9 (migrations) moves to before Release 1 (R.7), and Foundation changes to the project model need no migration. Changes to the project file are still listed in each pull request.
- **F4 precision: float graph edges, golden hashes re-recorded once (owner).** The live mixer sums tracks, folder buses and the master in 64-bit `double`, while graph audio edges are 32-bit float. Measured on 2026-11-03: rounding each track's output to float where it enters a bus or the master changes 10 of the 12 golden hashes (rounding of about 1e-7, inaudible). The owner chose to keep float edges and re-record those hashes once, in F4.2, where the old mixer is changed to round at exactly the points the graph will. F4.3 (the graph runs playback) reproduces the F4.2 hashes bit-for-bit. Later golden-hash changes follow the 2026-11-03 "reliability over old-engine compatibility" entry above.

## 2026-11-03: Roadmap order, first release and per-item tables

- **Goal restated (owner):** C.A.W. is not trying to be a conventional DAW and needn't work like one, but it must be able to do everything a good DAW can do, because there is no good DAW for mobile. This replaces the older "lightweight DAW in a pinch, no full feature parity" wording in `architecture.md`. The goal is stated in [vision](vision.md).
- **Graph first.** The engine graph and N-channel core (issue #28) is the roadmap's new **Foundation** stage, before the remaining Stage 0 (SFZ, stems) and Stage 1 features, so they are built on the graph once rather than on the old mixer and then migrated. This replaces the same day's decision to pause graph integration until after Stage 1.
- **First release after Stage 7.** Release 1 (signed builds, onboarding/help, docs, licensing, distribution) comes after recording works, on Android and Windows; Stages 8–10 ship as updates. It was previously the last stage.
- **Gaps added to the roadmap:** app-wide undo/redo and crash recovery (Stage 1), project format versions and migration (Foundation, before the project model changes), audio output settings (Stage 5), and onboarding, help and a preset/template browser (Release 1).
- **Layout:** each stage is a table of items with status, where (engine/app), dependencies and what's missing, so progress and gaps are visible per item.

## 2026-11-03: Engine shape, formats and trust decisions to avoid later rework

- **One graph runs everything (eventual engine core).** Code (.caw) layers, synth voices, effects, folder buses, sends and master all become nodes of the one typed module graph. The current layer → effects → folder bus → master mixer is migrated into it, not kept as a parallel path. Timing: first, as the roadmap's Foundation stage (see the next entry).
- **Stage 0 SFZ means full import and mapping.** The first multisample version imports WAV samples (own or third-party), maps zones (key ranges, velocity layers) by hand, plays them in C.A.W and exports WAV + .sfz. This pulls the needed parts of roadmap Stage 3 (audio import) and Stage 4 (sampler zones, WAV/SFZ interchange) into Stage 0.
- **Exports were to be bit-identical** on every platform; superseded on 2026-11-12: output, exports included, need only be perceptually identical (entry of that day).
- **Low-end target includes budget phones:** Galaxy A1x-class, 3–4 GB RAM, Android 10+. Voice counts, buffer sizes and benchmark budgets are set for that class.
- **Precision:** graph audio buffers are 32-bit float; 64-bit is used where accuracy needs it (phase/time accumulators, sensitive filter state). The .caw VM keeps its 64-bit JavaScript number semantics, which bytebeat compatibility requires.
- **Latency is adjustable:** a low-latency mode for playing live when timing matters, and a lighter, more stable mode (larger buffers, less CPU) when it doesn't. This is the workload-policy model in [engine-next](engine-next.md) §9.
- **Third-party native code: the user chooses per item.** Each external plugin (CLAP/VST3/AU) or third-party native module runs in one of three modes the user sets: **Isolated** (separate process), **Trusted** (in-process, no isolation, for code the user trusts) or **Blocked**. Shared .caw source stays sandboxed as before. The default mode for code not seen before is an open question in [vision](vision.md#open-owner-decisions).
- **Projects are folders that work like a repository.** A project folder holds the project file and its local assets; assets can also be linked from the global library. "Package build" collects every dependency into the folder so it works on its own. The format must stay compatible with a future **AutoStacc cloud library** (the owner's synced personal asset library). That sync is optional; core work never needs the network.
- **Audio clip timing is chosen per clip.** Clip positions are stored in musical time (beats). Each audio clip is either *musical* (follows tempo changes, time-stretched) or *fixed* (plays at original speed in seconds).
- **Graph is N-channel by design, stereo in practice.** Ports and buses carry a channel-layout field and are not hard-coded to two channels; only mono and stereo are implemented until surround (roadmap Stage 10).
- **Everything in the graph must be plugin-exportable.** Built-in graph nodes may not depend on the app or the OS, so any graph can become a CLAP/VST3 plugin (roadmap Stage 9).
- **Projects set their own render sample rate** (default 48 kHz; 44.1 and 96 kHz selectable). Live playback resamples to the device when they differ; exports always use the project rate.

## 2026-11-03: A separate test route for chat agents

- Owner: GPT works from a chat window with only a GitHub connector, can't run tests itself, and gets stuck re-reviewing when its context grows. It needs a way to run tests without opening pull requests or building the app, plus a workflow that survives a new chat.
- Chosen: `gpt/**` branches run only the Quick check (`.github/workflows/quick-check.yml`, `scripts/agent-run.js`). `run:` lines in the last commit message choose exactly which commands run (a filtered test, a sanitizer run, one build target, a render, ripgrep, Graphify, ctags lookups), so the agent tests what it needs while it builds, much like a terminal. With none, a default set runs (docs guard, Linux build and tests, examples, Dart checks when `app/` changed). Commands are a fixed list run without a shell. The same runner covers ChatGPT's own list of gaps (2026-11-03): git `diff`/`log`/`show`/`blame`; app interaction through widget tests, accessibility guidelines and published `screenshot` PNGs; a RUNNING notice and `INDEX.md` for job tracking; and an environment line in every report so a CI pass is never presented as a hardware result. It publishes a short report file per branch on the `agent-results` branch, because a file is what the connector reads reliably. **[Assumption]** It is not verified that the connector can read Actions logs or trigger `workflow_dispatch`, so the route needs neither.
- Full Engine, App and Docs CI is skipped on `gpt/**` pushes and runs on the pull request, which is still the merge gate. The report's write token sits in a separate job that never runs branch code.
- Start-of-chat context is generated, not remembered: `START.md` on `agent-results` bundles `AGENTS.md`, `CLAUDE.md`, `docs/vision.md` and every area rule, rebuilt from `Main` when any of them changes. A start prompt in the ChatGPT project's instructions (text in `AGENTS.md`) makes each chat fetch it first and confirm what it read, since ChatGPT has no hooks.
- The loop and stop rules live in `AGENTS.md` ("Chat-agent route"): a progress comment on the issue replaces chat memory, each file is reviewed at most once per chat, two failed fixes means stop and report, and a long chat hands off to a new one.

## 2026-11-03: Agent navigation tools are the default path

- Owner: Graphify and Serena (with the repo map) are how agents find and read code by default; plain Read, Grep and shell `cat`/`sed`/`grep` are for what those tools already named.
- Enforced by tooling rather than wording: the session-start hook prints the navigation order and how to load Serena's deferred tools, and Serena's `remind` hook now watches Bash and Serena calls as well as Read/Grep (`.claude/README.md`).

## 2026-11-02: Prepared project snapshots are the project-publication unit

- Build the complete project runtime on a control/worker thread as one owned prepared snapshot: module instances, VM chains, graph topology, routing, buffers, schedules, parameters, automation, event storage and a bounded state-migration plan.
- Publish one pending snapshot atomically and let the audio callback adopt it only at a block boundary. The callback must not allocate, lock, compile, wait for workers or call the UI.
- Keep the active snapshot alive while it is processed; retire superseded snapshots through preallocated/intrusive retirement records and reclaim them only on a control thread. Replacing an unconsumed pending snapshot must be safe and must not leak.
- Treat project replacement as a transaction. Do not send hundreds of independent layer-install commands that can partially apply when the fixed command queue fills. Keep any remaining live-control queue bounded, coalesced where appropriate, and report overflow to the caller.
- Prepare migration metadata off-thread. Apply only bounded, preallocated state-transfer work at safe block boundaries; if a migration cannot fit the configured real-time budget, defer activation or return an actionable error rather than blocking or silently resetting state.
- This is the target M1 architecture; it is a decision, not a claim that the current Engine already implements it. The current command queue can drop installs after its timeout, the retirement pending list can leak on overflow, and slot exhaustion can skip a layer.

## 2026-11-02: Reopen and complete native engine integration

- The owner explicitly authorizes the full native engine refactor and integration, superseding the earlier note that graph-to-Engine integration was paused.
- Start from the verified native-engine-foundation branch history, but integrate into the existing Engine/VM/mixer. Do not create a second engine or stop at interfaces and documentation.
- Keep the permanent engine blueprint, milestone ledger and recovery guide current; one coherent review PR is the delivery target.
- The graph compiler must not impose arbitrary node/connection/block caps. Resource limits must reflect actual memory, hardware and host safety budgets, with explicit errors and no silent content loss.

## 2026-11-02: Adaptive concurrency and batching

- Concurrency and batching are foundational capabilities, selected automatically according to graph dependencies, workload size, deadlines and available hardware.
- Parallelize independent work across graph branches, tracks, voices, channels and offline tasks where it yields a net benefit; batch compatible operations and use SIMD/accelerators when transfer and setup costs justify them.
- Avoid arbitrary thread counts and unconditional parallelism. Use bounded worker pools, adaptive task granularity, serial fast paths and controls against oversubscription.
- Preserve sample accuracy, deterministic semantics where required, audio deadlines and stable fallbacks. The audio callback must not block waiting for workers or accelerators.
- Optimize measured end-to-end performance, including scheduling, synchronization, memory movement, power and worst-case deadline margin—not just throughput or thread utilization.
- Full requirements: [Native engine refactor, Section 17](engine-next.md#17-adaptive-concurrency-batching-and-minimum-overhead-execution).

## 2026-11-02: Universal creative capability and routing

- The engine must make any technically realizable music/audio idea straightforward to create and combine; standard workflows are defaults, not creative limits.
- Use a universal typed multi-domain graph for audio, multichannel streams, sidechains, control/modulation, MIDI 1.0/2.0, notes, per-note expression, transport and timestamped events. Support cross-domain routing and explicit feedback/delay boundaries.
- Sidechain is first-class and can accept any compatible source, including audio, buses, tracks, external inputs, MIDI/events, envelopes and control signals. It must work across channels, processors and buses through the shared routing model.
- Avoid arbitrary fixed caps on project objects or graph complexity. Real constraints are available resources, platform/format requirements and explicit safety budgets. Surface unavoidable limits and never silently truncate.
- Make resource budgets configurable within host safety policy; enforce real-time bounded work, isolation, diagnostics, graceful bypass/recovery and clear failure reporting.
- Keep common workflows simple and fast while providing advanced extension interfaces for unusual processing, routing and execution models.
- Full requirements: [Native engine refactor, Section 16](engine-next.md#16-universal-creative-capability-safe-extensibility-and-unrestricted-composition).

## 2026-11-02: Safe extensibility for unconventional engine behavior

- The standard engine path is the efficient default, not a creative limitation. Developers must be able to build unusual generators, processors, effects, routing, modulation, synthesis and execution behaviors through explicit extension points.
- Provide composable standard interfaces and advanced interfaces where a generic abstraction would constrain a technique or add unnecessary overhead.
- Extensions declare capabilities, channel/event types, latency, resource needs, state and real-time requirements; validate and prepare them before activation.
- Protect the audio thread with bounded work, preallocated resources, defined failure/bypass/recovery behavior and clear isolation boundaries. In-process native extensions are trusted, not sandboxed; sandboxed VM modules remain constrained.
- Version extension APIs and state, preserve project compatibility through migration/capability negotiation, and isolate experimental interfaces from stable core contracts.
- Full requirements and verification are in [Native engine refactor](engine-next.md#16-safe-extensibility-and-deliberate-departures-from-standard-engine-behavior).

## 2026-11-02: Unified parameter, modulation and mathematical processing model

- Manual controls, project automation and internal/hidden modulation must use one shared parameter model across instruments, effects, tracks, buses, native modules and the .caw VM.
- Parameters may be exposed as simple user controls or remain internal; advanced modulation must not clutter ordinary workflows, and every exposed parameter should remain manually controllable.
- Support conventional automation, MIDI/controller input, macros, envelopes, LFOs, note expression, modulation links and sidechain/audio-following sources where available.
- Define explicit, deterministic source-combination, precedence, scaling, clamping and smoothing rules. Evaluate sample-accurately only where required; use block/control-rate processing where it preserves behavior and saves work.
- Mathematical expressions are first-class generators, waveform sources, modulation/control sources and audio effects, with bounded sandboxed execution and the existing .caw VM retained.
- Keep the cheapest correct path: constants stay constant, shared modulation is computed once where possible, and tables/precomputation are used only when worthwhile with a correct fallback.
- Detailed requirements and tests are in [Native engine refactor](engine-next.md#15-unified-parameters-modulation-automation-and-mathematical-modules).

## 2026-11-01: Native engine refactor and efficiency-first architecture

- The next major engine work is a refactor and integration of the existing CAW engine, not a ground-up rewrite or a parallel engine.
- Use proven professional audio-engine foundations and integrate the existing VM, synth, mixer, automation, renderer, typed module/graph and adaptive execution work into one coherent system.
- Avoid unnecessary work and complexity. Use the simplest correct implementation, and introduce additional processing only when requirements justify it.
- Prefer efficient mathematical/procedural DSP for suitable operations; use tables, wavetables, caches and precomputation when repeated work makes them worthwhile and memory permits. Keep the normal calculation path as a safe fallback.
- Detect and use compatible CPU, SIMD, GPU, memory, audio-device, connected-device, power and thermal capabilities when they provide a measured benefit. Keep portable implementations and safe fallbacks; optional hardware must never be required for project correctness.
- Evaluate existing permissively licensed/commercially usable libraries and proven algorithms before writing replacements. No GPL/AGPL, revenue-capped or commercial-only dependency without an explicit owner exception. Review exact versions and transitive licences and record every adopted dependency.
- Keep stereo as the efficient default while making the architecture capable of explicit mono and future multichannel processing.
- Preserve existing projects, modules, sound semantics, deterministic behavior, real-time callback invariants and live/offline render parity.
- The detailed technical plan is [Native engine refactor](engine-next.md). The canonical sequencing is [Roadmap](roadmap.md).

## 2026-11-02: Permanent roadmap and full production direction

- The C.A.W. roadmap is the permanent, canonical plan. It owns feature scope, sequencing, long-term capabilities, performance gates and explicit exclusions.
- Do not maintain competing master plans or separate feature-sequencing documents. Supporting notes may record factual implementation gaps or detailed technical designs, but the roadmap controls ordering.
- The long-term product direction includes the DAW capabilities discussed: non-destructive audio editing, sample authoring, complete mixer/routing, live MIDI and control surfaces, tempo maps, audio/MIDI recording, monitoring, latency compensation, punch/loop recording, takes/comping, plugin hosting, platform support, practical mastering tools, optional collaboration and surround/immersive audio.
- These capabilities are planned in dependency order, not claimed as implemented or all scheduled for immediate work.
- Video synchronization is not a current priority and is excluded from the roadmap unless the owner changes this decision.
- No in-app AI integration remains the current direction.

## 2026-11-01: No in-app AI integration in current scope

- Do not add AI generation, AI editing, source separation, model inference, cloud audio processing or AI-dependent sound features to C.A.W. for now.
- AI coding assistants may still be used externally as development tools; that does not authorize AI functionality in the shipped app or engine.
- Keep GitHub library synchronization/source picking separate and deferred; it is not implemented as an app workflow.

## 2026-10-31: Arrangement-first composition replaces the session grid

- **The old session grid is retired completely.** The Arranger is a horizontal song timeline with track lanes and reusable MIDI clip instances; no clip-launcher/session-grid alternate mode is retained.
- **Track ownership:** generators, effects and mix controls belong to tracks. Clips reference reusable pattern sources and own their start, length, source offset and loop behavior.
- **Folder routing:** nested folders can be organizational or stereo group buses. A bus sums child audio once and applies group volume/pan before routing to its parent or master.
- **Automation:** track volume and pan lanes follow song time and are interpolated in the native callback. Global and module-parameter automation remain future work.
- **Piano-roll multi-clip behavior:** selected companion clips are visible as read-only references; linked clips that share a source edit together. Editing multiple independent sources as one operation remains a follow-up.

## 2026-11-02: Graph compile and preparation require an explicit working-memory budget

- Graph compilation and prepared execution require a non-zero GraphResourceBudget.maxWorkingBytes; the API does not silently choose an arbitrary fixed node or connection cap.
- Optional maxNodes and maxConnections ceilings default to the representational maximum and may be set by host policy when a specific count ceiling is justified.
- Preflight estimates cover internal compiler temporaries and prepared executor buffers; caller-owned graph input and processor instances are excluded. The estimate is a preflight guard, not a replacement for handling allocator failure, which remains a distinct OutOfMemory result.
- The active Engine must eventually derive this budget from the hardware-aware EngineResourceBudget and pass it when preparing the graph. Until that integration exists, the graph API is budget-safe only when callers supply a realistic budget.
- This is implemented in code commit 07c796f8 and passed Engine, App and Docs CI at checkpoint 1269019. Follow-up commit e815b495 adds direct compiler-budget rejection coverage and awaits CI.

## 2026-11-02 — Effect-chain length is resource-governed, not a fixed product cap

Project layers and synth patches may describe dynamically sized module/effect chains. Parsing and engine preparation must preserve every authored chain element; no silent truncation or arbitrary eight-effect ceiling is allowed. Memory and processing costs are handled by explicit host resource budgets and clear preparation errors. This change does not remove unrelated limits such as the current project layer-slot model or export-buffer capacity; those remain separate integration work.

## 2026-11-06: Native C++ effects in playback (updated 2026-11-09)

**Implementation decision:** explicitly loaded stereo C++ effects run in two kinds of project-owned chain: a track's (`components` on a layer) and the master's (`master_components`), each entry an id or `{"id", "params"}`. A track's chain runs after its .caw modules, whose mono output enters as two equal channels, and before volume and pan; what the effects make of it stays stereo, and the pan law then works per side. The master's runs before the safety limiter, which stays last. Components between .caw modules wait for the dual-mono rule (#17). Folder buses take no components yet.

- One type, `ComponentChain`, serves both. It is built and activated on the control thread before anything is sent, so a component that is not loaded, has other ports or names a parameter it lacks refuses the whole update. An update with the same components in the same order keeps the chain, and its running state (a reverb's tail), and only sets values; any other change rebuilds it.
- Native effects without a tail start each play from silence (reset on Stop, and when a silent track sounds again), and a kept chain takes the project's values with the rest at their defaults, so playback matches a fresh render (export). A project runs at most 256 native component instances. Adding, removing or reordering a component rebuilds the whole chain, crossfaded over 20 ms while it sounds (the other components' tails restart).
- Parameter values ramp through the F6 resolver. `caw_engine_set_component_param` changes one while playing; the app stores it in the project too. Project automation lanes drive component parameters too (`target_type: component`).

- A successful build never loads or authorizes code. The caller must pass an explicit Blocked, Isolated or Trusted value to the Engine C API; Blocked refuses before opening the library, Isolated is rejected until a real separate-process host exists, and Trusted runs in-process.
- Trust is not serialized into the portable project. The project stores component IDs, order and values only; each user/device must make its own trust decision before the component can be used.
- The audio callback uses fixed preallocated stereo stages, performs no host allocation or locking, sanitizes output and publishes/retires master chains through the existing command/retirement path. Component code itself must obey the real-time contract.
- The known scratch and chain-pointer storage is included in Engine budgets. ABI v1 does not report component-private heap/state size; that remains an explicit measurement gap.
- Next (issue #137): the Android-hosted compiler, the per-component trust UI/store and the in-app C++ editor.
