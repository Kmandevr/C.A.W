// C.A.W. Library: a display spectrum analyzer (two signals, one FFT, log-frequency bins in dB); header-only.
#pragma once

#include <cmath>
#include <cstdint>
#include <vector>

namespace caw::lib {

// For a UI, not for sound: it feeds a display (caw/display.hpp) and never changes audio, so it may use the
// platform's maths. push() is a store per sample; analyze() costs one 2048-point complex FFT (both signals at
// once: one is the real part, the other the imaginary part, and the two spectra are separated afterwards by the
// FFT's symmetry), about 30-60 us on a phone core, so call it at most ~60 times a second, and only while a UI
// is watching (DisplayBuffer::watched()). prepare() allocates; push() and analyze() never do.
//
// Each output bin covers an equal share of octaves between loHz and hiHz: the strongest FFT bin inside it, or,
// where a display bin is narrower than an FFT bin (the low end), the power interpolated at its centre. Levels
// are dB relative to a full-scale sine (Hann window), floored at -120, with fast-rise, slower-fall smoothing
// over successive calls so the picture moves calmly.
class SpectrumAnalyzer {
public:
    static constexpr uint32_t kSize = 2048;

    void prepare(double sampleRate, uint32_t bins = 128, double loHz = 20.0, double hiHz = 20000.0) {
        rate_ = sampleRate > 0.0 ? sampleRate : 48000.0;
        bins_ = bins < 1 ? 1 : bins;
        a_.assign(kSize, 0.0f);
        b_.assign(kSize, 0.0f);
        re_.assign(kSize, 0.0);
        im_.assign(kSize, 0.0);
        window_.resize(kSize);
        cos_.resize(kSize / 2);
        sin_.resize(kSize / 2);
        rev_.resize(kSize);
        const double pi = 3.14159265358979323846;
        for (uint32_t i = 0; i < kSize; ++i) window_[i] = static_cast<float>(0.5 - 0.5 * std::cos(2.0 * pi * i / kSize));
        for (uint32_t i = 0; i < kSize / 2; ++i) {
            cos_[i] = std::cos(2.0 * pi * i / kSize);
            sin_[i] = -std::sin(2.0 * pi * i / kSize);
        }
        uint32_t bits = 0;
        while ((1u << bits) < kSize) ++bits;
        for (uint32_t i = 0; i < kSize; ++i) {
            uint32_t r = 0;
            for (uint32_t k = 0; k < bits; ++k) r |= ((i >> k) & 1u) << (bits - 1 - k);
            rev_[i] = r;
        }
        hi_ = hiHz > 0.45 * rate_ ? 0.45 * rate_ : hiHz;
        lo_ = loHz > 0.0 && loHz < hi_ ? loHz : 20.0;
        from_.resize(bins_);
        to_.resize(bins_);
        centre_.resize(bins_);
        const double binHz = rate_ / kSize;
        for (uint32_t j = 0; j < bins_; ++j) {
            const double fl = lo_ * std::pow(hi_ / lo_, static_cast<double>(j) / bins_);
            const double fh = lo_ * std::pow(hi_ / lo_, static_cast<double>(j + 1) / bins_);
            from_[j] = static_cast<uint32_t>(std::ceil(fl / binHz));
            to_[j] = static_cast<uint32_t>(std::floor(fh / binHz));
            centre_[j] = std::sqrt(fl * fh) / binHz;
        }
        smoothA_.assign(bins_, -120.0f);
        smoothB_.assign(bins_, -120.0f);
        powA_.assign(kSize / 2 + 1, 0.0);
        powB_.assign(kSize / 2 + 1, 0.0);
        pos_ = 0;
    }
    void clear() noexcept {
        for (float& v : a_) v = 0.0f;
        for (float& v : b_) v = 0.0f;
        for (float& v : smoothA_) v = -120.0f;
        for (float& v : smoothB_) v = -120.0f;
    }
    uint32_t bins() const noexcept { return bins_; }
    double lowHz() const noexcept { return lo_; }
    double highHz() const noexcept { return hi_; }
    // The display bin j's centre frequency.
    double binHz(uint32_t j) const noexcept { return lo_ * std::pow(hi_ / lo_, (j + 0.5) / bins_); }

