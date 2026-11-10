// Audio output through miniaudio (AAudio on Android, WASAPI on Windows, Core Audio, ALSA/PulseAudio), with load metering.
#include <chrono>
#include <cstring>
#include <mutex>
#include <string>

#include "caw.h"
#include "capi_internal.h"
#include "miniaudio.h"

namespace {

constexpr int kChunk = 512;

// One audio output per process. When Android recreates the app's screen (it lost focus while playing, say), a new
// copy of the app starts with a new engine while the old one, which nothing controls any more, may still be
// playing; the two would sound together. Starting audio on an engine therefore closes any other engine's device.
// Only start and stop take this lock (never the audio callback).
std::mutex gDeviceLock;
CawEngine* gActive = nullptr;

void stopLocked(CawEngine* e);

struct Audio {
    ma_device device;
    CawEngine* owner = nullptr;
    bool large = false;  // opened with the larger buffer
    float l[kChunk], r[kChunk];
};

// The larger buffer (Auto while not recording, Battery): 1024 frames, about 21 ms at 48 kHz, so the callback
// wakes about 47 times a second instead of a few hundred (a low-latency burst is 96 to 192 frames on most phones).
constexpr ma_uint32 kLargeBufferFrames = 1024;

bool wantsLarge(const CawEngine* e) {
    return e->bufferMode == CAW_BUFFER_BATTERY || (e->bufferMode == CAW_BUFFER_AUTO && !e->recording);
}

void callback(ma_device* dev, void* output, const void*, ma_uint32 frames) {
    auto* a = static_cast<Audio*>(dev->pUserData);
    const auto start = std::chrono::steady_clock::now();
    auto* out = static_cast<float*>(output);
    ma_uint32 done = 0;
    while (done < frames) {
        const int n = static_cast<int>(frames - done < kChunk ? frames - done : kChunk);
        a->owner->engine->process(a->l, a->r, n);
        for (int i = 0; i < n; ++i) {
            out[(done + i) * 2] = a->l[i];
            out[(done + i) * 2 + 1] = a->r[i];
        }
        done += static_cast<ma_uint32>(n);
    }
    const double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double budget = static_cast<double>(frames) / static_cast<double>(dev->sampleRate);
    a->owner->engine->reportLoad(budget > 0 ? used / budget : 0.0);
}

void setError(const std::string& msg, char* error, int32_t len) {
    if (!error || len <= 0) return;
    std::strncpy(error, msg.c_str(), static_cast<size_t>(len - 1));
    error[len - 1] = '\0';
}

void stopLocked(CawEngine* e) {
    if (!e || !e->audio) return;
    auto* a = static_cast<Audio*>(e->audio);
    ma_device_uninit(&a->device);
    delete a;
    e->audio = nullptr;
    if (gActive == e) gActive = nullptr;
}

int32_t startLocked(CawEngine* e, char* error, int32_t error_len) {
    if (e->audio) return 0;
    if (gActive && gActive != e) stopLocked(gActive);  // an orphaned engine from an earlier copy of the app
    auto* a = new Audio();
    a->owner = e;
    a->large = wantsLarge(e);
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate = static_cast<ma_uint32>(e->engine->sampleRate());
    // Low latency asks AAudio for AAUDIO_PERFORMANCE_MODE_LOW_LATENCY (its fast, MMAP path, where the callback runs
    // on a high-priority thread); the conservative profile asks for PERFORMANCE_MODE_NONE, the power-saving
    // legacy path (miniaudio 0.11.25, ma_open_stream__aaudio). The larger buffer sets the callback size: with
    // aaudio.allowSetBufferCapacity, miniaudio passes it to setBufferCapacityInFrames/setFramesPerDataCallback.
    // Auto keeps the fast path and only lengthens the callback; Battery also leaves the fast path.
    cfg.performanceProfile = e->bufferMode == CAW_BUFFER_BATTERY ? ma_performance_profile_conservative
                                                                 : ma_performance_profile_low_latency;
    if (a->large) {
        cfg.periodSizeInFrames = kLargeBufferFrames;
        cfg.aaudio.allowSetBufferCapacity = MA_TRUE;
    }
    cfg.dataCallback = callback;
    cfg.pUserData = a;
    ma_result r = ma_device_init(nullptr, &cfg, &a->device);
    if (r != MA_SUCCESS) {
        setError(std::string("can't open the audio device: ") + ma_result_description(r), error, error_len);
        delete a;
        return 1;
    }
    r = ma_device_start(&a->device);
    if (r != MA_SUCCESS) {
        setError(std::string("can't start the audio device: ") + ma_result_description(r), error, error_len);
        ma_device_uninit(&a->device);
        delete a;
        return 1;
    }
    e->audio = a;
    gActive = e;
    return 0;
}

}  // namespace

extern "C" {

int32_t caw_audio_start(CawEngine* e, char* error, int32_t error_len) {
    if (!e) return 1;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    return startLocked(e, error, error_len);
}

void caw_audio_stop(CawEngine* e) {
    if (!e) return;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    stopLocked(e);
}

void caw_audio_set_buffer_mode(CawEngine* e, int32_t mode, int32_t recording) {
    if (!e) return;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    e->bufferMode = mode == CAW_BUFFER_LOW_LATENCY || mode == CAW_BUFFER_BATTERY ? mode : CAW_BUFFER_AUTO;
    e->recording = recording != 0;
    auto* a = static_cast<Audio*>(e->audio);
    if (!a || a->large == wantsLarge(e)) return;
    // Reopen at the new size: a short gap, at a recording's start or end, or a settings change.
    stopLocked(e);
    char error[256];
    startLocked(e, error, sizeof error);
}

int32_t caw_audio_buffer_frames(CawEngine* e) {
    if (!e) return 0;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    const auto* a = static_cast<const Audio*>(e->audio);
    return a ? static_cast<int32_t>(a->device.playback.internalPeriodSizeInFrames) : 0;
}

}  // extern "C"
