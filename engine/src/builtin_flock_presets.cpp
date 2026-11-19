// Flock's presets (org.caw.flock): named for the job and tagged by purpose; each plays a built-in tone, so it sounds with no sample loaded.
#include <string_view>
#include <vector>

#include "builtin_flock.h"
#include "presets.h"

namespace caw::flock {

namespace {
using V = std::vector<std::pair<std::string_view, double>>;
}

const std::vector<BuiltinPreset>* presets(std::string_view id) {
    static const std::vector<BuiltinPreset> p = {
        {"Soft strings cloud", "Sound design: a gentle pad of string grains that opens as it scans", V{{"builtin", 0}, {"size", 140}, {"density", 22}, {"spray", 60}, {"scan", 0.15}, {"attack", 0.4}, {"release", 1.5}, {"pan", 0.6}}},
        {"Glass shimmer", "Sound design: glassy grains an octave up, scattered over octaves", V{{"builtin", 1}, {"pitch", 12}, {"spread", 12}, {"scale", 5}, {"size", 70}, {"density", 40}, {"window", 2}, {"release", 2.0}, {"pan", 0.8}}},
        {"Breath pad", "Sound design: airy breath grains, slow and wide", V{{"builtin", 2}, {"size", 220}, {"density", 14}, {"spray", 150}, {"attack", 0.8}, {"release", 2.5}, {"width", 1.5}, {"filter", 1}, {"cutoff", 6000}}},
        {"Grain choir", "Vocals: a choir smeared into a soft cloud of vowels", V{{"builtin", 3}, {"size", 180}, {"density", 24}, {"spread", 0.25}, {"spray", 40}, {"scan", 0.1}, {"attack", 0.3}, {"release", 1.8}}},
        {"Frozen vowel", "Vocals: one moment of the choir held still as a pad", V{{"builtin", 3}, {"freeze", 1}, {"position", 0.55}, {"size", 260}, {"density", 18}, {"spray", 5}, {"jitter", 0.4}, {"attack", 0.5}, {"release", 2.0}}},
        {"Scatter keys", "Sound design: short percussive grains plucked from the strings", V{{"builtin", 0}, {"size", 30}, {"density", 60}, {"window", 3}, {"spray", 300}, {"attack", 0.002}, {"decay", 0.6}, {"sustain", 0.0}, {"release", 0.4}, {"filter", 1}, {"cutoff", 8000}, {"filter_env", 2}, {"filter_decay", 0.3}}},
        {"Reverse bloom", "Sound design: grains mostly backwards, swelling in", V{{"builtin", 1}, {"reverse", 0.85}, {"size", 160}, {"density", 20}, {"window", 4}, {"spray", 120}, {"attack", 1.2}, {"release", 2.0}}},
        {"Octave rain", "Sound design: grains raining down the octaves on a major scale", V{{"builtin", 1}, {"spread", 24}, {"scale", 2}, {"size", 45}, {"density", 70}, {"jitter", 0.8}, {"pan", 1}, {"release", 1.2}}},
        {"Dark drone", "Bass: two octaves down, long grains through a low-pass", V{{"builtin", 0}, {"pitch", -24}, {"size", 400}, {"density", 10}, {"spray", 80}, {"filter", 1}, {"cutoff", 900}, {"resonance", 1.5}, {"attack", 1.0}, {"release", 3.0}, {"voices", 4}}},
        {"Sub grain bass", "Bass: a tight mono-ish grain bass with a filter pluck", V{{"builtin", 2}, {"pitch", -12}, {"size", 60}, {"density", 50}, {"spray", 2}, {"pan", 0.05}, {"width", 0.3}, {"filter", 1}, {"cutoff", 400}, {"filter_env", 3}, {"filter_decay", 0.15}, {"attack", 0.003}, {"release", 0.2}, {"voices", 2}}},
        {"Lo-fi dust", "Lo-fi: tiny, sparse, scattered grains, filtered dark", V{{"builtin", 2}, {"size", 8}, {"density", 120}, {"spray", 400}, {"jitter", 1}, {"window", 3}, {"filter", 1}, {"cutoff", 3500}, {"release", 0.8}}},
        {"Tempo stutter", "Sound design: sixteenth-note grains in time with the song", V{{"builtin", 3}, {"sync", 3}, {"size", 70}, {"jitter", 0}, {"window", 3}, {"spray", 1}, {"release", 0.5}}},
    };
    return id == kFlockId ? &p : nullptr;
}

}  // namespace caw::flock
