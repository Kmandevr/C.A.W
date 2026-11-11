// Library kernel tests: smoothers, the LFO, the band-limited wavetable and the FDN reverb (caw/library/).
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

#include "caw/library/delay.hpp"
#include "caw/library/lfo.hpp"
#include "caw/library/oscillator.hpp"
#include "caw/library/reverb.hpp"
#include "caw/library/smoothing.hpp"
#include "caw/library/wavetable.hpp"
#include "test.h"

using namespace caw;

namespace {

// Power at each DFT bin 0..n/2 of x (a direct DFT: slow, but this is a test).
std::vector<double> powerSpectrum(const std::vector<double>& x) {
    const size_t n = x.size();
    std::vector<double> p(n / 2 + 1, 0.0);
    for (size_t k = 0; k <= n / 2; ++k) {
        double re = 0.0, im = 0.0;
        for (size_t i = 0; i < n; ++i) {
            const double a = kTwoPi * static_cast<double>((k * i) % n) / static_cast<double>(n);
            re += x[i] * std::cos(a);
            im -= x[i] * std::sin(a);
        }
        p[k] = re * re + im * im;
    }
    return p;
}

// The share of the power (in dB) that is not at a multiple of `harmonicBin` (excluding DC).
double inharmonicDb(const std::vector<double>& p, size_t harmonicBin) {
    double good = 0.0, bad = 0.0;
    for (size_t k = 1; k < p.size(); ++k) (k % harmonicBin == 0 ? good : bad) += p[k];
    return 10.0 * std::log10(bad / (good + bad) + 1e-300);
}

}  // namespace

// --- smoothing.hpp ---

TEST(library_one_pole_smoother_covers_99_percent_in_its_time_and_lands_exactly) {
    lib::OnePoleSmoother s;
    s.setTime(0.01, 48000.0);  // 480 samples
    s.snap(0.0);
    s.setTarget(1.0);
    for (int i = 0; i < 479; ++i) s.next();
    CHECK_NEAR(s.next(), 0.99, 1e-3);
    for (int i = 0; i < 48000; ++i) s.next();
    CHECK_EQ(s.value(), 1.0);  // landed, not creeping
    CHECK(!s.smoothing());
    s.setTime(0.0, 48000.0);
    s.setTarget(-2.0);
    CHECK_EQ(s.next(), -2.0);  // no time: a jump
    s.setTarget(std::nan(""));
    CHECK_EQ(s.next(), 0.0);  // NaN reads as 0
}

TEST(library_linear_smoother_reaches_the_target_in_exactly_its_frames) {
    lib::LinearSmoother s;
    s.setTime(0.001, 48000.0);  // 48 samples
    s.snap(0.0);
    s.setTarget(1.0);
    float out[64];
    s.process(out, 64);
    CHECK_NEAR(out[23], 0.5, 1e-9);
    CHECK(out[46] < 1.0f);
    CHECK_EQ(out[47], 1.0f);
    CHECK_EQ(out[63], 1.0f);
    CHECK(!s.smoothing());
    s.setTarget(0.0);  // restart from where it is
    CHECK_NEAR(s.next(), 1.0 - 1.0 / 48.0, 1e-12);
}

// --- lfo.hpp ---

TEST(library_lfo_runs_at_its_rate_in_hz_and_tempo_synced) {
    lib::Lfo lfo;
    lfo.prepare(48000.0);
    lfo.setRateHz(2.0);
    int rising = 0;
    double prev = lfo.next();
    for (int i = 1; i < 480000 + 100; ++i) {  // 10 s and a bit
        const double v = lfo.next();
        if (prev < 0.0 && v >= 0.0) ++rising;
        prev = v;
    }
    CHECK_EQ(rising, 20);
    lfo.retrigger();
    lfo.block(480000);  // one jump of 10 s
    CHECK_NEAR(lfo.cycle() + lfo.phase(), 20.0, 1e-9);

    lfo.setRateBeats(1.0, 120.0);  // a quarter note at 120 BPM: 2 Hz
    CHECK_NEAR(lfo.rateHz(), 2.0, 1e-12);
    lfo.setRateBeats(4.0, 120.0);  // a bar
    CHECK_NEAR(lfo.rateHz(), 0.5, 1e-12);
    lfo.setRateBeats(0.0, 120.0);
    CHECK_EQ(lfo.rateHz(), 0.0);
    lfo.setRateHz(1e9);  // held to a quarter of the rate
    CHECK_NEAR(lfo.rateHz(), 12000.0, 1e-9);
}

