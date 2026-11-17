// MIDI clip playback (#226): held notes chased at play, loops and passes; bends past an octave; a clip's last part repeat.
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "caw/instrument.hpp"
#include "engine.h"
#include "midifile.h"
#include "pattern.h"
#include "render.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

using cawtest::Shape;

constexpr double kPi = 3.14159265358979323846;
constexpr int kStep = 6000;  // frames in a step at 120 BPM and 48 kHz
const float kCentre = static_cast<float>(std::cos(kPi / 4.0));  // the mixer's centre pan gain

std::vector<float> run(Engine& e, int64_t frames, int block = 64) {
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += block) {
        const int n = static_cast<int>(std::min<int64_t>(block, frames - i));
        e.process(l.data() + i, r.data() + i, n);
    }
    return l;
}

// A one-track project playing `pattern` on the test signal in Notes mode.
ProjectSpec oneTrack(const std::string& pattern, Shape shape, int bars = 1, cawtest::Params params = {}) {
    ProjectSpec p = cawtest::testSignalProject({}, 120, bars);
    p.modules.push_back({"p", pattern});
    p.layers.push_back(cawtest::testSignalNotesLayer("t", shape, "p", std::move(params)));
    return p;
}

// The pitch a rising saw (level 1, centre pan) plays over [from, to): its slope, skipping the wraps, as a MIDI note.
double sawPitch(const std::vector<float>& v, size_t from, size_t to) {
    double sum = 0;
    int n = 0;
    for (size_t i = from + 1; i < to; ++i) {
        const double d = static_cast<double>(v[i]) - v[i - 1];
        if (d <= 0) continue;  // a wrap
        sum += d;
        ++n;
    }
    if (n == 0) return -1000;
    const double hz = sum / n / kCentre * 48000.0 / 2.0;
    return 69.0 + 12.0 * std::log2(hz / 440.0);
}

bool silent(const std::vector<float>& v, size_t from, size_t to) {
    for (size_t i = from; i < to; ++i)
        if (v[i] != 0.0f) return false;
    return true;
}

}  // namespace

// The owner (#226): "when you move the cursor around it doesn't wait for note starts". Play from the middle of a long
// note bending a fifth up through it: it sounds at once, at the pitch its bend has there, and bends on from it.
TEST(a_long_bent_note_started_in_its_middle_sounds_at_once_at_its_bent_pitch) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(oneTrack("---\nkind: pattern\nlength: 16\n---\n0 C4 16 1 bend 0:0 1:16\n", Shape::Saw))
              .find("\"ok\":true") != std::string::npos);
    e.play(8);  // halfway: the bend is at +8 semitones
    const auto out = run(e, 4 * kStep);
    CHECK(!silent(out, 0, 64));
    CHECK_NEAR(sawPitch(out, 600, 1600), 68.1, 0.15);  // after Play's 10 ms fade-in (step 8.1: +8.1)
    CHECK_NEAR(sawPitch(out, 2 * kStep, 2 * kStep + 1000), 70.1, 0.15);  // step 10: +10
}

// Looping back into a held note picks it up again: the loop range 4..12 inside a note 0..16, and a second track
// whose layer loops every 8 steps (its own passes) with a note across its pass start.
TEST(looping_back_into_a_held_note_sounds_it_from_the_loop_start) {
    ProjectSpec p = oneTrack("---\nkind: pattern\nlength: 16\n---\n0 C4 16 1 bend 0:0 1:16\n", Shape::Saw);
    p.loopRange = true;
    p.loopStartSteps = 4;
    p.loopEndSteps = 12;
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 16 * kStep);
    // 0..12, then 4..12 again from frame 12 steps: the bend restarts at +4.
    CHECK(!silent(out, 12 * kStep, 12 * kStep + 64));
    CHECK_NEAR(sawPitch(out, 12 * kStep, 12 * kStep + 1000), 64.0, 0.15);
    CHECK_NEAR(sawPitch(out, 14 * kStep, 14 * kStep + 1000), 66.0, 0.15);
}

