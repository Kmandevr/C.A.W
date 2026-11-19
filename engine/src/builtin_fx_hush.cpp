// Hush (org.caw.vocalclean, 1.1.0): vocal clean-up on one event detector: De-click (LPC residual, AR interpolation), De-plosive (low-band bursts) and Breath (unvoiced, flat, quiet segments), each with a small look-ahead reported as latency.
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

// Original code (C.A.W. is Apache-2.0) from published methods:
// - the event detector: per 2.7 ms hop (128 frames at 48 kHz) the mono sum's band energies (below 150 Hz, 150 Hz to
//   5 kHz, above 5 kHz: biquads), zero-crossing rate, spectral flatness (a Hann-windowed 256-point FFT, 300 Hz to
//   10 kHz) and, only when the others ask for it, voicing (the normalised autocorrelation's peak over 80-400 Hz on
//   the signal decimated to about 12 kHz). Each variant switches on only the features it reads;
// - De-click: an order-16 LPC (autocorrelation and Levinson-Durbin) per channel, refitted every 5.3 ms on the
//   repaired signal; a click is a residual above k times the residual's running RMS; the gap (up to Max length) is
//   rebuilt by least-squares autoregressive interpolation (Janssen, Veldhuis and Vries, IEEE TASSP 34(2), 1986; one
//   pass with the fitted model, its Toeplitz normal equations solved by Levinson's recursion), 5 ms late;
// - De-plosive: a low-band burst rising far over its recent level while the mid band does not rise with it cuts the
//   band below Frequency for that event only (at most Length), 3 ms ahead of the audio;
// - Breath: an unvoiced, flat, quieter-than-the-phrase segment is lowered by Range with Fade-long ramps, the audio
//   20 ms late so the ramp starts at the breath's start; one longer than 600 ms is not a breath.

namespace caw::fx {

namespace {

using clean::clampd;

// ---- The shared event detector --------------------------------------------------------------------------------

class HushDetector {
public:
    enum : unsigned { kBands = 1, kSpectrum = 2, kVoicing = 4 };

    bool prepare(double rate, unsigned flags) {
        flags_ = flags;
        rate_ = rate;
        const double scale = rate > 140000 ? 4 : (rate > 70000 ? 2 : (rate < 32000 ? 0.5 : 1));
        hop_ = static_cast<uint32_t>(128 * scale);
        fftN_ = static_cast<uint32_t>(256 * scale);
        lp150_.set(false, 150, 0.7071, rate);
        hp150_.set(true, 150, 0.7071, rate);
        lp5k_.set(false, 5000, 0.7071, rate);
        hp5k_.set(true, 5000, 0.7071, rate);
        q_ = std::max(1u, static_cast<uint32_t>(rate / 12000.0 + 0.5));
        fdv_ = rate / q_;
        try {
            if (flags & kSpectrum) {
                tables_ = clean::sharedTables(fftN_);
                ring_.assign(fftN_, 0.0f);
                re_.assign(fftN_, 0.0);
                im_.assign(fftN_, 0.0);
            }
            if (flags & kVoicing) dec_.assign(kDec, 0.0f);
        } catch (...) {
            return false;
        }
        clear();
        return true;
    }
    void clear() noexcept {
        for (auto* f : {&lp150_, &hp150_, &lp5k_, &hp5k_}) f->clear();
        std::fill(ring_.begin(), ring_.end(), 0.0f);
        std::fill(dec_.begin(), dec_.end(), 0.0f);
        at_ = ringAt_ = decAt_ = decN_ = 0;
        aLow_ = aMid_ = aHigh_ = aAll_ = decSum_ = 0.0;
        crossings_ = 0;
        lastSign_ = false;
        low = mid = high = level = zcr = 0.0;
        flatness = 0.0;
    }
    uint32_t hop() const noexcept { return hop_; }
    double hopSeconds() const noexcept { return hop_ / rate_; }

