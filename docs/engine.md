---
title: Engine and language reference
summary: What the built C++ engine does: the module language, playback of layers, the project file, exports, the C API, the caw CLI and the tests.
covers: [engine/, examples/]
updated: 2026-11-10
---

# Engine and language reference

The engine in `engine/` as built. The reasons behind it are in [architecture](architecture.md), and the version plan is in [roadmap](roadmap.md). All of it is **[Fact]**: it is checked by `engine/tests/`.

## Layout

| Path | What it is |
| --- | --- |
| `engine/src/` | The portable core: `compile` (header, lexer, parser, code generation), `vm`, `builtins`, `detmath` (a forward to the public `include/caw/detmath.hpp`), `pattern` (note patterns), `engine` (mixer and voices), `component_chain` and `note_events` (native effects and instruments), `builtin_components`, `project`, `render` (exports), `docs` (generated reference), `wav`, `json`, `capi` |
| `engine/lib/` | The built-in libraries, written in the module language (`drum`, `synth`, `util`). CMake builds them into the engine |
| `engine/include/caw.h` | The C API, version 4 |
| `engine/platform/` | Audio output through miniaudio, and a stand-in for builds without a device |
| `engine/cli/` | The `caw` tool |
| `engine/tests/` | Unit tests and golden renders (`golden.txt`) |
| `engine/bench/` | `caw_bench`, which times the engine like a phone's audio callback ([performance](performance.md)) |
| `engine/third_party/miniaudio/` | miniaudio 0.11.25 (2026-03-04), unmodified, public domain or MIT-0 |
| `examples/` | Starter modules. CMake builds them into the engine, and the app offers them as templates |

Build and test (Linux or macOS, CMake 3.22+ and a C++20 compiler):

```
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build && ctest --test-dir engine/build --output-on-failure
```

## Module files (`.caw`)

A module is one text file: an optional header between `---` lines, then code.

```
---
caw: 1               # module format version (only 1 exists)
kind: generator      # generator (makes sound), effect (changes `in`), library (functions only) or pattern (notes)
name: Bass
summary: Filtered saw bass playing an A minor pattern
mode: float          # byte or float; default byte for generators, float for effects
rate: 8000           # byte mode only: how fast t counts (1000-192000, default 8000)
---
param cutoff = 900 in 100..4000
let env = ad(step % 4 == 0, 0.002, 0.18)
lpf(saw(mtof(A1)), cutoff * (0.3 + env), 4) * env
```

Unknown header keys are ignored, so newer files still load. With no header, a file is a byte-mode generator, so a bytebeat formula pasted on its own just works.

### Statements

- `let name = expression` names a value.
- `param name = default in min..max` declares a slider. The app shows one per param, and the value is fixed for a whole block. Without `in`, the range is 0–1 if the default is in it, and otherwise 0 to twice the default. The default, range and step must be finite numbers (a compile error otherwise). Options can come in any order after the default:
  - `step 0.5`: the slider moves in steps
  - `"How bright the bass is"`: a tooltip
  - `param filter = on` (or `off`): a toggle, 1 or 0
  - `param wave = saw in [sine, saw, square]`: a dropdown. Its value is the index (here 1), and the code can compare with `wave.square`.
- `global name = …` takes the same options as `param`, but the value belongs to the project. The app shows it once under Project controls, and every module that declares the same name reads the same value.
- `export let name = expression` shares a value. Other modules read it as `module.name`.
  - `module` is the module's name in lower case, with other characters as `_`: Kick gives `kick`, and Bytebeat loop gives `bytebeat_loop`.
  - The first layer (in project order) that plays the module provides the value. A silent layer shares zeros.
  - Layers run in dependency order, so a reader hears the same sample. When two modules read each other, one of them hears the other one block (64 samples) late.
  - An effect can read the export of the generator in front of it.
  - A name that nothing exports reads 0, and the project result lists it as a warning.
  - Within one layer, a module reads only exports of modules before it in the chain; an import from a later module (or itself) reads 0, with a warning.
- `fn name(a, b) = expression` defines a function.
  - Each call is expanded in place, so oscillators, envelopes and filters inside a function get their own state per call.
  - The body sees its arguments, built-ins, and names defined above the function.
  - Functions can't call themselves. Errors in a body show even if it's never called.
- **Comments with meaning:**
  - `/// text` lines directly above a `param`, `global`, `export let` or `fn` document it. The app shows them in tooltips.
  - `// --- Name ---` starts a group: the controls below it appear under that heading.
- The last line is the output, and it must be an expression.
- Statements are separated by new lines or `;`. A line ending in an operator, or an open bracket, continues on the next line. Comments are `//` and `/* */`.

### Values and operators

Every value is a 64-bit float, as in JavaScript, and the operators give JavaScript's results. So a formula pasted from a bytebeat site sounds the same here. The only exceptions are the defined cases marked below.

| Operators (loosest first) | Meaning |
| --- | --- |
| `c ? a : b` | choice (both sides are computed) |
| `\|\|` `&&` | JavaScript logic: returns one of its operands |
| `\|` `^` `&` | bitwise on 32-bit integers |
| `==` `!=` `<` `<=` `>` `>=` | 1 or 0 (`===` and `!==` are accepted too) |
| `<<` `>>` `>>>` | shifts; the count is masked to 0–31; `>>` keeps the sign, `>>>` doesn't |
| `+` `-` | |
| `*` `/` `%` | `x/0` and `x%0` give **0**; `%` keeps the left side's sign |
| `**` | power, right-associative |
| `-x` `+x` `!x` `~x` | unary |

