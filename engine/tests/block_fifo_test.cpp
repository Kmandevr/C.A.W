// Callback sizes: every track's bits the same for odd sizes, and the device's fixed-block FIFO (BlockFifo) bit-identical to fixed blocks.
#include <cstdint>
#include <algorithm>
#include <cmath>
#include <functional>
#include <random>
#include <string>
#include <vector>

#include "block_fifo.h"
#include "engine.h"
#include "test.h"

using namespace caw;

namespace {

// A song with sends, a bus, a keyed ducker and a delay: the parts whose state crosses blocks.
ProjectSpec fifoSong() {
    ProjectSpec p;
    p.bpm = 90;  // 8000-frame steps at 48 kHz: the default project's tempo
    p.loopBars = 2;
    p.modules = {{"a", "---\nkind: pattern\nname: A\nlength: 32\n---\n0 C3 2 1\n4 E3 1 0.8\n9 G3 3 0.9\n17 A3 1 0.7\n"
                       "21 C4 2 0.9\n28 B3 1 0.6\n"},
                 {"k", "---\nkind: pattern\nname: K\nlength: 16\n---\n0 C2 1 1\n4 C2 1 1\n8 C2 1 1\n12 C2 1 1\n"}};
    LayerSpec lead;
    lead.id = lead.name = "Lead";
    lead.pattern = "a";
    lead.hasInstrument = true;
    lead.instrument.id = "org.caw.synth.flagship";
    lead.components = {{"org.caw.ducker", {}}, {"org.caw.delay.pingpong", {}}};
    LayerSpec kick;
    kick.id = kick.name = "Kick";
    kick.pattern = "k";
    kick.hasInstrument = true;
    kick.instrument.id = "org.caw.drums";
    p.layers = {lead, kick};
    return p;
}

// The song in callbacks of `size(callback)` frames, through a BlockFifo when `fifo` (as the device callback
// does), else straight into Engine::process.
std::vector<float> render(int64_t frames, bool fifo, const std::function<int(int)>& size) {
    Engine e(48000);
    CHECK(e.setProject(fifoSong()).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> out(static_cast<size_t>(frames) * 2);
    std::vector<float> l(4096), r(4096);
    BlockFifo<kBlock> f;
    int64_t at = 0;
    for (int call = 0; at < frames; ++call) {
        const int n = static_cast<int>(std::min<int64_t>(size(call), frames - at));
        if (fifo) f.pull(l.data(), r.data(), n, 512, [&](float* bl, float* br, int m) { e.process(bl, br, m); });
        else e.process(l.data(), r.data(), n);
        for (int i = 0; i < n; ++i) {
            out[static_cast<size_t>(at + i) * 2] = l[static_cast<size_t>(i)];
            out[static_cast<size_t>(at + i) * 2 + 1] = r[static_cast<size_t>(i)];
        }
        at += n;
    }
    return out;
}

}  // namespace

TEST(the_block_fifo_plays_the_same_bits_as_fixed_blocks_for_any_callback_size) {
    const int64_t frames = 48000 * 6;
    const std::vector<float> blocks = render(frames, false, [](int) { return kBlock; });
    double peak = 0;
    for (float v : blocks) peak = std::max(peak, static_cast<double>(std::fabs(v)));
    CHECK(peak > 0.01);  // it plays
    std::mt19937 rng(11);
    std::uniform_int_distribution<int> any(1, 2048);
    const std::vector<std::pair<std::string, std::function<int(int)>>> sizes = {
        {"random 1-2048", [&](int) { return any(rng); }}, {"441", [](int) { return 441; }},
        {"480", [](int) { return 480; }},   {"960", [](int) { return 960; }},
        {"1023", [](int) { return 1023; }}, {"1920", [](int) { return 1920; }},
        {"1", [](int) { return 1; }},       {"4096", [](int) { return 4096; }}};
    for (const auto& [name, size] : sizes) {
        const std::vector<float> got = render(frames, true, size);
        size_t differ = 0;
        for (size_t i = 0; i < got.size(); ++i) differ += got[i] != blocks[i];
        if (differ) cawtest::fail(__FILE__, __LINE__, name + ": " + std::to_string(differ) + " samples differ");
    }
}

TEST(the_block_fifo_holds_less_than_a_block_and_reports_its_latency) {
    CHECK_EQ(BlockFifo<kBlock>::maxLatency(192), 0);  // whole blocks: it adds nothing
    CHECK_EQ(BlockFifo<kBlock>::maxLatency(1024), 0);
    CHECK_EQ(BlockFifo<kBlock>::maxLatency(441), kBlock - 1);
    CHECK_EQ(BlockFifo<kBlock>::maxLatency(480), kBlock - 1);
    BlockFifo<kBlock> f;
    float l[2048], r[2048];
    int rendered = 0, played = 0, worst = 0;
    std::mt19937 rng(3);
    std::uniform_int_distribution<int> any(1, 2048);
    for (int k = 0; k < 2000; ++k) {
        const int n = any(rng);
        f.pull(l, r, n, 512, [&](float* bl, float* br, int m) {
            CHECK_EQ(m % kBlock, 0);  // the engine only ever sees whole blocks
            CHECK(m <= 512);
            for (int i = 0; i < m; ++i) bl[i] = br[i] = static_cast<float>(rendered + i);
            rendered += m;
        });
        for (int i = 0; i < n; ++i) CHECK_EQ(l[i], static_cast<float>(played + i));  // in order, none lost or repeated
        played += n;
        CHECK_EQ(rendered - played, f.held());
        worst = std::max(worst, f.held());
    }
    CHECK(worst <= BlockFifo<kBlock>::maxLatency(441));
    // Whole-block callbacks from empty pass straight through.
    f.flush();
    f.pull(l, r, 192, 512, [&](float*, float*, int) {});
    CHECK_EQ(f.held(), 0);
}

TEST(every_track_plays_the_same_bits_for_odd_callback_sizes_over_a_long_render) {
    // The long-run drift check (2026-11-12, the owner's Bluetooth report): each track's output, tapped, in
    // 64-frame callbacks and in the sizes Bluetooth and background routes give, over a minute (fast-forwarded).
    // A track sliding out of time, or behaving differently for a block size, shows as differing samples. Track3 is
    // the default project's: its Flagship is 0 on the beat it starts on, so its ducker wakes a frame after it, and
    // it ducked there at 441-frame callbacks and not at 64 (fixed in builtin_ducker.cpp, 2026-11-12).
    ProjectSpec p = fifoSong();
    p.loopBars = 16;
    p.modules.push_back({"t3", "---\nkind: pattern\nname: Pattern 3\nlength: 16\n---\n0 B2,F#3,D4 16 1 ratchet 8\n"
                               "16 F#3,B2 16 1 ratchet 8\n16 C#4 16 1 ratchet 8 bend 0:1 0.3125:0\n"
                               "32 B3,E3 16 1 ratchet 8 bend 0:2 0.375:0\n32 B2 16 1 ratchet 8\n"});
    LayerSpec t3;  // the default project's Track 3: from step 68 (beat 17), Flagship into a Trigger-mode ducker
    t3.id = t3.name = "Track3";
    t3.hasInstrument = true;
    t3.instrument.id = "org.caw.synth.flagship";
    t3.instrument.params = {{"osc1_frame", 0.39}, {"flt1_cutoff", 6176}, {"flt1_resonance", 0.127}, {"osc1_unison", 2},
                            {"osc1_detune", 0}, {"osc1_level", 0.569}};
    t3.components = {{"org.caw.ducker", {{"release", 357.27}, {"tension", 0.218}, {"hold", 66.86}, {"attack", 13.73}}},
                     {"org.caw.distortion", {{"drive", 9.58}}}};
    t3.clips.push_back({"c", "t3", 68, 188, 0, true, false, 64});
    p.layers.push_back(t3);
    const int64_t frames = 48000 * 60;
    const size_t tracks = p.layers.size();
    auto taps = [&](const std::function<int(int)>& size) {
        Engine e(48000);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        std::vector<std::vector<float>> tl(tracks, std::vector<float>(4096)), tr(tracks, std::vector<float>(4096));
        for (size_t t = 0; t < tracks; ++t) CHECK(e.setOutputTap(p.layers[t].id, tl[t].data(), tr[t].data()));
        e.play();
        std::vector<std::vector<float>> out(tracks, std::vector<float>(static_cast<size_t>(frames)));
        std::vector<float> l(4096), r(4096);
        int64_t at = 0;
        for (int call = 0; at < frames; ++call) {
            const int n = static_cast<int>(std::min<int64_t>(size(call), frames - at));
            e.process(l.data(), r.data(), n);
            for (size_t t = 0; t < tracks; ++t)
                for (int i = 0; i < n; ++i) out[t][static_cast<size_t>(at + i)] = tl[t][static_cast<size_t>(i)] + tr[t][static_cast<size_t>(i)];
            at += n;
        }
        return out;
    };
    const auto ref = taps([](int) { return kBlock; });
    std::mt19937 rng(5);
    std::uniform_int_distribution<int> any(1, 2048);
    const std::vector<std::pair<std::string, std::function<int(int)>>> sizes = {
        {"441", [](int) { return 441; }}, {"1023", [](int) { return 1023; }}, {"random 1-2048", [&](int) { return any(rng); }}};
    for (const auto& [name, size] : sizes) {
        const auto got = taps(size);
        for (size_t t = 0; t < tracks; ++t) {
            int64_t differ = 0, first = -1;
            for (int64_t i = 0; i < frames; ++i)
                if (got[t][static_cast<size_t>(i)] != ref[t][static_cast<size_t>(i)]) {
                    if (first < 0) first = i;
                    ++differ;
                }
            if (differ)
                cawtest::fail(__FILE__, __LINE__, name + ", " + p.layers[t].id + ": " + std::to_string(differ) +
                                                      " samples differ from frame " + std::to_string(first));
        }
    }
}

TEST(the_engine_does_the_same_work_after_minutes_of_play_with_no_app_calls) {
    // As in the background (2026-11-12): nothing calls the engine but the device. After an edit's swap (whose
    // retired objects wait for the control thread), three minutes play in 441-frame callbacks: the chunk visits
    // the same slots and graph nodes at the end as at the start, and still sounds.
    ProjectSpec p = fifoSong();
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(441), r(441);
    for (int k = 0; k < 100; ++k) e.process(l.data(), r.data(), 441);
    p.layers[0].components = {{"org.caw.delay.pingpong", {}}};  // a chain swap: the old chain is retired
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    for (int k = 0; k < 100; ++k) e.process(l.data(), r.data(), 441);
    const int slots = e.slotsScannedPerChunk();
    const uint32_t nodes = e.mixGraphNodesRun();
    double peak = 0;
    for (int64_t k = 0, calls = 48000LL * 180 / 441; k < calls; ++k) {
        e.process(l.data(), r.data(), 441);
        if (k > calls - 2000)
            for (float v : l) peak = std::max(peak, static_cast<double>(std::fabs(v)));
    }
    CHECK_EQ(e.slotsScannedPerChunk(), slots);
    CHECK_EQ(e.mixGraphNodesRun(), nodes);
    CHECK(peak > 0.01);
    CHECK(e.meters().playing);
}

TEST(a_play_or_stop_moves_the_transport_count_the_device_fifo_watches) {
    Engine e(48000);
    CHECK(e.setProject(fifoSong()).find("\"ok\":true") != std::string::npos);
    const uint32_t before = e.transportSends();
    e.play();
    CHECK_EQ(e.transportSends(), before + 1);
    e.stop();
    CHECK_EQ(e.transportSends(), before + 2);
    e.playCountIn(0, 4);
    CHECK_EQ(e.transportSends(), before + 3);
}
