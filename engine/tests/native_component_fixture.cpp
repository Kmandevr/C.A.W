// Shared-library fixture for the explicit-trust ModuleRegistry loading tests.
#include <atomic>
#include <cstring>
#include <new>

#include <caw/component.hpp>
#include <caw/instrument.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"audio_in", caw::PortType::Audio, caw::ChannelLayout::Stereo, true, 0, false, 0.0f},
    {"audio_out", caw::PortType::Audio, caw::ChannelLayout::Stereo, false, 0, false, 0.0f},
};

const caw::ModuleDescriptor kDescriptor{
    "org.caw.tests.native-loader",
    1,
    kPorts,
    2,
    nullptr,
    0,
    nullptr,
    0,
    {},
};

class TestNativeProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }

    void process(const caw::StereoProcessBlock& block) noexcept override {
        if (!block.outputLeft || !block.outputRight) return;
        for (uint32_t frame = 0; frame < block.frames; ++frame) {
            block.outputLeft[frame] = block.inputLeft ? block.inputLeft[frame] * 2.0f : 0.0f;
            block.outputRight[frame] = block.inputRight ? block.inputRight[frame] * 2.0f : 0.0f;
        }
    }
};

// The bundle's second component: halves its input.
const caw::ModuleDescriptor kHalfDescriptor{"org.caw.tests.native-loader.half", 1, kPorts, 2, nullptr, 0, nullptr, 0, {}};

class HalfProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kHalfDescriptor; }

    void process(const caw::StereoProcessBlock& block) noexcept override {
        if (!block.outputLeft || !block.outputRight) return;
        for (uint32_t frame = 0; frame < block.frames; ++frame) {
            block.outputLeft[frame] = block.inputLeft ? block.inputLeft[frame] * 0.5f : 0.0f;
            block.outputRight[frame] = block.inputRight ? block.inputRight[frame] * 0.5f : 0.0f;
        }
    }
};

// The bundle's third component: separate left and right gains, so tests can tell the sides apart
// and set parameters. "left" ramps over 8 frames; "right" jumps.
caw::ParameterDescriptor gainParameter(std::string_view id, uint32_t smoothing) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.defaultValue = 1.0;
    p.minimum = 0.0;
    p.maximum = 4.0;
    p.smoothingFrames = smoothing;
    return p;
}
const caw::ParameterDescriptor kGainParameters[] = {gainParameter("left", 8), gainParameter("right", 0)};
caw::ModuleDescriptor gainDescriptor() {
    caw::ModuleDescriptor d{"org.caw.tests.native-loader.gain", 1, kPorts, 2, kGainParameters, 2, nullptr, 0, {}};
    d.maxStateBytes = 8;  // its state: how many blocks it has processed (a stand-in for a tail or a buffer)
    return d;
}
const caw::ModuleDescriptor kGainDescriptor = gainDescriptor();

class GainProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kGainDescriptor; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& block) noexcept override {
        if (block.input.channelCount != 2 || block.output.channelCount != 2) return false;
        for (uint32_t c = 0; c < 2; ++c) {
            double fixed = 1.0;
            const double* samples = nullptr;
            if (block.parameterCount == 2) {
                fixed = block.parameters[c].value;
                samples = block.parameters[c].samples;
            }
            for (uint32_t i = 0; i < block.frames; ++i)
                block.output.channels[c][i] =
                    static_cast<float>(block.input.channels[c][i] * (samples ? samples[i] : fixed));
        }
        const uint64_t n = blocks_.fetch_add(1, std::memory_order_relaxed) + 1;
        // Display data (caw.display.v1), every block: {blocks processed, the block's left output peak}.
        float peak = 0.0f;
        for (uint32_t i = 0; i < block.frames; ++i) {
            const float v = block.output.channels[0][i] < 0 ? -block.output.channels[0][i] : block.output.channels[0][i];
            peak = v > peak ? v : peak;
        }
        const float shown[2] = {static_cast<float>(n), peak};
        display_.publish(shown, 2);
        return true;
    }
    uint32_t readDisplay(float* out, uint32_t max) const noexcept override { return display_.read(out, max); }
    void reset() noexcept override { blocks_.store(0, std::memory_order_relaxed); }
    uint32_t stateVersion() const noexcept override { return 7; }
    // Safe while processing: the count is atomic.
    bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept override {
        if (capacity < 8) return false;
        const uint64_t n = blocks_.load(std::memory_order_relaxed);
        std::memcpy(destination, &n, 8);
        written = 8;
        return true;
    }
    bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept override {
        if (size != 8 || version != 7) return false;
        uint64_t n = 0;
        std::memcpy(&n, source, 8);
        blocks_.store(n, std::memory_order_relaxed);
        return true;
    }