    // One mono sample; true when it completed a hop (the features below are then this hop's).
    bool push(double x) noexcept {
        aAll_ += x * x;
        const bool sign = x >= 0.0;
        crossings_ += sign != lastSign_;
        lastSign_ = sign;
        if (flags_ & kBands) {
            const double l = lp150_.run(x);
            const double m = lp5k_.run(hp150_.run(x));
            const double h = hp5k_.run(x);
            aLow_ += l * l, aMid_ += m * m, aHigh_ += h * h;
        }
        if (flags_ & kSpectrum) {
            ring_[ringAt_] = static_cast<float>(x);
            ringAt_ = ringAt_ + 1 == fftN_ ? 0 : ringAt_ + 1;
        }
        if (flags_ & kVoicing) {
            decSum_ += x;
            if (++decN_ == q_) {
                dec_[decAt_] = static_cast<float>(decSum_ / q_);
                decAt_ = (decAt_ + 1) & (kDec - 1);
                decSum_ = 0.0;
                decN_ = 0;
            }
        }
        if (++at_ < hop_) return false;
        const double inv = 1.0 / hop_;
        level = aAll_ * inv, low = aLow_ * inv, mid = aMid_ * inv, high = aHigh_ * inv;
        zcr = crossings_ * rate_ * inv;  // crossings a second
        aAll_ = aLow_ = aMid_ = aHigh_ = 0.0;
        crossings_ = 0;
        at_ = 0;
        for (auto* f : {&lp150_, &hp150_, &lp5k_, &hp5k_}) f->flush();
        if (flags_ & kSpectrum) flatness = flat();
        return true;
    }
    // The normalised autocorrelation's peak over 80-400 Hz of the last 21 ms (0..1): 1 is periodic (voiced).
    double voicing() const noexcept {
        if (!(flags_ & kVoicing)) return 0.0;
        const uint32_t w = static_cast<uint32_t>(0.021 * fdv_);
        const uint32_t lo = static_cast<uint32_t>(fdv_ / 400.0), hi = std::min<uint32_t>(kDec - w - 1, static_cast<uint32_t>(fdv_ / 80.0));
        const uint32_t start = (decAt_ + kDec - w - hi) & (kDec - 1);  // the oldest sample used
        double best = 0.0;
        for (uint32_t lag = lo; lag <= hi; ++lag) {
            double xy = 0, xx = 0, yy = 0;
            for (uint32_t i = 0; i < w; ++i) {
                const double a = dec_[(start + i) & (kDec - 1)], b = dec_[(start + i + lag) & (kDec - 1)];
                xy += a * b, xx += a * a, yy += b * b;
            }
            if (xx > 1e-20 && yy > 1e-20) best = std::max(best, xy / std::sqrt(xx * yy));
        }
        return best;
    }

    double low = 0, mid = 0, high = 0, level = 0, zcr = 0, flatness = 0;

private:
    static constexpr uint32_t kDec = 512;
    double flat() noexcept {
        const double* w = tables_->window.data();
        for (uint32_t j = 0; j < fftN_; ++j) {
            re_[j] = ring_[(ringAt_ + j) % fftN_] * w[j] * w[j];  // Hann (the sqrt-Hann squared)
            im_[j] = 0.0;
        }
        tables_->fft.forward(re_.data(), im_.data());
        const uint32_t k0 = std::max(1u, static_cast<uint32_t>(300.0 * fftN_ / rate_));
        const uint32_t k1 = std::min(fftN_ / 2, static_cast<uint32_t>(std::min(10000.0, 0.45 * rate_) * fftN_ / rate_));
        double logs = 0, sum = 0;
        for (uint32_t k = k0; k <= k1; ++k) {
            const double p = re_[k] * re_[k] + im_[k] * im_[k] + 1e-20;
            logs += detLog(p);
            sum += p;
        }
        const double m = k1 - k0 + 1.0;
        return detExp(logs / m) / (sum / m);
    }

    unsigned flags_ = 0;
    double rate_ = 48000, fdv_ = 12000, aLow_ = 0, aMid_ = 0, aHigh_ = 0, aAll_ = 0, decSum_ = 0;
    uint32_t hop_ = 128, fftN_ = 256, q_ = 4, at_ = 0, ringAt_ = 0, decAt_ = 0, decN_ = 0, crossings_ = 0;
    bool lastSign_ = false;
    clean::Biquad lp150_, hp150_, lp5k_, hp5k_;
    clean::SharedTables* tables_ = nullptr;
    std::vector<float> ring_, dec_;
    std::vector<double> re_, im_;
};

// A delay line of whole frames for the look-ahead (both sides).
struct Look {
    std::vector<float> l, r;
    uint32_t size = 1, at = 0, delay = 0;
    bool prepare(uint32_t frames) {
        uint32_t s = 1;
        while (s < frames + 1) s <<= 1;
        try {
            l.assign(s, 0.0f);
            r.assign(s, 0.0f);
        } catch (...) {
            return false;
        }
        size = s, delay = frames;
        return true;
    }
    void clear() noexcept {
        std::fill(l.begin(), l.end(), 0.0f);
        std::fill(r.begin(), r.end(), 0.0f);
        at = 0;
    }
    // Writes this frame, returns the one `delay` frames ago.
    void step(float xl, float xr, float& yl, float& yr) noexcept {
        l[at] = xl, r[at] = xr;
        const uint32_t from = (at + size - delay) & (size - 1);
        yl = l[from], yr = r[from];
        at = (at + 1) & (size - 1);
    }
};

// ---- De-click -------------------------------------------------------------------------------------------------

enum ClickParam : uint32_t { kCSens, kCLength, kCMode, kCListen, kCCount };
constexpr std::string_view kClickModes[] = {"Click", "Crackle"};
constexpr int kOrder = 16;

const ParamTable& clickParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("sensitivity", "Sensitivity", 0.5, 0.0, 1.0);
        p.num("length", "Max length", 1.0, 0.1, 2.0, "ms");
        p.pick("mode", "Mode", 0.0, kClickModes);
        p.pick("listen", "Listen to removed", 0.0, kOffOn);
        return p;
    }();
    return t;
}
constexpr double kClickLook = 0.005, kPlosiveLook = 0.003, kBreathLook = 0.020;
uint32_t lookFrames(double seconds, double rate) noexcept { return static_cast<uint32_t>(seconds * rate + 0.5); }

