// The built-in MIDI effects (1.1.0): Arpeggiator, Chords (by scale), Scale (snap or filter), Note echo and Humanize.
#include <algorithm>
#include <cmath>
#include <new>

#include "builtin_effects.h"
#include "caw/library/music.hpp"
#include "midi_fx.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0). Each effect keeps a small fixed table of the input notes it is shaping
// (sized to the job: 64 arpeggio keys, 128 chords or echoed notes, 256 snapped or humanized notes) and the base's
// queue sized to what it schedules; nothing grows after activate. Parameters are read at each event's or step's
// frame (they jump: no smoothing), so automation lands on the same samples at any block size.

namespace caw::midifx {

namespace {

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, false, 0.0f},
    {"notes_out", PortType::Event, ChannelLayout::None, false, 0, false, 0.0f},
};

ModuleDescriptor midiDescriptor(std::string_view id, std::string_view name, const fx::ParamTable& t) {
    ModuleDescriptor d;
    d.id = id;
    d.name = name;
    d.role = ModuleRole::EventProcessor;
    d.ports = kPorts;
    d.portCount = 2;
    d.parameters = t.data();
    d.parameterCount = t.size();
    d.capabilities = kCapabilityNotesIn | kCapabilityMidiIn | kCapabilityEventsOut | kCapabilityNeedsTransport;
    d.cpuClass = CpuClass::Light;
    return d;
}

// A MIDI effect's knobs jump (no ramp): a note reads the value at its own frame.
ParameterDescriptor& flat(ParameterDescriptor& p) {
    p.smoothingFrames = 0;
    return p;
}
ParameterDescriptor& whole(ParameterDescriptor& p) {
    p.smoothingFrames = 0;
    p.step = 1.0;
    return p;
}

