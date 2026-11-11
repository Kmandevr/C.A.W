// The formant filter ("org.caw.formant", vowels on an XY pad) and the disperser ("org.caw.disperser", an all-pass chain) of the EQ & Filter group.
#include "builtin_fx_filters.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/formant.hpp"

// Original code (C.A.W. is Apache-2.0). The formant filter is the source-filter model of a vowel (Fant, "Acoustic
// Theory of Speech Production", 1960): parallel resonances at the first three formants. The disperser is a cascade
// of second-order all-passes at one frequency (Smith, "Introduction to Digital Filters", CCRMA, "Allpass Filters"):
// flat in level, each stage adding group delay around the frequency, so a chain of many smears a transient into a
// chirp.

namespace caw::fx {

namespace {

using filters::lane;
using filters::Pair;
using filters::pairOf;

// A TPT state-variable filter step (12 dB/octave), shared by both effects: low, band (un-normalised) out.
struct SvfCoefs {
    double a1 = 1, a2 = 0, a3 = 0, k = 1;
    void set(double hz, double q, double sr) noexcept {
        const double f = std::clamp(hz, 10.0, 0.49 * sr);
        const double g = detTan(kPi * f / sr);
        k = 1.0 / std::clamp(q, 0.05, 100.0);
        a1 = 1.0 / (1.0 + g * (g + k));
        a2 = g * a1;
        a3 = g * a2;
    }
};
struct SvfState {
    double ic1 = 0, ic2 = 0;
    void step(const SvfCoefs& c, double x, double& band, double& low) noexcept {
        const double v3 = x - ic2;
        band = c.a1 * ic1 + c.a2 * v3;
        low = ic2 + c.a2 * ic1 + c.a3 * v3;
        ic1 = 2.0 * band - ic1;
        ic2 = 2.0 * low - ic2;
    }
    void clear() noexcept { ic1 = ic2 = 0.0; }
    void flush() noexcept {
        if (ic1 < 1e-20 && ic1 > -1e-20) ic1 = 0.0;
        if (ic2 < 1e-20 && ic2 > -1e-20) ic2 = 0.0;
    }
};

// ---------- Formant ----------

enum FormantParam : uint32_t { kFX, kFY, kFShift, kFQ, kFLows, kFHighs, kFMix, kFOutput, kFCount };

// Where the vowels sit on the pad, as on the IPA vowel chart: front to the left, back to the right, closed at the
// top (y 0), open at the bottom (y 1). In lib::kVowelFormantsHz's order: A, E, I, O, U.
constexpr double kVowelXY[5][2] = {{0.6, 1.0}, {0.15, 0.5}, {0.0, 0.0}, {0.85, 0.5}, {1.0, 0.0}};
// The formants' levels (F2 and F3 are quieter than F1 in speech), F1 6 dB up: three narrow peaks keep only a
// slice of a broad sound, so a vowel comes out near the level that went in.
constexpr double kFormantLevel[3] = {2.0, 1.4, 0.9};

const ParamTable& formantParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("vowel_x", "Vowel X", 0.6, 0.0, 1.0);
        p.num("vowel_y", "Vowel Y", 1.0, 0.0, 1.0);
        p.num("shift", "Gender / shift", 0.0, -12.0, 12.0, "st");
        p.expo("q", "Q", 8.0, 1.0, 30.0);
        p.num("lows", "Lows", 0.0, 0.0, 1.0);
        p.num("highs", "Highs", 0.0, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& formantDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.formant", "Formant filter", formantParams(), 0, 0);
    return d;
}

// The three formants at pad point (x, y): each vowel weighted by 1 / (d^2 + e)^2 (inverse distance, so the pad
// lands on a vowel exactly at its point and morphs smoothly between), averaged in log frequency.
void formantsAt(double x, double y, double hz[3]) noexcept {
    double w[5], total = 0.0;
    for (int v = 0; v < 5; ++v) {
        const double dx = x - kVowelXY[v][0], dy = y - kVowelXY[v][1], d2 = dx * dx + dy * dy + 1e-5;
        w[v] = 1.0 / (d2 * d2);
        total += w[v];
    }
    for (int f = 0; f < 3; ++f) {
        double l = 0.0;
        for (int v = 0; v < 5; ++v) l += w[v] * detLog(lib::kVowelFormantsHz[v][f]);
        hz[f] = detExp(l / total);
    }
}

class FormantEffect final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return formantDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) {
            for (SvfState& s : band_[c]) s.clear();
            low_[c].clear(), high_[c].clear();
        }
        mix_.reset(), out_.reset(), lows_.reset(), highs_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        for (int c = 0; c < 2; ++c) {  // subnormal tails, at the grid
            for (SvfState& s : band_[c]) s.flush();
            low_[c].flush(), high_[c].flush();
        }
        x_ = std::clamp(param(kFX, at), 0.0, 1.0);
        y_ = std::clamp(param(kFY, at), 0.0, 1.0);
        formantsAt(x_, y_, hz_);
        const double shift = detPow(2.0, std::clamp(param(kFShift, at), -12.0, 12.0) / 12.0);
        const double q = std::clamp(param(kFQ, at), 1.0, 30.0);
        for (int f = 0; f < 3; ++f) {
            hz_[f] = std::min(hz_[f] * shift, 0.45 * sr);
            coefs_[f].set(hz_[f], q, sr);
        }
        lowC_.set(hz_[0] * 0.7, 0.707, sr);
        highC_.set(std::min(hz_[2] * 1.4, 0.45 * sr), 0.707, sr);
        lows_.set(std::clamp(param(kFLows, at), 0.0, 1.0), kControlFrames);
        highs_.set(std::clamp(param(kFHighs, at), 0.0, 1.0), kControlFrames);
        mix_.set(std::clamp(param(kFMix, at), 0.0, 1.0), kControlFrames);
        out_.set(lib::dbToGain(std::clamp(param(kFOutput, at), -24.0, 24.0)), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double lows = lows_.next(), highs = highs_.next(), mix = mix_.next(), out = out_.next();
            const double x[2] = {finiteOr0(inL[i]), finiteOr0(inR[i])};
            double y[2];
            for (int c = 0; c < 2; ++c) {
                double wet = 0.0, band, low;
                for (int f = 0; f < 3; ++f) {
                    band_[c][f].step(coefs_[f], x[c], band, low);
                    wet += kFormantLevel[f] * coefs_[f].k * band;  // k x band: unity at its formant, then its level
                }
                low_[c].step(lowC_, x[c], band, low);
                wet += lows * low;
                high_[c].step(highC_, x[c], band, low);
                wet += highs * (x[c] - highC_.k * band - low);
                y[c] = x[c] + (wet * out - x[c]) * mix;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        for (int f = 0; f < 3; ++f) out[2 + f] = static_cast<float>(hz_[f]);
        out[5] = static_cast<float>(x_);
        out[6] = static_cast<float>(y_);
        return 7;
    }

private:
    SvfCoefs coefs_[3], lowC_, highC_;
    SvfState band_[2][3], low_[2], high_[2];
    double hz_[3] = {730, 1090, 2440}, x_ = 0.6, y_ = 1.0;
    Ramp mix_, out_, lows_, highs_;
};

ModuleProcessor* makeFormant() noexcept { return new (std::nothrow) FormantEffect(); }

// ---------- Disperser ----------

enum DisperserParam : uint32_t { kDAmount, kDFreq, kDPinch, kDSpread, kDMix, kDCount };
constexpr int kMaxStages = 64;

const ParamTable& disperserParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("amount", "Amount", 0.5, 0.0, 1.0);
        p.expo("freq", "Frequency", 1000.0, 20.0, 20000.0, "Hz");
        p.num("pinch", "Pinch", 0.3, 0.0, 1.0);
        p.num("spread", "Spread", 0.0, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& disperserDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.disperser", "Disperser", disperserParams(), 0, 0);
    return d;
}

// Amount 0..1 runs 0..64 stages, between whole counts as a blend of the chain's outputs either side (the chain
// computes every count's output on the way, so a moving amount glides with no click). Pinch is the stages' Q,
// 0.3 .. 9: a high Q bunches the delay tight around the frequency (a sharper "zap").
class Disperser final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return disperserDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        for (int s = 0; s < kMaxStages; ++s) ic1_[s] = ic2_[s] = pairOf(0.0, 0.0);
        stages_.reset(), mix_.reset();
        live_ = 0;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        for (int s = 0; s < live_; ++s) ic1_[s] = filters::flushPair(ic1_[s]), ic2_[s] = filters::flushPair(ic2_[s]);  // at the grid
        freq_ = std::clamp(param(kDFreq, at), 20.0, 0.45 * sr);
        q_ = 0.3 * detPow(30.0, std::clamp(param(kDPinch, at), 0.0, 1.0));
        spread_ = std::clamp(param(kDSpread, at), 0.0, 1.0);
        SvfCoefs l, r;
        l.set(freq_, q_, sr);
        r.set(std::min(freq_ * detPow(2.0, spread_), 0.45 * sr), q_, sr);  // the right side up to an octave higher
        a1_ = pairOf(l.a1, r.a1), a2_ = pairOf(l.a2, r.a2), a3_ = pairOf(l.a3, r.a3), k2_ = pairOf(2.0 * l.k, 2.0 * r.k);
        const double from = stages_.fresh ? -1.0 : stages_.value;
        count_ = std::clamp(param(kDAmount, at), 0.0, 1.0) * kMaxStages;
        stages_.set(count_, kControlFrames);
        // Stages the next 16 frames use; those dropped out are cleared, so they come back in clean.
        const double most = std::max(from, count_);
        const int live = std::min(kMaxStages, static_cast<int>(std::ceil(most)));
        for (int s = live; s < live_; ++s) ic1_[s] = ic2_[s] = pairOf(0.0, 0.0);
        live_ = live;
        mix_.set(std::clamp(param(kDMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double count = std::clamp(stages_.next(), 0.0, static_cast<double>(live_)), mix = mix_.next();
            const int whole = static_cast<int>(count);
            const double frac = count - whole;
            const Pair x = pairOf(finiteOr0(inL[i]), finiteOr0(inR[i]));
            // Both sides at once through the chain: all-pass y = v - 2 k band per stage, the outputs either side of
            // the count kept on the way.
            Pair v = x, below = x, above = x;
            const Pair two = pairOf(2.0, 2.0);
            for (int s = 0; s < live_; ++s) {
                const Pair v3 = v - ic2_[s];
                const Pair band = a1_ * ic1_[s] + a2_ * v3;
                const Pair low = ic2_[s] + a2_ * ic1_[s] + a3_ * v3;
                ic1_[s] = two * band - ic1_[s];
                ic2_[s] = two * low - ic2_[s];
                v = v - k2_ * band;
                if (s + 1 == whole) below = v;
                if (s == whole) above = v;
            }
            if (whole >= live_) above = below = v;
            const Pair wet = below + (above - below) * pairOf(frac, frac);
            const double y[2] = {lane(x, 0) + (lane(wet, 0) - lane(x, 0)) * mix, lane(x, 1) + (lane(wet, 1) - lane(x, 1)) * mix};
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(count_);
        out[3] = static_cast<float>(freq_);
        out[4] = static_cast<float>(q_);
        out[5] = static_cast<float>(spread_);
        return 6;
    }

private:
    Pair ic1_[kMaxStages], ic2_[kMaxStages];  // each stage's two states, left and right side by side
    Pair a1_ = pairOf(1, 1), a2_ = pairOf(0, 0), a3_ = pairOf(0, 0), k2_ = pairOf(2, 2);
    Ramp stages_, mix_;
    int live_ = 0;
    double count_ = 32.0, freq_ = 1000.0, q_ = 0.8, spread_ = 0.0;
};

ModuleProcessor* makeDisperser() noexcept { return new (std::nothrow) Disperser(); }

}  // namespace

void registerFormantAndDisperser(ModuleRegistry& registry) {
    registry.add(formantDescriptor(), &makeFormant);
    registry.add(disperserDescriptor(), &makeDisperser);
}

}  // namespace caw::fx
