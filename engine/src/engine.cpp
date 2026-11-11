// Mixer implementation: the audio-thread render loop and the control-thread project diffing that feeds it.
#include "engine.h"
#include "audio_clips.h"

#include "presets.h"
#include "quality.h"
#include "builtin_components.h"
#include "graph.h"
#include "meters.h"
#include "route_math.h"
#include "caw/library/stereo.hpp"
#include "hardware.h"

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
#include "json.h"
#include "params.h"

namespace caw {

// Immutable automation prepared on the control thread and reclaimed off the audio callback.
struct Engine::AutomationData {
    std::vector<AutomationPointSpec> volume;
    std::vector<AutomationPointSpec> pan;
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
    bool overloaded = false;
    bool bus = false;
    int parentSlot = -1;
    AutomationData* automation = nullptr;
    double outL[kBlock] = {}, outR[kBlock] = {};
    ComponentChain* inserts = nullptr;  // native stereo effects after the instrument, before volume and pan
    DelayLine* delay = nullptr;         // latency compensation, after volume and pan
    SendTable* sends = nullptr;         // where the slot's sends and keys go (owned; replaced by SetSends)
    double routeGain[kMaxRoutes] = {};  // audio thread: each route's gain at the end of the last block
    bool routeOk[kMaxRoutes] = {};      // updateRouting: the route's destination runs after this slot this chunk
    bool routesStale = false;           // stopped or silent: the routes' delays hold old audio; clear them
    // A bus's input from sends this chunk (valid while recvChunk is the chunk being run).
    float recvL[kBlock] = {}, recvR[kBlock] = {};
    int64_t recvChunk = -1;
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

    // This chunk's plan (planChunk), read by the slot's graph nodes. Chunks end at every loop
    // boundary of a playing track, so one plan covers the whole chunk.
    enum class Mode : uint8_t { Idle, Bus, Silent, Play };
    Mode mode = Mode::Idle;
    double target = 0;          // mix target (0 while muted or soloed out)
    int64_t n0 = 0, repeat = 0; // sample in the layer's loop, and the pattern repeat
    const Pattern* pat = nullptr;
    bool previewing = false;    // audio thread: the track holds a preview note, or its sound is still dying away
    DeviceNotes deviceNotes;    // audio thread: the device MIDI channels' bend and pedal (API 15)
    int64_t previewQuiet = 0;   // samples the track's output has been below kPreviewQuiet
    int64_t previewTail = 0;    // samples since its last preview voice ended
    int64_t previewN = 0;       // stopped: the sample in the layer's loop that preview chunks run from
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
    void run(float* outL, float* outR, int m) noexcept {
        const size_t n = l.size();
        for (int i = 0; i < m; ++i) {
            const float dl = l[pos], dr = r[pos];
            l[pos] = outL[i];
            r[pos] = outR[i];
            outL[i] = dl;
            outR[i] = dr;
            pos = pos + 1 == n ? 0 : pos + 1;
        }
    }
};

// A slot's routes: its sends (into bus inputs) then the sidechain keys it feeds, each with its own latency
// compensation. Built on the control thread; the audio thread swaps it in (SetSends) and retires the old one.
struct Engine::SendTable {
    struct Route {
        int dest = -1;     // destination slot
        int key = -1;      // -1: a bus's input; else the component index on dest's inserts it keys
        double level = 1;
        // pre: the tap asked for; tapPre: the tap in use (audio thread). A switch fades the route out, changes
        // tap at 0 and fades back in, so it never jumps.
        bool pre = false, mute = false, tapPre = false;
        DelayLine* delay = nullptr;  // owned; null: none
    };
    Route routes[kMaxRoutes];
    int count = 0;
    bool keys = false;  // some route keys a component: the slot runs even while muted or soloed out
    SendTable() = default;
    SendTable(const SendTable&) = delete;
    SendTable& operator=(const SendTable&) = delete;
    ~SendTable() {
        for (Route& r : routes) delete r.delay;
    }
};

static_assert(ComponentChain::kMaxFrames == static_cast<uint32_t>(kBlock), "component chains run Engine blocks");

struct Engine::Cmd {
    // Install: the slot becomes a track (steps, order); its instrument and inserts come by their own commands.
    enum Type { Install, SetSteps, SetPattern, Remove, Transport, SetMaster, SetMasterChain, SetInserts, SetInstrument, SetComponentAutomation, SetDelay, SetSends, SetSendLevel, Play, Stop, AuditionOnly, ClearOverload, SetOrder, SetRouting, ConfigureBus, SetAutomation, Grow, Preview, Metronome, ReleaseTouches } type = Play;
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
    int countInBeats = 0;      // Play: beats of count-in clicks before it starts
    // Preview: what to do with preview [previewId] on [slot]: 0 note on, 1 glide to [pitch], 2 note off, 3 all off.
    int previewOp = 0;
    int32_t previewId = 0;
    double pitch = 60, vel = 1;
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
};

namespace {

constexpr double kSwapSeconds = 0.02;
constexpr double kStopSeconds = 0.01;
constexpr double kPlayTailSeconds = 0.005;   // Play after Stop: a ringing instrument fades out over this
constexpr double kPlayTailQuietSeconds = 0.1;  // ... if its track sounded within the last 0.1 s
constexpr double kPreviewGlideSeconds = 0.005;  // a held preview glides to a new pitch this fast (a bend being drawn)
constexpr float kPreviewQuiet = 1e-4f;          // -80 dB: a preview's effect tail below this has died away
constexpr double kPreviewQuietSeconds = 0.25;   // ... once it has stayed below it this long
constexpr double kPreviewTailSeconds = 30.0;    // the longest a tail (or a self-oscillating effect) keeps running
constexpr double kGainSeconds = 0.005;
constexpr double kLimitCeiling = 0.977;  // about -0.2 dBFS
// Retirements the retired queue has no room for wait in the pending list: 2 * (maxLayers() + 1) entries
// plus this slack (256 at 64 layers), so every slot can hand back a chain and its fading one at once.
constexpr int kPendingSlack = 126;
constexpr size_t kMaxProjectComponents = 256;  // native component instances in one project (tracks and master)
constexpr int64_t kMaxCompensationFrames = 1 << 15;  // latency compensation up to about 0.7 s at 48 kHz
// Grows above this many layers are not considered (node counts stay far inside uint32_t).
constexpr int kLayerCeiling = 1 << 20;

 // An upper bound on the bytes compileArrangement builds, so a huge looping clip is refused before it is expanded.
double arrangementBytes(const std::vector<ClipSpec>& clips,
    const std::map<std::string, std::shared_ptr<const Pattern>>& sources, int beatsPerBar) {
    double total = 0;
    for (const ClipSpec& clip : clips) {
        if (clip.mute) continue;
        const auto found = sources.find(clip.pattern);
        if (found == sources.end() || !found->second || found->second->notes.empty()) continue;
        const Pattern& src = *found->second;
        const double sourceLength = clip.loopSteps > 0 ? clip.loopSteps : std::max(1, src.steps(beatsPerBar));
        const double passes = clip.loop ? 2.0 + std::floor(clip.lengthSteps / sourceLength) : 1.0;
        double ratchets = 0;
        for (const PatternNote& note : src.notes) ratchets += std::max(1, static_cast<int>(note.ratchet));
        total += passes * (static_cast<double>(src.notes.size()) * sizeof(PatternNote) + 2.0 * ratchets * sizeof(PatternEvent));
    }
    return total;
}

 // Compile clip instances off the audio thread into one immutable, absolute-time event stream.
std::shared_ptr<const Pattern> compileArrangement(
    const std::vector<ClipSpec>& clips,
    const std::map<std::string, std::shared_ptr<const Pattern>>& sources,
    int beatsPerBar,
    int projectLengthSteps) {
    auto out = std::make_shared<Pattern>();
    out->name = "Arrangement";
    out->lengthSteps = projectLengthSteps;
    for (const ClipSpec& clip : clips) {
        if (clip.mute) continue;  // a muted clip plays nothing; the layer still follows the arrangement
        const auto found = sources.find(clip.pattern);
        if (found == sources.end() || !found->second) continue;
        const Pattern& src = *found->second;
        if (src.notes.empty()) continue;  // nothing to place, however often the clip repeats it
        // The clip's own loop point (0: the pattern's length): notes past it never play, and a loop past the
        // pattern's end plays silence up to it before repeating.
        const int sourceLength = clip.loopSteps > 0 ? clip.loopSteps : std::max(1, src.steps(beatsPerBar));
        double sourcePos = static_cast<double>(clip.sourceOffsetSteps);
        int consumed = 0;
        int timeline = clip.startSteps;
        while (consumed < clip.lengthSteps) {
            if (sourcePos >= sourceLength) {
                if (!clip.loop) break;
                sourcePos = std::fmod(sourcePos, static_cast<double>(sourceLength));
            }
            const int segment = static_cast<int>(std::min<double>(
                clip.lengthSteps - consumed, sourceLength - sourcePos));
            if (segment <= 0) break;
            const double sourceEnd = sourcePos + segment;
            const size_t noteBase = out->notes.size();
            struct RatchetSpan { double start, end; uint16_t sub; };
            std::vector<std::vector<RatchetSpan>> eventSpans;
            std::vector<int> remap(src.notes.size(), -1);
            for (size_t i = 0; i < src.notes.size(); ++i) {
                const PatternNote& original = src.notes[i];
                const double originalEnd = original.at + original.len;
                if (originalEnd <= sourcePos || original.at >= sourceEnd) continue;
                const double clippedStart = std::max(original.at, sourcePos);
                const double clippedEnd = std::min(originalEnd, sourceEnd);
                const bool trimmedAtStart = clippedStart > original.at;
                const bool trimmedAtEnd = clippedEnd < originalEnd;
                // Intersect each ratchet with the source window. This preserves both sustained
                // note tails and the original ratchet grid when a clip starts or ends mid-note.
                std::vector<RatchetSpan> spans;
                const double ratchetLength = original.len / original.ratchet;
                for (int q = 0; q < original.ratchet; ++q) {
                    const double ratchetStart = original.at + ratchetLength * q;
                    const double ratchetEnd = original.at + ratchetLength * (q + 1);
                    const double start = std::max(ratchetStart, sourcePos);
                    const double end = std::min(ratchetEnd, sourceEnd);
                    if (end > start)
                        spans.push_back({timeline + (start - sourcePos), timeline + (end - sourcePos),
                                         static_cast<uint16_t>(q)});
                }
                if (spans.empty()) continue;
                PatternNote note = original;
                note.at = timeline + (clippedStart - sourcePos);
                note.len = clippedEnd - clippedStart;
                // The note's expression (bend, vibrato, pressure, timbre) comes along: `extra` indexes the
                // source's list, so it is copied into the arrangement's and pointed there.
                if (original.extra >= 0 && static_cast<size_t>(original.extra) < src.expressions.size()) {
                    note.extra = static_cast<int>(out->expressions.size());
                    out->expressions.push_back(src.expressions[static_cast<size_t>(original.extra)]);
                } else {
                    note.extra = -1;
                }
                if (trimmedAtStart || trimmedAtEnd) note.slideFrom = note.slideTo = -1;
                remap[i] = static_cast<int>(out->notes.size());
                out->notes.push_back(note);
                eventSpans.push_back(std::move(spans));
                out->lastEnd = std::max(out->lastEnd, note.at + note.len);
            }
            for (size_t i = 0; i < remap.size(); ++i) {
                if (remap[i] < 0) continue;
                const PatternNote& original = src.notes[i];
                PatternNote& note = out->notes[static_cast<size_t>(remap[i])];
                if (original.slideFrom >= 0 && static_cast<size_t>(original.slideFrom) < remap.size() &&
                    remap[static_cast<size_t>(original.slideFrom)] >= 0)
                    note.slideFrom = remap[static_cast<size_t>(original.slideFrom)];
                if (original.slideTo >= 0 && static_cast<size_t>(original.slideTo) < remap.size() &&
                    remap[static_cast<size_t>(original.slideTo)] >= 0)
                    note.slideTo = remap[static_cast<size_t>(original.slideTo)];
            }
            for (size_t i = 0; i < eventSpans.size(); ++i) {
                const uint32_t noteIndex = static_cast<uint32_t>(noteBase + i);
                for (const RatchetSpan& span : eventSpans[i]) {
                    out->events.push_back({span.start, noteIndex, span.sub, true});
                    out->events.push_back({span.end, noteIndex, span.sub, false});
                }
            }
            timeline += segment;
            consumed += segment;
            sourcePos = 0;
            if (!clip.loop) break;
        }
    }
    std::stable_sort(out->events.begin(), out->events.end(), [](const PatternEvent& a, const PatternEvent& b) {
        if (a.step != b.step) return a.step < b.step;
        // Release notes ending on this sample before starting notes at the same sample.
        // This allows a just-freed voice to be reused at clip and note boundaries.
        return !a.on && b.on;
    });
    return out;
}

double bitsToDouble(uint64_t b) { return std::bit_cast<double>(b); }
uint64_t doubleToBits(double d) { return std::bit_cast<uint64_t>(d); }

double automationValue(const std::vector<AutomationPointSpec>& points, double at, double fallback) noexcept {
    return automationLaneValue(points.data(), points.size(), at, fallback);  // the one lane rule (params.h)
}


void storeMax(std::atomic<float>& a, float v) {
    float cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
    }
}

}  // namespace

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

    // capacity: layer slots; the graph also routes the audition slot after them.
    MixGraph(Engine& e, int capacity, double sampleRate, const EngineResourceBudget& engineBudget)
        : slots(capacity + 1), master(capacity + 1),
          target(static_cast<size_t>(slots), 0), routable(static_cast<size_t>(slots), 0),
          pending(static_cast<size_t>(slots) + 1, 0),
          deferred(static_cast<size_t>(slots) + 1, 0), emitted(static_cast<size_t>(slots) + 1, 0),
          slotOrder(static_cast<size_t>(slots), 0), stack(static_cast<size_t>(slots) + 1, 0), position(static_cast<size_t>(slots) + 1, UINT32_MAX),
          order(static_cast<size_t>(nodeCount()), 0), edges(static_cast<size_t>(maxEdges()), GraphConnection{}) {
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
                                   static_cast<uint32_t>(slots)) != GraphError::Ok)
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

uint32_t Engine::mixGraphNodesRun() const noexcept { return mixGraph_->executor.runCount(); }
int Engine::slotsScannedPerChunk() const noexcept { return liveCount_; }

// Audio thread: slot i joins the in-use list (kept ascending, so loops over it run in index order as
// the full scans did). It leaves in processChunk once nothing is left for a loop to do there.
// Stopped: an audio track monitoring its input runs as a held preview would, so its input is heard through its chain.
void Engine::wakeMonitors() noexcept {
    for (int i = 0; i < slotCount_; ++i) {
        Slot& s = slotAt(i);
        if (!s.active || !s.track || !s.instrument || s.previewing || !s.instrument->monitorsStopped()) continue;
        if (s.instrumentIdle) {
            s.instrument->reset();
            s.instrument->notes()->forget(false);
            s.instrument->notes()->clearEvents();
            s.instrumentIdle = false;
        }
        s.previewing = true;
        s.previewQuiet = s.previewTail = 0;
        previewing_ = true;
        markLive(i);
    }
}

void Engine::markLive(int i) noexcept {
    Slot& s = slotAt(i);
    if (s.listed) return;
    s.listed = true;
    int k = liveCount_;
    while (k > 0 && live_[k - 1] > i) {
        live_[k] = live_[k - 1];
        --k;
    }
    live_[k] = i;
    ++liveCount_;
}

void Engine::bindTable() noexcept {
    SlotTable& t = *table_;
    slots_ = t.slots.get();
    mixGraph_ = t.graph.get();
    processOrder_ = t.processOrder.get();
    live_ = t.live.get();
    capacity_ = t.capacity;
    auditionSlot_ = t.capacity;
    slotCount_ = t.capacity + 1;
}

Engine::Slot& Engine::ctlSlot(int i) noexcept { return *ctlTable_->slots[i]; }

Engine::Engine(double sampleRate)
    : Engine(sampleRate, makeEngineResourceBudget(detectHardwareProfile())) {}

Engine::Engine(double sampleRate, EngineResourceBudget resourceBudget)
    : sr_(sampleRate),
      resourceBudget_(resourceBudget),
      cmds_(new Spsc<Cmd, 1024>()),
      retired_(new Spsc<Retired, 1024>()),
      masterScope_(new std::atomic<float>[kScopeSize]),
      loudness_(std::make_unique<LoudnessMeter>()) {
    for (int i = 0; i < kScopeSize; ++i) masterScope_[i].store(0);
    midiPending_.reset(new PendingMidi[Midi2InputQueue::kCapacity]);
    loudness_->prepare(sampleRate);
    audioIn_ = std::make_unique<LiveAudio>(sampleRate);
    masterCorrelation_.prepare(sampleRate);
    registerBuiltinComponents(nativeModules_);  // the Library's stereo tools, ready in every chain
    ctlSr_ = sampleRate;
    constexpr int initial = kInitialLayerCapacity;
    auto first = std::make_unique<SlotTable>();
    first->capacity = initial;
    first->slots.reset(new Slot*[static_cast<size_t>(initial + 1)]);
    first->processOrder.reset(new int[static_cast<size_t>(initial + 1)]());
    first->live.reset(new int[static_cast<size_t>(initial + 1)]());
    slotStore_.reserve(static_cast<size_t>(initial + 1));
    for (int s = 0; s <= initial; ++s) {
        slotStore_.push_back(std::make_unique<Slot>());
        slotStore_.back()->correlation.prepare(sr_);
        Slot& slot = *slotStore_.back();
        slot.index = s;
        for (int i = 0; i < kScopeSize; ++i) slot.scope[i].store(0);
        first->slots[s] = &slot;
    }
    first->graph.reset(new MixGraph(*this, initial, sampleRate, resourceBudget_));

    // maxLayers(): the largest capacity a grow can reach inside the graph-working budget. A grow
    // keeps the old table and graph alive until the audio thread retires them, so the peak is the
    // old graph + the new graph + the slots: bounded by twice the new graph. The graph's cost is
    // measured, from the executor's own working-memory estimate, at three capacities; it grows
    // with the square of the capacity (every bus and the master reserve room for every slot as a
    // source), so the three fix a quadratic exactly.
    {
        const double g1 = static_cast<double>(MixGraph(*this, 1, sampleRate, resourceBudget_).bytes());
        const double g2 = static_cast<double>(MixGraph(*this, 2, sampleRate, resourceBudget_).bytes());
        const double g64 = static_cast<double>(first->graph->bytes());
        const double d = g2 - g1;
        const double q = ((g64 - g2) - 62.0 * d) / 3906.0;  // (64^2 - 2^2) - 62 * (2^2 - 1^2)
        const double b = d - 3.0 * q;
        const double a = g1 - b - q;
        const double perSlot = static_cast<double>(sizeof(Slot) + sizeof(std::unique_ptr<Slot>) + sizeof(Slot*) +
                                                   2 * sizeof(int) + 2 * sizeof(Retired));
        const double budget = static_cast<double>(resourceBudget_.graphWorkingBytes);
        auto fits = [&](int c) {
            const double cap = c;
            return 2.0 * std::max(0.0, a + b * cap + q * cap * cap) + perSlot * (cap + 1.0) <= budget;
        };
        int lo = initial;  // fits, or is the floor every Engine keeps (the mix graph's own budget floor)
        if (fits(initial)) {
            int hi = initial * 2;  // the first capacity found not to fit
            while (hi < kLayerCeiling && fits(hi)) { lo = hi; hi *= 2; }
            if (hi >= kLayerCeiling) {
                hi = kLayerCeiling;
                if (fits(hi)) lo = hi;
            }
            while (hi - lo > 1) {
                const int mid = lo + (hi - lo) / 2;
                (fits(mid) ? lo : hi) = mid;
            }
        }
        maxLayers_ = lo;
    }
    // The pending list holds two retirements per slot at the largest capacity, so the slots can hand back what
    // they replaced (the retired queue is an Spsc fixed at 1024) while the control thread is slow to drain.
    pendingMax_ = 2 * (maxLayers_ + 1) + kPendingSlack;
    if (pendingMax_ < 2 * (maxLayers_ + 1)) throw std::logic_error("pending list cannot hold two retirements per slot");
    pending_.reset(new Retired[static_cast<size_t>(pendingMax_)]);
    table_ = std::move(first);
    bindTable();
    ctlTable_ = table_.get();
    ctlCapacity_.store(initial, std::memory_order_relaxed);
    updateTiming();
    ctlLoopLen_ = loopLen_;
    loopLenFlag_.store(loopLen_);
}

Engine::~Engine() {
    // No audio thread runs any more: free everything directly.
    Cmd c;
    while (cmds_->pop(c)) {
        delete c.pattern;
        delete c.automation;
        delete c.orderList;
        delete c.table;
        delete c.masterChain;
        delete c.componentAutomation;
        delete c.delay;
        delete c.sends;
    }
    Retired r;
    while (retired_->pop(r)) {
        delete r.pattern;
        delete r.automation;
        delete r.order;
        delete r.table;
        delete r.masterChain;
        delete r.componentAutomation;
        delete r.delay;
        delete r.sends;
    }
    for (int i = 0; i < pendingCount_; ++i) {
        delete pending_[i].pattern;
        delete pending_[i].automation;
        delete pending_[i].order;
        delete pending_[i].table;
        delete pending_[i].masterChain;
        delete pending_[i].componentAutomation;
        delete pending_[i].delay;
        delete pending_[i].sends;
    }
    delete masterChain_;
    masterChain_ = nullptr;
    delete masterFading_;
    masterFading_ = nullptr;
    for (const auto& slot : slotStore_) {
        delete slot->inserts;
        delete slot->insertsFading;
        delete slot->instrument;
        delete slot->instrumentFading;
        delete slot->delayFading;
        delete slot->delay;
        delete slot->sends;
        delete slot->pattern;
        delete slot->automation;
    }
}

// ===================== control thread =====================

void Engine::drainRetired() {
    Retired r;
    while (retired_->pop(r)) {
        delete r.pattern;
        delete r.automation;
        delete r.order;
        delete r.table;
        delete r.masterChain;
        delete r.componentAutomation;
        delete r.delay;
        delete r.sends;
        if (r.freed) r.freed->ctlBusy = false;
    }
}

