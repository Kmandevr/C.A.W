// The flagship synth (#171) and its new Library kernels: unison layout, stacks, filters, the mod matrix, block sizes, silence.
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstdio>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "caw/instrument.hpp"
#include "caw/library/comb.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/formant.hpp"
#include "caw/library/oscillator.hpp"
#include "caw/library/unison.hpp"
#include "caw/library/wavetable.hpp"
#include "analysis.h"
#include "presets.h"
#include "caw.h"
#include "engine.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

constexpr const char* kId = "org.caw.synth.flagship";
using Values = std::vector<std::pair<std::string, double>>;

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

int paramIndex(const ModuleDescriptor& d, const std::string& id) {
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == id) return static_cast<int>(k);
    cawtest::fail(__FILE__, __LINE__, "no parameter " + id);
    return -1;
}

// A patch to measure pitches with: one sine copy, no filters, no effects, no modulation, a fast attack.
Values plain(Values extra = {}) {
    Values v = {{"osc1_frame", 0.0}, {"osc1_unison", 1},      {"flt1_on", 0},       {"fx_reverb_on", 0},
                {"mod1_src", 0},     {"env1_attack", 0.001}, {"env1_sustain", 1.0}, {"osc1_phase_rand", 0},
                {"osc1_spread", 0}};
    for (auto& e : extra) v.push_back(e);
    return v;
}

struct Stereo {
    std::vector<float> left, right;
};

// Plays `events` through an activated flagship in `block`-frame blocks with `values` over the defaults.
Stereo play(ModuleProcessor& p, const std::vector<Event>& events, uint32_t frames, const Values& values = {},
            uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = paramIndex(d, id);
        if (k >= 0) params[static_cast<size_t>(k)].value = v;
    }
    Stereo out;
    out.left.resize(frames);
    out.right.resize(frames);
    std::vector<float> l(block), r(block);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, block};
    size_t next = 0;
    for (uint32_t start = 0; start < frames; start += block) {
        const uint32_t n = std::min(block, frames - start);
        std::vector<Event> in;
        while (next < events.size() && events[next].frame < start + n) {
            Event e = events[next++];
            e.frame -= start;
            in.push_back(e);
        }
        const EventInput ev{in.data(), static_cast<uint32_t>(in.size())};
        ProcessBlock b;
        b.frames = n;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &ev;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p.processPorts(b));
        std::memcpy(out.left.data() + start, l.data(), n * sizeof(float));
        std::memcpy(out.right.data() + start, r.data(), n * sizeof(float));
    }
    return out;
}

std::unique_ptr<ModuleProcessor> make(Engine& e) {
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(kId);
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 512));
    return p;
}

// Power per bin of a Hann-windowed segment (bin k is k * 48000 / n Hz).
std::vector<double> spectrum(const std::vector<float>& x, size_t from, size_t n) {
    std::vector<std::complex<double>> d(n);
    for (size_t i = 0; i < n; ++i)
        d[i] = (0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * static_cast<double>(i) / n)) * x[from + i];
    analysis::fft(d, false);
    std::vector<double> p(n / 2);
    for (size_t k = 0; k < n / 2; ++k) p[k] = std::norm(d[k]);
    return p;
}
// The strongest bin within +-width Hz of hz, as a power.
double peakNear(const std::vector<double>& s, double hz, double width, size_t n) {
    const double binHz = 48000.0 / n;
    double best = 0;
    for (size_t k = static_cast<size_t>(std::max(1.0, (hz - width) / binHz)); k <= static_cast<size_t>((hz + width) / binHz) && k < s.size(); ++k)
        best = std::max(best, s[k]);
    return best;
}
double bandPower(const std::vector<double>& s, double lo, double hi, size_t n) {
    const double binHz = 48000.0 / n;
    double sum = 1e-30;
    for (size_t k = 1; k < s.size(); ++k)
        if (k * binHz >= lo && k * binHz < hi) sum += s[k];
    return sum;
}
// The frequency of the strongest bin in [lo, hi), refined by a parabola through it and its neighbours.
double peakHz(const std::vector<double>& s, double lo, double hi, size_t n) {
    const double binHz = 48000.0 / n;
    size_t best = 0;
    for (size_t k = 1; k + 1 < s.size(); ++k)
        if (k * binHz >= lo && k * binHz < hi && (best == 0 || s[k] > s[best])) best = k;
    if (best == 0) return 0;
    const double a = std::log(s[best - 1] + 1e-30), b = std::log(s[best] + 1e-30), c = std::log(s[best + 1] + 1e-30);
    const double shift = 0.5 * (a - c) / (a - 2 * b + c);
    return (best + shift) * binHz;
}

double hzOf(double pitch) { return 440.0 * std::pow(2.0, (pitch - 69.0) / 12.0); }

}  // namespace

// ---------- Library kernels ----------

