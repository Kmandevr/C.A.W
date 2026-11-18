// Audio output through miniaudio (AAudio on Android, WASAPI on Windows, Core Audio, ALSA/PulseAudio), with load metering.
#include <atomic>
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
#include <sys/system_properties.h>
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
#include <audioclient.h>
#endif

#include "caw.h"
#include "capi_internal.h"
#include "buffer_tuner.h"
#include "device_choice.h"
#include "device_period.h"
#include "device_render.h"
#include "input_bridge.h"
#include "miniaudio.h"

namespace {

// One audio output per process. When Android recreates the app's screen (it lost focus while playing, say), a new
// copy of the app starts with a new engine while the old one, which nothing controls any more, may still be
// playing; the two would sound together. Starting audio on an engine therefore closes any other engine's device.
// Only the control calls take these locks (never the audio callback). gOpLock is held through each call that opens,
// closes or reconfigures a device (taken first), gDeviceLock only while the shared state changes, so the status and
// latency polls (gDeviceLock alone) never wait for a slow device open, and no context is destroyed under an open.
std::mutex gOpLock;
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
    // The input (API 18): a capture device of its own beside the output (never duplex), open only while the app
    // asks for it, feeding the output callback through the bridge; `input` while it is open, else why it did not
    // open. A capture that stops, starves or fails never touches the output: its frames are silence.
    ma_device* capture = nullptr;  // its own allocation per open (swapped in under the lock), null while closed
    bool input = false;
    ma_uint32 inputChannels = 0;
    ma_uint32 duplexBufferFrames = 0;  // the bridge's starting fill, in the latency estimate
    std::string inputDeviceId, inputError;
    // The chosen input did not open, so the default records (#242); why, for the status ("" when it did).
    std::string inputFallbackReason;
    caw::InputBridge bridge;
    // Behind the app (caw_audio_set_background): the output's AAudio buffer raised toward its capacity, and the
    // size to restore on return.
    bool background = false;
    int32_t savedBufferFrames = 0;
    // The buffer's automatic size (caw_audio_tune_buffer, #236; control thread, under gDeviceLock): which stream it
    // tunes, by `streams` (each open and each reroute counts one, so a new stream starts it again even where the
    // allocator hands back the old stream's address), when it last looked and in which playback (the engine's Play
    // count: the time between two playbacks is not quiet time).
    caw::BufferTuner tuner;
    std::atomic<uint32_t> streams{0};
    uint32_t tunedStreams = 0;
    uint64_t tunedPlays = 0;
    std::chrono::steady_clock::time_point tunedAt{};
#if defined(_WIN32)
    // The last WASAPI endpoint ids read for their kind, so caw_audio_latency's polls skip COM until the device moves.
    std::wstring kindOutId, kindInId;
    const char* kindOut = "unknown";
    const char* kindIn = "unknown";
#endif
    // The output: the engine renders whole kBlock-frame blocks whatever size the callback is (DeviceRender's
    // BlockFifo, the owner's fixed-block idea, 2026-11-12), unless the period is small and not whole blocks, with
    // or without the input open (switching paths while running would drop or repeat the held frames). Fresh at
    // every open; never flushed while running (a Play or Stop keeps the frames it holds: device_render.h).
    caw::DeviceRender render;
    int fifoLatency = 0;   // the most frames it holds back (0 when the period is whole blocks): the bridge's fill covers it
    // The size the callback is called with: miniaudio's fixed size (its intermediary buffer), or, where the output
    // takes AAudio's own sizes (deviceSizes, takesDeviceSizes), the stream's burst, which a low-latency stream
    // calls back with. The status reports it as period_frames.
    int callbackFrames = 0;
    bool deviceSizes = false;
    // AAudio: the output's buffer size (getBufferSizeInFrames: the frames queued ahead of the speaker, about two
    // bursts on a low-latency stream; 0 unknown), read at open, after a reroute and behind the app.
    int32_t bufferFrames = 0;
    // Set by miniaudio's job thread when an AAudio reroute rebuilt the stream (another burst, buffer and modes); the
    // control thread's next status, latency or size call reads them again (refreshAfterReroute).
    std::atomic<bool> rerouted{false};
    // Set with it when the output was opened at a fixed size on AAudio: the rebuilt stream is given no size
    // (miniaudio does not carry allowSetBufferCapacity over), so AAudio calls back with its own sizes under
    // miniaudio's fixed one, a whole fixed-size render inside one burst's callback. The control thread reopens the
    // device at its settings (reopenAfterReroute).
    std::atomic<bool> reopen{false};
    int fifoMeanHold = 0;  // the frames it holds back on average: in the latency figures that align recordings
    // #241's diagnostic (caw_audio_status "clock" and the input's counters): what the streams have done since they
    // opened, so a device run shows whether frames go missing between the capture, the engine and the speaker.
    // Relaxed atomics, each written on one callback's thread only; reset before the stream starts.
    std::atomic<int64_t> outCallbacks{0}, outFrames{0}, outRendered{0}, outLate{0};
    std::atomic<int32_t> outMin{0}, outMax{0};
    std::chrono::steady_clock::time_point openedAt{}, inputOpenedAt{};
    // Low latency on WASAPI (#237): the engine's periods read before the open (wasapiPeriods) and the smallest
    // period asked from them (0: none asked, miniaudio's 10 ms default), with where it came from ("shared_engine":
    // IAudioClient3's shared-mode engine period, "device_period": the exclusive minimum, "none").
    uint32_t smallestFrames = 0;
    const char* periodSource = "none";
    uint32_t enginePeriods[4] = {};  // shared-mode default, fundamental, min, max (frames; 0 unread)
    uint32_t mixRate = 0;            // the engine's mix rate the shared periods are for
    int64_t devicePeriodHns = 0;     // the exclusive-mode minimum device period (100 ns)
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

#if defined(__ANDROID__)
int androidSdk() {
    char v[PROP_VALUE_MAX] = {};
    return __system_property_get("ro.build.version.sdk", v) > 0 ? std::atoi(v) : 0;
}
#endif

// Whether the output takes the device's own callback sizes (miniaudio's noFixedSizedCallback) instead of miniaudio's
// fixed size. On AAudio, when the size is not given to the stream (no size asked, or Android 11 and older, where
// miniaudio's compatibility workarounds keep it from the stream), miniaudio's fixed size falls back to the
// stream's whole buffer capacity in one period ([Fact] miniaudio 0.11.25 source, read 2026-11-13:
// ma_device_init_by_type__aaudio sets periodSizeInFrames = bufferCapacityInFrames, periodCount 1, when
// getFramesPerDataCallback is unspecified; ma_device_init sizes the intermediary buffer from it): about 1950
// frames (40 ms) where AAudio calls back a burst (96 to 192 frames) at a time, so one burst's callback rendered
// the whole capacity and missed its deadline at a fraction of the load. AAudio's own sizes are what its
// documentation recommends for the lowest latency (AAudioStreamBuilder_setFramesPerDataCallback: "do not call
// this function", read 2026-11-13). DeviceRender takes any size (whole blocks through its FIFO, or straight).
// Elsewhere miniaudio's period is the backend's own (WASAPI, Core Audio, ALSA and PulseAudio derive it from the
// asked size or miniaudio's default, 10 ms, 25 ms on PulseAudio, and call back with it), so the fixed size matches
// what the device asks.
bool takesDeviceSizes(ma_backend b, ma_uint32 frames) {
#if defined(__ANDROID__)
    return b == ma_backend_aaudio && (frames == 0 || androidSdk() <= 30);
#else
    (void)b;
    (void)frames;
    return false;
#endif
}

// A miniaudio context on its default backend order, or first on the one CAW_AUDIO_BACKEND names (#237; unset by
// default): a desktop override for the CLI and test runs, such as "jack", whose callback runs on the JACK server's
// real-time thread at the server's period ([Fact, miniaudio 0.11.25 source] ma_device_init__jack takes
// jack_get_buffer_size; the default order tries PulseAudio and ALSA first, so JACK is otherwise never reached while
// either opens). A name miniaudio does not know (ma_get_backend_from_name) or a backend that does not open falls
// back to the default order. Read on the control thread at each open. [overridden] (optional) says whether the
// named backend is the one that opened, so a caller whose device then fails on it can retry on the default order.
ma_result initContext(ma_context* context, bool* overridden = nullptr) {
    if (overridden) *overridden = false;
    if (const char* name = std::getenv("CAW_AUDIO_BACKEND"); name && name[0]) {
        ma_backend b;
        if (ma_get_backend_from_name(name, &b) == MA_SUCCESS && ma_context_init(&b, 1, nullptr, context) == MA_SUCCESS) {
            if (overridden) *overridden = true;
            return MA_SUCCESS;
        }
    }
    return ma_context_init(nullptr, 0, nullptr, context);
}

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
// getter, so they are looked up in the libaaudio.so it opened). Read at open, before the stream starts and on the
// opening thread, so no reroute can replace the stream meanwhile, and again after a reroute under its reroute lock
// (refreshAfterReroute).
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

// The stream's burst (AAudioStream_getFramesPerBurst, NDK API 26, which miniaudio loads), 0 if unknown.
int32_t aaudioBurst(const Audio* a) {
    if (a->context.backend != ma_backend_aaudio || !a->device.aaudio.pStreamPlayback || !a->context.aaudio.AAudioStream_getFramesPerBurst)
        return 0;
    using Getter = int32_t (*)(void*);
    const int32_t n = reinterpret_cast<Getter>(a->context.aaudio.AAudioStream_getFramesPerBurst)(a->device.aaudio.pStreamPlayback);
    return n > 0 && n <= 8192 ? n : 0;
}

// The stream's buffer size (AAudioStream_getBufferSizeInFrames, NDK API 26, looked up as setBackground does), 0 if
// unknown. The caller holds the reroute lock, or the stream has not started.
int32_t aaudioBufferFrames(const Audio* a) {
    if (a->context.backend != ma_backend_aaudio || !a->context.aaudio.hAAudio || !a->device.aaudio.pStreamPlayback) return 0;
    using Getter = int32_t (*)(void*);
    auto get = reinterpret_cast<Getter>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getBufferSizeInFrames"));
    const int32_t n = get ? get(a->device.aaudio.pStreamPlayback) : 0;
    return n > 0 ? n : 0;
}

// A stream's underruns (output) or overruns (input) since it opened (AAudioStream_getXRunCount, NDK API 26, looked
// up as above); -1 unknown. The caller holds that device's reroute lock.
int32_t aaudioXRuns(const Audio* a, void* stream) {
    if (a->context.backend != ma_backend_aaudio || !a->context.aaudio.hAAudio || !stream) return -1;
    using Getter = int32_t (*)(void*);
    auto get = reinterpret_cast<Getter>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getXRunCount"));
    return get ? get(stream) : -1;
}
// The device a stream runs on (AAudioStream_getDeviceId, NDK API 26: AudioDeviceInfo.getId()), 0 unknown. The caller
// holds that device's reroute lock, or the stream has not started.
int32_t aaudioStreamDevice(const Audio* a, void* stream) {
    if (a->context.backend != ma_backend_aaudio || !a->context.aaudio.hAAudio || !stream) return 0;
    using Getter = int32_t (*)(void*);
    auto get = reinterpret_cast<Getter>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getDeviceId"));
    const int32_t n = get ? get(stream) : 0;
    return n > 0 ? n : 0;
}
int32_t outputDevice(Audio* a) {
    if (a->context.backend != ma_backend_aaudio) return 0;
    ma_mutex_lock(&a->device.aaudio.rerouteLock);
    const int32_t n = aaudioStreamDevice(a, a->device.aaudio.pStreamPlayback);
    ma_mutex_unlock(&a->device.aaudio.rerouteLock);
    return n;
}
int32_t inputDevice(const Audio* a) {
    if (!a->capture || a->context.backend != ma_backend_aaudio) return 0;
    ma_mutex_lock(&a->capture->aaudio.rerouteLock);
    const int32_t n = aaudioStreamDevice(a, a->capture->aaudio.pStreamCapture);
    ma_mutex_unlock(&a->capture->aaudio.rerouteLock);
    return n;
}
int32_t outputXRuns(Audio* a) {
    if (a->context.backend != ma_backend_aaudio) return -1;  // the reroute lock is AAudio's
    ma_mutex_lock(&a->device.aaudio.rerouteLock);
    const int32_t n = aaudioXRuns(a, a->device.aaudio.pStreamPlayback);
    ma_mutex_unlock(&a->device.aaudio.rerouteLock);
    return n;
}
int32_t inputXRuns(const Audio* a) {
    if (!a->capture || a->context.backend != ma_backend_aaudio) return -1;
    ma_mutex_lock(&a->capture->aaudio.rerouteLock);
    const int32_t n = aaudioXRuns(a, a->capture->aaudio.pStreamCapture);
    ma_mutex_unlock(&a->capture->aaudio.rerouteLock);
    return n;
}
#else
int32_t outputDevice(Audio*) { return 0; }
int32_t inputDevice(const Audio*) { return 0; }
int32_t outputXRuns(Audio*) { return -1; }
int32_t inputXRuns(const Audio*) { return -1; }
void readAAudioModes(Audio*) {}
int32_t aaudioBurst(const Audio*) { return 0; }
int32_t aaudioBufferFrames(const Audio*) { return 0; }
#endif

// miniaudio's job thread, after an AAudio reroute rebuilt the stream (ma_device_reinit__aaudio keeps
// noFixedSizedCallback, so the output still takes the new stream's own sizes): only a flag, read on the control thread.
void notified(const ma_device_notification* n) {
    if (!n || n->type != ma_device_notification_type_rerouted || !n->pDevice || !n->pDevice->pUserData) return;
    auto* a = static_cast<Audio*>(n->pDevice->pUserData);
    // deviceSizes, frames and the backend are set before the device starts and never change while it runs.
    if (!a->deviceSizes && a->frames > 0 && a->context.backend == ma_backend_aaudio) a->reopen.store(true, std::memory_order_release);
    // WASAPI (#237): the rebuilt stream asks the period found for the old endpoint; if the new one did not give it
    // (miniaudio's quiet IAudioClient fallback, a 3-period buffer), the control thread reopens the device at its
    // settings, which looks at the new endpoint's periods and checks what opens (openDevice).
    if (a->context.backend == ma_backend_wasapi && a->smallestFrames > 0 &&
        n->pDevice->playback.internalPeriodSizeInFrames != a->smallestFrames)
        a->reopen.store(true, std::memory_order_release);
    a->streams.fetch_add(1, std::memory_order_release);
    a->rerouted.store(true, std::memory_order_release);
    // The new stream fills its buffer as a fresh device's does (an atomic store; the engine outlives its device).
    a->owner->engine->requestDeviceWarmUp();
}

// Under gDeviceLock, before a status, latency or size is reported: after a reroute, the new stream's modes, burst
// and buffer, under its reroute lock. The callback's renderer needs nothing (it chooses its path per callback, for
// any size: DeviceRender::openVarying), and the input's bridge keeps the fill it opened with, sized from the
// stream's capacity (attachCapture), which covers the new stream's callbacks too.
void refreshAfterReroute(Audio* a) {
    if (!a->rerouted.exchange(false, std::memory_order_acq_rel)) return;
#if defined(__ANDROID__)
    if (a->context.backend != ma_backend_aaudio) return;
    ma_mutex_lock(&a->device.aaudio.rerouteLock);
    if (a->device.aaudio.pStreamPlayback) {
        readAAudioModes(a);
        if (a->deviceSizes)
            if (const int32_t burst = aaudioBurst(a); burst > 0) a->callbackFrames = burst;
        a->bufferFrames = aaudioBufferFrames(a);
    }
    ma_mutex_unlock(&a->device.aaudio.rerouteLock);
#endif
}

// The output's callback size as reported (period_frames) and the periods that make up its buffer with it.
int32_t reportedPeriod(const Audio* a) {
    return a->callbackFrames > 0 ? a->callbackFrames : static_cast<int32_t>(a->device.playback.internalPeriodSizeInFrames);
}
// Where the output takes AAudio's sizes the buffer is the stream's buffer size (what is queued), not miniaudio's
// period count, which is then the whole capacity in one period.
int32_t reportedPeriods(const Audio* a) {
    const auto& p = a->device.playback;
    // AAudio's queue (its buffer size, at a fixed size too: miniaudio's periods there are the capacity, #241) in
    // callbacks; elsewhere the backend's periods.
    if (!a->deviceSizes && a->bufferFrames <= 0) return static_cast<int32_t>(p.internalPeriods);
    return caw::queuedPeriods(caw::queuedOutputFrames(a->bufferFrames, p.internalPeriodSizeInFrames, p.internalPeriods),
                              a->callbackFrames, p.internalPeriods);
}

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
    (void)input;  // a playback device: the input comes through the bridge
    // The Benchmark's live mode: process() timed apart, so the rest of the callback is its device I/O part.
    CawStressStats* const stress = a->owner->stress.load(std::memory_order_acquire);
    a->render.timeProcess(stress != nullptr);
    a->bridge.beginCallback(static_cast<int>(frames));  // its drift loop samples the fill once a callback
    // Fixed blocks through the FIFO (device_render.h), or straight for a small odd period. The bridge's input is
    // pulled for each block the engine renders, so it follows the frames rendered, not the frames played (they
    // differ by what the FIFO holds); silence where the input is missing, none while it is closed.
    const int rendered = a->render.render(*a->owner->engine, out, static_cast<int>(frames),
                                          [a](int m, int& ch) { return a->bridge.pull(m, ch); });
    const double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double budget = static_cast<double>(frames) / static_cast<double>(dev->sampleRate);
    // The load per frame rendered: through the FIFO a callback renders more or fewer frames than it plays.
    a->owner->engine->reportLoad(budget > 0 ? used / budget : 0.0, static_cast<int>(frames), rendered);
    // The clock diagnostic (#241): this thread is the only writer.
    a->outCallbacks.fetch_add(1, std::memory_order_relaxed);
    a->outFrames.fetch_add(frames, std::memory_order_relaxed);
    a->outRendered.fetch_add(rendered, std::memory_order_relaxed);
    if (used > budget) a->outLate.fetch_add(1, std::memory_order_relaxed);
    const int32_t n = static_cast<int32_t>(frames);
    if (const int32_t lo = a->outMin.load(std::memory_order_relaxed); lo == 0 || n < lo) a->outMin.store(n, std::memory_order_relaxed);
    if (n > a->outMax.load(std::memory_order_relaxed)) a->outMax.store(n, std::memory_order_relaxed);
    // The Benchmark's live mode, after the timed span: silent output whatever was rendered (zeros, never a scaled
    // NaN), and the callback recorded; its core is read on the first callback and every kCoreEvery-th
    // (sched_getcpu can be a system call), -1 meaning "not read this time".
    if (a->owner->muteOutput.load(std::memory_order_relaxed)) std::fill(out, out + static_cast<size_t>(frames) * 2, 0.0f);
    if (stress)
        stress->record(used, budget, static_cast<int32_t>(frames), stress->coreDue() ? callbackCore() : -1,
                       a->render.takeProcessNs());
}

