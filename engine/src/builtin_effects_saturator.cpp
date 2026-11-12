// The built-in saturator (#173, "org.caw.saturator"): tape, tube, clips, folds, crush, fuzz, rectify, bit shape and fat, 2x oversampled (4x at High).
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/dynamics.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/oversample.hpp"

// Original code (C.A.W. is Apache-2.0). The curves are standard waveshapers (tanh, an exponential tube-like
// asymmetry, a cubic soft clip, a hard clip, a sine fold and a bit/sample-rate crusher); the oversampler is the
// Library's polyphase IIR half-band (caw/library/oversample.hpp), with no latency. fx-dynamics (2026-11-11) added
// fuzz (an asymmetric cubic-boosted tanh), a full-wave rectifier, a triangle wavefolder, a bit shaper (amplitude
// steps at the oversampled rate, no sample-rate drop), "fat" (tanh plus its square: Faturator-style even
// harmonics), a left/right bias spread and a dynamics knob that gives the output back the input's envelope;
// a mode or oversampling change now dips the wet path for 2 ms each way instead of clicking.

namespace caw::fx {

namespace {

enum SatParam : uint32_t {
    kMode, kDrive, kBias, kTone, kBits, kRate, kOversample, kAutoGain, kOutput, kMix, kSpread, kDynamics, kSatCount
};
// fx-dynamics: the modes from Fuzz on, and the spread and dynamics knobs, were added at the ends (saved values keep
// their meaning).
constexpr std::string_view kModes[] = {"Tape", "Tube", "Soft clip", "Hard clip", "Fold", "Crush",
                                       "Fuzz", "Rectify", "Tri fold", "Bit shape", "Fat"};
enum Mode : int { kTape, kTube, kSoft, kHard, kFold, kCrush, kFuzz, kRectify, kTriFold, kBitShape, kFat, kModeCount };
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
        p.num("spread", "Spread", 0.0, 0.0, 1.0);      // the bias apart on the left and right
        p.num("dynamics", "Dynamics", 0.0, 0.0, 1.0);  // gives the output back the input's envelope
        return p;
    }();
    return t;
}
const ModuleDescriptor& satDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.saturator", "Saturator", satParams(), 0, 0);
    return d;
}

// The curves, each with slope 1 at 0 (so the drive alone sets how hard it is pushed; the rectifier's slope is
// +-1 and the bit shaper's 1 on average). `steps`: the bit shaper's levels per unit.
[[gnu::always_inline]] inline double curve(int mode, double x, double steps = 128.0) noexcept {
    switch (mode) {
        case kTube:  // asymmetric: the positive side a tanh, the negative an exponential that flattens at -2/3 (even harmonics)
            return x >= 0.0 ? lib::tanhApprox(x) : (lib::fastExp(1.5 * x) - 1.0) * (1.0 / 1.5);
        case kSoft: {  // cubic: 1.5 u - 0.5 u^3 with u = 2x/3, flat at +-1 from |x| = 1.5
            const double u = x * (2.0 / 3.0);
            return u >= 1.0 ? 1.0 : (u <= -1.0 ? -1.0 : 1.5 * u - 0.5 * u * u * u);
        }
        case kHard: return x > 1.0 ? 1.0 : (x < -1.0 ? -1.0 : x);
        case kFold: return lib::fastSinCycles(x * 0.15915494309189535);  // sin(x): folds back past pi/2
        case kFuzz: {  // tanh(x + x^3): squarer than tanh; the negative side clips at -0.7 (a fuzz's asymmetry)
            const double u = x + x * x * x;
            return x >= 0.0 ? lib::tanhApprox(u) : 0.7 * lib::tanhApprox(u * (1.0 / 0.7));
        }
        case kRectify: return lib::tanhApprox(x < 0.0 ? -x : x);  // full wave: the octave up (its DC is removed after)
        case kTriFold: {  // a triangle: up to 1 at x = 1, back to 0 at 2, -1 at 3, and on
            const double t = (x + 1.0) * 0.25;
            const double f = t - lib::fast_detail::floorSmall(t);
            return 1.0 - 4.0 * (f < 0.5 ? 0.5 - f : f - 0.5);
        }
        case kBitShape: {
            const double v = x > 1.0 ? 1.0 : (x < -1.0 ? -1.0 : x);
            return std::floor(v * steps + 0.5) / steps;
        }
        case kFat: {  // tanh plus half its square: a strong second harmonic (Faturator-style weight)
            const double t = lib::tanhApprox(x);
            return t + 0.5 * t * t;
        }
        default: return lib::tanhApprox(x);                               // tape: tanh
    }
}

