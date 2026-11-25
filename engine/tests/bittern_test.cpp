// Bittern (1.1.3): each stop at its footage, the measured spectra and speech, the recorded speech only at a pipe's start, the shared wind, registrations, no glitches, the cathedral by default, the swell box, block sizes, presets and a reference render.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "bittern_organ.h"
#include "builtin_bittern.h"
#include "presets.h"
#include "recorded_bank.h"
#include "test.h"
#include "timber_harness.h"
#include "tolerance.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr const char* kId = "org.caw.bittern";
const char* const kIds[] = {"bourdon16", "principal8", "octave4", "fifteenth2", "mixture", "trumpet8", "rohrflute8",
                            "gamba8", "celeste8", "flute4", "nazard", "tierce", "subbass32"};
std::unique_ptr<ModuleProcessor> makeB(const Values& v, double sr = 48000) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kId, v);
    if (p && !p->activate(sr, 512)) p.reset();
    return p;
}
bittern::Organ& organOf(ModuleProcessor& p) { return static_cast<timber::Instrument<bittern::Organ>&>(p).model(); }
// Every stop off but `stop` at 1, dry, no wind, no chiff.
Values only(const char* stop, Values extra = {}) {
    Values v = {{"space", 0.0}, {"wind", 0.0}, {"chiff", 0.0}};
    for (const char* id : kIds) v.emplace_back(id, std::string(id) == stop ? 1.0 : 0.0);
    for (auto& x : extra) v.push_back(x);
    return v;
}
Values with(Values v, const Values& extra) {
    for (auto& x : extra) v.push_back(x);
    return v;
}
double powerAt(const std::vector<float>& x, double hz, size_t from, size_t n) {
    double re = 0, im = 0;
    for (size_t i = 0; i < n; ++i) {
        const double w = 0.5 - 0.5 * std::cos(2 * timber_test::kPi * i / (n - 1));
        re += x[from + i] * w * std::cos(2 * timber_test::kPi * hz * i / 48000.0);
        im += x[from + i] * w * std::sin(2 * timber_test::kPi * hz * i / 48000.0);
    }
    return re * re + im * im;
}
double rmsOf(const std::vector<float>& x, size_t from, size_t n) {
    double s = 0;
    for (size_t i = from; i < from + n && i < x.size(); ++i) s += static_cast<double>(x[i]) * x[i];
    return std::sqrt(s / n);
}
// The time (s) a held note's 5 ms RMS first reaches half its level at 0.8..1.0 s.
double halfTime(const std::vector<float>& x) {
    const double steady = rmsOf(x, 38400, 9600);
    for (size_t i = 0; i + 240 < x.size(); i += 48)
        if (rmsOf(x, i, 240) >= 0.5 * steady) return i / 48000.0;
    return 1e9;
}

// The glitch scan: the worst sample step (the second difference, so a smooth tone's own slope does not count, and a
// jump of level or phase stands out) against its local level (the larger of its RMS over the 10 ms before and the
// 10 ms after), and the worst 2 ms window's RMS against the larger of the 40 ms before and after it.
struct Scan {
    double step = 0, window = 0;
    double stepAt = 0, windowAt = 0;
};
Scan scan(const std::vector<float>& x) {
    const long n = static_cast<long>(x.size());
    std::vector<double> c(x.size() + 1, 0.0), d(x.size(), 0.0), cd(x.size() + 1, 0.0);
    for (long i = 0; i < n; ++i) c[i + 1] = c[i] + static_cast<double>(x[i]) * x[i];
    for (long i = 2; i < n; ++i) d[i] = static_cast<double>(x[i]) - 2.0 * x[i - 1] + x[i - 2];
    for (long i = 0; i < n; ++i) cd[i + 1] = cd[i] + d[i] * d[i];
    auto rmsOver = [&](const std::vector<double>& q, long a, long b) {
        a = std::max(0L, a), b = std::min(n, b);
        return b > a ? std::sqrt((q[b] - q[a]) / (b - a)) : 0.0;
    };
    auto rms = [&](long a, long b) { return rmsOver(c, a, b); };
    Scan s;
    for (long i = 2; i < n; ++i) {
        const double local = std::max(rmsOver(cd, i - 480, i), rmsOver(cd, i + 1, i + 481));
        const double r = std::fabs(d[i]) / (local + 1e-6);
        if (r > s.step) s.step = r, s.stepAt = i / 48000.0;
    }
    for (long i = 0; i + 96 < n; i += 48) {
        const double local = std::max(rms(i - 1920, i), rms(i + 96, i + 96 + 1920));
        const double r = rms(i, i + 96) / (local + 1e-4);
        if (r > s.window) s.window = r, s.windowAt = i / 48000.0;
    }
    return s;
}
// Plays `segments` one after the other on one instance (each with its own knobs; notes held across them), joined.
struct Segment {
    Values knobs;
    std::vector<Note> notes;
    double seconds;
    std::vector<Cc> ccs = {};
};
std::vector<float> playSegments(const std::vector<Segment>& segs) {
    auto p = makeB(segs[0].knobs);
    std::vector<float> out;
    for (const Segment& s : segs) {
        const std::vector<float> m = play(*p, s.knobs, s.notes, s.seconds, 48000, 64, s.ccs).mono();
        out.insert(out.end(), m.begin(), m.end());
    }
    return out;
}

}  // namespace

