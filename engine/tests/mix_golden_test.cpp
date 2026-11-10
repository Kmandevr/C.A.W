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

// FNV-1a over the float bits of both channels, rendered in uneven blocks. With `next`, that
// project replaces the first one (a live code swap) once `swapAt` frames have played.
uint64_t render(const ProjectSpec& p, int64_t frames, float* peak = nullptr, const ProjectSpec* next = nullptr,
                int64_t swapAt = 0) {
    Engine e(48000);
    e.setProject(p);
    e.play();
    bool swapped = next == nullptr;
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
        if (!swapped && done >= swapAt) {
            e.setProject(*next);
            swapped = true;
        }
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

// The same templates plus effects and patterns, for tracks that run several modules (F4.4).
ProjectSpec withEffects() {
    ProjectSpec p = base();
    for (const char* file : {"fold.caw", "glitch-fx.caw", "bitcrush.caw", "bytebeat-loop.caw", "acid-line.caw", "chords.caw"}) {
        std::string id(file);
        id.resize(id.size() - 4);
        p.modules.push_back({id, templateSource(file), {}});
    }
    return p;
}

LayerSpec chainTrack(const std::string& id, std::vector<std::string> chain, double volume, double pan,
                     const std::string& parent = {}) {
    LayerSpec l = track(id, chain.front(), volume, pan, parent);
    l.chain = std::move(chain);
    return l;
}

struct Case { const char* name; ProjectSpec project; uint64_t hash; float minPeak = 0.01f; };

std::vector<Case> cases() {
    std::vector<Case> out;
    {
        ProjectSpec p = base();
        p.layers = {track("k", "kick", 0.9, 0.0), track("h", "hats", 0.6, -0.4), track("b", "bass", 0.7, 0.3)};
        out.push_back({"three tracks into master", p, 0x45214f636391b586ull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.2), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        out.push_back({"folder bus plus root track", p, 0xa2657bbd13342b4dull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("outer", 0.8, -0.2), folder("inner", 0.6, 0.4, "outer"),
                    track("k", "kick", 0.9, 0.0, "inner"), track("a", "acid-synth", 0.5, 0.1, "inner"),
                    track("h", "hats", 0.6, -0.5, "outer"), track("p", "wavetable-pad", 0.4, 0.0)};
        out.push_back({"nested folders", p, 0xc383e0666b2ac970ull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        p.layers[2].mute = true;
        p.layers[3].solo = true;
        p.layers[1].solo = true;
        out.push_back({"mute and solo across a folder", p, 0x3c96c3a9b07d665full});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("p", "wavetable-pad", 0.5, 0.0)};
        p.layers[0].automation = {{"volume", {{0, 0.1}, {8, 1.0}, {16, 0.3}}}, {"pan", {{0, -1.0}, {16, 1.0}}}};
        p.layers[3].automation = {{"pan", {{0, 1.0}, {12, -0.6}}}};
        out.push_back({"folder and track automation", p, 0xdfa84bb2309418a1ull});
    }
    {
        // Mute alone: the muted child drops out and its sibling and the root track keep playing.
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        p.layers[1].mute = true;
        out.push_back({"mute only inside a folder", p, 0xbfc1ad829219773cull});
    }
    {
        // Solo of one child: its unmuted, non-soloed sibling and the root track fall silent.
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        p.layers[1].solo = true;
        out.push_back({"solo of one child silences its sibling", p, 0x19de80e173f6131bull});
    }
    {
        ProjectSpec p = base();
        p.master = 2.5;  // drives the safety limiter
        p.layers = {folder("all", 1.0, 0.0), track("k", "kick", 1.0, 0.0, "all"), track("b", "bass", 1.0, 0.0, "all"),
                    track("a", "acid-synth", 1.0, 0.0, "all")};
        // The limiter must actually engage: the peak sits at its ceiling, far above the unlimited
        // level of these tracks, but never above 1.
        out.push_back({"limiter driven through a bus", p, 0xec107bbe489b1a5bull, 0.9f});
    }
    {
        // Each module of a chain is its own graph node, joined by float edges.
        ProjectSpec p = withEffects();
        p.layers = {chainTrack("b", {"bass", "fold", "glitch-fx"}, 0.7, 0.2), chainTrack("k", {"kick", "bitcrush"}, 0.8, 0.0)};
        out.push_back({"effect chains on tracks", p, 0xde088443ea8ae328ull});
    }
    {
        // Short, odd loop lengths: the shadow lane crossfades every seam, mid-block and through effects.
        ProjectSpec p = withEffects();
        p.layers = {chainTrack("y", {"bytebeat-loop", "fold"}, 0.6, -0.3), chainTrack("h", {"hats", "glitch-fx"}, 0.6, 0.4)};
        p.layers[0].lengthSteps = 3;
        p.layers[1].lengthSteps = 5;
        out.push_back({"short loops crossfade at every seam", p, 0xe988dd6f153178b3ull});
    }
    {
        // Pattern layers: voices on the first node, effects after, inside a folder bus.
        ProjectSpec p = withEffects();
        p.layers = {folder("keys", 0.8, 0.0), chainTrack("a", {"acid-synth", "glitch-fx"}, 0.6, -0.2, "keys"),
                    chainTrack("c", {"wavetable-pad", "bitcrush", "fold"}, 0.4, 0.3, "keys")};
        p.layers[1].pattern = "acid-line";
        p.layers[2].pattern = "chords";
        out.push_back({"pattern synths through effect chains", p, 0x3eebef32c77d49b9ull});
    }
    {
        // The Library's built-in native effects (#121) in track and master chains, tempo-synced delay included.
        ProjectSpec p = withEffects();
        p.layers = {chainTrack("b", {"bass"}, 0.7, 0.2), chainTrack("a", {"acid-synth"}, 0.6, -0.3)};
        p.layers[1].pattern = "acid-line";
        p.layers[0].components = {{"org.caw.distortion", {{"shape", 0}, {"drive", 6}, {"mix", 0.7}}},
                                  {"org.caw.stereo.width", {{"width", 1.6}}}};
        p.layers[1].components = {{"org.caw.chorus", {{"rate", 0.8}, {"depth", 0.6}}},
                                  {"org.caw.delay.pingpong", {{"sync", 3}, {"feedback", 0.5}, {"mix", 0.4}}},
                                  {"org.caw.stereo.balance", {{"pan", 0.2}}}};
        p.masterComponents = {{"org.caw.distortion", {{"shape", 3}, {"bits", 12}, {"mix", 0.3}}}};
        out.push_back({"built-in library effects on tracks and the master", p, 0x145ddd83b6c52ab7ull});
    }
    return out;
}

}  // namespace

// Guards the mixer's routing arithmetic and each track's module chain, all run by the one graph.
TEST(multi_track_mixes_match_golden_renders) {
    const int64_t frames = 48000 * 2;  // two seconds: more than one 140 BPM bar, so the loop wraps
    for (const Case& c : cases()) {
        float peak = 0.0f;
        const uint64_t h = render(c.project, frames, &peak);
        if (!(peak > c.minPeak)) cawtest::fail(__FILE__, __LINE__, std::string(c.name) + " peak too low");
        CHECK(peak <= 1.0f);
        if (h != c.hash) {
            char buf[160];
            std::snprintf(buf, sizeof buf, "%s renders 0x%016llxull", c.name, static_cast<unsigned long long>(h));
            cawtest::fail(__FILE__, __LINE__, buf);
        }
        // Determinism: a second engine renders the same bits.
        CHECK_EQ(render(c.project, frames), h);
    }
}

// Mute and solo silence exactly: the mix equals the same project with those tracks left out.
TEST(mute_and_solo_mixes_equal_projects_without_the_silenced_tracks) {
    const int64_t frames = 48000;
    ProjectSpec muted = base();
    muted.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
    muted.layers[1].mute = true;
    ProjectSpec withoutKick = base();
    withoutKick.layers = {folder("drums", 0.7, 0.0), track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
    CHECK_EQ(render(muted, frames), render(withoutKick, frames));

    ProjectSpec soloed = base();
    soloed.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                     track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
    soloed.layers[1].solo = true;
    ProjectSpec onlyKick = base();
    onlyKick.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums")};
    CHECK_EQ(render(soloed, frames), render(onlyKick, frames));
}

// Live code swaps: the replaced chain fades out on its own lane while the new one fades in, also
// when the two chains have different lengths, and new code waits for the next beat or bar.
TEST(code_swaps_between_chains_of_different_lengths_match_golden_renders) {
    struct Swap { const char* name; ProjectSpec from, to; uint64_t hash; };
    std::vector<Swap> swaps;
    {
        ProjectSpec a = withEffects();
        a.swapMode = 2;  // next bar
        a.layers = {chainTrack("b", {"bass", "fold", "glitch-fx"}, 0.7, 0.2), chainTrack("k", {"kick"}, 0.8, 0.0)};
        ProjectSpec b = a;
        b.layers = {chainTrack("b", {"bass"}, 0.7, 0.2), chainTrack("k", {"kick", "bitcrush", "fold"}, 0.8, 0.0)};
        swaps.push_back({"three modules to one and one to three at the next bar", a, b, 0x56a06ca3ed5bf333ull});
    }
    {
        ProjectSpec a = withEffects();
        a.swapMode = 0;  // at once, mid-block
        a.layers = {chainTrack("a", {"acid-synth", "glitch-fx"}, 0.6, 0.0)};
        a.layers[0].pattern = "acid-line";
        ProjectSpec b = a;
        b.layers[0].chain = {"acid-synth", "fold", "bitcrush"};
        swaps.push_back({"pattern synth changes its effects at once", a, b, 0x6124700d2464da0bull});
    }
    {
        ProjectSpec a = withEffects();
        a.swapMode = 1;  // next beat, on a short loop that crossfades its seams
        a.layers = {chainTrack("y", {"bytebeat-loop", "fold"}, 0.6, 0.0)};
        a.layers[0].lengthSteps = 3;
        ProjectSpec b = a;
        b.layers[0].chain = {"bytebeat-loop", "glitch-fx", "fold"};
        swaps.push_back({"short loop swaps at the next beat", a, b, 0x925c10fb5c56e83full});
    }
    for (const Swap& sw : swaps) {
        float peak = 0.0f;
        const uint64_t h = render(sw.from, 48000 * 2, &peak, &sw.to, 30011);
        if (!(peak > 0.01f)) cawtest::fail(__FILE__, __LINE__, std::string(sw.name) + " peak too low");
        CHECK(peak <= 1.0f);
        if (h != sw.hash) {
            char buf[160];
            std::snprintf(buf, sizeof buf, "%s renders 0x%016llxull", sw.name, static_cast<unsigned long long>(h));
            cawtest::fail(__FILE__, __LINE__, buf);
        }
        CHECK(render(sw.from, 48000 * 2, nullptr, &sw.to, 30011) != render(sw.from, 48000 * 2));  // the swap is heard
    }
}
