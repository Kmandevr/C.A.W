---
title: Vision and principles
summary: The owner's brief, condensed: what C.A.W is, its platforms, its principles, the sound-engine approaches, the interface and the AI workflow, plus the open-questions register. Guides decisions; not a spec.
updated: 2026-10-28
---

# Vision and principles

The owner's brief (2026-10-28), condensed. Where this note and the code disagree, the code says what exists. The technical answer is in [architecture](architecture.md).

## What it is

**Name (owner, 2026-10-28):** C.A.W stands for **Code Auditioning Workspace**. The logo is a crow.

A cross-platform app that works as an experimental sound-design instrument: bytebeat, mathematical sound, procedural synthesis, raw audio manipulation and glitch music. It has the immediacy of an instrument and the flexibility of a programming environment. It isn't a DAW, a generic code editor or just a bytebeat player. It complements Reaper by making unusual sounds, instruments, effects and samples to export.

**Platforms (owner, 2026-10-28):** Android, iOS, Windows, macOS and Linux, and more where practical. Android comes first: the owner's phone is a Galaxy S22+.

**Bits (owner, 2026-10-28):** code works directly on the bits, so sounds can be chaotic and random-sounding yet exactly repeatable, like `t>>6<<5%t`.

**Instruments and exports (owner, 2026-10-28):** any sound can become a playable synth, a waveform or wavetable to load into other synths, or a sample (one-shot, loop or multisample). This is a core capability, not an extra.

**Synthesis, MIDI, ease of use (owner, 2026-10-28):** proper synthesis and MIDI support, and user-friendly helpers so musical results, such as a loop that fits the beat, are easy to make.

**Layout and look (owner, 2026-10-28):** three areas: a **Builder** for making modules (sounds and effects), an **Arranger** for using them, and an **Exporter**. What you build can later be played in a **house-built synth**. Neon on black: green, pink, yellow and blue.

**Plugins (owner, 2026-10-28):** it may also ship as a VST3 or CLAP plugin. **Standalone (owner):** every build runs fully on its own and offline.

**Business direction (owner, 2026-10-28):** closed and commercial, sold only through AutoStacc, the owner's own store. Until then, it's the owner's tool for making samples to sell on AutoStacc, so getting sound out as WAV comes before polish for other users.

## Principles (established direction)

1. **Code is the source of truth.** Sounds and effects are defined in editable code, not locked behind conventional synth controls.
2. **Immediate experimentation.** Change code, hear it, iterate.
3. **Local audio.** Generation and playback run on the device, offline included.
4. **Modular.** Instruments, effects, functions, patterns and tools are reusable across projects without copying source around.
5. **AI-assisted creation.** AI assistants create and edit sound files through the file structure and GitHub. The instrument stays fully useful without AI, and all rendering is local.
6. **Open architecture.** Not tied to one AI provider or one sound engine.
7. **Built for commercial release** through AutoStacc. Licensing, security, maintainability, performance and user data ownership are considered from the start.

## Sound engine approaches

- **Bytebeat and mathematical audio:** expressions of a time variable using bitwise logic, shifts, arithmetic and maths functions, from classic bytebeat to harsh noise and glitch textures.
- **Procedural synthesis:** code-defined kicks, snares, basses, clicks, drones and unconventional instruments, with every component editable.
- **Raw audio and byte manipulation:** import audio and transform it (bit depth, sample rate, bitwise ops, reinterpretation, distortion, repetition). Originals are preserved and processing is nondestructive.
- **Sequencing and polyrhythms:** a compact language that is easy to read and fast to type on a phone, with independent loops, shared BPM and polyrhythms. The owner's examples (`kck`, `snr`, `hat`, `p8`, `p16`, `p4`) are ideas, not required syntax.
- **Reusable effects and modules:** define once, reuse anywhere (bitcrushers, waveshapers, byte folding, granular stutter, delays, filters, sample manglers).

## Interface

It should feel like an instrument, not a desktop IDE on a phone. It has a touch-friendly syntax-highlighted editor, instant play, stop and restart, a waveform display (and spectrum where practical), auto-generated parameter controls, a library browser, a pattern area, import and WAV export, and clear feedback for errors and expensive code. It stays compact, with expandable panels and sensible defaults.

## AI workflow

1. The owner asks an AI for a sound.
2. The AI edits files in the sound library.
3. Changes are versioned on GitHub.
4. The app fetches them, validates them and loads compatible modules.
5. The owner hears the result and keeps editing.

GitHub stores and versions files; it never runs audio code. Downloaded code is untrusted. Auth never relies on a privileged token embedded in the app; per-user repositories let users own their work.

## How the owner works

From an Android phone (Galaxy S22+), relying on AI-assisted development. Keep complexity, AI usage and manual steps low. Inspect before assuming, reuse what exists, separate facts from proposals, prefer a small working prototype over a large unfinished architecture, and present a short plan before large or irreversible changes.

## Open questions

Only the owner can settle these. Never build one as settled; ask.

| Question | Blocks | Status |
| --- | --- | --- |
| iOS: sell through the App Store as the one exception to AutoStacc-only, or skip iOS ([architecture](architecture.md#6-biggest-risks-and-simplest-mitigations)) | iOS release | Open |
| Licence for the sound library's modules (e.g. CC0 or MIT) | Stage 3 (sharing modules) | Open |
| How a purchase on AutoStacc unlocks or delivers the app (plain download, account check, licence key) | Stage 5 | Open |
