// Built-in presets (named parameter sets of built-in components) and the migration of the retired synths to Flagship presets.
#include "presets.h"

#include <cmath>
#include <cstdio>
#include <deque>

#include "builtin_flagship.h"
#include "json.h"

namespace caw {

namespace {

constexpr std::string_view kFlagship = "org.caw.synth.flagship";
constexpr std::string_view kMorph = "org.caw.synth.morph", kBass = "org.caw.bass", kAcid = "org.caw.synth.acid",
                           kBasic = "org.caw.synth.basic";

// Flagship's numbers the presets use (builtin_flagship.cpp's enums).
enum : int { kSrcNone = 0, kSrcEnv1 = 1, kSrcEnv2 = 2, kSrcLfo1 = 4, kSrcVelocity = 8, kSrcTimbre = 12, kSrcAccent = 14 };
enum : int { kLadderLp = 0, kSvfLp = 3 };
constexpr double kClassic = 4;                    // the Classic table: sine, triangle, saw, square
constexpr double kSine = 0, kTriangle = 1.0 / 3.0, kSaw = 2.0 / 3.0, kSquare = 1;  // its frames
constexpr double kPoly = 0, kMono = 1, kLegato = 2;
constexpr double kFourBars = 8;                   // lfo sync: 16 beats
// Octaves over the whole travel of Flagship's cutoff knob (20 Hz .. 20 kHz): a slot's amount 1 moves it this far.
constexpr double kCutoffOctaves = 9.965784284662087;
// ln(10 s / 1 ms), the travel of Flagship's time knobs.
constexpr double kTimeLogRange = 9.210340371976184;

// A slot's destination value: the parameter's index + 1.
double dst(std::string_view param) { return flagshipParameterIndex(param) + 1.0; }

using Values = std::vector<std::pair<std::string_view, double>>;

// Every preset sets all three oscillators, both filters, the slots it uses and slot 1 (Flagship's default slot 1
// opens filter 1 from env 2), so it doesn't depend on what Flagship's defaults are.
Values common() {
    return {{"osc1_on", 1}, {"osc1_table", kClassic}, {"osc1_unison", 1}, {"osc1_phase", 0}, {"osc1_phase_rand", 0},
            {"osc1_spread", 0}, {"osc1_detune", 0}, {"osc1_level", 0.7}, {"osc2_on", 0}, {"osc3_on", 0},
            {"flt1_on", 1}, {"flt2_on", 0}, {"flt1_drive", 1}, {"flt1_keytrack", 0}, {"flt1_mix", 1},
            {"mod1_src", kSrcNone}, {"mod1_dst", 0}, {"mod1_amt", 0}, {"fx_dist_on", 0}, {"fx_eq_on", 0},
            {"fx_chorus_on", 0}, {"fx_delay_on", 0}, {"fx_reverb_on", 0}, {"voice_mode", kPoly}};
}
Values with(Values v, Values more) {
    for (auto& m : more) {
        bool found = false;
        for (auto& x : v)
            if (x.first == m.first) x.second = m.second, found = true;
        if (!found) v.push_back(m);
    }
    return v;
}

// A slot: source, destination parameter, amount, (optionally) the source scaling it.
Values slot(int n, int source, std::string_view target, double amount, int via = kSrcNone, bool bipolar = false) {
    static const char* const names[] = {"mod1", "mod2", "mod3", "mod4", "mod5", "mod6"};
    const std::string_view p = names[n - 1];
    // The ids live as long as the program, in a static deque (which never moves its elements).
    static std::deque<std::string> store;
    auto id = [&](const char* suffix) -> std::string_view {
        store.push_back(std::string(p) + suffix);
        return store.back();
    };
    return {{id("_src"), static_cast<double>(source)}, {id("_dst"), dst(target)}, {id("_amt"), amount},
            {id("_via"), static_cast<double>(via)}, {id("_bipolar"), bipolar ? 1.0 : 0.0}};
}

// ---------- The presets that replace the retired synths (sounds measured against them: docs/performance.md) ----------

// The Morph synth: a sine-triangle-saw-square morph of seven copies 18 ct out, swept by a slow sine over 16 beats.
Values morphPad() {
    Values v = with(common(), {{"osc1_frame", 0.45}, {"osc1_unison", 7}, {"osc1_detune", 18}, {"osc1_detune_power", 0},
                               {"osc1_spread", 0.7}, {"osc1_blend", 0.5}, {"osc1_phase_rand", 1}, {"osc1_level", 1},
                               {"flt1_type", kSvfLp}, {"flt1_cutoff", 1800}, {"flt1_resonance", 0.15},
                               {"env1_attack", 0.3}, {"env1_decay", 0.5}, {"env1_sustain", 0.8}, {"env1_release", 0.8},
                               {"lfo1_shape", 0}, {"lfo1_sync", kFourBars}, {"lfo1_mode", 2 /* Running */},
                               {"velocity", 0.5}, {"volume", 0.3}});
    v = with(v, slot(1, kSrcLfo1, "osc1_frame", 0.25, kSrcNone, true));       // drift
    v = with(v, slot(2, kSrcTimbre, "flt1_cutoff", 4.0 / kCutoffOctaves));   // a note's timbre opens it 4 octaves
    return v;
}

// The bass: a saw with a sine an octave below, a 12 dB low-pass the envelope opens by 2.5 octaves, legato glide.
Values monoBass() {
    Values v = with(common(), {{"osc1_frame", kSaw}, {"osc2_on", 1}, {"osc2_table", kClassic}, {"osc2_frame", kSine},
                               {"osc2_octave", -1}, {"osc2_level", 0.4}, {"osc2_unison", 1}, {"osc2_phase", 0},
                               {"osc2_phase_rand", 0}, {"osc2_spread", 0}, {"osc2_detune", 0},
                               {"flt1_type", kSvfLp}, {"flt1_cutoff", 600}, {"flt1_resonance", 0.3},
                               {"env1_attack", 0.003}, {"env1_decay", 0.25}, {"env1_sustain", 0.6}, {"env1_release", 0.06},
                               {"env2_attack", 0.001}, {"env2_decay", 0.25}, {"env2_sustain", 0}, {"env2_release", 0.25},
                               {"fx_dist_on", 1}, {"fx_dist_type", 0}, {"fx_dist_drive", 1.2}, {"fx_dist_mix", 1},
                               {"voice_mode", kLegato}, {"glide", 0.04}, {"velocity", 0.6}, {"volume", 0.6}});
    return with(v, slot(1, kSrcEnv2, "flt1_cutoff", 5.0 * 0.5 / kCutoffOctaves));
}

// The acid synth: a saw into a resonant 4-pole ladder, legato slides, and accents (above velocity 0.7) that open
// the filter envelope further, shorten it and play louder.
Values acid303() {
    Values v = with(common(), {{"osc1_frame", kSaw}, {"flt1_type", kLadderLp}, {"flt1_cutoff", 500}, {"flt1_resonance", 0.7},
                               {"env1_attack", 0.002}, {"env1_decay", 0.3}, {"env1_sustain", 0.5}, {"env1_release", 0.04},
                               {"env2_attack", 0.001}, {"env2_decay", 0.3}, {"env2_sustain", 0}, {"env2_release", 0.3},
                               {"fx_dist_on", 1}, {"fx_dist_type", 0}, {"fx_dist_drive", 2}, {"fx_dist_mix", 1},
                               {"voice_mode", kLegato}, {"glide", 0.06}, {"velocity", 0.6}, {"volume", 0.6}});
    v = with(v, slot(1, kSrcEnv2, "flt1_cutoff", 5.0 * 0.6 / kCutoffOctaves));
    v = with(v, slot(2, kSrcEnv2, "flt1_cutoff", 2.5 * 0.5 / kCutoffOctaves, kSrcAccent));  // accent: env 2 opens further
    v = with(v, slot(3, kSrcAccent, "env2_decay", std::log(1.0 - 0.5 * 0.5) / kTimeLogRange));  // and decays sooner
    v = with(v, slot(4, kSrcAccent, "volume", 0.6 * 0.5 * 0.6));                                  // and is louder
    return v;
}

// The basic synth: a saw and a square 7 ct apart into a 12 dB low-pass that follows the level envelope.
Values basic() {
    Values v = with(common(), {{"osc1_frame", kSaw}, {"osc1_level", 0.75}, {"osc2_on", 1}, {"osc2_table", kClassic},
                               {"osc2_frame", kSquare}, {"osc2_fine", 7}, {"osc2_level", 0.5}, {"osc2_unison", 1},
                               {"osc2_phase", 0}, {"osc2_phase_rand", 0}, {"osc2_spread", 0}, {"osc2_detune", 0},
                               {"flt1_type", kSvfLp}, {"flt1_cutoff", 2400}, {"flt1_resonance", 0},
                               {"env1_attack", 0.005}, {"env1_decay", 0.3 * 1.3815510557964273}, {"env1_sustain", 0.7},
                               {"env1_release", 0.25 * 1.3815510557964273}, {"velocity", 1}, {"volume", 0.15}});
    v = with(v, slot(1, kSrcEnv1, "flt1_cutoff", 5.0 * 0.5 / kCutoffOctaves));
    v = with(v, slot(2, kSrcTimbre, "flt1_cutoff", 4.0 / kCutoffOctaves));
    return v;
}

const std::vector<BuiltinPreset>& flagshipPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Init", "Flagship's own default: a warm, wide saw stack", {}},
        {"Morph pad", "A sine-to-square morph with unison and a slow drift (the Morph synth)", morphPad()},
        {"Mono bass", "A saw and a sub an octave down, a low-pass and legato glide (the Bass)", monoBass()},
        {"Acid 303", "A saw into a resonant ladder, with accents and slides (the Acid synth)", acid303()},
        {"Basic", "Two oscillators, a low-pass and an ADSR (the Basic synth)", basic()},
    };
    return p;
}

