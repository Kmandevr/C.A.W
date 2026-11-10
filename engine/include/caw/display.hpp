// Live display data from the audio thread to a UI (#173): a lock-free, double-buffered float block per instance.
#pragma once

#include <atomic>
#include <cstdint>

namespace caw {

// The most floats one display block holds (an EQ's two 128-bin spectra and its bands fit with room to spare).
inline constexpr uint32_t kMaxDisplayFloats = 1024;

// A component's live picture for its UI: a spectrum, gain reduction, levels, a position. The audio thread
// publishes a small block of floats now and then (about 60 times a second is plenty: DisplayClock); a UI
// thread reads the latest whole block at any time. Neither side ever waits for the other or allocates.
//
// How: two slots, each guarded by its own sequence counter (a seqlock). publish() writes the slot the reader
// is not pointed at, its counter odd while it writes and even once done, then points the reader at it. read()
// copies the slot it is pointed at and keeps the copy only if that slot's counter was even and unchanged
// across the copy; a writer would have to publish twice during one copy to disturb it, so a read is
// practically never retried, and it gives up (returns 0) after a few tries rather than wait. Every float is
// an atomic with relaxed order (a plain load or store on every CPU C.A.W. runs on), so there is no data race.
//
// Capacity is in floats (at most kMaxDisplayFloats); the object holds 2 x Capacity floats inline, so it is
// part of the processor and needs no allocation.
template <uint32_t Capacity>
class DisplayBuffer {
    static_assert(Capacity > 0 && Capacity <= kMaxDisplayFloats, "a display block holds 1..kMaxDisplayFloats floats");
    static_assert(std::atomic<float>::is_always_lock_free && std::atomic<uint32_t>::is_always_lock_free);

public:
    static constexpr uint32_t capacity() noexcept { return Capacity; }

    // Audio thread (one writer): makes values[0..count) the latest block (count is held to Capacity).
    void publish(const float* values, uint32_t count) noexcept {
        if (!values) count = 0;
        if (count > Capacity) count = Capacity;
        const uint32_t next = (latest_.load(std::memory_order_relaxed) + 1u) & 1u;
        Slot& s = slots_[next];
        const uint32_t v = s.version.load(std::memory_order_relaxed);
        s.version.store(v + 1u, std::memory_order_relaxed);  // odd: being written
        std::atomic_thread_fence(std::memory_order_release);
        for (uint32_t i = 0; i < count; ++i) s.data[i].store(values[i], std::memory_order_relaxed);
        s.count.store(count, std::memory_order_relaxed);
        s.version.store(v + 2u, std::memory_order_release);  // even: whole
        latest_.store(next, std::memory_order_release);
        published_.store(published_.load(std::memory_order_relaxed) + 1u, std::memory_order_release);
    }

    // Any other thread: copies the latest block into out (at most max floats) and returns how many floats it
    // copied; 0 before the first publish, or in the (practically never seen) case that the writer kept
    // overwriting the slot during every try.
    uint32_t read(float* out, uint32_t max) const noexcept {
        if (!out || max == 0 || published_.load(std::memory_order_acquire) == 0) return 0;
        for (int attempt = 0; attempt < 4; ++attempt) {
            const Slot& s = slots_[latest_.load(std::memory_order_acquire) & 1u];
            const uint32_t v = s.version.load(std::memory_order_acquire);
            if (v & 1u) continue;
            uint32_t n = s.count.load(std::memory_order_relaxed);
            if (n > Capacity) n = Capacity;
            if (n > max) n = max;
            for (uint32_t i = 0; i < n; ++i) out[i] = s.data[i].load(std::memory_order_relaxed);
            std::atomic_thread_fence(std::memory_order_acquire);
            if (s.version.load(std::memory_order_relaxed) == v) return n;
        }
        return 0;
    }

    // How many blocks have been published (a UI can skip a repaint when it hasn't moved).
    uint32_t sequence() const noexcept { return published_.load(std::memory_order_acquire); }

    // Back to "nothing published" (control thread, while the audio thread does not publish: at activate).
    void clear() noexcept {
        published_.store(0, std::memory_order_release);
        for (Slot& s : slots_) s.count.store(0, std::memory_order_relaxed);
    }

private:
    struct Slot {
        std::atomic<uint32_t> version{0};
        std::atomic<uint32_t> count{0};
        std::atomic<float> data[Capacity] = {};
    };
    Slot slots_[2];
    std::atomic<uint32_t> latest_{0};
    std::atomic<uint32_t> published_{0};
};

// When to publish: about `hz` times a second, counted in frames, so a processor publishes from its block loop
// without reading a clock. A display is not sound: when it fires may depend on the block size.
class DisplayClock {
public:
    void prepare(double sampleRate, double hz = 60.0) noexcept {
        const double frames = sampleRate > 0.0 && hz > 0.0 ? sampleRate / hz : 800.0;
        period_ = frames < 1.0 ? 1u : static_cast<uint32_t>(frames);
        left_ = 0;  // the first block publishes
    }
    // True when a block of `frames` reaches the next publish time.
    // The leftover carries over, so blocks longer than half the period still average `hz` (at most one
    // publish per block).
    bool tick(uint32_t frames) noexcept {
        left_ -= static_cast<int64_t>(frames);
        if (left_ > 0) return false;
        left_ += period_;
        if (left_ <= 0) left_ = period_;  // a block longer than the period: once per block
        return true;
    }
    uint32_t period() const noexcept { return period_; }

private:
    uint32_t period_ = 800;
    int64_t left_ = 0;
};

}  // namespace caw
