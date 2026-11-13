// What a CawEngine handle holds, shared by the core C API and the platform audio output.
#pragma once

#include <atomic>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "engine.h"

// The Benchmark's live mode (capi_stress.cpp, API 27): what the device callback measured while a stress run listens.
// Preallocated by the run before it is installed; the callback only stores into it (no allocation, no lock).
struct CawStressStats {
    static constexpr int64_t kCoreEvery = 64;  // callbacks between reads of the callback's core
    explicit CawStressStats(size_t capacity) : loads(capacity), times(capacity), frames(capacity) {}
    std::vector<float> loads;    // per callback: its share of its own budget
    std::vector<float> times;    // per callback: microseconds
    std::vector<int32_t> frames; // per callback: its size (devices may vary it)
    std::atomic<int64_t> written{0}, overBudget{0}, usedNs{0}, budgetNs{0}, framesSum{0};
    std::atomic<int32_t> core{-1};  // the core the callback last ran on when read (-1: unknown)
    // Whether this callback should read its core: the first, then every kCoreEvery-th.
    bool coreDue() const noexcept { return written.load(std::memory_order_relaxed) % kCoreEvery == 0; }
    void record(double usedSeconds, double budgetSeconds, int32_t callbackFrames, int32_t cpu) noexcept {
        const int64_t at = written.load(std::memory_order_relaxed);
        if (at < static_cast<int64_t>(loads.size())) {
            loads[static_cast<size_t>(at)] = static_cast<float>(budgetSeconds > 0 ? usedSeconds / budgetSeconds : 0.0);
            times[static_cast<size_t>(at)] = static_cast<float>(usedSeconds * 1e6);
            frames[static_cast<size_t>(at)] = callbackFrames;
        }
        if (usedSeconds > budgetSeconds) overBudget.fetch_add(1, std::memory_order_relaxed);
        usedNs.fetch_add(static_cast<int64_t>(usedSeconds * 1e9), std::memory_order_relaxed);
        budgetNs.fetch_add(static_cast<int64_t>(budgetSeconds * 1e9), std::memory_order_relaxed);
        framesSum.fetch_add(callbackFrames, std::memory_order_relaxed);
        if (cpu >= 0) core.store(cpu, std::memory_order_relaxed);
        written.store(at + 1, std::memory_order_release);
    }
};

struct CawEngine {
    std::unique_ptr<caw::Engine> engine;
    void* audio = nullptr;  // owned by engine/platform
    // The Benchmark's live mode: the device callback zeroes its output after process() (the run is silent), and
    // records into `stress` while it is set. Both are the stress run's own engine's, never the app's.
    std::atomic<bool> muteOutput{false};
    std::atomic<CawStressStats*> stress{nullptr};
    // The device buffer (caw_audio_set_buffer_mode): CAW_BUFFER_*, and whether the app is recording. Only the
    // control thread touches them, under engine/platform's device lock.
    int bufferMode = 0;
    bool recording = false;
    // The device's choice (caw_audio_configure): a playback device by the backend's id, else by name (both empty:
    // the default), a callback size (0: the buffer mode's) and CAW_AUDIO_* flags. Under the same lock.
    std::string deviceId;
    std::string deviceName;
    int periodFrames = 0;
    int audioFlags = 0;
    // The input (caw_audio_configure_input, API 18): duplex when enabled; a capture device by id, else by name
    // (both empty: the default), and how many channels. Under the same lock.
    bool inputEnabled = false;
    std::string inputId;
    std::string inputName;
    int inputChannels = 2;

    // Async control jobs retain the handle until their worker callback has finished.
    bool retainAsync() {
        std::lock_guard<std::mutex> lock(asyncMutex);
        if (destroying) return false;
        ++asyncJobs;
        return true;
    }
    void releaseAsync() {
        std::lock_guard<std::mutex> lock(asyncMutex);
        if (asyncJobs > 0 && --asyncJobs == 0) asyncDone.notify_all();
    }
    void waitAsync() {
        std::unique_lock<std::mutex> lock(asyncMutex);
        destroying = true;
        asyncDone.wait(lock, [this] { return asyncJobs == 0; });
    }

private:
    std::mutex asyncMutex;
    std::condition_variable asyncDone;
    uint32_t asyncJobs = 0;
    bool destroying = false;
};

// Underruns the running device has reported since it opened (AAudio's XRun count); -1 where the platform reports
// none or no device runs. engine/platform (audio_miniaudio.cpp, audio_none.cpp).
int32_t cawAudioXruns(CawEngine* e);
