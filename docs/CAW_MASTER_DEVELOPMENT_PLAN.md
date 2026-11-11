---
title: C.A.W. master development plan
summary: Design specification for the UI/workflow overhaul and engine integration; current implementation status is tracked separately.
updated: 2026-11-11
---

# C.A.W. — Master Development Plan

**Status:** This is an owner-approved design specification, not a current implementation report. Task 1 implementation was authorized on 2026-10-31; the current shipped UI and remaining gaps are recorded in [App](app.md), [UI design](ui.md) and the [core development plan](core-and-feature-plan.md). Task 2 remains architectural context; its graph-to-Engine/VM integration is the [roadmap](roadmap.md)'s Foundation stage (issue #28).  
**Project:** C.A.W. (Code Auditioning Workspace), repository `Kmandevr/C.A.W`.  
**Purpose:** Preserve the agreed design scope for future contributors without implying that every requirement below is implemented.

> This is C.A.W., not AutoStacc. The requirements below are design intent unless the current app/engine references explicitly mark them implemented. The owner has directed no in-app AI integration for now; AI-related proposals in this design are deferred and must not be built without a new explicit decision. Always audit the repository before changing code.

# Master Task 1 — Complete UI and Workflow Overhaul

## Objective
Create a cohesive, responsive, visually distinctive creative environment. Keep ordinary workflows approachable while exposing the full capabilities of the underlying engine to advanced users.

## 1. Visual identity
Use the agreed retro-futurist neon studio aesthetic:
- Dark obsidian/graphite foundation; layered, instrument-like panels rather than generic rounded cards.
- Semantic accents: signal green (generators/playback), electric violet (modulation/automation), pulse coral (effects/warnings), ion blue (library/focus), warm amber (patterns/sequencing).
- Selective neon glow, illuminated active controls, animated signal paths, technical markings, grids and restrained phosphor/terminal details.
- Blend modern electronic instrumentation with 1960s terminal and experimental hardware influences.
- Avoid generic productivity-app styling, excessive glass, excessive glow and rainbow-colored panels.
- Purposeful motion and smooth audio-reactive visuals; inactive UI stays quiet and readable.
- Design principle: “It should look like an experimental instrument that happens to be powerful software.”

## 2. Main workspaces

### Builder
The quick, approachable primary creative workspace:
- Create and arrange generators, instruments and effects.
- Work with MIDI patterns.
- Common track controls: volume, pan, mute, solo and quick routing.
- Fast access to common parameters and creative operations.
- Keep routine creation straightforward; do not force users into advanced panels for ordinary tasks.

### Arranger
A familiar horizontal song-arrangement workflow:
- Tracks stacked vertically with a horizontal timeline.
- Reusable MIDI clips/patterns; selection, editing, snapping, grid and timeline navigation.
- Resizable tracks/panels, drag-and-drop, context menus and keyboard shortcuts.
- Smooth timeline zoom, scroll and playhead movement.
- Arrangement-first, not a session-grid replacement. No audio recording/audio clips are required unless already supported.

### Mixer / Editor
A genuinely separate detailed workspace, not merely Builder with more buttons:
- Detailed channel strips, full effect chains and parameter editing.
- Advanced routing, sends, buses, groups and master channel.
- Stereo width/channel configuration and precise level/pan controls.
- Automation and modulation editing.
- Detailed generator/instrument settings.
- Signal analysis and metering.
- Master volume, peak/loudness meters, stereo correlation/phase monitoring, master FX, limiting/compression, output routing and clipping detection.
- Expose the programmable engine and unconventional processing capabilities, not just conventional DAW controls.
- Builder and Mixer share the same project state; changes appear immediately in both.
- Selecting an item in Builder and opening the Editor should navigate directly to that item's detailed controls.
- Desktop may show multiple panels/dockable sections; mobile uses a focused navigable editor, not a compressed desktop mixer.

