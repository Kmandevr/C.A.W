// The built-in effects suite (#173): registration, and the base every effect shares (control grid, sleep, display).
#pragma once

#include <cstdint>
#include <deque>
#include <string>
#include <string_view>
#include <vector>

#include "caw/display.hpp"
#include "quality.h"
#include "caw/library/fastmath.hpp"
#include "module_registry.h"

namespace caw {

// Registers the suite: org.caw.eq, .compressor, .limiter, .reverb.pro, .delay.pro, .saturator, .gate, .filter,
// .phaser, .flanger, .utility, .transient (builtin_effects_*.cpp) and .ducker (builtin_ducker.cpp).
// registerBuiltinComponents calls it.
void registerBuiltinEffects(ModuleRegistry& registry);

namespace fx {

void registerEq(ModuleRegistry& registry);         // builtin_effects_eq.cpp
void registerDynamics(ModuleRegistry& registry);   // builtin_effects_dynamics.cpp: compressor, limiter, gate, transient
void registerSpace(ModuleRegistry& registry);      // builtin_effects_space.cpp: reverb, delay
void registerSaturator(ModuleRegistry& registry);  // builtin_effects_saturator.cpp
void registerKit(ModuleRegistry& registry);        // builtin_effects_kit.cpp: filter, phaser, flanger, utility
void registerDucker(ModuleRegistry& registry);     // builtin_ducker.cpp: the ducker (#175)
// fx-dynamics begin
void registerFxDynamics(ModuleRegistry& registry);  // builtin_fx_dynamics.cpp: dynamics, multiband, de-esser (and the drive file's)
void registerFxDrive(ModuleRegistry& registry);     // builtin_fx_drive.cpp: clipper, phase distortion
// fx-dynamics end

constexpr std::string_view kOffOn[] = {"Off", "On"};

// A parameter table built at start-up (ids and names may be made from a prefix, as the EQ's "b3_freq"). The
// strings live in deques, so the descriptors' string_views stay valid as it grows.
class ParamTable {
public:
    ParameterDescriptor& num(std::string id, std::string name, double def, double lo, double hi,
                             std::string_view unit = {}) {
        ids_.push_back(std::move(id));
        names_.push_back(std::move(name));
        ParameterDescriptor p;
        p.id = ids_.back();
        p.name = names_.back();
        p.defaultValue = def;
        p.minimum = lo;
        p.maximum = hi;
        p.unit = unit;
        p.smoothingFrames = 480;  // 10 ms at 48 kHz: a knob move doesn't click
        d_.push_back(p);
        return d_.back();
    }
    // Times, frequencies, rates, ratios: the knob tapers (each step multiplies), fine near the bottom.
    ParameterDescriptor& expo(std::string id, std::string name, double def, double lo, double hi,
                              std::string_view unit = {}) {
        ParameterDescriptor& p = num(std::move(id), std::move(name), def, lo, hi, unit);
        p.curve = ParameterCurve::Exponential;
        return p;
    }
    template <size_t N>
    ParameterDescriptor& pick(std::string id, std::string name, double def, const std::string_view (&labels)[N]) {
        ParameterDescriptor& p = num(std::move(id), std::move(name), def, 0.0, static_cast<double>(N - 1));
        p.step = 1.0;
        p.choices = labels;
        p.choiceCount = static_cast<uint32_t>(N);
        p.smoothingFrames = 0;  // a choice jumps
        return p;
    }
    const ParameterDescriptor* data() const noexcept { return d_.data(); }
    uint32_t size() const noexcept { return static_cast<uint32_t>(d_.size()); }
    // Index of a parameter by id (start-up only; -1 if none).
    int index(std::string_view id) const noexcept {
        for (size_t k = 0; k < d_.size(); ++k)
            if (d_[k].id == id) return static_cast<int>(k);
        return -1;
    }

private:
    std::deque<std::string> ids_, names_;
    std::vector<ParameterDescriptor> d_;
};

// A value read at control points and ramped in a straight line over the kControlFrames frames after each (a mix,
// a gain): the first set() after a reset() jumps.
struct Ramp {
    double value = 0.0, step = 0.0;
    bool fresh = true;
    void set(double target, uint32_t frames) noexcept {
        if (fresh) value = target, fresh = false;
        step = (target - value) / static_cast<double>(frames);
    }
    double next() noexcept { return value += step; }
    void reset() noexcept { fresh = true, step = 0.0; }
};

// Note divisions for tempo sync, in whole notes: straight, triplet (x 2/3) and dotted (x 1.5).
constexpr std::string_view kSyncDivisions[] = {"Free",  "1/32",  "1/16 T", "1/16", "1/16 D", "1/8 T", "1/8",   "1/8 D",
                                               "1/4 T", "1/4",   "1/4 D",  "1/2 T", "1/2",    "1/2 D", "1 bar", "2 bars"};
constexpr double kSyncWholeNotes[] = {0.0,         0.03125, 0.0625 * 2 / 3, 0.0625, 0.09375, 0.125 * 2 / 3, 0.125, 0.1875,
                                      0.25 * 2 / 3, 0.25,   0.375,          1.0 / 3, 0.5,    0.75,          1.0,   2.0};
static_assert(sizeof(kSyncDivisions) / sizeof(kSyncDivisions[0]) == sizeof(kSyncWholeNotes) / sizeof(kSyncWholeNotes[0]));
constexpr int kSyncCount = static_cast<int>(sizeof(kSyncWholeNotes) / sizeof(kSyncWholeNotes[0]));

// A stereo effect's descriptor: one stereo input, one stereo output (what a track's chain takes).
ModuleDescriptor effectDescriptor(std::string_view id, std::string_view name, const ParamTable& params,
                                  uint32_t latencyFrames, uint32_t tailFrames);
// A keyed effect's: the stereo input, a stereo "sidechain" input (the key another layer sends it), with `notes`
// an event input "key_notes" (the notes the key's layer plays), and the stereo output (ComponentChain::isKeyedEffect).
ModuleDescriptor keyedEffectDescriptor(std::string_view id, std::string_view name, const ParamTable& params,
                                       uint32_t latencyFrames, uint32_t tailFrames, bool notes);

// What every effect of the suite shares:
// - a control grid: control() reads the knobs every 16 frames, counted across blocks, so any block size gives
//   the same bits; run() does the per-sample work in between;
// - sleep: after `idleFrames()` frames of silent input and output (below -110 dB), at a grid point, the state is
//   cleared and the effect says it is quiet(); a sleeping effect (or one the host still runs) passes silence and
//   wakes on the first input sample that is not 0, where its grid restarts, so where it sleeps and wakes doesn't
//   depend on the block size either;
// - display: about 60 times a second fillDisplay() writes the effect's floats, which a UI reads through
//   readDisplay() (caw/display.hpp); input and output peaks since the last publish are counted here.
class EffectBase : public ModuleProcessor {
public:
    static constexpr uint32_t kControlFrames = 16;

