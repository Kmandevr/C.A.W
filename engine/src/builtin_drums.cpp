// org.caw.drums (Drums): 64 pads (4 banks of 16) of layered drum synthesis (body, click, noise, metal, modal resonator, sample) with pad and kit effects.
#include "builtin_drums.h"
#include "builtin_drums_layout.h"
#include "component_samples.h"
#include "drums_acoustic.h"
#include "quality.h"
#include "recorded_bank.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <new>

#include "caw/detmath.hpp"
#include "caw/display.hpp"
#include "caw/instrument.hpp"
#include "caw/library/distortion.hpp"
#include "caw/library/dynamics.hpp"
#include "caw/library/envelope.hpp"
#include "caw/library/eq.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/modal.hpp"
#include "caw/library/oscillator.hpp"
#include "caw/library/oversample.hpp"
#include "caw/library/reverb.hpp"

// Original code (C.A.W. is Apache-2.0). The techniques (an 808-style swept sine body, six-square metal banks,
// band-passed noise bursts for claps, modal membranes and bars) are described in docs/engine.md ("Drums") in our
// own words, with sources; no other instrument's code was used.
//
// How it runs:
// - A voice belongs to a pad; a pool of 64 voices serves all 64 pads (each pad up to its own polyphony, 1..4).
//   Only sounding voices are visited, and in a voice only the layers that are on.
// - Once per control period (16 frames) each pad with a sounding voice reads its knobs and works out its
//   settings (macros included); each of its voices then works out its coefficients (with its own velocity,
//   variation, glide and pressure). A pad that isn't sounding reads nothing: unused pads cost nothing.
// - The grid runs on from block to block (it never restarts), and a hit reads its pad's knobs at its own frame,
//   so a render is the same at any block size.

#if defined(_MSC_VER) && !defined(__clang__)
#define CAW_DRUMS_INLINE __forceinline
#else
#define CAW_DRUMS_INLINE inline __attribute__((always_inline))
#endif

