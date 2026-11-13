// The tempo map and time signatures (1.0.3, #207): exact beat <-> time maths, note timing across stepped and ramped
// changes and loops, the metronome's signatures, MIDI tempo and meter round trips, synced effects, the C API, and
// single-tempo projects to the bit.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <fstream>
#include <sstream>
#include <atomic>
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "caw.h"
#include "engine.h"
#include "json.h"
#include "midifile.h"
#include "pattern.h"
#include "project.h"
#include "render.h"
#include "sample_time.h"
#include "tempo_map.h"
#include "test.h"
#include "test_signal.h"
#include "timing_oracle.h"

using namespace caw;

namespace {

std::vector<cawtest::OraclePoint> oracle(const std::vector<TempoPointSpec>& pts) {
    std::vector<cawtest::OraclePoint> out;
    for (const TempoPointSpec& p : pts) out.push_back({p.beat, p.bpm, p.ramp});
    return out;
}

int64_t expectedFrame(const std::vector<TempoPointSpec>& pts, double rate, double step) {
    return static_cast<int64_t>(std::floor(cawtest::strictTempoFrame(oracle(pts), rate, step) + 0.5));
}

// Seconds at a beat by numeric integration of 60 / bpm(b) (Simpson's rule on each stretch between points), for
// checking the closed forms.
double integratedSeconds(const std::vector<TempoPointSpec>& pts, double beat) {
    double t = 0;
    for (size_t i = 0; i < pts.size() && pts[i].beat < beat; ++i) {
        const double a = pts[i].beat, b = i + 1 < pts.size() ? std::min(beat, pts[i + 1].beat) : beat;
        const bool ramp = i + 1 < pts.size() && pts[i + 1].ramp;
        auto f = [&](double x) {
            const double bpm = ramp ? pts[i].bpm + (pts[i + 1].bpm - pts[i].bpm) * (x - a) / (pts[i + 1].beat - a) : pts[i].bpm;
            return 60.0 / bpm;
        };
        const int n = 2000;
        const double h = (b - a) / n;
        double sum = f(a) + f(b);
        for (int k = 1; k < n; ++k) sum += f(a + k * h) * (k % 2 ? 4.0 : 2.0);
        t += sum * h / 3.0;
    }
    return t;
}

// Frames where the test signal's impulses (one on each note-on) sound, playing for `frames`.
std::vector<int64_t> onsets(Engine& e, int64_t frames, int block = 256) {
    std::vector<int64_t> at;
    std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
    for (int64_t i = 0; i < frames; i += block) {
        e.process(l.data(), r.data(), block);
        for (int k = 0; k < block; ++k)
            if (std::fabs(l[static_cast<size_t>(k)]) > 0.1f) at.push_back(i + k);
    }
    return at;
}

ProjectSpec impulseProject(const std::string& notes, int lengthSteps, int bars) {
    ProjectSpec p = cawtest::testSignalProject({}, 120, bars);
    p.modules.push_back({"pat", "---\nkind: pattern\nlength: " + std::to_string(lengthSteps) + "\n---\n" + notes});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", cawtest::Shape::Impulse, "pat"));
    return p;
}

std::string noteLines(const std::vector<double>& steps) {
    std::string s;
    char line[64];
    for (double st : steps) {
        std::snprintf(line, sizeof line, "%.17g C4 0.5 1\n", st);
        s += line;
    }
    return s;
}

const std::vector<TempoPointSpec> kStepped = {{0, 120, false}, {8, 90, false}, {12, 150, false}};
const std::vector<TempoPointSpec> kRamped = {{0, 120, false}, {4, 120, false}, {12, 175, true}, {14, 70, false}, {20, 50, true}};

}  // namespace

TEST(tempo_map_one_tempo_is_the_old_maths_to_the_bit) {
    // One tempo (and points that never change it) is one segment: frames are roundFrames(step, stepFrames).
    for (const double rate : {22050.0, 44100.0, 48000.0})
        for (const double bpm : {60.0, 77.0, 133.0, 174.0}) {
            TempoMap a = TempoMap::single(bpm, rate), b;
            b.build({{0, bpm, false}, {16, bpm, false}, {20, bpm, true}}, rate);
            CHECK(a.constant() && b.constant());
            const double L = sampletime::stepFrames(rate, bpm);
            for (int s4 = 0; s4 < 4000; ++s4) {
                const double step = s4 / 3.0;
                CHECK(a.roundFrame(step) == sampletime::roundFrames(step, L));
                CHECK(b.frameAt(step) == step * L);
                CHECK(b.stepAt(static_cast<double>(s4)) == static_cast<double>(s4) / L);
            }
        }
}

