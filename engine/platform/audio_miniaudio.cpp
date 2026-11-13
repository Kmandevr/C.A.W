// Audio output through miniaudio (AAudio on Android, WASAPI on Windows, Core Audio, ALSA/PulseAudio), with load metering.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include <algorithm>

#if defined(__ANDROID__)
#include <dlfcn.h>
#include <time.h>
#endif
#if defined(__linux__)
#include <sched.h>  // sched_getcpu (Android too)
#endif
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mmdeviceapi.h>
#endif

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
    // Exclusive and low latency: on AAudio what the stream reported at open (AAudio may grant less than asked,
    // and a later reroute may change it); on WASAPI exclusive is what opened (it fails rather than share);
    // elsewhere what was asked.
    bool exclusive = false;
    bool lowLatency = false;
    bool modesReadBack = false;  // AAudio: the two above were read from the stream
    // The chosen device, size or exclusive mode did not open, so the system default did (shared, its own size).
    bool fallback = false;
    std::string fallbackReason;
    std::string deviceId;        // the backend's id of the device that opened ("" for the default)
    // The input (API 18): open when the device runs duplex; why not when it was asked for and did not open.
    bool input = false;
    ma_uint32 inputChannels = 0;
    ma_uint32 duplexBufferFrames = 0;  // miniaudio's duplex ring buffer's starting fill, in the latency estimate
    std::string inputDeviceId, inputError;
#if defined(_WIN32)
    // The last WASAPI endpoint ids read for their kind, so caw_audio_latency's polls skip COM until the device moves.
    std::wstring kindOutId, kindInId;
    const char* kindOut = "unknown";
    const char* kindIn = "unknown";
#endif
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

std::string bounded(const char* s, size_t n) {
    size_t len = 0;
    while (len < n && s[len]) ++len;
    return std::string(s, len);
}

// A device's id as text, to keep in settings. WASAPI's is its endpoint ID string, which identifies each of two
// identical interfaces that share a name and survives restarts and replugging (not a driver reinstall)
// ([Fact] Microsoft Learn, "Endpoint ID Strings", read 2026-11-11); the string backends' ids are device names
// or paths. "" where the backend has no id worth keeping (AAudio, JACK and the null backend use small integers).
std::string deviceIdText(ma_backend b, const ma_device_id& id) {
    switch (b) {
        case ma_backend_wasapi: {
            std::string out;  // UTF-16 to UTF-8
            for (size_t i = 0; i < 64 && id.wasapi[i]; ++i) {
                uint32_t c = static_cast<uint16_t>(id.wasapi[i]);
                if (c >= 0xD800 && c < 0xDC00 && i + 1 < 64) {
                    const uint32_t lo = static_cast<uint16_t>(id.wasapi[i + 1]);
                    if (lo >= 0xDC00 && lo < 0xE000) {
                        c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
                        ++i;
                    }
                }
                if (c < 0x80) {
                    out += static_cast<char>(c);
                } else if (c < 0x800) {
                    out += static_cast<char>(0xC0 | (c >> 6));
                    out += static_cast<char>(0x80 | (c & 0x3F));
                } else if (c < 0x10000) {
                    out += static_cast<char>(0xE0 | (c >> 12));
                    out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
                    out += static_cast<char>(0x80 | (c & 0x3F));
                } else {
                    out += static_cast<char>(0xF0 | (c >> 18));
                    out += static_cast<char>(0x80 | ((c >> 12) & 0x3F));
                    out += static_cast<char>(0x80 | ((c >> 6) & 0x3F));
                    out += static_cast<char>(0x80 | (c & 0x3F));
                }
            }
            return out;
        }
        case ma_backend_dsound: {
            static const char* hex = "0123456789abcdef";
            std::string out;
            for (const ma_uint8 v : id.dsound) {
                out += hex[v >> 4];
                out += hex[v & 15];
            }
            return out;
        }
        case ma_backend_winmm: return "winmm:" + std::to_string(id.winmm);
        case ma_backend_alsa: return bounded(id.alsa, sizeof id.alsa);
        case ma_backend_pulseaudio: return bounded(id.pulse, sizeof id.pulse);
        case ma_backend_coreaudio: return bounded(id.coreaudio, sizeof id.coreaudio);
        case ma_backend_sndio: return bounded(id.sndio, sizeof id.sndio);
        case ma_backend_audio4: return bounded(id.audio4, sizeof id.audio4);
        case ma_backend_oss: return bounded(id.oss, sizeof id.oss);
        default: return std::string();
    }
}

