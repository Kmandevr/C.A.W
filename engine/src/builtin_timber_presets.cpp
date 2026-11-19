// Timber's presets: at least six per model, named for the job, each naming its `variant` (model).
#include <string_view>
#include <vector>

#include "builtin_timber.h"
#include "presets.h"

namespace caw::timber {
namespace {

using V = std::vector<std::pair<std::string_view, double>>;

V with(double variant, V v) {
    v.emplace_back("variant", variant);
    return v;
}

const std::vector<BuiltinPreset>& list() {
    static const std::vector<BuiltinPreset> p = {
        // Piano (0)
        {"Concert grand", "Piano: a full grand in a hall, for solo and classical playing", with(0, {})},
        {"Pop ballad piano", "Piano: a bright, close grand that sits in a mix", with(0, {{"hammer", 0.75}, {"tone", 0.25}, {"space", 0.1}, {"decay", 0.9}})},
        {"Felt piano", "Piano: a soft felt-muted upright, intimate and dark, for film and lo-fi", with(0, {{"character", 2}, {"hammer", 0.15}, {"tone", -0.3}, {"release", 0.5}, {"space", 0.25}})},
        {"Upright practice", "Piano: a boxy upright in a small room", with(0, {{"character", 1}, {"hammer", 0.55}, {"unison", 2.0}, {"space", 0.08}, {"body", 0.85}})},
        {"Honky-tonk", "Piano: an old upright out of tune with itself, for saloon and ragtime", with(0, {{"character", 1}, {"unison", 6.0}, {"hammer", 0.7}, {"tone", 0.2}})},
        {"Pedalled ambience", "Piano: sustain down, strong resonance and a wide room, for ambient washes", with(0, {{"sustain", 1.0}, {"resonance", 0.8}, {"space", 0.4}, {"hammer", 0.35}})},
        {"Jazz trio piano", "Piano: a warm grand with a soft touch, close", with(0, {{"hammer", 0.4}, {"tone", -0.1}, {"space", 0.1}, {"velocity", 0.9}})},
        {"Una corda", "Piano: the soft pedal down, a hushed and veiled grand", with(0, {{"soft", 1.0}, {"hammer", 0.3}, {"space", 0.2}})},
    };
    return p;
}

}  // namespace

const std::vector<BuiltinPreset>* timberPresets(std::string_view id) { return id == kTimberId ? &list() : nullptr; }

}  // namespace caw::timber
