// The built-in modulators (#161): LFO, envelope, follower, step sequencer, random, macros and MIDI to CV, written on the public caw/modulator.hpp.
#include "builtin_modulators.h"

#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "builtin_effects.h"
#include "caw/library/dynamics.hpp"
#include "caw/library/envelope.hpp"
#include "caw/modulator.hpp"
#include "mod_route.h"

namespace caw {

namespace {

using fx::kSyncCount;
using fx::kSyncDivisions;
using fx::kSyncWholeNotes;
using fx::ParamTable;

constexpr uint32_t kLfoPoints = 16, kSteps = 16, kMacros = 8;
constexpr std::string_view kLfoShapes[] = {"Sine",   "Triangle",      "Saw up",        "Saw down",
                                           "Square", "Sample & hold", "Smooth random", "Custom"};
constexpr std::string_view kLfoModes[] = {"Free", "Retrigger", "Song"};
constexpr std::string_view kEnvModes[] = {"Retrigger", "Legato"};
constexpr std::string_view kPriorities[] = {"Last", "Highest", "Lowest"};

double frac(double x) noexcept { return x - std::floor(x); }

// A modulator's descriptor: its parameters, a notes input and/or an audio input, and its outputs.
struct Layout {
    ParamTable p;
    std::vector<PortDescriptor> ports;
    ModuleDescriptor desc;
    void finish(std::string_view id, std::string_view name, bool notes, bool audio, std::initializer_list<std::string_view> outs) {
        if (notes) ports.push_back(mod::notesInput("notes"));
        if (audio) ports.push_back(mod::audioInput("audio"));
        for (std::string_view o : outs) ports.push_back(mod::output(o));
        desc.id = id;
        desc.name = name;
        desc.role = ModuleRole::Utility;
        desc.ports = ports.data();
        desc.portCount = static_cast<uint32_t>(ports.size());
        desc.parameters = p.data();
        desc.parameterCount = p.size();
    }
    uint32_t at(std::string_view id) const { return static_cast<uint32_t>(p.index(id)); }
};

ParameterDescriptor& plain(ParameterDescriptor& d) {  // a value modulators read once per block: no knob ramp
    d.smoothingFrames = 0;
    return d;
}

// Hz of a synced or free rate: `sync` (kSyncDivisions; 0 Free) at the tempo, else `hz`.
double rateHz(int sync, double hz, double tempo) noexcept {
    const int s = std::clamp(sync, 0, kSyncCount - 1);
    return s > 0 ? tempo / (60.0 * kSyncWholeNotes[s] * 4.0) : hz;
}

// ---- LFO ----
struct LfoLayout : Layout {
    uint32_t shape, rate, sync, phase, mode, points[kLfoPoints];
    LfoLayout() {
        plain(p.pick("shape", "Shape", 0.0, kLfoShapes));
        p.expo("rate", "Rate", 1.0, 0.01, 40.0, "Hz");
        plain(p.pick("sync", "Sync", 0.0, kSyncDivisions));
        p.num("phase", "Phase", 0.0, 0.0, 1.0);
        plain(p.pick("mode", "Mode", 0.0, kLfoModes));
        for (uint32_t q = 0; q < kLfoPoints; ++q)  // the Custom shape (drawn): a sine to start from, as the FX rack's
            plain(p.num("p" + std::to_string(q + 1), "Point " + std::to_string(q + 1),
                        0.5 + 0.5 * std::sin(2.0 * 3.14159265358979323846 * q / kLfoPoints), 0.0, 1.0));
        shape = at("shape"), rate = at("rate"), sync = at("sync"), phase = at("phase"), mode = at("mode");
        for (uint32_t q = 0; q < kLfoPoints; ++q) points[q] = at("p" + std::to_string(q + 1));
        finish("org.caw.mod.lfo", "LFO", true, false, {"out"});
    }
};
const LfoLayout& lfoLayout() {
    static const LfoLayout l;
    return l;
}

class Lfo final : public mod::Modulator {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return lfoLayout().desc; }
    void reset() noexcept override {
        phase_ = 0.0;
        cycle_ = 0;
        out_.reset();
    }

protected:
    bool render(const mod::Block& b) noexcept override {
        const LfoLayout& k = lfoLayout();
        const int sync = std::clamp(static_cast<int>(b.param(k.sync) + 0.5), 0, kSyncCount - 1);
        const int mode = std::clamp(static_cast<int>(b.param(k.mode) + 0.5), 0, 2);
        const int shape = std::clamp(static_cast<int>(b.param(k.shape) + 0.5), 0, 7);
        const double hz = rateHz(sync, b.param(k.rate, 1.0), b.tempo());
        if (mode == 1)
            for (uint32_t i = 0; i < b.notes.count; ++i)
                if (mod::decode(b.notes.events[i]).kind == mod::NoteMessage::Kind::NoteOn) phase_ = 0.0, cycle_ = 0;
        double beat = 0.0;
        if (mode == 2 && sync > 0 && b.beatAt(b.frames, beat)) {  // locked to the song: where it is at the block's end
            const double c = std::max(0.0, beat / (kSyncWholeNotes[sync] * 4.0));
            cycle_ = static_cast<uint64_t>(std::floor(c));
            phase_ = frac(c);
        } else {
            phase_ += hz * b.frames / sampleRate();
            if (phase_ >= 1.0) {
                const double whole = std::floor(phase_);
                cycle_ += static_cast<uint64_t>(whole);
                phase_ -= whole;
            }
        }
        const double p = frac(phase_ + b.param(k.phase));
        double v;
        if (shape == 7) {
            const double x = p * kLfoPoints;
            const uint32_t i = std::min<uint32_t>(static_cast<uint32_t>(x), kLfoPoints - 1);
            const double a = b.param(k.points[i], 0.5), c = b.param(k.points[(i + 1) % kLfoPoints], 0.5);
            v = a + (c - a) * (x - i);
        } else {
            v = 0.5 * (std::clamp(modLfoShape(shape, p, cycle_, 0x3000u), -1.0, 1.0) + 1.0);
        }
        out_.ramp(b.outputs[0], b.frames, v);
        return true;
    }

private:
    double phase_ = 0.0;
    uint64_t cycle_ = 0;
    mod::Ramp out_;
};

// ---- Envelope (ADSR from notes) ----
struct EnvLayout : Layout {
    uint32_t attack, decay, sustain, release, mode;
    EnvLayout() {
        p.expo("attack", "Attack", 0.005, 0.001, 10.0, "s");
        p.expo("decay", "Decay", 0.3, 0.001, 10.0, "s");
        p.num("sustain", "Sustain", 0.5, 0.0, 1.0);
        p.expo("release", "Release", 0.3, 0.001, 10.0, "s");
        plain(p.pick("mode", "Mode", 0.0, kEnvModes));
        attack = at("attack"), decay = at("decay"), sustain = at("sustain"), release = at("release"), mode = at("mode");
        finish("org.caw.mod.envelope", "Envelope", true, false, {"out"});
    }
};
const EnvLayout& envLayout() {
    static const EnvLayout l;
    return l;
}

class Envelope final : public mod::Modulator {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return envLayout().desc; }
    void reset() noexcept override {
        env_.clear();
        held_.clear();
    }

protected:
    bool render(const mod::Block& b) noexcept override {
        const EnvLayout& k = envLayout();
        env_.set(b.param(k.attack, 0.005), b.param(k.decay, 0.3), b.param(k.sustain, 0.5), b.param(k.release, 0.3),
                 b.sampleRate);
        const bool legato = b.param(k.mode) >= 0.5;
        uint32_t e = 0;
        float* out = b.outputs[0];
        for (uint32_t i = 0; i < b.frames; ++i) {
            for (; e < b.notes.count && b.notes.events[e].frame <= i; ++e) {
                const mod::NoteMessage m = mod::decode(b.notes.events[e]);
                const bool was = held_.any();
                if (!held_.apply(m)) continue;
                if (m.kind == mod::NoteMessage::Kind::NoteOn && (!legato || !was)) env_.gateOn();
                if (!held_.any()) env_.gateOff();
            }
            out[i] = static_cast<float>(std::clamp(env_.next(), 0.0, 1.0));
        }
        return true;
    }

private:
    lib::Adsr env_;
    mod::HeldNotes held_;
};