TEST(library_lfo_shapes_start_where_documented_and_stay_in_range) {
    const lib::LfoShape shapes[] = {lib::LfoShape::Sine,       lib::LfoShape::Triangle,  lib::LfoShape::SawUp,
                                    lib::LfoShape::SawDown,    lib::LfoShape::Square,    lib::LfoShape::SampleHold,
                                    lib::LfoShape::SmoothRandom};
    for (const lib::LfoShape shape : shapes) {
        for (int uni = 0; uni < 2; ++uni) {
            lib::Lfo lfo;
            lfo.prepare(48000.0);
            lfo.setShape(shape);
            lfo.setRateHz(3.7);
            lfo.setUnipolar(uni == 1);
            double lo = 1e9, hi = -1e9;
            for (int i = 0; i < 48000; ++i) {
                const double v = lfo.next();
                lo = v < lo ? v : lo;
                hi = v > hi ? v : hi;
            }
            CHECK(lo >= (uni ? 0.0 : -1.0));
            CHECK(hi <= 1.0);
            CHECK(hi - lo > 0.3);  // it moves
        }
    }
    lib::Lfo lfo;
    lfo.prepare(48000.0);
    lfo.setRateHz(1.0);
    CHECK_EQ(lfo.value(), 0.0);  // sine from 0
    lfo.setShape(lib::LfoShape::SawUp);
    CHECK_EQ(lfo.value(), -1.0);
    lfo.setShape(lib::LfoShape::SawDown);
    CHECK_EQ(lfo.value(), 1.0);
    lfo.setUnipolar(true);
    CHECK_EQ(lfo.value(), 1.0);
    lfo.setShape(lib::LfoShape::SawUp);
    CHECK_EQ(lfo.value(), 0.0);
    lfo.setUnipolar(false);
    lfo.setShape(lib::LfoShape::Sine);
    lfo.setPhaseOffset(0.25);  // a quarter cycle on: the sine's peak
    CHECK_NEAR(lfo.value(), 1.0, 1e-12);
    lfo.setShape(lib::LfoShape::Triangle);
    CHECK_NEAR(lfo.value(), 1.0, 1e-12);
    lfo.advance(24000);  // half a cycle later: the trough
    CHECK_NEAR(lfo.value(), -1.0, 1e-9);
    lfo.retrigger();  // back to the offset
    CHECK_NEAR(lfo.phase(), 0.25, 1e-12);

    // Square with a 25 % pulse: high for a quarter of the cycle.
    lib::Lfo sq;
    sq.prepare(48000.0);
    sq.setShape(lib::LfoShape::Square);
    sq.setPulseWidth(0.25);
    sq.setRateHz(10.0);
    int high = 0;
    for (int i = 0; i < 48000; ++i) high += sq.next() > 0.0 ? 1 : 0;
    CHECK_NEAR(high / 48000.0, 0.25, 1e-3);
}

TEST(library_lfo_random_shapes_are_seeded_held_per_cycle_and_smooth) {
    auto run = [](lib::LfoShape shape, uint32_t seed) {
        lib::Lfo lfo;
        lfo.prepare(48000.0);
        lfo.setShape(shape);
        lfo.setSeed(seed);
        lfo.setRateHz(10.0);  // 4800 samples per cycle
        std::vector<double> v(48000);
        for (double& x : v) x = lfo.next();
        return v;
    };
    const std::vector<double> sh = run(lib::LfoShape::SampleHold, 7);
    CHECK(sh == run(lib::LfoShape::SampleHold, 7));  // same seed, same values
    CHECK(sh != run(lib::LfoShape::SampleHold, 8));
    int changes = 0;
    for (size_t i = 1; i < sh.size(); ++i) changes += sh[i] != sh[i - 1] ? 1 : 0;
    CHECK(changes >= 8 && changes <= 10);  // a new value once per cycle (10 cycles, a step might repeat)
    CHECK_EQ(sh[100], sh[4700]);           // held within a cycle

    const std::vector<double> sm = run(lib::LfoShape::SmoothRandom, 7);
    double maxStep = 0.0;
    for (size_t i = 1; i < sm.size(); ++i) maxStep = std::fmax(maxStep, std::fabs(sm[i] - sm[i - 1]));
    CHECK(maxStep < 3.0 / 4800.0);  // smoothstep slope at most 1.5 x the 2-unit range per cycle
    CHECK_NEAR(sm[4800 * 3], sh[4800 * 3 + 10], 1e-3);  // passes through each cycle's held value

    // Locked to the transport: the cycle number comes from the beat position, so the random values do too.
    lib::Lfo a, b;
    a.prepare(48000.0);
    b.prepare(48000.0);
    a.setShape(lib::LfoShape::SampleHold);
    b.setShape(lib::LfoShape::SampleHold);
    a.setRateBeats(1.0, 120.0);
    b.setRateBeats(1.0, 120.0);
    b.advance(24000 * 5 + 12000);  // 5.5 beats of free running
    a.syncToBeat(5.5, 1.0);
    CHECK_EQ(a.cycle(), 5U);
    CHECK_NEAR(a.phase(), 0.5, 1e-12);
    CHECK_EQ(a.value(), b.value());
}

