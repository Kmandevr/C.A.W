// Per-note FX (#127 step 4): each note of a layer's instrument through its own chain of effects (a slot) over the voice bus, with deterministic slot choice, an overflow chain, tails, crossfaded swaps and stats.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <string>
#include <vector>

#include "component_chain.h"
#include "modulation_links.h"
#include "module_registry.h"
#include "project.h"
#include "spsc.h"

namespace caw {

// Voices a layer asks for ("noteVoices", B) and the slot chains a rack holds: B for the High cap (min(B, 16) = B)
// plus kNoteFxSpares, so a stolen slot can fade out for 10 ms while the new note starts on a fresh chain.
constexpr int kMaxNoteVoices = 16;
constexpr int kNoteFxSpares = 2;
constexpr int kMaxNoteSlots = kMaxNoteVoices + kNoteFxSpares;
constexpr double kNoteFxFadeSeconds = 0.010;    // a stolen or finished slot's fade
constexpr double kNoteFxMaxTailSeconds = 2.0;   // a slot rings out at most this long after its note ends
// A finished note's slot rings at least this long past its last sound (longer than any block, so the end is never
// learnt after its fade should have started).
constexpr uint32_t kNoteFxMinTail = 128;
constexpr uint32_t kNoteFxMaxEvents = 128;      // one slot's events in one run() stretch (more are dropped)
constexpr uint32_t kNoteFxMaxBindings = 64;     // modulated parameters per slot chain

// The live voice budget for B voices at a quality (quality.h): Eco min(B, 4), Normal B, High min(B, 16).
int noteFxBudget(int voices, int quality) noexcept;
// The slot chains a rack for B voices holds (without the overflow chain).
inline int noteFxSlots(int voices) noexcept {
    const int b = voices < 1 ? 1 : voices > kMaxNoteVoices ? kMaxNoteVoices : voices;
    return b + kNoteFxSpares;
}

// What caw_engine_note_fx_stats reports (CawNoteFxStats). Any thread.
struct NoteFxStats {
    uint32_t voices = 0;       // B, the layer's noteVoices
    uint32_t budget = 0;       // the live cap at the current quality
    uint32_t active = 0;       // slots holding a note (held, released or ringing out)
    uint32_t activeMask = 0;   // bit k: slot k holds a note (the UI's active-voice dots)
    uint32_t overflowing = 0;  // 1 while the overflow chain runs
    uint32_t overflowed = 0;   // notes that went to the overflow chain since the host started
    uint32_t stolen = 0;       // released or ringing slots given to a new note
    uint32_t newestSlot = 0;   // the slot of the newest note (the display reads it)
};

// The chains: noteFxSlots(B) slot chains and one overflow chain, all built and activated on the control thread.
// Their shape never changes; values, bypass and knob moves fan out to every chain.
class NoteFxRack {
public:
    static std::unique_ptr<NoteFxRack> build(const ModuleRegistry& registry, const std::vector<ComponentSpec>& specs,
                                             int voices, double sampleRate, std::string& error);
    bool sameComponents(const std::vector<ComponentSpec>& specs, int voices, double sampleRate) const noexcept;
    int voices() const noexcept { return voices_; }
    int slots() const noexcept { return static_cast<int>(chains_.size()) - 1; }
    ComponentChain& slot(int k) noexcept { return *chains_[static_cast<size_t>(k)]; }
    const ComponentChain& slot(int k) const noexcept { return *chains_[static_cast<size_t>(k)]; }
    ComponentChain& overflow() noexcept { return *chains_.back(); }
    ComponentChain& chain(int k) noexcept { return *chains_[static_cast<size_t>(k)]; }  // 0..slots(): the last is overflow
    int chains() const noexcept { return static_cast<int>(chains_.size()); }
    // Control thread.
    void setValues(const std::vector<ComponentSpec>& specs) noexcept;
    bool setValue(std::size_t index, const std::string& param, double value) noexcept;
    bool setBypass(std::size_t index, bool bypass) noexcept;
    uint64_t latencyFrames() const noexcept { return slot(0).latencyFrames(); }
    // The frames a slot rings on after its note ends: the chain's declared tail, at most 2 s.
    uint32_t tailFrames() const noexcept { return tail_; }
    uint32_t maxParameters() const noexcept { return maxParams_; }
    bool takesEvents() const noexcept { return events_; }
    std::atomic<bool> installed{false};  // set by the audio thread when a host first plays it

private:
    NoteFxRack() = default;
    std::vector<std::unique_ptr<ComponentChain>> chains_;
    int voices_ = 8;
    double sampleRate_ = 0;
    uint32_t tail_ = 0, maxParams_ = 0;
    bool events_ = false;
};

// The note-source links of one layer (modulation_links.h), with their amounts (a ring drag sets them while playing).
struct NoteFxLinks {
    std::vector<NoteLink> links;
    std::unique_ptr<std::atomic<double>[]> amounts;
    struct Group {
        uint32_t entry = 0, param = 0;
        uint32_t first = 0, count = 0;  // its links
    };
    std::vector<Group> groups;  // one per moved parameter
};

class NoteFxManager;

// One layer's per-note FX on the audio thread: the voice bus it hands its instrument, which slot each note plays
// in, the slots' tails and fades, and the rack (and the one it replaced, crossfading out). Made on the control
// thread with every buffer it needs; nothing after that allocates.
class NoteFxHost {
public:
    explicit NoteFxHost(double sampleRate);
    NoteFxHost(const NoteFxHost&) = delete;
    NoteFxHost& operator=(const NoteFxHost&) = delete;

