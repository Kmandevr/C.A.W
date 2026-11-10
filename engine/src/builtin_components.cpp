// Built-in components (the C.A.W. Library, #121): stereo effects and an instrument, registered in every Engine.
#include "builtin_components.h"

#include "builtin_effects.h"
#include "builtin_instruments.h"

#include <algorithm>
#include <cmath>

#include "caw/detmath.hpp"
#include "caw/instrument.hpp"
#include "caw/library/delay.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/stereo.hpp"

namespace caw {

namespace {

constexpr PortDescriptor kStereoPorts[] = {stereoInput("in"), stereoOutput("out")};

ParameterDescriptor parameter(std::string_view id, std::string_view name, double def, double lo, double hi) {
    ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.smoothingFrames = 480;  // 10 ms at 48 kHz: a knob move doesn't click
    return p;
}

// A time, frequency, rate or gain: the knob tapers (each step of its travel multiplies the value), so it turns finely
// near the bottom of a wide range.
ParameterDescriptor tapered(std::string_view id, std::string_view name, double def, double lo, double hi,
                            std::string_view unit = {}) {
    ParameterDescriptor p = parameter(id, name, def, lo, hi);
    p.unit = unit;
    p.curve = ParameterCurve::Exponential;
    return p;
}

ModuleDescriptor descriptor(std::string_view id, std::string_view name, const ParameterDescriptor* params) {
    ModuleDescriptor d;
    d.id = id;
    d.name = name;
    d.role = ModuleRole::Utility;
    d.ports = kStereoPorts;
    d.portCount = 2;
    d.parameters = params;
    d.parameterCount = 1;
    return d;
}

const ParameterDescriptor kBalanceParams[] = {parameter("pan", "Pan", 0.0, -1.0, 1.0)};
const ParameterDescriptor kWidthParams[] = {parameter("width", "Width", 1.0, 0.0, 2.0)};
const ModuleDescriptor kBalance = descriptor("org.caw.stereo.balance", "Balance", kBalanceParams);
const ModuleDescriptor kWidth = descriptor("org.caw.stereo.width", "Width", kWidthParams);

// The block's value of parameter 0 at frame i (per frame while it ramps or is automated).
double valueAt(const AudioProcessBlock& b, uint32_t i, double fallback) noexcept {
    if (b.parameterCount == 0 || !b.parameters) return fallback;
    return b.parameters[0].samples ? b.parameters[0].samples[i] : b.parameters[0].value;
}

bool stereo(const AudioProcessBlock& b) noexcept { return b.input.channelCount == 2 && b.output.channelCount == 2; }

class Balance final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kBalance; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            const lib::PanGains g = lib::balanceGains(valueAt(b, i, 0.0));
            b.output.channels[0][i] = static_cast<float>(b.input.channels[0][i] * g.left);
            b.output.channels[1][i] = static_cast<float>(b.input.channels[1][i] * g.right);
        }
        return true;
    }
};

class Width final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kWidth; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            double l = b.input.channels[0][i], r = b.input.channels[1][i];
            lib::applyWidth(valueAt(b, i, 1.0), l, r);
            b.output.channels[0][i] = static_cast<float>(l);
            b.output.channels[1][i] = static_cast<float>(r);
        }
        return true;
    }
};

// Distortion: one of four shapes per channel (so a stereo signal stays stereo), then a dry/wet mix and
// an output level.
constexpr std::string_view kShapes[] = {"Drive", "Hard clip", "Fold", "Crush"};
ParameterDescriptor shapeParameter() {
    ParameterDescriptor p = parameter("shape", "Shape", 0.0, 0.0, 3.0);
    p.step = 1.0;
    p.choices = kShapes;
    p.choiceCount = 4;
    p.smoothingFrames = 0;  // a choice jumps
    return p;
}
const ParameterDescriptor kDistortionParams[] = {
    shapeParameter(),
    tapered("drive", "Drive", 4.0, 1.0, 20.0),
    parameter("bits", "Bits", 8.0, 1.0, 24.0),
    parameter("mix", "Mix", 1.0, 0.0, 1.0),
    parameter("output", "Output", 1.0, 0.0, 2.0),
};
ModuleDescriptor distortionDescriptor() {
    ModuleDescriptor d = descriptor("org.caw.distortion", "Distortion", kDistortionParams);
    d.role = ModuleRole::Effect;
    d.parameterCount = 5;
    return d;
}
const ModuleDescriptor kDistortion = distortionDescriptor();

double paramAt(const AudioProcessBlock& b, uint32_t k, uint32_t i, double fallback) noexcept {
    if (k >= b.parameterCount || !b.parameters) return fallback;
    return b.parameters[k].samples ? b.parameters[k].samples[i] : b.parameters[k].value;
}