TEST(library_lfo_block_rate_matches_per_sample) {
    lib::Lfo perSample, perBlock;
    for (lib::Lfo* l : {&perSample, &perBlock}) {
        l->prepare(44100.0);
        l->setShape(lib::LfoShape::Triangle);
        l->setRateHz(5.3);
        l->setPhaseOffset(0.1);
    }
    for (int b = 0; b < 200; ++b) {
        double first = 0.0;
        for (int i = 0; i < 64; ++i) {
            const double v = perSample.next();
            if (i == 0) first = v;
        }
        CHECK_NEAR(perBlock.block(64), first, 1e-9);
    }
    CHECK_NEAR(perBlock.phase(), perSample.phase(), 1e-9);
}

// --- wavetable.hpp ---

TEST(library_wavetable_builds_frames_from_functions_and_harmonics_alike) {
    lib::Wavetable t;
    t.prepare(4, 2048);
    CHECK_EQ(t.frameSize(), 2048);
    CHECK_EQ(t.levels(), 11);  // 1024 harmonics down to 1
    CHECK(t.setFrameFunction(0, [](double p) { return std::sin(kTwoPi * p) + 0.5 * std::cos(kTwoPi * 3.0 * p); }));
    const double amps[] = {1.0, 0.0, 0.5};
    const double phases[] = {0.0, 0.0, 0.25};
    CHECK(t.setFrameHarmonics(1, amps, 3, phases));
    CHECK_EQ(t.frameCount(), 2);
    for (int level = 0; level < 9; ++level)  // levels that keep the 3rd harmonic
        for (int i = 0; i < 97; ++i) {
            const double p = i / 97.0;
            const double want = std::sin(kTwoPi * p) + 0.5 * std::cos(kTwoPi * 3.0 * p);
            // Linear interpolation's error bound, max|f''| / (8 M^2), plus float rounding.
            const double m = t.levelSize(level);
            const double tol = kTwoPi * kTwoPi * (1.0 + 0.5 * 9.0) / (8.0 * m * m) + 1e-5;
            CHECK_NEAR(t.read(0, level, p), want, tol);
            CHECK_NEAR(t.read(1, level, p), want, tol);
        }
    CHECK(!t.setFrameHarmonics(4, amps, 3));  // out of range
    lib::Wavetable unprepared;
    CHECK(!unprepared.setFrameHarmonics(0, amps, 3));
}

TEST(library_wavetable_level_choice_keeps_every_harmonic_below_nyquist) {
    lib::Wavetable t;
    t.prepare(1, 2048);
    for (double dt = 1e-5; dt < 0.5; dt *= 1.01) {
        const int k = t.levelFor(dt);
        CHECK(k >= 0);
        CHECK(t.harmonicsAt(k) * dt <= 0.5);
        if (k > 0) CHECK(t.harmonicsAt(k - 1) * dt > 0.5);  // and keeps as many as it can
    }
    CHECK_EQ(t.levelFor(0.5), -1);
    lib::WavetableOscillator osc;
    osc.setTable(&t);
    t.setFrameFunction(0, [](double p) { return std::sin(kTwoPi * p); });
    osc.setFrequency(30000.0, 48000.0);  // above Nyquist: silence, not an alias
    CHECK_EQ(osc.next(), 0.0);
}

TEST(library_wavetable_saw_does_not_alias_where_a_naive_saw_does) {
    lib::Wavetable t;
    t.prepare(1, 2048);
    t.setFrameFunction(0, [](double p) { return 2.0 * p - 1.0; });  // the naive saw, band-limited per level
    // 4800 samples at 48 kHz give 10 Hz bins; f0 = 1230 Hz is bin 123, and every alias of a harmonic above
    // Nyquist lands off the multiples of 123.
    for (const double f0 : {1230.0, 5130.0}) {
        const size_t bin = static_cast<size_t>(f0 / 10.0);
        lib::WavetableOscillator osc;
        osc.setTable(&t);
        osc.setFrequency(f0, 48000.0);
        std::vector<double> band(4800), naive(4800);
        double ph = 0.0;
        for (size_t i = 0; i < band.size(); ++i) {
            band[i] = osc.next();
            naive[i] = 2.0 * ph - 1.0;
            ph += f0 / 48000.0;
            ph -= std::floor(ph);
        }
        const double bandDb = inharmonicDb(powerSpectrum(band), bin);
        const double naiveDb = inharmonicDb(powerSpectrum(naive), bin);
        CHECK(bandDb < -60.0);
        CHECK(naiveDb > -40.0);  // the test can see aliasing
        if (!(bandDb < -60.0)) cawtest::fail(__FILE__, __LINE__, "inharmonic dB " + cawtest::show(bandDb, naiveDb));
    }
}