TEST(unison_layout_spreads_copies_by_the_detune_curve_and_pans_mirror_pairs) {
    lib::UnisonVoice v[16];
    lib::UnisonSettings s;
    s.voices = 7;
    s.detune = 0.3;
    CHECK_EQ(lib::unisonLayout(s, v), 7);
    for (int i = 0; i < 7; ++i) CHECK_NEAR(v[i].semitones, 0.3 * (i / 3.0 - 1.0), 1e-12);  // even spacing
    s.power = 1.0;  // gathered near the centre: |x|^4, the outer copies stay at +-detune
    lib::unisonLayout(s, v);
    CHECK_NEAR(v[0].semitones, -0.3, 1e-12);
    CHECK_NEAR(v[6].semitones, 0.3, 1e-12);
    CHECK_NEAR(v[4].semitones, 0.3 * std::pow(1.0 / 3.0, 4.0), 1e-9);
    s.power = -1.0;  // pushed out: |x|^0.25
    lib::unisonLayout(s, v);
    CHECK_NEAR(v[4].semitones, 0.3 * std::pow(1.0 / 3.0, 0.25), 1e-9);
    CHECK_EQ(v[3].semitones, 0.0);
    // Spread 0 centres every copy; at 1 each mirror pair sits on opposite sides, alternating pair by pair.
    s.power = 0.0;
    for (int i = 0; i < 7; ++i) CHECK_EQ(v[i].pan, v[i].pan);
    lib::unisonLayout(s, v);
    for (int i = 0; i < 7; ++i) CHECK_EQ(v[i].pan, 0.0);
    s.spread = 1.0;
    lib::unisonLayout(s, v);
    CHECK_NEAR(v[0].pan, -1.0, 1e-12);
    CHECK_NEAR(v[6].pan, 1.0, 1e-12);
    CHECK_NEAR(v[1].pan, 2.0 / 3.0, 1e-12);
    CHECK_NEAR(v[5].pan, -2.0 / 3.0, 1e-12);
    CHECK_EQ(v[3].pan, 0.0);
    // The levels' squares sum to 1; blend 0 keeps only the centre, 1 only the others.
    double sum = 0;
    for (int i = 0; i < 7; ++i) sum += v[i].gain * v[i].gain;
    CHECK_NEAR(sum, 1.0, 1e-12);
    s.blend = 0.0;
    lib::unisonLayout(s, v);
    CHECK_NEAR(v[3].gain, 1.0, 1e-12);
    CHECK_EQ(v[0].gain, 0.0);
    s.blend = 1.0;
    lib::unisonLayout(s, v);
    CHECK_EQ(v[3].gain, 0.0);
    s.voices = 4;  // an even count: the middle two are the centre
    s.blend = 0.0;
    lib::unisonLayout(s, v);
    CHECK_NEAR(v[1].gain, std::sqrt(0.5), 1e-12);
    CHECK_NEAR(v[2].gain, std::sqrt(0.5), 1e-12);
    CHECK_EQ(v[0].gain, 0.0);
    // Stacks.
    CHECK_EQ(lib::unisonStackSemitones(lib::UnisonStack::Octave, 1), 12.0);
    CHECK_EQ(lib::unisonStackSemitones(lib::UnisonStack::TwoOctaves, 2), 24.0);
    CHECK_EQ(lib::unisonStackSemitones(lib::UnisonStack::Fifth, 3), 7.0);
    CHECK_EQ(lib::unisonStackSemitones(lib::UnisonStack::Major, 1), 4.0);
    CHECK_EQ(lib::unisonStackSemitones(lib::UnisonStack::Minor, 1), 3.0);
    CHECK_NEAR(lib::unisonStackSemitones(lib::UnisonStack::Harmonics, 2), 12.0 * std::log2(3.0), 1e-9);
    s.voices = 1;
    CHECK_EQ(lib::unisonLayout(s, v), 1);
    CHECK_EQ(v[0].semitones, 0.0);
    CHECK_EQ(v[0].gain, 1.0);
}

TEST(library_comb_formant_multimode_ladder_and_eq_respond_as_their_kinds) {
    // White noise through each filter; the power in bands shows its response.
    auto through = [](auto&& filter) {
        lib::Noise noise(5);
        std::vector<float> y(65536);
        for (float& v : y) v = static_cast<float>(filter(noise.next()));
        return spectrum(y, 0, 65536);
    };
    constexpr size_t n = 65536;
    // Comb at 500 Hz, feedback 0.9: peaks at 500, 1000, 1500 Hz, troughs between.
    lib::CombFilter comb;
    comb.prepare(48000, 20);
    comb.set(500, 0.9, 0.0);
    const std::vector<double> c = through([&](double x) { return comb.process(x); });
    for (double f : {500.0, 1000.0, 1500.0}) CHECK(bandPower(c, f - 20, f + 20, n) > 20 * bandPower(c, f + 230, f + 270, n));
    // Negative feedback: peaks at the odd multiples of 250 Hz.
    comb.clear();
    comb.set(500, -0.9, 0.0);
    const std::vector<double> odd = through([&](double x) { return comb.process(x); });
    CHECK(bandPower(odd, 230, 270, n) > 20 * bandPower(odd, 480, 520, n));
    // Formants: A has its first formant near 730 Hz, I near 270 Hz.
    lib::FormantFilter a, i;
    a.set(0.0, 1.0, 10.0, 48000);
    i.set(0.5, 1.0, 10.0, 48000);
    const std::vector<double> sa = through([&](double x) { return a.process(x); });
    const std::vector<double> si = through([&](double x) { return i.process(x); });
    CHECK(bandPower(sa, 680, 780, n) > 10 * bandPower(sa, 240, 300, n));
    CHECK(bandPower(si, 240, 300, n) > 10 * bandPower(si, 680, 780, n));
    // The ladder's modes around 1 kHz.
    lib::MultiLadder lp, hp, bp;
    for (lib::MultiLadder* l : {&lp, &hp, &bp}) l->set(1000, 0.0, 48000);
    const std::vector<double> sl = through([&](double x) { return lp.process<lib::LadderMode::LowPass>(x * 0.1); });
    const std::vector<double> sh = through([&](double x) { return hp.process<lib::LadderMode::HighPass>(x * 0.1); });
    const std::vector<double> sb = through([&](double x) { return bp.process<lib::LadderMode::BandPass>(x * 0.1); });
    CHECK(bandPower(sl, 100, 300, n) > 1000 * bandPower(sl, 8000, 10000, n));
    CHECK(bandPower(sh, 8000, 10000, n) > 1000 * bandPower(sh, 100, 300, n));
    CHECK(bandPower(sb, 800, 1200, n) / 400 > 10 * bandPower(sb, 8000, 10000, n) / 2000);
    CHECK(bandPower(sb, 800, 1200, n) / 400 > 10 * bandPower(sb, 50, 150, n) / 100);
    // EQ: +12 dB low shelf and -12 dB high shelf, mid untouched.
    lib::ThreeBandEq eq;
    eq.set(12.0, 0.0, -12.0, 1000.0, 48000);
    const std::vector<double> se = through([&](double x) { return eq.process(x); });
    const double mid = bandPower(se, 900, 1100, n) / 200;
    CHECK(bandPower(se, 40, 80, n) / 40 > 8 * mid);
    CHECK(bandPower(se, 12000, 16000, n) / 4000 < mid / 8);
}

