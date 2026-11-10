---
title: Engine and language reference
summary: What the built C++ engine does: the module language, playback of layers, the project file, exports, the C API, the caw CLI, the component testing suite, the sample-pack maker and the tests.
covers: [engine/, examples/]
updated: 2026-11-10
---

# Engine and language reference

The engine in `engine/` as built. The reasons behind it are in [architecture](architecture.md), and the version plan is in [roadmap](roadmap.md). All of it is **[Fact]**: it is checked by `engine/tests/`.

## Layout

| Path | What it is |
| --- | --- |
| `engine/src/` | The portable core: `compile` (header, lexer, parser, code generation), `vm`, `builtins`, `detmath` (a forward to the public `include/caw/detmath.hpp`), `pattern` (note patterns), `engine` (mixer and voices), `component_chain` and `note_events` (native effects and instruments), `builtin_components` and `builtin_instruments`, `project`, `render` (exports), `docs` (generated reference), `wav`, `json`, `capi` |
| `engine/lib/` | The built-in libraries, written in the module language (`drum`, `synth`, `util`). CMake builds them into the engine |
| `engine/include/caw.h` | The C API, version 4 |
| `engine/platform/` | Audio output through miniaudio, and a stand-in for builds without a device |
| `engine/cli/` | The `caw` tool |
| `engine/plugin/clap/` | The CLAP wrapper that exports a component library as a `.clap` plug-in, and its test host |
| `engine/tests/` | Unit tests and golden renders (`golden.txt`) |
| `engine/bench/` | `caw_bench`, which times the engine like a phone's audio callback ([performance](performance.md)) |
| `engine/third_party/miniaudio/` | miniaudio 0.11.25 (2026-03-04), unmodified, public domain or MIT-0 |
| `examples/` | Starter modules. CMake builds them into the engine, and the app offers them as templates |

Build and test (Linux or macOS, CMake 3.22+ and a C++20 compiler):

```
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build && ctest --test-dir engine/build --output-on-failure
```

