// The built-in C++ instruments (#157) and the Library kernels they share: listing, timing, drums, mono glides, golden renders.
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "caw/instrument.hpp"
#include "caw/library/drums.hpp"
#include "caw/library/delay.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/oscillator.hpp"
#include "analysis.h"
#include "presets.h"
#include "engine.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

const char* const kInstruments[] = {"org.caw.drum.kick", "org.caw.drum.snare", "org.caw.drum.hats", "org.caw.drum.kit",
                                    "org.caw.synth.flagship"};
// The synths that became Flagship presets (2026-11-10, one synth): a test of one plays Flagship with its preset.
const char* const kRetired[] = {"org.caw.bass", "org.caw.synth.acid", "org.caw.synth.morph", "org.caw.synth.basic"};

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

// Plays `events` (frames from the start) through an activated instrument in 64-frame blocks; returns the left side.
// `values` overrides parameters by id; the rest keep their defaults.
std::vector<float> play(ModuleProcessor& p, const std::vector<Event>& events, uint32_t frames,
                        const std::vector<std::pair<std::string, double>>& values = {}, std::vector<float>* rightOut = nullptr) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    std::vector<float> out(frames), right(frames);
    float left[64], r[64];
    float* channels[2] = {left, r};
    const ChannelBufferView audio{channels, 2, 64};
    size_t next = 0;
    for (uint32_t start = 0; start < frames; start += 64) {
        const uint32_t n = std::min<uint32_t>(64, frames - start);
        std::vector<Event> block;
        while (next < events.size() && events[next].frame < start + n) {
            Event e = events[next++];
            e.frame -= start;
            block.push_back(e);
        }
        const EventInput in{block.data(), static_cast<uint32_t>(block.size())};
        ProcessBlock b;
        b.frames = n;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &in;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p.processPorts(b));
        for (uint32_t i = 0; i < n; ++i) {
            out[start + i] = left[i];
            right[start + i] = r[i];
        }
    }
    if (rightOut) *rightOut = right;
    return out;
}

// A retired synth's knob values as Flagship's (its preset and the knobs mapped), as the engine loads an old project.
std::vector<std::pair<std::string, double>> asFlagship(const char* id, std::vector<std::pair<std::string, double>> values) {
    std::string to = id;
    migrateLegacyInstrument(to, values);
    return values;
}

std::unique_ptr<ModuleProcessor> make(Engine& e, const char* id) {
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(isLegacyInstrument(id) ? "org.caw.synth.flagship" : id);
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 64));
    return p;
}

double energy(const std::vector<float>& v, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to && i < v.size(); ++i) s += static_cast<double>(v[i]) * v[i];
    return s;
}

// The frequency of a signal from its rising zero crossings over [from, to).
double frequency(const std::vector<float>& v, size_t from, size_t to, double sr = 48000) {
    size_t first = 0, last = 0, count = 0;
    for (size_t i = from + 1; i < to; ++i)
        if (v[i - 1] < 0.0f && v[i] >= 0.0f) {
            if (count == 0) first = i;
            last = i;
            ++count;
        }
    return count < 2 ? 0.0 : sr * static_cast<double>(count - 1) / static_cast<double>(last - first);
}

std::string pattern(const std::string& notes) { return "---\nkind: pattern\nname: P\nlength: 16\n---\n" + notes; }

uint64_t renderHash(const ProjectSpec& p, int64_t frames, float* peak) {
    Engine e(48000);
    if (!ok(e.setProjectOffline(p))) return 0;
    e.play();
    uint64_t h = 1469598103934665603ull;
    std::vector<float> l(256), r(256);
    for (int64_t done = 0; done < frames; done += 256) {
        e.process(l.data(), r.data(), 256);
        for (int i = 0; i < 256; ++i)
            for (float v : {l[static_cast<size_t>(i)], r[static_cast<size_t>(i)]}) {
                if (peak) *peak = std::max(*peak, std::fabs(v));
                uint32_t bits = 0;
                std::memcpy(&bits, &v, 4);
                for (int k = 0; k < 4; ++k) {
                    h ^= (bits >> (8 * k)) & 0xFF;
                    h *= 1099511628211ull;
                }
            }
    }
    return h;
}

ComponentSpec effect(const std::string& id, std::vector<std::pair<std::string, double>> params = {}) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}

ProjectSpec track(const std::string& instrument, const std::string& notes, std::vector<std::pair<std::string, double>> params = {}) {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 1;
    p.seed = 7;
    p.master = 0.8;
    p.modules.push_back({"pat", pattern(notes), {}});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.pattern = "pat";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = instrument;
    l.instrument.params = std::move(params);
    p.layers.push_back(l);
    return p;
}

