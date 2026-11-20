// Bit distortion's Bitwise glitch ops (1.1.1): rotate, reverse, OR, the key and echo combine, steps and pattern, freeze, seeded flips, tone, gate and level; block sizes, bad input, not static, reference.
#include <cstring>

#include "fx_modes_harness.h"
#include "tolerance.h"

using namespace modes_test;

namespace {

constexpr const char* kBits = "org.caw.bits";

// The word after the shift, in its own bits (the 1.1.0 arithmetic, written out here independently), and q.
uint32_t shifted(double x, int bits, int shift, int64_t& q) {
    x = std::clamp(x, -1.0, 1.0);
    const uint32_t sign = 1u << (bits - 1), mask = (1u << bits) - 1u;
    q = std::llround(x * static_cast<double>(sign - 1));
    const int64_t v = shift >= 0 ? q * (int64_t{1} << shift) : (q >= 0 ? q >> -shift : -((-q + (int64_t{1} << -shift) - 1) >> -shift));
    return static_cast<uint32_t>(v) & mask;
}
struct Ops {
    int bits = 12, shift = 0, rotate = 0, reverse = 0;
    uint32_t x = 0, o = 0, a = 0xffff, combine = 0;  // combine: the combined lanes (16-bit)
    int op = 0;                                      // 0 XOR, 1 AND, 2 OR
};
// One sample through every op (all steps active, nothing frozen or flipped), `other` the combined word.
double expect(double x, const Ops& k, uint32_t other = 0) {
    int64_t q;
    const int b = k.bits;
    const uint32_t mask = (1u << b) - 1u, sign = 1u << (b - 1);
    uint32_t u = shifted(x, b, k.shift, q);
    if (q == 0) return 0.0;
    const uint32_t cm = (k.combine >> (16 - b)) & mask;
    for (int lane = 0; lane < b; ++lane) {  // lane by lane
        if (!((cm >> lane) & 1u)) continue;
        const uint32_t mine = (u >> lane) & 1u, theirs = (other >> lane) & 1u;
        const uint32_t r = k.op == 0 ? mine ^ theirs : (k.op == 1 ? mine & theirs : mine | theirs);
        u = (u & ~(1u << lane)) | (r << lane);
    }
    const int rot = ((k.rotate % b) + b) % b;
    uint32_t rotated = 0;
    for (int lane = 0; lane < b; ++lane) rotated |= ((u >> lane) & 1u) << ((lane + rot) % b);
    u = rotated;
    const int n = std::min(k.reverse, b);
    uint32_t rev = u & ~((1u << n) - 1u);
    for (int lane = 0; lane < n; ++lane) rev |= ((u >> lane) & 1u) << (n - 1 - lane);
    u = rev;
    u = ((u ^ ((k.x >> (16 - b)) & mask)) | ((k.o >> (16 - b)) & mask)) & ((k.a >> (16 - b)) & mask);
    const int32_t s = static_cast<int32_t>(u ^ sign) - static_cast<int32_t>(sign);
    return s / static_cast<double>(sign - 1);
}
uint32_t keyWord(double x, int bits) {
    int64_t q;
    return shifted(x, bits, 0, q);
}

Values glitch(Values v) {  // the exact tests: no level, all steps active
    v.emplace_back("level", 0);
    return with(v, 1);
}

// `in` through p with a key on the sidechain (processPorts), in `block`-frame blocks.
Stereo runKeyed(ModuleProcessor& p, const Stereo& in, const Stereo& key, const Values& values, uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    Stereo out = silence(in.size());
    for (size_t start = 0; start < in.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        const float* kc[2] = {key.l.data() + start, key.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        const ConstChannelBufferView ins[2] = {{ic, 2, n}, {kc, 2, n}};
        const ChannelBufferView outs[1] = {{oc, 2, n}};
        ProcessBlock b;
        b.frames = n;
        b.sampleRate = 48000;
        b.audioIn = ins;
        b.audioInCount = 2;
        b.audioOut = outs;
        b.audioOutCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p.processPorts(b));
    }
    return out;
}

Stereo tone(double hz, double amp, size_t frames, double phase = 0.3) {
    Stereo s = silence(frames);
    for (size_t i = 0; i < frames; ++i) s.l[i] = s.r[i] = static_cast<float>(amp * std::sin(2 * kPi * hz * i / 48000.0 + phase));
    return s;
}

size_t differing(const std::vector<float>& got, const std::vector<double>& want) {
    size_t wrong = 0;
    for (size_t i = 0; i < got.size(); ++i) wrong += std::fabs(got[i] - static_cast<float>(want[i])) > 1e-6f;
    return wrong;
}

// Spectral flatness (geometric over arithmetic mean of the power, Hann windows of 1024, bins 2..511), averaged over
// the loud windows of `x`: white noise is about 0.55, a tone near 0.
double flatness(const std::vector<float>& x) {
    constexpr size_t n = 1024;
    std::vector<double> c(n), s(n), w(n);
    for (size_t k = 0; k < n; ++k) {
        c[k] = std::cos(2 * kPi * k / n), s[k] = std::sin(2 * kPi * k / n);
        w[k] = 0.5 - 0.5 * std::cos(2 * kPi * k / n);
    }
    double sum = 0;
    int count = 0;
    for (size_t at = 0; at + n <= x.size(); at += 6000) {
        if (rms(x, at, at + n) < 1e-3) continue;
        double logSum = 0, linSum = 0;
        for (size_t bin = 2; bin < n / 2; ++bin) {
            double re = 0, im = 0;
            for (size_t k = 0; k < n; ++k) {
                const double v = x[at + k] * w[k];
                const size_t idx = (bin * k) % n;
                re += v * c[idx], im -= v * s[idx];
            }
            const double pw = re * re + im * im + 1e-20;
            logSum += std::log(pw), linSum += pw;
        }
        const double m = static_cast<double>(n / 2 - 2);
        sum += std::exp(logSum / m) / (linSum / m);
        ++count;
    }
    return count ? sum / count : 0.0;
}

bool isGlitchPreset(const BuiltinPreset& p) {
    bool mine = false, ops = false;
    for (const auto& [k, x] : p.values) {
        mine = mine || (k == "variant" && x == 1.0);
        ops = ops || k == "combine" || k == "rotate" || k == "reverse" || k == "or" || k == "freeze" || k == "flips" ||
              k == "pattern";
    }
    return mine && ops;
}

}  // namespace

