// Bit distortion's 1.1.0 Bitwise variant: word size, shift, XOR and AND masks bit-exact, the lanes display, block sizes, bad input, presets, reference.
#include "fx_modes_harness.h"
#include "tolerance.h"

using namespace modes_test;

namespace {

constexpr const char* kBits = "org.caw.bits";

// What one sample becomes (the variant's own arithmetic, written out here independently).
double expect(double x, int bits, int shift, uint32_t xor16, uint32_t and16) {
    x = std::clamp(x, -1.0, 1.0);
    const uint32_t sign = 1u << (bits - 1), mask = (1u << bits) - 1u;
    const double scale = static_cast<double>(sign - 1);
    const int64_t q = std::llround(x * scale);
    int64_t v = shift >= 0 ? q * (int64_t{1} << shift) : (q >= 0 ? q >> -shift : -((-q + (int64_t{1} << -shift) - 1) >> -shift));
    uint32_t u = static_cast<uint32_t>(v) & mask;
    if (q == 0) return 0.0;  // silence stays silence
    u = (u ^ ((xor16 >> (16 - bits)) & mask)) & ((and16 >> (16 - bits)) & mask);
    const int32_t s = static_cast<int32_t>(u ^ sign) - static_cast<int32_t>(sign);
    return s / scale;
}

}  // namespace

TEST(bitwise_is_bit_distortions_second_variant) {
    const fx::MergedDevice* m = fx::findMergedDevice(kBits);
    CHECK(m && m->variants.size() == 2u);
    CHECK(m && m->variants[1].name == std::string("Bitwise"));
    if (!m) return;
    const ModuleDescriptor* d = &m->variants[1].descriptor();
    // 1.1.0's six, `variant` (index 6, structural), then 1.1.1's glitch ops and the sidechain filter appended.
    CHECK_EQ(d->parameterCount, 27u);
    const ParameterDescriptor& v = d->parameters[6];
    CHECK(v.id == fx::kVariantParam);
    CHECK_EQ(v.defaultValue, 1.0);
    CHECK_EQ(v.choiceCount, 2u);
    CHECK(!v.automatable && !v.modulatable && !v.midiMappable);
    CHECK_EQ(d->latencyFrames, 0u);
    CHECK(d->cpuClass == CpuClass::Light);
}

TEST(bitwise_shifts_xors_and_masks_each_word_exactly) {
    Stereo in = silence(4096);
    for (size_t i = 0; i < in.size(); ++i) in.l[i] = in.r[i] = static_cast<float>(0.97 * std::sin(2 * kPi * 3 * i / 4096.0));
    struct Case {
        int bits, shift;
        uint32_t x, a;
    };
    for (const Case& c : {Case{16, 0, 0, 0xffff}, Case{12, 0, 0x00f0, 0xffff}, Case{8, 2, 0, 0xffff}, Case{10, -3, 0, 0xffff},
                          Case{16, 0, 0, 0xfc00}, Case{14, 1, 0x0ff0, 0xaaff}, Case{2, 0, 0, 0xffff}}) {
        const Values v = {{"bits", static_cast<double>(c.bits)}, {"shift", static_cast<double>(c.shift)}, {"xor", static_cast<double>(c.x)}, {"and", static_cast<double>(c.a)}};
        const Stereo out = render(kBits, with(v, 1), in);
        size_t wrong = 0;
        for (size_t i = 0; i < in.size(); ++i)
            wrong += std::fabs(out.l[i] - static_cast<float>(expect(in.l[i], c.bits, c.shift, c.x, c.a))) > 1e-6f;
        if (wrong) cawtest::fail(__FILE__, __LINE__, std::to_string(c.bits) + " bits, shift " + std::to_string(c.shift) + ": " + std::to_string(wrong) + " frames differ");
    }
    // The defaults (12 bits, nothing else) are a plain 12-bit quantiser: within half a step of the input.
    const Stereo plain = render(kBits, with({}, 1), in);
    for (size_t i = 0; i < in.size(); i += 97) CHECK(std::fabs(plain.l[i] - in.l[i]) < 1.0 / 2048);
}

TEST(bitwise_publishes_its_lanes_flipping) {
    auto p = make(kBits, with({{"bits", 16}}, 1));
    if (!p) return;
    run(*p, sine(440, 0.5, 4800), with({{"bits", 16}}, 1));
    float shown[64];
    CHECK_EQ(p->readDisplay(shown, 64), 45u);  // 1.1.1 appends 7 (fx_bits_glitch_test.cpp)
    CHECK_EQ(shown[2], 16.0f);
    CHECK(shown[6] > 0.2f && shown[6] <= 1.0f);  // the lowest lane flips often
    CHECK(shown[6 + 15] < 0.03f);                  // the sign lane twice a cycle (880 a second)
    for (int b = 0; b < 16; ++b) CHECK(shown[22 + b] == 0.0f || shown[22 + b] == 1.0f);
    // With 4 bits only the top 4 lanes move.
    auto q = make(kBits, with({{"bits", 4}}, 1));
    if (!q) return;
    run(*q, sine(440, 0.5, 4800), with({{"bits", 4}}, 1));
    q->readDisplay(shown, 64);
    for (int b = 0; b < 12; ++b) CHECK_EQ(shown[6 + b], 0.0f);
    CHECK(shown[6 + 13] > 0.0f);
}

TEST(bitwise_gives_the_same_bits_at_any_block_size_and_survives_bad_input) {
    const Values v = {{"bits", 11}, {"shift", 1}, {"xor", 0x0ff0}, {"and", 0xfff0}, {"mix", 0.7}};
    checkBlockSizes(kBits, with(v, 1), music(30000), "bitwise");
    checkBadInput(kBits, with(v, 1), "bitwise", 48000);
}

TEST(bitwise_presets_are_job_named_and_sound) {
    checkPresets(kBits, 1, 8, music(48000));
    CHECK(findBuiltinPreset(kBits, "Wrap around") && findBuiltinPreset(kBits, "Top bits only"));
}

TEST(bitwise_matches_its_reference_render) {
    cawtest::References refs("fx_bits_bitwise");
    const Stereo out = render(kBits, with({{"bits", 12}, {"shift", 1}, {"xor", 0x00f0}, {"and", 0xffe0}}, 1), music(48000 * 2));
    CHECK_REFERENCE(refs, "bitwise_mangle", (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
}