private:
    std::atomic<uint64_t> blocks_{0};
    caw::DisplayBuffer<2> display_;
};

// The bundle's fourth component: a feedback echo (240 frames, feedback 0.5) with a declared tail, so
// tests can hear it ring out after Stop.
caw::ModuleDescriptor echoDescriptor() {
    caw::ModuleDescriptor d{"org.caw.tests.native-loader.echo", 1, kPorts, 2, nullptr, 0, nullptr, 0, {}};
    d.tailFrames = 48000;
    return d;
}
const caw::ModuleDescriptor kEchoDescriptor = echoDescriptor();

class EchoProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kEchoDescriptor; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& block) noexcept override {
        if (block.input.channelCount != 2 || block.output.channelCount != 2) return false;
        for (uint32_t i = 0; i < block.frames; ++i) {
            for (uint32_t c = 0; c < 2; ++c) {
                const float delayed = line_[c][pos_];
                const float y = block.input.channels[c][i] + 0.5f * delayed;
                line_[c][pos_] = y;
                block.output.channels[c][i] = y;
            }
            pos_ = (pos_ + 1) % kLength;
        }
        return true;
    }
    void reset() noexcept override {
        for (auto& l : line_) for (float& v : l) v = 0.0f;
        pos_ = 0;
    }

private:
    static constexpr uint32_t kLength = 240;
    float line_[2][kLength] = {};
    uint32_t pos_ = 0;
};

// The bundle's fifth component: delays its input by 100 frames and declares that latency.
caw::ModuleDescriptor lateDescriptor() {
    caw::ModuleDescriptor d{"org.caw.tests.native-loader.late", 1, kPorts, 2, nullptr, 0, nullptr, 0, {}};
    d.latencyFrames = 100;
    return d;
}
const caw::ModuleDescriptor kLateDescriptor = lateDescriptor();

class LateProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kLateDescriptor; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& block) noexcept override {
        if (block.input.channelCount != 2 || block.output.channelCount != 2) return false;
        for (uint32_t i = 0; i < block.frames; ++i) {
            for (uint32_t c = 0; c < 2; ++c) {
                const float x = block.input.channels[c][i];
                block.output.channels[c][i] = line_[c][pos_];
                line_[c][pos_] = x;
            }
            pos_ = (pos_ + 1) % 100;
        }
        return true;
    }

private:
    float line_[2][100] = {};
    uint32_t pos_ = 0;
};

// The bundle's sixth component: a drone that never goes quiet, declaring a 0.1 s tail, so tests can
// see a tail reach its cap while still audible.
caw::ModuleDescriptor droneDescriptor() {
    caw::ModuleDescriptor d{"org.caw.tests.native-loader.drone", 1, kPorts, 2, nullptr, 0, nullptr, 0, {}};
    d.tailFrames = 4800;
    return d;
}
const caw::ModuleDescriptor kDroneDescriptor = droneDescriptor();

class DroneProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDroneDescriptor; }
    void process(const caw::StereoProcessBlock& block) noexcept override {
        for (uint32_t i = 0; i < block.frames; ++i) block.outputLeft[i] = block.outputRight[i] = 0.5f;
    }
};

// The bundle's seventh component: reports the transport it sees, left the tempo / 1000 and right the
// song position in beats / 100 (-1 on both without a transport).
const caw::ModuleDescriptor kTransportDescriptor{"org.caw.tests.native-loader.transport", 1, kPorts, 2, nullptr, 0,
                                                 nullptr, 0, {}};

class TransportProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kTransportDescriptor; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& block) noexcept override {
        const caw::Transport* t = block.transport;
        for (uint32_t i = 0; i < block.frames; ++i) {
            block.output.channels[0][i] = t ? static_cast<float>(t->tempo / 1000.0) : -1.0f;
            block.output.channels[1][i] = t ? static_cast<float>(t->beat / 100.0) : -1.0f;
        }
        return true;
    }
};