TEST(bits_glitch_appends_its_parameters_and_a_key) {
    const fx::MergedDevice* m = fx::findMergedDevice(kBits);
    CHECK(m && m->variants.size() == 2u);  // no new variant: the ops are Bitwise's
    if (!m) return;
    const ModuleDescriptor& d = m->variants[1].descriptor();
    const char* ids[] = {"bits", "shift", "xor", "and", "output", "mix", "variant", "rotate", "reverse", "or", "combine",
                         "combine_op", "combine_mask", "echo", "rate", "pattern", "freeze", "grain", "hold", "flips",
                         "seed", "tone", "gate", "level", "sc_hpf", "sc_lpf", "sc_listen"};
    CHECK_EQ(d.parameterCount, 27u);
    for (uint32_t k = 0; k < 27 && k < d.parameterCount; ++k) CHECK(d.parameters[k].id == std::string(ids[k]));
    bool key = false;
    for (uint32_t k = 0; k < d.portCount; ++k) key = key || (d.ports[k].input && d.ports[k].id == "sidechain");
    CHECK(key);
    CHECK(d.cpuClass == CpuClass::Light);
    // Crush is untouched: no key.
    const ModuleDescriptor& crush = m->variants[0].descriptor();
    for (uint32_t k = 0; k < crush.portCount; ++k) CHECK(crush.ports[k].id != "sidechain");
}

