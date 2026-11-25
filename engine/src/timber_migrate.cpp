// Timber's load-time alias (removed in 1.1.3): the mapping table from each old model and its knobs to the new instruments' presets and knobs.
#include "timber_migrate.h"

#include <algorithm>
#include <cmath>

#include "builtin_bittern.h"
#include "builtin_curlew.h"
#include "builtin_flagship.h"
#include "builtin_nightingale.h"
#include "builtin_starling.h"
#include "builtin_woodpecker.h"
#include "fx_merged.h"
#include "module_registry.h"
#include "presets.h"

namespace caw::timber {
namespace {

constexpr std::string_view kKestrelId = "org.caw.synth.flagship";  // Kestrel, the wavetable synth

// ======================= The mapping table (owner, 2026-11-25): change it here and only here =======================
// Piano -> Starling's piano; Bowed -> Nightingale; Winds -> Curlew; Mallets -> Woodpecker; a pipe-like organ (no
// rotary, no percussion, little drive) -> Bittern; Electric piano -> Kestrel's electric-piano presets ("it's just a
// synthesized piano"); the tonewheel organ -> Kestrel's tonewheel preset.
//
// [Open question, awaiting the owner] the tonewheel organ's destination. false sends every Timber organ to Bittern.
constexpr bool kTonewheelToKestrel = true;
//
// Plucked -> Starling's Classical guitar (variant 1: the guitars and the koto) or Harp (2), being added in 1.1.3.
// TODO(plucked, 1.1.3): until those variants are on Main, a plucked entry falls back to Starling's piano (0) with
// these presets (pluckedDestination checks the variant exists). Delete the fallback once they are.
constexpr int kPluckedVariant[4] = {1, 1, 2, 1};  // Steel guitar, Nylon guitar, Harp, Koto
constexpr std::string_view kPluckedFallback[4] = {"Bright pop grand", "Warm jazz grand", "Grand piano", "Bright pop grand"};
//
constexpr std::string_view kPianoPresets[3] = {"Grand piano", "Upright", "Felt piano"};  // by Character
constexpr std::string_view kBowedPresets[4] = {"Solo violin", "Solo viola", "Solo cello", "Double bass"};  // variant = section
constexpr int kWindVariant[4] = {1, 0, 2, 3};  // Clarinet, Flute, Sax, Brass -> Curlew's Clarinet, Flute, Saxophone, Trumpet
constexpr std::string_view kWindPresets[4] = {"Clarinet", "Concert flute", "Alto sax", "Trumpet"};
// Marimba, Vibraphone, Xylophone, Glockenspiel, Chimes, Bell -> Woodpecker's (the bell to its tubular bells).
constexpr int kMalletVariant[6] = {0, 3, 1, 2, 4, 4};
constexpr std::string_view kMalletPresets[6] = {"Concert marimba", "Vibraphone", "Xylophone", "Glockenspiel", "Tubular bells", "Tubular bells"};
constexpr std::string_view kEpPresets[2] = {"Electric piano (tine)", "Electric piano (reed)"};  // by Kind
constexpr std::string_view kOrganPipePreset = "Soft flutes", kOrganWheelPreset = "Tonewheel organ";
// ====================================================================================================================

// Timber's shared knobs' defaults per model (builtin_timber.cpp as it was): release, body, space.
struct SharedDefaults {
    double release, body, space;
};
constexpr SharedDefaults kShared[7] = {{0.25, 0.75, 0.15}, {0.12, 0.5, 0.1}, {0.01, 0.5, 0.1}, {0.15, 0.5, 0.12},
                                       {0.25, 0.6, 0.2},   {0.3, 0.5, 0.15},  {0.08, 0.5, 0.15}};

// A value of the old entry, held to its old range; `def` when absent or not finite (the last one given wins).
double get(const Params& p, std::string_view id, double def, double lo, double hi) noexcept {
    double v = def;
    for (const auto& [k, x] : p)
        if (k == id) v = std::isfinite(x) ? x : def;
    return std::clamp(v, lo, hi);
}
int pick(const Params& p, std::string_view id, int count) noexcept {
    return static_cast<int>(std::floor(get(p, id, 0.0, 0.0, count - 1.0) + 0.5));
}
bool has(const Params& p, std::string_view id) noexcept {
    for (const auto& [k, x] : p)
        if (k == id && std::isfinite(x)) return true;
    return false;
}
void put(Params& out, std::string_view id, double v) {
    for (auto& [k, x] : out)
        if (k == id) {
            x = v;
            return;
        }
    out.emplace_back(std::string(id), v);
}
// Copies the old knob (if the entry names it) under the same or another id.
void carry(const Params& in, Params& out, std::string_view from, double lo, double hi, std::string_view to = {}) {
    if (has(in, from)) put(out, to.empty() ? from : to, get(in, from, 0.0, lo, hi));
}
bool simulated(const Params& p) noexcept { return get(p, "sim", 0.0, 0.0, 1.0) >= 0.5; }

// One drawbar (0..8, a step is 3 dB) as an amplitude.
double bar(const Params& p, std::string_view id, double def) noexcept {
    const double n = std::floor(get(p, id, def, 0.0, 8.0) + 0.5);
    return n <= 0.0 ? 0.0 : std::pow(10.0, -3.0 * (8.0 - n) / 20.0);
}
bool organPipeLike(const Params& p) noexcept {
    if (!kTonewheelToKestrel) return true;
    return pick(p, "rotary", 4) == 0 && pick(p, "perc", 3) == 0 && get(p, "drive", 0.1, 0.0, 1.0) <= 0.2;
}

// The destination's descriptor (merged devices by variant; Bittern and Kestrel from a registry of their own).
const ModuleDescriptor* descriptorOf(std::string_view id, int variant) {
    if (const fx::MergedDevice* d = fx::findMergedDevice(id))
        return d->variants.empty() ? nullptr : &d->variants[std::min<size_t>(variant, d->variants.size() - 1)].descriptor();
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        bittern::registerBittern(x);
        registerFlagshipSynth(x);
        return x;
    }();
    return r.find(id);
}
const ParameterDescriptor* paramOf(const ModuleDescriptor* d, std::string_view id) noexcept {
    if (!d) return nullptr;
    for (uint32_t k = 0; k < d->parameterCount; ++k)
        if (d->parameters[k].id == id) return &d->parameters[k];
    return nullptr;
}

// The shared knobs for an acoustic destination (Timber's own frame: the same ids and units).
void sharedKnobs(const Params& in, Params& out, Model m, bool body) {
    const SharedDefaults& d = kShared[static_cast<int>(m)];
    carry(in, out, "tone", -1.0, 1.0);
    put(out, "space", get(in, "space", d.space, 0.0, 1.0));  // the room the old project had (the new ones are dry)
    carry(in, out, "velocity", 0.0, 1.0);
    carry(in, out, "release", 0.005, 10.0);
    carry(in, out, "level", -48.0, 12.0);
    carry(in, out, "voices", 1.0, 64.0);
    if (body) carry(in, out, "body", 0.0, 1.0);
}

// Kestrel's shared mapping: tone as a low-pass, space as its reverb, level as its volume, release as Env 1's.
void kestrelShared(const Params& in, Params& out, Model m) {
    const SharedDefaults& d = kShared[static_cast<int>(m)];
    const double tone = get(in, "tone", 0.0, -1.0, 1.0);
    if (std::fabs(tone) > 0.02) put(out, "flt1_on", 1), put(out, "flt1_type", 0), put(out, "flt1_cutoff", 7000.0 * std::pow(4.0, tone));
    const double space = get(in, "space", d.space, 0.0, 1.0);
    if (space > 0.01) put(out, "fx_reverb_on", 1), put(out, "fx_reverb_mix", 0.5 * space);
    put(out, "volume", std::clamp(0.6 * std::pow(10.0, get(in, "level", 0.0, -48.0, 12.0) / 20.0), 0.0, 1.0));
    put(out, "env1_release", get(in, "release", d.release, 0.005, 10.0));
}

void mapPiano(const Params& in, Params& out) {
    for (const char* k : {"hammer", "unison", "stretch", "decay", "sustain", "soft", "resonance"}) {
        const ParameterDescriptor* p = paramOf(descriptorOf(starling::kStarlingId, 0), k);
        if (p) carry(in, out, k, p->minimum, p->maximum);
    }
    put(out, "character", pick(in, "character", 3));
    if (simulated(in))  // Classic had none of these: Starling's own defaults stand in
        for (const char* k : {"tier", "noise", "touch", "action", "glide", "sympathy", "phantom"}) carry(in, out, k, 0.0, 3.0);
    sharedKnobs(in, out, Model::Piano, true);
}

void mapPlucked(const Params& in, Params& out, const Destination& to) {
    const ModuleDescriptor* d = descriptorOf(to.id, to.variant);
    // A plucked variant's own knobs of the same name (fit() drops those it lacks) ...
    for (const char* k : {"pick", "position", "brightness", "damping"}) carry(in, out, k, 0.0, 1.0);
    const double pick01 = get(in, "pick", 0.5, 0.0, 1.0), bright = get(in, "brightness", 0.5, 0.0, 1.0);
    // ... and the piano's (the fallback): the pick as the hammer, palm muting as a shorter ring.
    put(out, "hammer", std::clamp(0.3 + 0.4 * pick01 + 0.3 * (bright - 0.5), 0.0, 1.0));
    const double mute = paramOf(d, "damping") ? 0.0 : get(in, "damping", 0.0, 0.0, 1.0);
    put(out, "decay", std::clamp(get(in, "decay", 1.0, 0.25, 4.0) * (1.0 - 0.75 * mute), 0.25, 4.0));
    sharedKnobs(in, out, Model::Plucked, false);
}

void mapBowed(const Params& in, Params& out) {
    for (const char* k : {"pressure", "speed", "vibrato"}) carry(in, out, k, 0.0, 1.0);
    carry(in, out, "vib_rate", 2.0, 9.0);
    carry(in, out, "attack", 0.005, 2.0);
    if (has(in, "position")) {  // Timber's 0.03..0.3 of the string from the bridge; Nightingale's 0 bridge .. 1 fingerboard
        const double x = get(in, "position", 0.12, 0.03, 0.3);
        put(out, "position", x <= 0.12 ? 0.5 * (x - 0.03) / 0.09 : 0.5 + 0.5 * (x - 0.12) / 0.18);
    }
    if (simulated(in)) carry(in, out, "noises", 0.0, 1.0, "noise");
    sharedKnobs(in, out, Model::Bowed, false);  // Body: the recorded body (Nightingale's 1) stays
}

void mapWinds(const Params& in, Params& out) {
    for (const char* k : {"breath", "noise", "reed", "vibrato", "growl"}) carry(in, out, k, 0.0, 1.0);
    carry(in, out, "vib_rate", 2.0, 9.0);
    carry(in, out, "attack", 0.005, 2.0);
    sharedKnobs(in, out, Model::Winds, false);
}

void mapMallets(const Params& in, Params& out, int instrument) {
    carry(in, out, "hardness", 0.0, 1.0);
    carry(in, out, "decay", 0.25, 4.0);
    // Timber's key-up damper (0 rings on) is the pedal's opposite (Woodpecker's 0 damps as you let go).
    if (instrument == 1 || instrument >= 4) put(out, "sustain", 1.0 - get(in, "dampen", 0.0, 0.0, 1.0));
    if (instrument == 1) carry(in, out, "motor", 0.0, 8.0);
    sharedKnobs(in, out, Model::Mallets, true);
}

void mapOrganPipe(const Params& in, Params& out) {
    // Timber's drawbars are pure sines: the flue stops nearest each footage.
    // Bittern's default stops off; its Pedal on every key, as the 16' drawbar sounded under every note.
    for (const char* k : {"principal8", "octave4"}) put(out, k, 0.0);
    put(out, "pedal", 1.0);
    put(out, "bourdon16", std::max(bar(in, "db16", 8), 0.5 * bar(in, "db513", 8)));
    put(out, "rohrflute8", bar(in, "db8", 8));
    put(out, "flute4", bar(in, "db4", 0));
    put(out, "nazard", bar(in, "db223", 0));
    put(out, "fifteenth2", bar(in, "db2", 0));
    put(out, "tierce", bar(in, "db135", 0));
    put(out, "mixture", std::max(bar(in, "db113", 0), bar(in, "db1", 0)));
    sharedKnobs(in, out, Model::Organ, false);
}

void mapOrganWheel(const Params& in, Params& out) {
    put(out, "osc2_level", 0.45 * bar(in, "db16", 8));
    put(out, "osc1_level", 0.45 * bar(in, "db8", 8));
    double upper = 0.0;
    for (const char* k : {"db4", "db223", "db2", "db135", "db113", "db1"}) upper = std::max(upper, bar(in, k, 0));
    const double quint = bar(in, "db513", 8);
    if (quint >= upper) {
        put(out, "osc3_level", 0.45 * quint);
    } else {  // the upper drawbars: the Additive table's drawbar frame at 8'
        put(out, "osc3_table", 6), put(out, "osc3_frame", 5.0 / 7.0), put(out, "osc3_semi", 0), put(out, "osc3_level", 0.45 * upper);
    }
    const int rotary = pick(in, "rotary", 4), vibrato = pick(in, "vibrato", 7);
    if (rotary == 0 && vibrato == 0) {
        put(out, "fx_chorus_on", 0);
    } else if (rotary == 0) {  // the scanner: V1-V3 the wet alone, C1-C3 mixed with the dry
        put(out, "fx_chorus_rate", 6.9), put(out, "fx_chorus_depth", 0.1 + 0.1 * ((vibrato - 1) % 3 + 1));
        put(out, "fx_chorus_mix", vibrato <= 3 ? 0.9 : 0.5);
    } else if (rotary >= 2) {  // Fast (and Brake, heard fast)
        put(out, "fx_chorus_rate", 6.0), put(out, "fx_chorus_depth", 0.35), put(out, "fx_chorus_mix", 0.5);
    }
    const double drive = get(in, "drive", 0.1, 0.0, 1.0);
    if (drive > 0.05) put(out, "fx_dist_on", 1), put(out, "fx_dist_type", 0), put(out, "fx_dist_drive", 1.0 + 5.0 * drive);
    kestrelShared(in, out, Model::Organ);
}

void mapEPiano(const Params& in, Params& out, int kind) {
    const bool tine = kind == 0;
    put(out, "osc1_warp_amt", (tine ? 0.1 : 0.22) * (0.4 + 1.2 * get(in, "pickup", 0.5, 0.0, 1.0)));
    const double bark = get(in, "bark", 0.2, 0.0, 1.0);
    put(out, "mod2_amt", 0.1 + 0.4 * bark);
    if (bark > 0.3) put(out, "fx_dist_on", 1), put(out, "fx_dist_type", 0), put(out, "fx_dist_drive", 1.0 + 4.0 * bark);
    put(out, "mod3_amt", (tine ? 0.4 : 0.24) * get(in, "bell", 0.5, 0.0, 1.0));
    put(out, "mod4_amt", (tine ? 0.8 : 0.5) * get(in, "tremolo", 0.0, 0.0, 1.0));
    put(out, "lfo1_rate", get(in, "rate", 4.0, 0.5, 12.0));
    const double decay = get(in, "decay", 1.0, 0.25, 4.0);
    put(out, "env1_decay", (tine ? 3.0 : 2.0) * decay);
    put(out, "env2_decay", (tine ? 0.5 : 0.3) * decay);
    put(out, "velocity", get(in, "velocity", 0.8, 0.0, 1.0));
    kestrelShared(in, out, Model::EPiano);
}

// Keeps only the destination's parameters, each finite and in its range.
void fit(Params& out, const ModuleDescriptor* d) {
    if (!d) return;
    Params kept;
    for (auto& [k, v] : out) {
        if (k == fx::kVariantParam) {
            kept.emplace_back(k, v);
            continue;
        }
        const ParameterDescriptor* p = paramOf(d, k);
        if (!p) continue;
        kept.emplace_back(k, std::isfinite(v) ? std::clamp(v, p->minimum, p->maximum) : p->defaultValue);
    }
    out = std::move(kept);
}

// Starling's plucked variant, or its piano while that variant does not exist yet (the TODO above); the preset is the
// variant's first.
Destination pluckedDestination(int instrument) {
    const int want = kPluckedVariant[instrument];
    const fx::MergedDevice* d = fx::findMergedDevice(starling::kStarlingId);
    if (d && static_cast<size_t>(want) < d->variants.size())
        for (const BuiltinPreset& b : builtinPresets(starling::kStarlingId))
            for (const auto& [k, v] : b.values)
                if (k == fx::kVariantParam && v == want) return {starling::kStarlingId, want, b.name};
    return {starling::kStarlingId, 0, kPluckedFallback[instrument]};
}

constexpr std::string_view kKnobs[] = {
    "variant", "tone", "body", "space", "velocity", "release", "voices", "level", "sim", "noises",
    // Piano
    "hammer", "character", "unison", "stretch", "decay", "sustain", "soft", "resonance", "tier", "noise", "touch",
    "action", "glide", "sympathy", "phantom",
    // Electric piano
    "kind", "pickup", "symmetry", "bell", "bark", "tremolo", "rate",
    // Organ
    "db16", "db513", "db8", "db4", "db223", "db2", "db135", "db113", "db1", "perc", "perc_decay", "vibrato", "click",
    "drive", "rotary",
    // Plucked, Bowed, Mallets, Winds
    "instrument", "position", "pick", "damping", "brightness", "section", "pressure", "speed", "vib_rate", "attack",
    "hardness", "dampen", "motor", "breath", "reed", "growl"};

}  // namespace