// The capture device's callback: its frames into the bridge, nothing else.
void captureCallback(ma_device* dev, void* output, const void* input, ma_uint32 frames) {
    (void)output;
    static_cast<Audio*>(dev->pUserData)->bridge.push(static_cast<const float*>(input), static_cast<int>(frames));
}

#if defined(__ANDROID__)
ma_result signalJob(ma_job* job) {
    ma_event_signal(reinterpret_cast<ma_event*>(job->data.custom.data0));
    return MA_SUCCESS;
}
#endif

// Before a device is uninitialised, no reroute job may still be queued for it: miniaudio's AAudio error callback
// posts one to the context's job thread (ma_stream_error_callback__aaudio), and run after ma_device_uninit it would
// lock the device's destroyed reroute mutex ([Fact] miniaudio 0.11.25 source, read 2026-11-12:
// ma_job_process__device__aaudio_reroute; ma_device_uninit__aaudio sets isTearingDown and then destroys the
// mutex without waiting for the queue). So the device is marked as tearing down first (no new job is posted), and a
// job posted after any earlier ones is waited for: the job thread runs them in order.
void drainRerouteJobs(Audio* a, ma_device* d) {
#if defined(__ANDROID__)
    if (!d || a->context.backend != ma_backend_aaudio) return;
    __atomic_store_n(&d->aaudio.isTearingDown.value, MA_TRUE, __ATOMIC_SEQ_CST);
    ma_event done;
    if (ma_event_init(&done) != MA_SUCCESS) return;
    ma_job job = ma_job_init(MA_JOB_TYPE_CUSTOM);
    job.data.custom.proc = signalJob;
    job.data.custom.data0 = reinterpret_cast<ma_uintptr>(&done);
    if (ma_device_job_thread_post(&a->context.aaudio.jobThread, &job) == MA_SUCCESS) ma_event_wait(&done);
    ma_event_uninit(&done);
#else
    (void)a;
    (void)d;
#endif
}