constexpr std::string_view kKeys[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
constexpr std::string_view kScaleNames[] = {"Major",          "Minor",         "Dorian",           "Phrygian",
                                            "Lydian",         "Mixolydian",    "Locrian",          "Harmonic minor",
                                            "Melodic minor",  "Major pentatonic", "Minor pentatonic", "Blues",
                                            "Chromatic",      "Whole tone"};
static_assert(std::size(kScaleNames) == lib::kScaleCount);
constexpr std::string_view kOffOn[] = {"Off", "On"};

long floorDiv(long a, long b) noexcept { return a >= 0 ? a / b : -((-a + b - 1) / b); }

// A key: root pitch class 0..11 and a scale shape.
struct Key {
    int root = 0;
    const lib::ScaleShape* sc = &lib::kScales[0];
    Key(int r, int s) noexcept : root(std::clamp(r, 0, 11)), sc(&lib::kScales[std::clamp(s, 0, lib::kScaleCount - 1)]) {}
    bool contains(long note) const noexcept {
        const long pc = ((note - root) % 12 + 12) % 12;
        for (int i = 0; i < sc->count; ++i)
            if (sc->steps[i] == pc) return true;
        return false;
    }
    // The note of degree d (0: the root in octave 0, so C = 0; any degree, any octave).
    long note(long d) const noexcept {
        const long o = floorDiv(d, sc->count);
        return root + 12 * o + sc->steps[d - o * sc->count];
    }
    // The highest degree whose note is at or below `n`.
    long degreeBelow(long n) const noexcept {
        const long rel = n - root, o = floorDiv(rel, 12), pc = rel - 12 * o;
        int i = 0;
        while (i + 1 < sc->count && sc->steps[i + 1] <= pc) ++i;
        return o * sc->count + i;
    }
};

double clampPitch(double p) noexcept { return std::clamp(p, 0.0, 127.0); }

Event noteOnWithVelocity(const Event& e, double velocity) noexcept {
    Event x = e;
    const double v = std::clamp(velocity, 0.0, 1.0);
    uint32_t vel = static_cast<uint32_t>(v * 65535.0 + 0.5);
    if (vel == 0) vel = 1;
    x.data[1] = (vel << 16) | (x.data[1] & 0xFFFFu);
    return x;
}

// A small table of input notes by id, packed (remove moves the last in): a linear search, as only a handful are
// held at once.
template <class Rec, uint32_t N>
struct Table {
    Rec items[N];
    uint32_t used = 0;
    Rec* find(uint32_t id) noexcept {
        for (uint32_t i = 0; i < used; ++i)
            if (items[i].id == id) return &items[i];
        return nullptr;
    }
    Rec* add(uint32_t id) noexcept {
        if (Rec* r = find(id)) return r;
        if (used == N) return nullptr;
        items[used] = Rec{};
        items[used].id = id;
        return &items[used++];
    }
    void remove(Rec* r) noexcept { *r = items[--used]; }
};

// ---------------------------------------------------------------------------------------------------------------
// Arpeggiator: the held keys one after another (or all at once) on a tempo grid.
// While the song plays, steps fall on the song's grid of the rate (the step at song sample round(n x step x
// frames-per-beat), odd steps later by the swing), so a pass sounds the same from every Play and a note that starts
// on a step plays on it; while stopped, the grid starts at the first key. Each step ends after `gate` of the step.

enum ArpParam : uint32_t { aRate, aPattern, aOctaves, aGate, aSwing, aHold, aVelMode, aVelocity, aSeed, aCount };
constexpr std::string_view kRates[] = {"1/32", "1/16 T", "1/16", "1/16 D", "1/8 T", "1/8",   "1/8 D", "1/4 T",
                                       "1/4",  "1/4 D",  "1/2 T", "1/2",   "1/2 D", "1 bar", "2 bars"};
static_assert(std::size(kRates) + 1 == std::size(fx::kSyncWholeNotes));
constexpr std::string_view kPatterns[] = {"Up", "Down", "Up-down", "Down-up", "As played", "Random", "Chord"};
constexpr std::string_view kVelModes[] = {"As played", "Fixed"};

const fx::ParamTable& arpParams() {
    static const fx::ParamTable t = [] {
        fx::ParamTable p;
        p.pick("rate", "Rate", 2, kRates);
        p.pick("pattern", "Pattern", 0, kPatterns);
        whole(p.num("octaves", "Octaves", 1, 1, 4));
        flat(p.num("gate", "Gate", 0.5, 0.05, 1.0));
        flat(p.num("swing", "Swing", 0.0, 0.0, 0.5));
        p.pick("hold", "Hold", 0, kOffOn);
        p.pick("vel_mode", "Velocity", 0, kVelModes);
        flat(p.num("velocity", "Fixed velocity", 0.8, 0.01, 1.0));
        whole(p.num("seed", "Seed", 1, 0, 9999));
        return p;
    }();
    return t;
}
const ModuleDescriptor& arpDescriptor() {
    static const ModuleDescriptor d = midiDescriptor("org.caw.midi.arp", "Arpeggiator", arpParams());
    return d;
}

class Arp final : public MidiEffect {
public:
    Arp() noexcept : MidiEffect(arpDescriptor(), 256) {}

protected:
    struct Held {
        uint32_t id = 0;
        double pitch = 60, vel = 1;
        uint8_t channel = 0;
        bool down = true;
    };
    static constexpr uint32_t kMax = 64;

    void clearState() noexcept override {
        count_ = down_ = 0;
        counter_ = 0;
        freeNext_ = 0;
        freeIdx_ = 0;
        wasPlaying_ = false;
        lastPitch_ = -1;
    }
    bool busy() const noexcept override { return count_ > 0; }
    uint32_t heldCount() const noexcept override { return count_; }

    int findHeld(uint32_t id) const noexcept {
        for (uint32_t i = 0; i < count_; ++i)
            if (held_[i].id == id) return static_cast<int>(i);
        return -1;
    }
    void removeAt(uint32_t i) noexcept {  // keeps the played order
        for (; i + 1 < count_; ++i) held_[i] = held_[i + 1];
        --count_;
    }

    void note(const Event& e, const NoteMessage& m) noexcept override {
        const int at = findHeld(m.noteId);
        switch (m.type) {
            case NoteMessageType::On: {
                if (on(aHold, m.frame) && down_ == 0) count_ = 0;  // a new chord replaces the latched one
                if (at >= 0) removeAt(static_cast<uint32_t>(at));
                if (count_ == 0) {  // the first key: the pattern starts over, and a free grid starts here
                    counter_ = 0;
                    freeNext_ = static_cast<double>(now() + m.frame);
                    freeIdx_ = 0;
                }
                if (count_ < kMax) {
                    held_[count_++] = {m.noteId, m.pitch, m.velocity, m.channel, true};
                    ++down_;
                }
                return;
            }
            case NoteMessageType::Off:
                if (at < 0) return emit(m.frame, e);
                if (held_[at].down) held_[at].down = false, --down_;
                if (!on(aHold, m.frame)) removeAt(static_cast<uint32_t>(at));
                return;
            default:
                if (at < 0) emit(m.frame, e);  // the keys' own motion is not played; anything else passes
                return;
        }
    }

    void tick(uint32_t from, uint32_t to) noexcept override {
        if (!on(aHold, from))  // Hold turned off: latched keys that are up go
            for (uint32_t i = count_; i-- > 0;)
                if (!held_[i].down) removeAt(i);
        const bool grid = playing();
        if (count_ == 0) {
            wasPlaying_ = grid;
            return;
        }
        const int r = std::clamp(choice(aRate, from), 0, static_cast<int>(std::size(kRates)) - 1);
        const double len = fx::kSyncWholeNotes[r + 1] * 4.0 * framesPerBeat();  // frames per step
        const double swing = std::clamp(param(aSwing, from), 0.0, 0.5);
        if (grid) {
            const int64_t s0 = songSample(0);
            auto stepAt = [&](int64_t n) {
                return static_cast<int64_t>(std::floor((static_cast<double>(n) + ((n & 1) ? swing : 0.0)) * len + 0.5));
            };
            int64_t n = static_cast<int64_t>(std::floor(static_cast<double>(s0 + from) / len)) - 1;
            while (stepAt(n) < s0 + from) ++n;
            for (int64_t t; (t = stepAt(n)) < s0 + to; ++n) step(static_cast<uint32_t>(t - s0), n, stepAt(n + 1) - t);
        } else {
            if (wasPlaying_) freeNext_ = static_cast<double>(now() + from), freeIdx_ = 0;
            for (;;) {
                const double sw = (freeIdx_ & 1) ? swing * len : 0.0;
                int64_t t = static_cast<int64_t>(std::floor(freeNext_ + sw + 0.5));
                if (t >= now() + to) break;
                t = std::max<int64_t>(t, now() + from);
                const double nextSw = (freeIdx_ & 1) ? 0.0 : swing * len;
                const int64_t next = static_cast<int64_t>(std::floor(freeNext_ + len + nextSw + 0.5));
                step(static_cast<uint32_t>(t - now()), freeIdx_, next - t);
                freeNext_ += len;
                ++freeIdx_;
            }
        }
        wasPlaying_ = grid;
    }

    void step(uint32_t frame, int64_t n, int64_t stepLen) noexcept {
        const uint32_t h = count_;
        if (h == 0) return;
        const int oct = std::clamp(static_cast<int>(param(aOctaves, frame) + 0.5), 1, 4);
        const int pattern = std::clamp(choice(aPattern, frame), 0, static_cast<int>(std::size(kPatterns)) - 1);
        const bool fixed = choice(aVelMode, frame) == 1;
        const double fixedVel = param(aVelocity, frame);
        const int64_t offAfter = std::max<int64_t>(1, static_cast<int64_t>(std::floor(param(aGate, frame) * static_cast<double>(stepLen) + 0.5)));
        uint32_t order[kMax];  // the keys by pitch (insertion sort: a handful)
        for (uint32_t i = 0; i < h; ++i) {
            uint32_t j = i;
            while (j > 0 && held_[order[j - 1]].pitch > held_[i].pitch) order[j] = order[j - 1], --j;
            order[j] = i;
        }
        const int64_t L = static_cast<int64_t>(h) * oct;
        const int64_t c = counter_++;
        auto play = [&](uint32_t key, int octave) {
            const Held& k = held_[key];
            const double pitch = clampPitch(k.pitch + 12.0 * octave);
            const uint32_t id = newId();
            const uint8_t mk = notes::keyOf(pitch);
            emit(frame, notes::noteOn(frame, id, pitch, fixed ? fixedVel : k.vel, k.channel));
            schedule(now() + frame + offAfter, notes::noteOff(0, id, mk, 0.0, k.channel));
            lastPitch_ = pitch;
        };
        if (pattern == 6) {  // Chord: every key at once, an octave further each step
            const int o = static_cast<int>(c % oct);
            for (uint32_t i = 0; i < h; ++i) play(order[i], o);
            return;
        }
        int64_t idx;
        switch (pattern) {
            case 1: idx = L - 1 - c % L; break;
            case 2:
            case 3: {
                const int64_t period = L > 1 ? 2 * L - 2 : 1, k = c % period;
                idx = k < L ? k : period - k;
                if (pattern == 3) idx = L - 1 - idx;
                break;
            }
            case 5:
                idx = static_cast<int64_t>(unit(static_cast<uint32_t>(param(aSeed, frame)), static_cast<uint64_t>(playing() ? n : c),
                                                h, 0x41) * static_cast<double>(L));
                idx = std::min(idx, L - 1);
                break;
            default: idx = c % L; break;
        }
        const uint32_t which = static_cast<uint32_t>(idx % h);
        play(pattern == 4 ? which : order[which], static_cast<int>(idx / h));
    }

    uint32_t fillDisplay(float* out) noexcept override {
        const int r = std::clamp(choice(aRate, 0), 0, static_cast<int>(std::size(kRates)) - 1);
        out[0] = static_cast<float>(counter_);
        out[1] = static_cast<float>(lastPitch_);
        out[2] = static_cast<float>(1.0 / (fx::kSyncWholeNotes[r + 1] * 4.0));  // steps per beat
        out[3] = playing() ? 1.0f : 0.0f;
        out[4] = static_cast<float>(choice(aPattern, 0));
        const uint32_t n = std::min<uint32_t>(count_, 16);
        out[5] = static_cast<float>(n);
        for (uint32_t i = 0; i < 16; ++i) out[6 + i] = i < n ? static_cast<float>(held_[i].pitch) : -1.0f;
        return 22;
    }

private:
    Held held_[kMax];
    uint32_t count_ = 0, down_ = 0;
    int64_t counter_ = 0, freeIdx_ = 0;
    double freeNext_ = 0, lastPitch_ = -1;
    bool wasPlaying_ = false;
};

// ---------------------------------------------------------------------------------------------------------------
// Chords: each key plays a chord built on it from the key's scale (stacked scale thirds, so C in C major plays C
// major and D plays D minor); a key outside the scale is moved to the nearest scale note first. The played note
// keeps its id (its root tone); the added tones get ids of their own and follow its bends.

enum ChordParam : uint32_t { cRoot, cScale, cType, cInversion, cVoicing, cStrum, cAdded, cCount };
constexpr std::string_view kChordTypes[] = {"Triad", "Seventh", "Ninth", "Sus2", "Sus4", "Sixth", "Power", "Octaves"};
constexpr std::string_view kVoicings[] = {"Close", "Open", "Wide"};
constexpr int kChordDegrees[6][5] = {{0, 2, 4}, {0, 2, 4, 6}, {0, 2, 4, 6, 8}, {0, 1, 4}, {0, 3, 4}, {0, 2, 4, 5}};
constexpr int kChordDegreeCount[6] = {3, 4, 5, 3, 3, 4};
constexpr int kChordSemis[8][5] = {{0, 4, 7}, {0, 4, 7, 10}, {0, 4, 7, 10, 14}, {0, 2, 7}, {0, 5, 7}, {0, 4, 7, 9}, {0, 7, 12}, {0, 12, 24}};
constexpr int kChordSemiCount[8] = {3, 4, 5, 3, 3, 4, 3, 3};

const fx::ParamTable& chordParams() {
    static const fx::ParamTable t = [] {
        fx::ParamTable p;
        p.pick("root", "Key", 0, kKeys);
        p.pick("scale", "Scale", 0, kScaleNames);
        p.pick("type", "Chord", 0, kChordTypes);
        whole(p.num("inversion", "Inversion", 0, 0, 3));
        p.pick("voicing", "Voicing", 0, kVoicings);
        flat(p.num("strum", "Strum", 0, 0, 200, "ms"));
        flat(p.num("added", "Added velocity", 1.0, 0.05, 1.0));
        return p;
    }();
    return t;
}
const ModuleDescriptor& chordDescriptor() {
    static const ModuleDescriptor d = midiDescriptor("org.caw.midi.chords", "Chords", chordParams());
    return d;
}

class Chords final : public MidiEffect {
public:
    Chords() noexcept : MidiEffect(chordDescriptor(), 256) {}

protected:
    struct Rec {
        uint32_t id = 0;
        int n = 0;
        uint32_t ids[5] = {};
        int semis[5] = {};  // each tone above the played key (its whole-note part)
        uint8_t keys[5] = {};
        int64_t onAt[5] = {};
        uint8_t channel = 0;
    };
    void clearState() noexcept override {
        table_.used = 0;
        lastIn_ = -1;
        lastN_ = 0;
    }
    uint32_t heldCount() const noexcept override { return table_.used; }

    void note(const Event& e, const NoteMessage& m) noexcept override {
        const int64_t t = now() + m.frame;
        Rec* r = table_.find(m.noteId);
        if (m.type == NoteMessageType::On) {
            if (r) release(*r, m.frame, t), table_.remove(r);  // the same id again: the old chord ends
            r = table_.add(m.noteId);
            if (!r) return emit(m.frame, e);
            const long n0 = std::lround(m.pitch);
            const double frac = m.pitch - static_cast<double>(n0);
            const Key key(choice(cRoot, m.frame), choice(cScale, m.frame));
            const int type = std::clamp(choice(cType, m.frame), 0, 7);
            int semis[5];
            int count;
            if (type >= 6 || key.sc->count != 7) {  // fixed shapes (power, octaves; scales without thirds)
                count = kChordSemiCount[type];
                for (int j = 0; j < count; ++j) semis[j] = kChordSemis[type][j];
                if (key.sc->count != 12 && type < 6 && !key.contains(n0)) {  // still in the key's nearest note
                    const long d = key.degreeBelow(n0);
                    const long lo = key.note(d), hi = key.note(d + 1);
                    const long s = (hi - n0 < n0 - lo) ? hi : lo;
                    for (int j = 0; j < count; ++j) semis[j] += static_cast<int>(s - n0);
                }
            } else {
                long d = key.degreeBelow(n0);
                if (key.note(d + 1) - n0 < n0 - key.note(d)) ++d;  // nearest scale note (a tie goes down)
                count = kChordDegreeCount[type];
                for (int j = 0; j < count; ++j) semis[j] = static_cast<int>(key.note(d + kChordDegrees[type][j]) - n0);
            }
            const int inv = std::clamp(static_cast<int>(param(cInversion, m.frame) + 0.5), 0, 3);
            for (int j = 0; j < std::min(inv, count - 1); ++j) semis[j] += 12;
            const int voicing = choice(cVoicing, m.frame);
            if (voicing >= 1 && count >= 3) semis[1] += 12;
            if (voicing == 2 && count >= 4) semis[3] += 12;
            int order[5];  // tones low to high (the strum's order); the played note is tone 0
            for (int i = 0; i < count; ++i) {
                int j = i;
                while (j > 0 && semis[order[j - 1]] > semis[i]) order[j] = order[j - 1], --j;
                order[j] = i;
            }
            const int64_t strum = static_cast<int64_t>(std::floor(param(cStrum, m.frame) * rate() / 1000.0 + 0.5));
            const double added = param(cAdded, m.frame);
            r->n = count;
            r->channel = m.channel;
            for (int p = 0; p < count; ++p) {
                const int j = order[p];
                const double pitch = static_cast<double>(n0 + semis[j]) + frac;
                r->semis[p] = semis[j];
                r->ids[p] = 0;
                if (pitch < 0.0 || pitch > 127.0) continue;
                const uint32_t id = j == 0 ? m.noteId : newId();
                r->keys[p] = notes::keyOf(pitch);
                r->onAt[p] = t + p * strum;
                if (schedule(r->onAt[p], notes::noteOn(0, id, pitch, j == 0 ? m.velocity : m.velocity * added, m.channel)))
                    r->ids[p] = id;
                last_[p] = static_cast<float>(pitch);
            }
            lastIn_ = m.pitch;
            lastN_ = count;
            return;
        }
        if (!r) return emit(m.frame, e);
        if (m.type == NoteMessageType::Off) {
            release(*r, m.frame, t);
            table_.remove(r);
            return;
        }
        for (int p = 0; p < r->n; ++p) {  // the played note's motion moves the whole chord
            if (!r->ids[p] || r->onAt[p] > t) continue;
            if (m.type == NoteMessageType::Pitch) {
                emit(m.frame, notes::notePitch(m.frame, r->ids[p], r->keys[p], clampPitch(m.pitch + r->semis[p]), r->channel));
            } else {
                Event x = withKey(e, r->keys[p]);
                x.noteId = r->ids[p];
                emit(m.frame, x);
            }
        }
    }
    void release(Rec& r, uint32_t frame, int64_t t) noexcept {
        for (int p = 0; p < r.n; ++p) {
            if (!r.ids[p]) continue;
            if (r.onAt[p] > t && cancel(r.ids[p])) continue;  // strummed, not sounding yet: never starts
            emit(frame, notes::noteOff(frame, r.ids[p], r.keys[p], 0.0, r.channel));
        }
    }
    uint32_t fillDisplay(float* out) noexcept override {
        out[0] = static_cast<float>(lastIn_);
        out[1] = static_cast<float>(lastN_);
        for (int p = 0; p < 5; ++p) out[2 + p] = p < lastN_ ? last_[p] : -1.0f;
        return 7;
    }

private:
    Table<Rec, 128> table_;
    double lastIn_ = -1;
    int lastN_ = 0;
    float last_[5] = {};
};

// ---------------------------------------------------------------------------------------------------------------
// Scale: each note moved into the key (to the nearest scale note, down or up) or left out (Filter), then moved by
// whole scale degrees (Transpose). A note keeps its id and microtonal fraction; its bends move with it.

enum ScaleParam : uint32_t { sRoot, sScale, sMode, sTranspose, sCount };
constexpr std::string_view kSnapModes[] = {"Nearest", "Down", "Up", "Filter"};

const fx::ParamTable& scaleParams() {
    static const fx::ParamTable t = [] {
        fx::ParamTable p;
        p.pick("root", "Key", 0, kKeys);
        p.pick("scale", "Scale", 0, kScaleNames);
        p.pick("mode", "Mode", 0, kSnapModes);
        whole(p.num("transpose", "Transpose", 0, -7, 7, "degrees"));
        return p;
    }();
    return t;
}
const ModuleDescriptor& scaleDescriptor() {
    static const ModuleDescriptor d = midiDescriptor("org.caw.midi.scale", "Scale", scaleParams());
    return d;
}

class ScaleFx final : public MidiEffect {
public:
    ScaleFx() noexcept : MidiEffect(scaleDescriptor(), 0) {}

protected:
    struct Rec {
        uint32_t id = 0;
        double delta = 0;
        uint8_t key = 60;
        bool drop = false;
    };
    void clearState() noexcept override {
        table_.used = 0;
        lastIn_ = lastOut_ = -1;
    }
    uint32_t heldCount() const noexcept override { return table_.used; }

    void note(const Event& e, const NoteMessage& m) noexcept override {
        Rec* r = table_.find(m.noteId);
        if (m.type == NoteMessageType::On) {
            r = r ? r : table_.add(m.noteId);
            if (!r) return emit(m.frame, e);
            const Key key(choice(sRoot, m.frame), choice(sScale, m.frame));
            const int mode = choice(sMode, m.frame);
            const long n0 = std::lround(m.pitch);
            long s = n0;
            bool drop = false;
            if (!key.contains(n0)) {
                if (mode == 3) {
                    drop = true;
                } else {
                    for (long d = 1; d < 12; ++d) {
                        if (mode != 2 && key.contains(n0 - d)) { s = n0 - d; break; }
                        if (mode != 1 && key.contains(n0 + d)) { s = n0 + d; break; }
                    }
                }
            }
            if (const long tr = std::lround(param(sTranspose, m.frame)); tr != 0 && !drop) s = key.note(key.degreeBelow(s) + tr);
            const double pitch = m.pitch + static_cast<double>(s - n0);
            drop = drop || pitch < 0.0 || pitch > 127.0;
            r->drop = drop;
            r->delta = static_cast<double>(s - n0);
            r->key = notes::keyOf(pitch);
            lastIn_ = m.pitch;
            lastOut_ = drop ? -1.0 : pitch;
            if (!drop) emit(m.frame, notes::noteOn(m.frame, m.noteId, pitch, m.velocity, m.channel));
            return;
        }
        if (!r) return emit(m.frame, e);
        const Rec rec = *r;
        if (m.type == NoteMessageType::Off) table_.remove(r);
        if (rec.drop) return;
        if (m.type == NoteMessageType::Pitch)
            emit(m.frame, notes::notePitch(m.frame, m.noteId, rec.key, clampPitch(m.pitch + rec.delta), m.channel));
        else
            emit(m.frame, withKey(e, rec.key));
    }
    uint32_t fillDisplay(float* out) noexcept override {
        const Key key(choice(sRoot, 0), choice(sScale, 0));
        out[0] = static_cast<float>(lastIn_);
        out[1] = static_cast<float>(lastOut_);
        out[2] = static_cast<float>(key.root);
        out[3] = static_cast<float>(choice(sScale, 0));
        for (int pc = 0; pc < 12; ++pc) out[4 + pc] = key.contains(pc) ? 1.0f : 0.0f;
        return 16;
    }

private:
    Table<Rec, 256> table_;
    double lastIn_ = -1, lastOut_ = -1;
};

// ---------------------------------------------------------------------------------------------------------------
// Note echo: each note repeats `repeats` times, `time` apart (synced or free), each repeat quieter by `decay` and
// moved by `pitch` semitones; a repeat lasts as long as the played note. Dry plays the played note itself.

enum EchoParam : uint32_t { eSync, eTime, eRepeats, eDecay, ePitch, eDry, eCount };

const fx::ParamTable& echoParams() {
    static const fx::ParamTable t = [] {
        fx::ParamTable p;
        p.pick("sync", "Sync", 6, fx::kSyncDivisions);
        flat(p.expo("time", "Time", 250, 10, 2000, "ms"));
        whole(p.num("repeats", "Repeats", 3, 1, 16));
        flat(p.num("decay", "Decay", 0.6, 0.05, 1.0));
        whole(p.num("pitch", "Pitch", 0, -24, 24, "st"));
        p.pick("dry", "Dry", 1, kOffOn);
        return p;
    }();
    return t;
}
const ModuleDescriptor& echoDescriptor() {
    static const ModuleDescriptor d = midiDescriptor("org.caw.midi.echo", "Note echo", echoParams());
    return d;
}

class Echo final : public MidiEffect {
public:
    Echo() noexcept : MidiEffect(echoDescriptor(), 2048) {}

protected:
    struct Rec {
        uint32_t id = 0;
        int n = 0;
        int64_t gap = 1;
        bool dry = true;
        uint8_t channel = 0;
        uint32_t ids[16] = {};
        uint8_t keys[16] = {};
    };
    void clearState() noexcept override {
        table_.used = 0;
        lastCopies_ = 0;
    }
    uint32_t heldCount() const noexcept override { return table_.used; }

    void note(const Event& e, const NoteMessage& m) noexcept override {
        const int64_t t = now() + m.frame;
        Rec* r = table_.find(m.noteId);
        if (m.type == NoteMessageType::On) {
            if (r) release(*r, m.frame, t), table_.remove(r);
            const bool dry = on(eDry, m.frame);
            if (dry) emit(m.frame, e);
            r = table_.add(m.noteId);
            if (!r) return;
            const int sync = std::clamp(choice(eSync, m.frame), 0, fx::kSyncCount - 1);
            const double secs = sync == 0 ? param(eTime, m.frame) / 1000.0 : fx::kSyncWholeNotes[sync] * 240.0 / tempo();
            r->gap = std::max<int64_t>(1, static_cast<int64_t>(std::floor(secs * rate() + 0.5)));
            r->dry = dry;
            r->channel = m.channel;
            const int repeats = std::clamp(static_cast<int>(param(eRepeats, m.frame) + 0.5), 1, 16);
            const double decay = param(eDecay, m.frame);
            const double shift = std::lround(param(ePitch, m.frame));
            double vel = m.velocity;
            r->n = 0;
            for (int k = 1; k <= repeats; ++k) {
                vel *= decay;
                if (vel < 0.02) break;
                const double pitch = m.pitch + shift * k;
                r->ids[r->n] = 0;
                r->keys[r->n] = notes::keyOf(pitch);
                if (pitch >= 0.0 && pitch <= 127.0) {
                    const uint32_t id = newId();
                    if (schedule(t + k * r->gap, notes::noteOn(0, id, pitch, vel, m.channel))) r->ids[r->n] = id;
                }
                ++r->n;
            }
            lastCopies_ = r->n;
            return;
        }
        if (!r) return emit(m.frame, e);
        if (m.type == NoteMessageType::Off) {
            if (r->dry) emit(m.frame, e);
            release(*r, m.frame, t);
            table_.remove(r);
            return;
        }
        if (r->dry) emit(m.frame, e);  // the repeats replay the note, not its motion
    }
    void release(Rec& r, uint32_t frame, int64_t t) noexcept {
        for (int k = 0; k < r.n; ++k) {
            if (!r.ids[k]) continue;
            if (schedule(t + (k + 1) * r.gap, notes::noteOff(0, r.ids[k], r.keys[k], 0.0, r.channel))) continue;
            if (!cancel(r.ids[k])) emit(frame, notes::noteOff(frame, r.ids[k], r.keys[k], 0.0, r.channel));
        }
    }
    uint32_t fillDisplay(float* out) noexcept override {
        const int sync = std::clamp(choice(eSync, 0), 0, fx::kSyncCount - 1);
        const double secs = sync == 0 ? param(eTime, 0) / 1000.0 : fx::kSyncWholeNotes[sync] * 240.0 / tempo();
        out[0] = static_cast<float>(lastCopies_);
        out[1] = static_cast<float>(secs * 1000.0);
        out[2] = static_cast<float>(queuedCount());
        return 3;
    }

private:
    Table<Rec, 128> table_;
    int lastCopies_ = 0;
};

// ---------------------------------------------------------------------------------------------------------------
// Humanize: each note a little late (0..timing ms) and its velocity a little off (+-velocity), from a hash of the
// seed, the note's key and where it falls in the song: the same notes get the same feel from every Play (a running
// count while stopped). Late only: a real-time effect cannot play a note early. The rest of the note moves with it.

enum HumanParam : uint32_t { hTiming, hVelocity, hSeed, hCount };

const fx::ParamTable& humanParams() {
    static const fx::ParamTable t = [] {
        fx::ParamTable p;
        flat(p.num("timing", "Timing", 10, 0, 50, "ms"));
        flat(p.num("velocity", "Velocity", 0.1, 0, 0.5));
        whole(p.num("seed", "Seed", 1, 0, 9999));
        return p;
    }();
    return t;
}
const ModuleDescriptor& humanDescriptor() {
    static const ModuleDescriptor d = midiDescriptor("org.caw.midi.humanize", "Humanize", humanParams());
    return d;
}

class Humanize final : public MidiEffect {
public:
    Humanize() noexcept : MidiEffect(humanDescriptor(), 1024) {}

protected:
    struct Rec {
        uint32_t id = 0;
        int64_t delay = 0;
    };
    void clearState() noexcept override {
        table_.used = 0;
        count_ = 0;
        lastDelay_ = lastVel_ = 0;
    }
    uint32_t heldCount() const noexcept override { return table_.used; }

    void note(const Event& e, const NoteMessage& m) noexcept override {
        const int64_t t = now() + m.frame;
        Rec* r = table_.find(m.noteId);
        if (m.type == NoteMessageType::On) {
            r = r ? r : table_.add(m.noteId);
            const uint64_t where = playing() ? static_cast<uint64_t>(songSample(m.frame)) : (1ull << 62) + count_++;
            const uint32_t seed = static_cast<uint32_t>(param(hSeed, m.frame));
            const double u1 = unit(seed, where, m.key, 1), u2 = unit(seed, where, m.key, 2);
            int64_t delay = static_cast<int64_t>(std::floor(param(hTiming, m.frame) * rate() / 1000.0 * u1 + 0.5));
            const double change = param(hVelocity, m.frame) * (2.0 * u2 - 1.0);
            const Event x = noteOnWithVelocity(e, std::clamp(m.velocity + change, 0.01, 1.0));
            if (!r || !schedule(t + delay, x)) {
                emit(m.frame, x);
                delay = 0;
            }
            if (r) r->delay = delay;
            lastDelay_ = static_cast<double>(delay) * 1000.0 / rate();
            lastVel_ = change;
            return;
        }
        if (!r) return emit(m.frame, e);
        const int64_t delay = r->delay;
        if (m.type == NoteMessageType::Off) table_.remove(r);
        if (!schedule(t + delay, e) && m.type == NoteMessageType::Off) emit(m.frame, e);
    }
    uint32_t fillDisplay(float* out) noexcept override {
        out[0] = static_cast<float>(lastDelay_);
        out[1] = static_cast<float>(lastVel_);
        out[2] = static_cast<float>(param(hTiming, 0));
        out[3] = static_cast<float>(param(hVelocity, 0));
        return 4;
    }

private:
    Table<Rec, 256> table_;
    uint64_t count_ = 0;
    double lastDelay_ = 0, lastVel_ = 0;
};

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

}  // namespace

