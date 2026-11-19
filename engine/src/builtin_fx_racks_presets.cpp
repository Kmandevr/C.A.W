// The racks' factory presets (fx-racks): whole racks (children, their knobs and the routes) as named sets of values.
#include <deque>
#include <memory>
#include <string>

#include "builtin_components.h"
#include "builtin_fx_racks.h"
#include "presets.h"

namespace caw {

namespace {

using Values = std::vector<std::pair<std::string_view, double>>;
using Owned = std::vector<std::pair<std::string, double>>;

// The ids live as long as the program (a deque never moves its elements).
std::string_view keep(std::string s) {
    static std::deque<std::string> store;
    store.push_back(std::move(s));
    return store.back();
}

double fx(std::string_view id) { return static_cast<double>(rackChildHash(id)); }

// A slot's child: its `_fx` (the id's hash) and its merged device's `variant` (fx_merged.h), so no preset needs
// migrating (fx_migrate.h).
Owned child(const std::string& slot, std::string_view id, int variant = 0) {
    return {{slot + "_fx", fx(id)}, {slot + ".variant", variant}};
}

// A slot's child that is not a merged device: its `_fx` only.
Owned plainChild(const std::string& slot, std::string_view id) { return {{slot + "_fx", fx(id)}}; }

Owned with(Owned a, const Owned& b) {
    a.insert(a.end(), b.begin(), b.end());
    return a;
}

// A route's destination for the rack these values make: the parameter's index + 1 in its descriptor.
double destination(std::string_view rackId, const Owned& values, std::string_view param) {
    static const ModuleRegistry registry = [] {
        ModuleRegistry r;
        registerBuiltinComponents(r);
        return r;
    }();
    std::unique_ptr<ModuleProcessor> p = registry.create(rackId);
    auto* rack = dynamic_cast<RackContainer*>(p.get());
    std::string error;
    if (!rack || !rack->configure(registry, values, true, error)) return 0.0;
    const ModuleDescriptor& d = p->descriptor();
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == param) return k + 1.0;
    return 0.0;
}

// Route n: source (kRackSources' number), destination parameter, amount, bipolar.
void route(std::string_view rackId, Owned& v, int n, int source, std::string_view param, double amount, bool bipolar) {
    const std::string p = "mod" + std::to_string(n) + "_";
    const double dst = destination(rackId, v, param);
    v.insert(v.end(), {{p + "src", source}, {p + "dst", dst}, {p + "amt", amount}, {p + "bipolar", bipolar ? 1.0 : 0.0}});
}

Values frozen(const Owned& v) {
    Values out;
    for (const auto& [k, x] : v) out.emplace_back(keep(k), x);
    out.emplace_back(kRackLayoutParam, kRackLayoutCurrent);  // routes made on today's layout
    return out;
}

enum : int { kLfo1 = 1, kLfo2 = 2, kFollow1 = 5, kEnv1 = 7, kRandom = 9, kMacro1 = 10, kMacro2 = 11 };

std::vector<BuiltinPreset> fxRackPresets() {
    const std::string_view id = kFxRackId;
    std::vector<BuiltinPreset> out;
    {  // a low-pass swept by an eighth-note LFO, its depth on macro 1's knob
        Owned v = with(child("s1", "org.caw.filter"), {{"s1.cutoff", 900}, {"s1.resonance", 0.45},
                   {"lfo1_shape", 1}, {"lfo1_sync", 6}, {"macro1", 0.6}});
        route(id, v, 1, kLfo1, "s1.cutoff", 0.35, true);
        out.push_back({"Wobble filter", "An eighth-note LFO sweeps a resonant low-pass", frozen(v)});
    }
    {  // dotted-eighth echoes into a reverb; macro 1 throws more of both
        Owned v = with(child("s1", "org.caw.delay"), {{"s1.sync", 7}, {"s1.feedback", 0.45}, {"s1.mix", 0.3},
                   {"s1.high_cut", 3500}});  // Digital
        v = with(with(v, child("s2", "org.caw.reverb")), {{"s2.decay", 4.0}, {"s2.mix", 0.25}, {"macro1", 0.3}});  // Hall
        route(id, v, 1, kMacro1, "s1.feedback", 0.4, false);
        route(id, v, 2, kMacro1, "s2.mix", 0.4, false);
        out.push_back({"Dub space", "Dotted echoes into a long reverb; Macro 1 throws more", frozen(v)});
    }
    {  // the echoes duck under the playing and swell in the gaps (a follower turns the delay's mix down)
        Owned v = with(child("s1", "org.caw.delay"), {{"s1.sync", 9}, {"s1.feedback", 0.5}, {"s1.mix", 0.55},
                   {"fol1_attack", 5}, {"fol1_release", 250}, {"fol1_gain", 12}});
        route(id, v, 1, kFollow1, "s1.mix", -0.5, false);
        out.push_back({"Ducked delay", "Quarter-note echoes that stay out of the way while you play", frozen(v)});
    }
    {  // a saturator whose drive breathes with a slow random source, then a gentle tone filter
        Owned v = with(child("s1", "org.caw.drive", 1), {{"s1.mode", 0}, {"s1.drive", 9}});  // Saturate
        v = with(with(v, child("s2", "org.caw.filter")), {{"s2.cutoff", 7000}, {"rnd_rate", 0.7}, {"rnd_smooth", 1}});
        route(id, v, 1, kRandom, "s1.drive", 0.15, true);
        out.push_back({"Drifting tape", "Tape drive that wanders, darkened a little", frozen(v)});
    }
    {  // a band-pass that opens with each note of the key (Env 1) and a phaser on top
        Owned v = with(child("s1", "org.caw.filter"), {{"s1.cutoff", 300}, {"s1.resonance", 0.5}});
        v = with(with(v, child("s2", "org.caw.phaser")), {{"s2.mix", 0.35}, {"env1_attack", 0.01}, {"env1_decay", 0.4},
                   {"env1_sustain", 0.2}});
        route(id, v, 1, kEnv1, "s1.cutoff", 0.45, false);
        out.push_back({"Note sweep", "The key track's notes open a resonant filter; a phaser on top", frozen(v)});
    }
    // 1.1.0: job-named chains, the purpose first (the last one playful, as each device's last preset).
    {  // a compressor, a de-esser and a short reverb: a lead vocal's usual chain
        Owned v = with(child("s1", "org.caw.compressor"), {{"s1.threshold", -20}, {"s1.ratio", 3}, {"s1.attack", 5},
                   {"s1.release", 120}});
        v = with(with(v, plainChild("s2", "org.caw.deesser")), {{"s2.freq", 6500}, {"s2.threshold", -30}, {"s2.range", 8}});
        v = with(with(v, child("s3", "org.caw.reverb")), {{"s3.decay", 1.5}, {"s3.mix", 0.15}});  // Hall
        out.push_back({"Vocal chain", "Vocals: compression, then the esses tamed, then a little room", frozen(v)});
    }
    {  // saturation into a fast compressor, mixed in parallel: drum bus weight
        Owned v = with(child("s1", "org.caw.drive", 1), {{"s1.mode", 0}, {"s1.drive", 6}, {"s1.mix", 0.5}});  // Saturate
        v = with(with(v, child("s2", "org.caw.compressor")), {{"s2.threshold", -18}, {"s2.ratio", 4}, {"s2.attack", 10},
                   {"s2.release", 100}, {"s2.mix", 0.6}});
        out.push_back({"Drum bus crunch", "Drums: saturated, then squeezed in parallel for a heavier bus", frozen(v)});
    }
    {  // a dark filter that drifts on a slow LFO into eighth echoes and a reverb
        Owned v = with(child("s1", "org.caw.filter"), {{"s1.cutoff", 2500}, {"s1.resonance", 0.3}, {"lfo1_shape", 0},
                   {"lfo1_rate", 0.2}});
        v = with(with(v, child("s2", "org.caw.delay")), {{"s2.sync", 6}, {"s2.feedback", 0.55}, {"s2.mix", 0.4},
                   {"s2.high_cut", 2500}});  // Digital
        v = with(with(v, child("s3", "org.caw.reverb")), {{"s3.decay", 3.0}, {"s3.mix", 0.3}});  // Hall
        route(id, v, 1, kLfo1, "s1.cutoff", 0.2, true);
        out.push_back({"Crow's nest", "Lo-fi: a dark, wobbling echo chamber", frozen(v)});
    }
    return out;
}

std::vector<BuiltinPreset> multibandPresets() {
    std::vector<BuiltinPreset> out;
    {
        Owned v = {{"bands", 3}, {"xover1", 180}, {"xover2", 3000}};
        for (const char* b : {"b1s1", "b2s1", "b3s1"}) {
            const std::string s = b;
            v = with(with(v, child(s, "org.caw.compressor")), {{s + ".threshold", -20}, {s + ".ratio", 2.5},
                               {s + ".attack", 15}, {s + ".release", 200}});
        }
        out.push_back({"Multiband glue", "Three gentle compressors hold lows, mids and highs together", frozen(v)});
    }
    out.push_back({"Mono lows, wide top", "Below 150 Hz in mono, above 4 kHz wider",
                   frozen(with(with(with(with({{"bands", 3}, {"xover1", 150}, {"xover2", 4000}}, child("b1s1", "org.caw.utility")),
                                         {{"b1s1.width", 0}}), child("b3s1", "org.caw.utility")), {{"b3s1.width", 1.6}}))});
    out.push_back({"Air exciter", "Tube harmonics only above 5 kHz, mixed in",
                   frozen(with(with({{"bands", 2}, {"xover1", 5000}}, child("b2s1", "org.caw.drive", 1)),  // Saturate
                               {{"b2s1.mode", 1}, {"b2s1.drive", 12}, {"b2s1.mix", 0.5}}))});
    out.push_back({"Tight low end", "A fast compressor on the lows only",
                   frozen(with(with({{"bands", 2}, {"xover1", 120}}, child("b1s1", "org.caw.compressor")),
                               {{"b1s1.threshold", -24}, {"b1s1.ratio", 6}, {"b1s1.attack", 3}, {"b1s1.release", 80}}))});
    out.push_back({"Split space", "Dry lows, a reverb on the mids and highs",
                   frozen(with(with({{"bands", 2}, {"xover1", 300}}, child("b2s1", "org.caw.reverb")), {{"b2s1.mix", 0.3}}))});
    // 1.1.0: job-named chains, the purpose first (the last one playful).
    {  // gentle low compression, warmth on the top
        Owned v = {{"bands", 3}, {"xover1", 120}, {"xover2", 6000}};
        v = with(with(v, child("b1s1", "org.caw.compressor")), {{"b1s1.threshold", -18}, {"b1s1.ratio", 2},
                   {"b1s1.attack", 30}, {"b1s1.release", 200}});
        v = with(with(v, child("b3s1", "org.caw.drive", 1)), {{"b3s1.mode", 1}, {"b3s1.drive", 4}, {"b3s1.mix", 0.3}});  // Saturate
        out.push_back({"Master band polish", "Mastering: the lows held gently, a little warmth on the air", frozen(v)});
    }
    {  // a vocal's harsh presence and esses compressed on their own
        Owned v = {{"bands", 3}, {"xover1", 2000}, {"xover2", 7000}};
        v = with(with(v, child("b2s1", "org.caw.compressor")), {{"b2s1.threshold", -24}, {"b2s1.ratio", 3},
                   {"b2s1.attack", 2}, {"b2s1.release", 80}});
        v = with(with(v, child("b3s1", "org.caw.compressor")), {{"b3s1.threshold", -28}, {"b3s1.ratio", 4},
                   {"b3s1.attack", 1}, {"b3s1.release", 60}});
        out.push_back({"Vocal de-harsh", "Vocals: the 2-7 kHz bite and the esses above each compressed alone", frozen(v)});
    }
    {  // a different effect in each band
        Owned v = {{"bands", 3}, {"xover1", 200}, {"xover2", 3000}};
        v = with(with(v, child("b1s1", "org.caw.drive", 1)), {{"b1s1.mode", 0}, {"b1s1.drive", 8}});  // Saturate
        v = with(with(v, child("b2s1", "org.caw.phaser")), {{"b2s1.mix", 0.5}});
        v = with(with(v, child("b3s1", "org.caw.delay")), {{"b3s1.sync", 6}, {"b3s1.feedback", 0.4}, {"b3s1.mix", 0.4}});
        out.push_back({"Caw, caw, caw", "Sound design: lows driven, mids phased, highs echoed", frozen(v)});
    }
    return out;
}

}  // namespace

const std::vector<BuiltinPreset>& rackPresets(std::string_view componentId) {
    static const std::vector<BuiltinPreset> fxRack = fxRackPresets(), multiband = multibandPresets(), none;
    if (componentId == kFxRackId) return fxRack;
    if (componentId == kMultibandRackId) return multiband;
    return none;
}

}  // namespace caw
