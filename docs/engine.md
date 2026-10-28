---
title: Engine and language reference
summary: What the built C++ engine does: the module language, playback of layers, the project file, exports, the C API, the caw CLI and the tests.
covers: [engine/, examples/]
updated: 2026-10-28
---

# Engine and language reference

The engine in `engine/` as built. The reasons behind it are in [architecture](architecture.md), and the version plan is in [roadmap](roadmap.md). All of it is **[Fact]**: it is checked by `engine/tests/`.

## Layout

| Path | What it is |
| --- | --- |
| `engine/src/` | The portable core: `compile` (header, lexer, parser, code generation), `vm`, `builtins`, `detmath`, `engine` (mixer), `project`, `render` (exports), `docs` (generated reference), `wav`, `json`, `capi` |
| `engine/lib/` | The built-in libraries, written in the module language (`drum`, `synth`, `util`). CMake builds them into the engine |
| `engine/include/caw.h` | The C API, version 1 |
| `engine/platform/` | Audio output through miniaudio, and a stand-in for builds without a device |
| `engine/cli/` | The `caw` tool |
| `engine/tests/` | Unit tests and golden renders (`golden.txt`) |
| `engine/third_party/miniaudio/` | miniaudio 0.11.25 (2026-03-04), unmodified, public domain or MIT-0 |
| `examples/` | Starter modules. CMake builds them into the engine, and the app offers them as templates |

Build and test (Linux or macOS, CMake 3.22+ and a C++20 compiler):

```
cmake -S engine -B engine/build -G Ninja -DCMAKE_BUILD_TYPE=Release
cmake --build engine/build && engine/build/caw_tests
```

## Module files (`.caw`)

A module is one text file: an optional header between `---` lines, then code.

```
---
caw: 1               # module format version (only 1 exists)
kind: generator      # generator (makes sound), effect (changes `in`) or library (functions only)
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
- `param name = default in min..max` declares a slider. The app shows one per param, and the value is fixed for a whole block. Without `in`, the range is 0–1 if the default is in it, and otherwise 0 to twice the default. Options can come in any order after the default:
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
| `pi` | π |

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
- 32 params and globals
- 16 exports and 32 imports
- functions nested 32 calls deep, and 4096 function calls expanded in all (each call is copied in place, so nested calls multiply)
- 1,048,576 numbers (8 MB) of state for oscillators, envelopes, filters, delays and reverbs
- across the whole project, 64 MB of such state (each module also keeps a copy for seams). A layer that would pass it stays silent, with a warning

Errors give a line and column, counting the header lines, for example `line 5, col 5: unknown name 'nope'`.

## Playback

- **Project:** BPM, beats per bar, loop length in bars, seed and master volume. The project loop is `round(steps × 60 × sr / (bpm × 4))` samples, and every layer restarts when it wraps.
- **Layers:** up to 64. Each layer is a generator followed by up to 8 effects. A layer loops at its own length in 16ths; 0 means it follows the project loop. Each loop start falls at `round(k × length)`, so a 3-bar layer against a 4-bar loop stays in time.
- **Seams:** when a layer restarts, the end of its previous pass crossfades into the new one over 3 ms. This can be turned off per project with `seam_crossfade`.
- **Hot swap:** changed code replaces the old program with a 20 ms crossfade, without stopping. Code that fails to compile reports an error and leaves the old program playing.
- **Mix:** each layer has volume, constant-power pan, mute and solo, smoothed over 5 ms. The master chain is master volume, then a 5 Hz DC blocker, then a safety limiter with a ceiling of −0.2 dBFS, always last.
- **Overload:** the host reports how much of each audio callback was used. If the average stays above 85% for 20 callbacks, the engine mutes the newest audible layer, flags it in the meters and waits 100 callbacks before it would mute another. Clearing the overload unmutes them.
- **Threads:** the control thread compiles code and sends messages to the audio thread through a lock-free queue. The audio thread hands retired programs back the same way, so it never allocates, locks or frees. Parameter and mix values are atomics.
- **Globals and exports:**
  - A global's value comes from the project's `globals` (or its default), and changes take effect without recompiling.
  - Each layer has 16 export buffers. They're filled while its chain runs, so they're also ready for the effects later in that chain.
- **Determinism:**
  - The output doesn't depend on the device's buffer size.
  - The engine builds with `-ffp-contract=off` (MSVC `/fp:precise`, which never contracts).
  - It uses its own `sin`, `exp` and `log`, so every platform gives the same bits.

## Project file (JSON)

The app, the CLI and exports share one format:

```json
{ "caw_project": 1, "name": "Night Glitch", "bpm": 140, "beats_per_bar": 4, "loop_bars": 4,
  "seed": 7, "master": 0.7, "seam_crossfade": true, "key_root": 9, "key_scale": 1, "globals": { "swing": 0.1 },
  "modules": [ { "id": "m1", "name": "Kick", "source": "...the .caw text...", "params": { "shift": 6 } } ],
  "layers": [ { "id": "l1", "name": "Byte lead", "chain": ["m1", "fx1"], "length_steps": 48,
                "volume": 0.8, "pan": 0, "mute": false, "solo": false } ],
  "audition": { "chain": ["m1"], "length_steps": 0 }, "audition_only": false }