TEST(wavetable_level_data_reads_what_read_reads) {
    lib::Wavetable t;
    t.prepare(2, 1024);
    double a[512];
    lib::sawHarmonics(a, 512);
    t.setFrameHarmonics(1, a, 512);
    for (int level = 0; level < t.levels(); ++level) {
        const float* d = t.levelData(1, level);
        CHECK(d != nullptr);
        if (!d) continue;
        const int m = t.levelSize(level);
        CHECK_EQ(d[m], d[0]);
        CHECK_EQ(t.read(1, level, 0.5), d[m / 2]);
    }
    CHECK(t.levelData(2, 0) == nullptr);
    CHECK(t.levelData(0, t.levels()) == nullptr);
}

// ---------- The instrument ----------

TEST(the_flagship_lists_its_parameters_grouped_by_section_with_good_descriptors) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    const ModuleDescriptor& d = p->descriptor();
    CHECK_EQ(d.id, std::string_view("org.caw.synth.flagship"));
    CHECK_EQ(d.name, std::string_view("Flagship"));
    CHECK_EQ(d.parameterCount, 209u);
    const char* prefixes[] = {"osc1_", "osc2_", "osc3_", "flt1_", "flt2_", "flt_", "env1_", "env2_", "env3_", "lfo1_",
                              "lfo2_", "lfo3_", "rnd_", "volume", "velocity", "bend_range", "fx_", "mod", "voice_mode", "glide"};
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        const ParameterDescriptor& q = d.parameters[k];
        bool grouped = false;
        for (const char* pre : prefixes) grouped = grouped || q.id.substr(0, std::strlen(pre)) == pre;
        if (!grouped) cawtest::fail(__FILE__, __LINE__, std::string(q.id) + " is in no section");
        CHECK(!q.name.empty());
        CHECK(q.defaultValue >= q.minimum && q.defaultValue <= q.maximum);
        const bool timeOrRate = q.unit == "s" || q.unit == "Hz";
        if (timeOrRate && q.curve != ParameterCurve::Exponential)
            cawtest::fail(__FILE__, __LINE__, std::string(q.id) + " is a time or rate on a linear knob");
        if (q.choiceCount) CHECK_EQ(q.maximum - q.minimum + 1, static_cast<double>(q.choiceCount));
    }
    // A slot's destination lists every parameter before the slots, by name (value k + 1 is parameter k).
    const ParameterDescriptor& dst = d.parameters[paramIndex(d, "mod1_dst")];
    CHECK_EQ(dst.choiceCount, static_cast<uint32_t>(paramIndex(d, "mod1_src")) + 1);
    CHECK_EQ(dst.choices[0], std::string_view("None"));
    CHECK_EQ(dst.choices[paramIndex(d, "flt1_cutoff") + 1], std::string_view("Filter 1 cutoff"));
    // The default: osc 1 on with seven copies, the others off.
    CHECK_EQ(d.parameters[paramIndex(d, "osc1_on")].defaultValue, 1.0);
    CHECK_EQ(d.parameters[paramIndex(d, "osc1_unison")].defaultValue, 7.0);
    CHECK_EQ(d.parameters[paramIndex(d, "osc2_on")].defaultValue, 0.0);
    CHECK_EQ(d.parameters[paramIndex(d, "osc3_on")].defaultValue, 0.0);
}

TEST(the_flagship_unison_detune_spreads_pitches_by_the_detune_and_its_power) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    constexpr size_t n = 32768;
    // Two copies 50 cents either side of A4.
    const Stereo two = play(*p, {notes::noteOn(0, 1, 69, 1)}, 48000, plain({{"osc1_unison", 2}, {"osc1_detune", 50}}));
    const std::vector<double> s = spectrum(two.left, 4800, n);
    CHECK_NEAR(peakHz(s, 400, 440, n), hzOf(68.5), 0.5);
    CHECK_NEAR(peakHz(s, 440, 480, n), hzOf(69.5), 0.5);
    CHECK(peakNear(s, 440, 3, n) < 0.01 * peakNear(s, hzOf(69.5), 3, n));  // nothing at the note itself
    // Three copies at power +1: the outer ones at +-100 cents, the middle one on the note.
    p->reset();
    const Stereo three = play(*p, {notes::noteOn(0, 1, 69, 1)}, 48000,
                              plain({{"osc1_unison", 3}, {"osc1_detune", 100}, {"osc1_detune_power", 1}}));
    const std::vector<double> t = spectrum(three.left, 4800, n);
    CHECK_NEAR(peakHz(t, 400, 430, n), hzOf(68), 0.5);
    CHECK_NEAR(peakHz(t, 430, 450, n), 440.0, 0.5);
    CHECK_NEAR(peakHz(t, 450, 480, n), hzOf(70), 0.5);
    // Five copies: the inner pair at (1/2)^(4^power) of the detune: (1/2)^2 at power 0.5, (1/2)^0.25 at -1.
    for (double power : {0.5, -1.0}) {
        p->reset();
        const Stereo five = play(*p, {notes::noteOn(0, 1, 69, 1)}, 96000,
                                 plain({{"osc1_unison", 5}, {"osc1_detune", 100}, {"osc1_detune_power", power}}));
        const std::vector<double> f = spectrum(five.left, 4800, 65536);
        const double inner = 100.0 * std::pow(0.5, std::pow(4.0, power));  // cents
        const double expect = hzOf(69 + inner / 100.0);
        CHECK_NEAR(peakHz(f, expect - 3, expect + 3, 65536), expect, 0.4);
    }
}