// ---- Envelope follower ----
struct FollowLayout : Layout {
    uint32_t attack, release, gain;
    FollowLayout() {
        p.expo("attack", "Attack", 10.0, 0.1, 500.0, "ms");
        p.expo("release", "Release", 150.0, 5.0, 5000.0, "ms");
        p.num("gain", "Gain", 0.0, -24.0, 24.0, "dB");
        attack = at("attack"), release = at("release"), gain = at("gain");
        finish("org.caw.mod.follower", "Envelope follower", false, true, {"out"});
    }
};
const FollowLayout& followLayout() {
    static const FollowLayout l;
    return l;
}

class Follower final : public mod::Modulator {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return followLayout().desc; }
    void reset() noexcept override { follow_.clear(); }

protected:
    bool render(const mod::Block& b) noexcept override {
        const FollowLayout& k = followLayout();
        follow_.setCoefficients(lib::timeCoefficient(b.param(k.attack, 10.0) * 0.001, b.sampleRate),
                                lib::timeCoefficient(b.param(k.release, 150.0) * 0.001, b.sampleRate));
        const double g = lib::dbToGain(b.param(k.gain));
        const ConstChannelBufferView* a = b.audio;
        const bool has = a && a->channelCount > 0 && a->valid() && a->frames >= b.frames;
        float* out = b.outputs[0];
        for (uint32_t i = 0; i < b.frames; ++i) {
            double x = 0.0;
            if (has)
                for (uint32_t c = 0; c < a->channelCount; ++c) x = std::max(x, static_cast<double>(std::fabs(a->channels[c][i])));
            out[i] = static_cast<float>(std::clamp(follow_.process(x) * g, 0.0, 1.0));
        }
        return true;
    }

