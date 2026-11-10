// Built-in C++ instruments (#157): the drums and a kit on the Library's kernels; Flagship (builtin_flagship.cpp) plays the rest.
#include "builtin_instruments.h"
#include "builtin_flagship.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/detmath.hpp"
#include "caw/instrument.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/drums.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/oscillator.hpp"
#include "caw/library/stereo.hpp"

namespace caw {

namespace {

// Parameters are read, and coefficients set, once per 16 frames (0.33 ms at 48 kHz).
constexpr uint32_t kControlFrames = 16;

ParameterDescriptor parameter(std::string_view id, std::string_view name, double def, double lo, double hi,
                              std::string_view unit = {}) {
    ParameterDescriptor p;
    p.id = id;
    p.name = name;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.unit = unit;
    p.smoothingFrames = 480;  // 10 ms at 48 kHz: a knob move doesn't click
    return p;
}
// A time, frequency or gain: the knob tapers, so it turns finely near the bottom of a wide range.
ParameterDescriptor exponential(std::string_view id, std::string_view name, double def, double lo, double hi,
                                std::string_view unit = {}) {
    ParameterDescriptor p = parameter(id, name, def, lo, hi, unit);
    p.curve = ParameterCurve::Exponential;
    return p;
}
ParameterDescriptor seconds(std::string_view id, std::string_view name, double def, double lo, double hi) {
    return exponential(id, name, def, lo, hi, "s");
}
ParameterDescriptor hertz(std::string_view id, std::string_view name, double def, double lo, double hi) {
    return exponential(id, name, def, lo, hi, "Hz");
}
ParameterDescriptor choice(std::string_view id, std::string_view name, double def, const std::string_view* labels,
                           uint32_t count) {
    ParameterDescriptor p = parameter(id, name, def, 0.0, static_cast<double>(count - 1));
    p.step = 1.0;
    p.choices = labels;
    p.choiceCount = count;
    p.smoothingFrames = 0;  // a choice jumps
    return p;
}

constexpr PortDescriptor kInstrumentPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

template <size_t N>
ModuleDescriptor instrument(std::string_view id, std::string_view name, const ParameterDescriptor (&params)[N],
                            uint32_t tailFrames) {
    ModuleDescriptor d;
    d.id = id;
    d.name = name;
    d.role = ModuleRole::Instrument;
    d.ports = kInstrumentPorts;
    d.portCount = 2;
    d.parameters = params;
    d.parameterCount = static_cast<uint32_t>(N);
    d.tailFrames = tailFrames;
    return d;
}

// An instrument's control grid: control(at) once every kControlFrames frames of the instrument's own time
// (at = that frame in the block), carried from one render call to the next, so neither a block's size nor
// where events split it moves the grid (live playback and an export render the same). restart() puts the
// next control on the next frame: a note-on does that, so the note starts with the knobs' values at its frame.
class ControlClock {
public:
    // run(i, n) renders frames i .. i + n of this call, all within one control period.
    template <class Control, class Run>
    void run(uint32_t frames, uint32_t offset, Control&& control, Run&& run) noexcept {
        for (uint32_t i = 0; i < frames;) {
            if (left_ == 0) {
                control(offset + i);
                left_ = kControlFrames;
            }
            const uint32_t n = std::min(left_, frames - i);
            run(i, n);
            i += n;
            left_ -= n;
        }
    }
    void restart() noexcept { left_ = 0; }

private:
    uint32_t left_ = 0;
};

// The grid, frame by frame: sample(i) for each frame i of this render call.
template <class Control, class Sample>
void inChunks(ControlClock& clock, uint32_t frames, uint32_t offset, Control&& control, Sample&& sample) noexcept {
    clock.run(frames, offset, control, [&](uint32_t i, uint32_t n) noexcept {
        for (const uint32_t end = i + n; i < end; ++i) sample(i);
    });
}

// A drum voice played in turn from N copies: a new hit chokes the ringing ones (5 ms) and starts a free one,
// so a fast repeat never clicks.
template <class Voice, int N>
struct DrumSlot {
    Voice voices[N];
    int next = 0;
    template <class Settings>
    void set(const Settings& s, double sampleRate) noexcept {
        for (Voice& v : voices) v.set(s, sampleRate);
    }
    void hit(double velocity) noexcept {
        int pick = -1;
        for (int i = 0; i < N; ++i) {
            if (voices[i].active()) voices[i].choke();
            else if (pick < 0) pick = i;
        }
        if (pick < 0) pick = next;
        voices[pick].trigger(velocity);
        next = (pick + 1) % N;
    }
    void choke() noexcept {
        for (Voice& v : voices)
            if (v.active()) v.choke();
    }
    double sample() noexcept {
        double y = 0.0;
        for (Voice& v : voices) y += v.next();
        return y;
    }
    bool active() const noexcept {
        for (const Voice& v : voices)
            if (v.active()) return true;
        return false;
    }
    void clear() noexcept {
        for (Voice& v : voices) v.clear();
        next = 0;
    }
};

// ---------- Kick ----------

const ParameterDescriptor kKickParams[] = {
    hertz("tune", "Tune", 48.0, 20.0, 200.0),
    parameter("punch", "Punch", 0.6, 0.0, 1.0),
    seconds("decay", "Decay", 0.35, 0.05, 4.0),
    parameter("click", "Click", 0.3, 0.0, 1.0),
    parameter("tone", "Tone", 0.6, 0.0, 1.0),
    exponential("drive", "Drive", 1.5, 1.0, 10.0),
    parameter("volume", "Volume", 0.8, 0.0, 1.0),
};
const ModuleDescriptor kKick = instrument("org.caw.drum.kick", "Kick", kKickParams, 768000);  // a 4 s decay at 192 kHz

lib::KickSettings kickSettings(const ProcessBlock& b, uint32_t at, uint32_t first) noexcept {
    lib::KickSettings s;
    s.tune = parameterAt(b, first + 0, at, 48.0);
    s.punch = parameterAt(b, first + 1, at, 0.6);
    s.decay = parameterAt(b, first + 2, at, 0.35);
    s.click = parameterAt(b, first + 3, at, 0.3);
    s.tone = parameterAt(b, first + 4, at, 0.6);
    s.drive = parameterAt(b, first + 5, at, 1.5);
    return s;
}

// Every note plays the kick (its pitch is the `tune` knob's, not the note's); velocity sets the level.
class KickInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kKick; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate;
        kick_.clear();
        kick_.set(lib::KickSettings{}, sr_);
        return true;
    }
    void reset() noexcept override {
        kick_.clear();
        clock_.restart();
    }
    // No voice sounding: silent until the next note (which restarts the control grid, so a skipped stretch
    // changes nothing).
    bool quiet() const noexcept override { return !kick_.active(); }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type != NoteMessageType::On) return;
        kick_.hit(m.velocity);
        clock_.restart();
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        inChunks(clock_, frames, offset,
                 [&](uint32_t at) noexcept {
                     kick_.set(kickSettings(b, at, 0), sr_);
                     volume_ = parameterAt(b, 6, at, 0.8);
                 },
                 [&](uint32_t i) noexcept { left[i] = right[i] = static_cast<float>(kick_.sample() * volume_); });
    }