TEST(tempo_map_closed_forms_match_integration_and_invert) {
    TempoMap m;
    m.build(kRamped, 48000);
    CHECK(!m.constant());
    for (const double beat : {0.0, 2.0, 4.0, 6.5, 8.0, 11.99, 12.0, 13.0, 14.0, 17.0, 20.0, 25.0}) {
        CHECK_NEAR(m.secondsAt(beat), integratedSeconds(kRamped, beat), 1e-9);
        CHECK_NEAR(m.beatAt(m.secondsAt(beat)), beat, 1e-9);
        CHECK_NEAR(m.frameAt(beat * 4) / 48000.0, m.secondsAt(beat), 1e-9);
        CHECK_NEAR(m.stepAt(m.frameAt(beat * 4)), beat * 4, 1e-7);
    }
    // The tempo along the ramp, and the stepped tempo after the last point.
    CHECK_NEAR(m.bpmAtStep(8 * 4), 120 + 55 * 0.5, 1e-9);
    CHECK_EQ(m.bpmAtStep(14 * 4), 70.0);
    CHECK_NEAR(m.bpmAtStep(17 * 4), 60.0, 1e-9);
    CHECK_EQ(m.bpmAtStep(30 * 4), 50.0);
}

TEST(tempo_map_and_signatures_are_checked) {
    std::string error;
    std::vector<TempoPointSpec> pts = {{4, 100, false}, {0, 120, false}};
    CHECK(checkTempoPoints(pts, error) && pts[0].beat == 0);  // sorted
    std::vector<TempoPointSpec> bad[] = {{}, {{2, 120, false}}, {{0, 0.5, false}}, {{0, 1000, false}},
                                         {{0, 120, false}, {4, 100, false}, {4, 90, false}}, {{0, NAN, false}}};
    for (auto& b : bad) {
        CHECK(!checkTempoPoints(b, error));
        CHECK(!error.empty());
    }
    std::vector<TempoPointSpec> many(static_cast<size_t>(kMaxTempoPoints) + 1);
    for (size_t i = 0; i < many.size(); ++i) many[i] = {static_cast<double>(i), 120, false};
    CHECK(!checkTempoPoints(many, error));

    std::vector<TimeSigSpec> sigs = {{0, NAN, 3, 4}, {2, NAN, 7, 8}, {5, NAN, 4, 4}};
    CHECK(checkTimeSigs(sigs, error));
    CHECK_EQ(sigs[1].beat, 6.0);
    CHECK_EQ(sigs[2].beat, 6.0 + 3 * 3.5);
    std::vector<TimeSigSpec> mismatch = {{0, 0, 4, 4}, {2, 7, 3, 4}};
    CHECK(!checkTimeSigs(mismatch, error) && error.find("bars put it at beat 8") != std::string::npos);
    std::vector<TimeSigSpec> badDen = {{0, 0, 4, 3}};
    CHECK(!checkTimeSigs(badDen, error));
    std::vector<TimeSigSpec> byBeat = {{0, 0, 4, 4}, {0, 8, 3, 4}, {0, 9.5, 5, 8}};
    CHECK(!timeSigsFromBeats(byBeat, error) && error.find("bar line") != std::string::npos);
    std::vector<TimeSigSpec> onBars = {{0, 0, 4, 4}, {0, 8, 3, 4}, {0, 11, 5, 8}};
    CHECK(timeSigsFromBeats(onBars, error) && onBars[1].bar == 2 && onBars[2].bar == 3);

    // The project JSON: limits fail closed with a message that names the problem.
    ProjectSpec p;
    CHECK(!parseProject(R"({"caw_project":1,"tempo_map":[{"beat":0,"bpm":0}]})", p, error) &&
          error.find("bpm") != std::string::npos);
    CHECK(!parseProject(R"({"caw_project":1,"tempo_map":[{"beat":1,"bpm":90}]})", p, error));
    CHECK(!parseProject(R"({"caw_project":1,"time_signatures":[{"bar":0,"num":4,"den":4},{"bar":1,"beat":3,"num":3,"den":4}]})",
                        p, error));
    CHECK(parseProject(R"({"caw_project":1,"bpm":100,"tempo_map":[{"beat":0,"bpm":90},{"beat":8,"bpm":140,"ramp":true}],
                        "time_signatures":[{"bar":0,"beat":0,"num":6,"den":8},{"bar":4,"beat":12,"num":4,"den":4}]})",
                       p, error));
    CHECK_EQ(p.bpm, 90.0);  // the map's first point
    CHECK(p.tempoMap.size() == 2 && p.tempoMap[1].ramp);
    CHECK(p.timeSigs.size() == 2 && p.timeSigs[1].beat == 12.0);
}

