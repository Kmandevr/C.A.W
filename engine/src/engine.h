// The mixer and its control side: tracks (an instrument and its inserts) with their own loop lengths, crossfaded
// chain changes, folder buses, sends, mute/solo, limiter and meters.
#pragma once

#include <atomic>
#include <cstdint>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <vector>

#include "audio_input.h"
#include "component_chain.h"
#include "midi_device.h"
#include "modulation_links.h"
#include "note_fx_host.h"
#include "execution.h"
#include "meters.h"
#include "module_registry.h"
#include "pattern.h"
#include "project.h"
#include "spsc.h"

namespace caw {

class MixPool;  // mix_pool.h

constexpr int kBlock = 64;  // frames the mixer runs at most at once (a chunk); component chains run in these blocks
constexpr int kScopeSize = 1024;
// Layer slots a new Engine starts with. It grows past them (setProject) up to maxLayers(), which
// its memory budget sets; this many are always available.
constexpr int kInitialLayerCapacity = 64;

struct Meters {
    float cpu = 0, peakL = 0, peakR = 0;
    bool playing = false;
    int64_t position = 0, loopLength = 0;
    int overloaded = 0;  // layers muted because the device ran out of time
};

struct LayerMeter {
    float peak = 0, progress = 0;  // peak: the louder side's
    float peakL = 0, peakR = 0;
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
    // Audio input (caw.h API 18): monitoring, recording and the latency ping.
    LiveAudio& liveAudio() noexcept { return *audioIn_; }
    const EngineResourceBudget& resourceBudget() const noexcept { return resourceBudget_; }
    // Layer slots the engine holds: kInitialLayerCapacity at first, growing (never shrinking) when
    // a project needs more. The Builder's audition is the slot after them, so auditionSlot() ==
    // layerCapacity() and moves when the Engine grows; scope() takes kScopeAudition for it, never this index.
    int layerCapacity() const noexcept { return ctlCapacity_.load(std::memory_order_relaxed); }
    int auditionSlot() const noexcept { return layerCapacity(); }
    // The most layer slots this Engine's graph-working budget allows (at least kInitialLayerCapacity):
    // a project with more layers is refused by setProject.
    int maxLayers() const noexcept { return maxLayers_; }

