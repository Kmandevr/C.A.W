// fx-dynamics (Drive category): the Clipper (hard, soft and analog curves, up to 8x oversampled, clip to 0 dB) and Phase distortion.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/dynamics.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/oversample.hpp"

// Original code (C.A.W. is Apache-2.0). Techniques, in our own words (docs/engine.md, "Dynamics and drive"):
// - the clipper is a memoryless curve run at 2, 4 or 8 times the rate (cascaded polyphase IIR half-bands,
//   caw/library/oversample.hpp), so the harmonics it makes above the old Nyquist are filtered off instead of
//   folding back (Zölzer (ed.), DAFX, 2nd ed. 2011, ch. 4; Välimäki et al. on aliasing in virtual-analog
//   nonlinearities). Its soft curve is a quadratic knee joining the straight line to the ceiling with matching
//   slope; "analog" is an asymmetric tanh;
// - phase distortion is the input read from a delay line whose delay the input itself (low-passed by Tone, and
//   with Normalize divided by its own envelope) moves around a fixed centre: self phase modulation, which on a
//   sine sounds like feedback FM. The read uses 4-point Hermite interpolation (J. O. Smith, Physical Audio Signal
//   Processing, CCRMA online book, "Delay-Line Interpolation"); the fixed centre is the declared latency, and the
//   dry path is delayed as much so the mix stays in phase.

