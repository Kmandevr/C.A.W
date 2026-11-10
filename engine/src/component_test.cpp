// Offline testing suite for C++ components: test signals in, a component rendered off the audio thread, measurements as JSON.
#include "component_test.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <limits>
#include <memory>
#include <new>

#include "analysis.h"
#include "builtin_components.h"
#include "caw/detmath.hpp"
#include "json.h"
#include "params.h"
#include "wav.h"

namespace caw {

namespace {

constexpr double kMaxRenderSeconds = 120.0;      // signal plus tail, per render
constexpr uint32_t kMaxSweepSteps = 64;
constexpr std::size_t kMaxResponseFrames = 1u << 20;  // frequency response FFT
constexpr std::size_t kMaxLagFrames = 1u << 17;       // latency search window
constexpr double kQuietDb = -90.0;                    // IR length and tail end: below the input's peak by this

// ---------------------------------------------------------------- request parsing

const char* signalName(TestSignalKind k) {
    switch (k) {
        case TestSignalKind::Impulse: return "impulse";
        case TestSignalKind::Sine: return "sine";
        case TestSignalKind::Sweep: return "sweep";
        case TestSignalKind::WhiteNoise: return "white";
        case TestSignalKind::PinkNoise: return "pink";
        case TestSignalKind::Silence: return "silence";
        case TestSignalKind::Dc: return "dc";
        case TestSignalKind::Wav: return "wav";
        case TestSignalKind::Buffer: return "buffer";
    }
    return "sine";
}

bool signalKind(const std::string& s, TestSignalKind& k) {
    for (TestSignalKind c : {TestSignalKind::Impulse, TestSignalKind::Sine, TestSignalKind::Sweep,
                             TestSignalKind::WhiteNoise, TestSignalKind::PinkNoise, TestSignalKind::Silence,
                             TestSignalKind::Dc, TestSignalKind::Wav, TestSignalKind::Buffer})
        if (s == signalName(c)) {
            k = c;
            return true;
        }
    return false;
}

bool onlyKeys(const Json& j, std::initializer_list<const char*> keys, const char* where, std::string& error) {
    for (const auto& [k, v] : j.obj) {
        bool known = false;
        for (const char* key : keys) known = known || k == key;
        if (!known) {
            error = std::string("unknown key '") + k + "' in " + where;
            return false;
        }
    }
    return true;
}

bool number(const Json& j, const char* key, double& out, std::string& error) {
    const Json* v = j.get(key);
    if (!v) return true;
    if (v->type != Json::Type::Number || !std::isfinite(v->num)) {
        error = std::string("'") + key + "' must be a number";
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

bool parseComponent(const Json& j, TestComponent& c, const char* where, std::string& error) {
    if (j.type == Json::Type::String) {
        c.id = j.str;
        return !c.id.empty() || (error = std::string(where) + " needs an id", false);
    }
    if (j.type != Json::Type::Object) {
        error = std::string(where) + " must be an id or an object";
        return false;
    }
    if (!onlyKeys(j, {"id", "library", "trust", "params"}, where, error)) return false;
    std::string trust;
    if (!text(j, "id", c.id, error) || !text(j, "library", c.library, error) || !text(j, "trust", trust, error))
        return false;
    if (c.id.empty()) {
        error = std::string(where) + " needs an id";
        return false;
    }
    if (!trust.empty()) {
        c.trustSet = true;
        if (trust == "trusted") c.trust = NativeModuleTrust::Trusted;
        else if (trust == "isolated") c.trust = NativeModuleTrust::Isolated;
        else if (trust == "blocked") c.trust = NativeModuleTrust::Blocked;
        else {
            error = "trust must be 'trusted', 'isolated' or 'blocked'";
            return false;
        }
    }
    if (!c.library.empty() && !c.trustSet) {
        error = std::string(where) + ": a library needs an explicit trust ('trusted', 'isolated' or 'blocked')";
        return false;
    }
    if (const Json* p = j.get("params")) {
        if (p->type != Json::Type::Object) {
            error = "'params' must be an object of parameter id to value";
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

bool floats(const Json* j, std::vector<float>& out, std::string& error) {
    if (!j) return true;
    if (j->type != Json::Type::Array) {
        error = "'left' and 'right' must be arrays of numbers";
        return false;
    }
    out.reserve(j->arr.size());
    for (const Json& v : j->arr) {
        if (v.type != Json::Type::Number) {
            error = "'left' and 'right' must be arrays of numbers";
            return false;
        }
        out.push_back(static_cast<float>(v.num));
    }
    return true;
}

bool parseSignal(const Json& j, TestSignal& s, std::string& error) {
    if (j.type == Json::Type::String) {
        if (!signalKind(j.str, s.kind)) {
            error = "unknown signal type '" + j.str + "'";
            return false;
        }
        return true;
    }
    if (j.type != Json::Type::Object) {
        error = "'signal' must be a type name or an object";
        return false;
    }
    if (!onlyKeys(j, {"type", "seconds", "level_db", "frequency", "start_frequency", "end_frequency", "seed",
                      "decorrelated", "path", "left", "right"},
                  "signal", error))
        return false;
    std::string type = "sine";
    if (!text(j, "type", type, error)) return false;
    if (!signalKind(type, s.kind)) {
        error = "unknown signal type '" + type + "'";
        return false;
    }
    double seed = s.seed;
    if (!number(j, "seconds", s.seconds, error) || !number(j, "frequency", s.frequency, error) ||
        !number(j, "start_frequency", s.startFrequency, error) || !number(j, "end_frequency", s.endFrequency, error) ||
        !number(j, "seed", seed, error) || !flag(j, "decorrelated", s.decorrelated, error) ||
        !text(j, "path", s.path, error) || !floats(j.get("left"), s.left, error) ||
        !floats(j.get("right"), s.right, error))
        return false;
    if (j.get("level_db")) {
        if (!number(j, "level_db", s.level, error)) return false;
        s.levelSet = true;
    }
    if (!(seed >= 0 && seed <= 4294967295.0)) {
        error = "'seed' must be 0 to 4294967295";
        return false;
    }
    s.seed = static_cast<uint32_t>(seed);
    return true;
}

// ---------------------------------------------------------------- WAV input

uint32_t le(const uint8_t* p, int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; ++i) v |= static_cast<uint32_t>(p[i]) << (8 * i);
    return v;
}

bool readWav(const std::string& path, std::vector<float>& left, std::vector<float>& right, int& rate,
             std::string& error) {
    // A regular file, read up to what the longest allowed test signal needs (120 s, 192 kHz, 32-bit stereo).
    constexpr std::uintmax_t kMaxWavBytes = 200u * 1024u * 1024u;
    std::error_code ec;
    if (!std::filesystem::is_regular_file(path, ec) || std::filesystem::file_size(path, ec) > kMaxWavBytes || ec) {
        error = "'" + path + "' is not a readable WAV file of at most 200 MB";
        return false;
    }
    std::ifstream f(path, std::ios::binary);
    if (!f) {
        error = "can't read the WAV file '" + path + "'";
        return false;
    }
    const std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    if (b.size() < 12 || std::memcmp(b.data(), "RIFF", 4) != 0 || std::memcmp(b.data() + 8, "WAVE", 4) != 0) {
        error = "'" + path + "' is not a WAV file";
        return false;
    }
    uint32_t format = 0, channels = 0, bits = 0;
    const uint8_t* data = nullptr;
    std::size_t dataSize = 0;
    for (std::size_t at = 12; at + 8 <= b.size();) {
        const uint32_t size = le(&b[at + 4], 4);
        const std::size_t body = at + 8;
        const std::size_t avail = std::min<std::size_t>(size, b.size() - body);
        if (std::memcmp(&b[at], "fmt ", 4) == 0 && avail >= 16) {
            format = le(&b[body], 2);
            channels = le(&b[body + 2], 2);
            rate = static_cast<int>(le(&b[body + 4], 4));
            bits = le(&b[body + 14], 2);
            if (format == 0xFFFE && avail >= 26) format = le(&b[body + 24], 2);  // extensible: the subformat
        } else if (std::memcmp(&b[at], "data", 4) == 0) {
            data = &b[body];
            dataSize = avail;
        }
        at = body + size + (size & 1u);
    }
    const bool pcm = format == 1 && (bits == 16 || bits == 24 || bits == 32);
    const bool flt = format == 3 && bits == 32;
    if (!data || (!pcm && !flt) || channels < 1 || channels > 2 || rate < 8000 || rate > 192000) {
        error = "'" + path + "' must be 16/24/32-bit PCM or 32-bit float WAV, mono or stereo, 8 to 192 kHz";
        return false;
    }
    const std::size_t bytes = bits / 8, frames = dataSize / (bytes * channels);
    left.resize(frames);
    right.resize(frames);
    for (std::size_t i = 0; i < frames; ++i)
        for (uint32_t c = 0; c < 2; ++c) {
            const uint8_t* p = data + (i * channels + std::min(c, channels - 1)) * bytes;
            float v = 0;
            if (flt) {
                const uint32_t u = le(p, 4);
                std::memcpy(&v, &u, 4);
            } else {
                const uint32_t u = le(p, static_cast<int>(bytes)) << (32 - bits);
                v = static_cast<float>(static_cast<int32_t>(u) / 2147483648.0);
            }
            (c == 0 ? left : right)[i] = v;
        }
    return true;
}

// ---------------------------------------------------------------- JSON output

struct Out {
    std::string s;
    void raw(const char* t) { s += t; }
    void key(const char* k) {
        if (!s.empty() && s.back() != '{' && s.back() != '[') s += ',';
        s += '"';
        s += k;
        s += "\":";
    }
    void item() {
        if (!s.empty() && s.back() != '{' && s.back() != '[') s += ',';
    }
    void num(double v) {
        if (!std::isfinite(v)) {
            s += "null";
            return;
        }
        if (v == 0) v = 0;  // no "-0"
        char buf[40];
        std::snprintf(buf, sizeof buf, "%.10g", v);
        s += buf;
    }
    void integer(uint64_t v) { s += std::to_string(v); }
    void str(std::string_view v) {
        s += '"';
        s += jsonEscape(v);
        s += '"';
    }
    void boolean(bool v) { s += v ? "true" : "false"; }
    void kv(const char* k, double v) { key(k), num(v); }
    void ki(const char* k, uint64_t v) { key(k), integer(v); }
    void ks(const char* k, std::string_view v) { key(k), str(v); }
    void kb(const char* k, bool v) { key(k), boolean(v); }
};

const char* roleName(ModuleRole r) {
    switch (r) {
        case ModuleRole::Instrument: return "instrument";
        case ModuleRole::Generator: return "generator";
        case ModuleRole::Effect: return "effect";
        case ModuleRole::Utility: return "utility";
        case ModuleRole::EventProcessor: return "event_processor";
        case ModuleRole::Analyzer: return "analyzer";
        case ModuleRole::Unspecified: break;
    }
    return "unspecified";
}

void frames(Out& o, const char* k, uint32_t v) {
    if (v == kInfiniteTail) o.ks(k, "infinite");
    else o.ki(k, v);
}

bool isStereoEffect(const ModuleDescriptor& d) noexcept {
    if (d.portCount != 2 || !d.ports) return false;
    const PortDescriptor& in = d.ports[0];
    const PortDescriptor& out = d.ports[1];
    return in.type == PortType::Audio && in.input && portChannelCount(in) == 2 && out.type == PortType::Audio &&
           !out.input && portChannelCount(out) == 2;
}

// ---------------------------------------------------------------- measurements

struct Window {
    std::size_t start = 0, size = 0;
};
Window clampWindow(std::size_t start, std::size_t size, std::size_t total) {
    start = std::min(start, total);
    return {start, std::min(size, total - start)};
}

std::vector<float> mid(const std::vector<float>& l, const std::vector<float>& r) {
    std::vector<float> m(l.size());
    for (std::size_t i = 0; i < l.size(); ++i) m[i] = 0.5f * (l[i] + r[i]);
    return m;
}

void sanitize(std::vector<float>& v) {
    for (float& x : v)
        if (!std::isfinite(x)) x = 0.0f;
}

bool hasLatencySignal(TestSignalKind k) {
    return k == TestSignalKind::Impulse || k == TestSignalKind::Sweep || k == TestSignalKind::WhiteNoise ||
           k == TestSignalKind::PinkNoise || k == TestSignalKind::Wav || k == TestSignalKind::Buffer;
}
bool hasResponseSignal(TestSignalKind k) {
    return k == TestSignalKind::Impulse || k == TestSignalKind::Sweep || k == TestSignalKind::WhiteNoise ||
           k == TestSignalKind::PinkNoise;
}

struct Context {
    const ComponentTestRequest& req;
    double sampleRate;
    std::size_t signalFrames, renderFrames;
    const std::vector<float>& inL;
    const std::vector<float>& inR;
    double inputPeak;
};

// Every measurement of one render, written into `o` as an object's members. `full` adds the spectrum
// and frequency response (left out of each parameter-sweep point to keep it small).
void measure(Out& o, const Context& c, ComponentRender& r, bool full, std::vector<std::string>& warnings) {
    const bool impulse = c.req.signal.kind == TestSignalKind::Impulse;
    const std::size_t R = c.renderFrames, S = c.signalFrames, L = r.latencyFrames;
    const Window inWin = impulse ? Window{0, R} : clampWindow(0, S, R);
    const Window outWin = impulse ? Window{0, R} : clampWindow(L, S, R);
    // Raw counts over the whole render, then the output is cleaned for the rest.
    const analysis::Levels rawL = analysis::levels(r.left.data(), R), rawR = analysis::levels(r.right.data(), R);
    sanitize(r.left);
    sanitize(r.right);
    const analysis::Levels raw[2] = {rawL, rawR};
    const std::vector<float>* outs[2] = {&r.left, &r.right};
    const std::vector<float>* ins[2] = {&c.inL, &c.inR};
    double clipPeak = 0;
    o.key("channels");
    o.raw("[");
    for (int ch = 0; ch < 2; ++ch) {
        const analysis::Levels lv = analysis::levels(outs[ch]->data() + outWin.start, outWin.size);
        const analysis::Levels in = analysis::levels(ins[ch]->data() + inWin.start, inWin.size);
        clipPeak = std::max(clipPeak, raw[ch].peak);
        o.item();
        o.raw("{");
        o.kv("peak_db", lv.peakDb);
        o.kv("rms_db", lv.rmsDb);
        o.kv("dc_offset", lv.dc);
        o.kv("crest_db", lv.rms > 0 ? lv.crestDb : std::numeric_limits<double>::quiet_NaN());
        o.kv("gain_db", in.rms > 0 ? lv.rmsDb - in.rmsDb : std::numeric_limits<double>::quiet_NaN());
        o.ki("nan", raw[ch].nan);
        o.ki("inf", raw[ch].inf);
        o.ki("denormal", raw[ch].denormal);
        o.raw("}");
        if (raw[ch].nan + raw[ch].inf && std::find(warnings.begin(), warnings.end(), "non_finite") == warnings.end())
            warnings.push_back("non_finite");
        if (raw[ch].denormal && std::find(warnings.begin(), warnings.end(), "denormals") == warnings.end())
            warnings.push_back("denormals");
    }
    o.raw("]");
    if (clipPeak > 1.0) warnings.push_back("clipping");
    if (r.failedBlocks) warnings.push_back("failed_blocks");
    o.ki("failed_blocks", r.failedBlocks);
    const analysis::Stereo st = analysis::stereo(r.left.data() + outWin.start, r.right.data() + outWin.start, outWin.size);
    o.key("stereo");
    o.raw("{");
    o.kv("correlation", st.correlation);
    o.kv("width", st.width);
    o.raw("}");

    const std::vector<float> outMid = mid(r.left, r.right);
    // Steady state: past the declared latency and the first 100 ms (or quarter) of the signal.
    const std::size_t skip = std::min<std::size_t>(static_cast<std::size_t>(0.1 * c.sampleRate), S / 4);
    const Window steady = clampWindow(L + skip, S > skip ? S - skip : 0, R);

    o.key("thd");
    if (c.req.signal.kind == TestSignalKind::Sine) {
        o.raw("{");
        o.kv("frequency", c.req.signal.frequency);
        for (int ch = 0; ch < 2; ++ch) {
            const analysis::SineDistortion d = analysis::sineDistortion(
                outs[ch]->data() + steady.start, steady.size, c.req.signal.frequency, c.sampleRate);
            o.key(ch == 0 ? "left" : "right");
            if (!d.valid) {
                o.raw("null");
                continue;
            }
            o.raw("{");
            o.kv("fundamental_db", analysis::toDb(d.fundamental));
            o.kv("thd_percent", d.thd * 100.0);
            o.kv("thd_db", analysis::toDb(d.thd));
            o.kv("thd_n_percent", d.thdN * 100.0);
            o.kv("thd_n_db", analysis::toDb(d.thdN));
            o.raw("}");
        }
        o.raw("}");
    } else {
        o.raw("null");
    }

    const double quiet = c.inputPeak * std::pow(10.0, kQuietDb / 20.0);
    o.key("impulse_response");
    if (impulse && c.inputPeak > 0) {
        std::size_t end = 0;
        for (int ch = 0; ch < 2; ++ch) end = std::max(end, analysis::endAbove(outs[ch]->data(), R, quiet));
        o.raw("{");
        o.ki("length_frames", end);
        o.kv("length_ms", 1000.0 * static_cast<double>(end) / c.sampleRate);
        o.kb("truncated", end == R && R > 0);
        o.raw("}");
    } else {
        o.raw("null");
    }

    o.key("latency");
    o.raw("{");
    o.ki("declared", r.latencyFrames);
    int64_t measured = -1;
    if (hasLatencySignal(c.req.signal.kind)) {
        const std::vector<float> inMid = mid(c.inL, c.inR);
        const std::size_t n = std::min(R, kMaxLagFrames);
        measured = analysis::findLag(inMid.data(), outMid.data(), n, n);
    }
    o.key("measured");
    if (measured >= 0) o.integer(static_cast<uint64_t>(measured));
    else o.raw("null");
    o.key("matches");
    if (measured >= 0) o.boolean(measured == static_cast<int64_t>(r.latencyFrames));
    else o.raw("null");
    o.raw("}");
    if (measured >= 0 && measured != static_cast<int64_t>(r.latencyFrames)) warnings.push_back("latency_mismatch");

    o.key("tail");
    if (c.inputPeak > 0) {
        std::size_t end = 0;
        for (int ch = 0; ch < 2; ++ch) end = std::max(end, analysis::endAbove(outs[ch]->data(), R, quiet));
        const uint64_t tail = end > S ? end - S : 0;
        const bool truncated = end == R && R > S;
        const bool within = r.tailFrames == kInfiniteTail ||
                            tail <= static_cast<uint64_t>(r.tailFrames) + r.latencyFrames;
        o.raw("{");
        frames(o, "declared", r.tailFrames);
        o.ki("measured", tail);
        o.kv("measured_ms", 1000.0 * static_cast<double>(tail) / c.sampleRate);
        o.kb("truncated", truncated);
        o.kb("within_declared", within);
        o.raw("}");
        if (!within) warnings.push_back("tail_exceeds_declared");
        if (truncated && r.tailFrames != kInfiniteTail) warnings.push_back("tail_truncated");
    } else {
        o.raw("null");
    }

    if (!full) return;
    o.key("spectrum");
    if (c.req.signal.kind != TestSignalKind::Silence) {
        const Window w = impulse ? Window{0, R} : steady;
        const std::size_t size = std::min<std::size_t>(c.req.fftSize, std::max<std::size_t>(256, analysis::nextPowerOfTwo(w.size)));
        const auto bands = analysis::spectrumBands(outMid.data() + w.start, w.size, size, c.sampleRate, c.req.bandsPerOctave);
        o.raw("{");
        o.ki("fft_size", size);
        o.ks("window", "hann");
        o.ks("channel", "mid");
        o.key("bands");
        o.raw("[");
        for (const auto& b : bands) {
            o.item();
            o.raw("[");
            o.num(b.hz);
            o.raw(",");
            o.num(b.db);
            o.raw("]");
        }
        o.raw("]}");
    } else {
        o.raw("null");
    }
    o.key("frequency_response");
    if (hasResponseSignal(c.req.signal.kind) && c.inputPeak > 0) {
        const std::vector<float> inMid = mid(c.inL, c.inR);
        const std::size_t n = std::min(R, kMaxResponseFrames);
        const auto bands = analysis::frequencyResponse(inMid.data(), outMid.data(), n, c.sampleRate, c.req.bandsPerOctave);
        o.raw("{");
        o.ks("channel", "mid");
        o.key("bands");
        o.raw("[");
        for (const auto& b : bands) {
            o.item();
            o.raw("[");
            o.num(b.hz);
            o.raw(",");
            o.num(b.db);
            o.raw("]");
        }
        o.raw("]}");
    } else {
        o.raw("null");
    }
}

// A null test: a[i + shiftA] - b[i + shiftB] over both channels (outputs already cleaned).
struct NullResult {
    double peakDb = 0, rmsDb = 0, referenceRmsDb = 0;
    bool exact = true;
    std::size_t frames = 0;
};
NullResult nullTest(const std::vector<float>* a[2], const std::vector<float>* b[2], std::size_t shiftA,
                    std::size_t shiftB) {
    NullResult n;
    const std::size_t lenA = a[0]->size() > shiftA ? a[0]->size() - shiftA : 0;
    const std::size_t lenB = b[0]->size() > shiftB ? b[0]->size() - shiftB : 0;
    n.frames = std::min(lenA, lenB);
    double peak = 0, sumSq = 0, refSq = 0;
    for (int ch = 0; ch < 2; ++ch)
        for (std::size_t i = 0; i < n.frames; ++i) {
            const double x = (*a[ch])[i + shiftA], d = x - static_cast<double>((*b[ch])[i + shiftB]);
            if (d != 0) n.exact = false;
            peak = std::max(peak, std::fabs(d));
            sumSq += d * d;
            refSq += x * x;
        }
    const double count = std::max<double>(1, 2.0 * static_cast<double>(n.frames));
    n.peakDb = analysis::toDb(peak);
    n.rmsDb = analysis::toDb(std::sqrt(sumSq / count));
    n.referenceRmsDb = analysis::toDb(std::sqrt(refSq / count));
    return n;
}

void writeNull(Out& o, const char* key, const std::vector<float>* a[2], const std::vector<float>* b[2],
               uint32_t latA, uint32_t latB, NullAlign align, const std::vector<std::string>* extra = nullptr) {
    std::size_t shiftA = 0, shiftB = 0;
    if (align == NullAlign::Declared) {
        shiftA = latA;
        shiftB = latB;
    } else if (align == NullAlign::Measured) {
        // Either side may be the later one: try both lags and keep the deeper null.
        const std::vector<float> ma = mid(*a[0], *a[1]), mb = mid(*b[0], *b[1]);
        const std::size_t n = std::min({ma.size(), mb.size(), kMaxLagFrames});
        const int64_t aLate = analysis::findLag(mb.data(), ma.data(), n, n);
        const int64_t bLate = analysis::findLag(ma.data(), mb.data(), n, n);
        const NullResult x = nullTest(a, b, aLate > 0 ? static_cast<std::size_t>(aLate) : 0, 0);
        const NullResult y = nullTest(a, b, 0, bLate > 0 ? static_cast<std::size_t>(bLate) : 0);
        if (bLate > 0 && !(y.rmsDb >= x.rmsDb)) shiftB = static_cast<std::size_t>(bLate);
        else if (aLate > 0) shiftA = static_cast<std::size_t>(aLate);
    }
    const NullResult n = nullTest(a, b, shiftA, shiftB);
    o.key(key);
    o.raw("{");
    if (extra)
        for (const std::string& s : *extra) o.raw(s.c_str());
    o.ks("align", align == NullAlign::None ? "none" : align == NullAlign::Declared ? "declared" : "measured");
    o.key("offset_frames");
    o.num(static_cast<double>(shiftA) - static_cast<double>(shiftB));
    o.ki("frames", n.frames);
    o.kb("exact", n.exact);
    o.kv("difference_peak_db", n.peakDb);
    o.kv("difference_rms_db", n.rmsDb);
    o.kv("depth_db", n.rmsDb - n.referenceRmsDb);
    o.raw("}");
}

bool writeStereoWav(const std::string& path, const std::vector<float>& l, const std::vector<float>& r, double rate,
                    std::string& error) {
    std::vector<float> inter(l.size() * 2);
    for (std::size_t i = 0; i < l.size(); ++i) {
        inter[2 * i] = std::isfinite(l[i]) ? l[i] : 0.0f;
        inter[2 * i + 1] = std::isfinite(r[i]) ? r[i] : 0.0f;
    }
    WavSpec spec;
    spec.sampleRate = static_cast<int>(rate);
    spec.float32 = true;
    return writeFile(path, encodeWav(spec, inter.data(), static_cast<int64_t>(l.size())), error);
}

std::string failure(const std::string& error) {
    return "{\"ok\":false,\"error\":\"" + jsonEscape(error) + "\"}";
}

}  // namespace

// ---------------------------------------------------------------- public

bool parseComponentTestRequest(std::string_view json, ComponentTestRequest& out, std::string& error) {
    Json j;
    if (!parseJson(json, j, error)) return false;
    if (j.type != Json::Type::Object) {
        error = "the request must be a JSON object";
        return false;
    }
    if (!onlyKeys(j, {"component", "sample_rate", "block_size", "signal", "tail_seconds", "tempo", "cpu", "fft_size",
                      "bands_per_octave", "compare", "align", "bypass", "sweep", "write_wav", "write_input_wav"},
                  "the request", error))
        return false;
    const Json* comp = j.get("component");
    if (!comp) {
        error = "the request needs a 'component'";
        return false;
    }
    if (!parseComponent(*comp, out.component, "'component'", error)) return false;
    double block = out.blockSize, fft = out.fftSize;
    if (j.get("sample_rate")) out.sampleRateSet = true;
    std::string align;
    if (!number(j, "sample_rate", out.sampleRate, error) || !number(j, "block_size", block, error) ||
        !number(j, "tail_seconds", out.tailSeconds, error) || !number(j, "tempo", out.tempo, error) ||
        !flag(j, "cpu", out.cpu, error) || !number(j, "fft_size", fft, error) ||
        !number(j, "bands_per_octave", out.bandsPerOctave, error) || !text(j, "align", align, error) ||
        !flag(j, "bypass", out.bypass, error) || !text(j, "write_wav", out.writeWav, error) ||
        !text(j, "write_input_wav", out.writeInputWav, error))
        return false;
    if (!(out.sampleRate >= 8000 && out.sampleRate <= 192000) || out.sampleRate != std::floor(out.sampleRate)) {
        error = "'sample_rate' must be a whole number from 8000 to 192000";
        return false;
    }
    if (!(block >= 1 && block <= 8192) || block != std::floor(block)) {
        error = "'block_size' must be a whole number from 1 to 8192";
        return false;
    }
    out.blockSize = static_cast<uint32_t>(block);
    if (!(fft >= 256 && fft <= 65536) || analysis::nextPowerOfTwo(static_cast<std::size_t>(fft)) != fft) {
        error = "'fft_size' must be a power of two from 256 to 65536";
        return false;
    }
    out.fftSize = static_cast<uint32_t>(fft);
    if (!(out.tempo >= 20 && out.tempo <= 999)) {
        error = "'tempo' must be 20 to 999";
        return false;
    }
    if (!(out.bandsPerOctave >= 1 && out.bandsPerOctave <= 48)) {
        error = "'bands_per_octave' must be 1 to 48";
        return false;
    }
    if (align == "none") out.align = NullAlign::None;
    else if (align == "measured") out.align = NullAlign::Measured;
    else if (align.empty() || align == "declared") out.align = NullAlign::Declared;
    else {
        error = "'align' must be 'none', 'declared' or 'measured'";
        return false;
    }
    if (const Json* s = j.get("signal"))
        if (!parseSignal(*s, out.signal, error)) return false;
    if (const Json* c = j.get("compare")) {
        out.hasCompare = true;
        if (!parseComponent(*c, out.compare, "'compare'", error)) return false;
    }
    if (const Json* s = j.get("sweep")) {
        if (s->type != Json::Type::Object || !onlyKeys(*s, {"param", "steps", "from", "to"}, "sweep", error)) {
            if (error.empty()) error = "'sweep' must be an object";
            return false;
        }
        double steps = 0;
        if (!text(*s, "param", out.sweepParam, error) || !number(*s, "steps", steps, error) ||
            !number(*s, "from", out.sweepFrom, error) || !number(*s, "to", out.sweepTo, error))
            return false;
        out.sweepFromSet = s->get("from") != nullptr;
        out.sweepToSet = s->get("to") != nullptr;
        if (out.sweepParam.empty()) {
            error = "'sweep' needs a 'param'";
            return false;
        }
        if (s->get("steps") && (!(steps >= 1 && steps <= kMaxSweepSteps) || steps != std::floor(steps))) {
            error = "sweep 'steps' must be a whole number from 1 to 64";
            return false;
        }
        out.sweepSteps = static_cast<uint32_t>(steps);  // 0: chosen from the parameter
        out.hasSweep = true;
    }
    return true;
}

bool generateTestSignal(const TestSignal& s, double sampleRate, std::vector<float>& left, std::vector<float>& right,
                        std::string& error) {
    using namespace caw;
    if (s.kind == TestSignalKind::Buffer || s.kind == TestSignalKind::Wav) {
        left = s.left;
        right = s.right.empty() ? s.left : s.right;
        if (left.size() != right.size()) {
            error = "the signal's left and right must be the same length";
            return false;
        }
        if (left.empty()) {
            error = "the signal buffer is empty";
            return false;
        }
        return true;
    }
    if (!(s.seconds > 0 && s.seconds <= kMaxRenderSeconds)) {
        error = "signal 'seconds' must be above 0 and at most 120";
        return false;
    }
    const std::size_t n = s.kind == TestSignalKind::Impulse
                              ? 1
                              : std::max<std::size_t>(1, static_cast<std::size_t>(std::llround(s.seconds * sampleRate)));
    const double level = s.levelSet ? s.level : s.kind == TestSignalKind::Impulse ? 0.0 : -6.0;
    if (!(level <= 0 && level >= -200)) {
        error = "signal 'level_db' must be -200 to 0";
        return false;
    }
    const double amp = detPow(10.0, level / 20.0);
    left.assign(n, 0.0f);
    right.assign(n, 0.0f);
    const double nyquist = sampleRate / 2;
    switch (s.kind) {
        case TestSignalKind::Impulse: left[0] = right[0] = static_cast<float>(amp); break;
        case TestSignalKind::Silence: break;
        case TestSignalKind::Dc: std::fill(left.begin(), left.end(), static_cast<float>(amp)); break;
        case TestSignalKind::Sine: {
            if (!(s.frequency > 0 && s.frequency < nyquist)) {
                error = "sine 'frequency' must be above 0 and below half the sample rate";
                return false;
            }
            const double w = kTwoPi * s.frequency / sampleRate;
            for (std::size_t i = 0; i < n; ++i) left[i] = static_cast<float>(amp * detSin(w * static_cast<double>(i)));
            break;
        }
        case TestSignalKind::Sweep: {
            const double f1 = s.startFrequency, f2 = std::min(s.endFrequency, 0.95 * nyquist);
            if (!(f1 > 0 && f2 > f1)) {
                error = "sweep needs 0 < start_frequency < end_frequency (held below 0.95 x Nyquist)";
                return false;
            }
            // Exponential sweep: phase = 2 pi f1 T / ln(f2/f1) * (exp(t ln(f2/f1) / T) - 1).
            const double T = static_cast<double>(n) / sampleRate, k = detLog(f2 / f1);
            for (std::size_t i = 0; i < n; ++i) {
                const double t = static_cast<double>(i) / sampleRate;
                left[i] = static_cast<float>(amp * detSin(kTwoPi * f1 * T / k * (detExp(t * k / T) - 1.0)));
            }
            break;
        }
        case TestSignalKind::WhiteNoise:
        case TestSignalKind::PinkNoise: {
            const int sides = s.decorrelated ? 2 : 1;
            for (int side = 0; side < sides; ++side) {
                std::vector<float>& x = side == 0 ? left : right;
                uint32_t state = hash32(s.seed * 2u + static_cast<uint32_t>(side) + 0x9E3779B9u) | 1u;
                double b0 = 0, b1 = 0, b2 = 0, b3 = 0, b4 = 0, b5 = 0, b6 = 0, sumSq = 0;
                std::vector<double> v(n);
                for (std::size_t i = 0; i < n; ++i) {
                    state ^= state << 13;  // xorshift32
                    state ^= state >> 17;
                    state ^= state << 5;
                    const double white = static_cast<double>(state) / 2147483648.0 - 1.0;
                    double y = white;
                    if (s.kind == TestSignalKind::PinkNoise) {  // Paul Kellett's pink filter (refined)
                        b0 = 0.99886 * b0 + white * 0.0555179;
                        b1 = 0.99332 * b1 + white * 0.0750759;
                        b2 = 0.96900 * b2 + white * 0.1538520;
                        b3 = 0.86650 * b3 + white * 0.3104856;
                        b4 = 0.55000 * b4 + white * 0.5329522;
                        b5 = -0.7616 * b5 - white * 0.0168980;
                        y = b0 + b1 + b2 + b3 + b4 + b5 + b6 + white * 0.5362;
                        b6 = white * 0.115926;
                    }
                    v[i] = y;
                    sumSq += y * y;
                }
                const double scale = sumSq > 0 ? amp / std::sqrt(sumSq / static_cast<double>(n)) : 0.0;
                for (std::size_t i = 0; i < n; ++i) x[i] = static_cast<float>(v[i] * scale);
            }
            if (s.decorrelated) return true;
            break;
        }
        case TestSignalKind::Wav:
        case TestSignalKind::Buffer: break;
    }
    right = left;
    return true;
}

bool prepareRegistry(ModuleRegistry& registry, const TestComponent& c, std::string& error) {
    if (c.library.empty()) {
        if (registry.find(c.id)) return true;
        error = "component '" + c.id + "' is not built in; give its 'library' and a 'trust' choice";
        return false;
    }
    if (!c.trustSet) {
        error = "a component library needs an explicit trust choice";
        return false;
    }
    const ModuleLoadResult r = registry.loadSharedLibrary(c.library, c.id, c.trust);
    if (!r.success) {
        error = "can't load '" + c.id + "' from '" + c.library + "': " + r.message;
        return false;
    }
    return true;
}

bool renderComponent(const ModuleRegistry& registry, const TestComponent& c, double sampleRate, uint32_t blockSize,
                     double tempo, const std::vector<float>& inL, const std::vector<float>& inR, bool timing,
                     ComponentRender& out, std::string& error) {
    const ModuleDescriptor* d = registry.find(c.id);
    if (!d) {
        error = "component '" + c.id + "' is not loaded";
        return false;
    }
    if (!isStereoEffect(*d)) {
        error = "component '" + c.id +
                "' must have one stereo audio input and one stereo audio output (testing instruments, with note "
                "input, is not built yet)";
        return false;
    }
    std::unique_ptr<ModuleProcessor> p = registry.create(c.id);
    if (!p) {
        error = "component '" + c.id + "' could not create an instance";
        return false;
    }
    const ModuleDescriptor& own = p->descriptor();
    std::vector<ParameterValue> values(own.parameterCount);
    for (uint32_t k = 0; k < own.parameterCount; ++k) values[k].value = constrainParameter(own.parameters[k], own.parameters[k].defaultValue);
    for (const auto& [name, v] : c.params) {
        uint32_t k = 0;
        while (k < own.parameterCount && own.parameters[k].id != name) ++k;
        if (k == own.parameterCount) {
            error = "component '" + c.id + "' has no parameter '" + name + "'";
            return false;
        }
        values[k].value = constrainParameter(own.parameters[k], v);
    }
    if (!p->activate(sampleRate, blockSize)) {
        error = "component '" + c.id + "' refused to activate at " + std::to_string(static_cast<int>(sampleRate)) +
                " Hz, blocks of " + std::to_string(blockSize);
        return false;
    }
    out.latencyFrames = own.latencyFrames;
    out.tailFrames = own.tailFrames;
    const std::size_t n = inL.size();
    out.left.assign(n, 0.0f);
    out.right.assign(n, 0.0f);
    out.failedBlocks = 0;
    out.blockMicros.clear();
    if (timing) out.blockMicros.reserve(n / blockSize + 1);
    std::vector<float> stageL(blockSize), stageR(blockSize);
    Transport transport;
    transport.tempo = tempo;
    transport.playing = true;
    for (std::size_t at = 0; at < n; at += blockSize) {
        const uint32_t m = static_cast<uint32_t>(std::min<std::size_t>(blockSize, n - at));
        std::copy_n(inL.data() + at, m, stageL.data());  // the component may not keep or write its input
        std::copy_n(inR.data() + at, m, stageR.data());
        const float* in[2] = {stageL.data(), stageR.data()};
        float* o[2] = {out.left.data() + at, out.right.data() + at};
        AudioProcessBlock block;
        block.input = {in, 2, m};
        block.output = {o, 2, m};
        block.frames = m;
        block.sampleRate = sampleRate;
        block.parameters = values.empty() ? nullptr : values.data();
        block.parameterCount = own.parameterCount;
        transport.beat = static_cast<double>(at) / sampleRate * tempo / 60.0;
        block.transport = &transport;
        const auto t0 = std::chrono::steady_clock::now();
        const bool ok = p->process(block);
        if (timing)
            out.blockMicros.push_back(
                std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - t0).count());
        if (!ok) {
            ++out.failedBlocks;
            std::copy_n(inL.data() + at, m, o[0]);
            std::copy_n(inR.data() + at, m, o[1]);
        }
    }
    p->deactivate();
    return true;
}

std::string runComponentTest(const ComponentTestRequest& request) try {
    ComponentTestRequest req = request;
    if (req.signal.kind == TestSignalKind::Wav) {
        int rate = 0;
        std::string error;
        if (req.signal.path.empty()) return failure("a 'wav' signal needs a 'path'");
        if (!readWav(req.signal.path, req.signal.left, req.signal.right, rate, error)) return failure(error);
        if (!req.sampleRateSet) req.sampleRate = rate;
        else if (rate != static_cast<int>(req.sampleRate))
            return failure("the WAV file is " + std::to_string(rate) + " Hz but the test runs at " +
                           std::to_string(static_cast<int>(req.sampleRate)) + " Hz (leave 'sample_rate' out to use the file's)");
    }
    std::string error;
    ModuleRegistry registry;
    registerBuiltinComponents(registry);
    if (!prepareRegistry(registry, req.component, error)) return failure(error);
    const ModuleDescriptor* d = registry.find(req.component.id);

    std::vector<float> inL, inR;
    if (!generateTestSignal(req.signal, req.sampleRate, inL, inR, error)) return failure(error);
    const std::size_t S = inL.size();
    double tail = req.tailSeconds;
    if (tail < 0) {
        tail = d->tailFrames == kInfiniteTail
                   ? 5.0
                   : (static_cast<double>(d->tailFrames) + d->latencyFrames) / req.sampleRate + 0.25;
    }
    if (static_cast<double>(S) / req.sampleRate + tail > kMaxRenderSeconds) {
        if (req.tailSeconds >= 0) return failure("the signal and tail together must be at most 120 s");
        tail = std::max(0.0, kMaxRenderSeconds - static_cast<double>(S) / req.sampleRate);
    }
    const std::size_t R = S + static_cast<std::size_t>(std::llround(tail * req.sampleRate));
    inL.resize(R, 0.0f);
    inR.resize(R, 0.0f);
    double inputPeak = 0;
    for (std::size_t i = 0; i < S; ++i)
        inputPeak = std::max({inputPeak, std::fabs(static_cast<double>(inL[i])), std::fabs(static_cast<double>(inR[i]))});

    ComponentRender main;
    if (!renderComponent(registry, req.component, req.sampleRate, req.blockSize, req.tempo, inL, inR, req.cpu, main,
                         error))
        return failure(error);
    const ModuleDescriptor& desc = *registry.find(req.component.id);
    if (!req.writeInputWav.empty() && !writeStereoWav(req.writeInputWav, inL, inR, req.sampleRate, error))
        return failure(error);
    if (!req.writeWav.empty() && !writeStereoWav(req.writeWav, main.left, main.right, req.sampleRate, error))
        return failure(error);

    const Context ctx{req, req.sampleRate, S, R, inL, inR, inputPeak};
    std::vector<std::string> warnings;
    Out o;
    o.raw("{");
    o.kb("ok", true);
    o.ks("error", "");
    o.ki("schema", 1);
    o.key("component");
    o.raw("{");
    o.ks("id", desc.id);
    o.ks("name", desc.name.empty() ? desc.id : desc.name);
    o.ki("version", desc.version);
    o.ks("role", roleName(desc.role));
    o.ks("source", req.component.library.empty() ? "builtin" : "library");
    o.ki("latency_frames", desc.latencyFrames);
    frames(o, "tail_frames", desc.tailFrames);
    o.key("params");
    o.raw("{");
    for (uint32_t k = 0; k < desc.parameterCount; ++k) {
        double v = desc.parameters[k].defaultValue;
        for (const auto& [name, value] : req.component.params)
            if (desc.parameters[k].id == name) v = value;
        o.kv(std::string(desc.parameters[k].id).c_str(), constrainParameter(desc.parameters[k], v));
    }
    o.raw("}}");
    o.key("settings");
    o.raw("{");
    o.ki("sample_rate", static_cast<uint64_t>(req.sampleRate));
    o.ki("block_size", req.blockSize);
    o.kv("tempo", req.tempo);
    o.ks("signal", signalName(req.signal.kind));
    if (req.signal.kind != TestSignalKind::Wav && req.signal.kind != TestSignalKind::Buffer &&
        req.signal.kind != TestSignalKind::Silence)
        o.kv("level_db", req.signal.levelSet ? req.signal.level : req.signal.kind == TestSignalKind::Impulse ? 0.0 : -6.0);
    if (req.signal.kind == TestSignalKind::Sine) o.kv("frequency", req.signal.frequency);
    if (req.signal.kind == TestSignalKind::Sweep) {
        o.kv("start_frequency", req.signal.startFrequency);
        o.kv("end_frequency", std::min(req.signal.endFrequency, 0.95 * req.sampleRate / 2));
    }
    if (req.signal.kind == TestSignalKind::WhiteNoise || req.signal.kind == TestSignalKind::PinkNoise) {
        o.ki("seed", req.signal.seed);
        o.kb("decorrelated", req.signal.decorrelated);
    }
    o.ki("signal_frames", S);
    o.ki("render_frames", R);
    o.raw("}");
    o.key("output");
    o.raw("{");
    measure(o, ctx, main, true, warnings);
    o.raw("}");

    if (req.cpu && !main.blockMicros.empty()) {
        std::vector<double> t = main.blockMicros;
        std::sort(t.begin(), t.end());
        const double median = t.size() % 2 ? t[t.size() / 2] : (t[t.size() / 2 - 1] + t[t.size() / 2]) / 2;
        const double budget = 1e6 * req.blockSize / req.sampleRate;
        o.key("cpu");
        o.raw("{");
        o.ki("blocks", t.size());
        o.kv("median_us", median);
        o.kv("worst_us", t.back());
        o.kv("median_percent", 100.0 * median / budget);
        o.kv("worst_percent", 100.0 * t.back() / budget);
        o.raw("}");
    }

    const std::vector<float>* a[2] = {&main.left, &main.right};
    if (req.bypass) {
        const std::vector<float>* dry[2] = {&inL, &inR};
        writeNull(o, "bypass", a, dry, main.latencyFrames, 0, req.align);
    }
    if (req.hasCompare) {
        ModuleRegistry other;
        registerBuiltinComponents(other);
        if (!prepareRegistry(other, req.compare, error)) return failure(error);
        ComponentRender cmp;
        if (!renderComponent(other, req.compare, req.sampleRate, req.blockSize, req.tempo, inL, inR, false, cmp, error))
            return failure(error);
        sanitize(cmp.left);
        sanitize(cmp.right);
        const std::vector<float>* b[2] = {&cmp.left, &cmp.right};
        Out head;
        head.ks("id", req.compare.id);
        head.ks("source", req.compare.library.empty() ? "builtin" : "library");
        head.ki("latency_frames", cmp.latencyFrames);
        const std::vector<std::string> extra = {head.s};
        writeNull(o, "compare", a, b, main.latencyFrames, cmp.latencyFrames, req.align, &extra);
    }
    if (req.hasSweep) {
        uint32_t k = 0;
        while (k < desc.parameterCount && desc.parameters[k].id != req.sweepParam) ++k;
        if (k == desc.parameterCount)
            return failure("component '" + req.component.id + "' has no parameter '" + req.sweepParam + "' to sweep");
        const ParameterDescriptor& pd = desc.parameters[k];
        const double from = req.sweepFromSet ? req.sweepFrom : pd.minimum;
        const double to = req.sweepToSet ? req.sweepTo : pd.maximum;
        uint32_t steps = req.sweepSteps;
        if (steps == 0) steps = pd.choiceCount > 0 ? std::min(pd.choiceCount, kMaxSweepSteps) : 5;
        o.key("sweep");
        o.raw("{");
        o.ks("param", req.sweepParam);
        o.key("points");
        o.raw("[");
        for (uint32_t i = 0; i < steps; ++i) {
            const double raw = steps == 1 ? from : from + (to - from) * i / (steps - 1);
            TestComponent c = req.component;
            std::erase_if(c.params, [&](const auto& p) { return p.first == req.sweepParam; });
            c.params.emplace_back(req.sweepParam, raw);
            ComponentRender r;
            if (!renderComponent(registry, c, req.sampleRate, req.blockSize, req.tempo, inL, inR, false, r, error))
                return failure(error);
            std::vector<std::string> pointWarnings;
            o.item();
            o.raw("{");
            o.kv("value", constrainParameter(pd, raw));
            measure(o, ctx, r, false, pointWarnings);
            o.key("warnings");
            o.raw("[");
            for (const std::string& w : pointWarnings) {
                o.item();
                o.str(w);
            }
            o.raw("]}");
        }
        o.raw("]}");
    }
    o.key("warnings");
    o.raw("[");
    for (const std::string& w : warnings) {
        o.item();
        o.str(w);
    }
    o.raw("]}");
    return o.s;
} catch (const std::bad_alloc&) {
    return failure("out of memory: the test is too long for this device");
} catch (...) {
    return failure("the component test failed");
}

namespace {

// [name] as a plain file name inside [dir] (no separators, no "..", not hidden), or empty.
std::string inside(const std::string& dir, const std::string& name) {
    if (dir.empty() || name.empty() || name == "." || name == ".." || name[0] == '.' ||
        name.find_first_of("/\\:") != std::string::npos)
        return {};
    return dir + "/" + name;
}

bool hostPath(std::string& path, const std::string& dir, const char* key, std::string& error) {
    if (path.empty()) return true;
    const std::string p = inside(dir, path);
    if (p.empty()) {
        error = std::string("'") + key + "' must be a plain file name inside the host's folder";
        return false;
    }
    path = p;
    return true;
}

bool hostComponent(TestComponent& c, const ComponentTestHost& host, std::string& error) {
    if (c.trustSet) {
        error = "the request may not choose a trust level; the host gives it";
        return false;
    }
    if (!c.library.empty()) {
        c.trust = host.trust;
        c.trustSet = true;
    }
    return true;
}

}  // namespace

std::string componentTestJson(std::string_view requestJson, const ComponentTestHost& host) try {
    ComponentTestRequest req;
    std::string error;
    if (!parseComponentTestRequest(requestJson, req, error)) return failure(error);
    if (!hostComponent(req.component, host, error) || !hostComponent(req.compare, host, error) ||
        !hostPath(req.writeWav, host.outputDir, "write_wav", error) ||
        !hostPath(req.writeInputWav, host.outputDir, "write_input_wav", error) ||
        !hostPath(req.signal.path, host.inputDir, "signal.path", error))
        return failure(error);
    return runComponentTest(req);
} catch (...) {
    return failure("the component test failed");
}

std::string componentTestJson(std::string_view requestJson) try {
    ComponentTestRequest req;
    std::string error;
    if (!parseComponentTestRequest(requestJson, req, error)) return failure(error);
    return runComponentTest(req);
} catch (...) {
    return failure("the component test failed");
}

}  // namespace caw