    // Control thread. Each returns quickly; patterns parse and chains are built here, never on the audio thread.
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
    // Component index that names a layer's native instrument instead of one of its inserts.
    static constexpr uint32_t kInstrumentIndex = 0xFFFFFFFFu;
    // A component index with this bit names component (index & ~kNoteComponentFlag) of the layer's per-note FX
    // (#127): knob moves and bypass fan out to every slot, the display reads the newest note's slot.
    static constexpr uint32_t kNoteComponentFlag = 0x40000000u;
    // Per-note FX (#127): the layer's voice budget, active slots and overflow (any thread; false: none there).
    bool noteFxStats(const std::string& layerId, NoteFxStats& out);
    // Play after Stop: an instrument still ringing fades out over its next 5 ms, rendered at Play (inside one
    // callback). All the ringing instruments share this many frames of that work, so Play never costs more than
    // two 5 ms tails at 48 kHz: one or two fade over 5 ms, more over less each (16: 0.6 ms).
    static constexpr int kPlayTailBudgetFrames = 480;
    // A native component's parameter while it plays: component `index` of the layer's inserts (an
    // empty layer id: the master chain; kInstrumentIndex: the layer's instrument). Ramps over the parameter's smoothing. False if there is no
    // such component or parameter. A later project update sets the values it names again.
    bool setComponentParam(const std::string& layerId, uint32_t index, const std::string& param, double value);
    // Project modulation (#161, modulation_links.h; API 19): a running modulator's knob or bypass, a link's amount
    // while it plays, and what the audio thread last published (a modulator's outputs, 0..1; a link's target's summed
    // offset in normalized travel). The readers never wait: 0 (outputs) or false while a project update runs.
    bool setModulatorParam(const std::string& modulatorId, const std::string& param, double value);
    bool setModulatorBypass(const std::string& modulatorId, bool bypass);
    bool setModulationAmount(uint32_t linkId, double amount);
    int32_t modulatorOutputs(const std::string& modulatorId, float* out, int32_t max);
    bool modulationOffset(uint32_t linkId, float& out);
    // Bypasses (or brings back) a playing native component, crossfaded. False if there is none.
    bool setComponentBypass(const std::string& layerId, uint32_t index, bool bypass);
    // {"ok":true,"components":[{"index","ok","version","state"(base64)}]} for a layer's chain (empty
    // id: the master's; its instrument has index kInstrumentIndex), as each component's save_state writes it now; store it in the project so a
    // reload or an export starts from it. {"ok":false,...} if the layer has no chain.
    std::string componentStatesJson(const std::string& layerId);
    // Gives a playing native component a new saved state (API version 14): the convolver's WAV impulse, a preset's
    // state. The component's chain is rebuilt here, on the control thread, with every component's current values
    // and state and this one's replaced, then crossfaded in as a project update would. False (nothing changes) when
    // there is no such component or it refuses the state.
    bool setComponentState(const std::string& layerId, uint32_t index, const uint8_t* data, size_t size, uint32_t version);
    // Live display data (#173): the latest block a playing component published (ModuleProcessor::readDisplay),
    // at most `max` floats into out; the count, 0 when it has none (or the control thread is busy: it never
    // waits), -1 when there is no such component. Any thread but the audio thread.
    int32_t componentDisplay(const std::string& layerId, uint32_t index, float* out, uint32_t max);
    void setLayerMix(const std::string& layerId, double volume, double pan, bool mute, bool solo);
    // A send while it plays (send `index` of the layer's project "sends"): its level (linear, 0..+12 dB), pre- or
    // post-fader and mute, ramped over a block. False if the layer has no such send. A later project update sets
    // the values it names again.
    bool setSend(const std::string& layerId, uint32_t index, double level, bool pre, bool mute);
    // Most routes (sends and sidechain keys) one layer feeds.
    static constexpr int kMaxRoutes = 24;
    // Note previews (#103): a held note on a layer's instrument, heard through its effects and mix, while playing or
    // stopped. [id] is the caller's handle: a second noteOn with it ends the first. Only tracks (layers with an
    // instrument) can preview.
    void noteOn(const std::string& layerId, int32_t id, double pitch, double velocity);
    void notePitch(int32_t id, double pitch);  // glides a held preview to [pitch] without a new attack
    void noteOff(int32_t id);
    void notesOff();
    // MIDI from devices (caw.h, API 15): messages for [layerId]'s instrument, queued for the audio thread, which
    // plays each at its frame from its time on the MIDI clock (midiClockNs; 0 means now). UMP words (MIDI 1.0
    // Channel Voice ones upscaled to MIDI 2.0) or MIDI 1.0 bytes. Returns the messages queued; a full queue drops
    // the rest (counted in midiDropped). Any thread but the audio thread.
    int midiUmp(const std::string& layerId, const uint32_t* words, int count, int64_t timeNs);
    int midiBytes(const std::string& layerId, const uint8_t* bytes, int count, int64_t timeNs);
    // Ends every device note on [layerId] (empty: every layer), at the next callback.
    void midiRelease(const std::string& layerId);
    void setMidiOptions(bool mpe, double bendRange, double noteBendRange, double delayMs) noexcept;
    uint64_t midiDropped() const noexcept;
    static int64_t midiClockNs() noexcept;
    // The transport's position in samples (into the project loop, not wrapped) the audio thread renders at [timeNs]
    // on the MIDI clock, from the last callback's start; -1 while not playing or before a callback.
    int64_t positionAt(int64_t timeNs) const noexcept;
    // Tests only: the MIDI clock the audio thread reads (-1: the real one).
    void setMidiClockForTest(int64_t ns) noexcept { midiClockTest_.store(ns, std::memory_order_relaxed); }
    void setMaster(double volume);
    void play(double fromStep = 0);  // fromStep: sixteenth steps into the project loop (out of range starts at 0)
    // Count-in: clicks [beats] beats at the tempo (previews still play), then plays from [fromStep] on the
    // sample after the last beat. 0 beats is play().
    void playCountIn(double fromStep, int beats);
    // The metronome: a short built-in click on every beat while playing (accented on the bar), mixed before the
    // safety limiter. Off by default; renders and exports never click.
    void setMetronome(bool on);
    // The click's volume (0..1) and sound (caw.h CAW_CLICK_*), read by the audio thread at each click.
    void setMetronomeSound(double volume, int sound) noexcept;
    // A test tone: [seconds] (0..10) of a 440 Hz sine at -12 dBFS, playing or not, added after the master's gain
    // and transport fades and before the safety limiter; 0 ends it.
    void testTone(double seconds) noexcept;
    // Whether a tone is asked for or still plays: a request the audio thread has not taken yet, or the state it
    // published at its last callback (so a request ended before any callback, or too short to be a sample, is not).
    bool testToneSounding() const noexcept {
        return toneRequest_.load(std::memory_order_acquire) > 0 || toneActive_.load(std::memory_order_acquire);
    }
    // Drops any request and the tone in progress. Only while no process() runs (the device is closed).
    void resetTestTone() noexcept;
    // Sound quality (caw.h CAW_QUALITY_*): the built-ins read it while they play (quality.h). Normal by default.
    void setQuality(int quality) noexcept;
    int quality() const noexcept { return quality_.load(std::memory_order_relaxed); }
    // Ends every knob touch now, as a Play does, so the lanes rule again (an automation Touch write released).
    void releaseTouches();
    void stop();
    void clearOverload();
    Meters meters();
    bool layerMeter(int index, LayerMeter& out);
    // The master's loudness (BS.1770-5 / EBU Tech 3341: momentary, short-term, integrated since the last Play or
    // reset) and true peak, after the safety limiter (meters.h). Not the audio thread.
    LoudnessMeter::Reading loudness();
    void resetLoudness();
    // Stereo correlation (-1..1, 0 while silent) of the master, or of a project layer (track or folder bus, what
    // it sends on). False for an index that is not a project layer.
    float masterCorrelation() const noexcept { return masterCorrelation_.read(); }
    bool layerCorrelation(int index, float& out);
    int scope(int index, float* out, int n);  // a project layer index, kScopeMaster or kScopeAudition
    // Offline renders only (stems, render_stems.cpp), while no process() runs: from the next process() on, the output
    // of project layer `layerId` (a track or a folder bus: what it sends to its parent bus or the master, after its
    // effects, volume, pan and latency compensation, as it meets the others) is also copied into left and right at
    // the frames it plays in each process() call. The buffers must hold as many frames as every later call; frames
    // the layer doesn't play are left as they are (the caller clears them). False if the layer has no slot.
    bool setOutputTap(const std::string& layerId, float* left, float* right);
    void clearOutputTaps();
    int64_t loopLength();                     // samples in the project loop
    // Mix-graph routing updates the graph refused; always 0 unless the routing derivation is wrong.
    uint32_t routingRejections() const noexcept { return routingRejections_.load(std::memory_order_relaxed); }
    // Tests only, between process() calls: graph nodes the last chunk ran.
    uint32_t mixGraphNodesRun() const noexcept;
    // Tests only, between process() calls: slots the per-chunk loops (planning, solo, routing) visit.
    int slotsScannedPerChunk() const noexcept;
    // Tests only: the track gain glide's per-sample factor (set when the Engine is made, speed phase 5a).
    double trackGainCoefForTest() const noexcept { return trackGainCoef_; }
    // Tests only, between process() calls: run the mix graph in its plain order instead of level by level (speed
    // phase 5b), from the next routing update on; the output must be the same bits.
    void setMixLevelsForTest(bool on) noexcept;
    // Tests only, between process() calls: the mix graph's levels at the last routing update (0: not routed).
    uint32_t mixGraphLevelsForTest() const noexcept;
    // Tests only: skip the master DC blocker and limiter so layer output can be checked exactly.
    void setMasterBypass(bool on) { bypass_.store(on, std::memory_order_relaxed); }

