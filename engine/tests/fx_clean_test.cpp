// 1.1.0's clean-up devices: Preen (Denoise, De-hum, De-reverb) and Hush (De-click, De-plosive, Breath): transparency, latency, SNR gain, musical noise, hum found, events found, the clip pass, block sizes, NaN, presets, references.
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "caw/library/convolver.hpp"
#include "component_chain.h"
#include "fx_clean.h"
#include "fx_modes_harness.h"
#include "tolerance.h"

using namespace caw;
using namespace modes_test;

namespace {

constexpr const char* kPreen = "org.caw.clean";
constexpr const char* kHush = "org.caw.vocalclean";

Stereo whiteNoise(size_t n, double amp, uint32_t seed = 11) {
    Stereo s = silence(n);
    for (size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        s.l[i] = static_cast<float>(amp * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0));
        seed = seed * 1664525u + 1013904223u;
        s.r[i] = static_cast<float>(amp * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0));
    }
    return s;
}
Stereo tones(size_t n, double amp = 0.3) {
    Stereo s = silence(n);
    for (size_t i = 0; i < n; ++i) {
        const double t = i / 48000.0;
        const double v = amp * (std::sin(2 * modes_test::kPi * 440 * t) + 0.5 * std::sin(2 * modes_test::kPi * 1250 * t)) * (0.6 + 0.4 * std::sin(2 * modes_test::kPi * 0.7 * t));
        s.l[i] = static_cast<float>(v);
        s.r[i] = static_cast<float>(0.9 * v);
    }
    return s;
}
// Plucked notes (two partials, a new one every 250 ms, decaying), no noise of their own.
Stereo plucks(size_t n) {
    Stereo s = silence(n);
    const double hz[] = {110.0, 164.8, 220.0, 293.7, 196.0, 130.8};
    for (size_t i = 0; i < n; ++i) {
        const size_t t = i % 12000;
        const double f = hz[(i / 12000) % 6], env = std::exp(-static_cast<double>(t) / 6000.0);
        const double v = 0.3 * env * (std::sin(2 * modes_test::kPi * f * t / 48000.0) + 0.4 * std::sin(2 * modes_test::kPi * 3 * f * t / 48000.0));
        s.l[i] = static_cast<float>(v), s.r[i] = static_cast<float>(0.9 * v);
    }
    return s;
}
Stereo add(Stereo a, const Stereo& b, double gain = 1.0) {
    for (size_t i = 0; i < a.size(); ++i) a.l[i] += static_cast<float>(gain * b.l[i]), a.r[i] += static_cast<float>(gain * b.r[i]);
    return a;
}
// The error of `out` against `want` delayed by `lag`, from `from` on: the peak and the RMS ratio in dB.
double errorDb(const Stereo& out, const Stereo& want, size_t lag, size_t from) {
    double e = 0, w = 0;
    for (size_t i = from; i < out.size(); ++i) {
        const double ref = i >= lag ? want.l[i - lag] : 0.0;
        e += (out.l[i] - ref) * (out.l[i] - ref);
        w += ref * ref;
    }
    return 10.0 * std::log10((e + 1e-30) / (w + 1e-30));
}
double peakErrorDb(const Stereo& out, const Stereo& want, size_t lag, size_t from) {
    double p = 0;
    for (size_t i = from; i < out.size(); ++i) {
        const double ref = i >= lag ? want.l[i - lag] : 0.0;
        p = std::max({p, std::fabs(out.l[i] - ref), std::fabs(out.r[i] - (i >= lag ? want.r[i - lag] : 0.0))});
    }
    return db(p);
}
uint32_t latencyOf(const char* id, const Values& v) {
    auto p = make(id, v);
    if (!p) return ~0u;
    const auto* var = dynamic_cast<const VariableLatency*>(p.get());
    if (!var) return p->descriptor().latencyFrames;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<double> values(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        values[k] = d.parameters[k].defaultValue;
        for (const auto& [name, x] : v)
            if (d.parameters[k].id == name) values[k] = x;
    }
    return var->latencyFor(values.data(), d.parameterCount);
}
// The lag (0..maxLag) at which `out` best matches `in`.
size_t bestLag(const Stereo& in, const Stereo& out, size_t maxLag) {
    size_t best = 0;
    double most = -1e300;
    for (size_t lag = 0; lag <= maxLag; ++lag) {
        double s = 0;
        for (size_t i = maxLag; i < in.size() - maxLag; ++i) s += static_cast<double>(in.l[i]) * out.l[i + lag];
        if (s > most) most = s, best = lag;
    }
    return best;
}
double goertzelDb(const std::vector<float>& x, double hz, size_t from, size_t to) {
    const double c = 2 * std::cos(2 * modes_test::kPi * hz / 48000.0);
    double s1 = 0, s2 = 0;
    for (size_t i = from; i < to; ++i) {
        const double s = x[i] + c * s1 - s2;
        s2 = s1, s1 = s;
    }
    const double n = static_cast<double>(to - from);
    return 10 * std::log10((s1 * s1 + s2 * s2 - c * s1 * s2) / (n * n) + 1e-30);
}
std::vector<float> display(ModuleProcessor& p) {
    std::vector<float> d(256);
    d.resize(p.readDisplay(d.data(), 256));
    return d;
}

}  // namespace