namespace caw::fx {

namespace {

// ---------- Oversampling with cross-faded factor changes ----------

constexpr int kMaxStages = 3;  // 8x

// x through `stages` cascaded 2x stages around f (f runs at 2^stages the rate).
template <class F>
double oversampled(lib::Oversampler2x* s, int stages, double x, const F& f) noexcept {
    if (stages <= 0) return f(x);
    double u[2];
    s->up(x, u);
    u[0] = oversampled(s + 1, stages - 1, u[0], f);
    u[1] = oversampled(s + 1, stages - 1, u[1], f);
    return s->down(u);
}

// One channel's oversampling for a memoryless curve: two chains, so a new factor starts on a clean chain and is
// cross-faded in over kFade frames while the old one still runs (no click when the factor or quality changes).
class Oversampling {
public:
    static constexpr int kFade = 256;
    Oversampling() noexcept {
        const lib::HalfBandDesign d(8, 0.04);
        for (auto& c : chain_)
            for (auto& s : c) s.set(d);
    }
    void clear() noexcept {
        for (auto& c : chain_)
            for (auto& s : c) s.clear();
        fade_ = 0;
        fresh_ = true;
    }
    void setStages(int stages) noexcept {
        stages = std::clamp(stages, 0, kMaxStages);
        if (fresh_) {
            stages_[cur_] = stages;
            fresh_ = false;
            return;
        }
        if (stages == stages_[cur_]) return;
        cur_ = 1 - cur_;
        for (auto& s : chain_[cur_]) s.clear();
        stages_[cur_] = stages;
        fade_ = kFade;
    }
    int stages() const noexcept { return stages_[cur_]; }
    template <class F>
    double process(double x, const F& f) noexcept {
        const double y = oversampled(chain_[cur_], stages_[cur_], x, f);
        if (fade_ == 0) return y;
        const double old = oversampled(chain_[1 - cur_], stages_[1 - cur_], x, f);
        const double w = static_cast<double>(fade_--) / kFade;
        return y + (old - y) * w;
    }

private:
    lib::Oversampler2x chain_[2][kMaxStages];
    int stages_[2] = {0, 0}, cur_ = 0, fade_ = 0;
    bool fresh_ = true;
};

// ---------- Clipper ----------

constexpr std::string_view kClipModes[] = {"Hard", "Soft", "Analog"};
enum ClipMode : int { kHard, kSoft, kAnalog };
constexpr std::string_view kClipOversampling[] = {"Auto", "Off", "2x", "4x", "8x"};
enum ClipParam : uint32_t { kCMode, kCDrive, kCCeiling, kCSoftness, kCOversample, kCMaster, kCOutput, kCMix, kClipCount };
constexpr uint32_t kCurvePoints = 65;
constexpr double kAnalogBias = 0.1;

const ParamTable& clipParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 0.0, kClipModes);
        p.num("drive", "Drive", 0.0, 0.0, 24.0, "dB");
        p.num("ceiling", "Ceiling", -0.3, -24.0, 0.0, "dB");
        p.num("softness", "Softness", 0.5, 0.0, 1.0);
        p.pick("oversample", "Oversampling", 0.0, kClipOversampling);
        // Mastering: the ceiling is 0 dBFS and the output and mix are ignored, so no sample passes full scale.
        p.pick("master", "Clip to 0 dB", 0.0, kOffOn);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& clipDescriptor() {
    static const ModuleDescriptor d = withCpu(effectDescriptor("org.caw.clipper", "Clipper", clipParams(), 0, 0), CpuClass::Light);
    return d;
}

// The curve for u = input / ceiling (output / ceiling): never past 1 (the analog curve's negative side reaches
// -1, its positive side a little less).
inline double clipCurve(int mode, double u, double knee) noexcept {
    const double a = u < 0 ? -u : u, s = u < 0 ? -1.0 : 1.0;
    switch (mode) {
        case kSoft: {
            if (knee < 1e-6) return a >= 1.0 ? s : u;
            const double t = 1.0 - knee;
            if (a <= t) return u;
            if (a >= 1.0 + knee) return s;
            const double d = a - t;
            return s * (t + d - d * d / (4.0 * knee));
        }
        case kAnalog: {
            constexpr double tb = 0.09966799462495582;  // tanh(0.1)
            return (lib::fastTanh(u + kAnalogBias) - tb) / (1.0 + tb);
        }
        default: return a >= 1.0 ? s : u;
    }
}

class Clipper final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return clipDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        blendStep_ = 1.0 / (0.005 * sampleRate);
        return true;
    }
    void clearState() noexcept override {
        for (auto& o : os_) o.clear();
        drive_.reset(), ceiling_.reset(), out_.reset(), mix_.reset();
        fresh_ = true;
        blend_ = 1.0;
        overMax_ = -120.0;
    }
    void control(uint32_t at) noexcept override {
        const int mode = std::clamp(choice(kCMode, at), 0, 2);
        if (fresh_) mode_ = prevMode_ = mode, blend_ = 1.0;
        else if (mode != mode_) prevMode_ = blend_ < 1.0 ? prevMode_ : mode_, mode_ = mode, blend_ = 0.0;
        fresh_ = false;
        master_ = on(kCMaster, at);
        driveDb_ = std::clamp(param(kCDrive, at), 0.0, 24.0);
        ceilingDb_ = master_ ? 0.0 : std::clamp(param(kCCeiling, at), -24.0, 0.0);
        knee_ = std::clamp(param(kCSoftness, at), 0.0, 1.0);
        drive_.set(lib::dbToGain(driveDb_), kControlFrames);
        ceiling_.set(lib::dbToGain(ceilingDb_), kControlFrames);
        out_.set(master_ ? 1.0 : lib::dbToGain(param(kCOutput, at)), kControlFrames);
        mix_.set(master_ ? 1.0 : std::clamp(param(kCMix, at), 0.0, 1.0), kControlFrames);
        // Auto: off in Eco, 2x in Normal, 4x in High; a chosen factor is honoured, but Eco runs one stage fewer,
        // at most 2x (2x off, 4x and 8x at 2x).
        const int q = quality(), pick = choice(kCOversample, at);
        int stages = pick == 0 ? (q == kQualityEco ? 0 : (q == kQualityHigh ? 2 : 1)) : std::clamp(pick - 1, 0, kMaxStages);
        if (q == kQualityEco) stages = std::clamp(stages - 1, 0, 1);
        for (auto& o : os_) o.setStages(stages);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double drive = drive_.next(), ceiling = ceiling_.next(), out = out_.next(), mix = mix_.next();
            if (blend_ < 1.0) blend_ = std::min(1.0, blend_ + blendStep_);
            const double inv = 1.0 / ceiling, knee = knee_, blend = blend_;
            const int mode = mode_, prev = prevMode_;
            const auto curve = [&](double v) noexcept {
                const double y = clipCurve(mode, v * inv, knee);
                if (blend >= 1.0) return ceiling * y;
                const double before = clipCurve(prev, v * inv, knee);  // a mode change cross-fades the curves
                return ceiling * (before + (y - before) * blend);
            };
            const double x[2] = {inL[i], inR[i]};
            float* o[2] = {outL + i, outR + i};
            for (int c = 0; c < 2; ++c) {
                const double v = x[c] * drive;
                const double a = v < 0 ? -v : v;
                if (a > 1e-6) overMax_ = std::max(overMax_, lib::gainToDb(a * inv, -120.0));
                // Oversampled, the half-bands' phase lets the clipped wave overshoot the ceiling (by up to several dB
                // on clipped noise; measured 2026-11-11). Clip to 0 dB then clips once more at the base rate, so no
                // sample passes full scale; otherwise the overshoot stays, as clipping it again would bring the
                // aliases back (a 7 kHz test sine: aliases -15 dB at 1x, -48 dB at 2x, -53 dB at 4x and 8x, and
                // -18 dB when clipped again).
                double y = os_[c].process(v, curve);
                if (master_) y = std::clamp(y, -1.0, 1.0);
                else y = x[c] + (y * out - x[c]) * mix;
                *o[c] = static_cast<float>(y);
            }
        }
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(mode_);
        out[3] = static_cast<float>(driveDb_);
        out[4] = static_cast<float>(ceilingDb_);
        out[5] = static_cast<float>(knee_);
        out[6] = static_cast<float>(1 << os_[0].stages());
        out[7] = static_cast<float>(std::max(0.0, overMax_));  // how far the driven peak went past the ceiling
        out[8] = master_ ? 1.0f : 0.0f;
        out[9] = static_cast<float>(kCurvePoints);
        // The transfer curve: the output for inputs -1..1 (after drive, before output and mix).
        const double drive = lib::dbToGain(driveDb_), ceiling = lib::dbToGain(ceilingDb_);
        for (uint32_t k = 0; k < kCurvePoints; ++k) {
            const double x = -1.0 + 2.0 * k / (kCurvePoints - 1);
            out[10 + k] = watched ? static_cast<float>(ceiling * clipCurve(mode_, x * drive / ceiling, knee_)) : 0.0f;
        }
        overMax_ = -120.0;
        return 10 + kCurvePoints;
    }