void checkGolden(const char* name, const ProjectSpec& p, uint64_t golden) {
    float peak = 0;
    const uint64_t h = renderHash(p, 48000 * 2, &peak);
    if (!(peak > 0.05f && peak <= 1.0f)) cawtest::fail(__FILE__, __LINE__, std::string(name) + ": peak out of range");
    if (h != golden) {
        char buf[128];
        std::snprintf(buf, sizeof buf, "%s renders 0x%016llxull", name, static_cast<unsigned long long>(h));
        cawtest::fail(__FILE__, __LINE__, buf);
    }
    if (renderHash(p, 48000 * 2, nullptr) != h) cawtest::fail(__FILE__, __LINE__, std::string(name) + ": a second engine differs");
}

}  // namespace

// ---------- Library kernels ----------

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

// ---------- Instruments ----------

TEST(the_built_in_instruments_are_listed_with_readable_names) {
    Engine e(48000);
    const std::string list = e.nativeComponentsJson();
    const char* names[] = {"Kick", "Snare", "Hi-hats", "Drum kit", "Flagship"};
    for (int i = 0; i < 5; ++i) {
        const size_t at = list.find(std::string("\"id\":\"") + kInstruments[i] + "\"");
        CHECK(at != std::string::npos);
        if (at == std::string::npos) continue;
        const size_t end = list.find("\"id\":\"org.caw.", at + 10);
        const std::string entry = list.substr(at, end == std::string::npos ? std::string::npos : end - at);
        CHECK(entry.find("\"role\":\"instrument\"") != std::string::npos);
        CHECK(entry.find(std::string("\"name\":\"") + names[i] + "\"") != std::string::npos);
    }
    // The retired synths are gone from the list; Flagship lists the presets that replace them.
    for (const char* id : kRetired) CHECK(list.find(std::string("\"id\":\"") + id + "\"") == std::string::npos);
    const size_t flagship = list.find("\"presets\":[{\"name\":\"Init\"");
    CHECK(flagship != std::string::npos);
    for (const char* name : {"Morph pad", "Mono bass", "Acid 303", "Basic"})
        CHECK(list.find(std::string("{\"name\":\"") + name + "\"", flagship) != std::string::npos);
}

TEST(each_built_in_instrument_starts_on_its_frame_and_falls_silent_after_its_note) {
    Engine e(48000);
    std::vector<const char*> ids(std::begin(kInstruments), std::end(kInstruments));
    ids.insert(ids.end(), std::begin(kRetired), std::end(kRetired));  // Flagship with each preset
    for (const char* id : ids) {
        std::unique_ptr<ModuleProcessor> p = make(e, id);
        if (!p) continue;
        const uint8_t key = std::strcmp(id, "org.caw.drum.kit") == 0 ? 36 : 45;
        const std::vector<Event> notes = {notes::noteOn(100, 1, key, 1.0), notes::noteOff(12100, 1, key)};
        const std::vector<float> out = play(*p, notes, 48000 * 6, asFlagship(id, {}));
        bool before = true;
        for (int i = 0; i < 100; ++i) before = before && out[static_cast<size_t>(i)] == 0.0f;
        if (!before) cawtest::fail(__FILE__, __LINE__, std::string(id) + " sounds before its note");
        const double e1 = energy(out, 100, 4900);
        if (!(e1 > 1e-3)) cawtest::fail(__FILE__, __LINE__, std::string(id) + " is silent after its note");
        bool after = true;
        for (size_t i = out.size() - 4800; i < out.size(); ++i) after = after && out[i] == 0.0f;
        if (!after) cawtest::fail(__FILE__, __LINE__, std::string(id) + " still sounds 5 s after its note ended");
        float peak = 0;
        for (float v : out) peak = std::max(peak, std::fabs(v));
        if (!(peak <= 1.0f)) cawtest::fail(__FILE__, __LINE__, std::string(id) + " clips at default settings");
        // reset() silences it at once.
        play(*p, {notes::noteOn(0, 2, key, 1.0)}, 640, asFlagship(id, {}));
        p->reset();
        const std::vector<float> quiet = play(*p, {}, 640, asFlagship(id, {}));
        if (energy(quiet, 0, 640) != 0.0) cawtest::fail(__FILE__, __LINE__, std::string(id) + " sounds after reset");
        p->deactivate();
    }
}

TEST(hats_are_closed_or_open_by_note_and_a_closed_hit_chokes_an_open_one) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> hats = make(e, "org.caw.drum.hats");
    if (!hats) return;
    const std::vector<float> closed = play(*hats, {notes::noteOn(0, 1, 42, 1)}, 24000);
    hats->reset();
    const std::vector<float> open = play(*hats, {notes::noteOn(0, 1, 46, 1)}, 24000);
    CHECK(energy(open, 4800, 9600) > 100.0 * energy(closed, 4800, 9600));  // A#2 rings, F#2 is short
    hats->reset();
    const std::vector<float> choked = play(*hats, {notes::noteOn(0, 1, 46, 1), notes::noteOn(4800, 2, 42, 0.01)}, 24000);
    CHECK(energy(choked, 9600, 14400) < 0.01 * energy(open, 9600, 14400));
    hats->reset();
    const std::vector<float> forced = play(*hats, {notes::noteOn(0, 1, 42, 1)}, 24000, {{"mode", 2}});  // Open
    CHECK(energy(forced, 4800, 9600) > 100.0 * energy(closed, 4800, 9600));
}