    void push(float a, float b) noexcept {
        if (a_.empty()) return;
        a_[pos_] = std::isfinite(a) ? a : 0.0f;
        b_[pos_] = std::isfinite(b) ? b : 0.0f;
        pos_ = (pos_ + 1) & (kSize - 1);
    }

    // The two spectra of the last kSize samples into outA and outB (bins() floats each; either may be null).
    void analyze(float* outA, float* outB) noexcept {
        if (a_.empty()) return;
        for (uint32_t i = 0; i < kSize; ++i) {
            const uint32_t at = (pos_ + i) & (kSize - 1), r = rev_[i];
            re_[r] = a_[at] * window_[i];
            im_[r] = b_[at] * window_[i];
        }
        for (uint32_t half = 1; half < kSize; half <<= 1) {
            const uint32_t step = kSize / (half * 2);
            for (uint32_t start = 0; start < kSize; start += half * 2)
                for (uint32_t k = 0; k < half; ++k) {
                    const double wr = cos_[k * step], wi = sin_[k * step];
                    const uint32_t p = start + k, q = p + half;
                    const double tr = re_[q] * wr - im_[q] * wi, ti = re_[q] * wi + im_[q] * wr;
                    re_[q] = re_[p] - tr;
                    im_[q] = im_[p] - ti;
                    re_[p] += tr;
                    im_[p] += ti;
                }
        }
        // X = A + jB with A, B real: A[k] = (X[k] + conj X[N-k]) / 2, B[k] = (X[k] - conj X[N-k]) / 2j.
        const double norm = 4.0 / kSize;  // a full-scale sine reads |A| = N / 4 through a Hann window
        for (uint32_t k = 0; k <= kSize / 2; ++k) {
            const uint32_t n = (kSize - k) & (kSize - 1);
            const double ar = 0.5 * (re_[k] + re_[n]), ai = 0.5 * (im_[k] - im_[n]);
            const double br = 0.5 * (im_[k] + im_[n]), bi = -0.5 * (re_[k] - re_[n]);
            powA_[k] = (ar * ar + ai * ai) * norm * norm;
            powB_[k] = (br * br + bi * bi) * norm * norm;
        }
        reduce(powA_, smoothA_, outA);
        reduce(powB_, smoothB_, outB);
    }

private:
    void reduce(const std::vector<double>& power, std::vector<float>& smooth, float* out) noexcept {
        const uint32_t last = kSize / 2;
        for (uint32_t j = 0; j < bins_; ++j) {
            double p = 0.0;
            if (from_[j] <= to_[j] && to_[j] <= last) {
                for (uint32_t k = from_[j]; k <= to_[j]; ++k) p = power[k] > p ? power[k] : p;
            } else {
                const double c = centre_[j];
                const uint32_t k0 = static_cast<uint32_t>(c);
                const double frac = c - k0;
                const double p0 = k0 <= last ? power[k0] : 0.0, p1 = k0 + 1 <= last ? power[k0 + 1] : 0.0;
                p = p0 + (p1 - p0) * frac;
            }
            double db = p > 1e-12 ? 10.0 * std::log10(p) : -120.0;
            db = db < -120.0 ? -120.0 : db;
            float& s = smooth[j];
            s += static_cast<float>((db - s) * (db > s ? 0.7 : 0.25));
            if (out) out[j] = s;
        }
    }

    double rate_ = 48000.0, lo_ = 20.0, hi_ = 20000.0;
    uint32_t bins_ = 128, pos_ = 0;
    std::vector<float> a_, b_, window_, smoothA_, smoothB_;
    std::vector<double> re_, im_, cos_, sin_, powA_, powB_, centre_;
    std::vector<uint32_t> rev_, from_, to_;
};

}  // namespace caw::lib