// Each stop sounds at its footage: the strongest of the candidate pitches (16', 8', 4', 2 2/3', 2', 1 3/5', 32') is
// its own (the stopped ranks' fundamental, the others' too); C3 (key 48).
TEST(bittern_each_stop_sounds_at_its_footage) {
    struct S {
        const char* id;
        double mult;
    } stops[] = {{"bourdon16", 0.5}, {"principal8", 1}, {"rohrflute8", 1}, {"gamba8", 1}, {"octave4", 2}, {"flute4", 2},
                 {"nazard", 3}, {"fifteenth2", 4}, {"tierce", 5}, {"trumpet8", 1}, {"subbass32", 0.25}};
    const double f8 = 440.0 * std::pow(2.0, (48 - 69) / 12.0);
    for (const S& s : stops) {
        const Values v = only(s.id);
        auto p = makeB(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, 48, 0.7}}, 0.8).mono();
        const double own = powerAt(m, f8 * s.mult, 19200, 9600);
        double other = 0;
        for (double k : {0.25, 0.5, 1.0, 2.0, 3.0, 4.0, 5.0})
            if (k != s.mult && k < s.mult) other = std::max(other, powerAt(m, f8 * k, 19200, 9600));
        if (verbose()) std::printf("%s: own %.1f dB, any lower %.1f dB\n", s.id, 10 * std::log10(own + 1e-30), 10 * std::log10(other + 1e-30));
        CHECK(own > 10.0 * other);  // nothing below the rank's own pitch
        CHECK(own > 1e-3);
    }
}

// The measured spectra (VCSL's organ): the stopped flute's odd harmonics (its 3rd at least 10 dB over its 2nd and
// 4th: measured 15-50 dB), the principal's full train (its 2nd and 3rd within 20 dB of its fundamental), C3.
TEST(bittern_spectra_follow_the_recordings) {
    const double f = 440.0 * std::pow(2.0, (48 - 69) / 12.0);
    auto partials = [&](const char* stop, double* db) {
        const Values v = only(stop);
        auto p = makeB(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, 48, 0.7}}, 1.0).mono();
        for (int h = 1; h <= 4; ++h) db[h] = 10 * std::log10(powerAt(m, f * h, 24000, 19200) + 1e-30);
    };
    double st[5], pr[5];
    partials("rohrflute8", st);
    partials("principal8", pr);
    if (verbose()) std::printf("stopped 1..4: %.1f %.1f %.1f %.1f; principal %.1f %.1f %.1f %.1f dB\n", st[1], st[2], st[3], st[4], pr[1], pr[2], pr[3], pr[4]);
    CHECK(st[3] > st[2] + 10 && st[3] > st[4] + 10);
    CHECK(pr[2] > pr[1] - 20 && pr[3] > pr[1] - 20);
}

// The measured speech: a pipe rises to half its level in the time measured for its pitch (an 8' C3 about 130 ms, a 2'
// C5 about 78 ms), so the small pipes of a chorus speak first.
TEST(bittern_small_pipes_speak_first) {
    const Values a = only("principal8"), b = only("fifteenth2");
    auto p = makeB(a), q = makeB(b);
    const double t8 = halfTime(play(*p, a, {{0.0, -1, 48, 0.7}}, 1.0).mono());
    const double t2 = halfTime(play(*q, b, {{0.0, -1, 48, 0.7}}, 1.0).mono());
    if (verbose()) std::printf("half level: 8' %.0f ms, 2' %.0f ms\n", 1e3 * t8, 1e3 * t2);
    CHECK(t8 > 0.07 && t8 < 0.25);
    CHECK(t2 > 0.03 && t2 < t8 * 0.8);
}

