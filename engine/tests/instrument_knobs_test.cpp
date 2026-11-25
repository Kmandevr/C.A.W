// The 1.1.3 instruments' every-knob audibility: each user-visible knob of Starling, Nightingale, Curlew, Bittern and Woodpecker (every variant), at its two ends (or each choice), changes something a listener hears.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "test.h"
#include "timber_harness.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr double kSr = 48000;

// The perceptual features of a render (mono), the owner's columns (2026-11-25) and a few more:
// lvl 0..0.8 s, bright (first-difference RMS minus RMS over 0..0.8 s), early 0..0.1 s, late 0.6..0.8 s and tail
// 0.9..1.5 s (all dB); tune: the lowest note's fundamental in cents against equal temperament (0.1..0.7 s);
// onset: ms to the first sample 40 dB under the peak; mod: the envelope's fluctuation (10 ms frames' dB against
// their 80 ms running mean, RMS over 0.15..0.8 s: vibrato through a body, tremolo, beating, flutter).
struct Features {
    double lvl = 0, bright = 0, early = 0, late = 0, tail = 0, tune = 0, onset = 0, mod = 0;
};
constexpr int kFeatures = 8;
constexpr const char* kFeatureNames[kFeatures] = {"lvl", "bright", "early", "late", "tail", "tune", "onset", "mod"};
// What counts as heard: about 1 dB of a level, 5 cents, 2 ms of onset, 0.5 dB of envelope fluctuation.
constexpr double kThreshold[kFeatures] = {1.0, 1.0, 1.0, 1.0, 1.0, 5.0, 2.0, 0.5};
double featureAt(const Features& f, int k) {
    const double v[kFeatures] = {f.lvl, f.bright, f.early, f.late, f.tail, f.tune, f.onset, f.mod};
    return v[k];
}

double rmsOf(const std::vector<float>& x, size_t a, size_t b) {
    double e = 0;
    b = std::min(b, x.size());
    for (size_t i = a; i < b; ++i) e += static_cast<double>(x[i]) * x[i];
    return 10 * std::log10(e / std::max<size_t>(1, b - a) + 1e-20);
}

Features measure(const std::vector<float>& m, double lowest) {
    Features f;
    const size_t s08 = static_cast<size_t>(0.8 * kSr);
    f.lvl = rmsOf(m, 0, s08);
    std::vector<float> d(m.size());
    for (size_t i = 1; i < m.size(); ++i) d[i] = m[i] - m[i - 1];
    f.bright = rmsOf(d, 0, s08) - f.lvl;
    f.early = rmsOf(m, 0, static_cast<size_t>(0.1 * kSr));
    f.late = rmsOf(m, static_cast<size_t>(0.6 * kSr), s08);
    f.tail = std::max(-120.0, rmsOf(m, static_cast<size_t>(0.9 * kSr), static_cast<size_t>(1.5 * kSr)));
    const double ref = 440.0 * std::pow(2.0, (lowest - 69) / 12.0);
    const size_t a = static_cast<size_t>(0.1 * kSr), n = static_cast<size_t>(0.6 * kSr);
    f.tune = cents(peakHz(m, ref, 60, a, n, kSr), ref);
    float peak = 0;
    for (float x : m) peak = std::max(peak, std::fabs(x));
    for (size_t i = 0; i < m.size(); ++i)
        if (std::fabs(m[i]) > 0.01f * peak) {
            f.onset = 1000.0 * i / kSr;
            break;
        }
    const size_t fr = static_cast<size_t>(0.01 * kSr);
    std::vector<double> e;
    for (size_t i = static_cast<size_t>(0.07 * kSr); i + fr <= s08; i += fr) e.push_back(rmsOf(m, i, i + fr));
    double acc = 0;
    int cnt = 0;
    for (size_t i = 8; i < e.size(); ++i) {
        double mean = 0;
        for (size_t j = i - 8; j < i; ++j) mean += e[j];
        mean = (mean + e[i]) / 9.0;
        acc += (e[i] - mean) * (e[i] - mean), ++cnt;
    }
    f.mod = cnt ? std::sqrt(acc / cnt) : 0;
    return f;
}

// A render: the knobs `v`, notes and controllers, 1.5 s.
struct Phrase {
    std::vector<Note> notes;
    std::vector<Cc> ccs;
    double lowest = 48;
};

Stereo render(const char* id, const Values& v, const Phrase& ph) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, v);
    if (!p || !p->activate(kSr, 512)) return {};
    return play(*p, v, ph.notes, 1.5, kSr, 64, ph.ccs);
}

Phrase chord(double base, std::vector<double> steps, double velocity = 0.7) {
    Phrase ph;
    for (double s : steps) ph.notes.push_back({0.0, 0.8, base + s, velocity});
    ph.lowest = base + steps[0];
    return ph;
}

