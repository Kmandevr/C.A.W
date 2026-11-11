// C.A.W. Library: drawn LFO curves, tempo-synced phase and tremolo (the .caw lfo.curve and util.trem); header-only.
#pragma once

#include <cmath>

#include "../detmath.hpp"

namespace caw::lib {

// A drawn LFO shape: up to kMaxPoints points (x = where in the cycle, 0..1, y = level, -1..1), joined by
// straight lines and looped (after the last point the line runs back to the first, one cycle on). It holds
// no phase: read it at any phase, for example an Lfo's (lfo.hpp):
//
//     const double v = curve.valueAt(lfo.phase());
//     lfo.advance(1);
//
// setEven() places the points at even spacing, which is the .caw lfo.curve(beats, phase, p0, p1, p2, p3)
// for four points. valueAt() is a short search and one lerp: no allocation, safe on the audio thread. Set the
// points off the audio thread or between blocks (setPoints copies them).
class CurveShape {
public:
    static constexpr int kMaxPoints = 32;

    // Evenly spaced points: point k sits at k / count. A count outside 1..kMaxPoints is held to it.
    void setEven(const double* levels, int count) noexcept {
        count_ = clampCount(count);
        for (int k = 0; k < count_; ++k) {
            x_[k] = static_cast<double>(k) / count_;
            y_[k] = clampLevel(levels[k]);
        }
    }
    // Points at their own places (x 0..1, kept in order: a point left of the one before moves onto it).
    void setPoints(const double* xs, const double* levels, int count) noexcept {
        count_ = clampCount(count);
        double last = 0.0;
        for (int k = 0; k < count_; ++k) {
            double x = finiteOr0(xs[k]);
            x = x < last ? last : (x > 1.0 ? 1.0 : x);
            x_[k] = last = x;
            y_[k] = clampLevel(levels[k]);
        }
    }
    int count() const noexcept { return count_; }

    // The level at `phase` cycles (wrapped to 0..1).
    double valueAt(double phase) const noexcept {
        if (count_ <= 0) return 0.0;
        double p = finiteOr0(phase);
        p -= std::floor(p);
        // Before the first point: the line from the last point (one cycle back).
        if (p < x_[0]) return lerp(x_[count_ - 1] - 1.0, y_[count_ - 1], x_[0], y_[0], p);
        int k = 0;
        while (k + 1 < count_ && x_[k + 1] <= p) ++k;
        if (k + 1 < count_) return lerp(x_[k], y_[k], x_[k + 1], y_[k + 1], p);
        return lerp(x_[k], y_[k], x_[0] + 1.0, y_[0], p);  // after the last point: back to the first
    }

private:
    static int clampCount(int n) noexcept { return n < 1 ? 1 : (n > kMaxPoints ? kMaxPoints : n); }
    static double clampLevel(double v) noexcept {
        const double y = finiteOr0(v);
        return y < -1.0 ? -1.0 : (y > 1.0 ? 1.0 : y);
    }
    static double lerp(double x0, double y0, double x1, double y1, double p) noexcept {
        return x1 > x0 ? y0 + (y1 - y0) * (p - x0) / (x1 - x0) : y1;
    }

    double x_[kMaxPoints] = {0.0};
    double y_[kMaxPoints] = {0.0};
    int count_ = 1;
};

// Where a tempo-synced LFO is at a song position, in cycles (not wrapped): `seconds` into the song at `bpm`,
// one cycle every `beats` beats, started `offset` cycles in. 0 for a cycle length or tempo that is not
// positive. The .caw lfo.* read their phase this way from the layer's time.
inline double beatPhase(double seconds, double bpm, double beats, double offset = 0.0) noexcept {
    const double b = finiteOr0(beats), t = finiteOr0(bpm);
    if (!(b > 0.0) || !(t > 0.0)) return 0.0;
    return finiteOr0(seconds) * (t / 60.0) / b + finiteOr0(offset);
}

// A tremolo's gain from a bipolar LFO value (-1..1) and a depth (0..1): 1 at the LFO's bottom, 1 - depth at
// its top (the .caw util.trem: x * (1 - depth * (0.5 + 0.5 * lfo))).
inline double tremoloGain(double lfo, double depth) noexcept {
    return 1.0 - finiteOr0(depth) * (0.5 + 0.5 * finiteOr0(lfo));
}

}  // namespace caw::lib
