// The mixer and its control side: layers with their own loop lengths, hot-swap crossfades, mute/solo, limiter and meters.
#pragma once

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>
#include <vector>

#include "execution.h"
#include "pattern.h"
#include "program.h"
#include "project.h"
#include "spsc.h"
#include "vm.h"

namespace caw {

constexpr int kSlots = kMaxLayers + 1;  // the last slot is the Builder's audition
constexpr int kAuditionSlot = kMaxLayers;
constexpr int kScopeSize = 1024;
constexpr int kMaxVoices = 32;  // most notes a pattern layer plays at once (a module asks for 1..32 with voices:)
// Modules one track runs (its generator or voice, then effects); each is its own mix-graph node.
// A longer chain is refused with a layer error, never truncated.
constexpr int kMaxTrackModules = 32;

struct Meters {
    float cpu = 0, peakL = 0, peakR = 0;
    bool playing = false;
    int64_t position = 0, loopLength = 0;
    int overloaded = 0;  // layers muted because the device ran out of time
};

struct LayerMeter {
    float peak = 0, progress = 0;
    bool overloaded = false, active = false;
};

class Engine {
public:
    // sampleRate must be 8,000-192,000 Hz. Throws std::runtime_error if the mix graph cannot be
    // prepared there, or std::bad_alloc; the C API turns either into a null engine.
    explicit Engine(double sampleRate);
    Engine(double sampleRate, EngineResourceBudget resourceBudget);
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    double sampleRate() const { return sr_; }
    const EngineResourceBudget& resourceBudget() const noexcept { return resourceBudget_; }

    // Control thread. Each returns quickly; compiling happens here, never on the audio thread.
    std::string setProject(const ProjectSpec& p);  // result JSON: per-module ok/error and params
    std::string setProjectJson(std::string_view json);
    void setParam(const std::string& moduleId, const std::string& name, double value);
    void setGlobal(const std::string& name, double value);
    void setLayerMix(const std::string& layerId, double volume, double pan, bool mute, bool solo);
    void setMaster(double volume);
    void play();
    void stop();
    void clearOverload();
    Meters meters();
    bool layerMeter(int index, LayerMeter& out);
    int scope(int index, float* out, int n);  // index -1 is the master output
    int64_t loopLength();                     // samples in the project loop
    // Mix-graph routing updates the graph refused; always 0 unless the routing derivation is wrong.
    uint32_t routingRejections() const noexcept { return routingRejections_.load(std::memory_order_relaxed); }
    // Tests only, between process() calls: graph nodes the last chunk ran.
    uint32_t mixGraphNodesRun() const noexcept;
    // Tests only: skip the master DC blocker and limiter so layer output can be checked exactly.
    void setMasterBypass(bool on) { bypass_.store(on, std::memory_order_relaxed); }

    // Audio thread: no allocation, locks or I/O.
    void process(float* left, float* right, int frames) noexcept;
    void reportLoad(double load) noexcept;  // fraction of the callback's time budget used

    struct Chain;

private:
    struct Slot;
    struct Cmd;
    struct Retired;
    struct AutomationData;
    struct ExportPool;
    struct MixGraph;  // the graph that routes slots, folder buses and master (engine.cpp)

    void drainRetired();
    bool canRetire(size_t count) const noexcept;
    bool send(const Cmd& c);
    void applyCommands() noexcept;
    void retire(Chain* c, int freedSlot, std::shared_ptr<const Pattern>* pattern = nullptr,
                AutomationData* automation = nullptr) noexcept;
    int processChunk(float* l, float* r, int maxFrames) noexcept;  // returns the frames it ran
    int planChunk(int maxFrames) noexcept;
    void planTrack(Slot& s, int& m) noexcept;
    // Graph nodes (audio thread): each module of a track, the track's crossfades and mix, a
    // folder bus, and the master stage.
    void runModuleNode(int slot, int index, const float* const* in, float* const* out, int m) noexcept;
    void runTrackNode(int slot, const float* const* in, float* outL, float* outR, int m) noexcept;
    void runBusNode(int slot, const float* inL, const float* inR, float* outL, float* outR, int m) noexcept;
    void runMasterNode(const float* inL, const float* inR, float* outL, float* outR, int m) noexcept;
    void updateRouting() noexcept;
    double slotTarget(const Slot& s) const noexcept;
    void updateSolo() noexcept;
    void prepareLane(Chain& c, int lane, int64_t n0, int len) noexcept;
    void markTouched(Chain& c, const std::vector<std::string>* ids, const std::string& name);
    void resolveParams(Chain& c, const Instance& inst, size_t idx, int64_t globalStart, int len) noexcept;
    const double* runModule(Chain& c, int lane, bool shadow, size_t idx, int64_t n0, int64_t globalStart, int len,
                            const double* input, Slot* exportTo, const Pattern* pat, int64_t repeat) noexcept;
    void runVoices(Chain& c, const Pattern* pat, int64_t repeat, int64_t n0, int len, double* out, Slot* exportTo,
                   int offset, const BlockCtx& base) noexcept;
    void noteEvent(Chain& c, const Pattern& pat, const PatternEvent& e, int64_t repeat) noexcept;
    void takeExpression(struct Voice& v, const Pattern& pat, const PatternNote& n) noexcept;
    int64_t loopStart(const Slot& s, int64_t k) const noexcept;
    void updateTiming() noexcept;
    void pickOverloadVictim() noexcept;

