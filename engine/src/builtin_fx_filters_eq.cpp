// The DJ 3-band EQ ("org.caw.eq.dj"), the tilt EQ ("org.caw.tilt") and the 31-band graphic EQ ("org.caw.geq") of the EQ & Filter group.
#include "builtin_fx_filters.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <string>

#include "caw/library/eq.hpp"
#include "caw/library/spectrum.hpp"

// Original code (C.A.W. is Apache-2.0). The 3-band EQ splits with Linkwitz-Riley 4th-order crossovers (two
// Butterworth stages each; Linkwitz, "Active crossover networks for noncoincident drivers", JAES 1976) and an
// all-pass on the low band, so the bands sum back flat. The graphic EQ is a cascade of proportional bells whose
// gains are corrected for their overlap by an interaction matrix (the method of Välimäki & Liski, "Accurate
// cascade graphic equalizer", IEEE Signal Processing Letters 24(2), 2017, here in one linear step).

namespace caw::fx {

namespace {

using filters::lane;
using filters::Pair;
using filters::pairOf;

// A TPT state-variable stage with all its outputs.
struct Stage {
    double a1 = 1, a2 = 0, a3 = 0, k = 1.4142135623730951;
    void set(double hz, double q, double sr) noexcept {
        const double g = detTan(kPi * std::clamp(hz, 10.0, 0.49 * sr) / sr);
        k = 1.0 / q;
        a1 = 1.0 / (1.0 + g * (g + k));
        a2 = g * a1;
        a3 = g * a2;
    }
};
struct StageState {
    double ic1 = 0, ic2 = 0, band = 0, low = 0;
    // Returns the high-pass; band and low are kept.
    double step(const Stage& c, double x) noexcept {
        const double v3 = x - ic2;
        band = c.a1 * ic1 + c.a2 * v3;
        low = ic2 + c.a2 * ic1 + c.a3 * v3;
        ic1 = 2.0 * band - ic1;
        ic2 = 2.0 * low - ic2;
        return x - c.k * band - low;
    }
    void clear() noexcept { ic1 = ic2 = band = low = 0.0; }
    void flush() noexcept {
        if (ic1 < 1e-20 && ic1 > -1e-20) ic1 = 0.0;
        if (ic2 < 1e-20 && ic2 > -1e-20) ic2 = 0.0;
    }
};

// ---------- 3-band EQ ----------

enum Eq3Param : uint32_t { kELow, kEMid, kEHigh, kEKillLow, kEKillMid, kEKillHigh, kELowX, kEHighX, kEOutput, kECount };

const ParamTable& eq3Params() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("low", "Low", 0.0, -24.0, 12.0, "dB");
        p.num("mid", "Mid", 0.0, -24.0, 12.0, "dB");
        p.num("high", "High", 0.0, -24.0, 12.0, "dB");
        p.pick("kill_low", "Kill low", 0.0, kOffOn);
        p.pick("kill_mid", "Kill mid", 0.0, kOffOn);
        p.pick("kill_high", "Kill high", 0.0, kOffOn);
        p.expo("low_x", "Low / mid", 250.0, 40.0, 1000.0, "Hz");
        p.expo("high_x", "Mid / high", 2500.0, 1000.0, 12000.0, "Hz");
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& eq3Descriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.eq.dj", "3-band EQ", eq3Params(), 0, 0);
    return d;
}

class Eq3 final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return eq3Descriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        glide_ = 1.0 - detExp(-1.0 / (0.004 * sr));  // a kill or a gain glides over ~4 ms (no click)
        return true;
    }
    void clearState() noexcept override {
        for (auto& c : ch_)
            for (StageState& s : c.s) s.clear();
        fresh_ = true;
        for (double& p : peak_) p = 0.0;
    }
    void control(uint32_t at) noexcept override {
        for (auto& c : ch_)  // subnormal tails, at the grid
            for (StageState& s : c.s) s.flush();
        const double sr = rate();
        lowX_ = std::clamp(param(kELowX, at), 40.0, 1000.0);
        highX_ = std::clamp(param(kEHighX, at), std::max(1000.0, lowX_ * 1.5), 12000.0);
        highX_ = std::min(highX_, 0.45 * sr);
        constexpr double kButter = 0.70710678118654752;
        low_.set(lowX_, kButter, sr);
        high_.set(highX_, kButter, sr);
        for (int b = 0; b < 3; ++b) {
            db_[b] = std::clamp(param(kELow + b, at), -24.0, 12.0);
            kill_[b] = on(kEKillLow + b, at);
            target_[b] = kill_[b] ? 0.0 : lib::dbToGain(db_[b]);
        }
        outTarget_ = lib::dbToGain(std::clamp(param(kEOutput, at), -24.0, 12.0));
        if (fresh_) {
            for (int b = 0; b < 3; ++b) gain_[b] = target_[b];
            out_ = outTarget_;
            fresh_ = false;
        }
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            for (int b = 0; b < 3; ++b) gain_[b] += (target_[b] - gain_[b]) * glide_;
            out_ += (outTarget_ - out_) * glide_;
            const double x[2] = {finiteOr0(inL[i]), finiteOr0(inR[i])};
            double y[2];
            for (int c = 0; c < 2; ++c) {
                StageState* s = ch_[c].s;
                // First split at the low crossover: one stage gives both first halves, then a second each.
                const double hp1 = s[0].step(low_, x[c]);
                const double lp1 = s[0].low;
                s[1].step(low_, lp1);
                const double lowBand0 = s[1].low;
                const double rest = s[2].step(low_, hp1);
                // The low band through the high crossover's all-pass (LR4's sum: x - 2 k band, Q 0.707).
                s[3].step(high_, lowBand0);
                const double lowBand = lowBand0 - 2.0 * high_.k * s[3].band;
                const double hp2 = s[4].step(high_, rest);
                const double lp2 = s[4].low;
                s[5].step(high_, lp2);
                const double mid = s[5].low;
                const double hi = s[6].step(high_, hp2);
                const double bands[3] = {lowBand, mid, hi};
                for (int b = 0; b < 3; ++b) peak_[b] = std::max(peak_[b], std::fabs(bands[b]));
                y[c] = (lowBand * gain_[0] + mid * gain_[1] + hi * gain_[2]) * out_;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        for (int b = 0; b < 3; ++b) {
            out[2 + b] = static_cast<float>(lib::gainToDb(peak_[b]));  // each band's peak before its gain
            out[5 + b] = kill_[b] ? 1.0f : 0.0f;
            peak_[b] = 0.0;
        }
        out[8] = static_cast<float>(lowX_);
        out[9] = static_cast<float>(highX_);
        return 10;
    }

private:
    struct Channel {
        StageState s[7];
    };
    Stage low_, high_;
    Channel ch_[2];
    double db_[3] = {0, 0, 0}, target_[3] = {1, 1, 1}, gain_[3] = {1, 1, 1}, peak_[3] = {0, 0, 0};
    bool kill_[3] = {false, false, false}, fresh_ = true;
    double lowX_ = 250.0, highX_ = 2500.0, out_ = 1.0, outTarget_ = 1.0, glide_ = 0.005;
};