#if defined(__ANDROID__)
// AAudio's sharing and performance modes as the stream has them (NDK API 26; miniaudio 0.11.25 loads neither
// getter, so they are looked up in the libaaudio.so it opened). Read once at open, before the stream starts and on
// the opening thread, so no reroute can replace the stream meanwhile.
void readAAudioModes(Audio* a) {
    if (a->context.backend != ma_backend_aaudio || !a->context.aaudio.hAAudio || !a->device.aaudio.pStreamPlayback) return;
    using Getter = int32_t (*)(void*);
    auto sharing = reinterpret_cast<Getter>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getSharingMode"));
    auto performance = reinterpret_cast<Getter>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getPerformanceMode"));
    if (!sharing || !performance) return;
    a->exclusive = sharing(a->device.aaudio.pStreamPlayback) == 0;         // AAUDIO_SHARING_MODE_EXCLUSIVE
    a->lowLatency = performance(a->device.aaudio.pStreamPlayback) == 12;   // AAUDIO_PERFORMANCE_MODE_LOW_LATENCY
    a->modesReadBack = true;
}
#else
void readAAudioModes(Audio*) {}
#endif

// The core this callback runs on, for the Benchmark's live mode (-1 where the platform can't say).
int32_t callbackCore() {
#if defined(__linux__)
    return static_cast<int32_t>(sched_getcpu());
#elif defined(_WIN32)
    return static_cast<int32_t>(GetCurrentProcessorNumber());
#else
    return -1;
#endif
}

void callback(ma_device* dev, void* output, const void* input, ma_uint32 frames) {
    auto* a = static_cast<Audio*>(dev->pUserData);
    const auto start = std::chrono::steady_clock::now();
    auto* out = static_cast<float*>(output);
    ma_uint32 done = 0;
    caw::LiveAudio& live = a->owner->engine->liveAudio();
    const auto* in = static_cast<const float*>(input);
    const int ch = a->input && in ? static_cast<int>(a->inputChannels) : 0;
    while (done < frames) {
        const int n = static_cast<int>(frames - done < kChunk ? frames - done : kChunk);
        live.beginCallback(ch ? in + static_cast<size_t>(done) * ch : nullptr, ch, n);  // monitoring and recording
        a->owner->engine->process(a->l, a->r, n);
        live.afterCallback(a->l, a->r, n);  // the latency ping
        const float gain = a->owner->muteOutput.load(std::memory_order_relaxed) ? 0.0f : 1.0f;  // the Benchmark: silent
        for (int i = 0; i < n; ++i) {
            out[(done + i) * 2] = gain * a->l[i];
            out[(done + i) * 2 + 1] = gain * a->r[i];
        }
        done += static_cast<ma_uint32>(n);
    }
    const double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double budget = static_cast<double>(frames) / static_cast<double>(dev->sampleRate);
    a->owner->engine->reportLoad(budget > 0 ? used / budget : 0.0, static_cast<int>(frames));
    if (CawStressStats* s = a->owner->stress.load(std::memory_order_acquire)) s->record(used, budget, callbackCore());
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
    e->engine->liveAudio().setDeviceChannels(0);
    delete a;
    e->audio = nullptr;
    e->engine->resetTestTone();  // a tone cut off here would otherwise say it sounds until the device reopens
    if (gActive == e) gActive = nullptr;
}