class DeClick final : public EffectBase, public VariableLatency {
public:
    explicit DeClick(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double*, uint32_t) const noexcept override { return lookFrames(kClickLook, rate()); }
    uint64_t idleFrames() const noexcept override { return delay_ + static_cast<uint64_t>(0.05 * rate()); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        delay_ = lookFrames(kClickLook, sr);
        maxGap_ = static_cast<uint32_t>(0.002 * sr + 0.5);
        lpcWin_ = sr > 70000 ? 1024 : 512;
        lpcHop_ = lpcWin_ / 2;
        uint32_t s = 1;
        while (s < delay_ + lpcWin_ + maxGap_ + 4 * kOrder + 64) s <<= 1;
        size_ = s;
        try {
            for (int c = 0; c < 2; ++c) ring_[c].assign(s, 0.0f), removed_[c].assign(s, 0.0f);
            win_.assign(lpcWin_, 0.0);
            for (uint32_t i = 0; i < lpcWin_; ++i) win_[i] = 0.5 - 0.5 * detCos(2.0 * kPi * i / lpcWin_);
            const uint32_t m = maxGap_ + 2;
            r_.assign(m, 0.0), b_.assign(m, 0.0), x_.assign(m, 0.0), y_.assign(m, 0.0), t_.assign(m, 0.0);
        } catch (...) {
            return false;
        }
        rmsCoef_ = detExp(-1.0 / (0.01 * sr));
        return true;
    }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) {
            std::fill(ring_[c].begin(), ring_[c].end(), 0.0f);
            std::fill(removed_[c].begin(), removed_[c].end(), 0.0f);
            for (double& a : a_[c]) a = 0.0;
            sigma2_[c] = 0.0;
        }
        t_now_ = 0;
        fitted_ = false;
        warm_ = static_cast<uint32_t>(0.02 * rate());
        inGap_ = pending_ = false;
        sinceFit_ = 0;
    }
    void control(uint32_t at) noexcept override {
        const double s = clampd(param(kCSens, at), 0.0, 1.0);
        crackle_ = choice(kCMode, at) == 1;
        k_ = (10.0 - 6.0 * s) * (crackle_ ? 0.7 : 1.0);
        double len = clampd(param(kCLength, at), 0.1, 2.0);
        if (crackle_) len = std::min(len, 0.5);
        maxLen_ = std::clamp<uint32_t>(static_cast<uint32_t>(len * 0.001 * rate() + 0.5), 1, maxGap_);
        listen_ = on(kCListen, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const uint32_t mask = size_ - 1;
        for (uint32_t i = 0; i < n; ++i) {
            const uint32_t w = static_cast<uint32_t>(t_now_) & mask;
            const float x[2] = {static_cast<float>(finiteOr0(inL[i])), static_cast<float>(finiteOr0(inR[i]))};
            bool exceed = false;
            for (int c = 0; c < 2; ++c) {
                ring_[c][w] = x[c];
                if (!fitted_) continue;
                double e = x[c];
                for (int k = 1; k <= kOrder; ++k) e += a_[c][k] * ring_[c][(w - k) & mask];
                const double e2 = e * e, lim = k_ * k_ * std::max(sigma2_[c], 1e-12);
                const bool warming = warm_ > 0;  // the residual's RMS settles first (unclipped)
                if (e2 > lim && !warming) exceed = true;
                const double u = warming ? e2 : std::min(e2, lim);
                sigma2_[c] = u + (sigma2_[c] - u) * rmsCoef_;
            }
            if (warm_ > 0 && fitted_) --warm_;
            detect(exceed);
            const uint32_t rd = (w - delay_) & mask;
            outL[i] = listen_ ? removed_[0][rd] : ring_[0][rd];
            outR[i] = listen_ ? removed_[1][rd] : ring_[1][rd];
            removed_[0][rd] = removed_[1][rd] = 0.0f;
            ++t_now_;
            if (++sinceFit_ >= lpcHop_ && t_now_ >= lpcWin_ + maxGap_ + 2 * kOrder) {
                sinceFit_ = 0;
                fit();
            }
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(clicks_);
        out[3] = static_cast<float>(recent_);
        out[4] = static_cast<float>(lastLen_ * 1000.0 / rate());
        out[5] = static_cast<float>(k_);
        out[6] = static_cast<float>(1000.0 * delay_ / rate());
        recent_ = 0;
        return 7;
    }

private:
    void detect(bool exceed) noexcept {
        const uint64_t t = t_now_;
        if (pending_ && t >= repairAt_) {
            repair();
            pending_ = false;
        }
        if (inGap_) {
            if (exceed) last_ = t;
            if (t - last_ > 8 || t + 1 - gapStart_ >= maxLen_) {
                inGap_ = false;
                gapEnd_ = std::min<uint64_t>(last_, gapStart_ + maxLen_ - 1);
                pending_ = true;
                repairAt_ = gapEnd_ + kOrder + 1;
            }
        } else if (exceed && !pending_ && fitted_) {
            inGap_ = true;
            gapStart_ = t - 1;
            last_ = t;
        }
    }
    // Least-squares AR interpolation of [gapStart_, gapEnd_] from the order-16 model and the 16 samples either side.
    void repair() noexcept {
        const uint32_t mask = size_ - 1;
        const uint32_t m = static_cast<uint32_t>(gapEnd_ - gapStart_ + 1);
        for (int c = 0; c < 2; ++c) {
            double cf[kOrder + 1];
            cf[0] = 1.0;
            for (int k = 1; k <= kOrder; ++k) cf[k] = a_[c][k];
            double rc[kOrder + 1];
            for (int l = 0; l <= kOrder; ++l) {
                double s = 0;
                for (int k = 0; k + l <= kOrder; ++k) s += cf[k] * cf[k + l];
                rc[l] = s;
            }
            for (uint32_t l = 0; l < m; ++l) r_[l] = l <= static_cast<uint32_t>(kOrder) ? rc[l] : 0.0;
            for (uint32_t i = 0; i < m; ++i) {
                double s = 0;
                for (int d = 1; d <= kOrder; ++d) {
                    // the known neighbours d before and d after unknown sample i, outside the gap
                    if (static_cast<int64_t>(i) - d < 0) {
                        const uint64_t at = gapStart_ + i - d;
                        s += rc[d] * ring_[c][at & mask];
                    }
                    if (i + d >= m) {
                        const uint64_t at = gapStart_ + i + d;
                        s += rc[d] * ring_[c][at & mask];
                    }
                }
                b_[i] = -s;
            }
            if (!solve(m)) continue;
            for (uint32_t i = 0; i < m; ++i) {
                const uint32_t at = static_cast<uint32_t>(gapStart_ + i) & mask;
                const double v = clampd(x_[i], -4.0, 4.0);
                removed_[c][at] += static_cast<float>(ring_[c][at] - v);
                ring_[c][at] = static_cast<float>(v);
            }
        }
        ++clicks_, ++recent_;
        lastLen_ = m;
    }
    // Solves the symmetric Toeplitz system (first column r_, right side b_) into x_ (Levinson, Golub and Van Loan
    // 4.7.2); false when it is not positive definite.
    bool solve(uint32_t m) noexcept {
        const double t0 = r_[0];
        if (!(t0 > 0)) return false;
        for (uint32_t i = 0; i < m; ++i) r_[i] /= t0, b_[i] /= t0;
        x_[0] = b_[0];
        if (m == 1) return true;
        y_[0] = -r_[1];
        double beta = 1.0, alpha = -r_[1];
        for (uint32_t k = 1; k < m; ++k) {
            beta *= (1.0 - alpha * alpha);
            if (!(beta > 1e-12)) return false;
            double s = 0;
            for (uint32_t i = 1; i <= k; ++i) s += r_[i] * x_[k - i];
            const double mu = (b_[k] - s) / beta;
            for (uint32_t i = 0; i < k; ++i) t_[i] = x_[i] + mu * y_[k - 1 - i];
            for (uint32_t i = 0; i < k; ++i) x_[i] = t_[i];
            x_[k] = mu;
            if (k < m - 1) {
                double s2 = 0;
                for (uint32_t i = 1; i <= k; ++i) s2 += r_[i] * y_[k - i];
                alpha = -(r_[k + 1] + s2) / beta;
                for (uint32_t i = 0; i < k; ++i) t_[i] = y_[i] + alpha * y_[k - 1 - i];
                for (uint32_t i = 0; i < k; ++i) y_[i] = t_[i];
                y_[k] = alpha;
            }
        }
        for (uint32_t i = 0; i < m; ++i) if (!std::isfinite(x_[i])) return false;
        return true;
    }
    // The LPC of the last window that is already past any gap (so repaired), per channel.
    void fit() noexcept {
        const uint32_t mask = size_ - 1;
        const uint64_t end = t_now_ - (maxGap_ + 2 * kOrder + 8);
        for (int c = 0; c < 2; ++c) {
            double r[kOrder + 1] = {};
            for (int l = 0; l <= kOrder; ++l) {
                double s = 0;
                for (uint32_t i = l; i < lpcWin_; ++i) {
                    const uint64_t a = end - lpcWin_ + i, b = a - l;
                    s += ring_[c][a & mask] * win_[i] * ring_[c][b & mask] * win_[i - l];
                }
                r[l] = s;
            }
            r[0] = r[0] * 1.0001 + 1e-12;
            double a[kOrder + 1] = {1.0}, err = r[0];
            bool ok = true;
            for (int i = 1; i <= kOrder && ok; ++i) {
                double acc = r[i];
                for (int j = 1; j < i; ++j) acc += a[j] * r[i - j];
                const double k = -acc / err;
                double tmp[kOrder + 1];
                for (int j = 1; j < i; ++j) tmp[j] = a[j] + k * a[i - j];
                for (int j = 1; j < i; ++j) a[j] = tmp[j];
                a[i] = k;
                err *= (1.0 - k * k);
                ok = err > 0 && std::isfinite(err);
            }
            if (!ok) continue;
            for (int k = 0; k <= kOrder; ++k) a_[c][k] = a[k];
        }
        fitted_ = true;
    }

    const ModuleDescriptor& d_;
    std::vector<float> ring_[2], removed_[2];
    std::vector<double> win_, r_, b_, x_, y_, t_;
    double a_[2][kOrder + 1] = {}, sigma2_[2] = {}, k_ = 7, rmsCoef_ = 0.99;
    uint32_t warm_ = 0, size_ = 1, delay_ = 240, maxGap_ = 96, maxLen_ = 48, lpcWin_ = 512, lpcHop_ = 256, sinceFit_ = 0, lastLen_ = 0;
    uint64_t t_now_ = 0, gapStart_ = 0, gapEnd_ = 0, last_ = 0, repairAt_ = 0, clicks_ = 0, recent_ = 0;
    bool fitted_ = false, inGap_ = false, pending_ = false, crackle_ = false, listen_ = false;
};

// ---- De-plosive -----------------------------------------------------------------------------------------------

enum PlosiveParam : uint32_t { kPSens, kPFreq, kPAmount, kPLength, kPListen, kPCount };

const ParamTable& plosiveParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("sensitivity", "Sensitivity", 0.5, 0.0, 1.0);
        p.expo("frequency", "Frequency", 150.0, 60.0, 300.0, "Hz");
        p.num("amount", "Amount", 12.0, 0.0, 24.0, "dB");
        p.num("length", "Length", 60.0, 10.0, 80.0, "ms");
        p.pick("listen", "Listen to removed", 0.0, kOffOn);
        return p;
    }();
    return t;
}

