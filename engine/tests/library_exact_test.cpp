// The Library kernels as components get them (strict floating point, caw_exact_tests): oscillators, fast maths, filters, envelopes, glide, drum voices.
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <vector>

#include "caw/library/delay.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/drums.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/oscillator.hpp"
#include "test.h"

using namespace caw;

TEST(library_oscillators_are_band_limited_seeded_and_morph_between_the_basic_shapes) {
    CHECK_NEAR(lib::noteHz(69), 440.0, 1e-9);
    CHECK_NEAR(lib::noteHz(57), 220.0, 1e-9);
    CHECK_NEAR(lib::wrap01(1.25), 0.25, 1e-12);
    CHECK_NEAR(lib::wrap01(-0.25), 0.75, 1e-12);
    // Far from the edge the waves are the naive shapes; at the edge the step is smoothed.
    CHECK_NEAR(lib::sawWave(0.5, 0.01), 0.0, 1e-12);
    CHECK_NEAR(lib::squareWave(0.25, 0.01), 1.0, 1e-12);
    CHECK_NEAR(lib::squareWave(0.75, 0.01), -1.0, 1e-12);
    CHECK(std::fabs(lib::sawWave(0.001, 0.01)) < 0.9);
    CHECK_NEAR(lib::triangleWave(0.25), 1.0, 1e-12);
    CHECK_NEAR(lib::morphWave(0.1, 0.01, 0.0), lib::sineWave(0.1), 1e-12);
    CHECK_NEAR(lib::morphWave(0.1, 0.01, 1.0 / 3.0), lib::triangleWave(0.1), 1e-12);
    CHECK_NEAR(lib::morphWave(0.3, 0.01, 2.0 / 3.0), lib::sawWave(0.3, 0.01), 1e-12);
    CHECK_NEAR(lib::morphWave(0.3, 0.01, 1.0), lib::squareWave(0.3, 0.01), 1e-12);
    CHECK_NEAR(lib::morphWave(0.3, 0.01, 0.5), 0.5 * (lib::triangleWave(0.3) + lib::sawWave(0.3, 0.01)), 1e-12);
    lib::Noise a(3), b(3), c(4);
    double sum = 0, lo = 1, hi = -1;
    bool differs = false;
    for (int i = 0; i < 10000; ++i) {
        const double x = a.next();
        CHECK_EQ(x, b.next());
        differs = differs || x != c.next();
        sum += x;
        lo = std::min(lo, x);
        hi = std::max(hi, x);
    }
    CHECK(differs);
    CHECK(lo >= -1.0 && hi < 1.0 && lo < -0.99 && hi > 0.99);
    CHECK(std::fabs(sum / 10000) < 0.03);
    a.reset();
    CHECK_EQ(a.next(), lib::Noise(3).next());
}