```

- A module's `name` is what `module.export` uses; without it, the header's `name:` is used.
- `key_root` is 0–11 from C and `key_scale` is a `scale.*` index (0 major, 1 minor); they default to A minor.
- `audition` is the Builder's preview. With `audition_only`, only that chain is heard.
- Values outside their range are clamped:
  - BPM 20–400
  - 1–64 bars
  - 64 layers
- Fields the app adds for itself, such as colours, are ignored.

## Exports

| Kind | What it renders |
| --- | --- |
| Loop | One exact project loop. The engine renders two loops and keeps the second, so the file starts with the seam crossfades it has when it repeats. Includes a `smpl` loop chunk over the whole file. Bit-identical to the second loop of live playback |
| Free | Any length from 0.1 to 600 seconds, from the start |
| One-shot | One pass of one layer (its own length, or the project loop if it follows it), at most 30 s. The end is trimmed to 5 ms after the last sound above −80 dB |
| Wavetable | 1–256 frames of 2048 samples from one module, sweeping one param from its min to its max. In a frame, `t` runs 0–2047, `phase` 0–1 and `sr` is 2048, so `sine(1)` is one cycle. Each frame's DC is removed, and the table is normalized to peak 1. Written as 32-bit float mono |

- Files are WAV at 44.1 or 48 kHz, as 24-bit PCM or 32-bit float.
- An export refuses to run if any module it uses fails to compile.
- **[Assumption]** Serum may want an extra `clm ` chunk to recognise 2048-sample frames. This isn't written yet; check before relying on Serum.

## C API (`engine/include/caw.h`)

- **Checking a module:** `caw_check(source)` returns JSON: ok, error, line, col, kind, mode, name, summary, and:
  - `params`: each with name, default, min, max, step, kind (`number`, `toggle` or `choice`), choices, tip, header, doc and global
  - `exports` (name and doc), `imports`, and `functions` (name, args and doc)
- **Engine:** `caw_engine_create(sample_rate)` creates one.
  - `caw_engine_set_project(json)` returns the same description per module, plus `ref` (its name for exports) and `warnings`.
  - Live controls: `caw_engine_set_param`, `caw_engine_set_global`, `caw_engine_set_layer_mix`, `caw_engine_play`, `caw_engine_stop`, `caw_engine_clear_overload`.
- **Meters:** `caw_engine_meters`, `caw_engine_layer_meter` and `caw_engine_scope` (1024 samples per layer, for the audition at index 64, or for the master at −1).
- **Hosts and devices:** `caw_engine_process(left, right, frames)` lets hosts such as a plugin drive the audio. `caw_audio_start` and `caw_audio_stop` open the device through miniaudio: AAudio or OpenSL ES on Android, WASAPI on Windows, Core Audio, and ALSA or PulseAudio.
- **Exports:** `caw_render(project_json, options, path, progress, cancel, …)` writes a WAV. Progress counts 0–1000, and a non-zero cancel stops it.
- **Templates:** `caw_template_count`, `caw_template_file` and `caw_template_source`.
- **Function library:** `caw_library()` returns JSON: `functions` (name, category, signature, doc, example and args with name, doc and optional) and `constants`. The app's Library sheet reads it.
- Strings the engine returns are freed with `caw_free`. Only `caw_*` symbols are exported.
- Nothing throws across the API: running out of memory comes back as an error.

## The `caw` CLI

```
caw check FILE.caw...
caw render INPUT.caw|INPUT.json -o OUT.wav [--loop | --seconds S | --oneshot LAYER | --wavetable MODULE --param P --frames N]
           [--rate 44100|48000] [--float] [--bpm B --bars N --steps N]
caw templates
caw docs [--check] [--dir DIR]
```

- For a single `.caw` file, `render` builds a one-layer project: `--bpm` and `--bars` set the loop, and `--steps` sets the layer's length.
- It prints frames, length, peak and RMS, and flags `SILENT` or `CLIPPING`, so an agent can check its work without listening.
- `caw docs` writes [library.md](library.md) and [agent-guide.md](agent-guide.md) into `docs/` from the engine's own docs. It fails if a function lacks a description, an argument description or an example, or if an example doesn't compile or is silent. `--check` only compares, and CI runs it, so the notes can't drift from the code.

## Tests

`engine/build/caw_tests` runs 51 tests:
- **Language:** JavaScript semantics, the defined edge cases, built-ins, params, error messages and limits.
- **Variables:** functions, rich params, globals, exports across layers in either order, exports inside a chain, missing sources, and cycles.
- **Library:** envelopes, LFOs, the music helpers (NaN arguments included), delay, effects and glitch tools, effect buffers starting silent on every loop, project libraries and name clashes, borrowed tips, the function-call and project memory budgets, and that every function is documented with an example that plays.
- **Mixer:** block-size independence, layer lengths, seams, hot swap, broken code, mute, solo and pan, overload, stop and removal, effects, params and the limiter.
- **Exports:** loop lengths, export equal to playback, free-length renders and cancel, one-shots, wavetables, broken modules and WAV bytes.
- **Golden renders:** one hash per template in `engine/tests/golden.txt`. A hash changes only with an intended sound change; then run `caw_tests --update-golden` and say why in the commit.

The suite passes under GCC 13, Clang 18, and GCC with AddressSanitizer and UBSan (`-DCAW_SANITIZE=ON`). GCC and Clang give identical golden hashes.
