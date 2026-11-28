// Play-ahead's thread: renders the tracks the callback handed over into their rings, and lets go when asked.
#include "play_ahead.h"

#include <algorithm>
#include <chrono>

#include "fp_mode.h"

namespace caw {

PlayAhead::PlayAhead(int64_t depth, bool thread, RenderFn render, void* ctx)
    : depth_(std::max<int64_t>(depth, 4 * AheadTrack::kBlock)), render_(render), ctx_(ctx),
      tracks_(new AheadTrack[kTracks]) {
    for (int i = 0; i < kTracks; ++i) tracks_[i].allocate(depth_);
    if (thread) thread_ = std::thread([this] { run(); });
}

PlayAhead::~PlayAhead() {
    quit_.store(true, std::memory_order_release);
    wakeSeq_.fetch_add(1, std::memory_order_release);
    wakeSeq_.notify_all();
    if (thread_.joinable()) thread_.join();
}

void PlayAhead::wake() noexcept {
    if (!sleeping_.load(std::memory_order_acquire)) return;
    wakeSeq_.fetch_add(1, std::memory_order_release);
    wakeSeq_.notify_one();
}

bool PlayAhead::service(AheadTrack& t, int64_t target, int64_t minBatch) noexcept {
    if (t.state.load(std::memory_order_acquire) != AheadTrack::Worker) return false;
    if (t.drain.load(std::memory_order_acquire)) {
        t.state.store(AheadTrack::Released, std::memory_order_release);
        return true;
    }
    if (stallForTest.load(std::memory_order_relaxed)) return false;
    const int64_t want = std::min(target, t.size) - t.fill();
    if (want < minBatch) return false;
    const int64_t batch = std::min(want, std::max<int64_t>(AheadTrack::kBlock, t.size / 4));
    const auto start = std::chrono::steady_clock::now();
    int64_t done = 0;
    // The drain flag is read before every chunk, so the callback gets the track back within one chunk's render.
    while (done < batch && t.room() && !t.drain.load(std::memory_order_acquire) &&
           !stallForTest.load(std::memory_order_relaxed)) {
        const int n = render_(ctx_, t, static_cast<int>(std::min<int64_t>(batch - done, AheadTrack::kBlock)));
        if (n <= 0) break;
        done += n;
    }
    workNs.fetch_add(static_cast<uint64_t>(
                         std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - start).count()),
                     std::memory_order_relaxed);
    workFrames.fetch_add(static_cast<uint64_t>(done), std::memory_order_relaxed);
    return done > 0;
}

void PlayAhead::serviceSync(AheadTrack& t, int64_t target) noexcept {
    // Each call renders one batch at most: to the target, or lets go.
    for (int guard = 0; guard < 64 && t.fill() < target && service(t, target, 1); ++guard)
        if (t.state.load(std::memory_order_relaxed) != AheadTrack::Worker) break;
    if (t.drain.load(std::memory_order_acquire)) service(t, target, 1);
}

void PlayAhead::run() noexcept {
    const ScopedFlushDenormals flush;  // as the callback renders (fp_mode.h): the same bits
    // An ordinary thread (no real-time policy): it has the ring's depth of slack, not the callback's deadline.
    // A batch is worth waking for once a ring has room for 1/16 of its depth (or a request to let go).
    const int64_t minBatch = std::max<int64_t>(AheadTrack::kBlock, depth_ / 16);
    while (!quit_.load(std::memory_order_acquire)) {
        const uint32_t seq = wakeSeq_.load(std::memory_order_acquire);
        bool did = false;
        for (int i = 0; i < kTracks; ++i) did = service(tracks_[i], depth_, minBatch) || did;
        if (did) continue;
        sleeping_.store(true, std::memory_order_seq_cst);
        // Something may have changed between the scan and the flag: look once more before sleeping.
        bool pending = false;
        for (int i = 0; i < kTracks && !pending; ++i) {
            AheadTrack& t = tracks_[i];
            if (t.state.load(std::memory_order_acquire) != AheadTrack::Worker) continue;
            pending = t.drain.load(std::memory_order_acquire) ||
                      (!stallForTest.load(std::memory_order_relaxed) && t.size - t.fill() >= minBatch);
        }
        if (!pending && !quit_.load(std::memory_order_acquire)) wakeSeq_.wait(seq, std::memory_order_acquire);
        sleeping_.store(false, std::memory_order_relaxed);
    }
}

}  // namespace caw
