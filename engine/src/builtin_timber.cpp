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
#include "timber_keys.h"
#include "timber_mallet_wind.h"
#include "timber_piano.h"
#include "timber_strings.h"

namespace caw::timber {
namespace {

constexpr std::string_view kName = "Timber";
constexpr std::string_view kModels[] = {"Piano", "Electric piano", "Organ", "Plucked", "Bowed", "Mallets", "Winds"};
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
    t.expo("release", "Release", release, 0.005, 10.0, "s").group = "shared";
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
constexpr std::string_view kPianoModes[] = {"Classic", "Simulated"};
constexpr std::string_view kPianoTiers[] = {"Setting", "Eco", "Normal", "High"};
constexpr std::string_view kOffOn[] = {"Off", "On"};
// 1.1.2's Simulated piano: Classic (the 1.1.0 piano, bit for bit) stays the default; `tier` "Setting" follows
// Settings > Sound > Quality, the others hold this piano at one tier (its voice cap still follows the setting).
void simulatedPianoParams(fx::ParamTable& t) {
    ParameterDescriptor& sim = t.pick("sim", "Mode", 0.0, kPianoModes);
    sim.group = "piano", sim.automatable = false, sim.modulatable = false;
    ParameterDescriptor& tier = t.pick("tier", "Quality", 0.0, kPianoTiers);
    tier.group = "piano", tier.automatable = false, tier.modulatable = false;
    t.num("noise", "Noise", 0.35, 0.0, 1.0).group = "piano";  // the mechanical noises: 0.35 a listener's, 1 close-miked
    t.num("touch", "Touch", 0.0, 0.0, 1.0).group = "piano";   // pressed .. struck (the finger on the key)
    t.pick("action", "Action delay", 0.0, kOffOn).group = "piano";
    t.num("glide", "Pitch glide", 0.5, 0.0, 1.0).group = "piano";
    t.num("sympathy", "Sympathy", 0.5, 0.0, 1.0).group = "piano";
    t.num("phantom", "Phantom partials", 0.5, 0.0, 1.0).group = "piano";  // High only
}
void pianoParams(fx::ParamTable& t) {
    t.num("hammer", "Hammer", 0.5, 0.0, 1.0).group = "piano";
    t.pick("character", "Character", 0.0, kCharacters).group = "piano";
    t.num("unison", "Unison detune", 1.0, 0.0, 6.0, "ct").group = "piano";
    t.num("stretch", "Stretch", 1.0, 0.0, 2.0).group = "piano";
    t.expo("decay", "Decay", 1.0, 0.25, 4.0, "x").group = "piano";
    t.num("sustain", "Sustain pedal", 0.0, 0.0, 1.0).group = "piano";
    t.num("soft", "Soft pedal", 0.0, 0.0, 1.0).group = "piano";
    t.num("resonance", "Resonance", 0.3, 0.0, 1.0).group = "piano";
    simulatedPianoParams(t);  // 1.1.2: Simulated's choice and knobs, appended (timber_piano.h)
}
const ModuleDescriptor& pianoDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<Piano>(0, 0.25, 0.75, 0.15, CpuClass::Heavy, &pianoParams);
    return d;
}
static_assert(Piano::kModelParams == 16);

// ---------- Electric piano ----------
constexpr std::string_view kKinds[] = {"Tine", "Reed"};
void epianoParams(fx::ParamTable& t) {
    t.pick("kind", "Kind", 0.0, kKinds).group = "epiano";
    t.num("pickup", "Pickup", 0.5, 0.0, 1.0).group = "epiano";
    t.num("symmetry", "Symmetry", 0.2, -1.0, 1.0).group = "epiano";
    t.num("bell", "Bell", 0.5, 0.0, 1.0).group = "epiano";
    t.num("bark", "Bark", 0.2, 0.0, 1.0).group = "epiano";
    t.num("tremolo", "Tremolo", 0.0, 0.0, 1.0).group = "epiano";
    t.expo("rate", "Tremolo rate", 4.0, 0.5, 12.0, "Hz").group = "epiano";
    t.expo("decay", "Decay", 1.0, 0.25, 4.0, "x").group = "epiano";
}
const ModuleDescriptor& epianoDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<EPiano>(1, 0.12, 0.5, 0.1, CpuClass::Medium, &epianoParams);
    return d;
}
static_assert(EPiano::kModelParams == 8);