TEST(the_kit_maps_general_midi_keys_to_its_drums) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> kit = make(e, "org.caw.drum.kit");
    if (!kit) return;
    for (uint8_t key : {35, 36, 38, 39, 40, 42, 44, 46}) {
        kit->reset();
        const std::vector<float> out = play(*kit, {notes::noteOn(0, 1, key, 1)}, 4800);
        if (!(energy(out, 0, 4800) > 1e-3)) cawtest::fail(__FILE__, __LINE__, "kit key " + std::to_string(key) + " is silent");
    }
    for (uint8_t key : {37, 41, 60}) {
        kit->reset();
        const std::vector<float> out = play(*kit, {notes::noteOn(0, 1, key, 1)}, 4800);
        if (energy(out, 0, 4800) != 0.0) cawtest::fail(__FILE__, __LINE__, "kit key " + std::to_string(key) + " sounds");
    }
    // Each drum has its own level.
    kit->reset();
    const std::vector<float> muted = play(*kit, {notes::noteOn(0, 1, 36, 1)}, 4800, {{"kick", 0.0}});
    CHECK_EQ(energy(muted, 0, 4800), 0.0);
}

TEST(the_mono_and_acid_presets_glide_to_an_overlapping_note_and_back_when_it_ends) {
    Engine e(48000);
    for (const char* id : {"org.caw.synth.acid", "org.caw.bass"}) {
        std::unique_ptr<ModuleProcessor> p = make(e, id);
        if (!p) continue;
        // A1 (55 Hz) held; E2 (82.4 Hz) over it from 0.5 s to 1 s; then A1 alone again. A dark filter leaves the fundamental.
        const std::vector<Event> notes = {notes::noteOn(0, 1, 33, 1), notes::noteOn(24000, 2, 40, 1), notes::noteOff(48000, 2, 40),
                                          notes::noteOff(72000, 1, 33)};
        const bool acid = std::strcmp(id, "org.caw.synth.acid") == 0;
        const std::vector<std::pair<std::string, double>> dark =
            acid ? std::vector<std::pair<std::string, double>>{{"cutoff", 40}, {"resonance", 0}, {"env", 0}, {"drive", 1}}
                 : std::vector<std::pair<std::string, double>>{{"cutoff", 40}, {"resonance", 0}, {"env", 0}, {"sub", 0},
                                                               {"sustain", 1}, {"drive", 1}};
        const std::vector<float> out = play(*p, notes, 72000, asFlagship(id, dark));
        const double a = frequency(out, 12000, 24000), up = frequency(out, 36000, 48000), back = frequency(out, 60000, 72000);
        if (std::fabs(a - 55.0) > 1.5 || std::fabs(up - 82.41) > 1.5 || std::fabs(back - 55.0) > 1.5) {
            char buf[160];
            std::snprintf(buf, sizeof buf, "%s plays %.2f, %.2f, %.2f Hz", id, a, up, back);
            cawtest::fail(__FILE__, __LINE__, buf);
        }
        // Legato: the overlap did not restart the envelope (no new attack at 0.5 s, so no jump in level there).
        if (acid) {
            const double beforeE = energy(out, 22800, 24000), afterE = energy(out, 24000, 25200);
            CHECK(afterE < 3.0 * beforeE);
        }
    }
}

TEST(the_morph_pad_preset_spreads_its_unison_across_the_stereo_field) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e, "org.caw.synth.morph");
    if (!p) return;
    std::vector<float> right;
    const char* id = "org.caw.synth.morph";
    const std::vector<float> left = play(*p, {notes::noteOn(0, 1, 57, 1)}, 24000, asFlagship(id, {{"attack", 0.001}}), &right);
    double diff = 0;
    for (size_t i = 0; i < left.size(); ++i) diff += std::fabs(left[i] - right[i]);
    CHECK(diff > 1.0);  // wide
    p->reset();
    const std::vector<float> mono = play(*p, {notes::noteOn(0, 1, 57, 1)}, 24000, asFlagship(id, {{"attack", 0.001}, {"spread", 0}}), &right);
    for (size_t i = 0; i < mono.size(); ++i) CHECK_EQ(mono[i], right[i]);  // spread 0: both sides the same
    // One unison voice without detune or drift is a plain morph of the shape: at shape 0, a sine at the note's pitch.
    p->reset();
    const std::vector<float> sine =
        play(*p, {notes::noteOn(0, 1, 57, 1)}, 24000,
             asFlagship(id, {{"attack", 0.001}, {"unison", 1}, {"drift", 0}, {"shape", 0}, {"cutoff", 16000}}));
    CHECK_NEAR(frequency(sine, 4800, 24000), 220.0, 0.5);
}

