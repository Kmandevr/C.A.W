// Pattern tests: the note format and its errors, and patterns played on a track (the test signal's Notes mode).
#include <cmath>
#include <string>
#include <vector>

#include "detmath.h"
#include "engine.h"
#include "pattern.h"
#include "render.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

const std::string kHead = "---\nkind: pattern\n---\n";
const double kPanGain = std::cos(kPi / 4.0);  // centre pan, as the mixer applies it

bool has(const std::string& s, const char* part) { return s.find(part) != std::string::npos; }

std::string patternError(const std::string& body) { return parsePattern(kHead + body).error; }

// A track playing `notes` (pattern "p") on the test signal in Notes mode: DC at `level` times each held note's
// velocity (an Impulse instead marks each note's first sample), at 120 BPM (6000 samples per step at 48 kHz).
ProjectSpec voicedProject(double level, const std::string& notes, int loopBars = 4,
                          cawtest::Shape shape = cawtest::Shape::Dc) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = loopBars;
    p.seed = 3;
    p.master = 1.0;
    p.modules.push_back({"p", notes.rfind("---", 0) == 0 ? notes : kHead + notes, {}});
    p.layers = {cawtest::testSignalNotesLayer("l", shape, "p", {{"level", level}})};
    return p;
}

// Runs `frames` more samples and returns the generator's output (left channel without the centre-pan gain).
std::vector<double> run(Engine& e, int64_t frames) {
    std::vector<float> lf(static_cast<size_t>(frames)), rf(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += 64)
        e.process(lf.data() + i, rf.data() + i, static_cast<int>(std::min<int64_t>(64, frames - i)));
    std::vector<double> out(lf.size());
    for (size_t i = 0; i < lf.size(); ++i) out[i] = lf[i] / kPanGain;
    return out;
}

// The track's output for `frames` samples: the left channel divided by the centre-pan gain.
std::vector<double> play(double level, const std::string& notes, int64_t frames, int loopBars = 4,
                         cawtest::Shape shape = cawtest::Shape::Dc) {
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string res = e.setProject(voicedProject(level, notes, loopBars, shape));
    if (!has(res, "\"ok\":true")) cawtest::fail(__FILE__, __LINE__, "project failed: " + res);
    e.play();
    return run(e, frames);
}

}  // namespace

// Pattern text parses without the .caw compiler (#160 removes it): note names live in pattern.h.
TEST(pattern_note_names_need_no_compiler) {
    double v = 0;
    CHECK(noteNumber("C4", v) && v == 60);
    CHECK(noteNumber("F#2", v) && v == 42);
    CHECK(noteNumber("Bb0", v) && v == 22);
    CHECK(!noteNumber("H4", v));
    CHECK(!noteNumber("C", v));
    CHECK(!noteNumber("C10", v));
    PatternResult r = parsePattern(kHead + "0 C4 1 1\n");
    CHECK(r.pattern && r.pattern->notes.size() == 1 && r.pattern->notes[0].pitch == 60);
}

TEST(patterns_parse_notes_chords_and_extras) {
    PatternResult r = parsePattern(
        "---\nkind: pattern\nname: Test\nlength: 2 bars\n---\n// comment\n0 A2 2 0.5\n13/3 C3,E3 1/3 1 ratchet 2 prob 0.25\n"
        "4 60.5 2 slide\n6 B3 1\n");
    CHECK(r.error.empty());
    const Pattern& p = *r.pattern;
    CHECK(p.name == "Test" && p.lengthBars == 2 && p.steps(4) == 32 && p.steps(3) == 24);
    // Sorted by start: A2 at 0, 60.5 at 4, the C3,E3 chord at 13/3, B3 at 6.
    CHECK(p.notes.size() == 5);
    CHECK_EQ(p.notes[0].pitch, 45.0);
    CHECK_EQ(p.notes[0].vel, 0.5);
    CHECK_EQ(p.notes[1].pitch, 60.5);  // microtones are kept
    CHECK_NEAR(p.notes[2].at, 13.0 / 3.0, 1e-12);
    CHECK(p.notes[2].ratchet == 2 && p.notes[2].prob == 0.25 && p.notes[3].pitch == 52.0);
    CHECK(p.notes[1].slideTo == 4 && p.notes[4].slideFrom == 1);
    CHECK(p.events.size() == 2 * (1 + 2 + 2 + 1 + 1));
    // Without a length, a pattern covers the whole bars its notes need.
    CHECK(parsePattern(kHead + "0 C3 1\n17 C3 1\n").pattern->steps(4) == 32);
}