TEST(library_wavetable_morph_interpolates_linearly_between_frames) {
    lib::Wavetable t;
    t.prepare(3, 2048);
    const double h1[] = {1.0}, h2[] = {0.0, 1.0}, h3[] = {0.0, 0.0, 1.0};
    t.setFrameHarmonics(0, h1, 1);
    t.setFrameHarmonics(1, h2, 2);
    t.setFrameHarmonics(2, h3, 3);
    CHECK_EQ(t.frameCount(), 3);
    struct Case {
        double position, w1, w2, w3;
    };
    for (const Case c : {Case{0.0, 1, 0, 0}, Case{0.25, 0.5, 0.5, 0}, Case{0.5, 0, 1, 0}, Case{0.9, 0, 0.2, 0.8},
                         Case{1.0, 0, 0, 1}, Case{-3.0, 1, 0, 0}, Case{7.0, 0, 0, 1}}) {
        lib::WavetableOscillator osc;
        osc.setTable(&t);
        osc.setFrequency(100.0, 48000.0);
        osc.setPosition(c.position);
        double ph = 0.0, worst = 0.0;
        for (int i = 0; i < 960; ++i) {
            const double want = c.w1 * std::sin(kTwoPi * ph) + c.w2 * std::sin(2 * kTwoPi * ph) + c.w3 * std::sin(3 * kTwoPi * ph);
            worst = std::fmax(worst, std::fabs(osc.next() - want));
            ph += 100.0 / 48000.0;
            ph -= std::floor(ph);
        }
        CHECK(worst < 1e-3);
    }
}

// --- reverb.hpp ---

namespace {

// RT60 from an impulse response by Schroeder backward integration: twice the time from -5 dB to -35 dB.
double measureRt60(const std::vector<double>& energy, double rate) {
    std::vector<double> edc(energy.size() + 1, 0.0);
    for (size_t i = energy.size(); i-- > 0;) edc[i] = edc[i + 1] + energy[i];
    const double total = edc[0];
    size_t t5 = 0, t35 = 0;
    for (size_t i = 0; i < energy.size(); ++i) {
        const double db = 10.0 * std::log10(edc[i] / total + 1e-300);
        if (t5 == 0 && db <= -5.0) t5 = i;
        if (t35 == 0 && db <= -35.0) {
            t35 = i;
            break;
        }
    }
    return 2.0 * static_cast<double>(t35 - t5) / rate;
}

std::vector<double> impulseEnergy(lib::Reverb& rv, size_t frames) {
    std::vector<double> e(frames);
    for (size_t i = 0; i < frames; ++i) {
        float l = i == 0 ? 1.0f : 0.0f, r = 0.0f;
        rv.process(l, r);
        e[i] = static_cast<double>(l) * l + static_cast<double>(r) * r;
    }
    return e;
}

}  // namespace

TEST(library_reverb_decays_in_its_rt60) {
    for (const double decay : {0.8, 2.5}) {
        for (const double size : {0.2, 0.9}) {
            lib::Reverb rv;
            rv.prepare(48000.0, 256);
            lib::ReverbSettings s;
            s.decay = decay;
            s.size = size;
            s.damping = 0.0;
            s.mix = 1.0;
            rv.set(s);
            const double rt = measureRt60(impulseEnergy(rv, static_cast<size_t>(48000 * decay * 2.5)), 48000.0);
            if (!(std::fabs(rt - decay) <= 0.05 * decay))
                cawtest::fail(__FILE__, __LINE__, "RT60 measured vs set: " + cawtest::show(rt, decay));
        }
    }
}

