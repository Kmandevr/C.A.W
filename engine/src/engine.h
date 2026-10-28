// The mixer and its control side: layers with their own loop lengths, hot-swap crossfades, mute/solo, limiter and meters.
#pragma once

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "pattern.h"
#include "program.h"
#include "project.h"
#include "spsc.h"
#include "vm.h"

namespace caw {

constexpr int kSlots = kMaxLayers + 1;  // the last slot is the Builder's audition
constexpr int kAuditionSlot = kMaxLayers;
constexpr int kScopeSize = 1024;
constexpr int kVoices = 8;  // notes a pattern layer plays at once; the oldest is stolen when all are busy

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
    explicit Engine(double sampleRate);
    ~Engine();
    Engine(const Engine&) = delete;
    Engine& operator=(const Engine&) = delete;

    double sampleRate() const { return sr_; }

    // Control thread. Each returns quickly; compiling happens here, never on the audio thread.
    std::string setProject(const ProjectSpec& p);  // result JSON: per-module ok/error and params
    std::string setProjectJson(std::string_view json);
    void setParam(const std::string& moduleId, const std::string& name, double value);
    void setGlobal(const std::string& name, double value);
    void setLayerMix(const std::string& layerId, double volume, double pan, bool mute, bool solo);
    void play();
    void stop();
    void clearOverload();
    Meters meters();
    bool layerMeter(int index, LayerMeter& out);
    int scope(int index, float* out, int n);  // index -1 is the master output
    int64_t loopLength();                     // samples in the project loop
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

    void drainRetired();
    void send(const Cmd& c);
    void applyCommands() noexcept;
    void retire(Chain* c, int freedSlot, std::shared_ptr<const Pattern>* pattern = nullptr) noexcept;
    void processChunk(float* l, float* r, int m) noexcept;
    void processSlot(Slot& s, int m, double target) noexcept;
    double slotTarget(const Slot& s) const noexcept;
    void runChain(Chain& c, bool shadow, int64_t n0, int len, double* out, Slot* exportTo, int offset,
                  const Pattern* pat, int64_t repeat) noexcept;
    void runVoices(Chain& c, const Pattern* pat, int64_t repeat, int64_t n0, int len, double* out, Slot* exportTo,
                   int offset, const BlockCtx& base) noexcept;
    void noteEvent(Chain& c, const Pattern& pat, const PatternEvent& e, int64_t repeat) noexcept;
    int64_t loopStart(const Slot& s, int64_t k) const noexcept;
    void updateTiming() noexcept;
    void pickOverloadVictim() noexcept;

    const double sr_;

    // ---- audio-thread state ----
    std::unique_ptr<Slot[]> slots_;
    bool playing_ = false;
    int stopFade_ = 0;  // samples left in the stop fade, 0 when not stopping
    int64_t g_ = 0;     // position in the project loop
    int64_t epoch_ = 0; // project loops completed since play
    double bpm_ = 120.0;
    int beatsPerBar_ = 4;
    int loopSteps_ = 64;
    uint32_t seed_ = 0;
    double master_ = 0.7;
    bool seamXf_ = true;
    int keyRoot_ = 9, keyScale_ = 1;
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
    Retired* pending_ = nullptr;  // retired chains waiting for room in the queue
    int pendingCount_ = 0;
    double mixL_[kBlock], mixR_[kBlock], tmp_[kBlock], tmp2_[kBlock];

    // ---- shared ----
    std::unique_ptr<Spsc<Cmd, 1024>> cmds_;
    std::unique_ptr<Spsc<Retired, 1024>> retired_;
    std::atomic<float> cpu_{0}, peakL_{0}, peakR_{0};
    std::atomic<bool> playingFlag_{false};
    std::atomic<bool> bypass_{false};
    std::atomic<int64_t> posFlag_{0}, loopLenFlag_{0};
    std::atomic<int> overloadedFlag_{0};
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
    };
    struct LayerState {
        int slot = -1;
        Chain* chain = nullptr;
        std::vector<const Program*> sig;
        std::vector<const double*> wiring;  // where each import of the chain reads from
        int steps = -1;
        bool voiced = false;                     // plays a pattern through a pool of voices
        std::shared_ptr<const Pattern> pattern;  // what the audio thread was last sent
        double volume = -1, pan = 0;
        bool mute = false, solo = false;
    };
    std::map<std::string, ModuleState> modules_;
    std::map<std::string, LayerState> layers_;
    std::vector<std::string> order_;  // layer ids in project order, for meters
    std::map<std::string, double> globals_;
    bool slotBusy_[kSlots] = {};
    double ctlSr_ = 0;
    int64_t ctlLoopLen_ = 0;

    Chain* buildChain(const std::vector<std::string>& ids, const std::vector<const double*>& wiring, bool voiced);
    void writeParams(Chain& c);
    void writeMix(int slot, double vol, double pan, bool mute, bool solo);
    int freeSlot();
};

}  // namespace caw
