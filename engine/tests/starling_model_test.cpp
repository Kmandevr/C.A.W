// Starling's piano model (Timber's Simulated piano, ported from its 1.1.2 tests in 1.1.3): the hammer tables' physics, inharmonicity, the pedal and held keys, quiet to zeros and bad values.
#include <cmath>
#include <cstdio>
#include <string>
#include <utility>
#include <vector>

#include "starling_piano.h"
#include "test.h"
#include "timber_harness.h"
#include "timber_piano_curves.h"
#include "timber_piano_sim.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr const char* kStarling = "org.caw.starling";
double hzOfKey(double key) { return 440.0 * std::pow(2.0, (key - 69.0) / 12.0); }

// The piano with nothing in the way of a measurement: no room, the default otherwise.
Values model(Values v) {
    Values base = {{"variant", 0}, {"space", 0}};
    for (auto& x : v) base.push_back(x);
    return base;
}
starling::PianoModel& modelOf(ModuleProcessor& p) {
    return static_cast<timber::Instrument<starling::PianoModel>&>(p).model();
}
// The model alone: Starling's recordings muted, so what is measured is the shared piano model.
std::unique_ptr<ModuleProcessor> makeModel(const Values& v) {
    auto p = makeInstrument(kStarling, v);
    if (p) modelOf(*p).testMuteRecordings = true;
    return p;
}

// The power of x[from, from + n) at hz (Hann window), with the complex exponential by rotation (no trig per sample).
double powerAt(const std::vector<float>& x, double hz, size_t from, size_t n, double sr) {
    const double w = 2 * timber_test::kPi * hz / sr, cw = std::cos(w), sw = std::sin(w);
    const double wh = 2 * timber_test::kPi / (n - 1), ch = std::cos(wh), sh = std::sin(wh);
    double er = 1, ei = 0, hr = 1, hi = 0, re = 0, im = 0, ws = 0;
    for (size_t i = 0; i < n && from + i < x.size(); ++i) {
        const double win = 0.5 - 0.5 * hr;
        re += win * x[from + i] * er, im -= win * x[from + i] * ei, ws += win;
        const double nr = er * cw - ei * sw, ni = er * sw + ei * cw;
        er = nr, ei = ni;
        const double mr = hr * ch - hi * sh, mi = hr * sh + hi * ch;
        hr = mr, hi = mi;
    }
    return (re * re + im * im) / (ws * ws + 1e-30);
}
double peakNear(const std::vector<float>& x, double hz, double cents, size_t from, size_t n, double sr) {
    double best = hz, bp = -1;
    for (double c = -cents; c <= cents; c += cents / 20) {
        const double f = hz * std::pow(2.0, c / 1200), q = powerAt(x, f, from, n, sr);
        if (q > bp) bp = q, best = f;
    }
    double lo = best * std::pow(2.0, -cents / 20 / 1200), hi = best * std::pow(2.0, cents / 20 / 1200);
    for (int it = 0; it < 24; ++it) {
        const double a = hi - (hi - lo) * 0.618, b = lo + (hi - lo) * 0.618;
        if (powerAt(x, a, from, n, sr) > powerAt(x, b, from, n, sr)) hi = b;
        else lo = a;
    }
    return 0.5 * (lo + hi);
}

}  // namespace