// The ducker's shapes (#175): the duck's attack, hold, release (ms), curve and depth; the trigger is left alone.
const std::vector<BuiltinPreset>& duckerPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Pump", "The classic sidechain pump: straight down, a slow swell back", {{"attack", 1.0}, {"hold", 10.0}, {"release", 260.0}, {"tension", 0.6}, {"depth", 1.0}}},
        {"Quick", "A short dip that clears room for the kick and gets out of the way", {{"attack", 0.5}, {"hold", 0.0}, {"release", 90.0}, {"tension", -0.3}, {"depth", 0.8}}},
        {"Smooth", "A gentle, rounded duck for pads and vocals", {{"attack", 15.0}, {"hold", 30.0}, {"release", 400.0}, {"tension", -0.5}, {"depth", 0.6}}},
        {"Gate", "Off on the hit, back hard at the end: a choppy trance gate", {{"attack", 0.3}, {"hold", 120.0}, {"release", 8.0}, {"tension", 0.0}, {"depth", 1.0}}},
    };
    return p;
}

const std::vector<BuiltinPreset> kNone;

void set(std::vector<std::pair<std::string, double>>& params, std::string_view id, double value) {
    for (auto& p : params)
        if (p.first == id) {
            p.second = value;
            return;
        }
    params.emplace_back(std::string(id), value);
}