namespace caw {

namespace {

using namespace drums;

#include "drums/kernels.inc"

#include "drums/pad_settings.inc"

// ---------- A voice ----------

struct Variation {
    double gain = 1, pitch = 0, decayMul = 1, toneOct = 0, click = 1, pan = 0, punch = 1, pos = 0;
};

struct DrumVoice {
    // bookkeeping
    bool active = false, held = false;
    int pad = -1;
    uint32_t noteId = 0;
    uint64_t age = 0;
    double note = 60, velocity = 1, pressure = 0;
    Variation var;
    double glideSt = 0, glideTarget = 0;
    // fades: a choke or steal (5 ms), a gate's release, a pressure damp
    bool fading = false, releasing = false;
    double fadeGain = 1, fadeCoef = 1, relGain = 1, relCoef = 1, dampGain = 1, dampCoef = 1;
    // what this voice runs (copied from its pad's settings at each control)
    bool body = false, click = false, noise = false, metal = false, res = false, smp = false;
    int quality = kQualityNormal;
    // body
    DrumEnv bodyEnv, pitchEnv;
    double phase = 0, phase2 = 0, fEnd = 55, fStart = 220, invSr = 1.0 / 48000, p2ratio = 1.5, p2level = 0,
           shapeAmt = 0, shapeNorm = 1, fold = 0, bodyLevel = 1, bodyF = 55;
    int wave = 0;
    // pitch shape: four segments in semitones over the settled pitch
    bool points = false;
    int pSeg = 0;
    uint32_t pPos = 0, pLen[4] = {1, 1, 1, 1};
    double pFrom[4] = {}, pTo[4] = {}, pK[4] = {1, 1, 1, 1}, pSign[4] = {};
    // sub
    bool sub = false, subClean = true;
    int subWave = 0;
    DrumEnv subEnv;
    lib::OnePole subLpf;
    double subPhase = 0, subDt = 0, subFollow = 0, subDrive = 0, subNorm = 1, subLevel = 0.5, subOut = 0;
    bool subFilter = false;
    // click
    DrumEnv clickEnv;
    lib::OnePole clickHp;
    lib::Svf clickBp;
    double clickPhase = 0, clickTone = 2000, clickLevel = 0.5;
    int clickType = 0;
    // noise
    DrumEnv noiseEnv, tailEnv;
    lib::Noise rng{1};
    lib::Svf noiseSvf;
    double pink[3] = {0, 0, 0}, pinkK[3] = {0, 0, 0}, brown = 0, brownK = 0, crushHeld = 0, wire = 0, wireK = 0;
    double shellPhase = 0, shellDt = 0, shellLevel = 1, shellCoef = 1;  // Snappy's own shell, with the body off
    uint32_t crushEvery = 1, crushLeft = 0, clapCount = 0, clapPeriod = 480, clapBursts = 3;
    double burst = 0, burstCoef = 0, noiseLevel = 1, sweep = 0, noiseFreq = 2000, noiseQ = 0.707;
    int noiseMode = 0, color = 0, noiseFilter = kFilterHp;
    // metal
    DrumEnv metalEnv;
    lib::Svf metalBp, metalHp;
    lib::Oversampler2x metalOs{halfBand()};
    double mPhase[6] = {}, mDt[6] = {}, mAmp[6] = {}, fmIndex = 0, metalNoise = 0.5, band = 0, bandGain = 1, metalLevel = 1;
    int metalMode = 0;
    // resonator
    lib::ModalBank modal;
    lib::ModalSettings modalSet;
    uint32_t exciteLeft = 0, exciteLength = 1, exciteAt = 0;
    double resInput = 0.2, resLevel = 1;
    int exciter = kExciteMallet;
    bool ringing = false;
    // sample
    const SampleBuffer* sample = nullptr;
    double smpPos = 0, smpStep = 1, smpFirst = 0, smpLast = 0, smpLevel = 1;
    bool reverse = false, smpPlaying = false;
    DrumEnv smpEnv;
    // fm (1.1.0)
    bool fm = false;
    DrumEnv fmEnv, fmIEnv, fmPEnv;
    double fmPhaseC = 0, fmPhaseM = 0, fmPrev = 0, fmF = 200, fmStartMul = 1, fmRatio = 1.41, fmDepth = 0, fmFb = 0,
           fmLevel = 1;
    // phys (1.1.0): the waveguide's line lives in the processor's pool (one stretch per voice)
    bool phys = false;
    float* physLine = nullptr;
    uint32_t physMax = 0, physW = 0, physExciteLeft = 0, physExciteLength = 1;
    double physDelay = 100, physPickDelay = 0, physGain = 0.99, physSign = 1, physLp = 0, physLpK = 0.5, physAp = 0,
           physApIn = 0, physApK = 0, physInput = 0, physLevel = 1, physPeak = 0;
    int physModel = 0, physExciter = 0;
    // tex (1.1.0)
    bool tex = false;
    int texMode = 0;
    DrumEnv texEnv;
    lib::Svf texLo, texHi;
    double texLoGain = 1, texHiGain = 1, texChance = 0, texGrain = 0, texGrainK = 0, texGrainAmp = 0, texScale = 1,
           texLevel = 1;
    // the sample's pitch drop (1.1.0)
    DrumEnv smpPEnv;
    double smpDrop = 0;
    // ring modulator (1.1.0)
    double ringMix = 0, ringPhase = 0, ringDt = 0;
    // sends (1.1.0)
    double echoSend = 0, busSend = 1;
    // accent (1.1.0): this hit's
    double accent = 0;
    // effects
    Drive drive, clipper;
    bool drivePost = false, driveLoOn = false, driveHiOn = false;
    double driveMix = 1;
    lib::OnePole driveLo;
    lib::Svf driveHi;
    double compA = -1, compR = -1;
    // width: a short-delayed, high-passed copy as the side signal
    bool wide = false;
    float widthBuf[128] = {};
    uint32_t widthAt = 0, widthDelay = 20;
    lib::Svf widthHp, widthHp2;
    double width = 0, side = 0, roomSend = 1, gainMid = 1;
    int flt = 0;
    lib::OnePole lp6;
    lib::Svf svf;
    double fltEnvLevel = 1, fltEnvCoef = 0;
    bool eq = false;
    lib::EqBand eqLow, eqMid, eqHigh;
    bool shaper = false, comp = false;
    lib::EnvelopeFollower fast, slow, compEnv;
    double trA = 0, trS = 0, compThr = 0, compRatio = 1, compMakeup = 1, gr = 0;
    double gainL = 1, gainR = 1;
    // display
    bool capture = false;