`-DCAW_CLAP=ON` (off by default; it fetches the CLAP headers from GitHub) also builds the CLAP export tests: the minimal example and a test bundle as `.clap` plug-ins, and `caw_clap_tests`, a small CLAP host CTest runs ([native module SDK](native-module-sdk.md#export-as-a-clap-plug-in)).

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
  - **A pattern edit while a note sounds** (owner, 2026-11-10, #170): pattern text has no note ids, so `setProject` matches the old pattern's notes to the new one's on the control thread (`matchPatternNotes`, `engine/src/pattern.cpp`): first notes with the same start, length, pitch and ratchets, in order (a curve, velocity or chance edit keeps the note); then each changed note takes the edited note that overlaps it in time, nearest in pitch, then start, then length (a move, stretch or transpose that still overlaps its old place). Past 2^24 pairs of changed notes that second pass is skipped. The map goes to the audio thread with the pattern (and is retired with it). On the track's next run, a held note (a .caw voice or a native instrument's) whose matched note still covers the playhead keeps sounding, with no new trig or note-on, and takes the new note's curve from the playhead, gliding from the pitch heard to where the new curve is over 5 ms; it then ends where the edited note ends. A note the edit deletes, or moves off the playhead, is released (its release, not a cut); a note the edit adds starts at its next start. A native note's 16-frame control grid keeps its phase across the edit. A voice copies the new curve into storage set aside for the layer's longest curve, rounded up to a power of two of at least 16 points, so adding a point seldom rebuilds the chain; a curve that doesn't fit (a beat- or bar-timed code swap still waiting) ends the note rather than allocate. Two notes at the same pitch overlapping the same place are told apart only by start and length, so a drag that swaps their order can hand a sounding note to the other one. With no edit nothing changes, so playback and export match (goldens unchanged).
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
- **Loop range** (REAPER's loop points, 2026-11-10): with `loop_range` on, playback that reaches `loop_end_steps` goes back to `loop_start_steps` (both rounded to samples like the loop), every layer restarting there as at the song's end, with the same seam crossfades. Played from after the range, the song plays to its end and then goes back to the range's start. Off (the default, and every older project), the whole song loops.
- **Layers:** up to 64. Each layer is a generator (or a native C++ instrument, below) followed by a dynamically sized effect chain; chain length is constrained by explicit host resource budgets, not a fixed product limit. A layer loops at its own length in 16ths, or its pattern's length; 0 means it follows the project loop. Each loop start falls at `round(k × length)`, so a 3-bar layer against a 4-bar loop stays in time.
- **Pattern layers:** notes start and end on the exact sample (`round(at × samples per 16th)`). At a pattern restart, held notes are released, but voices and effects carry on, so tails ring across it and there's no seam crossfade. Editing a pattern swaps it in at the next block without rebuilding the sound. A note that is already sounding follows the edit from the playhead, gliding onto its new curve, or is released if the edit deleted it or moved it off the playhead ([Patterns](#patterns)). Editing the generator's code keeps held notes playing in the new code (see Hot swap).
- **Seams:** when a layer restarts, the end of its previous pass crossfades into the new one over 3 ms. This can be turned off per project with `seam_crossfade`.
- **Hot swap:** changed code replaces the old program with a 20 ms crossfade, without stopping. Code that fails to compile reports an error and leaves the old program playing.
  - **Unchanged calls keep playing:** every stateful call (oscillator, envelope, filter, delay, reverb …) has a name made of its function, the `fn` calls it sits inside, and how many like it come before it there. If the new code has a call with the same name and size, it takes over the old one's running state, so changing one number doesn't restart phases, envelopes or echoes. Other calls start fresh under the crossfade.
  - Up to 262,144 numbers (2 MB) of state are carried over per swap, so the copy stays cheap on the audio thread; past that, calls start fresh. In a pattern layer, the voices and their held notes carry over too.
  - **When:** at once, or at the next beat or bar line (the project's `swap`), sample-exact. Newer code replaces code still waiting, and a layer nobody hears swaps at once.
- **Mix:** each layer has volume, constant-power pan, mute and solo, smoothed over 5 ms. Track and master volume are linear gains from 0 to +12 dB (3.981, `kMaxMixGain`; owner, 2026-11-10: faders like REAPER's), in the project JSON (`volume`, `master`) and the live controls alike; more is held at +12 dB. Volume automation lanes reach the same +12 dB (API version 7; before it they stopped at 0 dB), so a lane written from a fader keeps its level. The master chain is master volume, then a 5 Hz DC blocker, then a safety limiter with a ceiling of −0.2 dBFS, always last.
- **Overload:** the host reports how much of each audio callback was used. If the average stays above 85% for 20 callbacks, the engine mutes the newest audible layer, flags it in the meters and waits 100 callbacks before it would mute another. Clearing the overload unmutes them.
- **Threads:** the control thread compiles code and sends messages to the audio thread through a lock-free queue. The audio thread hands retired programs back the same way, so it never allocates, locks or frees. Parameter and mix values are atomics.
- **Globals and exports:**
  - A global's value comes from the project's `globals` (or its default), and changes take effect without recompiling.
  - Each layer has as many export buffers as its chain exports (lazily allocated, within a project-wide budget, #133). They're filled while its chain runs, so they're also ready for the effects later in that chain.
- **Determinism:**
  - The output doesn't depend on the device's buffer size.
  - The engine builds with `-ffp-contract=off` (MSVC `/fp:precise`, which never contracts), and `-fno-trapping-math` (Clang's default; it changes no result, since nothing reads floating-point exception flags, and lets GCC vectorize loops with selects).
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
- An arrangement layer can instead contain \`clips\`. Each clip references a reusable pattern source and has \`start_steps\`, \`length_steps\`, \`source_offset_steps\`, \`loop\` and an optional \`mute\` (a muted clip plays nothing, while its layer still follows the arrangement instead of running free). Clip instances may overlap; all of their notes use the track's one generator/effect chain and voice pool.
- The control thread compiles clips into a sorted absolute-time event stream when the project changes. The audio callback does no pattern parsing or timeline allocation: it splits its current block at note boundaries and renders the events at their sample positions. The scheduler follows project transport and loop boundaries; it does not depend on Flutter timers.
- Folder layers may set `folder: true`, `bus: true|false` and `parent`. A parent must be an existing folder; cycles and invalid parents are rejected. Bus folders sum their descendants' stereo output once, then apply the folder's volume and pan before routing to an ancestor bus or master. Organization-only folders do not process audio.
- A layer's `automation` array supports `volume` and `pan` lanes, each with any number of ordered `{step, value}` points. The audio callback linearly interpolates these points against absolute song position; no UI timer or per-block parsing is involved. Volume values are gains from 0 to +12 dB (`kMaxMixGain`, more is held there); pan values are -1–1.
- If a clip references a missing or broken pattern, that clip contributes no notes; legacy broken patterns keep their last good version playing.
- `voices` is how many voices each pattern layer may use for new notes, 1–8 (default 8; the app's light mode sends 4). Voices already sounding finish when it drops.
- `swap` is when changed code is heard while playing: `now` (default), `beat` or `bar`.
- `audition` is the Builder's preview, with an optional pattern. With `audition_only`, only that chain is heard.
- Values outside their range are clamped:
  - BPM 20–400
- Any number of layers: the Engine grows to fit, up to what its memory budget allows (`maxLayers()`), and refuses a project with more by name (F7.3).
- `loop_range` (default false) with `loop_start_steps` and `loop_end_steps` turns the loop range on (see Playback); while it is on, both must be whole steps with the end after the start, and the song lengthens to reach the end. Off, the two are not read.
- Song positions are refused with a message naming the field, never moved or shortened (F7.2): `loop_bars`, layer `length_steps`, clip `start_steps`/`length_steps`/`source_offset_steps`, automation point steps and the audition length must be whole numbers (points may be fractional) that fit the 32-bit step count, so a song holds whole bars up to 2^31 − 1 steps (`maxLoopBars`/`maxArrangementSteps` in `engine/src/project.h`). Project automation lengthens the loop to reach its last point.
- Clips are expanded off the audio thread. A layer whose clips would expand past the project-state budget left (an upper bound, checked before expanding) is not installed, with a warning. Building takes about three times the result, so that peak must fit the budget left after the project so far and the layer's own chain.
- Fields the app adds for itself, such as colours, are ignored.

## Exports

| Kind | What it renders |
| --- | --- |
| Loop | One exact project loop, or the loop range while it is on (refused before rendering when it is longer than a WAV file holds, about 3.1 hours of stereo float at 48 kHz). The engine renders two loops and keeps the second (with a loop range: from the start to the range's end, then the range again), so the file starts with the seam crossfades it has when it repeats. Includes a `smpl` loop chunk over the whole file. Bit-identical to the second pass of live playback |
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
  - Live controls: `caw_engine_set_param`, `caw_engine_set_global`, `caw_engine_set_layer_mix`, `caw_engine_set_master` (a 5 ms audio-thread gain ramp), `caw_engine_play`, `caw_engine_play_at` (play from a position in sixteenth steps, converted with the tempo in effect when the play arrives, so a pause resumes on the same beat; it fades in over 10 ms, as does a play that interrupts a stop's fade; outside the loop it starts at 0, notes that began before it are not heard and a trig waits for its module's next pass), `caw_engine_stop`, `caw_engine_clear_overload`. API version 7 (2026-11-10, REAPER flow gaps 3 and 4): `caw_engine_play_count_in(engine, step, beats)` clicks `beats` (0..64) beats at the tempo, accented on each bar, then plays from `step` as `play_at` does, on the sample after the last beat (previews play over it; a Stop cancels it; while playing it is `play_at`); `caw_engine_set_metronome(engine, on)` clicks every beat while the song plays, accented on the bar. The click is built in (`Engine::startClick`): 30 ms of a decaying sine, 1760 Hz at 0.5 on the bar and 1320 Hz at 0.32 on other beats, mixed into the master before the safety limiter while playing; the count-in, which runs with the song stopped, adds it to the output directly, held to ±1 (its peak is under the limiter's ceiling). Off by default; offline renders never click. It was chosen over a hidden click track as simpler and real-time safe: no allocation, a few floats of state. `caw_engine_release_touches(engine)` ends every knob touch as a Play does, without moving the transport, so lanes rule again at once (the app's automation Touch mode). Tests: `count_in_clicks_each_beat_then_plays_on_the_sample_after_the_last`, `metronome_clicks_on_every_beat_while_playing_and_not_when_off`, `released_touches_let_the_lanes_rule_again_while_playing`, and `count_in_metronome_and_released_touches_never_allocate_on_the_audio_thread`.
  - Note previews (#103): `caw_engine_note_on(layer_id, id, pitch, velocity)`, `caw_engine_note_pitch`, `caw_engine_note_off`, `caw_engine_notes_off`; heard through the layer's effects and mix while playing or stopped, without moving the transport (detail: [engine build status](engine-build-status.md)).
- **Meters:** `caw_engine_meters` (master sample peaks since the last read, left and right), `caw_engine_layer_meter` (a track's or folder's sample peak since the last read, after volume and pan; `caw_engine_layer_meter_stereo`, API version 5, also gives each side's peak, and either call resets both) and `caw_engine_scope` (1024 samples of a track's signal before pan, per layer, or for the master and the audition by `CAW_SCOPE_MASTER`/`CAW_SCOPE_AUDITION`).
- **Hosts and devices:** `caw_engine_process(left, right, frames)` lets hosts such as a plugin drive the audio. `caw_audio_start` and `caw_audio_stop` open the device through miniaudio: AAudio or OpenSL ES on Android, WASAPI on Windows, Core Audio, and ALSA or PulseAudio.
- **Exports:** `caw_render(project_json, options, path, progress, cancel, …)` writes a WAV. Progress counts 0–1000, and a non-zero cancel stops it.
- **Templates:** `caw_template_count`, `caw_template_file` and `caw_template_source`.
- **MIDI files:** `caw_pattern_from_midi` and `caw_pattern_export` (see [MIDI files](#midi-files)).
- **Function library:** `caw_library()` returns JSON: `functions` (name, category, signature, doc, example and args with name, doc and optional) and `constants`. The app's Library sheet reads it.
- **Native C++ components:** `caw_engine_load_component(engine, library_path, expected_component_id, trust_level)` loads a built shared library into the Engine's `ModuleRegistry` and returns JSON with `ok`, component ID, error text and error code. The caller must pass `CAW_NATIVE_TRUST_BLOCKED`, `CAW_NATIVE_TRUST_ISOLATED` or `CAW_NATIVE_TRUST_TRUSTED`; there is no default. Blocked refuses before opening the library, Isolated is rejected until a separate-process host exists, and Trusted loads in-process. `caw_engine_unload_component` returns 1 only when the library can be unloaded (no live processor wrapper retains it). A build does not call either API. The component exports one C symbol, `caw_get_component_v3` (`engine/include/caw_component.h`); the Engine activates each master-chain instance (`activate(sample rate, kBlock)`) before it plays, and creation, destruction and memory stay inside the component. `caw_engine_components` returns every loaded component's descriptor as JSON (identity, role, timing, ports with layout and channel count, parameters with choices and capability flags, UI controls). The Dart FFI wrapper calls load, unload and the listing on a background isolate. Components see the song's transport in each block (`CawProcessBlock.transport`, `caw::Transport`): the tempo and beats per bar always, and the position in beats with `playing` set while the song plays. A project places loaded stereo effects (one stereo audio input, one stereo audio output, any parameters) in a layer's `components` (after its .caw chain, before volume and pan) and in `master_components` (before the safety limiter); each entry is an id or `{"id": ..., "params": {name: value}, "bypass": bool, "state": base64, "state_version": n}`. A bypassed component crossfades to its input over 5 ms and is then not run. A component that says it has fallen silent (`ModuleProcessor::quiet()`, the C interface's `caw.quiet.v1` extension) sleeps (is not run, and its output is silence) until an event or input that is not silent arrives. A declared tail alone never puts one to sleep: it would fall asleep on a block boundary with its timed state frozen, so the output would depend on the device's buffer size (second audio review, 2026-11-10; test `a_sleeping_component_renders_the_same_at_any_block_size`). The built-in drums, acid synth and flagship synth say when they are quiet (the acid synth once its filter envelope has run out too, the flagship once no voice sounds and its effects have fallen below −94 dB); the others keep running. A saved state loads when the chain is built (a component may refuse it, which refuses the update). Project automation lanes reach component parameters with `{"target_type": "component", "layer": id (absent: the master), "component": index, "target": param}`: a lane rules while playing, a knob move overrides it until the next Play, and parameters the descriptor marks not automatable ignore lanes. A component that is not loaded, has other ports or names an unknown parameter refuses the whole update. An update with the same components in the same order keeps each chain's running state. `caw_engine_set_component_param(engine, layer_id, index, param_id, value)` changes a value while playing (NULL or empty layer id: the master), ramping over the parameter's smoothing. `caw_engine_set_component_bypass` bypasses one while playing, and `caw_engine_component_states` returns each component's state as JSON (base64) for the project; the app stores it on every save (`ProjectDoc.storeComponentStates`). API version 4 (instruments, below). After Stop, effects that declare a tail (`tail_frames`) ring out on silence until their output stays below −80 dB for 0.25 s (at most the declared tail, and 30 s); effects without one stop with the transport and start the next play from silence. Tracks are kept in time with the track whose effects add the most latency (the sum of their `latency_frames`, up to 32,768 frames): the others are delayed after volume and pan. Every Engine also has the Library's built-in stereo tools, which need no trust choice and can't be unloaded. `org.caw.stereo.balance` (`pan` −1..1: the side being turned down falls linearly, the other stays at unity) and `org.caw.stereo.width` (`width` 0..2, mid/side: 0 is mono, 1 unchanged; a mono signal is unchanged at every width) both live in `engine/src/builtin_components.cpp`, with kernels in `caw/library/stereo.hpp`. `org.caw.distortion` (`shape`: Drive, Hard clip, Fold or Crush; `drive` 1..20, `bits` 1..24, `mix`, `output` 0..2) distorts each channel separately. Its kernels in `caw/library/distortion.hpp` are the same code the .caw `fx.drive`, `fx.crush` and `fx.fold` call, so both sound the same (goldens unchanged). `org.caw.delay.pingpong` (`sync`: Free or a note division from 1/16 to a bar, `time` in ms when free, `feedback` 0..0.95, `cross` 0..1 for ping-pong: toward 1 the left line takes the mono average of both inputs and the right line none, so even a centred sound bounces left, right, left, its first echo at the dry level (before the second audio review, 2026-11-10, the left line took the sum, 6 dB over); `mix`) has up to 4 s of delay, set aside at activate (a longer division is held at 4 s), and glides to a new time; it syncs to the song's tempo and rings out after Stop. `org.caw.chorus` (`rate` 0.05..5 Hz, `depth`, `mix`) sweeps each side a quarter cycle apart, so a mono signal comes out wide. `caw_engine_components` lists them first, with `"builtin": true`. `caw_engine_reload_component` loads a rebuild (a new file) of a loaded component: every chain using it switches to the new build, keeping each instance's values, bypass and (if the new build accepts it) state, and a chain swap of any kind (a rebuild, an effect added or removed) crossfades over 20 ms while it sounds. The per-component trust store remains outstanding.
- **Native instruments (#156, API version 4):** a component with one event input and one stereo audio output (no other ports; `ComponentChain::isInstrument`) can be a layer's `instrument`; an instrument in `components`, or an effect as `instrument`, refuses the update. It is a one-component `ComponentChain` (`buildInstrument`) on the track's slot, so values, bypass (a crossfade to silence), state, automation, transport, latency (added to the track's), rebuilds and the project-component cap work as for effects; `CAW_INSTRUMENT_INDEX` (0xFFFFFFFF) addresses it in `caw_engine_set_component_param`, `_bypass` and `_component_states`, and lanes use `{"target_type": "instrument", "layer": id, "target": param}`. The engine sends it the track's notes as MIDI 2.0 UMP note events with host note ids (the encoding in [the SDK](native-module-sdk.md#writing-an-instrument)), queued per block in a `NoteEvents` list set aside when the instrument's chain is built (4,096 events a block and 1,024 held notes, 360 KB per instrument track, about 23 MB at 64 tracks, counted in the project memory budget; the host sets no practical polyphony cap, owner 2026-11-10). A thousand notes at once is far past what a track plays, and 4,096 events leave room for every held note to end and start again in one block; the earlier 16,384 events and 4,096 notes took 1.5 MB a track, about 94 MB at 64 tracks and twice that for a track during a rebuild (second audio review, 2026-11-10). Room for every held note's off is kept back from note-ons and per-note motion, so a full block drops a pitch or pressure update, never an off; drops are counted (`overflow()`), and a 1,025th note ends the oldest. The block's events are put in frame order by a natural merge sort of the runs they arrive in, frame-accurate in every block: pattern and clip notes with the same rules .caw voices follow (chance per repeat, ratchets, clip loops, loop restarts ending held notes, a slide as a pitch glide on the held note without a new on, the note's bend, vibrato, pressure and timbre every 16 frames, and held notes following a pattern edit, below in [Patterns](#patterns)), note previews (`caw_engine_note_on/_pitch/_off/_notes_off`: piano roll and MIDI keyboards), and offs for every held note at Stop, at a tempo change and at Play. After Stop it rings out (its release, then the track's effects) until the track is quiet for 0.25 s, at most 30 s; at Play it is reset unless a preview is held, so an export (the same path, `setProjectOffline`) starts from silence; one still ringing out after Stop first fades out over the new pass's first 5 ms, rendered at Play inside that callback, so the instruments ringing share a budget of 480 frames of that work (`Engine::kPlayTailBudgetFrames`: two fade over 5 ms, 16 over 0.6 ms each), and Play never costs more than about two 5 ms tails (second audio review, 2026-11-10). A track muted long enough to stop is reset before it plays again. A new or rebuilt instrument takes over the held notes (a new on for each, same ids) while the old one releases them and crossfades out over 20 ms. The track then runs its .caw effects (they are mono: they take the instrument's mid, and without any the instrument stays stereo), its native inserts, volume and pan. The built-in `org.caw.synth.basic` ("Basic synth", 128 voices) has two oscillators (`wave1`, `wave2`: saw, square, triangle, sine; `detune` in cents, `mix`), a resonant state-variable low-pass (`cutoff` 40..18000 Hz, `resonance`, `env`: how far the envelope opens it; a note's timbre opens it too), an ADSR envelope (`attack`, `decay`, `release` 0.001..10 s, `sustain`) and `volume`; velocity and pressure scale each voice, and its maths is deterministic (a golden render, `instrument_test.cpp`).
- **Built-in instruments (#157, `engine/src/builtin_instruments.cpp`):** seven more, built on the Library kernels (`caw/library/`, [SDK](native-module-sdk.md#the-library)), deterministic, allocation-free while processing, read their knobs every 16 frames, and each has a golden render (`builtin_instruments_test.cpp`). Drums ignore a note's pitch and offs; velocity sets the level, and a new hit fades the ringing one over 5 ms.
  - `org.caw.drum.kick` ("Kick"): a sine falling from `tune × (1 + 10 × punch)` to `tune` (20..200 Hz, 48), `punch` 0..1, `decay` 0.05..4 s (to −60 dB), `click` (a burst of filtered noise), `tone` 0 dark..1 bright, `drive` 1..10, `volume`.
  - `org.caw.drum.snare` ("Snare"): a triangle-and-sine body (`tune` 80..400 Hz, `body` decay) and high-passed noise (`snappy` decay, `tone` 200..12000 Hz), `mix` noise against body, `volume`.
  - `org.caw.drum.hats` ("Hi-hats"): six square waves at inharmonic pitches mixed with noise (`metal`), high-passed at `tone` (2000..14000 Hz); A#2 (46, the General MIDI open hi-hat) plays open (`open` decay), every other key closed (`closed` decay), unless `mode` makes every note Closed or Open. Any hit chokes the ringing one.
  - `org.caw.drum.kit` ("Drum kit"): General MIDI keys B1/C2 (35, 36) kick, D2/E2 (38, 40) snare, D#2 (39) clap (band-passed noise in three bursts and a tail), F#2/G#2 (42, 44) closed and A#2 (46) open hi-hat; other keys are silent. Knobs: `kick_tune`, `kick_decay`, `kick_punch`, `snare_tune`, `snare_snappy`, `clap_decay`, `hat_closed`, `hat_open`, `hat_tone`, a level per drum (`kick`, `snare`, `clap`, `hats`) and `volume`.
  - `org.caw.bass` ("Bass"): one voice, last-note priority: a saw or square (`wave`) with a sine an octave below (`sub`), a resonant 12 dB low-pass (`cutoff` 40..8000 Hz, `resonance`) that `env` opens by up to 5 octaves, `decay` (filter and level), `sustain`, `glide` (0.001..1 s; overlapping notes glide, and with `legato` On they don't restart the envelopes), `drive`, `volume`.
  - `org.caw.synth.acid` ("Acid synth"): 303-style, one voice: a saw or square into a 4-pole ladder (`cutoff` 40..5000 Hz, `resonance` up to self-oscillation), `env` (filter envelope depth), `decay`, `accent` (notes above velocity 0.7, fully at 1, open the filter further, decay faster and play louder), `slide` (the glide time when a note overlaps a held one; a pattern `slide` arrives as the host's pitch glide and needs no new note), `drive`, `volume`.
  - `org.caw.synth.morph` ("Morph synth"): 128 voices, each up to 16 unison copies (`unison`, `detune` ±1 semitone at 1, `spread` across the stereo field) of a wave that morphs sine, triangle, saw, square (`shape`; the wavetable pad's `table.basic`, computed with band-limited oscillators instead of a table), swept by `drift` over 16 beats of the song's tempo; a resonant 12 dB low-pass per side (`cutoff` 100..16000 Hz, `resonance`; a note's timbre opens it), ADSR (`attack`, `decay`, `release` 0.001..10 s, `sustain`), `volume`; velocity and pressure scale each voice.
  - `org.caw.synth.flagship` ("Flagship", #171, `engine/src/builtin_flagship.cpp`): the "synth that can do all the things" beside Morph, in original code (no Vital code, presets or wavetables; [decisions](decisions.md)). 64 voices; 191 parameters, grouped by id prefix so a layout can make sections:
    - **`osc1_`..`osc3_` (three wavetable oscillators):** `on` (osc 1 on by default), `table` (Basic: sine, saw, square, 25 % pulse; Analog: triangle, warm saw, shark fin, soft square, soft pulse; Vocal: A, E, I, O, U formants; Harmonic: a band of harmonics sweeping up over 16 frames; generated by code at the first activate, 1,024-sample mip-mapped frames shared by every instance), `frame` 0..1 (between frames, linearly), `level`, `pan`, `octave` ±4, `semi` ±12, `fine` ±100 ct, `phase`, `phase_rand` (0 every copy starts at `phase`, 1 at random), `warp` (None, Bend, Sync up to 8×, Mirror, Quantize 256..2 steps) and `warp_amt`, `unison` 1..16 (osc 1 seven), `detune` 0..100 ct (where the outermost copies sit), `detune_power` −1..1 (0 even spacing, +1 gathers copies near the note as \|x\|⁴, −1 pushes them out as \|x\|^0.25), `spread` (pan of each copy: \|x\| × spread, mirror pairs on opposite sides alternating pair by pair, so spread 0 is exactly mono), `blend` (0 only the centre copy or two, 0.5 all equal, 1 only the others; levels power-normalised), `stack` (Off, Octave, 2 octaves, Fifth, Major chord, Minor chord, Harmonics: intervals cycled across the copies in pitch order), `dest` (Filter 1, Filter 2, Both, Bypass). The layout is `caw/library/unison.hpp`.
    - **`flt1_`, `flt2_` (two filters per voice):** `on`, `type` (Ladder LP/HP/BP 24/12 dB, SVF LP/HP/BP/notch, Comb: peaks at the cutoff and its multiples, Formant: `morph` sweeps A, E, I, O, U and the cutoff over 1 kHz shifts the formants), `cutoff` 20..20000 Hz, `resonance`, `drive` 1..10 (a level-matched tanh before the filter), `keytrack` (0..1 of an octave per octave from C4), `morph` (formant vowel, comb damping), `mix`. `flt_routing`: Series (filter 1 into filter 2; Both feeds filter 1) or Parallel (summed).
    - **`env1_`..`env3_`:** ADSR (`attack`, `decay`, `release` 0.001..10 s, `sustain`); env 1 is the level. **`lfo1_`..`lfo3_`:** `shape` (lfo.hpp's seven), `rate` 0.01..40 Hz, `sync` (Off, 1/32 .. 8 bars: locked to the song's position while it plays), `mode` (Free: one for the instrument; Retrigger: per voice, from each note). **`rnd_`:** `rate`, `mode` (sample and hold or smooth), per voice.
    - **`mod1_`..`mod16_` (the mod matrix; edited in the flagship's device editor, [app](app.md)):** `src` (None, Env 1..3, LFO 1..3, Random, Velocity, Note, Pitch bend (the note's per-note pitch from where it started, over `bend_range`), Pressure, Timbre, Mod wheel (controller 1 when the host sends it)), `dst` (None or any parameter before the slots: value k + 1 is parameter k, labelled by name), `amt` −1..1 and `bipolar` (a source is 0..1; bipolar makes it −1..1). A slot adds amount × source in the destination's knob travel (its curve: an exponential knob moves in octaves), slots on one destination add up, and the result is clamped to the range. Applied every 16 frames per voice; a voice source moves an instrument-wide parameter (below) from the newest voice. Slot 1 starts as env 2 opening filter 1 by 1.5 octaves.
    - **Instrument-wide:** `volume`, `velocity` (how much a soft note is quieter), `bend_range` 1..48 st; **`fx_` (effects, in this order):** distortion (`fx_dist_on`, `_type` Drive/Hard clip/Fold/Crush, `_drive` 1..20, `_mix`), a three-band EQ (`fx_eq_on`, `_low`/`_mid`/`_high` ±18 dB, `_mid_freq` 100..8000 Hz, `_mix`; shelves at 250 Hz and 4 kHz), chorus (`fx_chorus_on`, `_rate`, `_depth`, `_mix`), ping-pong delay (`fx_delay_on`, `_sync` Off or 1/16 .. a bar, `_time` 0.01..4 s, `_feedback` 0..0.95, `_mix`) and reverb (`fx_reverb_on`, off by default: a reverb per track costs about two voices; `_size`, `_decay` 0.1..20 s, `_damping`, `_mix`). An effect switched on starts from silence.
    - The default is a warm, wide saw stack (seven copies 25 ct out, spread 0.8, a ladder at 2.4 kHz opened by env 2). Each block size renders the same bits (the control grid runs on across blocks and restarts at a note-on); with no voice and the effects below −94 dB for 0.1 s (plus the delay time) it clears the effects and says it is quiet. Cost: [performance](performance.md#flagship-synth-2026-11-10).

- **The built-in effects suite (#173, `engine/src/builtin_effects*.cpp`):** twelve stereo effects in original code on the Library's kernels, listed with the other built-ins. They share `fx::EffectBase`: knobs read every 16 frames on a grid that runs across blocks (any block size gives the same bits, tested at 1, 37, 64 and 500 frames), ramps between grid points for gains and mixes, and sleep: after silent input and output (below −110 dB) for their own time (a delay's time, a reverb's pre-delay plus 0.2 s) they clear their state at a grid point and say `quiet()`, and they wake on the first input sample that is not 0, where the grid restarts. Each publishes [display data](#display-data) about 60 times a second. Times, frequencies and rates taper (exponential knobs). Golden hashes: `engine/tests/effects_golden.inc`; costs: [performance](performance.md#effects-suite-2026-11-10).
  - `org.caw.eq` ("EQ"): 8 bands `b1_`..`b8_`, each `on`, `type` (Bell, Low shelf, High shelf, Low cut 12/24/48, High cut 12/24/48, Notch, Band-pass, Tilt), `freq` 20..20000 Hz, `gain` ±24 dB, `q` 0.1..18, `channel` (Stereo, Mid, Side, Left, Right); `output` ±24 dB. Defaults: a 30 Hz low cut and an 18 kHz high cut (off), a 100 Hz low shelf, bells at 250, 800, 2500 and 6000 Hz and a 10 kHz high shelf, all at 0 dB, so the default passes its input bit for bit. Bands are trapezoidal SVF stages (`lib::EqFilter`): minimum phase, zero latency; cuts are Butterworth stages whose last Q follows `q`; a band switched on, off or to another type or channel fades over 5 ms.
  - `org.caw.compressor` ("Compressor"): `threshold` −60..0 dB, `ratio` 1..20, `knee` 0..24 dB (the soft-knee curve of Giannoulis, Massberg and Reiss 2012), `attack` 0.05..200 ms, `release` 5..2000 ms, `auto_release` (0.3× the release after a transient, up to 2× under held compression), `makeup` −12..24 dB, `auto_makeup` (on: adds half the reduction a 0 dBFS signal would get), `mix`, `lookahead` 0..5 ms, `detect` (Peak, RMS over 10 ms), `link` 0..1 (stereo link), `sc_hpf` 20..1000 Hz (the detector's high-pass; 20 is off), `sc_listen`. Latency: a fixed 240 frames (5 ms at 48 kHz), whatever the look-ahead, because a descriptor declares one latency; the look-ahead moves where the detector reads inside that delay. An external sidechain (another track's signal) is not possible yet: a track's chain takes components with one stereo input only (`ComponentChain::build`); that needs a second input port and routing, a follow-up.
  - `org.caw.limiter` ("Limiter"): `gain` 0..24 dB in, `ceiling` −24..0 dB, `release` 1..1000 ms, `lookahead` 0.1..4.9 ms, `true_peak` (a 4× interpolated peak estimate, `lib::TruePeak`). A sliding minimum of the gain each sample needs, an instant-attack release and a moving average as long as the look-ahead, so the gain is down when the peak leaves the 240-frame delay; then a hard clamp at the ceiling, so sample peaks never pass it. Latency 240 frames.
  - `org.caw.reverb.pro` ("Reverb"): the Library's FDN run wet only: `size`, `decay` 0.1..30 s, `predelay` 0..500 ms or `predelay_sync` (Free, 1/64 .. 1/4; up to 1 s), `damping`, `low_cut` 20..2000 Hz and `high_cut` 1..20 kHz on the wet, `width` 0..2, `mod` (line modulation) and `mod_rate` 0.05..5 Hz, `freeze`, `duck` (the input turns the wet down by up to 30 dB × duck: fully at 0 dBFS, not at all below −50 dBFS), `mix`. Tail: infinite (freeze); it sleeps once silent.
  - `org.caw.delay.pro` ("Delay"): `mode` (Stereo, Ping-pong, Dual), `sync` (Free, 1/32, then 1/16 .. 1/2 straight, T triplet and D dotted, 1 and 2 bars) and `time` 1..4000 ms, `sync_r`/`time_r` (the right side in Dual), `offset` ±50 % (the right side's time in Stereo), `feedback` 0..1, `low_cut`, `high_cut` (in the loop, on each echo), `drive` (soft saturation in the loop; 0 is clean), `mod_depth` (up to ±3 ms) and `mod_rate`, `duck`, `freeze` (the loop repeats exactly and takes no input), `mix`. Up to 4 s (a longer division is held there); 4-point Hermite reads; a new time glides over ~50 ms. Tail: infinite.
  - `org.caw.saturator` ("Saturator"): `mode` (Tape: tanh and a 15 kHz roll-off; Tube: asymmetric, even harmonics; Soft clip: cubic; Hard clip; Fold: a sine fold; Crush: `bits` 1..16 and `rate` 200..48000 Hz sample-and-hold), `drive` 0..36 dB, `bias` (asymmetry; its DC is removed), `tone` (a ±9 dB tilt at 1 kHz), `oversample` (Off, 2× by the Library's polyphase IIR half-band: no latency), `auto_gain` (−drive/2 dB), `output`, `mix`.
  - `org.caw.gate` ("Gate"): `threshold`, `range` −80..0 dB, `ratio` 1..50 (an expander below about 4, a gate above), `attack`, `hold`, `release`, `knee`, `sc_hpf`. `org.caw.transient` ("Transient shaper"): `attack` and `sustain` ±1 (up to ±24 dB from two pairs of level followers), `output`, `mix`.
  - `org.caw.filter` ("Filter"): `type` (Low-pass and High-pass 12/24 dB SVF, Band-pass, Notch, Ladder low-, high- and band-pass), `cutoff`, `resonance`, `drive` 0..24 dB, an LFO (`lfo_amount` ±4 octaves at 1, `lfo_rate`, `lfo_sync` Off .. 4 bars, locked to the song while it plays, `lfo_shape` the Library's seven, `lfo_stereo` up to half a cycle between the sides) and an envelope follower (`env_amount` ±4 octaves, `env_attack`, `env_release`), `mix`. `org.caw.phaser` ("Phaser"): `stages` 2..12 first-order all-passes, `rate`, `sync`, `depth` (±3 octaves), `center`, `feedback`, `stereo`, `mix`. `org.caw.flanger` ("Flanger"): `delay` 0.2..10 ms swept from 5 % to 195 % at full `depth`, `rate`, `sync`, `feedback`, `stereo`, `mix`. `org.caw.utility` ("Utility"): `gain` −60..24 dB, `invert_l`, `invert_r`, `channels` (Stereo, Mono, Left, Right, Swap), `width`, `pan` (balance), `bass_mono` with `bass_freq` 40..500 Hz (the side below it removed), `dc_block`.
- **Display data (#173, API version 6):** `caw_engine_component_display(engine, layer_id, index, out, max)` copies the latest floats a playing component published for its UI (addressed as in `caw_engine_set_component_param`; NULL or empty layer id: the master; `CAW_INSTRUMENT_INDEX`: the instrument) and returns the count: 0 when it publishes nothing yet or the engine is busy with a project update (it never waits for the control lock: `try_lock`), −1 when there is no such component. Components publish about 60 times a second through a lock-free double buffer (`caw/display.hpp`, [SDK](native-module-sdk.md#display-data)); reading allocates nothing and never blocks the audio thread (tests `display_test.cpp`, `publishing_and_reading_display_data_never_allocates`). Dart: `Engine.componentDisplay(layerId, index, Float32List)`. Each built-in's layout is under [Display data](#display-data).
- **Component testing:** `caw_component_test(request_json, trust_level, output_dir, input_dir)` renders one C++ effect offline with a test signal and returns its measurements as JSON (see [Component testing](#component-testing)). The host gives a library's trust (the user's own choice for it); a request naming a `trust` is refused. Written WAVs are plain file names inside `output_dir` and a WAV test signal a plain name inside `input_dir` (NULL: none), so a request handed on from project data can't load code or touch files on its own. A test WAV is read only from a regular file of at most 200 MB. The CLI keeps `--trust` and paths, since its user types them. It blocks while it renders, so hosts call it from a worker, never the UI or audio thread.
- **Sample packs:** `caw_sample_pack_render(request_json, trust_level, progress, cancel)` renders an instrument over notes, velocities and parameter steps to named WAV files in one directory and returns the result as JSON (see [Sample packs](#sample-packs)). It blocks while it renders, so hosts call it from a worker, never the UI or audio thread.
- Strings the engine returns are freed with `caw_free`. Only `caw_*` symbols are exported.
- Nothing throws across the API: running out of memory comes back as an error.

### Display data

What each built-in publishes through `caw_engine_component_display`, float by float (levels are peaks since the last publish in dBFS, floored at −120; gain reduction in dB as a positive number; a "now" value is the latest sample's). A built-in not listed publishes nothing. The app decodes these in `app/lib/model/device_display.dart` (`decodeDisplay`).

| Id | Floats | Layout |
|---|---|---|
| `org.caw.eq` | 439 | 0 bins (128), 1 lowest Hz (20), 2 highest Hz (20000), 3 analyzed (1 when a UI read lately and the spectra and curve below are fresh, else they are −120); 4–131 input spectrum dB, 132–259 output spectrum dB (a 2048-point FFT, Hann, 0 dB = a full-scale sine, each bin an equal share of octaves between 20 Hz and 20 kHz, fast rise and slower fall); 260–387 the EQ's computed response dB on the same grid (all bands that are on, whatever their channel, and the output gain); 388–435 the 8 bands × {on, type, freq, gain, q, channel}; 436 output dB, 437 input peak, 438 output peak |
| `org.caw.compressor` | 11 | 0 input peak, 1 output peak, 2 most reduction, 3 reduction now, 4 detector level peak dB, 5 threshold, 6 ratio, 7 knee, 8 makeup dB (with auto), 9 look-ahead ms, 10 sidechain (0: internal) |
| `org.caw.limiter` | 7 | 0 input peak (after `gain`), 1 output peak, 2 most reduction, 3 reduction now, 4 ceiling dB, 5 gain dB, 6 true peak on |
| `org.caw.reverb.pro` | 8 | 0 input peak, 1 wet peak (after filters and ducking), 2 output peak, 3 most ducking dB, 4 decay s, 5 pre-delay s (sync resolved), 6 freeze, 7 size |
| `org.caw.delay.pro` | 9 | 0 input peak, 1 wet peak, 2 output peak, 3 left time s, 4 right time s (gliding), 5 feedback, 6 most ducking dB, 7 freeze, 8 mode |
| `org.caw.saturator` | 73 | 0 input peak, 1 output peak, 2 mode, 3 drive dB, 4 bias, 5 tone, 6 auto gain dB, 7 curve points (65); 8–72 the transfer curve: the output for inputs −1..1 in 65 even steps, before tone, output and mix (0 when nobody watched) |
| `org.caw.gate` | 7 | 0 input peak, 1 output peak, 2 reduction now, 3 most reduction, 4 detector level dB, 5 threshold, 6 open (reduction under 1 dB) |
| `org.caw.transient` | 5 | 0 input peak, 1 output peak, 2 gain change now dB (signed), 3 most boost dB, 4 most cut dB |
| `org.caw.filter` | 73 | 0 input peak, 1 output peak, 2 type, 3 left cutoff Hz (modulated), 4 right cutoff Hz, 5 resonance, 6 LFO (−1..1), 7 envelope (0..1), 8 response points (64); 9–72 the response dB at the left cutoff, 20 Hz..20 kHz on a log grid (analog prototypes; 0 when nobody watched) |
| `org.caw.phaser` | 7 | 0 input peak, 1 output peak, 2 left LFO, 3 right LFO, 4 left frequency Hz, 5 right frequency Hz, 6 stages |
| `org.caw.flanger` | 6 | 0 input peak, 1 output peak, 2 left LFO, 3 right LFO, 4 left delay ms, 5 right delay ms |
| `org.caw.utility` | 6 | 0 input peak, 1 output peak, 2 correlation of the output (−1 out of phase .. 1 mono) since the last publish, 3 gain dB, 4 width, 5 pan |

## The `caw` CLI

```
caw check FILE.caw...
caw render INPUT.caw|INPUT.json -o OUT.wav [--loop | --seconds S | --oneshot LAYER | --wavetable MODULE --param P --frames N]
           [--rate 44100|48000] [--float] [--bpm B --bars N --steps N --pattern FILE]
caw templates
caw docs [--check] [--dir DIR]
caw midi import IN.mid -o OUT.caw | caw midi export PATTERN.caw -o OUT.mid [--clip]
caw test-component ID|LIBRARY [--id ID --trust T] [--signal TYPE ...] [--param NAME=VALUE ...] [--sweep P] [--compare X] [--bypass] [--report json|text] [--strict]
caw sample-pack [INSTRUMENT] --out DIR [--request FILE.json] [--library PATH --trust T] [--effect ID ...] [--notes ...] [--vel ...] [--step NAME=V1,V2 ...] [...]
```

- For a single `.caw` file, `render` builds a one-layer project: `--bpm` and `--bars` set the loop, `--steps` sets the layer's length, and `--pattern FILE` plays it from a pattern's notes. `caw check` checks patterns too.
- It prints frames, length, peak and RMS, and flags `SILENT` or `CLIPPING`, so an agent can check its work without listening.
- `caw docs` writes [library.md](library.md) and [agent-guide.md](agent-guide.md) into `docs/` from the engine's own docs. It fails if a function lacks a description, an argument description or an example, or if an example doesn't compile or is silent. `--check` only compares, and CI runs it, so the notes can't drift from the code.

## Component testing

The testing suite for C++ effects (#163; `engine/src/component_test.*`, measurements in `engine/src/analysis.*`). It loads one component, activates it at a sample rate and block size, feeds it a test signal block by block on the calling thread (no audio device, never the audio thread), and measures the output. Both the C API (`caw_component_test`) and the CLI (`caw test-component`) take the same JSON request and return the same JSON result. Instruments (note input) are not supported yet: a component must have one stereo audio input and one stereo audio output. The request type keeps the signal separate from the harness, so a note sequence can become another signal kind.

**Request** (JSON object; an unknown key is an error, so a typo doesn't silently change the test):

| Key | Default | Meaning |
| --- | --- | --- |
| `component` | required | an id (`"org.caw.distortion"`) or `{"id", "library", "trust", "params": {id: value}}`. A built-in needs only its id. A built library needs `library` (the .so/.dll path) and `trust`: `"trusted"` loads it in-process, `"blocked"` and `"isolated"` are refused as in the Engine; there is no default. Unnamed parameters keep their defaults; values are clamped and stepped as in playback. |
| `signal` | sine | a type name or `{"type", ...}`. Types: `impulse` (one frame), `sine` (`frequency`, default 1000 Hz), `sweep` (exponential, `start_frequency` 20 to `end_frequency` 20000 Hz, held below 0.95 x Nyquist), `white`, `pink` (`seed`, default 1; `decorrelated`: independent left and right), `silence`, `dc`, `wav` (`path`: 16/24/32-bit PCM or 32-bit float, mono or stereo) and `buffer` (`left`, `right` arrays). `seconds` (default 1, at most 120) and `level_db` (dBFS: peak for impulse, sine, sweep and DC, RMS for noise; default 0 for an impulse, -6 otherwise). Signals other than `wav` and `buffer` are the same in both channels unless decorrelated, and are generated with the deterministic maths, so they are the same bits on every device. |
| `sample_rate` | 48000 | 8000 to 192000; a `wav` signal's own rate when left out (a mismatch is an error) |
| `block_size` | 64 | 1 to 8192: the `max_frames` passed to activate and the frames per process call (the last block may be shorter) |
| `tail_seconds` | from the descriptor | silence rendered after the signal: the declared tail and latency plus 0.25 s, or 5 s for an infinite tail; signal and tail together at most 120 s |
| `tempo` | 120 | the transport every block carries (playing, from beat 0) |
| `cpu` | true | time each process call |
| `fft_size` | 8192 | 256 to 65536, power of two, for the spectrum |
| `bands_per_octave` | 6 | resolution of the spectrum and frequency response |
| `compare` | none | a second component (same form as `component`) for a null test. It is loaded in its own registry, so the same id from another library file (another build) works |
| `bypass` | false | also null-test the output against the dry input (A/B against bypass) |
| `align` | `declared` | null-test alignment: `none`, `declared` (each side shifted by its declared latency) or `measured` (by cross-correlation, either side may be later) |
| `sweep` | none | `{"param", "steps", "from", "to"}`: render once more per value, `steps` (1 to 64; default 5, or one per choice of a choice parameter) evenly from `from` to `to` (default: the parameter's range) |
| `write_wav`, `write_input_wav` | none | write the output or the test signal as a 32-bit float stereo WAV, for listening |

**Result** (keys are stable; `schema` is 1). Every result has `ok` and `error`; on failure that is all. A dB value of minus infinity (digital silence) is written as `null`; so is a value that doesn't apply.
- `component`: `id`, `name`, `version`, `role`, `source` (`builtin` or `library`), `latency_frames`, `tail_frames` (a number or `"infinite"`) and `params` (every value used).
- `settings`: `sample_rate`, `block_size`, `tempo`, `signal`, its level and frequencies, `signal_frames` and `render_frames` (signal plus tail).
- `output`:
  - `channels` (left, right): `peak_db`, `rms_db` (dBFS by amplitude: a full-scale sine has RMS -3.01 dB), `dc_offset`, `crest_db` and `gain_db` (output RMS minus input RMS), over the signal's span shifted by the declared latency (an impulse: the whole render); `nan`, `inf` and `denormal` (non-zero subnormal floats) are counted over the whole raw render, before the suite treats non-finite samples as 0 for the other measurements. `failed_blocks` counts process calls that returned false (the input passes through, as in the app).
  - `stereo`: `correlation` (1 identical, 0 unrelated, -1 inverted) and `width` (rms(side) / (rms(mid) + rms(side)): 0 mono, 1 fully out of phase).
  - `thd` (sine only), per channel: `fundamental_db`, `thd_percent`/`thd_db` (harmonics 2 to 10 below Nyquist) and `thd_n_percent`/`thd_n_db` (everything but the fundamental and DC). Measured by a least-squares fit of the known frequency over whole cycles of the steady state (past the declared latency and the signal's first 100 ms or quarter).
  - `impulse_response` (impulse only): `length_frames` and `length_ms`, until the output stays below -90 dB of the input's peak, and `truncated` (still above it at the end of the render).
  - `latency`: `declared`, `measured` (the lag of the largest cross-correlation between input and output, within the first 2^17 frames; `null` for a sine, DC or silence, whose every period matches) and `matches`.
  - `tail`: `declared`, `measured` (frames after the signal ends until the output stays below -90 dB of the input's peak), `measured_ms`, `truncated` and `within_declared` (measured at most declared tail plus declared latency; always true for an infinite tail).
  - `spectrum` (not for silence): `fft_size`, `window` (`hann`), `channel` (`mid`, (L + R) / 2) and `bands`, `[hz, db]` pairs from 20 Hz at `bands_per_octave`, each band's loudest bin, scaled so a full-scale sine on a bin reads 0 dB.
  - `frequency_response` (impulse, sweep and noise): `channel` and `bands`, `[hz, db]` = output power over input power per band, from the FFT of the whole render (first 2^20 frames); bands where the input has less than -60 dB of its loudest band's power are left out. It describes linear, time-invariant effects; for others it is an average.
- `cpu` (with `cpu`): `blocks`, `median_us`, `worst_us`, and both as `median_percent`/`worst_percent` of the block's real-time duration. The only part of a result that varies between runs: with `cpu` off, the same request gives the same JSON byte for byte.
- `bypass` and `compare` (when asked): `align`, `offset_frames` (output frames skipped on the tested side minus the other), `frames` compared, `exact` (every sample equal), `difference_peak_db`, `difference_rms_db` and `depth_db` (difference RMS relative to the tested output's RMS). `compare` also names the other `id`, `source` and `latency_frames`.
- `sweep`: `param` and `points`, each with `value` and the same `output` measurements except spectrum and frequency response, plus its own `warnings`.
- `warnings`: `non_finite`, `denormals`, `clipping` (a sample above 1.0), `failed_blocks`, `latency_mismatch`, `tail_exceeds_declared` and `tail_truncated` (the render ended while a finite tail still sounded).

**CLI:** `caw test-component org.caw.distortion --param drive=8 --report text`, or for a built library `caw test-component ./build/my-echo.so --id local.my-echo --trust trusted --signal impulse`. Options map onto the request (`caw` with no arguments lists them); `--request FILE.json` sends a request file as it is. It prints the JSON result (`--report text`: a few readable lines). It exits 1 when the test fails, and with `--strict` also when the result has warnings, so CI can gate a component on it.

## Sample packs

The sample-pack maker (#164; `engine/src/sample_pack.*`) renders one instrument, optionally followed by a chain of stereo effects, offline on the calling thread (no audio device, never the audio thread) over a grid of notes x velocities x parameter steps, and writes each cell as a WAV file into one output directory, with a manifest and optionally SFZ files. Each cell gets fresh instances, activated at the request's sample rate and block size; the instrument gets a MIDI 2.0 note on at frame 0 (velocity / 127, note id 1), held for `hold_seconds`, then a note off; the render goes on until, after the off and the chain's declared latency, the output has stayed below `tail_threshold_db` for 0.25 s (or `max_seconds` is reached: `tail_truncated`). The file then ends at the last frame above that threshold. Parameters keep one value per file (no smoothing), and the transport is playing at `tempo` from beat 0. The same request gives the same files byte for byte (the manifest records an FNV-1a hash of each).

**Trust and files.** Trust is never read from the request: the caller passes it (`trust_level` in the C API, `--trust` in the CLI) and it applies to every `library` the request names; only `CAW_NATIVE_TRUST_TRUSTED` loads one (blocked and isolated are refused, as in the Engine), and a `"trust"` key anywhere in the request is an error. Built-ins need no trust. Every file is written directly inside `output_dir` (created if missing, then made canonical): names are sanitised to letters, digits and `. _ - # +` (anything else becomes `_`, no `..`, no leading dot, at most 150 characters, Windows device names prefixed with `_`), a target that is a symbolic link or not a regular file is refused, and an existing file is refused unless `overwrite` is true. All names are checked (and must be unique, ignoring case) before anything renders. Each file is written to `NAME.part` and renamed, so a failure never leaves a half-written file; a cancelled or failed pack keeps the files finished before it and writes no manifest. The engine reads no WAV files here.

**Request** (JSON object; an unknown key is an error):

| Key | Default | Meaning |
| --- | --- | --- |
| `instrument` | required | an id (`"org.caw.synth.basic"`) or `{"id", "library", "params": {id: value}}`; it must be an instrument (one event input, one stereo audio output) |
| `effects` | none | up to 16 stereo effects in order, each in the same form |
| `output_dir` | required | the directory every file goes into |
| `name` | `sample` | the pack's name (sanitised): `{name}`, and the manifest `NAME.json` and SFZ `NAME.sfz` |
| `name_pattern` | `{name}_{note}_{vel}_{param}` | tokens `{name}`, `{note}` (C4 = 60, sharps: `F#4`, `C-1`), `{midi}`, `{vel}`, `{param}`, `{index}`; the result is sanitised, repeated underscores collapse and trailing `_`/`-` are dropped (so an empty `{param}` leaves no trace); `.wav` is added |
| `notes` | `[60]` | up to 128 notes, MIDI numbers or names (`"C3"`, `"Bb2"`), or `{"from", "to", "step"}` |
| `velocities` | `[100]` | 1..127, a list or `{"from", "to", "steps"}` (rounded) |
| `params` | none | up to 8 axes: `{"id", "values": [...]}` or `{"id", "from", "to", "steps"}` (at most 128 values), with `"effect": n` for `effects[n]`'s parameter (default: the instrument's). Values are clamped and stepped as in playback. The first axis changes slowest, then notes, then velocities |
| `hold_seconds` | 1 | 0.001..60 |
| `max_seconds` | the larger of 10 and hold + 5 (at most 60) | the longest a file may be |
| `tail_threshold_db` | -80 | where the tail ends |
| `sample_rate`, `block_size`, `tempo` | 48000, 64, 120 | 8000..192000, 1..8192, 20..999 |
| `bit_depth` | 24 | 16 or 24 (PCM, rounded and clipped to full scale, no dither) or 32 (float) |
| `channels` | 2 | 1 writes the mid, (L + R) / 2 |
| `trim` | `{"start": true, "end": true, "threshold_db": -80}` | removes leading and trailing frames where every channel is below the threshold; `false` turns both off |
| `fade_in_ms`, `fade_out_ms` | 0 | linear fades after trimming, kept outside a loop |
| `normalize` | `none` | `"peak"`, `"rms"` or `{"mode", "target_db", "scope"}`: target -1 dBFS for peak, -18 dBFS for RMS (over all samples of all channels); scope `file` (each file its own gain) or `group` (one gain for the pack, set by its loudest file, keeping the files' relative levels; costs a measuring pass). For 16/24-bit the gain is held so the peak stays at or below 0 dBFS (`normalize_limited_by_peak`) |
| `loop` | false | `true` or `{"enabled", "min_seconds": 0.05, "max_seconds": half the hold}`: a forward loop in the held part, as heard after the chain's latency. Its end is the frame before the last rising zero crossing (of the mid) at or before 20 ms (or a tenth of the hold, if less) before the note off; its start is the rising zero crossing, from `max_seconds` before the end to `min_seconds` before it, whose surrounding 64 frames either side best match the end's (both channels; ties keep the longer loop). Written to the `smpl` chunk; `no_loop_found` when there is none |
| `sfz` | false | also write SFZ: one file per parameter combination (`NAME.sfz`, or `NAME_PARAMS.sfz` with axes) |
| `manifest` | true | write `NAME.json` |
| `max_files` | 256 | the grid may be at most this (at most 4096); a larger grid is refused before rendering |
| `overwrite` | false | replace existing files of the same names |

**Each WAV** has `fmt `, `fact` (float), a `smpl` chunk (MIDI unity note = the rendered note, the sample period, and the loop, if any, as start and inclusive end frames) and `data`.

**SFZ** (plain text, basic opcodes only): one `<region>` per file with `sample=` (the file name, in the same directory), `lokey`/`hikey` (each sampled note covers the keys halfway to its neighbours; the lowest from 0, the highest to 127), `pitch_keycenter`, `lovel`/`hivel` (each velocity layer from the one below it, exclusive, up to its own velocity; the lowest from 1, the highest to 127), and `loop_mode=loop_continuous loop_start= loop_end=` or `loop_mode=no_loop`.

**Result and manifest.** The result has `ok` and `error` (on failure that is all), `output_dir` (canonical) and everything the manifest holds; the manifest has no absolute paths, so a pack can be moved: `schema` (1), `name`, `instrument` and `effects` (`id`, `source` builtin or library), `settings`, `file_count`, `files` (each: `file`, `note`, `note_name`, `velocity`, `params` {id: value used}, `param_effects` (`"instrument"` or an effect index, per axis), `frames`, `seconds`, `trimmed_start_frames`, `peak_db`, `rms_db`, `gain_db`, `loop` (`start`, `end`, `match_db`: the seam's difference energy relative to the signal, lower is better) or null, `tail_truncated`, `hash` and `warnings`), `sfz` (file names), `manifest` and `warnings` (`tail_truncated`, `failed_blocks`, `no_loop_found`, `silent`, `normalize_limited_by_peak`, `clipped`, `over_full_scale`). A dB of digital silence is `null`.

**CLI:** `caw sample-pack org.caw.synth.basic --out pack --name lead --notes C2:C5:12 --vel 64,127 --step cutoff=600,3000 --set release=0.4 --loop --sfz --normalize peak --group --bits 16`. `--request FILE.json` reads a request; the options override its keys. `--library PATH` takes the instrument from a built library and `--trust trusted|isolated|blocked` (default blocked) is the trust passed for every library; `--effect ID` (repeatable) adds built-in effects (library effects go in a request file). `caw` with no arguments lists every option. It prints the result JSON and exits 1 when the pack fails.

**[Fact] Limits, as built:** a loop is found only where the held sound repeats: a detuned two-oscillator patch that beats slower than the hold gets a loop whose seam does not match well (`match_db` about -25 to -28 dB for `org.caw.synth.basic` at its default 7-cent detune, against below -80 dB with one sine oscillator), and nothing crossfades the seam. Notes are whole MIDI numbers.

## Tests

`engine/build/caw_tests` runs 370 tests and `engine/build/caw_rt_tests` 77 more (CTest runs both):
- **Language:** JavaScript semantics, the defined edge cases, built-ins, params, error messages and limits.
- **Variables:** functions, rich params, globals, exports across layers in either order, exports inside a chain, missing sources, and cycles.
- **Library:** envelopes, LFOs, the music helpers (NaN arguments included), delay, effects and glitch tools, effect buffers starting silent on every loop, project libraries and name clashes, borrowed tips, the function-call and project memory budgets, and that every function is documented with an example that plays.
- **MIDI files:** round trips of the templates through `.mid` and `.midi2`, chords, fractions, microtones, exact clip and SMF bytes, hand-built files with running status and tempo changes, and thousands of truncated or corrupted files that must give errors without crashing.
- **Patterns:** the note format and its errors, sample-exact note starts and ends, chords and voice stealing without clicks, the note variables, ratchets, slides, repeatable probability, pattern length, byte-mode pitch, the engine's release fade, notes released by seed and tempo changes, packed patterns, late-note warnings, pattern edits carrying sounding notes onto their new curve (or ending deleted ones) and the note matcher, code edits keeping held notes, the default note without a pattern, and exports checking patterns.
- **Mixer:** (runs through the Engine's mix graph since F4.3) block-size independence, a track removed from inside a folder fading out (issue #76), layer lengths, seams, hot swap (calls keeping their state, swaps waiting for the bar), broken code, mute, solo and pan, overload, stop and removal, effects, params and the limiter.
- **Exports:** loop lengths, export equal to playback, free-length renders and cancel, one-shots, wavetables, broken modules and WAV bytes.
- **Modules and graph:** descriptor validation (layouts, the 64-channel port ceiling, identity version, role, choice parameters), the CP.2 capability flags (the executor refuses a modulation link, automation lane or CC mapping a parameter does not allow), the processor contract and its stereo adapter, graph compile errors and budgets, and the planar N-channel executor: distinct generated signals per channel for mono, stereo, quad, 5.1, 7.1 and Discrete(3), channel isolation, fan-in summing order (summing inputs), typed ports (sidechain, modulation, control, and event merge order, overflow and order checks), parameters (resolution, modulation links, automation lanes against the Engine's lane values, MIDI CC mappings), audio-thread re-routing (`setRouting`: validation, rejection keeps the old routing, unlisted nodes skipped, no allocation), host channel-count mismatches, processor failure reporting, re-prepare/reset, runtime publication, and no allocation or free in `process()`. These real-time tests are in `caw_rt_tests`, whose `engine/tests/alloc_counter.cpp` replaces the global `operator new`/`delete` to count calls; keeping it out of `caw_tests` keeps AddressSanitizer's new/delete mismatch checks there.
- **Flagship synth:** `flagship_test.cpp`: the unison layout (detune curve, mirror pans, blend levels, stacks), the comb, formant, multimode ladder and EQ kernels on noise, `Wavetable::levelData`, the descriptors (sections, curves, the matrix's destination list), unison pitches against the detune and its power, spread 0 exactly mono and wider at 1, each stack's intervals, each filter type on a saw (and series, parallel, bypass), the matrix moving a level, a pan and a cutoff, the same bits at blocks of 64, 128, 512 and 37 with every part on, finite output and silence after release (quiet), a bend, and a note above Nyquist staying silent; its golden render, perceptual reference and timing tests are with the other built-ins'.
- **Instruments:** `builtin_instruments_test.cpp`: the Library's oscillators, filters, envelopes, glide and drum voices, every built-in instrument listed with its name, starting on its frame and falling silent, the hats' open, closed and choke, the kit's key map, the mono synths' glide and legato, the morph synth's stereo spread and a golden render each; `instrument_test.cpp`: the project fields, the UMP note encoding, the bounded note list, notes reaching a recording fixture instrument on their exact frames across loop wraps and clip loops, slides, previews (ids, glides, notes off), Stop and Play, values, bypass and lanes, state, a rebuild taking over held notes, .caw effects after an instrument, wrong-shaped components refused, the built-in synth starting a note mid-block and its golden render, a bent note playing as loud as a plain one in live playback on the built-in synths, a sounding bent note following a pattern edit (a moved curve point; a moved, transposed and shortened note; a deleted note and one moved off the playhead ending) on the recorder, Morph and Flagship, and the C API; `engine_rt_test.cpp` plays, swaps, previews and stops instruments, the built-in ones included, and edits a pattern under sounding bent notes, without an allocation.
- **Native SDK:** compiled components cross the plain-C interface v3 in `engine/include/caw_component.h` (installed with the SDK; `tests/component_header_check.c` compiles it as C99); `CAW_EXPORT_COMPONENT` in `engine/include/caw/component.hpp` builds it from a C++ `ModuleProcessor`. The C++ contract is `engine/include/caw/module.hpp`, exposed through the installable `CAW::SDK` package, which also checks with `static_assert` that its enums and event record match the C ones. `ModuleRegistry` and the Engine C API load explicit-trust shared libraries on Windows and POSIX through that one entry point, copy and validate the descriptor and stable ID, refuse a library without it (`MissingEntryPoint`), another interface version (`IncompatibleAbi`) or a missing function (`IncompleteTable`), and keep the library loaded while instances live. Tests: a fixture component, and a second build of it without the entry point. With `-DCAW_CLAP=ON`, `caw_clap_tests` (8 tests) loads the exported `.clap` plug-ins as a CLAP host and checks the factory, descriptors, ports, parameters (info, text, flush, sample-accurate changes and smoothing), state round trips, notes and MIDI in and out, the transport and zero allocations in process, against the same components run through `ModuleRegistry`, sample for sample.
- **Mixer golden renders:** eight multi-track projects in `engine/tests/mix_golden_test.cpp` (pan, a folder bus, nested folders, mute and solo together and each alone, folder and track automation, the limiter driven through a bus and shown to engage), rendered in uneven blocks and hashed over float bits. They hold routing changes, such as moving the mixer into the graph, to bit-exact output. A companion test shows a muted or non-soloed track contributes exactly nothing: the mix equals the same project without it.
- **Component testing:** every measurement against known signals (a sine's level, crest and THD near zero, a known 1 % + 0.5 % harmonic mix, FFT bins and the Hann scaling, IR end and cross-correlation lag), the signals (levels, seeded noise, decorrelation), the fixture's echo IR length (3,361 frames) and denormals, its 100-frame delay measured against the declared latency with every broadband signal, exact nulls of identical components and of two loads of one library, gain changes in dB, parameter sweeps, the built-in effects at an odd block size with every signal, a tail longer than declared, refusals (no trust, blocked, unknown keys and parameters), a WAV round trip, the C API, and the same JSON for the same request.
- **Sample packs:** note names both ways, the sanitiser (separators, `..`, leading dots, device names, length) and name patterns, trim, fades, a loop on whole cycles of a sine, the `smpl` chunk and samples read back at 16, 24 and 32 bits, SFZ key and velocity ranges, a real pack of `org.caw.synth.basic` (8 files, non-silent, looped, group peak, the same bytes in another directory and with `overwrite`), effects with an effect-parameter axis, mono float and RMS normalisation, refusals (a library without trust, a `trust` key, unknown parameters and keys, not an instrument, `max_files`, clashing names, an existing file, a symlinked target), names that try to leave the directory, and the C API's trust, progress and cancel.
- **Golden renders:** one hash per template in `engine/tests/golden.txt`. A hash changes only with an intended sound change; then run `caw_tests --update-golden` and say why in the commit.

The suite passes under GCC 13, Clang 18, and GCC with AddressSanitizer and UBSan (`-DCAW_SANITIZE=ON`). GCC and Clang give identical golden hashes.