TEST(the_flagship_spread_widens_a_centred_patch) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    auto sideOverMid = [](const Stereo& s) {
        double side = 0, mid = 0;
        for (size_t i = 0; i < s.left.size(); ++i) {
            const double m = 0.5 * (s.left[i] + s.right[i]), d = 0.5 * (s.left[i] - s.right[i]);
            mid += m * m;
            side += d * d;
        }
        return side / mid;
    };
    // The default patch at spread 0 is exactly mono, filter and envelopes included (the reverb, which widens
    // anything, is off); at 1 it is wide.
    const std::vector<Event> chord = {notes::noteOn(0, 1, 57, 1), notes::noteOn(0, 2, 64, 0.8), notes::noteOff(24000, 1, 57),
                                      notes::noteOff(24000, 2, 64)};
    const Stereo narrow = play(*p, chord, 48000, {{"osc1_spread", 0}, {"fx_reverb_on", 0}});
    CHECK_EQ(sideOverMid(narrow), 0.0);
    p->reset();
    const Stereo wide = play(*p, chord, 48000, {{"osc1_spread", 1}, {"fx_reverb_on", 0}});
    CHECK(sideOverMid(wide) > 0.1);
    p->reset();
    const Stereo some = play(*p, chord, 48000, {{"osc1_spread", 0.3}, {"fx_reverb_on", 0}});
    CHECK(sideOverMid(some) > 0.0);
    CHECK(sideOverMid(some) < sideOverMid(wide));
}

TEST(the_flagship_stack_modes_play_their_intervals) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    constexpr size_t n = 32768;
    const double root = hzOf(57);  // A3, 220 Hz
    struct Case {
        int stack, copies;
        std::vector<double> semitones;
    };
    const Case cases[] = {{1, 2, {0, 12}},     {2, 3, {0, 12, 24}},  {3, 2, {0, 7}},
                          {4, 3, {0, 4, 7}},   {5, 3, {0, 3, 7}},    {6, 4, {0, 12, 19.019550008653873, 24}}};
    for (const Case& c : cases) {
        p->reset();
        const Stereo out = play(*p, {notes::noteOn(0, 1, 57, 1)}, 48000,
                                plain({{"osc1_unison", static_cast<double>(c.copies)}, {"osc1_detune", 0}, {"osc1_stack", static_cast<double>(c.stack)}}));
        const std::vector<double> s = spectrum(out.left, 4800, n);
        double loudest = 0;
        for (double st : c.semitones) loudest = std::max(loudest, peakNear(s, root * std::pow(2.0, st / 12.0), 3, n));
        for (double st : c.semitones) {
            const double hz = root * std::pow(2.0, st / 12.0);
            if (!(peakNear(s, hz, 3, n) > 0.1 * loudest))
                cawtest::fail(__FILE__, __LINE__, "stack " + std::to_string(c.stack) + " lacks " + std::to_string(hz) + " Hz");
            CHECK_NEAR(peakHz(s, hz - 5, hz + 5, n), hz, 0.5);
        }
        // Nothing else: a semitone above the root is empty.
        if (!(peakNear(s, root * std::pow(2.0, 1.0 / 12.0), 3, n) < 1e-4 * loudest))
            cawtest::fail(__FILE__, __LINE__, "stack " + std::to_string(c.stack) + " plays more than its intervals");
    }
}

TEST(the_flagship_filter_types_shape_a_saw_as_their_kinds) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    constexpr size_t n = 32768;
    // A2 (110 Hz) saw, one copy, filter 1 at 1 kHz.
    auto render = [&](Values extra) {
        Values v = plain({{"osc1_frame", 1.0 / 3.0}, {"flt1_on", 1}, {"flt1_cutoff", 1000}, {"flt1_resonance", 0.0}});
        for (auto& x : extra) v.push_back(x);
        p->reset();
        return spectrum(play(*p, {notes::noteOn(0, 1, 45, 1)}, 48000, v).left, 4800, n);
    };
    const std::vector<double> dry = render({{"flt1_on", 0}});
    auto gain = [&](const std::vector<double>& s, double lo, double hi) { return bandPower(s, lo, hi, n) / bandPower(dry, lo, hi, n); };
    for (int type : {0, 3}) {  // ladder and SVF low-pass
        const std::vector<double> s = render({{"flt1_type", static_cast<double>(type)}});
        CHECK(gain(s, 100, 400) > 0.5);
        CHECK(gain(s, 6000, 12000) < (type == 0 ? 1e-4 : 1e-2));  // 24 and 12 dB/octave
    }
    for (int type : {1, 4}) {  // high-pass
        const std::vector<double> s = render({{"flt1_type", static_cast<double>(type)}});
        CHECK(gain(s, 100, 120) < (type == 1 ? 1e-4 : 1e-2));
        CHECK(gain(s, 6000, 12000) > 0.5);
    }
    for (int type : {2, 5}) {  // band-pass
        const std::vector<double> s = render({{"flt1_type", static_cast<double>(type)}});
        CHECK(gain(s, 900, 1100) > 10 * gain(s, 100, 120));
        CHECK(gain(s, 900, 1100) > 10 * gain(s, 8000, 12000));
    }
    {  // notch: the harmonic nearest 1 kHz (990 Hz) drops out, its neighbours far less
        const std::vector<double> s = render({{"flt1_type", 6.0}, {"flt1_cutoff", 990}});
        CHECK(gain(s, 980, 1000) < 0.01);
        CHECK(gain(s, 200, 240) > 0.5);
        CHECK(gain(s, 4000, 6000) > 0.5);
    }
    {  // comb at 220 Hz: the even harmonics of 110 Hz ring, the odd ones between fall back
        const std::vector<double> s = render({{"flt1_type", 7.0}, {"flt1_cutoff", 220}, {"flt1_resonance", 1.0}});
        CHECK(peakNear(s, 440, 3, n) / peakNear(dry, 440, 3, n) > 30 * peakNear(s, 330, 3, n) / peakNear(dry, 330, 3, n));
    }
    {  // formant: A's first formant (730 Hz) against I's (270 Hz)
        const std::vector<double> a = render({{"flt1_type", 8.0}, {"flt1_morph", 0.0}});
        const std::vector<double> i = render({{"flt1_type", 8.0}, {"flt1_morph", 0.5}});
        CHECK(gain(a, 650, 800) > 4 * gain(a, 200, 350));
        CHECK(gain(i, 200, 350) > 4 * gain(i, 650, 800));
    }
    {  // two filters in series and in parallel: a low-pass after a high-pass keeps only between them
        const Values both = {{"flt1_type", 1.0}, {"flt1_cutoff", 500}, {"flt2_on", 1}, {"flt2_type", 0.0}, {"flt2_cutoff", 2000}};
        Values series = both;
        const std::vector<double> s = render(series);
        CHECK(gain(s, 100, 120) < 1e-3);
        CHECK(gain(s, 8000, 12000) < 1e-3);
        Values parallel = both;  // osc 1 to both filters, summed: lows and highs come back
        parallel.push_back({"flt_routing", 1});
        parallel.push_back({"osc1_dest", 2});
        const std::vector<double> q = render(parallel);
        CHECK(gain(q, 100, 120) > 0.3);
        CHECK(gain(q, 6000, 12000) > 0.3);
        Values bypass = both;  // bypass skips them
        bypass.push_back({"osc1_dest", 3});
        const std::vector<double> b = render(bypass);
        CHECK_NEAR(gain(b, 100, 120), 1.0, 0.05);
        CHECK_NEAR(gain(b, 6000, 12000), 1.0, 0.05);
    }
}