TEST(pattern_errors_point_at_the_problem) {
    CHECK(has(patternError("0 H3 1"), "line 4, col 3: expected a note"));
    CHECK(has(patternError("0 C3"), "a note line is"));
    CHECK(has(patternError("0 C3 1 2"), "velocity must be 0 to 1"));
    CHECK(has(patternError("0 C3 1 wobble"), "unknown extra 'wobble'"));
    CHECK(has(patternError("0 C3 1 ratchet 9"), "ratchet must be 1 to 8"));
    CHECK(has(patternError("[kick]\n0 C1 1"), "kit rows"));
    CHECK(has(parsePattern("0 C3 1\n").error, "needs 'kind: pattern'"));
}

TEST(notes_start_and_end_on_their_samples) {
    // Level times velocity shows exactly when each note sounds: 6000 samples per step, so step 4.5 is sample 27000.
    std::vector<double> y = play(1.0, "0 C4 1 0.5\n4.5 C4 1/2 1\n", 40000);
    CHECK_NEAR(y[0], 0.5, 1e-4);  // a velocity reaches the instrument as a 16-bit MIDI 2.0 value
    CHECK_NEAR(y[5999], 0.5, 1e-4);
    CHECK_NEAR(y[6000], 0.0, 1e-6);
    CHECK_NEAR(y[26999], 0.0, 1e-6);
    CHECK_NEAR(y[27000], 1.0, 1e-6);
    CHECK_NEAR(y[29999], 1.0, 1e-6);
    CHECK_NEAR(y[30000], 0.0, 1e-6);
}

TEST(chords_sound_one_note_each) {
    std::vector<double> y = play(0.1, "0 C3,E3,G3 4\n", 1000);
    CHECK_NEAR(y[500], 0.3, 1e-6);
    std::vector<double> z = play(0.1, "0 C3,D3,E3,F3,G3,A3,B3,C4,D4 4\n", 1000);
    CHECK_NEAR(z[500], 0.9, 1e-6);
}

TEST(probability_is_repeatable_and_varies_per_repeat) {
    // A one-step pattern repeats 64 times in a 4-bar loop; a 50% note plays on some repeats only.
    std::vector<double> a = play(1.0, "---\nkind: pattern\nlength: 1\n---\n0 C4 1/2 1 prob 0.5\n", 64 * 6000);
    std::vector<double> b = play(1.0, "---\nkind: pattern\nlength: 1\n---\n0 C4 1/2 1 prob 0.5\n", 64 * 6000);
    int played = 0;
    for (int k = 0; k < 64; ++k) played += a[static_cast<size_t>(k) * 6000 + 10] > 0.5;
    CHECK(played > 16 && played < 48);
    CHECK(a == b);
}

TEST(a_pattern_sets_the_layer_length) {
    // An 8-step pattern repeats every 8 steps even though the project loop is 4 bars.
    std::vector<double> y = play(1.0, "---\nkind: pattern\nlength: 8\n---\n0 C4 1\n", 100000, 4, cawtest::Shape::Impulse);
    CHECK(y[0] > 0.5 && y[48000] > 0.5 && y[96000] > 0.5);
}

TEST(exports_check_a_layers_pattern) {
    ProjectSpec p = voicedProject(0.3, "0 A4 1\n", 1);
    RenderResult out;
    CHECK(renderExport(p, ExportOptions{}, out));
    p.modules[0].source = kHead + "0 Z4 1\n";
    CHECK(!renderExport(p, ExportOptions{}, out) && has(out.error, "pattern 'p'"));
    p.layers[0].pattern = "nope";
    CHECK(!renderExport(p, ExportOptions{}, out) && has(out.error, "no pattern 'nope'"));
}

