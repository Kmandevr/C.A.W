// The sampler's offline tools (C API 43): root detection (YIN), drop-and-play mapping, slicing and recorded takes, with their JSON requests.
#include "sampler_tools.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>

#include "asset_store.h"
#include "audio_analysis.h"
#include "caw/detmath.hpp"
#include "json.h"

namespace caw {

namespace {

constexpr size_t kMaxRequestBytes = 64u << 10;
constexpr size_t kMaxSamples = 128;
constexpr size_t kMaxNotes = 128;

std::string num(double v) {
    char b[40];
    std::snprintf(b, sizeof b, "%.10g", v);
    return b;
}

std::string fail(const std::string& e) { return "{\"ok\":false,\"error\":\"" + jsonEscape(e) + "\"}"; }

double hzToMidi(double hz) { return 69.0 + 12.0 * detLog(hz / 440.0) / 0.69314718055994530942; }

// One YIN frame: the cumulative mean normalised difference of x[0, w + maxLag), its first dip under the threshold
// (else the global minimum), refined by a parabola. Returns the period in samples (0: none) and its aperiodicity.
double yinPeriod(const float* x, int w, int minLag, int maxLag, std::vector<double>& d, double& aperiodicity) {
    d.assign(static_cast<size_t>(maxLag + 2), 0.0);
    for (int tau = 1; tau <= maxLag + 1; ++tau) {
        double s = 0;
        for (int i = 0; i < w; ++i) {
            const double v = static_cast<double>(x[i]) - x[i + tau];
            s += v * v;
        }
        d[static_cast<size_t>(tau)] = s;
    }
    double run = 0;
    d[0] = 1;
    for (int tau = 1; tau <= maxLag + 1; ++tau) {
        run += d[static_cast<size_t>(tau)];
        d[static_cast<size_t>(tau)] = run > 0 ? d[static_cast<size_t>(tau)] * tau / run : 1.0;
    }
    int best = -1;
    for (int tau = minLag; tau <= maxLag; ++tau) {
        if (d[static_cast<size_t>(tau)] < 0.15) {
            while (tau + 1 <= maxLag && d[static_cast<size_t>(tau + 1)] < d[static_cast<size_t>(tau)]) ++tau;
            best = tau;
            break;
        }
    }
    if (best < 0) {
        best = minLag;
        for (int tau = minLag; tau <= maxLag; ++tau)
            if (d[static_cast<size_t>(tau)] < d[static_cast<size_t>(best)]) best = tau;
    }
    aperiodicity = d[static_cast<size_t>(best)];
    const double a = d[static_cast<size_t>(best - 1)], b = d[static_cast<size_t>(best)], c = d[static_cast<size_t>(best + 1)];
    const double den = a - 2 * b + c;
    const double shift = std::fabs(den) > 1e-12 ? std::clamp(0.5 * (a - c) / den, -0.5, 0.5) : 0.0;
    return best + shift;
}

}  // namespace

RootResult detectRoot(const AudioAsset& a, int64_t from, int64_t to) {
    RootResult r;
    if (a.frames <= 0 || a.rate <= 0) return r;
    if (to <= 0 || to > a.frames) to = a.frames;
    from = std::clamp<int64_t>(from, 0, to);
    const double sr = a.rate;
    // The mono sum of [from, to), at most 1 s of it from just after its loudest attack.
    const float* L = a.channel(0);
    const float* R = a.channel(1);
    int64_t peakAt = from;
    float peak = 0;
    const int64_t search = std::min<int64_t>(to, from + static_cast<int64_t>(sr));
    for (int64_t i = from; i < search; ++i) {
        const float v = std::fabs(L[i] + R[i]);
        if (v > peak) {
            peak = v;
            peakAt = i;
        }
    }
    if (peak < 2e-4f) return r;
    const int64_t begin = std::min(to, peakAt + static_cast<int64_t>(0.03 * sr));
    const int64_t end = std::min(to, begin + static_cast<int64_t>(1.0 * sr));
    const int w = static_cast<int>(0.05 * sr);
    const int minLag = std::max(2, static_cast<int>(sr / 4200.0));
    const int maxLag = static_cast<int>(sr / 40.0);
    const int hop = static_cast<int>(0.025 * sr);
    std::vector<float> x(static_cast<size_t>(std::max<int64_t>(0, end - begin)));
    for (size_t i = 0; i < x.size(); ++i) x[i] = 0.5f * (L[begin + static_cast<int64_t>(i)] + R[begin + static_cast<int64_t>(i)]);
    const int64_t need = w + maxLag + 2;
    if (static_cast<int64_t>(x.size()) < need) return r;
    struct Frame { double midi, rms, ap; };
    std::vector<Frame> frames;
    std::vector<double> d;
    double loudest = 0;
    for (int64_t s = 0; s + need <= static_cast<int64_t>(x.size()) && frames.size() < 40; s += hop) {
        double e = 0;
        for (int i = 0; i < w; ++i) e += static_cast<double>(x[static_cast<size_t>(s + i)]) * x[static_cast<size_t>(s + i)];
        const double rms = std::sqrt(e / w);
        double ap = 1;
        const double period = yinPeriod(x.data() + s, w, minLag, maxLag, d, ap);
        frames.push_back({period > 0 ? hzToMidi(sr / period) : 0.0, rms, ap});
        loudest = std::max(loudest, rms);
    }
    std::vector<double> voiced;
    for (const Frame& f : frames)
        if (f.ap < 0.2 && f.rms > loudest * 0.01 && f.midi > 0) voiced.push_back(f.midi);
    if (voiced.empty()) return r;
    std::vector<double> sorted = voiced;
    std::sort(sorted.begin(), sorted.end());
    const double median = sorted[sorted.size() / 2];
    size_t agree = 0;
    for (double m : voiced) agree += std::fabs(m - median) < 0.5;
    r.midi = median;
    r.confidence = std::clamp(static_cast<double>(agree) / static_cast<double>(frames.size()), 0.0, 1.0);
    r.sure = agree >= 3 && 2 * agree >= frames.size() && median >= 0 && median <= 127;
    if (r.sure) {
        r.root = std::clamp(static_cast<int>(std::lround(median)), 0, 127);
        r.cents = (median - r.root) * 100.0;
    }
    return r;
}

void spreadByRoot(std::vector<SamplerZone>& zones) {
    std::map<std::pair<int, int>, std::vector<size_t>> layers;
    for (size_t i = 0; i < zones.size(); ++i) layers[{zones[i].lovel, zones[i].hivel}].push_back(i);
    for (auto& [vel, idx] : layers) {
        std::map<int, std::vector<size_t>> byRoot;
        for (size_t i : idx) byRoot[zones[i].root].push_back(i);
        std::vector<int> roots;
        for (auto& [root, _] : byRoot) roots.push_back(root);
        for (size_t k = 0; k < roots.size(); ++k) {
            const int lo = k == 0 ? 0 : (roots[k - 1] + roots[k] - 1) / 2 + 1;
            const int hi = k + 1 == roots.size() ? 127 : (roots[k] + roots[k + 1] - 1) / 2;
            const std::vector<size_t>& same = byRoot[roots[k]];
            for (size_t n = 0; n < same.size(); ++n) {
                SamplerZone& z = zones[same[n]];
                z.lokey = lo;
                z.hikey = hi;
                z.seqLength = same.size() > 1 ? static_cast<int>(std::min<size_t>(same.size(), 100)) : 1;
                z.seqPosition = same.size() > 1 ? static_cast<int>(std::min<size_t>(n + 1, 100)) : 1;
            }
        }
    }
}

std::vector<SamplerZone> mapSamples(const std::vector<MapInput>& in, MapMode mode, int startKey, MapMode* used) {
    std::vector<SamplerZone> out;
    const size_t n = std::min(in.size(), kMaxSamplerZones);
    if (mode == MapMode::Auto) {
        bool all = n > 0;
        for (size_t i = 0; i < n; ++i) all = all && in[i].root >= 0;
        mode = n <= 1 || all ? MapMode::Root : MapMode::Spread;
    }
    if (used) *used = mode;
    for (size_t i = 0; i < n; ++i) {
        SamplerZone z;
        z.path = in[i].path;
        z.root = in[i].root >= 0 ? std::clamp(in[i].root, 0, 127) : 60;
        z.tune = in[i].root >= 0 ? std::clamp(-in[i].cents, -100.0, 100.0) : 0.0;
        switch (mode) {
            case MapMode::Spread: {
                z.lokey = static_cast<int>(i * 128 / n);
                z.hikey = static_cast<int>((i + 1) * 128 / n) - 1;
                z.root = (z.lokey + z.hikey + 1) / 2;
                z.tune = 0;
                break;
            }
            case MapMode::Keys:
                z.lokey = z.hikey = z.root = std::clamp(startKey + static_cast<int>(i), 0, 127);
                z.tune = 0;
                break;
            default: break;
        }
        out.push_back(std::move(z));
    }
    if (mode == MapMode::Root) spreadByRoot(out);
    return out;
}

std::vector<SamplerZone> sliceZones(const std::string& path, const std::vector<int64_t>& cutsIn, int64_t frames,
                                    int startKey) {
    std::vector<int64_t> cuts{0};
    for (int64_t c : cutsIn)
        if (c > cuts.back() && c < frames) cuts.push_back(c);
    std::vector<SamplerZone> out;
    for (size_t i = 0; i < cuts.size(); ++i) {
        const int key = startKey + static_cast<int>(i);
        if (key > 127) break;
        SamplerZone z;
        z.path = path;
        z.lokey = z.hikey = z.root = std::max(0, key);
        z.offset = cuts[i];
        z.end = (i + 1 < cuts.size() ? cuts[i + 1] : frames) - 1;
        z.loopMode = LoopMode::OneShot;
        z.loopModeSet = true;
        out.push_back(std::move(z));
    }
    return out;
}

std::vector<SamplerZone> takeZones(const AudioAsset& a, const std::vector<TakeNote>& notes,
                                   std::vector<TakeNoteResult>& results) {
    results.clear();
    std::vector<SamplerZone> out;
    const double sr = a.rate;
    const double toFile = a.sourceRate > 0 ? a.sourceRate / sr : 1.0;  // asset frames to the file's own frames
    const float* L = a.channel(0);
    const float* R = a.channel(1);
    for (const TakeNote& n : notes) {
        TakeNoteResult res;
        res.key = n.key;
        const int64_t from = std::clamp<int64_t>(static_cast<int64_t>(n.startSeconds * sr), 0, a.frames);
        const int64_t to = std::clamp<int64_t>(static_cast<int64_t>(n.endSeconds * sr), from, a.frames);
        float peak = 0;
        for (int64_t i = from; i < to; ++i) peak = std::max(peak, std::max(std::fabs(L[i]), std::fabs(R[i])));
        if (peak >= 1e-3f) {
            int64_t on = from;
            while (on < to && std::max(std::fabs(L[on]), std::fabs(R[on])) < peak * 0.05f) ++on;
            on = std::max(from, on - static_cast<int64_t>(0.002 * sr));
            int64_t off = to - 1;
            while (off > on && std::max(std::fabs(L[off]), std::fabs(R[off])) < peak * 0.002f) --off;
            off = std::min(to - 1, off + static_cast<int64_t>(0.02 * sr));
            res.found = true;
            const RootResult root = detectRoot(a, on, off + 1);
            res.sure = root.sure;
            res.midi = root.sure ? root.midi : 0;
            res.start = static_cast<int64_t>(std::llround(static_cast<double>(on) * toFile));
            res.end = static_cast<int64_t>(std::llround(static_cast<double>(off) * toFile));
            SamplerZone z;
            z.path = a.path;
            z.root = std::clamp(n.key, 0, 127);
            z.lovel = n.lovel;
            z.hivel = n.hivel;
            z.offset = res.start;
            z.end = std::max(res.start + 1, res.end);
            out.push_back(std::move(z));
        }
        results.push_back(res);
    }
    spreadByRoot(out);
    return out;
}

// ---------------------------------------------------------------- JSON

namespace {

bool parseRequest(const char* text, Json& j, std::string& error) {
    if (!text) {
        error = "no request";
        return false;
    }
    const size_t len = std::strlen(text);
    if (len > kMaxRequestBytes) {
        error = "the request is over 64 KiB";
        return false;
    }
    if (!parseJson(std::string_view(text, len), j, error)) return false;
    if (j.type != Json::Type::Object) {
        error = "the request must be an object";
        return false;
    }
    return true;
}

bool wholeIn(const Json& j, const char* key, int lo, int hi, int fallback, int& out, std::string& error) {
    const double v = j.number(key, fallback);
    if (!std::isfinite(v) || v != std::floor(v) || v < lo || v > hi) {
        error = std::string(key) + " must be a whole number " + std::to_string(lo) + ".." + std::to_string(hi);
        return false;
    }
    out = static_cast<int>(v);
    return true;
}

bool realIn(const Json& j, const char* key, double lo, double hi, double fallback, double& out, std::string& error) {
    const double v = j.number(key, fallback);
    if (!std::isfinite(v) || v < lo || v > hi) {
        error = std::string(key) + " must be " + num(lo) + ".." + num(hi);
        return false;
    }
    out = v;
    return true;
}

std::string stateOf(const std::vector<SamplerZone>& zones) {
    SamplerProgram p;
    p.zones = zones;
    return samplerStateJson(p);
}

}  // namespace

std::string samplerMapJson(const char* request, double rate) {
    Json j;
    std::string error;
    if (!parseRequest(request, j, error)) return fail(error);
    const Json* samples = j.get("samples");
    if (!samples || samples->type != Json::Type::Array || samples->arr.empty() || samples->arr.size() > kMaxSamples)
        return fail("samples must be a list of 1.." + std::to_string(kMaxSamples));
    const std::string m = j.string("mode", "auto");
    MapMode mode;
    if (m == "auto") mode = MapMode::Auto;
    else if (m == "root") mode = MapMode::Root;
    else if (m == "spread") mode = MapMode::Spread;
    else if (m == "keys") mode = MapMode::Keys;
    else return fail("mode is auto, root, spread or keys");
    int startKey = 36;
    if (!wholeIn(j, "start_key", 0, 127, 36, startKey, error)) return fail(error);
    const bool detect = j.boolean("detect", true);
    std::vector<MapInput> in;
    std::vector<RootResult> found;
    for (size_t i = 0; i < samples->arr.size(); ++i) {
        const Json& s = samples->arr[i];
        const std::string where = "sample " + std::to_string(i);
        if (s.type != Json::Type::Object || s.string("path").empty()) return fail(where + " needs a \"path\"");
        MapInput mi;
        mi.path = s.string("path");
        RootResult rr;
        if (s.get("root") && s.get("root")->type != Json::Type::Null) {
            if (!wholeIn(s, "root", 0, 127, 60, mi.root, error)) return fail(where + ": " + error);
            rr.sure = true;
            rr.root = mi.root;
            rr.midi = mi.root;
        } else if (detect && mode != MapMode::Keys) {
            auto asset = AssetStore::global().load(mi.path, rate, error);
            if (!asset) return fail(where + ": " + error);
            rr = detectRoot(*asset);
            if (rr.sure) {
                mi.root = rr.root;
                mi.cents = rr.cents;
            }
        }
        in.push_back(mi);
        found.push_back(rr);
    }
    MapMode used = mode;
    const std::vector<SamplerZone> zones = mapSamples(in, mode, startKey, &used);
    static const char* kModes[] = {"auto", "root", "spread", "keys"};
    std::string s = "{\"ok\":true,\"error\":\"\",\"mode\":\"" + std::string(kModes[static_cast<int>(used)]) + "\",\"samples\":[";
    for (size_t i = 0; i < in.size(); ++i) {
        if (i) s += ",";
        s += "{\"path\":\"" + jsonEscape(in[i].path) + "\",\"sure\":" + (found[i].sure ? "true" : "false") +
             ",\"root\":" + (found[i].sure ? std::to_string(found[i].root) : "null") + ",\"midi\":" +
             (found[i].sure ? num(found[i].midi) : "null") + ",\"cents\":" + num(found[i].sure ? found[i].cents : 0) + "}";
    }
    return s + "],\"state\":" + stateOf(zones) + "}";
}

std::string samplerSliceJson(const char* path, const char* options, double rate) {
    if (!path || !*path) return fail("no path");
    Json j;
    std::string error;
    if (options && *options) {
        if (!parseRequest(options, j, error)) return fail(error);
    } else {
        j.type = Json::Type::Object;
    }
    const std::string by = j.string("by", "transients");
    if (by != "transients" && by != "grid") return fail("by is transients or grid");
    int startKey = 36, divisions = 16, maxSlices = 64;
    double sensitivity = 0.5, minGap = 0.05;
    if (!wholeIn(j, "start_key", 0, 127, 36, startKey, error) || !wholeIn(j, "divisions", 1, 128, 16, divisions, error) ||
        !wholeIn(j, "max_slices", 1, 128, 64, maxSlices, error) ||
        !realIn(j, "sensitivity", 0, 1, 0.5, sensitivity, error) ||
        !realIn(j, "min_gap_seconds", 0.005, 2, 0.05, minGap, error))
        return fail(error);
    auto a = AssetStore::global().load(path, rate, error);
    if (!a) return fail(error);
    const int64_t frames = a->sourceFrames > 0 ? a->sourceFrames : a->frames;
    std::vector<int64_t> cuts;
    if (by == "grid") {
        for (int i = 1; i < divisions; ++i) cuts.push_back(frames * i / divisions);
    } else {
        if (a->seconds() > kMaxAnalysisSeconds) return fail("the file is longer than 600 seconds");
        SliceOptions o;
        o.sensitivity = sensitivity;
        o.minGapSeconds = minGap;
        o.maxSlices = std::max(1, maxSlices - 1);
        for (const Slice& s : detectSlices(*a, o)) cuts.push_back(s.frame);
        std::sort(cuts.begin(), cuts.end());
    }
    const std::vector<SamplerZone> zones = sliceZones(path, cuts, frames, startKey);
    std::string s = "{\"ok\":true,\"error\":\"\",\"frames\":" + std::to_string(frames) + ",\"seconds\":" +
                    num(a->seconds()) + ",\"slices\":[";
    for (size_t i = 0; i < zones.size(); ++i)
        s += (i ? ",{\"start\":" : "{\"start\":") + std::to_string(zones[i].offset) + ",\"end\":" +
             std::to_string(zones[i].end + 1) + ",\"key\":" + std::to_string(zones[i].root) + "}";
    return s + "],\"state\":" + stateOf(zones) + "}";
}

std::string samplerTakeJson(const char* request, double rate) {
    Json j;
    std::string error;
    if (!parseRequest(request, j, error)) return fail(error);
    const std::string path = j.string("path");
    if (path.empty()) return fail("the request needs a \"path\"");
    const Json* notes = j.get("notes");
    if (!notes || notes->type != Json::Type::Array || notes->arr.empty() || notes->arr.size() > kMaxNotes)
        return fail("notes must be a list of 1.." + std::to_string(kMaxNotes));
    std::vector<TakeNote> plan;
    for (size_t i = 0; i < notes->arr.size(); ++i) {
        const Json& n = notes->arr[i];
        const std::string where = "note " + std::to_string(i) + ": ";
        if (n.type != Json::Type::Object) return fail(where + "must be an object");
        TakeNote t;
        if (!wholeIn(n, "key", 0, 127, -1, t.key, error) || !realIn(n, "start_seconds", 0, 7200, -1, t.startSeconds, error) ||
            !realIn(n, "end_seconds", 0, 7200, -1, t.endSeconds, error) || !wholeIn(n, "lovel", 1, 127, 1, t.lovel, error) ||
            !wholeIn(n, "hivel", 1, 127, 127, t.hivel, error))
            return fail(where + error);
        if (t.endSeconds <= t.startSeconds || t.lovel > t.hivel) return fail(where + "a low bound is above its high bound");
        plan.push_back(t);
    }
    auto a = AssetStore::global().load(path, rate, error);
    if (!a) return fail(error);
    std::vector<TakeNoteResult> res;
    const std::vector<SamplerZone> zones = takeZones(*a, plan, res);
    std::string s = "{\"ok\":true,\"error\":\"\",\"notes\":[";
    for (size_t i = 0; i < res.size(); ++i) {
        const TakeNoteResult& r = res[i];
        if (i) s += ",";
        s += "{\"key\":" + std::to_string(r.key) + ",\"found\":" + (r.found ? "true" : "false") + ",\"midi\":" +
             (r.sure ? num(r.midi) : "null") + ",\"in_tune\":" +
             (r.sure && std::fabs(r.midi - r.key) < 0.5 ? "true" : "false") + ",\"start\":" + std::to_string(r.start) +
             ",\"end\":" + std::to_string(r.end) + "}";
    }
    return s + "],\"state\":" + stateOf(zones) + "}";
}

}  // namespace caw
