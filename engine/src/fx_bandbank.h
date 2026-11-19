// A log-spaced band filterbank (TPT SVF band-passes, envelope followers, a bell cascade, a synthesis bank) shared by Duck's Carve and Mimic's vocoder.
#pragma once

#include <cmath>
#include <cstdint>

#include "caw/library/dynamics.hpp"
#include "caw/library/fastmath.hpp"

// Original code (C.A.W. is Apache-2.0). The filters are the topology-preserving state-variable filter (Zavalishin,
// "The Art of VA Filter Design"; the same core as lib::Svf), laid out band by band in plain arrays (structure of
// arrays), so the analysis loop over independent bands vectorizes. Each band-pass is two SVF stages (4th order),
// normalised to unity gain at its centre. Two sides (left and right, or mid and side) run side by side.

namespace caw::fx::bands {

inline constexpr double kPi = 3.14159265358979323846;

// Band k's centre of `count` log-spaced bands from lo to hi (both ends included).
inline double centre(uint32_t k, uint32_t count, double lo, double hi) noexcept {
    if (count < 2) return std::sqrt(lo * hi);
    return lo * std::pow(hi / lo, static_cast<double>(k) / static_cast<double>(count - 1));
}

// The SVF coefficients of a centre and q at a rate (the centre held below 0.49 of the rate).
struct Coef {
    float g = 0, k = 0, a1 = 0, a2 = 0, a3 = 0;
    void set(double fc, double q, double sr) noexcept {
        const double top = 0.49 * sr;
        fc = fc < 10.0 ? 10.0 : (fc > top ? top : fc);
        const double gg = std::tan(kPi * fc / sr), kk = 1.0 / q;
        g = static_cast<float>(gg);
        k = static_cast<float>(kk);
        a1 = static_cast<float>(1.0 / (1.0 + gg * (gg + kk)));
        a2 = static_cast<float>(gg * a1);
        a3 = static_cast<float>(gg * a2);
    }
};

// The analysis side: per band two band-pass stages on each side, rectified and followed (attack and release).
// env(side, band) is the band's level, linear. process() takes one frame of both sides.
template <uint32_t Max>
class Analyzer {
public:
    void setup(uint32_t count, double lo, double hi, double q, double sr) noexcept {
        count_ = count > Max ? Max : count;
        first_ = 0, last_ = count_;
        for (uint32_t b = 0; b < count_; ++b) {
            Coef c;
            c.set(centre(b, count_, lo, hi), q, sr);
            a1_[b] = c.a1, a2_[b] = c.a2, a3_[b] = c.a3;
            norm_[b] = c.k * c.k;  // each stage's band output peaks at 1/k at its centre: two stages, k^2 back to 1
        }
    }
    void setTimes(double attackSeconds, double releaseSeconds, double sr) noexcept {
        att_ = static_cast<float>(lib::timeCoefficient(attackSeconds, sr));
        rel_ = static_cast<float>(lib::timeCoefficient(releaseSeconds, sr));
    }
    void clear() noexcept {
        for (int s = 0; s < 2; ++s)
            for (uint32_t b = 0; b < Max; ++b) s1_[s][0][b] = s2_[s][0][b] = s1_[s][1][b] = s2_[s][1][b] = env_[s][b] = 0;
    }
    uint32_t count() const noexcept { return count_; }
    float env(int side, uint32_t band) const noexcept { return env_[side][band]; }
    // Only bands first..last-1 run (a band outside costs nothing and reads 0); one coming back starts from rest.
    void setActive(uint32_t first, uint32_t last) noexcept {
        last = last > count_ ? count_ : last;
        first = first > last ? last : first;
        for (uint32_t b = 0; b < count_; ++b) {
            const bool was = b >= first_ && b < last_, now = b >= first && b < last;
            if (was != now)
                for (int s = 0; s < 2; ++s) s1_[s][0][b] = s2_[s][0][b] = s1_[s][1][b] = s2_[s][1][b] = env_[s][b] = 0;
        }
        first_ = first, last_ = last;
    }
    void process(float x0, float x1) noexcept {
        side(0, x0);
        side(1, x1);
    }
    // One side only (a mono key).
    void side(int s, float x) noexcept {
        float* __restrict s1a = s1_[s][0];
        float* __restrict s2a = s2_[s][0];
        float* __restrict s1b = s1_[s][1];
        float* __restrict s2b = s2_[s][1];
        float* __restrict e = env_[s];
        const float* __restrict a1 = a1_;
        const float* __restrict a2 = a2_;
        const float* __restrict a3 = a3_;
        const float* __restrict nm = norm_;
        const float att = att_, rel = rel_;
        for (uint32_t b = first_; b < last_; ++b) {
            const float v3 = x - s2a[b];
            const float v1 = a1[b] * s1a[b] + a2[b] * v3;
            const float v2 = s2a[b] + a2[b] * s1a[b] + a3[b] * v3;
            s1a[b] = 2.0f * v1 - s1a[b];
            s2a[b] = 2.0f * v2 - s2a[b];
            const float w3 = v1 - s2b[b];
            const float w1 = a1[b] * s1b[b] + a2[b] * w3;
            const float w2 = s2b[b] + a2[b] * s1b[b] + a3[b] * w3;
            s1b[b] = 2.0f * w1 - s1b[b];
            s2b[b] = 2.0f * w2 - s2b[b];
            float y = w1 * nm[b];
            y = y < 0.0f ? -y : y;
            const float c = y > e[b] ? att : rel;
            float v = y + (e[b] - y) * c;
            v = v < 1e-20f ? 0.0f : v;  // no subnormals
            e[b] = v;
        }
    }

