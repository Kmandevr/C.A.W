// A chain of native stereo components (a track's inserts or the master's), with their parameters.
#include "component_chain.h"

#include <algorithm>
#include <bit>
#include <chrono>
#include <cmath>
#include <cstring>

#include "audio_clips.h"
#include "builtin_fx_racks.h"
#include "json.h"
#include "mod_route.h"
#include "route_math.h"

namespace caw {

namespace {

constexpr double kBypassSeconds = 0.005;

uint64_t toBits(double v) noexcept {
    uint64_t b = 0;
    std::memcpy(&b, &v, sizeof b);
    return b;
}
double fromBits(uint64_t b) noexcept {
    double v = 0;
    std::memcpy(&v, &b, sizeof v);
    return v;
}

bool isStereoEffect(const ModuleDescriptor& d) noexcept {
    if (d.portCount != 2 || !d.ports) return false;
    const PortDescriptor& in = d.ports[0];
    const PortDescriptor& out = d.ports[1];
    return in.type == PortType::Audio && in.input && in.layout == ChannelLayout::Stereo &&
           portChannelCount(in) == 2 && out.type == PortType::Audio && !out.input &&
           out.layout == ChannelLayout::Stereo && portChannelCount(out) == 2;
}

std::string quoted(const std::string& s) { return "'" + jsonEscape(s) + "'"; }

bool stereoAudio(const PortDescriptor& p) noexcept {
    return p.type == PortType::Audio && p.layout == ChannelLayout::Stereo && portChannelCount(p) == 2;
}

std::atomic<ChainProfile*> gProfile{nullptr};

uint64_t nowNs() noexcept {
    return static_cast<uint64_t>(
        std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count());
}

// Times one entry's block into its profile slot (no slot: nothing), less the time of chains nested inside it (a
// per-note FX slot inside its instrument, a rack's own chain), so each slot holds its own time. Audio thread only.
uint64_t gNestedNs = 0;
struct ProfileScope {
    ChainProfile::Slot* slot;
    uint64_t t0, outer = 0;
    bool ran = false;
    ProfileScope(ChainProfile* p, const void* processor, const std::string* id) noexcept
        : slot(p ? p->slot(processor, id) : nullptr), t0(slot ? nowNs() : 0) {
        if (!slot) return;
        outer = gNestedNs;
        gNestedNs = 0;
    }
    ~ProfileScope() {
        if (!slot) return;
        const uint64_t took = nowNs() - t0;
        slot->ns += took - std::min(took, gNestedNs);
        ++slot->calls;
        slot->ran += ran ? 1 : 0;
        gNestedNs = outer + took;
    }
};

}  // namespace

void ChainProfile::set(ChainProfile* profile) noexcept { gProfile.store(profile, std::memory_order_release); }
ChainProfile* ChainProfile::current() noexcept { return gProfile.load(std::memory_order_acquire); }

ChainProfile::Slot* ChainProfile::slot(const void* processor, const std::string* id) noexcept {
    for (uint32_t k = 0; k < used; ++k)
        if (slots[k].processor == processor) return &slots[k];
    if (used == kSlots) return nullptr;
    Slot& s = slots[used++];
    s.processor = processor;
    s.id = id;
    return &s;
}

bool ComponentChain::isKeyedEffect(const ModuleDescriptor& d) noexcept {
    if (!d.ports || d.portCount < 3 || d.portCount > 4) return false;
    int mainIn = 0, keyIn = 0, events = 0, out = 0;
    bool first = true, keyFirst = false;
    for (uint32_t k = 0; k < d.portCount; ++k) {
        const PortDescriptor& p = d.ports[k];
        if (p.type == PortType::Event && p.input) {
            ++events;
        } else if (stereoAudio(p) && !p.input) {
            ++out;
        } else if (stereoAudio(p) && p.input) {
            const bool key = p.id == "sidechain";
            if (first) keyFirst = key;
            first = false;
            ++(key ? keyIn : mainIn);
        } else {
            return false;
        }
    }
    return mainIn == 1 && keyIn == 1 && !keyFirst && events <= 1 && out == 1;
}

bool ComponentChain::isInstrument(const ModuleDescriptor& d) noexcept {
    if (d.portCount != 2 || !d.ports) return false;
    bool events = false, out = false;
    for (uint32_t k = 0; k < 2; ++k) {
        const PortDescriptor& p = d.ports[k];
        if (p.type == PortType::Event && p.input) events = true;
        else if (p.type == PortType::Audio && !p.input && p.layout == ChannelLayout::Stereo && portChannelCount(p) == 2) out = true;
    }
    return events && out;
}

bool ComponentChain::runsPerNote(const ModuleDescriptor& d, std::string* why) noexcept {
    uint32_t in = 0, out = 0, events = 0;
    for (uint32_t k = 0; d.ports && k < d.portCount; ++k) {
        const PortDescriptor& p = d.ports[k];
        if (stereoAudio(p) && p.input) ++in;
        else if (stereoAudio(p) && !p.input) ++out;
        else if (p.type == PortType::Event && p.input) ++events;
        else in = 99;
    }
    if (in != 1 || out != 1 || events > 1 || isKeyedEffect(d)) {
        if (why) *why = "only an effect with one stereo input and one stereo output runs per note";
        return false;
    }
    if (!(d.domains & (kDomainPerNote | kDomainPerVoice))) {
        if (why) *why = "it doesn't say it can run per note (its descriptor's domains)";
        return false;
    }
    return true;
}

std::unique_ptr<ComponentChain> ComponentChain::buildNoteEffects(const ModuleRegistry& registry,
                                                                 const std::vector<ComponentSpec>& specs,
                                                                 double sampleRate, std::string& error) {
    return make(registry, specs, sampleRate, Kind::NoteEffects, error);
}

bool ComponentChain::quiet() const noexcept {
    for (const auto& e : entries_)
        if (!(e->asleep || (e->mix == 0.0 && e->bypass.load(std::memory_order_relaxed)))) return false;
    return true;
}

std::unique_ptr<ComponentChain> ComponentChain::buildInstrument(const ModuleRegistry& registry, const ComponentSpec& spec,
                                                                double sampleRate, std::string& error) {
    return make(registry, {spec}, sampleRate, Kind::Instrument, error);
}

bool ComponentChain::isModulator(const ModuleDescriptor& d) noexcept {
    if (!d.ports || d.portCount == 0) return false;
    uint32_t outs = 0, events = 0, audio = 0;
    for (uint32_t k = 0; k < d.portCount; ++k) {
        const PortDescriptor& p = d.ports[k];
        if (p.type == PortType::Modulation && !p.input) ++outs;
        else if (p.type == PortType::Event && p.input) ++events;
        else if (p.type == PortType::Audio && p.input && (portChannelCount(p) == 1 || portChannelCount(p) == 2)) ++audio;
        else return false;
    }
    return outs >= 1 && outs <= kMaxModulatorOutputs && events <= 1 && audio <= 1;
}

std::unique_ptr<ComponentChain> ComponentChain::buildModulators(const ModuleRegistry& registry,
                                                                const std::vector<ComponentSpec>& specs,
                                                                double sampleRate, std::string& error) {
    return make(registry, specs, sampleRate, Kind::Modulators, error);
}

uint32_t ComponentChain::modulatorOutputs(std::size_t index) const noexcept {
    const ModuleDescriptor* d = descriptorOf(index);
    uint32_t n = 0;
    for (uint32_t k = 0; d && k < d->portCount; ++k) n += d->ports[k].type == PortType::Modulation && !d->ports[k].input;
    return n;
}

bool ComponentChain::modulatorTakesNotes(std::size_t index) const noexcept {
    const ModuleDescriptor* d = descriptorOf(index);
    for (uint32_t k = 0; d && k < d->portCount; ++k)
        if (d->ports[k].type == PortType::Event && d->ports[k].input) return true;
    return false;
}

bool ComponentChain::modulatorTakesAudio(std::size_t index) const noexcept {
    const ModuleDescriptor* d = descriptorOf(index);
    for (uint32_t k = 0; d && k < d->portCount; ++k)
        if (d->ports[k].type == PortType::Audio && d->ports[k].input) return true;
    return false;
}

int ComponentChain::parameterIndexOf(std::size_t index, std::string_view id) const noexcept {
    return index < entries_.size() ? parameterIndex(*entries_[index], id) : -1;
}

ComponentChain::~ComponentChain() {
    for (auto& e : entries_)
        if (e->processor) e->processor->deactivate();
    delete automation_;
}

uint64_t ComponentChain::estimateBytes(std::size_t components, std::size_t parameters) noexcept {
    const uint64_t perParameter = sizeof(ParameterResolver) + sizeof(std::atomic<uint64_t>) +
                                  sizeof(std::atomic<uint32_t>) + sizeof(uint64_t) + sizeof(uint32_t) +
                                  sizeof(std::array<double, kMaxFrames>) + sizeof(ParameterValue);
    return sizeof(ComponentChain) + static_cast<uint64_t>(components) * (sizeof(Entry) + sizeof(void*)) +
           static_cast<uint64_t>(parameters) * perParameter;
}

int ComponentChain::parameterIndex(const Entry& e, std::string_view id) const noexcept {
    if (!e.index.empty()) {
        const auto it = e.index.find(id);
        return it == e.index.end() ? -1 : it->second;
    }
    const ModuleDescriptor& d = e.processor->descriptor();
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == id) return static_cast<int>(k);
    return -1;
}

