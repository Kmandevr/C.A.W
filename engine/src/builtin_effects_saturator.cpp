// The built-in saturator (#173, "org.caw.saturator"): tape, tube, soft and hard clip, fold and crush, 2x oversampled.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/eq.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/oversample.hpp"

// Original code (C.A.W. is Apache-2.0). The curves are standard waveshapers (tanh, an exponential tube-like
// asymmetry, a cubic soft clip, a hard clip, a sine fold and a bit/sample-rate crusher); the oversampler is the
// Library's polyphase IIR half-band (caw/library/oversample.hpp), with no latency.

namespace caw::fx {

namespace {

enum SatParam : uint32_t { kMode, kDrive, kBias, kTone, kBits, kRate, kOversample, kAutoGain, kOutput, kMix, kSatCount };
constexpr std::string_view kModes[] = {"Tape", "Tube", "Soft clip", "Hard clip", "Fold", "Crush"};
enum Mode : int { kTape, kTube, kSoft, kHard, kFold, kCrush };
constexpr std::string_view kOversampling[] = {"Off", "2x"};
constexpr uint32_t kCurvePoints = 65;

const ParamTable& satParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 0.0, kModes);
        p.num("drive", "Drive", 6.0, 0.0, 36.0, "dB");
        p.num("bias", "Bias", 0.0, -1.0, 1.0);
        p.num("tone", "Tone", 0.0, -1.0, 1.0);
        p.num("bits", "Bits (crush)", 8.0, 1.0, 16.0);
        p.expo("rate", "Rate (crush)", 11025.0, 200.0, 48000.0, "Hz");
        p.pick("oversample", "Oversampling", 1.0, kOversampling);
        p.pick("auto_gain", "Auto gain", 1.0, kOffOn);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& satDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.saturator", "Saturator", satParams(), 0, 0);
    return d;
}

// The curves, each with slope 1 at 0 (so the drive alone sets how hard it is pushed).
inline double curve(int mode, double x) noexcept {
    switch (mode) {
        case kTube:  // asymmetric: the positive side a tanh, the negative an exponential that flattens at -2/3 (even harmonics)
            return x >= 0.0 ? lib::fastTanh(x) : (lib::fastExp(1.5 * x) - 1.0) * (1.0 / 1.5);
        case kSoft: {  // cubic: 1.5 u - 0.5 u^3 with u = 2x/3, flat at +-1 from |x| = 1.5
            const double u = x * (2.0 / 3.0);
            return u >= 1.0 ? 1.0 : (u <= -1.0 ? -1.0 : 1.5 * u - 0.5 * u * u * u);
        }
        case kHard: return x > 1.0 ? 1.0 : (x < -1.0 ? -1.0 : x);
        case kFold: return lib::fastSinCycles(x * 0.15915494309189535);  // sin(x): folds back past pi/2
        default: return lib::fastTanh(x);                               // tape: tanh
    }
}

