// The flagship synth (#171): three wavetable oscillators with unison, two filters, a mod matrix and an effects rack.
#include "builtin_flagship.h"
#include "params.h"
#include "quality.h"
#include "simd4.h"
#include "stereo_pair.h"

#include <algorithm>
#include <bit>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "component_samples.h"
#include "caw/detmath.hpp"
#include "caw/instrument.hpp"
#include "caw/library/comb.hpp"
#include "caw/library/convolver.hpp"
#include "caw/library/delay.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/formant.hpp"
#include "caw/library/lfo.hpp"
#include "caw/library/oscillator.hpp"
#include "caw/library/oversample.hpp"
#include "caw/library/reverb.hpp"
#include "caw/library/stereo.hpp"
#include "caw/library/unison.hpp"
#include "caw/library/wavetable.hpp"
#include "flagship_banks.h"
#include "flagship_filters.h"

// Original code (C.A.W. is Apache-2.0). The controls follow what a modern wavetable synth offers, reproduced from
// general synthesis knowledge and public descriptions of what such controls do; no other synth's code, presets
// or wavetables were used (docs/decisions.md, "A flagship synth that can do everything").
//
// How it runs (the costs the phone budget cares about):
// - Everything that is not audio runs once per control period of 16 frames (0.33 ms at 48 kHz): the knobs,
//   the mod matrix, each voice's oscillator steps, mip levels, unison gains and filter coefficients. The grid
//   runs on from block to block and restarts on a note-on, so any block size renders the same sound: the same
//   bits on the builds checked (with -ffp-contract=fast a whole period's fixed-length loops and a shorter
//   piece's may be fused differently, about 1 ulp; perceptual identity is the rule, docs/decisions.md).
// - An oscillator copy (one unison voice) costs one interpolated read of a band-limited mip level per sample
//   (two when the frame position sits between frames), plus its warp: no trig, no branches on data.
// - Only sounding voices are visited (caw::VoicePool), only oscillators that are on, only filters and effects
//   that are on. With no voice and the effects' tails below -94 dB the synth clears its effects and is quiet()
//   (the host skips it) until the next note.

#if defined(_MSC_VER) && !defined(__clang__)
#define CAW_FORCE_INLINE __forceinline
#define CAW_NO_INLINE __declspec(noinline)
#else
#define CAW_FORCE_INLINE inline __attribute__((always_inline))
#define CAW_NO_INLINE __attribute__((noinline))
#endif
// A loop the compiler keeps as a loop (vectorized, not unrolled further): a long body unrolled four times over
// spills registers on x86-64's 16.
#if defined(__clang__)
#define CAW_NO_UNROLL _Pragma("clang loop unroll(disable)")
#elif defined(__GNUC__)
#define CAW_NO_UNROLL _Pragma("GCC unroll 1")
#else
#define CAW_NO_UNROLL
#endif

