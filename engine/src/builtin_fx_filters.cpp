// The ladder filter ("org.caw.ladder") and the nonlinear filter ("org.caw.nlfilter") of the EQ & Filter group, and the group's registration.
#include "builtin_fx_filters.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/filter.hpp"
#include "caw/library/oversample.hpp"

// Original code (C.A.W. is Apache-2.0). Both are zero-delay-feedback (topology-preserving transform) filters, the
// form Zavalishin's "The Art of VA Filter Design" describes; the ladder solves its saturating feedback loop with
// Newton's method each sample, so it stays in tune and stable up to and past self-oscillation.

namespace caw::fx {

namespace {

using filters::Switch;

// ---------- Ladder ----------

enum LadderParam : uint32_t { kLMode, kLSlope, kLCutoff, kLResonance, kLDrive, kLBias, kLComp, kLMix, kLOutput, kLCount };
constexpr std::string_view kLadderModes[] = {"Low-pass", "Band-pass", "High-pass"};
constexpr std::string_view kSlopes[] = {"12 dB", "24 dB"};
// Resonance 1 is a feedback of 4.4: the loop self-oscillates from 4 (about 0.91 on the knob).
constexpr double kMaxFeedback = 4.4;

const ParamTable& ladderParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 0.0, kLadderModes);
        p.pick("slope", "Slope", 1.0, kSlopes);
        p.expo("cutoff", "Cutoff", 1000.0, 20.0, 20000.0, "Hz");
        p.num("resonance", "Resonance", 0.3, 0.0, 1.0);
        p.num("drive", "Drive", 0.0, 0.0, 36.0, "dB");
        p.num("bias", "Bias", 0.0, -1.0, 1.0);
        p.num("comp", "Bass comp", 0.5, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& ladderDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.ladder", "Ladder filter", ladderParams(), 0, kInfiniteTail);
    return d;
}

// The loop's coefficients, shared by both channels: four one-pole stages y = G in + (1 - G) s (TPT, G = g / (1 + g)).
struct LadderCoefs {
    double G = 0.5, G4 = 0.0625, b = 0.5, G2 = 0.25, G3 = 0.125, k = 0.0, bias = 0.0, tb = 0.0;
    void set(double cutoff, double sampleRate, double feedback, double biasIn) noexcept {
        const double g = detTan(kPi * cutoff / sampleRate);
        G = g / (1.0 + g);
        b = 1.0 - G;
        G2 = G * G, G3 = G2 * G, G4 = G3 * G;
        k = feedback;
        bias = biasIn;
        tb = lib::softClip(biasIn);
    }
};

// One channel's ladder. The first stage takes w = T(a - k y4), T(z) = tanh(z + bias) - tanh(bias) (the transistor
// pair's saturation; a bias tilts it, adding even harmonics; the tanh is filter.hpp's softClip, its rational
// stand-in, so a sample costs no exp). Since y4 = G^4 w + S (S from the states), w solves
// w = T(a - k S - k G^4 w): started from the linear solution and refined by two Newton steps (f' >= 1, so it
// converges fast), w is bounded by T's range whatever the feedback, and the stages after it are stable one-poles.
struct LadderChannel {
    double s[4] = {0, 0, 0, 0};
    double w = 0, y[4] = {0, 0, 0, 0};
    void step(const LadderCoefs& c, double a) noexcept {
        const double S = c.b * (c.G3 * s[0] + c.G2 * s[1] + c.G * s[2] + s[3]);
        const double base = a - c.k * S, kg = c.k * c.G4;
        double u = base / (1.0 + kg);  // the linear loop's answer
        u = u > 3.0 ? 3.0 : (u < -3.0 ? -3.0 : u);
        for (int it = 0; it < 2; ++it) {
            const double t = lib::softClip(base - kg * u + c.bias);
            const double f = u - (t - c.tb), d = 1.0 + kg * (1.0 - t * t);  // tanh's slope: near enough for Newton
            u -= f / d;
        }
        w = u;
        double in = u;
        for (int i = 0; i < 4; ++i) {
            const double v = (in - s[i]) * c.G;
            y[i] = v + s[i];
            s[i] = filters::guard(y[i] + v);
            in = y[i];
        }
    }
    // The output for a tap: mode * 2 + slope (24 dB = 1). Pole mixing (H = one stage): LP y2 or y4, BP 2 w H (1-H)
    // or 4 w H^2 (1-H)^2, HP w (1-H)^2 or w (1-H)^4, each unity at its passband's middle.
    double tap(int t, double hpScale) const noexcept {
        switch (t) {
            case 0: return y[1];
            case 1: return y[3];
            case 2: return 2.0 * (y[0] - y[1]) * hpScale;
            case 3: return 4.0 * (y[1] - 2.0 * y[2] + y[3]) * hpScale;
            case 4: return (w - 2.0 * y[0] + y[1]) * hpScale;
            default: return (w - 4.0 * y[0] + 6.0 * y[1] - 4.0 * y[2] + y[3]) * hpScale;
        }
    }
    void clear() noexcept {
        for (int i = 0; i < 4; ++i) s[i] = y[i] = 0.0;
        w = 0.0;
    }
    void flush() noexcept {
        for (double& v : s)
            if (v < 1e-20 && v > -1e-20) v = 0.0;
    }
};

class LadderEffect final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return ladderDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        tap_.prepare(sr);
        return true;
    }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) ch_[c].clear(), os_[c].clear();
        mix_.reset(), drive_.reset(), out_.reset(), scale_.reset();
        first_ = true;
    }
    void control(uint32_t at) noexcept override {
        for (int c = 0; c < 2; ++c) ch_[c].flush();  // subnormal tails, at the grid (block-size independent)
        const int tap = std::clamp(choice(kLMode, at), 0, 2) * 2 + std::clamp(choice(kLSlope, at), 0, 1);
        if (first_) tap_.snap(tap);
        else tap_.set(tap);
        const int factor = quality() == kQualityHigh ? 2 : 1;
        if (factor != factor_ && !first_)
            for (auto& o : os_) o.clear();
        factor_ = factor;
        first_ = false;
        cutoff_ = std::clamp(param(kLCutoff, at), 20.0, 0.45 * rate());
        resonance_ = std::clamp(param(kLResonance, at), 0.0, 1.0);
        const double k = kMaxFeedback * resonance_;
        coefs_.set(cutoff_, rate() * factor_, k, 0.6 * std::clamp(param(kLBias, at), -1.0, 1.0));
        driveDb_ = std::clamp(param(kLDrive, at), 0.0, 36.0);
        const double comp = 1.0 + std::clamp(param(kLComp, at), 0.0, 1.0) * k;  // the passband's loss, made up
        const double g = lib::dbToGain(driveDb_);
        // Small signals see the loop as linear at drive 0 dB; drive pushes it into the tanh, and the output is
        // brought back by half the drive's dB (it saturates, so the level rises less than the drive).
        drive_.set(g * comp, kControlFrames);
        scale_.set(1.0 / comp, kControlFrames);
        out_.set(lib::dbToGain(std::clamp(param(kLOutput, at), -24.0, 24.0)) / std::sqrt(g), kControlFrames);
        mix_.set(std::clamp(param(kLMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double drive = drive_.next(), sc = scale_.next(), out = out_.next(), mix = mix_.next();
            const double x[2] = {inL[i], inR[i]};
            const double tw = tap_.fading() ? tap_.next() : 1.0;
            double y[2];
            for (int c = 0; c < 2; ++c) {
                const double a = finiteOr0(x[c]) * drive;
                double v;
                if (factor_ == 2) {
                    double up[2];
                    os_[c].up(a, up);
                    for (double& u : up) u = filtered(ch_[c], u, tw, sc);
                    v = os_[c].down(up);
                } else {
                    v = filtered(ch_[c], a, tw, sc);
                }
                y[c] = x[c] + (v * out - x[c]) * mix;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(tap_.to / 2);
        out[3] = static_cast<float>(tap_.to % 2);
        out[4] = static_cast<float>(cutoff_);
        out[5] = static_cast<float>(resonance_);
        out[6] = static_cast<float>(driveDb_);
        out[7] = resonance_ * kMaxFeedback >= 4.0 ? 1.0f : 0.0f;  // self-oscillating
        out[8] = static_cast<float>(factor_);
        return 9;
    }

private:
    double filtered(LadderChannel& ch, double a, double tw, double sc) noexcept {
        ch.step(coefs_, a);
        const double hp = tap_.to >= 2 ? sc : 1.0, hpFrom = tap_.from >= 2 ? sc : 1.0;
        const double now = ch.tap(tap_.to, hp);
        return tw >= 1.0 ? now : ch.tap(tap_.from, hpFrom) + (now - ch.tap(tap_.from, hpFrom)) * tw;
    }
    LadderCoefs coefs_;
    LadderChannel ch_[2];
    lib::Oversampler2x os_[2];
    Switch tap_;
    Ramp mix_, drive_, out_, scale_;
    double cutoff_ = 1000.0, resonance_ = 0.3, driveDb_ = 0.0;
    int factor_ = 1;
    bool first_ = true;
};

ModuleProcessor* makeLadder() noexcept { return new (std::nothrow) LadderEffect(); }

// ---------- Nonlinear filter ----------

enum NlParam : uint32_t { kNType, kNCutoff, kNQ, kNDrive, kNShape, kNMix, kNOutput, kNCount };
constexpr std::string_view kNlTypes[] = {"Low-pass", "Band-pass", "High-pass", "Notch", "All-pass"};
constexpr std::string_view kNlShapes[] = {"Clean", "Warm", "Diode", "Hard", "Fold", "Rectify"};
enum NlShape : int { kClean, kWarm, kDiode, kHard, kFold, kRectify };

const ParamTable& nlParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("type", "Type", 0.0, kNlTypes);
        p.expo("cutoff", "Cutoff", 1200.0, 20.0, 20000.0, "Hz");
        p.expo("q", "Q", 2.0, 0.5, 25.0);
        p.num("drive", "Drive", 12.0, 0.0, 36.0, "dB");
        p.pick("shape", "Shape", 1.0, kNlShapes);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& nlDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.nlfilter", "Nonlinear filter", nlParams(), 0, 0);
    return d;
}

// The loop's nonlinearity, each with slope 1 at 0 (small signals pass as the clean filter): a tanh, a diode's
// lopsided curve (soft on one side, harder on the other), a hard clip, a sine fold (it turns back past 1.57,
// metallic), and a rectifier-flavoured curve (the negative half folded up a little: octave-ish growl).
inline double shapeOf(int shape, double v) noexcept {
    switch (shape) {
        case kWarm: return lib::tanhApprox(v);
        case kDiode: return v >= 0.0 ? lib::tanhApprox(v) : 0.6 * lib::tanhApprox(v / 0.6);
        case kHard: return v > 1.0 ? 1.0 : (v < -1.0 ? -1.0 : v);
        case kFold: {
            const double c = v > 6.0 ? 6.0 : (v < -6.0 ? -6.0 : v);
            return lib::fastSinCycles(c / kTwoPi);
        }
        case kRectify: {
            const double t = lib::tanhApprox(v);
            return t + 0.35 * t * t - 0.35 * lib::tanhApprox(v * v * 0.25);  // slope 1 at 0, a bent, lopsided top
        }
        default: return v;
    }
}

// One channel's state-variable filter (TPT, 12 dB/octave) with the shape on its band-pass integrator: the band
// state saturates (as an OTA's integrator does), so resonance and drive bend the filter rather than clip after
// it, and a loud resonance can no longer grow without bound.
struct NlChannel {
    double s1 = 0, s2 = 0;
    // `rk` is sqrt(k): the band is shaped at sqrt(k) times its level, so a high Q (whose band state runs Q times
    // the input) saturates sooner, but not Q times sooner.
    double step(double x, double g, double k, double rk, double h, int shape, int type) noexcept {
        const double hp = (x - (k + g) * s1 - s2) * h;
        double bp = g * hp + s1;
        if (shape != kClean) bp = shapeOf(shape, bp * rk) / rk;
        s1 = filters::guard(2.0 * bp - s1, 1e3);
        const double lp = g * bp + s2;
        s2 = filters::guard(2.0 * lp - s2, 1e3);
        switch (type) {
            case 1: return k * bp;
            case 2: return x - k * bp - lp;
            case 3: return x - k * bp;
            case 4: return x - 2.0 * k * bp;
            default: return lp;
        }
    }
    void clear() noexcept { s1 = s2 = 0.0; }
    void flush() noexcept {
        if (s1 < 1e-20 && s1 > -1e-20) s1 = 0.0;
        if (s2 < 1e-20 && s2 > -1e-20) s2 = 0.0;
    }
};

class NonlinearFilter final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return nlDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        mode_.prepare(sr);
        return true;
    }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) a_[c].clear(), b_[c].clear(), os_[c].clear();
        mix_.reset(), drive_.reset(), out_.reset();
        first_ = true;
    }
    void control(uint32_t at) noexcept override {
        for (int c = 0; c < 2; ++c) a_[c].flush(), b_[c].flush();  // subnormal tails, at the grid
        // A type or shape change fades to a freshly cleared second filter (two filters run during the fade).
        const int mode = std::clamp(choice(kNType, at), 0, 4) * 8 + std::clamp(choice(kNShape, at), 0, 5);
        if (first_) mode_.snap(mode);
        else if (mode != mode_.to && !mode_.fading()) {
            for (int c = 0; c < 2; ++c) std::swap(a_[c], b_[c]), a_[c].clear();
            mode_.set(mode);
        }
        const int factor = quality() == kQualityHigh ? 2 : 1;
        if (factor != factor_ && !first_)
            for (auto& o : os_) o.clear();
        factor_ = factor;
        first_ = false;
        cutoff_ = std::clamp(param(kNCutoff, at), 20.0, 0.45 * rate());
        q_ = std::clamp(param(kNQ, at), 0.5, 25.0);
        g_ = detTan(kPi * cutoff_ / (rate() * factor_));
        k_ = 1.0 / q_;
        rk_ = std::sqrt(k_);
        h_ = 1.0 / (1.0 + k_ * g_ + g_ * g_);
        driveDb_ = std::clamp(param(kNDrive, at), 0.0, 36.0);
        const double g = lib::dbToGain(driveDb_);
        drive_.set(g, kControlFrames);
        // Clean is linear: the drive is taken back off exactly. A shape saturates, so only half the drive's dB is.
        clean_ = std::clamp(choice(kNShape, at), 0, 5) == kClean;
        out_.set(lib::dbToGain(std::clamp(param(kNOutput, at), -24.0, 24.0)) / (clean_ ? g : std::sqrt(g)), kControlFrames);
        mix_.set(std::clamp(param(kNMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double drive = drive_.next(), out = out_.next(), mix = mix_.next();
            const double fade = mode_.fading() ? mode_.next() : 1.0;
            const double x[2] = {inL[i], inR[i]};
            double y[2];
            for (int c = 0; c < 2; ++c) {
                double a = finiteOr0(x[c]) * drive;
                // Driven into a shape, the input meets a soft ceiling at 4 (the band saturates near 1): the dry part
                // a high-pass, notch or all-pass passes stays bounded however hard it is driven.
                if (!clean_) a = 4.0 * lib::tanhApprox(0.25 * a);
                double v;
                if (factor_ == 2) {
                    double up[2];
                    os_[c].up(a, up);
                    for (double& u : up) u = filtered(c, u, fade);
                    v = os_[c].down(up);
                } else {
                    v = filtered(c, a, fade);
                }
                y[c] = x[c] + (v * out - x[c]) * mix;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(mode_.to / 8);
        out[3] = static_cast<float>(mode_.to % 8);
        out[4] = static_cast<float>(cutoff_);
        out[5] = static_cast<float>(q_);
        out[6] = static_cast<float>(driveDb_);
        return 7;
    }

private:
    double filtered(int c, double a, double fade) noexcept {
        const double now = a_[c].step(a, g_, k_, rk_, h_, mode_.to % 8, mode_.to / 8);
        if (fade >= 1.0) return now;
        const double was = b_[c].step(a, g_, k_, rk_, h_, mode_.from % 8, mode_.from / 8);
        return was + (now - was) * fade;
    }
    NlChannel a_[2], b_[2];  // a_: the filter heard; b_: the one fading out
    lib::Oversampler2x os_[2];
    Switch mode_;
    Ramp mix_, drive_, out_;
    double cutoff_ = 1200.0, q_ = 2.0, driveDb_ = 12.0, g_ = 0.1, k_ = 0.5, rk_ = 0.7, h_ = 1.0;
    int factor_ = 1;
    bool first_ = true, clean_ = false;
};

ModuleProcessor* makeNl() noexcept { return new (std::nothrow) NonlinearFilter(); }

}  // namespace

void registerLadderAndNonlinear(ModuleRegistry& registry) {
    registry.add(ladderDescriptor(), &makeLadder);
    registry.add(nlDescriptor(), &makeNl);
}

void registerFilters(ModuleRegistry& registry) {
    registerLadderAndNonlinear(registry);
    registerCombAndResonator(registry);
    registerFormantAndDisperser(registry);
    registerFilterEqs(registry);
}

}  // namespace caw::fx
