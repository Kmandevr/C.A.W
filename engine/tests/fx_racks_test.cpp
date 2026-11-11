// fx-racks: the FX rack and the multiband rack (flat split, band chains, latency, modulation, presets, block sizes).
#include <cmath>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "builtin_fx_racks.h"
#include "caw/library/filter.hpp"
#include "component_chain.h"
#include "module.h"
#include "presets.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

constexpr double kSr = 48000.0;

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

double hashOf(std::string_view id) { return static_cast<double>(rackChildHash(id)); }

ComponentSpec spec(std::string id, std::vector<std::pair<std::string, double>> params) {
    ComponentSpec s;
    s.id = std::move(id);
    s.params = std::move(params);
    return s;
}

std::unique_ptr<ComponentChain> chainOf(const ComponentSpec& s, std::string* why = nullptr) {
    std::string error;
    auto c = ComponentChain::build(registry(), {s}, kSr, error);
    if (why) *why = error;
    else if (!c) cawtest::fail(__FILE__, __LINE__, "the chain was refused: " + error);
    return c;
}

// A deterministic noise in -amp..amp.
std::vector<float> noise(size_t n, float amp, uint32_t seed = 1) {
    std::vector<float> v(n);
    uint32_t x = seed;
    for (auto& s : v) {
        x = x * 1664525u + 1013904223u;
        s = amp * (static_cast<float>(x >> 8) / 8388608.0f - 1.0f);
    }
    return v;
}

// Runs the chain over left/right (in place) in blocks of `block` frames (at most 64), the transport playing.
void render(ComponentChain& c, std::vector<float>& l, std::vector<float>& r, uint32_t block = 64) {
    ChainTime t;
    t.stepLength = kSr * 60.0 / 120.0 / 4.0;
    for (size_t at = 0; at < l.size();) {
        const uint32_t m = static_cast<uint32_t>(std::min<size_t>(block, l.size() - at));
        t.start = static_cast<int64_t>(at);
        c.process(l.data() + at, r.data() + at, m, kSr, &t);
        at += m;
    }
}

double rms(const std::vector<float>& v, size_t from = 0) {
    double s = 0.0;
    for (size_t i = from; i < v.size(); ++i) s += static_cast<double>(v[i]) * v[i];
    return std::sqrt(s / static_cast<double>(v.size() - from));
}

// The all-pass a Linkwitz-Riley crossover at hz leaves on the summed bands (low plus high).
struct AllPass {
    lib::Svf f;
    explicit AllPass(double hz) { f.set(hz, 0.70710678118654752, kSr); }
    double operator()(double x) {
        const lib::SvfOutput o = f.process(x);
        return o.notch - 1.41421356237309505 * o.band;
    }
};

}  // namespace

TEST(rack_child_hashes_are_24_bit_never_zero_and_unique_among_the_built_ins) {
    CHECK_EQ(rackChildHash("org.caw.filter"), rackChildHash("org.caw.filter"));
    // Pinned: the app's Dart (app/lib/model/racks.dart) computes the same numbers.
    CHECK_EQ(rackChildHash(""), (2166136261u >> 24) ^ (2166136261u & 0xFFFFFFu));
    std::vector<uint32_t> seen;
    for (const ModuleDescriptor* d : registry().builtinComponents()) {
        const uint32_t h = rackChildHash(d->id);
        CHECK(h > 0 && h < (1u << 24));
        for (uint32_t s : seen) CHECK(s != h);
        seen.push_back(h);
    }
}

TEST(rack_descriptors_are_valid_empty_and_filled) {
    for (std::string_view id : {kFxRackId, kMultibandRackId}) {
        const ModuleDescriptor* d = registry().find(id);
        CHECK(d != nullptr);
        if (!d) continue;
        CHECK(validateModuleDescriptor(*d) == ModuleValidation::Ok);
    }
    auto p = registry().create(kFxRackId);
    auto* rack = dynamic_cast<RackContainer*>(p.get());
    CHECK(rack != nullptr);
    std::string error;
    CHECK(rack->configure(registry(), {{"s1_fx", hashOf("org.caw.filter")}, {"s3_fx", hashOf("org.caw.eq")}}, false, error));
    const ModuleDescriptor& d = p->descriptor();
    CHECK(validateModuleDescriptor(d) == ModuleValidation::Ok);
    bool cutoff = false, eqBand = false, route = false;
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        cutoff = cutoff || d.parameters[k].id == "s1.cutoff";
        eqBand = eqBand || d.parameters[k].id == "s3.b1_freq";
        route = route || d.parameters[k].id == "mod16_bipolar";
    }
    CHECK(cutoff && eqBand && route);
}