TEST(bits_glitch_neutral_knobs_play_the_1_1_0_word_bit_for_bit) {
    const Stereo in = music(24000);
    const Values old = {{"bits", 11}, {"shift", 1}, {"xor", 0x0ff0}, {"and", 0xfff0}, {"mix", 0.7}};
    const Stereo a = render(kBits, with(old, 1), in);
    Values neutral = old;
    for (const auto& kv : Values{{"rotate", 0}, {"reverse", 0}, {"or", 0}, {"combine", 0}, {"freeze", 0}, {"flips", 0},
                                 {"tone", 20000}, {"gate", -80}, {"level", 0}, {"rate", 6}, {"seed", 99}})
        neutral.push_back(kv);
    const Stereo b = render(kBits, with(neutral, 1), in);
    CHECK(std::memcmp(a.l.data(), b.l.data(), a.l.size() * 4) == 0 && std::memcmp(a.r.data(), b.r.data(), a.r.size() * 4) == 0);
}

TEST(bits_glitch_rotate_reverse_and_or_are_exact) {
    const Stereo in = tone(3 * 48000.0 / 4096, 0.97, 4096);
    for (const Ops& k : {Ops{12, 0, 1, 0, 0, 0, 0xffff}, Ops{8, 1, -3, 0, 0, 0, 0xffff}, Ops{16, 0, 0, 5, 0, 0, 0xffff},
                         Ops{10, -2, 0, 10, 0, 0, 0xffff}, Ops{12, 0, 0, 0, 0, 0x00f0, 0xffff},
                         Ops{14, 0, 2, 4, 0x0ff0, 0x0003 << 4, 0xfff0}}) {
        const Values v = {{"bits", double(k.bits)}, {"shift", double(k.shift)}, {"rotate", double(k.rotate)}, {"reverse", double(k.reverse)},
                          {"xor", double(k.x)}, {"or", double(k.o)}, {"and", double(k.a)}};
        const Stereo out = render(kBits, glitch(v), in);
        std::vector<double> want(in.size());
        for (size_t i = 0; i < in.size(); ++i) want[i] = expect(in.l[i], k);
        if (const size_t w = differing(out.l, want))
            cawtest::fail(__FILE__, __LINE__, std::to_string(k.bits) + " bits, rotate " + std::to_string(k.rotate) + ", reverse " +
                                                  std::to_string(k.reverse) + ": " + std::to_string(w) + " frames differ");
    }
}

TEST(bits_glitch_combines_with_the_key_bit_by_bit) {
    const Stereo in = tone(220, 0.8, 9600), key = tone(331, 0.7, 9600, 1.1);
    for (int op = 0; op < 3; ++op) {
        const Values v = {{"bits", 12}, {"combine", 1}, {"combine_op", double(op)}, {"combine_mask", 0xff00}};
        auto p = make(kBits, glitch(v));
        if (!p) return;
        const Stereo out = runKeyed(*p, in, key, glitch(v));
        Ops k;
        k.combine = 0xff00, k.op = op;
        std::vector<double> want(in.size());
        for (size_t i = 0; i < in.size(); ++i) want[i] = expect(in.l[i], k, keyWord(key.l[i], 12));
        if (const size_t w = differing(out.l, want))
            cawtest::fail(__FILE__, __LINE__, "key op " + std::to_string(op) + ": " + std::to_string(w) + " frames differ");
        // The same at other block sizes.
        for (uint32_t block : {1u, 37u, 512u}) {
            p->reset();
            const Stereo again = runKeyed(*p, in, key, glitch(v), block);
            CHECK(std::memcmp(again.l.data(), out.l.data(), out.l.size() * 4) == 0);
        }
    }
    // No key routed: the word passes (a plain 12-bit word); Listen plays the key.
    const Values v = {{"bits", 12}, {"combine", 1}, {"combine_op", 1}};
    const Stereo plain = render(kBits, glitch(v), in);
    std::vector<double> want(in.size());
    for (size_t i = 0; i < in.size(); ++i) want[i] = expect(in.l[i], Ops{});
    CHECK_EQ(differing(plain.l, want), size_t{0});
    auto p = make(kBits, glitch({{"combine", 1}, {"sc_listen", 1}}));
    if (!p) return;
    const Stereo heard = runKeyed(*p, in, key, glitch({{"combine", 1}, {"sc_listen", 1}}));
    CHECK(std::memcmp(heard.l.data(), key.l.data(), key.l.size() * 4) == 0);
}

