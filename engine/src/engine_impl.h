// Private to the engine's .cpp files: the nested Engine:: structs (slots, commands, retirements, routes, mix graph) and the helpers they share.
#pragma once
#include "engine.h"
#include "fx_merged.h"
#include "fx_migrate.h"
#include "audio_clips.h"

#include "presets.h"
#include "quality.h"
#include "builtin_components.h"
#include "builtin_pack.h"
#include "graph.h"
#include "meters.h"
#include "load_stabilizer.h"
#include "mix_pool.h"
#include "thread_tuning.h"
#include "route_math.h"
#include "caw/library/fastmath.hpp"
#include "caw/library/stereo.hpp"
#include "hardware.h"
#include "sample_preview.h"
#include "vca.h"

#include <algorithm>
#include <bit>
#include <cassert>
#include <array>
#include <chrono>
#include <cstdio>
#include <cmath>
#include <stdexcept>
#include <thread>

#include "detmath.h"
#include "fp_mode.h"
#include "json.h"
#include "params.h"
#include "sample_time.h"

namespace caw {

// Immutable automation prepared on the control thread and reclaimed off the audio callback.
struct Engine::AutomationData {
    std::vector<AutomationPointSpec> volume;
    std::vector<AutomationPointSpec> pan;
};

struct Engine::Retired {
    Slot* freed = nullptr;  // a slot whose layer has faded out (by object: the audition's index can change)
    std::shared_ptr<const Pattern>* pattern = nullptr;
    AutomationData* automation = nullptr;
    std::vector<int>* order = nullptr;
    SlotTable* table = nullptr;  // a slot table (and its mix graph) a Grow replaced
    ComponentChain* masterChain = nullptr;  // a component chain (master or a track's inserts) replaced or freed
    ComponentAutomation* componentAutomation = nullptr;  // a component chain's automation table replaced
    DelayLine* delay = nullptr;  // a latency-compensation delay replaced or freed
    SendTable* sends = nullptr;  // a route table replaced or freed
    SongTime* song = nullptr;    // a tempo map and signatures replaced
    VcaTable* vca = nullptr;     // a VCA table replaced
};

// What one graph node (a slot's, or the master's) hands back while the graph runs (speed phase 5a): kept here and
// pushed to the retired queue by the callback thread once the graph has run (flushRetires), so nodes never touch the
// shared queue. Bounded: a track node retires at most 3 things a chunk (a fading instrument, inserts and delay), a
// bus node at most 5 (its fading inserts and delay, then its slot, fading inserts and delay when it is freed).
// Each list has its own share of the queue's free room for the chunk (`budget`, at most kCapacity), handed out by
// the callback thread before the graph runs (speed phase 5c), so a node's canRetireNode reads only its own list and
// gives the same answer whichever thread runs it, and whenever.
struct Engine::RetireList {
    static constexpr int kCapacity = 8;
    Retired items[kCapacity];
    int count = 0;
    int budget = 0;
};

// Per-layer audio and meter state. Fields above `vol` belong to the audio thread.
struct Engine::Slot {
    // This slot's place in the slot table: fixed for a layer slot; the audition slot (always the
    // last) gets the new last index from the audio thread when a Grow swaps in a larger table.
    int index = -1;
    bool active = false;
    bool listed = false;     // in Engine::live_, the slots the per-chunk loops visit (audio thread)
    bool removing = false;
    bool track = false;      // installed as a track: its instrument plays the notes, through its inserts
    bool fresh = true;       // the track has not played yet since it was installed or play started
    bool chase = false;      // its next chunk picks up the pattern notes already sounding there (#226, chaseNotes)
    bool overloaded = false;  // shed: the device ran out of time (setShed keeps Engine::overloadedFlag_ counting these)
    uint64_t shedSeq = 0;       // audio thread: when it was shed, in shed order (the newest shed comes back first)
    double shedCost = 0;        // audio thread: what it is taken to cost: the meter's drop after it was shed, at most
                                // an equal share of the load when it was shed (a load falling for another reason
                                // then must not make it look too costly ever to come back)
    double restoreDelay = 0;    // audio thread: seconds under the restore load before it comes back (doubles on a re-shed)
    double restoredAt = -1e9;   // audio thread: the load clock when it last came back
    bool bus = false;
    int parentSlot = -1;
    AutomationData* automation = nullptr;
    double outL[kBlock] = {}, outR[kBlock] = {};
    ComponentChain* inserts = nullptr;  // native stereo effects after the instrument, before volume and pan
    DelayLine* delay = nullptr;         // latency compensation, after volume and pan
    SendTable* sends = nullptr;         // where the slot's sends and keys go (owned; replaced by SetSends)
    bool routesStale = false;           // stopped or silent: the routes' delays hold old audio; clear them
    // A bus's input from sends this chunk, summed from its sources' route outputs when it runs (pullRoutes).
    float recvL[kBlock] = {}, recvR[kBlock] = {};
    // The node's own scratch (speed phase 5a; was the Engine's, shared by every node): the signal through its
    // inserts (the pre tap), and a replaced chain's or delay's output during a crossfade.
    float insL[kBlock] = {}, insR[kBlock] = {};
    float fadeL[kBlock] = {}, fadeR[kBlock] = {};
    RetireList retires;  // what this slot's node handed back this chunk (flushRetires)
    bool routingChanged = false;  // its node freed it this chunk: routing is re-derived (ORed after the graph)
    DelayLine* delayFading = nullptr;   // the delay `delay` replaced, crossfading out (null: no delay)
    int delayFadeLeft = 0;
    bool delayStale = false;            // stopped or silent: the delay holds old audio; clear before it runs
    ComponentChain* insertsFading = nullptr;  // the chain `inserts` replaced, crossfading out (null: the dry signal)
    int insertsFadeLeft = 0;                  // samples of that crossfade still to run
    bool insertsIdle = false;  // the inserts stopped running (Silent): reset before they run again
    ComponentChain* instrument = nullptr;        // a native instrument playing the track's notes (null: none)
    ComponentChain* instrumentFading = nullptr;  // the instrument `instrument` replaced, crossfading out
    int instrumentFadeLeft = 0;
    bool instrumentIdle = false;  // the instrument stopped running (Silent): reset before it runs again
    float instL[kBlock] = {}, instR[kBlock] = {};  // this chunk's instrument output (runInstrument)
    // Play while the instrument still rang out (after Stop): its next few milliseconds, rendered before it was
    // reset and faded to silence, mixed in from the next chunk so the reset doesn't click.
    static constexpr int kPlayTailMax = 512;
    float playTailL[kPlayTailMax] = {}, playTailR[kPlayTailMax] = {};
    int playTailLen = 0, playTailAt = 0;
    bool insertTail = false;   // a bus, stopped: its inserts ring out on silence until quiet
    int tailFade = 0;          // > 0: a tail at its cap, still audible, fading out (frames left); -1: faded
    int64_t tailCap = 0;       // ... or for at most this many samples
    std::shared_ptr<const Pattern>* pattern = nullptr;  // owned here, freed on the control thread when retired
    int steps = 0;
    int order = 0;
    double layerLen = 1;  // samples in this layer's loop, for the progress meter
    int64_t k = -1, epoch = -1, lastN = 0;
    double gain = 0;
    double panCache = 2, gl = 0, gr = 0;