// The bundle's eighth component: an instrument that records every note event it gets (the absolute
// frame since activate or reset, its type, note id, pitch and velocity) and saves the list as its
// state, so tests can check what reached it and when. Left plays 0.1 per held note times `level`;
// right plays the last pitch / 128.
constexpr caw::PortDescriptor kRecorderPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};
caw::ParameterDescriptor levelParameter() {
    caw::ParameterDescriptor p;
    p.id = "level";
    p.defaultValue = 1.0;
    p.minimum = 0.0;
    p.maximum = 4.0;
    return p;
}
const caw::ParameterDescriptor kRecorderParameters[] = {levelParameter()};
struct Recorded {
    uint64_t frame;
    uint32_t noteId;
    uint32_t type;  // caw::NoteMessageType
    float pitch, velocity;
};
constexpr uint32_t kMaxRecorded = 256;
caw::ModuleDescriptor recorderDescriptor() {
    caw::ModuleDescriptor d{"org.caw.tests.native-loader.recorder", 1, kRecorderPorts, 2, kRecorderParameters, 1,
                            nullptr, 0, {}};
    d.role = caw::ModuleRole::Instrument;
    d.maxStateBytes = 4 + kMaxRecorded * sizeof(Recorded);
    return d;
}
const caw::ModuleDescriptor kRecorderDescriptor = recorderDescriptor();

class RecorderProcessor final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kRecorderDescriptor; }
    bool usesProcessPorts() const noexcept override { return true; }
    bool processPorts(const caw::ProcessBlock& b) noexcept override {
        if (b.audioOutCount != 1 || b.audioOut[0].channelCount != 2) return false;
        const caw::Event* events = b.eventInCount ? b.eventIn[0].events : nullptr;
        const uint32_t count = events ? b.eventIn[0].count : 0;
        const double level = b.parameterCount ? b.parameters[0].value : 1.0;
        uint32_t e = 0;
        for (uint32_t i = 0; i < b.frames; ++i) {
            for (; e < count && events[e].frame <= i; ++e) {
                caw::NoteMessage m;
                caw::readNote(events[e], m);
                if (m.type == caw::NoteMessageType::On) ++held_;
                if (m.type == caw::NoteMessageType::Off && held_ > 0) --held_;
                if (m.type == caw::NoteMessageType::On || m.type == caw::NoteMessageType::Pitch) pitch_ = m.pitch;
                const uint32_t n = recorded_.load(std::memory_order_relaxed);
                if (n < kMaxRecorded) {
                    log_[n] = {frames_ + events[e].frame, m.noteId, static_cast<uint32_t>(m.type),
                               static_cast<float>(m.pitch), static_cast<float>(m.velocity)};
                    recorded_.store(n + 1, std::memory_order_release);
                }
            }
            b.audioOut[0].channels[0][i] = static_cast<float>(0.1 * held_ * level);
            b.audioOut[0].channels[1][i] = static_cast<float>(pitch_ / 128.0);
        }
        frames_ += b.frames;
        return true;
    }
    void reset() noexcept override {
        frames_ = 0;
        held_ = 0;
    }
    bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept override {
        const uint32_t n = recorded_.load(std::memory_order_acquire);
        if (capacity < 4 + n * sizeof(Recorded)) return false;
        std::memcpy(destination, &n, 4);
        std::memcpy(destination + 4, log_, n * sizeof(Recorded));
        written = 4 + n * static_cast<uint32_t>(sizeof(Recorded));
        return true;
    }
    bool loadState(const uint8_t* source, uint32_t size, uint32_t) noexcept override {
        uint32_t n = 0;
        if (size < 4) return false;
        std::memcpy(&n, source, 4);
        if (n > kMaxRecorded || size != 4 + n * sizeof(Recorded)) return false;
        std::memcpy(log_, source + 4, n * sizeof(Recorded));
        recorded_.store(n, std::memory_order_release);
        return true;
    }

private:
    Recorded log_[kMaxRecorded]{};
    std::atomic<uint32_t> recorded_{0};
    uint64_t frames_ = 0;
    int held_ = 0;
    double pitch_ = 0;
};

}  // namespace

#ifndef CAW_TEST_OMIT_ENTRY  // the second fixture plays a library without the v2 entry point
// A bundle of two components (owner, 2026-11-09: a package may hold several).
CAW_EXPORT_COMPONENTS(TestNativeProcessor, HalfProcessor, GainProcessor, EchoProcessor, LateProcessor, DroneProcessor, TransportProcessor,
                      RecorderProcessor)
#endif
