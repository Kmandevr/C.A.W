// Built-in C++ instruments (#157): drums, a kit, a bass, an acid synth and a morph synth, on the Library's kernels.
#include "builtin_instruments.h"

#include <algorithm>
#include <cmath>
#include <new>

#include "caw/detmath.hpp"
#include "caw/instrument.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/drums.hpp"
#include "caw/library/envelope.hpp"
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
ParameterDescriptor exponential(std::string_view id, std::string_view name, double def, double lo, double hi,
                                std::string_view unit) {
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
ParameterDescriptor whole(std::string_view id, std::string_view name, double def, double lo, double hi) {
    ParameterDescriptor p = parameter(id, name, def, lo, hi);
    p.step = 1.0;
    p.smoothingFrames = 0;
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

double clampd(double v, double lo, double hi) noexcept {
    v = finiteOr0(v);
    return v < lo ? lo : (v > hi ? hi : v);
}

// Renders `frames` frames in control chunks: control(at) once per chunk (at = the chunk's first frame in the
// block), then sample(i) for each of its frames (i = the frame in this render call).
template <class Control, class Sample>
void inChunks(uint32_t frames, uint32_t offset, Control&& control, Sample&& sample) noexcept {
    for (uint32_t start = 0; start < frames; start += kControlFrames) {
        const uint32_t end = std::min(frames, start + kControlFrames);
        control(offset + start);
        for (uint32_t i = start; i < end; ++i) sample(i);
    }
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
    parameter("drive", "Drive", 1.5, 1.0, 10.0),
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
    void reset() noexcept override { kick_.clear(); }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type == NoteMessageType::On) kick_.hit(m.velocity);
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        double volume = 0.8;
        inChunks(frames, offset,
                 [&](uint32_t at) noexcept {
                     kick_.set(kickSettings(b, at, 0), sr_);
                     volume = parameterAt(b, 6, at, 0.8);
                 },
                 [&](uint32_t i) noexcept { left[i] = right[i] = static_cast<float>(kick_.sample() * volume); });
    }

private:
    DrumSlot<lib::KickVoice, 2> kick_;
    double sr_ = 48000.0;
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
    void reset() noexcept override { snare_.clear(); }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type == NoteMessageType::On) snare_.hit(m.velocity);
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        double volume = 0.8;
        inChunks(frames, offset,
                 [&](uint32_t at) noexcept {
                     snare_.set(snareSettings(b, at, 0), sr_);
                     volume = parameterAt(b, 5, at, 0.8);
                 },
                 [&](uint32_t i) noexcept { left[i] = right[i] = static_cast<float>(snare_.sample() * volume); });
    }

private:
    DrumSlot<lib::SnareVoice, 2> snare_;
    double sr_ = 48000.0;
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
        hats_.clear();
        return true;
    }
    void reset() noexcept override { hats_.clear(); }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type == NoteMessageType::On) hats_.hit(m.key, m.velocity);
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        double volume = 0.8;
        inChunks(frames, offset,
                 [&](uint32_t at) noexcept {
                     hats_.update(static_cast<int>(parameterAt(b, 0, at, 0.0)), parameterAt(b, 3, at, 7000.0),
                                  parameterAt(b, 4, at, 0.5), parameterAt(b, 1, at, 0.045), parameterAt(b, 2, at, 0.3), sr_);
                     volume = parameterAt(b, 5, at, 0.8);
                 },
                 [&](uint32_t i) noexcept { left[i] = right[i] = static_cast<float>(hats_.sample() * volume); });
    }

private:
    HatPair hats_;
    double sr_ = 48000.0;
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

protected:
    void onNote(const NoteMessage& m) noexcept override {
        if (m.type != NoteMessageType::On) return;
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
        double kick = 1, snare = 0.8, clap = 0.7, hats = 0.6, volume = 0.8;
        inChunks(frames, offset,
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
    }
    DrumSlot<lib::KickVoice, 2> kick_;
    DrumSlot<lib::SnareVoice, 2> snare_;
    DrumSlot<lib::ClapVoice, 2> clap_;
    HatPair hats_;
    double sr_ = 48000.0;
};

// ---------- Mono note handling (bass, acid) ----------

