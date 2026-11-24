// Timber's 1.1.2 Simulated models (every model but the piano): the realism checks (the flute's jet and breath, the reeds' tonguing and bores, brass brightening with level, the bow's Helmholtz motion and Schelleng window, handling noise and fret buzz, contact mallets and hammers, the organ's key contacts), block sizes, tiers, bad values and references.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>
#include <vector>

#include "test.h"
#include "timber_harness.h"
#include "timber_keys.h"
#include "timber_mallet_wind.h"
#include "timber_strings.h"
#include "tolerance.h"

using namespace caw;
using namespace timber_test;
using namespace caw::timber;

namespace {

double hzOf(double note) { return 440.0 * std::pow(2.0, (note - 69.0) / 12.0); }
bool same(const Stereo& a, const Stereo& b) { return a.l == b.l && a.r == b.r; }
Values simOf(int model, Values v) {
    v.emplace_back("sim", 1.0);
    return withModel(model, v);
}
// One sustained note, mono.
std::vector<float> note(const Values& v, double key, double vel, double on, double total, int tier = kQualityNormal) {
    auto p = make(v, 48000, tier);
    return play(*p, v, {{0.0, on, key, vel}}, total).mono();
}
// A harmonic's level against the fundamental's, plus 20 log10(n): 0 for a sawtooth's 1/n.
double sawDev(const std::vector<float>& x, double f, int n, size_t from, size_t len) {
    return bandDb(x, n * f, from, len, 48000) - bandDb(x, f, from, len, 48000) + 20 * std::log10(n);
}

// Drives one model's class directly (no frame), for the checks that read its state.
template <class M>
struct Direct {
    M m;
    typename M::Voice voices[4];
    Shared s;
    double p[M::kModelParams] = {};
    explicit Direct(int quality = kQualityNormal) {
        s.sr = 48000, s.quality = quality, s.release = 0.2;
        m.prepare(48000, voices, 4);
        m.reset();
    }
    void set(const double* values) {
        for (uint32_t k = 0; k < M::kModelParams; ++k) p[k] = values[k];
        m.control(p, s);
    }
    typename M::Voice& start(double pitch, double vel) {
        typename M::Voice& v = voices[0];
        v.active = v.held = true, v.pitch = pitch, v.velocity = vel, v.key = static_cast<uint8_t>(pitch);
        m.start(v, s);
        return v;
    }
    // Ends a chunk as the frame does: the model's post() after its voices.
    void finish(uint32_t n) {
        float l[kControlFrames] = {}, r[kControlFrames] = {};
        m.post(l, r, n, s);
    }
    // Renders `frames` (a multiple of 16) of voice 0, calling control and voiceControl on the grid.
    void run(std::vector<float>& out, size_t frames) {
        float buf[kControlFrames];
        for (size_t at = 0; at < frames; at += kControlFrames) {
            m.control(p, s);
            m.voiceControl(voices[0], s);
            m.render(voices[0], buf, kControlFrames);
            finish(kControlFrames);
            out.insert(out.end(), buf, buf + kControlFrames);
        }
    }
};

}  // namespace

// ---------- Every simulated model ----------

