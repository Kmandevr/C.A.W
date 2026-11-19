// Phase align (org.caw.phasealign, 1.1.0): a sub-sample delay and polarity against a key track, set by hand or learned by GCC-PHAT cross-correlation.
#include <algorithm>
#include <cmath>
#include <memory>
#include <new>

#include "builtin_effects.h"
#include "builtin_fx_tools.h"
#include "caw/detmath.hpp"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0). For multi-mic drums or a DI and an amp: this track is delayed (0..20 ms, a
// fraction of a sample at a time: 4-point Lagrange interpolation, so the device adds 1 frame of latency the host
// compensates) and its polarity flipped, to line up with the key (the sidechain: the reference track).
// Auto learns both: it cuts this track and the key into frames of F samples (F the power of 2 at least twice the
// longest lag, 20 ms: 2048 at 48 kHz), and for each frame where both sound (above -60 dBFS) adds their cross-power
// spectrum (one complex FFT of 2F carries both, separated by symmetry). After `window` seconds of such frames it
// weights the sum by its magnitude (the generalized cross-correlation with phase transform, GCC-PHAT: C. Knapp
// and G. Carter, IEEE Trans. ASSP 24(4), 1976), takes the inverse FFT, and finds the strongest peak within +-20
// ms: its place (refined by a parabola through its neighbours) is the lag, its sign the polarity, its height
// (0..1) the confidence. The work runs on the audio thread at frame rate (about 23 FFTs a second at 48 kHz) only
// while learning, then stops. A lag that would need this track moved earlier (it is late) cannot be applied here:
// the display says how far, to delay the key's track instead. The FFT tables are shared by every instance.

namespace caw::fx {

namespace {

enum AlignParam : uint32_t { kMode, kDelay, kInvert, kLearn, kWindow, kCount };
constexpr std::string_view kModes[] = {"Manual", "Auto"};
constexpr std::string_view kOff[] = {"Off", "On"};
constexpr double kMaxMs = 20.0;

const ParamTable& alignParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 0, kModes);
        p.num("delay", "Delay", 0.0, 0.0, kMaxMs, "ms").smoothingFrames = 0;  // smoothed inside (no zipper)
        p.pick("invert", "Invert", 0, kOff);
        ParameterDescriptor& l = p.pick("learn", "Learn", 0, kOff);  // Off to On: Auto learns again
        l.automatable = false;
        l.modulatable = false;
        p.num("window", "Window", 2.0, 0.5, 10.0, "s").smoothingFrames = 0;
        return p;
    }();
    return t;
}
const ModuleDescriptor& alignDescriptor() {
    static const ModuleDescriptor d =
        withCpu(keyedEffectDescriptor("org.caw.phasealign", "Phase align", alignParams(), 1, 0, false), CpuClass::Light);
    return d;
}

// A radix-2 complex FFT's tables for one size, shared read-only by every instance (built on the control thread).
struct FftTable {
    uint32_t n = 0;
    std::unique_ptr<uint32_t[]> rev;
    std::unique_ptr<float[]> c, s;
    explicit FftTable(uint32_t size) : n(size), rev(new uint32_t[size]), c(new float[size / 2]), s(new float[size / 2]) {
        uint32_t bits = 0;
        while ((1u << bits) < n) ++bits;
        for (uint32_t i = 0; i < n; ++i) {
            uint32_t r = 0;
            for (uint32_t k = 0; k < bits; ++k) r |= ((i >> k) & 1u) << (bits - 1 - k);
            rev[i] = r;
        }
        for (uint32_t i = 0; i < n / 2; ++i) {
            c[i] = static_cast<float>(detCos(kTwoPi * i / n));
            s[i] = static_cast<float>(-detSin(kTwoPi * i / n));
        }
    }
};
const FftTable* fftTable(uint32_t n) {
    switch (n) {  // the sizes 44.1 to 192 kHz need
        case 4096: { static const FftTable t(4096); return &t; }
        case 8192: { static const FftTable t(8192); return &t; }
        case 16384: { static const FftTable t(16384); return &t; }
        default: return nullptr;
    }
}
// In place; inverse: conjugate twiddles, no scaling.
void fft(float* re, float* im, const FftTable& t, bool inverse) noexcept {
    const uint32_t n = t.n;
    for (uint32_t i = 0; i < n; ++i)
        if (const uint32_t j = t.rev[i]; j > i) std::swap(re[i], re[j]), std::swap(im[i], im[j]);
    const float sign = inverse ? -1.0f : 1.0f;
    for (uint32_t len = 2; len <= n; len <<= 1) {
        const uint32_t half = len / 2, step = n / len;
        for (uint32_t i = 0; i < n; i += len)
            for (uint32_t k = 0; k < half; ++k) {
                const float wr = t.c[k * step], wi = sign * t.s[k * step];
                const uint32_t a = i + k, b = a + half;
                const float xr = re[b] * wr - im[b] * wi, xi = re[b] * wi + im[b] * wr;
                re[b] = re[a] - xr, im[b] = im[a] - xi;
                re[a] += xr, im[a] += xi;
            }
    }
}

