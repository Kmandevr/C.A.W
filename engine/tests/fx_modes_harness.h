// Shared helpers for the 1.1.0 effect-mode tests: make a merged device's variant, run it over stereo signals, check block sizes, NaN and presets.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "builtin_components.h"
#include "fx_merged.h"
#include "presets.h"
#include "test.h"

namespace modes_test {

using namespace caw;
using Values = std::vector<std::pair<std::string, double>>;
constexpr double kPi = 3.14159265358979323846;

inline const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

struct Stereo {
    std::vector<float> l, r;
    size_t size() const { return l.size(); }
};

inline Stereo silence(size_t frames) { return {std::vector<float>(frames), std::vector<float>(frames)}; }
inline Stereo sine(double hz, double amp, size_t frames) {
    Stereo s = silence(frames);
    for (size_t i = 0; i < frames; ++i) s.l[i] = s.r[i] = static_cast<float>(amp * std::sin(2 * kPi * hz * i / 48000.0));
    return s;
}
// One click (a single full-scale-ish frame) at `at`.
inline Stereo click(size_t frames, size_t at = 0, double amp = 0.9) {
    Stereo s = silence(frames);
    s.l[at] = s.r[at] = static_cast<float>(amp);
    return s;
}
// A musical test signal: plucked tones and noise bursts, a little different on each side.
inline Stereo music(size_t frames, uint32_t seed = 7) {
    Stereo s = silence(frames);
    const double notes[] = {110.0, 164.8, 220.0, 293.7, 196.0, 130.8};
    for (size_t i = 0; i < frames; ++i) {
        const size_t note = (i / 12000) % 6, t = i % 12000;
        seed = seed * 1664525u + 1013904223u;
        const double nz = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0);
        const double env = std::exp(-static_cast<double>(t) / 4000.0);
        const double hz = notes[note];
        const double tone = std::sin(2 * kPi * hz * t / 48000.0) + 0.3 * std::sin(2 * kPi * 2 * hz * t / 48000.0);
        const double burst = t < 600 ? nz * (1.0 - t / 600.0) : 0.0;
        s.l[i] = static_cast<float>(0.4 * env * tone + 0.3 * burst);
        s.r[i] = static_cast<float>(0.35 * env * tone - 0.25 * burst);
    }
    return s;
}

inline Values with(Values v, double variant) {
    v.emplace_back("variant", variant);
    return v;
}

inline std::unique_ptr<ModuleProcessor> make(const char* id, const Values& values) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, values);
    CHECK(p != nullptr);
    if (p && !p->activate(48000, 512)) {
        cawtest::fail(__FILE__, __LINE__, "activate failed");
        return nullptr;
    }
    return p;
}

// Runs `p` over `in` in blocks of `block` (process(): no key).
inline Stereo run(ModuleProcessor& p, const Stereo& in, const Values& values, uint32_t block = 64) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values)
            if (d.parameters[k].id == id) params[k].value = v;
    }
    Stereo out = silence(in.size());
    for (size_t start = 0; start < in.size(); start += block) {
        const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, in.size() - start));
        const float* ic[2] = {in.l.data() + start, in.r.data() + start};
        float* oc[2] = {out.l.data() + start, out.r.data() + start};
        AudioProcessBlock b;
        b.input = {ic, 2, n};
        b.output = {oc, 2, n};
        b.frames = n;
        b.sampleRate = 48000;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p.process(b));
    }
    return out;
}

inline Stereo render(const char* id, const Values& values, const Stereo& in, uint32_t block = 64) {
    auto p = make(id, values);
    return p ? run(*p, in, values, block) : silence(in.size());
}

inline double peak(const std::vector<float>& v, size_t from = 0, size_t to = ~size_t{0}) {
    double p = 0;
    for (size_t i = from; i < std::min(to, v.size()); ++i) p = std::max(p, std::fabs(static_cast<double>(v[i])));
    return p;
}
inline double rms(const std::vector<float>& v, size_t from = 0, size_t to = ~size_t{0}) {
    double s = 0;
    size_t n = 0;
    for (size_t i = from; i < std::min(to, v.size()); ++i, ++n) s += static_cast<double>(v[i]) * v[i];
    return n ? std::sqrt(s / static_cast<double>(n)) : 0.0;
}
inline double db(double x) { return 20.0 * std::log10(std::max(x, 1e-12)); }
inline bool finite(const Stereo& s) {
    for (size_t i = 0; i < s.size(); ++i)
        if (!std::isfinite(s.l[i]) || !std::isfinite(s.r[i])) return false;
    return true;
}