    // The mix graph's worker pool (speed phase 5c, mix_pool.h): independent nodes of a graph level (tracks, folder
    // buses) run on several threads, the output the same bits as on one. Control thread, only while no process()
    // runs (before a device starts, after it stops, or with no device): start `workers` threads (at most
    // MixPool::kMaxWorkers; 0 makes a pool that runs everything on the callback thread), or stop them. False if the
    // threads could not be made (then it runs serially).
    bool startMixPool(uint32_t workers);
    bool startMixPool(uint32_t workers, bool live);  // live: workers tuned to the device's callback (thread_tuning.h)
    void stopMixPool() noexcept;
    uint32_t mixWorkers() const noexcept;
    // When the pool is used: Auto (the default) once the callbacks' measured load (reportLoad) has stayed above
    // kMixParallelLoad for kMixParallelSeconds, back to one thread once the load less the time the callback spent
    // waiting for workers stays below kMixSerialLoad for kMixSerialSeconds; Always; or Never. Any thread; read at
    // each callback. Auto also sizes the pool from that wait (speed phase 5d): while the callback waits more than
    // kMixWaitShare of the budget and longer than the workers ran tasks (the pool costs more than it gives) for
    // kMixWaitSeconds, one worker fewer takes tasks; at none, one thread, not tried again for kMixRetrySeconds;
    // while the wait stays under kMixWaitShare / 4 for kMixGrowSeconds, one more.
    enum class MixParallel : int { Auto = 0, Always = 1, Never = 2 };
    void setMixParallel(MixParallel mode) noexcept { mixMode_.store(static_cast<int>(mode), std::memory_order_relaxed); }
    static constexpr double kMixParallelLoad = 0.4, kMixParallelSeconds = 0.5;
    static constexpr double kMixSerialLoad = 0.08, kMixSerialSeconds = 5.0;
    static constexpr double kMixWaitShare = 0.1, kMixWaitSeconds = 0.5, kMixGrowSeconds = 2.0, kMixRetrySeconds = 10.0;
    // Auto's workers now (tests, diagnostics): those taking tasks, at most mixWorkers().
    uint32_t mixActiveWorkers() const noexcept;
    // Audio thread diagnostics (speed phase 5d) as JSON, for caw_audio_threads; reads the callback core's clock
    // from sysfs or the power API, so never on the audio thread.
    std::string audioThreadsJson() const;
    // The platform layer, once its device runs: whether the callback thread joined MMCSS "Pro Audio" (Windows).
    void setCallbackMmcss(bool mmcss) noexcept;
    // The platform, around a live device (before it starts, after it stops): the pool with
    // MixPool::defaultWorkers(), Auto, and the count of live devices offline renders check.
    void startLiveMixPool();
    void stopLiveMixPool() noexcept;
    static int liveDevices() noexcept;
    // An offline render's Engine, before it renders: the pool with MixPool::defaultWorkers(), Always, unless a live
    // device runs (then it stays on one thread, leaving the cores to the live audio).
    void useOfflineMixPool();
    // Tests only, before Engines are made: every Engine made from now on starts a pool of `workers` and uses it
    // Always (0: Never; -1, the default: no override). Offline renders then keep that.
    static void setMixThreadsForTest(int workers) noexcept;
    // Tests only, between process() calls: whether the last callback ran the graph with the pool.
    bool mixParallelForTest() const noexcept { return mixParallel_; }
    MixPool* mixPoolForTest() noexcept { return pool_.get(); }
    // Tests only, between process() calls: whether the layer's node ran in the serial lane at the last parallel
    // callback, and the levels the last chunk handed to the pool.
    bool mixLayerSerialForTest(const std::string& layerId) const;
    uint32_t mixParallelLevelsForTest() const noexcept;