// ---------- Organ ----------
constexpr std::string_view kPercs[] = {"Off", "2nd", "3rd"};
constexpr std::string_view kPercDecay[] = {"Slow", "Fast"};
constexpr std::string_view kVibratos[] = {"Off", "V1", "V2", "V3", "C1", "C2", "C3"};
constexpr std::string_view kRotaries[] = {"Off", "Slow", "Fast", "Brake"};
void organParams(fx::ParamTable& t) {
    static const char* kBars[9][2] = {{"db16", "16'"}, {"db513", "5 1/3'"}, {"db8", "8'"}, {"db4", "4'"}, {"db223", "2 2/3'"},
                                      {"db2", "2'"}, {"db135", "1 3/5'"}, {"db113", "1 1/3'"}, {"db1", "1'"}};
    static constexpr double kDefault[9] = {8, 8, 8, 0, 0, 0, 0, 0, 0};  // the classic 888000000
    for (int k = 0; k < 9; ++k) {
        ParameterDescriptor& p = t.num(kBars[k][0], kBars[k][1], kDefault[k], 0.0, 8.0);
        p.step = 1.0, p.group = "organ/drawbars";
    }
    t.pick("perc", "Percussion", 0.0, kPercs).group = "organ";
    t.pick("perc_decay", "Percussion decay", 1.0, kPercDecay).group = "organ";
    t.pick("vibrato", "Vibrato", 0.0, kVibratos).group = "organ";
    t.num("click", "Key click", 0.3, 0.0, 1.0).group = "organ";
    t.num("drive", "Drive", 0.1, 0.0, 1.0).group = "organ";
    t.pick("rotary", "Rotary", 1.0, kRotaries).group = "organ";
}
const ModuleDescriptor& organDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<Organ>(2, 0.01, 0.5, 0.1, CpuClass::Medium, &organParams);
    return d;
}
static_assert(Organ::kModelParams == 15);

// ---------- Plucked ----------
constexpr std::string_view kPlucked[] = {"Steel guitar", "Nylon guitar", "Harp", "Koto"};
void pluckParams(fx::ParamTable& t) {
    t.pick("instrument", "Instrument", 0.0, kPlucked).group = "plucked";
    t.num("position", "Pluck position", 0.2, 0.02, 0.5).group = "plucked";
    t.num("pick", "Pick", 0.5, 0.0, 1.0).group = "plucked";
    t.num("damping", "Damping", 0.0, 0.0, 1.0).group = "plucked";
    t.num("brightness", "Brightness", 0.5, 0.0, 1.0).group = "plucked";
    t.expo("decay", "Decay", 1.0, 0.25, 4.0, "x").group = "plucked";
}
const ModuleDescriptor& pluckDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<Pluck>(3, 0.15, 0.5, 0.12, CpuClass::Medium, &pluckParams);
    return d;
}
static_assert(Pluck::kModelParams == 6);

// ---------- Bowed ----------
constexpr std::string_view kSections[] = {"Violin", "Viola", "Cello", "Bass"};
void bowedParams(fx::ParamTable& t) {
    t.pick("section", "Instrument", 0.0, kSections).group = "bowed";
    t.num("pressure", "Bow pressure", 0.5, 0.0, 1.0).group = "bowed";
    t.num("speed", "Bow speed", 0.5, 0.0, 1.0).group = "bowed";
    t.num("position", "Bow position", 0.12, 0.03, 0.3).group = "bowed";
    t.num("vibrato", "Vibrato", 0.3, 0.0, 1.0).group = "bowed";
    t.expo("vib_rate", "Vibrato rate", 5.5, 2.0, 9.0, "Hz").group = "bowed";
    t.expo("attack", "Attack", 0.12, 0.005, 2.0, "s").group = "bowed";
}
const ModuleDescriptor& bowedDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<Bowed>(4, 0.25, 0.6, 0.2, CpuClass::Medium, &bowedParams);
    return d;
}
static_assert(Bowed::kModelParams == 7);