    std::atomic<uint64_t> vol{0}, pan{0};
    std::atomic<bool> mute{false}, solo{false};
    // Audio thread: its VCA groups (vca.h), apart from its own mute and solo above: one of them muted or soloed
    // (refreshed with the solo state), and this chunk's VCA gain per frame (runVca; vcaOn: not exactly 1 throughout).
    // A change of its groups (a new table) ramps from vcaLast, the gain it had, by an offset that decays with the
    // faders' 5 ms pole (vcaOffset); vcaFresh: a new layer here, which starts at its groups' gain.
    bool vcaMute = false, vcaSolo = false, vcaOn = false;
    bool vcaDirty = false, vcaFresh = false;
    double vcaLast = 1.0, vcaOffset = 0.0;
    double vca[kBlock] = {};
    // A layer newly in this slot: no VCA state from the slot's last owner.
    void resetVca() noexcept {
        vcaMute = vcaSolo = vcaOn = false;
        vcaDirty = vcaFresh = true;
        vcaLast = 1.0;
        vcaOffset = 0.0;
    }
    std::atomic<float> peakL{0}, peakR{0}, progress{0};  // meters: each side's sample peak since the last read
    CorrelationMeter correlation;                         // of what it sends on
    std::atomic<bool> overloadFlag{false};
    std::atomic<float> scope[kScopeSize];
    std::atomic<int> scopePos{0};

