// Audio output through miniaudio (AAudio on Android, WASAPI on Windows, Core Audio, ALSA/PulseAudio), with load metering.
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>

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
    ma_context context;
    ma_device device;
    CawEngine* owner = nullptr;
    ma_uint32 frames = 0;     // the callback size asked for (0: the device's smallest)
    bool exclusive = false;   // opened in exclusive mode
    bool lowLatency = false;  // opened with the low-latency profile
    float l[kChunk], r[kChunk];
};

// The larger buffer (Auto while not recording, Battery): 1024 frames, about 21 ms at 48 kHz, so the callback
// wakes about 47 times a second instead of a few hundred (a low-latency burst is 96 to 192 frames on most phones).
constexpr ma_uint32 kLargeBufferFrames = 1024;

bool wantsLarge(const CawEngine* e) {
    return e->bufferMode == CAW_BUFFER_BATTERY || (e->bufferMode == CAW_BUFFER_AUTO && !e->recording);
}

// The callback size to ask for: the one chosen (caw_audio_configure), else the buffer mode's (0: the smallest).
ma_uint32 wantedFrames(const CawEngine* e) {
    if (e->periodFrames > 0) return static_cast<ma_uint32>(e->periodFrames);
    return wantsLarge(e) ? kLargeBufferFrames : 0;
}

std::string quoted(const char* s) {
    std::string out = "\"";
    for (const char* p = s; p && *p; ++p) {
        if (*p == '"' || *p == '\\') out += '\\';
        if (static_cast<unsigned char>(*p) >= 0x20) out += *p;
    }
    return out + "\"";
}

char* dup(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

// Exclusive mode is a request miniaudio passes on for WASAPI (AUDCLNT_SHAREMODE_EXCLUSIVE) and AAudio
// (AAUDIO_SHARING_MODE_EXCLUSIVE) (miniaudio 0.11.25: ma_device_init__wasapi, ma_create_and_configure_
// AAudioStreamBuilder__aaudio); other backends here are left in shared mode.
bool takesExclusive(ma_backend b) { return b == ma_backend_wasapi || b == ma_backend_aaudio; }

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
    a->owner->engine->reportLoad(budget > 0 ? used / budget : 0.0, static_cast<int>(frames));
}

void setError(const std::string& msg, char* error, int32_t len) {
    if (!error || len <= 0) return;
    std::strncpy(error, msg.c_str(), static_cast<size_t>(len - 1));
    error[len - 1] = '\0';
}

void stopLocked(CawEngine* e) {
    if (!e || !e->audio) return;
    auto* a = static_cast<Audio*>(e->audio);
    ma_device_uninit(&a->device);  // the callback has stopped once this returns
    ma_context_uninit(&a->context);
    delete a;
    e->audio = nullptr;
    e->engine->resetTestTone();  // a tone cut off here would otherwise say it sounds until the device reopens
    if (gActive == e) gActive = nullptr;
}