TEST(library_fast_maths_matches_the_exact_maths_within_a_billionth) {
    // detExp builds 2^k from its bits instead of calling ldexp: the same bits.
    auto ldexpExp = [](double x) {
        if (std::isnan(x)) return 0.0;
        if (x > 709.0) x = 709.0;
        if (x < -745.0) return 0.0;
        const double k = std::floor(x / 0.69314718055994530942 + 0.5);
        const double r = (x - k * 6.93147180369123816490e-01) - k * 1.90821492927058770002e-10;
        double p = 1.0 / 6227020800.0;
        for (double d : {479001600.0, 39916800.0, 3628800.0, 362880.0, 40320.0, 5040.0, 720.0, 120.0, 24.0, 6.0, 2.0, 1.0, 1.0})
            p = p * r + 1.0 / d;
        return std::ldexp(p, static_cast<int>(k));
    };
    uint32_t mismatches = 0;
    double worstExp = 0, worstTanh = 0, worstSin = 0, worstDrive = 0;
    lib::Saturator sat;
    sat.set(3.0);
    for (int i = -200000; i <= 200000; ++i) {
        const double x = i * 0.0037;  // -740 .. 740
        uint64_t a = 0, b = 0;
        const double e = detExp(x), r = ldexpExp(x);
        std::memcpy(&a, &e, 8);
        std::memcpy(&b, &r, 8);
        mismatches += a != b;
        if (x > -700 && x < 700) worstExp = std::max(worstExp, std::fabs(lib::fastExp(x) / e - 1.0));
        const double t = i * 0.0002;  // -40 .. 40
        worstTanh = std::max(worstTanh, std::fabs(lib::fastTanh(t) - detTanh(t)));
        worstSin = std::max(worstSin, std::fabs(lib::fastSinCycles(t) - detSin(kTwoPi * t)));
        worstDrive = std::max(worstDrive, std::fabs(sat.process(t * 0.05) - lib::drive(t * 0.05, 3.0)));
    }
    CHECK_EQ(mismatches, 0u);
    CHECK(worstExp < 1e-9);
    CHECK(worstTanh < 1e-9);
    CHECK(worstSin < 1e-9);
    CHECK(worstDrive < 1e-9);
    CHECK_EQ(lib::fastTanh(std::nan("")), 0.0);
    CHECK_EQ(lib::fastSinCycles(std::nan("")), 0.0);
    CHECK_EQ(lib::fastExp(-1000.0), 0.0);
    // wrap01's branch for 0..2 gives phase - floor(phase) exactly, a negative zero included.
    for (double x : {0.0, -0.0, 0.25, 0.999999999, 1.0, 1.5, 1.9999999, -0.25, 2.5, -3.75}) {
        const double got = lib::wrap01(x), want = x - std::floor(x);
        CHECK(std::memcmp(&got, &want, sizeof got) == 0);
    }
    CHECK(!std::signbit(lib::wrap01(-0.0)));
}

TEST(library_block_oscillators_follow_morph_wave) {
    // addMorphStack renders morphWave in float a block at a time: each shape and blend within float rounding,
    // its phase moved on as many steps.
    for (double shape : {0.0, 0.2, 1.0 / 3.0, 0.45, 2.0 / 3.0, 0.8, 1.0}) {
        for (double dt : {0.003, 0.0217, 0.11}) {
            double phase = 0.37, ref = 0.37;
            float l[64] = {}, r[64] = {};
            const float gl = 0.5f, gr = 1.0f;
            double worst = 0;
            for (int block = 0; block < 8; ++block) {
                for (float& v : l) v = 0.0f;
                for (float& v : r) v = 0.0f;
                lib::addMorphStack(l, r, 64, &phase, &dt, 1, shape, &gl, &gr);
                for (int i = 0; i < 64; ++i) {
                    const double want = lib::morphWave(ref, dt, shape);
                    ref = lib::wrap01(ref + dt);
                    // Within a step of the edge the float phase can fall either side: compare away from it.
                    const double fromEdge = std::min({ref, 1.0 - ref, std::fabs(ref - 0.5)});
                    if (fromEdge < 2.5 * dt) continue;
                    worst = std::max(worst, std::fabs(r[i] - want));
                    CHECK_NEAR(l[i], 0.5 * r[i], 1e-6);
                }
            }
            CHECK(worst < 2e-4);
            CHECK_NEAR(phase, ref, 1e-12);
        }
    }
    // Copies add up in order and a step out of range is skipped.
    double phases[2] = {0.0, 0.5}, dts[2] = {0.01, 0.7};
    const float gains[2] = {1.0f, 1.0f};
    float l[16] = {}, r[16] = {};
    lib::addMorphStack(l, r, 16, phases, dts, 2, 0.0, gains, gains);
    CHECK_NEAR(l[4], std::sin(kTwoPi * 0.04), 1e-6);
    CHECK_EQ(phases[1], 0.5);
}