class DePlosive final : public EffectBase, public VariableLatency {
public:
    explicit DePlosive(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double*, uint32_t) const noexcept override { return lookFrames(kPlosiveLook, rate()); }
    uint64_t idleFrames() const noexcept override { return look_.delay + static_cast<uint64_t>(0.1 * rate()); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        if (!det_.prepare(sr, HushDetector::kBands) || !look_.prepare(lookFrames(kPlosiveLook, sr))) return false;
        const double hop = det_.hopSeconds();
        slow_ = detExp(-hop / 0.3);
        attackRun_ = detExp(-double(kControlFrames) / (0.0007 * sr));  // per run of 16 frames
        releaseRun_ = detExp(-double(kControlFrames) / (0.02 * sr));
        return true;
    }
    void clearState() noexcept override {
        det_.clear();
        look_.clear();
        for (auto& f : cut_) f.clear();
        lowSlow_ = midSlow_ = 0.0;
        warm_ = 0;
        event_ = false;
        eventHops_ = 0;
        env_ = 0.0;
    }
    void control(uint32_t at) noexcept override {
        const double s = clampd(param(kPSens, at), 0.0, 1.0);
        ratio_ = lib::dbToGain(2.0 * (15.0 - 9.0 * s));  // a power ratio (10^(dB/10)): 15 dB at 0, 6 dB at 1
        const double f = clampd(param(kPFreq, at), 60.0, 300.0);
        if (f != freqFor_) {
            freqFor_ = f;
            const double w = 2.0 * kPi * f / rate();
            cos_ = detCos(w);
            alpha_ = detSin(w) * 0.7071067811865476;  // a shelf slope of 1
        }
        amountDb_ = clampd(param(kPAmount, at), 0.0, 24.0);
        maxHops_ = static_cast<uint32_t>(clampd(param(kPLength, at), 10.0, 80.0) * 0.001 / det_.hopSeconds() + 0.5);
        listen_ = on(kPListen, at);
    }
    // The cut is a low shelf (RBJ cookbook, slope 1) at Frequency whose gain follows the event's envelope, set
    // once a run (at most 16 frames): exactly -Amount dB at the bottom. Outside events it is bypassed (state cleared),
    // so the voice passes untouched, only delayed.
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const bool was = env_ > 0.0;
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = finiteOr0(inL[i]), xr = finiteOr0(inR[i]);
            if (det_.push(0.5 * (xl + xr))) hop();
            look_.step(static_cast<float>(xl), static_cast<float>(xr), dl_[i], dr_[i]);
        }
        const double target = event_ ? 1.0 : 0.0;
        const double coef = target > env_ ? attackRun_ : releaseRun_;
        env_ = target + (env_ - target) * (n == kControlFrames ? coef : detExp(detLog(coef) * n / kControlFrames));
        if (env_ < 1e-4 && !event_) env_ = 0.0;
        if (!was && env_ == 0.0) {
            for (uint32_t i = 0; i < n; ++i) {
                outL[i] = listen_ ? 0.0f : dl_[i];
                outR[i] = listen_ ? 0.0f : dr_[i];
            }
            for (auto& f : cut_) f.clear();
            return;
        }
        const double db = -amountDb_ * env_;
        cutMax_ = std::min(cutMax_, db);
        const double a = lib::dbToGain(0.5 * db), sa = std::sqrt(a), c = cos_, al = alpha_;
        const double a0 = (a + 1) + (a - 1) * c + 2 * sa * al;
        for (auto& f : cut_) {
            f.b0 = a * ((a + 1) - (a - 1) * c + 2 * sa * al) / a0;
            f.b1 = 2 * a * ((a - 1) - (a + 1) * c) / a0;
            f.b2 = a * ((a + 1) - (a - 1) * c - 2 * sa * al) / a0;
            f.a1 = -2 * ((a - 1) + (a + 1) * c) / a0;
            f.a2 = ((a + 1) + (a - 1) * c - 2 * sa * al) / a0;
        }
        for (uint32_t i = 0; i < n; ++i) {
            const double yl = cut_[0].run(dl_[i]), yr = cut_[1].run(dr_[i]);
            outL[i] = static_cast<float>(listen_ ? dl_[i] - yl : yl);
            outR[i] = static_cast<float>(listen_ ? dr_[i] - yr : yr);
        }
        for (auto& f : cut_) f.flush();
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(cutMax_);  // the deepest cut since the last publish, dB (0 or less)
        out[3] = static_cast<float>(events_);
        out[4] = static_cast<float>(10.0 * std::log10(lowNow_ + 1e-12));
        out[5] = static_cast<float>(10.0 * std::log10(rise_ + 1e-12));
        out[6] = static_cast<float>(1000.0 * look_.delay / rate());
        cutMax_ = 0.0;
        return 7;
    }