TEST(timber_sim_models_render_the_same_bits_at_any_block_size_and_tier) {
    for (int model = 1; model <= 6; ++model)
        for (int tier : {kQualityEco, kQualityNormal, kQualityHigh}) {
            const Values v = simOf(model, {{"space", 0.3}, {"noises", 0.8}});
            const std::vector<Note> n = {{0.0, 0.4, 48, 0.8}, {0.013, 0.31, 64, 0.5}, {0.2, -1, 71.3, 1.0}, {0.35, 0.6, 55, 0.3}};
            Stereo ref;
            for (uint32_t block : {64u, 1u, 37u, 512u}) {
                auto p = make(v, 48000, tier);
                const Stereo s = play(*p, v, n, 0.8, 48000, block, {{0.1, 64, 1.0}, {0.5, 64, 0.0}, {0.3, 1, 0.7}});
                if (block == 64) ref = s;
                else if (!same(ref, s))
                    cawtest::fail(__FILE__, __LINE__, "model " + std::to_string(model) + " tier " + std::to_string(tier) + " differs at block " + std::to_string(block));
            }
        }
    // Every kind within each model at Normal (each kind runs its own path).
    struct Kind {
        int model;
        const char* id;
        int count;
    };
    for (const Kind k : {Kind{1, "kind", 2}, Kind{3, "instrument", 4}, Kind{4, "section", 4}, Kind{5, "instrument", 6}, Kind{6, "instrument", 4}})
        for (int i = 1; i < k.count; ++i) {
            const Values v = simOf(k.model, {{"space", 0.3}, {"noises", 0.8}, {k.id, static_cast<double>(i)}});
            const std::vector<Note> n = {{0.0, 0.4, 60, 0.8}, {0.013, 0.31, 67, 0.5}, {0.2, -1, 72.3, 1.0}};
            Stereo ref;
            for (uint32_t block : {64u, 1u, 37u}) {
                auto p = make(v);
                const Stereo s = play(*p, v, n, 0.6, 48000, block, {{0.3, 1, 0.7}});
                if (block == 64) ref = s;
                else if (!same(ref, s))
                    cawtest::fail(__FILE__, __LINE__, "model " + std::to_string(k.model) + " " + k.id + " " + std::to_string(i) + " differs at block " + std::to_string(block));
            }
        }
}

TEST(timber_sim_models_fall_quiet_to_exact_zeros_and_survive_bad_values) {
    for (int model = 1; model <= 6; ++model) {
        const Values v = simOf(model, {{"space", 0.5}, {"release", 0.1}, {"noises", 1.0}});
        auto p = make(v);
        double quietAt = -1;
        const Stereo s = play(*p, v, {{0.0, 0.2, 60, 1.0}, {0.05, 0.25, 30, 1.0}}, 45.0, 48000, 64, {}, &quietAt);
        if (verbose()) std::printf("sim model %d quiet at %.2f s\n", model, quietAt);
        CHECK(quietAt > 0 && quietAt < 44);
        bool zeros = true;
        for (size_t i = static_cast<size_t>(44.0 * 48000); i < s.size(); ++i) zeros = zeros && s.l[i] == 0.0f && s.r[i] == 0.0f;
        CHECK(zeros);
        const Values bad = simOf(model, {{"tone", NAN}, {"noises", NAN}, {"release", NAN}, {"level", -INFINITY}});
        auto q = make(bad);
        const Stereo b = play(*q, bad, {{0.0, 0.1, 127.9, 1.0}, {0.0, 0.1, 0.0, 1.0}}, 0.3);
        bool finite = true;
        for (size_t i = 0; i < b.size(); ++i) finite = finite && std::isfinite(b.l[i]) && std::isfinite(b.r[i]);
        CHECK(finite);
        // Loud chords at every tier stay bounded.
        for (int tier : {kQualityEco, kQualityHigh}) {
            auto r = make(simOf(model, {{"noises", 1.0}}), 48000, tier);
            const Stereo c = play(*r, simOf(model, {{"noises", 1.0}}), {{0.0, 0.5, 36, 1.0}, {0.0, 0.5, 48, 1.0}, {0.0, 0.5, 60, 1.0}, {0.0, 0.5, 84, 1.0}}, 0.8);
            float peak = 0;
            for (size_t i = 0; i < c.size(); ++i) peak = std::max(peak, std::fabs(c.l[i]));
            CHECK(std::isfinite(peak) && peak < 4.0f);
        }
    }
}

TEST(timber_sim_models_match_their_reference_renders) {
    cawtest::References refs("timber_sim");
    static const char* kNames[] = {"", "epiano", "organ", "plucked", "bowed", "mallets", "winds"};
    for (int model = 1; model <= 6; ++model) {
        const Values v = simOf(model, model == 4 ? Values{{"attack", 0.005}} : Values{});
        auto p = make(v);
        const Stereo s = play(*p, v, {{0.0, 0.5, 48, 0.9}, {0.1, 0.6, 55, 0.6}, {0.2, 0.9, 64, 0.75}, {0.3, 0.7, 76, 0.4}}, 1.2);
        CHECK_REFERENCE(refs, std::string("timber_sim_") + kNames[model], (cawtest::Audio{s.l, s.r}), cawtest::Class::Chaotic);
    }
}

