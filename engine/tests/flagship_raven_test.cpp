// Flagship's 1.1.0 synthesis (Raven): oscillator interaction, spectral banks, LFO 4, macros and filter models, and old presets unchanged.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <complex>
#include <cstring>
#include <memory>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include "caw/instrument.hpp"
#include "caw/library/wavetable.hpp"
#include "flagship_banks.h"
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
        // Osc FM (case 0) as the new modes' FM cases: chaotic (see flagship_new_modes_match_their_reference_renders).
        CHECK_REFERENCE(refs, "old warps " + std::to_string(k), (cawtest::Audio{out.l, out.r}),
                        k == 0 ? cawtest::Class::Chaotic : cawtest::Class::Stable);
        ++k;
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
        // The spectral and additive warps (11..18), each between two of its bank's amounts, with the frame moving.
        const char* names[] = {"stretch", "shift", "odd even", "formant", "smear", "disperse", "low high cut", "comb"};
        for (int m = 0; m < 8; ++m)
            c.push_back({std::string("spectral ") + names[m],
                         with({{"osc1_warp", 11.0 + m}, {"osc1_warp_amt", 0.45}, {"osc1_frame", 0.5}, {"mod3_src", 5},
                               {"mod3_dst", 3.0}, {"mod3_amt", 0.2}})});
        c.push_back({"additive table with a spectral warp",
                     with({{"osc1_table", 6}, {"osc1_frame", 0.3}, {"osc2_table", 6}, {"osc2_warp", 13}, {"osc2_warp_amt", 0.3}})});
        // LFO 4 (retriggered, on osc 1's frame) and two macros (on the warp amount and, scaled by velocity, the level).
        c.push_back({"lfo 4 and macros", with({{"lfo4_shape", 2}, {"lfo4_rate", 3.0}, {"lfo4_mode", 1}, {"mod4_src", 15},
                                               {"mod4_dst", 3.0}, {"mod4_amt", 0.4}, {"macro1", 0.7}, {"mod5_src", 16},
                                               {"mod5_dst", 12.0}, {"mod5_amt", 0.6}, {"osc1_warp", 1}, {"macro8", 0.5},
                                               {"mod6_src", 23}, {"mod6_via", 8}, {"mod6_dst", 4.0}, {"mod6_amt", -0.3}})});
        // The filter models (9..13), driven, resonant, their cutoff swept by the slot's LFO; both filters in parallel.
        const char* filters[] = {"diode lp", "sallen-key lp", "phaser", "comb negative", "vowel"};
        for (int f = 0; f < 5; ++f)
            c.push_back({std::string("filter ") + filters[f],
                         with({{"flt1_on", 1}, {"flt1_type", 9.0 + f}, {"flt1_resonance", f == 3 ? 0.8 : 1.0},
                               {"flt1_drive", 3.0}, {"flt1_morph", 0.6}, {"flt1_cutoff", 900}, {"mod3_src", 4},
                               {"mod3_dst", 60.0 /* flt1_cutoff + 1 */}, {"mod3_amt", 0.3}, {"flt2_on", 1}, {"flt2_type", 13.0 - f},
                               {"flt_routing", 1}, {"osc2_dest", 1}})});
        c.push_back({"harmonic table stretched", with({{"osc1_table", 3}, {"osc1_warp", 11}, {"osc1_warp_amt", 1.0}})});
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
        // Phase modulation by another oscillator turns the last bit's differences between builds' arithmetic (the
        // optimiser's reassociation, Arm64's fused multiply-adds) into audible-level noise far below the sound:
        // those cases match in loudness, spectrum and onsets; the rest null (the noise source is seeded).
        const bool fm = c.name.find("osc fm") != std::string::npos;
        CHECK_REFERENCE(refs, c.name, (cawtest::Audio{out.l, out.r}), fm ? cawtest::Class::Chaotic : cawtest::Class::Stable);
    }
}