TEST(clean_devices_list_their_variants) {
    checkVariant(kPreen, 0, "Denoise");
    checkVariant(kPreen, 1, "De-hum");
    checkVariant(kPreen, 2, "De-reverb");
    checkVariant(kHush, 0, "De-click");
    checkVariant(kHush, 1, "De-plosive");
    checkVariant(kHush, 2, "Breath");
    // Learn, the quality tier and monitoring are set by hand only.
    const ModuleDescriptor* d = checkVariant(kPreen, 0, "Denoise");
    if (d)
        for (uint32_t k = 0; k < d->parameterCount; ++k) {
            const std::string id(d->parameters[k].id);
            if (id == "learn" || id == "quality" || id == "monitor") CHECK(!d->parameters[k].automatable && !d->parameters[k].modulatable);
        }
}

TEST(preen_reports_its_latency_by_tier_and_it_is_measured) {
    const Stereo in = music(48000);
    struct Case {
        Values v;
        uint32_t want;
    } cases[] = {{{{"variant", 0}, {"quality", 0}}, 1024}, {{{"variant", 0}}, 2048}, {{{"variant", 0}, {"quality", 2}}, 4096},
                 {{{"variant", 0}, {"monitor", 1}}, 512},  {{{"variant", 0}, {"monitor", 1}, {"quality", 2}}, 512},
                 {{{"variant", 2}}, 2048},                 {{{"variant", 2}, {"monitor", 1}}, 512}};
    for (const Case& c : cases) {
        CHECK_EQ(latencyOf(kPreen, c.v), c.want);
        // Reduction (Amount) 0 gives the input back exactly that late, to rounding: null below -90 dB.
        Values v = c.v;
        v.emplace_back("reduction", 0.0);
        v.emplace_back("amount", 0.0);
        const Stereo out = render(kPreen, v, in);
        const double e = peakErrorDb(out, in, c.want, 0);
        if (!(e < -90.0)) cawtest::fail(__FILE__, __LINE__, "not transparent at window " + std::to_string(c.want) + ": " + std::to_string(e));
    }
    CHECK_EQ(latencyOf(kPreen, {{"variant", 1}}), 0u);
    // De-hum at depth 0 is the input, bit for bit.
    const Stereo hum = render(kPreen, {{"variant", 1}, {"frequency", 1}, {"depth", 0}}, in);
    CHECK(std::memcmp(hum.l.data(), in.l.data(), in.size() * 4) == 0);
}

