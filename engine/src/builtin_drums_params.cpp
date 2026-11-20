// org.caw.drums' parameter table: the kit-wide parameters, 217 per pad for 64 pads, then the Acoustic kit (its settings and 16 pieces), each tagged with its group.
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
constexpr std::string_view kPenvModes[] = {"Curve", "Points"};
constexpr std::string_view kSubWaves[] = {"Sine", "Triangle", "Warm"};
constexpr std::string_view kSubOcts[] = {"0 oct", "-1 oct", "-2 oct"};
constexpr std::string_view kSubRoutes[] = {"Clean", "Through effects"};
constexpr std::string_view kClips[] = {"Off", "Soft", "Hard"};
constexpr std::string_view kTrigs[] = {"One-shot", "Gate"};
constexpr std::string_view kWaves[] = {"Sine", "Triangle", "Saw", "Square"};
constexpr std::string_view kClicks[] = {"Noise", "Impulse", "Blip", "Tick", "Chirp", "Pop"};
constexpr std::string_view kNoiseModes[] = {"Normal", "Snappy", "Clap"};
constexpr std::string_view kColors[] = {"White", "Pink", "Brown", "Crushed"};
constexpr std::string_view kFilters[] = {"Off", "Low-pass", "Band-pass", "High-pass"};
constexpr std::string_view kMetalModes[] = {"Squares", "FM pairs", "Ring"};
constexpr std::string_view kSets[] = {"808", "Bright", "Cymbal", "Cowbell", "Gong", "Bell", "Harmonic"};
constexpr std::string_view kModels[] = {"Membrane", "Plate", "Bar", "Tube", "Bell", "Cymbal"};
constexpr std::string_view kExciters[] = {"Layers", "Mallet", "Noise"};
constexpr std::string_view kDrives[] = {"Off", "Soft", "Hard", "Fold", "Crush", "Tube", "Rectify", "Decimate", "Asymmetric"};
constexpr std::string_view kDrivePos[] = {"Pre filter", "Post filter"};
constexpr std::string_view kVoiceFilters[] = {"Off", "LP 6 dB", "LP 12 dB", "High-pass", "Band-pass"};
constexpr std::string_view kModes[] = {"Kit", "Single"};
constexpr std::string_view kGlobalChans[] = {"Any", "1", "2", "3", "4", "5", "6", "7", "8",
                                             "9", "10", "11", "12", "13", "14", "15", "16"};
constexpr std::string_view kKitDrives[] = {"Off", "Soft", "Tape", "Hard", "Crush"};
constexpr std::string_view kPhysModels[] = {"String", "Pipe", "Stiff string"};
constexpr std::string_view kPhysExciters[] = {"Pluck", "Noise", "Layers"};
constexpr std::string_view kTexModes[] = {"Bands", "Dust", "Crackle"};
constexpr std::string_view kSwingGrids[] = {"1/16", "1/8"};
constexpr std::string_view kAccentOns[] = {"Beats", "Bar starts", "Off-beats", "Loud hits"};
constexpr std::string_view kGrooves[] = {"Off", "Shuffle", "Laid back", "Gallop", "Broken", "Half-time"};
constexpr std::string_view kEchoSyncs[] = {"Free", "1/16", "1/8", "1/8 dotted", "1/4", "1/8 triplet"};
// 1.1.2
constexpr std::string_view kEngines[] = {"Layers", "Acoustic"};
constexpr std::string_view kPieceNames[] = {"Piece 1", "Piece 2",  "Piece 3",  "Piece 4",  "Piece 5",  "Piece 6",
                                            "Piece 7", "Piece 8",  "Piece 9",  "Piece 10", "Piece 11", "Piece 12",
                                            "Piece 13", "Piece 14", "Piece 15", "Piece 16"};
constexpr std::string_view kLayerPieces[] = {"Off",      "Piece 1",  "Piece 2",  "Piece 3",  "Piece 4",  "Piece 5",
                                             "Piece 6",  "Piece 7",  "Piece 8",  "Piece 9",  "Piece 10", "Piece 11",
                                             "Piece 12", "Piece 13", "Piece 14", "Piece 15", "Piece 16"};
