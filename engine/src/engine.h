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

#include "component_chain.h"
#include "execution.h"
#include "module_registry.h"
#include "pattern.h"
#include "program.h"
#include "project.h"
#include "spsc.h"
#include "vm.h"

namespace caw {

constexpr int kScopeSize = 1024;
constexpr int kMaxVoices = 32;  // most notes a pattern layer plays at once (a module asks for 1..32 with voices:)
// Modules one track runs (its generator or voice, then effects); each is its own mix-graph node.
// A longer chain is refused with a layer error, never truncated.
constexpr int kMaxTrackModules = 32;
// Layer slots a new Engine starts with. It grows past them (setProject) up to maxLayers(), which
// its memory budget sets; this many are always available.
constexpr int kInitialLayerCapacity = 64;
// The export-buffer budget is a share sized for this many slots (the initial layers plus the audition).
constexpr int kExportBudgetSlots = kInitialLayerCapacity + 1;

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

// scope() ids beside project layer indices: the master output and the Builder's audition, whose slot moves when
// the Engine grows (F7.3), so hosts address it by this id instead of a slot number.
constexpr int kScopeMaster = -1;
constexpr int kScopeAudition = -2;

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
    // Layer slots the engine holds: kInitialLayerCapacity at first, growing (never shrinking) when
    // a project needs more. The Builder's audition is the slot after them, so auditionSlot() ==
    // layerCapacity() and moves when the Engine grows; scope() takes kScopeAudition for it, never this index.
    int layerCapacity() const noexcept { return ctlCapacity_.load(std::memory_order_relaxed); }
    int auditionSlot() const noexcept { return layerCapacity(); }
    // The most layer slots this Engine's graph-working budget allows (at least kInitialLayerCapacity):
    // a project with more layers is refused by setProject.
    int maxLayers() const noexcept { return maxLayers_; }
    // Export buffers one layer may hold, and how many the whole project may allocate (a 65-slot share
    // of the graph-working budget, so growing past 64 layers spreads it rather than multiplying it).
    size_t exportBuffersPerLayer() const noexcept { return exportPerSlot_; }
    size_t exportBufferBudget() const noexcept { return exportPerSlot_ * static_cast<size_t>(kExportBudgetSlots); }

    // Control thread. Each returns quickly; compiling happens here, never on the audio thread.
    std::string setProject(const ProjectSpec& p);  // live: commands are applied by the audio callback
    // Offline render only: call while no audio callback can run; project commands are applied synchronously.
    std::string setProjectOffline(const ProjectSpec& p);
    std::string setProjectJson(std::string_view json);
    // Native components are loaded only after an explicit per-component trust decision.
    ModuleLoadResult loadNativeComponent(const std::string& path, const std::string& expectedId, NativeModuleTrust trust);
    bool unloadNativeComponent(const std::string& id);
    // A rebuild of a loaded component (a new file): it replaces the old build, and every chain that
    // uses it is rebuilt with the new one, crossfaded, keeping each instance's values, bypass and
    // (when the new build accepts it) state. On failure the old build keeps playing.
    ModuleLoadResult reloadNativeComponent(const std::string& path, const std::string& expectedId, NativeModuleTrust trust);
    std::unique_ptr<ModuleProcessor> createNativeComponent(const std::string& id);
    // {"ok":true,"components":[descriptor, ...]} for the loaded native components (moduleDescriptorJson).
    std::string nativeComponentsJson();
    void setParam(const std::string& moduleId, const std::string& name, double value);
    void setGlobal(const std::string& name, double value);
    // A native component's parameter while it plays: component `index` of the layer's inserts (an
    // empty layer id: the master chain). Ramps over the parameter's smoothing. False if there is no
    // such component or parameter. A later project update sets the values it names again.
    bool setComponentParam(const std::string& layerId, uint32_t index, const std::string& param, double value);
    // Bypasses (or brings back) a playing native component, crossfaded. False if there is none.
    bool setComponentBypass(const std::string& layerId, uint32_t index, bool bypass);
    // {"ok":true,"components":[{"index","ok","version","state"(base64)}]} for a layer's chain (empty
    // id: the master's), as each component's save_state writes it now; store it in the project so a
    // reload or an export starts from it. {"ok":false,...} if the layer has no chain.
    std::string componentStatesJson(const std::string& layerId);
    void setLayerMix(const std::string& layerId, double volume, double pan, bool mute, bool solo);
    // Note previews (#103): a held note on a layer's instrument, heard through its effects and mix, while playing or
    // stopped. [id] is the caller's handle: a second noteOn with it ends the first. Only layers that play a pattern
    // (a voiced chain) can preview.
    void noteOn(const std::string& layerId, int32_t id, double pitch, double velocity);
    void notePitch(int32_t id, double pitch);  // glides a held preview to [pitch] without a new attack
    void noteOff(int32_t id);
    void notesOff();
    void setMaster(double volume);
    void play(double fromStep = 0);  // fromStep: sixteenth steps into the project loop (out of range starts at 0)
    void stop();
    void clearOverload();
    Meters meters();
    bool layerMeter(int index, LayerMeter& out);
    int scope(int index, float* out, int n);  // a project layer index, kScopeMaster or kScopeAudition
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
    struct SlotTable;  // the slots, their mix graph and order list at one capacity (engine.cpp)
    struct DelayLine;  // a track's latency-compensation delay (engine.cpp)

