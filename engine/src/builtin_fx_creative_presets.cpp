// The factory presets of the Creative and Pitch & Time effects (fx-creative), which presets.cpp's builtinPresets lists.
#include <string_view>
#include <vector>

#include "presets.h"

namespace caw {

namespace {

// The trance gate's pattern as step values s1..sN.
std::vector<std::pair<std::string_view, double>> pattern(std::initializer_list<double> steps,
                                                         std::vector<std::pair<std::string_view, double>> rest) {
    static constexpr std::string_view names[] = {"s1",  "s2",  "s3",  "s4",  "s5",  "s6",  "s7",  "s8",  "s9",  "s10", "s11",
                                                 "s12", "s13", "s14", "s15", "s16", "s17", "s18", "s19", "s20", "s21", "s22",
                                                 "s23", "s24", "s25", "s26", "s27", "s28", "s29", "s30", "s31", "s32"};
    size_t k = 0;
    for (double v : steps) {
        if (k >= 32) break;
        rest.emplace_back(names[k++], v);
    }
    // A pattern shorter than 32 repeats, so a later switch to more steps keeps its feel.
    const size_t n = k;
    for (; n > 0 && k < 32; ++k) rest.emplace_back(names[k], rest[rest.size() - n].second);
    return rest;
}

}  // namespace

const std::vector<BuiltinPreset>* creativeBuiltinPresets(std::string_view id) {
    static const std::vector<BuiltinPreset> tape = {
        {"Quick stop", "A short brake: the pitch dives in a quarter second", {{"stop", 0}, {"stop_time", 250}, {"stop_sync", 0}, {"start_time", 60}, {"start_sync", 0}, {"curve", 0.3}}},
        {"Slow wind-down", "A turntable switched off: two seconds of sinking pitch", {{"stop", 0}, {"stop_time", 2000}, {"stop_sync", 0}, {"start_time", 400}, {"start_sync", 0}, {"curve", -0.3}}},
        {"Beat stop", "Stops over a quarter note, spins back up over an eighth", {{"stop", 0}, {"stop_sync", 9}, {"start_sync", 6}, {"curve", 0}}},
        {"Bar brake", "A whole bar of slow-down for a drop", {{"stop", 0}, {"stop_sync", 14}, {"start_sync", 6}, {"curve", 0.5}}},
        {"Vinyl spin-up", "A quick stop and a long, rising spin-up", {{"stop", 0}, {"stop_time", 400}, {"stop_sync", 0}, {"start_time", 900}, {"start_sync", 0}, {"curve", 0.4}}},
        {"Hard cut", "A fast stop and an instant restart", {{"stop", 0}, {"stop_time", 120}, {"stop_sync", 0}, {"start_time", 1}, {"start_sync", 0}, {"curve", 0.6}}},
    };
    static const std::vector<BuiltinPreset> reverser = {
        {"Quarter flip", "Each beat played backwards", {{"sync", 9}, {"crossfade", 10}, {"mix", 1}}},
        {"Eighth swirl", "Short backwards chunks, softly blended", {{"sync", 6}, {"crossfade", 30}, {"mix", 1}}},
        {"Long smear", "A whole bar reversed with long crossfades, under the dry", {{"sync", 14}, {"crossfade", 50}, {"mix", 0.6}}},
        {"Half reverse", "Half notes backwards, half and half with the dry", {{"sync", 12}, {"crossfade", 15}, {"mix", 0.5}}},
        {"Free 150 ms", "Fast free-running reversal for texture", {{"sync", 0}, {"time", 150}, {"crossfade", 20}, {"mix", 1}}},
    };
    static const std::vector<BuiltinPreset> gate = {
        {"Classic 16", "The off-beat trance chop", pattern({1, 0, 1, 1, 0, 1, 1, 0, 1, 0, 1, 1, 0, 1, 0.6, 1}, {{"steps", 1}, {"rate", 2}, {"attack", 1}, {"decay", 200}, {"sustain", 1}, {"release", 30}, {"length", 0.5}, {"swing", 0}, {"legato", 0}, {"mix", 1}})},
        {"Offbeat pump", "Eighth-note off-beats with a short decay", pattern({0, 0, 1, 1}, {{"steps", 1}, {"rate", 2}, {"attack", 5}, {"decay", 150}, {"sustain", 0.3}, {"release", 40}, {"length", 0.9}, {"swing", 0}, {"legato", 1}, {"mix", 1}})},
        {"Choppy 32", "Thirty-second notes, every other one on", pattern({1, 0}, {{"steps", 2}, {"rate", 0}, {"attack", 0.5}, {"decay", 60}, {"sustain", 0.8}, {"release", 8}, {"length", 0.4}, {"swing", 0}, {"legato", 0}, {"mix", 1}})},
        {"Swing gate", "Every sixteenth, swung", pattern({1, 0.7}, {{"steps", 1}, {"rate", 2}, {"attack", 1}, {"decay", 120}, {"sustain", 0.5}, {"release", 25}, {"length", 0.5}, {"swing", 0.6}, {"legato", 0}, {"mix", 1}})},
        {"Soft pulses", "Rounded eighth pulses, the dry under them", pattern({1, 0.5, 0.8, 0.5}, {{"steps", 0}, {"rate", 4}, {"attack", 20}, {"decay", 300}, {"sustain", 0.6}, {"release", 150}, {"length", 0.7}, {"swing", 0}, {"legato", 0}, {"mix", 0.8}})},
        {"Tied chords", "Long tied groups for pads", pattern({1, 1, 1, 0, 1, 1, 0, 0, 1, 1, 1, 1, 0, 1, 1, 0}, {{"steps", 1}, {"rate", 2}, {"attack", 3}, {"decay", 400}, {"sustain", 0.9}, {"release", 60}, {"length", 0.8}, {"swing", 0}, {"legato", 1}, {"mix", 1}})},
    };
    static const std::vector<BuiltinPreset> stutter = {
        {"Fill on the 4", "Sometimes repeats the last beat of a bar in sixteenths", {{"interval", 2}, {"offset", 12}, {"division", 3}, {"length", 2}, {"chance", 0.6}, {"decay", 0.1}, {"pitch", 0}, {"gate", 1}, {"mix", 1}}},
        {"Rising roll", "Thirty-second repeats climbing a semitone each", {{"interval", 3}, {"offset", 12}, {"division", 1}, {"length", 3}, {"chance", 0.7}, {"decay", 0}, {"pitch", 1}, {"gate", 0.9}, {"mix", 1}}},
        {"Falling eighths", "Eighth repeats sinking and fading", {{"interval", 2}, {"offset", 8}, {"division", 5}, {"length", 3}, {"chance", 0.5}, {"decay", 0.25}, {"pitch", -1}, {"gate", 1}, {"mix", 1}}},
        {"Glitch spray", "Tiny 1/64 bursts scattered across the beat", {{"interval", 0}, {"offset", 2}, {"division", 0}, {"length", 1}, {"chance", 0.3}, {"decay", 0.05}, {"pitch", 0}, {"gate", 0.6}, {"mix", 1}}},
        {"Gated quarters", "Every two bars, quarter-note repeats cut in half", {{"interval", 3}, {"offset", 0}, {"division", 6}, {"length", 4}, {"chance", 1}, {"decay", 0}, {"pitch", 0}, {"gate", 0.5}, {"mix", 1}}},
    };
    static const std::vector<BuiltinPreset> crush = {
        {"8-bit console", "Eight bits at 16 kHz, the stair-steps left in", {{"bits", 8}, {"rate", 16000}, {"jitter", 0}, {"dither", 0}, {"adc", 0}, {"dac", 0}, {"mix", 1}}},
        {"12-bit sampler", "A gritty vintage sampler, filtered on the way in and out", {{"bits", 12}, {"rate", 26000}, {"jitter", 0}, {"dither", 0}, {"adc", 0.8}, {"dac", 0.6}, {"mix", 1}}},
        {"Telephone", "Narrow and rough: 8 kHz with both filters", {{"bits", 8}, {"rate", 8000}, {"jitter", 0}, {"dither", 0.3}, {"adc", 1}, {"dac", 1}, {"mix", 1}}},
        {"Destroyed", "Three bits at 2 kHz, the clock wobbling", {{"bits", 3}, {"rate", 2000}, {"jitter", 0.4}, {"dither", 0}, {"adc", 0}, {"dac", 0}, {"output", -4}, {"mix", 1}}},
        {"Dusty jitter", "A light, noisy crunch blended with the dry", {{"bits", 10}, {"rate", 11000}, {"jitter", 0.3}, {"dither", 0.5}, {"adc", 0.3}, {"dac", 0.3}, {"mix", 0.7}}},
    };
    static const std::vector<BuiltinPreset> pitch = {
        {"Octave up", "Twelve semitones up", {{"semitones", 12}, {"cents", 0}, {"grain", 50}, {"jitter", 0}, {"mix", 1}}},
        {"Octave down", "Twelve semitones down, long grains", {{"semitones", -12}, {"cents", 0}, {"grain", 90}, {"jitter", 0}, {"mix", 1}}},
        {"Fifth harmony", "A fifth up, under the dry", {{"semitones", 7}, {"cents", 0}, {"grain", 60}, {"jitter", 0}, {"mix", 0.5}}},
        {"Doubler", "A few cents up with jitter: a second take", {{"semitones", 0}, {"cents", 12}, {"grain", 40}, {"jitter", 0.3}, {"mix", 0.5}}},
        {"Sub octave", "An octave down mixed in for weight", {{"semitones", -12}, {"cents", 0}, {"grain", 120}, {"jitter", 0}, {"mix", 0.4}}},
        {"Warble", "Random pitch wobble from big jitter", {{"semitones", 0}, {"cents", 0}, {"grain", 80}, {"jitter", 1}, {"mix", 1}}},
    };
    static const std::vector<BuiltinPreset> shift = {
        {"Subtle widen", "A few hertz up on the left and down on the right", {{"shift", 3}, {"direction", 2}, {"spread", 0}, {"feedback", 0}, {"mix", 0.5}}},
        {"Barber-pole", "A slow shift fed back: an endless rising swirl", {{"shift", 5}, {"direction", 0}, {"spread", 0}, {"feedback", 0.8}, {"delay", 25}, {"mix", 0.5}}},
        {"Metallic up", "Every partial 300 Hz up: clangy and inharmonic", {{"shift", 300}, {"direction", 0}, {"spread", 0}, {"feedback", 0}, {"mix", 1}}},
        {"Down detune", "Forty hertz down: dark and sour", {{"shift", 40}, {"direction", 1}, {"spread", 0}, {"feedback", 0}, {"mix", 0.7}}},
        {"Alien voice", "Six hundred down with a little feedback", {{"shift", 600}, {"direction", 1}, {"spread", 20}, {"feedback", 0.3}, {"delay", 8}, {"mix", 1}}},
    };
    static const std::vector<BuiltinPreset> ring = {
        {"Classic ring", "A 440 Hz sine: sum and difference tones", {{"source", 0}, {"freq", 440}, {"spread", 0}, {"bias", 0}, {"rectify", 0}, {"mix", 1}}},
        {"Tremolo", "A 6 Hz sine half-way to AM: a pulse, not a ring", {{"source", 0}, {"freq", 6}, {"spread", 0}, {"bias", 0.5}, {"rectify", 0}, {"mix", 1}}},
        {"Robot voice", "A low sine ring for a talking machine", {{"source", 0}, {"freq", 30}, {"spread", 0}, {"bias", 0}, {"rectify", 0}, {"mix", 1}}},
        {"Bell metal", "A high sine spread across the sides", {{"source", 0}, {"freq", 1250}, {"spread", 0.2}, {"bias", 0}, {"rectify", 0}, {"mix", 0.8}}},
        {"Noise grit", "Filtered noise as the carrier: hiss and dirt", {{"source", 4}, {"freq", 3000}, {"spread", 0}, {"bias", 0.6}, {"rectify", 0}, {"mix", 1}}},
        {"Rectified buzz", "A folded triangle at 110 Hz", {{"source", 1}, {"freq", 110}, {"spread", 0}, {"bias", 0}, {"rectify", 1}, {"mix", 1}}},
        {"Key cross", "The input times the sidechain key's sound", {{"source", 5}, {"bias", 0}, {"rectify", 0}, {"mix", 1}}},
    };
    if (id == "org.caw.tapestop") return &tape;
    if (id == "org.caw.reverser") return &reverser;
    if (id == "org.caw.trancegate") return &gate;
    if (id == "org.caw.stutter") return &stutter;
    if (id == "org.caw.bitcrush") return &crush;
    if (id == "org.caw.pitchshift") return &pitch;
    if (id == "org.caw.freqshift") return &shift;
    if (id == "org.caw.ringmod") return &ring;
    return nullptr;
}

}  // namespace caw