    // ---- audio thread ----
    // Before the instrument's block of m frames: places this block's note-ons in slots (or overflow), and returns
    // the bus to hand the instrument (null: no rack). `events` are the block's events in frame order; `time` the
    // block's transport (null: none); `global` the modulators' links into the per-note components this chunk.
    const VoiceBus* begin(const Event* events, uint32_t count, uint32_t m, const ChainTime* time,
                          const ChainModulation* global, int quality) noexcept;
    // After the instrument's block: reads WRITTEN and ENDED, runs tails and fades, frees slots.
    void end(uint32_t m) noexcept;
    // The instrument was reset (it holds no notes): every slot frees and every chain is cleared.
    void reset() noexcept;
    // A chain that the global modulation's bindings can be resolved against (null: no rack).
    const ComponentChain* modChain() const noexcept { return rack_ ? &rack_->slot(0) : nullptr; }

    // Any thread.
    NoteFxStats stats() const noexcept;
    std::atomic<bool> installed{false};  // set by the audio thread when a plan first plays it

private:
    friend class NoteFxManager;
    enum class Use : uint8_t { Free, Held, Released, Ended, Leaving };
    static constexpr uint64_t kNever = UINT64_MAX;
    // Timing is in the host's own frames (clock_), never in blocks, so where the Engine's chunks fall (the device
    // buffer, an export) never changes the sound.
    struct Slot {
        Use use = Use::Free;
        uint32_t noteId = 0;
        uint64_t order = 0;     // note-on order
        uint64_t endOrder = 0;  // when its note ended
        bool fromReleased = false;  // Leaving: its note still plays, crossfading into the overflow chain
        uint32_t startFrame = 0;    // this block: the frame its note starts (0 for an older one)
        uint64_t fadeAt = kNever;   // the frame its fade out starts (a steal, or its tail's end)
        uint64_t lastSound = 0;     // one past the last frame its note sounded
        uint32_t cursor = 0;        // this block: its next event to look at
        NoteSourceState note;       // what per-note sources read
    };
    static void runThunk(void* host, uint32_t offset, uint32_t frames) noexcept;
    void run(uint32_t offset, uint32_t frames) noexcept;
    void assign(uint32_t noteId, uint32_t frame) noexcept;
    void release(uint32_t noteId) noexcept;
    void leave(Slot& s, uint64_t at, bool fromReleased) noexcept;
    float fadeWeight(uint64_t fadeAt, uint64_t t) const noexcept;
    bool expired(uint64_t fadeAt, uint64_t t) const noexcept {
        return fadeAt != kNever && t >= fadeAt + static_cast<uint64_t>(fadeLen_);
    }
    uint64_t restFadeAt() const noexcept { return restLastSound_ + tailMin(); }
    uint64_t tailMin() const noexcept;  // a slot's tail, at least kNoteFxMinTail frames
    void freeSlot(int k) noexcept;
    // The slot's events up to `end` (exclusive): expression into s.note, its events (rebased to `from`) out.
    // A note-on there sets its age to 0 at frame `ageAt`'s reckoning (the frame the caller counts age from).
    void walk(Slot& s, uint32_t from, uint32_t end, uint32_t& count, uint32_t ageAt) noexcept;
    const ChainModulation* slotModulation(Slot* s, uint32_t from, uint32_t len) noexcept;
    void process(int k, float* l, float* r, uint32_t from, uint32_t len, const ChainModulation* mod) noexcept;
    // Audio thread, from the manager: a new rack (crossfading in) and links.
    bool swapRack(NoteFxRack* next) noexcept;
    float swapWeight(uint32_t frame) const noexcept;

