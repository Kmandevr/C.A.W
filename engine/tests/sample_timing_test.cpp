// Timing exact to the sample: ratchets and fractional starts where strict maths puts them, every track's bits the same for any callback size, and the device's fixed-block FIFO.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <random>
#include <functional>
#include <cstdio>
#include <string>
#include <vector>

#include "block_fifo.h"
#include "engine.h"
#include "midifile.h"
#include "pattern.h"
#include "project.h"
#include "sample_time.h"
#include "test.h"
#include "test_signal.h"
#include "timing_oracle.h"

using namespace caw;

namespace {

// One awkward note: a sample rate and tempo whose step is not a whole number of samples, and a ratchet whose
// repeats fall on half samples, where a fused multiply-add (Arm64) and separate roundings (x86-64, MSVC) part ways.
struct RatchetCase {
    int rate;
    double bpm, at, len;
    int ratchet;
};

// The frames where the test signal's impulses (one on each note-on) sound.
std::vector<int64_t> onsets(const RatchetCase& c, int64_t frames) {
    ProjectSpec p = cawtest::testSignalProject({}, c.bpm, 2);
    char line[96];
    std::snprintf(line, sizeof line, "%.17g C4 %.17g 1 ratchet %d\n", c.at, c.len, c.ratchet);
    p.modules.push_back({"pat", std::string("---\nkind: pattern\nlength: 32\n---\n") + line});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", cawtest::Shape::Impulse, "pat"));
    Engine e(c.rate);
    e.setMasterBypass(true);
    std::vector<int64_t> at;
    if (e.setProject(p).find("\"ok\":true") == std::string::npos) return at;
    e.play();
    std::vector<float> l(256), r(256);
    for (int64_t i = 0; i < frames; i += 256) {
        e.process(l.data(), r.data(), 256);
        for (int k = 0; k < 256; ++k)
            if (std::fabs(l[static_cast<size_t>(k)]) > 0.1f) at.push_back(i + k);
    }
    return at;
}

}  // namespace

TEST(ratchet_repeats_land_on_the_strict_sample_at_awkward_tempos_and_rates) {
    // Each case has a repeat that a fused multiply-add moves by one sample (found by sweeping rates, tempos,
    // quarter-step starts and lengths, and ratchets 2 to 8).
    const RatchetCase cases[] = {
        {44100, 60, 2, 1, 6},      // repeat 5: 31237 strict, 31238 fused
        {44100, 77, 1.25, 1.25, 6},  // repeat 5: 19688 strict, 19687 fused
        {44100, 140, 2, 1.25, 7},  // repeat 6
        {22050, 77, 5.25, 0.75, 7},  // repeat 6
        {22050, 60, 0.75, 1.25, 7},  // a fractional start; repeat 3
    };
    for (const RatchetCase& c : cases) {
        std::vector<int64_t> want;
        for (int sub = 0; sub < c.ratchet; ++sub)
            want.push_back(cawtest::strictRatchetStart(c.rate, c.bpm, c.at, c.len, c.ratchet, sub));
        const std::vector<int64_t> got = onsets(c, want.back() + 512);
        CHECK_EQ(got.size(), want.size());
        for (size_t i = 0; i < got.size() && i < want.size(); ++i) CHECK_EQ(got[i], want[i]);
    }
}

TEST(sample_time_helpers_match_strict_maths_across_a_sweep) {
    // The helpers every event, clip and loop position goes through (sample_time.h), against the strict reference, over
    // rates, tempos, quarter-step starts and lengths, and ratchets: a fused or reassociated build would miss some.
    int checked = 0, mismatches = 0;
    for (const int rate : {22050, 44100, 48000, 96000})
        for (const double bpm : {60.0, 77.0, 93.0, 100.0, 133.0, 140.0, 174.0, 87.5}) {
            const double frames = sampletime::stepFrames(rate, bpm);
            if (frames != cawtest::strictStepFrames(rate, bpm)) ++mismatches;
            for (int at4 = 0; at4 < 64; ++at4)
                for (int len4 = 1; len4 <= 8; ++len4)
                    for (int ratchet = 2; ratchet <= 8; ++ratchet)
                        for (int sub = 1; sub <= ratchet; ++sub) {
                            const double at = at4 / 4.0, len = len4 / 4.0;
                            const auto got = static_cast<int64_t>(
                                sampletime::roundFrames(sampletime::ratchetStep(at, len, ratchet, sub), frames));
                            if (got != cawtest::strictRatchetStart(rate, bpm, at, len, ratchet, sub)) ++mismatches;
                            ++checked;
                        }
        }
    CHECK(checked > 100000);
    CHECK_EQ(mismatches, 0);
}