class PhaseAlign final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return alignDescriptor(); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        maxLag_ = static_cast<uint32_t>(std::ceil(kMaxMs * 1e-3 * sampleRate));
        frame_ = 1024;
        while (frame_ < 2 * maxLag_) frame_ <<= 1;
        table_ = fftTable(2 * frame_);
        if (!table_) return false;
        uint32_t line = 8;
        while (line < maxLag_ + 8) line <<= 1;
        mask_ = line - 1;
        const uint32_t n = 2 * frame_;
        lineL_.reset(new (std::nothrow) float[line]);
        lineR_.reset(new (std::nothrow) float[line]);
        x_.reset(new (std::nothrow) float[frame_]);
        y_.reset(new (std::nothrow) float[frame_]);
        re_.reset(new (std::nothrow) float[n]);
        im_.reset(new (std::nothrow) float[n]);
        accRe_.reset(new (std::nothrow) float[frame_ + 1]);
        accIm_.reset(new (std::nothrow) float[frame_ + 1]);
        if (!lineL_ || !lineR_ || !x_ || !y_ || !re_ || !im_ || !accRe_ || !accIm_) return false;
        smooth_ = 1.0 - std::exp(-static_cast<double>(kControlFrames) / (0.02 * sampleRate));
        corrKeep_ = std::exp(-static_cast<double>(kControlFrames) / (0.3 * sampleRate));
        return true;
    }

    void control(uint32_t at) noexcept override {
        const bool autoMode = choice(kMode, at) == 1;
        const bool learn = on(kLearn, at);
        if ((learn && !learnWas_) || (autoMode && !autoWas_)) startLearning();
        learnWas_ = learn;
        autoWas_ = autoMode;
        learning_ = autoMode && !learned_;
        windowFrames_ = param(kWindow, at) * rate();
        const double target = autoMode ? (learned_ ? learnedDelay_ : 0.0)
                                       : std::clamp(param(kDelay, at), 0.0, kMaxMs) * 1e-3 * rate();
        const bool invert = autoMode ? learnedInvert_ : on(kInvert, at);
        delay_ = fresh_ ? target : delay_ + (target - delay_) * smooth_;
        if (std::fabs(delay_ - target) < 1e-6) delay_ = target;
        fresh_ = false;
        polarity_.set(invert ? -1.0 : 1.0, kControlFrames);
        // 4-point Lagrange taps for the delay plus the 1-frame latency, at positions k-1 .. k+2 back.
        const double d = delay_ + 1.0;
        const double k = std::floor(d), f = d - k;
        tap_ = static_cast<uint32_t>(k) - 1;
        const double fm1 = f - 1.0, fm2 = f - 2.0, fp1 = f + 1.0;
        h_[0] = static_cast<float>(-f * fm1 * fm2 / 6.0);
        h_[1] = static_cast<float>(fp1 * fm1 * fm2 / 2.0);
        h_[2] = static_cast<float>(-fp1 * f * fm2 / 2.0);
        h_[3] = static_cast<float>(fp1 * f * fm1 / 6.0);
        sxy_ *= corrKeep_, sxx_ *= corrKeep_, syy_ *= corrKeep_;
        if (!std::isfinite(sxy_ + sxx_ + syy_)) sxy_ = sxx_ = syy_ = 0.0;  // a non-finite input passed
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* kl = keyLeft();
        const float* kr = keyRight();
        for (uint32_t i = 0; i < n; ++i) {
            lineL_[write_] = inL[i];
            lineR_[write_] = inR[i];
            float l = 0.0f, r = 0.0f;
            for (uint32_t t = 0; t < 4; ++t) {
                const uint32_t p = (write_ - tap_ - t + 2 * (mask_ + 1)) & mask_;
                l += h_[t] * lineL_[p];
                r += h_[t] * lineR_[p];
            }
            write_ = (write_ + 1) & mask_;
            const float g = static_cast<float>(polarity_.next());
            outL[i] = l * g;
            outR[i] = r * g;
            const float key = kl ? 0.5f * (kl[i] + kr[i]) : 0.0f;
            const float me = 0.5f * (outL[i] + outR[i]);
            sxy_ += static_cast<double>(me) * keyPrev_, sxx_ += static_cast<double>(me) * me, syy_ += static_cast<double>(keyPrev_) * keyPrev_;
            keyPrev_ = key;  // the key 1 frame late, as the output is
            keyPeak_ = std::max(keyPeak_, std::fabs(key));
            if (learning_) {
                x_[fill_] = 0.5f * (inL[i] + inR[i]);
                y_[fill_] = key;
                if (++fill_ == frame_) addFrame();
            }
        }
    }

    void clearState() noexcept override {
        if (lineL_) std::fill_n(lineL_.get(), mask_ + 1, 0.0f), std::fill_n(lineR_.get(), mask_ + 1, 0.0f);
        write_ = 0;
        fresh_ = true;
        polarity_.reset();
        sxy_ = sxx_ = syy_ = 0.0;
        keyPrev_ = 0.0f;
        fill_ = 0;  // a frame in progress starts again (what was learned stays)
    }
    // Asleep the key may still sound: it stays awake while it does (EffectBase), and here for a frame's analysis.
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(delay_ * 1000.0 / rate());
        out[3] = polarity_.value < 0.0 ? 1.0f : 0.0f;
        out[4] = static_cast<float>(autoWas_ ? 1 : 0);
        out[5] = static_cast<float>(learned_ ? 1.0 : std::min(1.0, heard_ / std::max(1.0, windowFrames_)));
        out[6] = static_cast<float>(foundLag_ * 1000.0 / rate());
        out[7] = static_cast<float>(confidence_);
        const double den = std::sqrt(sxx_ * syy_);
        out[8] = static_cast<float>(den > 1e-12 ? sxy_ / den : 0.0);
        out[9] = static_cast<float>(lib::gainToDb(keyPeak_));
        keyPeak_ = 0.0f;
        return 10;
    }

