// The Convolver as a merged device (variant 0 as it was) and its 1.1.0 Cab variant: cabinets, mic position and distance, response sizes, kept state, block sizes, bad input, presets, display, references.
#include <complex>

#include "fx_modes_harness.h"
#include "tolerance.h"

using namespace modes_test;

namespace {

constexpr const char* kConv = "org.caw.convolver";

// The level (dB) of the `hz` component of v[from, from + n) (Hann-windowed single-bin DFT).
double toneDb(const std::vector<float>& v, double hz, size_t from, size_t n) {
    std::complex<double> acc = 0;
    double wsum = 0;
    for (size_t i = 0; i < n; ++i) {
        const double w = 0.5 - 0.5 * std::cos(2 * kPi * i / n);
        acc += w * static_cast<double>(v[from + i]) * std::polar(1.0, -2 * kPi * hz * i / 48000.0);
        wsum += w;
    }
    return db(2.0 * std::abs(acc) / wsum);
}
// The cab's gain (dB) at hz.
double gainAt(const Values& v, double hz) {
    const Stereo out = render(kConv, with(v, 1), sine(hz, 0.1, 16384));
    return toneDb(out.l, hz, 8000, 8192) - db(0.1);
}

}  // namespace

TEST(the_convolver_is_a_merged_device_its_old_self_first_then_cab) {
    const fx::MergedDevice* m = fx::findMergedDevice(kConv);
    CHECK(m && m->variants.size() == 2u);
    if (!m || m->variants.size() < 2) return;
    CHECK(m->variants[0].name == "Convolver");
    const ModuleDescriptor& old = m->variants[0].descriptor();
    CHECK(registry().find(kConv) == &old);           // the reused id lists variant 0
    CHECK_EQ(old.latencyFrames, 512u);                // the convolver as it was: its latency, state and cost
    CHECK(old.maxStateBytes > 0 && old.cpuClass == CpuClass::Heavy);
    CHECK(old.parameters[old.parameterCount - 1].id == fx::kVariantParam);
    CHECK(old.parameters[0].id == std::string("source"));
    const ModuleDescriptor* cab = checkVariant(kConv, 1, "Cab");
    if (!cab) return;
    CHECK_EQ(cab->latencyFrames, 0u);
    CHECK_EQ(cab->parameterCount, 6u);
    CHECK_EQ(cab->maxStateBytes, old.maxStateBytes);
    // An entry with no variant still plays the convolver (no migration needed).
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kConv, {});
    CHECK(p && &p->descriptor() == &old);
}

TEST(cab_cabinets_sound_different_and_the_mic_moves_as_it_should) {
    // Every cabinet passes the mids, cuts the deep lows and rolls the top off; no two are alike.
    double at3k[6];
    for (int c = 0; c < 6; ++c) {
        const Values v = {{"cab", static_cast<double>(c)}, {"position", 0.3}, {"distance", 1.0}};  // far: no proximity lift
        const double mid = gainAt(v, 1000), top = gainAt(v, 12000), deep = gainAt(v, 15);
        if (!(std::fabs(mid) < 9.0 && top < mid - 15.0 && deep < mid - 6.0))
            cawtest::fail(__FILE__, __LINE__, "cab " + std::to_string(c) + ": " + std::to_string(deep) + " / " + std::to_string(mid) + " / " + std::to_string(top));
        at3k[c] = gainAt(v, 3000) - mid;
        CHECK(registry().find(kConv) != nullptr);
    }
    for (int a = 0; a < 6; ++a)
        for (int b = a + 1; b < 6; ++b) CHECK(std::fabs(at3k[a] - at3k[b]) > 0.3 || std::fabs(gainAt({{"cab", double(a)}}, 200) - gainAt({{"cab", double(b)}}, 200)) > 0.3);
    // Position: the edge is darker than the centre up top, the same in the mids.
    const Values centre = {{"cab", 2}, {"position", 0}, {"distance", 0.2}}, edge = {{"cab", 2}, {"position", 1}, {"distance", 0.2}};
    CHECK(gainAt(edge, 4000) < gainAt(centre, 4000) - 6.0);
    CHECK(std::fabs(gainAt(edge, 500) - gainAt(centre, 500)) < 1.0);
    // Distance: close lifts the lows (proximity), far loses top.
    const Values close = {{"cab", 2}, {"position", 0.3}, {"distance", 0}}, far = {{"cab", 2}, {"position", 0.3}, {"distance", 1}};
    CHECK(gainAt(close, 120) > gainAt(far, 120) + 3.0);
    CHECK(gainAt(far, 4500) < gainAt(close, 4500));
}

TEST(cab_responses_are_short_and_sized_by_the_rate) {
    for (const auto& [rate, taps] : {std::pair{48000.0, 128.0f}, std::pair{44100.0, 120.0f}, std::pair{96000.0, 256.0f}, std::pair{32000.0, 88.0f}}) {
        std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kConv, {{"variant", 1}});
        CHECK(p && p->activate(rate, 512));
        if (!p) return;
        run(*p, music(4800), with({}, 1));
        float shown[128];
        CHECK_EQ(p->readDisplay(shown, 128), 72u);
        CHECK_EQ(shown[5], taps);
        CHECK(shown[6] < 2.8f);  // ms
    }
}

TEST(cab_keeps_a_users_ir_state_for_the_convolver) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), kConv, {{"variant", 1}});
    CHECK(p != nullptr);
    if (!p) return;
    const uint8_t state[] = {1, 2, 3, 4, 5, 6, 7, 8, 9};
    CHECK(p->loadState(state, sizeof state, 1));
    uint8_t back[16] = {};
    uint32_t written = 0;
    CHECK(p->saveState(back, sizeof back, written));
    CHECK_EQ(written, 9u);
    CHECK(std::memcmp(back, state, 9) == 0);
    CHECK(!p->loadState(state, sizeof state, 2));
}

TEST(cab_gives_the_same_bits_at_any_block_size_and_survives_bad_input) {
    const Values v = {{"cab", 4}, {"position", 0.6}, {"distance", 0.7}};
    checkBlockSizes(kConv, with(v, 1), music(30000), "cab");
    checkBadInput(kConv, with(v, 1), "cab", 48000);
}

TEST(cab_presets_are_job_named_and_sound) {
    checkPresets(kConv, 1, 8, music(48000));
    CHECK(findBuiltinPreset(kConv, "Rock 4x12 close") && findBuiltinPreset(kConv, "Bass 1x15 deep"));
}

TEST(cab_matches_its_reference_renders) {
    cawtest::References refs("fx_cab");
    const Stereo in = music(48000 * 2);
    const char* names[] = {"cab_4x12_close", "cab_bass_4x10_far"};
    const Values values[] = {{{"cab", 2}, {"position", 0.2}, {"distance", 0.1}}, {{"cab", 4}, {"position", 0.5}, {"distance", 0.9}}};
    for (int k = 0; k < 2; ++k) {
        const Stereo out = render(kConv, with(values[k], 1), in);
        CHECK_REFERENCE(refs, names[k], (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
}
