// Audio samples for built-in components (a drum pad's sample layer): the slots a processor offers, and loading them off the audio thread.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace caw {

class ModuleProcessor;

// One loaded sample: mono floats at the engine's rate. Immutable once handed to a processor.
struct SampleBuffer {
    std::vector<float> data;
    std::string source;  // what it was loaded from ("path:..." or "builtin:..."), to skip reloading the same
};

// Limits on what a project may load (docs/engine.md, "Drums", Samples).
inline constexpr double kMaxSampleSeconds = 30.0;              // per slot, after resampling
inline constexpr uint64_t kMaxSampleBytesPerComponent = 64ull << 20;  // every slot of one instance together
inline constexpr uint64_t kMaxSampleFileBytes = 256ull << 20;  // a file larger than this is refused unread

// A sample a project entry names: {"slot": n, "path": "..."} or {"slot": n, "builtin": "name"}.
struct SampleRefSpec {
    uint32_t slot = 0;
    std::string path;
    std::string builtin;
};

// A processor with sample slots implements this (found with dynamic_cast). Every call is on the control
// thread; the audio thread picks a new buffer up at its next block (a lock-free exchange) and hands the old
// one back, which a later control-thread call frees.
class SampleSlots {
public:
    virtual ~SampleSlots() = default;
    virtual uint32_t sampleSlotCount() const noexcept = 0;
    // The source of the buffer last given to `slot` ("" for none).
    virtual const std::string& sampleSource(uint32_t slot) const noexcept = 0;
    // Gives `slot` this buffer (null empties it). False if the slot doesn't exist.
    virtual bool setSample(uint32_t slot, std::unique_ptr<SampleBuffer> buffer) noexcept = 0;
};

// A single-slot lock-free handover: the control thread offers, the audio thread takes. At most one buffer is
// in flight each way; the audio thread never frees.
class SampleHandover {
public:
    ~SampleHandover() {
        delete next_.exchange(nullptr);
        delete retired_.exchange(nullptr);
        delete current_;
    }
    // Control thread: frees what the audio thread retired, replaces an offer not yet taken. Never null (an
    // empty buffer empties the slot).
    void offer(SampleBuffer* b) noexcept {
        delete retired_.exchange(nullptr, std::memory_order_acq_rel);
        delete next_.exchange(b, std::memory_order_acq_rel);
    }
    // Control thread: frees a retired buffer (call now and then).
    void collect() noexcept { delete retired_.exchange(nullptr, std::memory_order_acq_rel); }
    // Audio thread: takes an offer when the retire slot is free; returns the buffer to play.
    const SampleBuffer* poll() noexcept {
        if (next_.load(std::memory_order_relaxed) && !retired_.load(std::memory_order_acquire)) {
            SampleBuffer* n = next_.exchange(nullptr, std::memory_order_acq_rel);
            if (n) {
                retired_.store(current_, std::memory_order_release);
                current_ = n;  // an empty buffer empties the slot
            }
        }
        return current_ && !current_->data.empty() ? current_ : nullptr;
    }
    const SampleBuffer* current() const noexcept { return current_; }

private:
    std::atomic<SampleBuffer*> next_{nullptr}, retired_{nullptr};
    SampleBuffer* current_ = nullptr;  // audio thread
};

// Decodes a WAV file (PCM 8/16/24/32-bit, float 32/64, 1..8 channels, extensible format) to mono floats at
// `rate`, bounds-checked against the limits above. Control thread (file I/O). False with `error`.
bool decodeWavFile(const std::string& path, double rate, std::vector<float>& out, std::string& error);
// The same from bytes in memory (tests, and any host that reads the file itself). Rate 0: at the file's own rate.
bool decodeWavBytes(const uint8_t* bytes, size_t size, double rate, std::vector<float>& out, std::string& error);

// Loads every named sample into `processor` (if it has slots), skipping slots whose source didn't change and
// emptying the slots no longer named. Control thread. Returns false with `error` for a bad reference; a file
// that fails to decode empties its slot and adds a line to `warnings`.
bool applyComponentSamples(ModuleProcessor& processor, const std::vector<SampleRefSpec>& samples, double rate,
                           std::string& error, std::string* warnings = nullptr);

}  // namespace caw
