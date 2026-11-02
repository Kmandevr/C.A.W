---
title: C.A.W. core development plan and complete feature list
summary: Two-part master plan: ordered core build sequence first, then the complete owner-discussed feature inventory with priorities, costs and scope.
updated: 2026-11-01
---

# C.A.W. — Core Development Plan and Complete Feature List

This is the single planning entry point for the work discussed across this planning session. It has two parts:

1. **Core development plan:** what to finish first, in dependency order, with measurable exit gates.
2. **Complete feature list:** the full inventory of music-workflow, sound-design, engine, UI, platform and delivery capabilities discussed, including deferred and excluded ideas.

The core plan controls sequencing. The feature list preserves scope so lower-priority ideas are not forgotten or accidentally treated as current work. The linked [music workflow feature-gap plan](music-workflow-feature-gap-plan.md) and [lightweight creative audio systems plan](lightweight-creative-audio-systems.md) retain detailed audits and implementation specifications.

## Owner direction and non-negotiable rules

- C.A.W. remains a phone-first, code-driven sound and music workspace, not a conventional DAW. Useful arrangement and editing workflows are still wanted where they support the product.
- **No AI integration in this plan:** no AI generation, AI editing, source separation, model inference, cloud audio processing or AI-dependent features.
- Work from the actual repository and current implementation. A roadmap item is not evidence that a feature exists. Re-check code before implementing anything listed here.
- Keep one shared project model, pattern model, asset model, engine and processing path. Extend existing systems instead of creating parallel incompatible frameworks.
- Run locally and work offline; keep phone and desktop workflows coherent, with touch-first controls and full keyboard/mouse access.
- Target very weak phones as well as stronger mobile and desktop hardware. Scale work to available resources; do not impose unnecessary overhead on capable hardware or waste resources on weak hardware.
- Audio callback work stays bounded, allocation-free, lock-free and free of I/O, logging, UI calls and unbounded loops. Prepare, analyze, render and reclaim state off the callback.
- Use the existing worker pool and adaptive workload planner. Do not introduce a second scheduler or background polling when a feature is idle.
- Keep saved/offline render quality stable. If preview quality is reduced under load, label it; never silently degrade final exports.
- Every feature needs relevant model/serialization, engine, UI and performance tests. Keep CI green; never weaken or skip tests to make it pass.
- Preserve current approved v2 commitments and their status. Any change in priority requires the owner's direction.

## Current implementation snapshot (checked 2026-11-01)

This is the repository baseline before future work. The linked app/engine references contain the detailed evidence.

| Area | What exists now | What is not yet complete |
|---|---|---|
| App and platforms | Eight Flutter workspaces; Android and Windows app CI artifacts | iOS/macOS release builds; Linux app is not a shipped CI artifact |
| Engine | Portable C++20 engine, constrained module VM, native stereo playback/mixer, offline renderer, bounded worker pool and adaptive workload policy | Not every modular graph/native-module foundation is integrated into the active VM/mixer path |
| Pattern editing | Piano roll, drum grid, note expressions, lane curves, pattern generators, MIDI file import/export | Kit-row routing, code-generated procedural patterns/Freeze, advanced groove/quantize extensions |
| Arrangement | MIDI clip timeline, linked/independent clips, nested folders, stereo folder buses, track/folder volume-pan automation | Audio clips, clip automation, markers/sections and consolidation |
| Mixer | Track volume/pan/mute/solo, generator/effect chains, folder buses and master output | Sends, general sidechain routing, parallel paths and master effect chains |
| Sound/synth | Code generators/effects, house synth patch compiler/playback, built-in wavetable morph/phase warp, LFOs and modulation matrix | Custom/imported wavetable authoring, drawn LFO curves and additional warp modes |
| MIDI | MIDI pattern file import/export and MIDI 2.0 UMP decoder/input-queue primitive | USB/Bluetooth device I/O, controller learn, clock and live Engine voice routing |
| Export | WAV loop/free-length/one-shot/wavetable, MIDI, profiles/history and bounded in-memory queue | SFZ multisample export, stems, persistent queue and broader batch delivery |
| Audio assets | Generated audio and module/effect processing | Audio-file import, audio clip editing, sample editor, multisample mapping |
| Plugins | Plugin Builder validates/packages native .caw source; native SDK/graph foundations exist | Dynamic native loading, process isolation, CLAP/VST3 binary build/hosting |
| AI | External coding assistants may be used as development tools | No in-app AI, model inference or cloud-audio integration is in current scope |