private:
    void startLearning() noexcept {
        std::fill_n(accRe_.get(), frame_ + 1, 0.0f);
        std::fill_n(accIm_.get(), frame_ + 1, 0.0f);
        heard_ = 0.0;
        fill_ = 0;
        learned_ = false;
    }
    // One frame of both signals into the cross-power sum (a frame where either is near silence counts for nothing).
    void addFrame() noexcept {
        fill_ = 0;
        const uint32_t n = 2 * frame_;
        double ex = 0.0, ey = 0.0;
        for (uint32_t i = 0; i < frame_; ++i) ex += static_cast<double>(x_[i]) * x_[i], ey += static_cast<double>(y_[i]) * y_[i];
        if (!(ex / frame_ >= 1e-6 && ey / frame_ >= 1e-6 && std::isfinite(ex + ey))) return;  // -60 dBFS, or not finite
        for (uint32_t i = 0; i < frame_; ++i) re_[i] = x_[i], im_[i] = y_[i];
        std::fill_n(re_.get() + frame_, frame_, 0.0f);
        std::fill_n(im_.get() + frame_, frame_, 0.0f);
        fft(re_.get(), im_.get(), *table_, false);
        for (uint32_t k = 0; k <= frame_; ++k) {  // X = (Z[k] + conj Z[n-k]) / 2, Y = (Z[k] - conj Z[n-k]) / 2i
            const uint32_t m = (n - k) & (n - 1);
            const float xr = 0.5f * (re_[k] + re_[m]), xi = 0.5f * (im_[k] - im_[m]);
            const float yr = 0.5f * (im_[k] + im_[m]), yi = -0.5f * (re_[k] - re_[m]);
            accRe_[k] += xr * yr + xi * yi;  // X conj(Y)
            accIm_[k] += xi * yr - xr * yi;
        }
        heard_ += frame_;
        if (heard_ >= windowFrames_) finish();
    }
    void finish() noexcept {
        const uint32_t n = 2 * frame_;
        for (uint32_t k = 0; k <= frame_; ++k) {  // the phase transform: unit magnitude, then Hermitian
            const float mag = std::sqrt(accRe_[k] * accRe_[k] + accIm_[k] * accIm_[k]);
            const float w = mag > 1e-20f ? 1.0f / mag : 0.0f;
            re_[k] = accRe_[k] * w, im_[k] = accIm_[k] * w;
            if (k > 0 && k < frame_) re_[n - k] = re_[k], im_[n - k] = -im_[k];
        }
        im_[0] = im_[frame_] = 0.0f;
        fft(re_.get(), im_.get(), *table_, true);
        auto at = [&](int64_t lag) { return re_[static_cast<uint32_t>((lag + n) & (n - 1))] / static_cast<float>(n); };
        int64_t best = 0;
        float peak = 0.0f;
        for (int64_t lag = -static_cast<int64_t>(maxLag_); lag <= static_cast<int64_t>(maxLag_); ++lag)
            if (std::fabs(at(lag)) > std::fabs(peak)) peak = at(lag), best = lag;
        const double a = std::fabs(at(best - 1)), b = std::fabs(peak), c = std::fabs(at(best + 1));
        const double den = a - 2.0 * b + c;
        const double shift = den < 0.0 ? std::clamp(0.5 * (a - c) / den, -0.5, 0.5) : 0.0;
        // x(n) = y(n + d) (this track early by d) peaks at lag -d.
        foundLag_ = -(static_cast<double>(best) + shift);
        learnedDelay_ = std::clamp(foundLag_, 0.0, static_cast<double>(maxLag_));
        learnedInvert_ = peak < 0.0f;
        confidence_ = std::clamp(static_cast<double>(std::fabs(peak)), 0.0, 1.0);
        learned_ = true;
        learning_ = false;
    }

    const FftTable* table_ = nullptr;
    std::unique_ptr<float[]> lineL_, lineR_, x_, y_, re_, im_, accRe_, accIm_;
    uint32_t maxLag_ = 960, frame_ = 2048, mask_ = 0, write_ = 0, tap_ = 0, fill_ = 0;
    float h_[4] = {0, 1, 0, 0};
    double delay_ = 0, smooth_ = 0.05, corrKeep_ = 0.99;
    double sxy_ = 0, sxx_ = 0, syy_ = 0;
    float keyPrev_ = 0, keyPeak_ = 0;
    double windowFrames_ = 96000, heard_ = 0, foundLag_ = 0, learnedDelay_ = 0, confidence_ = 0;
    bool learned_ = false, learning_ = false, learnedInvert_ = false, learnWas_ = false, autoWas_ = false, fresh_ = true;
    Ramp polarity_;
};