bool Engine::send(const Cmd& c) {
    // Reclaim completed objects before publishing more work. This also makes room
    // for the audio thread to transfer any pending retirements into the SPSC queue.
    drainRetired();
    if (offlineControl_) applyCommands();
    // The audio thread empties the queue every callback; offline installation drains it synchronously.
    for (int tries = 0; !cmds_->push(c); ++tries) {
        drainRetired();
        if (offlineControl_) applyCommands();
        if (tries > 2000) {
            delete c.pattern;  // audio stalled; drop rather than hang the app
            delete c.automation;
            delete c.orderList;
            delete c.table;
            delete c.masterChain;
            delete c.componentAutomation;
            delete c.delay;
            delete c.sends;
            return false;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    if (offlineControl_) applyCommands();
    return true;
}

int Engine::freeSlot() {
    for (int s = 0; s < ctlTable_->capacity; ++s)
        if (!ctlSlot(s).ctlBusy) {
            ctlSlot(s).ctlBusy = true;
            return s;
        }
    return -1;
}

// Control thread, under ctl_: a table of `capacity` layer slots that keeps every existing Slot
// (layer slots at their indices, the audition moved to the new last one), a mix graph sized for
// it; sent to the audio thread as one Grow command.
std::string Engine::grow(int capacity) {
    SlotTable& old = *ctlTable_;
    if (capacity <= old.capacity) return {};
    if (capacity > maxLayers_)
        return "the project needs " + std::to_string(capacity) + " layer slots; this device's memory budget allows at most " +
               std::to_string(maxLayers_);
    const size_t storeBefore = slotStore_.size();
    auto rollBack = [&] {  // nothing new reached the audio thread: drop it again
        slotStore_.resize(storeBefore);
    };
    auto t = std::make_unique<SlotTable>();
    try {
        t->capacity = capacity;
        t->slots.reset(new Slot*[static_cast<size_t>(capacity + 1)]);
        t->processOrder.reset(new int[static_cast<size_t>(capacity + 1)]());
        t->live.reset(new int[static_cast<size_t>(capacity + 1)]());
        for (int s = 0; s < old.capacity; ++s) t->slots[s] = old.slots[s];
        t->slots[capacity] = old.slots[old.capacity];  // the audition; the audio thread sets its index
        slotStore_.reserve(storeBefore + static_cast<size_t>(capacity - old.capacity));
        for (int s = old.capacity; s < capacity; ++s) {
            slotStore_.push_back(std::make_unique<Slot>());
            slotStore_.back()->correlation.prepare(sr_);
            Slot& slot = *slotStore_.back();
            slot.index = s;
            for (int i = 0; i < kScopeSize; ++i) slot.scope[i].store(0);
            t->slots[s] = &slot;
        }
        t->graph.reset(new MixGraph(*this, capacity, sr_, resourceBudget_));
        // The budget holds the old graph and the new one at once (maxLayers() allows for that).
        const uint64_t perSlot = sizeof(Slot) + sizeof(std::unique_ptr<Slot>) + sizeof(Slot*) + 2 * sizeof(int) +
                                 2 * sizeof(Retired);
        const uint64_t peak = static_cast<uint64_t>(old.graph->bytes()) + t->graph->bytes() +
                              perSlot * static_cast<uint64_t>(capacity + 1);
        if (peak > resourceBudget_.graphWorkingBytes) {
            rollBack();
            return "growing to " + std::to_string(capacity) + " layer slots needs " + std::to_string(peak) +
                   " bytes of graph working memory; this device's budget is " +
                   std::to_string(resourceBudget_.graphWorkingBytes);
        }
    } catch (const std::bad_alloc&) {
        rollBack();
        return "unable to allocate " + std::to_string(capacity) + " layer slots within the hardware-derived memory budget";
    } catch (const std::runtime_error&) {
        rollBack();
        return "the mix graph for " + std::to_string(capacity) + " layer slots could not be prepared";
    }
    const int oldAudition = old.capacity;
    Cmd c;
    c.type = Cmd::Grow;
    c.table = t.release();
    SlotTable* sent = c.table;
    if (!send(c)) {  // send() freed the table
        rollBack();
        return "audio command queue is not accepting project updates";
    }
    ctlTable_ = sent;
    ctlCapacity_.store(capacity, std::memory_order_relaxed);
    for (auto& [id, ls] : layers_)
        if (ls.slot == oldAudition) ls.slot = capacity;  // the audition's layer state follows it
    return {};
}

void Engine::writeMix(int slot, double vol, double pan, bool mute, bool solo) {
    Slot& s = ctlSlot(slot);
    s.vol.store(doubleToBits(vol), std::memory_order_relaxed);
    s.pan.store(doubleToBits(pan), std::memory_order_relaxed);
    s.mute.store(mute, std::memory_order_relaxed);
    s.solo.store(solo, std::memory_order_relaxed);
}

std::string Engine::setProjectJson(std::string_view json) {
    ProjectSpec p;
    std::string err;
    if (!parseProject(json, p, err)) return "{\"ok\":false,\"error\":\"" + jsonEscape(err) + "\",\"modules\":{}}";
    return setProject(p);
}

ModuleLoadResult Engine::loadNativeComponent(
    const std::string& path, const std::string& expectedId, NativeModuleTrust trust) {
    std::lock_guard<std::mutex> lock(ctl_);
    return nativeModules_.loadSharedLibrary(path, expectedId, trust);
}

ModuleLoadResult Engine::reloadNativeComponent(
    const std::string& path, const std::string& expectedId, NativeModuleTrust trust) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    // Every chain that uses the component, rebuilt before anything is sent: one that can't be keeps the old build.
    struct Rebuilt {
        int slot;  // -1: the master
        LayerState* layer;
        std::unique_ptr<ComponentChain> chain;
    };
    ModuleLoadResult result = nativeModules_.loadSharedLibrary(path, expectedId, trust, true);
    if (!result.success) return result;
    std::vector<Rebuilt> rebuilt;
    std::string error;
    const BuildingQuality building(&quality_);
    const BuildingLiveAudio buildingInput(audioIn_.get());
    auto rebuild = [&](ComponentChain* old, int slot, LayerState* layer, const std::string& layerId) {
        if (!old || !old->uses(expectedId)) return true;
        const std::vector<ComponentSpec> specs = old->currentSpecs();
        auto chain = old->instrument() ? ComponentChain::buildInstrument(nativeModules_, specs.front(), sr_, error)
                                       : ComponentChain::build(nativeModules_, specs, sr_, error);
        if (!chain) return false;
        delete chain->swapAutomation(chain->automationFor(ctlAutomation_, layerId).release());
        rebuilt.push_back({slot, layer, std::move(chain)});
        return true;
    };
    bool ok = rebuild(ctlMasterChain_, -1, nullptr, "");
    for (auto& [id, ls] : layers_) {
        if (ok && ls.slot >= 0 && !ls.bus) ok = rebuild(ls.inserts, ls.slot, &ls, id);
        if (ok && ls.slot >= 0 && !ls.bus) ok = rebuild(ls.instrument, ls.slot, &ls, id);
    }
    if (!ok) {
        // The new build is loaded but can't take over (its ports changed, it failed to activate, ...).
        result.success = false;
        result.error = ModuleLoadError::InvalidDescriptor;
        result.message = "The rebuild is now the loaded build (new instances use it), but the playing project keeps "
                         "the previous build until it is fixed: " + error;
        return result;
    }
    for (Rebuilt& r : rebuilt) {
        Cmd c;
        const bool instrument = r.chain->instrument();
        c.type = r.slot < 0 ? Cmd::SetMasterChain : instrument ? Cmd::SetInstrument : Cmd::SetInserts;
        c.slot = r.slot;
        ComponentChain* sent = r.chain.release();
        c.masterChain = sent;
        if (!send(c)) continue;  // send() freed it; the old build plays on there
        if (r.layer) (instrument ? r.layer->instrument : r.layer->inserts) = sent;
        else ctlMasterChain_ = sent;
    }
    std::map<std::string, std::vector<std::string>> warnings;
    updateCompensation(warnings);  // the rebuild may add a different latency
    return result;
}

bool Engine::unloadNativeComponent(const std::string& id) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    return nativeModules_.unload(id);
}

std::string Engine::nativeComponentsJson() {
    std::lock_guard<std::mutex> lock(ctl_);
    std::string json = "{\"ok\":true,\"components\":[";
    bool first = true;
    // Built-in components first, marked so the app can tell them from loaded ones (they need no trust).
    for (const ModuleDescriptor* d : nativeModules_.builtinComponents()) {
        std::string one = moduleDescriptorJson(*d);
        std::string head = first ? "{\"builtin\":true," : ",{\"builtin\":true,";
        if (!builtinPresets(d->id).empty()) head += "\"presets\":" + builtinPresetsJson(d->id) + ",";
        json += head + one.substr(1);
        first = false;
    }
    for (const ModuleDescriptor* d : nativeModules_.loadedComponents()) {
        json += (first ? "" : ",") + moduleDescriptorJson(*d);
        first = false;
    }
    return json + "]}";
}

std::unique_ptr<ModuleProcessor> Engine::createNativeComponent(const std::string& id) {
    std::lock_guard<std::mutex> lock(ctl_);
    return nativeModules_.create(id);
}

void Engine::setQuality(int quality) noexcept {
    quality_.store(quality < kQualityEco ? kQualityEco : (quality > kQualityHigh ? kQualityHigh : quality), std::memory_order_relaxed);
}

std::string Engine::setProject(const ProjectSpec& p) {
    return setProjectImpl(p, false);
}

std::string Engine::setProjectOffline(const ProjectSpec& p) {
    return setProjectImpl(p, true);
}