// Opens and starts the device on [a]'s context: [id] (null: the default), [frames] a callback (0: the device's
// own), exclusive mode when asked and the backend takes it (shared if refused). MA_SUCCESS or why not.
ma_result openDevice(Audio* a, const CawEngine* e, const ma_device_id* id, ma_uint32 frames, bool exclusive,
                     std::string& why, const ma_device_id* inputId = nullptr, bool duplex = false) {
    ma_device_config cfg = ma_device_config_init(duplex ? ma_device_type_duplex : ma_device_type_playback);
    a->input = duplex;
    if (duplex) {
        // Input and output in one callback (miniaudio duplex), so monitoring adds no buffer of its own; the input
        // is always shared (exclusive applies to playback).
        cfg.capture.format = ma_format_f32;
        cfg.capture.channels = static_cast<ma_uint32>(e->inputChannels);
        cfg.capture.pDeviceID = inputId;
        cfg.capture.shareMode = ma_share_mode_shared;
    }
    cfg.playback.format = ma_format_f32;
    cfg.playback.channels = 2;
    cfg.playback.pDeviceID = id;
    cfg.sampleRate = static_cast<ma_uint32>(e->engine->sampleRate());
    // Low latency asks AAudio for AAUDIO_PERFORMANCE_MODE_LOW_LATENCY (its fast, MMAP path, where the callback runs
    // on a high-priority thread); the conservative profile asks for PERFORMANCE_MODE_NONE, the power-saving
    // legacy path (miniaudio 0.11.25, ma_open_stream__aaudio). Battery also leaves the fast path.
    // A callback size goes to setBufferCapacityInFrames/setFramesPerDataCallback only with
    // aaudio.allowSetBufferCapacity and, while miniaudio's compatibility workarounds are on (the default), only on
    // Android 12 and later (`ma_android_sdk_version() > 30`, ma_create_and_configure_AAudioStreamBuilder__aaudio):
    // on Android 11 and older the chosen size is ignored and the device picks its own; the status shows what it gave.
    a->lowLatency = e->bufferMode != CAW_BUFFER_BATTERY;
    cfg.performanceProfile = a->lowLatency ? ma_performance_profile_low_latency : ma_performance_profile_conservative;
    a->frames = frames;
    if (frames > 0) {
        cfg.periodSizeInFrames = frames;
        cfg.aaudio.allowSetBufferCapacity = MA_TRUE;
    }
    cfg.dataCallback = callback;
    cfg.pUserData = a;
    a->exclusive = exclusive && takesExclusive(a->context.backend);
    cfg.playback.shareMode = a->exclusive ? ma_share_mode_exclusive : ma_share_mode_shared;
    ma_result r = ma_device_init(&a->context, &cfg, &a->device);
    if (r != MA_SUCCESS && a->exclusive) {
        // The device refused exclusive mode (another app holds it, or no native format fits): shared instead.
        a->exclusive = false;
        cfg.playback.shareMode = ma_share_mode_shared;
        r = ma_device_init(&a->context, &cfg, &a->device);
    }
    if (r != MA_SUCCESS) {
        why = std::string("can't open the audio device: ") + ma_result_description(r);
        return r;
    }
    readAAudioModes(a);
    if (duplex) {
        a->inputChannels = a->device.capture.channels;
        e->engine->liveAudio().setDeviceChannels(static_cast<int>(a->inputChannels));
        // [Assumption] the round trip is about both sides' buffers; a ping measures it (caw_latency_ping_start).
        const ma_uint32 in = a->device.capture.internalPeriodSizeInFrames * std::max<ma_uint32>(1, a->device.capture.internalPeriods);
        const ma_uint32 out = a->device.playback.internalPeriodSizeInFrames * std::max<ma_uint32>(1, a->device.playback.internalPeriods);
        // [Verified, miniaudio 0.11.25 source] on an asynchronous backend (AAudio, OpenSL ES, Core Audio, JACK,
        // Web Audio) and on PulseAudio, duplex runs through ma_device.duplexRB: the capture callback writes into
        // it and the playback callback reads from it, and ma_duplex_rb_init starts its write position two capture
        // periods ahead (ma_pcm_rb_seek_write(..., captureInternalPeriodSizeInFrames * 2)). Those two periods are
        // in the round trip too. WASAPI, ALSA and the other blocking read/write backends have no such buffer
        // (ma_device_init only makes it when ma_context_is_backend_asynchronous). How far the fill drifts while
        // running is not counted: the ping measures that.
        a->duplexBufferFrames = a->device.duplexRB.rb.rb.pBuffer ? a->device.capture.internalPeriodSizeInFrames * 2 : 0;
        e->engine->liveAudio().setDeviceLatency(static_cast<int64_t>(in) + out + a->duplexBufferFrames);
    } else {
        e->engine->liveAudio().setDeviceChannels(0);
    }
    e->engine->resetTestTone();  // a request made while closed is stale (the callback is not running yet)
    r = ma_device_start(&a->device);
    if (r != MA_SUCCESS) {
        why = std::string("can't start the audio device: ") + ma_result_description(r);
        ma_device_uninit(&a->device);
        return r;
    }
    return MA_SUCCESS;
}

