// Flagship's (Raven's) spectral and additive warp banks: each wavetable's frames resynthesised at 8 warp amounts, built off the audio thread and shared.
#pragma once

#include <atomic>
#include <cstdint>
#include <memory>

#include "caw/library/wavetable.hpp"

namespace caw::flagship {

// The spectral and additive warps, in the order of Flagship's warp list (appended after Osc sync).
enum SpectralMode : int { kStretch, kShift, kOddEven, kFormant, kSmear, kDisperse, kCut, kComb, kSpectralModes };

inline constexpr int kBankLevels = 8;      // the warp amounts 0, 1/7 .. 1
inline constexpr int kBankMaxFrames = 16;  // a longer table's frames are resampled to 16 for its banks

// A table's frames at kBankLevels warp amounts: frame `level * frames + f` is frame f at amount level / 7.
struct Bank {
    lib::Wavetable table;
    int frames = 1;
};

// A table a bank can be made from. The built-in tables live for the program; a user table's is registered by the
// instance that loaded it (control thread) and the worker builds from it only while it is still held.
using SourceId = uint32_t;
SourceId builtinSource(int index, const lib::Wavetable* table);  // index 0..15, the table living for the program
SourceId registerSource(std::shared_ptr<const lib::Wavetable> table);  // control thread

// Starts the shared builder thread (control thread, once is enough; later calls do nothing).
void startBankWorker();

// One instance's banks. find() runs on the audio thread: lock-free, no allocation. A bank not built yet is
// requested from the worker and find() returns null until it is ready (the oscillator plays unwarped meanwhile).
// Offline (an export's render, a test built under BuildingOffline), find() builds it there and then, so a render
// never depends on the worker's timing. Held banks are released after `idle()` reports them unused for about a
// second; the worker frees one nobody holds after about 10 s.
class BankUser {
public:
    BankUser() noexcept;
    ~BankUser();
    BankUser(const BankUser&) = delete;
    BankUser& operator=(const BankUser&) = delete;
    void setOffline(bool offline) noexcept { offline_ = offline; }
    const Bank* find(SourceId source, int mode) noexcept;
    // Once per control period: `bank` (or null) is in use by a sounding voice.
    void mark(const Bank* bank) noexcept;
    // Once per control period, after the marks: releases what no voice used for kIdleControls.
    void idle() noexcept;
    void releaseAll() noexcept;
    bool holding() const noexcept { return count_ > 0; }

private:
    static constexpr int kHeld = 8;
    static constexpr uint32_t kIdleControls = 3000;  // about a second at 48 kHz
    struct Held {
        int slot = -1;
        uint64_t key = 0;
        const Bank* bank = nullptr;
        uint32_t unused = 0;
    };
    Held held_[kHeld];
    int count_ = 0;
    bool offline_ = false;
};

// For tests: the bank for (table, mode) built now on this thread (not shared, not cached).
std::unique_ptr<Bank> buildBankNow(const lib::Wavetable& source, int mode);
// For tests: how many banks the shared cache holds built, and how many it has built since the program started (a
// bank freed and built again counts twice).
int cachedBanks() noexcept;
int banksBuilt() noexcept;

}  // namespace caw::flagship