TEST(the_flagship_mod_matrix_moves_its_destinations) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    const ModuleDescriptor& d = p->descriptor();
    const double volume = paramIndex(d, "volume") + 1, pan = paramIndex(d, "osc1_pan") + 1, cutoff = paramIndex(d, "flt1_cutoff") + 1;
    const std::vector<Event> note = {notes::noteOn(0, 1, 57, 1)};
    const Stereo base = play(*p, note, 24000, plain());
    const double level = analysis::levels(base.left.data(), base.left.size()).rms;
    CHECK(level > 0.01);
    // Velocity (1 here) to the volume, -1: the volume's knob goes to 0.
    p->reset();
    const Stereo silent = play(*p, note, 24000, plain({{"mod1_src", 8}, {"mod1_dst", volume}, {"mod1_amt", -1}}));
    CHECK(analysis::levels(silent.left.data(), 24000).peak < 1e-6);
    // ... and +0.3: louder than the knob alone.
    p->reset();
    const Stereo louder = play(*p, note, 24000, plain({{"volume", 0.3}, {"mod1_src", 8}, {"mod1_dst", volume}, {"mod1_amt", 0.3}}));
    p->reset();
    const Stereo knob = play(*p, note, 24000, plain({{"volume", 0.3}}));
    CHECK_NEAR(analysis::levels(louder.left.data(), 24000).rms / analysis::levels(knob.left.data(), 24000).rms, 2.0, 0.02);
    // A bipolar LFO at 2 Hz on the pan: the level moves from side to side.
    p->reset();
    const Stereo swing = play(*p, note, 48000, plain({{"mod2_src", 4}, {"mod2_dst", pan}, {"mod2_amt", 1}, {"mod2_bipolar", 1}}));
    double leftFirst = 0, rightFirst = 0;
    for (size_t i = 0; i < 12000; ++i) leftFirst += swing.left[i] * swing.left[i], rightFirst += swing.right[i] * swing.right[i];
    CHECK(rightFirst > 3 * leftFirst);  // a sine rises first: right
    double leftSecond = 0, rightSecond = 0;
    for (size_t i = 12000; i < 24000; ++i) leftSecond += swing.left[i] * swing.left[i], rightSecond += swing.right[i] * swing.right[i];
    CHECK(leftSecond > 3 * rightSecond);
    // Env 2 on the cutoff (the default slot) opens a dark filter at the attack and closes as it decays.
    p->reset();
    const Values dark = {{"osc1_frame", 1.0 / 3.0}, {"osc1_unison", 1}, {"flt1_cutoff", 200}, {"fx_reverb_on", 0}, {"mod1_amt", 0.5},
                         {"env2_decay", 0.2}, {"env2_sustain", 0}};
    const Stereo swept = play(*p, note, 48000, dark);
    const std::vector<double> early = spectrum(swept.left, 0, 4096), late = spectrum(swept.left, 40000, 4096);
    CHECK(bandPower(early, 3000, 8000, 4096) > 100 * bandPower(late, 3000, 8000, 4096));
    // Two slots on one destination add up; a slot with no source does nothing.
    p->reset();
    const Stereo summed = play(*p, note, 24000, plain({{"volume", 0.3}, {"mod1_src", 8}, {"mod1_dst", volume}, {"mod1_amt", 0.15},
                                                        {"mod2_src", 8}, {"mod2_dst", volume}, {"mod2_amt", 0.15},
                                                        {"mod3_src", 0}, {"mod3_dst", cutoff}, {"mod3_amt", 1}}));
    CHECK_EQ(analysis::levels(summed.left.data(), 24000).rms, analysis::levels(louder.left.data(), 24000).rms);
}

