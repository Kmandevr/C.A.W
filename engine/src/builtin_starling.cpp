// Starling (org.caw.starling): each model's descriptor and class as a variant of one merged device, its presets, registration and sizes.
#include "builtin_starling.h"

#include <deque>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "presets.h"
#include "starling_piano.h"
#include "instrument_core.h"

namespace caw::starling {
namespace {

using timber::Instrument;

constexpr std::string_view kName = "Starling";
constexpr std::string_view kModels[] = {"Piano"};
constexpr uint32_t kModelCount = sizeof(kModels) / sizeof(kModels[0]);

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

// The shared knobs, first in every model's descriptor, in Timber's order (instrument_core.h reads them by index).
// Dry by default (owner, 2026-11-24): Space 0, the room is the user's own effect.
void sharedParams(fx::ParamTable& t, double voices, double maxVoices, double release, double body) {
    t.num("tone", "Tone", 0.0, -1.0, 1.0).group = "shared";
    t.num("body", "Body", body, 0.0, 1.0).group = "shared";
    t.num("space", "Space", 0.0, 0.0, 1.0).group = "shared";
    t.num("velocity", "Velocity", 0.8, 0.0, 1.0).group = "shared";
    t.expo("release", "Release", release, 0.005, 10.0, "s").group = "shared";
    ParameterDescriptor& v = t.num("voices", "Voices", voices, 1.0, maxVoices);
    v.step = 1.0, v.smoothingFrames = 0, v.group = "shared";
    t.num("level", "Level", 0.0, -48.0, 12.0, "dB").group = "shared";
}

template <class M>
const ModuleDescriptor& modelDescriptor(uint32_t index, double release, double body, CpuClass cpu,
                                        void (*own)(fx::ParamTable&)) {
    struct Built {
        fx::ParamTable table;
        std::vector<ParameterDescriptor> params;
        ModuleDescriptor desc;
    };
    static std::deque<Built> store;
    static std::mutex guard;
    const std::lock_guard<std::mutex> lock(guard);
    Built& b = store.emplace_back();
    sharedParams(b.table, M::kNormalCap, M::kHighCap, release, body);
    own(b.table);
    b.params.assign(b.table.data(), b.table.data() + b.table.size());
    ParameterDescriptor model = fx::variantParameter(kModels, index);
    model.name = "Model";
    b.params.push_back(model);
    ModuleDescriptor& m = b.desc;
    m.id = kStarlingId;
    m.name = kName;
    m.role = ModuleRole::Instrument;
    m.ports = kPorts;
    m.portCount = 2;
    m.parameters = b.params.data();
    m.parameterCount = static_cast<uint32_t>(b.params.size());
    m.tailFrames = 192000 * 40;  // a 30 s bass string at 192 kHz; it says quiet() sooner
    m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the sustain pedal
    m.cpuClass = cpu;
    return m;
}

// ---------- Piano ----------
constexpr std::string_view kCharacters[] = {"Grand", "Upright", "Felt"};
constexpr std::string_view kTiers[] = {"Setting", "Eco", "Normal", "High"};
constexpr std::string_view kOffOn[] = {"Off", "On"};
// In PianoModel::P's order (starling_piano.h).
void pianoParams(fx::ParamTable& t) {
    t.num("hammer", "Hammer", 0.5, 0.0, 1.0).group = "piano";
    t.pick("character", "Character", 0.0, kCharacters).group = "piano";
    t.num("unison", "Unison detune", 1.0, 0.0, 6.0, "ct").group = "piano";
    t.num("stretch", "Stretch", 1.0, 0.0, 2.0).group = "piano";  // 1: the Salamander Grand's own tuning
    t.expo("decay", "Decay", 1.0, 0.25, 4.0, "x").group = "piano";
    t.num("sustain", "Sustain pedal", 0.0, 0.0, 1.0).group = "piano";
    t.num("soft", "Soft pedal", 0.0, 0.0, 1.0).group = "piano";
    t.num("resonance", "Resonance", 0.3, 0.0, 1.0).group = "piano";
    ParameterDescriptor& tier = t.pick("tier", "Quality", 0.0, kTiers);
    tier.group = "piano", tier.automatable = false, tier.modulatable = false;
    t.num("noise", "Noise", 0.35, 0.0, 1.0).group = "piano";  // key-release, pedal and damper noises: 0.35 as recorded
    t.num("touch", "Touch", 0.0, 0.0, 1.0).group = "piano";
    t.pick("action", "Action delay", 0.0, kOffOn).group = "piano";
    t.num("glide", "Pitch glide", 0.5, 0.0, 1.0).group = "piano";
    t.num("sympathy", "Sympathy", 0.5, 0.0, 1.0).group = "piano";
    t.num("phantom", "Phantom partials", 0.5, 0.0, 1.0).group = "piano";  // High only
}
const ModuleDescriptor& pianoDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<PianoModel>(0, 0.25, 0.75, CpuClass::Heavy, &pianoParams);
    return d;
}

template <class M, const ModuleDescriptor& (*D)(), int Index>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) Instrument<M>(D(), Index);
}