TEST(notes_land_on_their_exact_sample_across_stepped_and_ramped_changes) {
    // Notes before, on and after each change and inside the ramps, at a rate where no step is a whole sample.
    const double rate = 44100;
    const std::vector<double> steps = {0, 5, 13.5, 31, 32, 33.25, 47, 48, 50, 53.75, 55, 56, 59.5, 63};
    for (const auto* map : {&kStepped, &kRamped}) {
        ProjectSpec p = impulseProject(noteLines(steps), 64, 4);
        p.tempoMap = *map;
        Engine e(rate);
        e.setMasterBypass(true);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        e.play();
        const int64_t end = expectedFrame(*map, rate, 63) + 1000;
        const std::vector<int64_t> got = onsets(e, end);
        CHECK_EQ(got.size(), steps.size());
        for (size_t i = 0; i < got.size() && i < steps.size(); ++i) CHECK_EQ(got[i], expectedFrame(*map, rate, steps[i]));
        CHECK_EQ(e.loopLength(), expectedFrame(*map, rate, 64));
    }
}

TEST(a_layers_own_loop_repeats_on_the_map_across_a_change) {
    // A 16-step pattern repeating over a song whose tempo changes mid-pass: each pass starts at its song step.
    const double rate = 44100;
    const std::vector<TempoPointSpec> map = {{0, 128, false}, {6, 97, false}, {10, 140, true}};
    ProjectSpec p = impulseProject(noteLines({0, 4.5, 11}), 16, 4);
    p.tempoMap = map;
    Engine e(rate);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<int64_t> want;
    for (int k = 0; k < 4; ++k)
        for (double s : {0.0, 4.5, 11.0}) want.push_back(expectedFrame(map, rate, 16 * k + s));
    const std::vector<int64_t> got = onsets(e, want.back() + 500, 100);
    CHECK_EQ(got.size(), want.size());
    for (size_t i = 0; i < got.size() && i < want.size(); ++i) CHECK_EQ(got[i], want[i]);
}

TEST(a_loop_range_spanning_a_tempo_change_repeats_exactly) {
    // The loop range runs from step 16 to 48 over a change at step 32 (and a ramp after it): every pass plays the
    // same notes on the same samples, at any callback size.
    const double rate = 44100;
    const std::vector<TempoPointSpec> map = {{0, 120, false}, {8, 80, false}, {11, 130, true}};
    std::vector<double> steps;
    for (int s = 0; s < 64; s += 3) steps.push_back(s + 0.25);
    ProjectSpec p = impulseProject(noteLines(steps), 64, 4);
    p.tempoMap = map;
    p.loopRange = true;
    p.loopStartSteps = 16;
    p.loopEndSteps = 48;
    const int64_t from = expectedFrame(map, rate, 16), to = expectedFrame(map, rate, 48);
    std::vector<int64_t> want;
    for (double s : steps)
        if (expectedFrame(map, rate, s) < to) want.push_back(expectedFrame(map, rate, s));
    for (int pass = 0; pass < 2; ++pass)
        for (double s : steps) {
            const int64_t f = expectedFrame(map, rate, s);
            if (f >= from && f < to) want.push_back(to + pass * (to - from) + (f - from));
        }
    for (const int block : {64, 100, 333}) {
        Engine e(rate);
        e.setMasterBypass(true);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        e.play();
        const std::vector<int64_t> got = onsets(e, to + 2 * (to - from) - 1, block);
        CHECK_EQ(got.size(), want.size());
        for (size_t i = 0; i < got.size() && i < want.size(); ++i) CHECK_EQ(got[i], want[i]);
    }
}