void registerMidiEffects(ModuleRegistry& registry) {
    registry.add(arpDescriptor(), &make<Arp>);
    registry.add(chordDescriptor(), &make<Chords>);
    registry.add(scaleDescriptor(), &make<ScaleFx>);
    registry.add(echoDescriptor(), &make<Echo>);
    registry.add(humanDescriptor(), &make<Humanize>);
}

const std::vector<BuiltinPreset>* presets(std::string_view id) {
    // Job-named; the description starts with its purpose (Sound design, Mixing...).
    static const std::vector<BuiltinPreset> arp = {
        {"Classic up 16ths", "Sound design: the held chord climbing in 16th notes", {{"rate", 2}, {"pattern", 0}, {"gate", 0.5}}},
        {"Trance gate 16ths", "Sound design: short up-down 16ths over two octaves", {{"rate", 2}, {"pattern", 2}, {"octaves", 2}, {"gate", 0.3}}},
        {"Swung 8ths", "Sound design: lazy 8ths with a shuffle", {{"rate", 5}, {"pattern", 0}, {"swing", 0.25}, {"gate", 0.6}}},
        {"Down triplets", "Sound design: falling 8th-note triplets", {{"rate", 4}, {"pattern", 1}, {"gate", 0.5}}},
        {"Random sparkle", "Sound design: random keys over three octaves, fixed velocity", {{"rate", 2}, {"pattern", 5}, {"octaves", 3}, {"gate", 0.25}, {"vel_mode", 1}, {"velocity", 0.7}}},
        {"Chord stabs", "Sound design: the whole chord on each 8th, short", {{"rate", 5}, {"pattern", 6}, {"gate", 0.2}}},
        {"Held pad pulse", "Sound design: latched keys pulsing in quarters, legato", {{"rate", 8}, {"pattern", 4}, {"hold", 1}, {"gate", 1.0}}},
        {"32nd shimmer", "Sound design: fast up-and-down 32nds over four octaves", {{"rate", 0}, {"pattern", 3}, {"octaves", 4}, {"gate", 0.4}}},
        {"Bass octave 8ths", "Bass: the note and its octave in 8ths", {{"rate", 5}, {"pattern", 0}, {"octaves", 2}, {"gate", 0.7}}},
    };
    static const std::vector<BuiltinPreset> chords = {
        {"Major key triads", "Sound design: one finger plays the key's triads (C major)", {{"root", 0}, {"scale", 0}, {"type", 0}}},
        {"Minor key triads", "Sound design: triads in A minor", {{"root", 9}, {"scale", 1}, {"type", 0}}},
        {"Lush sevenths", "Sound design: open seventh chords in the key", {{"type", 1}, {"voicing", 1}}},
        {"Neo-soul ninths", "Sound design: wide ninth chords, softer added notes", {{"type", 2}, {"voicing", 2}, {"added", 0.7}}},
        {"Guitar strum", "Guitar: a quick upward strum of open triads", {{"type", 0}, {"voicing", 1}, {"strum", 25}}},
        {"Power chords", "Guitar: root, fifth and octave", {{"type", 6}}},
        {"Octave stack", "Bass: the note in three octaves", {{"type", 7}, {"added", 0.6}}},
        {"Suspended pads", "Sound design: sus2 chords, first inversion", {{"type", 3}, {"inversion", 1}}},
        {"Dorian groove", "Sound design: sixth chords in D dorian", {{"root", 2}, {"scale", 2}, {"type", 5}}},
    };
    static const std::vector<BuiltinPreset> scale = {
        {"C major snap", "Sound design: every note into C major, nearest", {{"root", 0}, {"scale", 0}, {"mode", 0}}},
        {"A minor snap", "Sound design: every note into A minor", {{"root", 9}, {"scale", 1}, {"mode", 0}}},
        {"Pentatonic safe", "Sound design: only the major pentatonic's notes, nearest", {{"scale", 9}, {"mode", 0}}},
        {"Minor pentatonic filter", "Guitar: notes outside A minor pentatonic are left out", {{"root", 9}, {"scale", 10}, {"mode", 3}}},
        {"Blues snap down", "Guitar: notes fall to the blues scale below", {{"root", 4}, {"scale", 11}, {"mode", 1}}},
        {"Harmony a third up", "Vocals: the line moved two scale degrees up, in key", {{"transpose", 2}}},
        {"Diatonic fifth below", "Bass: the line four degrees down, in key", {{"transpose", -4}}},
        {"Dorian lock", "Sound design: D dorian, snapped up", {{"root", 2}, {"scale", 2}, {"mode", 2}}},
        {"Whole-tone dream", "Sound design: everything on a whole-tone scale", {{"scale", 13}}},
    };
    static const std::vector<BuiltinPreset> echo = {
        {"Dotted 8th echoes", "Sound design: three dotted-8th repeats fading out", {{"sync", 7}, {"repeats", 3}, {"decay", 0.6}}},
        {"Quarter repeats", "Sound design: four quarter-note repeats", {{"sync", 9}, {"repeats", 4}, {"decay", 0.7}}},
        {"Rising octaves", "Sound design: each 8th repeat an octave higher", {{"sync", 6}, {"repeats", 3}, {"pitch", 12}, {"decay", 0.7}}},
        {"Falling fifths", "Sound design: each repeat a fifth lower", {{"sync", 6}, {"repeats", 4}, {"pitch", -7}, {"decay", 0.75}}},
        {"Triplet ripple", "Drums: fast 16th-triplet ghost repeats", {{"sync", 2}, {"repeats", 5}, {"decay", 0.5}}},
        {"Free slapback", "Vocals: one short free-time repeat", {{"sync", 0}, {"time", 110}, {"repeats", 1}, {"decay", 0.5}}},
        {"Long tail", "Sound design: twelve slow repeats dying away", {{"sync", 9}, {"repeats", 12}, {"decay", 0.82}}},
        {"Wet only", "Sound design: the repeats without the played note", {{"sync", 6}, {"repeats", 3}, {"dry", 0}}},
        {"Roll", "Drums: 32nd-note repeats, a roll from one hit", {{"sync", 1}, {"repeats", 7}, {"decay", 0.85}}},
    };
    static const std::vector<BuiltinPreset> human = {
        {"Subtle feel", "Mixing: a few milliseconds and a touch of velocity", {{"timing", 6}, {"velocity", 0.06}}},
        {"Loose player", "Mixing: a looser hand", {{"timing", 18}, {"velocity", 0.15}}},
        {"Drunk drummer", "Drums: very loose timing and dynamics", {{"timing", 40}, {"velocity", 0.3}}},
        {"Velocity only", "Drums: dynamics vary, timing stays tight", {{"timing", 0}, {"velocity", 0.2}}},
        {"Timing only", "Mixing: timing drifts, dynamics stay", {{"timing", 12}, {"velocity", 0}}},
        {"Hi-hat life", "Drums: small velocity changes for programmed hats", {{"timing", 3}, {"velocity", 0.25}}},
        {"Strummed keys", "Sound design: chords spread a little, as played by hand", {{"timing", 25}, {"velocity", 0.08}}},
        {"Bass pocket", "Bass: slightly behind the beat", {{"timing", 10}, {"velocity", 0.05}}},
        {"Another take", "Mixing: the same feel with another seed", {{"timing", 10}, {"velocity", 0.1}, {"seed", 2}}},
    };
    if (id == "org.caw.midi.arp") return &arp;
    if (id == "org.caw.midi.chords") return &chords;
    if (id == "org.caw.midi.scale") return &scale;
    if (id == "org.caw.midi.echo") return &echo;
    if (id == "org.caw.midi.humanize") return &human;
    return nullptr;
}

}  // namespace caw::midifx