TEST(held_notes_are_released_by_seed_and_tempo_changes) {
    // A 50% note that plays with seed 3 must still end when the seed changes while it's held.
    ProjectSpec p = voicedProject(1.0, "---\nkind: pattern\nlength: 16\n---\n0 C4 2 1 prob 0.5\n");
    PatternResult pat = parsePattern(p.modules[0].source);
    uint32_t playSeed = 0, quietSeed = 0;
    for (uint32_t sd = 1; sd < 100 && (!playSeed || !quietSeed); ++sd)
        (notePlays(pat.pattern->notes[0], 0, 0, sd) ? playSeed : quietSeed) = sd;
    p.seed = playSeed;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    CHECK(run(e, 6000)[100] > 0.5);
    p.seed = quietSeed;
    e.setProject(p);
    CHECK_NEAR(run(e, 12000)[11000], 0.0, 1e-9);
    // A tempo change while a note is held lets it go instead of leaving it hanging.
    ProjectSpec q = voicedProject(1.0, "0 C4 8\n");
    Engine f(48000);
    f.setMasterBypass(true);
    f.setProject(q);
    f.play();
    CHECK(run(f, 3000)[2000] > 0.5);
    q.bpm = 90;
    f.setProject(q);
    CHECK_NEAR(run(f, 3000)[2000], 0.0, 1e-9);
}

TEST(packed_patterns_stay_cheap_and_late_notes_warn) {
    // 40 notes three samples apart: past 16 splits in a block the rest start together, and all still play.
    std::string notes;
    for (int k = 0; k < 40; ++k) notes += std::to_string(k) + "/2000 C4 1 0.01\n";
    std::vector<double> y = play(1.0, notes, 6000);
    CHECK(y[1000] > 0.07);  // every note sounds (velocity 0.01 each)
    Engine e(48000);
    std::string res = e.setProject(voicedProject(1.0, "---\nkind: pattern\nlength: 8\n---\n0 C4 1\n9 C4 1\n"));
    CHECK(has(res, "1 note starts after the pattern's length and never plays"));
}

TEST(a_pattern_edit_lets_a_sounding_note_follow_it) {
    // An 8-step note is shortened to 2 steps while it plays (owner, 2026-11-10, #170: a sounding note follows the
    // edit): it ends where the edited note ends (step 2), and the next pass plays the short version.
    ProjectSpec p = voicedProject(1.0, "---\nkind: pattern\nlength: 16\n---\n0 C4 8\n");
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    run(e, 6016);
    p.modules[0].source = "---\nkind: pattern\nlength: 16\n---\n0 C4 2\n";
    e.setProject(p);
    std::vector<double> y = run(e, 120000);
    const size_t at = 6016;  // samples already played
    CHECK(y[11990 - at] > 0.5);
    CHECK_NEAR(y[12100 - at], 0.0, 1e-9);
    CHECK_NEAR(y[47990 - at], 0.0, 1e-9);
    CHECK(y[96000 + 100 - at] > 0.5);
    CHECK_NEAR(y[96000 + 13000 - at], 0.0, 1e-9);
}

TEST(pattern_notes_are_matched_across_an_edit) {
    auto pat = [](const std::string& body) { return parsePattern(kHead + body).pattern; };
    // Unchanged notes keep their partner even when another note's move reorders them; a curve edit is the same note.
    auto a = pat("0 C4 4\n2 E4 4  bend 0:0 1:2\n3 G4 2\n");
    auto b = pat("0 C4 4\n2 E4 4  bend 0:0 1:-5\n1 G4 3\n");
    CHECK(a && b);
    if (!a || !b) return;
    // b sorted by start: C4 (0), G4 (1), E4 (2)
    std::vector<int> m = matchPatternNotes(*a, *b);
    CHECK_EQ(m.size(), size_t{3});
    CHECK(m.size() == 3 && m[0] == 0 && m[1] == 2 && m[2] == 1);
    // A note moved, stretched or transposed while overlapping its old place is the same note; a deleted one has none.
    auto c = pat("0 C4 4\n2 E4 4\n6 G4 2\n");
    auto d = pat("0 C4 4\n3 F4 6\n");
    CHECK(c && d);
    if (!c || !d) return;
    m = matchPatternNotes(*c, *d);
    CHECK(m.size() == 3 && m[0] == 0 && m[1] == 1 && m[2] == -1);
    // Two notes at one pitch: each keeps the one nearest its old start.
    auto e = pat("0 C4 4\n2 C4 4\n");
    auto f = pat("1/2 C4 4\n5/2 C4 4\n");
    CHECK(e && f);
    if (!e || !f) return;
    m = matchPatternNotes(*e, *f);
    CHECK(m.size() == 2 && m[0] == 0 && m[1] == 1);
}

