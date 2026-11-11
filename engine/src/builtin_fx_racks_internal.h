// The racks' shared container class (fx-racks): slots of built-in effects, a per-instance descriptor, the control grid and sleep.
#pragma once

#include <cmath>
#include <cstdint>
#include <deque>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "builtin_effects.h"
#include "builtin_fx_racks.h"
#include "caw/display.hpp"
#include "component_chain.h"
#include "params.h"
#include "quality.h"
#include "route_math.h"

namespace caw {
namespace fx {

inline constexpr uint32_t kRackControlFrames = 16;  // the grid: knobs and modulators every 16 frames
inline constexpr uint32_t kRackRoutes = 16;         // the FX rack's mod routes (as Flagship's slots)
inline constexpr uint32_t kRackDisplayFloats = 160;
inline constexpr uint32_t kMaxChunkEvents = 128;

// The FX rack's mod sources, by `modN_src` value.
inline constexpr std::string_view kRackSources[] = {
    "None",    "LFO 1",   "LFO 2",   "LFO 3",   "LFO 4",   "Follower 1", "Follower 2", "Env 1",   "Env 2",
    "Random",  "Macro 1", "Macro 2", "Macro 3", "Macro 4", "Macro 5",    "Macro 6",    "Macro 7", "Macro 8"};
inline constexpr uint32_t kRackSourceCount = sizeof(kRackSources) / sizeof(kRackSources[0]);

// What one kind of rack is: its own parameters (slots' `_fx` and `_on` among them), its slots, its ports, and the
// descriptor it has with every slot empty (the registry's).
struct RackLayout {
    struct Slot {
        std::string name;   // "s1", "b2s3": the prefix of its parameters
        std::string label;  // "S1", "B2.3": the prefix of their display names
        int band = 0;       // the multiband rack's band (0-based); 0 on the FX rack
        int fx = -1, on = -1;  // own parameter indices of `<name>_fx` and `<name>_on`
    };
    // A descriptor for some children: the own parameters, each child's as `<slot>.<id>`, then (matrix) the routes.
    struct Built {
        std::deque<std::string> strings;
        std::vector<ParameterDescriptor> params;
        std::vector<std::string_view> dstLabels;
        std::vector<uint32_t> childFirst;  // per slot: the index of its first parameter
        uint32_t modBase = 0;              // the index of mod1_src (the parameter count without a matrix)
        ModuleDescriptor desc;
        void make(const RackLayout& layout, const std::vector<const ModuleDescriptor*>& children);
    };

    std::string_view id, name;
    ParamTable own;
    std::vector<Slot> slots;
    bool keyed = false, matrix = false;
    Built staticBuild;

    // After `own` and `slots` are filled: indexes the slots' parameters and builds the empty descriptor.
    void finish(std::string_view id, std::string_view name, bool keyedPorts, bool hasMatrix);
    // Adds a slot's `_fx` (the child's hash, rackChildHash) and `_on` parameters.
    void addSlot(std::string slotName, std::string slotLabel, int band) {
        ParameterDescriptor& fx = own.num(slotName + "_fx", slotLabel + " effect", 0.0, 0.0, 16777215.0);
        fx.step = 1.0;
        fx.smoothingFrames = 0;
        fx.automatable = false;
        fx.modulatable = false;
        fx.midiMappable = false;
        own.pick(slotName + "_on", slotLabel + " on", 1.0, kOffOn);
        slots.push_back({std::move(slotName), std::move(slotLabel), band, -1, -1});
    }
};

// A rack: a ModuleProcessor whose children are other built-ins, run on a 16-frame grid counted across blocks (so any
// block size gives the same bits), asleep after 50 ms of silence in and out once every child is quiet.
class RackBase : public ModuleProcessor, public RackContainer, public VariableLatency {
public:
    ~RackBase() override;
    const ModuleDescriptor& descriptor() const noexcept override {
        return configured_ ? built_.desc : layout().staticBuild.desc;
    }
    bool configure(const ModuleRegistry& registry, const std::vector<std::pair<std::string, double>>& params,
                   bool lenient, std::string& error) override;
    uint32_t readChildDisplay(uint32_t child, float* out, uint32_t max) const noexcept override;
    bool activate(double sampleRate, uint32_t maxFrames) noexcept override;
    void deactivate() noexcept override;
    void reset() noexcept override;
    bool quiet() const noexcept override { return idle_; }
    using ModuleProcessor::process;
    bool process(const AudioProcessBlock& b) noexcept override;
    bool usesProcessPorts() const noexcept override { return layout().keyed; }
    bool processPorts(const ProcessBlock& b) noexcept override;
    uint32_t readDisplay(float* out, uint32_t max) const noexcept override { return display_.read(out, max); }
    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* destination, uint32_t capacity, uint32_t& written) const noexcept override;
    bool loadState(const uint8_t* source, uint32_t size, uint32_t version) noexcept override;
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override;

protected:
    struct Slot {
        std::unique_ptr<ModuleProcessor> processor;  // null: empty
        uint32_t first = 0, count = 0;               // its parameters in the rack's
        bool keyed = false, keyEvents = false, active = false;
        const VariableLatency* variable = nullptr;
        uint32_t latencyCap = 0;  // the most latency it may add (activate)
        double mix = -1.0;        // 1 on, 0 off, between while crossfading; -1 before the first block
    };