namespace {

// The golden renders: a track per built-in instrument, and the effects and settings First loop uses.
struct Golden {
    const char* name;
    ProjectSpec project;
    uint64_t hash;
};

std::vector<Golden> goldens() {
    std::vector<Golden> g;
    // Kick: four on the floor with a pickup, tuned and driven.
    g.push_back({"kick", track("org.caw.drum.kick", "0 C2 1 1\n4 C2 1 0.8\n8 C2 1 1\n10 C2 1 0.6\n12 C2 1 1\n",
                               {{"tune", 52}, {"drive", 3}, {"click", 0.5}}),
                 0xc7641cbabbe0e3a3ull});
    // Snare: backbeat and a ghost roll.
    g.push_back({"snare", track("org.caw.drum.snare", "4 D2 1 1\n12 D2 1 1\n14 D2 1 0.4\n15 D2 1 0.6\n"), 0xb0184ce1843bca37ull});
    // Hats: 16ths, open on the off-beats' last 16th, choked by the next closed one.
    g.push_back({"hats", track("org.caw.drum.hats", "0 F#2 1 0.9\n1 F#2 1 0.5\n2 F#2 1 0.8\n3 F#2 1 0.5\n4 F#2 1 0.9\n"
                                                    "5 F#2 1 0.5\n6 A#2 1 0.8\n7 F#2 1 0.5\n8 F#2 1 0.9\n9 F#2 1 0.5\n"
                                                    "10 F#2 1 0.8\n11 F#2 1 0.5\n12 F#2 1 0.9\n13 F#2 1 0.5\n14 A#2 1 0.8\n15 F#2 1 0.5\n"),
                 0x7d07c25f99a0806full});
    // Kit: every drum, and a key it doesn't map.
    g.push_back({"kit", track("org.caw.drum.kit", "0 C2 1 1\n2 F#2 1 0.6\n4 D2 1 1\n4 D#2 1 0.7\n6 A#2 1 0.8\n8 C2 1 1\n"
                                                  "10 C#2 1 1\n11 B1 1 0.7\n12 E2 1 0.9\n14 G#2 1 0.6\n"),
                 0x15d9886e50243793ull});
    // The retired synths' projects (bass, acid, morph) play Flagship presets with their knobs mapped (one synth,
    // 2026-11-10): re-recorded then, perceptually the same as before (the_presets_sound_like_the_synths_they_replace).
    // Bass: First loop's line, an overlap that glides, a slide.
    g.push_back({"bass", track("org.caw.bass", "0 A1 1/2 1\n2 A1 1/2 1\n3 C2 1/2 1\n4 A2 1/2 1\n6 G1 1/2 1\n8 E2 2 1\n9 C2 2 0.8\n"
                                               "11 G1 1 1 slide\n12 A1 2 1\n15 A1 1/2 1\n",
                               {{"cutoff", 300}, {"resonance", 0.45}, {"env", 0.6}, {"decay", 0.18}, {"sustain", 0.3}}),
                 0xc08882e21c064997ull});
    // Acid: the Acid line pattern (slides, a ratchet, a note that plays half the time), squelchy.
    g.push_back({"acid", track("org.caw.synth.acid", "0 A1 2 1\n2 A2 1 0.7\n3 A1 1 0.8 slide\n4 C2 2 0.9\n6 A1 1 0.6 prob 0.5\n"
                                                     "8 E2 2 1 ratchet 2\n10 G1 1 0.7\n11 A1 1 0.8 slide\n12 A2 2 0.9\n14 G2 1 0.6\n15 E2 1 0.8\n",
                               {{"resonance", 0.8}, {"wave", 1}}),
                 0x1aa46f5e5c697003ull});
    // Morph synth: a chord with a quarter tone, drifting, wide.
    g.push_back({"morph", track("org.caw.synth.morph", "0 A3 8 0.8\n0 C4 8 0.8\n0 E4 8 0.8\n8 F3 6 0.7\n8 60.5 6 0.7\n8 C4 6 0.7\n",
                                {{"attack", 0.05}, {"release", 0.3}, {"shape", 0.6}, {"drift", 0.4}}),
                 0x5a0015830a00f7feull});
    // Flagship: its default patch (a warm, wide saw stack of seven, a ladder, env 2 on the cutoff) on a
    // chord, a line over it and a bent note. Re-recorded (2026-11-10 performance pass): the unwarped oscillator
    // reads its table with a 32-bit fixed-point phase (finer than the float one; perceptually the same).
    g.push_back({"flagship", track("org.caw.synth.flagship", "0 A3 8 0.8\n0 C4 8 0.8\n0 E4 8 0.8\n8 F3 6 0.7\n8 60.5 6 0.7\n"
                                                             "8 C4 6 0.7\n10 A4 1 1\n11 C5 1 0.9\n12 E5 3 0.8 bend 0:0 1:2\n"),
                 0x7f5e571711aaa4efull});
    return g;
}

// More sounds whose character must survive a faster implementation (perceptual references only, no hash):
// First loop's Pad, Lead and Acid tracks with their effects, the basic synth, and the Morph synth's extremes.
std::vector<Golden> references() {
    std::vector<Golden> g = goldens();
    const std::string chords = "0 A3,C4,E4 8 0.8\n8 F3,A3,C4 8 0.75\n";
    ProjectSpec pad = track("org.caw.synth.morph", chords);
    pad.layers[0].components = {effect("org.caw.chorus")};
    g.push_back({"pad + chorus", pad, 0});
    ProjectSpec lead = track("org.caw.synth.morph", "0 E4 2 0.9\n2 A4 2 0.8\n4 C5 3 0.9\n8 B4 2 0.8\n10 A4 2 0.7\n12 G4 4 0.8\n",
                             {{"shape", 0.66}, {"drift", 0.15}, {"unison", 3}, {"detune", 0.1}, {"cutoff", 2600},
                              {"attack", 0.005}, {"decay", 0.25}, {"sustain", 0.5}, {"release", 0.3}});
    lead.layers[0].components = {effect("org.caw.delay.pingpong", {{"sync", 3}, {"mix", 0.3}})};
    g.push_back({"lead + ping-pong", lead, 0});
    ProjectSpec acid = g[5].project;
    acid.layers[0].instrument.params = {{"resonance", 0.8}};
    acid.layers[0].components = {effect("org.caw.distortion", {{"drive", 3}, {"mix", 0.5}})};
    g.push_back({"acid + distortion", acid, 0});
    for (int shape = 1; shape < 4; ++shape) {
        ProjectSpec d = track("org.caw.synth.morph", "0 A1 4 1\n4 A3 4 1\n8 E5 4 1\n12 A6 4 1\n");
        d.layers[0].components = {effect("org.caw.distortion", {{"shape", static_cast<double>(shape)}, {"drive", 6}, {"bits", 6}})};
        g.push_back({shape == 1 ? "hard clip" : shape == 2 ? "fold" : "crush", d, 0});
    }
    g.push_back({"morph sine", track("org.caw.synth.morph", "0 A2 8 1\n8 A5 8 1\n",
                                     {{"unison", 1}, {"shape", 0}, {"drift", 0}, {"cutoff", 16000}}), 0});
    g.push_back({"morph bright square x16", track("org.caw.synth.morph", "0 A1 8 1\n8 A4,E5 8 1\n",
                                                  {{"unison", 16}, {"shape", 1}, {"drift", 0}, {"cutoff", 16000},
                                                   {"detune", 0.5}, {"attack", 0.001}}), 0});
    g.push_back({"morph saw sweep", track("org.caw.synth.morph", "0 C2,C3,G3,C4,E4,G4,C5,E5 16 1\n",
                                          {{"shape", 0.5}, {"drift", 1}, {"cutoff", 9000}, {"resonance", 0.6}}), 0});
    ProjectSpec basic = track("org.caw.synth.basic", "0 C3 4 1\n0 G3 4 0.8\n4 51 2 0.9 slide\n6 F3 2 0.9\n8 60.5 4 0.7 ratchet 3\n"
                                                     "12 60 4 0.6\n12 63 4 0.6\n12 67 4 0.6\n",
                              {{"wave2", 1}, {"cutoff", 1200}, {"resonance", 0.4}, {"release", 0.4}});
    g.push_back({"basic synth", basic, 0});
    return g;
}

// What a listener hears of a render, to compare two implementations of one sound: the level of each side, how
// alike the sides are, and the mid's spectral envelope (mean power in half-octave bands from 31.25 Hz to 16 kHz,
// averaged over 4096-frame Hann windows).
constexpr int kSoundBands = 19;
struct Sound {
    double rmsL = 0, rmsR = 0, correlation = 0;
    double bands[kSoundBands] = {};
};

Sound measure(const ProjectSpec& p, int64_t frames) {
    Sound s;
    Engine e(48000);
    if (!ok(e.setProjectOffline(p))) return s;
    e.play();
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t done = 0; done < frames; done += 256) e.process(l.data() + done, r.data() + done, 256);
    s.rmsL = analysis::levels(l.data(), l.size()).rmsDb;
    s.rmsR = analysis::levels(r.data(), r.size()).rmsDb;
    s.correlation = analysis::stereo(l.data(), r.data(), l.size()).correlation;
    constexpr size_t kN = 4096;
    double power[kN / 2] = {};
    int windows = 0;
    std::vector<std::complex<double>> d(kN);
    for (size_t at = 0; at + kN <= l.size(); at += kN / 2, ++windows) {
        for (size_t i = 0; i < kN; ++i) {
            const double w = 0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * static_cast<double>(i) / kN);
            d[i] = 0.5 * (static_cast<double>(l[at + i]) + r[at + i]) * w;
        }
        analysis::fft(d, false);
        for (size_t k = 0; k < kN / 2; ++k) power[k] += std::norm(d[k]);
    }
    for (int b = 0; b < kSoundBands; ++b) {
        const double lo = 31.25 * std::pow(2.0, (b - 0.5) / 2.0), hi = 31.25 * std::pow(2.0, (b + 0.5) / 2.0);
        double sum = 1e-30;
        for (size_t k = 1; k < kN / 2; ++k) {
            const double hz = static_cast<double>(k) * 48000.0 / kN;
            if (hz >= lo && hz < hi) sum += power[k];
        }
        s.bands[b] = 10.0 * std::log10(sum / std::max(1, windows));
    }
    return s;
}

