// Fixed-size lock-free single-producer single-consumer queue for messages between the control and audio threads.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>

namespace caw {

template <class T, size_t N>
class Spsc {
    static_assert((N & (N - 1)) == 0, "capacity must be a power of two");

public:
    bool push(const T& v) noexcept {
        const size_t w = write_.load(std::memory_order_relaxed);
        if (w - read_.load(std::memory_order_acquire) == N) return false;
        buf_[w & (N - 1)] = v;
        write_.store(w + 1, std::memory_order_release);
        return true;
    }

    bool pop(T& out) noexcept {
        const size_t r = read_.load(std::memory_order_relaxed);
        if (r == write_.load(std::memory_order_acquire)) return false;
        out = buf_[r & (N - 1)];
        read_.store(r + 1, std::memory_order_release);
        return true;
    }

    // Observe the next item without consuming it. Only the consumer may call this.
    bool peek(T& out) const noexcept {
        const size_t r = read_.load(std::memory_order_relaxed);
        if (r == write_.load(std::memory_order_acquire)) return false;
        out = buf_[r & (N - 1)];
        return true;
    }

    // Producer-side capacity query. A concurrent consumer can only increase this value.
    size_t writable() const noexcept {
        const size_t w = write_.load(std::memory_order_relaxed);
        const size_t r = read_.load(std::memory_order_acquire);
        const size_t used = w - r;
        return used >= N ? 0 : N - used;
    }

private:
    std::array<T, N> buf_{};
    alignas(64) std::atomic<size_t> write_{0};
    alignas(64) std::atomic<size_t> read_{0};
};

}  // namespace caw