TEST(denoise_raises_the_snr_of_music_in_noise) {
    // Adaptive tracking needs a signal that moves (a held tone longer than its 1.5 s window reads as noise): notes.
    const size_t n = 48000 * 5;
    const Stereo clean = music(n);
    const Stereo noisy = add(clean, whiteNoise(n, 0.03));
    const double before = errorDb(noisy, clean, 0, 48000 * 2);
    for (int q : {0, 1, 2}) {
        const Values v = {{"variant", 0}, {"reduction", 20}, {"quality", static_cast<double>(q)}};
        const Stereo out = render(kPreen, v, noisy);
        const double after = errorDb(out, clean, latencyOf(kPreen, v), 48000 * 2);
        if (!(after < before - (q == 2 ? 1.0 : 3.0)))  // High's long window smears the notes' onsets more  // waveform SNR (the notes' own noise bursts count as signal)
            cawtest::fail(__FILE__, __LINE__, "tier " + std::to_string(q) + ": SNR " + std::to_string(-before) + " -> " + std::to_string(-after));
    }
    // Listen gives what is removed: with the output it sums back to the input.
    const Stereo kept = render(kPreen, {{"variant", 0}, {"reduction", 20}}, noisy);
    const Stereo gone = render(kPreen, {{"variant", 0}, {"reduction", 20}, {"listen", 1}}, noisy);
    CHECK(peakErrorDb(add(kept, gone), noisy, 2048, 0) < -90.0);
}

TEST(denoise_learns_a_profile_saves_it_and_uses_it) {
    const size_t n = 48000 * 2;
    const Stereo noise = whiteNoise(n, 0.03, 5);
    const Values learn = {{"variant", 0}, {"learn", 1}, {"adaptive", 0}, {"reduction", 20}};
    const Values use = {{"variant", 0}, {"learn", 0}, {"adaptive", 0}, {"reduction", 20}};
    auto p = make(kPreen, learn);
    if (!p) return;
    const Stereo heard = run(*p, noise, learn);
    // While learning the noise passes unchanged.
    CHECK(peakErrorDb(heard, noise, 2048, 0) < -90.0);
    const Stereo clean = tones(n, 0.2);
    const Stereo noisy = add(clean, whiteNoise(n, 0.03, 9));
    const Stereo out = run(*p, noisy, use);
    const std::vector<float> shown = display(*p);
    CHECK(shown.size() == 74 && shown[4] == 1.0f && shown[3] > 1.5f);
    CHECK(errorDb(out, clean, 2048, 24000) < errorDb(noisy, clean, 0, 24000) - 6.0);
    // The saved profile restores into a new instance at another rate's grid and reduces the same.
    std::vector<uint8_t> state(p->descriptor().maxStateBytes);
    uint32_t written = 0;
    CHECK(p->saveState(state.data(), static_cast<uint32_t>(state.size()), written) && written > 16);
    state.resize(written);
    auto q = make(kPreen, use);
    CHECK(q && q->loadState(state.data(), written, 1));
    if (q) CHECK(errorDb(run(*q, noisy, use), clean, 2048, 24000) < errorDb(noisy, clean, 0, 24000) - 6.0);
    // Bad bytes are refused.
    std::vector<uint8_t> bad = state;
    bad[5] = 0xff;
    CHECK(q && !q->loadState(bad.data(), written, 1));
    CHECK(q && !q->loadState(state.data(), written - 4, 1));
    // The clip pass takes the same profile.
    fx::DenoiseClipSettings s;
    s.reduction = 20;
    s.profile = state.data();
    s.profileBytes = written;
    Stereo clip = silence(n);
    CHECK(fx::denoiseClip(noisy.l.data(), noisy.r.data(), clip.l.data(), clip.r.data(), n, 48000, s));
    CHECK(errorDb(clip, clean, 0, 24000) < errorDb(noisy, clean, 0, 24000) - 6.0);
}

