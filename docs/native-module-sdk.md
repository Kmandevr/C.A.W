---
title: Native module SDK
summary: C ABI host contract and C++ component SDK, validation, real-time rules, state and packaging.
updated: 2026-11-10
covers: [engine/include/caw_component.h, engine/include/caw/library/, engine/src/sample_pack.*, engine/plugin/clap/, engine/cmake/CAWClap.cmake, engine/include/caw/module.hpp, engine/include/caw/component.hpp, engine/include/caw/instrument.hpp, engine/CMakeLists.txt, engine/cmake/, examples/cpp/minimal/, examples/cpp/poly-synth/, scripts/caw-component-build.js, .github/workflows/cpp-components.yml, engine/src/module.*, engine/src/module_registry.*, engine/src/graph.*, engine/src/component_test.*, engine/src/analysis.*]
---

# Native module SDK v1

**Status [Fact, checked 2026-11-09]:**
- **Interface and SDK:** the plain-C component interface v3 and the installable C++ SDK (`CAW::SDK`) exist.
- **Desktop build:** a manifest-driven CMake build, and CI for Linux, Windows and Android.
- **In-app compiler:** `engine/compiler/` is built for Android by CI, and in CI it compiles real components to arm64 libraries; its first run on a phone is still to come.
- **Loading:** explicit trust (Blocked / Trusted; Isolated is refused, since there is no sandbox), and rebuilds that switch in while playing.
- **Playback:** stereo effects with parameters, automation, bypass, state, tails and latency compensation, on tracks and the master; instruments (an event input, a stereo output) playing a track's notes, with the same (2026-11-10, #156).
- **Testing:** an offline testing suite measures an effect (levels, THD+N, impulse response, latency and tail against the declared values, null tests, parameter sweeps, CPU per block) from the C API or `caw test-component`; instruments are not covered yet.
- **CLAP export (2026-11-10):** a component library also builds as a `.clap` plug-in for Linux and Windows hosts ("Export as a CLAP plug-in" below).
- **Still to come:** the UI, process isolation, signing, components with other ports, VST3 export and an in-app Export button.

## Writing an effect

A component is ordinary C++20 against `caw/component.hpp`. A new effect starts from the blank template (`CppComponentDoc.blankEffect`): a stereo pass-through with its `caw-component.json`. The parts:

```cpp
#include <algorithm>
#include <vector>

#include <caw/component.hpp>

namespace {
constexpr caw::PortDescriptor kPorts[] = {caw::stereoInput("in"), caw::stereoOutput("out")};

caw::ParameterDescriptor time() {                 // a knob: id, range, default, smoothing
    caw::ParameterDescriptor p;
    p.id = "time"; p.name = "Time"; p.unit = "ms";
    p.minimum = 1; p.maximum = 1000; p.defaultValue = 250;
    p.smoothingFrames = 480;                      // moves glide over 10 ms instead of clicking
    return p;
}
const caw::ParameterDescriptor kParams[] = {time()};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "local.my-echo"; d.name = "My echo"; d.role = caw::ModuleRole::Effect;
    d.ports = kPorts; d.portCount = 2; d.parameters = kParams; d.parameterCount = 1;
    d.tailFrames = caw::kInfiniteTail;            // it rings on after the input stops
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

class Echo final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {  // allocate here, never in process()
        rate_ = rate;
        try { line_.assign(static_cast<size_t>(rate), 0.0f); } catch (...) { return false; }
        return true;
    }
    void reset() noexcept override { std::fill(line_.begin(), line_.end(), 0.0f); }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < b.frames; ++i) {
            // A parameter is per frame while it moves (samples), otherwise one value for the block.
            const double ms = b.parameters[0].samples ? b.parameters[0].samples[i] : b.parameters[0].value;
            // b.transport (null while stopped) gives tempo and the song position, for tempo-synced effects.
            const size_t delay = static_cast<size_t>(ms * rate_ / 1000.0);
            const size_t read = (pos_ + line_.size() - delay) % line_.size();
            for (uint32_t c = 0; c < 2; ++c) b.output.channels[c][i] = b.input.channels[c][i] + 0.5f * line_[read];
            line_[pos_] = 0.5f * (b.input.channels[0][i] + b.input.channels[1][i]);
            pos_ = (pos_ + 1) % line_.size();
        }
        return true;
    }
private:
    std::vector<float> line_;
    size_t pos_ = 0;
    double rate_ = 48000;
};
}  // namespace

CAW_EXPORT_COMPONENT(Echo, kDescriptor)
```