// ---------- Winds ----------

TEST(timber_sim_winds_speak_and_hold_their_pitch) {
    for (int instrument = 0; instrument < 4; ++instrument)
        for (double key : {instrument == 2 ? 55.0 : 50.0, 62.0, 74.0, 81.0}) {  // [Assumption] the cone speaks from G3 up
            const Values v = simOf(6, {{"instrument", instrument}, {"space", 0}, {"vibrato", 0}, {"noise", 0}, {"noises", 0}});
            const std::vector<float> x = note(v, key, 0.8, 1.0, 1.6);
            const double f = hzOf(key);
            const double a = rmsDb(x, 24000, 9600), b = rmsDb(x, 38400, 9600), after = rmsDb(x, 67200, 4800);
            const double err = cents(peakHz(x, f, 100, 19200, 24000, 48000), f);
            if (verbose()) std::printf("sim wind %d key %.0f: %.1f / %.1f dB, after %.1f, %+.1f ct\n", instrument, key, a, b, after, err);
            CHECK(a > -45);
            CHECK(std::fabs(a - b) < 4);
            CHECK(after < b - 30);
            CHECK(std::fabs(err) < 12);
        }
}

TEST(timber_sim_flute_breath_noise_follows_the_flow_and_pulses_with_the_period) {
    // The jet's turbulence, read from the voice: its level against the flow (U^2) through a slow attack, and its
    // envelope's spectrum, which peaks at the note's own frequency (the flux into the pipe switches each period).
    Direct<Wind> d;
    double p[Wind::kModelParams] = {1, 0.6, 0.4, 0.5, 0, 5, 0, 0.6, 1, 0};
    d.set(p);
    Wind::Voice& v = d.start(69, 0.8);
    std::vector<float> turb, flow;
    float buf[kControlFrames];
    for (int blk = 0; blk < 4800; ++blk) {
        d.m.control(d.p, d.s);
        d.m.voiceControl(v, d.s);
        for (uint32_t i = 0; i < kControlFrames; ++i) {
            d.m.render(v, buf + i, 1);
            d.finish(1);
            turb.push_back(v.turb);
            flow.push_back(v.jetU * v.jetU);
        }
    }
    // Level against flow, in 10 ms windows over the attack (0-0.6 s).
    std::vector<double> lv, fl;
    for (size_t at = 0; at + 480 <= 28800; at += 480) {
        double e = 0, u = 0;
        for (size_t i = at; i < at + 480; ++i) e += turb[i] * turb[i], u += flow[i];
        lv.push_back(std::sqrt(e / 480)), fl.push_back(u / 480);
    }
    double ma = 0, mb = 0;
    for (size_t i = 0; i < lv.size(); ++i) ma += lv[i], mb += fl[i];
    ma /= lv.size(), mb /= fl.size();
    double sab = 0, saa = 0, sbb = 0;
    for (size_t i = 0; i < lv.size(); ++i) sab += (lv[i] - ma) * (fl[i] - mb), saa += (lv[i] - ma) * (lv[i] - ma), sbb += (fl[i] - mb) * (fl[i] - mb);
    const double corr = sab / std::sqrt(saa * sbb + 1e-30);
    // The steady envelope's spectrum: |turb| from 0.8 s.
    std::vector<float> env(turb.begin() + 38400, turb.end());
    for (float& x : env) x = std::fabs(x);
    const double f0 = hzOf(69);
    const double atF = bandDb(env, f0, 0, env.size(), 48000);
    const double off = std::max(bandDb(env, 0.7 * f0, 0, env.size(), 48000), bandDb(env, 1.35 * f0, 0, env.size(), 48000));
    if (verbose()) std::printf("flute breath: corr %.3f, envelope at f0 %.1f dB vs %.1f off it\n", corr, atF, off);
    CHECK(corr > 0.8);
    CHECK(atF > off + 6);
}

