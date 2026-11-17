// The sample browser's preview voice (API 33): one audio file auditioned beside the song, stretched to its tempo off the audio thread.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "asset_store.h"
#include "spsc.h"

namespace caw {

// Limits on what a preview stretches (a longer file previews at its own speed).
inline constexpr double kPreviewStretchSeconds = 60.0;  // source seconds
inline constexpr double kPreviewMinRatio = 0.25, kPreviewMaxRatio = 4.0;

// What caw_engine_preview_sample asks for (an options JSON, parsed with limits).
struct PreviewOptions {
    double startSeconds = 0;  // where in the file it starts (source seconds)
    double ratio = 1;         // output length / source length: project tempo stretching (0.25..4; 1 plays as is)
    int sync = 0;             // 0 now, 1 the song's next beat, 2 its next bar (only while the song plays)
    bool loop = false;        // play again from the start at the end
    double volume = -1;       // 0..1; negative keeps the current preview volume
    std::string layer;        // "layer": play through this track's effects and mix (empty: straight to the master)
    int slot = -1;            // the layer's engine slot, resolved by the caller (-1: the master)
};
bool parsePreviewOptions(const char* json, PreviewOptions& out, std::string& error);

// One prepared preview: the asset, and its stretched copy when the ratio is not 1. Immutable once posted.
struct PreviewSound {
    std::shared_ptr<const AudioAsset> asset;
    std::vector<float> l, r;  // the stretched copy at the engine rate (empty: the asset plays directly)
    int64_t frames = 0;       // playable frames
    double ratio = 1;
    bool loop = false;
    uint64_t seq = 0;    // its command's place in the queue
    uint64_t start = 0;  // which start it is (the C API's seq)
    void frame(int64_t i, float& left, float& right) const noexcept {
        if (i < 0 || i >= frames) {
            left = right = 0.0f;
        } else if (!l.empty()) {
            left = l[static_cast<size_t>(i)];
            right = r[static_cast<size_t>(i)];
        } else {
            left = asset->data[0][static_cast<size_t>(i)];
            right = asset->channels > 1 ? asset->data[1][static_cast<size_t>(i)] : left;
        }
    }
};

// The voice. Control threads (any, one at a time: a lock) prepare a sound and post commands through a lock-free
// queue; the audio thread takes them once per callback (take), adds the voice to the output per sample (next) and
// publishes what it plays (publish). A sound is freed on a control thread once the audio thread has moved past it
// (its command consumed and neither voice holds it). A start, stop or seek crossfades over kFade samples, so a
// scrub or a new file never clicks.
class SamplePreview {
public:
    explicit SamplePreview(double sampleRate);
    ~SamplePreview();

    // Control threads. start() stretches (when asked) on the calling thread, which can take a while for a long loop
    // (call it from a worker); false with an error when the queue is full or memory runs out.
    bool start(std::shared_ptr<const AudioAsset> asset, const PreviewOptions& options, std::string& error,
               double* effectiveRatio = nullptr, uint64_t* startSeq = nullptr);  // startSeq: State::seq once it plays
    void stop();
    void seek(double sourceSeconds);
    void setVolume(double volume) noexcept;
    struct State {
        bool playing = false;     // a voice sounds or waits for its beat
        bool waiting = false;     // waiting for the song's next beat or bar
        bool through = false;     // it went through a track's effects in the last callback
        double seconds = 0;       // where it plays, in source seconds
        double length = 0;        // the file's length in source seconds
        uint64_t seq = 0;         // the start it plays (each start counts one up)
    };
    State state() const noexcept;

    // Audio thread. The song's clock at the callback's start: frames to its next beat and bar (-1: not playing).
    struct SongClock {
        int64_t toBeat = -1, toBar = -1;
    };
    void take(const SongClock& clock) noexcept;
    bool active() const noexcept { return cur_.sound != nullptr || old_.sound != nullptr; }
    // The slot whose effects it plays through while it sounds (-1: none, it goes to the master).
    int route() const noexcept { return active() ? route_ : -1; }
    void next(double& left, double& right) noexcept;  // adds the voice's next frame
    // Adds m frames to a track's instrument output (its effects follow); marks this callback as routed.
    void render(float* left, float* right, int m) noexcept;
    void publish() noexcept;                          // once per callback, after the last frame

    static constexpr int kFade = 256;

private:
    struct Cmd {
        enum Type : uint8_t { Start, Stop, Seek } type = Start;
        PreviewSound* sound = nullptr;
        int64_t frame = 0;
        int64_t wait = -1;  // sync: 1 beat, 2 bar (resolved by take)
        uint64_t seq = 0;
        int slot = -1;      // Start: the track it plays through (-1: the master)
    };
    struct Voice {
        const PreviewSound* sound = nullptr;
        int64_t pos = 0;
        int64_t wait = 0;   // frames before it starts
        int ramp = 0;       // fade-in samples done (kFade: full) or, for the old voice, fade-out samples left
    };
    bool post(const Cmd& c);
    void prune();  // frees sounds the audio thread no longer holds (lock held)

    double sr_;
    std::mutex lock_;
    std::vector<std::shared_ptr<PreviewSound>> held_;
    uint64_t seq_ = 0, starts_ = 0;
    PreviewSound* lastPosted_ = nullptr;
    double lastLength_ = 0, lastRatio_ = 1;
    Spsc<Cmd, 64> queue_;
    std::atomic<float> volume_{0.8f};
    // Audio thread.
    Voice cur_, old_;
    double gain_ = 0.8, gainTarget_ = 0.8;
    int route_ = -1;        // the slot of the last start (a fading voice follows it too)
    bool routed_ = false;   // render() ran this callback
    // Published by the audio thread.
    std::atomic<const PreviewSound*> inUse_[2] = {nullptr, nullptr};
    std::atomic<uint64_t> consumed_{0};
    std::atomic<double> posSeconds_{0}, lengthSeconds_{0};
    std::atomic<uint64_t> playingSeq_{0};
    std::atomic<int> flags_{0};  // 1 playing, 2 waiting, 4 through a track
};

}  // namespace caw