private:
    Oversampling os_[2];
    Ramp drive_, ceiling_, out_, mix_;
    int mode_ = 0, prevMode_ = 0;
    bool fresh_ = true, master_ = false;
    double blend_ = 1.0, blendStep_ = 0.004, driveDb_ = 0, ceilingDb_ = -0.3, knee_ = 0.5, overMax_ = -120;
};

// ---------- Phase distortion ----------

enum PdParam : uint32_t { kPDrive, kPNormalize, kPTone, kPBias, kPSpread, kPMix, kPdCount };
constexpr uint32_t kPdCentre = 48;  // frames: the delay's centre, the declared latency
constexpr double kPdSwing = kPdCentre - 2;  // the most the delay moves, so it never reads under 2 frames back
constexpr uint32_t kPdRing = 256;   // power of two above twice the centre plus the interpolation's taps

const ParamTable& pdParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("drive", "Drive", 0.4, 0.0, 1.0);
        p.num("normalize", "Normalize", 1.0, 0.0, 1.0);
        p.expo("tone", "Tone", 4000.0, 100.0, 20000.0, "Hz");
        p.num("bias", "Bias", 0.0, -1.0, 1.0);
        p.num("spread", "Spread", 0.0, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& pdDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.phasedist", "Phase distortion", pdParams(), kPdCentre, 0);
    return d;
}

