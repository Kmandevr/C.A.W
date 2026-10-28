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
| `engine/src/` | The portable core: `compile` (header, lexer, parser, code generation), `vm`, `builtins`, `detmath`, `engine` (mixer), `project`, `render` (exports), `wav`, `json`, `capi` |
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
kind: generator      # generator (makes sound) or effect (changes `in`)
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
- `param name = default in min..max` declares a slider. The app shows one per param, and the value is fixed for a whole block. Without `in`, the range is 0–1 if the default is in it, and otherwise 0 to twice the default.
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

### Built-ins

- **Maths:** `sin cos tan abs floor ceil round trunc sqrt exp log tanh sign fract min max pow clamp(x,lo,hi) mix(a,b,x) mtof(note)`. `log` and `sqrt` of values ≤ 0 give 0.
- **Bits:** `rotl(x,n) rotr(x,n) popcount clz ctz bitrev bswap`, `bits(x)` (the bits of a 32-bit float as an integer) and `float(i)` (the reverse).
- **Seeded randomness:** `hash(x)` scrambles x into a 32-bit number. `noise()` is white noise from `t`, and `noise(x)` is noise from x. Both change with the project seed, never with the clock.
- **Oscillators:** `sine(freq) saw(freq) square(freq, width=0.5) tri(freq)`. Saw and square are band-limited (PolyBLEP).
- **Envelope:** `ad(trigger, attack=0.005, decay=0.3)` starts each time `trigger` rises above 0. The attack is linear and the decay reaches −60 dB after `decay` seconds.
- **Filter:** `lpf(x, cutoff, q=0.707)`, `hpf`, `bpf`: a state-variable filter.

Each call to an oscillator, `ad`, a filter or `noise` has its own state. The state returns to its start at every loop start, so every loop repeats exactly.

### Output

- **Byte mode:** keeps the low 8 bits (`v & 255`) and maps them to −1…1. This is classic bytebeat.
- **Float mode:** the value is the sample, clamped to −1…1, with NaN and infinity turned into 0.

### Limits (the sandbox)

The language has no I/O, loops or recursion, so a program's cost is fixed when it compiles. A module may not exceed:
- 64 KB of source
- nesting 128 deep
- 1024 values (registers)
- 32 params
- 8192 numbers of oscillator, envelope and filter state

Errors give a line and column, counting the header lines, for example `line 5, col 5: unknown name 'nope'`.

## Playback

- **Project:** BPM, beats per bar, loop length in bars, seed and master volume. The project loop is `round(steps × 60 × sr / (bpm × 4))` samples, and every layer restarts when it wraps.
- **Layers:** up to 64. Each layer is a generator followed by up to 8 effects. A layer loops at its own length in 16ths; 0 means it follows the project loop. Each loop start falls at `round(k × length)`, so a 3-bar layer against a 4-bar loop stays in time.
- **Seams:** when a layer restarts, the end of its previous pass crossfades into the new one over 3 ms. This can be turned off per project with `seam_crossfade`.
- **Hot swap:** changed code replaces the old program with a 20 ms crossfade, without stopping. Code that fails to compile reports an error and leaves the old program playing.
- **Mix:** each layer has volume, constant-power pan, mute and solo, smoothed over 5 ms. The master chain is master volume, then a 5 Hz DC blocker, then a safety limiter with a ceiling of −0.2 dBFS, always last.
- **Overload:** the host reports how much of each audio callback was used. If the average stays above 85% for 20 callbacks, the engine mutes the newest audible layer, flags it in the meters and waits 100 callbacks before it would mute another. Clearing the overload unmutes them.
- **Threads:** the control thread compiles code and sends messages to the audio thread through a lock-free queue. The audio thread hands retired programs back the same way, so it never allocates, locks or frees. Parameter and mix values are atomics.
- **Determinism:**
  - The output doesn't depend on the device's buffer size.
  - The engine builds with `-ffp-contract=off` (MSVC `/fp:precise`, which never contracts).
  - It uses its own `sin`, `exp` and `log`, so every platform gives the same bits.

## Project file (JSON)

The app, the CLI and exports share one format:

```json
{ "caw_project": 1, "name": "Night Glitch", "bpm": 140, "beats_per_bar": 4, "loop_bars": 4,
  "seed": 7, "master": 0.7, "seam_crossfade": true,
  "modules": [ { "id": "m1", "source": "...the .caw text...", "params": { "shift": 6 } } ],
  "layers": [ { "id": "l1", "name": "Byte lead", "chain": ["m1", "fx1"], "length_steps": 48,
                "volume": 0.8, "pan": 0, "mute": false, "solo": false } ],
  "audition": { "chain": ["m1"], "length_steps": 0 }, "audition_only": false }
```

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

- **Checking a module:** `caw_check(source)` returns JSON with ok, error, line, col, kind and params.
- **Engine:** `caw_engine_create(sample_rate)` creates one. `caw_engine_set_project(json)` returns per-module results. Live controls: `caw_engine_set_param`, `caw_engine_set_layer_mix`, `caw_engine_play`, `caw_engine_stop`, `caw_engine_clear_overload`.
- **Meters:** `caw_engine_meters`, `caw_engine_layer_meter` and `caw_engine_scope` (1024 samples per layer, for the audition at index 64, or for the master at −1).
- **Hosts and devices:** `caw_engine_process(left, right, frames)` lets hosts such as a plugin drive the audio. `caw_audio_start` and `caw_audio_stop` open the device through miniaudio: AAudio or OpenSL ES on Android, WASAPI on Windows, Core Audio, and ALSA or PulseAudio.
- **Exports:** `caw_render(project_json, options, path, progress, cancel, …)` writes a WAV. Progress counts 0–1000, and a non-zero cancel stops it.
- **Templates:** `caw_template_count`, `caw_template_file` and `caw_template_source`.
- Strings the engine returns are freed with `caw_free`. Only `caw_*` symbols are exported.

## The `caw` CLI

```
caw check FILE.caw...
caw render INPUT.caw|INPUT.json -o OUT.wav [--loop | --seconds S | --oneshot LAYER | --wavetable MODULE --param P --frames N]
           [--rate 44100|48000] [--float] [--bpm B --bars N --steps N]
caw templates
```

- For a single `.caw` file, `render` builds a one-layer project: `--bpm` and `--bars` set the loop, and `--steps` sets the layer's length.
- It prints frames, length, peak and RMS, and flags `SILENT` or `CLIPPING`, so an agent can check its work without listening.

## Tests

`engine/build/caw_tests` runs 32 tests:
- **Language:** JavaScript semantics, the defined edge cases, built-ins, params, error messages and limits.
- **Mixer:** block-size independence, layer lengths, seams, hot swap, broken code, mute, solo and pan, overload, stop and removal, effects, params and the limiter.
- **Exports:** loop lengths, export equal to playback, free-length renders and cancel, one-shots, wavetables, broken modules and WAV bytes.
- **Golden renders:** one hash per template in `engine/tests/golden.txt`. A hash changes only with an intended sound change; then run `caw_tests --update-golden` and say why in the commit.

The suite passes under GCC 13, Clang 18, and GCC with AddressSanitizer and UBSan (`-DCAW_SANITIZE=ON`). GCC and Clang give identical golden hashes.
