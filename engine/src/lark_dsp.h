// Lark's shared DSP (org.caw.pitchfix and the clip editor): scales and target notes, the YIN detector on a decimated copy, its full-rate refinement, and the Hann table TD-PSOLA grains read.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string_view>
#include <vector>

#include "caw/detmath.hpp"

// Original code (C.A.W. is Apache-2.0), from the papers only:
// - YIN: A. de Cheveigné and H. Kawahara, "YIN, a fundamental frequency estimator for speech and music", JASA
//   111(4), 2002 (steps 2-5: the difference function, its cumulative mean normalised form d', the absolute
//   threshold and parabolic interpolation). It runs on a copy low-passed (two biquads at 3 kHz) and decimated to
//   about 12 kHz, an analysis every 64 decimated samples (5.3 ms at 48 kHz), its window the newest samples (compared
//   with those a lag earlier, so the estimate is as recent as it can be). The difference function is computed
//   directly and stops at the first dip under the threshold once it rises again (a voice's dip comes early, so a
//   voice costs a fraction of the full scan; the design's FFT form costs the same on every hop). The lag found is
//   then refined on the full-rate signal: the raw difference at three lags around it and a parabola, so the pitch
//   is within a few cents, not the decimated grid's.
// - The clip editor's candidates follow pYIN's idea (M. Mauch and S. Dixon, ICASSP 2014; ideas only, its
//   reference plug-in is GPL): every dip of d' is a candidate, weighted by how many thresholds of a prior would pick
//   it first; an HMM chooses among them (lark_editor.cpp).
// - TD-PSOLA: Moulines and Charpentier, Speech Communication 9(5-6), 1990: two-period Hann grains at pitch marks,
//   laid at the target period. The window table is shared by every instance (warmTables, at registration).
// Monophonic and time-domain throughout: no spectrogram, no spectral separation, no event-to-note association
// (the design's patent notes: Celemony's US8022286B2 claims a polyphonic STFT method).

namespace caw::lark {

constexpr double kPi = 3.14159265358979323846;

// --- Scales and target notes -----------------------------------------------------------------------------------------

inline constexpr std::string_view kScaleNames[] = {"Chromatic",  "Major",      "Minor",      "Harmonic minor", "Melodic minor",
                                                   "Dorian",     "Phrygian",   "Lydian",     "Mixolydian",     "Major pentatonic",
                                                   "Minor pentatonic", "Blues", "Custom"};
inline constexpr int kScaleCount = 13;
inline constexpr int kCustomScale = 12;
// Bit k: the note k semitones above the key is in the scale.
inline constexpr uint16_t kScaleMasks[kScaleCount] = {
    0xFFF,
    (1 << 0) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11),   // major
    (1 << 0) | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 8) | (1 << 10),   // natural minor
    (1 << 0) | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 8) | (1 << 11),   // harmonic minor
    (1 << 0) | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 11),   // melodic minor
    (1 << 0) | (1 << 2) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 10),   // dorian
    (1 << 0) | (1 << 1) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 8) | (1 << 10),   // phrygian
    (1 << 0) | (1 << 2) | (1 << 4) | (1 << 6) | (1 << 7) | (1 << 9) | (1 << 11),   // lydian
    (1 << 0) | (1 << 2) | (1 << 4) | (1 << 5) | (1 << 7) | (1 << 9) | (1 << 10),   // mixolydian
    (1 << 0) | (1 << 2) | (1 << 4) | (1 << 7) | (1 << 9),                          // major pentatonic
    (1 << 0) | (1 << 3) | (1 << 5) | (1 << 7) | (1 << 10),                         // minor pentatonic
    (1 << 0) | (1 << 3) | (1 << 5) | (1 << 6) | (1 << 7) | (1 << 10),              // blues
    0,                                                                             // custom: the note switches
};

// The pitch classes allowed (bit pc, C = 0) for `scale` in `key` (0 = C); `custom` holds pitch classes already.
inline uint16_t pitchClasses(int scale, int key, uint16_t custom) noexcept {
    scale = std::clamp(scale, 0, kScaleCount - 1);
    key = ((key % 12) + 12) % 12;
    if (scale == kCustomScale) return static_cast<uint16_t>(custom & 0xFFF);
    uint16_t out = 0;
    for (int k = 0; k < 12; ++k)
        if (kScaleMasks[scale] & (1 << k)) out = static_cast<uint16_t>(out | (1 << ((k + key) % 12)));
    return out;
}

