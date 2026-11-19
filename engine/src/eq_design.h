// The EQ's FIR design kit (1.1.0): shared tables, an FFT done a slice per control step, the Match learner and curve.
#pragma once

#include <atomic>
#include <cstdint>
#include <vector>

namespace caw::fx::eqd {

// Original code (C.A.W. is Apache-2.0). Linear-phase and Match design their responses on the audio thread a
// slice at a time, on the control grid (as the Convolver builds its responses), so a redesign never blocks or
// allocates and any block size gives the same bits. Nothing here allocates after prepare().

constexpr uint32_t kMaxFft = 8192;  // the largest design (Linear-phase at High)
constexpr uint32_t kMaxBits = 13;

// Read-only tables every instance shares, built once (tables(), first called at registration).
struct Tables {
    double cos[kMaxFft / 2], sin[kMaxFft / 2];  // cos and -sin of 2 pi i / kMaxFft (detCos, detSin)
    uint32_t rev[kMaxFft];                      // 13-bit reversal; an n-point FFT shifts it right
    double tan[kMaxFft / 2 + 1];                // tan(pi k / kMaxFft), held below pi/2 (an EqFilter's magnitude2 input)
    float kaiser[3][kMaxFft];                   // Kaiser windows (beta kKaiserBeta) of 2,048, 4,096 and 8,192 points
    float hann[4096];                           // the Match learner's window
};
constexpr double kKaiserBeta = 6.0;
const Tables& tables() noexcept;

// An in-place complex radix-2 FFT of n <= kMaxFft points (the Library's Fft, in slices): start(), then step()
// until it returns true. Forward is e^{-j}, inverse e^{+j} and unscaled.
class StagedFft {
public:
    void start(double* re, double* im, uint32_t n, bool inverse) noexcept;
    // Up to `budget` swaps or butterflies; true once the transform is done.
    bool step(uint32_t budget) noexcept;
    void run() noexcept { while (!step(1u << 30)) {} }

private:
    double* re_ = nullptr;
    double* im_ = nullptr;
    uint32_t n_ = 0, shift_ = 0, idx_ = 0, half_ = 1, halfBits_ = 0;
    double sign_ = 1.0;
    int phase_ = 2;  // 0 reversal, 1 passes, 2 done
};

// Match's long-term spectra (Welch: 4,096-point Hann frames every 2,048 frames, power summed per bin) of a
// reference (the key) and of the input, each the mid (L + R) / 2. Audio thread: push() in run(), step() at each
// control. The sums are the saved snapshot (save()/load(), control thread).
class SpectrumLearner {
public:
    static constexpr uint32_t kN = 4096, kHop = 2048, kBins = kN / 2 + 1;
    enum Which { kReference = 0, kInput = 1 };

    bool prepare();  // allocates (control thread)
    void clear() noexcept;  // the frame history (the sums stay)
    void forget(int which) noexcept;
    // n frames: the reference (null: silence) and the input, each learned only while its flag is on.
    void push(const float* refL, const float* refR, const float* inL, const float* inR, uint32_t n, bool learnRef,
              bool learnIn) noexcept;
    void step() noexcept;
    const double* sums(int which) const noexcept { return sum_[which].data(); }
    uint32_t frames(int which) const noexcept { return hops_[which]; }  // frames learned (hops)
    double seconds(int which, double sampleRate) const noexcept { return hops_[which] * double(kHop) / sampleRate; }
    // The snapshot: the mean power per bin of each (bins with no frames: zeros). Seqlock-read, so it is safe while
    // the audio thread learns.
    static constexpr uint32_t kStateBytes = 16 + 2 * kBins * 4;
    bool save(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept;
    bool load(const uint8_t* src, uint32_t size) noexcept;
    bool any() const noexcept { return hops_[0] > 0 && hops_[1] > 0; }
    uint32_t generation() const noexcept { return gen_; }  // moves when the sums change

private:
    std::vector<float> ring_[2];
    std::vector<double> sum_[2], re_, im_;
    uint32_t hops_[2] = {0, 0};
    uint32_t pos_ = 0, since_ = 0, filled_ = 0, gen_ = 0;
    bool busy_ = false, learning_[2] = {false, false}, loud_[2] = {false, false};
    StagedFft fft_;
    std::atomic<uint32_t> seq_{0};
};

// Match's curve on a 1/24-octave grid from 20 Hz (kGrid points, to about 20 kHz): the reference's level minus
// the input's in dB, each smoothed over 1/6 octave, then over +-smoothing x 1 octave, clamped to +-12 dB, times
// amount, faded to 0 over 1/3 octave outside [lowHz, highHz]. Flat (zeros) until both have been learned.
constexpr uint32_t kGrid = 240;
double gridHz(uint32_t j) noexcept;
void matchCurve(const SpectrumLearner& l, double sampleRate, double amount, double smoothing, double lowHz, double highHz,
                double* curveDb) noexcept;
// One learned spectrum on the grid (dB, 1/6-octave smoothed; -120 where nothing is learned), for the display.
void spectrumOnGrid(const SpectrumLearner& l, int which, double sampleRate, double* db) noexcept;
// The curve's value (dB) at hz, interpolated on the grid (held at its ends).
double curveAt(const double* curveDb, double hz) noexcept;

// Up to 8 bells that approximate a curve (greedy: the largest remaining deviation, its width at half its height),
// for the app's "Fit bands" (each {freq, gain, q}; gain 0 for an unused one). One band per call, `residual`
// carrying what is left between calls (start it as a copy of the curve).
struct FitBand {
    double freq = 1000, gain = 0, q = 1;
};
FitBand fitOneBand(double* residual, double sampleRate) noexcept;

}  // namespace caw::fx::eqd