// The renders before the faster implementations (2026-11-10: wavetable Morph synth, control-rate chorus LFO, fast
// saturation and sines), measured over 2 s by measure(). `CAW_PRINT_SOUNDS=1 caw_tests the_built_in_sounds` prints
// these rows for the current code.
struct Reference {
    const char* name;
    Sound sound;
};
#include "builtin_sounds_reference.inc"

// Perceptually the same (the owner's bar where bit-exactness costs real-time performance): each side's level within
// 0.5 dB, the sides' correlation within 0.05, and every band within 30 dB of the loudest within 1 dB (2.5 dB for the
// bands 30 to 50 dB down; quieter ones are not compared).
void checkSameSound(const char* name, const Sound& was, const Sound& now) {
    auto fail = [&](const std::string& what, double a, double b) {
        char buf[200];
        std::snprintf(buf, sizeof buf, "%s: %s was %.3f, now %.3f", name, what.c_str(), a, b);
        cawtest::fail(__FILE__, __LINE__, buf);
    };
    if (!(std::fabs(was.rmsL - now.rmsL) <= 0.5)) fail("left RMS dB", was.rmsL, now.rmsL);
    if (!(std::fabs(was.rmsR - now.rmsR) <= 0.5)) fail("right RMS dB", was.rmsR, now.rmsR);
    if (!(std::fabs(was.correlation - now.correlation) <= 0.05)) fail("correlation", was.correlation, now.correlation);
    double loudest = -1e9;
    for (double b : was.bands) loudest = std::max(loudest, b);
    for (int b = 0; b < kSoundBands; ++b) {
        const double down = loudest - was.bands[b];
        const double tolerance = down <= 30 ? 1.0 : down <= 50 ? 2.5 : 1e9;
        if (!(std::fabs(was.bands[b] - now.bands[b]) <= tolerance))
            fail("band " + std::to_string(static_cast<int>(31.25 * std::pow(2.0, b / 2.0))) + " Hz dB", was.bands[b], now.bands[b]);
    }
}

}  // namespace