class PhaseDistortion final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return pdDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        for (auto& e : env_) e.setCoefficients(lib::timeCoefficient(0.001, sampleRate), lib::timeCoefficient(0.2, sampleRate));
        return true;
    }
    void clearState() noexcept override {
        for (auto& c : ring_) for (float& v : c) v = 0.0f;
        pos_ = 0;
        for (auto& f : tone_) f.clear();
        for (auto& e : env_) e.clear();
        drive_.reset(), norm_.reset(), bias_.reset(), spread_.reset(), mix_.reset();
        mod_[0] = mod_[1] = 0.0;
    }
    uint64_t idleFrames() const noexcept override { return kPdCentre * 2 + static_cast<uint64_t>(0.05 * rate()); }
    void control(uint32_t at) noexcept override {
        const double d = std::clamp(param(kPDrive, at), 0.0, 1.0);
        driveValue_ = d;
        drive_.set(d * d * kPdSwing, kControlFrames);  // the delay's swing either side of the centre, in frames
        normValue_ = std::clamp(param(kPNormalize, at), 0.0, 1.0);
        norm_.set(normValue_, kControlFrames);
        tone_[0].set(std::clamp(param(kPTone, at), 100.0, 20000.0), 0.70710678118654752, rate());
        tone_[1].setLike(tone_[0]);
        tone_[0].flushDenormals(), tone_[1].flushDenormals();  // on the control grid: the same bits at any block size
        biasValue_ = std::clamp(param(kPBias, at), -1.0, 1.0);
        spreadValue_ = std::clamp(param(kPSpread, at), 0.0, 1.0);
        bias_.set(biasValue_, kControlFrames);
        spread_.set(spreadValue_, kControlFrames);
        mix_.set(std::clamp(param(kPMix, at), 0.0, 1.0), kControlFrames);
        cubic_ = quality() != kQualityEco;  // Eco reads with linear interpolation
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        constexpr uint32_t mask = kPdRing - 1;
        for (uint32_t i = 0; i < n; ++i) {
            const double swing = drive_.next(), norm = norm_.next(), bias = bias_.next(), spread = spread_.next(), mix = mix_.next();
            ring_[0][pos_] = inL[i];
            ring_[1][pos_] = inR[i];
            const double x[2] = {inL[i], inR[i]};
            float* o[2] = {outL + i, outR + i};
            for (int c = 0; c < 2; ++c) {
                const double m = tone_[c].lowpass(x[c]);
                const double env = env_[c].process(m < 0 ? -m : m);
                // Normalize: the modulator over its own envelope (no more than 40 dB of lift), so the amount
                // doesn't depend on the input's level.
                const double lifted = m / std::max(env, 0.01);
                double mod = m + (lifted - m) * norm + bias + (c == 0 ? spread : -spread);
                mod = std::clamp(mod, -1.0, 1.0);
                mod_[c] = mod;
                const double delay = kPdCentre + swing * mod;  // 2 .. 94 frames
                const double back = static_cast<double>(pos_) - delay + kPdRing;
                const double fl = std::floor(back);
                const double t = back - fl;
                const uint32_t k = static_cast<uint32_t>(fl) & mask;
                const float* r = ring_[c];
                double wet;
                if (cubic_) {
                    // 4-point Hermite through r[k-1], r[k], r[k+1], r[k+2]: the delay is at least 2 frames, so
                    // k + 2 <= pos has been written.
                    const double y0 = r[(k - 1) & mask], y1 = r[k], y2 = r[(k + 1) & mask], y3 = r[(k + 2) & mask];
                    const double c1 = 0.5 * (y2 - y0), c2 = y0 - 2.5 * y1 + 2.0 * y2 - 0.5 * y3;
                    const double c3 = 0.5 * (y3 - y0) + 1.5 * (y1 - y2);
                    wet = ((c3 * t + c2) * t + c1) * t + y1;
                } else {
                    wet = r[k] + (r[(k + 1) & mask] - r[k]) * t;
                }
                const double dry = r[(pos_ - kPdCentre) & mask];
                *o[c] = static_cast<float>(dry + (wet - dry) * mix);
            }
            pos_ = (pos_ + 1) & mask;
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(driveValue_);
        out[3] = static_cast<float>(normValue_);
        out[4] = static_cast<float>(biasValue_);
        out[5] = static_cast<float>(spreadValue_);
        out[6] = static_cast<float>(mod_[0]);
        out[7] = static_cast<float>(mod_[1]);
        const double ms = 1000.0 / rate();
        out[8] = static_cast<float>((kPdCentre + driveValue_ * driveValue_ * kPdSwing * mod_[0]) * ms);
        out[9] = static_cast<float>((kPdCentre + driveValue_ * driveValue_ * kPdSwing * mod_[1]) * ms);
        return 10;
    }

private:
    float ring_[2][kPdRing] = {};
    uint32_t pos_ = 0;
    lib::Svf tone_[2];
    lib::EnvelopeFollower env_[2];
    Ramp drive_, norm_, bias_, spread_, mix_;
    double driveValue_ = 0.4, normValue_ = 1, biasValue_ = 0, spreadValue_ = 0, mod_[2] = {};
    bool cubic_ = true;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerFxDrive(ModuleRegistry& registry) {
    registry.add(clipDescriptor(), &make<Clipper>);
    registry.add(pdDescriptor(), &make<PhaseDistortion>);
}

}  // namespace caw::fx