private:
    void hop() noexcept {
        const double low = det_.low, mid = det_.mid;
        lowNow_ = low;
        if (warm_ < 8) {  // the first hops only set the baselines (their mean)
            ++warm_;
            lowSlow_ += (low - lowSlow_) / warm_, midSlow_ += (mid - midSlow_) / warm_;
            return;
        }
        const double lowRise = low / (lowSlow_ + 1e-10), midRise = mid / (midSlow_ + 1e-10);
        rise_ = lowRise;
        if (!event_) {
            if (lowRise > ratio_ && low > 1e-6 && lowRise > 4.0 * midRise && low > 0.5 * mid) {
                event_ = true;
                eventHops_ = 0;
                ++events_;
            }
        } else if (++eventHops_ >= maxHops_ || lowRise < 0.5 * ratio_) {
            event_ = false;
        }
        if (!event_) {  // the baselines follow outside events only
            lowSlow_ = low + (lowSlow_ - low) * slow_;
            midSlow_ = mid + (midSlow_ - mid) * slow_;
        }
    }

    const ModuleDescriptor& d_;
    HushDetector det_;
    Look look_;
    clean::Biquad cut_[2];
    float dl_[kControlFrames] = {}, dr_[kControlFrames] = {};
    double slow_ = 0.99, attackRun_ = 0.6, releaseRun_ = 0.98, lowSlow_ = 0, midSlow_ = 0, ratio_ = 10, amountDb_ = 12;
    double cos_ = 1, alpha_ = 0;
    double env_ = 0, freqFor_ = -1, cutMax_ = 0, lowNow_ = 0, rise_ = 0;
    uint32_t warm_ = 0, eventHops_ = 0, maxHops_ = 22;
    uint64_t events_ = 0;
    bool event_ = false, listen_ = false;
};