std::unique_ptr<ComponentChain> ComponentChain::build(const ModuleRegistry& registry,
                                                      const std::vector<ComponentSpec>& specs, double sampleRate,
                                                      std::string& error) {
    return make(registry, specs, sampleRate, Kind::Effects, error);
}

std::unique_ptr<ComponentChain> ComponentChain::make(const ModuleRegistry& registry, const std::vector<ComponentSpec>& specs,
                                                     double sampleRate, Kind kind, std::string& error) {
    const bool instrument = kind == Kind::Instrument;
    std::unique_ptr<ComponentChain> chain(new ComponentChain());
    chain->modulators_ = kind == Kind::Modulators;
    chain->noteFx_ = kind == Kind::NoteEffects;
    chain->sampleRate_ = sampleRate;
    if (instrument) chain->notes_ = std::make_unique<NoteEvents>();
    chain->entries_.reserve(specs.size());
    for (const ComponentSpec& spec : specs) {
        const ModuleDescriptor* d = registry.find(spec.id);
        if (!d) {
            error = "native component " + quoted(spec.id) + " is not loaded; load it with an explicit trust choice first";
            return nullptr;
        }
        if (instrument && !isInstrument(*d)) {
            error = "native component " + quoted(spec.id) +
                    " can't be an instrument: an instrument has one event input and one stereo audio output";
            return nullptr;
        }
        if (kind == Kind::Modulators) {
            if (!isModulator(*d)) {
                error = "native component " + quoted(spec.id) +
                        " is not a modulator: a modulator has 1 to 8 modulation outputs, at most one event input and"
                        " at most one audio input";
                return nullptr;
            }
        } else if (isModulator(*d)) {
            error = "native component " + quoted(spec.id) + " is a modulator: add it to the project's modulators";
            return nullptr;
        }
        if (!instrument && isInstrument(*d)) {
            error = "native component " + quoted(spec.id) + " is an instrument: choose it as the track's instrument";
            return nullptr;
        }
        if (kind == Kind::NoteEffects) {
            std::string why;
            if (!runsPerNote(*d, &why)) {
                error = "native component " + quoted(spec.id) + " can't run per note: " + why;
                return nullptr;
            }
        }
        const bool keyed = kind == Kind::Effects && isKeyedEffect(*d);
        if (kind == Kind::Effects && !isStereoEffect(*d) && !keyed) {
            error = "native component " + quoted(spec.id) +
                    " must expose one stereo audio input and one stereo audio output (and, keyed, a stereo"
                    " \"sidechain\" input and at most one event input)";
            return nullptr;
        }
        auto e = std::make_unique<Entry>();
        e->id = spec.id;
        if (keyed) {
            e->key = std::make_unique<KeyInput>();
            for (uint32_t k = 0; k < d->portCount; ++k)
                e->keyEvents = e->keyEvents || (d->ports[k].type == PortType::Event && d->ports[k].input);
        }
        if (kind == Kind::NoteEffects)
            for (uint32_t k = 0; k < d->portCount; ++k)
                e->noteEvents = e->noteEvents || (d->ports[k].type == PortType::Event && d->ports[k].input);
        e->processor = registry.create(spec.id);
        if (!e->processor) {
            error = "native component " + quoted(spec.id) + " could not create a processor instance";
            return nullptr;
        }
        if (kind == Kind::Modulators && !e->processor->usesProcessPorts()) {
            error = "native component " + quoted(spec.id) + " has modulation outputs but does not process ports";
            return nullptr;
        }
        // A rack (fx-racks) makes its children from its slot values first: its descriptor then lists their parameters.
        if (auto* rack = dynamic_cast<RackContainer*>(e->processor.get())) {
            std::string why;
            if (!rack->configure(registry, spec.params, spec.lenient, why)) {
                error = "native component " + quoted(spec.id) + ": " + why;
                return nullptr;
            }
            e->structure = rackStructure(spec);
        }
        const ModuleDescriptor& own = e->processor->descriptor();  // lives as long as the processor
        const uint32_t count = own.parameterCount;
        e->resolvers.resize(count);
        e->held = std::make_unique<std::atomic<uint64_t>[]>(count);
        e->touches = std::make_unique<std::atomic<uint32_t>[]>(count);
        e->seenBits.resize(count);
        e->seenTouch.assign(count, 0);
        e->samples.resize(count);
        e->values.resize(count);
        if (count > 64) {  // a long list (org.caw.drums): looked up by id, not walked
            e->index.reserve(count);
            for (uint32_t k = 0; k < count; ++k) e->index.emplace(own.parameters[k].id, static_cast<int>(k));
        }
        std::vector<double> values(count);
        for (uint32_t k = 0; k < count; ++k) {
            if (!e->resolvers[k].configure(own.parameters[k])) {
                error = "native component " + quoted(spec.id) + " has an invalid parameter " +
                        quoted(std::string(own.parameters[k].id));
                return nullptr;
            }
            values[k] = own.parameters[k].defaultValue;
        }
        for (const auto& [name, value] : spec.params) {
            const int k = chain->parameterIndex(*e, name);
            if (k < 0 && spec.lenient) continue;  // a rebuild dropped the parameter
            // A rack's value for a child its slot no longer holds (`s2.cutoff` after s2 changed): left over, ignored.
            if (k < 0 && !e->structure.empty() && name.find('.') != std::string::npos) continue;
            if (k < 0) {
                error = "native component " + quoted(spec.id) + " has no parameter " + quoted(name);
                return nullptr;
            }
            values[static_cast<size_t>(k)] = value;
        }
        for (uint32_t k = 0; k < count; ++k) {
            const double v = constrainParameter(own.parameters[k], values[k]);
            e->resolvers[k].setInitial(v);  // a restored value: no ramp
            e->held[k].store(toBits(v), std::memory_order_relaxed);
            e->seenBits[k] = toBits(v);
        }
        const bool bypass = spec.bypass;
        e->bypass.store(bypass, std::memory_order_relaxed);
        e->mix = bypass ? 0.0 : 1.0;
        // Prepared here, on the control thread: the audio thread only processes.
        if (!e->processor->activate(sampleRate, kMaxFrames)) {
            error = "native component " + quoted(spec.id) + " could not prepare for playback";
            return nullptr;
        }
        if (spec.hasState) {
            const bool fits = spec.state.size() <= own.maxStateBytes;
            const bool loaded = fits && e->processor->loadState(spec.state.data(), static_cast<uint32_t>(spec.state.size()),
                                                               spec.stateVersion);
            if (!loaded && !spec.lenient) {
                error = "native component " + quoted(spec.id) +
                        (fits ? " refused its saved state" : " saved state is larger than it allows");
                return nullptr;
            }
            if (!loaded) e->processor->reset();  // a rebuild that can't take the old state starts clean
        }
        if (!applyComponentSamples(*e->processor, spec.samples, sampleRate, error)) {
            error = "native component " + quoted(spec.id) + ": " + error;
            return nullptr;
        }
        applyComponentHostData(*e->processor, spec, sampleRate);  // audio clips, a sampler's zones
        chain->entries_.push_back(std::move(e));
    }
    return chain;
}