TEST(timber_sim_flute_attack_is_a_breathy_transient) {
    // The jet's slow start (its speed rising with the breath) and the tongue's release: the attack's share of noise
    // (above 5 kHz) is far over the steady tone's.
    const Values v = simOf(6, {{"instrument", 1}, {"space", 0}, {"vibrato", 0}, {"attack", 0.08}, {"noises", 0.3}});
    const std::vector<float> x = note(v, 72, 0.8, 1.0, 1.2);
    const double attack = highShareDb(x, 0, 2400, 48000, 5000), steady = highShareDb(x, 28800, 4800, 48000, 5000);
    if (verbose()) std::printf("flute high share: attack %.1f, steady %.1f dB\n", attack, steady);
    CHECK(attack > steady + 6);
}

TEST(timber_sim_reeds_tongue_their_notes_and_the_bores_set_the_harmonics) {
    // Clarinet: a closed cylinder's odd harmonics lead its even ones; sax: a cone sounds them all.
    const Values cl = simOf(6, {{"instrument", 0}, {"space", 0}, {"vibrato", 0}, {"noise", 0}, {"noises", 0}});
    const Values sx = simOf(6, {{"instrument", 2}, {"space", 0}, {"vibrato", 0}, {"noise", 0}, {"noises", 0}});
    const double f = hzOf(50);
    const std::vector<float> c = note(cl, 50, 0.8, 1.0, 1.2), s = note(sx, 50, 0.8, 1.0, 1.2);
    const double cOdd = std::min(bandDb(c, f, 24000, 9600, 48000), bandDb(c, 3 * f, 24000, 9600, 48000));
    const double cEven = std::max(bandDb(c, 2 * f, 24000, 9600, 48000), bandDb(c, 4 * f, 24000, 9600, 48000));
    const double sOdd = std::max(bandDb(s, f, 24000, 9600, 48000), bandDb(s, 3 * f, 24000, 9600, 48000));
    const double sEven = std::max(bandDb(s, 2 * f, 24000, 9600, 48000), bandDb(s, 4 * f, 24000, 9600, 48000));
    if (verbose()) std::printf("clarinet odd %.1f even %.1f; sax odd %.1f even %.1f\n", cOdd, cEven, sOdd, sEven);
    CHECK(cOdd > cEven + 10);
    CHECK(sEven > sOdd - 12);
    // The tongue: silent while it holds the reed, a fast onset after; a short release is a tongued stop.
    const Values tg = simOf(6, {{"instrument", 0}, {"space", 0}, {"vibrato", 0}, {"noise", 0}, {"noises", 0}, {"attack", 0.005}, {"release", 0.02}});
    const std::vector<float> t = note(tg, 62, 1.0, 0.5, 0.8);
    const double held = rmsDb(t, 0, 96), sounding = rmsDb(t, 4800, 2400), stopped = rmsDb(t, 28800, 2400);
    if (verbose()) std::printf("tongue: under it %.1f, sounding %.1f, after the tongued stop %.1f dB\n", held, sounding, stopped);
    CHECK(held < sounding - 20);
    CHECK(stopped < sounding - 30);  // 0.1 s after: the bore rings on a moment behind the closed reed
}

TEST(timber_sim_brass_brightens_with_level_and_steepens) {
    // Played louder (the velocity pushes the lips harder) the upper harmonics rise against the fundamental; the
    // radiated wave's steepening (Normal) adds to that at a loud note over Eco, which has none.
    const Values v = simOf(6, {{"instrument", 3}, {"space", 0}, {"vibrato", 0}, {"noise", 0}, {"noises", 0}, {"breath", 0.6}});
    const double f = hzOf(62);
    auto slope = [&](const std::vector<float>& x) {
        const double g = peakHz(x, f, 40, 24000, 9600, 48000);
        const double h1 = bandDb(x, g, 24000, 9600, 48000);
        return 0.5 * (bandDb(x, 2 * g, 24000, 9600, 48000) + bandDb(x, 4 * g, 24000, 9600, 48000)) - h1;
    };
    const double soft = slope(note(v, 62, 0.2, 1.0, 1.2)), loud = slope(note(v, 62, 1.0, 1.0, 1.2));
    const double ecoSoft = slope(note(v, 62, 0.2, 1.0, 1.2, kQualityEco)), ecoLoud = slope(note(v, 62, 1.0, 1.0, 1.2, kQualityEco));
    if (verbose()) std::printf("brass 2nd/4th against the 1st: pp %.1f, ff %.1f dB; Eco pp %.1f, ff %.1f dB\n", soft, loud, ecoSoft, ecoLoud);
    CHECK(loud > soft + 3);
    CHECK(loud > ecoLoud + 1.5);
    CHECK(loud - soft > ecoLoud - ecoSoft);
}