TEST(starling_model_hammer_contact_shortens_up_the_keyboard_and_with_speed) {
    namespace pc = timber::piano_curves;
    // [Fact, Russell, "The piano hammer as a nonlinear spring", and the KTH lecture pages, read 2026-11-20] the
    // contact time falls from bass to treble (the hammer mass falls) and with a harder strike; the force rises.
    auto mean = [](int z0, int z1, int l) {
        double s = 0;
        for (int z = z0; z <= z1; ++z) s += timber::psim::hammer(z, l).contactMs;
        return s / (z1 - z0 + 1);
    };
    for (int l = 0; l < pc::kLayers; ++l) {
        const double bass = mean(0, 6, l), mid = mean(8, 13, l), top = mean(16, 21, l);
        if (verbose()) std::printf("speed %.1f m/s: contact %.2f / %.2f / %.2f ms\n", pc::kLayerSpeed[l], bass, mid, top);
        CHECK(bass > mid && mid > top);
        if (l > 0) CHECK(mean(0, 21, l) < mean(0, 21, l - 1));
    }
    for (int z = 0; z < pc::kZones; ++z) {
        CHECK(timber::psim::hammer(z, pc::kLayers - 1).contactMs < timber::psim::hammer(z, 0).contactMs);
        for (int l = 1; l < pc::kLayers; ++l) CHECK(timber::psim::hammer(z, l).peak > timber::psim::hammer(z, l - 1).peak);
        // Each pulse starts at rest and ends at rest: no window cuts it (the Casio reading, docs/decisions.md).
        const int16_t* p = timber::psim::hammer(z, 2).pulse;
        CHECK(p[0] >= 0 && p[pc::kPulseFrames - 1] == 0);
    }
}

TEST(starling_model_inharmonicity_follows_the_fitted_curve) {
    // Every A and D# from A0 to A6: B from partials 2..15 (least squares) within 10 % of the curve the loop was
    // designed from (and that curve fits the Salamander Grand's partials, timber_piano_curves.h).
    const double sr = 48000;
    for (double key = 21; key <= 93; key += 3) {
        if (static_cast<int>(key) % 12 != 9 && static_cast<int>(key) % 12 != 3) continue;
        const Values v = model({{"unison", 0}, {"glide", 0}, {"sympathy", 0}, {"noise", 0}, {"body", 0}, {"stretch", 0}});
        auto p = makeModel(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, key, 0.7}}, 0.7).mono();
        const double B = timber::piano_curves::inharmonicity(key);
        const double f0 = hzOfKey(key), n0 = 24000, at = 4800;
        const double f1 = peakNear(m, f0 * std::sqrt(1 + B), 30, at, n0, sr);
        std::vector<std::pair<int, double>> parts;
        for (int n = 2; n <= 15; ++n) {
            const double want = n * f1 * std::sqrt((1 + B * n * n) / (1 + B));
            if (want > 0.4 * sr) break;
            parts.push_back({n, peakNear(m, want, 15, at, n0, sr)});
        }
        double best = 0, bestErr = 1e30;
        for (int i = 0; i < 4000; ++i) {
            const double b = std::exp(std::log(1e-6) + (std::log(5e-2) - std::log(1e-6)) * i / 3999.0);
            double e = 0;
            for (const auto& [n, f] : parts) {
                const double r = f / (n * f1 * std::sqrt((1 + b * n * n) / (1 + b))) - 1;
                e += r * r;
            }
            if (e < bestErr) bestErr = e, best = b;
        }
        if (verbose()) std::printf("key %.0f: B %.3e against %.3e (%zu partials)\n", key, best, B, parts.size());
        if (parts.size() >= 3) CHECK(std::fabs(best / B - 1) < 0.10);
    }
}

TEST(starling_model_pedal_noise_never_reaches_the_resonance_and_the_pedal_lengthens_the_decay) {
    const std::vector<Note> notes = {{0.0, 0.3, 48, 0.8}, {0.05, 0.35, 55, 0.7}, {0.6, 0.9, 62, 0.6}};
    const std::vector<Cc> ccs = {{0.2, 64, 1.0}, {0.8, 64, 0.0}, {1.0, 64, 1.0}};
    double res[2];
    for (int k = 0; k < 2; ++k) {
        const Values v = model({{"noise", k == 0 ? 0.0 : 1.0}, {"resonance", 0.8}});
        auto p = makeModel(v);
        play(*p, v, notes, 1.5, 48000, 64, ccs);
        res[k] = modelOf(*p).resInputEnergy;
    }
    CHECK(res[0] > 0 && res[0] == res[1]);  // bit-identical input with and without the pedal's noise
    // [Fact, Schutz et al., AES 2008, abstract read 2026-11-20] the sustain pedal lengthens the decay.
    double tail[2];
    for (int k = 0; k < 2; ++k) {
        const Values v = model({{"sustain", k == 0 ? 0.0 : 1.0}});
        auto p = makeModel(v);
        tail[k] = rmsDb(play(*p, v, {{0.0, 0.3, 55, 0.8}}, 2.0).mono(), 48000, 48000);
    }
    CHECK(tail[1] > tail[0] + 20);
}