bool ComponentChain::sameComponents(const std::vector<ComponentSpec>& specs, double sampleRate) const noexcept {
    if (specs.size() != entries_.size() || sampleRate != sampleRate_) return false;
    for (std::size_t i = 0; i < specs.size(); ++i)
        if (specs[i].id != entries_[i]->id || rackStructure(specs[i]) != entries_[i]->structure) return false;
    return true;
}

void ComponentChain::setValues(const std::vector<ComponentSpec>& specs) noexcept {
    for (std::size_t i = 0; i < specs.size() && i < entries_.size(); ++i) {
        Entry& e = *entries_[i];
        const ModuleDescriptor& d = e.processor->descriptor();
        bool done = false;
        if (!e.index.empty()) {  // a long list: each named value looked up once (every value stored once, no flicker)
            try {
                std::vector<double> values(d.parameterCount);
                for (uint32_t k = 0; k < d.parameterCount; ++k) values[k] = d.parameters[k].defaultValue;
                for (const auto& [name, v] : specs[i].params) {
                    const auto it = e.index.find(std::string_view(name));
                    if (it != e.index.end()) values[static_cast<size_t>(it->second)] = v;
                }
                for (uint32_t k = 0; k < d.parameterCount; ++k)
                    e.held[k].store(toBits(constrainParameter(d.parameters[k], values[k])), std::memory_order_relaxed);
                done = true;
            } catch (...) {
            }
        }
        if (!done) {
            for (uint32_t k = 0; k < d.parameterCount; ++k) {
                double value = d.parameters[k].defaultValue;
                for (const auto& [name, v] : specs[i].params)
                    if (d.parameters[k].id == name) value = v;
                e.held[k].store(toBits(constrainParameter(d.parameters[k], value)), std::memory_order_relaxed);
            }
        }
        try {  // samples named or no longer named (loading off the audio thread; a file that fails empties its slot)
            std::string ignored;
            applyComponentSamples(*e.processor, specs[i].samples, sampleRate_, ignored);
            applyComponentHostData(*e.processor, specs[i], sampleRate_);
        } catch (...) {
        }
        e.generation.fetch_add(1, std::memory_order_release);  // after the values
        e.bypass.store(specs[i].bypass, std::memory_order_relaxed);
    }
}

