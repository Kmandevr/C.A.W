---
title: Vision and principles
summary: Owner-approved product direction, actual platform support, current product boundaries and unresolved owner decisions.
updated: 2026-11-05
---

# Vision and principles

This note records product direction, not a list of shipped features. The permanent [roadmap](roadmap.md) is the canonical plan and sequencing source. For implementation truth, use [App](app.md), [Engine](engine.md) and [Engine implementation status](engine-build-status.md). Code and tests take precedence over this vision when describing what exists.

## Product identity and direction

**Name:** C.A.W. means **Code Auditioning Workspace**. The logo is a crow.

C.A.W. is a code-driven sound-design and music-production workspace for creating, shaping, auditioning, arranging, recording, editing, mixing and exporting sounds, instruments, patterns and reusable musical content.

**Goal (owner, 2026-11-03):** C.A.W. is not trying to be a conventional DAW, and it doesn't have to work the way one does. It must be able to do everything a good DAW can do, because there is no good DAW for mobile. Its own way of working (code, patterns, one shared project and engine model, phone-first touch) is the means; full production capability is the requirement. It keeps a lightweight architecture so weak phones stay first-class, rather than copying a heavyweight DAW's design.

**Owner decision (2026-11-05):** ordinary C++ is C.A.W.'s programming language. It is general-purpose, not a music-only DSL; users can write anything ordinary C++ allows. The C.A.W. Library/SDK supplies reusable audio, music, math, bit-manipulation, data and general-purpose building blocks. One shared component model makes each component available to the C++ editor, visual composition, generated/custom performance UI, mixer and later plugin/standalone adapters. These are coordinated views of one project and runtime, not parallel implementations. See [C++ creation platform](cpp-creation-platform.md).

**Current delivery priority (owner, 2026-11-06):** create a working prototype before building out the full architecture. Deliver a narrow, useful end-to-end slice and expand it through working product behavior. Plan for future compatibility and extensibility where they affect today's interfaces, but do not build comprehensive migration systems, marketplace plumbing or speculative frameworks ahead of demonstrated need.

The current repository still contains the constrained .caw language and VM; that is an implementation fact, not the chosen destination. Useful existing engine capabilities are to be migrated into the C++ Library/SDK and shared component system before the old language and VM are removed. The owner has waived backwards compatibility for old .caw source and pre-release projects.

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
- A portable C++20 engine and constrained .caw module language for code-defined generators, effects, patterns, libraries and synth patches (current implementation, not the target language). The planned C++ authoring/toolchain and shared component SDK are not implemented yet.
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
- Audio/MIDI recording, input monitoring, latency compensation, take lanes and comping are not implemented; they are planned later in the permanent roadmap.
- The modular graph executor and native module registry are foundations, not the active playback/mixer path. External CLAP/VST3 binary hosting and dynamic native-module loading are not implemented.
- Video synchronization is not planned at this time.
- See [engine implementation status](engine-build-status.md) for the complete native boundary and paused work.

## Product principles

1. **Code and visual editing share one source of truth.** A visual control must update the same project/module data that code and playback use.
2. **Fast experimentation.** Make a sound, audition it, adjust it and export it without unnecessary setup.
3. **Local and offline first.** No app capability requires internet access. Editing, compiling and linking C++, resolving already-installed dependencies, playback, project/library management, saving, packaging and rendering work locally. Internet access is optional and may only improve the experience by obtaining or updating dependencies/toolchain packages that are then cached for offline use; it is never a remote execution dependency.
4. **Modular and reusable.** Generators, effects, functions, patterns, recordings and project assets should be reusable without duplicating incompatible systems.
5. **Phone-first, desktop-capable.** Touch workflows must be practical on a phone; desktop must support keyboard and mouse without becoming a separate product.
6. **Transparent resource controls.** Show CPU, memory, audio and build load. Make budgets and recommendations configurable and allow users to override advisory limits; do not impose arbitrary hidden ceilings. Keep genuine format and real-time safety constraints explicit.
7. **Safe real-time audio.** The callback stays bounded and avoids allocation, locks, I/O, logging and UI calls.
8. **Evidence over claims.** Performance, platform support and feature completion require tests or device measurements.
9. **Extensible without rewrites.** New components, algorithms, ports, parameters, UI controls, MIDI capabilities, formats and platform adapters must plug into defined contracts without requiring unrelated systems to be rewritten.

## Sound-design direction

The creative direction includes bytebeat and mathematical audio, procedural synthesis, raw bit-level sound design, reusable effects, modulation, waveform/wavetable work, resonant and physical-model-inspired sounds, and controlled sound variation.

These are not all implemented. The [lightweight creative audio systems design](lightweight-creative-audio-systems.md) separates existing primitives from proposed additions and estimates impact, effort and runtime cost.

Audio import, sample editing, multisampling, non-destructive audio transformations and recording are desired workflow extensions, but remain future work until they appear in the app and engine implementation.

## AI and external services

**No in-app AI integration is in the current product scope.** Do not add AI generation, AI editing, source separation, model inference, cloud audio processing or AI-dependent sound features.

AI coding assistants may be used by the owner and contributors as development tools. That is separate from the shipped C.A.W. product and does not imply an AI feature, provider integration or network dependency in the app.

GitHub-based library synchronization and source selection are also not implemented as an app workflow. Keep the app fully useful offline; optional project collaboration/synchronization is a later roadmap capability and must not be required for core operation.

## Commercial and licensing direction

**Owner direction (2026-11-09):** C.A.W. is intended to be free and open source. It is licensed under [Apache-2.0](../LICENSE). AutoStacc distributes the free app and the optional support bundles. Core functionality is not paywalled. Optional support/donation bundles may provide prebuilt libraries of FX, instruments, presets, samples and sounds; they use the same component/content formats as free and creator-made content. Do not claim AutoStacc distribution or bundle delivery is implemented.

New dependencies require exact version, transitive dependency and licence review and an entry in [decisions](decisions.md). Dependencies must be permissive (no GPL/AGPL); no paid licence is assumed. See [visual creation and signal routing](visual-routing-and-library-integration.md) for the current candidate evaluation.

## Open owner decisions

Only the owner can settle these questions. Do not silently convert them into implementation requirements.

| Question | Current status |
|---|---|
| iOS distribution: App Store exception or no iOS release | Open |
| Licence for user-created/shared sound modules | Open |
| How AutoStacc delivers the free app and the support bundles | Open |
| Initial trust state for a newly encountered native component | Open; each component's trust level must be explicitly chosen by the user; no silent trust assignment ([decisions](decisions.md), 2026-11-06) |
| How the optional AutoStacc cloud library syncs with project folders and the global library | Open; compatibility is required ([decisions](decisions.md), 2026-11-03) |
| Whether effect tails should carry across a layer loop restart in every case | Open; see [engine playback](engine.md#playback) |
