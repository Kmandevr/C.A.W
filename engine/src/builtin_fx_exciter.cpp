// Glint (org.caw.exciter, 1.1.0): Exciter adds harmonics to the highs; Bass adds the lows' harmonics so bass is heard on small speakers.
#include "builtin_effects.h"
#include "builtin_fx_voice.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <span>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/oversample.hpp"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0). Both modes make harmonics the same way: a band of the input (the highs
// above Frequency, or the lows below it) is divided by its own peak envelope (instant attack), so it swings within
// -1..1 whatever its level; Chebyshev polynomials of that (T2 = 2u^2 - 1 the 2nd harmonic of a sine, T3 = 4u^3 - 3u
// the 3rd, T4, T5) are weighted by Character (even to odd) and Density, and multiplied back by the envelope. The
// harmonics therefore follow the band's level in a straight line (no drive knob, no level-dependent tone), and for
// a sine their levels are exactly the weights, which is what the harmonics bars show.
// - Exciter: the band is a 12 dB/octave high-pass at Frequency (800 Hz..12 kHz); only T2 and T3, at 2x oversampling
//   (the Library's polyphase IIR half-band, no latency) at Normal and High quality, which keeps a cubic alias-free
//   up to the old Nyquist; Eco runs at the base rate. The harmonics are high-passed again at Frequency (the DC
//   and slow envelope of the even part, any difference tones) and low-passed by Tone (off at 20 kHz, the
//   default), then added by Amount.
// - Bass: the band is the mid's lows (two 12 dB/octave low-passes at Frequency, 40..250 Hz); T2..T5 (Density adds
//   T4 and T5), band-passed Frequency..6 x Frequency (one SVF band-pass stage), added to both sides; Cut lows crossfades the dry signal to
//   itself high-passed at Frequency (24 dB/octave, per side; it runs only while Cut lows is up): headroom on small
//   speakers that can't play the lows anyway. Harmonics of bass need no
//   oversampling. The psychoacoustic effect (the missing fundamental: harmonics imply the pitch below them) is
//   textbook (e.g. Moore, "An Introduction to the Psychology of Hearing"); no product's design is copied.

namespace caw::fx {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr std::string_view kId = "org.caw.exciter";
constexpr std::string_view kName = "Exciter";
constexpr std::string_view kVariants[] = {"Exciter", "Bass"};
constexpr uint32_t kBars = 8;  // harmonics 2..9 shown

enum ExParam : uint32_t { exFreq, exAmount, exCharacter, exTone, exListen, exOutput, exCount };
enum BaParam : uint32_t { baFreq, baAmount, baCharacter, baDensity, baCut, baListen, baOutput, baCount };

const ParamTable& exciterParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("freq", "Frequency", 3000.0, 800.0, 12000.0, "Hz");
        p.num("amount", "Amount", 0.35, 0.0, 1.0);
        p.num("character", "Character", 0.4, 0.0, 1.0);  // 0 even (warm), 1 odd (bright)
        p.expo("tone", "Tone", 20000.0, 2000.0, 20000.0, "Hz");  // 20 kHz: off
        p.pick("listen", "Listen", 0.0, kOffOn);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ParamTable& bassParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("freq", "Frequency", 100.0, 40.0, 250.0, "Hz");
        p.num("amount", "Amount", 0.4, 0.0, 1.0);
        p.num("character", "Character", 0.3, 0.0, 1.0);
        p.num("density", "Density", 0.3, 0.0, 1.0);
        p.num("cut", "Cut lows", 0.0, 0.0, 1.0);
        p.pick("listen", "Listen", 0.0, kOffOn);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}

const ModuleDescriptor& exciterBase() {
    static const ModuleDescriptor d = withCpu(effectDescriptor(kId, kName, exciterParams(), 0, 0), CpuClass::Medium);  // 2x oversampled
    return d;
}
const ModuleDescriptor& bassBase() {
    static const ModuleDescriptor d = withCpu(effectDescriptor(kId, kName, bassParams(), 0, 0), CpuClass::Light);
    return d;
}
const ModuleDescriptor& exciterVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(exciterBase(), kId, kName, kVariants, 0);
    return d;
}
const ModuleDescriptor& bassVariant() {
    static const ModuleDescriptor& d = legacyVariantDescriptor(bassBase(), kId, kName, kVariants, 1);
    return d;
}

