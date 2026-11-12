// Built-in components (the C.A.W. Library, #121): stereo effects and an instrument, registered in every Engine.
#include "builtin_components.h"
#include "builtin_modulators.h"

#include "builtin_effects.h"
#include "builtin_instruments.h"
#include "builtin_test_signal.h"

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
    d.domains = kDomainWhole | kDomainPerNote;  // #120: stereo effects may run per note
    d.cpuClass = CpuClass::Light;
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
    // No state: silence in gives silence out, so the host may skip it while its input is silent.
    bool quiet() const noexcept override { return true; }
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
    // No state: silence in gives silence out, so the host may skip it while its input is silent.
    bool quiet() const noexcept override { return true; }
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
    d.cpuClass = CpuClass::Medium;
    return d;
}
const ModuleDescriptor kDistortion = distortionDescriptor();

double paramAt(const AudioProcessBlock& b, uint32_t k, uint32_t i, double fallback) noexcept {
    if (k >= b.parameterCount || !b.parameters) return fallback;
    return b.parameters[k].samples ? b.parameters[k].samples[i] : b.parameters[k].value;
}

// No knob among the first `count` ramps in this block (the usual case): each holds one value for every frame.
bool steadyKnobs(const AudioProcessBlock& b, uint32_t count) noexcept {
    for (uint32_t k = 0; k < count && k < b.parameterCount && b.parameters; ++k)
        if (b.parameters[k].samples) return false;
    return true;
}

// The shapes' per-sample maths is the Library's fast kind (fastmath.hpp: the same curves within 1e-9), and
// what depends only on the knobs is worked out once per value, not per sample.
class Distortion final : public ModuleProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kDistortion; }
    // No state: silence in gives silence out, so the host may skip it while its input is silent.
    bool quiet() const noexcept override { return true; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override {
        if (!stereo(b)) return false;
        if (steadyKnobs(b, 5) && static_cast<int>(paramAt(b, 0, 0, 0.0)) == 0) return processDrive(b);
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
                    default: y = saturator_.processApprox(x); break;                             // lib::drive
                }
                b.output.channels[c][i] = static_cast<float>((x + (y - x) * mix) * out);
            }
        }
        return true;
    }

private:
    // Drive with every knob holding still: the knobs read once, and a sample the same on both sides (a centred
    // instrument) driven once for both (2026-11-10 second performance pass; the same bits as the loop above).
    bool processDrive(const AudioProcessBlock& b) noexcept {
        saturator_.set(paramAt(b, 1, 0, 4.0));
        const double mix = paramAt(b, 3, 0, 1.0), out = paramAt(b, 4, 0, 1.0);
        const float* inL = b.input.channels[0];
        const float* inR = b.input.channels[1];
        float* outL = b.output.channels[0];
        float* outR = b.output.channels[1];
        const auto shape = [&](double x, double y) noexcept { return static_cast<float>((x + (y - x) * mix) * out); };
        uint32_t i = 0;
        for (; i + 1 < b.frames; i += 2) {  // two frames at a time (Saturator::process2Approx: processApprox()'s steps)
            const double l[2] = {inL[i], inL[i + 1]}, r[2] = {inR[i], inR[i + 1]};
            double yl[2], yr[2];
            saturator_.process2Approx(l, yl);
            const bool same = r[0] == l[0] && r[1] == l[1];
            if (!same) saturator_.process2Approx(r, yr);
            for (int j = 0; j < 2; ++j) {
                outL[i + j] = shape(l[j], yl[j]);
                outR[i + j] = same ? outL[i + j] : shape(r[j], yr[j]);
            }
        }
        for (; i < b.frames; ++i) {
            const double l = inL[i], r = inR[i];
            const float yl = shape(l, saturator_.processApprox(l));
            outL[i] = yl;
            outR[i] = r == l ? yl : shape(r, saturator_.processApprox(r));
        }
        return true;
    }

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
    d.cpuClass = CpuClass::Medium;
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
        if (steadyKnobs(b, 5)) {  // the knobs and the target read once (the same bits as the loop below)
            const int sync = static_cast<int>(paramAt(b, 0, 0, 3.0));
            const double target = sync > 0 && sync < 8 ? lib::noteSeconds(tempo_, kDivisionWholeNotes[sync])
                                                       : paramAt(b, 1, 0, 375.0) / 1000.0;
            const double feedback = paramAt(b, 2, 0, 0.45), cross = paramAt(b, 3, 0, 1.0), mix = paramAt(b, 4, 0, 0.35);
            for (uint32_t i = 0; i < b.frames; ++i) {
                seconds_ = seconds_ < 0.0 ? target : seconds_ + (target - seconds_) * glide_;
                float l = b.input.channels[0][i], r = b.input.channels[1][i];
                delay_.process(seconds_, feedback, cross, mix, l, r);
                b.output.channels[0][i] = l;
                b.output.channels[1][i] = r;
            }
            return true;
        }
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
    d.cpuClass = CpuClass::Medium;
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
        if (steadyKnobs(b, 3)) {  // the knobs read once (the same bits as the loop below)
            const double rate = paramAt(b, 0, 0, 0.6), depth = paramAt(b, 1, 0, 0.5), mix = paramAt(b, 2, 0, 0.5);
            for (uint32_t i = 0; i < b.frames; ++i) {
                if (left_ == 0) {
                    chorus_.control(rate, depth, kControlFrames);
                    left_ = kControlFrames;
                }
                --left_;
                float l = b.input.channels[0][i], r = b.input.channels[1][i];
                chorus_.step(mix, l, r);
                b.output.channels[0][i] = l;
                b.output.channels[1][i] = r;
            }
            return true;
        }
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
    registerBuiltinEffects(registry);  // the effects suite (#173, builtin_effects*.cpp)
    registerBuiltinInstruments(registry);  // the drums and Flagship (builtin_instruments.cpp, builtin_flagship.cpp)
    registerBuiltinModulators(registry);  // LFO, envelope, follower, steps, random, macros, MIDI to CV (#161)
    registerTestSignal(registry);  // org.caw.test.osc, internal: for tests, never listed (builtin_test_signal.cpp)
}

}  // namespace caw