TEST(library_envelope_skip_and_ladder_and_chorus_fast_paths_match) {
    // Adsr::skip(n) lands where n next() calls do, in every stage.
    lib::Adsr a, b;
    a.set(0.003, 0.05, 0.4, 0.1, 48000);
    b.set(0.003, 0.05, 0.4, 0.1, 48000);
    a.gateOn();
    b.gateOn();
    for (int block = 0; block < 400; ++block) {
        if (block == 300) {
            a.gateOff();
            b.gateOff();
        }
        const uint32_t n = 1 + static_cast<uint32_t>(block % 16);
        double last = 0;
        for (uint32_t i = 0; i < n; ++i) last = a.next();
        CHECK_NEAR(b.skip(n), last, 1e-9);
        CHECK_EQ(a.active(), b.active());
    }
    // A held note at sustain 0 settles at exactly 0 instead of decaying into denormal numbers.
    lib::Adsr held;
    held.set(0.001, 0.01, 0.0, 0.1, 48000);
    held.gateOn();
    for (int i = 0; i < 48000; ++i) held.next();
    CHECK_EQ(held.level(), 0.0);
    // The ladder's fast tanh: the same filter within a millionth.
    lib::Ladder exact, fast;
    exact.set(800, 0.9, 48000);
    fast.set(800, 0.9, 48000);
    double worst = 0;
    for (int i = 0; i < 48000; ++i) {
        const double x = lib::sawWave(lib::wrap01(i * 0.00271), 0.00271);
        worst = std::max(worst, std::fabs(exact.process(x) - fast.processFast(x)));
    }
    CHECK(worst < 1e-6);
    // The chorus at the control rate stays within a few thousandths of the per-sample sweep on a test tone.
    lib::Chorus perSample, controlled;
    perSample.prepare(48000);
    controlled.prepare(48000);
    double diff = 0, level = 0;
    for (int i = 0; i < 48000; ++i) {
        if (i % 16 == 0) controlled.control(2.0, 1.0, 16);
        const float x = static_cast<float>(std::sin(kTwoPi * 440.0 * i / 48000.0));
        float l1 = x, r1 = x, l2 = x, r2 = x;
        perSample.process(2.0, 1.0, 1.0, l1, r1);
        controlled.step(1.0, l2, r2);
        diff = std::max(diff, static_cast<double>(std::max(std::fabs(l1 - l2), std::fabs(r1 - r2))));
        level = std::max(level, static_cast<double>(std::fabs(l1)));
    }
    CHECK(level > 0.9);
    CHECK(diff < 0.005);
}

TEST(library_filters_pass_and_stop_what_they_should) {
    lib::Svf svf;
    svf.set(1000, 0.707, 48000);
    lib::OnePole one;
    one.set(1000, 48000);
    lib::Ladder ladder;
    ladder.set(1000, 0.0, 48000);
    double low = 0, high = 0, band = 0, pole = 0, lad = 0;
    for (int i = 0; i < 48000; ++i) {
        const lib::SvfOutput o = svf.process(0.5);
        low = o.low, high = o.high, band = o.band;
        pole = one.low(0.5);
        lad = ladder.process(0.1);
    }
    CHECK_NEAR(low, 0.5, 1e-6);  // DC passes the low-pass, not the high-pass or band-pass
    CHECK_NEAR(high, 0.0, 1e-6);
    CHECK_NEAR(band, 0.0, 1e-6);
    CHECK_NEAR(pole, 0.5, 1e-6);
    CHECK_NEAR(lad, std::tanh(0.1), 1e-3);  // no resonance: unity at DC after the soft clip
    // A tone two octaves above the cutoff: about -24 dB through the SVF, about -48 dB through the ladder.
    auto level = [](auto&& filter) {
        double peak = 0;
        for (int i = 0; i < 48000; ++i) {
            const double y = filter(0.1 * lib::sineWave(i * 4000.0 / 48000.0));
            if (i > 24000) peak = std::max(peak, std::fabs(y));
        }
        return peak / 0.1;
    };
    lib::Svf s2;
    s2.set(1000, 0.707, 48000);
    lib::Ladder l2;
    l2.set(1000, 0.0, 48000);
    const double svfLevel = level([&](double x) { return s2.lowpass(x); });
    const double ladderLevel = level([&](double x) { return l2.process(x); });
    CHECK(svfLevel > 0.04 && svfLevel < 0.09);
    CHECK(ladderLevel > 0.001 && ladderLevel < 0.008);
    // Resonance peaks the ladder at its cutoff.
    lib::Ladder flat, peaked;
    flat.set(1000, 0.0, 48000);
    peaked.set(1000, 0.9, 48000);
    double a = 0, b = 0;
    for (int i = 0; i < 48000; ++i) {
        const double x = 0.05 * lib::sineWave(i * 1000.0 / 48000.0);
        const double fa = flat.process(x), fb = peaked.process(x);
        if (i > 24000) a = std::max(a, std::fabs(fa)), b = std::max(b, std::fabs(fb));
    }
    CHECK(b > 2.0 * a);
    CHECK_NEAR(lib::resonanceQ(0), 0.70710678, 1e-6);
    CHECK(lib::resonanceQ(1) > 19 && lib::resonanceQ(1) < 21);
    CHECK_NEAR(lib::shiftCutoff(1000, 1, 48000), 2000, 1e-6);
    CHECK_NEAR(lib::shiftCutoff(1000, 10, 48000), 0.45 * 48000, 1e-9);
    CHECK_NEAR(lib::shiftCutoff(1000, -10, 48000), 10, 1e-9);
}

