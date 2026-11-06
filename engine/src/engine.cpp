// Mixer implementation: the audio-thread render loop and the control-thread project diffing that feeds it.
#include "engine.h"
#include "graph.h"
#include "route_math.h"
#include "hardware.h"

#include <algorithm>
#include <cassert>
#include <array>
#include <chrono>
#include <cstdio>
#include <cmath>
#include <stdexcept>
#include <thread>

#include "compile.h"
#include "detmath.h"
#include "json.h"
#include "params.h"
#include "tables.h"

namespace caw {

// Immutable automation prepared on the control thread and reclaimed off the audio callback.
struct Engine::AutomationData {
    std::vector<AutomationPointSpec> volume;
    std::vector<AutomationPointSpec> pan;
};

// Export buffers, allocated on the control thread and never moved. Each slot points at its own
// slice of a pointer segment: one segment for every slot when the pool is first made, then one per
// grow for the slots it adds, so a grow never moves a slice the audio thread reads.
struct Engine::ExportPool {
    size_t capacityPerSlot = 0;
    std::vector<std::unique_ptr<std::array<double, kBlock>*[]>> segments;
    std::vector<std::unique_ptr<std::array<double, kBlock>>> buffers;
};

// Per-layer audio and meter state. Fields above `vol` belong to the audio thread.
struct Engine::Slot {
    // This slot's place in the slot table: fixed for a layer slot; the audition slot (always the
    // last) gets the new last index from the audio thread when a Grow swaps in a larger table.
    int index = -1;
    bool active = false;
    bool removing = false;
    bool fresh = true;       // the chain has not played yet since it was installed or play started
    bool contiguous = false; // the previous sample was processed, so a seam can crossfade
    bool overloaded = false;
    bool bus = false;
    int parentSlot = -1;
    AutomationData* automation = nullptr;
    double outL[kBlock] = {}, outR[kBlock] = {};
    Chain* cur = nullptr;
    Chain* old = nullptr;    // previous chain, fading out after a hot swap
    Chain* pending = nullptr;  // new code waiting for the next beat or bar
    std::shared_ptr<const Pattern>* pattern = nullptr;  // owned here, freed on the control thread when retired
    int swapLeft = 0;
    int seamLeft = 0;
    int64_t shadowN = 0;
    int steps = 0;
    int order = 0;
    int64_t k = -1, epoch = -1, lastN = 0, expectG = -1;
    double gain = 0;
    double panCache = 2, gl = 0, gr = 0;

    std::atomic<uint64_t> vol{0}, pan{0};
    std::atomic<bool> mute{false}, solo{false};
    std::atomic<float> peak{0}, progress{0};
    std::atomic<bool> overloadFlag{false};
    std::atomic<float> scope[kScopeSize];
    std::atomic<int> scopePos{0};

    bool ctlBusy = false;  // control thread only: a layer holds this slot, or it is still fading out

    std::array<double, kBlock>** exportBuf = nullptr;  // stable slice in Engine::ExportPool
    size_t exportCapacity = 0;
    size_t exportCount = 0;  // grows to the largest active chain export count; audio-thread owned

    // This chunk's plan (planChunk), read by the slot's graph nodes. Chunks end at every loop
    // boundary and code swap of a playing track, so one plan covers the whole chunk.
    enum class Mode : uint8_t { Idle, Bus, Silent, Play };
    Mode mode = Mode::Idle;
    double target = 0;          // mix target (0 while muted or soloed out)
    int64_t n0 = 0, repeat = 0; // sample in the layer's loop, and the pattern repeat
    const Pattern* pat = nullptr;
    bool seam = false;          // the shadow lane finishes the previous pass this chunk
    bool fade = false;          // the replaced chain plays on in the fade lane this chunk
    bool previewing = false;    // audio thread: the chain holds a preview voice, or its sound is still dying away
    int64_t previewQuiet = 0;   // samples the track's output has been below kPreviewQuiet
    int64_t previewTail = 0;    // samples since its last preview voice ended
    int64_t previewN = 0;       // stopped: the sample in the layer's loop that preview chunks run from
};

// One sounding note of a pattern layer's generator.
struct Voice {
    Instance* inst = nullptr;
    bool active = false, gate = false, trig = false;
    uint32_t note = 0;
    uint16_t sub = 0;
    int64_t started = 0;  // note-on order, for stealing the oldest and for exports
    int64_t since = 0;    // samples since note-on
    int64_t rel = 0;      // samples since release
    int64_t quiet = 0;    // samples below -90 dB since release
    double pitch = 60, target = 60, glideStep = 0, freq = 261.6255653005986;
    int glideLeft = 0;
    double vel = 1, tacc = 0, phase = 0;
    double lastY = 0;     // last output sample, so a voice cut short can be smoothed over
    int64_t offAt = -1;   // a note from an edited pattern: the sample (in the layer pass) where it ends
    // The note's own bend, pressure, timbre and vibrato, copied at note start (no allocation on the audio thread).
    bool expressive = false;
    NoteExpression ex;
    int64_t exStart = 0;  // `since` when this note took the voice (a slide hands a voice on mid-way)
    double exLen = 1;     // the note's length in samples, for the curves' 0..1 time
    // The curves run at control rate: worked out every kExpressionStep samples, with linear steps in between.
    double bend = 0, press = 1, timbre = 0, freqNow = 0;
    double dBend = 0, dPress = 0, dTimbre = 0, dFreq = 0;
    int exLeft = 0;  // samples until the next control point
    int32_t preview = -1;  // a note preview's id (#103), or -1 for a pattern's note
};

constexpr int kExpressionStep = 16;  // 1/3 ms at 48 kHz: smooth for bends and vibrato up to 30 Hz, 16x cheaper

constexpr uint32_t kOrphanNote = 0xFFFFFFFFu;  // a held note whose pattern was edited: ends at offAt
constexpr uint32_t kPreviewNote = 0xFFFFFFFEu;  // a note preview: no pattern event matches it, only its own off

// One layer's modules: the main instances plus shadow copies that play the loop's tail across a seam. A layer
// with a pattern runs its generator as voiceCount voices instead (main[0], shadow[0] and extras), with no seams.
struct Engine::Chain {
    std::vector<std::unique_ptr<Instance>> main, shadow;
    bool voiced = false;
    size_t expressionCapacity = 0;
    std::vector<std::unique_ptr<Instance>> extraVoices;
    Voice voices[kMaxVoices];
    int voiceCount = 0;  // voices with an instance: the generator's voices: setting, at least 2 (main and shadow)
    int voiceTake = 0;   // voices that take new notes: the voices: setting itself, 1..kMaxVoices
    int64_t noteCount = 0;
    double declick = 0;  // what voices cut short (stolen or ended) were playing; decays over about 2 ms
    double vtb[kBlock], vtime[kBlock], vphase[kBlock], vtrig[kBlock], vgate[kBlock], vnote[kBlock], vfreq[kBlock];
    double vvel[kBlock], vrel[kBlock], vout[kBlock], gen[kBlock];
    double vbend[kBlock], vpress[kBlock], vtimbre[kBlock];
    double ones[kBlock], dnote[kBlock], dfreq[kBlock];
    // Each .caw param resolves through the shared parameter model (F6.6): its held value (set by
    // writeParams) is the manual base and its automation lane (if any) the automated one. Only a
    // knob move (setParam/setGlobal, which bump the param's touch serial) is a touch, until the
    // next Play; any other held-value change (a project update) is a restore. .caw params have
    // no smoothing, so resolving a module more than once per chunk (lanes, shadow) gives the
    // same values.
    struct ParamSlot {
        ParameterResolver resolver;
        bool active = false;          // false: the descriptor did not validate; the VM reads the held value
        uint64_t heldBits = 0;        // the held value last seen (audio thread after publication)
        uint32_t seenSerial = 0;      // the touch stamp last seen (audio thread)
        bool passThrough = false;     // no lane and the held value resolves to itself: skip the resolver
        const ProjectAutomationLaneSpec* lane = nullptr;
    };
    std::vector<std::array<double, kBlock>> paramSamples;
    std::vector<const double*> paramValuePtrs;
    std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>> automation;
    std::vector<std::vector<ParamSlot>> paramSlots;  // [module][param]
    // [module][param]: the stamp of the last knob move (control thread, release), read by the audio thread.
    std::vector<std::unique_ptr<std::atomic<uint32_t>[]>> touchSerials;
    std::array<double, kBlock> laneScratch{};
    uint64_t touchEpoch = 0;  // the play count this chain's touches belong to
    std::vector<std::string> moduleIds;
    // How each module takes over the running state of the chain it replaces, so unchanged calls play on.
    struct Migration {
        int from = -1;                    // module index in the replaced chain
        const Program* expect = nullptr;  // the program the plan was made against
        std::vector<std::array<uint32_t, 3>> ranges;  // (from offset, to offset, count)
    };
    std::vector<Migration> migrate;
    std::vector<std::vector<std::pair<uint16_t, size_t>>> exportMap;  // per module: (register, export buffer)
    size_t exportCount = 0;
    std::vector<std::vector<const double*>> importPtrs;            // per module: one pointer per import
    uint32_t used = 0;
    double layerLen = 1;  // samples in this layer's loop, for pos and phase
    // Per lane (0 the main pass, 1 the shadow across a seam): the block's time variables, worked
    // out once per chunk by the first module node and read by the rest, plus the lane's input.
    struct Lane {
        double nb[kBlock], stepb[kBlock], beatb[kBlock], barb[kBlock], posb[kBlock], timeb[kBlock];
        double srb[kBlock], bpmb[kBlock], seedb[kBlock], dtrig[kBlock], in[kBlock];
    } lanes[2];
    double tb[kBlock], rateb[kBlock], zero[kBlock];
};

struct Engine::MasterChain {
    std::vector<std::unique_ptr<ModuleProcessor>> processors;
};

struct Engine::Cmd {
    enum Type { Install, SetSteps, SetPattern, Remove, Transport, SetMaster, SetMasterChain, Play, Stop, AuditionOnly, ClearOverload, SetOrder, SetRouting, ConfigureBus, SetAutomation, Grow, Preview } type = Play;
    std::shared_ptr<const Pattern>* pattern = nullptr;
    std::vector<int>* orderList = nullptr;  // SetOrder: slots in dependency order (owned; retired by the audio thread)
    SlotTable* table = nullptr;  // Grow: the larger slot table (owned; the one it replaces is retired)
    int slot = 0;
    Chain* chain = nullptr;
    MasterChain* masterChain = nullptr;
    int steps = 0, order = 0, parentSlot = -1;
    AutomationData* automation = nullptr;
    double bpm = 120, master = 0.7;
    int beatsPerBar = 4, loopSteps = 64, keyRoot = 9, keyScale = 1;
    uint32_t seed = 0;
    bool seamXf = true, flag = false;
    int swapMode = 0;
    int voices = kMaxVoices;
    uint64_t playCount = 0;    // Play: the control thread's play count, which ends touches
    double fromStep = 0;       // Play: where in the project loop to start, in sixteenth steps
    uint32_t touchStamp = 0;   // Play: the last touch stamp before it (later stamps are touches after it)
    // Preview: what to do with preview [previewId] on [slot]: 0 note on, 1 glide to [pitch], 2 note off, 3 all off.
    int previewOp = 0;
    int32_t previewId = 0;
    double pitch = 60, vel = 1;
};

struct Engine::Retired {
    Chain* chain = nullptr;
    Slot* freed = nullptr;  // a slot whose layer has faded out (by object: the audition's index can change)
    std::shared_ptr<const Pattern>* pattern = nullptr;
    AutomationData* automation = nullptr;
    std::vector<int>* order = nullptr;
    SlotTable* table = nullptr;  // a slot table (and its mix graph) a Grow replaced
    MasterChain* masterChain = nullptr;
};

namespace {

constexpr double kSwapSeconds = 0.02;
constexpr uint64_t kMasterScratchBytes = 4ull * kBlock * sizeof(float);
constexpr double kSeamSeconds = 0.003;
constexpr double kStopSeconds = 0.01;
constexpr double kPreviewGlideSeconds = 0.005;  // a held preview glides to a new pitch this fast (a bend being drawn)
constexpr float kPreviewQuiet = 1e-4f;          // -80 dB: a preview's effect tail below this has died away
constexpr double kPreviewQuietSeconds = 0.25;   // ... once it has stayed below it this long
constexpr double kPreviewTailSeconds = 30.0;    // the longest a tail (or a self-oscillating effect) keeps running
constexpr double kGainSeconds = 0.005;
constexpr double kLimitCeiling = 0.977;  // about -0.2 dBFS
// Play retires up to two entries per slot and must always find room, even with the retired queue
// full: the pending list holds 2 * (maxLayers() + 1) entries plus this slack (256 at 64 layers).
constexpr int kPendingSlack = 126;
// What one slot's export segment reserves per buffer: the pointer, the owner, and the buffer.
constexpr uint64_t kExportBufferBytes = static_cast<uint64_t>(kBlock) * sizeof(double);
constexpr uint64_t kExportSlotBytes =
    kExportBufferBytes + sizeof(std::array<double, kBlock>*) + sizeof(std::unique_ptr<std::array<double, kBlock>>);
// Grows above this many layers are not considered (node counts stay far inside uint32_t).
constexpr int kLayerCeiling = 1 << 20;
constexpr double kVoiceQuietSeconds = 0.1;   // a released voice ends after this long below -90 dB
constexpr double kVoiceMaxRelease = 10.0;    // or this long after release, whatever its level
constexpr double kQuietLevel = 3.1622776601683795e-5;  // -90 dB
constexpr double kReleaseFade = 0.01;        // code that ignores gate and rel fades out this fast at note-off
constexpr double kDeclickSeconds = 0.002;
constexpr int kMaxSplits = 16;               // note changes that split one block; more start together
constexpr int64_t kMaxTakeOver = 262144;     // state numbers a code swap may copy (2 MB): beyond it, start fresh
constexpr double kC4 = 261.6255653005986;

double mtof(double note) { return 440.0 * detPow(2.0, (note - 69.0) / 12.0); }