// A TPT SVF stage's coefficients: high-pass, low-pass (Q 0.7071: Butterworth).
lib::SvfMix highPass(double hz, double sr) {
    lib::SvfMix m;
    const double g = detTan(kPi * std::min(hz, 0.45 * sr) / sr), k = 1.4142135623730951;
    m.set(g, k, 1.0, -k, -1.0);
    return m;
}
lib::SvfMix lowPass(double hz, double sr) {
    lib::SvfMix m;
    const double g = detTan(kPi * std::min(hz, 0.45 * sr) / sr);
    m.set(g, 1.4142135623730951, 0.0, 0.0, 1.0);
    return m;
}

inline double finite0(float x) noexcept { return x == x && x - x == 0.0f ? static_cast<double>(x) : 0.0; }

// Harmonics from u in -1..1 (the band over its envelope): the Chebyshev polynomials, weighted.
struct Weights {
    double w2 = 0, w3 = 0, w4 = 0, w5 = 0;
    double shape(double u) const noexcept {
        u = u > 1.0 ? 1.0 : (u < -1.0 ? -1.0 : u);
        const double u2 = u * u;
        const double t2 = 2.0 * u2 - 1.0, t3 = (4.0 * u2 - 3.0) * u;
        const double t4 = 8.0 * u2 * u2 - 8.0 * u2 + 1.0, t5 = ((16.0 * u2 - 20.0) * u2 + 5.0) * u;
        return w2 * t2 + w3 * t3 + w4 * t4 + w5 * t5;
    }
};

