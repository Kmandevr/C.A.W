// Sample-pack maker: batch-renders an instrument (and effects) over notes, velocities and parameter steps to named WAV files.
#include "sample_pack.h"

#include "presets.h"
#include "utf8_path.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <limits>
#include <map>
#include <memory>
#include <new>
#include <system_error>

#include "builtin_components.h"
#include "caw/detmath.hpp"
#include "caw/instrument.hpp"
#include "component_chain.h"
#include "json.h"
#include "params.h"

namespace caw {

namespace fs = std::filesystem;

namespace {

constexpr uint32_t kMaxFilesCap = 4096;
constexpr std::size_t kMaxEffects = 16;
constexpr std::size_t kMaxAxes = 8;
constexpr std::size_t kMaxAxisValues = 128;
constexpr double kMaxFileSeconds = 60.0;
constexpr double kQuietSeconds = 0.25;
constexpr std::size_t kMaxNameChars = 150;
constexpr double kMaxRoundRobins = 16;
constexpr int kLoopWindow = 64;  // frames either side of the seam compared when choosing a loop start

// ---------------------------------------------------------------- small helpers

int32_t atomicLoad(int32_t* p) {
#if defined(__cpp_lib_atomic_ref)
    return std::atomic_ref<int32_t>(*p).load();
#else
    return __atomic_load_n(p, __ATOMIC_SEQ_CST);
#endif
}
void atomicStore(int32_t* p, int32_t v) {
#if defined(__cpp_lib_atomic_ref)
    std::atomic_ref<int32_t>(*p).store(v);
#else
    __atomic_store_n(p, v, __ATOMIC_SEQ_CST);
#endif
}
bool cancelled(int32_t* c) { return c && atomicLoad(c) != 0; }
void setProgress(int32_t* p, double fraction) {
    if (p) atomicStore(p, static_cast<int32_t>(std::clamp(fraction, 0.0, 1.0) * 1000.0));
}

double toLinear(double db) { return std::pow(10.0, db / 20.0); }
double toDb(double v) { return v > 0 ? 20.0 * std::log10(v) : -std::numeric_limits<double>::infinity(); }

std::string fmt(double v, const char* f = "%.10g") {
    if (v == 0) v = 0;  // no "-0"
    char buf[48];
    std::snprintf(buf, sizeof buf, f, v);
    return buf;
}


struct Out {
    std::string s;
    void raw(const char* t) { s += t; }
    void raw(const std::string& t) { s += t; }
    void sep() {
        if (!s.empty() && s.back() != '{' && s.back() != '[') s += ',';
    }
    void key(const char* k) {
        sep();
        s += '"';
        s += k;
        s += "\":";
    }
    void num(double v) { s += std::isfinite(v) ? fmt(v) : "null"; }
    void str(std::string_view v) {
        s += '"';
        s += jsonEscape(v);
        s += '"';
    }
    void kv(const char* k, double v) { key(k), num(v); }
    void ki(const char* k, int64_t v) { key(k), s += std::to_string(v); }
    void ks(const char* k, std::string_view v) { key(k), str(v); }
    void kb(const char* k, bool v) { key(k), s += v ? "true" : "false"; }
};

std::string failure(const std::string& error) { return "{\"ok\":false,\"error\":\"" + jsonEscape(error) + "\"}"; }

// ---------------------------------------------------------------- request parsing

bool onlyKeys(const Json& j, std::initializer_list<const char*> keys, const char* where, std::string& error) {
    for (const auto& [k, v] : j.obj) {
        if (k == "trust") {
            error = std::string("'trust' is not read from the request (") + where +
                    "): the caller passes it (caw_sample_pack_render's trust_level, the CLI's --trust)";
            return false;
        }
        bool known = false;
        for (const char* key : keys) known = known || k == key;
        if (!known) {
            error = std::string("unknown key '") + k + "' in " + where;
            return false;
        }
    }
    return true;
}

bool number(const Json& j, const char* key, double& out, double lo, double hi, std::string& error) {
    const Json* v = j.get(key);
    if (!v) return true;
    if (v->type != Json::Type::Number || !std::isfinite(v->num) || v->num < lo || v->num > hi) {
        error = std::string("'") + key + "' must be a number from " + fmt(lo) + " to " + fmt(hi);
        return false;
    }
    out = v->num;
    return true;
}

bool text(const Json& j, const char* key, std::string& out, std::string& error) {
    const Json* v = j.get(key);
    if (!v) return true;
    if (v->type != Json::Type::String) {
        error = std::string("'") + key + "' must be a string";
        return false;
    }
    out = v->str;
    return true;
}

bool flag(const Json& j, const char* key, bool& out, std::string& error) {
    const Json* v = j.get(key);
    if (!v) return true;
    if (v->type != Json::Type::Bool) {
        error = std::string("'") + key + "' must be true or false";
        return false;
    }
    out = v->b;
    return true;
}

bool parseComponent(const Json& j, PackComponent& c, const char* where, std::string& error) {
    if (j.type == Json::Type::String) {
        c.id = j.str;
        if (c.id.empty()) error = std::string(where) + " needs an id";
        return !c.id.empty();
    }
    if (j.type != Json::Type::Object) {
        error = std::string(where) + " must be an id or an object";
        return false;
    }
    if (!onlyKeys(j, {"id", "library", "params"}, where, error)) return false;
    if (!text(j, "id", c.id, error) || !text(j, "library", c.library, error)) return false;
    if (c.id.empty()) {
        error = std::string(where) + " needs an id";
        return false;
    }
    if (const Json* p = j.get("params")) {
        if (p->type != Json::Type::Object) {
            error = std::string(where) + ": 'params' must be an object of parameter id to value";
            return false;
        }
        for (const auto& [k, v] : p->obj) {
            if (v.type != Json::Type::Number || !std::isfinite(v.num)) {
                error = "parameter '" + k + "' must be a number";
                return false;
            }
            c.params.emplace_back(k, v.num);
        }
    }
    return true;
}

// A list of numbers, or {"from", "to", "steps"} evenly spaced (steps 1: from).
bool numberList(const Json& j, const char* where, std::vector<double>& out, std::string& error) {
    out.clear();
    if (j.type == Json::Type::Array) {
        if (j.arr.empty() || j.arr.size() > kMaxAxisValues) {
            error = std::string("'") + where + "' needs 1 to " + std::to_string(kMaxAxisValues) + " values";
            return false;
        }
        for (const Json& v : j.arr) {
            if (v.type != Json::Type::Number || !std::isfinite(v.num)) {
                error = std::string("'") + where + "' values must be numbers";
                return false;
            }
            out.push_back(v.num);
        }
        return true;
    }
    if (j.type != Json::Type::Object) {
        error = std::string("'") + where + "' must be a list or {\"from\", \"to\", \"steps\"}";
        return false;
    }
    if (!onlyKeys(j, {"from", "to", "steps"}, where, error)) return false;
    double from = 0, to = 0, steps = 0;
    if (!j.get("from") || !j.get("to") || !j.get("steps")) {
        error = std::string("'") + where + "' needs 'from', 'to' and 'steps'";
        return false;
    }
    if (!number(j, "from", from, -1e9, 1e9, error) || !number(j, "to", to, -1e9, 1e9, error) ||
        !number(j, "steps", steps, 1, static_cast<double>(kMaxAxisValues), error))
        return false;
    if (steps != std::floor(steps)) {
        error = std::string("'") + where + "' steps must be a whole number";
        return false;
    }
    const int n = static_cast<int>(steps);
    for (int i = 0; i < n; ++i) out.push_back(n == 1 ? from : from + (to - from) * i / (n - 1));
    return true;
}

bool parseNotes(const Json& j, std::vector<int>& out, std::string& error) {
    out.clear();
    if (j.type == Json::Type::Object) {
        if (!onlyKeys(j, {"from", "to", "step"}, "notes", error)) return false;
        int bounds[2] = {0, 0};
        const char* keys[2] = {"from", "to"};
        for (int k = 0; k < 2; ++k) {
            const Json* v = j.get(keys[k]);
            if (!v) {
                error = "'notes' needs 'from' and 'to'";
                return false;
            }
            if (v->type == Json::Type::String) {
                if (!parseNoteName(v->str, bounds[k])) {
                    error = "'" + v->str + "' is not a note name (C4 = 60)";
                    return false;
                }
            } else if (v->type == Json::Type::Number && v->num == std::floor(v->num) && v->num >= 0 && v->num <= 127) {
                bounds[k] = static_cast<int>(v->num);
            } else {
                error = "'notes' from and to must be note names or MIDI notes 0 to 127";
                return false;
            }
        }
        double step = 1;
        if (!number(j, "step", step, 1, 127, error)) return false;
        if (step != std::floor(step) || bounds[1] < bounds[0]) {
            error = "'notes' needs a whole 'step' and 'to' at or above 'from'";
            return false;
        }
        for (int n = bounds[0]; n <= bounds[1]; n += static_cast<int>(step)) out.push_back(n);
        return true;
    }
    if (j.type != Json::Type::Array || j.arr.empty() || j.arr.size() > 128) {
        error = "'notes' must be a list of 1 to 128 notes (names or MIDI numbers) or {\"from\", \"to\", \"step\"}";
        return false;
    }
    for (const Json& v : j.arr) {
        int n = 0;
        if (v.type == Json::Type::String) {
            if (!parseNoteName(v.str, n)) {
                error = "'" + v.str + "' is not a note name (C4 = 60)";
                return false;
            }
        } else if (v.type == Json::Type::Number && v.num == std::floor(v.num) && v.num >= 0 && v.num <= 127) {
            n = static_cast<int>(v.num);
        } else {
            error = "notes must be note names or MIDI notes 0 to 127";
            return false;
        }
        if (std::find(out.begin(), out.end(), n) != out.end()) {
            error = "note " + noteName(n) + " is listed twice";
            return false;
        }
        out.push_back(n);
    }
    return true;
}

bool parseVelocities(const Json& j, std::vector<int>& out, std::string& error) {
    std::vector<double> v;
    if (!numberList(j, "velocities", v, error)) return false;
    out.clear();
    for (double x : v) {
        const int r = static_cast<int>(std::lround(x));
        if (!(x >= 1 && x <= 127)) {
            error = "velocities must be 1 to 127";
            return false;
        }
        if (std::find(out.begin(), out.end(), r) != out.end()) {
            error = "velocity " + std::to_string(r) + " is listed twice";
            return false;
        }
        out.push_back(r);
    }
    return true;
}

bool parseAxis(const Json& j, PackParamAxis& a, std::size_t effects, std::string& error) {
    if (j.type != Json::Type::Object) {
        error = "each of 'params' must be {\"id\", \"values\"} or {\"id\", \"from\", \"to\", \"steps\"}";
        return false;
    }
    if (!onlyKeys(j, {"id", "effect", "values", "from", "to", "steps"}, "params", error)) return false;
    if (!text(j, "id", a.id, error)) return false;
    if (a.id.empty()) {
        error = "each of 'params' needs an 'id'";
        return false;
    }
    double effect = -1;
    if (!number(j, "effect", effect, 0, kMaxEffects - 1, error)) return false;
    if (j.get("effect")) {
        if (effect != std::floor(effect) || effect >= static_cast<double>(effects)) {
            error = "param '" + a.id + "': 'effect' must be an index into 'effects'";
            return false;
        }
        a.effect = static_cast<int>(effect);
    }
    if (const Json* v = j.get("values")) {
        if (j.get("from") || j.get("to") || j.get("steps")) {
            error = "param '" + a.id + "': give 'values' or 'from', 'to' and 'steps', not both";
            return false;
        }
        return numberList(*v, "values", a.values, error);
    }
    Json range;
    range.type = Json::Type::Object;
    for (const char* k : {"from", "to", "steps"})
        if (const Json* v = j.get(k)) range.obj[k] = *v;
    return numberList(range, "params", a.values, error);
}

}  // namespace

// ---------------------------------------------------------------- names

std::string noteName(int midi) {
    static const char* kNames[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
    midi = std::clamp(midi, 0, 127);
    return std::string(kNames[midi % 12]) + std::to_string(midi / 12 - 1);
}

bool parseNoteName(std::string_view s, int& midi) {
    if (s.size() < 2) return false;
    const char letter = static_cast<char>(std::toupper(static_cast<unsigned char>(s[0])));
    if (letter < 'A' || letter > 'G') return false;
    static const int base[] = {9, 11, 0, 2, 4, 5, 7};  // A..G
    int n = base[letter - 'A'];
    std::size_t i = 1;
    if (s[i] == '#') ++n, ++i;
    else if (s[i] == 'b') --n, ++i;
    bool negative = false;
    if (i < s.size() && s[i] == '-') negative = true, ++i;
    if (i + 1 != s.size() || !std::isdigit(static_cast<unsigned char>(s[i]))) return false;
    const int oct = (s[i] - '0') * (negative ? -1 : 1);
    if (negative && oct != -1) return false;
    const int v = (oct + 1) * 12 + n;
    if (v < 0 || v > 127) return false;
    midi = v;
    return true;
}

std::string sanitizeFileName(std::string_view name) {
    std::string s;
    for (char c : name) {
        const unsigned char u = static_cast<unsigned char>(c);
        const bool ok = (u < 128 && std::isalnum(u)) || c == '.' || c == '_' || c == '-' || c == '#' || c == '+';
        const char put = ok ? c : '_';
        if (put == '.' && !s.empty() && s.back() == '.') continue;  // no ".."
        s += put;
    }
    while (!s.empty() && (s.front() == '.')) s.erase(s.begin());
    if (s.size() > kMaxNameChars) s.resize(kMaxNameChars);
    while (!s.empty() && s.back() == '.') s.pop_back();
    if (s.empty()) return "sample";
    // Windows device names are reserved with any extension.
    std::string stem = s.substr(0, s.find('.'));
    for (char& c : stem) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    static const char* kReserved[] = {"CON", "PRN", "AUX", "NUL"};
    bool reserved = std::find_if(std::begin(kReserved), std::end(kReserved), [&](const char* r) { return stem == r; }) !=
                    std::end(kReserved);
    if (stem.size() == 4 && (stem.rfind("COM", 0) == 0 || stem.rfind("LPT", 0) == 0) && stem[3] >= '1' && stem[3] <= '9')
        reserved = true;
    if (reserved) s = "_" + s;
    return s;
}

std::string expandNamePattern(std::string_view pattern, std::string_view name, int note, int velocity,
                              std::string_view param, uint32_t index, int roundRobin) {
    std::string s;
    for (std::size_t i = 0; i < pattern.size(); ++i) {
        if (pattern[i] == '{') {
            const std::size_t close = pattern.find('}', i);
            if (close != std::string_view::npos) {
                const std::string_view token = pattern.substr(i + 1, close - i - 1);
                bool known = true;
                if (token == "name") s += name;
                else if (token == "note") s += noteName(note);
                else if (token == "midi") s += std::to_string(note);
                else if (token == "vel") s += std::to_string(velocity);
                else if (token == "param") s += param;
                else if (token == "index") s += std::to_string(index);
                else if (token == "rr") s += roundRobin > 0 ? std::to_string(roundRobin) : std::string();
                else known = false;
                if (known) {
                    i = close;
                    continue;
                }
            }
        }
        s += pattern[i];
    }
    std::string sane = sanitizeFileName(s);
    std::string out;
    for (char c : sane)
        if (!(c == '_' && (out.empty() || out.back() == '_'))) out += c;
    while (!out.empty() && (out.back() == '_' || out.back() == '-')) out.pop_back();
    return out.empty() ? "sample" : sanitizeFileName(out);
}

std::string paramLabel(const std::vector<std::pair<std::string, std::string>>& idValue) {
    std::string s;
    for (const auto& [id, v] : idValue) {
        if (!s.empty()) s += '_';
        s += id;
        s += '-';
        for (char c : v) s += c == '-' ? 'm' : c;
    }
    return s;
}

// ---------------------------------------------------------------- per-file processing

std::size_t trimSilence(std::vector<float>& left, std::vector<float>& right, double thresholdDb, bool start, bool end) {
    const double thr = toLinear(thresholdDb);
    const std::size_t n = left.size();
    auto loud = [&](std::size_t i) { return std::fabs(left[i]) > thr || std::fabs(right[i]) > thr; };
    std::size_t first = 0, last = n;
    if (start)
        while (first < n && !loud(first)) ++first;
    if (end)
        while (last > first && !loud(last - 1)) --last;
    if (first == n && start) last = first;  // all silent
    left.erase(left.begin() + static_cast<std::ptrdiff_t>(last), left.end());
    right.erase(right.begin() + static_cast<std::ptrdiff_t>(last), right.end());
    left.erase(left.begin(), left.begin() + static_cast<std::ptrdiff_t>(first));
    right.erase(right.begin(), right.begin() + static_cast<std::ptrdiff_t>(first));
    return first;
}

void applyFades(std::vector<float>& left, std::vector<float>& right, std::size_t fadeIn, std::size_t fadeOut) {
    const std::size_t n = left.size();
    fadeIn = std::min(fadeIn, n);
    fadeOut = std::min(fadeOut, n);
    for (std::size_t i = 0; i < fadeIn; ++i) {
        const float g = static_cast<float>(static_cast<double>(i) / fadeIn);
        left[i] *= g;
        right[i] *= g;
    }
    for (std::size_t i = 0; i < fadeOut; ++i) {
        const float g = static_cast<float>(static_cast<double>(i) / fadeOut);  // 0 on the last frame
        left[n - 1 - i] *= g;
        right[n - 1 - i] *= g;
    }
}

PackLoop findLoop(const std::vector<float>& left, const std::vector<float>& right, std::size_t earliest,
                  std::size_t endTarget, std::size_t minLength) {
    PackLoop best;
    const std::size_t n = left.size();
    const std::size_t W = kLoopWindow;
    if (n < 4 * W || endTarget + 1 + W > n) return best;
    auto mid = [&](std::size_t i) { return 0.5 * (static_cast<double>(left[i]) + right[i]); };
    auto rising = [&](std::size_t c) { return c > 0 && mid(c - 1) < 0.0 && mid(c) >= 0.0; };
    // The loop end: the frame before a rising crossing, at most a 20 Hz period before endTarget + 1.
    std::size_t ce = 0;
    const std::size_t lookBack = 2400;
    for (std::size_t c = endTarget + 1; c + lookBack > endTarget + 1 && c > W; --c)
        if (rising(c)) {
            ce = c;
            break;
        }
    if (ce == 0 || ce < minLength + W) return best;
    const std::size_t lo = std::max(earliest, W), hi = ce - std::max<std::size_t>(minLength, 1);
    double energy = 0;
    for (std::size_t j = ce - W; j < ce + W; ++j)
        energy += static_cast<double>(left[j]) * left[j] + static_cast<double>(right[j]) * right[j];
    if (energy <= 0) return best;
    double bestScore = 0;
    for (std::size_t s = lo; s <= hi; ++s) {
        if (!rising(s)) continue;
        double score = 0;
        for (std::size_t k = 0; k < 2 * W; ++k) {
            const double dl = static_cast<double>(left[s - W + k]) - left[ce - W + k];
            const double dr = static_cast<double>(right[s - W + k]) - right[ce - W + k];
            score += dl * dl + dr * dr;
        }
        if (!best.found || score < bestScore) {  // ties keep the earlier start: the longer loop
            best.found = true;
            bestScore = score;
            best.start = s;
            best.end = ce - 1;
        }
    }
    if (best.found) best.matchDb = bestScore > 0 ? 10.0 * std::log10(bestScore / energy) : -200.0;
    return best;
}

std::size_t crossfadeLoop(std::vector<float>& left, std::vector<float>& right, const PackLoop& loop, std::size_t frames,
                          bool equalPower) {
    if (!loop.found || loop.end < loop.start || loop.end >= left.size()) return 0;
    const std::size_t length = loop.end - loop.start + 1;
    const std::size_t X = std::min({frames, length, loop.start});
    // Frame k of the fade: the loop's own audio at end - X + 1 + k fades out while the audio that led into the
    // loop's start, at start - X + k, fades in. At the last frame the loop plays what came just before its start,
    // so wrapping to `start` continues the sound as it first ran. Equal power (sin/cos gains, whose squares sum to
    // 1) keeps the level of unrelated material; linear (gains summing to 1) keeps it for material that matches. The
    // audio before the loop is only read: the fade writes inside the loop, which starts after it.
    for (std::size_t k = 0; k < X; ++k) {
        const std::size_t i = loop.end + 1 - X + k, j = loop.start - X + k;
        const double t = static_cast<double>(k + 1) / static_cast<double>(X + 1);
        const double in = equalPower ? detSin(t * kPi / 2.0) : t;
        const double out = equalPower ? detCos(t * kPi / 2.0) : 1.0 - t;
        left[i] = static_cast<float>(left[i] * out + left[j] * in);
        right[i] = static_cast<float>(right[i] * out + right[j] * in);
    }
    return X;
}

// ---------------------------------------------------------------- WAV and SFZ

namespace {
void u16(std::vector<uint8_t>& b, uint32_t v) {
    b.push_back(static_cast<uint8_t>(v));
    b.push_back(static_cast<uint8_t>(v >> 8));
}
void u32(std::vector<uint8_t>& b, uint32_t v) {
    for (int i = 0; i < 4; ++i) b.push_back(static_cast<uint8_t>(v >> (8 * i)));
}
void tag(std::vector<uint8_t>& b, const char* t) { b.insert(b.end(), t, t + 4); }
}  // namespace

std::vector<uint8_t> encodePackWav(const PackWavSpec& spec, const std::vector<float>& left,
                                   const std::vector<float>& right) {
    const bool flt = spec.bitDepth == 32;
    const uint32_t bytesPer = static_cast<uint32_t>(spec.bitDepth / 8);
    const uint32_t ch = static_cast<uint32_t>(spec.channels);
    const uint32_t frames = static_cast<uint32_t>(left.size());
    const uint32_t blockAlign = bytesPer * ch;
    const uint32_t dataBytes = frames * blockAlign;
    std::vector<uint8_t> b;
    b.reserve(128 + dataBytes);
    tag(b, "RIFF");
    u32(b, 0);  // patched below
    tag(b, "WAVE");
    tag(b, "fmt ");
    u32(b, 16);
    u16(b, flt ? 3 : 1);
    u16(b, ch);
    u32(b, static_cast<uint32_t>(spec.sampleRate));
    u32(b, static_cast<uint32_t>(spec.sampleRate) * blockAlign);
    u16(b, blockAlign);
    u16(b, bytesPer * 8);
    if (flt) {
        tag(b, "fact");
        u32(b, 4);
        u32(b, frames);
    }
    const bool loop = spec.loop && spec.loopEnd >= spec.loopStart && spec.loopEnd < frames;
    tag(b, "smpl");
    u32(b, 36 + (loop ? 24 : 0));
    u32(b, 0);                                                                     // manufacturer
    u32(b, 0);                                                                     // product
    u32(b, static_cast<uint32_t>(1000000000.0 / spec.sampleRate + 0.5));           // sample period (ns)
    u32(b, static_cast<uint32_t>(std::clamp(spec.rootNote, 0, 127)));              // unity note
    u32(b, 0);                                                                     // pitch fraction
    u32(b, 0);                                                                     // SMPTE format
    u32(b, 0);                                                                     // SMPTE offset
    u32(b, loop ? 1 : 0);                                                          // loops
    u32(b, 0);                                                                     // sampler data
    if (loop) {
        u32(b, 0);  // cue id
        u32(b, 0);  // forward
        u32(b, spec.loopStart);
        u32(b, spec.loopEnd);  // the last sample played in the loop
        u32(b, 0);  // fraction
        u32(b, 0);  // play forever
    }
    tag(b, "data");
    u32(b, dataBytes);
    // TPDF dither (Lipshitz, Wannamaker and Vanderkooy, "Quantization and Dither: A Theoretical Survey", JAES
    // 40(5), 1992): the difference of two independent uniform values, +-1 LSB triangular, added before rounding,
    // makes the rounding error's first two moments independent of the signal (no distortion, a steady noise floor).
    // Seeded xorshift32 per file, so the same request gives the same bytes. Exact digital silence stays silent.
    const bool dither = !flt && spec.dither == PackDither::Tpdf;
    uint32_t state = spec.ditherSeed * 2654435761u | 1u;
    auto uniform = [&state]() {
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return static_cast<double>(state) / 4294967296.0;
    };
    for (uint32_t i = 0; i < frames; ++i)
        for (uint32_t c = 0; c < ch; ++c) {
            float v = c == 0 ? left[i] : right[i];
            if (!std::isfinite(v)) v = 0.0f;
            if (flt) {
                uint32_t bits;
                std::memcpy(&bits, &v, 4);
                u32(b, bits);
                continue;
            }
            const double d = std::clamp(static_cast<double>(v), -1.0, 1.0);
            const double noise = dither ? uniform() - uniform() : 0.0;  // in LSBs
            const double tpdf = dither && v != 0.0f ? noise : 0.0;
            if (spec.bitDepth == 16) {
                const int32_t s = std::clamp(static_cast<int32_t>(std::floor(d * 32767.0 + tpdf + 0.5)), -32768, 32767);
                u16(b, static_cast<uint32_t>(s) & 0xFFFFu);
            } else {
                const int32_t s = std::clamp(static_cast<int32_t>(std::floor(d * 8388607.0 + tpdf + 0.5)), -8388608, 8388607);
                const uint32_t u = static_cast<uint32_t>(s);
                b.push_back(static_cast<uint8_t>(u));
                b.push_back(static_cast<uint8_t>(u >> 8));
                b.push_back(static_cast<uint8_t>(u >> 16));
            }
        }
    if (dataBytes & 1) b.push_back(0);
    const uint32_t riff = static_cast<uint32_t>(b.size() - 8);
    for (int i = 0; i < 4; ++i) b[4 + i] = static_cast<uint8_t>(riff >> (8 * i));
    return b;
}

std::string sfzText(std::string_view title, const std::vector<SfzRegion>& regions) {
    std::vector<int> notes, vels;
    for (const SfzRegion& r : regions) {
        if (std::find(notes.begin(), notes.end(), r.note) == notes.end()) notes.push_back(r.note);
        if (std::find(vels.begin(), vels.end(), r.velocity) == vels.end()) vels.push_back(r.velocity);
    }
    std::sort(notes.begin(), notes.end());
    std::sort(vels.begin(), vels.end());
    std::string s = "// " + std::string(title) + " (made by C.A.W.)\n";
    std::vector<const SfzRegion*> order;
    for (const SfzRegion& r : regions) order.push_back(&r);
    std::stable_sort(order.begin(), order.end(), [](const SfzRegion* a, const SfzRegion* b) {
        return a->note != b->note ? a->note < b->note : a->velocity != b->velocity ? a->velocity < b->velocity
                                                                                   : a->roundRobin < b->roundRobin;
    });
    for (const SfzRegion* r : order) {
        const std::size_t ni = static_cast<std::size_t>(std::find(notes.begin(), notes.end(), r->note) - notes.begin());
        const std::size_t vi = static_cast<std::size_t>(std::find(vels.begin(), vels.end(), r->velocity) - vels.begin());
        const int lokey = ni == 0 ? 0 : (notes[ni - 1] + notes[ni]) / 2 + 1;
        const int hikey = ni + 1 == notes.size() ? 127 : (notes[ni] + notes[ni + 1]) / 2;
        const int lovel = vi == 0 ? 1 : vels[vi - 1] + 1;
        const int hivel = vi + 1 == vels.size() ? 127 : vels[vi];
        s += "<region> sample=" + r->sample + " lokey=" + std::to_string(lokey) + " hikey=" + std::to_string(hikey) +
             " pitch_keycenter=" + std::to_string(r->note) + " lovel=" + std::to_string(lovel) +
             " hivel=" + std::to_string(hivel);
        if (r->roundRobins > 1)
            s += " seq_length=" + std::to_string(r->roundRobins) + " seq_position=" + std::to_string(r->roundRobin);
        if (r->loop)
            s += " loop_mode=loop_continuous loop_start=" + std::to_string(r->loopStart) +
                 " loop_end=" + std::to_string(r->loopEnd);
        else
            s += " loop_mode=no_loop";
        s += "\n";
    }
    return s;
}

// ---------------------------------------------------------------- request

bool parseSamplePackRequest(std::string_view json, SamplePackRequest& out, std::string& error) {
    Json j;
    if (!parseJson(json, j, error)) return false;
    if (j.type != Json::Type::Object) {
        error = "the request must be a JSON object";
        return false;
    }
    if (!onlyKeys(j, {"instrument", "effects", "output_dir", "name", "name_pattern", "notes", "velocities", "params",
                      "hold_seconds", "max_seconds", "tail_threshold_db", "sample_rate", "block_size", "tempo",
                      "bit_depth", "channels", "trim", "fade_in_ms", "fade_out_ms", "normalize", "loop", "sfz",
                      "manifest", "max_files", "overwrite", "round_robins", "dither"},
                  "the request", error))
        return false;
    SamplePackRequest r;
    const Json* inst = j.get("instrument");
    if (!inst) {
        error = "the request needs an 'instrument'";
        return false;
    }
    if (!parseComponent(*inst, r.instrument, "instrument", error)) return false;
    if (const Json* fx = j.get("effects")) {
        if (fx->type != Json::Type::Array || fx->arr.size() > kMaxEffects) {
            error = "'effects' must be a list of at most " + std::to_string(kMaxEffects) + " components";
            return false;
        }
        for (const Json& e : fx->arr) {
            PackComponent c;
            if (!parseComponent(e, c, "effects", error)) return false;
            r.effects.push_back(std::move(c));
        }
    }
    if (!text(j, "output_dir", r.outputDir, error) || !text(j, "name", r.name, error) ||
        !text(j, "name_pattern", r.namePattern, error))
        return false;
    if (r.outputDir.empty()) {
        error = "the request needs an 'output_dir'";
        return false;
    }
    if (r.namePattern.empty() || r.namePattern.size() > 256) {
        error = "'name_pattern' must be 1 to 256 characters";
        return false;
    }
    if (const Json* v = j.get("notes"); v && !parseNotes(*v, r.notes, error)) return false;
    if (const Json* v = j.get("velocities"); v && !parseVelocities(*v, r.velocities, error)) return false;
    if (const Json* p = j.get("params")) {
        if (p->type != Json::Type::Array || p->arr.size() > kMaxAxes) {
            error = "'params' must be a list of at most " + std::to_string(kMaxAxes) + " parameter steps";
            return false;
        }
        for (const Json& a : p->arr) {
            PackParamAxis axis;
            if (!parseAxis(a, axis, r.effects.size(), error)) return false;
            for (const PackParamAxis& other : r.params)
                if (other.id == axis.id && other.effect == axis.effect) {
                    error = "param '" + axis.id + "' is stepped twice";
                    return false;
                }
            r.params.push_back(std::move(axis));
        }
    }
    double block = r.blockSize, bits = r.bitDepth, ch = r.channels, maxFiles = r.maxFiles;
    if (!number(j, "hold_seconds", r.holdSeconds, 0.001, kMaxFileSeconds, error) ||
        !number(j, "max_seconds", r.maxSeconds, 0.01, kMaxFileSeconds, error) ||
        !number(j, "tail_threshold_db", r.tailThresholdDb, -200, 0, error) ||
        !number(j, "sample_rate", r.sampleRate, 8000, 192000, error) || !number(j, "block_size", block, 1, 8192, error) ||
        !number(j, "tempo", r.tempo, 20, 999, error) || !number(j, "bit_depth", bits, 16, 32, error) ||
        !number(j, "channels", ch, 1, 2, error) || !number(j, "fade_in_ms", r.fadeInMs, 0, 10000, error) ||
        !number(j, "fade_out_ms", r.fadeOutMs, 0, 10000, error) ||
        !number(j, "max_files", maxFiles, 1, kMaxFilesCap, error) || !flag(j, "sfz", r.sfz, error) ||
        !flag(j, "manifest", r.manifest, error) || !flag(j, "overwrite", r.overwrite, error))
        return false;
    if (block != std::floor(block) || ch != std::floor(ch) || maxFiles != std::floor(maxFiles) ||
        r.sampleRate != std::floor(r.sampleRate)) {
        error = "'block_size', 'channels', 'max_files' and 'sample_rate' must be whole numbers";
        return false;
    }
    if (bits != 16 && bits != 24 && bits != 32) {
        error = "'bit_depth' must be 16, 24 (PCM) or 32 (float)";
        return false;
    }
    r.blockSize = static_cast<uint32_t>(block);
    r.bitDepth = static_cast<int>(bits);
    r.channels = static_cast<int>(ch);
    r.maxFiles = static_cast<uint32_t>(maxFiles);
    if (!j.get("max_seconds")) r.maxSeconds = std::min(kMaxFileSeconds, std::max(r.maxSeconds, r.holdSeconds + 5.0));
    if (r.maxSeconds < r.holdSeconds) {
        error = "'max_seconds' must be at least 'hold_seconds'";
        return false;
    }
    if (const Json* t = j.get("trim")) {
        if (t->type == Json::Type::Bool) {
            r.trimStart = r.trimEnd = t->b;
        } else if (t->type == Json::Type::Object) {
            if (!onlyKeys(*t, {"start", "end", "threshold_db"}, "trim", error) || !flag(*t, "start", r.trimStart, error) ||
                !flag(*t, "end", r.trimEnd, error) || !number(*t, "threshold_db", r.trimThresholdDb, -200, 0, error))
                return false;
        } else {
            error = "'trim' must be true, false or {\"start\", \"end\", \"threshold_db\"}";
            return false;
        }
    }
    if (const Json* nm = j.get("normalize")) {
        std::string mode = "none", scope = "file";
        bool targetSet = false;
        if (nm->type == Json::Type::String) {
            mode = nm->str;
        } else if (nm->type == Json::Type::Object) {
            if (!onlyKeys(*nm, {"mode", "target_db", "scope"}, "normalize", error) || !text(*nm, "mode", mode, error) ||
                !text(*nm, "scope", scope, error) || !number(*nm, "target_db", r.normalizeTargetDb, -100, 0, error))
                return false;
            targetSet = nm->get("target_db") != nullptr;
        } else {
            error = "'normalize' must be \"none\", \"peak\", \"rms\" or {\"mode\", \"target_db\", \"scope\"}";
            return false;
        }
        if (mode == "none") r.normalize = PackNormalize::None;
        else if (mode == "peak") r.normalize = PackNormalize::Peak;
        else if (mode == "rms") r.normalize = PackNormalize::Rms;
        else {
            error = "normalize 'mode' must be none, peak or rms";
            return false;
        }
        if (!targetSet) r.normalizeTargetDb = r.normalize == PackNormalize::Rms ? -18.0 : -1.0;
        if (scope != "file" && scope != "group") {
            error = "normalize 'scope' must be file or group";
            return false;
        }
        r.normalizeGroup = scope == "group";
    }
    if (const Json* l = j.get("loop")) {
        if (l->type == Json::Type::Bool) {
            r.loop = l->b;
        } else if (l->type == Json::Type::Object) {
            r.loop = true;
            std::string shape = "equal_power";
            if (!onlyKeys(*l, {"enabled", "min_seconds", "max_seconds", "crossfade_ms", "crossfade"}, "loop", error) ||
                !flag(*l, "enabled", r.loop, error) ||
                !number(*l, "min_seconds", r.loopMinSeconds, 0.001, kMaxFileSeconds, error) ||
                !number(*l, "max_seconds", r.loopMaxSeconds, 0.001, kMaxFileSeconds, error) ||
                !number(*l, "crossfade_ms", r.loopCrossfadeMs, 0, 10000, error) || !text(*l, "crossfade", shape, error))
                return false;
            if (shape != "equal_power" && shape != "linear") {
                error = "loop 'crossfade' must be equal_power or linear";
                return false;
            }
            r.loopCrossfadeEqualPower = shape == "equal_power";
        } else {
            error = "'loop' must be true, false or {\"enabled\", \"min_seconds\", \"max_seconds\"}";
            return false;
        }
    }
    if (const Json* rr = j.get("round_robins")) {
        double count = r.roundRobins;
        if (rr->type == Json::Type::Number) {
            if (!number(j, "round_robins", count, 1, kMaxRoundRobins, error)) return false;
        } else if (rr->type == Json::Type::Object) {
            if (!onlyKeys(*rr, {"count", "preroll_ms", "vary"}, "round_robins", error) ||
                !number(*rr, "count", count, 1, kMaxRoundRobins, error) ||
                !number(*rr, "preroll_ms", r.roundRobinPrerollMs, 0, 1000, error))
                return false;
            if (const Json* v = rr->get("vary")) {
                if (v->type != Json::Type::Array || v->arr.size() > kMaxAxes) {
                    error = "round_robins 'vary' must be a list of at most " + std::to_string(kMaxAxes) + " parameters";
                    return false;
                }
                for (const Json& e : v->arr) {
                    PackVary pv;
                    double effect = -1;
                    if (e.type != Json::Type::Object || !onlyKeys(e, {"id", "effect", "amount"}, "vary", error) ||
                        !text(e, "id", pv.id, error) || !number(e, "effect", effect, 0, kMaxEffects - 1, error) ||
                        !number(e, "amount", pv.amount, 0, 1e9, error)) {
                        if (error.empty()) error = "each 'vary' entry must be {\"id\", \"effect\", \"amount\"}";
                        return false;
                    }
                    if (pv.id.empty() || !e.get("amount")) {
                        error = "each 'vary' entry needs an 'id' and an 'amount'";
                        return false;
                    }
                    if (e.get("effect")) {
                        if (effect != std::floor(effect) || effect >= static_cast<double>(r.effects.size())) {
                            error = "vary 'effect' must index 'effects'";
                            return false;
                        }
                        pv.effect = static_cast<int>(effect);
                    }
                    r.roundRobinVary.push_back(std::move(pv));
                }
            }
        } else {
            error = "'round_robins' must be a count or {\"count\", \"preroll_ms\", \"vary\"}";
            return false;
        }
        if (count != std::floor(count)) {
            error = "'round_robins' must be a whole number";
            return false;
        }
        r.roundRobins = static_cast<int>(count);
    }
    if (const Json* d = j.get("dither")) {
        if (d->type != Json::Type::String || (d->str != "none" && d->str != "tpdf")) {
            error = "'dither' must be \"none\" or \"tpdf\"";
            return false;
        }
        r.dither = d->str == "tpdf" ? PackDither::Tpdf : PackDither::None;
    }
    // A retired synth (2026-11-10, one synth) renders as Flagship with its preset; steps on its old knobs move
    // the Flagship knob they map to, and a step on one that maps to none is refused.
    if (r.instrument.library.empty() && isLegacyInstrument(r.instrument.id)) {
        const std::string legacy = r.instrument.id;
        migrateLegacyInstrument(r.instrument.id, r.instrument.params);
        for (PackParamAxis& axis : r.params) {
            if (axis.effect >= 0) continue;
            const std::string to = migratedLegacyParameter(legacy, axis.id);
            if (to.empty()) {
                error = "'" + legacy + "' now plays as a Flagship preset, which has no knob for '" + axis.id + "'";
                return false;
            }
            axis.id = to;
        }
        for (PackVary& v : r.roundRobinVary) {
            if (v.effect >= 0) continue;
            const std::string to = migratedLegacyParameter(legacy, v.id);
            if (to.empty()) {
                error = "'" + legacy + "' now plays as a Flagship preset, which has no knob for '" + v.id + "'";
                return false;
            }
            v.id = to;
        }
    }
    out = std::move(r);
    return true;
}

// ---------------------------------------------------------------- rendering

namespace {

bool isStereoEffect(const ModuleDescriptor& d) noexcept {
    if (d.portCount != 2 || !d.ports) return false;
    const PortDescriptor& in = d.ports[0];
    const PortDescriptor& out = d.ports[1];
    return in.type == PortType::Audio && in.input && portChannelCount(in) == 2 && out.type == PortType::Audio &&
           !out.input && portChannelCount(out) == 2;
}

uint32_t paramIndex(const ModuleDescriptor& d, std::string_view id) {
    uint32_t k = 0;
    while (k < d.parameterCount && d.parameters[k].id != id) ++k;
    return k;
}

// The value as it names a file: a choice by its label, a number compactly.
std::string valueText(const ParameterDescriptor& p, double v) {
    if (p.choiceCount > 0) {
        const long idx = std::lround(v - p.minimum);
        if (idx >= 0 && static_cast<uint32_t>(idx) < p.choiceCount) return std::string(p.choices[idx]);
    }
    return fmt(v, "%.6g");
}

struct Stage {
    std::unique_ptr<ModuleProcessor> processor;
    std::vector<ParameterValue> values;
};

struct Cell {
    int note = 60, velocity = 100;
    std::vector<double> axisValues;  // constrained, one per axis
    std::string paramText;           // the {param} expansion
    std::size_t combo = 0;           // index of the parameter combination
    int rr = 0;                      // round robin take, from 0
    std::string file;                // with .wav
};

// A deterministic value in [-1, 1] for a round robin's variation (0 for the first take, so a pack of one take per
// cell renders as without round robins).
double varyAmount(const Cell& c, std::size_t entry) {
    if (c.rr == 0) return 0.0;
    uint32_t h = 2166136261u;
    for (uint32_t v : {static_cast<uint32_t>(c.note), static_cast<uint32_t>(c.velocity), static_cast<uint32_t>(c.combo),
                       static_cast<uint32_t>(c.rr), static_cast<uint32_t>(entry)})
        for (int k = 0; k < 4; ++k) h = (h ^ ((v >> (8 * k)) & 255u)) * 16777619u;
    h ^= h >> 15;
    h *= 0x2c1b3c6du;
    h ^= h >> 12;
    return static_cast<double>(h) / 2147483647.5 - 1.0;
}

struct Rendered {
    std::vector<float> left, right;
    std::size_t offFrame = 0, latency = 0, trimmed = 0;
    bool truncated = false;
    uint64_t failedBlocks = 0;
};

class PackRenderer {
public:
    PackRenderer(const SamplePackRequest& r, const ModuleRegistry& reg) : req_(r), reg_(reg) {}

    // One cell: fresh instances, a note on held for the hold, then off; until quiet (or the most frames).
    bool render(const Cell& cell, Rendered& out, int32_t* cancel, std::string& error) {
        std::vector<Stage> stages;
        std::vector<const PackComponent*> comps{&req_.instrument};
        for (const PackComponent& e : req_.effects) comps.push_back(&e);
        out.latency = 0;
        for (std::size_t s = 0; s < comps.size(); ++s) {
            Stage st;
            st.processor = reg_.create(comps[s]->id);
            if (!st.processor) {
                error = "component '" + comps[s]->id + "' could not create an instance";
                return false;
            }
            const ModuleDescriptor& d = st.processor->descriptor();
            st.values.resize(d.parameterCount);
            for (uint32_t k = 0; k < d.parameterCount; ++k)
                st.values[k].value = constrainParameter(d.parameters[k], d.parameters[k].defaultValue);
            for (const auto& [id, v] : comps[s]->params) {
                const uint32_t k = paramIndex(d, id);
                if (k == d.parameterCount) {
                    error = "component '" + comps[s]->id + "' has no parameter '" + id + "'";
                    return false;
                }
                st.values[k].value = constrainParameter(d.parameters[k], v);
            }
            for (std::size_t a = 0; a < req_.params.size(); ++a)
                if (req_.params[a].effect + 1 == static_cast<int>(s)) {
                    const uint32_t k = paramIndex(d, req_.params[a].id);
                    if (k == d.parameterCount) {
                        error = "component '" + comps[s]->id + "' has no parameter '" + req_.params[a].id + "'";
                        return false;
                    }
                    st.values[k].value = cell.axisValues[a];
                }
            for (std::size_t v = 0; v < req_.roundRobinVary.size(); ++v)
                if (req_.roundRobinVary[v].effect + 1 == static_cast<int>(s)) {
                    const PackVary& pv = req_.roundRobinVary[v];
                    const uint32_t k = paramIndex(d, pv.id);
                    if (k == d.parameterCount) {
                        error = "component '" + comps[s]->id + "' has no parameter '" + pv.id + "' to vary";
                        return false;
                    }
                    st.values[k].value =
                        constrainParameter(d.parameters[k], st.values[k].value + pv.amount * varyAmount(cell, v));
                }
            if (s == 0 && !st.processor->usesProcessPorts()) {
                error = "instrument '" + comps[s]->id + "' does not take note events (processPorts)";
                return false;
            }
            if (!st.processor->activate(req_.sampleRate, req_.blockSize)) {
                error = "component '" + comps[s]->id + "' refused to activate at " +
                        std::to_string(static_cast<int>(req_.sampleRate)) + " Hz";
                return false;
            }
            out.latency += d.latencyFrames;
            stages.push_back(std::move(st));
        }
        const std::size_t B = req_.blockSize;
        // A later round robin first runs the chain on silence (its free-running state moves on), then plays.
        const std::size_t pre = static_cast<std::size_t>(
            std::llround(static_cast<double>(cell.rr) * req_.roundRobinPrerollMs * 0.001 * req_.sampleRate));
        const std::size_t maxFrames = static_cast<std::size_t>(std::llround(req_.maxSeconds * req_.sampleRate));
        const std::size_t off = std::max<std::size_t>(1, static_cast<std::size_t>(std::llround(req_.holdSeconds * req_.sampleRate)));
        const std::size_t quietNeed = static_cast<std::size_t>(std::llround(kQuietSeconds * req_.sampleRate));
        const double thr = toLinear(req_.tailThresholdDb);
        out.offFrame = off;
        out.left.clear();
        out.right.clear();
        out.left.reserve(std::min<std::size_t>(maxFrames, off + 2 * quietNeed + out.latency));
        out.right.reserve(out.left.capacity());
        out.truncated = true;
        out.failedBlocks = 0;
        std::vector<float> L(B), R(B), sL(B), sR(B);
        Transport transport;
        transport.tempo = req_.tempo;
        transport.playing = true;
        const uint32_t noteId = 1;
        const uint8_t key = static_cast<uint8_t>(cell.note);
        std::size_t quiet = 0, lastLoud = 0;
        bool anyLoud = false;
        bool aborted = false;
        // One block of the chain: the instrument with `events`, then each effect.
        auto runBlock = [&](uint32_t m, const Event* events, uint32_t count) {
            std::fill_n(L.data(), m, 0.0f);
            std::fill_n(R.data(), m, 0.0f);
            for (std::size_t s = 0; s < stages.size(); ++s) {
                Stage& st = stages[s];
                const uint32_t pc = static_cast<uint32_t>(st.values.size());
                std::copy_n(L.data(), m, sL.data());
                std::copy_n(R.data(), m, sR.data());
                float* o[2] = {L.data(), R.data()};
                bool ok;
                if (s == 0) {
                    const ChannelBufferView audioOut{o, 2, m};
                    const EventInput in{events, count};
                    ProcessBlock ports;
                    ports.frames = m;
                    ports.sampleRate = req_.sampleRate;
                    ports.audioOut = &audioOut;
                    ports.audioOutCount = 1;
                    ports.eventIn = &in;
                    ports.eventInCount = 1;
                    ports.parameters = pc ? st.values.data() : nullptr;
                    ports.parameterCount = pc;
                    ports.transport = &transport;
                    ok = st.processor->processPorts(ports);
                } else {
                    const float* in[2] = {sL.data(), sR.data()};
                    AudioProcessBlock block;
                    block.input = {in, 2, m};
                    block.output = {o, 2, m};
                    block.frames = m;
                    block.sampleRate = req_.sampleRate;
                    block.parameters = pc ? st.values.data() : nullptr;
                    block.parameterCount = pc;
                    block.transport = &transport;
                    ok = st.processor->process(block);
                }
                if (!ok) {  // as in the app: a failed instrument is silent, a failed effect passes its input
                    ++out.failedBlocks;
                    std::copy_n(sL.data(), m, L.data());
                    std::copy_n(sR.data(), m, R.data());
                }
                for (uint32_t i = 0; i < m; ++i) {
                    if (!std::isfinite(L[i])) L[i] = 0.0f;
                    if (!std::isfinite(R[i])) R[i] = 0.0f;
                }
            }
        };
        for (std::size_t done = 0; done < pre;) {  // a round robin's pre-roll: silence, nothing kept
            const uint32_t m = static_cast<uint32_t>(std::min(B, pre - done));
            transport.beat = 0.0;
            runBlock(m, nullptr, 0);
            done += m;
        }
        for (std::size_t at = 0; at < maxFrames; at += B) {
            if (cancelled(cancel)) {
                error = "cancelled";
                aborted = true;
                break;
            }
            const uint32_t m = static_cast<uint32_t>(std::min(B, maxFrames - at));
            Event events[2];
            uint32_t count = 0;
            if (at == 0) events[count++] = notes::noteOn(0, noteId, cell.note, cell.velocity / 127.0);
            if (off >= at && off < at + m) events[count++] = notes::noteOff(static_cast<uint32_t>(off - at), noteId, key);
            transport.beat = static_cast<double>(at) / req_.sampleRate * req_.tempo / 60.0;
            runBlock(m, events, count);
            for (uint32_t i = 0; i < m; ++i) {
                out.left.push_back(L[i]);
                out.right.push_back(R[i]);
                if (std::fabs(L[i]) > thr || std::fabs(R[i]) > thr) {
                    quiet = 0;
                    lastLoud = at + i;
                    anyLoud = true;
                } else {
                    ++quiet;
                }
            }
            if (at + m >= off + out.latency && quiet >= quietNeed) {
                out.truncated = false;
                break;
            }
        }
        for (Stage& st : stages) st.processor->deactivate();
        if (aborted) return false;
        // The render ends where the tail fell below the threshold (the note's own length at least, if it sounded).
        const std::size_t keep = anyLoud ? std::max(lastLoud + 1, std::min(off, out.left.size())) : out.left.size();
        if (!out.truncated) {
            out.left.resize(keep);
            out.right.resize(keep);
        }
        return true;
    }

private:
    const SamplePackRequest& req_;
    const ModuleRegistry& reg_;
};

struct Measured {
    double peak = 0, rms = 0;
};
Measured measure(const std::vector<float>& l, const std::vector<float>& r, int channels) {
    Measured m;
    double sum = 0;
    for (std::size_t i = 0; i < l.size(); ++i) {
        m.peak = std::max(m.peak, static_cast<double>(std::fabs(l[i])));
        sum += static_cast<double>(l[i]) * l[i];
        if (channels == 2) {
            m.peak = std::max(m.peak, static_cast<double>(std::fabs(r[i])));
            sum += static_cast<double>(r[i]) * r[i];
        }
    }
    const double n = static_cast<double>(l.size()) * channels;
    m.rms = n > 0 ? std::sqrt(sum / n) : 0.0;
    return m;
}

uint64_t fnv1a(const std::vector<uint8_t>& b) {
    uint64_t h = 1469598103934665603ull;
    for (uint8_t c : b) h = (h ^ c) * 1099511628211ull;
    return h;
}

std::string hex64(uint64_t v) {
    char buf[20];
    std::snprintf(buf, sizeof buf, "%016llx", static_cast<unsigned long long>(v));
    return buf;
}

// The path for `name` inside `dir` (already canonical): a plain name, never a symlink or a non-file, and an
// existing file only with overwrite.
bool targetPath(const fs::path& dir, const std::string& name, bool overwrite, fs::path& out, std::string& error) {
    if (name.empty() || name != sanitizeFileName(name) || name.find('/') != std::string::npos ||
        name.find('\\') != std::string::npos || name.find("..") != std::string::npos) {
        error = "'" + name + "' is not a plain file name";
        return false;
    }
    const fs::path p = dir / utf8Path(name);
    if (p.parent_path() != dir || p.filename() != utf8Path(name)) {
        error = "'" + name + "' would be outside the output directory";
        return false;
    }
    std::error_code ec;
    const fs::file_status st = fs::symlink_status(p, ec);
    if (fs::is_symlink(st)) {
        error = "'" + name + "' in the output directory is a symbolic link; refusing to write through it";
        return false;
    }
    if (fs::exists(st)) {
        if (!fs::is_regular_file(st)) {
            error = "'" + name + "' in the output directory is not a regular file";
            return false;
        }
        if (!overwrite) {
            error = "'" + name + "' already exists in the output directory (set 'overwrite' to replace it)";
            return false;
        }
    }
    out = p;
    return true;
}

// Writes through `<name>.part` and renames it over the target, so a failure never leaves a half-written file.
bool writeInside(const fs::path& dir, const std::string& name, const std::string& bytes, bool overwrite,
                 std::string& error) {
    fs::path target, part;
    if (!targetPath(dir, name, overwrite, target, error)) return false;
    if (!targetPath(dir, name + ".part", true, part, error)) return false;
    {
        std::ofstream f(part, std::ios::binary | std::ios::trunc);
        if (!f) {
            error = "can't write '" + name + "' in the output directory";
            return false;
        }
        f.write(bytes.data(), static_cast<std::streamsize>(bytes.size()));
        f.close();
        if (!f) {
            std::error_code ec;
            fs::remove(part, ec);
            error = "couldn't write all of '" + name + "'";
            return false;
        }
    }
    std::error_code ec;
    fs::rename(part, target, ec);
    if (ec) {
        fs::remove(target, ec);  // Windows: rename doesn't replace
        ec.clear();
        fs::rename(part, target, ec);
    }
    if (ec) {
        fs::remove(part, ec);
        error = "couldn't move '" + name + ".part' to '" + name + "'";
        return false;
    }
    return true;
}

}  // namespace

std::string renderSamplePack(const SamplePackRequest& req, NativeModuleTrust trust, int32_t* progress,
                             int32_t* cancel) try {
    std::string error;
    setProgress(progress, 0);
    // Components: built-ins, then each library once with the caller's trust.
    ModuleRegistry registry;
    registerBuiltinComponents(registry);
    std::map<std::string, std::string> loadedFrom;
    std::vector<const PackComponent*> comps{&req.instrument};
    for (const PackComponent& e : req.effects) comps.push_back(&e);
    for (const PackComponent* c : comps) {
        if (c->library.empty()) {
            if (!registry.find(c->id)) return failure("component '" + c->id + "' is not built in; give its 'library'");
            continue;
        }
        if (const auto it = loadedFrom.find(c->id); it != loadedFrom.end()) {
            if (it->second != c->library) return failure("component '" + c->id + "' is named from two libraries");
            continue;
        }
        if (registry.find(c->id)) return failure("component '" + c->id + "' is built in; leave out its 'library'");
        if (trust != NativeModuleTrust::Trusted)
            return failure("component '" + c->id + "' is in a library: it loads only with trust 'trusted' (given: " +
                           (trust == NativeModuleTrust::Blocked ? "blocked" : "isolated") + ")");
        const ModuleLoadResult r = registry.loadSharedLibrary(c->library, c->id, trust);
        if (!r.success) return failure("can't load '" + c->id + "' from '" + c->library + "': " + r.message);
        loadedFrom[c->id] = c->library;
    }
    const ModuleDescriptor* inst = registry.find(req.instrument.id);
    if (!ComponentChain::isInstrument(*inst))
        return failure("'" + req.instrument.id + "' is not an instrument (one event input, one stereo audio output)");
    std::vector<const ModuleDescriptor*> descs{inst};
    for (const PackComponent& e : req.effects) {
        const ModuleDescriptor* d = registry.find(e.id);
        if (!isStereoEffect(*d))
            return failure("effect '" + e.id + "' must have one stereo audio input and one stereo audio output");
        descs.push_back(d);
    }
    for (std::size_t s = 0; s < comps.size(); ++s)
        for (const auto& [id, v] : comps[s]->params)
            if (paramIndex(*descs[s], id) == descs[s]->parameterCount)
                return failure("component '" + comps[s]->id + "' has no parameter '" + id + "'");
    // The grid: parameter combinations (the first axis slowest), then notes, then velocities.
    std::vector<const ParameterDescriptor*> axisDesc;
    for (const PackParamAxis& a : req.params) {
        const ModuleDescriptor& d = *descs[static_cast<std::size_t>(a.effect + 1)];
        const uint32_t k = paramIndex(d, a.id);
        if (k == d.parameterCount) return failure("component '" + std::string(d.id) + "' has no parameter '" + a.id + "'");
        axisDesc.push_back(&d.parameters[k]);
    }
    uint64_t combos = 1;
    for (const PackParamAxis& a : req.params) combos *= a.values.size();
    const uint64_t total = combos * req.notes.size() * req.velocities.size() * static_cast<uint64_t>(req.roundRobins);
    if (total > req.maxFiles)
        return failure("the pack would be " + std::to_string(total) + " files, more than 'max_files' (" +
                       std::to_string(req.maxFiles) + ")");
    // Output directory: created if missing, then canonical; every file goes directly inside it.
    std::error_code ec;
    const fs::path dirIn = utf8Path(req.outputDir);
    if (!fs::exists(dirIn, ec)) fs::create_directories(dirIn, ec);
    if (!fs::is_directory(dirIn, ec)) return failure("the output directory '" + req.outputDir + "' is not a directory");
    const fs::path dir = fs::canonical(dirIn, ec);
    if (ec) return failure("can't resolve the output directory '" + req.outputDir + "'");

    const std::string packName = sanitizeFileName(req.name);
    // Round robins need their take in the name: added at the end when the pattern doesn't place it.
    std::string pattern = req.namePattern;
    if (req.roundRobins > 1 && pattern.find("{rr}") == std::string::npos && pattern.find("{index}") == std::string::npos)
        pattern += "_rr{rr}";
    for (const PackVary& v : req.roundRobinVary) {
        const ModuleDescriptor& d = *descs[static_cast<std::size_t>(v.effect + 1)];
        if (paramIndex(d, v.id) == d.parameterCount)
            return failure("component '" + std::string(d.id) + "' has no parameter '" + v.id + "' to vary");
    }
    std::vector<Cell> cells;
    std::vector<std::string> comboText;
    for (uint64_t c = 0; c < combos; ++c) {
        std::vector<double> values;
        std::vector<std::pair<std::string, std::string>> label;
        uint64_t rest = c;
        std::vector<std::size_t> idx(req.params.size());
        for (std::size_t a = req.params.size(); a-- > 0;) {
            idx[a] = static_cast<std::size_t>(rest % req.params[a].values.size());
            rest /= req.params[a].values.size();
        }
        for (std::size_t a = 0; a < req.params.size(); ++a) {
            const double v = constrainParameter(*axisDesc[a], req.params[a].values[idx[a]]);
            values.push_back(v);
            label.emplace_back(req.params[a].id, valueText(*axisDesc[a], v));
        }
        const std::string ptext = sanitizeFileName(paramLabel(label));
        comboText.push_back(req.params.empty() ? "" : ptext);
        for (int note : req.notes)
            for (int vel : req.velocities)
                for (int rr = 0; rr < req.roundRobins; ++rr) {
                    Cell cell;
                    cell.note = note;
                    cell.velocity = vel;
                    cell.axisValues = values;
                    cell.paramText = comboText.back();
                    cell.combo = static_cast<std::size_t>(c);
                    cell.rr = rr;
                    cell.file = expandNamePattern(pattern, packName, note, vel, cell.paramText,
                                                  static_cast<uint32_t>(cells.size()), req.roundRobins > 1 ? rr + 1 : 0) +
                                ".wav";
                    cells.push_back(std::move(cell));
                }
    }
    // Names: unique (case-insensitively, for Windows and Android storage) and writable before anything renders.
    std::map<std::string, std::size_t> seen;
    auto lower = [](std::string s) {
        for (char& ch : s) ch = static_cast<char>(std::tolower(static_cast<unsigned char>(ch)));
        return s;
    };
    for (std::size_t i = 0; i < cells.size(); ++i) {
        const auto [it, fresh] = seen.emplace(lower(cells[i].file), i);
        if (!fresh)
            return failure("two samples would both be named '" + cells[i].file +
                           "': put {note}, {vel} and {param} (or {index}), and {rr} with round robins, in 'name_pattern'");
        fs::path p;
        if (!targetPath(dir, cells[i].file, req.overwrite, p, error)) return failure(error);
    }
    std::vector<std::string> sfzFiles;
    if (req.sfz)
        for (uint64_t c = 0; c < combos; ++c)
            sfzFiles.push_back(sanitizeFileName(combos == 1 ? packName : packName + "_" + comboText[c]) + ".sfz");
    const std::string manifestFile = packName + ".json";
    for (const std::string& f : sfzFiles) {
        fs::path p;
        if (seen.count(lower(f))) return failure("'" + f + "' is named twice");
        seen.emplace(lower(f), 0);
        if (!targetPath(dir, f, req.overwrite, p, error)) return failure(error);
    }
    if (req.manifest) {
        fs::path p;
        if (seen.count(lower(manifestFile))) return failure("'" + manifestFile + "' is named twice");
        if (!targetPath(dir, manifestFile, req.overwrite, p, error)) return failure(error);
    }

    PackRenderer renderer(req, registry);
    const double sr = req.sampleRate;
    const std::size_t fadeIn = static_cast<std::size_t>(std::llround(req.fadeInMs * sr / 1000.0));
    const std::size_t fadeOut = static_cast<std::size_t>(std::llround(req.fadeOutMs * sr / 1000.0));
    const double passes = req.normalize != PackNormalize::None && req.normalizeGroup ? 2.0 : 1.0;
    std::vector<std::string> warnings;
    auto warnOnce = [&](const char* w) {
        if (std::find(warnings.begin(), warnings.end(), w) == warnings.end()) warnings.push_back(w);
    };

    // Everything a file gets before gain: render, mono, loop search, trim, fades.
    struct Prepared {
        Rendered r;
        PackLoop loop;
        std::size_t crossfade = 0;
        std::vector<std::string> warnings;
    };
    auto prepare = [&](const Cell& cell, Prepared& p) -> bool {
        if (!renderer.render(cell, p.r, cancel, error)) return false;
        p.warnings.clear();
        if (p.r.truncated) p.warnings.push_back("tail_truncated");
        if (p.r.failedBlocks) p.warnings.push_back("failed_blocks");
        if (req.channels == 1)
            for (std::size_t i = 0; i < p.r.left.size(); ++i) p.r.left[i] = p.r.right[i] = 0.5f * (p.r.left[i] + p.r.right[i]);
        p.loop = PackLoop{};
        if (req.loop) {
            // In the held part, as heard (after the chain's latency), ending a little before the note off.
            const std::size_t L = p.r.latency, off = p.r.offFrame;
            const std::size_t guard = std::min<std::size_t>(static_cast<std::size_t>(0.02 * sr), off / 10);
            const std::size_t endTarget = L + off > guard + 1 ? L + off - guard - 1 : 0;
            const double maxLen = req.loopMaxSeconds > 0 ? req.loopMaxSeconds * sr : 0.5 * off;
            const std::size_t minLen = std::max<std::size_t>(16, static_cast<std::size_t>(req.loopMinSeconds * sr));
            const std::size_t span = static_cast<std::size_t>(std::max(maxLen, static_cast<double>(minLen)));
            const std::size_t earliest = std::max(L, endTarget > span ? endTarget - span : 0);
            if (endTarget > earliest + minLen) p.loop = findLoop(p.r.left, p.r.right, earliest, endTarget, minLen);
            if (!p.loop.found) p.warnings.push_back("no_loop_found");
        }
        p.r.trimmed = trimSilence(p.r.left, p.r.right, req.trimThresholdDb, req.trimStart, req.trimEnd);
        if (p.loop.found) {
            if (p.loop.start < p.r.trimmed || p.loop.end - p.r.trimmed >= p.r.left.size()) {
                p.loop.found = false;
                p.warnings.push_back("no_loop_found");
            } else {
                p.loop.start -= p.r.trimmed;
                p.loop.end -= p.r.trimmed;
            }
        }
        p.crossfade = 0;
        if (p.loop.found && req.loopCrossfadeMs > 0) {
            const std::size_t want = static_cast<std::size_t>(std::llround(req.loopCrossfadeMs * sr / 1000.0));
            p.crossfade = crossfadeLoop(p.r.left, p.r.right, p.loop, want, req.loopCrossfadeEqualPower);
            if (p.crossfade < want) p.warnings.push_back("loop_crossfade_shortened");
        }
        std::size_t fi = fadeIn, fo = fadeOut;
        if (p.loop.found) {  // fades stay outside the loop
            fi = std::min(fi, p.loop.start);
            fo = std::min(fo, p.r.left.size() - 1 - p.loop.end);
        }
        applyFades(p.r.left, p.r.right, fi, fo);
        if (p.r.left.empty()) p.warnings.push_back("silent");
        return true;
    };

    // Group normalisation: a measuring pass first, so memory holds one file at a time.
    double groupGain = 1.0;
    bool groupLimited = false;
    if (passes == 2.0) {
        double loudest = 0, peakest = 0;
        for (std::size_t i = 0; i < cells.size(); ++i) {
            Prepared p;
            if (!prepare(cells[i], p)) return failure(error);
            const Measured m = measure(p.r.left, p.r.right, req.channels);
            loudest = std::max(loudest, req.normalize == PackNormalize::Rms ? m.rms : m.peak);
            peakest = std::max(peakest, m.peak);
            setProgress(progress, (i + 1.0) / (cells.size() * passes));
        }
        if (loudest > 0) {
            groupGain = toLinear(req.normalizeTargetDb) / loudest;
            if (req.bitDepth != 32 && peakest * groupGain > 1.0) {
                groupGain = 1.0 / peakest;
                groupLimited = true;
            }
        }
    }

    Out files;
    files.raw("[");
    std::vector<std::vector<SfzRegion>> sfz(static_cast<std::size_t>(combos));
    bool anyLimited = groupLimited, anyClipped = false;
    for (std::size_t i = 0; i < cells.size(); ++i) {
        const Cell& cell = cells[i];
        Prepared p;
        if (!prepare(cell, p)) return failure(error);
        double gain = groupGain;
        if (req.normalize != PackNormalize::None && !req.normalizeGroup) {
            const Measured m = measure(p.r.left, p.r.right, req.channels);
            const double level = req.normalize == PackNormalize::Rms ? m.rms : m.peak;
            gain = level > 0 ? toLinear(req.normalizeTargetDb) / level : 1.0;
            if (req.bitDepth != 32 && m.peak * gain > 1.0) {
                gain = 1.0 / m.peak;
                p.warnings.push_back("normalize_limited_by_peak");
                anyLimited = true;
            }
        }
        if (gain != 1.0)
            for (std::size_t k = 0; k < p.r.left.size(); ++k) {
                p.r.left[k] = static_cast<float>(p.r.left[k] * gain);
                p.r.right[k] = static_cast<float>(p.r.right[k] * gain);
            }
        const Measured m = measure(p.r.left, p.r.right, req.channels);
        if (m.peak > 1.0) {
            p.warnings.push_back(req.bitDepth == 32 ? "over_full_scale" : "clipped");
            anyClipped = true;
        }
        PackWavSpec spec;
        spec.sampleRate = static_cast<int>(sr);
        spec.channels = req.channels;
        spec.bitDepth = req.bitDepth;
        spec.rootNote = cell.note;
        spec.dither = req.bitDepth == 32 ? PackDither::None : req.dither;
        spec.ditherSeed = static_cast<uint32_t>(i + 1);
        spec.loop = p.loop.found;
        spec.loopStart = static_cast<uint32_t>(p.loop.start);
        spec.loopEnd = static_cast<uint32_t>(p.loop.end);
        const std::vector<uint8_t> bytes = encodePackWav(spec, p.r.left, p.r.right);
        if (!writeInside(dir, cell.file, std::string(bytes.begin(), bytes.end()), req.overwrite, error))
            return failure(error);
        for (const std::string& w : p.warnings) warnOnce(w.c_str());
        files.sep();
        files.raw("{");
        files.ks("file", cell.file);
        files.ki("note", cell.note);
        files.ks("note_name", noteName(cell.note));
        files.ki("velocity", cell.velocity);
        if (req.roundRobins > 1) files.ki("round_robin", cell.rr + 1);
        files.key("params");
        files.raw("{");
        for (std::size_t a = 0; a < req.params.size(); ++a) {
            files.key(req.params[a].id.c_str());
            files.num(cell.axisValues[a]);
        }
        files.raw("}");
        if (!req.params.empty()) {
            files.key("param_effects");
            files.raw("[");
            for (const PackParamAxis& a : req.params) {
                files.sep();
                if (a.effect < 0) files.str("instrument");
                else files.raw(std::to_string(a.effect));
            }
            files.raw("]");
        }
        files.ki("frames", static_cast<int64_t>(p.r.left.size()));
        files.kv("seconds", static_cast<double>(p.r.left.size()) / sr);
        files.ki("trimmed_start_frames", static_cast<int64_t>(p.r.trimmed));
        files.kv("peak_db", toDb(m.peak));
        files.kv("rms_db", toDb(m.rms));
        files.kv("gain_db", toDb(gain));
        files.key("loop");
        if (p.loop.found) {
            files.raw("{");
            files.ki("start", static_cast<int64_t>(p.loop.start));
            files.ki("end", static_cast<int64_t>(p.loop.end));
            files.kv("match_db", p.loop.matchDb);
            files.ki("crossfade_frames", static_cast<int64_t>(p.crossfade));
            files.raw("}");
        } else {
            files.raw("null");
        }
        files.kb("tail_truncated", p.r.truncated);
        files.ks("hash", "fnv1a64:" + hex64(fnv1a(bytes)));
        files.key("warnings");
        files.raw("[");
        for (const std::string& w : p.warnings) {
            files.sep();
            files.str(w);
        }
        files.raw("]}");
        if (req.sfz) {
            SfzRegion reg;
            reg.sample = cell.file;
            reg.note = cell.note;
            reg.velocity = cell.velocity;
            reg.roundRobin = cell.rr + 1;
            reg.roundRobins = req.roundRobins;
            reg.loop = p.loop.found;
            reg.loopStart = spec.loopStart;
            reg.loopEnd = spec.loopEnd;
            sfz[cell.combo].push_back(std::move(reg));
        }
        setProgress(progress, (i + 1.0 + (passes - 1.0) * cells.size()) / (cells.size() * passes));
    }
    files.raw("]");
    if (anyLimited) warnOnce("normalize_limited_by_peak");
    (void)anyClipped;
    for (std::size_t c = 0; c < sfzFiles.size(); ++c) {
        const std::string title = packName + (comboText[c].empty() ? "" : " " + comboText[c]);
        if (!writeInside(dir, sfzFiles[c], sfzText(title, sfz[c]), req.overwrite, error)) return failure(error);
    }

    // The manifest (portable: no absolute paths) and the result (the manifest plus where it went).
    Out body;
    body.ki("schema", 1);
    body.ks("name", packName);
    body.key("instrument");
    body.raw("{");
    body.ks("id", req.instrument.id);
    body.ks("source", req.instrument.library.empty() ? "builtin" : "library");
    body.raw("}");
    body.key("effects");
    body.raw("[");
    for (const PackComponent& e : req.effects) {
        body.sep();
        body.raw("{");
        body.ks("id", e.id);
        body.ks("source", e.library.empty() ? "builtin" : "library");
        body.raw("}");
    }
    body.raw("]");
    body.key("settings");
    body.raw("{");
    body.kv("sample_rate", sr);
    body.ki("bit_depth", req.bitDepth);
    body.ki("channels", req.channels);
    body.kv("hold_seconds", req.holdSeconds);
    body.kv("max_seconds", req.maxSeconds);
    body.kv("tail_threshold_db", req.tailThresholdDb);
    body.ki("block_size", req.blockSize);
    body.kv("tempo", req.tempo);
    body.ks("normalize", req.normalize == PackNormalize::None ? "none" : req.normalize == PackNormalize::Peak ? "peak" : "rms");
    if (req.normalize != PackNormalize::None) {
        body.kv("normalize_target_db", req.normalizeTargetDb);
        body.ks("normalize_scope", req.normalizeGroup ? "group" : "file");
    }
    body.kb("loop", req.loop);
    if (req.loop && req.loopCrossfadeMs > 0) {
        body.kv("loop_crossfade_ms", req.loopCrossfadeMs);
        body.ks("loop_crossfade", req.loopCrossfadeEqualPower ? "equal_power" : "linear");
    }
    body.ki("round_robins", req.roundRobins);
    body.ks("dither", req.bitDepth != 32 && req.dither == PackDither::Tpdf ? "tpdf" : "none");
    body.raw("}");
    body.ki("file_count", static_cast<int64_t>(cells.size()));
    body.key("files");
    body.raw(files.s);
    body.key("sfz");
    body.raw("[");
    for (const std::string& f : sfzFiles) {
        body.sep();
        body.str(f);
    }
    body.raw("]");
    if (req.manifest) body.ks("manifest", manifestFile);
    body.key("warnings");
    body.raw("[");
    for (const std::string& w : warnings) {
        body.sep();
        body.str(w);
    }
    body.raw("]");
    if (req.manifest && !writeInside(dir, manifestFile, "{" + body.s + "}\n", req.overwrite, error))
        return failure(error);
    setProgress(progress, 1.0);
    Out result;
    result.raw("{");
    result.kb("ok", true);
    result.ks("error", "");
    result.ks("output_dir", pathText(dir));
    result.raw(",");
    result.raw(body.s);
    result.raw("}");
    return result.s;
} catch (const std::bad_alloc&) {
    return failure("out of memory: the pack is too large for this device");
} catch (...) {
    return failure("the sample pack failed");
}

std::string samplePackJson(std::string_view requestJson, NativeModuleTrust trust, int32_t* progress,
                           int32_t* cancel) try {
    SamplePackRequest req;
    std::string error;
    if (!parseSamplePackRequest(requestJson, req, error)) return failure(error);
    return renderSamplePack(req, trust, progress, cancel);
} catch (...) {
    return failure("the sample pack failed");
}

}  // namespace caw