TEST(library_reverb_damping_shortens_the_highs_not_the_lows) {
    lib::Reverb bright, dark;
    lib::ReverbSettings s;
    s.mix = 1.0;
    s.decay = 1.5;
    s.damping = 0.0;
    bright.prepare(48000.0, 256);
    bright.set(s);
    s.damping = 0.8;
    dark.prepare(48000.0, 256);
    dark.set(s);
    const std::vector<double> eb = impulseEnergy(bright, 96000), ed = impulseEnergy(dark, 96000);
    double sb = 0.0, sd = 0.0;
    for (size_t i = 0; i < eb.size(); ++i) {
        sb += eb[i];
        sd += ed[i];
    }
    CHECK(sd < sb);  // damping removes energy
    CHECK(sd > 0.05 * sb);
}

TEST(library_reverb_stays_finite_bounded_and_denormal_free) {
    lib::Reverb rv;
    rv.prepare(48000.0, 512, 0.2);
    lib::ReverbSettings s;
    s.decay = 60.0;  // the longest tail
    s.size = 1.0;
    s.damping = 0.0;
    s.width = 2.0;
    s.mix = 1.0;
    rv.set(s);
    caw::lib::Noise noise(3);
    double peak = 0.0, sumSq = 0.0;
    const int frames = 48000 * 10;
    for (int i = 0; i < frames; ++i) {
        float l = static_cast<float>(noise.next()), r = static_cast<float>(noise.next());
        if (i % 9973 == 0) l = std::nanf("");
        if (i % 7919 == 0) r = INFINITY;
        rv.process(l, r);
        CHECK(std::isfinite(l) && std::isfinite(r));
        peak = std::fmax(peak, std::fmax(std::fabs(l), std::fabs(r)));
        sumSq += static_cast<double>(l) * l;
    }
    CHECK(peak < 100.0);
    CHECK(std::sqrt(sumSq / frames) < 20.0);

    // A short tail after an impulse ends in exact zeros, never in subnormals.
    lib::Reverb tail;
    tail.prepare(48000.0, 512);
    s.decay = 0.3;
    s.width = 1.0;
    tail.set(s);
    int subnormals = 0;
    float l = 1.0f, r = 1.0f;
    for (int i = 0; i < 48000 * 20; ++i) {
        tail.process(l, r);
        if (std::fpclassify(l) == FP_SUBNORMAL || std::fpclassify(r) == FP_SUBNORMAL) ++subnormals;
        l = r = 0.0f;
    }
    tail.process(l, r);
    CHECK_EQ(subnormals, 0);
    CHECK_EQ(l, 0.0f);
    CHECK_EQ(r, 0.0f);
    CHECK(tail.tailFrames() >= static_cast<uint64_t>(1.5 * 0.3 * 48000));
}

TEST(library_reverb_mix_width_pre_delay_and_determinism) {
    lib::ReverbSettings s;
    s.mix = 0.0;
    lib::Reverb dry;
    dry.prepare(44100.0, 128);
    dry.set(s);
    caw::lib::Noise noise(9);
    for (int i = 0; i < 4410; ++i) {  // mix 0 is the dry signal, bit for bit
        const float inL = static_cast<float>(noise.next()), inR = static_cast<float>(noise.next());
        float l = inL, r = inR;
        dry.process(l, r);
        CHECK_EQ(l, inL);
        CHECK_EQ(r, inR);
    }

    // Width 0: a mono tail. Width 1: left and right differ (a mono input gets a stereo tail).
    for (const double width : {0.0, 1.0}) {
        lib::Reverb rv;
        rv.prepare(48000.0, 128);
        s.mix = 1.0;
        s.width = width;
        rv.set(s);
        double diff = 0.0;
        for (int i = 0; i < 48000; ++i) {
            float l = i == 0 ? 1.0f : 0.0f, r = l;
            rv.process(l, r);
            diff += std::fabs(l - r);
        }
        if (width == 0.0) CHECK_EQ(diff, 0.0);
        else CHECK(diff > 0.1);
    }

    // Pre-delay: nothing comes out before it has passed.
    auto firstSound = [&](double preDelay) {
        lib::Reverb rv;
        rv.prepare(48000.0, 128, 0.5);
        s.width = 1.0;
        s.size = 0.0;
        s.preDelay = preDelay;
        rv.set(s);
        for (int i = 0; i < 48000; ++i) {
            float l = i == 0 ? 1.0f : 0.0f, r = l;
            rv.process(l, r);
            if (l != 0.0f || r != 0.0f) return i;
        }
        return -1;
    };
    const int direct = firstSound(0.0), delayed = firstSound(0.1);
    CHECK(direct > 0 && direct < 4800);
    CHECK_EQ(delayed, direct + 4800);
    CHECK_EQ(firstSound(9.0), direct + 24000);  // held to the prepared maximum

    // Determinism: two instances give the same bits; a block call matches frame by frame.
    lib::Reverb a, b;
    s = lib::ReverbSettings{};
    a.prepare(48000.0, 64);
    b.prepare(48000.0, 64);
    a.set(s);
    b.set(s);
    std::vector<float> bl(4096), br(4096);
    caw::lib::Noise n2(5);
    for (int i = 0; i < 4096; ++i) {
        bl[i] = static_cast<float>(n2.next());
        br[i] = static_cast<float>(n2.next());
    }
    std::vector<float> al = bl, ar = br;
    for (int i = 0; i < 4096; ++i) a.process(al[i], ar[i]);
    for (int off = 0; off < 4096; off += 64) b.process(bl.data() + off, br.data() + off, 64);
    CHECK(al == bl);
    CHECK(ar == br);
    a.clear();
    float l = 0.0f, r = 0.0f;
    a.process(l, r);
    CHECK_EQ(l, 0.0f);  // cleared: silent
}

