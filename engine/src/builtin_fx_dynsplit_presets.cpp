// The presets of 1.1.0's new dynamics variants (Talon's Up and Bus, Hatch's Expand and Pedal gate, Duck's Level and Carve) and Duck's own, listed by fx::newVariantPresets.
#include <span>
#include <vector>

#include "fx_merged.h"
#include "presets.h"

// Job-named, the purpose first in the description (Guitar, Vocals, Drums, Bass, Mixing, Mastering, Sound design,
// Lo-fi). Each names its `variant`; Talon's get talon_layout from fx::mergedPresets. A keyed one says so: the app
// turns Sidechain to External (or gives Carve its key).

namespace caw::fx {

const std::vector<BuiltinPreset>& duckVariantPresets();  // builtin_fx_duck.cpp

namespace {

const std::vector<BuiltinPreset>& talonPresets() {
    static const std::vector<BuiltinPreset> p = {
        // Up (2)
        {"Bring up the tail", "Drums: lifts a room's and a cymbal's decay without touching the hits",
         {{"variant", 2}, {"threshold", -28}, {"ratio", 3}, {"range", 12}, {"floor", -60}, {"attack", 2}, {"release", 80}}},
        {"Vocal detail", "Vocals: raises breaths and quiet words toward the loud ones",
         {{"variant", 2}, {"threshold", -30}, {"ratio", 2}, {"range", 9}, {"floor", -55}, {"attack", 5}, {"release", 200}, {"detect", 1}}},
        {"Guitar sustain", "Guitar: holds a clean note up as it dies away",
         {{"variant", 2}, {"threshold", -24}, {"ratio", 4}, {"range", 15}, {"floor", -50}, {"attack", 10}, {"release", 300}, {"detect", 1}}},
        {"Bass even", "Bass: lifts the soft notes so the line sits level",
         {{"variant", 2}, {"threshold", -20}, {"ratio", 2.5}, {"range", 8}, {"floor", -50}, {"attack", 10}, {"release", 150}, {"detect", 1}, {"sc_hpf", 60}}},
        {"Gentle lift", "Mixing: a little upward squeeze for a part that gets lost",
         {{"variant", 2}, {"threshold", -35}, {"ratio", 1.5}, {"range", 6}, {"floor", -65}, {"attack", 20}, {"release", 400}, {"detect", 1}}},
        {"Master density", "Mastering: quiet passages up a few dB with look-ahead, the peaks untouched",
         {{"variant", 2}, {"threshold", -26}, {"ratio", 1.6}, {"range", 4}, {"floor", -70}, {"attack", 30}, {"release", 600}, {"lookahead", 5}, {"detect", 1}}},
        {"Room bloom", "Sound design: drags reverb and noise floors up into the foreground",
         {{"variant", 2}, {"threshold", -18}, {"ratio", 8}, {"range", 24}, {"floor", -80}, {"attack", 1}, {"release", 50}}},
        {"Parallel lift", "Mixing: half the lifted signal under the dry, natural movement kept",
         {{"variant", 2}, {"threshold", -30}, {"ratio", 4}, {"range", 18}, {"floor", -60}, {"attack", 5}, {"release", 150}, {"mix", 0.5}}},
        {"Warm detail", "Lo-fi: lifts every scrape and breath, warmed",
         {{"variant", 2}, {"threshold", -22}, {"ratio", 6}, {"range", 20}, {"floor", -70}, {"attack", 3}, {"release", 120}, {"character", 1}}},
        // Bus (3)
        {"Mix glue", "Mixing: 2:1, slow attack, auto release, a dB or two on the mix bus",
         {{"variant", 3}, {"threshold", -14}, {"ratio", 1}, {"attack", 30}, {"release", 4}}},
        {"Drum bus smash", "Drums: 4:1, fast attack, the room comes forward",
         {{"variant", 3}, {"threshold", -24}, {"ratio", 2}, {"attack", 1}, {"release", 0}, {"mix", 0.6}}},
        {"Drum bus punch", "Drums: 4:1 with a 10 ms attack: the hits pass, the body is held",
         {{"variant", 3}, {"threshold", -18}, {"ratio", 2}, {"attack", 10}, {"release", 1}}},
        {"Master glue", "Mastering: 1.5:1, gentle, auto release, the lows left out of the key",
         {{"variant", 3}, {"threshold", -10}, {"ratio", 0}, {"attack", 30}, {"release", 4}, {"sc_hpf", 90}}},
        {"Vocal bus", "Vocals: 2:1 over the vocal group, the release at 0.3 s",
         {{"variant", 3}, {"threshold", -16}, {"ratio", 1}, {"attack", 3}, {"release", 1}, {"detect", 1}}},
        {"Bass bus", "Bass: 4:1, slow, holding sub and top together",
         {{"variant", 3}, {"threshold", -18}, {"ratio", 2}, {"attack", 30}, {"release", 2}, {"sc_hpf", 40}}},
        {"Warm bus", "Lo-fi: 10:1 into the warm character, gluey and dense",
         {{"variant", 3}, {"threshold", -20}, {"ratio", 3}, {"attack", 3}, {"release", 4}, {"character", 1}, {"mix", 0.7}}},
        {"Keyed bus pump", "Sound design: key it from the kick, the whole bus breathes with it",
         {{"variant", 3}, {"threshold", -26}, {"ratio", 3}, {"attack", 0.1}, {"release", 1}, {"sidechain", 1}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& hatchPresets() {
    static const std::vector<BuiltinPreset> p = {
        // Expand (1)
        {"Tame the room", "Drums: pulls a tom's or snare's room down between hits, gently",
         {{"variant", 1}, {"threshold", -35}, {"ratio", 2}, {"range", -18}, {"attack", 0.5}, {"hold", 30}, {"release", 150}}},
        {"Vocal breaths down", "Vocals: lowers breaths and bleed between phrases",
         {{"variant", 1}, {"threshold", -42}, {"ratio", 1.8}, {"range", -12}, {"attack", 2}, {"hold", 50}, {"release", 250}, {"detect", 1}}},
        {"Guitar hum down", "Guitar: an amp's hiss and hum sink when the playing stops",
         {{"variant", 1}, {"threshold", -50}, {"ratio", 3}, {"range", -30}, {"attack", 1}, {"hold", 40}, {"release", 200}}},
        {"Bass bleed down", "Bass: quiets the bleed of other mics on a bass DI or amp",
         {{"variant", 1}, {"threshold", -40}, {"ratio", 2}, {"range", -15}, {"attack", 3}, {"hold", 60}, {"release", 300}, {"sc_lpf", 2000}}},
        {"Podcast clean", "Vocals: room tone drops under a speaker's pauses",
         {{"variant", 1}, {"threshold", -45}, {"ratio", 2.5}, {"range", -20}, {"attack", 5}, {"hold", 150}, {"release", 400}, {"detect", 1}}},
        {"Mix tidy", "Mixing: a light expander to clean up the noise floor of a stem",
         {{"variant", 1}, {"threshold", -55}, {"ratio", 1.5}, {"range", -10}, {"attack", 2}, {"hold", 20}, {"release", 300}}},
        {"Hats tight", "Drums: shortens the ring of hats and cymbals, the key filtered to the top",
         {{"variant", 1}, {"threshold", -30}, {"ratio", 4}, {"range", -40}, {"attack", 0.1}, {"hold", 5}, {"release", 60}, {"sc_hpf", 3000}}},
        {"Keyed expand", "Sound design: key it from another track, which opens this one",
         {{"variant", 1}, {"threshold", -30}, {"ratio", 4}, {"range", -60}, {"attack", 0.5}, {"hold", 10}, {"release", 100}, {"sidechain", 1}}},
        // Pedal gate (2)
        {"High-gain guitar", "Guitar: before the drive, silence between riffs with no chatter",
         {{"variant", 2}, {"threshold", -50}, {"hysteresis", 8}, {"attack", 0.1}, {"hold", 10}, {"release", 60}, {"tracking", 0.7}}},
        {"Palm mute chug", "Guitar: chugs stop dead, the tracked release kept short",
         {{"variant", 2}, {"threshold", -45}, {"hysteresis", 6}, {"attack", 0.05}, {"hold", 2}, {"release", 20}, {"tracking", 0.3}}},
        {"Clean sustain", "Guitar: a clean note fades as it was dying, the hiss stays out",
         {{"variant", 2}, {"threshold", -60}, {"hysteresis", 10}, {"attack", 0.5}, {"hold", 30}, {"release", 200}, {"tracking", 1}}},
        {"Bass gate", "Bass: lets a slow note ring, kills the hum between",
         {{"variant", 2}, {"threshold", -55}, {"hysteresis", 8}, {"attack", 0.3}, {"hold", 20}, {"release", 150}, {"tracking", 0.8}, {"sc_hpf", 30}}},
        {"Tight drums", "Drums: a kick or tom gated short, no chatter on its tail",
         {{"variant", 2}, {"threshold", -35}, {"hysteresis", 6}, {"attack", 0.05}, {"hold", 15}, {"release", 40}, {"tracking", 0.4}}},
        {"Vocal booth", "Vocals: the room between lines goes away, the end of a word kept",
         {{"variant", 2}, {"threshold", -50}, {"hysteresis", 10}, {"attack", 1}, {"hold", 50}, {"release", 250}, {"tracking", 0.8}, {"range", -24}}},
        {"Soft floor", "Mixing: only 12 dB down when closed, for a natural noise floor",
         {{"variant", 2}, {"threshold", -55}, {"hysteresis", 6}, {"attack", 0.5}, {"hold", 20}, {"release", 150}, {"tracking", 0.5}, {"range", -12}}},
        {"Stutter gate", "Sound design: key it from a rhythm track, this one chops in time",
         {{"variant", 2}, {"threshold", -30}, {"hysteresis", 4}, {"attack", 0.05}, {"hold", 0}, {"release", 10}, {"tracking", 0}, {"sidechain", 1}}},
    };
    return p;
}

const std::vector<BuiltinPreset>& duckDevicePresets() {
    static const std::vector<BuiltinPreset> p = [] {
        std::vector<BuiltinPreset> v = duckVariantPresets();  // Duck (0), 1.0.8's
        const std::vector<BuiltinPreset> more = {
            // Level (1)
            {"Podcast rider", "Vocals: a speaker held near -18 LUFS, pauses left alone",
             {{"variant", 1}, {"target", -18}, {"max_boost", 9}, {"max_cut", 12}, {"speed", 1.5}, {"gate", -45}, {"lookahead", 2}}},
            {"Sung lead rider", "Vocals: rides a sung lead up and down a few dB, slowly",
             {{"variant", 1}, {"target", -16}, {"max_boost", 6}, {"max_cut", 6}, {"speed", 0.8}, {"gate", -40}, {"lookahead", 1}}},
            {"Voice-over even", "Vocals: holds narration level across takes",
             {{"variant", 1}, {"target", -20}, {"max_boost", 12}, {"max_cut", 12}, {"speed", 2}, {"gate", -50}, {"lookahead", 3}}},
            {"Guitar level", "Guitar: evens a part that moves between rhythm and lead",
             {{"variant", 1}, {"target", -18}, {"max_boost", 6}, {"max_cut", 9}, {"speed", 3}, {"gate", -45}}},
            {"Bass level", "Bass: keeps the line's loudness steady across a song",
             {{"variant", 1}, {"target", -16}, {"max_boost", 4}, {"max_cut", 6}, {"speed", 4}, {"gate", -45}}},
            {"Stem leveller", "Mixing: slow and gentle, a stem kept near its target",
             {{"variant", 1}, {"target", -20}, {"max_boost", 3}, {"max_cut", 3}, {"speed", 6}, {"gate", -50}}},
            {"Master rider", "Mastering: a very slow ride of a dB or two toward -14 LUFS",
             {{"variant", 1}, {"target", -14}, {"max_boost", 2}, {"max_cut", 2}, {"speed", 10}, {"gate", -40}, {"lookahead", 3}}},
            {"Pump up the quiet", "Lo-fi: a fast rider that drags everything to one loudness",
             {{"variant", 1}, {"target", -14}, {"max_boost", 18}, {"max_cut", 18}, {"speed", 0.2}, {"gate", -70}}},
            // Carve (2): keyed by the part that should come through.
            {"Vocal space", "Vocals: key it from the vocal: the music dips where the voice is",
             {{"variant", 2}, {"amount", 0.7}, {"range", 6}, {"low", 200}, {"high", 6000}, {"attack", 10}, {"release", 150}}},
            {"Kick through bass", "Bass: key it from the kick: the bass dips only in the kick's lows",
             {{"variant", 2}, {"amount", 0.9}, {"range", 9}, {"low", 30}, {"high", 300}, {"attack", 2}, {"release", 90}}},
            {"Snare through guitars", "Guitar: key it from the snare: the guitars open for its crack",
             {{"variant", 2}, {"amount", 0.6}, {"range", 6}, {"low", 150}, {"high", 8000}, {"attack", 2}, {"release", 100}}},
            {"Lead over pads", "Mixing: key it from the lead: the pads step out of its way",
             {{"variant", 2}, {"amount", 0.6}, {"range", 6}, {"low", 150}, {"high", 10000}, {"attack", 15}, {"release", 200}}},
            {"Drums over the mix", "Drums: key it from the drum bus: the music bus parts for each hit",
             {{"variant", 2}, {"amount", 0.5}, {"range", 4}, {"low", 40}, {"high", 12000}, {"attack", 3}, {"release", 120}, {"bands", 1}}},
            {"Voice-over bed", "Vocals: key it from the narration: deep, slow dips in the music bed",
             {{"variant", 2}, {"amount", 1}, {"range", 12}, {"low", 150}, {"high", 7000}, {"attack", 20}, {"release", 400}}},
            {"Wide carve", "Mixing: Mid/Side: the key's centre dips the mid, its sides the sides",
             {{"variant", 2}, {"amount", 0.6}, {"range", 6}, {"low", 100}, {"high", 12000}, {"stereo", 2}}},
            {"Spectral pump", "Sound design: key it from a loop: a deep, fast spectral sidechain",
             {{"variant", 2}, {"amount", 1}, {"range", 24}, {"low", 40}, {"high", 16000}, {"attack", 1}, {"release", 60}, {"bands", 1}}},
        };
        v.insert(v.end(), more.begin(), more.end());
        return v;
    }();
    return p;
}

}  // namespace

std::span<const BuiltinPreset> newVariantPresets(std::string_view id) {
    if (id == "org.caw.compressor") return talonPresets();
    if (id == "org.caw.gate") return hatchPresets();
    if (id == "org.caw.duck") return duckDevicePresets();
    return {};
}

}  // namespace caw::fx
