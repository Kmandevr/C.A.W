// The tolerance comparators (tolerance.h): the reference codec, last-bit changes accepted, real bugs rejected.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <string>
#include <utility>
#include <system_error>
#include <vector>

#include "caw/detmath.hpp"
#include "engine.h"
#include "test.h"
#include "tolerance.h"

using namespace caw;
using cawtest::Audio;

namespace {

using Values = std::vector<std::pair<std::string, double>>;

// Plucked partials and noise bursts on a beat, a quarter second of silence, different sides (as effects_test's).
Audio music(size_t frames) {
    Audio s{std::vector<float>(frames, 0.0f), std::vector<float>(frames, 0.0f)};
    uint32_t seed = 12345;
    for (size_t i = 0; i < frames; ++i) {
        const size_t beat = i % 12000, bar = i / 12000;
        if (bar == 3) continue;
        const double env = detExp(-static_cast<double>(beat) / 2400.0);
        seed = seed * 1664525u + 1013904223u;
        const double noise = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * detExp(-static_cast<double>(beat) / 300.0);
        const double f = 110.0 * (1 + bar % 4);
        const double t = static_cast<double>(i) / 48000.0;
        const double tone = detSin(kTwoPi * f * t) + 0.5 * detSin(kTwoPi * 2.01 * f * t) + 0.25 * detSin(kTwoPi * 5.3 * f * t);
        s.l[i] = static_cast<float>(0.4 * env * tone + 0.3 * noise);
        s.r[i] = static_cast<float>(0.4 * env * detSin(kTwoPi * 1.5 * f * t) + 0.25 * noise);
    }
    return s;
}

// `in` through the built-in effect `id` at its defaults with `values` over them, in 64-frame blocks.
Audio through(const char* id, const Audio& in, const Values& values = {}) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
    CHECK(p != nullptr);
    if (!p || !p->activate(48000, 512)) return {};
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : values)
            if (d.parameters[k].id == name) params[k].value = v;
    }
    Audio out{std::vector<float>(in.frames()), std::vector<float>(in.frames())};
    for (size_t start = 0; start < in.frames(); start += 64) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(64, in.frames() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        AudioProcessBlock b;
        b.input = {ic, 2, n};
        b.output = {oc, 2, n};
        b.frames = n;
        b.sampleRate = 48000;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p->process(b));
    }
    return out;
}

Audio gained(Audio a, double db) {
    const float g = static_cast<float>(std::pow(10.0, db / 20.0));
    for (float& v : a.l) v *= g;
    for (float& v : a.r) v *= g;
    return a;
}
Audio clicked(Audio a, size_t at, int samples, float level) {
    for (int i = 0; i < samples; ++i) a.l[at + static_cast<size_t>(i)] += (i % 2 ? -level : level);
    return a;
}
Audio late(Audio a) {  // one frame later, the length kept
    for (std::vector<float>* c : {&a.l, &a.r}) {
        c->insert(c->begin(), 0.0f);
        c->pop_back();
    }
    return a;
}

#define CHECK_ACCEPTED(why)                                                                      \
    do {                                                                                         \
        const std::string w_ = (why);                                                            \
        if (!w_.empty()) cawtest::fail(__FILE__, __LINE__, "rejected: " + w_);                   \
    } while (0)

bool sameBits(const Audio& a, const Audio& b) { return a.l == b.l && a.r == b.r; }

}  // namespace