int32_t startLocked(CawEngine* e, char* error, int32_t error_len) {
    if (e->audio) return 0;
    if (gActive && gActive != e) stopLocked(gActive);  // an orphaned engine from an earlier copy of the app
    auto* a = new Audio();
    a->owner = e;
    ma_result r = ma_context_init(nullptr, 0, nullptr, &a->context);
    if (r != MA_SUCCESS) {
        setError(std::string("can't open the audio system: ") + ma_result_description(r), error, error_len);
        delete a;
        return 1;
    }
    // A device chosen by id (two identical interfaces share a name), else by name, found in the backend's list;
    // else the default (it was unplugged, say). No list for the default, nor on AAudio, which lists only the
    // default (miniaudio 0.11.25, ma_context_enumerate_devices__aaudio) and where Android routes the output.
    ma_device_id chosen;
    bool found = false;
    if ((!e->deviceId.empty() || !e->deviceName.empty()) && a->context.backend != ma_backend_aaudio) {
        ma_device_info* playback = nullptr;
        ma_uint32 count = 0;
        if (ma_context_get_devices(&a->context, &playback, &count, nullptr, nullptr) == MA_SUCCESS) {
            for (ma_uint32 i = 0; i < count && !found && !e->deviceId.empty(); ++i) {
                if (e->deviceId == deviceIdText(a->context.backend, playback[i].id)) {
                    chosen = playback[i].id;
                    found = true;
                }
            }
            for (ma_uint32 i = 0; i < count && !found && !e->deviceName.empty(); ++i) {
                if (e->deviceName == playback[i].name) {
                    chosen = playback[i].id;
                    found = true;
                }
            }
        }
    }
    // The capture device the same way (AAudio: the default input, which Android routes).
    ma_device_id chosenInput;
    bool inputFound = false;
    if (e->inputEnabled && (!e->inputId.empty() || !e->inputName.empty()) && a->context.backend != ma_backend_aaudio) {
        ma_device_info* capture = nullptr;
        ma_uint32 count = 0;
        if (ma_context_get_devices(&a->context, nullptr, nullptr, &capture, &count) == MA_SUCCESS) {
            for (ma_uint32 i = 0; i < count && !inputFound && !e->inputId.empty(); ++i)
                if (e->inputId == deviceIdText(a->context.backend, capture[i].id)) {
                    chosenInput = capture[i].id;
                    inputFound = true;
                }
            for (ma_uint32 i = 0; i < count && !inputFound && !e->inputName.empty(); ++i)
                if (e->inputName == capture[i].name) {
                    chosenInput = capture[i].id;
                    inputFound = true;
                }
        }
    }
    const ma_uint32 frames = wantedFrames(e);
    const bool exclusive = (e->audioFlags & CAW_AUDIO_EXCLUSIVE) != 0;
    std::string why;
    if (e->inputEnabled) {
        r = openDevice(a, e, found ? &chosen : nullptr, frames, exclusive, why, inputFound ? &chosenInput : nullptr, true);
        if (r == MA_SUCCESS) {
            if (inputFound) a->inputDeviceId = deviceIdText(a->context.backend, chosenInput);
        } else {
            // No input (no permission, no microphone, a busy device): playback alone, and the status says why.
            a->inputError = why;
            why.clear();
            r = openDevice(a, e, found ? &chosen : nullptr, frames, exclusive, why);
        }
    } else {
        r = openDevice(a, e, found ? &chosen : nullptr, frames, exclusive, why);
    }
    if (r != MA_SUCCESS && (found || frames > 0 || exclusive)) {
        // The choice did not open (the interface is busy or refuses the size): the system default, shared, at its
        // own size, so Play is never silent; the status says so (fallback) and why.
        std::string again;
        if (openDevice(a, e, nullptr, 0, false, again) == MA_SUCCESS) {
            a->fallback = true;
            a->fallbackReason = why;
            r = MA_SUCCESS;
        }
    } else if (r == MA_SUCCESS && found) {
        a->deviceId = deviceIdText(a->context.backend, chosen);
    }
    if (r != MA_SUCCESS) {
        setError(why, error, error_len);
        ma_context_uninit(&a->context);
        delete a;
        return 1;
    }
    e->audio = a;
    gActive = e;
    return 0;
}

// Reopens a running device after its choice changed: 0 when it runs again as chosen (or was not running), 2 when
// it runs on the system default because the choice did not open, 1 when nothing opened (the device is closed).
int32_t reopenLocked(CawEngine* e) {
    if (!e->audio) return 0;
    stopLocked(e);
    char error[256];
    if (startLocked(e, error, sizeof error) != 0) return 1;
    return static_cast<const Audio*>(e->audio)->fallback ? 2 : 0;
}

std::string inputStatus(const CawEngine* e, const Audio* a) {
    const bool running = a && a->input;
    std::string out = std::string("{\"enabled\":") + (e->inputEnabled ? "true" : "false") +
                      ",\"running\":" + (running ? "true" : "false") +
                      ",\"requested_device\":" + quoted(e->inputName.c_str()) +
                      ",\"requested_device_id\":" + quoted(e->inputId.c_str()) +
                      ",\"requested_channels\":" + std::to_string(e->inputChannels);
    if (running) {
        const auto& c = a->device.capture;
        out += ",\"device\":" + quoted(c.name) + ",\"device_id\":" + quoted(a->inputDeviceId.c_str()) +
               ",\"channels\":" + std::to_string(a->inputChannels) + ",\"sample_rate\":" + std::to_string(c.internalSampleRate) +
               ",\"period_frames\":" + std::to_string(c.internalPeriodSizeInFrames) +
               ",\"duplex_buffer_frames\":" + std::to_string(a->duplexBufferFrames) +
               ",\"latency_frames\":" + std::to_string(e->engine->liveAudio().latency());
    }
    return out + ",\"error\":" + quoted(a ? a->inputError.c_str() : "") + "}";
}


