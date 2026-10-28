---
title: Vision and principles
summary: The owner's brief, condensed: what C.A.W is, its principles, the sound-engine approaches, the interface and the AI workflow, plus the open-questions register. Guides decisions; not a spec.
updated: 2026-10-28
---

# Vision and principles

The owner's brief (2026-10-28), condensed. Where this note and the code disagree, the code says what exists. The technical answer is in [architecture](architecture.md).

## What it is

An Android app that works as an experimental sound-design instrument: bytebeat, mathematical sound, procedural synthesis, raw audio manipulation and glitch music. It has the immediacy of an instrument and the flexibility of a programming environment. It isn't a DAW, a generic code editor or just a bytebeat player. It complements Reaper by making unusual sounds, instruments, effects and samples to export.

## Principles (established direction)

1. **Code is the source of truth.** Sounds and effects are defined in editable code, not locked behind conventional synth controls.
2. **Immediate experimentation.** Change code, hear it, iterate.
3. **Local audio.** Generation and playback run on the device, offline included.
4. **Modular.** Instruments, effects, functions, patterns and tools are reusable across projects without copying source around.
5. **AI-assisted creation.** AI assistants create and edit sound files through the file structure and GitHub. The instrument stays fully useful without AI, and all rendering is local.
6. **Open architecture.** Not tied to one AI provider or one sound engine.
7. **Built for commercial release.** Licensing, security, maintainability, performance and user data ownership are considered from the start.

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

From an Android phone, relying on AI-assisted development. Keep complexity, AI usage and manual steps low. Inspect before assuming, reuse what exists, separate facts from proposals, prefer a small working prototype over a large unfinished architecture, and present a short plan before large or irreversible changes.

## Open questions

Only the owner can settle these. Never build one as settled; ask.

| Question | Blocks | Status |
| --- | --- | --- |
| Phone model and Android version (main test device, confirms `minSdk 27`) | Milestone 1, step 1 | Open |
| App licence direction: closed/commercial, open-source or open-core | Milestone 1, step 1; accepting contributions | Open |
| Licence for the sound library's modules (e.g. CC0 or MIT) | Stage 2 | Open |
| Keep "C.A.W" as the name? | Store listing | Open |
