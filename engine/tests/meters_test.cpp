// The live meters: K-weighting against BS.1770-5's table, EBU Tech 3341's minimum test signals, true peak, correlation.
#include <cmath>
#include <string>
#include <vector>

#include "caw.h"
#include "capi_internal.h"
#include "engine.h"
#include "meters.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

constexpr double kPi = 3.14159265358979323846;

// Feeds `seconds` of a stereo sine (both sides, `dbfs` per-channel peak) in 480-frame blocks (`odd` blocks of 37).
void tone(LoudnessMeter& m, double hz, double dbfs, double seconds, double rate = 48000, bool odd = false,
          double* phase = nullptr) {
    const double amp = dbfs <= -900 ? 0.0 : std::pow(10.0, dbfs / 20.0);
    const int frames = static_cast<int>(std::lround(seconds * rate));
    const int block = odd ? 37 : 480;
    std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
    double ph = phase ? *phase : 0.0;
    for (int done = 0; done < frames; done += block) {
        const int n = std::min(block, frames - done);
        for (int i = 0; i < n; ++i) {
            l[static_cast<size_t>(i)] = r[static_cast<size_t>(i)] = static_cast<float>(amp * std::sin(ph));
            ph += 2 * kPi * hz / rate;
        }
        m.process(l.data(), r.data(), n);
    }
    if (phase) *phase = ph;
}

}  // namespace

TEST(k_weighting_designed_at_48_khz_is_the_recommendations_table) {
    // ITU-R BS.1770-5 (11/2023), Tables 1 and 2 (stage 1 the shelf, stage 2 the high-pass), checked 2026-11-11.
    LoudnessMeter::Biquad s, h;
    LoudnessMeter::kWeighting(48000, s, h);
    CHECK_NEAR(s.b0, 1.53512485958697, 1e-9);
    CHECK_NEAR(s.b1, -2.69169618940638, 1e-9);
    CHECK_NEAR(s.b2, 1.19839281085285, 1e-9);
    CHECK_NEAR(s.a1, -1.69065929318241, 1e-9);
    CHECK_NEAR(s.a2, 0.73248077421585, 1e-9);
    CHECK_EQ(h.b0, 1.0);
    CHECK_EQ(h.b1, -2.0);
    CHECK_EQ(h.b2, 1.0);
    CHECK_NEAR(h.a1, -1.99004745483398, 1e-9);
    CHECK_NEAR(h.a2, 0.99007225036621, 1e-9);
}

TEST(loudness_meets_ebu_tech_3341s_minimum_test_signals) {
    // Tech 3341 V4 (11/2023), Table 1. #1: a stereo 1 kHz sine at -23 dBFS: M, S and I all -23.0 +-0.1 LUFS.
    for (double rate : {44100.0, 48000.0, 96000.0}) {
        LoudnessMeter m;
        m.prepare(rate);
        tone(m, 1000, -23, 20, rate);
        const LoudnessMeter::Reading r = m.read();
        CHECK_NEAR(r.momentary, -23.0, 0.1);
        CHECK_NEAR(r.shortTerm, -23.0, 0.1);
        CHECK_NEAR(r.integrated, -23.0, 0.1);
        CHECK_NEAR(r.integratedSeconds, 20.0, 0.11);
    }
    // #3: 10 s at -36, 60 s at -23, 10 s at -36 dBFS: I = -23.0 (the relative gate drops the quiet parts).
    {
        LoudnessMeter m;
        m.prepare(48000);
        double ph = 0;
        tone(m, 1000, -36, 10, 48000, false, &ph);
        tone(m, 1000, -23, 60, 48000, false, &ph);
        tone(m, 1000, -36, 10, 48000, false, &ph);
        CHECK_NEAR(m.read().integrated, -23.0, 0.1);
    }
    // #4: 10 s at -72, -36, 60 s at -23, -36, -72 dBFS: I = -23.0 (the absolute gate drops -72).
    {
        LoudnessMeter m;
        m.prepare(48000);
        double ph = 0;
        tone(m, 1000, -72, 10, 48000, false, &ph);
        tone(m, 1000, -36, 10, 48000, false, &ph);
        tone(m, 1000, -23, 60, 48000, false, &ph);
        tone(m, 1000, -36, 10, 48000, false, &ph);
        tone(m, 1000, -72, 10, 48000, false, &ph);
        CHECK_NEAR(m.read().integrated, -23.0, 0.1);
    }
    // #5: 20 s at -26, 20.1 s at -20, 20 s at -26 dBFS: I = -23.0. Odd blocks: the sub-blocks don't follow them.
    {
        LoudnessMeter m;
        m.prepare(48000);
        double ph = 0;
        tone(m, 1000, -26, 20, 48000, true, &ph);
        tone(m, 1000, -20, 20.1, 48000, true, &ph);
        tone(m, 1000, -26, 20, 48000, true, &ph);
        CHECK_NEAR(m.read().integrated, -23.0, 0.1);
    }
}