bool ComponentChain::setValue(std::size_t index, const std::string& parameterId, double value) noexcept {
    if (index >= entries_.size() || !std::isfinite(value)) return false;
    Entry& e = *entries_[index];
    const int k = parameterIndex(e, parameterId);
    if (k < 0) return false;
    const double v = constrainParameter(e.processor->descriptor().parameters[k], value);
    e.held[k].store(toBits(v), std::memory_order_relaxed);
    e.touches[k].fetch_add(1, std::memory_order_release);  // after the value: the audio thread reads it after this
    e.generation.fetch_add(1, std::memory_order_release);
    return true;
}

bool ComponentChain::setBypass(std::size_t index, bool bypass) noexcept {
    if (index >= entries_.size()) return false;
    entries_[index]->bypass.store(bypass, std::memory_order_relaxed);
    return true;
}

std::vector<ComponentChain::SavedState> ComponentChain::saveStates() const {
    std::vector<SavedState> out(entries_.size());
    for (std::size_t i = 0; i < entries_.size(); ++i) {
        const ModuleProcessor& p = *entries_[i]->processor;
        out[i].data.resize(p.descriptor().maxStateBytes);
        uint32_t written = 0;
        out[i].ok = p.saveState(out[i].data.data(), static_cast<uint32_t>(out[i].data.size()), written);
        out[i].data.resize(out[i].ok ? written : 0);
        out[i].version = p.stateVersion();
    }
    return out;
}