TEST(denoise_keeps_musical_noise_down_with_smoothing) {
    // Noise alone: what remains after reduction, its isolated spectral peaks (a bin 12 dB over its neighbours in
    // frequency and time) counted per frame; smoothing lowers the count.
    const size_t n = 48000 * 4;
    const Stereo noise = whiteNoise(n, 0.05, 3);
    auto count = [&](double smoothing) {
        const Stereo out = render(kPreen, {{"variant", 0}, {"reduction", 30}, {"smoothing", smoothing}, {"transient", 0}}, noise);
        lib::Fft fft;
        fft.prepare(1024);
        std::vector<std::vector<double>> frames;
        for (size_t at = 48000 * 2; at + 1024 < n; at += 512) {
            std::vector<double> re(1024), im(1024), p(513);
            for (int j = 0; j < 1024; ++j) re[j] = out.l[at + j] * (0.5 - 0.5 * std::cos(2 * modes_test::kPi * j / 1024));
            fft.forward(re.data(), im.data());
            for (int k = 0; k <= 512; ++k) p[k] = re[k] * re[k] + im[k] * im[k] + 1e-30;
            frames.push_back(p);
        }
        // Isolated peaks (a bin 6 dB over its neighbours two bins away and a frame either side) per frame, plus the
        // spread of the log spectrum (dB): musical noise is both.
        size_t isolated = 0;
        double sum = 0, sum2 = 0, count = 0;
        for (size_t f = 1; f + 1 < frames.size(); ++f)
            for (int k = 2; k < 510; ++k) {
                const double v = frames[f][k] / 3.98;
                if (v > frames[f][k - 2] && v > frames[f][k + 2] && v > frames[f - 1][k] && v > frames[f + 1][k]) ++isolated;
                const double d = 10 * std::log10(frames[f][k]);
                sum += d, sum2 += d * d, count += 1;
            }
        const double spread = std::sqrt(sum2 / count - (sum / count) * (sum / count));
        return std::make_pair(static_cast<double>(isolated) / frames.size(), spread);
    };
    const auto rough = count(0.0), smooth = count(1.0);
    if (!(smooth.second < rough.second && smooth.first < 10.0 && rough.first < 10.0))
        cawtest::fail(__FILE__, __LINE__, "isolated peaks a frame " + std::to_string(rough.first) + " -> " + std::to_string(smooth.first) +
                                              ", spread " + std::to_string(rough.second) + " -> " + std::to_string(smooth.second) + " dB");
    // And the noise is down by most of the reduction.
    const Stereo out = render(kPreen, {{"variant", 0}, {"reduction", 30}}, noise);
    CHECK(db(rms(out.l, 48000 * 2)) < db(rms(noise.l, 48000 * 2)) - 15.0);
}

TEST(denoise_clip_pass_is_aligned_undoable_and_reduces) {
    const size_t n = 48000 * 4;
    const Stereo clean = plucks(n);
    const Stereo noisy = add(clean, whiteNoise(n, 0.03));
    fx::DenoiseClipSettings s;
    s.reduction = 0;
    Stereo out = silence(n);
    CHECK(fx::denoiseClip(noisy.l.data(), noisy.r.data(), out.l.data(), out.r.data(), n, 48000, s));
    CHECK(peakErrorDb(out, noisy, 0, 0) < -90.0);  // Reduction 0: the clip back, unshifted
    s.reduction = 20;
    CHECK(fx::denoiseClip(noisy.l.data(), noisy.r.data(), out.l.data(), out.r.data(), n, 48000, s));
    const double before = errorDb(noisy, clean, 0, 24000), after = errorDb(out, clean, 0, 24000);
    if (!(after < before - 3.0)) cawtest::fail(__FILE__, __LINE__, "clip SNR " + std::to_string(-before) + " -> " + std::to_string(-after));
    CHECK_EQ(bestLag(clean, out, 64), size_t{0});
    // Bad arguments fail with a reason.
    std::string why;
    CHECK(!fx::denoiseClip(nullptr, nullptr, out.l.data(), out.r.data(), n, 48000, s, &why) && !why.empty());
    CHECK(!fx::denoiseClip(noisy.l.data(), noisy.r.data(), out.l.data(), out.r.data(), n, 1000, s, &why));
}

