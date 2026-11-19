// The EQ's FIR design kit (1.1.0): shared tables, the sliced FFT, the Match learner, its curve and its band fit.
#include "eq_design.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "caw/detmath.hpp"
#include "caw/library/eq.hpp"

namespace caw::fx::eqd {

namespace {

double besselI0(double x) noexcept {
    double sum = 1.0, term = 1.0;
    for (int k = 1; k < 60; ++k) {
        const double h = x / (2.0 * k);
        term *= h * h;
        sum += term;
        if (term < sum * 1e-17) break;
    }
    return sum;
}

double log2Of(double x) noexcept { return detLog(x) * 1.4426950408889634; }
double db10(double power) noexcept { return 4.3429448190325182 * detLog(power); }  // 10 log10

// The mean power of bins whose centres lie within +-1/12 octave of hz (at least the nearest bin).
double bandPower(const double* sums, uint32_t hops, double hz, double sampleRate) noexcept {
    if (hops == 0) return 0.0;
    const double binHz = sampleRate / SpectrumLearner::kN;
    const double r = 1.0594630943592953;  // 2^(1/12)
    int lo = static_cast<int>(std::ceil(hz / r / binHz)), hi = static_cast<int>(std::floor(hz * r / binHz));
    const int top = static_cast<int>(SpectrumLearner::kBins) - 1;
    if (hi < lo) lo = hi = static_cast<int>(std::lround(hz / binHz));
    lo = std::clamp(lo, 1, top);
    hi = std::clamp(hi, lo, top);
    double s = 0.0;
    for (int k = lo; k <= hi; ++k) s += sums[k];
    return s / (static_cast<double>(hi - lo + 1) * hops);
}

}  // namespace

const Tables& tables() noexcept {
    static const Tables* t = [] {
        auto* x = new Tables;
        for (uint32_t i = 0; i < kMaxFft / 2; ++i) {
            x->cos[i] = detCos(kTwoPi * i / kMaxFft);
            x->sin[i] = -detSin(kTwoPi * i / kMaxFft);
        }
        for (uint32_t i = 0; i < kMaxFft; ++i) {
            uint32_t r = 0;
            for (uint32_t k = 0; k < kMaxBits; ++k) r |= ((i >> k) & 1u) << (kMaxBits - 1 - k);
            x->rev[i] = r;
        }
        for (uint32_t k = 0; k <= kMaxFft / 2; ++k) {
            const double f = std::min(static_cast<double>(k) / kMaxFft, 0.4995);
            x->tan[k] = detTan(kPi * f);
        }
        const double i0 = besselI0(kKaiserBeta);
        for (int t = 0; t < 3; ++t) {
            const uint32_t n = 2048u << t;
            for (uint32_t i = 0; i < kMaxFft; ++i) {
                if (i >= n) {
                    x->kaiser[t][i] = 0.0f;
                    continue;
                }
                const double u = (static_cast<double>(i) - n / 2.0) / (n / 2.0);
                x->kaiser[t][i] = static_cast<float>(besselI0(kKaiserBeta * std::sqrt(std::max(0.0, 1.0 - u * u))) / i0);
            }
        }
        for (uint32_t i = 0; i < 4096; ++i) x->hann[i] = static_cast<float>(0.5 - 0.5 * detCos(kTwoPi * i / 4096.0));
        return x;
    }();
    return *t;
}

void StagedFft::start(double* re, double* im, uint32_t n, bool inverse) noexcept {
    re_ = re, im_ = im, n_ = n;
    uint32_t bits = 0;
    while ((1u << bits) < n) ++bits;
    shift_ = kMaxBits - bits;
    sign_ = inverse ? -1.0 : 1.0;
    idx_ = 0, half_ = 1, halfBits_ = 0;
    phase_ = n > 1 ? 0 : 2;
}

bool StagedFft::step(uint32_t budget) noexcept {
    const Tables& t = tables();
    while (budget > 0 && phase_ != 2) {
        if (phase_ == 0) {
            for (; idx_ < n_ && budget > 0; ++idx_, --budget) {
                const uint32_t r = t.rev[idx_] >> shift_;
                if (r > idx_) {
                    std::swap(re_[idx_], re_[r]);
                    std::swap(im_[idx_], im_[r]);
                }
            }
            if (idx_ == n_) phase_ = 1, idx_ = 0;
            continue;
        }
        const uint32_t stride = kMaxFft / (2 * half_), count = n_ / 2;
        for (; idx_ < count && budget > 0; ++idx_, --budget) {
            const uint32_t k = idx_ & (half_ - 1), p = ((idx_ >> halfBits_) << (halfBits_ + 1)) + k, q = p + half_;
            const double wr = t.cos[k * stride], wi = sign_ * t.sin[k * stride];
            const double tr = re_[q] * wr - im_[q] * wi, ti = re_[q] * wi + im_[q] * wr;
            re_[q] = re_[p] - tr;
            im_[q] = im_[p] - ti;
            re_[p] += tr;
            im_[p] += ti;
        }
        if (idx_ == count) {
            idx_ = 0;
            half_ <<= 1, ++halfBits_;
            if (half_ >= n_) phase_ = 2;
        }
    }
    return phase_ == 2;
}

bool SpectrumLearner::prepare() {
    try {
        for (int w = 0; w < 2; ++w) {
            ring_[w].assign(kN, 0.0f);
            sum_[w].assign(kBins, 0.0);
        }
        re_.assign(kN, 0.0);
        im_.assign(kN, 0.0);
    } catch (...) {
        return false;
    }
    hops_[0] = hops_[1] = 0;
    clear();
    return true;
}

void SpectrumLearner::clear() noexcept {
    for (auto& r : ring_) std::fill(r.begin(), r.end(), 0.0f);
    pos_ = since_ = filled_ = 0;
    busy_ = false;
}

void SpectrumLearner::forget(int which) noexcept {
    seq_.fetch_add(1, std::memory_order_acq_rel);
    std::fill(sum_[which].begin(), sum_[which].end(), 0.0);
    hops_[which] = 0;
    ++gen_;
    seq_.fetch_add(1, std::memory_order_acq_rel);
}

void SpectrumLearner::push(const float* refL, const float* refR, const float* inL, const float* inR, uint32_t n,
                           bool learnRef, bool learnIn) noexcept {
    learning_[0] = learnRef, learning_[1] = learnIn;
    if (!learnRef && !learnIn) {
        filled_ = 0;  // a new take starts from a full frame
        since_ = 0;
        return;
    }
    float* a = ring_[0].data();
    float* b = ring_[1].data();
    for (uint32_t i = 0; i < n; ++i) {
        const float r = refL ? 0.5f * (refL[i] + refR[i]) : 0.0f;
        a[pos_] = r == r ? r : 0.0f;
        const float x = 0.5f * (inL[i] + inR[i]);
        b[pos_] = x == x ? x : 0.0f;
        pos_ = (pos_ + 1) & (kN - 1);
    }
    since_ += n;
    filled_ = std::min<uint32_t>(kN, filled_ + n);
}

void SpectrumLearner::step() noexcept {
    if (busy_) {
        if (!fft_.step(2048)) return;
        // Both spectra from the one transform (the reference in the real part, the input in the imaginary part).
        seq_.fetch_add(1, std::memory_order_acq_rel);
        for (uint32_t k = 0; k < kBins; ++k) {
            const uint32_t m = (kN - k) & (kN - 1);
            const double ar = 0.5 * (re_[k] + re_[m]), ai = 0.5 * (im_[k] - im_[m]);
            const double br = 0.5 * (im_[k] + im_[m]), bi = -0.5 * (re_[k] - re_[m]);
            if (loud_[0]) sum_[0][k] += ar * ar + ai * ai;
            if (loud_[1]) sum_[1][k] += br * br + bi * bi;
        }
        for (int w = 0; w < 2; ++w)
            if (loud_[w]) ++hops_[w];
        ++gen_;
        seq_.fetch_add(1, std::memory_order_acq_rel);
        busy_ = false;
        return;
    }
    if (since_ < kHop || filled_ < kN || !(learning_[0] || learning_[1])) return;
    since_ = 0;
    const float* hann = tables().hann;
    double e[2] = {0.0, 0.0};
    for (uint32_t i = 0; i < kN; ++i) {
        const uint32_t at = (pos_ + i) & (kN - 1);
        const double a = ring_[0][at], b = ring_[1][at];
        e[0] += a * a, e[1] += b * b;
        re_[i] = a * hann[i];
        im_[i] = b * hann[i];
    }
    // A frame quieter than -80 dBFS RMS (silence, a gap) is not learned.
    for (int w = 0; w < 2; ++w) loud_[w] = learning_[w] && e[w] > kN * 1e-8;
    if (!loud_[0] && !loud_[1]) return;
    fft_.start(re_.data(), im_.data(), kN, false);
    busy_ = true;
}

namespace {
constexpr uint32_t kStateMagic = 0x4D574143u;  // "CAWM"
void put32(uint8_t* p, uint32_t v) noexcept { for (int k = 0; k < 4; ++k) p[k] = static_cast<uint8_t>(v >> (8 * k)); }
uint32_t get32(const uint8_t* p) noexcept { return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24); }
}  // namespace