Bitwise operators convert their inputs the JavaScript way: they drop the fraction and wrap modulo 2³², and NaN or infinity becomes 0. So `t>>6<<5%t` reads as `(t>>6) << (5%t)`. Numbers can be written `12`, `0.5`, `.5`, `1e3`, `0xFF` or `0b1010`. Note names are numbers: `C4` = 60, `A4` = 69, `F#2`, `Bb3`, octaves 0–9.

### Variables

| Name | Value |
| --- | --- |
| `t` | Byte mode: counts at `rate` per second. Float mode: samples. Both count from the layer's loop start |
| `sr`, `rate` | Device or export sample rate; `t`'s rate |
| `bpm`, `seed` | Project tempo and seed |
| `step`, `beat`, `bar` | 16ths, beats and bars since the layer's loop start (whole numbers) |
| `pos`, `phase` | 0→1 through the layer's loop. In wavetable export they go 0→1 through one frame |
| `time` | Seconds since the layer's loop start |
| `in` | The incoming sound, for effects (0 in a generator) |
| `trig`, `gate` | The note: `trig` is 1 on its first sample, `gate` is 1 while it's held |
| `note`, `freq`, `vel` | The note's pitch as a MIDI number (fractions allowed) and in Hz, and its velocity 0–1 |
| `rel` | Samples since the note was released (0 while held) |
| `bend` | The current note's pitch-expression offset in semitones; 0 when no bend curve is active |
| `pi` | π |

- **Note variables** come from the layer's [pattern](#patterns). Each note runs the generator as its own voice, and inside a voice `t`, `time` and `phase` count from the note's start: `phase` goes 0→1 once per cycle at `freq`, and in byte mode `t` runs at `rate` when the note is C4, twice as fast an octave up. `step`, `beat`, `bar` and `pos` still follow the layer.
- Without a pattern, the note variables describe one C4 note held through each layer loop: `trig` is 1 on the loop's first sample, `gate` and `vel` are 1. In a wavetable export `freq` is 1, so `sine(freq)` is one cycle.
- They are soft names: a `let` or function argument called `note`, `gate`, `trig` and so on hides them, so older modules keep working.

### Patterns

A module with `kind: pattern` holds notes, not code. A layer picks one as its pattern, and the layer's generator plays its notes. Patterns are plain text, so a person or an AI agent can write one:

```
---
kind: pattern
name: Acid line
length: 16          # in 16ths, or `length: 2 bars`; without it, the whole bars its notes need
---
// at   note(s)    len   vel   extras
0       A1         2     1
3       A1         1     0.8   slide
13/3    E2         1     0.6   prob 0.5
4.5     C3,E3,G3   1/2   0.9   ratchet 2
```

- **Columns:** `at` and `len` are in 16ths and may be decimals or fractions (`13/3` lands exactly on a triplet). Notes are names (`A1`, `F#3`) or MIDI numbers, with fractions for microtones; commas make a chord. `vel` is 0–1 and optional (default 1).
- **Extras:**
  - `prob P`: the note plays with chance P. The choice comes from the project seed, the note and which repeat of the pattern this is, so every project loop plays the same way and exports match playback.
  - `ratchet N`: the note is split into N equal repeats (2–8).
  - `slide`: the next note starting exactly where this one ends takes over its voice. No new `trig`; the pitch glides over half a step. In a chord, sliding notes pair with the next chord's notes in written order.
  - `bend`: per-note pitch curve in semitones, written as time/value points; optional segment bend handles use `~`.
  - `vib`: vibrato depth, rate in Hz and optional fade-in.
  - `press`: per-note pressure/volume curve; `timbre`: per-note timbre curve. These are preserved in the pattern model and emitted as MPE expression on MIDI export.
- **Playback:**
  - The pattern sets the layer's loop length; a note running past the end is released there.
  - A pattern layer's voice count defaults to 8 and can be set from 1 to 32 in the module header, subject to the project's overall voice cap. When the layer reaches its configured voice limit, it steals the oldest voice.
  - A released voice ends after 0.1 s below −90 dB, or 10 s after release. Code that reads `gate` or `rel` shapes its own release and code that reads `trig` rings on like a one-shot; anything else (a plain bytebeat) is faded out by the engine over 10 ms at note-off.
  - A stolen or ended voice that is still sounding is smoothed over (its last value fades in about 2 ms), so it doesn't click. Effects in the chain run once on the sum of the voices.
  - A tempo change releases held notes. At most 16 note changes split one 64-sample block; further ones in that block start together (at most 1.3 ms early).
  - Notes that start at or after the pattern's length never play, and the project result warns about them.
  - An `export let` in a voiced generator shares the newest voice's value.
- **Limits:** note collections grow dynamically; there is no fixed 4096-note parser cap. Pattern step indices use the signed 32-bit representation boundary rather than a fixed 4096-step product cap; note-expression curves are dynamically sized. Ratchets remain limited to 8. Errors give a line and column. Kit rows (`[kick]` lines) are reserved for kit patterns and are an error for now.

### MIDI files

A pattern can be imported from, and exported to, MIDI files for use in Reaper and other DAWs (code in `engine/src/midifile.cpp`).

