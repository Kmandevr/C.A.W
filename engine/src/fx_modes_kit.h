// Small DSP parts the 1.1.0 effect modes share (delay lines, diffusers, a seeded noise, windows); allocation only in prepare().
#pragma once

#include <algorithm>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "stereo_pair.h"

// Original code (C.A.W. is Apache-2.0).

namespace caw::fx::modes {

// Bounded and flushed before it is stored in a loop (as the Library's delay lines): an extreme input can't latch a
// feedback path, a silent one never runs in subnormal numbers, NaN is read as 0.
inline float store(double v) noexcept {
    if (!(v > -1e4)) return v != v ? 0.0f : -1e4f;
    if (v > 1e4) return 1e4f;
    return (v < 1e-20 && v > -1e-20) ? 0.0f : static_cast<float>(v);
}
inline double flush(double v) noexcept { return v < 1e-20 && v > -1e-20 ? 0.0 : v; }

// A mono delay line of a power-of-two length. Read before write: `back` counts frames from the next write, so
// back 1 is the newest sample.
class Line {
public:
    bool prepare(size_t frames) noexcept {
        try {
            size_t n = 1;
            while (n < frames + 8) n <<= 1;
            buf_.assign(n, 0.0f);
            mask_ = n - 1;
        } catch (...) {
            return false;
        }
        pos_ = 0;
        return true;
    }
    void clear() noexcept {
        std::fill(buf_.begin(), buf_.end(), 0.0f);
        pos_ = 0;
    }
    size_t capacity() const noexcept { return mask_ + 1 - 8; }
    void write(double v) noexcept {
        buf_[pos_] = store(v);
        pos_ = (pos_ + 1) & mask_;
    }
    double at(size_t back) const noexcept { return buf_[(pos_ - back) & mask_]; }
    // `back` frames back (at least 2), by 4-point Hermite interpolation.
    double hermite(double back) const noexcept {
        const size_t w = static_cast<size_t>(back);
        const double t = back - static_cast<double>(w);
        const size_t p = pos_ - w;
        const double ym1 = buf_[(p + 1) & mask_], y0 = buf_[p & mask_];
        const double y1 = buf_[(p - 1) & mask_], y2 = buf_[(p - 2) & mask_];
        const double c1 = 0.5 * (y1 - ym1), c2 = ym1 - 2.5 * y0 + 2.0 * y1 - 0.5 * y2;
        const double c3 = 0.5 * (y2 - ym1) + 1.5 * (y0 - y1);
        return ((c3 * t + c2) * t + c1) * t + y0;
    }
    // `back` frames back (at least 1), linear.
    double linear(double back) const noexcept {
        const size_t w = static_cast<size_t>(back);
        const double t = back - static_cast<double>(w);
        const double a = buf_[(pos_ - w) & mask_], b = buf_[(pos_ - w - 1) & mask_];
        return a + (b - a) * t;
    }

private:
    std::vector<float> buf_;
    size_t mask_ = 0, pos_ = 0;
};

// A Schroeder all-pass of a fixed length (diffusion): y = -g x + d, d's input x + g y.
class Allpass {
public:
    bool prepare(size_t frames) noexcept { return line_.prepare(frames + 2); }
    void clear() noexcept { line_.clear(); }
    void setLength(size_t frames) noexcept { len_ = std::max<size_t>(1, std::min(frames, line_.capacity())); }
    double process(double x, double g) noexcept {
        const double d = line_.at(len_);
        const double v = x + g * d;
        line_.write(v);
        return d - g * v;
    }
    // A modulated read (`extra` frames more, fractional).
    double processMod(double x, double g, double extra) noexcept {
        const double d = line_.linear(static_cast<double>(len_) + extra);
        const double v = x + g * d;
        line_.write(v);
        return d - g * v;
    }

private:
    Line line_;
    size_t len_ = 1;
};

// A first-order all-pass (dispersion: a spring's chirp): y = a x + x1 - a y1.
struct Allpass1 {
    double x1 = 0, y1 = 0;
    double process(double x, double a) noexcept {
        const double y = a * (x - y1) + x1;
        x1 = x;
        y1 = flush(y);
        return y1;
    }
    void clear() noexcept { x1 = y1 = 0; }
};

// A seeded noise, the same numbers on every platform: uniform in [-1, 1).
struct Noise {
    uint32_t seed = 1;
    double next() noexcept {
        seed = seed * 1664525u + 1013904223u;
        return static_cast<double>(seed >> 8) / 8388608.0 - 1.0;
    }
};

// A one-pole smoother toward a target (k the per-sample coefficient from timeCoefficient).
struct Smooth {
    double y = 0;
    double next(double target, double k) noexcept { return y = flush(target + (y - target) * k); }
};

// sin^2(pi x) for x in [0, 1]: a Hann window (two at half a period apart sum to 1).
inline double hann(double x) noexcept {
    const double s = lib::fastSinCycles(0.5 * x);
    return s * s;
}

// An equal-power pan, -1 left .. 1 right: the left and right gains.
inline void panGains(double pan, double& l, double& r) noexcept {
    const double p = 0.125 * (std::clamp(pan, -1.0, 1.0) + 1.0);  // 0..0.25 cycles
    l = lib::fastSinCycles(p + 0.25);
    r = lib::fastSinCycles(p);
}

// x with NaN and infinities read as 0, both lanes (as finiteOr0).
inline Pair finitePair(Pair x) noexcept { return pairOf(finiteOr0(lane(x, 0)), finiteOr0(lane(x, 1))); }

// A stereo pair of state-variable filters set alike, run as one two-wide vector (stereo_pair.h): the Library's Svf
// arithmetic (its set() works the coefficients out, skipping an unchanged cutoff), both sides' state in one Pair.
struct PairSvf {
    lib::Svf coef;  // only its coefficients are used
    Pair s1{}, s2{};
    void set(double hz, double q, double sr) noexcept { coef.set(hz, q, sr); }
    void clear() noexcept { s1 = s2 = splat(0.0); }
    void flush() noexcept { s1 = flushPair(s1), s2 = flushPair(s2); }
    // One frame: v1 (band) and v2 (low); the high is x - k v1 - v2.
    void step(Pair x, Pair& v1, Pair& v2) noexcept {
        lib::Svf::step(x, s1, s2, splat(coef.a1()), splat(coef.a2()), splat(coef.a3()), splat(2.0), v1, v2);
    }
    Pair low(Pair x) noexcept {
        Pair v1, v2;
        step(x, v1, v2);
        return v2;
    }
    Pair high(Pair x) noexcept {
        Pair v1, v2;
        step(x, v1, v2);
        return x - splat(coef.k()) * v1 - v2;
    }
    // The 2nd-order all-pass: x - 2k v1.
    Pair allpass(Pair x) noexcept {
        Pair v1, v2;
        step(x, v1, v2);
        return x - splat(2.0 * coef.k()) * v1;
    }
};

// A stereo pair of EQ bands (the Library's EqBand construction: m0 x + m1 band + m2 low on a state-variable
// filter), one two-wide vector.
struct PairEq {
    enum Kind { LowShelf, Bell, HighShelf };
    double a1 = 1, a2 = 0, a3 = 0, m0 = 1, m1 = 0, m2 = 0;
    double hz_ = -1, db_ = 1e9, q_ = -1, rate_ = -1;
    int kind_ = -1;
    Pair s1{}, s2{};
    void set(Kind kind, double hz, double db, double q, double sr) noexcept {
        if (kind == kind_ && hz == hz_ && db == db_ && q == q_ && sr == rate_) return;
        kind_ = kind, hz_ = hz, db_ = db, q_ = q, rate_ = sr;
        const double f = std::clamp(hz, 10.0, 0.49 * sr), d = std::clamp(db, -48.0, 24.0), qq = std::clamp(q, 0.1, 40.0);
        const double A = detPow(10.0, d / 40.0), rootA = detPow(10.0, d / 80.0);
        double g = detTan(kPi * f / sr), k = 1.0 / qq;
        if (kind == LowShelf) g /= rootA, m0 = 1.0, m1 = k * (A - 1.0), m2 = A * A - 1.0;
        else if (kind == HighShelf) g *= rootA, m0 = A * A, m1 = k * (1.0 - A) * A, m2 = 1.0 - A * A;
        else k = 1.0 / (qq * A), m0 = 1.0, m1 = k * (A * A - 1.0), m2 = 0.0;
        a1 = 1.0 / (1.0 + g * (g + k));
        a2 = g * a1;
        a3 = g * a2;
    }
    void clear() noexcept { s1 = s2 = splat(0.0); }
    void flush() noexcept { s1 = flushPair(s1), s2 = flushPair(s2); }
    Pair process(Pair x) noexcept {
        Pair v1, v2;
        lib::Svf::step(x, s1, s2, splat(a1), splat(a2), splat(a3), splat(2.0), v1, v2);
        return splat(m0) * x + splat(m1) * v1 + splat(m2) * v2;
    }
};

}  // namespace caw::fx::modes
