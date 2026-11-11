// The fx-space stereo effects: Haas widener with a mono check, a 3-band stereo imager with vectorscope, and a channel mixer.
#include "builtin_fx_space.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/library/filter.hpp"

// Original code (C.A.W. is Apache-2.0).

namespace caw::fx {

namespace {

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

// Sums for a correlation (and the mono-compatibility) since the last display.
struct StereoMeter {
    double lr = 0, ll = 0, rr = 0, sum = 0;
    void add(double l, double r) noexcept {
        lr += l * r, ll += l * l, rr += r * r;
        sum += (l + r) * (l + r);
    }
    // -1 (out of phase) .. 1 (mono); 0 for silence.
    double correlation() const noexcept {
        const double den = std::sqrt(ll * rr);
        return den > 1e-20 ? std::clamp(lr / den, -1.0, 1.0) : 0.0;
    }
    // The level the mono sum loses against the stereo, in dB: 0 for mono, -3 for unrelated sides, falling to -60
    // as the sides cancel.
    double monoLossDb() const noexcept {
        const double st = 2.0 * (ll + rr);
        if (st < 1e-20) return 0.0;
        return std::max(-60.0, 10.0 * std::log10(std::max(1e-6, sum / st)));
    }
    // -1 (all left) .. 1 (all right).
    double balance() const noexcept {
        const double t = ll + rr;
        return t > 1e-20 ? (rr - ll) / t : 0.0;
    }
    void clear() noexcept { lr = ll = rr = sum = 0; }
};

// ---------- Haas ----------

enum HaasParam : uint32_t { kHSide, kHDelay, kHGuard, kHLevel, kHMono, kHMix, kHaasCount };
constexpr std::string_view kSides[] = {"Left", "Right"};

const ParamTable& haasParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("side", "Delayed side", 1.0, kSides);
        p.num("delay", "Delay", 12.0, 0.0, 40.0, "ms");
        p.expo("guard", "Mono below", 150.0, 20.0, 1000.0, "Hz");
        p.num("level", "Delayed level", 0.0, -12.0, 6.0, "dB");
        p.pick("mono_check", "Mono check", 0.0, kOffOn);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& haasDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.haas", "Haas", haasParams(), 0, 2400);
    return d;
}

// The precedence (Haas) effect: one side delayed by up to 40 ms reads as width while the ear still places the
// sound at the earlier side. What it costs in mono is a comb (notches at odd multiples of 1 / (2 x delay)), so
// below `guard` the delayed side is left undelayed (a complementary split, flat when summed: the bass stays
// centred and mono-safe), the delayed side's level can be trimmed to re-centre it, Mono check sums the output to
// listen as a phone speaker would, and the display meters the correlation and the level lost in mono.
class Haas final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return haasDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override { return line_.prepare(0.05, sr); }
    void clearState() noexcept override {
        line_.clear();
        split_.clear();
        delay_.reset(), level_.reset(), mix_.reset();
        meter_.clear();
    }
    void control(uint32_t at) noexcept override {
        // Recursive states flushed once per control block (on the grid: the same at any block size).
        split_.flushDenormals();
        side_ = choice(kHSide, at) >= 1 ? 1 : 0;
        delayMs_ = std::clamp(param(kHDelay, at), 0.0, 40.0);
        delay_.set(delayMs_ * 0.001 * rate(), kControlFrames);
        const double guard = param(kHGuard, at);
        useGuard_ = guard > 20.5;
        split_.set(guard, 0.70710678118654752, rate());
        if (!useGuard_) split_.clear();
        level_.set(lib::dbToGain(std::clamp(param(kHLevel, at), -12.0, 6.0)), kControlFrames);
        mono_ = on(kHMono, at);
        mix_.set(std::clamp(param(kHMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            const double xs = x[side_];
            const double low = useGuard_ ? split_.lowpass(xs) : 0.0, high = xs - low;
            line_.write(high);
            const double d = delay_.next();
            const double back = d < 1.0 ? high + (line_.read(1.0) - high) * d : line_.read(d);
            double y[2] = {x[0], x[1]};
            y[side_] = low + back * level_.next();
            const double m = mix_.next();
            double l = x[0] + (y[0] - x[0]) * m, r = x[1] + (y[1] - x[1]) * m;
            meter_.add(l, r);
            if (mono_) l = r = 0.5 * (l + r);
            outL[i] = static_cast<float>(l);
            outR[i] = static_cast<float>(r);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(meter_.correlation());
        out[3] = static_cast<float>(meter_.monoLossDb());
        out[4] = static_cast<float>(delayMs_);
        out[5] = static_cast<float>(delayMs_ > 0.01 ? 500.0 / delayMs_ : 0.0);  // the first notch in mono, Hz
        out[6] = mono_ ? 1.0f : 0.0f;
        meter_.clear();
        return 7;
    }

private:
    ModLine line_;
    lib::Svf split_;
    Ramp delay_, level_, mix_;
    StereoMeter meter_;
    int side_ = 1;
    bool useGuard_ = true, mono_ = false;
    double delayMs_ = 12.0;
};

// ---------- Stereo imager ----------

enum ImagerParam : uint32_t { kILowFreq, kIHighFreq, kILowWidth, kIMidWidth, kIHighWidth, kIMidGain, kISideGain, kIOutput, kImagerCount };
constexpr uint32_t kScopePoints = 128;

const ParamTable& imagerParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.expo("low_freq", "Low / mid", 200.0, 40.0, 1000.0, "Hz");
        p.expo("high_freq", "Mid / high", 4000.0, 1000.0, 12000.0, "Hz");
        p.num("low_width", "Low width", 1.0, 0.0, 2.0);
        p.num("mid_width", "Mid width", 1.0, 0.0, 2.0);
        p.num("high_width", "High width", 1.0, 0.0, 2.0);
        p.num("mid_gain", "Mid", 0.0, -24.0, 12.0, "dB");
        p.num("side_gain", "Side", 0.0, -24.0, 12.0, "dB");
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& imagerDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.imager", "Imager", imagerParams(), 0, 0);
    return d;
}

// Three bands split by 4th-order Linkwitz-Riley crossovers (each two 2nd-order Butterworth sections, so a band's
// low and high parts sum back flat in level), the low band passed through the upper crossover's all-pass so all
// three line up in phase; each band's side scaled by its width (0: mono, 1: as is, 2: twice the side), then the
// mid and side gains and the output. The display meters the correlation per band and overall, the balance, and a
// vectorscope: the last 128 points (mid, side) of the output, one every 4 frames.
class Imager final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return imagerDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        for (auto& f : lo_) f.clear();
        for (auto& f : hi_) f.clear();
        for (auto& f : lo2_) f.clear();
        for (auto& f : hi2_) f.clear();
        for (auto& f : ap_) f.clear();
        for (auto& r : width_) r.reset();
        mid_.reset(), side_.reset();
        for (auto& m : band_) m.clear();
        meter_.clear();
        for (float& v : scope_) v = 0.0f;
        scopePos_ = scopeTick_ = 0;
    }
    void control(uint32_t at) noexcept override {
        // Recursive states flushed once per control block (on the grid: the same at any block size).
        for (auto& f : lo_) f.flushDenormals();
        for (auto& f : hi_) f.flushDenormals();
        for (auto& f : lo2_) f.flushDenormals();
        for (auto& f : hi2_) f.flushDenormals();
        for (auto& f : ap_) f.flushDenormals();
        const double sr = rate();
        const double f1 = param(kILowFreq, at), f2 = std::max(param(kIHighFreq, at), f1 * 1.5);
        constexpr double q = 0.70710678118654752;
        for (int c = 0; c < 2; ++c)
            for (int s = 0; s < 2; ++s) {
                lo_[2 * c + s].set(f1, q, sr), hi_[2 * c + s].set(f1, q, sr);
                lo2_[2 * c + s].set(f2, q, sr), hi2_[2 * c + s].set(f2, q, sr);
            }
        for (auto& f : ap_) f.set(f2, q, sr);
        width_[0].set(std::clamp(param(kILowWidth, at), 0.0, 2.0), kControlFrames);
        width_[1].set(std::clamp(param(kIMidWidth, at), 0.0, 2.0), kControlFrames);
        width_[2].set(std::clamp(param(kIHighWidth, at), 0.0, 2.0), kControlFrames);
        const double out = lib::dbToGain(param(kIOutput, at));
        mid_.set(lib::dbToGain(param(kIMidGain, at)) * out, kControlFrames);
        side_.set(lib::dbToGain(param(kISideGain, at)) * out, kControlFrames);
    }
    // The 4th-order sections of channel c's crossover (two Svf in series), and the low band's all-pass.
    double lp(lib::Svf* f, int c, double x) noexcept { return f[2 * c + 1].lowpass(f[2 * c].lowpass(x)); }
    double hp(lib::Svf* f, int c, double x) noexcept { return f[2 * c + 1].highpass(f[2 * c].highpass(x)); }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            double b[3][2];
            for (int c = 0; c < 2; ++c) {
                const double low = lp(lo_, c, x[c]), rest = hp(hi_, c, x[c]);
                const lib::SvfOutput a = ap_[c].process(low);
                b[0][c] = a.notch - 1.4142135623730951 * a.band;  // the upper crossover's 2nd-order all-pass
                b[1][c] = lp(lo2_, c, rest);
                b[2][c] = hp(hi2_, c, rest);
            }
            double mid = 0.0, side = 0.0;
            for (int k = 0; k < 3; ++k) {
                const double w = width_[k].next();
                band_[k].add(b[k][0], b[k][1]);
                mid += 0.5 * (b[k][0] + b[k][1]);
                side += 0.5 * (b[k][0] - b[k][1]) * w;
            }
            mid *= mid_.next();
            side *= side_.next();
            const double l = mid + side, r = mid - side;
            meter_.add(l, r);
            if (++scopeTick_ >= 4) {
                scopeTick_ = 0;
                scope_[2 * scopePos_] = static_cast<float>(mid);
                scope_[2 * scopePos_ + 1] = static_cast<float>(side);
                scopePos_ = (scopePos_ + 1) % kScopePoints;
            }
            outL[i] = static_cast<float>(l);
            outR[i] = static_cast<float>(r);
        }
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(meter_.correlation());
        out[3] = static_cast<float>(meter_.balance());
        for (int k = 0; k < 3; ++k) out[4 + k] = static_cast<float>(band_[k].correlation());
        out[7] = static_cast<float>(meter_.monoLossDb());
        out[8] = static_cast<float>(kScopePoints);
        for (uint32_t p = 0; p < kScopePoints; ++p) {  // oldest first
            const uint32_t at = (scopePos_ + p) % kScopePoints;
            const float m = scope_[2 * at], s = scope_[2 * at + 1];
            out[9 + 2 * p] = watched && std::isfinite(m) ? m : 0.0f;
            out[10 + 2 * p] = watched && std::isfinite(s) ? s : 0.0f;
        }
        meter_.clear();
        for (auto& m : band_) m.clear();
        return 9 + 2 * kScopePoints;
    }