    virtual const RackLayout& layout() const noexcept = 0;
    // Control thread, at activate (after the children): set aside lines and buffers.
    virtual bool prepare(double sampleRate) = 0;
    // Audio thread: the knobs at frame `at` of the block.
    virtual void control(uint32_t at) noexcept = 0;
    // Audio thread: n frames (at most kRackControlFrames) at frame `at` of the block; in may alias out.
    virtual void chunk(const float* inL, const float* inR, float* outL, float* outR, uint32_t n, uint32_t at) noexcept = 0;
    virtual void clearState() noexcept = 0;
    // The key's notes between frames at and at + n while asleep (the FX rack counts held notes).
    virtual void idleEvents(uint32_t at, uint32_t n) noexcept { (void)at, (void)n; }
    virtual bool canSleep() const noexcept { return true; }
    virtual uint32_t fillDisplay(float* out, bool watched) noexcept = 0;
    // The rack's latency for these values (the flattened parameters).
    virtual uint32_t latencyOf(const double* values, uint32_t count) const noexcept = 0;

    // Parameter k at frame `at` of the block (its default when the host resolves none).
    double paramAt(uint32_t k, uint32_t at) const noexcept;
    bool on(uint32_t k, uint32_t at) const noexcept { return paramAt(k, at) >= 0.5; }
    int choiceAt(uint32_t k, uint32_t at) const noexcept { return static_cast<int>(paramAt(k, at) + 0.5); }
    // The children's values from frame `at` (into childValues_), before a chunk.
    void sliceChildValues(uint32_t at) noexcept;
    // Runs slot s over n frames at frame `at` (in and out must not alias), with its switch's crossfade.
    void runChild(Slot& s, const float* inL, const float* inR, float* outL, float* outR, uint32_t n, uint32_t at) noexcept;
    bool childrenQuiet() const noexcept;
    // The key's notes in [at, at + n), their frames from `at`.
    const Event* chunkEvents(uint32_t at, uint32_t n, uint32_t& count) noexcept;
    const EventInput& keyNotes() const noexcept { return keyNotes_; }
    const float* keyLeft() const noexcept { return keyL_; }
    const float* keyRight() const noexcept { return keyR_; }
    uint32_t childLatency(const Slot& s, const double* values, uint32_t count) const noexcept;
    // latencyValues_ = every parameter at frame `at` (to ask the children their latency on the audio thread).
    void currentLatencyValues(uint32_t at) noexcept;
    double rate() const noexcept { return rate_; }
    double tempo() const noexcept { return tempo_; }
    const Transport* transport() const noexcept { return transport_; }
    float inPeakDb() const noexcept { return static_cast<float>(lib::gainToDb(inPeak_)); }
    float outPeakDb() const noexcept { return static_cast<float>(lib::gainToDb(outPeak_)); }

    std::vector<Slot> slots_;
    std::vector<ParameterValue> childValues_;
    std::vector<double> latencyValues_;
    RackLayout::Built built_;
    bool configured_ = false;
    const std::atomic<int>* quality_ = nullptr;  // the building Engine's (activate)

private:
    bool run(const AudioProcessBlock& b) noexcept;
    uint32_t childLatencyCap(const Slot& s, double sampleRate) const noexcept;

    const AudioProcessBlock* block_ = nullptr;
    const ParameterValue* blockParams_ = nullptr;
    uint32_t blockParamCount_ = 0;
    const Transport* transport_ = nullptr;
    const float* keyL_ = nullptr;
    const float* keyR_ = nullptr;
    EventInput keyNotes_{};
    std::vector<Event> events_;
    double rate_ = 48000.0, tempo_ = 120.0;
    uint32_t maxFrames_ = 64;
    uint32_t left_ = 0;
    uint64_t silent_ = 0;
    bool idle_ = true, skipPublish_ = false;
    double inPeak_ = 0.0, outPeak_ = 0.0;
    DisplayClock clock_;
    DisplayBuffer<kRackDisplayFloats> display_;
    float shown_[kRackDisplayFloats] = {};
};

// A fixed delay for a stereo pair (latency compensation and the dry path): capacity set aside at prepare.
class RackDelay {
public:
    void prepare(uint32_t maxDelay) {
        size_ = maxDelay + 1;
        l_.assign(size_, 0.0f);
        r_.assign(size_, 0.0f);
        pos_ = 0;
    }
    void clear() noexcept {
        std::fill(l_.begin(), l_.end(), 0.0f);
        std::fill(r_.begin(), r_.end(), 0.0f);
        pos_ = 0;
    }
    // Writes x and reads what was written `delay` frames ago (delay 0: x itself).
    void tick(float& l, float& r, uint32_t delay) noexcept {
        if (size_ == 0) return;
        l_[pos_] = l, r_[pos_] = r;
        const uint32_t d = delay < size_ ? delay : size_ - 1;
        const uint32_t at = pos_ >= d ? pos_ - d : pos_ + size_ - d;
        l = l_[at], r = r_[at];
        pos_ = pos_ + 1 == size_ ? 0 : pos_ + 1;
    }

private:
    std::vector<float> l_, r_;
    uint32_t size_ = 0, pos_ = 0;
};

void registerFxRack(ModuleRegistry& registry);         // builtin_fx_racks_fx.cpp
void registerMultibandRack(ModuleRegistry& registry);  // builtin_fx_racks_multiband.cpp

}  // namespace fx
}  // namespace caw
