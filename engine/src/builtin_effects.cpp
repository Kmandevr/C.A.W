// The built-in effects suite (#173): the shared EffectBase (control grid, sleep, display) and registration.
#include "builtin_effects.h"

#include <algorithm>

namespace caw {
namespace fx {

namespace {
constexpr PortDescriptor kStereoPorts[] = {stereoInput("in"), stereoOutput("out")};
constexpr PortDescriptor eventInput(std::string_view id) noexcept {
    PortDescriptor p;
    p.id = id;
    p.type = PortType::Event;
    p.input = true;
    return p;
}
constexpr PortDescriptor kKeyedPorts[] = {stereoInput("in"), stereoInput("sidechain"), stereoOutput("out")};
constexpr PortDescriptor kKeyedNotePorts[] = {stereoInput("in"), stereoInput("sidechain"), eventInput("key_notes"),
                                              stereoOutput("out")};
constexpr float kSilent = 3.1622777e-6f;  // -110 dB
}  // namespace

ModuleDescriptor effectDescriptor(std::string_view id, std::string_view name, const ParamTable& params,
                                  uint32_t latencyFrames, uint32_t tailFrames) {
    ModuleDescriptor d;
    d.id = id;
    d.name = name;
    d.role = ModuleRole::Effect;
    d.ports = kStereoPorts;
    d.portCount = 2;
    d.parameters = params.data();
    d.parameterCount = params.size();
    d.latencyFrames = latencyFrames;
    d.tailFrames = tailFrames;
    return d;
}

ModuleDescriptor keyedEffectDescriptor(std::string_view id, std::string_view name, const ParamTable& params,
                                       uint32_t latencyFrames, uint32_t tailFrames, bool notes) {
    ModuleDescriptor d = effectDescriptor(id, name, params, latencyFrames, tailFrames);
    d.ports = notes ? kKeyedNotePorts : kKeyedPorts;
    d.portCount = notes ? 4 : 3;
    return d;
}

bool EffectBase::processPorts(const ProcessBlock& b) noexcept {
    if (!keyed_ || b.audioInCount < 1 || b.audioOutCount != 1) return false;
    AudioProcessBlock block;
    block.input = b.audioIn[0];
    block.output = b.audioOut[0];
    block.frames = b.frames;
    block.sampleRate = b.sampleRate;
    block.parameters = b.parameters;
    block.parameterCount = b.parameterCount;
    block.transport = b.transport;
    const bool key = b.audioInCount >= 2 && b.audioIn[1].channelCount == 2 && b.audioIn[1].valid() &&
                     b.audioIn[1].frames >= b.frames;
    keyL_ = key ? b.audioIn[1].channels[0] : nullptr;
    keyR_ = key ? b.audioIn[1].channels[1] : nullptr;
    keyNotes_ = b.eventInCount > 0 && b.eventIn ? b.eventIn[0] : EventInput{};
    const bool done = process(block);
    keyL_ = keyR_ = nullptr;
    keyNotes_ = EventInput{};
    return done;
}

bool EffectBase::activate(double sampleRate, uint32_t maxFrames) noexcept {
    rate_ = sampleRate > 0.0 ? sampleRate : 48000.0;
    keyed_ = false;
    const ModuleDescriptor& d = descriptor();
    for (uint32_t k = 0; k < d.portCount; ++k) keyed_ = keyed_ || (d.ports[k].input && d.ports[k].id == "sidechain");
    quality_ = buildingQuality();
    clock_.prepare(rate_, 60.0);
    display_.clear();
    if (!prepare(rate_, maxFrames)) return false;
    reset();
    return true;
}

void EffectBase::reset() noexcept {
    clearState();
    idle_ = true;
    left_ = 0;
    silent_ = 0;
    inPeak_ = outPeak_ = 0.0;
}

bool EffectBase::process(const AudioProcessBlock& b) noexcept {
    if (b.input.channelCount != 2 || b.output.channelCount != 2 || !audioProcessBlockValid(b)) return false;
    block_ = &b;
    if (b.transport) tempo_ = b.transport->tempo > 1.0 ? b.transport->tempo : 1.0;
    const float* inL = b.input.channels[0];
    const float* inR = b.input.channels[1];
    float* outL = b.output.channels[0];
    float* outR = b.output.channels[1];
    const uint64_t idleAfter = idleFrames();
    bool fellAsleep = false;
    for (uint32_t i = 0; i < b.frames;) {
        if (idle_) {
            while (i < b.frames && inL[i] == 0.0f && inR[i] == 0.0f) outL[i] = outR[i] = 0.0f, ++i;
            if (i == b.frames) break;
            idle_ = false;  // woken: the grid starts here
            left_ = 0;
            silent_ = 0;
        }
        if (left_ == 0) {
            control(i);
            left_ = kControlFrames;
        }
        const uint32_t n = std::min(left_, b.frames - i);
        bool zero[kControlFrames];
        double inPeak = inPeak_;
        for (uint32_t k = 0; k < n; ++k) {
            const float l = inL[i + k], r = inR[i + k];
            zero[k] = l == 0.0f && r == 0.0f;
            const double a = l < 0 ? -l : l, c = r < 0 ? -r : r;
            inPeak = std::max(inPeak, std::max(a, c));
        }
        inPeak_ = inPeak;
        runAt_ = i;
        run(inL + i, inR + i, outL + i, outR + i, n);
        double outPeak = outPeak_;
        for (uint32_t k = 0; k < n; ++k) {
            const float l = outL[i + k], r = outR[i + k];
            const float a = std::max(l < 0 ? -l : l, r < 0 ? -r : r);
            outPeak = std::max(outPeak, static_cast<double>(a));
            silent_ = zero[k] && a < kSilent ? silent_ + 1 : 0;
        }
        outPeak_ = outPeak;
        left_ -= n;
        i += n;
        if (left_ == 0 && silent_ >= idleAfter) {  // at a grid point: the same frame at any block size
            clearState();
            idle_ = true;
            silent_ = 0;
            fellAsleep = true;
        }
    }
    bool publish = clock_.tick(b.frames);
    if (publish && quality() == kQualityEco) publish = (skipPublish_ = !skipPublish_);  // Eco: 30 a second
    if (publish || fellAsleep) {
        const uint32_t n = fillDisplay(shown_, display_.watched());
        display_.publish(shown_, std::min<uint32_t>(n, kMaxDisplayFloats));
        inPeak_ = outPeak_ = 0.0;
    }
    block_ = nullptr;
    return true;
}

}  // namespace fx

void registerBuiltinEffects(ModuleRegistry& registry) {
    fx::registerEq(registry);
    fx::registerDynamics(registry);
    fx::registerSpace(registry);
    fx::registerSaturator(registry);
    fx::registerKit(registry);
    fx::registerDucker(registry);
}

}  // namespace caw