    bool sounding() const noexcept {
        return bodyEnv.active() || subEnv.active() || clickEnv.active() || noiseEnv.active() || tailEnv.active() ||
               clapCount < clapEnd() || metalEnv.active() || ringing || smpPlaying || fmEnv.active() ||
               (phys && (physExciteLeft > 0 || physPeak > 2e-5)) || texEnv.active();
    }
    uint32_t clapEnd() const noexcept { return noiseMode == kNoiseClap && noise ? clapBursts * clapPeriod : 0; }
};

// ---------- The instrument ----------

const ModuleDescriptor& drumsDescriptor();

class DrumsProcessor final : public InstrumentProcessor, public SampleSlots {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return drumsDescriptor(); }

    bool activate(double sampleRate, uint32_t maxFrames) noexcept override {
        (void)maxFrames;
        sr_ = sampleRate > 0.0 && std::isfinite(sampleRate) ? sampleRate : 48000.0;
        quality_ = buildingQuality();
        try {
            room_.prepare(sr_, 64, 0.1);
            // 1.1.0: the waveguides' lines (a period at 30 Hz per voice) and the echo's 2 s.
            physMax_ = static_cast<uint32_t>(sr_ / 30.0) + 8;
            physPool_.assign(static_cast<size_t>(physMax_) * kVoices, 0.0f);
            const size_t echo = static_cast<size_t>(2.0 * sr_) + 8;
            echoL_.assign(echo, 0.0f);
            echoR_.assign(echo, 0.0f);
            if (!acoustic_.prepare(sr_)) return false;  // 1.1.2: the Acoustic kit's mic delay lines
            // 1.1.3: the recorded kit parts (decoded on first use, shared, freed with the last Rook); without them
            // every piece plays its model.
            if (!bank_) bank_ = recorded::acquire(recorded::BankId::RookKit);
            acoustic_.setRecordings(bank_ ? acoustic::RecBank{bank_->pcm.get(), bank_->frames, static_cast<double>(bank_->rate)}
                                          : acoustic::RecBank{});
        } catch (...) {
            return false;
        }
        displayClock_.prepare(sr_);
        display_.clear();
        reset();
        return true;
    }

    void reset() noexcept override {
        for (DrumVoice& v : voices_) v = DrumVoice{};
        live_ = 0;
        for (uint32_t p = 0; p < kPads; ++p) {
            hits_[p] = 0;
            heldCount_[p] = 0;
            padLevel_[p] = 0.0f;
        }
        for (auto& c : captureMax_) c.fill(0.0f);
        for (auto& c : captureMin_) c.fill(0.0f);
        captureAt_.fill(0);
        captureBin_.fill(1);
        glue_.clear();
        glueGain_ = 1.0;
        kitDriveL_.clear();
        kitDriveR_.clear();
        kitClipL_.clear();
        kitClipR_.clear();
        kitLowL_.clear();
        kitLowR_.clear();
        kitHighL_.clear();
        kitHighR_.clear();
        kitLowDb_ = kitHighDb_ = 1e9;
        room_.clear();
        roomQuiet_ = 0;
        clearEcho();
        pending_ = 0;
        lastKey_ = -1;
        lastChannel_ = 0;
        lastVelocity_ = 0;
        notesSeen_ = 0;
        roomOn_ = false;
        settled_ = true;
        left_ = 0;
        clock_ = 0;
        lastPad_ = -1;
        acoustic_.reset();
        lastPedal_ = -1.0;
        acousticRead_ = ~0ull;
    }

