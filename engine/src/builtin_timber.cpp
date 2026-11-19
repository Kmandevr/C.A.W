// Timber (org.caw.timber): each model's descriptor and class as a variant of one merged device, registration and sizes.
#include "builtin_timber.h"

#include <deque>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "presets.h"
#include "timber_core.h"
#include "timber_piano.h"

namespace caw::timber {
namespace {

constexpr std::string_view kName = "Timber";
constexpr std::string_view kModels[] = {"Piano"};
constexpr uint32_t kModelCount = sizeof(kModels) / sizeof(kModels[0]);

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

// The knobs every model shares, first in its descriptor.
void sharedParams(fx::ParamTable& t, double voices, double maxVoices, double release, double body, double space) {
    t.num("tone", "Tone", 0.0, -1.0, 1.0).group = "shared";
    t.num("body", "Body", body, 0.0, 1.0).group = "shared";
    t.num("space", "Space", space, 0.0, 1.0).group = "shared";
    t.num("velocity", "Velocity", 0.8, 0.0, 1.0).group = "shared";
    t.expo("release", "Release", release, 0.02, 10.0, "s").group = "shared";
    ParameterDescriptor& v = t.num("voices", "Voices", voices, 1.0, maxVoices);
    v.step = 1.0, v.smoothingFrames = 0, v.group = "shared";
    t.num("level", "Level", 0.0, -48.0, 12.0, "dB").group = "shared";
}

// A model's descriptor: shared knobs, its own (`own` fills them), then `variant` ("Model").
template <class M>
const ModuleDescriptor& modelDescriptor(uint32_t index, double release, double body, double space, CpuClass cpu,
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
    sharedParams(b.table, M::kNormalCap, M::kHighCap, release, body, space);
    own(b.table);
    b.params.assign(b.table.data(), b.table.data() + b.table.size());
    ParameterDescriptor model = fx::variantParameter(kModels, index);
    model.name = "Model";
    b.params.push_back(model);
    ModuleDescriptor& m = b.desc;
    m.id = kTimberId;
    m.name = kName;
    m.role = ModuleRole::Instrument;
    m.ports = kPorts;
    m.portCount = 2;
    m.parameters = b.params.data();
    m.parameterCount = static_cast<uint32_t>(b.params.size());
    m.tailFrames = 192000 * 40;  // a 30 s bass string at 192 kHz and the room; it says quiet() sooner
    m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the sustain pedal and the mod wheel
    m.cpuClass = cpu;
    return m;
}

// ---------- Piano ----------
constexpr std::string_view kCharacters[] = {"Grand", "Upright", "Felt"};
void pianoParams(fx::ParamTable& t) {
    t.num("hammer", "Hammer", 0.5, 0.0, 1.0).group = "piano";
    t.pick("character", "Character", 0.0, kCharacters).group = "piano";
    t.num("unison", "Unison detune", 1.0, 0.0, 6.0, "ct").group = "piano";
    t.num("stretch", "Stretch", 1.0, 0.0, 2.0).group = "piano";
    t.expo("decay", "Decay", 1.0, 0.25, 4.0, "x").group = "piano";
    t.num("sustain", "Sustain pedal", 0.0, 0.0, 1.0).group = "piano";
    t.num("soft", "Soft pedal", 0.0, 0.0, 1.0).group = "piano";
    t.num("resonance", "Resonance", 0.3, 0.0, 1.0).group = "piano";
}
const ModuleDescriptor& pianoDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<Piano>(0, 0.25, 0.75, 0.15, CpuClass::Heavy, &pianoParams);
    return d;
}
static_assert(Piano::kModelParams == 8);

template <class M, const ModuleDescriptor& (*D)(), int Index>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) Instrument<M>(D(), Index);
}

const fx::Variant kVariants[] = {
    {kModels[0], &pianoDescriptor, &make<Piano, &pianoDescriptor, 0>},
};
static_assert(sizeof(kVariants) / sizeof(kVariants[0]) == kModelCount);
const fx::MergedDevice kDevices[] = {{kTimberId, kName, kVariants}};

}  // namespace

std::span<const fx::MergedDevice> mergedTimberDevices() { return kDevices; }

void registerTimber(ModuleRegistry& registry) {
    (void)tables();  // built here, so no voice ever builds them
    registry.replaceBuiltin(pianoDescriptor(), kVariants[0].create);
}

size_t timberBytes(uint32_t variant, double sampleRate) noexcept {
    if (variant >= kModelCount) return 0;
    std::unique_ptr<ModuleProcessor> p(kVariants[variant].create());
    if (!p || !p->activate(sampleRate, 64)) return 0;
    switch (variant) {
        case 0: return static_cast<Instrument<Piano>&>(*p).bytes();
        default: return 0;
    }
}
size_t timberTableBytes() noexcept { return sizeof(Tables); }

}  // namespace caw::timber