// What a knob needs to be heard, stated here and in docs/engine.md (and in its own name where it is a context of
// one variant or tier). Each entry: the device and knob; the values both ends are rendered with; the phrase.
struct Context {
    const char* device;
    const char* param;
    Values with;
    int phrase;  // 0: the variant's chord; 1: soft notes (velocity 0.3); 2: a loud bass note; 3: silently held keys
                 // under staccato strikes; 4: one held note (vibrato, growl: the chord would beat)
    const char* why;
};
const Context kContexts[] = {
    {"org.caw.starling", "resonance", {{"sustain", 1.0}}, 0, "the sustain pedal down"},
    {"org.caw.starling", "sympathy", {}, 3, "silently held keys (MIDI velocity 1-3) under staccato strikes"},
    {"org.caw.starling", "phantom", {{"tier", 3}}, 0, "Quality High (the only tier with phantom partials)"},
    {"org.caw.starling", "glide", {{"velocity", 1.0}}, 2, "a loud bass note"},
    {"org.caw.starling", "velocity", {}, 1, "soft notes"},
    {"org.caw.nightingale", "velocity", {}, 1, "soft notes"},
    {"org.caw.curlew", "velocity", {}, 1, "soft notes"},
    {"org.caw.woodpecker", "velocity", {}, 1, "soft notes"},
    {"org.caw.bittern", "velocity", {}, 1, "soft notes"},
    {"org.caw.woodpecker", "motor_depth", {{"motor", 5.0}}, 0, "the motor turning"},
    {"org.caw.curlew", "vib_rate", {{"vibrato", 0.6}}, 4, "vibrato on"},
    {"org.caw.curlew", "vibrato", {}, 4, "one note"},
    {"org.caw.curlew", "growl", {}, 4, "one note"},
    {"org.caw.nightingale", "vib_rate", {{"vibrato", 0.6}}, 4, "vibrato on"},
    {"org.caw.nightingale", "vibrato", {}, 4, "one note"},
    {"org.caw.bittern", "trem_rate", {{"tremulant", 0.8}}, 0, "the tremulant on"},
};
const Context* contextFor(const std::string& device, const std::string& param) {
    for (const Context& c : kContexts)
        if (device == c.device && param == c.param) return &c;
    return nullptr;
}
// Knobs a test of ends cannot judge: the variant itself; Quality, a CPU choice meant to sound alike (it only has to
// change something, checked below); voices is the polyphony cap (checked with the chord: one voice drops three notes).
bool skipped(const std::string& param) { return param == "variant"; }

struct Device {
    const char* id;
    const char* name;
    bool checked;  // Bittern: printed only (being rebuilt in parallel, 2026-11-25)
};
constexpr Device kDevices[] = {
    {"org.caw.starling", "Starling", true},       {"org.caw.nightingale", "Nightingale", true},
    {"org.caw.curlew", "Curlew", true},           {"org.caw.woodpecker", "Woodpecker", true},
    {"org.caw.bittern", "Bittern", false},
};

// The variant's chord: a spread voicing moved by octaves to where the variant sounds loudest.
Phrase variantChord(const char* id, const Values& base) {
    const std::vector<double> steps = {0, 7, 16, 23};
    double bestDb = -1e9, best = 48;
    for (double b : {48.0, 36.0, 60.0, 24.0, 72.0}) {
        const Phrase ph = chord(b, steps);
        const double l = rmsOf(render(id, base, ph).mono(), 0, static_cast<size_t>(0.8 * kSr));
        if (l > bestDb + 1.0) bestDb = l, best = b;
    }
    return chord(best, steps);
}

Phrase phraseFor(int kind, const Phrase& c) {
    switch (kind) {
        case 1: {
            Phrase p = c;
            for (Note& n : p.notes) n.velocity = 0.3;
            return p;
        }
        case 2: {
            Phrase p;
            p.notes = {{0.0, 0.8, 33, 1.0}};
            p.lowest = 33;
            return p;
        }
        case 3: {
            // The keys of a C major chord pressed silently and held; C3 and G3 struck short underneath.
            Phrase p;
            for (double k : {60.0, 64.0, 67.0, 72.0}) p.notes.push_back({0.0, 1.5, k, 1.0 / 127});
            p.notes.push_back({0.05, 0.25, 48, 0.8});
            p.notes.push_back({0.05, 0.25, 55, 0.8});
            p.lowest = 60;
            return p;
        }
        case 4: {
            Phrase p;
            p.notes = {{0.0, 0.8, c.lowest + 12, 0.7}};
            p.lowest = c.lowest + 12;
            return p;
        }
        default: return c;
    }
}

