// Export renders. Each one drives the same Engine as live playback, so files match what you heard bit for bit.
#include "render.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>

#include "builtin_components.h"
#include "component_test.h"
#include "engine.h"
#include "pattern.h"
#include "sample_time.h"
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

}  // namespace

// Every pattern a layer plays must parse, so an export never silently drops a broken one.
bool checkExportModules(const ProjectSpec& p, std::string& err) {
    for (const LayerSpec& l : p.layers) {
        if (l.pattern.empty()) continue;
        const ModuleSpec* m = p.module(l.pattern);
        PatternResult pr = m ? parsePattern(m->source) : PatternResult{};
        if (!pr.pattern) {
            err = "layer '" + l.name + "': " + (m ? "pattern '" + l.pattern + "': " + pr.error : "no pattern '" + l.pattern + "'");
            return false;
        }
    }
    return true;
}

namespace {

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
    const std::string projectResult = eng.setProjectOffline(p);
    if (projectResult.find("\"ok\":true") == std::string::npos) {
        error = "couldn't install project for offline export: " + projectResult;
        return false;
    }
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
    return static_cast<int64_t>(sampletime::roundFrames(steps, sampletime::stepFrames(sr, p.bpm)));
}

// Each frame's DC offset removed, then the whole table normalised to a peak of 1, into out.samples.
void finishWavetable(std::vector<double>& table, int frames, RenderResult& out) {
    for (int f = 0; f < frames; ++f) {
        double mean = 0;
        for (int i = 0; i < kWavetableFrame; ++i) mean += table[static_cast<size_t>(f) * kWavetableFrame + i];
        mean /= kWavetableFrame;
        for (int i = 0; i < kWavetableFrame; ++i) table[static_cast<size_t>(f) * kWavetableFrame + i] -= mean;
    }
    double peak = 0;
    for (double v : table) peak = std::max(peak, std::fabs(v));
    const double scale = peak > 0 ? 1.0 / peak : 0.0;
    for (size_t i = 0; i < table.size(); ++i) out.samples[i] = static_cast<float>(table[i] * scale);
}

// A C++ instrument's wavetable. The target is a layer with an instrument (played with the layer's values) or a
// built-in component's id. Each frame is a fresh instance holding A0 (MIDI 21, 27.5 Hz) at a sample rate of
// 27.5 * 2048, so one cycle of the note is one 2048-frame frame; the frame is the cycle after kWarmCycles, past
// the note's attack, as the mid of the instrument's output. With a param, frame f sets it to
// min + (max - min) * f / (frames - 1) (one frame: its default), constrained as the host constrains it. A
// component's saved state (a user wavetable, drum samples) isn't loaded: built-ins render their own sound.
constexpr int kWarmCycles = 3;
constexpr double kWavetableNoteHz = 27.5;  // A0

// The instrument a wavetable target names: a layer's (with its values), or else a built-in component's id.
TestComponent componentWavetableTarget(const ProjectSpec& p, const std::string& target) {
    TestComponent c;
    for (const LayerSpec& l : p.layers)
        if (l.id == target && l.hasInstrument && !l.folder) {
            c.id = l.instrument.id;
            c.params = l.instrument.params;
            return c;
        }
    c.id = target;
    return c;
}

