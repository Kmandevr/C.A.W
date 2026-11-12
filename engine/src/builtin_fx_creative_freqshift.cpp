// The frequency shifter (fx-creative): "org.caw.freqshift", single-sideband shifting through a Hilbert transformer, up, down or both, with a feedback delay.
#include <cmath>

#include "builtin_fx_creative.h"
#include "caw/library/oversample.hpp"

// Original code (C.A.W. is Apache-2.0). Single-sideband modulation (Bode's frequency shifter; DAFX, 2nd ed.,
// ch. 3 "Modulators and demodulators"): the input becomes an analytic pair I, Q (Q the Hilbert transform of
// I, 90 degrees behind at every frequency); I cos(wt) - Q sin(wt) is every partial moved up by w, I cos + Q sin
// moved down. The pair comes from two chains of all-passes whose phases differ by 90 degrees: the Library's
// polyphase half-band (Valenzuela and Constantinides 1983) moved by a quarter of the sample rate, which turns
// each section (a + z^-2)/(1 + a z^-2) into one with coefficient -a and leaves one branch a sample late
// (Harris, "Multirate Signal Processing for Communication Systems", 2004, on half-band Hilbert filters). With 12
// sections and a transition of 20 Hz the difference stays within 0.1 degree from 20 Hz to 20 kHz at 48 kHz, so
// the unwanted sideband is about 60 dB down (tested). IIR: no latency.

