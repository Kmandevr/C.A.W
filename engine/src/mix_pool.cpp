// The mixer's real-time worker pool (speed phases 5c, 5d): claim loop, spin through a callback then sleep, tuning.
#include "mix_pool.h"

#include <algorithm>
#include <chrono>
#include <cstring>
#include <limits>
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
// The pool start the calling (callback) thread last described itself to (MixPool::noteCallbackThread).
thread_local uint64_t tNotedStart = 0;
std::atomic<uint64_t> gStarts{0};

constexpr uint64_t kIndexMask = 0xFFFFu;
constexpr uint32_t kCoreSampleEvery = 32;  // callbacks between two reads of the callback's core

int64_t nowNs() noexcept {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// Tests only (setDelayForTest): a busy wait of 0..max microseconds from a per-thread xorshift.
void testDelay(uint32_t maxMicros, uint64_t& rng) noexcept {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    const auto until = std::chrono::steady_clock::now() + std::chrono::microseconds(rng % (uint64_t{maxMicros} + 1));
    while (std::chrono::steady_clock::now() < until) CAW_POOL_PAUSE();
}

// Touches about 64 KB of the worker's stack before it serves, so its first nodes don't take page faults.
#if defined(__GNUC__) || defined(__clang__)
__attribute__((noinline))
#elif defined(_MSC_VER)
__declspec(noinline)
#endif
void touchStack() noexcept {
    volatile unsigned char page[64 * 1024];
    for (size_t i = 0; i < sizeof page; i += 256) page[i] = 0;
}

}  // namespace

uint32_t MixPool::defaultWorkers() noexcept { return tuning::poolWorkers(tuning::topology(), kMaxWorkers); }

uint32_t MixPool::lane() noexcept { return tLane; }

MixPool::~MixPool() { stop(); }

bool MixPool::start(uint32_t workers, Kind kind) {
    stop();
    workers = std::min(workers, kMaxWorkers);
    kind_ = kind;
    startId_ = gStarts.fetch_add(1, std::memory_order_relaxed) + 1;
    stop_.store(false, std::memory_order_relaxed);
    workerTasks_.store(0, std::memory_order_relaxed);
    workerNs_.store(0, std::memory_order_relaxed);
    waitNs_ = 0;
    active_.store(kMaxWorkers, std::memory_order_relaxed);
    tidsReady_.store(0, std::memory_order_relaxed);
    tuned_.store(0, std::memory_order_relaxed);
    callbackGen_.store(0, std::memory_order_relaxed);
    callbackCpu_.store(-1, std::memory_order_relaxed);
    callbacks_ = 0;
    spinUntil_.store(0, std::memory_order_relaxed);
    try {
        threads_.reserve(workers);
        for (uint32_t w = 0; w < workers; ++w) threads_.emplace_back([this, w] { loop(w + 1); });
    } catch (...) {  // std::system_error (no thread) or std::bad_alloc
        stop();
        return false;
    }
    count_ = workers;
    if (kind == Kind::Live) {
        // The workers' ids before the first callback, so it can hand them to the hint with its own (bounded: a
        // worker that is slow to start is left out of the hint, nothing else).
        const auto until = std::chrono::steady_clock::now() + std::chrono::milliseconds(200);
        while (tidsReady_.load(std::memory_order_acquire) < workers && std::chrono::steady_clock::now() < until)
            std::this_thread::yield();
        hint_ = tuning::hintOpen();
    }
    return true;
}

void MixPool::stop() noexcept {
    if (hint_) {
        tuning::hintClose(hint_);
        hint_ = nullptr;
    }
    if (threads_.empty()) return;
    stop_.store(true, std::memory_order_seq_cst);
    wake_.fetch_add(1, std::memory_order_seq_cst);
    wake_.notify_all();
    active_.store(kStopping, std::memory_order_seq_cst);  // a worker Auto had set aside wakes too
    active_.notify_all();
    for (std::thread& t : threads_)
        if (t.joinable()) t.join();
    threads_.clear();
    count_ = 0;
}

void MixPool::setCallbackMmcss(bool mmcss) noexcept {
    if (mmcss_.exchange(mmcss, std::memory_order_relaxed) != mmcss && cbTid_.load(std::memory_order_relaxed) != 0)
        callbackGen_.fetch_add(1, std::memory_order_release);  // the workers retune at their next idle point
}