private:
    DrumSlot<lib::FastKickVoice, 2> kick_;
    ControlClock clock_;
    double sr_ = 48000.0, volume_ = 0.8;
};

// ---------- Snare ----------

const ParameterDescriptor kSnareParams[] = {
    hertz("tune", "Tune", 185.0, 80.0, 400.0),
    seconds("body", "Body", 0.07, 0.01, 1.0),
    seconds("snappy", "Snappy", 0.18, 0.01, 2.0),
    hertz("tone", "Tone", 2500.0, 200.0, 12000.0),
    parameter("mix", "Noise", 0.5, 0.0, 1.0),
    parameter("volume", "Volume", 0.8, 0.0, 1.0),
};
const ModuleDescriptor kSnare = instrument("org.caw.drum.snare", "Snare", kSnareParams, 384000);

lib::SnareSettings snareSettings(const ProcessBlock& b, uint32_t at, uint32_t first) noexcept {
    lib::SnareSettings s;
    s.tune = parameterAt(b, first + 0, at, 185.0);
    s.body = parameterAt(b, first + 1, at, 0.07);
    s.snappy = parameterAt(b, first + 2, at, 0.18);
    s.tone = parameterAt(b, first + 3, at, 2500.0);
    s.mix = parameterAt(b, first + 4, at, 0.5);
    return s;
}

class SnareInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kSnare; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate;
        snare_.clear();
        snare_.set(lib::SnareSettings{}, sr_);
        return true;
    }
    void reset() noexcept override {
        snare_.clear();
        clock_.restart();
    }
    bool quiet() const noexcept override { return !snare_.active(); }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type != NoteMessageType::On) return;
        snare_.hit(m.velocity);
        clock_.restart();
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        inChunks(clock_, frames, offset,
                 [&](uint32_t at) noexcept {
                     snare_.set(snareSettings(b, at, 0), sr_);
                     volume_ = parameterAt(b, 5, at, 0.8);
                 },
                 [&](uint32_t i) noexcept { left[i] = right[i] = static_cast<float>(snare_.sample() * volume_); });
    }

private:
    DrumSlot<lib::SnareVoice, 2> snare_;
    ControlClock clock_;
    double sr_ = 48000.0, volume_ = 0.8;
};

// ---------- Hi-hats ----------

// General MIDI drum keys (as the GM percussion map numbers them; C4 = 60).
constexpr uint8_t kKeyKickLow = 35, kKeyKick = 36, kKeySnare = 38, kKeyClap = 39, kKeySnareHigh = 40,
                  kKeyHatClosed = 42, kKeyHatPedal = 44, kKeyHatOpen = 46;

constexpr std::string_view kHatModes[] = {"By note", "Closed", "Open"};
const ParameterDescriptor kHatParams[] = {
    choice("mode", "Open or closed", 0.0, kHatModes, 3),
    seconds("closed", "Closed decay", 0.045, 0.005, 0.5),
    seconds("open", "Open decay", 0.3, 0.05, 2.0),
    hertz("tone", "Tone", 7000.0, 2000.0, 14000.0),
    parameter("metal", "Metal", 0.5, 0.0, 1.0),
    parameter("volume", "Volume", 0.8, 0.0, 1.0),
};
const ModuleDescriptor kHats = instrument("org.caw.drum.hats", "Hi-hats", kHatParams, 384000);

// One hi-hat: any hit chokes the one ringing, as on a real pair of cymbals. The closed and open hits differ
// only in decay, so each voice keeps the decay it started with. A hit waits for the next update() (the
// render that follows it on the same frame), so it starts with the knobs' values at its frame.
class HatPair {
public:
    void hit(uint8_t key, double velocity) noexcept {
        int pick = -1;
        for (int i = 0; i < 2; ++i) {
            if (voices_[i].active()) voices_[i].choke();
            else if (pick < 0 && pending_[i] < 0.0) pick = i;
        }
        if (pick < 0) pick = next_;
        key_[pick] = key;
        pending_[pick] = velocity;
        next_ = 1 - pick;
    }
    // mode 0: open on A#2 (46, the GM open hi-hat) and closed on every other key; 1 always closed; 2 always open.
    // Sets both voices and starts the hits waiting.
    void update(int mode, double tone, double metal, double closedDecay, double openDecay, double sampleRate) noexcept {
        lib::HatSettings s;
        s.tone = tone;
        s.metal = metal;
        for (int i = 0; i < 2; ++i) {
            if (pending_[i] >= 0.0) open_[i] = mode == 2 || (mode == 0 && key_[i] == kKeyHatOpen);
            s.decay = open_[i] ? openDecay : closedDecay;
            voices_[i].set(s, sampleRate);
            if (pending_[i] >= 0.0) {
                voices_[i].trigger(pending_[i]);
                pending_[i] = -1.0;
            }
        }
    }
    double sample() noexcept { return voices_[0].next() + voices_[1].next(); }
    bool active() const noexcept { return voices_[0].active() || voices_[1].active() || pending_[0] >= 0.0 || pending_[1] >= 0.0; }
    void clear() noexcept {
        for (int i = 0; i < 2; ++i) {
            voices_[i].clear();
            open_[i] = false;
            pending_[i] = -1.0;
            key_[i] = 0;
        }
        next_ = 0;
    }

private:
    lib::HatVoice voices_[2];
    bool open_[2] = {false, false};
    double pending_[2] = {-1.0, -1.0};
    uint8_t key_[2] = {0, 0};
    int next_ = 0;
};

