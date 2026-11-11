// The ring modulator (fx-creative): "org.caw.ringmod", the input times a sine, triangle, square, saw or noise carrier, or times another track's sound (its sidechain key).
#include <cmath>

#include "builtin_fx_creative.h"
#include "caw/library/filter.hpp"
#include "caw/library/oversample.hpp"

// Original code (C.A.W. is Apache-2.0). Ring modulation is a multiplication (DAFX, 2nd ed., ch. 3): every
// partial of the input meets every partial of the carrier at their sum and difference. Bias moves it toward
// amplitude modulation (carrier b + (1 - b) c: at 1 the input passes); rectify folds the carrier's negative
// half up (or the positive half down). The square and saw carriers are band-limited by PolyBLEP (Välimäki and
// Huovilainen, "Antialiasing Oscillators in Subtractive Synthesis", IEEE Signal Processing Magazine 24(2), 2007);
// noise is white noise through a low-pass at the carrier frequency. The product's sum frequencies can pass the
// Nyquist frequency, so at High quality the multiplication runs at twice the rate (the Library's polyphase
// half-band, no latency).

namespace caw::fx {

namespace {

using creative::clampTo;

enum RingParam : uint32_t { kSource, kFreq, kSpreadR, kBias, kRectify, kMixR, kRingCount };
constexpr std::string_view kSources[] = {"Sine", "Triangle", "Square", "Saw", "Noise", "Sidechain"};
enum Source : int { kSine, kTri, kSquare, kSaw, kNoiseSrc, kKey };

const ParamTable& ringParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("source", "Carrier", 0.0, kSources);
        p.expo("freq", "Frequency", 440.0, 0.1, 8000.0, "Hz");
        p.num("spread", "Stereo spread", 0.0, 0.0, 1.0);
        p.num("bias", "Bias", 0.0, 0.0, 1.0);
        p.num("rectify", "Rectify", 0.0, -1.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

const ModuleDescriptor& ringDescriptor() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.ringmod", "Ring mod", ringParams(), 0, 0, false);
    return d;
}

// PolyBLEP's correction near a step at phase 0 (t in cycles, dt the step per sample).
double blep(double t, double dt) noexcept {
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

// One side's carrier.
struct Carrier {
    double phase = 0.0;
    lib::Svf noiseLp;
    creative::Noise noise;
    void clear(uint32_t seed) noexcept {
        phase = 0.0;
        noiseLp.clear();
        noise.seed(seed);
    }
    double next(int source, double dt, double noiseGain) noexcept {
        double c;
        switch (source) {
            case kTri: c = 4.0 * std::fabs(phase - 0.5) - 1.0; break;
            case kSquare: c = (phase < 0.5 ? 1.0 : -1.0) + blep(phase, dt) - blep(phase + 0.5 - std::floor(phase + 0.5), dt); break;
            case kSaw: c = 2.0 * phase - 1.0 - blep(phase, dt); break;
            case kNoiseSrc: c = clampTo(noiseLp.lowpass(noise.bipolar()) * noiseGain, -1.5, 1.5); break;
            default: c = lib::fastSinCycles(phase); break;
        }
        phase += dt;
        phase -= std::floor(phase);
        return c;
    }
};

class RingMod final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return ringDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        carrier_[0].clear(0xa11ce);
        carrier_[1].clear(0xb0b);
        for (auto& o : up_) o.clear();
        for (auto& o : upKey_) o.clear();
        for (auto& o : down_) o.clear();
        bias_.reset(), rect_.reset(), mix_.reset();
        carrierPeak_ = 0.0;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        source_ = std::clamp(choice(kSource, at), 0, 5);
        const bool high = quality() == kQualityHigh;
        if (high != oversampled_) {
            for (auto& o : up_) o.clear();
            for (auto& o : down_) o.clear();
            oversampled_ = high;
        }
        const double inner = sr * (oversampled_ ? 2.0 : 1.0);
        const double f = clampTo(param(kFreq, at), 0.1, 8000.0), spread = clampTo(param(kSpreadR, at), 0.0, 1.0);
        freq_[0] = f * lib::fastExp(-spread * 0.057762265046662105);  // one semitone down at full spread
        freq_[1] = f * lib::fastExp(spread * 0.057762265046662105);   // and up
        for (int c = 0; c < 2; ++c) {
            dt_[c] = freq_[c] / inner;
            carrier_[c].noiseLp.set(std::max(20.0, freq_[c]), 0.70710678118654752, inner);
            carrier_[c].noiseLp.flushDenormals();
            // White noise filtered to f keeps f / (rate / 2) of its power: made up to about a sine's level.
            noiseGain_[c] = std::min(8.0, 0.8 * std::sqrt(0.5 * inner / std::max(20.0, freq_[c])));
        }
        bias_.set(clampTo(param(kBias, at), 0.0, 1.0), kControlFrames);
        rect_.set(clampTo(param(kRectify, at), -1.0, 1.0), kControlFrames);
        mix_.set(clampTo(param(kMixR, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* key[2] = {keyLeft(), keyRight()};
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            const double b = bias_.next(), r = rect_.next(), m = mix_.next();
            for (int c = 0; c < 2; ++c) {
                const double k = key[c] ? finiteOr0(key[c][i]) : 0.0;
                double y;
                if (oversampled_) {
                    double hi[2], ki[2] = {k, k};
                    up_[c].up(x[c], hi);
                    if (source_ == kKey) upKey_[c].up(k, ki);
                    for (int j = 0; j < 2; ++j) hi[j] *= shape(source_ == kKey ? ki[j] : carrier_[c].next(source_, dt_[c], noiseGain_[c]), b, r);
                    y = down_[c].down(hi);
                } else {
                    y = x[c] * shape(source_ == kKey ? k : carrier_[c].next(source_, dt_[c], noiseGain_[c]), b, r);
                }
                (c ? outR : outL)[i] = static_cast<float>(x[c] + (y - x[c]) * m);
            }
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(source_);
        out[3] = static_cast<float>(freq_[0]);
        out[4] = static_cast<float>(freq_[1]);
        out[5] = static_cast<float>(carrier_[0].phase);
        out[6] = static_cast<float>(carrierPeak_);
        out[7] = oversampled_ ? 2.0f : 1.0f;
        carrierPeak_ = 0.0;
        return 8;
    }

private:
    // The carrier after rectify and bias.
    double shape(double c, double bias, double rectify) noexcept {
        const double a = c < 0 ? -c : c;
        carrierPeak_ = std::max(carrierPeak_, a);
        const double folded = rectify >= 0.0 ? c + (a - c) * rectify : c + (-a - c) * -rectify;
        return bias + (1.0 - bias) * folded;
    }

    Carrier carrier_[2];
    lib::Oversampler2x up_[2], upKey_[2], down_[2];
    Ramp bias_, rect_, mix_;
    int source_ = kSine;
    bool oversampled_ = false;
    double freq_[2] = {440.0, 440.0}, dt_[2] = {0.01, 0.01}, noiseGain_[2] = {1.0, 1.0}, carrierPeak_ = 0.0;
};

}  // namespace

void registerRingMod(ModuleRegistry& registry) { registry.add(ringDescriptor(), &creative::make<RingMod>); }

}  // namespace caw::fx