class Saturator final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return satDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        for (auto& o : os_) o.set(lib::HalfBandDesign(8, 0.04));
        for (auto& o : os4_) o.set(lib::HalfBandDesign(8, 0.04));
        for (auto& d : dc_) d.set(10.0, sampleRate);
        for (auto& t : tape_) t.set(15000.0, sampleRate);
        fadeStep_ = 1.0 / (0.002 * sampleRate);
        envIn_.setCoefficients(lib::timeCoefficient(0.005, sampleRate), lib::timeCoefficient(0.08, sampleRate));
        envOut_.setCoefficients(lib::timeCoefficient(0.005, sampleRate), lib::timeCoefficient(0.08, sampleRate));
        return true;
    }
    void clearState() noexcept override {
        for (auto& o : os_) o.clear();
        for (auto& o : os4_) o.clear();
        for (auto& d : dc_) d.clear();
        for (auto& t : tape_) t.clear();
        for (int c = 0; c < 2; ++c)
            for (auto& s : tone_[c]) s.clear();
        held_[0] = held_[1] = 0.0;
        crushPhase_ = 1.0;
        drive_.reset(), out_.reset(), mix_.reset(), bias_.reset(), spread_.reset(), dyn_.reset();
        spread_.value = 0.0;
        envIn_.clear(), envOut_.clear();
        started_ = switching_ = false;
        fade_ = 1.0;
    }
    void control(uint32_t at) noexcept override {
        const int mode = std::clamp(choice(kMode, at), 0, kModeCount - 1);
        driveDb_ = std::clamp(param(kDrive, at), 0.0, 36.0);
        if (driveDb_ != driveDbFor_) driveDbFor_ = driveDb_, driveGain_ = lib::dbToGain(driveDb_);  // an exp: on a change
        drive_.set(driveGain_, kControlFrames);
        biasValue_ = std::clamp(param(kBias, at), -1.0, 1.0) * 0.5;
        bias_.set(biasValue_, kControlFrames);
        toneValue_ = std::clamp(param(kTone, at), -1.0, 1.0);
        tone_filter_.set(lib::EqType::Tilt, 1000.0, toneValue_ * 9.0, 0.5, rate());
        if (tone_filter_.identity())  // flat: not run; start clean when it tilts again
            for (int c = 0; c < 2; ++c)
                for (auto& st : tone_[c]) st.clear();
        // Oversampling: the knob's 2x, off in Eco, 4x (two half-band stages) in High.
        const int q = quality();
        const int factor = !on(kOversample, at) || mode == kCrush || q == kQualityEco ? 1 : (q == kQualityHigh ? 4 : 2);
        if (!started_) {  // the first control after a reset: straight in
            started_ = true;
            mode_ = mode;
            if (factor == 4 && factor_ != 4)  // the inner stage starts clean
                for (auto& o : os4_) o.clear();
            factor_ = factor;
            oversample_ = factor > 1;
        } else if (mode != mode_ || factor != factor_) {  // a change: the wet path dips out and back (run())
            wantMode_ = mode;
            wantFactor_ = factor;
            switching_ = true;
        }
        autoDb_ = on(kAutoGain, at) ? -0.5 * driveDb_ : 0.0;
        const double outDb = param(kOutput, at) + autoDb_;
        if (outDb != outDbFor_) outDbFor_ = outDb, outGain_ = lib::dbToGain(outDb);
        out_.set(outGain_, kControlFrames);
        mix_.set(std::clamp(param(kMix, at), 0.0, 1.0), kControlFrames);
        const double bits = std::clamp(param(kBits, at), 1.0, 16.0);
        if (bits != bitsFor_) bitsFor_ = bits, steps_ = detPow(2.0, bits - 1.0);  // a pow: on a change
        crushStep_ = std::clamp(param(kRate, at), 200.0, 48000.0) / rate();
        spreadValue_ = std::clamp(param(kSpread, at), 0.0, 1.0);
        spreadOn_ = spreadValue_ > 0.0 || spread_.value != 0.0;
        spread_.set(spreadValue_ * 0.25, kControlFrames);
        dynValue_ = std::clamp(param(kDynamics, at), 0.0, 1.0);
        dynOn_ = dynValue_ > 0.0;
        if (dynOn_) {  // the gain that brings the wet envelope back to the input's, as far as `dynamics` says
            const double db = dynValue_ * (lib::gainToDb(envIn_.value(), -90.0) - lib::gainToDb(envOut_.value(), -90.0));
            dyn_.set(lib::dbToGain(std::clamp(db, -24.0, 24.0)), kControlFrames);
        } else {
            dyn_.reset();
            envIn_.clear(), envOut_.clear();
        }
    }
    // Per sample while a mode or oversampling change is under way: down to dry in 2 ms, switch, back in 2 ms.
    void stepSwitch() noexcept {
        if (switching_) {
            fade_ -= fadeStep_;
            if (fade_ > 0.0) return;
            fade_ = 0.0;
            switching_ = false;
            mode_ = wantMode_;
            factor_ = wantFactor_;
            oversample_ = factor_ > 1;
            for (auto& o : os_) o.clear();
            for (auto& o : os4_) o.clear();
            for (auto& t : tape_) t.clear();
            held_[0] = held_[1] = 0.0;
        } else {
            fade_ = std::min(1.0, fade_ + fadeStep_);
        }
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // A run with no mode or oversampling change under way keeps one mode throughout: the loop is made for it
        // (the curve inlined, no switch per sample); the arithmetic is the same either way.
        if (switching_ || fade_ < 1.0) return runWith<-1>(inL, inR, outL, outR, n);
        switch (mode_) {
            case kTube: return runBlock<kTube>(inL, inR, outL, outR, n);
            case kSoft: return runBlock<kSoft>(inL, inR, outL, outR, n);
            case kHard: return runBlock<kHard>(inL, inR, outL, outR, n);
            case kFold: return runBlock<kFold>(inL, inR, outL, outR, n);
            case kCrush: return runWith<kCrush>(inL, inR, outL, outR, n);
            case kFuzz: return runBlock<kFuzz>(inL, inR, outL, outR, n);
            case kRectify: return runBlock<kRectify>(inL, inR, outL, outR, n);
            case kTriFold: return runBlock<kTriFold>(inL, inR, outL, outR, n);
            case kBitShape: return runBlock<kBitShape>(inL, inR, outL, outR, n);
            case kFat: return runBlock<kFat>(inL, inR, outL, outR, n);
            default: return runBlock<kTape>(inL, inR, outL, outR, n);
        }
    }
    // runWith<M>'s arithmetic for one mode (not the crusher) and no change under way, stage by stage over the run:
    // the ramps, each side's drive and bias, its oversampler up (Oversampler2x::upBlock), the curve over every
    // oversampled value (a loop that vectorizes), down, the tape and DC filters and the tone, then the dynamics
    // and the mix. Each sample meets the same operations in the same order (speed phase 4).
    template <int M>
    void runBlock(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept {
        constexpr uint32_t K = kControlFrames;
        double drive[K], bias0[K], outGain[K], mix[K], sp[K];
        for (uint32_t i = 0; i < n; ++i) {
            drive[i] = drive_.next(), bias0[i] = bias_.next(), outGain[i] = out_.next(), mix[i] = mix_.next();
            sp[i] = spreadOn_ ? spread_.next() : 0.0;
        }
        const double steps = steps_;
        double v[2][K];
        for (int c = 0; c < 2; ++c) {
            const float* in = c ? inR : inL;
            double x[K], off[K], up[2 * K], up4[4 * K];
            for (uint32_t i = 0; i < n; ++i) {
                const double bias = spreadOn_ ? bias0[i] + (c == 0 ? sp[i] : -sp[i]) : bias0[i];
                // The curve's value at the bias, worked out again only when the bias (or the mode) moved.
                if (bias != offsetBias_[c] || M != offsetMode_[c] || steps != offsetSteps_[c]) {
                    offsetBias_[c] = bias;
                    offsetMode_[c] = M;
                    offsetSteps_[c] = steps;
                    offset_[c] = curve(M, bias, steps);
                }
                off[i] = offset_[c];
                x[i] = static_cast<double>(in[i]) * drive[i] + bias;
            }
            double* y = v[c];
            if (factor_ == 4) {
                os_[c].upBlock(x, up, static_cast<int>(n));
                os4_[c].upBlock(up, up4, static_cast<int>(2 * n));
                for (uint32_t i = 0; i < n; ++i)
                    for (int k = 0; k < 4; ++k) up4[4 * i + k] = curve(M, up4[4 * i + k], steps) - off[i];
                os4_[c].downBlock(up4, up, static_cast<int>(2 * n));
                os_[c].downBlock(up, y, static_cast<int>(n));
            } else if (oversample_) {
                os_[c].upBlock(x, up, static_cast<int>(n));
                for (uint32_t i = 0; i < n; ++i)
                    for (int k = 0; k < 2; ++k) up[2 * i + k] = curve(M, up[2 * i + k], steps) - off[i];
                os_[c].downBlock(up, y, static_cast<int>(n));
            } else {
                for (uint32_t i = 0; i < n; ++i) y[i] = curve(M, x[i], steps) - off[i];
            }
            if (M == kTape)  // tape's gentle top-end loss
                for (uint32_t i = 0; i < n; ++i) y[i] = tape_[c].low(y[i]);
            for (uint32_t i = 0; i < n; ++i) y[i] = dc_[c].high(y[i]);  // the bias's offset and an asymmetric curve's DC
            if (!tone_filter_.identity())
                for (uint32_t i = 0; i < n; ++i) y[i] = tone_filter_.process(tone_[c], y[i]);
        }
        if (dynOn_) {  // the envelopes, linked, before the dynamics gain (which follows them at control rate)
            for (uint32_t i = 0; i < n; ++i) {
                const double xl = inL[i], xr = inR[i];
                const double a = std::max(xl < 0 ? -xl : xl, xr < 0 ? -xr : xr);
                const double b = std::max(v[0][i] < 0 ? -v[0][i] : v[0][i], v[1][i] < 0 ? -v[1][i] : v[1][i]);
                envIn_.process(a);
                envOut_.process(b);
                const double g = dyn_.next();
                v[0][i] *= g, v[1][i] *= g;
            }
        }
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            const double wl = v[0][i] * outGain[i], wr = v[1][i] * outGain[i];
            outL[i] = static_cast<float>(xl + (wl - xl) * mix[i]);
            outR[i] = static_cast<float>(xr + (wr - xr) * mix[i]);
        }
    }
    // M: the mode for the whole run, or -1: mode_ as it is at each sample (a change under way).
    template <int M>
    void runWith(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept {
        for (uint32_t i = 0; i < n; ++i) {
            const double drive = drive_.next(), bias0 = bias_.next(), out = out_.next(), mix0 = mix_.next();
            if (M < 0 && (switching_ || fade_ < 1.0)) stepSwitch();
            const int mode = M < 0 ? mode_ : M;
            const double mix = fade_ < 1.0 ? mix0 * fade_ : mix0;
            const double sp = spreadOn_ ? spread_.next() : 0.0;
            const double steps = steps_;
            const double x[2] = {inL[i], inR[i]};
            double y[2];
            if (mode == kCrush) {
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
                    const double bias = spreadOn_ ? bias0 + (c == 0 ? sp : -sp) : bias0;
                    // The curve's value at the bias, worked out again only when the bias (or the mode) moved.
                    if (bias != offsetBias_[c] || mode != offsetMode_[c] || steps != offsetSteps_[c]) {
                        offsetBias_[c] = bias;
                        offsetMode_[c] = mode;
                        offsetSteps_[c] = steps;
                        offset_[c] = curve(mode, bias, steps);
                    }
                    const double offset = offset_[c];
                    const double v = x[c] * drive + bias;
                    if (factor_ == 4) {
                        double up[2], a[2], b[2];
                        os_[c].up(v, up);
                        os4_[c].up(up[0], a);
                        os4_[c].up(up[1], b);
                        for (double& u : a) u = curve(mode, u, steps) - offset;
                        for (double& u : b) u = curve(mode, u, steps) - offset;
                        const double down[2] = {os4_[c].down(a), os4_[c].down(b)};
                        y[c] = os_[c].down(down);
                    } else if (oversample_) {
                        double up[2];
                        os_[c].up(v, up);
                        up[0] = curve(mode, up[0], steps) - offset;
                        up[1] = curve(mode, up[1], steps) - offset;
                        y[c] = os_[c].down(up);
                    } else {
                        y[c] = curve(mode, v, steps) - offset;
                    }
                    if (mode == kTape) y[c] = tape_[c].low(y[c]);  // tape's gentle top-end loss
                }
            }
            double v[2];
            for (int c = 0; c < 2; ++c) {
                v[c] = dc_[c].high(y[c]);  // the bias's offset and an asymmetric curve's DC, removed
                if (!tone_filter_.identity()) v[c] = tone_filter_.process(tone_[c], v[c]);
            }
            if (dynOn_) {  // the envelopes, linked, before the dynamics gain (which follows them at control rate)
                const double a = std::max(x[0] < 0 ? -x[0] : x[0], x[1] < 0 ? -x[1] : x[1]);
                const double b = std::max(v[0] < 0 ? -v[0] : v[0], v[1] < 0 ? -v[1] : v[1]);
                envIn_.process(a);
                envOut_.process(b);
                const double g = dyn_.next();
                v[0] *= g, v[1] *= g;
            }
            for (int c = 0; c < 2; ++c) {
                const double w = v[c] * out;
                y[c] = x[c] + (w - x[c]) * mix;
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
            else y = curve(mode_, x * drive + biasValue_, steps_) - curve(mode_, biasValue_, steps_);
            out[8 + k] = static_cast<float>(y);
        }
        return 8 + kCurvePoints;
    }

private:
    lib::Oversampler2x os_[2], os4_[2];  // os4_: the inner stage of High's 4x
    lib::OnePole dc_[2], tape_[2];
    lib::EqFilter tone_filter_;
    lib::SvfState tone_[2][lib::EqFilter::kMaxStages];
    Ramp drive_, out_, mix_, bias_, spread_, dyn_;
    lib::EnvelopeFollower envIn_, envOut_;
    int mode_ = 0, wantMode_ = 0, wantFactor_ = 2;
    bool started_ = false, switching_ = false, spreadOn_ = false, dynOn_ = false;
    double fade_ = 1.0, fadeStep_ = 0.01, spreadValue_ = 0, dynValue_ = 0;
    bool oversample_ = true;
    int factor_ = 2;
    double driveDb_ = 6, biasValue_ = 0, toneValue_ = 0, autoDb_ = 0, steps_ = 128, crushStep_ = 0.25;
    double crushPhase_ = 1.0, held_[2] = {};
    double driveDbFor_ = -1e300, driveGain_ = 1, outDbFor_ = -1e300, outGain_ = 1, bitsFor_ = -1;  // control: last worked out
    double offset_[2] = {}, offsetBias_[2] = {}, offsetSteps_[2] = {};  // curve(offsetMode_, offsetBias_, ...) per side
    int offsetMode_[2] = {-1, -1};
};

ModuleProcessor* makeSaturator() noexcept { return new (std::nothrow) Saturator(); }

}  // namespace

void registerSaturator(ModuleRegistry& registry) { registry.add(satDescriptor(), &makeSaturator); }

}  // namespace caw::fx