TEST(the_built_in_instruments_render_the_same_at_any_block_size) {
    // Audio review fix 4: the 16-frame control grid (the built-in synths) and the expression grid (the host's
    // per-note pitch, pressure and timbre) restarted at every block and event split, so live playback (a
    // device's callback size) and an export differed. They now run on from block to block.
    auto render = [](const ProjectSpec& p, int block) {
        Engine e(48000);
        std::vector<float> out;
        if (!ok(e.setProjectOffline(p))) return out;
        e.play();
        std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
        for (int done = 0; done < 48000; done += block) {
            e.process(l.data(), r.data(), block);
            for (int i = 0; i < block; ++i) out.push_back(l[static_cast<size_t>(i)]), out.push_back(r[static_cast<size_t>(i)]);
        }
        out.resize(48000 * 2);
        return out;
    };
    const std::string expressive = "0 A3 6 0.9 bend 0:0 0.5:2 1:-1 vib 0.3 5.5 press 0:1 1:0.3 timbre 0:0 1:0.8\n"
                                   "2 C4 3 0.7 slide\n6 E4,G4 4 0.8 bend 0:0 1:-3\n10 C3 4 1\n12 D3 2 0.6 ratchet 3\n";
    std::vector<Golden> cases = goldens();
    for (const char* id : {"org.caw.synth.morph", "org.caw.synth.basic", "org.caw.bass", "org.caw.synth.acid"})
        cases.push_back({id, track(id, expressive, {{"attack", 0.002}}), 0});
    cases.push_back({"flagship expressive", track("org.caw.synth.flagship", expressive, {{"env1_attack", 0.002}}), 0});
    for (const Golden& g : cases) {
        const std::vector<float> a = render(g.project, 256), b = render(g.project, 37);
        size_t differ = 0;
        for (size_t i = 0; i < a.size() && i < b.size(); ++i) differ += a[i] != b[i];

        if (a.size() != b.size() || differ != 0)
            cawtest::fail(__FILE__, __LINE__, std::string(g.name) + ": " + std::to_string(differ) + " samples differ by block size");
    }
}