TEST(bits_glitch_echo_combines_with_its_own_word_ago) {
    const Stereo in = tone(97, 0.9, 9600);
    const Values v = {{"bits", 12}, {"combine", 2}, {"echo", 2}};  // 96 frames
    const Stereo out = render(kBits, glitch(v), in);
    Ops k;
    k.combine = 0xffff;
    std::vector<double> want(in.size());
    for (size_t i = 0; i < in.size(); ++i) want[i] = expect(in.l[i], k, i >= 96 ? keyWord(in.l[i - 96], 12) : 0u);
    CHECK_EQ(differing(out.l, want), size_t{0});
}

TEST(bits_glitch_pattern_gates_the_ops_by_step) {
    // 1/16 at 120 (no transport): 6000 frames a step, from the first sound. Pattern 0b01: only the first of 8 steps.
    const Stereo in = tone(110, 0.9, 6000 * 9);
    const Values v = {{"bits", 12}, {"xor", 0x0f00}, {"rate", 2}, {"pattern", 1}};
    const Stereo out = render(kBits, glitch(v), in);
    Ops on, off;
    on.x = 0x0f00;
    std::vector<double> want(in.size());
    for (size_t i = 0; i < in.size(); ++i) want[i] = expect(in.l[i], (i / 6000) % 8 == 0 ? on : off);
    CHECK_EQ(differing(out.l, want), size_t{0});
    // While the song plays, the steps follow its position: covered by the free clock's being the same beat grid.
}

TEST(bits_glitch_freeze_loops_its_grain_for_the_hold) {
    // 1/4 at 120: 24000 frames a step; a 10 ms grain (480 frames) of every lane, held for the whole step.
    const Stereo in = tone(173, 0.9, 30000);
    const Values v = {{"bits", 16}, {"freeze", 0xffff}, {"grain", 10}, {"hold", 1}, {"rate", 5}};
    const Stereo out = render(kBits, glitch(v), in);
    Ops k;
    k.bits = 16;
    size_t wrong = 0;
    for (size_t i = 0; i < 24000; ++i) {
        const bool silent = expect(in.l[i], k) == 0.0;  // silence stays silence, even frozen
        const double want = silent ? 0.0 : expect(in.l[i % 480], k);
        wrong += std::fabs(out.l[i] - static_cast<float>(want)) > 1e-6f;
    }
    CHECK_EQ(wrong, size_t{0});
    // The next step records a new grain: live again for its first 480 frames.
    for (size_t i = 24000; i < 24480; ++i) CHECK(std::fabs(out.l[i] - static_cast<float>(expect(in.l[i], k))) < 1e-6f);
}

TEST(bits_glitch_flips_are_seeded_and_repeat) {
    const Stereo in = music(48000);
    const Values v = {{"bits", 12}, {"flips", 0.2}, {"seed", 7}, {"rate", 2}};
    const Stereo a = render(kBits, glitch(v), in), b = render(kBits, glitch(v), in);
    CHECK(std::memcmp(a.l.data(), b.l.data(), a.l.size() * 4) == 0);
    Values other = v;
    other[2].second = 8;
    const Stereo c = render(kBits, glitch(other), in);
    CHECK(std::memcmp(a.l.data(), c.l.data(), a.l.size() * 4) != 0);
    const Stereo plain = render(kBits, glitch({{"bits", 12}}), in);
    CHECK(std::memcmp(a.l.data(), plain.l.data(), a.l.size() * 4) != 0);
    // Flips of 1: every lane of every step flips (the word inverted).
    const Stereo all = render(kBits, glitch({{"bits", 12}, {"flips", 1}}), in);
    for (size_t i = 0; i < in.size(); i += 101) {
        const double p = expect(in.l[i], Ops{});
        if (p != 0.0) CHECK(std::fabs(all.l[i] - static_cast<float>(-p - 1.0 / 2047)) < 1e-6f);
    }
}

