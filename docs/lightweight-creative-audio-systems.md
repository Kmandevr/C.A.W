---
title: Lightweight creative audio systems plan
summary: Prioritized, performance-aware research plan for distinctive non-AI sound generation, transformation, exploration and inspection features.
covers: [engine/, app/lib/engine/]
updated: 2026-11-06
---

# Lightweight creative audio systems plan

This is the detailed design companion to the [two-part core development plan and complete feature list](core-and-feature-plan.md). It filters unconventional audio ideas through C.A.W.'s actual architecture and low-end-device requirements. It complements the [music workflow feature-gap plan](music-workflow-feature-gap-plan.md); it does not replace the existing piano-roll, mixer, audio-editing, sampling, MIDI or export work.

**Owner direction:** no AI integration in this work. No model inference, cloud processing, AI sound generation, AI-assisted editing or AI-dependent features. All proposed processing is conventional deterministic DSP, mathematics, algorithms and user-directed exploration.

## 1. Decision rules

A feature belongs in this plan only when it:

1. Adds a meaningful sound-design capability or a genuinely better way to explore sound.
2. Can reuse the current C++20 engine, public C++ SDK, project model, worker pool and app UI; the .caw module language is transitional, not the target authoring language.
3. Has bounded memory and predictable work; it cannot compromise the audio callback.
4. Can scale down gracefully on weak phones, or move optional expensive work to a bounded background/offline job.
5. Has a small first useful version. A feature that requires a new general-purpose framework is not a first-stage candidate.

### Existing architecture to preserve

**[Fact, checked 2026-11-03; app caps removed in F7.1 and the 64-bar song limit in F7.2, 2026-11-04; more than 64 layers within the memory budget since F7.3]** C.A.W. has a portable C++20 engine, deterministic transitional .caw VM, code-defined generators and effects, `param`, `global`, `export` and reusable `fn` functions, arithmetic and bitwise operations, patterns, a stereo mixer (routing between tracks, buses and master in 32-bit float since 2026-11-03; sample-peak meters per track, folder and master), offline rendering, a transport that resumes a pause where it stopped (2026-11-05), a native worker pool and an adaptive workload planner. Since Foundation F4.3 one planar N-channel graph runs live playback and offline render (a node per track module, then track, folder bus and master nodes, since F4.4); its executor runs typed sidechain, modulation and control ports since F5.1 and event (note/MIDI) ports since F5.2; one parameter resolver for manual, automation and modulation values (F6.1) feeds every graph node its parameters (F6.2), including modulation links between nodes (F6.3), automation lanes (F6.4) and MIDI CC mappings (F6.5), and the Engine's .caw params use it too (F6.6). See [engine](engine.md), [architecture](architecture.md), [engine implementation status](engine-build-status.md) and [performance](performance.md).

**[Fact, current transitional implementation]** The .caw module language is intentionally constrained: functions expand inline, cannot recurse, and the language is not a general-purpose array/loop environment. Stateful DSP built-ins own their state. New product work targets ordinary C++ and the shared C.A.W. Library/SDK; do not extend .caw as a parallel authoring language. The current public module contract is `engine/include/caw/module.hpp` (`CAW::SDK`), distributed as an installable CMake package with a manifest-driven local component build path. Explicitly loaded zero-parameter stereo effects now run through `ProjectDoc.masterComponents` in the live master chain, before the safety limiter. Parameter mapping and track-chain integration remain incomplete.

**[Fact]** The audio callback must remain bounded and must not allocate, lock, perform I/O, log, call the UI or execute unbounded work. Preparation, analysis, file access, expensive rendering and state destruction belong on control/background threads. The current project memory budget documented in [performance](performance.md) is 64 MB; that is a ceiling for the project, not a target for one feature.

## 2. Scoring model

Scores are planning estimates, not measured benchmarks.

- **Creative impact:** 1 (minor convenience) to 5 (could meaningfully distinguish C.A.W.).
- **Priority:** P0 (first within this creative-systems track, after the currently approved v2 commitments), P1 (high-value follow-on), P2 (optional later), P3 (do not schedule now). These labels do not supersede the current app-usable v2 order recorded in [engine implementation status](engine-build-status.md) or owner-approved work in the [music workflow plan](music-workflow-feature-gap-plan.md).
- **Engineering effort:** XS (small contained addition), S (small), M (moderate), L (large), XL (too broad for current scope).
- **Runtime cost:** expected additional cost while the feature is actively used. "Idle: none" means no background polling or processing when closed/not selected. Actual CPU, memory, battery and callback measurements are required before release.

