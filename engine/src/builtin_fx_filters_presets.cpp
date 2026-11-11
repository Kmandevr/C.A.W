// The factory presets of the EQ & Filter group's effects (ladder, nonlinear filter, comb, resonator, formant, disperser, 3-band, tilt and graphic EQ).
#include "builtin_fx_filters.h"

namespace caw::fx {

namespace {

const std::vector<BuiltinPreset>& ladder() {
    static const std::vector<BuiltinPreset> p = {
        {"Acid squelch", "A resonant 24 dB low-pass just short of whistling, driven", {{"mode", 0}, {"slope", 1}, {"cutoff", 650}, {"resonance", 0.82}, {"drive", 9}, {"comp", 0.6}}},
        {"Warm low-pass", "A gentle 24 dB roll-off that rounds off the top", {{"mode", 0}, {"slope", 1}, {"cutoff", 2500}, {"resonance", 0.15}, {"drive", 3}, {"comp", 0.5}}},
        {"Self-oscillation", "Resonance past the edge: the filter sings a sine at its cutoff", {{"mode", 0}, {"slope", 1}, {"cutoff", 440}, {"resonance", 0.97}, {"drive", 0}, {"comp", 0.2}}},
        {"Fat drive", "Pushed hard into the transistors: a warm, filtered distortion", {{"mode", 0}, {"slope", 1}, {"cutoff", 4000}, {"resonance", 0.3}, {"drive", 27}, {"bias", 0.3}, {"comp", 0.8}, {"output", -3}}},
        {"Thin band", "A 12 dB band-pass with some ring: telephone-ish and vocal", {{"mode", 1}, {"slope", 0}, {"cutoff", 1200}, {"resonance", 0.6}, {"drive", 4}}},
        {"Airy high-pass", "A 12 dB high-pass with a small peak: clears the lows, keeps the sparkle", {{"mode", 2}, {"slope", 0}, {"cutoff", 180}, {"resonance", 0.35}, {"drive", 0}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& nonlinear() {
    static const std::vector<BuiltinPreset> p = {
        {"Analog warmth", "A low-pass whose resonance saturates like an OTA", {{"type", 0}, {"cutoff", 1800}, {"q", 3}, {"drive", 12}, {"shape", 1}, {"output", -5}}},
        {"Screaming band", "A tight band-pass driven until its peak screams", {{"type", 1}, {"cutoff", 440}, {"q", 10}, {"drive", 24}, {"shape", 1}, {"output", 15}}},
        {"Diode growl", "Lopsided diode saturation in a resonant low-pass", {{"type", 0}, {"cutoff", 600}, {"q", 6}, {"drive", 20}, {"shape", 2}, {"output", -6}}},
        {"Folded metal", "The fold shape in the loop: clangy, metallic overtones", {{"type", 0}, {"cutoff", 1500}, {"q", 8}, {"drive", 26}, {"shape", 4}, {"output", -12}}},
        {"Hard notch", "A notch whose hard-clipped loop chews the signal around it", {{"type", 3}, {"cutoff", 1000}, {"q", 2}, {"drive", 18}, {"shape", 3}, {"output", -8}}},
        {"Clean all-pass", "No distortion: an all-pass that shifts the phase around 1 kHz", {{"type", 4}, {"cutoff", 1000}, {"q", 1}, {"drive", 0}, {"shape", 0}, {"mix", 0.5}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& comb() {
    static const std::vector<BuiltinPreset> p = {
        {"Metallic", "Strong positive feedback at a fixed pitch: a ringing tube", {{"tune", 0}, {"freq", 330}, {"feedback", 0.9}, {"damping", 0.1}}},
        {"Hollow", "Negative feedback: odd harmonics only, a clarinet-like hollow", {{"tune", 0}, {"freq", 200}, {"feedback", -0.85}, {"damping", 0.3}}},
        {"Flange static", "No feedback: the frozen notches of a flanger", {{"tune", 0}, {"freq", 1200}, {"feedback", 0}, {"mix", 1}}},
        {"Tuned A", "Tuned to the note A2 with a long, soft ring", {{"tune", 1}, {"note", 45}, {"feedback", 0.95}, {"damping", 0.45}}},
        {"Wide comb", "Right polarity flipped and spread: wide yet mono-safe", {{"tune", 0}, {"freq", 500}, {"feedback", 0.5}, {"stereo", 1}, {"spread", 0.4}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& resonator() {
    static const std::vector<BuiltinPreset> p = {
        {"Plucked string", "A string at C3: every harmonic, a medium ring", {{"mode", 0}, {"note", 48}, {"decay", 1.5}, {"brightness", 0.5}, {"spread", 0.3}, {"mix", 0.5}}},
        {"Hollow square", "Odd harmonics only, like a square wave or a clarinet", {{"mode", 1}, {"note", 45}, {"decay", 2}, {"brightness", 0.4}, {"mix", 0.5}}},
        {"Glass bell", "The inharmonic modes of a struck bar: chimes and bells", {{"mode", 2}, {"note", 72}, {"decay", 4}, {"brightness", 0.7}, {"spread", 0.6}, {"mix", 0.5}}},
        {"Minor chord", "A minor chord rings out of anything you feed it", {{"mode", 3}, {"chord", 1}, {"note", 57}, {"decay", 3}, {"brightness", 0.5}, {"spread", 0.5}, {"mix", 0.45}}},
        {"Pentatonic wash", "A pentatonic scale's notes sustain from noise and drums", {{"mode", 4}, {"scale", 2}, {"note", 48}, {"decay", 6}, {"brightness", 0.6}, {"spread", 0.8}, {"mix", 0.4}}},
        {"Short body", "A quick, bright string resonance: body for drums and plucks", {{"mode", 0}, {"note", 40}, {"decay", 0.25}, {"brightness", 0.8}, {"mix", 0.35}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& formant() {
    static const std::vector<BuiltinPreset> p = {
        {"Ahh", "The open vowel A", {{"vowel_x", 0.6}, {"vowel_y", 1.0}, {"q", 8}}},
        {"Ooh", "The rounded vowel U", {{"vowel_x", 1.0}, {"vowel_y", 0.0}, {"q", 8}}},
        {"Eee", "The bright vowel I", {{"vowel_x", 0.0}, {"vowel_y", 0.0}, {"q", 10}}},
        {"Deep voice", "O with the formants a fifth down: a big, low throat", {{"vowel_x", 0.85}, {"vowel_y", 0.5}, {"shift", -7}, {"q", 7}, {"lows", 0.3}}},
        {"Small voice", "E with the formants up: a smaller, higher voice", {{"vowel_x", 0.15}, {"vowel_y", 0.5}, {"shift", 6}, {"q", 9}}},
        {"Talk box", "Between the vowels, narrow and with some of the dry highs", {{"vowel_x", 0.5}, {"vowel_y", 0.55}, {"q", 14}, {"highs", 0.2}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& disperser() {
    static const std::vector<BuiltinPreset> p = {
        {"Laser zap", "Many pinched stages up high: transients become a laser chirp", {{"amount", 0.9}, {"freq", 3000}, {"pinch", 0.7}}},
        {"Boomy kick", "The low end smeared into a longer, boomy drop", {{"amount", 0.6}, {"freq", 120}, {"pinch", 0.5}}},
        {"Soft snap", "A few stages around the mids: a gentler, rounder attack", {{"amount", 0.2}, {"freq", 1500}, {"pinch", 0.2}}},
        {"Wet bass", "A wobbly, liquid bass from a chain around 300 Hz", {{"amount", 0.75}, {"freq", 300}, {"pinch", 0.4}, {"spread", 0.15}}},
        {"Phasey", "Half dry: the chain's phase against the dry makes moving notches", {{"amount", 0.35}, {"freq", 800}, {"pinch", 0.3}, {"mix", 0.5}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& eq3() {
    static const std::vector<BuiltinPreset> p = {
        {"Bass kill", "The lows gone: the mixing DJ's swap", {{"kill_low", 1}}},
        {"Mid scoop", "The mids pulled down for a smiley, club sound", {{"mid", -8}, {"low", 2}, {"high", 2}}},
        {"Highs only", "Lows and mids killed: just the hats", {{"kill_low", 1}, {"kill_mid", 1}}},
        {"Warm boost", "A touch more low end and less top", {{"low", 4}, {"high", -3}}},
        {"Telephone", "Only the mids, with a narrow split", {{"kill_low", 1}, {"kill_high", 1}, {"low_x", 400}, {"high_x", 2800}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& tilt() {
    static const std::vector<BuiltinPreset> p = {
        {"Brighter", "Tilted up toward the highs", {{"tilt", 4}, {"freq", 1000}}},
        {"Darker", "Tilted down toward the highs: warmer, softer", {{"tilt", -4}, {"freq", 1000}}},
        {"Air lift", "A broad lift above 3 kHz", {{"tilt", 3}, {"freq", 3000}, {"q", 0.4}}},
        {"Weight", "More lows, a little less top, pivoting low", {{"tilt", -3}, {"freq", 300}, {"q", 0.6}}},
        {"Wide sparkle", "The sides tilted bright: width up top only", {{"tilt", 5}, {"freq", 2000}, {"channel", 2}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& geq() {
    static const std::vector<BuiltinPreset> p = {
        {"Smile", "The classic V: lows and highs up, mids down", {{"g3", 5}, {"g5", 4}, {"g7", 3}, {"g9", 1}, {"g13", -2}, {"g15", -3}, {"g17", -3}, {"g19", -2}, {"g23", 1}, {"g25", 3}, {"g27", 4}, {"g29", 5}}},
        {"Vocal presence", "A lift at 2 to 5 kHz, less mud at 250 Hz", {{"g12", -3}, {"g13", -2}, {"g21", 2}, {"g22", 3}, {"g23", 3}, {"g24", 2}, {"g2", -6}}},
        {"Radio", "Only 300 Hz to 3 kHz: a small speaker", {{"g1", -12}, {"g2", -12}, {"g3", -12}, {"g4", -12}, {"g5", -12}, {"g6", -10}, {"g7", -8}, {"g8", -6}, {"g9", -3}, {"g24", -3}, {"g25", -6}, {"g26", -9}, {"g27", -12}, {"g28", -12}, {"g29", -12}, {"g30", -12}, {"g31", -12}}},
        {"Less mud", "The low mids carved out", {{"g10", -3}, {"g11", -5}, {"g12", -5}, {"g13", -3}}},
        {"Sub boost", "More of the lowest octave", {{"g2", 5}, {"g3", 6}, {"g4", 5}, {"g5", 3}}},
    };
    return p;
}

}  // namespace

const std::vector<BuiltinPreset>* filtersPresets(std::string_view id) {
    if (id == "org.caw.ladder") return &ladder();
    if (id == "org.caw.nlfilter") return &nonlinear();
    if (id == "org.caw.comb") return &comb();
    if (id == "org.caw.resonator") return &resonator();
    if (id == "org.caw.formant") return &formant();
    if (id == "org.caw.disperser") return &disperser();
    if (id == "org.caw.eq3") return &eq3();
    if (id == "org.caw.tilt") return &tilt();
    if (id == "org.caw.geq") return &geq();
    return nullptr;
}

}  // namespace caw::fx
