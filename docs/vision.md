---
title: Vision and principles
summary: Owner-approved product direction, actual platform support, current product boundaries and unresolved owner decisions.
updated: 2026-11-12
---

# Vision and principles

This note records product direction, not a list of shipped features. The permanent [roadmap](roadmap.md) is the canonical plan and sequencing source. For implementation truth, use [App](app.md), [Engine](engine.md) and [Engine implementation status](engine-build-status.md). Code and tests take precedence over this vision when describing what exists.

## Product identity and direction

**Name:** C.A.W. means **Code Auditioning Workspace**. The logo is a crow.

C.A.W. is a code-driven sound-design and music-production workspace for creating, shaping, auditioning, arranging, recording, editing, mixing and exporting sounds, instruments, patterns and reusable musical content.

**Goal (owner, 2026-11-03):** C.A.W. is not trying to be a conventional DAW, and it doesn't have to work the way one does. It must be able to do everything a good DAW can do, because there is no good DAW for mobile. Its own way of working (code, patterns, one shared project and engine model, phone-first touch) is the means; full production capability is the requirement. It keeps a lightweight architecture so weak phones stay first-class, rather than copying a heavyweight DAW's design. **Owner (2026-11-09):** it should *feel* like a full DAW, closest to REAPER, "but better and more specialized": the familiar workflow (tracks, mixer, FX stacks, automation, a browser) with C.A.W.'s own strengths built in, such as writing, building and hearing your own effects inside the song. The layout is in [decisions](decisions.md) ("The app's layout").

**Owner decision (2026-11-05):** ordinary C++ is C.A.W.'s programming language. It is general-purpose, not a music-only DSL; users can write anything ordinary C++ allows. The C.A.W. Library/SDK supplies reusable audio, music, math, bit-manipulation, data and general-purpose building blocks. One shared component model makes each component available to the C++ editor, visual composition, generated/custom performance UI, mixer and later plugin/standalone adapters. These are coordinated views of one project and runtime, not parallel implementations. See [C++ creation platform](cpp-creation-platform.md).

**C++ rules the app (owner, 2026-11-10):** C++ is "the supreme ruler" of C.A.W. and replaces the .caw language entirely ([decisions](decisions.md), "C++ replaces the .caw language"). In C++ you build synths and effects, write custom LFOs and other modulators, and route anything to anywhere. Notes can be written as text-based MIDI, in C.A.W.'s own text form where standard MIDI has none. The mindset, in the owner's words not to be taken verbatim: you could port an entire game into the app and it would just turn into music. The vision is for C.A.W. to do "literally anything you could imagine". Most DAWs restrict you to the way their engine works. C.A.W. instead gives native engine support for "weird shenanigans", so you can make sounds you can't make anywhere else. That makes it at once a plug-in builder, a DAW, a testing suite and a sample-pack maker: "the jack of all trades while still being specialized". Built so far (2026-11-10): C++ effects and instruments on tracks (#156), an engine-side testing suite for effects (#163), and CLAP export of a component library (#162). [Proposal] Modulators, routing anything anywhere and text MIDI are planned (#155), and so are the sample-pack maker (#164), VST3 export and the app's use of the testing suite.

**Current delivery priority (owner, 2026-11-06):** create a working prototype before building out the full architecture. Deliver a narrow, useful end-to-end slice and expand it through working product behavior. Plan for future compatibility and extensibility where they affect today's interfaces, but do not build comprehensive migration systems, marketplace plumbing or speculative frameworks ahead of demonstrated need.

