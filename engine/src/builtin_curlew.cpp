// Curlew (org.caw.curlew): each instrument's descriptor and class as a variant of one merged device, its presets, registration and sizes.
#include "builtin_curlew.h"

#include <deque>
#include <memory>
#include <mutex>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "curlew_winds.h"
#include "presets.h"
#include "instrument_core.h"

namespace caw::curlew {
namespace {

using timber::Instrument;

constexpr std::string_view kName = "Curlew";
constexpr std::string_view kPlay[] = {"Legato", "Poly"};
constexpr std::string_view kInstruments[] = {"Flute", "Clarinet", "Saxophone", "Trumpet", "Trombone", "French horn"};
constexpr uint32_t kCount = sizeof(kInstruments) / sizeof(kInstruments[0]);

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

template <int I>
struct At : Winds {
    At() { which = I; }
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
    t.expo("release", "Release", 0.08, 0.005, 10.0, "s").group = "shared";
    ParameterDescriptor& v = t.num("voices", "Voices", 8.0, 1.0, 8.0);
    v.step = 1.0, v.smoothingFrames = 0, v.group = "shared";
    t.num("level", "Level", 0.0, -48.0, 12.0, "dB").group = "shared";
    // In Winds::P's order.
    t.num("breath", "Breath", 0.6, 0.0, 1.0).group = "winds";
    t.num("noise", "Breath noise", 0.15, 0.0, 1.0).group = "winds";
    t.num("reed", index == 0 ? "Jet" : (index >= 3 ? "Lips" : "Reed"), 0.5, 0.0, 1.0).group = "winds";
    t.num("vibrato", "Vibrato", index == 1 ? 0.0 : 0.2, 0.0, 1.0).group = "winds";  // a clarinet plays straight
    t.expo("vib_rate", "Vibrato rate", 5.0, 2.0, 9.0, "Hz").group = "winds";
    t.num("growl", "Growl", 0.0, 0.0, 1.0).group = "winds";
    t.expo("attack", "Attack", 0.04, 0.005, 2.0, "s").group = "winds";
    t.pick("play", "Play", 0.0, kPlay).group = "winds";  // Legato: one note at a time, slurred
    b.params.assign(t.data(), t.data() + t.size());
    ParameterDescriptor model = fx::variantParameter(kInstruments, index);
    model.name = "Instrument";
    b.params.push_back(model);
    ModuleDescriptor& m = b.desc;
    m.id = kCurlewId;
    m.name = kName;
    m.role = ModuleRole::Instrument;
    m.ports = kPorts;
    m.portCount = 2;
    m.parameters = b.params.data();
    m.parameterCount = static_cast<uint32_t>(b.params.size());
    m.tailFrames = 192000 * 2;
    m.capabilities = kCapabilityNotesIn | kCapabilityMidiIn;  // the mod wheel (expression)
    m.cpuClass = CpuClass::Medium;
    return m;
}
template <uint32_t I>
const ModuleDescriptor& descriptor() {
    static const ModuleDescriptor& d = descriptorFor(I);
    return d;
}
static_assert(Winds::kModelParams == 8);  // breath .. attack, play

template <int I>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) Instrument<At<I>>(descriptor<I>(), I);
}

const fx::Variant kVariants[] = {
    {kInstruments[0], &descriptor<0>, &make<0>}, {kInstruments[1], &descriptor<1>, &make<1>},
    {kInstruments[2], &descriptor<2>, &make<2>}, {kInstruments[3], &descriptor<3>, &make<3>},
    {kInstruments[4], &descriptor<4>, &make<4>}, {kInstruments[5], &descriptor<5>, &make<5>},
};
static_assert(sizeof(kVariants) / sizeof(kVariants[0]) == kCount);
const fx::MergedDevice kDevices[] = {{kCurlewId, kName, kVariants}};

using V = std::vector<std::pair<std::string_view, double>>;
V with(double variant, V v) {
    v.emplace_back("variant", variant);
    return v;
}

}  // namespace

std::span<const fx::MergedDevice> mergedCurlewDevices() { return kDevices; }

void registerCurlew(ModuleRegistry& registry) { registry.replaceBuiltin(descriptor<0>(), kVariants[0].create); }

const std::vector<BuiltinPreset>* curlewPresets(std::string_view id) {
    static const std::vector<BuiltinPreset> p = {
        {"Concert flute", "Flute: a clear, singing flute, close and dry", with(0, {})},
        {"Breathy flute", "Flute: more air in the tone, for film and lo-fi", with(0, {{"noise", 0.45}, {"breath", 0.45}})},
        {"Flute, bright and forward", "Flute: overblown a little, for leads", with(0, {{"breath", 0.85}, {"reed", 0.65}})},
        {"Clarinet", "Clarinet: a woody, straight clarinet", with(1, {})},
        {"Clarinet, soft chalumeau", "Clarinet: dark and soft in the low register", with(1, {{"breath", 0.4}, {"reed", 0.35}})},
        {"Alto sax", "Saxophone: a warm sax with a little vibrato", with(2, {})},
        {"Sax, growl", "Saxophone: pushed hard with a throat growl, for rock and funk", with(2, {{"breath", 0.9}, {"growl", 0.5}, {"reed", 0.7}})},
        {"Trumpet", "Trumpet: a bright, open trumpet", with(3, {})},
        {"Trumpet, soft", "Trumpet: mellow, played gently", with(3, {{"breath", 0.4}, {"reed", 0.35}})},
        {"Trombone", "Trombone: a full, round trombone", with(4, {})},
        {"French horn", "French horn: warm and round, for film", with(5, {})},
        {"Horn swell", "French horn: a slow swell for pads and film", with(5, {{"attack", 0.4}, {"breath", 0.5}})},
    };
    return id == kCurlewId ? &p : nullptr;
}

size_t curlewBytes(uint32_t variant, double sampleRate) noexcept {
    if (variant >= kCount) return 0;
    std::unique_ptr<ModuleProcessor> p(kVariants[variant].create());
    if (!p || !p->activate(sampleRate, 64)) return 0;
    return static_cast<Instrument<At<0>>&>(*p).bytes();  // every variant is the same class but for its body
}

Winds* curlewModelOf(ModuleProcessor& p) noexcept {
    if (auto* q = dynamic_cast<Instrument<At<0>>*>(&p)) return &q->model();
    if (auto* q = dynamic_cast<Instrument<At<1>>*>(&p)) return &q->model();
    if (auto* q = dynamic_cast<Instrument<At<2>>*>(&p)) return &q->model();
    if (auto* q = dynamic_cast<Instrument<At<3>>*>(&p)) return &q->model();
    if (auto* q = dynamic_cast<Instrument<At<4>>*>(&p)) return &q->model();
    if (auto* q = dynamic_cast<Instrument<At<5>>*>(&p)) return &q->model();
    return nullptr;
}

}  // namespace caw::curlew
