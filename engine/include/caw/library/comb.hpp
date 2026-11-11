// C.A.W. Library: a tuned feedback comb filter (fractional delay, damping in the loop); header-only, prepare() allocates.
#pragma once

#include <cmath>
#include <cstddef>
#include <vector>

#include "../detmath.hpp"

namespace caw::lib {

// A feedback comb: y[n] = x[n] + feedback * lowpass(y[n - D]), with D = sampleRate / frequency samples (read
// between samples, linearly). It resonates at the frequency and every multiple of it, like a plucked string
// or a tube: a positive feedback peaks at f, 2f, 3f, ...; a negative one at the odd multiples of f / 2 (a
// hollow, clarinet-like sound an octave down). `damping` 0..1 darkens the loop (a one-pole low-pass), so the
// high resonances die first. The output is scaled by sqrt(1 - feedback^2), which keeps white noise at the
// same power at every feedback.
//
// prepare() allocates the delay line (call it in activate); set() and process() never allocate. A NaN input
// reads 0, and what goes back into the loop is bounded and flushed to 0 when tiny (no subnormal decay).
class CombFilter {
public:
    // Room for frequencies down to `lowestHz` at `sampleRate`.
    void prepare(double sampleRate, double lowestHz = 20.0) {
        rate_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        const double lo = lowestHz > 1.0 && std::isfinite(lowestHz) ? lowestHz : 20.0;
        line_.assign(static_cast<size_t>(std::ceil(rate_ / lo)) + 3, 0.0f);
        pos_ = 0;
        lp_ = 0.0;
        cutoff_ = -1.0;
    }
    // frequency in Hz (held to the prepared lowest .. 0.45 of the sample rate), feedback -0.995..0.995,
    // damping 0..1. Costs a divide and a sqrt; call it when a knob moves (every 16 frames is plenty).
    void set(double frequency, double feedback, double damping) noexcept {
        const size_t n = line_.size();
        if (n < 4) return;
        double f = finiteOr0(frequency);
        const double lo = rate_ / static_cast<double>(n - 3), hi = 0.45 * rate_;
        f = f < lo ? lo : (f > hi ? hi : f);
        if (f != cutoff_) {
            cutoff_ = f;
            delay_ = rate_ / f;
        }
        const double fb = finiteOr0(feedback);
        feedback_ = fb < -0.995 ? -0.995 : (fb > 0.995 ? 0.995 : fb);
        const double d = finiteOr0(damping);
        damp_ = 1.0 - 0.9 * (d < 0.0 ? 0.0 : (d > 1.0 ? 1.0 : d));  // the loop low-pass's coefficient, 1 = open
        scale_ = std::sqrt(1.0 - feedback_ * feedback_);
    }
    double process(double input) noexcept {
        const size_t n = line_.size();
        if (n < 4) return 0.0;
        // D samples back, between the two nearest: back is pos + 3 .. pos + n - 1 (under 2n) after one wrap.
        const double back = static_cast<double>(pos_) + static_cast<double>(n) - delay_;
        const size_t whole = static_cast<size_t>(back);
        const size_t i0 = whole >= n ? whole - n : whole;
        const size_t i1 = i0 + 1 == n ? 0 : i0 + 1;
        const double frac = back - static_cast<double>(whole);
        const double delayed = line_[i0] + (line_[i1] - line_[i0]) * frac;
        lp_ += (delayed - lp_) * damp_;
        if (lp_ < 1e-20 && lp_ > -1e-20) lp_ = 0.0;
        const double y = finiteOr0(input) + feedback_ * lp_;
        line_[pos_] = store(y);
        pos_ = pos_ + 1 == n ? 0 : pos_ + 1;
        return y * scale_;
    }
    void clear() noexcept {
        for (float& v : line_) v = 0.0f;
        lp_ = 0.0;
    }

private:
    static float store(double v) noexcept {
        if (!(v > -1e4)) return v != v ? 0.0f : -1e4f;
        if (v > 1e4) return 1e4f;
        return (v < 1e-20 && v > -1e-20) ? 0.0f : static_cast<float>(v);
    }
    std::vector<float> line_;
    size_t pos_ = 0;
    double rate_ = 48000.0, delay_ = 100.0, cutoff_ = -1.0, feedback_ = 0.0, damp_ = 1.0, scale_ = 1.0, lp_ = 0.0;
};

}  // namespace caw::lib
