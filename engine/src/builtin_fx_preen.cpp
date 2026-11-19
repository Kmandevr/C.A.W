// Preen (org.caw.clean, 1.1.0): the clean-up device's De-hum and De-reverb variants, its variant table and its presets (Denoise is builtin_fx_preen_denoise.cpp).
#include <algorithm>
#include <cmath>
#include <new>
#include <span>
#include <vector>

#include "builtin_effects.h"
#include "component_chain.h"
#include "fx_clean.h"
#include "fx_clean_dsp.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0).
// De-hum: finds the hum by Goertzel filters (Goertzel, 1958) on the low-passed mono sum decimated to about 4 kHz,
//   over 1.5 s windows: the 50 or 60 Hz comb (harmonics 1-8) with more power, then the fundamental refined each
//   window from every harmonic's peak (a parabola through the log power 0.25 Hz either side), to within about
//   0.1 Hz. It removes it with a cascade of TPT state-variable notches (Zavalishin, "The Art of VA Filter
//   Design", 2012) at harmonics 1..N: no latency.
// De-reverb: single-channel late-reverberation suppression (Lebart, Boucher and Denbigh, Acta Acustica 87, 2001):
//   the late reverb's power is the smoothed power T_l earlier, scaled by exp(-2 delta T_l), delta = 3 ln 10 / T60;
//   it is taken out by a floored power-subtraction gain on the shared STFT. T60 is set, or estimated blind from the
//   frame energy's free decays (a least-squares slope over 250 ms that fell steadily by at least 15 dB). WPE is
//   not used (NTT's linear-prediction dereverberation patents, e.g. US8271277B2).

namespace caw::fx {

const ModuleDescriptor& preenDenoiseBaseDescriptor();  // builtin_fx_preen_denoise.cpp
ModuleProcessor* makePreenDenoiseAs(const ModuleDescriptor& variant) noexcept;

namespace {

using clean::Bins;
using clean::clampd;

ParameterDescriptor& byHand(ParameterDescriptor& p) {
    p.automatable = p.modulatable = p.midiMappable = false;
    return p;
}
constexpr std::string_view kTiers[] = {"Eco", "Normal", "High"};

// ---- De-hum ---------------------------------------------------------------------------------------------------

enum HumParam : uint32_t { kHFreq, kHCustom, kHHarmonics, kHWidth, kHDepth, kHBalance, kHFollow, kHListen, kHCount };
constexpr std::string_view kHumFreqs[] = {"Auto", "50 Hz", "60 Hz", "Custom"};
constexpr int kMaxNotches = 16, kDetectHarmonics = 8;

const ParamTable& humParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("frequency", "Frequency", 0.0, kHumFreqs);
        p.expo("custom", "Custom frequency", 50.0, 20.0, 400.0, "Hz");
        ParameterDescriptor& h = p.num("harmonics", "Harmonics", 8.0, 1.0, 16.0);
        h.step = 1.0;
        h.smoothingFrames = 0;
        p.expo("width", "Width", 2.0, 0.5, 20.0, "Hz");
        p.num("depth", "Depth", 1.0, 0.0, 1.0);
        p.num("balance", "Odd/even", 0.0, -1.0, 1.0);
        p.pick("follow", "Follow drift", 1.0, kOffOn);
        p.pick("listen", "Listen to removed", 0.0, kOffOn);
        return p;
    }();
    return t;
}
const ModuleDescriptor& humBase() {
    static const ModuleDescriptor d =
        withDomains(withCpu(effectDescriptor("org.caw.clean", "Preen", humParams(), 0, 0), CpuClass::Light), kDomainWhole);
    return d;
}

struct Goertzel {
    double coef = 0, s1 = 0, s2 = 0;
    void set(double hz, double rate) noexcept { coef = 2.0 * detCos(2.0 * kPi * hz / rate), s1 = s2 = 0; }
    void push(double x) noexcept {
        const double s = x + coef * s1 - s2;
        s2 = s1, s1 = s;
    }
    double power() const noexcept { return std::max(0.0, s1 * s1 + s2 * s2 - coef * s1 * s2); }
};