    // Audio thread: no allocation, locks or I/O.
    void process(float* left, float* right, int frames) noexcept;
    // One callback's share of its time budget used, for [frames] frames at the engine's rate. The average, the time
    // over budget before a layer is shed and the rest after it go by time, so any callback size behaves alike.
    void reportLoad(double load, int frames) noexcept;

private:
    // First, so it outlives every component chain (built-ins keep a pointer to it).
    std::atomic<int> quality_{1};
    // The device input (monitoring, recording, the latency ping); audio tracks keep a pointer to it.
    std::unique_ptr<LiveAudio> audioIn_;
    std::atomic<bool> monitorWanted_{false};  // some audio track monitors its input (control thread sets it)
    void wakeMonitors() noexcept;
    struct Slot;
    struct Cmd;
    struct Retired;
    struct RetireList;  // what one graph node hands back in a chunk (engine.cpp)
    struct AutomationData;
    struct MixGraph;  // the graph that routes slots, folder buses and master (engine.cpp)
    struct SlotTable;  // the slots, their mix graph and order list at one capacity (engine.cpp)
    struct DelayLine;  // a track's latency-compensation delay (engine.cpp)
    struct SendTable;  // where a slot's sends and keys go, with their delays (engine.cpp)

    void drainRetired();
    size_t retireRoom() const noexcept;  // audio thread: entries the retired queue and its overflow can still take
    bool canRetire(size_t count) const noexcept;  // outside the graph
    // Inside the graph (speed phase 5c): whether `count` more fit in the node's own list and its share of the room.
    static bool canRetireNode(const RetireList& list, int count) noexcept;
    void assignRetireBudgets() noexcept;  // audio thread, before the graph: each node list's share of the room
    bool send(const Cmd& c);
    std::string setProjectImpl(const ProjectSpec& p, bool offline);
    void applyCommands() noexcept;
    void retire(Slot* freed, std::shared_ptr<const Pattern>* pattern = nullptr, AutomationData* automation = nullptr,
                std::vector<int>* order = nullptr, SlotTable* table = nullptr,
                ComponentChain* components = nullptr) noexcept;
    void retireEntry(const Retired& r) noexcept;  // audio thread: to the control thread, to be freed
    // Inside the graph (speed phase 5a): a node's retirements go to its own list, pushed after the graph has run.
    // False (and an assert) only if it doesn't fit, which canRetireNode rules out: then nothing is retired.
    bool nodeRetire(RetireList& list, const Retired& r) noexcept;
    bool nodeRetireChain(RetireList& list, ComponentChain* chain) noexcept;  // null: nothing (true)
    void flushRetires() noexcept;
    void bindTable() noexcept;  // audio thread: cache the current table's slots, graph and sizes
    void markLive(int slot) noexcept;  // audio thread: the slot joins the in-use list the per-chunk loops visit
    int processChunk(float* l, float* r, int maxFrames) noexcept;  // returns the frames it ran
    int planChunk(int maxFrames) noexcept;
    void planTrack(Slot& s, int& m) noexcept;
    // Graph nodes (audio thread): a track (its instrument, inserts and mix), a folder bus, and the master stage.
    void runTrackNode(int slot, float* outL, float* outR, int m) noexcept;
    void runDelay(Slot& s, float* outL, float* outR, int m) noexcept;
    void runBusNode(int slot, const float* inL, const float* inR, float* outL, float* outR, int m) noexcept;
    // A slot's native inserts over L/R in place, with the crossfade of a chain change (tracks and buses).
    void runInserts(Slot& s, float* L, float* R, int m) noexcept;
    // A slot's sends and keys: pre taps after its effects, post taps after volume and pan (before its delay).
    uint32_t keyNotes(const Slot& s, int m, Event* out, uint32_t max) const noexcept;
    void runRoutes(Slot& s, const float* preL, const float* preR, const float* postL, const float* postR, int m,
                   bool silenced, bool bus) noexcept;
    // A destination's sends and keys when it runs, summed from its sources' route outputs; true if a send arrived.
    bool pullRoutes(Slot& d, int m) noexcept;
    void runMasterNode(const float* inL, const float* inR, float* outL, float* outR, int m) noexcept;
    void updateRouting() noexcept;
    double slotTarget(const Slot& s) const noexcept;
    void updateSolo() noexcept;
    // A track's instrument, first in its track node: its pattern notes and note motion as events, then
    // the instrument (and one it replaced, crossfading out) into the slot's instL/instR.
    void runInstrument(Slot& s, int m) noexcept;
    void instrumentNotes(Slot& s, NoteEvents& notes, int m) noexcept;
    void instrumentMotion(NoteEvents& notes, int m) noexcept;
    void noteMotion(NoteEvents& notes, NoteEvents::Held& h, int end) noexcept;
    bool ringsAtPlay(const Slot& s) const noexcept;
    void playTail(Slot& s, int most) noexcept;
    static bool playsNotes(const Slot& s) noexcept;
    void previewCommand(const Cmd& c) noexcept;
    void takeDeviceMidi(int frames) noexcept;   // callback start: the queue into midiPending_, frames worked out
    void feedDeviceMidi(Slot& s, NoteEvents& notes, int m) noexcept;  // this chunk's device messages for s
    void endDeviceMidi(int frames) noexcept;    // callback end: keep only the messages for later callbacks
    bool queueDeviceMidi(int slot, Midi2Event e, int64_t timeNs) noexcept;
    int deviceSlot(const std::string& layerId);
    void updatePreviewing(int frames) noexcept;
    void endPlayback() noexcept;
    bool noteSpan(const PatternNote& n, uint32_t sub, int64_t& start, int64_t& stop) const noexcept;
    void rebindNote(NoteEvents& notes, NoteEvents::Held& h, const Pattern* pat, int64_t n0) noexcept;
    int64_t loopStart(const Slot& s, int64_t k) const noexcept;
    void updateTiming() noexcept;
    // Where playback from g_ goes back: the loop range's end while it is on and ahead, else the song end.
    int64_t wrapAt() const noexcept;
    void pickOverloadVictim() noexcept;