// What both modes share: the knobs read on change, the wet and output ramps, the display's bars.
class GlintBase : public EffectBase {
public:
    explicit GlintBase(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    void clearBase() noexcept {
        wet_.reset(), out_.reset();
        env_[0] = env_[1] = 0.0;
        first_ = true;
    }
    uint32_t fillBars(float* out, int mode, double hz, int oversample) noexcept {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(mode);
        out[3] = static_cast<float>(hz);
        out[4] = static_cast<float>(lib::gainToDb(bandPeak_));
        out[5] = static_cast<float>(lib::gainToDb(harmPeak_));
        out[6] = static_cast<float>(amount_);
        out[7] = static_cast<float>(kBars);
        const double w[kBars] = {w_.w2, w_.w3, w_.w4, w_.w5, 0, 0, 0, 0};
        for (uint32_t k = 0; k < kBars; ++k) out[8 + k] = static_cast<float>(lib::gainToDb(std::fabs(w[k]) * wetGain_));
        out[16] = static_cast<float>(oversample);
        bandPeak_ = harmPeak_ = 0.0;
        return 17;
    }
    void setWeights(double character, double density) noexcept {
        const double c = std::clamp(character, 0.0, 1.0), dn = std::clamp(density, 0.0, 1.0);
        w_.w2 = 1.0 - c, w_.w3 = c;
        w_.w4 = 0.5 * dn * (1.0 - c), w_.w5 = 0.5 * dn * c;
        const double sum = w_.w2 + w_.w3 + w_.w4 + w_.w5;
        w_.w2 /= sum, w_.w3 /= sum, w_.w4 /= sum, w_.w5 /= sum;
    }

    const ModuleDescriptor& d_;
    Weights w_;
    Ramp wet_, out_;
    double env_[2] = {};
    double rel_ = 0.999, amount_ = 0, wetGain_ = 0, outGain_ = 1;
    double bandPeak_ = 0, harmPeak_ = 0;
    bool listen_ = false, first_ = true;
};

class Exciter final : public GlintBase {
public:
    using GlintBase::GlintBase;

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        rel_ = detExp(-1.0 / (0.010 * sr));  // 10 ms: a few cycles of the lowest band
        return true;
    }
    void clearState() noexcept override {
        clearBase();
        for (int s = 0; s < 2; ++s) {
            pre_[s].clear(), post_[s].clear(), tone_[s].clear();
            os_[s].clear();
        }
    }
    void control(uint32_t at) noexcept override {
        if (knobsUnchanged(knobs_, exCount, at) && !first_) {
            wet_.set(wetGain_, kControlFrames), out_.set(outGain_, kControlFrames);
            return;
        }
        const double sr = rate();
        hz_ = std::clamp(param(exFreq, at), 800.0, 12000.0);
        pre_c_ = highPass(hz_, sr);
        post_c_ = highPass(hz_, sr);
        const double tone = std::clamp(param(exTone, at), 2000.0, 20000.0);
        if (tone < 20000.0 && !toneOn_) tone_[0].clear(), tone_[1].clear();
        toneOn_ = tone < 20000.0;  // 20 kHz: off (the tone filter doesn't run)
        tone_c_ = lowPass(tone, sr);
        amount_ = std::clamp(param(exAmount, at), 0.0, 1.0);
        setWeights(param(exCharacter, at), 0.0);
        listen_ = on(exListen, at);
        wetGain_ = 2.0 * amount_;
        outGain_ = lib::dbToGain(param(exOutput, at));
        wet_.set(wetGain_, kControlFrames), out_.set(outGain_, kControlFrames);
        first_ = false;
    }
    // In stages over the run (at most 16 frames), both sides in each loop (two independent filter chains the CPU
    // overlaps): the band and its envelope, then the harmonics (2x: up, shape, down), then the post filters.
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const bool over = quality() != kQualityEco;
        oversample_ = over ? 2 : 1;
        double x[2][kControlFrames], band[2][kControlFrames], env[2][kControlFrames], inv[2][kControlFrames];
        double y[2][kControlFrames];
        double e0 = env_[0], e1 = env_[1], most = bandPeak_;
        lib::SvfState a0 = pre_[0], a1 = pre_[1];
        for (uint32_t i = 0; i < n; ++i) {
            const double l = finite0(inL[i]), r = finite0(inR[i]);
            x[0][i] = l, x[1][i] = r;
            const double v0 = a0.process(pre_c_, l), v1 = a1.process(pre_c_, r);
            const double m0 = std::fabs(v0), m1 = std::fabs(v1);
            e0 = m0 > e0 ? m0 : e0 * rel_;
            e1 = m1 > e1 ? m1 : e1 * rel_;
            e0 = e0 < 1e-15 ? 0.0 : e0;
            e1 = e1 < 1e-15 ? 0.0 : e1;
            most = std::max(most, std::max(m0, m1));
            band[0][i] = v0, band[1][i] = v1, env[0][i] = e0, env[1][i] = e1;
        }
        env_[0] = e0, env_[1] = e1, bandPeak_ = most;
        pre_[0] = a0, pre_[1] = a1;
        for (int s = 0; s < 2; ++s)
            for (uint32_t i = 0; i < n; ++i) inv[s][i] = env[s][i] > 0.0 ? 1.0 / env[s][i] : 0.0;
        for (int s = 0; s < 2; ++s) {
            if (over) {
                double up[2 * kControlFrames];
                os_[s].upBlock(band[s], up, static_cast<int>(n));
                for (uint32_t j = 0; j < 2 * n; ++j) up[j] = env[s][j >> 1] * w_.shape(up[j] * inv[s][j >> 1]);
                os_[s].downBlock(up, y[s], static_cast<int>(n));
            } else {
                for (uint32_t i = 0; i < n; ++i) y[s][i] = env[s][i] * w_.shape(band[s][i] * inv[s][i]);
            }
        }
        lib::SvfState p0 = post_[0], p1 = post_[1];
        for (uint32_t i = 0; i < n; ++i) y[0][i] = p0.process(post_c_, y[0][i]), y[1][i] = p1.process(post_c_, y[1][i]);
        post_[0] = p0, post_[1] = p1;
        if (toneOn_) {
            lib::SvfState t0 = tone_[0], t1 = tone_[1];
            for (uint32_t i = 0; i < n; ++i) y[0][i] = t0.process(tone_c_, y[0][i]), y[1][i] = t1.process(tone_c_, y[1][i]);
            tone_[0] = t0, tone_[1] = t1;
        }
        const double dry = listen_ ? 0.0 : 1.0;
        double hp = harmPeak_;
        for (uint32_t i = 0; i < n; ++i) {
            const double w = wet_.next(), o = out_.next();
            hp = std::max(hp, std::max(std::fabs(y[0][i]), std::fabs(y[1][i])) * w);
            outL[i] = static_cast<float>((dry * x[0][i] + w * y[0][i]) * o);
            outR[i] = static_cast<float>((dry * x[1][i] + w * y[1][i]) * o);
        }
        harmPeak_ = hp;
    }
    uint32_t fillDisplay(float* out, bool) noexcept override { return fillBars(out, 0, hz_, oversample_); }