class DeHum final : public EffectBase {
public:
    explicit DeHum(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        dec_ = std::max(1u, static_cast<uint32_t>(sr / 4000.0 + 0.5));
        fd_ = sr / dec_;
        window_ = static_cast<uint32_t>(1.5 * fd_ + 0.5);
        lp_[0].set(false, 900.0, 0.5412, sr);
        lp_[1].set(false, 900.0, 1.3066, sr);
        return true;
    }
    void clearState() noexcept override {
        for (auto& f : lp_) f.clear();
        for (int h = 0; h < kMaxNotches; ++h) ic1_[h][0] = ic1_[h][1] = ic2_[h][0] = ic2_[h][1] = 0.0;
        decAt_ = 0;
        decSum_ = 0.0;
        at_ = 0;
        family_ = 0;  // found again after a sleep
        switchVotes_ = 0;
        windows_ = 0;
        mode_ = -1;
        startWindow();
        for (auto& r : depth_) r.reset();
    }
    void control(uint32_t at) noexcept override {
        const int mode = std::clamp(choice(kHFreq, at), 0, 3);
        const double custom = clampd(param(kHCustom, at), 20.0, 400.0);
        if (mode != mode_ || (mode == 3 && custom != custom_)) {  // a new base: detection starts over from it
            mode_ = mode;
            custom_ = custom;
            family_ = mode == 0 ? 0 : mode;  // 1: 50, 2: 60, 3: custom
            base_ = baseOf(family_);
            f0_ = base_;
            windows_ = 0;
            startWindow();
            coefFor_ = -1;
        }
        follow_ = on(kHFollow, at);
        listen_ = on(kHListen, at);
        harmonics_ = std::clamp(static_cast<int>(param(kHHarmonics, at) + 0.5), 1, kMaxNotches);
        const double width = clampd(param(kHWidth, at), 0.5, 20.0);
        if (f0_ != coefFor_ || width != widthFor_ || harmonics_ != notchesFor_) setNotches(width);
        const double depth = clampd(param(kHDepth, at), 0.0, 1.0), bal = clampd(param(kHBalance, at), -1.0, 1.0);
        for (int h = 0; h < kMaxNotches; ++h) {
            const bool odd = (h + 1) % 2 == 1;
            const double side = odd ? std::min(1.0, 1.0 - bal) : std::min(1.0, 1.0 + bal);
            const bool live = family_ != 0 && h < harmonics_ && (h + 1) * f0_ < 0.45 * rate();
            depth_[h].set(live ? depth * side : 0.0, kControlFrames);
        }
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = finiteOr0(inL[i]), xr = finiteOr0(inR[i]);
            detect(0.5 * (xl + xr));
            double yl = xl, yr = xr;
            for (int h = 0; h < active_; ++h) {
                const double d = depth_[h].next() * k_[h];
                double y[2] = {yl, yr};
                for (int c = 0; c < 2; ++c) {
                    const double v3 = y[c] - ic2_[h][c];
                    const double v1 = a1_[h] * ic1_[h][c] + a2_[h] * v3;
                    const double v2 = ic2_[h][c] + a2_[h] * ic1_[h][c] + a3_[h] * v3;
                    ic1_[h][c] = 2.0 * v1 - ic1_[h][c];
                    ic2_[h][c] = 2.0 * v2 - ic2_[h][c];
                    y[c] -= d * v1;  // the notch: the input less its band part
                }
                yl = y[0], yr = y[1];
            }
            for (int h = active_; h < kMaxNotches; ++h) depth_[h].next();
            outL[i] = static_cast<float>(listen_ ? xl - yl : yl);
            outR[i] = static_cast<float>(listen_ ? xr - yr : yr);
        }
        for (int h = 0; h < active_; ++h)
            for (int c = 0; c < 2; ++c) {
                if (std::fabs(ic1_[h][c]) < 1e-25 || !std::isfinite(ic1_[h][c])) ic1_[h][c] = 0.0;
                if (std::fabs(ic2_[h][c]) < 1e-25 || !std::isfinite(ic2_[h][c])) ic2_[h][c] = 0.0;
            }
        for (auto& f : lp_) f.flush();
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = family_ ? static_cast<float>(f0_) : 0.0f;
        out[3] = static_cast<float>(family_);
        out[4] = family_ && (!follow_ && windows_ >= kLockWindows) ? 1.0f : 0.0f;
        out[5] = static_cast<float>(harmonics_);
        for (int h = 0; h < kDetectHarmonics; ++h) out[6 + h] = level_[h];
        return 6 + kDetectHarmonics;
    }