private:
    lib::EnvelopeFollower follow_;
};

// ---- Step sequencer ----
struct StepsLayout : Layout {
    uint32_t count, sync, rate, glide, steps[kSteps];
    StepsLayout() {
        plain(p.num("steps", "Steps", 8.0, 1.0, kSteps)).step = 1.0;
        plain(p.pick("sync", "Sync", 3.0, kSyncDivisions));  // 1/16
        p.expo("rate", "Rate", 4.0, 0.05, 40.0, "Hz");
        p.num("glide", "Glide", 0.0, 0.0, 1.0);
        for (uint32_t q = 0; q < kSteps; ++q)  // a rising ramp to start from
            plain(p.num("s" + std::to_string(q + 1), "Step " + std::to_string(q + 1), (q % 8) / 7.0, 0.0, 1.0));
        count = at("steps"), sync = at("sync"), rate = at("rate"), glide = at("glide");
        for (uint32_t q = 0; q < kSteps; ++q) steps[q] = at("s" + std::to_string(q + 1));
        finish("org.caw.mod.steps", "Step sequencer", false, false, {"out"});
    }
};
const StepsLayout& stepsLayout() {
    static const StepsLayout l;
    return l;
}

class Steps final : public mod::Modulator {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return stepsLayout().desc; }
    void reset() noexcept override {
        pos_ = 0.0;
        out_.reset();
    }