// Under gDeviceLock: takes the input out (the output plays on, its input silence from the next chunk) and returns
// its device, for destroyCapture after the lock.
ma_device* detachCapture(CawEngine* e, Audio* a) {
    ma_device* d = a->capture;
    a->capture = nullptr;
    a->bridge.close();  // no pull() reads it from here; a push() still running is ignored once it sees it closed
    a->input = false;
    a->inputChannels = 0;
    a->duplexBufferFrames = 0;
    a->inputDeviceId.clear();
    e->engine->liveAudio().setDeviceChannels(0);
    return d;
}

// Outside gDeviceLock (gOpLock held, so the context lives): stops and frees a detached capture device. The capture
// callback has stopped once ma_device_uninit returns.
void destroyCapture(Audio* a, ma_device* d) {
    if (!d) return;
    drainRerouteJobs(a, d);
    ma_device_uninit(d);
    delete d;
}

// Closes the input alone, all under the caller's locks.
void closeCapture(CawEngine* e, Audio* a) {
    if (a->capture) destroyCapture(a, detachCapture(e, a));
    else detachCapture(e, a);
}

// Whether the input is open and delivering: its device still started (an AAudio stream that could not be reopened
// after a disconnect is stopped by miniaudio) and not starved for longer than the bridge allows.
bool captureHealthy(const Audio* a) {
    return a->input && a->capture && ma_device_get_state(a->capture) == ma_device_state_started && !a->bridge.stalled();
}

void setError(const std::string& msg, char* error, int32_t len) {
    if (!error || len <= 0) return;
    std::strncpy(error, msg.c_str(), static_cast<size_t>(len - 1));
    error[len - 1] = '\0';
}

void stopLocked(CawEngine* e) {
    if (!e || !e->audio) return;
    auto* a = static_cast<Audio*>(e->audio);
    closeCapture(e, a);
    drainRerouteJobs(a, &a->device);
    ma_device_uninit(&a->device);  // the callback has stopped once this returns
    e->engine->stopLiveMixPool();   // so the workers can go
    ma_context_uninit(&a->context);
    e->engine->liveAudio().setDeviceChannels(0);
    delete a;
    e->audio = nullptr;
    e->engine->resetTestTone();  // a tone cut off here would otherwise say it sounds until the device reopens
    if (gActive == e) gActive = nullptr;
}

#if defined(_WIN32)
// IAudioClient3's vtable, declared here as miniaudio 0.11.25 does (ma_IAudioClient3Vtbl), so no SDK's guard on the
// interface matters: IUnknown's 3 slots, IAudioClient's 12, IAudioClient2's 3, then GetSharedModeEnginePeriod.
struct AudioClient3Vtbl {
    void* unknown[2];
    ULONG(STDMETHODCALLTYPE* Release)(void*);
    void* audioClient[12];
    void* audioClient2[3];
    HRESULT(STDMETHODCALLTYPE* GetSharedModeEnginePeriod)(void*, const WAVEFORMATEX*, UINT32*, UINT32*, UINT32*, UINT32*);
};
struct AudioClient3 {
    AudioClient3Vtbl* v;
};

// The endpoint's periods for Low latency (#237), read before the open on a client of its own that is never
// initialised: the mix format's rate, the shared engine's periods (IAudioClient3::GetSharedModeEnginePeriod for that
// format, Windows 10+) and the exclusive minimum (IAudioClient::GetDevicePeriod). [Fact, Microsoft Learn
// IAudioClient::Initialize, read 2026-11-17] GetDevicePeriod and GetMixFormat "do not require that Initialize be
// called first". [id] null: the default render endpoint for the console role, as miniaudio opens it
// (ma_context_get_MMDevice__wasapi). ole32 at run time, COM initialised for the call, as wasapiKind does. Control
// thread only, never the audio thread.
void wasapiPeriods(Audio* a, const wchar_t* id) {
    HMODULE ole = LoadLibraryW(L"ole32.dll");
    if (!ole) return;
    using CoInit = HRESULT(WINAPI*)(LPVOID, DWORD);
    using CoUninit = void(WINAPI*)();
    using CoCreate = HRESULT(WINAPI*)(REFCLSID, LPUNKNOWN, DWORD, REFIID, LPVOID*);
    using CoFree = void(WINAPI*)(LPVOID);
    auto coInit = reinterpret_cast<CoInit>(reinterpret_cast<void*>(GetProcAddress(ole, "CoInitializeEx")));
    auto coUninit = reinterpret_cast<CoUninit>(reinterpret_cast<void*>(GetProcAddress(ole, "CoUninitialize")));
    auto coCreate = reinterpret_cast<CoCreate>(reinterpret_cast<void*>(GetProcAddress(ole, "CoCreateInstance")));
    auto coFree = reinterpret_cast<CoFree>(reinterpret_cast<void*>(GetProcAddress(ole, "CoTaskMemFree")));
    if (coInit && coUninit && coCreate && coFree) {
        const HRESULT init = coInit(nullptr, COINIT_MULTITHREADED);
        static const CLSID kEnumerator = {0xBCDE0395, 0xE52F, 0x467C, {0x8E, 0x3D, 0xC4, 0x57, 0x92, 0x91, 0x69, 0x2E}};
        static const IID kIEnumerator = {0xA95664D2, 0x9614, 0x4F35, {0xA7, 0x46, 0xDE, 0x8D, 0xB6, 0x36, 0x17, 0xE6}};
        static const IID kIAudioClient = {0x1CB9AD4C, 0xDBFA, 0x4C32, {0xB1, 0x78, 0xC2, 0xF5, 0x68, 0xA7, 0x03, 0xB2}};
        static const IID kIAudioClient3 = {0x7ED4EE07, 0x8E67, 0x4CD4, {0x8C, 0x1A, 0x2B, 0x7A, 0x59, 0x87, 0xAD, 0x42}};
        IMMDeviceEnumerator* en = nullptr;
        if (SUCCEEDED(coCreate(kEnumerator, nullptr, CLSCTX_ALL, kIEnumerator, reinterpret_cast<void**>(&en))) && en) {
            IMMDevice* dev = nullptr;
            const HRESULT got = id && id[0] ? en->GetDevice(id, &dev) : en->GetDefaultAudioEndpoint(eRender, eConsole, &dev);
            if (SUCCEEDED(got) && dev) {
                IAudioClient* client = nullptr;
                if (SUCCEEDED(dev->Activate(kIAudioClient, CLSCTX_ALL, nullptr, reinterpret_cast<void**>(&client))) && client) {
                    REFERENCE_TIME def = 0, min = 0;
                    if (SUCCEEDED(client->GetDevicePeriod(&def, &min))) a->devicePeriodHns = min;
                    WAVEFORMATEX* mix = nullptr;
                    if (SUCCEEDED(client->GetMixFormat(&mix)) && mix) {
                        a->mixRate = mix->nSamplesPerSec;
                        AudioClient3* c3 = nullptr;
                        if (SUCCEEDED(client->QueryInterface(kIAudioClient3, reinterpret_cast<void**>(&c3))) && c3) {
                            UINT32 p[4] = {};
                            if (SUCCEEDED(c3->v->GetSharedModeEnginePeriod(c3, mix, &p[0], &p[1], &p[2], &p[3])))
                                for (int i = 0; i < 4; ++i) a->enginePeriods[i] = p[i];
                            c3->v->Release(c3);
                        }
                        coFree(mix);
                    }
                    client->Release();
                }
                dev->Release();
            }
            en->Release();
        }
        if (init == S_OK || init == S_FALSE) coUninit();
    }
    FreeLibrary(ole);
}
#endif