bool SpectrumLearner::save(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept {
    written = 0;
    if (hops_[0] == 0 && hops_[1] == 0) return true;  // nothing learned: no state
    if (!dst || capacity < kStateBytes) return false;
    for (int attempt = 0; attempt < 64; ++attempt) {
        const uint32_t before = seq_.load(std::memory_order_acquire);
        if (before & 1u) continue;
        put32(dst, kStateMagic);
        put32(dst + 4, kBins);
        put32(dst + 8, hops_[0]);
        put32(dst + 12, hops_[1]);
        uint8_t* p = dst + 16;
        for (int w = 0; w < 2; ++w)
            for (uint32_t k = 0; k < kBins; ++k, p += 4) {
                const float v = hops_[w] ? static_cast<float>(sum_[w][k] / hops_[w]) : 0.0f;
                std::memcpy(p, &v, 4);
            }
        if (seq_.load(std::memory_order_acquire) == before) {
            written = kStateBytes;
            return true;
        }
    }
    return false;
}

bool SpectrumLearner::load(const uint8_t* src, uint32_t size) noexcept {
    if (size == 0) {
        forget(0), forget(1);
        return true;
    }
    if (!src || size != kStateBytes || get32(src) != kStateMagic || get32(src + 4) != kBins) return false;
    const uint32_t hops[2] = {get32(src + 8), get32(src + 12)};
    if (hops[0] > (1u << 30) || hops[1] > (1u << 30)) return false;
    const uint8_t* p = src + 16;
    for (int w = 0; w < 2; ++w)
        for (uint32_t k = 0; k < kBins; ++k, p += 4) {
            float v;
            std::memcpy(&v, p, 4);
            if (!std::isfinite(v) || v < 0.0f) v = 0.0f;
            sum_[w][k] = static_cast<double>(std::min(v, 1e12f)) * hops[w];
        }
    hops_[0] = hops[0], hops_[1] = hops[1];
    ++gen_;
    return true;
}

double gridHz(uint32_t j) noexcept { return 20.0 * detPow(2.0, static_cast<double>(j) / 24.0); }

double curveAt(const double* curveDb, double hz) noexcept {
    if (!(hz > 20.0)) return curveDb[0];
    const double x = log2Of(hz / 20.0) * 24.0;
    if (x >= kGrid - 1) return curveDb[kGrid - 1];
    const uint32_t j = static_cast<uint32_t>(x);
    const double f = x - j;
    return curveDb[j] + (curveDb[j + 1] - curveDb[j]) * f;
}

void spectrumOnGrid(const SpectrumLearner& l, int which, double sampleRate, double* db) noexcept {
    // 0 dB: a full-scale sine (|X| = N/4 through the Hann window).
    const double norm = 16.0 / (static_cast<double>(SpectrumLearner::kN) * SpectrumLearner::kN);
    const uint32_t hops = l.frames(which);
    for (uint32_t j = 0; j < kGrid; ++j) {
        const double hz = gridHz(j);
        const double p = hz < 0.49 * sampleRate ? bandPower(l.sums(which), hops, hz, sampleRate) * norm : 0.0;
        db[j] = p > 1e-12 ? std::max(-120.0, db10(p)) : -120.0;
    }
}

void matchCurve(const SpectrumLearner& l, double sampleRate, double amount, double smoothing, double lowHz, double highHz,
                double* curveDb) noexcept {
    double d[kGrid];
    const bool any = l.any();
    for (uint32_t j = 0; j < kGrid; ++j) {
        const double hz = gridHz(j);
        double v = 0.0;
        if (any && hz < 0.49 * sampleRate) {
            const double r = bandPower(l.sums(SpectrumLearner::kReference), l.frames(SpectrumLearner::kReference), hz, sampleRate);
            const double x = bandPower(l.sums(SpectrumLearner::kInput), l.frames(SpectrumLearner::kInput), hz, sampleRate);
            if (r > 1e-14 && x > 1e-14) v = db10(r / x);
        }
        d[j] = v;
    }
    const int radius = static_cast<int>(std::lround(std::clamp(smoothing, 0.0, 1.0) * 24.0));
    amount = std::clamp(amount, 0.0, 1.0);
    lowHz = std::clamp(lowHz, 20.0, 20000.0);
    highHz = std::clamp(highHz, lowHz, 20000.0);
    for (uint32_t j = 0; j < kGrid; ++j) {
        double s = 0.0;
        int count = 0;
        for (int k = static_cast<int>(j) - radius; k <= static_cast<int>(j) + radius; ++k) {
            if (k < 0 || k >= static_cast<int>(kGrid)) continue;
            s += d[k], ++count;
        }
        double v = std::clamp(s / count, -12.0, 12.0) * amount;
        const double hz = gridHz(j);
        double outside = 0.0;  // octaves outside the limits
        if (hz < lowHz) outside = log2Of(lowHz / hz);
        if (hz > highHz) outside = log2Of(hz / highHz);
        v *= std::max(0.0, 1.0 - 3.0 * outside);
        curveDb[j] = v;
    }
}

FitBand fitOneBand(double* residual, double sampleRate) noexcept {
    FitBand b;
    uint32_t at = 0;
    for (uint32_t j = 1; j < kGrid; ++j)
        if (std::fabs(residual[j]) > std::fabs(residual[at])) at = j;
    const double g = residual[at];
    if (std::fabs(g) < 0.25) return b;  // nothing worth a band
    uint32_t lo = at, hi = at;
    while (lo > 0 && residual[lo - 1] * g > 0.5 * g * g) --lo;
    while (hi + 1 < kGrid && residual[hi + 1] * g > 0.5 * g * g) ++hi;
    const double octaves = std::max(1.0 / 12.0, static_cast<double>(hi - lo + 1) / 24.0);
    const double r = detPow(2.0, octaves);
    b.freq = gridHz(at);
    b.gain = std::clamp(g, -24.0, 24.0);
    b.q = std::clamp(std::sqrt(r) / (r - 1.0), 0.3, 10.0);
    lib::EqFilter bell;
    bell.set(lib::EqType::Bell, b.freq, b.gain, b.q, sampleRate);
    for (uint32_t j = 0; j < kGrid; ++j) {
        const double hz = std::min(gridHz(j), 0.49 * sampleRate);
        residual[j] -= db10(bell.magnitude2(detTan(kPi * hz / sampleRate)));
    }
    return b;
}

}  // namespace caw::fx::eqd