    bool ctlBusy = false;  // control thread only: a layer holds this slot, or it is still fading out
    // Offline renders only (setOutputTap): where this slot's output is also copied, at the frame it plays in the
    // current process() call; null when it isn't tapped.
    float* tapL = nullptr;
    float* tapR = nullptr;
    bool tapPre = false;  // the tap takes the signal before the fader (setOutputTap's preFader)

    // This chunk's plan (planChunk), read by the slot's graph nodes. Chunks end at every loop
    // boundary of a playing track, so one plan covers the whole chunk.
    // Ahead: the track plays from its play-ahead ring (planAhead): only its mix (fader on) runs here.
    enum class Mode : uint8_t { Idle, Bus, Silent, Play, Ahead };
    Mode mode = Mode::Idle;
    double target = 0;          // mix target (0 while muted or soloed out)
    int64_t n0 = 0, repeat = 0; // sample in the layer's loop, and the pattern repeat
    double passStep = 0;        // the song step this pass of the layer starts on (the tempo map's timing)
    int64_t passStart = 0;      // and its first sample in the song
    const Pattern* pat = nullptr;
    bool previewing = false;    // audio thread: the track holds a preview note, or its sound is still dying away
    DeviceNotes deviceNotes;    // audio thread: the device MIDI channels' bend and pedal (API 15)
    // A MIDI-out layer (API 47): its notes and their bytes (owned by the Engine, never freed while it lives; null:
    // not one). Set by SetMidiOut; such a slot runs as a track whose instrument output is silence.
    MidiOutLane* midiOut = nullptr;
    int64_t previewQuiet = 0;   // samples the track's output has been below kPreviewQuiet
    int64_t previewTail = 0;    // samples since its last preview voice ended
    int64_t previewN = 0;       // stopped: the sample in the layer's loop that preview chunks run from
    // Play-ahead (play_ahead.h). Audio thread: the AheadTrack rendering it (-1: live); live for good after an
    // underrun (until installed again); the frames of a fade back in; frames since the last edit or note aimed at it.
    int ahead = -1;
    int aheadStrikes = 0;     // underruns since installed (play-ahead): each keeps it live for a while
    int64_t aheadBanLeft = 0; // frames it stays live after an underrun (INT64_MAX: for good, after the third)
    int aheadFadeIn = 0, aheadFadeLen = 0;
    int64_t aheadQuiet = 0;
    uint32_t aheadTouchSeen = 0;
    // A value edit on the control thread bumps aheadTouch and then reads aheadOwned; the audio thread sets aheadOwned
    // and then reads aheadTouch (both sequentially consistent), so an edit either sees the track ahead (and goes to
    // its inbox) or stops it going ahead.
    std::atomic<uint32_t> aheadTouch{0};
    std::atomic<bool> aheadOwned{false};
};

constexpr int kExpressionStep = 16;  // 1/3 ms at 48 kHz: smooth for bends and vibrato up to 30 Hz, 16x cheaper

// A held note carried across a pattern edit glides from the pitch heard to its new curve over this long.
constexpr double kRebindGlideSeconds = 0.005;

// Delays a track's output so it lines up with the track whose native effects add the most latency.
struct Engine::DelayLine {
    std::vector<float> l, r;
    size_t pos = 0;
    void clear() noexcept {
        std::fill(l.begin(), l.end(), 0.0f);
        std::fill(r.begin(), r.end(), 0.0f);
    }
    // Takes over `from`'s recent input, so a changed delay continues the signal instead of a gap of silence.
    void takeHistory(const DelayLine* from) noexcept {
        const size_t n = l.size();
        const size_t m = from ? from->l.size() : 0;
        for (size_t k = 0; k < n; ++k) {
            const size_t back = n - k;  // l[k] (k = 0 oldest) holds the input from `back` samples ago
            if (back <= m) {
                const size_t at = (from->pos + m - back) % m;
                l[k] = from->l[at];
                r[k] = from->r[at];
            } else {
                l[k] = r[k] = 0.0f;
            }
        }
        pos = 0;
    }
    // Each frame swaps with the ring's oldest (the frame `n` back comes out, this one goes in): in runs up to the
    // ring's end, as two plain swaps of arrays (no wrap test per frame).
    void run(float* outL, float* outR, int m) noexcept {
        const size_t n = l.size();
        for (size_t i = 0, frames = static_cast<size_t>(m); i < frames && n > 0;) {
            const size_t k = std::min(frames - i, n - pos);
            std::swap_ranges(outL + i, outL + i + k, l.data() + pos);
            std::swap_ranges(outR + i, outR + i + k, r.data() + pos);
            i += k;
            pos = pos + k == n ? 0 : pos + k;
        }
    }
};

// A feedback send's ring (built on the control thread with its route table): the source writes each chunk's route
// signal at its frames on the engine's route clock (Engine::routeFrame_, which counts every frame the mixer runs),
// and the destination reads the frames kBlock before, so the route is exactly kBlock frames late whatever the
// device's buffer and chunk sizes, and whichever of the two runs first (or at once, on the mix pool: a chunk is at
// most kBlock frames, so the two never touch the same frames). The reader zeroes what it read, so a source that
// stops writing goes quiet a chunk later. The soft clip and DC block on the return are the reader's.
struct FeedbackRing {
    static constexpr int kSize = 2 * kBlock;
    static_assert((kSize & (kSize - 1)) == 0, "the ring's frames are masked: its size must be a power of two");
    static constexpr double kUnlimited = 16.0;  // without its limiter, a return is held to +/-16 (+24 dBFS)
    float l[kSize] = {}, r[kSize] = {};
    bool limiter = true;
    double pole = 0.9987;              // the DC block's (about 10 Hz)
    double xl = 0, yl = 0, xr = 0, yr = 0;  // the DC block's last input and output, per side (the reader's)
    void clear() noexcept {
        std::fill_n(l, kSize, 0.0f);
        std::fill_n(r, kSize, 0.0f);
        xl = yl = xr = yr = 0;
    }
    // A rebuilt route table's ring carries on from the one it replaces (audio thread, between chunks).
    void takeHistory(const FeedbackRing& was) noexcept {
        std::copy_n(was.l, kSize, l);
        std::copy_n(was.r, kSize, r);
        xl = was.xl; yl = was.yl; xr = was.xr; yr = was.yr;
    }
};

// A feedback return's soft clip: unity below 0.5, then a tanh knee that never reaches 1 (0 dBFS).
inline double feedbackClip(double x) noexcept {
    const double a = std::fabs(x);
    if (!(a > 0.5)) return a == a ? x : 0.0;  // NaN: silence
    const double y = 0.5 + 0.5 * lib::tanhApprox((a - 0.5) * 2.0);
    return x < 0 ? -y : y;
}

// A slot's routes: its sends (into bus or track inputs) then the sidechain keys it feeds, each with its own latency
// compensation. Built on the control thread; the audio thread swaps it in (SetSends) and retires the old one.
struct Engine::SendTable {
    struct Route {
        int dest = -1;     // destination slot
        int key = -1;      // -1: a bus's or track's input; else the component index on dest's inserts it keys
        double level = 1;
        // pre: the tap asked for; tapPre: the tap in use (audio thread). A switch fades the route out, changes
        // tap at 0 and fades back in, so it never jumps.
        bool pre = false, mute = false, tapPre = false;
        DelayLine* delay = nullptr;  // owned; null: none
        double gain = 0;   // audio thread: its gain at the end of the last block (a route that stays keeps it)
        bool ok = false;   // updateRouting: its destination runs after this slot this chunk
        // Audio thread (speed phase 5a): the source writes the route's signal here, and its destination sums its
        // routes from their sources' tables in a fixed order when it runs (pullRoutes). `chunk`: the chunk it
        // reached its destination in (the destination then takes it: a bus marks its input received, a key its
        // notes); `audio`: it also wrote out[LR] that chunk (a settled, silent route adds nothing).
        float outL[kBlock] = {}, outR[kBlock] = {};
        int64_t chunk = -1;
        bool audio = false;
        // A feedback send: its destination reads `ring` (kBlock frames late), never outL/outR, chunk or audio, so it
        // may close a loop and runs in no order with its source.
        bool feedback = false;
        FeedbackRing* ring = nullptr;  // owned; feedback only
    };
    std::unique_ptr<Route[]> routes;  // count, sized from the layer's routes on the control thread
    int count = 0;
    bool keys = false;  // some route keys a component: the slot runs even while muted or soloed out
    // Audio thread: the note-ons and note-offs the slot played in the chunk its routes last ran (keyNotes), which
    // its key routes' destinations take into their keys.
    Event keyEvents[ComponentChain::kMaxKeyEvents] = {};
    uint32_t keyEventCount = 0;
    explicit SendTable(int n) : routes(new Route[static_cast<size_t>(n)]), count(n) {}
    SendTable(const SendTable&) = delete;
    SendTable& operator=(const SendTable&) = delete;
    ~SendTable() {
        for (int k = 0; k < count; ++k) {
            delete routes[k].delay;
            delete routes[k].ring;
        }
    }
};

static_assert(ComponentChain::kMaxFrames == static_cast<uint32_t>(kBlock), "component chains run Engine blocks");
static_assert(VcaTable::kFrames == kBlock, "VCA groups work out a chunk's gains in Engine blocks");

struct Engine::Cmd {
    // Install: the slot becomes a track (steps, order); its instrument and inserts come by their own commands.
    enum Type { Install, SetSteps, SetPattern, Remove, Transport, SetSong, SetMaster, SetMasterChain, SetInserts, SetInstrument, SetComponentAutomation, SetDelay, SetSends, SetSendLevel, SetMidiOut, Play, Stop, AuditionOnly, ClearOverload, SetOrder, SetRouting, ConfigureBus, SetAutomation, Grow, Preview, Metronome, ReleaseTouches, SetVca, SetValue } type = Play;
    // SetValue (play-ahead): component `order` of chain `valueChain` (the slot's) gets parameter `param` = `master`
    // (valueKind 0), its bypass (1) or its auto gain (2) = `flag`, once the slot's ahead ring has played out.
    int valueKind = 0, param = -1;
    ComponentChain* valueChain = nullptr;  // not owned: the chain the slot holds when it applies
    std::shared_ptr<const Pattern>* pattern = nullptr;
    // SetOrder: slots in dependency order; SetPattern: for each note of the old pattern, the new note that carries it
    // on, or -1 (matchPatternNotes). Owned; retired by the audio thread.
    std::vector<int>* orderList = nullptr;
    SlotTable* table = nullptr;  // Grow: the larger slot table (owned; the one it replaces is retired)
    int slot = 0;
    ComponentChain* masterChain = nullptr;  // SetMasterChain: the master's; SetInserts/SetInstrument: the slot's (owned)
    // SetComponentAutomation: for slot's inserts (its instrument when `flag`), or the master's (slot -1)
    ComponentAutomation* componentAutomation = nullptr;
    DelayLine* delay = nullptr;  // SetDelay: the slot's latency compensation (null: none)
    SendTable* sends = nullptr;  // SetSends: the slot's routes (owned; null: none)
    SongTime* song = nullptr;    // Transport, SetSong: the tempo map and signatures (owned; null: unchanged)
    VcaTable* vca = nullptr;     // SetVca: the project's VCA groups (owned; null: none)
    bool sendMute = false;       // SetSendLevel: route `order` gets level `master`, pre `flag` and this mute
    int steps = 0, order = 0, parentSlot = -1;
    AutomationData* automation = nullptr;
    double bpm = 120, master = 0.7;
    int beatsPerBar = 4, loopSteps = 64;
    int loopFromSteps = 0, loopToSteps = 0;  // Transport: the loop range, when loopRange
    bool loopRange = false;
    uint32_t seed = 0;
    bool flag = false;
    uint64_t playCount = 0;    // Play: the control thread's play count, which ends touches
    double fromStep = 0;       // Play: where in the project loop to start, in sixteenth steps
    uint32_t touchStamp = 0;   // Play: the last touch stamp before it (later stamps are touches after it)
    int countInBeats = 0;      // Play: beats of count-in clicks before it starts (bars when countInBars)
    bool countInBars = false;
    // Preview: what to do with preview [previewId] on [slot]: 0 note on, 1 glide to [pitch], 2 note off, 3 all off.
    int previewOp = 0;
    int32_t previewId = 0;
    double pitch = 60, vel = 1;
    // SetMidiOut: the slot's MIDI-out lane (null: the slot no longer sends MIDI) and its configuration.
    MidiOutLane* midiLane = nullptr;
    MidiOutSpec midiSpec;
};

// Helpers and state more than one of the engine's .cpp files use.
namespace detail {

constexpr double kGainSeconds = 0.005;

inline double bitsToDouble(uint64_t b) { return std::bit_cast<double>(b); }
inline uint64_t doubleToBits(double d) { return std::bit_cast<uint64_t>(d); }

inline std::atomic<int> gLiveDevices{0};     // Engines with a live device (startLiveMixPool)

}  // namespace detail
using detail::kGainSeconds;
using detail::bitsToDouble;
using detail::doubleToBits;
using detail::gLiveDevices;

// The engine's mix graph: node i runs slot i (a track or a folder bus) and node `slots` is the master
// stage. Every node has a summing stereo input; routing (child -> folder bus, root -> master) and the
// execution order are set on the audio thread from the slots' state (Engine::updateRouting).
struct Engine::MixGraph {
    // A track's node: its instrument, inserts, volume and pan (Engine::runTrackNode); no graph input.
    class TrackNode final : public ModuleProcessor {
    public:
        TrackNode(Engine& e, int slot, const ModuleDescriptor& d) : e_(e), slot_(slot), d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        using ModuleProcessor::process;
        bool process(const AudioProcessBlock& b) noexcept override {
            e_.runTrackNode(slot_, b.output.channels[0], b.output.channels[1], static_cast<int>(b.frames));
            return true;
        }
    private:
        Engine& e_;
        int slot_;
        const ModuleDescriptor& d_;
    };
    class BusNode final : public ModuleProcessor {
    public:
        BusNode(Engine& e, int slot, const ModuleDescriptor& d) : e_(e), slot_(slot), d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        using ModuleProcessor::process;
        bool process(const AudioProcessBlock& b) noexcept override {
            e_.runBusNode(slot_, b.input.channels[0], b.input.channels[1], b.output.channels[0],
                          b.output.channels[1], static_cast<int>(b.frames));
            return true;
        }
    private:
        Engine& e_;
        int slot_;
        const ModuleDescriptor& d_;
    };
    class MasterNode final : public ModuleProcessor {
    public:
        MasterNode(Engine& e, const ModuleDescriptor& d) : e_(e), d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        using ModuleProcessor::process;
        bool process(const AudioProcessBlock& b) noexcept override {
            e_.runMasterNode(b.input.channels[0], b.input.channels[1], b.output.channels[0],
                             b.output.channels[1], static_cast<int>(b.frames));
            return true;
        }
    private:
        Engine& e_;
        const ModuleDescriptor& d_;
    };