// A centred (mono) sound must still bounce: full ping-pong sends the first echo left, the next right, and so on.
// Before this test the delay fed each side its own input, so identical left and right stayed identical (owner report).
TEST(library_ping_pong_bounces_a_centred_sound_between_the_sides) {
    caw::lib::PingPongDelay d;
    const double sr = 48000.0;
    d.prepare(sr, 1.0);
    const int delay = 4800;  // 0.1 s
    double eL[4] = {}, eR[4] = {};
    for (int i = 0; i < 4 * delay; ++i) {
        float l = i < 64 ? 1.0f : 0.0f, r = l;  // a short centred click
        d.process(0.1, 0.5, 1.0, 1.0, l, r);   // fully wet, full cross
        const int echo = i / delay - 1;          // which echo this frame belongs to
        if (echo >= 0 && echo < 4) { eL[echo] += double(l) * l; eR[echo] += double(r) * r; }
    }
    CHECK(eL[0] > 100.0 * eR[0]);  // first echo on the left
    CHECK(eR[1] > 100.0 * eL[1]);  // second on the right
    CHECK(eL[2] > 100.0 * eR[2]);  // and back
}

// Second audio review, fix 2: full cross fed the left line inL + inR, so a centred sound's first echo came back at
// twice its level (+6 dB over the dry sound). The left line now takes the mono average: the echo is at the dry level.
TEST(library_ping_pong_echoes_a_centred_sound_no_louder_than_it_came_in) {
    caw::lib::PingPongDelay d;
    d.prepare(1000.0, 1.0);
    float peak = 0.0f;
    for (int t = 0; t < 15; ++t) {
        float l = t == 0 ? 0.5f : 0.0f, r = l;  // a centred click at 0.5
        d.process(0.010, 0.0, 1.0, 1.0, l, r);   // no feedback, full cross, all wet
        if (t == 10) CHECK_NEAR(l, 0.5, 1e-6);   // the one echo, on the left, at the click's level
        peak = std::max({peak, std::fabs(l), std::fabs(r)});
    }
    CHECK(peak <= 0.5f + 1e-6f);
}

// cross 0 keeps two plain echoes: each side echoes its own input.
TEST(library_ping_pong_with_no_cross_echoes_each_side_in_place) {
    caw::lib::PingPongDelay d;
    d.prepare(48000.0, 1.0);
    double eL = 0, eR = 0;
    for (int i = 0; i < 9600; ++i) {
        float l = i < 64 ? 1.0f : 0.0f, r = 0.0f;
        d.process(0.1, 0.5, 0.0, 1.0, l, r);
        eL += double(l) * l; eR += double(r) * r;
    }
    CHECK(eL > 0.5);
    CHECK(eR == 0.0);
}

// --- .caw parity (#122): the Library ports render the same as the .caw built-ins they replace ---

#include "caw/library/glitch.hpp"
#include "caw/library/modulation.hpp"
#include "caw/library/music.hpp"
#include "compile.h"
#include "vm.h"

