// Timber's Simulated piano (1.1.2): Classic untouched by the new knobs, the hammer tables' physics, realism against measurements (inharmonicity, decay, attack spectra), the noises as contacts, the patents guard, block sizes, bad values and a reference render.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "test.h"
#include "timber_core.h"
#include "timber_harness.h"
#include "timber_piano.h"
#include "timber_piano_curves.h"
#include "timber_piano_sim.h"
#include "tolerance.h"

using namespace caw;
using namespace timber_test;

namespace {

bool same(const Stereo& a, const Stereo& b) { return a.l == b.l && a.r == b.r; }
double hzOfKey(double key) { return 440.0 * std::pow(2.0, (key - 69.0) / 12.0); }

// The Simulated piano with nothing in the way of a measurement: no room, no detune, the default otherwise.
Values sim(Values v) {
    Values base = {{"sim", 1}, {"space", 0}};
    for (auto& x : v) base.push_back(x);
    return withModel(0, base);
}

timber::Piano& pianoOf(ModuleProcessor& p) { return static_cast<timber::Instrument<timber::Piano>&>(p).model(); }

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

// Broadband decay as the measurement script read the Salamander notes: 50 ms frames, the peak in the first second,
// a line fitted to the level from `a` to `b` s after it; T60 in s (0: no decay).
double decayT60(const std::vector<float>& x, double a, double b, double sr = 48000) {
    const size_t h = static_cast<size_t>(0.05 * sr), frames = x.size() / h;
    std::vector<double> lv(frames), t(frames);
    for (size_t i = 0; i < frames; ++i) {
        double e = 0;
        for (size_t k = 0; k < h; ++k) e += double(x[i * h + k]) * x[i * h + k];
        lv[i] = 10 * std::log10(e / h + 1e-20), t[i] = (i + 0.5) * 0.05;
    }
    size_t pk = 0;
    for (size_t i = 0; i < std::min<size_t>(20, frames); ++i)
        if (lv[i] > lv[pk]) pk = i;
    double sx = 0, sy = 0, sxx = 0, sxy = 0;
    int m = 0;
    for (size_t i = 0; i < frames; ++i)
        if (t[i] >= t[pk] + a && t[i] <= t[pk] + b && lv[i] > -100) sx += t[i], sy += lv[i], sxx += t[i] * t[i], sxy += t[i] * lv[i], ++m;
    if (m < 5) return 0;
    const double slope = (m * sxy - sx * sy) / (m * sxx - sx * sx);
    return slope < 0 ? -60 / slope : 0;
}

double median(std::vector<double> v) {
    std::sort(v.begin(), v.end());
    return v.size() % 2 ? v[v.size() / 2] : 0.5 * (v[v.size() / 2 - 1] + v[v.size() / 2]);
}

// The share (dB) of x[from, from + n)'s power above `split` Hz (to 16 kHz), on a 25 Hz grid with the fast DFT.
double highShare(const std::vector<float>& x, size_t from, size_t n, double split, double sr = 48000) {
    double hi = 0, all = 0;
    for (double f = 25; f < 16000; f += 25) {
        const double q = powerAt(x, f, from, n, sr);
        all += q;
        if (f >= split) hi += q;
    }
    return 10 * std::log10((hi + 1e-30) / (all + 1e-30));
}
size_t onset(const std::vector<float>& x, double fraction = 0.1) {
    float peak = 0;
    for (size_t i = 0; i < std::min<size_t>(x.size(), 24000); ++i) peak = std::max(peak, std::fabs(x[i]));
    for (size_t i = 0; i < x.size(); ++i)
        if (std::fabs(x[i]) > fraction * peak) return i;
    return 0;
}

}  // namespace

// ---------- Classic is the 1.1.0 piano ----------

TEST(timber_piano_classic_ignores_every_simulated_knob) {
    const std::vector<Note> notes = {{0.0, 0.5, 33, 0.9}, {0.05, 0.4, 60, 0.6}, {0.1, -1, 84, 1.0}, {0.3, 0.7, 47, 0.3}};
    const std::vector<Cc> ccs = {{0.2, 64, 1.0}, {0.6, 64, 0.0}};
    const Values plain = withModel(0, {{"space", 0.2}});
    const Values loaded = withModel(0, {{"space", 0.2}, {"tier", 3}, {"noise", 1}, {"touch", 1}, {"action", 1}, {"glide", 1},
                                        {"sympathy", 1}, {"phantom", 1}});
    auto a = make(plain), b = make(loaded);
    CHECK(same(play(*a, plain, notes, 1.0, 48000, 64, ccs), play(*b, loaded, notes, 1.0, 48000, 64, ccs)));
}

