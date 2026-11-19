// The Filter's Wah variant (1.1.0): a resonant band-pass swept by the playing (auto-wah) or by a pedal knob.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <span>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/eq.hpp"
#include "fx_merged.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0); C.A.W's own curves, not measured from any pedal.
// One trapezoidal state-variable filter per side (Zavalishin's TPT SVF, as the EQ's bands): its band-pass,
// normalised to unity at the peak, plus a little of its low-pass (a wah keeps some body), mixed with the dry.
// Mode Envelope: the input's level (a peak follower with Attack and Release) moves the sweep, Sensitivity setting
// how loud a note must be to open it fully, Range how far it goes, Direction up or down (auto-wah). Mode Pedal:
// the `pedal` knob (0 heel, 1 toe) is the position, so a knob, an automation lane, a MIDI controller (an
// expression pedal) or React to... moves it. Each Curve is a sweep range, a Q at heel and at toe (Resonance scales
// both) and a taper:
//   Classic 400 Hz..2.2 kHz, Q 4..7; Vintage 450 Hz..1.7 kHz, Q 6..9 (narrower, vocal); Bass 150 Hz..1.1 kHz, Q
//   3..5, more low end kept; Wide 250 Hz..4 kHz, Q 2.5..5 (a synth-style sweep).
// The frequency and Q follow at control rate (16 frames, glided over about 5 ms), the coefficients from detTan
// (the same bits on every platform); the TPT filter stays stable however fast they move.

namespace caw::fx {

namespace {

enum WahParam : uint32_t { kMode, kCurve, kPedal, kSens, kAttack, kRelease, kRange, kDirection, kResonance, kMix, kOutput, kCount };
constexpr std::string_view kModes[] = {"Envelope", "Pedal"};
constexpr std::string_view kCurves[] = {"Classic", "Vintage", "Bass", "Wide"};
constexpr std::string_view kDirections[] = {"Up", "Down"};

struct Curve {
    double lowHz, highHz, qHeel, qToe, low, taper;  // low: the low-pass share kept; taper: position^taper
};
constexpr Curve kCurveTable[] = {
    {400.0, 2200.0, 4.0, 7.0, 0.12, 1.0},
    {450.0, 1700.0, 6.0, 9.0, 0.06, 1.25},
    {150.0, 1100.0, 3.0, 5.0, 0.35, 0.9},
    {250.0, 4000.0, 2.5, 5.0, 0.15, 1.0},
};

const ParamTable& wahParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 0.0, kModes);
        p.pick("curve", "Curve", 0.0, kCurves);
        p.num("pedal", "Pedal", 0.5, 0.0, 1.0);
        p.num("sensitivity", "Sensitivity", 0.6, 0.0, 1.0);
        p.expo("attack", "Attack", 8.0, 1.0, 200.0, "ms");
        p.expo("release", "Release", 120.0, 10.0, 2000.0, "ms");
        p.num("range", "Range", 1.0, 0.0, 1.0);
        p.pick("direction", "Direction", 0.0, kDirections);
        p.num("resonance", "Resonance", 0.5, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}

const ModuleDescriptor& wahBaseDescriptor() {
    static const ModuleDescriptor d = withCpu(effectDescriptor("org.caw.filter", "Filter", wahParams(), 0, 0), CpuClass::Light);
    return d;
}

class Wah final : public EffectBase {
public:
    explicit Wah(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        glide_ = 1.0 - detExp(-static_cast<double>(kControlFrames) / (0.005 * sr));
        return true;
    }
    void clearState() noexcept override {
        left_.clear(), right_.clear();
        env_ = 0.0;
        first_ = true;
        mix_.reset(), out_.reset();
    }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const bool same = knobsUnchanged(knobs_, kCount, at);
        if (same && !first_ && mode_ == 1 && settled_) return;  // a parked pedal: nothing moves
        if (!same || first_) {
            mode_ = std::clamp(choice(kMode, at), 0, 1);
            curve_ = kCurveTable[std::clamp(choice(kCurve, at), 0, 3)];
            sensGain_ = lib::dbToGain(std::clamp(param(kSens, at), 0.0, 1.0) * 40.0);
            atk_ = 1.0 - detExp(-1.0 / (std::max(1.0, param(kAttack, at)) * 0.001 * sr));
            rel_ = 1.0 - detExp(-1.0 / (std::max(10.0, param(kRelease, at)) * 0.001 * sr));
            range_ = std::clamp(param(kRange, at), 0.0, 1.0);
            down_ = choice(kDirection, at) == 1;
            res_ = 0.5 + std::clamp(param(kResonance, at), 0.0, 1.0);
            mixTarget_ = std::clamp(param(kMix, at), 0.0, 1.0);
            outTarget_ = lib::dbToGain(param(kOutput, at));
            pedal_ = std::clamp(param(kPedal, at), 0.0, 1.0);
        }
        double p = pedal_;
        if (mode_ == 0) {
            levelDb_ = lib::gainToDb(env_);
            const double x = std::min(1.0, env_ * sensGain_);
            p = range_ * std::sqrt(x);
            if (down_) p = 1.0 - p;
        }
        // Position, glided, then the curve's frequency and Q.
        if (first_) pos_ = p;
        else pos_ += (p - pos_) * glide_;
        settled_ = std::fabs(p - pos_) < 1e-6;
        if (settled_) pos_ = p;
        const double t = detPow(std::clamp(pos_, 0.0, 1.0), curve_.taper);
        hz_ = curve_.lowHz * detPow(curve_.highHz / curve_.lowHz, t);
        const double q = (curve_.qHeel + (curve_.qToe - curve_.qHeel) * t) * res_;
        const double g = detTan(kPi * std::min(hz_, 0.45 * sr) / sr), k = 1.0 / q;
        coef_.set(g, k, 0.0, k, curve_.low);
        mix_.set(mixTarget_, kControlFrames);
        out_.set(outTarget_, kControlFrames);
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        if (mode_ == 0) {  // the level the sweep follows: the louder side, a peak with attack and release
            double e = env_;
            for (uint32_t i = 0; i < n; ++i) {
                const double a = std::max(std::fabs(static_cast<double>(inL[i])), std::fabs(static_cast<double>(inR[i])));
                const double c = a > e ? atk_ : rel_;
                e += (a - e) * c;
            }
            env_ = e < 1e-12 || !(e == e) ? 0.0 : e;
        }
        lib::SvfState l = left_, r = right_;
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i] == inL[i] ? inL[i] : 0.0, xr = inR[i] == inR[i] ? inR[i] : 0.0;
            const double yl = l.process(coef_, xl), yr = r.process(coef_, xr);
            const double m = mix_.next(), o = out_.next();
            outL[i] = static_cast<float>((xl + (yl - xl) * m) * o);
            outR[i] = static_cast<float>((xr + (yr - xr) * m) * o);
        }
        left_ = l, right_ = r;
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(hz_);
        out[3] = static_cast<float>(pos_);
        out[4] = static_cast<float>(mode_ == 0 ? levelDb_ : -120.0);
        out[5] = static_cast<float>(mode_);
        out[6] = static_cast<float>(curve_.lowHz);
        out[7] = static_cast<float>(curve_.highHz);
        out[8] = static_cast<float>(lib::gainToDb(outTarget_));
        return 9;
    }