// API 23: how late one side of the device is, in the engine's frames, and where the figure came from.
struct SideLatency {
    int64_t frames = 0;
    const char* source = "none";  // "timestamp" (AAudio's presentation time), "buffers" (the queued periods), "none"
    int32_t deviceId = 0;         // AAudio's routed device id (AudioDeviceInfo.getId() on Android); 0 elsewhere
    const char* kind = "unknown"; // the endpoint's link, where the backend says (WASAPI); the app's AudioDeviceKind names
};

#if defined(_WIN32)
// The kind of link a WASAPI endpoint is, from its property store: the bus that enumerated it
// (DEVPKEY_Device_EnumeratorName: [Assumption] "BTHENUM" for classic Bluetooth audio, "BTHLEDEVICE" for Bluetooth LE,
// "USB" for USB audio, the names Windows' bus drivers use in hardware ids) and else its EndpointFormFactor
// (PKEY_AudioEndpoint_FormFactor, VT_UI4; Microsoft Learn, read 2026-11-12). ole32 is loaded at run time, as
// miniaudio does. Called off the audio thread (caw_audio_latency); COM is initialised for the call.
const char* wasapiKind(const wchar_t* id) {
    if (!id || !id[0]) return "unknown";
    HMODULE ole = LoadLibraryW(L"ole32.dll");
    if (!ole) return "unknown";
    using CoInit = HRESULT(WINAPI*)(LPVOID, DWORD);
    using CoUninit = void(WINAPI*)();
    using CoCreate = HRESULT(WINAPI*)(REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*);
    using PvClear = HRESULT(WINAPI*)(PROPVARIANT*);
    auto coInit = reinterpret_cast<CoInit>(reinterpret_cast<void*>(GetProcAddress(ole, "CoInitializeEx")));
    auto coUninit = reinterpret_cast<CoUninit>(reinterpret_cast<void*>(GetProcAddress(ole, "CoUninitialize")));
    auto coCreate = reinterpret_cast<CoCreate>(reinterpret_cast<void*>(GetProcAddress(ole, "CoCreateInstance")));
    auto pvClear = reinterpret_cast<PvClear>(reinterpret_cast<void*>(GetProcAddress(ole, "PropVariantClear")));
    const char* kind = "unknown";
    if (coInit && coUninit && coCreate && pvClear) {
        const HRESULT init = coInit(nullptr, COINIT_MULTITHREADED);
        static const CLSID kEnumerator = {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
        static const IID kIEnumerator = {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
        static const PROPERTYKEY kFormFactor = {{0x1da5d803, 0xd492, 0x4edd, {0x8c, 0x23, 0xe0, 0xc0, 0xff, 0xee, 0x7f, 0x0e}}, 0};
        static const PROPERTYKEY kBus = {{0xa45c254e, 0xdf1c, 0x4efd, {0x80, 0x20, 0x67, 0xd1, 0x46, 0xa8, 0x50, 0xe0}}, 24};
        IMMDeviceEnumerator* en = nullptr;
        if (SUCCEEDED(coCreate(kEnumerator, nullptr, CLSCTX_ALL, kIEnumerator, reinterpret_cast<void**>(&en))) && en) {
            IMMDevice* dev = nullptr;
            if (SUCCEEDED(en->GetDevice(id, &dev)) && dev) {
                IPropertyStore* store = nullptr;
                if (SUCCEEDED(dev->OpenPropertyStore(STGM_READ, &store)) && store) {
                    PROPVARIANT v;
                    PropVariantInit(&v);
                    if (SUCCEEDED(store->GetValue(kBus, &v)) && v.vt == VT_LPWSTR && v.pwszVal) {
                        const wchar_t* b = v.pwszVal;
                        if (_wcsicmp(b, L"BTHENUM") == 0) kind = "bluetooth";
                        else if (_wcsnicmp(b, L"BTHLE", 5) == 0) kind = "bluetoothLe";
                        else if (_wcsicmp(b, L"USB") == 0) kind = "usb";
                    }
                    pvClear(&v);
                    if (std::strcmp(kind, "unknown") == 0) {
                        PropVariantInit(&v);
                        if (SUCCEEDED(store->GetValue(kFormFactor, &v)) && v.vt == VT_UI4) {
                            switch (v.ulVal) {  // EndpointFormFactor
                                case 0: kind = "remote"; break;                  // RemoteNetworkDevice
                                case 1: case 4: kind = "builtIn"; break;         // Speakers, Microphone
                                case 2: case 3: case 5: case 8: kind = "wired"; break;  // LineLevel, Headphones, Headset, SPDIF
                                case 9: kind = "hdmi"; break;                    // DigitalAudioDisplayDevice (HDMI, DisplayPort)
                                default: break;
                            }
                        }
                        pvClear(&v);
                    }
                    store->Release();
                }
                dev->Release();
            }
            en->Release();
        }
        if (init == S_OK || init == S_FALSE) coUninit();
    }
    FreeLibrary(ole);
    return kind;
}
#endif

int64_t toEngineFrames(int64_t frames, ma_uint32 deviceRate, int engineRate) {
    if (deviceRate == 0 || static_cast<int>(deviceRate) == engineRate) return frames;
    return frames * engineRate / static_cast<int64_t>(deviceRate);
}

// Every queued period of one side, at the engine's rate: the whole latency where nothing better is known
// (WASAPI, ALSA, PulseAudio). [Assumption] a converter, the driver and the speaker (or a Bluetooth link) add more;
// the per-device offset in the app covers that.
SideLatency bufferLatency(const ma_uint32 period, const ma_uint32 periods, const ma_uint32 rate, int engineRate) {
    SideLatency s;
    s.frames = toEngineFrames(static_cast<int64_t>(period) * std::max<ma_uint32>(1, periods), rate, engineRate);
    s.source = s.frames > 0 ? "buffers" : "none";
    return s;
}

#if defined(__ANDROID__)
// AAudio's own figure, from AAudioStream_getTimestamp (NDK API 26: the time a frame was played on the speaker or
// headset, or recorded on the microphone): the next frame written (read) reaches the speaker at (was recorded at)
// that time plus the frames between them, so the latency is how far that lies from now. The same reckoning as
// Oboe's AudioStream::calculateLatencyMillis. Looked up in the libaaudio.so miniaudio opened, as the modes are.
// Called with the device's reroute lock held, so the stream stays the one miniaudio has. False when no timestamp
// is available yet (a stream that has only just started) or the figure is out of range.
bool aaudioLatency(Audio* a, void* stream, bool output, int engineRate, SideLatency& out) {
    if (!stream || !a->context.aaudio.hAAudio) return false;
    void* lib = a->context.aaudio.hAAudio;
    using Timestamp = int32_t (*)(void*, int32_t, int64_t*, int64_t*);
    using Frames = int64_t (*)(void*);
    using Int = int32_t (*)(void*);
    auto timestamp = reinterpret_cast<Timestamp>(dlsym(lib, "AAudioStream_getTimestamp"));
    auto frames = reinterpret_cast<Frames>(dlsym(lib, output ? "AAudioStream_getFramesWritten" : "AAudioStream_getFramesRead"));
    auto rate = reinterpret_cast<Int>(dlsym(lib, "AAudioStream_getSampleRate"));
    auto device = reinterpret_cast<Int>(dlsym(lib, "AAudioStream_getDeviceId"));
    if (device) out.deviceId = device(stream);
    if (!timestamp || !frames || !rate) return false;
    int64_t position = 0, timeNs = 0;
    if (timestamp(stream, CLOCK_MONOTONIC, &position, &timeNs) != 0) return false;  // AAUDIO_OK is 0
    const int32_t sr = rate(stream);
    if (sr <= 0 || timeNs <= 0) return false;
    const int64_t app = frames(stream);
    timespec now{};
    clock_gettime(CLOCK_MONOTONIC, &now);
    const int64_t nowNs = static_cast<int64_t>(now.tv_sec) * 1000000000LL + now.tv_nsec;
    const int64_t at = timeNs + (app - position) * 1000000000LL / sr;
    const int64_t ns = output ? at - nowNs : nowNs - at;
    if (ns <= 0 || ns > 2000000000LL) return false;  // stale or not yet meaningful
    out.frames = ns * engineRate / 1000000000LL;
    out.source = "timestamp";
    return true;
}
#endif

std::string sideJson(const SideLatency& s, int engineRate, bool running) {
    const double ms = engineRate > 0 ? static_cast<double>(s.frames) * 1000.0 / engineRate : 0.0;
    char buf[48];
    std::snprintf(buf, sizeof buf, "%.2f", ms);
    return std::string("{\"running\":") + (running ? "true" : "false") + ",\"frames\":" + std::to_string(s.frames) +
           ",\"ms\":" + buf + ",\"source\":\"" + s.source + "\",\"device_id\":" + std::to_string(s.deviceId) +
           ",\"kind\":\"" + s.kind + "\"}";
}

std::string latencyJson(CawEngine* e, Audio* a) {
    const int rate = static_cast<int>(e->engine->sampleRate());
    if (!a) return "{\"running\":false,\"sample_rate\":" + std::to_string(rate) + ",\"output\":" +
                   sideJson(SideLatency{}, rate, false) + ",\"input\":" + sideJson(SideLatency{}, rate, false) + "}";
    const auto& p = a->device.playback;
    const auto& c = a->device.capture;
    SideLatency out = bufferLatency(p.internalPeriodSizeInFrames, p.internalPeriods, p.internalSampleRate, rate);
    SideLatency in;
    if (a->input) in = bufferLatency(c.internalPeriodSizeInFrames, c.internalPeriods, c.internalSampleRate, rate);
#if defined(__ANDROID__)
    if (a->context.backend == ma_backend_aaudio) {
        ma_mutex_lock(&a->device.aaudio.rerouteLock);
        SideLatency t;
        if (aaudioLatency(a, a->device.aaudio.pStreamPlayback, true, rate, t)) out = t;
        else out.deviceId = t.deviceId;
        if (a->input) {
            SideLatency ti;
            if (aaudioLatency(a, a->device.aaudio.pStreamCapture, false, rate, ti)) in = ti;
            else in.deviceId = ti.deviceId;
        }
        ma_mutex_unlock(&a->device.aaudio.rerouteLock);
    }
#endif
#if defined(_WIN32)
    if (a->context.backend == ma_backend_wasapi) {
        auto cached = [](const wchar_t* id, std::wstring& lastId, const char*& kind) {
            if (lastId != id) { lastId = id; kind = wasapiKind(id); }
            return kind;
        };
        out.kind = cached(a->device.playback.id.wasapi, a->kindOutId, a->kindOut);
        if (a->input) in.kind = cached(a->device.capture.id.wasapi, a->kindInId, a->kindIn);
    }
#endif
    // The duplex ring buffer's two capture periods (see openDevice) hold the input back before the callback reads it.
    if (a->input) in.frames += toEngineFrames(a->duplexBufferFrames, c.internalSampleRate, rate);
    return "{\"running\":true,\"sample_rate\":" + std::to_string(rate) + ",\"output\":" + sideJson(out, rate, true) +
           ",\"input\":" + sideJson(in, rate, a->input) + "}";
}

}  // namespace

int32_t cawAudioXruns(CawEngine* e) {
#if defined(__ANDROID__)
    std::lock_guard<std::mutex> lock(gDeviceLock);
    if (!e || !e->audio) return -1;
    auto* a = static_cast<Audio*>(e->audio);
    if (a->context.backend != ma_backend_aaudio || !a->context.aaudio.hAAudio || !a->device.aaudio.pStreamPlayback) return -1;
    // AAudioStream_getXRunCount (NDK API 26; miniaudio 0.11.25 does not load it): underruns since the stream opened.
    using Getter = int32_t (*)(void*);
    auto xruns = reinterpret_cast<Getter>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getXRunCount"));
    if (!xruns) return -1;
    const int32_t n = xruns(a->device.aaudio.pStreamPlayback);
    return n >= 0 ? n : -1;
#else
    (void)e;
    return -1;  // elsewhere this reads no underrun count (miniaudio passes none on)
#endif
}

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
    if (!e) return;  // a reopen that fails leaves the device closed: caw_audio_status says so
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
            out += "{\"name\":" + quoted(playback[i].name) +
                   ",\"id\":" + quoted(deviceIdText(context.backend, playback[i].id).c_str()) +
                   ",\"default\":" + (playback[i].isDefault ? "true" : "false");
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

int32_t caw_audio_configure(CawEngine* e, const char* device_id, const char* device_name, int32_t period_frames,
                            int32_t flags) {
    if (!e) return 1;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    std::string id = device_id ? std::string(device_id).substr(0, 511) : std::string();
    std::string name = device_name ? std::string(device_name).substr(0, MA_MAX_DEVICE_NAME_LENGTH) : std::string();
    const int frames = period_frames <= 0 ? 0 : period_frames < 16 ? 16 : period_frames > 8192 ? 8192 : period_frames;
    const int f = flags & CAW_AUDIO_EXCLUSIVE;
    if (id == e->deviceId && name == e->deviceName && frames == e->periodFrames && f == e->audioFlags) {
        const auto* a = static_cast<const Audio*>(e->audio);
        return a && a->fallback ? 2 : 0;
    }
    e->deviceId = std::move(id);
    e->deviceName = std::move(name);
    e->periodFrames = frames;
    e->audioFlags = f;
    return reopenLocked(e);
}

char* caw_audio_input_devices(void) {
    ma_context context;
    if (ma_context_init(nullptr, 0, nullptr, &context) != MA_SUCCESS)
        return dup("{\"backend\":\"none\",\"exclusive\":false,\"devices\":[]}");
    std::string out = "{\"backend\":" + quoted(ma_get_backend_name(context.backend)) + ",\"exclusive\":false,\"devices\":[";
    ma_device_info* capture = nullptr;
    ma_uint32 count = 0;
    if (ma_context_get_devices(&context, nullptr, nullptr, &capture, &count) == MA_SUCCESS) {
        for (ma_uint32 i = 0; i < count; ++i) {
            ma_uint32 channels = 0;
            std::vector<ma_uint32> rates;
            ma_device_info info;
            if (ma_context_get_device_info(&context, ma_device_type_capture, &capture[i].id, &info) == MA_SUCCESS)
                for (ma_uint32 f = 0; f < info.nativeDataFormatCount; ++f) {
                    channels = std::max(channels, info.nativeDataFormats[f].channels);
                    const ma_uint32 rate = info.nativeDataFormats[f].sampleRate;
                    if (std::find(rates.begin(), rates.end(), rate) == rates.end()) rates.push_back(rate);
                }
            std::sort(rates.begin(), rates.end());
            std::string list;
            for (const ma_uint32 v : rates) list += (list.empty() ? "" : ",") + std::to_string(v);
            out += std::string(i ? "," : "") + "{\"name\":" + quoted(capture[i].name) +
                   ",\"id\":" + quoted(deviceIdText(context.backend, capture[i].id).c_str()) +
                   ",\"default\":" + (capture[i].isDefault ? "true" : "false") + ",\"channels\":" + std::to_string(channels) +
                   ",\"rates\":[" + list + "],\"exclusive_rates\":[]}";
        }
    }
    ma_context_uninit(&context);
    return dup(out + "]}");
}

int32_t caw_audio_configure_input(CawEngine* e, int32_t enabled, const char* device_id, const char* device_name,
                                  int32_t channels) {
    if (!e) return 1;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    const bool on = enabled != 0;
    std::string id = device_id ? std::string(device_id).substr(0, 511) : std::string();
    std::string name = device_name ? std::string(device_name).substr(0, MA_MAX_DEVICE_NAME_LENGTH) : std::string();
    const int ch = channels <= 0 ? 2 : (channels > 32 ? 32 : channels);
    const auto* running = static_cast<const Audio*>(e->audio);
    // Unchanged, and either off or already open: nothing to do. Asked again with input on while the device runs
    // without it (it failed to open, say because RECORD_AUDIO was not granted yet), it is tried again.
    if (on == e->inputEnabled && id == e->inputId && name == e->inputName && ch == e->inputChannels &&
        (!on || !running || running->input))
        return running && running->fallback ? 2 : 0;
    e->inputEnabled = on;
    e->inputId = std::move(id);
    e->inputName = std::move(name);
    e->inputChannels = ch;
    return reopenLocked(e);
}

char* caw_audio_status(CawEngine* e) {
    if (!e) return dup("{\"running\":false}");
    std::lock_guard<std::mutex> lock(gDeviceLock);
    const std::string request = ",\"requested_device\":" + quoted(e->deviceName.c_str()) +
                                ",\"requested_device_id\":" + quoted(e->deviceId.c_str()) +
                                ",\"requested_frames\":" + std::to_string(e->periodFrames) +
                                ",\"exclusive_requested\":" + ((e->audioFlags & CAW_AUDIO_EXCLUSIVE) ? "true" : "false");
    const auto* a = static_cast<const Audio*>(e->audio);
    if (!a) return dup("{\"running\":false" + request + ",\"input\":" + inputStatus(e, nullptr) + "}");
    const auto& p = a->device.playback;
    return dup("{\"running\":true,\"backend\":" + quoted(ma_get_backend_name(a->context.backend)) +
               ",\"device\":" + quoted(p.name) + ",\"device_id\":" + quoted(a->deviceId.c_str()) +
               ",\"sample_rate\":" + std::to_string(p.internalSampleRate) +
               ",\"period_frames\":" + std::to_string(p.internalPeriodSizeInFrames) +
               ",\"periods\":" + std::to_string(p.internalPeriods) +
               ",\"exclusive\":" + (a->exclusive ? "true" : "false") +
               ",\"low_latency\":" + (a->lowLatency ? "true" : "false") +
               ",\"modes_read_back\":" + (a->modesReadBack ? "true" : "false") +
               ",\"fallback\":" + (a->fallback ? "true" : "false") +
               ",\"fallback_reason\":" + quoted(a->fallbackReason.c_str()) + request + ",\"input\":" + inputStatus(e, a) + "}");
}

char* caw_audio_latency(CawEngine* e) {
    if (!e) return dup("{\"running\":false}");
    std::lock_guard<std::mutex> lock(gDeviceLock);
    return dup(latencyJson(e, static_cast<Audio*>(e->audio)));
}

}  // extern "C"
