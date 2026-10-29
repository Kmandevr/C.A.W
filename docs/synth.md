---
title: Synth
summary: The house synth (kind: synth): a Vital/Serum-style instrument whose patch is a readable .caw file, its layout, file format, engine design and build stages.
updated: 2026-10-29
---

# Synth

The house synth from [vision](vision.md) and [roadmap](roadmap.md#v2--variables-patterns-house-synth-and-mvp). Owner's choices (2026-10-29) are **[Fact]**; the rest is **[Proposal]** until built.

## What the owner asked for

- **[Fact]** A Vital/Serum-style synth that is also code: a fixed-layout screen on top, and underneath, the patch is one readable `.caw` file that the owner or an AI agent can edit directly.
- **[Fact]** A new module kind, `kind: synth`. It opens in Sounds as the synth screen with a Code tab, and a track can use it as its sound to play patterns.
- **[Fact]** Android first, inside the app. The engine side stays ready to become a CLAP/VST3 plugin, which will get a full custom UI.
- **[Fact]** Playing: patterns and an on-screen keyboard now; MIDI hardware later.
- **[Fact]** Wavetables: built-in shapes (sine, saw, square, triangle and more), tables rendered from any C.A.W code, tables drawn by hand, and imported Serum/Vital WAV tables.
- **[Fact]** Full size (no small caps on voices or unison), heavily optimised, and the app warns on overload (the engine's overload muting and Light mode already do).
- **[Fact]** Effects stay basic and useful first, and any slot can hold an effect module the user built.
- **[Fact]** The owner accepted these defaults (2026-10-29): 3 wavetable oscillators plus a sub and a noise source; unison up to 16 with detune and spread; warp modes; 2 filters (serial or parallel); 3 envelopes, 4 drawn LFOs, 4 macros, a mod matrix with drag-to-modulate; drive, chorus, delay, reverb, EQ and compressor; presets as `.caw` files with tags.

## The patch file **[Proposal]**

One line per part, like pattern files: easy to read, diff and write by hand or by an agent. The synth screen edits these lines and keeps comments, the way the piano roll keeps a pattern's comments.

```
---
caw: 1
kind: synth
name: Glass pad
summary: Wide detuned pad with a slow filter sweep
tags: pad, wide
---
voices 8
glide 0.02

// --- Oscillators ---
osc a table saw level 0.8 unison 7 detune 0.25 spread 0.8 pos 0 warp sync 0.3
osc b table hollow level 0.5 octave -1 pos 0.5
osc c off
sub level 0.3 shape sine octave -1
noise level 0.05 color 0.6

// --- Filters ---
filter 1 lowpass cutoff 1200 res 0.3 drive 0.1 keytrack 0.5 from a b sub
filter 2 off
filters serial

// --- Modulation ---
env 1 attack 0.01 decay 0.3 sustain 0.7 release 0.4   // env 1 shapes the volume
env 2 attack 0.2 decay 1 sustain 0 release 0.5
lfo 1 shape tri rate 1/4 bar
lfo 2 shape 0:0 0.5:1~0.4 1:0 rate 2 hz
macro 1 Bright 0.5
mod env 2 -> filter 1 cutoff 0.4
mod lfo 1 -> osc a pos 0.3
mod macro 1 -> filter 1 cutoff 0.5
mod vel -> volume 0.5

// --- Effects ---
fx drive amount 0.3
fx chorus rate 0.5 depth 0.4 mix 0.4
fx crushfx                 // the project's own effect module, by name
fx reverb size 0.6 mix 0.25

// --- Tables ---
table hollow 0:0 0.25:1~0.5 0.5:0 0.75:-1~-0.5 1:0   // drawn: one cycle, points and bends
table grit from glitchwave frames 64 sweep shift      // rendered from a generator module
table vocal file vocal.wav                            // imported 2048-sample frames
```

- Values are the same numbers the screen shows; anything left out takes its default, so a patch can be three lines.
- `~k` bends the segment after a point, as in [the Curve tool](app.md) and the [curve proposal on #11](https://github.com/Kmandevr/C.A.W/issues/11).
- **Eject to code:** the screen can turn a patch into an ordinary generator module (the code the engine runs for it, below), for sound design past what the layout offers.

## How the engine plays it **[Proposal]**

Reviewed by the `architect` agent (2026-10-29): the core fits the engine as built, with the changes folded in below.

- **A patch compiles to C.A.W code.** The engine translates the patch into a generator program (one voice) plus effect programs, using new native built-ins for the heavy parts. That reuses what already works: the voice pool and pattern playback, hot swap that keeps running state, exports, the CLI, determinism, golden tests and the sandbox. The VM runs each op over a whole block, so a few dozen ops per voice cost little; the work is inside the built-ins.
- **Each part is its own function** in the generated code (`osc_a`, `filt_1`, `env_2`), because hot swap matches running state by call path: adding an oscillator then doesn't restart the others.
- **Voices hold no delays or reverbs.** Every voice is a whole copy of the voice program's state, so effects live only in the effect programs, after the voices are summed.
- **Voice count:** today every pattern track has a fixed pool of 8. It becomes a per-patch setting (`voices`) up to a fixed maximum, set aside when the track is installed; the sandbox needs a fixed bound. Proposed maximum: 32.
- **New built-ins**, each native C++ over a whole block:
  - `wt(table, freq, pos, unison, detune, …)`: a wavetable oscillator with up to 16 unison voices inside one call, morphing between frames, band-limited by mipmapped tables (one table per octave) so high notes don't alias
  - warps: sync, bend, phase distortion, FM from another oscillator, and bit and sample crush
  - comb and formant filters next to the existing `lpf`, `hpf`, `bpf` and `notch`; a drawn-shape LFO `lfo.shape`; `fx.chorus` and `fx.eq`
- **Tables** are shared, read-only data owned by the compiled program (or by the engine, for the built-in shapes), never per-voice state: a 256-frame table with its mipmaps is about 5 MB of floats, loaded once.
  - In code a table is a name fixed at compile time (`table.saw`, `table.hollow`); the compiler stores its index in the call, and the VM hands the built-in a pointer to it. Tables don't count against a module's state limit; they get their own memory budget, and going over it fails closed (the module reports an error, nothing crashes).
  - Mipmaps (one band-limited copy per octave) are built with the engine's own deterministic maths, the same on every device.
  - Settings that can't change while a note plays (the table, the unison count) are fixed at compile time, which keeps `wt` within the 6 arguments a call can take.
  - Drawn LFO shapes and drawn tables use the same mechanism. Tables from code reuse the wavetable export.
- **Imported tables** are stored next to the patch: in the project file as their own `tables` entry, and in git as a `.wav` beside the `.caw`.
- **Effects run in line order:** each run of built-in `fx` lines becomes one generated effect program, each user module is its own instance where its line is, and the track's own effects come after. In the example, drive and chorus run first, then `crushfx`, then reverb.
- **Stereo:** unison spread, chorus and reverb need stereo, and the engine is mono per track today (a track is panned at the mix). The plan: synth stage 1 is mono; then a program can declare stereo output (a second output register and right-channel buffer, stereo built-ins writing two adjacent registers, mono user effects run as a left and right pair, and pan acting as balance). Mono tracks keep today's code path, so every existing golden render stays bit-identical.
- **Placement:** `engine/src/tables.{h,cpp}` (storage, mipmaps, built-in shapes) and `engine/src/synth.{h,cpp}` (patch to code and tables, a pure function); the new built-ins in `builtins.cpp`; imported WAV tables are read when the project is set, never on the audio thread. No new C API call: `caw_check` accepts `kind: synth` and returns the parsed parts and the generated code, which is also what "eject to code" uses.
- **The app doesn't parse the patch itself.** It edits lines as text and reads the structure from the engine's JSON, so there is one grammar, in the engine.

## Open questions

- **Voice maximum.** The owner asked for no caps; the sandbox needs some fixed bound. Proposed: 32 voices per track, each oscillator up to 16 unison.
- **Plugin UI library.** Picked when the plugin stage starts; it must be permissively licensed. **[Fact]** (checked 2026-10-29 on [github.com/VitalAudio/visage](https://github.com/VitalAudio/visage)) Visage is MIT-licensed and draws with Direct3D 11, Metal, Vulkan and WebGL on Windows, macOS, Linux and the web; it lists no Android or iOS support, so it would serve the desktop plugin, not the phone app.

## Build stages **[Proposal]**

1. **Engine core**, each step tested on its own with `caw_tests` and the CLI:
   1. tables with the built-in shapes and mipmaps, and `wt(table.saw, freq, pos, unison, detune)` usable from plain code, with golden renders
   2. the voice count as a per-patch setting up to the maximum
   3. `synth.cpp` for a first subset (oscillators, sub, noise, one filter, the volume envelope, effect groups) and `kind: synth` in `caw check`, with goldens of the generated code and its sound
2. **Stereo** for programs that declare it, then spread, chorus and reverb in stereo.
3. **Modulation:** envelopes, drawn LFOs, macros and the mod matrix.
4. **App:** the synth screen (oscillators, filters, modulation, effects pages), drag-to-modulate, the on-screen keyboard, the table editor (draw, from code, import WAV), presets with tags and search.
5. **Warps, the extra filters and effects, and optimisation** measured with `caw_bench` on the phone's budget.