std::string Engine::setProjectImpl(const ProjectSpec& p, bool offline) {
    {
        bool monitors = false;  // an audio track that monitors its input runs while stopped (wakeMonitors)
        for (const LayerSpec& l : p.layers)
            monitors = monitors || (l.instrument.audioTrack && l.instrument.audioTrack->input.present &&
                                    l.instrument.audioTrack->input.monitor != 0);
        monitorWanted_.store(monitors, std::memory_order_relaxed);
    }
    const BuildingQuality building(&quality_);
    const BuildingLiveAudio buildingInput(audioIn_.get());
    {
        // Sends to buses only, keys from playing layers, and no loops (parseProject checks it too; this covers
        // projects built in code).
        std::string error;
        if (!validateRouting(p, error)) return "{\"ok\":false,\"error\":\"" + jsonEscape(error) + "\",\"modules\":{}}";
    }
    // The synths that became Flagship presets (2026-11-10, one synth): an old project's track plays Flagship with
    // the matching preset and its knobs mapped, and its lanes on those knobs move Flagship's.
    if (std::any_of(p.layers.begin(), p.layers.end(), [](const LayerSpec& l) { return isLegacyInstrument(l.instrument.id); })) {
        ProjectSpec migrated = p;
        for (LayerSpec& l : migrated.layers) {
            if (!isLegacyInstrument(l.instrument.id)) continue;
            const std::string legacy = l.instrument.id;
            migrateLegacyInstrument(l.instrument.id, l.instrument.params);
            l.instrument.hasState = false;  // the old synths saved no state
            auto& lanes = migrated.automation;
            for (auto it = lanes.begin(); it != lanes.end();) {
                if (it->targetType == "instrument" && it->moduleId == l.id) {
                    it->target = migratedLegacyParameter(legacy, it->target);
                    if (it->target.empty()) {  // an old knob with no Flagship knob in its units
                        it = lanes.erase(it);
                        continue;
                    }
                }
                ++it;
            }
        }
        return setProjectImpl(migrated, offline);
    }
    std::lock_guard<std::mutex> lock(ctl_);
    offlineControl_ = offline;
    struct OfflineControlReset {
        bool& active;
        ~OfflineControlReset() { active = false; }
    } reset{offlineControl_};
    drainRetired();

    // Native component chains: the master's and each track's inserts. Components must already be
    // explicitly loaded through the trust-gated Engine API. Every chain is built (and activated) here,
    // before anything is sent, so a component that can't run refuses the whole update. A chain with
    // the same components in the same order is kept, running state and all, and only takes values.
    std::unique_ptr<ComponentChain> nextMasterChain;
    const bool keepMasterChain = ctlMasterChain_ && ctlMasterChain_->sameComponents(p.masterComponents, sr_);
    std::map<std::string, std::unique_ptr<ComponentChain>> nextInserts;
    std::map<std::string, std::unique_ptr<ComponentChain>> nextInstruments;  // native instruments to send
    uint64_t masterChainBytes = 0;  // every component chain the project holds, for the state budget
    {
        auto charge = [&](const std::vector<ComponentSpec>& specs) {
            size_t parameters = 0;
            for (const ComponentSpec& c : specs)
                if (const ModuleDescriptor* d = nativeModules_.find(c.id)) parameters += d->parameterCount;
            masterChainBytes += ComponentChain::estimateBytes(specs.size(), parameters);
        };
        if (!p.masterComponents.empty()) charge(p.masterComponents);
        size_t total = p.masterComponents.size();
        for (const LayerSpec& l : p.layers) {
            if (!(l.folder && !l.busEnabled) && !l.components.empty()) {  // tracks and bus folders run inserts
                charge(l.components);
                total += l.components.size();
            }
            if (!l.folder && l.hasInstrument) {
                charge({l.instrument});
                masterChainBytes += sizeof(NoteEvents) + NoteEvents::kBytes;  // its note list and held notes
                ++total;
            }
            if (!l.folder && !l.noteComponents.empty())  // per-note FX (#127): each slot chain and the overflow chain
                for (int k = 0; k <= noteFxSlots(l.noteVoices); ++k) {
                    charge(l.noteComponents);
                    total += l.noteComponents.size();
                }
        }
        if (p.auditionOnly) {  // the preview's own chain, as a track's
            if (!p.auditionComponents.empty()) {
                charge(p.auditionComponents);
                total += p.auditionComponents.size();
            }
            if (p.hasAuditionInstrument) {
                charge({p.auditionInstrument});
                masterChainBytes += sizeof(NoteEvents) + NoteEvents::kBytes;
                ++total;
            }
        }
        // Each instance may allocate what it likes when activated; the cap bounds how many there are.
        if (total > kMaxProjectComponents)
            return "{\"ok\":false,\"error\":\"the project uses " + std::to_string(total) +
                   " native components; at most " + std::to_string(kMaxProjectComponents) + " can run\",\"modules\":{}}";
        if (masterChainBytes > resourceBudget_.projectStateBytes)
            return R"({"ok":false,"error":"native component chains exceed this Engine's project-state memory budget","modules":{}})";
        std::string error;
        if (!keepMasterChain && !p.masterComponents.empty()) {
            nextMasterChain = ComponentChain::build(nativeModules_, p.masterComponents, sr_, error);
            if (!nextMasterChain)
                return "{\"ok\":false,\"error\":\"master: " + jsonEscape(error) + "\",\"modules\":{}}";
        }
        for (const LayerSpec& l : p.layers) {
            if ((l.folder && !l.busEnabled) || l.components.empty()) continue;  // organization-only folders run none
            auto it = layers_.find(l.id);
            // A layer that turns from a track into a bus (or back) starts its inserts afresh: its slot drops them.
            if (it != layers_.end() && it->second.inserts && it->second.bus == l.folder &&
                it->second.inserts->sameComponents(l.components, sr_))
                continue;
            auto chain = ComponentChain::build(nativeModules_, l.components, sr_, error);
            if (!chain)
                return "{\"ok\":false,\"error\":\"layer '" + jsonEscape(l.id) + "': " + jsonEscape(error) +
                       "\",\"modules\":{}}";
            nextInserts[l.id] = std::move(chain);
        }
        for (const LayerSpec& l : p.layers) {
            if (l.folder || !l.hasInstrument) continue;
            auto it = layers_.find(l.id);
            if (it != layers_.end() && it->second.instrument && it->second.instrument->sameComponents({l.instrument}, sr_))
                continue;
            auto instrument = ComponentChain::buildInstrument(nativeModules_, l.instrument, sr_, error);
            if (!instrument)
                return "{\"ok\":false,\"error\":\"layer '" + jsonEscape(l.id) + "' instrument: " + jsonEscape(error) +
                       "\",\"modules\":{}}";
            nextInstruments[l.id] = std::move(instrument);
        }
        // Per-note FX (#127, note_fx_host.cpp): built here too, so one that can't run refuses the update.
        if (const std::string why = noteFx_->prepare(nativeModules_, p, sr_); !why.empty())
            return "{\"ok\":false,\"error\":\"" + jsonEscape(why) + "\",\"modules\":{}}";
        if (p.auditionOnly) {
            const std::string id = "\1audition";
            auto it = layers_.find(id);
            if (!p.auditionComponents.empty() &&
                !(it != layers_.end() && it->second.inserts && it->second.inserts->sameComponents(p.auditionComponents, sr_))) {
                auto chain = ComponentChain::build(nativeModules_, p.auditionComponents, sr_, error);
                if (!chain)
                    return "{\"ok\":false,\"error\":\"audition: " + jsonEscape(error) + "\",\"modules\":{}}";
                nextInserts[id] = std::move(chain);
            }
            if (p.hasAuditionInstrument &&
                !(it != layers_.end() && it->second.instrument && it->second.instrument->sameComponents({p.auditionInstrument}, sr_))) {
                auto instrument = ComponentChain::buildInstrument(nativeModules_, p.auditionInstrument, sr_, error);
                if (!instrument)
                    return "{\"ok\":false,\"error\":\"audition instrument: " + jsonEscape(error) + "\",\"modules\":{}}";
                nextInstruments[id] = std::move(instrument);
            }
        }
    }
    // Layer slots: refuse a project the budget cannot hold, then grow before any layer is sent, so
    // every command below uses the new table. A folder without a bus takes no slot.
    {
        int layerCount = 0;
        for (const LayerSpec& l : p.layers) layerCount += !(l.folder && !l.busEnabled);
        if (layerCount > maxLayers_)
            return "{\"ok\":false,\"error\":\"project has " + std::to_string(layerCount) +
                   " layers; this device's memory budget allows at most " + std::to_string(maxLayers_) +
                   "\",\"modules\":{}}";
        // Slots still busy (layers that stay, or are fading out) plus one per layer that has none yet.
        int needed = 0;
        for (int s = 0; s < ctlTable_->capacity; ++s) needed += ctlSlot(s).ctlBusy;
        for (const LayerSpec& l : p.layers) {
            if (l.folder && !l.busEnabled) continue;
            auto it = layers_.find(l.id);
            if (it == layers_.end() || it->second.slot < 0) ++needed;
        }
        if (needed > ctlTable_->capacity) {
            const std::string error = grow(std::min(maxLayers_, std::max(needed, 2 * ctlTable_->capacity)));
            if (!error.empty()) return "{\"ok\":false,\"error\":\"" + jsonEscape(error) + "\",\"modules\":{}}";
        }
    }
    const int slotCount = ctlTable_->capacity + 1;
    const int auditionSlot = ctlTable_->capacity;

    // Transport first, so new layers start with the right timing.
    Cmd t;
    t.type = Cmd::Transport;
    t.bpm = p.bpm;
    t.beatsPerBar = p.beatsPerBar;
    t.loopSteps = p.loopSteps();
    t.loopRange = p.loopRange && p.loopEndSteps > p.loopStartSteps && p.loopEndSteps <= p.loopSteps();
    t.loopFromSteps = p.loopStartSteps;
    t.loopToSteps = p.loopEndSteps;
    t.seed = p.seed;
    t.master = p.master;
    if (!send(t))
        return "{\"ok\":false,\"error\":\"audio command queue is not accepting project updates\",\"modules\":{}}";
    const double stepLen = 60.0 * ctlSr_ / (p.bpm * 4.0);
    ctlLoopLen_ = static_cast<int64_t>(std::floor(p.loopSteps() * stepLen + 0.5));

    const auto projectAutomation = std::make_shared<const std::vector<ProjectAutomationLaneSpec>>(p.automation);
    ctlAutomation_ = projectAutomation;

    // Modules are patterns (note clips): parse the changed ones. A broken one keeps its last good version playing.
    bool allOk = true;
    std::map<std::string, ModuleState> next;
    for (const ModuleSpec& m : p.modules) {
        ModuleState st;
        auto it = modules_.find(m.id);
        if (it != modules_.end()) st = it->second;
        if (it == modules_.end() || st.source != m.source || (!st.pattern && st.error.empty())) {
            PatternResult r = parsePattern(m.source);
            st.source = m.source;
            if (r.pattern) {
                st.pattern = r.pattern;
                st.error.clear();
                st.line = st.col = 0;
            } else {
                st.error = r.error;
                st.line = r.line;
                st.col = r.col;
            }
        }
        if (!st.error.empty()) allOk = false;
        next[m.id] = std::move(st);
    }
    modules_ = std::move(next);

    // Layers: diff against what the audio thread has, sending only what changed.
    struct Want {
        std::string id;
        std::string pattern;
        int steps;
        double vol, pan;
        bool mute, solo;
        int order;
        std::vector<ClipSpec> clips;
        std::vector<AutomationLaneSpec> automation;
        std::string parentId;
        bool bus = false;
        const std::vector<ComponentSpec>* components = nullptr;  // the layer's native inserts
        const ComponentSpec* instrument = nullptr;  // the layer's native instrument, if any
    };
    std::vector<Want> wants;
    int order = 0;
    if (p.auditionOnly) {
        wants.push_back({"\1audition", p.auditionPattern, p.auditionSteps, 0.8, 0.0, false, false, 100000, {}, {}, "", false,
                         &p.auditionComponents, p.hasAuditionInstrument ? &p.auditionInstrument : nullptr});
    }
    order_.clear();
    for (const LayerSpec& l : p.layers) {
        order_.push_back(l.id);
        wants.push_back({l.id, l.pattern, l.lengthSteps, l.volume, l.pan, l.mute, l.solo, ++order, l.clips, l.automation, l.parentId, l.folder && l.busEnabled, &l.components,
                         l.hasInstrument && !l.folder ? &l.instrument : nullptr});
    }

    // Pass 1: whether each layer plays (a track needs an instrument), its notes, and its slot.
    struct Planned {
        Want w;
        LayerState ls;
        std::shared_ptr<const Pattern> pattern;
        std::string arrangementSig;
        std::string automationSig;
        bool track = false;  // a native instrument plays the layer's notes
    };
    std::vector<Planned> plan;
    std::map<std::string, LayerState> nextLayers;
    std::map<std::string, std::vector<std::string>> warnings;
    // A native component chain's automation lanes: a chain about to be sent takes its table now (the
    // audio thread doesn't have it yet); a kept chain gets a new table only when its lanes changed.
    auto attachAutomation = [&](ComponentChain& chain, const std::string& layer) {
        delete chain.swapAutomation(chain.automationFor(projectAutomation, layer).release());
    };
    auto updateAutomation = [&](int slot, ComponentChain& chain, const std::string& layer, std::string& key) {
        std::string next = ComponentChain::automationKey(p.automation, layer, chain.instrument() ? "instrument" : "component");
        if (next == key) return;
        Cmd c;
        c.type = Cmd::SetComponentAutomation;
        c.slot = slot;
        c.flag = chain.instrument();
        c.componentAutomation = chain.automationFor(projectAutomation, layer).release();
        if (send(c)) {
            key = std::move(next);
        } else {
            allOk = false;
            warnings["project"].push_back("audio command queue rejected a native component automation update");
        }
    };
    for (const auto& [id, st] : modules_) {
        if (!st.pattern) continue;
        const int steps = st.pattern->steps(p.beatsPerBar);
        int late = 0;
        for (const PatternNote& n : st.pattern->notes) late += n.at >= steps;
        if (late > 0)
            warnings[id].push_back(std::to_string(late) + " note" + (late == 1 ? " starts" : "s start") +
                                   " after the pattern's length and never play" + (late == 1 ? "s" : ""));
    }
    uint64_t projectStateBytes = masterChainBytes;  // includes the known master-chain object and processor pointer storage
    std::vector<std::vector<int>> readsFrom(static_cast<size_t>(slotCount));
    for (Want& w : wants) {
        Planned pl{w, {}, nullptr, {}, {}};
        pl.track = w.instrument != nullptr && !w.bus;
        uint64_t layerStateBytes = 0;
        // Arrangement clips are compiled into an immutable absolute-time event stream here,
        // on the control thread. A layer still plays them on one instrument through one chain.
        if (!w.clips.empty() && pl.track) {
            pl.arrangementSig = std::to_string(p.beatsPerBar) + "|" + std::to_string(p.loopSteps()) + "|";
            std::map<std::string, std::shared_ptr<const Pattern>> sources;
            for (const auto& [moduleId, module] : modules_)
                if (module.pattern) sources.emplace(moduleId, module.pattern);
            for (const ClipSpec& clip : w.clips) {
                pl.arrangementSig += clip.id + "|" + clip.pattern + "|" + std::to_string(clip.startSteps) + "|" +
                    std::to_string(clip.lengthSteps) + "|" + std::to_string(clip.sourceOffsetSteps) + "|" +
                    std::to_string(clip.loopSteps) + "|" + (clip.loop ? "1" : "0") + (clip.mute ? "m" : "") + "|";
                auto source = modules_.find(clip.pattern);
                if (source != modules_.end()) pl.arrangementSig += source->second.source;
                pl.arrangementSig += "\x1e";
            }
            // The expanded clips are project state: refuse them, before building them, past the budget left after
            // the project so far. Building takes about three times the result (vectors grow by doubling and the sort
            // takes a buffer the size of the events), so that peak must fit too.
            const double expanded = arrangementBytes(w.clips, sources, p.beatsPerBar);
            const double left = static_cast<double>(resourceBudget_.projectStateBytes) - static_cast<double>(projectStateBytes);
            if (expanded > 0 && 3.0 * expanded > left) {
                warnings["project"].push_back("layer '" + w.id + "' not installed: its arrangement clips expand to about " +
                    std::to_string(static_cast<uint64_t>(std::min(expanded, 1.8e19))) +
                    " bytes of notes, over this Engine's project-state budget of " +
                    std::to_string(resourceBudget_.projectStateBytes) + " bytes");
                allOk = false;
                pl.track = false;
            } else {
                auto previous = layers_.find(w.id);
                if (previous != layers_.end() && previous->second.arrangementSig == pl.arrangementSig &&
                    previous->second.pattern) {
                    pl.pattern = previous->second.pattern;
                } else {
                    pl.pattern = compileArrangement(w.clips, sources, p.beatsPerBar, p.loopSteps());
                }
                pl.w.steps = 0;  // arrangement follows the project transport, not an individual clip loop
                layerStateBytes = static_cast<uint64_t>(std::ceil(expanded));
            }
        } else if (!w.pattern.empty() && pl.track) {
            auto it = modules_.find(w.pattern);
            if (it != modules_.end() && it->second.pattern) {
                pl.pattern = it->second.pattern;
                pl.w.steps = pl.pattern->steps(p.beatsPerBar);
            } else {
                warnings["project"].push_back("layer '" + w.id + "': pattern '" + w.pattern +
                                              "' is missing or has an error, so it plays without one");
            }
        }
        if (pl.track && layerStateBytes > resourceBudget_.projectStateBytes - std::min(projectStateBytes, resourceBudget_.projectStateBytes)) {
            warnings["project"].push_back("layer '" + w.id + "' not installed: its notes exceed this Engine's project-state budget of " +
                std::to_string(resourceBudget_.projectStateBytes) + " bytes");
            allOk = false;
            pl.track = false;
        }
        if (pl.track) projectStateBytes += layerStateBytes;
        auto it = layers_.find(w.id);
        if (it != layers_.end()) {
            pl.ls = it->second;
            layers_.erase(it);
        }
        const bool isAudition = w.id[0] == '\x01';
        if (!w.bus && !pl.track) {
            // Nothing plays it (no instrument): it takes no slot.
            if (pl.ls.slot >= 0) {
                Cmd c;
                c.type = Cmd::Remove;
                c.slot = pl.ls.slot;
                if (!send(c)) {
                    allOk = false;
                    warnings[w.id].push_back("audio command queue rejected removal of a layer that plays nothing");
                    nextLayers[w.id] = pl.ls;
                }
            }
            continue;
        }
        if (pl.ls.slot < 0) {
            pl.ls.slot = isAudition ? auditionSlot : freeSlot();
            if (isAudition) ctlSlot(auditionSlot).ctlBusy = true;
            if (pl.ls.slot < 0) {
                allOk = false;
                warnings[w.id].push_back("no free engine layer slot; layer was not installed because previous removals are still fading");
                nextLayers[w.id] = pl.ls;
                continue;
            }
            pl.ls.automationSig = "\x01new-slot";  // force an empty-or-populated automation command on slot reuse
            pl.ls.track = false;
            pl.ls.inserts = nullptr;
            pl.ls.instrument = nullptr;
            pl.ls.compensation = 0;
            pl.ls.pattern = nullptr;
            pl.ls.steps = -1;
            pl.ls.volume = -1;
        }
        plan.push_back(std::move(pl));
    }

    // Resolve nested folder buses and make parents depend on their children in render order.
    std::map<std::string, int> slotByLayer;
    std::map<std::string, const LayerSpec*> specByLayer;
    for (const LayerSpec& layer : p.layers) specByLayer[layer.id] = &layer;
    for (const Planned& pl : plan) slotByLayer[pl.w.id] = pl.ls.slot;
    // Parent walks are bounded by the layer count (a chain has fewer ancestors), so they also end on a cycle.
    const int maxDepth = static_cast<int>(p.layers.size());
    for (Planned& pl : plan) {
        // Recompute routing from the new project, not the previous snapshot.
        pl.ls.parentSlot = -1;
        std::string parent = pl.w.parentId;
        for (int depth = 0; !parent.empty() && depth < maxDepth; ++depth) {
            auto spec = specByLayer.find(parent);
            if (spec == specByLayer.end()) break;
            auto bus = slotByLayer.find(parent);
            if (spec->second->folder && spec->second->busEnabled && bus != slotByLayer.end()) {
                pl.ls.parentSlot = bus->second;
                break;
            }
            parent = spec->second->parentId;
        }
        if (pl.ls.parentSlot >= 0) readsFrom[pl.ls.parentSlot].push_back(pl.ls.slot);
        // Soloing a folder solos its descendants; soloing a child keeps every ancestor bus open.
        std::string ancestor = pl.w.parentId;
        for (int depth = 0; !ancestor.empty() && depth < maxDepth; ++depth) {
            auto spec = specByLayer.find(ancestor);
            if (spec == specByLayer.end()) break;
            if (spec->second->solo) pl.w.solo = true;
            if (spec->second->folder && !spec->second->busEnabled && spec->second->mute) pl.w.mute = true;
            ancestor = spec->second->parentId;
        }
        if (pl.w.bus) {
            for (const LayerSpec& candidate : p.layers) {
                if (!candidate.solo) continue;
                std::string parent = candidate.parentId;
                for (int depth = 0; !parent.empty() && depth < maxDepth; ++depth) {
                    if (parent == pl.w.id) { pl.w.solo = true; break; }
                    auto spec = specByLayer.find(parent);
                    if (spec == specByLayer.end()) break;
                    parent = spec->second->parentId;
                }
            }
        }
    }

    // A soloed layer keeps open every bus it is heard through: its sends' buses and theirs, and the buses above them.
    {
        std::map<std::string, Planned*> byId;
        for (Planned& pl : plan) byId[pl.w.id] = &pl;
        for (bool changed = true; changed;) {
            changed = false;
            for (Planned& pl : plan) {
                if (!pl.w.solo) continue;
                auto spec = specByLayer.find(pl.w.id);
                if (spec == specByLayer.end()) continue;
                auto open = [&](const std::string& id) {
                    auto it = byId.find(id);
                    if (it != byId.end() && !it->second->w.solo) {
                        it->second->w.solo = true;
                        changed = true;
                    }
                };
                for (const SendSpec& send : spec->second->sends) open(send.to);
                open(routeTarget(p, *spec->second));
            }
        }
    }

    // Pass 2: send what changed, and order layers so buses run after their children.
    std::vector<int> projectOrder;
    for (Planned& pl : plan) {
        LayerState& ls = pl.ls;
        const Want& w = pl.w;
        ls.arrangementSig = pl.arrangementSig;
        for (const AutomationLaneSpec& lane : w.automation) {
            pl.automationSig += lane.target + "|";
            for (const AutomationPointSpec& point : lane.points)
                pl.automationSig += std::to_string(point.step) + ":" + std::to_string(point.value) + ";";
        }
        if (w.vol != ls.volume || w.pan != ls.pan || w.mute != ls.mute || w.solo != ls.solo) {
            writeMix(ls.slot, w.vol, w.pan, w.mute, w.solo);
            ls.volume = w.vol;
            ls.pan = w.pan;
            ls.mute = w.mute;
            ls.solo = w.solo;
        }
        // A layer's native inserts: a new chain (crossfaded in), none, or new values for the one it keeps.
        auto syncInserts = [&]() {
            const bool wantsInserts = w.components && !w.components->empty();
            auto made = nextInserts.find(w.id);
            if (made != nextInserts.end() || (!wantsInserts && ls.inserts)) {
                Cmd inserts;
                inserts.type = Cmd::SetInserts;
                inserts.slot = ls.slot;
                ComponentChain* sent = made != nextInserts.end() ? made->second.release() : nullptr;
                if (sent) attachAutomation(*sent, w.id);
                inserts.masterChain = sent;
                if (send(inserts)) {
                    ls.inserts = sent;
                    ls.insertsAutomationKey = ComponentChain::automationKey(p.automation, w.id);
                } else {
                    allOk = false;
                    warnings["project"].push_back("layer '" + w.id + "': audio command queue rejected its native component update");
                }
            } else if (wantsInserts && ls.inserts) {
                ls.inserts->setValues(*w.components);
                updateAutomation(ls.slot, *ls.inserts, w.id, ls.insertsAutomationKey);
            }
        };
        if (!w.bus) {
            syncInserts();
            auto madeInstrument = nextInstruments.find(w.id);
            if ((pl.track && madeInstrument != nextInstruments.end()) || (!pl.track && ls.instrument)) {
                Cmd instrument;
                instrument.type = Cmd::SetInstrument;
                instrument.slot = ls.slot;
                ComponentChain* sent = pl.track ? madeInstrument->second.release() : nullptr;
                if (sent) attachAutomation(*sent, w.id);
                instrument.masterChain = sent;
                if (send(instrument)) {
                    ls.instrument = sent;
                    ls.instrumentAutomationKey = ComponentChain::automationKey(p.automation, w.id, "instrument");
                } else {
                    allOk = false;
                    warnings["project"].push_back("layer '" + w.id + "': audio command queue rejected its native instrument update");
                }
            } else if (pl.track && ls.instrument) {
                ls.instrument->setValues({*w.instrument});
                updateAutomation(ls.slot, *ls.instrument, w.id, ls.instrumentAutomationKey);
            }
        }
        if (w.bus) {
            Cmd bus;
            bus.type = Cmd::ConfigureBus;
            bus.slot = ls.slot;
            bus.parentSlot = pl.ls.parentSlot;
            bus.order = w.order;
            const bool newBus = !ls.bus;
            bus.flag = newBus;
            if (newBus) ls.automationSig = "\\x01new-slot";
            if (!send(bus)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected folder-bus configuration");
                nextLayers[w.id] = ls;
                continue;
            }
            if (newBus) {  // the slot dropped what it had as a track (its chain, inserts, instrument and delay)
                ls.inserts = nullptr;
                ls.instrument = nullptr;
                ls.compensation = 0;
            }
            ls.bus = true;
            syncInserts();  // after ConfigureBus, so a new bus keeps them
            ls.parentSlot = pl.ls.parentSlot;
            if (ls.automationSig != pl.automationSig) {
                Cmd automation;
                automation.type = Cmd::SetAutomation;
                automation.slot = ls.slot;
                automation.flag = newBus;
                auto* data = new AutomationData();
                for (const AutomationLaneSpec& lane : w.automation) {
                    auto& points = lane.target == "volume" ? data->volume : data->pan;
                    points.insert(points.end(), lane.points.begin(), lane.points.end());
                }
                if (data->volume.empty() && data->pan.empty()) delete data;
                else automation.automation = data;
                if (send(automation)) ls.automationSig = pl.automationSig;
                else {
                    allOk = false;
                    warnings[w.id].push_back("audio command queue rejected folder automation update");
                    nextLayers[w.id] = ls;
                    continue;
                }
            }
            ls.track = false;
            ls.pattern.reset();
            ls.steps = 0;
            projectOrder.push_back(ls.slot);
            nextLayers[w.id] = ls;
            continue;
        }
        if (ls.bus) ls.automationSig = "\\x01new-slot";
        if (ls.automationSig != pl.automationSig) {
            Cmd automation; automation.type = Cmd::SetAutomation; automation.slot = ls.slot;
            auto* data = new AutomationData();
            for (const AutomationLaneSpec& lane : w.automation) {
                auto& points = lane.target == "volume" ? data->volume : data->pan;
                points.insert(points.end(), lane.points.begin(), lane.points.end());
            }
            if (data->volume.empty() && data->pan.empty()) delete data;
            else automation.automation = data;
            if (send(automation)) ls.automationSig = pl.automationSig;
            else {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected layer automation update");
                nextLayers[w.id] = ls;
                continue;
            }
        }
        {
            Cmd routing;
            routing.type = Cmd::SetRouting;
            routing.slot = ls.slot;
            routing.parentSlot = pl.ls.parentSlot;
            if (!send(routing)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected track routing update");
                nextLayers[w.id] = ls;
                continue;
            }
            ls.bus = false;
            ls.parentSlot = pl.ls.parentSlot;
        }
        if (!ls.track) {
            Cmd cmd;
            cmd.type = Cmd::Install;
            cmd.slot = ls.slot;
            cmd.steps = w.steps;
            cmd.order = w.order;
            if (!send(cmd)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected the track");
                nextLayers[w.id] = ls;
                continue;
            }
            ls.track = true;
            ls.steps = w.steps;
        } else {
            if (w.steps != ls.steps) {
                Cmd cmd;
                cmd.type = Cmd::SetSteps;
                cmd.slot = ls.slot;
                cmd.steps = w.steps;
                if (!send(cmd)) {
                    allOk = false;
                    warnings[w.id].push_back("audio command queue rejected layer-length update");
                    nextLayers[w.id] = ls;
                    continue;
                }
                ls.steps = w.steps;
            }
        }
        if (pl.pattern != ls.pattern) {
            Cmd cmd;
            cmd.type = Cmd::SetPattern;
            cmd.slot = ls.slot;
            cmd.pattern = pl.pattern ? new std::shared_ptr<const Pattern>(pl.pattern) : nullptr;
            // Which new note carries on each old one, so held notes follow the edit (worked out here, off the
            // audio thread; send() frees it if the queue rejects the command).
            if (pl.pattern && ls.pattern)
                cmd.orderList = new std::vector<int>(matchPatternNotes(*ls.pattern, *pl.pattern));
            if (!send(cmd)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected pattern update");
                nextLayers[w.id] = ls;
                continue;
            }
            ls.pattern = pl.pattern;
        }
        projectOrder.push_back(ls.slot);
        nextLayers[w.id] = ls;
    }
    // Layers that disappeared fade out and free their slot.
    for (auto& [id, ls] : layers_) {
        if (ls.slot < 0) continue;
        Cmd c;
        c.type = Cmd::Remove;
        c.slot = ls.slot;
        if (!send(c)) {
            allOk = false;
            warnings[id].push_back("audio command queue rejected layer removal");
            nextLayers[id] = ls;
        }
    }
    layers_ = std::move(nextLayers);

    // Routes: each layer's sends (in project order, so a send's index stays its index), then the sidechain keys
    // it feeds. updateCompensation sends them with their delays.
    for (auto& [id, ls] : layers_) {
        ls.routes.clear();
        ls.userSends = 0;
    }
    for (const LayerSpec& l : p.layers) {
        auto it = layers_.find(l.id);
        if (it == layers_.end() || it->second.slot < 0) continue;
        LayerState& ls = it->second;
        for (const SendSpec& send : l.sends) {
            LayerState::Route r;
            auto to = layers_.find(send.to);
            if (to != layers_.end() && to->second.slot >= 0 && to->second.bus) r.dest = to->second.slot;
            else warnings["project"].push_back("layer '" + l.id + "': send to '" + send.to + "': that bus isn't playing, so the send is silent");
            r.level = send.level;
            r.pre = send.pre;
            r.mute = send.mute;
            ls.routes.push_back(r);
        }
        ls.userSends = static_cast<int>(ls.routes.size());
    }
    for (const LayerSpec& l : p.layers) {
        auto it = layers_.find(l.id);
        if (it == layers_.end() || it->second.slot < 0) continue;
        for (size_t i = 0; i < l.components.size(); ++i) {
            const ComponentSpec& c = l.components[i];
            if (!c.hasKey) continue;
            if (!it->second.inserts || !it->second.inserts->keyed(i)) {
                warnings["project"].push_back("layer '" + l.id + "': component '" + c.id + "' has no sidechain input, so its key is ignored");
                continue;
            }
            auto from = layers_.find(c.key.layer);
            if (from == layers_.end() || from->second.slot < 0) {
                warnings["project"].push_back("layer '" + l.id + "': component '" + c.id + "': its key '" + c.key.layer + "' isn't playing");
                continue;
            }
            if (from->second.routes.size() >= static_cast<size_t>(kMaxRoutes)) {
                warnings["project"].push_back("layer '" + c.key.layer + "' keys more than " + std::to_string(kMaxRoutes - kMaxSends) +
                                                " components; the rest hear no key");
                continue;
            }
            LayerState::Route r;
            r.dest = it->second.slot;
            r.key = static_cast<int>(i);
            r.level = c.key.level;
            r.pre = c.key.pre;
            from->second.routes.push_back(r);
        }
    }

    if (!updateCompensation(warnings)) allOk = false;

    // Dependency order: repeatedly take the first layer (in project order) whose children are all placed (a bus
    // after the tracks and buses in it). validateRouting refuses loops, so every layer is placed; the audio
    // thread's routing (updateRouting) then also runs each send's and key's source before its destination.
    {
        Cmd oc;
        oc.type = Cmd::SetOrder;
        auto orderList = std::make_unique<std::vector<int>>();
        orderList->reserve(static_cast<size_t>(slotCount));
        std::vector<bool> placed(static_cast<size_t>(slotCount), false);
        bool progress = true;
        while (progress) {
            progress = false;
            for (int slot : projectOrder) {
                if (placed[slot]) continue;
                bool ready = true;
                for (int src : readsFrom[slot])
                    if (!placed[src] && std::find(projectOrder.begin(), projectOrder.end(), src) != projectOrder.end())
                        ready = false;
                if (!ready) continue;
                placed[slot] = true;
                orderList->push_back(slot);
                progress = true;
            }
        }
        for (int slot : projectOrder)
            if (!placed[slot]) orderList->push_back(slot);  // never expected: kept playing in project order
        oc.orderList = orderList.release();  // send() frees it if the queue rejects the command
        if (!send(oc)) {
            allOk = false;
            warnings["project"].push_back("audio command queue rejected project layer ordering");
        }
    }

    Cmd a;
    a.type = Cmd::AuditionOnly;
    a.flag = p.auditionOnly;
    if (!send(a)) {
        allOk = false;
        warnings["project"].push_back("audio command queue rejected audition mode update");
    }

    if (keepMasterChain) {
        ctlMasterChain_->setValues(p.masterComponents);
        updateAutomation(-1, *ctlMasterChain_, "", ctlMasterAutomationKey_);
    } else if (nextMasterChain || ctlMasterChain_) {
        Cmd masterChainCommand;
        masterChainCommand.type = Cmd::SetMasterChain;
        ComponentChain* sent = nextMasterChain.release();
        if (sent) attachAutomation(*sent, "");
        masterChainCommand.masterChain = sent;
        if (send(masterChainCommand)) {
            ctlMasterChain_ = sent;
            ctlMasterAutomationKey_ = ComponentChain::automationKey(p.automation, "");
        } else {
            allOk = false;
            warnings["project"].push_back("audio command queue rejected native master-chain update");
        }
    }

    // Per-note FX (#127): its own plan, swapped in lock-free at the next chunk, as modulation's.
    noteFx_->commit(p, [&](const std::string& id) {
        auto it = layers_.find(id);
        return it == layers_.end() || it->second.bus ? -1 : it->second.slot;
    }, ctlAutomation_, warnings["project"]);
    // Project modulation (#161, modulation_links.cpp): its own plan, swapped in lock-free at the next chunk.
    {
        std::vector<std::string>& w = warnings["project"];
        const std::string modError = modulation_->update(nativeModules_, p, sr_, [&](const std::string& id) {
            ModulationHost::LayerInfo info;
            if (id.empty()) {
                info.inserts = ctlMasterChain_;
                return info;
            }
            auto it = layers_.find(id);
            if (it == layers_.end()) return info;
            info.slot = it->second.slot;
            info.bus = it->second.bus;
            info.sends = it->second.userSends;
            info.inserts = it->second.inserts;
            info.instrument = it->second.instrument;
            info.noteFx = noteFx_->chainFor(id);
            return info;
        }, w);
        if (!modError.empty()) {
            allOk = false;
            w.push_back(modError);
        }
    }

    std::string mods;
    for (const ModuleSpec& m : p.modules) {
        const ModuleState& st = modules_.at(m.id);
        if (!mods.empty()) mods += ",";
        mods += "\"" + jsonEscape(m.id) + "\":{\"ok\":" + (st.error.empty() ? "true" : "false");
        if (!st.error.empty())
            mods += ",\"error\":\"" + jsonEscape(st.error) + "\",\"line\":" + std::to_string(st.line) +
                    ",\"col\":" + std::to_string(st.col);
        if (st.pattern) mods += "," + describePattern(*st.pattern);
        else mods += ",\"kind\":\"pattern\"";
        mods += ",\"warnings\":[";
        auto wit = warnings.find(m.id);
        if (wit != warnings.end()) {
            std::sort(wit->second.begin(), wit->second.end());
            wit->second.erase(std::unique(wit->second.begin(), wit->second.end()), wit->second.end());
            for (size_t i = 0; i < wit->second.size(); ++i)
                mods += (i ? ",\"" : "\"") + jsonEscape(wit->second[i]) + "\"";
        }
        mods += "]}";
    }
    std::string projectWarnings;
    auto projectWarningIt = warnings.find("project");
    if (projectWarningIt != warnings.end()) {
        auto& messages = projectWarningIt->second;
        std::sort(messages.begin(), messages.end());
        messages.erase(std::unique(messages.begin(), messages.end()), messages.end());
        for (size_t i = 0; i < messages.size(); ++i)
            projectWarnings += (i ? ",\"" : "\"") + jsonEscape(messages[i]) + "\"";
    }
    return std::string("{\"ok\":") + (allOk ? "true" : "false") +
           ",\"modules\":{" + mods + "},\"warnings\":{\"project\":[" + projectWarnings + "]}}";
}

ComponentChain* Engine::ctlComponentChain(const std::string& layerId, uint32_t& index) noexcept {
    const bool instrument = index == kInstrumentIndex;
    if (instrument) index = 0;
    if (layerId.empty()) return instrument ? nullptr : ctlMasterChain_;
    auto it = layers_.find(layerId);
    if (it == layers_.end()) return nullptr;
    return instrument ? it->second.instrument : it->second.inserts;
}

// Latency compensation: each track is delayed so it lines up with the track whose native effects add the most
// latency (the master chain delays everything alike, so it needs none). Control thread, under ctl_.
bool Engine::updateCompensation(std::map<std::string, std::vector<std::string>>& warnings) {
    bool ok = true;
    // Plugin delay compensation over the whole routing: a slot's own latency is its instrument's and inserts';
    // a bus's input arrives at the latest of what feeds it (children and sends), and every route into a bus
    // (or the master) is delayed by how much earlier it arrives, so everything that meets is in time. Keys
    // are not delayed: they arrive as early as they can (a ducker's look-ahead covers a late one).
    struct Node {
        LayerState* ls = nullptr;
        const std::string* id = nullptr;
        int64_t own = 0, in = 0, raw = 0;
        int indegree = 0;
        std::vector<int> out;  // slots it feeds (its bus, its sends' buses)
    };
    std::map<int, Node> nodes;
    for (auto& [id, ls] : layers_) {
        if (ls.slot < 0) continue;
        Node& n = nodes[ls.slot];
        n.ls = &ls;
        n.id = &id;
        uint64_t frames = 0;
        if (ls.inserts) frames += ls.inserts->latencyFrames();
        if (ls.instrument && !ls.bus) frames += ls.instrument->latencyFrames() + noteFx_->latencyFrames(id);
        n.own = static_cast<int64_t>(std::min<uint64_t>(frames, 1u << 30));
    }
    auto busAt = [&](int slot) -> Node* {
        auto it = nodes.find(slot);
        return it != nodes.end() && it->second.ls->bus ? &it->second : nullptr;
    };
    for (auto& [slot, n] : nodes) {
        if (Node* parent = busAt(n.ls->parentSlot); parent && n.ls->parentSlot != slot) n.out.push_back(n.ls->parentSlot);
        for (const LayerState::Route& r : n.ls->routes)
            if (r.key < 0 && busAt(r.dest) && r.dest != slot) n.out.push_back(r.dest);
        for (int to : n.out) ++nodes[to].indegree;
    }
    // Kahn's order (routing loops are refused before here; any left over go last).
    std::vector<int> order, ready;
    for (auto& [slot, n] : nodes)
        if (n.indegree == 0) ready.push_back(slot);
    while (!ready.empty()) {
        const int x = ready.back();
        ready.pop_back();
        order.push_back(x);
        for (int to : nodes[x].out)
            if (--nodes[to].indegree == 0) ready.push_back(to);
    }
    if (order.size() < nodes.size())
        for (auto& [slot, n] : nodes)
            if (n.indegree > 0) order.push_back(slot);
    int64_t masterIn = 0;
    for (int x : order) {
        Node& n = nodes[x];
        n.raw = n.in + n.own;
        bool toMaster = !busAt(n.ls->parentSlot) || n.ls->parentSlot == x;
        for (int to : n.out) nodes[to].in = std::max(nodes[to].in, n.raw);
        if (toMaster) masterIn = std::max(masterIn, n.raw);
    }
    bool capped = false;
    auto delayTo = [&](const Node& from, int64_t arrival) {
        const int64_t d = arrival - from.raw;
        if (d > kMaxCompensationFrames) capped = true;
        return std::clamp<int64_t>(d, 0, kMaxCompensationFrames);
    };
    auto makeDelay = [](int64_t frames) -> DelayLine* {
        if (frames <= 0) return nullptr;
        auto* d = new DelayLine();
        d->l.assign(static_cast<size_t>(frames), 0.0f);
        d->r.assign(static_cast<size_t>(frames), 0.0f);
        return d;
    };
    for (int x : order) {
        Node& n = nodes[x];
        LayerState& ls = *n.ls;
        const Node* parent = busAt(ls.parentSlot);
        const int64_t want = delayTo(n, parent && ls.parentSlot != x ? parent->in : masterIn);
        if (want != ls.compensation) {
            Cmd d;
            d.type = Cmd::SetDelay;
            d.slot = ls.slot;
            d.delay = makeDelay(want);
            if (send(d)) {
                ls.compensation = want;
            } else {
                ok = false;
                warnings["project"].push_back("layer '" + *n.id + "': audio command queue rejected its latency compensation");
            }
        }
        // The routes: a new table when a destination or a delay changed, else just the levels that moved.
        std::vector<int64_t> delays;
        std::string sig;
        for (const LayerState::Route& r : ls.routes) {
            const Node* to = r.key < 0 ? busAt(r.dest) : nullptr;
            delays.push_back(to ? delayTo(n, to->in) : 0);
            sig += std::to_string(r.dest) + ":" + std::to_string(r.key) + ":" + std::to_string(delays.back()) + ";";
        }
        if (sig != ls.routesSig) {
            Cmd c;
            c.type = Cmd::SetSends;
            c.slot = ls.slot;
            if (!ls.routes.empty()) {
                c.sends = new SendTable();
                for (size_t k = 0; k < ls.routes.size(); ++k) {
                    const LayerState::Route& r = ls.routes[k];
                    SendTable::Route& t = c.sends->routes[k];
                    t.dest = r.dest;
                    t.key = r.key;
                    t.level = r.level;
                    t.pre = t.tapPre = r.pre;
                    t.mute = r.mute;
                    t.delay = makeDelay(delays[k]);
                    c.sends->keys = c.sends->keys || (r.key >= 0 && r.dest >= 0);
                }
                c.sends->count = static_cast<int>(ls.routes.size());
            }
            if (send(c)) {
                ls.routesSig = sig;
                ls.routesSent = ls.routes;
            } else {
                ok = false;
                warnings["project"].push_back("layer '" + *n.id + "': audio command queue rejected its sends");
            }
            continue;
        }
        for (size_t k = 0; k < ls.routes.size() && k < ls.routesSent.size(); ++k) {
            const LayerState::Route& r = ls.routes[k];
            LayerState::Route& was = ls.routesSent[k];
            if (r.level == was.level && r.pre == was.pre && r.mute == was.mute) continue;
            Cmd c;
            c.type = Cmd::SetSendLevel;
            c.slot = ls.slot;
            c.order = static_cast<int>(k);
            c.master = r.level;
            c.flag = r.pre;
            c.sendMute = r.mute;
            if (send(c)) was = r;
        }
    }
    if (capped)
        warnings["project"].push_back("native effects add more latency than the " + std::to_string(kMaxCompensationFrames) +
                                      " frames tracks are kept in time over");
    return ok;
}

