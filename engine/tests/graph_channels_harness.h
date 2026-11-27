// Shared helpers for the graph executor tests (graph_*_test.cpp): channel shapes, generators, buses and typed-port modules.
#pragma once

#include "test.h"

#include "alloc_counter.h"
#include "graph.h"

#include <algorithm>
#include <bit>
#include <cstdint>
#include <cmath>
#include <limits>
#include <memory>
#include <string>
#include <vector>

namespace graph_channels_test {

using namespace caw;

constexpr GraphResourceBudget kBudget{
    std::numeric_limits<std::size_t>::max(),
    std::numeric_limits<std::size_t>::max(),
    64u * 1024u * 1024u,
};

// One module shape per channel layout: a generator (out only) and an effect (in + out).
struct ChannelModules {
    ChannelModules(ChannelLayout layout, uint32_t discrete)
        : sourcePorts{{"out", PortType::Audio, layout, false, discrete}},
          effectPorts{{"in", PortType::Audio, layout, true, discrete},
                      {"out", PortType::Audio, layout, false, discrete}},
          source{"test.channels.source", 1, sourcePorts, 1, nullptr, 0},
          effect{"test.channels.effect", 1, effectPorts, 2, nullptr, 0},
          channels(channelCountForLayout(layout, discrete)) {}
    ChannelModules(const ChannelModules&) = delete;
    ChannelModules& operator=(const ChannelModules&) = delete;
    PortDescriptor sourcePorts[1];
    PortDescriptor effectPorts[2];
    ModuleDescriptor source;
    ModuleDescriptor effect;
    uint32_t channels;
};

// Distinct, deterministic signal per channel: a channel-specific sine plus a channel tag.
inline float signal(uint32_t channel, uint32_t frame) noexcept {
    const double phase = static_cast<double>(frame) * 0.01 * static_cast<double>(channel + 1);
    return static_cast<float>(std::sin(phase) * 0.5 + static_cast<double>(channel) * 0.0625);
}

inline float gainFor(uint32_t channel) noexcept { return 0.5f + 0.25f * static_cast<float>(channel); }

// The sign bit, read from the bits: under the engine's -fno-signed-zeros (this file's flags) GCC may fold
// std::signbit(x) into x < 0, which is false for -0.0f.
inline bool signBit(float x) noexcept { return (std::bit_cast<uint32_t>(x) >> 31) != 0; }

// x through two gain nodes, each product rounded to float as the nodes do. The rounded first product goes through a
// volatile: this file builds with the engine's flags (-fassociative-math), which could otherwise fold the expected
// value into x * (gain * gain).
inline float twiceGained(float x, uint32_t channel) noexcept {
    volatile float once = x * gainFor(channel);
    return once * gainFor(channel);
}

class Generator final : public ModuleProcessor {
public:
    explicit Generator(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        if (block.input.channelCount != 0) return false;
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i) block.output.channels[c][i] = signal(c, i);
        return true;
    }
private:
    const ModuleDescriptor& d_;
};

class ChannelGain final : public ModuleProcessor {
public:
    explicit ChannelGain(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        if (block.input.channelCount != block.output.channelCount) return false;
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i)
                block.output.channels[c][i] = block.input.channels[c][i] * gainFor(c);
        return true;
    }
private:
    const ModuleDescriptor& d_;
};

// Negates exactly one channel and copies the others; proves channels never alias.
class TouchOneChannel final : public ModuleProcessor {
public:
    TouchOneChannel(const ModuleDescriptor& d, uint32_t channel) : d_(d), channel_(channel) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i)
                block.output.channels[c][i] = c == channel_ ? -block.input.channels[c][i]
                                                            : block.input.channels[c][i];
        return true;
    }
private:
    const ModuleDescriptor& d_;
    uint32_t channel_;
};

class Failing final : public ModuleProcessor {
public:
    explicit Failing(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock&) noexcept override { return false; }
private:
    const ModuleDescriptor& d_;
};

// Implements neither process overload: must fail loudly instead of leaving its buffer as-is.
class Unimplemented final : public ModuleProcessor {
public:
    explicit Unimplemented(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
private:
    const ModuleDescriptor& d_;
};

struct Planar {
    Planar(uint32_t channels, uint32_t frames, float fill = 0.0f)
        : data(channels, std::vector<float>(frames, fill)) {
        for (auto& channel : data) { pointers.push_back(channel.data()); constPointers.push_back(channel.data()); }
    }
    ChannelBufferView view(uint32_t frames) { return {pointers.data(), static_cast<uint32_t>(pointers.size()), frames}; }
    ConstChannelBufferView constView(uint32_t frames) const {
        return {constPointers.data(), static_cast<uint32_t>(constPointers.size()), frames};
    }
    std::vector<std::vector<float>> data;
    std::vector<float*> pointers;
    std::vector<const float*> constPointers;
};

struct LayoutCase { ChannelLayout layout; uint32_t discrete; uint32_t channels; };
const LayoutCase kLayouts[] = {
    {ChannelLayout::Mono, 0, 1},       {ChannelLayout::Stereo, 0, 2},
    {ChannelLayout::Quad, 0, 4},       {ChannelLayout::Surround51, 0, 6},
    {ChannelLayout::Surround71, 0, 8}, {ChannelLayout::Discrete, 3, 3},
};

// A 6-channel mix-bus shape: a summing input (fan-in) and one output.
struct BusModule {
    BusModule()
        : ports{{"in", PortType::Audio, ChannelLayout::Surround51, true, 0, true},
                {"out", PortType::Audio, ChannelLayout::Surround51, false}},
          bus{"test.channels.bus", 1, ports, 2, nullptr, 0} {}
    PortDescriptor ports[2];
    ModuleDescriptor bus;
};

// Generator with a per-instance offset so every source is distinct.
class OffsetGenerator final : public ModuleProcessor {
public:
    OffsetGenerator(const ModuleDescriptor& d, uint32_t offset) : d_(d), offset_(offset) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i) block.output.channels[c][i] = signal(c, i + offset_);
        return true;
    }