Model timberModel(const Params& params) noexcept {
    double v = 0.0;
    for (const auto& [k, x] : params)
        if (k == fx::kVariantParam) v = x;
    if (!std::isfinite(v) || v < 0.0) return Model::Piano;
    return static_cast<Model>(static_cast<int>(std::floor(std::min(v, 6.0) + 0.5)));
}

Destination timberDestination(const Params& p) noexcept {
    switch (timberModel(p)) {
        case Model::Piano: return {starling::kStarlingId, 0, kPianoPresets[pick(p, "character", 3)]};
        case Model::EPiano: return {kKestrelId, 0, kEpPresets[pick(p, "kind", 2)]};
        case Model::Organ:
            return organPipeLike(p) ? Destination{bittern::kBitternId, 0, kOrganPipePreset}
                                    : Destination{kKestrelId, 0, kOrganWheelPreset};
        case Model::Plucked: return pluckedDestination(pick(p, "instrument", 4));
        case Model::Bowed: {
            const int i = pick(p, "section", 4);
            return {nightingale::kNightingaleId, i, kBowedPresets[i]};
        }
        case Model::Mallets: {
            const int i = pick(p, "instrument", 6);
            return {woodpecker::kWoodpeckerId, kMalletVariant[i], kMalletPresets[i]};
        }
        case Model::Winds:
        default: {
            const int i = pick(p, "instrument", 4);
            return {curlew::kCurlewId, kWindVariant[i], kWindPresets[i]};
        }
    }
}