// A curve point's time in seconds after the Basic synth's (a fall of 5 time constants, -43 dB) on Flagship's
// envelope (a fall of 60 dB).
constexpr double kBasicTime = 1.3815510557964273;

double clampTo(double v, double lo, double hi) { return v < lo ? lo : (v > hi ? hi : v); }

// The basic synth's damping k = 2 - 1.9 r as Flagship's resonance (q = 0.707 * 28^r): q = 1 / k.
double basicResonance(double r) {
    const double q = 1.0 / (2.0 - 1.9 * clampTo(r, 0.0, 1.0));
    return clampTo(std::log(q / 0.70710678118654752) / std::log(28.0), 0.0, 1.0);
}

double basicWaveFrame(double wave) {
    switch (static_cast<int>(clampTo(wave, 0, 3))) {
        case 1: return kSquare;
        case 2: return kTriangle;
        case 3: return kSine;
        default: return kSaw;
    }
}

// The old knobs onto Flagship's, given the old values (each read with its old default).
void mapMorph(const std::vector<std::pair<std::string, double>>& old, std::vector<std::pair<std::string, double>>& out) {
    for (const auto& [k, v] : old) {
        if (k == "shape") set(out, "osc1_frame", v);
        else if (k == "drift") set(out, "mod1_amt", clampTo(v, 0, 1));
        else if (k == "unison") set(out, "osc1_unison", v);
        else if (k == "detune") set(out, "osc1_detune", clampTo(v, 0, 1) * 100.0);
        else if (k == "spread") set(out, "osc1_spread", v);
        else if (k == "cutoff") set(out, "flt1_cutoff", v);
        else if (k == "resonance") set(out, "flt1_resonance", v);
        else if (k == "attack" || k == "decay" || k == "sustain" || k == "release") set(out, "env1_" + k, v);
        else if (k == "volume") set(out, "volume", clampTo(v, 0, 1) * 0.6);
    }
}
void mapBass(const std::vector<std::pair<std::string, double>>& old, std::vector<std::pair<std::string, double>>& out) {
    for (const auto& [k, v] : old) {
        if (k == "wave") set(out, "osc1_frame", v >= 0.5 ? kSquare : kSaw);
        else if (k == "sub") set(out, "osc2_level", clampTo(v, 0, 1) * 0.8);
        else if (k == "cutoff") set(out, "flt1_cutoff", v);
        else if (k == "resonance") set(out, "flt1_resonance", v);
        else if (k == "env") set(out, "mod1_amt", 5.0 * clampTo(v, 0, 1) / kCutoffOctaves);
        else if (k == "decay") set(out, "env1_decay", v), set(out, "env2_decay", v), set(out, "env2_release", v);
        else if (k == "sustain") set(out, "env1_sustain", v);
        else if (k == "glide") set(out, "glide", v);
        else if (k == "legato") set(out, "voice_mode", v >= 0.5 ? kLegato : kMono);
        else if (k == "drive") set(out, "fx_dist_drive", v);
        else if (k == "volume") set(out, "volume", v);
    }
}
void mapAcid(const std::vector<std::pair<std::string, double>>& old, std::vector<std::pair<std::string, double>>& out) {
    double accent = 0.5, volume = 0.6;
    for (const auto& [k, v] : old) {
        if (k == "wave") set(out, "osc1_frame", v >= 0.5 ? kSquare : kSaw);
        else if (k == "cutoff") set(out, "flt1_cutoff", v);
        else if (k == "resonance") set(out, "flt1_resonance", v);
        else if (k == "env") set(out, "mod1_amt", 5.0 * clampTo(v, 0, 1) / kCutoffOctaves);
        else if (k == "decay") set(out, "env1_decay", v), set(out, "env2_decay", v), set(out, "env2_release", v);
        else if (k == "accent") accent = clampTo(v, 0, 1);
        else if (k == "slide") set(out, "glide", v);
        else if (k == "drive") set(out, "fx_dist_drive", v);
        else if (k == "volume") set(out, "volume", volume = clampTo(v, 0, 1));
    }
    set(out, "mod2_amt", 2.5 * accent / kCutoffOctaves);
    set(out, "mod3_amt", std::log(1.0 - 0.5 * accent) / kTimeLogRange);
    set(out, "mod4_amt", 0.6 * accent * volume);
}
void mapBasic(const std::vector<std::pair<std::string, double>>& old, std::vector<std::pair<std::string, double>>& out) {
    double mix = 0.5;
    for (const auto& [k, v] : old) {
        if (k == "wave1") set(out, "osc1_frame", basicWaveFrame(v));
        else if (k == "wave2") set(out, "osc2_frame", basicWaveFrame(v));
        else if (k == "detune") set(out, "osc2_fine", v);
        else if (k == "mix") mix = clampTo(v, 0, 1);
        else if (k == "cutoff") set(out, "flt1_cutoff", v);
        else if (k == "resonance") set(out, "flt1_resonance", basicResonance(v));
        else if (k == "env") set(out, "mod1_amt", 5.0 * clampTo(v, 0, 1) / kCutoffOctaves);
        else if (k == "attack" || k == "sustain") set(out, "env1_" + k, v);
        else if (k == "decay" || k == "release") set(out, "env1_" + k, v * kBasicTime);
        else if (k == "volume") set(out, "volume", clampTo(v, 0, 1) * 0.3);
    }
    set(out, "osc1_level", 1.0 - 0.5 * mix);
    set(out, "osc2_level", mix);
}

