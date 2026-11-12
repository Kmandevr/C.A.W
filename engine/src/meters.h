// Live loudness (ITU-R BS.1770-5 / EBU Tech 3341), true peak and stereo correlation meters: cheap accumulation on the audio thread, the rest at read.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>

namespace caw {

// A meter reading that has no value yet (too little audio, or silence below the absolute gate), in LUFS or dBTP.
constexpr float kMeterNone = -200.0f;

// Stereo correlation: sum(L R) / sqrt(sum(L L) sum(R R)) over an exponential window of about 300 ms, from +1 (the
// same on both sides: mono) through 0 (unrelated) to -1 (opposite: cancels in mono); 0 while silent. The audio
// thread adds three products a sample and publishes one value a block; any thread reads it.
class CorrelationMeter {
public:
    void prepare(double sampleRate) noexcept;
    void process(const float* left, const float* right, int frames) noexcept;  // audio thread
    void clear() noexcept;                                                     // audio thread (or before it runs)
    float read() const noexcept { return value_.load(std::memory_order_relaxed); }

private:
    double ll_ = 0, rr_ = 0, lr_ = 0;
    double perFrame_ = 0;  // -1 / (window x rate): the decay is exp(perFrame_ x frames)
    int keepFrames_ = -1;  // the block size keep_ was worked out for
    double keep_ = 1;
    std::atomic<float> value_{0.0f};
};

// Momentary (400 ms), short-term (3 s) and integrated (gated) loudness of a stereo signal, per ITU-R BS.1770-5
// (11/2023) and EBU Tech 3341 V4 (11/2023), and its true peak (BS.1770-5 Annex 2). The audio thread K-weights
// each sample (two biquads a side), sums its square into the current 100 ms sub-block, and at each sub-block's
// end (control rate) works out the 400 ms and 3 s windows from the last 4 and 30 sub-blocks, publishes them, and
// counts the 400 ms block's loudness into a histogram of 0.01 LU bins from -70 to +10 LUFS. The integrated
// loudness is worked out from that histogram when read (off the audio thread), so memory stays fixed however long
// it runs; a block's energy is taken at its bin's centre, at most 0.005 LU off. The true peak oversamples x4 with
// the Annex's 48-tap interpolating filter. Nothing here allocates once constructed.
class LoudnessMeter {
public:
    static constexpr int kBins = 8000;            // -70 .. +10 LUFS in 0.01 LU
    static constexpr double kLowestLufs = -70.0;  // the absolute gate
    static constexpr double kBinLu = 0.01;

    struct Reading {
        float momentary = kMeterNone, shortTerm = kMeterNone, integrated = kMeterNone;
        float momentaryMax = kMeterNone, shortTermMax = kMeterNone;  // since the last reset
        float truePeakL = kMeterNone, truePeakR = kMeterNone;      // dBTP since the last read
        float truePeakMax = kMeterNone;                             // dBTP since the last reset
        double integratedSeconds = 0;                               // audio measured since the last reset
    };

    LoudnessMeter();
    void prepare(double sampleRate) noexcept;  // before the audio thread runs it
    void process(const float* left, const float* right, int frames) noexcept;  // audio thread
    // Any thread: the integrated loudness, the maxima and the true-peak maximum start again (the audio thread
    // clears them at its next block).
    void requestReset() noexcept { resetAsked_.fetch_add(1, std::memory_order_relaxed); }
    // Before the audio thread runs it: from now on the meter measures only while something reads it, from the start
    // until kUnreadSeconds pass with no read(), and again from the next read() (which starts it over, as a reset
    // does). The Engine's master meter does this: nothing in the app reads it yet, and it costs about as much as
    // a light effect (2026-11-11 performance pass).
    static constexpr double kUnreadSeconds = 30.0;
    void sleepWhenUnread(bool on) noexcept { sleepWhenUnread_ = on; }
    // Off the audio thread (one reader at a time): the momentary and short-term values as last published, the
    // integrated loudness worked out now, and the true peaks (those since the last read are reset by reading).
    Reading read() noexcept;
    // Audio thread: x[0..n) holds only zeros (either sign).
    static bool allZero(const float* x, int n) noexcept;

    // K-weighting for `sampleRate`: the BS.1770 pre-filter (a high shelf, then a high-pass) designed from its
    // analogue prototype, so it is the Recommendation's 48 kHz table at 48 kHz and the same curve at any rate.
    struct Biquad {
        double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0;
    };
    static void kWeighting(double sampleRate, Biquad& shelf, Biquad& highpass) noexcept;

private:
    struct Filter {
        Biquad c;
        double z1 = 0, z2 = 0;
        double run(double x) noexcept {
            const double y = c.b0 * x + z1;
            z1 = c.b1 * x - c.a1 * y + z2;
            z2 = c.b2 * x - c.a2 * y;
            return y;
        }
    };
    void clearAudioState() noexcept;
    bool atRest() const noexcept;
    void endSubBlock() noexcept;
    double truePeak(int side, double x) noexcept;

    double sampleRate_ = 48000;
    int subFrames_ = 4800;  // 100 ms
    int oversample_ = 4;    // 4 at 48 kHz, 2 at 96 kHz, 1 from 192 kHz (Annex 2)
    Filter shelf_[2], high_[2];
    double subSum_ = 0;  // the K-weighted squares of both sides in the current sub-block
    int subLeft_ = 4800;
    std::array<double, 30> subs_{};  // the last 30 sub-blocks' mean squares (sum of both sides), a ring
    int subPos_ = 0, subCount_ = 0;
    uint32_t resetSeen_ = 0;
    // The last 12 samples per side, written twice (at tpPos_ and tpPos_ + 12), so the window is always contiguous:
    // the sample k back is at tpPos_ + 12 - k.
    double tpHistory_[2][24] = {};
    int tpPos_ = 0;
    bool settled_ = true;  // atRest() after the last samples measured: silence in skips the per-sample work
    double tpMax_ = 0, mMax_ = 0, sMax_ = 0;

    std::atomic<uint32_t> resetAsked_{0};
    std::atomic<uint32_t> reads_{0};  // bumped by read()
    bool sleepWhenUnread_ = false;
    uint32_t readsSeen_ = 0;          // audio thread
    double unreadFrames_ = 0;         // audio thread: frames since a read() was last seen
    bool asleep_ = false;             // audio thread: not measuring (no read lately)
    std::atomic<float> momentary_{kMeterNone}, shortTerm_{kMeterNone}, momentaryMax_{kMeterNone},
        shortTermMax_{kMeterNone}, truePeakL_{0}, truePeakR_{0}, truePeakMax_{0};
    std::atomic<uint64_t> blocks_{0};  // 400 ms blocks counted since the reset (any loudness)
    std::array<std::atomic<uint32_t>, kBins> bins_;
    std::array<double, kBins> binEnergy_{};  // each bin centre's mean square, for the read
};

}  // namespace caw