TEST(play_at_a_step_starts_on_the_map) {
    const double rate = 48000;
    ProjectSpec p = impulseProject(noteLines({40}), 64, 4);
    p.tempoMap = kRamped;
    Engine e(rate);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play(36.0);
    const std::vector<int64_t> got = onsets(e, 48000);
    CHECK_EQ(got.size(), 1u);
    if (!got.empty()) CHECK_EQ(got[0], expectedFrame(kRamped, rate, 40) - expectedFrame(kRamped, rate, 36));
    // The position reports beats, seconds and the tempo there.
    const Engine::SongPosition pos = e.position();
    TempoMap m;
    m.build(kRamped, rate);
    CHECK_NEAR(pos.beat, m.stepAt(static_cast<double>(pos.frame)) / 4.0, 1e-12);
    CHECK_NEAR(pos.seconds, static_cast<double>(pos.frame) / rate, 1e-12);
    CHECK_NEAR(pos.bpm, m.bpmAtStep(pos.beat * 4), 1e-9);
}

namespace {

struct Click {
    int64_t frame;
    bool accent;
};

// The metronome's clicks (and accents) over `frames`, the project otherwise silent. A click's first sample is
// sin(0) = 0, so the first non-zero sample after a silence is the click's frame + 1.
std::vector<Click> clicks(Engine& e, int64_t frames) {
    std::vector<Click> out;
    std::vector<float> l(256), r(256);
    std::vector<float> all;
    for (int64_t i = 0; i < frames; i += 256) {
        e.process(l.data(), r.data(), 256);
        all.insert(all.end(), l.begin(), l.end());
    }
    int64_t quiet = 1 << 20;
    for (size_t i = 0; i < all.size(); ++i) {
        if (std::fabs(all[i]) > 1e-6f) {
            if (quiet > 200) {
                float peak = 0;
                for (size_t k = i; k < std::min(all.size(), i + 200); ++k) peak = std::max(peak, std::fabs(all[k]));
                out.push_back({static_cast<int64_t>(i) - 1, peak > 0.4f});
            }
            quiet = 0;
        } else {
            ++quiet;
        }
    }
    return out;
}

}  // namespace

TEST(the_metronome_follows_the_signatures_and_the_tempo_map) {
    // 3/4 for two bars, then 7/8 (an eighth-note tick, the accent every 7), at 120 BPM; then the same over a ramp.
    const double rate = 48000;
    const std::vector<TimeSigSpec> sigs = {{0, 0, 3, 4}, {2, 6, 7, 8}};
    for (const bool ramp : {false, true}) {
        const std::vector<TempoPointSpec> map =
            ramp ? std::vector<TempoPointSpec>{{0, 120, false}, {12, 180, true}} : std::vector<TempoPointSpec>{{0, 120, false}};
        ProjectSpec p = cawtest::testSignalProject({}, 120, 8);
        p.tempoMap = map;
        p.timeSigs = sigs;
        Engine e(rate);
        e.setMasterBypass(true);
        e.setMetronome(true);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        e.play();
        std::vector<Click> want;
        for (int b = 0; b < 6; ++b) want.push_back({0, b % 3 == 0});
        for (int k = 0; k < 14; ++k) want.push_back({0, k % 7 == 0});
        std::vector<double> beats;
        for (int b = 0; b < 6; ++b) beats.push_back(b);
        for (int k = 0; k < 14; ++k) beats.push_back(6 + k * 0.5);
        for (size_t i = 0; i < want.size(); ++i)
            want[i].frame = static_cast<int64_t>(std::ceil(cawtest::strictTempoFrame(oracle(map), rate, beats[i] * 4)));
        const std::vector<Click> got = clicks(e, want.back().frame + 2000);
        CHECK_EQ(got.size(), want.size());
        for (size_t i = 0; i < got.size() && i < want.size(); ++i) {
            CHECK_EQ(got[i].frame, want[i].frame);
            CHECK_EQ(got[i].accent, want[i].accent);
        }
    }
}