**Status rule:** a row in Part II is an inventory of product scope, not proof of implementation. If a capability is not listed as existing above or verified in [App](app.md)/[Engine implementation status](engine-build-status.md), treat it as planned, partial or conditional—not shipped.

## Part I — Core development plan

### Core order at a glance

| Order | Workstream | Why it comes here | Exit condition |
|---:|---|---|---|
| 0 | Finish already-approved v2 commitments | Existing commitments, not optional new ideas | Module/global automation, SFZ workflow and stems export integrated, tested and documented |
| 1 | Finish pattern and piano-roll workflow | Completes the core musical editing loop | Note editing, expression curves, generators and editing gestures work end-to-end |
| 2 | Complete mixer and routing | Needed before complex track/effect workflows | Sends, sidechain, parallel routing and master FX use the real engine |
| 3 | Add basic non-destructive audio clips | Opens the project to imported audio | Import, preview, arrange, trim, split, fades and gain preserve originals |
| 4 | Complete sample authoring and multisampling | Builds on the common audio asset model | Sample editing, zones, velocity layers, round-robin and WAV/SFZ work |
| 5 | Complete live MIDI hardware | Builds on existing MIDI 2.0/UMP and port foundations | USB/Bluetooth connection, mapping, clock and reconnect are dependable |
| 6 | Improve arrangement and delivery | Depends on editing, routing and asset foundations | Clip automation, markers/sections, consolidation, stems and batch export work |
| 7 | Add lightweight creative sound systems | Distinctive sound design after core workflow foundations | Each feature passes quality, determinism and low-end performance gates |
| 8 | Conditional advanced tools | Higher cost or less certain everyday value | Prototype proves demand and acceptable device cost |
| 9 | Platform/plugin and commercial delivery | Depends on stable engine interfaces and release readiness | Supported builds, plugin formats/hosting and release requirements are verified |

### Phase 0 — Existing v2 commitments

These remain ahead of the new creative-systems track unless the owner explicitly reprioritizes them.

- Complete automation for module parameters and project globals, including engine connection and serialization.
- Complete the SFZ workflow, including the existing WAV/SFZ multisample commitment.
- Complete stems export and integrate it with the native export pipeline.
- Preserve existing pattern, mixer, MIDI, arrangement and export foundations; do not rebuild them as part of these tasks.
- Reconcile status documentation against code and CI as each item is completed.

**Exit gate:** each commitment is usable through the app, covered by tests, documented accurately and verified by applicable CI. A design or partial engine API does not count as complete integration.

### Phase 1 — Extend the existing pattern and piano-roll workflow

**Already implemented:** shared text-backed pattern model; piano roll and drum grid; draw/select/curve/erase tools; adaptive grid and snap; note preview; velocity/chance lanes; per-note pitch, pressure/volume, timbre and vibrato expression; multi-selection and linked/independent clip multi-edit; touch and keyboard actions; Euclidean, random-in-key, arpeggiate, humanize, chord stamp, legato, reverse and pitch inversion. See [App](app.md) and the [music workflow gap plan](music-workflow-feature-gap-plan.md).

**Remaining extensions, not missing foundations:**
- Improve advanced quantization, groove/swing templates and note chop/glue/strum only where a concrete workflow justifies them.
- Continue refining curve editing, live preview, touch ergonomics and keyboard access based on tested gaps.
- Keep drum grid, piano roll and text editing on the same pattern model.
- Preserve arrangement-to-roll navigation and linked/independent source semantics.

**Exit gate:** any remaining extension has model/serialization, engine and UI regression coverage as appropriate; existing pattern data remains compatible; phone layouts do not overflow.

### Phase 2 — Complete mixer and routing

- Complete flexible sends and returns, sidechain routing, parallel paths and master effects.
- Extend the current folder-bus model only where needed; do not create a second mixer or routing graph.
- Connect routing to the native engine rather than simulating controls in the UI.
- Preserve stereo signal paths and clear track/folder/master boundaries.
- Add routing visualization and practical controls without making the phone layout unusable.
- Keep processing order deterministic and callback work bounded.

**Exit gate:** real audio routing tests cover send levels, sidechain behavior, parallel paths, master processing, channel isolation, stereo behavior and overload handling.

### Phase 3 — Basic non-destructive audio assets and clips