// ---------- Bowed ----------
// (The bow's tests use the bridge's force; its loss rounds the sawtooth's corner on the higher strings.)

TEST(timber_sim_bow_finds_helmholtz_motion_inside_schellengs_window) {
    // Inside the window (the default force), the bridge's force is a sawtooth: each of the first 6 harmonics
    // within 3 dB of 1/n (the bow at 1/10 of the string: its 10th is the first missing one). Too little force
    // and it slips more than once a period: no longer a sawtooth.
    for (int section : {1, 2, 3}) {
        static constexpr double kKey[4] = {69, 62, 48, 36};
        const double key = kKey[section], f = hzOf(key);
        // The bridge's loss rounds the corner of the higher strings' sawtooth: to the 8th on the cello and the bass,
        // the 5th on the viola.
        const int top = section == 1 ? 4 : 8;
        const Values in = simOf(4, {{"section", section}, {"space", 0}, {"body", 0}, {"vibrato", 0}, {"noises", 0}, {"attack", 0.005}, {"position", 0.1}});
        const std::vector<float> x = note(in, key, 0.8, 1.5, 1.6, kQualityHigh);  // High: the elasto-plastic bow
        double worst = 0;
        for (int n = 2; n <= top; ++n) worst = std::max(worst, std::fabs(sawDev(x, f, n, 24000, 24000)));
        Values low = in;
        low.emplace_back("pressure", 0.0);
        const std::vector<float> y = note(low, key, 0.8, 1.5, 1.6, kQualityHigh);
        double lowWorst = 0;
        for (int n = 2; n <= 6; ++n) lowWorst = std::max(lowWorst, std::fabs(sawDev(y, f, n, 24000, 24000)));
        if (verbose()) std::printf("bow section %d: worst 1/n deviation %.1f dB in the window, %.1f dB under it\n", section, worst, lowWorst);
        CHECK(worst < 3);
        CHECK(lowWorst > 6);
    }
}

TEST(timber_sim_bow_slips_for_about_its_position_of_each_period) {
    // Helmholtz motion: the string slips under the bow for beta of each period (the bow's position along it); the
    // rounded corner (the bridge's loss) and the bristles' release widen it a little.
    for (double beta : {0.1, 0.15}) {
        Direct<Bowed> d(kQualityHigh);
        double p[Bowed::kModelParams] = {2, 0.5, 0.5, beta, 0, 5.5, 0.005, 1, 0};
        d.set(p);
        Bowed::Voice& v = d.start(48, 0.8);
        std::vector<float> out;
        d.run(out, 24000);
        v.sliding = v.counted = 0;
        d.run(out, 24000);
        const double share = static_cast<double>(v.sliding) / v.counted;
        if (verbose()) std::printf("bow at %.2f: slipping %.3f of the time\n", beta, share);
        CHECK(share > 0.6 * beta && share < 2.2 * beta);
    }
}

TEST(timber_sim_bowed_string_sustains_in_tune_and_stops_after) {
    for (int section = 0; section < 4; ++section) {
        static constexpr double kKey[4] = {69, 62, 48, 36};
        const double key = kKey[section];
        const Values v = simOf(4, {{"space", 0}, {"vibrato", 0}, {"section", section}, {"release", 0.15}});
        const std::vector<float> m = note(v, key, 0.8, 1.5, 2.5);
        const double a = rmsDb(m, 38400, 9600), b = rmsDb(m, 60000, 9600), after = rmsDb(m, 96000, 9600);
        const double err = cents(peakHz(m, hzOf(key), 60, 24000, 38400, 48000), hzOf(key));
        if (verbose()) std::printf("sim bowed %d: %.1f / %.1f dB held, %.1f after, %+.1f ct\n", section, a, b, after, err);
        CHECK(a > -40);
        CHECK(std::fabs(a - b) < 4);
        CHECK(after < b - 30);  // the bow stopped on the string damps it less than 1.1.0's table: a bass rings a little
        CHECK(std::fabs(err) < 15);
    }
}