TEST(the_flagship_renders_the_same_bits_at_any_block_size) {
    // Every part on: three oscillators with warps and stacks, both filters (comb, formant), the matrix with
    // free, synced and retriggered LFOs, the random source and per-note expression, and every effect.
    const Values busy = {
        {"osc2_on", 1}, {"osc2_table", 1}, {"osc2_frame", 0.55}, {"osc2_warp", 2}, {"osc2_warp_amt", 0.4}, {"osc2_unison", 4},
        {"osc2_stack", 3}, {"osc2_dest", 1}, {"osc3_on", 1}, {"osc3_table", 2}, {"osc3_frame", 0.3}, {"osc3_warp", 3},
        {"osc3_warp_amt", 0.6}, {"osc3_dest", 3}, {"osc1_warp", 1}, {"osc1_warp_amt", 0.5}, {"osc1_table", 3},
        {"flt2_on", 1}, {"flt2_type", 8}, {"flt2_morph", 0.4}, {"flt_routing", 1}, {"flt1_type", 7}, {"flt1_keytrack", 1},
        {"mod2_src", 4}, {"mod2_dst", 3}, {"mod2_amt", 0.4}, {"lfo1_sync", 4}, {"mod3_src", 5}, {"mod3_dst", 59},
        {"mod3_amt", -0.3}, {"lfo2_mode", 1}, {"lfo2_shape", 5}, {"mod4_src", 7}, {"mod4_dst", 32}, {"mod4_amt", 0.2},
        {"mod5_src", 11}, {"mod5_dst", 101}, {"mod5_amt", 0.2}, {"mod6_src", 12}, {"mod6_dst", 61}, {"mod6_amt", 0.3},
        {"mod7_src", 10}, {"mod7_dst", 8}, {"mod7_amt", 0.5}, {"mod7_bipolar", 1},
        {"fx_dist_on", 1}, {"fx_eq_on", 1}, {"fx_eq_low", 4}, {"fx_chorus_on", 1}, {"fx_delay_on", 1}, {"fx_delay_mix", 0.3}};
    const std::string expressive = "0 A3 6 0.9 bend 0:0 0.5:2 1:-1 vib 0.3 5.5 press 0:1 1:0.3 timbre 0:0 1:0.8\n"
                                   "2 C4 3 0.7 slide\n6 E4,G4 4 0.8 bend 0:0 1:-3\n10 C3 4 1\n12 D3 2 0.6 ratchet 3\n";
    auto project = [&](const Values& v) {
        ProjectSpec p;
        p.bpm = 128;
        p.loopBars = 1;
        p.seed = 3;
        p.master = 0.8;
        p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n" + expressive, {}});
        LayerSpec l;
        l.id = "t";
        l.name = "t";
        l.pattern = "pat";
        l.volume = 1.0;
        l.hasInstrument = true;
        l.instrument.id = kId;
        l.instrument.params = v;
        p.layers.push_back(l);
        return p;
    };
    auto render = [](const ProjectSpec& p, int block) {
        Engine e(48000);
        std::vector<float> out;
        if (!ok(e.setProjectOffline(p))) return out;
        e.play();
        std::vector<float> l(static_cast<size_t>(block)), r(static_cast<size_t>(block));
        for (int done = 0; done < 96000; done += block) {
            e.process(l.data(), r.data(), block);
            for (int i = 0; i < block; ++i) out.push_back(l[static_cast<size_t>(i)]), out.push_back(r[static_cast<size_t>(i)]);
        }
        out.resize(96000 * 2);
        return out;
    };
    for (const Values* v : {static_cast<const Values*>(nullptr), &busy}) {
        const ProjectSpec p = project(v ? *v : Values{});
        const std::vector<float> a = render(p, 64), b = render(p, 128), c = render(p, 512), d = render(p, 37);
        CHECK(!a.empty());
        size_t differ = 0;
        double energy = 0;
        for (size_t i = 0; i < a.size(); ++i) {
            differ += a[i] != b[i] || a[i] != c[i] || a[i] != d[i];
            energy += a[i] * a[i];
            if (!std::isfinite(a[i])) cawtest::fail(__FILE__, __LINE__, "a sample is not finite");
        }
        CHECK(energy > 1.0);
        if (differ) cawtest::fail(__FILE__, __LINE__, std::string(v ? "busy" : "default") + ": " + std::to_string(differ) + " samples differ by block size");
    }
}

TEST(the_flagship_falls_silent_after_release_and_says_so) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    CHECK(p->quiet());  // nothing played yet
    // Every effect on, a 2 s reverb: a note of 0.5 s; within 8 s the output is exactly 0 and the synth quiet.
    const Values all = {{"fx_dist_on", 1}, {"fx_eq_on", 1}, {"fx_chorus_on", 1}, {"fx_delay_on", 1}, {"fx_reverb_decay", 2.0}};
    const Stereo out = play(*p, {notes::noteOn(0, 1, 57, 1), notes::noteOff(24000, 1, 57)}, 48000 * 8, all);
    for (size_t i = 0; i < out.left.size(); ++i)
        if (!std::isfinite(out.left[i]) || !std::isfinite(out.right[i])) {
            cawtest::fail(__FILE__, __LINE__, "not finite");
            break;
        }
    CHECK(analysis::levels(out.left.data(), 24000).rms > 0.01);
    bool silent = true;
    for (size_t i = out.left.size() - 9600; i < out.left.size(); ++i) silent = silent && out.left[i] == 0.0f && out.right[i] == 0.0f;
    CHECK(silent);
    CHECK(p->quiet());
    // While held it is not quiet; a NaN parameter reads as its range's end and sounds finite.
    play(*p, {notes::noteOn(0, 2, 60, 1)}, 640);
    CHECK(!p->quiet());
    p->reset();
    CHECK(p->quiet());
    const Stereo weird = play(*p, {notes::noteOn(0, 3, 60, 1)}, 4800,
                              {{"flt1_cutoff", std::nan("")}, {"osc1_detune", std::nan("")}, {"mod1_amt", std::nan("")}});
    for (float v : weird.left) CHECK(std::isfinite(v));
}