TEST(racks_refuse_racks_and_unknown_effects_inside) {
    std::string why;
    CHECK(!chainOf(spec("org.caw.rack.fx", {{"s1_fx", hashOf("org.caw.rack.multiband")}}), &why));
    CHECK(why.find("nest") != std::string::npos);
    CHECK(!chainOf(spec("org.caw.rack.fx", {{"s1_fx", 12345}}), &why));
    CHECK(!chainOf(spec("org.caw.rack.multiband", {{"b1s1_fx", hashOf("org.caw.synth.flagship")}}), &why));
    ComponentSpec lenient = spec("org.caw.rack.fx", {{"s1_fx", 12345}});
    lenient.lenient = true;
    CHECK(chainOf(lenient) != nullptr);
}

TEST(multiband_bands_sum_flat_a_null_against_the_crossovers_all_passes) {
    for (int bands = 1; bands <= 5; ++bands) {
        const double hz[4] = {150.0, 900.0, 4000.0, 11000.0};
        auto c = chainOf(spec("org.caw.rack.multiband", {{"bands", bands}, {"xover1", hz[0]}, {"xover2", hz[1]},
                                                         {"xover3", hz[2]}, {"xover4", hz[3]}}));
        if (!c) continue;
        std::vector<float> l = noise(24000, 0.5f, 3), r = noise(24000, 0.5f, 4);
        std::vector<double> el(l.begin(), l.end()), er(r.begin(), r.end());
        for (int x = 0; x + 1 < bands; ++x) {
            AllPass al(hz[x]), ar(hz[x]);
            for (auto& v : el) v = al(v);
            for (auto& v : er) v = ar(v);
        }
        render(*c, l, r);
        double err = 0.0, ref = 0.0;
        for (size_t i = 0; i < l.size(); ++i) {
            err += (l[i] - el[i]) * (l[i] - el[i]) + (r[i] - er[i]) * (r[i] - er[i]);
            ref += el[i] * el[i] + er[i] * er[i];
        }
        const double nullDb = 10.0 * std::log10(err / ref + 1e-30);
        if (!(nullDb < -100.0)) cawtest::fail(__FILE__, __LINE__, "bands " + std::to_string(bands) + ": null " + std::to_string(nullDb) + " dB");
    }
}

TEST(multiband_runs_each_bands_own_chain_and_mutes_and_solos_bands) {
    // Two bands at 1 kHz; band 1 holds a utility at -60 dB. A 100 Hz tone all but vanishes, a 6 kHz one stays.
    auto tone = [](double hz) {
        std::vector<float> v(48000);
        for (size_t i = 0; i < v.size(); ++i) v[i] = static_cast<float>(0.5 * std::sin(2.0 * 3.14159265358979 * hz * i / kSr));
        return v;
    };
    auto run = [&](double hz, std::vector<std::pair<std::string, double>> extra) {
        std::vector<std::pair<std::string, double>> p = {{"bands", 2}, {"xover1", 1000.0},
                                                         {"b1s1_fx", hashOf("org.caw.utility")}, {"b1s1.gain", -60.0}};
        p.insert(p.end(), extra.begin(), extra.end());
        auto c = chainOf(spec("org.caw.rack.multiband", p));
        std::vector<float> l = tone(hz), r = tone(hz);
        if (c) render(*c, l, r);
        return rms(l, 24000) / (0.5 / std::sqrt(2.0));
    };
    CHECK(run(100.0, {}) < 0.01);
    CHECK_NEAR(run(6000.0, {}), 1.0, 0.02);
    CHECK(run(6000.0, {{"band2_mute", 1}}) < 0.01);
    CHECK(run(6000.0, {{"band1_solo", 1}}) < 0.01);
    CHECK_NEAR(run(100.0, {{"band1_bypass", 1}}), 1.0, 0.02);  // the band's chain bypassed
    CHECK_NEAR(run(6000.0, {{"band2_gain", -6.0206}}), 0.5, 0.01);
    CHECK(run(6000.0, {{"mix", 0.0}, {"band2_mute", 1}}) > 0.98);  // dry is the split summed, before any band control
}