// The period Low latency asks for where the backend's default is not its smallest (#237): on WASAPI, the smallest
// shared engine period of at least kSmallestPeriodFloor, or for exclusive mode the device's minimum period. 0
// elsewhere and whenever it is unknown: miniaudio's default then (10 ms on WASAPI, its own per backend).
// [Fact, miniaudio 0.11.25 source, ma_device_init_internal__wasapi, read 2026-11-17] shared mode tries
// IAudioClient3::InitializeSharedAudioStream with the asked period rounded down to the fundamental and clamped to
// min..max, only when WASAPI need not convert the rate (the engine's rate is the mix format's: else
// AUDCLNT_STREAMFLAGS_AUTOCONVERTPCM is set, which that call refuses), and falls back to IAudioClient::Initialize
// with the asked period times its 3 periods, which Windows raises to the engine's minimum buffer ([Fact, Microsoft
// Learn IAudioClient::Initialize]). So a mismatched rate leaves Low latency at 10 ms (the status's "mix_rate" says
// so) and the size asked is only ever a legal one.
// What smallestPeriod found, cleared at every open (and before each look), so a status never reports an earlier
// open's periods.
void clearPeriods(Audio* a) {
    a->smallestFrames = 0;
    a->periodSource = "none";
    a->mixRate = 0;
    a->devicePeriodHns = 0;
    for (auto& p : a->enginePeriods) p = 0;
}

ma_uint32 smallestPeriod(Audio* a, const CawEngine* e, const ma_device_id* id, bool exclusive) {
    clearPeriods(a);
#if defined(_WIN32)
    if (a->context.backend != ma_backend_wasapi || e->bufferMode != CAW_BUFFER_LOW_LATENCY) return 0;
    wasapiPeriods(a, id ? reinterpret_cast<const wchar_t*>(id->wasapi) : nullptr);
    const auto rate = static_cast<uint32_t>(e->engine->sampleRate());
    if (exclusive) {
        a->smallestFrames = caw::exclusivePeriodFrames(a->devicePeriodHns, rate);
        if (a->smallestFrames > 0) a->periodSource = "device_period";
    } else if (a->mixRate == rate) {
        a->smallestFrames = caw::smallestSharedPeriod(a->enginePeriods[1], a->enginePeriods[2], a->enginePeriods[3]);
        if (a->smallestFrames > 0) a->periodSource = "shared_engine";
    }
#else
    (void)e;
    (void)id;
    (void)exclusive;
#endif
    return a->smallestFrames;
}

// Opens and starts the device on [a]'s context: [id] (null: the default), [frames] a callback (0: the device's
// own), exclusive mode when asked and the backend takes it (shared if refused). MA_SUCCESS or why not.
ma_result openDevice(Audio* a, const CawEngine* e, const ma_device_id* id, ma_uint32 frames, bool exclusive,
                     std::string& why) {
    ma_device_config cfg = ma_device_config_init(ma_device_type_playback);
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
    // AAUDIO_USAGE_GAME (#236): [Fact, developer.android.com/games/sdk/oboe/low-latency-audio, read 2026-11-17] the
    // low-latency guide asks for it "to take full advantage of latency optimizations, especially when connected to
    // Bluetooth headsets". [Fact, AOSP AudioAttributes.java main, read 2026-11-17] USAGE_GAME's volume stream is
    // STREAM_MUSIC (toVolumeStreamType), the media volume, as USAGE_MEDIA's (AAudio's default); [Fact, NDK r30
    // aaudio/AAudio.h] API 28 (miniaudio skips it where setUsage is missing) and MEDIA and GAME are the two usages
    // other apps' playback capture may take. Kept over a reroute (miniaudio 0.11.25 ma_device_reinit__aaudio copies
    // aaudio.usage). Every AAudio route: the app can't tell the route before the stream opens.
    cfg.aaudio.usage = ma_aaudio_usage_game;
    cfg.performanceProfile = a->lowLatency ? ma_performance_profile_low_latency : ma_performance_profile_conservative;
    a->frames = frames;
    if (frames > 0) {
        cfg.periodSizeInFrames = frames;
        cfg.aaudio.allowSetBufferCapacity = MA_TRUE;
    }
    // Where AAudio is not given the size, the callback takes AAudio's own sizes (takesDeviceSizes).
    a->deviceSizes = takesDeviceSizes(a->context.backend, frames);
    cfg.noFixedSizedCallback = a->deviceSizes ? MA_TRUE : MA_FALSE;
    cfg.dataCallback = callback;
    cfg.notificationCallback = notified;
    cfg.pUserData = a;
    // WASAPI: miniaudio's audio thread joins MMCSS "Pro Audio" (AvSetMmThreadCharacteristicsA in
    // ma_device_start__wasapi_nolock, on that thread, miniaudio 0.11.25); the default usage joins no MMCSS task.
    // The mix pool's workers then join the same task (thread_tuning_win.cpp), never above the callback.
    cfg.wasapi.usage = ma_wasapi_usage_pro_audio;
    a->exclusive = exclusive && takesExclusive(a->context.backend);
    cfg.playback.shareMode = a->exclusive ? ma_share_mode_exclusive : ma_share_mode_shared;
    // Low latency with no size chosen: the smallest period the endpoint allows where the backend's default is not
    // it (WASAPI, smallestPeriod); a size that does not open falls back to the default before anything else does.
    // miniaudio may also open without the asked period: shared mode falls back from IAudioClient3 to
    // IAudioClient::Initialize quietly (a rate WASAPI must convert, a refusal), which leaves about 3 × the asked
    // period of buffer (some 9 ms at 144 frames) instead of the engine period. So a device whose period is not the
    // one asked is closed and opened again at the default, and the status says so ("refused", frames 0).
    clearPeriods(a);
    const auto init = [&] {
        const ma_uint32 at = frames == 0 ? smallestPeriod(a, e, id, a->exclusive) : 0;
        if (frames == 0) cfg.periodSizeInFrames = at;
        ma_result res = ma_device_init(&a->context, &cfg, &a->device);
        const bool refused = res == MA_SUCCESS && at > 0 && a->device.playback.internalPeriodSizeInFrames != at;
        if (refused) ma_device_uninit(&a->device);
        if (at > 0 && (res != MA_SUCCESS || refused)) {
            a->smallestFrames = 0;
            a->periodSource = refused ? "refused" : "none";
            cfg.periodSizeInFrames = 0;
            res = ma_device_init(&a->context, &cfg, &a->device);
        }
        return res;
    };
    ma_result r = init();
    if (r != MA_SUCCESS && a->exclusive) {
        // The device refused exclusive mode (another app holds it, or no native format fits): shared instead.
        a->exclusive = false;
        cfg.playback.shareMode = ma_share_mode_shared;
        r = init();
    }
    if (r != MA_SUCCESS) {
        why = std::string("can't open the audio device: ") + ma_result_description(r);
        return r;
    }
    readAAudioModes(a);
    a->streams.fetch_add(1, std::memory_order_release);  // a new stream for the buffer tuner
    // miniaudio calls back with a fixed size (its intermediary buffer, noFixedSizedCallback off), or with AAudio's
    // own sizes (its burst on a low-latency stream; any other size still renders right through DeviceRender).
    // What the FIFO holds back on top is at most a block short of one, unless that size is whole blocks.
    a->rerouted.store(false, std::memory_order_relaxed);
    a->bufferFrames = aaudioBufferFrames(a);  // not started yet: no reroute can replace the stream
    if (a->deviceSizes) {
        // The sizes vary (a reroute's new stream, the legacy path): the renderer picks its path per callback.
        const int32_t burst = aaudioBurst(a);
        a->callbackFrames = burst > 0 ? burst : static_cast<int>(a->device.playback.internalPeriodSizeInFrames);
        a->render.openVarying(a->callbackFrames);
    } else {
        a->callbackFrames = static_cast<int>(a->device.playback.intermediaryBufferCap);
        a->render.open(a->callbackFrames);
    }
    e->engine->requestSheddingReset();  // a fresh device: a throttled stretch before doesn't count
    for (auto* c : {&a->outCallbacks, &a->outFrames, &a->outRendered, &a->outLate}) c->store(0, std::memory_order_relaxed);
    a->outMin.store(0, std::memory_order_relaxed);
    a->outMax.store(0, std::memory_order_relaxed);
    a->openedAt = std::chrono::steady_clock::now();
    e->engine->requestDeviceWarmUp();   // nor its own first callbacks: the stream filling its buffer (#234)
    a->fifoLatency = a->render.latency();
    a->fifoMeanHold = a->render.meanHold();
    e->engine->resetTestTone();  // a request made while closed is stale (the callback is not running yet)
    try {
        e->engine->startLiveMixPool();  // the mix graph's workers (speed phase 5c), before the callback runs
    } catch (...) {
        // No pool: the graph runs on the callback thread alone.
    }
    r = ma_device_start(&a->device);
    if (r != MA_SUCCESS) {
        why = std::string("can't start the audio device: ") + ma_result_description(r);
        ma_device_uninit(&a->device);
        e->engine->stopLiveMixPool();
        return r;
    }
#if defined(_WIN32)
    // ma_device_start returns once the WASAPI thread has started (and joined MMCSS, or failed to).
    if (a->context.backend == ma_backend_wasapi) e->engine->setCallbackMmcss(a->device.wasapi.hAvrtHandle != nullptr);
#endif
    return MA_SUCCESS;
}