bool MixPool::claimOne(uint32_t lane) noexcept {
    uint64_t c = claim_.load(std::memory_order_acquire);
    for (;;) {
        const uint32_t count = static_cast<uint32_t>((c >> 16) & kIndexMask);
        const uint32_t index = static_cast<uint32_t>(c & kIndexMask);
        if (index >= count) return false;
        // The epoch in the word makes a claim read during an earlier run fail here instead of taking an index.
        if (claim_.compare_exchange_weak(c, c + 1, std::memory_order_acq_rel, std::memory_order_acquire)) {
            if (lane != 0) {
                if (const uint32_t hold = holdMicros_.load(std::memory_order_relaxed)) {
                    const int64_t until = nowNs() + int64_t{hold} * 1000;
                    while (nowNs() < until) CAW_POOL_PAUSE();
                }
                const int64_t t0 = nowNs();
                task_(context_, index);
                workerNs_.fetch_add(nowNs() - t0, std::memory_order_relaxed);
                workerTasks_.fetch_add(1, std::memory_order_relaxed);
            } else {
                task_(context_, index);
            }
            done_.fetch_add(1, std::memory_order_release);
            return true;
        }
    }
}

void MixPool::publishWake() noexcept {
    // seq_cst with the sleepers' count: either a sleeping worker is seen here (and woken) or it sees the new value
    // before it sleeps.
    wake_.fetch_add(1, std::memory_order_seq_cst);
    if (sleepers_.load(std::memory_order_seq_cst) != 0) wake_.notify_all();
}

void MixPool::noteCallbackThread() noexcept {
    const tuning::CallbackThread t = tuning::describeCallbackThread();
    cbTid_.store(t.tid, std::memory_order_relaxed);
    cbPolicy_.store(t.policy, std::memory_order_relaxed);
    cbPriority_.store(t.priority, std::memory_order_relaxed);
    cbNice_.store(t.nice, std::memory_order_relaxed);
    callbackApplied_.store(t.applied, std::memory_order_relaxed);
    callbackGen_.fetch_add(1, std::memory_order_release);
    if (hint_) {
        int32_t tids[1 + kMaxWorkers];
        size_t n = 0;
        if (t.tid > 0) tids[n++] = t.tid;
        for (uint32_t w = 0; w < count_; ++w)
            if (const int32_t id = workerTids_[w].load(std::memory_order_relaxed); id > 0) tids[n++] = id;
        tuning::hintThreads(hint_, tids, n);  // atomics only: the hint's own thread makes the system calls
    }
}

void MixPool::beginCallback(bool wake) noexcept {
    if (kind_ == Kind::Live) {
        // Once per callback thread and start: its id, policy and priority (cheap calls), for the workers' tuning.
        if (tNotedStart != startId_) {
            tNotedStart = startId_;
            noteCallbackThread();
        }
        if (callbacks_++ % kCoreSampleEvery == 0) callbackCpu_.store(tuning::currentCpu(), std::memory_order_relaxed);
    }
    if (count_ == 0 || !wake) return;
    spinUntil_.store(std::numeric_limits<int64_t>::max(), std::memory_order_relaxed);
    publishWake();  // sleeping workers wake while the callback plans its first chunk
}

void MixPool::endCallback() noexcept {
    if (count_ == 0) return;
    spinUntil_.store(nowNs() + int64_t{kGraceMicros} * 1000, std::memory_order_relaxed);
}

void MixPool::takeTimes(int64_t& waitNs, int64_t& workerNs) noexcept {
    waitNs = waitNs_;
    waitNs_ = 0;
    workerNs = workerNs_.exchange(0, std::memory_order_relaxed);
}

void MixPool::begin(Task task, void* context, uint32_t count) noexcept {
    task_ = task;
    context_ = context;
    pending_ = count;
    published_ = !(count_ == 0 || count < 2 || count > kIndexMask);
    if (!published_) return;  // finish() runs them here, in order
    done_.store(0, std::memory_order_relaxed);
    const uint32_t epoch = ++epoch_;
    claim_.store(static_cast<uint64_t>(epoch) << 32 | static_cast<uint64_t>(count) << 16, std::memory_order_release);
    // From the first level of a callback on, the workers spin through the rest of it (endCallback ends that).
    if (spinUntil_.load(std::memory_order_relaxed) != std::numeric_limits<int64_t>::max())
        spinUntil_.store(std::numeric_limits<int64_t>::max(), std::memory_order_relaxed);
    publishWake();
}

