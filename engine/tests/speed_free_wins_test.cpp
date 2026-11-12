// Speed phase 1 ("free wins"): Eco lowers oversampling, silent meters and nodes skip work exactly, the master chain sleeps after a tail and wakes sample-exactly.
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "analysis.h"
#include "component_chain.h"
#include "engine.h"
#include "meters.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

ProjectSpec oneTrack(const std::string& instrument, const std::string& notes,
                     std::vector<std::pair<std::string, double>> params, std::vector<ComponentSpec> effects = {}) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n" + notes});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.pattern = "pat";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = instrument;
    l.instrument.params = std::move(params);
    l.components = std::move(effects);
    p.layers.push_back(l);
    return p;
}

// `seconds` of the project playing at `quality`, interleaved.
std::vector<float> render(const ProjectSpec& p, int quality, double seconds = 1.0) {
    Engine e(48000);
    e.setQuality(quality);
    std::vector<float> out;
    if (!ok(e.setProjectOffline(p))) return out;
    e.play();
    std::vector<float> a(256), b(256);
    for (int done = 0; done < static_cast<int>(seconds * 48000); done += 256) {
        e.process(a.data(), b.data(), 256);
        for (int i = 0; i < 256; ++i) out.push_back(a[static_cast<size_t>(i)]), out.push_back(b[static_cast<size_t>(i)]);
    }
    return out;
}

double difference(const std::vector<float>& a, const std::vector<float>& b) {
    double d = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) d += std::fabs(a[i] - b[i]);
    return d;
}

bool sameBits(const std::vector<float>& a, const std::vector<float>& b) {
    return a.size() == b.size() && std::memcmp(a.data(), b.data(), a.size() * sizeof(float)) == 0;
}

}  // namespace

TEST(eco_renders_flagships_fold_and_fm_warps_without_oversampling) {
    // osc 1 bright (one copy, no filter, no reverb) through each warp at full amount.
    for (const double w : {5.0, 6.0}) {  // FM, Fold
        const ProjectSpec p = oneTrack("org.caw.synth.flagship", "0 A4 8 1\n",
                                       {{"osc1_unison", 1}, {"osc1_warp", w}, {"osc1_warp_amt", 1}, {"flt1_on", 0},
                                        {"fx_reverb_on", 0}});
        const std::vector<float> eco = render(p, 0), normal = render(p, 1), high = render(p, 2);
        CHECK(!eco.empty());
        // Normal and High oversample alike (2x); Eco renders at the sample rate: a different, aliased signal...
        CHECK(sameBits(normal, high));
        CHECK(difference(eco, normal) > 1.0);
        // ...at about the same level, finite.
        for (float v : eco) CHECK(std::isfinite(v));
        CHECK_NEAR(analysis::levels(eco.data(), eco.size()).rmsDb, analysis::levels(normal.data(), normal.size()).rmsDb, 1.5);
    }
}

TEST(eco_runs_the_clippers_chosen_oversampling_one_stage_lower) {
    // oversample: 0 Auto, 1 Off, 2 2x, 3 4x, 4 8x.
    auto clip = [](int quality, double oversample) {
        return render(oneTrack("org.caw.synth.flagship", "0 A4 4 1\n", {{"osc1_unison", 1}, {"flt1_on", 0}, {"fx_reverb_on", 0}},
                               {{"org.caw.clipper", {{"drive", 18}, {"oversample", oversample}}}}),
                      quality);
    };
    CHECK(sameBits(clip(0, 2), clip(1, 1)));  // Eco 2x: off
    CHECK(sameBits(clip(0, 3), clip(1, 2)));  // Eco 4x: 2x
    CHECK(sameBits(clip(0, 4), clip(1, 2)));  // Eco 8x: 2x
    CHECK(difference(clip(1, 2), clip(1, 1)) > 0.01);  // Normal honours the choice
}

TEST(the_loudness_meter_skips_silence_with_the_same_readings_at_any_block_size) {
    // A tone, silence, a tone: measured in blocks of 1, 64 and 4800 frames (the silent fast path takes the zeros
    // in different runs), the readings are the same, and the silence counts as time but not as loudness.
    std::vector<float> l, r;
    for (int i = 0; i < 3 * 48000; ++i) {
        const bool tone = i < 48000 || i >= 2 * 48000;
        const float v = tone ? static_cast<float>(0.1 * std::sin(2.0 * 3.141592653589793 * 997.0 * i / 48000.0)) : 0.0f;
        l.push_back(v);
        r.push_back(i % 7 == 0 && !tone ? -0.0f : v);  // a few signed zeros in the silence
    }
    LoudnessMeter::Reading first{};
    int k = 0;
    for (const int block : {1, 64, 4800}) {
        LoudnessMeter m;
        m.prepare(48000);
        for (int i = 0; i < static_cast<int>(l.size()); i += block) {
            const int n = std::min<int>(block, static_cast<int>(l.size()) - i);
            m.process(l.data() + i, r.data() + i, n);
        }
        const LoudnessMeter::Reading x = m.read();
        if (k++ == 0) {
            first = x;
            CHECK_NEAR(x.integratedSeconds, 3.0, 0.11);
            CHECK(x.integrated > -30.0f && x.integrated < -10.0f);
        } else {
            CHECK_EQ(x.integrated, first.integrated);
            CHECK_EQ(x.momentary, first.momentary);
            CHECK_EQ(x.shortTerm, first.shortTerm);
            CHECK_EQ(x.truePeakMax, first.truePeakMax);
            CHECK_EQ(x.integratedSeconds, first.integratedSeconds);
        }
    }
    // The tone alone gives the same integrated loudness: the silent blocks fall under the absolute gate.
    LoudnessMeter tone;
    tone.prepare(48000);
    tone.process(l.data(), r.data(), 48000);
    tone.process(l.data() + 2 * 48000, r.data() + 2 * 48000, 48000);
    // (within a little: the 400 ms blocks across the silence's edges are part tone)
    CHECK_NEAR(tone.read().integrated, first.integrated, 1.0);
}