int64_t toEngineFrames(int64_t frames, ma_uint32 deviceRate, int engineRate) {
    if (deviceRate == 0 || static_cast<int>(deviceRate) == engineRate) return frames;
    return frames * engineRate / static_cast<int64_t>(deviceRate);
}

// What the input opens as, copied under the lock so the device can open outside it.
struct CaptureRequest {
    std::string id, name;
    int channels = 2;
    int rate = 48000;
    bool lowLatency = true;
};

CaptureRequest captureRequest(const CawEngine* e) {
    CaptureRequest q;
    q.id = e->inputId;
    q.name = e->inputName;
    q.channels = e->inputChannels;
    q.rate = static_cast<int>(e->engine->sampleRate());
    q.lowLatency = e->bufferMode != CAW_BUFFER_BATTERY;
    return q;
}

// Opens (not starts) a capture device on [a]'s context: the chosen one (by id, else by name; else the default,
// which on AAudio Android routes), 1..32 channels, shared, at the engine's rate. Touches no shared state, so it
// runs outside gDeviceLock (gOpLock held). Null and [why] when it did not open (no permission, no microphone,
// another app holding it); [deviceId] the id of a chosen device that opened.
//
// On AAudio, which lists only the default, the chosen device is named by its Android id ("aaudio:<id>",
// device_choice.h, #242). A chosen device that is found but does not open gives the default instead, with
// [fallback] saying why ("" when the choice opened or none was made).
ma_device* initCapture(Audio* a, const CaptureRequest& q, std::string& deviceId, std::string& why, std::string& fallback) {
    fallback.clear();
    ma_device_id chosen;
    bool found = false;
    if (a->context.backend == ma_backend_aaudio) {
        if (const int32_t n = caw::aaudioDeviceId(q.id); n > 0) {
            chosen.aaudio = n;
            found = true;
        }
    } else if (!q.id.empty() || !q.name.empty()) {
        ma_device_info* capture = nullptr;
        ma_uint32 count = 0;
        if (ma_context_get_devices(&a->context, nullptr, nullptr, &capture, &count) == MA_SUCCESS) {
            for (ma_uint32 i = 0; i < count && !found && !q.id.empty(); ++i)
                if (q.id == deviceIdText(a->context.backend, capture[i].id)) {
                    chosen = capture[i].id;
                    found = true;
                }
            for (ma_uint32 i = 0; i < count && !found && !q.name.empty(); ++i)
                if (q.name == capture[i].name) {
                    chosen = capture[i].id;
                    found = true;
                }
        }
    }
    ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
    cfg.capture.format = ma_format_f32;
    cfg.capture.channels = static_cast<ma_uint32>(q.channels);
    cfg.capture.pDeviceID = found ? &chosen : nullptr;
    cfg.capture.shareMode = ma_share_mode_shared;
    cfg.sampleRate = static_cast<ma_uint32>(q.rate);
    cfg.performanceProfile = q.lowLatency ? ma_performance_profile_low_latency : ma_performance_profile_conservative;
    cfg.dataCallback = captureCallback;
    cfg.pUserData = a;
    auto* d = new ma_device();
    ma_result r = ma_device_init(&a->context, &cfg, d);
    if (r != MA_SUCCESS && found) {
        // The chosen input is busy or gone: the default records instead, and the status says so.
        fallback = std::string("the chosen input did not open (") + ma_result_description(r) + "); the default records";
        found = false;
        cfg.capture.pDeviceID = nullptr;
        r = ma_device_init(&a->context, &cfg, d);
    }
    if (r != MA_SUCCESS) {
        delete d;
        fallback.clear();
        why = std::string("can't open the audio input: ") + ma_result_description(r);
        return nullptr;
    }
    deviceId = !found ? std::string() : a->context.backend == ma_backend_aaudio ? q.id : deviceIdText(a->context.backend, chosen);
    return d;
}

// Under gDeviceLock: an opened capture device becomes the input. The output starts reading once two capture
// periods and one output callback, plus what the output's FIFO renders ahead, are queued (so neither side's burst
// runs it dry), follows the clocks' drift, and jumps back (crossfaded) only when they come eight periods apart.
// Starved for 250 ms, the input counts as stopped (the status says so; the app tries it again). All in the
// engine's frames: the bridge runs at the engine's rate.
//
// The output callback is the larger of the backend's period and miniaudio's fixed callback size (its intermediary
// buffer, `intermediaryBufferCap`, in the callback's frames: the period asked for, [Fact] miniaudio 0.11.25 source,
// ma_device_init, read 2026-11-13). Where the output takes AAudio's own sizes (takesDeviceSizes) that is the
// stream's whole capacity in one period: more than any callback asks, also after a reroute (the bridge keeps its
// fill), at the cost of a larger input delay, which the latency figures include.
void attachCapture(CawEngine* e, Audio* a, ma_device* d, std::string deviceId) {
    const int rate = static_cast<int>(e->engine->sampleRate());
    const auto& c = d->capture;
    const auto& p = a->device.playback;
    const ma_uint32 channels = std::min<ma_uint32>(c.channels, caw::kMaxInputChannels);
    const int64_t period = std::max<int64_t>(1, toEngineFrames(c.internalPeriodSizeInFrames, c.internalSampleRate, rate));
    const int64_t outPeriod = std::max<int64_t>({1, toEngineFrames(p.internalPeriodSizeInFrames, p.internalSampleRate, rate),
                                                 static_cast<int64_t>(p.intermediaryBufferCap)});
    // The FIFO's frames on top: a callback through it renders (and pulls) up to fifoLatency frames more than it plays.
    a->bridge.open(static_cast<int>(channels), static_cast<int>(2 * period + outPeriod + a->fifoLatency),
                   static_cast<int>(8 * std::max(period, outPeriod)), rate / 4, rate);
    a->capture = d;
    a->input = true;
    a->inputOpenedAt = std::chrono::steady_clock::now();  // the bridge's pushed() counts from its open, above
    a->inputChannels = channels;
    a->duplexBufferFrames = static_cast<ma_uint32>(a->bridge.prime());
    a->inputDeviceId = std::move(deviceId);
    e->engine->liveAudio().setDeviceChannels(static_cast<int>(channels));
    // [Assumption] the round trip is about both sides' buffers and the bridge's fill; a ping measures it. Each
    // side's buffer is in its device's frames, converted; the fill is already the engine's.
    const int64_t in = toEngineFrames(static_cast<int64_t>(c.internalPeriodSizeInFrames) * std::max<ma_uint32>(1, c.internalPeriods),
                                      c.internalSampleRate, rate);
    // The output's queue: AAudio's buffer size where it is known (miniaudio's periods are the whole capacity, at a
    // fixed size too, #241), else miniaudio's periods.
    const int64_t out = toEngineFrames(caw::queuedOutputFrames(a->bufferFrames, p.internalPeriodSizeInFrames, p.internalPeriods),
                                       p.internalSampleRate, rate);
    // The round trip: the input's buffer and the bridge's fill (the FIFO's most included: queued input, a real
    // delay) to the engine, then the FIFO's mean hold and the output's buffer to the speaker.
    e->engine->liveAudio().setDeviceLatency(in + out + a->duplexBufferFrames + a->fifoMeanHold);
}

