// Woodpecker (org.caw.woodpecker): each instrument's descriptor (its own knobs) and class as a variant of one merged device, its presets, registration and sizes.
#include "builtin_woodpecker.h"

#include <deque>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "presets.h"
#include "timber_core.h"
#include "woodpecker_bars.h"

namespace caw::woodpecker {
namespace {

using timber::Instrument;

constexpr std::string_view kName = "Woodpecker";
constexpr std::string_view kNames[] = {"Marimba", "Xylophone", "Glockenspiel", "Vibraphone", "Tubular bells", "Timpani"};
constexpr uint32_t kCount = sizeof(kNames) / sizeof(kNames[0]);
static_assert(kCount == kInstruments);

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

// Each instrument's own knobs, as Bars::P (the rest held at their neutral values): every one has the mallet, the
// decay, the attack's level and the tier; the bars with tubes the resonator; the vibraphone its motor and pedal, the
// chimes their damper pedal.
using P = Bars::P;
constexpr uint32_t kOwnCount[kInstruments] = {5, 5, 4, 8, 5, 4};
constexpr P kOwn[kInstruments][8] = {
    {P::kHardness, P::kDecay, P::kAttack, P::kTier, P::kResonator},
    {P::kHardness, P::kDecay, P::kAttack, P::kTier, P::kResonator},
    {P::kHardness, P::kDecay, P::kAttack, P::kTier},
    {P::kHardness, P::kDecay, P::kAttack, P::kTier, P::kResonator, P::kSustain, P::kMotor, P::kMotorDepth},
    {P::kHardness, P::kDecay, P::kAttack, P::kTier, P::kSustain},
    {P::kHardness, P::kDecay, P::kAttack, P::kTier},
};
constexpr double kNeutral[Bars::kAll] = {0.5, 1.0, 1.0, 0.0, 0.0, 0.0, 0.0, 0.0};

template <int I>
struct At : Bars {
    static constexpr uint32_t kModelParams = kOwnCount[I];
    At() { which = I; }
    void control(const double* p, const Shared& s) noexcept {
        double q[Bars::kAll];
        for (uint32_t k = 0; k < Bars::kAll; ++k) q[k] = kNeutral[k];
        for (uint32_t k = 0; k < kModelParams; ++k) q[kOwn[I][k]] = p[k];
        Bars::control(q, s);
    }
};

constexpr std::string_view kTiers[] = {"Setting", "Eco", "Normal", "High"};

const ModuleDescriptor& descriptorFor(uint32_t index) {
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
    // Timber's shared knobs (timber_core.h reads them by index). Dry by default (Space 0); Body 0.5 is the bar as
    // recorded; Release is how fast a damper stops a released note (the vibraphone's and the chimes').
    t.num("tone", "Tone", 0.0, -1.0, 1.0).group = "shared";
    t.num("body", "Body", 0.5, 0.0, 1.0).group = "shared";
    t.num("space", "Space", 0.0, 0.0, 1.0).group = "shared";
    t.num("velocity", "Velocity", 0.8, 0.0, 1.0).group = "shared";
    t.expo("release", "Release", 0.2, 0.005, 10.0, "s").group = "shared";
    ParameterDescriptor& v = t.num("voices", "Voices", 24.0, 1.0, 32.0);
    v.step = 1.0, v.smoothingFrames = 0, v.group = "shared";
    t.num("level", "Level", 0.0, -48.0, 12.0, "dB").group = "shared";
    // The defaults: each instrument's recorded mallet (the vibraphone's yarn, the xylophone's medium).
    const Layout& lay = kLayouts[index];
    const double hardness = index == kXylophone ? lay.hardness[1] : lay.hardness[0];
    for (uint32_t k = 0; k < kOwnCount[index]; ++k) {
        switch (kOwn[index][k]) {
            case P::kHardness: t.num("hardness", index == kTimpani ? "Stick" : "Mallet hardness", hardness, 0.0, 1.0).group = "mallets"; break;
            case P::kDecay: t.expo("decay", "Decay", 1.0, 0.25, 4.0, "x").group = "mallets"; break;
            case P::kAttack: t.num("attack", "Attack level", 1.0, 0.0, 1.0).group = "mallets"; break;
            case P::kTier: {
                ParameterDescriptor& tier = t.pick("tier", "Quality", 0.0, kTiers);
                tier.group = "mallets", tier.automatable = false, tier.modulatable = false;
                break;
            }
            case P::kResonator: t.num("resonator", "Resonator", 1.0, 0.0, 1.0).group = "mallets"; break;
            case P::kSustain: t.num("sustain", "Damper pedal", 0.0, 0.0, 1.0).group = "mallets"; break;
            case P::kMotor: t.num("motor", "Motor rate", 0.0, 0.0, 8.0, "Hz").group = "mallets"; break;
            case P::kMotorDepth: t.num("motor_depth", "Motor depth", 0.6, 0.0, 1.0).group = "mallets"; break;
            default: break;
        }
    }
    b.params.assign(t.data(), t.data() + t.size());
    ParameterDescriptor model = fx::variantParameter(kNames, index);
    model.name = "Instrument";
    b.params.push_back(model);
    ModuleDescriptor& m = b.desc;
    m.id = kWoodpeckerId;
    m.name = kName;
    m.role = ModuleRole::Instrument;
    m.ports = kPorts;
    m.portCount = 2;
    m.parameters = b.params.data();
    m.parameterCount = static_cast<uint32_t>(b.params.size());
    m.tailFrames = 192000 * (index == kChimes ? 46 : (index == kVibraphone ? 31 : 26));  // the longest mode's T60; it says quiet() sooner
    m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the damper pedal (CC 64)
    m.cpuClass = CpuClass::Medium;
    return m;
}
template <uint32_t I>
const ModuleDescriptor& descriptor() {
    static const ModuleDescriptor& d = descriptorFor(I);
    return d;
}

template <int I>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) Instrument<At<I>>(descriptor<I>(), I);
}