    // Node layout: a track node per slot, then a bus node per slot, then master.
    // The layout depends on the slot count (layer capacity + the audition), fixed at construction.
    const int slots;   // slot count
    const int master;  // the master in slot-level routing scratch (== slots)
    const int routesPerSlot;  // the most routes one slot's table holds (kDefaultRoutes, or what a project needs)
    uint32_t trackNode(int slot) const noexcept { return static_cast<uint32_t>(slot); }
    uint32_t busNode(int slot) const noexcept { return static_cast<uint32_t>(slots + slot); }
    uint32_t masterNode() const noexcept { return static_cast<uint32_t>(2 * slots); }
    int nodeCount() const noexcept { return 2 * slots + 1; }
    int maxEdges() const noexcept { return slots; }  // each slot's output into its bus or the master
    // The mixer graph is fixed engine structure (nodeCount() nodes of kBlock frames), not project content, so it
    // gets its own budget floor rather than competing with project graphs.
    static constexpr std::size_t kMinBudgetBytes = 8u * 1024u * 1024u;

    const PortDescriptor ports[2] = {{"in", PortType::Audio, ChannelLayout::Stereo, true, 0, true},
                                     {"out", PortType::Audio, ChannelLayout::Stereo, false}};
    const PortDescriptor trackPorts[1] = {{"out", PortType::Audio, ChannelLayout::Stereo, false}};
    const ModuleDescriptor trackDescriptor{"caw.track.out", 1, trackPorts, 1, nullptr, 0};
    const ModuleDescriptor busDescriptor{"caw.mixer.bus", 1, ports, 2, nullptr, 0};
    const ModuleDescriptor masterDescriptor{"caw.mixer.master", 1, ports, 2, nullptr, 0};
    std::vector<std::string> ids;
    std::vector<std::unique_ptr<ModuleProcessor>> nodes;
    GraphExecutor executor;

