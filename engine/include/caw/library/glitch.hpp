// C.A.W. Library: glitch kernels (sample and hold, 16-bit mask, wraparound), the .caw glitch.hold, mask and wrap; header-only.
#pragma once

#include <cmath>
#include <cstdint>

#include "../detmath.hpp"

namespace caw::lib {

// Ported from the .caw glitch.* built-ins with the same results (engine/tests/library_kernels_test.cpp renders
// both). The stutter (.caw glitch.stutter) is not here: the built-in Stutter effect (org.caw.stutter) does it,
// and the built-in Bitcrush (org.caw.bitcrush) has a rate reduction with jitter and converter filters; these
// kernels are the small building blocks for your own code.

// Sample and hold: takes a new value `rate` times a second and holds it in between (the first sample is
// always taken). A rate of 0 holds forever; a rate is held to the sample rate. Good on audio (a crude
// downsampler) and on modulation (stepped random from noise).
class SampleHold {
public:
    void reset() noexcept {
        phase_ = 0.0;
        value_ = 0.0;
        started_ = false;
    }
    double process(double x, double rate, double sampleRate) noexcept {
        if (!started_ || phase_ >= 1.0) {
            value_ = finiteOr0(x);
            started_ = true;
            phase_ -= std::floor(phase_);
        }
        const double r = finiteOr0(rate);
        const double sr = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        phase_ += (r < 0.0 ? 0.0 : (r > sr ? sr : r)) / sr;
        return value_;
    }
    double value() const noexcept { return value_; }

private:
    double phase_ = 0.0, value_ = 0.0;
    bool started_ = false;
};

// Flips bits of the sound read as a 16-bit number (x held to -1..1, times 32767, rounded down): `mask`
// 0..65535 names the bits. Mask 0 is a 16-bit quantizer; high bits are loud and harsh, low bits a hiss.
inline double bitMask(double x, uint32_t mask) noexcept {
    const double v = finiteOr0(x);
    const int32_t q = static_cast<int32_t>(std::floor((v < -1.0 ? -1.0 : (v > 1.0 ? 1.0 : v)) * 32767.0));
    return static_cast<double>(q ^ static_cast<int32_t>(mask & 0xFFFFu)) / 32767.0;
}

// Pushes the sound past full scale by `amount` (1 = clean, below 1 reads as 1) and wraps what goes over
// round to the other side, like an integer overflow: the result is always -1..1.
inline double wrapAround(double x, double amount) noexcept {
    const double v = finiteOr0(x) * (amount < 1.0 || !std::isfinite(amount) ? 1.0 : amount) + 1.0;
    return v - 2.0 * std::floor(v / 2.0) - 1.0;
}

}  // namespace caw::lib
