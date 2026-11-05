---
title: Synth
summary: Implemented synth patch compiler, supported patch features, app behavior and verified gaps.
covers: [engine/src/synth.cpp, engine/tests/synth_test.cpp, app/lib/ui/builder_screen.dart, app/lib/ui/modulation_panel.dart]
updated: 2026-11-02
---

# Synth

This note describes the synth functionality that exists in the repository. It is not a proposal for a dedicated synth workstation or an external plugin.

## Current implementation

**[Fact, checked 2026-11-01]** The engine accepts modules with header kind: synth. The patch compiler translates the patch into ordinary generator code plus effect modules, which use the existing voice, pattern, hot-swap, export and deterministic-render paths. The Init synth template is included, and engine tests cover parsing, validation and generated output.

A synth patch is a code-editable module. In the current app, it is handled through the normal Builder workflow (the Code panel; in a narrow panel its controls and code scroll as one list under a one-row track card, and its sheets open as glass sheets while Glass is on): generated parameters appear in the Controls panel and the patch source remains editable in the code editor, which shows the restored code after a project undo or redo. There is no separate Vital/Serum-style synth screen or dedicated on-screen keyboard in the current UI.

## Supported patch features

| Area | Implemented behavior |
|---|---|
| Voices | Per-patch voice count from 1 to 32; default 8, subject to the project's voice cap |
| Pitch | Glide and note-driven pitch; pattern notes use the existing engine voice system |
| Oscillators | Three wavetable oscillator slots; built-in tables; level, unison up to 16, detune, frame position, octave, semitone and fine tuning |
| Wavetable playback | Built-in wavetable tables, band-limited playback, frame morphing and phase-distortion amount (warp) |
| Other sources | Sub oscillator and noise |
| Filters | Two filters; low-pass, high-pass, band-pass and notch; serial or parallel routing |
| Envelopes | Three ADSR envelopes |
| LFOs | Four tempo-synced LFOs: sine, triangle, saw, square, stepped random or a four-point curve |
| Macros | Four named macro controls |
| Modulation | Sources: envelopes 2/3, LFOs 1–4, macros 1–4 and velocity. Destinations: oscillator position/level/pitch, filter cutoff/resonance and master volume |
| Effects | Drive, bit-crush, delay, reverb and compressor; project effect modules can also be referenced in a dynamically sized patch effect chain |
| Validation | Patch values are range-checked; errors identify the source line/column; caw check --code prints generated code |

The synth modulation matrix is editable through the Builder's Modulation links panel. The general module/global modulation editor also supports expression-based modulation through the existing modulation path.

## Wavetable boundaries

The wavetable oscillator can morph through frames of its selected built-in table and supports up to 16 unison voices with detune. The table and unison count are fixed when a note starts. A bounded phase-distortion parameter is supported.

The following are **not implemented**:
- Drawing custom wavetable tables in the app.
- Rendering arbitrary generator modules into custom synth tables as a patch authoring workflow.
- Importing Serum/Vital WAV tables into a synth patch.
- A graphical multi-point LFO curve editor; the patch syntax supports a four-point curve via p0..p3, but drawing/editing arbitrary curves in the UI is not implemented.
- Additional oscillator warp modes such as hard sync, FM and fold.
- Built-in synth chorus and EQ effects. A project effect module can be used where the patch supports a named module effect.

Do not show unsupported patch lines as valid syntax or claim that imported/drawn tables are available.

## App and plugin boundaries

- Synth patches are edited through Builder's ordinary code and generated-controls workflow.
- The current app does not provide a dedicated synth page, on-screen synth keyboard, preset browser/tag manager or drag-to-modulate canvas.
- MIDI pattern file import/export is implemented, but USB/Bluetooth MIDI device connection and live hardware routing are not.
- Plugin Builder validates and packages native .caw source modules. It does not compile CLAP/VST3 binaries or host third-party plugins.
- The native module SDK/graph foundations are not the active Engine/VM playback path; see [engine implementation status](engine-build-status.md).

## Verification and source of truth

Implementation is in engine/src/synth.cpp, with tests in engine/tests/synth_test.cpp. App integration is through the normal Builder and module parameter path in app/lib/ui/builder_screen.dart and app/lib/ui/modulation_panel.dart. The detailed engine boundary is in [Engine](engine.md) and [Engine implementation status](engine-build-status.md).

If a patch feature changes, update this note in the same change and verify the generated syntax against the compiler/tests. Never infer support from the example of a future patch format.