// Opens and starts the input beside the running output, all under the caller's locks (caw_audio_start's path;
// caw_audio_configure_input opens it outside gDeviceLock). A failure leaves the output as it was and says why.
void openCapture(CawEngine* e, Audio* a) {
    closeCapture(e, a);
    a->inputError.clear();
    std::string id, why, fallback;
    ma_device* d = initCapture(a, captureRequest(e), id, why, fallback);
    a->inputFallbackReason = fallback;
    if (!d) {
        a->inputError = why;
        return;
    }
    attachCapture(e, a, d, std::move(id));
    const ma_result r = ma_device_start(d);
    if (r != MA_SUCCESS) {
        a->inputError = std::string("can't start the audio input: ") + ma_result_description(r);
        closeCapture(e, a);
    }
}

// An AAudio output chosen by its id that runs on another device (Android opened another, or miniaudio reopened the
// default after a disconnect: device_choice.h) is a fallback, which the status says, with why. Under gDeviceLock
// or before the device is shared.
void checkChosenOutput(Audio* a) {
    const int32_t chosen = caw::aaudioDeviceId(a->deviceId);
    if (chosen <= 0 || a->fallback) return;
    const int32_t routed = outputDevice(a);
    if (caw::onChosenDevice(chosen, routed)) return;
    a->fallback = true;
    a->fallbackReason = "the chosen output is not the one playing (it disconnected, or Android routed elsewhere); device " +
                        std::to_string(routed) + " plays";
}

// The output on [a]'s context: the chosen device, else the system default (fallback). MA_SUCCESS or why not; the
// caller owns the context either way.
ma_result openOnContext(CawEngine* e, Audio* a, std::string& why) {
    // A device chosen by id (two identical interfaces share a name), else by name, found in the backend's list;
    // else the default (it was unplugged, say). No list for the default, nor on AAudio, which lists only the
    // default (miniaudio 0.11.25, ma_context_enumerate_devices__aaudio) and where Android routes the output.
    // On AAudio a device is chosen by its Android id ("aaudio:<id>", device_choice.h, #242), which the app reads from
    // AudioManager.
    ma_device_id chosen;
    bool found = false;
    if (a->context.backend == ma_backend_aaudio) {
        if (const int32_t n = caw::aaudioDeviceId(e->deviceId); n > 0) {
            chosen.aaudio = n;
            found = true;
        }
    } else if (!e->deviceId.empty() || !e->deviceName.empty()) {
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
    const ma_uint32 frames = wantedFrames(e);
    const bool exclusive = (e->audioFlags & CAW_AUDIO_EXCLUSIVE) != 0;
    ma_result r = openDevice(a, e, found ? &chosen : nullptr, frames, exclusive, why);
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
        a->deviceId = a->context.backend == ma_backend_aaudio ? e->deviceId : deviceIdText(a->context.backend, chosen);
        checkChosenOutput(a);  // Android may have opened another device
    }
    return r;
}