private:
    const ModuleDescriptor& d_;
    double knobs_[kCount] = {};
    lib::SvfMix coef_;
    lib::SvfState left_, right_;
    Curve curve_ = kCurveTable[0];
    int mode_ = 0;
    bool down_ = false, first_ = true, settled_ = false;
    double sensGain_ = 1, atk_ = 1, rel_ = 1, range_ = 1, res_ = 1, mixTarget_ = 1, outTarget_ = 1, pedal_ = 0.5;
    double env_ = 0, levelDb_ = -120, pos_ = 0, hz_ = 1000, glide_ = 1;
    Ramp mix_, out_;
};

using V = std::vector<std::pair<std::string_view, double>>;
const std::vector<BuiltinPreset>& wahList() {
    static const std::vector<BuiltinPreset> p = {
        {"Funk auto-wah", "Guitar: quick quack on every strum", V{{"mode", 0}, {"curve", 0}, {"sensitivity", 0.7}, {"attack", 4}, {"release", 90}, {"variant", 3}}},
        {"Slow bloom wah", "Guitar: notes open slowly as they ring", V{{"mode", 0}, {"curve", 1}, {"sensitivity", 0.6}, {"attack", 60}, {"release", 400}, {"variant", 3}}},
        {"Bass envelope", "Bass: a round, low auto-wah that keeps the bottom", V{{"mode", 0}, {"curve", 2}, {"sensitivity", 0.65}, {"attack", 6}, {"release", 150}, {"variant", 3}}},
        {"Down sweep quack", "Guitar: closes as you hit harder, opens as it fades", V{{"mode", 0}, {"curve", 0}, {"direction", 1}, {"sensitivity", 0.7}, {"variant", 3}}},
        {"Synth sweep", "Sound design: a wide, resonant sweep from the playing", V{{"mode", 0}, {"curve", 3}, {"resonance", 0.8}, {"sensitivity", 0.75}, {"release", 250}, {"variant", 3}}},
        {"Pedal: classic", "Guitar: map an expression pedal or a knob to Pedal", V{{"mode", 1}, {"curve", 0}, {"pedal", 0.5}, {"variant", 3}}},
        {"Pedal: vintage vocal", "Guitar: a narrow, vocal sweep under your foot", V{{"mode", 1}, {"curve", 1}, {"pedal", 0.5}, {"resonance", 0.6}, {"variant", 3}}},
        {"Parked wah", "Guitar: the pedal parked half way, a fixed nasal tone", V{{"mode", 1}, {"curve", 0}, {"pedal", 0.6}, {"resonance", 0.4}, {"variant", 3}}},
        {"Drum loop wah", "Drums: an auto-wah on a loop, half wet", V{{"mode", 0}, {"curve", 3}, {"sensitivity", 0.5}, {"attack", 2}, {"release", 80}, {"mix", 0.5}, {"variant", 3}}},
        {"Lo-fi talk box", "Lo-fi: a slow, deep, talking sweep", V{{"mode", 0}, {"curve", 1}, {"resonance", 1}, {"attack", 30}, {"release", 300}, {"output", 2}, {"variant", 3}}},
    };
    return p;
}

}  // namespace

const ModuleDescriptor& wahVariantDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(wahBaseDescriptor(), "org.caw.filter", "Filter", labels, index);
    return d;
}
ModuleProcessor* makeWahAs(const ModuleDescriptor& variant) noexcept { return new (std::nothrow) Wah(variant); }
std::span<const BuiltinPreset> wahPresets() { return wahList(); }

}  // namespace caw::fx