// Export equals live: a loop export of a loop range starting inside a held note equals playback's second pass.
TEST(a_chased_note_exports_as_it_plays) {
    ProjectSpec p = oneTrack("---\nkind: pattern\nlength: 16\n---\n0 C4 16 1 bend 0:0 1:16\n", Shape::Saw);
    p.loopRange = true;
    p.loopStartSteps = 4;
    p.loopEndSteps = 12;
    p.master = 1.0;
    RenderResult r;
    ExportOptions o;
    CHECK(renderExport(p, o, r));
    CHECK_EQ(r.frames, int64_t{8 * kStep});
    Engine e(48000);
    e.setProject(p);
    e.play();
    const int64_t total = 12 * kStep + r.frames;
    std::vector<float> l(static_cast<size_t>(total)), rr(static_cast<size_t>(total));
    for (int64_t i = 0; i < total; i += 441) {
        const int n = static_cast<int>(std::min<int64_t>(441, total - i));
        e.process(l.data() + i, rr.data() + i, n);
    }
    bool same = true, heard = false;
    for (int64_t i = 0; i < r.frames && same; ++i) {
        same = r.samples[static_cast<size_t>(i) * 2] == l[static_cast<size_t>(12 * kStep + i)];
        heard = heard || (i < 64 && r.samples[static_cast<size_t>(i) * 2] != 0.0f);
    }
    CHECK(same);
    CHECK(heard);
    std::vector<float> file(static_cast<size_t>(r.frames));
    for (int64_t i = 0; i < r.frames; ++i) file[static_cast<size_t>(i)] = r.samples[static_cast<size_t>(i) * 2];
    CHECK_NEAR(sawPitch(file, 0, 1000), 64.0, 0.15);  // the bend as it is at step 4
}

// The owner (#226): "remove the limit where you can only bend an octave". A three-octave bend plays at its pitch.
TEST(a_three_octave_bend_plays_at_its_pitch) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(oneTrack("---\nkind: pattern\nlength: 16\n---\n0 C2 16 1 bend 0:36 1:36\n", Shape::Saw))
              .find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 2 * kStep);
    CHECK_NEAR(sawPitch(out, kStep, kStep + 1000), 72.0, 0.15);
    // Down as far: C7 bent 36 down plays C4.
    Engine d(48000);
    d.setMasterBypass(true);
    CHECK(d.setProject(oneTrack("---\nkind: pattern\nlength: 16\n---\n0 C7 16 1 bend 0:-36 1:-36\n", Shape::Saw))
              .find("\"ok\":true") != std::string::npos);
    d.play();
    const auto down = run(d, 2 * kStep);
    CHECK_NEAR(sawPitch(down, kStep, kStep + 4000), 60.0, 0.15);
}

TEST(a_bend_reads_to_96_semitones_and_no_further) {
    CHECK(parsePattern("---\nkind: pattern\n---\n0 C4 4 1 bend 0:0 1:96\n").error.empty());
    CHECK(parsePattern("---\nkind: pattern\n---\n0 C4 4 1 bend 0:0 1:-96\n").error.empty());
    CHECK(!parsePattern("---\nkind: pattern\n---\n0 C4 4 1 bend 0:0 1:97\n").error.empty());
    CHECK(!parsePattern("---\nkind: pattern\n---\n0 C4 4 1 bend 0:0 1:90 vib 7 5\n").error.empty());
}

// An extreme bend reaches the instrument no higher than the engine's Nyquist and no lower than its floor, so no
// oscillator runs past half the rate; the output stays finite.
TEST(an_extreme_bend_stays_below_nyquist_and_finite) {
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(oneTrack("---\nkind: pattern\nlength: 16\n---\n0 G9 16 1 bend 0:96 1:96\n", Shape::Saw))
              .find("\"ok\":true") != std::string::npos);
    e.play();
    const auto out = run(e, 2 * kStep);
    bool finite = true;
    for (float v : out) finite = finite && std::isfinite(v) && std::fabs(v) <= 1.0f;
    CHECK(finite);
    // The saw at Nyquist rises by 2 a frame (it wraps every other frame): never faster.
    for (size_t i = kStep + 1; i < static_cast<size_t>(kStep + 200); ++i)
        if (out[i] - out[i - 1] > 0) CHECK(out[i] - out[i - 1] <= 2.0f * kCentre + 1e-4f);
}

