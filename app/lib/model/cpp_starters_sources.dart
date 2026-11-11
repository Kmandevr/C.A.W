// The C++ starters' files, generated from examples/cpp/starters by test/cpp_starters_test.dart; do not edit.
// Regenerate: CAW_UPDATE_STARTERS=1 flutter test test/cpp_starters_test.dart

/// Folder name -> {path in the component -> text}.
const cppStarterSources = <String, Map<String, String>>{
  'acid': {
    'caw-component.json': r'''{
  "format": "caw.component",
  "version": 1,
  "component": {
    "id": "org.caw.starter.acid",
    "name": "Acid"
  },
  "sources": [
    "src/acid.cpp"
  ]
}
''',
    'src/acid.cpp': r'''// Acid: a mono saw into a resonant 24 dB ladder that slides between overlapping notes; loud notes (velocity above 0.7) are accents (try the Acid line pattern).
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
''',
  },
  'bass': {
    'caw-component.json': r'''{
  "format": "caw.component",
  "version": 1,
  "component": {
    "id": "org.caw.starter.bass",
    "name": "Bass"
  },
  "sources": [
    "src/bass.cpp"
  ]
}
''',
    'src/bass.cpp': r'''// Bass: a filtered saw bass whose low-pass opens at each note and closes as it fades; plays a track's notes.
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
''',
  },
  'bytebeat-loop': {
    'caw-component.json': r'''{
  "format": "caw.component",
  "version": 1,
  "component": {
    "id": "org.caw.starter.bytebeat-loop",
    "name": "Bytebeat loop"
  },
  "sources": [
    "src/bytebeat_loop.cpp"
  ]
}
''',
    'src/bytebeat_loop.cpp': r'''// Bytebeat loop: a shifting bytebeat riff that plays while a note is held (C4 plays it at 8 kHz, other notes transpose it); slide shift to change the rhythm.
#include <cstdint>

#include <caw/component.hpp>
#include <caw/instrument.hpp>
#include <caw/library/oscillator.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {
    {"notes", caw::PortType::Event, caw::ChannelLayout::None, true, 0, false, 0.0f},
    caw::stereoOutput("out"),
};

caw::ParameterDescriptor shift() {
    caw::ParameterDescriptor p;
    p.id = "shift";
    p.name = "Shift";  // which bits of t drive the rhythm
    p.defaultValue = 6;
    p.minimum = 1;
    p.maximum = 12;
    p.step = 1;
    return p;
}
caw::ParameterDescriptor volume() {
    caw::ParameterDescriptor p;
    p.id = "volume";
    p.name = "Volume";
    p.defaultValue = 0.4;
    p.smoothingFrames = 480;
    return p;
}
enum : uint32_t { kShift, kVolume };
const caw::ParameterDescriptor kParams[] = {shift(), volume()};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.bytebeat-loop";
    d.name = "Bytebeat loop";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 2;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

// The formula: a melody from t times a slowly changing multiplier, and a rhythm from two shifted copies of t.
// Every value is cut to its low 8 bits, as in classic bytebeat. (Original to C.A.W.)
uint8_t formula(uint32_t t, uint32_t shift) noexcept {
    const uint32_t melody = (t * (2 + ((t >> 11) & 3))) >> ((t >> 13) & 1);
    const uint32_t rhythm = (t >> shift) & (t >> 3);
    return static_cast<uint8_t>((melody & 160) + (rhythm & 63));
}

class BytebeatLoop final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        held_ = 0;
        level_ = 0;
        position_ = 0;
    }

protected:
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type == caw::NoteMessageType::On) {
            if (held_++ == 0) position_ = 0;  // the riff starts from t = 0 on the first note
            step_ = 8000.0 * caw::lib::noteHz(m.pitch) / caw::lib::noteHz(60) / rate_;
            velocity_ = m.velocity;
        } else if (m.type == caw::NoteMessageType::Off && held_ > 0) {
            --held_;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        const uint32_t sh = static_cast<uint32_t>(caw::parameterAt(b, kShift, offset, 6));
        const double gain = caw::parameterAt(b, kVolume, offset, 0.4) * velocity_;
        const double fade = 1.0 / (0.005 * rate_);  // 5 ms in and out: no click at the note's edges
        for (uint32_t i = 0; i < frames; ++i) {
            level_ = held_ > 0 ? (level_ + fade < 1 ? level_ + fade : 1) : (level_ - fade > 0 ? level_ - fade : 0);
            if (level_ <= 0) {
                left[i] = right[i] = 0.0f;
                continue;
            }
            // t counts at the bytebeat rate and holds between counts: the stair steps are the sound.
            const uint32_t t = static_cast<uint32_t>(static_cast<uint64_t>(position_));
            position_ += step_;
            const double y = (formula(t, sh < 1 ? 1 : (sh > 12 ? 12 : sh)) / 128.0 - 1.0) * level_ * gain;
            left[i] = right[i] = static_cast<float>(y);
        }
    }

private:
    int held_ = 0;
    double position_ = 0, step_ = 1.0 / 6.0, level_ = 0, velocity_ = 1, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(BytebeatLoop, kDescriptor)
''',
  },
  'glitch-fx': {
    'caw-component.json': r'''{
  "format": "caw.component",
  "version": 1,
  "component": {
    "id": "org.caw.starter.glitch-fx",
    "name": "Glitch"
  },
  "sources": [
    "src/glitch_fx.cpp"
  ]
}
''',
    'src/glitch_fx.cpp': r'''// Glitch: flips bits of the incoming sound and holds it at a lower rate on the last 16th of each beat, in time with the song.
#include <caw/component.hpp>
#include <caw/library/glitch.hpp>

namespace {

constexpr caw::PortDescriptor kPorts[] = {caw::stereoInput("in"), caw::stereoOutput("out")};

caw::ParameterDescriptor knob(std::string_view id, std::string_view name, double def, double lo, double hi,
                              double step = 0, std::string_view unit = {}) {
    caw::ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.step = step;
    p.unit = unit;
    p.curve = unit == "Hz" ? caw::ParameterCurve::Exponential : caw::ParameterCurve::Linear;
    return p;
}
enum : uint32_t { kMask, kRate, kMix };
const caw::ParameterDescriptor kParams[] = {
    knob("mask", "Mask", 240, 0, 4095, 1),               // which bits flip on the glitch step
    knob("rate", "Hold rate", 4000, 200, 48000, 0, "Hz"),  // how often the held value is picked up
    knob("mix", "Mix", 1, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.glitch-fx";
    d.name = "Glitch";
    d.role = caw::ModuleRole::Effect;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 3;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

// A parameter's value at a frame (per frame while it ramps or is automated).
double param(const caw::AudioProcessBlock& b, uint32_t k, uint32_t frame, double fallback) noexcept {
    if (k >= b.parameterCount || !b.parameters) return fallback;
    return b.parameters[k].samples ? b.parameters[k].samples[frame] : b.parameters[k].value;
}

class Glitch final : public caw::ModuleProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        hold_[0].reset();
        hold_[1].reset();
        freeBeat_ = 0;
    }

    bool process(const caw::AudioProcessBlock& b) noexcept override {
        if (!caw::audioProcessBlockValid(b) || b.input.channelCount != 2 || b.output.channelCount != 2) return false;
        // The song position and tempo; with no transport (an audition), a free-running 120 BPM.
        const double tempo = b.transport && b.transport->tempo > 0 ? b.transport->tempo : 120.0;
        const double start = b.transport ? b.transport->beat : freeBeat_;
        const double perFrame = tempo / 60.0 / rate_;
        const uint32_t mask = static_cast<uint32_t>(param(b, kMask, 0, 240));
        const double hz = param(b, kRate, 0, 4000);
        for (uint32_t i = 0; i < b.frames; ++i) {
            const double beat = start + i * perFrame;
            const double mix = param(b, kMix, i, 1);
            const bool glitch = beat - static_cast<double>(static_cast<int64_t>(beat)) >= 0.75;  // the 4th 16th
            for (int c = 0; c < 2; ++c) {
                const double x = b.input.channels[c][i];
                // The hold runs all the time, so it picks up the beat's sound the moment the glitch step starts.
                const double held = hold_[c].process(x, hz, rate_);
                const double wet = glitch ? caw::lib::bitMask(held, mask) : x;
                b.output.channels[c][i] = static_cast<float>(x + (wet - x) * mix);
            }
        }
        freeBeat_ = start + b.frames * perFrame;
        return true;
    }

private:
    caw::lib::SampleHold hold_[2];
    double freeBeat_ = 0, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Glitch, kDescriptor)
''',
  },
  'hats': {
    'caw-component.json': r'''{
  "format": "caw.component",
  "version": 1,
  "component": {
    "id": "org.caw.starter.hats",
    "name": "Hats"
  },
  "sources": [
    "src/hats.cpp"
  ]
}
''',
    'src/hats.cpp': r'''// Hats: high-passed noise hi-hats, closed on most notes and open on A#2 (46); an open hat is choked by the next hit.
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
enum : uint32_t { kTone, kClosed, kOpen, kVolume };
const caw::ParameterDescriptor kParams[] = {
    knob("tone", "Tone", 7000, 2000, 12000, "Hz"),    // lowest frequency let through: higher is thinner
    knob("closed", "Closed decay", 0.04, 0.01, 0.2, "s"),
    knob("open", "Open decay", 0.25, 0.05, 1.0, "s"),
    knob("volume", "Volume", 0.5, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.hats";
    d.name = "Hats";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 4;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

constexpr int kOpenKey = 46;  // A#2, the General MIDI open hi-hat

class Hats final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        env_.clear();
        filter_ = {};
        noise_.reset();
    }

protected:
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type != caw::NoteMessageType::On) return;
        open_ = m.key == kOpenKey;
        velocity_ = m.velocity;
        env_.trigger();  // one voice: a closed hat cuts an open one off, as on a real kit
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        filter_.set(caw::parameterAt(b, kTone, offset, 7000), 1.2, rate_);
        env_.set(0.0005, open_ ? caw::parameterAt(b, kOpen, offset, 0.25) : caw::parameterAt(b, kClosed, offset, 0.04), rate_);
        const double gain = caw::parameterAt(b, kVolume, offset, 0.5) * velocity_;
        for (uint32_t i = 0; i < frames; ++i) {
            // The noise runs on between hits, so each hit sounds slightly different (and the same on every render).
            const double y = filter_.process(noise_.next()).high * env_.next() * gain;
            left[i] = right[i] = static_cast<float>(y);
        }
    }

private:
    caw::lib::AdEnvelope env_;
    caw::lib::Svf filter_;
    caw::lib::Noise noise_{7};
    bool open_ = false;
    double velocity_ = 1, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Hats, kDescriptor)
''',
  },
  'kick': {
    'caw-component.json': r'''{
  "format": "caw.component",
  "version": 1,
  "component": {
    "id": "org.caw.starter.kick",
    "name": "Kick"
  },
  "sources": [
    "src/kick.cpp"
  ]
}
''',
    'src/kick.cpp': r'''// Kick: a sine kick with a fast pitch drop at the start of each hit; any note plays it.
#include <caw/component.hpp>
#include <caw/instrument.hpp>
#include <caw/library/envelope.hpp>
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
    p.smoothingFrames = 480;
    return p;
}
enum : uint32_t { kTune, kPunch, kDecay, kVolume };
const caw::ParameterDescriptor kParams[] = {
    knob("tune", "Tune", 45, 30, 90, "Hz"),        // the pitch the kick settles at
    knob("punch", "Punch", 0.6, 0, 1),             // how far and how long the pitch drops from
    knob("decay", "Decay", 0.35, 0.05, 1.5, "s"),  // seconds until it fades out
    knob("volume", "Volume", 0.8, 0, 1),
};

caw::ModuleDescriptor describe() {
    caw::ModuleDescriptor d;
    d.id = "org.caw.starter.kick";
    d.name = "Kick";
    d.role = caw::ModuleRole::Instrument;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = kParams;
    d.parameterCount = 4;
    return d;
}
const caw::ModuleDescriptor kDescriptor = describe();

// One voice is enough: a new hit restarts the kick (a drum machine's kick works the same way).
class Kick final : public caw::InstrumentProcessor {
public:
    const caw::ModuleDescriptor& descriptor() const noexcept override { return kDescriptor; }
    bool activate(double rate, uint32_t) noexcept override {
        rate_ = rate;
        reset();
        return true;
    }
    void reset() noexcept override {
        level_.clear();
        drop_.clear();
        phase_ = 0;
    }

protected:
    void onNote(const caw::NoteMessage& m) noexcept override {
        if (m.type != caw::NoteMessageType::On) return;
        velocity_ = m.velocity;
        phase_ = 0;  // every hit starts at the same point of the sine: the same click each time
        level_.trigger();
        drop_.trigger();
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const caw::ProcessBlock& b) noexcept override {
        const double tune = caw::parameterAt(b, kTune, offset, 45);
        const double punch = caw::parameterAt(b, kPunch, offset, 0.6);
        level_.set(0.001, caw::parameterAt(b, kDecay, offset, 0.35), rate_);
        drop_.set(0.0005, 0.04 + punch * 0.08, rate_);
        const double gain = caw::parameterAt(b, kVolume, offset, 0.8) * velocity_;
        for (uint32_t i = 0; i < frames; ++i) {
            const double d = drop_.next();
            // The pitch starts up to 8 times higher and falls along the square of the drop envelope.
            const double hz = tune * (1.0 + 7.0 * punch * d * d);
            const double y = caw::lib::sineWave(phase_) * level_.next() * gain;
            phase_ = caw::lib::wrap01(phase_ + hz / rate_);
            left[i] = right[i] = static_cast<float>(y);
        }
    }

private:
    caw::lib::AdEnvelope level_, drop_;
    double phase_ = 0, velocity_ = 1, rate_ = 48000;
};

}  // namespace

CAW_EXPORT_COMPONENT(Kick, kDescriptor)
''',
  },
  'pad': {
    'caw-component.json': r'''{
  "format": "caw.component",
  "version": 1,
  "component": {
    "id": "org.caw.starter.pad",
    "name": "Pad"
  },
  "sources": [
    "src/pad.cpp"
  ]
}
''',
    'src/pad.cpp': r'''// Pad: a wide pad of detuned copies morphing sine to square, the shape drifting on a drawn 16-beat curve; plays a track's notes (try the Chords pattern).
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
''',
  },
};
