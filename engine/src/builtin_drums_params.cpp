// org.caw.drums' parameter table: 19 kit-wide parameters, then 119 per pad for 64 pads, each tagged with its group.
#include "builtin_drums_layout.h"

#include <cmath>
#include <deque>
#include <string>
#include <unordered_map>

namespace caw::drums {

namespace {

enum class Kind { Num, Exp, Whole, Choice };

struct Spec {
    std::string_view suffix, name, layer;
    Kind kind;
    double lo, hi, def;
    std::string_view unit;
    const std::string_view* choices = nullptr;
    uint32_t count = 0;
};

template <size_t N>
constexpr uint32_t countOf(const std::string_view (&)[N]) { return static_cast<uint32_t>(N); }

constexpr std::string_view kOffOn[] = {"Off", "On"};
constexpr std::string_view kChans[] = {"Kit", "Any", "1", "2", "3", "4", "5", "6", "7", "8",
                                       "9", "10", "11", "12", "13", "14", "15", "16"};
constexpr std::string_view kTypes[] = {"Kick", "Snare", "Clap", "Closed hat", "Open hat", "Pedal hat", "Tom", "Crash",
                                       "Ride", "Cymbal", "Rim", "Cowbell", "Shaker", "Perc", "808 bass", "FX"};
static_assert(sizeof(kTypes) / sizeof(kTypes[0]) == kTypeCount);
constexpr std::string_view kChokes[] = {"Off", "1", "2", "3", "4", "5", "6", "7", "8"};
constexpr std::string_view kOuts[] = {"Main", "Out 2", "Out 3", "Out 4", "Out 5", "Out 6", "Out 7", "Out 8", "Out 9"};
constexpr std::string_view kPress[] = {"Off", "Damp", "Choke", "Tone", "Pitch"};
constexpr std::string_view kTrigs[] = {"One-shot", "Gate"};
constexpr std::string_view kWaves[] = {"Sine", "Triangle", "Saw", "Square"};
constexpr std::string_view kSubOct[] = {"-1 oct", "-2 oct"};
constexpr std::string_view kClicks[] = {"Noise", "Impulse", "Blip", "Tick", "Chirp", "Pop"};
constexpr std::string_view kNoiseModes[] = {"Normal", "Snappy", "Clap"};
constexpr std::string_view kColors[] = {"White", "Pink", "Brown", "Crushed"};
constexpr std::string_view kFilters[] = {"Off", "Low-pass", "Band-pass", "High-pass"};
constexpr std::string_view kMetalModes[] = {"Squares", "FM pairs", "Ring"};
constexpr std::string_view kSets[] = {"808", "Bright", "Cymbal", "Cowbell", "Gong", "Bell", "Harmonic"};
constexpr std::string_view kModels[] = {"Membrane", "Plate", "Bar", "Tube", "Bell", "Cymbal"};
constexpr std::string_view kExciters[] = {"Layers", "Mallet", "Noise"};
constexpr std::string_view kDrives[] = {"Off", "Soft", "Hard", "Fold", "Crush", "Tube"};
constexpr std::string_view kDrivePos[] = {"Pre filter", "Post filter"};
constexpr std::string_view kVoiceFilters[] = {"Off", "LP 6 dB", "LP 12 dB", "High-pass", "Band-pass"};
constexpr std::string_view kModes[] = {"Kit", "Single"};
constexpr std::string_view kGlobalChans[] = {"Any", "1", "2", "3", "4", "5", "6", "7", "8",
                                             "9", "10", "11", "12", "13", "14", "15", "16"};
constexpr std::string_view kKitDrives[] = {"Off", "Soft", "Tape", "Hard", "Crush"};

// The note choices: Auto, Off, Any other, then every MIDI note (C4 = 60).
struct NoteLabels {
    std::string text[kNoteFirst + 128];
    std::string_view view[kNoteFirst + 128];
    NoteLabels() {
        text[kNoteAuto] = "Auto";
        text[kNoteOff] = "Off";
        text[kNoteAny] = "Any other";
        static const char* const names[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
        for (int n = 0; n < 128; ++n)
            text[kNoteFirst + n] = std::string(names[n % 12]) + std::to_string(n / 12 - 1) + " (" + std::to_string(n) + ")";
        for (int i = 0; i < kNoteFirst + 128; ++i) view[i] = text[i];
    }
};
const NoteLabels& noteLabels() {
    static const NoteLabels l;
    return l;
}
struct PadLabels {
    std::string text[kPads + 1];
    std::string_view view[kPads + 1];
    PadLabels() {
        text[0] = "Last hit";
        for (uint32_t p = 0; p < kPads; ++p) text[p + 1] = padName(p);
        for (uint32_t i = 0; i <= kPads; ++i) view[i] = text[i];
    }
};
const PadLabels& padLabels() {
    static const PadLabels l;
    return l;
}

#define CHOICE(s, n, layer, def, labels) {s, n, layer, Kind::Choice, 0, countOf(labels) - 1.0, def, {}, labels, countOf(labels)}

// One pad's parameters, in PadParam order; `def` is the neutral pad's value.
const Spec* padSpecs() {
    static const Spec specs[kPadParams] = {
        {"note", "Note", "pad", Kind::Choice, 0, static_cast<double>(kNoteFirst) + 127.0, kNoteAuto, {}, nullptr, kNoteFirst + 128},
        CHOICE("chan", "MIDI channel", "pad", 0, kChans),
        CHOICE("type", "Drum type", "pad", kTypePerc, kTypes),
        {"level", "Level", "pad", Kind::Num, -60, 12, 0, "dB"},
        {"pan", "Pan", "pad", Kind::Num, -1, 1, 0, {}},
        {"tune", "Tune", "pad", Kind::Num, -48, 48, 0, "st"},
        CHOICE("track", "Pitch tracking", "pad", 0, kOffOn),
        {"root", "Root note", "pad", Kind::Whole, 0, 127, 60, {}},
        CHOICE("mono", "Mono", "pad", 0, kOffOn),
        {"glide", "Glide", "pad", Kind::Exp, 0.001, 2, 0.08, "s"},
        CHOICE("trig", "Trigger", "pad", kOneShot, kTrigs),
        {"release", "Release", "pad", Kind::Exp, 0.001, 5, 0.1, "s"},
        {"poly", "Polyphony", "pad", Kind::Whole, 1, 4, 2, {}},
        CHOICE("choke", "Choke group", "pad", 0, kChokes),
        CHOICE("out", "Output", "pad", 0, kOuts),
        CHOICE("press_dest", "Pressure", "pad", kPressOff, kPress),
        {"press_amt", "Pressure amount", "pad", Kind::Num, -1, 1, 0.5, {}},

        CHOICE("body_on", "Body", "body", 0, kOffOn),
        CHOICE("body_wave", "Body wave", "body", kWaveSine, kWaves),
        {"body_shape", "Body shape", "body", Kind::Num, 0, 1, 0, {}},
        {"body_fold", "Body fold", "body", Kind::Num, 0, 1, 0, {}},
        {"body_freq", "Body pitch", "body", Kind::Exp, 20, 2000, 55, "Hz"},
        {"body_pitch", "Pitch envelope", "body", Kind::Num, 0, 96, 24, "st"},
        {"body_ptime", "Pitch time", "body", Kind::Exp, 0.001, 2, 0.05, "s"},
        {"body_pcurve", "Pitch curve", "body", Kind::Num, -1, 1, 0, {}},
        {"body_attack", "Body attack", "body", Kind::Exp, 0.0001, 0.5, 0.0005, "s"},
        {"body_hold", "Body hold", "body", Kind::Num, 0, 2, 0, "s"},
        {"body_decay", "Body decay", "body", Kind::Exp, 0.01, 10, 0.4, "s"},
        {"body_dcurve", "Body decay curve", "body", Kind::Num, -1, 1, 0, {}},
        {"body_p2_ratio", "Second partial ratio", "body", Kind::Exp, 0.5, 8, 1.5, {}},
        {"body_p2_level", "Second partial level", "body", Kind::Num, 0, 1, 0, {}},
        {"body_sub", "Sub level", "body", Kind::Num, 0, 1, 0, {}},
        CHOICE("body_sub_oct", "Sub octave", "body", 0, kSubOct),
        {"body_phase", "Start phase", "body", Kind::Num, 0, 1, 0, {}},
        {"body_level", "Body level", "body", Kind::Num, -60, 12, 0, "dB"},

        CHOICE("click_on", "Click", "click", 0, kOffOn),
        CHOICE("click_type", "Click type", "click", kClickNoise, kClicks),
        {"click_level", "Click level", "click", Kind::Num, 0, 1, 0.5, {}},
        {"click_tone", "Click tone", "click", Kind::Exp, 100, 16000, 2000, "Hz"},
        {"click_length", "Click length", "click", Kind::Exp, 0.0005, 0.1, 0.008, "s"},

        CHOICE("noise_on", "Noise", "noise", 0, kOffOn),
        CHOICE("noise_mode", "Noise mode", "noise", kNoiseNormal, kNoiseModes),
        CHOICE("noise_color", "Noise colour", "noise", kWhite, kColors),
        CHOICE("noise_filter", "Noise filter", "noise", kFilterHp, kFilters),
        {"noise_freq", "Noise frequency", "noise", Kind::Exp, 20, 20000, 2000, "Hz"},
        {"noise_res", "Noise resonance", "noise", Kind::Num, 0, 1, 0, {}},
        {"noise_sweep", "Noise sweep", "noise", Kind::Num, -6, 6, 0, "oct"},
        {"noise_attack", "Noise attack", "noise", Kind::Exp, 0.0001, 1, 0.001, "s"},
        {"noise_decay", "Noise decay", "noise", Kind::Exp, 0.005, 10, 0.2, "s"},
        {"noise_dcurve", "Noise decay curve", "noise", Kind::Num, -1, 1, 0, {}},
        {"noise_bursts", "Clap bursts", "noise", Kind::Whole, 1, 8, 3, {}},
        {"noise_spacing", "Clap spacing", "noise", Kind::Exp, 0.002, 0.05, 0.01, "s"},
        {"noise_level", "Noise level", "noise", Kind::Num, -60, 12, 0, "dB"},

        CHOICE("metal_on", "Metal", "metal", 0, kOffOn),
        CHOICE("metal_mode", "Metal mode", "metal", kMetalSquare, kMetalModes),
        CHOICE("metal_set", "Metal ratios", "metal", kSet808, kSets),
        {"metal_freq", "Metal pitch", "metal", Kind::Exp, 50, 2000, 410.6, "Hz"},
        {"metal_spread", "Metal spread", "metal", Kind::Num, -1, 1, 0, {}},
        {"metal_fm", "FM index", "metal", Kind::Num, 0, 10, 2, {}},
        {"metal_tone", "Metal high-pass", "metal", Kind::Exp, 200, 16000, 7000, "Hz"},
        {"metal_color", "Metal band", "metal", Kind::Exp, 200, 16000, 8000, "Hz"},
        {"metal_band", "Band-pass amount", "metal", Kind::Num, 0, 1, 0, {}},
        {"metal_res", "Metal resonance", "metal", Kind::Num, 0, 1, 0.16, {}},
        {"metal_attack", "Metal attack", "metal", Kind::Exp, 0.0001, 0.5, 0.0005, "s"},
        {"metal_decay", "Metal decay", "metal", Kind::Exp, 0.005, 10, 0.05, "s"},
        {"metal_dcurve", "Metal decay curve", "metal", Kind::Num, -1, 1, 0, {}},
        {"metal_open", "Openness", "metal", Kind::Num, 0, 1, 0, {}},
        {"metal_noise", "Metal noise", "metal", Kind::Num, 0, 1, 0.5, {}},
        {"metal_level", "Metal level", "metal", Kind::Num, -60, 12, 0, "dB"},

        CHOICE("res_on", "Resonator", "res", 0, kOffOn),
        CHOICE("res_model", "Resonator model", "res", 0, kModels),
        {"res_freq", "Resonator pitch", "res", Kind::Exp, 20, 8000, 150, "Hz"},
        {"res_decay", "Resonator decay", "res", Kind::Exp, 0.01, 20, 0.6, "s"},
        {"res_damp", "Damping", "res", Kind::Num, 0, 1, 0.4, {}},
        {"res_bright", "Brightness", "res", Kind::Num, 0, 1, 0.5, {}},
        {"res_inharm", "Inharmonicity", "res", Kind::Num, -1, 1, 0, {}},
        {"res_pos", "Strike position", "res", Kind::Num, 0, 1, 0.3, {}},
        CHOICE("res_exciter", "Exciter", "res", kExciteMallet, kExciters),
        {"res_input", "Layers into resonator", "res", Kind::Num, 0, 1, 0.2, {}},
        {"res_level", "Resonator level", "res", Kind::Num, -60, 12, 0, "dB"},

        CHOICE("smp_on", "Sample", "smp", 0, kOffOn),
        {"smp_start", "Sample start", "smp", Kind::Num, 0, 1, 0, {}},
        {"smp_end", "Sample end", "smp", Kind::Num, 0, 1, 1, {}},
        {"smp_tune", "Sample tune", "smp", Kind::Num, -48, 48, 0, "st"},
        CHOICE("smp_reverse", "Reverse", "smp", 0, kOffOn),
        {"smp_attack", "Sample attack", "smp", Kind::Exp, 0.0001, 1, 0.0001, "s"},
        {"smp_decay", "Sample decay", "smp", Kind::Exp, 0.01, 30, 30, "s"},
        {"smp_level", "Sample level", "smp", Kind::Num, -60, 12, 0, "dB"},

        CHOICE("drive_type", "Drive type", "fx", kDriveOff, kDrives),
        {"drive", "Drive", "fx", Kind::Exp, 1, 20, 2, {}},
        CHOICE("drive_pos", "Drive position", "fx", 0, kDrivePos),
        CHOICE("flt", "Filter", "fx", kVfOff, kVoiceFilters),
        {"cutoff", "Cutoff", "fx", Kind::Exp, 20, 20000, 12000, "Hz"},
        {"flt_res", "Filter resonance", "fx", Kind::Num, 0, 1, 0, {}},
        {"flt_env", "Filter envelope", "fx", Kind::Num, -6, 6, 0, "oct"},
        {"flt_decay", "Filter decay", "fx", Kind::Exp, 0.005, 5, 0.2, "s"},
        {"eq_low", "EQ low", "fx", Kind::Num, -18, 18, 0, "dB"},
        {"eq_mid", "EQ mid", "fx", Kind::Num, -18, 18, 0, "dB"},
        {"eq_freq", "EQ mid frequency", "fx", Kind::Exp, 80, 12000, 1000, "Hz"},
        {"eq_high", "EQ high", "fx", Kind::Num, -18, 18, 0, "dB"},
        {"tr_attack", "Transient attack", "fx", Kind::Num, -1, 1, 0, {}},
        {"tr_sustain", "Transient sustain", "fx", Kind::Num, -1, 1, 0, {}},
        {"comp", "Compressor", "fx", Kind::Num, 0, 1, 0, {}},

        {"punch", "Punch", "macro", Kind::Num, -1, 1, 0, {}},
        {"tone", "Tone", "macro", Kind::Num, -1, 1, 0, {}},
        {"snap", "Snap", "macro", Kind::Num, -1, 1, 0, {}},
        {"length", "Length", "macro", Kind::Num, -1, 1, 0, {}},
        {"dirt", "Dirt", "macro", Kind::Num, -1, 1, 0, {}},
        {"pitch", "Pitch", "macro", Kind::Num, -1, 1, 0, {}},

        {"vel_level", "Velocity to level", "var", Kind::Num, 0, 1, 1, {}},
        {"vel_pitch", "Velocity to pitch", "var", Kind::Num, 0, 24, 0, "st"},
        {"vel_decay", "Velocity to decay", "var", Kind::Num, -1, 1, 0, {}},
        {"vel_tone", "Velocity to tone", "var", Kind::Num, -1, 1, 0.3, {}},
        {"vel_click", "Velocity to click", "var", Kind::Num, 0, 1, 0.5, {}},
        {"rnd_pitch", "Random pitch", "var", Kind::Num, 0, 100, 0, "ct"},
        {"rnd_decay", "Random decay", "var", Kind::Num, 0, 1, 0, {}},
        {"rnd_tone", "Random tone", "var", Kind::Num, 0, 1, 0, {}},
        {"rnd_pan", "Random pan", "var", Kind::Num, 0, 1, 0, {}},
        {"rnd_level", "Random level", "var", Kind::Num, 0, 1, 0, {}},
    };
    return specs;
}

const Spec* globalSpecs() {
    static const Spec specs[kGlobalCount] = {
        CHOICE("mode", "Mode", "main", kModeKit, kModes),
        CHOICE("channel", "MIDI channel", "main", 0, kGlobalChans),
        {"base_note", "First pad note", "main", Kind::Whole, 0, 64, 36, {}},
        {"volume", "Volume", "main", Kind::Num, -60, 12, 0, "dB"},
        {"seed", "Variation seed", "main", Kind::Whole, 0, 65535, 1, {}},
        {"view_pad", "Shown pad", "main", Kind::Choice, 0, kPads, 0, {}, nullptr, kPads + 1},
        {"glue", "Glue", "glue", Kind::Num, 0, 1, 0, {}},
        {"glue_threshold", "Glue threshold", "glue", Kind::Num, -40, 0, -12, "dB"},
        {"glue_ratio", "Glue ratio", "glue", Kind::Exp, 1, 20, 4, {}},
        {"glue_attack", "Glue attack", "glue", Kind::Exp, 0.1, 100, 10, "ms"},
        {"glue_release", "Glue release", "glue", Kind::Exp, 10, 1000, 120, "ms"},
        {"glue_makeup", "Glue makeup", "glue", Kind::Num, 0, 24, 0, "dB"},
        CHOICE("kit_drive_type", "Kit drive", "drive", 0, kKitDrives),
        {"kit_drive", "Kit drive amount", "drive", Kind::Exp, 1, 20, 2, {}},
        {"kit_drive_mix", "Kit drive mix", "drive", Kind::Num, 0, 1, 1, {}},
        {"room", "Room", "room", Kind::Num, 0, 1, 0, {}},
        {"room_size", "Room size", "room", Kind::Num, 0, 1, 0.35, {}},
        {"room_decay", "Room decay", "room", Kind::Exp, 0.1, 10, 0.8, "s"},
        {"room_damping", "Room damping", "room", Kind::Num, 0, 1, 0.5, {}},
    };
    return specs;
}
#undef CHOICE

void fill(ParameterDescriptor& p, const Spec& s, std::string_view id, std::string_view name, std::string_view group,
          double def) {
    p.id = id;
    p.name = name;
    p.group = group;
    p.minimum = s.lo;
    p.maximum = s.hi;
    p.defaultValue = def;
    p.unit = s.unit;
    p.smoothingFrames = 480;  // 10 ms at 48 kHz
    switch (s.kind) {
        case Kind::Exp: p.curve = ParameterCurve::Exponential; break;
        case Kind::Whole:
            p.step = 1.0;
            p.smoothingFrames = 0;
            break;
        case Kind::Choice:
            p.step = 1.0;
            p.smoothingFrames = 0;
            p.choiceCount = s.count;
            break;
        case Kind::Num: break;
    }
}

struct Table {
    ParameterDescriptor d[kParamCount];
    std::deque<std::string> text;  // a deque never moves its strings
    std::unordered_map<std::string_view, int> index;

