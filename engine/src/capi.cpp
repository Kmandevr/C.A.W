// C API implementation (everything except the audio device, which lives in engine/platform).
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>

#include "caw.h"
#include "builtin_drums.h"
#include "presets.h"
#include "capi_internal.h"
#include "component_test.h"
#include "sample_pack.h"
#include "json.h"
#include "midifile.h"
#include "pattern.h"
#include "render.h"
#include "render_stems.h"
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

static_assert(CAW_INSTRUMENT_INDEX == caw::Engine::kInstrumentIndex, "the C API and the Engine name the instrument alike");

int32_t caw_api_version(void) { return CAW_API_VERSION; }

void caw_free(char* s) { std::free(s); }

// Nothing may throw across the C API: running out of memory becomes an error the host can show.
const char* const kOutOfMemory = "out of memory: the project is too big for this device";

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

namespace {
// Load and reload share their checks and their JSON result.
char* loadComponent(CawEngine* e, const char* library_path, const char* expected_component_id, int32_t trust_level,
                    bool reload) try {
    using namespace caw;
    if (!e || !e->engine || !library_path || !expected_component_id)
        return dup("{\"ok\":false,\"error\":\"missing engine, library path or component ID\",\"errorCode\":3}");
    NativeModuleTrust trust;
    switch (trust_level) {
        case CAW_NATIVE_TRUST_BLOCKED: trust = NativeModuleTrust::Blocked; break;
        case CAW_NATIVE_TRUST_ISOLATED: trust = NativeModuleTrust::Isolated; break;
        case CAW_NATIVE_TRUST_TRUSTED: trust = NativeModuleTrust::Trusted; break;
        default:
            return dup("{\"ok\":false,\"error\":\"invalid native component trust level\",\"errorCode\":3}");
    }
    const ModuleLoadResult result = reload ? e->engine->reloadNativeComponent(library_path, expected_component_id, trust)
                                           : e->engine->loadNativeComponent(library_path, expected_component_id, trust);
    return dup(std::string("{\"ok\":") + (result.success ? "true" : "false") +
               ",\"componentId\":\"" + jsonEscape(result.componentId) +
               "\",\"error\":\"" + jsonEscape(result.message) +
               "\",\"errorCode\":" + std::to_string(static_cast<int>(result.error)) + "}");
} catch (const std::bad_alloc&) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\",\"errorCode\":4}");
} catch (...) {
    return dup("{\"ok\":false,\"error\":\"native component loading failed\",\"errorCode\":4}");
}
}  // namespace

char* caw_engine_load_component(CawEngine* e, const char* library_path, const char* expected_component_id,
                                int32_t trust_level) {
    return loadComponent(e, library_path, expected_component_id, trust_level, false);
}

char* caw_engine_reload_component(CawEngine* e, const char* library_path, const char* expected_component_id,
                                  int32_t trust_level) {
    return loadComponent(e, library_path, expected_component_id, trust_level, true);
}

char* caw_engine_components(CawEngine* e) try {
    if (!e || !e->engine) return dup("{\"ok\":false,\"error\":\"no engine\",\"components\":[]}");
    return dup(e->engine->nativeComponentsJson());
} catch (const std::bad_alloc&) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\",\"components\":[]}");
} catch (...) {
    return dup("{\"ok\":false,\"error\":\"native component listing failed\",\"components\":[]}");
}

int32_t caw_engine_unload_component(CawEngine* e, const char* component_id) try {
    return e && e->engine && component_id && e->engine->unloadNativeComponent(component_id) ? 1 : 0;
} catch (...) {
    return 0;
}

int32_t caw_engine_set_component_param(CawEngine* e, const char* layer_id, uint32_t index, const char* param_id,
                                       double value) try {
    return e && e->engine && param_id &&
                   e->engine->setComponentParam(layer_id ? layer_id : "", index, param_id, value)
               ? 1 : 0;
} catch (...) {
    return 0;
}

int32_t caw_engine_set_component_bypass(CawEngine* e, const char* layer_id, uint32_t index, int32_t bypass) try {
    return e && e->engine && e->engine->setComponentBypass(layer_id ? layer_id : "", index, bypass != 0) ? 1 : 0;
} catch (...) {
    return 0;
}

int32_t caw_engine_set_send(CawEngine* e, const char* layer_id, uint32_t index, double level, int32_t pre,
                            int32_t mute) try {
    return e && e->engine && layer_id && e->engine->setSend(layer_id, index, level, pre != 0, mute != 0) ? 1 : 0;
} catch (...) {
    return 0;
}

int32_t caw_engine_component_display(CawEngine* e, const char* layer_id, uint32_t index, float* out, int32_t max) try {
    if (!e || !e->engine || !out || max <= 0) return e && e->engine ? 0 : -1;
    return e->engine->componentDisplay(layer_id ? layer_id : "", index, out, static_cast<uint32_t>(max));
} catch (...) {
    return 0;
}

