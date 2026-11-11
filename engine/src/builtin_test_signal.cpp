// The internal test signal (org.caw.test.osc): sine, saw, square, seeded noise, DC, impulse and sweep, free-running or played by notes.
#include "builtin_test_signal.h"

#include <cmath>

#include "caw/detmath.hpp"
#include "caw/instrument.hpp"

namespace caw {

namespace {

enum Param : uint32_t { kShape, kMode, kFreq, kNote, kLevel, kLeft, kRight, kPhase, kSeed, kSweepTo, kSweepTime, kPeriod, kParamCount };

constexpr std::string_view kShapeNames[] = {"Sine", "Saw", "Square", "Noise", "DC", "Impulse", "Sweep"};
constexpr std::string_view kModeNames[] = {"Free", "Notes"};

ParameterDescriptor param(std::string_view id, double def, double lo, double hi, double step = 0.0) {
    ParameterDescriptor p;
    p.id = id;
    p.defaultValue = def;
    p.minimum = lo;
    p.maximum = hi;
    p.step = step;
    p.smoothingFrames = 0;  // a test sets a value and gets exactly it from the next block
    return p;
}

ParameterDescriptor choice(std::string_view id, const std::string_view* names, uint32_t count) {
    ParameterDescriptor p = param(id, 0.0, 0.0, count - 1.0, 1.0);
    p.choices = names;
    p.choiceCount = count;
    return p;
}

const ParameterDescriptor kParams[kParamCount] = {
    choice("shape", kShapeNames, 7),
    choice("mode", kModeNames, 2),
    param("freq", 440.0, 0.0, 100000.0),      // Hz (Free mode, unless `note` is set)
    param("note", -1.0, -1.0, 127.0),         // >= 0: the Free-mode pitch as a MIDI note (69 = 440 Hz)
    param("level", 1.0, -1000.0, 1000.0),     // amplitude; DC outputs it
    param("left", 1.0, -1000.0, 1000.0),      // gain on the left channel
    param("right", 1.0, -1000.0, 1000.0),     // gain on the right channel
    param("phase", 0.0, 0.0, 1.0),            // start phase in cycles
    param("seed", 1.0, 0.0, 2147483647.0, 1.0),
    param("sweep_to", 20000.0, 0.01, 100000.0),  // Hz the sweep ends at
    param("sweep_time", 1.0, 0.001, 600.0),      // seconds the sweep takes, then it holds sweep_to
    param("period", 0.0, 0.0, 600.0),            // impulse: seconds between impulses (0: one at the start)
};

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

const ModuleDescriptor& testSignalDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor m;
        m.id = kTestSignalId;
        m.name = "Test signal";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        m.parameters = kParams;
        m.parameterCount = kParamCount;
        m.domains = kDomainWhole | kDomainPerNote;  // Notes mode renders into a voice bus (VoiceLanes)
        m.capabilities = kCapabilityNotesIn;
        m.cpuClass = CpuClass::Light;
        return m;
    }();
    return d;
}

double midiHz(double pitch) noexcept { return 440.0 * detExp((pitch - 69.0) * (detail::kLn2 / 12.0)); }

// One sounding signal: the Free mode's one, or one per held note.
struct Voice {
    bool active = false, held = false;
    uint32_t noteId = 0;
    uint64_t age = 0;
    double pitch = 60, velocity = 1;
    double phase = 0;     // cycles, 0..1
    uint64_t elapsed = 0; // frames since it started
    uint32_t rng = 1;

    void start(double startPhase, uint32_t seed) noexcept {
        phase = startPhase;
        elapsed = 0;
        rng = hash32(seed) | 1u;
    }
};

class TestSignal final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return testSignalDescriptor(); }
    bool activate(double sampleRate, uint32_t) noexcept override {
        sr_ = sampleRate > 0 ? sampleRate : 48000.0;
        reset();
        return true;
    }
    void reset() noexcept override {
        voices_.clear();
        free_ = Voice{};
        freeStarted_ = false;
    }
    bool quiet() const noexcept override { return notes_ && live_ == 0 && !lanes_.any(); }