TEST(rack_latency_adds_up_and_the_multiband_rack_keeps_its_bands_in_time) {
    const double limiter = hashOf("org.caw.limiter");
    auto fx = chainOf(spec("org.caw.rack.fx", {{"s1_fx", limiter}, {"s2_fx", limiter}, {"s3_fx", hashOf("org.caw.eq")}}));
    if (fx) CHECK_EQ(fx->latencyFrames(), 480u);
    auto off = chainOf(spec("org.caw.rack.fx", {{"s1_fx", limiter}, {"s2_fx", limiter}, {"s2_on", 0}}));
    if (off) CHECK_EQ(off->latencyFrames(), 240u);
    auto mb = chainOf(spec("org.caw.rack.multiband", {{"bands", 2}, {"b1s1_fx", limiter}, {"b1s1.ceiling", 0.0}}));
    if (!mb) return;
    CHECK_EQ(mb->latencyFrames(), 240u);
    auto plain = chainOf(spec("org.caw.rack.multiband", {{"bands", 2}}));
    // Quiet noise (far under the limiter's ceiling): the rack is its empty self, 240 frames later, in both bands.
    std::vector<float> l = noise(24000, 0.01f, 7), r = noise(24000, 0.01f, 8);
    std::vector<float> pl = l, pr = r;
    render(*mb, l, r);
    render(*plain, pl, pr);
    double err = 0.0, ref = 0.0;
    for (size_t i = 240; i < l.size(); ++i) {
        err += (l[i] - pl[i - 240]) * (l[i] - pl[i - 240]);
        ref += pl[i - 240] * pl[i - 240];
    }
    CHECK(10.0 * std::log10(err / ref + 1e-30) < -60.0);
}

TEST(fx_rack_modulates_an_inner_parameter_from_a_macro_and_an_lfo) {
    // A utility in slot 1; macro 1 moves its gain knob all the way down (-60 dB) over a unipolar route.
    auto build = [&](double macro, std::vector<std::pair<std::string, double>> extra = {}) {
        auto p = registry().create(kFxRackId);
        std::string error;
        dynamic_cast<RackContainer*>(p.get())->configure(registry(), {{"s1_fx", hashOf("org.caw.utility")}}, false, error);
        int dst = -1;
        for (uint32_t k = 0; k < p->descriptor().parameterCount; ++k)
            if (p->descriptor().parameters[k].id == "s1.gain") dst = static_cast<int>(k);
        std::vector<std::pair<std::string, double>> v = {{"s1_fx", hashOf("org.caw.utility")}, {"macro1", macro},
                                                         {"mod1_src", 10 /* Macro 1 */}, {"mod1_dst", dst + 1.0},
                                                         {"mod1_amt", -1.0}};
        v.insert(v.end(), extra.begin(), extra.end());
        return chainOf(spec("org.caw.rack.fx", v));
    };
    auto level = [&](ComponentChain* c) {
        std::vector<float> l = noise(24000, 0.5f), r = noise(24000, 0.5f, 2);
        if (c) render(*c, l, r);
        return rms(l, 4800);
    };
    const double dry = rms(noise(24000, 0.5f), 4800);
    CHECK_NEAR(level(build(0.0).get()) / dry, 1.0, 1e-3);
    CHECK(level(build(1.0).get()) / dry < 0.01);
    // Half the macro: the gain knob (-60..24 dB, at 0) half its travel down, to -42 dB.
    CHECK_NEAR(level(build(0.5).get()) / dry, std::pow(10.0, -42.0 / 20.0), 0.002);
}