std::vector<ComponentSpec> ComponentChain::currentSpecs() const {
    const std::vector<SavedState> states = saveStates();
    std::vector<ComponentSpec> specs(entries_.size());
    for (std::size_t i = 0; i < entries_.size(); ++i) {
        const Entry& e = *entries_[i];
        const ModuleDescriptor& d = e.processor->descriptor();
        specs[i].id = e.id;
        specs[i].lenient = true;
        for (uint32_t k = 0; k < d.parameterCount; ++k)
            specs[i].params.emplace_back(std::string(d.parameters[k].id), fromBits(e.held[k].load(std::memory_order_relaxed)));
        specs[i].bypass = e.bypass.load(std::memory_order_relaxed);
        if (states[i].ok && !states[i].data.empty()) {
            specs[i].hasState = true;
            
            specs[i].stateVersion = states[i].version;
            specs[i].state = states[i].data;
        }
    }
    return specs;
}

bool ComponentChain::uses(const std::string& id) const noexcept {
    for (const auto& e : entries_)
        if (e->id == id) return true;
    return false;
}

std::string ComponentChain::automationKey(const std::vector<ProjectAutomationLaneSpec>& lanes, const std::string& layer,
                                          const char* targetType) {
    std::string key;
    for (const ProjectAutomationLaneSpec& lane : lanes) {
        if (lane.targetType != targetType || lane.moduleId != layer) continue;
        key += std::to_string(lane.component) + "|" + lane.target + "|";
        for (const AutomationPointSpec& p : lane.points) {
            // Exact: the bits, so the smallest edit gives a new key.
            key += std::to_string(std::bit_cast<uint64_t>(p.step)) + ":" + std::to_string(std::bit_cast<uint64_t>(p.value)) + ";";
        }
    }
    return key;
}

std::unique_ptr<ComponentAutomation> ComponentChain::automationFor(
    const std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>>& lanes, const std::string& layer) const {
    if (!lanes) return nullptr;
    auto table = std::make_unique<ComponentAutomation>();
    table->lanes = lanes;
    table->byParam.resize(entries_.size());
    bool any = false;
    const char* targetType = instrument() ? "instrument" : noteFx_ ? "noteComponent" : "component";
    for (std::size_t i = 0; i < entries_.size(); ++i) {
        const ModuleDescriptor& d = entries_[i]->processor->descriptor();
        table->byParam[i].assign(d.parameterCount, nullptr);
        for (uint32_t k = 0; k < d.parameterCount; ++k) {
            if (!d.parameters[k].automatable) continue;  // the descriptor's flag: lanes never drive it
            for (const ProjectAutomationLaneSpec& lane : *lanes)
                if (lane.targetType == targetType && lane.moduleId == layer &&
                    lane.component == static_cast<int>(i) && lane.target == d.parameters[k].id && !lane.points.empty()) {
                    table->byParam[i][k] = &lane;
                    any = true;
                    break;
                }
        }
    }
    if (!any) return nullptr;
    return table;
}

uint32_t ComponentChain::tailFrames() const noexcept {
    uint32_t tail = 0;
    for (const auto& e : entries_)
        if (!e->bypass.load(std::memory_order_relaxed)) tail = std::max(tail, e->processor->descriptor().tailFrames);
    return tail;
}

uint64_t ComponentChain::latencyFrames() const noexcept {
    uint64_t latency = 0;
    for (const auto& e : entries_) {  // a bypassed effect passes its input on undelayed
        if (e->bypass.load(std::memory_order_relaxed)) continue;
        if (const auto* v = dynamic_cast<const VariableLatency*>(e->processor.get())) {
            // Control thread: as many values as it has (a rack has hundreds).
            std::vector<double> values(e->resolvers.size());
            const uint32_t n = static_cast<uint32_t>(values.size());
            for (uint32_t k = 0; k < n; ++k) values[k] = fromBits(e->held[k].load(std::memory_order_relaxed));
            latency += v->latencyFor(values.data(), n);
        } else {
            latency += e->processor->descriptor().latencyFrames;
        }
    }
    return latency;
}

void ComponentChain::reset() noexcept {
    for (auto& e : entries_) {
        e->processor->reset();
        e->asleep = false;
    }
}

namespace {
// Non-finite samples become 0. Tested on the bits (exponent all ones: inf or NaN) and written as a select,
// so the loop vectorizes.
void sanitize(float* x, uint32_t m) noexcept {
    for (uint32_t i = 0; i < m; ++i) {
        const uint32_t bits = std::bit_cast<uint32_t>(x[i]);
        x[i] = (bits & 0x7f800000u) == 0x7f800000u ? 0.0f : x[i];
    }
}
}  // namespace