protected:
    void beginBlock(const ProcessBlock& b) noexcept override {
        const bool notes = parameterAt(b, kMode, 0, 0.0) >= 0.5;
        if (notes != notes_) reset();
        notes_ = notes;
        startPhase_ = parameterAt(b, kPhase, 0, 0.0);
        seed_ = static_cast<uint32_t>(parameterAt(b, kSeed, 0, 1.0));
        lanes_.bind(b);
        if (!notes_ && !freeStarted_) {
            free_.start(startPhase_, seed_);
            freeStarted_ = true;
        }
    }
    void onNote(const NoteMessage& m) noexcept override {
        if (!notes_) return;
        if (m.type == NoteMessageType::On) {
            Voice& v = voices_.start(m.noteId, &lanes_);
            v.pitch = m.pitch;
            v.velocity = m.velocity;
            v.start(startPhase_, seed_ + m.noteId);
        } else if (Voice* v = voices_.find(m.noteId)) {
            if (m.type == NoteMessageType::Off) v->active = false;  // no release: the note ends on its frame
            else if (m.type == NoteMessageType::Pitch) v->pitch = m.pitch;
        }
    }
    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        const int shape = static_cast<int>(parameterAt(b, kShape, offset, 0.0) + 0.5);
        const double gl = parameterAt(b, kLeft, offset, 1.0), gr = parameterAt(b, kRight, offset, 1.0);
        const double sweepTo = parameterAt(b, kSweepTo, offset, 20000.0);
        const double sweepFrames = parameterAt(b, kSweepTime, offset, 1.0) * sr_;
        const uint64_t period = static_cast<uint64_t>(std::floor(parameterAt(b, kPeriod, offset, 0.0) * sr_ + 0.5));
        for (uint32_t i = 0; i < frames; ++i) left[i] = right[i] = 0.0f;
        if (lanes_.any()) lanes_.begin(offset, frames);
        auto play = [&](Voice& v, bool fromNote, float* outL, float* outR) noexcept {
            for (uint32_t i = 0; i < frames; ++i) {
                const double level = parameterAt(b, kLevel, offset + i, 1.0) * (fromNote ? v.velocity : 1.0);
                double hz;
                if (fromNote) {
                    hz = midiHz(v.pitch);
                } else {
                    const double note = parameterAt(b, kNote, offset + i, -1.0);
                    hz = note >= 0 ? midiHz(note) : parameterAt(b, kFreq, offset + i, 440.0);
                }
                double y = 0;
                switch (shape) {
                    case 0: y = detSin(kTwoPi * v.phase); break;
                    case 1: y = 2.0 * v.phase - 1.0; break;
                    case 2: y = v.phase < 0.5 ? 1.0 : -1.0; break;
                    case 3:
                        v.rng ^= v.rng << 13;
                        v.rng ^= v.rng >> 17;
                        v.rng ^= v.rng << 5;
                        y = v.rng / 2147483648.0 - 1.0;
                        break;
                    case 4: y = 1.0; break;
                    case 5: y = v.elapsed == 0 || (period > 0 && v.elapsed % period == 0) ? 1.0 : 0.0; break;
                    default: {
                        const double from = hz > 0.01 ? hz : 0.01;
                        const double u = sweepFrames > 0 ? std::fmin(1.0, v.elapsed / sweepFrames) : 1.0;
                        hz = from * detExp(u * detLog(sweepTo / from));
                        y = detSin(kTwoPi * v.phase);
                    }
                }
                const double out = y * level;
                outL[i] += static_cast<float>(out * gl);
                outR[i] += static_cast<float>(out * gr);
                v.phase += hz / sr_;
                v.phase -= std::floor(v.phase);
                ++v.elapsed;
            }
        };
        if (!notes_) {
            play(free_, false, left, right);
            live_ = 1;
        } else {
            // The voice bus (#127): a note with a lane plays there; the lanes join the mix after the host's FX.
            voices_.forEachActive([&](Voice& v) {
                if (VoiceLane* lane = lanes_.laneFor(v.noteId)) play(v, true, lane->channels[0] + offset, lane->channels[1] + offset);
                else play(v, true, left, right);
            });
            live_ = voices_.activeCount();
        }
        if (lanes_.any()) lanes_.runAndSum(left, right, offset, frames);
    }
    void endBlock(const ProcessBlock&) noexcept override {
        if (lanes_.any()) lanes_.endBlock([&](uint32_t id) noexcept { return notes_ && voices_.find(id) != nullptr; });
    }

private:
    double sr_ = 48000.0;
    bool notes_ = false, freeStarted_ = false;
    double startPhase_ = 0;
    uint32_t seed_ = 1;
    uint32_t live_ = 0;
    Voice free_;
    VoicePool<Voice, 64> voices_;
    VoiceLanes lanes_;  // the host's voice bus for this block (#127), or none
};

ModuleProcessor* makeTestSignal() noexcept { return new (std::nothrow) TestSignal(); }

}  // namespace

void registerTestSignal(ModuleRegistry& registry) { registry.addInternal(testSignalDescriptor(), &makeTestSignal); }

}  // namespace caw