bool Engine::setSend(const std::string& layerId, uint32_t index, double level, bool pre, bool mute) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0 || index >= static_cast<uint32_t>(it->second.userSends)) return false;
    LayerState& ls = it->second;
    LayerState::Route& r = ls.routes[index];
    r.level = std::isfinite(level) ? std::clamp(level, 0.0, kMaxMixGain) : 0.0;
    r.pre = pre;
    r.mute = mute;
    if (index >= ls.routesSent.size()) return false;
    Cmd c;
    c.type = Cmd::SetSendLevel;
    c.slot = ls.slot;
    c.order = static_cast<int>(index);
    c.master = r.level;
    c.flag = r.pre;
    c.sendMute = r.mute;
    if (!send(c)) return false;
    ls.routesSent[index] = r;
    return true;
}

bool Engine::setComponentParam(const std::string& layerId, uint32_t index, const std::string& param, double value) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (index != kInstrumentIndex && (index & kNoteComponentFlag))  // per-note FX (#127): every slot
        return noteFx_->setParam(layerId, index & ~kNoteComponentFlag, param, value);
    ComponentChain* chain = ctlComponentChain(layerId, index);
    if (!chain) return false;
    const uint64_t before = chain->latencyFrames();
    if (!chain->setValue(index, param, value)) return false;
    if (chain->latencyFrames() != before) {  // a look-ahead turned on or off: everything else moves to stay in time
        std::map<std::string, std::vector<std::string>> warnings;
        updateCompensation(warnings);
    }
    return true;
}

bool Engine::setComponentBypass(const std::string& layerId, uint32_t index, bool bypass) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (index != kInstrumentIndex && (index & kNoteComponentFlag)) {  // per-note FX (#127): every slot
        if (!noteFx_->setBypass(layerId, index & ~kNoteComponentFlag, bypass)) return false;
        std::map<std::string, std::vector<std::string>> warnings;
        updateCompensation(warnings);
        return true;
    }
    ComponentChain* chain = ctlComponentChain(layerId, index);
    if (!chain || !chain->setBypass(index, bypass)) return false;
    std::map<std::string, std::vector<std::string>> warnings;
    updateCompensation(warnings);  // a bypassed effect adds no latency
    return true;
}

std::string Engine::componentStatesJson(const std::string& layerId) {
    std::lock_guard<std::mutex> lock(ctl_);
    uint32_t insertsIndex = 0, instrumentIndex = kInstrumentIndex;
    ComponentChain* chain = ctlComponentChain(layerId, insertsIndex);
    ComponentChain* instrument = ctlComponentChain(layerId, instrumentIndex);
    if (!chain && !instrument) return R"({"ok":false,"error":"no native components run there","components":[]})";
    std::string j = R"({"ok":true,"components":[)";
    bool first = true;
    auto add = [&](const ComponentChain::SavedState& state, uint64_t index) {
        j += std::string(first ? "" : ",") + "{\"index\":" + std::to_string(index) + ",\"ok\":" + (state.ok ? "true" : "false") +
             ",\"version\":" + std::to_string(state.version) + ",\"state\":\"" +
             base64Encode(state.data.data(), state.data.size()) + "\"}";
        first = false;
    };
    if (chain) {
        const std::vector<ComponentChain::SavedState> states = chain->saveStates();
        for (size_t i = 0; i < states.size(); ++i) add(states[i], i);
    }
    if (instrument)
        for (const ComponentChain::SavedState& state : instrument->saveStates()) add(state, kInstrumentIndex);
    return j + "]}";
}

bool Engine::setComponentState(const std::string& layerId, uint32_t index, const uint8_t* data, size_t size,
                               uint32_t version) {
    if (size > 0 && !data) return false;
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    const bool instrument = index == kInstrumentIndex;
    uint32_t at = index;
    ComponentChain* old = ctlComponentChain(layerId, at);
    if (!old) return false;
    LayerState* ls = nullptr;
    if (!layerId.empty()) {
        auto it = layers_.find(layerId);
        if (it == layers_.end() || it->second.slot < 0) return false;
        ls = &it->second;
    }
    std::vector<ComponentSpec> specs = old->currentSpecs();
    if (at >= specs.size()) return false;
    ComponentSpec& spec = specs[at];
    spec.lenient = false;  // this one must take the new state; the others keep theirs as a rebuild does
    spec.hasState = true;
    spec.stateVersion = version;
    spec.state.assign(data, data + size);
    std::string error;
    const BuildingQuality building(&quality_);
    const BuildingLiveAudio buildingInput(audioIn_.get());
    auto chain = instrument ? ComponentChain::buildInstrument(nativeModules_, specs.front(), sr_, error)
                            : ComponentChain::build(nativeModules_, specs, sr_, error);
    if (!chain) return false;
    delete chain->swapAutomation(chain->automationFor(ctlAutomation_, layerId).release());
    Cmd c;
    c.type = !ls ? Cmd::SetMasterChain : instrument ? Cmd::SetInstrument : Cmd::SetInserts;
    c.slot = ls ? ls->slot : -1;
    ComponentChain* sent = chain.release();
    c.masterChain = sent;
    if (!send(c)) return false;  // send() freed it; the old chain plays on
    if (ls) (instrument ? ls->instrument : ls->inserts) = sent;
    else ctlMasterChain_ = sent;
    std::map<std::string, std::vector<std::string>> warnings;
    updateCompensation(warnings);
    return true;
}

int32_t Engine::componentDisplay(const std::string& layerId, uint32_t index, float* out, uint32_t max) {
    // Never waits: a UI polls this every frame, and a project update can hold ctl_ for a while (it then shows
    // its last picture). The chains themselves are read without locks (DisplayBuffer).
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);
    if (!lock.owns_lock()) return 0;
    if (index != kInstrumentIndex && (index & kNoteComponentFlag))  // per-note FX (#127): the newest note's slot
        return noteFx_->readDisplay(layerId, index & ~kNoteComponentFlag, out, max);
    ComponentChain* chain = ctlComponentChain(layerId, index);
    if (!chain) return -1;
    return chain->readDisplay(index, out, max);
}

bool Engine::setModulatorParam(const std::string& modulatorId, const std::string& param, double value) {
    std::lock_guard<std::mutex> lock(ctl_);
    return modulation_->setModulatorParam(modulatorId, param, value);
}

bool Engine::setModulatorBypass(const std::string& modulatorId, bool bypass) {
    std::lock_guard<std::mutex> lock(ctl_);
    return modulation_->setModulatorBypass(modulatorId, bypass);
}

bool Engine::setModulationAmount(uint32_t linkId, double amount) {
    std::lock_guard<std::mutex> lock(ctl_);
    const bool perNote = noteFx_->setLinkAmount(linkId, amount);  // a note-source link (#127)
    return modulation_->setLinkAmount(linkId, amount) || perNote;
}

bool Engine::noteFxStats(const std::string& layerId, NoteFxStats& out) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);  // a UI polls it: never waits
    return lock.owns_lock() && noteFx_->stats(layerId, out);
}

int32_t Engine::modulatorOutputs(const std::string& modulatorId, float* out, int32_t max) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);  // a UI polls it: never waits
    if (!lock.owns_lock()) return 0;
    return modulation_->outputs(modulatorId, out, max);
}

bool Engine::modulationOffset(uint32_t linkId, float& out) {
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);
    return lock.owns_lock() && modulation_->linkOffset(linkId, out);
}

void Engine::setLayerMix(const std::string& layerId, double volume, double pan, bool mute, bool solo) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0) return;
    LayerState& ls = it->second;
    ls.volume = std::isfinite(volume) ? std::clamp(volume, 0.0, kMaxMixGain) : 0.0;
    ls.pan = std::min(1.0, std::max(-1.0, pan));
    ls.mute = mute;
    ls.solo = solo;
    writeMix(ls.slot, ls.volume, ls.pan, mute, solo);
}

void Engine::noteOn(const std::string& layerId, int32_t id, double pitch, double velocity) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (!layerId.empty() && layerId[0] == '\x01') return;  // the audition's internal layer: its slot moves on a grow
    auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0) return;
    Cmd c;
    c.type = Cmd::Preview;
    c.previewOp = 0;
    c.slot = it->second.slot;
    c.previewId = id;
    c.pitch = std::isfinite(pitch) ? std::clamp(pitch, 0.0, 127.0) : 60.0;
    c.vel = std::isfinite(velocity) ? std::clamp(velocity, 0.0, 1.0) : 1.0;
    // A new note on the same id elsewhere ends the old one there first.
    auto old = previewSlots_.find(id);
    if (old != previewSlots_.end() && old->second != c.slot) {
        Cmd off = c;
        off.previewOp = 2;
        off.slot = old->second;
        if (!send(off)) return;  // the queue is full: keep the old note's entry, so its off can still reach it
    }
    if (send(c)) previewSlots_[id] = c.slot;
}

void Engine::notePitch(int32_t id, double pitch) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = previewSlots_.find(id);
    if (it == previewSlots_.end() || !std::isfinite(pitch)) return;
    Cmd c;
    c.type = Cmd::Preview;
    c.previewOp = 1;
    c.slot = it->second;
    c.previewId = id;
    c.pitch = std::clamp(pitch, 0.0, 127.0);
    send(c);
}

void Engine::noteOff(int32_t id) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = previewSlots_.find(id);
    if (it == previewSlots_.end()) return;
    Cmd c;
    c.type = Cmd::Preview;
    c.previewOp = 2;
    c.slot = it->second;
    c.previewId = id;
    if (send(c)) previewSlots_.erase(it);  // a full queue keeps the entry, so a later off still ends the note
}

void Engine::notesOff() {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::Preview;
    c.previewOp = 3;
    if (send(c)) previewSlots_.clear();
}

// ---- Device MIDI (API 15) ----

int64_t Engine::midiClockNs() noexcept {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

bool Engine::queueDeviceMidi(int slot, Midi2Event e, int64_t timeNs) noexcept {
    e.target = slot;
    e.timeNs = timeNs;
    return midiIn_.push(e);
}

// The layer's slot, or -1. Briefly under ctl_, as a preview's note on.
int Engine::deviceSlot(const std::string& id) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (id.empty() || id[0] == '\x01') return -1;
    auto it = layers_.find(id);
    return it == layers_.end() ? -1 : it->second.slot;
}

int Engine::midiUmp(const std::string& layerId, const uint32_t* words, int count, int64_t timeNs) {
    if (!words || count <= 0) return 0;
    const int slot = deviceSlot(layerId);
    if (slot < 0) return 0;
    if (timeNs <= 0) timeNs = midiClockNs();
    std::lock_guard<std::mutex> lock(midiPush_);
    int queued = 0;
    for (int i = 0; i < count;) {
        const int n = umpWordCount(words[i]);
        if (i + n > count) break;  // a message cut short
        uint32_t w[2] = {words[i], n > 1 ? words[i + 1] : 0u};
        i += n;
        if ((w[0] >> 28) == 0x2 && !ump1ToUmp2(w[0], w)) continue;
        Midi2Event e;
        if (!decodeMidi2ChannelVoice(w[0], w[1], e)) continue;  // utility, system, SysEx, flex data: not for notes
        e.ump[0] = w[0];
        e.ump[1] = w[1];
        if (queueDeviceMidi(slot, e, timeNs)) ++queued;
    }
    return queued;
}

int Engine::midiBytes(const std::string& layerId, const uint8_t* bytes, int count, int64_t timeNs) {
    if (!bytes || count <= 0) return 0;
    const int slot = deviceSlot(layerId);
    if (slot < 0) return 0;
    if (timeNs <= 0) timeNs = midiClockNs();
    std::lock_guard<std::mutex> lock(midiPush_);
    int queued = 0;
    uint8_t status = 0;  // running status within this call
    for (int i = 0; i < count;) {
        const uint8_t b = bytes[i];
        if (b >= 0xF8) { ++i; continue; }  // real-time bytes may come anywhere
        if (b >= 0xF0) {  // system common and SysEx: skipped up to the next status byte
            status = 0;
            ++i;
            while (i < count && bytes[i] < 0x80) ++i;
            continue;
        }
        if (b >= 0x80) {
            status = b;
            ++i;
        } else if (status == 0) {
            ++i;
            continue;
        }
        const int need = midi1DataBytes(status);
        if (i + need > count) break;
        const uint8_t d1 = need > 0 ? bytes[i] : 0, d2 = need > 1 ? bytes[i + 1] : 0;
        if (d1 >= 0x80 || d2 >= 0x80) continue;  // a status byte arrived early: start again from it
        i += need;
        uint32_t w[2];
        Midi2Event e;
        if (!midi1ToUmp2(status, d1, d2, 0, w) || !decodeMidi2ChannelVoice(w[0], w[1], e)) continue;
        e.ump[0] = w[0];
        e.ump[1] = w[1];
        if (queueDeviceMidi(slot, e, timeNs)) ++queued;
    }
    return queued;
}

void Engine::midiRelease(const std::string& layerId) {
    int slot = -1;
    if (!layerId.empty()) {
        slot = deviceSlot(layerId);
        if (slot < 0) return;
    }
    Midi2Event e;
    e.type = Midi2EventType::AllOff;
    std::lock_guard<std::mutex> lock(midiPush_);
    queueDeviceMidi(slot, e, midiClockNs());  // slot -1: every slot
}

void Engine::setMidiOptions(bool mpe, double bendRange, double noteBendRange, double delayMs) noexcept {
    auto clampD = [](double v, double lo, double hi, double fallback) {
        return std::isfinite(v) ? std::clamp(v, lo, hi) : fallback;
    };
    midiMpe_.store(mpe, std::memory_order_relaxed);
    midiBendRange_.store(clampD(bendRange, 0, 96, 2), std::memory_order_relaxed);
    midiNoteBendRange_.store(clampD(noteBendRange, 0, 96, 48), std::memory_order_relaxed);
    midiDelayNs_.store(static_cast<int64_t>(clampD(delayMs, 0, 200, 0) * 1e6), std::memory_order_relaxed);
}

uint64_t Engine::midiDropped() const noexcept {
    return midiIn_.dropped() + midiPendingDropped_.load(std::memory_order_relaxed);
}

int64_t Engine::positionAt(int64_t timeNs) const noexcept {
    const int64_t pos = cbPos_.load(std::memory_order_acquire);
    if (pos < 0) return -1;
    const int64_t at = cbTimeNs_.load(std::memory_order_acquire);
    return pos + static_cast<int64_t>(std::floor(static_cast<double>(timeNs - at) * sr_ / 1e9));
}

void Engine::setMaster(double volume) {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::SetMaster;
    c.master = std::isfinite(volume) ? std::clamp(volume, 0.0, kMaxMixGain) : 0.0;
    send(c);
}

void Engine::play(double fromStep) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    Cmd c;
    c.type = Cmd::Play;
    c.fromStep = fromStep;
    c.playCount = playCount_ + 1;
    c.touchStamp = touchCounter_;
    if (!send(c)) return;  // nothing changed on the audio side, so keep the control side as it was
    playCount_ = c.playCount;
    loudness_->requestReset();  // the integrated loudness measures this play
}

void Engine::playCountIn(double fromStep, int beats) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    Cmd c;
    c.type = Cmd::Play;
    c.fromStep = fromStep;
    c.countInBeats = std::clamp(beats, 0, 64);
    c.playCount = playCount_ + 1;
    c.touchStamp = touchCounter_;
    if (!send(c)) return;
    playCount_ = c.playCount;
    loudness_->requestReset();
}

void Engine::setMetronome(bool on) {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::Metronome;
    c.flag = on;
    send(c);
}

void Engine::setMetronomeSound(double volume, int sound) noexcept {
    clickVolume_.store(static_cast<float>(std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 1.0),
                       std::memory_order_relaxed);
    clickSound_.store(sound >= 0 && sound <= 2 ? sound : 0, std::memory_order_relaxed);
}

void Engine::testTone(double seconds) noexcept {
    const double s = std::isfinite(seconds) ? std::clamp(seconds, 0.0, 10.0) : 0.0;
    toneRequest_.store(static_cast<int64_t>(s * sr_), std::memory_order_release);
}

void Engine::resetTestTone() noexcept {
    toneRequest_.store(-1, std::memory_order_release);
    toneLeft_ = toneLen_ = 0;
    toneActive_.store(false, std::memory_order_release);
}

// The test tone: 0.25 (-12 dBFS) of 440 Hz with 10 ms fades, added before the safety limiter (finishSample in
// runMasterNode, or mixToneOnly where the master stage does not run). A request to end it early fades it out over
// those 10 ms.
void Engine::takeToneRequest() noexcept {
    // A start is published as sounding before its request is cleared, so testToneSounding() never reads false in
    // between. A request that lands after the load is left for the next callback.
    int64_t req = toneRequest_.load(std::memory_order_acquire);
    if (req == -1) return;
    if (req > 0) toneActive_.store(true, std::memory_order_release);
    if (!toneRequest_.compare_exchange_strong(req, -1, std::memory_order_acq_rel)) return;
    const int64_t ramp = std::max<int64_t>(1, static_cast<int64_t>(0.01 * sr_));
    if (req > 0) {
        toneLeft_ = toneLen_ = req;
        tonePhase_ = 0;
    } else if (toneLeft_ > ramp) {
        toneLen_ -= toneLeft_ - ramp;
        toneLeft_ = ramp;
    }
}

double Engine::nextTone() noexcept {
    const int64_t ramp = std::max<int64_t>(1, static_cast<int64_t>(0.01 * sr_));
    const double done = static_cast<double>(toneLen_ - toneLeft_);
    const double env = std::min({1.0, (done + 1.0) / static_cast<double>(ramp),
                                 static_cast<double>(toneLeft_) / static_cast<double>(ramp)});
    const double v = 0.25 * env * std::sin(tonePhase_);
    tonePhase_ += kTwoPi * 440.0 / sr_;
    if (tonePhase_ >= kTwoPi) tonePhase_ -= kTwoPi;
    --toneLeft_;
    return v;
}

void Engine::mixToneOnly(float* left, float* right, int frames) noexcept {
    if (toneLeft_ <= 0) return;
    const double rel = detExp(-1.0 / (0.1 * sr_));
    const bool bypass = bypass_.load(std::memory_order_relaxed);
    for (int j = 0; j < frames && toneLeft_ > 0; ++j) {
        const double t = nextTone();
        const double yl = static_cast<double>(left[j]) + t, yr = static_cast<double>(right[j]) + t;
        const double env = std::max(std::fabs(yl), std::fabs(yr));
        limEnv_ = env > limEnv_ ? env : env + (limEnv_ - env) * rel;
        const double gain = bypass ? 1.0 : (limEnv_ > kLimitCeiling ? kLimitCeiling / limEnv_ : 1.0);
        left[j] = static_cast<float>(yl * gain);
        right[j] = static_cast<float>(yr * gain);
    }
}

void Engine::releaseTouches() {
    // The same bookkeeping as a Play, without moving the transport: chains drop their touches at their next chunk.
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::ReleaseTouches;
    c.playCount = playCount_ + 1;
    c.touchStamp = touchCounter_;
    if (!send(c)) return;
    playCount_ = c.playCount;
}

void Engine::stop() {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::Stop;
    send(c);
}

void Engine::startPlay(double fromStep, uint64_t playCount, uint32_t touchStamp) noexcept {
    playing_ = true;
    // Ringing tails play on into the new pass (state kept), as the effects would have.
    masterTailLeft_ = 0;
    masterTailFade_ = 0;
    for (int i = 0; i < slotCount_; ++i) {
        slotAt(i).insertTail = false;
        slotAt(i).tailFade = 0;
    }
    touchEpoch_ = playCount;  // chains from before this Play drop their touches at their next chunk
    touchPlayStamp_ = touchStamp;
    ++modPlays_;  // project modulators restart at the next chunk (#161)
    // Resuming starts mid-loop: each track works out its own loop pass from g_ at its next chunk. Code
    // there may be far from zero, and a Play during a stop fade cuts it short, so both fade in.
    // In steps, converted with the tempo the Transport commands before it set, so a tempo change made
    // while paused still resumes on the same beat.
    {
        const double at = std::isfinite(fromStep) && fromStep > 0 ? std::floor(fromStep * stepLen_ + 0.5) : 0.0;
        g_ = at > 0 && at < static_cast<double>(loopLen_) ? static_cast<int64_t>(at) : 0;
    }
    playRampIn_ = g_ > 0 || stopFade_ > 0 ? std::max(1, static_cast<int>(kStopSeconds * sr_)) : 0;
    stopFade_ = 0;
    epoch_ = 0;
    dcL_[0] = dcL_[1] = dcR_[0] = dcR_[1] = 0;
    limEnv_ = 0;
    // The instruments still ringing share the play-tail budget, so Play's callback stays bounded.
    {
        int ringing = 0;
        for (int i = 0; i < slotCount_; ++i)
            if (ringsAtPlay(slotAt(i))) ++ringing;
        const int tailLen = ringing > 0 ? std::max(1, kPlayTailBudgetFrames / ringing) : 0;
        for (int i = 0; i < slotCount_; ++i) {
            Slot& s = slotAt(i);
            if (!s.active) continue;
            s.playTailLen = s.playTailAt = 0;
            if (s.instrument) {
                // Pattern notes end; without a held preview the instrument starts from silence, as an export does.
                NoteEvents& notes = *s.instrument->notes();
                const bool rings = ringsAtPlay(s);
                notes.releaseAll(0, true);
                if (!notes.holdsPreview()) {
                    // Still sounding (a release after Stop): its next 5 ms (less when many ring) fade out
                    // over the new pass's start.
                    if (rings) playTail(s, tailLen);
                    s.instrument->reset();
                    notes.forget(false);
                    notes.clearEvents();
                }
            }
            s.fresh = true;
            s.k = -1;
            s.epoch = -1;
            updateSolo();
            const double target = slotTarget(s);
            s.gain = target > 0.0
                ? (s.automation ? automationValue(s.automation->volume, 0.0, target) : target)
                : 0.0;
        }
    }
}