 // An upper bound on the bytes compileArrangement builds, so a huge looping clip is refused before it is expanded.
double arrangementBytes(const std::vector<ClipSpec>& clips,
    const std::map<std::string, std::shared_ptr<const Pattern>>& sources, int beatsPerBar) {
    double total = 0;
    for (const ClipSpec& clip : clips) {
        const auto found = sources.find(clip.pattern);
        if (found == sources.end() || !found->second || found->second->notes.empty()) continue;
        const Pattern& src = *found->second;
        const double sourceLength = std::max(1, src.steps(beatsPerBar));
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
        const auto found = sources.find(clip.pattern);
        if (found == sources.end() || !found->second) continue;
        const Pattern& src = *found->second;
        if (src.notes.empty()) continue;  // nothing to place, however often the clip repeats it
        const int sourceLength = std::max(1, src.steps(beatsPerBar));
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

// Lets every held note go into its release (at a layer restart, or when the pattern changes).
// A pattern restarting releases its own notes; held previews keep sounding until their note off.
void releaseVoices(Voice* voices, int count) {
    for (int v = 0; v < count; ++v)
        if (voices[v].active && voices[v].gate && voices[v].preview < 0) {
            voices[v].gate = false;
            voices[v].rel = 0;
            voices[v].quiet = 0;
        }
}

double bitsToDouble(uint64_t b) { return std::bit_cast<double>(b); }
uint64_t doubleToBits(double d) { return std::bit_cast<uint64_t>(d); }

double automationValue(int count, const double* steps, const double* values, double at, double fallback) noexcept {
    if (count <= 0) return fallback;
    if (at <= steps[0]) return values[0];
    int lo = 0, hi = count - 1;
    while (lo + 1 < hi) {
        const int mid = (lo + hi) / 2;
        if (steps[mid] <= at) lo = mid; else hi = mid;
    }
    if (at >= steps[count - 1]) return values[count - 1];
    const double span = steps[hi] - steps[lo];
    if (span <= 0.0) return values[hi];
    const double t = (at - steps[lo]) / span;
    return values[lo] + (values[hi] - values[lo]) * t;
}

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
    // Lanes on a track's module edges: 0 the current chain, 1 its shadow finishing the previous
    // pass across a loop seam, 2 the replaced chain fading out after a code swap.
    static constexpr uint32_t kLanes = 3;
    static constexpr int K = kMaxTrackModules;

    class ModuleNode final : public ModuleProcessor {
    public:
        ModuleNode(Engine& e, int slot, int index, const ModuleDescriptor& d) : e_(e), slot_(slot), index_(index), d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        using ModuleProcessor::process;
        bool process(const AudioProcessBlock& b) noexcept override {
            e_.runModuleNode(slot_, index_, b.input.channels, b.output.channels, static_cast<int>(b.frames));
            return true;
        }
    private:
        Engine& e_;
        int slot_, index_;
        const ModuleDescriptor& d_;
    };
    class TrackNode final : public ModuleProcessor {
    public:
        TrackNode(Engine& e, int slot, const ModuleDescriptor& d) : e_(e), slot_(slot), d_(d) {}
        const ModuleDescriptor& descriptor() const noexcept override { return d_; }
        using ModuleProcessor::process;
        bool process(const AudioProcessBlock& b) noexcept override {
            e_.runTrackNode(slot_, b.input.channels, b.output.channels[0], b.output.channels[1],
                            static_cast<int>(b.frames));
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

    // Node layout: K module nodes per slot, then a track node and a bus node per slot, then master.
    static constexpr uint32_t moduleNode(int slot, int index) { return static_cast<uint32_t>(slot * K + index); }
    // The layout depends on the slot count (layer capacity + the audition), fixed at construction.
    const int slots;   // slot count
    const int master;  // the master in slot-level routing scratch (== slots)
    uint32_t trackNode(int slot) const noexcept { return static_cast<uint32_t>(slots * K + slot); }
    uint32_t busNode(int slot) const noexcept { return static_cast<uint32_t>(slots * K + slots + slot); }
    uint32_t masterNode() const noexcept { return static_cast<uint32_t>(slots * (K + 2)); }
    int nodeCount() const noexcept { return slots * (K + 2) + 1; }
    int maxEdges() const noexcept { return slots * (K + 1); }
    // The mixer graph is fixed engine structure (nodeCount() nodes of kBlock frames, about 2 MB at 64 layers), not
    // project content, so it gets its own budget floor rather than competing with project graphs.
    static constexpr std::size_t kMinBudgetBytes = 8u * 1024u * 1024u;

    const PortDescriptor ports[2] = {{"in", PortType::Audio, ChannelLayout::Stereo, true, 0, true},
                                     {"out", PortType::Audio, ChannelLayout::Stereo, false}};
    const PortDescriptor lanePorts[2] = {{"in", PortType::Audio, ChannelLayout::Discrete, true, kLanes},
                                         {"out", PortType::Audio, ChannelLayout::Discrete, false, kLanes}};
    const PortDescriptor trackPorts[2] = {{"in", PortType::Audio, ChannelLayout::Discrete, true, kLanes},
                                          {"out", PortType::Audio, ChannelLayout::Stereo, false}};
    const ModuleDescriptor moduleDescriptor{"caw.track.module", 1, lanePorts, 2, nullptr, 0};
    const ModuleDescriptor trackDescriptor{"caw.track.out", 1, trackPorts, 2, nullptr, 0};
    const ModuleDescriptor busDescriptor{"caw.mixer.bus", 1, ports, 2, nullptr, 0};
    const ModuleDescriptor masterDescriptor{"caw.mixer.master", 1, ports, 2, nullptr, 0};
    std::vector<std::string> ids;
    std::vector<std::unique_ptr<ModuleProcessor>> nodes;
    GraphExecutor executor;

    // Routing scratch, audio thread only; slot-level arrays use `master` for the master. Sized in
    // the constructor and never resized on the audio thread.
    std::vector<int> target;          // [slots] routed destination slot (or master), or -1
    std::vector<uint8_t> routable;    // [slots] runs this chunk: active, and a bus or a track with a chain
    std::vector<int> modules;         // [slots] module nodes a routed track runs
    std::vector<int> pending;         // [slots + 1] routed children not yet ordered
    std::vector<uint8_t> deferred;    // [slots + 1]
    std::vector<uint8_t> emitted;     // [slots + 1]
    std::vector<int> slotOrder;       // [slots]
    std::vector<uint32_t> position;   // [slots + 1]
    std::vector<uint32_t> order;      // [nodeCount()]
    std::vector<GraphConnection> edges;  // [maxEdges()]

    // capacity: layer slots; the graph also routes the audition slot after them.
    MixGraph(Engine& e, int capacity, double sampleRate, const EngineResourceBudget& engineBudget)
        : slots(capacity + 1), master(capacity + 1),
          target(static_cast<size_t>(slots), 0), routable(static_cast<size_t>(slots), 0),
          modules(static_cast<size_t>(slots), 0), pending(static_cast<size_t>(slots) + 1, 0),
          deferred(static_cast<size_t>(slots) + 1, 0), emitted(static_cast<size_t>(slots) + 1, 0),
          slotOrder(static_cast<size_t>(slots), 0), position(static_cast<size_t>(slots) + 1, 0),
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
            for (int i = 0; i < K; ++i)
                add("slot" + std::to_string(s) + ".m" + std::to_string(i),
                    std::make_unique<ModuleNode>(e, s, i, moduleDescriptor), &moduleDescriptor);
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
        b += static_cast<std::size_t>(slots) * (K * sizeof(ModuleNode) + sizeof(TrackNode) + sizeof(BusNode)) + sizeof(MasterNode);
        b += static_cast<std::size_t>(nodeCount()) * (sizeof(GraphNode) + sizeof(ModuleProcessor*));
        b += (target.capacity() + modules.capacity() + pending.capacity() + slotOrder.capacity()) * sizeof(int);
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
    std::unique_ptr<MixGraph> graph;
};

uint32_t Engine::mixGraphNodesRun() const noexcept { return mixGraph_->executor.runCount(); }

void Engine::bindTable() noexcept {
    SlotTable& t = *table_;
    slots_ = t.slots.get();
    mixGraph_ = t.graph.get();
    processOrder_ = t.processOrder.get();
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
      exportPerSlot_(static_cast<size_t>((resourceBudget.graphWorkingBytes > kMasterScratchBytes
              ? resourceBudget.graphWorkingBytes - kMasterScratchBytes : 0) /
              (static_cast<uint64_t>(kInitialLayerCapacity + 1) * kExportSlotBytes))),
      cmds_(new Spsc<Cmd, 1024>()),
      retired_(new Spsc<Retired, 1024>()),
      masterScope_(new std::atomic<float>[kScopeSize]) {
    for (int i = 0; i < kScopeSize; ++i) masterScope_[i].store(0);
    ctlSr_ = sampleRate;
    constexpr int initial = kInitialLayerCapacity;
    auto first = std::make_unique<SlotTable>();
    first->capacity = initial;
    first->slots.reset(new Slot*[static_cast<size_t>(initial + 1)]);
    first->processOrder.reset(new int[static_cast<size_t>(initial + 1)]());
    slotStore_.reserve(static_cast<size_t>(initial + 1));
    for (int s = 0; s <= initial; ++s) {
        slotStore_.push_back(std::make_unique<Slot>());
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
                                                   sizeof(int) + 2 * sizeof(Retired)) +
            static_cast<double>(exportPerSlot_) * static_cast<double>(kExportSlotBytes - kExportBufferBytes);
        const double budget = static_cast<double>(resourceBudget_.graphWorkingBytes > kMasterScratchBytes
            ? resourceBudget_.graphWorkingBytes - kMasterScratchBytes : 0);
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
    // Play retires up to two entries per slot; the pending list holds that at the largest capacity,
    // so a Play never waits on the retired queue (Spsc, fixed at 1024) once the control thread drains.
    pendingMax_ = 2 * (maxLayers_ + 1) + kPendingSlack;
    if (pendingMax_ < 2 * (maxLayers_ + 1)) throw std::logic_error("pending list cannot hold a Play's retirements");
    pending_.reset(new Retired[static_cast<size_t>(pendingMax_)]);
    table_ = std::move(first);
    bindTable();
    ctlTable_ = table_.get();
    ctlCapacity_.store(initial, std::memory_order_relaxed);
    warmTables();  // the built-in wavetables are built here, never on the audio thread
    updateTiming();
    ctlLoopLen_ = loopLen_;
    loopLenFlag_.store(loopLen_);
}

Engine::~Engine() {
    // No audio thread runs any more: free everything directly.
    Cmd c;
    while (cmds_->pop(c)) {
        if (c.type == Cmd::Install) delete c.chain;
        delete c.pattern;
        delete c.automation;
        delete c.orderList;
        delete c.table;
        delete c.masterChain;
    }
    Retired r;
    while (retired_->pop(r)) {
        delete r.chain;
        delete r.pattern;
        delete r.automation;
        delete r.order;
        delete r.table;
        delete r.masterChain;
    }
    for (int i = 0; i < pendingCount_; ++i) {
        delete pending_[i].chain;
        delete pending_[i].pattern;
        delete pending_[i].automation;
        delete pending_[i].order;
        delete pending_[i].table;
        delete pending_[i].masterChain;
    }
    delete masterChain_;
    masterChain_ = nullptr;
    for (const auto& slot : slotStore_) {
        delete slot->cur;
        delete slot->old;
        delete slot->pending;
        delete slot->pattern;
        delete slot->automation;
    }
}

// ===================== control thread =====================

void Engine::drainRetired() {
    Retired r;
    while (retired_->pop(r)) {
        delete r.chain;
        delete r.pattern;
        delete r.automation;
        delete r.order;
        delete r.table;
        delete r.masterChain;
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
            if (c.type == Cmd::Install) delete c.chain;  // audio stalled; drop rather than hang the app
            delete c.pattern;
            delete c.automation;
            delete c.orderList;
            delete c.table;
            delete c.masterChain;
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
// it, and export segments for the new slots; sent to the audio thread as one Grow command.
std::string Engine::grow(int capacity) {
    SlotTable& old = *ctlTable_;
    if (capacity <= old.capacity) return {};
    if (capacity > maxLayers_)
        return "the project needs " + std::to_string(capacity) + " layer slots; this device's memory budget allows at most " +
               std::to_string(maxLayers_);
    const size_t storeBefore = slotStore_.size();
    const size_t segmentsBefore = exportPool_ ? exportPool_->segments.size() : 0;
    auto rollBack = [&] {  // nothing new reached the audio thread: drop it again
        slotStore_.resize(storeBefore);
        if (exportPool_) exportPool_->segments.resize(segmentsBefore);
    };
    auto t = std::make_unique<SlotTable>();
    try {
        t->capacity = capacity;
        t->slots.reset(new Slot*[static_cast<size_t>(capacity + 1)]);
        t->processOrder.reset(new int[static_cast<size_t>(capacity + 1)]());
        for (int s = 0; s < old.capacity; ++s) t->slots[s] = old.slots[s];
        t->slots[capacity] = old.slots[old.capacity];  // the audition; the audio thread sets its index
        slotStore_.reserve(storeBefore + static_cast<size_t>(capacity - old.capacity));
        for (int s = old.capacity; s < capacity; ++s) {
            slotStore_.push_back(std::make_unique<Slot>());
            Slot& slot = *slotStore_.back();
            slot.index = s;
            for (int i = 0; i < kScopeSize; ++i) slot.scope[i].store(0);
            t->slots[s] = &slot;
        }
        t->graph.reset(new MixGraph(*this, capacity, sr_, resourceBudget_));
        // The budget holds the old graph and the new one at once (maxLayers() allows for that).
        const uint64_t perSlot = sizeof(Slot) + sizeof(std::unique_ptr<Slot>) + sizeof(Slot*) + sizeof(int) +
                                 2 * sizeof(Retired) + exportPerSlot_ * (kExportSlotBytes - kExportBufferBytes);
        const uint64_t peak = static_cast<uint64_t>(old.graph->bytes()) + t->graph->bytes() +
                              perSlot * static_cast<uint64_t>(capacity + 1);
        if (peak > resourceBudget_.graphWorkingBytes) {
            rollBack();
            return "growing to " + std::to_string(capacity) + " layer slots needs " + std::to_string(peak) +
                   " bytes of graph working memory; this device's budget is " +
                   std::to_string(resourceBudget_.graphWorkingBytes);
        }
        if (exportPool_) {
            // New slots get their own segment; existing slices (which the audio thread reads) stay put.
            const size_t added = static_cast<size_t>(capacity - old.capacity);
            const size_t per = exportPool_->capacityPerSlot;
            exportPool_->segments.push_back(std::make_unique<std::array<double, kBlock>*[]>(per * added));
            exportPool_->buffers.reserve(per * static_cast<size_t>(capacity + 1));
            for (int s = old.capacity; s < capacity; ++s) {
                t->slots[s]->exportBuf = exportPool_->segments.back().get() + static_cast<size_t>(s - old.capacity) * per;
                t->slots[s]->exportCapacity = per;
            }
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

Engine::Chain* Engine::buildChain(const std::vector<std::string>& ids, const std::vector<const double*>& wiring,
                                  bool voiced, const Chain* prev, const std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>>& automation,
                                   size_t expressionCapacity) {
    auto* c = new Chain();
    c->voiced = voiced;
    size_t buf = 0;
    size_t w = 0;
    for (size_t i = 0; i < ids.size(); ++i) {
        const ModuleState& m = modules_.at(ids[i]);
        c->main.push_back(std::make_unique<Instance>(m.program));
        c->shadow.push_back(std::make_unique<Instance>(m.program));
        c->moduleIds.push_back(ids[i]);
        c->used |= m.program->usedVars;
        // Export buffers are numbered in chain order; setProject uses the same numbering.
        std::vector<std::pair<uint16_t, size_t>> exports;
        for (const ExportDef& e : m.program->exports) exports.emplace_back(e.reg, buf++);
        c->exportMap.push_back(std::move(exports));
        std::vector<const double*> imports;
        for (size_t k = 0; k < m.program->imports.size(); ++k) imports.push_back(w < wiring.size() ? wiring[w++] : nullptr);
        c->importPtrs.push_back(std::move(imports));
    }
    std::fill_n(c->zero, kBlock, 0.0);
    std::fill_n(c->ones, kBlock, 1.0);
    std::fill_n(c->dnote, kBlock, 60.0);
    std::fill_n(c->dfreq, kBlock, kC4);
    if (voiced && !c->main.empty()) {
        // Voice 0 and 1 reuse the main and shadow instances, so a layer always has at least two.
        c->voiceCount = std::clamp(c->main[0]->program().voices, 2, kMaxVoices);
        c->voiceTake = std::clamp(c->main[0]->program().voices, 1, kMaxVoices);
        for (int v = 2; v < c->voiceCount; ++v)
            c->extraVoices.push_back(std::make_unique<Instance>(c->main[0]->programPtr()));
        c->voices[0].inst = c->main[0].get();
        c->voices[1].inst = c->shadow[0].get();
        for (int v = 2; v < c->voiceCount; ++v) c->voices[v].inst = c->extraVoices[static_cast<size_t>(v - 2)].get();
    }
    c->exportCount = buf;
    c->expressionCapacity = std::max(expressionCapacity, prev ? prev->expressionCapacity : size_t{0});
    for (Voice& voice : c->voices) {
        voice.ex.bend.points.reserve(c->expressionCapacity);
        voice.ex.press.points.reserve(c->expressionCapacity);
        voice.ex.timbre.points.reserve(c->expressionCapacity);
    }
    size_t maxParams = 0;
    for (const auto& instance : c->main) maxParams = std::max(maxParams, instance->program().params.size());
    c->paramSamples.resize(maxParams);
    c->paramValuePtrs.resize(maxParams, nullptr);
    writeParams(*c);
    c->automation = automation;
    // Give every param a resolver and find its automation lane, on the control thread.
    c->paramSlots.resize(c->main.size());
    c->touchSerials.resize(c->main.size());
    c->touchEpoch = playCount_;  // its touches (below) already belong to the current playback
    for (size_t moduleIndex = 0; moduleIndex < c->main.size(); ++moduleIndex) {
        const Program& program = c->main[moduleIndex]->program();
        const std::string& moduleId = c->moduleIds[moduleIndex];
        c->paramSlots[moduleIndex].resize(program.params.size());
        c->touchSerials[moduleIndex] = std::make_unique<std::atomic<uint32_t>[]>(program.params.size());
        for (size_t paramIndex = 0; paramIndex < program.params.size(); ++paramIndex) {
            const ParamDef& def = program.params[paramIndex];
            Chain::ParamSlot& slot = c->paramSlots[moduleIndex][paramIndex];
            ParameterDescriptor descriptor;
            descriptor.id = def.name;  // the program outlives the chain's resolvers
            descriptor.defaultValue = def.def;
            descriptor.minimum = def.min;
            descriptor.maximum = def.max;
            descriptor.step = def.step;
            slot.active = slot.resolver.configure(descriptor);
            const double held = c->main[moduleIndex]->param(static_cast<int>(paramIndex));
            slot.heldBits = std::bit_cast<uint64_t>(held);
            if (slot.active) {
                slot.resolver.setInitial(held);
                // A touch made before this rebuild (since the last Play) carries over.
                const bool touched = def.global ? touchedGlobals_.count(def.name) != 0
                                                : touchedParams_.count({moduleId, def.name}) != 0;
                if (touched) slot.resolver.setBase(held);
            }
            const ProjectAutomationLaneSpec* selected = nullptr;
            for (const ProjectAutomationLaneSpec& lane : *automation) {
                const bool matches = lane.targetType == "global"
                    ? (def.global && lane.target == def.name)
                    : (lane.targetType == "param" && !def.global && lane.moduleId == moduleId && lane.target == def.name);
                if (matches) { selected = &lane; break; }
            }
            if (selected && !selected->points.empty()) slot.lane = selected;
        }
    }
    // Plan how this chain takes over the running state of the one it replaces: every stateful call whose name
    // (position in the code) and size are unchanged keeps playing, within a copy budget for the audio thread.
    if (prev) {
        int64_t budget = kMaxTakeOver;
        std::vector<bool> used(prev->moduleIds.size(), false);
        c->migrate.resize(ids.size());
        for (size_t i = 0; i < ids.size(); ++i) {
            for (size_t j = 0; j < prev->moduleIds.size(); ++j) {
                if (used[j] || prev->moduleIds[j] != ids[i]) continue;
                used[j] = true;
                Chain::Migration& m = c->migrate[i];
                m.from = static_cast<int>(j);
                const Program& from = prev->main[j]->program();
                const Program& to = c->main[i]->program();
                m.expect = &from;
                const int64_t copies =
                    (i == 0 && voiced && prev->voiced) ? std::min(c->voiceCount, prev->voiceCount) : 1;
                for (const StateSite& site : to.stateSites)
                    for (const StateSite& old : from.stateSites)
                        if (old.key == site.key && old.size == site.size) {
                            if (budget < static_cast<int64_t>(site.size) * copies) break;
                            budget -= static_cast<int64_t>(site.size) * copies;
                            m.ranges.push_back({old.offset, site.offset, site.size});
                            break;
                        }
                break;
            }
        }
    }
    return c;
}

void Engine::writeParams(Chain& c) {
    for (size_t i = 0; i < c.main.size(); ++i) {
        const ModuleState& m = modules_.at(c.moduleIds[i]);
        const Program& p = c.main[i]->program();
        for (size_t k = 0; k < p.params.size(); ++k) {
            const ParamDef& d = p.params[k];
            double v = d.def;
            if (d.global) {
                auto it = globals_.find(d.name);
                if (it != globals_.end()) v = it->second;
            } else {
                auto it = m.params.find(d.name);
                if (it != m.params.end()) v = it->second;
            }
            v = std::min(d.max, std::max(d.min, v));
            c.main[i]->setParam(static_cast<int>(k), v);
            c.shadow[i]->setParam(static_cast<int>(k), v);
            if (i == 0)
                for (auto& extra : c.extraVoices) extra->setParam(static_cast<int>(k), v);
        }
    }
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

bool Engine::unloadNativeComponent(const std::string& id) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    return nativeModules_.unload(id);
}

std::unique_ptr<ModuleProcessor> Engine::createNativeComponent(const std::string& id) {
    std::lock_guard<std::mutex> lock(ctl_);
    return nativeModules_.create(id);
}

std::string Engine::setProject(const ProjectSpec& p) {
    return setProjectImpl(p, false);
}

std::string Engine::setProjectOffline(const ProjectSpec& p) {
    return setProjectImpl(p, true);
}

std::string Engine::setProjectImpl(const ProjectSpec& p, bool offline) {
    std::lock_guard<std::mutex> lock(ctl_);
    offlineControl_ = offline;
    struct OfflineControlReset {
        bool& active;
        ~OfflineControlReset() { active = false; }
    } reset{offlineControl_};
    drainRetired();

    // The first native playback slice is a zero-parameter stereo master-effect chain.
    // Components must already be explicitly loaded through the trust-gated Engine API.
    std::unique_ptr<MasterChain> nextMasterChain;
    uint64_t masterChainBytes = 0;
    if (!p.masterComponents.empty()) {
        const uint64_t count = static_cast<uint64_t>(p.masterComponents.size());
        if (count > (std::numeric_limits<uint64_t>::max() - sizeof(MasterChain)) /
                        sizeof(std::unique_ptr<ModuleProcessor>))
            return R"({"ok":false,"error":"native master chain size overflows the project memory estimate","modules":{}})";
        masterChainBytes = sizeof(MasterChain) + count * sizeof(std::unique_ptr<ModuleProcessor>);
        if (masterChainBytes > resourceBudget_.projectStateBytes)
            return R"({"ok":false,"error":"native master chain exceeds this Engine's project-state memory budget","modules":{}})";
        nextMasterChain = std::make_unique<MasterChain>();
        nextMasterChain->processors.reserve(p.masterComponents.size());
        for (const std::string& componentId : p.masterComponents) {
            const ModuleDescriptor* descriptor = nativeModules_.find(componentId);
            if (!descriptor)
                return "{\"ok\":false,\"error\":\"native component '" + jsonEscape(componentId) +
                       "' is not loaded; load it with an explicit trust choice first\",\"modules\":{}}";
            const bool stereoEffect = descriptor->portCount == 2 && descriptor->ports &&
                descriptor->ports[0].type == PortType::Audio && descriptor->ports[0].input &&
                descriptor->ports[0].layout == ChannelLayout::Stereo && descriptor->ports[0].channelCount == 2 &&
                descriptor->ports[1].type == PortType::Audio && !descriptor->ports[1].input &&
                descriptor->ports[1].layout == ChannelLayout::Stereo && descriptor->ports[1].channelCount == 2 &&
                descriptor->parameterCount == 0;
            if (!stereoEffect)
                return "{\"ok\":false,\"error\":\"native component '" + jsonEscape(componentId) +
                       "' must currently expose one stereo audio input, one stereo audio output and no parameters\",\"modules\":{}}";
            auto processor = nativeModules_.create(componentId);
            if (!processor)
                return "{\"ok\":false,\"error\":\"native component '" + jsonEscape(componentId) +
                       "' could not create a processor instance\",\"modules\":{}}";
            nextMasterChain->processors.push_back(std::move(processor));
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
    t.seed = p.seed;
    t.master = p.master;
    t.seamXf = p.seamCrossfade;
    t.keyRoot = p.keyRoot;
    t.keyScale = p.keyScale;
    t.swapMode = p.swapMode;
    t.voices = p.voices;
    if (!send(t))
        return "{\"ok\":false,\"error\":\"audio command queue is not accepting project updates\",\"modules\":{}}";
    const double stepLen = 60.0 * ctlSr_ / (p.bpm * 4.0);
    ctlLoopLen_ = static_cast<int64_t>(std::floor(p.loopSteps() * stepLen + 0.5));

    globals_ = p.globals;
    const auto projectAutomation = std::make_shared<const std::vector<ProjectAutomationLaneSpec>>(p.automation);

    // Project libraries (kind: library) compile first; every other module can call their functions.
    std::vector<std::string_view> moduleSources;
    for (const ModuleSpec& m : p.modules) moduleSources.push_back(m.source);
    const std::vector<LibrarySource> libs = projectLibraries(moduleSources);
    std::string libSig;
    for (const LibrarySource& l : libs) libSig += l.ns + "\x1f" + l.source + "\x1e";

    // Compile changed modules. A module that fails keeps its last good program, so the old sound plays on.
    bool allOk = true;
    std::vector<std::pair<std::string, std::string>> synthWarnings;  // (synth id, message), added to warnings below
    std::map<std::string, ModuleState> next;
    for (const ModuleSpec& m : p.modules) {
        ModuleState st;
        auto it = modules_.find(m.id);
        if (it != modules_.end()) st = it->second;
        if (moduleKindOf(m.source) == ModuleKind::Pattern) {
            // Patterns are notes, not code: parse them; a broken one keeps its last good version playing.
            st.program = nullptr;
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
        } else if (it == modules_.end() || st.source != m.source || st.libSig != libSig || (!st.program && st.error.empty())) {
            CompileResult r = compileModule(m.source, libs);
            st.libSig = libSig;
            st.source = m.source;
            if (r.program) {
                st.program = r.program;
                st.error.clear();
                st.line = st.col = 0;
            } else {
                st.error = r.error;
                st.line = r.line;
                st.col = r.col;
            }
        }
        st.params = m.params;
        st.ref = refName(!m.name.empty() ? m.name : (st.program && !st.program->name.empty() ? st.program->name : m.id));
        // A synth plays as its voice then its effects: generated effect modules live as hidden modules beside it.
        st.expand.clear();
        if (st.program && st.program->synth) {
            st.expand.push_back(m.id);
            for (size_t k = 0; k < st.program->synthFx.size(); ++k) {
                const std::string& fx = st.program->synthFx[k];
                if (fx[0] == '@') {
                    st.expand.push_back("\x1e" + fx.substr(1));
                    continue;
                }
                // Keyed by the effect's kind and count ("delay_2"), so adding a line elsewhere keeps its tail.
                const std::string hid = m.id + "\x1f" + st.program->synthFxKeys[k];
                ModuleState hs;
                auto old = modules_.find(hid);
                if (old != modules_.end()) hs = old->second;
                if (hs.source != fx || hs.libSig != libSig || !hs.program) {
                    CompileResult cr = compileModule(fx, libs);
                    hs.source = fx;
                    hs.libSig = libSig;
                    if (cr.program) hs.program = cr.program;
                    hs.error = cr.program ? std::string() : cr.error;
                }
                if (!hs.error.empty())
                    synthWarnings.push_back({m.id, "the " + st.program->synthFxKeys[k] + " effect made from this patch doesn't compile (an engine bug): " + hs.error});
                hs.params = m.params;
                next[hid] = std::move(hs);
                st.expand.push_back(hid);
            }
        }
        if (!st.error.empty()) allOk = false;
        next[m.id] = std::move(st);
    }
    modules_ = std::move(next);

    // Layers: diff against what the audio thread has, sending only what changed.
    struct Want {
        std::string id;
        std::vector<std::string> chain;
        std::string pattern;
        int steps;
        double vol, pan;
        bool mute, solo;
        int order;
        std::vector<ClipSpec> clips;
        std::vector<AutomationLaneSpec> automation;
        std::string parentId;
        bool bus = false;
    };
    std::vector<Want> wants;
    int order = 0;
    if (p.auditionOnly) {
        wants.push_back({"\1audition", p.auditionChain, p.auditionPattern, p.auditionSteps, 0.8, 0.0, false, false, 100000, {}, {}, "", false});
    }
    order_.clear();
    for (const LayerSpec& l : p.layers) {
        order_.push_back(l.id);
        wants.push_back({l.id, l.chain, l.pattern, l.lengthSteps, l.volume, l.pan, l.mute, l.solo, ++order, l.clips, l.automation, l.parentId, l.folder && l.busEnabled});
    }

    // Pass 1: which modules each layer plays, and its slot.
    struct Planned {
        Want w;
        LayerState ls;
        std::vector<std::string> ids;
        std::vector<const Program*> sig;
        std::shared_ptr<const Pattern> pattern;
        std::string arrangementSig;
        std::string automationSig;
        std::string parameterAutomationSig;
        size_t expressionCapacity = 0;
    };
    std::vector<Planned> plan;
    std::map<std::string, LayerState> nextLayers;
    std::map<std::string, std::vector<std::string>> warnings;
    for (const auto& [id, msg] : synthWarnings) warnings[id].push_back(msg);
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
        Planned pl{w, {}, {}, {}, nullptr, {}, {}, {}};
        uint64_t layerStateDoubles = 0;
        // A synth in the chain stands for its voice and effects; its project effect modules are found by name.
        std::vector<std::string> chain;
        for (const std::string& id : w.chain) {
            auto it = modules_.find(id);
            if (it == modules_.end() || it->second.expand.empty()) {
                chain.push_back(id);
                continue;
            }
            for (const std::string& e : it->second.expand) {
                if (e[0] != '\x1e') {
                    chain.push_back(e);
                    continue;
                }
                const std::string name = e.substr(1);
                std::string found;
                for (const auto& [mid, ms] : modules_)
                    if (mid.find('\x1f') == std::string::npos && (mid == name || ms.ref == refName(name))) found = mid;
                if (found.empty() || !modules_.at(found).program || modules_.at(found).program->kind != ModuleKind::Effect)
                    warnings[id].push_back("fx " + name + ": there is no effect module called '" + name + "' in the project");
                else
                    chain.push_back(found);
            }
        }
        for (const std::string& id : chain) {
            auto it = modules_.find(id);
            if (it == modules_.end() || !it->second.program || it->second.program->kind == ModuleKind::Library) continue;
            pl.ids.push_back(id);
            pl.sig.push_back(it->second.program.get());
            layerStateDoubles += static_cast<uint64_t>(std::max(0, it->second.program->stateSize));
        }
        // Arrangement clips are compiled into an immutable absolute-time event stream here,
        // on the control thread. A layer still uses one voice pool and one instrument/effect chain.
        if (!w.clips.empty() && !pl.ids.empty()) {
            pl.arrangementSig = std::to_string(p.beatsPerBar) + "|" + std::to_string(p.loopSteps()) + "|";
            std::map<std::string, std::shared_ptr<const Pattern>> sources;
            for (const auto& [moduleId, module] : modules_)
                if (module.pattern) sources.emplace(moduleId, module.pattern);
            for (const ClipSpec& clip : w.clips) {
                pl.arrangementSig += clip.id + "|" + clip.pattern + "|" + std::to_string(clip.startSteps) + "|" +
                    std::to_string(clip.lengthSteps) + "|" + std::to_string(clip.sourceOffsetSteps) + "|" +
                    (clip.loop ? "1" : "0") + "|";
                auto source = modules_.find(clip.pattern);
                if (source != modules_.end()) pl.arrangementSig += source->second.source;
                pl.arrangementSig += "\x1e";
            }
            // The expanded clips are project state: refuse them, before building them, past the budget left after
            // the project so far and this layer's chain. Building takes about three times the result (vectors grow
            // by doubling and the sort takes a buffer the size of the events), so that peak must fit too.
            const double expanded = arrangementBytes(w.clips, sources, p.beatsPerBar);
            const double left = static_cast<double>(resourceBudget_.projectStateBytes) -
                static_cast<double>(projectStateBytes) - static_cast<double>(layerStateDoubles) * sizeof(double);
            if (expanded > 0 && 3.0 * expanded > left) {
                warnings[pl.ids.front()].push_back("layer not installed: its arrangement clips expand to about " +
                    std::to_string(static_cast<uint64_t>(std::min(expanded, 1.8e19))) +
                    " bytes of notes, over this Engine's project-state budget of " +
                    std::to_string(resourceBudget_.projectStateBytes) + " bytes");
                allOk = false;
                pl.ids.clear();
                pl.sig.clear();
            } else {
                auto previous = layers_.find(w.id);
                if (previous != layers_.end() && previous->second.arrangementSig == pl.arrangementSig &&
                    previous->second.pattern) {
                    pl.pattern = previous->second.pattern;
                } else {
                    pl.pattern = compileArrangement(w.clips, sources, p.beatsPerBar, p.loopSteps());
                }
                pl.w.steps = 0;  // arrangement follows the project transport, not an individual clip loop
                layerStateDoubles += static_cast<uint64_t>(std::ceil(expanded / sizeof(double)));
                const Program& gen = *modules_.at(pl.ids.front()).program;
                layerStateDoubles += static_cast<uint64_t>(std::clamp(gen.voices, 2, kMaxVoices) - 1) *
                    static_cast<uint64_t>(std::max(0, gen.stateSize));
            }
        } else if (!w.pattern.empty() && !pl.ids.empty()) {
            auto it = modules_.find(w.pattern);
            if (it != modules_.end() && it->second.pattern) {
                pl.pattern = it->second.pattern;
                pl.w.steps = pl.pattern->steps(p.beatsPerBar);
                const Program& gen = *modules_.at(pl.ids.front()).program;
                layerStateDoubles += static_cast<uint64_t>(std::clamp(gen.voices, 2, kMaxVoices) - 1) *
                    static_cast<uint64_t>(std::max(0, gen.stateSize));
            } else {
                warnings[pl.ids.front()].push_back("pattern '" + w.pattern + "' is missing or has an error, so it plays without one");
            }
        }
        if (pl.pattern) {
            for (const NoteExpression& expression : pl.pattern->expressions) {
                pl.expressionCapacity = std::max(pl.expressionCapacity, expression.bend.points.size());
                pl.expressionCapacity = std::max(pl.expressionCapacity, expression.press.points.size());
                pl.expressionCapacity = std::max(pl.expressionCapacity, expression.timbre.points.size());
            }
        }
        // The project-state share comes from the Engine's measured/fallback resource budget.
        const bool stateSizeOverflow = layerStateDoubles > std::numeric_limits<uint64_t>::max() / sizeof(double);
        const uint64_t layerStateBytes = stateSizeOverflow
            ? std::numeric_limits<uint64_t>::max() : layerStateDoubles * sizeof(double);
        const bool overBudget = stateSizeOverflow || projectStateBytes > resourceBudget_.projectStateBytes ||
            layerStateBytes > resourceBudget_.projectStateBytes - projectStateBytes;
        if (!pl.ids.empty() && overBudget) {
            warnings[pl.ids.front()].push_back("layer not installed: estimated module state exceeds this Engine's project-state budget of " +
                std::to_string(resourceBudget_.projectStateBytes) + " bytes");
            allOk = false;
            pl.ids.clear();
            pl.sig.clear();
        }
        if (pl.ids.size() > static_cast<size_t>(kMaxTrackModules)) {
            // Each module runs as its own mix-graph node, and a track has kMaxTrackModules of them.
            warnings[pl.ids.front()].push_back("layer not installed: its chain has " + std::to_string(pl.ids.size()) +
                " modules and a track runs at most " + std::to_string(kMaxTrackModules));
            allOk = false;
            pl.ids.clear();
            pl.sig.clear();
        }
        if (!pl.ids.empty()) projectStateBytes += layerStateBytes;
        auto it = layers_.find(w.id);
        if (it != layers_.end()) {
            pl.ls = it->second;
            layers_.erase(it);
        }
        const bool isAudition = w.id[0] == '\x01';
        if (pl.ids.empty() && !w.bus) {
            if (pl.ls.slot >= 0) {
                Cmd c;
                c.type = Cmd::Remove;
                c.slot = pl.ls.slot;
                if (!send(c)) {
                    allOk = false;
                    warnings[w.id].push_back("audio command queue rejected removal of an invalid layer");
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
            pl.ls.sig.clear();
            pl.ls.wiring.clear();
            pl.ls.chain = nullptr;
            pl.ls.voiced = false;
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

    // Reserve a stable pointer table from the graph-working budget. Individual buffers are
    // allocated only when a project needs them; their addresses never move during Engine life.
    std::vector<size_t> requiredExportsPerSlot(static_cast<size_t>(slotCount), 0);
    size_t maxExportsPerSlot = 0;
    for (const Planned& pl : plan) {
        if (pl.ls.slot < 0 || pl.ls.slot >= slotCount || pl.ids.empty()) continue;
        size_t count = 0;
        for (const std::string& id : pl.ids) {
            auto module = modules_.find(id);
            if (module != modules_.end() && module->second.program)
                count += module->second.program->exports.size();
        }
        requiredExportsPerSlot[static_cast<size_t>(pl.ls.slot)] = count;
        maxExportsPerSlot = std::max(maxExportsPerSlot, count);
    }
    if (maxExportsPerSlot > 0) {
        // Every slot may hold exportPerSlot_ buffers (fixed from the budget at construction); the
        // pointer segment for all current slots is made the first time a project exports.
        const size_t budgetCapacity = exportPerSlot_;
        if (!exportPool_) {
            if (budgetCapacity < maxExportsPerSlot)
                return R"({"ok":false,"error":"project exports exceed the hardware-derived graph working-memory budget"})";
            try {
                auto pool = std::make_unique<ExportPool>();
                pool->capacityPerSlot = budgetCapacity;
                pool->segments.push_back(std::make_unique<std::array<double, kBlock>*[]>(budgetCapacity * static_cast<size_t>(slotCount)));
                pool->buffers.reserve(budgetCapacity * static_cast<size_t>(slotCount));
                for (int slot = 0; slot < slotCount; ++slot) {
                    ctlSlot(slot).exportBuf = pool->segments.back().get() + static_cast<size_t>(slot) * budgetCapacity;
                    ctlSlot(slot).exportCapacity = budgetCapacity;
                }
                exportPool_ = std::move(pool);
            } catch (const std::bad_alloc&) {
                return R"({"ok":false,"error":"unable to allocate the export pointer table within the hardware-derived memory budget"})";
            }
        } else if (maxExportsPerSlot > exportPool_->capacityPerSlot) {
            return R"({"ok":false,"error":"project requires more exports per layer than the hardware-derived stable export pool supports"})";
        }
        try {
            for (int slot = 0; slot < slotCount; ++slot) {
                const size_t required = requiredExportsPerSlot[static_cast<size_t>(slot)];
                for (size_t index = 0; index < required; ++index) {
                    if (ctlSlot(slot).exportBuf[index]) continue;
                    auto buffer = std::make_unique<std::array<double, kBlock>>();
                    buffer->fill(0.0);
                    auto* stable = buffer.get();
                    exportPool_->buffers.push_back(std::move(buffer));
                    ctlSlot(slot).exportBuf[index] = stable;
                }
            }
        } catch (const std::bad_alloc&) {
            return R"({"ok":false,"error":"unable to allocate the required export buffers within the hardware-derived memory budget"})";
        }
    }

    // Pass 2: where each exported value lives. The first layer (in project order) playing a module provides it.
    struct Source {
        int slot;
        size_t module;  // its index in that layer's chain
        const double* buf;
    };
    std::map<std::string, Source> sources;
    for (const Planned& pl : plan) {
        if (pl.w.id[0] == '\x01') continue;
        size_t buf = 0;
        for (size_t k = 0; k < pl.ids.size(); ++k) {
            const ModuleState& m = modules_.at(pl.ids[k]);
            for (const ExportDef& e : m.program->exports) {
                sources.emplace(m.ref + "." + e.name, Source{pl.ls.slot, k, ctlSlot(pl.ls.slot).exportBuf[buf]->data()});
                ++buf;
            }
        }
    }

    // Pass 3: wire imports, install changed chains, and order layers so exporters run before their readers.
    std::vector<int> projectOrder;
    for (Planned& pl : plan) {
        std::vector<const double*> wiring;
        for (size_t k = 0; k < pl.ids.size(); ++k) {
            const std::string& id = pl.ids[k];
            for (const std::string& imp : modules_.at(id).program->imports) {
                auto src = sources.find(imp);
                if (src == sources.end()) {
                    wiring.push_back(nullptr);
                    warnings[id].push_back("nothing exports '" + imp + "' (it reads 0)");
                } else if (src->second.slot == pl.ls.slot && src->second.module >= k) {
                    // Each module is a graph node, run in chain order: a later module (or this one)
                    // has not run yet this chunk, so the value would lag by however chunks split.
                    wiring.push_back(nullptr);
                    warnings[id].push_back("'" + imp + "' comes from a later module in this layer's chain (it reads 0)");
                } else {
                    wiring.push_back(src->second.buf);
                    if (src->second.slot != pl.ls.slot) readsFrom[pl.ls.slot].push_back(src->second.slot);
                }
            }
        }
        LayerState& ls = pl.ls;
        const Want& w = pl.w;
        ls.arrangementSig = pl.arrangementSig;
        for (const ProjectAutomationLaneSpec& lane : p.automation) {
            pl.parameterAutomationSig += lane.targetType + "|" + lane.moduleId + "|" + lane.target + "|";
            for (const AutomationPointSpec& point : lane.points)
                pl.parameterAutomationSig += std::to_string(point.step) + ":" + std::to_string(point.value) + ";";
        }
        const bool parameterAutomationChanged = ls.parameterAutomationSig != pl.parameterAutomationSig;
        for (const AutomationLaneSpec& lane : w.automation) {
            pl.automationSig += lane.target + "|";
            for (const AutomationPointSpec& point : lane.points)
                pl.automationSig += std::to_string(point.step) + ":" + std::to_string(point.value) + ";";
        }
        const bool voiced = pl.pattern != nullptr;
        if (w.vol != ls.volume || w.pan != ls.pan || w.mute != ls.mute || w.solo != ls.solo) {
            writeMix(ls.slot, w.vol, w.pan, w.mute, w.solo);
            ls.volume = w.vol;
            ls.pan = w.pan;
            ls.mute = w.mute;
            ls.solo = w.solo;
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
            ls.bus = true;
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
            ls.chain = nullptr;
            ls.sig.clear();
            ls.wiring.clear();
            ls.pattern.reset();
            ls.voiced = false;
            ls.expressionCapacity = 0;
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
        if (pl.sig != ls.sig || wiring != ls.wiring || voiced != ls.voiced || parameterAutomationChanged ||
            pl.expressionCapacity != ls.expressionCapacity) {
            Chain* c = buildChain(pl.ids, wiring, voiced, ls.chain, projectAutomation, pl.expressionCapacity);
            Cmd cmd;
            cmd.type = Cmd::Install;
            cmd.slot = ls.slot;
            cmd.chain = c;
            cmd.steps = w.steps;
            cmd.order = w.order;
            if (!send(cmd)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected the prepared module chain");
                nextLayers[w.id] = ls;
                continue;
            }
            ls.chain = c;
            ls.voiced = voiced;
            ls.expressionCapacity = pl.expressionCapacity;
            ls.sig = pl.sig;
            ls.wiring = std::move(wiring);
            ls.steps = w.steps;
        } else {
            writeParams(*ls.chain);
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
            if (!send(cmd)) {
                allOk = false;
                warnings[w.id].push_back("audio command queue rejected pattern update");
                nextLayers[w.id] = ls;
                continue;
            }
            ls.pattern = pl.pattern;
        }
        ls.parameterAutomationSig = pl.parameterAutomationSig;
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

    // Dependency order: repeatedly take the first layer (in project order) whose sources are all placed. Layers
    // in a loop are placed last in project order; one side of the loop then hears the other a block late.
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
        for (int slot : projectOrder) {
            if (placed[slot]) continue;
            orderList->push_back(slot);
            // Cycles are kept playable with the existing bounded one-block feedback behavior. Surface that
            // behavior in the owning module's diagnostics instead of silently accepting a delayed connection.
            for (const Planned& pl : plan) {
                if (pl.ls.slot != slot || pl.ids.empty()) continue;
                for (const std::string& id : pl.ids) {
                    warnings[id].push_back(
                        "signal dependency cycle (or a route blocked by one): at least one source is read from the previous block");
                }
                break;
            }
        }
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

    Cmd masterChainCommand;
    masterChainCommand.type = Cmd::SetMasterChain;
    masterChainCommand.masterChain = nextMasterChain.release();
    if (!send(masterChainCommand)) {
        allOk = false;
        warnings["project"].push_back("audio command queue rejected native master-chain update");
    }

    std::string mods;
    for (const ModuleSpec& m : p.modules) {
        const ModuleState& st = modules_.at(m.id);
        if (!mods.empty()) mods += ",";
        mods += "\"" + jsonEscape(m.id) + "\":{\"ok\":" + (st.error.empty() ? "true" : "false") + ",\"ref\":\"" +
                jsonEscape(st.ref) + "\"";
        if (!st.error.empty())
            mods += ",\"error\":\"" + jsonEscape(st.error) + "\",\"line\":" + std::to_string(st.line) +
                    ",\"col\":" + std::to_string(st.col);
        if (st.program) mods += "," + describeProgram(*st.program);
        else if (st.pattern) mods += "," + describePattern(*st.pattern);
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

void Engine::setParam(const std::string& moduleId, const std::string& name, double value) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = modules_.find(moduleId);
    if (it == modules_.end()) return;
    it->second.params[name] = value;
    // A synth's params reach its generated effect modules too.
    std::vector<std::string> ids{moduleId};
    for (const std::string& e : it->second.expand)
        if (e != moduleId && e[0] != '\x1e') {
            modules_.at(e).params[name] = value;
            ids.push_back(e);
        }
    for (const std::string& id : ids) touchedParams_.insert({id, name});
    for (auto& [id, ls] : layers_)
        if (ls.chain)
            for (const std::string& m : ls.chain->moduleIds)
                if (std::find(ids.begin(), ids.end(), m) != ids.end()) {
                    writeParams(*ls.chain);
                    markTouched(*ls.chain, &ids, name);
                    break;
                }
}

void Engine::markTouched(Chain& c, const std::vector<std::string>* ids, const std::string& name) {
    // After writeParams stored the held values, so the audio thread reads the new value with the stamp.
    // One engine-wide stamp per knob move, so a Play can tell moves made before it from later ones.
    ++touchCounter_;
    for (size_t i = 0; i < c.main.size(); ++i) {
        if (ids && std::find(ids->begin(), ids->end(), c.moduleIds[i]) == ids->end()) continue;
        const Program& p = c.main[i]->program();
        for (size_t k = 0; k < p.params.size(); ++k)
            if (p.params[k].name == name && p.params[k].global == (ids == nullptr))
                c.touchSerials[i][k].store(touchCounter_, std::memory_order_release);
    }
}

void Engine::setGlobal(const std::string& name, double value) {
    std::lock_guard<std::mutex> lock(ctl_);
    globals_[name] = value;
    touchedGlobals_.insert(name);
    for (auto& [id, ls] : layers_)
        if (ls.chain) {
            writeParams(*ls.chain);
            markTouched(*ls.chain, nullptr, name);
        }
}

void Engine::setLayerMix(const std::string& layerId, double volume, double pan, bool mute, bool solo) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0) return;
    LayerState& ls = it->second;
    ls.volume = std::min(1.0, std::max(0.0, volume));
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

void Engine::setMaster(double volume) {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::SetMaster;
    c.master = std::isfinite(volume) ? std::clamp(volume, 0.0, 1.0) : 0.0;
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
    touchedParams_.clear();  // a (re)start ends every touch; chains do the same at their next chunk
    touchedGlobals_.clear();
}

void Engine::stop() {
    std::lock_guard<std::mutex> lock(ctl_);
    Cmd c;
    c.type = Cmd::Stop;
    send(c);
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
    out.peak = s.peak.exchange(0, std::memory_order_relaxed);
    out.progress = s.progress.load(std::memory_order_relaxed);
    out.overloaded = s.overloadFlag.load(std::memory_order_relaxed);
    return true;
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
}

bool Engine::canRetire(size_t count) const noexcept {
    // The callback may use the queue plus its preallocated overflow list. When
    // overflow is already in use, retire() appends there until the control thread
    // drains the queue and a later callback can move the pending entries across.
    const size_t pendingFree = static_cast<size_t>(pendingMax_ - pendingCount_);
    if (pendingCount_ != 0) return count <= pendingFree;
    return count <= retired_->writable() + pendingFree;
}

void Engine::retire(Chain* c, Slot* freed, std::shared_ptr<const Pattern>* pattern,
                    AutomationData* automation, std::vector<int>* order, SlotTable* table,
                    MasterChain* masterChain) noexcept {
    if (!c && !freed && !pattern && !automation && !order && !table && !masterChain) return;
    Retired r{c, freed, pattern, automation, order, table, masterChain};
    if (pendingCount_ == 0 && retired_->push(r)) return;
    if (pendingCount_ < pendingMax_) pending_[pendingCount_++] = r;
    // All callers reserve queue capacity before changing ownership. This is a
    // defensive fallback; command processing is paused while pending is non-empty.
}

void Engine::swapIn(Slot& s, Chain* c) noexcept {
    retire(s.old, nullptr);
    s.old = s.cur;
    s.cur = c;
    s.swapLeft = static_cast<int>(kSwapSeconds * sr_);
    s.seamLeft = 0;
    Chain& from = *s.old;
    Chain& to = *s.cur;
    // Unchanged calls keep their running state (phase, envelopes, delay lines), as planned in buildChain.
    bool voicesTaken = false;
    for (size_t i = 0; i < to.migrate.size(); ++i) {
        const Chain::Migration& m = to.migrate[i];
        if (m.from < 0 || static_cast<size_t>(m.from) >= from.main.size()) continue;
        if (&from.main[static_cast<size_t>(m.from)]->program() != m.expect) continue;  // planned against other code
        const bool gen = i == 0 && m.from == 0;
        if (gen && to.voiced != from.voiced) continue;
        if (gen && to.voiced) {
            // Voices past the new count end here, smoothed over like a stolen voice.
            for (int v = to.voiceCount; v < from.voiceCount; ++v)
                if (from.voices[v].active) to.declick += from.voices[v].lastY;
            for (int v = 0; v < std::min(to.voiceCount, from.voiceCount); ++v) {
                Instance* inst = to.voices[v].inst;
                to.voices[v] = from.voices[v];
                to.voices[v].inst = inst;
                for (const auto& [a, b, n] : m.ranges) inst->copyStateRange(*from.voices[v].inst, a, b, n);
            }
            to.noteCount = from.noteCount;
            to.declick += from.declick;
            voicesTaken = true;
        } else {
            for (const auto& [a, b, n] : m.ranges)
                to.main[i]->copyStateRange(*from.main[static_cast<size_t>(m.from)], a, b, n);
        }
    }
    // A pattern layer whose generator changed too much to take over: held notes start again in the new code.
    if (!voicesTaken && from.voiced && to.voiced)
        for (int v = 0; v < std::min(to.voiceCount, from.voiceCount); ++v) {
            const Voice& f = from.voices[v];
            Voice& t = to.voices[v];
            if (!f.active || !f.gate) continue;
            Instance* inst = t.inst;
            t = f;
            t.inst = inst;
            inst->reset();
            t.trig = true;
            t.started = ++to.noteCount;
            t.since = t.rel = t.quiet = 0;
            t.exStart = 0;
            t.exLeft = 0;
            t.tacc = t.phase = t.lastY = 0;
        }
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
            case Cmd::Install: retirementNeed = 2; break;
            case Cmd::SetAutomation:
            case Cmd::SetMasterChain:
            case Cmd::SetPattern:
            case Cmd::Remove:
            case Cmd::SetOrder:
            case Cmd::Grow: retirementNeed = 1; break;
            case Cmd::ConfigureBus: retirementNeed = c.flag ? 4 : 3; break;
            // Every slot may retire its current and old chain. The pending overflow holds that at
            // maxLayers() (pendingMax_), so with the queue drained a Play always finds room.
            case Cmd::Play: retirementNeed = static_cast<size_t>(2 * slotCount_); break;
            default: break;
        }
        if (!canRetire(retirementNeed) || !cmds_->pop(c)) break;
        routingDirty_ = true;  // any command may change slots, buses or order
        switch (c.type) {
            case Cmd::Install: {
                Slot& s = slotAt(c.slot);
                s.exportCount = std::max(s.exportCount, c.chain ? c.chain->exportCount : size_t{0});
                s.steps = c.steps;
                s.order = c.order;
                if (!s.active || s.removing || !s.cur) {
                    retire(s.cur, nullptr);
                    retire(s.old, nullptr);
                    s.cur = c.chain;
                    s.old = nullptr;
                    s.swapLeft = 0;
                    s.seamLeft = 0;
                    s.peak.store(0, std::memory_order_relaxed);  // a reused slot doesn't show its last owner's level
                    s.active = true;
                    s.removing = false;
                    s.fresh = true;
                    s.contiguous = false;
                    s.overloaded = false;
                    s.bus = false;
                    s.overloadFlag.store(false, std::memory_order_relaxed);
                    s.k = -1;
                    s.epoch = -1;
                    updateSolo();
                    const double initialTarget = slotTarget(s);
                    s.gain = initialTarget > 0.0 && s.automation && !s.automation->volume.empty() ? s.automation->volume.front().value : initialTarget;
                } else if (swapMode_ > 0 && playing_ && stopFade_ == 0) {
                    // Wait for the next beat or bar; newer code replaces code still waiting.
                    retire(s.pending, nullptr);
                    s.pending = c.chain;
                } else {
                    retire(s.pending, nullptr);
                    s.pending = nullptr;
                    swapIn(s, c.chain);
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
                retire(nullptr, nullptr, nullptr, s.automation);
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
                retire(s.cur, nullptr, s.pattern);
                retire(s.old, nullptr);
                retire(s.pending, nullptr);
                s.cur = s.old = s.pending = nullptr;
                s.pattern = nullptr;
                s.peak.store(0, std::memory_order_relaxed);
                s.active = true;
                s.removing = false;
                s.bus = true;
                if (c.flag) {
                    retire(nullptr, nullptr, nullptr, s.automation);
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
                // A sounding note finishes as the old pattern had it; the edit is heard from its next start.
                if (s.cur && s.cur->voiced) {
                    const Pattern* old = s.pattern ? s.pattern->get() : nullptr;
                    for (Voice& v : s.cur->voices) {
                        if (!v.active || !v.gate || v.note == kOrphanNote || v.preview >= 0) continue;
                        if (!old || v.note >= old->notes.size()) {
                            v.gate = false;
                            v.rel = v.quiet = 0;
                            continue;
                        }
                        const PatternNote& n = old->notes[v.note];
                        const double end = n.at + n.len / n.ratchet * (v.sub + 1);
                        v.offAt = static_cast<int64_t>(std::floor(end * stepLen_ + 0.5));
                        v.note = kOrphanNote;
                    }
                }
                retire(nullptr, nullptr, s.pattern);
                s.pattern = c.pattern;
                break;
            }
            case Cmd::Remove: {
                Slot& s = slotAt(c.slot);
                s.removing = true;
                retire(nullptr, nullptr, nullptr, s.automation);
                s.automation = nullptr;
                break;
            }
            case Cmd::Transport:
                // A tempo change moves every note in time: let held notes go so none is left hanging.
                if (c.bpm != bpm_)
                    for (int i = 0; i < slotCount_; ++i) {
                        if (slotAt(i).cur && slotAt(i).cur->voiced) releaseVoices(slotAt(i).cur->voices, slotAt(i).cur->voiceCount);
                        if (slotAt(i).old && slotAt(i).old->voiced) releaseVoices(slotAt(i).old->voices, slotAt(i).old->voiceCount);
                    }
                bpm_ = c.bpm;
                beatsPerBar_ = c.beatsPerBar;
                loopSteps_ = c.loopSteps;
                seed_ = c.seed;
                master_ = masterTarget_ = c.master;
                masterStep_ = 0.0;
                masterRamp_ = 0;
                seamXf_ = c.seamXf;
                keyRoot_ = c.keyRoot;
                keyScale_ = c.keyScale;
                swapMode_ = c.swapMode;
                voiceLimit_ = c.voices;
                updateTiming();
                if (g_ >= loopLen_) g_ = 0;
                loopLenFlag_.store(loopLen_, std::memory_order_relaxed);
                break;
            case Cmd::SetMaster:
                masterTarget_ = std::isfinite(c.master) ? std::clamp(c.master, 0.0, 1.0) : 0.0;
                masterRamp_ = std::max(1, static_cast<int>(sr_ * kGainSeconds));
                masterStep_ = (masterTarget_ - master_) / masterRamp_;
                break;
            case Cmd::SetMasterChain:
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, masterChain_);
                masterChain_ = c.masterChain;
                break;
            case Cmd::Play:
                playing_ = true;
                touchEpoch_ = c.playCount;  // chains from before this Play drop their touches at their next chunk
                touchPlayStamp_ = c.touchStamp;
                // Resuming starts mid-loop: each track works out its own loop pass from g_ at its next chunk. Code
                // there may be far from zero, and a Play during a stop fade cuts it short, so both fade in.
                // In steps, converted with the tempo the Transport commands before it set, so a tempo change made
                // while paused still resumes on the same beat.
                {
                    const double at = std::isfinite(c.fromStep) && c.fromStep > 0 ? std::floor(c.fromStep * stepLen_ + 0.5) : 0.0;
                    g_ = at > 0 && at < static_cast<double>(loopLen_) ? static_cast<int64_t>(at) : 0;
                }
                playRampIn_ = g_ > 0 || stopFade_ > 0 ? std::max(1, static_cast<int>(kStopSeconds * sr_)) : 0;
                stopFade_ = 0;
                epoch_ = 0;
                dcL_[0] = dcL_[1] = dcR_[0] = dcR_[1] = 0;
                limEnv_ = 0;
                for (int i = 0; i < slotCount_; ++i) {
                    Slot& s = slotAt(i);
                    if (!s.active) continue;
                    retire(s.old, nullptr);
                    s.old = nullptr;
                    if (s.pending) {
                        retire(s.cur, nullptr);
                        s.cur = s.pending;
                        s.pending = nullptr;
                    }
                    s.swapLeft = 0;
                    s.seamLeft = 0;
                    if (s.cur) restartChain(*s.cur);  // a held preview plays on into playback
                    s.fresh = true;
                    s.contiguous = false;
                    s.k = -1;
                    s.epoch = -1;
                    updateSolo();
                    const double target = slotTarget(s);
                    s.gain = target > 0.0
                        ? (s.automation ? automationValue(s.automation->volume, 0.0, target) : target)
                        : 0.0;
                }
                break;
            case Cmd::Stop:
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
                retire(nullptr, nullptr, nullptr, nullptr, c.orderList);  // freed on the control thread
                break;
            case Cmd::Grow: {
                // A larger table from the control thread: the same Slot objects for every layer
                // slot (same addresses, same indices) plus new idle ones, and the audition moved to
                // the new last index. No slot state changes, so nothing is heard; routing is
                // re-derived (routingDirty_) before the next chunk runs the new graph.
                SlotTable& t = *c.table;
                for (int k = 0; k < processCount_; ++k)
                    t.processOrder[k] = processOrder_[k] == auditionSlot_ ? t.capacity : processOrder_[k];
                t.slots[t.capacity]->index = t.capacity;
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, table_.release());  // freed on the control thread
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
    for (int i = 0; i < capacity_ && !any; ++i)
        any = slotAt(i).active && !slotAt(i).removing && slotAt(i).solo.load(std::memory_order_relaxed);
    anySolo_ = any;
}

int64_t Engine::loopStart(const Slot& s, int64_t k) const noexcept {
    return static_cast<int64_t>(std::floor(static_cast<double>(k) * (s.steps * stepLen_) + 0.5));
}

// A lane's time variables for this chunk: worked out once, by the track's first module node.
void Engine::prepareLane(Chain& c, int lane, int64_t n0, int len) noexcept {
    Chain::Lane& L = c.lanes[lane];
    const uint32_t u = c.used;
    auto uses = [u](Var v) { return (u >> static_cast<int>(v)) & 1u; };
    for (int i = 0; i < len; ++i) L.nb[i] = static_cast<double>(n0 + i);
    if (uses(Var::Step) || uses(Var::Beat) || uses(Var::Bar)) {
        for (int i = 0; i < len; ++i) {
            const double st = std::floor(L.nb[i] / stepLen_);
            L.stepb[i] = st;
            L.beatb[i] = std::floor(st / 4.0);
            L.barb[i] = std::floor(L.beatb[i] / beatsPerBar_);
        }
    }
    if (uses(Var::Pos) || uses(Var::Phase)) {
        // pos counts through this layer's loop; layers that follow the project count through the project loop.
        for (int i = 0; i < len; ++i) L.posb[i] = L.nb[i] / c.layerLen;
    }
    if (uses(Var::Time))
        for (int i = 0; i < len; ++i) L.timeb[i] = L.nb[i] / sr_;
    std::fill_n(L.srb, len, sr_);
    std::fill_n(L.bpmb, len, bpm_);
    std::fill_n(L.seedb, len, static_cast<double>(seed_));
    // Without a pattern, the note variables describe one note held through the layer's loop (C4, full velocity).
    if (uses(Var::Trig))
        for (int i = 0; i < len; ++i) L.dtrig[i] = L.nb[i] == 0.0 ? 1.0 : 0.0;
}

// Resolves module idx's params for one chunk into c.paramValuePtrs (null: the VM reads the held
// value, which is then exactly the resolved one). Bounded by params x len; no allocation.
void Engine::resolveParams(Chain& c, const Instance& inst, size_t idx, int64_t globalStart, int len) noexcept {
    if (c.touchEpoch != touchEpoch_) {
        // Playback (re)started: touches end, and knob moves made before it (while stopped) are
        // taken as plain values, so the lanes rule again. A move stamped after the Play stays
        // unseen, so it becomes a touch below.
        for (size_t m = 0; m < c.paramSlots.size(); ++m)
            for (size_t k = 0; k < c.paramSlots[m].size(); ++k) {
                c.paramSlots[m][k].resolver.clearTouch();
                const uint32_t stamp = c.touchSerials[m][k].load(std::memory_order_acquire);
                if (static_cast<int32_t>(stamp - touchPlayStamp_) <= 0) c.paramSlots[m][k].seenSerial = stamp;
            }
        c.touchEpoch = touchEpoch_;
    }
    std::vector<Chain::ParamSlot>& slots = c.paramSlots[idx];
    for (size_t k = 0; k < slots.size(); ++k) {
        Chain::ParamSlot& slot = slots[k];
        if (!slot.active) continue;
        // The serial first: a knob move stores the held value before bumping it.
        const uint32_t serial = c.touchSerials[idx][k].load(std::memory_order_acquire);
        const double held = inst.param(static_cast<int>(k));
        const uint64_t bits = std::bit_cast<uint64_t>(held);
        if (serial != slot.seenSerial) {  // a knob move: the manual base, a touch over a lane
            slot.seenSerial = serial;
            slot.heldBits = bits;
            slot.resolver.setBase(held);
            slot.passThrough = false;
        } else if (bits != slot.heldBits) {  // a restore (project update): the value, no touch
            slot.heldBits = bits;
            slot.resolver.setInitial(held);
            slot.passThrough = false;
        } else if (slot.passThrough) {
            continue;  // the common case: the VM reads the held value, which is the resolved one
        }
        const double* automation = nullptr;
        if (slot.lane) {
            // The Engine's lane position; the resolver clamps and steps it like any base.
            const auto& points = slot.lane->points;
            for (int sample = 0; sample < len; ++sample)
                c.laneScratch[static_cast<size_t>(sample)] =
                    automationValue(points, static_cast<double>(globalStart + sample) / stepLen_, points.front().value);
            automation = c.laneScratch.data();
        }
        double* out = c.paramSamples[k].data();
        const ParameterValue value = slot.resolver.resolve(static_cast<uint32_t>(len), automation, nullptr, out);
        if (value.samples) {
            c.paramValuePtrs[k] = value.samples;
        } else if (std::bit_cast<uint64_t>(value.value) != bits) {  // e.g. a held value off the step grid
            std::fill_n(out, len, value.value);
            c.paramValuePtrs[k] = out;
        } else {
            slot.passThrough = !slot.lane;  // .caw params never ramp, so this holds until the value changes
        }
    }
}

// Module idx of a chain over one chunk of a lane (prepared by prepareLane); returns its output.
const double* Engine::runModule(Chain& c, int lane, bool shadow, size_t idx, int64_t n0, int64_t globalStart, int len,
                                const double* input, Slot* exportTo, const Pattern* pat, int64_t repeat) noexcept {
    Chain::Lane& L = c.lanes[lane];
    auto& inst = (shadow ? c.shadow : c.main)[idx];
    BlockCtx ctx;
    ctx.n = len;
    ctx.sr = sr_;
    ctx.bpm = bpm_;
    ctx.seed = seed_;
    ctx.keyRoot = keyRoot_;
    ctx.keyScale = keyScale_;
    const bool trig = ((c.used >> static_cast<int>(Var::Trig)) & 1u) != 0;
    ctx.vars[static_cast<int>(Var::Sr)] = L.srb;
    ctx.vars[static_cast<int>(Var::Bpm)] = L.bpmb;
    ctx.vars[static_cast<int>(Var::Seed)] = L.seedb;
    ctx.vars[static_cast<int>(Var::Step)] = L.stepb;
    ctx.vars[static_cast<int>(Var::Beat)] = L.beatb;
    ctx.vars[static_cast<int>(Var::Bar)] = L.barb;
    ctx.vars[static_cast<int>(Var::Pos)] = L.posb;
    ctx.vars[static_cast<int>(Var::Phase)] = L.posb;
    ctx.vars[static_cast<int>(Var::Time)] = L.timeb;
    ctx.vars[static_cast<int>(Var::Trig)] = trig ? L.dtrig : c.zero;
    ctx.vars[static_cast<int>(Var::Gate)] = c.ones;
    ctx.vars[static_cast<int>(Var::Note)] = c.dnote;
    ctx.vars[static_cast<int>(Var::Freq)] = c.dfreq;
    ctx.vars[static_cast<int>(Var::Vel)] = c.ones;
    ctx.vars[static_cast<int>(Var::Rel)] = c.zero;
    ctx.vars[static_cast<int>(Var::Bend)] = c.zero;
    ctx.vars[static_cast<int>(Var::Press)] = c.ones;
    ctx.vars[static_cast<int>(Var::Timbre)] = c.zero;
    ctx.importOffset = 0;  // a chunk is one segment: exports and imports start at the chunk
    std::fill(c.paramValuePtrs.begin(), c.paramValuePtrs.end(), nullptr);
    ctx.paramValues = c.paramValuePtrs.data();
    ctx.paramValueCount = static_cast<uint32_t>(c.paramValuePtrs.size());
    resolveParams(c, *inst, idx, globalStart, len);
    if (idx == 0 && c.voiced) {
        runVoices(c, pat, repeat, n0, len, c.gen, exportTo, 0, ctx);
        return c.gen;
    }
    ctx.imports = c.importPtrs[idx].empty() ? nullptr : c.importPtrs[idx].data();
    const Program& p = inst->program();
    if (p.mode == OutputMode::Byte) {
        const double ratio = p.rate / sr_;
        for (int i = 0; i < len; ++i) c.tb[i] = std::floor(L.nb[i] * ratio);
        std::fill_n(c.rateb, len, p.rate);
    } else {
        std::copy_n(L.nb, len, c.tb);
        std::fill_n(c.rateb, len, sr_);
    }
    ctx.vars[static_cast<int>(Var::T)] = c.tb;
    ctx.vars[static_cast<int>(Var::Rate)] = c.rateb;
    ctx.vars[static_cast<int>(Var::In)] = input;
    const double* y = inst->process(ctx);
    if (exportTo && exportTo->exportBuf)
        for (const auto& [reg, buf] : c.exportMap[idx])
            if (buf < exportTo->exportCapacity && exportTo->exportBuf[buf])
                std::copy_n(inst->reg(reg), len, exportTo->exportBuf[buf]->data());
    return y;
}

// A note taking a voice brings its own expression; its curves run over the note's (or ratchet repeat's) length.
void Engine::takeExpression(Voice& v, const Pattern& pat, const PatternNote& n) noexcept {
    v.expressive = n.extra >= 0 && static_cast<size_t>(n.extra) < pat.expressions.size();
    if (!v.expressive) return;
    v.ex = pat.expressions[static_cast<size_t>(n.extra)];
    v.exStart = v.since;
    v.exLen = std::max(1.0, n.len / std::max(1, n.ratchet) * stepLen_);
    v.exLeft = 0;  // work out the first control point on the next sample
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
Voice& Engine::pickVoice(Chain& c) noexcept {
    Voice* pick = nullptr;
    // Only the project's first `voices` voices take new notes (light mode plays fewer).
    const int limit = std::min(voiceLimit_, c.voiceTake);  // voices: 1 is mono: each note steals the one voice
    for (int i = 0; i < limit; ++i)
        if (!c.voices[i].active) {
            pick = &c.voices[i];
            break;
        }
    for (int pass = 0; pass < 2 && !pick; ++pass)
        for (int i = 0; i < limit; ++i) {
            Voice& v = c.voices[i];
            if ((pass == 1 || !v.gate) && (!pick || v.started < pick->started)) pick = &v;
        }
    Voice& v = *pick;
    if (v.active) c.declick += v.lastY;  // stealing a sounding voice: smooth over the jump
    v.lastY = 0;
    return v;
}

// Play and the end of a stop start a chain from silence: its instances reset and its pattern voices end. A held
// preview keeps its voice and its instrument's state (voice 0's instrument is main[0]), so it sounds on unbroken.
void Engine::restartChain(Chain& c) noexcept {
    const bool keep0 = c.voiced && c.voices[0].active && c.voices[0].preview >= 0;
    for (size_t i = keep0 ? 1 : 0; i < c.main.size(); ++i) c.main[i]->reset();
    for (Voice& v : c.voices)
        if (v.preview < 0) v.active = false;
}

// Note previews (#103) on the audio thread: a preview takes a voice like a pattern note, with no expression, and
// holds it until its note off.
void Engine::previewCommand(const Cmd& c) noexcept {
    auto release = [](Voice& v) {
        v.gate = false;
        v.rel = v.quiet = 0;
    };
    if (c.previewOp == 3) {
        for (int i = 0; i < slotCount_; ++i) {
            Slot& s = slotAt(i);
            if (!s.cur || !s.cur->voiced) continue;
            for (Voice& v : s.cur->voices)
                if (v.active && v.gate && v.preview >= 0) release(v);
        }
        return;
    }
    if (c.slot < 0 || c.slot >= slotCount_) return;
    Slot& s = slotAt(c.slot);
    if (!s.active || !s.cur || !s.cur->voiced) return;
    Chain& ch = *s.cur;
    Voice* held = nullptr;
    for (Voice& v : ch.voices)
        if (v.active && v.gate && v.preview == c.previewId) held = &v;
    if (c.previewOp == 1) {
        if (!held) return;
        held->target = c.pitch;
        held->glideLeft = std::max(1, static_cast<int>(std::floor(kPreviewGlideSeconds * sr_ + 0.5)));
        held->glideStep = (held->target - held->pitch) / held->glideLeft;
        return;
    }
    if (held) release(*held);  // an off, or a new note on the same id: the old one ends first
    if (c.previewOp != 0) return;
    Voice& v = pickVoice(ch);
    v.inst->reset();
    v.active = v.gate = v.trig = true;
    v.note = kPreviewNote;
    v.sub = 0;
    v.preview = c.previewId;
    v.started = ++ch.noteCount;
    v.since = v.rel = v.quiet = 0;
    v.pitch = v.target = c.pitch;
    v.glideLeft = 0;
    v.glideStep = 0;
    v.freq = mtof(c.pitch);
    v.vel = c.vel;
    v.tacc = v.phase = 0;
    v.offAt = -1;
    v.expressive = false;
    v.exLeft = 0;
    v.bend = v.timbre = 0;
    v.press = 1;
    s.previewing = true;
    s.previewQuiet = s.previewTail = 0;
    previewing_ = true;
}

// After a callback: which slots still preview. A slot keeps running after its last preview voice ends until its
// output (an effect's tail) has stayed below -80 dB for a moment, so a reverb isn't cut off; a muted or soloed-out
// slot doesn't run, so its previews end at once. Only previewing slots are looked at: no cost when none was played.
void Engine::updatePreviewing(int frames) noexcept {
    bool any = false;
    for (int i = 0; i < slotCount_; ++i) {
        Slot& s = slotAt(i);
        if (!s.previewing) continue;
        const bool silent = !s.active || (slotTarget(s) == 0.0 && s.gain == 0.0);
        bool voices = false;
        if (s.cur && s.cur->voiced)
            for (Voice& v : s.cur->voices) {
                if (!v.active || v.preview < 0) continue;
                if (silent) v.active = false;
                else voices = true;
            }
        s.previewTail = voices ? 0 : s.previewTail + frames;
        const bool live = voices || (!silent && s.cur && s.cur->voiced && s.previewQuiet < static_cast<int64_t>(kPreviewQuietSeconds * sr_) &&
                                     s.previewTail < static_cast<int64_t>(kPreviewTailSeconds * sr_));
        s.previewing = live;
        any = any || live;
    }
    previewing_ = any;
}

// The stop fade has reached silence: pattern notes end and effects start from silence, so a later preview hears
// neither the chord that was playing nor a frozen tail. Held previews keep their voices; the master fades them back
// in. Stopped, a track's time runs on from where it stopped (preview chunks).
void Engine::endPlayback() noexcept {
    for (int i = 0; i < slotCount_; ++i) {
        Slot& s = slotAt(i);
        if (!s.cur) continue;
        restartChain(*s.cur);
        if (s.old) {  // a stop during a code swap: the old chain's fade ends too
            restartChain(*s.old);
            for (Voice& v : s.old->voices) v.active = false;
            s.swapLeft = 0;
        }
        s.previewN = s.lastN + 1;
        s.previewQuiet = 0;
    }
    previewRampIn_ = previewing_ ? std::max(1, static_cast<int>(kStopSeconds * sr_)) : 0;
}

void Engine::noteEvent(Chain& c, const Pattern& pat, const PatternEvent& e, int64_t repeat) noexcept {
    const PatternNote& n = pat.notes[e.note];
    // A note-off just releases whichever voice holds the note; only note-ons ask whether the note plays.
    if (e.on && !notePlays(n, e.note, repeat, seed_)) return;
    if (!e.on) {
        for (Voice& v : c.voices)
            if (v.active && v.gate && v.note == e.note && v.sub == e.sub) {
                v.gate = false;
                v.rel = v.quiet = 0;
                return;
            }
        return;
    }
    // A slide hands the sliding note's voice to this note: no new attack, the pitch glides over half a step.
    if (e.sub == 0 && n.slideFrom >= 0) {
        const PatternNote& from = pat.notes[static_cast<size_t>(n.slideFrom)];
        for (Voice& v : c.voices)
            if (v.active && v.gate && v.note == static_cast<uint32_t>(n.slideFrom) && v.sub == from.ratchet - 1) {
                v.note = e.note;
                v.sub = 0;
                v.vel = n.vel;
                // The glide starts from the pitch being heard, bend included, so a bent note doesn't snap first.
                if (v.expressive) v.pitch += v.bend;
                v.target = n.pitch;
                v.glideLeft = std::max(1, static_cast<int>(std::floor(stepLen_ * 0.5 + 0.5)));
                v.glideStep = (v.target - v.pitch) / v.glideLeft;
                takeExpression(v, pat, n);
                return;
            }
    }
    Voice& v = pickVoice(c);
    v.preview = -1;
    v.inst->reset();
    v.active = v.gate = v.trig = true;
    v.note = e.note;
    v.sub = e.sub;
    v.started = ++c.noteCount;
    v.since = v.rel = v.quiet = 0;
    v.pitch = v.target = n.pitch;
    v.glideLeft = 0;
    v.glideStep = 0;
    v.freq = mtof(n.pitch);
    v.vel = n.vel;
    v.tacc = v.phase = 0;
    v.offAt = -1;
    takeExpression(v, pat, n);
}

void Engine::runVoices(Chain& c, const Pattern* pat, int64_t repeat, int64_t n0, int len, double* out, Slot* exportTo,
                       int offset, const BlockCtx& base) noexcept {
    std::fill_n(out, len, 0.0);
    auto sampleOf = [this](double step) { return static_cast<int64_t>(std::floor(step * stepLen_ + 0.5)); };
    const PatternEvent* ev = pat ? pat->events.data() : nullptr;
    const size_t ne = pat ? pat->events.size() : 0;
    size_t e = static_cast<size_t>(
        std::partition_point(ev, ev + ne, [&](const PatternEvent& x) { return sampleOf(x.step) < n0; }) - ev);
    const Program& prog = c.voices[0].inst->program();
    const bool byteMode = prog.mode == OutputMode::Byte;
    const double tPerHz = prog.rate / sr_ / kC4;  // byte mode: t runs at the formula rate when the note is C4
    std::fill_n(c.rateb, len, byteMode ? prog.rate : sr_);
    const int64_t quietMax = static_cast<int64_t>(kVoiceQuietSeconds * sr_);
    const int64_t relMax = static_cast<int64_t>(kVoiceMaxRelease * sr_);
    // Code that reads gate or rel shapes its own release, and code that reads trig rings on like a one-shot.
    // Anything else (a plain bytebeat, say) would sound forever, so the engine fades it out at note-off.
    const uint32_t uses = prog.usedVars;
    auto reads = [uses](Var v) { return ((uses >> static_cast<int>(v)) & 1u) != 0; };
    const bool engineFade = !reads(Var::Gate) && !reads(Var::Rel) && !reads(Var::Trig);
    const double fadeLen = std::max(1.0, kReleaseFade * sr_);
    const double declickCoef = detExp(-1.0 / (kDeclickSeconds * sr_));
    int64_t pos = n0;
    const int64_t end = n0 + len;
    int splits = 0;
    while (pos < end) {
        while (e < ne && sampleOf(ev[e].step) <= pos) noteEvent(c, *pat, ev[e++], repeat);
        // Notes held over from before a pattern edit end where the old pattern ended them.
        int64_t orphanNext = end;
        for (Voice& v : c.voices) {
            if (!v.active || !v.gate || v.offAt < 0) continue;
            if (v.offAt <= pos) {
                v.gate = false;
                v.rel = v.quiet = 0;
                v.offAt = -1;
            } else {
                orphanNext = std::min(orphanNext, v.offAt);
            }
        }
        // A pattern packed with notes can't split a block into slivers: past kMaxSplits they start together.
        if (++splits >= kMaxSplits)
            while (e < ne && sampleOf(ev[e].step) < end) noteEvent(c, *pat, ev[e++], repeat);
        const int64_t next = std::min(orphanNext, e < ne ? std::min(end, sampleOf(ev[e].step)) : end);
        const int n = static_cast<int>(next - pos), o = static_cast<int>(pos - n0);
        int newest = -1;
        for (int v = 0; v < c.voiceCount; ++v)
            if (c.voices[v].active && (newest < 0 || c.voices[v].started > c.voices[newest].started)) newest = v;
        if (exportTo && exportTo->exportBuf)
            for (const auto& [reg, buf] : c.exportMap[0])
                if (buf < exportTo->exportCapacity && exportTo->exportBuf[buf])
                    std::fill_n(exportTo->exportBuf[buf]->data() + offset + o, n, 0.0);
        BlockCtx ctx = base;
        ctx.n = n;
        for (int k = 0; k < static_cast<int>(Var::Count); ++k)
            if (ctx.vars[k]) ctx.vars[k] += o;
        ctx.paramValueOffset = o;
        ctx.vars[static_cast<int>(Var::T)] = c.vtb;
        ctx.vars[static_cast<int>(Var::Time)] = c.vtime;
        ctx.vars[static_cast<int>(Var::Phase)] = c.vphase;
        ctx.vars[static_cast<int>(Var::Rate)] = c.rateb + o;
        ctx.vars[static_cast<int>(Var::In)] = c.zero;
        ctx.vars[static_cast<int>(Var::Trig)] = c.vtrig;
        ctx.vars[static_cast<int>(Var::Gate)] = c.vgate;
        ctx.vars[static_cast<int>(Var::Note)] = c.vnote;
        ctx.vars[static_cast<int>(Var::Freq)] = c.vfreq;
        ctx.vars[static_cast<int>(Var::Vel)] = c.vvel;
        ctx.vars[static_cast<int>(Var::Rel)] = c.vrel;
        ctx.vars[static_cast<int>(Var::Bend)] = c.vbend;
        ctx.vars[static_cast<int>(Var::Press)] = c.vpress;
        ctx.vars[static_cast<int>(Var::Timbre)] = c.vtimbre;
        ctx.imports = c.importPtrs[0].empty() ? nullptr : c.importPtrs[0].data();
        ctx.importOffset = offset + o;
        for (int vi = 0; vi < c.voiceCount; ++vi) {
            Voice& v = c.voices[vi];
            if (!v.active) continue;
            for (int i = 0; i < n; ++i) {
                if (v.glideLeft > 0) {
                    v.pitch = --v.glideLeft == 0 ? v.target : v.pitch + v.glideStep;
                    v.freq = mtof(v.pitch);
                }
                c.vtrig[i] = v.trig ? 1.0 : 0.0;
                v.trig = false;
                c.vgate[i] = v.gate ? 1.0 : 0.0;
                // The note's expression: its bend (plus vibrato) moves note and freq; press and timbre are 0..1.
                // Worked out every kExpressionStep samples from the note's start, stepped linearly in between, so
                // it costs little per sample and doesn't depend on how the device splits blocks.
                double bend = 0.0, press = 1.0, timbre = 0.0, freq = v.freq;
                if (v.expressive) {
                    const int64_t into = v.since - v.exStart;
                    if (v.exLeft <= 0) {
                        if (into == 0 || v.freqNow == 0) {
                            expressionAt(v.ex, 0.0, v.exLen, sr_, v.bend, v.press, v.timbre);
                            v.freqNow = mtof(v.pitch + v.bend);
                        }
                        double b, p, t;
                        expressionAt(v.ex, static_cast<double>(into + kExpressionStep), v.exLen, sr_, b, p, t);
                        v.dBend = (b - v.bend) / kExpressionStep;
                        v.dPress = (p - v.press) / kExpressionStep;
                        v.dTimbre = (t - v.timbre) / kExpressionStep;
                        v.dFreq = (mtof(v.pitch + v.glideStep * kExpressionStep + b) - v.freqNow) / kExpressionStep;
                        v.exLeft = kExpressionStep;
                    }
                    bend = v.bend;
                    press = v.press;
                    timbre = v.timbre;
                    freq = v.freqNow;
                    v.bend += v.dBend;
                    v.press += v.dPress;
                    v.timbre += v.dTimbre;
                    v.freqNow += v.dFreq;
                    --v.exLeft;
                }
                c.vnote[i] = v.pitch + bend;
                c.vfreq[i] = freq;
                c.vbend[i] = bend;
                c.vpress[i] = press;
                c.vtimbre[i] = timbre;
                c.vvel[i] = v.vel;
                c.vrel[i] = v.gate ? 0.0 : static_cast<double>(v.rel++);
                c.vtb[i] = byteMode ? std::floor(v.tacc) : static_cast<double>(v.since);
                v.tacc += tPerHz * freq;
                c.vtime[i] = static_cast<double>(v.since++) / sr_;
                c.vphase[i] = v.phase;
                v.phase += freq / sr_;
                v.phase -= std::floor(v.phase);
            }
            const double* y = v.inst->process(ctx);
            const bool autoPress = v.expressive && !v.ex.press.points.empty() && !reads(Var::Press);
            for (int i = 0; i < n; ++i) {
                double s = y[i];
                if (engineFade && !v.gate) s *= std::max(0.0, 1.0 - c.vrel[i] / fadeLen);
                if (autoPress) s *= c.vpress[i];  // code that doesn't read press still gets the note's volume curve
                out[o + i] += s;
                v.lastY = s;
                if (!v.gate) v.quiet = std::fabs(s) < kQuietLevel ? v.quiet + 1 : 0;
            }
            if (exportTo && exportTo->exportBuf && vi == newest)
                for (const auto& [reg, buf] : c.exportMap[0])
                    if (buf < exportTo->exportCapacity && exportTo->exportBuf[buf])
                        std::copy_n(v.inst->reg(reg), n, exportTo->exportBuf[buf]->data() + offset + o);
            if (!v.gate && (v.quiet >= quietMax || v.rel >= relMax || (engineFade && v.rel >= fadeLen))) {
                c.declick += v.lastY;  // ending a voice that is still sounding: smooth over the jump
                v.active = false;
            }
        }
        for (int i = 0; i < n && c.declick != 0.0; ++i) {
            out[o + i] += c.declick;
            c.declick *= declickCoef;
            if (std::fabs(c.declick) < 1e-12) c.declick = 0.0;
        }
        pos = next;
    }
}

// A playing track at the start of a chunk: loop restarts and code swaps happen here, on their
// exact sample, and the chunk is cut short at the next one so a whole chunk is one segment.
void Engine::planTrack(Slot& s, int& m) noexcept {
    const bool free = s.steps <= 0;
    const double layerLen = free ? static_cast<double>(loopLen_) : s.steps * stepLen_;
    const int seamLen = std::max(1, static_cast<int>(kSeamSeconds * sr_));
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
        if (!s.fresh && s.cur && s.cur->voiced) {
            // A pattern layer restarts its pattern: held notes ring out, voices and effects carry on.
            releaseVoices(s.cur->voices, s.cur->voiceCount);
            if (s.old && s.old->voiced) releaseVoices(s.old->voices, s.old->voiceCount);
            else if (s.old)
                for (auto& inst : s.old->main) inst->reset();
            s.seamLeft = 0;
        } else if (!s.fresh) {
            const bool cont = s.contiguous && s.expectG == gg;
            if (seamXf_ && cont && !s.old && s.cur) {
                // The shadow takes over the old pass's state; main is reset just below.
                for (size_t i = 0; i < s.cur->main.size(); ++i) s.cur->shadow[i]->swapState(*s.cur->main[i]);
                s.shadowN = s.lastN + 1;
                s.seamLeft = seamLen;
            } else {
                s.seamLeft = 0;
            }
            if (s.cur)
                for (auto& inst : s.cur->main) inst->reset();
            if (s.old)
                for (auto& inst : s.old->main) inst->reset();
        }
        s.fresh = false;
        s.k = k;
        s.epoch = epoch_;
    }
    m = static_cast<int>(std::min<int64_t>(m, nx - gg));
    // New code waiting for the next beat or bar goes in on that exact sample.
    if (s.pending) {
        const double unit = (swapMode_ == 1 ? 4.0 : 4.0 * beatsPerBar_) * stepLen_;
        int64_t kb = static_cast<int64_t>(std::floor(static_cast<double>(gg) / unit));
        int64_t at = static_cast<int64_t>(std::floor(kb * unit + 0.5));
        if (at < gg) at = static_cast<int64_t>(std::floor(++kb * unit + 0.5));
        if (at == gg || swapMode_ == 0) {
            if (canRetire(1)) {
                swapIn(s, s.pending);
                s.pending = nullptr;
                routingDirty_ = true;  // the fade lane may need more module nodes
            }
        } else {
            m = static_cast<int>(std::min<int64_t>(m, at - gg));
        }
    }
    s.n0 = gg - st;
    s.repeat = free ? epoch_ : k;
    s.cur->layerLen = layerLen;
    if (s.old) s.old->layerLen = layerLen;
    s.pat = s.pattern ? s.pattern->get() : nullptr;
    s.seam = s.seamLeft > 0;
    s.fade = s.old && s.swapLeft > 0;
}

// Decides what each slot does this chunk and returns the chunk's length: maxFrames, cut at the
// next loop boundary or code swap of any playing track.
int Engine::planChunk(int maxFrames) noexcept {
    int m = maxFrames;
    if (previewChunk_) {
        // Stopped, with previews: only the previewing tracks run, with no pattern events and no transport, through
        // their effects, mix, folder buses and master. Swaps and removals wait for playback, as they do while stopped.
        for (int i = 0; i < slotCount_; ++i) {
            Slot& s = slotAt(i);
            if (!s.active || (!s.bus && !s.cur)) { s.mode = Slot::Mode::Idle; continue; }
            if (s.bus) { s.mode = Slot::Mode::Bus; continue; }
            s.target = slotTarget(s);
            if (!s.previewing || !s.cur->voiced || (s.target == 0.0 && s.gain == 0.0)) {
                s.mode = Slot::Mode::Silent;
                continue;
            }
            s.mode = Slot::Mode::Play;
            s.pat = nullptr;
            s.seam = false;
            s.fade = s.old && s.swapLeft > 0;  // a code edit while a preview sounds still crossfades
            // The layer's time runs on through its loop, so time-driven effects keep moving; cut at the wrap.
            const double layerLen = s.steps <= 0 ? static_cast<double>(loopLen_) : s.steps * stepLen_;
            const int64_t len = std::max<int64_t>(1, static_cast<int64_t>(std::floor(layerLen + 0.5)));
            s.cur->layerLen = layerLen;
            if (s.old) s.old->layerLen = layerLen;
            s.previewN = ((s.previewN % len) + len) % len;
            s.n0 = s.previewN;
            m = static_cast<int>(std::min<int64_t>(m, len - s.n0));
        }
        return m;
    }
    for (int i = 0; i < slotCount_; ++i) {
        Slot& s = slotAt(i);
        if (!s.active || (!s.bus && !s.cur)) { s.mode = Slot::Mode::Idle; continue; }
        if (s.bus) { s.mode = Slot::Mode::Bus; continue; }
        s.target = slotTarget(s);
        if (s.target == 0.0 && s.gain == 0.0) {
            // Silent (muted, soloed out or removed, and faded out): nothing runs; swaps and removal finish.
            s.mode = Slot::Mode::Silent;
            s.contiguous = false;
            if (s.pending && canRetire(1)) { swapIn(s, s.pending); s.pending = nullptr; routingDirty_ = true; }
            if (s.removing && canRetire(2)) {
                retire(s.cur, nullptr, s.pattern);
                s.pattern = nullptr;
                retire(s.old, &s);
                s.cur = s.old = nullptr;
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
    for (int i = 0; i < slotCount_; ++i) {
        Slot& slot = slotAt(i);
        if (slot.exportBuf && slot.exportCount > 0 &&
            (!slot.active || !slot.cur || (slotTarget(slot) == 0.0 && slot.gain == 0.0))) {
            for (size_t b = 0; b < slot.exportCount; ++b)
                if (slot.exportBuf[b]) std::fill_n(slot.exportBuf[b]->data(), maxFrames, 0.0);
            if (!slot.active || (!slot.cur && !slot.pending)) slot.exportCount = 0;
        }
    }
    const int m = planChunk(maxFrames);
    if (previewChunk_)
        // Stopped, a track that isn't previewing exports silence, not the last block it played.
        for (int i = 0; i < slotCount_; ++i) {
            Slot& slot = slotAt(i);
            if (slot.mode == Slot::Mode::Play || !slot.exportBuf) continue;
            for (size_t b = 0; b < slot.exportCount; ++b)
                if (slot.exportBuf[b]) std::fill_n(slot.exportBuf[b]->data(), m, 0.0);
        }
    ++chunkId_;
    // One graph runs the mix: each track's modules as a chain of nodes then its track node, in
    // dependency order (exporters before readers), each folder bus after its children, then the
    // master stage. Routing changes only between chunks.
    if (routingDirty_) {
        routingDirty_ = false;
        updateRouting();
    }
    float* outputs[2] = {l, r};
    if (!mixGraph_->executor.process(ConstChannelBufferView{}, ChannelBufferView{outputs, 2, static_cast<uint32_t>(m)},
                                     static_cast<uint32_t>(m))) {
        std::fill_n(l, m, 0.0f);
        std::fill_n(r, m, 0.0f);
    }
    return m;
}

// Routing as the old two-pass mixer did it, now as graph edges: a routable slot (active, and a bus or
// a track with a chain) goes to its parent when that parent is an active folder bus, is dropped when
// its parent is anything else (as the old mixer discarded it), and goes to master at the root. Order
// is the old pass order (processOrder_, then the remaining slots by index) with each bus held back
// until its routed children have run, so a track always reaches its bus in the same chunk (issue
// #76). A track runs as its module nodes (enough for its current chain and the one fading out),
// chained lane by lane into its track node. Edges into buses follow that order, which is the old
// accumulation order. Idle slots are left out of the order, so they cost nothing.
void Engine::updateRouting() noexcept {
    MixGraph& g = *mixGraph_;
    const int master = g.master;
    for (int i = 0; i < slotCount_; ++i) {
        const Slot& s = slotAt(i);
        int to = -1, modules = 0;
        bool routable = s.active && (s.bus || s.cur);
        if (routable && !s.bus) {
            modules = static_cast<int>(s.cur->main.size());
            if (s.old) modules = std::max(modules, static_cast<int>(s.old->main.size()));
            if (modules < 1 || modules > MixGraph::K) {
                // setProject refuses longer chains; one here is a bug, so it is counted, not played cut short.
                routingRejections_.fetch_add(1, std::memory_order_relaxed);
                assert(!"track chain does not fit its module nodes");
                routable = false;
            }
        }
        if (routable) {
            if (s.parentSlot >= 0 && s.parentSlot < capacity_ && s.parentSlot != i) {
                const Slot& parent = slotAt(s.parentSlot);
                to = parent.active && parent.bus ? s.parentSlot : -1;
            } else {
                to = master;
            }
        }
        g.routable[i] = routable;
        g.modules[i] = modules;
        g.target[i] = to;
    }
    for (int n = 0; n <= slotCount_; ++n) { g.pending[n] = 0; g.deferred[n] = false; g.emitted[n] = false; }
    for (int i = 0; i < slotCount_; ++i)
        if (g.target[i] >= 0 && g.target[i] != master) ++g.pending[g.target[i]];
    int count = 0;
    auto emit = [&](int x) noexcept {
        while (x >= 0) {
            g.emitted[x] = true;
            g.slotOrder[count++] = x;
            const int parent = g.target[x];
            x = -1;
            if (parent >= 0 && parent != master && --g.pending[parent] == 0 && g.deferred[parent]) {
                g.deferred[parent] = false;
                x = parent;
            }
        }
    };
    auto visit = [&](int x) noexcept {
        if (x < 0 || x >= slotCount_ || !g.routable[x] || g.emitted[x] || g.deferred[x]) return;
        if (g.pending[x] > 0) { g.deferred[x] = true; return; }
        emit(x);
    };
    for (int k = 0; k < processCount_; ++k) visit(processOrder_[k]);
    for (int k = 0; k < slotCount_; ++k) visit(k);
    // A routing cycle is never sent by the control thread; if one appears, keep everything ordered
    // and drop the edges that would point backwards.
    for (int k = 0; k < slotCount_; ++k)
        if (g.routable[k] && !g.emitted[k]) { g.emitted[k] = true; g.slotOrder[count++] = k; }
    for (int n = 0; n <= slotCount_; ++n) g.position[n] = UINT32_MAX;  // not run this chunk
    for (int k = 0; k < count; ++k) g.position[g.slotOrder[k]] = static_cast<uint32_t>(k);
    g.position[master] = static_cast<uint32_t>(count);
    uint32_t nodeCount = 0, edgeCount = 0;
    for (int k = 0; k < count; ++k) {
        const int x = g.slotOrder[k];
        uint32_t out = g.busNode(x);
        if (!slotAt(x).bus) {
            const int n = g.modules[x];
            for (int i = 0; i < n; ++i) {
                g.order[nodeCount++] = MixGraph::moduleNode(x, i);
                if (i > 0) g.edges[edgeCount++] = GraphConnection{MixGraph::moduleNode(x, i - 1), 1, MixGraph::moduleNode(x, i), 0};
            }
            out = g.trackNode(x);
            g.order[nodeCount++] = out;
            g.edges[edgeCount++] = GraphConnection{MixGraph::moduleNode(x, n - 1), 1, out, 0};
        } else {
            g.order[nodeCount++] = out;
        }
        const int to = g.target[x];
        if (to < 0 || g.position[x] >= g.position[to]) continue;
        g.edges[edgeCount++] = GraphConnection{out, 1, to == master ? g.masterNode() : g.busNode(to), 0};
    }
    g.order[nodeCount++] = g.masterNode();
    // Valid by construction. A rejection would keep the previous routing (safe: stale nodes output
    // zeros) but must never pass unnoticed: it is counted and asserts in debug builds.
    if (!g.executor.setRouting(g.edges.data(), edgeCount, g.order.data(), nodeCount)) {
        routingRejections_.fetch_add(1, std::memory_order_relaxed);
        assert(!"mix graph rejected a derived route");
    }
}

// Module `index` of a playing track, on every lane that runs this chunk. Lanes arrive and leave
// as float (graph edges are 32-bit, owner 2026-11-03); a module past a lane's chain passes it on.
void Engine::runModuleNode(int slot, int index, const float* const* in, float* const* out, int m) noexcept {
    Slot& s = slotAt(slot);
    if (s.mode != Slot::Mode::Play) return;  // the track node outputs silence and reads no lane
    const size_t idx = static_cast<size_t>(index);
    const int64_t gg = g_;
    auto lane = [&](Chain& c, int l, bool shadow, int len, int64_t n0, Slot* exportTo, const Pattern* pat,
                    int64_t repeat, int channel) noexcept {
        if (idx >= c.main.size()) {
            std::copy_n(in[channel], len, out[channel]);
            return;
        }
        if (idx == 0) prepareLane(c, l, n0, len);
        const double* x = c.zero;
        if (idx > 0) {
            for (int i = 0; i < len; ++i) c.lanes[l].in[i] = static_cast<double>(in[channel][i]);
            x = c.lanes[l].in;
        }
        const double* y = runModule(c, l, shadow, idx, n0, gg, len, x, exportTo, pat, repeat);
        for (int i = 0; i < len; ++i) out[channel][i] = routeSample(y[i]);
    };
    lane(*s.cur, 0, false, m, s.n0, &s, s.pat, s.repeat, 0);
    if (s.seam) lane(*s.cur, 1, true, std::min(m, s.seamLeft), s.shadowN, nullptr, nullptr, s.k, 1);
    if (s.fade) lane(*s.old, 0, false, m, s.n0, nullptr, nullptr, s.k, 2);
}

// A playing track's output: the seam and swap crossfades of its lanes, then gain and pan.
void Engine::runTrackNode(int slot, const float* const* in, float* outL, float* outR, int m) noexcept {
    Slot& s = slotAt(slot);
    if (s.mode != Slot::Mode::Play) {
        std::fill_n(outL, m, 0.0f);
        std::fill_n(outR, m, 0.0f);
        return;
    }
    const double target = s.target;
    const double gainCoef = 1.0 - detExp(-1.0 / (kGainSeconds * sr_));
    const int seamLen = std::max(1, static_cast<int>(kSeamSeconds * sr_));
    const int swapLen = std::max(1, static_cast<int>(kSwapSeconds * sr_));
    const double pan = bitsToDouble(s.pan.load(std::memory_order_relaxed));
    if ((!s.automation || s.automation->pan.empty()) && pan != s.panCache) {
        s.panCache = pan;
        const double th = (pan + 1.0) * (kPi / 4.0);
        s.gl = detCos(th);
        s.gr = detSin(th);
    }
    double* y = tmp_;
    for (int i = 0; i < m; ++i) y[i] = static_cast<double>(in[0][i]);
    if (s.seam) {
        const int sl = std::min(m, s.seamLeft);
        for (int i = 0; i < sl; ++i) {
            const double w = static_cast<double>(seamLen - s.seamLeft + i + 1) / (seamLen + 1);
            y[i] = static_cast<double>(in[1][i]) * (1.0 - w) + y[i] * w;
        }
        s.shadowN += sl;
        s.seamLeft -= sl;
    }
    if (s.fade) {
        const int sl = std::min(m, s.swapLeft);
        for (int i = 0; i < m; ++i) {
            double w = 1.0;
            if (i < sl) w = static_cast<double>(swapLen - s.swapLeft + i + 1) / (swapLen + 1);
            y[i] = static_cast<double>(in[2][i]) * (1.0 - w) + y[i] * w;
        }
        s.swapLeft -= sl;
    }
    if (s.old && s.swapLeft <= 0 && canRetire(1)) {
        retire(s.old, nullptr);
        s.old = nullptr;
        routingDirty_ = true;  // the fade lane's extra module nodes stop running
    }
    float peak = 0, sig = 0;
    int sp = s.scopePos.load(std::memory_order_relaxed);
    for (int i = 0; i < m; ++i) {
        const double step = static_cast<double>(g_ + i) / stepLen_;
        const bool volumeAutomated = s.automation && !s.automation->volume.empty();
        const double desired = target > 0.0
            ? (volumeAutomated ? automationValue(s.automation->volume, step, target) : target) : 0.0;
        if (volumeAutomated) {
            // The interpolated automation curve is already continuous; don't add lag on top.
            s.gain = desired;
        } else if (s.gain != desired) {
            s.gain += (desired - s.gain) * gainCoef;
            if (std::fabs(desired - s.gain) < 1e-6) s.gain = desired;
        }
        const double v = finiteOr0(y[i]) * s.gain;
        double gl = s.gl, gr = s.gr;
        if (s.automation && !s.automation->pan.empty()) {
            const double automatedPan = automationValue(s.automation->pan, step, pan);
            const double th = (automatedPan + 1.0) * (kPi / 4.0);
            gl = detCos(th); gr = detSin(th);
        }
        // Graph edges carry 32-bit float (owner, 2026-11-03), saturating at +/-FLT_MAX (route_math.h).
        outL[i] = routeSample(v * gl);
        outR[i] = routeSample(v * gr);
        // The meter reads what the track sends on (after volume and pan), the louder channel's sample peak.
        const float av = std::max(std::fabs(outL[i]), std::fabs(outR[i]));
        if (av > peak) peak = av;
        sig = std::max(sig, static_cast<float>(std::fabs(v)));  // before pan: a preview's tail test, like the scope
        s.scope[sp].store(static_cast<float>(v), std::memory_order_relaxed);
        sp = (sp + 1) % kScopeSize;
    }
    s.scopePos.store(sp, std::memory_order_release);
    storeMax(s.peak, peak);
    s.previewQuiet = sig > kPreviewQuiet ? 0 : s.previewQuiet + m;
    if (previewChunk_) {
        s.previewN += m;  // the transport isn't moving: its place in the loop stays; the preview's time runs on
        return;
    }
    s.lastN = s.n0 + m - 1;
    const int64_t next = g_ + m;
    s.expectG = next >= loopLen_ ? 0 : next;
    s.contiguous = true;
    s.progress.store(static_cast<float>(static_cast<double>(s.n0 + m) / s.cur->layerLen), std::memory_order_relaxed);
}

// A folder bus: its children arrive summed in float on the graph's summing input.
void Engine::runBusNode(int slot, const float* inL, const float* inR, float* outL, float* outR, int m) noexcept {
    Slot& s = slotAt(slot);
    if (s.mode != Slot::Mode::Bus) {
        std::fill_n(outL, m, 0.0f);
        std::fill_n(outR, m, 0.0f);
        return;
    }
    const double target = slotTarget(s);
    for (int j = 0; j < m; ++j) {
        s.outL[j] = inL[j];
        s.outR[j] = inR[j];
    }
    const double pan = bitsToDouble(s.pan.load(std::memory_order_relaxed));
    const double gainCoef = 1.0 - detExp(-1.0 / (kGainSeconds * sr_));
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
        const double automatedPan = s.automation && !s.automation->pan.empty()
            ? automationValue(s.automation->pan, step, pan) : pan;
        const double leftPan = automatedPan > 0.0 ? 1.0 - automatedPan : 1.0;
        const double rightPan = automatedPan < 0.0 ? 1.0 + automatedPan : 1.0;
        s.outL[j] *= s.gain * leftPan;
        s.outR[j] *= s.gain * rightPan;
    }
    if (s.removing && s.gain == 0.0) { s.active = false; s.bus = false; routingDirty_ = true; }
    // Graph edges carry 32-bit float (owner, 2026-11-03), saturating at +/-FLT_MAX (route_math.h).
    float peak = 0;
    for (int j = 0; j < m; ++j) {
        outL[j] = routeSample(s.outL[j]);
        outR[j] = routeSample(s.outR[j]);
        peak = std::max(peak, std::max(std::fabs(outL[j]), std::fabs(outR[j])));
    }
    storeMax(s.peak, peak);  // a folder's meter: its mix after volume and pan
}

void Engine::runMasterNode(const float* inL, const float* inR, float* outL, float* outR, int m) noexcept {
    // Master order: gain/DC block, trusted native stereo effects, safety limiter last.
    const double R = 1.0 - kTwoPi * 5.0 / sr_;
    const double rel = detExp(-1.0 / (0.1 * sr_));
    double fade = 1.0;
    float pl = 0, pr = 0;
    const bool bypass = bypass_.load(std::memory_order_relaxed);
    int sp = masterScopePos_.load(std::memory_order_relaxed);

    // Preallocate two stereo stages on Engine. The callback only writes into these fixed buffers.
    float* stage0L = masterStageL_[0].data();
    float* stage0R = masterStageR_[0].data();
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
        stage0L[i] = static_cast<float>(bypass ? xl : yl);
        stage0R[i] = static_cast<float>(bypass ? xr : yr);
    }

    const float* currentL = stage0L;
    const float* currentR = stage0R;
    if (masterChain_) {
        for (size_t index = 0; index < masterChain_->processors.size(); ++index) {
            ModuleProcessor* processor = masterChain_->processors[index].get();
            const size_t destination = (index & 1u) == 0u ? 1u : 0u;
            float* destinationL = masterStageL_[destination].data();
            float* destinationR = masterStageR_[destination].data();
            std::copy_n(currentL, m, destinationL);
            std::copy_n(currentR, m, destinationR);
            const float* inputChannels[2] = {currentL, currentR};
            float* outputChannels[2] = {destinationL, destinationR};
            const AudioProcessBlock block{
                {inputChannels, 2, static_cast<uint32_t>(m)},
                {outputChannels, 2, static_cast<uint32_t>(m)},
                static_cast<uint32_t>(m),
                sr_,
                nullptr,
                0,
            };
            if (!processor->process(block)) {
                std::copy_n(currentL, m, destinationL);
                std::copy_n(currentR, m, destinationR);
            }
            for (int frame = 0; frame < m; ++frame) {
                destinationL[frame] = static_cast<float>(finiteOr0(static_cast<double>(destinationL[frame])));
                destinationR[frame] = static_cast<float>(finiteOr0(static_cast<double>(destinationR[frame])));
            }
            currentL = destinationL;
            currentR = destinationR;
        }
    }

    // Keep the safety limiter after native code so a component cannot bypass the master ceiling.
    for (int i = 0; i < m; ++i) {
        double yl = currentL[i];
        double yr = currentR[i];
        const double env = std::max(std::fabs(yl), std::fabs(yr));
        limEnv_ = env > limEnv_ ? env : env + (limEnv_ - env) * rel;
        const double gain = bypass ? 1.0 : (limEnv_ > kLimitCeiling ? kLimitCeiling / limEnv_ : 1.0);
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
        }
        const float ol = static_cast<float>(yl * gain * fade);
        const float orr = static_cast<float>(yr * gain * fade);
        outL[i] = ol;
        outR[i] = orr;
        pl = std::max(pl, std::fabs(ol));
        pr = std::max(pr, std::fabs(orr));
        masterScope_[sp].store(0.5f * (ol + orr), std::memory_order_relaxed);
        sp = (sp + 1) % kScopeSize;
    }
    masterScopePos_.store(sp, std::memory_order_release);
    storeMax(peakL_, pl);
    storeMax(peakR_, pr);
}

void Engine::pickOverloadVictim() noexcept {
    int best = -1;
    for (int i = 0; i < slotCount_; ++i) {
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
    if (overloadPending_) {
        overloadPending_ = false;
        pickOverloadVictim();
    }
    int i = 0;
    while (i < frames) {
        if (!playing_) {
            if (!previewing_) {
                std::fill(left + i, left + frames, 0.0f);
                std::fill(right + i, right + frames, 0.0f);
                break;
            }
            // Stopped with previews: they play, the transport stays where it is.
            previewChunk_ = true;
            const int m = processChunk(left + i, right + i, std::min(frames - i, kBlock));
            previewChunk_ = false;
            i += m;
            continue;
        }
        const int maxM = static_cast<int>(std::min<int64_t>({static_cast<int64_t>(frames - i), kBlock, loopLen_ - g_}));
        const int m = processChunk(left + i, right + i, maxM);
        if (stopEnded_) {
            stopEnded_ = false;
            endPlayback();
        }
        g_ += m;
        if (g_ >= loopLen_) {
            g_ = 0;
            ++epoch_;
        }
        i += m;
    }
    if (previewing_) updatePreviewing(frames);
    playingFlag_.store(playing_, std::memory_order_relaxed);
    posFlag_.store(g_, std::memory_order_relaxed);
}

void Engine::reportLoad(double load) noexcept {
    loadAvg_ = 0.9 * loadAvg_ + 0.1 * load;
    cpu_.store(static_cast<float>(loadAvg_), std::memory_order_relaxed);
    if (overCooldown_ > 0) --overCooldown_;
    if (loadAvg_ > 0.85) {
        if (++overCount_ >= 20 && overCooldown_ == 0) {
            overloadPending_ = true;
            overCount_ = 0;
            overCooldown_ = 100;
        }
    } else {
        overCount_ = 0;
    }
}

}  // namespace caw