// The shapes' per-sample maths is the Library's fast kind (fastmath.hpp: the same curves within 1e-9), and
// what depends only on the knobs is worked out once per value, not per sample.
class Distortion final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kDistortion; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            const int shape = static_cast<int>(paramAt(b, 0, i, 0.0));
            const double amount = paramAt(b, 1, i, 4.0), bits = paramAt(b, 2, i, 8.0);
            const double mix = paramAt(b, 3, i, 1.0), out = paramAt(b, 4, i, 1.0);
            if (shape == 0) saturator_.set(amount);
            if (shape == 3 && bits != bits_) {
                bits_ = bits;
                const double whole = bits < 1.0 ? 1.0 : (bits > 24.0 ? 24.0 : bits);
                steps_ = detPow(2.0, std::floor(whole) - 1.0);
            }
            for (uint32_t c = 0; c < 2; ++c) {
                const double x = b.input.channels[c][i];
                double y = 0.0;
                switch (shape) {
                    case 1: y = lib::hardClip(x, amount); break;
                    case 2: y = lib::fastSinCycles(finiteOr0(x) * amount * 0.25); break;  // lib::fold
                    case 3: y = std::floor(finiteOr0(x) * steps_ + 0.5) / steps_; break;  // lib::crush
                    default: y = saturator_.process(x); break;                             // lib::drive
                }
                b.output.channels[c][i] = static_cast<float>((x + (y - x) * mix) * out);
            }
        }
        return true;
    }

private:
    lib::Saturator saturator_;
    double bits_ = -1.0, steps_ = 128.0;
};

// Ping-pong delay: synced to the song's tempo (a note division) or free (milliseconds), with feedback,
// cross-feed between the sides and a dry/wet mix. Up to 4 s of delay, allocated at activate (a division
// longer than that, such as a bar below 60 BPM, is held at 4 s).
constexpr std::string_view kDivisions[] = {"Free", "1/16", "1/8", "Dotted 1/8", "1/4", "Dotted 1/4", "1/2", "1 bar"};
constexpr double kDivisionWholeNotes[] = {0.0, 0.0625, 0.125, 0.1875, 0.25, 0.375, 0.5, 1.0};
ParameterDescriptor syncParameter() {
    ParameterDescriptor p = parameter("sync", "Sync", 3.0, 0.0, 7.0);
    p.step = 1.0;
    p.choices = kDivisions;
    p.choiceCount = 8;
    p.smoothingFrames = 0;
    return p;
}
const ParameterDescriptor kDelayParams[] = {
    syncParameter(),
    tapered("time", "Time (free)", 375.0, 1.0, 4000.0, "ms"),
    parameter("feedback", "Feedback", 0.45, 0.0, 0.95),
    parameter("cross", "Ping-pong", 1.0, 0.0, 1.0),
    parameter("mix", "Mix", 0.35, 0.0, 1.0),
};
ModuleDescriptor delayDescriptor() {
    ModuleDescriptor d = descriptor("org.caw.delay.pingpong", "Ping-pong delay", kDelayParams);
    d.role = ModuleRole::Effect;
    d.parameterCount = 5;
    d.tailFrames = kInfiniteTail;  // with feedback it rings until it is quiet
    return d;
}
const ModuleDescriptor kDelay = delayDescriptor();

class PingPong final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kDelay; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        glide_ = 1.0 - detExp(-1.0 / (0.03 * sampleRate));  // the delay time follows a change over ~30 ms
        seconds_ = -1.0;
        try {
            delay_.prepare(sampleRate, 4.0);
        } catch (...) {
            return false;
        }
        return true;
    }
    void reset() noexcept override { delay_.clear(); }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        // The host gives the tempo even while stopped; without a transport at all, the last tempo seen holds.
        if (b.transport) tempo_ = b.transport->tempo;
        for (uint32_t i = 0; i < b.frames; ++i) {
            const int sync = static_cast<int>(paramAt(b, 0, i, 3.0));
            const double target = sync > 0 && sync < 8 ? lib::noteSeconds(tempo_, kDivisionWholeNotes[sync])
                                                       : paramAt(b, 1, i, 375.0) / 1000.0;
            // A new division or tempo glides there, so the echo bends briefly instead of clicking.
            seconds_ = seconds_ < 0.0 ? target : seconds_ + (target - seconds_) * glide_;
            float l = b.input.channels[0][i], r = b.input.channels[1][i];
            delay_.process(seconds_, paramAt(b, 2, i, 0.45), paramAt(b, 3, i, 1.0), paramAt(b, 4, i, 0.35), l, r);
            b.output.channels[0][i] = l;
            b.output.channels[1][i] = r;
        }
        return true;
    }