    // Routing scratch, audio thread only; slot-level arrays use `master` for the master. Sized in
    // the constructor and never resized on the audio thread.
    std::vector<int> target;          // [slots] routed destination slot (or master), or -1
    std::vector<uint8_t> routable;    // [slots] runs this chunk: active, and a bus or a track
    std::vector<int> pending;         // [slots + 1] routed children not yet ordered
    std::vector<uint8_t> deferred;    // [slots + 1]
    std::vector<uint8_t> emitted;     // [slots + 1]
    std::vector<int> slotOrder;       // [slots]
    std::vector<int> stack;           // [slots + 1] slots ready to be ordered
    std::vector<uint32_t> position;   // [slots + 1]
    std::vector<uint32_t> order;      // [nodeCount()]
    std::vector<GraphConnection> edges;  // [maxEdges()]
    // Sends and keys pull (speed phase 5a): destination d sums inRoutes[inFirst[d] ..][inCount[d]] when it runs,
    // in the old push order (its sources in the order they run, each one's routes by index), so the sums keep their
    // bits. Each also orders its source's node before d's in the executor's levels (dependencies).
    struct InRoute {
        const SendTable* table = nullptr;  // the source's routes (alive until the graph has run: flushRetires)
        int k = 0;                         // the route's index there
    };
    int maxRoutes() const noexcept { return slots * routesPerSlot; }
    std::vector<int> inFirst, inCount;     // [slots] each: where d's routes start in inRoutes, and how many
    std::vector<InRoute> inRoutes;         // [maxRoutes()]
    // updateRouting builds the next tables here and swaps them in only once the executor accepts the routing they
    // go with, so pullRoutes never reads tables made for another order (speed phase 5c).
    std::vector<int> inFirstNext, inCountNext;
    std::vector<InRoute> inRoutesNext;
    std::vector<GraphDependency> dependencies;  // [maxRoutes()]