- Import common audio files and preview them locally.
- Show waveform summaries and place audio clips on the existing arrangement timeline.
- Support trim, split, move, duplicate, source offset, loop, fade-in/out, clip gain and reverse.
- Keep edits non-destructive: preserve the original asset and store clip operations/parameters.
- Use the same asset identity and processing path for generated and imported audio.
- Reuse existing effect/module chains for processing; do not introduce a separate incompatible audio editor.

**Exit gate:** project save/reopen preserves source references and edits; missing assets are reported clearly; edits do not modify originals; preview and arrangement remain responsive on phone.

### Phase 4 — Sample authoring and multisampling

- Add sample editing for crop/trim, fades, gain/normalization, reverse and loop points.
- Add sampler zones with key ranges, velocity layers and round-robin groups.
- Support audition/preview and a practical mapping editor.
- Complete WAV and SFZ multisample interchange, with consistent asset references.
- Add transient slicing and sample-to-pattern workflows after the basic editor and mapping are reliable.
- Keep generated audio, imported samples and multisample zones on a shared asset model.

**Exit gate:** sample projects save/load, mapping and velocity selection are deterministic, SFZ/WAV interchange is tested, and memory limits are explicit.

### Phase 5 — Live MIDI hardware and performance

- Connect real USB and Bluetooth MIDI devices through the existing MIDI 2.0/UMP foundations.
- Add device discovery, selection, status, connect/disconnect and reconnect handling.
- Route notes and CC; add controller learn/mapping.
- Add MIDI clock input/output and sync where supported.
- Keep on-screen performance keys and metronome/count-in as practical live-entry tools.
- Test timing, device loss, reconnect, duplicate events and lifecycle cleanup across supported platforms.

**Exit gate:** hardware connection is verified on real supported devices; device loss/reconnect is safe; timing and routing tests pass. Decoder support alone does not count as hardware connectivity.

### Phase 6 — Arrangement and delivery

- Improve markers, sections and navigation across longer arrangements.
- Add clip-following automation and finish automation integration for parameters, modulation and processing behavior where supported by the shared engine model.
- Add consolidation/bounce and render selected tracks or groups.
- Complete stems, batch export and persistent export-queue behavior as specified by approved export work.
- Keep export options, progress, cancellation, errors and output locations understandable on phone and desktop.
- Ensure export is deterministic where the engine promises it, without claiming cross-device bit identity where it is not guaranteed.

**Exit gate:** arrangement edits and automation survive project reload; batch/stems output has correct routing, naming, length and alignment; cancellation and failure cleanup are tested.

### Phase 7 — Lightweight creative sound systems

Build only after Phase 0 commitments and without blocking Phases 1–6 when a workflow dependency is more important. Priority labels below are relative to this creative-systems phase.

1. **Extend deterministic mathematical modulation** — XS–S; impact 4/5; creative P0; build on existing deterministic math, seeded noise, LFOs and parameter/global modulation.
2. **Compact cellular/bit-pattern generators** — S–M; impact 4/5; creative P0.
3. **Extend waveshaping and waveform morphing** — S–M; impact 5/5; creative P0; build on existing drive/fold/tanh and wavetable frame morph/phase warp.
4. **Small seeded sound-variation explorer** — M; impact 5/5; creative P0; 8 candidates initially, hard cap 16, explicit user action, background/offline rendering.
5. **Sound lineage/family metadata** — S; impact 3/5; creative P1.
6. **Non-destructive processing history/checkpoints** — M; impact 4/5; creative P1; store recipes/metadata rather than duplicate audio buffers.
7. **Asset/selection waveform and transient analysis** — S–M; impact 4/5; creative P1; the Engine Lab already has a live master scope, so any new work should extend it to assets/selections with on-demand background analysis.
8. **Extend spectrum inspection to asset/selection analysis** — M; impact 3/5; creative P1; the Engine Lab already has a bounded 512-point master FFT view, so any expansion must reuse it rather than claim the first spectrum display is missing.
9. **Small resonator/physical-model library** — M; impact 4/5; creative P1; fixed voices/state and simple comb, modal or digital-waveguide models.

Each item gets its own implementation issue, code audit, acceptance criteria and measured performance review before work starts. Do not implement the whole phase as one oversized change.

### Phase 8 — Conditional advanced tools