// Closed on every key but A#2 (46, the GM open hi-hat), unless `mode` makes every note closed or open.
class HatsInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kHats; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate;
        reset();
        return true;
    }
    void reset() noexcept override {
        hats_.clear();
        clock_.restart();
    }
    bool quiet() const noexcept override { return !hats_.active(); }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type != NoteMessageType::On) return;
        hats_.hit(m.key, m.velocity);
        clock_.restart();  // the hit starts at the next control: this frame
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        inChunks(clock_, frames, offset,
                 [&](uint32_t at) noexcept {
                     hats_.update(static_cast<int>(parameterAt(b, 0, at, 0.0)), parameterAt(b, 3, at, 7000.0),
                                  parameterAt(b, 4, at, 0.5), parameterAt(b, 1, at, 0.045), parameterAt(b, 2, at, 0.3), sr_);
                     volume_ = parameterAt(b, 5, at, 0.8);
                 },
                 [&](uint32_t i) noexcept { left[i] = right[i] = static_cast<float>(hats_.sample() * volume_); });
    }

private:
    HatPair hats_;
    ControlClock clock_;
    double sr_ = 48000.0, volume_ = 0.8;
};

// ---------- Drum kit ----------

const ParameterDescriptor kKitParams[] = {
    hertz("kick_tune", "Kick tune", 48.0, 20.0, 200.0),
    seconds("kick_decay", "Kick decay", 0.35, 0.05, 4.0),
    parameter("kick_punch", "Kick punch", 0.6, 0.0, 1.0),
    hertz("snare_tune", "Snare tune", 185.0, 80.0, 400.0),
    seconds("snare_snappy", "Snare snappy", 0.18, 0.01, 2.0),
    seconds("clap_decay", "Clap decay", 0.15, 0.02, 2.0),
    seconds("hat_closed", "Closed hat decay", 0.045, 0.005, 0.5),
    seconds("hat_open", "Open hat decay", 0.3, 0.05, 2.0),
    hertz("hat_tone", "Hat tone", 7000.0, 2000.0, 14000.0),
    parameter("kick", "Kick level", 1.0, 0.0, 1.0),
    parameter("snare", "Snare level", 0.8, 0.0, 1.0),
    parameter("clap", "Clap level", 0.7, 0.0, 1.0),
    parameter("hats", "Hats level", 0.6, 0.0, 1.0),
    parameter("volume", "Volume", 0.8, 0.0, 1.0),
};
enum KitParam : uint32_t {
    kKitKickTune, kKitKickDecay, kKitKickPunch, kKitSnareTune, kKitSnareSnappy, kKitClapDecay, kKitHatClosed,
    kKitHatOpen, kKitHatTone, kKitKick, kKitSnare, kKitClap, kKitHats, kKitVolume
};
const ModuleDescriptor kKit = instrument("org.caw.drum.kit", "Drum kit", kKitParams, 768000);