// The metronome's click: 30 ms of a decaying sine, higher and louder on the bar's first beat. At most 0.5, so it
// stays under the safety limiter's ceiling even where it is mixed after it (the count-in's own output).
// The sound (setMetronomeSound) picks the length and pitch: Classic, Wood (lower and rounder) or Tick (short and
// high); the volume scales it.
void Engine::startClick(bool accent) noexcept {
    const int sound = clickSound_.load(std::memory_order_relaxed);
    const double seconds = sound == 1 ? 0.04 : sound == 2 ? 0.008 : 0.03;
    const double hz = sound == 1 ? (accent ? 880.0 : 660.0) : sound == 2 ? (accent ? 3520.0 : 2640.0)
                                                                         : (accent ? 1760.0 : 1320.0);
    clickLen_ = clickLeft_ = std::max(1, static_cast<int>(seconds * sr_));
    clickPhase_ = 0;
    clickInc_ = kTwoPi * hz / sr_;
    clickAmp_ = (accent ? 0.5 : 0.32) * static_cast<double>(clickVolume_.load(std::memory_order_relaxed));
}

double Engine::nextClick() noexcept {
    if (clickLeft_ <= 0) return 0.0;
    const double t = 1.0 - static_cast<double>(clickLeft_--) / clickLen_;  // 0..1 through the click
    const double env = (1.0 - t) * (1.0 - t);
    const double v = clickAmp_ * env * std::sin(clickPhase_);
    clickPhase_ += clickInc_;
    return v;
}

void Engine::clearOverload() {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::ClearOverload;
    send(c);
}

int64_t Engine::loopLength() {
    std::lock_guard<std::mutex> lock(ctl_);
    return ctlLoopLen_;
}

Meters Engine::meters() {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    Meters m;
    m.cpu = cpu_.load(std::memory_order_relaxed);
    m.peakL = peakL_.exchange(0, std::memory_order_relaxed);
    m.peakR = peakR_.exchange(0, std::memory_order_relaxed);
    m.playing = playingFlag_.load(std::memory_order_relaxed);
    m.position = posFlag_.load(std::memory_order_relaxed);
    m.loopLength = loopLenFlag_.load(std::memory_order_relaxed);
    m.overloaded = overloadedFlag_.load(std::memory_order_relaxed);
    return m;
}

bool Engine::layerMeter(int index, LayerMeter& out) {
    std::lock_guard<std::mutex> lock(ctl_);
    out = LayerMeter{};
    if (index < 0 || index >= static_cast<int>(order_.size())) return false;
    auto it = layers_.find(order_[index]);
    if (it == layers_.end() || it->second.slot < 0) return true;
    Slot& s = ctlSlot(it->second.slot);
    out.active = true;
    out.peakL = s.peakL.exchange(0, std::memory_order_relaxed);
    out.peakR = s.peakR.exchange(0, std::memory_order_relaxed);
    out.peak = std::max(out.peakL, out.peakR);
    out.progress = s.progress.load(std::memory_order_relaxed);
    out.overloaded = s.overloadFlag.load(std::memory_order_relaxed);
    return true;
}

LoudnessMeter::Reading Engine::loudness() {
    std::lock_guard<std::mutex> lock(ctl_);  // one reader at a time
    return loudness_->read();
}

void Engine::resetLoudness() { loudness_->requestReset(); }

bool Engine::layerCorrelation(int index, float& out) {
    std::lock_guard<std::mutex> lock(ctl_);
    out = 0.0f;
    if (index < 0 || index >= static_cast<int>(order_.size())) return false;
    auto it = layers_.find(order_[index]);
    if (it == layers_.end() || it->second.slot < 0) return true;
    out = ctlSlot(it->second.slot).correlation.read();
    return true;
}

bool Engine::setOutputTap(const std::string& layerId, float* left, float* right) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = layers_.find(layerId);
    if (!left || !right || it == layers_.end() || it->second.slot < 0) return false;
    Slot& s = ctlSlot(it->second.slot);
    s.tapL = left;
    s.tapR = right;
    return true;
}

void Engine::clearOutputTaps() {
    std::lock_guard<std::mutex> lock(ctl_);
    for (int i = 0; i < ctlTable_->capacity; ++i) ctlSlot(i).tapL = ctlSlot(i).tapR = nullptr;
}

int Engine::scope(int index, float* out, int n) {
    std::lock_guard<std::mutex> lock(ctl_);
    n = std::min(n, kScopeSize);
    const std::atomic<float>* ring = masterScope_.get();
    int pos = masterScopePos_.load(std::memory_order_acquire);
    if (index != kScopeMaster) {
        int slot = -1;
        if (index == kScopeAudition) {
            slot = ctlTable_->capacity;  // auditionSlot()
        } else if (index >= 0 && index < static_cast<int>(order_.size())) {
            auto it = layers_.find(order_[index]);
            if (it != layers_.end()) slot = it->second.slot;
        }
        if (slot < 0) {
            std::fill_n(out, n, 0.0f);
            return n;
        }
        ring = ctlSlot(slot).scope;
        pos = ctlSlot(slot).scopePos.load(std::memory_order_acquire);
    }
    for (int i = 0; i < n; ++i) out[i] = ring[(pos - n + i + kScopeSize) % kScopeSize].load(std::memory_order_relaxed);
    return n;
}

// ===================== audio thread =====================

void Engine::updateTiming() noexcept {
    stepLen_ = 60.0 * sr_ / (bpm_ * 4.0);
    loopLen_ = static_cast<int64_t>(std::floor(loopSteps_ * stepLen_ + 0.5));
    if (loopLen_ < 1) loopLen_ = 1;
    loopFrom_ = loopRange_ ? std::clamp<int64_t>(static_cast<int64_t>(std::floor(loopFromSteps_ * stepLen_ + 0.5)), 0, loopLen_ - 1) : 0;
    loopTo_ = loopRange_ ? std::clamp<int64_t>(static_cast<int64_t>(std::floor(loopToSteps_ * stepLen_ + 0.5)), loopFrom_ + 1, loopLen_) : loopLen_;
}

int64_t Engine::wrapAt() const noexcept { return loopRange_ && g_ < loopTo_ ? loopTo_ : loopLen_; }

bool Engine::canRetire(size_t count) const noexcept {
    // The callback may use the queue plus its preallocated overflow list. When
    // overflow is already in use, retire() appends there until the control thread
    // drains the queue and a later callback can move the pending entries across.
    const size_t pendingFree = static_cast<size_t>(pendingMax_ - pendingCount_);
    if (pendingCount_ != 0) return count <= pendingFree;
    return count <= retired_->writable() + pendingFree;
}

void Engine::retire(Slot* freed, std::shared_ptr<const Pattern>* pattern, AutomationData* automation,
                    std::vector<int>* order, SlotTable* table, ComponentChain* masterChain) noexcept {
    if (!freed && !pattern && !automation && !order && !table && !masterChain) return;
    retireEntry(Retired{freed, pattern, automation, order, table, masterChain});
}

void Engine::retireEntry(const Retired& r) noexcept {
    if (pendingCount_ == 0 && retired_->push(r)) return;
    if (pendingCount_ < pendingMax_) pending_[pendingCount_++] = r;
    // All callers reserve queue capacity before changing ownership. This is a
    // defensive fallback; command processing is paused while pending is non-empty.
}

void Engine::applyCommands() noexcept {
    // Move what fits into the queue, in order, then close the gap once (a Play at a large capacity
    // can leave hundreds pending).
    int moved = 0;
    while (moved < pendingCount_ && retired_->push(pending_[moved])) ++moved;
    if (moved > 0) {
        std::copy(pending_.get() + moved, pending_.get() + pendingCount_, pending_.get());
        pendingCount_ -= moved;
    }
    // Non-retiring controls may still pass a full retirement backlog (for example Stop).
    // Commands that replace or release owned objects remain blocked by canRetire().
    Cmd c;
    while (cmds_->peek(c)) {
        size_t retirementNeed = 0;
        switch (c.type) {
            case Cmd::SetMasterChain:
            case Cmd::SetInserts:
            case Cmd::SetInstrument:
            case Cmd::SetDelay: retirementNeed = 2; break;
            case Cmd::SetSends: retirementNeed = 1; break;  // the one still crossfading, and the one replaced  // a chain still crossfading, and the one replaced
            case Cmd::SetAutomation:
            case Cmd::SetComponentAutomation:
            case Cmd::SetPattern:
            case Cmd::Remove:
            case Cmd::SetOrder:
            case Cmd::Grow: retirementNeed = 1; break;
            case Cmd::ConfigureBus: retirementNeed = c.flag ? 7 : 6; break;
            default: break;
        }
        if (!canRetire(retirementNeed) || !cmds_->pop(c)) break;
        routingDirty_ = true;  // any command may change slots, buses or order
        switch (c.type) {
            case Cmd::Install: {
                // The slot becomes a track (its instrument and inserts arrive by their own commands).
                Slot& s = slotAt(c.slot);
                s.steps = c.steps;
                s.order = c.order;
                if (!s.active || s.removing || !s.track) {
                    s.track = true;
                    s.peakL.store(0, std::memory_order_relaxed);  // a reused slot doesn't show its last owner's level
                    s.peakR.store(0, std::memory_order_relaxed);
                    s.correlation.clear();
                    s.active = true;
                    markLive(c.slot);
                    s.removing = false;
                    s.fresh = true;
                    s.overloaded = false;
                    s.bus = false;
                    s.overloadFlag.store(false, std::memory_order_relaxed);
                    s.k = -1;
                    s.epoch = -1;
                    updateSolo();
                    const double initialTarget = slotTarget(s);
                    s.gain = initialTarget > 0.0 && s.automation && !s.automation->volume.empty() ? s.automation->volume.front().value : initialTarget;
                }
                break;
            }
            case Cmd::SetSteps:
                slotAt(c.slot).steps = c.steps;
                break;
            case Cmd::SetRouting: {
                Slot& s = slotAt(c.slot);
                s.parentSlot = c.parentSlot;
                s.bus = false;
                break;
            }
            case Cmd::SetAutomation: {
                Slot& s = slotAt(c.slot);
                retire(nullptr, nullptr, s.automation);
                s.automation = c.automation;
                if (c.flag && s.bus) {
                    const double initialTarget = slotTarget(s);
                    s.gain = initialTarget > 0.0 && s.automation && !s.automation->volume.empty()
                        ? s.automation->volume.front().value : initialTarget;
                }
                break;
            }
            case Cmd::ConfigureBus: {
                Slot& s = slotAt(c.slot);
                if (!c.flag && s.bus && s.active && !s.removing) {
                    // Already this bus: its inserts, delay and routes stay (they have their own commands).
                    s.parentSlot = c.parentSlot;
                    s.order = c.order;
                    break;
                }
                retire(nullptr, s.pattern);
                {
                    Retired r{nullptr, nullptr, nullptr, nullptr, nullptr, s.inserts};  // a new bus starts without them
                    r.delay = s.delay;
                    if (r.masterChain || r.delay) retireEntry(r);
                }
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
                s.insertsFading = nullptr;
                s.insertsFadeLeft = 0;
                s.inserts = nullptr;
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.instrument);
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.instrumentFading);
                s.instrument = s.instrumentFading = nullptr;
                s.instrumentFadeLeft = 0;
                s.delay = nullptr;
                {
                    Retired d;
                    d.delay = s.delayFading;
                    if (d.delay) retireEntry(d);
                    s.delayFading = nullptr;
                    s.delayFadeLeft = 0;
                }
                s.track = false;
                s.pattern = nullptr;
                s.peakL.store(0, std::memory_order_relaxed);
                s.peakR.store(0, std::memory_order_relaxed);
                s.correlation.clear();
                s.active = true;
                markLive(c.slot);
                s.removing = false;
                s.bus = true;
                if (c.flag) {
                    retire(nullptr, nullptr, s.automation);
                    s.automation = nullptr;
                }
                s.parentSlot = c.parentSlot;
                s.order = c.order;
                s.gain = slotTarget(s);
                updateSolo();
                break;
            }
            case Cmd::SetPattern: {
                Slot& s = slotAt(c.slot);
                // A sounding note that the edit kept (matchPatternNotes) moves onto its new note on the slot's next
                // run, which knows the playhead: it sounds on and follows the new curve. One the edit deleted ends.
                const std::vector<int>* map = c.orderList;
                auto carried = [map](uint32_t note) {
                    return map && note < map->size() ? (*map)[note] : -1;
                };
                if (s.instrument) {
                    // None keeps pointing into the old pattern.
                    NoteEvents& notes = *s.instrument->notes();
                    for (NoteEvents::Held& h : notes.held()) {
                        if (!h.active || h.source != NoteEvents::Source::Pattern) continue;
                        h.ex = nullptr;
                        const int to = carried(h.note);
                        if (to < 0) {
                            notes.off(0, h);
                            continue;
                        }
                        h.note = static_cast<uint32_t>(to);
                        h.rebind = true;
                    }
                }
                retire(nullptr, s.pattern, nullptr, c.orderList);
                s.pattern = c.pattern;
                break;
            }
            case Cmd::Remove: {
                Slot& s = slotAt(c.slot);
                s.removing = true;
                retire(nullptr, nullptr, s.automation);
                s.automation = nullptr;
                break;
            }
            case Cmd::Transport:
                // A tempo change moves every note in time: let held notes go so none is left hanging.
                if (c.bpm != bpm_)
                    for (int i = 0; i < slotCount_; ++i)
                        if (slotAt(i).instrument) slotAt(i).instrument->notes()->releaseAll(0, true);
                bpm_ = c.bpm;
                beatsPerBar_ = c.beatsPerBar;
                loopSteps_ = c.loopSteps;
                loopRange_ = c.loopRange;
                loopFromSteps_ = c.loopFromSteps;
                loopToSteps_ = c.loopToSteps;
                seed_ = c.seed;
                master_ = masterTarget_ = c.master;
                masterStep_ = 0.0;
                masterRamp_ = 0;
                updateTiming();
                if (g_ >= loopLen_) g_ = 0;
                loopLenFlag_.store(loopLen_, std::memory_order_relaxed);
                break;
            case Cmd::SetMaster:
                masterTarget_ = std::isfinite(c.master) ? std::clamp(c.master, 0.0, kMaxMixGain) : 0.0;
                masterRamp_ = std::max(1, static_cast<int>(sr_ * kGainSeconds));
                masterStep_ = (masterTarget_ - master_) / masterRamp_;
                break;
            case Cmd::SetMasterChain:
                // The replaced chain crossfades out (a rebuild, an effect added or removed: no click).
                {
                    // As for track inserts: keep whichever side of a running crossfade is heard more now.
                    const int fadeLen = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                    if (masterFadeLeft_ * 2 > fadeLen) std::swap(masterChain_, masterFading_);
                }
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, masterFading_);
                masterFading_ = nullptr;
                masterFadeLeft_ = 0;
                if (playing_ || previewing_) {  // sounding: crossfade; otherwise the next sound starts on the new chain
                    masterFading_ = masterChain_;
                    masterFadeLeft_ = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                } else {
                    retire(nullptr, nullptr, nullptr, nullptr, nullptr, masterChain_);
                }
                masterChain_ = c.masterChain;
                break;
            case Cmd::SetDelay: {
                Slot& s = slotAt(c.slot);
                Retired r;
                r.delay = s.delayFading;  // a delay change still crossfading: its old line goes
                s.delayFading = nullptr;
                s.delayFadeLeft = 0;
                if (r.delay) retireEntry(r);
                if (c.delay && !s.delayStale) c.delay->takeHistory(s.delay);
                if ((s.mode == Slot::Mode::Play || s.mode == Slot::Mode::Bus) && !s.delayStale) {
                    s.delayFading = s.delay;  // sounding: the timing change crossfades
                    s.delayFadeLeft = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                } else if (s.delay) {
                    Retired old;
                    old.delay = s.delay;
                    retireEntry(old);
                }
                s.delay = c.delay;
                break;
            }
            case Cmd::SetSends: {
                Slot& s = slotAt(c.slot);
                SendTable* next = c.sends;
                if (next) {
                    for (int k = 0; k < next->count; ++k) {
                        SendTable::Route& r = next->routes[k];
                        const SendTable::Route* was = s.sends && k < s.sends->count ? &s.sends->routes[k] : nullptr;
                        // A route that stays keeps its gain, its tap (a change of tap then fades as SetSendLevel's
                        // does) and, unless stale, its delay's recent input. A route that now goes elsewhere starts
                        // from silence: its old line holds the old destination's audio.
                        const bool stays = was && was->dest == r.dest && was->key == r.key;
                        if (!stays) s.routeGain[k] = 0.0;
                        if (stays && s.routeGain[k] > 0.0) r.tapPre = was->tapPre;
                        if (r.delay && stays && !s.routesStale) r.delay->takeHistory(was->delay);
                    }
                }
                Retired r;
                r.sends = s.sends;
                if (r.sends) retireEntry(r);
                s.sends = next;
                break;
            }
            case Cmd::SetSendLevel: {
                Slot& s = slotAt(c.slot);
                if (s.sends && c.order >= 0 && c.order < s.sends->count) {
                    SendTable::Route& r = s.sends->routes[c.order];
                    r.level = c.master;
                    r.pre = c.flag;  // runRoutes moves the tap over, through silence
                    if (s.routeGain[c.order] == 0.0) r.tapPre = r.pre;
                    r.mute = c.sendMute;
                }
                break;
            }
            case Cmd::SetComponentAutomation: {
                ComponentChain* chain = c.slot < 0 ? masterChain_ : c.flag ? slotAt(c.slot).instrument : slotAt(c.slot).inserts;
                Retired r;
                // No chain (it was replaced in the meantime): the table is retired unused.
                r.componentAutomation = chain ? chain->swapAutomation(c.componentAutomation) : c.componentAutomation;
                if (r.componentAutomation) retireEntry(r);
                break;
            }
            case Cmd::SetInserts: {
                Slot& s = slotAt(c.slot);
                // A swap still crossfading: keep whichever side is heard more now, so nothing is cut short.
                const int fadeLen = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                if (s.insertsFadeLeft * 2 > fadeLen) std::swap(s.inserts, s.insertsFading);
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
                s.insertsFading = nullptr;
                s.insertsFadeLeft = 0;
                if (s.mode == Slot::Mode::Play || s.mode == Slot::Mode::Bus) {
                    s.insertsFading = s.inserts;  // sounding: crossfades out (null: from the dry signal)
                    s.insertsFadeLeft = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                } else {
                    retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.inserts);
                }
                s.inserts = c.masterChain;
                break;
            }
            case Cmd::SetInstrument: {
                Slot& s = slotAt(c.slot);
                const int fadeLen = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                ComponentChain* next = c.masterChain;
                // Held notes move to the new instrument (a rebuild or a new choice keeps a note sounding);
                // the old one lets them go and rings out as it crossfades. They are taken over from the
                // instrument that holds them, the current one, even when a swap still crossfading keeps the
                // one it replaced (whose notes were let go) as the side heard more.
                if (s.instrument && next && !s.instrumentIdle) next->notes()->takeOver(*s.instrument->notes());
                if (s.instrumentFadeLeft * 2 > fadeLen) std::swap(s.instrument, s.instrumentFading);
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.instrumentFading);
                s.instrumentFading = nullptr;
                s.instrumentFadeLeft = 0;
                if (s.mode == Slot::Mode::Play && s.instrument && !s.instrumentIdle) {
                    s.instrument->notes()->releaseAll(0, false);
                    s.instrumentFading = s.instrument;
                    s.instrumentFadeLeft = fadeLen;
                } else {
                    retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.instrument);
                    // Not sounding: it starts from silence when it first runs, so a Play doesn't take it for an
                    // instrument still ringing out and mix in a tail of what it never played (playTail).
                    s.instrumentIdle = next != nullptr;
                }
                s.instrument = next;
                break;
            }
            case Cmd::Play:
                countInLeft_ = 0;
                if (c.countInBeats > 0 && stepLen_ > 0 && !playing_) {
                    // Count-in: clicks first; process() starts the playback when they end.
                    countInBeat_ = std::max<int64_t>(1, static_cast<int64_t>(std::llround(4.0 * stepLen_)));
                    countInLeft_ = countInBeat_ * c.countInBeats;
                    countInAt_ = 0;
                    countInFrom_ = c.fromStep;
                    countInPlayCount_ = c.playCount;
                    countInTouchStamp_ = c.touchStamp;
                    if (!playing_) break;  // while playing it starts at once, as a Play
                    countInLeft_ = 0;
                }
                startPlay(c.fromStep, c.playCount, c.touchStamp);
                break;
            case Cmd::Metronome:
                metronome_ = c.flag;
                break;
            case Cmd::ReleaseTouches:
                touchEpoch_ = c.playCount;  // as a Play: chains end their touches at their next chunk
                touchPlayStamp_ = c.touchStamp;
                break;
            case Cmd::Stop:
                countInLeft_ = 0;  // a Stop during the count-in cancels it
                if (playing_ && stopFade_ == 0) stopFade_ = std::max(1, static_cast<int>(kStopSeconds * sr_));
                playRampIn_ = 0;
                break;
            case Cmd::AuditionOnly:
                auditionOnly_ = c.flag;
                break;
            case Cmd::Preview:
                previewCommand(c);
                break;
            case Cmd::SetOrder:
                processCount_ = 0;
                if (c.orderList) {
                    processCount_ = std::min(static_cast<int>(c.orderList->size()), slotCount_);
                    std::copy_n(c.orderList->data(), processCount_, processOrder_);
                }
                retire(nullptr, nullptr, nullptr, c.orderList);  // freed on the control thread
                break;
            case Cmd::Grow: {
                // A larger table from the control thread: the same Slot objects for every layer
                // slot (same addresses, same indices) plus new idle ones, and the audition moved to
                // the new last index. No slot state changes, so nothing is heard; routing is
                // re-derived (routingDirty_) before the next chunk runs the new graph.
                SlotTable& t = *c.table;
                for (int k = 0; k < processCount_; ++k)
                    t.processOrder[k] = processOrder_[k] == auditionSlot_ ? t.capacity : processOrder_[k];
                for (int k = 0; k < liveCount_; ++k)  // the audition stays last: still ascending
                    t.live[k] = live_[k] == auditionSlot_ ? t.capacity : live_[k];
                t.slots[t.capacity]->index = t.capacity;
                retire(nullptr, nullptr, nullptr, nullptr, table_.release());  // freed on the control thread
                table_.reset(c.table);  // table_ held nothing after release(): no delete here
                bindTable();
                break;
            }
            case Cmd::ClearOverload:
                for (int i = 0; i < slotCount_; ++i) {
                    slotAt(i).overloaded = false;
                    slotAt(i).overloadFlag.store(false, std::memory_order_relaxed);
                }
                overloadedFlag_.store(0, std::memory_order_relaxed);
                break;
        }
    }
}

double Engine::slotTarget(const Slot& s) const noexcept {
    if (s.removing || s.overloaded) return 0.0;
    if (auditionOnly_) return s.index == auditionSlot_ ? bitsToDouble(s.vol.load(std::memory_order_relaxed)) : 0.0;
    if (s.index == auditionSlot_) return 0.0;
    if (s.mute.load(std::memory_order_relaxed)) return 0.0;
    if (anySolo_ && !s.solo.load(std::memory_order_relaxed)) return 0.0;
    return s.automation && !s.automation->volume.empty() ? 1.0 : bitsToDouble(s.vol.load(std::memory_order_relaxed));
}

void Engine::updateSolo() noexcept {
    bool any = false;
    for (int k = 0; k < liveCount_ && !any; ++k) {
        const int i = live_[k];
        if (i >= capacity_) break;  // the audition, always last
        any = slotAt(i).active && !slotAt(i).removing && slotAt(i).solo.load(std::memory_order_relaxed);
    }
    anySolo_ = any;
}

int64_t Engine::loopStart(const Slot& s, int64_t k) const noexcept {
    return static_cast<int64_t>(std::floor(static_cast<double>(k) * (s.steps * stepLen_) + 0.5));
}