// The held notes of a mono instrument, newest last (last-note priority): releasing the newest returns to
// the one held before it. Holds 16; a 17th forgets the oldest.
class NoteStack {
public:
    struct Held {
        uint32_t id = 0;
        double pitch = 60.0;
    };
    void push(uint32_t id, double pitch) noexcept {
        remove(id);
        if (count_ == kSize) {
            for (uint32_t i = 1; i < kSize; ++i) notes_[i - 1] = notes_[i];
            --count_;
        }
        notes_[count_++] = {id, pitch};
    }
    bool remove(uint32_t id) noexcept {
        for (uint32_t i = 0; i < count_; ++i)
            if (notes_[i].id == id) {
                for (uint32_t j = i + 1; j < count_; ++j) notes_[j - 1] = notes_[j];
                --count_;
                return true;
            }
        return false;
    }
    Held* find(uint32_t id) noexcept {
        for (uint32_t i = 0; i < count_; ++i)
            if (notes_[i].id == id) return &notes_[i];
        return nullptr;
    }
    const Held* top() const noexcept { return count_ ? &notes_[count_ - 1] : nullptr; }
    bool empty() const noexcept { return count_ == 0; }
    void clear() noexcept { count_ = 0; }

private:
    static constexpr uint32_t kSize = 16;
    Held notes_[kSize];
    uint32_t count_ = 0;
};

// What a mono instrument does with its notes: which pitch it plays and when its envelopes start and end. The
// pitch glides at the control rate (kControlFrames), in semitones.
class MonoNotes {
public:
    enum class Action : uint8_t { None, Start, Release };
    // `legato`: a note played while another is held glides there without restarting the envelopes.
    // Returns Start when the envelopes should restart (and the velocity is the new note's), Release when the
    // last held note ended.
    Action on(const NoteMessage& m, bool legato, bool sounding, double glideSeconds, double sampleRate) noexcept {
        const bool overlap = !held_.empty();
        held_.push(m.noteId, m.pitch);
        if (overlap || sounding) pitch_.glideTo(m.pitch, glideSeconds, sampleRate / kControlFrames);
        else pitch_.jump(m.pitch);
        if (overlap && legato) return Action::None;
        velocity_ = m.velocity;
        return Action::Start;
    }
    Action off(const NoteMessage& m, double glideSeconds, double sampleRate) noexcept {
        const NoteStack::Held* top = held_.top();
        const bool wasTop = top && top->id == m.noteId;
        if (!held_.remove(m.noteId)) return Action::None;
        if (held_.empty()) return Action::Release;
        if (wasTop) pitch_.glideTo(held_.top()->pitch, glideSeconds, sampleRate / kControlFrames);
        return Action::None;
    }
    // A held note's pitch now (a slide or a bend the host sends every 16 frames): followed within ~3 ms.
    void pitch(const NoteMessage& m, double sampleRate) noexcept {
        NoteStack::Held* h = held_.find(m.noteId);
        if (!h) return;
        h->pitch = m.pitch;
        if (held_.top() == h) pitch_.glideTo(m.pitch, 0.003, sampleRate / kControlFrames);
    }
    double nextPitch() noexcept { return pitch_.next(); }
    double velocity() const noexcept { return velocity_; }
    void clear() noexcept {
        held_.clear();
        pitch_.jump(48.0);
        velocity_ = 1.0;
    }

private:
    NoteStack held_;
    lib::Glide pitch_;
    double velocity_ = 1.0;
};

// ---------- Bass ----------

constexpr std::string_view kBassWaves[] = {"Saw", "Square"};
constexpr std::string_view kOffOn[] = {"Off", "On"};
const ParameterDescriptor kBassParams[] = {
    choice("wave", "Wave", 0.0, kBassWaves, 2),
    parameter("sub", "Sub", 0.5, 0.0, 1.0),
    hertz("cutoff", "Cutoff", 600.0, 40.0, 8000.0),
    parameter("resonance", "Resonance", 0.3, 0.0, 1.0),
    parameter("env", "Filter env", 0.5, 0.0, 1.0),
    seconds("decay", "Decay", 0.25, 0.02, 4.0),
    parameter("sustain", "Sustain", 0.6, 0.0, 1.0),
    seconds("glide", "Glide", 0.04, 0.001, 1.0),
    choice("legato", "Legato", 1.0, kOffOn, 2),
    parameter("drive", "Drive", 1.2, 1.0, 10.0),
    parameter("volume", "Volume", 0.6, 0.0, 1.0),
};
enum BassParam : uint32_t {
    kBassWave, kBassSub, kBassCutoff, kBassResonance, kBassEnv, kBassDecay, kBassSustain, kBassGlide, kBassLegato,
    kBassDrive, kBassVolume
};
const ModuleDescriptor kBass = instrument("org.caw.bass", "Bass", kBassParams, 96000);  // a 0.06 s release, effects aside