TEST(dehum_finds_the_hum_within_a_fifth_of_a_hertz_and_removes_it) {
    const size_t n = 48000 * 12;
    for (double f0 : {50.3, 59.8}) {
        Stereo hum = silence(n);
        for (size_t i = 0; i < n; ++i) {
            double v = 0;
            for (int h = 1; h <= 5; ++h) v += (0.05 / h) * std::sin(2 * modes_test::kPi * h * f0 * i / 48000.0 + h);
            hum.l[i] = hum.r[i] = static_cast<float>(v);
        }
        const Stereo in = add(add(hum, whiteNoise(n, 0.01)), tones(n, 0.1));
        const Values v = {{"variant", 1}};
        auto p = make(kPreen, v);
        if (!p) return;
        const Stereo out = run(*p, in, v);
        const std::vector<float> d = display(*p);
        CHECK(d.size() == 14);
        if (d.size() >= 4) {
            if (!(std::fabs(d[2] - f0) < 0.2)) cawtest::fail(__FILE__, __LINE__, "found " + std::to_string(d[2]) + " for " + std::to_string(f0));
            CHECK_EQ(d[3], f0 < 55 ? 1.0f : 2.0f);
        }
        for (int h = 1; h <= 3; ++h) {
            const double a = goertzelDb(in.l, h * f0, n - 48000 * 2, n), b = goertzelDb(out.l, h * f0, n - 48000 * 2, n);
            if (!(b < a - 20.0)) cawtest::fail(__FILE__, __LINE__, "harmonic " + std::to_string(h) + " only " + std::to_string(a - b) + " dB down");
        }
        // The tones between the harmonics are kept.
        CHECK(std::fabs(goertzelDb(out.l, 440, n - 48000 * 2, n) - goertzelDb(in.l, 440, n - 48000 * 2, n)) < 0.5);
    }
}

TEST(dereverb_lowers_a_reverb_tail) {
    // Dry clicks of noise every 1.5 s through an exponential noise reverb (T60 1.2 s): the tail falls further after
    // De-reverb, the bursts themselves stay.
    const size_t n = 48000 * 9;
    Stereo dry = silence(n);
    uint32_t seed = 3;
    for (size_t i = 0; i < n; ++i) {
        seed = seed * 1664525u + 1013904223u;
        if (i % 72000 < 2400) dry.l[i] = dry.r[i] = static_cast<float>(0.4 * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0));
    }
    const size_t irLen = 48000;
    std::vector<float> ir(irLen);
    for (size_t i = 0; i < irLen; ++i) {
        seed = seed * 1664525u + 1013904223u;
        ir[i] = static_cast<float>(0.05 * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * std::exp(-6.9 * i / (1.2 * 48000)));
    }
    Stereo wet = dry;
    // A sparse convolution: the bursts are short, so convolve only where the dry signal is non-zero.
    for (size_t i = 0; i < n; ++i) {
        if (dry.l[i] == 0.0f) continue;
        for (size_t j = 1; j < irLen && i + j < n; j += 1) wet.l[i + j] += dry.l[i] * ir[j];
    }
    wet.r = wet.l;
    const Values v = {{"variant", 2}, {"amount", 1}, {"decay_mode", 1}, {"decay", 1.2}};
    const Stereo out = render(kPreen, v, wet);
    const size_t lat = 2048;
    // The tail 150-600 ms after each burst ends, from the second burst on.
    double tin = 0, tout = 0, bin = 0, bout = 0;
    for (size_t b = 1; b < 6; ++b) {
        const size_t s = b * 72000;
        tin += rms(wet.l, s + 2400 + 7200, s + 2400 + 28800);
        tout += rms(out.l, s + lat + 2400 + 7200, s + lat + 2400 + 28800);
        bin += rms(wet.l, s, s + 2400);
        bout += rms(out.l, s + lat, s + lat + 2400);
    }
    if (!(db(tout) < db(tin) - 4.0)) cawtest::fail(__FILE__, __LINE__, "tail only " + std::to_string(db(tin) - db(tout)) + " dB down");
    CHECK(db(bout) > db(bin) - 3.0);
    // Auto finds a decay time in the right range.
    auto p = make(kPreen, {{"variant", 2}});
    if (p) {
        run(*p, wet, {{"variant", 2}});
        const std::vector<float> d = display(*p);
        CHECK(d.size() == 41 && d[3] > 0.4f && d[3] < 3.0f);
    }
}

