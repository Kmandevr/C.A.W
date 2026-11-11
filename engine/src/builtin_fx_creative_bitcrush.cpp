// The bitcrusher (fx-creative): "org.caw.bitcrush", fewer bits and a lower sample rate with jitter, dither and the converters' anti-alias and anti-image filters.
#include <cmath>

#include "builtin_fx_creative.h"
#include "caw/library/filter.hpp"

// Original code (C.A.W. is Apache-2.0). A model of a cheap converter pair: an anti-alias low-pass (the ADC's),
// sample-and-hold at the reduced rate with a jittered clock, quantisation to 2^bits levels with optional TPDF
// dither (Lipshitz, Wannamaker and Vanderkooy, "Quantization and Dither: A Theoretical Survey", JAES 40(5), 1992),
// then an anti-image low-pass (the DAC's reconstruction filter). Both filters are 4-pole Butterworth (two of the
// Library's SVFs); at 0 they are out of the path, so the folded-back aliases and stair-step images, which are
// the point of a crusher, stay. Unlike the saturator's Crush mode (a plain bits-and-rate stage after drive), this
// one models the converters.

namespace caw::fx {

namespace {

using creative::clampTo;

enum CrushParam : uint32_t { kBits, kRateC, kJitter, kDither, kAdc, kDac, kOutput, kMixC, kCrushCount };

const ParamTable& crushParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("bits", "Bits", 8.0, 1.0, 24.0);
        p.expo("rate", "Sample rate", 8000.0, 200.0, 48000.0, "Hz");
        p.num("jitter", "Jitter", 0.0, 0.0, 1.0);
        p.num("dither", "Dither", 0.0, 0.0, 1.0);
        p.num("adc", "Anti-alias", 0.0, 0.0, 1.0);
        p.num("dac", "Anti-image", 0.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

const ModuleDescriptor& crushDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.bitcrush", "Bitcrush", crushParams(), 0, 0);
    return d;
}

// A 4-pole Butterworth low-pass whose cutoff slides from the host's top (amount 0, out of the path) down to just
// under the crushed rate's Nyquist (amount 1), on a log scale; blended in over the first tenth of the knob.
struct ConverterFilter {
    lib::Svf a[2], b[2];
    double amount = 0.0, cutoff = 20000.0;
    void set(double amt, double crushedRate, double sr) noexcept {
        if (amt <= 0.0 && amount > 0.0) clear();  // out of the path: it starts from silence when it comes back
        amount = amt;
        const double top = 0.45 * sr, low = std::min(top, 0.45 * crushedRate);
        cutoff = low >= top ? top : top * lib::fastExp(amt * lib::fastLog(low / top));
        for (int c = 0; c < 2; ++c) {
            a[c].set(cutoff, 0.54119610014619698, sr);
            b[c].set(cutoff, 1.30656296487637652, sr);
        }
    }
    double process(int c, double x) noexcept {
        if (amount <= 0.0) return x;
        const double y = b[c].lowpass(a[c].lowpass(x));
        const double blend = amount >= 0.1 ? 1.0 : amount * 10.0;
        return x + (y - x) * blend;
    }
    void clear() noexcept {
        for (int c = 0; c < 2; ++c) a[c].clear(), b[c].clear();
    }
    void flush() noexcept {
        for (int c = 0; c < 2; ++c) a[c].flushDenormals(), b[c].flushDenormals();
    }
};

class Bitcrush final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return crushDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        adc_.clear(), dac_.clear();
        phase_ = 1.0;  // the first frame is held at once
        period_ = 1.0;
        held_[0] = held_[1] = 0.0;
        noise_.seed(0x5eed);
        mix_.reset(), out_.reset();
        holds_ = 0;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        crushed_ = clampTo(param(kRateC, at), 200.0, sr);
        step_ = crushed_ / sr;
        const double bits = clampTo(param(kBits, at), 1.0, 24.0);
        levels_ = lib::fastExp((bits - 1.0) * 0.69314718055994531);  // 2^(bits - 1) levels each side of 0
        jitter_ = clampTo(param(kJitter, at), 0.0, 1.0);
        dither_ = clampTo(param(kDither, at), 0.0, 1.0);
        adc_.set(clampTo(param(kAdc, at), 0.0, 1.0), crushed_, sr);
        dac_.set(clampTo(param(kDac, at), 0.0, 1.0), crushed_, sr);
        out_.set(lib::dbToGain(clampTo(param(kOutput, at), -24.0, 12.0)), kControlFrames);
        mix_.set(clampTo(param(kMixC, at), 0.0, 1.0), kControlFrames);
        adc_.flush(), dac_.flush();
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const double inv = 1.0 / levels_;
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            const double f[2] = {adc_.process(0, x[0]), adc_.process(1, x[1])};
            // The crushed clock: a hold every 1 / step_ frames, each period stretched or squeezed by the jitter.
            phase_ += step_;
            if (phase_ >= period_) {
                phase_ -= period_;
                if (phase_ >= 1.0) phase_ = 0.0;
                period_ = 1.0 + 0.9 * jitter_ * noise_.bipolar();
                for (int c = 0; c < 2; ++c) {
                    // TPDF dither of up to one step, then rounding to the nearest level (0 is a level).
                    const double d = dither_ > 0.0 ? dither_ * (noise_.uniform() - noise_.uniform()) : 0.0;
                    const double q = std::floor(f[c] * levels_ + d + 0.5) * inv;
                    held_[c] = clampTo(q, -1.0, 1.0);
                }
                ++holds_;
            }
            const double g = out_.next(), m = mix_.next();
            for (int c = 0; c < 2; ++c) {
                const double y = dac_.process(c, held_[c]) * g;
                (c ? outR : outL)[i] = static_cast<float>(x[c] + (y - x[c]) * m);
            }
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(1.0 + std::log2(levels_));
        out[3] = static_cast<float>(crushed_);
        out[4] = static_cast<float>(adc_.cutoff);
        out[5] = static_cast<float>(dac_.cutoff);
        out[6] = static_cast<float>(holds_);
        holds_ = 0;
        return 7;
    }

private:
    ConverterFilter adc_, dac_;
    creative::Noise noise_;
    Ramp mix_, out_;
    double phase_ = 1.0, period_ = 1.0, step_ = 1.0 / 6.0, crushed_ = 8000.0, levels_ = 128.0, jitter_ = 0.0, dither_ = 0.0;
    double held_[2] = {0.0, 0.0};
    uint32_t holds_ = 0;
};

}  // namespace

void registerBitcrush(ModuleRegistry& registry) { registry.add(crushDescriptor(), &creative::make<Bitcrush>); }

}  // namespace caw::fx
