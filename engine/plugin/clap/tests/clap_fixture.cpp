// Test bundle for the CLAP wrapper: an effect with parameters, state, latency and tail; an instrument with note input and output; a transport reader.
#include <atomic>
#include <cmath>
#include <cstring>

#include <caw/component.hpp>

namespace {

// ---- org.caw.tests.clap.drive: drive x shape, mixed with the dry signal, 3 frames late.

constexpr caw::PortDescriptor kStereoPorts[] = {caw::stereoInput("in"), caw::stereoOutput("out")};
constexpr std::string_view kShapes[] = {"Soft", "Hard", "Fold"};

caw::ParameterDescriptor driveParameter() {
    caw::ParameterDescriptor p;
    p.id = "drive";
    p.name = "Drive";
    p.unit = "x";
    p.minimum = 1.0;
    p.maximum = 8.0;
    p.defaultValue = 2.0;
    p.smoothingFrames = 16;
    return p;
}
caw::ParameterDescriptor shapeParameter() {
    caw::ParameterDescriptor p;
    p.id = "shape";
    p.name = "Shape";
    p.minimum = 0.0;
    p.maximum = 2.0;
    p.step = 1.0;
    p.choices = kShapes;
    p.choiceCount = 3;
    p.modulatable = false;
    return p;
}
caw::ParameterDescriptor mixParameter() {
    caw::ParameterDescriptor p;
    p.id = "mix";
    p.minimum = 0.0;
    p.maximum = 1.0;
    p.step = 0.01;
    p.defaultValue = 1.0;
    return p;
}
const caw::ParameterDescriptor kDriveParameters[] = {driveParameter(), shapeParameter(), mixParameter()};

caw::ModuleDescriptor driveDescriptor() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.tests.clap.drive";
    d.name = "Test drive";
    d.version = 3;
    d.role = caw::ModuleRole::Effect;
    d.ports = kStereoPorts;
    d.portCount = 2;
    d.parameters = kDriveParameters;
    d.parameterCount = 3;
    d.latencyFrames = 3;
    d.tailFrames = 1000;
    d.maxStateBytes = 8;
    return d;
}
const caw::ModuleDescriptor kDriveDescriptor = driveDescriptor();

class Drive final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDriveDescriptor; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& b) noexcept override {
        if (b.input.channelCount != 2 || b.output.channelCount != 2 || b.parameterCount != 3) return false;
        for (uint32_t i = 0; i < b.frames; ++i) {
            const double drive = b.parameters[0].samples ? b.parameters[0].samples[i] : b.parameters[0].value;
            const double shape = b.parameters[1].samples ? b.parameters[1].samples[i] : b.parameters[1].value;
            const double mix = b.parameters[2].samples ? b.parameters[2].samples[i] : b.parameters[2].value;
            for (uint32_t c = 0; c < 2; ++c) {
                const double x = b.input.channels[c][i];
                double y = x * drive;
                if (shape < 0.5) y = y / (1.0 + std::fabs(y));
                else if (shape < 1.5) y = y > 1.0 ? 1.0 : (y < -1.0 ? -1.0 : y);
                else y = std::sin(y);
                b.output.channels[c][i] = line_[c][pos_];
                line_[c][pos_] = static_cast<float>(mix * y + (1.0 - mix) * x);
            }
            pos_ = (pos_ + 1) % 3;
        }
        blocks_.fetch_add(1, std::memory_order_relaxed);
        return true;
    }
    void reset() noexcept override {
        std::memset(line_, 0, sizeof(line_));
        pos_ = 0;
    }
    uint32_t stateVersion() const noexcept override { return 5; }
    bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept override {
        if (capacity < 8) return false;
        const uint64_t n = blocks_.load(std::memory_order_relaxed);
        std::memcpy(destination, &n, 8);
        written = 8;
        return true;
    }
    bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept override {
        if (size != 8 || version != 5) return false;
        uint64_t n = 0;
        std::memcpy(&n, source, 8);
        blocks_.store(n, std::memory_order_relaxed);
        return true;
    }