namespace caw::fx {

namespace {

using creative::clampTo;

enum ShiftParam : uint32_t { kShift, kDirection, kSpread, kFeedback, kDelayF, kMixF, kShiftCount };
constexpr std::string_view kDirections[] = {"Up", "Down", "Both"};
constexpr double kMaxDelay = 1.0;  // seconds

const ParamTable& shiftParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("shift", "Shift", 100.0, -2000.0, 2000.0, "Hz");
        p.pick("direction", "Direction", 0.0, kDirections);
        p.num("spread", "Stereo spread", 0.0, 0.0, 200.0, "Hz");
        p.num("feedback", "Feedback", 0.0, 0.0, 0.95);
        p.expo("delay", "Feedback delay", 10.0, 1.0, 1000.0, "ms");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

const ModuleDescriptor& shiftDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.freqshift", "Frequency shifter", shiftParams(), 0, 4800);
    return d;
}

// The 90-degree pair: i() and q() of one input, q() 90 degrees behind i() across the band.
class Hilbert {
public:
    void set(double sampleRate) noexcept {
        const lib::HalfBandDesign d(12, clampTo(20.0 / sampleRate, 1e-4, 0.02));
        ni_ = nq_ = 0;
        for (int k = 0; k < d.count(); ++k) (k % 2 ? q_[nq_++] : i_[ni_++]) = -d.coefficient(k);
        clear();
    }
    void clear() noexcept {
        for (int k = 0; k < 6; ++k) xi_[k][0] = xi_[k][1] = yi_[k][0] = yi_[k][1] = 0.0;
        for (int k = 0; k < 6; ++k) xq_[k][0] = xq_[k][1] = yq_[k][0] = yq_[k][1] = 0.0;
        held_ = 0.0;
    }
    void process(double x, double& i, double& q) noexcept {
        i = chain(x, i_, ni_, xi_, yi_);
        q = chain(held_, q_, nq_, xq_, yq_);  // the Q branch a frame late
        held_ = x;
    }
    void flush() noexcept {
        auto f = [](double& v) { if (v < 1e-20 && v > -1e-20) v = 0.0; };
        for (int k = 0; k < 6; ++k)
            for (int j = 0; j < 2; ++j) f(xi_[k][j]), f(yi_[k][j]), f(xq_[k][j]), f(yq_[k][j]);
    }

private:
    // First-order all-passes in z^-2: y = a (x - y[n-2]) + x[n-2].
    static double chain(double x, const double* a, int n, double (*xs)[2], double (*ys)[2]) noexcept {
        for (int k = 0; k < n; ++k) {
            const double y = a[k] * (x - ys[k][1]) + xs[k][1];
            xs[k][1] = xs[k][0], xs[k][0] = x;
            ys[k][1] = ys[k][0], ys[k][0] = y;
            x = y;
        }
        return x;
    }
    double i_[6] = {}, q_[6] = {};
    int ni_ = 0, nq_ = 0;
    double xi_[6][2] = {}, yi_[6][2] = {}, xq_[6][2] = {}, yq_[6][2] = {};
    double held_ = 0.0;
};

class FreqShift final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return shiftDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        for (auto& h : hilbert_) h.set(sr);
        return ring_.allocate(static_cast<size_t>(std::ceil(kMaxDelay * sr)) + 8);
    }
    void clearState() noexcept override {
        for (auto& h : hilbert_) h.clear();
        ring_.clear();
        phase_[0] = phase_[1] = 0.0;
        mix_.reset(), fb_.reset(), delay_.reset();
        for (auto& s : shift_) s.reset();
    }
    uint64_t idleFrames() const noexcept override {
        // The feedback delay rings: a pass every `delay`, each fb_ quieter, until -110 dB (at most 30 s).
        const double fb = fb_.value;
        const double passes = fb > 1e-3 ? std::min(200.0, 110.0 / (-8.685889638065035 * lib::fastLog(fb))) : 0.0;
        return static_cast<uint64_t>((passes + 1.0) * delay_.value + 0.05 * rate());
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const double shift = clampTo(param(kShift, at), -2000.0, 2000.0), spread = clampTo(param(kSpread, at), 0.0, 200.0);
        shift_[0].set((shift - 0.5 * spread) / sr, kControlFrames);
        shift_[1].set((shift + 0.5 * spread) / sr, kControlFrames);
        direction_ = std::clamp(choice(kDirection, at), 0, 2);
        fb_.set(clampTo(param(kFeedback, at), 0.0, 0.95), kControlFrames);
        delay_.set(clampTo(param(kDelayF, at), 1.0, 1000.0) * 0.001 * sr, kControlFrames);
        mix_.set(clampTo(param(kMixF, at), 0.0, 1.0), kControlFrames);
        for (auto& h : hilbert_) h.flush();
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {inL[i], inR[i]};
            const double fb = fb_.next(), d = delay_.next(), m = mix_.next();
            double y[2];
            for (int c = 0; c < 2; ++c) {
                // The loop soft-limited, so it can't run away (and not read at all while there is none).
                const double v = fb > 0.0 ? x[c] + fb * lib::tanhApprox(ring_.read(c, d - 1.0)) : x[c];
                double I, Q;
                hilbert_[c].process(v, I, Q);
                phase_[c] += shift_[c].next();
                phase_[c] -= std::floor(phase_[c]);
                const double s = lib::fastSinCycles(phase_[c]), co = lib::fastSinCycles(phase_[c] + 0.25);
                const bool up = direction_ == 0 || (direction_ == 2 && c == 0);
                y[c] = up ? I * co - Q * s : I * co + Q * s;
            }
            ring_.write(y[0], y[1]);
            outL[i] = static_cast<float>(x[0] + (y[0] - x[0]) * m);
            outR[i] = static_cast<float>(x[1] + (y[1] - x[1]) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        const double sr = rate();
        const double sign[2] = {direction_ == 1 ? -1.0 : 1.0, direction_ == 0 ? 1.0 : -1.0};
        out[2] = static_cast<float>(sign[0] * shift_[0].value * sr);  // the shift each side hears, in Hz
        out[3] = static_cast<float>(sign[1] * shift_[1].value * sr);
        out[4] = static_cast<float>(direction_);
        out[5] = static_cast<float>(fb_.value);
        out[6] = static_cast<float>(phase_[0]);
        return 7;
    }

private:
    Hilbert hilbert_[2];
    creative::Ring ring_;
    Ramp shift_[2], fb_, delay_, mix_;
    double phase_[2] = {0.0, 0.0};
    int direction_ = 0;
};

}  // namespace

void registerFreqShift(ModuleRegistry& registry) { registry.add(shiftDescriptor(), &creative::make<FreqShift>); }

}  // namespace caw::fx