// One voice: a saw or square with a sine an octave below, a resonant low-pass the envelope opens, and an
// amplitude envelope. Overlapping notes glide (legato).
class BassInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kBass; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate;
        reset();
        return true;
    }
    void reset() noexcept override {
        notes_.clear();
        amp_.clear();
        fenv_.clear();
        filter_.clear();
        phase_ = sub_ = 0.0;
    }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        switch (m.type) {
            case NoteMessageType::On:
                if (!amp_.active()) phase_ = sub_ = 0.0;
                if (notes_.on(m, legato_, amp_.active(), glide_, sr_) == MonoNotes::Action::Start) {
                    amp_.gateOn();
                    fenv_.trigger();
                }
                break;
            case NoteMessageType::Off:
                if (notes_.off(m, glide_, sr_) == MonoNotes::Action::Release) amp_.gateOff();
                break;
            case NoteMessageType::Pitch: notes_.pitch(m, sr_); break;
            default: break;
        }
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        int wave = 0;
        double sub = 0.5, drive = 1.2, gain = 0.0, dt = 0.0;
        inChunks(frames, offset,
                 [&](uint32_t at) noexcept {
                     wave = static_cast<int>(parameterAt(b, kBassWave, at, 0.0));
                     sub = parameterAt(b, kBassSub, at, 0.5);
                     const double decay = parameterAt(b, kBassDecay, at, 0.25);
                     amp_.set(0.003, decay, parameterAt(b, kBassSustain, at, 0.6), 0.06, sr_);
                     fenv_.set(0.001, decay, sr_);
                     glide_ = parameterAt(b, kBassGlide, at, 0.04);
                     legato_ = parameterAt(b, kBassLegato, at, 1.0) >= 0.5;
                     drive = parameterAt(b, kBassDrive, at, 1.2);
                     dt = std::min(0.45, lib::noteHz(notes_.nextPitch()) / sr_);
                     const double octaves = 5.0 * parameterAt(b, kBassEnv, at, 0.5) * fenv_.level();
                     filter_.set(lib::shiftCutoff(parameterAt(b, kBassCutoff, at, 600.0), octaves, sr_),
                                 lib::resonanceQ(parameterAt(b, kBassResonance, at, 0.3)), sr_);
                     gain = (0.4 + 0.6 * notes_.velocity()) * parameterAt(b, kBassVolume, at, 0.6);
                 },
                 [&](uint32_t i) noexcept {
                     if (!amp_.active()) {
                         left[i] = right[i] = 0.0f;
                         fenv_.next();
                         return;
                     }
                     const double osc = wave == 1 ? lib::squareWave(phase_, dt) : lib::sawWave(phase_, dt);
                     const double x = osc * 0.7 + lib::sineWave(sub_) * sub * 0.8;
                     phase_ = lib::wrap01(phase_ + dt);
                     sub_ = lib::wrap01(sub_ + 0.5 * dt);
                     fenv_.next();
                     const double y = lib::drive(filter_.lowpass(x) * amp_.next(), drive) * gain;
                     left[i] = right[i] = static_cast<float>(y);
                     if (!amp_.active()) filter_.clear();
                 });
    }

private:
    MonoNotes notes_;
    lib::Adsr amp_;
    lib::AdEnvelope fenv_;
    lib::Svf filter_;
    double sr_ = 48000.0, phase_ = 0.0, sub_ = 0.0, glide_ = 0.04;
    bool legato_ = true;
};

// ---------- Acid synth ----------