// ---- Breath ---------------------------------------------------------------------------------------------------

enum BreathParam : uint32_t { kBSens, kBRange, kBFade, kBKeep, kBListen, kBCount };

const ParamTable& breathParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("sensitivity", "Sensitivity", 0.5, 0.0, 1.0);
        p.num("range", "Range", 12.0, 0.0, 40.0, "dB");
        p.num("fade", "Fade", 10.0, 2.0, 30.0, "ms");
        p.pick("keep", "Keep between phrases", 0.0, kOffOn);
        p.pick("listen", "Listen to removed", 0.0, kOffOn);
        return p;
    }();
    return t;
}

class Breath final : public EffectBase, public VariableLatency {
public:
    explicit Breath(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double*, uint32_t) const noexcept override { return lookFrames(kBreathLook, rate()); }
    uint64_t idleFrames() const noexcept override { return look_.delay + static_cast<uint64_t>(0.1 * rate()); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        if (!det_.prepare(sr, HushDetector::kBands | HushDetector::kSpectrum | HushDetector::kVoicing) ||
            !look_.prepare(lookFrames(kBreathLook, sr)))
            return false;
        hop_ = det_.hopSeconds();
        confirmHops_ = static_cast<uint32_t>(kBreathLook / hop_ + 0.5);
        maxHops_ = static_cast<uint32_t>(0.6 / hop_ + 0.5);
        pauseHops_ = static_cast<uint32_t>(0.25 / hop_ + 0.5);
        return true;
    }
    void clearState() noexcept override {
        det_.clear();
        look_.clear();
        peakDb_ = -120.0;
        run_ = 0;
        quiet_ = 0;
        afterPause_ = false;
        veto_ = false;
        down_ = false;
        gain_ = 1.0;
    }
    void control(uint32_t at) noexcept override {
        sens_ = clampd(param(kBSens, at), 0.0, 1.0);
        range_ = clampd(param(kBRange, at), 0.0, 40.0);
        fadeFrames_ = std::max(1.0, clampd(param(kBFade, at), 2.0, 30.0) * 0.001 * rate());
        keep_ = on(kBKeep, at);
        listen_ = on(kBListen, at);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = finiteOr0(inL[i]), xr = finiteOr0(inR[i]);
            if (det_.push(0.5 * (xl + xr))) hop();
            float dl, dr;
            look_.step(static_cast<float>(xl), static_cast<float>(xr), dl, dr);
            // Toward the target in a straight line over the fade (down) or at most the look-ahead (up, so the
            // voice after a breath is back at full level).
            const double target = down_ ? targetGain_ : 1.0;
            const double frames = down_ ? fadeFrames_ : std::min(fadeFrames_, look_.delay * 0.8);
            const double step = (1.0 - targetGain_) / frames;
            gain_ = gain_ > target ? std::max(target, gain_ - step) : std::min(target, gain_ + step);
            const double g = listen_ ? 1.0 - gain_ : gain_;
            outL[i] = static_cast<float>(dl * g);
            outR[i] = static_cast<float>(dr * g);
            gainMin_ = std::min(gainMin_, gain_);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(lib::gainToDb(gainMin_, -120.0));
        out[3] = static_cast<float>(breaths_);
        out[4] = static_cast<float>(det_.flatness);
        out[5] = static_cast<float>(voiced_);
        out[6] = static_cast<float>(levelDb_);
        out[7] = static_cast<float>(1000.0 * look_.delay / rate());
        out[8] = run_ > 0 ? 1.0f : 0.0f;
        gainMin_ = 1.0;
        return 9;
    }

private:
    void hop() noexcept {
        const double total = det_.level;
        levelDb_ = 10.0 * std::log10(total + 1e-14);
        peakDb_ = std::max(levelDb_, peakDb_ - 6.0 * hop_);  // the phrase's level, falling 6 dB a second
        const bool silent = levelDb_ < -70.0 || levelDb_ < peakDb_ - 55.0;
        voiced_ = 0.0;
        bool like = false;
        const double flatT = 0.35 - 0.2 * sens_;
        if (!silent && levelDb_ < peakDb_ - 12.0 && det_.flatness > flatT && det_.zcr > 2500.0 - 1000.0 * sens_ &&
            det_.high < 0.6 * total) {  // not a sibilant (mostly above 5 kHz)
            voiced_ = det_.voicing();  // only now: its cost is paid on candidates
            like = voiced_ < 0.6 + 0.2 * sens_;
        }
        if (like) {
            if (run_ == 0) afterPause_ = quiet_ >= pauseHops_;
            ++run_;
            if (run_ > maxHops_) veto_ = true;  // too long for a breath
            if (run_ >= confirmHops_ && !veto_ && !down_) {
                down_ = true;
                ++breaths_;
                targetGain_ = lib::dbToGain(-(keep_ && afterPause_ ? 0.5 : 1.0) * range_);
            }
            if (veto_) down_ = false;
        } else {
            run_ = 0;
            veto_ = false;
            down_ = false;
        }
        quiet_ = silent ? quiet_ + 1 : 0;
    }