const fx::Variant kVariants[] = {
    {kModels[0], &pianoDescriptor, &make<PianoModel, &pianoDescriptor, 0>},
};
static_assert(sizeof(kVariants) / sizeof(kVariants[0]) == kModelCount);
const fx::MergedDevice kDevices[] = {{kStarlingId, kName, kVariants}};

using V = std::vector<std::pair<std::string_view, double>>;
V with(double variant, V v) {
    v.emplace_back("variant", variant);
    return v;
}

}  // namespace

std::span<const fx::MergedDevice> mergedStarlingDevices() { return kDevices; }

void registerStarling(ModuleRegistry& registry) {
    registry.replaceBuiltin(pianoDescriptor(), kVariants[0].create);
}

const std::vector<BuiltinPreset>* starlingPresets(std::string_view id) {
    static const std::vector<BuiltinPreset> p = {
        // Piano (0): dry and close by default; add the room with Space or your own reverb.
        {"Grand piano", "Piano: the Salamander Grand's own attack and noises on a modelled grand, close and dry", with(0, {})},
        {"Grand, a little room", "Piano: the grand with a small room around it, ready to play", with(0, {{"space", 0.12}})},
        {"Bright pop grand", "Piano: a brighter hammer and tone that cut through a band mix", with(0, {{"hammer", 0.75}, {"tone", 0.2}})},
        {"Warm jazz grand", "Piano: a softer hammer and a light touch, for trio and lounge", with(0, {{"hammer", 0.35}, {"tone", -0.1}, {"touch", 0.4}})},
        {"Close-miked grand", "Piano: the hammers, keys and pedal up front, as heard from inside the lid", with(0, {{"noise", 0.9}, {"body", 0.6}})},
        {"Pedalled ballad", "Piano: rich ringing under the sustain pedal (play the pedal by CC 64)", with(0, {{"resonance", 0.6}, {"sympathy", 0.8}, {"hammer", 0.45}})},
        {"Soft-pedal nocturne", "Piano: una corda and a soft hammer, for quiet, intimate pieces", with(0, {{"soft", 1.0}, {"hammer", 0.3}})},
        {"Upright", "Piano: a home upright, modelled from the strike, for songwriting", with(0, {{"character", 1}})},
        {"Felt piano", "Piano: the felt rail down, soft and dark, for film and lo-fi", with(0, {{"character", 2}, {"hammer", 0.2}, {"noise", 0.6}, {"release", 0.5}})},
        {"Honky-tonk upright", "Piano: an old upright out of tune with itself, for saloon and ragtime", with(0, {{"character", 1}, {"unison", 5.0}, {"hammer", 0.7}})},
        {"Light grand (Eco)", "Piano at Eco: the grand for less CPU, for big projects on a phone", with(0, {{"tier", 1}})},
        {"Grand for export (High)", "Piano at High: more strings' detail and phantom partials, for final renders", with(0, {{"tier", 3}, {"phantom", 0.7}})},
    };
    return id == kStarlingId ? &p : nullptr;
}

size_t starlingBytes(uint32_t variant, double sampleRate) noexcept {
    if (variant >= kModelCount) return 0;
    std::unique_ptr<ModuleProcessor> p(kVariants[variant].create());
    if (!p || !p->activate(sampleRate, 64)) return 0;
    return static_cast<Instrument<PianoModel>&>(*p).bytes();
}

}  // namespace caw::starling
