// The mixer's real-time worker pool (speed phase 5c): claim loop, spin then sleep, start and stop.
#include "mix_pool.h"

#include <algorithm>
#include <chrono>
#include <system_error>

#include "fp_mode.h"

#if defined(__x86_64__) || defined(_M_X64) || defined(__i386__) || defined(_M_IX86)
#include <immintrin.h>
#define CAW_POOL_PAUSE() _mm_pause()
#elif (defined(__aarch64__) || defined(__arm__)) && (defined(__GNUC__) || defined(__clang__))
#define CAW_POOL_PAUSE() __asm__ __volatile__("yield" ::: "memory")
#elif defined(_M_ARM64) || defined(_M_ARM)
#include <intrin.h>
#define CAW_POOL_PAUSE() __yield()
#else
#define CAW_POOL_PAUSE() std::this_thread::yield()
#endif

namespace caw {

namespace {

thread_local uint32_t tLane = 0;

// How long an idle worker spins before it sleeps, unless parked: longer than the gap between two levels of a chunk
// and between the chunks of one callback (the master stage and the next chunk's planning, tens of microseconds),
// shorter than the gap between callbacks.
constexpr auto kSpin = std::chrono::microseconds(50);

constexpr uint64_t kIndexMask = 0xFFFFu;

// Tests only (setDelayForTest): a busy wait of 0..max microseconds from a per-thread xorshift.
void testDelay(uint32_t maxMicros, uint64_t& rng) noexcept {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    const auto until = std::chrono::steady_clock::now() + std::chrono::microseconds(rng % (uint64_t{maxMicros} + 1));
    while (std::chrono::steady_clock::now() < until) CAW_POOL_PAUSE();
}

}  // namespace

uint32_t MixPool::defaultWorkers() noexcept {
    const unsigned hw = std::thread::hardware_concurrency();
    return hw <= 1 ? 0u : std::min<uint32_t>(hw - 1, 3u);
}

uint32_t MixPool::lane() noexcept { return tLane; }

MixPool::~MixPool() { stop(); }

bool MixPool::start(uint32_t workers) {
    stop();
    workers = std::min(workers, kMaxWorkers);
    stop_.store(false, std::memory_order_relaxed);
    workerTasks_.store(0, std::memory_order_relaxed);
    try {
        threads_.reserve(workers);
        for (uint32_t w = 0; w < workers; ++w) threads_.emplace_back([this, w] { loop(w + 1); });
    } catch (...) {  // std::system_error (no thread) or std::bad_alloc
        stop();
        return false;
    }
    count_ = workers;
    return true;
}

void MixPool::stop() noexcept {
    if (threads_.empty()) return;
    stop_.store(true, std::memory_order_seq_cst);
    wake_.fetch_add(1, std::memory_order_seq_cst);
    wake_.notify_all();
    for (std::thread& t : threads_)
        if (t.joinable()) t.join();
    threads_.clear();
    count_ = 0;
}

bool MixPool::claimOne(bool worker) noexcept {
    uint64_t c = claim_.load(std::memory_order_acquire);
    for (;;) {
        const uint32_t count = static_cast<uint32_t>((c >> 16) & kIndexMask);
        const uint32_t index = static_cast<uint32_t>(c & kIndexMask);
        if (index >= count) return false;
        // The epoch in the word makes a claim read during an earlier run fail here instead of taking an index.
        if (claim_.compare_exchange_weak(c, c + 1, std::memory_order_acq_rel, std::memory_order_acquire)) {
            task_(context_, index);
            if (worker) workerTasks_.fetch_add(1, std::memory_order_relaxed);
            done_.fetch_add(1, std::memory_order_release);
            return true;
        }
    }
}

void MixPool::run(Task task, void* context, uint32_t count) noexcept {
    if (count_ == 0 || count < 2 || count > kIndexMask) {
        for (uint32_t i = 0; i < count; ++i) task(context, i);
        return;
    }
    task_ = task;
    context_ = context;
    done_.store(0, std::memory_order_relaxed);
    const uint32_t epoch = ++epoch_;
    claim_.store(static_cast<uint64_t>(epoch) << 32 | static_cast<uint64_t>(count) << 16, std::memory_order_release);
    // seq_cst with the sleepers' count: either a sleeping worker is seen here (and woken) or it sees the new epoch
    // before it sleeps.
    wake_.store(epoch, std::memory_order_seq_cst);
    if (sleepers_.load(std::memory_order_seq_cst) != 0) wake_.notify_all();
    while (claimOne(false)) {
    }
    while (done_.load(std::memory_order_acquire) != count) CAW_POOL_PAUSE();
}

void MixPool::loop(uint32_t lane) noexcept {
    tLane = lane;
    const ScopedFlushDenormals flushDenormals;  // per thread, as on the callback (fp_mode.h): the nodes' arithmetic
    uint64_t rng = 0x9E3779B97F4A7C15ull * (lane + 1);
    uint32_t seen = wake_.load(std::memory_order_acquire);
    while (!stop_.load(std::memory_order_acquire)) {
        for (;;) {
            if (const uint32_t d = delayMicros_.load(std::memory_order_relaxed)) testDelay(d, rng);
            if (!claimOne(true)) break;
        }
        // Idle: spin a little for the next run, then sleep until one is published.
        if (!parked_.load(std::memory_order_relaxed)) {
            const auto until = std::chrono::steady_clock::now() + kSpin;
            for (uint32_t n = 0; wake_.load(std::memory_order_acquire) == seen; ++n) {
                CAW_POOL_PAUSE();
                if ((n & 63u) == 63u && std::chrono::steady_clock::now() >= until) break;
            }
        }
        if (wake_.load(std::memory_order_acquire) == seen) {
            sleepers_.fetch_add(1, std::memory_order_seq_cst);
            if (wake_.load(std::memory_order_seq_cst) == seen) wake_.wait(seen, std::memory_order_seq_cst);
            sleepers_.fetch_sub(1, std::memory_order_seq_cst);
        }
        seen = wake_.load(std::memory_order_acquire);
    }
}

}  // namespace caw