TEST(starling_model_held_key_rings_at_the_struck_keys_partials) {
    // C3 held down silently (too slow to throw its hammer); C4 struck and released: C3's strings go on at C4's
    // fundamental (C3's 2nd partial), with `sympathy` and not without.
    double at[2];
    for (int k = 0; k < 2; ++k) {
        const Values v = model({{"sympathy", k == 0 ? 0.0 : 1.0}, {"velocity", 1}, {"noise", 0}, {"body", 0}});
        auto p = makeModel(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, 48, 0.01}, {0.02, 0.3, 60, 0.9}}, 1.2).mono();
        const double f = hzOfKey(60) * std::sqrt(1 + timber::piano_curves::inharmonicity(48) * 4);
        at[k] = 10 * std::log10(powerAt(m, f, 33600, 19200, 48000) + 1e-30);
    }
    if (verbose()) std::printf("after C4's release, at C4: %.1f dB without, %.1f with\n", at[0], at[1]);
    CHECK(at[1] > at[0] + 20);
}

TEST(starling_model_falls_quiet_to_exact_zeros_and_survives_bad_values) {
    const Values v = model({{"space", 0.5}, {"release", 0.1}, {"noise", 1}, {"sustain", 0.0}});
    auto p = makeInstrument(kStarling, v);
    double quietAt = -1;
    const Stereo s = play(*p, v, {{0.0, 0.2, 60, 1.0}, {0.05, 0.25, 30, 1.0}}, 45.0, 48000, 64, {{0.1, 64, 1}, {0.15, 64, 0}}, &quietAt);
    if (verbose()) std::printf("quiet at %.2f s\n", quietAt);
    CHECK(quietAt > 0 && quietAt < 44);
    bool zeros = true;
    for (size_t i = static_cast<size_t>(44.0 * 48000); i < s.size(); ++i) zeros = zeros && s.l[i] == 0.0f && s.r[i] == 0.0f;
    CHECK(zeros);
    for (double bad : {double(NAN), double(INFINITY), -1e300}) {
        const Values b = model({{"tier", bad}, {"noise", bad}, {"touch", bad}, {"action", bad}, {"glide", bad}, {"sympathy", bad},
                                {"phantom", bad}, {"hammer", bad}, {"body", bad}});
        auto q = makeInstrument(kStarling, b);
        const Stereo o = play(*q, b, {{0.0, 0.1, 127.9, 1.0}, {0.0, 0.1, 0.0, 1.0}, {0.01, 0.2, 21, 1.0}}, 0.4);
        bool finite = true;
        for (size_t i = 0; i < o.size(); ++i) finite = finite && std::isfinite(o.l[i]) && std::isfinite(o.r[i]);
        CHECK(finite);
    }
    // Many held keys, the pedal down and full sympathy for 6 s: the held strings feeding each other stay stable.
    const Values h = model({{"sympathy", 1}, {"sustain", 1}, {"resonance", 1}});
    auto q = makeModel(h);
    std::vector<Note> chord;
    for (int k = 0; k < 16; ++k) chord.push_back({0.01 * k, -1, 36.0 + 3 * k, 0.9});
    const std::vector<float> m = play(*q, h, chord, 6.0).mono();
    if (verbose()) std::printf("16 held keys, pedal down: %.1f dB in the first second, %.1f dB at 5-6 s\n", rmsDb(m, 0, 48000), rmsDb(m, 5 * 48000, 48000));
    CHECK(rmsDb(m, 5 * 48000, 48000) < rmsDb(m, 0, 48000) - 6);
}