    double sr_;
    int fadeLen_ = 480;
    NoteFxRack* rack_ = nullptr;
    NoteFxRack* fading_ = nullptr;  // the rack rack_ replaced, crossfading out over swapLen_
    int swapLeft_ = 0, swapLen_ = 960;
    const NoteFxLinks* links_ = nullptr;
    Spsc<void*, 1024>* retire_ = nullptr;  // racks handed back (the manager's)
    Slot slots_[kMaxNoteSlots];
    VoiceLane lanes_[kMaxNoteSlots + 1];  // a lane per slot, then the overflow lane (kLaneRest)
    VoiceBus bus_;
    std::unique_ptr<float[]> buffers_;    // every lane's two channels, then two scratch pairs
    float* scratchL_ = nullptr;
    float* scratchR_ = nullptr;
    float* dryL_ = nullptr;
    float* dryR_ = nullptr;
    // This block.
    const Event* events_ = nullptr;
    uint32_t eventCount_ = 0, m_ = 0, covered_ = 0;
    ChainTime time_;
    bool hasTime_ = false;
    int budget_ = 0;
    uint32_t restFrom_ = 0;
    bool restOn_ = false;     // the overflow lane is assigned this block
    bool restLive_ = false;   // the overflow chain is running (its notes or its tail)
    bool startup_ = true;     // the first block: held notes it never saw start play in the overflow lane
    uint64_t restLastSound_ = 0;  // one past the last frame the overflow lane's input sounded
    uint64_t clock_ = 0;          // the host's frames before this block
    uint64_t order_ = 0, endOrder_ = 0;
    // Modulation scratch (slots run one at a time, so they share it).
    ChainModulation::Binding global_[kNoteFxMaxBindings];
    uint32_t globalCount_ = 0;
    ChainModulation::Binding bindings_[kNoteFxMaxBindings];
    ChainModulation mod_;
    std::vector<ParameterValue> values_;
    std::vector<double> samples_;
    std::unique_ptr<float[]> offsets_;  // kNoteFxMaxBindings x ComponentChain::kMaxFrames
    int groupGlobal_[kMaxNoteLinks] = {};  // each link group's global binding, or -1
    Event slotEvents_[kNoteFxMaxEvents];
    uint32_t eventsThisCall_ = 0;
    // Stats.
    std::atomic<uint32_t> statBudget_{0}, statActive_{0}, statMask_{0}, statOverflowing_{0}, statOverflowed_{0},
        statStolen_{0}, statNewest_{0}, statVoices_{0};
};

// Every layer's per-note FX: built on the control thread, handed to the audio thread lock-free as a plan (which
// host plays on which slot, with which rack and links), retired back here to be freed. The Engine holds one.
class NoteFxManager {
public:
    NoteFxManager();
    ~NoteFxManager();
    NoteFxManager(const NoteFxManager&) = delete;
    NoteFxManager& operator=(const NoteFxManager&) = delete;

    // ---- control thread ----
    // Builds the racks the project needs, before anything is sent: a layer's per-note FX need a native instrument
    // that declares the per-note domain (a voice bus), and every component must run per note; "" or the error
    // that refuses the project. Unchanged racks are kept (and take the new values at commit).
    std::string prepare(const ModuleRegistry& registry, const ProjectSpec& p, double sampleRate);
    // Instances the project's per-note FX run (for the Engine's component cap) and their memory estimate.
    static size_t instances(const ProjectSpec& p);
    // After prepare: sends the plan (each layer's slot from `slotOf`, -1 not playing; automation `lanes`).
    void commit(const ProjectSpec& p, const std::function<int(const std::string&)>& slotOf,
                const std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>>& lanes,
                std::vector<std::string>& warnings);
    void drain() noexcept;
    // A per-note component's knob (fans out to every slot), bypass, display (the newest note's slot).
    bool setParam(const std::string& layer, uint32_t index, const std::string& param, double value);
    bool setBypass(const std::string& layer, uint32_t index, bool bypass);
    int32_t readDisplay(const std::string& layer, uint32_t index, float* out, uint32_t max) const;
    bool setLinkAmount(uint32_t linkId, double amount);
    uint64_t latencyFrames(const std::string& layer) const noexcept;
    const ComponentChain* chainFor(const std::string& layer) const noexcept;
    bool stats(const std::string& layer, NoteFxStats& out) const;

    // ---- audio thread ----
    // At each chunk: takes a new plan (racks crossfade in; hosts no longer used go back).
    void beginChunk() noexcept;
    // The host playing on `slot`, or null.
    NoteFxHost* forSlot(int slot) noexcept;

private:
    struct Plan;
    struct Layer {
        NoteFxRack* rack = nullptr;
        NoteFxHost* host = nullptr;
        std::string automationKey;
    };
    void free(void* p) noexcept;
    void reclaim(Plan* untaken) noexcept;  // a plan the audio thread never took
    std::map<std::string, Layer> layers_;            // control thread: what each layer last sent
    std::map<std::string, NoteFxRack*> pending_;     // prepare's racks, not sent yet
    std::set<NoteFxRack*> racks_;                    // every rack alive (freed when handed back)
    std::set<NoteFxHost*> hosts_;
    Plan* ctl_ = nullptr;                            // the newest plan sent
    std::atomic<Plan*> next_{nullptr};
    Plan* cur_ = nullptr;                            // audio thread
    Plan* waiting_ = nullptr;                        // audio thread: a plan held back while the queue was full
    std::unique_ptr<Spsc<void*, 1024>> retire_;       // racks, hosts and plans handed back (tagged pointers)
    std::set<Plan*> plans_;                          // every plan alive
    double sr_ = 48000.0;
};

}  // namespace caw