// General MIDI keys: B1/C2 (35, 36) kick, D2/E2 (38, 40) snare, D#2 (39) clap, F#2/G#2 (42, 44) closed hi-hat,
// A#2 (46) open hi-hat. Other keys are silent.
class KitInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kKit; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate;
        clear();
        kick_.set(lib::KickSettings{}, sr_);
        snare_.set(lib::SnareSettings{}, sr_);
        clap_.set(lib::ClapSettings{}, sr_);
        return true;
    }
    void reset() noexcept override { clear(); }
    bool quiet() const noexcept override { return !kick_.active() && !snare_.active() && !clap_.active() && !hats_.active(); }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type != NoteMessageType::On) return;
        clock_.restart();
        switch (m.key) {
            case kKeyKickLow:
            case kKeyKick: kick_.hit(m.velocity); break;
            case kKeySnare:
            case kKeySnareHigh: snare_.hit(m.velocity); break;
            case kKeyClap: clap_.hit(m.velocity); break;
            case kKeyHatClosed:
            case kKeyHatPedal:
            case kKeyHatOpen: hats_.hit(m.key, m.velocity); break;
            default: break;
        }
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        double& kick = level_[0];
        double& snare = level_[1];
        double& clap = level_[2];
        double& hats = level_[3];
        double& volume = level_[4];
        inChunks(clock_, frames, offset,
                 [&](uint32_t at) noexcept {
                     lib::KickSettings k;
                     k.tune = parameterAt(b, kKitKickTune, at, 48.0);
                     k.decay = parameterAt(b, kKitKickDecay, at, 0.35);
                     k.punch = parameterAt(b, kKitKickPunch, at, 0.6);
                     kick_.set(k, sr_);
                     lib::SnareSettings s;
                     s.tune = parameterAt(b, kKitSnareTune, at, 185.0);
                     s.snappy = parameterAt(b, kKitSnareSnappy, at, 0.18);
                     snare_.set(s, sr_);
                     lib::ClapSettings c;
                     c.decay = parameterAt(b, kKitClapDecay, at, 0.15);
                     clap_.set(c, sr_);
                     hats_.update(0, parameterAt(b, kKitHatTone, at, 7000.0), 0.5, parameterAt(b, kKitHatClosed, at, 0.045),
                                  parameterAt(b, kKitHatOpen, at, 0.3), sr_);
                     kick = parameterAt(b, kKitKick, at, 1.0);
                     snare = parameterAt(b, kKitSnare, at, 0.8);
                     clap = parameterAt(b, kKitClap, at, 0.7);
                     hats = parameterAt(b, kKitHats, at, 0.6);
                     volume = parameterAt(b, kKitVolume, at, 0.8);
                 },
                 [&](uint32_t i) noexcept {
                     const double y = kick_.sample() * kick + snare_.sample() * snare + clap_.sample() * clap +
                                      hats_.sample() * hats;
                     left[i] = right[i] = static_cast<float>(y * volume);
                 });
    }

private:
    void clear() noexcept {
        kick_.clear();
        snare_.clear();
        clap_.clear();
        hats_.clear();
        clock_.restart();
    }
    DrumSlot<lib::FastKickVoice, 2> kick_;
    DrumSlot<lib::SnareVoice, 2> snare_;
    DrumSlot<lib::ClapVoice, 2> clap_;
    HatPair hats_;
    ControlClock clock_;
    double sr_ = 48000.0;
    double level_[5] = {1.0, 0.8, 0.7, 0.6, 0.8};  // the kick, snare, clap and hats levels and the volume, at the last control
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerBuiltinInstruments(ModuleRegistry& registry) {
    registry.add(kKick, &make<KickInstrument>);
    registry.add(kSnare, &make<SnareInstrument>);
    registry.add(kHats, &make<HatsInstrument>);
    registry.add(kKit, &make<KitInstrument>);
    registerFlagshipSynth(registry);  // the flagship synth (builtin_flagship.cpp)
}

}  // namespace caw
