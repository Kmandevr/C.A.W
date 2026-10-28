// Measures the engine like a phone's audio callback does: time per callback, real-time load, compile and memory.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <functional>
#include <string>
#include <vector>

#include "capi_internal.h"
#include "compile.h"
#include "engine.h"
#include "project.h"
#include "render.h"

using namespace caw;
using Clock = std::chrono::steady_clock;

namespace {

constexpr int kRate = 48000;
constexpr int kCallback = 192;  // a common Android burst (AAudio low latency); the budget is 4 ms at 48 kHz

std::string tpl(const char* file) {
    for (int i = 0; i < kTemplateCount; ++i)
        if (std::strcmp(kTemplateFiles[i], file) == 0) return kTemplateSources[i];
    std::fprintf(stderr, "no template %s\n", file);
    std::exit(2);
}

long rssKb() {
    std::ifstream f("/proc/self/status");
    std::string line;
    while (std::getline(f, line))
        if (line.rfind("VmRSS:", 0) == 0) return std::atol(line.c_str() + 6);
    return -1;
}

void addLayer(ProjectSpec& p, const std::string& id, std::vector<std::string> chain, int steps = 16,
              const std::string& pattern = "") {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.chain = std::move(chain);
    l.lengthSteps = steps;
    l.pattern = pattern;
    l.volume = 0.5;
    p.layers.push_back(l);
}

ProjectSpec starter() {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 4;
    p.modules = {{"kick", tpl("kick.caw"), {}},       {"bass", tpl("bass.caw"), {}},
                 {"hats", tpl("hats.caw"), {}},       {"byte", tpl("bytebeat-loop.caw"), {}},
                 {"crush", tpl("bitcrush.caw"), {}}};
    addLayer(p, "kick", {"kick"});
    addLayer(p, "bass", {"bass"});
    addLayer(p, "hats", {"hats"});
    addLayer(p, "byte", {"byte", "crush"}, 48);
    return p;
}

ProjectSpec manyLayers(int n) {
    ProjectSpec p = starter();
    p.layers.clear();
    const char* gens[] = {"kick", "bass", "hats", "byte"};
    for (int i = 0; i < n; ++i) addLayer(p, "l" + std::to_string(i), {gens[i % 4]}, 16 * (1 + i % 3));
    return p;
}

ProjectSpec patterns() {
    ProjectSpec p;
    p.bpm = 128;
    p.loopBars = 4;
    p.modules = {{"synth", tpl("acid-synth.caw"), {}}, {"line", tpl("acid-line.caw"), {}},
                 {"chords", tpl("chords.caw"), {}}, {"synth2", tpl("acid-synth.caw"), {}}};
    addLayer(p, "acid", {"synth"}, 0, "line");
    addLayer(p, "pad", {"synth2"}, 0, "chords");
    return p;
}

ProjectSpec effects() {
    ProjectSpec p = starter();
    p.modules.push_back({"verb", "---\nkind: effect\nmode: float\n---\nfx.reverb(in, 0.8, 0.3, 0.3)", {}});
    p.modules.push_back({"echo", "---\nkind: effect\nmode: float\n---\nfx.delay(in, beats(0.75), 0.5, 0.3)", {}});
    for (LayerSpec& l : p.layers) l.chain.insert(l.chain.end(), {"echo", "verb"});
    return p;
}

struct Result {
    double meanUs = 0, p99Us = 0, maxUs = 0, load = 0;
};

// Plays `seconds` of audio in kCallback-frame callbacks; `each` runs between callbacks (control-thread work).
Result play(Engine& e, double seconds, const std::function<void(int)>& each = nullptr) {
    const int calls = static_cast<int>(seconds * kRate / kCallback);
    std::vector<float> l(kCallback), r(kCallback);
    std::vector<double> us;
    us.reserve(static_cast<size_t>(calls));
    for (int c = 0; c < calls; ++c) {
        if (each) each(c);
        const auto t0 = Clock::now();
        e.process(l.data(), r.data(), kCallback);
        us.push_back(std::chrono::duration<double, std::micro>(Clock::now() - t0).count());
    }
    Result res;
    for (double v : us) res.meanUs += v;
    res.meanUs /= static_cast<double>(us.size());
    std::sort(us.begin(), us.end());
    res.p99Us = us[us.size() * 99 / 100];
    res.maxUs = us.back();
    res.load = res.meanUs / (1e6 * kCallback / kRate);
    return res;
}

void report(const char* name, const Result& r) {
    std::printf("%-34s mean %8.1f us  p99 %8.1f us  max %8.1f us  load %6.2f%%\n", name, r.meanUs, r.p99Us,
                r.maxUs, 100.0 * r.load);
}

double ms(Clock::time_point a) { return std::chrono::duration<double, std::milli>(Clock::now() - a).count(); }

}  // namespace