// The banks' resynthesis: amount 0 of every bank is its table again (the FFT and the additive rebuild within -80 dB of
// the table's peak), and the frames of a table longer than 16 are resampled to 16.
TEST(flagship_spectral_banks_rebuild_their_tables_at_amount_zero) {
    lib::Wavetable t;
    t.prepare(4, 1024);
    double a[512];
    for (int f = 0; f < 4; ++f) {
        for (int h = 1; h <= 512; ++h) a[h - 1] = (f + 1.0) / (h * (1.0 + 0.1 * f * h));
        double ph[512];
        for (int h = 1; h <= 512; ++h) ph[h - 1] = 0.37 * h * f;
        t.setFrameHarmonics(f, a, 512, ph);
    }
    for (int mode = 0; mode < flagship::kSpectralModes; ++mode) {
        std::unique_ptr<flagship::Bank> b = flagship::buildBankNow(t, mode);
        CHECK(b != nullptr);
        if (!b) continue;
        CHECK_EQ(b->frames, 4);
        CHECK_EQ(b->table.frameCount(), 4 * flagship::kBankLevels);
        double worst = 0.0, peak = 0.0;
        for (int f = 0; f < 4; ++f)
            for (int level = 0; level < t.levels(); ++level) {
                const float* x = t.levelData(f, level);
                const float* y = b->table.levelData(f, level);
                for (int i = 0; i < t.levelSize(level); ++i) {
                    peak = std::max(peak, static_cast<double>(std::fabs(x[i])));
                    worst = std::max(worst, static_cast<double>(std::fabs(x[i] - y[i])));
                }
            }
        CHECK(20.0 * std::log10(worst / peak + 1e-30) < -80.0);
        // Every amount finite and as loud as its frame (within 0.5 dB, the RMS kept).
        for (int k = 0; k < b->table.frameCount(); ++k) {
            const float* y = b->table.levelData(k, 0);
            double sum = 0.0;
            for (int i = 0; i < 1024; ++i) sum += static_cast<double>(y[i]) * y[i];
            const float* x = t.levelData(k % 4, 0);
            double ref = 0.0;
            for (int i = 0; i < 1024; ++i) ref += static_cast<double>(x[i]) * x[i];
            CHECK(std::isfinite(sum));
            CHECK(std::fabs(10.0 * std::log10(sum / ref)) < 0.5);
        }
    }
    lib::Wavetable longer;
    longer.prepare(40, 1024);
    for (int f = 0; f < 40; ++f) {
        a[0] = 1.0;
        longer.setFrameHarmonics(f, a, 1);
    }
    std::unique_ptr<flagship::Bank> b = flagship::buildBankNow(longer, 0);
    CHECK(b && b->frames == flagship::kBankMaxFrames);
}

TEST(flagship_spectral_warps_shape_a_saw_as_their_kinds) {
    Engine e(48000);
    const size_t n = 16384;
    const double f0 = 110.0;
    // The Basic table's saw at 110 Hz. Amounts on a bank level (k / 7) read two frames, as an unwarped table does.
    const auto render = [&](int warp, double amount) {
        std::unique_ptr<ModuleProcessor> p = make(e);
        const Values v = plainPatch({{"osc1_frame", 1.0 / 3.0}, {"osc1_warp", static_cast<double>(warp)}, {"osc1_warp_amt", amount}});
        const Stereo out = play(*p, held(45), 24000 + n, v);
        return spectrum(out.l, 24000, n);
    };
    const std::vector<double> saw = render(0, 0.0);
    // Odd/even at 4/7: the even harmonics gone, the odd ones kept.
    const std::vector<double> odd = render(13, 4.0 / 7.0);
    CHECK(peakDb(odd, 2 * f0, 4, n) < peakDb(saw, 2 * f0, 4, n) - 50.0);
    CHECK(peakDb(odd, 4 * f0, 4, n) < peakDb(saw, 4 * f0, 4, n) - 50.0);
    CHECK(std::fabs(peakDb(odd, 3 * f0, 4, n) - peakDb(saw, 3 * f0, 4, n)) < 3.0);
    // Low/high cut at full: a band around the 16th harmonic, the fundamental and the top far down.
    const std::vector<double> band = render(17, 1.0);
    CHECK(peakDb(band, 16 * f0, 4, n) > peakDb(band, f0, 4, n) + 20.0);
    CHECK(peakDb(band, 16 * f0, 4, n) > bandDb(band, 64 * f0, 20000, n) + 10.0);
    // Stretch at full: harmonic h moves to 1 + 3 (h - 1), so the 2nd harmonic's place empties and the 4th fills.
    const std::vector<double> stretched = render(11, 1.0);
    CHECK(peakDb(stretched, 2 * f0, 4, n) < peakDb(stretched, 4 * f0, 4, n) - 40.0);
    // Comb at 2/7 (full depth, notches 6.3 harmonics apart from the fundamental): the 4th harmonic notched out.
    const std::vector<double> comb = render(18, 2.0 / 7.0);
    CHECK(peakDb(comb, 4 * f0, 4, n) - peakDb(comb, f0, 4, n) < peakDb(saw, 4 * f0, 4, n) - peakDb(saw, f0, 4, n) - 20.0);
    // Disperse and smear keep the level; every warp sounds.
    for (int w : {11, 12, 14, 15, 16}) {
        const std::vector<double> s = render(w, 0.6);
        CHECK(std::fabs(bandDb(s, 50, 20000, n) - bandDb(saw, 50, 20000, n)) < 3.0);
    }
}

