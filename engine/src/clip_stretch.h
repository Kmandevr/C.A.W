// High-quality clip stretching and pitch: Signalsmith Stretch (engine/third_party, MIT) behind a real-time-safe interface.
#pragma once

#include <cstdint>
#include <memory>

namespace caw {

// One clip voice's Signalsmith Stretch instance (stereo, its default preset: 120 ms blocks every 30 ms, the
// computation split across each interval). prepare() allocates on the control thread; every other call is real-time
// safe: measured to allocate nothing and take no lock (audio_rt_test.cpp, docs/engine.md "Audio clips").
//
// The caller feeds source frames ahead of the output: the output at time t is the source at the input position fed
// outputLatency() frames earlier, less inputLatency() (see ClipReader in time_stretch.h).
class HqStretcher {
public:
    static constexpr int kChunk = 64;         // output frames per process()
    static constexpr int kMaxFeed = 64 * 32;  // input frames one process() reads at most

    HqStretcher();
    ~HqStretcher();
    HqStretcher(const HqStretcher&) = delete;
    HqStretcher& operator=(const HqStretcher&) = delete;

    bool prepare(double sampleRate);  // control thread; false when out of memory
    double sampleRate() const noexcept { return rate_; }
    int inputLatency() const noexcept { return inLat_; }
    int outputLatency() const noexcept { return outLat_; }
    int seekLength() const noexcept { return seekLen_; }

    // Clears the state for a new start and sets the pitch (a frequency ratio).
    void reset(double pitchRatio) noexcept;
    // The input scratch the next seek() or process() reads: max(kMaxFeed, seekLength()) frames a side.
    float* inputL() noexcept { return inL_.get(); }
    float* inputR() noexcept { return inR_.get(); }
    // Pre-rolls `frames` (at most seekLength()) of input from the scratch, at a playback rate hint.
    void seek(int frames, double rate) noexcept;
    // kChunk output frames from `inFrames` (0..kMaxFeed) of input in the scratch.
    void process(int inFrames, float* outL, float* outR) noexcept;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
    std::unique_ptr<float[]> inL_, inR_;
    double rate_ = 0;
    int inLat_ = 0, outLat_ = 0, seekLen_ = 0;
};

}  // namespace caw
