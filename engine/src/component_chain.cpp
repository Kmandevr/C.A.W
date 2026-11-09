// A chain of native stereo components (a track's inserts or the master's), with their parameters.
#include "component_chain.h"

#include <algorithm>
#include <cmath>
#include <cstring>

#include "json.h"

namespace caw {

namespace {

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
    for (Entry& e : entries_)
        if (e.processor) e.processor->deactivate();
}

uint64_t ComponentChain::estimateBytes(std::size_t components, std::size_t parameters) noexcept {
    const uint64_t perParameter = sizeof(ParameterResolver) + sizeof(std::atomic<uint64_t>) + sizeof(uint64_t) +
                                  sizeof(std::array<double, kMaxFrames>) + sizeof(ParameterValue);
    return sizeof(ComponentChain) + static_cast<uint64_t>(components) * sizeof(Entry) +
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
        Entry e;
        e.id = spec.id;
        e.processor = registry.create(spec.id);
        if (!e.processor) {
            error = "native component " + quoted(spec.id) + " could not create a processor instance";
            return nullptr;
        }
        const ModuleDescriptor& own = e.processor->descriptor();  // lives as long as the processor
        const uint32_t count = own.parameterCount;
        e.resolvers.resize(count);
        e.held = std::make_unique<std::atomic<uint64_t>[]>(count);
        e.seen.resize(count);
        e.samples.resize(count);
        e.values.resize(count);
        for (uint32_t k = 0; k < count; ++k) {
            if (!e.resolvers[k].configure(own.parameters[k])) {
                error = "native component " + quoted(spec.id) + " has an invalid parameter " +
                        quoted(std::string(own.parameters[k].id));
                return nullptr;
            }
            const double initial = constrainParameter(own.parameters[k], own.parameters[k].defaultValue);
            e.resolvers[k].setInitial(initial);
            e.held[k].store(toBits(initial), std::memory_order_relaxed);
            e.seen[k] = toBits(initial);
        }
        for (const auto& [name, value] : spec.params) {
            const int k = chain->parameterIndex(e, name);
            if (k < 0) {
                error = "native component " + quoted(spec.id) + " has no parameter " + quoted(name);
                return nullptr;
            }
            const double v = constrainParameter(own.parameters[k], value);
            e.resolvers[static_cast<size_t>(k)].setInitial(v);  // a restored value: no ramp
            e.held[k].store(toBits(v), std::memory_order_relaxed);
            e.seen[static_cast<size_t>(k)] = toBits(v);
        }
        // Prepared here, on the control thread: the audio thread only processes.
        if (!e.processor->activate(sampleRate, kMaxFrames)) {
            error = "native component " + quoted(spec.id) + " could not prepare for playback";
            return nullptr;
        }
        chain->entries_.push_back(std::move(e));
    }
    return chain;
}

bool ComponentChain::sameComponents(const std::vector<ComponentSpec>& specs, double sampleRate) const noexcept {
    if (specs.size() != entries_.size() || sampleRate != sampleRate_) return false;
    for (std::size_t i = 0; i < specs.size(); ++i)
        if (specs[i].id != entries_[i].id) return false;
    return true;
}

void ComponentChain::setValues(const std::vector<ComponentSpec>& specs) noexcept {
    for (std::size_t i = 0; i < specs.size() && i < entries_.size(); ++i) {
        const ModuleDescriptor& d = entries_[i].processor->descriptor();
        for (uint32_t k = 0; k < d.parameterCount; ++k) {
            double value = d.parameters[k].defaultValue;
            for (const auto& [name, v] : specs[i].params)
                if (d.parameters[k].id == name) value = v;
            entries_[i].held[k].store(toBits(constrainParameter(d.parameters[k], value)), std::memory_order_relaxed);
        }
    }
}

void ComponentChain::reset() noexcept {
    for (Entry& e : entries_) e.processor->reset();
}

bool ComponentChain::setValue(std::size_t index, const std::string& parameterId, double value) noexcept {
    if (index >= entries_.size() || !std::isfinite(value)) return false;
    Entry& e = entries_[index];
    const int k = parameterIndex(e, parameterId);
    if (k < 0) return false;
    const double v = constrainParameter(e.processor->descriptor().parameters[k], value);
    e.held[k].store(toBits(v), std::memory_order_relaxed);
    return true;
}

void ComponentChain::process(float* left, float* right, uint32_t m, double sampleRate) noexcept {
    if (m == 0 || m > kMaxFrames) return;
    for (Entry& e : entries_) {
        const std::size_t count = e.resolvers.size();
        for (std::size_t k = 0; k < count; ++k) {
            const uint64_t bits = e.held[k].load(std::memory_order_relaxed);
            if (bits != e.seen[k]) {
                e.seen[k] = bits;
                e.resolvers[k].setBase(fromBits(bits));  // ramps over the parameter's smoothing
            }
            e.values[k] = e.resolvers[k].resolve(m, nullptr, nullptr, e.samples[k].data());
        }
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
        if (!e.processor->process(block)) {
            std::copy_n(stageL_.data(), m, left);
            std::copy_n(stageR_.data(), m, right);
        }
        for (uint32_t i = 0; i < m; ++i) {
            if (!std::isfinite(left[i])) left[i] = 0.0f;
            if (!std::isfinite(right[i])) right[i] = 0.0f;
        }
    }
}

}  // namespace caw