const fx::Variant kVariants[] = {
    {kNames[0], &descriptor<0>, &make<0>}, {kNames[1], &descriptor<1>, &make<1>}, {kNames[2], &descriptor<2>, &make<2>},
    {kNames[3], &descriptor<3>, &make<3>}, {kNames[4], &descriptor<4>, &make<4>}, {kNames[5], &descriptor<5>, &make<5>},
};
static_assert(sizeof(kVariants) / sizeof(kVariants[0]) == kCount);
const fx::MergedDevice kDevices[] = {{kWoodpeckerId, kName, kVariants}};

using V = std::vector<std::pair<std::string_view, double>>;
V with(double variant, V v) {
    v.emplace_back("variant", variant);
    return v;
}

template <int I>
Bars* modelAt(ModuleProcessor& p) noexcept {
    auto* i = dynamic_cast<Instrument<At<I>>*>(&p);
    return i ? &i->model() : nullptr;
}
template <int I>
size_t bytesAt(ModuleProcessor& p) noexcept {
    auto* i = dynamic_cast<Instrument<At<I>>*>(&p);
    return i ? i->bytes() : 0;
}

}  // namespace

std::span<const fx::MergedDevice> mergedWoodpeckerDevices() { return kDevices; }

void registerWoodpecker(ModuleRegistry& registry) { registry.replaceBuiltin(descriptor<0>(), kVariants[0].create); }

const std::vector<BuiltinPreset>* woodpeckerPresets(std::string_view id) {
    static const std::vector<BuiltinPreset> p = {
        {"Concert marimba", "Marimba: the recorded rosewood bars and their tubes, close and dry", with(kMarimba, {})},
        {"Soft marimba", "Marimba: yarn mallets, warm and round, for ballads and film", with(kMarimba, {{"hardness", 0.15}})},
        {"Marimba in a hall", "Marimba: a little room and a longer ring", with(kMarimba, {{"space", 0.3}, {"decay", 1.4}})},
        {"Xylophone", "Xylophone: medium mallets, bright and dry", with(kXylophone, {})},
        {"Hard xylophone", "Xylophone: hard mallets that crack, for cartoons and orchestral runs", with(kXylophone, {{"hardness", 0.85}})},
        {"Glockenspiel", "Glockenspiel: brass mallets on steel bars, ringing", with(kGlockenspiel, {})},
        {"Music box glock", "Glockenspiel: soft and short, like a music box", with(kGlockenspiel, {{"hardness", 0.3}, {"decay", 0.5}})},
        {"Vibraphone", "Vibraphone: yarn mallets, damped as you let go (hold the pedal by CC 64)", with(kVibraphone, {})},
        {"Vibes with motor", "Vibraphone: the motor on, a slow shimmer, pedal down", with(kVibraphone, {{"motor", 4.5}, {"sustain", 1.0}})},
        {"Hard vibes", "Vibraphone: hard mallets, a bell-like attack, for jazz solos", with(kVibraphone, {{"hardness", 0.75}})},
        {"Tubular bells", "Tubular bells: the hammer on brass chimes, ringing out", with(kChimes, {{"sustain", 1.0}})},
        {"Bells, damped", "Tubular bells: damped as you let go", with(kChimes, {})},
        {"Timpani", "Timpani: felt sticks on the kettle drums", with(kTimpani, {})},
        {"Timpani, hard sticks", "Timpani: hard sticks for a sharp, articulate roll", with(kTimpani, {{"hardness", 0.8}})},
        {"Light mallets (Eco)", "Marimba at Eco: fewer modes for less CPU, for big projects on a phone", with(kMarimba, {{"tier", 1}})},
    };
    return id == kWoodpeckerId ? &p : nullptr;
}

size_t woodpeckerBytes(uint32_t variant, double sampleRate) noexcept {
    if (variant >= kCount) return 0;
    std::unique_ptr<ModuleProcessor> p(kVariants[variant].create());
    if (!p || !p->activate(sampleRate, 64)) return 0;
    switch (variant) {  // each variant is its own class (its own knob count)
        case 0: return bytesAt<0>(*p);
        case 1: return bytesAt<1>(*p);
        case 2: return bytesAt<2>(*p);
        case 3: return bytesAt<3>(*p);
        case 4: return bytesAt<4>(*p);
        default: return bytesAt<5>(*p);
    }
}

Bars* woodpeckerModel(ModuleProcessor& p, uint32_t variant) noexcept {
    switch (variant) {
        case 0: return modelAt<0>(p);
        case 1: return modelAt<1>(p);
        case 2: return modelAt<2>(p);
        case 3: return modelAt<3>(p);
        case 4: return modelAt<4>(p);
        case 5: return modelAt<5>(p);
        default: return nullptr;
    }
}

}  // namespace caw::woodpecker
