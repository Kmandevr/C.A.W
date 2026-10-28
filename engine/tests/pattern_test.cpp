// Pattern tests: the note format and its errors, and generators played from patterns through voices.
#include <cmath>
#include <string>
#include <vector>

#include "compile.h"
#include "detmath.h"
#include "engine.h"
#include "pattern.h"
#include "render.h"
#include "test.h"

using namespace caw;

namespace {

const std::string kHead = "---\nkind: pattern\n---\n";
const std::string kFloat = "---\nmode: float\n---\n";
const double kPanGain = std::cos(kPi / 4.0);  // centre pan, as the mixer applies it

bool has(const std::string& s, const char* part) { return s.find(part) != std::string::npos; }

std::string patternError(const std::string& body) { return parsePattern(kHead + body).error; }

// Plays `gen` from `notes` for `frames` samples at 120 BPM (6000 samples per step at 48 kHz); returns the left channel
// divided by the centre-pan gain, so it equals the generator's output.
std::vector<double> play(const std::string& gen, const std::string& notes, int64_t frames, int loopBars = 4) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = loopBars;
    p.seed = 3;
    p.master = 1.0;
    p.modules.push_back({"g", kFloat + gen, {}});
    p.modules.push_back({"p", notes.rfind("---", 0) == 0 ? notes : kHead + notes, {}});
    LayerSpec l;
    l.id = "l";
    l.chain = {"g"};
    l.pattern = "p";
    l.volume = 1.0;
    p.layers = {l};
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string res = e.setProject(p);
    if (!has(res, "\"ok\":true")) cawtest::fail(__FILE__, __LINE__, "project failed: " + res);
    e.play();
    std::vector<float> lf(static_cast<size_t>(frames)), rf(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += 64)
        e.process(lf.data() + i, rf.data() + i, static_cast<int>(std::min<int64_t>(64, frames - i)));
    std::vector<double> out(lf.size());
    for (size_t i = 0; i < lf.size(); ++i) out[i] = lf[i] / kPanGain;
    return out;
}

}  // namespace

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
    CHECK(has(compileModule(kHead + "0 C3 1\n").error, "a pattern holds notes, not code"));
}

TEST(notes_start_and_end_on_their_samples) {
    // gate * vel shows exactly when each note sounds: 6000 samples per step, so step 4.5 is sample 27000.
    std::vector<double> y = play("gate * vel", "0 C4 1 0.5\n4.5 C4 1/2 1\n", 40000);
    CHECK_NEAR(y[0], 0.5, 1e-6);
    CHECK_NEAR(y[5999], 0.5, 1e-6);
    CHECK_NEAR(y[6000], 0.0, 1e-6);
    CHECK_NEAR(y[26999], 0.0, 1e-6);
    CHECK_NEAR(y[27000], 1.0, 1e-6);
    CHECK_NEAR(y[29999], 1.0, 1e-6);
    CHECK_NEAR(y[30000], 0.0, 1e-6);
}

TEST(chords_use_one_voice_per_note_and_the_oldest_is_stolen) {
    std::vector<double> y = play("gate * 0.1", "0 C3,E3,G3 4\n", 1000);
    CHECK_NEAR(y[500], 0.3, 1e-6);
    // Nine notes at once: eight voices, so one note doesn't sound.
    std::vector<double> z = play("gate * 0.1", "0 C3,D3,E3,F3,G3,A3,B3,C4,D4 4\n", 1000);
    CHECK_NEAR(z[500], 0.8, 1e-6);
}

TEST(voices_hear_their_note) {
    // Output is clamped to -1..1, so values are scaled down to read them.
    std::vector<double> y = play("gate * (note + vel) * 0.01", "0 A4 2 0.25\n2 C5 2\n", 20000);
    CHECK_NEAR(y[100], 0.6925, 1e-6);
    CHECK_NEAR(y[12100], 0.73, 1e-6);
    std::vector<double> f = play("freq * 0.001", "0 A4 1\n", 100);
    CHECK_NEAR(f[50], 0.44, 1e-7);
    // trig is 1 on a note's first sample only; ratchets start the note again.
    std::vector<double> t = play("trig", "0 A4 4 1 ratchet 2\n", 30000);
    int trigs = 0;
    for (double v : t) trigs += v > 0.5;
    CHECK(trigs == 2 && t[0] > 0.5 && t[12000] > 0.5);
    // rel counts samples since release.
    std::vector<double> r = play("rel * 0.001", "0 A4 1\n", 6100);
    CHECK_NEAR(r[6000 + 50], 0.05, 1e-7);
}