    const ModuleDescriptor& d_;
    HushDetector det_;
    Look look_;
    double hop_ = 0.00267, sens_ = 0.5, range_ = 12, fadeFrames_ = 480, peakDb_ = -120, levelDb_ = -120, voiced_ = 0;
    double gain_ = 1.0, targetGain_ = 0.25, gainMin_ = 1.0;
    uint32_t confirmHops_ = 8, maxHops_ = 225, pauseHops_ = 94, run_ = 0, quiet_ = 0;
    uint64_t breaths_ = 0;
    bool keep_ = false, listen_ = false, afterPause_ = false, veto_ = false, down_ = false;
};

// ---- The device -----------------------------------------------------------------------------------------------

constexpr std::string_view kId = "org.caw.vocalclean";
constexpr std::string_view kName = "Hush";
constexpr std::string_view kVariants[] = {"De-click", "De-plosive", "Breath"};

const ModuleDescriptor& clickBase() {
    static const ModuleDescriptor d = withDomains(
        withCpu(effectDescriptor(kId, kName, clickParams(), lookFrames(kClickLook, 48000), 0), CpuClass::Medium), kDomainWhole);
    return d;
}
const ModuleDescriptor& plosiveBase() {
    static const ModuleDescriptor d = withDomains(
        withCpu(effectDescriptor(kId, kName, plosiveParams(), lookFrames(kPlosiveLook, 48000), 0), CpuClass::Light), kDomainWhole);
    return d;
}
const ModuleDescriptor& breathBase() {
    static const ModuleDescriptor d = withDomains(
        withCpu(effectDescriptor(kId, kName, breathParams(), lookFrames(kBreathLook, 48000), 0), CpuClass::Light), kDomainWhole);
    return d;
}

template <class T>
ModuleProcessor* makeAs(const ModuleDescriptor& d) noexcept {
    return new (std::nothrow) T(d);
}
template <uint32_t Index, const ModuleDescriptor& (*Base)(), ModuleProcessor* (*MakeAs)(const ModuleDescriptor&) noexcept>
struct V {
    static const ModuleDescriptor& descriptor() {
        static const ModuleDescriptor& d = legacyVariantDescriptor(Base(), kId, kName, kVariants, Index);
        return d;
    }
    static ModuleProcessor* create() noexcept { return MakeAs(descriptor()); }
    static constexpr Variant variant() { return {kVariants[Index], &descriptor, &create}; }
};

const Variant kHush[] = {V<0, &clickBase, &makeAs<DeClick>>::variant(), V<1, &plosiveBase, &makeAs<DePlosive>>::variant(),
                         V<2, &breathBase, &makeAs<Breath>>::variant()};
const MergedDevice kDevices[] = {{kId, kName, kHush}};