private:
    lib::PingPongDelay delay_;
    double tempo_ = 120.0;
    double seconds_ = -1.0;  // the delay time now (gliding to the target); -1 before the first block
    double glide_ = 0.0;
};

// Stereo chorus: rate, depth and mix; the two sides sweep a quarter cycle apart.
const ParameterDescriptor kChorusParams[] = {
    tapered("rate", "Rate", 0.6, 0.05, 5.0, "Hz"),
    parameter("depth", "Depth", 0.5, 0.0, 1.0),
    parameter("mix", "Mix", 0.5, 0.0, 1.0),
};
ModuleDescriptor chorusDescriptor() {
    ModuleDescriptor d = descriptor("org.caw.chorus", "Chorus", kChorusParams);
    d.role = ModuleRole::Effect;
    d.parameterCount = 3;
    d.tailFrames = 9600;  // the 50 ms line empties, at rates up to 192 kHz
    return d;
}
const ModuleDescriptor kChorus = chorusDescriptor();

class ChorusEffect final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kChorus; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        try {
            chorus_.prepare(sampleRate);
        } catch (...) {
            return false;
        }
        return true;
    }
    void reset() noexcept override {
        chorus_.clear();
        left_ = 0;
    }
    using ModuleProcessor::process;
    // The LFO runs at the control rate (lib::Chorus::control every 16 frames, carried across blocks so a
    // block's size doesn't move it), the sweep gliding in between: perceptually the per-sample sweep.
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            if (left_ == 0) {
                chorus_.control(paramAt(b, 0, i, 0.6), paramAt(b, 1, i, 0.5), kControlFrames);
                left_ = kControlFrames;
            }
            --left_;
            float l = b.input.channels[0][i], r = b.input.channels[1][i];
            chorus_.step(paramAt(b, 2, i, 0.5), l, r);
            b.output.channels[0][i] = l;
            b.output.channels[1][i] = r;
        }
        return true;
    }

private:
    static constexpr uint32_t kControlFrames = 16;
    lib::Chorus chorus_;
    uint32_t left_ = 0;  // frames until the next control
};


// The basic synth ("org.caw.synth.basic"): 128 voices of two oscillators (saw, square, triangle or sine; the second
// detuned and mixed in), a resonant low-pass filter that follows the envelope, and an ADSR envelope. Velocity sets
// the level; a note's pressure scales it and its timbre opens the filter. Deterministic maths (caw/detmath.hpp),
// so it renders the same bits on every device.
constexpr std::string_view kWaves[] = {"Saw", "Square", "Triangle", "Sine"};
ParameterDescriptor waveParameter(std::string_view id, std::string_view name, double def) {
    ParameterDescriptor p = parameter(id, name, def, 0.0, 3.0);
    p.step = 1.0;
    p.choices = kWaves;
    p.choiceCount = 4;
    p.smoothingFrames = 0;
    return p;
}
ParameterDescriptor timeParameter(std::string_view id, std::string_view name, double def, double hi) {
    ParameterDescriptor p = parameter(id, name, def, 0.001, hi);
    p.unit = "s";
    p.curve = ParameterCurve::Exponential;
    return p;
}
ParameterDescriptor cutoffParameter() {
    ParameterDescriptor p = parameter("cutoff", "Cutoff", 2400.0, 40.0, 18000.0);
    p.unit = "Hz";
    p.curve = ParameterCurve::Exponential;
    return p;
}
ParameterDescriptor detuneParameter() {
    ParameterDescriptor p = parameter("detune", "Detune", 7.0, -100.0, 100.0);
    p.unit = "cents";
    return p;
}
const ParameterDescriptor kSynthParams[] = {
    waveParameter("wave1", "Wave 1", 0.0),
    waveParameter("wave2", "Wave 2", 1.0),
    detuneParameter(),
    parameter("mix", "Osc 2", 0.5, 0.0, 1.0),
    cutoffParameter(),
    parameter("resonance", "Resonance", 0.2, 0.0, 1.0),
    parameter("env", "Filter env", 0.5, 0.0, 1.0),
    timeParameter("attack", "Attack", 0.005, 10.0),
    timeParameter("decay", "Decay", 0.3, 10.0),
    parameter("sustain", "Sustain", 0.7, 0.0, 1.0),
    timeParameter("release", "Release", 0.25, 10.0),
    parameter("volume", "Volume", 0.5, 0.0, 1.0),
};
enum SynthParam : uint32_t { kWave1, kWave2, kDetune, kMix, kCutoff, kResonance, kEnv, kAttack, kDecay, kSustain, kRelease, kVolume };
constexpr PortDescriptor kInstrumentPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};
ModuleDescriptor synthDescriptor() {
    ModuleDescriptor d = descriptor("org.caw.synth.basic", "Basic synth", kSynthParams);
    d.role = ModuleRole::Instrument;
    d.ports = kInstrumentPorts;
    d.parameterCount = 12;
    d.tailFrames = 1920000;  // a 10 s release at up to 192 kHz
    return d;
}
const ModuleDescriptor kSynth = synthDescriptor();