constexpr std::string_view kArtics[] = {"Hit", "Off-centre", "Edge", "Bell", "Rimshot", "Cross-stick", "Rim click",
                                        "Flam", "Roll", "Buzz", "Choke", "Closed", "Open", "Foot"};
static_assert(sizeof(kArtics) / sizeof(kArtics[0]) == kArtCount);
constexpr std::string_view kKitKinds[] = {"Custom", "Synth", "Produced", "Acoustic"};
constexpr std::string_view kMicSetups[] = {"Dry close", "Studio", "Room", "Overheads"};
constexpr std::string_view kSticks[] = {"Sticks", "Hot rods", "Brushes", "Mallets"};
constexpr std::string_view kPieceKinds[] = {"Off", "Kick", "Snare", "Tom", "Hi-hat", "Crash", "Ride", "Splash", "China"};
static_assert(sizeof(kPieceKinds) / sizeof(kPieceKinds[0]) == kPieceKindCount);
constexpr std::string_view kHeads[] = {"Coated", "Clear", "Coated 2-ply", "Clear 2-ply", "Calfskin"};
constexpr std::string_view kShells[] = {"Maple", "Birch", "Mahogany", "Oak", "Steel", "Brass", "Acrylic"};
constexpr std::string_view kAlloys[] = {"B20 bronze", "B8 bronze", "Brass", "Dark (lathed)"};
constexpr std::string_view kBeaters[] = {"Felt", "Plastic", "Wood", "Fleece"};

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

        {"press_damp", "Pressure to damp", "press", Kind::Num, 0, 1, 0, {}},
        CHOICE("press_choke", "Pressure chokes", "press", 0, kOffOn),
        {"press_tone", "Pressure to tone", "press", Kind::Num, -1, 1, 0, {}},
        {"press_pitch", "Pressure to pitch", "press", Kind::Num, -12, 12, 0, "st"},
        {"press_level", "Pressure to level", "press", Kind::Num, -1, 1, 0, {}},
        {"press_drive", "Pressure to drive", "press", Kind::Num, 0, 1, 0, {}},

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
        {"body_phase", "Start phase", "body", Kind::Num, 0, 1, 0, {}},
        {"body_level", "Body level", "body", Kind::Num, -60, 12, 0, "dB"},

        CHOICE("penv_mode", "Pitch shape", "penv", kPenvCurve, kPenvModes),
        {"penv_t1", "Point 1 time", "penv", Kind::Exp, 0.0005, 2, 0.004, "s"},
        {"penv_p1", "Point 1 pitch", "penv", Kind::Num, -24, 96, 12, "st"},
        {"penv_c1", "Segment 1 curve", "penv", Kind::Num, -1, 1, 0.5, {}},
        {"penv_t2", "Point 2 time", "penv", Kind::Exp, 0.0005, 2, 0.02, "s"},
        {"penv_p2", "Point 2 pitch", "penv", Kind::Num, -24, 96, 3, "st"},
        {"penv_c2", "Segment 2 curve", "penv", Kind::Num, -1, 1, 0.5, {}},
        {"penv_t3", "Point 3 time", "penv", Kind::Exp, 0.0005, 2, 0.08, "s"},
        {"penv_p3", "Point 3 pitch", "penv", Kind::Num, -24, 96, 0, "st"},
        {"penv_c3", "Segment 3 curve", "penv", Kind::Num, -1, 1, 0.5, {}},
        {"penv_t4", "Point 4 time", "penv", Kind::Exp, 0.0005, 2, 0.2, "s"},
        {"penv_p4", "Point 4 pitch", "penv", Kind::Num, -24, 96, 0, "st"},
        {"penv_c4", "Segment 4 curve", "penv", Kind::Num, -1, 1, 0, {}},

        CHOICE("sub_on", "Sub", "sub", 0, kOffOn),
        CHOICE("sub_wave", "Sub wave", "sub", kSubSine, kSubWaves),
        CHOICE("sub_oct", "Sub octave", "sub", 1, kSubOcts),
        {"sub_fine", "Sub tune", "sub", Kind::Num, -12, 12, 0, "st"},
        {"sub_follow", "Sub follows pitch", "sub", Kind::Num, 0, 1, 0, {}},
        {"sub_attack", "Sub attack", "sub", Kind::Exp, 0.0001, 0.5, 0.005, "s"},
        {"sub_hold", "Sub hold", "sub", Kind::Num, 0, 2, 0, "s"},
        {"sub_decay", "Sub decay", "sub", Kind::Exp, 0.01, 10, 0.6, "s"},
        {"sub_dcurve", "Sub decay curve", "sub", Kind::Num, -1, 1, 0, {}},
        {"sub_drive", "Sub drive", "sub", Kind::Num, 0, 1, 0, {}},
        {"sub_lp", "Sub low-pass", "sub", Kind::Exp, 40, 2000, 2000, "Hz"},
        CHOICE("sub_route", "Sub route", "sub", kSubClean, kSubRoutes),
        {"sub_level", "Sub level", "sub", Kind::Num, -60, 12, -6, "dB"},

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

        CHOICE("drive_type", "Drive type", "drive", kDriveOff, kDrives),
        {"drive", "Drive", "drive", Kind::Exp, 1, 20, 2, {}},
        CHOICE("drive_pos", "Drive position", "drive", 0, kDrivePos),
        {"drive_lo", "Drive low cut", "drive", Kind::Exp, 20, 2000, 20, "Hz"},
        {"drive_hi", "Drive high cut", "drive", Kind::Exp, 500, 20000, 20000, "Hz"},
        {"drive_mix", "Drive mix", "drive", Kind::Num, 0, 1, 1, {}},

        CHOICE("flt", "Filter", "filter", kVfOff, kVoiceFilters),
        {"cutoff", "Cutoff", "filter", Kind::Exp, 20, 20000, 12000, "Hz"},
        {"flt_res", "Filter resonance", "filter", Kind::Num, 0, 1, 0, {}},
        {"flt_env", "Filter envelope", "filter", Kind::Num, -6, 6, 0, "oct"},
        {"flt_decay", "Filter decay", "filter", Kind::Exp, 0.005, 5, 0.2, "s"},

        {"eq_low", "EQ low", "eq", Kind::Num, -18, 18, 0, "dB"},
        {"eq_low_freq", "EQ low frequency", "eq", Kind::Exp, 30, 600, 120, "Hz"},
        {"eq_mid", "EQ mid", "eq", Kind::Num, -18, 18, 0, "dB"},
        {"eq_freq", "EQ mid frequency", "eq", Kind::Exp, 80, 12000, 1000, "Hz"},
        {"eq_q", "EQ mid Q", "eq", Kind::Exp, 0.3, 8, 1, {}},
        {"eq_high", "EQ high", "eq", Kind::Num, -18, 18, 0, "dB"},
        {"eq_high_freq", "EQ high frequency", "eq", Kind::Exp, 1000, 16000, 6000, "Hz"},

        {"tr_attack", "Transient attack", "dyn", Kind::Num, -1, 1, 0, {}},
        {"tr_sustain", "Transient sustain", "dyn", Kind::Num, -1, 1, 0, {}},
        {"comp", "Compressor", "dyn", Kind::Num, 0, 1, 0, {}},
        {"comp_attack", "Compressor attack", "dyn", Kind::Exp, 0.1, 100, 2, "ms"},
        {"comp_release", "Compressor release", "dyn", Kind::Exp, 10, 1000, 60, "ms"},
        CHOICE("clip", "Clipper", "dyn", kClipOff, kClips),
        {"clip_gain", "Clipper drive", "dyn", Kind::Num, 0, 24, 0, "dB"},

        {"width", "Width", "space", Kind::Num, 0, 1, 0, {}},
        {"width_hz", "Mono below", "space", Kind::Exp, 40, 1000, 200, "Hz"},
        {"room_send", "Room send", "space", Kind::Num, 0, 1, 1, {}},

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
        {"vel_punch", "Velocity to pitch drop", "var", Kind::Num, 0, 1, 0, {}},
        {"rnd_pitch", "Random pitch", "var", Kind::Num, 0, 100, 0, "ct"},
        {"rnd_decay", "Random decay", "var", Kind::Num, 0, 1, 0, {}},
        {"rnd_tone", "Random tone", "var", Kind::Num, 0, 1, 0, {}},
        {"rnd_pan", "Random pan", "var", Kind::Num, 0, 1, 0, {}},
        {"rnd_level", "Random level", "var", Kind::Num, 0, 1, 0, {}},
        {"rnd_pos", "Random strike position", "var", Kind::Num, 0, 1, 0, {}},

        CHOICE("fm_on", "FM", "fm", 0, kOffOn),
        {"fm_freq", "FM pitch", "fm", Kind::Exp, 20, 4000, 200, "Hz"},
        {"fm_ratio", "FM ratio", "fm", Kind::Exp, 0.25, 16, 1.41, {}},
        {"fm_index", "FM depth", "fm", Kind::Num, 0, 20, 3, {}},
        {"fm_idecay", "FM depth decay", "fm", Kind::Exp, 0.002, 4, 0.08, "s"},
        {"fm_feedback", "FM feedback", "fm", Kind::Num, 0, 1, 0, {}},
        {"fm_pitch", "FM pitch drop", "fm", Kind::Num, 0, 48, 0, "st"},
        {"fm_ptime", "FM drop time", "fm", Kind::Exp, 0.001, 1, 0.03, "s"},
        {"fm_attack", "FM attack", "fm", Kind::Exp, 0.0001, 0.5, 0.0005, "s"},
        {"fm_decay", "FM decay", "fm", Kind::Exp, 0.005, 10, 0.3, "s"},
        {"fm_dcurve", "FM decay curve", "fm", Kind::Num, -1, 1, 0, {}},
        {"fm_level", "FM level", "fm", Kind::Num, -60, 12, 0, "dB"},

        CHOICE("phys_on", "Physical", "phys", 0, kOffOn),
        CHOICE("phys_model", "Physical model", "phys", kPhysString, kPhysModels),
        {"phys_freq", "Physical pitch", "phys", Kind::Exp, 30, 2000, 110, "Hz"},
        {"phys_decay", "Physical decay", "phys", Kind::Exp, 0.02, 20, 1, "s"},
        {"phys_damp", "Physical damping", "phys", Kind::Num, 0, 1, 0.4, {}},
        {"phys_pick", "Pluck position", "phys", Kind::Num, 0, 1, 0.2, {}},
        CHOICE("phys_exciter", "Physical exciter", "phys", kPhysPluck, kPhysExciters),
        {"phys_input", "Layers into physical", "phys", Kind::Num, 0, 1, 0.3, {}},
        {"phys_level", "Physical level", "phys", Kind::Num, -60, 12, 0, "dB"},

        CHOICE("tex_on", "Texture", "tex", 0, kOffOn),
        CHOICE("tex_mode", "Texture mode", "tex", kTexBands, kTexModes),
        {"tex_freq", "Texture frequency", "tex", Kind::Exp, 40, 16000, 3000, "Hz"},
        {"tex_spread", "Texture spread", "tex", Kind::Num, 0, 4, 1.5, "oct"},
        {"tex_res", "Texture resonance", "tex", Kind::Num, 0, 1, 0.3, {}},
        {"tex_tilt", "Texture tilt", "tex", Kind::Num, -1, 1, 0, {}},
        {"tex_density", "Grain density", "tex", Kind::Exp, 10, 20000, 1500, "Hz"},
        {"tex_attack", "Texture attack", "tex", Kind::Exp, 0.0001, 1, 0.001, "s"},
        {"tex_decay", "Texture decay", "tex", Kind::Exp, 0.005, 10, 0.25, "s"},
        {"tex_dcurve", "Texture decay curve", "tex", Kind::Num, -1, 1, 0, {}},
        {"tex_level", "Texture level", "tex", Kind::Num, -60, 12, 0, "dB"},

        {"smp_pitch", "Sample pitch drop", "smp", Kind::Num, 0, 48, 0, "st"},
        {"smp_ptime", "Sample drop time", "smp", Kind::Exp, 0.001, 1, 0.05, "s"},
        {"smp_hold", "Sample hold", "smp", Kind::Num, 0, 2, 0, "s"},
        {"smp_dcurve", "Sample decay curve", "smp", Kind::Num, -1, 1, 0, {}},
        {"smp_vel_start", "Velocity to start", "smp", Kind::Num, 0, 1, 0, {}},
        {"smp_rnd_start", "Random start", "smp", Kind::Num, 0, 1, 0, {}},

        {"ring_mix", "Ring mod", "fx", Kind::Num, 0, 1, 0, {}},
        {"ring_freq", "Ring frequency", "fx", Kind::Exp, 20, 8000, 440, "Hz"},
        {"echo_send", "Echo send", "fx", Kind::Num, 0, 1, 0, {}},
        {"bus_send", "Kit bus send", "fx", Kind::Num, 0, 1, 1, {}},

        {"swing", "Swing", "groove", Kind::Num, 0, 1, 0, {}},
        CHOICE("swing_grid", "Swing grid", "groove", kGrid16, kSwingGrids),
        {"humanize", "Humanize", "groove", Kind::Num, 0, 1, 0, {}},
        {"accent", "Accent", "groove", Kind::Num, 0, 1, 0, {}},
        CHOICE("accent_on", "Accent on", "groove", kAccentBeats, kAccentOns),
        {"flam", "Flam", "groove", Kind::Num, 0, 1, 0, {}},
        {"flam_time", "Flam time", "groove", Kind::Exp, 0.005, 0.06, 0.02, "s"},
        CHOICE("groove", "Groove", "groove", kGrooveOff, kGrooves),
        {"groove_amt", "Groove amount", "groove", Kind::Num, 0, 1, 1, {}},

        CHOICE("engine", "Engine", "acou", kEngineLayers, kEngines),
        CHOICE("acou_piece", "Piece", "acou", 0, kPieceNames),
        CHOICE("acou_artic", "Articulation", "acou", kArtHit, kArtics),
        CHOICE("acou_layer", "Acoustic layer", "acou", 0, kLayerPieces),
    };
    return specs;
}