TEST(bits_glitch_gives_the_same_bits_at_any_block_size_and_survives_bad_input) {
    const Values sets[] = {
        with({{"bits", 11}, {"rotate", 2}, {"reverse", 3}, {"or", 0x0030}, {"pattern", 0x5a}, {"tone", 6000}}, 1),
        with({{"bits", 14}, {"combine", 2}, {"echo", 7}, {"freeze", 0xf000}, {"grain", 9}, {"hold", 0.7}, {"gate", -40}}, 1),
        with({{"bits", 10}, {"flips", 0.3}, {"seed", 3}, {"rate", 0}, {"combine_mask", 0x0ff0}, {"combine", 2}}, 1),
    };
    int k = 0;
    for (const Values& v : sets) {
        const std::string what = "glitch set " + std::to_string(k++);
        checkBlockSizes(kBits, v, music(30000), what);
        checkBadInput(kBits, v, what, 48000);
    }
}

TEST(bits_glitch_presets_are_tagged_level_safe_and_not_static) {
    const Stereo in = music(48000 * 2);
    const double inRms = rms(in.l), inFlat = flatness(in.l);
    size_t glitchPresets = 0;
    for (const BuiltinPreset& preset : builtinPresets(kBits)) {
        if (!isGlitchPreset(preset)) continue;
        ++glitchPresets;
        CHECK(preset.description.find(": ") != std::string_view::npos);  // "Purpose: what it does"
        Values values;
        CHECK(applyBuiltinPreset(kBits, preset.name, values));
        const Stereo out = render(kBits, values, in);
        const std::string name(preset.name);
        // Never louder than the input (Auto level), and not silenced.
        const double level = rms(out.l);
        if (!(level <= inRms * 1.05 && level > inRms * 0.1))
            cawtest::fail(__FILE__, __LINE__, name + ": level " + std::to_string(db(level / inRms)) + " dB from the input");
        // Not static: not white noise (flatness well under noise's 0.55), and still moving with the music in each
        // quarter second where the music sounds.
        const double flat = flatness(out.l);
        if (!(flat < 0.25 && flat < inFlat + 0.15))
            cawtest::fail(__FILE__, __LINE__, name + ": spectral flatness " + std::to_string(flat) + " (input " + std::to_string(inFlat) + ")");
        for (size_t at = 0; at + 12000 <= in.size(); at += 12000) {
            if (rms(in.l, at, at + 12000) < 0.01) continue;
            double moved = 0;
            for (size_t i = at + 1; i < at + 12000; ++i) moved += std::fabs(out.l[i] - out.l[i - 1]);
            if (moved < 1.0) cawtest::fail(__FILE__, __LINE__, name + ": stuck at " + std::to_string(at));
        }
    }
    CHECK(glitchPresets >= 8u);
}

TEST(bits_glitch_matches_its_reference_renders) {
    cawtest::References refs("fx_bits_glitch");
    const Stereo in = music(48000 * 2);
    const Stereo ring = render(kBits, with({{"bits", 12}, {"combine", 2}, {"echo", 3}, {"combine_mask", 0xff00}, {"tone", 9000}}, 1), in);
    CHECK_REFERENCE(refs, "glitch_echo_ring", (cawtest::Audio{ring.l, ring.r}), cawtest::Class::Stable);
    const Stereo steps = render(kBits, with({{"bits", 12}, {"xor", 0x0f00}, {"rotate", 1}, {"reverse", 3}, {"freeze", 0xf000},
                                             {"grain", 15}, {"hold", 0.8}, {"flips", 0.1}, {"seed", 7}, {"pattern", 0x5d}, {"gate", -50}}, 1),
                                in);
    CHECK_REFERENCE(refs, "glitch_steps", (cawtest::Audio{steps.l, steps.r}), cawtest::Class::Stable);
}