TEST(slides_glide_without_a_new_attack) {
    // A4 slides into C5: no second trig, and the pitch moves over half a step (3000 samples).
    std::vector<double> t = play("trig", "0 A4 2 1 slide\n2 C5 2\n", 24000);
    int trigs = 0;
    for (double v : t) trigs += v > 0.5;
    CHECK(trigs == 1);
    std::vector<double> n = play("note * 0.01", "0 A4 2 1 slide\n2 C5 2\n", 24000);
    CHECK_NEAR(n[11999], 0.69, 1e-7);
    CHECK_NEAR(n[12000 + 1499], (69.0 + 3.0 * 1500.0 / 3000.0) * 0.01, 1e-6);
    CHECK_NEAR(n[12000 + 3000], 0.72, 1e-7);
}

TEST(probability_is_repeatable_and_varies_per_repeat) {
    // A one-step pattern repeats 64 times in a 4-bar loop; a 50% note plays on some repeats only.
    std::vector<double> a = play("gate", "---\nkind: pattern\nlength: 1\n---\n0 C4 1/2 1 prob 0.5\n", 64 * 6000);
    std::vector<double> b = play("gate", "---\nkind: pattern\nlength: 1\n---\n0 C4 1/2 1 prob 0.5\n", 64 * 6000);
    int played = 0;
    for (int k = 0; k < 64; ++k) played += a[static_cast<size_t>(k) * 6000 + 10] > 0.5;
    CHECK(played > 16 && played < 48);
    CHECK(a == b);
}

TEST(a_pattern_sets_the_layer_length) {
    // An 8-step pattern repeats every 8 steps even though the project loop is 4 bars.
    std::vector<double> y = play("trig", "---\nkind: pattern\nlength: 8\n---\n0 C4 1\n", 100000);
    CHECK(y[0] > 0.5 && y[48000] > 0.5 && y[96000] > 0.5);
}

TEST(byte_mode_pitch_follows_the_note) {
    // At C5, t runs twice as fast as at C4: C4's sample 2i equals C5's sample i.
    const std::string gen = "---\nmode: byte\nrate: 8000\n---\nt";
    std::vector<double> c4 = play(gen, "0 C4 4\n", 6000);
    std::vector<double> c5 = play(gen, "0 C5 4\n", 6000);
    for (int i = 0; i < 2900; i += 97) CHECK_NEAR(c4[static_cast<size_t>(2 * i)], c5[static_cast<size_t>(i)], 1e-6);
}

TEST(without_a_pattern_one_note_holds_through_the_loop) {
    ProjectSpec p = singleModuleProject(kFloat + "(trig + gate + note * 0.001 + vel + rel) * 0.1", 120, 1);
    p.layers[0].volume = 1.0;
    p.master = 1.0;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    float l[64], r[64];
    e.process(l, r, 64);
    CHECK_NEAR(l[0] / kPanGain, 0.306, 1e-6);
    CHECK_NEAR(l[1] / kPanGain, 0.206, 1e-6);
    // Names written before patterns existed still work: a let can hide a note variable.
    CHECK(compileModule("let note = 5\nlet gate = 1\nnote * gate").program != nullptr);
}

TEST(exports_check_a_layers_pattern) {
    ProjectSpec p = singleModuleProject(kFloat + "sine(freq) * gate * 0.3", 120, 1);
    p.modules.push_back({"p", kHead + "0 A4 1\n", {}});
    p.layers[0].pattern = "p";
    RenderResult out;
    CHECK(renderExport(p, ExportOptions{}, out));
    p.modules[1].source = kHead + "0 Z4 1\n";
    CHECK(!renderExport(p, ExportOptions{}, out) && has(out.error, "pattern 'p'"));
    p.layers[0].pattern = "nope";
    CHECK(!renderExport(p, ExportOptions{}, out) && has(out.error, "no pattern 'nope'"));
}
