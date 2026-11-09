// A chain of native stereo components (a track's inserts or the master's), with their parameters.
#include "component_chain.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstring>

#include "json.h"

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

}  // namespace

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

int ComponentChain::parameterIndex(const Entry& e, const std::string& id) const noexcept {
    const ModuleDescriptor& d = e.processor->descriptor();
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == id) return static_cast<int>(k);
    return -1;
}

std::unique_ptr<ComponentChain> ComponentChain::build(const ModuleRegistry& registry,
                                                      const std::vector<ComponentSpec>& specs, double sampleRate,
                                                      std::string& error) {
    std::unique_ptr<ComponentChain> chain(new ComponentChain());
    chain->sampleRate_ = sampleRate;
    chain->entries_.reserve(specs.size());
    for (const ComponentSpec& spec : specs) {
        const ModuleDescriptor* d = registry.find(spec.id);
        if (!d) {
            error = "native component " + quoted(spec.id) + " is not loaded; load it with an explicit trust choice first";
            return nullptr;
        }
        if (!isStereoEffect(*d)) {
            error = "native component " + quoted(spec.id) +
                    " must currently expose one stereo audio input and one stereo audio output";
            return nullptr;
        }
        auto e = std::make_unique<Entry>();
        e->id = spec.id;
        e->processor = registry.create(spec.id);
        if (!e->processor) {
            error = "native component " + quoted(spec.id) + " could not create a processor instance";
            return nullptr;
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
        chain->entries_.push_back(std::move(e));
    }
    return chain;
}

bool ComponentChain::sameComponents(const std::vector<ComponentSpec>& specs, double sampleRate) const noexcept {
    if (specs.size() != entries_.size() || sampleRate != sampleRate_) return false;
    for (std::size_t i = 0; i < specs.size(); ++i)
        if (specs[i].id != entries_[i]->id) return false;
    return true;
}

void ComponentChain::setValues(const std::vector<ComponentSpec>& specs) noexcept {
    for (std::size_t i = 0; i < specs.size() && i < entries_.size(); ++i) {
        Entry& e = *entries_[i];
        const ModuleDescriptor& d = e.processor->descriptor();
        for (uint32_t k = 0; k < d.parameterCount; ++k) {
            double value = d.parameters[k].defaultValue;
            for (const auto& [name, v] : specs[i].params)
                if (d.parameters[k].id == name) value = v;
            e.held[k].store(toBits(constrainParameter(d.parameters[k], value)), std::memory_order_relaxed);
        }
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

std::string ComponentChain::automationKey(const std::vector<ProjectAutomationLaneSpec>& lanes, const std::string& layer) {
    std::string key;
    for (const ProjectAutomationLaneSpec& lane : lanes) {
        if (lane.targetType != "component" || lane.moduleId != layer) continue;
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
    for (std::size_t i = 0; i < entries_.size(); ++i) {
        const ModuleDescriptor& d = entries_[i]->processor->descriptor();
        table->byParam[i].assign(d.parameterCount, nullptr);
        for (uint32_t k = 0; k < d.parameterCount; ++k) {
            if (!d.parameters[k].automatable) continue;  // the descriptor's flag: lanes never drive it
            for (const ProjectAutomationLaneSpec& lane : *lanes)
                if (lane.targetType == "component" && lane.moduleId == layer &&
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
    for (const auto& e : entries_)  // a bypassed effect passes its input on undelayed
        if (!e->bypass.load(std::memory_order_relaxed)) latency += e->processor->descriptor().latencyFrames;
    return latency;
}

void ComponentChain::reset() noexcept {
    for (auto& e : entries_) e->processor->reset();
}

void ComponentChain::process(float* left, float* right, uint32_t m, double sampleRate, const ChainTime* time) noexcept {
    if (m == 0 || m > kMaxFrames) return;
    const bool newPlay = time && time->playEpoch != playEpoch_;
    if (time) playEpoch_ = time->playEpoch;
    Transport transport;  // what each component sees of the song (none while stopped)
    if (time) transport = {time->tempo, static_cast<double>(time->start) / time->stepLength / 4.0, time->beatsPerBar, true};
    const double bypassStep = 1.0 / std::max(1.0, kBypassSeconds * sampleRate);
    for (std::size_t index = 0; index < entries_.size(); ++index) {
        Entry& e = *entries_[index];
        const std::size_t count = e.resolvers.size();
        // Parameters move on even while bypassed, so a component comes back at its current values.
        for (std::size_t k = 0; k < count; ++k) {
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
                time && automation_ && index < automation_->byParam.size() && k < automation_->byParam[index].size()
                    ? automation_->byParam[index][k] : nullptr;
            if (lane) {
                for (uint32_t i = 0; i < m; ++i)
                    lane_[i] = automationLaneValue(lane->points.data(), lane->points.size(),
                                                   static_cast<double>(time->start + i) / time->stepLength,
                                                   lane->points.front().value);
                automation = lane_.data();
            }
            e.values[k] = e.resolvers[k].resolve(m, automation, nullptr, e.samples[k].data());
        }
        const double target = e.bypass.load(std::memory_order_relaxed) ? 0.0 : 1.0;
        if (e.mix == 0.0 && target == 0.0) continue;  // bypassed: not run, input passes on untouched
        if (e.mix == 0.0) e.processor->reset();  // back from a bypass: no audio from before it
        std::copy_n(left, m, stageL_.data());
        std::copy_n(right, m, stageR_.data());
        const float* in[2] = {stageL_.data(), stageR_.data()};
        float* out[2] = {left, right};
        AudioProcessBlock block;
        block.input = {in, 2, m};
        block.output = {out, 2, m};
        block.frames = m;
        block.sampleRate = sampleRate;
        block.parameters = count ? e.values.data() : nullptr;
        block.parameterCount = static_cast<uint32_t>(count);
        block.transport = time ? &transport : nullptr;
        if (!e.processor->process(block)) {
            std::copy_n(stageL_.data(), m, left);
            std::copy_n(stageR_.data(), m, right);
        }
        for (uint32_t i = 0; i < m; ++i) {
            if (!std::isfinite(left[i])) left[i] = 0.0f;
            if (!std::isfinite(right[i])) right[i] = 0.0f;
        }
        if (e.mix != target || target != 1.0) {
            for (uint32_t i = 0; i < m; ++i) {
                e.mix = target > e.mix ? std::min(target, e.mix + bypassStep) : std::max(target, e.mix - bypassStep);
                const float w = static_cast<float>(e.mix);
                left[i] = stageL_[i] + (left[i] - stageL_[i]) * w;
                right[i] = stageR_[i] + (right[i] - stageR_[i]) * w;
            }
        }
    }
}

}  // namespace caw
