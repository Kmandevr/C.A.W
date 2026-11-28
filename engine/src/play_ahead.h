// Play-ahead (docs/engine.md): tracks nobody touches rendered before they are heard, into rings a dedicated thread fills.
#pragma once
#include <atomic>
#include <cstdint>
#include <memory>
#include <thread>

namespace caw {

struct SongTime;
struct ChainProfile;
struct PartProfile;

// The transport as a track's instrument and inserts read it for one chunk (Engine::planTrack, instrumentNotes,
// runInstrument, runInserts). The Engine fills its own from its members at each chunk; an ahead track's producer
// steps a copy with the same wrap rule as Engine::process.
struct TrackClock {
    int64_t g = 0;          // the chunk's first sample in the project loop
    int64_t epoch = 0;      // project loops completed since Play
    const SongTime* song = nullptr;
    double stepLen = 0;
    int64_t loopLen = 0;
    bool timeConstant = true;
    double bpm = 120;
    int beatsPerBar = 4;
    const double* steps = nullptr;  // with a tempo map: the song step at each frame of the chunk
    bool playing = false;
    bool previewChunk = false;
    ChainProfile* profile = nullptr;
    uint32_t seed = 0;
    int stopFade = 0;
    uint64_t touchEpoch = 0;
    int64_t chunk = 0;      // the chunk counter keys are stamped with (an ahead track's: one no key ever has)
    bool loopRange = false;
    int64_t loopFrom = 0, loopTo = 0;
    // On the ahead renderer: no project modulation, per-note FX, device MIDI or Benchmark parts (an ahead track has
    // none of them, Engine::aheadEligible).
    bool ahead = false;
    PartProfile* parts() const noexcept;  // the Benchmark's parts (null: none); engine.h
    // Where playback from g goes back (Engine::wrapAt).
    int64_t wrapAt() const noexcept { return loopRange && g < loopTo ? loopTo : loopLen; }
    // Moves on by m frames, as Engine::process does after a chunk.
    void advance(int m) noexcept {
        const int64_t wrap = wrapAt();
        g += m;
        if (g >= wrap) {
            g = loopRange ? loopFrom : 0;
            ++epoch;
        }
    }
};

// One ahead track: a ring of its pre-fader audio and its producer's state. Single producer (the ahead thread, or the
// callback while it builds the lead), single consumer (the callback). Allocated off the audio thread.
struct AheadTrack {
    static constexpr int kBlock = 64;
    // Free: no slot. Lead: the callback renders it ahead itself (twice its share) until the ring holds the lead.
    // Worker: the ahead thread renders it. Released: the ahead thread saw drain and let go; the callback owns the
    // slot's instrument and inserts again and plays out what the ring holds.
    enum State : int { Free, Lead, Worker, Released };
    std::atomic<int> state{Free};
    std::atomic<bool> drain{false};  // the callback asks the producer to stop and let go

    // Each chunk the producer rendered: its first frame (on the ring's frame count), the frame in the layer's loop it
    // started on and the loop's length, so the callback publishes the progress meter as the frames are heard.
    struct Meta {
        int64_t at = 0;
        int64_t n0 = 0;
        double layerLen = 1;
    };
    int64_t size = 0;      // frames the ring holds at most (the depth)
    int64_t metaSize = 0;
    std::unique_ptr<float[]> l, r;
    std::unique_ptr<Meta[]> meta;
    std::atomic<int64_t> written{0}, read{0};          // frames
    std::atomic<int64_t> metaWritten{0}, metaRead{0};  // chunks

    // The producer's own (whoever produces).
    int slot = -1;
    void* slotRef = nullptr;  // the Engine's Slot (slots never move)
    TrackClock clock;
    double steps[kBlock] = {};
    float bufL[kBlock] = {}, bufR[kBlock] = {};

    // The callback's own.
    int64_t pos = 0;        // frames the playhead moved through since the track went ahead
    bool underrun = false;  // fading out or silent until the producer lets go
    int fadeLeft = 0, fadeLen = 0;
    bool dropped = false;   // a seek, loop, tempo or project change: nothing more from the ring is heard
    int64_t lastN0 = 0;     // the last frame heard's place in the layer's loop, and the loop's length
    double lastLayerLen = 1;
    int parked = 0;         // commands waiting for the ring's end (Engine::aheadInbox_)

