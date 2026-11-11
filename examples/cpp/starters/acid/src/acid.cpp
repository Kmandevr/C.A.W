// Acid: a mono saw into a resonant 24 dB ladder that slides between overlapping notes; loud notes (velocity above 0.7) are accents (try the Acid line pattern).
#include <caw/component.hpp>
#include <caw/instrument.hpp>
#include <caw/library/envelope.hpp>
#include <caw/library/filter.hpp>
#include <caw/library/oscillator.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};

caw::ParameterDescriptor knob(std::string_view id, std::string_view name, double def, double lo, double hi,
                              std::string_view unit = {}) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.unit = unit;
    p.curve = unit == "Hz" || unit == "s" ? caw::ParameterCurve::Exponential : caw::ParameterCurve::Linear;
    p.smoothingFrames = 480;
    return p;
}
enum : uint32_t { kCutoff, kResonance, kSweep, kDecay, kSlide, kVolume };
const caw::ParameterDescriptor kParams[] = {
    knob("cutoff", "Cutoff", 500, 100, 4000, "Hz"),  // brightness before each note opens the filter
    knob("resonance", "Resonance", 0.7, 0, 1),       // higher squelches
    knob("sweep", "Sweep", 2.5, 0, 6),               // how many octaves each note opens the filter
    knob("decay", "Decay", 0.2, 0.02, 1, "s"),       // how fast the filter falls after a note starts
    knob("slide", "Slide", 0.06, 0.005, 0.5, "s"),   // glide time between overlapping notes
    knob("volume", "Volume", 0.5, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.acid";
    d.name = "Acid";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 6;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

// Mono, last note wins: a note played while another is held slides to its pitch without restarting the
// envelopes (legato, a 303's slide); a note after silence starts fresh.
class Acid final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        held_ = 0;
        amp_.clear();
        sweep_.clear();
        filter_.clear();
        phase_ = 0;
    }

protected:
    void beginBlock(const caw::ProcessBlock& b) noexcept override { slide_ = caw::parameterAt(b, kSlide, 0, 0.06); }

    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type == caw::NoteMessageType::On) {
            if (held_ > 0) {
                pitch_.glideTo(m.pitch, slide_, rate_);  // legato: slide, keep the envelopes going
            } else {
                pitch_.jump(m.pitch);
                accent_ = m.velocity > 0.7 ? 1.0 : 0.0;
                amp_.gateOn();
                sweep_.trigger();
            }
            push(m.noteId, m.pitch);
        } else if (m.type == caw::NoteMessageType::Off) {
            remove(m.noteId);
            if (held_ > 0) pitch_.glideTo(stack_[held_ - 1].pitch, slide_, rate_);  // back to the note still held
            else amp_.gateOff();
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        const double cutoff = caw::parameterAt(b, kCutoff, offset, 500);
        const double resonance = caw::parameterAt(b, kResonance, offset, 0.7);
        const double octaves = caw::parameterAt(b, kSweep, offset, 2.5) * (1.0 + 0.5 * accent_);
        const double decay = caw::parameterAt(b, kDecay, offset, 0.2) * (1.0 - 0.4 * accent_);  // accents snap shut
        const double gain = caw::parameterAt(b, kVolume, offset, 0.5) * (1.0 + 0.6 * accent_) * 0.5;
        amp_.set(0.002, 0.2, 0.6, 0.04, rate_);
        sweep_.set(0.001, decay, rate_);
        for (uint32_t i = 0; i < frames; ++i) {
            const double dt = caw::lib::noteHz(pitch_.next()) / rate_;
            const double e = sweep_.next();
            if ((i & 15) == 0) filter_.set(caw::lib::shiftCutoff(cutoff, octaves * e, rate_), resonance, rate_);
            const double y = filter_.processFast(caw::lib::sawWave(phase_, dt)) * amp_.next() * gain;
            phase_ = caw::lib::wrap01(phase_ + dt);
            left[i] = right[i] = static_cast<float>(y);
        }
    }

private:
    struct Held {
        uint32_t id;
        double pitch;
    };
    void push(uint32_t id, double pitch) noexcept {
        remove(id);
        if (held_ == kStack) remove(stack_[0].id);  // full: forget the oldest
        stack_[held_++] = {id, pitch};
    }
    void remove(uint32_t id) noexcept {
        for (int k = 0; k < held_; ++k)
            if (stack_[k].id == id) {
                for (int j = k + 1; j < held_; ++j) stack_[j - 1] = stack_[j];
                --held_;
                return;
            }
    }

    static constexpr int kStack = 8;
    Held stack_[kStack] = {};
    int held_ = 0;
    caw::lib::Glide pitch_;
    caw::lib::Adsr amp_;
    caw::lib::AdEnvelope sweep_;
    caw::lib::Ladder filter_;
    double phase_ = 0, accent_ = 0, slide_ = 0.06, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Acid, kDescriptor)