| Candidate | Impact | Priority | Effort | Runtime / memory expectation | Decision |
|---|---:|---|---|---|---|
| Extend deterministic math modulation | 4 | P0 | XS–S | Very low; constant state | Keep; existing math, seeded noise, LFO and parameter/global modulation are the foundation |
| Compact cellular/bit-pattern generators | 4 | P0 | S–M | Very low with fixed-size state | Keep, bounded version |
| Extend waveshaping and waveform morphing | 5 | P0 | S–M | Low per sample; small tables if used | Keep; existing drive/fold/tanh and wavetable frame morph/phase warp are foundations |
| Small seeded variation explorer | 5 | P0 | M | Background/offline render; capped candidate count | Keep |
| Sound lineage/family metadata | 3 | P1 | S | Negligible DSP; small project metadata | Keep |
| Non-destructive operation history | 4 | P1 | M | Small metadata; avoid duplicate audio buffers | Keep |
| Asset/selection waveform and transient analysis | 4 | P1 | S–M | On-demand background analysis; small cache | Keep; Engine Lab already has a live master scope |
| Expand spectrum and asset inspection | 3 | P1 | M | On-demand FFT; bounded scratch buffer | Keep, optional; Engine Lab already has a 512-point master FFT view |
| Lightweight resonator models | 4 | P1 | M | Low–medium, fixed voice/state limits | Keep, small library |
| Expanded granular processor beyond existing glitch.stutter | 4 | P2 | M–L | Medium; fixed grain and buffer limits | Prototype later; basic bounded stutter is already implemented |
| Audio transformation stack / compositing | 4 | P2 | M–L | Depends on processing graph; reuse existing chains | Keep only as simple reusable modules |
| Full spectral painting / arbitrary spectral masks | 4 | P3 | XL | High CPU, memory and UI complexity | Drop from current plan |
| Full wavelet/reassignment editor | 2 | P3 | L–XL | High analysis and visualization complexity | Drop |
| Harmonic/percussive NMF separation | 3 | P3 | L–XL | High CPU and tuning burden | Drop |
| General-purpose physical simulation | 3 | P3 | XL | Unpredictable scope and cost | Drop |
| GPU audio-shader language/runtime | 2 | P3 | XL | New backend, portability and synchronization burden | Drop |
| Full multidimensional sound-space visualizer | 3 | P3 | L | UI and analysis overhead | Drop |
| Advanced phase-space editor | 2 | P3 | L | Difficult interaction for limited everyday benefit | Drop |
| AI generation/editing/source separation | — | P3 | — | Outside owner direction | Explicitly excluded |

## 3. Keep and develop

### 3.1 Deterministic mathematical modulation

**Purpose:** create evolving movement and unusual timbres from small mathematical expressions rather than adding large modulation engines.

**First version**
- Add documented examples and templates using existing math, arithmetic and bitwise functions.
- Provide bounded chaotic-style equations and deterministic pseudo-random sequences driven by project seed and sample/step position.
- Expose safe controls for rate, depth, offset, folding and quantization.
- Make results repeatable for the same project, seed and parameters.
- Let the resulting signal control existing parameters through the current modulation/export mechanism where possible.

**Do not build:** an unbounded differential-equation solver, arbitrary expression graph or a second modulation runtime.

**Effort:** XS–S if existing built-ins suffice; M only if a missing deterministic primitive is proven necessary.

**Cost:** very low when expressions use existing bounded VM operations. No extra work while playback is stopped.

**Acceptance:** golden-render tests prove repeatability; parameter extremes remain finite and bounded; benchmark shows no material callback regression.

### 3.2 Compact cellular and bit-pattern sound generators

**Purpose:** use local state-transition rules to create rhythmic, noisy, evolving and repeatable patterns.