    // capacity: layer slots; the graph also routes the audition slot after them.
    MixGraph(Engine& e, int capacity, double sampleRate, const EngineResourceBudget& engineBudget,
             int routes = kDefaultRoutes)
        : slots(capacity + 1), master(capacity + 1), routesPerSlot(std::max(routes, static_cast<int>(kDefaultRoutes))),
          target(static_cast<size_t>(slots), 0), routable(static_cast<size_t>(slots), 0),
          pending(static_cast<size_t>(slots) + 1, 0),
          deferred(static_cast<size_t>(slots) + 1, 0), emitted(static_cast<size_t>(slots) + 1, 0),
          slotOrder(static_cast<size_t>(slots), 0), stack(static_cast<size_t>(slots) + 1, 0), position(static_cast<size_t>(slots) + 1, UINT32_MAX),
          order(static_cast<size_t>(nodeCount()), 0), edges(static_cast<size_t>(maxEdges()), GraphConnection{}),
          inFirst(static_cast<size_t>(slots), 0), inCount(static_cast<size_t>(slots), 0),
          inRoutes(static_cast<size_t>(maxRoutes())), inFirstNext(static_cast<size_t>(slots), 0),
          inCountNext(static_cast<size_t>(slots), 0), inRoutesNext(static_cast<size_t>(maxRoutes())),
          dependencies(static_cast<size_t>(maxRoutes())) {
        const int kNodes = nodeCount();
        ids.reserve(kNodes);
        nodes.reserve(kNodes);
        std::vector<GraphNode> graphNodes;
        std::vector<ModuleProcessor*> processors;
        graphNodes.reserve(kNodes);
        processors.reserve(kNodes);
        auto add = [&](std::string id, std::unique_ptr<ModuleProcessor> node, const ModuleDescriptor* d) {
            ids.push_back(std::move(id));
            nodes.push_back(std::move(node));
            graphNodes.push_back({ids.back(), d});
            processors.push_back(nodes.back().get());
        };
        for (int s = 0; s < slots; ++s)
            add("slot" + std::to_string(s) + ".track", std::make_unique<TrackNode>(e, s, trackDescriptor), &trackDescriptor);
        for (int s = 0; s < slots; ++s)
            add("slot" + std::to_string(s) + ".bus", std::make_unique<BusNode>(e, s, busDescriptor), &busDescriptor);
        add("master", std::make_unique<MasterNode>(e, masterDescriptor), &masterDescriptor);
        GraphResourceBudget budget = makeGraphResourceBudget(engineBudget);
        budget.maxWorkingBytes = std::max(budget.maxWorkingBytes, kMinBudgetBytes);
        if (executor.prepareRouted(graphNodes, processors, masterNode(), kBlock, sampleRate, budget,
                                   static_cast<uint32_t>(slots), static_cast<uint32_t>(maxRoutes())) != GraphError::Ok)
            throw std::runtime_error("mix graph could not be prepared");
    }