int32_t startLocked(CawEngine* e, char* error, int32_t error_len) {
    if (e->audio) return 0;
    if (gActive && gActive != e) stopLocked(gActive);  // an orphaned engine from an earlier copy of the app
    auto* a = new Audio();
    a->owner = e;
    a->frames = wantedFrames(e);
    ma_result r = ma_context_init(nullptr, 0, nullptr, &a->context);
    if (r != MA_SUCCESS) {
        setError(std::string("can't open the audio system: ") + ma_result_description(r), error, error_len);
        delete a;
        return 1;
    }
    // A device chosen by name: found in the backend's list, else the default (it was unplugged, say).
    ma_device_id chosen;
    bool found = false;
    if (!e->deviceName.empty()) {
        ma_device_info* playback = nullptr;
        ma_uint32 count = 0;
        if (ma_context_get_devices(&a->context, &playback, &count, nullptr, nullptr) == MA_SUCCESS) {
            for (ma_uint32 i = 0; i < count && !found; ++i) {
                if (e->deviceName == playback[i].name) {
                    chosen = playback[i].id;
                    found = true;
                }
            }
        }
    }
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.playback.pDeviceID = found ? &chosen : nullptr;
    cfg.sampleRate = static_cast<ma_uint32>(e->engine->sampleRate());
    // Low latency asks AAudio for AAUDIO_PERFORMANCE_MODE_LOW_LATENCY (its fast, MMAP path, where the callback runs
    // on a high-priority thread); the conservative profile asks for PERFORMANCE_MODE_NONE, the power-saving
    // legacy path (miniaudio 0.11.25, ma_open_stream__aaudio). A callback size is passed on with
    // aaudio.allowSetBufferCapacity: miniaudio gives it to setBufferCapacityInFrames/setFramesPerDataCallback
    // (ma_create_and_configure_AAudioStreamBuilder__aaudio). Battery also leaves the fast path.
    a->lowLatency = e->bufferMode != CAW_BUFFER_BATTERY;
    cfg.performanceProfile = a->lowLatency ? ma_performance_profile_low_latency : ma_performance_profile_conservative;
    if (a->frames > 0) {
        cfg.periodSizeInFrames = a->frames;
        cfg.aaudio.allowSetBufferCapacity = MA_TRUE;
    }
    cfg.dataCallback = callback;
    cfg.pUserData = a;
    a->exclusive = (e->audioFlags & CAW_AUDIO_EXCLUSIVE) != 0 && takesExclusive(a->context.backend);
    cfg.playback.shareMode = a->exclusive ? ma_share_mode_exclusive : ma_share_mode_shared;
    r = ma_device_init(&a->context, &cfg, &a->device);
    if (r != MA_SUCCESS && a->exclusive) {
        // The device refused exclusive mode (another app holds it, or no native format fits): shared instead.
        a->exclusive = false;
        cfg.playback.shareMode = ma_share_mode_shared;
        r = ma_device_init(&a->context, &cfg, &a->device);
    }
    if (r != MA_SUCCESS) {
        setError(std::string("can't open the audio device: ") + ma_result_description(r), error, error_len);
        ma_context_uninit(&a->context);
        delete a;
        return 1;
    }
    e->engine->resetTestTone();  // a request made while closed is stale (the callback is not running yet)
    r = ma_device_start(&a->device);
    if (r != MA_SUCCESS) {
        setError(std::string("can't start the audio device: ") + ma_result_description(r), error, error_len);
        ma_device_uninit(&a->device);
        ma_context_uninit(&a->context);
        delete a;
        return 1;
    }
    e->audio = a;
    gActive = e;
    return 0;
}

// Reopens a running device after its choice changed; 0 when it runs again (or was not running).
int32_t reopenLocked(CawEngine* e) {
    if (!e->audio) return 0;
    stopLocked(e);
    char error[256];
    return startLocked(e, error, sizeof error) == 0 ? 0 : 1;
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
    const bool wasLowLatency = e->bufferMode != CAW_BUFFER_BATTERY;
    e->bufferMode = mode == CAW_BUFFER_LOW_LATENCY || mode == CAW_BUFFER_BATTERY ? mode : CAW_BUFFER_AUTO;
    e->recording = recording != 0;
    auto* a = static_cast<Audio*>(e->audio);
    if (!a) return;
    // Reopen at the new size or profile: a short gap, at a recording's start or end, or a settings change.
    if (a->frames == wantedFrames(e) && wasLowLatency == (e->bufferMode != CAW_BUFFER_BATTERY)) return;
    reopenLocked(e);
}

int32_t caw_audio_buffer_frames(CawEngine* e) {
    if (!e) return 0;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    const auto* a = static_cast<const Audio*>(e->audio);
    return a ? static_cast<int32_t>(a->device.playback.internalPeriodSizeInFrames) : 0;
}