private:
    float line_[2][3] = {};
    uint32_t pos_ = 0;
    std::atomic<uint64_t> blocks_{0};
};

// ---- org.caw.tests.clap.synth: plays the notes it gets and echoes every event.
// Left: the sum of the sounding notes' velocities / 10; right: the sum of their keys / 1280.

constexpr caw::PortDescriptor kSynthPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
    {"echo", caw::PortType::Event, caw::ChannelLayout::None, false, 0, false, 0.0f},
};

caw::ModuleDescriptor synthDescriptor() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.tests.clap.synth";
    d.name = "Test synth";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kSynthPorts;
    d.portCount = 3;
    return d;
}
const caw::ModuleDescriptor kSynthDescriptor = synthDescriptor();

class Synth final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kSynthDescriptor; }
    bool usesProcessPorts() const noexcept override { return true; }
    bool processPorts(const caw::ProcessBlock& b) noexcept override {
        if (b.audioOutCount != 1 || b.audioOut[0].channelCount != 2) return false;
        const caw::EventInput none;
        const caw::EventInput& in = b.eventInCount ? b.eventIn[0] : none;
        uint32_t next = 0;
        for (uint32_t i = 0; i < b.frames; ++i) {
            for (; next < in.count && in.events[next].frame <= i; ++next) take(in.events[next]);
            double left = 0.0, right = 0.0;
            for (const Voice& v : voices_)
                if (v.id) {
                    left += v.velocity / 10.0;
                    right += v.key / 1280.0;
                }
            b.audioOut[0].channels[0][i] = static_cast<float>(left);
            b.audioOut[0].channels[1][i] = static_cast<float>(right);
        }
        if (b.eventOutCount) {
            caw::EventOutput& out = b.eventOut[0];
            for (uint32_t e = 0; e < in.count && out.count < out.capacity; ++e) out.events[out.count++] = in.events[e];
        }
        return true;
    }
    void reset() noexcept override {
        for (Voice& v : voices_) v = Voice{};
    }

private:
    struct Voice {
        uint32_t id = 0, key = 0;
        double velocity = 0.0;
    };
    void take(const caw::Event& e) noexcept {
        if (e.kind != caw::EventKind::Note || (e.data[0] >> 28) != 0x4) return;
        const uint32_t status = (e.data[0] >> 20) & 0xF;
        if (status == 0x9) {
            for (Voice& v : voices_)
                if (!v.id) {
                    v = {e.noteId, (e.data[0] >> 8) & 0x7F, (e.data[1] >> 16) / 65535.0};
                    return;
                }
        } else if (status == 0x8) {
            for (Voice& v : voices_)
                if (v.id == e.noteId) v = Voice{};
        }
    }
    Voice voices_[16];
};

// ---- org.caw.tests.clap.transport: left the tempo / 1000, right the beat / 100 (-1 without a transport).

caw::ModuleDescriptor transportDescriptor() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.tests.clap.transport";
    d.role = caw::ModuleRole::Utility;
    d.ports = kStereoPorts;
    d.portCount = 2;
    return d;
}
const caw::ModuleDescriptor kTransportDescriptor = transportDescriptor();

class TransportReader final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kTransportDescriptor; }
    using caw::ModuleProcessor::process;
    bool process(const caw::AudioProcessBlock& b) noexcept override {
        const caw::Transport* t = b.transport;
        for (uint32_t i = 0; i < b.frames; ++i) {
            b.output.channels[0][i] = t ? static_cast<float>(t->tempo / 1000.0) : -1.0f;
            b.output.channels[1][i] = t ? static_cast<float>(t->beat / 100.0 + t->beatsPerBar / 1000.0) : -1.0f;
        }
        return true;
    }
};

}  // namespace

CAW_EXPORT_COMPONENTS(Drive, Synth, TransportReader)