int32_t startLocked(CawEngine* e, char* error, int32_t error_len) {
    if (e->audio) {
        // Open and playing: nothing to do. Stopped behind our back (miniaudio stops a device whose AAudio stream
        // could not be reopened after a disconnect): closed, so it opens again below.
        if (ma_device_get_state(&static_cast<Audio*>(e->audio)->device) == ma_device_state_started) return 0;
        stopLocked(e);
    }
    if (gActive && gActive != e) stopLocked(gActive);  // an orphaned engine from an earlier copy of the app
    auto* a = new Audio();
    a->owner = e;
    bool overridden = false;
    ma_result r = initContext(&a->context, &overridden);
    if (r != MA_SUCCESS) {
        setError(std::string("can't open the audio system: ") + ma_result_description(r), error, error_len);
        delete a;
        return 1;
    }
    std::string why;
    r = openOnContext(e, a, why);
    if (r != MA_SUCCESS && overridden) {
        // CAW_AUDIO_BACKEND's backend opened but its device did not (#237): the default order instead.
        ma_context_uninit(&a->context);
        r = ma_context_init(nullptr, 0, nullptr, &a->context);
        if (r == MA_SUCCESS) {
            a->fallback = false;
            a->fallbackReason.clear();
            a->deviceId.clear();
            r = openOnContext(e, a, why);
            if (r != MA_SUCCESS) ma_context_uninit(&a->context);
        } else {
            why = std::string("can't open the audio system: ") + ma_result_description(r);
        }
    } else if (r != MA_SUCCESS) {
        ma_context_uninit(&a->context);
    }
    if (r != MA_SUCCESS) {
        setError(why, error, error_len);
        delete a;
        return 1;
    }
    e->audio = a;
    gActive = e;
    if (e->inputEnabled) openCapture(e, a);  // after the output, which plays whether or not this opens
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

// The control thread, at the start of a status, latency or size call: after an AAudio reroute of an output opened
// at a fixed size (Audio::reopen, set on miniaudio's job thread), the device reopens at its settings as a buffer-mode
// change does (reopenLocked: the same Engine, so the transport, project and position carry on; the route change
// was a gap already). Only when no open or reconfigure holds gOpLock (try_lock: a poll never waits for one, and
// that call opens a fresh device anyway); never on the audio thread or miniaudio's job thread.
void reopenAfterReroute(CawEngine* e) {
    std::unique_lock<std::mutex> op(gOpLock, std::try_to_lock);
    if (!op.owns_lock()) return;
    std::lock_guard<std::mutex> lock(gDeviceLock);
    auto* a = static_cast<Audio*>(e->audio);
    if (!a || !a->reopen.load(std::memory_order_acquire)) return;
    reopenLocked(e);
}

// The input's state: "off" (not asked for, or no output running), "open" (delivering), "stalled" (open, but
// nothing has arrived for 250 ms: another app took the microphone, or the stream died quietly), "stopped" (the
// system stopped it: a disconnect miniaudio could not reopen) or "failed" (asked for and did not open; "error").
const char* inputState(const CawEngine* e, const Audio* a) {
    if (!e->inputEnabled || !a) return "off";
    if (!a->input) return "failed";
    if (!a->capture || ma_device_get_state(a->capture) != ma_device_state_started) return "stopped";
    return a->bridge.stalled() ? "stalled" : "open";
}

std::string secondsSince(std::chrono::steady_clock::time_point t) {
    char b[32];
    std::snprintf(b, sizeof b, "%.3f", std::chrono::duration<double>(std::chrono::steady_clock::now() - t).count());
    return b;
}

// #241's diagnostic: the output callback's frames against the time since the device opened (frames / seconds is
// the rate the speaker really takes them at; a shortfall is time the device played without asking), the frames
// the engine rendered for them (more by at most the FIFO's 63), the callbacks' sizes, the ones over their budget,
// the stream's own underruns, and the layers shed for load.
std::string clockStatus(const CawEngine* e, Audio* a) {
    const caw::Engine::SheddingStats sh = e->engine->sheddingStats();
    return std::string("{\"seconds\":") + secondsSince(a->openedAt) +
           ",\"callbacks\":" + std::to_string(a->outCallbacks.load(std::memory_order_relaxed)) +
           ",\"frames\":" + std::to_string(a->outFrames.load(std::memory_order_relaxed)) +
           ",\"rendered_frames\":" + std::to_string(a->outRendered.load(std::memory_order_relaxed)) +
           ",\"min_frames\":" + std::to_string(a->outMin.load(std::memory_order_relaxed)) +
           ",\"max_frames\":" + std::to_string(a->outMax.load(std::memory_order_relaxed)) +
           ",\"late_callbacks\":" + std::to_string(a->outLate.load(std::memory_order_relaxed)) +
           ",\"xruns\":" + std::to_string(outputXRuns(a)) + ",\"shed\":" + std::to_string(sh.shed) +
           ",\"restored\":" + std::to_string(sh.restored) + ",\"muted_now\":" + std::to_string(sh.mutedNow) + "}";
}

std::string inputStatus(const CawEngine* e, const Audio* a) {
    const bool running = a && a->input && a->capture;
    std::string out = std::string("{\"enabled\":") + (e->inputEnabled ? "true" : "false") +
                      ",\"running\":" + (running ? "true" : "false") + ",\"state\":\"" + inputState(e, a) + "\"" +
                      ",\"requested_device\":" + quoted(e->inputName.c_str()) +
                      ",\"requested_device_id\":" + quoted(e->inputId.c_str()) +
                      ",\"requested_channels\":" + std::to_string(e->inputChannels);
    if (running) {
        const auto& c = a->capture->capture;
        // #242: the device the stream runs on (AAudio; 0 elsewhere), and whether the chosen one is not it: it did
        // not open, or it went away and miniaudio reopened the default.
        const int32_t routed = inputDevice(a);
        const bool moved = !caw::onChosenDevice(caw::aaudioDeviceId(a->inputDeviceId), routed);
        const std::string reason = !a->inputFallbackReason.empty() ? a->inputFallbackReason
                                   : moved ? "the chosen input is not the one recording (it disconnected); device " + std::to_string(routed) + " records"
                                           : std::string();
        out += ",\"device\":" + quoted(c.name) + ",\"device_id\":" + quoted(a->inputDeviceId.c_str()) +
               ",\"routed_device_id\":" + std::to_string(routed) + ",\"fallback\":" + (reason.empty() ? "false" : "true") +
               ",\"fallback_reason\":" + quoted(reason.c_str()) +
               ",\"channels\":" + std::to_string(a->inputChannels) + ",\"sample_rate\":" + std::to_string(c.internalSampleRate) +
               ",\"period_frames\":" + std::to_string(c.internalPeriodSizeInFrames) +
               ",\"duplex_buffer_frames\":" + std::to_string(a->duplexBufferFrames) +
               ",\"latency_frames\":" + std::to_string(e->engine->liveAudio().latency()) +
               ",\"underruns\":" + std::to_string(a->bridge.underruns()) +
               ",\"dropped_frames\":" + std::to_string(a->bridge.dropped()) +
               ",\"missing_frames\":" + std::to_string(a->bridge.missing()) +
               ",\"drift_ppm\":" + std::to_string(static_cast<int64_t>((a->bridge.ratio() - 1.0) * 1e6)) +
               // #241: the capture's frames against the time since it opened (its real rate), the bridge's fill
               // now (the input's delay, held near duplex_buffer_frames) and the stream's own overruns.
               ",\"pushed_frames\":" + std::to_string(a->bridge.pushed()) +
               ",\"seconds\":" + secondsSince(a->inputOpenedAt) +
               ",\"fill_frames\":" + std::to_string(static_cast<int64_t>(a->bridge.delay())) +
               ",\"skipped_frames\":" + std::to_string(a->bridge.skipped()) +
               ",\"xruns\":" + std::to_string(inputXRuns(a));
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
    const bool input = a->input && a->capture;
    refreshAfterReroute(a);
    // Without a timestamp: what AAudio queues (its buffer size, not miniaudio's periods, which are the stream's
    // whole capacity, #241), else the backend's periods.
    SideLatency out;
    out.frames = toEngineFrames(caw::queuedOutputFrames(a->bufferFrames, p.internalPeriodSizeInFrames, p.internalPeriods),
                                p.internalSampleRate, rate);
    out.source = out.frames > 0 ? "buffers" : "none";
    SideLatency in;
    if (input) {
        const auto& c = a->capture->capture;
        in = bufferLatency(c.internalPeriodSizeInFrames, c.internalPeriods, c.internalSampleRate, rate);
    }
#if defined(__ANDROID__)
    if (a->context.backend == ma_backend_aaudio) {
        ma_mutex_lock(&a->device.aaudio.rerouteLock);
        SideLatency t;
        if (aaudioLatency(a, a->device.aaudio.pStreamPlayback, true, rate, t)) out = t;
        else out.deviceId = t.deviceId;
        ma_mutex_unlock(&a->device.aaudio.rerouteLock);
        if (input) {  // the input's own device, under its own reroute lock
            ma_mutex_lock(&a->capture->aaudio.rerouteLock);
            SideLatency ti;
            if (aaudioLatency(a, a->capture->aaudio.pStreamCapture, false, rate, ti)) in = ti;
            else in.deviceId = ti.deviceId;
            ma_mutex_unlock(&a->capture->aaudio.rerouteLock);
        }
    }
#endif
#if defined(_WIN32)
    if (a->context.backend == ma_backend_wasapi) {
        auto cached = [](const wchar_t* id, std::wstring& lastId, const char*& kind) {
            if (lastId != id) { lastId = id; kind = wasapiKind(id); }
            return kind;
        };
        out.kind = cached(a->device.playback.id.wasapi, a->kindOutId, a->kindOut);
        if (input) in.kind = cached(a->capture->capture.id.wasapi, a->kindInId, a->kindIn);
    }
#endif
    // Two different delays, each on its own side (the app adds the sides for recording): the input waits in the
    // bridge for its fill, which includes the FIFO's most frames as headroom (queued input the drift loop holds
    // there, so a real delay), and the engine's output waits in the FIFO for its mean hold before it plays. Both
    // at the engine's rate already (callback frames are).
    if (input) in.frames += a->duplexBufferFrames;
    out.frames += a->fifoMeanHold;
    return "{\"running\":true,\"sample_rate\":" + std::to_string(rate) + ",\"output\":" + sideJson(out, rate, true) +
           ",\"input\":" + sideJson(in, rate, input) + "}";
}

// Behind the app (and not monitoring), a larger output buffer rides out the scheduling gaps Android gives a
// background app; in front it goes back to the size it had. AAudio only: AAudioStream_setBufferSizeInFrames
// changes how many frames are queued (the latency) up to the stream's capacity, without reopening it
// ([Fact] developer.android.com NDK AAudio reference, read 2026-11-12: "adjust the latency of the buffer by
// changing the threshold where blocking will occur", "cannot be set higher than getBufferCapacityInFrames",
// API 26; miniaudio 0.11.25 loads getBufferCapacityInFrames but not the setter, so it is looked up in the
// libaaudio.so it opened). Under the reroute lock, so the stream is the one miniaudio has; a reroute meanwhile
// opens a new stream at its own default. Returns the output's buffer size now, in frames (0: not AAudio).
int32_t setBackground(Audio* a, bool on) {
#if defined(__ANDROID__)
    if (a->context.backend != ma_backend_aaudio || !a->context.aaudio.hAAudio) return 0;
    using SetSize = int32_t (*)(void*, int32_t);
    using Int = int32_t (*)(void*);
    auto setSize = reinterpret_cast<SetSize>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_setBufferSizeInFrames"));
    auto getSize = reinterpret_cast<Int>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getBufferSizeInFrames"));
    auto capacity = reinterpret_cast<Int>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getBufferCapacityInFrames"));
    if (!setSize || !getSize || !capacity) return 0;
    int32_t now = 0;
    ma_mutex_lock(&a->device.aaudio.rerouteLock);
    void* stream = a->device.aaudio.pStreamPlayback;
    if (stream) {
        if (on && !a->background) {
            a->savedBufferFrames = getSize(stream);
            const int32_t cap = capacity(stream);
            if (cap > 0) setSize(stream, cap);
            a->background = true;
        } else if (!on && a->background) {
            if (a->savedBufferFrames > 0) setSize(stream, a->savedBufferFrames);
            a->background = false;
        }
        now = getSize(stream);
        if (now > 0) a->bufferFrames = now;
    }
    ma_mutex_unlock(&a->device.aaudio.rerouteLock);
    return now > 0 ? now : 0;
#else
    (void)a;
    (void)on;
    return 0;
#endif
}

}  // namespace

int32_t cawAudioXruns(CawEngine* e) {
#if defined(__ANDROID__)
    std::lock_guard<std::mutex> op(gOpLock);  // the context lives while it is held
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
    std::lock_guard<std::mutex> op(gOpLock);
    std::lock_guard<std::mutex> lock(gDeviceLock);
    // A Benchmark live run has the device: another engine may not take it over (that would end the run).
    if (gActive && gActive != e && gActive->stress.load(std::memory_order_acquire)) {
        setError("the Benchmark is using the audio device", error, error_len);
        return 1;
    }
    return startLocked(e, error, error_len);
}

void caw_audio_stop(CawEngine* e) {
    if (!e) return;
    std::lock_guard<std::mutex> op(gOpLock);
    std::lock_guard<std::mutex> lock(gDeviceLock);
    stopLocked(e);
}

void caw_audio_set_buffer_mode(CawEngine* e, int32_t mode, int32_t recording) {
    if (!e) return;  // a reopen that fails leaves the device closed: caw_audio_status says so
    std::lock_guard<std::mutex> op(gOpLock);
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
    reopenAfterReroute(e);
    std::lock_guard<std::mutex> lock(gDeviceLock);
    auto* a = static_cast<Audio*>(e->audio);
    if (a) refreshAfterReroute(a);
    return a ? reportedPeriod(a) : 0;
}

char* caw_audio_devices(void) {
    ma_context context;
    if (initContext(&context) != MA_SUCCESS) {
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
    std::lock_guard<std::mutex> op(gOpLock);
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
    if (initContext(&context) != MA_SUCCESS)
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
    std::lock_guard<std::mutex> op(gOpLock);  // held throughout: the context outlives the open below
    const bool on = enabled != 0;
    std::string id = device_id ? std::string(device_id).substr(0, 511) : std::string();
    std::string name = device_name ? std::string(device_name).substr(0, MA_MAX_DEVICE_NAME_LENGTH) : std::string();
    const int ch = channels <= 0 ? 2 : (channels > 32 ? 32 : channels);
    Audio* running = nullptr;
    ma_device* old = nullptr;
    CaptureRequest q;
    {
        std::lock_guard<std::mutex> lock(gDeviceLock);
        running = static_cast<Audio*>(e->audio);
        // Unchanged, and either off or open and delivering: nothing to do. Asked again with input on while it is
        // not (it failed to open because RECORD_AUDIO was not granted yet or another app held the microphone, or it
        // stopped or starved since), it is tried again. Only the input opens or closes: the output plays on.
        if (on == e->inputEnabled && id == e->inputId && name == e->inputName && ch == e->inputChannels &&
            (!on || !running || captureHealthy(running)))
            return running && running->fallback ? 2 : 0;
        e->inputEnabled = on;
        e->inputId = std::move(id);
        e->inputName = std::move(name);
        e->inputChannels = ch;
        if (!running) return 0;
        old = detachCapture(e, running);
        running->inputError.clear();
        q = captureRequest(e);
    }
    // The slow part outside gDeviceLock, so the status and latency polls never wait for it: close the old input,
    // open the new one (gOpLock keeps the context and the output as they are meanwhile).
    destroyCapture(running, old);
    if (!on) return running->fallback ? 2 : 0;
    std::string deviceId, why, fallback;
    ma_device* d = initCapture(running, q, deviceId, why, fallback);
    {
        std::lock_guard<std::mutex> lock(gDeviceLock);
        running->inputFallbackReason = fallback;
        if (!d) {
            running->inputError = why;
            return running->fallback ? 2 : 0;
        }
        attachCapture(e, running, d, std::move(deviceId));
    }
    const ma_result r = ma_device_start(d);
    if (r != MA_SUCCESS) {
        ma_device* failed = nullptr;
        {
            std::lock_guard<std::mutex> lock(gDeviceLock);
            running->inputError = std::string("can't start the audio input: ") + ma_result_description(r);
            failed = detachCapture(e, running);
        }
        destroyCapture(running, failed);
    }
    return running->fallback ? 2 : 0;
}

int32_t caw_audio_tune_buffer(CawEngine* e, int32_t start_frames) {
#if defined(__ANDROID__)
    if (!e) return 0;
    reopenAfterReroute(e);
    std::lock_guard<std::mutex> op(gOpLock);  // the context lives while it is held
    std::lock_guard<std::mutex> lock(gDeviceLock);
    auto* a = static_cast<Audio*>(e->audio);
    if (!a || a->context.backend != ma_backend_aaudio || !a->context.aaudio.hAAudio) return 0;
    if (a->background) return a->bufferFrames;  // behind the app the buffer is at its capacity (setBackground)
    // Only where the output has no size of its own (Low latency, or Auto while recording): a fixed 1024-frame
    // buffer is left as it is, and 0 says nothing was tuned, so the app keeps no size for the output.
    if (!caw::tunesBuffer(e->bufferMode == CAW_BUFFER_LOW_LATENCY, e->bufferMode == CAW_BUFFER_AUTO, e->recording)) return 0;
    using SetSize = int32_t (*)(void*, int32_t);
    using Int = int32_t (*)(void*);
    auto setSize = reinterpret_cast<SetSize>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_setBufferSizeInFrames"));
    auto getSize = reinterpret_cast<Int>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getBufferSizeInFrames"));
    auto capacity = reinterpret_cast<Int>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getBufferCapacityInFrames"));
    auto xruns = reinterpret_cast<Int>(dlsym(a->context.aaudio.hAAudio, "AAudioStream_getXRunCount"));
    auto burst = reinterpret_cast<Int>(a->context.aaudio.AAudioStream_getFramesPerBurst);
    if (!setSize || !getSize || !capacity || !xruns || !burst) return 0;
    int32_t now = 0;
    ma_mutex_lock(&a->device.aaudio.rerouteLock);
    if (void* stream = a->device.aaudio.pStreamPlayback) {
        const auto t = std::chrono::steady_clock::now();
        const int32_t x = xruns(stream);
        int32_t want = 0;
        const uint32_t streams = a->streams.load(std::memory_order_acquire);
        const uint64_t plays = e->engine->playsSent();
        if (streams != a->tunedStreams || !a->tuner.started()) {  // a new stream (an open or a reroute): start again
            const int32_t b = burst(stream);
            if (b > 0) want = a->tuner.start(b, caw::BufferTuner::kFloorBursts * b, capacity(stream), start_frames, x);
            a->tunedStreams = streams;
        } else {
            // A new playback starts the quiet time again from now: a pause is not time without underruns.
            const double quiet = plays != a->tunedPlays ? 0.0 : std::chrono::duration<double>(t - a->tunedAt).count();
            want = a->tuner.update(x, quiet);
        }
        a->tunedPlays = plays;
        a->tunedAt = t;
        if (want > 0) setSize(stream, want);
        now = getSize(stream);
        if (now > 0) a->bufferFrames = now;
    }
    ma_mutex_unlock(&a->device.aaudio.rerouteLock);
    return now > 0 ? now : 0;
#else
    (void)e;
    (void)start_frames;
    return 0;
#endif
}

int32_t caw_audio_set_background(CawEngine* e, int32_t background) {
    if (!e) return 0;
    std::lock_guard<std::mutex> op(gOpLock);
    std::lock_guard<std::mutex> lock(gDeviceLock);
    auto* a = static_cast<Audio*>(e->audio);
    if (!a) return 0;
    return setBackground(a, background != 0);
}

char* caw_audio_status(CawEngine* e) {
    if (!e) return dup("{\"running\":false}");
    reopenAfterReroute(e);
    std::lock_guard<std::mutex> lock(gDeviceLock);
    const std::string request = ",\"requested_device\":" + quoted(e->deviceName.c_str()) +
                                ",\"requested_device_id\":" + quoted(e->deviceId.c_str()) +
                                ",\"requested_frames\":" + std::to_string(e->periodFrames) +
                                ",\"exclusive_requested\":" + ((e->audioFlags & CAW_AUDIO_EXCLUSIVE) ? "true" : "false");
    auto* a = static_cast<Audio*>(e->audio);
    if (!a) return dup("{\"running\":false" + request + ",\"input\":" + inputStatus(e, nullptr) + "}");
    refreshAfterReroute(a);
    checkChosenOutput(a);  // a chosen AAudio device that went away (#242)
    const auto& p = a->device.playback;
    // Not started: the system stopped it (a disconnect miniaudio could not reopen); caw_audio_start opens it again.
    const bool started = ma_device_get_state(&a->device) == ma_device_state_started;
    return dup(std::string("{\"running\":") + (started ? "true" : "false") + ",\"stopped_by_system\":" +
               (started ? "false" : "true") + ",\"backend\":" + quoted(ma_get_backend_name(a->context.backend)) +
               ",\"device\":" + quoted(p.name) + ",\"device_id\":" + quoted(a->deviceId.c_str()) +
               // AAudio: the device the stream runs on (AudioDeviceInfo.getId(); 0 elsewhere or unknown), #242.
               ",\"routed_device_id\":" + std::to_string(outputDevice(a)) +
               ",\"sample_rate\":" + std::to_string(p.internalSampleRate) +
               // #241: the rate the engine renders, counts its song clock and asks every stream for (the one source
               // of truth); the stream's own rate above differs only where miniaudio resamples between them.
               ",\"engine_sample_rate\":" + std::to_string(static_cast<int64_t>(e->engine->sampleRate())) +
               ",\"period_frames\":" + std::to_string(reportedPeriod(a)) +
               ",\"periods\":" + std::to_string(reportedPeriods(a)) +
               ",\"device_sizes\":" + (a->deviceSizes ? "true" : "false") +
               ",\"exclusive\":" + (a->exclusive ? "true" : "false") +
               ",\"low_latency\":" + (a->lowLatency ? "true" : "false") +
               ",\"modes_read_back\":" + (a->modesReadBack ? "true" : "false") +
               ",\"smallest_period\":{\"frames\":" + std::to_string(a->smallestFrames) +
               ",\"source\":" + quoted(a->periodSource) + ",\"engine_default\":" + std::to_string(a->enginePeriods[0]) +
               ",\"engine_fundamental\":" + std::to_string(a->enginePeriods[1]) +
               ",\"engine_min\":" + std::to_string(a->enginePeriods[2]) +
               ",\"engine_max\":" + std::to_string(a->enginePeriods[3]) + ",\"mix_rate\":" + std::to_string(a->mixRate) +
               ",\"device_period_hns\":" + std::to_string(a->devicePeriodHns) + "}" +
               ",\"fallback\":" + (a->fallback ? "true" : "false") +
               ",\"fallback_reason\":" + quoted(a->fallbackReason.c_str()) + request + ",\"clock\":" + clockStatus(e, a) +
               ",\"input\":" + inputStatus(e, a) + "}");
}

char* caw_audio_latency(CawEngine* e) {
    if (!e) return dup("{\"running\":false}");
    reopenAfterReroute(e);
    std::lock_guard<std::mutex> lock(gDeviceLock);
    return dup(latencyJson(e, static_cast<Audio*>(e->audio)));
}

}  // extern "C"