    void allocate(int64_t frames) {
        size = frames;
        metaSize = frames / 16 + 4;
        l.reset(new float[static_cast<size_t>(frames)]());
        r.reset(new float[static_cast<size_t>(frames)]());
        meta.reset(new Meta[static_cast<size_t>(metaSize)]());
    }
    // The callback, with the track Free (no producer): empty.
    void clear() noexcept {
        written.store(0, std::memory_order_relaxed);
        read.store(0, std::memory_order_relaxed);
        metaWritten.store(0, std::memory_order_relaxed);
        metaRead.store(0, std::memory_order_relaxed);
        drain.store(false, std::memory_order_relaxed);
        pos = 0;
        underrun = dropped = false;
        fadeLeft = fadeLen = 0;
    }
    int64_t fill() const noexcept {
        return written.load(std::memory_order_acquire) - read.load(std::memory_order_relaxed);
    }
    // Producer: room for a chunk of up to kBlock frames.
    bool room() const noexcept {
        return written.load(std::memory_order_relaxed) + kBlock - read.load(std::memory_order_acquire) <= size &&
               metaWritten.load(std::memory_order_relaxed) - metaRead.load(std::memory_order_acquire) < metaSize;
    }
    // Producer: a rendered chunk (room() was true).
    void push(const float* L, const float* R, int m, int64_t n0, double layerLen) noexcept {
        const int64_t w = written.load(std::memory_order_relaxed);
        const int64_t mw = metaWritten.load(std::memory_order_relaxed);
        meta[mw % metaSize] = {w, n0, layerLen};
        for (int i = 0; i < m; ++i) {
            const int64_t at = (w + i) % size;
            l[at] = L[i];
            r[at] = R[i];
        }
        metaWritten.store(mw + 1, std::memory_order_release);
        written.store(w + m, std::memory_order_release);
    }
    // Consumer: m frames (at most fill()) into L/R (null: dropped), and the last one's place in the layer's loop.
    void pop(float* L, float* R, int m, int64_t& n0Last, double& layerLen) noexcept {
        const int64_t rd = read.load(std::memory_order_relaxed);
        if (L)
            for (int i = 0; i < m; ++i) {
                const int64_t at = (rd + i) % size;
                L[i] = l[at];
                R[i] = r[at];
            }
        const int64_t last = rd + m - 1;
        int64_t mr = metaRead.load(std::memory_order_relaxed);
        const int64_t mw = metaWritten.load(std::memory_order_acquire);
        while (mr + 1 < mw && meta[(mr + 1) % metaSize].at <= last) ++mr;
        const Meta& e = meta[mr % metaSize];
        n0Last = e.n0 + (last - e.at);
        layerLen = e.layerLen;
        metaRead.store(mr, std::memory_order_release);
        read.store(rd + m, std::memory_order_release);
    }
};

// The ahead thread and the tracks it renders. Built on the control thread (setPlayAhead); the callback hands tracks
// to it and takes them back without waiting (AheadTrack::state, drain).
class PlayAhead {
public:
    static constexpr int kTracks = 8;  // tracks ahead at once at most (their rings are allocated up front)
    // Renders the track's next chunk (at most `most` frames, at most kBlock) into its ring; returns its frames.
    using RenderFn = int (*)(void* ctx, AheadTrack& t, int most) noexcept;
    // depth: each ring's frames; thread: false for tests, which fill the rings on the callback (serviceSync).
    PlayAhead(int64_t depth, bool thread, RenderFn render, void* ctx);
    ~PlayAhead();
    PlayAhead(const PlayAhead&) = delete;
    PlayAhead& operator=(const PlayAhead&) = delete;

    AheadTrack& track(int i) noexcept { return tracks_[i]; }
    bool threaded() const noexcept { return thread_.joinable(); }
    int64_t depth() const noexcept { return depth_; }
    // Callback: a track was handed over or frames were played (the thread sleeps while every ring is full).
    void wake() noexcept;
    // Tests (no thread): on the calling thread, a Worker track to `target` frames in its ring, or let go.
    void serviceSync(AheadTrack& t, int64_t target) noexcept;

    std::atomic<uint64_t> workNs{0}, workFrames{0};  // the producer's time and the frames it rendered
    std::atomic<bool> stallForTest{false};           // the producer renders nothing while set (underrun tests)

private:
    // A Worker track: let go if asked, else render up to `target` frames ahead in batches of at most a quarter of
    // the ring; true if it did anything.
    bool service(AheadTrack& t, int64_t target, int64_t minBatch) noexcept;
    void run() noexcept;

    const int64_t depth_;
    RenderFn render_;
    void* ctx_;
    std::unique_ptr<AheadTrack[]> tracks_;
    std::atomic<bool> quit_{false};
    std::atomic<uint32_t> wakeSeq_{0};
    std::atomic<bool> sleeping_{false};
    std::thread thread_;
};

}  // namespace caw