// The note's expression `into` samples after it took the voice: bend (curve + vibrato), press and timbre.
static void expressionAt(const NoteExpression& x, double into, double len, double sr, double& bend, double& press, double& timbre) {
    const double u = std::clamp(into / len, 0.0, 1.0);
    bend = !x.bend.points.empty() ? x.bend.at(u) : 0.0;
    if (x.vibDepth > 0) {
        const double fade = x.vibDelay > 0 ? std::clamp(u / x.vibDelay, 0.0, 1.0) : 1.0;
        bend += x.vibDepth * fade * detSin(kTwoPi * x.vibRate * into / sr);
    }
    press = !x.press.points.empty() ? x.press.at(u) : 1.0;
    timbre = !x.timbre.points.empty() ? x.timbre.at(u) : 0.0;
}

// A free voice, else the oldest released one, else the oldest; a sounding voice it takes is smoothed over.
// Callback start: device messages from the queue join the ones a past callback kept for later, and each gets its
// frame in this callback. A message for a track that is not running wakes it as a preview does, so a key played
// while stopped is heard.
void Engine::takeDeviceMidi(int frames) noexcept {
    const int64_t test = midiClockTest_.load(std::memory_order_relaxed);
    const int64_t now = test >= 0 ? test : midiClockNs();
    cbTimeNs_.store(now, std::memory_order_relaxed);
    cbPos_.store(playing_ ? g_ : -1, std::memory_order_release);
    midiChunkFrom_ = 0;
    Midi2Event e;
    while (midiIn_.pop(e)) {
        if (midiPendingCount_ == Midi2InputQueue::kCapacity) {
            midiPendingDropped_.fetch_add(1, std::memory_order_relaxed);
            continue;
        }
        PendingMidi& p = midiPending_[midiPendingCount_++];
        p.e = e;
        p.done = false;
    }
    if (midiPendingCount_ == 0) return;
    const int64_t delay = midiDelayNs_.load(std::memory_order_relaxed);
    for (uint32_t k = 0; k < midiPendingCount_; ++k) {
        PendingMidi& p = midiPending_[k];
        if (p.e.type == Midi2EventType::AllOff) {  // at once, whatever its time
            const DeviceMidiOptions o{};
            for (int i = 0; i < slotCount_; ++i) {
                if (p.e.target >= 0 && i != p.e.target) continue;
                Slot& s = slotAt(i);
                if (s.instrument) s.deviceNotes.apply(*s.instrument->notes(), p.e, 0, o);  // its notes, then reset
                else s.deviceNotes.reset();
            }
            p.done = true;
            continue;
        }
        p.frame = deviceMidiFrame(p.e.timeNs, now, frames, sr_, delay);
        if (p.frame >= frames) continue;  // a later callback's
        if (p.e.target < 0 || p.e.target >= slotCount_) {
            p.done = true;
            continue;
        }
        Slot& s = slotAt(p.e.target);
        if (!s.active || !s.track || !s.instrument) {
            p.done = true;
            continue;
        }
        const bool on = p.e.type == Midi2EventType::NoteOn;
        if (on && !s.previewing) {
            s.previewing = true;
            s.previewQuiet = s.previewTail = 0;
            markLive(p.e.target);
        }
        if (on) previewing_ = true;
    }
}

// The chunk's device messages for s (and any earlier one it did not run for), at their frames in it.
void Engine::feedDeviceMidi(Slot& s, NoteEvents& notes, int m) noexcept {
    const DeviceMidiOptions o{midiMpe_.load(std::memory_order_relaxed), midiBendRange_.load(std::memory_order_relaxed),
                              midiNoteBendRange_.load(std::memory_order_relaxed)};
    const int64_t end = midiChunkFrom_ + m;
    for (uint32_t k = 0; k < midiPendingCount_; ++k) {
        PendingMidi& p = midiPending_[k];
        if (p.done || p.e.target != s.index || p.frame >= end) continue;
        const int64_t at = p.frame - midiChunkFrom_;
        s.deviceNotes.apply(notes, p.e, static_cast<uint32_t>(at < 0 ? 0 : at), o);
        p.done = true;
    }
}

// Callback end: messages for later callbacks stay; delivered ones, and ones for a track that did not run, go.
void Engine::endDeviceMidi(int frames) noexcept {
    uint32_t keep = 0;
    for (uint32_t k = 0; k < midiPendingCount_; ++k) {
        const PendingMidi& p = midiPending_[k];
        if (p.done || p.frame < frames) continue;
        midiPending_[keep++] = p;
    }
    midiPendingCount_ = keep;
}

// Note previews (#103) on the audio thread: a note on, a pitch glide or a note off on the track's instrument, with
// the caller's id.
void Engine::previewCommand(const Cmd& c) noexcept {
    if (c.previewOp == 3) {
        for (int i = 0; i < slotCount_; ++i) {
            Slot& s = slotAt(i);
            // The app's previews only: a device's held keys stay (caw_engine_midi_release ends those).
            if (s.instrument) s.instrument->notes()->releasePreviews(0, kDevicePreviewBase);
        }
        return;
    }
    if (c.slot < 0 || c.slot >= slotCount_) return;
    Slot& s = slotAt(c.slot);
    if (!s.active || !s.track || !s.instrument) return;
    NoteEvents& notes = *s.instrument->notes();
    if (s.instrumentIdle) {  // it hasn't run since it fell silent: start it from silence now
        s.instrument->reset();
        notes.forget(false);
        notes.clearEvents();
        s.instrumentIdle = false;
    }
    NoteEvents::Held* held = notes.findPreview(c.previewId);
    if (c.previewOp == 1) {
        if (!held) return;
        held->target = c.pitch;
        held->glideLeft = std::max(1, static_cast<int>(std::floor(kPreviewGlideSeconds * sr_ + 0.5)));
        held->glideStep = (held->target - held->pitch) / held->glideLeft;
        held->motionFrom = 0;
        held->motionWait = 0;
        return;
    }
    if (c.previewOp == 2) {
        if (held) notes.off(0, *held);
        return;
    }
    notes.on(0, NoteEvents::Source::Preview, 0, 0, c.previewId, c.pitch, c.vel);
    s.previewing = true;
    s.previewQuiet = s.previewTail = 0;
    previewing_ = true;
}

// After a callback: which slots still preview. A slot keeps running after its last preview note ends until its
// output (an effect's tail) has stayed below -80 dB for a moment, so a reverb isn't cut off; a muted or soloed-out
// slot doesn't run, so its previews end at once. Only previewing slots are looked at: no cost when none was played.
void Engine::updatePreviewing(int frames) noexcept {
    bool any = false;
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        if (!s.previewing) continue;
        const bool silent = !s.active || (slotTarget(s) == 0.0 && s.gain == 0.0);
        bool voices = false;  // a preview note is held
        if (s.instrument && (s.instrument->notes()->holdsPreview() || s.instrument->monitorsStopped())) {
            if (silent) {
                s.instrument->notes()->releasePreviews(0);
                s.instrumentIdle = true;
            } else {
                voices = true;
            }
        }
        s.previewTail = voices ? 0 : s.previewTail + frames;
        const int64_t cap = s.insertTail ? s.tailCap : static_cast<int64_t>(kPreviewTailSeconds * sr_);
        const bool quiet = s.previewQuiet >= static_cast<int64_t>(kPreviewQuietSeconds * sr_);
        // A tail still audible at its cap fades out instead of stopping dead.
        if (s.insertTail && !voices && !silent && !quiet && s.previewTail >= cap && s.tailFade == 0)
            s.tailFade = std::max(1, static_cast<int>(kSwapSeconds * sr_));
        const bool fadingOut = s.insertTail && s.tailFade > 0;
        const bool runs = s.bus ? s.insertTail : s.track;
        const bool live = voices || (!silent && runs && !quiet && s.tailFade >= 0 && (s.previewTail < cap || fadingOut));
        if (!live && s.insertTail) {
            s.insertTail = false;
            s.tailFade = 0;
            s.insertsIdle = true;  // rung out: start from silence next time
        }
        s.previewing = live;
        any = any || live;
    }
    if (masterTailLeft_ > 0) {
        const bool quiet = masterQuiet_ >= static_cast<int64_t>(kPreviewQuietSeconds * sr_);
        if (quiet || masterTailFade_ < 0) {
            masterTailLeft_ = 0;
        } else if (masterTailFade_ == 0) {
            masterTailLeft_ = std::max<int64_t>(0, masterTailLeft_ - frames);
            if (masterTailLeft_ == 0) {  // at its cap and still audible: fade out first
                masterTailFade_ = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                masterTailLeft_ = 1;
            }
        }
        if (masterTailLeft_ == 0) {
            masterTailFade_ = 0;
            if (masterChain_) masterChain_->reset();
        }
        any = any || masterTailLeft_ > 0;
    }
    previewing_ = any;
}

// The stop fade has reached silence: pattern notes end and effects start from silence, so a later preview hears
// neither the chord that was playing nor a frozen tail. Held previews keep their voices; the master fades them back
// in. Stopped, a track's time runs on from where it stopped (preview chunks).
void Engine::endPlayback() noexcept {
    // Native effects with a tail (a delay, a reverb) ring out on silence until they are quiet, as
    // in a DAW; the rest start the next play from silence, as a fresh render (an export) does.
    auto tailCap = [&](const ComponentChain& c) -> int64_t {
        const uint32_t tail = c.tailFrames();
        const int64_t most = static_cast<int64_t>(kPreviewTailSeconds * sr_);
        return tail == kInfiniteTail ? most : std::min<int64_t>(tail, most);
    };
    if (masterChain_) {
        masterTailLeft_ = tailCap(*masterChain_);
        masterQuiet_ = 0;
        masterTailFade_ = 0;
        if (masterTailLeft_ > 0) previewing_ = true;
        else masterChain_->reset();
    }
    for (int i = 0; i < slotCount_; ++i) {
        Slot& s = slotAt(i);
        s.delayStale = true;  // the next play starts from silence, as an export does, not the song's last frames
        s.routesStale = true;
        if (s.inserts) {
            s.tailCap = tailCap(*s.inserts);
            if (s.tailCap > 0 && s.active && !(slotTarget(s) == 0.0 && s.gain == 0.0)) {  // a bus's reverb rings out too
                s.insertTail = true;
                s.tailFade = 0;
                s.previewing = true;
                s.previewTail = 0;
                previewing_ = true;
            } else {
                s.inserts->reset();
            }
        }
        if (!s.track) continue;
        // The instrument's notes end and ring out (their release, its effects' tails) until quiet.
        if (s.instrument && !s.instrumentIdle) s.instrument->notes()->releaseAll(0, true);
        s.insertTail = false;  // the track runs whole, as for a preview, not just its inserts
        if (s.active && !s.bus && !(slotTarget(s) == 0.0 && s.gain == 0.0)) {
            s.previewing = true;
            s.previewTail = 0;
            previewing_ = true;
        }
        s.previewN = s.lastN + 1;
        s.previewQuiet = 0;
    }
    previewRampIn_ = previewing_ ? std::max(1, static_cast<int>(kStopSeconds * sr_)) : 0;
}

bool Engine::playsNotes(const Slot& s) noexcept { return s.track; }

// Where sub-note `sub` of pattern note `n` sounds, in samples of the layer pass; false when it has no such repeat.
bool Engine::noteSpan(const PatternNote& n, uint32_t sub, int64_t& start, int64_t& stop) const noexcept {
    const int ratchet = std::max(1, n.ratchet);
    if (sub >= static_cast<uint32_t>(ratchet)) return false;
    const double part = n.len / ratchet;
    start = static_cast<int64_t>(std::floor((n.at + part * sub) * stepLen_ + 0.5));
    stop = static_cast<int64_t>(std::floor((n.at + part * (sub + 1)) * stepLen_ + 0.5));
    return true;
}

// A held note carried across a pattern edit, at the start of its next chunk (n0): if its new note still covers the
// playhead it sounds on and its motion carries on from the next control point of its grid (the grid's phase is
// kept), now on the new note's curve, gliding there over kRebindGlideSeconds; otherwise it is released.
void Engine::rebindNote(NoteEvents& notes, NoteEvents::Held& h, const Pattern* pat, int64_t n0) noexcept {
    h.rebind = false;
    int64_t start = 0, stop = 0;
    const PatternNote* n = pat && h.note < pat->notes.size() ? &pat->notes[h.note] : nullptr;
    if (!n || !noteSpan(*n, h.sub, start, stop) || n0 < start || n0 >= stop) {
        notes.off(0, h);
        return;
    }
    const bool expressive = n->extra >= 0 && static_cast<size_t>(n->extra) < pat->expressions.size();
    h.ex = expressive ? &pat->expressions[static_cast<size_t>(n->extra)] : nullptr;
    h.exLen = std::max(1.0, n->len / std::max(1, n->ratchet) * stepLen_);
    h.since = n0 + static_cast<int64_t>(h.motionFrom) + h.motionWait - start;  // at its next control point
    double bend = 0, press = 1, timbre = 0;
    if (h.ex) expressionAt(*h.ex, static_cast<double>(h.since), h.exLen, sr_, bend, press, timbre);
    // A curve the new note doesn't have goes back to its resting value.
    if (!h.ex || h.ex->press.points.empty()) notes.pressure(0, h, 1.0);
    if (!h.ex || h.ex->timbre.points.empty()) notes.timbre(0, h, 0.0);
    h.vel = n->vel;
    h.pitch = h.sentPitch - bend;
    h.target = n->pitch;
    // Whole control steps, so the glide ends on a grid point.
    const int steps = std::max(1, static_cast<int>(std::floor(kRebindGlideSeconds * sr_ / kExpressionStep + 0.5)));
    h.glideLeft = steps * kExpressionStep;
    h.glideStep = (h.target - h.pitch) / h.glideLeft;
}

// The pattern's notes in this chunk as the instrument's events, on their exact frames: chance per repeat, ratchets,
// slides (the held note glides on, no new attack), the note's expression, and held notes carried across a pattern
// edit following their new note.
void Engine::instrumentNotes(Slot& s, NoteEvents& notes, int m) noexcept {
    const int64_t n0 = s.n0, end = n0 + m;
    const Pattern* pat = s.pat;
    auto sampleOf = [this](double step) { return static_cast<int64_t>(std::floor(step * stepLen_ + 0.5)); };
    for (NoteEvents::Held& h : notes.held())
        if (h.active && h.rebind) rebindNote(notes, h, pat, n0);
    if (!pat) return;
    const PatternEvent* ev = pat->events.data();
    const size_t ne = pat->events.size();
    size_t e = static_cast<size_t>(
        std::partition_point(ev, ev + ne, [&](const PatternEvent& x) { return sampleOf(x.step) < n0; }) - ev);
    auto express = [&](NoteEvents::Held& h, const PatternNote& n, uint32_t frame) noexcept {
        const bool expressive = n.extra >= 0 && static_cast<size_t>(n.extra) < pat->expressions.size();
        h.ex = expressive ? &pat->expressions[static_cast<size_t>(n.extra)] : nullptr;
        h.exLen = std::max(1.0, n.len / std::max(1, n.ratchet) * stepLen_);
        h.since = 0;
        h.motionFrom = frame;
        h.motionWait = 0;
    };
    for (; e < ne && sampleOf(ev[e].step) < end; ++e) {
        const PatternEvent& pe = ev[e];
        const PatternNote& n = pat->notes[pe.note];
        const uint32_t frame = static_cast<uint32_t>(std::max<int64_t>(0, sampleOf(pe.step) - n0));
        if (!pe.on) {
            if (NoteEvents::Held* h = notes.findPattern(pe.note, pe.sub)) {
                noteMotion(notes, *h, static_cast<int>(frame));
                notes.off(frame, *h);
            }
            continue;
        }
        if (!notePlays(n, pe.note, s.repeat, seed_)) continue;
        if (pe.sub == 0 && n.slideFrom >= 0) {
            const PatternNote& from = pat->notes[static_cast<size_t>(n.slideFrom)];
            if (NoteEvents::Held* h = notes.findPattern(static_cast<uint32_t>(n.slideFrom), static_cast<uint16_t>(from.ratchet - 1))) {
                noteMotion(notes, *h, static_cast<int>(frame));  // its glide and expression up to the slide
                h->note = pe.note;
                h->sub = 0;
                h->pitch = h->sentPitch;  // from the pitch being heard, bend included
                h->target = n.pitch;
                h->glideLeft = std::max(1, static_cast<int>(std::floor(stepLen_ * 0.5 + 0.5)));
                h->glideStep = (h->target - h->pitch) / h->glideLeft;
                express(*h, n, frame);
                continue;
            }
        }
        // The same note still held ends first, with its motion up to here, as an off and a slide do
        // (on() would end it too, but without the motion, so its last pitch would depend on the block split).
        if (NoteEvents::Held* same = notes.findPattern(pe.note, pe.sub)) {
            noteMotion(notes, *same, static_cast<int>(frame));
            notes.off(frame, *same);
        }
        NoteEvents::Held& h = notes.on(frame, NoteEvents::Source::Pattern, pe.note, pe.sub, -1, n.pitch, n.vel);
        express(h, n, frame);
    }
}

// Glides and expression as per-note pitch, pressure and timbre events, worked out every kExpressionStep frames, sent
// only when a value changes. The grid runs on from the note's start (or its
// slide) across blocks, and a note that ends or slides mid-block first gets its points up to there, so the events
// land on the same frames, with the same values, at any block size.
void Engine::noteMotion(NoteEvents& notes, NoteEvents::Held& h, int end) noexcept {
    if (h.glideLeft <= 0 && !h.ex) {
        h.motionFrom = static_cast<uint32_t>(end);
        h.motionWait = 0;
        return;
    }
    int f = static_cast<int>(h.motionFrom) + h.motionWait;
    for (; f < end; f += kExpressionStep) {
        double bend = 0, press = 1, timbre = 0;
        if (h.ex) expressionAt(*h.ex, static_cast<double>(h.since), h.exLen, sr_, bend, press, timbre);
        const uint32_t frame = static_cast<uint32_t>(f);
        notes.pitch(frame, h, h.pitch + bend);
        if (h.ex) {
            if (!h.ex->press.points.empty()) notes.pressure(frame, h, std::clamp(press, 0.0, 1.0));
            if (!h.ex->timbre.points.empty()) notes.timbre(frame, h, std::clamp(timbre, 0.0, 1.0));
        }
        if (h.glideLeft > 0) {
            const int k = std::min(kExpressionStep, h.glideLeft);
            h.glideLeft -= k;
            h.pitch = h.glideLeft == 0 ? h.target : h.pitch + h.glideStep * k;
        }
        h.since += kExpressionStep;
    }
    h.motionWait = f - end;  // the next point, that many frames on
    h.motionFrom = static_cast<uint32_t>(end);
}

void Engine::instrumentMotion(NoteEvents& notes, int m) noexcept {
    for (NoteEvents::Held& h : notes.held()) {
        if (!h.active) continue;
        noteMotion(notes, h, m);
        h.motionFrom = 0;  // the next block starts at its frame 0
    }
}

// Whether Play finds the slot's instrument still ringing out after Stop (it sounded within the last 0.1 s and
// holds no preview, which plays on into the new pass): Play then renders a short tail of it (playTail).
bool Engine::ringsAtPlay(const Slot& s) const noexcept {
    return s.instrument && !s.instrumentIdle && s.active &&
           s.previewQuiet < static_cast<int64_t>(kPlayTailQuietSeconds * sr_) && !s.instrument->notes()->holdsPreview();
}

// Renders the instrument's next few milliseconds (at most 5 ms and `most` frames; its notes already let go) into
// the slot's play tail, faded to silence, before Play resets it; runInstrument mixes the tail into the first
// chunks of the new pass.
void Engine::playTail(Slot& s, int most) noexcept {
    const int len = std::min({Slot::kPlayTailMax, std::max(1, most), std::max(1, static_cast<int>(kPlayTailSeconds * sr_ + 0.5))});
    const ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), false};
    for (int done = 0; done < len;) {
        const int n = std::min(kBlock, len - done);
        s.instrument->process(s.playTailL + done, s.playTailR + done, static_cast<uint32_t>(n), sr_, &time);
        done += n;
    }
    for (int i = 0; i < len; ++i) {
        const float w = static_cast<float>(len - i) / static_cast<float>(len + 1);
        s.playTailL[i] *= w;
        s.playTailR[i] *= w;
    }
    s.playTailLen = len;
    s.playTailAt = 0;
}

void Engine::runInstrument(Slot& s, int m) noexcept {
    ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), playing_ && !previewChunk_};
    time.modulation = modulation_->forChain(s.index, ModChainKind::Instrument, s.instrument, 0);  // #161
    if (s.instrumentIdle) {
        // It stopped running while silent: what it held is stale, so it starts from silence.
        for (ComponentChain* c : {s.instrument, s.instrumentFading})
            if (c) {
                c->reset();
                c->notes()->forget(false);
                c->notes()->clearEvents();
            }
        if (NoteFxHost* fx = noteFx_->forSlot(s.index)) fx->reset();  // per-note FX (#127)
        s.instrumentIdle = false;
    }
    if (s.instrument) {
        NoteEvents& notes = *s.instrument->notes();
        if (!previewChunk_) instrumentNotes(s, notes, m);
        if (midiPendingCount_ > 0) feedDeviceMidi(s, notes, m);
        instrumentMotion(notes, m);
        if (modulation_->listens(s.index)) modulation_->tapNotes(s.index, notes.events(), notes.count());  // #161
        // Per-note FX (#127, note_fx_host.cpp): the host places this block's notes in slots and hands the
        // instrument its voice bus; each lane runs through its slot inside the instrument's block.
        NoteFxHost* noteFx = noteFx_->forSlot(s.index);
        if (noteFx) {
            notes.sort();
            s.instrument->setVoices(noteFx->begin(notes.events(), notes.count(), static_cast<uint32_t>(m), &time,
                modulation_->forChain(s.index, ModChainKind::NoteFx, noteFx->modChain(), 2), quality()));
        }
        s.instrument->process(s.instL, s.instR, static_cast<uint32_t>(m), sr_, &time);
        if (noteFx) {
            s.instrument->setVoices(nullptr);
            noteFx->end(static_cast<uint32_t>(m));
        }
    } else {
        std::fill_n(s.instL, m, 0.0f);
        std::fill_n(s.instR, m, 0.0f);
    }
    for (int i = 0; i < m && s.playTailAt < s.playTailLen; ++i, ++s.playTailAt) {
        s.instL[i] += s.playTailL[s.playTailAt];
        s.instR[i] += s.playTailR[s.playTailAt];
    }
    if (s.instrumentFadeLeft <= 0) return;
    // A replaced instrument (a rebuild, another choice) rings out under the new one for 20 ms.
    if (s.instrumentFading) {
        ChainTime fadeTime = time;
        fadeTime.modulation = modulation_->forChain(s.index, ModChainKind::Instrument, s.instrumentFading, 1);
        s.instrumentFading->process(fadeL_, fadeR_, static_cast<uint32_t>(m), sr_, &fadeTime);
    } else {
        std::fill_n(fadeL_, m, 0.0f);
        std::fill_n(fadeR_, m, 0.0f);
    }
    const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
    for (int i = 0; i < m; ++i) {
        const float w = s.instrumentFadeLeft > 0
            ? static_cast<float>(len - s.instrumentFadeLeft + 1) / static_cast<float>(len + 1) : 1.0f;
        if (s.instrumentFadeLeft > 0) --s.instrumentFadeLeft;
        s.instL[i] = fadeL_[i] + (s.instL[i] - fadeL_[i]) * w;
        s.instR[i] = fadeR_[i] + (s.instR[i] - fadeR_[i]) * w;
    }
    if (s.instrumentFadeLeft == 0 && s.instrumentFading) {
        if (canRetire(1)) {
            retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.instrumentFading);
            s.instrumentFading = nullptr;
        } else {
            s.instrumentFadeLeft = 1;  // no room to hand it back yet: try again next block
        }
    }
}

// A playing track at the start of a chunk: loop restarts happen here, on their exact sample, and the chunk is
// cut short at the next one so a whole chunk is one pass.
void Engine::planTrack(Slot& s, int& m) noexcept {
    const bool free = s.steps <= 0;
    const double layerLen = free ? static_cast<double>(loopLen_) : s.steps * stepLen_;
    const int64_t gg = g_;
    int64_t k = 0, st = 0, nx = loopLen_;
    if (!free) {
        const double S = s.steps * stepLen_;
        k = static_cast<int64_t>(std::floor(static_cast<double>(gg) / S));
        while (loopStart(s, k + 1) <= gg) ++k;
        while (k > 0 && loopStart(s, k) > gg) --k;
        st = loopStart(s, k);
        nx = std::min<int64_t>(loopStart(s, k + 1), loopLen_);
    }
    if (k != s.k || epoch_ != s.epoch) {
        // The layer restarts its pattern: held notes ring out, the instrument and its effects carry on.
        if (!s.fresh && s.instrument && !s.instrumentIdle) s.instrument->notes()->releaseAll(0, true);
        s.fresh = false;
        s.k = k;
        s.epoch = epoch_;
    }
    m = static_cast<int>(std::min<int64_t>(m, nx - gg));
    s.n0 = gg - st;
    s.repeat = free ? epoch_ : k;
    s.layerLen = layerLen;
    s.pat = s.pattern ? s.pattern->get() : nullptr;
}