const std::vector<BuiltinPreset>& hushPresetList() {
    static const std::vector<BuiltinPreset> p = {
        // De-click (0)
        {"Mouth clicks", "Vocals: lip and tongue clicks in close-miked speech or singing", {{"sensitivity", 0.5}, {"length", 1}, {"variant", 0}}},
        {"Gentle de-click", "Vocals: only the obvious clicks", {{"sensitivity", 0.25}, {"variant", 0}}},
        {"Vinyl clicks", "Lo-fi: scratches and pops from a record", {{"sensitivity", 0.6}, {"length", 2}, {"variant", 0}}},
        {"Vinyl crackle", "Lo-fi: a record's fine crackle", {{"sensitivity", 0.6}, {"mode", 1}, {"variant", 0}}},
        {"Digital ticks", "Mixing: single-sample ticks from edits or dropouts", {{"sensitivity", 0.7}, {"length", 0.3}, {"variant", 0}}},
        {"Guitar pick noise", "Guitar: sharp pick and fret clicks on acoustic", {{"sensitivity", 0.4}, {"length", 0.5}, {"variant", 0}}},
        {"Strong de-click", "Mixing: every click it can find (may touch transients)", {{"sensitivity", 0.9}, {"length", 2}, {"variant", 0}}},
        {"Hear the clicks", "Mixing: listen to what is taken out", {{"sensitivity", 0.5}, {"listen", 1}, {"variant", 0}}},
        // De-plosive (1)
        {"Pop filter", "Vocals: P and B pops on a close mic", {{"variant", 1}}},
        {"Gentle plosives", "Vocals: only the strongest pops, a light cut", {{"sensitivity", 0.3}, {"amount", 8}, {"variant", 1}}},
        {"Strong plosives", "Vocals: deep pops on a very close mic", {{"sensitivity", 0.7}, {"amount", 18}, {"frequency", 200}, {"variant", 1}}},
        {"Podcast voice", "Vocals: speech pops and breath thumps", {{"sensitivity", 0.6}, {"amount", 14}, {"length", 70}, {"variant", 1}}},
        {"Low male voice", "Vocals: a lower cut that keeps the chest", {{"frequency", 100}, {"amount", 12}, {"variant", 1}}},
        {"Bright female voice", "Vocals: a higher cut for a lighter voice", {{"frequency", 220}, {"amount", 12}, {"variant", 1}}},
        {"Wind bumps", "Mixing: short low thumps from wind or handling", {{"sensitivity", 0.6}, {"frequency", 250}, {"amount", 20}, {"length", 80}, {"variant", 1}}},
        {"Kick-safe plosives", "Vocals: only pops well over the low end around them", {{"sensitivity", 0.2}, {"amount", 10}, {"length", 40}, {"variant", 1}}},
        // Breath (2)
        {"Softer breaths", "Vocals: breaths lowered, still natural", {{"range", 8}, {"variant", 2}}},
        {"Breath control", "Vocals: breaths well down for a pop vocal", {{"range", 15}, {"variant", 2}}},
        {"Remove breaths", "Vocals: breaths almost gone", {{"range", 30}, {"sensitivity", 0.6}, {"variant", 2}}},
        {"Keep phrasing", "Vocals: breaths between phrases kept a little", {{"range", 15}, {"keep", 1}, {"variant", 2}}},
        {"Voice-over", "Vocals: speech breaths lowered, quick fades", {{"range", 18}, {"fade", 6}, {"variant", 2}}},
        {"Gentle sensitive", "Vocals: soft breaths found more easily", {{"range", 10}, {"sensitivity", 0.8}, {"variant", 2}}},
        {"Slow fades", "Vocals: long, smooth fades into each breath", {{"range", 12}, {"fade", 25}, {"variant", 2}}},
        {"Audiobook", "Vocals: narration breaths well down, smooth fades", {{"range", 22}, {"fade", 15}, {"sensitivity", 0.6}, {"variant", 2}}},
    };
    return p;
}

}  // namespace

std::span<const MergedDevice> mergedHushDevices() { return kDevices; }
const std::vector<BuiltinPreset>& hushPresets() { return hushPresetList(); }

const std::vector<BuiltinPreset>& preenPresets();  // builtin_fx_preen.cpp

std::span<const BuiltinPreset> cleanPresets(std::string_view id) {
    if (id == "org.caw.clean") return preenPresets();
    if (id == kId) return hushPresets();
    return {};
}

size_t hushBytes(uint32_t variant, double sr) noexcept {
    const double scale = sr > 140000 ? 4 : (sr > 70000 ? 2 : (sr < 32000 ? 0.5 : 1));
    auto ring = [](uint32_t frames) {
        uint32_t s = 1;
        while (s < frames + 1) s <<= 1;
        return size_t{2} * s * 4;
    };
    if (variant == 0) {
        const uint32_t delay = lookFrames(kClickLook, sr), gap = static_cast<uint32_t>(0.002 * sr + 0.5), win = sr > 70000 ? 1024 : 512;
        uint32_t s = 1;
        while (s < delay + win + gap + 4 * kOrder + 64) s <<= 1;
        return size_t{4} * s * 4 + win * 8 + 5 * (gap + 2) * 8;
    }
    if (variant == 1) return ring(lookFrames(kPlosiveLook, sr));
    const size_t fft = static_cast<size_t>(256 * scale);
    return ring(lookFrames(kBreathLook, sr)) + fft * (4 + 16) + 512 * 4;
}

}  // namespace caw::fx