namespace {

// Runs a float-mode .caw body for `blocks` blocks (t = the sample number, time in seconds) and returns its raw
// output: the old path, for comparing a port with.
std::vector<double> renderCaw(const std::string& body, int blocks, uint32_t seed = 0, double bpm = 120,
                              double sr = 48000) {
    CompileResult r = compileModule("---\nmode: float\n---\n" + body);
    if (!r.program) {
        cawtest::fail(__FILE__, __LINE__, "compile failed: " + body + " -> " + r.error);
        return {};
    }
    Instance inst(r.program);
    std::vector<double> out;
    double tb[kBlock], time[kBlock], zero[kBlock] = {};
    BlockCtx c;
    c.sr = sr;
    c.bpm = bpm;
    c.seed = seed;
    for (int b = 0; b < blocks; ++b) {
        for (int i = 0; i < kBlock; ++i) {
            tb[i] = b * kBlock + i;
            time[i] = tb[i] / sr;
        }
        c.n = kBlock;
        for (int v = 0; v < static_cast<int>(Var::Count); ++v) c.vars[v] = zero;
        c.vars[static_cast<int>(Var::T)] = tb;
        c.vars[static_cast<int>(Var::Time)] = time;
        inst.process(c);
        out.insert(out.end(), inst.rawOutput(), inst.rawOutput() + kBlock);
    }
    return out;
}

// How many of the samples differ between the .caw render and the port (beyond `tol`).
template <class F>
int mismatches(const std::vector<double>& caw, F port, double tol = 0.0) {
    int bad = 0;
    for (size_t n = 0; n < caw.size(); ++n)
        if (!(std::fabs(caw[n] - port(static_cast<double>(n))) <= tol)) ++bad;
    return bad;
}

}  // namespace

TEST(library_music_scale_and_quantize_match_the_caw_builtins) {
    // Every scale, degrees -20..19 and roots 48..71, then notes 30..90 in steps of a quarter tone.
    const int blocks = 14 * 24 * 40 / kBlock + 1;
    std::vector<double> s = renderCaw("scale(t % 40 - 20, floor(t / 40) % 14, 48 + floor(t / 560) % 24)", blocks);
    CHECK_EQ(mismatches(s, [](double n) {
                 return lib::scaleNote(std::fmod(n, 40) - 20, static_cast<lib::Scale>(static_cast<int>(std::floor(n / 40)) % 14),
                                       48 + std::fmod(std::floor(n / 560), 24));
             }), 0);
    std::vector<double> q = renderCaw("quantize(30 + (t % 240) / 4, floor(t / 240) % 14, 50 + floor(t / 3360) % 12)", 160);
    CHECK_EQ(mismatches(q, [](double n) {
                 return lib::quantizeNote(30 + std::fmod(n, 240) / 4, static_cast<lib::Scale>(static_cast<int>(std::floor(n / 240)) % 14),
                                          50 + std::fmod(std::floor(n / 3360), 12));
             }), 0);
    CHECK_EQ(lib::scaleNote(0, lib::Scale::Minor, lib::keyRoot(9)), 69.0);  // the .caw default key: A4
    CHECK_EQ(lib::scaleNote(-1, lib::Scale::Minor, 69), 67.0);
    CHECK_EQ(lib::quantizeNote(61, lib::Scale::Major, 60), 60.0);  // a tie goes down
    CHECK_EQ(lib::scaleNote(std::nan(""), lib::Scale::Major, 60), 60.0);
}

TEST(library_music_chords_and_arpeggios_match_the_caw_builtins) {
    std::vector<double> c = renderCaw("chord(t % 12, floor(t / 12) % 30 - 10, 40 + floor(t / 360) % 30)", 180);
    CHECK_EQ(mismatches(c, [](double n) {
                 return lib::chordNote(static_cast<lib::Chord>(static_cast<int>(std::fmod(n, 12))), std::fmod(std::floor(n / 12), 30) - 10,
                                       40 + std::fmod(std::floor(n / 360), 30));
             }), 0);
    // Every chord, mode and octave count over 40 steps, with a project seed (the random mode follows it).
    for (uint32_t seed : {0u, 77u}) {
        std::vector<double> a = renderCaw("arp(t % 12, floor(t / 12) % 40, floor(t / 480) % 4, 57, 1 + floor(t / 1920) % 4)", 121, seed);
        CHECK_EQ(mismatches(a, [seed](double n) {
                     return lib::arpNote(static_cast<lib::Chord>(static_cast<int>(std::fmod(n, 12))), std::fmod(std::floor(n / 12), 40),
                                         static_cast<lib::ArpMode>(static_cast<int>(std::fmod(std::floor(n / 480), 4))), 57,
                                         1 + static_cast<int>(std::fmod(std::floor(n / 1920), 4)), seed);
                 }), 0);
    }
    CHECK_EQ(lib::chordNote(lib::Chord::Maj, 3, 60), 72.0);
    CHECK_EQ(lib::arpNote(lib::Chord::Maj, 3, lib::ArpMode::UpDown, 60), 64.0);  // 60 64 67 64, then again
}