namespace caw {

namespace {

#include "flagship/params.inc"

#include "flagship/wavetables.inc"

#include "flagship/osc_stack.inc"

#include "flagship/osc_modes.inc"

#include "flagship/voice_filter.inc"

// ---------- The instrument ----------

struct Voice {
    bool active = false, held = false;
    uint32_t noteId = 0;
    uint64_t age = 0;
    bool starting = false, fresh = false;  // the next control sets the note's start (and, fresh, its phases)
    // Eco's FM warp at the sample rate (OscKey::once), latched when the voice starts from silence: a
    // quality change while a note sounds never switches its oscillators between the 1x and the decimated path.
    bool ecoWarps = false;
    // Each oscillator's fold at twice the rate (OscKey::foldTwice), chosen when the voice starts from silence
    // (foldTwiceFor): a bend, a glide or a knob while the note sounds never switches it between the two paths.
    bool foldTwice[kOscs] = {};
    uint32_t seed = 0;
    double tailGain = 0.0;  // the releasing voice's loudest output per unit of envelope (render.inc, endTail)
    double notePitch = 60.0, pitch = 60.0, velocity = 1.0, pressure = 0.0, timbre = 0.0;
    lib::Adsr env[kEnvs];
    lib::Lfo lfo[kLfos];  // the retriggered LFOs (a free one is the instrument's)
    lib::Lfo random;
    OscVoice osc[kOscs];
    // Each oscillator's latest mono output (before its level) at each frame of the control period, for the one
    // Osc FM modulates from it. Oscillators render in order, so 2 and 3 hear 1 and 2 in the same frames and 1
    // hears 3 one period (16 frames) late: the same for any block size.
    float fmBuf[kOscs + 1][kControlFrames] = {};  // then the voice's noise (kNoiseRow), drawn at each control
    uint32_t noise = 1;                            // its generator's state
    VoiceFilter filter[kFilters];
    bool parallel = false;
    double gain0 = 0.0, gain1 = 0.0;  // the level ramps from gain0 to gain1 over the control period
    bool mono = false;  // the mono or legato voice: its pitch follows `glide` at each control
    double configuredPitch = -1.0;  // the pitch its oscillators and filters were last worked out for
    double moving[kSlots] = {};     // the values the slots moved, as its sections were last worked out
    bool shared = false;            // its level goes into the instrument's shared filter 1 (see startVoice)
    lib::Glide glide;   // in semitones, stepped once per control period
};

// The notes held in mono and legato, newest last (last-note priority: ending the newest returns to the one held
// before it). Holds 16; a 17th forgets the oldest.
class HeldNotes {
public:
    struct Held {
        uint32_t id = 0;
        double pitch = 60.0;
    };
    void push(uint32_t id, double pitch) noexcept {
        remove(id);
        if (count_ == kSize) {
            std::copy(notes_ + 1, notes_ + kSize, notes_);
            --count_;
        }
        notes_[count_++] = {id, pitch};
    }
    bool remove(uint32_t id) noexcept {
        for (uint32_t i = 0; i < count_; ++i)
            if (notes_[i].id == id) {
                std::copy(notes_ + i + 1, notes_ + count_, notes_ + i);
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

class FlagshipInstrument final : public InstrumentProcessor {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return flagshipDescriptor(); }

    bool activate(double sampleRate, uint32_t maxBlock) noexcept override {
        try {
            sr_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
            quality_ = buildingQuality();
            const Tables& built = tables();
            for (int t = 0; t < kTableCount; ++t) table_[t] = &built.table[t];
            table_[kAdditiveTable] = &built.additive;
            table_[kUserTable] = user_ ? &user_->table : &emptyUserTable();
            for (int t = 0; t < kTableChoices; ++t)
                if (t != kUserTable) source_[t] = flagship::builtinSource(t, table_[t]);
            source_[kUserTable] = user_ ? flagship::registerSource(std::shared_ptr<const lib::Wavetable>(user_, &user_->table))
                                        : flagship::builtinSource(kUserTable, &emptyUserTable());
            banks_.setOffline(buildingOffline());
            flagship::startBankWorker();
            for (auto& pair : combs_)
                for (lib::CombFilter& c : pair) c.prepare(sr_, 20.0);
            chorus_.prepare(sr_);
            delay_.prepare(sr_, 4.0);  // a bar at 60 bpm
            reverb_.prepare(sr_, static_cast<int>(maxBlock), 0.1);
        } catch (...) {
            return false;
        }
        const Params& p = params();
        for (uint32_t k = 0; k < kParamCount; ++k) base_[k] = p.d[k].defaultValue;
        lastGiven_ = ~0u;  // the next block reads every value
        reset();
        return true;
    }

    // The user wavetable. Control thread, when the chain is built and before it plays (a state change rebuilds
    // the chain: caw_engine_set_component_state), so the voices never read a table that goes away.
    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        written = 0;
        if (!user_) return true;
        const size_t need = user_->canonical.size();
        if (!dst || need > capacity) return false;
        std::memcpy(dst, user_->canonical.data(), need);
        written = static_cast<uint32_t>(need);
        return true;
    }
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        if (version != 1 || size > kMaxWtStateBytes) return false;
        try {
            std::shared_ptr<const UserTable> next;
            if (size > 0) {
                std::vector<uint8_t> canonical;
                if (!canonicalUserTable(src, size, canonical)) return false;
                next = userTableFor(std::move(canonical));
            }
            reset();  // no voice holds the old table's frames
            banks_.releaseAll();  // nor its banks
            user_ = std::move(next);
            table_[kUserTable] = user_ ? &user_->table : &emptyUserTable();
            source_[kUserTable] = user_ ? flagship::registerSource(std::shared_ptr<const lib::Wavetable>(user_, &user_->table))
                                        : flagship::builtinSource(kUserTable, &emptyUserTable());
            return true;
        } catch (...) {
            return false;
        }
    }