The .caw language and VM were removed on 2026-11-11 (#160), once C++ built-ins and the app made the same music; the owner waived compatibility with old .caw sources and pre-release projects.

## Platforms and actual support

**Product targets:** Android, iOS, Windows, macOS and Linux, with Android first.

**Current repository support (checked 2026-11-01):**
- The Flutter app has CI build artifacts for Android and Windows.
- Linux is used for app analysis/tests and has a local Flutter runner, but is not currently a shipped app artifact.
- The portable C++ engine is built/tested by CI on Linux x64, Linux Arm64 and Windows x64, plus Linux sanitizers.
- iOS and macOS app builds are not currently part of the app CI workflow. They remain portability targets, not verified shipped builds.

Do not describe a platform as supported for release solely because Flutter or the C++ engine could theoretically target it.

## Current product capabilities — summary

The app has three sections: Build (C++ components and patterns), Files and Arrange (tracks and clips, with the mixer, the automation lanes and the FX stack). Export is a page from the project menu and Engine diagnostics are in Settings.

The repository currently includes:
- A portable C++20 engine with built-in C++ instruments and effects and the project's own C++ components, written and built in Build.
- Pattern editing with a piano roll and drum grid, note expressions, velocity/chance curves and pattern generators.
- Arrangement clips, nested folders, stereo folder buses and track/folder volume-pan automation.
- Track mixer controls, master output level and stereo peak meters.
- Engine diagnostics (Settings › About and beta): scope/spectrum inspection and meters.
- MIDI pattern import/export, including Standard MIDI Files and MIDI 2.0 Clip Files, plus a native MIDI 2.0 UMP decoder/input-queue primitive.
- Native offline WAV rendering, loop/free-length/one-shot/wavetable export, named profiles, export history and a bounded in-memory queue.
- Portable .caw project import/export (packages with their dependencies; old .cawproj files import), project-local folders, tags, saved searches and restore points.
- CLAP plug-in project export of a C++ component (Build › Export as plug-in).

Important boundaries:
- USB, Bluetooth and UMP MIDI devices (Android) and WinMM ports (Windows) play instruments at the frame they were played; not yet tested on the owner's hardware. MIDI clock and output are not implemented.
- Audio-file import, audio clips, sample editing and WAV/SFZ multisample authoring are not implemented.
- Sends to bus folders, sidechain keys (the ducker, compressor and gate) and bus effects are built (2026-11-11, #175); receives, parallel paths inside a track and a routing matrix are not. Native effect chains on tracks, buses and the master are built (engine).
- Instrument and effect knob automation is built; stems export is in the Export song sheet.
- Audio/MIDI recording, input monitoring, recording latency compensation, take lanes and comping are not implemented; they are planned later in the permanent roadmap. (Plugin delay compensation for native effects is built.)
- The modular graph executor and native module registry are foundations, not the active playback/mixer path. External CLAP/VST3 binary hosting is not implemented. Dynamic loading of C.A.W. native components, under the user's explicit trust choice, is built in the engine; no screen uses it yet.
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
| iOS distribution | Decided 2026-11-09: iOS ships through the App Store without C++ authoring ([decisions](decisions.md)) |
| Licence for user-created/shared sound modules | Open |
| How AutoStacc delivers the free app and the support bundles | Open |
| Initial trust state for a newly encountered native component | Open; each component's trust level must be explicitly chosen by the user; no silent trust assignment ([decisions](decisions.md), 2026-11-06) |
| How the optional AutoStacc cloud library syncs with project folders and the global library | Open; compatibility is required ([decisions](decisions.md), 2026-11-03) |
| Note clips stored as pattern text with .mid import/export, instead of stored as MIDI (#158) | Decided on the owner's behalf 2026-11-10, to confirm; also whether the app keeps one MIDI converter, the Dart one or the engine's ([decisions](decisions.md)) |
| Android developer verification for the sideloaded APK | Open. **[Fact, checked 2026-11-10]** Google requires apps on certified Android devices to come from registered developers, from 2026-09-30 in Brazil, Indonesia, Singapore and Thailand and globally in 2027 (no US or EU date yet); a free limited-distribution account reaches only 20 devices, and ADB installs and an advanced sideloading flow remain ([Android Developers Blog](https://android-developers.googleblog.com/2026/03/android-developer-verification-rolling-out-to-all-developers.html)). The owner decides whether and when to register `com.kmandevr.caw` with its signing key; it is not needed for `v1.0.0-beta.1` |
| Audio (2026-11-11, branch `audio-ui`): the look of the audio clips, the input sheet, Settings › Audio's input part and the sampler editor (in the APK); a default edge fade; recordings kept with the project or in a shared library; loop takes as stacked lanes for comping; imports copied (now) or referenced in place ([decisions](decisions.md#2026-11-11-audio-assets-clips-sampler-and-input-wp-j-choices-to-confirm)) | Open |
| Whether effect tails should carry across a layer loop restart in every case | Open; see [engine playback](engine.md#playback) |
| Music video editor (2026-11-12, #182; [decisions](decisions.md#2026-11-12-the-music-video-becomes-an-editor-owner-182)): the editor's look (in the APK), whether it should also open full screen instead of only in the sheet, what an empty stretch of the lane shows (now the arrangement; or hold the shot before), effects per shot (now) or per panel, a photosensitivity warning for Strobe, the editor's keys in the action catalogue, and whether Falling notes should be in the director's defaults | Open |
| Piano roll (WP-K2, 2026-11-11): the look of the Quantize… sheet and the step bar (in the APK); whether Ctrl+U should use the sheet's last settings; whether the slide-up on-screen keys should also step; the MIDI CC numbers for automation lanes (CC7 volume, CC10 pan, others from CC20, as proposed in #11), the volume curve (127·√gain) and how parameter lanes scale ([app](app.md)) | Open |
| Matching REAPER's flow ([REAPER's flow](reaper-flow.md)): the phone look of the new screens (Export sheet, send knob). S splits, Touch automation from a transport button and on-screen keys with pads (owner, 2026-11-10). The clip bar, the ruler with the loop range, markers and regions, the recording flow and automation writing are built; their look and the choices made for them are to confirm ([decisions](decisions.md)) | Open |