    bool quiet() const noexcept override { return settled_ && !lanes_.any() && pending_ == 0; }

    uint32_t readDisplay(float* out, uint32_t max) const noexcept override { return display_.read(out, max); }

    // SampleSlots: one slot per pad (A1 = 0).
    uint32_t sampleSlotCount() const noexcept override { return kPads; }
    const std::string& sampleSource(uint32_t slot) const noexcept override {
        static const std::string none;
        return slot < kPads ? sources_[slot] : none;
    }
    bool setSample(uint32_t slot, std::unique_ptr<SampleBuffer> buffer) noexcept override {
        if (slot >= kPads) return false;
        if (!buffer) buffer.reset(new (std::nothrow) SampleBuffer());
        if (!buffer) return false;
        sources_[slot] = buffer->source;
        slots_[slot].offer(buffer.release());
        return true;
    }

protected:
    void beginBlock(const ProcessBlock& b) noexcept override {
        block_ = &b;
        ++blockCount_;
        lanes_.bind(b);
        // A new sample: voices still playing the one it replaces stop their sample layer (it is freed later).
        for (uint32_t s = 0; s < kPads; ++s) {
            const SampleBuffer* before = playing_[s];
            const SampleBuffer* now = slots_[s].poll();
            if (now != before) {
                for (DrumVoice& v : voices_)
                    if (v.sample == before && before) v.sample = nullptr, v.smpPlaying = false;
                playing_[s] = now;
            }
        }
        const bool playing = b.transport && b.transport->playing;
        if (playing && !wasPlaying_)  // Play: the variation starts over, so a render repeats
            for (uint32_t p = 0; p < kPads; ++p) hits_[p] = 0;
        wasPlaying_ = playing;
        mode_ = clampi(parameterAt(b, kMode, 0, kModeKit), 0, 1);
        channel_ = clampi(parameterAt(b, kChannel, 0, 0), 0, 16);
        base_ = clampi(parameterAt(b, kBaseNote, 0, 36), 0, 64);
        seed_ = static_cast<uint32_t>(clampi(parameterAt(b, kSeed, 0, 1), 0, 65535));
    }

    void onNote(const NoteMessage& m) noexcept override {
        if (!block_) return;
        const uint32_t at = m.frame;
        switch (m.type) {
            case NoteMessageType::On: noteOn(m, at); break;
            case NoteMessageType::Off: noteOff(m, at); break;
            case NoteMessageType::Pressure:
                for (DrumVoice& v : voices_)
                    if (v.active && v.noteId == m.noteId) v.pressure = clampd(m.value, 0, 1);
                if (acoustic_.awake()) acoustic_.pressure(m.noteId, m.value);  // a cymbal's grab (1.1.2)
                break;
            default: break;
        }
    }

    void render(float* left, float* right, uint32_t frames, uint32_t offset, const ProcessBlock& b) noexcept override {
        for (uint32_t i = 0; i < frames;) {
            uint32_t until = frames - i;
            if (pending_) until = firePending(offset + i, until);
            if (left_ == 0) {
                control(b, offset + i);
                left_ = kControlFrames;
            }
            const uint32_t n = std::min(left_, until);
            renderChunk(left + i, right + i, n, offset + i);
            i += n;
            left_ -= n;
            clock_ += n;
        }
        if (displayClock_.tick(frames)) publish(b, offset);
    }

    // The voice bus (#127): a hit's lane ends once no voice plays its note.
    void endBlock(const ProcessBlock&) noexcept override {
        if (!lanes_.any()) return;
        lanes_.endBlock([&](uint32_t id) noexcept {
            for (uint32_t i = 0; i < live_; ++i)
                if (voices_[list_[i]].active && voices_[list_[i]].noteId == id) return true;
            return false;
        });
    }

private:
#include "drums/notes.inc"

#include "drums/voice_start.inc"

#include "drums/voice_sample.inc"

#include "drums/block.inc"

public:
    static constexpr uint32_t kDisplayFloats = 80 + 2 * kBins + kPitchPoints;  // 656

private:
    static constexpr uint32_t kHeldMax = 8;