std::string number(double v) {
    char buf[40];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    return buf;
}

}  // namespace

// fx-dynamics begin
const std::vector<BuiltinPreset>* fxDynamicsPresets(std::string_view id);  // builtin_fx_dynamics_presets.cpp
// fx-dynamics end
// fx-creative begin: the Creative and Pitch & Time effects' presets (builtin_fx_creative_presets.cpp)
const std::vector<BuiltinPreset>* creativeBuiltinPresets(std::string_view id);
// fx-creative end

const std::vector<BuiltinPreset>& builtinPresets(std::string_view componentId) {
    if (const auto* p = fxDynamicsPresets(componentId)) return *p;  // fx-dynamics
    if (componentId == kFlagship) return flagshipPresets();
    if (componentId == "org.caw.ducker") return duckerPresets();
    if (const auto* p = creativeBuiltinPresets(componentId)) return *p;  // fx-creative
    return kNone;
}

const BuiltinPreset* findBuiltinPreset(std::string_view componentId, std::string_view name) {
    for (const BuiltinPreset& p : builtinPresets(componentId))
        if (p.name == name) return &p;
    return nullptr;
}

bool applyBuiltinPreset(std::string_view componentId, std::string_view name,
                        std::vector<std::pair<std::string, double>>& params) {
    const BuiltinPreset* preset = findBuiltinPreset(componentId, name);
    if (!preset) return false;
    std::vector<std::pair<std::string, double>> out;
    out.reserve(preset->values.size() + params.size());
    for (const auto& [k, v] : preset->values) out.emplace_back(std::string(k), v);
    for (const auto& [k, v] : params) set(out, k, v);
    params = std::move(out);
    return true;
}