// The allowed note nearest `midi` (ties go down); `midi` itself rounded when no class is allowed.
inline int nearestNote(double midi, uint16_t classes) noexcept {
    const int centre = static_cast<int>(std::floor(midi + 0.5));
    if ((classes & 0xFFF) == 0) return centre;
    int best = centre;
    double bestDist = 1e9;
    for (int d = -6; d <= 6; ++d) {
        const int n = centre + d;
        if (!(classes & (1 << (((n % 12) + 12) % 12)))) continue;
        const double dist = std::fabs(midi - n);
        if (dist < bestDist - 1e-12) bestDist = dist, best = n;
    }
    return best;
}

// The target with hysteresis: `current` (or none, -1000) is kept while it is allowed and within `hyst` semitones
// of being as near as the nearest.
inline int chooseTarget(double midi, uint16_t classes, int current, double hyst = 0.2) noexcept {
    const int best = nearestNote(midi, classes);
    if (current > -1000 && current != best && ((classes & 0xFFF) == 0 || (classes & (1 << (((current % 12) + 12) % 12)))) &&
        std::fabs(midi - current) < std::fabs(midi - best) + hyst)
        return current;
    return best;
}

inline double hzToMidi(double hz) noexcept { return 69.0 + 12.0 * detLog(hz / 440.0) / 0.69314718055994530942; }
inline double midiToHz(double m) noexcept { return 440.0 * detPow(2.0, (m - 69.0) / 12.0); }

// --- The grains' window ----------------------------------------------------------------------------------------------

inline constexpr uint32_t kHannSize = 1024;  // a periodic Hann over [0, 1024), one guard point
struct HannTable {
    float w[kHannSize + 2] = {};
};
inline HannTable& hannStore() noexcept {
    static HannTable t;
    return t;
}
// Builds the shared table (registration calls it; idempotent, so tests and tools may call it too).
inline void warmTables() noexcept {
    HannTable& t = hannStore();
    if (t.w[kHannSize / 2] == 1.0f) return;
    for (uint32_t i = 0; i <= kHannSize / 2; ++i) {
        const float v = static_cast<float>(0.5 - 0.5 * detCos(2.0 * kPi * i / kHannSize));
        t.w[i] = v;
        if (i > 0 && i < kHannSize / 2) t.w[kHannSize - i] = v;
    }
    t.w[kHannSize / 2] = 1.0f;
    t.w[kHannSize] = t.w[kHannSize + 1] = 0.0f;
}
// The window at x = (n - centre) / half in [-1, 1): 0 at -1, 1 at 0.
inline double hann(double x) noexcept {
    const double pos = (x + 1.0) * (kHannSize / 2);
    if (!(pos >= 0.0) || pos >= kHannSize) return 0.0;
    const uint32_t i = static_cast<uint32_t>(pos);
    const double f = pos - i;
    const float* w = hannStore().w;
    return w[i] + f * (w[i + 1] - w[i]);
}

// --- YIN -------------------------------------------------------------------------------------------------------------

inline constexpr uint32_t kHop = 64;        // decimated samples between analyses
inline constexpr uint32_t kMaxWindow = 256;  // decimated window
inline constexpr uint32_t kMaxLag = 400;     // decimated lags (12 kHz / 30 Hz)
inline constexpr uint32_t kDecRing = 1024;   // decimated samples kept (a power of two, > window + lags)

// The decimation for a rate: about 12 kHz.
inline uint32_t decimationFor(double sr) noexcept { return static_cast<uint32_t>(std::max(1.0, std::floor(sr / 12000.0 + 0.5))); }

// A biquad low-pass (Butterworth sections) in double, transposed direct form II.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    void lowpass(double hz, double sr, double q) noexcept {
        const double k = detTan(kPi * std::min(hz, 0.45 * sr) / sr), n = 1.0 / (1.0 + k / q + k * k);
        b0 = k * k * n, b1 = 2.0 * b0, b2 = b0;
        a1 = 2.0 * (k * k - 1.0) * n, a2 = (1.0 - k / q + k * k) * n;
    }
    double run(double x) noexcept {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void clear() noexcept { z1 = z2 = 0.0; }
};

// d'(tau) for tau = 1..maxLag of x[0 .. window + maxLag] into dn (dn[0] = 1). With `stopBelow` > 0 it stops once a
// dip under that threshold has risen again and returns the last tau computed; otherwise it computes them all.
inline uint32_t cmnd(const float* x, uint32_t window, uint32_t minLag, uint32_t maxLag, float* dn, double stopBelow) noexcept {
    dn[0] = 1.0f;
    double running = 0.0;
    uint32_t found = 0;
    for (uint32_t tau = 1; tau <= maxLag; ++tau) {
        float s0 = 0, s1 = 0, s2 = 0, s3 = 0;  // four sums: independent chains, a fixed order
        const float* a = x;
        const float* b = x + tau;
        uint32_t j = 0;
        for (; j + 4 <= window; j += 4) {
            const float e0 = a[j] - b[j], e1 = a[j + 1] - b[j + 1], e2 = a[j + 2] - b[j + 2], e3 = a[j + 3] - b[j + 3];
            s0 += e0 * e0, s1 += e1 * e1, s2 += e2 * e2, s3 += e3 * e3;
        }
        for (; j < window; ++j) {
            const float e = a[j] - b[j];
            s0 += e * e;
        }
        const double d = static_cast<double>(s0) + s1 + s2 + s3;
        running += d;
        dn[tau] = running > 0.0 ? static_cast<float>(d * tau / running) : 1.0f;
        if (stopBelow > 0.0 && tau >= minLag) {
            if (!found && dn[tau] < stopBelow) found = tau;
            else if (found && dn[tau] >= dn[tau - 1]) return tau;
        }
    }
    return maxLag;
}

