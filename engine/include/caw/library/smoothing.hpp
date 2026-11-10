// C.A.W. Library: parameter smoothers (one-pole and linear ramp) that stop knob moves from clicking; header-only.
#pragma once

#include <cmath>

#include "../detmath.hpp"

namespace caw::lib {

// Why smooth: a knob arrives once per block (or whenever the user moves it). Using the new value at once
// makes a step in a gain or cutoff, which you hear as a click or "zipper" noise. A smoother turns the step
// into a short glide. The cost is one multiply-add per sample, so smooth every parameter that scales audio.
//
// Both smoothers below split the work the efficient way: setTime() pays for the maths (an exp or a divide)
// once, setTarget() is free, and next() is a few flops. Call setTarget() as often as you like.

// One-pole (exponential) smoother: covers about 99 % of the distance to the target in `seconds`, fast at
// first and slower near the end, which suits cutoffs and other values heard on a log scale. When it gets
// within 1e-9 of the target it lands on it exactly, so it never creeps through subnormal numbers.
class OnePoleSmoother {
public:
    // The time to cover 99 % of a step (0: no smoothing). Costs one exp.
    void setTime(double seconds, double sampleRate) noexcept {
        coef_ = seconds > 0.0 && std::isfinite(seconds) && sampleRate > 0.0
                    ? detExp(-4.605170185988091 / (seconds * sampleRate))  // ln(100) = 4.605...
                    : 0.0;
    }
    void setTarget(double target) noexcept { target_ = finiteOr0(target); }
    // Jump straight to a value (at prepare or reset, so a voice does not glide in from 0).
    void snap(double value) noexcept { value_ = target_ = finiteOr0(value); }
    double next() noexcept {
        value_ = target_ + (value_ - target_) * coef_;
        if (std::fabs(value_ - target_) < 1e-9) value_ = target_;
        return value_;
    }
    // Fill `out` with the next `frames` values: per-sample gains for a block.
    void process(float* out, int frames) noexcept {
        for (int i = 0; i < frames; ++i) out[i] = static_cast<float>(next());
    }
    double value() const noexcept { return value_; }
    double target() const noexcept { return target_; }
    bool smoothing() const noexcept { return value_ != target_; }

private:
    double value_ = 0, target_ = 0, coef_ = 0;
};

// Linear ramp: reaches the target in exactly `seconds` (rounded to whole samples), then holds it. A new
// target restarts the ramp from wherever it is. Use it for gains and mixes, where a straight line is
// what you want and an exact end time matters (a crossfade that must finish by the block's end).
class LinearSmoother {
public:
    // The ramp length (0: jump). Costs nothing per sample; store it once.
    void setTime(double seconds, double sampleRate) noexcept {
        const double n = finiteOr0(seconds) * finiteOr0(sampleRate);
        rampFrames_ = n >= 1.0 ? (n > 1e9 ? 1000000000 : static_cast<int>(n + 0.5)) : 0;
    }
    void setTarget(double target) noexcept {
        target_ = finiteOr0(target);
        if (target_ == value_ || rampFrames_ == 0) {
            value_ = target_;
            left_ = 0;
            return;
        }
        left_ = rampFrames_;
        step_ = (target_ - value_) / rampFrames_;
    }
    void snap(double value) noexcept {
        value_ = target_ = finiteOr0(value);
        left_ = 0;
    }
    double next() noexcept {
        if (left_ > 0) value_ = --left_ == 0 ? target_ : value_ + step_;  // lands exactly on the target
        return value_;
    }
    void process(float* out, int frames) noexcept {
        for (int i = 0; i < frames; ++i) out[i] = static_cast<float>(next());
    }
    double value() const noexcept { return value_; }
    double target() const noexcept { return target_; }
    bool smoothing() const noexcept { return left_ > 0; }

private:
    double value_ = 0, target_ = 0, step_ = 0;
    int rampFrames_ = 0, left_ = 0;
};

}  // namespace caw::lib