    std::string_view keep(std::string s) {
        text.push_back(std::move(s));
        return text.back();
    }
    Table() {
        const Spec* g = globalSpecs();
        for (uint32_t k = 0; k < kGlobalCount; ++k) {
            fill(d[k], g[k], g[k].suffix, g[k].name, keep("kit/" + std::string(g[k].layer)), g[k].def);
            d[k].choices = g[k].choices;
        }
        d[kViewPad].choices = padLabels().view;
        d[kViewPad].automatable = false;  // what the editor shows, not sound
        d[kViewPad].modulatable = false;
        d[kViewPad].midiMappable = false;
        const Spec* s = padSpecs();
        for (uint32_t pad = 0; pad < kPads; ++pad) {
            const Voice& def = defaultVoice(pad);
            const std::string pid = padId(pad), pname = padName(pad);
            for (uint32_t k = 0; k < kPadParams; ++k) {
                ParameterDescriptor& p = d[padParam(pad, k)];
                fill(p, s[k], keep(pid + "_" + std::string(s[k].suffix)), keep(pname + " " + std::string(s[k].name)),
                     keep(pid + "/" + std::string(s[k].layer)), def[k]);
                p.choices = k == kNote ? noteLabels().view : s[k].choices;
            }
        }
        for (uint32_t k = 0; k < kParamCount; ++k) index.emplace(d[k].id, static_cast<int>(k));
    }
};

const Table& table() {
    static const Table t;
    return t;
}

}  // namespace

std::string padId(uint32_t pad) {
    return std::string(1, static_cast<char>('a' + pad / kPadsPerBank)) + std::to_string(pad % kPadsPerBank + 1);
}
std::string padName(uint32_t pad) {
    return std::string(1, static_cast<char>('A' + pad / kPadsPerBank)) + std::to_string(pad % kPadsPerBank + 1);
}

const Voice& neutralVoice() {
    static const Voice v = [] {
        Voice x{};
        const Spec* s = padSpecs();
        for (uint32_t k = 0; k < kPadParams; ++k) x[k] = s[k].def;
        return x;
    }();
    return v;
}

std::string_view padParamSuffix(uint32_t p) { return p < kPadParams ? padSpecs()[p].suffix : std::string_view{}; }

const ParameterDescriptor& padParamDescriptor(uint32_t pad, uint32_t p) { return table().d[padParam(pad, p)]; }

const ParameterDescriptor* parameterTable() { return table().d; }

int padParamIndex(std::string_view suffix) {
    static const std::unordered_map<std::string_view, int> m = [] {
        std::unordered_map<std::string_view, int> x;
        for (uint32_t k = 0; k < kPadParams; ++k) x.emplace(padSpecs()[k].suffix, static_cast<int>(k));
        return x;
    }();
    const auto it = m.find(suffix);
    return it == m.end() ? -1 : it->second;
}

int parameterIndex(std::string_view id) {
    const auto& m = table().index;
    const auto it = m.find(id);
    return it == m.end() ? -1 : it->second;
}

double constrainPad(uint32_t p, double v) {
    if (p >= kPadParams) return 0.0;
    const Spec& s = padSpecs()[p];
    if (!std::isfinite(v)) v = s.def;
    v = v < s.lo ? s.lo : (v > s.hi ? s.hi : v);
    if (s.kind == Kind::Choice || s.kind == Kind::Whole) v = std::floor(v + 0.5);
    return v;
}

std::string_view typeName(int type) { return type >= 0 && type < kTypeCount ? kTypes[type] : std::string_view("Perc"); }

}  // namespace caw::drums
