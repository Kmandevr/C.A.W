// Bittern (1.1.3): each stop at its footage's pitch, the chiff, the cathedral's tail on by default, the swell box, block sizes, presets and a reference render.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "bittern_organ.h"
#include "builtin_bittern.h"
#include "presets.h"
#include "test.h"
#include "instrument_harness.h"
#include "tolerance.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr const char* kId = "org.caw.bittern";
std::unique_ptr<ModuleProcessor> makeB(const Values& v, double sr = 48000) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kId, v);
    if (p && !p->activate(sr, 512)) p.reset();
    return p;
}
// Every stop off but `stop` at 1, dry, no wind, no chiff.
Values only(const char* stop, Values extra = {}) {
    static const char* kIds[] = {"bourdon16", "principal8", "rohrflute8", "gamba8", "celeste8", "octave4", "flute4",
                                 "nazard", "fifteenth2", "tierce", "mixture", "trumpet8", "subbass32"};
    Values v = {{"space", 0.0}, {"wind", 0.0}, {"chiff", 0.0}};
    for (const char* id : kIds) v.emplace_back(id, std::string(id) == stop ? 1.0 : 0.0);
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

// The chiff: the flue pipes' attack carries a noise burst (more in the first 40 ms with Chiff than without).
TEST(bittern_flue_pipes_chiff) {
    const Values a = only("rohrflute8", {{"chiff", 1.0}}), b = only("rohrflute8", {{"chiff", 0.0}});
    auto p = makeB(a), q = makeB(b);
    const std::vector<float> x = play(*p, a, {{0.0, -1, 60, 0.8}}, 0.3).mono(), y = play(*q, b, {{0.0, -1, 60, 0.8}}, 0.3).mono();
    std::vector<float> d(x.size());
    for (size_t i = 0; i < x.size(); ++i) d[i] = x[i] - y[i];
    const double early = rmsOf(d, 0, 1920), late = rmsOf(d, 9600, 1920);
    if (verbose()) std::printf("chiff: first 40 ms %.1f dB, at 200 ms %.1f dB\n", 20 * std::log10(early + 1e-12), 20 * std::log10(late + 1e-12));
    CHECK(early > 1e-4);
    CHECK(late < early * 0.05);
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

TEST(bittern_gives_the_same_bits_at_any_block_size) {
    const Values v = {{"tremulant", 0.5}, {"mixture", 0.7}, {"trumpet8", 0.6}};
    const std::vector<Note> n = {{0.0, 0.4, 36, 0.8}, {0.05, 0.5, 60, 0.5}, {0.2, 0.6, 72, 0.9}};
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