// ---------- Mallets ----------
constexpr std::string_view kMallets[] = {"Marimba", "Vibraphone", "Xylophone", "Glockenspiel", "Chimes", "Bell"};
void malletParams(fx::ParamTable& t) {
    t.pick("instrument", "Instrument", 0.0, kMallets).group = "mallets";
    t.num("hardness", "Mallet hardness", 0.5, 0.0, 1.0).group = "mallets";
    t.expo("decay", "Decay", 1.0, 0.25, 4.0, "x").group = "mallets";
    t.num("position", "Strike position", 0.3, 0.0, 1.0).group = "mallets";
    t.num("damping", "High damping", 0.4, 0.0, 1.0).group = "mallets";
    t.num("dampen", "Key-up damper", 0.0, 0.0, 1.0).group = "mallets";
    t.num("motor", "Motor", 0.0, 0.0, 10.0, "Hz").group = "mallets";
}
const ModuleDescriptor& malletDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<Mallet>(5, 0.3, 0.5, 0.15, CpuClass::Medium, &malletParams);
    return d;
}
static_assert(Mallet::kModelParams == 7);

// ---------- Winds ----------
constexpr std::string_view kWinds[] = {"Clarinet", "Flute", "Sax", "Brass"};
void windParams(fx::ParamTable& t) {
    t.pick("instrument", "Instrument", 0.0, kWinds).group = "winds";
    t.num("breath", "Breath", 0.6, 0.0, 1.0).group = "winds";
    t.num("noise", "Breath noise", 0.15, 0.0, 1.0).group = "winds";
    t.num("reed", "Reed / jet / lips", 0.5, 0.0, 1.0).group = "winds";
    t.num("vibrato", "Vibrato", 0.2, 0.0, 1.0).group = "winds";
    t.expo("vib_rate", "Vibrato rate", 5.0, 2.0, 9.0, "Hz").group = "winds";
    t.num("growl", "Growl", 0.0, 0.0, 1.0).group = "winds";
    t.expo("attack", "Attack", 0.04, 0.005, 2.0, "s").group = "winds";
}
const ModuleDescriptor& windDescriptor() {
    static const ModuleDescriptor& d = modelDescriptor<Wind>(6, 0.08, 0.5, 0.15, CpuClass::Medium, &windParams);
    return d;
}
static_assert(Wind::kModelParams == 8);

template <class M, const ModuleDescriptor& (*D)(), int Index>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) Instrument<M>(D(), Index);
}

const fx::Variant kVariants[] = {
    {kModels[0], &pianoDescriptor, &make<Piano, &pianoDescriptor, 0>},
    {kModels[1], &epianoDescriptor, &make<EPiano, &epianoDescriptor, 1>},
    {kModels[2], &organDescriptor, &make<Organ, &organDescriptor, 2>},
    {kModels[3], &pluckDescriptor, &make<Pluck, &pluckDescriptor, 3>},
    {kModels[4], &bowedDescriptor, &make<Bowed, &bowedDescriptor, 4>},
    {kModels[5], &malletDescriptor, &make<Mallet, &malletDescriptor, 5>},
    {kModels[6], &windDescriptor, &make<Wind, &windDescriptor, 6>},
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
        case 1: return static_cast<Instrument<EPiano>&>(*p).bytes();
        case 2: return static_cast<Instrument<Organ>&>(*p).bytes();
        case 3: return static_cast<Instrument<Pluck>&>(*p).bytes();
        case 4: return static_cast<Instrument<Bowed>&>(*p).bytes();
        case 5: return static_cast<Instrument<Mallet>&>(*p).bytes();
        case 6: return static_cast<Instrument<Wind>&>(*p).bytes();
        default: return 0;
    }
}
size_t timberTableBytes() noexcept { return sizeof(Tables) + psim::tableBytes(); }  // 1.1.2: and the Simulated piano's

}  // namespace caw::timber