TEST(notes_carry_their_own_bend_vibrato_press_and_timbre) {
    // Parsing: points, bends after ~, ranges and errors.
    PatternResult r = parsePattern(kHead + "0 C3 4 1 bend 0:0~0.5 0.5:12 1:-2 vib 0.3 5.5 0.25 press 0:1 1:0.2 timbre 0:0 1:1\n4 D3 4\n");
    CHECK(r.pattern != nullptr);
    if (r.pattern) {
        CHECK_EQ(r.pattern->expressions.size(), size_t{1});
        CHECK_EQ(r.pattern->notes[0].extra, 0);
        CHECK_EQ(r.pattern->notes[1].extra, -1);
        const NoteExpression& ex = r.pattern->expressions[0];
        CHECK_EQ(ex.bend.points.size(), size_t{3});
        CHECK_NEAR(ex.bend.at(0.0), 0.0, 1e-9);
        CHECK_NEAR(ex.bend.at(0.5), 12.0, 1e-6);
        CHECK(ex.bend.at(0.25) < 6.0);  // bend 0.5 eases in
        CHECK_NEAR(ex.bend.at(1.0), -2.0, 1e-6);
        CHECK_NEAR(ex.vibDepth, 0.3, 1e-9);
        CHECK_NEAR(ex.press.at(1.0), 0.2, 1e-6);
    }
    CHECK(patternError("0 C3 1 bend\n").find("needs points") != std::string::npos);
    CHECK(patternError("0 C3 1 bend 0.5:1 0.2:0\n").find("rising") != std::string::npos);
    CHECK(patternError("0 C3 1 press 0:2\n").find("press values must be 0 to 1") != std::string::npos);
    CHECK(patternError("0 C3 1 bend 0:60\n").find("bend values must be -48 to 48") != std::string::npos);
    CHECK(patternError("0 C3 1 vib 0.3\n").find("vib needs depth and rate") != std::string::npos);
}

TEST(pattern_parser_accepts_more_than_4096_notes) {
    std::string source = "---\nkind: pattern\n---\n";
    for (int i = 0; i < 4097; ++i)
        source += std::to_string(i % 16) + " C4 1\n";
    const PatternResult parsed = parsePattern(source);
    CHECK(parsed.pattern != nullptr);
    if (!parsed.pattern) return;
    CHECK_EQ(parsed.pattern->notes.size(), size_t{4097});
    CHECK_EQ(parsed.pattern->events.size(), size_t{8194});
}

TEST(pattern_lengths_can_exceed_4096_steps) {
    const PatternResult parsed = parsePattern(
        "---\nkind: pattern\nlength: 5000\n---\n4500 C4 1\n");
    CHECK(parsed.pattern != nullptr);
    if (!parsed.pattern) return;
    CHECK_EQ(parsed.pattern->steps(4), 5000);
    CHECK_EQ(parsed.pattern->notes.size(), size_t{1});
    CHECK_NEAR(parsed.pattern->notes[0].at, 4500.0, 1e-9);
}

TEST(pattern_curves_can_exceed_16_points) {
    std::string source = "---\nkind: pattern\n---\n0 C4 1 bend";
    for (int i = 0; i < 20; ++i) {
        const double t = static_cast<double>(i) / 19.0;
        const double value = static_cast<double>(i) / 19.0;
        source += " " + std::to_string(t) + ":" + std::to_string(value);
    }
    source += "\n";
    const PatternResult parsed = parsePattern(source);
    CHECK(parsed.pattern != nullptr);
    if (!parsed.pattern) return;
    CHECK_EQ(parsed.pattern->expressions.size(), size_t{1});
    CHECK_EQ(parsed.pattern->expressions[0].bend.points.size(), size_t{20});
    CHECK_NEAR(parsed.pattern->expressions[0].bend.at(1.0), 1.0, 1e-6);
}