private:
    double knobs_[exCount] = {};
    lib::SvfMix pre_c_, post_c_, tone_c_;
    lib::SvfState pre_[2], post_[2], tone_[2];
    bool toneOn_ = false;
    lib::Oversampler2x os_[2];
    double hz_ = 3000;
    int oversample_ = 2;
};

class BassExciter final : public GlintBase {
public:
    using GlintBase::GlintBase;

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        rel_ = detExp(-1.0 / (0.030 * sr));  // 30 ms: longer than a period of the lowest band
        return true;
    }
    void clearState() noexcept override {
        clearBase();
        lp_[0].clear(), lp_[1].clear(), hp_.clear();
        for (auto& side : dryHp_) side[0].clear(), side[1].clear();
        cut_.reset();
        cutting_ = false;
    }
    void control(uint32_t at) noexcept override {
        if (knobsUnchanged(knobs_, baCount, at) && !first_) {
            wet_.set(wetGain_, kControlFrames), out_.set(outGain_, kControlFrames), cut_.set(cutTarget_, kControlFrames);
            return;
        }
        const double sr = rate();
        hz_ = std::clamp(param(baFreq, at), 40.0, 250.0);
        lp_c_ = lowPass(hz_, sr);
        {  // the harmonics' band: one SVF band-pass at sqrt(6) x Frequency, Q 0.49 (Frequency..6 x Frequency)
            const double g = detTan(kPi * std::min(2.449 * hz_, 0.45 * sr) / sr), k = 1.0 / 0.49;
            hp_c_.set(g, k, 0.0, k, 0.0);
        }
        dryHp_c_ = highPass(hz_, sr);
        amount_ = std::clamp(param(baAmount, at), 0.0, 1.0);
        setWeights(param(baCharacter, at), param(baDensity, at));
        listen_ = on(baListen, at);
        wetGain_ = 2.0 * amount_;
        outGain_ = lib::dbToGain(param(baOutput, at));
        cutTarget_ = std::clamp(param(baCut, at), 0.0, 1.0);
        if (cutTarget_ > 0.0 && !cutting_) for (auto& side : dryHp_) side[0].clear(), side[1].clear();
        cutting_ = cutTarget_ > 0.0 || cut_.value > 0.0;
        wet_.set(wetGain_, kControlFrames), out_.set(outGain_, kControlFrames), cut_.set(cutTarget_, kControlFrames);
        first_ = false;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        lib::SvfState a = lp_[0], b = lp_[1], h1 = hp_;
        double e = env_[0];
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = finite0(inL[i]), xr = finite0(inR[i]);
            const double lows = b.process(lp_c_, a.process(lp_c_, 0.5 * (xl + xr)));
            const double mag = std::fabs(lows);
            e = mag > e ? mag : e * rel_;
            if (e < 1e-15) e = 0.0;
            bandPeak_ = std::max(bandPeak_, mag);
            double h = e > 0.0 ? e * w_.shape(lows / e) : 0.0;
            h = h1.process(hp_c_, h);
            const double w = wet_.next(), o = out_.next(), c = cut_.next();
            const double add = w * h;
            harmPeak_ = std::max(harmPeak_, std::fabs(add));
            double dl = xl, dr = xr;
            if (cutting_) {
                dl += c * (dryHp_[0][1].process(dryHp_c_, dryHp_[0][0].process(dryHp_c_, xl)) - xl);
                dr += c * (dryHp_[1][1].process(dryHp_c_, dryHp_[1][0].process(dryHp_c_, xr)) - xr);
            }
            if (listen_) dl = dr = 0.0;
            outL[i] = static_cast<float>((dl + add) * o);
            outR[i] = static_cast<float>((dr + add) * o);
        }
        lp_[0] = a, lp_[1] = b, hp_ = h1;
        env_[0] = e;
    }
    uint32_t fillDisplay(float* out, bool) noexcept override { return fillBars(out, 1, hz_, 1); }

private:
    double knobs_[baCount] = {};
    lib::SvfMix lp_c_, hp_c_;
    lib::SvfMix dryHp_c_;
    lib::SvfState lp_[2], hp_, dryHp_[2][2];
    Ramp cut_;
    double hz_ = 100, cutTarget_ = 0;
    bool cutting_ = false;
};

ModuleProcessor* makeExciter() noexcept { return new (std::nothrow) Exciter(exciterVariant()); }
ModuleProcessor* makeBass() noexcept { return new (std::nothrow) BassExciter(bassVariant()); }