TEST(the_flagship_voice_follows_pitch_bend_and_stops_at_its_highest_notes) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // A per-note pitch (a bend) moves the copies: A4 bent to B4.
    const Stereo bent = play(*p, {notes::noteOn(0, 1, 69, 1), notes::notePitch(4800, 1, 69, 71)}, 48000, plain());
    const std::vector<double> s = spectrum(bent.left, 9600, 32768);
    CHECK_NEAR(peakHz(s, 450, 520, 32768), hzOf(71), 0.5);
    // A note far above Nyquist with an octave stack is silent, not aliased.
    p->reset();
    const Stereo high = play(*p, {notes::noteOn(0, 1, 127, 1)}, 4800, plain({{"osc1_octave", 4}}));
    CHECK_EQ(analysis::levels(high.left.data(), 4800).peak, 0.0);
}

TEST(the_flagship_mono_and_legato_modes_play_one_voice_gliding_between_notes) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // A1 held, E2 over it from 0.5 s to 1 s, then A1 alone again: one voice, at the newest note's pitch.
    const std::vector<Event> notes = {notes::noteOn(0, 1, 33, 1), notes::noteOn(24000, 2, 40, 1), notes::noteOff(48000, 2, 40),
                                      notes::noteOff(72000, 1, 33)};
    for (double mode : {1.0, 2.0}) {
        p->reset();
        const Stereo out = play(*p, notes, 72000, plain({{"voice_mode", mode}, {"glide", 0.02}}));
        const std::vector<double> held = spectrum(out.left, 12000, 8192), over = spectrum(out.left, 36000, 8192),
                                  back = spectrum(out.left, 60000, 8192);
        CHECK_NEAR(peakHz(held, 30, 200, 8192), 55.0, 1.5);
        CHECK_NEAR(peakHz(over, 30, 200, 8192), 82.41, 1.5);
        CHECK(peakNear(over, 55.0, 2, 8192) < 0.01 * peakNear(over, 82.41, 2, 8192));  // A1 is not sounding too
        CHECK_NEAR(peakHz(back, 30, 200, 8192), 55.0, 1.5);
    }
    // Poly plays both. The glide: 5 ms after the second note the pitch is still on its way.
    p->reset();
    const Stereo poly = play(*p, notes, 48000, plain());
    const std::vector<double> both = spectrum(poly.left, 36000, 8192);
    CHECK(peakNear(both, 55.0, 2, 8192) > 0.3 * peakNear(both, 82.41, 2, 8192));
    // Mono restarts the envelopes at each note (an attack after a decay), legato does not.
    const Values decaying = {{"osc1_frame", 0.0}, {"osc1_unison", 1}, {"flt1_on", 0}, {"fx_reverb_on", 0}, {"mod1_src", 0},
                             {"env1_attack", 0.001}, {"env1_decay", 0.1}, {"env1_sustain", 0.1}, {"osc1_phase_rand", 0}};
    auto jump = [&](double mode) {
        p->reset();
        Values v = decaying;
        v.push_back({"voice_mode", mode});
        const Stereo s = play(*p, notes, 30000, v);
        return analysis::levels(s.left.data() + 24000, 2400).rms / analysis::levels(s.left.data() + 21600, 2400).rms;
    };
    CHECK(jump(1.0) > 3.0);
    CHECK(jump(2.0) < 1.5);
}

TEST(the_flagship_accent_and_a_slots_second_source_scale_its_amount) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    const ModuleDescriptor& d = p->descriptor();
    const double volume = paramIndex(d, "volume") + 1;
    // Accent (14) on the volume: nothing at velocity 0.7, all of it at 1. Velocity to level is off.
    auto level = [&](double velocity, Values extra) {
        p->reset();
        Values v = plain({{"volume", 0.3}, {"velocity", 0}});
        for (auto& x : extra) v.push_back(x);
        const Stereo s = play(*p, {notes::noteOn(0, 1, 57, static_cast<float>(velocity))}, 24000, v);
        return analysis::levels(s.left.data(), 24000).rms;
    };
    const Values accent = {{"mod1_src", 14}, {"mod1_dst", volume}, {"mod1_amt", 0.3}};
    CHECK_NEAR(level(0.7, accent) / level(0.7, {}), 1.0, 1e-6);
    CHECK_NEAR(level(1.0, accent) / level(1.0, {}), 2.0, 0.02);
    // The same slot scaled by velocity (8): at velocity 0.5 half the amount.
    const Values via = {{"mod1_src", 14}, {"mod1_dst", volume}, {"mod1_amt", 0.3}, {"mod1_via", 8}};
    CHECK_NEAR(level(1.0, via) / level(1.0, {}), 2.0, 0.02);
    const Values half = {{"mod1_src", 8}, {"mod1_dst", volume}, {"mod1_amt", 0.3}, {"mod1_via", 8}};
    CHECK_NEAR(level(0.5, half) / level(0.5, {}), 1.0 + 0.3 * 0.25 / 0.3, 0.02);
}

TEST(the_flagship_classic_table_plays_the_classic_shapes) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // Classic (4): frame 0 a sine, 1/3 a triangle (odd harmonics at 1/h^2), 1 a square (odd at 1/h).
    auto harmonics = [&](double frame) {
        p->reset();
        const Stereo s = play(*p, {notes::noteOn(0, 1, 57, 1)}, 24000, plain({{"osc1_table", 4}, {"osc1_frame", frame}}));
        const std::vector<double> sp = spectrum(s.left, 8000, 8192);
        return std::vector<double>{peakNear(sp, 220, 3, 8192), peakNear(sp, 440, 3, 8192), peakNear(sp, 660, 3, 8192)};
    };
    const std::vector<double> sine = harmonics(0), triangle = harmonics(1.0 / 3.0), square = harmonics(1);
    CHECK(sine[2] < 1e-3 * sine[0]);
    CHECK_NEAR(triangle[2] / triangle[0], 1.0 / 81.0, 0.003);  // powers
    CHECK_NEAR(square[2] / square[0], 1.0 / 9.0, 0.02);
    CHECK(square[1] < 1e-3 * square[0]);
}

