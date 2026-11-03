// Mixer golden renders: multi-track projects (pan, folder buses, nesting, mute/solo, automation) hashed bit-exactly.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "capi_internal.h"
#include "engine.h"
#include "test.h"

using namespace caw;

namespace {

std::string templateSource(const char* file) {
    for (int i = 0; i < kTemplateCount; ++i)
        if (std::strcmp(kTemplateFiles[i], file) == 0) return kTemplateSources[i];
    return {};
}

LayerSpec track(const std::string& id, const std::string& module, double volume, double pan,
                const std::string& parent = {}) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.chain = {module};
    l.volume = volume;
    l.pan = pan;
    l.parentId = parent;
    return l;
}

LayerSpec folder(const std::string& id, double volume, double pan, const std::string& parent = {}) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.folder = true;
    l.busEnabled = true;
    l.volume = volume;
    l.pan = pan;
    l.parentId = parent;
    return l;
}

ProjectSpec base() {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 1;
    p.master = 0.8;
    p.seed = 7;
    for (const char* file : {"kick.caw", "hats.caw", "bass.caw", "acid-synth.caw", "wavetable-pad.caw"}) {
        std::string id(file);
        id.resize(id.size() - 4);
        p.modules.push_back({id, templateSource(file), {}});
    }
    return p;
}

// FNV-1a over the float bits of both channels, rendered in uneven blocks.
uint64_t render(const ProjectSpec& p, int64_t frames, float* peak = nullptr) {
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> l(256), r(256);
    uint64_t h = 1469598103934665603ull;
    auto mix = [&](float v) {
        uint32_t bits;
        std::memcpy(&bits, &v, sizeof bits);
        for (int b = 0; b < 4; ++b) { h ^= (bits >> (8 * b)) & 0xffu; h *= 1099511628211ull; }
    };
    const int blocks[] = {192, 64, 256, 37, 128};
    int64_t done = 0;
    for (int k = 0; done < frames; ++k) {
        const int n = static_cast<int>(std::min<int64_t>(blocks[k % 5], frames - done));
        e.process(l.data(), r.data(), n);
        for (int i = 0; i < n; ++i) {
            mix(l[static_cast<size_t>(i)]);
            mix(r[static_cast<size_t>(i)]);
            if (peak) *peak = std::max({*peak, std::fabs(l[static_cast<size_t>(i)]), std::fabs(r[static_cast<size_t>(i)])});
        }
        done += n;
    }
    return h;
}

struct Case { const char* name; ProjectSpec project; uint64_t hash; };

std::vector<Case> cases() {
    std::vector<Case> out;
    {
        ProjectSpec p = base();
        p.layers = {track("k", "kick", 0.9, 0.0), track("h", "hats", 0.6, -0.4), track("b", "bass", 0.7, 0.3)};
        out.push_back({"three tracks into master", p, 0xd65b12da92b57200ull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.2), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        out.push_back({"folder bus plus root track", p, 0xc36a58a5a2f3a05dull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("outer", 0.8, -0.2), folder("inner", 0.6, 0.4, "outer"),
                    track("k", "kick", 0.9, 0.0, "inner"), track("a", "acid-synth", 0.5, 0.1, "inner"),
                    track("h", "hats", 0.6, -0.5, "outer"), track("p", "wavetable-pad", 0.4, 0.0)};
        out.push_back({"nested folders", p, 0x6e9dc0675d64b5ddull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        p.layers[2].mute = true;
        p.layers[3].solo = true;
        p.layers[1].solo = true;
        out.push_back({"mute and solo across a folder", p, 0x52f9e405df9e92deull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("p", "wavetable-pad", 0.5, 0.0)};
        p.layers[0].automation = {{"volume", {{0, 0.1}, {8, 1.0}, {16, 0.3}}}, {"pan", {{0, -1.0}, {16, 1.0}}}};
        p.layers[3].automation = {{"pan", {{0, 1.0}, {12, -0.6}}}};
        out.push_back({"folder and track automation", p, 0xb847da2ce0d9fa0full});
    }
    {
        ProjectSpec p = base();
        p.master = 2.5;  // drives the safety limiter
        p.layers = {folder("all", 1.0, 0.0), track("k", "kick", 1.0, 0.0, "all"), track("b", "bass", 1.0, 0.0, "all"),
                    track("a", "acid-synth", 1.0, 0.0, "all")};
        out.push_back({"limiter driven through a bus", p, 0xcd5fad8550b7b2e7ull});
    }
    return out;
}

}  // namespace

// Guards the mixer's routing arithmetic: F4.3 moves it into the graph and must keep every hash.
TEST(multi_track_mixes_match_golden_renders) {
    const int64_t frames = 48000 * 2;  // two seconds: more than one 140 BPM bar, so the loop wraps
    for (const Case& c : cases()) {
        float peak = 0.0f;
        const uint64_t h = render(c.project, frames, &peak);
        if (!(peak > 0.01f)) cawtest::fail(__FILE__, __LINE__, std::string(c.name) + " renders silence");
        if (h != c.hash) {
            char buf[160];
            std::snprintf(buf, sizeof buf, "%s renders 0x%016llxull", c.name, static_cast<unsigned long long>(h));
            cawtest::fail(__FILE__, __LINE__, buf);
        }
        // Determinism: a second engine renders the same bits.
        CHECK_EQ(render(c.project, frames), h);
    }
}