    // Settles the filter states below 1e-20 to 0 (Mimic calls it at control rate: no subnormal tails).
    void flush() noexcept {
        for (int s = 0; s < 2; ++s)
            for (int k = 0; k < 2; ++k)
                for (uint32_t b = 0; b < count_; ++b) {
                    float& p = s1_[s][k][b];
                    float& q = s2_[s][k][b];
                    p = p < 1e-20f && p > -1e-20f ? 0.0f : p;
                    q = q < 1e-20f && q > -1e-20f ? 0.0f : q;
                }
    }

private:
    uint32_t count_ = 0, first_ = 0, last_ = 0;
    float a1_[Max] = {}, a2_[Max] = {}, a3_[Max] = {}, norm_[Max] = {};
    float s1_[2][2][Max] = {}, s2_[2][2][Max] = {};  // [side][stage][band]
    float env_[2][Max] = {};
    float att_ = 0, rel_ = 0;
};

// A cascade of bell filters (the SVF peaking form, y = x + (A^2 - 1) k v1 with k = 1 / (q A)) on two sides, one
// gain per band and side set at control rate (setGain), applied band after band.
template <uint32_t Max>
class BellCascade {
public:
    void setup(uint32_t count, double lo, double hi, double q, double sr) noexcept {
        count_ = count > Max ? Max : count;
        q_ = q;
        for (uint32_t b = 0; b < count_; ++b) {
            const double fc = centre(b, count_, lo, hi), top = 0.49 * sr;
            g_[b] = std::tan(kPi * (fc > top ? top : fc) / sr);
            for (int s = 0; s < 2; ++s) db_[s][b] = 1e300, setGain(s, b, 0.0);
        }
    }
    // Band b's gain on side s, dB (0: flat). Control rate: a division and a dbToGain.
    void setGain(int s, uint32_t b, double db) noexcept {
        if (db == db_[s][b]) return;
        db_[s][b] = db;
        const double a = lib::dbToGain(0.5 * db);  // A = 10^(dB/40)
        const double k = 1.0 / (q_ * a), g = g_[b];
        const double a1 = 1.0 / (1.0 + g * (g + k));
        c_[s][b][0] = static_cast<float>(a1);
        c_[s][b][1] = static_cast<float>(g * a1);
        c_[s][b][2] = static_cast<float>(g * g * a1);
        c_[s][b][3] = static_cast<float>((a * a - 1.0) * k);
        flat_[s][b] = db == 0.0;
    }
    void clear() noexcept {
        for (int s = 0; s < 2; ++s)
            for (uint32_t b = 0; b < Max; ++b) s1_[s][b] = s2_[s][b] = 0;
    }
    // Side `to` takes band b's gain from side `from` (no work beyond the copy).
    void copyGain(int to, int from, uint32_t b) noexcept {
        db_[to][b] = db_[from][b];
        for (int k = 0; k < 4; ++k) c_[to][b][k] = c_[from][b][k];
        flat_[to][b] = flat_[from][b];
    }
    uint32_t count() const noexcept { return count_; }
    // n samples of both sides in place, band after band, the two sides in one loop (two independent chains, so the
    // CPU overlaps them). A band flat on both sides costs nothing: it is skipped and rests (a dip starts in 0.01 dB
    // steps from there, so its first samples change next to nothing).
    void run(float* x0, float* x1, uint32_t n) noexcept {
        for (uint32_t b = 0; b < count_; ++b) {
            if (flat_[0][b] && flat_[1][b]) {
                s1_[0][b] = s2_[0][b] = s1_[1][b] = s2_[1][b] = 0.0f;
                continue;
            }
            const float a10 = c_[0][b][0], a20 = c_[0][b][1], a30 = c_[0][b][2], m0 = c_[0][b][3];
            const float a11 = c_[1][b][0], a21 = c_[1][b][1], a31 = c_[1][b][2], m1 = c_[1][b][3];
            float p1 = s1_[0][b], p2 = s2_[0][b], q1 = s1_[1][b], q2 = s2_[1][b];
            for (uint32_t i = 0; i < n; ++i) {
                const float v3 = x0[i] - p2, w3 = x1[i] - q2;
                const float v1 = a10 * p1 + a20 * v3, w1 = a11 * q1 + a21 * w3;
                const float v2 = p2 + a20 * p1 + a30 * v3, w2 = q2 + a21 * q1 + a31 * w3;
                p1 = 2.0f * v1 - p1, q1 = 2.0f * w1 - q1;
                p2 = 2.0f * v2 - p2, q2 = 2.0f * w2 - q2;
                x0[i] += m0 * v1;
                x1[i] += m1 * w1;
            }
            s1_[0][b] = flush(p1), s2_[0][b] = flush(p2), s1_[1][b] = flush(q1), s2_[1][b] = flush(q2);
        }
    }

private:
    static float flush(float v) noexcept { return v < 1e-20f && v > -1e-20f ? 0.0f : v; }
    uint32_t count_ = 0;
    double q_ = 1.0, g_[Max] = {};
    double db_[2][Max] = {};
    float c_[2][Max][4] = {};
    bool flat_[2][Max] = {};
    float s1_[2][Max] = {}, s2_[2][Max] = {};
};

// The synthesis side (Mimic's carrier): one signal through the same 4th-order band-passes, each band's output
// followed (its level, for the caller's gains) and weighted by a gain that ramps in a straight line to the target
// setGains() gives over the next `frames`, then summed into two outputs by each band's pan weights (left, right).
template <uint32_t Max>
class Synthesis {
public:
    void setup(uint32_t count, double lo, double hi, double q, double sr) noexcept {
        count_ = count > Max ? Max : count;
        for (uint32_t b = 0; b < count_; ++b) {
            Coef c;
            c.set(centre(b, count_, lo, hi), q, sr);
            a1_[b] = c.a1, a2_[b] = c.a2, a3_[b] = c.a3;
            norm_[b] = c.k * c.k;
        }
        for (uint32_t b = count_; b < Max; ++b) a1_[b] = a2_[b] = a3_[b] = norm_[b] = 0.0f;
    }
    void setTimes(double attackSeconds, double releaseSeconds, double sr) noexcept {
        att_ = static_cast<float>(lib::timeCoefficient(attackSeconds, sr));
        rel_ = static_cast<float>(lib::timeCoefficient(releaseSeconds, sr));
    }
    void setPan(uint32_t b, float left, float right) noexcept { panL_[b] = left, panR_[b] = right; }
    void clear() noexcept {
        for (uint32_t b = 0; b < Max; ++b) s1a_[b] = s2a_[b] = s1b_[b] = s2b_[b] = env_[b] = gain_[b] = step_[b] = 0.0f;
    }
    uint32_t count() const noexcept { return count_; }
    float env(uint32_t b) const noexcept { return env_[b]; }
    // The gains to reach over the next `frames` frames (target[0..count)).
    void setGains(const float* target, uint32_t frames) noexcept {
        const float inv = 1.0f / static_cast<float>(frames ? frames : 1);
        for (uint32_t b = 0; b < count_; ++b) step_[b] = (target[b] - gain_[b]) * inv;
    }
    void process(float x, float& left, float& right) noexcept {
        float l = 0.0f, r = 0.0f;
        const float att = att_, rel = rel_;
        for (uint32_t b = 0; b < count_; ++b) {
            const float v3 = x - s2a_[b];
            const float v1 = a1_[b] * s1a_[b] + a2_[b] * v3;
            const float v2 = s2a_[b] + a2_[b] * s1a_[b] + a3_[b] * v3;
            s1a_[b] = 2.0f * v1 - s1a_[b];
            s2a_[b] = 2.0f * v2 - s2a_[b];
            const float w3 = v1 - s2b_[b];
            const float w1 = a1_[b] * s1b_[b] + a2_[b] * w3;
            const float w2 = s2b_[b] + a2_[b] * s1b_[b] + a3_[b] * w3;
            s1b_[b] = 2.0f * w1 - s1b_[b];
            s2b_[b] = 2.0f * w2 - s2b_[b];
            const float y = w1 * norm_[b];
            const float a = y < 0.0f ? -y : y;
            float e = a + (env_[b] - a) * (a > env_[b] ? att : rel);
            env_[b] = e < 1e-20f ? 0.0f : e;
            const float g = gain_[b] + step_[b];
            gain_[b] = g;
            const float o = y * g;
            l += o * panL_[b];
            r += o * panR_[b];
        }
        left = l, right = r;
    }
    // Settles the filter states below 1e-20 to 0 (call at control rate: no subnormal tails).
    void flush() noexcept {
        for (uint32_t b = 0; b < count_; ++b) {
            s1a_[b] = tiny(s1a_[b]), s2a_[b] = tiny(s2a_[b]), s1b_[b] = tiny(s1b_[b]), s2b_[b] = tiny(s2b_[b]);
        }
    }

private:
    static float tiny(float v) noexcept { return v < 1e-20f && v > -1e-20f ? 0.0f : v; }
    uint32_t count_ = 0;
    float a1_[Max] = {}, a2_[Max] = {}, a3_[Max] = {}, norm_[Max] = {};
    float s1a_[Max] = {}, s2a_[Max] = {}, s1b_[Max] = {}, s2b_[Max] = {};
    float env_[Max] = {}, gain_[Max] = {}, step_[Max] = {}, panL_[Max] = {}, panR_[Max] = {};
    float att_ = 0, rel_ = 0;
};

}  // namespace caw::fx::bands