ModuleProcessor* makeEq3() noexcept { return new (std::nothrow) Eq3(); }

// ---------- Tilt EQ ----------

enum TiltParam : uint32_t { kTTilt, kTFreq, kTQ, kTChannel, kTOutput, kTCount };
constexpr std::string_view kTiltChannels[] = {"Stereo", "Mid", "Side"};

const ParamTable& tiltParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("tilt", "Tilt", 0.0, -12.0, 12.0, "dB");
        p.expo("freq", "Pivot", 800.0, 100.0, 10000.0, "Hz");
        p.expo("q", "Steepness", 0.5, 0.3, 1.5);
        p.pick("channel", "Channel", 0.0, kTiltChannels);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& tiltDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.tilt", "Tilt EQ", tiltParams(), 0, 0);
    return d;
}

// The tilt is the parametric EQ's Tilt band (eq.hpp: a high shelf at the pivot, the whole curve down by half the
// tilt): `tilt` dB from the lows to the highs, 0 dB at the pivot, steeper with Q. A channel change fades the
// filter out and back in (5 ms) with a clean state.
class TiltEq final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return tiltDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        fadeStep_ = 1.0 / (0.005 * sr);
        glide_ = 1.0 - detExp(-1.0 / (0.005 * sr));
        return true;
    }
    void clearState() noexcept override {
        clearStates();
        first_ = true;
    }
    void control(uint32_t at) noexcept override {
        tilt_ = std::clamp(param(kTTilt, at), -12.0, 12.0);
        freq_ = std::clamp(param(kTFreq, at), 100.0, 10000.0);
        q_ = std::clamp(param(kTQ, at), 0.3, 1.5);
        filter_.set(lib::EqType::Tilt, freq_, tilt_, q_, rate());
        const int channel = std::clamp(choice(kTChannel, at), 0, 2);
        if (first_) channel_ = channel, w_ = 1.0;
        if (channel != channel_ && w_ == 0.0) {
            channel_ = channel;
            clearStates();
        }
        target_ = channel == channel_ ? 1.0 : 0.0;
        outTarget_ = lib::dbToGain(std::clamp(param(kTOutput, at), -24.0, 24.0));
        if (first_) out_ = outTarget_;
        first_ = false;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            if (w_ != target_) w_ = target_ > w_ ? std::min(1.0, w_ + fadeStep_) : std::max(0.0, w_ - fadeStep_);
            out_ += (outTarget_ - out_) * glide_;
            double l = finiteOr0(inL[i]), r = finiteOr0(inR[i]);
            if (!filter_.identity()) {
                switch (channel_) {
                    case 1: {
                        const double m = 0.5 * (l + r), s = 0.5 * (l - r);
                        const double y = m + (filter_.process(st_[0], m) - m) * w_;
                        l = y + s, r = y - s;
                        break;
                    }
                    case 2: {
                        const double m = 0.5 * (l + r), s = 0.5 * (l - r);
                        const double y = s + (filter_.process(st_[0], s) - s) * w_;
                        l = m + y, r = m - y;
                        break;
                    }
                    default:
                        l += (filter_.process(st_[0], l) - l) * w_;
                        r += (filter_.process(st_[1], r) - r) * w_;
                        break;
                }
            } else {
                clearStates();
            }
            outL[i] = static_cast<float>(l * out_);
            outR[i] = static_cast<float>(r * out_);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(tilt_);
        out[3] = static_cast<float>(freq_);
        out[4] = static_cast<float>(q_);
        out[5] = static_cast<float>(channel_);
        return 6;
    }