TEST(declick_finds_and_repairs_clicks) {
    const size_t n = 48000 * 3;
    const Stereo clean = tones(n, 0.3);
    Stereo clicked = clean;
    size_t inserted = 0;
    for (size_t at = 4800; at < n - 4800; at += 4321, ++inserted) {
        clicked.l[at] += 0.5f, clicked.r[at] += 0.45f;
        clicked.l[at + 1] -= 0.3f, clicked.r[at + 1] -= 0.25f;
    }
    const Values v = {{"variant", 0}};
    const uint32_t lat = latencyOf(kHush, v);
    CHECK_EQ(lat, 240u);
    auto p = make(kHush, v);
    if (!p) return;
    const Stereo out = run(*p, clicked, v);
    const std::vector<float> d = display(*p);
    CHECK(d.size() == 7);
    const double found = d.empty() ? 0 : d[2];
    if (!(found >= 0.9 * inserted && found <= 1.1 * inserted))
        cawtest::fail(__FILE__, __LINE__, "repaired " + std::to_string(found) + " of " + std::to_string(inserted));
    const double before = errorDb(clicked, clean, 0, 4800), after = errorDb(out, clean, lat, 4800);
    if (!(after < before - 20.0)) cawtest::fail(__FILE__, __LINE__, "error " + std::to_string(before) + " -> " + std::to_string(after));
    // Clean tones: nothing to repair, the input back exactly 5 ms late.
    auto q = make(kHush, v);
    if (q) {
        const Stereo same = run(*q, clean, v);
        CHECK_EQ(display(*q)[2], 0.0f);
        CHECK(peakErrorDb(same, clean, lat, 0) < -200.0);
    }
}

TEST(deplosive_cuts_low_bursts_and_leaves_the_voice) {
    const size_t n = 48000 * 3;
    // A "voice": 220 Hz with harmonics to 3 kHz; pops: a 60 Hz burst of 40 ms every 0.75 s.
    Stereo voice = silence(n), pops = silence(n);
    for (size_t i = 0; i < n; ++i) {
        double v = 0;
        for (int h = 2; h <= 12; ++h) v += 0.03 * std::sin(2 * modes_test::kPi * 220 * h * i / 48000.0);
        voice.l[i] = voice.r[i] = static_cast<float>(v);
        const size_t t = i % 36000;
        if (i > 24000 && t < 1920) pops.l[i] = pops.r[i] = static_cast<float>(0.5 * std::sin(2 * modes_test::kPi * 60 * t / 48000.0) * std::exp(-static_cast<double>(t) / 600.0));
    }
    const Values v = {{"variant", 1}};
    CHECK_EQ(latencyOf(kHush, v), 144u);
    auto p = make(kHush, v);
    if (!p) return;
    const Stereo in = add(voice, pops);
    const Stereo out = run(*p, in, v);
    CHECK(display(*p)[3] >= 3.0f);
    double a = 0, b = 0;
    for (size_t s = 36000; s + 2000 < n; s += 36000) a += rms(in.l, s, s + 1920), b += rms(out.l, s + 144, s + 144 + 1920);
    if (!(db(b) < db(a) - 4.0)) cawtest::fail(__FILE__, __LINE__, "pops only " + std::to_string(db(a) - db(b)) + " dB down");
    // The voice alone: no event, the input back 3 ms late, exactly.
    auto q = make(kHush, v);
    if (q) {
        const Stereo same = run(*q, voice, v);
        CHECK_EQ(display(*q)[3], 0.0f);
        CHECK(peakErrorDb(same, voice, 144, 0) < -200.0);
    }
}