std::string builtinPresetsJson(std::string_view componentId) {
    std::string json = "[";
    bool first = true;
    for (const BuiltinPreset& p : builtinPresets(componentId)) {
        json += (first ? "{\"name\":\"" : ",{\"name\":\"") + jsonEscape(p.name) + "\",\"description\":\"" +
                jsonEscape(p.description) + "\",\"params\":{";
        for (size_t i = 0; i < p.values.size(); ++i)
            json += (i ? ",\"" : "\"") + jsonEscape(p.values[i].first) + "\":" + number(p.values[i].second);
        json += "}}";
        first = false;
    }
    return json + "]";
}

bool isLegacyInstrument(std::string_view id) { return id == kMorph || id == kBass || id == kAcid || id == kBasic; }

bool migrateLegacyInstrument(std::string& id, std::vector<std::pair<std::string, double>>& params, std::string* preset) {
    if (!isLegacyInstrument(id)) return false;
    const char* name = id == kMorph ? "Morph pad" : id == kBass ? "Mono bass" : id == kAcid ? "Acid 303" : "Basic";
    std::vector<std::pair<std::string, double>> out;
    applyBuiltinPreset(kFlagship, name, out);
    if (id == kMorph) mapMorph(params, out);
    else if (id == kBass) mapBass(params, out);
    else if (id == kAcid) mapAcid(params, out);
    else mapBasic(params, out);
    id = std::string(kFlagship);
    params = std::move(out);
    if (preset) *preset = name;
    return true;
}