// Decides what each slot does this chunk and returns the chunk's length: maxFrames, cut at the
// next loop boundary of any playing track.
int Engine::planChunk(int maxFrames) noexcept {
    int m = maxFrames;
    if (previewChunk_) {
        // Stopped, with previews: only the previewing tracks run, with no pattern events and no transport, through
        // their effects, mix, folder buses and master. Removals wait for playback, as they do while stopped.
        for (int k = 0; k < liveCount_; ++k) {
            Slot& s = slotAt(live_[k]);
            if (!s.active || (!s.bus && !s.track)) { s.mode = Slot::Mode::Idle; continue; }
            if (s.bus) { s.mode = Slot::Mode::Bus; continue; }
            s.target = slotTarget(s);
            const bool silentMix = s.target == 0.0 && s.gain == 0.0;
            if (!s.previewing || !playsNotes(s) || silentMix) {
                s.mode = Slot::Mode::Silent;
                s.insertsIdle = true;
                s.instrumentIdle = s.instrumentIdle || s.instrument || s.instrumentFading;
                s.delayStale = true;
                s.routesStale = true;
                continue;
            }
            s.mode = Slot::Mode::Play;
            s.pat = nullptr;
            // The layer's time runs on through its loop, so time-driven effects keep moving; cut at the wrap.
            const double layerLen = s.steps <= 0 ? static_cast<double>(loopLen_) : s.steps * stepLen_;
            const int64_t len = std::max<int64_t>(1, static_cast<int64_t>(std::floor(layerLen + 0.5)));
            s.layerLen = layerLen;
            s.previewN = ((s.previewN % len) + len) % len;
            s.n0 = s.previewN;
            m = static_cast<int>(std::min<int64_t>(m, len - s.n0));
        }
        return m;
    }
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        if (!s.active || (!s.bus && !s.track)) { s.mode = Slot::Mode::Idle; continue; }
        if (s.bus) { s.mode = Slot::Mode::Bus; continue; }
        s.target = slotTarget(s);
        // A slot keying a component (a kick keying a ducker) keeps running while muted or soloed out, so its key
        // still sounds; its own output is silence.
        const bool keys = s.sends && s.sends->keys && !s.removing && !s.overloaded;
        if (s.target == 0.0 && s.gain == 0.0 && !keys) {
            // Silent (muted, soloed out or removed, and faded out): nothing runs; a removal finishes.
            s.mode = Slot::Mode::Silent;
            s.insertsIdle = true;
            s.instrumentIdle = s.instrumentIdle || s.instrument || s.instrumentFading;
            s.delayStale = true;
            s.routesStale = true;
            if (s.removing && canRetire(6)) {
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.instrument);
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.instrumentFading);
                s.instrument = s.instrumentFading = nullptr;
                s.instrumentFadeLeft = 0;
                {
                    Retired d;
                    d.delay = s.delayFading;
                    if (d.delay) retireEntry(d);
                    s.delayFading = nullptr;
                    s.delayFadeLeft = 0;
                }
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
                s.insertsFading = nullptr;
                s.insertsFadeLeft = 0;
                retire(nullptr, s.pattern);
                s.pattern = nullptr;
                {
                    // One entry: the slot frees with its inserts and delay.
                    Retired r{&s, nullptr, nullptr, nullptr, nullptr, s.inserts};
                    r.delay = s.delay;
                    r.sends = s.sends;
                    retireEntry(r);
                }
                s.inserts = nullptr;
                s.delay = nullptr;
                s.sends = nullptr;
                s.track = false;
                s.active = false;
                s.removing = false;
                s.mode = Slot::Mode::Idle;
                routingDirty_ = true;
            }
            continue;
        }
        s.mode = Slot::Mode::Play;
        planTrack(s, m);
    }
    return m;
}

int Engine::processChunk(float* l, float* r, int maxFrames) noexcept {
    // Only slots in use are visited (#133). A slot leaves the list once no loop has anything left to do
    // for it: inactive, not previewing and planned Idle (the scans it skips would only set Idle again).
    // Its routing scratch is reset, as updateRouting would have left it.
    int kept = 0;
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
        Slot& slot = slotAt(i);
        if (!slot.active && !slot.previewing && slot.mode == Slot::Mode::Idle) {
            slot.listed = false;
            MixGraph& g = *mixGraph_;
            g.routable[i] = 0;
            g.target[i] = -1;
            g.pending[i] = 0;
            g.deferred[i] = g.emitted[i] = 0;
            g.position[i] = UINT32_MAX;
            continue;
        }
        live_[kept++] = i;
    }
    liveCount_ = kept;
    const int m = planChunk(maxFrames);
    audioIn_->chunk(tapAt_, m, g_, playing_ && !previewChunk_);  // monitoring frames and the recorder's input
    ++chunkId_;
    // Project modulation (#161): due modulator blocks and every target's offsets, before any target runs.
    modulation_->beginChunk(static_cast<uint32_t>(m), g_, stepLen_, bpm_, static_cast<uint32_t>(beatsPerBar_),
                            playing_ && !previewChunk_, modPlays_, chunkId_);
    noteFx_->beginChunk();  // per-note FX (#127): a new plan
    // One graph runs the mix: each track's node, each folder bus after its children (and after every send and
    // key into it), then the master stage. Routing changes only between chunks.
    if (routingDirty_) {
        routingDirty_ = false;
        updateRouting();
    }
    float* outputs[2] = {l, r};
    if (!mixGraph_->executor.process(ConstChannelBufferView{}, ChannelBufferView{outputs, 2, static_cast<uint32_t>(m)},
                                     static_cast<uint32_t>(m))) {
        std::fill_n(l, m, 0.0f);
        std::fill_n(r, m, 0.0f);
        mixToneOnly(l, r, m);  // the master stage, last in the graph, did not run
    }
    return m;
}

// Routing as graph edges: a routable slot (active, and a bus or a track) goes to its parent when
// that parent is an active folder bus, is dropped when its parent is anything else, and goes to master at the
// root. Sends and sidechain keys add order but no edges (the source adds into its destination's input, runRoutes):
// a slot runs after every slot that feeds it, whether as a child, a send or a key. The order is the old pass order
// (processOrder_, then the remaining slots by index) with each slot held back until what feeds it has run, so a
// track always reaches its bus in the same chunk (issue #76). A track is one node (its instrument, inserts and
// mix). Edges into buses follow that order, which is the old accumulation order. Idle slots are left out of the
// order, so they cost nothing.
void Engine::updateRouting() noexcept {
    MixGraph& g = *mixGraph_;
    const int master = g.master;
    // Only slots in use (live_, ascending); the rest are not routable, and processChunk reset their
    // scratch when they left the list (#133).
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
        const Slot& s = slotAt(i);
        int to = -1;
        const bool routable = s.active && (s.bus || s.track);
        if (routable) {
            if (s.parentSlot >= 0 && s.parentSlot < capacity_ && s.parentSlot != i) {
                const Slot& parent = slotAt(s.parentSlot);
                to = parent.active && parent.bus ? s.parentSlot : -1;
            } else {
                to = master;
            }
        }
        g.routable[i] = routable;
        g.target[i] = to;
    }
    // A route counts when both ends run: into a bus's input, or a key into a slot with inserts.
    auto routeDest = [&](const Slot& s, int k) noexcept {
        const SendTable::Route& r = s.sends->routes[k];
        if (r.dest < 0 || r.dest >= slotCount_ || r.dest == s.index || !g.routable[r.dest]) return -1;
        const Slot& d = slotAt(r.dest);
        if (r.key < 0 ? !d.bus : !d.inserts) return -1;
        return r.dest;
    };
    for (int k = 0; k < liveCount_; ++k) {
        const int n = live_[k];
        g.pending[n] = 0; g.deferred[n] = false; g.emitted[n] = false;
    }
    g.pending[master] = 0; g.deferred[master] = false; g.emitted[master] = false;
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
        if (!g.routable[i]) continue;
        if (g.target[i] >= 0 && g.target[i] != master) ++g.pending[g.target[i]];
        const Slot& s = slotAt(i);
        if (s.sends)
            for (int k = 0; k < s.sends->count; ++k)
                if (const int d = routeDest(s, k); d >= 0) ++g.pending[d];
    }
    int count = 0;
    auto release = [&](int to, int& top) noexcept {
        if (to >= 0 && to != master && --g.pending[to] == 0 && g.deferred[to]) {
            g.deferred[to] = false;
            g.stack[top++] = to;
        }
    };
    auto emit = [&](int first) noexcept {
        int top = 0;
        g.stack[top++] = first;
        while (top > 0) {
            const int x = g.stack[--top];
            g.emitted[x] = true;
            g.slotOrder[count++] = x;
            const Slot& s = slotAt(x);
            if (s.sends)
                for (int k = s.sends->count - 1; k >= 0; --k) release(routeDest(s, k), top);
            release(g.target[x], top);  // last pushed, first ordered: the parent bus as before
        }
    };
    auto visit = [&](int x) noexcept {
        if (x < 0 || x >= slotCount_ || !g.routable[x] || g.emitted[x] || g.deferred[x]) return;
        if (g.pending[x] > 0) { g.deferred[x] = true; return; }
        emit(x);
    };
    for (int k = 0; k < processCount_; ++k) visit(processOrder_[k]);
    for (int k = 0; k < liveCount_; ++k) visit(live_[k]);
    // A routing cycle is never sent by the control thread; if one appears, keep everything ordered
    // and drop the edges and routes that would point backwards.
    for (int j = 0; j < liveCount_; ++j)
        if (const int k = live_[j]; g.routable[k] && !g.emitted[k]) { g.emitted[k] = true; g.slotOrder[count++] = k; }
    for (int j = 0; j < liveCount_; ++j) g.position[live_[j]] = UINT32_MAX;  // not run this chunk
    g.position[master] = UINT32_MAX;
    for (int k = 0; k < count; ++k) g.position[g.slotOrder[k]] = static_cast<uint32_t>(k);
    g.position[master] = static_cast<uint32_t>(count);
    for (int j = 0; j < liveCount_; ++j) {
        const int i = live_[j];
        Slot& s = slotAt(i);
        if (!s.sends) continue;
        for (int k = 0; k < s.sends->count; ++k) {
            const int d = g.routable[i] ? routeDest(s, k) : -1;
            s.routeOk[k] = d >= 0 && g.position[i] < g.position[d];
        }
    }
    uint32_t nodeCount = 0, edgeCount = 0;
    for (int k = 0; k < count; ++k) {
        const int x = g.slotOrder[k];
        const bool bus = slotAt(x).bus;
        const uint32_t out = bus ? g.busNode(x) : g.trackNode(x);
        g.order[nodeCount++] = out;
        const int to = g.target[x];
        if (to < 0 || g.position[x] >= g.position[to]) continue;
        // The output port: a bus node's second (after its summing input), a track node's only one.
        g.edges[edgeCount++] = GraphConnection{out, bus ? 1u : 0u, to == master ? g.masterNode() : g.busNode(to), 0};
    }
    g.order[nodeCount++] = g.masterNode();
    // Valid by construction. A rejection would keep the previous routing (safe: stale nodes output
    // zeros) but must never pass unnoticed: it is counted and asserts in debug builds.
    if (!g.executor.setRouting(g.edges.data(), edgeCount, g.order.data(), nodeCount)) {
        routingRejections_.fetch_add(1, std::memory_order_relaxed);
        assert(!"mix graph rejected a derived route");
    }
}

// A track's latency compensation, with the crossfade of a delay change.
void Engine::runDelay(Slot& s, float* outL, float* outR, int m) noexcept {
    if (s.delayStale) {  // it held the song's last frames from before a stop or a silence
        if (s.delay) s.delay->clear();
        if (s.delayFading && canRetire(1)) {  // a change that was still crossfading is over: the new timing holds
            Retired r;
            r.delay = s.delayFading;
            retireEntry(r);
            s.delayFading = nullptr;
            s.delayFadeLeft = 0;
        } else if (s.delayFading) {
            s.delayFading->clear();
        }
        s.delayStale = false;
    }
    const bool fading = s.delayFadeLeft > 0;
    if (fading) {
        std::copy_n(outL, m, fadeL_);
        std::copy_n(outR, m, fadeR_);
        if (s.delayFading) s.delayFading->run(fadeL_, fadeR_, m);
    }
    if (s.delay) s.delay->run(outL, outR, m);
    if (!fading) return;
    const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
    for (int i = 0; i < m; ++i) {
        const float w = s.delayFadeLeft > 0 ? static_cast<float>(len - s.delayFadeLeft + 1) / static_cast<float>(len + 1) : 1.0f;
        if (s.delayFadeLeft > 0) --s.delayFadeLeft;
        outL[i] = fadeL_[i] + (outL[i] - fadeL_[i]) * w;
        outR[i] = fadeR_[i] + (outR[i] - fadeR_[i]) * w;
    }
    if (s.delayFadeLeft == 0 && s.delayFading) {
        if (canRetire(1)) {
            Retired r;
            r.delay = s.delayFading;
            retireEntry(r);
            s.delayFading = nullptr;
        } else {
            s.delayFadeLeft = 1;  // no room to hand it back yet: try again next block
        }
    }
}

// A slot's native inserts in place, crossfading from a replaced chain (or the dry signal) over 20 ms.
void Engine::runInserts(Slot& s, float* L, float* R, int m) noexcept {
    ComponentChain* const inserts = s.inserts;
    const bool fading = s.insertsFadeLeft > 0;
    // A tail frozen while the slot was silent must not play on when it sounds again.
    if (s.insertsIdle) {
        if (inserts) inserts->reset();
        if (s.insertsFading) s.insertsFading->reset();
        s.insertsIdle = false;
    }
    ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), playing_ && !previewChunk_,
                   chunkId_};
    time.modulation = modulation_->forChain(s.index, ModChainKind::Inserts, inserts, 0);  // #161
    const ChainTime* t = &time;
    if (fading) {
        std::copy_n(L, m, fadeL_);
        std::copy_n(R, m, fadeR_);
        ChainTime fadeTime = time;
        fadeTime.modulation = modulation_->forChain(s.index, ModChainKind::Inserts, s.insertsFading, 1);
        if (s.insertsFading) s.insertsFading->process(fadeL_, fadeR_, static_cast<uint32_t>(m), sr_, &fadeTime);
    }
    if (inserts) inserts->process(L, R, static_cast<uint32_t>(m), sr_, t);
    if (fading) {
        const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
        for (int i = 0; i < m; ++i) {
            const float w = s.insertsFadeLeft > 0
                ? static_cast<float>(len - s.insertsFadeLeft + 1) / static_cast<float>(len + 1) : 1.0f;
            if (s.insertsFadeLeft > 0) --s.insertsFadeLeft;
            L[i] = fadeL_[i] + (L[i] - fadeL_[i]) * w;
            R[i] = fadeR_[i] + (R[i] - fadeR_[i]) * w;
        }
        if (s.insertsFadeLeft == 0 && s.insertsFading && canRetire(1)) {
            retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
            s.insertsFading = nullptr;
        } else if (s.insertsFadeLeft == 0 && s.insertsFading) {
            s.insertsFadeLeft = 1;  // no room to hand it back yet: hold the new chain at full and try again
        }
    }
}

// Sends and keys (runRoutes): each route's gain ramps across the block to its level (0 while muted, and for a
// send while the slot is muted or soloed out); a pre route reads the pre tap, a post send the post tap. A post key
// reads the pre tap times the fader's own volume and pan (automated ones included), whatever mute, solo or the
// fader's ramp do, so a muted kick ducks just as a playing one and unmuting it doesn't re-trigger. A switch of
// tap fades the route to 0 and back. Each route's delay keeps it in time where it arrives; the result adds into
// the destination's input for this chunk. `bus`: the slot is a folder bus (its pan is a balance).
void Engine::runRoutes(Slot& s, const float* preL, const float* preR, const float* postL, const float* postR, int m,
                       bool silenced, bool bus) noexcept {
    SendTable& t = *s.sends;
    // The fader's volume and pan per frame, for post keys (worked out only when some route needs them).
    double faderL[kBlock], faderR[kBlock];
    bool fader = false;
    auto faderGains = [&]() {
        if (fader) return;
        fader = true;
        const bool volumeLane = s.automation && !s.automation->volume.empty();
        const bool panLane = s.automation && !s.automation->pan.empty();
        const double vol = bitsToDouble(s.vol.load(std::memory_order_relaxed));
        const double pan = bitsToDouble(s.pan.load(std::memory_order_relaxed));
        auto gains = [bus](double p, double& l, double& r) {
            if (bus) {
                l = p > 0.0 ? 1.0 - p : 1.0;
                r = p < 0.0 ? 1.0 + p : 1.0;
            } else {
                const lib::PanGains g = lib::constantPowerPan(p);
                l = g.left;
                r = g.right;
            }
        };
        double pl = 0.0, pr = 0.0;
        gains(pan, pl, pr);
        for (int i = 0; i < m; ++i) {
            const double step = static_cast<double>(g_ + i) / stepLen_;
            const double v = volumeLane ? automationValue(s.automation->volume, step, 1.0) : vol;
            if (panLane) gains(automationValue(s.automation->pan, step, pan), pl, pr);
            faderL[i] = v * pl;
            faderR[i] = v * pr;
        }
    };
    // The notes the slot plays this chunk, for components keyed by it (the ducker's Notes mode).
    Event notes[ComponentChain::kMaxKeyEvents];
    const uint32_t noteCount = t.keys ? keyNotes(s, m, notes, ComponentChain::kMaxKeyEvents) : 0;
    if (s.routesStale) {
        for (int k = 0; k < t.count; ++k)
            if (t.routes[k].delay) t.routes[k].delay->clear();
        s.routesStale = false;
    }
    for (int k = 0; k < t.count; ++k) {
        SendTable::Route& r = t.routes[k];
        const bool key = r.key >= 0;
        const float* levelMod = key ? nullptr : modulation_->send(s.index, k);  // project modulation (#161)
        const double level = levelMod ? faderGain(faderPosition(r.level) + levelMod[m - 1]) : r.level;
        const double want = r.mute || (!key && silenced) ? 0.0 : level;
        const double from = s.routeGain[k];
        if (!s.routeOk[k]) {
            s.routeGain[k] = 0.0;  // its destination doesn't run: it starts from silence when it does
            continue;
        }
        if (from == 0.0 && want == 0.0 && !r.delay) {
            r.tapPre = r.pre;  // silent: the tap can change at once
            continue;
        }
        Slot& d = slotAt(r.dest);
        auto skip = [&]() { s.routeGain[k] = want; };
        float* dl = nullptr;
        float* dr = nullptr;
        if (key) {
            ComponentChain::KeyInput* in = d.inserts ? d.inserts->keyInput(static_cast<size_t>(r.key)) : nullptr;
            if (!in) {
                skip();
                continue;
            }
            in->begin(chunkId_);
            dl = in->l;
            dr = in->r;
            // Merged by frame with what other sources wrote (each list is in frame order).
            for (uint32_t k2 = 0; k2 < noteCount && in->count < ComponentChain::kMaxKeyEvents; ++k2) {
                uint32_t at = in->count++;
                while (at > 0 && in->events[at - 1].frame > notes[k2].frame) {
                    in->events[at] = in->events[at - 1];
                    --at;
                }
                in->events[at] = notes[k2];
            }
        } else {
            if (d.recvChunk != chunkId_) {
                std::fill_n(d.recvL, m, 0.0f);
                std::fill_n(d.recvR, m, 0.0f);
                d.recvChunk = chunkId_;
            }
            dl = d.recvL;
            dr = d.recvR;
        }
        const bool postKey = key && (!r.pre || !r.tapPre);
        if (postKey) faderGains();
        const float* xl = r.tapPre || key ? preL : postL;
        const float* xr = r.tapPre || key ? preR : postR;
        // A level change glides at a fixed rate per sample (full scale in 5 ms), so it is the same at any block size.
        const double most = 1.0 / std::max(1.0, kGainSeconds * sr_);
        double g = from;
        for (int i = 0; i < m; ++i) {
            const double aim = r.tapPre == r.pre ? want : 0.0;  // changing tap: through silence
            if (g != aim) g = aim > g ? std::min(aim, g + most) : std::max(aim, g - most);
            if (g == 0.0 && r.tapPre != r.pre) {
                r.tapPre = r.pre;
                xl = r.tapPre || key ? preL : postL;
                xr = r.tapPre || key ? preR : postR;
            }
            const bool faded = key && !r.tapPre;
            routeL_[i] = routeSample(static_cast<double>(xl[i]) * g * (faded ? faderL[i] : 1.0));
            routeR_[i] = routeSample(static_cast<double>(xr[i]) * g * (faded ? faderR[i] : 1.0));
        }
        s.routeGain[k] = g;
        if (r.delay) r.delay->run(routeL_, routeR_, m);
        for (int i = 0; i < m; ++i) {
            dl[i] = routeSample(static_cast<double>(dl[i]) + routeL_[i]);
            dr[i] = routeSample(static_cast<double>(dr[i]) + routeR_[i]);
        }
    }
}

// The note-ons a playing slot's pattern starts in this chunk (those that play: chance, ratchets; a slide is legato
// and starts none), as MIDI 2.0 note-ons at their frames, at most `max`.
uint32_t Engine::keyNotes(const Slot& s, int m, Event* out, uint32_t max) const noexcept {
    if (s.mode != Slot::Mode::Play || previewChunk_ || !s.pat) return 0;
    const Pattern& pat = *s.pat;
    auto sampleOf = [this](double step) { return static_cast<int64_t>(std::floor(step * stepLen_ + 0.5)); };
    const PatternEvent* ev = pat.events.data();
    const size_t ne = pat.events.size();
    const int64_t n0 = s.n0, end = n0 + m;
    size_t e = static_cast<size_t>(
        std::partition_point(ev, ev + ne, [&](const PatternEvent& x) { return sampleOf(x.step) < n0; }) - ev);
    uint32_t count = 0;
    for (; e < ne && count < max && sampleOf(ev[e].step) < end; ++e) {
        const PatternEvent& pe = ev[e];
        if (!pe.on) continue;
        const PatternNote& n = pat.notes[pe.note];
        if (pe.sub == 0 && n.slideFrom >= 0) continue;
        if (!notePlays(n, pe.note, s.repeat, seed_)) continue;
        Event& x = out[count++];
        x = Event{};
        x.frame = static_cast<uint32_t>(std::max<int64_t>(0, sampleOf(pe.step) - n0));
        x.kind = EventKind::Note;
        x.noteId = pe.note + 1;
        const uint32_t key = static_cast<uint32_t>(std::clamp(std::lround(n.pitch), 0L, 127L));
        const uint32_t vel = static_cast<uint32_t>(std::clamp(n.vel, 0.0, 1.0) * 65535.0 + 0.5);
        x.data[0] = 0x40000000u | (0x9u << 20) | (key << 8);  // MIDI 2.0 note on, group 0, channel 0
        x.data[1] = vel << 16;
    }
    return count;
}