TEST(reference_codec_round_trips_the_rounded_samples) {
    // Music, a render through a reverb, silence, a full-scale square and values over full scale: each decodes to
    // exactly its 2^-21 steps, at most 2^-22 (-132.4 dBFS) from the render.
    Audio m = music(48000);
    Audio square{std::vector<float>(5000), std::vector<float>(5000)}, loud = square;
    for (size_t i = 0; i < 5000; ++i) {
        square.l[i] = (i / 50) % 2 ? 1.0f : -1.0f, square.r[i] = -square.l[i];
        loud.l[i] = 7.5f * static_cast<float>(detSin(0.01 * static_cast<double>(i))), loud.r[i] = loud.l[i] * -0.3f;
    }
    Audio silence{std::vector<float>(777), std::vector<float>(777)};
    for (const Audio* a : {&m, &square, &loud, &silence}) {
        const std::vector<uint8_t> bytes = cawtest::encodeAudio(*a);
        Audio back;
        CHECK(cawtest::decodeAudio(bytes, static_cast<uint32_t>(a->frames()), back));
        CHECK(sameBits(back, cawtest::quantize(*a)));
        CHECK(cawtest::nullResidualDbfs(back, *a) <= -132.4);
        CHECK_ACCEPTED(cawtest::compareStable(back, *a));
    }
    // Compressed: music takes well under the 22 bits a sample its steps span.
    CHECK(cawtest::encodeAudio(m).size() < m.frames() * 2 * 22 / 8 / 2);
    // A truncated stream is refused, not read past its end.
    std::vector<uint8_t> bytes = cawtest::encodeAudio(m);
    bytes.resize(bytes.size() / 2);
    Audio back;
    CHECK(!cawtest::decodeAudio(bytes, 48000, back));
}

TEST(stable_comparison_accepts_last_bit_changes_and_rejects_real_bugs) {
    const Audio in = music(48000 * 2);
    const Audio ref = cawtest::quantize(through("org.caw.filter", in, {{"resonance", 0.3}}));
    // Accepted: a few float steps of difference everywhere (what another rounding gives a stable path).
    Audio near = ref;
    for (size_t i = 0; i < near.frames(); ++i) {
        near.l[i] = std::nextafter(near.l[i], 2.0f);
        near.r[i] = std::nextafter(std::nextafter(near.r[i], -2.0f), -2.0f);
    }
    CHECK_ACCEPTED(cawtest::compareStable(ref, near));
    CHECK_ACCEPTED(cawtest::compareStable(ref, gained(ref, 1e-6)));
    // Rejected: a gain off by 0.5 dB, a 4-sample click at -40 dBFS, a filter at 1300 Hz instead of 1200, one frame
    // late, a frame short, and a NaN.
    CHECK(!cawtest::compareStable(ref, gained(ref, 0.5)).empty());
    CHECK(!cawtest::compareStable(ref, gained(ref, -0.01)).empty());
    CHECK(!cawtest::compareStable(ref, clicked(ref, 30000, 4, 0.01f)).empty());
    CHECK(!cawtest::compareStable(ref, through("org.caw.filter", in, {{"resonance", 0.3}, {"cutoff", 1300}})).empty());
    CHECK(!cawtest::compareStable(ref, late(ref)).empty());
    Audio shorter = ref;
    shorter.l.pop_back(), shorter.r.pop_back();
    CHECK(!cawtest::compareStable(ref, shorter).empty());
    Audio nan = ref;
    nan.r[1234] = std::nanf("");
    CHECK(!cawtest::compareStable(ref, nan).empty());
    // The smallest rejected difference is -120 dBFS.
    Audio edge = ref;
    edge.l[100] += 1.01e-6f;
    CHECK(!cawtest::compareStable(ref, edge).empty());
}