ModuleProcessor* makeAlign() noexcept { return new (std::nothrow) PhaseAlign(); }

}  // namespace

void registerPhaseAlign(ModuleRegistry& registry) {
    fftTable(4096);  // 44.1 and 48 kHz's table, built here at registration rather than on a first use
    registry.add(alignDescriptor(), &makeAlign);
}

const std::vector<BuiltinPreset>& phaseAlignPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Auto align (2 s)", "Drums: learn the delay and polarity from two seconds of playing", {{"mode", 1}, {"window", 2}}},
        {"Auto align, quick", "Drums: learn from half a second", {{"mode", 1}, {"window", 0.5}}},
        {"Auto align, careful", "Mixing: learn from eight seconds (quiet or sparse parts)", {{"mode", 1}, {"window", 8}}},
        {"Snare bottom flip", "Drums: the bottom mic's polarity flipped", {{"invert", 1}}},
        {"Kick in and out", "Drums: the inside mic delayed 1 ms to meet the outside one", {{"delay", 1.0}}},
        {"Overheads to snare", "Drums: about 1 m of distance (2.9 ms)", {{"delay", 2.9}}},
        {"Room mic", "Drums: about 3 m of distance (8.7 ms)", {{"delay", 8.7}}},
        {"DI to amp", "Guitar: the DI delayed to meet a miked amp (0.6 ms)", {{"delay", 0.6}}},
        {"Bass DI to amp", "Bass: the DI delayed to its amp, auto", {{"mode", 1}, {"window", 3}}},
        {"Flip only", "Mixing: polarity only, no delay", {{"invert", 1}, {"delay", 0}}},
    };
    return p;
}

void registerTools(ModuleRegistry& registry) {
    registerLofi(registry);
    registerPhaseAlign(registry);
}

const std::vector<BuiltinPreset>* toolsPresets(std::string_view id) {
    if (id == "org.caw.meters") return &meterPresets();
    if (id == "org.caw.lofi") return &lofiPresets();
    if (id == "org.caw.phasealign") return &phaseAlignPresets();
    return nullptr;
}

}  // namespace caw::fx
