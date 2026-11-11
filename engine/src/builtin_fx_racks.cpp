// The racks (fx-racks): the shared container (children from slot values, a per-instance descriptor, state, sleep) and registration.
#include "builtin_fx_racks.h"

#include "builtin_fx_racks_internal.h"

#include <algorithm>
#include <cstring>

namespace caw {

uint32_t rackChildHash(std::string_view id) noexcept {
    uint32_t h = 2166136261u;  // 32-bit FNV-1a
    for (const char c : id) {
        h ^= static_cast<uint8_t>(c);
        h *= 16777619u;
    }
    const uint32_t folded = (h >> 24) ^ (h & 0xFFFFFFu);  // xor-folded to 24 bits: exact as a double
    return folded == 0 ? 1u : folded;
}

std::string rackStructure(const ComponentSpec& spec) {
    if (!isRackId(spec.id)) return {};
    // The `_fx` values, by slot name, in the order the spec gives them (the slot names make it order-free below).
    std::vector<std::pair<std::string, long long>> slots;
    for (const auto& [name, value] : spec.params) {
        if (name.size() < 4 || name.compare(name.size() - 3, 3, "_fx") != 0 || name.find('.') != std::string::npos) continue;
        const long long v = std::isfinite(value) ? static_cast<long long>(value + 0.5) : 0;
        bool found = false;
        for (auto& s : slots)
            if (s.first == name) s.second = v, found = true;
        if (!found) slots.emplace_back(name, v);
    }
    std::sort(slots.begin(), slots.end());
    std::string key = spec.id;
    for (const auto& [name, v] : slots)
        if (v != 0) key += "|" + name + "=" + std::to_string(v);
    return key;
}

namespace fx {

namespace {
constexpr float kSilent = 3.1622777e-6f;  // -110 dB
constexpr PortDescriptor eventIn(std::string_view id) noexcept {
    PortDescriptor p;
    p.id = id;
    p.type = PortType::Event;
    p.input = true;
    return p;
}
constexpr PortDescriptor kPlainPorts[] = {stereoInput("in"), stereoOutput("out")};
constexpr PortDescriptor kKeyedPorts[] = {stereoInput("in"), stereoInput("sidechain"), eventIn("key_notes"),
                                          stereoOutput("out")};
constexpr std::string_view kPolarities[] = {"Unipolar", "Bipolar"};

bool stereoAudio(const PortDescriptor& p) noexcept {
    return p.type == PortType::Audio && p.layout == ChannelLayout::Stereo && portChannelCount(p) == 2;
}
bool plainStereoEffect(const ModuleDescriptor& d) noexcept {
    return d.portCount == 2 && d.ports && stereoAudio(d.ports[0]) && d.ports[0].input && stereoAudio(d.ports[1]) &&
           !d.ports[1].input;
}
uint32_t stateWord(const uint8_t* p) noexcept {
    return static_cast<uint32_t>(p[0]) | static_cast<uint32_t>(p[1]) << 8 | static_cast<uint32_t>(p[2]) << 16 |
           static_cast<uint32_t>(p[3]) << 24;
}
void putWord(uint8_t* p, uint32_t v) noexcept {
    p[0] = static_cast<uint8_t>(v), p[1] = static_cast<uint8_t>(v >> 8), p[2] = static_cast<uint8_t>(v >> 16),
    p[3] = static_cast<uint8_t>(v >> 24);
}
constexpr uint32_t kStateMagic = 0x4b434152u;  // "RACK"
}  // namespace

// ---------- The layout ----------

void RackLayout::finish(std::string_view id, std::string_view name, bool keyedPorts, bool hasMatrix) {
    this->id = id;
    this->name = name;
    keyed = keyedPorts;
    matrix = hasMatrix;
    for (Slot& s : slots) {
        s.fx = own.index(s.name + "_fx");
        s.on = own.index(s.name + "_on");
    }
    // Every own parameter steers the rack itself: a route moves only the children's knobs.
    for (uint32_t k = 0; k < own.size(); ++k) const_cast<ParameterDescriptor*>(own.data())[k].modulatable = false;
    staticBuild.make(*this, {});
}

void RackLayout::Built::make(const RackLayout& layout, const std::vector<const ModuleDescriptor*>& children) {
    strings.clear();
    params.clear();
    dstLabels.clear();
    const uint32_t own = layout.own.size();
    params.assign(layout.own.data(), layout.own.data() + own);
    childFirst.assign(layout.slots.size(), 0);
    uint64_t stateBytes = 8;
    uint32_t tail = 0;
    for (size_t s = 0; s < layout.slots.size(); ++s) {
        childFirst[s] = static_cast<uint32_t>(params.size());
        stateBytes += 12;
        const ModuleDescriptor* d = s < children.size() ? children[s] : nullptr;
        if (!d) continue;
        stateBytes += d->maxStateBytes;
        tail = std::max(tail, d->tailFrames);
        for (uint32_t k = 0; k < d->parameterCount; ++k) {
            ParameterDescriptor p = d->parameters[k];
            strings.push_back(layout.slots[s].name + "." + std::string(p.id));
            p.id = strings.back();
            strings.push_back(layout.slots[s].label + " " + std::string(p.name.empty() ? p.id : p.name));
            p.name = strings.back();
            params.push_back(p);
        }
    }
    modBase = static_cast<uint32_t>(params.size());
    if (layout.matrix) {
        dstLabels.push_back("None");
        for (uint32_t k = 0; k < modBase; ++k) dstLabels.push_back(params[k].name.empty() ? params[k].id : params[k].name);
        for (uint32_t s = 0; s < kRackRoutes; ++s) {
            const std::string p = "mod" + std::to_string(s + 1) + "_", n = "Mod " + std::to_string(s + 1) + " ";
            auto add = [&](std::string id, std::string nm, double lo, double hi) -> ParameterDescriptor& {
                strings.push_back(std::move(id));
                ParameterDescriptor q;
                q.id = strings.back();
                strings.push_back(std::move(nm));
                q.name = strings.back();
                q.minimum = lo;
                q.maximum = hi;
                q.modulatable = false;
                params.push_back(q);
                return params.back();
            };
            ParameterDescriptor& src = add(p + "src", n + "source", 0, kRackSourceCount - 1);
            src.step = 1, src.choices = kRackSources, src.choiceCount = kRackSourceCount;
            ParameterDescriptor& dst = add(p + "dst", n + "destination", 0, static_cast<double>(modBase));
            dst.step = 1, dst.choices = dstLabels.data(), dst.choiceCount = static_cast<uint32_t>(dstLabels.size());
            ParameterDescriptor& amt = add(p + "amt", n + "amount", -1, 1);
            amt.smoothingFrames = 480;
            ParameterDescriptor& bip = add(p + "bipolar", n + "polarity", 0, 1);
            bip.step = 1, bip.choices = kPolarities, bip.choiceCount = 2;
        }
    }
    desc = ModuleDescriptor{};
    desc.id = layout.id;
    desc.name = layout.name;
    desc.role = ModuleRole::Effect;
    desc.ports = layout.keyed ? kKeyedPorts : kPlainPorts;
    desc.portCount = layout.keyed ? 4 : 2;
    desc.parameters = params.data();
    desc.parameterCount = static_cast<uint32_t>(params.size());
    desc.tailFrames = tail;
    desc.maxStateBytes = static_cast<uint32_t>(std::min<uint64_t>(stateBytes, 64u << 20));
}

// ---------- The container ----------

bool RackBase::configure(const ModuleRegistry& registry, const std::vector<std::pair<std::string, double>>& params,
                         bool lenient, std::string& error) {
    const RackLayout& L = layout();
    slots_.clear();
    slots_.resize(L.slots.size());
    std::vector<const ModuleDescriptor*> descs(L.slots.size(), nullptr);
    std::vector<const ModuleDescriptor*> builtins = registry.builtinComponents();
    for (size_t s = 0; s < L.slots.size(); ++s) {
        double v = 0.0;
        for (const auto& [name, value] : params)
            if (name == L.slots[s].name + "_fx") v = value;
        const uint32_t hash = std::isfinite(v) && v > 0.0 ? static_cast<uint32_t>(v + 0.5) : 0u;
        if (hash == 0) continue;
        const ModuleDescriptor* found = nullptr;
        for (const ModuleDescriptor* d : builtins)
            if (rackChildHash(d->id) == hash) found = d;
        std::string why;
        if (!found) why = "names no built-in effect";
        else if (isRackId(found->id)) why = "can't hold a rack (racks don't nest)";
        else if (!plainStereoEffect(*found) && !ComponentChain::isKeyedEffect(*found)) why = "can only hold a stereo effect";
        if (why.empty()) {
            slots_[s].processor = registry.create(found->id);
            if (!slots_[s].processor) why = "could not create its effect";
        }
        if (!why.empty()) {
            if (lenient) continue;
            error = std::string(L.id) + " slot " + L.slots[s].name + " " + why;
            slots_.clear();
            return false;
        }
        const ModuleDescriptor& own = slots_[s].processor->descriptor();
        descs[s] = &own;
        slots_[s].keyed = ComponentChain::isKeyedEffect(own);
        for (uint32_t k = 0; k < own.portCount; ++k)
            slots_[s].keyEvents = slots_[s].keyEvents || (own.ports[k].type == PortType::Event && own.ports[k].input);
        slots_[s].variable = dynamic_cast<const VariableLatency*>(slots_[s].processor.get());
    }
    built_.make(L, descs);
    for (size_t s = 0; s < slots_.size(); ++s) {
        slots_[s].first = built_.childFirst[s];
        slots_[s].count = descs[s] ? descs[s]->parameterCount : 0;
    }
    configured_ = true;
    return true;
}

uint32_t RackBase::childLatencyCap(const Slot& s, double sampleRate) const noexcept {
    if (!s.processor) return 0;
    const ModuleDescriptor& d = s.processor->descriptor();
    uint32_t cap = d.latencyFrames;
    if (s.variable) {
        std::vector<double> values(d.parameterCount);
        for (uint32_t k = 0; k < d.parameterCount; ++k) values[k] = d.parameters[k].defaultValue;
        cap = std::max(cap, s.variable->latencyFor(values.data(), d.parameterCount));
        // [Assumption] a variable latency stays within 20 ms (the ducker's look-ahead is at most 10 ms).
        cap = std::max(cap, static_cast<uint32_t>(0.02 * sampleRate) + 1);
    }
    return cap;
}

uint32_t RackBase::childLatency(const Slot& s, const double* values, uint32_t count) const noexcept {
    if (!s.processor) return 0;
    uint32_t n = s.processor->descriptor().latencyFrames;
    if (s.variable && s.first + s.count <= count) n = s.variable->latencyFor(values + s.first, s.count);
    return std::min(n, s.latencyCap);
}

bool RackBase::activate(double sampleRate, uint32_t maxFrames) noexcept {
    rate_ = sampleRate > 0.0 ? sampleRate : 48000.0;
    maxFrames_ = std::max<uint32_t>(maxFrames, kRackControlFrames);
    quality_ = buildingQuality();
    clock_.prepare(rate_, 60.0);
    display_.clear();
    try {
        const uint32_t total = descriptor().parameterCount;
        childValues_.assign(total, ParameterValue{});
        latencyValues_.assign(total, 0.0);
        events_.assign(kMaxChunkEvents, Event{});
        for (Slot& s : slots_) {
            if (!s.processor) continue;
            if (!s.processor->activate(rate_, kRackControlFrames)) return false;
            s.active = true;
            s.latencyCap = childLatencyCap(s, rate_);
        }
        if (!prepare(rate_)) return false;
    } catch (...) {
        return false;
    }
    reset();
    return true;
}

void RackBase::deactivate() noexcept {
    for (Slot& s : slots_)
        if (s.processor && s.active) s.processor->deactivate(), s.active = false;
}

RackBase::~RackBase() { deactivate(); }

void RackBase::reset() noexcept {
    for (Slot& s : slots_) {
        if (s.processor) s.processor->reset();
        s.mix = -1.0;  // the first block takes the slot's switch as it stands
    }
    clearState();
    idle_ = true;
    left_ = 0;
    silent_ = 0;
    inPeak_ = outPeak_ = 0.0;
}

uint32_t RackBase::readChildDisplay(uint32_t child, float* out, uint32_t max) const noexcept {
    if (child >= slots_.size() || !slots_[child].processor) return 0;
    return slots_[child].processor->readDisplay(out, max);
}

bool RackBase::saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept {
    written = 0;
    if (!destination || capacity < 8) return false;
    putWord(destination, kStateMagic);
    putWord(destination + 4, static_cast<uint32_t>(slots_.size()));
    uint32_t at = 8;
    for (const Slot& s : slots_) {
        if (capacity - at < 12) return false;
        uint32_t n = 0;
        bool ok = false;
        if (s.processor) ok = s.processor->saveState(destination + at + 12, capacity - at - 12, n);
        if (!ok) n = 0;
        putWord(destination + at, ok && s.processor ? 1u : 0u);
        putWord(destination + at + 4, s.processor ? s.processor->stateVersion() : 1u);
        putWord(destination + at + 8, n);
        at += 12 + n;
    }
    written = at;
    return true;
}

bool RackBase::loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept {
    if (version != 1) return false;
    if (size == 0) return true;
    if (!source || size < 8 || stateWord(source) != kStateMagic || stateWord(source + 4) != slots_.size()) return false;
    uint32_t at = 8;
    for (Slot& s : slots_) {
        if (size - at < 12) return false;
        const uint32_t has = stateWord(source + at), v = stateWord(source + at + 4), n = stateWord(source + at + 8);
        if (n > size - at - 12) return false;
        if (has && s.processor && !s.processor->loadState(source + at + 12, n, v)) return false;
        at += 12 + n;
    }
    return at == size;
}

const Event* RackBase::chunkEvents(uint32_t at, uint32_t n, uint32_t& count) noexcept {
    count = 0;
    for (uint32_t k = 0; k < keyNotes_.count && count < events_.size(); ++k) {
        const Event& e = keyNotes_.events[k];
        if (e.frame < at || e.frame >= at + n) continue;
        events_[count] = e;
        events_[count].frame -= at;
        ++count;
    }
    return events_.data();
}

void RackBase::sliceChildValues(uint32_t at) noexcept {
    const uint32_t n = std::min<uint32_t>(static_cast<uint32_t>(childValues_.size()), block_ ? blockParamCount_ : 0);
    for (uint32_t k = 0; k < n; ++k) {
        const ParameterValue& v = blockParams_[k];
        childValues_[k] = v.samples ? ParameterValue{v.samples + at, v.samples[at]} : v;
    }
    const ModuleDescriptor& d = descriptor();
    for (uint32_t k = n; k < childValues_.size(); ++k) childValues_[k] = ParameterValue{nullptr, d.parameters[k].defaultValue};
}

void RackBase::runChild(Slot& s, const float* inL, const float* inR, float* outL, float* outR, uint32_t n, uint32_t at) noexcept {
    const double target = s.processor && on(static_cast<uint32_t>(layout().slots[&s - slots_.data()].on), at) ? 1.0 : 0.0;
    if (s.mix < 0.0) s.mix = target;
    if (!s.processor || (s.mix == 0.0 && target == 0.0)) {
        std::copy_n(inL, n, outL);
        std::copy_n(inR, n, outR);
        return;
    }
    if (s.mix == 0.0) s.processor->reset();  // back from off: nothing from before
    uint32_t eventCount = 0;
    const Event* ev = s.keyEvents ? chunkEvents(at, n, eventCount) : nullptr;
    const bool steadyOn = s.mix == 1.0 && target == 1.0;
    if (steadyOn && s.processor->quiet() && eventCount == 0 && peakAbs(inL, n) == 0.0f && peakAbs(inR, n) == 0.0f) {
        std::fill_n(outL, n, 0.0f);  // asleep, and still silence coming in
        std::fill_n(outR, n, 0.0f);
        return;
    }
    const float* in[2] = {inL, inR};
    float* out[2] = {outL, outR};
    Transport t;
    if (transport_) {
        t = *transport_;
        t.beat += static_cast<double>(at) * t.tempo / (60.0 * rate_);
    }
    bool done;
    if (s.keyed) {
        static const float silence[kRackControlFrames] = {};
        const float* key[2] = {keyL_ ? keyL_ + at : silence, keyR_ ? keyR_ + at : silence};
        const ConstChannelBufferView audioIn[2] = {{in, 2, n}, {key, 2, n}};
        const ChannelBufferView audioOut{out, 2, n};
        const EventInput events{ev, eventCount};
        ProcessBlock ports;
        ports.frames = n;
        ports.sampleRate = rate_;
        ports.audioIn = audioIn;
        ports.audioInCount = 2;
        ports.audioOut = &audioOut;
        ports.audioOutCount = 1;
        ports.eventIn = s.keyEvents ? &events : nullptr;
        ports.eventInCount = s.keyEvents ? 1 : 0;
        ports.parameters = s.count ? childValues_.data() + s.first : nullptr;
        ports.parameterCount = s.count;
        ports.transport = transport_ ? &t : nullptr;
        done = s.processor->usesProcessPorts() && s.processor->processPorts(ports);
    } else {
        AudioProcessBlock block;
        block.input = {in, 2, n};
        block.output = {out, 2, n};
        block.frames = n;
        block.sampleRate = rate_;
        block.parameters = s.count ? childValues_.data() + s.first : nullptr;
        block.parameterCount = s.count;
        block.transport = transport_ ? &t : nullptr;
        done = s.processor->process(block);
    }
    if (!done) {
        std::copy_n(inL, n, outL);
        std::copy_n(inR, n, outR);
    }
    for (uint32_t i = 0; i < n; ++i) outL[i] = std::isfinite(outL[i]) ? outL[i] : 0.0f;
    for (uint32_t i = 0; i < n; ++i) outR[i] = std::isfinite(outR[i]) ? outR[i] : 0.0f;
    if (s.mix != target || target != 1.0) {
        const double step = 1.0 / (0.005 * rate_);
        for (uint32_t i = 0; i < n; ++i) {
            s.mix = target > s.mix ? std::min(target, s.mix + step) : std::max(target, s.mix - step);
            const float w = static_cast<float>(s.mix);
            outL[i] = inL[i] + (outL[i] - inL[i]) * w;
            outR[i] = inR[i] + (outR[i] - inR[i]) * w;
        }
    }
}

bool RackBase::childrenQuiet() const noexcept {
    for (const Slot& s : slots_)
        if (s.processor && s.mix != 0.0 && !s.processor->quiet()) return false;
    return true;
}

bool RackBase::processPorts(const ProcessBlock& b) noexcept {
    if (!layout().keyed || b.audioInCount < 1 || b.audioOutCount != 1) return false;
    const bool key = b.audioInCount >= 2 && b.audioIn[1].channelCount == 2 && b.audioIn[1].valid() &&
                     b.audioIn[1].frames >= b.frames;
    keyL_ = key ? b.audioIn[1].channels[0] : nullptr;
    keyR_ = key ? b.audioIn[1].channels[1] : nullptr;
    keyNotes_ = b.eventInCount > 0 && b.eventIn ? b.eventIn[0] : EventInput{};
    AudioProcessBlock block;
    block.input = b.audioIn[0];
    block.output = b.audioOut[0];
    block.frames = b.frames;
    block.sampleRate = b.sampleRate;
    block.parameters = b.parameters;
    block.parameterCount = b.parameterCount;
    block.transport = b.transport;
    const bool done = run(block);
    keyL_ = keyR_ = nullptr;
    keyNotes_ = EventInput{};
    return done;
}

bool RackBase::process(const AudioProcessBlock& b) noexcept {
    keyL_ = keyR_ = nullptr;
    keyNotes_ = EventInput{};
    return run(b);
}

bool RackBase::run(const AudioProcessBlock& b) noexcept {
    if (b.input.channelCount != 2 || b.output.channelCount != 2 || !audioProcessBlockValid(b)) return false;
    block_ = &b;
    blockParams_ = b.parameters;
    blockParamCount_ = b.parameters ? b.parameterCount : 0;
    transport_ = b.transport;
    if (b.transport) tempo_ = b.transport->tempo > 1.0 ? b.transport->tempo : 1.0;
    const float* inL = b.input.channels[0];
    const float* inR = b.input.channels[1];
    float* outL = b.output.channels[0];
    float* outR = b.output.channels[1];
    const uint64_t idleAfter = static_cast<uint64_t>(0.05 * rate_);
    bool fellAsleep = false;
    for (uint32_t i = 0; i < b.frames;) {
        if (idle_) {
            uint32_t from = i;
            while (i < b.frames && inL[i] == 0.0f && inR[i] == 0.0f) outL[i] = outR[i] = 0.0f, ++i;
            idleEvents(from, i - from);
            if (i == b.frames) break;
            idle_ = false;  // woken: the grid starts here
            left_ = 0;
            silent_ = 0;
        }
        if (left_ == 0) {
            control(i);
            left_ = kRackControlFrames;
        }
        const uint32_t n = std::min(left_, b.frames - i);
        bool zero[kRackControlFrames];
        double inPeak = inPeak_;
        for (uint32_t k = 0; k < n; ++k) {
            const float l = inL[i + k], r = inR[i + k];
            zero[k] = l == 0.0f && r == 0.0f;
            inPeak = std::max(inPeak, static_cast<double>(std::max(std::fabs(l), std::fabs(r))));
        }
        inPeak_ = inPeak;
        // The input may alias the output (a host's in-place block): chunk() reads it into its own buffers first.
        chunk(inL + i, inR + i, outL + i, outR + i, n, i);
        double outPeak = outPeak_;
        for (uint32_t k = 0; k < n; ++k) {
            const float a = std::max(std::fabs(outL[i + k]), std::fabs(outR[i + k]));
            outPeak = std::max(outPeak, static_cast<double>(a));
            silent_ = zero[k] && a < kSilent ? silent_ + 1 : 0;
        }
        outPeak_ = outPeak;
        left_ -= n;
        i += n;
        if (left_ == 0 && silent_ >= idleAfter && childrenQuiet() && canSleep()) {  // at a grid point
            clearState();
            for (Slot& s : slots_)
                if (s.processor) s.processor->reset();
            idle_ = true;
            silent_ = 0;
            fellAsleep = true;
        }
    }
    bool publish = clock_.tick(b.frames);
    if (publish && qualityNow(quality_) == kQualityEco) publish = (skipPublish_ = !skipPublish_);
    if (publish || fellAsleep) {
        const uint32_t n = fillDisplay(shown_, display_.watched());
        display_.publish(shown_, std::min<uint32_t>(n, kRackDisplayFloats));
        inPeak_ = outPeak_ = 0.0;
    }
    block_ = nullptr;
    blockParams_ = nullptr;
    transport_ = nullptr;
    return true;
}

uint32_t RackBase::latencyFor(const double* values, uint32_t count) const noexcept {
    return latencyOf(values, count);
}

double RackBase::paramAt(uint32_t k, uint32_t at) const noexcept {
    if (!blockParams_ || k >= blockParamCount_) return descriptor().parameters[k].defaultValue;
    const ParameterValue& v = blockParams_[k];
    return v.samples ? v.samples[at] : v.value;
}

void RackBase::currentLatencyValues(uint32_t at) noexcept {
    const uint32_t n = static_cast<uint32_t>(latencyValues_.size());
    for (uint32_t k = 0; k < n; ++k) latencyValues_[k] = paramAt(k, at);
}

// ---------- Registration ----------

void registerRacks(ModuleRegistry& registry) {
    registerFxRack(registry);
    registerMultibandRack(registry);
}

}  // namespace fx
}  // namespace caw