// The same bits at blocks of 1, 37, 64 and 512.
inline void checkBlockSizes(const char* id, const Values& values, const Stereo& in, const std::string& what) {
    auto p = make(id, values);
    if (!p) return;
    const Stereo want = run(*p, in, values, 64);
    for (uint32_t block : {1u, 37u, 512u}) {
        p->reset();
        const Stereo got = run(*p, in, values, block);
        if (std::memcmp(want.l.data(), got.l.data(), want.l.size() * 4) != 0 ||
            std::memcmp(want.r.data(), got.r.data(), want.r.size() * 4) != 0)
            cawtest::fail(__FILE__, __LINE__, what + ": block " + std::to_string(block) + " differs from 64");
    }
}

// NaN, infinities and subnormal input: the state never latches (finite after the burst, silent and quiet after
// silence) and a subnormal input gives a finite output.
inline void checkBadInput(const char* id, const Values& values, const std::string& what, size_t tailFrames = 48000 * 12) {
    auto p = make(id, values);
    if (!p) return;
    Stereo in = music(9600);
    in.l[100] = std::nanf("");
    in.r[200] = INFINITY;
    in.l[300] = -INFINITY;
    in.r[400] = std::nanf("");
    for (size_t i = 5000; i < 5200; ++i) in.l[i] = in.r[i] = 1e-39f;  // subnormal
    const Stereo out = run(*p, in, values);
    for (size_t i = 410; i < out.size(); ++i)
        if (!std::isfinite(out.l[i]) || !std::isfinite(out.r[i])) {
            cawtest::fail(__FILE__, __LINE__, what + ": not finite after the bad input, at " + std::to_string(i));
            return;
        }
    const Stereo after = run(*p, silence(tailFrames), values, 512);
    if (!finite(after)) cawtest::fail(__FILE__, __LINE__, what + ": tail not finite");
    if (peak(after.l, after.size() - 4800) > 1e-5 || !p->quiet())
        cawtest::fail(__FILE__, __LINE__, what + ": does not fall silent and asleep after silence");
}

// Every preset of `variant`: at least `least`, each named and described, rendering finite and audible.
inline void checkPresets(const char* id, double variant, size_t least, const Stereo& in) {
    size_t count = 0;
    for (const BuiltinPreset& preset : builtinPresets(id)) {
        bool mine = false;
        for (const auto& [k, x] : preset.values) mine = mine || (k == "variant" && x == variant);
        if (!mine) continue;
        ++count;
        CHECK(!preset.name.empty() && !preset.description.empty());
        Values values;
        CHECK(applyBuiltinPreset(id, preset.name, values));
        const Stereo out = render(id, values, in);
        if (!finite(out)) cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + ": not finite");
        const double level = rms(out.l);
        if (!(level > 1e-3 && peak(out.l) < 4.0))
            cawtest::fail(__FILE__, __LINE__, std::string(preset.name) + ": level " + std::to_string(level));
    }
    if (count < least)
        cawtest::fail(__FILE__, __LINE__, std::string(id) + " variant " + std::to_string(variant) + ": " +
                                              std::to_string(count) + " presets");
}

// A variant appended to `id` at `index` named `name`: `variant` structural, its labels the whole list.
inline const ModuleDescriptor* checkVariant(const char* id, uint32_t index, const char* name) {
    const fx::MergedDevice* m = fx::findMergedDevice(id);
    CHECK(m != nullptr);
    if (!m || m->variants.size() <= index) {
        cawtest::fail(__FILE__, __LINE__, std::string(id) + " has no variant " + std::to_string(index));
        return nullptr;
    }
    CHECK(m->variants[index].name == std::string(name));
    const ModuleDescriptor& d = m->variants[index].descriptor();
    CHECK(d.id == std::string(id));
    const ParameterDescriptor& v = d.parameters[d.parameterCount - 1];
    CHECK(v.id == fx::kVariantParam);
    CHECK_EQ(v.defaultValue, static_cast<double>(index));
    CHECK_EQ(v.choiceCount, static_cast<uint32_t>(m->variants.size()));
    CHECK(!v.automatable && !v.modulatable && !v.midiMappable);
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, {{"variant", static_cast<double>(index)}});
    CHECK(p && &p->descriptor() == &d);
    return &d;
}

}  // namespace modes_test