std::string migratedLegacyParameter(std::string_view legacyId, std::string_view param) {
    const bool morph = legacyId == kMorph, bass = legacyId == kBass, acid = legacyId == kAcid, basicSynth = legacyId == kBasic;
    if (!(morph || bass || acid || basicSynth)) return {};
    if (param == "cutoff") return "flt1_cutoff";
    if (param == "resonance" && !basicSynth) return "flt1_resonance";
    if ((morph || basicSynth) && (param == "attack" || param == "sustain")) return "env1_" + std::string(param);
    if (morph && (param == "decay" || param == "release")) return "env1_" + std::string(param);
    if (bass && param == "sustain") return "env1_sustain";
    if ((bass && param == "glide") || (acid && param == "slide")) return "glide";
    if (morph && param == "shape") return "osc1_frame";
    if (morph && (param == "unison" || param == "spread")) return "osc1_" + std::string(param);
    if ((bass || acid) && param == "drive") return "fx_dist_drive";
    if ((bass || acid) && param == "volume") return "volume";
    if (basicSynth && param == "detune") return "osc2_fine";
    return {};
}

std::string migrateInstrumentJson(std::string_view entryJson) {
    Json j;
    std::string error;
    if (!parseJson(entryJson, j, error) || j.type != Json::Type::Object)
        return "{\"ok\":false,\"error\":\"" + jsonEscape(error.empty() ? "an entry must be an object" : error) + "\"}";
    std::string id = j.string("id");
    std::vector<std::pair<std::string, double>> params;
    if (const Json* ps = j.get("params"); ps && ps->type == Json::Type::Object)
        for (const auto& [k, v] : ps->obj)
            if (v.type == Json::Type::Number && std::isfinite(v.num)) params.emplace_back(k, v.num);
    std::string preset;
    const std::string legacy = id;
    const bool migrated = migrateLegacyInstrument(id, params, &preset);
    if (!migrated)
        if (const Json* named = j.get("preset"); named && named->type == Json::Type::String) {
            if (!applyBuiltinPreset(id, named->str, params))
                return "{\"ok\":false,\"error\":\"" + jsonEscape("'" + id + "' has no preset '" + named->str + "'") + "\"}";
            preset = named->str;
        }
    std::string json = std::string("{\"ok\":true,\"migrated\":") + (migrated ? "true" : "false") + ",\"id\":\"" +
                       jsonEscape(id) + "\"";
    if (!migrated && !preset.empty()) json += ",\"preset\":\"" + jsonEscape(preset) + "\"";
    if (migrated) {
        json += ",\"preset\":\"" + jsonEscape(preset) + "\",\"lanes\":{";
        bool first = true;
        for (const char* k : {"shape", "drift", "unison", "detune", "spread", "cutoff", "resonance", "attack", "decay",
                              "sustain", "release", "volume", "wave", "sub", "env", "glide", "legato", "drive", "accent",
                              "slide", "wave1", "wave2", "mix"}) {
            const std::string to = migratedLegacyParameter(legacy, k);
            if (to.empty()) continue;
            json += (first ? "\"" : ",\"") + std::string(k) + "\":\"" + to + "\"";
            first = false;
        }
        json += "}";
    }
    json += ",\"params\":{";
    for (size_t i = 0; i < params.size(); ++i)
        json += (i ? ",\"" : "\"") + jsonEscape(params[i].first) + "\":" + number(params[i].second);
    return json + "}}";
}

}  // namespace caw