TEST(flagship_spectral_banks_are_shared_and_built_off_the_audio_thread_live) {
    Engine e(48000);
    const Values v = plainPatch({{"osc1_frame", 1.0 / 3.0}, {"osc1_table", 1}, {"osc1_warp", 16}, {"osc1_warp_amt", 0.5}});
    // Offline: two instances, one bank.
    const int before = flagship::banksBuilt();
    std::unique_ptr<ModuleProcessor> a = make(e), b = make(e);
    if (!a || !b) return;
    const Stereo x = play(*a, held(), 4800, v);
    const Stereo y = play(*b, held(), 4800, v);
    CHECK_EQ(flagship::banksBuilt(), before + 1);
    CHECK(x.l == y.l);
    // Live: the first notes play unwarped while the worker builds the bank (here the Vocal table's, not built yet).
    Values w = v;
    w.push_back({"osc1_table", 2});
    std::unique_ptr<ModuleProcessor> live = make(e, false);
    std::unique_ptr<ModuleProcessor> reference = make(e);
    if (!live || !reference) return;
    const int have = flagship::banksBuilt();
    play(*live, held(), 64, w);  // asks for it
    for (int i = 0; i < 500 && flagship::banksBuilt() == have; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(10));
    CHECK_EQ(flagship::banksBuilt(), have + 1);
    live->reset();
    const Stereo l = play(*live, held(), 4800, w);
    const Stereo r = play(*reference, held(), 4800, w);
    CHECK(l.l == r.l);  // ready: the same as an offline render
}

TEST(flagship_lfo_4_and_the_macros_are_mod_sources) {
    Engine e(48000);
    const ModuleProcessor* probe = nullptr;
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    probe = p.get();
    const ModuleDescriptor& d = probe->descriptor();
    const ParameterDescriptor& src = d.parameters[index(d, "mod1_src")];
    CHECK_EQ(src.choiceCount, 24u);
    CHECK_EQ(src.choices[15], std::string_view("LFO 4"));
    CHECK_EQ(src.choices[16], std::string_view("Macro 1"));
    CHECK_EQ(src.choices[23], std::string_view("Macro 8"));
    // A macro at 1 moving osc 1's level (destination: the parameter's index + 1) by -1: silent; at 0, as without.
    const double level = index(d, "osc1_level") + 1.0;
    const auto rms = [&](Values v) {
        std::unique_ptr<ModuleProcessor> q = make(e);
        const Stereo out = play(*q, held(), 9600, plainPatch(v));
        double sum = 0;
        for (size_t i = 4800; i < out.l.size(); ++i) sum += static_cast<double>(out.l[i]) * out.l[i];
        return std::sqrt(sum / 4800);
    };
    const double plain = rms({});
    CHECK(plain > 0.05);
    CHECK(rms({{"mod1_src", 19}, {"mod1_dst", level}, {"mod1_amt", -1.0}, {"macro4", 1.0}}) < 1e-4);
    CHECK_NEAR(rms({{"mod1_src", 19}, {"mod1_dst", level}, {"mod1_amt", -1.0}, {"macro4", 0.0}}), plain, 1e-9);
    // LFO 4 as a square at 5 Hz on the level: the output swings at its rate (two loud and two quiet tenths a second).
    std::unique_ptr<ModuleProcessor> q = make(e);
    const Stereo out = play(*q, held(), 48000, plainPatch({{"lfo4_shape", 4}, {"lfo4_rate", 5.0}, {"mod1_src", 15},
                                                          {"mod1_dst", level}, {"mod1_amt", -0.8}, {"mod1_bipolar", 0}}));
    double lo = 1e9, hi = 0;
    for (int w = 0; w < 10; ++w) {
        double sum = 0;
        for (int i = 0; i < 2400; ++i) sum += std::fabs(out.l[4800 * w + 1200 + i]);
        lo = std::min(lo, sum), hi = std::max(hi, sum);
    }
    CHECK(hi > 3.0 * lo);
}