TEST(library_music_euclid_and_seeded_choices_match_the_caw_builtins) {
    std::vector<double> e = renderCaw("euclid(t % 18, 1 + floor(t / 18) % 17, floor(t / 306) % 40 - 8, floor(t / 12240) % 3)", 575);
    CHECK_EQ(mismatches(e, [](double n) {
                 return lib::euclid(std::fmod(n, 18), 1 + std::fmod(std::floor(n / 18), 17), std::fmod(std::floor(n / 306), 40) - 8,
                                    std::fmod(std::floor(n / 12240), 3)) ? 1.0 : 0.0;
             }), 0);
    std::string hits;
    for (int s = 0; s < 16; ++s) hits += lib::euclid(5, 16, s) ? 'x' : '.';
    CHECK_EQ(hits, std::string("x...x..x..x..x.."));
    for (uint32_t seed : {0u, 9u}) {
        CHECK_EQ(mismatches(renderCaw("rand(t)", 8, seed), [seed](double n) { return lib::randomUnit(n, seed); }), 0);
        CHECK_EQ(mismatches(renderCaw("randi(t, 1 + t % 9)", 8, seed),
                            [seed](double n) { return static_cast<double>(lib::randomIndex(n, 1 + std::fmod(n, 9), seed)); }), 0);
        CHECK_EQ(mismatches(renderCaw("chance(t, (t % 10) / 10)", 8, seed),
                            [seed](double n) { return lib::chance(n, std::fmod(n, 10) / 10, seed) ? 1.0 : 0.0; }), 0);
    }
}

TEST(library_curve_lfo_and_tremolo_match_the_caw_builtins) {
    // Four even points is lfo.curve: a two-beat cycle at 120 BPM (1 s), started a tenth in.
    const double pts[4] = {0.0, 1.0, -0.5, -1.0};
    lib::CurveShape curve;
    curve.setEven(pts, 4);
    std::vector<double> c = renderCaw("lfo.curve(2, 0.1, 0, 1, -0.5, -1)", 1600);
    CHECK_EQ(mismatches(c, [&](double n) { return curve.valueAt(lib::beatPhase(n / 48000.0, 120, 2, 0.1)); }, 1e-12), 0);
    CHECK_NEAR(curve.valueAt(0.125), 0.5, 1e-12);
    CHECK_NEAR(curve.valueAt(0.875), -0.5, 1e-12);  // the last point runs back to the first
    // Points at their own places: a ramp up over the first 10 %, then down to the end.
    const double xs[2] = {0.0, 0.1}, ys[2] = {-1.0, 1.0};
    curve.setPoints(xs, ys, 2);
    CHECK_NEAR(curve.valueAt(0.05), 0.0, 1e-12);
    CHECK_NEAR(curve.valueAt(0.55), 0.0, 1e-12);
    CHECK_EQ(curve.valueAt(std::nan("")), -1.0);
    // util.trem: a quarter-beat sine tremolo at depth 0.8 on a ramp.
    std::vector<double> t = renderCaw("util.trem((t % 100) / 100, 0.25, 0.8)", 200);
    CHECK_EQ(mismatches(t, [](double n) {
                 const double p = lib::beatPhase(n / 48000.0, 120, 0.25);
                 return std::fmod(n, 100) / 100 * lib::tremoloGain(detSin(kTwoPi * (p - std::floor(p))), 0.8);
             }, 1e-12), 0);
}

TEST(library_glitch_kernels_match_the_caw_builtins) {
    lib::SampleHold hold;
    std::vector<double> h = renderCaw("glitch.hold(t % 977, 1234 + (t % 3000))", 100);
    CHECK_EQ(mismatches(h, [&](double n) { return hold.process(std::fmod(n, 977), 1234 + std::fmod(n, 3000), 48000); }), 0);
    std::vector<double> m = renderCaw("glitch.mask(sin(t * 0.01) * 1.2, t % 65536)", 40);
    CHECK_EQ(mismatches(m, [](double n) {
                 return lib::bitMask(detSin(n * 0.01) * 1.2, static_cast<uint32_t>(std::fmod(n, 65536)));
             }), 0);
    std::vector<double> w = renderCaw("glitch.wrap(sin(t * 0.01), 1 + (t % 50) / 10)", 40);
    CHECK_EQ(mismatches(w, [](double n) { return lib::wrapAround(detSin(n * 0.01), 1 + std::fmod(n, 50) / 10); }), 0);
    CHECK_NEAR(lib::wrapAround(0.5, 3), -0.5, 1e-12);
    for (int i = -100; i <= 100; ++i) {
        const double y = lib::wrapAround(i * 0.37, 7);
        CHECK(y >= -1.0 && y <= 1.0);
    }
}