- **Expanded granular processing:** M–L; impact 4/5; creative P2. The existing engine already has a bounded glitch.stutter effect; any later granular work must add a distinct useful capability using short fixed-window grains and hard caps on grain count, duration, overlap and buffer size.
- **Simple reusable audio transformation stack:** M–L; impact 4/5; reuse existing chains and module/effect composition. No new universal compositing framework.
- **Parent selection/crossover for variation exploration:** only if the first seeded explorer proves useful; keep it user-directed and bounded.
- **Optional oversampling:** only when measured aliasing warrants it; optional quality mode, never an unconditional weak-device cost.
- **Time stretching/warping, advanced transient tools and restoration:** only after basic audio clips/sampling and a concrete use case.
- **Advanced analysis or visualization:** require a measured prototype and clear user benefit before adding cost.

**Promotion gate:** a prototype must demonstrate a useful workflow, bounded worst-case CPU/RAM, safe cancellation and acceptable performance on a weak Android profile before it becomes committed work.

### Phase 9 — Platform, plugins and delivery

- Keep Android first, with Windows desktop alongside it; maintain iOS, macOS and Linux portability through the shared engine where feasible.
- Continue using native C++ engine interfaces shared by the app and CLI.
- Complete CLAP/VST3/AU integration only after the native plugin host/SDK, lifecycle, sandboxing, licensing and platform packaging are real and tested.
- Keep Plugin Builder's .caw module authoring distinct from compiling or hosting external binary plugins.
- Support desktop workflows and Reaper handoff without making a full desktop DAW a prerequisite.
- Complete signing, install, privacy, release and commercial delivery requirements before distribution.

**Exit gate:** each supported platform has CI builds and platform-specific smoke tests; plugin claims match actual host/SDK support; release artifacts are signed and installable.

### Cross-cutting performance and quality gates

- Measure CPU, callback p99/max duration, memory, allocations, battery/thermal behavior and UI frame time on weak and strong devices.
- Keep idle overhead near zero: no recurring analysis, polling or background search when features are closed or unused.
- Reuse the current worker pool/adaptive planner for bounded background tasks. Parallelize independent preparation/render jobs only when hardware and workload justify it; avoid oversubscription and contention.
- Make voice counts, grain counts, buffer sizes, FFT sizes, candidate counts, cache sizes and iteration counts explicit hard limits.
- Degrade optional preview/visual work gracefully under pressure; do not silently change saved assets or final export quality.
- Test deterministic seeds, offline/playback agreement, NaN/Inf handling, cancellation, project save/load, memory recovery after repeated use and cleanup after failures.
- Require actual low-end Android testing before claiming the product meets the potato-device target.

## Part II — Complete feature list

This inventory preserves the features and directions discussed. The current baseline is in the snapshot above. Status terms are planning labels, not claims that code exists: **Existing foundation** means some relevant implementation is present; **Complete** must be confirmed against code; **Planned** means not yet complete; **Conditional** means prototype/owner approval required; **Excluded** means not in current scope.

### A. Core creation and sound design

| Feature | Status / scope | Impact | Effort | Priority |
|---|---|---:|---|---|
| Code-defined generators and effects; reusable modules | Existing foundation; extend, do not replace | 5 | — | Core |
| Module parameters, project globals, exported signals and functions | Existing foundation; finish automation integration | 5 | M | Phase 0 |
| Bytebeat, bit tools, procedural synthesis and raw audio mangling | Existing foundation; preserve deterministic semantics | 5 | — | Core |
| Extended deterministic math modulation and seeded pseudo-random sequences | Existing foundation: deterministic math, seeded noise, LFOs and parameter/global modulation; proposed additions must identify a specific missing primitive | 4 | XS–S | Creative P0 |
| Compact cellular automata / bit-register generators | Planned; fixed-width, one-dimensional first version | 4 | S–M | Creative P0 |
| Expanded waveshaping: saturation, fold, rectify, asymmetry and bounded transfer curves | Existing foundation: tanh, drive, fold and wavetable phase distortion; custom transfer curves remain proposed | 5 | S–M | Creative P0 |
| Expanded analytic waveform morphing and wavetable authoring | Existing foundation: built-in wavetable playback, frame morphing and phase warp; custom/imported table authoring remains incomplete | 5 | S–M | Creative P0 |
| Seeded sound-variation explorer | Planned; 8–16 bounded candidates, user-directed | 5 | M | Creative P0 |
| Sound lineage/family metadata | Planned; parent, seed, changed parameters and source identity | 3 | S | Creative P1 |
| Non-destructive processing history/checkpoints | Planned; operation recipes, bounded metadata and A/B | 4 | M | Creative P1 |
| Lightweight resonator/modal/digital-waveguide instruments | Planned; fixed voice/state limits | 4 | M | Creative P1 |
| Expanded granular processor / advanced stutter variants | Conditional; existing glitch.stutter is implemented; any extension must keep bounded grain and buffer counts | 4 | M–L | Creative P2 |
| Reusable audio transformation chains | Existing effect-chain foundation; keep composition simple | 4 | M–L | Conditional P2 |