// ---------- The hammer tables (build-time Chaigne-Askenfelt strikes) ----------

TEST(timber_piano_hammer_contact_shortens_up_the_keyboard_and_with_speed) {
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

// ---------- Realism against measurements ----------

TEST(timber_piano_simulated_inharmonicity_follows_the_fitted_curve) {
    // Every A and D# from A0 to A6: B from partials 2..15 (least squares) within 10 % of the curve the loop was
    // designed from (and that curve fits the Salamander Grand's partials, timber_piano_curves.h).
    const double sr = 48000;
    for (double key = 21; key <= 93; key += 3) {
        if (static_cast<int>(key) % 12 != 9 && static_cast<int>(key) % 12 != 3) continue;
        const Values v = sim({{"unison", 0}, {"glide", 0}, {"sympathy", 0}, {"noise", 0}, {"body", 0}, {"stretch", 0}});
        auto p = make(v);
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

TEST(timber_piano_simulated_decays_like_the_salamander_grand) {
    // [Fact, measured 2026-11-20 from the Salamander Grand (CC-BY 3.0; numbers only), velocity layer 8] the median
    // broadband T60 of C, D#, F# and A per octave, 0.1-1 s after the peak (octaves 1-7) and 2-6 s (octaves 1-4).
    // [Assumption] the 25 % tolerance is ours.
    static constexpr double kEarly[7] = {13.06, 6.91, 5.08, 2.50, 2.09, 2.90, 2.84};
    static constexpr double kLate[4] = {24.8, 21.0, 16.4, 23.7};
    for (int o = 1; o <= 7; ++o) {
        std::vector<double> early, late;
        for (int pc : {0, 3, 6, 9}) {
            const double key = 12 * (o + 1) + pc;
            const Values v = sim({{"noise", 0}, {"glide", 0}});
            auto p = make(v);
            const std::vector<float> m = play(*p, v, {{0.0, -1, key, 0.5}}, o <= 4 ? 7.2 : 2.2).mono();
            early.push_back(decayT60(m, 0.1, 1.0));
            if (o <= 4) late.push_back(decayT60(m, 2.0, 6.0));
        }
        const double e = median(early), l = o <= 4 ? median(late) : 0;
        if (verbose()) std::printf("octave %d: early %.2f s (%.2f), late %.1f s (%.1f)\n", o, e, kEarly[o - 1], l, o <= 4 ? kLate[o - 1] : 0.0);
        CHECK(std::fabs(e / kEarly[o - 1] - 1) < 0.25);
        if (o <= 4) CHECK(std::fabs(l / kLate[o - 1] - 1) < 0.25);
    }
}

TEST(timber_piano_simulated_attack_brightens_and_grows_like_the_salamander_grand) {
    // [Fact, measured 2026-11-20 from the Salamander Grand, velocity layers 2 and 16] in the first 30 ms, the share
    // above the 6.5th partial grows by 6.3 dB (C2) and 20.7 dB (C4) from pp to ff, and the first 100 ms by 14.0 and
    // 13.5 dB. [Assumption] the layers as velocities 0.09 and 0.98; the 6 dB tolerance is ours.
    struct Target {
        double key, bright, level;
    };
    for (const Target t : {Target{36, 6.3, 14.0}, Target{60, 20.7, 13.5}}) {
        double share[2], level[2];
        for (int k = 0; k < 2; ++k) {
            const Values v = sim({{"noise", 0}, {"velocity", 1}});
            auto p = make(v);
            const std::vector<float> m = play(*p, v, {{0.0, -1, t.key, k == 0 ? 0.09 : 0.98}}, 0.3).mono();
            const size_t on = onset(m);
            share[k] = highShare(m, on, 1440, 6.5 * hzOfKey(t.key));
            level[k] = rmsDb(m, on, 4800);
        }
        if (verbose()) std::printf("key %.0f: brightening %.1f dB (%.1f), level %.1f dB (%.1f)\n", t.key, share[1] - share[0], t.bright,
                                   level[1] - level[0], t.level);
        CHECK(std::fabs(share[1] - share[0] - t.bright) < 6);
        CHECK(std::fabs(level[1] - level[0] - t.level) < 6);
    }
}

TEST(timber_piano_simulated_keyboard_is_even_and_as_loud_as_classic) {
    double lo = 1e9, hi = -1e9, simSum = 0, classicSum = 0;
    int n = 0;
    for (double key = 21; key <= 108; key += 7) {
        const Values v = sim({}), c = withModel(0, {{"space", 0}});
        auto p = make(v), q = make(c);
        const double l = rmsDb(play(*p, v, {{0.0, -1, key, 0.7}}, 0.3).mono(), 0, 14400);
        const double lc = rmsDb(play(*q, c, {{0.0, -1, key, 0.7}}, 0.3).mono(), 0, 14400);
        if (verbose()) std::printf("key %.0f: %.1f dB (Classic %.1f)\n", key, l, lc);
        lo = std::min(lo, l), hi = std::max(hi, l);
        simSum += l, classicSum += lc, ++n;
    }
    CHECK(hi - lo < 12);
    CHECK(std::fabs(simSum / n - classicSum / n) < 3);
}

// ---------- The noises, as contacts ----------

TEST(timber_piano_attack_thump_grows_with_velocity_and_is_strongest_in_the_treble) {
    double lv[2][3];
    for (int r = 0; r < 2; ++r)
        for (int k = 0; k < 3; ++k) {
            const Values v = sim({{"noise", 1}});
            auto p = make(v);
            pianoOf(*p).testMuteStrings = true;
            const std::vector<float> m = play(*p, v, {{0.0, -1, r == 0 ? 36.0 : 84.0, 0.2 + 0.35 * k}}, 0.1).mono();
            lv[r][k] = rmsDb(m, 0, 2400);
        }
    if (verbose()) std::printf("thump C2 %.1f %.1f %.1f, C6 %.1f %.1f %.1f dB\n", lv[0][0], lv[0][1], lv[0][2], lv[1][0], lv[1][1], lv[1][2]);
    for (int r = 0; r < 2; ++r) CHECK(lv[r][0] < lv[r][1] && lv[r][1] < lv[r][2] && lv[r][0] > -120);
    for (int k = 0; k < 3; ++k) CHECK(lv[1][k] > lv[0][k]);
}

TEST(timber_piano_key_bottom_comes_before_the_string_at_pp_and_after_at_ff) {
    double before = 0, after = 0;
    for (int k = 0; k < 2; ++k) {
        const Values v = sim({{"action", 1}, {"noise", 1}, {"velocity", 1}});
        auto p = make(v);
        play(*p, v, {{0.0, -1, 60, k == 0 ? 0.15 : 0.95}}, 0.1);
        const timber::Piano& m = pianoOf(*p);
        (k == 0 ? before : after) = m.lastKeybedAt - m.lastStrikeAt;
        if (verbose()) std::printf("velocity %s: strike at %.1f ms, key bottom at %.1f ms\n", k ? "ff" : "pp", m.lastStrikeAt / 48.0, m.lastKeybedAt / 48.0);
        CHECK(m.lastStrikeAt > (k == 0 ? 20 * 48.0 : 1.5 * 48.0));  // the action delay: longer when soft
    }
    CHECK(before < 0 && after > 0);
}

TEST(timber_piano_damper_buzz_follows_the_string_and_never_the_release) {
    // The buzz grows with what the string still has when its damper lands.
    double buzz[2];
    for (int k = 0; k < 2; ++k) {
        const Values v = sim({{"noise", 1}});
        auto p = make(v);
        play(*p, v, {{0.0, 0.4, 48, k == 0 ? 0.3 : 0.95}}, 0.8);
        buzz[k] = pianoOf(*p).buzzEnergy;
    }
    if (verbose()) std::printf("damper buzz energy %.3g (soft) %.3g (loud)\n", buzz[0], buzz[1]);
    CHECK(buzz[0] > 0 && buzz[1] > 4 * buzz[0]);
    // A note-off's velocity changes nothing (the patent guard: no sound by the manner of release).
    Stereo outs[2];
    for (int k = 0; k < 2; ++k) {
        const Values v = sim({{"noise", 1}, {"touch", 1}, {"action", 1}});
        auto p = make(v);
        const ModuleDescriptor& d = p->descriptor();
        std::vector<ParameterValue> params(d.parameterCount);
        for (uint32_t i = 0; i < d.parameterCount; ++i) {
            params[i].value = d.parameters[i].defaultValue;
            for (const auto& [name, x] : v)
                if (d.parameters[i].id == name) params[i].value = x;
        }
        outs[k].l.assign(48000, 0), outs[k].r.assign(48000, 0);
        for (size_t at = 0; at < 48000; at += 64) {
            std::vector<Event> ev;
            if (at == 0) ev.push_back(notes::noteOn(0, 1, 52, 0.8)), ev.push_back(notes::noteOn(10, 2, 64, 0.6));
            if (at == 19200) ev.push_back(notes::noteOff(5, 1, 52, k == 0 ? 0.0 : 1.0)), ev.push_back(notes::noteOff(9, 2, 64, k == 0 ? 0.1 : 0.9));
            float* ch[2] = {outs[k].l.data() + at, outs[k].r.data() + at};
            const ChannelBufferView audio{ch, 2, 64};
            const EventInput in{ev.data(), static_cast<uint32_t>(ev.size())};
            ProcessBlock b;
            b.frames = 64, b.sampleRate = 48000, b.audioOut = &audio, b.audioOutCount = 1, b.eventIn = &in, b.eventInCount = 1;
            b.parameters = params.data(), b.parameterCount = d.parameterCount;
            p->processPorts(b);
        }
    }
    CHECK(same(outs[0], outs[1]));
}

TEST(timber_piano_pedal_noise_never_reaches_the_resonance_and_the_pedal_lengthens_the_decay) {
    const std::vector<Note> notes = {{0.0, 0.3, 48, 0.8}, {0.05, 0.35, 55, 0.7}, {0.6, 0.9, 62, 0.6}};
    const std::vector<Cc> ccs = {{0.2, 64, 1.0}, {0.8, 64, 0.0}, {1.0, 64, 1.0}};
    double res[2];
    Stereo outs[2];
    for (int k = 0; k < 2; ++k) {
        const Values v = sim({{"noise", k == 0 ? 0.0 : 1.0}, {"resonance", 0.8}});
        auto p = make(v);
        outs[k] = play(*p, v, notes, 1.5, 48000, 64, ccs);
        res[k] = pianoOf(*p).resInputEnergy;
    }
    CHECK(res[0] > 0 && res[0] == res[1]);  // bit-identical input with and without the pedal's noise
    double diff = 0;
    for (size_t i = 0; i < outs[0].size(); ++i) diff += std::fabs(outs[0].l[i] - outs[1].l[i]);
    CHECK(diff > 0);  // the noise is there, at the output
    // [Fact, Schutz et al., AES 2008, abstract read 2026-11-20] the sustain pedal lengthens the decay.
    double tail[2];
    for (int k = 0; k < 2; ++k) {
        const Values v = sim({{"sustain", k == 0 ? 0.0 : 1.0}});
        auto p = make(v);
        tail[k] = rmsDb(play(*p, v, {{0.0, 0.3, 55, 0.8}}, 2.0).mono(), 48000, 48000);
    }
    CHECK(tail[1] > tail[0] + 20);
}

TEST(timber_piano_held_key_rings_at_the_struck_keys_partials) {
    // C3 held down silently (too slow to throw its hammer); C4 struck and released: C3's strings go on at C4's
    // fundamental (C3's 2nd partial), with `sympathy` and not without.
    double at[2], own[2];
    for (int k = 0; k < 2; ++k) {
        const Values v = sim({{"sympathy", k == 0 ? 0.0 : 1.0}, {"velocity", 1}, {"noise", 0}, {"body", 0}});
        auto p = make(v);
        const std::vector<float> m = play(*p, v, {{0.0, -1, 48, 0.01}, {0.02, 0.3, 60, 0.9}}, 1.2).mono();
        const double f = hzOfKey(60) * std::sqrt(1 + timber::piano_curves::inharmonicity(48) * 4);
        at[k] = 10 * std::log10(powerAt(m, f, 33600, 19200, 48000) + 1e-30);
        own[k] = 10 * std::log10(powerAt(m, hzOfKey(48), 33600, 19200, 48000) + 1e-30);
    }
    if (verbose()) std::printf("after C4's release, at C4: %.1f dB without, %.1f with; at C3: %.1f, %.1f\n", at[0], at[1], own[0], own[1]);
    CHECK(at[1] > at[0] + 20);
}

// ---------- As every built-in: block sizes, bad values, quiet, reference ----------

TEST(timber_piano_simulated_renders_the_same_bits_at_any_block_size) {
    for (int tier : {1, 2, 3}) {
        const Values v = sim({{"space", 0.3}, {"tier", static_cast<double>(tier)}, {"noise", 1}, {"touch", 0.7}, {"action", 1}, {"sympathy", 1},
                              {"glide", 1}, {"phantom", 1}});
        const std::vector<Note> n = {{0.0, 0.4, 28, 0.9}, {0.013, 0.31, 64, 0.5}, {0.2, -1, 71.3, 1.0}, {0.35, 0.6, 40, 0.3}, {0.1, 0.5, 98, 0.8}};
        Stereo ref;
        for (uint32_t block : {64u, 1u, 37u, 512u}) {
            auto p = make(v);
            const Stereo s = play(*p, v, n, 0.9, 48000, block, {{0.1, 64, 1.0}, {0.5, 64, 0.0}, {0.3, 1, 0.7}});
            if (block == 64) ref = s;
            else if (!same(ref, s)) cawtest::fail(__FILE__, __LINE__, "tier " + std::to_string(tier) + " differs at block " + std::to_string(block));
        }
    }
}

TEST(timber_piano_simulated_falls_quiet_to_exact_zeros_and_survives_bad_values) {
    const Values v = sim({{"space", 0.5}, {"release", 0.1}, {"noise", 1}, {"sustain", 0.0}});
    auto p = make(v);
    double quietAt = -1;
    const Stereo s = play(*p, v, {{0.0, 0.2, 60, 1.0}, {0.05, 0.25, 30, 1.0}}, 45.0, 48000, 64, {{0.1, 64, 1}, {0.15, 64, 0}}, &quietAt);
    if (verbose()) std::printf("Simulated quiet at %.2f s\n", quietAt);
    CHECK(quietAt > 0 && quietAt < 44);
    bool zeros = true;
    for (size_t i = static_cast<size_t>(44.0 * 48000); i < s.size(); ++i) zeros = zeros && s.l[i] == 0.0f && s.r[i] == 0.0f;
    CHECK(zeros);
    for (double bad : {double(NAN), double(INFINITY), -1e300}) {
        const Values b = withModel(0, {{"sim", 1}, {"tier", bad}, {"noise", bad}, {"touch", bad}, {"action", bad}, {"glide", bad}, {"sympathy", bad},
                                       {"phantom", bad}, {"hammer", bad}, {"body", bad}});
        auto q = make(b);
        const Stereo o = play(*q, b, {{0.0, 0.1, 127.9, 1.0}, {0.0, 0.1, 0.0, 1.0}, {0.01, 0.2, 21, 1.0}}, 0.4);
        bool finite = true;
        for (size_t i = 0; i < o.size(); ++i) finite = finite && std::isfinite(o.l[i]) && std::isfinite(o.r[i]);
        CHECK(finite);
    }
    // Many held keys, the pedal down and full sympathy for 6 s: the held strings feeding each other stay stable.
    const Values h = sim({{"sympathy", 1}, {"sustain", 1}, {"resonance", 1}});
    auto q = make(h);
    std::vector<Note> chord;
    for (int k = 0; k < 16; ++k) chord.push_back({0.01 * k, -1, 36.0 + 3 * k, 0.9});
    const std::vector<float> m = play(*q, h, chord, 6.0).mono();
    CHECK(rmsDb(m, 5 * 48000, 48000) < rmsDb(m, 0, 48000) - 6);
}

TEST(timber_piano_simulated_matches_its_reference_render) {
    cawtest::References refs("timber_piano");
    for (int tier : {1, 2, 3}) {
        const Values v = sim({{"tier", static_cast<double>(tier)}, {"noise", 0.6}, {"sustain", 0.0}});
        auto p = make(v);
        const Stereo s = play(*p, v, {{0.0, 0.5, 33, 0.9}, {0.1, 0.6, 55, 0.6}, {0.2, 0.9, 64, 0.75}, {0.3, 0.7, 88, 0.4}}, 1.2, 48000, 64,
                              {{0.4, 64, 1.0}, {0.8, 64, 0.0}});
        CHECK_REFERENCE(refs, "timber_piano_simulated_tier" + std::to_string(tier), (cawtest::Audio{s.l, s.r}), cawtest::Class::Chaotic);
    }
}