private:
    void clearStates() noexcept {
        for (auto& side : st_)
            for (lib::SvfState& s : side) s.clear();
    }
    lib::EqFilter filter_;
    lib::SvfState st_[2][lib::EqFilter::kMaxStages];
    double tilt_ = 0, freq_ = 800, q_ = 0.5, w_ = 1, target_ = 1, fadeStep_ = 0.004, out_ = 1, outTarget_ = 1, glide_ = 0.004;
    int channel_ = 0;
    bool first_ = true;
};

ModuleProcessor* makeTilt() noexcept { return new (std::nothrow) TiltEq(); }

// ---------- Graphic EQ ----------

constexpr int kGBands = 31;
// The ISO 266 third-octave centres, 20 Hz to 20 kHz.
constexpr double kIsoHz[kGBands] = {20,   25,   31.5, 40,   50,   63,    80,    100,   125,   160,  200,
                                    250,  315,  400,  500,  630,  800,   1000,  1250,  1600,  2000, 2500,
                                    3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000};
constexpr const char* kIsoNames[kGBands] = {"20 Hz",  "25 Hz",  "31.5 Hz", "40 Hz",  "50 Hz",  "63 Hz",  "80 Hz",
                                            "100 Hz", "125 Hz", "160 Hz",  "200 Hz", "250 Hz", "315 Hz", "400 Hz",
                                            "500 Hz", "630 Hz", "800 Hz",  "1 kHz",  "1.25 kHz", "1.6 kHz", "2 kHz",
                                            "2.5 kHz", "3.15 kHz", "4 kHz", "5 kHz",  "6.3 kHz", "8 kHz",  "10 kHz",
                                            "12.5 kHz", "16 kHz", "20 kHz"};