    double sr_ = 48000.0;
    const std::atomic<int>* quality_ = nullptr;
    const ProcessBlock* block_ = nullptr;
    DrumVoice voices_[kVoices];
    uint16_t list_[kVoices] = {};
    uint32_t live_ = 0;
    uint64_t age_ = 0;
    PadSettings settings_[kPads];
    uint32_t hits_[kPads] = {};
    std::pair<uint32_t, double> held_[kPads][kHeldMax] = {};
    uint32_t heldCount_[kPads] = {};
    int mode_ = kModeKit, channel_ = 0, base_ = 36;
    uint32_t seed_ = 1;
    bool wasPlaying_ = false;
    uint32_t left_ = 0;
    uint64_t clock_ = 0, blockCount_ = 0;
    // samples
    SampleHandover slots_[kPads];
    const SampleBuffer* playing_[kPads] = {};
    std::string sources_[kPads];  // control thread
    // kit effects
    lib::EnvelopeFollower glue_;
    double glueAmount_ = 0, glueThr_ = -12, glueRatio_ = 4, glueMakeup_ = 1, glueGr_ = 0, glueGain_ = 1;
    int kitDriveType_ = 0;
    double kitDriveMix_ = 1;
    Drive kitDriveL_, kitDriveR_, kitClipL_, kitClipR_;
    lib::EqBand kitLowL_, kitLowR_, kitHighL_, kitHighR_;
    bool kitEq_ = false;
    int kitClip_ = 0;
    double kitLowDb_ = 1e9, kitHighDb_ = 1e9;
    // note learn: the last note received (any note, a pad or not)
    int lastKey_ = -1, lastChannel_ = 0;
    float lastVelocity_ = 0;
    uint32_t notesSeen_ = 0;
    lib::Reverb room_;
    bool roomOn_ = false, settled_ = true;
    // 1.1.0: the waveguides' lines, the echo, and the hits groove holds back (swing, humanize, flam)
    std::vector<float> physPool_;
    uint32_t physMax_ = 0;
    std::vector<float> echoL_, echoR_;
    uint32_t echoW_ = 0, echoQuiet_ = 0;
    double echoDelay_ = 1, echoTarget_ = 1, echoFb_ = 0.35, echoSpread_ = 0.6, echoK_ = 0.5, echoLpL_ = 0, echoLpR_ = 0,
           echoMix_ = 0;
    bool echoOn_ = false;
    struct Pending {
        uint64_t due = 0;
        uint32_t pad = 0;
        NoteMessage m;
        double accent = 0;
        bool grace = false, released = false;
    };
    static constexpr uint32_t kPendingMax = 128;
    Pending pendingHits_[kPendingMax];
    uint32_t pending_ = 0;
    VoiceLanes lanes_;  // the host's voice bus for this block (#127), or none
    struct LaneOut {
        uint32_t noteId = 0;
        uint8_t out = 0;
    };
    LaneOut laneOuts_[VoiceLanes::kMaxLanes];
    uint32_t laneOutNext_ = 0;
    double roomMix_ = 0;
    uint32_t roomQuiet_ = 0;
    double volume_ = 1;
    // display
    DisplayBuffer<kDisplayFloats> display_;
    bool watched_ = true;  // a UI read the display lately (publish): hits capture their waveform
    acoustic::AcousticKit acoustic_;  // 1.1.2: the Acoustic kit's 16 pieces
    std::shared_ptr<const recorded::Bank> bank_;  // 1.1.3: its recorded parts (held while this Rook lives)
    const ParameterDescriptor* table_ = parameterTable();
    double lastPedal_ = -1.0;
    uint64_t acousticRead_ = ~0ull;  // the block its settings were last read in
    bool acousticRamps_ = false;     // one of them ramps: read them every control
    DisplayClock displayClock_;
    float frame_[kDisplayFloats] = {};
    float padLevel_[kPads] = {};
    std::array<std::array<float, kBins>, kPads> captureMax_{}, captureMin_{};
    std::array<uint32_t, kPads> captureAt_{}, captureBin_{};
    float captureLength_[kPads] = {};
    int lastPad_ = -1;
    uint32_t publishCount_ = 0;
};

constexpr PortDescriptor kPorts[] = {
    {"notes", PortType::Event, ChannelLayout::None, true, 0, true, 0.0f},
    stereoOutput("out"),
};

const ModuleDescriptor& drumsDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor m;
        m.id = kDrumsId;
        m.name = "Drums";
        m.role = ModuleRole::Instrument;
        m.ports = kPorts;
        m.portCount = 2;
        m.parameters = parameterTable();
        m.parameterCount = kParamCount;
        m.tailFrames = 192000 * 70;  // a 60 s ring at 192 kHz and the room; it says quiet() sooner
        m.domains = kDomainWhole | kDomainPerNote;  // #127: one voice-bus lane per hit
        m.capabilities = kCapabilityNotesIn | kCapabilitySampleAssets;
        m.cpuClass = CpuClass::Medium;
        return m;
    }();
    return d;
}