private:
    static constexpr int kLockWindows = 4;  // Follow drift off: refined for 4 windows (6 s), then held
    static constexpr double kStep = 0.25;   // Hz either side of each harmonic

    double baseOf(int family) const noexcept { return family == 1 ? 50.0 : (family == 2 ? 60.0 : (family == 3 ? custom_ : 50.0)); }

    void startWindow() noexcept {
        for (int h = 0; h < kDetectHarmonics; ++h) {
            fam_[0][h].set(50.0 * (h + 1), fd_);
            fam_[1][h].set(60.0 * (h + 1), fd_);
            for (int s = 0; s < 3; ++s) ref_[h][s].set((h + 1) * f0_ + (s - 1) * kStep, fd_);
        }
        at_ = 0;
    }
    void detect(double x) noexcept {
        const double y = lp_[1].run(lp_[0].run(x));
        decSum_ += y;
        if (++decAt_ < dec_) return;
        const double v = decSum_ / dec_;
        decAt_ = 0;
        decSum_ = 0.0;
        if (!follow_ && family_ && windows_ >= kLockWindows) return;  // held: no detection cost
        const int hs = harmonicsBelow(f0_);
        for (int h = 0; h < kDetectHarmonics; ++h) fam_[0][h].push(v), fam_[1][h].push(v);
        for (int h = 0; h < hs; ++h)
            for (int s = 0; s < 3; ++s) ref_[h][s].push(v);
        if (++at_ >= window_) endWindow(hs);
    }
    int harmonicsBelow(double f) const noexcept {
        int h = 0;
        while (h < kDetectHarmonics && (h + 1) * (f + 1.0) < 0.45 * fd_) ++h;
        return h;
    }
    void endWindow(int hs) noexcept {
        double p50 = 0, p60 = 0;
        for (int h = 0; h < kDetectHarmonics; ++h) {
            if (50.0 * (h + 1) < 0.45 * fd_) p50 += fam_[0][h].power();
            if (60.0 * (h + 1) < 0.45 * fd_) p60 += fam_[1][h].power();
        }
        const double floorP = 1e-9 * window_ * window_;  // about -90 dBFS a harmonic: no hum to find
        if (mode_ == 0) {
            const int want = p60 > p50 ? 2 : 1;
            const double best = std::max(p50, p60);
            if (family_ == 0) {
                if (best > floorP) family_ = want, base_ = f0_ = baseOf(want), windows_ = 0;
            } else if (want != family_ && best > 2.0 * std::min(p50, p60) && best > floorP) {
                if (++switchVotes_ >= 2) family_ = want, base_ = f0_ = baseOf(want), windows_ = 0, switchVotes_ = 0;
            } else {
                switchVotes_ = 0;
            }
        }
        if (family_ && hs > 0) {
            double num = 0, den = 0;
            for (int h = 0; h < hs; ++h) {
                const double a = ref_[h][0].power(), b = ref_[h][1].power(), c = ref_[h][2].power();
                level_[h] = static_cast<float>(std::max(-120.0, 10.0 * std::log10(2.0 * std::max(b, 1e-30) / (0.25 * window_ * window_))));
                if (b < floorP) continue;
                double est;
                if (b >= a && b >= c && a > 0 && c > 0) {
                    const double la = detLog(a), lb = detLog(b), lc = detLog(c);
                    const double den2 = la - 2.0 * lb + lc;
                    est = den2 < 0 ? clampd(0.5 * (la - lc) / den2, -1.0, 1.0) * kStep : 0.0;
                } else {
                    est = a > c ? -kStep : kStep;
                }
                const double w = std::max(a, std::max(b, c));
                num += w * est / (h + 1);
                den += w;
            }
            if (den > 0) f0_ = clampd(f0_ + num / den, base_ - 2.0, base_ + 2.0);
            ++windows_;
        }
        startWindow();
    }
    void setNotches(double width) noexcept {
        coefFor_ = f0_;
        widthFor_ = width;
        notchesFor_ = harmonics_;
        active_ = 0;
        for (int h = 0; h < harmonics_; ++h) {  // only the harmonics asked for run
            const double f = (h + 1) * f0_;
            if (f >= 0.45 * rate()) break;
            const double g = detTan(kPi * f / rate()), k = width / f;
            a1_[h] = 1.0 / (1.0 + g * (g + k));
            a2_[h] = g * a1_[h];
            a3_[h] = g * a2_[h];
            k_[h] = k;  // k v1 is the input at the centre: the notch is x - k v1
            active_ = h + 1;
        }
    }

    const ModuleDescriptor& d_;
    clean::Biquad lp_[2];
    Goertzel fam_[2][kDetectHarmonics], ref_[kDetectHarmonics][3];
    float level_[kDetectHarmonics] = {-120, -120, -120, -120, -120, -120, -120, -120};
    uint32_t dec_ = 12, decAt_ = 0, window_ = 6000, at_ = 0;
    double fd_ = 4000, decSum_ = 0;
    int mode_ = -1, family_ = 0, switchVotes_ = 0, windows_ = 0, harmonics_ = 8, active_ = 0, notchesFor_ = -1;
    double custom_ = 50, base_ = 50, f0_ = 50, coefFor_ = -1, widthFor_ = -1;
    bool follow_ = true, listen_ = false;
    double a1_[kMaxNotches] = {}, a2_[kMaxNotches] = {}, a3_[kMaxNotches] = {}, k_[kMaxNotches] = {};
    double ic1_[kMaxNotches][2] = {}, ic2_[kMaxNotches][2] = {};
    Ramp depth_[kMaxNotches];
};