TEST(the_metronome_with_one_tempo_and_signature_clicks_as_before) {
    // 4/4 at 100 BPM, 44.1 kHz (a beat is 26460 samples): every beat, the accent each bar.
    ProjectSpec p = cawtest::testSignalProject({}, 100, 4);
    Engine e(44100);
    e.setMasterBypass(true);
    e.setMetronome(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const std::vector<Click> got = clicks(e, 26460 * 9 - 300);
    CHECK_EQ(got.size(), 9u);
    for (size_t i = 0; i < got.size(); ++i) {
        CHECK_EQ(got[i].frame, static_cast<int64_t>(i) * 26460);
        CHECK_EQ(got[i].accent, i % 4 == 0);
    }
}

TEST(the_count_in_ticks_at_the_signature_and_tempo_where_playback_starts) {
    // Playing from beat 8 (a 6/8 bar at 90 BPM): six eighth-note clicks of 16000 samples, the accent on the first.
    ProjectSpec p = cawtest::testSignalProject({}, 120, 8);
    p.tempoMap = {{0, 120, false}, {8, 90, false}};
    p.timeSigs = {{0, 0, 4, 4}, {2, 8, 6, 8}};
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.playCountIn(32, 6);
    const std::vector<Click> got = clicks(e, 6 * 16000 - 1000);
    CHECK_EQ(got.size(), 6u);
    for (size_t i = 0; i < got.size(); ++i) {
        CHECK_EQ(got[i].frame, static_cast<int64_t>(i) * 16000);
        CHECK_EQ(got[i].accent, i == 0);
    }
}

TEST(midi_files_round_trip_the_tempo_map_and_signatures) {
    PatternResult pr = parsePattern("---\nkind: pattern\nlength: 4 bars\n---\n0 C4 1 1\n17 E4 2 0.5\n");
    CHECK(pr.pattern != nullptr);
    if (!pr.pattern) return;
    MidiSongMeta song;
    song.tempo = {{0, 120, false}, {8, 96, false}, {16, 150, false}, {20.5, 125, false}};
    song.sigs = {{0, 0, 4, 4}, {2, 8, 3, 4}, {4, 14, 7, 8}};
    for (const bool clip : {false, true}) {
        const std::vector<uint8_t> bytes = clip ? patternToMidiClip(*pr.pattern, song) : patternToSmf(*pr.pattern, song);
        std::string error;
        MidiSongMeta back;
        const std::string text = patternFromMidi(bytes.data(), bytes.size(), MidiImportOptions{}, error, &back);
        CHECK(!text.empty());
        CHECK_EQ(back.tempo.size(), song.tempo.size());
        for (size_t i = 0; i < back.tempo.size() && i < song.tempo.size(); ++i) {
            CHECK_EQ(back.tempo[i].beat, song.tempo[i].beat);
            CHECK_EQ(back.tempo[i].bpm, song.tempo[i].bpm);
            CHECK(!back.tempo[i].ramp);
        }
        CHECK_EQ(back.sigs.size(), song.sigs.size());
        for (size_t i = 0; i < back.sigs.size() && i < song.sigs.size(); ++i) {
            CHECK_EQ(back.sigs[i].bar, song.sigs[i].bar);
            CHECK_EQ(back.sigs[i].beat, song.sigs[i].beat);
            CHECK_EQ(back.sigs[i].num, song.sigs[i].num);
            CHECK_EQ(back.sigs[i].den, song.sigs[i].den);
        }
    }
    // The old export (one tempo, one meter) is unchanged by the map's writer.
    const std::vector<uint8_t> a = patternToSmf(*pr.pattern, 133, 3);
    MidiSongMeta one;
    one.tempo = {{0, 133, false}};
    one.sigs = {{0, 0, 3, 4}};
    CHECK(a == patternToSmf(*pr.pattern, one));
    // A ramp becomes stepped tempo events whose stretches keep the ramp's time.
    MidiSongMeta ramp;
    ramp.tempo = {{0, 120, false}, {8, 60, true}};
    TempoMap exact;
    exact.build(ramp.tempo, 48000);
    for (const bool clip : {false, true}) {
        const std::vector<uint8_t> bytes = clip ? patternToMidiClip(*pr.pattern, ramp) : patternToSmf(*pr.pattern, ramp);
        std::string error;
        MidiSongMeta back;
        CHECK(!patternFromMidi(bytes.data(), bytes.size(), MidiImportOptions{}, error, &back).empty());
        CHECK_EQ(back.tempo.size(), 33u);  // 32 sixteenth stretches and the end
        TempoMap stepped;
        stepped.build(back.tempo, 48000);
        for (const double beat : {1.0, 4.0, 8.0, 10.0}) CHECK_NEAR(stepped.secondsAt(beat), exact.secondsAt(beat), 2e-5);
    }
    // The C API returns them as JSON.
    const std::vector<uint8_t> bytes = patternToSmf(*pr.pattern, song);
    char* json = caw_pattern_from_midi(bytes.data(), static_cast<int32_t>(bytes.size()));
    Json j;
    std::string error;
    CHECK(json && parseJson(json, j, error));
    caw_free(json);
    std::vector<TempoPointSpec> pts;
    std::vector<TimeSigSpec> sigs;
    CHECK(j.get("tempo_map") && readTempoMap(*j.get("tempo_map"), pts, error) && pts.size() == 4);
    CHECK(j.get("time_signatures") && readTimeSigs(*j.get("time_signatures"), sigs, error) && sigs.size() == 3);
}

TEST(a_tempo_synced_delay_follows_the_tempo_at_the_playhead) {
    // A ping-pong delay synced to a quarter note: an impulse at beat 0 (120 BPM) echoes 0.5 s later, one at beat 12,
    // after the tempo stepped to 60 at beat 8, echoes 1 s later.
    const int rate = 16000;
    ProjectSpec p = impulseProject(noteLines({0, 48}), 64, 4);
    ComponentSpec delay;
    delay.id = "org.caw.delay.pingpong";
    delay.params = {{"sync", 4}, {"feedback", 0}, {"mix", 0.5}};
    p.layers[0].components = {delay};
    p.tempoMap = {{0, 120, false}, {8, 60, false}};
    Engine e(rate);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(256), r(256), sum;
    for (int64_t i = 0; i < rate * 10; i += 256) {
        e.process(l.data(), r.data(), 256);
        for (int k = 0; k < 256; ++k) sum.push_back(std::fabs(l[static_cast<size_t>(k)]) + std::fabs(r[static_cast<size_t>(k)]));
    }
    std::vector<int64_t> peaks;
    for (size_t i = 0; i < sum.size(); ++i)
        if (sum[i] > 0.05f && (peaks.empty() || static_cast<int64_t>(i) - peaks.back() > rate / 10)) peaks.push_back(static_cast<int64_t>(i));
    CHECK_EQ(peaks.size(), 4u);
    if (peaks.size() == 4) {
        CHECK_EQ(peaks[0], 0);
        CHECK(std::llabs(peaks[1] - rate / 2) <= 2);
        CHECK_EQ(peaks[2], 8 * rate);
        CHECK(std::llabs(peaks[3] - 9 * rate) <= 2);
    }
    // What a component sees: the tempo and beat at its block's first frame.
    SongTime song = songTimeOf(p, rate);
    ChainTime t;
    t.song = &song;
    t.start = 9 * rate;
    const Transport tr = t.transportAt(true);
    CHECK_EQ(tr.tempo, 60.0);
    CHECK_NEAR(tr.beat, 13.0, 1e-12);
}

TEST(one_tempo_projects_render_the_same_bits_with_or_without_a_map) {
    // A project with automation, a looping layer and a loop range, played as before (no map), and with a map whose
    // points never change the tempo and the signature its beats per bar make: the same output to the bit.
    ProjectSpec p = impulseProject(noteLines({0, 3.5, 7, 13.25}), 16, 2);
    p.bpm = 133;
    p.layers[0].instrument.params.push_back({"shape", static_cast<double>(cawtest::Shape::Saw)});
    ProjectAutomationLaneSpec lane;
    lane.targetType = "instrument";
    lane.moduleId = "l0";
    lane.target = "level";
    lane.points = {{0, 0.2}, {20, 1.0}, {32, 0.5}};
    p.automation.push_back(lane);
    p.loopRange = true;
    p.loopStartSteps = 4;
    p.loopEndSteps = 28;
    ProjectSpec q = p;
    q.tempoMap = {{0, 133, false}, {3, 133, false}, {6, 133, true}};
    q.timeSigs = {{0, 0, 4, 4}};
    std::vector<float> a, b;
    for (auto* out : {&a, &b}) {
        Engine e(44100);
        e.setMetronome(true);
        CHECK(e.setProject(out == &a ? p : q).find("\"ok\":true") != std::string::npos);
        e.play();
        std::vector<float> l(173), r(173);
        for (int k = 0; k < 2000; ++k) {
            e.process(l.data(), r.data(), 173);
            out->insert(out->end(), l.begin(), l.end());
            out->insert(out->end(), r.begin(), r.end());
        }
    }
    CHECK(a == b);
    CHECK(*std::max_element(a.begin(), a.end()) > 0.01f);
    CHECK_EQ(stepFrame(q, 44100, 37), static_cast<int64_t>(sampletime::roundFrames(37, sampletime::stepFrames(44100, 133))));
}

TEST(renders_follow_the_tempo_map) {
    ProjectSpec p = impulseProject(noteLines({0}), 64, 4);
    p.tempoMap = kRamped;
    for (const int64_t steps : {0, 17, 48, 64, 200}) CHECK_EQ(stepFrame(p, 48000, steps), expectedFrame(kRamped, 48000, steps));
}

TEST(the_c_api_sets_the_tempo_map_and_reports_the_position) {
    CawEngine* e = caw_engine_create(48000);
    CHECK(e != nullptr);
    if (!e) return;
    const char* project = R"({"caw_project":1,"bpm":120,"loop_bars":8,"layers":[]})";
    char* r = caw_engine_set_project(e, project);
    caw_free(r);
    const CawTempoPoint pts[] = {{8, 60, 0}, {0, 120, 0}, {12, 90, 1}};  // unsorted: sorted here
    CHECK_EQ(caw_engine_set_tempo_map(e, pts, 3), 0);
    const CawTempoPoint badPts[] = {{0, 2000, 0}};
    CHECK_EQ(caw_engine_set_tempo_map(e, badPts, 1), 1);
    CHECK_EQ(caw_engine_set_tempo_map(e, nullptr, 1), 1);
    const CawTimeSig sigs[] = {{0, 3, 4}, {6, 6, 8}};
    CHECK_EQ(caw_engine_set_time_signatures(e, sigs, 2), 0);
    const CawTimeSig offBar[] = {{0, 3, 4}, {4, 6, 8}};
    CHECK_EQ(caw_engine_set_time_signatures(e, offBar, 2), 1);
    caw_engine_play_at(e, 40);  // beat 10: 60 BPM, then the ramp toward 90
    std::vector<float> l(480), rr(480);
    for (int k = 0; k < 100; ++k) caw_engine_process(e, l.data(), rr.data(), 480);  // one second
    CawPosition pos{};
    CHECK_EQ(caw_engine_position(e, &pos), 2);
    pos.struct_size = sizeof(CawPosition);
    CHECK_EQ(caw_engine_position(e, &pos), 0);
    CHECK_EQ(pos.playing, 1);
    // The ramp from 60 BPM at beat 8 toward 90 at beat 12: beat 10 is at 4 + 8 ln 1.25 s; one second on from there.
    TempoMap m;
    m.build({{0, 120, false}, {8, 60, false}, {12, 90, true}}, 48000);
    CHECK_NEAR(m.secondsAt(10), 4 + 8 * std::log(1.25), 1e-12);
    CHECK_EQ(pos.frame, static_cast<int64_t>(m.roundFrame(40)) + 48000);
    CHECK_NEAR(pos.seconds, static_cast<double>(pos.frame) / 48000, 1e-12);
    CHECK_NEAR(pos.beat, m.stepAt(static_cast<double>(pos.frame)) / 4, 1e-12);
    CHECK(pos.beat > 11 && pos.beat < 11.5);
    CHECK_NEAR(pos.bpm, 60 + 7.5 * (pos.beat - 8), 1e-9);
    // 3/4 for two bars (6 beats), then 6/8 bars of 3 beats: bar 3 (0-based) starts at beat 9.
    CHECK_EQ(pos.bar, 3);
    CHECK_NEAR(pos.beat_in_bar, pos.beat - 9, 1e-12);
    CHECK(pos.num == 6 && pos.den == 8);
    CHECK_EQ(caw_engine_set_bpm(e, 90), 0);
    CHECK_EQ(caw_engine_set_bpm(e, 0), 1);
    caw_engine_destroy(e);
}

namespace {

struct VectorMap {
    const char* name;
    std::vector<TempoPointSpec> points;
};

const std::vector<VectorMap> kVectorMaps = {
    {"constant", {{0, 120, false}}},
    {"stepped", {{0, 120, false}, {8, 90, false}, {16, 140, false}, {18.5, 72.5, false}}},
    {"ramp", {{0, 100, false}, {16, 160, true}}},
    {"mixed", {{0, 60, false}, {4, 180, true}, {10, 75, false}, {20, 50, true}, {24, 50, false}, {28, 200, true}}},
};
const double kVectorBeats[] = {0, 0.25, 0.5, 1, 2.25, 3.999, 4, 6, 7.75, 8, 10, 12.5, 16, 18.5, 20, 22, 24, 26, 28, 31.5, 40};

std::string vectorsPath() { return std::string(CAW_ROOT) + "/engine/tests/references/tempo_vectors.json"; }

}  // namespace

TEST(tempo_vectors_shared_with_the_app_match_the_engine) {
    // engine/tests/references/tempo_vectors.json: (beat, seconds) pairs for four maps, which the app's tempo maths
    // checks itself against. `caw_tests --update-references tempo_vectors_shared_with_the_app_match_the_engine`
    // writes it again from the engine.
    if (cawtest::updateGolden) {
        std::string out = "{\n  \"about\": \"Tempo maps and (beat, seconds) pairs from the engine's TempoMap (engine/src/tempo_map.h): "
                          "the app's beat<->seconds maths must agree within 1e-9 s.\",\n  \"maps\": [\n";
        for (size_t m = 0; m < kVectorMaps.size(); ++m) {
            TempoMap tm;
            tm.build(kVectorMaps[m].points, 48000);
            out += "    {\"name\": \"" + std::string(kVectorMaps[m].name) + "\", \"tempo_map\": [";
            char b[160];
            for (size_t i = 0; i < kVectorMaps[m].points.size(); ++i) {
                const TempoPointSpec& p = kVectorMaps[m].points[i];
                std::snprintf(b, sizeof b, "%s{\"beat\": %.17g, \"bpm\": %.17g, \"ramp\": %s}", i ? ", " : "", p.beat, p.bpm,
                              p.ramp ? "true" : "false");
                out += b;
            }
            out += "],\n      \"vectors\": [";
            bool first = true;
            for (const double beat : kVectorBeats) {
                std::snprintf(b, sizeof b, "%s[%.17g, %.17g]", first ? "" : ", ", beat, tm.secondsAt(beat));
                out += b;
                first = false;
            }
            out += std::string("]}") + (m + 1 < kVectorMaps.size() ? "," : "") + "\n";
        }
        out += "  ]\n}\n";
        std::ofstream(vectorsPath(), std::ios::binary) << out;
    }
    std::ifstream in(vectorsPath(), std::ios::binary);
    std::stringstream ss;
    ss << in.rdbuf();
    Json j;
    std::string error;
    CHECK(parseJson(ss.str(), j, error));
    const Json* maps = j.get("maps");
    CHECK(maps && maps->arr.size() == kVectorMaps.size());
    if (!maps) return;
    int checked = 0;
    for (const Json& m : maps->arr) {
        std::vector<TempoPointSpec> pts;
        CHECK(m.get("tempo_map") && readTempoMap(*m.get("tempo_map"), pts, error));
        TempoMap tm;
        tm.build(pts, 48000);
        for (const Json& v : m.get("vectors")->arr) {
            const double beat = v.arr[0].num, sec = v.arr[1].num;
            CHECK_NEAR(tm.secondsAt(beat), sec, 1e-12);
            CHECK_NEAR(tm.beatAt(sec), beat, 1e-9);
            CHECK_NEAR(cawtest::strictTempoFrame(oracle(pts), 48000, beat * 4) / 48000.0, sec, 1e-9);
            CHECK_NEAR(integratedSeconds(pts, beat), sec, 1e-9);
            ++checked;
        }
    }
    CHECK(checked >= 80);
}

TEST(tempo_maps_swap_while_another_thread_plays) {
    // The control thread sets maps, signatures and projects and reads the position while the audio thread plays a
    // song: a looping track, a synced delay and the metronome.
    ProjectSpec p = impulseProject(noteLines({0, 3, 7.5}), 16, 2);
    ComponentSpec delay;
    delay.id = "org.caw.delay.pingpong";
    delay.params = {{"sync", 3}};
    p.layers[0].components = {delay};
    p.tempoMap = kRamped;
    Engine e(48000);
    e.setMetronome(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::atomic<bool> stop{false};
    std::atomic<float> peak{0};
    std::thread audio([&] {
        std::vector<float> l(128), r(128);
        while (!stop.load()) {
            e.process(l.data(), r.data(), 128);
            for (float v : l) if (std::fabs(v) > peak.load(std::memory_order_relaxed)) peak.store(std::fabs(v), std::memory_order_relaxed);
        }
    });
    for (int k = 0; k < 60; ++k) {
        if (k % 3 == 0) CHECK(e.setTempoMap({{0, 90.0 + k, false}, {2, 140, true}}).empty());
        if (k % 3 == 1) CHECK(e.setTimeSignatures({{0, 0, 3 + k % 5, 8}}).empty());
        if (k % 3 == 2) {
            p.tempoMap = k % 2 ? kStepped : std::vector<TempoPointSpec>{};
            CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        }
        const Engine::SongPosition pos = e.position();
        CHECK(pos.beat >= 0 && std::isfinite(pos.seconds));
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
    }
    stop.store(true);
    audio.join();
    CHECK(peak.load() > 0.01f);
}