// The recorded speech: with Chiff the attack carries the recording's own speech (more in the first 100 ms than
// without), and from 0.5 s on nothing of it is left (the two renders identical: no noise off the note's start).
TEST(bittern_speech_is_recorded_and_only_at_the_start) {
    const Values a = only("rohrflute8", {{"chiff", 1.0}, {"wind", 0.3}});
    auto p = makeB(a), q = makeB(a);
    organOf(*q).testMuteSpeech = true;
    const std::vector<float> x = play(*p, a, {{0.0, -1, 60, 0.8}}, 1.0).mono(), y = play(*q, a, {{0.0, -1, 60, 0.8}}, 1.0).mono();
    std::vector<float> d(x.size());
    for (size_t i = 0; i < x.size(); ++i) d[i] = x[i] - y[i];
    const double early = rmsOf(d, 0, 4800), late = rmsOf(d, 24000, 24000);
    if (verbose()) std::printf("speech: first 100 ms %.1f dB, after 0.5 s %.1f dB\n", 20 * std::log10(early + 1e-12), 20 * std::log10(late + 1e-30));
    CHECK(early > 1e-4);
    CHECK(late == 0.0);
}

// The chiff knob: the flue pipes' attack carries more speech with Chiff 1 than 0, and little of it by 300 ms.
TEST(bittern_flue_pipes_chiff) {
    const Values a = only("rohrflute8", {{"chiff", 1.0}}), b = only("rohrflute8", {{"chiff", 0.0}});
    auto p = makeB(a), q = makeB(b);
    const std::vector<float> x = play(*p, a, {{0.0, -1, 60, 0.8}}, 0.5).mono(), y = play(*q, b, {{0.0, -1, 60, 0.8}}, 0.5).mono();
    std::vector<float> d(x.size());
    for (size_t i = 0; i < x.size(); ++i) d[i] = x[i] - y[i];
    const double early = rmsOf(d, 0, 4800), late = rmsOf(d, 14400, 4800);
    if (verbose()) std::printf("chiff: first 100 ms %.1f dB, at 300 ms %.1f dB\n", 20 * std::log10(early + 1e-12), 20 * std::log10(late + 1e-12));
    CHECK(early > 1e-4);
    CHECK(late < early * 0.25);
}

// The shared wind: a big chord of the full organ sags the reservoir (and so flattens every pipe a little), one soft
// note barely; and nothing sounding, it settles back.
TEST(bittern_wind_sags_under_a_big_chord) {
    const Values full = {{"registration", 3.0}, {"space", 0.0}}, soft = only("rohrflute8", {{"rohrflute8", 0.4}});
    auto p = makeB(full), q = makeB(soft);
    auto r = makeB(full);
    std::vector<Note> chord;
    for (int k = 0; k < 10; ++k) chord.push_back({0.0, 0.5, 36.0 + 4 * k, 0.8});
    play(*p, full, chord, 0.45);
    const double big = organOf(*p).sag;
    play(*q, soft, {{0.0, 0.8, 60, 0.8}}, 0.6);
    const double small = organOf(*q).sag;
    play(*r, full, chord, 2.5);
    const double after = organOf(*r).sag;
    if (verbose()) std::printf("sag: full chord %.2f, one soft note %.3f, after %.3f\n", big, small, after);
    CHECK(big > 0.4);
    CHECK(small < 0.05);
    CHECK(after < 0.05);
}

// A registration is one tap: the choice plays exactly what the same stops drawn by hand play, and each differs.
TEST(bittern_registrations_are_the_stops_they_name) {
    const std::vector<Note> n = {{0.0, 0.5, 48, 0.7}, {0.0, 0.5, 55, 0.7}, {0.0, 0.5, 64, 0.7}};
    std::vector<std::vector<float>> each;
    for (int r = 1; r < bittern::kRegistrations; ++r) {
        Values byHand = {{"space", 0.0}};
        for (int k = 0; k < bittern::kStops; ++k) byHand.emplace_back(kIds[k], bittern::kRegistration[r][k]);
        const Values byChoice = {{"space", 0.0}, {"registration", static_cast<double>(r)}};
        auto p = makeB(byHand), q = makeB(byChoice);
        const std::vector<float> a = play(*p, byHand, n, 0.8).mono(), b = play(*q, byChoice, n, 0.8).mono();
        CHECK(a == b);
        each.push_back(b);
    }
    for (size_t i = 0; i < each.size(); ++i)
        for (size_t j = i + 1; j < each.size(); ++j) CHECK(each[i] != each[j]);
}