TEST(a_silent_track_with_a_send_changes_no_bit_of_the_mix) {
    // A track playing beside a track that sounds nothing (no notes, a send to the same bus): the same bits as
    // without the silent track.
    auto project = [](bool silent) {
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 1;
        p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 A3 4 1\n8 E4 4 0.7\n"});
        p.modules.push_back({"none", "---\nkind: pattern\nname: N\nlength: 16\n---\n"});
        LayerSpec bus;
        bus.id = bus.name = "Bus";
        bus.folder = true;
        bus.components = {{"org.caw.delay.pro", {{"mix", 0.5}}}};
        LayerSpec a = cawtest::testSignalLayer("a", cawtest::Shape::Saw, {{"mode", 1}});
        a.pattern = "pat";
        a.sends.push_back({"Bus", 0.5, false, false});
        p.layers.push_back(a);
        if (silent) {
            LayerSpec s = cawtest::testSignalLayer("s", cawtest::Shape::Sine, {{"mode", 1}}, {{"org.caw.eq", {}}});
            s.pattern = "none";
            s.sends.push_back({"Bus", 0.8, false, false});
            s.sends.push_back({"Bus", 0.3, true, false});
            p.layers.push_back(s);
        }
        p.layers.push_back(bus);
        return p;
    };
    const std::vector<float> with = render(project(true), 1, 2.0), without = render(project(false), 1, 2.0);
    CHECK(!with.empty());
    CHECK(analysis::levels(with.data(), with.size()).peak > 0.01);
    CHECK(sameBits(with, without));
}

TEST(the_master_chain_sleeps_after_a_tail_and_wakes_sample_exactly) {
    // A test tone at bars 1 and 5 of 8 through a master compressor and limiter: after the first note the master's
    // effects fall asleep (once the DC blocker's decay reaches the last float), and the second note wakes them on
    // its first frame: it plays the first note's bits.
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 8;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 128\n---\n0 A4 2 1\n64 A4 2 1\n"});
    LayerSpec t = cawtest::testSignalLayer("t", cawtest::Shape::Sine, {{"mode", 1}, {"level", 0.5}});
    t.pattern = "pat";
    p.layers.push_back(t);
    p.masterComponents = {{"org.caw.compressor", {{"threshold", -20}}}, {"org.caw.limiter", {}}};
    Engine e(48000);
    CHECK(ok(e.setProjectOffline(p)));
    ChainProfile profile{};
    ChainProfile::set(&profile);
    e.play();
    constexpr int kFrames = 256, kBar = 96000;  // 2 s a bar at 120 BPM
    std::vector<float> a(kFrames), b(kFrames), out;
    int lastLoud = -1, lastRan = -1;
    uint64_t ran = 0;
    for (int at = 0; at < 8 * kBar; at += kFrames) {
        e.process(a.data(), b.data(), kFrames);
        float peak = 0;
        for (int i = 0; i < kFrames; ++i) {
            out.push_back(a[static_cast<size_t>(i)]);
            peak = std::max(peak, std::max(std::fabs(a[static_cast<size_t>(i)]), std::fabs(b[static_cast<size_t>(i)])));
        }
        uint64_t now = 0;
        for (uint32_t s = 0; s < profile.used; ++s)
            if (profile.slots[s].id && *profile.slots[s].id == "org.caw.compressor") now += profile.slots[s].ran;
        if (at < 4 * kBar) {  // after the first note only
            if (peak > 1e-5f) lastLoud = at;
            if (now != ran) lastRan = at;
        }
        ran = now;
    }
    ChainProfile::set(nullptr);
    CHECK(lastLoud > 0);
    CHECK(lastRan >= lastLoud);
    CHECK(lastRan < 4 * kBar - kBar / 2);  // asleep well before the second note
    // Woken by the second note on its first frame: the same samples as the first note's, from the same offset.
    const size_t span = 2 * static_cast<size_t>(kBar);
    CHECK(out.size() >= 4 * static_cast<size_t>(kBar) + span);
    const std::vector<float> first(out.begin(), out.begin() + static_cast<std::ptrdiff_t>(span));
    const std::vector<float> second(out.begin() + 4 * kBar, out.begin() + 4 * kBar + static_cast<std::ptrdiff_t>(span));
    CHECK(analysis::levels(first.data(), first.size()).peak > 0.1);
    CHECK(sameBits(first, second));
}