TEST(a_sleeping_component_renders_the_same_at_any_block_size) {
    // Second audio review, fix 1: a component put to sleep by its declared tail fell asleep on a block boundary
    // and froze there (a chorus's LFO, the acid synth's filter envelope), so after a pause it woke in another
    // state for each device buffer size, and playback no longer matched the export. Now only a component that
    // says it is quiet (and has nothing left running) sleeps. The Engine runs at most 64 frames at a time, so
    // only a callback size that is not a multiple of 64 moves the chunk boundaries: 37 and 100 do, 512 doesn't.
    // The basic synth stopped a released voice at the end of a render call, so it too ended on a block-dependent frame.
    auto render = [](const ProjectSpec& p, int block) {
        Engine e(48000);
        std::vector<float> out;
        if (!ok(e.setProjectOffline(p))) return out;
        e.play();
        std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
        for (int done = 0; done < 48000 * 4; done += block) {
            e.process(l.data(), r.data(), block);
            for (int i = 0; i < block; ++i) out.push_back(l[static_cast<size_t>(i)]), out.push_back(r[static_cast<size_t>(i)]);
        }
        out.resize(48000 * 4 * 2);
        return out;
    };
    std::vector<Golden> cases;
    // A short note, then most of a bar of silence (over 1 s): the chorus's input is silent far past its tail.
    ProjectSpec chorus = track("org.caw.synth.basic", "0 A3 1 0.8\n", {{"release", 0.02}});
    chorus.layers[0].components = {effect("org.caw.chorus")};
    cases.push_back({"basic + chorus", chorus, 0});
    // The synths that keep running through a gap: a released voice stops on the same frame at any block size.
    for (const char* id : {"org.caw.synth.basic", "org.caw.synth.morph"})
        cases.push_back({id, track(id, "0 A3 1 0.8\n6 C4 1/2 0.7\n", {{"release", 0.02}, {"decay", 0.05}}), 0});
    cases.push_back({"org.caw.bass", track("org.caw.bass", "0 A1 1 0.8\n6 C2 1/2 0.7\n"), 0});
    // Drums and the acid synth with gaps between hits: each falls quiet and sleeps in the gaps.
    cases.push_back({"kick", track("org.caw.drum.kick", "0 C2 1 1\n7 C2 1 0.8\n", {{"decay", 0.1}}), 0});
    cases.push_back({"snare", track("org.caw.drum.snare", "4 D2 1 1\n13 D2 1 0.6\n"), 0});
    cases.push_back({"hats", track("org.caw.drum.hats", "0 F#2 1 0.9\n6 A#2 1 0.8\n11 F#2 1 0.5\n"), 0});
    cases.push_back({"kit", track("org.caw.drum.kit", "0 C2 1 1\n5 D#2 1 0.7\n9 A#2 1 0.8\n14 D2 1 1\n"), 0});
    cases.push_back({"acid", track("org.caw.synth.acid", "0 A1 1/4 1\n5 C2 1/4 0.9\n11 A2 1/4 0.8\n", {{"decay", 1.0}}), 0});
    // The flagship falls quiet between notes (no voice, effects below -94 dB) and sleeps: dry, and with every
    // effect, a free LFO and the random source moving knobs (clocks that must stand still while it sleeps).
    const char* flagshipNotes = "0 A3 1/2 0.8\n6 C4 1/2 0.7\n";
    cases.push_back({"flagship dry", track("org.caw.synth.flagship", flagshipNotes, {{"env1_release", 0.02}}), 0});
    cases.push_back({"flagship + effects and LFOs",
                     track("org.caw.synth.flagship", flagshipNotes,
                           {{"env1_release", 0.05}, {"fx_chorus_on", 1}, {"fx_delay_on", 1}, {"fx_delay_feedback", 0.2},
                            {"fx_reverb_on", 1}, {"fx_reverb_decay", 0.3}, {"mod2_src", 4}, {"mod2_dst", 5}, {"mod2_amt", 0.5},
                            {"mod2_bipolar", 1}, {"lfo1_rate", 3.3}, {"mod3_src", 7}, {"mod3_dst", 3}, {"mod3_amt", 0.3}}),
                     0});
    for (const Golden& g : cases) {
        const std::vector<float> a = render(g.project, 64);
        for (int block : {37, 100, 512}) {
            const std::vector<float> b = render(g.project, block);
            size_t differ = 0;
            for (size_t i = 0; i < a.size() && i < b.size(); ++i) differ += a[i] != b[i];
            if (a.empty() || a.size() != b.size() || differ != 0)
                cawtest::fail(__FILE__, __LINE__, std::string(g.name) + ": " + std::to_string(differ) +
                                                      " samples differ between blocks of 64 and " + std::to_string(block));
        }
    }
}