char* caw_audio_devices(void) {
    ma_context context;
    if (ma_context_init(nullptr, 0, nullptr, &context) != MA_SUCCESS) {
        return dup("{\"backend\":\"none\",\"exclusive\":false,\"devices\":[]}");
    }
    std::string out = "{\"backend\":" + quoted(ma_get_backend_name(context.backend)) +
                      ",\"exclusive\":" + (takesExclusive(context.backend) ? "true" : "false") + ",\"devices\":[";
    ma_device_info* playback = nullptr;
    ma_uint32 count = 0;
    if (ma_context_get_devices(&context, &playback, &count, nullptr, nullptr) == MA_SUCCESS) {
        for (ma_uint32 i = 0; i < count; ++i) {
            if (i) out += ",";
            out += "{\"name\":" + quoted(playback[i].name) + ",\"default\":" + (playback[i].isDefault ? "true" : "false");
            ma_device_info info;
            std::string rates, exclusiveRates;
            if (ma_context_get_device_info(&context, ma_device_type_playback, &playback[i].id, &info) == MA_SUCCESS) {
                std::vector<ma_uint32> shared, exclusive;
                for (ma_uint32 f = 0; f < info.nativeDataFormatCount; ++f) {
                    const ma_uint32 rate = info.nativeDataFormats[f].sampleRate;
                    auto& list = (info.nativeDataFormats[f].flags & MA_DATA_FORMAT_FLAG_EXCLUSIVE_MODE) ? exclusive : shared;
                    if (std::find(list.begin(), list.end(), rate) == list.end()) list.push_back(rate);
                }
                std::sort(shared.begin(), shared.end());
                std::sort(exclusive.begin(), exclusive.end());
                for (const ma_uint32 v : shared) rates += (rates.empty() ? "" : ",") + std::to_string(v);
                for (const ma_uint32 v : exclusive) exclusiveRates += (exclusiveRates.empty() ? "" : ",") + std::to_string(v);
            }
            out += ",\"rates\":[" + rates + "],\"exclusive_rates\":[" + exclusiveRates + "]}";
        }
    }
    ma_context_uninit(&context);
    return dup(out + "]}");
}

int32_t caw_audio_configure(CawEngine* e, const char* device_name, int32_t period_frames, int32_t flags) {
    if (!e) return 1;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    std::string name = device_name ? std::string(device_name).substr(0, MA_MAX_DEVICE_NAME_LENGTH) : std::string();
    const int frames = period_frames <= 0 ? 0 : period_frames < 16 ? 16 : period_frames > 8192 ? 8192 : period_frames;
    const int f = flags & CAW_AUDIO_EXCLUSIVE;
    if (name == e->deviceName && frames == e->periodFrames && f == e->audioFlags) return 0;
    e->deviceName = std::move(name);
    e->periodFrames = frames;
    e->audioFlags = f;
    return reopenLocked(e);
}

char* caw_audio_status(CawEngine* e) {
    if (!e) return dup("{\"running\":false}");
    std::lock_guard<std::mutex> lock(gDeviceLock);
    const std::string request = ",\"requested_device\":" + quoted(e->deviceName.c_str()) +
                                ",\"requested_frames\":" + std::to_string(e->periodFrames) +
                                ",\"exclusive_requested\":" + ((e->audioFlags & CAW_AUDIO_EXCLUSIVE) ? "true" : "false");
    const auto* a = static_cast<const Audio*>(e->audio);
    if (!a) return dup("{\"running\":false" + request + "}");
    const auto& p = a->device.playback;
    return dup("{\"running\":true,\"backend\":" + quoted(ma_get_backend_name(a->context.backend)) +
               ",\"device\":" + quoted(p.name) + ",\"sample_rate\":" + std::to_string(p.internalSampleRate) +
               ",\"period_frames\":" + std::to_string(p.internalPeriodSizeInFrames) +
               ",\"periods\":" + std::to_string(p.internalPeriods) +
               ",\"exclusive\":" + (a->exclusive ? "true" : "false") +
               ",\"low_latency\":" + (a->lowLatency ? "true" : "false") + request + "}");
}

}  // extern "C"
