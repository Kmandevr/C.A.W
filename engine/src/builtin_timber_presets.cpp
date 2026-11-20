// Timber's presets: at least six per model, named for the job, each naming its `variant` (model); 1.1.2 adds six or more Simulated ones per model.
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
// 1.1.2: a preset of a model's Simulated choice.
V sim(V v) {
    v.emplace_back("sim", 1.0);
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
        // Mallets (5)
        {"Concert marimba", "Mallets: a warm rosewood marimba with yarn mallets", with(5, {{"hardness", 0.35}})},
        {"Jazz vibes", "Mallets: a vibraphone with its motor and damper pedal, for jazz", with(5, {{"instrument", 1}, {"motor", 5.0}, {"dampen", 0.8}, {"space", 0.2}})},
        {"Bright xylophone", "Mallets: a hard-mallet xylophone for quick figures", with(5, {{"instrument", 2}, {"hardness", 0.85}})},
        {"Glockenspiel", "Mallets: a bright steel glockenspiel for sparkling lines", with(5, {{"instrument", 3}, {"hardness", 0.8}, {"space", 0.25}})},
        {"Tubular chimes", "Mallets: orchestral chimes for big moments", with(5, {{"instrument", 4}, {"hardness", 0.6}, {"space", 0.35}, {"decay", 1.5}})},
        {"Church bell", "Mallets: a large bronze bell, its hum ringing long", with(5, {{"instrument", 5}, {"hardness", 0.7}, {"space", 0.45}, {"decay", 2.0}})},
        // Winds (6)
        {"Clarinet solo", "Winds: a woody clarinet with a gentle vibrato", with(6, {{"vibrato", 0.25}, {"space", 0.2}})},
        {"Breathy flute", "Winds: a soft flute with plenty of breath", with(6, {{"instrument", 1}, {"noise", 0.45}, {"vibrato", 0.35}, {"space", 0.25}})},
        {"Tenor sax", "Winds: a full, reedy sax for melodies", with(6, {{"instrument", 2}, {"reed", 0.6}, {"vibrato", 0.3}})},
        {"Growl sax", "Winds: a growled, gritty sax for rock and funk solos", with(6, {{"instrument", 2}, {"growl", 0.6}, {"breath", 0.85}})},
        {"Muted brass", "Winds: a soft, round brass line", with(6, {{"instrument", 3}, {"breath", 0.45}, {"reed", 0.4}})},
        {"Brass stab", "Winds: a bright brass hit with a fast attack, for horn sections", with(6, {{"instrument", 3}, {"breath", 0.9}, {"attack", 0.01}, {"release", 0.05}})},
        // ---------- 1.1.2: Simulated (every model but the piano; the piano's are in their own block) ----------
        // Electric piano (1)
        {"Real tine stage piano", "Electric piano, simulated: a hammered tine through its pickup, the action heard softly, for ballads and soul", with(1, sim({{"pickup", 0.45}, {"bell", 0.5}, {"tremolo", 0.3}, {"rate", 3.5}}))},
        {"Real tine, close and hard", "Electric piano, simulated: struck hard near the pickup, barking, for funk comping", with(1, sim({{"pickup", 0.85}, {"symmetry", 0.45}, {"bark", 0.6}, {"bell", 0.7}, {"velocity", 1.0}}))},
        {"Real reed classroom", "Electric piano, simulated: a steel reed with its tremolo and the keys' thunk, for soul and pop", with(1, sim({{"kind", 1}, {"tremolo", 0.45}, {"rate", 5.5}, {"bark", 0.25}, {"noises", 0.4}}))},
        {"Real reed rock", "Electric piano, simulated: an overdriven reed played hard, for rock rhythm parts", with(1, sim({{"kind", 1}, {"bark", 0.8}, {"pickup", 0.8}, {"symmetry", 0.5}}))},
        {"Felt-quiet tine", "Electric piano, simulated: a soft tine with the hammers and dampers barely heard, for film and lo-fi", with(1, sim({{"pickup", 0.2}, {"bell", 0.2}, {"tone", -0.3}, {"noises", 0.15}, {"space", 0.25}}))},
        {"Close-miked tine", "Electric piano, simulated: the action's thunk and damper felt up front, as a mic by the keys hears them", with(1, sim({{"pickup", 0.5}, {"noises", 1.0}, {"space", 0.05}}))},
        // Organ (2)
        {"Real tonewheel 888", "Organ, simulated: 888 with the keys' contacts clicking as they close, slow rotary, for gospel and soul", with(2, sim({{"click", 0.5}, {"rotary", 1}}))},
        {"Real jazz percussion", "Organ, simulated: 3rd percussion and a crisp contact click, for jazz comping", with(2, sim({{"perc", 2}, {"perc_decay", 1}, {"vibrato", 6}, {"click", 0.8}}))},
        {"Real rock organ", "Organ, simulated: full and driven on a fast rotary, hard contacts, for rock", with(2, sim({{"db4", 8}, {"db2", 6}, {"db1", 8}, {"drive", 0.75}, {"rotary", 2}, {"click", 0.9}}))},
        {"Real ballad flutes", "Organ, simulated: soft flutes with worn, gentle contacts, for quiet backing", with(2, sim({{"db16", 0}, {"db513", 0}, {"db8", 6}, {"db4", 4}, {"vibrato", 5}, {"drive", 0.0}, {"click", 0.15}}))},
        {"Real reggae bubble", "Organ, simulated: short mid stops whose contacts click on every skank", with(2, sim({{"db16", 0}, {"db513", 0}, {"db8", 8}, {"db4", 8}, {"db223", 8}, {"perc", 1}, {"perc_decay", 1}, {"click", 0.7}}))},
        {"Real church stops", "Organ, simulated: soft stops without the rotary, the contacts almost silent, for hymns", with(2, sim({{"db16", 6}, {"db513", 0}, {"db8", 8}, {"db4", 6}, {"db2", 4}, {"rotary", 0}, {"click", 0.05}, {"space", 0.35}, {"release", 0.3}}))},
        // Plucked (3)
        {"Real steel acoustic", "Plucked, simulated: a picked steel-string guitar, hard strokes buzzing on the frets, for strumming", with(3, sim({{"brightness", 0.6}, {"pick", 0.6}}))},
        {"Real fingerstyle nylon", "Plucked, simulated: a nylon guitar plucked with the fingers, the bass strings squeaking on slides", with(3, sim({{"instrument", 1}, {"pick", 0.2}, {"position", 0.25}, {"brightness", 0.3}, {"noises", 0.4}}))},
        {"Real slide blues", "Plucked, simulated: steel strings for bends and glides, the windings heard as the finger slides", with(3, sim({{"pick", 0.55}, {"position", 0.15}, {"noises", 0.6}, {"release", 0.3}}))},
        {"Real palm mute", "Plucked, simulated: muted at the bridge and picked hard, for tight rhythm parts", with(3, sim({{"damping", 0.8}, {"pick", 0.8}, {"position", 0.1}}))},
        {"Real concert harp", "Plucked, simulated: a harp let go from the fingers, ringing on, for arpeggios", with(3, sim({{"instrument", 2}, {"pick", 0.25}, {"space", 0.3}, {"position", 0.3}}))},
        {"Real koto", "Plucked, simulated: a bright koto plucked near its bridge", with(3, sim({{"instrument", 3}, {"position", 0.07}, {"pick", 0.8}, {"brightness", 0.7}}))},
        // Bowed (4)
        {"Real solo violin", "Bowed, simulated: elasto-plastic bow friction with its noise, for expressive melodies", with(4, sim({{"vibrato", 0.5}, {"space", 0.25}}))},
        {"Real cello", "Bowed, simulated: a singing cello bowed firmly, for lines and solos", with(4, sim({{"section", 2}, {"pressure", 0.6}, {"vibrato", 0.45}, {"space", 0.3}}))},
        {"Real double bass", "Bowed, simulated: a heavy bass bow for low lines", with(4, sim({{"section", 3}, {"pressure", 0.7}, {"attack", 0.04}, {"release", 0.12}}))},
        {"Real viola", "Bowed, simulated: a mellow viola with a soft attack, for inner voices", with(4, sim({{"section", 1}, {"attack", 0.2}, {"vibrato", 0.35}}))},
        {"Real scratchy bow", "Bowed, simulated: too much bow force for the speed: the raucous, scratching tone, for tension and sound design", with(4, sim({{"pressure", 1.0}, {"speed", 0.2}, {"noises", 0.7}, {"vibrato", 0.0}}))},
        {"Real airy flautando", "Bowed, simulated: a light, fast bow over the fingerboard, breathy and soft, for film", with(4, sim({{"pressure", 0.2}, {"speed", 0.8}, {"position", 0.25}, {"noises", 0.5}, {"space", 0.35}}))},
        // Mallets (5)
        {"Real marimba, yarn mallets", "Mallets, simulated: a rosewood marimba struck with soft yarn mallets, for warm figures", with(5, sim({{"hardness", 0.3}}))},
        {"Real marimba, hard mallets", "Mallets, simulated: hard rubber mallets, bright and knocking, for fast lines", with(5, sim({{"hardness", 0.85}, {"noises", 0.4}}))},
        {"Real jazz vibes", "Mallets, simulated: a vibraphone with motor and damper, cord mallets, for jazz", with(5, sim({{"instrument", 1}, {"motor", 5.0}, {"dampen", 0.8}, {"hardness", 0.45}, {"space", 0.2}}))},
        {"Real xylophone", "Mallets, simulated: hard plastic mallets on rosewood bars, for quick orchestral figures", with(5, sim({{"instrument", 2}, {"hardness", 0.9}}))},
        {"Real glockenspiel", "Mallets, simulated: brass mallets on steel bars, sparkling, for celesta-like lines", with(5, sim({{"instrument", 3}, {"hardness", 0.8}, {"space", 0.25}}))},
        {"Real tubular bells", "Mallets, simulated: chimes struck with a rawhide hammer, for big moments", with(5, sim({{"instrument", 4}, {"hardness", 0.65}, {"space", 0.35}, {"decay", 1.5}}))},
        // Winds (6)
        {"Real clarinet", "Winds, simulated: a reed clarinet with tongued attacks and soft key clicks, for melodies", with(6, sim({{"vibrato", 0.2}, {"space", 0.2}}))},
        {"Real breathy flute", "Winds, simulated: a jet-driven flute whose breath noise pulses with the tone, for soft melodies", with(6, sim({{"instrument", 1}, {"noise", 0.35}, {"vibrato", 0.35}, {"space", 0.25}}))},
        {"Real tenor sax", "Winds, simulated: a conical sax bore with tongued attacks, for melodies and solos", with(6, sim({{"instrument", 2}, {"reed", 0.6}, {"vibrato", 0.3}}))},
        {"Real growl sax", "Winds, simulated: a growled sax blown hard, for rock and funk solos", with(6, sim({{"instrument", 2}, {"growl", 0.6}, {"breath", 0.85}}))},
        {"Real brass section", "Winds, simulated: lips on a brass bore, brightening and brassy as it gets louder, for horn sections", with(6, sim({{"instrument", 3}, {"breath", 0.6}, {"attack", 0.02}}))},
        {"Real soft brass", "Winds, simulated: brass played softly: round and dark, for pads and chorales", with(6, sim({{"instrument", 3}, {"breath", 0.3}, {"velocity", 0.5}, {"attack", 0.08}, {"space", 0.3}}))},
        {"Close-miked flute", "Winds, simulated: the breath, tongue and keys up front, as a close mic hears them", with(6, sim({{"instrument", 1}, {"noise", 0.5}, {"noises", 1.0}, {"space", 0.05}}))},
    };
    return p;
}

}  // namespace

const std::vector<BuiltinPreset>* timberPresets(std::string_view id) { return id == kTimberId ? &list() : nullptr; }

}  // namespace caw::timber