bool migrateTimber(std::string& id, Params& params, std::string* preset) {
    if (id != kTimberId) return false;
    const Destination to = timberDestination(params);
    const Model m = timberModel(params);
    Params out;
    switch (m) {
        case Model::Piano: mapPiano(params, out); break;
        case Model::EPiano: mapEPiano(params, out, pick(params, "kind", 2)); break;
        case Model::Organ: to.id == bittern::kBitternId ? mapOrganPipe(params, out) : mapOrganWheel(params, out); break;
        case Model::Plucked: mapPlucked(params, out, to); break;
        case Model::Bowed: mapBowed(params, out); break;
        case Model::Mallets: mapMallets(params, out, pick(params, "instrument", 6)); break;
        case Model::Winds: mapWinds(params, out); break;
    }
    applyBuiltinPreset(to.id, to.preset, out);  // the preset's values under the mapped knobs (its `variant` among them)
    if (fx::findMergedDevice(to.id)) put(out, fx::kVariantParam, to.variant);
    fit(out, descriptorOf(to.id, to.variant));
    id = std::string(to.id);
    params = std::move(out);
    if (preset) *preset = std::string(to.preset);
    return true;
}

std::string migratedTimberParameter(const Params& oldParams, std::string_view param) {
    const Destination to = timberDestination(oldParams);
    const Model m = timberModel(oldParams);
    std::string_view target;
    const auto among = [&](std::initializer_list<std::string_view> ids) {
        for (std::string_view k : ids)
            if (k == param) return true;
        return false;
    };
    if (to.id == kKestrelId) {
        if (param == "release") target = "env1_release";
        else if (m == Model::EPiano && param == "velocity") target = "velocity";
        else if (m == Model::EPiano && param == "rate") target = "lfo1_rate";
    } else if (among({"tone", "space", "velocity", "release", "level"})) {
        target = param;
    } else if (param == "body" && (m == Model::Piano || m == Model::Mallets)) {
        target = param;
    } else if (m == Model::Piano && among({"hammer", "unison", "stretch", "decay", "sustain", "soft", "resonance", "noise",
                                           "touch", "glide", "sympathy", "phantom"})) {
        target = param;
    } else if (m == Model::Plucked && among({"decay", "pick", "position", "brightness"})) {
        target = param;
    } else if (m == Model::Bowed && among({"pressure", "speed", "vibrato", "vib_rate", "attack"})) {
        target = param;
    } else if (m == Model::Bowed && param == "noises") {
        target = "noise";
    } else if (m == Model::Winds && among({"breath", "noise", "reed", "vibrato", "vib_rate", "growl", "attack"})) {
        target = param;
    } else if (m == Model::Mallets && among({"hardness", "decay", "motor"})) {
        target = param;
    }
    if (target.empty() || !paramOf(descriptorOf(to.id, to.variant), target)) return {};
    return std::string(target);
}

std::span<const std::string_view> timberKnobs() noexcept { return kKnobs; }

}  // namespace caw::timber
