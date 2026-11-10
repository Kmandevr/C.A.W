// Example C.A.W. instrument: 8 voices of a sine or saw with an attack/release envelope, played by note events.
#include <cmath>
#include <string_view>

#include <caw/component.hpp>
#include <caw/instrument.hpp>

namespace {

// An instrument's ports: notes in, stereo out (no audio in).
constexpr caw::PortDescriptor kPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};

constexpr std::string_view kWaves[] = {"Sine", "Saw"};
caw::ParameterDescriptor wave() {
    caw::ParameterDescriptor p;
    p.id = "wave"; p.name = "Wave";
    p.minimum = 0; p.maximum = 1; p.step = 1; p.defaultValue = 1;
    p.choices = kWaves; p.choiceCount = 2;
    return p;
}
caw::ParameterDescriptor seconds(std::string_view id, std::string_view name, double def) {
    caw::ParameterDescriptor p;
    p.id = id; p.name = name; p.unit = "s";
    p.minimum = 0.001; p.maximum = 5; p.defaultValue = def;
    p.curve = caw::ParameterCurve::Exponential;
    return p;
}
caw::ParameterDescriptor volume() {
    caw::ParameterDescriptor p;
    p.id = "volume"; p.name = "Volume";
    p.minimum = 0; p.maximum = 1; p.defaultValue = 0.5;
    p.smoothingFrames = 480;  // a knob move glides over 10 ms at 48 kHz
    return p;
}
const caw::ParameterDescriptor kParams[] = {wave(), seconds("attack", "Attack", 0.01), seconds("release", "Release", 0.3), volume()};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.examples.poly-synth"; d.name = "Poly synth";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts; d.portCount = 2;
    d.parameters = kParams; d.parameterCount = 4;
    d.tailFrames = 5 * 192000;  // the longest release, at up to 192 kHz
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

class PolySynth final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        voices_.clear();
        return true;
    }
    void reset() noexcept override { voices_.clear(); }  // the host calls this so the next play starts silent

protected:
    // Each note message arrives on its own frame; the host's note id says which note it is about.
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type == caw::NoteMessageType::On) {
            Voice& v = voices_.start(m.noteId);  // a free voice, else the oldest one is stolen
            v.velocity = m.velocity;
            v.step = frequency(m.pitch) / rate_;
        } else if (Voice* v = voices_.find(m.noteId)) {
            if (m.type == caw::NoteMessageType::Off) v->held = false;                     // into its release
            if (m.type == caw::NoteMessageType::Pitch) v->step = frequency(m.pitch) / rate_;  // a glide or bend
        }
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        for (Voice& v : voices_) {
            if (!v.active) continue;
            for (uint32_t i = 0; i < frames; ++i) {
                const uint32_t at = offset + i;  // parameters are per frame of the whole block
                const bool saw = caw::parameterAt(b, 0, at, 1) > 0.5;
                const double attack = 1.0 / (caw::parameterAt(b, 1, at, 0.01) * rate_);
                const double release = 1.0 / (caw::parameterAt(b, 2, at, 0.3) * rate_);
                v.level = v.held ? std::fmin(1.0, v.level + attack) : v.level - release;
                if (v.level <= 0.0) {
                    v.active = false;
                    v.level = 0.0;
                    break;
                }
                const double osc = saw ? 2.0 * v.phase - 1.0 : std::sin(6.283185307179586 * v.phase);
                v.phase += v.step;
                v.phase -= std::floor(v.phase);
                const float y = static_cast<float>(osc * v.level * v.velocity * caw::parameterAt(b, 3, at, 0.5) * 0.25);
                left[i] += y;
                right[i] += y;
            }
        }
    }

private:
    struct Voice {
        bool active = false, held = false;  // VoicePool's fields
        uint32_t noteId = 0;
        uint64_t age = 0;
        double level = 0, velocity = 1, phase = 0, step = 0;
    };
    static double frequency(double pitch) noexcept { return 440.0 * std::pow(2.0, (pitch - 69.0) / 12.0); }
    caw::VoicePool<Voice, 8> voices_;
    double rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(PolySynth, kDescriptor)