### B. Pattern, piano roll and musical editing

- Arrangement-first timeline with reusable MIDI clips; the retired session/clip-launcher grid is not to return as an alternate composition view.
- Shared pattern model edited through text, piano roll and drum grid.
- Piano roll with adaptive/fixed grid, snap/free timing, zoom, scrolling and scale/key highlighting without forcing notes into key.
- Draw, Select, Curve and Erase tools; large touch targets and keyboard equivalents.
- Note creation by tap or drag; drag note length; move, resize, duplicate, delete and multi-select.
- Live preview while creating/moving notes and chords.
- Velocity lane; probability, ratchet, slide and custom per-note values.
- Pitch and other expression curves, freehand drawing refined into points and handles, with snap and live preview.
- Curves both on notes and as stacked lanes where useful.
- Chord stamping; Euclidean, random-in-key, arpeggiate and humanize generators.
- Quantization, groove, note utilities and per-repeat procedural variation/freeze.
- Copy/paste/move through visible on-screen actions; VIM-style editing, custom quick actions, configurable shortcuts and macros.
- Double-click/double-tap a MIDI clip to open its piano roll; selected clips can act as faint references while source ownership remains clear.
- Reusable clips with independent or linked source behavior, source offset, loop, split, resize and multi-edit.

### C. Mixer, routing and audio engine

- Track volume, pan, mute, solo and effect chains; stereo signal paths by default.
- Nested folders and stereo group buses using the existing project/engine model.
- Flexible sends/returns, sidechain, parallel routing and master effects.
- Master gain, limiter/safety processing and master output controls.
- Modulation links from LFOs/envelopes/signals to module parameters; module/global parameter automation.
- Clip-following automation and automation of processing behavior.
- Real engine integration for all controls; no UI-only fake routing.
- Adaptive workload planning, worker-pool scheduling and resource-aware parallelism.
- Low-latency playback, safe hot swap, bounded voice budgets and high-latency headphone behavior considered in interaction/testing.
- Native stereo throughout; measure phase/correlation/loudness tools before scheduling them.

### D. Audio import, editing and analysis

- Import and preview common audio assets.
- Non-destructive audio clips on the existing arrangement timeline.
- Waveform display, trim, split, move, duplicate, source offset, loop, fades, clip gain and reverse.
- Time stretching/warping and beat-aware processing after basic clips are stable.
- Transient detection and slicing, including sample-to-pattern workflows.
- Waveform peak-envelope inspection and editable transient markers.
- Basic on-demand FFT spectrum view with log-frequency axis and peak hold.
- Optional compact analysis UI, worker-based processing and bounded caches.
- Processing history as recipes/checkpoints referencing source assets.
- Advanced spectrogram, spectral selection, noise repair and restoration are not part of the first audio editor.

### E. Sampling and instruments

- Sample editor: trim/crop, fades, gain/normalization, reverse and loop points.
- Sampler zones, key ranges, velocity layers, round-robin groups and audition.
- WAV and SFZ multisample authoring/interchange.
- Generated sounds, imported samples and multisample zones share a common asset model.
- Small physical/resonator family: comb, modal, string/metallic waveguide models with fixed buffers and voice counts.
- Avoid a general physical simulation system or a separate instrument host.

### F. MIDI and performance

- Existing MIDI pattern import/export and MIDI 2.0/UMP decoder foundations.
- Real USB and Bluetooth MIDI device discovery, connection, status and reconnect.
- Note and CC routing, controller learn/mapping and MIDI clock input/output.
- On-screen performance keys, metronome and count-in where useful.
- Test real devices, event timing, device loss, duplicate messages and reconnection.
- MIDI/audio recording, input monitoring, latency compensation, punch-in/out, loop recording, take lanes and comping remain deferred until the owner changes scope.

### G. Arrangement, export and project workflow

