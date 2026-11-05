// C API implementation (everything except the audio device, which lives in engine/platform).
#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>

#include "caw.h"
#include "capi_internal.h"
#include "compile.h"
#include "docs.h"
#include "json.h"
#include "midifile.h"
#include "pattern.h"
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

// Nothing may throw across the C API: running out of memory becomes an error the host can show.
const char* const kOutOfMemory = "out of memory: the project is too big for this device";

char* caw_check(const char* source) try {
    using namespace caw;
    if (moduleKindOf(source ? source : "") == ModuleKind::Pattern) {
        PatternResult pr = parsePattern(source);
        if (!pr.pattern)
            return dup("{\"ok\":false,\"kind\":\"pattern\",\"error\":\"" + jsonEscape(pr.error) +
                       "\",\"line\":" + std::to_string(pr.line) + ",\"col\":" + std::to_string(pr.col) + "}");
        return dup("{\"ok\":true," + describePattern(*pr.pattern) + "}");
    }
    CompileResult r = compileModule(source ? source : "");
    if (!r.program)
        return dup("{\"ok\":false,\"error\":\"" + jsonEscape(r.error) + "\",\"line\":" + std::to_string(r.line) +
                   ",\"col\":" + std::to_string(r.col) + "}");
    return dup("{\"ok\":true," + describeProgram(*r.program) + "}");
} catch (const std::bad_alloc&) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\",\"line\":0,\"col\":0}");
}

CawEngine* caw_engine_create(int32_t sample_rate) try {
    if (sample_rate < 8000 || sample_rate > 192000) return nullptr;
    auto e = std::make_unique<CawEngine>();
    e->engine = std::make_unique<caw::Engine>(sample_rate);
    return e.release();
} catch (...) {
    // No C++ exception may cross the C ABI (and the Dart FFI behind it): report failure instead.
    return nullptr;
}

void caw_engine_destroy(CawEngine* e) {
    if (!e) return;
    caw_audio_stop(e);
    e->waitAsync();
    delete e;
}

char* caw_engine_set_project(CawEngine* e, const char* json) try {
    if (!e || !json) return dup("{\"ok\":false,\"error\":\"no engine\",\"modules\":{}}");
    return dup(e->engine->setProjectJson(json));
} catch (const std::bad_alloc&) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\",\"modules\":{}}");
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

// Previews keep a small id-to-layer map on the control side; out of memory drops the preview, never throws.
void caw_engine_note_on(CawEngine* e, const char* layer_id, int32_t id, double pitch, double velocity) try {
    if (e && layer_id) e->engine->noteOn(layer_id, id, pitch, velocity);
} catch (const std::bad_alloc&) {
}

void caw_engine_note_pitch(CawEngine* e, int32_t id, double pitch) {
    if (e) e->engine->notePitch(id, pitch);
}

void caw_engine_note_off(CawEngine* e, int32_t id) {
    if (e) e->engine->noteOff(id);
}

void caw_engine_notes_off(CawEngine* e) {
    if (e) e->engine->notesOff();
}

void caw_engine_set_master(CawEngine* e, double volume) {
    if (e) e->engine->setMaster(volume);
}

void caw_engine_play(CawEngine* e) {
    if (e) e->engine->play();
}

void caw_engine_play_at(CawEngine* e, double step) {
    if (e) e->engine->play(step);
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
                   int32_t* cancel, char* error, int32_t error_len) try {
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
    // Streams loop and free exports to the file, so a long song needs no more memory than a short one (F7.2).
    if (!renderExportToWav(p, opts, out_path, o->float32 != 0, err, progress, cancel)) {
        copyError(err, error, error_len);
        return 1;
    }
    return 0;
} catch (const std::bad_alloc&) {
    copyError(kOutOfMemory, error, error_len);
    return 1;
}

char* caw_pattern_from_midi(const uint8_t* data, int32_t size) try {
    if (!data || size <= 0) return dup("{\"ok\":false,\"error\":\"the file is empty\",\"pattern\":\"\"}");
    std::string err;
    const std::string text = caw::patternFromMidi(data, static_cast<size_t>(size), caw::MidiImportOptions{}, err);
    if (text.empty())
        return dup("{\"ok\":false,\"error\":\"" + caw::jsonEscape(err) + "\",\"pattern\":\"\"}");
    return dup("{\"ok\":true,\"error\":\"\",\"pattern\":\"" + caw::jsonEscape(text) + "\"}");
} catch (const std::bad_alloc&) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\",\"pattern\":\"\"}");
}

int32_t caw_pattern_export(const char* pattern_source, double bpm, int32_t beats_per_bar, int32_t format,
                           const char* out_path, char* error, int32_t error_len) try {
    using namespace caw;
    if (!pattern_source || !out_path) {
        copyError("missing argument", error, error_len);
        return 1;
    }
    if (!(bpm >= 20 && bpm <= 400) || beats_per_bar < 1 || beats_per_bar > 16 ||
        (format != CAW_MIDI_SMF && format != CAW_MIDI_CLIP)) {
        copyError("bpm must be 20 to 400, beats per bar 1 to 16 and format 0 (.mid) or 1 (MIDI 2.0 clip)", error,
                  error_len);
        return 1;
    }
    PatternResult pr = parsePattern(pattern_source);
    if (!pr.pattern) {
        copyError(pr.error, error, error_len);
        return 1;
    }
    const std::vector<uint8_t> bytes = format == CAW_MIDI_CLIP ? patternToMidiClip(*pr.pattern, bpm, beats_per_bar)
                                                               : patternToSmf(*pr.pattern, bpm, beats_per_bar);
    std::string err;
    if (!writeFile(out_path, bytes, err)) {
        copyError(err, error, error_len);
        return 1;
    }
    return 0;
} catch (const std::bad_alloc&) {
    copyError(kOutOfMemory, error, error_len);
    return 1;
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