struct Row {
    std::string label;
    Features a, b;
    bool heard = false, identical = false;
};

bool sameAudio(const Stereo& x, const Stereo& y) { return x.l == y.l && x.r == y.r; }

}  // namespace

TEST(instrument_every_knob_is_audible) {
    int failures = 0;
    for (const Device& dev : kDevices) {
        std::unique_ptr<ModuleProcessor> probe = createComponent(registry(), dev.id, {});
        CHECK(probe != nullptr);
        if (!probe) continue;
        int variants = 1;
        for (uint32_t k = 0; k < probe->descriptor().parameterCount; ++k)
            if (probe->descriptor().parameters[k].id == "variant") variants = static_cast<int>(probe->descriptor().parameters[k].choiceCount);
        for (int var = 0; var < variants; ++var) {
            const Values base = variants > 1 ? Values{{"variant", static_cast<double>(var)}} : Values{};
            std::unique_ptr<ModuleProcessor> pv = createComponent(registry(), dev.id, base);
            if (!pv) continue;
            const ModuleDescriptor& d = pv->descriptor();
            std::string vname = variants > 1 && d.parameters[d.parameterCount - 1].choices
                                    ? std::string(d.parameters[d.parameterCount - 1].choices[var])
                                    : std::string("-");
            for (uint32_t k = 0; k < d.parameterCount; ++k)
                if (d.parameters[k].id == "variant" && d.parameters[k].choices) vname = std::string(d.parameters[k].choices[var]);
            const Phrase c = variantChord(dev.id, base);
            if (verbose()) std::printf("\n%s / %s (chord on %.0f)\n", dev.name, vname.c_str(), c.lowest);
            for (uint32_t k = 0; k < d.parameterCount; ++k) {
                const ParameterDescriptor& pd = d.parameters[k];
                const std::string id(pd.id);
                if (skipped(id)) continue;
                const Context* ctx = contextFor(dev.id, id);
                const Phrase ph = phraseFor(ctx ? ctx->phrase : 0, c);
                Values with = base;
                if (ctx)
                    for (const auto& kv : ctx->with) with.push_back(kv);
                std::vector<std::pair<std::string, double>> ends;
                if (pd.choiceCount > 0) {
                    for (uint32_t i = 0; i < pd.choiceCount; ++i) ends.emplace_back(std::string(pd.choices[i]), pd.minimum + i);
                    if (id == "tier") ends = {{"Eco", 1.0}, {"High", 3.0}};  // Setting plays the Settings tier (one of these)
                } else {
                    ends = {{"min", pd.minimum}, {"max", pd.maximum}};
                }
                std::vector<Features> fs;
                std::vector<Stereo> outs;
                for (const auto& [label, x] : ends) {
                    Values v = with;
                    v.emplace_back(id, x);
                    outs.push_back(render(dev.id, v, ph));
                    fs.push_back(measure(outs.back().mono(), ph.lowest));
                }
                // Every pair of ends (choices: every pair) must differ by a threshold in some feature.
                for (size_t i = 0; i < ends.size(); ++i)
                    for (size_t j = i + 1; j < ends.size(); ++j) {
                        if (ends.size() > 2 && pd.choiceCount == 0) continue;
                        double best = 0;
                        int which = -1;
                        for (int f = 0; f < kFeatures; ++f) {
                            const double dd = std::fabs(featureAt(fs[i], f) - featureAt(fs[j], f)) / kThreshold[f];
                            if (dd > best) best = dd, which = f;
                        }
                        const bool identical = sameAudio(outs[i], outs[j]);
                        const bool heard = id == "tier" ? !identical : best >= 1.0;
                        if (verbose()) {
                            std::printf("  %-12s %-8s|%-8s", id.c_str(), ends[i].first.c_str(), ends[j].first.c_str());
                            for (int f = 0; f < kFeatures; ++f)
                                std::printf(" %s %+6.1f", kFeatureNames[f], featureAt(fs[j], f) - featureAt(fs[i], f));
                            std::printf("  %s%s%s%s\n", identical ? "IDENTICAL " : "", heard ? "ok" : "NOT HEARD",
                                        which >= 0 ? " by " : "", which >= 0 ? kFeatureNames[which] : "");
                            if (ctx) std::printf("               (context: %s)\n", ctx->why);
                        }
                        if (!heard && dev.checked) {
                            ++failures;
                            std::printf("not heard: %s %s %s (%s vs %s)\n", dev.name, vname.c_str(), id.c_str(), ends[i].first.c_str(),
                                        ends[j].first.c_str());
                        }
                    }
            }
        }
    }
    CHECK_EQ(failures, 0);
}