char* caw_engine_component_states(CawEngine* e, const char* layer_id) try {
    if (!e || !e->engine) return nullptr;
    return dup(e->engine->componentStatesJson(layer_id ? layer_id : ""));
} catch (...) {
    return nullptr;
}

int32_t caw_engine_set_component_state(CawEngine* e, const char* layer_id, uint32_t index, const uint8_t* data,
                                       int32_t size, uint32_t version) try {
    if (!e || !e->engine || size < 0 || (size > 0 && !data)) return 0;
    return e->engine->setComponentState(layer_id ? layer_id : "", index, data, static_cast<size_t>(size), version) ? 1 : 0;
} catch (...) {
    return 0;
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

void caw_engine_play_count_in(CawEngine* e, double step, int32_t beats) {
    if (e) e->engine->playCountIn(step, beats);
}

void caw_engine_set_metronome(CawEngine* e, int32_t on) {
    if (e) e->engine->setMetronome(on != 0);
}

void caw_engine_set_metronome_sound(CawEngine* e, double volume, int32_t sound) {
    if (e) e->engine->setMetronomeSound(volume, sound);
}

void caw_engine_test_tone(CawEngine* e, double seconds) {
    if (e) e->engine->testTone(seconds);
}

int32_t caw_engine_test_tone_sounding(CawEngine* e) { return e && e->engine->testToneSounding() ? 1 : 0; }

void caw_engine_release_touches(CawEngine* e) {
    if (e) e->engine->releaseTouches();
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

int32_t caw_engine_layer_meter_stereo(CawEngine* e, int32_t index, CawLayerMeter* out, float* peak_l, float* peak_r) {
    if (!e || !out) return 0;
    caw::LayerMeter m;
    const bool ok = e->engine->layerMeter(index, m);
    out->peak = m.peak;
    out->progress = m.progress;
    out->active = m.active ? 1 : 0;
    out->overloaded = m.overloaded ? 1 : 0;
    if (peak_l) *peak_l = m.peakL;
    if (peak_r) *peak_r = m.peakR;
    return ok ? 1 : 0;
}

int32_t caw_engine_layer_meter(CawEngine* e, int32_t index, CawLayerMeter* out) {
    return caw_engine_layer_meter_stereo(e, index, out, nullptr, nullptr);
}

int32_t caw_engine_layer_meters(CawEngine* e, CawLayerMeterStereo* out, int32_t capacity) {
    if (!e) return 0;
    auto sink = [](void* ctx, int i, const caw::LayerMeter& m) {
        static_cast<CawLayerMeterStereo*>(ctx)[i] =
            CawLayerMeterStereo{m.peak, m.peakL, m.peakR, m.progress, m.active ? 1 : 0, m.overloaded ? 1 : 0};
    };
    return e->engine->layerMeters(out ? capacity : 0, out ? +sink : nullptr, out);
}

void caw_engine_loudness(CawEngine* e, CawLoudness* out) {
    if (!out) return;
    *out = CawLoudness{CAW_METER_NONE, CAW_METER_NONE, CAW_METER_NONE, CAW_METER_NONE, CAW_METER_NONE,
                       CAW_METER_NONE, CAW_METER_NONE, CAW_METER_NONE, 0.0f, 0.0f};
    if (!e) return;
    const caw::LoudnessMeter::Reading r = e->engine->loudness();
    out->momentary_lufs = r.momentary;
    out->short_term_lufs = r.shortTerm;
    out->integrated_lufs = r.integrated;
    out->momentary_max_lufs = r.momentaryMax;
    out->short_term_max_lufs = r.shortTermMax;
    out->true_peak_l_dbtp = r.truePeakL;
    out->true_peak_r_dbtp = r.truePeakR;
    out->true_peak_max_dbtp = r.truePeakMax;
    out->correlation = e->engine->masterCorrelation();
    out->integrated_seconds = static_cast<float>(r.integratedSeconds);
}

void caw_engine_loudness_reset(CawEngine* e) {
    if (e) e->engine->resetLoudness();
}

int32_t caw_engine_layer_correlation(CawEngine* e, int32_t index, float* out) {
    if (!e || !out) return 0;
    return e->engine->layerCorrelation(index, *out) ? 1 : 0;
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

char* caw_component_test(const char* request_json, int32_t trust_level, const char* output_dir,
                         const char* input_dir) try {
    if (!request_json) return dup("{\"ok\":false,\"error\":\"missing request\"}");
    caw::ComponentTestHost host;
    host.trust = trust_level == CAW_NATIVE_TRUST_TRUSTED    ? caw::NativeModuleTrust::Trusted
                 : trust_level == CAW_NATIVE_TRUST_ISOLATED ? caw::NativeModuleTrust::Isolated
                                                             : caw::NativeModuleTrust::Blocked;
    host.outputDir = output_dir ? output_dir : "";
    host.inputDir = input_dir ? input_dir : "";
    return dup(caw::componentTestJson(request_json, host));
} catch (...) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\"}");
}

char* caw_sample_pack_render(const char* request_json, int32_t trust_level, int32_t* progress, int32_t* cancel) try {
    if (!request_json) return dup("{\"ok\":false,\"error\":\"missing request\"}");
    caw::NativeModuleTrust trust;
    switch (trust_level) {
        case CAW_NATIVE_TRUST_BLOCKED: trust = caw::NativeModuleTrust::Blocked; break;
        case CAW_NATIVE_TRUST_ISOLATED: trust = caw::NativeModuleTrust::Isolated; break;
        case CAW_NATIVE_TRUST_TRUSTED: trust = caw::NativeModuleTrust::Trusted; break;
        default: return dup("{\"ok\":false,\"error\":\"invalid native component trust level\"}");
    }
    return dup(caw::samplePackJson(request_json, trust, progress, cancel));
} catch (...) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\"}");
}

}  // extern "C"