void MixPool::finish() noexcept {
    const uint32_t count = pending_;
    pending_ = 0;
    if (!published_) {
        for (uint32_t i = 0; i < count; ++i) task_(context_, i);
        return;
    }
    published_ = false;
    if (holdMicros_.load(std::memory_order_relaxed) != 0) {  // tests: let a worker claim first (up to 2 ms)
        const int64_t until = nowNs() + 2'000'000;
        while ((claim_.load(std::memory_order_acquire) & kIndexMask) == 0 && nowNs() < until) CAW_POOL_PAUSE();
    }
    while (claimOne(0)) {
    }
    if (done_.load(std::memory_order_acquire) != count) {
        const int64_t t0 = nowNs();
        while (done_.load(std::memory_order_acquire) != count) CAW_POOL_PAUSE();
        waitNs_ += nowNs() - t0;
    }
}

void MixPool::loop(uint32_t lane) noexcept {
    tLane = lane;
    const ScopedFlushDenormals flushDenormals;  // per thread, as on the callback (fp_mode.h): the nodes' arithmetic
    touchStack();
    workerTids_[lane - 1].store(tuning::currentThreadId(), std::memory_order_relaxed);
    tidsReady_.fetch_add(1, std::memory_order_release);
    tuning::WorkerState tuning;
    uint32_t tunedGen = 0;
    uint64_t rng = 0x9E3779B97F4A7C15ull * (lane + 1);
    uint32_t seen = wake_.load(std::memory_order_acquire);
    while (!stop_.load(std::memory_order_acquire)) {
        const uint32_t active = active_.load(std::memory_order_acquire);
        if (lane > active) {  // not one of Auto's workers now: sleep until that changes (or the pool stops)
            active_.wait(active, std::memory_order_acquire);
            seen = wake_.load(std::memory_order_acquire);
            continue;
        }
        for (;;) {
            if (const uint32_t d = delayMicros_.load(std::memory_order_relaxed)) testDelay(d, rng);
            if (!claimOne(lane)) break;
        }
        // Tuning (Live), outside any task, so a slow system call never holds a level back: the callback has
        // described itself, or its thread changed.
        if (kind_ == Kind::Live) {
            const uint32_t gen = callbackGen_.load(std::memory_order_acquire);
            if (gen != tunedGen) {
                tunedGen = gen;
                tuning::CallbackThread cb;
                cb.known = true;
                cb.tid = cbTid_.load(std::memory_order_relaxed);
                cb.policy = cbPolicy_.load(std::memory_order_relaxed);
                cb.priority = cbPriority_.load(std::memory_order_relaxed);
                cb.nice = cbNice_.load(std::memory_order_relaxed);
                cb.mmcss = mmcss_.load(std::memory_order_relaxed);
                tuned_.fetch_or(tuning::tuneWorker(cb, tuning), std::memory_order_relaxed);
            }
        }
        // Idle: spin while a callback runs (and a little after), never longer than kMaxSpinMicros, unless parked
        // then sleep until a run or a callback is published.
        if (!parked_.load(std::memory_order_relaxed)) {
            const int64_t cap = nowNs() + int64_t{kMaxSpinMicros} * 1000;
            for (uint32_t n = 0; wake_.load(std::memory_order_acquire) == seen; ++n) {
                CAW_POOL_PAUSE();
                if ((n & 63u) == 63u) {
                    // Gives the core to anything else waiting for it (the system's own threads), so it need not
                    // preempt a thread that is running a node; returns at once when nothing waits.
                    std::this_thread::yield();
                    const int64_t t = nowNs();
                    if (t >= cap || t >= spinUntil_.load(std::memory_order_relaxed) ||
                        parked_.load(std::memory_order_relaxed) || stop_.load(std::memory_order_relaxed))
                        break;
                }
            }
        }
        if (wake_.load(std::memory_order_acquire) == seen) {
            sleepers_.fetch_add(1, std::memory_order_seq_cst);
            if (wake_.load(std::memory_order_seq_cst) == seen) wake_.wait(seen, std::memory_order_seq_cst);
            sleepers_.fetch_sub(1, std::memory_order_seq_cst);
        }
        seen = wake_.load(std::memory_order_acquire);
    }
    tuning::untuneWorker(tuning);
}

}  // namespace caw