TEST(a_whole_rack_saves_and_loads_as_one_set_of_values_and_state) {
    ComponentSpec s = spec("org.caw.rack.fx", {{"s1_fx", hashOf("org.caw.filter")}, {"s1.cutoff", 700.0},
                                               {"s2_fx", hashOf("org.caw.delay.pro")}, {"s2.mix", 0.4},
                                               {"lfo1_rate", 3.0}, {"mod1_src", 1}, {"mod1_amt", 0.3}});
    auto a = chainOf(s);
    if (!a) return;
    std::vector<float> l = noise(9600, 0.3f), r = noise(9600, 0.3f, 9);
    std::vector<float> l2 = l, r2 = r;
    // Point route 1 at the filter's cutoff by id, as the app does.
    std::vector<ComponentSpec> cur = a->currentSpecs();
    CHECK_EQ(cur.size(), 1u);
    CHECK_EQ(rackStructure(cur[0]), rackStructure(s));
    cur[0].lenient = false;
    std::string error;
    auto b = ComponentChain::build(registry(), cur, kSr, error);
    CHECK(b != nullptr);
    if (!b) return;
    CHECK(b->sameComponents({s}, kSr));
    render(*a, l, r);
    render(*b, l2, r2);
    CHECK(l == l2 && r == r2);
    // Every value came back, the children's included.
    bool cutoff = false;
    for (const auto& [k, v] : b->currentSpecs()[0].params)
        if (k == "s1.cutoff") cutoff = std::fabs(v - 700.0) < 1e-9;
    CHECK(cutoff);
    // The state (the children's states inside the rack's) loads back.
    const auto states = a->saveStates();
    CHECK(states[0].ok);
    ComponentSpec withState = s;
    withState.hasState = true;
    withState.state = states[0].data;
    withState.stateVersion = states[0].version;
    CHECK(chainOf(withState) != nullptr);
    // A changed slot is a new structure (the chain is rebuilt); a changed knob is not.
    ComponentSpec knob = s;
    knob.params.emplace_back("s1.cutoff", 2000.0);
    CHECK(a->sameComponents({knob}, kSr));
    ComponentSpec other = s;
    other.params.emplace_back("s2_fx", hashOf("org.caw.reverb.pro"));
    CHECK(!a->sameComponents({other}, kSr));
}

TEST(rack_factory_presets_build_and_sound) {
    for (std::string_view id : {kFxRackId, kMultibandRackId}) {
        const auto& presets = builtinPresets(id);
        CHECK(presets.size() >= 3);
        for (const BuiltinPreset& p : presets) {
            std::vector<std::pair<std::string, double>> values;
            CHECK(applyBuiltinPreset(id, p.name, values));
            for (const auto& [k, v] : values)
                if (k.size() > 4 && k.compare(k.size() - 4, 4, "_dst") == 0) CHECK(v > 0.0);  // every route found its knob
            auto c = chainOf(spec(std::string(id), values));
            if (!c) continue;
            std::vector<float> l = noise(9600, 0.3f), r = noise(9600, 0.3f, 5);
            render(*c, l, r);
            const double out = rms(l, 4800);
            if (!(out > 1e-3 && out < 2.0)) cawtest::fail(__FILE__, __LINE__, std::string(p.name) + " level " + std::to_string(out));
        }
    }
}

TEST(racks_give_the_same_bits_at_any_block_size) {
    const std::vector<ComponentSpec> specs = {
        spec("org.caw.rack.fx", {{"s1_fx", hashOf("org.caw.filter")}, {"s2_fx", hashOf("org.caw.saturator")},
                                 {"s3_fx", hashOf("org.caw.delay.pro")}, {"mod1_src", 1}, {"mod1_dst", 0},
                                 {"lfo1_rate", 5.0}, {"mod2_src", 5}, {"mod3_src", 9}}),
        spec("org.caw.rack.multiband", {{"bands", 4}, {"b1s1_fx", hashOf("org.caw.compressor")},
                                        {"b2s1_fx", hashOf("org.caw.limiter")}, {"b3s2_fx", hashOf("org.caw.chorus")},
                                        {"band3_pan", -0.5}})};
    for (ComponentSpec s : specs) {
        // Route 1 to the first child's first knob.
        if (s.id == kFxRackId) {
            auto p = registry().create(kFxRackId);
            std::string e;
            dynamic_cast<RackContainer*>(p.get())->configure(registry(), s.params, false, e);
            for (uint32_t k = 0; k < p->descriptor().parameterCount; ++k)
                if (p->descriptor().parameters[k].id == "s1.cutoff") s.params.emplace_back("mod1_dst", k + 1.0);
            for (uint32_t k = 0; k < p->descriptor().parameterCount; ++k)
                if (p->descriptor().parameters[k].id == "s2.drive") s.params.emplace_back("mod2_dst", k + 1.0);
            for (uint32_t k = 0; k < p->descriptor().parameterCount; ++k)
                if (p->descriptor().parameters[k].id == "s3.mix") s.params.emplace_back("mod3_dst", k + 1.0);
            s.params.emplace_back("mod1_amt", 0.4);
            s.params.emplace_back("mod2_amt", 0.3);
            s.params.emplace_back("mod3_amt", 0.2);
        }
        std::vector<float> ref;
        for (uint32_t block : {64u, 1u, 37u, 16u}) {
            auto c = chainOf(s);
            if (!c) break;
            std::vector<float> l = noise(19200, 0.4f), r = noise(19200, 0.4f, 6);
            for (size_t i = 6000; i < 9000; ++i) l[i] = r[i] = 0.0f;  // a gap: sleep and wake
            render(*c, l, r, block);
            if (ref.empty()) ref = l;
            else if (l != ref) cawtest::fail(__FILE__, __LINE__, s.id + " differs at block " + std::to_string(block));
        }
    }
}