TEST(a_note_held_at_sustain_zero_settles_instead_of_decaying_into_denormals) {
    // Audio review fix 7: the basic synth's level (and lib::Adsr's, which the bass and Morph synth use) fell
    // toward a sustain of 0 forever, through denormal numbers (slow on many CPUs). It now settles at 0.
    Engine e(48000);
    struct Case {
        const char* id;
        std::vector<std::pair<std::string, double>> values;
    };
    const Case cases[] = {{"org.caw.synth.basic", {{"sustain", 0}, {"decay", 0.01}}},
                          {"org.caw.synth.morph", {{"sustain", 0}, {"decay", 0.01}, {"attack", 0.001}}},
                          {"org.caw.bass", {{"sustain", 0}, {"decay", 0.02}}},
                          {"org.caw.synth.flagship", {{"env1_sustain", 0}, {"env1_decay", 0.01}, {"env1_attack", 0.001}, {"fx_reverb_on", 0}}}};
    for (const Case& c : cases) {
        std::unique_ptr<ModuleProcessor> p = make(e, c.id);
        if (!p) continue;
        std::vector<float> right;
        const std::vector<float> left = play(*p, {notes::noteOn(0, 1, 57, 1)}, 48000 * 4, asFlagship(c.id, c.values), &right);
        const analysis::Levels l = analysis::levels(left.data(), left.size());
        CHECK_EQ(l.denormal, 0u);
        CHECK_EQ(left.back(), 0.0f);  // silent while still held
    }
}

TEST(the_built_in_instruments_match_their_golden_renders) {
    for (const Golden& g : goldens()) checkGolden(g.name, g.project, g.hash);
}

TEST(the_built_in_sounds_are_perceptually_what_they_were) {
    const bool print = std::getenv("CAW_PRINT_SOUNDS") != nullptr;
    for (const Golden& g : references()) {
        const Sound now = measure(g.project, 48000 * 2);
        if (print) {
            std::printf("    {\"%s\", {%.4f, %.4f, %.5f, {", g.name, now.rmsL, now.rmsR, now.correlation);
            for (int b = 0; b < kSoundBands; ++b) std::printf("%s%.3f", b ? ", " : "", now.bands[b]);
            std::printf("}}},\n");
            continue;
        }
        const Reference* ref = nullptr;
        for (const Reference& r : kSoundReferences)
            if (std::strcmp(r.name, g.name) == 0) ref = &r;
        if (!ref) {
            cawtest::fail(__FILE__, __LINE__, std::string(g.name) + ": no reference");
            continue;
        }
        checkSameSound(g.name, ref->sound, now);
    }
}

TEST(the_presets_sound_like_the_synths_they_replace) {
    // One synth (owner, 2026-11-10): the bass, acid, morph and basic synths became Flagship presets, which an old
    // project's tracks play with their knobs mapped. Each case is compared with the retired synth's own render
    // (kRetiredSynthReferences). The mono and two-oscillator ones (bass, acid, basic, a one-copy sine) are
    // perceptually the same by the owner's bar (checkSameSound). The unison ones start each copy at a random
    // phase, which neither synth repeats, so a 2 s render moves by about as much between two runs of the old
    // synth itself (a phase seed shifted, docs/performance.md): their bar is each side's level within 1.2 dB,
    // the correlation within 0.07 and the bands within 30 dB of the loudest within 2 dB RMS. The bright square
    // through 16 kHz is not compared band by band: the old synth's polyBLEP square aliased, Flagship's band-limited
    // tables don't, so it lacks the old aliases between the harmonics (up to 9 dB at 88 Hz).
    for (const Golden& g : references()) {
        const Reference* was = nullptr;
        for (const Reference& r : kRetiredSynthReferences)
            if (std::strcmp(r.name, g.name) == 0) was = &r;
        if (!was) continue;
        const Sound now = measure(g.project, 48000 * 2);
        const std::string name = g.name;
        if (name == "bass" || name == "acid" || name == "acid + distortion" || name == "basic synth" || name == "morph sine") {
            checkSameSound(g.name, was->sound, now);
            continue;
        }
        auto fail = [&](const char* what, double a, double b) {
            char buf[200];
            std::snprintf(buf, sizeof buf, "%s: %s was %.3f, now %.3f", g.name, what, a, b);
            cawtest::fail(__FILE__, __LINE__, buf);
        };
        if (!(std::fabs(was->sound.rmsL - now.rmsL) <= 1.2)) fail("left RMS dB", was->sound.rmsL, now.rmsL);
        if (!(std::fabs(was->sound.rmsR - now.rmsR) <= 1.2)) fail("right RMS dB", was->sound.rmsR, now.rmsR);
        if (!(std::fabs(was->sound.correlation - now.correlation) <= 0.07)) fail("correlation", was->sound.correlation, now.correlation);
        if (name == "morph bright square x16") continue;
        double loudest = -1e9, squares = 0;
        int bands = 0;
        for (double b : was->sound.bands) loudest = std::max(loudest, b);
        for (int b = 0; b < kSoundBands; ++b)
            if (loudest - was->sound.bands[b] <= 30) squares += std::pow(now.bands[b] - was->sound.bands[b], 2), ++bands;
        const double rms = std::sqrt(squares / std::max(1, bands));
        if (!(rms <= 2.0)) fail("band RMS difference dB", 0.0, rms);
    }
}