protected:
    bool render(const mod::Block& b) noexcept override {
        const StepsLayout& k = stepsLayout();
        const int sync = std::clamp(static_cast<int>(b.param(k.sync, 3.0) + 0.5), 0, kSyncCount - 1);
        const uint32_t n = static_cast<uint32_t>(std::clamp(b.param(k.count, 8.0) + 0.5, 1.0, static_cast<double>(kSteps)));
        double beat = 0.0;
        if (sync > 0 && b.beatAt(b.frames, beat)) {  // playing: each step on the song's grid
            pos_ = std::max(0.0, beat / (kSyncWholeNotes[sync] * 4.0));
        } else {
            pos_ += rateHz(sync, b.param(k.rate, 4.0), b.tempo()) * b.frames / sampleRate();
        }
        const double whole = std::floor(pos_);
        const uint32_t i = static_cast<uint32_t>(std::fmod(whole, static_cast<double>(n)));
        const double f = pos_ - whole;
        const double cur = b.param(k.steps[i]), next = b.param(k.steps[(i + 1) % n]);
        const double g = std::clamp(b.param(k.glide), 0.0, 1.0);
        double v = cur;
        if (g > 0.0 && f > 1.0 - g) v = cur + (next - cur) * (f - (1.0 - g)) / g;
        out_.ramp(b.outputs[0], b.frames, v);
        if (pos_ > 1e12) pos_ = frac(pos_);
        return true;
    }

private:
    double pos_ = 0.0;
    mod::Ramp out_;
};

// ---- Random (sample & hold, smoothed) ----
struct RandomLayout : Layout {
    uint32_t rate, sync, smooth, seed;
    RandomLayout() {
        p.expo("rate", "Rate", 4.0, 0.05, 40.0, "Hz");
        plain(p.pick("sync", "Sync", 0.0, kSyncDivisions));
        p.num("smooth", "Smooth", 0.0, 0.0, 1.0);
        plain(p.num("seed", "Seed", 1.0, 0.0, 999.0)).step = 1.0;
        rate = at("rate"), sync = at("sync"), smooth = at("smooth"), seed = at("seed");
        finish("org.caw.mod.random", "Random", false, false, {"out"});
    }
};
const RandomLayout& randomLayout() {
    static const RandomLayout l;
    return l;
}

class Random final : public mod::Modulator {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return randomLayout().desc; }
    void reset() noexcept override {
        phase_ = 0.0;
        cycle_ = 0;
        out_.reset();
    }

protected:
    bool render(const mod::Block& b) noexcept override {
        const RandomLayout& k = randomLayout();
        const int sync = std::clamp(static_cast<int>(b.param(k.sync) + 0.5), 0, kSyncCount - 1);
        double beat = 0.0;
        if (sync > 0 && b.beatAt(b.frames, beat)) {
            const double c = std::max(0.0, beat / (kSyncWholeNotes[sync] * 4.0));
            cycle_ = static_cast<uint64_t>(std::floor(c));
            phase_ = frac(c);
        } else {
            phase_ += rateHz(sync, b.param(k.rate, 4.0), b.tempo()) * b.frames / sampleRate();
            if (phase_ >= 1.0) {
                const double whole = std::floor(phase_);
                cycle_ += static_cast<uint64_t>(whole);
                phase_ -= whole;
            }
        }
        const uint32_t seed = 0x4000u + static_cast<uint32_t>(std::clamp(b.param(k.seed, 1.0), 0.0, 999.0));
        const double a = modUnitHash(seed, cycle_), c = modUnitHash(seed, cycle_ + 1);
        const double t = phase_ * phase_ * (3.0 - 2.0 * phase_);
        out_.ramp(b.outputs[0], b.frames, a + (c - a) * t * std::clamp(b.param(k.smooth), 0.0, 1.0));
        return true;
    }

private:
    double phase_ = 0.0;
    uint64_t cycle_ = 0;
    mod::Ramp out_;
};

// ---- Macros ----
struct MacroLayout : Layout {
    MacroLayout() {
        for (uint32_t m = 0; m < kMacros; ++m)
            p.num("macro" + std::to_string(m + 1), "Macro " + std::to_string(m + 1), 0.0, 0.0, 1.0);
        finish("org.caw.mod.macros", "Macros", false, false, {"m1", "m2", "m3", "m4", "m5", "m6", "m7", "m8"});
    }
};
const MacroLayout& macroLayout() {
    static const MacroLayout l;
    return l;
}

class Macros final : public mod::Modulator {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return macroLayout().desc; }