    const double sr_;
    const double trackGainCoef_;  // the track and bus gain glide's per-sample factor (set with the Engine)
    const EngineResourceBudget resourceBudget_;
    int maxLayers_ = kInitialLayerCapacity;  // set once in the constructor
    int pendingMax_ = 0;                     // pending_ entries; set once in the constructor

    // ---- audio-thread state ----
    // The current slot table (owned; a Grow command swaps in a larger one and retires this one).
    // Slots are individually allocated and never move; a layer slot keeps its index for the life
    // of the Engine, and the audition (always the last slot) is re-indexed by the swap.
    std::unique_ptr<SlotTable> table_;
    Slot** slots_ = nullptr;      // table_'s slots
    MixGraph* mixGraph_ = nullptr;  // table_'s graph, routed on the audio thread
    int* processOrder_ = nullptr;   // table_'s order list: slots in project order, buses after their children
    int* live_ = nullptr;           // table_'s in-use list: liveCount_ slots, ascending (markLive)
    int liveCount_ = 0;
    int capacity_ = 0;      // layer slots; the audition slot follows them
    int auditionSlot_ = 0;  // == capacity_
    int slotCount_ = 0;     // capacity_ + 1 (layers and the audition)
    Slot& slotAt(int i) noexcept { return *slots_[i]; }
    const Slot& slotAt(int i) const noexcept { return *slots_[i]; }
    bool playing_ = false;
    bool previewing_ = false;     // some slot holds a preview voice (still sounding or releasing)
    bool previewChunk_ = false;   // this chunk runs only the previewing slots, with the transport stopped
    bool stopEnded_ = false;      // the stop fade reached silence this callback (endPlayback runs after the chunk)
    int tapAt_ = 0;               // audio thread: the current chunk's first frame in its process() call (output taps)
    int previewRampIn_ = 0;       // samples left of the master's fade back in for previews after a stop
    int stopFade_ = 0;  // samples left in the stop fade, 0 when not stopping
    int playRampIn_ = 0;  // samples left of the fade in after a Play mid-loop or during a stop fade (no click)
    int64_t g_ = 0;     // position in the project loop
    int64_t epoch_ = 0; // project loops completed since play
    uint64_t touchEpoch_ = 0;  // the play count of the last Play handled (audio thread); ends touches
    uint32_t touchPlayStamp_ = 0;  // the last knob move's stamp before that Play (audio thread)
    // Metronome and count-in (audio thread): a click is [clickLeft_] samples of a decaying sine.
    bool metronome_ = false;
    int64_t countInLeft_ = 0, countInAt_ = 0, countInBeat_ = 0;  // samples left, samples into it, its beat length
    double countInFrom_ = 0;
    uint64_t countInPlayCount_ = 0;
    uint32_t countInTouchStamp_ = 0;
    int clickLeft_ = 0, clickLen_ = 0;
    double clickPhase_ = 0, clickInc_ = 0, clickAmp_ = 0;
    std::atomic<float> clickVolume_{1.0f};
    std::atomic<int> clickSound_{0};
    // The test tone: a request in samples from the control thread (-1: none, 0: end it), then the audio thread's
    // own state, which it alone publishes in toneActive_ (whether frames are left after its last callback).
    std::atomic<int64_t> toneRequest_{-1};
    std::atomic<bool> toneActive_{false};
    int64_t toneLeft_ = 0, toneLen_ = 0;
    double tonePhase_ = 0;
    void takeToneRequest() noexcept;                       // once per callback, before any sample
    double nextTone() noexcept;                            // the tone's next sample (only while toneLeft_ > 0)
    void mixToneOnly(float* left, float* right, int frames) noexcept;  // frames the master stage did not run
    void startPlay(double fromStep, uint64_t playCount, uint32_t touchStamp) noexcept;
    void startClick(bool accent) noexcept;
    double nextClick() noexcept;  // the click's next sample (0 when none sounds)
    double bpm_ = 120.0;
    int beatsPerBar_ = 4;
    int loopSteps_ = 64;
    bool loopRange_ = false;               // the project's loop range is on
    int loopFromSteps_ = 0, loopToSteps_ = 0;
    int64_t loopFrom_ = 0, loopTo_ = 0;    // the loop range in samples (updateTiming)
    uint32_t seed_ = 0;
    double master_ = 0.7;
    double masterTarget_ = 0.7, masterStep_ = 0.0;
    int masterRamp_ = 0;
    bool anySolo_ = false;  // some layer is soloed (refreshed each callback)
    bool auditionOnly_ = false;
    double stepLen_ = 0;  // samples per 16th note
    int64_t loopLen_ = 0; // samples per project loop
    double dcL_[2] = {0, 0}, dcR_[2] = {0, 0}, limEnv_ = 0;
    double loadAvg_ = 0;
    double overSeconds_ = 0, coolSeconds_ = 0;  // time over budget so far, time left before another layer is shed
    double loadDt_ = 0, loadKeep_ = 0;          // the last callback's length and the average's weight for it
    bool overloadPending_ = false;
    int processCount_ = 0;
    int64_t chunkId_ = 0;
    bool routingDirty_ = true;  // re-derive graph routing before the next chunk
    // Speed phase 5c (audio thread): this callback runs the graph with the pool; Auto's choice and its timers.
    bool mixParallel_ = false;
    bool mixAuto_ = false;
    double mixOverSeconds_ = 0, mixUnderSeconds_ = 0;
    // Speed phase 5d (audio thread): Auto's workers and the wait it weighs (shares of the budget, averaged).
    uint32_t mixActive_ = 0;
    double waitAvg_ = 0, workAvg_ = 0, mixLosingSeconds_ = 0, mixGrowSeconds_ = 0, mixRetrySeconds_ = 0;
    std::atomic<float> waitShare_{0};
    int retireStart_ = 0;  // where assignRetireBudgets hands out what is left after the even shares
    bool wantsMixPool() const noexcept;
    bool slotForeign(const Slot& s) noexcept;  // a node in the serial lane: it holds third-party native code
    // Retirements waiting for room in the queue (pendingMax_ entries: two per slot at maxLayers() and
    // some slack; owned, so a throwing constructor cannot leak it).
    std::unique_ptr<Retired[]> pending_;
    int pendingCount_ = 0;
    int64_t masterTailLeft_ = 0;  // audio thread: stopped, the master chain rings out for at most this long
    int64_t masterQuiet_ = 0;     // ... ending sooner once its output has been quiet for a moment
    int masterTailFade_ = 0;      // > 0: at its cap and still audible, fading out (frames left); -1: faded
    ComponentChain* masterFading_ = nullptr;  // audio thread: the master chain a newer one replaced, crossfading out
    int masterFadeLeft_ = 0;
    float masterFadeL_[kBlock], masterFadeR_[kBlock];  // audio thread: a replaced master chain's output while it fades
    float masterStageL_[kBlock], masterStageR_[kBlock];  // audio thread: the master chain runs here
    // Audio thread: what the master node hands back in a chunk (flushRetires pushes it after the graph, with each
    // slot's list, which is in Slot; assignRetireBudgets shares the room out before the graph).
    std::unique_ptr<RetireList> masterRetires_;

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
    std::unique_ptr<LoudnessMeter> loudness_;  // the master's (about 100 KB: its gating histogram)
    CorrelationMeter masterCorrelation_;
    // Project modulation (#161): its plan comes from the control thread, the audio thread runs it each chunk.
    std::unique_ptr<ModulationHost> modulation_ = std::make_unique<ModulationHost>();
    std::unique_ptr<NoteFxManager> noteFx_ = std::make_unique<NoteFxManager>();  // per-note FX (#127)
    uint64_t modPlays_ = 0;  // audio thread: Plays handled, so the modulators restart at each (not at a touch release)

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
    // A project module: a pattern (note clip) and the last version that parsed.
    struct ModuleState {
        std::string source;
        std::shared_ptr<const Pattern> pattern;  // the last version that parsed
        std::string error;
        int line = 0, col = 0;
    };
    struct LayerState {
        int slot = -1;
        bool track = false;                      // installed as a track (Install sent): it plays its instrument
        int steps = -1;
        std::shared_ptr<const Pattern> pattern;  // what the audio thread was last sent
        std::string arrangementSig;              // source + clip signature; keeps compiled timelines stable
        double volume = -1, pan = 0;
        bool mute = false, solo = false, bus = false;
        int parentSlot = -1;
        std::string automationSig;
        ComponentChain* inserts = nullptr;  // the native effects last sent to the slot (alive while it plays)
        std::string insertsAutomationKey;   // the lanes their automation table was made from
        ComponentChain* instrument = nullptr;  // the native instrument last sent to the slot (alive while it plays)
        std::string instrumentAutomationKey;
        int64_t compensation = 0;           // the latency-compensation delay last sent, in frames
        // Sends (the project's, in order) then sidechain keys this layer feeds; set by setProject, sent by
        // updateCompensation with their delays.
        struct Route {
            int dest = -1;     // the destination slot (-1: none; the send's bus is missing)
            int key = -1;      // -1: into the bus's input; else the component index on dest's inserts it keys
            double level = 1;
            bool pre = false, mute = false;
        };
        std::vector<Route> routes, routesSent;
        int userSends = 0;          // routes[0..userSends) are the project's sends
        std::string routesSig;      // destinations and delays last sent
    };
    std::map<std::string, ModuleState> modules_;
    std::map<std::string, LayerState> layers_;
    std::map<int32_t, int> previewSlots_;  // control thread: each held preview's slot, for its pitch and off
    // Device MIDI (API 15): producers push under midiPush_ (never the audio thread); the audio thread pops into
    // midiPending_ (made with the Engine) and places each message at its frame.
    struct PendingMidi {
        Midi2Event e;
        int64_t frame = 0;  // in the current callback
        bool done = false;
    };
    Midi2InputQueue midiIn_;
    std::mutex midiPush_;
    std::unique_ptr<PendingMidi[]> midiPending_;
    uint32_t midiPendingCount_ = 0;
    int midiChunkFrom_ = 0;  // audio thread: the chunk's first frame in the callback
    std::atomic<uint64_t> midiPendingDropped_{0};
    std::atomic<bool> midiMpe_{false};
    std::atomic<double> midiBendRange_{2}, midiNoteBendRange_{48};
    std::atomic<int64_t> midiDelayNs_{0};
    std::atomic<int64_t> midiClockTest_{-1};
    std::atomic<int64_t> cbTimeNs_{0}, cbPos_{-1};  // the last callback's start on the MIDI clock, and g_ then (-1: stopped)
    std::vector<std::string> order_;  // layer ids in project order, for meters
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

    void writeMix(int slot, double vol, double pan, bool mute, bool solo);
    int freeSlot();
    // Control thread; null: none. `index` kInstrumentIndex names the layer's instrument (and becomes 0).
    ComponentChain* ctlComponentChain(const std::string& layerId, uint32_t& index) noexcept;
    // Latency compensation for every route (each track's and bus's main output and each send, so all arrive in
    // time where they meet), sending changed delays and route tables.
    bool updateCompensation(std::map<std::string, std::vector<std::string>>& warnings);

    // The mix pool (speed phase 5c). Last, so its threads are joined before anything they could touch goes.
    std::atomic<int> mixMode_{0};
    bool liveDevice_ = false;  // control thread: startLiveMixPool counted this Engine in liveDevices()
    bool offlinePool_ = false; // useOfflineMixPool's: serial while any live device runs (checked each callback)
    std::unique_ptr<MixPool> pool_;
};

}  // namespace caw
