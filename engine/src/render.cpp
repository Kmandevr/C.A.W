// Export renders. Each one drives the same Engine as live playback, so files match what you heard bit for bit.
#include "render.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>

#include "compile.h"
#include "engine.h"
#include "vm.h"

namespace caw {

namespace {

void setProgress(int32_t* p, double fraction) {
    if (p) std::atomic_ref<int32_t>(*p).store(static_cast<int32_t>(std::clamp(fraction, 0.0, 1.0) * 1000.0));
}

bool cancelled(int32_t* c) { return c && std::atomic_ref<int32_t>(*c).load() != 0; }

// Every module a render uses must compile, so an export never silently drops a broken one.
bool checkModules(const ProjectSpec& p, std::string& err) {
    for (const LayerSpec& l : p.layers)
        for (const std::string& id : l.chain) {
            const ModuleSpec* m = p.module(id);
            if (!m) {
                err = "layer '" + l.name + "' uses a missing module '" + id + "'";
                return false;
            }
            CompileResult r = compileModule(m->source);
            if (!r.program) {
                err = "module '" + id + "': " + r.error;
                return false;
            }
        }
    return true;
}

// Plays the project from the start and records `total` frames, keeping those from `keepFrom` on.
bool record(const ProjectSpec& p, int sr, int64_t keepFrom, int64_t total, RenderResult& out, int32_t* progress,
            int32_t* cancel) {
    Engine eng(sr);
    eng.setProject(p);
    eng.play();
    const int64_t keep = total - keepFrom;
    out.samples.assign(static_cast<size_t>(keep) * 2, 0.0f);
    out.channels = 2;
    out.sampleRate = sr;
    out.frames = keep;
    constexpr int kChunk = 512;
    float l[kChunk], r[kChunk];
    for (int64_t done = 0; done < total;) {
        if (cancelled(cancel)) {
            out.error = "cancelled";
            return false;
        }
        const int n = static_cast<int>(std::min<int64_t>(kChunk, total - done));
        eng.process(l, r, n);
        for (int i = 0; i < n; ++i) {
            const int64_t f = done + i - keepFrom;
            if (f < 0) continue;
            out.samples[static_cast<size_t>(f) * 2] = l[i];
            out.samples[static_cast<size_t>(f) * 2 + 1] = r[i];
        }
        done += n;
        if ((done & 0xFFFF) < kChunk) setProgress(progress, static_cast<double>(done) / total);
    }
    setProgress(progress, 1.0);
    return true;
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
    CompileResult cr = compileModule(m->source);
    if (!cr.program) {
        out.error = "module '" + o.target + "': " + cr.error;
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
    double tb[kBlock], ph[kBlock], zero[kBlock], srb[kBlock], bpmb[kBlock], seedb[kBlock];
    std::fill_n(zero, kBlock, 0.0);
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

}  // namespace

bool renderExport(const ProjectSpec& in, const ExportOptions& o, RenderResult& out, int32_t* progress,
                  int32_t* cancel) {
    out = RenderResult{};
    if (o.sampleRate < 8000 || o.sampleRate > 192000) {
        out.error = "sample rate must be 8000 to 192000";
        return false;
    }
    if (o.kind == ExportKind::Wavetable) return renderWavetable(in, o, out, progress, cancel);
    if (!checkModules(in, out.error)) return false;
    ProjectSpec p = in;
    p.auditionOnly = false;
    p.auditionChain.clear();
    const int sr = o.sampleRate;
    switch (o.kind) {
        case ExportKind::Loop: {
            // Render two loops and keep the second: it starts with the first loop's seam crossfades, exactly as a
            // loop sounds when it repeats.
            const int64_t len = loopFrames(p, sr, p.loopSteps());
            out.loop = true;
            return record(p, sr, len, 2 * len, out, progress, cancel);
        }
        case ExportKind::Free: {
            const double secs = std::clamp(o.seconds, 0.1, 600.0);
            return record(p, sr, 0, static_cast<int64_t>(std::floor(secs * sr + 0.5)), out, progress, cancel);
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
            if (only.lengthSteps > 0) {
                p.loopBars = 64;  // long enough that the project loop never cuts the layer short
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

}  // namespace caw