private:
    lib::Svf lo_[4], hi_[4], lo2_[4], hi2_[4], ap_[2];
    Ramp width_[3], mid_, side_;
    StereoMeter band_[3], meter_;
    float scope_[2 * kScopePoints] = {};
    uint32_t scopePos_ = 0, scopeTick_ = 0;
};

// ---------- Channel mixer ----------

enum MixerParam : uint32_t { kLL, kRL, kLR, kRR, kMixerCount };

const ParamTable& mixerParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("left_to_left", "Left to left", 1.0, -1.0, 1.0);
        p.num("right_to_left", "Right to left", 0.0, -1.0, 1.0);
        p.num("left_to_right", "Left to right", 0.0, -1.0, 1.0);
        p.num("right_to_right", "Right to right", 1.0, -1.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& mixerDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.channelmixer", "Channel mixer", mixerParams(), 0, 0);
    return d;
}

// A 2 x 2 matrix: each output side is the two inputs scaled by -1 (inverted) .. 0 (none) .. 1 (as is). Swaps,
// mono folds, single-side copies and polarity flips are all corners of it.
class ChannelMixer final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return mixerDescriptor(); }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        for (auto& g : g_) g.reset();
        meter_.clear();
    }
    void control(uint32_t at) noexcept override {
        for (uint32_t k = 0; k < 4; ++k) g_[k].set(std::clamp(param(k, at), -1.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double l = inL[i], r = inR[i];
            const double ll = g_[kLL].next(), rl = g_[kRL].next(), lr = g_[kLR].next(), rr = g_[kRR].next();
            const double yl = l * ll + r * rl, yr = l * lr + r * rr;
            meter_.add(yl, yr);
            outL[i] = static_cast<float>(yl);
            outR[i] = static_cast<float>(yr);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(meter_.correlation());
        out[3] = static_cast<float>(meter_.balance());
        meter_.clear();
        return 4;
    }

private:
    Ramp g_[4];
    StereoMeter meter_;
};

}  // namespace

void registerFxSpaceStereo(ModuleRegistry& registry) {
    registry.add(haasDescriptor(), &make<Haas>);
    registry.add(imagerDescriptor(), &make<Imager>);
    registry.add(mixerDescriptor(), &make<ChannelMixer>);
}

}  // namespace caw::fx
