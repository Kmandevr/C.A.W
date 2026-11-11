// Mixer golden renders: multi-track projects (pan, folder buses, nesting, mute/solo, automation, effect chains and
// their swaps) on the test signal, hashed bit-exactly.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

// The sounds the mixes play: the test signal (test_signal.h) in Notes mode, each on its own pattern.
struct Sound {
    const char* name;
    cawtest::Shape shape;
    const char* pattern;
    double level;
};
constexpr Sound kSounds[] = {
    {"kick", cawtest::Shape::Sine, "kick-pat", 0.9},
    {"hats", cawtest::Shape::Noise, "hats-pat", 0.3},
    {"bass", cawtest::Shape::Saw, "bass-pat", 0.5},
    {"acid", cawtest::Shape::Square, "acid-line", 0.4},
    {"pad", cawtest::Shape::Sine, "chords", 0.3},
};

LayerSpec track(const std::string& id, const std::string& sound, double volume, double pan,
                const std::string& parent = {}) {
    LayerSpec l;
    for (const Sound& s : kSounds)
        if (sound == s.name) l = cawtest::testSignalNotesLayer(id, s.shape, s.pattern, {{"level", s.level}});
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

std::string pattern(const std::string& length, const std::string& notes) {
    return "---\nkind: pattern\nlength: " + length + "\n---\n" + notes;
}

ProjectSpec base() {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 1;
    p.master = 0.8;
    p.seed = 7;
    p.modules = {
        {"kick-pat", pattern("16", "0 C2 1 1\n4 C2 1 1\n8 C2 1 1\n12 C2 1 0.9\n"), {}},
        {"hats-pat", pattern("16", "2 F#2 1/2 0.8\n6 F#2 1/2 0.7\n10 F#2 1/2 0.8\n14 F#2 1/2 0.6 prob 0.5\n"), {}},
        {"bass-pat", pattern("16", "0 A1 2 1\n3 A1 1 0.8\n6 C2 2 0.9\n8 E1 3 1\n12 G1 2 0.7 slide\n14 A1 2 0.9\n"), {}},
        {"acid-line", pattern("16", "0 A1 2 1\n2 A2 1 0.7\n3 A1 1 0.8 slide\n4 C2 2 0.9\n6 A1 1 0.6 prob 0.5\n"
                                    "8 E2 2 1 ratchet 2\n10 G1 1 0.7\n11 A1 1 0.8 slide\n12 A2 2 0.9\n14 G2 1 0.6\n"
                                    "15 E2 1 0.8\n"), {}},
        {"chords", pattern("16", "0 A3,C4,E4 8 0.8\n8 F3,A3,C4 6 0.75\n14 G3,B3,D4 1/2 0.5 ratchet 2\n"), {}},
    };
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

// A track playing `sound` through native effects (F4.4: a track's chain).
LayerSpec chainTrack(const std::string& id, const std::string& sound, std::vector<ComponentSpec> effects, double volume,
                     double pan, const std::string& parent = {}) {
    LayerSpec l = track(id, sound, volume, pan, parent);
    l.components = std::move(effects);
    return l;
}

ComponentSpec effect(const std::string& id, std::vector<std::pair<std::string, double>> params = {}) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}
const ComponentSpec kFold = effect("org.caw.distortion", {{"shape", 2}, {"drive", 8}, {"mix", 0.8}});
const ComponentSpec kGlitch = effect("org.caw.stutter");
const ComponentSpec kCrush = effect("org.caw.bitcrush");

struct Case { const char* name; ProjectSpec project; uint64_t hash; float minPeak = 0.01f; };

std::vector<Case> cases() {
    std::vector<Case> out;
    {
        ProjectSpec p = base();
        p.layers = {track("k", "kick", 0.9, 0.0), track("h", "hats", 0.6, -0.4), track("b", "bass", 0.7, 0.3)};
        out.push_back({"three tracks into master", p, 0x66a15e47258d707bull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.2), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        out.push_back({"folder bus plus root track", p, 0x9c4499def0d1fbe8ull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("outer", 0.8, -0.2), folder("inner", 0.6, 0.4, "outer"),
                    track("k", "kick", 0.9, 0.0, "inner"), track("a", "acid", 0.5, 0.1, "inner"),
                    track("h", "hats", 0.6, -0.5, "outer"), track("p", "pad", 0.4, 0.0)};
        out.push_back({"nested folders", p, 0xd3456d224a9906f4ull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        p.layers[2].mute = true;
        p.layers[3].solo = true;
        p.layers[1].solo = true;
        out.push_back({"mute and solo across a folder", p, 0xaac5b87820a31d0dull});
    }
    {
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("p", "pad", 0.5, 0.0)};
        p.layers[0].automation = {{"volume", {{0, 0.1}, {8, 1.0}, {16, 0.3}}}, {"pan", {{0, -1.0}, {16, 1.0}}}};
        p.layers[3].automation = {{"pan", {{0, 1.0}, {12, -0.6}}}};
        out.push_back({"folder and track automation", p, 0x93cb73f57b1cb1c9ull});
    }
    {
        // Mute alone: the muted child drops out and its sibling and the root track keep playing.
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        p.layers[1].mute = true;
        out.push_back({"mute only inside a folder", p, 0x3861ec23660fddf6ull});
    }
    {
        // Solo of one child: its unmuted, non-soloed sibling and the root track fall silent.
        ProjectSpec p = base();
        p.layers = {folder("drums", 0.7, 0.0), track("k", "kick", 0.9, 0.0, "drums"),
                    track("h", "hats", 0.6, -0.5, "drums"), track("b", "bass", 0.7, 0.3)};
        p.layers[1].solo = true;
        out.push_back({"solo of one child silences its sibling", p, 0x6e083baadc6ca6dbull});
    }
    {
        ProjectSpec p = base();
        p.master = 2.5;  // drives the safety limiter
        p.layers = {folder("all", 1.0, 0.0), track("k", "kick", 1.0, 0.0, "all"), track("b", "bass", 1.0, 0.0, "all"),
                    track("a", "acid", 1.0, 0.0, "all")};
        // The limiter must actually engage: the peak sits at its ceiling, far above the unlimited
        // level of these tracks, but never above 1.
        out.push_back({"limiter driven through a bus", p, 0xe4f745e67662198full, 0.9f});
    }
    {
        ProjectSpec p = base();
        p.layers = {chainTrack("b", "bass", {kFold, kGlitch}, 0.7, 0.2), chainTrack("k", "kick", {kCrush}, 0.8, 0.0)};
        out.push_back({"effect chains on tracks", p, 0xba66a9dd0b06aa03ull});
    }
    {
        // Short, odd pattern lengths: each track loops on its own, mid-block and through effects.
        ProjectSpec p = base();
        p.modules.push_back({"three", pattern("3", "0 C3 1 1\n1.5 G3 1 0.6\n"), {}});
        p.modules.push_back({"five", pattern("5", "0 F#2 1/2 0.9\n2 F#2 1/2 0.5\n4 F#2 1 0.7\n"), {}});
        p.layers = {chainTrack("y", "bass", {kFold}, 0.6, -0.3), chainTrack("h", "hats", {kGlitch}, 0.6, 0.4)};
        p.layers[0].pattern = "three";
        p.layers[1].pattern = "five";
        out.push_back({"short patterns loop at their own lengths", p, 0x7f904007a6434369ull});
    }
    {
        // Chords and an acid line through effect chains, inside a folder bus.
        ProjectSpec p = base();
        p.layers = {folder("keys", 0.8, 0.0), chainTrack("a", "acid", {kGlitch}, 0.6, -0.2, "keys"),
                    chainTrack("c", "pad", {kCrush, kFold}, 0.4, 0.3, "keys")};
        out.push_back({"chords and an acid line through effect chains", p, 0xb751f9d7f2cfbffdull});
    }
    {
        // The Library's built-in native effects (#121) in track and master chains, tempo-synced delay included.
        ProjectSpec p = base();
        p.layers = {track("b", "bass", 0.7, 0.2), track("a", "acid", 0.6, -0.3)};
        p.layers[0].components = {{"org.caw.distortion", {{"shape", 0}, {"drive", 6}, {"mix", 0.7}}},
                                  {"org.caw.stereo.width", {{"width", 1.6}}}};
        p.layers[1].components = {{"org.caw.chorus", {{"rate", 0.8}, {"depth", 0.6}}},
                                  {"org.caw.delay.pingpong", {{"sync", 3}, {"feedback", 0.5}, {"mix", 0.4}}},
                                  {"org.caw.stereo.balance", {{"pan", 0.2}}}};
        p.masterComponents = {{"org.caw.distortion", {{"shape", 3}, {"bits", 12}, {"mix", 0.3}}}};
        // Re-recorded 2026-11-10: the ping-pong feeds its left line the mono average at full cross, not the sum
        // (its first echo was 6 dB over the dry sound; second audio review, fix 2).
        out.push_back({"built-in library effects on tracks and the master", p, 0x02ec1b741562a889ull});
    }
    return out;
}

}  // namespace

// Guards the mixer's routing arithmetic and each track's chain, all run by the one graph.
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

// Chain swaps while playing: a track's inserts or instrument change mid-block, the replaced ones crossfade out.
TEST(chain_swaps_while_playing_match_golden_renders) {
    struct Swap { const char* name; ProjectSpec from, to; uint64_t hash; };
    std::vector<Swap> swaps;
    {
        ProjectSpec a = base();
        a.layers = {chainTrack("b", "bass", {kFold, kGlitch}, 0.7, 0.2), track("k", "kick", 0.8, 0.0)};
        ProjectSpec b = a;
        b.layers = {track("b", "bass", 0.7, 0.2), chainTrack("k", "kick", {kCrush, kFold}, 0.8, 0.0)};
        swaps.push_back({"two effects to none and none to two", a, b, 0xfe51f47c8cf35948ull});
    }
    {
        ProjectSpec a = base();
        a.layers = {chainTrack("a", "acid", {kGlitch}, 0.6, 0.0)};
        ProjectSpec b = a;
        b.layers[0].components = {kFold, kCrush};
        swaps.push_back({"an acid line changes its effects", a, b, 0x08b34c5f7cd69cabull});
    }
    {
        ProjectSpec a = base();
        a.layers = {chainTrack("c", "pad", {kFold}, 0.6, 0.0)};
        ProjectSpec b = a;
        b.layers[0].instrument = cawtest::testSignal(cawtest::Shape::Saw, {{"mode", 1}, {"level", 0.2}});
        swaps.push_back({"chords change instrument", a, b, 0x24e8e804d48b9373ull});
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