    void drainRetired();
    bool canRetire(size_t count) const noexcept;
    bool send(const Cmd& c);
    std::string setProjectImpl(const ProjectSpec& p, bool offline);
    void applyCommands() noexcept;
    void retire(Chain* c, Slot* freed, std::shared_ptr<const Pattern>* pattern = nullptr,
                AutomationData* automation = nullptr, std::vector<int>* order = nullptr,
                SlotTable* table = nullptr, ComponentChain* components = nullptr) noexcept;
    void retireEntry(const Retired& r) noexcept;  // audio thread: to the control thread, to be freed
    void bindTable() noexcept;  // audio thread: cache the current table's slots, graph and sizes
    int processChunk(float* l, float* r, int maxFrames) noexcept;  // returns the frames it ran
    int planChunk(int maxFrames) noexcept;
    void planTrack(Slot& s, int& m) noexcept;
    // Graph nodes (audio thread): each module of a track, the track's crossfades and mix, a
    // folder bus, and the master stage.
    void runModuleNode(int slot, int index, const float* const* in, float* const* out, int m) noexcept;
    void runTrackNode(int slot, const float* const* in, float* outL, float* outR, int m) noexcept;
    void runDelay(Slot& s, float* outL, float* outR, int m) noexcept;
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
    struct Voice& pickVoice(Chain& c) noexcept;
    void previewCommand(const Cmd& c) noexcept;
    void updatePreviewing(int frames) noexcept;
    void endPlayback() noexcept;
    static void restartChain(Chain& c) noexcept;
    void takeExpression(struct Voice& v, const Pattern& pat, const PatternNote& n) noexcept;
    int64_t loopStart(const Slot& s, int64_t k) const noexcept;
    void updateTiming() noexcept;
    void pickOverloadVictim() noexcept;

    const double sr_;
    const EngineResourceBudget resourceBudget_;
    // Export buffers each slot may hold: fixed at construction from the budget (as the first export
    // pool sized it at 64 layers), so every slot added by a grow gets the same.
    const size_t exportPerSlot_;
    int maxLayers_ = kInitialLayerCapacity;  // set once in the constructor
    int pendingMax_ = 0;                     // pending_ entries; set once in the constructor
    std::unique_ptr<ExportPool> exportPool_;