const ParameterDescriptor kAcidParams[] = {
    choice("wave", "Wave", 0.0, kBassWaves, 2),
    hertz("cutoff", "Cutoff", 500.0, 40.0, 5000.0),
    parameter("resonance", "Resonance", 0.7, 0.0, 1.0),
    parameter("env", "Env mod", 0.6, 0.0, 1.0),
    seconds("decay", "Decay", 0.3, 0.05, 2.0),
    parameter("accent", "Accent", 0.5, 0.0, 1.0),
    seconds("slide", "Slide", 0.06, 0.005, 0.5),
    parameter("drive", "Drive", 2.0, 1.0, 10.0),
    parameter("volume", "Volume", 0.6, 0.0, 1.0),
};
enum AcidParam : uint32_t { kAcidWave, kAcidCutoff, kAcidResonance, kAcidEnv, kAcidDecay, kAcidAccent, kAcidSlide, kAcidDrive, kAcidVolume };
const ModuleDescriptor kAcid = instrument("org.caw.synth.acid", "Acid synth", kAcidParams, 96000);

// 303-style: one voice of saw or square into a resonant 4-pole ladder. Each new note restarts the filter
// envelope; a note played over a held one (or a pattern slide) glides there without restarting it. Notes
// with a velocity above 0.7 are accented, fully at 1: the envelope opens the filter further, decays faster
// and the note is louder, by `accent`.
class AcidInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kAcid; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate;
        reset();
        return true;
    }
    void reset() noexcept override {
        notes_.clear();
        amp_.clear();
        fenv_.clear();
        filter_.clear();
        phase_ = 0.0;
        accentLevel_ = 0.0;
    }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        switch (m.type) {
            case NoteMessageType::On:
                if (!amp_.active()) phase_ = 0.0;
                if (notes_.on(m, true, amp_.active(), slide_, sr_) == MonoNotes::Action::Start) {
                    amp_.gateOn();
                    fenv_.trigger();
                    accentLevel_ = clampd((m.velocity - 0.7) / 0.3, 0.0, 1.0);
                }
                break;
            case NoteMessageType::Off:
                if (notes_.off(m, slide_, sr_) == MonoNotes::Action::Release) amp_.gateOff();
                break;
            case NoteMessageType::Pitch: notes_.pitch(m, sr_); break;
            default: break;
        }
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        int wave = 0;
        double drive = 2.0, gain = 0.0, dt = 0.0;
        inChunks(frames, offset,
                 [&](uint32_t at) noexcept {
                     wave = static_cast<int>(parameterAt(b, kAcidWave, at, 0.0));
                     const double accent = parameterAt(b, kAcidAccent, at, 0.5) * accentLevel_;
                     const double decay = parameterAt(b, kAcidDecay, at, 0.3);
                     amp_.set(0.002, decay, 0.5, 0.04, sr_);
                     fenv_.set(0.001, decay * (1.0 - 0.5 * accent), sr_);
                     slide_ = parameterAt(b, kAcidSlide, at, 0.06);
                     drive = parameterAt(b, kAcidDrive, at, 2.0);
                     dt = std::min(0.45, lib::noteHz(notes_.nextPitch()) / sr_);
                     const double octaves = (5.0 * parameterAt(b, kAcidEnv, at, 0.6) + 2.5 * accent) * fenv_.level();
                     filter_.set(lib::shiftCutoff(parameterAt(b, kAcidCutoff, at, 500.0), octaves, sr_),
                                 parameterAt(b, kAcidResonance, at, 0.7), sr_);
                     gain = (0.4 + 0.6 * notes_.velocity()) * (1.0 + 0.6 * accent) * parameterAt(b, kAcidVolume, at, 0.6);
                 },
                 [&](uint32_t i) noexcept {
                     fenv_.next();
                     if (!amp_.active()) {
                         left[i] = right[i] = 0.0f;
                         return;
                     }
                     const double osc = wave == 1 ? lib::squareWave(phase_, dt) : lib::sawWave(phase_, dt);
                     phase_ = lib::wrap01(phase_ + dt);
                     const double y = lib::drive(filter_.process(osc * 0.7) * amp_.next(), drive) * gain;
                     left[i] = right[i] = static_cast<float>(y);
                     if (!amp_.active()) filter_.clear();
                 });
    }

