// Offline signal measurements for the component testing suite: levels, FFT spectra, THD+N, IR length, latency.
#include "analysis.h"

#include <algorithm>
#include <cmath>
#include <limits>

namespace caw::analysis {

namespace {

constexpr double kPi = 3.14159265358979323846;

double sample(const float* x, std::size_t i) noexcept {
    const float v = x[i];
    return std::isfinite(v) ? static_cast<double>(v) : 0.0;
}

// Solves the 3x3 system m * v = rhs by Gaussian elimination with partial pivoting. False if singular.
bool solve3(double m[3][3], double rhs[3], double v[3]) noexcept {
    for (int c = 0; c < 3; ++c) {
        int p = c;
        for (int r = c + 1; r < 3; ++r)
            if (std::fabs(m[r][c]) > std::fabs(m[p][c])) p = r;
        if (std::fabs(m[p][c]) < 1e-12) return false;
        if (p != c) {
            for (int k = 0; k < 3; ++k) std::swap(m[p][k], m[c][k]);
            std::swap(rhs[p], rhs[c]);
        }
        for (int r = c + 1; r < 3; ++r) {
            const double f = m[r][c] / m[c][c];
            for (int k = c; k < 3; ++k) m[r][k] -= f * m[c][k];
            rhs[r] -= f * rhs[c];
        }
    }
    for (int c = 2; c >= 0; --c) {
        double s = rhs[c];
        for (int k = c + 1; k < 3; ++k) s -= m[c][k] * v[k];
        v[c] = s / m[c][c];
    }
    return true;
}

// Least-squares a * sin(w n) + b * cos(w n) + d over x; subtracts the fit from x when `remove`.
bool fitSine(std::vector<double>& x, double w, double& a, double& b, double& d, bool remove) {
    double m[3][3] = {}, rhs[3] = {};
    const std::size_t n = x.size();
    for (std::size_t i = 0; i < n; ++i) {
        const double s = std::sin(w * static_cast<double>(i)), c = std::cos(w * static_cast<double>(i));
        const double basis[3] = {s, c, 1.0};
        for (int r = 0; r < 3; ++r) {
            for (int k = 0; k < 3; ++k) m[r][k] += basis[r] * basis[k];
            rhs[r] += basis[r] * x[i];
        }
    }
    double v[3] = {};
    if (!solve3(m, rhs, v)) return false;
    a = v[0];
    b = v[1];
    d = v[2];
    if (remove)
        for (std::size_t i = 0; i < n; ++i)
            x[i] -= a * std::sin(w * static_cast<double>(i)) + b * std::cos(w * static_cast<double>(i)) + d;
    return true;
}

// Band centres from 20 Hz, spaced 1/bandsPerOctave octave, below Nyquist; with each band's edges.
struct BandEdge {
    double centre, lo, hi;
};
std::vector<BandEdge> bands(double sampleRate, double bandsPerOctave) {
    std::vector<BandEdge> out;
    const double bpo = std::clamp(bandsPerOctave, 1.0, 48.0);
    const double half = std::pow(2.0, 0.5 / bpo), nyquist = sampleRate / 2.0;
    for (int k = 0;; ++k) {
        const double f = 20.0 * std::pow(2.0, k / bpo);
        if (f >= nyquist) break;
        out.push_back({f, f / half, std::min(f * half, nyquist)});
    }
    return out;
}

}  // namespace

double toDb(double linear) noexcept {
    return linear > 0.0 ? 20.0 * std::log10(linear) : -std::numeric_limits<double>::infinity();
}

std::size_t nextPowerOfTwo(std::size_t n) noexcept {
    std::size_t p = 1;
    while (p < n) p <<= 1;
    return p;
}

void fft(std::vector<std::complex<double>>& data, bool inverse) {
    const std::size_t n = data.size();
    if (n < 2) return;
    for (std::size_t i = 1, j = 0; i < n; ++i) {
        std::size_t bit = n >> 1;
        for (; j & bit; bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) std::swap(data[i], data[j]);
    }
    // Twiddles computed directly per index (not by recurrence), so large sizes keep their accuracy.
    std::vector<std::complex<double>> tw(n / 2);
    const double sign = inverse ? 1.0 : -1.0;
    for (std::size_t k = 0; k < n / 2; ++k) {
        const double a = sign * 2.0 * kPi * static_cast<double>(k) / static_cast<double>(n);
        tw[k] = {std::cos(a), std::sin(a)};
    }
    for (std::size_t len = 2; len <= n; len <<= 1) {
        const std::size_t step = n / len, halfLen = len / 2;
        for (std::size_t i = 0; i < n; i += len)
            for (std::size_t k = 0; k < halfLen; ++k) {
                const std::complex<double> u = data[i + k], v = data[i + k + halfLen] * tw[k * step];
                data[i + k] = u + v;
                data[i + k + halfLen] = u - v;
            }
    }
    if (inverse)
        for (auto& v : data) v /= static_cast<double>(n);
}

Levels levels(const float* x, std::size_t n) noexcept {
    Levels l;
    double sum = 0, sumSq = 0;
    for (std::size_t i = 0; i < n; ++i) {
        const float v = x[i];
        if (std::isnan(v)) { ++l.nan; continue; }
        if (std::isinf(v)) { ++l.inf; continue; }
        if (std::fpclassify(v) == FP_SUBNORMAL) ++l.denormal;
        const double d = v;
        l.peak = std::max(l.peak, std::fabs(d));
        sum += d;
        sumSq += d * d;
    }
    if (n > 0) {
        l.dc = sum / static_cast<double>(n);
        l.rms = std::sqrt(sumSq / static_cast<double>(n));
    }
    l.peakDb = toDb(l.peak);
    l.rmsDb = toDb(l.rms);
    l.crestDb = l.rms > 0 ? l.peakDb - l.rmsDb : 0.0;
    return l;
}

Stereo stereo(const float* l, const float* r, std::size_t n) noexcept {
    Stereo s;
    double ll = 0, rr = 0, lr = 0, mm = 0, ss = 0;
    for (std::size_t i = 0; i < n; ++i) {
        const double a = sample(l, i), b = sample(r, i);
        ll += a * a;
        rr += b * b;
        lr += a * b;
        const double m = (a + b) / 2, d = (a - b) / 2;
        mm += m * m;
        ss += d * d;
    }
    if (ll > 0 && rr > 0) s.correlation = std::clamp(lr / std::sqrt(ll * rr), -1.0, 1.0);
    const double mid = std::sqrt(mm), side = std::sqrt(ss);
    if (mid + side > 0) s.width = side / (mid + side);
    return s;
}

SineDistortion sineDistortion(const float* x, std::size_t n, double frequency, double sampleRate, int maxHarmonic) {
    SineDistortion out;
    if (!(frequency > 0) || !(sampleRate > 0) || frequency >= sampleRate / 2) return out;
    // A whole number of cycles, so the harmonics are as close to orthogonal as the frames allow.
    const double period = sampleRate / frequency;
    const std::size_t cycles = static_cast<std::size_t>(static_cast<double>(n) / period);
    if (cycles < 1) return out;
    const std::size_t m = std::max<std::size_t>(1, static_cast<std::size_t>(std::llround(cycles * period)));
    std::vector<double> residual(std::min(m, n));
    for (std::size_t i = 0; i < residual.size(); ++i) residual[i] = sample(x, i);
    const double w = 2.0 * kPi * frequency / sampleRate;
    double a = 0, b = 0, d = 0;
    if (!fitSine(residual, w, a, b, d, true)) return out;
    out.fundamental = std::sqrt(a * a + b * b);
    if (out.fundamental <= 0) return out;
    double sumSq = 0;
    for (double v : residual) sumSq += v * v;
    const double residualRms = std::sqrt(sumSq / static_cast<double>(residual.size()));
    out.thdN = residualRms / (out.fundamental / std::sqrt(2.0));
    double harmonics = 0;
    for (int k = 2; k <= maxHarmonic && k * frequency < sampleRate / 2; ++k) {
        std::vector<double> copy = residual;
        double ha = 0, hb = 0, hd = 0;
        if (fitSine(copy, w * k, ha, hb, hd, false)) harmonics += ha * ha + hb * hb;
    }
    out.thd = std::sqrt(harmonics) / out.fundamental;
    out.valid = true;
    return out;
}

std::size_t endAbove(const float* x, std::size_t n, double threshold) noexcept {
    for (std::size_t i = n; i > 0; --i)
        if (std::fabs(sample(x, i - 1)) > threshold) return i;
    return 0;
}

int64_t findLag(const float* ref, const float* sig, std::size_t n, std::size_t maxLag) {
    if (n == 0) return -1;
    double er = 0, es = 0;
    for (std::size_t i = 0; i < n; ++i) {
        er += sample(ref, i) * sample(ref, i);
        es += sample(sig, i) * sample(sig, i);
    }
    if (er <= 0 || es <= 0) return -1;
    const std::size_t size = nextPowerOfTwo(2 * n);
    std::vector<std::complex<double>> a(size), b(size);
    for (std::size_t i = 0; i < n; ++i) {
        a[i] = sample(ref, i);
        b[i] = sample(sig, i);
    }
    fft(a, false);
    fft(b, false);
    for (std::size_t i = 0; i < size; ++i) a[i] = std::conj(a[i]) * b[i];
    fft(a, true);  // a[l] = sum ref[i] * sig[i + l]
    const std::size_t last = std::min(maxLag, n - 1);
    std::size_t best = 0;
    double bestValue = -1;
    for (std::size_t l = 0; l <= last; ++l) {
        const double v = std::fabs(a[l].real());
        if (v > bestValue * (1.0 + 1e-9)) {  // ties keep the earliest lag
            bestValue = v;
            best = l;
        }
    }
    return static_cast<int64_t>(best);
}

std::vector<Band> spectrumBands(const float* x, std::size_t n, std::size_t fftSize, double sampleRate,
                                double bandsPerOctave) {
    const std::size_t size = std::max<std::size_t>(2, nextPowerOfTwo(fftSize));
    std::vector<std::complex<double>> data(size);
    double windowSum = 0;
    for (std::size_t i = 0; i < size; ++i) {
        const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * static_cast<double>(i) / static_cast<double>(size));
        windowSum += w;
        data[i] = i < n ? sample(x, i) * w : 0.0;
    }
    fft(data, false);
    const double scale = 2.0 / windowSum;
    const double binHz = sampleRate / static_cast<double>(size);
    std::vector<Band> out;
    for (const BandEdge& e : bands(sampleRate, bandsPerOctave)) {
        double best = 0;
        bool any = false;
        for (std::size_t k = static_cast<std::size_t>(std::ceil(e.lo / binHz)); k < size / 2 && k * binHz < e.hi; ++k) {
            best = std::max(best, std::abs(data[k]) * scale);
            any = true;
        }
        if (!any) {
            const std::size_t k = std::min(size / 2 - 1, static_cast<std::size_t>(std::llround(e.centre / binHz)));
            best = std::abs(data[k]) * scale;
        }
        out.push_back({e.centre, toDb(best)});
    }
    return out;
}