**First version**
- Start with one-dimensional, fixed-width cellular automata or bit-register rules, not a general two-dimensional simulation.
- Store state in a fixed-width integer or small fixed-size state object.
- Support a small set of rules, seed, density, clock division and output mapping.
- Map output to gates, rhythm, pitch offsets, wavetable selection or modulation.
- Permit deterministic reset and exact offline/playback agreement.
- Include presets that demonstrate drum triggers, evolving pulses and noisy modulation.

**Important implementation caveat:** the current module language is not a general array/loop language. Do not try to express an arbitrary grid simulation in user code. Prefer a small, bounded built-in or library primitive with fixed state and a clear interface. Only add native state if the creative result cannot be achieved with existing bitwise expressions.

**Effort:** S for a bit-register/one-dimensional first version; M if new stateful VM primitives and serialization are needed.

**Cost:** very low when state is fixed and updated at a bounded clock rate. Avoid updating a large grid for every sample.

**Acceptance:** deterministic golden renders, fixed maximum state size, bounded update count, reset/seed tests and a phone-profile benchmark.

**Research basis:** cellular automata have been studied as a sound-synthesis method, including the challenge of making their autonomous behaviour controllable for sound design. C.A.W.'s small, user-controlled version should deliberately avoid the complexity of a general CA synthesis system. [University of Plymouth research](https://researchportal.plymouth.ac.uk/en/studentTheses/sound-synthesis-with-cellular-automata/).

### 3.3 Waveshaping and waveform morphing

**Purpose:** provide distinctive timbres using direct mathematical transformation and controlled movement between wave shapes.

**First version**
- Expose useful waveshaping functions: soft/hard saturation, fold, rectify, asymmetry and user-defined bounded transfer curves where the language permits.
- Morph between a small number of analytic waveform shapes using a normalized blend parameter.
- Reuse current oscillators and wavetable/export path wherever possible.
- Add oversampling only for a demonstrated aliasing problem and only as an optional quality setting; do not make it the default on weak devices.
- Make all parameters automatable using the existing parameter/modulation model.

**Do not build:** a separate GPU shader system, unlimited wavetable editor or a large always-running oversampling framework.

**Effort:** S–M depending on whether the current built-ins already cover the transfer functions.

**Cost:** low for basic waveshaping and analytic morphing; optional oversampling costs more and must be explicitly bounded.

**Acceptance:** tests cover DC, NaN/Inf, amplitude bounds, aliasing examples and bit-exact deterministic output where promised. Benchmarks compare basic and optional oversampled modes.

### 3.4 Seeded sound-variation explorer

**Purpose:** let a person discover useful variations without manually moving every control or listening to hundreds of renders.

**First version**
- Select a module and choose which parameters may vary.
- Generate a small batch, initially 8 candidates and at most 16 in the first release.
- Use bounded seeded perturbations, parameter-aware ranges and optional constraints.
- Render candidates in the existing background/offline worker system, never in the audio callback.
- Present compact audition tiles with play, compare, keep, discard and regenerate.
- Let the user pin parameters and vary only the rest.
- Store the chosen result as ordinary module code/parameter values so it remains editable and portable.

**Do not build:** neural search, cloud services, huge genetic populations, automatic aesthetic scoring, always-running background search or a complex multidimensional map.

**Later extension:** user-directed parent selection and simple crossover between compatible parameter sets. Only add this if the first variation workflow proves useful.

**Effort:** M; most work is UI, job orchestration, candidate identity and safe project state—not a new DSP engine.

**Cost:** bounded background CPU during explicit generation; candidate count and render duration are capped. Memory is limited by sequential rendering and a small preview cache, not keeping every full render in RAM.

**Acceptance:** same seed and settings reproduce the same candidates; cancellation works; candidate generation never blocks playback; the UI remains responsive; memory returns to baseline after candidates are discarded.