// The built-in instruments take any pitch the engine sends (its range, kMinNotePitch..Nyquist) without NaN or a blow-up.
TEST(the_built_in_instruments_stay_finite_at_extreme_pitches) {
    for (const char* id : {"org.caw.synth.flagship", "org.caw.sampler", "org.caw.drums"}) {
        for (const char* bend : {"0:96 1:96", "0:-96 1:-96", "0:-96 1:96"}) {
            for (const char* key : {"C0", "G9"}) {
                ProjectSpec p = cawtest::testSignalProject({}, 120, 1);
                p.modules.push_back({"p", std::string("---\nkind: pattern\nlength: 16\n---\n0 ") + key + " 8 1 bend " + bend + "\n"});
                LayerSpec l;
                l.id = "t";
                l.volume = 1.0;
                l.hasInstrument = true;
                l.instrument.id = id;
                l.pattern = "p";
                p.layers.push_back(l);
                Engine e(48000);
                e.setMasterBypass(true);
                const std::string result = e.setProject(p);
                if (result.find("\"ok\":true") == std::string::npos) cawtest::fail(__FILE__, __LINE__, result);
                e.play();
                const auto out = run(e, 10 * kStep, 256);
                float peak = 0;
                bool finite = true;
                for (float v : out) {
                    finite = finite && std::isfinite(v);
                    peak = std::max(peak, std::fabs(v));
                }
                if (!finite || peak > 4.0f)
                    cawtest::fail(__FILE__, __LINE__, std::string(id) + " " + key + " bend " + bend + ": peak " + std::to_string(peak));
            }
        }
    }
}

// A five-octave bend fits a MIDI export: the MPE bend range (RPN 0 on each member channel) widens to 96 semitones and
// the bend's 14-bit values read back as the bend.
TEST(a_bend_past_four_octaves_exports_with_a_bend_range_that_holds_it) {
    const PatternResult r = parsePattern("---\nkind: pattern\nlength: 16\n---\n0 C3 16 1 bend 0:0 1:60\n");
    CHECK(r.pattern != nullptr);
    if (!r.pattern) return;
    const std::vector<uint8_t> bytes = patternToSmf(*r.pattern, 120, 4);
    // Scan the note track's channel messages (running status is not used by the writer).
    int range = -1, most = 8192;
    for (size_t i = 0; i + 2 < bytes.size(); ++i) {
        const uint8_t st = bytes[i];
        if ((st & 0xF0) == 0xB0 && (st & 0x0F) != 0 && bytes[i + 1] == 6 && i >= 6 && bytes[i - 2] == 0 && bytes[i - 3] == 100)
            range = bytes[i + 2];
        if ((st & 0xF0) == 0xE0 && (st & 0x0F) != 0 && bytes[i + 1] < 0x80 && bytes[i + 2] < 0x80)
            most = std::max(most, bytes[i + 1] | (bytes[i + 2] << 7));
    }
    CHECK_EQ(range, 96);
    const double reached = (most - 8192) / 8192.0 * range;
    CHECK(reached > 59.0 && reached <= 60.01);  // its last 1/32-note value, just short of the end
}

namespace {

// A clip `length` steps long repeating its pattern every `loop` steps; the pattern's notes each have their own
// velocity, so the DC test signal's level says which note sounds.
std::vector<float> clipRender(const std::string& notes, int patternSteps, int loop, int length, int bars,
                              bool tempoMap = false) {
    ProjectSpec p = cawtest::testSignalProject({}, 120, bars);
    p.modules.push_back({"p", "---\nkind: pattern\nlength: " + std::to_string(patternSteps) + "\n---\n" + notes});
    if (tempoMap) p.tempoMap = {{0, 120, false}, {1000, 120, false}};
    LayerSpec layer = cawtest::testSignalNotesLayer("t", Shape::Dc, "", {});
    ClipSpec clip{"c", "p", 0, length, 0, true};
    clip.loopSteps = loop;
    layer.clips.push_back(clip);
    p.layers.push_back(layer);
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    return run(e, static_cast<int64_t>(bars) * 16 * kStep);
}

float level(double vel) { return static_cast<float>(vel) * kCentre; }

}  // namespace