// ---------- Plucked ----------

TEST(timber_sim_handling_noise_rises_linearly_with_slide_speed) {
    // A finger sliding on a wound string: the windings' pulse rate and the noise's RMS rise with its speed
    // (Pakarinen, Penttinen and Bank 2007). The same pluck glided at 0, 1 and 2 semitones a second; the noise is the
    // difference from the still one.
    double rate[3] = {}, level[3] = {};
    for (int k = 0; k < 3; ++k) {
        Direct<Pluck> d;
        double p[Pluck::kModelParams] = {0, 0.2, 0.5, 0, 0.5, 1, 1, 1.0};
        d.set(p);
        Pluck::Voice& v = d.start(43, 0.6);
        float buf[kControlFrames];
        for (int blk = 0; blk < 3000; ++blk) {
            v.pitch = 43 + k * 1.0 * blk * kControlFrames / 48000.0;
            d.m.control(d.p, d.s);
            d.m.voiceControl(v, d.s);
            d.m.render(v, buf, kControlFrames);
            d.finish(kControlFrames);
            if (blk == 1500) rate[k] = v.slideInc * 48000.0, level[k] = v.slideAmp + kControlFrames * v.slideStep;
        }
    }
    // A pulse train's RMS through the longitudinal mode: its size times the square root of its rate.
    const double rms1 = level[1] * std::sqrt(rate[1]), rms2 = level[2] * std::sqrt(rate[2]);
    if (verbose()) std::printf("slide pulse rates %.1f, %.1f, %.1f Hz; RMS ratio %.3f\n", rate[0], rate[1], rate[2], rms2 / rms1);
    CHECK(rate[0] == 0.0 && level[0] == 0.0);
    CHECK(rate[1] > 10.0);
    CHECK(std::fabs(rate[2] / rate[1] - 2.0) < 0.15);
    CHECK(std::fabs(rms2 / rms1 - 2.0) < 0.2);
}

TEST(timber_sim_hard_plucks_buzz_on_the_frets) {
    // A hard pluck of the low E swings past the frets' gap and buzzes (Normal: more high partials than Eco, which
    // has no frets); a soft one stays under the gap and sounds the same at both tiers.
    const Values v = simOf(3, {{"instrument", 0}, {"space", 0}, {"noises", 0}});
    const std::vector<float> hard = note(v, 40, 1.0, -1, 0.6), hardEco = note(v, 40, 1.0, -1, 0.6, kQualityEco);
    const std::vector<float> soft = note(v, 40, 0.2, -1, 0.6), softEco = note(v, 40, 0.2, -1, 0.6, kQualityEco);
    const double h = highShareDb(hard, 0, 9600, 48000, 2000), he = highShareDb(hardEco, 0, 9600, 48000, 2000);
    if (verbose()) std::printf("pluck high share: hard %.1f (Eco %.1f) dB\n", h, he);
    CHECK(h > he + 2);
    CHECK(soft == softEco);
}

// ---------- Mallets and the electric piano ----------