- **Import:** `caw midi import IN.mid -o OUT.caw [--track N] [--channel C] [--name NAME] [--no-bend] [--no-slides]`, or `caw_pattern_from_midi(data, size)`, which returns `{"ok","error","pattern"}`.
  - It reads Standard MIDI Files (format 0 and 1) and MIDI 2.0 Clip Files (`.midi2`). All tracks and channels are merged unless one is chosen.
  - Times come from ticks, so tempo changes don't move notes. Whole steps are written as numbers, small fractions exactly (`13/3`), and anything else to 1/1000 step.
  - Notes with the same start, length and velocity become one chord line. Velocity is vel/127, or vel/65535 for a clip file.
  - The pattern is the whole bars of the file's first time signature (4/4 without one).
  - A pitch bend sounding at a note's start becomes a microtonal pitch, assuming ±2 semitones.
  - A note that overlaps the next one by at most 1/8 step becomes a `slide`, so ordinary legato playing comes in as slides. `--no-slides` turns that off.
  - Limits: 16 MB and 65536 events; notes and steps are bounded only by the signed 32-bit step representation (a caller may pass a lower note allowance). Format 2, SMPTE-timed and malformed files give an error.
- **Export:** `caw midi export PATTERN.caw -o OUT.mid|OUT.midi2 [--bpm B] [--beats N] [--clip]`, or `caw_pattern_export(source, bpm, beats_per_bar, CAW_MIDI_SMF|CAW_MIDI_CLIP, path, error, len)`.
  - Both formats use 960 ticks per quarter and carry the tempo, the meter and the pattern's name.
  - Ratchets are written as their repeats, every note is written whatever its `prob`, and a slide is a legato overlap of 1/16 step. Notes are cut at the pattern's length, as in playback.
  - `.mid` is a format 1 file. Microtonal notes round to the nearest note and play on a channel of their own (2–9, 11–16) with a pitch bend; RPN 0 sets the bend range to ±2 semitones. If the pattern has note expressions (bend, vibrato, pressure or timbre), export uses an MPE lower zone with per-note pitch bend, channel pressure and CC74 timbre.
  - `.midi2` follows the MIDI Clip File specification (M2-116-U, read 2026-10-28): MIDI 2.0 notes with 16-bit velocity, and microtones through the Note On Pitch 7.9 attribute.
    - **[Assumption]** Some layout choices aren't fixed by the spec. Everything is on group 0, channel 1. Tempo, time signature and clip name sit right after Start of Clip. Note Off has velocity 0x8000.
    - **[Assumption]** Which DAWs read clip files is unverified ([architecture](architecture.md#variables-and-patterns-proposal)).

### Built-ins and libraries

Every function, with its arguments and an example, is in the generated [function library](library.md); this is the overview.

- **Built-in functions** (C++, `engine/src/builtins.cpp`), by category:
  - Maths, Bits and Random (`hash`, `noise`, `rand`, `randi`, `chance`)
  - Oscillators (band-limited `saw` and `square`) and Envelopes (`ad`, `env.adsr`, `env.ar`)
  - LFOs (`lfo.*`, in beats, so they follow the tempo)
  - Filters (`lpf`, `hpf`, `bpf`, `notch`, `lp1`, `hp1`, `slew`)
  - Effects (`fx.*`: delay, reverb, drive, crush and more) and Glitch (`glitch.*`: stutter, hold, mask, wrap and more)
  - Music: `scale`, `quantize`, `chord`, `arp`, `euclid`, `beats`
- **Constants:** `scale.*`, `chord.*` and `arp.*` name the scales, chords and arpeggio modes the music functions take.
- **The project key:** `scale`, `chord` and `arp` default to the key in the project file (`key_root`, `key_scale`); A minor when it has none.
- **Built-in libraries** (`engine/lib/*.caw`), written in the module language so anyone can read how they work: `drum.*` (kick, snare, hat, clap), `synth.*` (supersaw, pluck, acid, pad, fm) and `util.*` (duck, gate, trem).
- Each call to a function with state (oscillators, envelopes, filters, effects) has its own state. The state returns to its start at every loop start, so every loop repeats exactly, and echo and reverb tails stop at the restart (after the seam crossfade). Delay, reverb and stutter buffers aren't cleared at the restart; they count what they've written since and read unwritten samples as 0, so a restart costs the audio thread almost nothing.
- A param passed straight to a documented argument borrows that argument's description as its tip, unless it has its own.

### Library modules

A module with `kind: library` and `namespace: name` holds only documented `fn` functions. Every other module in the project can call them as `name.fn(…)`; the library itself makes no sound and is skipped in layers.

```
---
kind: library
namespace: mine
name: My tools
---
/// Folds a signal back into -1..1.
/// x: the signal
/// amount: 1 = none, higher folds more
/// example: mine.fold(sine(110), 3) * 0.5
fn fold(x, amount) = sin(x * amount)
```

- The `///` lines document the function: a summary, then one `arg: meaning` line per argument and an `example:` line. The app's Library sheet and completion show them.
- The namespace is letters, digits and `_`, starting with a letter. A function whose name is already taken (a built-in, a constant or an earlier library's) is an error on that library alone: it is left out, and the other modules keep working.

### Output

- **Byte mode:** keeps the low 8 bits (`v & 255`) and maps them to −1…1. This is classic bytebeat.
- **Float mode:** the value is the sample, clamped to −1…1, with NaN and infinity turned into 0.

### Limits (the sandbox)

The language has no I/O, loops or recursion, so a program's cost is fixed when it compiles. A module may not exceed:
- 64 KB of source
- nesting 128 deep
- 1024 values (registers)
- dynamically sized params and globals (subject to source/register representation limits)
- dynamically sized exports/imports, bounded by the Engine's hardware-derived graph-working memory share
- functions nested 32 calls deep, and 4096 function calls expanded in all (each call is copied in place, so nested calls multiply)
- 1,048,576 numbers (8 MB) of state for oscillators, envelopes, filters, delays and reverbs
- across the whole project, a project-state share of the EngineResourceBudget, derived from the platform's conservative available-memory probe. Unknown memory uses an explicit 64 MiB project-state fallback. Over-budget layers are not installed and the project update returns an error.

Errors give a line and column, counting the header lines, for example `line 5, col 5: unknown name 'nope'`.

## Playback

- **Project:** BPM, beats per bar, loop length in bars, seed and master volume. The project loop is `round(steps × 60 × sr / (bpm × 4))` samples, and every layer restarts when it wraps.
- **Layers:** up to 64. Each layer is a generator (or a native C++ instrument, below) followed by a dynamically sized effect chain; chain length is constrained by explicit host resource budgets, not a fixed product limit. A layer loops at its own length in 16ths, or its pattern's length; 0 means it follows the project loop. Each loop start falls at `round(k × length)`, so a 3-bar layer against a 4-bar loop stays in time.
- **Pattern layers:** notes start and end on the exact sample (`round(at × samples per 16th)`). At a pattern restart, held notes are released, but voices and effects carry on, so tails ring across it and there's no seam crossfade. Editing a pattern swaps it in at the next block without rebuilding the sound. A note that is already sounding finishes where the old pattern ended it, and the edit is heard from the note's next start. Editing the generator's code keeps held notes playing in the new code (see Hot swap).
- **Seams:** when a layer restarts, the end of its previous pass crossfades into the new one over 3 ms. This can be turned off per project with `seam_crossfade`.
- **Hot swap:** changed code replaces the old program with a 20 ms crossfade, without stopping. Code that fails to compile reports an error and leaves the old program playing.
  - **Unchanged calls keep playing:** every stateful call (oscillator, envelope, filter, delay, reverb …) has a name made of its function, the `fn` calls it sits inside, and how many like it come before it there. If the new code has a call with the same name and size, it takes over the old one's running state, so changing one number doesn't restart phases, envelopes or echoes. Other calls start fresh under the crossfade.
  - Up to 262,144 numbers (2 MB) of state are carried over per swap, so the copy stays cheap on the audio thread; past that, calls start fresh. In a pattern layer, the voices and their held notes carry over too.
  - **When:** at once, or at the next beat or bar line (the project's `swap`), sample-exact. Newer code replaces code still waiting, and a layer nobody hears swaps at once.
- **Mix:** each layer has volume, constant-power pan, mute and solo, smoothed over 5 ms. The master chain is master volume, then a 5 Hz DC blocker, then a safety limiter with a ceiling of −0.2 dBFS, always last.
- **Overload:** the host reports how much of each audio callback was used. If the average stays above 85% for 20 callbacks, the engine mutes the newest audible layer, flags it in the meters and waits 100 callbacks before it would mute another. Clearing the overload unmutes them.
- **Threads:** the control thread compiles code and sends messages to the audio thread through a lock-free queue. The audio thread hands retired programs back the same way, so it never allocates, locks or frees. Parameter and mix values are atomics.
- **Globals and exports:**
  - A global's value comes from the project's `globals` (or its default), and changes take effect without recompiling.
  - Each layer has as many export buffers as its chain exports (lazily allocated, within a project-wide budget, #133). They're filled while its chain runs, so they're also ready for the effects later in that chain.
- **Determinism:**
  - The output doesn't depend on the device's buffer size.
  - The engine builds with `-ffp-contract=off` (MSVC `/fp:precise`, which never contracts).
  - It uses its own `sin`, `exp` and `log`, so every platform gives the same bits.

## Project file (JSON)

The app, the CLI and exports share one format:

```json
{ "caw_project": 1, "name": "Night Glitch", "bpm": 140, "beats_per_bar": 4, "loop_bars": 4,
  "seed": 7, "master": 0.7, "seam_crossfade": true, "voices": 8, "swap": "now", "key_root": 9, "key_scale": 1, "globals": { "swing": 0.1 },
  "automation": [
    { "target_type": "param", "module": "m1", "target": "cutoff",
      "points": [ { "step": 0, "value": 900 }, { "step": 64, "value": 2400 } ] },
    { "target_type": "global", "target": "swing",
      "points": [ { "step": 0, "value": 0 }, { "step": 64, "value": 0.2 } ] }
  ],
  "modules": [ { "id": "m1", "name": "Kick", "source": "...the .caw text...", "params": { "shift": 6 } } ],
  "layers": [
    { "id": "g1", "name": "Group", "folder": true, "bus": true,
      "volume": 0.9, "pan": 0, "mute": false, "solo": false },
    { "id": "l1", "name": "Byte lead", "chain": ["m1", "fx1"], "parent": "g1",
      "clips": [ { "id": "c1", "pattern": "p1", "start_steps": 0, "length_steps": 16,
                  "source_offset_steps": 0, "loop": true } ],
      "volume": 0.8, "pan": 0, "mute": false, "solo": false,
      "automation": [ { "target": "volume", "points": [ { "step": 0, "value": 0.8 }, { "step": 64, "value": 0.4 } ] } ] }
  ],
  "audition": { "chain": ["m1"], "pattern": "p1", "length_steps": 0 }, "audition_only": false }
```

- Optional project-level `automation` lanes target module parameters or named project globals. A parameter lane uses `target_type: "param"`, its stable `module` ID and parameter `target`; a global lane uses `target_type: "global"` and the global `target` name. Each lane has song-time `points` with `step` and `value`. Points are linearly interpolated; the lane holds its first/last value outside its point range. The project loop extends far enough to include the latest arrangement or automation point, then repeats. Parameter values are clamped to the declared parameter range. A global lane reaches every module declaring that global name. The field is optional, so older project files remain valid. Project-level lane and point collections are dynamically sized; they are constrained by the overall project memory budget rather than fixed lane/point counts.
- A module's `name` is what `module.export` uses; without it, the header's `name:` is used.
- `key_root` is 0–11 from C and `key_scale` is a `scale.*` index (0 major, 1 minor); they default to A minor.
- A legacy layer's \`pattern\` names one pattern module; its notes play the generator, and its length replaces \`length_steps\`.
- A layer's `instrument` (a component entry, as in `components`) is a native C++ instrument that plays its notes in place of a .caw generator: its `chain` then holds only .caw effects, and any other module in it is left out with a warning (see the C API's native components, below).
- An arrangement layer can instead contain \`clips\`. Each clip references a reusable pattern source and has \`start_steps\`, \`length_steps\`, \`source_offset_steps\` and \`loop\`. Clip instances may overlap; all of their notes use the track's one generator/effect chain and voice pool.
- The control thread compiles clips into a sorted absolute-time event stream when the project changes. The audio callback does no pattern parsing or timeline allocation: it splits its current block at note boundaries and renders the events at their sample positions. The scheduler follows project transport and loop boundaries; it does not depend on Flutter timers.
- Folder layers may set `folder: true`, `bus: true|false` and `parent`. A parent must be an existing folder; cycles and invalid parents are rejected. Bus folders sum their descendants' stereo output once, then apply the folder's volume and pan before routing to an ancestor bus or master. Organization-only folders do not process audio.
- A layer's `automation` array supports `volume` and `pan` lanes, each with any number of ordered `{step, value}` points. The audio callback linearly interpolates these points against absolute song position; no UI timer or per-block parsing is involved. Volume values are 0–1; pan values are -1–1.
- If a clip references a missing or broken pattern, that clip contributes no notes; legacy broken patterns keep their last good version playing.
- `voices` is how many voices each pattern layer may use for new notes, 1–8 (default 8; the app's light mode sends 4). Voices already sounding finish when it drops.
- `swap` is when changed code is heard while playing: `now` (default), `beat` or `bar`.
- `audition` is the Builder's preview, with an optional pattern. With `audition_only`, only that chain is heard.
- Values outside their range are clamped:
  - BPM 20–400
- Any number of layers: the Engine grows to fit, up to what its memory budget allows (`maxLayers()`), and refuses a project with more by name (F7.3).
- Song positions are refused with a message naming the field, never moved or shortened (F7.2): `loop_bars`, layer `length_steps`, clip `start_steps`/`length_steps`/`source_offset_steps`, automation point steps and the audition length must be whole numbers (points may be fractional) that fit the 32-bit step count, so a song holds whole bars up to 2^31 − 1 steps (`maxLoopBars`/`maxArrangementSteps` in `engine/src/project.h`). Project automation lengthens the loop to reach its last point.
- Clips are expanded off the audio thread. A layer whose clips would expand past the project-state budget left (an upper bound, checked before expanding) is not installed, with a warning. Building takes about three times the result, so that peak must fit the budget left after the project so far and the layer's own chain.
- Fields the app adds for itself, such as colours, are ignored.

## Exports

| Kind | What it renders |
| --- | --- |
| Loop | One exact project loop (refused before rendering when it is longer than a WAV file holds, about 3.1 hours of stereo float at 48 kHz). The engine renders two loops and keeps the second, so the file starts with the seam crossfades it has when it repeats. Includes a `smpl` loop chunk over the whole file. Bit-identical to the second loop of live playback |
| Free | Any length from 0.1 to 600 seconds, from the start |
| One-shot | One pass of one layer (its own or its pattern's length, or the project loop if it follows it), at most 30 s. The end is trimmed to 5 ms after the last sound above −80 dB |
| Wavetable | 1–256 frames of 2048 samples from one module, sweeping one param from its min to its max. In a frame, `t` runs 0–2047, `phase` 0–1 and `sr` is 2048, so `sine(1)` is one cycle. Each frame's DC is removed, and the table is normalized to peak 1. Written as 32-bit float mono |

- Files are WAV at 44.1 or 48 kHz, as 24-bit PCM or 32-bit float.
- An export refuses to run if any module or pattern it uses has an error.
- **[Assumption]** Serum may want an extra `clm ` chunk to recognise 2048-sample frames. This isn't written yet; check before relying on Serum.

## Hardware profile and execution policy

The native hardware probe is a one-time, non-real-time snapshot. It uses active/online logical CPUs, process affinity where exposed, and Linux/Android cgroup CPU and memory limits where readable. Windows uses available physical memory; Linux/Android combine system-available memory with a finite cgroup limit minus current usage. An exhausted finite cgroup limit is represented by a 1 MiB scheduler budget; a zero field means the signal is unavailable. Positive measurements are budgeted at one quarter, capped at 8192 MiB. macOS/iOS currently use half of reported physical memory as a conservative fallback, not live available memory. The scheduler falls back to one worker for unknown or very low memory. On Android, the host reads thermal status (Android 10+) and battery-saver state once, then listens for changes through event-driven platform channels; foreground/background and audio-playing transitions also refresh the worker budget. Unsupported platforms retain an explicit `Unknown` pressure state; background/offline work reserves one host core where possible and GPU work is disabled. Physical-device behavior still requires validation.

## C API (`engine/include/caw.h`)

- **Checking a module:** `caw_check(source)` returns JSON: ok, error, line, col, kind, mode, name, summary, and:
  - `params`: each with name, default, min, max, step, kind (`number`, `toggle` or `choice`), choices, tip, header, doc and global
  - `exports` (name and doc), `imports`, and `functions` (name, args and doc)
  - for a pattern: kind `pattern`, name, summary, `notes` (how many), `length_steps`, `length_bars` and `last_end`
- **Engine:** `caw_engine_create(sample_rate)` creates one.
  - `caw_engine_set_project(json)` returns the same description per module, plus `ref` (its name for exports) and `warnings`.
  - Live controls: `caw_engine_set_param`, `caw_engine_set_global`, `caw_engine_set_layer_mix`, `caw_engine_set_master` (a 5 ms audio-thread gain ramp), `caw_engine_play`, `caw_engine_play_at` (play from a position in sixteenth steps, converted with the tempo in effect when the play arrives, so a pause resumes on the same beat; it fades in over 10 ms, as does a play that interrupts a stop's fade; outside the loop it starts at 0, notes that began before it are not heard and a trig waits for its module's next pass), `caw_engine_stop`, `caw_engine_clear_overload`.
  - Note previews (#103): `caw_engine_note_on(layer_id, id, pitch, velocity)`, `caw_engine_note_pitch`, `caw_engine_note_off`, `caw_engine_notes_off`; heard through the layer's effects and mix while playing or stopped, without moving the transport (detail: [engine build status](engine-build-status.md)).
- **Meters:** `caw_engine_meters` (master sample peaks since the last read, left and right), `caw_engine_layer_meter` (a track's or folder's sample peak since the last read, after volume and pan) and `caw_engine_scope` (1024 samples of a track's signal before pan, per layer, or for the master and the audition by `CAW_SCOPE_MASTER`/`CAW_SCOPE_AUDITION`).
- **Hosts and devices:** `caw_engine_process(left, right, frames)` lets hosts such as a plugin drive the audio. `caw_audio_start` and `caw_audio_stop` open the device through miniaudio: AAudio or OpenSL ES on Android, WASAPI on Windows, Core Audio, and ALSA or PulseAudio.
- **Exports:** `caw_render(project_json, options, path, progress, cancel, …)` writes a WAV. Progress counts 0–1000, and a non-zero cancel stops it.
- **Templates:** `caw_template_count`, `caw_template_file` and `caw_template_source`.
- **MIDI files:** `caw_pattern_from_midi` and `caw_pattern_export` (see [MIDI files](#midi-files)).
- **Function library:** `caw_library()` returns JSON: `functions` (name, category, signature, doc, example and args with name, doc and optional) and `constants`. The app's Library sheet reads it.
- **Native C++ components:** `caw_engine_load_component(engine, library_path, expected_component_id, trust_level)` loads a built shared library into the Engine's `ModuleRegistry` and returns JSON with `ok`, component ID, error text and error code. The caller must pass `CAW_NATIVE_TRUST_BLOCKED`, `CAW_NATIVE_TRUST_ISOLATED` or `CAW_NATIVE_TRUST_TRUSTED`; there is no default. Blocked refuses before opening the library, Isolated is rejected until a separate-process host exists, and Trusted loads in-process. `caw_engine_unload_component` returns 1 only when the library can be unloaded (no live processor wrapper retains it). A build does not call either API. The component exports one C symbol, `caw_get_component_v3` (`engine/include/caw_component.h`); the Engine activates each master-chain instance (`activate(sample rate, kBlock)`) before it plays, and creation, destruction and memory stay inside the component. `caw_engine_components` returns every loaded component's descriptor as JSON (identity, role, timing, ports with layout and channel count, parameters with choices and capability flags, UI controls). The Dart FFI wrapper calls load, unload and the listing on a background isolate. Components see the song's transport in each block (`CawProcessBlock.transport`, `caw::Transport`): the tempo and beats per bar always, and the position in beats with `playing` set while the song plays. A project places loaded stereo effects (one stereo audio input, one stereo audio output, any parameters) in a layer's `components` (after its .caw chain, before volume and pan) and in `master_components` (before the safety limiter); each entry is an id or `{"id": ..., "params": {name: value}, "bypass": bool, "state": base64, "state_version": n}`. A bypassed component crossfades to its input over 5 ms and is then not run. A saved state loads when the chain is built (a component may refuse it, which refuses the update). Project automation lanes reach component parameters with `{"target_type": "component", "layer": id (absent: the master), "component": index, "target": param}`: a lane rules while playing, a knob move overrides it until the next Play, and parameters the descriptor marks not automatable ignore lanes. A component that is not loaded, has other ports or names an unknown parameter refuses the whole update. An update with the same components in the same order keeps each chain's running state. `caw_engine_set_component_param(engine, layer_id, index, param_id, value)` changes a value while playing (NULL or empty layer id: the master), ramping over the parameter's smoothing. `caw_engine_set_component_bypass` bypasses one while playing, and `caw_engine_component_states` returns each component's state as JSON (base64) for the project; the app stores it on every save (`ProjectDoc.storeComponentStates`). API version 4 (instruments, below). After Stop, effects that declare a tail (`tail_frames`) ring out on silence until their output stays below −80 dB for 0.25 s (at most the declared tail, and 30 s); effects without one stop with the transport and start the next play from silence. Tracks are kept in time with the track whose effects add the most latency (the sum of their `latency_frames`, up to 32,768 frames): the others are delayed after volume and pan. Every Engine also has the Library's built-in stereo tools, which need no trust choice and can't be unloaded. `org.caw.stereo.balance` (`pan` −1..1: the side being turned down falls linearly, the other stays at unity) and `org.caw.stereo.width` (`width` 0..2, mid/side: 0 is mono, 1 unchanged; a mono signal is unchanged at every width) both live in `engine/src/builtin_components.cpp`, with kernels in `caw/library/stereo.hpp`. `org.caw.distortion` (`shape`: Drive, Hard clip, Fold or Crush; `drive` 1..20, `bits` 1..24, `mix`, `output` 0..2) distorts each channel separately. Its kernels in `caw/library/distortion.hpp` are the same code the .caw `fx.drive`, `fx.crush` and `fx.fold` call, so both sound the same (goldens unchanged). `org.caw.delay.pingpong` (`sync`: Free or a note division from 1/16 to a bar, `time` in ms when free, `feedback` 0..0.95, `cross` 0..1 for ping-pong, `mix`) has up to 4 s of delay, set aside at activate (a longer division is held at 4 s), and glides to a new time; it syncs to the song's tempo and rings out after Stop. `org.caw.chorus` (`rate` 0.05..5 Hz, `depth`, `mix`) sweeps each side a quarter cycle apart, so a mono signal comes out wide. `caw_engine_components` lists them first, with `"builtin": true`. `caw_engine_reload_component` loads a rebuild (a new file) of a loaded component: every chain using it switches to the new build, keeping each instance's values, bypass and (if the new build accepts it) state, and a chain swap of any kind (a rebuild, an effect added or removed) crossfades over 20 ms while it sounds. The per-component trust store remains outstanding.
- **Native instruments (#156, API version 4):** a component with one event input and one stereo audio output (no other ports; `ComponentChain::isInstrument`) can be a layer's `instrument`; an instrument in `components`, or an effect as `instrument`, refuses the update. It is a one-component `ComponentChain` (`buildInstrument`) on the track's slot, so values, bypass (a crossfade to silence), state, automation, transport, latency (added to the track's), rebuilds and the project-component cap work as for effects; `CAW_INSTRUMENT_INDEX` (0xFFFFFFFF) addresses it in `caw_engine_set_component_param`, `_bypass` and `_component_states`, and lanes use `{"target_type": "instrument", "layer": id, "target": param}`. The engine sends it the track's notes as MIDI 2.0 UMP note events with host note ids (the encoding in [the SDK](native-module-sdk.md#writing-an-instrument)), queued per block in a fixed `NoteEvents` list (2,048 events, 128 held notes; more are counted, `overflow()`, and a 129th note ends the oldest), frame-accurate in every block: pattern and clip notes with the same rules .caw voices follow (chance per repeat, ratchets, clip loops, loop restarts ending held notes, a slide as a pitch glide on the held note without a new on, the note's bend, vibrato, pressure and timbre every 16 frames, and notes of an edited pattern ending where the old one ended them), note previews (`caw_engine_note_on/_pitch/_off/_notes_off`: piano roll and MIDI keyboards), and offs for every held note at Stop, at a tempo change and at Play. After Stop it rings out (its release, then the track's effects) until the track is quiet for 0.25 s, at most 30 s; at Play it is reset unless a preview is held, so an export (the same path, `setProjectOffline`) starts from silence. A track muted long enough to stop is reset before it plays again. A new or rebuilt instrument takes over the held notes (a new on for each, same ids) while the old one releases them and crossfades out over 20 ms. The track then runs its .caw effects (they are mono: they take the instrument's mid, and without any the instrument stays stereo), its native inserts, volume and pan. The built-in `org.caw.synth.basic` ("Basic synth", 16 voices) has two oscillators (`wave1`, `wave2`: saw, square, triangle, sine; `detune` in cents, `mix`), a resonant state-variable low-pass (`cutoff` 40..18000 Hz, `resonance`, `env`: how far the envelope opens it; a note's timbre opens it too), an ADSR envelope (`attack`, `decay`, `release` 0.001..10 s, `sustain`) and `volume`; velocity and pressure scale each voice, and its maths is deterministic (a golden render, `instrument_test.cpp`).
- Strings the engine returns are freed with `caw_free`. Only `caw_*` symbols are exported.
- Nothing throws across the API: running out of memory comes back as an error.

## The `caw` CLI

```
caw check FILE.caw...
caw render INPUT.caw|INPUT.json -o OUT.wav [--loop | --seconds S | --oneshot LAYER | --wavetable MODULE --param P --frames N]
           [--rate 44100|48000] [--float] [--bpm B --bars N --steps N --pattern FILE]
caw templates
caw docs [--check] [--dir DIR]
caw midi import IN.mid -o OUT.caw | caw midi export PATTERN.caw -o OUT.mid [--clip]
```

- For a single `.caw` file, `render` builds a one-layer project: `--bpm` and `--bars` set the loop, `--steps` sets the layer's length, and `--pattern FILE` plays it from a pattern's notes. `caw check` checks patterns too.
- It prints frames, length, peak and RMS, and flags `SILENT` or `CLIPPING`, so an agent can check its work without listening.
- `caw docs` writes [library.md](library.md) and [agent-guide.md](agent-guide.md) into `docs/` from the engine's own docs. It fails if a function lacks a description, an argument description or an example, or if an example doesn't compile or is silent. `--check` only compares, and CI runs it, so the notes can't drift from the code.

## Tests

`engine/build/caw_tests` runs 291 tests and `engine/build/caw_rt_tests` 76 more (CTest runs both):
- **Language:** JavaScript semantics, the defined edge cases, built-ins, params, error messages and limits.
- **Variables:** functions, rich params, globals, exports across layers in either order, exports inside a chain, missing sources, and cycles.
- **Library:** envelopes, LFOs, the music helpers (NaN arguments included), delay, effects and glitch tools, effect buffers starting silent on every loop, project libraries and name clashes, borrowed tips, the function-call and project memory budgets, and that every function is documented with an example that plays.
- **MIDI files:** round trips of the templates through `.mid` and `.midi2`, chords, fractions, microtones, exact clip and SMF bytes, hand-built files with running status and tempo changes, and thousands of truncated or corrupted files that must give errors without crashing.
- **Patterns:** the note format and its errors, sample-exact note starts and ends, chords and voice stealing without clicks, the note variables, ratchets, slides, repeatable probability, pattern length, byte-mode pitch, the engine's release fade, notes released by seed and tempo changes, packed patterns, late-note warnings, pattern edits letting sounding notes finish, code edits keeping held notes, the default note without a pattern, and exports checking patterns.
- **Mixer:** (runs through the Engine's mix graph since F4.3) block-size independence, a track removed from inside a folder fading out (issue #76), layer lengths, seams, hot swap (calls keeping their state, swaps waiting for the bar), broken code, mute, solo and pan, overload, stop and removal, effects, params and the limiter.
- **Exports:** loop lengths, export equal to playback, free-length renders and cancel, one-shots, wavetables, broken modules and WAV bytes.
- **Modules and graph:** descriptor validation (layouts, the 64-channel port ceiling, identity version, role, choice parameters), the CP.2 capability flags (the executor refuses a modulation link, automation lane or CC mapping a parameter does not allow), the processor contract and its stereo adapter, graph compile errors and budgets, and the planar N-channel executor: distinct generated signals per channel for mono, stereo, quad, 5.1, 7.1 and Discrete(3), channel isolation, fan-in summing order (summing inputs), typed ports (sidechain, modulation, control, and event merge order, overflow and order checks), parameters (resolution, modulation links, automation lanes against the Engine's lane values, MIDI CC mappings), audio-thread re-routing (`setRouting`: validation, rejection keeps the old routing, unlisted nodes skipped, no allocation), host channel-count mismatches, processor failure reporting, re-prepare/reset, runtime publication, and no allocation or free in `process()`. These real-time tests are in `caw_rt_tests`, whose `engine/tests/alloc_counter.cpp` replaces the global `operator new`/`delete` to count calls; keeping it out of `caw_tests` keeps AddressSanitizer's new/delete mismatch checks there.
- **Instruments:** `instrument_test.cpp`: the project fields, the UMP note encoding, the bounded note list, notes reaching a recording fixture instrument on their exact frames across loop wraps and clip loops, slides, previews (ids, glides, notes off), Stop and Play, values, bypass and lanes, state, a rebuild taking over held notes, .caw effects after an instrument, wrong-shaped components refused, the built-in synth starting a note mid-block and its golden render, and the C API; `engine_rt_test.cpp` plays, swaps, previews and stops instruments without an allocation.
- **Native SDK:** compiled components cross the plain-C interface v3 in `engine/include/caw_component.h` (installed with the SDK; `tests/component_header_check.c` compiles it as C99); `CAW_EXPORT_COMPONENT` in `engine/include/caw/component.hpp` builds it from a C++ `ModuleProcessor`. The C++ contract is `engine/include/caw/module.hpp`, exposed through the installable `CAW::SDK` package, which also checks with `static_assert` that its enums and event record match the C ones. `ModuleRegistry` and the Engine C API load explicit-trust shared libraries on Windows and POSIX through that one entry point, copy and validate the descriptor and stable ID, refuse a library without it (`MissingEntryPoint`), another interface version (`IncompatibleAbi`) or a missing function (`IncompleteTable`), and keep the library loaded while instances live. Tests: a fixture component, and a second build of it without the entry point.
- **Mixer golden renders:** eight multi-track projects in `engine/tests/mix_golden_test.cpp` (pan, a folder bus, nested folders, mute and solo together and each alone, folder and track automation, the limiter driven through a bus and shown to engage), rendered in uneven blocks and hashed over float bits. They hold routing changes, such as moving the mixer into the graph, to bit-exact output. A companion test shows a muted or non-soloed track contributes exactly nothing: the mix equals the same project without it.
- **Golden renders:** one hash per template in `engine/tests/golden.txt`. A hash changes only with an intended sound change; then run `caw_tests --update-golden` and say why in the commit.

The suite passes under GCC 13, Clang 18, and GCC with AddressSanitizer and UBSan (`-DCAW_SANITIZE=ON`). GCC and Clang give identical golden hashes.