// The parabola through d'(tau - 1), d'(tau), d'(tau + 1): the dip's lag, within half a step.
inline double parabolic(const float* dn, uint32_t tau, uint32_t last) noexcept {
    if (tau < 1 || tau + 1 > last) return tau;
    const double l = dn[tau - 1], c = dn[tau], r = dn[tau + 1], den = l - 2.0 * c + r;
    return den > 0.0 ? tau + std::clamp(0.5 * (l - r) / den, -0.5, 0.5) : static_cast<double>(tau);
}

// The raw difference of y over `window` samples at lag `lag` (y holds window + lag samples from y[0]).
inline double rawDiff(const float* y, uint32_t window, uint32_t lag) noexcept {
    float s0 = 0, s1 = 0, s2 = 0, s3 = 0;
    uint32_t j = 0;
    for (; j + 4 <= window; j += 4) {
        const float e0 = y[j] - y[j + lag], e1 = y[j + 1] - y[j + 1 + lag], e2 = y[j + 2] - y[j + 2 + lag], e3 = y[j + 3] - y[j + 3 + lag];
        s0 += e0 * e0, s1 += e1 * e1, s2 += e2 * e2, s3 += e3 * e3;
    }
    for (; j < window; ++j) {
        const float e = y[j] - y[j + lag];
        s0 += e * e;
    }
    return static_cast<double>(s0) + s1 + s2 + s3;
}

// The refinement's window for a full-rate lag: two periods, 192..1536 samples.
inline uint32_t refineWindow(double lag) noexcept {
    return static_cast<uint32_t>(std::clamp(2.0 * lag, 192.0, 1536.0));
}

// The full-rate lag near `lag0`: the raw difference at the nearest lag and its neighbours (walking at most 3 steps
// downhill), then a parabola. `at(j)` gives full-rate sample j of a span whose newest is j = span - 1; `span` must
// cover refineWindow + lag + 4.
template <class At>
double refineLag(At&& at, uint32_t span, double lag0, float* scratch) noexcept {
    const uint32_t window = refineWindow(lag0);
    int64_t li = static_cast<int64_t>(std::floor(lag0 + 0.5));
    auto diff = [&](int64_t lag) -> double {
        if (lag < 2 || static_cast<uint64_t>(window + lag + 1) > span) return 1e300;
        const uint32_t n = window + static_cast<uint32_t>(lag);
        const uint32_t start = span - n;
        for (uint32_t j = 0; j < n; ++j) scratch[j] = at(start + j);
        return rawDiff(scratch, window, static_cast<uint32_t>(lag));
    };
    double c = diff(li), l = diff(li - 1), r = diff(li + 1);
    for (int step = 0; step < 3 && !(c <= l && c <= r); ++step) {
        if (l < c) r = c, c = l, --li, l = diff(li - 1);
        else l = c, c = r, ++li, r = diff(li + 1);
    }
    if (!(c <= l && c <= r) || l >= 1e299 || r >= 1e299) return lag0;
    const double den = l - 2.0 * c + r;
    return den > 0.0 ? li + std::clamp(0.5 * (l - r) / den, -0.5, 0.5) : static_cast<double>(li);
}

// The live detector: push() each full-rate sample (the mid); every hop it analyses the newest window and says so.
class Detector {
public:
    struct Result {
        bool voiced = false;
        double hz = 0.0, confidence = 0.0, rms = 0.0;
        double lag = 0.0;  // the period in frames; the analysis is centred about 1.5 periods before the newest sample
    };

