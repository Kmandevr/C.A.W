// Bass: a filtered saw bass whose low-pass opens at each note and closes as it fades; plays a track's notes.
#include <caw/component.hpp>
#include <caw/instrument.hpp>
#include <caw/library/envelope.hpp>
#include <caw/library/filter.hpp>
#include <caw/library/oscillator.hpp>

namespace {

// Notes in, stereo out.
constexpr caw::PortDescriptor kPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};

caw::ParameterDescriptor knob(std::string_view id, std::string_view name, double def, double lo, double hi,
                              std::string_view unit = {}, bool expo = false) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.unit = unit;
    p.curve = expo ? caw::ParameterCurve::Exponential : caw::ParameterCurve::Linear;
    p.smoothingFrames = 480;  // a knob move glides over 10 ms
    return p;
}
enum : uint32_t { kCutoff, kResonance, kDecay, kVolume };
const caw::ParameterDescriptor kParams[] = {
    knob("cutoff", "Cutoff", 900, 100, 4000, "Hz", true),  // brightness when the filter is closed
    knob("resonance", "Resonance", 0.3, 0, 1),             // higher whistles at the cutoff
    knob("decay", "Decay", 0.18, 0.02, 1, "s", true),      // how fast each note's filter and level fall
    knob("volume", "Volume", 0.7, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.bass";
    d.name = "Bass";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 4;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

class Bass final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        voices_.clear();
        return true;
    }
    void reset() noexcept override { voices_.clear(); }

protected:
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type == caw::NoteMessageType::On) {
            Voice& v = voices_.start(m.noteId);
            v.dt = caw::lib::noteHz(m.pitch) / rate_;
            v.velocity = m.velocity;
            v.phase = 0;
            v.filter = {};
            v.env.trigger();
        } else if (Voice* v = voices_.find(m.noteId)) {
            if (m.type == caw::NoteMessageType::Off) v->held = false;
            if (m.type == caw::NoteMessageType::Pitch) v->dt = caw::lib::noteHz(m.pitch) / rate_;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        const double cutoff = caw::parameterAt(b, kCutoff, offset, 900);
        const double q = caw::lib::resonanceQ(caw::parameterAt(b, kResonance, offset, 0.3));
        const double decay = caw::parameterAt(b, kDecay, offset, 0.18);
        const double volume = caw::parameterAt(b, kVolume, offset, 0.7);
        for (Voice& v : voices_) {
            v.env.set(0.002, v.held ? decay : decay * 0.5, rate_);  // let go: it fades twice as fast
            for (uint32_t i = 0; i < frames; ++i) {
                const double e = v.env.next();
                // The filter's coefficients cost a tan: work them out every 16 samples, not every sample.
                if ((i & 15) == 0) v.filter.set(cutoff * (0.3 + e), q, rate_);
                const double y = v.filter.lowpass(caw::lib::sawWave(v.phase, v.dt)) * e * v.velocity * volume * 0.8;
                v.phase = caw::lib::wrap01(v.phase + v.dt);
                left[i] += static_cast<float>(y);
                right[i] += static_cast<float>(y);
            }
            if (!v.env.active()) v.active = false;
        }
    }

private:
    struct Voice {
        bool active = false, held = false;
        uint32_t noteId = 0;
        uint64_t age = 0;
        double phase = 0, dt = 0, velocity = 1;
        caw::lib::AdEnvelope env;
        caw::lib::Svf filter;
    };
    caw::VoicePool<Voice, 8> voices_;
    double rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Bass, kDescriptor)