// A playing track's output: the seam and swap crossfades of its lanes, then gain and pan.
void Engine::runTrackNode(int slot, float* outL, float* outR, int m) noexcept {
    Slot& s = slotAt(slot);
    if (s.mode != Slot::Mode::Play) {
        std::fill_n(outL, m, 0.0f);
        std::fill_n(outR, m, 0.0f);
        return;
    }
    const double target = s.target;
    if (!(trackGainCoef_ >= 0.0)) trackGainCoef_ = 1.0 - detExp(-1.0 / (kGainSeconds * sr_));  // once per Engine
    const double gainCoef = trackGainCoef_;
    const double pan = bitsToDouble(s.pan.load(std::memory_order_relaxed));
    if ((!s.automation || s.automation->pan.empty()) && pan != s.panCache) {
        s.panCache = pan;
        const lib::PanGains g = lib::constantPowerPan(pan);
        s.gl = g.left;
        s.gr = g.right;
    }
    // The instrument (#17) into the native inserts, stereo through volume and pan (the pan law then works per side,
    // as balance).
    runInstrument(s, m);
    std::copy_n(s.instL, m, insertL_);
    std::copy_n(s.instR, m, insertR_);
    runInserts(s, insertL_, insertR_, m);
    float peakL = 0, peakR = 0, sig = 0;
    int sp = s.scopePos.load(std::memory_order_relaxed);
    const bool volumeAutomated = s.automation && !s.automation->volume.empty();
    const bool panAutomated = s.automation && !s.automation->pan.empty();
    const double settled = target > 0.0 ? target : 0.0;
    // Project modulation of the fader (#161): offsets in its travel (the app's taper) and in pan's, per frame.
    const float* volumeMod = modulation_->volume(slot);
    const float* panMod = modulation_->pan(slot);
    if (!volumeAutomated && !panAutomated && s.gain == settled && !volumeMod && !panMod) {
        // The usual case: volume settled, no lanes. The same sums as the loop below, without its per-sample
        // branches, and the scope written in at most two runs instead of a wrap test per sample.
        const double gain = s.gain, gl = s.gl, gr = s.gr;
        float mid[kBlock], level[kBlock];
        for (int i = 0; i < m; ++i) {
            const double vl = static_cast<double>(insertL_[i]) * gain;
            const double vr = static_cast<double>(insertR_[i]) * gain;
            outL[i] = routeSample(vl * gl);
            outR[i] = routeSample(vr * gr);
            const double al = std::fabs(vl), ar = std::fabs(vr);
            level[i] = static_cast<float>(al < ar ? ar : al);
            mid[i] = static_cast<float>(0.5 * (vl + vr));
        }
        peakL = peakAbs(outL, m);
        peakR = peakAbs(outR, m);
        sig = peakAbs(level, m);
        for (int i = 0; i < m;) {
            const int run = std::min(m - i, kScopeSize - sp);
            for (int k = 0; k < run; ++k) s.scope[sp + k].store(mid[i + k], std::memory_order_relaxed);
            i += run;
            sp = (sp + run) % kScopeSize;
        }
    } else  // volume moving or automated: per sample
    for (int i = 0; i < m; ++i) {
        const double step = volumeAutomated || panAutomated ? static_cast<double>(g_ + i) / stepLen_ : 0.0;
        const double desired = target > 0.0
            ? (volumeAutomated ? automationValue(s.automation->volume, step, target) : target) : 0.0;
        if (volumeAutomated) {
            // The interpolated automation curve is already continuous; don't add lag on top.
            s.gain = desired;
        } else if (s.gain != desired) {
            s.gain += (desired - s.gain) * gainCoef;
            if (std::fabs(desired - s.gain) < 1e-6) s.gain = desired;
        }
        const double gain = volumeMod && s.gain > 0.0 ? faderGain(faderPosition(s.gain) + volumeMod[i]) : s.gain;  // muted stays silent
        const double vl = static_cast<double>(insertL_[i]) * gain;
        const double vr = static_cast<double>(insertR_[i]) * gain;
        const double v = 0.5 * (vl + vr);  // the scope and tail test read the mid
        double gl = s.gl, gr = s.gr;
        if (panAutomated || panMod) {
            double automatedPan = panAutomated ? automationValue(s.automation->pan, step, pan) : pan;
            if (panMod) automatedPan = std::clamp(automatedPan + 2.0 * panMod[i], -1.0, 1.0);
            const lib::PanGains g = lib::constantPowerPan(automatedPan);
            gl = g.left; gr = g.right;
        }
        // Graph edges carry 32-bit float (owner, 2026-11-03), saturating at +/-FLT_MAX (route_math.h).
        outL[i] = routeSample(vl * gl);
        outR[i] = routeSample(vr * gr);
        // The meter reads what the track sends on (after volume and pan), each channel's sample peak.
        peakL = std::max(peakL, std::fabs(outL[i]));
        peakR = std::max(peakR, std::fabs(outR[i]));
        sig = std::max(sig, static_cast<float>(std::max(std::fabs(vl), std::fabs(vr))));  // before pan: a preview's tail test, like the scope
        s.scope[sp].store(static_cast<float>(v), std::memory_order_relaxed);
        sp = (sp + 1) % kScopeSize;
    }
    s.scopePos.store(sp, std::memory_order_release);
    storeMax(s.peakL, peakL);
    storeMax(s.peakR, peakR);
    s.correlation.process(outL, outR, m);
    // A modulator hears this track (#161): after its effects, and after the fader.
    if (modulation_->listens(slot)) modulation_->tapAudio(slot, insertL_, insertR_, outL, outR, static_cast<uint32_t>(m));
    if (s.sends && s.sends->count > 0) runRoutes(s, insertL_, insertR_, outL, outR, m, !(target > 0.0), false);
    if (s.delay || s.delayFadeLeft > 0) runDelay(s, outL, outR, m);  // in time where it meets the others
    if (s.tapL) {  // an offline stem: what the track sends on, as it meets the others
        std::copy_n(outL, m, s.tapL + tapAt_);
        std::copy_n(outR, m, s.tapR + tapAt_);
    }
    s.previewQuiet = sig > kPreviewQuiet ? 0 : s.previewQuiet + m;
    if (previewChunk_) {
        s.previewN += m;  // the transport isn't moving: its place in the loop stays; the preview's time runs on
        return;
    }
    s.lastN = s.n0 + m - 1;
    s.progress.store(static_cast<float>(static_cast<double>(s.n0 + m) / s.layerLen), std::memory_order_relaxed);
}

// A folder bus: its children arrive summed in float on the graph's summing input, and sends into it in its own
// input (runRoutes). Then its inserts, volume and pan, its sends, and its latency compensation.
void Engine::runBusNode(int slot, const float* inL, const float* inR, float* outL, float* outR, int m) noexcept {
    Slot& s = slotAt(slot);
    if (s.mode != Slot::Mode::Bus) {
        std::fill_n(outL, m, 0.0f);
        std::fill_n(outR, m, 0.0f);
        return;
    }
    const double target = slotTarget(s);
    const bool received = s.recvChunk == chunkId_;
    const bool inserts = s.inserts || s.insertsFadeLeft > 0;
    if (received || inserts) {
        for (int j = 0; j < m; ++j) {
            insertL_[j] = received ? routeSample(static_cast<double>(inL[j]) + s.recvL[j]) : inL[j];
            insertR_[j] = received ? routeSample(static_cast<double>(inR[j]) + s.recvR[j]) : inR[j];
        }
        if (inserts) runInserts(s, insertL_, insertR_, m);
        for (int j = 0; j < m; ++j) {
            s.outL[j] = insertL_[j];
            s.outR[j] = insertR_[j];
        }
    } else {
        for (int j = 0; j < m; ++j) {
            s.outL[j] = inL[j];
            s.outR[j] = inR[j];
        }
    }
    const bool routes = s.sends && s.sends->count > 0;
    if (routes && !received && !inserts) {  // the pre tap, when it isn't in insertL_ already
        std::copy_n(inL, m, insertL_);
        std::copy_n(inR, m, insertR_);
    }
    const double pan = bitsToDouble(s.pan.load(std::memory_order_relaxed));
    const double gainCoef = 1.0 - detExp(-1.0 / (kGainSeconds * sr_));
    const float* volumeMod = modulation_->volume(slot);  // project modulation (#161)
    const float* panMod = modulation_->pan(slot);
    for (int j = 0; j < m; ++j) {
        const double step = static_cast<double>(g_ + j) / stepLen_;
        const bool volumeAutomated = s.automation && !s.automation->volume.empty();
        const double desired = target > 0.0
            ? (volumeAutomated ? automationValue(s.automation->volume, step, target) : target) : 0.0;
        if (volumeAutomated) {
            s.gain = desired;
        } else if (s.gain != desired) {
            s.gain += (desired - s.gain) * gainCoef;
            if (std::fabs(desired - s.gain) < 1e-6) s.gain = desired;
        }
        double automatedPan = s.automation && !s.automation->pan.empty()
            ? automationValue(s.automation->pan, step, pan) : pan;
        if (panMod) automatedPan = std::clamp(automatedPan + 2.0 * panMod[j], -1.0, 1.0);
        const double leftPan = automatedPan > 0.0 ? 1.0 - automatedPan : 1.0;
        const double rightPan = automatedPan < 0.0 ? 1.0 + automatedPan : 1.0;
        const double gain = volumeMod && s.gain > 0.0 ? faderGain(faderPosition(s.gain) + volumeMod[j]) : s.gain;  // muted stays silent
        s.outL[j] *= gain * leftPan;
        s.outR[j] *= gain * rightPan;
    }
    // Graph edges carry 32-bit float (owner, 2026-11-03), saturating at +/-FLT_MAX (route_math.h).
    float peakL = 0, peakR = 0;
    for (int j = 0; j < m; ++j) {
        outL[j] = routeSample(s.outL[j]);
        outR[j] = routeSample(s.outR[j]);
        peakL = std::max(peakL, std::fabs(outL[j]));
        peakR = std::max(peakR, std::fabs(outR[j]));
    }
    if (previewChunk_ && s.tailFade != 0) {  // stopped: a capped tail of its inserts fading out
        const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
        for (int i = 0; i < m; ++i) {
            const float g = s.tailFade > 0 ? static_cast<float>(s.tailFade) / static_cast<float>(len) : 0.0f;
            if (s.tailFade > 0 && --s.tailFade == 0) s.tailFade = -1;
            outL[i] *= g;
            outR[i] *= g;
        }
    }
    if (modulation_->listens(slot))  // a modulator hears this bus (#161)
        modulation_->tapAudio(slot, received || inserts || routes ? insertL_ : inL, received || inserts || routes ? insertR_ : inR,
                              outL, outR, static_cast<uint32_t>(m));
    storeMax(s.peakL, peakL);  // a folder's meter: its mix after volume and pan
    storeMax(s.peakR, peakR);
    s.correlation.process(outL, outR, m);
    s.previewQuiet = std::max(peakL, peakR) > kPreviewQuiet ? 0 : s.previewQuiet + m;
    if (routes) runRoutes(s, insertL_, insertR_, outL, outR, m, !(target > 0.0), true);
    if (s.delay || s.delayFadeLeft > 0) runDelay(s, outL, outR, m);  // in time where it meets the others
    if (s.tapL) {  // an offline stem: the bus's output, as it meets the others
        std::copy_n(outL, m, s.tapL + tapAt_);
        std::copy_n(outR, m, s.tapR + tapAt_);
    }
    if (s.removing && s.gain == 0.0 && canRetire(3)) {
        // Faded out: the slot is free again, with its inserts, delay and routes.
        Retired r{&s, nullptr, nullptr, nullptr, nullptr, s.inserts};
        r.delay = s.delay;
        r.sends = s.sends;
        retireEntry(r);
        retire(nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
        if (s.delayFading) {
            Retired d;
            d.delay = s.delayFading;
            retireEntry(d);
        }
        s.inserts = s.insertsFading = nullptr;
        s.insertsFadeLeft = 0;
        s.delay = s.delayFading = nullptr;
        s.delayFadeLeft = 0;
        s.sends = nullptr;
        s.active = false;
        s.bus = false;
        s.removing = false;
        s.previewing = false;
        s.insertTail = false;
        routingDirty_ = true;
    }
}

void Engine::runMasterNode(const float* inL, const float* inR, float* outL, float* outR, int m) noexcept {
    // Master order: gain/DC block, trusted native stereo effects, safety limiter last.
    const double R = 1.0 - kTwoPi * 5.0 / sr_;
    const double rel = detExp(-1.0 / (0.1 * sr_));
    double fade = 1.0;
    float pl = 0, pr = 0;
    const bool bypass = bypass_.load(std::memory_order_relaxed);
    int sp = masterScopePos_.load(std::memory_order_relaxed);

    // The metronome, while the song plays: a click as the playhead crosses each beat.
    const bool clicks = metronome_ && playing_ && !previewChunk_ && stepLen_ > 0;
    const double beatLen = 4.0 * stepLen_;
    auto finishSample = [&](int frame, double yl, double yr) noexcept {
        if (clicks) {
            const double pos = static_cast<double>(g_ + frame);
            const double beat = std::floor(pos / beatLen);
            if (pos - beat * beatLen < 1.0) startClick(static_cast<int64_t>(beat) % std::max(1, beatsPerBar_) == 0);
        }
        if (clickLeft_ > 0) {
            const double v = nextClick();
            yl += v;
            yr += v;
        }
        if (stopFade_ > 0) {
            fade = static_cast<double>(stopFade_) / (kStopSeconds * sr_);
            if (--stopFade_ == 0) {
                playing_ = false;
                stopEnded_ = true;
            }
        } else if (!playing_ && !previewChunk_) {
            fade = 0.0;
        } else if (previewChunk_ && previewRampIn_ > 0) {
            const int len = std::max(1, static_cast<int>(kStopSeconds * sr_));
            fade = 1.0 - static_cast<double>(previewRampIn_--) / len;
        } else if (playing_ && playRampIn_ > 0) {
            const int len = std::max(1, static_cast<int>(kStopSeconds * sr_));
            fade = 1.0 - static_cast<double>(playRampIn_--) / len;
        } else {
            fade = 1.0;  // a fade in that ended earlier in this chunk is done: the rest is at full level
        }
        float ol, orr;
        if (toneLeft_ > 0) {
            // The test tone joins after the transport's fades (it sounds stopped too) and before the limiter, which
            // follows the louder of the song's own level and the sum, so the sum stays under the ceiling.
            const double t = nextTone();
            const double sl = yl * fade + t, sr = yr * fade + t;
            const double env = std::max({std::fabs(yl), std::fabs(yr), std::fabs(sl), std::fabs(sr)});
            limEnv_ = env > limEnv_ ? env : env + (limEnv_ - env) * rel;
            const double gain = bypass ? 1.0 : (limEnv_ > kLimitCeiling ? kLimitCeiling / limEnv_ : 1.0);
            ol = static_cast<float>(sl * gain);
            orr = static_cast<float>(sr * gain);
        } else {
            const double env = std::max(std::fabs(yl), std::fabs(yr));
            limEnv_ = env > limEnv_ ? env : env + (limEnv_ - env) * rel;
            const double gain = bypass ? 1.0 : (limEnv_ > kLimitCeiling ? kLimitCeiling / limEnv_ : 1.0);
            ol = static_cast<float>(yl * gain * fade);
            orr = static_cast<float>(yr * gain * fade);
        }
        outL[frame] = ol;
        outR[frame] = orr;
        pl = std::max(pl, std::fabs(ol));
        pr = std::max(pr, std::fabs(orr));
        masterScope_[sp].store(0.5f * (ol + orr), std::memory_order_relaxed);
        sp = (sp + 1) % kScopeSize;
    };

    if (!masterChain_ && masterFadeLeft_ == 0) {
        // Keep the normal Engine path allocation-free and free of extra staging copies.
        for (int i = 0; i < m; ++i) {
            if (masterRamp_ > 0) {
                master_ += masterStep_;
                if (--masterRamp_ == 0) master_ = masterTarget_;
            }
            const double xl = finiteOr0(static_cast<double>(inL[i])) * master_;
            const double xr = finiteOr0(static_cast<double>(inR[i])) * master_;
            const double yl = xl - dcL_[0] + R * dcL_[1];
            dcL_[0] = xl;
            dcL_[1] = yl;
            const double yr = xr - dcR_[0] + R * dcR_[1];
            dcR_[0] = xr;
            dcR_[1] = yr;
            finishSample(i, bypass ? xl : yl, bypass ? xr : yr);
        }
    } else {
        // The chain runs in place on the Engine's scratch block; projects without native components
        // skip this branch and its copies. The callback never allocates or locks.
        float* stageL = masterStageL_;
        float* stageR = masterStageR_;
        for (int i = 0; i < m; ++i) {
            if (masterRamp_ > 0) {
                master_ += masterStep_;
                if (--masterRamp_ == 0) master_ = masterTarget_;
            }
            const double xl = finiteOr0(static_cast<double>(inL[i])) * master_;
            const double xr = finiteOr0(static_cast<double>(inR[i])) * master_;
            const double yl = xl - dcL_[0] + R * dcL_[1];
            dcL_[0] = xl;
            dcL_[1] = yl;
            const double yr = xr - dcR_[0] + R * dcR_[1];
            dcR_[0] = xr;
            dcR_[1] = yr;
            stageL[i] = static_cast<float>(bypass ? xl : yl);
            stageR[i] = static_cast<float>(bypass ? xr : yr);
        }
        ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), playing_ && !previewChunk_};
        time.modulation = modulation_->forChain(-1, ModChainKind::Master, masterChain_, 0);  // #161
        const ChainTime* t = &time;
        const bool fading = masterFadeLeft_ > 0;
        if (fading) {
            std::copy_n(stageL, m, fadeL_);
            std::copy_n(stageR, m, fadeR_);
            ChainTime fadeTime = time;
            fadeTime.modulation = modulation_->forChain(-1, ModChainKind::Master, masterFading_, 1);
            if (masterFading_) masterFading_->process(fadeL_, fadeR_, static_cast<uint32_t>(m), sr_, &fadeTime);
        }
        if (masterChain_) masterChain_->process(stageL, stageR, static_cast<uint32_t>(m), sr_, t);
        if (masterTailFade_ != 0 && previewChunk_) {  // the master's capped tail fading out
            const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
            for (int i = 0; i < m; ++i) {
                const float g = masterTailFade_ > 0 ? static_cast<float>(masterTailFade_) / static_cast<float>(len) : 0.0f;
                if (masterTailFade_ > 0 && --masterTailFade_ == 0) masterTailFade_ = -1;
                stageL[i] *= g;
                stageR[i] *= g;
            }
        }
        if (fading) {
            const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
            for (int i = 0; i < m; ++i) {
                const float w = masterFadeLeft_ > 0 ? static_cast<float>(len - masterFadeLeft_ + 1) / static_cast<float>(len + 1) : 1.0f;
                if (masterFadeLeft_ > 0) --masterFadeLeft_;
                stageL[i] = fadeL_[i] + (stageL[i] - fadeL_[i]) * w;
                stageR[i] = fadeR_[i] + (stageR[i] - fadeR_[i]) * w;
            }
            if (masterFadeLeft_ == 0 && masterFading_) {
                if (canRetire(1)) {
                    retire(nullptr, nullptr, nullptr, nullptr, nullptr, masterFading_);
                    masterFading_ = nullptr;
                } else {
                    masterFadeLeft_ = 1;
                }
            }
        }
        const float* currentL = stageL;
        const float* currentR = stageR;
        for (int i = 0; i < m; ++i) finishSample(i, currentL[i], currentR[i]);
    }

    masterQuiet_ = std::max(pl, pr) > kPreviewQuiet ? 0 : masterQuiet_ + m;  // for the master chain's tail
    masterScopePos_.store(sp, std::memory_order_release);
    storeMax(peakL_, pl);
    storeMax(peakR_, pr);
    masterCorrelation_.process(outL, outR, m);
    loudness_->process(outL, outR, m);  // K-weighting and true peak per sample; the rest each 100 ms
}

void Engine::pickOverloadVictim() noexcept {
    int best = -1;
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
        const Slot& s = slotAt(i);
        if (!s.active || s.overloaded || slotTarget(s) == 0.0) continue;
        if (best < 0 || s.order > slotAt(best).order) best = i;
    }
    if (best >= 0) {
        slotAt(best).overloaded = true;
        slotAt(best).overloadFlag.store(true, std::memory_order_relaxed);
        overloadedFlag_.fetch_add(1, std::memory_order_relaxed);
    }
}

void Engine::process(float* left, float* right, int frames) noexcept {
    // Whether any layer is soloed, worked out once per callback rather than once per layer and block.
    updateSolo();
    applyCommands();
    updateSolo();
    takeDeviceMidi(frames);
    takeToneRequest();
    if (!playing_ && monitorWanted_.load(std::memory_order_relaxed)) wakeMonitors();
    if (overloadPending_) {
        overloadPending_ = false;
        pickOverloadVictim();
    }
    int i = 0;
    while (i < frames) {
        if (countInLeft_ > 0) {
            // Count-in: the transport waits while the clicks play (previews play over them), then starts on the
            // sample after the last beat, once the retire queue has room for a Play (else a chunk later).
            const int m = static_cast<int>(std::min<int64_t>({static_cast<int64_t>(frames - i), kBlock, countInLeft_}));
            int done = m;
            if (previewing_) {
                previewChunk_ = true;
                midiChunkFrom_ = i;
                tapAt_ = i;
                done = processChunk(left + i, right + i, m);
                previewChunk_ = false;
            } else {
                std::fill(left + i, left + i + m, 0.0f);
                std::fill(right + i, right + i + m, 0.0f);
                mixToneOnly(left + i, right + i, m);
            }
            for (int j = 0; j < done; ++j) {
                if (countInAt_ % countInBeat_ == 0) startClick((countInAt_ / countInBeat_) % std::max(1, beatsPerBar_) == 0);
                ++countInAt_;
                const float v = static_cast<float>(nextClick());
                left[i + j] = std::clamp(left[i + j] + v, -1.0f, 1.0f);
                right[i + j] = std::clamp(right[i + j] + v, -1.0f, 1.0f);
            }
            countInLeft_ -= done;
            i += done;
            if (countInLeft_ == 0) {
                if (canRetire(static_cast<size_t>(2 * slotCount_))) startPlay(countInFrom_, countInPlayCount_, countInTouchStamp_);
                else countInLeft_ = 1;  // [Assumption] a full retire queue is rare; the start slips by a sample
            }
            continue;
        }
        if (!playing_) {
            if (!previewing_) {
                std::fill(left + i, left + frames, 0.0f);
                std::fill(right + i, right + frames, 0.0f);
                mixToneOnly(left + i, right + i, frames - i);
                break;
            }
            // Stopped with previews: they play, the transport stays where it is.
            previewChunk_ = true;
            midiChunkFrom_ = i;
            tapAt_ = i;
            const int m = processChunk(left + i, right + i, std::min(frames - i, kBlock));
            previewChunk_ = false;
            i += m;
            continue;
        }
        // The song loops at its end, or at the loop range's end while that is on (and before it).
        const int64_t wrap = wrapAt();
        const int maxM = static_cast<int>(std::min<int64_t>({static_cast<int64_t>(frames - i), kBlock, wrap - g_}));
        midiChunkFrom_ = i;
        tapAt_ = i;
        const int m = processChunk(left + i, right + i, maxM);
        if (stopEnded_) {
            stopEnded_ = false;
            endPlayback();
        }
        g_ += m;
        if (g_ >= wrap) {
            g_ = loopRange_ ? loopFrom_ : 0;
            ++epoch_;
        }
        i += m;
    }
    if (midiPendingCount_ > 0) endDeviceMidi(frames);
    if (previewing_) updatePreviewing(frames);
    toneActive_.store(toneLeft_ > 0, std::memory_order_release);
    playingFlag_.store(playing_, std::memory_order_relaxed);
    posFlag_.store(g_, std::memory_order_relaxed);
}

// Tuned at 512-frame callbacks at 48 kHz (10.7 ms): the average kept 0.9 of itself a callback, 20 callbacks over
// 0.85 shed a layer and 100 callbacks passed before the next. The same in seconds, for any callback size.
void Engine::reportLoad(double load, int frames) noexcept {
    constexpr double kTick = 512.0 / 48000.0;
    constexpr double kOverSeconds = 20 * kTick, kCoolSeconds = 100 * kTick;
    constexpr double kSlack = 1e-9;  // summed callback lengths land a hair under the product
    if (frames <= 0) return;
    const double dt = static_cast<double>(frames) / sr_;
    if (dt != loadDt_) {  // the size rarely changes: pow only then
        loadDt_ = dt;
        loadKeep_ = std::pow(0.9, dt / kTick);
    }
    loadAvg_ = loadKeep_ * loadAvg_ + (1.0 - loadKeep_) * (std::isfinite(load) ? load : 0.0);
    cpu_.store(static_cast<float>(loadAvg_), std::memory_order_relaxed);
    coolSeconds_ = std::max(0.0, coolSeconds_ - dt);
    if (loadAvg_ > 0.85) {
        overSeconds_ += dt;
        if (overSeconds_ >= kOverSeconds - kSlack && coolSeconds_ <= kSlack) {
            overloadPending_ = true;
            overSeconds_ = 0;
            coolSeconds_ = kCoolSeconds;
        }
    } else {
        overSeconds_ = 0;
    }
}

}  // namespace caw