### Engine Lab
An advanced workspace for exploring and controlling engine behavior:
- Visual connections among audio, MIDI, parameters, data and engine operations.
- Bitwise/sample-level manipulation, buffer operations and sample-representation controls.
- Unusual processing relationships and dynamic processing configurations.
- Custom engine modules, automation and live inspection of processing/signal relationships.
- Make powerful operations discoverable without requiring every user to understand the implementation.

### Automation and visual programming
First-class editing environments, not secondary features:
- Draw automation curves; create patterns, sequences and envelopes.
- Connect modulation sources and targets visually.
- Automate parameters, connections and processing behavior.
- Use audio, MIDI, mathematical, timing, data-derived and engine-state sources.
- Visual edits and code edits affect the same underlying system.
- Code-defined connections should appear in the graph whenever representable; visual connections should be inspectable/editable in code.

### Exporter
A unified adaptive export workspace with Quick Export and Advanced Export modes.

Content categories:
- Audio renders, loops, one-shots, stems and processed audio.
- MIDI and patterns.
- Wavetables and synthesis assets.
- Instruments and plugins.
- Native projects, generators, effects and presets.

Audio settings:
- WAV, FLAC and other supported formats.
- Sample rate, bit depth, floating-point formats, mono/stereo/multichannel where supported.
- Quality, normalization, dithering and metadata (BPM/key/name).
- Loop, selection, full project and custom-length rendering; effect/release tails.

Workflow and reliability:
- Batch export, stems, shared queue, progress, cancellation and actionable errors.
- Export profiles/templates, remembered destinations and per-export destination choice.
- Preview, export history, re-export and reproducible settings.
- Dependency collection and portability.
- Offline operation, streaming/chunked large renders, cleanup on cancellation and no UI freeze/audio interference.
- On success offer open, reveal-in-file-manager and preview/test actions.
- Do not promise unsupported output formats or destinations.

### Plugin Builder
A dedicated plugin-development workspace:
- Start from an existing generator/effect/instrument or create a new one.
- Guided and advanced workflows.
- Visual no-code builder and native code path.
- Automatically generated parameter controls; customizable UI and metadata.
- Target selection, validation, testing, building and packaging.
- CLAP first, VST3 later; standalone builds where feasible.
- Test input/output, mono/stereo, automation, preset save/restore, CPU/memory, audio-thread safety, sample rates/buffer sizes and crash behavior.
- Packages may include compiled plugins, optional source, portable C.A.W. modules, UI definitions, presets, graphics, version/dependencies/licenses.
- Review SDK/dependency licensing; do not assume redistribution rights.

