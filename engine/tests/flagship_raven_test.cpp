// Flagship's 1.1.0 synthesis (Raven): oscillator interaction, spectral banks, LFO 4, macros and filter models, and old presets unchanged.
#include <algorithm>
#include <cmath>
#include <complex>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "caw/instrument.hpp"
#include "analysis.h"
#include "engine.h"
#include "presets.h"
#include "quality.h"
#include "test.h"
#include "tolerance.h"

using namespace caw;

namespace {

constexpr const char* kId = "org.caw.synth.flagship";
using Values = std::vector<std::pair<std::string, double>>;

struct Stereo {
    std::vector<float> l, r;
};

int index(const ModuleDescriptor& d, const std::string& id) {
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == id) return static_cast<int>(k);
    cawtest::fail(__FILE__, __LINE__, "no parameter " + id);
    return -1;
}

// An activated flagship; `offline` builds it as an export's render does (its banks built when first needed).
std::unique_ptr<ModuleProcessor> make(Engine& e, bool offline = true) {
    const BuildingOffline scope(offline);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(kId);
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 512));
    return p;
}

// `events` through p in blocks of the sizes in `blocks` (repeated), with `values` over the defaults.
Stereo play(ModuleProcessor& p, const std::vector<Event>& events, uint32_t frames, const Values& values,
            const std::vector<uint32_t>& blocks = {64}) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = index(d, id);
        if (k >= 0) params[static_cast<size_t>(k)].value = v;
    }
    Stereo out;
    out.l.resize(frames);
    out.r.resize(frames);
    const uint32_t most = *std::max_element(blocks.begin(), blocks.end());
    std::vector<float> l(most), r(most);
    float* channels[2] = {l.data(), r.data()};
    size_t next = 0, turn = 0;
    for (uint32_t start = 0, block = blocks[0]; start < frames; start += block, block = blocks[++turn % blocks.size()]) {
        const uint32_t n = std::min(block, frames - start);
        const ChannelBufferView audio{channels, 2, n};
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
        std::memcpy(out.l.data() + start, l.data(), n * sizeof(float));
        std::memcpy(out.r.data() + start, r.data(), n * sizeof(float));
    }
    return out;
}

// A chord held for a second, then released.
std::vector<Event> chord() {
    return {notes::noteOn(0, 1, 48, 0.9), notes::noteOn(100, 2, 55, 0.7), notes::noteOn(220, 3, 64, 1.0),
            notes::noteOff(48000, 1, 48), notes::noteOff(48000, 2, 55), notes::noteOff(48000, 3, 64)};
}

Values presetValues(std::string_view name) {
    for (const BuiltinPreset& p : builtinPresets(kId))
        if (p.name == name) {
            Values v;
            for (const auto& [k, x] : p.values) v.emplace_back(std::string(k), x);
            return v;
        }
    cawtest::fail(__FILE__, __LINE__, "no preset " + std::string(name));
    return {};
}

}  // namespace