// The stops are grouped by division (the Great, the Swell, the Pedal) and every 1.1.3-alpha.1 knob is still there
// (a project from before plays as drawn: the registration choice defaults to the knobs).
TEST(bittern_stops_are_grouped_by_division_and_old_knobs_load) {
    auto p = makeB({});
    CHECK(p != nullptr);
    if (!p) return;
    const ModuleDescriptor& d = p->descriptor();
    auto groupOf = [&](const char* id) -> std::string {
        for (uint32_t k = 0; k < d.parameterCount; ++k)
            if (d.parameters[k].id == id) return std::string(d.parameters[k].group);
        return "";
    };
    for (const char* id : {"bourdon16", "principal8", "octave4", "fifteenth2", "mixture", "trumpet8"}) CHECK(groupOf(id) == "great");
    for (const char* id : {"rohrflute8", "gamba8", "celeste8", "flute4", "nazard", "tierce"}) CHECK(groupOf(id) == "swell");
    CHECK(groupOf("subbass32") == "pedal");
    for (const char* id : {"tremulant", "wind", "chiff", "trem_rate", "tone", "body", "space", "velocity", "release", "voices", "level"})
        CHECK(!groupOf(id).empty());
    CHECK(groupOf("registration") == "registration");
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == "registration") CHECK(d.parameters[k].defaultValue == 0.0);
    // An old project's values (every alpha.1 id) play.
    const Values old = {{"bourdon16", 0.6}, {"principal8", 1.0}, {"rohrflute8", 0.5}, {"octave4", 0.7}, {"tremulant", 0.2}, {"wind", 0.4}, {"chiff", 0.6}, {"trem_rate", 5.0}};
    auto q = makeB(old);
    const std::vector<float> m = play(*q, old, {{0.0, 0.4, 60, 0.7}}, 0.6).mono();
    CHECK(rmsOf(m, 9600, 9600) > 1e-3);
}

// Silence is silent: nothing before the first note (with the room on), and the dry organ's output exactly zero once
// its notes and their release are over.
TEST(bittern_is_silent_without_notes) {
    auto p = makeB({});
    const std::vector<float> a = play(*p, {}, {}, 1.0).mono();
    CHECK(std::all_of(a.begin(), a.end(), [](float x) { return x == 0.0f; }));
    const Values dry = {{"space", 0.0}};
    auto q = makeB(dry);
    const std::vector<float> b = play(*q, dry, {{0.2, 0.25, 60, 0.7}, {0.2, 0.25, 36, 0.7}}, 2.0).mono();
    CHECK(std::all_of(b.begin(), b.begin() + 9600, [](float x) { return x == 0.0f; }));
    CHECK(std::all_of(b.begin() + 72000, b.end(), [](float x) { return std::fabs(x) < 1e-7f; }));
}