void ComponentChain::resolveEntry(Entry& e, std::size_t index, uint32_t m, const ChainTime* time, bool playing,
                                  bool newPlay) noexcept {
    const std::size_t count = e.resolvers.size();
    // Parameters move on even while bypassed, so a component comes back at its current values. Nothing new
    // since the last block (no value, touch, lane or play change, no ramp): last block's values stand.
    const uint32_t generation = e.generation.load(std::memory_order_acquire);
    const bool steady = generation == e.seenGeneration && !newPlay && !e.dynamic && playing == e.seenPlaying &&
                        e.seenLanes == static_cast<const void*>(automation_);
    e.seenGeneration = generation;
    e.seenPlaying = playing;
    e.seenLanes = automation_;
    e.dynamic = false;
    for (std::size_t k = 0; k < count && !steady; ++k) {
        if (newPlay) e.resolvers[k].clearTouch();  // a Play ends knob overrides: the lanes rule again
        const uint32_t touch = e.touches[k].load(std::memory_order_acquire);
        const uint64_t bits = e.held[k].load(std::memory_order_relaxed);
        if (touch != e.seenTouch[k]) {  // a knob move: ramps, and overrides a lane
            e.seenTouch[k] = touch;
            e.seenBits[k] = bits;
            e.resolvers[k].setBase(fromBits(bits));
        } else if (bits != e.seenBits[k]) {  // a project update: ramps, not a touch
            e.seenBits[k] = bits;
            const bool touched = e.resolvers[k].touched();
            e.resolvers[k].setBase(fromBits(bits));
            if (!touched) e.resolvers[k].clearTouch();
        }
        const double* automation = nullptr;
        const ProjectAutomationLaneSpec* lane =
            playing && automation_ && index < automation_->byParam.size() && k < automation_->byParam[index].size()
                ? automation_->byParam[index][k] : nullptr;
        if (lane) {
            for (uint32_t i = 0; i < m; ++i)
                lane_[i] = automationLaneValue(lane->points.data(), lane->points.size(),
                                               static_cast<double>(time->start + i) / time->stepLength,
                                               lane->points.front().value);
            automation = lane_.data();
        }
        e.values[k] = e.resolvers[k].resolve(m, automation, nullptr, e.samples[k].data());
        e.dynamic = e.dynamic || e.values[k].samples != nullptr || e.resolvers[k].ramping();
    }
}

const ParameterValue* ComponentChain::modulated(const Entry& e, std::size_t index, uint32_t m,
                                                const ChainTime* time) noexcept {
    const ChainModulation* mod = time ? time->modulation : nullptr;
    const uint32_t count = static_cast<uint32_t>(e.values.size());
    if (!mod || mod->count == 0 || count > mod->valueCapacity || !mod->values) return e.values.data();
    bool any = false;
    uint32_t buffer = 0;
    const ModuleDescriptor& d = e.processor->descriptor();
    for (uint32_t b = 0; b < mod->count; ++b) {
        const ChainModulation::Binding& x = mod->bindings[b];
        if (x.entry != index || x.param >= count || !x.offset || !d.parameters[x.param].modulatable) continue;
        if (!any) {
            std::copy_n(e.values.data(), count, mod->values);
            any = true;
        }
        const ParameterDescriptor& p = d.parameters[x.param];
        const ParameterValue base = e.values[x.param];
        const float* off = x.offset;
        bool flat = !base.samples;
        for (uint32_t i = 1; i < m && flat; ++i) flat = off[i] == off[0];
        if (flat) {
            mod->values[x.param] = ParameterValue{nullptr, modulatedValue(p, base.value, off[0])};
        } else if (buffer < mod->sampleBuffers && mod->samples) {
            double* out = mod->samples + static_cast<std::size_t>(buffer++) * kMaxFrames;
            if (base.samples) {
                for (uint32_t i = 0; i < m; ++i) out[i] = modulatedValue(p, base.samples[i], off[i]);
            } else {  // a held base: its normalized value and the curve's log once (modulatedValue's bits)
                denormalizeOffsets(p, normalizeParameter(p, base.value), off, m, out);
            }
            mod->values[x.param] = ParameterValue{out, out[0]};
        }
    }
    return any ? mod->values : e.values.data();
}

void ComponentChain::beginModulators(const ChainTime* time) noexcept {
    const bool playing = time && time->playing;
    modNewPlay_ = playing && time->playEpoch != playEpoch_;
    if (playing) playEpoch_ = time->playEpoch;
}

