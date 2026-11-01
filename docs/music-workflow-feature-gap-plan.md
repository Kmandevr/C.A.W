---
title: Music workflow feature-gap plan
summary: Evidence-based status and build order for extending CAW's piano roll, arrangement, mixer, audio editing, sampling, MIDI and export workflows.
covers: [app/lib/ui/, app/lib/model/, engine/]
updated: 2026-11-01
---

# Music workflow feature-gap plan

This is the detailed implementation-gap companion to the [two-part core development plan and complete feature list](core-and-feature-plan.md) and the [roadmap](roadmap.md). It compares CAW's implemented workflows with useful capabilities found in established music creation and audio-editing software. The purpose is to extend CAW's existing systems, not rebuild them or copy a full conventional DAW. For unconventional, non-AI sound-generation and transformation ideas filtered for low-end hardware, see the separate [lightweight creative audio systems plan](lightweight-creative-audio-systems.md).

## Status key

- **[Fact] Implemented:** current app/engine documentation identifies a working implementation.
- **[Fact] Partial:** a useful foundation exists, but the complete workflow does not.
- **[Proposal] Planned:** a sensible extension, not a claim that code exists.
- **[Deferred]** Deliberately outside the current scope; do not start without revisiting the owner's direction.

Where documentation conflicts, the app and engine implementation are authoritative. The current app reference is [app](app.md), the UI specification is [ui](ui.md), and engine details are in [engine](engine.md).

## Existing foundations — preserve and extend

### Pattern editor and piano roll

- **[Fact] Implemented:** pattern files, piano-roll editor, draw/select/erase tools, adaptive grid, snapping/free timing, triplets, keyboard navigation, note preview, velocity lane, and per-note velocity, chance, ratchet and slide editing.
- **[Fact] Implemented:** MIDI pattern import/export (.mid, .midi2) through the pattern editor. Imported MIDI tempo is not applied to project tempo.
- **[Fact] Implemented:** the Curve tool edits velocity and chance lane curves; per-note expression editors support pitch bend, pressure/volume, timbre and vibrato, including editable points and segment bends.
- **[Fact] Implemented:** pattern actions include Euclidean, random-in-key, arpeggiate, humanize, chord stamp, legato, reverse and pitch inversion. These are implemented in the piano-roll action path and pattern model.
- **[Proposal] Extend:** add advanced quantization controls (strength, timing and note-length handling), reusable groove/swing templates, note chop/glue and strum. These are enhancements, not missing implementations of the existing generators or curve tools.
- **[Proposal] Extend:** add scale/chord assistance and ghost-note/reference editing where it improves composition, while retaining free notes outside the project key.

### Arrangement

- **[Fact] Implemented:** arrangement-first horizontal timeline, track lanes, reusable MIDI clip sources, linked and independent duplicates, move/resize/split, source-offset shift, time selection, multi-selection/reference notes, nested folders and optional stereo folder buses.
- **[Fact] Implemented:** track and folder-bus volume/pan automation is serialized and played by the native engine.
- **[Fact] Not implemented:** audio clips; clip-following automation and plugin/global parameter automation.
- **[Proposal] Extend:** named song sections/markers (intro, verse, chorus, bridge, outro), section selection and duplication, clip consolidation/bounce, richer loop/time selection and clip-level automation.
- **[Proposal] Extend:** a tempo/time-signature map only if changing tempo or meter within a song becomes a concrete need. Do not assume it is already supported by the project-level BPM and time signature.

### Mixer and signal flow

- **[Fact] Implemented:** track volume/pan/mute/solo, generator/effect chains, nested folder buses, folder routing and group volume/pan, master output level and stereo peak meters.
- **[Fact] Partial:** exported module signals and sidechain concepts exist in the engine/module system, but full user-facing routing and modulation connections are not integrated as a general mixer workflow.
- **[Fact] Not implemented:** sends, arbitrary buses, parallel routing/effects, master effect chain, stereo width/correlation/loudness/phase tools and plugin/global parameter automation in the Mixer.
- **[Proposal] Extend:** implement sends and explicit routing, sidechain connections, parallel effect paths and a master effect chain using the existing native processing foundations. Add metering only where it helps diagnose a real workflow.

### Export and file workflow

- **[Fact] Implemented:** native offline WAV rendering, loop/free-length/one-shot/wavetable export, MIDI pattern export, named export profiles, export history and a sequential in-memory queue (up to 50 jobs).
- **[Fact] Partial:** queue state is not persisted across restarts; batch/stem rendering and multi-destination automation are incomplete.
- **[Proposal] Extend:** stem export, batch export, persistent/recoverable export queues and reusable export presets for repeated delivery.
- **[Fact] Not implemented:** audio/MIDI asset preview caching is incomplete in Files.

### Modules and plugins

- **[Fact] Implemented:** code-defined generators/effects, parameter metadata, reusable functions, Plugin Builder for validating and packaging native .caw modules.
- **[Fact] Partial:** native module SDK and graph-processing foundations exist, but the prepared graph runtime is not the universal Engine/VM mixer path; external CLAP/VST3 hosting/loading is not available.
- **[Proposal] Extend:** complete native processor integration only when a concrete user workflow needs it. Do not treat plugin hosting as a prerequisite for the audio and pattern features below.