// The owner (#226): "four bars of stuff, repeat every four bars, but the clip is five bars: it plays all four of those
// bars in the last bar". Bar 5 plays bar 1 again, cut at the clip's end: a note held into the end stops there.
TEST(a_clip_longer_than_its_repeat_plays_the_repeat_s_start_cut_at_its_end) {
    // Bar 1: 0.1 at 0..4 and 0.2 at 8..20 (held across the bar line); 0.3, 0.4, 0.5 open bars 2, 3, 4.
    const std::string notes = "0 C4 4 0.1\n8 D4 12 0.2\n20 E4 4 0.3\n36 F4 4 0.4\n52 G4 4 0.5\n";
    for (const bool map : {false, true}) {
        const auto out = clipRender(notes, 64, 64, 80, 6, map);
        const auto at = [&](double step) { return out[static_cast<size_t>(step * kStep)]; };
        CHECK_NEAR(at(64.5), level(0.1), 1e-4);  // bar 5 opens as bar 1 did
        CHECK_NEAR(at(67.9), level(0.1), 1e-4);
        CHECK_NEAR(at(68.5), 0.0, 1e-6);
        CHECK_NEAR(at(72.5), level(0.2), 1e-4);  // the held note, from its own start
        CHECK_NEAR(out[80 * kStep - 1], level(0.2), 1e-4);
        CHECK(silent(out, 80 * kStep, 96 * kStep));  // cut at the clip's end; nothing of bars 2-4 squeezed in
        CHECK(silent(out, static_cast<size_t>(68 * kStep), static_cast<size_t>(72 * kStep)));
    }
}

// Three bars repeating in an eight-bar clip: passes at bars 1, 4 and 7, the last cut after its second bar.
TEST(a_three_bar_repeat_in_an_eight_bar_clip_keeps_exact_timing) {
    const std::string notes = "0 C4 2 0.1\n16 D4 2 0.2\n32 E4 20 0.3\n";
    const auto out = clipRender(notes, 48, 48, 128, 9);
    for (const int pass : {0, 48, 96}) {
        CHECK_NEAR(out[static_cast<size_t>(pass * kStep)], level(0.1), 1e-4);  // on its exact frame
        CHECK_NEAR(out[static_cast<size_t>(pass * kStep) - (pass ? 1 : 0)], pass ? level(0.3) : level(0.1), 1e-4);
        CHECK_NEAR(out[static_cast<size_t>((pass + 16) * kStep)], level(0.2), 1e-4);
        CHECK_NEAR(out[static_cast<size_t>((pass + 32) * kStep)], pass < 96 ? level(0.3) : 0.0f, 1e-4);
    }
    // The held note: to its pass's end at 48 and 96; the last pass stops at the clip's end, 128 (pass step 32).
    CHECK_NEAR(out[static_cast<size_t>(47.9 * kStep)], level(0.3), 1e-4);
    CHECK_NEAR(out[static_cast<size_t>(113 * kStep)], level(0.2), 1e-4);  // the last pass's 0.2 note, 112..114
    CHECK(silent(out, 114 * kStep, 128 * kStep));
    CHECK(silent(out, 128 * kStep, 144 * kStep));
}

// The owner's case (#226): a four-bar note bending up through the chords, repeating every four bars in a five-bar
// clip. Bar 5 plays the note's first bar, cut there: its bend is the first bar's, not all four bars' squeezed in.
TEST(a_bent_note_cut_at_a_clip_s_end_keeps_its_bend_where_it_was) {
    ProjectSpec p = cawtest::testSignalProject({}, 120, 6);
    p.modules.push_back({"p", "---\nkind: pattern\nlength: 64\n---\n0 C4 64 1 bend 0:0 1:16\n"});
    LayerSpec layer = cawtest::testSignalNotesLayer("t", Shape::Saw, "", {});
    ClipSpec clip{"c", "p", 0, 80, 0, true};
    clip.loopSteps = 64;
    layer.clips.push_back(clip);
    // A second clip starting 32 steps into the same note (a source offset): it plays the note's second half.
    LayerSpec offset = cawtest::testSignalNotesLayer("u", Shape::Saw, "", {});
    offset.clips.push_back({"d", "p", 0, 32, 32, false});
    offset.mute = true;
    p.layers.push_back(layer);
    p.layers.push_back(offset);
    for (const bool second : {false, true}) {
        p.layers[0].mute = second;
        p.layers[1].mute = !second;
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        e.play();
        const auto out = run(e, 80 * kStep);
        if (!second) {
            CHECK_NEAR(sawPitch(out, 8 * kStep, 8 * kStep + 1000), 62.0, 0.15);    // bar 1, step 8: +2
            CHECK_NEAR(sawPitch(out, 72 * kStep, 72 * kStep + 1000), 62.0, 0.15);  // bar 5, step 8: +2 again
        } else {
            CHECK_NEAR(sawPitch(out, 0, 1000), 68.0, 0.15);                        // source step 32: +8
            CHECK_NEAR(sawPitch(out, 16 * kStep, 16 * kStep + 1000), 72.0, 0.15);  // source step 48: +12
        }
    }
}