private:
    MonoNotes notes_;
    lib::Adsr amp_;
    lib::AdEnvelope fenv_;
    lib::Ladder filter_;
    double sr_ = 48000.0, phase_ = 0.0, slide_ = 0.06, accentLevel_ = 0.0;
};

// ---------- Morph synth ----------

constexpr uint32_t kMaxUnison = 16;
const ParameterDescriptor kMorphParams[] = {
    parameter("shape", "Shape", 0.45, 0.0, 1.0),
    parameter("drift", "Drift", 0.25, 0.0, 1.0),
    whole("unison", "Unison", 7.0, 1.0, kMaxUnison),
    parameter("detune", "Detune", 0.18, 0.0, 1.0),
    parameter("spread", "Stereo spread", 0.7, 0.0, 1.0),
    hertz("cutoff", "Cutoff", 1800.0, 100.0, 16000.0),
    parameter("resonance", "Resonance", 0.15, 0.0, 1.0),
    seconds("attack", "Attack", 0.3, 0.001, 10.0),
    seconds("decay", "Decay", 0.5, 0.001, 10.0),
    parameter("sustain", "Sustain", 0.8, 0.0, 1.0),
    seconds("release", "Release", 0.8, 0.001, 10.0),
    parameter("volume", "Volume", 0.5, 0.0, 1.0),
};
enum MorphParam : uint32_t {
    kMorphShape, kMorphDrift, kMorphUnison, kMorphDetune, kMorphSpread, kMorphCutoff, kMorphResonance, kMorphAttack,
    kMorphDecay, kMorphSustain, kMorphRelease, kMorphVolume
};
const ModuleDescriptor kMorph = instrument("org.caw.synth.morph", "Morph synth", kMorphParams, 1920000);  // 10 s at 192 kHz

// 8 voices, each a stack of up to 16 detuned copies (unison, spread across the stereo field) of one
// waveform that morphs from sine through triangle and saw to square (`shape`; the .caw wavetable pad's
// table.basic). `drift` sweeps the shape with a slow sine over 16 beats. A resonant low-pass per side (a
// note's timbre opens it), an ADSR envelope; velocity and pressure set the level.
class MorphInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return kMorph; }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate;
        reset();
        return true;
    }
    void reset() noexcept override {
        voices_.clear();
        lfo_ = 0.0;
        started_ = 0;
        unison_ = 0;
        detune_ = spread_ = -1.0;
    }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        switch (m.type) {
            case NoteMessageType::On: {
                Voice& v = voices_.start(m.noteId);
                const bool fresh = !v.amp.active();
                v.velocity = m.velocity;
                v.pressure = 1.0;
                v.timbre = 0.0;
                v.freq = lib::noteHz(m.pitch);
                v.amp.gateOn();
                if (fresh) {  // a stolen voice continues from where it is (no click)
                    ++started_;
                    for (uint32_t u = 0; u < kMaxUnison; ++u)
                        v.phase[u] = u == 0 ? 0.0
                                            : static_cast<double>(hash32(started_ * 0x9E3779B9U + u * 0x85EBCA6BU)) /
                                                  4294967296.0;
                    v.left.clear();
                    v.right.clear();
                }
                break;
            }
            case NoteMessageType::Off:
                if (Voice* v = voices_.find(m.noteId); v && v->held) {
                    v->held = false;
                    v->amp.gateOff();
                }
                break;
            case NoteMessageType::Pitch:
                if (Voice* v = voices_.find(m.noteId)) v->freq = lib::noteHz(m.pitch);
                break;
            case NoteMessageType::Pressure:
                if (Voice* v = voices_.find(m.noteId)) v->pressure = m.value;
                break;
            case NoteMessageType::Timbre:
                if (Voice* v = voices_.find(m.noteId)) v->timbre = m.value;
                break;
            case NoteMessageType::Other: break;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        const double tempo = b.transport && b.transport->tempo > 0.0 ? b.transport->tempo : 120.0;
        for (uint32_t start = 0; start < frames; start += kControlFrames) {
            const uint32_t end = std::min(frames, start + kControlFrames);
            const uint32_t at = offset + start;
            updateUnison(static_cast<uint32_t>(clampd(parameterAt(b, kMorphUnison, at, 7.0), 1.0, kMaxUnison)),
                         clampd(parameterAt(b, kMorphDetune, at, 0.18), 0.0, 1.0),
                         clampd(parameterAt(b, kMorphSpread, at, 0.7), 0.0, 1.0));
            const double drift = parameterAt(b, kMorphDrift, at, 0.25) * detSin(kTwoPi * lfo_);
            const double shape = clampd(parameterAt(b, kMorphShape, at, 0.45) + drift, 0.0, 1.0);
            lfo_ = lib::wrap01(lfo_ + static_cast<double>(end - start) * tempo / (60.0 * 16.0 * sr_));
            const double attack = parameterAt(b, kMorphAttack, at, 0.3), decay = parameterAt(b, kMorphDecay, at, 0.5);
            const double sustain = parameterAt(b, kMorphSustain, at, 0.8), release = parameterAt(b, kMorphRelease, at, 0.8);
            const double cutoff = parameterAt(b, kMorphCutoff, at, 1800.0);
            const double q = lib::resonanceQ(parameterAt(b, kMorphResonance, at, 0.15));
            const double volume = parameterAt(b, kMorphVolume, at, 0.5) * 0.6 * unisonGain_;
            for (Voice& v : voices_) {
                if (!v.active) continue;
                v.amp.set(attack, decay, sustain, release, sr_);
                const double fc = lib::shiftCutoff(cutoff, 4.0 * v.timbre, sr_);
                v.left.set(fc, q, sr_);
                v.right.set(fc, q, sr_);
                double dt[kMaxUnison];
                for (uint32_t u = 0; u < unison_; ++u) dt[u] = std::min(0.45, v.freq * ratio_[u] / sr_);
                const double level = (0.5 + 0.5 * v.velocity) * v.pressure * volume;
                for (uint32_t i = start; i < end; ++i) {
                    double l = 0.0, r = 0.0;
                    for (uint32_t u = 0; u < unison_; ++u) {
                        const double x = lib::morphWave(v.phase[u], dt[u], shape);
                        v.phase[u] = lib::wrap01(v.phase[u] + dt[u]);
                        l += x * gainL_[u];
                        r += x * gainR_[u];
                    }
                    const double a = v.amp.next() * level;
                    left[i] += static_cast<float>(v.left.lowpass(l) * a);
                    right[i] += static_cast<float>(v.right.lowpass(r) * a);
                }
                if (!v.amp.active()) v.active = false;
            }
        }
    }

