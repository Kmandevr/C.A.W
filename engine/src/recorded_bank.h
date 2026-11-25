// Recorded instrument parts built into the engine (embedded FLAC in engine/assets/): decoded on first use, shared, and freed when no instrument holds them.
#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <span>

namespace caw::recorded {

// One embedded recording: mono floats at its own rate, every clip of an instrument laid end to end (a manifest beside
// the instrument's code says where each clip starts).
struct Bank {
    std::unique_ptr<float[]> pcm;
    uint64_t frames = 0;
    uint32_t rate = 0;
    std::span<const float> samples() const noexcept { return {pcm.get(), static_cast<size_t>(frames)}; }
};

enum class BankId : uint32_t { StarlingPiano, Woodpecker, Bittern, kCount };

// The bank, decoded now if no instrument holds it yet; null if it cannot be decoded (the instrument then plays
// without it). Control thread only: it may allocate and decode (an instrument calls it from activate()). The
// pointer keeps the bank alive; the last holder's release frees it, so an unused instrument costs no memory
// (owner, 2026-11-24: "if you're using the piano it doesn't load the organ stuff").
std::shared_ptr<const Bank> acquire(BankId id) noexcept;

// What the decoded banks hold now, in bytes (the tests read it to check load-on-use and freeing).
size_t residentBytes() noexcept;

}  // namespace caw::recorded
