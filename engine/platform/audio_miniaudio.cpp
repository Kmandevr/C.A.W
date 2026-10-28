// Audio output through miniaudio (AAudio on Android, WASAPI on Windows, Core Audio, ALSA/PulseAudio), with load metering.
#include <chrono>
#include <cstring>
#include <string>

#include "caw.h"
#include "capi_internal.h"
#include "miniaudio.h"

namespace {

constexpr int kChunk = 512;

struct Audio {
    ma_device device;
    CawEngine* owner = nullptr;
    float l[kChunk], r[kChunk];
};

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

}  // namespace

extern "C" {

int32_t caw_audio_start(CawEngine* e, char* error, int32_t error_len) {
    if (!e) return 1;
    if (e->audio) return 0;
    auto* a = new Audio();
    a->owner = e;
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.sampleRate = static_cast<ma_uint32>(e->engine->sampleRate());
    cfg.performanceProfile = ma_performance_profile_low_latency;
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
    return 0;
}

void caw_audio_stop(CawEngine* e) {
    if (!e || !e->audio) return;
    auto* a = static_cast<Audio*>(e->audio);
    ma_device_uninit(&a->device);
    delete a;
    e->audio = nullptr;
}

}  // extern "C"
