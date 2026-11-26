// Bittern (org.caw.bittern): the pipe organ's descriptor (its stops as levels), presets (registrations), registration and sizes.
#include "builtin_bittern.h"

#include <memory>
#include <new>
#include <vector>

#include "bittern_organ.h"
#include "builtin_effects.h"
#include "presets.h"
#include "instrument_core.h"

namespace caw::bittern {
namespace {

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

// The stops in Stop's order (by division), their ids and labels (the Tabernacle organ's names and pitches) and the
// default registration (the Great's Principal 8' and Octave 4', the Swell's Gedeckt coupled, the Pedal's Bourdon
// under the lowest key). A stop of the 1.1.3-alpha organ keeps its id where it is the same kind of pipe, so a project
// from then loads (bourdon16 is now the Pedal's, subbass32 the Contre Bourdon 32', rohrflute8 the Gedeckt 8', gamba8
// the Viole Céleste II, flute4 the Flauto Traverso 4', fifteenth2 the Super Octave 2', mixture the Fourniture IV).
struct StopInfo {
    const char* id;
    const char* name;
    double initial;
};
constexpr StopInfo kStopInfo[kStops] = {
    {"subprincipal16", "Subprincipal 16'", 0.0}, {"principal8", "Principal 8'", 1.0},
    {"flute_harm8", "Flûte Harmonique 8'", 0.0}, {"octave4", "Octave 4'", 0.7},
    {"fifteenth2", "Super Octave 2'", 0.0},      {"mixture", "Fourniture IV", 0.0},
    {"trumpet8", "Trumpet 8'", 0.0},
    {"geigen8", "Geigen Principal 8'", 0.0},     {"rohrflute8", "Gedeckt 8'", 0.5},
    {"gamba8", "Viole Céleste II", 0.0},         {"flute4", "Flauto Traverso 4'", 0.0},
    {"nazard", "Nazard 2 2/3'", 0.0},            {"tierce", "Tierce 1 3/5'", 0.0},
    {"plein_jeu", "Plein Jeu IV", 0.0},          {"trompette8", "1ère Trompette 8'", 0.0},
    {"hautbois8", "Hautbois 8'", 0.0},
    {"concert_flute8", "Concert Flute 8'", 0.0}, {"erzahler8", "Kleine Erzähler II", 0.0},
    {"krummhorn8", "Krummhorn 8'", 0.0},
    {"tuba8", "Tuba Mirabilis 8'", 0.0},
    {"subbass32", "Contre Bourdon 32'", 0.0},    {"ped_principal16", "Principal 16'", 0.0},
    {"bourdon16", "Bourdon 16'", 0.6},           {"ped_principal8", "Principal 8' (Pedal)", 0.0},
    {"trombone16", "Trombone 16'", 0.0},         {"bombarde32", "Bombarde 32'", 0.0},
    {"gemshorn4", "Gemshorn 4'", 0.0},           {"voix_humaine8", "Voix Humaine 8'", 0.0},
    {"violin8", "Violin 8'", 0.0},               {"cello8", "Violoncello 8'", 0.0},
    {"contrabass16", "Contrabass 16'", 0.0},     {"quint10", "Quint 10 2/3'", 0.0},
    {"choral_bass4", "Choral Bass 4'", 0.0},
};
constexpr const char* kDivisionGroup[kDivisions] = {"great", "swell", "choir", "antiphonal", "pedal"};
// The registration choice (kRegistration's rows): the organ's usual combinations, one tap; "Stops" plays the knobs.
constexpr std::string_view kRegistrationNames[kRegistrations] = {
    "Stops", "Soft accompaniment", "Hymn plenum", "Hymn with reeds", "Full organ", "Tuba over full",
    "Harmonic flute solo", "Reed solo", "Celestes"};
constexpr std::string_view kPedalNames[] = {"Lowest key", "Every key"};

const ModuleDescriptor& descriptor() {
    static fx::ParamTable t;
    static std::vector<ParameterDescriptor> params;
    static ModuleDescriptor m;
    static const bool built = [] {
        // The instruments' shared knobs (instrument_core.h reads them by index). The room is on: Space 0.45, the hall
        // (owner, 2026-11-24: the organ is the one realistic instrument that is not dry).
        t.num("tone", "Tone", 0.0, -1.0, 1.0).group = "shared";
        t.num("body", "Body", 0.5, 0.0, 1.0).group = "shared";
        t.num("space", "Space", 0.45, 0.0, 1.0).group = "shared";
        t.num("velocity", "Velocity", 0.6, 0.0, 1.0).group = "shared";  // a tracker action: a key struck hard speaks sooner
        t.expo("release", "Release", 0.12, 0.005, 10.0, "s").group = "shared";
        ParameterDescriptor& v = t.num("voices", "Voices", 16.0, 1.0, 24.0);
        v.step = 1.0, v.smoothingFrames = 0, v.group = "shared";
        t.num("level", "Level", 0.0, -48.0, 12.0, "dB").group = "shared";
        for (int k = 0; k < kStops; ++k) t.num(kStopInfo[k].id, kStopInfo[k].name, kStopInfo[k].initial, 0.0, 1.0).group = kDivisionGroup[kDivisionOf[k]];
        t.num("tremulant", "Tremulant", 0.0, 0.0, 1.0).group = "wind";
        t.num("wind", "Living wind", 0.3, 0.0, 1.0).group = "wind";
        t.num("chiff", "Chiff", 0.5, 0.0, 1.0).group = "wind";
        t.expo("trem_rate", "Tremulant rate", 6.0, 2.0, 9.0, "Hz").group = "wind";
        // Last, so every earlier knob keeps its place: a project from before it plays its stops as drawn.
        ParameterDescriptor& r = t.pick("registration", "Registration", 0.0, kRegistrationNames);
        r.group = "registration", r.modulatable = false;
        // One keyboard plays the manuals and the pedal: the pedal stops on the lowest key held (a bass line under
        // the hands) or on every key, within the pedal's compass.
        ParameterDescriptor& ped = t.pick("pedal", "Pedal", 0.0, kPedalNames);
        ped.group = "pedal", ped.modulatable = false;
        // The Swell's and the Choir's boxes as a knob (1 open; the mod wheel closes them from here), automatable.
        t.num("swell", "Swell", 1.0, 0.0, 1.0).group = "wind";
        // The floor: the organ's low end as felt in the hall, which a recording loses (+6 dB under 110 Hz at 0.5).
        t.num("weight", "Weight", 0.5, 0.0, 1.0).group = "room";
        // The Chimes (tubular bells, G3 to G5), struck by the keys.
        t.num("chimes", "Chimes", 0.0, 0.0, 1.0).group = "choir";
        // The pipes across the case: the C side left, the C# side right, the bass in the outer towers.
        t.num("spread", "Spread", 0.6, 0.0, 1.0).group = "room";
        params.assign(t.data(), t.data() + t.size());
        m.id = kBitternId;
        m.name = "Bittern";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        m.parameters = params.data();
        m.parameterCount = static_cast<uint32_t>(params.size());
        m.tailFrames = 192000 * 8;  // the hall's tail
        m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the mod wheel: the swell box
        m.cpuClass = CpuClass::Heavy;
        return true;
    }();
    (void)built;
    return m;
}
static_assert(Organ::kModelParams == kStops + 10);

ModuleProcessor* make() noexcept { return new (std::nothrow) timber::Instrument<Organ>(descriptor(), 0); }

using V = std::vector<std::pair<std::string_view, double>>;
// A registration: every stop off but the named ones.
V reg(V on) {
    V v;
    for (const StopInfo& s : kStopInfo) {
        double x = 0;
        for (const auto& [k, y] : on)
            if (k == s.id) x = y;
        v.emplace_back(s.id, x);
    }
    for (const auto& kv : on) {  // the other knobs a preset names (space, tremulant, ...)
        bool stop = false;
        for (const StopInfo& s : kStopInfo) stop = stop || kv.first == s.id;
        if (!stop) v.push_back(kv);
    }
    return v;
}

}  // namespace

void registerBittern(ModuleRegistry& registry) {
    buildTables();  // built here, so no voice ever builds them
    registry.replaceBuiltin(descriptor(), &make);
}

const std::vector<BuiltinPreset>* bitternPresets(std::string_view id) {
    static const std::vector<BuiltinPreset> p = {
        // The registrations, as their stops (the knobs show them; the Registration choice does the same in one tap).
        {"Soft accompaniment", "The Swell's Gedeckt and Viole Céleste with the Choir's Kleine Erzähler, the Pedal's Bourdon under them: for the choir to sing over", reg({{"rohrflute8", 0.8}, {"gamba8", 0.7}, {"erzahler8", 0.8}, {"bourdon16", 0.7}})},
        {"Hymn plenum", "The Great's principal chorus with its Fourniture, the Swell's Geigen and Plein Jeu coupled, the Pedal's principals", reg({{"principal8", 1}, {"octave4", 0.9}, {"fifteenth2", 0.8}, {"mixture", 0.7}, {"geigen8", 0.8}, {"plein_jeu", 0.6}, {"ped_principal16", 0.8}, {"ped_principal8", 0.7}, {"bourdon16", 0.7}})},
        {"Hymn with reeds", "The plenum with the Swell's Trompette, the Great's Trumpet and the Pedal's Trombone", reg({{"principal8", 1}, {"octave4", 0.9}, {"fifteenth2", 0.8}, {"mixture", 0.7}, {"geigen8", 0.8}, {"plein_jeu", 0.6}, {"trompette8", 0.8}, {"trumpet8", 0.8}, {"ped_principal16", 0.8}, {"ped_principal8", 0.7}, {"bourdon16", 0.7}, {"trombone16", 0.8}})},
        {"Full organ", "Every chorus out with both 32's in the Pedal, a big, gentle sound of many mild ranks", reg({{"subprincipal16", 0.8}, {"principal8", 1}, {"flute_harm8", 0.7}, {"octave4", 1}, {"fifteenth2", 0.9}, {"mixture", 0.9}, {"trumpet8", 0.9}, {"geigen8", 0.9}, {"rohrflute8", 0.6}, {"flute4", 0.6}, {"plein_jeu", 0.8}, {"trompette8", 0.9}, {"concert_flute8", 0.6}, {"subbass32", 0.9}, {"ped_principal16", 1}, {"bourdon16", 0.8}, {"ped_principal8", 0.8}, {"trombone16", 0.9}, {"bombarde32", 0.8}})},
        {"Tuba over full", "The full organ with the Antiphonal's Tuba Mirabilis singing out on top", reg({{"subprincipal16", 0.8}, {"principal8", 1}, {"flute_harm8", 0.7}, {"octave4", 1}, {"fifteenth2", 0.9}, {"mixture", 0.9}, {"trumpet8", 0.9}, {"geigen8", 0.9}, {"rohrflute8", 0.6}, {"flute4", 0.6}, {"plein_jeu", 0.8}, {"trompette8", 0.9}, {"concert_flute8", 0.6}, {"tuba8", 1}, {"subbass32", 0.9}, {"ped_principal16", 1}, {"bourdon16", 0.8}, {"ped_principal8", 0.8}, {"trombone16", 0.9}, {"bombarde32", 0.8}})},
        {"Harmonic flute solo", "The Great's Flûte Harmonique over the Swell's Viole Céleste", reg({{"flute_harm8", 1}, {"gamba8", 0.6}, {"bourdon16", 0.6}})},
        {"Krummhorn solo", "The Choir's Krummhorn over the Swell's Gedeckt and Flauto Traverso", reg({{"krummhorn8", 1}, {"rohrflute8", 0.6}, {"flute4", 0.5}, {"bourdon16", 0.6}})},
        {"Celestes", "The Swell's Viole Céleste and the Choir's Kleine Erzähler, beating slowly, with the tremulant", reg({{"gamba8", 0.9}, {"erzahler8", 0.9}, {"bourdon16", 0.6}, {"tremulant", 0.4}})},
        {"Hautbois solo", "The Swell's Hautbois over its Gedeckt, the box half closed for a plaintive line", reg({{"hautbois8", 1}, {"rohrflute8", 0.6}, {"bourdon16", 0.5}})},
        {"Trompette solo", "The Swell's French Trompette over a soft flute, for fanfares", reg({{"trompette8", 1}, {"rohrflute8", 0.5}, {"bourdon16", 0.6}})},
        {"Tuba Mirabilis", "The Antiphonal's high-pressure Tuba alone over the Swell's strings", reg({{"tuba8", 1}, {"gamba8", 0.6}, {"rohrflute8", 0.4}, {"bourdon16", 0.6}})},
        {"Cornet", "The Swell's Gedeckt, Flauto Traverso, Nazard and Tierce: a reedy solo voice from flue pipes", reg({{"rohrflute8", 0.8}, {"flute4", 0.6}, {"nazard", 0.5}, {"tierce", 0.4}, {"bourdon16", 0.5}})},
        {"Bach plenum", "A bright principal chorus with the Fourniture, for counterpoint, the hall a little closer", reg({{"principal8", 1}, {"octave4", 0.8}, {"fifteenth2", 0.7}, {"mixture", 0.6}, {"ped_principal16", 0.8}, {"ped_principal8", 0.6}, {"space", 0.35}})},
        {"Flute with tremulant", "The Choir's Concert Flute with its tremulant, for a warm, vocal line", reg({{"concert_flute8", 0.9}, {"tremulant", 0.5}, {"bourdon16", 0.5}})},
        {"Deep pedal", "The Contre Bourdon 32', Principal 16' and Bourdon 16' on every key: the floor shaking", reg({{"subbass32", 1}, {"ped_principal16", 0.8}, {"bourdon16", 0.9}, {"pedal", 1.0}})},
        {"Loft (close)", "The default chorus heard from the organ loft: much less of the hall", reg({{"principal8", 1}, {"octave4", 0.7}, {"rohrflute8", 0.5}, {"bourdon16", 0.6}, {"space", 0.15}})},
        {"Dry organ", "The default chorus with no hall, for your own reverb", reg({{"principal8", 1}, {"octave4", 0.7}, {"rohrflute8", 0.5}, {"bourdon16", 0.6}, {"space", 0.0}})},
        {"Chimes over strings", "The Chimes over the Choir's Violin and Violoncello and the Swell's Viole Céleste", reg({{"chimes", 1}, {"violin8", 0.7}, {"cello8", 0.7}, {"gamba8", 0.5}, {"contrabass16", 0.6}})},
        {"String orchestra", "The orchestral strings as pipes: Violin, Violoncello and the Pedal's Contrabass, with the celestes", reg({{"violin8", 0.9}, {"cello8", 0.8}, {"gamba8", 0.6}, {"erzahler8", 0.5}, {"contrabass16", 0.8}, {"pedal", 1.0}})},
        {"Wall of sound", "The full organ with every 32' and the Quint's resultant, the floor at full Weight", reg({{"subprincipal16", 0.8}, {"principal8", 1}, {"flute_harm8", 0.7}, {"octave4", 1}, {"fifteenth2", 0.9}, {"mixture", 0.9}, {"trumpet8", 0.9}, {"geigen8", 0.9}, {"rohrflute8", 0.6}, {"flute4", 0.6}, {"plein_jeu", 0.8}, {"trompette8", 0.9}, {"concert_flute8", 0.6}, {"subbass32", 1}, {"ped_principal16", 1}, {"bourdon16", 0.9}, {"ped_principal8", 0.8}, {"trombone16", 0.9}, {"bombarde32", 0.9}, {"contrabass16", 0.8}, {"quint10", 0.7}, {"choral_bass4", 0.7}, {"weight", 1.0}})},
        {"Voix Humaine", "The Swell's Voix Humaine with the tremulant over its Gedeckt: the organ's singing voice", reg({{"voix_humaine8", 1}, {"rohrflute8", 0.6}, {"tremulant", 0.5}, {"bourdon16", 0.5}})},
        {"Drunken organ", "A living, unsteady wind and a slow tremulant: a haunted, wavering organ", reg({{"geigen8", 0.8}, {"gamba8", 0.6}, {"bourdon16", 0.5}, {"wind", 1}, {"tremulant", 0.6}, {"trem_rate", 3.5}})},
    };
    return id == kBitternId ? &p : nullptr;
}

size_t bitternTableBytes() noexcept { return tableBytes(); }

}  // namespace caw::bittern
