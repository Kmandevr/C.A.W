// Audio input: the device's input per callback for monitoring, recording armed tracks to WAV takes, latency ping, recovery.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <string_view>
#include <thread>
#include <vector>

#include "spsc.h"

namespace caw {

inline constexpr int kMaxInputChannels = 32;

// A component that plays the device input (an audio track monitoring): the Engine keeps its track running while
// the transport is stopped as long as it says so. Audio thread.
class LiveInputUser {
public:
    virtual ~LiveInputUser() = default;
    virtual bool monitoringStopped() const noexcept = 0;
};

// A float ring between the audio thread (push) and the writer thread (pop).
class FloatRing {
public:
    bool allocate(size_t capacity);  // a power of two at least this big; control thread
    size_t writable() const noexcept;
    size_t readable() const noexcept;
    bool push(const float* v, size_t n) noexcept;  // all or nothing
    size_t pop(float* out, size_t n) noexcept;

private:
    std::unique_ptr<float[]> buf_;
    size_t mask_ = 0;
    alignas(64) std::atomic<size_t> write_{0};
    alignas(64) std::atomic<size_t> read_{0};
};

// One Engine's live input. The platform's duplex callback calls beginCallback with the input frames of each
// process() call (and afterCallback with what it is about to play); the Engine calls chunk() for every chunk it
// renders. Without a device (tests, renders) beginCallback can be called by hand, or never: monitors hear silence.
class LiveAudio {
public:
    explicit LiveAudio(double sampleRate);
    ~LiveAudio();
    LiveAudio(const LiveAudio&) = delete;
    LiveAudio& operator=(const LiveAudio&) = delete;

    // ---- audio thread (the device callback)
    void beginCallback(const float* interleaved, int channels, int frames) noexcept;
    // The Engine's chunk: frames [at, at + frames) of this call play song samples [songPos, songPos + frames).
    void chunk(int at, int frames, int64_t songPos, bool playing) noexcept;
    // Device input for monitoring: channel c at frame i of the current chunk (0 when there is none).
    float input(int channel, int frame) const noexcept {
        const int f = chunkAt_ + frame;
        if (!in_ || channel < 0 || channel >= inChannels_ || f < 0 || f >= inFrames_) return 0.0f;
        return in_[static_cast<size_t>(f) * static_cast<size_t>(inChannels_) + static_cast<size_t>(channel)];
    }
    bool recordingNow() const noexcept { return armed_.load(std::memory_order_relaxed); }
    // After process(): the latency ping's burst is added to the output here, and the input is captured.
    void afterCallback(float* left, float* right, int frames) noexcept;

    // ---- control thread
    double sampleRate() const noexcept { return sr_; }
    // The device's channels (the platform sets it at open; 0: no input open).
    void setDeviceChannels(int channels) noexcept { deviceChannels_.store(channels, std::memory_order_relaxed); }
    int deviceChannels() const noexcept { return deviceChannels_.load(std::memory_order_relaxed); }
    // Recording latency compensation in frames: an override (>= 0), or -1 to use the measured ping, else the
    // device's own estimate (setDeviceLatency, from its buffer sizes).
    void setLatencyOverride(int64_t frames) noexcept { latencyOverride_.store(frames, std::memory_order_relaxed); }
    void setDeviceLatency(int64_t frames) noexcept { deviceLatency_.store(frames, std::memory_order_relaxed); }
    int64_t latency() const noexcept;
    std::string latencyJson() const;
    // Per-channel input peaks since the last call (at most `max`); returns the channels written.
    int peaks(float* out, int max) noexcept;

    // Recording (docs/engine.md, "Recording"). JSON in, JSON out.
    std::string startRecording(std::string_view requestJson);
    std::string stopRecording();
    std::string recordingStatus();
    // Finalises takes left behind by a crash (".wav.part" files in dir) and lists them.
    static std::string recover(const std::string& dir);

    // Latency ping: a noise burst out, its echo found in the input (a loopback cable, or speaker to mic).
    bool startPing();
    std::string pingResult();

private:
    struct Header {
        int64_t songPos = 0;
        int32_t frames = 0;
        int32_t gapBefore = 0;  // frames dropped (a full ring) just before this chunk
    };
    struct Session;
    void writerLoop();

    const double sr_;
    // audio thread
    const float* in_ = nullptr;
    int inChannels_ = 0, inFrames_ = 0, chunkAt_ = 0;
    int32_t gap_ = 0;
    std::atomic<float> peaks_[kMaxInputChannels];
    std::atomic<int> deviceChannels_{0};
    std::atomic<int64_t> latencyOverride_{-1}, deviceLatency_{0}, measured_{-1};
    // recording
    std::atomic<bool> armed_{false};
    std::atomic<int64_t> dropped_{0};
    int ringChannels_ = 0;
    std::unique_ptr<float[]> scratch_;  // one chunk's frames, interleaved for the ring
    FloatRing samples_;
    std::unique_ptr<Spsc<Header, 8192>> headers_;
    std::unique_ptr<Session> session_;
    std::thread writer_;
    std::atomic<bool> stopWriter_{false};
    std::mutex ctl_;
    // ping (0 idle, 1 asked, 2 playing and capturing, 3 captured)
    std::atomic<int> pingState_{0};
    std::vector<float> burst_, capture_;
    size_t pingAt_ = 0;
    std::string pingLast_;
};

// For the components an Engine builds on this thread: its LiveAudio (null outside an Engine), as BuildingQuality.
LiveAudio* buildingLiveAudio() noexcept;
class BuildingLiveAudio {
public:
    explicit BuildingLiveAudio(LiveAudio* a) noexcept;
    ~BuildingLiveAudio();
    BuildingLiveAudio(const BuildingLiveAudio&) = delete;
    BuildingLiveAudio& operator=(const BuildingLiveAudio&) = delete;

private:
    LiveAudio* was_;
};

}  // namespace caw