TEST(library_envelopes_and_glides_keep_their_times) {
    lib::AdEnvelope ad;
    ad.set(0.001, 0.1, 48000);
    ad.trigger();
    double peakAt = -1;
    for (int i = 0; i < 48; ++i)
        if (ad.next() >= 1.0 && peakAt < 0) peakAt = i;
    CHECK_NEAR(peakAt, 47, 1);  // a 1 ms attack
    for (int i = 0; i < 4800; ++i) ad.next();
    CHECK_NEAR(ad.level(), 0.001, 1e-4);  // -60 dB 100 ms later
    for (int i = 0; i < 48000 && ad.active(); ++i) ad.next();
    CHECK(!ad.active());
    CHECK_EQ(ad.level(), 0.0);
    lib::Adsr env;
    env.set(0.001, 0.05, 0.4, 0.2, 48000);
    env.gateOn();
    for (int i = 0; i < 24000; ++i) env.next();
    CHECK_NEAR(env.level(), 0.4, 1e-6);  // holds at the sustain
    CHECK(!env.releasing());
    env.gateOff();
    CHECK(env.releasing());
    for (int i = 0; i < 9600; ++i) env.next();
    CHECK_NEAR(env.level(), 0.0004, 1e-4);  // -60 dB after the 200 ms release
    for (int i = 0; i < 48000 && env.active(); ++i) env.next();
    CHECK(!env.active());
    lib::Glide g;
    g.jump(40);
    CHECK_EQ(g.next(), 40.0);
    g.glideTo(52, 0.1, 1000);  // 100 steps
    for (int i = 0; i < 100; ++i) g.next();
    CHECK_NEAR(g.value(), 52, 0.15);  // 99 % of the way
    CHECK(g.value() < 52);
    g.glideTo(30, 0, 1000);
    CHECK_EQ(g.next(), 30.0);
}

TEST(library_drum_voices_ring_for_their_decay_then_stop_and_a_choke_cuts_them) {
    lib::KickVoice kick;
    kick.set(lib::KickSettings{}, 48000);
    kick.trigger(1.0);
    double peak = 0;
    int length = 0;
    for (; length < 48000 * 3 && kick.active(); ++length) peak = std::max(peak, std::fabs(kick.next()));
    CHECK(peak > 0.5 && peak <= 1.0);
    CHECK(length > 0.65 * 48000 && length < 0.75 * 48000);  // it stops at -120 dB: twice the 0.35 s decay (to -60 dB)
    CHECK_EQ(kick.next(), 0.0);
    lib::HatVoice hat;
    lib::HatSettings open;
    open.decay = 0.3;
    hat.set(open, 48000);
    hat.trigger(1.0);
    for (int i = 0; i < 480; ++i) hat.next();
    hat.choke();
    int rest = 0;
    for (; rest < 48000 && hat.active(); ++rest) hat.next();
    CHECK(rest < 48 * 50);  // the choke ends it within 50 ms instead of the 0.3 s decay
    lib::SnareVoice snare;
    snare.set(lib::SnareSettings{}, 48000);
    snare.trigger(0.5);
    lib::ClapVoice clap;
    clap.set(lib::ClapSettings{}, 48000);
    clap.trigger(1.0);
    double s = 0, c = 0;
    for (int i = 0; i < 48000; ++i) {
        s = std::max(s, std::fabs(snare.next()));
        c = std::max(c, std::fabs(clap.next()));
    }
    CHECK(s > 0.05 && s < 1.0);
    CHECK(c > 0.05 && c < 2.0);
    CHECK(!snare.active());
    CHECK(!clap.active());
}