// The Acoustic kit's settings ("acou_<suffix>", the kit kind "kit_kind").
const Spec* acouSpecs() {
    static const Spec specs[kAcouCount] = {
        CHOICE("kit_kind", "Kit kind", "kind", kKitCustom, kKitKinds),
        CHOICE("acou_mics", "Mics", "acoustic", kMicsStudio, kMicSetups),
        CHOICE("acou_stick", "Sticks", "acoustic", kStickSticks, kSticks),
        {"acou_hat_pedal", "Hi-hat pedal", "acoustic", Kind::Num, 0, 1, 1, {}},
        {"acou_sympathy", "Sympathetic ring", "acoustic", Kind::Num, 0, 1, 0.5, {}},
        {"acou_bleed", "Mic bleed", "acoustic", Kind::Num, 0, 1, 0.5, {}},
        {"acou_noise", "Mechanical noise", "acoustic", Kind::Num, 0, 1, 0.25, {}},
        {"acou_level", "Acoustic level", "acoustic", Kind::Num, -60, 12, 0, "dB"},
        {"acou_room", "Room mic", "acoustic", Kind::Num, 0, 1, 0.3, {}},
    };
    return specs;
}

// One piece's parameters ("pc<n>_<suffix>").
const Spec* pieceSpecs() {
    static const Spec specs[kPieceParams] = {
        CHOICE("kind", "Kind", "piece", kPieceOff, kPieceKinds),
        {"size", "Size", "piece", Kind::Num, 6, 26, 14, "in"},
        {"depth", "Depth", "piece", Kind::Num, 3, 22, 6.5, "in"},
        {"tune", "Tuning", "piece", Kind::Num, -24, 24, 0, "st"},
        {"reso", "Resonant head", "piece", Kind::Num, -12, 12, 0, "st"},
        CHOICE("head", "Heads", "piece", kHeadCoated, kHeads),
        CHOICE("shell", "Shell", "piece", kShellMaple, kShells),
        {"damp", "Damping", "piece", Kind::Num, 0, 1, 0.2, {}},
        {"decay", "Decay", "piece", Kind::Exp, 0.25, 4, 1, {}},
        {"glide", "Pitch glide", "piece", Kind::Num, 0, 1, 0.5, {}},
        {"wires", "Snare wires", "piece", Kind::Num, 0, 1, 0.6, {}},
        {"wire_level", "Wire level", "piece", Kind::Num, -24, 12, 0, "dB"},
        CHOICE("beater", "Beater", "piece", kBeaterFelt, kBeaters),
        CHOICE("port", "Port", "piece", 0, kOffOn),
        {"air", "Air loading", "piece", Kind::Num, 0, 1, 1, {}},
        CHOICE("alloy", "Alloy", "piece", kAlloyB20, kAlloys),
        {"swell", "Swell", "piece", Kind::Num, 0, 1, 0.5, {}},
        {"level", "Level", "piece", Kind::Num, -60, 12, 0, "dB"},
        {"pan", "Position", "piece", Kind::Num, -1, 1, 0, {}},
        {"dist", "Distance to overheads", "piece", Kind::Num, 0.3, 2, 1, "m"},
        {"shell_level", "Shell ring", "piece", Kind::Num, 0, 1, 0.5, {}},
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
        {"room_predelay", "Room pre-delay", "room", Kind::Num, 0, 100, 0, "ms"},
        {"kit_low", "Kit low shelf", "eq", Kind::Num, -12, 12, 0, "dB"},
        {"kit_high", "Kit high shelf", "eq", Kind::Num, -12, 12, 0, "dB"},
        CHOICE("kit_clip", "Kit clipper", "clip", kClipOff, kClips),
        {"kit_clip_gain", "Kit clipper drive", "clip", Kind::Num, 0, 24, 0, "dB"},
        {"echo", "Echo", "echo", Kind::Num, 0, 1, 0, {}},
        {"echo_time", "Echo time", "echo", Kind::Exp, 0.01, 2, 0.375, "s"},
        CHOICE("echo_sync", "Echo sync", "echo", kEcho8Dotted, kEchoSyncs),
        {"echo_feedback", "Echo feedback", "echo", Kind::Num, 0, 0.95, 0.35, {}},
        {"echo_tone", "Echo tone", "echo", Kind::Exp, 500, 16000, 5000, "Hz"},
        {"echo_spread", "Echo spread", "echo", Kind::Num, 0, 1, 0.6, {}},
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
        const Spec* a = acouSpecs();
        for (uint32_t k = 0; k < kAcouCount; ++k) {
            fill(d[acouParam(k)], a[k], a[k].suffix, a[k].name, keep("kit/" + std::string(a[k].layer)), a[k].def);
            d[acouParam(k)].choices = a[k].choices;
        }
        d[acouParam(kKitKind)].automatable = false;  // which builder made the kit: metadata, not sound
        d[acouParam(kKitKind)].modulatable = false;
        d[acouParam(kKitKind)].midiMappable = false;
        const Spec* pc = pieceSpecs();
        for (uint32_t piece = 0; piece < kPieces; ++piece) {
            const std::string id = "pc" + std::to_string(piece + 1), name = "Piece " + std::to_string(piece + 1);
            for (uint32_t k = 0; k < kPieceParams; ++k) {
                ParameterDescriptor& p = d[pieceParam(piece, k)];
                fill(p, pc[k], keep(id + "_" + std::string(pc[k].suffix)), keep(name + " " + std::string(pc[k].name)),
                     keep("kit/" + id), pc[k].def);
                p.choices = pc[k].choices;
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

std::string_view acouParamSuffix(uint32_t p) { return p < kAcouCount ? acouSpecs()[p].suffix : std::string_view{}; }
std::string_view pieceParamSuffix(uint32_t p) { return p < kPieceParams ? pieceSpecs()[p].suffix : std::string_view{}; }

bool articulationApplies(int kind, int a) noexcept {
    switch (kind) {
        case kPieceKick: return a == kArtHit || a == kArtOffCenter || a == kArtFlam || a == kArtChoke || a == kArtClosed;
        case kPieceSnare:
        case kPieceTom:
            return a == kArtHit || a == kArtOffCenter || a == kArtEdge || a == kArtRimshot || a == kArtCrossStick ||
                   a == kArtRimClick || a == kArtFlam || a == kArtRoll || a == kArtBuzz || a == kArtChoke || a == kArtClosed;
        case kPieceHiHat:
            return a == kArtHit || a == kArtEdge || a == kArtBell || a == kArtFlam || a == kArtClosed || a == kArtOpen ||
                   a == kArtFoot;
        case kPieceCrash:
        case kPieceRide:
        case kPieceSplash:
        case kPieceChina:
            return a == kArtHit || a == kArtEdge || a == kArtBell || a == kArtFlam || a == kArtRoll || a == kArtChoke;
        default: return false;
    }
}

int articulationFor(int kind, int a) noexcept {
    if (a < 0 || a >= kArtCount) a = kArtHit;
    if (articulationApplies(kind, a)) return a;
    // The nearest one the piece takes: a rim stroke on a cymbal is its edge, a bell on a drum its centre...
    static constexpr int kNear[kArtCount] = {kArtHit,  kArtHit,  kArtOffCenter, kArtHit,  kArtEdge, kArtEdge, kArtEdge,
                                             kArtHit,  kArtFlam, kArtRoll,      kArtClosed, kArtHit, kArtHit, kArtClosed};
    const int b = kNear[a];
    if (articulationApplies(kind, b)) return b;
    return kArtHit;
}

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

const std::vector<NeedRule>& needs() {
    static const std::vector<NeedRule> rules = [] {
        std::vector<NeedRule> r;
        auto add = [&](uint32_t p, std::vector<Need> all, bool global = false) { r.push_back({p, global, std::move(all)}); };
        const Need nz = {0, false, {}};
        auto on = [](uint32_t p) { return Need{p, false, {1}}; };
        auto in = [](uint32_t p, std::vector<int> v) { return Need{p, false, std::move(v)}; };
        auto nonzero = [&](uint32_t p) { Need n = nz; n.param = p; return n; };
        // A layer's settings need it on (its power is a "<layer>_on" choice).
        const Spec* s = padSpecs();
        for (uint32_t k = 0; k < kPadParams; ++k) {
            const std::string_view layer = s[k].layer;
            uint32_t power = kPadParams;
            for (uint32_t j = 0; j < kPadParams; ++j)
                if (s[j].layer == layer && s[j].suffix.size() == layer.size() + 3 && s[j].suffix.substr(0, layer.size()) == layer &&
                    s[j].suffix.substr(layer.size()) == "_on")
                    power = j;
            if (layer == "penv") power = kBodyOn;
            if (power == kPadParams || power == k || k == kBodyFreq) continue;  // body_freq: the sub's pitch too
            std::vector<Need> all = {on(power)};
            if (layer == "penv" && k != kPenvMode) all.push_back(in(kPenvMode, {kPenvPoints}));
            if (k == kBodyPTime || k == kBodyPCurve) all.push_back(in(kPenvMode, {kPenvCurve}));
            if (k == kBodyP2Ratio) all.push_back(nonzero(kBodyP2Level));
            if (k == kSubFollow) all.push_back(on(kBodyOn));
            if (k == kNoiseBursts || k == kNoiseSpacing) all.push_back(in(kNoiseMode, {kNoiseClap}));
            if (k == kNoiseRes) all.push_back(in(kNoiseFilter, {kFilterLp, kFilterBp, kFilterHp}));
            if (k == kMetalFm) all.push_back(in(kMetalMode, {kMetalFmPairs}));
            if (k == kMetalColor) all.push_back(nonzero(kMetalBand));
            if (k == kPhysInput) all.push_back(in(kPhysExciter, {kPhysLayers}));
            if (k == kTexDensity) all.push_back(in(kTexMode, {kTexDust, kTexCrackle}));
            if (k == kTexSpread || k == kTexTilt) all.push_back(in(kTexMode, {kTexBands}));
            if (k == kSmpPTime) all.push_back(nonzero(kSmpPitch));
            add(k, all);
        }
        const std::vector<int> drives = {1, 2, 3, 4, 5, 6, 7, 8}, filters = {1, 2, 3, 4};
        for (uint32_t k : {kDrive, kDriveLo, kDriveHi, kDriveMix, kPressDrive}) add(k, {in(kDriveType, drives)});
        add(PadParam::kDrivePos, {in(kDriveType, drives), in(kFlt, filters)});
        for (uint32_t k : {kCutoff, kFltEnv}) add(k, {in(kFlt, filters)});
        add(kFltRes, {in(kFlt, {kVfLp12, kVfHp, kVfBp})});
        add(kFltDecay, {in(kFlt, filters), nonzero(kFltEnv)});
        add(kEqLowFreq, {nonzero(kEqLow)});
        add(kEqFreq, {nonzero(kEqMid)});
        add(kEqQ, {nonzero(kEqMid)});
        add(kEqHighFreq, {nonzero(kEqHigh)});
        add(kCompAttack, {nonzero(kComp)});
        add(kCompRelease, {nonzero(kComp)});
        add(kClipGain, {in(kClip, {kClipSoft, kClipHard})});
        add(kWidthHz, {nonzero(kWidth)});
        add(kRoomSend, {Need{kRoom, true, {}}});
        add(kEchoSend, {Need{kEcho, true, {}}});
        add(kRingFreq, {nonzero(kRingMix)});
        add(kGlide, {on(kMono), on(kTrack)});
        add(kRoot, {on(kTrack)});
        add(kRelease, {in(kTrig, {kGate})});
        add(kVelPunch, {on(kBodyOn)});
        add(kVelClick, {on(kClickOn)});
        add(kRndPos, {on(kResOn)});
        add(kSwingGrid, {nonzero(kSwing)});
        add(kAccentOn, {nonzero(kAccent)});
        add(kFlamTime, {nonzero(kFlam)});
        add(kGrooveAmt, {in(kGroove, {1, 2, 3, 4, 5})});
        // 1.1.2: an Acoustic pad's piece and articulation need the engine; the acoustic layer is a Layers pad's.
        add(kAcouPiece, {in(kEngine, {kEngineAcoustic})});
        add(kAcouArtic, {in(kEngine, {kEngineAcoustic})});
        add(kAcouLayer, {in(kEngine, {kEngineLayers})});
        // Kit-wide.
        auto g = [](uint32_t p, std::vector<int> v = {}) { return Need{p, true, std::move(v)}; };
        // The Acoustic pieces: each setting is heard on the kinds it belongs to.
        const std::vector<int> drums = {kPieceKick, kPieceSnare, kPieceTom},
                               cymbals = {kPieceHiHat, kPieceCrash, kPieceRide, kPieceSplash, kPieceChina},
                               played = {1, 2, 3, 4, 5, 6, 7, 8};
        for (uint32_t piece = 0; piece < kPieces; ++piece) {
            auto pk = [&](std::vector<int> kinds) { return Need{pieceParam(piece, kPcKind), true, std::move(kinds)}; };
            for (uint32_t k = 1; k < kPieceParams; ++k) {
                std::vector<int> kinds = played;
                if (k == kPcDepth || k == kPcReso || k == kPcHead || k == kPcShell || k == kPcGlide || k == kPcAir ||
                    k == kPcShellLevel)
                    kinds = drums;
                if (k == kPcWires || k == kPcWireLevel) kinds = {kPieceSnare};
                if (k == kPcBeater || k == kPcPort) kinds = {kPieceKick};
                if (k == kPcAlloy || k == kPcSwell) kinds = cymbals;
                std::vector<Need> all = {pk(kinds)};
                if (k == kPcWireLevel) all.push_back(Need{pieceParam(piece, kPcWires), true, {}});
                add(pieceParam(piece, k), all, true);
            }
        }

        for (uint32_t k : {kGlueThreshold, kGlueRatio, kGlueAttack, kGlueRelease, kGlueMakeup}) add(k, {g(kGlue)}, true);
        for (uint32_t k : {kKitDrive, kKitDriveMix}) add(k, {g(kKitDriveType, {1, 2, 3, 4})}, true);
        for (uint32_t k : {kRoomSize, kRoomDecay, kRoomDamping, kRoomPredelay}) add(k, {g(kRoom)}, true);
        add(kKitClipGain, {g(kKitClip, {1, 2})}, true);
        for (uint32_t k : {kEchoSync, kEchoFeedback, kEchoTone, kEchoSpread}) add(k, {g(kEcho)}, true);
        add(kEchoTime, {g(kEcho), g(kEchoSync, {kEchoFree})}, true);
        return r;
    }();
    return rules;
}

std::string_view typeName(int type) { return type >= 0 && type < kTypeCount ? kTypes[type] : std::string_view("Perc"); }

}  // namespace caw::drums