- Arrangement markers/sections, timeline navigation and clip editing.
- Clip automation, consolidation/bounce and selected-track/group rendering.
- WAV loop/free-length/one-shot and wavetable export foundations.
- MIDI export and native offline renderer.
- SFZ and stems export commitments.
- Batch export, export profiles/history, queue persistence and robust cancellation/error cleanup.
- Portable project/module files, project-local folders, tags, saved searches and asset dependency handling.
- Non-destructive project restore points and bounded undo/redo where appropriate.
- Local/offline operation and clear missing-asset handling.
- Reaper handoff: exported loops, one-shots, wavetables and stems should be practical to use in existing production workflows.

### H. UI, accessibility and workflow

- Phone-first Builder, Arranger, Mixer, Engine Lab, Automation, Exporter, Files and Plugin Builder workspaces.
- Arrangement is the main composition view; avoid bringing back the retired session grid.
- Shared state and project model across workspaces; avoid duplicate editors/data models.
- Responsive portrait/landscape/desktop layouts; touch targets at least 48 dp where applicable.
- Same gesture vocabulary across phone and desktop; keyboard-only operation on desktop.
- Reaper-like shortcuts where appropriate, configurable actions, per-area keymaps, macros and custom toolbars.
- VIM-style modal control, command line, counts and recorded macros; optional Vim editing in code editor.
- Theme customization, live preview, readable shareable theme files, system UI font and bundled monospace font if license/size checks pass.
- Comfortable/compact density; calm neon visual language with restrained glow and short transitions.
- Startup choices: continue last project, blank project or template; new module/sound/effect/pattern/library files start empty with nearby templates.
- Sound inspector opens first; code editor remains one tap away.

### I. Performance, platforms and extensibility

- Android first, Windows desktop alongside it; iOS, macOS and Linux portability through shared C++ engine.
- Weak-device support with low idle CPU/RAM, adaptive workload and no unnecessary background activity.
- Stronger hardware can use available cores for independent jobs when it helps; avoid parallel overhead when the job is small.
- UI repaint only what changes; analysis and rendering off the callback; caches and buffers are bounded.
- Performance profiles Full Experience, Balanced, Lightweight and Minimal; preserve essential interaction and audio safety.
- Native module SDK and .caw Plugin Builder foundations.
- CLAP/VST3/AU plugin build/hosting only when a real native host/SDK, lifecycle, sandbox, licensing and platform integration exist.
- Shared engine CLI and offline renderer for tests, automation and reproducible output.
- GitHub integration, library sync, branch/PR workflows and shareable module assets remain separate platform capabilities; do not make cloud access required for making sound.
- Signed release builds, privacy/install documentation and eventual AutoStacc distribution after product readiness.

### J. Explicitly excluded from current scope

- AI generation, AI editing, AI source separation, model inference and cloud audio processing.
- Full wavelet/scalogram editing and time-frequency reassignment.
- Arbitrary spectrogram painting and frequency-region compositing.
- Harmonic/percussive NMF or similarly heavy source separation.
- General-purpose physical simulation (fluid, cloth, rigid body, arbitrary 3D geometry).
- GPU audio-shader language/runtime.
- Large multidimensional sound-space visualizers and advanced phase-space editors.
- Complex automatic sound repair/restoration.
- Huge evolutionary populations, unattended search and automatic aesthetic scoring.
- Full conventional DAW recording/comping, a session launcher, heavyweight stock instrument library or mastering suite as a goal in itself.

Reopen an excluded idea only with a concrete owner-requested use case, a small prototype, measured performance and an explicit scope decision.

## Source plans and evidence

- [Music workflow feature-gap plan](music-workflow-feature-gap-plan.md): verified implementation gaps and detailed workflow sequence for pattern editing, mixer, audio editing, sampling, MIDI, arrangement and export.
- [Lightweight creative audio systems plan](lightweight-creative-audio-systems.md): detailed first-version designs, architecture fit, effort/cost estimates, acceptance criteria and research references for the non-AI creative systems.
- [Engine implementation status](engine-build-status.md): current engine facts and v2 status; use this to verify what is actually implemented.
- [Master development plan](CAW_MASTER_DEVELOPMENT_PLAN.md): approved UI and engine task boundaries.
- [Roadmap](roadmap.md): product stages and release direction.
- [Vision](vision.md): owner decisions and product constraints.

**Status rule:** keep this master plan synchronized with the source plans when scope changes. Update implementation status only after code and CI evidence exist; do not mark a feature complete because it appears in this list.
