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

- **A patch compiles to C.A.W code.** The engine translates the patch into a generator program (one voice) plus an effect program (after the voices are summed), using new native built-ins for the heavy parts. That reuses what already works: the voice pool and pattern playback, hot swap that keeps running state, exports, the CLI, determinism, golden tests and the sandbox.
- **New built-ins**, each native C++ over a whole block:
  - `wt(table, freq, pos, unison, detune, …)`: a wavetable oscillator with up to 16 unison voices inside one call, morphing between frames, band-limited by mipmapped tables (one table per octave) so high notes don't alias
  - warps: sync, bend, phase distortion, FM from another oscillator, and bit and sample crush
  - comb and formant filters next to the existing `lpf`, `hpf`, `bpf` and `notch`; a drawn-shape LFO `lfo.shape`; `fx.chorus` and `fx.eq`
- **Tables** are shared, read-only data owned by the compiled program (or by the engine, for the built-in shapes), never per-voice state: a 256-frame table with its mipmaps is about 5 MB of floats, loaded once.
- **Imported tables** are stored next to the patch: in the project file as their own `tables` entry, and in git as a `.wav` beside the `.caw`.
- **User effect modules** in `fx` lines join the track's effect chain after the synth's own effects.
- **Stereo:** unison spread, chorus and reverb need stereo, and the engine is mono per track today (a track is panned at the mix). See the open question below.

## Open questions

- **Stereo engine.** Make every track stereo end to end (programs, effects, the mix and exports), or give only synth tracks a stereo path? Either way, mono modules and the golden renders must stay bit-identical.
- **Plugin UI library.** Picked when the plugin stage starts; it must be permissively licensed. **[Fact]** (checked 2026-10-29 on [github.com/VitalAudio/visage](https://github.com/VitalAudio/visage)) Visage is MIT-licensed and draws with Direct3D 11, Metal, Vulkan and WebGL on Windows, macOS, Linux and the web; it lists no Android or iOS support, so it would serve the desktop plugin, not the phone app.

## Build stages **[Proposal]**

1. **Engine core:** table storage with mipmaps and the built-in shapes, `wt` with unison and morphing, the patch parser and its translation to code, `kind: synth` in `caw check` and the C API, tests and golden renders.
2. **Stereo** (after the open question is settled), then spread, chorus and reverb in stereo.
3. **Modulation:** envelopes, drawn LFOs, macros and the mod matrix.
4. **App:** the synth screen (oscillators, filters, modulation, effects pages), drag-to-modulate, the on-screen keyboard, the table editor (draw, from code, import WAV), presets with tags and search.
5. **Warps, the extra filters and effects, and optimisation** measured with `caw_bench` on the phone's budget.
