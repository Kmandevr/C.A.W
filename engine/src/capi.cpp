// C API implementation (everything except the audio device, which lives in engine/platform).
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>

#include "caw.h"
#include "capi_internal.h"
#include "compile.h"
#include "docs.h"
#include "json.h"
#include "render.h"
#include "wav.h"

namespace {

char* dup(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}

void copyError(const std::string& msg, char* out, int32_t len) {
    if (!out || len <= 0) return;
    const size_t n = std::min(msg.size(), static_cast<size_t>(len - 1));
    std::memcpy(out, msg.data(), n);
    out[n] = '\0';
}

}  // namespace

extern "C" {

int32_t caw_api_version(void) { return CAW_API_VERSION; }

void caw_free(char* s) { std::free(s); }

char* caw_check(const char* source) {
    using namespace caw;
    CompileResult r = compileModule(source ? source : "");
    if (!r.program)
        return dup("{\"ok\":false,\"error\":\"" + jsonEscape(r.error) + "\",\"line\":" + std::to_string(r.line) +
                   ",\"col\":" + std::to_string(r.col) + "}");
    return dup("{\"ok\":true," + describeProgram(*r.program) + "}");
}

CawEngine* caw_engine_create(int32_t sample_rate) {
    if (sample_rate < 8000 || sample_rate > 192000) return nullptr;
    auto* e = new CawEngine();
    e->engine = std::make_unique<caw::Engine>(sample_rate);
    return e;
}

void caw_engine_destroy(CawEngine* e) {
    if (!e) return;
    caw_audio_stop(e);
    delete e;
}

char* caw_engine_set_project(CawEngine* e, const char* json) {
    if (!e || !json) return dup("{\"ok\":false,\"error\":\"no engine\",\"modules\":{}}");
    return dup(e->engine->setProjectJson(json));
}

void caw_engine_set_param(CawEngine* e, const char* module_id, const char* name, double value) {
    if (e && module_id && name) e->engine->setParam(module_id, name, value);
}

void caw_engine_set_global(CawEngine* e, const char* name, double value) {
    if (e && name) e->engine->setGlobal(name, value);
}

void caw_engine_set_layer_mix(CawEngine* e, const char* layer_id, double volume, double pan, int32_t mute,
                              int32_t solo) {
    if (e && layer_id) e->engine->setLayerMix(layer_id, volume, pan, mute != 0, solo != 0);
}

void caw_engine_play(CawEngine* e) {
    if (e) e->engine->play();
}

void caw_engine_stop(CawEngine* e) {
    if (e) e->engine->stop();
}

void caw_engine_clear_overload(CawEngine* e) {
    if (e) e->engine->clearOverload();
}

void caw_engine_meters(CawEngine* e, CawMeters* out) {
    if (!e || !out) return;
    const caw::Meters m = e->engine->meters();
    out->cpu = m.cpu;
    out->peak_l = m.peakL;
    out->peak_r = m.peakR;
    out->playing = m.playing ? 1 : 0;
    out->overloaded = m.overloaded;
    out->position = m.position;
    out->loop_length = m.loopLength;
}

int32_t caw_engine_layer_meter(CawEngine* e, int32_t index, CawLayerMeter* out) {
    if (!e || !out) return 0;
    caw::LayerMeter m;
    const bool ok = e->engine->layerMeter(index, m);
    out->peak = m.peak;
    out->progress = m.progress;
    out->active = m.active ? 1 : 0;
    out->overloaded = m.overloaded ? 1 : 0;
    return ok ? 1 : 0;
}

int32_t caw_engine_scope(CawEngine* e, int32_t index, float* out, int32_t n) {
    if (!e || !out || n <= 0) return 0;
    return e->engine->scope(index, out, n);
}

void caw_engine_process(CawEngine* e, float* left, float* right, int32_t frames) {
    if (e && left && right && frames > 0) e->engine->process(left, right, frames);
}

int32_t caw_render(const char* project_json, const CawRenderOptions* o, const char* out_path, int32_t* progress,
                   int32_t* cancel, char* error, int32_t error_len) {
    using namespace caw;
    if (!project_json || !o || !out_path) {
        copyError("missing argument", error, error_len);
        return 1;
    }
    ProjectSpec p;
    std::string err;
    if (!parseProject(project_json, p, err)) {
        copyError(err, error, error_len);
        return 1;
    }
    ExportOptions opts;
    opts.kind = o->kind == CAW_EXPORT_FREE        ? ExportKind::Free
                : o->kind == CAW_EXPORT_ONESHOT   ? ExportKind::OneShot
                : o->kind == CAW_EXPORT_WAVETABLE ? ExportKind::Wavetable
                                                  : ExportKind::Loop;
    opts.sampleRate = o->sample_rate;
    opts.seconds = o->seconds;
    opts.frames = o->frames;
    if (o->target) opts.target = o->target;
    if (o->param) opts.param = o->param;
    RenderResult r;
    if (!renderExport(p, opts, r, progress, cancel)) {
        copyError(r.error, error, error_len);
        return 1;
    }
    WavSpec spec;
    spec.sampleRate = r.sampleRate;
    spec.channels = r.channels;
    spec.float32 = opts.kind == ExportKind::Wavetable || o->float32 != 0;
    spec.loop = r.loop;
    if (!writeFile(out_path, encodeWav(spec, r.samples.data(), r.frames), err)) {
        copyError(err, error, error_len);
        return 1;
    }
    return 0;
}

char* caw_library(void) { return dup(caw::libraryJson()); }

int32_t caw_template_count(void) { return caw::kTemplateCount; }

const char* caw_template_file(int32_t i) {
    return i >= 0 && i < caw::kTemplateCount ? caw::kTemplateFiles[i] : nullptr;
}

const char* caw_template_source(int32_t i) {
    return i >= 0 && i < caw::kTemplateCount ? caw::kTemplateSources[i] : nullptr;
}

}  // extern "C"