TEST(a_racks_children_publish_display_data_through_the_rack) {
    auto c = chainOf(spec("org.caw.rack.multiband", {{"b2s1_fx", hashOf("org.caw.compressor")}}));
    if (!c) return;
    std::vector<float> l = noise(9600, 0.5f), r = noise(9600, 0.5f, 3);
    render(*c, l, r);
    float out[1024];
    CHECK(c->readDisplay(0, out, 1024) == 142);
    CHECK_EQ(out[2], 3.0f);
    CHECK(c->readDisplay(0 + (4 + 1) * 65536, out, 1024) == 11);  // b2s1: the compressor's block
    CHECK(c->readDisplay(0 + (0 + 1) * 65536, out, 1024) == 0);   // an empty slot
    CHECK(c->readDisplay(1 + 65536, out, 1024) == -1);
}

TEST(fx_rack_envelopes_follow_the_keys_notes) {
    // Env 1 (instant attack, full sustain) opens a utility's gain from -60 dB while a key note is held.
    auto p = registry().create(kFxRackId);
    std::string e;
    std::vector<std::pair<std::string, double>> v = {{"s1_fx", hashOf("org.caw.utility")}, {"s1.gain", -60.0},
                                                     {"env1_attack", 0.001}, {"env1_sustain", 1.0},
                                                     {"env1_release", 0.01}, {"mod1_src", 7}, {"mod1_amt", 0.7}};
    dynamic_cast<RackContainer*>(p.get())->configure(registry(), v, false, e);
    for (uint32_t k = 0; k < p->descriptor().parameterCount; ++k)
        if (p->descriptor().parameters[k].id == "s1.gain") v.emplace_back("mod1_dst", k + 1.0);
    auto c = chainOf(spec("org.caw.rack.fx", v));
    if (!c) return;
    CHECK(c->keyed(0));
    std::vector<float> l = noise(48000, 0.5f), r = noise(48000, 0.5f, 2);
    ChainTime t;
    t.stepLength = kSr * 60.0 / 120.0 / 4.0;
    for (size_t at = 0; at < l.size(); at += 64) {
        t.start = static_cast<int64_t>(at);
        t.chunk = static_cast<int64_t>(at / 64);
        ComponentChain::KeyInput* key = c->keyInput(0);
        key->begin(t.chunk);
        if (at == 12032 || at == 36032) {  // block starts (64 frames each)
            Event ev;
            ev.kind = EventKind::Note;
            ev.noteId = 1;
            ev.data[0] = (0x4u << 28) | ((at == 12032 ? 0x9u : 0x8u) << 20) | (60u << 8);
            ev.data[1] = 0xFFFFu << 16;
            key->events[key->count++] = ev;
        }
        c->process(l.data() + at, r.data() + at, 64, kSr, &t);
    }
    auto seg = [&](size_t a, size_t b) {
        double s = 0;
        for (size_t i = a; i < b; ++i) s += l[i] * l[i];
        return std::sqrt(s / (b - a));
    };
    CHECK(seg(2000, 11000) < 0.001);     // closed
    CHECK(seg(20000, 34000) > 0.05);     // open while held
    CHECK(seg(40000, 47000) < 0.001);    // released
}