// ---- De-reverb ------------------------------------------------------------------------------------------------

enum RevParam : uint32_t {
    kRAmount, kRDecayMode, kRDecay, kREarly, kRFloor, kRSmoothing, kRLow, kRHigh, kRListen, kRQuality, kRMonitor, kRCount
};
constexpr std::string_view kDecayModes[] = {"Auto", "Set"};

const ParamTable& revParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("amount", "Amount", 0.6, 0.0, 1.0);
        p.pick("decay_mode", "Decay", 0.0, kDecayModes);
        p.expo("decay", "Decay time", 1.0, 0.1, 10.0, "s");
        p.num("early", "Early keep", 50.0, 20.0, 100.0, "ms");
        p.num("floor", "Floor", -18.0, -40.0, 0.0, "dB");
        p.num("smoothing", "Smoothing", 0.5, 0.0, 1.0);
        p.expo("low", "Low limit", 20.0, 20.0, 2000.0, "Hz");
        p.expo("high", "High limit", 20000.0, 1000.0, 20000.0, "Hz");
        p.pick("listen", "Listen to removed", 0.0, kOffOn);
        byHand(p.pick("quality", "Quality", 1.0, kTiers));
        byHand(p.pick("monitor", "Low-latency monitoring", 0.0, kOffOn));
        return p;
    }();
    return t;
}
const ModuleDescriptor& revBase() {
    static const ModuleDescriptor d = withDomains(
        withCpu(effectDescriptor("org.caw.clean", "Preen", revParams(), clean::tierWindow(1, false, 48000), 4096), CpuClass::Heavy),
        kDomainWhole);
    return d;
}

// The history De-reverb keeps: the smoothed power of the last 100 ms of frames at the tier needing the most.
size_t revHistoryFloats(double sr) {
    size_t most = 0;
    for (int t = -1; t <= 2; ++t) {
        const uint32_t n = clean::tierWindow(t < 0 ? 0 : t, t < 0, sr);
        const size_t frames = static_cast<size_t>(std::ceil(0.1 / (n / 4 / sr))) + 1;
        most = std::max(most, frames * (n / 2 + 1));
    }
    return most;
}