// The presets Flagship had before 1.1.0 (and its defaults) render as they did: their references were recorded
// with the code before Raven's synthesis was added, so every appended parameter, warp, filter and source must leave
// them alone (stable: the difference below -120 dBFS; the stress suite's golden hashes check the bits).
TEST(flagship_s_presets_from_before_1_1_0_render_as_they_did) {
    Engine e(48000);
    cawtest::References refs("flagship");
    for (const char* name : {"Init", "Morph pad", "Mono bass", "Acid 303", "Basic", "Pluck", "FM bell"}) {
        std::unique_ptr<ModuleProcessor> p = make(e, false);
        if (!p) continue;
        const Stereo out = play(*p, chord(), 48000 * 3 / 2, presetValues(name));
        CHECK_REFERENCE(refs, std::string("preset ") + name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
    // Osc FM's ring, the fold and the FM warp from before (their default modulators).
    const Values oldWarps[] = {
        {{"osc2_on", 1}, {"osc2_warp", 7}, {"osc2_warp_amt", 0.4}, {"osc1_warp", 5}, {"osc1_warp_amt", 0.3}},
        {{"osc1_warp", 6}, {"osc1_warp_amt", 0.6}, {"osc3_on", 1}, {"osc3_warp", 2}, {"osc3_warp_amt", 0.5}},
    };
    int k = 0;
    for (const Values& v : oldWarps) {
        std::unique_ptr<ModuleProcessor> p = make(e, false);
        if (!p) continue;
        const Stereo out = play(*p, chord(), 48000, v);
        CHECK_REFERENCE(refs, "old warps " + std::to_string(k++), (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);
    }
}

namespace {

// Power per bin of a Hann-windowed segment of x (bin k is k * 48000 / n Hz).
std::vector<double> spectrum(const std::vector<float>& x, size_t from, size_t n) {
    std::vector<std::complex<double>> d(n);
    for (size_t i = 0; i < n; ++i)
        d[i] = (0.5 - 0.5 * std::cos(2.0 * 3.14159265358979323846 * static_cast<double>(i) / n)) * x[from + i];
    analysis::fft(d, false);
    std::vector<double> p(n / 2);
    for (size_t k = 0; k < n / 2; ++k) p[k] = std::norm(d[k]);
    return p;
}
// The strongest bin within +-width Hz of hz, in dB.
double peakDb(const std::vector<double>& s, double hz, double width, size_t n) {
    const double bin = 48000.0 / n;
    double best = 1e-30;
    for (size_t k = static_cast<size_t>(std::max(1.0, (hz - width) / bin)); k <= static_cast<size_t>((hz + width) / bin) && k < s.size(); ++k)
        best = std::max(best, s[k]);
    return 10.0 * std::log10(best);
}
double bandDb(const std::vector<double>& s, double lo, double hi, size_t n) {
    const double bin = 48000.0 / n;
    double sum = 1e-30;
    for (size_t k = 1; k < s.size(); ++k)
        if (k * bin >= lo && k * bin < hi) sum += s[k];
    return 10.0 * std::log10(sum);
}

// A plain test patch: osc 1 a sine of one copy, no filter, no effects, no slot, a flat envelope.
Values plainPatch(Values extra = {}) {
    Values v = {{"osc1_frame", 0.0}, {"osc1_unison", 1}, {"flt1_on", 0}, {"fx_reverb_on", 0}, {"mod1_src", 0},
                {"env1_attack", 0.001}, {"env1_sustain", 1.0}, {"osc1_phase_rand", 0}, {"osc1_spread", 0}, {"velocity", 0}};
    for (auto& e : extra) v.push_back(e);
    return v;
}
std::vector<Event> held(double pitch = 57) { return {notes::noteOn(0, 1, pitch, 1.0)}; }

// Every 1.1.0 mode in a busy patch (unison, a chord, a slot), for the finite, block-size and reference checks.
struct NewCase {
    std::string name;
    Values values;
};
const std::vector<NewCase>& newCases() {
    static const std::vector<NewCase> cases = [] {
        const Values busy = {{"osc1_unison", 5}, {"osc2_on", 1}, {"osc2_unison", 3}, {"osc2_semi", 7}, {"osc2_table", 1},
                             {"mod2_src", 4}, {"mod2_dst", 3}, {"mod2_amt", 0.3}, {"fx_reverb_on", 0}};
        auto with = [&](Values v) {
            Values x = busy;
            x.insert(x.end(), v.begin(), v.end());
            return x;
        };
        std::vector<NewCase> c = {
            {"osc rm from osc 2", with({{"osc1_warp", 8}, {"osc1_warp_amt", 0.8}, {"osc1_mod_src", 2}})},
            {"osc am from noise", with({{"osc1_warp", 9}, {"osc1_warp_amt", 0.6}, {"osc1_mod_src", 4}})},
            {"osc sync to osc 2", with({{"osc1_warp", 10}, {"osc1_warp_amt", 0.4}, {"osc1_mod_src", 2}, {"osc1_semi", 5}})},
            {"osc sync at eco-free full sweep", with({{"osc2_warp", 10}, {"osc2_warp_amt", 1.0}, {"osc2_mod_src", 1}})},
            {"osc fm from noise", with({{"osc1_warp", 7}, {"osc1_warp_amt", 0.3}, {"osc1_mod_src", 4}})},
            {"osc fm from osc 2", with({{"osc1_warp", 7}, {"osc1_warp_amt", 0.5}, {"osc1_mod_src", 2}})},
        };
        return c;
    }();
    return cases;
}

}  // namespace

TEST(flagship_osc_rm_multiplies_by_its_source_and_am_keeps_the_carrier) {
    Engine e(48000);
    const size_t n = 16384;
    // Osc 1 at 220 Hz times osc 2 at 329.6 Hz (silent itself: its level is 0, the copy it lends is before the level).
    const Values pair = plainPatch({{"osc2_on", 1}, {"osc2_unison", 1}, {"osc2_frame", 0.0}, {"osc2_semi", 7}, {"osc2_level", 0.0},
                                    {"osc2_phase_rand", 0}, {"osc2_spread", 0}, {"osc1_mod_src", 2}, {"osc1_warp_amt", 1.0}});
    const double f1 = 220.0, f2 = 220.0 * std::pow(2.0, 7.0 / 12.0);
    for (int am = 0; am < 2; ++am) {
        std::unique_ptr<ModuleProcessor> p = make(e);
        if (!p) return;
        Values v = pair;
        v.push_back({"osc1_warp", am ? 9.0 : 8.0});
        const Stereo out = play(*p, held(), 24000 + n, v);
        const std::vector<double> s = spectrum(out.l, 24000, n);
        const double carrier = peakDb(s, f1, 6, n), low = peakDb(s, f2 - f1, 6, n), high = peakDb(s, f2 + f1, 6, n);
        CHECK(std::fabs(low - high) < 1.0);  // the two side tones alike
        if (am) CHECK(carrier > low + 3.0);  // the carrier stays (at twice the side tones' amplitude)
        else CHECK(low > carrier + 40.0);     // ring: the carrier is gone
    }
}

TEST(flagship_osc_sync_locks_to_its_source_s_pitch) {
    Engine e(48000);
    const size_t n = 16384;
    // Osc 2 a sine 2.6 times osc 1's 110 Hz, synced to it: its partials move onto osc 1's harmonics.
    const Values base = plainPatch({{"osc1_level", 0.0}, {"osc2_on", 1}, {"osc2_unison", 1}, {"osc2_frame", 0.0},
                                    {"osc2_fine", 0.0}, {"osc2_octave", 1}, {"osc2_semi", 4}, {"osc2_phase_rand", 0},
                                    {"osc2_spread", 0}, {"osc2_mod_src", 1}, {"osc2_warp_amt", 1e-6}});
    const double f0 = 110.0, slave = 110.0 * std::pow(2.0, 16.0 / 12.0);
    std::unique_ptr<ModuleProcessor> free = make(e), synced = make(e);
    if (!free || !synced) return;
    const Stereo a = play(*free, held(45), 24000 + n, base);
    Values v = base;
    v.push_back({"osc2_warp", 10});
    const Stereo b = play(*synced, held(45), 24000 + n, v);
    const std::vector<double> sa = spectrum(a.l, 24000, n), sb = spectrum(b.l, 24000, n);
    CHECK(peakDb(sa, slave, 4, n) > peakDb(sa, 3 * f0, 4, n) + 30.0);  // free: its own pitch, between osc 1's harmonics
    CHECK(peakDb(sb, 3 * f0, 4, n) > peakDb(sb, slave, 4, n) + 20.0);  // synced: osc 1's harmonics
    CHECK(peakDb(sb, f0, 4, n) > peakDb(sb, slave, 4, n) + 10.0);      // the period is osc 1's
}

TEST(flagship_new_modes_stay_finite_and_bounded) {
    Engine e(48000);
    for (const NewCase& c : newCases()) {
        std::unique_ptr<ModuleProcessor> p = make(e);
        if (!p) continue;
        const Stereo out = play(*p, chord(), 48000 * 3 / 2, c.values);
        float peak = 0.0f;
        bool finite = true;
        for (size_t i = 0; i < out.l.size(); ++i) {
            finite = finite && std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
            peak = std::max(peak, std::max(std::fabs(out.l[i]), std::fabs(out.r[i])));
        }
        if (!finite || !(peak < 4.0f) || !(peak > 1e-3f))
            cawtest::fail(__FILE__, __LINE__, c.name + ": peak " + std::to_string(peak) + (finite ? "" : ", not finite"));
        const float tail = std::fabs(out.l.back()) + std::fabs(out.r.back());
        if (!(tail < 1e-3f)) cawtest::fail(__FILE__, __LINE__, c.name + ": still sounding after release");
    }
}

TEST(flagship_new_modes_render_the_same_at_any_block_size) {
    Engine e(48000);
    for (const NewCase& c : newCases()) {
        std::unique_ptr<ModuleProcessor> a = make(e), b = make(e);
        if (!a || !b) continue;
        const Stereo x = play(*a, chord(), 48000, c.values, {64});
        const Stereo y = play(*b, chord(), 48000, c.values, {1, 37, 64, 512});
        float worst = 0.0f;
        for (size_t i = 0; i < x.l.size(); ++i)
            worst = std::max(worst, std::max(std::fabs(x.l[i] - y.l[i]), std::fabs(x.r[i] - y.r[i])));
        if (!(worst <= 1e-6f)) cawtest::fail(__FILE__, __LINE__, c.name + ": blocks differ by " + std::to_string(worst));
    }
}

TEST(flagship_new_modes_match_their_reference_renders) {
    Engine e(48000);
    cawtest::References refs("flagship_raven");
    for (const NewCase& c : newCases()) {
        std::unique_ptr<ModuleProcessor> p = make(e);
        if (!p) continue;
        const Stereo out = play(*p, chord(), 48000, c.values);
        CHECK_REFERENCE(refs, c.name, (cawtest::Audio{out.l, out.r}), cawtest::Class::Stable);  // the noise is seeded
    }
}