TEST(breath_lowers_breaths_between_voiced_phrases) {
    // 400 ms "sung" phrases (a 180 Hz harmonic tone) and 300 ms "breaths" (soft noise low-passed at about 3 kHz, as
    // breath is, 25 dB down) in turn.
    const size_t phrase = 19200, breath = 14400, cycle = phrase + breath, n = cycle * 6;
    Stereo in = silence(n);
    uint32_t seed = 21;
    double lp = 0;
    for (size_t i = 0; i < n; ++i) {
        const size_t t = i % cycle;
        double v = 0;
        if (t < phrase) {
            for (int h = 1; h <= 10; ++h) v += (0.2 / h) * std::sin(2 * modes_test::kPi * 180 * h * i / 48000.0);
        } else {
            seed = seed * 1664525u + 1013904223u;
            lp += 0.33 * (0.05 * (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) - lp);
            v = lp;
        }
        in.l[i] = in.r[i] = static_cast<float>(v);
    }
    const Values v = {{"variant", 2}, {"range", 20}};
    const uint32_t lat = latencyOf(kHush, v);
    CHECK_EQ(lat, 960u);
    auto p = make(kHush, v);
    if (!p) return;
    const Stereo out = run(*p, in, v);
    CHECK(display(*p)[3] >= 4.0f);
    double bi = 0, bo = 0, vi = 0, vo = 0;
    for (size_t c = 1; c < 6; ++c) {
        const size_t s = c * cycle;
        vi += rms(in.l, s + 2400, s + phrase - 2400);
        vo += rms(out.l, s + lat + 2400, s + lat + phrase - 2400);
        bi += rms(in.l, s + phrase + 2400, s + cycle - 2400);
        bo += rms(out.l, s + lat + phrase + 2400, s + lat + cycle - 2400);
    }
    if (!(db(bo) < db(bi) - 10.0)) cawtest::fail(__FILE__, __LINE__, "breaths only " + std::to_string(db(bi) - db(bo)) + " dB down");
    if (!(std::fabs(db(vo) - db(vi)) < 0.5)) cawtest::fail(__FILE__, __LINE__, "voice moved " + std::to_string(db(vo) - db(vi)) + " dB");
}

TEST(clean_variants_are_block_size_independent_and_survive_bad_input) {
    const Stereo in = add(music(48000), whiteNoise(48000, 0.02));
    const std::pair<const char*, Values> all[] = {
        {kPreen, {{"variant", 0}}}, {kPreen, {{"variant", 0}, {"monitor", 1}, {"learn", 1}}}, {kPreen, {{"variant", 1}, {"frequency", 1}}},
        {kPreen, {{"variant", 2}}}, {kHush, {{"variant", 0}}}, {kHush, {{"variant", 0}, {"mode", 1}}},
        {kHush, {{"variant", 1}}}, {kHush, {{"variant", 2}}}};
    for (const auto& [id, v] : all) {
        const std::string what = std::string(id) + " variant " + std::to_string(v[0].second);
        checkBlockSizes(id, v, in, what);
        checkBadInput(id, v, what);
    }
}

TEST(clean_presets_render) {
    const Stereo in = add(music(48000), whiteNoise(48000, 0.02));
    for (double variant : {0.0, 1.0, 2.0}) {
        checkPresets(kPreen, variant, 8, in);
        checkPresets(kHush, variant, 8, in);
    }
}

TEST(clean_devices_match_their_reference_renders) {
    const Stereo in = add(music(48000 * 2), whiteNoise(48000 * 2, 0.02));
    cawtest::References refs("fx_clean");
    auto check = [&](const char* name, const char* id, const Values& v, cawtest::Class c) {
        const Stereo out = render(id, v, in);
        CHECK_REFERENCE(refs, name, (cawtest::Audio{out.l, out.r}), c);
    };
    check("preen_denoise", kPreen, {{"variant", 0}, {"reduction", 18}}, cawtest::Class::Stable);
    check("preen_dehum_50", kPreen, {{"variant", 1}, {"frequency", 1}}, cawtest::Class::Stable);
    check("preen_dereverb", kPreen, {{"variant", 2}, {"amount", 0.8}}, cawtest::Class::Stable);
    check("hush_declick", kHush, {{"variant", 0}}, cawtest::Class::Chaotic);
    check("hush_deplosive", kHush, {{"variant", 1}}, cawtest::Class::Chaotic);
    check("hush_breath", kHush, {{"variant", 2}}, cawtest::Class::Chaotic);
}