TEST(flagship_new_filter_models_shape_a_saw_as_their_kinds) {
    Engine e(48000);
    const size_t n = 16384;
    const auto render = [&](Values v) {
        std::unique_ptr<ModuleProcessor> p = make(e);
        Values x = plainPatch({{"osc1_frame", 1.0 / 3.0}, {"flt1_on", 1}});
        x.insert(x.end(), v.begin(), v.end());
        const Stereo out = play(*p, held(33), 24000 + n, x);  // a 55 Hz saw
        return spectrum(out.l, 24000, n);
    };
    const std::vector<double> dry = render({{"flt1_on", 0}});
    for (double type : {9.0, 10.0}) {  // the diode and Sallen-Key low-passes: the top cut, a peak at the cutoff
        const std::vector<double> soft = render({{"flt1_type", type}, {"flt1_cutoff", 1000}, {"flt1_resonance", 0.0}});
        CHECK(bandDb(soft, 8000, 16000, n) - bandDb(soft, 100, 400, n) < bandDb(dry, 8000, 16000, n) - bandDb(dry, 100, 400, n) - 30.0);
        const std::vector<double> ringing = render({{"flt1_type", type}, {"flt1_cutoff", 1000}, {"flt1_resonance", 0.9}});
        CHECK(bandDb(ringing, 850, 1150, n) - bandDb(ringing, 100, 400, n) > bandDb(soft, 850, 1150, n) - bandDb(soft, 100, 400, n) + 6.0);
    }
    // The phaser notches: at its deepest bin near the cutoff it is far below the dry saw's spectrum there.
    const std::vector<double> phased = render({{"flt1_type", 11}, {"flt1_cutoff", 1200}, {"flt1_resonance", 0.5}});
    double deepest = 0;
    for (double hz = 300; hz < 6000; hz += 55) deepest = std::min(deepest, peakDb(phased, hz, 3, n) - peakDb(dry, hz, 3, n));
    CHECK(deepest < -15.0);
    // The negative comb at 880 Hz rings odd multiples of 440 Hz, and dips at 880.
    const std::vector<double> comb = render({{"flt1_type", 12}, {"flt1_cutoff", 880}, {"flt1_resonance", 1.0}, {"flt1_morph", 0}});
    CHECK(peakDb(comb, 440, 4, n) - peakDb(dry, 440, 4, n) > peakDb(comb, 880, 4, n) - peakDb(dry, 880, 4, n) + 10.0);
    CHECK(peakDb(comb, 1320, 4, n) - peakDb(dry, 1320, 4, n) > peakDb(comb, 1760, 4, n) - peakDb(dry, 1760, 4, n) + 10.0);
    // The vowel keeps the body (the fundamental within 10 dB) and raises its A's first formant (730 Hz) over 1.5 kHz.
    const std::vector<double> vowel = render({{"flt1_type", 13}, {"flt1_cutoff", 1000}, {"flt1_resonance", 0.5}, {"flt1_morph", 0}});
    CHECK(std::fabs(peakDb(vowel, 55, 3, n) - peakDb(dry, 55, 3, n)) < 10.0);
    CHECK(peakDb(vowel, 715, 4, n) - peakDb(dry, 715, 4, n) > peakDb(vowel, 1540, 4, n) - peakDb(dry, 1540, 4, n) + 6.0);
}

