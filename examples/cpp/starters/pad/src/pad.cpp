// Pad: a wide pad of detuned copies morphing sine to square, the shape drifting on a drawn 16-beat curve; plays a track's notes (try the Chords pattern).
#include <caw/component.hpp>
#include <caw/instrument.hpp>
#include <caw/library/envelope.hpp>
#include <caw/library/filter.hpp>
#include <caw/library/modulation.hpp>
#include <caw/library/oscillator.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};

caw::ParameterDescriptor knob(std::string_view id, std::string_view name, double def, double lo, double hi,
                              std::string_view unit = {}, double step = 0) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.unit = unit;
    p.step = step;
    p.curve = unit == "Hz" ? caw::ParameterCurve::Exponential : caw::ParameterCurve::Linear;
    p.smoothingFrames = step > 0 ? 0 : 480;
    return p;
}
enum : uint32_t { kShape, kDrift, kCopies, kDetune, kCutoff, kVolume };
const caw::ParameterDescriptor kParams[] = {
    knob("shape", "Shape", 0.45, 0, 1),              // sine, triangle, saw, square
    knob("drift", "Drift", 0.25, 0, 1),              // how far the slow curve moves the shape
    knob("copies", "Copies", 5, 1, 7, {}, 1),        // detuned copies per note
    knob("detune", "Detune", 0.18, 0, 1),            // their spread, up to a semitone either way
    knob("cutoff", "Cutoff", 1800, 200, 8000, "Hz"),
    knob("volume", "Volume", 0.5, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.pad";
    d.name = "Pad";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 6;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

constexpr int kMaxCopies = 7;

class Pad final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        // The drift: a drawn curve, up quickly, a dip, then a long fall (levels -1..1 at even steps).
        const double points[] = {0.0, 1.0, 0.4, 0.7, -0.6, -1.0};
        drift_.setEven(points, 6);
        voices_.clear();
        return true;
    }
    void reset() noexcept override { voices_.clear(); }

protected:
    void beginBlock(const caw::ProcessBlock& b) noexcept override {
        // The curve follows the song: 16 beats a cycle, read from the transport at each block.
        const double beats = b.transport ? b.transport->beat : 0.0;
        driftNow_ = drift_.valueAt(beats / 16.0);
    }

    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type == caw::NoteMessageType::On) {
            Voice& v = voices_.start(m.noteId);
            v.pitch = m.pitch;
            v.velocity = m.velocity;
            for (int c = 0; c < kMaxCopies; ++c) v.phase[c] = 0.13 * c;  // spread starts: no flam at the attack
            v.env.gateOn();
        } else if (Voice* v = voices_.find(m.noteId)) {
            if (m.type == caw::NoteMessageType::Off) v->held = false, v->env.gateOff();
            if (m.type == caw::NoteMessageType::Pitch) v->pitch = m.pitch;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        double shape = caw::parameterAt(b, kShape, offset, 0.45) + caw::parameterAt(b, kDrift, offset, 0.25) * driftNow_;
        shape = shape < 0 ? 0 : (shape > 1 ? 1 : shape);
        int copies = static_cast<int>(caw::parameterAt(b, kCopies, offset, 5));
        copies = copies < 1 ? 1 : (copies > kMaxCopies ? kMaxCopies : copies);
        const double detune = caw::parameterAt(b, kDetune, offset, 0.18);
        const double cutoff = caw::parameterAt(b, kCutoff, offset, 1800);
        const double volume = caw::parameterAt(b, kVolume, offset, 0.5) * 0.3 / copies;
        for (Voice& v : voices_) {
            v.env.set(0.3, 0.5, 0.8, 0.8, rate_);
            v.filter[0].set(cutoff, 1.2, rate_);
            v.filter[1].set(cutoff, 1.2, rate_);
            double dt[kMaxCopies], panL[kMaxCopies], panR[kMaxCopies];
            for (int c = 0; c < copies; ++c) {
                // Copies spread evenly from -detune to +detune semitones, and from left to right.
                const double x = copies == 1 ? 0.0 : 2.0 * c / (copies - 1) - 1.0;
                dt[c] = caw::lib::noteHz(v.pitch + detune * x) / rate_;
                panL[c] = 0.5 - 0.4 * x;
                panR[c] = 0.5 + 0.4 * x;
            }
            for (uint32_t i = 0; i < frames; ++i) {
                double l = 0, r = 0;
                for (int c = 0; c < copies; ++c) {
                    const double s = caw::lib::morphWave(v.phase[c], dt[c], shape);
                    v.phase[c] = caw::lib::wrap01(v.phase[c] + dt[c]);
                    l += s * panL[c];
                    r += s * panR[c];
                }
                const double g = v.env.next() * (0.5 + 0.5 * v.velocity) * volume;
                left[i] += static_cast<float>(v.filter[0].lowpass(l) * g);
                right[i] += static_cast<float>(v.filter[1].lowpass(r) * g);
            }
            if (!v.env.active()) v.active = false;
        }
    }

private:
    struct Voice {
        bool active = false, held = false;
        uint32_t noteId = 0;
        uint64_t age = 0;
        double pitch = 60, velocity = 1;
        double phase[kMaxCopies] = {};
        caw::lib::Adsr env;
        caw::lib::Svf filter[2];
    };
    caw::VoicePool<Voice, 16> voices_;
    caw::lib::CurveShape drift_;
    double driftNow_ = 0, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Pad, kDescriptor)