    // What this graph holds outside the executor (node objects, ids, routing scratch), plus the
    // temporary node and processor lists its constructor builds.
    std::size_t hostBytes() const noexcept {
        std::size_t b = sizeof(MixGraph);
        b += ids.capacity() * sizeof(std::string);
        for (const std::string& id : ids) {
            const char* data = id.data();
            const char* self = reinterpret_cast<const char*>(&id);
            if (data < self || data >= self + sizeof(std::string)) b += id.capacity() + 1;  // not stored inline
        }
        b += nodes.capacity() * sizeof(std::unique_ptr<ModuleProcessor>);
        b += static_cast<std::size_t>(slots) * (sizeof(TrackNode) + sizeof(BusNode)) + sizeof(MasterNode);
        b += static_cast<std::size_t>(nodeCount()) * (sizeof(GraphNode) + sizeof(ModuleProcessor*));
        b += (target.capacity() + pending.capacity() + slotOrder.capacity() + stack.capacity()) * sizeof(int);
        b += routable.capacity() + deferred.capacity() + emitted.capacity();
        b += (position.capacity() + order.capacity()) * sizeof(uint32_t);
        b += edges.capacity() * sizeof(GraphConnection);
        b += (inFirst.capacity() + inCount.capacity()) * sizeof(int) + inRoutes.capacity() * sizeof(InRoute);
        b += (inFirstNext.capacity() + inCountNext.capacity()) * sizeof(int) + inRoutesNext.capacity() * sizeof(InRoute);
        b += dependencies.capacity() * sizeof(GraphDependency);
        return b;
    }
    // Everything this graph costs: the executor's own working-memory estimate plus hostBytes().
    std::size_t bytes() const noexcept { return executor.workingBytes() + hostBytes(); }
};

// The slots at one capacity, and the mix graph and order list sized for them. Built on the control
// thread; the audio thread owns the current one and retires it when a Grow replaces it.
struct Engine::SlotTable {
    int capacity = 0;                // layer slots; slots[capacity] is the audition
    std::unique_ptr<Slot*[]> slots;  // capacity + 1, pointing into Engine::slotStore_
    std::unique_ptr<int[]> processOrder;  // capacity + 1 entries
    // capacity + 1 entries: the slots in use, ascending (audio thread; Engine::live_). The per-chunk loops
    // visit only these, so their cost follows the layers in use, not the capacity (#133).
    std::unique_ptr<int[]> live;
    std::unique_ptr<MixGraph> graph;
};

}  // namespace caw