### User-controlled file management
- Users control folders, naming, nesting, locations, grouping and categories. C.A.W. may suggest defaults but must not force organization.
- A `.caw` file is a project (plain project JSON, or a zip package with its dependencies; #159); old `.cawproj` projects still import. Keep ordinary formats such as MIDI, WAV, JSON and TXT interoperable.
- Separate extension, content type and open behavior.
- Blank files/templates for projects, generators, effects, instruments, presets, MIDI patterns and custom templates.
- Custom templates, presets and inheritance without overwriting originals.
- Smart folders, multi-tags, saved searches, sorting, duplicate detection and bulk operations.
- Async previews for audio/MIDI/waveforms/spectra/presets; cache previews.
- Autosave, crash recovery, undo/redo for file operations, version history, restore points, overwrite protection, atomic saves and malformed-file handling.
- Dependency collection, missing-asset reporting/relinking, relative/absolute paths and consolidation.
- Custom content types and plugin-defined types eventually; avoid a new extension for every feature.
- Keep the native container versioned/validated and avoid turning ordinary external formats into proprietary containers.

## 3. Audio-reactive presentation
- Accurate waveform, scope and spectrum visualization.
- Meters with fast attack, smooth release, short peak hold and gradual peak fall.
- Independent left/right visualization and stereo scopes.
- Animated modulation/signal paths and sequencer playhead.
- Visual smoothing must never modify the underlying audio or compromise measurement accuracy.
- Avoid flicker, random jitter, unnecessary stopped-state animation and expensive full-screen effects.
- Update only changing components where practical.

## 4. Responsive design and visual performance modes
Desktop: multiple visible panels, docking/resizing where useful, efficient mouse/keyboard workflows.  
Mobile: focused navigable editing environment, not a compressed desktop mixer; default touch target 48dp.

Modes:
- Full experience: all visual features.
- Balanced: reduced decorative processing.
- Lightweight: simplified visual effects.
- Minimal: essential presentation.

Never sacrifice audio accuracy, UI responsiveness, meter smoothing, timeline smoothness, essential animations or editing feel. Reduce decorative glow, particles, scanlines, compositing and background visual work first. Do not arbitrarily lower refresh rates or make the interface choppy. Principle: “Lightweight should look simpler, not feel slower.”

## UI acceptance criteria
- Workspaces form one coherent instrument and share project state.
- Builder is easy and quick; Mixer/Editor is deep and powerful.
- Engine Lab, automation and visual programming expose the underlying engine without duplicating it.
- Desktop and mobile are deliberately designed.
- Audio-reactive visuals are smooth, accurate and lightweight.
- All visible controls perform their advertised actions.
- No existing functionality is lost during redesign.

---

# Master Task 2 — Audio Engine Integration, Expansion and Optimization

## Objective
Integrate existing capabilities, remove architectural limitations, expand C.A.W. into a programmable experimental audio-processing environment, and optimize it across desktop and mobile hardware.

## 1. Audit and integrate existing functionality first
Before replacing architecture:
- Audit the current repository and map existing capabilities to this plan.
- Identify incomplete, disconnected, duplicated or regressed functionality.
- Integrate existing generators, instruments, effects, modulation, MIDI, scheduling and processing.
- Preserve existing capabilities and tests; verify native stereo throughout.
- Keep the audio engine independent from UI rendering/animation.
- Profile actual bottlenecks before optimizing.
- Do not rewrite working systems without a demonstrated reason.

## 2. Universal interaction and connection architecture
Core principle: **anything exposing a compatible interface should be able to influence anything else that accepts that type of input.**

Potential sources:
- Audio signals and generator/effect outputs.
- MIDI events and notes.
- Mathematical functions and control signals.
- Individual samples, bits, bytes and buffer data.
- Timing, clocks and playback state.
- Automation, parameters and engine state.

Potential targets:
- Generators, instruments and effects.
- Effect parameters and processing algorithms.
- Tracks, buses and other channels.
- Sample representation and playback behavior.
- Timing, playback increments and buffer operations.
- Other modulation systems and engine properties.

Requirements:
- Transform between incompatible types rather than imposing arbitrary restrictions.
- Support cross-track/cross-component interactions and complex feedback relationships where technically valid.
- Allow audio to control data interpretation, data to control audio behavior, and parameters to influence other parameters.
- This is broader than a conventional modulation matrix.

Examples:
- One generator's bit pattern controls another generator's sample-rate interpretation.
- A kick's amplitude changes how a bass buffer is interpreted.
- One waveform controls bitwise processing on another channel.
- MIDI events change precision or playback behavior elsewhere.
- A mathematical function combines several tracks and feeds another processing path.

## 3. Universal automation and dynamic behavior
Automation extends beyond volume, pan and normal effect parameters. Automatable targets include:
- Effect settings and algorithms.
- Modulation connections themselves.
- Bitwise operations and sample interpretation.
- Playback increments and timing.
- Buffer/processing characteristics.
- Engine variables and custom code-defined parameters.
- Processing configuration and behavior.

Support multiple execution rates:
- Sample-rate/audio-rate interactions.
- Block-rate interactions.
- Event-rate interactions (MIDI/triggers).
- Engine-control/configuration interactions.

These rates must interoperate safely and predictably. Do not artificially limit what users can connect conceptually.

## 4. Programmable engine files (`.cawengine`)
Introduce a native engine-file format capable of defining:
- Processing algorithms and custom transformations.
- Bitwise operations and sample/buffer manipulation.
- Numerical representation changes.
- Dynamic modulation relationships and automation.
- Custom processing stages.
- Internal state and user-facing parameters.
- Relationships between otherwise independent engine components.

Engine files should be reusable, shareable, composable and dynamically responsive. Users can load ready-made systems or inspect and modify their logic.

### Engine development environment
Support both:
1. Visual construction and connections.
2. Advanced code-based development.

Code tools should eventually include:
- Context-aware completion and engine API awareness.
- Type and processing-rate validation.
- Connection suggestions and missing-declaration detection.
- Visual previews of code-defined relationships.
- Optional generation of modules from natural-language descriptions.
- Generated code remains inspectable and editable.

The visual graph, automation editor and code editor operate on the same underlying graph/system.

## 5. Low-level audio and data manipulation
Expose controlled access to the actual data and processing behavior. This is a defining C.A.W. capability, not merely a collection of conventional DSP effects.

| Area | Capabilities |
|---|---|
| Sample representation | Integer, floating-point, fixed-point and conversion |
| Bit operations | Flip, shift, mask, invert, truncate, rearrange |
| Byte operations | Byte order, reinterpretation, alignment |
| Sample rates | Resampling, reinterpretation, dynamic playback changes |
| Buffer operations | Boundaries, offsets, sizes and data manipulation |
| Channels | Interleave, deinterleave, swap, reinterpret and combine |
| Timing | Sample positions, increments and clock behavior |
| Numerical behavior | Precision, rounding, quantization and overflow |
| Processing graph | Custom stages, ordering and interaction |
| Memory interpretation | Controlled data-layout experimentation |

Keep distinctions clear:
- Resampling calculates new samples.
- Sample-rate reinterpretation changes playback interpretation.
- Lossy codec processing performs encode/decode behavior.
- Bit corruption directly modifies data representation.
- Precision reduction changes numeric representation/quantization.

Do not conflate these operations.

## 6. Non-destructive transformations
All internal data manipulation should support non-destructive operation by default.

Examples:
- Lossy compression and codec artifacts.
- Bit-depth reduction.
- Bit corruption.
- Data truncation.
- Sample-rate reinterpretation.
- Precision reduction.
- Byte manipulation.
- Channel corruption.
- Buffer manipulation.
- Unusual resampling/interpolation.

Support three modes:
1. **Non-destructive:** original source remains untouched; transformed result is calculated in the processing graph.
2. **Cached:** precomputed results are retained for efficient playback.
3. **Destructive rendering:** explicitly commit a new result/file only when requested.

Transformations must be stackable, reorderable, bypassable and automatable. Support deterministic corruption with reproducible seeds and randomized behavior. They should be usable throughout generators, effects, tracks, buses, master processing and custom engine files.

## 7. Engine scheduling and execution
Preserve a robust real-time audio engine:
- Deterministic sample-position scheduling and reliable event timing.
- Efficient generator/voice management and native stereo processing.
- Parallel processing of independent paths where appropriate.
- Safe dynamic graph changes; efficient buffer reuse and minimal copying.
- Controlled feedback/cyclic processing.
- No allocation, blocking locks, file I/O or UI work in the real-time callback.
- No arbitrary memory writes from custom engine code into audio-thread memory.

Dynamic graph/configuration changes should be prepared off the real-time thread and transferred at safe boundaries. Continuous parameter automation must remain responsive. Use bounded, validated execution for custom processing.

## 8. Hardware-aware parallelization and optimization
Make effective use of available hardware without wasting resources.

Desktop:
- Utilize available CPU cores intelligently.
- Parallelize independent processing paths.
- Scale with project complexity.
- Avoid imposing high overhead on low-end hardware.

Mobile:
- Adapt to CPU, memory and thermal constraints.
- Avoid unnecessary background work.
- Preserve audio stability and UI responsiveness.

Across platforms:
- Profile real bottlenecks.
- Minimize allocations, copying and cache misses.
- Reuse buffers and avoid redundant calculations.
- Separate audio processing from UI workloads.
- Scale parallelism intelligently.
- Monitor CPU, memory and processing deadlines.
- Do not claim performance improvements without measurements.

## 9. Plugin architecture and compatibility boundary
- Clean, replaceable plugin-host architecture.
- Desktop plugin loading should work normally.
- Stable interfaces for loading, processing, parameters and state.
- Isolate platform-specific hosting; identify plugin format and architecture.
- Handle plugin failures safely.
- Do not make future compatibility projects dependencies.

**CAW Bridge is a separate future project**, intended to explore local compatibility translation/emulation for existing desktop plugins on mobile. It should be independently developed/open source subject to licensing review. It must not become a current C.A.W. dependency or delay C.A.W. releases.

## 10. Export and rendering backend
Implement the engine side of the unified exporter:
- Offline/background rendering.
- Streaming/chunked large-file processing.
- Batch and stem rendering.
- Native stereo preservation.
- Multiple supported sample rates, bit depths and formats.
- Effect tails and accurate render boundaries.
- Dependency collection and reproducible settings.
- Cancellation and cleanup.
- No UI freeze or interference with live audio.

Plugin building/validation/packaging must have appropriate backend integration.

## 11. Testing and verification
Test:
- Audio correctness and stereo integrity.
- Scheduling accuracy.
- MIDI and automation.
- Graph changes during playback.
- Feedback stability.
- Buffer/memory safety.
- Sample-rate and buffer-size variations.
- Parallel-processing correctness.
- CPU/memory performance.
- Desktop and mobile behavior.
- Export correctness.
- Plugin loading and isolation.
- Regression coverage for all existing functionality.

Document measured improvements, test evidence, known limitations and compatibility.

## Engine acceptance criteria
- Existing functionality is preserved and integrated.
- Universal connections and transformations work across supported sources/targets.
- Engine files can define custom processing and dynamic relationships.
- Visual, automation and code workflows share one underlying system.
- Low-level manipulation and non-destructive processing work reliably.
- Real-time audio safety is maintained.
- Performance scales intelligently across desktop and mobile.
- Export and plugin systems use the same coherent processing architecture.

---

# How the two tasks fit together

**Task 1 owns presentation, interaction and workflow:** Builder, Arranger, Mixer/Editor, Engine Lab, automation/visual programming, Exporter, Plugin Builder and file management.

**Task 2 owns underlying processing and runtime:** existing engine integration, universal interaction graph, programmable engine files, low-level data manipulation, non-destructive transformations, scheduling, optimization, plugin-host boundary and rendering.

They share project state and stable interfaces. Neither should create a separate duplicate processing or project model.

## Recommended implementation sequence (after explicit approval)
1. Audit repository and map existing functionality to both master tasks.
2. Identify shared interfaces and dependencies.
3. Establish engine contracts and stable APIs for UI integration.
4. Integrate existing functionality before replacing or expanding systems.
5. Develop coordinated UI and engine workstreams.
6. Test each integration continuously.
7. Profile and optimize desktop and mobile.
8. Finish documentation and regression testing.

## Non-negotiable project constraints
- This is C.A.W., not AutoStacc.
- Do not begin implementation based on this document alone; obtain explicit approval in the future development session.
- Preserve existing functionality; avoid unnecessary rewrites, duplicated systems and scope creep.
- Native stereo is fundamental.
- Builder stays easy; Mixer/Editor is deeply capable.
- Universal interaction and automation are central to the engine.
- Low-level manipulation is a creative feature, not merely an effect category.
- Non-destructive experimentation preserves originals by default.
- Visual and code workflows operate on the same underlying system.
- Desktop and mobile are both first-class.
- Audio-thread isolation and real-time safety are mandatory.
- Optimize based on profiling and evidence.
- CAW Bridge remains separate and must not delay C.A.W.
- Do not silently alter users' work or automatically apply diagnostic fixes.

## Handoff instruction for a future session
First inspect the current `Kmandevr/C.A.W` repository and compare its actual state against both master tasks. Determine what is already implemented, incomplete, broken, outdated or missing. Present an evidence-based implementation map and identify dependencies. Only begin modifying code after the user explicitly authorizes building. Once authorized, implement, test, fix failures, document and continue through the agreed workstreams rather than stopping at recommendations.
