// Play-ahead's thread: renders the tracks the callback handed over into their rings, and lets go when asked.
#include "play_ahead.h"

#include <algorithm>
#include <chrono>

#include "fp_mode.h"
#include "thread_tuning.h"

namespace caw {

PlayAhead::PlayAhead(int64_t depth, int64_t lead, bool thread, RenderFn render, void* ctx)
    : depth_(std::max<int64_t>(depth, 4 * AheadTrack::kBlock)), lead_(std::max<int64_t>(lead, 2 * AheadTrack::kBlock)),
      render_(render), ctx_(ctx), tracks_(new AheadTrack[kTracks]) {
    for (int i = 0; i < kTracks; ++i) tracks_[i].allocate(depth_);
    if (thread) thread_ = std::thread([this] { run(); });
}

PlayAhead::~PlayAhead() {
    quit_.store(true, std::memory_order_release);
    if (thread_.joinable()) thread_.join();
}

void PlayAhead::noteCallback(int32_t tid, int policy, int priority, int nice) noexcept {
    cbTid_.store(tid, std::memory_order_relaxed);
    cbPolicy_.store(policy, std::memory_order_relaxed);
    cbPriority_.store(priority, std::memory_order_relaxed);
    cbNice_.store(nice, std::memory_order_relaxed);
    cbGen_.fetch_add(1, std::memory_order_release);
}

bool PlayAhead::service(AheadTrack& t, int64_t target, int64_t minBatch, int64_t batch) noexcept {
    if (t.state.load(std::memory_order_acquire) != AheadTrack::Worker) return false;
    if (t.drain.load(std::memory_order_acquire)) {
        t.state.store(AheadTrack::Released, std::memory_order_release);
        return true;
    }
    if (stallForTest.load(std::memory_order_relaxed)) return false;
    const int64_t want = std::min(target, t.size) - t.fill();
    if (want < minBatch) return false;
    batch = std::min(want, std::max<int64_t>(AheadTrack::kBlock, batch));
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
    for (int guard = 0; guard < 64 && t.fill() < target && service(t, target, 1, t.size / 4); ++guard)
        if (t.state.load(std::memory_order_relaxed) != AheadTrack::Worker) break;
    if (t.drain.load(std::memory_order_acquire)) service(t, target, 1, 0);
}

void PlayAhead::run() noexcept {
    using namespace std::chrono;
    const ScopedFlushDenormals flush;  // as the callback renders (fp_mode.h): the same bits
    tuning::WorkerState tuning;
    uint32_t tunedGen = 0;
    // A batch is worth starting once a ring has room for 1/16 of its depth (or a request to let go).
    const int64_t minBatch = std::max<int64_t>(AheadTrack::kBlock, depth_ / 16);
    auto windowStart = steady_clock::now();
    uint64_t windowNs = workNs.load(std::memory_order_relaxed);
    while (!quit_.load(std::memory_order_acquire)) {
        // The callback's scheduling, as the mix pool's workers follow it: a priority never above it.
        if (const uint32_t gen = cbGen_.load(std::memory_order_acquire); gen != tunedGen) {
            tunedGen = gen;
            tuning::CallbackThread cb;
            cb.known = true;
            cb.tid = cbTid_.load(std::memory_order_relaxed);
            cb.policy = cbPolicy_.load(std::memory_order_relaxed);
            cb.priority = cbPriority_.load(std::memory_order_relaxed);
            cb.nice = cbNice_.load(std::memory_order_relaxed);
            tuning::tuneWorker(cb, tuning);
        }
        // The ring with the least audio first, one batch each, so a new track's short lead is topped up before
        // a full one's: a batch is at most lead / (2 × tracks ahead).
        int active = 0;
        for (int i = 0; i < kTracks; ++i)
            if (tracks_[i].state.load(std::memory_order_acquire) == AheadTrack::Worker) ++active;
        const int64_t batch = std::max<int64_t>(2 * AheadTrack::kBlock, lead_ / (2 * std::max(1, active)));
        bool did = false;
        for (int round = 0; round < active; ++round) {
            AheadTrack* next = nullptr;
            int64_t least = INT64_MAX;
            for (int i = 0; i < kTracks; ++i) {
                AheadTrack& t = tracks_[i];
                if (t.state.load(std::memory_order_acquire) != AheadTrack::Worker) continue;
                if (t.drain.load(std::memory_order_acquire)) {
                    next = &t;
                    break;
                }
                const int64_t f = t.fill();
                if (t.size - f >= minBatch && f < least) {
                    least = f;
                    next = &t;
                }
            }
            if (!next || !service(*next, depth_, minBatch, batch)) break;
            did = true;
        }
        const auto now = steady_clock::now();
        if (now - windowStart >= milliseconds(250)) {
            const uint64_t ns = workNs.load(std::memory_order_relaxed);
            busy_.store(static_cast<float>(static_cast<double>(ns - windowNs) /
                                           static_cast<double>(duration_cast<nanoseconds>(now - windowStart).count())),
                        std::memory_order_relaxed);
            windowStart = now;
            windowNs = ns;
        }
        // Nothing to do: a short sleep. The callback never wakes this thread (no system call on the audio thread);
        // a ring has at least its lead (up to 85 ms) and a 300 ms depth, so 1 ms is far inside it.
        if (!did) std::this_thread::sleep_for(milliseconds(active > 0 ? 1 : 5));
    }
    tuning::untuneWorker(tuning);
}

}  // namespace caw