bool renderComponentWavetable(TestComponent c, const ExportOptions& o, RenderResult& out, int32_t* progress,
                              int32_t* cancel) {
    ModuleRegistry registry;
    registerBuiltinComponents(registry);
    const ModuleDescriptor* d = registry.find(c.id);
    if (!d) {
        out.error = "no instrument layer or built-in component '" + o.target + "' to make a wavetable from";
        return false;
    }
    bool notesIn = false;
    for (uint32_t k = 0; k < d->portCount; ++k) notesIn = notesIn || (d->ports[k].type == PortType::Event && d->ports[k].input);
    if (!notesIn) {
        out.error = "component '" + c.id + "' takes no notes: a wavetable is made from an instrument";
        return false;
    }
    const ParameterDescriptor* swept = nullptr;
    for (uint32_t k = 0; k < d->parameterCount; ++k)
        if (d->parameters[k].id == o.param) swept = &d->parameters[k];
    if (!o.param.empty() && !swept) {
        out.error = "component '" + c.id + "' has no parameter '" + o.param + "'";
        return false;
    }
    const int frames = std::clamp(o.frames, 1, 256);
    out.channels = 1;
    out.sampleRate = o.sampleRate;
    out.frames = static_cast<int64_t>(frames) * kWavetableFrame;
    out.samples.assign(static_cast<size_t>(out.frames), 0.0f);
    std::vector<double> table(static_cast<size_t>(out.frames), 0.0);
    const double sr = kWavetableNoteHz * kWavetableFrame;
    const size_t length = static_cast<size_t>(kWarmCycles + 1) * kWavetableFrame;
    const std::vector<float> silence(length, 0.0f);
    const std::vector<TestNote> note = {{21, 127, 0, static_cast<double>(length) / sr + 1.0}};
    const size_t base = c.params.size();
    if (swept) c.params.push_back({o.param, swept->defaultValue});
    for (int f = 0; f < frames; ++f) {
        if (cancelled(cancel)) {
            out.error = "cancelled";
            return false;
        }
        if (swept)
            c.params[base].second = frames == 1 ? swept->defaultValue
                                                : swept->minimum + (swept->maximum - swept->minimum) * f / (frames - 1);
        ComponentRender r;
        if (!renderComponent(registry, c, sr, 64, 120, silence, silence, false, r, out.error, note)) return false;
        const size_t from = static_cast<size_t>(kWarmCycles) * kWavetableFrame;
        for (int i = 0; i < kWavetableFrame; ++i)
            table[static_cast<size_t>(f) * kWavetableFrame + i] = 0.5 * (static_cast<double>(r.left[from + i]) + r.right[from + i]);
        setProgress(progress, static_cast<double>(f + 1) / frames);
    }
    finishWavetable(table, frames, out);
    return true;
}

bool renderWavetable(const ProjectSpec& p, const ExportOptions& o, RenderResult& out, int32_t* progress,
                     int32_t* cancel) {
    return renderComponentWavetable(componentWavetableTarget(p, o.target), o, out, progress, cancel);
}

// The checks and project every export starts from (not wavetables, which render one instrument).
bool prepareExport(const ProjectSpec& in, const ExportOptions& o, ProjectSpec& p, std::string& error) {
    if (o.sampleRate < 8000 || o.sampleRate > 192000) {
        error = "sample rate must be 8000 to 192000";
        return false;
    }
    if (o.kind != ExportKind::Wavetable && !checkExportModules(in, error)) return false;
    p = in;
    p.auditionOnly = false;
    p.hasAuditionInstrument = false;
    p.auditionComponents.clear();
    return true;
}

// Loop and free exports: which frames of a render from the start they keep. A loop renders two loops and keeps
// the second: it starts with the first loop's seam crossfades, exactly as a loop sounds when it repeats. With the
// project's loop range on, the loop is that range: the render plays to the range's end, goes back to its start as
// playback does, and keeps that second pass.
void playedSpan(const ProjectSpec& p, const ExportOptions& o, int64_t& keepFrom, int64_t& total) {
    const int sr = o.sampleRate;
    if (o.kind == ExportKind::Loop && p.loopRange && p.loopEndSteps > p.loopStartSteps && p.loopEndSteps <= p.loopSteps()) {
        keepFrom = loopFrames(p, sr, p.loopEndSteps);
        total = keepFrom + keepFrom - loopFrames(p, sr, p.loopStartSteps);
    } else if (o.kind == ExportKind::Loop) {
        keepFrom = loopFrames(p, sr, p.loopSteps());
        total = 2 * keepFrom;
    } else {
        keepFrom = 0;
        total = static_cast<int64_t>(sampletime::roundFrames(std::clamp(o.seconds, 0.1, 600.0), sr));
    }
}