TEST(timber_sim_contact_mallets_and_hammers_brighten_with_hardness_and_velocity) {
    auto share = [](const Values& v, double vel) { return highShareDb(note(v, 64, vel, -1, 0.3), 0, 4800, 48000, 1000); };
    const Values yarn = simOf(5, {{"space", 0}, {"hardness", 0.1}}), hard = simOf(5, {{"space", 0}, {"hardness", 0.95}});
    const Values medium = simOf(5, {{"space", 0}, {"hardness", 0.5}});
    const double sy = share(yarn, 0.8), sh = share(hard, 0.8), soft = share(medium, 0.2), loud = share(medium, 1.0);
    if (verbose()) std::printf("mallet high share: yarn %.1f, hard %.1f; yarn pp %.1f, ff %.1f dB\n", sy, sh, soft, loud);
    CHECK(sh > sy + 10);
    CHECK(loud > soft + 2);
    // The contact time: a hard head leaves the bar sooner than a yarn one.
    auto touch = [](double hardness) {
        Direct<Mallet> d;
        double p[Mallet::kModelParams] = {0, hardness, 1, 0.3, 0.4, 0, 0, 1, 0};
        d.set(p);
        Mallet::Voice& v = d.start(64, 0.8);
        int samples = 0;
        float y;
        while (!v.contact.done && samples < 4800) d.m.render(v, &y, 1), d.finish(1), ++samples;
        return samples;
    };
    const int ty = touch(0.1), th = touch(0.95);
    if (verbose()) std::printf("mallet contact: yarn %d, hard %d samples\n", ty, th);
    CHECK(ty > 3 * th);
    // The electric piano: a harder blow on the tine excites more of its bell modes.
    const Values ep = simOf(1, {{"space", 0}, {"noises", 0}, {"bark", 0}});
    const double ps = highShareDb(note(ep, 60, 0.2, -1, 0.3), 0, 4800, 48000, 1500), pl = highShareDb(note(ep, 60, 1.0, -1, 0.3), 0, 4800, 48000, 1500);
    if (verbose()) std::printf("tine bell share: pp %.1f, ff %.1f dB\n", ps, pl);
    CHECK(pl > ps + 3);
}

TEST(timber_sim_epiano_action_and_dampers_are_heard_by_the_noises_knob) {
    // The action's thunk at the strike and the damper felt at the release, at the `noises` level: they add low
    // energy at the attack and after the release, and nothing at 0.
    const Values quiet = simOf(1, {{"space", 0}, {"noises", 0}, {"tremolo", 0}}), close = simOf(1, {{"space", 0}, {"noises", 1}, {"tremolo", 0}});
    const std::vector<float> a = note(quiet, 72, 0.9, 0.3, 0.5), b = note(close, 72, 0.9, 0.3, 0.5);
    double dAttack = 0, dRelease = 0;
    for (size_t i = 0; i < 2400; ++i) dAttack += (a[i] - b[i]) * (a[i] - b[i]);
    for (size_t i = 14400; i < 15000; ++i) dRelease += (a[i] - b[i]) * (a[i] - b[i]);
    if (verbose()) std::printf("epiano noises: attack %.3g, release %.3g\n", dAttack, dRelease);
    CHECK(dAttack > 1e-6);
    CHECK(dRelease > 1e-8);
}

// ---------- Organ ----------

TEST(timber_sim_organ_click_comes_from_its_contacts_and_only_the_attack_changes) {
    // Hard contacts switch each wheel on where it is: more high energy in the first 4 ms than soft ones; after
    // the contacts settle, the tone is the 1.1.0 organ's to the bit (the same wheels, phases and gain).
    auto take = [](const Values& v) {
        auto p = make(v);
        return play(*p, v, {{0.0, -1, 60, 0.8}}, 0.1).mono();
    };
    const Values base = {{"space", 0}, {"rotary", 0}, {"vibrato", 0}, {"drive", 0}};
    Values hard = simOf(2, base), soft = simOf(2, base), classic = withModel(2, base);
    hard.emplace_back("click", 1.0), soft.emplace_back("click", 0.0), classic.emplace_back("click", 0.0);
    const std::vector<float> h = take(hard), s = take(soft), c = take(classic);
    const double hs = highShareDb(h, 0, 192, 48000, 3000), ss = highShareDb(s, 0, 192, 48000, 3000);
    if (verbose()) std::printf("organ attack share over 3 kHz: hard %.1f, soft %.1f dB\n", hs, ss);
    CHECK(hs > ss + 6);
    bool equal = true;
    for (size_t i = 960; i < h.size(); ++i) equal = equal && s[i] == c[i];
    CHECK(equal);
}
