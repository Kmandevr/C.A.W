// Bittern (org.caw.bittern): the pipe organ's descriptor (its stops as levels), presets (registrations), registration and sizes.
#include "builtin_bittern.h"

#include <memory>
#include <new>
#include <vector>

#include "bittern_organ.h"
#include "builtin_effects.h"
#include "presets.h"
#include "timber_core.h"

namespace caw::bittern {
namespace {

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

// The stops in Stop's order, their labels and default registration (a principal chorus on a 16' Bourdon).
struct StopInfo {
    const char* id;
    const char* name;
    double initial;
};
constexpr StopInfo kStopInfo[kStops] = {
    {"bourdon16", "Bourdon 16'", 0.6}, {"principal8", "Principal 8'", 1.0}, {"rohrflute8", "Rohrflöte 8'", 0.5},
    {"gamba8", "Gamba 8'", 0.0},       {"celeste8", "Voix céleste 8'", 0.0}, {"octave4", "Octave 4'", 0.7},
    {"flute4", "Flute 4'", 0.0},       {"nazard", "Nazard 2 2/3'", 0.0},   {"fifteenth2", "Fifteenth 2'", 0.0},
    {"tierce", "Tierce 1 3/5'", 0.0},  {"mixture", "Mixture IV", 0.0},     {"trumpet8", "Trumpet 8'", 0.0},
    {"subbass32", "Subbass 32'", 0.0},
};

const ModuleDescriptor& descriptor() {
    static fx::ParamTable t;
    static std::vector<ParameterDescriptor> params;
    static ModuleDescriptor m;
    static const bool built = [] {
        // Timber's shared knobs (timber_core.h reads them by index). The room is on: Space 0.45, a cathedral (owner,
        // 2026-11-24: the organ is the one realistic instrument that is not dry).
        t.num("tone", "Tone", 0.0, -1.0, 1.0).group = "shared";
        t.num("body", "Body", 0.5, 0.0, 1.0).group = "shared";
        t.num("space", "Space", 0.45, 0.0, 1.0).group = "shared";
        t.num("velocity", "Velocity", 0.3, 0.0, 1.0).group = "shared";  // an organ barely follows the key's speed
        t.expo("release", "Release", 0.12, 0.005, 10.0, "s").group = "shared";
        ParameterDescriptor& v = t.num("voices", "Voices", 16.0, 1.0, 24.0);
        v.step = 1.0, v.smoothingFrames = 0, v.group = "shared";
        t.num("level", "Level", 0.0, -48.0, 12.0, "dB").group = "shared";
        for (const StopInfo& s : kStopInfo) t.num(s.id, s.name, s.initial, 0.0, 1.0).group = "stops";
        t.num("tremulant", "Tremulant", 0.0, 0.0, 1.0).group = "wind";
        t.num("wind", "Living wind", 0.3, 0.0, 1.0).group = "wind";
        t.num("chiff", "Chiff", 0.5, 0.0, 1.0).group = "wind";
        t.expo("trem_rate", "Tremulant rate", 5.5, 2.0, 9.0, "Hz").group = "wind";
        params.assign(t.data(), t.data() + t.size());
        m.id = kBitternId;
        m.name = "Bittern";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        m.parameters = params.data();
        m.parameterCount = static_cast<uint32_t>(params.size());
        m.tailFrames = 192000 * 12;  // the cathedral's tail
        m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the mod wheel: the swell box
        m.cpuClass = CpuClass::Heavy;
        return true;
    }();
    (void)built;
    return m;
}
static_assert(Organ::kModelParams == kStops + 4);

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
        {"Cathedral principal chorus", "Principals 8' and 4' on a 16' Bourdon, in the cathedral", reg({{"bourdon16", 0.6}, {"principal8", 1}, {"rohrflute8", 0.5}, {"octave4", 0.7}})},
        {"Full organ", "Everything out: principals, mixture, trumpet and the 32' in the pedal, for the big finish", reg({{"bourdon16", 0.8}, {"principal8", 1}, {"octave4", 0.8}, {"fifteenth2", 0.7}, {"mixture", 0.7}, {"trumpet8", 0.8}, {"subbass32", 0.8}})},
        {"Bach plenum", "A bright principal chorus with the mixture, for counterpoint", reg({{"principal8", 1}, {"octave4", 0.8}, {"fifteenth2", 0.7}, {"mixture", 0.6}, {"space", 0.35}})},
        {"Soft flutes", "Rohrflöte 8' and Flute 4', gentle, for quiet accompaniment", reg({{"rohrflute8", 0.8}, {"flute4", 0.5}, {"chiff", 0.6}})},
        {"Strings and celeste", "Gamba with its celeste, a slow shimmer for pads", reg({{"gamba8", 0.8}, {"celeste8", 0.8}, {"space", 0.5}})},
        {"Cornet", "The flute mutations: a reedy solo voice from flue pipes", reg({{"rohrflute8", 0.8}, {"flute4", 0.6}, {"nazard", 0.5}, {"fifteenth2", 0.4}, {"tierce", 0.4}})},
        {"Trumpet solo", "The trumpet over a soft flute, for fanfares", reg({{"trumpet8", 1}, {"rohrflute8", 0.4}})},
        {"Flute with tremulant", "A flute with the tremulant, for a warm, vocal line", reg({{"rohrflute8", 0.9}, {"tremulant", 0.5}})},
        {"Deep pedal", "Bourdon 16' and Subbass 32': the floor shaking under everything", reg({{"bourdon16", 0.9}, {"subbass32", 1}, {"principal8", 0.4}})},
        {"Loft (close)", "The principal chorus heard from the organ loft: much less room", reg({{"bourdon16", 0.6}, {"principal8", 1}, {"rohrflute8", 0.5}, {"octave4", 0.7}, {"space", 0.15}})},
        {"Dry organ", "The principal chorus with no room, for your own reverb", reg({{"bourdon16", 0.6}, {"principal8", 1}, {"rohrflute8", 0.5}, {"octave4", 0.7}, {"space", 0.0}})},
        {"Drunken organ", "A living, unsteady wind and a slow tremulant: a haunted, wavering organ", reg({{"principal8", 0.8}, {"gamba8", 0.6}, {"wind", 1}, {"tremulant", 0.4}, {"trem_rate", 3.0}})},
    };
    return id == kBitternId ? &p : nullptr;
}

size_t bitternTableBytes() noexcept { return tableBytes(); }

}  // namespace caw::bittern
