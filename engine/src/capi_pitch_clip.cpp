// C API 42: the clip pitch editor's engine (Lark, one voice) for the app's workers: analyse a clip into notes, read its pitch curve, render per-note edits, free.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "caw.h"
#include "json.h"
#include "lark_editor.h"

struct CawPitchClip {
    caw::lark::Analysis analysis;
};

namespace {

constexpr size_t kMaxOptionsBytes = 4096;
constexpr size_t kMaxEditsBytes = 8u << 20;

char* dup(const std::string& s) {
    char* p = static_cast<char*>(std::malloc(s.size() + 1));
    if (p) std::memcpy(p, s.c_str(), s.size() + 1);
    return p;
}
std::string fail(const std::string& e) { return "{\"ok\":false,\"error\":\"" + caw::jsonEscape(e) + "\"}"; }
std::string num(double v) {
    char b[40];
    std::snprintf(b, sizeof b, "%.10g", std::isfinite(v) ? v : 0.0);
    return b;
}

bool parse(const char* text, size_t limit, caw::Json& out, std::string& error, const char* what) {
    if (!text || !*text) return true;
    const size_t n = std::strlen(text);
    if (n > limit) return error = std::string(what) + " are longer than " + std::to_string(limit) + " bytes", false;
    if (!caw::parseJson(std::string_view(text, n), out, error)) return error = std::string(what) + ": " + error, false;
    if (out.type != caw::Json::Type::Object) return error = std::string(what) + " must be an object", false;
    return true;
}

bool number(const caw::Json& j, const std::string& key, double lo, double hi, double& out, std::string& error,
            const std::string& where = "") {
    const caw::Json* v = j.get(key);
    if (!v || v->type == caw::Json::Type::Null) return true;
    if (v->type != caw::Json::Type::Number || !std::isfinite(v->num) || v->num < lo || v->num > hi) {
        char b[200];
        std::snprintf(b, sizeof b, "%s%s must be a number %g..%g", where.c_str(), key.c_str(), lo, hi);
        error = b;
        return false;
    }
    out = v->num;
    return true;
}

}  // namespace

