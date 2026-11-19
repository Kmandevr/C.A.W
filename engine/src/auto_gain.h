// Per-slot auto gain (1.0.8): a slow trim after an effect that matches its output's short-term loudness to its input's, a listening aid.
#pragma once

#include <cstdint>

namespace caw {

// Matches loudness, not peaks, so a device can be compared by ear with its bypass. Both the slot's input and output
// are K-weighted (BS.1770's pre-filter, meters.h) and their energies (the two sides summed) integrated by a one-pole
// of 1.5 s (whose equivalent rectangular window is 3 s, BS.1770's short-term). Every 16 frames, counted across blocks
// so any block size gives the same bits, the target trim is 10 log10(input / output energy), clamped to +-24 dB, and
// the trim moves toward it with a 200 ms one-pole; the gain then ramps linearly over the next 16 frames. Below a
// silence floor (either energy under -70 LUFS, BS.1770's absolute gate) the target holds, so silence never drifts
// and a device that falls silent is not pumped up. reset() (at each Play) starts from 0 dB, so a render repeats.
// No allocation; the audio thread alone calls process().
class AutoGainMatcher {
public:
    static constexpr double kWindowSeconds = 1.5;   // the energies' time constant (a 3 s equivalent window)
    static constexpr double kTrimSeconds = 0.2;     // the trim's own smoothing
    static constexpr double kMaxTrimDb = 24.0;
    static constexpr double kFloorLufs = -70.0;     // below it the target holds
    static constexpr uint32_t kGrid = 16;

    void prepare(double sampleRate) noexcept;
    void reset() noexcept;
    // `in` is what the slot was given, `out` what the effect made of it: out is trimmed in place (m frames).
    void process(const float* inL, const float* inR, float* outL, float* outR, uint32_t m) noexcept;
    double trimDb() const noexcept { return trimDb_; }

private:
    struct Biquad {
        double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    };
    struct State {
        double z1 = 0, z2 = 0;
    };
    static double run(const Biquad& c, State& s, double x) noexcept {
        const double y = c.b0 * x + s.z1;
        s.z1 = c.b1 * x - c.a1 * y + s.z2;
        s.z2 = c.b2 * x - c.a2 * y;
        return y;
    }
    Biquad shelf_, high_;
    State st_[4][2];  // in L, in R, out L, out R: shelf, high-pass
    double keep_ = 0, trimKeep_ = 0, floor_ = 0;
    double eIn_ = 0, eOut_ = 0;
    double targetDb_ = 0, trimDb_ = 0, gain_ = 1, step_ = 0;
    uint32_t left_ = 0;  // frames until the next grid point
};

}  // namespace caw