    const double sr_;
    const EngineResourceBudget resourceBudget_;
    std::unique_ptr<ExportPool> exportPool_;
    std::unique_ptr<MixGraph> mixGraph_;  // built in the constructor; routed on the audio thread

    // ---- audio-thread state ----
    std::unique_ptr<Slot[]> slots_;
    bool playing_ = false;
    int stopFade_ = 0;  // samples left in the stop fade, 0 when not stopping
    int64_t g_ = 0;     // position in the project loop
    int64_t epoch_ = 0; // project loops completed since play
    uint64_t touchEpoch_ = 0;  // the play count of the last Play handled (audio thread); ends touches
    double bpm_ = 120.0;
    int beatsPerBar_ = 4;
    int loopSteps_ = 64;
    uint32_t seed_ = 0;
    double master_ = 0.7;
    double masterTarget_ = 0.7, masterStep_ = 0.0;
    int masterRamp_ = 0;
    bool seamXf_ = true;
    int keyRoot_ = 9, keyScale_ = 1;
    int swapMode_ = 0;  // 0 at once, 1 next beat, 2 next bar
    int voiceLimit_ = kMaxVoices;  // the project's cap on voices for new notes (light mode sends 4)
    bool anySolo_ = false;  // some layer is soloed (refreshed each callback)
    bool auditionOnly_ = false;
    double stepLen_ = 0;  // samples per 16th note
    int64_t loopLen_ = 0; // samples per project loop
    double dcL_[2] = {0, 0}, dcR_[2] = {0, 0}, limEnv_ = 0;
    double loadAvg_ = 0;
    int overCount_ = 0, overCooldown_ = 0;
    bool overloadPending_ = false;
    int processOrder_[kSlots] = {};  // slots in dependency order (exporters before readers)
    int processCount_ = 0;
    int64_t chunkId_ = 0;
    bool routingDirty_ = true;  // re-derive graph routing before the next chunk
    std::unique_ptr<Retired[]> pending_;  // retired chains waiting for room in the queue (owned, so a throwing constructor cannot leak it)
    int pendingCount_ = 0;
    double tmp_[kBlock];

    // ---- shared ----
    std::unique_ptr<Spsc<Cmd, 1024>> cmds_;
    std::unique_ptr<Spsc<Retired, 1024>> retired_;
    std::atomic<float> cpu_{0}, peakL_{0}, peakR_{0};
    std::atomic<bool> playingFlag_{false};
    std::atomic<bool> bypass_{false};
    std::atomic<int64_t> posFlag_{0}, loopLenFlag_{0};
    std::atomic<int> overloadedFlag_{0};
    std::atomic<uint32_t> routingRejections_{0};  // mix-graph routes the executor refused (never expected)
    std::unique_ptr<std::atomic<float>[]> masterScope_;
    std::atomic<int> masterScopePos_{0};

    // ---- control-thread state ----
    std::mutex ctl_;
    struct ModuleState {
        std::string source;
        std::string ref;     // the name other modules use for its exports
        std::string libSig;  // the project libraries it was compiled with
        std::shared_ptr<const Program> program;  // last program that compiled
        std::shared_ptr<const Pattern> pattern;  // pattern modules: the last version that parsed
        std::string error;
        int line = 0, col = 0;
        std::map<std::string, double> params;
        // A synth: the chain it plays as (its voice, generated effect modules, and "\x1e" + name for a project module).
        std::vector<std::string> expand;
    };
    struct LayerState {
        int slot = -1;
        Chain* chain = nullptr;
        std::vector<const Program*> sig;
        std::vector<const double*> wiring;  // where each import of the chain reads from
        int steps = -1;
        bool voiced = false;                     // plays a pattern through a pool of voices
        std::shared_ptr<const Pattern> pattern;  // what the audio thread was last sent
        std::string arrangementSig;              // source + clip signature; keeps compiled timelines stable
        double volume = -1, pan = 0;
        bool mute = false, solo = false, bus = false;
        int parentSlot = -1;
        std::string automationSig;
        size_t expressionCapacity = 0;
        std::string parameterAutomationSig;
    };
    std::map<std::string, ModuleState> modules_;
    std::map<std::string, LayerState> layers_;
    std::vector<std::string> order_;  // layer ids in project order, for meters
    std::map<std::string, double> globals_;
    // Knob moves since the last Play (control thread), so a rebuilt chain keeps their touches.
    std::set<std::pair<std::string, std::string>> touchedParams_;  // (module id, param)
    std::set<std::string> touchedGlobals_;
    uint64_t playCount_ = 0;  // play() calls (control thread)
    bool slotBusy_[kSlots] = {};
    double ctlSr_ = 0;
    int64_t ctlLoopLen_ = 0;

    Chain* buildChain(const std::vector<std::string>& ids, const std::vector<const double*>& wiring, bool voiced,
                      const Chain* prev, const std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>>& automation,
                      size_t expressionCapacity);
    void swapIn(Slot& s, Chain* c) noexcept;  // hot swap with a crossfade, keeping what can keep playing
    void writeParams(Chain& c);
    void writeMix(int slot, double vol, double pan, bool mute, bool solo);
    int freeSlot();
};

}  // namespace caw
