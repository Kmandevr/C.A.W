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
        // Electric piano (1)
        {"Tine ballad", "Electric piano: a mellow tine piano with a slow stereo pan, for soul and ballads", with(1, {{"pickup", 0.35}, {"bell", 0.4}, {"tremolo", 0.5}, {"rate", 3.0}})},
        {"Tine bark", "Electric piano: a close pickup played hard, growling, for funk and rock", with(1, {{"pickup", 0.9}, {"symmetry", 0.5}, {"bark", 0.7}, {"bell", 0.6}})},
        {"Bell keys", "Electric piano: a glassy, bell-heavy tine for pop pads", with(1, {{"bell", 1.0}, {"pickup", 0.3}, {"space", 0.25}, {"tone", 0.2}})},
        {"Reed classic", "Electric piano: a reed piano with its tremolo, for soul and pop", with(1, {{"kind", 1}, {"tremolo", 0.4}, {"rate", 5.5}, {"bark", 0.3}})},
        {"Reed grit", "Electric piano: an overdriven reed for rock rhythm parts", with(1, {{"kind", 1}, {"bark", 0.8}, {"pickup", 0.8}, {"symmetry", 0.6}})},
        {"Soft tine pad", "Electric piano: a dark, long tine for backing chords", with(1, {{"pickup", 0.15}, {"bell", 0.15}, {"decay", 2.0}, {"tone", -0.3}, {"release", 0.4}})},
        // Organ (2)
        {"Gospel full", "Organ: all the low drawbars out, fast rotary, for gospel and soul", with(2, {{"db16", 8}, {"db513", 8}, {"db8", 8}, {"db4", 8}, {"db223", 6}, {"db2", 6}, {"rotary", 2}, {"drive", 0.3}})},
        {"Jazz percussion", "Organ: 888 with 3rd-harmonic fast percussion, for jazz comping", with(2, {{"perc", 2}, {"perc_decay", 1}, {"vibrato", 6}, {"click", 0.5}})},
        {"Rock drive", "Organ: a driven full registration on a fast rotary, for rock", with(2, {{"db4", 8}, {"db2", 6}, {"db1", 8}, {"drive", 0.8}, {"rotary", 2}, {"click", 0.6}})},
        {"Ballad soft", "Organ: flutes 8' and 4' on a slow rotary, for quiet backing", with(2, {{"db16", 0}, {"db513", 0}, {"db8", 6}, {"db4", 4}, {"vibrato", 5}, {"drive", 0.0}, {"click", 0.1}})},
        {"Church flutes", "Organ: soft stops without the rotary, for hymns and pads", with(2, {{"db16", 6}, {"db513", 0}, {"db8", 8}, {"db4", 6}, {"db2", 4}, {"rotary", 0}, {"click", 0.0}, {"space", 0.35}, {"release", 0.3}})},
        {"Reggae bubble", "Organ: a short, percussive mid registration for skank chords", with(2, {{"db16", 0}, {"db513", 0}, {"db8", 8}, {"db4", 8}, {"db223", 8}, {"perc", 1}, {"perc_decay", 1}, {"rotary", 1}})},
        // Plucked (3)
        {"Steel strummer", "Plucked: a bright steel-string acoustic for strummed chords", with(3, {{"brightness", 0.6}, {"pick", 0.6}})},
        {"Fingerstyle nylon", "Plucked: a warm nylon-string guitar plucked with the fingers", with(3, {{"instrument", 1}, {"pick", 0.2}, {"position", 0.25}, {"brightness", 0.3}})},
        {"Palm-muted picking", "Plucked: steel strings muted at the bridge, for tight rhythm parts", with(3, {{"damping", 0.8}, {"pick", 0.8}, {"position", 0.1}})},
        {"Concert harp", "Plucked: a harp whose strings ring on after the key, for glissandos and arpeggios", with(3, {{"instrument", 2}, {"pick", 0.25}, {"space", 0.3}, {"position", 0.3}})},
        {"Koto", "Plucked: a bright, near-bridge koto pluck", with(3, {{"instrument", 3}, {"position", 0.07}, {"pick", 0.8}, {"brightness", 0.7}})},
        {"Music box pluck", "Plucked: short, thin and bright, for lullabies and sound design", with(3, {{"decay", 0.4}, {"position", 0.05}, {"brightness", 0.9}, {"body", 0.1}})},
        // Bowed (4)
        {"Solo violin", "Bowed: an expressive violin with vibrato, for melodies", with(4, {{"vibrato", 0.5}, {"space", 0.25}})},
        {"Viola legato", "Bowed: a mellow viola with a soft attack, for inner voices", with(4, {{"section", 1}, {"attack", 0.25}, {"vibrato", 0.35}})},
        {"Cello lament", "Bowed: a warm, singing cello", with(4, {{"section", 2}, {"pressure", 0.6}, {"vibrato", 0.45}, {"space", 0.3}})},
        {"Bass pizz-like bow", "Bowed: a short, heavy double bass bow for low lines", with(4, {{"section", 3}, {"attack", 0.03}, {"release", 0.1}, {"pressure", 0.7}})},
        {"Sul ponticello", "Bowed: bowed near the bridge, glassy and thin, for tension cues", with(4, {{"position", 0.04}, {"pressure", 0.3}, {"vibrato", 0.0}})},
        {"Slow swell", "Bowed: long attacks and no vibrato, for string pads", with(4, {{"attack", 1.0}, {"release", 0.8}, {"vibrato", 0.1}, {"space", 0.4}})},
    };
    return p;
}

}  // namespace

const std::vector<BuiltinPreset>* timberPresets(std::string_view id) { return id == kTimberId ? &list() : nullptr; }

}  // namespace caw::timber