// A one-shot's silent end trimmed, keeping 5 ms after the last sound above -80 dB.
void trimSilentEnd(RenderResult& out, int sr) {
    int64_t last = -1;
    for (int64_t f = 0; f < out.frames; ++f)
        if (std::fabs(out.samples[static_cast<size_t>(f) * 2]) > 1e-4f ||
            std::fabs(out.samples[static_cast<size_t>(f) * 2 + 1]) > 1e-4f)
            last = f;
    const int64_t end = std::min<int64_t>(out.frames, last + 1 + sr / 200);
    out.frames = std::max<int64_t>(end, 1);
    out.samples.resize(static_cast<size_t>(out.frames) * 2);
}

// The one-shot of a C++ instrument layer with no notes of its own (no pattern, clips or length): its instrument and
// effects play one note (o.note, o.velocity, held o.noteSeconds) from the start, and the render runs on until the
// output has stayed below -80 dB for 0.25 s after the note's end (30 s at most), then the silent end is trimmed.
bool renderInstrumentNote(ProjectSpec& p, LayerSpec only, const ExportOptions& o, RenderResult& out, int32_t* progress,
                          int32_t* cancel) {
    const int sr = o.sampleRate;
    const int64_t most = static_cast<int64_t>(30) * sr;
    const double held = std::clamp(o.noteSeconds, 0.001, 29.0);
    const double steps = held * p.bpm * 4.0 / 60.0;
    const int stepsPerBar = p.beatsPerBar * 4;
    const int64_t mostSteps = static_cast<int64_t>(std::ceil(30.0 * p.bpm * 4.0 / 60.0));
    char line[96];
    std::snprintf(line, sizeof line, "0 %.17g %.17g %.17g\n", std::clamp(o.note, 0.0, 127.0), steps,
                  std::clamp(o.velocity, 0.0, 1.0));
    const std::string id = "\x01oneshot-note";
    p.modules.push_back({id, "---\nkind: pattern\nlength: " + std::to_string(mostSteps / stepsPerBar + 2) + " bars\n---\n" + line});
    p.loopBars = maxLoopBars(p.beatsPerBar);
    only.pattern = id;
    p.layers = {only};
    out.samples.clear();
    out.channels = 2;
    out.sampleRate = sr;
    const int64_t noteEnd = static_cast<int64_t>(std::ceil(held * sr));
    int64_t frame = 0, lastLoud = 0;
    bool finished = false;
    const bool ok = recordTo(p, sr, 0, most, [&](const float* lr, int n) {
        for (int i = 0; i < n; ++i, ++frame) {
            if (std::fabs(lr[i * 2]) > 1e-4f || std::fabs(lr[i * 2 + 1]) > 1e-4f) lastLoud = frame;
            out.samples.push_back(lr[i * 2]);
            out.samples.push_back(lr[i * 2 + 1]);
        }
        finished = frame > noteEnd && frame - std::max(lastLoud, noteEnd) > sr / 4;
        return !finished;
    }, out.error, progress, cancel);
    if (!ok && !finished) return false;
    out.error.clear();
    setProgress(progress, 1.0);
    out.frames = frame;
    trimSilentEnd(out, sr);
    return true;
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
            only.parentId.clear();  // its folder and send targets aren't in the render
            only.sends.clear();
            int64_t len;
            if (only.hasInstrument && !only.folder && only.pattern.empty() && only.clips.empty() && only.lengthSteps == 0)
                return renderInstrumentNote(p, only, o, out, progress, cancel);
            if (!only.clips.empty()) {
                // Its clips set the length: to the end of the last one.
                int64_t end = 0;
                for (const ClipSpec& c : only.clips) end = std::max<int64_t>(end, int64_t{c.startSteps} + c.lengthSteps);
                p.loopBars = maxLoopBars(p.beatsPerBar);  // the project loop never cuts the layer short
                len = loopFrames(p, sr, static_cast<int>(std::min<int64_t>(end, maxArrangementSteps(p.beatsPerBar))));
            } else if (!only.pattern.empty()) {
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
            trimSilentEnd(out, sr);
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
