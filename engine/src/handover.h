// A single-slot lock-free handover of immutable objects from the control thread to the audio thread (which never frees).
#pragma once

#include <atomic>

namespace caw {

// The control thread offers (replacing an offer not yet taken), the audio thread takes; what the audio thread lets
// go waits in `retired` until the control thread's next offer() or collect() frees it. At most one object is in
// flight each way, so the audio thread neither allocates nor frees.
template <class T>
class Handover {
public:
    Handover() = default;
    Handover(const Handover&) = delete;
    Handover& operator=(const Handover&) = delete;
    ~Handover() {
        delete next_.exchange(nullptr);
        delete retired_.exchange(nullptr);
        delete current_;
    }
    void offer(T* t) noexcept {  // control thread
        delete retired_.exchange(nullptr, std::memory_order_acq_rel);
        delete next_.exchange(t, std::memory_order_acq_rel);
    }
    void collect() noexcept { delete retired_.exchange(nullptr, std::memory_order_acq_rel); }  // control thread
    // Audio thread: takes an offer when the retire slot is free. True when `current()` changed.
    bool poll() noexcept {
        if (!next_.load(std::memory_order_relaxed) || retired_.load(std::memory_order_acquire)) return false;
        T* n = next_.exchange(nullptr, std::memory_order_acq_rel);
        if (!n) return false;
        retired_.store(current_, std::memory_order_release);
        current_ = n;
        return true;
    }
    const T* current() const noexcept { return current_; }  // audio thread

private:
    std::atomic<T*> next_{nullptr}, retired_{nullptr};
    T* current_ = nullptr;
};

}  // namespace caw
