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

#include "tempo_map.h"

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
    // `channels` is the device's own count, the buffer's stride (only the first kMaxInputChannels are used).
    void beginCallback(const float* interleaved, int channels, int frames) noexcept;
    // The Engine's chunk: frames [at, at + frames) of this call play song samples [songPos, songPos + frames).
    void chunk(int at, int frames, int64_t songPos, bool playing) noexcept;
    // Device input for monitoring: channel c at frame i of the current chunk (0 when there is none).
    float input(int channel, int frame) const noexcept {
        const int f = chunkAt_ + frame;
        if (!in_ || channel < 0 || channel >= inChannels_ || f < 0 || f >= inFrames_) return 0.0f;
        return in_[static_cast<size_t>(f) * static_cast<size_t>(inStride_) + static_cast<size_t>(channel)];
    }
    bool recordingNow() const noexcept { return armed_.load(std::memory_order_relaxed); }
    // The song's tempo map (1.0.3) for audio tracks, which keep a pointer to this LiveAudio: the Engine's audio thread
    // sets it when it swaps a map in (before the mix graph runs, so tracks on pool workers read it after that), and
    // tracks read it while they play. Null outside an Engine (a track then times its clips by the transport alone).
    void setSongTime(const SongTime* song) noexcept { song_.store(song, std::memory_order_release); }
    const SongTime* songTime() const noexcept { return song_.load(std::memory_order_acquire); }
    // The Engine's tempo map on the control side (each project update and tempo-map call sets it): a recording
    // request without its own "tempo_map" times its takes by it.
    void setTempoPoints(std::vector<TempoPointSpec> points);
    // After process(): the latency ping's burst is added to the output here, and the input is captured. The
    // callback's input is let go here: a process() outside a device callback hears none (the buffer is the
    // device's and goes when it closes).
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
    // Tests: the writer stops draining the ring while held (a stalled disk), so a fast loop fills it.
    void holdWriter(bool hold) noexcept { holdWriter_.store(hold, std::memory_order_release); }
    // Finalises takes left behind by a crash (".wav.part" files in dir whose header is the recorder's own) and
    // lists them. Refused while a recording in this process writes into the folder.
    static std::string recover(const std::string& dir);

    // Latency ping: a noise burst out, its echo found in the input (a loopback cable, or speaker to mic).
    bool startPing();
    std::string pingResult();

private:
    std::atomic<const SongTime*> song_{nullptr};
    struct Header {
        int64_t songPos = 0;
        int32_t frames = 0;
        int32_t gapBefore = 0;  // frames dropped (full rings) just before this chunk, their song positions unknown
        bool silent = false;    // the sample ring was full: no samples were pushed, the writer writes silence here
    };
    struct Session;
    void writerLoop();

    const double sr_;
    // audio thread
    const float* in_ = nullptr;
    int inChannels_ = 0, inStride_ = 0, inFrames_ = 0, chunkAt_ = 0;
    std::atomic<bool> inChunk_{false};  // the audio thread is inside chunk() (startRecording waits it out)
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
    void waitForChunk() const noexcept;  // control thread, once disarmed: until no chunk() can still use the ring
    std::atomic<bool> stopWriter_{false};
    std::atomic<bool> holdWriter_{false};
    std::vector<TempoPointSpec> tempoPoints_;  // setTempoPoints (under ctl_)
    std::mutex ctl_;
    // ping (0 idle, 1 asked, 2 playing and capturing, 3 captured, 4 being worked out)
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
