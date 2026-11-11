// fx-dynamics: the factory presets of the Dynamics and Drive effects (dynamics, multiband, de-esser, clipper, phase distortion, saturator).
#include <string_view>
#include <vector>

#include "presets.h"

namespace caw {

namespace {

const std::vector<BuiltinPreset>& dynamicsPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Gentle glue", "A soft 2:1 over the loud parts, nothing below", {{"high_threshold", -18}, {"high_ratio", 2}, {"low_ratio", 1}, {"knee", 12}, {"attack", 10}, {"release", 150}}},
        {"Upward lift", "Brings quiet detail up toward the body, leaves peaks alone", {{"low_threshold", -36}, {"low_ratio", 3}, {"high_threshold", -6}, {"high_ratio", 1}, {"knee", 9}, {"attack", 5}, {"release", 200}, {"range", 18}}},
        {"Squash both ways", "Upward and downward at once: a dense, even level", {{"low_threshold", -34}, {"low_ratio", 4}, {"high_threshold", -20}, {"high_ratio", 6}, {"knee", 6}, {"attack", 2}, {"release", 90}, {"out_gain", 2}}},
        {"Noise expander", "Pushes the hiss and room down between notes", {{"low_threshold", -50}, {"low_ratio", 0.33}, {"high_threshold", -6}, {"high_ratio", 1}, {"knee", 6}, {"attack", 1}, {"release", 120}, {"range", 30}}},
        {"Punch expander", "Upward expansion over the threshold: hits jump out", {{"low_ratio", 1}, {"high_threshold", -20}, {"high_ratio", 0.6}, {"knee", 6}, {"attack", 0.5}, {"release", 60}, {"range", 9}, {"out_gain", -4}}},
        {"Parallel smash", "Hard both ways, half mixed in", {{"low_threshold", -40}, {"low_ratio", 6}, {"high_threshold", -24}, {"high_ratio", 10}, {"attack", 1}, {"release", 60}, {"mix", 0.5}, {"out_gain", 3}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& multibandPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"OTT", "The famous three-band squash at full depth", {{"mode", 1}, {"depth", 1}, {"time", 1}, {"upward", 1}, {"downward", 1}}},
        {"OTT gentle", "OTT at a third: sheen without the pumping", {{"mode", 1}, {"depth", 0.33}, {"time", 1}}},
        {"Upward only", "OTT's lift of quiet detail, no squeeze from above", {{"mode", 1}, {"depth", 0.6}, {"downward", 0}, {"upward", 1}}},
        {"Fast and crispy", "OTT with quick times: grit on synths and drums", {{"mode", 1}, {"depth", 0.7}, {"time", 0.25}, {"out_gain", -2}}},
        {"Mix bus", "Light per-band control for a whole mix", {{"mode", 0}, {"depth", 1}, {"upward", 0}, {"b1_down_thr", -20}, {"b1_down_ratio", 2}, {"b2_down_thr", -18}, {"b2_down_ratio", 1.8}, {"b3_down_thr", -22}, {"b3_down_ratio", 2}, {"xover_low", 150}, {"xover_high", 4000}}},
        {"Tame lows", "Holds a boomy low end down, the rest untouched", {{"mode", 0}, {"depth", 1}, {"upward", 0}, {"b1_down_thr", -30}, {"b1_down_ratio", 6}, {"b2_down_ratio", 1}, {"b3_down_ratio", 1}, {"xover_low", 180}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& deesserPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Vocal", "Softens esses around 6.5 kHz on a lead voice", {{"freq", 6500}, {"threshold", -30}, {"range", 10}}},
        {"Bright voice", "Higher and stronger, for an airy, breathy take", {{"freq", 8500}, {"threshold", -34}, {"range", 14}, {"release", 40}}},
        {"Low esses", "Lower male esses and harsh 'sh' sounds", {{"freq", 4200}, {"threshold", -30}, {"range", 9}}},
        {"Hats tamer", "Takes the sizzle off bright cymbals, whole signal", {{"freq", 9000}, {"threshold", -24}, {"range", 6}, {"mode", 1}, {"release", 120}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& clipperPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Master clip", "Clips to 0 dBFS, 4x oversampled, for loudness", {{"master", 1}, {"mode", 1}, {"softness", 0.2}, {"drive", 3}, {"oversample", 3}}},
        {"Drum smash", "Hard clips the peaks of a drum bus for punch", {{"mode", 0}, {"drive", 8}, {"ceiling", -3}, {"output", 2}}},
        {"Soft round", "A gentle soft clip that just rounds the tops", {{"mode", 1}, {"softness", 0.8}, {"drive", 4}, {"ceiling", -1}}},
        {"Analog warmth", "The asymmetric curve, pushed: a warm, thick edge", {{"mode", 2}, {"drive", 9}, {"ceiling", -2}, {"output", -1}}},
        {"808 grit", "Clipped sub bass that cuts through on small speakers", {{"mode", 0}, {"drive", 15}, {"ceiling", -6}, {"output", 3}, {"oversample", 3}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& phaseDistPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Subtle grit", "A little self-modulation: edge without fuzz", {{"drive", 0.25}, {"tone", 3000}}},
        {"Metallic", "Strong, bright self-FM: a clangy, bell-like bite", {{"drive", 0.8}, {"tone", 12000}, {"normalize", 1}}},
        {"Warm bend", "Low tone and bias: the waveform leans, not buzzes", {{"drive", 0.6}, {"tone", 600}, {"bias", 0.3}}},
        {"Wide phase", "Spread pulls the sides apart for a wide grind", {{"drive", 0.55}, {"spread", 0.5}, {"tone", 5000}}},
        {"Dynamic", "No normalize: louder notes distort more", {{"drive", 0.7}, {"normalize", 0}, {"tone", 6000}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& saturatorPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Warm tape", "Tape with a soft top, gently driven", {{"mode", 0}, {"drive", 8}, {"tone", -0.2}}},
        {"Tube glow", "Tube's even harmonics with a touch of bias", {{"mode", 1}, {"drive", 10}, {"bias", 0.2}}},
        {"Fuzz box", "A buzzing, squared-off fuzz", {{"mode", 6}, {"drive", 26}, {"tone", 0.2}, {"mix", 1}}},
        {"Octave up", "Full-wave rectify: the octave above, gritty", {{"mode", 7}, {"drive", 6}, {"mix", 0.6}}},
        {"Wavefolder", "The triangle folder, pushed into rich overtones", {{"mode", 8}, {"drive", 15}, {"bias", 0.15}}},
        {"Bit shaper", "Stepped amplitude without the sample-rate drop", {{"mode", 9}, {"bits", 4}, {"drive", 4}}},
        {"Faturate", "Fat, heavy saturation that keeps the dynamics", {{"mode", 10}, {"drive", 14}, {"dynamics", 0.7}, {"spread", 0.3}}},
    };
    return p;
}

}  // namespace

// The presets of fx-dynamics' effects (presets.cpp asks here first), or null for any other id.
const std::vector<BuiltinPreset>* fxDynamicsPresets(std::string_view id) {
    if (id == "org.caw.dynamics") return &dynamicsPresets();
    if (id == "org.caw.multiband") return &multibandPresets();
    if (id == "org.caw.deesser") return &deesserPresets();
    if (id == "org.caw.clipper") return &clipperPresets();
    if (id == "org.caw.phasedist") return &phaseDistPresets();
    if (id == "org.caw.saturator") return &saturatorPresets();
    return nullptr;
}

}  // namespace caw