TEST(short_term_and_momentary_follow_their_windows_and_maxima_hold_until_reset) {
    // Tech 3341 #9-style: 1.34 s at -20 and 1.66 s at -30 dBFS repeated: S is constant (-23 +-0.1) after 3 s.
    LoudnessMeter m;
    m.prepare(48000);
    double ph = 0;
    for (int k = 0; k < 5; ++k) {
        tone(m, 1000, -20, 1.34, 48000, false, &ph);
        tone(m, 1000, -30, 1.66, 48000, false, &ph);
        if (k >= 1) CHECK_NEAR(m.read().shortTerm, -23.0, 0.1);
    }
    // Momentary sees 400 ms: after 0.5 s of -10 dBFS it reads -10 and holds that as its maximum.
    tone(m, 1000, -10, 0.5, 48000, false, &ph);
    LoudnessMeter::Reading r = m.read();
    CHECK_NEAR(r.momentary, -10.0, 0.1);
    CHECK_NEAR(r.momentaryMax, -10.0, 0.1);
    tone(m, 1000, -40, 1.0, 48000, false, &ph);
    r = m.read();
    CHECK_NEAR(r.momentary, -40.0, 0.1);
    CHECK_NEAR(r.momentaryMax, -10.0, 0.1);
    // Silence: no momentary reading (it is not a level); a reset clears the maxima and the integrated loudness.
    tone(m, 1000, -1000, 1.0);
    CHECK_EQ(m.read().momentary, kMeterNone);
    m.requestReset();
    tone(m, 1000, -1000, 0.01);  // the audio thread takes the reset at its next block
    r = m.read();
    CHECK_EQ(r.integrated, kMeterNone);
    CHECK_EQ(r.momentaryMax, kMeterNone);
    CHECK_EQ(r.integratedSeconds, 0.0);
}

TEST(true_peak_sees_the_peak_between_samples) {
    // A quarter-rate sine at 45 degrees: every sample is at 0.707 (-3.01 dBFS) but the wave peaks at 1.0 midway,
    // which the x4 interpolation (BS.1770-5 Annex 2) lands on.
    LoudnessMeter m;
    m.prepare(48000);
    std::vector<float> l(4800), r(4800);
    for (size_t i = 0; i < l.size(); ++i) {
        l[i] = static_cast<float>(0.5 * std::sin(kPi / 2 * static_cast<double>(i) + kPi / 4));
        r[i] = 0.25f * l[i];
    }
    m.process(l.data(), r.data(), static_cast<int>(l.size()));
    const LoudnessMeter::Reading a = m.read();
    CHECK_NEAR(a.truePeakL, 20 * std::log10(0.5), 0.2);  // not the samples' -9.03 dB
    CHECK_NEAR(a.truePeakR, 20 * std::log10(0.125), 0.2);
    CHECK_NEAR(a.truePeakMax, 20 * std::log10(0.5), 0.2);
    const LoudnessMeter::Reading b = m.read();  // the per-read peaks were reset by reading; the maximum holds
    CHECK_EQ(b.truePeakL, kMeterNone);
    CHECK_NEAR(b.truePeakMax, 20 * std::log10(0.5), 0.2);
}