TEST(chaotic_comparison_accepts_another_phase_and_rejects_real_bugs) {
    // Accepted: three partials at other phases (a free-running oscillator started elsewhere): the same loudness in
    // every window, the same spectrum.
    auto tones = [](double p) {
        Audio a{std::vector<float>(48000), std::vector<float>(48000)};
        for (size_t i = 0; i < a.frames(); ++i) {
            const double t = kTwoPi * static_cast<double>(i) / 48000.0;
            a.l[i] = static_cast<float>(0.2 * (detSin(200 * t + 0.3 + p) + detSin(300 * t + 1.1 - p) + detSin(500 * t + 2.0 + 2 * p)));
            a.r[i] = static_cast<float>(0.3 * detSin(300 * t + 0.7 + 3 * p));
        }
        return a;
    };
    const cawtest::Features phase0 = cawtest::measureFeatures(tones(0)), phase1 = cawtest::measureFeatures(tones(0.4));
    CHECK_ACCEPTED(cawtest::compareChaotic(phase0, phase1));
    CHECK(!cawtest::compareStable(tones(0), tones(0.4)).empty());  // which the stable comparison would refuse

    // Rejected, on a reverb render (a chaotic-class sound) and a filter render (for onsets after silence).
    const Audio in = music(48000 * 2);
    const Audio verb = through("org.caw.reverb.pro", in);
    const cawtest::Features ref = cawtest::measureFeatures(verb);
    CHECK_ACCEPTED(cawtest::compareChaotic(ref, cawtest::measureFeatures(verb)));
    CHECK(!cawtest::compareChaotic(ref, cawtest::measureFeatures(gained(verb, 0.5))).empty());
    CHECK(!cawtest::compareChaotic(ref, cawtest::measureFeatures(gained(verb, -0.2))).empty());
    CHECK(!cawtest::compareChaotic(ref, cawtest::measureFeatures(clicked(verb, 30000, 4, 0.05f))).empty());
    const Audio filtered = through("org.caw.filter", in, {{"resonance", 0.3}});
    const cawtest::Features fref = cawtest::measureFeatures(filtered);
    CHECK(!fref.onsets[0].empty());
    CHECK(!cawtest::compareChaotic(fref, cawtest::measureFeatures(through("org.caw.filter", in, {{"resonance", 0.3}, {"cutoff", 1300}}))).empty());
    // Onsets may move by up to 2 frames in a chaotic render (stable renders stay exact through the null), no more.
    CHECK_ACCEPTED(cawtest::compareChaotic(fref, cawtest::measureFeatures(late(filtered))));
    CHECK(!cawtest::compareChaotic(fref, cawtest::measureFeatures(late(late(late(filtered))))).empty());
    CHECK(!cawtest::compareChaotic(fref, cawtest::measureFeatures(clicked(filtered, 30000, 4, 0.05f))).empty());
}

TEST(exact_comparison_of_discrete_results) {
    const std::vector<uint32_t> frames = {0, 12000, 24000, 48000};
    CHECK(cawtest::compareExact(frames, frames).empty());
    CHECK(!cawtest::compareExact(frames, {0, 12000, 24001, 48000}).empty());
    CHECK(!cawtest::compareExact(frames, {0, 12000, 24000}).empty());
    // Onsets: the first frame above -60 dBFS after 10 ms at or below -80 dBFS (frames between those levels do not
    // count as an onset nor as silence).
    std::vector<float> x(10000, 0.0f);
    x[100] = 0.5f, x[101] = 0.2f, x[300] = 0.5f, x[5000] = 5e-4f, x[5003] = 2e-3f;
    CHECK(cawtest::compareExact(cawtest::onsets(x), std::vector<uint32_t>{100, 5003}).empty());
}

namespace {

std::vector<uint8_t> fileBytes(const std::string& path) {
    std::vector<uint8_t> b;
    if (std::FILE* f = std::fopen(path.c_str(), "rb")) {
        uint8_t buf[4096];
        for (size_t n; (n = std::fread(buf, 1, sizeof buf, f)) > 0;) b.insert(b.end(), buf, buf + n);
        std::fclose(f);
    }
    return b;
}
void writeBytes(const std::string& path, const std::vector<uint8_t>& b) {
    if (std::FILE* f = std::fopen(path.c_str(), "wb")) {
        if (!b.empty()) std::fwrite(b.data(), 1, b.size(), f);
        std::fclose(f);
    }
}

}  // namespace