    // ---- audio-thread state ----
    // The current slot table (owned; a Grow command swaps in a larger one and retires this one).
    // Slots are individually allocated and never move; a layer slot keeps its index for the life
    // of the Engine, and the audition (always the last slot) is re-indexed by the swap.
    std::unique_ptr<SlotTable> table_;
    Slot** slots_ = nullptr;      // table_'s slots
    MixGraph* mixGraph_ = nullptr;  // table_'s graph, routed on the audio thread
    int* processOrder_ = nullptr;   // table_'s order list: slots in dependency order (exporters before readers)
    int capacity_ = 0;      // layer slots; the audition slot follows them
    int auditionSlot_ = 0;  // == capacity_
    int slotCount_ = 0;     // capacity_ + 1 (layers and the audition)
    Slot& slotAt(int i) noexcept { return *slots_[i]; }
    const Slot& slotAt(int i) const noexcept { return *slots_[i]; }
    bool playing_ = false;
    bool previewing_ = false;     // some slot holds a preview voice (still sounding or releasing)
    bool previewChunk_ = false;   // this chunk runs only the previewing slots, with the transport stopped
    bool stopEnded_ = false;      // the stop fade reached silence this callback (endPlayback runs after the chunk)
    int previewRampIn_ = 0;       // samples left of the master's fade back in for previews after a stop
    int stopFade_ = 0;  // samples left in the stop fade, 0 when not stopping
    int playRampIn_ = 0;  // samples left of the fade in after a Play mid-loop or during a stop fade (no click)
    int64_t g_ = 0;     // position in the project loop
    int64_t epoch_ = 0; // project loops completed since play
    uint64_t touchEpoch_ = 0;  // the play count of the last Play handled (audio thread); ends touches
    uint32_t touchPlayStamp_ = 0;  // the last knob move's stamp before that Play (audio thread)
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
    int processCount_ = 0;
    int64_t chunkId_ = 0;
    bool routingDirty_ = true;  // re-derive graph routing before the next chunk
    // Retirements waiting for room in the queue (pendingMax_ entries, enough for a Play at
    // maxLayers(); owned, so a throwing constructor cannot leak it).
    std::unique_ptr<Retired[]> pending_;
    int pendingCount_ = 0;
    double tmp_[kBlock];
    int64_t masterTailLeft_ = 0;  // audio thread: stopped, the master chain rings out for at most this long
    int64_t masterQuiet_ = 0;     // ... ending sooner once its output has been quiet for a moment
    ComponentChain* masterFading_ = nullptr;  // audio thread: the master chain a newer one replaced, crossfading out
    int masterFadeLeft_ = 0;
    float insertL_[kBlock], insertR_[kBlock];
    float fadeL_[kBlock], fadeR_[kBlock];  // audio thread: a replaced chain's output during its crossfade            // audio thread: a track's inserts run here
    float masterStageL_[kBlock], masterStageR_[kBlock];  // audio thread: the master chain runs here

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
    ModuleRegistry nativeModules_;  // control-thread registry; loaded processors keep their library alive
    ComponentChain* masterChain_ = nullptr;  // audio-thread-owned; replaced/retired through commands
    // Control thread: the master chain last sent (alive until a later command replaces it), so an
    // update with the same components keeps it and only sets values.
    ComponentChain* ctlMasterChain_ = nullptr;
    std::string ctlMasterAutomationKey_;
    std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>> ctlAutomation_;  // the last project's lanes  // the lanes the master chain's automation table was made from
    bool offlineControl_ = false;  // control thread only; true only when no audio callback can run
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
        ComponentChain* inserts = nullptr;  // the native effects last sent to the slot (alive while it plays)
        std::string insertsAutomationKey;   // the lanes their automation table was made from
        int64_t compensation = 0;           // the latency-compensation delay last sent, in frames
    };
    std::map<std::string, ModuleState> modules_;
    std::map<std::string, LayerState> layers_;
    std::map<int32_t, int> previewSlots_;  // control thread: each held preview's slot, for its pitch and off
    std::vector<std::string> order_;  // layer ids in project order, for meters
    std::map<std::string, double> globals_;
    // Knob moves since the last Play (control thread), so a rebuilt chain keeps their touches.
    std::set<std::pair<std::string, std::string>> touchedParams_;  // (module id, param)
    std::set<std::string> touchedGlobals_;
    uint64_t playCount_ = 0;     // Play commands sent (control thread)
    uint32_t touchCounter_ = 0;  // knob moves (control thread); wraps, compared by difference
    // Every slot ever made (the audio thread's tables point into it); it only grows.
    std::vector<std::unique_ptr<Slot>> slotStore_;
    SlotTable* ctlTable_ = nullptr;  // the newest table sent (alive until a newer one replaces it)
    std::atomic<int> ctlCapacity_{0};  // ctlTable_'s layer capacity, for layerCapacity()
    Slot& ctlSlot(int i) noexcept;
    std::string grow(int capacity);  // a larger slot table, sent to the audio thread; "" or an error
    double ctlSr_ = 0;
    int64_t ctlLoopLen_ = 0;

    Chain* buildChain(const std::vector<std::string>& ids, const std::vector<const double*>& wiring, bool voiced,
                      const Chain* prev, const std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>>& automation,
                      size_t expressionCapacity);
    void swapIn(Slot& s, Chain* c) noexcept;  // hot swap with a crossfade, keeping what can keep playing
    void writeParams(Chain& c);
    void writeMix(int slot, double vol, double pan, bool mute, bool solo);
    int freeSlot();
    ComponentChain* ctlComponentChain(const std::string& layerId) noexcept;  // control thread; null: none
    bool updateCompensation(std::map<std::string, std::vector<std::string>>& warnings);
};

}  // namespace caw