    void reset() noexcept override {
        voices_.clear();
        held_.clear();
        shared_.clear();
        sharedQuiet_ = true;
        sharedRan_ = false;
        sharedPeak_ = 0.0f;
        knobsChanged_ = true;
        for (lib::Lfo& l : lfo_) {
            l = lib::Lfo{};
            l.prepare(sr_);
        }
        clearEffects();
        distOn_ = eqOn_ = chorusOn_ = delayOn_ = reverbOn_ = false;
        clock_.restart();
        sinceControl_ = 0;
        started_ = 0;
        modWheel_ = 0.0;
        idle_ = true;
        quietRun_ = 0;
        periodPeak_ = 0.0f;
        tailDebt_ = tailCoef_ = 0.0;
        tailRaise_ = 1.0;
        volume0_ = volume1_ = 0.0;
        delayTime0_ = delayTime1_ = 0.0;
    }

    // No voice and the effects cleared: silence until the next note (whose note-on restarts the control grid;
    // the free LFOs and every other clock stood still while idle, so a skipped stretch changes nothing).
    bool quiet() const noexcept override { return idle_ && !lanes_.any(); }

protected:
    void onNote(const NoteMessage& m) noexcept override {
        switch (m.type) {
            case NoteMessageType::On: {
                settle();  // the sounding voices move on to this frame first
                if (voiceMode(m.frame) != kPoly) {
                    monoOn(m);
                    break;
                }
                Voice& v = voices_.start(m.noteId, &lanes_);
                v.fresh = !v.env[0].active();  // a stolen voice continues from where it is (no click)
                if (v.fresh) v.ecoWarps = qualityNow(quality_) == kQualityEco;
                v.starting = true;
                v.mono = false;
                v.seed = hash32(++started_ * 0x9E3779B9U);
                v.notePitch = v.pitch = m.pitch;
                v.velocity = m.velocity;
                v.pressure = v.timbre = 0.0;
                for (lib::Adsr& e : v.env) e.gateOn();
                idle_ = false;
                clock_.restart();  // the voice's settings from this frame
                break;
            }
            case NoteMessageType::Off:
                if (held_.find(m.noteId)) {
                    settle();
                    monoOff(m);
                    break;
                }
                if (Voice* v = voices_.find(m.noteId); v && v->held) {
                    settle();  // the modulation envelopes release from this frame
                    v->held = false;
                    for (lib::Adsr& e : v->env) e.gateOff();
                    v->tailGain = 0.0;
                }
                break;
            case NoteMessageType::Pitch:
                if (HeldNotes::Held* h = held_.find(m.noteId)) {  // mono: a held note's slide or bend
                    h->pitch = m.pitch;
                    if (Voice* v = voices_.find(m.noteId); v && v->mono)  // the note sounding: followed within ~3 ms
                        v->glide.glideTo(m.pitch, 0.003, sr_ / kControlFrames);
                } else if (Voice* v = voices_.find(m.noteId)) {
                    v->pitch = m.pitch;
                }
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

    // Mono and legato: one voice. A note while it sounds moves it there (gliding), restarting its envelopes
    // unless legato and another note is held; a note while it is silent starts it afresh.
    void monoOn(const NoteMessage& m) noexcept {
        const bool overlap = !held_.empty();
        const bool legato = voiceMode(m.frame) == kLegato;
        held_.push(m.noteId, m.pitch);
        Voice* sounding = nullptr;
        voices_.forEachActive([&](Voice& v) noexcept {
            if (v.env[0].active() && (!sounding || v.age > sounding->age)) sounding = &v;
        });
        clock_.restart();
        idle_ = false;
        if (sounding && sounding->mono) {
            Voice& v = *sounding;
            v.noteId = m.noteId;
            v.held = true;
            v.notePitch = m.pitch;
            v.glide.glideTo(m.pitch, glideAt(m.frame), sr_ / kControlFrames);
            if (overlap && legato) return;  // a slide: the envelopes run on
            v.velocity = m.velocity;
            v.starting = true;  // the LFOs and the random source restart; the phases run on (no click)
            v.fresh = false;
            for (lib::Adsr& e : v.env) e.gateOn();
            return;
        }
        Voice& v = voices_.start(m.noteId, &lanes_);
        v.fresh = !v.env[0].active();
        if (v.fresh) v.ecoWarps = qualityNow(quality_) == kQualityEco;
        v.starting = true;
        v.mono = true;
        v.seed = hash32(++started_ * 0x9E3779B9U);
        v.notePitch = v.pitch = m.pitch;
        v.glide.jump(m.pitch);
        v.velocity = m.velocity;
        v.pressure = v.timbre = 0.0;
        for (lib::Adsr& e : v.env) e.gateOn();
    }
    // A knob at a note's frame: its value in this block (or where it is ramping, there).
    double knobAt(uint32_t k, uint32_t frame) const noexcept {
        if (block_ && k < block_->parameterCount && block_->parameters && block_->parameters[k].samples)
            return block_->parameters[k].samples[frame];
        return base_[k];
    }
    int voiceMode(uint32_t frame) const noexcept { return clampi(knobAt(kVoiceMode, frame), 0, 2); }
    double glideAt(uint32_t frame) const noexcept { return clampd(knobAt(kGlide, frame), 0.001, 2.0); }

    void monoOff(const NoteMessage& m) noexcept {
        const HeldNotes::Held* top = held_.top();
        const bool wasTop = top && top->id == m.noteId;
        held_.remove(m.noteId);
        Voice* v = wasTop ? voices_.find(m.noteId) : nullptr;
        if (!v || !v->mono) return;
        if (held_.empty()) {
            v->held = false;
            for (lib::Adsr& e : v->env) e.gateOff();
            v->tailGain = 0.0;
            return;
        }
        const HeldNotes::Held& back = *held_.top();  // back to the note held before, gliding, envelopes running on
        v->noteId = back.id;
        v->glide.glideTo(back.pitch, glideAt(m.frame), sr_ / kControlFrames);
        clock_.restart();
    }

    // The mod wheel (controller 1), from a MIDI 1.0 or MIDI 2.0 channel voice message, when the host sends one.
    void onEvent(const Event& e) noexcept override {
        const uint32_t w0 = e.data[0], type = w0 >> 28, status = (w0 >> 20) & 0xF, index = (w0 >> 8) & 0x7F;
        if (status != 0xB || index != 1) return;
        if (type == 0x2) modWheel_ = static_cast<double>(w0 & 0x7F) / 127.0;
        else if (type == 0x4) modWheel_ = static_cast<double>(e.data[1]) / 4294967295.0;
    }

    // The knobs that hold still over this block are read once here, before its notes (whose voice mode and glide
    // they set); the ramping ones at each control.
    void beginBlock(const ProcessBlock& b) noexcept override {
        transport_ = b.transport;
        block_ = &b;
        lanes_.bind(b);
        const Params& p = params();
        const uint32_t given = b.parameters ? std::min(b.parameterCount, kParamCount) : 0;
        // The same values as last block, none ramping (a steady chain hands over the same array): nothing to read.
        // A ramp's samples pointer can stay while its values move, so a block after one with ramps reads them all.
        if (given == lastGiven_ && rampCount_ == 0 && given > 0 &&
            std::memcmp(b.parameters, lastValues_, given * sizeof(ParameterValue)) == 0)
            return;
        lastGiven_ = given;
        if (given > 0) std::memcpy(lastValues_, b.parameters, given * sizeof(ParameterValue));
        rampCount_ = 0;
        bool changed = false;
        for (uint32_t k = 0; k < given; ++k) {  // the host's values (the usual case: every one, none ramping)
            const ParameterValue& pv = b.parameters[k];
            if (pv.samples) {
                ramp_[rampCount_++] = static_cast<uint16_t>(k);
                continue;
            }
            changed |= pv.value != base_[k];
            base_[k] = pv.value;
        }
        for (uint32_t k = given; k < kParamCount; ++k) {
            changed |= p.d[k].defaultValue != base_[k];
            base_[k] = p.d[k].defaultValue;
        }
        knobsChanged_ = knobsChanged_ || changed;  // until the next control has used them
    }

    // The voice bus (#127): a note whose lane ends at the block's end has no voice left playing it.
    void endBlock(const ProcessBlock&) noexcept override {
        if (lanes_.any()) lanes_.endBlock([&](uint32_t id) noexcept { return voices_.find(id) != nullptr; });
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        if (idle_) {
            std::memset(left, 0, frames * sizeof(float));
            std::memset(right, 0, frames * sizeof(float));
            if (lanes_.any()) {  // a lane before its note starts: the host's FX still run (on silence)
                lanes_.begin(offset, frames);
                lanes_.runAndSum(left, right, offset, frames);
            }
            return;
        }
        clock_.run(frames, offset,
                   [&](uint32_t at) noexcept {
                       settle();
                       control(b, at);
                   },
                   [&](uint32_t start, uint32_t n) noexcept {
                       renderPeriod(left + start, right + start, n, offset + start);
                       if (!idle_) sinceControl_ += n;  // gone idle: every clock stands still
                   });
    }

private:
#include "flagship/modulation.inc"

#include "flagship/configure.inc"

#include "flagship/render.inc"

    struct Slot {
        int source = kSrcNone;
        int target = 0;  // into targetParam_
        double amount = 0.0;
        bool bipolar = false;
        int via = kSrcNone;  // the source the amount is scaled by (None: 1)
    };

    VoicePool<Voice, kVoices> voices_;
    VoiceLanes lanes_;  // the host's voice bus for this block (#127), or none
    HeldNotes held_;  // mono and legato
    lib::CombFilter combs_[kVoices][kFilters * 2];
    const lib::Wavetable* table_[kTableChoices] = {};  // the built-in tables, then User, then Additive
    flagship::SourceId source_[kTableChoices] = {};    // each one's id for the spectral banks
    flagship::BankUser banks_;                         // the spectral banks this instance reads
    std::shared_ptr<const UserTable> user_;            // the loaded user table (the state), or none
    lib::HalfBandDesign half_{2 * Decimator2x::kStages, 0.04};               // the FM and 2x fold's decimators
    const std::atomic<int>* quality_ = nullptr;  // the building Engine's (quality.h)
    Clock clock_;
    const Transport* transport_ = nullptr;
    const ProcessBlock* block_ = nullptr;  // the block being processed (beginBlock), for knobs at a note's frame
    double sr_ = 48000.0, tempo_ = 120.0, modWheel_ = 0.0;
    uint32_t sinceControl_ = 0, started_ = 0;
    bool idle_ = true;
    uint64_t quietRun_ = 0;
    float periodPeak_ = 0.0f;
    // The voices ended early: their tails' bound and its slowest fall a frame; the shared stage's most raise of a
    // quiet signal (render.inc, endTail); the EQ's boosts and the reverb's mix it reads.
    double tailDebt_ = 0.0, tailCoef_ = 0.0, tailRaise_ = 1.0, eqBoost_ = 1.0, reverbMix_ = 0.0;

    double base_[kParamCount] = {};
    uint16_t ramp_[kParamCount] = {};  // the parameters ramping in this block
    uint32_t rampCount_ = 0;
    ParameterValue lastValues_[kParamCount] = {};  // the block's values as last handed over (beginBlock)
    uint32_t lastGiven_ = ~0u;
    lib::Lfo lfo_[kLfos];
    double freeLfo_[kLfos] = {};
    Slot slots_[kSlots];
    uint32_t slotCount_ = 0, targetCount_ = 0, used_ = 0;
    uint32_t moved_ = 0;          // the voice sections (sectionOf) a slot moves this control
    uint32_t rampMoved_ = 0;      // the voice sections a ramping knob moved this control (control())
    bool knobsChanged_ = true;    // a knob, the tempo or the quality moved since the last control
    bool noiseUsed_ = false;      // an oscillator's mod source is Noise: each voice draws it at each control
    double lastTempo_ = 0.0;
    int lastQuality_ = -1;  // used_: bit s set when a slot listens to source s
    uint32_t targetParam_[kSlots] = {};
    double targetNorm_[kSlots] = {};
    double targetTop_[kSlots] = {};  // the top of each one's travel (modulationTop)
    uint8_t targetOf_[kModTargets] = {};  // 1 + the parameter's index into targetParam_, 0 if no slot moves it
    double globalOffsets_[kSlots] = {};

    double volume0_ = 0.0, volume1_ = 0.0;
    bool distOn_ = false, eqOn_ = false, chorusOn_ = false, delayOn_ = false, reverbOn_ = false;
    int distType_ = 0;
    double distDrive_ = 2.0, distMix_ = 1.0, crushSteps_ = 8.0;
    lib::Saturator saturator_;
    lib::ThreeBandEq eqL_, eqR_;
    double eqMix_ = 1.0;
    lib::Chorus chorus_;
    double chorusMix_ = 0.35;
    lib::PingPongDelay delay_;
    double delayTime0_ = 0.0, delayTime1_ = 0.0, delayFeedback_ = 0.35, delayMix_ = 0.25;
    lib::Reverb reverb_;
    VoiceFilter shared_;        // filter 1 for the voices whose filter 1 is set alike (startVoice)
    bool sharedOn_ = false;     // filter 1 (unmodulated) is linear, alone and without key tracking
    bool sharedUsed_ = false, sharedQuiet_ = true, sharedRan_ = false;  // fed this piece; resting; fed this period
    float sharedPeak_ = 0.0f;  // its loudest output this period
    float sharedL_[kControlFrames] = {}, sharedR_[kControlFrames] = {};
    static constexpr uint32_t kFxEq = 1, kFxChorus = 2, kFxDelay = 4, kFxReverb = 8;
    uint32_t fxDirty_ = kFxEq | kFxChorus | kFxDelay | kFxReverb;  // the effects that were on since their last clear
};

ModuleProcessor* makeFlagship() noexcept { return new (std::nothrow) FlagshipInstrument(); }

}  // namespace

void registerFlagshipSynth(ModuleRegistry& registry) { registry.add(flagshipDescriptor(), &makeFlagship); }

int flagshipParameterIndex(std::string_view id) noexcept {
    const Params& p = params();
    for (uint32_t k = 0; k < kParamCount; ++k)
        if (p.d[k].id == id) return static_cast<int>(k);
    return -1;
}

}  // namespace caw