// The glitch scan (owner, 2026-11-25: "noise at the wrong point mostly, or glitches in the audio ... unintended
// sounds"): no sample step more than 8 times its local level and no 2 ms window more than 4 times the 40 ms around
// it, dry, over keys across the range, chords, fast repeats of one key, stops drawn and retired while keys are held,
// the swell moved, the voice cap's stealing and every registration.
TEST(bittern_has_no_glitches) {
    constexpr double kStepLimit = 8.0, kWindowLimit = 4.0;
    const Values dry = {{"space", 0.0}};
    std::vector<std::pair<std::string, std::vector<float>>> cases;
    {
        std::vector<Note> keys;
        for (int k = 0; k < 14; ++k) keys.push_back({0.35 * k, 0.35 * k + 0.25, 24.0 + 6 * k, 0.7});
        cases.push_back({"keys", playSegments({{dry, keys, 5.2}})});
    }
    {
        std::vector<Note> chords;
        for (int r = 0; r < 4; ++r)
            for (int k : {36, 48, 55, 60, 64, 67, 72}) chords.push_back({0.5 * r, 0.5 * r + 0.4, static_cast<double>(k + r), 0.8});
        cases.push_back({"chords, full organ", playSegments({{with(dry, {{"registration", 3.0}}), chords, 2.6}})});
    }
    {
        std::vector<Note> rep;
        for (int k = 0; k < 20; ++k) rep.push_back({0.06 * k, 0.06 * k + 0.09, 60, 0.8});  // overlapping: struck again while held
        for (int k = 0; k < 10; ++k) rep.push_back({1.4 + 0.11 * k, 1.4 + 0.11 * k + 0.05, 43, 0.8});  // struck again while releasing
        cases.push_back({"fast repeats", playSegments({{with(dry, {{"registration", 2.0}}), rep, 2.8}})});
    }
    {
        const Values a = with(dry, {{"principal8", 1.0}, {"octave4", 0.0}, {"trumpet8", 0.0}, {"gamba8", 0.0}});
        const Values b = with(dry, {{"principal8", 1.0}, {"octave4", 0.8}, {"trumpet8", 0.7}, {"gamba8", 0.6}});
        const Values c = with(dry, {{"principal8", 0.0}, {"octave4", 0.8}, {"trumpet8", 0.0}, {"gamba8", 0.6}, {"bourdon16", 0.0}, {"rohrflute8", 0.0}});
        const std::vector<Note> held = {{0.0, -1, 48, 0.7}, {0.0, -1, 55, 0.7}, {0.0, -1, 64, 0.7}};
        cases.push_back({"stops while held", playSegments({{a, held, 0.5}, {b, {}, 0.5}, {c, {}, 0.5}, {a, {}, 0.5}, {with(a, {{"registration", 3.0}}), {}, 0.5}, {a, {}, 0.5}})});
    }
    {
        const std::vector<Cc> swell = {{0.3, 1, 1.0}, {0.6, 1, 0.0}, {0.8, 1, 0.7}, {1.0, 1, 0.1}};
        cases.push_back({"swell", playSegments({{dry, {{0.0, 1.2, 48, 0.7}, {0.0, 1.2, 60, 0.7}}, 1.5, swell}})});
    }
    {
        std::vector<Note> many;
        for (int r = 0; r < 6; ++r)
            for (int k = 0; k < 8; ++k) many.push_back({0.2 * r, 0.2 * r + 0.6, 40.0 + 5 * k + r, 0.8});
        cases.push_back({"voice cap", playSegments({{with(dry, {{"voices", 4.0}, {"registration", 3.0}}), many, 2.2}})});
    }
    for (int r = 1; r < bittern::kRegistrations; ++r)
        cases.push_back({"registration " + std::to_string(r),
                         playSegments({{with(dry, {{"registration", static_cast<double>(r)}}), {{0.0, 0.5, 36, 0.7}, {0.1, 0.6, 60, 0.7}, {0.2, 0.7, 84, 0.7}}, 1.2}})});
    for (const auto& [name, x] : cases) {
        const Scan s = scan(x);
        if (verbose()) std::printf("glitch scan %-22s step %.2f (at %.3f s), 2 ms window %.2f (at %.3f s)\n", name.c_str(), s.step, s.stepAt, s.window, s.windowAt);
        CHECK(s.step < kStepLimit);
        CHECK(s.window < kWindowLimit);
        if (std::getenv("BITTERN_DUMP") && s.step >= kStepLimit) {
            const long at = static_cast<long>(s.stepAt * 48000);
            for (long i = at - 12; i < at + 8; ++i) std::printf("  %ld %.6f\n", i, x[i]);
        }
    }
    // The scan sees what it is for: the same held chord with its phase jumped a quarter cycle (a voice restarted), cut
    // off dead (a gate), or with one sample 30 dB under its level added (a click).
    const std::vector<float> chord = playSegments({{dry, {{0.0, 0.6, 48, 0.7}, {0.0, 0.6, 60, 0.7}}, 0.8}});
    std::vector<float> jump = chord, gate = chord, click = chord;
    const double held = rmsOf(chord, 19200, 4800);
    for (size_t i = 19200; i < jump.size(); ++i) jump[i] = chord[std::min(chord.size() - 1, i + 46)];  // C3's quarter cycle
    std::fill(gate.begin() + 19200, gate.end(), 0.0f);
    click[19200] += static_cast<float>(held * 0.0316 * 40.0);
    for (const auto* g : {&jump, &gate, &click}) {
        const Scan s = scan(*g);
        if (verbose()) std::printf("glitch scan calibration: step %.2f, window %.2f\n", s.step, s.window);
        CHECK(s.step >= kStepLimit || s.window >= kWindowLimit);
    }
}