    bool activate(double sampleRate, uint32_t maxFrames) noexcept override;
    void reset() noexcept override;
    bool quiet() const noexcept override { return idle_; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override;
    // A keyed effect (its descriptor has a "sidechain" input) takes its ports: the main input and output, the key
    // and the key's notes; the rest is process() as for any effect.
    bool usesProcessPorts() const noexcept override { return keyed_; }
    bool processPorts(const ProcessBlock& b) noexcept override;
    uint32_t readDisplay(float* out, uint32_t max) const noexcept override { return display_.read(out, max); }

protected:
    // Control thread, at activate: allocate (delay lines, tables). False refuses the instance.
    virtual bool prepare(double sampleRate, uint32_t maxFrames) noexcept = 0;
    // Audio thread: the knobs at frame `at` of the block (param()).
    virtual void control(uint32_t at) noexcept = 0;
    // Audio thread: n frames (at most kControlFrames) from in to out (they may not alias).
    virtual void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept = 0;
    // Back to silence (delay lines, filter states, followers).
    virtual void clearState() noexcept = 0;
    // Frames of silence in and out after which nothing more can come out (a delay's time, a reverb's pre-delay).
    virtual uint64_t idleFrames() const noexcept { return static_cast<uint64_t>(0.05 * rate_); }
    // The display floats (at most kMaxDisplayFloats) into out; returns the count. `watched`: a UI read lately
    // (skip expensive work otherwise).
    virtual uint32_t fillDisplay(float* out, bool watched) noexcept = 0;

    // A keyed effect, inside run(): the key's frames from run()'s first one (null when the host gives no key:
    // silence), and that frame's place in the block (for the key's notes, whose frames count from the block).
    const float* keyLeft() const noexcept { return keyL_ ? keyL_ + runAt_ : nullptr; }
    const float* keyRight() const noexcept { return keyR_ ? keyR_ + runAt_ : nullptr; }
    uint32_t runStart() const noexcept { return runAt_; }
    const EventInput& keyNotes() const noexcept { return keyNotes_; }

    // Parameter k at frame `at` of the current block (its default when the host resolves none).
    double param(uint32_t k, uint32_t at) const noexcept {
        if (!block_ || k >= block_->parameterCount || !block_->parameters) return descriptor().parameters[k].defaultValue;
        const ParameterValue& v = block_->parameters[k];
        return v.samples ? v.samples[at] : v.value;
    }
    int choice(uint32_t k, uint32_t at) const noexcept { return static_cast<int>(param(k, at) + 0.5); }
    bool on(uint32_t k, uint32_t at) const noexcept { return param(k, at) >= 0.5; }
    // The song's tempo (the last one the host gave; 120 before any).
    double tempo() const noexcept { return tempo_; }
    // Seconds of sync division `division` (kSyncDivisions; 0 = Free) at the song's tempo.
    double syncSeconds(int division) const noexcept {
        const int d = division < 0 ? 0 : (division >= kSyncCount ? kSyncCount - 1 : division);
        return kSyncWholeNotes[d] * 240.0 / tempo_;
    }
    // While the song plays: its position in beats at frame `at` of the block (false while stopped).
    bool beatAt(uint32_t at, double& beat) const noexcept {
        if (!block_ || !block_->transport || !block_->transport->playing) return false;
        beat = block_->transport->beat + static_cast<double>(at) * tempo_ / (60.0 * rate_);
        return true;
    }
    double rate() const noexcept { return rate_; }
    // The Engine's quality now (quality.h): Eco, Normal or High.
    int quality() const noexcept { return qualityNow(quality_); }
    // Peaks since the last publish, in dB (floored at -120).
    float inPeakDb() const noexcept { return static_cast<float>(lib::gainToDb(inPeak_)); }
    float outPeakDb() const noexcept { return static_cast<float>(lib::gainToDb(outPeak_)); }

private:
    const AudioProcessBlock* block_ = nullptr;
    bool keyed_ = false;                          // the descriptor has a "sidechain" input (activate)
    const float* keyL_ = nullptr;                 // this block's key (processPorts), else null
    const float* keyR_ = nullptr;
    EventInput keyNotes_{};
    uint32_t runAt_ = 0;                          // the frame of the block run() starts at
    const std::atomic<int>* quality_ = nullptr;  // the building Engine's (activate)
    bool skipPublish_ = false;                   // Eco publishes every other display tick (30 a second)
    double rate_ = 48000.0, tempo_ = 120.0;
    uint32_t left_ = 0;         // frames until the next control
    uint64_t silent_ = 0;       // frames of silence in and out so far
    bool idle_ = true;          // asleep: silence out until an input sample that is not 0
    double inPeak_ = 0.0, outPeak_ = 0.0;
    DisplayClock clock_;
    DisplayBuffer<kMaxDisplayFloats> display_;
    float shown_[kMaxDisplayFloats] = {};
};

}  // namespace fx
}  // namespace caw