TEST(flagship_presets_set_their_values_and_an_entry_names_one) {
    // Every preset names only Flagship's parameters, within their ranges.
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    const ModuleDescriptor& d = p->descriptor();
    CHECK_EQ(builtinPresets(kId).size(), 5u);
    for (const BuiltinPreset& preset : builtinPresets(kId))
        for (const auto& [id, v] : preset.values) {
            const int k = paramIndex(d, std::string(id));
            if (k < 0) continue;
            const ParameterDescriptor& q = d.parameters[k];
            if (!(v >= q.minimum && v <= q.maximum))
                cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + ": " + std::string(id) + " out of range");
        }
    // {"id": flagship, "preset": "Mono bass", "params": {...}}: the preset's values under the entry's own.
    std::string json = R"({"bpm":120,"loop_bars":1,"layers":[{"id":"t","name":"t","volume":1,
        "instrument":{"id":"org.caw.synth.flagship","preset":"Mono bass","params":{"flt1_cutoff":900}}}]})";
    ProjectSpec spec;
    std::string error;
    CHECK(parseProject(json, spec, error));
    const auto& params = spec.layers[0].instrument.params;
    auto value = [&](const char* id) {
        for (const auto& [k, v] : params)
            if (k == id) return v;
        return -1.0;
    };
    CHECK_EQ(value("voice_mode"), 2.0);
    CHECK_EQ(value("flt1_cutoff"), 900.0);
    CHECK(!parseProject(R"({"layers":[{"id":"t","instrument":{"id":"org.caw.synth.flagship","preset":"Nope"}}]})", spec, error));
    CHECK(error.find("Nope") != std::string::npos);
}

TEST(an_old_project_s_retired_synth_plays_as_flagship_with_its_preset_and_knobs) {
    // An old project naming org.caw.bass renders exactly as Flagship with the Mono bass preset and the old knobs
    // mapped, and its lanes move the knobs they map to.
    auto render = [](ProjectSpec p) {
        Engine e(48000);
        std::vector<float> out;
        const std::string result = e.setProjectOffline(p);
        if (!ok(result)) cawtest::fail(__FILE__, __LINE__, result);
        if (!ok(result)) return out;
        e.play();
        std::vector<float> l(256), r(256);
        for (int done = 0; done < 48000; done += 256) {
            e.process(l.data(), r.data(), 256);
            out.insert(out.end(), l.begin(), l.end());
        }
        return out;
    };
    ProjectSpec old;
    old.bpm = 120;
    old.loopBars = 1;
    old.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 A1 2 1\n2 C2 2 0.8\n4 E2 4 1\n", {}});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.pattern = "pat";
    l.hasInstrument = true;
    l.instrument.id = "org.caw.bass";
    l.instrument.params = {{"cutoff", 300}, {"env", 0.8}, {"legato", 0}};
    old.layers.push_back(l);
    ProjectAutomationLaneSpec lane;
    lane.targetType = "instrument";
    lane.moduleId = "t";
    lane.target = "cutoff";
    lane.points = {{0, 200}, {8, 2000}};
    old.automation.push_back(lane);
    ProjectAutomationLaneSpec gone = lane;
    gone.target = "env";  // no Flagship knob in its units: dropped
    old.automation.push_back(gone);
    ProjectSpec now = old;
    now.layers[0].instrument.id = kId;
    now.layers[0].instrument.params.clear();
    CHECK(applyBuiltinPreset(kId, "Mono bass", now.layers[0].instrument.params));
    auto set = [&](const char* id, double v) {
        for (auto& [k, x] : now.layers[0].instrument.params)
            if (k == id) x = v;
    };
    set("flt1_cutoff", 300);
    set("mod1_amt", 5.0 * 0.8 / 9.965784284662087);
    set("voice_mode", 1);
    now.automation = {lane};
    now.automation[0].target = "flt1_cutoff";
    const std::vector<float> a = render(old), b = render(now);
    CHECK(!a.empty());
    size_t first = 0;
    while (first < a.size() && first < b.size() && a[first] == b[first]) ++first;
    if (a.size() != b.size() || first != a.size())
        cawtest::fail(__FILE__, __LINE__, "the migrated project differs from frame " + std::to_string(first));
    CHECK(analysis::levels(a.data(), a.size()).rms > 1e-3);
    // The C API's migration gives the app the same entry, its preset's name and the lanes' knobs.
    char* json = caw_migrate_instrument(R"({"id":"org.caw.synth.acid","params":{"resonance":0.9,"slide":0.1}})");
    const std::string out = json;
    caw_free(json);
    CHECK(out.find("\"migrated\":true") != std::string::npos);
    CHECK(out.find("\"id\":\"org.caw.synth.flagship\"") != std::string::npos);
    CHECK(out.find("\"preset\":\"Acid 303\"") != std::string::npos);
    CHECK(out.find("\"flt1_resonance\":0.90000000000000002") != std::string::npos);
    CHECK(out.find("\"glide\":0.10000000000000001") != std::string::npos);
    CHECK(out.find("\"slide\":\"glide\"") != std::string::npos);
    char* other = caw_migrate_instrument(R"({"id":"org.caw.drum.kick","params":{"tune":50}})");
    CHECK(std::string(other).find("\"migrated\":false") != std::string::npos);
    caw_free(other);
    // An entry naming a preset comes back with the preset's values under its own (the app fills its knobs).
    char* named = caw_migrate_instrument(R"({"id":"org.caw.synth.flagship","preset":"Acid 303","params":{"glide":0.2}})");
    const std::string resolved = named;
    caw_free(named);
    CHECK(resolved.find("\"migrated\":false") != std::string::npos);
    CHECK(resolved.find("\"preset\":\"Acid 303\"") != std::string::npos);
    CHECK(resolved.find("\"glide\":0.20000000000000001") != std::string::npos);
    CHECK(resolved.find("\"voice_mode\":2") != std::string::npos);
    char* bad = caw_migrate_instrument(R"({"id":"org.caw.synth.flagship","preset":"Nope"})");
    CHECK(std::string(bad).find("\"ok\":false") != std::string::npos);
    caw_free(bad);
}