namespace {

// The absolute ticks of every note-on (velocity > 0) in a Standard MIDI File, over all its tracks.
std::vector<int64_t> noteOnTicks(const std::vector<uint8_t>& b) {
    std::vector<int64_t> out;
    size_t p = 14;  // past MThd
    while (p + 8 <= b.size()) {
        const size_t len = (size_t{b[p + 4]} << 24) | (size_t{b[p + 5]} << 16) | (size_t{b[p + 6]} << 8) | b[p + 7];
        const size_t end = std::min(b.size(), p + 8 + len);
        size_t i = p + 8;
        int64_t tick = 0;
        uint8_t status = 0;
        auto vlq = [&]() {
            uint64_t v = 0;
            while (i < end) {
                const uint8_t c = b[i++];
                v = (v << 7) | (c & 0x7f);
                if (!(c & 0x80)) break;
            }
            return v;
        };
        while (i < end) {
            tick += static_cast<int64_t>(vlq());
            if (i >= end) break;
            if (b[i] == 0xff) {  // meta: type, length, data
                i += 2;
                i += vlq();
                continue;
            }
            if (b[i] == 0xf0 || b[i] == 0xf7) {
                ++i;
                i += vlq();
                continue;
            }
            if (b[i] & 0x80) status = b[i++];
            const int data = (status & 0xf0) == 0xc0 || (status & 0xf0) == 0xd0 ? 1 : 2;
            if ((status & 0xf0) == 0x90 && i + 1 < end && b[i + 1] > 0) out.push_back(tick);
            i += static_cast<size_t>(data);
        }
        p = end;
    }
    std::sort(out.begin(), out.end());
    return out;
}

}  // namespace

TEST(midi_export_puts_ratchet_repeats_on_the_strict_tick) {
    // The exported repeats come from the same strict step as playback (sample_time.h ratchetStep), so a file is the
    // same on every platform: each note-on at llround(step * ticks per step) of the strict step.
    const RatchetCase cases[] = {{44100, 60, 2, 1, 6}, {44100, 77, 1.25, 1.25, 6}, {44100, 140, 2, 1.25, 7},
                                 {22050, 77, 5.25, 0.75, 7}, {22050, 60, 0.75, 1.25, 7}};
    constexpr double kStepTicks = kMidiExportPpq / 4.0;
    for (const RatchetCase& c : cases) {
        char line[96];
        std::snprintf(line, sizeof line, "%.17g C4 %.17g 1 ratchet %d\n", c.at, c.len, c.ratchet);
        const PatternResult r = parsePattern(std::string("---\nkind: pattern\nlength: 32\n---\n") + line);
        CHECK(r.pattern != nullptr);
        if (!r.pattern) continue;
        const std::vector<int64_t> got = noteOnTicks(patternToSmf(*r.pattern, c.bpm, 4));
        CHECK_EQ(got.size(), static_cast<size_t>(c.ratchet));
        for (int sub = 0; sub < c.ratchet && static_cast<size_t>(sub) < got.size(); ++sub)
            CHECK_EQ(got[static_cast<size_t>(sub)],
                     static_cast<int64_t>(std::llround(cawtest::strictRatchetStep(c.at, c.len, c.ratchet, sub) * kStepTicks)));
    }
}

TEST(tempo_synced_effects_place_the_song_beat_on_the_strict_frame) {
    // fx::creative::StepClock locks to the song's frame, floor(beat * 60 * rate / tempo + 0.5), through sample_time.h.
    int mismatches = 0;
    for (const double rate : {22050.0, 44100.0, 48000.0, 96000.0})
        for (const double tempo : {60.0, 77.0, 93.0, 133.0, 174.0, 87.5})
            for (int k = 0; k < 2000; ++k) {
                const double beat = k / 7.0;
                if (sampletime::roundBeatFrames(beat, rate, tempo) != cawtest::strictBeatFrame(beat, rate, tempo)) ++mismatches;
            }
    CHECK_EQ(mismatches, 0);
}

// ---------- callback sizes and the device's fixed-block FIFO (2026-11-12, the owner's Bluetooth report) ----------

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