protected:
    bool render(const mod::Block& b) noexcept override {  // each knob as it ramps (its own smoothing)
        for (uint32_t m = 0; m < kMacros && m < b.outputCount; ++m) {
            const ParameterValue* v = b.parameters && m < b.parameterCount ? &b.parameters[m] : nullptr;
            for (uint32_t i = 0; i < b.frames; ++i)
                b.outputs[m][i] = static_cast<float>(v ? (v->samples ? v->samples[i] : v->value) : 0.0);
        }
        return true;
    }
};

// ---- MIDI to CV ----
struct MidiLayout : Layout {
    uint32_t low, high, glide, priority;
    MidiLayout() {
        plain(p.num("low", "Lowest note", 36.0, 0.0, 127.0)).step = 1.0;
        plain(p.num("high", "Highest note", 96.0, 0.0, 127.0)).step = 1.0;
        p.num("glide", "Glide", 0.0, 0.0, 2.0, "s");
        plain(p.pick("priority", "Priority", 0.0, kPriorities));
        low = at("low"), high = at("high"), glide = at("glide"), priority = at("priority");
        finish("org.caw.mod.midi", "MIDI to CV", true, false, {"pitch", "velocity", "gate", "pressure"});
    }
};
const MidiLayout& midiLayout() {
    static const MidiLayout l;
    return l;
}

class MidiToCv final : public mod::Modulator {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return midiLayout().desc; }
    void reset() noexcept override {
        held_.clear();
        pitch_ = target_ = velocity_ = pressure_ = 0.0;
        fresh_ = true;
    }

protected:
    bool render(const mod::Block& b) noexcept override {
        const MidiLayout& k = midiLayout();
        const double lo = b.param(k.low, 36.0), hi = b.param(k.high, 96.0);
        const double span = hi > lo ? hi - lo : 1.0;
        const double glide = b.param(k.glide);
        const double coef = glide > 0.0 ? 1.0 - std::exp(-1.0 / (glide * b.sampleRate)) : 1.0;
        const int priority = static_cast<int>(b.param(k.priority) + 0.5);
        uint32_t e = 0;
        float* outs[4] = {};
        for (uint32_t o = 0; o < 4; ++o) outs[o] = o < b.outputCount ? b.outputs[o] : nullptr;
        for (uint32_t i = 0; i < b.frames; ++i) {
            for (; e < b.notes.count && b.notes.events[e].frame <= i; ++e) {
                const mod::NoteMessage m = mod::decode(b.notes.events[e]);
                if (m.kind == mod::NoteMessage::Kind::ChannelPressure || m.kind == mod::NoteMessage::Kind::PolyPressure) {
                    pressure_ = m.value;
                    continue;
                }
                if (!held_.apply(m)) continue;
                const mod::HeldNotes::Note* n = priority == 1 ? held_.highest() : priority == 2 ? held_.lowest() : held_.last();
                if (n) {
                    target_ = std::clamp((n->key - lo) / span, 0.0, 1.0);
                    velocity_ = n->velocity;
                    if (fresh_) pitch_ = target_, fresh_ = false;
                } else {
                    pressure_ = 0.0;
                }
            }
            pitch_ += (target_ - pitch_) * coef;
            if (outs[0]) outs[0][i] = static_cast<float>(pitch_);
            if (outs[1]) outs[1][i] = static_cast<float>(velocity_);
            if (outs[2]) outs[2][i] = held_.any() ? 1.0f : 0.0f;
            if (outs[3]) outs[3][i] = static_cast<float>(pressure_);
        }
        return true;
    }

private:
    mod::HeldNotes held_;
    double pitch_ = 0.0, target_ = 0.0, velocity_ = 0.0, pressure_ = 0.0;
    bool fresh_ = true;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerBuiltinModulators(ModuleRegistry& registry) {
    registry.add(lfoLayout().desc, &make<Lfo>);
    registry.add(envLayout().desc, &make<Envelope>);
    registry.add(followLayout().desc, &make<Follower>);
    registry.add(stepsLayout().desc, &make<Steps>);
    registry.add(randomLayout().desc, &make<Random>);
    registry.add(macroLayout().desc, &make<Macros>);
    registry.add(midiLayout().desc, &make<MidiToCv>);
}

}  // namespace caw
