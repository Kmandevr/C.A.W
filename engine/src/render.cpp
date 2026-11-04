// Export renders. Each one drives the same Engine as live playback, so files match what you heard bit for bit.
#include "render.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>

#include "compile.h"
#include "engine.h"
#include "pattern.h"
#include "vm.h"
#include "wav.h"

namespace caw {

namespace {

// The flags are plain ints shared with another thread (the app polls them). std::atomic_ref is missing from some
// standard libraries (the Android NDK's), so those use the compiler's atomic built-ins instead.
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

// The project's own libraries, as the engine loads them.
std::vector<LibrarySource> projectLibraries(const ProjectSpec& p) {
    std::vector<std::string_view> sources;
    for (const ModuleSpec& m : p.modules) sources.push_back(m.source);
    return caw::projectLibraries(sources);
}

// Every module a render uses must compile, so an export never silently drops a broken one.
bool checkModules(const ProjectSpec& p, std::string& err) {
    const std::vector<LibrarySource> libs = projectLibraries(p);
    for (const LayerSpec& l : p.layers) {
        if (l.pattern.empty()) continue;
        const ModuleSpec* m = p.module(l.pattern);
        PatternResult pr = m ? parsePattern(m->source) : PatternResult{};
        if (!pr.pattern) {
            err = "layer '" + l.name + "': " + (m ? "pattern '" + l.pattern + "': " + pr.error : "no pattern '" + l.pattern + "'");
            return false;
        }
    }
    for (const LayerSpec& l : p.layers)
        for (const std::string& id : l.chain) {
            const ModuleSpec* m = p.module(id);
            if (!m) {
                err = "layer '" + l.name + "' uses a missing module '" + id + "'";
                return false;
            }
            if (moduleKindOf(m->source) == ModuleKind::Library) continue;  // libraries don't play
            CompileResult r = compileModule(m->source, libs);
            if (!r.program) {
                err = "module '" + id + "': " + r.error;
                return false;
            }
        }
    return true;
}

// Refuses a render that a WAV file can't hold, before anything is allocated (songs run to the 32-bit step count).
bool fitsWav(int64_t frames, int sr, std::string& error) {
    if (frames <= kMaxWavFrames) return true;
    error = "the export is " + std::to_string(frames) + " frames, longer than a WAV file holds (" +
        std::to_string(kMaxWavFrames) + " frames, " + std::to_string(kMaxWavFrames / sr / 60) + " minutes at " +
        std::to_string(sr) + " Hz); export a shorter loop";
    return false;
}

// Plays the project from the start for `total` frames and hands those from `keepFrom` on to `sink`, interleaved,
// a chunk at a time. A sink returning false stops the render.
template <class Sink>
bool recordTo(const ProjectSpec& p, int sr, int64_t keepFrom, int64_t total, Sink&& sink, std::string& error,
              int32_t* progress, int32_t* cancel) {
    Engine eng(sr);
    eng.setProject(p);
    eng.play();
    constexpr int kChunk = 512;
    float l[kChunk], r[kChunk], lr[kChunk * 2];
    for (int64_t done = 0; done < total;) {
        if (cancelled(cancel)) {
            error = "cancelled";
            return false;
        }
        const int n = static_cast<int>(std::min<int64_t>(kChunk, total - done));
        eng.process(l, r, n);
        int kept = 0;
        for (int i = 0; i < n; ++i) {
            if (done + i < keepFrom) continue;
            lr[kept * 2] = l[i];
            lr[kept * 2 + 1] = r[i];
            ++kept;
        }
        if (kept > 0 && !sink(lr, kept)) {
            if (error.empty()) error = "couldn't write the export";
            return false;
        }
        done += n;
        if ((done & 0xFFFF) < kChunk) setProgress(progress, static_cast<double>(done) / total);
    }
    setProgress(progress, 1.0);
    return true;
}

// recordTo into memory.
bool record(const ProjectSpec& p, int sr, int64_t keepFrom, int64_t total, RenderResult& out, int32_t* progress,
            int32_t* cancel) {
    const int64_t keep = total - keepFrom;
    if (!fitsWav(keep, sr, out.error)) return false;
    out.samples.clear();
    out.samples.reserve(static_cast<size_t>(keep) * 2);
    out.channels = 2;
    out.sampleRate = sr;
    out.frames = keep;
    return recordTo(p, sr, keepFrom, total, [&](const float* lr, int n) {
        out.samples.insert(out.samples.end(), lr, lr + static_cast<size_t>(n) * 2);
        return true;
    }, out.error, progress, cancel);
}

int64_t loopFrames(const ProjectSpec& p, int sr, int steps) {
    const double stepLen = 60.0 * sr / (p.bpm * 4.0);
    return static_cast<int64_t>(std::floor(steps * stepLen + 0.5));
}

bool renderWavetable(const ProjectSpec& p, const ExportOptions& o, RenderResult& out, int32_t* progress,
                     int32_t* cancel) {
    const ModuleSpec* m = p.module(o.target);
    if (!m) {
        out.error = "no module '" + o.target + "' to make a wavetable from";
        return false;
    }
    CompileResult cr = compileModule(m->source, projectLibraries(p));
    if (!cr.program || cr.program->kind == ModuleKind::Library) {
        out.error = "module '" + o.target + "': " + (cr.program ? std::string("a library doesn't make sound") : cr.error);
        return false;
    }
    const Program& prog = *cr.program;
    int paramIdx = -1;
    for (size_t i = 0; i < prog.params.size(); ++i)
        if (prog.params[i].name == o.param) paramIdx = static_cast<int>(i);
    if (!o.param.empty() && paramIdx < 0) {
        out.error = "module '" + o.target + "' has no param '" + o.param + "'";
        return false;
    }
    const int frames = std::clamp(o.frames, 1, 256);
    out.channels = 1;
    out.sampleRate = o.sampleRate;
    out.frames = static_cast<int64_t>(frames) * kWavetableFrame;
    out.samples.assign(static_cast<size_t>(out.frames), 0.0f);
    std::vector<double> table(static_cast<size_t>(out.frames), 0.0);

    // One frame is one cycle: t and n run 0..2047, phase and pos 0..1, and sr is 2048, so sine(1) is one cycle.
    double tb[kBlock], ph[kBlock], zero[kBlock], srb[kBlock], bpmb[kBlock], seedb[kBlock], ones[kBlock], first[kBlock],
        c4[kBlock];
    std::fill_n(zero, kBlock, 0.0);
    std::fill_n(ones, kBlock, 1.0);
    std::fill_n(first, kBlock, 0.0);
    first[0] = 1.0;
    std::fill_n(c4, kBlock, 60.0);
    std::fill_n(srb, kBlock, static_cast<double>(kWavetableFrame));
    std::fill_n(bpmb, kBlock, p.bpm);
    std::fill_n(seedb, kBlock, static_cast<double>(p.seed));
    for (int f = 0; f < frames; ++f) {
        if (cancelled(cancel)) {
            out.error = "cancelled";
            return false;
        }
        Instance inst(cr.program);
        for (size_t i = 0; i < prog.params.size(); ++i) {
            auto it = m->params.find(prog.params[i].name);
            if (it != m->params.end()) inst.setParam(static_cast<int>(i), it->second);
        }
        if (paramIdx >= 0) {
            const ParamDef& d = prog.params[static_cast<size_t>(paramIdx)];
            const double v = frames == 1 ? d.def : d.min + (d.max - d.min) * f / (frames - 1);
            inst.setParam(paramIdx, v);
        }
        BlockCtx ctx;
        ctx.keyRoot = p.keyRoot;
        ctx.keyScale = p.keyScale;
        ctx.sr = kWavetableFrame;
        ctx.bpm = p.bpm;
        ctx.seed = p.seed;
        for (int b = 0; b < kWavetableFrame; b += kBlock) {
            ctx.n = kBlock;
            for (int i = 0; i < kBlock; ++i) {
                tb[i] = b + i;
                ph[i] = (b + i) / static_cast<double>(kWavetableFrame);
            }
            ctx.vars[static_cast<int>(Var::T)] = tb;
            ctx.vars[static_cast<int>(Var::Rate)] = srb;
            ctx.vars[static_cast<int>(Var::Sr)] = srb;
            ctx.vars[static_cast<int>(Var::Bpm)] = bpmb;
            ctx.vars[static_cast<int>(Var::Seed)] = seedb;
            ctx.vars[static_cast<int>(Var::Pos)] = ph;
            ctx.vars[static_cast<int>(Var::Phase)] = ph;
            ctx.vars[static_cast<int>(Var::Time)] = ph;
            ctx.vars[static_cast<int>(Var::In)] = zero;
            ctx.vars[static_cast<int>(Var::Step)] = zero;
            ctx.vars[static_cast<int>(Var::Beat)] = zero;
            ctx.vars[static_cast<int>(Var::Bar)] = zero;
            // One held note whose frequency is one cycle per frame, so sine(freq) is a single cycle.
            ctx.vars[static_cast<int>(Var::Trig)] = b == 0 ? first : zero;
            ctx.vars[static_cast<int>(Var::Gate)] = ones;
            ctx.vars[static_cast<int>(Var::Note)] = c4;
            ctx.vars[static_cast<int>(Var::Freq)] = ones;
            ctx.vars[static_cast<int>(Var::Vel)] = ones;
            ctx.vars[static_cast<int>(Var::Rel)] = zero;
            ctx.vars[static_cast<int>(Var::Bend)] = zero;
            ctx.vars[static_cast<int>(Var::Press)] = ones;
            ctx.vars[static_cast<int>(Var::Timbre)] = zero;
            const double* y = inst.process(ctx);
            for (int i = 0; i < kBlock; ++i) table[static_cast<size_t>(f) * kWavetableFrame + b + i] = y[i];
        }
        // Remove each frame's DC offset so the table is centred.
        double mean = 0;
        for (int i = 0; i < kWavetableFrame; ++i) mean += table[static_cast<size_t>(f) * kWavetableFrame + i];
        mean /= kWavetableFrame;
        for (int i = 0; i < kWavetableFrame; ++i) table[static_cast<size_t>(f) * kWavetableFrame + i] -= mean;
        setProgress(progress, static_cast<double>(f + 1) / frames);
    }
    double peak = 0;
    for (double v : table) peak = std::max(peak, std::fabs(v));
    const double scale = peak > 0 ? 1.0 / peak : 0.0;
    for (size_t i = 0; i < table.size(); ++i) out.samples[i] = static_cast<float>(table[i] * scale);
    return true;
}

// The checks and project every export starts from (not wavetables, which compile one module).
bool prepareExport(const ProjectSpec& in, const ExportOptions& o, ProjectSpec& p, std::string& error) {
    if (o.sampleRate < 8000 || o.sampleRate > 192000) {
        error = "sample rate must be 8000 to 192000";
        return false;
    }
    if (o.kind != ExportKind::Wavetable && !checkModules(in, error)) return false;
    p = in;
    p.auditionOnly = false;
    p.auditionChain.clear();
    return true;
}

// Loop and free exports: which frames of a render from the start they keep. A loop renders two loops and keeps
// the second: it starts with the first loop's seam crossfades, exactly as a loop sounds when it repeats.
void playedSpan(const ProjectSpec& p, const ExportOptions& o, int64_t& keepFrom, int64_t& total) {
    const int sr = o.sampleRate;
    if (o.kind == ExportKind::Loop) {
        keepFrom = loopFrames(p, sr, p.loopSteps());
        total = 2 * keepFrom;
    } else {
        keepFrom = 0;
        total = static_cast<int64_t>(std::floor(std::clamp(o.seconds, 0.1, 600.0) * sr + 0.5));
    }
}

}  // namespace

bool renderExport(const ProjectSpec& in, const ExportOptions& o, RenderResult& out, int32_t* progress,
                  int32_t* cancel) {
    out = RenderResult{};
    ProjectSpec p;
    if (!prepareExport(in, o, p, out.error)) return false;
    if (o.kind == ExportKind::Wavetable) return renderWavetable(in, o, out, progress, cancel);
    const int sr = o.sampleRate;
    switch (o.kind) {
        case ExportKind::Loop:
        case ExportKind::Free: {
            int64_t keepFrom = 0, total = 0;
            playedSpan(p, o, keepFrom, total);
            out.loop = o.kind == ExportKind::Loop;
            return record(p, sr, keepFrom, total, out, progress, cancel);
        }
        case ExportKind::OneShot: {
            const LayerSpec* layer = nullptr;
            for (const LayerSpec& l : p.layers)
                if (l.id == o.target) layer = &l;
            if (!layer) {
                out.error = "no layer '" + o.target + "' to export";
                return false;
            }
            LayerSpec only = *layer;
            only.mute = false;
            only.solo = false;
            int64_t len;
            if (!only.pattern.empty()) {
                // A pattern sets the layer's length.
                p.loopBars = maxLoopBars(p.beatsPerBar);  // the project loop never cuts the layer short
                len = loopFrames(p, sr, parsePattern(p.module(only.pattern)->source).pattern->steps(p.beatsPerBar));
            } else if (only.lengthSteps > 0) {
                p.loopBars = maxLoopBars(p.beatsPerBar);  // the project loop never cuts the layer short
                len = loopFrames(p, sr, only.lengthSteps);
            } else {
                len = loopFrames(p, sr, p.loopSteps());
            }
            len = std::min<int64_t>(len, static_cast<int64_t>(30) * sr);
            p.layers = {only};
            if (!record(p, sr, 0, len, out, progress, cancel)) return false;
            // Trim the silent end, keeping 5 ms after the last sound above -80 dB.
            int64_t last = -1;
            for (int64_t f = 0; f < out.frames; ++f)
                if (std::fabs(out.samples[static_cast<size_t>(f) * 2]) > 1e-4f ||
                    std::fabs(out.samples[static_cast<size_t>(f) * 2 + 1]) > 1e-4f)
                    last = f;
            const int64_t end = std::min<int64_t>(out.frames, last + 1 + sr / 200);
            out.frames = std::max<int64_t>(end, 1);
            out.samples.resize(static_cast<size_t>(out.frames) * 2);
            return true;
        }
        case ExportKind::Wavetable:
            break;
    }
    return false;
}

bool renderExportToWav(const ProjectSpec& in, const ExportOptions& o, const std::string& path, bool float32,
                       std::string& error, int32_t* progress, int32_t* cancel) {
    error.clear();
    WavSpec spec;
    spec.sampleRate = o.sampleRate;
    spec.channels = 2;
    spec.float32 = float32 || o.kind == ExportKind::Wavetable;
    if (o.kind == ExportKind::Loop || o.kind == ExportKind::Free) {
        ProjectSpec p;
        if (!prepareExport(in, o, p, error)) return false;
        int64_t keepFrom = 0, total = 0;
        playedSpan(p, o, keepFrom, total);
        if (!fitsWav(total - keepFrom, o.sampleRate, error)) return false;
        spec.loop = o.kind == ExportKind::Loop;
        WavFileWriter wav;
        if (!wav.open(path, spec, total - keepFrom, error)) return false;
        if (!recordTo(p, o.sampleRate, keepFrom, total, [&](const float* lr, int n) { return wav.write(lr, n); },
                      error, progress, cancel)) {
            wav.abandon();
            return false;
        }
        return wav.finish(error);
    }
    RenderResult r;
    if (!renderExport(in, o, r, progress, cancel)) {
        error = r.error;
        return false;
    }
    spec.sampleRate = r.sampleRate;
    spec.channels = r.channels;
    spec.loop = r.loop;
    return writeFile(path, encodeWav(spec, r.samples.data(), r.frames), error);
}

}  // namespace caw
