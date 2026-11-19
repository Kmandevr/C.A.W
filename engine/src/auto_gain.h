// Per-slot auto gain (1.0.8): a slow trim after an effect that matches its output's short-term loudness to its input's, a listening aid.
#pragma once

#include <cmath>
#include <cstdint>

namespace caw {

// Matches loudness, not peaks, so a device can be compared by ear with its bypass. Both the slot's input and output
// are K-weighted (BS.1770's pre-filter, meters.h) and their energies (the two sides summed) integrated by a one-pole
// of 1.5 s (whose equivalent rectangular window is 3 s, BS.1770's short-term). Every 16 frames, counted across blocks
// so any block size gives the same bits, the target trim is 10 log10(input / output energy), clamped to +-24 dB, and
// the trim moves toward it with a 200 ms one-pole; the gain then ramps linearly over the next 16 frames. Below a
// silence floor (either energy under -70 LUFS, BS.1770's absolute gate) the target holds, so silence never drifts
// and a device that falls silent is not pumped up. restart() (turned on, and each Play) starts the analysis from
// 0 dB, so a render repeats from Play; the gain heard ramps from where it was to that fresh trim over fadeFrames()
// (10 ms on the grid), so turning on or a Play while tails sound never steps. release() (turned off) ramps the gain
// to unity over the same fade; once active() is false the host stops calling it and its output is untouched.
// advanceSilence() is process() over frames of silence in and out that the host skipped (a sleeping effect): it
// gives the same state, so the trim does not depend on where the host's blocks fall.
// No allocation; the audio thread alone calls process(), advanceSilence(), restart() and release().
class AutoGainMatcher {
public:
    static constexpr double kWindowSeconds = 1.5;   // the energies' time constant (a 3 s equivalent window)
    static constexpr double kTrimSeconds = 0.2;     // the trim's own smoothing
    static constexpr double kMaxTrimDb = 24.0;
    static constexpr double kFloorLufs = -70.0;     // below it the target holds
    static constexpr uint32_t kGrid = 16;
    static constexpr double kFadeSeconds = 0.01;  // the ramp from the trim to unity (off) or to a new Play's start
    // The fade in frames: kFadeSeconds rounded up to whole grid steps (480 at 48 kHz).
    static uint32_t fadeFrames(double sampleRate) noexcept {
        const double frames = kFadeSeconds * (sampleRate > 0 ? sampleRate : 48000.0);
        const double steps = std::ceil(frames / kGrid - 1e-9);
        return (steps < 1 ? 1u : static_cast<uint32_t>(steps)) * kGrid;
    }

    void prepare(double sampleRate) noexcept;
    // Back to 0 dB at once, the fade too (a fresh matcher).
    void reset() noexcept;
    // Analysis from 0 dB again; the gain heard fades from its last value (none when that was unity).
    void restart() noexcept;
    // Turned off: the gain heard fades to unity, then active() is false.
    void release() noexcept;
    bool active() const noexcept { return on_ || fadeLeft_ > 0; }
    // `in` is what the slot was given, `out` what the effect made of it: out is trimmed in place (m frames).
    void process(const float* inL, const float* inR, float* outL, float* outR, uint32_t m) noexcept;
    // m frames of silence in and out the host did not run: the state process() would have left.
    void advanceSilence(uint32_t m) noexcept;
    double trimDb() const noexcept { return on_ ? trimDb_ : 0.0; }

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
        if (s.z1 < 1e-30 && s.z1 > -1e-30) s.z1 = 0.0;  // silence: no subnormal creep, and a state that settles
        if (s.z2 < 1e-30 && s.z2 > -1e-30) s.z2 = 0.0;
        return y;
    }
    void clearAnalysis() noexcept;
    // One frame: the analysis of the slot's input and output samples (while on) and the fade; the gain to apply.
    double frame(double inL, double inR, double outL, double outR) noexcept;
    bool settled() const noexcept;
    Biquad shelf_, high_;
    State st_[4][2];  // in L, in R, out L, out R: shelf, high-pass
    double keep_ = 0, trimKeep_ = 0, floor_ = 0;
    double eIn_ = 0, eOut_ = 0;
    double targetDb_ = 0, trimDb_ = 0, gain_ = 1, step_ = 0;
    uint32_t left_ = 0;  // frames until the next grid point
    // The fade (restart, release): the gain heard goes from fadeFrom_ to the analysis' (unity once off) in
    // fadeFrames_ frames; applied_ is the gain last heard.
    double fadeFrom_ = 1, applied_ = 1;
    uint32_t fadeFrames_ = kGrid, fadeLeft_ = 0;
    bool on_ = false;  // restart()ed and not release()d since
};

}  // namespace caw