bool ComponentChain::runModulator(std::size_t index, uint32_t m, double sampleRate, const ChainTime* time,
                                  const Event* events, uint32_t eventCount, const float* inL, const float* inR,
                                  float* const* outs, uint32_t outCount) noexcept {
    if (!modulators_ || index >= entries_.size() || m == 0 || m > kMaxFrames) return false;
    Entry& e = *entries_[index];
    ProfileScope scope(gProfile.load(std::memory_order_relaxed), e.processor.get(), &e.id);
    if (scope.slot) scope.slot->modulator = true;
    scope.ran = true;
    const bool playing = time && time->playing;
    resolveEntry(e, index, m, time, playing, modNewPlay_);
    for (uint32_t k = 0; k < outCount; ++k) std::fill_n(outs[k], m, 0.0f);
    if (e.bypass.load(std::memory_order_relaxed)) return true;  // bypassed: its outputs hold 0
    Transport transport;
    if (time) transport = {time->tempo, static_cast<double>(time->start) / time->stepLength / 4.0, time->beatsPerBar, playing};
    static const float silence[kMaxFrames] = {};
    const float* ch[2] = {inL ? inL : silence, inR ? inR : (inL ? inL : silence)};
    const ModuleDescriptor& d = e.processor->descriptor();
    uint32_t audioChannels = 0;
    for (uint32_t k = 0; k < d.portCount; ++k)
        if (d.ports[k].type == PortType::Audio && d.ports[k].input) audioChannels = portChannelCount(d.ports[k]);
    const ConstChannelBufferView audioIn{ch, audioChannels, m};
    const EventInput notes{events, events ? eventCount : 0};
    ProcessBlock ports;
    ports.frames = m;
    ports.sampleRate = sampleRate;
    ports.audioIn = audioChannels ? &audioIn : nullptr;
    ports.audioInCount = audioChannels ? 1 : 0;
    ports.eventIn = modulatorTakesNotes(index) ? &notes : nullptr;
    ports.eventInCount = ports.eventIn ? 1 : 0;
    ports.modulationOut = outs;
    ports.modulationOutCount = outCount;
    ports.parameters = e.values.empty() ? nullptr : modulated(e, index, m, time);
    ports.parameterCount = static_cast<uint32_t>(e.values.size());
    ports.transport = time ? &transport : nullptr;
    const bool ok = e.processor->processPorts(ports);
    for (uint32_t k = 0; k < outCount; ++k) {
        float* o = outs[k];
        for (uint32_t i = 0; i < m; ++i) o[i] = ok && std::isfinite(o[i]) ? std::clamp(o[i], 0.0f, 1.0f) : 0.0f;
    }
    return ok;
}