std::vector<Band> frequencyResponse(const float* in, const float* out, std::size_t n, double sampleRate,
                                    double bandsPerOctave) {
    std::vector<Band> result;
    if (n == 0) return result;
    const std::size_t size = std::max<std::size_t>(2, nextPowerOfTwo(n));
    std::vector<std::complex<double>> x(size), y(size);
    for (std::size_t i = 0; i < n; ++i) {
        x[i] = sample(in, i);
        y[i] = sample(out, i);
    }
    fft(x, false);
    fft(y, false);
    const double binHz = sampleRate / static_cast<double>(size);
    struct Power {
        double centre, in, out;
    };
    std::vector<Power> powers;
    double loudest = 0;
    for (const BandEdge& e : bands(sampleRate, bandsPerOctave)) {
        double pi = 0, po = 0;
        bool any = false;
        for (std::size_t k = static_cast<std::size_t>(std::ceil(e.lo / binHz)); k < size / 2 && k * binHz < e.hi; ++k) {
            pi += std::norm(x[k]);
            po += std::norm(y[k]);
            any = true;
        }
        if (!any) continue;
        powers.push_back({e.centre, pi, po});
        loudest = std::max(loudest, pi);
    }
    if (loudest <= 0) return result;
    for (const Power& p : powers) {
        if (p.in < loudest * 1e-6) continue;
        result.push_back({p.centre, p.out > 0 ? 10.0 * std::log10(p.out / p.in) : -std::numeric_limits<double>::infinity()});
    }
    return result;
}

}  // namespace caw::analysis
