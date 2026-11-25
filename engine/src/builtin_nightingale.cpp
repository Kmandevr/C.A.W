// Nightingale (org.caw.nightingale): each instrument's descriptor and class as a variant of one merged device, its presets, registration and sizes.
#include "builtin_nightingale.h"

#include <deque>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "nightingale_bowed.h"
#include "presets.h"
#include "instrument_core.h"

namespace caw::nightingale {
namespace {

using timber::Instrument;

constexpr std::string_view kName = "Nightingale";
constexpr std::string_view kInstruments[] = {"Violin", "Viola", "Cello", "Bass"};
constexpr uint32_t kCount = sizeof(kInstruments) / sizeof(kInstruments[0]);

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

constexpr std::string_view kTiers[] = {"Setting", "Eco", "Normal", "High"};

// Each instrument is the bowed string with its own section (its body, its bridge loss).
template <int I>
struct At : Bowed {
    At() { instrument = I; }
};

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
    // Timber's shared knobs (instrument_core.h reads them by index). Dry by default; Body 1 is the recorded body.
    t.num("tone", "Tone", 0.0, -1.0, 1.0).group = "shared";
    t.num("body", "Body", 1.0, 0.0, 1.0).group = "shared";
    t.num("space", "Space", 0.0, 0.0, 1.0).group = "shared";
    t.num("velocity", "Velocity", 0.8, 0.0, 1.0).group = "shared";
    t.expo("release", "Release", 0.25, 0.005, 10.0, "s").group = "shared";
    ParameterDescriptor& v = t.num("voices", "Voices", 8.0, 1.0, 8.0);
    v.step = 1.0, v.smoothingFrames = 0, v.group = "shared";
    t.num("level", "Level", 0.0, -48.0, 12.0, "dB").group = "shared";
    // In Bowed::P's order.
    t.num("pressure", "Bow pressure", 0.5, 0.0, 1.0).group = "bow";
    t.num("speed", "Bow speed", 0.5, 0.0, 1.0).group = "bow";
    t.num("position", "Bow position", 0.5, 0.0, 1.0).group = "bow";  // 0 at the bridge .. 1 over the fingerboard
    t.num("vibrato", "Vibrato", 0.3, 0.0, 1.0).group = "bow";
    t.expo("vib_rate", "Vibrato rate", 5.5, 2.0, 9.0, "Hz").group = "bow";
    t.expo("attack", "Attack", 0.12, 0.005, 2.0, "s").group = "bow";
    t.num("noise", "Bow noise", 0.35, 0.0, 1.0).group = "bow";
    ParameterDescriptor& tier = t.pick("tier", "Quality", 0.0, kTiers);
    tier.group = "bow", tier.automatable = false, tier.modulatable = false;
    b.params.assign(t.data(), t.data() + t.size());
    ParameterDescriptor model = fx::variantParameter(kInstruments, index);
    model.name = "Instrument";
    b.params.push_back(model);
    ModuleDescriptor& m = b.desc;
    m.id = kNightingaleId;
    m.name = kName;
    m.role = ModuleRole::Instrument;
    m.ports = kPorts;
    m.portCount = 2;
    m.parameters = b.params.data();
    m.parameterCount = static_cast<uint32_t>(b.params.size());
    m.tailFrames = 192000 * 4;
    m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the mod wheel (expression)
    m.cpuClass = CpuClass::Medium;
    return m;
}
template <uint32_t I>
const ModuleDescriptor& descriptor() {
    static const ModuleDescriptor& d = descriptorFor(I);
    return d;
}
static_assert(Bowed::kModelParams == 8);

template <int I>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) Instrument<At<I>>(descriptor<I>(), I);
}

const fx::Variant kVariants[] = {
    {kInstruments[0], &descriptor<0>, &make<0>},
    {kInstruments[1], &descriptor<1>, &make<1>},
    {kInstruments[2], &descriptor<2>, &make<2>},
    {kInstruments[3], &descriptor<3>, &make<3>},
};
const fx::MergedDevice kDevices[] = {{kNightingaleId, kName, kVariants}};

using V = std::vector<std::pair<std::string_view, double>>;
V with(double variant, V v) {
    v.emplace_back("variant", variant);
    return v;
}

}  // namespace

std::span<const fx::MergedDevice> mergedNightingaleDevices() { return kDevices; }

void registerNightingale(ModuleRegistry& registry) { registry.replaceBuiltin(descriptor<0>(), kVariants[0].create); }

const std::vector<BuiltinPreset>* nightingalePresets(std::string_view id) {
    static const std::vector<BuiltinPreset> p = {
        {"Solo violin", "Violin: a solo player, expressive vibrato, close and dry", with(0, {})},
        {"Violin, legato lines", "Violin: a slower bow and a gentle attack for long singing lines", with(0, {{"attack", 0.25}, {"speed", 0.4}, {"vibrato", 0.4}})},
        {"Violin, dig in", "Violin: more pressure near the bridge, a bright and biting tone", with(0, {{"pressure", 0.8}, {"position", 0.3}, {"attack", 0.04}})},
        {"Violin, flautando", "Violin: light and airy over the fingerboard", with(0, {{"pressure", 0.15}, {"position", 0.85}, {"vibrato", 0.2}})},
        {"Violin, sul ponticello", "Violin: glassy and eerie at the bridge", with(0, {{"position", 0.05}, {"pressure", 0.6}, {"vibrato", 0.1}})},
        {"Solo viola", "Viola: darker and warmer than the violin", with(1, {})},
        {"Viola, warm pad", "Viola: soft bow and slow attack, for held harmony", with(1, {{"attack", 0.4}, {"pressure", 0.35}, {"vibrato", 0.35}})},
        {"Solo cello", "Cello: a singing solo cello", with(2, {})},
        {"Cello, film swell", "Cello: a slow bow that swells in, for cinematic lines", with(2, {{"attack", 0.6}, {"speed", 0.55}, {"vibrato", 0.4}})},
        {"Cello, gritty", "Cello: pressed hard near the bridge, rosin and grit", with(2, {{"pressure", 0.85}, {"position", 0.25}, {"noise", 0.6}})},
        {"Double bass", "Bass: a bowed double bass, deep and woody", with(3, {})},
        {"Bass, drone", "Bass: a long, even bow for drones and pedal notes", with(3, {{"attack", 0.5}, {"vibrato", 0.1}, {"speed", 0.45}})},
    };
    return id == kNightingaleId ? &p : nullptr;
}

size_t nightingaleBytes(uint32_t variant, double sampleRate) noexcept {
    if (variant >= kCount) return 0;
    std::unique_ptr<ModuleProcessor> p(kVariants[variant].create());
    if (!p || !p->activate(sampleRate, 64)) return 0;
    switch (variant) {
        case 0: return static_cast<Instrument<At<0>>&>(*p).bytes();
        case 1: return static_cast<Instrument<At<1>>&>(*p).bytes();
        case 2: return static_cast<Instrument<At<2>>&>(*p).bytes();
        default: return static_cast<Instrument<At<3>>&>(*p).bytes();
    }
}

Bowed* nightingaleModelOf(ModuleProcessor& p) noexcept {
    if (auto* q = dynamic_cast<Instrument<At<0>>*>(&p)) return &q->model();
    if (auto* q = dynamic_cast<Instrument<At<1>>*>(&p)) return &q->model();
    if (auto* q = dynamic_cast<Instrument<At<2>>*>(&p)) return &q->model();
    if (auto* q = dynamic_cast<Instrument<At<3>>*>(&p)) return &q->model();
    return nullptr;
}

}  // namespace caw::nightingale