class Saturator final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return satDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        for (auto& o : os_) o.set(lib::HalfBandDesign(8, 0.04));
        for (auto& d : dc_) d.set(10.0, sampleRate);
        for (auto& t : tape_) t.set(15000.0, sampleRate);
        return true;
    }
    void clearState() noexcept override {
        for (auto& o : os_) o.clear();
        for (auto& d : dc_) d.clear();
        for (auto& t : tape_) t.clear();
        for (int c = 0; c < 2; ++c)
            for (auto& s : tone_[c]) s.clear();
        held_[0] = held_[1] = 0.0;
        crushPhase_ = 1.0;
        drive_.reset(), out_.reset(), mix_.reset(), bias_.reset();
    }
    void control(uint32_t at) noexcept override {
        mode_ = std::clamp(choice(kMode, at), 0, 5);
        driveDb_ = std::clamp(param(kDrive, at), 0.0, 36.0);
        drive_.set(lib::dbToGain(driveDb_), kControlFrames);
        biasValue_ = std::clamp(param(kBias, at), -1.0, 1.0) * 0.5;
        bias_.set(biasValue_, kControlFrames);
        toneValue_ = std::clamp(param(kTone, at), -1.0, 1.0);
        tone_filter_.set(lib::EqType::Tilt, 1000.0, toneValue_ * 9.0, 0.5, rate());
        if (tone_filter_.identity())  // flat: not run; start clean when it tilts again
            for (int c = 0; c < 2; ++c)
                for (auto& st : tone_[c]) st.clear();
        oversample_ = on(kOversample, at) && mode_ != kCrush;
        autoDb_ = on(kAutoGain, at) ? -0.5 * driveDb_ : 0.0;
        out_.set(lib::dbToGain(param(kOutput, at) + autoDb_), kControlFrames);
        mix_.set(std::clamp(param(kMix, at), 0.0, 1.0), kControlFrames);
        const double bits = std::clamp(param(kBits, at), 1.0, 16.0);
        steps_ = detPow(2.0, bits - 1.0);
        crushStep_ = std::clamp(param(kRate, at), 200.0, 48000.0) / rate();
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double drive = drive_.next(), bias = bias_.next(), out = out_.next(), mix = mix_.next();
            const double offset = mode_ == kCrush ? 0.0 : curve(mode_, bias);
            const double x[2] = {inL[i], inR[i]};
            double y[2];
            if (mode_ == kCrush) {
                crushPhase_ += crushStep_;
                const bool take = crushPhase_ >= 1.0;
                if (take) crushPhase_ -= std::floor(crushPhase_);
                for (int c = 0; c < 2; ++c) {
                    if (take) {
                        const double v = std::clamp(x[c] * drive, -1.0, 1.0);
                        held_[c] = std::floor(v * steps_ + 0.5) / steps_;
                    }
                    y[c] = held_[c];
                }
            } else {
                for (int c = 0; c < 2; ++c) {
                    const double v = x[c] * drive + bias;
                    if (oversample_) {
                        double up[2];
                        os_[c].up(v, up);
                        up[0] = curve(mode_, up[0]) - offset;
                        up[1] = curve(mode_, up[1]) - offset;
                        y[c] = os_[c].down(up);
                    } else {
                        y[c] = curve(mode_, v) - offset;
                    }
                    if (mode_ == kTape) y[c] = tape_[c].low(y[c]);  // tape's gentle top-end loss
                }
            }
            for (int c = 0; c < 2; ++c) {
                double v = dc_[c].high(y[c]);  // the bias's offset and an asymmetric curve's DC, removed
                if (!tone_filter_.identity()) v = tone_filter_.process(tone_[c], v);
                v *= out;
                y[c] = x[c] + (v - x[c]) * mix;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(mode_);
        out[3] = static_cast<float>(driveDb_);
        out[4] = static_cast<float>(biasValue_ * 2.0);
        out[5] = static_cast<float>(toneValue_);
        out[6] = static_cast<float>(autoDb_);
        out[7] = static_cast<float>(kCurvePoints);
        // The transfer curve: the output for inputs -1 .. 1 (before the tone, output and mix), as the knobs set it.
        const double drive = lib::dbToGain(driveDb_);
        for (uint32_t k = 0; k < kCurvePoints; ++k) {
            const double x = -1.0 + 2.0 * k / (kCurvePoints - 1);
            double y;
            if (!watched) y = 0.0;
            else if (mode_ == kCrush) y = std::floor(std::clamp(x * drive, -1.0, 1.0) * steps_ + 0.5) / steps_;
            else y = curve(mode_, x * drive + biasValue_) - curve(mode_, biasValue_);
            out[8 + k] = static_cast<float>(y);
        }
        return 8 + kCurvePoints;
    }

private:
    lib::Oversampler2x os_[2];
    lib::OnePole dc_[2], tape_[2];
    lib::EqFilter tone_filter_;
    lib::SvfState tone_[2][lib::EqFilter::kMaxStages];
    Ramp drive_, out_, mix_, bias_;
    int mode_ = 0;
    bool oversample_ = true;
    double driveDb_ = 6, biasValue_ = 0, toneValue_ = 0, autoDb_ = 0, steps_ = 128, crushStep_ = 0.25;
    double crushPhase_ = 1.0, held_[2] = {};
};

ModuleProcessor* makeSaturator() noexcept { return new (std::nothrow) Saturator(); }

}  // namespace

void registerSaturator(ModuleRegistry& registry) { registry.add(satDescriptor(), &makeSaturator); }

}  // namespace caw::fx