extern "C" {

char* caw_pitch_clip_analyse(const float* left, const float* right, int64_t frames, int32_t sample_rate,
                             const char* options_json, CawPitchClip** out) try {
    if (out) *out = nullptr;
    if (!out) return dup(fail("no place for the clip"));
    caw::Json j;
    std::string error;
    if (!parse(options_json, kMaxOptionsBytes, j, error, "options")) return dup(fail(error));
    caw::lark::AnalyseOptions o;
    if (j.type == caw::Json::Type::Object) {
        for (const auto& [k, v] : j.obj)
            if (k != "low_hz" && k != "high_hz") return dup(fail("options: unknown key " + k));
        if (!number(j, "low_hz", 50, 400, o.lowHz, error) || !number(j, "high_hz", 200, 2000, o.highHz, error))
            return dup(fail(error));
    }
    auto clip = std::make_unique<CawPitchClip>();  // freed if anything below throws
    if (!caw::lark::analyse(left, right, frames, sample_rate, o, clip->analysis, error)) return dup(fail(error));
    const caw::lark::Analysis& a = clip->analysis;
    std::string s = "{\"ok\":true,\"error\":\"\",\"sample_rate\":" + std::to_string(sample_rate) +
                    ",\"frames\":" + std::to_string(frames) + ",\"hop_frames\":" + std::to_string(a.hopFrames) +
                    ",\"hops\":" + std::to_string(a.midi.size()) + ",\"notes\":[";
    for (size_t k = 0; k < a.notes.size(); ++k) {
        const caw::lark::Note& n = a.notes[k];
        s += std::string(k ? "," : "") + "{\"start\":" + std::to_string(n.start) + ",\"end\":" + std::to_string(n.end) +
             ",\"pitch\":" + num(n.pitch) + ",\"drift_cents\":" + num(n.driftCents) + ",\"vibrato_rate\":" +
             num(n.vibratoRate) + ",\"vibrato_cents\":" + num(n.vibratoCents) + ",\"transition_in_ms\":" +
             num(n.transitionInMs) + ",\"transition_out_ms\":" + num(n.transitionOutMs) + ",\"gain_db\":" +
             num(n.gainDb) + "}";
    }
    *out = clip.release();
    return dup(s + "]}");
} catch (...) {
    return dup(fail("out of memory"));
}

int64_t caw_pitch_clip_curve(const CawPitchClip* clip, float* midi, float* voicing, float* rms_db, int64_t max) {
    if (!clip) return -1;
    const caw::lark::Analysis& a = clip->analysis;
    const int64_t n = static_cast<int64_t>(a.midi.size());
    const int64_t copy = std::clamp<int64_t>(max, 0, n);
    if (midi) std::copy(a.midi.begin(), a.midi.begin() + copy, midi);
    if (voicing) std::copy(a.voicing.begin(), a.voicing.begin() + copy, voicing);
    if (rms_db) std::copy(a.rmsDb.begin(), a.rmsDb.begin() + copy, rms_db);
    return n;
}

char* caw_pitch_clip_render(const CawPitchClip* clip, const float* left, const float* right, int64_t frames,
                            const char* edits_json, float* out_left, float* out_right) try {
    if (!clip) return dup(fail("no clip"));
    const caw::lark::Analysis& a = clip->analysis;
    caw::Json j;
    std::string error;
    if (!parse(edits_json, kMaxEditsBytes, j, error, "edits")) return dup(fail(error));
    std::vector<caw::lark::NoteEdit> edits(a.notes.size());
    size_t edited = 0;
    if (j.type == caw::Json::Type::Object) {
        for (const auto& [k, v] : j.obj)
            if (k != "edits") return dup(fail("edits: unknown key " + k));
        const caw::Json* list = j.get("edits");
        if (list && list->type != caw::Json::Type::Array && list->type != caw::Json::Type::Null)
            return dup(fail("edits must be an array"));
        if (list && list->arr.size() > a.notes.size()) return dup(fail("more edits than notes"));
        std::set<size_t> seen;
        const double limit = 10.0 * a.sampleRate;
        for (size_t i = 0; list && i < list->arr.size(); ++i) {
            const caw::Json& e = list->arr[i];
            const std::string where = "edits[" + std::to_string(i) + "].";
            if (e.type != caw::Json::Type::Object) return dup(fail(where.substr(0, where.size() - 1) + " must be an object"));
            static const char* kKeys[] = {"note", "pitch", "drift", "vibrato", "formant", "formant_keep", "time_frames",
                                          "stretch", "gain_db", "transition_ms"};
            for (const auto& [k, v] : e.obj)
                if (std::find_if(std::begin(kKeys), std::end(kKeys), [&](const char* x) { return k == x; }) == std::end(kKeys))
                    return dup(fail(where + k + " is not an edit"));
            double note = -1;
            if (!number(e, "note", 0, static_cast<double>(a.notes.size()) - 1, note, error, where) || note < 0 ||
                note != std::floor(note))
                return dup(fail(error.empty() ? where + "note must name a note, 0.." + std::to_string(a.notes.size()) + " - 1" : error));
            const size_t k = static_cast<size_t>(note);
            if (!seen.insert(k).second) return dup(fail(where + "note " + std::to_string(k) + " is edited twice"));
            caw::lark::NoteEdit& ed = edits[k];
            if (!number(e, "pitch", -24, 24, ed.pitch, error, where) || !number(e, "drift", 0, 1, ed.drift, error, where) ||
                !number(e, "vibrato", 0, 2, ed.vibrato, error, where) || !number(e, "formant", -12, 12, ed.formant, error, where) ||
                !number(e, "time_frames", -limit, limit, ed.timeFrames, error, where) ||
                !number(e, "stretch", 0.25, 4, ed.stretch, error, where) || !number(e, "gain_db", -60, 24, ed.gainDb, error, where) ||
                !number(e, "transition_ms", 0, 500, ed.transitionMs, error, where))
                return dup(fail(error));
            ed.timeFrames = std::floor(ed.timeFrames + 0.5);
            if (const caw::Json* fk = e.get("formant_keep")) {
                if (fk->type != caw::Json::Type::Bool) return dup(fail(where + "formant_keep must be true or false"));
                ed.formantKeep = fk->b;
            }
            edited += !ed.identity();
        }
    }
    if (!caw::lark::render(a, left, right, frames, edits, out_left, right ? out_right : nullptr, error)) return dup(fail(error));
    return dup("{\"ok\":true,\"error\":\"\",\"notes_edited\":" + std::to_string(edited) + "}");
} catch (...) {
    return dup(fail("out of memory"));
}

void caw_pitch_clip_free(CawPitchClip* clip) { delete clip; }

}  // extern "C"