private:
    const ModuleDescriptor& d_;
    uint32_t offset_;
};

class Copy final : public ModuleProcessor {
public:
    explicit Copy(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool process(const AudioProcessBlock& block) noexcept override {
        for (uint32_t c = 0; c < block.output.channelCount; ++c)
            for (uint32_t i = 0; i < block.frames; ++i) block.output.channels[c][i] = block.input.channels[c][i];
        return true;
    }
private:
    const ModuleDescriptor& d_;
};

// Stereo shapes for dynamic-routing tests: a generator and a summing bus.
struct StereoRoutingModules {
    StereoRoutingModules()
        : sourcePorts{{"out", PortType::Audio, ChannelLayout::Stereo, false}},
          busPorts{{"in", PortType::Audio, ChannelLayout::Stereo, true, 0, true},
                   {"out", PortType::Audio, ChannelLayout::Stereo, false}},
          plainPorts{{"in", PortType::Audio, ChannelLayout::Stereo, true},
                     {"out", PortType::Audio, ChannelLayout::Stereo, false}},
          source{"test.route.src", 1, sourcePorts, 1, nullptr, 0},
          bus{"test.route.bus", 1, busPorts, 2, nullptr, 0},
          plain{"test.route.plain", 1, plainPorts, 2, nullptr, 0} {}
    PortDescriptor sourcePorts[1], busPorts[2], plainPorts[2];
    ModuleDescriptor source, bus, plain;
};

// F5.1 typed ports: processors that opt in to processPorts().
class Typed : public ModuleProcessor {
public:
    explicit Typed(const ModuleDescriptor& d) : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool usesProcessPorts() const noexcept override { return true; }
private:
    const ModuleDescriptor& d_;
};

// Mono modulation source: signal(channel tag, frame + offset) scaled, or a fixed value when set.
class ModSource final : public Typed {
public:
    ModSource(const ModuleDescriptor& d, uint32_t offset, float fixed = 0.0f, bool useFixed = false)
        : Typed(d), offset_(offset), fixed_(fixed), useFixed_(useFixed) {}
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.modulationOutCount != 1 || b.audioInCount || b.audioOutCount) return false;
        for (uint32_t i = 0; i < b.frames; ++i) b.modulationOut[0][i] = useFixed_ ? fixed_ : signal(0, i + offset_);
        return true;
    }
private:
    uint32_t offset_;
    float fixed_;
    bool useFixed_;
};

// Audio in x modulation in -> audio out, plus a mono sidechain added at x10 and a control level.
class Processor final : public Typed {
public:
    using Typed::Typed;
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.audioInCount != 2 || b.audioOutCount != 1 || b.modulationInCount != 1 || b.controlInCount != 1)
            return false;
        const ConstChannelBufferView& in = b.audioIn[0];
        const ConstChannelBufferView& side = b.audioIn[1];
        const float level = *b.controlIn[0];
        for (uint32_t c = 0; c < b.audioOut[0].channelCount; ++c)
            for (uint32_t i = 0; i < b.frames; ++i)
                b.audioOut[0].channels[c][i] =
                    (in.channels[c][i] * b.modulationIn[0][i] + side.channels[0][i] * 10.0f) * level;
        return true;
    }
};

// Writes its control output once (the first block) and never again: the value must hold.
class ControlSource final : public Typed {
public:
    ControlSource(const ModuleDescriptor& d, float value) : Typed(d), value_(value) {}
    bool processPorts(const ProcessBlock& b) noexcept override {
        if (b.controlOutCount != 1) return false;
        if (!written_) *b.controlOut[0] = value_;
        written_ = true;
        return true;
    }
private:
    float value_;
    bool written_ = false;
};

struct TypedModules {
    TypedModules()
        : modPorts{{"lfo", PortType::Modulation, ChannelLayout::None, false}},
          procPorts{{"in", PortType::Audio, ChannelLayout::Stereo, true},
                    {"amount", PortType::Modulation, ChannelLayout::None, true, 0, true},
                    {"side", PortType::Audio, ChannelLayout::Mono, true},
                    {"level", PortType::Control, ChannelLayout::None, true, 0, false, 0.75f},
                    {"out", PortType::Audio, ChannelLayout::Stereo, false}},
          monoPorts{{"out", PortType::Audio, ChannelLayout::Mono, false}},
          controlPorts{{"set", PortType::Control, ChannelLayout::None, false, 0, false, 0.5f}},
          mod{"test.typed.lfo", 1, modPorts, 1, nullptr, 0},
          proc{"test.typed.proc", 1, procPorts, 5, nullptr, 0},
          mono{"test.typed.mono", 1, monoPorts, 1, nullptr, 0},
          control{"test.typed.control", 1, controlPorts, 1, nullptr, 0} {}
    PortDescriptor modPorts[1], procPorts[5], monoPorts[1], controlPorts[1];
    ModuleDescriptor mod, proc, mono, control;
};
// Port indexes on `proc`.
constexpr uint32_t kIn = 0, kAmount = 1, kSide = 2, kLevel = 3, kOut = 4;

}  // namespace graph_channels_test