// Each bell is half an octave wide (1.5 band spacings, as Välimäki & Liski advise, so neighbours blend smoothly).
constexpr double kGQ = 2.871;
constexpr double kGProbeDb = 12.0;  // the interaction matrix's probe gain
enum GeqParam : uint32_t { kGRange = kGBands, kGOutput, kGCount };
constexpr uint32_t kGBins = 64;

const ParamTable& geqParams() {
    static const ParamTable t = [] {
        ParamTable p;
        for (int b = 0; b < kGBands; ++b) p.num("g" + std::to_string(b + 1), kIsoNames[b], 0.0, -12.0, 12.0, "dB");
        p.num("range", "Range", 1.0, 0.0, 1.5);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& geqDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.geq", "Graphic EQ", geqParams(), 0, 0);
    return d;
}

class GraphicEq final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return geqDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        try {
            analyzer_.prepare(sr, kGBins, 20.0, 20000.0);
        } catch (...) {
            return false;
        }
        for (uint32_t j = 0; j < kGBins; ++j) binTan_[j] = std::tan(kPi * std::min(analyzer_.binHz(j), 0.49 * sr) / sr);
        // The bands that fit under 0.45 of the rate, and the LU factors of their interaction matrix: B[i][j] is
        // band j's response in dB at band i's centre, per dB of its gain (probed at 12 dB).
        bands_ = 0;
        while (bands_ < kGBands && kIsoHz[bands_] < 0.45 * sr) ++bands_;
        for (int j = 0; j < bands_; ++j) {
            lib::EqFilter probe;
            probe.set(lib::EqType::Bell, kIsoHz[j], kGProbeDb, kGQ, sr);
            for (int i = 0; i < bands_; ++i) {
                const double t = std::tan(kPi * kIsoHz[i] / sr);
                lu_[i][j] = 10.0 * std::log10(probe.magnitude2(t)) / kGProbeDb;
            }
        }
        // Doolittle LU without pivoting: the matrix is diagonally dominant (each bell is strongest at its centre).
        for (int k = 0; k < bands_; ++k)
            for (int i = k + 1; i < bands_; ++i) {
                lu_[i][k] /= lu_[k][k];
                for (int j = k + 1; j < bands_; ++j) lu_[i][j] -= lu_[i][k] * lu_[k][j];
            }
        glide_ = 1.0 - detExp(-1.0 / (0.005 * sr));
        return true;
    }
    void clearState() noexcept override {
        for (int b = 0; b < kGBands; ++b) ic1_[b] = ic2_[b] = pairOf(0.0, 0.0);
        analyzer_.clear();
        for (double& t : target_) t = 1e9;  // the next control solves afresh
        first_ = true;
    }
    void control(uint32_t at) noexcept override {
        for (int b = 0; b < kGBands; ++b) ic1_[b] = filters::flushPair(ic1_[b]), ic2_[b] = filters::flushPair(ic2_[b]);  // at the grid
        const double range = std::clamp(param(kGRange, at), 0.0, 1.5);
        bool changed = false;
        double want[kGBands];
        for (int b = 0; b < kGBands; ++b) {
            want[b] = std::clamp(param(static_cast<uint32_t>(b), at), -12.0, 12.0) * range;
            if (want[b] != target_[b]) changed = true;
        }
        if (changed) {
            for (int b = 0; b < kGBands; ++b) target_[b] = want[b];
            // Gains that make the cascade's response hit the targets at the centres: solve B g = t.
            double g[kGBands];
            for (int i = 0; i < bands_; ++i) {
                double s = target_[i];
                for (int j = 0; j < i; ++j) s -= lu_[i][j] * g[j];
                g[i] = s;
            }
            for (int i = bands_ - 1; i >= 0; --i) {
                double s = g[i];
                for (int j = i + 1; j < bands_; ++j) s -= lu_[i][j] * g[j];
                g[i] = std::clamp(s / lu_[i][i], -24.0, 24.0);
            }
            active_ = 0;
            for (int b = 0; b < bands_; ++b) {
                gain_[b] = std::fabs(g[b]) < 0.01 ? 0.0 : g[b];
                filters_[b].set(lib::EqType::Bell, kIsoHz[b], gain_[b], kGQ, rate());  // for the display's curve
                if (filters_[b].identity()) {
                    ic1_[b] = ic2_[b] = pairOf(0.0, 0.0);
                    continue;
                }
                // The bell (eq.hpp's: g = tan(pi f / rate), k = 1 / (Q A), y = x + k (A^2 - 1) band), both sides.
                const double A = detPow(10.0, gain_[b] / 40.0), g = detTan(kPi * kIsoHz[b] / rate()), k = 1.0 / (kGQ * A);
                const double a1 = 1.0 / (1.0 + g * (g + k));
                bell_[active_] = {pairOf(a1, a1), pairOf(g * a1, g * a1), pairOf(g * g * a1, g * g * a1),
                                  pairOf(k * (A * A - 1.0), k * (A * A - 1.0)), b};
                order_[active_++] = static_cast<uint8_t>(b);
            }
        }
        outTarget_ = lib::dbToGain(std::clamp(param(kGOutput, at), -24.0, 12.0));
        if (first_) out_ = outTarget_;
        first_ = false;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            out_ += (outTarget_ - out_) * glide_;
            const double xl = finiteOr0(inL[i]), xr = finiteOr0(inR[i]);
            Pair v = pairOf(xl, xr);
            const Pair two = pairOf(2.0, 2.0);
            for (int a = 0; a < active_; ++a) {
                const Bell& c = bell_[a];
                Pair& s1 = ic1_[c.band];
                Pair& s2 = ic2_[c.band];
                const Pair v3 = v - s2;
                const Pair band = c.a1 * s1 + c.a2 * v3;
                const Pair low = s2 + c.a2 * s1 + c.a3 * v3;
                s1 = two * band - s1;
                s2 = two * low - s2;
                v = v + c.m1 * band;
            }
            const double l = lane(v, 0) * out_, r = lane(v, 1) * out_;
            outL[i] = static_cast<float>(l);
            outR[i] = static_cast<float>(r);
            analyzer_.push(static_cast<float>(0.5 * (xl + xr)), static_cast<float>(0.5 * (l + r)));
        }
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(kGBins);
        out[3] = watched ? 1.0f : 0.0f;
        float* post = out + 4;
        float* curve = out + 4 + kGBins;
        if (watched) {
            float pre[kGBins];
            analyzer_.analyze(pre, post);
            for (uint32_t j = 0; j < kGBins; ++j) {
                double m = out_ * out_;
                for (int a = 0; a < active_; ++a) m *= filters_[order_[a]].magnitude2(binTan_[j]);
                curve[j] = static_cast<float>(m > 1e-24 ? 10.0 * std::log10(m) : -240.0);
            }
        } else {
            for (uint32_t j = 0; j < 2 * kGBins; ++j) post[j] = -120.0f;
        }
        return 4 + 2 * kGBins;
    }

private:
    struct Bell {
        Pair a1, a2, a3, m1;
        int band;
    };
    lib::EqFilter filters_[kGBands];  // the bells' responses, for the display
    Bell bell_[kGBands];               // the sounding bells, in order
    Pair ic1_[kGBands], ic2_[kGBands];  // each band's two states, left and right side by side
    double lu_[kGBands][kGBands] = {};
    double target_[kGBands] = {}, gain_[kGBands] = {}, binTan_[kGBins] = {};
    uint8_t order_[kGBands] = {};
    int bands_ = kGBands, active_ = 0;
    double out_ = 1.0, outTarget_ = 1.0, glide_ = 0.004;
    bool first_ = true;
    lib::SpectrumAnalyzer analyzer_;
};

ModuleProcessor* makeGeq() noexcept { return new (std::nothrow) GraphicEq(); }

}  // namespace

void registerFilterEqs(ModuleRegistry& registry) {
    registry.add(eq3Descriptor(), &makeEq3);
    registry.add(tiltDescriptor(), &makeTilt);
    registry.add(geqDescriptor(), &makeGeq);
}

}  // namespace caw::fx