The rules that matter:
- **Allocate in `activate`, never in `process`.** No locks, file access or logging there either.
- **Declare what the host must know:**
  - `latencyFrames`, so other tracks are delayed to match;
  - `tailFrames`, so the effect rings out after Stop;
  - `maxStateBytes`, together with `saveState`/`loadState` if it keeps state beyond its parameters.
- **Make `saveState` safe while `process` runs:** the host may save a playing project.
- **Make `reset()` clear what you hold.** The host calls it so the next play starts from silence.
- **Say when you are silent, and the host stops calling you.** Override `bool quiet() const noexcept` to return true, right after a `process`, when your output from then on is silence until an event arrives or your input is not silent (an instrument with no voice sounding, an effect whose tail has died out). The host then skips you, so a silent track costs nearly nothing; your time does not move meanwhile, so restart anything timed (a control grid, an LFO you care about) at the next note. `CAW_EXPORT_COMPONENT` offers it through the C interface's `caw.quiet.v1` extension (`CawQuietExtension`), and the CLAP export reports it as `CLAP_PROCESS_SLEEP`. Without it, the host still skips you once your input has been silent for longer than the `tailFrames` you declare (when that is more than 0 and finite) and your output is all zeros, so an honest tail is enough.
- **Use the Library for the same sound everywhere:** `caw/library/` ([below](#the-library)) and `caw/detmath.hpp` give the same bits on every device.

## Testing your effect

The testing suite renders your effect offline, with no audio device, and reports what it measured as JSON ([engine reference](engine.md#component-testing) for every key). From the command line, after building:

```
caw test-component ./build/my-echo.so --id local.my-echo --trust trusted --signal impulse --report text
caw test-component ./build/my-echo.so --id local.my-echo --trust trusted --signal sine --freq 1000 --param time=250
caw test-component ./build/my-echo.so --id local.my-echo --trust trusted --sweep time --steps 5
caw test-component ./build/my-echo-v2.so --id local.my-echo --trust trusted --compare ./build/my-echo.so --signal pink
```

A library is in-process code, so it loads only with an explicit `--trust trusted`, as in the app. Hosts call `caw_component_test(request_json, trust_level, output_dir, input_dir)` with the same request: the host gives the trust and the folders, never the request. What it catches:
- **Wrong declarations:** the measured latency against `latencyFrames` (an impulse, sweep or noise shows it), and the measured tail (until -90 dB) against `tailFrames`. A mismatch is a warning: the host compensates and rings out by what you declare.
- **Bad samples:** NaN, Inf and denormals in the raw output, clipping above 0 dBFS, and blocks where `process` returned false.
- **Sound:** peak, RMS, DC, crest factor and gain per channel; THD and THD+N for a sine; impulse-response length; frequency response from an impulse, sweep or noise; a spectrum; stereo correlation and width.
- **Changes:** a null test against another component or another build (`--compare`, aligned by declared or measured latency) or against the dry input (`--bypass`): `exact` is true only when every sample matches. A refactor that should not change the sound must null exactly.
- **Cost:** median and worst time per block, in µs and as a share of the block's real time on the machine that runs the test (a desktop CPU is not a phone's).

Run it at the block sizes and sample rates the app uses (`--block`, `--rate`); a result without `cpu` is the same byte for byte on every run, so it can be checked into a test. `--strict` exits 1 on any warning, for CI.

## Writing an instrument

An instrument plays a track's notes in place of a .caw generator (#156). Its ports are one event input and one stereo audio output, and nothing else; `role` is `Instrument`. A new one starts from the blank template (`CppComponentDoc.blankInstrument`, "New instrument" in Build and Files): a polyphonic sine with a 10 ms attack and release. `examples/cpp/poly-synth/` is a fuller example (sine or saw, attack, release, volume; CI builds and plays it), and the engine's built-in instruments are more: `org.caw.synth.basic` (`engine/src/builtin_components.cpp`) and the drums, bass, acid and morph synths (`engine/src/builtin_instruments.cpp`), which are made of [Library](#the-library) kernels you can use the same way.

The instrument owns its polyphony, as a CLAP instrument does: the host sends note events, the instrument decides which voice plays each. `caw/instrument.hpp` makes that short:
- **`caw::InstrumentProcessor`** implements `processPorts` for you. It calls `onNote(const caw::NoteMessage&)` for each event on its frame and `render(left, right, frames, offset, block)` for the frames between, so a note starts on its exact sample. Read a knob with `caw::parameterAt(block, k, offset + i, fallback)`. A block with more than 64 distinct event frames starts the rest together at the 64th split.
- **`caw::NoteMessage`**: `type` (`On`, `Off`, `Pitch`, `Pressure`, `Timbre`), `noteId` (the host's id: the off, pitch and pressure of a note carry its on's id), `pitch` (a MIDI note number with fraction), `velocity` 0..1, `value` 0..1 for pressure and timbre, and `frame`.
- **`caw::VoicePool<Voice, N>`** hands out voices by note id: a free one, else the oldest released, else the oldest held. `Voice` needs `bool active, held`, `uint32_t noteId` and `uint64_t age`. `N` is your polyphony: the host sets no practical limit of its own (it holds 4,096 notes), and the built-in synths use 128. `forEachActive(f)` and `find` walk only the voices sounding (the pool lists them as `start()` hands them out and drops one found silent), so a large `N` costs memory, not time; start voices only through `start()`.
- **`caw::readNote`** and `caw::notes::noteOn/noteOff/notePitch/notePressure/noteTimbre` decode and encode the events, for an instrument that implements `processPorts` itself.

```cpp
void onNote(const caw::NoteMessage& m) noexcept override {
    if (m.type == caw::NoteMessageType::On) voices_.start(m.noteId).step = hz(m.pitch) / rate_;
    else if (Voice* v = voices_.find(m.noteId); v && m.type == caw::NoteMessageType::Off) v->held = false;
}
```

What the host sends, as `caw::Event` records of kind `Note` (MIDI 2.0 Channel Voice UMP words plus the note id; the field meanings follow the MIDI 2.0 UMP specification M2-104-UM **[Assumption: as recalled; not re-checked against the specification on 2026-11-10]**):
- Note On, with attribute type 3 (Pitch 7.9) giving the exact pitch, so microtones arrive exactly; the key is the nearest semitone; the 16-bit velocity is at least 1.
- Note Off, with the same note id and key.
- Registered Per-Note Controller 3 (Pitch 7.25): the note's absolute pitch now, sent every 16 frames while it glides (a slide, a preview's new pitch) or bends (the note's bend curve and vibrato).
- Poly Pressure and Registered Per-Note Controller 74 (timbre) from the note's pressure and timbre curves.

The rules of an effect hold too: allocate in `activate`, make `reset()` silence every voice (the host calls it at Play and after the track was muted), and declare `tailFrames` for the longest release. The host ends every held note at Stop and lets the instrument ring out until it is quiet; the [engine reference](engine.md) has the details.

## Make a sample pack of your instrument

The sample-pack maker plays your instrument offline over the notes, velocities and parameter values you list and writes each as a WAV file, named, trimmed and optionally normalised and looped, with a manifest and an SFZ file a sampler can load ([engine reference](engine.md#sample-packs) for every key). After building:

```
caw sample-pack local.my-synth --library ./build/my-synth.so --trust trusted --out pack --name keys \
    --notes C2:C6:12 --vel 40,90,127 --hold 2 --loop --sfz --normalize peak --group
caw sample-pack --request pack.json --trust trusted --out pack --overwrite
```

Each file is a fresh instance: a note on at the first frame, held for `--hold` seconds, a note off, and the release until it falls below -80 dB. So `reset()`/`activate` must leave no state from before, `tailFrames` should cover your release (a release longer than `--max` is cut, `tail_truncated`), and the same build gives the same bytes every time. Use `--step NAME=V1,V2` to render a parameter at several values (one SFZ per combination), and `effects` in a request file to bake an effect chain into the samples. The library is in-process code, so it loads only with `--trust trusted` (hosts pass `CAW_NATIVE_TRUST_TRUSTED` to `caw_sample_pack_render`); the request itself cannot grant trust. Loops are found at matching zero crossings in the held part, so they sound seamless only when the held sound repeats.

## The Library

`engine/include/caw/library/` is header-only C++ in `namespace caw::lib`: what the engine's built-ins are made of, for your components to reuse. It uses only the deterministic maths of `caw/detmath.hpp`, so a component built with `CAW::SDK` gets the same bits as the engine, and nothing in it allocates except a `prepare()` (the delay lines, the reverb and the wavetable; call it in `activate`, never in `process`). Objects with coefficients have a `set()` that costs an exp or a tan (call it when a knob moves, or every 16 frames) and a per-sample call. Each header explains its method in comments, as a worked example of an efficient real-time kernel.
- `stereo.hpp`: `constantPowerPan` (the mixer's pan law), `balanceGains`, `applyWidth`.
- `distortion.hpp`: `drive`, `hardClip`, `fold`, `crush` (the .caw `fx.*` call the same code).
- `delay.hpp`: `PingPongDelay`, `Chorus`, `noteSeconds`.
- `oscillator.hpp`: `noteHz` (MIDI note with fraction to Hz), `wrap01`, `polyBlep`; `sineWave`, `triangleWave`, band-limited `sawWave`, `squareWave` and `pulseWave` (phase 0..1 and cycles per sample), `morphWave` (sine, triangle, saw, square by `shape` 0..1) and `Noise` (seeded white noise, the same sequence everywhere).
- `filter.hpp`: `Svf` (12 dB state-variable: low, band, high and notch at once; the .caw `lpf`/`hpf`/`bpf`/`notch` maths), `OnePole`, `Ladder` (24 dB low-pass with a soft-clipped input, resonance 0..1), `resonanceQ` (0..1 to a Q) and `shiftCutoff` (a cutoff moved by octaves, held in range).
- `envelope.hpp`: `AdEnvelope` (as the .caw `ad`), `Adsr` (as `env.adsr`), `Glide` (portamento), `decayCoefficient` and `attackStep`.
- `drums.hpp`: `KickVoice`, `SnareVoice`, `ClapVoice` and `HatVoice` with their settings structs: `set()`, `trigger(velocity)`, `next()`, `choke()`.
- `smoothing.hpp`: `OnePoleSmoother` (99 % of a step in its time, then lands exactly) and `LinearSmoother` (a ramp that ends in exactly its time); `setTime()` pays once, `setTarget()` is free. Smooth every knob that scales audio.
- `lfo.hpp`: `Lfo` with `LfoShape` sine, triangle, saw up and down, square (pulse width), sample-and-hold and smooth random; rate in Hz or tempo-synced (`setRateBeats(beats, bpm)`), phase offset, unipolar or bipolar, `retrigger()` and `syncToBeat(position, beats)`. `next()` per sample, `block(frames)` once per block. The random shapes are a function of seed and cycle number, so they repeat with the song.
- `wavetable.hpp`: `Wavetable` (frames you fill with `setFrameFunction` or `setFrameHarmonics`, sized at `prepare(maxFrames, frameSize)`) and `WavetableOscillator` (`setFrequency`, `setPosition` 0..1 morphing linearly between frames). Each frame keeps one mip level per octave, built additively from its harmonics (a function is measured with a direct DFT), and the oscillator plays the level whose harmonics all stay below Nyquist, so it does not alias; aliasing and interpolation images measure below −60 dB for a saw. Building costs about 6 ms per 2048-sample frame: do it off the audio thread, and swap tables between blocks. `sawHarmonics`, `squareHarmonics`, `triangleHarmonics` fill amplitude arrays.
- `reverb.hpp`: `Reverb` with `ReverbSettings` (`size`, `decay` as RT60 seconds, `damping`, `preDelay`, `width`, `mix`): an 8-line feedback delay network with Hadamard mixing and input all-passes, original code. `prepare(rate, maxBlock, maxPreDelay)` allocates; `process` is denormal-safe and NaN-proof, and the measured RT60 is within 5 % of `decay`. `tailFrames()` gives a component's tail. Changing `size` can click on a ringing tail.

```cpp
lib::Svf filter;
filter.set(lib::shiftCutoff(800.0, 3.0 * env.next(), rate), lib::resonanceQ(0.6), rate);
const double y = filter.lowpass(lib::sawWave(phase, dt));
```

## One module system

Built-in modules and add-on modules share the same stable identity (with display name, component version and role), typed ports, parameter metadata (choices and modulation/automation/MIDI capability flags, CP.2; components export their SDK header revision and the registry refuses any other), graph validation, state versioning and processing model: internally N-channel planar buffers with a stereo adapter, summing (mix-bus) inputs since F4.1 (2026-11-03) and audio-thread re-routing of summing inputs since F4.3 (`GraphExecutor::setRouting`), plus one-source routes into plain inputs since F4.4 (`prepareRouted`), which the Engine's mix graph uses (and whose `workingBytes()` estimate sets how many layers the Engine can grow to, F7.3), and since F5.1/F5.2 several audio ports, modulation, control and event ports for internal modules that implement `processPorts`; which saturate a processor's inf at ±FLT_MAX and treat NaN as 0 (`route_math.h`). Compiled components cross a plain C boundary, `engine/include/caw_component.h` (interface v3, see below); the C++ contract in `engine/include/caw/module.hpp` is compiled into each component and into the engine separately (`CAW::SDK` passes the engine's floating-point flags, no fused multiply-add contraction and no fast-math, plus `-fno-trapping-math` on GCC and Clang (no result changes; GCC then vectorizes loops with selects), so the public deterministic maths in `caw/detmath.hpp` and the Library in `caw/library/` give the same bits in a component as in the engine), so the two can use different compilers and C++ standard libraries. Internal `engine/src/module.h` forwards to that canonical header. A v1 `caw.component` manifest and CMake helper build an external shared library and emit a configuration-specific artifact path for the app build service.

## Entry point

**C interface v3 (CP.2, 2026-11-09).** A component library exports one symbol, `caw_get_component_v3(index)`, returning a static `CawComponentV3` table for each component it holds (a bundle may hold several, owner 2026-11-09; NULL past the last): a size-tagged `CawComponentDescriptor` (id, name, version, role, latency, tail, maximum state size, ports, parameters with choices and capability flags, UI controls, custom UI id; arrays read with the strides it declares) and functions `create(host)`, `destroy`, `activate(sample rate, max frames)`, `deactivate`, `reset`, `process` (the full typed-port block), `save_state`/`load_state` (with a state version) and `get_extension`. Plain C only (`engine/tests/component_header_check.c` compiles it as C99). Growth rules: each top-level struct starts with `struct_size` and readers accept larger ones; arrays use the declared strides; new capabilities arrive through `get_extension` on the host and component sides (none are defined yet). Threads: create, activate, deactivate, state, extensions and destroy on a control thread; process and reset on the audio thread, only while active. In C++, `CAW_EXPORT_COMPONENT(Type, descriptor)` exports one component and `CAW_EXPORT_COMPONENTS(A, B, ...)` a bundle (`engine/include/caw/component.hpp`); each builds the table from a `ModuleProcessor` and catches exceptions at the boundary. `ModuleRegistry` resolves only that symbol, walks its entries to the one with the expected id (refusing another interface version at any entry), checks sizes and the required functions, copies the descriptor into engine-owned storage (the C descriptor is the wire format; the engine works only with `caw::ModuleDescriptor`), validates it, and wraps each instance in an adapter that fills a C process block without allocating. The stereo-only interface v1 (`caw_module_sdk.h`) and the C++-typed `caw_component_*` exports are gone (owner, 2026-11-09: no v1 compatibility). Hosts read the loaded components' descriptors through `caw_engine_components` (JSON, `moduleDescriptorJson`), which the app parses into `NativeComponentInfo` (`app/lib/engine/component_info.dart`) with `Engine.nativeComponents()`; no screen uses it yet.

## Export as a CLAP plug-in

**[Fact, checked 2026-11-10]** Any component library builds as a CLAP plug-in other hosts load, without changing its code. In the component's `CMakeLists.txt`, after `caw_add_component`:

```cmake
caw_add_clap_plugin(TARGET my_echo_clap COMPONENT caw_component_local_my_echo
  OUTPUT_NAME my-echo VENDOR "Me" URL "https://example.org" VERSION "1.0.0")   # all but TARGET/COMPONENT optional
```

It compiles the component's sources once more with the SDK's wrapper (`engine/plugin/clap/caw_clap_entry.cpp`, installed in `lib/cmake/CAW/clap/`) into `my-echo.clap` next to the component library. The example does it with `-DCAW_BUILD_CLAP=ON` (`examples/cpp/minimal/`). Configuring fetches the CLAP headers (free-audio/clap 1.2.9, MIT, pinned by commit; the build stops if the fetched `LICENSE` is not MIT); offline, point `FETCHCONTENT_SOURCE_DIR_CAW_CLAP` at a checkout. Linux and Windows only: a macOS `.clap` is a bundle and is not built. The `.clap` still exports `caw_get_component_v3`, so C.A.W itself loads it like the plain library.

What the wrapper maps (the component sees an ordinary C.A.W host):
- **Factory:** one CLAP plug-in per component of the bundle, in bundle order; plug-in id = component id, name = display name, version = `VERSION` or the component's version number. Features: by role (instrument, audio-effect, utility, note-effect, analyzer), else by ports, plus `stereo`/`mono`.
- **Audio ports:** the component's audio ports with their channel counts; the first input and output are main. 32-bit float only.
- **Note ports:** one CLAP note port per event port (dialects CLAP, MIDI and MIDI 2). CLAP note on/off/choke become MIDI 2.0 UMP note messages (`CAW_EVENT_NOTE`) with note id = CLAP id + 1; notes without an id (MIDI 1.0, MIDI 2) get wrapper ids with the top bit set, and wildcard note-offs end every matching note. MIDI 1.0 note on/off are converted to MIDI 2.0 (velocity scaled linearly, 127 to 65535); other MIDI 1.0 messages stay MIDI 1.0 UMP words (`CAW_EVENT_MIDI`); MIDI 2 events pass through. Note expressions: pressure as Poly Pressure, the rest as registered per-note controllers (tuning as Pitch 7.25, volume, pan, vibrato as modulation, expression, brightness). **[Assumption]** the per-note controller numbers are from the MIDI 2.0 list as remembered, not checked against the specification text. Output events go back as CLAP notes (ids restored), MIDI or MIDI 2 events. Up to 1024 events per port per block piece; more are dropped.
- **Parameters:** CLAP id = FNV-1a hash of the parameter id (stable when parameters are reordered), plain min/max/default, automatable and modulatable from the flags, stepped for a step or choices, enum for choices. Value text shows choice labels, or the value with its unit (decimals from the step); text-to-value reads labels or numbers. Changes are sample-accurate: a parameter that changes in a block gets per-frame values, ramping over its `smoothingFrames` exactly as the engine ramps a manual change (the test checks bit for bit); CLAP modulation adds to the plain value before clamping and step snapping. Exponential curves are not visible to the host (CLAP has no curve), so generic sliders are linear.
- **State:** a versioned blob: the component id, its state version, each parameter value by id, then the component's own state. Loading checks the id; unknown parameter ids are ignored and missing ones take their default. A load while active waits (on the main thread, never on the audio thread) until the current block ends; blocks started meanwhile output silence.
- **Latency and tail** from the descriptor (an infinite tail reports `INT32_MAX`, CLAP's infinite). **Transport:** tempo, beat position (moved on per piece of a long block) and beats per bar (the time signature in quarter notes, rounded) reach the component while the host plays; stopped, it gets none, as the C.A.W contract says.
- **Not mapped:** control inputs read their default and modulation inputs 0; control and modulation outputs are discarded. Host blocks longer than 4096 frames are processed in pieces. No GUI (hosts show generic parameter controls), no per-voice modulation, no sysex.

Threads and memory follow CLAP: process, reset and (while active) flush on the audio thread, the rest on the main thread; everything is allocated in `activate`, and a test counts zero allocations in process, flush and reset. On Linux the plug-in links with `-Bsymbolic`, so a host that loads several C.A.W plug-ins with global symbols cannot route one plug-in's wrapper to another's components. The test host (`engine/plugin/clap/tests/clap_host_test.cpp`, `caw_clap_tests`, built with `-DCAW_CLAP=ON`) loads the example and a test bundle (`tests/clap_fixture.cpp`: an effect with parameters, state, latency and tail; an instrument with note input and output; a transport reader) and compares every sample with the same components run through `ModuleRegistry`. Not yet tried in a third-party host or with the community `clap-validator`.

## Real-time contract

The process callback may run on the audio thread. It must:
- allocate no memory and perform no file, network, logging or UI I/O;
- acquire no mutexes and wait on no other thread;
- process only the supplied bounded frame count;
- treat buffers and parameter arrays as borrowed for the duration of the call;
- return promptly and never throw across the C boundary;
- avoid unbounded loops and uncontrolled recursion.

Creation, destruction, state serialization, graph compilation and asset loading happen off the audio thread. A module that violates the contract can still stall or crash an in-process host: native modules are trusted code, **not a security sandbox**. Untrusted modules require process isolation, which is a separate future host feature.

## Resource and compatibility rules

- Stable IDs identify modules; display names are not identifiers.
- Parameter IDs and port IDs are stable within a module major version.
- Parameters arrive as one value per block: the block's first resolved value (owner, 2026-11-04). Internal modules get them from the graph executor as `AudioProcessBlock`/`ProcessBlock::parameters` (per-frame when a value varies, is modulated, automated or moved by a mapped MIDI CC, F6.2–F6.5); the C ABI does not change for that.
- State size is capped by the host and declared maximum; the host rejects oversized state.
- Hosts must pin module version and preserve project snapshots or report missing/incompatible dependencies.
- Optional features may be omitted from a build, but a missing dependency must be reported explicitly rather than silently substituted.
- The v1 interface is stereo-native. Mono and discrete layouts are explicit port declarations, never inferred from buffer count.

## User interfaces

The SDK deliberately does not prescribe one UI. A module may provide a declarative control schema, a custom host-rendered view identifier, or code-driven controls. This is metadata and validation only; the CAW app's UI renderer and custom-view runtime are still future integration work. The project/app stores UI metadata separately from DSP state so the same module works in the app, project tools and future plugin wrappers.

## Implemented loading and remaining stages

- **Implemented:** load a shared library on Windows with `LoadLibraryW`, and on Linux/macOS/Android with `dlopen`; validate the exported descriptor and expected stable ID; require descriptor, factory and component-owned destroy exports; keep the library loaded while any created processor wrapper exists; refuse unload while an instance is alive.
- **Implemented:** `ModuleRegistry` and the Engine control API expose this loader. The C API `caw_engine_load_component` requires an explicit `CAW_NATIVE_TRUST_BLOCKED`, `CAW_NATIVE_TRUST_ISOLATED` or `CAW_NATIVE_TRUST_TRUSTED` value. Invalid values are rejected. Blocked never opens the library; Isolated is explicitly unsupported; Trusted executes in the Engine process. Build success never calls this API.
- **Partial:** the registry returns a `ModuleProcessor` wrapper that delegates processing/state calls and retains the library lifetime. The Engine plays explicitly loaded native stereo effects with their parameters on tracks (`LayerDoc.components`) and the master (`ProjectDoc.masterComponents`), with the safety limiter after native code. Effects with other ports (control, modulation, events, more than one audio port) remain outstanding. The Dart FFI load/unload wrapper runs on a background isolate; the per-component trust UI/store is still missing.
- **Still required:** process isolation for Isolated mode, crash/timeout diagnostics, signed packages, dependency manifests and reproducible build metadata, and CI coverage for macOS in addition to the current Linux/Windows/Android matrix.

The current in-process SDK is for trusted native code only. A module package must never be described as sandboxed until process isolation is implemented and tested.