void ComponentChain::process(float* left, float* right, uint32_t m, double sampleRate, const ChainTime* time) noexcept {
    if (m == 0 || m > kMaxFrames) return;
    if (notes_) {  // an instrument makes its sound from silence: bypassed, it crossfades to silence
        std::fill_n(left, m, 0.0f);
        std::fill_n(right, m, 0.0f);
        notes_->sort();
    }
    const bool playing = time && time->playing;
    const bool newPlay = playing && time->playEpoch != playEpoch_;
    if (playing) playEpoch_ = time->playEpoch;
    Transport transport;  // what each component sees of the song: the tempo always, the position while playing
    if (time) transport = {time->tempo, static_cast<double>(time->start) / time->stepLength / 4.0, time->beatsPerBar, playing};
    const double bypassStep = 1.0 / std::max(1.0, kBypassSeconds * sampleRate);
    ChainProfile* const profile = gProfile.load(std::memory_order_relaxed);
    for (std::size_t index = 0; index < entries_.size(); ++index) {
        Entry& e = *entries_[index];
        ProfileScope scope(profile, e.processor.get(), &e.id);
        const std::size_t count = e.resolvers.size();
        resolveEntry(e, index, m, time, playing, newPlay);
        const double target = e.bypass.load(std::memory_order_relaxed) ? 0.0 : 1.0;
        if (e.mix == 0.0 && target == 0.0) continue;  // bypassed: not run, input passes on untouched
        if (e.mix == 0.0) e.processor->reset();  // back from a bypass: no audio from before it
        // Asleep (fallen silent) and still nothing coming in: not run. Its output is silence, which is already
        // in left/right (an instrument's are cleared above; an effect's input is silent and passes on).
        const bool on = e.mix == 1.0 && target == 1.0;
        // A keyed effect hears its key only in the chunk the sources wrote it (else silence and no notes).
        const KeyInput* key = e.key && time && time->chunk >= 0 && e.key->chunk == time->chunk ? e.key.get() : nullptr;
        const bool events = (notes_ && notes_->count() > 0) || (key && key->count > 0) || (e.noteEvents && noteEventCount_ > 0);
        if (e.asleep && on && !events && (notes_ || (peakAbs(left, m) == 0.0f && peakAbs(right, m) == 0.0f))) continue;
        e.asleep = false;
        scope.ran = true;
        std::copy_n(left, m, stageL_.data());
        std::copy_n(right, m, stageR_.data());
        const float* in[2] = {stageL_.data(), stageR_.data()};
        float* out[2] = {left, right};
        AudioProcessBlock block;
        block.input = {in, 2, m};
        block.output = {out, 2, m};
        block.frames = m;
        block.sampleRate = sampleRate;
        block.parameters = count ? modulated(e, index, m, time) : nullptr;
        block.parameterCount = static_cast<uint32_t>(count);
        block.transport = time ? &transport : nullptr;
        bool processed;
        if (e.key) {
            static const float silence[kMaxFrames] = {};
            const float* keyCh[2] = {key ? key->l : silence, key ? key->r : silence};
            const ConstChannelBufferView audioIn[2] = {{in, 2, m}, {keyCh, 2, m}};
            const ChannelBufferView audioOut{out, 2, m};
            const EventInput keyEvents{key ? key->events : nullptr, key ? key->count : 0};
            ProcessBlock ports;
            ports.frames = m;
            ports.sampleRate = sampleRate;
            ports.audioIn = audioIn;
            ports.audioInCount = 2;
            ports.audioOut = &audioOut;
            ports.audioOutCount = 1;
            ports.eventIn = e.keyEvents ? &keyEvents : nullptr;
            ports.eventInCount = e.keyEvents ? 1 : 0;
            ports.parameters = block.parameters;
            ports.parameterCount = block.parameterCount;
            ports.transport = block.transport;
            processed = e.processor->usesProcessPorts() && e.processor->processPorts(ports);
        } else if (notes_) {
            const ChannelBufferView audioOut{out, 2, m};
            const EventInput events{notes_->events(), notes_->count()};
            ProcessBlock ports;
            ports.frames = m;
            ports.sampleRate = sampleRate;
            ports.audioOut = &audioOut;
            ports.audioOutCount = 1;
            ports.eventIn = &events;
            ports.eventInCount = 1;
            ports.parameters = block.parameters;
            ports.parameterCount = block.parameterCount;
            ports.transport = block.transport;
            ports.voices = voices_;  // per-note FX lanes (#127), or null
            processed = e.processor->usesProcessPorts() && e.processor->processPorts(ports);
        } else if (e.noteEvents) {  // a per-note effect with an event input: its note's events (#127)
            const ConstChannelBufferView audioIn{in, 2, m};
            const ChannelBufferView audioOut{out, 2, m};
            const EventInput events{noteEvents_, noteEventCount_};
            ProcessBlock ports;
            ports.frames = m;
            ports.sampleRate = sampleRate;
            ports.audioIn = &audioIn;
            ports.audioInCount = 1;
            ports.audioOut = &audioOut;
            ports.audioOutCount = 1;
            ports.eventIn = &events;
            ports.eventInCount = 1;
            ports.parameters = block.parameters;
            ports.parameterCount = block.parameterCount;
            ports.transport = block.transport;
            processed = e.processor->usesProcessPorts() ? e.processor->processPorts(ports) : e.processor->process(block);
        } else {
            processed = e.processor->process(block);
        }
        if (!processed) {
            std::copy_n(stageL_.data(), m, left);
            std::copy_n(stageR_.data(), m, right);
        }
        sanitize(left, m);
        sanitize(right, m);
        // Only a component that says so sleeps: one put to sleep by its declared tail alone would fall asleep on a
        // block boundary with its timed state (an LFO, a control grid) frozen there, and wake differently for
        // each device buffer size than in an export.
        if (on && processed) e.asleep = e.processor->quiet();
        if (e.mix != target || target != 1.0) {
            for (uint32_t i = 0; i < m; ++i) {
                e.mix = target > e.mix ? std::min(target, e.mix + bypassStep) : std::max(target, e.mix - bypassStep);
                const float w = static_cast<float>(e.mix);
                left[i] = stageL_[i] + (left[i] - stageL_[i]) * w;
                right[i] = stageR_[i] + (right[i] - stageR_[i]) * w;
            }
        }
    }
    if (notes_) notes_->clearEvents();  // delivered (or dropped while bypassed): the next block starts empty
    noteEvents_ = nullptr;  // per-note FX: set again before each call
    noteEventCount_ = 0;
}

bool ComponentChain::monitorsStopped() const noexcept {
    for (const auto& e : entries_)
        if (e->processor && caw::monitorsStopped(*e->processor)) return true;
    return false;
}

int32_t ComponentChain::readDisplay(std::size_t index, float* out, uint32_t max) const noexcept {
    // A rack's child (fx-racks): index + (child + 1) * 65536.
    if (const std::size_t child = index >> 16; child > 0) {
        index &= 0xFFFFu;
        if (index >= entries_.size() || !entries_[index]->processor) return -1;
        const auto* rack = dynamic_cast<const RackContainer*>(entries_[index]->processor.get());
        if (!rack) return -1;
        const uint32_t n = rack->readChildDisplay(static_cast<uint32_t>(child - 1), out, max);
        return static_cast<int32_t>(n > max ? max : n);
    }
    if (index >= entries_.size() || !entries_[index]->processor) return -1;
    const uint32_t n = entries_[index]->processor->readDisplay(out, max);
    return static_cast<int32_t>(n > max ? max : n);
}

}  // namespace caw
