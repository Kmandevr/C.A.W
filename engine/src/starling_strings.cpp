// Starling's plucked strings (1.1.3): the classical guitar's and the harp's descriptors (their own knobs), classes and sizes, compiled with strict floating point so every build renders the same bits.
#include <deque>
#include <mutex>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "builtin_starling.h"
#include "starling_strings.h"

namespace caw::starling {
namespace {

using timber::Instrument;

template <int I>
struct At : Strings {
    static constexpr uint32_t kModelParams = Strings::kModelParams;
    static constexpr double kSpread = I == kGuitar ? 0.2 : 0.5;  // a guitar is one source; a harp is wide
    At() { which = I; }
};

constexpr std::string_view kTiers[] = {"Setting", "Eco", "Normal", "High"};

}  // namespace

const ModuleDescriptor& stringsDescriptor(int which, std::span<const std::string_view> models, uint32_t index) {
    struct Built {
        fx::ParamTable table;
        std::vector<ParameterDescriptor> params;
        ModuleDescriptor desc;
    };
    static std::deque<Built> store;
    static std::mutex guard;
    const std::lock_guard<std::mutex> lock(guard);
    Built& b = store.emplace_back();
    fx::ParamTable& t = b.table;
    // Timber's shared knobs (instrument_core.h reads them by index). Dry by default (Space 0); Body 0.5 is the instrument
    // as recorded; Release is how fast a finger stops a released string.
    t.num("tone", "Tone", 0.0, -1.0, 1.0).group = "shared";
    t.num("body", "Body", 0.5, 0.0, 1.0).group = "shared";
    t.num("space", "Space", 0.0, 0.0, 1.0).group = "shared";
    t.num("velocity", "Velocity", 0.8, 0.0, 1.0).group = "shared";
    t.expo("release", "Release", which == kGuitar ? 0.12 : 0.25, 0.005, 10.0, "s").group = "shared";
    ParameterDescriptor& v = t.num("voices", "Voices", Strings::kNormalCap, 1.0, Strings::kHighCap);
    v.step = 1.0, v.smoothingFrames = 0, v.group = "shared";
    t.num("level", "Level", 0.0, -48.0, 12.0, "dB").group = "shared";
    // In Strings::P's order. The defaults are the recordings' own pluck (kRecPosition, kRecHardness).
    const char* g = which == kGuitar ? "guitar" : "harp";
    t.num("position", "Pluck position", kRecPosition[which], 0.04, 0.5).group = g;
    t.num("hardness", which == kGuitar ? "Finger / nail" : "Finger", kRecHardness[which], 0.0, 1.0).group = g;
    t.num("damping", which == kGuitar ? "Palm mute" : "Damping", 0.0, 0.0, 1.0).group = g;
    t.num("noise", "String noise", 0.15, 0.0, 1.0).group = g;  // slides, the finger's touch, fret buzz: quiet
    t.num("sustain", which == kGuitar ? "Sustain pedal" : "Let ring", which == kGuitar ? 0.0 : 1.0, 0.0, 1.0).group = g;
    ParameterDescriptor& tier = t.pick("tier", "Quality", 0.0, kTiers);
    tier.group = g, tier.automatable = false, tier.modulatable = false;
    b.params.assign(t.data(), t.data() + t.size());
    ParameterDescriptor model = fx::variantParameter(models, index);
    model.name = "Model";
    b.params.push_back(model);
    ModuleDescriptor& m = b.desc;
    static constexpr PortDescriptor kPorts[] = {
        {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
        stereoOutput("out"),
    };
    m.id = kStarlingId;
    m.name = "Starling";
    m.role = ModuleRole::Instrument;
    m.ports = kPorts;
    m.portCount = 2;
    m.parameters = b.params.data();
    m.parameterCount = static_cast<uint32_t>(b.params.size());
    m.tailFrames = 192000 * (which == kGuitar ? 12 : 27);  // the longest measured T60 (the harp's bass 25 s); it says quiet() sooner
    m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the sustain pedal (CC 64)
    m.cpuClass = CpuClass::Medium;
    return m;
}

ModuleProcessor* makeStrings(int which, const ModuleDescriptor& d, int index) noexcept {
    if (which == kGuitar) return new (std::nothrow) Instrument<At<kGuitar>>(d, index);
    return new (std::nothrow) Instrument<At<kHarp>>(d, index);
}

Strings* stringsModel(ModuleProcessor& p, int which) noexcept {
    if (which == kGuitar) {
        auto* i = dynamic_cast<Instrument<At<kGuitar>>*>(&p);
        return i ? &i->model() : nullptr;
    }
    auto* i = dynamic_cast<Instrument<At<kHarp>>*>(&p);
    return i ? &i->model() : nullptr;
}

size_t stringsBytes(ModuleProcessor& p, int which) noexcept {
    if (which == kGuitar) {
        auto* i = dynamic_cast<Instrument<At<kGuitar>>*>(&p);
        return i ? i->bytes() : 0;
    }
    auto* i = dynamic_cast<Instrument<At<kHarp>>*>(&p);
    return i ? i->bytes() : 0;
}

}  // namespace caw::starling