private:
    struct Voice {
        bool active = false, held = false;
        uint32_t noteId = 0;
        uint64_t age = 0;
        lib::Adsr amp;
        lib::Svf left, right;
        double phase[kMaxUnison] = {};
        double freq = 261.6255653005986, velocity = 1.0, pressure = 1.0, timbre = 0.0;
    };
    // Unison copies spread evenly over +-detune semitones and, by `spread`, from left to right.
    void updateUnison(uint32_t unison, double detune, double spread) noexcept {
        if (unison == unison_ && detune == detune_ && spread == spread_) return;
        unison_ = unison;
        detune_ = detune;
        spread_ = spread;
        unisonGain_ = 1.0 / std::sqrt(static_cast<double>(unison));
        for (uint32_t u = 0; u < unison; ++u) {
            const double at = unison == 1 ? 0.0 : 2.0 * u / (unison - 1) - 1.0;
            ratio_[u] = detExp(detune * at * (0.69314718055994530942 / 12.0));
            const lib::PanGains g = lib::constantPowerPan(spread * at);
            gainL_[u] = g.left * 1.41421356237309505;  // the centre stays at unity
            gainR_[u] = g.right * 1.41421356237309505;
        }
    }
    VoicePool<Voice, 8> voices_;
    double sr_ = 48000.0, lfo_ = 0.0;
    uint32_t started_ = 0, unison_ = 0;
    double detune_ = -1.0, spread_ = -1.0, unisonGain_ = 1.0;
    double ratio_[kMaxUnison] = {}, gainL_[kMaxUnison] = {}, gainR_[kMaxUnison] = {};
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
    registry.add(kBass, &make<BassInstrument>);
    registry.add(kAcid, &make<AcidInstrument>);
    registry.add(kMorph, &make<MorphInstrument>);
}

}  // namespace caw