TEST(flagship_s_1_1_0_presets_play_and_use_the_new_synthesis) {
    // Every preset after the 1.0 seven sounds (finite, bounded, not silent) and sets a 1.1.0 warp, filter, source,
    // table or parameter (but 1.1.3's three keys).
    Engine e(48000);
    const auto& all = builtinPresets(kId);
    CHECK(all.size() >= 7 + 12);
    for (size_t k = 7; k < all.size(); ++k) {
        const BuiltinPreset& preset = all[k];
        bool uses = false;
        for (const auto& [id, v] : preset.values) {
            const std::string s(id);
            uses = uses || (s.size() > 5 && s.substr(s.size() - 5) == "_warp" && v >= 8) ||
                   (s.size() > 5 && s.substr(s.size() - 5) == "_type" && s[0] == 'f' && v >= 9) ||
                   (s.size() > 4 && s.substr(s.size() - 4) == "_src" && v >= 15) || (s.substr(0, 4) == "lfo4") ||
                   (s.size() > 6 && s.substr(s.size() - 6) == "_table" && v == 6) || s.find("_mod_src") != std::string::npos;
        }
        // 1.1.3's keys (Timber's electric pianos and tonewheel organ, timber_migrate.cpp) use FM and plain sines: they
        // only have to play.
        const bool keys = preset.name == "Electric piano (tine)" || preset.name == "Electric piano (reed)" || preset.name == "Tonewheel organ";
        if (!uses && !keys) cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + " uses none of 1.1.0's synthesis");
        std::unique_ptr<ModuleProcessor> p = make(e);
        if (!p) continue;
        const Stereo out = play(*p, chord(), 48000, presetValues(preset.name));
        float peak = 0.0f;
        bool finite = true;
        for (size_t i = 0; i < out.l.size(); ++i) {
            finite = finite && std::isfinite(out.l[i]) && std::isfinite(out.r[i]);
            peak = std::max(peak, std::max(std::fabs(out.l[i]), std::fabs(out.r[i])));
        }
        if (!finite || !(peak > 0.01f) || !(peak < 2.0f))
            cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + ": peak " + std::to_string(peak));
    }
}