ModuleProcessor* makeDrums() noexcept { return new (std::nothrow) DrumsProcessor(); }

}  // namespace

void registerDrums(ModuleRegistry& registry) { registry.add(drumsDescriptor(), &makeDrums); }

// Renders one sound of the library as a built-in one-shot: a hit at full velocity on pad A1 in Single mode, until
// it falls silent (at most 6 s), the sample layer off.
bool renderBuiltinDrumSample(std::string_view name, double sampleRate, std::vector<float>& out) {
    const Sound* sound = findSound(name);
    return sound && drums::renderVoice(sound->voice, sampleRate, 6.0, out);
}

bool drums::renderVoice(const Voice& voice, double sampleRate, double seconds, std::vector<float>& out) {
    const Voice* sound = &voice;
    std::unique_ptr<DrumsProcessor> p(new (std::nothrow) DrumsProcessor());
    if (!p || !p->activate(sampleRate, 64)) return false;
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> values(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) values[k].value = d.parameters[k].defaultValue;
    values[kMode].value = kModeSingle;
    for (uint32_t k = 0; k < kPadParams; ++k) values[padParam(0, k)].value = (*sound)[k];
    values[padParam(0, kSmpOn)].value = 0.0;
    values[padParam(0, kPan)].value = 0.0;
    values[padParam(0, kRndPan)].value = 0.0;
    values[padParam(0, kFlam)].value = 0.0;  // a one-shot of the sound itself: no grace hit, no lateness
    values[padParam(0, kHumanize)].value = 0.0;
    const uint32_t most = static_cast<uint32_t>(seconds * sampleRate);
    out.clear();
    out.reserve(most);
    float l[64], r[64];
    float* ch[2] = {l, r};
    const ChannelBufferView audio{ch, 2, 64};
    const Event on = notes::noteOn(0, 1, 60, 1.0);
    uint32_t silent = 0;
    for (uint32_t done = 0; done < most; done += 64) {
        const EventInput in{&on, done == 0 ? 1u : 0u};
        ProcessBlock b;
        b.frames = 64;
        b.sampleRate = sampleRate;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &in;
        b.eventInCount = 1;
        b.parameters = values.data();
        b.parameterCount = d.parameterCount;
        if (!p->processPorts(b)) return false;
        for (int i = 0; i < 64; ++i) out.push_back(0.5f * (l[i] + r[i]));  // centred: both sides carry it whole
        if (p->quiet()) {
            if (++silent > 2) break;
        }
    }
    while (!out.empty() && std::fabs(out.back()) < 1e-6f) out.pop_back();
    return !out.empty();
}

}  // namespace caw