class DeReverb final : public EffectBase, public VariableLatency {
public:
    explicit DeReverb(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        const int q = count > kRQuality ? static_cast<int>(values[kRQuality] + 0.5) : 1;
        return clean::tierWindow(q, count > kRMonitor && values[kRMonitor] >= 0.5, rate());
    }
    uint64_t idleFrames() const noexcept override { return stft_.size() + static_cast<uint64_t>(0.05 * rate()); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        maxN_ = clean::maxWindow(sr);
        const uint32_t bins = maxN_ / 2 + 1;
        if (!stft_.prepare(maxN_)) return false;
        try {
            const size_t h = revHistoryFloats(sr);
            for (int c = 0; c < 2; ++c) {
                ps_[c].assign(bins, 0.0f);
                held_[c].assign(bins, 1.0f);
                hist_[c].assign(h, 0.0f);
            }
            tmp_.assign(bins, 0.0f);
            histFloats_ = h;
        } catch (...) {
            return false;
        }
        n_ = 0;
        return true;
    }
    void clearState() noexcept override {
        stft_.clear();
        for (int c = 0; c < 2; ++c) {
            std::fill(ps_[c].begin(), ps_[c].end(), 0.0f);
            std::fill(held_[c].begin(), held_[c].end(), 1.0f);
            std::fill(hist_[c].begin(), hist_[c].end(), 0.0f);
        }
        histAt_ = 0;
        eCount_ = 0;
        eAt_ = 0;
        estimate_ = 1.0;
        decays_ = 0;
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const uint32_t n = clean::tierWindow(choice(kRQuality, at), on(kRMonitor, at), sr);
        if (n != n_) {
            n_ = n;
            stft_.setSize(n);
            hop_ = (n / 4) / sr;
            histFrames_ = static_cast<uint32_t>(std::min<size_t>(histFloats_ / (n / 2 + 1), std::ceil(0.1 / hop_) + 1));
            smoothFor_ = -1;
            for (int c = 0; c < 2; ++c) {
                std::fill(ps_[c].begin(), ps_[c].end(), 0.0f);
                std::fill(held_[c].begin(), held_[c].end(), 1.0f);
                std::fill(hist_[c].begin(), hist_[c].end(), 0.0f);
            }
            histAt_ = 0;
            eCount_ = eAt_ = 0;
            alpha_ = detExp(-hop_ / 0.1);
            decayFrames_ = std::min<uint32_t>(kEFrames, std::max<uint32_t>(4, static_cast<uint32_t>(0.25 / hop_ + 0.5)));
        }
        amount_ = clampd(param(kRAmount, at), 0.0, 1.0);
        auto_ = choice(kRDecayMode, at) == 0;
        set_ = clampd(param(kRDecay, at), 0.1, 10.0);
        delay_ = std::clamp<uint32_t>(static_cast<uint32_t>(param(kREarly, at) * 0.001 / hop_ + 0.5), 1, histFrames_ - 1);
        floor_ = lib::dbToGain(clampd(param(kRFloor, at), -40.0, 0.0));
        const double s = clampd(param(kRSmoothing, at), 0.0, 1.0);
        smoothing_ = s;
        if (s != smoothFor_) {
            smoothFor_ = s;
            fall_ = s > 0 ? detExp(-hop_ / (0.06 * s)) : 0.0;
            rise_ = s > 0 ? detExp(-hop_ / (0.015 * s)) : 0.0;
        }
        const double lo = param(kRLow, at), hi = param(kRHigh, at);  // at their ends (20 Hz, 20 kHz): off
        lowBin_ = lo <= 20.0 ? 0 : static_cast<uint32_t>(std::max(0.0, std::ceil(lo * n_ / rate())));
        highBin_ = hi >= 20000.0 ? n_ / 2 : static_cast<uint32_t>(std::min<double>(n_ / 2, std::floor(hi * n_ / rate())));
        listen_ = on(kRListen, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        stft_.process(inL, inR, outL, outR, n, [this](Bins& b) { frame(b); });
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(t60());
        out[3] = static_cast<float>(estimate_);
        out[4] = static_cast<float>(decays_);
        out[5] = static_cast<float>(1000.0 * n_ / rate());
        out[6] = static_cast<float>(n_);
        out[7] = static_cast<float>(meanGainDb_);
        out[8] = 32.0f;
        for (uint32_t j = 0; j < 32; ++j) {
            float g = 0.0f;
            if (watched && n_) {
                const double hz = 20.0 * std::pow(1000.0, j / 31.0);
                const uint32_t k = std::min<uint32_t>(n_ / 2, static_cast<uint32_t>(hz * n_ / rate() + 0.5));
                g = static_cast<float>(lib::gainToDb(0.5 * (held_[0][k] + held_[1][k]), -120.0));
            }
            out[9 + j] = g;
        }
        return 41;
    }

private:
    static constexpr uint32_t kEFrames = 128;
    double t60() const noexcept { return auto_ ? estimate_ : set_; }

    void frame(Bins& b) noexcept {
        const uint32_t bins = b.count;
        double e = 0.0;
        for (uint32_t k = 0; k < bins; ++k) e += b.lr[k] * b.lr[k] + b.li[k] * b.li[k] + b.rr[k] * b.rr[k] + b.ri[k] * b.ri[k];
        trackDecay(e);
        const double late = detExp(-6.0 * 2.302585092994046 * delay_ * hop_ / t60());  // exp(-2 delta T_l)
        const uint32_t past = (histAt_ + histFrames_ - delay_) % histFrames_;
        double sum = 0.0;
        for (int c = 0; c < 2; ++c) {
            float* ps = ps_[c].data();
            float* hist = hist_[c].data();
            for (uint32_t k = 0; k < bins; ++k) {
                const double p = c == 0 ? b.lr[k] * b.lr[k] + b.li[k] * b.li[k] : b.rr[k] * b.rr[k] + b.ri[k] * b.ri[k];
                const double s = p + (ps[k] - p) * alpha_;
                ps[k] = static_cast<float>(s);
                const double lateP = late * hist[past * bins + k];
                hist[histAt_ * bins + k] = ps[k];
                double g = 1.0;
                if (s > 1e-30 && k >= lowBin_ && k <= highBin_) g = std::sqrt(std::max(0.0, 1.0 - amount_ * lateP / s));
                tmp_[k] = static_cast<float>(g);
            }
            const double sf = 0.5 * smoothing_;
            float* held = held_[c].data();
            for (uint32_t k = 0; k < bins; ++k) {
                const double a = tmp_[k > 0 ? k - 1 : 0], m = tmp_[k], z = tmp_[k + 1 < bins ? k + 1 : k];
                double g = std::max(m + sf * ((a + 2.0 * m + z) * 0.25 - m), floor_);
                if (k < lowBin_ || k > highBin_) g = 1.0;
                const double c2 = g < held[k] ? fall_ : rise_;
                g = g + (held[k] - g) * c2;
                held[k] = static_cast<float>(g);
                sum += g * g;
                const double use = listen_ ? 1.0 - g : g;
                if (c == 0) b.lr[k] *= use, b.li[k] *= use;
                else b.rr[k] *= use, b.ri[k] *= use;
            }
        }
        histAt_ = (histAt_ + 1) % histFrames_;
        meanGainDb_ = 10.0 * std::log10(sum / (2.0 * bins) + 1e-12);
    }
    // Blind T60: the frame energy (dB) over the last 250 ms; when it fell steadily (each frame at most 1 dB above
    // the one before) by 15 dB or more from above -70 dBFS, its least-squares slope gives a decay time, and the
    // estimate moves a quarter of the way to it (held within 0.1-10 s).
    void trackDecay(double e) noexcept {
        const double ref = (n_ / kPi) * (n_ / kPi);
        const double db = 4.342944819032518 * detLog(e / ref + 1e-30);
        energy_[eAt_] = static_cast<float>(db);
        eAt_ = (eAt_ + 1) % kEFrames;
        if (eCount_ < decayFrames_) {
            ++eCount_;
            return;
        }
        const uint32_t m = decayFrames_;
        const uint32_t first = (eAt_ + kEFrames - m) % kEFrames;
        const double start = energy_[first], end = energy_[(eAt_ + kEFrames - 1) % kEFrames];
        if (start < -70.0 || start - end < 15.0) return;
        double prev = start, sx = 0, sy = 0, sxx = 0, sxy = 0;
        for (uint32_t j = 0; j < m; ++j) {
            const double y = energy_[(first + j) % kEFrames];
            if (y > prev + 1.0) return;
            prev = y;
            sx += j, sy += y, sxx += double(j) * j, sxy += j * y;
        }
        const double slope = (m * sxy - sx * sy) / (m * sxx - sx * sx) / hop_;  // dB a second
        if (!(slope < 0)) return;
        estimate_ = clampd(estimate_ + 0.25 * (-60.0 / slope - estimate_), 0.1, 10.0);
        ++decays_;
        eCount_ = 0;  // the next one starts afresh
    }

    const ModuleDescriptor& d_;
    clean::Stft stft_;
    std::vector<float> ps_[2], held_[2], hist_[2], tmp_;
    float energy_[kEFrames] = {};
    size_t histFloats_ = 0;
    uint32_t maxN_ = 4096, n_ = 0, histFrames_ = 2, histAt_ = 0, delay_ = 1, lowBin_ = 0, highBin_ = 0;
    uint32_t eAt_ = 0, eCount_ = 0, decayFrames_ = 24, decays_ = 0;
    double hop_ = 0.01, alpha_ = 0.5, amount_ = 0.6, set_ = 1.0, estimate_ = 1.0, floor_ = 0.125, smoothing_ = 0.5;
    double smoothFor_ = -1, fall_ = 0, rise_ = 0, meanGainDb_ = 0;
    bool auto_ = true, listen_ = false;
};

// ---- The device -----------------------------------------------------------------------------------------------

constexpr std::string_view kId = "org.caw.clean";
constexpr std::string_view kName = "Preen";
constexpr std::string_view kVariants[] = {"Denoise", "De-hum", "De-reverb"};

template <uint32_t Index, const ModuleDescriptor& (*Base)(), ModuleProcessor* (*MakeAs)(const ModuleDescriptor&) noexcept>
struct V {
    static const ModuleDescriptor& descriptor() {
        static const ModuleDescriptor& d = legacyVariantDescriptor(Base(), kId, kName, kVariants, Index);
        return d;
    }
    static ModuleProcessor* create() noexcept { return MakeAs(descriptor()); }
    static constexpr Variant variant() { return {kVariants[Index], &descriptor, &create}; }
};
ModuleProcessor* makeHum(const ModuleDescriptor& d) noexcept { return new (std::nothrow) DeHum(d); }
ModuleProcessor* makeRev(const ModuleDescriptor& d) noexcept { return new (std::nothrow) DeReverb(d); }

const Variant kPreen[] = {V<0, &preenDenoiseBaseDescriptor, &makePreenDenoiseAs>::variant(),
                          V<1, &humBase, &makeHum>::variant(), V<2, &revBase, &makeRev>::variant()};
const MergedDevice kDevices[] = {{kId, kName, kPreen}};

const std::vector<BuiltinPreset>& preenPresetList() {
    static const std::vector<BuiltinPreset> p = {
        // Denoise (0)
        {"Gentle hiss", "Mixing: a light, adaptive lift of steady hiss", {{"reduction", 8}, {"smoothing", 0.6}, {"variant", 0}}},
        {"Voice clean-up", "Vocals: room noise and hiss under speech or singing", {{"reduction", 14}, {"low", 80}, {"transient", 0.4}, {"variant", 0}}},
        {"Learned noise", "Mixing: play the noise alone with Learn on, then off: the profile does the rest", {{"reduction", 18}, {"adaptive", 0}, {"variant", 0}}},
        {"Guitar amp hiss", "Guitar: an amp's hiss and buzz between notes, picks kept", {{"reduction", 15}, {"transient", 0.6}, {"high", 16000}, {"variant", 0}}},
        {"Tape restore", "Lo-fi: tape hiss on an old recording, smooth and high quality", {{"reduction", 12}, {"smoothing", 0.8}, {"quality", 2}, {"variant", 0}}},
        {"Drum overheads", "Drums: noise between hits, the attacks kept", {{"reduction", 10}, {"transient", 0.9}, {"variant", 0}}},
        {"Heavy rescue", "Mixing: strong reduction for a noisy take (some artefacts)", {{"reduction", 30}, {"sensitivity", 3}, {"smoothing", 0.9}, {"variant", 0}}},
        {"Live monitoring", "Vocals: the short window while a track is armed (11 ms)", {{"reduction", 10}, {"monitor", 1}, {"variant", 0}}},
        {"Hear the noise", "Mixing: listen to what is taken out", {{"reduction", 14}, {"listen", 1}, {"variant", 0}}},
        // De-hum (1)
        {"Mains hum (auto)", "Mixing: finds 50 or 60 Hz hum and its harmonics", {{"variant", 1}}},
        {"50 Hz hum", "Mixing: Europe, Asia, Africa: 50 Hz and 8 harmonics", {{"frequency", 1}, {"variant", 1}}},
        {"60 Hz hum", "Mixing: the Americas: 60 Hz and 8 harmonics", {{"frequency", 2}, {"variant", 1}}},
        {"Guitar ground buzz", "Guitar: a buzzy hum with many harmonics", {{"harmonics", 16}, {"width", 3}, {"variant", 1}}},
        {"Bass-safe hum", "Bass: narrow notches that leave low notes alone", {{"width", 0.8}, {"harmonics", 6}, {"variant", 1}}},
        {"Odd harmonics only", "Mixing: hum from a transformer (odd harmonics)", {{"balance", -1}, {"variant", 1}}},
        {"Wide and gentle", "Mixing: a softer cut for a drifting hum", {{"width", 6}, {"depth", 0.7}, {"variant", 1}}},
        {"Fixed 50 Hz, held", "Mixing: a steady 50 Hz hum found once and held (no drift following)", {{"frequency", 1}, {"follow", 0}, {"variant", 1}}},
        // De-reverb (2)
        {"Room tame", "Vocals: a little less room on a dry-ish take", {{"amount", 0.4}, {"variant", 2}}},
        {"Dry the voice", "Vocals: a lot less room on speech or singing", {{"amount", 0.8}, {"floor", -24}, {"early", 40}, {"variant", 2}}},
        {"Big hall", "Mixing: a long reverb taken down", {{"amount", 0.7}, {"decay_mode", 1}, {"decay", 3}, {"variant", 2}}},
        {"Small room", "Mixing: a short, boxy room", {{"amount", 0.6}, {"decay_mode", 1}, {"decay", 0.5}, {"early", 30}, {"variant", 2}}},
        {"Drum room", "Drums: less room on a kit, the hits kept", {{"amount", 0.5}, {"early", 70}, {"smoothing", 0.3}, {"variant", 2}}},
        {"Guitar cab room", "Guitar: less room on a miked amp", {{"amount", 0.5}, {"low", 80}, {"variant", 2}}},
        {"Gentle and smooth", "Mixing: subtle and smooth, high quality", {{"amount", 0.35}, {"smoothing", 0.8}, {"quality", 2}, {"variant", 2}}},
        {"Hear the room", "Mixing: listen to what is taken out", {{"amount", 0.7}, {"listen", 1}, {"variant", 2}}},
    };
    return p;
}

}  // namespace

std::span<const MergedDevice> mergedPreenDevices() { return kDevices; }
const std::vector<BuiltinPreset>& preenPresets() { return preenPresetList(); }

size_t preenBytes(uint32_t variant, double sr) noexcept {
    const size_t n = clean::maxWindow(sr), bins = n / 2 + 1;
    const size_t stft = 4 * n * 4 + 2 * n * 8 + 4 * bins * 8;
    if (variant == 0) return sizeof(void*) * 64 + stft + 2 * bins * (4 * 4 + 8) + 2 * bins * 4 * (5 + 4) + bins * 4;
    if (variant == 1) return 0;  // nothing beyond its object
    return stft + 2 * bins * 8 + 2 * revHistoryFloats(sr) * 4 + bins * 4;
}

}  // namespace caw::fx