// 1.1.1: a slot on one of the choice lists 1.1.0 appended to (the oscillators' tables and warps, the filters' types)
// moves a saved patch's knob to the choice 1.0.9 moved it to. A slot moves a knob by a fraction of its travel, so
// the longer lists had sent an old patch's modulated filter type into the new comb, phaser and diode models (the
// owner's report: an old project playing echoes with no delay on the track). Velocity 1 is a source held at 1:
// knob + amount x the 1.0 list's last index, rounded and kept within that list, is what the patch must play.
TEST(a_slot_moves_an_old_patch_s_tables_warps_and_filter_types_as_1_0_9_did) {
    Engine e(48000);
    const std::vector<Event> note = {notes::noteOn(0, 1, 45, 1.0), notes::noteOff(24000, 1, 45)};
    auto moved = [&](const Values& patch, const std::string& target, double amount) {
        std::unique_ptr<ModuleProcessor> p = make(e, false);
        Values v = patch;
        if (p) {
            v.push_back({"mod2_src", 8});  // velocity
            v.push_back({"mod2_dst", index(p->descriptor(), target) + 1.0});
            v.push_back({"mod2_amt", amount});
            v.push_back({"mod2_bipolar", 0});
        }
        return p ? play(*p, note, 36000, v) : Stereo{};
    };
    auto plain = [&](const Values& patch) {
        std::unique_ptr<ModuleProcessor> p = make(e, false);
        return p ? play(*p, note, 36000, patch) : Stereo{};
    };
    auto same = [&](const Stereo& a, const Stereo& b, const std::string& what) {
        double diff = 0.0, ref = 0.0;
        for (size_t i = 0; i < a.l.size() && i < b.l.size(); ++i) {
            diff += (a.l[i] - b.l[i]) * (a.l[i] - b.l[i]) + (a.r[i] - b.r[i]) * (a.r[i] - b.r[i]);
            ref += b.l[i] * b.l[i] + b.r[i] * b.r[i];
        }
        const double db = 10.0 * std::log10(diff / std::max(ref, 1e-30) + 1e-30);
        if (a.l.empty() || !(ref > 0.0) || db > -120.0)
            cawtest::fail(__FILE__, __LINE__, what + ": " + std::to_string(db) + " dB from the 1.0.9 choice");
    };
    const Values low = {{"flt1_cutoff", 300.0}, {"flt1_resonance", 0.6}, {"fx_reverb_on", 0}};
    auto with = [&](Values v, std::initializer_list<std::pair<std::string, double>> more) {
        v.insert(v.end(), more.begin(), more.end());
        return v;
    };
    // Ladder LP + 7/8 of the travel: the comb (7 of 1.0's 0..8), not the phaser (11 of 0..13).
    same(moved(low, "flt1_type", 7.0 / 8.0), plain(with(low, {{"flt1_type", 7}})), "filter type up from Ladder LP");
    // The comb pushed past the list's end: the formant, 1.0's last (not the diode, the 1.1.0 type after it).
    same(moved(with(low, {{"flt1_type", 7}}), "flt1_type", 0.6), plain(with(low, {{"flt1_type", 8}})), "filter type past the end");
    // Filter 2 alike, down from the formant by 3 of its 8 steps.
    const Values both = with(low, {{"flt2_on", 1}, {"flt2_type", 8}, {"osc1_dest", 1}});
    same(moved(both, "flt2_type", -3.0 / 8.0), plain(with(low, {{"flt2_on", 1}, {"flt2_type", 5}, {"osc1_dest", 1}})),
         "filter 2 type down from the formant");
    // A table: Basic + 0.6 of 1.0's six is Harmonic (3), not Classic (4 of the seven with Additive).
    same(moved({}, "osc1_table", 0.6), plain({{"osc1_table", 3}}), "table");
    // A warp: Bend + 4/7 is FM (1 + 4 of 1.0's 0..7), not Odd/even (1 + 4/7 of 0..18, rounded: 13).
    const Values warped = {{"osc1_warp", 1}, {"osc1_warp_amt", 0.5}};
    same(moved(warped, "osc1_warp", 4.0 / 7.0), plain({{"osc1_warp", 5}, {"osc1_warp_amt", 0.5}}), "warp");
    // Past the end: Osc FM, 1.0's last, not Osc RM.
    same(moved(warped, "osc1_warp", 1.0), plain({{"osc1_warp", 7}, {"osc1_warp_amt", 0.5}}), "warp past the end");
}

// A knob on a 1.1.0 choice: the slot moves it over the whole list (nothing saved before 1.1.0 can be there).
TEST(a_slot_moves_a_1_1_0_choice_over_the_whole_list) {
    Engine e(48000);
    const std::vector<Event> note = {notes::noteOn(0, 1, 45, 1.0), notes::noteOff(24000, 1, 45)};
    auto render = [&](Values v) {
        std::unique_ptr<ModuleProcessor> p = make(e, false);
        return p ? play(*p, note, 36000, v) : Stereo{};
    };
    std::unique_ptr<ModuleProcessor> d = make(e, false);
    if (!d) return;
    const double dst = index(d->descriptor(), "flt1_type") + 1.0;
    // Diode LP (9) + 4/13 of the 14 types: Vowel (13).
    const Values base = {{"flt1_cutoff", 900.0}, {"flt1_resonance", 0.5}, {"fx_reverb_on", 0}};
    Values moved = base, vowel = base;
    moved.insert(moved.end(), {{"flt1_type", 9}, {"mod2_src", 8}, {"mod2_dst", dst}, {"mod2_amt", 4.0 / 13.0}});
    vowel.push_back({"flt1_type", 13});
    const Stereo a = render(moved), b = render(vowel);
    double diff = 0.0, ref = 0.0;
    for (size_t i = 0; i < a.l.size() && i < b.l.size(); ++i) diff += (a.l[i] - b.l[i]) * (a.l[i] - b.l[i]), ref += b.l[i] * b.l[i];
    CHECK(ref > 0.0);
    CHECK(diff <= ref * 1e-12);
}
