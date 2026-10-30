---
title: Vision and principles
summary: The owner's product brief, boundaries and principles for CAW as a modular sound-design and content-creation environment.
updated: 2026-10-30
---

# Vision and principles

This note states the product direction. The detailed technical plan is [Modular adaptive engine](engine-next.md); the current built implementation is in [engine](engine.md) and [app](app.md).

## What CAW is

**C.A.W means Code Auditioning Workspace.** It is a programmable sound-design and content-creation environment: bytebeat, bitwise and mathematical audio, procedural synthesis, sound design, reusable instruments/effects, MIDI and expressive patterns, samples, wavetables and exportable modules.

**CAW is not a DAW.** It creates building blocks for other applications; it does not need to recreate their arrangement, recording, mixing, mastering or general plugin-hosting workflows. It can provide lightweight audition/preview, combine creations for testing, and capture/record generated audio while sound is playing. Its purpose is to create, refine, package and export content for tools such as REAPER, not replace them.

The engine is a native, portable framework. The Flutter application is its current interactive creation environment, not the definition of what the engine can do. The same engine should support the app, CLI, offline renderer and future plugin builds.

## What it creates

- Bytebeat, deterministic bitwise and mathematical audio.
- Procedural drums, one-shots, loops, textures and sound effects.
- Custom synthesizers, oscillators, waveforms, wavetables, filters, envelopes, LFOs and modulation systems.
- Reusable audio effects and modular processors.
- MIDI patterns, generative MIDI, expressive per-note curves and MPE-style output.
- Samples, multisamples, presets and portable module packages.
- Eventually distributable CLAP plugins first, then VST3 and other formats where practical.

Stereo is native throughout the engine. It is not a bolt-on feature or merely a final pan stage.

## Principles

1. **Code is first-class.** Readable .caw files remain editable sources of truth. Visual editing supplements code; it never replaces or blocks it.
2. **Immediate iteration when needed.** Code → hear → tweak should be fast, but not every task needs ultra-low latency.
3. **Phone-first, not phone-limited.** Touch-first use on Android, with the same underlying creative capability on desktop. Adapt presentation to screen/input, not creative capability.
4. **Deterministic experimentation.** Seeded procedural and bitwise sound remains repeatable. Optimization must preserve defined semantics or expose a distinct, tested render mode.
5. **Local and offline.** Core creation/rendering works without an account, server, AI provider or DAW.
6. **Modular and reusable.** Modules, curves, waveforms, MIDI expressions, effects and tools can be reused in contexts beyond their first purpose.
7. **Creation is not locked to one method.** Start from factory content, begin blank, write code, assemble modules visually, or hand-build a specialized processor/UI.
8. **Interactive UI is extensible.** Modules can describe a generated interface, while developers can replace it with a fully custom hand-built interface. UI is separate from audio processing.
9. **Factory is a starting point.** Factory content remains under caw/factory. Each substantial asset should keep its source and documentation together.
10. **Local/global asset scopes.** Project-local assets travel with the project; global assets can be reused across projects through stable IDs and versioned references.
11. **Adaptive hardware use.** Use CPU features, multiple cores, memory, GPU and audio hardware where supported and measured. Choose execution strategy by workload: low latency for audition, efficient batching/parallelism for background work and offline rendering. Do not force realtime constraints on everything.
12. **Real-time safety remains absolute when audio is active.** No allocation, locks, I/O, logging, exceptions or unbounded work in the audio callback.
13. **AI is optional.** The long-term direction includes an agent/LLM working directly with CAW projects and files, rather than requiring copy/paste prompts. CAW remains fully useful without AI.
14. **Portable and externally useful.** Other applications should consume exported content without CAW running. CAW creates plugins; it does not become a general plugin host.
15. **Low-end devices matter.** Resource budgets, adaptive scheduling and measured performance are foundational, not late polish.
16. **Permissive dependencies.** Avoid GPL or commercial dependencies unless the owner explicitly approves. The existing proprietary project licence remains.

## Creation experience

The app should feel like a sound-design instrument, not a desktop IDE squeezed onto a phone. It provides a touch-friendly code editor, live preview where appropriate, scopes/meters, generated controls, interactive waveform/curve/filter/LFO editors, library and project browsing, MIDI/pattern tools, import and export, and clear feedback about errors and resource costs.

Code, generated controls, visual assembly and custom interfaces all operate on the same native module/parameter model. No screen or editor owns the underlying DSP implementation.

## AI and library workflow

AI assistants should be able to create/edit documented plain-text assets and project files. The longer-term goal is optional direct agent operation inside CAW, with validation, preview and review of changes. GitHub may version/sync files, but never executes audio code. Downloaded code remains sandboxed; no privileged GitHub token is embedded in the app.

## How the owner works

The owner works from an Android phone and relies on AI-assisted development. Keep complexity and manual steps low; all installable builds should be available from GitHub Actions. Inspect before assuming, reuse working code, separate facts from proposals, and use staged changes with tests rather than a risky rewrite.

## Open questions

Only the owner can settle these; do not silently decide them:
- iOS distribution model and whether iOS should ship.
- Licence for user-shareable sound-library modules.
- How AutoStacc purchases unlock/deliver the app.
- Whether non-pattern layer effect tails carry over loop restarts (current behavior is documented in [engine](engine.md#playback)).
- Exact supported plugin export subset and which native DSP operations can be compiled to each plugin target.
- Which hardware capability and thermal APIs are reliable on each target platform; verify before relying on them.