class BasicSynth final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kSynth; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sampleRate_ = sampleRate;
        reset();
        return true;
    }
    void reset() noexcept override {
        voices_.clear();
        controlLeft_ = 0;
    }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        switch (m.type) {
            case NoteMessageType::On: {
                controlLeft_ = 0;  // the control grid restarts here
                Voice& v = voices_.start(m.noteId);
                v.stage = Stage::Attack;
                v.velocity = m.velocity;
                v.pressure = 1.0;
                v.timbre = 0.0;
                setPitch(v, m.pitch);
                if (v.level == 0.0) {  // a silent voice starts clean; a stolen one continues from its level (no click)
                    v.phase1 = v.phase2 = 0.0;
                    v.ic1 = v.ic2 = 0.0;
                }
                break;
            }
            case NoteMessageType::Off:
                if (Voice* v = voices_.find(m.noteId); v && v->held) {
                    v->held = false;
                    v->stage = Stage::Release;
                }
                break;
            case NoteMessageType::Pitch:
                if (Voice* v = voices_.find(m.noteId)) setPitch(*v, m.pitch);
                break;
            case NoteMessageType::Pressure:
                if (Voice* v = voices_.find(m.noteId)) v->pressure = m.value;
                break;
            case NoteMessageType::Timbre:
                if (Voice* v = voices_.find(m.noteId)) v->timbre = m.value;
                break;
            case NoteMessageType::Other: break;
        }
    }

    // The control grid (envelope rates and each voice's steps and filter, every 16 frames) runs on from one
    // render call to the next and restarts at a note-on, so blocks and event splits don't move it.
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        for (uint32_t start = 0; start < frames;) {
            if (controlLeft_ == 0) {
                control(b, offset + start);
                controlLeft_ = kControlFrames;
            }
            const uint32_t n = std::min(controlLeft_, frames - start);
            voices_.forEachActive([&](Voice& v) noexcept { renderVoice(v, left, right, start, start + n, offset, b); });
            start += n;
            controlLeft_ -= n;
        }
    }