extern "C" char* caw_migrate_instrument(const char* entry_json) try {
    if (!entry_json) return dup("{\"ok\":false,\"error\":\"missing entry\"}");
    return dup(caw::migrateInstrumentJson(entry_json));
} catch (...) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\"}");
}

extern "C" char* caw_drums_info(void) try {
    return dup(caw::drumsInfoJson());
} catch (...) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\"}");
}

extern "C" char* caw_drums_randomize(int32_t type, uint32_t seed, double amount, int32_t pad, const char* current_json) try {
    return dup(caw::drumsRandomizeJson(type, seed, std::isfinite(amount) ? amount : 0.0, pad,
                                       current_json ? std::string_view(current_json) : std::string_view()));
} catch (...) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\"}");
}

extern "C" char* caw_drums_explode(const char* entry_json) try {
    if (!entry_json) return dup("{\"ok\":false,\"error\":\"missing entry\"}");
    return dup(caw::drumsExplodeJson(entry_json));
} catch (...) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\"}");
}

extern "C" void caw_engine_set_quality(CawEngine* e, int32_t quality) {
    if (e && e->engine) e->engine->setQuality(quality);
}

extern "C" int32_t caw_engine_quality(CawEngine* e) { return e && e->engine ? e->engine->quality() : CAW_QUALITY_NORMAL; }

// ---- Device MIDI (API 15) ----

extern "C" int64_t caw_midi_clock_ns(void) { return caw::Engine::midiClockNs(); }

extern "C" int32_t caw_engine_midi_ump(CawEngine* e, const char* layer_id, const uint32_t* words, int32_t count,
                                       int64_t time_ns) try {
    return e && e->engine && layer_id ? e->engine->midiUmp(layer_id, words, count, time_ns) : 0;
} catch (...) {
    return 0;
}

extern "C" int32_t caw_engine_midi_bytes(CawEngine* e, const char* layer_id, const uint8_t* bytes, int32_t count,
                                         int64_t time_ns) try {
    return e && e->engine && layer_id ? e->engine->midiBytes(layer_id, bytes, count, time_ns) : 0;
} catch (...) {
    return 0;
}

extern "C" void caw_engine_midi_release(CawEngine* e, const char* layer_id) try {
    if (e && e->engine) e->engine->midiRelease(layer_id ? layer_id : "");
} catch (...) {
}

extern "C" void caw_engine_set_midi_options(CawEngine* e, int32_t flags, double bend_range, double note_bend_range,
                                            double delay_ms) {
    if (e && e->engine) e->engine->setMidiOptions((flags & CAW_MIDI_MPE) != 0, bend_range, note_bend_range, delay_ms);
}

extern "C" int64_t caw_engine_midi_dropped(CawEngine* e) {
    return e && e->engine ? static_cast<int64_t>(e->engine->midiDropped()) : 0;
}

extern "C" int64_t caw_engine_position_at(CawEngine* e, int64_t time_ns) {
    return e && e->engine ? e->engine->positionAt(time_ns) : -1;
}

extern "C" char* caw_render_song(const char* project_json, const char* request_json, int32_t* progress,
                                 int32_t* cancel) try {
    caw::SongRenderResult r;
    if (!project_json || !request_json) {
        r.error = "missing argument";
        return dup(caw::songRenderResultJson(r));
    }
    caw::ProjectSpec p;
    caw::SongRenderRequest req;
    if (!caw::parseProject(project_json, p, r.error) || !caw::parseSongRenderRequest(request_json, req, r.error))
        return dup(caw::songRenderResultJson(r));
    caw::renderSong(p, req, r, progress, cancel);
    return dup(caw::songRenderResultJson(r));
} catch (const std::bad_alloc&) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\",\"files\":[]}");
}