    // Control thread: allocates the full-rate ring for `sr` (any lowest pitch down to 50 Hz).
    bool prepare(double sr) noexcept {
        sr_ = sr;
        decim_ = decimationFor(sr);
        fsd_ = sr / decim_;
        uint32_t need = 1536 + static_cast<uint32_t>(sr / 50.0) + 16, n = 1;
        while (n < need) n <<= 1;
        try {
            full_.assign(n, 0.0f);
            scratch_.assign(1536 + static_cast<size_t>(sr / 50.0) + 16, 0.0f);
        } catch (...) {
            return false;
        }
        fullMask_ = n - 1;
        aa1_.lowpass(3000.0, sr, 0.5411961), aa2_.lowpass(3000.0, sr, 1.3065630);
        configure(60.0, 1000.0, false, 0.15);
        clear();
        return true;
    }
    // Audio thread: the pitch range, the window (monitor: 10.7 ms, else 16 ms) and the threshold.
    void configure(double lowHz, double highHz, bool monitor, double threshold) noexcept {
        window_ = std::min<uint32_t>(kMaxWindow, static_cast<uint32_t>((monitor ? 0.0107 : 0.016) * fsd_ + 0.5));
        window_ &= ~3u;
        maxLag_ = std::min<uint32_t>(kMaxLag, static_cast<uint32_t>(std::ceil(fsd_ / std::max(30.0, lowHz))));
        minLag_ = std::max<uint32_t>(2, static_cast<uint32_t>(std::floor(fsd_ / std::max(highHz, lowHz * 1.5))));
        lowHz_ = lowHz, highHz_ = highHz;
        threshold_ = threshold;
    }
    void clear() noexcept {
        std::fill(full_.begin(), full_.end(), 0.0f);
        std::fill(dec_, dec_ + kDecRing, 0.0f);
        aa1_.clear(), aa2_.clear();
        fullPos_ = decPos_ = 0;
        count_ = hopCount_ = 0;
        result_ = {};
    }
    // One full-rate sample; true when an analysis finished on it (result()).
    bool push(float x) noexcept {
        full_[fullPos_] = x;
        fullPos_ = (fullPos_ + 1) & fullMask_;
        const double y = aa2_.run(aa1_.run(x));
        if (++count_ < decim_) return false;
        count_ = 0;
        dec_[decPos_] = static_cast<float>(y);
        decPos_ = (decPos_ + 1) & (kDecRing - 1);
        if (++hopCount_ < kHop) return false;
        hopCount_ = 0;
        analyse();
        return true;
    }
    const Result& result() const noexcept { return result_; }
    uint32_t hopFrames() const noexcept { return kHop * decim_; }
    double hopSeconds() const noexcept { return kHop * decim_ / sr_; }

private:
    void analyse() noexcept {
        const uint32_t need = window_ + maxLag_ + 2;
        double energy = 0.0;
        for (uint32_t i = 0; i < need; ++i) {
            // Newest first: the window is the newest samples, compared with the ones a lag before them.
            x_[i] = dec_[(decPos_ + kDecRing - 1 - i) & (kDecRing - 1)];
            if (i < window_) energy += static_cast<double>(x_[i]) * x_[i];
        }
        result_.rms = std::sqrt(energy / window_);
        result_.voiced = false;
        result_.confidence = 0.0;
        if (!(energy / window_ > 1e-7)) return;  // under about -70 dBFS (or not finite)
        const uint32_t last = cmnd(x_, window_, minLag_, maxLag_ + 1, dn_, threshold_);
        uint32_t best = 0;
        for (uint32_t t = minLag_; t <= std::min(last, maxLag_); ++t)
            if (dn_[t] < threshold_) {
                while (t + 1 <= std::min(last, maxLag_) && dn_[t + 1] < dn_[t]) ++t;
                best = t;
                break;
            }
        if (!best) return;
        const double tau = parabolic(dn_, best, last);
        const uint32_t span = static_cast<uint32_t>(scratch_.size()) - 8;
        const uint32_t start = (fullPos_ + fullMask_ + 1 - span) & fullMask_;
        const float* ring = full_.data();
        const uint32_t mask = fullMask_;
        const double lag = refineLag([&](uint32_t j) { return ring[(start + j) & mask]; }, span, tau * decim_, scratch_.data());
        const double hz = sr_ / lag;
        if (!(hz >= lowHz_ * 0.97 && hz <= highHz_ * 1.03)) return;
        result_.voiced = true;
        result_.hz = hz;
        result_.lag = lag;
        result_.confidence = std::clamp(1.0 - static_cast<double>(dn_[best]), 0.0, 1.0);
    }

    std::vector<float> full_, scratch_;
    float dec_[kDecRing] = {};
    float x_[kMaxWindow + kMaxLag + 4] = {};
    float dn_[kMaxLag + 4] = {};
    Biquad aa1_, aa2_;
    Result result_;
    double sr_ = 48000.0, fsd_ = 12000.0, lowHz_ = 60.0, highHz_ = 1000.0, threshold_ = 0.15;
    uint32_t decim_ = 4, fullMask_ = 0, fullPos_ = 0, decPos_ = 0, count_ = 0, hopCount_ = 0;
    uint32_t window_ = 192, maxLag_ = 200, minLag_ = 12;
};

}  // namespace caw::lark
