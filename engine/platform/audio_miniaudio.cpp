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
#if defined(_WIN32)
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <mmdeviceapi.h>
#endif

#include "caw.h"
#include "capi_internal.h"
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
    caw::InputBridge bridge;
    // Behind the app (caw_audio_set_background): the output's AAudio buffer raised toward its capacity, and the
    // size to restore on return.
    bool background = false;
    int32_t savedBufferFrames = 0;
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
    int fifoLatency = 0;  // frames it can hold back (0 when the period is whole blocks), in the output latency
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

void callback(ma_device* dev, void* output, const void* input, ma_uint32 frames) {
    auto* a = static_cast<Audio*>(dev->pUserData);
    const auto start = std::chrono::steady_clock::now();
    auto* out = static_cast<float*>(output);
    (void)input;  // a playback device: the input comes through the bridge
    // Fixed blocks through the FIFO (device_render.h), or straight for a small odd period. The bridge's input is
    // pulled for each block the engine renders, so it follows the frames rendered, not the frames played (they
    // differ by what the FIFO holds); silence where the input is missing, none while it is closed.
    const int rendered = a->render.render(*a->owner->engine, out, static_cast<int>(frames),
                                          [a](int m, int& ch) { return a->bridge.pull(m, ch); });
    const double used = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    const double budget = static_cast<double>(frames) / static_cast<double>(dev->sampleRate);
    // The load per frame rendered: through the FIFO a callback renders more or fewer frames than it plays.
    a->owner->engine->reportLoad(budget > 0 ? used / budget : 0.0, static_cast<int>(frames), rendered);
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
    cfg.performanceProfile = a->lowLatency ? ma_performance_profile_low_latency : ma_performance_profile_conservative;
    a->frames = frames;
    if (frames > 0) {
        cfg.periodSizeInFrames = frames;
        cfg.aaudio.allowSetBufferCapacity = MA_TRUE;
    }
    cfg.dataCallback = callback;
    cfg.pUserData = a;
    // WASAPI: miniaudio's audio thread joins MMCSS "Pro Audio" (AvSetMmThreadCharacteristicsA in
    // ma_device_start__wasapi_nolock, on that thread, miniaudio 0.11.25); the default usage joins no MMCSS task.
    // The mix pool's workers then join the same task (thread_tuning_win.cpp), never above the callback.
    cfg.wasapi.usage = ma_wasapi_usage_pro_audio;
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
    // miniaudio calls back with a fixed size (its intermediary buffer, noFixedSizedCallback off): what it holds
    // back on top is at most a block short of one, unless that size is whole blocks.
    a->render.open(static_cast<int>(a->device.playback.intermediaryBufferCap));
    e->engine->requestSheddingReset();  // a fresh device: its first callbacks' stalls and a throttled stretch before don't count
    a->fifoLatency = a->render.latency();
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
ma_device* initCapture(Audio* a, const CaptureRequest& q, std::string& deviceId, std::string& why) {
    ma_device_id chosen;
    bool found = false;
    if ((!q.id.empty() || !q.name.empty()) && a->context.backend != ma_backend_aaudio) {
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
    const ma_result r = ma_device_init(&a->context, &cfg, d);
    if (r != MA_SUCCESS) {
        delete d;
        why = std::string("can't open the audio input: ") + ma_result_description(r);
        return nullptr;
    }
    deviceId = found ? deviceIdText(a->context.backend, chosen) : std::string();
    return d;
}

// Under gDeviceLock: an opened capture device becomes the input. The output starts reading once two capture
// periods and one output callback, plus what the output's FIFO renders ahead, are queued (so neither side's burst
// runs it dry), follows the clocks' drift, and jumps back (crossfaded) only when they come eight periods apart. Starved for 250 ms, the input counts as stopped
// (the status says so; the app tries it again). All in the engine's frames: the bridge runs at the engine's rate.
void attachCapture(CawEngine* e, Audio* a, ma_device* d, std::string deviceId) {
    const int rate = static_cast<int>(e->engine->sampleRate());
    const auto& c = d->capture;
    const auto& p = a->device.playback;
    const ma_uint32 channels = std::min<ma_uint32>(c.channels, caw::kMaxInputChannels);
    const int64_t period = std::max<int64_t>(1, toEngineFrames(c.internalPeriodSizeInFrames, c.internalSampleRate, rate));
    const int64_t outPeriod = std::max<int64_t>(1, toEngineFrames(p.internalPeriodSizeInFrames, p.internalSampleRate, rate));
    // The FIFO's frames on top: a callback through it renders (and pulls) up to fifoLatency frames more than it plays.
    a->bridge.open(static_cast<int>(channels), static_cast<int>(2 * period + outPeriod + a->fifoLatency),
                   static_cast<int>(8 * std::max(period, outPeriod)), rate / 4, rate);
    a->capture = d;
    a->input = true;
    a->inputChannels = channels;
    a->duplexBufferFrames = static_cast<ma_uint32>(a->bridge.prime());
    a->inputDeviceId = std::move(deviceId);
    e->engine->liveAudio().setDeviceChannels(static_cast<int>(channels));
    // [Assumption] the round trip is about both sides' buffers and the bridge's fill; a ping measures it. Each
    // side's buffer is in its device's frames, converted; the fill is already the engine's.
    const int64_t in = toEngineFrames(static_cast<int64_t>(c.internalPeriodSizeInFrames) * std::max<ma_uint32>(1, c.internalPeriods),
                                      c.internalSampleRate, rate);
    const int64_t out = toEngineFrames(static_cast<int64_t>(p.internalPeriodSizeInFrames) * std::max<ma_uint32>(1, p.internalPeriods),
                                       p.internalSampleRate, rate);
    // The FIFO (fifoLatency) renders up to that many frames ahead of what plays, the bridge read with them.
    e->engine->liveAudio().setDeviceLatency(in + out + a->duplexBufferFrames + a->fifoLatency);
}

// Opens and starts the input beside the running output, all under the caller's locks (caw_audio_start's path;
// caw_audio_configure_input opens it outside gDeviceLock). A failure leaves the output as it was and says why.
void openCapture(CawEngine* e, Audio* a) {
    closeCapture(e, a);
    a->inputError.clear();
    std::string id, why;
    ma_device* d = initCapture(a, captureRequest(e), id, why);
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
    const ma_uint32 frames = wantedFrames(e);
    const bool exclusive = (e->audioFlags & CAW_AUDIO_EXCLUSIVE) != 0;
    std::string why;
    r = openDevice(a, e, found ? &chosen : nullptr, frames, exclusive, why);
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

// The input's state: "off" (not asked for, or no output running), "open" (delivering), "stalled" (open, but
// nothing has arrived for 250 ms: another app took the microphone, or the stream died quietly), "stopped" (the
// system stopped it: a disconnect miniaudio could not reopen) or "failed" (asked for and did not open; "error").
const char* inputState(const CawEngine* e, const Audio* a) {
    if (!e->inputEnabled || !a) return "off";
    if (!a->input) return "failed";
    if (!a->capture || ma_device_get_state(a->capture) != ma_device_state_started) return "stopped";
    return a->bridge.stalled() ? "stalled" : "open";
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
        out += ",\"device\":" + quoted(c.name) + ",\"device_id\":" + quoted(a->inputDeviceId.c_str()) +
               ",\"channels\":" + std::to_string(a->inputChannels) + ",\"sample_rate\":" + std::to_string(c.internalSampleRate) +
               ",\"period_frames\":" + std::to_string(c.internalPeriodSizeInFrames) +
               ",\"duplex_buffer_frames\":" + std::to_string(a->duplexBufferFrames) +
               ",\"latency_frames\":" + std::to_string(e->engine->liveAudio().latency()) +
               ",\"underruns\":" + std::to_string(a->bridge.underruns()) +
               ",\"dropped_frames\":" + std::to_string(a->bridge.dropped()) +
               ",\"missing_frames\":" + std::to_string(a->bridge.missing()) +
               ",\"drift_ppm\":" + std::to_string(static_cast<int64_t>((a->bridge.ratio() - 1.0) * 1e6));
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
    SideLatency out = bufferLatency(p.internalPeriodSizeInFrames, p.internalPeriods, p.internalSampleRate, rate);
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
    // The bridge's fill (see attachCapture) holds the input back before the engine reads it. The fixed-block FIFO
    // holds rendered frames back before they play: it is on the output side only, since the bridge is read per
    // block rendered (the app adds the two sides for recording, so counting it on both would count it twice).
    // Both at the engine's rate already (callback frames are).
    if (input) in.frames += a->duplexBufferFrames;
    out.frames += a->fifoLatency;
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

extern "C" {

int32_t caw_audio_start(CawEngine* e, char* error, int32_t error_len) {
    if (!e) return 1;
    std::lock_guard<std::mutex> op(gOpLock);
    std::lock_guard<std::mutex> lock(gDeviceLock);
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
    std::string deviceId, why;
    ma_device* d = initCapture(running, q, deviceId, why);
    {
        std::lock_guard<std::mutex> lock(gDeviceLock);
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
    std::lock_guard<std::mutex> lock(gDeviceLock);
    const std::string request = ",\"requested_device\":" + quoted(e->deviceName.c_str()) +
                                ",\"requested_device_id\":" + quoted(e->deviceId.c_str()) +
                                ",\"requested_frames\":" + std::to_string(e->periodFrames) +
                                ",\"exclusive_requested\":" + ((e->audioFlags & CAW_AUDIO_EXCLUSIVE) ? "true" : "false");
    const auto* a = static_cast<const Audio*>(e->audio);
    if (!a) return dup("{\"running\":false" + request + ",\"input\":" + inputStatus(e, nullptr) + "}");
    const auto& p = a->device.playback;
    // Not started: the system stopped it (a disconnect miniaudio could not reopen); caw_audio_start opens it again.
    const bool started = ma_device_get_state(&a->device) == ma_device_state_started;
    return dup(std::string("{\"running\":") + (started ? "true" : "false") + ",\"stopped_by_system\":" +
               (started ? "false" : "true") + ",\"backend\":" + quoted(ma_get_backend_name(a->context.backend)) +
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
