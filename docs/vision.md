---
title: Vision and principles
summary: Owner-approved product direction, current supported platforms, scope boundaries and unresolved owner decisions.
updated: 2026-11-01
---

# Vision and principles

This note records product direction, not a list of shipped features. For implementation truth, use [App](app.md), [Engine](engine.md), [Engine implementation status](engine-build-status.md) and the [core development plan](core-and-feature-plan.md). Code and tests take precedence over this vision when describing what exists.

## Product identity and direction

**Name:** C.A.W. means **Code Auditioning Workspace**. The logo is a crow.

C.A.W. is a code-driven sound-design and music workspace for creating, shaping, auditioning, arranging and exporting sounds, instruments, patterns and reusable musical content. Its centre of gravity is experimental sound creation, but that is not a reason to reject useful arrangement, editing and mixing workflows. It should be useful in a pinch without trying to reproduce every feature of a large conventional DAW.

Code remains a first-class way to define sounds and effects. Visual controls and editors should expose the same underlying project and engine state rather than creating parallel systems. C.A.W. complements established production tools through practical WAV and MIDI handoff.

## Platforms and actual support

**Product targets:** Android, iOS, Windows, macOS and Linux, with Android first.

**Current repository support (checked 2026-11-01):**
- The Flutter app has CI build artifacts for Android and Windows.
- Linux is used for app analysis/tests and has a local Flutter runner, but is not currently a shipped app artifact.
- The portable C++ engine is built/tested by CI on Linux x64, Linux Arm64 and Windows x64, plus Linux sanitizers.
- iOS and macOS app builds are not currently part of the app CI workflow. They remain portability targets, not verified shipped builds.

Do not describe a platform as supported for release solely because Flutter or the C++ engine could theoretically target it.

## Current product capabilities — summary

The app currently has eight workspaces: Builder, Arranger, Mixer, Engine Lab, Automation, Exporter, Files and Plugin Builder.

The repository currently includes:
- A portable C++20 engine and constrained .caw module language for code-defined generators, effects, patterns, libraries and synth patches.
- Module parameters, project globals, exported signals and reusable functions.
- Pattern editing with a piano roll and drum grid, note expressions, velocity/chance curves and pattern generators.
- Arrangement clips, nested folders, stereo folder buses and track/folder volume-pan automation.
- Track mixer controls, master output level and stereo peak meters.
- Engine Lab scope/spectrum inspection and engine diagnostics.
- MIDI pattern import/export, including Standard MIDI Files and MIDI 2.0 Clip Files, plus a native MIDI 2.0 UMP decoder/input-queue primitive.
- Native offline WAV rendering, loop/free-length/one-shot/wavetable export, named profiles, export history and a bounded in-memory queue.
- Portable .cawproj and .caw import/export, project-local folders, tags, saved searches and restore points.
- Plugin Builder for validating and packaging .caw source modules.

Important boundaries:
- USB/Bluetooth MIDI device discovery, connection and live Engine voice routing are not implemented.
- Audio-file import, audio clips, sample editing and WAV/SFZ multisample authoring are not implemented.
- Sends, general sidechain routing, parallel mixer paths and master effect chains are not complete.
- Module/global parameter automation and stems export remain approved v2 work.
- The modular graph executor and native module registry are foundations, not the active playback/mixer path. External CLAP/VST3 binary hosting and dynamic native-module loading are not implemented.
- See [engine implementation status](engine-build-status.md) for the complete native boundary and paused work.

## Product principles

1. **Code and visual editing share one source of truth.** A visual control must update the same project/module data that code and playback use.
2. **Fast experimentation.** Make a sound, audition it, adjust it and export it without unnecessary setup.
3. **Local and offline first.** Core sound creation and rendering do not require a cloud service or account.
4. **Modular and reusable.** Generators, effects, functions, patterns and project assets should be reusable without duplicating incompatible systems.
5. **Phone-first, desktop-capable.** Touch workflows must be practical on a phone; desktop must support keyboard and mouse without becoming a separate product.
6. **Resource-aware.** Work on weak devices with bounded memory and callback cost, while using stronger hardware when it benefits active work.
7. **Safe real-time audio.** The callback stays bounded and avoids allocation, locks, I/O, logging and UI calls.
8. **Evidence over claims.** Performance, platform support and feature completion require tests or device measurements.

## Sound-design direction

The creative direction includes bytebeat and mathematical audio, procedural synthesis, raw bit-level sound design, reusable effects, modulation, waveform/wavetable work, resonant and physical-model-inspired sounds, and controlled sound variation.

These are not all implemented. The [lightweight creative audio systems plan](lightweight-creative-audio-systems.md) separates existing primitives from proposed additions and ranks them by impact, effort and runtime cost.

Audio import, sample editing, multisampling and non-destructive audio transformations are desired workflow extensions, but remain future work until they appear in the app and engine implementation.

## AI and external services

**No in-app AI integration is in the current product scope.** Do not add AI generation, AI editing, source separation, model inference, cloud audio processing or AI-dependent sound features.

AI coding assistants may be used by the owner and contributors as development tools. That is separate from the shipped C.A.W. product and does not imply an AI feature, provider integration or network dependency in the app.

GitHub-based library synchronization and source selection are also not implemented as an app workflow. Keep the app fully useful offline; revisit remote sync only as a separately approved product feature.

## Commercial and licensing direction

The owner has described AutoStacc as the intended commercial distribution channel. The repository is public but proprietary; public source visibility does not grant reuse rights. Do not claim that an AutoStacc purchase/unlock flow or commercial release pipeline is implemented.

New dependencies require licence review and an entry in [decisions](decisions.md).

## Open owner decisions

Only the owner can settle these questions. Do not silently convert them into implementation requirements.

| Question | Current status |
|---|---|
| iOS distribution: App Store exception or no iOS release | Open |
| Licence for user-created/shared sound modules | Open |
| How a future AutoStacc purchase would deliver/unlock the app | Open |
| Whether effect tails should carry across a layer loop restart in every case | Open; see [engine playback](engine.md#playback) |