**Research basis:** interactive evolutionary sound exploration is an established research direction. The cited AES system explores synthesis through evolutionary algorithms; C.A.W. should take the human-directed exploration pattern while keeping its first version simpler and fully deterministic. [AES paper, 2024](https://doi.org/10.17743/jaes.2022.0137).

### 3.5 Sound lineage and family metadata

**Purpose:** preserve how a sound was discovered, without duplicating large audio files.

**First version**
- Store parent asset/module ID, variation seed, changed parameter values, source version/hash and a short user label.
- Show a simple parent → variation relationship and allow branching from a selected result.
- Keep sound data as normal modules/assets; lineage is optional metadata.
- Avoid retaining full audio renders or copying source buffers for each child.
- Handle missing parents gracefully; a sound remains usable if its history is unavailable.

**Effort:** S once the variation explorer has stable candidate IDs.

**Cost:** negligible playback cost; small storage metadata.

**Acceptance:** project save/load preserves lineage; deleting or moving a parent does not break a child; export remains independent of lineage metadata.

### 3.6 Non-destructive processing history

**Purpose:** make experimentation reversible and explainable, borrowing the useful part of CAD feature history and software version control.

**First version**
- Record user operations and parameter/code snapshots, not complete duplicated audio buffers.
- Reuse the app's existing undo/redo and project serialization model where possible.
- Add named checkpoints for important sound states.
- Allow A/B comparison of current and checkpoint versions.
- Keep history bounded by count and storage budget; make pruning explicit and safe.
- For future imported audio, store an operation recipe referencing the original asset rather than rewriting it.

**Do not build:** a full node-graph version-control system, infinite undo, or a second project database.

**Effort:** M because correctness across existing app editing and persistence matters more than the UI.

**Cost:** negligible DSP cost; bounded metadata storage. Audio snapshots should be opt-in and stored on disk, not duplicated in RAM.

**Acceptance:** undo/redo survives save/reopen as specified; restoring a checkpoint reproduces its sound; history pruning never deletes a source asset still in use.

### 3.7 Asset waveform and transient inspection

**Current foundation:** Engine Lab already shows a read-only live master scope. This proposal extends waveform inspection to selected renders or imported assets and adds optional transient markers; it does not claim that C.A.W. has no waveform display.

**First version**
- Reuse waveform data already available from preview/render when possible.
- Calculate min/max peak envelopes for zoomed-out waveform display.
- Add a simple transient/attack detector using bounded energy change and threshold/hysteresis.
- Show detected markers as suggestions; allow user adjustment and disable.
- Run analysis on a worker when a file is loaded or explicitly requested.
- Cache only a bounded summary keyed by asset hash and analysis settings.

**Do not build:** source separation, automatic beat transcription or a large ML classifier.

**Effort:** S–M.

**Cost:** low background work on demand; small cache. No continuous analysis while idle.

**Acceptance:** tests use known impulses, drum hits, sustained tones and noisy material; false positives are visible/editable; analysis never blocks playback or file browsing.

### 3.8 Expanded spectrum and asset inspection

**Current foundation:** Engine Lab already displays a read-only 512-point Hann-window FFT of the mono master scope, spanning 0–24 kHz. This proposal is for extending analysis to captured selections or imported assets, not adding C.A.W.'s first spectrum display.

**First version**
- Reuse the existing FFT implementation and add an on-demand logarithmic-frequency view with peak hold for a captured selection or asset, if the workflow proves useful.
- Use a fixed maximum FFT size and preallocated scratch storage.
- Compute on a worker from a captured preview/render block or asset, not in the callback.
- Refresh only while the inspector is open and at a low, bounded rate.
- Keep the display optional and compact on phone.

**Do not build:** arbitrary spectral painting, wavelet analysis, time-frequency reassignment or a second real-time audio engine.

**Effort:** M, including display and data handoff.

**Cost:** low–medium only while visible; fixed scratch memory and capped update rate.

**Acceptance:** FFT correctness tests, fixed maximum memory, no callback calls, no idle work and a frame-rate test on a phone-sized layout.

### 3.9 Small physical/resonator model library

**Purpose:** add a few distinctive physically-inspired instruments without a general physics simulation system.

**First version**
- Begin with simple comb/resonator structures and a small modal or digital-waveguide string/metallic model.
- Use fixed delay/state buffers, fixed voice limits and bounded parameter ranges.
- Expose intuitive parameters such as length/pitch, damping, stiffness/brightness and excitation.
- Support deterministic excitation and stable parameter changes.
- Reuse the existing module and voice lifecycle; do not create a separate instrument host.

**Do not build:** finite-difference physical simulation, fluid/cloth/rigid-body simulation, arbitrary 3D geometry or a general physical modelling language.

**Effort:** M for a small library; L if a new stateful synthesis architecture is required. If the latter is required, defer.

**Cost:** low–medium depending on voice count and delay lengths. Voice and buffer budgets must be explicit.

**Research basis:** digital waveguides are a well-established, comparatively efficient way to model acoustic propagation and have enabled real-time physical instruments and effects. This supports investigating a small waveguide/resonator family, not a broad simulation framework. [AES review, 2026](https://doi.org/10.17743/jaes.2026.0283).

### 3.10 Expanded granular processing beyond existing stutter

**Purpose:** add controlled micro-rearrangement, repeat, freeze and texture effects.

**First version, only after earlier work**
- Start with short fixed-window grain playback and only add repeat variants if they are meaningfully different from the existing glitch.stutter.
- Set hard limits for grain count, duration, overlap and buffer size.
- Preallocate all buffers during preparation.
- Provide a quality/voice limit that can be reduced under device pressure.
- Keep the effect bypassed or inactive when unused.
- Prefer simple sample-window operations before adding pitch-independent time stretching.

**Do not build:** unlimited granular networks, arbitrary spectral grains, large sample-history buffers or a full granular workstation.

**Effort:** M–L.

**Cost:** medium and content-dependent; must be measured on weak hardware. This is deliberately P2 rather than a foundation.

**Acceptance:** worst-case voice/buffer benchmarks, no allocations or locks in callback, stable overload behaviour, deterministic output and clear memory accounting.

## 4. Explicitly removed from the current plan

These concepts should not be scheduled as C.A.W. features under the present constraints:

- Full wavelet/scalogram editing and time-frequency reassignment.
- Arbitrary spectrogram painting and frequency-region compositing.
- Harmonic/percussive separation using NMF or similarly heavy decomposition.
- General-purpose physical simulation.
- GPU audio shaders or a new shader language/runtime.
- Large multidimensional sound-space visualizers.
- Advanced phase-space editing.
- Complex automatic sound repair/restoration.
- Large evolutionary populations or unattended sound-search processes.
- AI generation, AI editing, AI separation, model inference and cloud audio services.

If a future concrete use case changes this decision, reopen it as a new proposal with a measured prototype—not as an assumption.

## 5. Recommended build sequence

This is a priority order for the creative-systems work only. Complete or explicitly reprioritize the current app-usable v2 commitments first (module/global automation, SFZ and stems export, as recorded in [engine implementation status](engine-build-status.md)). This sequence does not silently replace that work or the music workflow gap sequence.

| Phase | Work | Why this order | Exit condition |
|---|---|---|---|
| 0 | Verify existing functions and current UI/engine support | Avoid duplicate built-ins and incorrect assumptions | Code-level inventory and baseline benchmarks |
| 1 | Math modulation, bit-pattern/compact cellular primitives, waveshaping and waveform morphing | Highest creative value for lowest runtime cost | Unit/golden tests; templates; callback benchmark |
| 2 | Seeded variation explorer | Builds on existing parameters, deterministic render and worker pool | 8–16 repeatable candidates; cancel/keep/discard; bounded memory |
| 3 | Lineage metadata and bounded history/checkpoints | Makes exploration safe and reusable | Save/load, undo/redo and history tests |
| 4 | Waveform/transient inspection and expanded spectrum/asset analysis | Helps users understand and edit results | On-demand analysis, bounded cache, phone UI validation |
| 5 | Small resonator/waveguide library | Distinctive instruments after state/voice budget patterns are proven | Several useful models, fixed state/voice caps, benchmark |
| 6 | Expanded granular prototype beyond existing glitch.stutter | Higher processing cost; only proceed if demand and headroom justify it | Measured worst-case profile and safe quality limit |

Do not start a later phase merely because an earlier phase is documented. Each phase must pass its exit condition and the owner can reprioritize based on actual use.

## 6. Shared engineering rules

### Real-time safety
- No allocations, frees, locks, I/O, logging, UI calls, exceptions or unbounded loops in the callback or any function it calls.
- Prepare buffers, tables, coefficients and processor state off the callback.
- Publish prepared state through the established safe handoff pattern; reclaim old state off the audio thread.
- Every loop, voice count, grain count, table size and buffer size has a hard upper bound.
- Any processor that cannot prove bounded callback work must render offline or be rejected from live playback.

### Device adaptation
- Idle means no analysis, candidate generation, polling or periodic refresh.
- Use the existing worker pool and adaptive workload planner for explicit background jobs; do not create a second scheduler.
- Prefer one candidate render at a time on weak devices; allow limited parallelism only when the current device budget supports it.
- Reduce optional analysis resolution, candidate count, grain count or voice count under thermal/battery pressure.
- Never silently change the sound of a saved/offline export to save CPU. Preview quality may degrade only if clearly labelled; final offline rendering remains deterministic and full quality.
- Respect the existing project memory budget and define per-feature caps before implementation.

### Determinism and safety
- Same module, project seed, parameters and render settings must reproduce the same samples wherever the engine promises deterministic output.
- Clamp or validate parameters; handle NaN/Inf and denormal-sensitive paths safely.
- Add unit tests and golden renders for sound-producing changes.
- Add worst-case benchmarks, not just average-case measurements.
- Verify cancellation, state teardown and project close while background jobs are active.

### UI and usability
- Keep the existing Builder/Arranger/Mixer model; do not create a separate scientific workstation.
- Phone-first controls: small number of meaningful parameters, clear defaults, compact inspector panels and large touch targets.
- Make advanced controls expandable rather than permanently visible.
- Every exploration result can be auditioned, kept or discarded without losing the current sound.
- Provide keyboard/action access on desktop and accessible touch equivalents.

## 7. Performance verification gates

Before a feature is accepted:

1. Record baseline and after measurements using `caw_bench` and the existing test suite.
2. Measure mean, p99 and maximum callback time, not just average CPU.
3. Measure peak memory and retained memory after cancellation, close and repeated use.
4. Benchmark the worst supported configuration: maximum voices, maximum grain count, maximum candidate batch or maximum analysis size.
5. Confirm that stopped/idle mode adds no recurring work.
6. Confirm background jobs yield/cancel and do not starve live playback.
7. Run golden-render tests for deterministic output.
8. Verify on a real low-end Android device before calling the performance target achieved. Cloud CI timings are comparison data, not phone measurements.

A feature is rejected or redesigned if it causes dropouts, unbounded memory growth, unexplained idle load, or a material regression in the existing starter/64-layer benchmark without a justified owner-approved trade-off.

## 8. Research references

These sources establish that the underlying techniques are real research directions; they do not prove that every proposed C.A.W. implementation will be lightweight.

- [Sound Synthesis With Cellular Automata — University of Plymouth](https://researchportal.plymouth.ac.uk/en/studentTheses/sound-synthesis-with-cellular-automata/): examines cellular automata for dynamic sound synthesis and the challenge of making their behaviour controllable for sound design.
- [A System for Sonic Explorations With Evolutionary Algorithms — AES, 2024](https://doi.org/10.17743/jaes.2022.0137): an established example of interactive evolutionary sound exploration. C.A.W.'s first version intentionally uses simpler deterministic parameter variation, not neural or unattended search.
- [Four Decades of Digital Waveguides — AES, 2026](https://doi.org/10.17743/jaes.2026.0283): review of efficient physical modelling approaches and their real-time instrument/effect applications.
- [Real-time audio best practices](https://truce.audio/docs/guide/best-practices/): practical guidance on bounded callback work, preallocation and avoiding blocking operations. C.A.W.'s own engine rules remain authoritative.

## 9. Review outcome

**Recommended now:** Phase 0 inventory, then Phase 1 math/bit-pattern/waveshaping/morphing work. These offer the best expected creative return per unit of engineering effort and runtime cost.

**Recommended after proof:** the small seeded variation explorer, history/lineage and on-demand inspection. These add a distinctive creative workflow while keeping expensive work off the callback.

**Conditional:** physical resonators and granular processing. Keep their scope narrow and require measured phone headroom before expanding.

**Removed:** high-cost spectral decomposition/editing, general simulation, GPU shader infrastructure, complex visualization, and all AI features.

No feature in this document is implemented merely because it appears here. Implementation must begin with a code-level gap check, a small issue/PR scope, tests and measured performance evidence.
