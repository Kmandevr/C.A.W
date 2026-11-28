// C API implementation (everything except the audio device, which lives in engine/platform).
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <new>
#include <string>

#include "caw.h"
#include "builtin_drums.h"
#include "drums_kits.h"
#include "presets.h"
#include "fx_migrate.h"
#include "capi_internal.h"
#include "output_safety.h"
#include "component_test.h"
#include "sample_pack.h"
#include "json.h"
#include "midifile.h"
#include "midi_sender.h"
#include "pattern.h"
#include "render.h"
#include "render_stems.h"
#include "scan/scan_file.h"
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
    caw::midiSender().detachIf(e->engine.get(), caw::Engine::midiClockNs());  // API 48: no sender pump reaches it after this
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
                    bool reload, uint32_t flags = 0, const char* legacy_sha256 = nullptr) try {
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
    if (flags & ~static_cast<uint32_t>(CAW_LOAD_LEGACY_GRACE))
        return dup("{\"ok\":false,\"error\":\"unknown load flags\",\"errorCode\":3}");
    // The grace names the exact file: 64 hex digits of its SHA-256.
    std::string graceHash;
    if (flags & static_cast<uint32_t>(CAW_LOAD_LEGACY_GRACE)) {
        graceHash = legacy_sha256 ? legacy_sha256 : "";
        bool hex = graceHash.size() == 64;
        for (const char c : graceHash) hex = hex && std::isxdigit(static_cast<unsigned char>(c));
        if (!hex)
            return dup("{\"ok\":false,\"error\":\"the legacy grace needs the SHA-256 of the file trusted before 1.0.7\","
                       "\"errorCode\":3}");
    }
    const ModuleLoadResult result =
        reload ? e->engine->reloadNativeComponent(library_path, expected_component_id, trust)
               : e->engine->loadNativeComponent(library_path, expected_component_id, trust, graceHash);
    return dup(std::string("{\"ok\":") + (result.success ? "true" : "false") +
               ",\"componentId\":\"" + jsonEscape(result.componentId) +
               "\",\"error\":\"" + jsonEscape(result.message) +
               "\",\"errorCode\":" + std::to_string(static_cast<int>(result.error)) +
               ",\"sha256\":\"" + jsonEscape(result.sha256) + "\",\"scan_verdict\":\"" +
               jsonEscape(result.scanVerdict) + "\",\"grace_applied\":" + (result.graceApplied ? "true" : "false") +
               "}");
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

char* caw_engine_load_component_ex(CawEngine* e, const char* library_path, const char* expected_component_id,
                                   int32_t trust_level, uint32_t flags, const char* legacy_sha256) {
    return loadComponent(e, library_path, expected_component_id, trust_level, false, flags, legacy_sha256);
}

char* caw_engine_scan_component(CawEngine*, const char* library_path, const char* expected_component_id,
                                uint32_t flags) try {
    using namespace caw::scan;
    if (!library_path) return dup(scanErrorJson("missing library path"));
    if (flags & ~(static_cast<uint32_t>(CAW_LOAD_LEGACY_GRACE) | static_cast<uint32_t>(CAW_SCAN_PLUGIN)))
        return dup(scanErrorJson("unknown scan flags"));
    const FileScan scanned = scanFile(library_path, expected_component_id ? expected_component_id : "");
    if (!scanned.ok) return dup(scanErrorJson(scanned.error));
    const PolicyInput input{(flags & static_cast<uint32_t>(CAW_SCAN_PLUGIN)) ? Host::Plugin : Host::Component,
                            (flags & static_cast<uint32_t>(CAW_LOAD_LEGACY_GRACE)) != 0};
    return dup(scanJson(scanned, decide(*scanned.report, input), input));
} catch (const std::bad_alloc&) {
    return dup(caw::scan::scanErrorJson(kOutOfMemory));
} catch (...) {
    return dup(caw::scan::scanErrorJson("the scan failed"));
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

int32_t caw_engine_set_component_auto_gain(CawEngine* e, const char* layer_id, uint32_t index, int32_t on) try {
    return e && e->engine && e->engine->setComponentAutoGain(layer_id ? layer_id : "", index, on != 0) ? 1 : 0;
} catch (...) {
    return 0;
}

int32_t caw_engine_component_auto_gain(CawEngine* e, const char* layer_id, uint32_t index, float* trim_db) try {
    if (!e || !e->engine) return -1;
    float db = 0.0f;
    const int32_t r = e->engine->componentAutoGain(layer_id ? layer_id : "", index, db);
    if (trim_db) *trim_db = r == 1 ? db : 0.0f;
    return r;
} catch (...) {
    return 0;
}

int32_t caw_engine_component_meter(CawEngine* e, const char* layer_id, uint32_t index, CawSlotMeter* out) try {
    if (!e || !e->engine) return -1;
    float l = 0.0f, r = 0.0f;
    bool clipped = false;
    const int32_t got = e->engine->componentMeter(layer_id ? layer_id : "", index, l, r, clipped);
    if (out) *out = CawSlotMeter{got == 1 ? l : 0.0f, got == 1 ? r : 0.0f, got == 1 && clipped ? 1 : 0};
    return got;
} catch (...) {
    return 0;
}

int32_t caw_engine_component_cost(CawEngine* e, const char* layer_id, uint32_t index, CawSlotCost* out) try {
    if (!e || !e->engine) return -1;
    double share = -1.0;
    uint32_t latency = 0;
    bool armed = false;
    const int32_t got = e->engine->componentCost(layer_id ? layer_id : "", index, share, latency, armed);
    if (out && out->struct_size >= sizeof(uint32_t)) {
        CawSlotCost c{};
        c.struct_size = static_cast<uint32_t>(sizeof(CawSlotCost));
        c.cpu_share = got == 1 ? static_cast<float>(share) : -1.0f;
        c.latency_frames = got == 1 ? latency : 0;
        const double rate = e->engine->sampleRate();
        c.latency_ms = got == 1 && rate > 0 ? static_cast<float>(latency * 1000.0 / rate) : 0.0f;
        c.armed = got == 1 && armed ? 1 : 0;
        const uint32_t size = out->struct_size < sizeof(CawSlotCost) ? out->struct_size : static_cast<uint32_t>(sizeof(CawSlotCost));
        c.struct_size = out->struct_size;  // the caller's size stays
        std::memcpy(out, &c, size);
    }
    return got;
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
int32_t caw_engine_note_on(CawEngine* e, const char* layer_id, int32_t id, double pitch, double velocity) try {
    return e && layer_id ? e->engine->noteOn(layer_id, id, pitch, velocity) : 0;
} catch (const std::bad_alloc&) {
    return 0;
}

int32_t caw_engine_note_pitch(CawEngine* e, int32_t id, double pitch) {
    return e ? e->engine->notePitch(id, pitch) : 0;
}

int32_t caw_engine_note_off(CawEngine* e, int32_t id) {
    return e ? e->engine->noteOff(id) : 0;
}

int32_t caw_engine_notes_off(CawEngine* e) {
    return e ? e->engine->notesOff() : 0;
}

int32_t caw_engine_set_vca(CawEngine* e, const char* group_id, double volume, int32_t mute, int32_t solo) try {
    return e && group_id && e->engine->setVca(group_id, volume, mute != 0, solo != 0) ? 1 : 0;
} catch (const std::bad_alloc&) {
    return 0;
}

int32_t caw_engine_set_master(CawEngine* e, double volume) {
    return e && e->engine->setMaster(volume) ? 1 : 0;
}

int32_t caw_engine_play(CawEngine* e) {
    return e && e->engine->play() ? 1 : 0;
}

int32_t caw_engine_play_at(CawEngine* e, double step) {
    return e && e->engine->play(step) ? 1 : 0;
}

int32_t caw_engine_play_count_in(CawEngine* e, double step, int32_t beats) {
    return e && e->engine->playCountIn(step, beats) ? 1 : 0;
}

int32_t caw_engine_play_count_in_bars(CawEngine* e, double step, int32_t bars) {
    return e && e->engine->playCountIn(step, bars, true) ? 1 : 0;
}

int32_t caw_engine_set_metronome(CawEngine* e, int32_t on) {
    return e && e->engine->setMetronome(on != 0) ? 1 : 0;
}

static_assert(CAW_OUTPUT_LIMITER == caw::OutputSafety::kLimiter && CAW_OUTPUT_MONO == caw::OutputSafety::kMono);

void caw_engine_set_output_safety(CawEngine* e, int32_t flags) {
    if (e) e->engine->setOutputSafety(flags & (CAW_OUTPUT_LIMITER | CAW_OUTPUT_MONO));
}

int32_t caw_engine_output_safety(CawEngine* e) { return e ? e->engine->outputSafety() : 0; }

void caw_engine_set_metronome_sound(CawEngine* e, double volume, int32_t sound) {
    if (e) e->engine->setMetronomeSound(volume, sound);
}

void caw_engine_test_tone(CawEngine* e, double seconds) {
    if (e) e->engine->testTone(seconds);
}

int32_t caw_engine_test_tone_sounding(CawEngine* e) { return e && e->engine->testToneSounding() ? 1 : 0; }

int32_t caw_engine_release_touches(CawEngine* e) {
    return e && e->engine->releaseTouches() ? 1 : 0;
}

int32_t caw_engine_stop(CawEngine* e) {
    return e && e->engine->stop() ? 1 : 0;
}

int32_t caw_engine_clear_overload(CawEngine* e) {
    return e && e->engine->clearOverload() ? 1 : 0;
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

namespace {

std::string jsonNumber(double v) {
    char b[40];
    std::snprintf(b, sizeof b, "%.17g", v);
    return b;
}

// A tempo map and signatures as JSON arrays (caw_pattern_from_midi; the project JSON's shape).
std::string songMetaJson(const caw::MidiSongMeta& m) {
    std::string out = ",\"tempo_map\":[";
    for (size_t i = 0; i < m.tempo.size(); ++i)
        out += std::string(i ? "," : "") + "{\"beat\":" + jsonNumber(m.tempo[i].beat) + ",\"bpm\":" +
               jsonNumber(m.tempo[i].bpm) + ",\"ramp\":" + (m.tempo[i].ramp ? "true" : "false") + "}";
    out += "],\"time_signatures\":[";
    for (size_t i = 0; i < m.sigs.size(); ++i)
        out += std::string(i ? "," : "") + "{\"bar\":" + std::to_string(m.sigs[i].bar) + ",\"beat\":" +
               jsonNumber(m.sigs[i].beat) + ",\"num\":" + std::to_string(m.sigs[i].num) + ",\"den\":" +
               std::to_string(m.sigs[i].den) + "}";
    return out + "]";
}

// The C API's lists as the engine's, unchecked (the callers check).
bool tempoFromC(const CawTempoPoint* pts, int32_t n, std::vector<caw::TempoPointSpec>& out) {
    if (n < 0 || n > caw::kMaxTempoPoints || (n > 0 && !pts)) return false;
    out.clear();
    for (int32_t i = 0; i < n; ++i) out.push_back({pts[i].beat, pts[i].bpm, pts[i].ramp != 0});
    return true;
}

bool sigsFromC(const CawTimeSig* sigs, int32_t n, std::vector<caw::TimeSigSpec>& out) {
    if (n < 0 || n > caw::kMaxTimeSigs || (n > 0 && !sigs)) return false;
    out.clear();
    for (int32_t i = 0; i < n; ++i) out.push_back({0, sigs[i].beat, sigs[i].num, sigs[i].den});
    return true;
}

}  // namespace

char* caw_pattern_from_midi(const uint8_t* data, int32_t size) try {
    if (!data || size <= 0) return dup("{\"ok\":false,\"error\":\"the file is empty\",\"pattern\":\"\"}");
    std::string err;
    caw::MidiSongMeta song;
    const std::string text = caw::patternFromMidi(data, static_cast<size_t>(size), caw::MidiImportOptions{}, err, &song);
    if (text.empty())
        return dup("{\"ok\":false,\"error\":\"" + caw::jsonEscape(err) + "\",\"pattern\":\"\"}");
    return dup("{\"ok\":true,\"error\":\"\",\"pattern\":\"" + caw::jsonEscape(text) + "\"" + songMetaJson(song) + "}");
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
    {
        MidiSongMeta one;
        one.tempo = {{0.0, bpm, false}};
        one.sigs = {{0, 0.0, beats_per_bar, 4}};
        std::string err;
        if (!checkMidiExport(*pr.pattern, one, format == CAW_MIDI_CLIP, err)) {
            copyError(err, error, error_len);
            return 1;
        }
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

extern "C" char* caw_migrate_component(const char* entry_json) try {
    if (!entry_json) return dup("{\"ok\":false,\"error\":\"missing entry\"}");
    return dup(caw::fx::migrateComponentJson(entry_json));
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

extern "C" char* caw_drums_kit_build(int32_t kind, int32_t style, uint32_t seed, int32_t key, int32_t map) try {
    return dup(caw::drumsKitBuildJson(kind, style, seed, key, map));
} catch (...) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\"}");
}

extern "C" char* caw_drums_kit_tool(const char* request_json) try {
    if (!request_json) return dup("{\"ok\":false,\"error\":\"missing request\"}");
    return dup(caw::drumsKitToolJson(request_json));
} catch (...) {
    return dup(std::string("{\"ok\":false,\"error\":\"") + kOutOfMemory + "\"}");
}

extern "C" void caw_engine_set_quality(CawEngine* e, int32_t quality) {
    if (e && e->engine) e->engine->setQuality(quality);
}

extern "C" int32_t caw_engine_quality(CawEngine* e) { return e && e->engine ? e->engine->quality() : CAW_QUALITY_NORMAL; }

extern "C" void caw_engine_set_play_ahead(CawEngine* e, int32_t on) try {
    if (e && e->engine) e->engine->setPlayAhead(on != 0);
} catch (...) {
}

extern "C" int32_t caw_engine_play_ahead(CawEngine* e) { return e && e->engine && e->engine->playAhead() ? 1 : 0; }

extern "C" int32_t caw_engine_play_ahead_stats(CawEngine* e, CawAheadStats* out) {
    if (!e || !e->engine || !out) return 0;
    const caw::Engine::AheadStats st = e->engine->aheadStats();
    out->tracks = st.tracks;
    out->underruns = st.underruns;
    out->drops = st.drops;
    out->work_ns = st.workNs;
    out->work_frames = st.workFrames;
    return 1;
}

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

// ---- API 47: MIDI out and the MIDI clock ----
static_assert(sizeof(CawMidiOutEvent) == sizeof(caw::MidiOutMessage), "CawMidiOutEvent is MidiOutMessage");
static_assert(offsetof(CawMidiOutEvent, port) == offsetof(caw::MidiOutMessage, port) &&
              offsetof(CawMidiOutEvent, data) == offsetof(caw::MidiOutMessage, data), "same layout");

extern "C" int32_t caw_engine_midi_out_drain(CawEngine* e, CawMidiOutEvent* out, int32_t capacity) {
    if (!e || !e->engine || !out || capacity <= 0) return 0;
    caw::MidiOutMessage buf[64];
    int32_t total = 0;
    while (total < capacity) {
        const int32_t n = e->engine->midiOutDrain(buf, std::min<int32_t>(64, capacity - total));
        for (int32_t k = 0; k < n; ++k) {
            CawMidiOutEvent& o = out[total + k];
            o.time_ns = buf[k].timeNs;
            o.port = buf[k].port;
            o.size = buf[k].size;
            for (int j = 0; j < 3; ++j) o.data[j] = buf[k].data[j], o.reserved[j] = 0;
        }
        total += n;
        if (n < 64) break;
    }
    return total;
}

extern "C" void caw_engine_set_midi_out_active(CawEngine* e, int32_t on) {
    if (e && e->engine) e->engine->setMidiOutActive(on != 0);
}

extern "C" int64_t caw_engine_midi_out_dropped(CawEngine* e) {
    return e && e->engine ? static_cast<int64_t>(e->engine->midiOutDropped()) : 0;
}

extern "C" void caw_engine_set_midi_out_port(CawEngine* e, int32_t port, int64_t offset_ns) {
    if (e && e->engine) e->engine->setMidiOutPortOffset(port, offset_ns);
}

extern "C" void caw_engine_set_midi_clock_out(CawEngine* e, int32_t port_mask) {
    if (e && e->engine) e->engine->setMidiClockOut(static_cast<uint32_t>(port_mask));
}

extern "C" void caw_engine_set_midi_clock_follow(CawEngine* e, int32_t on) try {
    if (e && e->engine) e->engine->setMidiClockFollow(on != 0);
} catch (...) {
}

extern "C" int32_t caw_engine_midi_clock_in(CawEngine* e, const uint8_t* bytes, int32_t count, int64_t time_ns) try {
    return e && e->engine ? e->engine->midiClockIn(bytes, count, time_ns) : 0;
} catch (...) {
    return 0;
}

extern "C" double caw_engine_midi_clock_in_bpm(CawEngine* e) {
    return e && e->engine && e->engine->midiClockFollowing() ? e->engine->midiClockInBpm() : 0.0;
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

// ---- the tempo map and time signatures (API version 31) ----

extern "C" int32_t caw_engine_set_tempo_map(CawEngine* e, const CawTempoPoint* points, int32_t count) try {
    std::vector<caw::TempoPointSpec> pts;
    if (!e || !tempoFromC(points, count, pts)) return 1;
    return e->engine->setTempoMap(std::move(pts)).empty() ? 0 : 1;
} catch (...) {
    return 1;
}

extern "C" int32_t caw_engine_set_time_signatures(CawEngine* e, const CawTimeSig* sigs, int32_t count) try {
    std::vector<caw::TimeSigSpec> list;
    if (!e || !sigsFromC(sigs, count, list)) return 1;
    std::string error;
    if (!caw::timeSigsFromBeats(list, error)) return 1;
    return e->engine->setTimeSignatures(std::move(list)).empty() ? 0 : 1;
} catch (...) {
    return 1;
}

extern "C" int32_t caw_engine_set_bpm(CawEngine* e, double bpm) try {
    if (!e) return 1;
    return e->engine->setTempoMap({{0.0, bpm, false}}).empty() ? 0 : 1;
} catch (...) {
    return 1;
}

extern "C" int32_t caw_engine_position(CawEngine* e, CawPosition* out) try {
    if (!e || !out) return 1;
    if (out->struct_size < sizeof(CawPosition)) return 2;
    const caw::Engine::SongPosition p = e->engine->position();
    out->playing = p.playing ? 1 : 0;
    out->frame = p.frame;
    out->beat = p.beat;
    out->seconds = p.seconds;
    out->bpm = p.bpm;
    out->bar = p.bar;
    out->beat_in_bar = p.beatInBar;
    out->num = p.num;
    out->den = p.den;
    return 0;
} catch (...) {
    return 1;
}

extern "C" int32_t caw_pattern_export_song(const char* pattern_source, const CawTempoPoint* points, int32_t point_count,
                                           const CawTimeSig* sigs, int32_t sig_count, int32_t format,
                                           const char* out_path, char* error, int32_t error_len) try {
    using namespace caw;
    if (!pattern_source || !out_path || (format != CAW_MIDI_SMF && format != CAW_MIDI_CLIP)) {
        copyError("missing argument, or format is not 0 (.mid) or 1 (MIDI 2.0 clip)", error, error_len);
        return 1;
    }
    MidiSongMeta song;
    std::string err;
    std::vector<TempoPointSpec> pts;
    std::vector<TimeSigSpec> list;
    if (!tempoFromC(points, point_count, pts) || !sigsFromC(sigs, sig_count, list)) {
        copyError("the tempo map or the time signatures are too long", error, error_len);
        return 1;
    }
    if (!pts.empty()) {
        if (!checkTempoPoints(pts, err)) {
            copyError(err, error, error_len);
            return 1;
        }
        song.tempo = std::move(pts);
    }
    if (!list.empty()) {
        if (!timeSigsFromBeats(list, err)) {
            copyError(err, error, error_len);
            return 1;
        }
        song.sigs = std::move(list);
    }
    PatternResult pr = parsePattern(pattern_source);
    if (!pr.pattern) {
        copyError(pr.error, error, error_len);
        return 1;
    }
    if (!checkMidiExport(*pr.pattern, song, format == CAW_MIDI_CLIP, err)) {
        copyError(err, error, error_len);
        return 1;
    }
    const std::vector<uint8_t> bytes = format == CAW_MIDI_CLIP ? patternToMidiClip(*pr.pattern, song) : patternToSmf(*pr.pattern, song);
    if (!writeFile(out_path, bytes, err)) {
        copyError(err, error, error_len);
        return 1;
    }
    return 0;
} catch (const std::bad_alloc&) {
    copyError(kOutOfMemory, error, error_len);
    return 1;
}