// The room is on by default: a held chord's release rings for seconds (the cathedral), and Space 0 stops at once.
TEST(bittern_rings_in_its_cathedral_by_default) {
    const Values wet = {}, dry = {{"space", 0.0}};
    auto p = makeB(wet), q = makeB(dry);
    const std::vector<Note> chord = {{0.0, 0.6, 48, 0.8}, {0.0, 0.6, 55, 0.8}, {0.0, 0.6, 60, 0.8}};
    const std::vector<float> a = play(*p, wet, chord, 3.0).mono(), b = play(*q, dry, chord, 3.0).mono();
    const double held = rmsOf(a, 14400, 9600), tail = rmsOf(a, 96000, 9600), dryTail = rmsOf(b, 96000, 9600);
    if (verbose()) std::printf("tail 1.4 s after release: %.1f dB under the chord (dry: %.1f)\n", 20 * std::log10(held / (tail + 1e-12)), 20 * std::log10(held / (dryTail + 1e-12)));
    CHECK(tail > held * 0.01);       // within 40 dB 1.4 s later: a long room
    CHECK(dryTail < held * 0.0001);  // dry: gone
}

// The swell box: the mod wheel closed makes it darker and quieter.
TEST(bittern_swell_box_darkens_and_softens) {
    const Values v = only("principal8");
    auto p = makeB(v), q = makeB(v);
    const std::vector<float> open = play(*p, v, {{0.0, -1, 60, 0.8}}, 0.6).mono();
    const std::vector<float> shut = play(*q, v, {{0.0, -1, 60, 0.8}}, 0.6, 48000, 64, {{0.0, 1, 1.0}}).mono();
    const double f = 440.0 * std::pow(2.0, (60 - 69) / 12.0);
    const double brightOpen = powerAt(open, 8 * f, 14400, 9600) / powerAt(open, f, 14400, 9600);
    const double brightShut = powerAt(shut, 8 * f, 14400, 9600) / powerAt(shut, f, 14400, 9600);
    CHECK(brightShut < brightOpen * 0.3);
    CHECK(rmsOf(shut, 14400, 9600) < rmsOf(open, 14400, 9600));
}

// The recorded speech is decoded with the first Bittern and freed with the last.
TEST(bittern_speech_loads_on_use_and_frees) {
    const size_t before = recorded::residentBytes();
    {
        auto a = makeB({});
        CHECK(a != nullptr);
        const size_t one = recorded::residentBytes();
        CHECK(one >= before + 1000000 * sizeof(float));
        auto b = makeB({});
        CHECK(recorded::residentBytes() == one);
    }
    CHECK(recorded::residentBytes() == before);
}

TEST(bittern_gives_the_same_bits_at_any_block_size) {
    const Values v = {{"tremulant", 0.5}, {"mixture", 0.7}, {"trumpet8", 0.6}};
    const std::vector<Note> n = {{0.0, 0.4, 36, 0.8}, {0.05, 0.5, 60, 0.5}, {0.2, 0.6, 72, 0.9}, {0.3, 0.7, 60, 0.7}};
    Stereo ref;
    for (uint32_t block : {64u, 1u, 37u, 512u}) {
        auto p = makeB(v);
        const Stereo s = play(*p, v, n, 0.8, 48000, block, {{0.3, 1, 0.5}});
        if (block == 64) ref = s;
        else CHECK(s.l == ref.l && s.r == ref.r);
    }
}

TEST(bittern_presets_load_and_play) {
    const std::vector<BuiltinPreset>* list = bittern::bitternPresets(kId);
    CHECK(list && list->size() >= 8);
    if (!list) return;
    for (const BuiltinPreset& pr : *list) {
        Values v;
        for (const auto& [k, x] : pr.values) v.emplace_back(std::string(k), x);
        auto p = makeB(v);
        CHECK(p != nullptr);
        if (!p) continue;
        const std::vector<float> m = play(*p, v, {{0.0, 0.5, 48, 0.7}, {0.0, 0.5, 64, 0.7}}, 0.7).mono();
        double peak = 0;
        for (float x : m) peak = std::max(peak, static_cast<double>(std::fabs(x)));
        CHECK(std::isfinite(peak) && peak > 1e-3 && peak < 4.0);
    }
}

TEST(bittern_matches_its_reference_render) {
    cawtest::References refs("bittern");
    const Values v = {{"mixture", 0.5}, {"tremulant", 0.3}};
    auto p = makeB(v);
    const Stereo s = play(*p, v, {{0.0, 0.8, 36, 0.7}, {0.2, 0.9, 60, 0.6}, {0.4, 1.0, 67, 0.8}, {0.5, 1.0, 72, 0.5}}, 1.6);
    CHECK_REFERENCE(refs, "bittern", (cawtest::Audio{s.l, s.r}), cawtest::Class::Chaotic);
}