TEST(reference_files_round_trip_and_refuse_damaged_ones) {
    // A folder of its own (other runs may share the temporary folder).
    const std::filesystem::path where = std::filesystem::temp_directory_path() /
        ("caw_tolerance_references_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::error_code ec;
    std::filesystem::remove_all(where, ec);
    std::filesystem::create_directories(where, ec);
    const std::string dir = where.generic_string();
    const Audio m = music(24000), filtered = through("org.caw.filter", m), verb = through("org.caw.reverb.pro", m);
    {
        // Recorded: two stable renders (one twice, stored once), a chaotic one; a name recorded twice is refused.
        cawtest::References w("selftest", dir, true);
        CHECK_ACCEPTED(w.compare("music", m, cawtest::Class::Stable));
        CHECK_ACCEPTED(w.compare("music again", m, cawtest::Class::Stable));
        CHECK_ACCEPTED(w.compare("filtered", filtered, cawtest::Class::Stable));
        CHECK_ACCEPTED(w.compare("reverb", verb, cawtest::Class::Chaotic));
        CHECK(!w.compare("music", m, cawtest::Class::Stable).empty());
    }
    const std::string path = dir + "/selftest.cawref";
    const std::vector<uint8_t> bytes = fileBytes(path);
    CHECK(bytes.size() > 1000);
    CHECK(bytes.size() < cawtest::encodeAudio(m).size() * 2);  // the repeat is an alias
    {
        // Read back: every render accepted; a changed one, another class, an unknown name and another length not.
        cawtest::References r("selftest", dir, false);
        CHECK(r.loaded());
        CHECK_EQ(r.size(), size_t{4});
        CHECK_ACCEPTED(r.compare("music", m, cawtest::Class::Stable));
        CHECK_ACCEPTED(r.compare("music again", m, cawtest::Class::Stable));
        CHECK_ACCEPTED(r.compare("filtered", filtered, cawtest::Class::Stable));
        CHECK_ACCEPTED(r.compare("reverb", verb, cawtest::Class::Chaotic));
        CHECK(!r.compare("music again", gained(m, 0.5), cawtest::Class::Stable).empty());
        CHECK(!r.compare("reverb", gained(verb, 0.5), cawtest::Class::Chaotic).empty());
        CHECK(!r.compare("filtered", filtered, cawtest::Class::Chaotic).empty());
        CHECK(!r.compare("unknown", m, cawtest::Class::Stable).empty());
        CHECK(!r.compare("music", music(24001), cawtest::Class::Stable).empty());
    }
    // Damaged files are refused whole, never read past their end: truncated anywhere, a byte too many, another magic.
    std::vector<std::vector<uint8_t>> damaged;
    for (size_t cut : {size_t{0}, size_t{7}, size_t{11}, size_t{40}, bytes.size() / 3, bytes.size() / 2, bytes.size() - 1})
        damaged.emplace_back(bytes.begin(), bytes.begin() + static_cast<std::ptrdiff_t>(cut));
    damaged.push_back(bytes);
    damaged.back().push_back(0);
    damaged.push_back(bytes);
    damaged.back()[6] = '9';
    for (const std::vector<uint8_t>& d : damaged) {
        writeBytes(path, d);
        cawtest::References r("selftest", dir, false);
        CHECK(!r.loaded());
        CHECK_EQ(r.size(), size_t{0});
        CHECK(!r.compare("music", m, cawtest::Class::Stable).empty());
    }
    // A waveform whose stream is cut short does not decode, nor one whose residual would overflow.
    std::vector<uint8_t> wave = cawtest::encodeAudio(m);
    Audio back;
    wave.resize(wave.size() - 16);
    CHECK(!cawtest::decodeAudio(wave, static_cast<uint32_t>(m.frames()), back));
    std::vector<uint8_t> huge(64, 0xFF);  // a raw 64-bit escape everywhere
    CHECK(!cawtest::decodeAudio(huge, 100, back));
    std::filesystem::remove_all(where, ec);
}