private:
    enum class Stage : uint8_t { Attack, Decay, Release };
    struct Voice {
        bool active = false, held = false;
        uint32_t noteId = 0;
        uint64_t age = 0;
        Stage stage = Stage::Attack;
        double level = 0, velocity = 1, pressure = 1, timbre = 0;
        double freq = 261.6255653005986, inc1 = 0, inc2 = 0, phase1 = 0, phase2 = 0;
        double ic1 = 0, ic2 = 0, a1 = 1, a2 = 0, a3 = 0;
    };
    void control(const ProcessBlock& b, uint32_t at) noexcept {
        const double sr = sampleRate_;
        const double detune = parameterAt(b, kDetune, at, 7.0);
        const double ratio = detPow(2.0, detune / 1200.0);
        attackStep_ = 1.0 / std::max(1.0, parameterAt(b, kAttack, at, 0.005) * sr);
        decayCoef_ = detExp(-1.0 / std::max(1.0, parameterAt(b, kDecay, at, 0.3) * sr / 5.0));
        releaseCoef_ = detExp(-1.0 / std::max(1.0, parameterAt(b, kRelease, at, 0.25) * sr / 5.0));
        const double env = parameterAt(b, kEnv, at, 0.5), cutoff = parameterAt(b, kCutoff, at, 2400.0);
        const double k = 2.0 - 1.9 * std::clamp(parameterAt(b, kResonance, at, 0.2), 0.0, 1.0);
        voices_.forEachActive([&](Voice& v) noexcept {
            v.inc1 = v.freq / sr;
            v.inc2 = v.freq * ratio / sr;
            const double octaves = 5.0 * env * v.level + 4.0 * v.timbre;
            double fc = cutoff * detPow(2.0, octaves);
            fc = std::clamp(fc, 20.0, 0.45 * sr);
            const double g = detTan(3.14159265358979323846 * fc / sr);
            v.a1 = 1.0 / (1.0 + g * (g + k));
            v.a2 = g * v.a1;
            v.a3 = g * v.a2;
        });
    }
    void renderVoice(Voice& v, float* left, float* right, uint32_t from, uint32_t to, uint32_t offset,
                     const ProcessBlock& b) noexcept {
        for (uint32_t i = from; i < to; ++i) {
            const uint32_t at = offset + i;
            const double sustain = parameterAt(b, kSustain, at, 0.7);
            switch (v.stage) {
                case Stage::Attack:
                    v.level += attackStep_;
                    if (v.level >= 1.0) { v.level = 1.0; v.stage = Stage::Decay; }
                    break;
                case Stage::Decay:
                    v.level = sustain + (v.level - sustain) * decayCoef_;
                    // At the sustain level (within 1e-9) it stays there: a held note at sustain 0 doesn't decay
                    // into denormal numbers.
                    if (v.level - sustain < 1e-9 && sustain - v.level < 1e-9) v.level = sustain;
                    break;
                case Stage::Release: v.level *= releaseCoef_; break;
            }
            const double o1 = oscillator(static_cast<int>(parameterAt(b, kWave1, at, 0.0)), v.phase1, v.inc1);
            const double o2 = oscillator(static_cast<int>(parameterAt(b, kWave2, at, 1.0)), v.phase2, v.inc2);
            const double mix = parameterAt(b, kMix, at, 0.5);
            const double x = o1 * (1.0 - 0.5 * mix) + o2 * mix;
            v.phase1 += v.inc1;
            v.phase1 -= std::floor(v.phase1);
            v.phase2 += v.inc2;
            v.phase2 -= std::floor(v.phase2);
            // Low-pass state-variable filter (topology-preserving form).
            const double v3 = x - v.ic2;
            const double v1 = v.a1 * v.ic1 + v.a2 * v3;
            const double v2 = v.ic2 + v.a2 * v.ic1 + v.a3 * v3;
            v.ic1 = 2.0 * v1 - v.ic1;
            v.ic2 = 2.0 * v2 - v.ic2;
            const double y = v2 * v.level * v.velocity * v.pressure * parameterAt(b, kVolume, at, 0.5) * 0.3;
            left[i] += static_cast<float>(y);
            right[i] += static_cast<float>(y);
            // Released and below -100 dB: silent from the next frame. Checked every frame, so where a render call
            // ends (the block size, an event) doesn't move it.
            if (v.stage == Stage::Release && v.level < 1e-5) {
                v.active = false;
                v.level = 0.0;
                break;
            }
        }
    }
    static constexpr uint32_t kControlFrames = 16;
    static void setPitch(Voice& v, double pitch) noexcept { v.freq = 440.0 * detPow(2.0, (pitch - 69.0) / 12.0); }
    // PolyBLEP: the step of a saw or square smoothed over one sample, so high notes alias less.
    static double blep(double t, double dt) noexcept {
        if (t < dt) {
            t /= dt;
            return t + t - t * t - 1.0;
        }
        if (t > 1.0 - dt) {
            t = (t - 1.0) / dt;
            return t * t + t + t + 1.0;
        }
        return 0.0;
    }
    static double oscillator(int wave, double t, double dt) noexcept {
        switch (wave) {
            case 1: {
                const double u = t + 0.5 - std::floor(t + 0.5);
                return (t < 0.5 ? 1.0 : -1.0) + blep(t, dt) - blep(u, dt);
            }
            case 2: return 4.0 * std::fabs(t - 0.5) - 1.0;
            case 3: return detSin(2.0 * 3.14159265358979323846 * t);
            default: return 2.0 * t - 1.0 - blep(t, dt);
        }
    }
    VoicePool<Voice, 128> voices_;  // plenty: a silent voice costs a check
    double sampleRate_ = 48000.0;
    double attackStep_ = 0, decayCoef_ = 0, releaseCoef_ = 0;
    uint32_t controlLeft_ = 0;  // frames until the next control
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerBuiltinComponents(ModuleRegistry& registry) {
    registry.add(kBalance, &make<Balance>);
    registry.add(kWidth, &make<Width>);
    registry.add(kDistortion, &make<Distortion>);
    registry.add(kDelay, &make<PingPong>);
    registry.add(kChorus, &make<ChorusEffect>);
    registry.add(kSynth, &make<BasicSynth>);
    registerBuiltinEffects(registry);  // the effects suite (#173, builtin_effects*.cpp)
    registerBuiltinInstruments(registry);  // the drums, bass, acid and morph synths (builtin_instruments.cpp)
}

}  // namespace caw