const Variant kGlint[] = {{kVariants[0], &exciterVariant, &makeExciter}, {kVariants[1], &bassVariant, &makeBass}};
const MergedDevice kDevices[] = {{kId, kName, kGlint}};

using V = std::vector<std::pair<std::string_view, double>>;

}  // namespace

std::span<const MergedDevice> mergedVoiceDevices() { return kDevices; }
size_t exciterBytes() noexcept { return std::max(sizeof(Exciter), sizeof(BassExciter)); }

const std::vector<BuiltinPreset>& exciterPresets() {
    static const std::vector<BuiltinPreset> p = {
        // Exciter
        {"Vocal air", "Vocals: a breath of sparkle above 6 kHz", V{{"variant", 0}, {"freq", 6000}, {"amount", 0.3}, {"character", 0.35}}},
        {"Vocal presence", "Vocals: forward and clear, from 3 kHz", V{{"variant", 0}, {"freq", 3000}, {"amount", 0.25}, {"character", 0.5}, {"tone", 12000}}},
        {"Acoustic sheen", "Guitar: strings that shine without getting harsh", V{{"variant", 0}, {"freq", 4500}, {"amount", 0.35}, {"character", 0.3}}},
        {"Hi-hat sizzle", "Drums: crisp cymbals and hats", V{{"variant", 0}, {"freq", 8000}, {"amount", 0.4}, {"character", 0.6}}},
        {"Snare crack", "Drums: more bite on the snare", V{{"variant", 0}, {"freq", 2500}, {"amount", 0.35}, {"character", 0.7}, {"tone", 10000}}},
        {"Dull recording fix", "Mixing: bring back highs a recording lost", V{{"variant", 0}, {"freq", 5000}, {"amount", 0.55}, {"character", 0.4}}},
        {"Master polish", "Mastering: a little top-end shine on the mix", V{{"variant", 0}, {"freq", 9000}, {"amount", 0.15}, {"character", 0.3}}},
        {"Warm tape top", "Lo-fi: soft, even harmonics like tape", V{{"variant", 0}, {"freq", 2000}, {"amount", 0.4}, {"character", 0.0}, {"tone", 8000}}},
        {"Synth edge", "Sound design: a bright, odd-harmonic edge on a pad", V{{"variant", 0}, {"freq", 1500}, {"amount", 0.6}, {"character", 1.0}}},
        {"Harmonics only", "Mixing: hear just what it adds (Listen)", V{{"variant", 0}, {"freq", 4000}, {"amount", 0.5}, {"listen", 1}}},
        // Bass
        {"Small speaker bass", "Bass: heard on phone and laptop speakers", V{{"variant", 1}, {"freq", 100}, {"amount", 0.5}, {"character", 0.3}, {"density", 0.3}}},
        {"Phone-safe kick", "Drums: the kick still thumps on a phone, its sub trimmed", V{{"variant", 1}, {"freq", 80}, {"amount", 0.55}, {"cut", 0.4}, {"density", 0.4}}},
        {"808 growl", "Bass: an 808 that reads on any speaker", V{{"variant", 1}, {"freq", 70}, {"amount", 0.6}, {"character", 0.6}, {"density", 0.6}}},
        {"Bass guitar warmth", "Bass: round, even harmonics on a DI bass", V{{"variant", 1}, {"freq", 120}, {"amount", 0.35}, {"character", 0.1}, {"density", 0.2}}},
        {"Synth bass punch", "Bass: harmonics that carry a synth bass in a busy mix", V{{"variant", 1}, {"freq", 150}, {"amount", 0.45}, {"character", 0.5}}},
        {"Sub replace", "Mixing: lows swapped for their harmonics (headroom)", V{{"variant", 1}, {"freq", 90}, {"amount", 0.6}, {"cut", 0.8}, {"density", 0.5}}},
        {"Master bass lift", "Mastering: a touch of bass harmonics on the mix", V{{"variant", 1}, {"freq", 110}, {"amount", 0.2}, {"density", 0.2}}},
        {"Lo-fi radio bass", "Lo-fi: lows only as harmonics, like a small radio", V{{"variant", 1}, {"freq", 200}, {"amount", 0.7}, {"cut", 1.0}, {"character", 0.7}}},
        {"Bass harmonics only", "Mixing: hear just what it adds (Listen)", V{{"variant", 1}, {"freq", 100}, {"amount", 0.6}, {"listen", 1}}},
    };
    return p;
}

}  // namespace caw::fx