TEST(correlation_reads_mono_unrelated_and_opposite_sides) {
    auto run = [](auto right) {
        CorrelationMeter c;
        c.prepare(48000);
        std::vector<float> l(256), r(256);
        uint32_t seed = 1;
        for (int b = 0; b < 400; ++b) {
            for (int i = 0; i < 256; ++i) {
                seed = seed * 1664525u + 1013904223u;
                l[static_cast<size_t>(i)] = static_cast<float>(std::sin(0.03 * (b * 256 + i)));
                r[static_cast<size_t>(i)] = right(l[static_cast<size_t>(i)], static_cast<float>((seed >> 8) / 8388608.0 - 1.0));
            }
            c.process(l.data(), r.data(), 256);
        }
        return c.read();
    };
    CHECK_NEAR(run([](float x, float) { return 0.5f * x; }), 1.0, 1e-4);
    CHECK_NEAR(run([](float x, float) { return -x; }), -1.0, 1e-4);
    CHECK(std::fabs(run([](float, float n) { return n; })) < 0.05);
    CHECK_EQ(run([](float, float) { return 0.0f; }), 0.0f);  // one side silent: nothing to correlate
}

namespace {

// A track of Flagship holding a chord through `inserts`, master bypassed off (the limiter stays in).
ProjectSpec chordTrack(std::vector<ComponentSpec> inserts) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 0.8;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 32\n---\n0 A3 32 0.9\n0 E4 32 0.8\n", {}});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.pattern = "pat";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = "org.caw.synth.flagship";
    l.components = std::move(inserts);
    p.layers.push_back(l);
    return p;
}

ComponentSpec insert(const std::string& id, std::vector<std::pair<std::string, double>> params) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}

}  // namespace

TEST(the_engine_meters_the_masters_loudness_and_each_layers_correlation) {
    CawEngine handle;  // the C API's handle around the engine under test
    handle.engine = std::make_unique<Engine>(48000);
    CawEngine* h = &handle;
    Engine& e = *handle.engine;
    CHECK(e.setProject(chordTrack({insert("org.caw.stereo.width", {{"width", 0.0}})})).find("\"ok\":true") !=
          std::string::npos);
    e.play();
    // Its output, metered again by a meter of our own: the engine's reading is that of what it played.
    LoudnessMeter mine;
    mine.prepare(48000);
    std::vector<float> l(256), r(256);
    for (int k = 0; k < 48000 * 4 / 256; ++k) {
        e.process(l.data(), r.data(), 256);
        mine.process(l.data(), r.data(), 256);
    }
    const LoudnessMeter::Reading got = e.loudness(), want = mine.read();
    CHECK(got.momentary > -40 && got.momentary < 0);
    CHECK_EQ(got.momentary, want.momentary);
    CHECK_EQ(got.shortTerm, want.shortTerm);
    CHECK_EQ(got.integrated, want.integrated);
    CHECK_EQ(got.truePeakMax, want.truePeakMax);
    CHECK(got.truePeakMax <= 0.5f);  // after the safety limiter
    // Width 0 made it mono: the track and the master correlate fully.
    float c = 0;
    CHECK(e.layerCorrelation(0, c));
    CHECK_NEAR(c, 1.0, 1e-4);
    CHECK_NEAR(e.masterCorrelation(), 1.0, 1e-4);
    CHECK(!e.layerCorrelation(5, c));
    // The C API: the same values, then a reset (Play does one too) empties the integrated loudness.
    CawLoudness cl;
    caw_engine_loudness(h, &cl);
    CHECK_EQ(cl.integrated_lufs, got.integrated);
    CHECK_NEAR(cl.correlation, 1.0, 1e-4);
    CHECK(cl.integrated_seconds > 3.5f);
    float lc = 0;
    CHECK_EQ(caw_engine_layer_correlation(h, 0, &lc), 1);
    CHECK_EQ(caw_engine_layer_correlation(h, 9, &lc), 0);
    caw_engine_loudness_reset(h);
    e.process(l.data(), r.data(), 256);
    caw_engine_loudness(h, &cl);
    CHECK_EQ(cl.integrated_lufs, CAW_METER_NONE);
    CHECK_EQ(cl.integrated_seconds, 0.0f);
}

TEST(a_track_with_one_side_inverted_reads_negative_correlation) {
    Engine e(48000);
    CHECK(e.setProject(chordTrack({insert("org.caw.stereo.width", {{"width", 0.0}}),
                                   insert("org.caw.utility", {{"invert_r", 1.0}})}))
              .find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(256), r(256);
    for (int k = 0; k < 400; ++k) e.process(l.data(), r.data(), 256);
    float c = 0;
    CHECK(e.layerCorrelation(0, c));
    CHECK_NEAR(c, -1.0, 1e-3);
}