int main(int argc, char** argv) {
    const double secs = argc > 1 ? std::atof(argv[1]) : 10.0;
    // `caw_bench SECONDS N` plays only playback scenario N (1-6), for exact instruction counts under callgrind.
    const int only = argc > 2 ? std::atoi(argv[2]) : 0;
    std::printf("callback %d frames at %d Hz (budget %.0f us); %.0f s per scenario\n", kCallback, kRate,
                1e6 * kCallback / kRate, secs);
    {
        Engine e(kRate);
        e.setProject(starter());
        report("stopped (starter project)", play(e, secs));
    }
    struct Case {
        const char* name;
        ProjectSpec p;
    };
    std::vector<Case> cases = {{"1 layer (bytebeat)", manyLayers(1)},
                               {"starter project (4 layers)", starter()},
                               {"16 layers", manyLayers(16)},
                               {"64 layers", manyLayers(64)},
                               {"pattern layers (acid + chords)", patterns()},
                               {"starter + delay + reverb each", effects()}};
    if (only > 0) {
        Case& c = cases[static_cast<size_t>(std::min<int>(only, static_cast<int>(cases.size())) - 1)];
        Engine e(kRate);
        e.setProject(c.p);
        e.play();
        report(c.name, play(e, secs));
        return 0;
    }
    for (Case& c : cases) {
        Engine e(kRate);
        const auto t0 = Clock::now();
        e.setProject(c.p);
        const double setMs = ms(t0);
        e.play();
        Result r = play(e, secs);
        report(c.name, r);
        std::printf("%-34s setProject %.1f ms\n", "", setMs);
    }
    {
        // Live editing: a code change every quarter second while 16 layers play; compile time is control-thread.
        Engine e(kRate);
        ProjectSpec p = manyLayers(16);
        e.setProject(p);
        e.play();
        double compileMs = 0;
        int swaps = 0;
        Result r = play(e, secs, [&](int c) {
            if (c % 62 != 0) return;
            p.modules[1].source = tpl("bass.caw") + "\n// edit " + std::to_string(c);
            const auto t0 = Clock::now();
            e.setProject(p);
            compileMs += ms(t0);
            ++swaps;
        });
        report("16 layers, code edit every 0.25 s", r);
        std::printf("%-34s %d swaps, setProject mean %.2f ms\n", "", swaps, compileMs / swaps);
    }
    {
        // Compile cost of each template, and of a project re-sent unchanged.
        for (int i = 0; i < kTemplateCount; ++i) {
            const auto t0 = Clock::now();
            int n = 0;
            for (; n < 50; ++n) compileModule(kTemplateSources[i]);
            std::printf("compile %-24s %.3f ms\n", kTemplateFiles[i], ms(t0) / n);
        }
        Engine e(kRate);
        ProjectSpec p = manyLayers(16);
        e.setProject(p);
        const auto t0 = Clock::now();
        for (int i = 0; i < 20; ++i) e.setProject(p);
        std::printf("setProject unchanged (16 layers)  %.3f ms\n", ms(t0) / 20);
    }
    {
        // Offline export speed, and memory with many layers.
        ProjectSpec p = manyLayers(16);
        ExportOptions o;
        RenderResult out;
        const auto t0 = Clock::now();
        renderExport(p, o, out);
        const double took = ms(t0);
        const double audio = 2.0 * out.frames / static_cast<double>(out.sampleRate);  // loop export renders 2 loops
        std::printf("loop export 16 layers: %.0f ms for %.2f s of audio (%.0fx real time)\n", took, audio,
                    audio * 1000.0 / took);
        const long before = rssKb();
        Engine e(kRate);
        e.setProject(manyLayers(64));
        std::printf("RSS: %ld kB before, %ld kB with 64 layers set up\n", before, rssKb());
    }
    return 0;
}
