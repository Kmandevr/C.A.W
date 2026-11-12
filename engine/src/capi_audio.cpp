// The C API for audio assets, SFZ, input meters, recording, input latency (API 18, WP-J) and audio threads (API 24).
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <string>

#include "asset_store.h"
#include "audio_input.h"
#include "builtin_sampler.h"
#include "caw.h"
#include "capi_internal.h"
#include "json.h"

namespace {
char* dup(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}
std::string fail(const std::string& e) { return "{\"ok\":false,\"error\":\"" + caw::jsonEscape(e) + "\"}"; }
std::string num(double v) {
    char b[40];
    std::snprintf(b, sizeof b, "%.10g", v);
    return b;
}
}  // namespace

extern "C" {

char* caw_asset_load(CawEngine* e, const char* path) try {
    if (!e || !path) return dup(fail("no engine or path"));
    std::string error;
    auto a = caw::AssetStore::global().load(path, e->engine->sampleRate(), error);
    if (!a) return dup(fail(error));
    return dup("{\"ok\":true,\"error\":\"\",\"path\":\"" + caw::jsonEscape(a->path) + "\",\"frames\":" +
               std::to_string(a->frames) + ",\"channels\":" + std::to_string(a->channels) + ",\"sample_rate\":" +
               num(a->rate) + ",\"source_rate\":" + num(a->sourceRate) + ",\"source_channels\":" +
               std::to_string(a->sourceChannels) + ",\"source_frames\":" + std::to_string(a->sourceFrames) +
               ",\"seconds\":" + num(a->seconds()) + ",\"bytes\":" + std::to_string(a->bytes()) + "}");
} catch (...) {
    return dup(fail("out of memory"));
}

int32_t caw_asset_peaks(CawEngine* e, const char* path, double start_seconds, double end_seconds, int32_t buckets,
                        int32_t channel, float* out) try {
    if (!e || !path || !out || buckets <= 0 || buckets > 65536 || !std::isfinite(start_seconds) ||
        !std::isfinite(end_seconds))
        return -1;
    std::string error;
    auto a = caw::AssetStore::global().load(path, e->engine->sampleRate(), error);
    if (!a) return -1;
    const double rate = a->rate;
    // Clamped before the cast (a huge time would not fit int64_t); readPeaks clamps to the asset.
    const int64_t s = static_cast<int64_t>(std::floor(std::clamp(start_seconds * rate, 0.0, 9e15)));
    const int64_t z = static_cast<int64_t>(std::floor(std::clamp(end_seconds * rate, 0.0, 9e15)));
    if (z <= s) return 0;
    return caw::readPeaks(*a, s, z, buckets, channel < 0 ? 0u : static_cast<uint32_t>(channel), out);
} catch (...) {
    return -1;
}

char* caw_asset_store_status(void) try { return dup(caw::AssetStore::global().statusJson()); } catch (...) {
    return nullptr;
}
void caw_asset_store_set_budget(int64_t bytes) {
    if (bytes > 0) caw::AssetStore::global().setBudget(static_cast<uint64_t>(bytes));
}
void caw_asset_store_purge(void) { caw::AssetStore::global().purge(); }

char* caw_sfz_import(const char* sfz_path) try {
    if (!sfz_path) return dup(fail("no path"));
    return dup(caw::sfzImportJson(sfz_path));
} catch (...) {
    return dup(fail("out of memory"));
}

char* caw_sfz_export(const char* state_json, const char* sfz_path, int32_t copy_samples) try {
    if (!state_json || !sfz_path) return dup(fail("no state or path"));
    return dup(caw::sfzExportJson(state_json, sfz_path, copy_samples != 0));
} catch (...) {
    return dup(fail("out of memory"));
}

int32_t caw_engine_input_peaks(CawEngine* e, float* out, int32_t max) {
    if (!e || !out || max <= 0) return 0;
    return e->engine->liveAudio().peaks(out, max);
}

char* caw_record_start(CawEngine* e, const char* request_json) try {
    if (!e || !request_json) return dup(fail("no engine or request"));
    return dup(e->engine->liveAudio().startRecording(request_json));
} catch (...) {
    return dup(fail("out of memory"));
}

char* caw_record_stop(CawEngine* e) try {
    if (!e) return dup(fail("no engine"));
    return dup(e->engine->liveAudio().stopRecording());
} catch (...) {
    return dup(fail("out of memory"));
}

char* caw_record_status(CawEngine* e) try {
    if (!e) return dup("{\"recording\":false}");
    return dup(e->engine->liveAudio().recordingStatus());
} catch (...) {
    return nullptr;
}

char* caw_record_recover(const char* dir) try {
    if (!dir) return dup(fail("no folder"));
    return dup(caw::LiveAudio::recover(dir));
} catch (...) {
    return dup(fail("recovery failed"));
}

void caw_engine_set_input_latency(CawEngine* e, int64_t frames) {
    if (e) e->engine->liveAudio().setLatencyOverride(frames < 0 ? -1 : frames);
}

char* caw_engine_input_latency(CawEngine* e) try {
    if (!e) return dup("{\"frames\":0}");
    return dup(e->engine->liveAudio().latencyJson());
} catch (...) {
    return nullptr;
}

int32_t caw_latency_ping_start(CawEngine* e) try { return e && e->engine->liveAudio().startPing() ? 1 : 0; } catch (...) {
    return 0;
}

char* caw_latency_ping_result(CawEngine* e) try {
    if (!e) return dup("{\"state\":\"idle\"}");
    return dup(e->engine->liveAudio().pingResult());
} catch (...) {
    return nullptr;
}

// API 24 (speed phase 5d): the audio thread's core, its clock and kind, the scheduling the platform gave, the pool.
char* caw_audio_threads(CawEngine* e) try {
    if (!e) return nullptr;
    return dup(e->engine->audioThreadsJson());
} catch (...) {
    return nullptr;
}

}  // extern "C"
