// Song renders: the mix and aligned stems from one engine pass per range, through temporary float files, then
// normalised, dithered and written as WAV files named from a pattern.
#include "render_stems.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <set>

#include "engine.h"
#include "json.h"
#include "meters.h"
#include "render.h"
#include "sample_pack.h"
#include "sample_time.h"
#include "utf8_path.h"
#include "wav.h"

namespace caw {

namespace {

namespace fs = std::filesystem;

constexpr double kTwoPi = 6.283185307179586476925286766559;
constexpr int kChunk = 512;
constexpr size_t kMaxStems = 256;         // open temporary files stay well under every platform's limit
constexpr double kMaxTailSeconds = 600.0;  // a tail (or a silence search) is at most ten minutes
constexpr double kSilenceHoldSeconds = 0.5;
constexpr double kSilencePadSeconds = 0.01;

void atomicStore(int32_t* p, int32_t v) {
#if defined(__cpp_lib_atomic_ref)
    std::atomic_ref<int32_t>(*p).store(v);
#else
    __atomic_store_n(p, v, __ATOMIC_SEQ_CST);
#endif
}

int32_t atomicLoad(int32_t* p) {
#if defined(__cpp_lib_atomic_ref)
    return std::atomic_ref<int32_t>(*p).load();
#else
    return __atomic_load_n(p, __ATOMIC_SEQ_CST);
#endif
}

void setProgress(int32_t* p, double fraction) {
    if (p) atomicStore(p, static_cast<int32_t>(std::clamp(fraction, 0.0, 1.0) * 1000.0));
}

bool cancelled(int32_t* c) { return c && atomicLoad(c) != 0; }

double stepFrames(const ProjectSpec& p, int sr) { return sampletime::stepFrames(sr, p.bpm); }

// The frame a step starts on, as the engine places it (Engine::play and the loop export round the same way).
int64_t frameOf(const ProjectSpec& p, int sr, int64_t steps) {
    return static_cast<int64_t>(sampletime::roundFrames(static_cast<double>(steps), stepFrames(p, sr)));
}

double toDb(double linear) { return linear > 0 ? 20.0 * std::log10(linear) : -200.0; }

// The master's linear stage, as Engine::runMasterNode runs it on the summed mix: its volume, the 5 Hz DC filter
// and the 10 ms fade in when playback starts after the song's first frame. Run on a stem, the stems that reach the
// master add up to the mix (within float rounding) whenever the master has no effects and the limiter is idle.
struct MasterStage {
    double gain = 1, r = 0, xl = 0, yl = 0, xr = 0, yr = 0;
    int rampLeft = 0, rampLen = 1;
    void start(double master, int sr, bool rampIn) {
        gain = std::isfinite(master) ? std::clamp(master, 0.0, kMaxMixGain) : 0.0;
        r = 1.0 - kTwoPi * 5.0 / sr;
        xl = yl = xr = yr = 0;
        rampLen = std::max(1, static_cast<int>(0.01 * sr));
        rampLeft = rampIn ? rampLen : 0;
    }
    void run(float* l, float* rr, int n) {
        for (int i = 0; i < n; ++i) {
            const double a = (std::isfinite(l[i]) ? static_cast<double>(l[i]) : 0.0) * gain;
            const double b = (std::isfinite(rr[i]) ? static_cast<double>(rr[i]) : 0.0) * gain;
            const double ol = a - xl + r * yl, orr = b - xr + r * yr;
            xl = a, yl = ol, xr = b, yr = orr;
            double fade = 1.0;
            if (rampLeft > 0) fade = 1.0 - static_cast<double>(rampLeft--) / rampLen;
            l[i] = static_cast<float>(ol * fade);
            rr[i] = static_cast<float>(orr * fade);
        }
    }
};

struct Range {
    std::string region;  // "" unless the bounds are regions
    int64_t startSteps = 0, endSteps = 0;
};

struct StemPick {
    std::string id, name, kind;
};

// One file of a range: where it streams, and what was measured on the way.
struct Output {
    std::string kind, layer, stemName, finalName, finalPath, rawPath;
    bool write = true;  // the mix is always measured (stems take its gain) but written only when asked for
    std::FILE* raw = nullptr;
    std::vector<float> l, r;
    MasterStage master;
    double peak = 0;
    std::unique_ptr<LoudnessMeter> meter;
    double lufs = kMeterNone, truePeakDb = kMeterNone;
};

// {project} {stem} {region} {kind} {index} expanded, sanitised, with the separators an empty token leaves collapsed.
std::string expandName(const std::string& pattern, const std::string& project, const std::string& stem,
                       const std::string& region, const std::string& kind, size_t index) {
    std::string s;
    for (size_t i = 0; i < pattern.size(); ++i) {
        if (pattern[i] == '{') {
            const size_t close = pattern.find('}', i);
            if (close != std::string::npos) {
                const std::string token = pattern.substr(i + 1, close - i - 1);
                bool known = true;
                if (token == "project") s += project;
                else if (token == "stem") s += stem;
                else if (token == "region") s += region;
                else if (token == "kind") s += kind;
                else if (token == "index") s += std::to_string(index);
                else known = false;
                if (known) {
                    i = close;
                    continue;
                }
            }
        }
        s += pattern[i];
    }
    const std::string sane = sanitizeFileName(s);
    std::string out;
    for (char c : sane) {
        const bool sep = c == '_' || c == '-';
        if (sep && (out.empty() || out.back() == '_' || out.back() == '-')) continue;
        out += c;
    }
    while (!out.empty() && (out.back() == '_' || out.back() == '-' || out.back() == '.')) out.pop_back();
    return out.empty() ? "export" : sanitizeFileName(out);
}

std::string lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

bool pickStems(const ProjectSpec& p, const SongRenderRequest& req, std::vector<StemPick>& out, std::string& error) {
    auto pick = [](const LayerSpec& l) {
        return StemPick{l.id, l.name.empty() ? l.id : l.name, l.folder ? "bus" : "track"};
    };
    if (!req.layers.empty()) {
        for (const std::string& id : req.layers) {
            const auto it = std::find_if(p.layers.begin(), p.layers.end(), [&](const LayerSpec& l) { return l.id == id; });
            if (it == p.layers.end()) {
                error = "no layer '" + id + "' to render a stem of";
                return false;
            }
            if (it->folder && !it->busEnabled) {
                error = "'" + it->name + "' is a folder without a bus: it has no output of its own";
                return false;
            }
            if (std::none_of(out.begin(), out.end(), [&](const StemPick& s) { return s.id == id; })) out.push_back(pick(*it));
        }
    } else {
        for (const LayerSpec& l : p.layers) {
            const bool bus = l.folder && l.busEnabled;
            const bool track = !l.folder && l.hasInstrument;
            if ((bus && req.buses) || (track && req.tracks)) out.push_back(pick(l));
        }
    }
    if (out.size() > kMaxStems) {
        error = "at most " + std::to_string(kMaxStems) + " stems in one render";
        return false;
    }
    return true;
}

bool makeRanges(const ProjectSpec& p, const SongRenderRequest& req, std::vector<Range>& out, std::string& error) {
    const int64_t most = maxArrangementSteps(p.beatsPerBar);
    auto add = [&](const std::string& name, int64_t a, int64_t b) {
        a = std::clamp<int64_t>(a, 0, most);
        b = std::clamp<int64_t>(b, 0, most);
        if (b <= a) {
            error = (name.empty() ? std::string("the range") : "region '" + name + "'") + " is empty";
            return false;
        }
        out.push_back({name, a, b});
        return true;
    };
    switch (req.bounds) {
        case SongBounds::Song:
            return add("", 0, p.loopSteps());
        case SongBounds::Loop:
            if (p.loopRange && p.loopEndSteps > p.loopStartSteps) return add("", p.loopStartSteps, p.loopEndSteps);
            return add("", 0, p.loopSteps());
        case SongBounds::Selection:
            return add("", req.startSteps, req.endSteps);
        case SongBounds::Regions:
            if (req.regions.empty()) {
                error = "no regions to render";
                return false;
            }
            for (const SongRegion& r : req.regions)
                if (!add(r.name.empty() ? "Region" : r.name, r.startSteps, r.endSteps)) return false;
            return true;
    }
    return false;
}

void closeRaw(Output& o, bool remove) {
    if (o.raw) std::fclose(o.raw);
    o.raw = nullptr;
    if (remove && !o.rawPath.empty()) removeFile(o.rawPath);
}

// The gain (dB) normalisation gives an output measured at `peak` (linear), `lufs` and `truePeakDb`.
double normalGain(const SongRenderRequest& req, double peak, double lufs, double truePeakDb) {
    switch (req.normalize) {
        case SongNormalize::None:
            return 0.0;
        case SongNormalize::Peak:
            return peak > 0 ? req.target - toDb(peak) : 0.0;
        case SongNormalize::Lufs: {
            if (lufs <= kMeterNone) return 0.0;
            double g = req.target - lufs;
            if (req.ceiling <= 0 && truePeakDb > kMeterNone) g = std::min(g, req.ceiling - truePeakDb);
            return g;
        }
    }
    return 0.0;
}

// One range: renders it with every output streaming to its temporary file, then encodes each to its WAV.
bool renderRange(const ProjectSpec& base, const SongRenderRequest& req, const std::vector<StemPick>& stems,
                 const Range& range, size_t rangeIndex, size_t rangeCount, std::set<std::string>& usedNames,
                 SongRenderResult& out, int32_t* progress, int32_t* cancel) {
    const int sr = req.sampleRate;
    std::string& error = out.error;
    ProjectSpec p = base;
    p.loopRange = false;  // a render runs straight through its range, never back to a loop start
    const int64_t start = frameOf(p, sr, range.startSteps), end = frameOf(p, sr, range.endSteps);
    const int64_t length = end - start;
    const double tailSec = std::clamp(req.tailSeconds, 0.0, kMaxTailSeconds);
    const int64_t tailMost = req.tail == SongTail::None ? 0 : static_cast<int64_t>(sampletime::roundFrames(tailSec, sr));
    const int64_t total = length + tailMost;
    if (total > kMaxWavFrames) {
        error = "the render is " + std::to_string(total) + " frames, longer than a WAV file holds";
        return false;
    }
    // The song must reach past the range and its tail, or playback would go back to the start inside them. Clips and
    // patterns end where they end, so the tail is their notes' releases and the effects ringing out.
    const int64_t needSteps =
        range.endSteps + static_cast<int64_t>(std::ceil(static_cast<double>(tailMost) / stepFrames(p, sr)));
    if (needSteps > p.loopSteps()) {
        const int64_t bar = static_cast<int64_t>(p.beatsPerBar) * 4;
        p.loopBars = static_cast<int>(std::min<int64_t>(maxLoopBars(p.beatsPerBar), (needSteps + bar - 1) / bar));
    }

    std::vector<Output> outs(1 + stems.size());
    outs[0].kind = "mix";
    outs[0].write = req.mix;
    for (size_t i = 0; i < stems.size(); ++i) {
        outs[i + 1].kind = stems[i].kind;
        outs[i + 1].layer = stems[i].id;
        outs[i + 1].stemName = stems[i].name;
    }
    const bool lufs = req.normalize == SongNormalize::Lufs;
    auto cleanup = [&]() {
        for (Output& o : outs) closeRaw(o, true);
    };
    size_t index = out.files.size();
    for (Output& o : outs) {
        if (!o.write) continue;
        std::string name = expandName(req.pattern, req.project, o.stemName, range.region, o.kind, ++index);
        std::string unique = name;
        for (int n = 2; usedNames.count(lower(unique)) > 0; ++n) unique = name + "_" + std::to_string(n);
        usedNames.insert(lower(unique));
        o.finalName = unique + ".wav";
        o.finalPath = pathText(utf8Path(req.outDir) / utf8Path(o.finalName));
        std::error_code ec;
        if (fs::is_symlink(fs::symlink_status(utf8Path(o.finalPath), ec))) {
            error = "'" + o.finalName + "' in the output folder is a symbolic link; refusing to write through it";
            cleanup();
            return false;
        }
        o.rawPath = o.finalPath + ".raw.part";
        o.raw = openFile(utf8Path(o.rawPath), "wb");
        if (!o.raw) {
            error = "can't open " + o.rawPath + " for writing";
            cleanup();
            return false;
        }
    }
    for (size_t i = 0; i < outs.size(); ++i) {
        Output& o = outs[i];
        if (i > 0) {
            o.l.assign(kChunk, 0.0f);
            o.r.assign(kChunk, 0.0f);
        }
        if (i == 0 || (lufs && req.normalizeEach)) {
            o.meter = std::make_unique<LoudnessMeter>();
            o.meter->prepare(sr);
        }
    }

    Engine eng(sr);
    const std::string installed = eng.setProjectOffline(p);
    if (installed.find("\"ok\":true") == std::string::npos) {
        error = "couldn't install the project for the render: " + installed;
        cleanup();
        return false;
    }
    for (size_t i = 1; i < outs.size(); ++i) eng.setOutputTap(outs[i].layer, outs[i].l.data(), outs[i].r.data());
    eng.play(static_cast<double>(range.startSteps));
    const bool rampIn = start > 0 && start < eng.loopLength();
    for (size_t i = 1; i < outs.size(); ++i) outs[i].master.start(p.master, sr, rampIn);

    const float silence = static_cast<float>(std::pow(10.0, std::clamp(req.silenceDb, -200.0, 0.0) / 20.0));
    const int64_t hold = static_cast<int64_t>(kSilenceHoldSeconds * sr);
    int64_t lastLoud = -1, done = 0;
    float mixL[kChunk], mixR[kChunk], lr[kChunk * 2];
    const double share = 1.0 / static_cast<double>(rangeCount);
    while (done < total) {
        if (cancelled(cancel)) {
            error = "cancelled";
            cleanup();
            return false;
        }
        const int n = static_cast<int>(std::min<int64_t>(kChunk, total - done));
        for (size_t i = 1; i < outs.size(); ++i) {
            std::fill_n(outs[i].l.data(), n, 0.0f);
            std::fill_n(outs[i].r.data(), n, 0.0f);
        }
        eng.process(mixL, mixR, n);
        for (size_t i = 0; i < outs.size(); ++i) {
            Output& o = outs[i];
            float* l = i == 0 ? mixL : o.l.data();
            float* r = i == 0 ? mixR : o.r.data();
            if (i > 0 && req.stemsThroughMaster) o.master.run(l, r, n);
            for (int k = 0; k < n; ++k) {
                const float a = std::fabs(l[k]), b = std::fabs(r[k]);
                const float m = a > b ? a : b;
                if (m > o.peak) o.peak = m;
                if (m > silence) lastLoud = std::max(lastLoud, done + k);
            }
            if (o.meter) o.meter->process(l, r, n);
            if (o.raw) {
                for (int k = 0; k < n; ++k) {
                    lr[2 * k] = l[k];
                    lr[2 * k + 1] = r[k];
                }
                if (std::fwrite(lr, sizeof(float), static_cast<size_t>(n) * 2, o.raw) != static_cast<size_t>(n) * 2) {
                    error = "couldn't write " + o.rawPath + " (is the storage full?)";
                    cleanup();
                    return false;
                }
            }
        }
        done += n;
        if (req.tail == SongTail::Silence && done >= length && done - (lastLoud + 1) >= hold) break;
        if ((done & 0x3FFF) < kChunk)
            setProgress(progress, share * (static_cast<double>(rangeIndex) + 0.9 * static_cast<double>(done) / total));
    }
    eng.clearOutputTaps();

    int64_t frames = done;
    if (req.tail == SongTail::Silence)
        frames = std::min(done, std::max(length, lastLoud + 1 + static_cast<int64_t>(kSilencePadSeconds * sr)));
    for (Output& o : outs) {
        if (o.raw && std::fclose(o.raw) != 0) {
            o.raw = nullptr;
            error = "couldn't finish " + o.rawPath;
            cleanup();
            return false;
        }
        o.raw = nullptr;
        if (o.meter) {
            const LoudnessMeter::Reading m = o.meter->read();
            o.lufs = m.integrated;
            o.truePeakDb = m.truePeakMax;
        }
    }

    // The mix's gain goes on every file (the stems keep adding up to it) unless each stem is normalised alone.
    const double mixGain = normalGain(req, outs[0].peak, outs[0].lufs, outs[0].truePeakDb);
    size_t encoded = 0, toEncode = 0;
    for (const Output& o : outs) toEncode += o.write ? 1 : 0;
    std::vector<float> buf(4096 * 2);
    for (size_t i = 0; i < outs.size(); ++i) {
        Output& o = outs[i];
        if (!o.write) continue;
        const double gainDb = i == 0 || !req.normalizeEach ? mixGain : normalGain(req, o.peak, o.lufs, o.truePeakDb);
        const double g = std::pow(10.0, gainDb / 20.0);
        WavSpec spec;
        spec.sampleRate = sr;
        spec.channels = 2;
        spec.float32 = req.bitDepth == 32;
        spec.pcmBits = req.bitDepth == 16 ? 16 : 24;
        spec.dither = req.dither && req.bitDepth == 16;
        spec.ditherSeed = static_cast<uint32_t>(out.files.size() + 1);
        WavFileWriter wav;
        std::FILE* in = openFile(utf8Path(o.rawPath), "rb");
        if (!in || !wav.open(o.finalPath, spec, frames, error)) {
            if (in) std::fclose(in);
            if (error.empty()) error = "can't read back " + o.rawPath;
            cleanup();
            return false;
        }
        double peakOut = 0;
        for (int64_t at = 0; at < frames;) {
            if (cancelled(cancel)) {
                std::fclose(in);
                wav.abandon();
                error = "cancelled";
                cleanup();
                return false;
            }
            const size_t n = static_cast<size_t>(std::min<int64_t>(4096, frames - at));
            if (std::fread(buf.data(), sizeof(float), n * 2, in) != n * 2) {
                std::fclose(in);
                wav.abandon();
                error = "couldn't read back " + o.rawPath;
                cleanup();
                return false;
            }
            if (gainDb != 0.0)
                for (size_t k = 0; k < n * 2; ++k) buf[k] = static_cast<float>(static_cast<double>(buf[k]) * g);
            for (size_t k = 0; k < n * 2; ++k) peakOut = std::max(peakOut, static_cast<double>(std::fabs(buf[k])));
            if (!wav.write(buf.data(), static_cast<int64_t>(n))) break;  // finish() reports it
            at += static_cast<int64_t>(n);
        }
        std::fclose(in);
        if (!wav.finish(error)) {
            cleanup();
            return false;
        }
        removeFile(o.rawPath);
        o.rawPath.clear();
        RenderedFile f;
        f.path = o.finalPath;
        f.name = o.finalName;
        f.kind = o.kind;
        f.layer = o.layer;
        f.region = range.region;
        f.frames = frames;
        f.gainDb = gainDb;
        f.peakDb = toDb(peakOut);
        f.lufs = o.lufs > kMeterNone ? o.lufs + gainDb : -200.0;
        out.files.push_back(std::move(f));
        ++encoded;
        setProgress(progress, share * (static_cast<double>(rangeIndex) + 0.9 +
                                       0.1 * static_cast<double>(encoded) / static_cast<double>(toEncode)));
    }
    return true;
}

const char* kRequestKeys[] = {"out_dir", "project", "pattern", "mix", "tracks", "buses", "layers", "bounds",
                              "start_steps", "end_steps", "regions", "sample_rate", "bit_depth", "dither",
                              "normalize", "target", "ceiling", "normalize_each", "tail", "tail_seconds",
                              "silence_db", "stems_through_master"};

}  // namespace

bool parseSongRenderRequest(std::string_view json, SongRenderRequest& r, std::string& error) {
    Json j;
    if (!parseJson(json, j, error)) return false;
    if (j.type != Json::Type::Object) {
        error = "the render request must be a JSON object";
        return false;
    }
    for (const auto& [key, value] : j.obj)
        if (std::none_of(std::begin(kRequestKeys), std::end(kRequestKeys), [&](const char* k) { return key == k; })) {
            error = "unknown key '" + key + "' in the render request";
            return false;
        }
    r = SongRenderRequest{};
    r.outDir = j.string("out_dir");
    r.project = j.string("project", r.project);
    r.pattern = j.string("pattern", r.pattern);
    if (r.pattern.empty()) r.pattern = "{project}_{region}_{stem}";
    r.mix = j.boolean("mix", r.mix);
    r.tracks = j.boolean("tracks", r.tracks);
    r.buses = j.boolean("buses", r.buses);
    if (const Json* l = j.get("layers")) {
        if (l->type != Json::Type::Array) {
            error = "'layers' must be a list of layer ids";
            return false;
        }
        for (const Json& id : l->arr) {
            if (id.type != Json::Type::String) {
                error = "'layers' must be a list of layer ids";
                return false;
            }
            r.layers.push_back(id.str);
        }
    }
    const std::string bounds = j.string("bounds", "song");
    if (bounds == "song") r.bounds = SongBounds::Song;
    else if (bounds == "loop") r.bounds = SongBounds::Loop;
    else if (bounds == "selection") r.bounds = SongBounds::Selection;
    else if (bounds == "regions") r.bounds = SongBounds::Regions;
    else {
        error = "'bounds' must be song, loop, selection or regions";
        return false;
    }
    auto steps = [&](const Json& o, const char* key, int& out) {
        const double v = o.number(key, 0);
        if (!std::isfinite(v) || v < 0 || v > 2147483647.0 || v != std::floor(v)) {
            error = std::string("'") + key + "' must be a whole number of steps";
            return false;
        }
        out = static_cast<int>(v);
        return true;
    };
    if (!steps(j, "start_steps", r.startSteps) || !steps(j, "end_steps", r.endSteps)) return false;
    if (const Json* regions = j.get("regions")) {
        if (regions->type != Json::Type::Array || regions->arr.size() > 1024) {
            error = "'regions' must be a list of at most 1024 {\"name\", \"start_steps\", \"end_steps\"}";
            return false;
        }
        for (const Json& g : regions->arr) {
            if (g.type != Json::Type::Object) {
                error = "each region must be {\"name\", \"start_steps\", \"end_steps\"}";
                return false;
            }
            SongRegion reg;
            reg.name = g.string("name");
            if (!steps(g, "start_steps", reg.startSteps) || !steps(g, "end_steps", reg.endSteps)) return false;
            r.regions.push_back(std::move(reg));
        }
    }
    const double rate = j.number("sample_rate", r.sampleRate);
    if (rate != std::floor(rate) || rate < 8000 || rate > 192000) {
        error = "'sample_rate' must be 8000 to 192000";
        return false;
    }
    r.sampleRate = static_cast<int>(rate);
    const double bits = j.number("bit_depth", r.bitDepth);
    if (bits != 16 && bits != 24 && bits != 32) {
        error = "'bit_depth' must be 16, 24 or 32 (float)";
        return false;
    }
    r.bitDepth = static_cast<int>(bits);
    r.dither = j.boolean("dither", r.dither);
    const std::string norm = j.string("normalize", "none");
    if (norm == "none") r.normalize = SongNormalize::None;
    else if (norm == "peak") r.normalize = SongNormalize::Peak, r.target = -1.0;
    else if (norm == "lufs") r.normalize = SongNormalize::Lufs, r.target = -14.0;
    else {
        error = "'normalize' must be none, peak or lufs";
        return false;
    }
    r.target = j.number("target", r.target);
    r.ceiling = j.number("ceiling", r.ceiling);
    if (!std::isfinite(r.target) || r.target < -70 || r.target > 0 || !std::isfinite(r.ceiling) || r.ceiling < -70) {
        error = "'target' must be -70..0 and 'ceiling' at least -70";
        return false;
    }
    r.normalizeEach = j.boolean("normalize_each", r.normalizeEach);
    const std::string tail = j.string("tail", "none");
    if (tail == "none") r.tail = SongTail::None;
    else if (tail == "seconds") r.tail = SongTail::Seconds;
    else if (tail == "silence") r.tail = SongTail::Silence, r.tailSeconds = 30.0;
    else {
        error = "'tail' must be none, seconds or silence";
        return false;
    }
    r.tailSeconds = j.number("tail_seconds", r.tailSeconds);
    r.silenceDb = j.number("silence_db", r.silenceDb);
    if (!std::isfinite(r.tailSeconds) || r.tailSeconds < 0 || r.tailSeconds > kMaxTailSeconds ||
        !std::isfinite(r.silenceDb) || r.silenceDb < -200 || r.silenceDb > 0) {
        error = "'tail_seconds' must be 0..600 and 'silence_db' -200..0";
        return false;
    }
    r.stemsThroughMaster = j.boolean("stems_through_master", r.stemsThroughMaster);
    return true;
}

std::string songRenderResultJson(const SongRenderResult& r) {
    auto num = [](double v) {
        char b[32];
        std::snprintf(b, sizeof b, "%.3f", std::isfinite(v) ? v : -200.0);
        return std::string(b);
    };
    std::string s = std::string("{\"ok\":") + (r.error.empty() ? "true" : "false") + ",\"error\":\"" +
        jsonEscape(r.error) + "\",\"files\":[";
    for (size_t i = 0; i < r.files.size(); ++i) {
        const RenderedFile& f = r.files[i];
        if (i) s += ',';
        s += "{\"path\":\"" + jsonEscape(f.path) + "\",\"name\":\"" + jsonEscape(f.name) + "\",\"kind\":\"" + f.kind +
            "\",\"layer\":\"" + jsonEscape(f.layer) + "\",\"region\":\"" + jsonEscape(f.region) +
            "\",\"frames\":" + std::to_string(f.frames) + ",\"gain_db\":" + num(f.gainDb) + ",\"peak_db\":" +
            num(f.peakDb) + ",\"lufs\":" + num(f.lufs) + "}";
    }
    return s + "]}";
}

bool renderSong(const ProjectSpec& in, const SongRenderRequest& req, SongRenderResult& out, int32_t* progress,
                int32_t* cancel) {
    out = SongRenderResult{};
    std::error_code ec;
    if (req.outDir.empty() || !fs::is_directory(utf8Path(req.outDir), ec)) {
        out.error = "the output folder '" + req.outDir + "' doesn't exist";
        return false;
    }
    if (req.sampleRate < 8000 || req.sampleRate > 192000) {
        out.error = "sample rate must be 8000 to 192000";
        return false;
    }
    if (!req.mix && !req.tracks && !req.buses && req.layers.empty()) {
        out.error = "nothing to render: ask for the mix, stems or both";
        return false;
    }
    if (!checkExportModules(in, out.error)) return false;
    ProjectSpec p = in;
    p.auditionOnly = false;
    std::vector<StemPick> stems;
    std::vector<Range> ranges;
    if (!pickStems(p, req, stems, out.error) || !makeRanges(p, req, ranges, out.error)) return false;
    if (!req.mix && stems.empty()) {
        out.error = "the project has no tracks or buses to render stems of";
        return false;
    }
    std::set<std::string> used;
    for (size_t i = 0; i < ranges.size(); ++i) {
        if (!renderRange(p, req, stems, ranges[i], i, ranges.size(), used, out, progress, cancel)) {
            for (const RenderedFile& f : out.files) removeFile(f.path);  // all or nothing
            out.files.clear();
            if (out.error.empty()) out.error = "the render failed";
            return false;
        }
    }
    setProgress(progress, 1.0);
    return true;
}

}  // namespace caw