## Major workflow gaps

### Audio import and editing

- **[Fact] Not implemented / deferred:** audio import and audio clips are explicitly outside the current implemented workflow. CAW's vision describes raw audio manipulation, but the app does not yet provide the complete import-to-arrangement editor.
- **[Proposal] Build:** import common audio assets; preview them; display waveforms; place audio clips on the existing arrangement timeline; trim, split, move, duplicate, fade, adjust clip gain and reverse.
- **[Proposal] Build:** keep edits non-destructive by storing clip operations and preserving the original asset. Add pitch/time adjustment, beat-aware stretching and transient slicing after basic editing is reliable.
- **[Proposal] Build:** reuse CAW's existing module/effect system to process generated and imported audio rather than creating a separate incompatible effect architecture.
- **[Proposal] Later:** spectrogram/spectral selection, noise repair and advanced restoration. These are valuable audio-editor features but should follow basic audio clip editing.

### Sampling and multisample authoring

- **[Fact] Partial:** CAW's design supports generators, wavetables and future WAV/SFZ multisamples; current export includes wavetables, but a complete sample-authoring and mapping workflow is not established.
- **[Proposal] Build:** a sample editor for trim/crop, fades, gain/normalization, reverse and loop points.
- **[Proposal] Build:** sampler zones with key ranges, velocity layers, round-robin groups and preview/audition. Support SFZ as an interchange format where practical.
- **[Proposal] Build:** transient slicing and sample-to-pattern workflows after basic sample editing and mapping.
- **Design rule:** generated audio, imported samples and multisample zones should share a common asset model and processing path wherever possible.

### MIDI hardware and performance

- **[Fact] Implemented:** MIDI 2.0 UMP decoding and bounded input-queue foundations, plus MIDI pattern file import/export. These primitives do not provide physical USB/Bluetooth port discovery or device connection.
- **[Fact] Not implemented:** complete USB/Bluetooth MIDI device discovery/connection, controller learn/mapping and external MIDI clock/sync.
- **[Proposal] Build:** reliable USB and Bluetooth MIDI input, device selection/status, note and CC routing, controller learn, clock input/output and clear disconnect/reconnect behavior.
- **[Proposal] Build:** on-screen performance keys and a metronome/count-in where they support live pattern entry.
- **[Deferred] Recording:** MIDI/audio recording, input monitoring, latency compensation, punch-in/out, loop recording, take lanes and comping are intentionally not part of the current scope. Revisit only after device I/O and latency behavior are dependable and the owner changes the scope.

## Recommended implementation order

This order deliberately finishes existing foundations before expanding into the larger audio workflow.

1. **Extend the existing pattern editor.** The piano roll, lane curves, per-note expression and current generator actions are implemented. Remaining candidates are advanced quantization/groove tools, strum/chop/glue and usability polish; verify each against the code before opening an issue.
2. **Complete core mixer routing.** Sends, sidechains, parallel paths and master effects, with engine integration and tests. Keep the real-time callback bounded and allocation/lock free.
3. **Add basic audio assets and clips.** Import, preview, waveform, arrangement placement, trim/split/move/duplicate, fades and clip gain. Preserve originals and make operations non-destructive.
4. **Complete sample authoring.** Sample editor, loop points, zones, velocity layers, round-robin and WAV/SFZ multisample workflow.
5. **Complete live MIDI connectivity.** USB/Bluetooth devices, controller learn, clock/sync and on-screen keys; test device loss/reconnect and timing.
6. **Improve arrangement and delivery.** Markers/sections, clip automation, consolidation/bounce, stems, batch exports and persistent export queue.
7. **Advanced audio tools.** Time stretching/warping, transient slicing, spectrogram and audio repair, based on measured demand and performance.
8. **Revisit recording only by owner approval.** MIDI recording first; audio recording and comping later, after monitoring and latency are reliable.

## Implementation constraints

- Extend the existing shared project, pattern, clip, module and engine models. Avoid parallel incompatible editors or duplicate state.
- Keep the arrangement-first workflow; the retired session/clip-launcher grid is not an alternate composition view.
- Maintain phone and desktop parity, large touch targets, keyboard/action access and accessible editing gestures.
- Preserve offline operation and low CPU/RAM overhead on weak devices. Expensive analysis, stretching and export belong off the audio callback and should use bounded background work.
- Every feature needs model/serialization tests, engine tests where relevant, UI interaction tests and a clear acceptance check on phone-sized layouts.
- Keep status honest: a design in the roadmap is not an implementation. Update this note and the owning app/engine docs when code changes.

## Scope exclusions

Do not add full conventional DAW recording, a session launcher, a heavyweight stock instrument library, a separate incompatible sample editor, or a mastering suite merely to match competitors. CAW should remain a lightweight code-driven sound and music workspace, with useful arrangement and editing capabilities where they directly support its purpose.
