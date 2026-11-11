// Mixer implementation: the audio-thread render loop and the control-thread project diffing that feeds it.
#include "engine.h"

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

// A slot's export pointer table: exactly as many entries as the largest chain it has held exports
// (#133). Never resized: a chain that exports more gets a new table by command (SetExports), and the
// audio thread hands the old one back to be freed.
struct Engine::ExportTable {
    size_t capacity = 0;
    std::unique_ptr<std::array<double, kBlock>*[]> entries;
};

// Export buffers and the slots' pointer tables, allocated on the control thread; a buffer never
// moves or is freed while the Engine lives (a slot keeps its buffers for its next layer).
struct Engine::ExportPool {
    std::vector<std::unique_ptr<std::array<double, kBlock>>> buffers;
    std::vector<std::unique_ptr<ExportTable>> tables;  // every table sent and not yet handed back
    size_t entries = 0;  // the entries of those tables
};

// Per-layer audio and meter state. Fields above `vol` belong to the audio thread.
struct Engine::Slot {
    // This slot's place in the slot table: fixed for a layer slot; the audition slot (always the
    // last) gets the new last index from the audio thread when a Grow swaps in a larger table.
    int index = -1;
    bool active = false;
    bool listed = false;     // in Engine::live_, the slots the per-chunk loops visit (audio thread)
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
    ComponentChain* inserts = nullptr;  // native stereo effects after the chain, before volume and pan
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
    float instL[kBlock] = {}, instR[kBlock] = {};  // this chunk's instrument output (module node 0)
    // Play while the instrument still rang out (after Stop): its next few milliseconds, rendered before it was
    // reset and faded to silence, mixed in from the next chunk so the reset doesn't click.
    static constexpr int kPlayTailMax = 512;
    float playTailL[kPlayTailMax] = {}, playTailR[kPlayTailMax] = {};
    int playTailLen = 0, playTailAt = 0;
    bool insertTail = false;   // stopped: the inserts ring out on silence (Mode::Tail) until quiet
    int tailFade = 0;          // > 0: a tail at its cap, still audible, fading out (frames left); -1: faded
    int64_t tailCap = 0;       // ... or for at most this many samples
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
    std::atomic<float> peakL{0}, peakR{0}, progress{0};  // meters: each side's sample peak since the last read
    CorrelationMeter correlation;                         // of what it sends on
    std::atomic<bool> overloadFlag{false};
    std::atomic<float> scope[kScopeSize];
    std::atomic<int> scopePos{0};

    bool ctlBusy = false;  // control thread only: a layer holds this slot, or it is still fading out

    // The slot's export pointer table (in Engine::ExportPool). `exports` is the audio thread's, set only by
    // a SetExports command; `ctlExports` is the control thread's, the newest table it sent. The control
    // thread fills a table's entries before it sends it, so the two threads never share a field (#133).
    ExportTable* exports = nullptr;
    ExportTable* ctlExports = nullptr;
    bool hasExports() const noexcept { return exports != nullptr; }
    std::array<double, kBlock>* exportAt(size_t b) const noexcept {
        return exports && b < exports->capacity ? exports->entries[b] : nullptr;
    }
    size_t exportCount = 0;  // grows to the largest active chain export count; audio-thread owned

    // This chunk's plan (planChunk), read by the slot's graph nodes. Chunks end at every loop
    // boundary and code swap of a playing track, so one plan covers the whole chunk.
    enum class Mode : uint8_t { Idle, Bus, Silent, Play, Tail };  // Tail: only the inserts run, on silence
    Mode mode = Mode::Idle;
    double target = 0;          // mix target (0 while muted or soloed out)
    int64_t n0 = 0, repeat = 0; // sample in the layer's loop, and the pattern repeat
    const Pattern* pat = nullptr;
    bool seam = false;          // the shadow lane finishes the previous pass this chunk
    bool fade = false;          // the replaced chain plays on in the fade lane this chunk
    bool previewing = false;    // audio thread: the chain holds a preview voice, or its sound is still dying away
    DeviceNotes deviceNotes;    // audio thread: the device MIDI channels' bend and pedal (API 13)
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
    bool rebind = false;  // its pattern was edited: it moves onto its note in the new one (`note`) next run
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

// A held note carried across a pattern edit glides from the pitch heard to its new curve over this long.
constexpr double kRebindGlideSeconds = 0.005;
constexpr uint32_t kPreviewNote = 0xFFFFFFFEu;  // a note preview: no pattern event matches it, only its own off

// One layer's modules: the main instances plus shadow copies that play the loop's tail across a seam. A layer
// with a pattern runs its generator as voiceCount voices instead (main[0], shadow[0] and extras), with no seams.
struct Engine::Chain {
    std::vector<std::unique_ptr<Instance>> main, shadow;
    bool voiced = false;
    // A native instrument (the slot's) plays the notes: main holds only the .caw effects after it
    // (perhaps none), and the chain loops as a pattern layer does (no seams, effects carry on).
    bool native = false;
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
    enum Type { Install, SetSteps, SetPattern, Remove, Transport, SetMaster, SetMasterChain, SetInserts, SetInstrument, SetComponentAutomation, SetDelay, SetSends, SetSendLevel, Play, Stop, AuditionOnly, ClearOverload, SetOrder, SetRouting, ConfigureBus, SetAutomation, Grow, Preview, Metronome, ReleaseTouches, SetExports } type = Play;
    std::shared_ptr<const Pattern>* pattern = nullptr;
    // SetOrder: slots in dependency order; SetPattern: for each note of the old pattern, the new note that carries it
    // on, or -1 (matchPatternNotes). Owned; retired by the audio thread.
    std::vector<int>* orderList = nullptr;
    SlotTable* table = nullptr;  // Grow: the larger slot table (owned; the one it replaces is retired)
    ExportTable* exportTable = nullptr;  // SetExports: the slot's new export table (owned by ExportPool)
    int slot = 0;
    Chain* chain = nullptr;
    ComponentChain* masterChain = nullptr;  // SetMasterChain: the master's; SetInserts/SetInstrument: the slot's (owned)
    // SetComponentAutomation: for slot's inserts (its instrument when `flag`), or the master's (slot -1)
    ComponentAutomation* componentAutomation = nullptr;
    DelayLine* delay = nullptr;  // SetDelay: the slot's latency compensation (null: none)
    SendTable* sends = nullptr;  // SetSends: the slot's routes (owned; null: none)
    bool sendMute = false;       // SetSendLevel: route `order` gets level `master`, pre `flag` and this mute
    int steps = 0, order = 0, parentSlot = -1;
    AutomationData* automation = nullptr;
    double bpm = 120, master = 0.7;
    int beatsPerBar = 4, loopSteps = 64, keyRoot = 9, keyScale = 1;
    int loopFromSteps = 0, loopToSteps = 0;  // Transport: the loop range, when loopRange
    bool loopRange = false;
    uint32_t seed = 0;
    bool seamXf = true, flag = false;
    int swapMode = 0;
    int voices = kMaxVoices;
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
    Chain* chain = nullptr;
    Slot* freed = nullptr;  // a slot whose layer has faded out (by object: the audition's index can change)
    std::shared_ptr<const Pattern>* pattern = nullptr;
    AutomationData* automation = nullptr;
    std::vector<int>* order = nullptr;
    SlotTable* table = nullptr;  // a slot table (and its mix graph) a Grow replaced
    ComponentChain* masterChain = nullptr;  // a component chain (master or a track's inserts) replaced or freed
    ComponentAutomation* componentAutomation = nullptr;  // a component chain's automation table replaced
    DelayLine* delay = nullptr;  // a latency-compensation delay replaced or freed
    SendTable* sends = nullptr;  // a route table replaced or freed
    ExportTable* exportTable = nullptr;  // an export table SetExports replaced (ExportPool frees it)
};

namespace {

constexpr double kSwapSeconds = 0.02;
constexpr double kSeamSeconds = 0.003;
constexpr double kStopSeconds = 0.01;
constexpr double kPlayTailSeconds = 0.005;   // Play after Stop: a ringing instrument fades out over this
constexpr double kPlayTailQuietSeconds = 0.1;  // ... if its track sounded within the last 0.1 s
constexpr double kPreviewGlideSeconds = 0.005;  // a held preview glides to a new pitch this fast (a bend being drawn)
constexpr float kPreviewQuiet = 1e-4f;          // -80 dB: a preview's effect tail below this has died away
constexpr double kPreviewQuietSeconds = 0.25;   // ... once it has stayed below it this long
constexpr double kPreviewTailSeconds = 30.0;    // the longest a tail (or a self-oscillating effect) keeps running
constexpr double kGainSeconds = 0.005;
constexpr double kLimitCeiling = 0.977;  // about -0.2 dBFS
// Play retires up to two entries per slot and must always find room, even with the retired queue
// full: the pending list holds 2 * (maxLayers() + 1) entries plus this slack (256 at 64 layers).
constexpr int kPendingSlack = 126;
constexpr size_t kMaxProjectComponents = 256;  // native component instances in one project (tracks and master)
constexpr int64_t kMaxCompensationFrames = 1 << 15;  // latency compensation up to about 0.7 s at 48 kHz
// What one export buffer costs against exportBufferBudget(): the buffer, its owner, and one table entry.
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
        if (clip.mute) continue;
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
        if (clip.mute) continue;  // a muted clip plays nothing; the layer still follows the arrangement
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
    std::vector<int> stack;           // [slots + 1] slots ready to be ordered
    std::vector<uint32_t> position;   // [slots + 1]
    std::vector<uint32_t> order;      // [nodeCount()]
    std::vector<GraphConnection> edges;  // [maxEdges()]

    // capacity: layer slots; the graph also routes the audition slot after them.
    MixGraph(Engine& e, int capacity, double sampleRate, const EngineResourceBudget& engineBudget)
        : slots(capacity + 1), master(capacity + 1),
          target(static_cast<size_t>(slots), 0), routable(static_cast<size_t>(slots), 0),
          modules(static_cast<size_t>(slots), 0), pending(static_cast<size_t>(slots) + 1, 0),
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
        b += (target.capacity() + modules.capacity() + pending.capacity() + slotOrder.capacity() + stack.capacity()) * sizeof(int);
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

size_t Engine::exportBytes() const noexcept {
    if (!exportPool_) return 0;
    return exportPool_->buffers.size() * (kExportBufferBytes + sizeof(std::unique_ptr<std::array<double, kBlock>>)) +
           exportPool_->entries * sizeof(std::array<double, kBlock>*);
}

// Control thread: forget a table the audio thread handed back (or never received) and free it.
void Engine::dropExportTable(ExportTable* t) noexcept {
    if (!t || !exportPool_) return;
    auto& tables = exportPool_->tables;
    for (size_t i = 0; i < tables.size(); ++i)
        if (tables[i].get() == t) {
            exportPool_->entries -= t->capacity;
            tables[i] = std::move(tables.back());
            tables.pop_back();
            return;
        }
}

// Audio thread: slot i joins the in-use list (kept ascending, so loops over it run in index order as
// the full scans did). It leaves in processChunk once nothing is left for a loop to do there.
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
      exportPerSlot_(static_cast<size_t>(resourceBudget.graphWorkingBytes /
                                         (static_cast<uint64_t>(kInitialLayerCapacity + 1) * kExportSlotBytes))),
      cmds_(new Spsc<Cmd, 1024>()),
      retired_(new Spsc<Retired, 1024>()),
      masterScope_(new std::atomic<float>[kScopeSize]),
      loudness_(std::make_unique<LoudnessMeter>()) {
    for (int i = 0; i < kScopeSize; ++i) masterScope_[i].store(0);
    midiPending_.reset(new PendingMidi[Midi2InputQueue::kCapacity]);
    loudness_->prepare(sampleRate);
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
        // A slot's export table header; its entries are charged to exportBufferBudget() with the buffers (#133).
        const double perSlot = static_cast<double>(sizeof(Slot) + sizeof(std::unique_ptr<Slot>) + sizeof(Slot*) +
                                                   2 * sizeof(int) + 2 * sizeof(Retired) + sizeof(ExportTable) +
                                                   sizeof(std::unique_ptr<ExportTable>));
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
        delete c.componentAutomation;
        delete c.delay;
        delete c.sends;
    }
    Retired r;
    while (retired_->pop(r)) {
        delete r.chain;
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
        delete pending_[i].chain;
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
        delete slot->cur;
        delete slot->old;
        delete slot->pending;
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
        delete r.chain;
        delete r.pattern;
        delete r.automation;
        delete r.order;
        delete r.table;
        delete r.masterChain;
        delete r.componentAutomation;
        delete r.delay;
        delete r.sends;
        dropExportTable(r.exportTable);
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
// it; sent to the audio thread as one Grow command. New slots have no export table until a chain exports.
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
                                 2 * sizeof(Retired) + sizeof(ExportTable) + sizeof(std::unique_ptr<ExportTable>);
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

Engine::Chain* Engine::buildChain(const std::vector<std::string>& ids, const std::vector<const double*>& wiring,
                                  bool voiced, bool native, const Chain* prev, const std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>>& automation,
                                   size_t expressionCapacity) {
    auto* c = new Chain();
    c->voiced = voiced;
    c->native = native;
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
    const BuildingQuality building(&quality_);
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
    ctlAutomation_ = projectAutomation;

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
        const std::vector<ComponentSpec>* components = nullptr;  // the layer's native inserts
        const ComponentSpec* instrument = nullptr;  // the layer's native instrument, if any
    };
    std::vector<Want> wants;
    int order = 0;
    if (p.auditionOnly) {
        wants.push_back({"\1audition", p.auditionChain, p.auditionPattern, p.auditionSteps, 0.8, 0.0, false, false, 100000, {}, {}, "", false});
    }
    order_.clear();
    for (const LayerSpec& l : p.layers) {
        order_.push_back(l.id);
        wants.push_back({l.id, l.chain, l.pattern, l.lengthSteps, l.volume, l.pan, l.mute, l.solo, ++order, l.clips, l.automation, l.parentId, l.folder && l.busEnabled, &l.components,
                         l.hasInstrument && !l.folder ? &l.instrument : nullptr});
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
        bool native = false;  // a native instrument plays the layer's notes
    };
    std::vector<Planned> plan;
    std::map<std::string, LayerState> nextLayers;
    // Export memory (#133): buffers and the slots' pointer-table entries, charged per layer here in
    // bytes against exportBufferBudget() (each buffer with one entry), while a layer that doesn't fit
    // can still be skipped like one without a free slot, so nothing later refuses a project after
    // slots were claimed or commands sent. Buffers once made stay with their slot and are reused.
    constexpr size_t kBufferBytes = kExportBufferBytes + sizeof(std::unique_ptr<std::array<double, kBlock>>);
    constexpr size_t kEntryBytes = sizeof(std::array<double, kBlock>*);
    const size_t exportBudgetBytes = exportBufferBudget() * kExportSlotBytes;
    size_t exportBytesPlanned = exportBytes();
    auto exportBuffersIn = [&](int slot) {
        const ExportTable* table = ctlSlot(slot).ctlExports;
        size_t made = 0;  // made from index 0 up, so the first empty entry ends them
        while (table && made < table->capacity && table->entries[made]) ++made;
        return made;
    };
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
        pl.native = w.instrument != nullptr && !w.bus;
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
            if (pl.native && it->second.program->kind != ModuleKind::Effect) {
                // A native instrument plays the notes instead: only .caw effects follow it.
                warnings[id].push_back("layer '" + w.id + "' plays the native instrument '" + w.instrument->id +
                                       "', so this module (not an effect) is not played there");
                continue;
            }
            pl.ids.push_back(id);
            pl.sig.push_back(it->second.program.get());
            layerStateDoubles += static_cast<uint64_t>(std::max(0, it->second.program->stateSize));
        }
        const std::string warnKey = pl.ids.empty() ? std::string("project") : pl.ids.front();
        // Arrangement clips are compiled into an immutable absolute-time event stream here,
        // on the control thread. A layer still uses one voice pool and one instrument/effect chain.
        if (!w.clips.empty() && (!pl.ids.empty() || pl.native)) {
            pl.arrangementSig = std::to_string(p.beatsPerBar) + "|" + std::to_string(p.loopSteps()) + "|";
            std::map<std::string, std::shared_ptr<const Pattern>> sources;
            for (const auto& [moduleId, module] : modules_)
                if (module.pattern) sources.emplace(moduleId, module.pattern);
            for (const ClipSpec& clip : w.clips) {
                pl.arrangementSig += clip.id + "|" + clip.pattern + "|" + std::to_string(clip.startSteps) + "|" +
                    std::to_string(clip.lengthSteps) + "|" + std::to_string(clip.sourceOffsetSteps) + "|" +
                    (clip.loop ? "1" : "0") + (clip.mute ? "m" : "") + "|";
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
                warnings[warnKey].push_back("layer not installed: its arrangement clips expand to about " +
                    std::to_string(static_cast<uint64_t>(std::min(expanded, 1.8e19))) +
                    " bytes of notes, over this Engine's project-state budget of " +
                    std::to_string(resourceBudget_.projectStateBytes) + " bytes");
                allOk = false;
                pl.ids.clear();
                pl.sig.clear();
                pl.native = false;
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
                if (!pl.native) {
                    const Program& gen = *modules_.at(pl.ids.front()).program;
                    layerStateDoubles += static_cast<uint64_t>(std::clamp(gen.voices, 2, kMaxVoices) - 1) *
                        static_cast<uint64_t>(std::max(0, gen.stateSize));
                }
            }
        } else if (!w.pattern.empty() && (!pl.ids.empty() || pl.native)) {
            auto it = modules_.find(w.pattern);
            if (it != modules_.end() && it->second.pattern) {
                pl.pattern = it->second.pattern;
                pl.w.steps = pl.pattern->steps(p.beatsPerBar);
                if (!pl.native) {
                    const Program& gen = *modules_.at(pl.ids.front()).program;
                    layerStateDoubles += static_cast<uint64_t>(std::clamp(gen.voices, 2, kMaxVoices) - 1) *
                        static_cast<uint64_t>(std::max(0, gen.stateSize));
                }
            } else {
                warnings[warnKey].push_back("pattern '" + w.pattern + "' is missing or has an error, so it plays without one");
            }
        }
        if (pl.pattern) {
            for (const NoteExpression& expression : pl.pattern->expressions) {
                pl.expressionCapacity = std::max(pl.expressionCapacity, expression.bend.points.size());
                pl.expressionCapacity = std::max(pl.expressionCapacity, expression.press.points.size());
                pl.expressionCapacity = std::max(pl.expressionCapacity, expression.timbre.points.size());
            }
            // Room to spare (a power of two, at least 16 points), so adding a curve point while the song plays
            // seldom rebuilds the chain, and a held voice can take its note's edited curve without allocating.
            pl.expressionCapacity = std::bit_ceil(std::max<size_t>(16, pl.expressionCapacity));
        }
        // The project-state share comes from the Engine's measured/fallback resource budget.
        const bool stateSizeOverflow = layerStateDoubles > std::numeric_limits<uint64_t>::max() / sizeof(double);
        const uint64_t layerStateBytes = stateSizeOverflow
            ? std::numeric_limits<uint64_t>::max() : layerStateDoubles * sizeof(double);
        const bool overBudget = stateSizeOverflow || projectStateBytes > resourceBudget_.projectStateBytes ||
            layerStateBytes > resourceBudget_.projectStateBytes - projectStateBytes;
        if ((!pl.ids.empty() || pl.native) && overBudget) {
            warnings[warnKey].push_back("layer not installed: estimated module state exceeds this Engine's project-state budget of " +
                std::to_string(resourceBudget_.projectStateBytes) + " bytes");
            allOk = false;
            pl.ids.clear();
            pl.sig.clear();
            pl.native = false;
        }
        if (pl.ids.size() > static_cast<size_t>(kMaxTrackModules)) {
            // Each module runs as its own mix-graph node, and a track has kMaxTrackModules of them.
            warnings[pl.ids.front()].push_back("layer not installed: its chain has " + std::to_string(pl.ids.size()) +
                " modules and a track runs at most " + std::to_string(kMaxTrackModules));
            allOk = false;
            pl.ids.clear();
            pl.sig.clear();
        }
        if (!pl.ids.empty() || pl.native) projectStateBytes += layerStateBytes;
        auto it = layers_.find(w.id);
        if (it != layers_.end()) {
            pl.ls = it->second;
            layers_.erase(it);
        }
        const bool isAudition = w.id[0] == '\x01';
        if (pl.ids.empty() && !w.bus && !pl.native) {
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
        const bool hadSlot = pl.ls.slot >= 0;
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
            pl.ls.inserts = nullptr;
            pl.ls.instrument = nullptr;
            pl.ls.native = false;
            pl.ls.compensation = 0;
            pl.ls.voiced = false;
            pl.ls.pattern = nullptr;
            pl.ls.steps = -1;
            pl.ls.volume = -1;
        }
        {
            size_t exports = 0;
            for (const std::string& id : pl.ids) {
                auto module = modules_.find(id);
                if (module != modules_.end() && module->second.program) exports += module->second.program->exports.size();
            }
            const size_t made = exportBuffersIn(pl.ls.slot);
            const ExportTable* table = ctlSlot(pl.ls.slot).ctlExports;
            const size_t entries = table ? table->capacity : 0;
            // A larger table replaces the slot's old one, which stays charged until the audio thread lets it go.
            const size_t adds = (exports > made ? exports - made : 0) * kBufferBytes +
                                (exports > entries ? exports : 0) * kEntryBytes;
            const char* why = nullptr;
            if (exports > exportPerSlot_)
                why = "its chain exports more values than one layer may hold within this device's memory budget";
            else if (exportBytesPlanned + adds > exportBudgetBytes)
                why = "the project's exports would exceed this device's export buffer budget (if another song is "
                      "still fading out, try again when it has)";
            if (why) {
                allOk = false;
                projectStateBytes -= layerStateBytes;  // charged above for a layer that now won't run
                // Keyed by the chain's first module, like the other chain warnings, so the result shows it.
                std::string& message = warnings[pl.ids.empty() ? std::string("project") : pl.ids.front()]
                    .emplace_back(std::string("layer '") + w.id + "' not installed: " + why);
                if (!hadSlot) {
                    ctlSlot(pl.ls.slot).ctlBusy = false;  // just claimed above; nothing was sent for it
                    pl.ls.slot = -1;
                    nextLayers[w.id] = pl.ls;
                } else {
                    // A playing layer can't keep its old chain outside the plan (its routing, order
                    // and exports would go stale), so it stops, the way an invalid layer is removed.
                    message += "; it was stopped";
                    Cmd c;
                    c.type = Cmd::Remove;
                    c.slot = pl.ls.slot;
                    if (!send(c)) {
                        message += " (the audio command queue was full, so it keeps playing unchanged)";
                        nextLayers[w.id] = pl.ls;
                    }
                }
                continue;
            }
            exportBytesPlanned += adds;
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

    // Export tables and buffers for what each planned layer exports (charged above). A slot whose
    // table is too small gets a new one, exactly its chain's size, with the old entries copied and the
    // new buffers made, sent before the chain that reads it (SetExports; the audio thread retires the
    // old table). A buffer's address never changes, so readers wired to it stay valid.
    if (!exportPool_) {
        try {
            exportPool_ = std::make_unique<ExportPool>();
        } catch (const std::bad_alloc&) {
            return R"({"ok":false,"error":"unable to allocate the export pool within the hardware-derived memory budget"})";
        }
    }
    for (const Planned& pl : plan) {
        if (pl.ls.slot < 0 || pl.ls.slot >= slotCount || pl.ids.empty()) continue;
        size_t required = 0;
        for (const std::string& id : pl.ids) {
            auto module = modules_.find(id);
            if (module != modules_.end() && module->second.program) required += module->second.program->exports.size();
        }
        if (required == 0) continue;
        Slot& slot = ctlSlot(pl.ls.slot);
        ExportTable* table = slot.ctlExports;
        ExportTable* made = nullptr;  // a new table, not yet sent
        try {
            if (!table || table->capacity < required) {
                auto fresh = std::make_unique<ExportTable>();
                fresh->capacity = required;
                fresh->entries = std::make_unique<std::array<double, kBlock>*[]>(required);  // null entries
                if (table) std::copy_n(table->entries.get(), table->capacity, fresh->entries.get());
                ExportTable* added = fresh.get();
                exportPool_->tables.push_back(std::move(fresh));  // on bad_alloc `fresh` still frees it
                exportPool_->entries += required;
                made = table = added;
            }
            // Only entries no chain on this slot has exported yet: the audio thread never reads them.
            for (size_t index = 0; index < required; ++index) {
                if (table->entries[index]) continue;
                auto buffer = std::make_unique<std::array<double, kBlock>>();
                buffer->fill(0.0);
                auto* stable = buffer.get();
                exportPool_->buffers.push_back(std::move(buffer));
                table->entries[index] = stable;
            }
        } catch (const std::bad_alloc&) {
            dropExportTable(made);
            return R"({"ok":false,"error":"unable to allocate the required export buffers within the hardware-derived memory budget"})";
        }
        if (made) {
            Cmd c;
            c.type = Cmd::SetExports;
            c.slot = pl.ls.slot;
            c.exportTable = made;
            if (!send(c)) {
                dropExportTable(made);
                return R"({"ok":false,"error":"audio command queue is not accepting project updates"})";
            }
            slot.ctlExports = made;
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
                sources.emplace(m.ref + "." + e.name, Source{pl.ls.slot, k, ctlSlot(pl.ls.slot).ctlExports->entries[buf]->data()});
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
        const bool voiced = pl.pattern != nullptr && !pl.native;
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
            if ((pl.native && madeInstrument != nextInstruments.end()) || (!pl.native && ls.instrument)) {
                Cmd instrument;
                instrument.type = Cmd::SetInstrument;
                instrument.slot = ls.slot;
                ComponentChain* sent = pl.native ? madeInstrument->second.release() : nullptr;
                if (sent) attachAutomation(*sent, w.id);
                instrument.masterChain = sent;
                if (send(instrument)) {
                    ls.instrument = sent;
                    ls.instrumentAutomationKey = ComponentChain::automationKey(p.automation, w.id, "instrument");
                } else {
                    allOk = false;
                    warnings["project"].push_back("layer '" + w.id + "': audio command queue rejected its native instrument update");
                }
            } else if (pl.native && ls.instrument) {
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
        if (pl.sig != ls.sig || wiring != ls.wiring || voiced != ls.voiced || pl.native != ls.native ||
            parameterAutomationChanged || pl.expressionCapacity != ls.expressionCapacity || !ls.chain) {
            Chain* c = buildChain(pl.ids, wiring, voiced, pl.native, ls.chain, projectAutomation, pl.expressionCapacity);
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
            ls.native = pl.native;
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
        if (ls.instrument && !ls.bus) frames += ls.instrument->latencyFrames();
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

int32_t Engine::componentDisplay(const std::string& layerId, uint32_t index, float* out, uint32_t max) {
    // Never waits: a UI polls this every frame, and a project update can hold ctl_ for a while (it then shows
    // its last picture). The chains themselves are read without locks (DisplayBuffer).
    std::unique_lock<std::mutex> lock(ctl_, std::try_to_lock);
    if (!lock.owns_lock()) return 0;
    ComponentChain* chain = ctlComponentChain(layerId, index);
    if (!chain) return -1;
    return chain->readDisplay(index, out, max);
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

// ---- Device MIDI (API 13) ----

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
    touchedParams_.clear();  // a (re)start ends every touch; chains do the same at their next chunk
    touchedGlobals_.clear();
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
    touchedParams_.clear();
    touchedGlobals_.clear();
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
    touchedParams_.clear();
    touchedGlobals_.clear();
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
            s.contiguous = false;
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

int64_t Engine::after(int64_t next) const noexcept {
    return next >= wrapAt() ? (loopRange_ ? loopFrom_ : 0) : next;
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
                    ComponentChain* masterChain) noexcept {
    if (!c && !freed && !pattern && !automation && !order && !table && !masterChain) return;
    retireEntry(Retired{c, freed, pattern, automation, order, table, masterChain});
}

void Engine::retireEntry(const Retired& r) noexcept {
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
            case Cmd::SetExports:
            case Cmd::Grow: retirementNeed = 1; break;
            case Cmd::ConfigureBus: retirementNeed = c.flag ? 9 : 8; break;
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
                    s.peakL.store(0, std::memory_order_relaxed);  // a reused slot doesn't show its last owner's level
                    s.peakR.store(0, std::memory_order_relaxed);
                    s.correlation.clear();
                    s.active = true;
                    markLive(c.slot);
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
                if (!c.flag && s.bus && s.active && !s.removing) {
                    // Already this bus: its inserts, delay and routes stay (they have their own commands).
                    s.parentSlot = c.parentSlot;
                    s.order = c.order;
                    break;
                }
                retire(s.cur, nullptr, s.pattern);
                retire(s.old, nullptr);
                retire(s.pending, nullptr);
                {
                    Retired r{nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.inserts};  // a new bus starts without them
                    r.delay = s.delay;
                    if (r.masterChain || r.delay) retireEntry(r);
                }
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
                s.insertsFading = nullptr;
                s.insertsFadeLeft = 0;
                s.inserts = nullptr;
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.instrument);
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.instrumentFading);
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
                s.cur = s.old = s.pending = nullptr;
                s.pattern = nullptr;
                s.peakL.store(0, std::memory_order_relaxed);
                s.peakR.store(0, std::memory_order_relaxed);
                s.correlation.clear();
                s.active = true;
                markLive(c.slot);
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
                // A sounding note that the edit kept (matchPatternNotes) moves onto its new note on the slot's next
                // run, which knows the playhead: it sounds on and follows the new curve. One the edit deleted ends.
                const std::vector<int>* map = c.orderList;
                auto carried = [map](uint32_t note) {
                    return map && note < map->size() ? (*map)[note] : -1;
                };
                if (s.cur && s.cur->voiced)
                    for (Voice& v : s.cur->voices) {
                        if (!v.active || !v.gate || v.preview >= 0) continue;
                        const int to = carried(v.note);
                        if (to < 0) {
                            v.gate = false;
                            v.rel = v.quiet = 0;
                            v.rebind = false;
                            continue;
                        }
                        v.note = static_cast<uint32_t>(to);
                        v.rebind = true;
                    }
                if (s.instrument) {
                    // The same for a native instrument's notes; none keeps pointing into the old pattern.
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
                retire(nullptr, nullptr, s.pattern, nullptr, c.orderList);
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
                        if (slotAt(i).instrument) slotAt(i).instrument->notes()->releaseAll(0, true);
                    }
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
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, masterFading_);
                masterFading_ = nullptr;
                masterFadeLeft_ = 0;
                if (playing_ || previewing_) {  // sounding: crossfade; otherwise the next sound starts on the new chain
                    masterFading_ = masterChain_;
                    masterFadeLeft_ = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                } else {
                    retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, masterChain_);
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
                if ((s.mode == Slot::Mode::Play || s.mode == Slot::Mode::Tail || s.mode == Slot::Mode::Bus) && !s.delayStale) {
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
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
                s.insertsFading = nullptr;
                s.insertsFadeLeft = 0;
                if (s.mode == Slot::Mode::Play || s.mode == Slot::Mode::Tail || s.mode == Slot::Mode::Bus) {
                    s.insertsFading = s.inserts;  // sounding: crossfades out (null: from the dry signal)
                    s.insertsFadeLeft = std::max(1, static_cast<int>(kSwapSeconds * sr_));
                } else {
                    retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.inserts);
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
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.instrumentFading);
                s.instrumentFading = nullptr;
                s.instrumentFadeLeft = 0;
                if (s.mode == Slot::Mode::Play && s.instrument && !s.instrumentIdle) {
                    s.instrument->notes()->releaseAll(0, false);
                    s.instrumentFading = s.instrument;
                    s.instrumentFadeLeft = fadeLen;
                } else {
                    retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.instrument);
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
                for (int k = 0; k < liveCount_; ++k)  // the audition stays last: still ascending
                    t.live[k] = live_[k] == auditionSlot_ ? t.capacity : live_[k];
                t.slots[t.capacity]->index = t.capacity;
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, table_.release());  // freed on the control thread
                table_.reset(c.table);  // table_ held nothing after release(): no delete here
                bindTable();
                break;
            }
            case Cmd::SetExports: {
                // A larger export table, with the old one's entries: chains keep reading the same buffers.
                Slot& s = slotAt(c.slot);
                if (s.exports) {
                    Retired r;
                    r.exportTable = s.exports;
                    retireEntry(r);
                }
                s.exports = c.exportTable;
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
    if (exportTo && exportTo->hasExports())
        for (const auto& [reg, buf] : c.exportMap[idx])
            if (exportTo->exportAt(buf))
                std::copy_n(inst->reg(reg), len, exportTo->exportAt(buf)->data());
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
// Callback start: device messages from the queue join the ones a past callback kept for later, and each gets its
// frame in this callback. A message for a track that is not running wakes it as a preview does, so a key played
// while stopped is heard. A .caw voice chain (no native instrument) takes notes as previews, at the block's start.
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
                if (s.cur && s.cur->voiced)
                    for (Voice& v : s.cur->voices)
                        if (v.active && v.gate && isDevicePreview(v.preview)) v.gate = false, v.rel = v.quiet = 0;
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
        if (!s.active || !s.cur) {
            p.done = true;
            continue;
        }
        const bool on = p.e.type == Midi2EventType::NoteOn;
        if (!s.instrument) {  // a .caw voice chain: notes only, as previews
            p.done = true;
            if (!s.cur->voiced || (!on && p.e.type != Midi2EventType::NoteOff)) continue;
            Cmd c;
            c.type = Cmd::Preview;
            c.previewOp = on ? 0 : 2;
            c.slot = p.e.target;
            c.previewId = devicePreviewId(p.e.group, p.e.channel, p.e.note);
            c.pitch = p.e.note;
            c.vel = p.e.value;
            previewCommand(c);
            continue;
        }
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

void Engine::previewCommand(const Cmd& c) noexcept {
    auto release = [](Voice& v) {
        v.gate = false;
        v.rel = v.quiet = 0;
    };
    if (c.previewOp == 3) {
        for (int i = 0; i < slotCount_; ++i) {
            Slot& s = slotAt(i);
            // The app's previews only: a device's held keys stay (caw_engine_midi_release ends those).
            if (s.instrument) s.instrument->notes()->releasePreviews(0, kDevicePreviewBase);
            if (!s.cur || !s.cur->voiced) continue;
            for (Voice& v : s.cur->voices)
                if (v.active && v.gate && v.preview >= 0 && !isDevicePreview(v.preview)) release(v);
        }
        return;
    }
    if (c.slot < 0 || c.slot >= slotCount_) return;
    Slot& s = slotAt(c.slot);
    if (!s.active || !s.cur) return;
    if (s.instrument) {
        // A native instrument: the preview is a note on, a pitch glide or a note off, with the caller's id.
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
        return;
    }
    if (!s.cur->voiced) return;
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
    v.rebind = false;
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
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        if (!s.previewing) continue;
        const bool silent = !s.active || (slotTarget(s) == 0.0 && s.gain == 0.0);
        bool voices = false;
        if (s.cur && s.cur->voiced)
            for (Voice& v : s.cur->voices) {
                if (!v.active || v.preview < 0) continue;
                if (silent) v.active = false;
                else voices = true;
            }
        if (s.instrument && s.instrument->notes()->holdsPreview()) {
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
        const bool runs = s.bus ? s.insertTail : s.cur && (s.cur->voiced || s.cur->native || s.insertTail);
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
        if (!s.cur) continue;
        if (s.cur->native) {
            // A native instrument's notes end and ring out (their release, its effects' tails) until quiet.
            if (s.instrument && !s.instrumentIdle) s.instrument->notes()->releaseAll(0, true);
            s.insertTail = false;  // the track runs whole, as for a preview, not just its inserts
            if (s.active && !s.bus && !(slotTarget(s) == 0.0 && s.gain == 0.0)) {
                s.previewing = true;
                s.previewTail = 0;
                previewing_ = true;
            }
        } else {
            restartChain(*s.cur);
        }
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
    v.rebind = false;
    takeExpression(v, pat, n);
}

bool Engine::playsNotes(const Slot& s) noexcept { return s.cur && (s.cur->voiced || s.cur->native); }

// Where sub-note `sub` of pattern note `n` sounds, in samples of the layer pass; false when it has no such repeat.
bool Engine::noteSpan(const PatternNote& n, uint32_t sub, int64_t& start, int64_t& stop) const noexcept {
    const int ratchet = std::max(1, n.ratchet);
    if (sub >= static_cast<uint32_t>(ratchet)) return false;
    const double part = n.len / ratchet;
    start = static_cast<int64_t>(std::floor((n.at + part * sub) * stepLen_ + 0.5));
    stop = static_cast<int64_t>(std::floor((n.at + part * (sub + 1)) * stepLen_ + 0.5));
    return true;
}

// A held .caw voice carried across a pattern edit, at the start of its next run (n0): if its new note still covers
// the playhead it sounds on (no new trig) and takes that note's curve from here, gliding from the pitch heard to
// where the new curve is over kRebindGlideSeconds; otherwise it is released.
void Engine::rebindVoice(Voice& v, const Pattern* pat, int64_t n0) noexcept {
    v.rebind = false;
    int64_t start = 0, stop = 0;
    const PatternNote* n = pat && v.note < pat->notes.size() ? &pat->notes[v.note] : nullptr;
    const bool expressive = n && n->extra >= 0 && static_cast<size_t>(n->extra) < pat->expressions.size();
    const NoteExpression* x = expressive ? &pat->expressions[static_cast<size_t>(n->extra)] : nullptr;
    // The curve is copied into the voice's own storage, set aside for the layer's longest curve: one that doesn't
    // fit (never expected: the chain is rebuilt with room first) ends the note rather than allocate here.
    const bool fits = !x || (x->bend.points.size() <= v.ex.bend.points.capacity() &&
                             x->press.points.size() <= v.ex.press.points.capacity() &&
                             x->timbre.points.size() <= v.ex.timbre.points.capacity());
    if (!n || !fits || !noteSpan(*n, v.sub, start, stop) || n0 < start || n0 >= stop) {
        v.gate = false;
        v.rel = v.quiet = 0;
        return;
    }
    const double heard = v.pitch + (v.expressive ? v.bend : 0.0);
    v.expressive = expressive;
    if (x) v.ex = *x;
    v.exLen = std::max(1.0, n->len / std::max(1, n->ratchet) * stepLen_);
    v.exStart = v.since - (n0 - start);
    v.bend = 0;
    v.press = 1;
    v.timbre = 0;
    if (x) expressionAt(v.ex, static_cast<double>(n0 - start), v.exLen, sr_, v.bend, v.press, v.timbre);
    v.exLeft = 0;  // the next sample works out its control point from these values, so nothing jumps
    v.vel = n->vel;
    v.pitch = heard - v.bend;
    v.freq = mtof(v.pitch);
    v.target = n->pitch;
    v.glideLeft = std::max(1, static_cast<int>(std::floor(kRebindGlideSeconds * sr_ + 0.5)));
    v.glideStep = (v.target - v.pitch) / v.glideLeft;
}

// The same for a native instrument's held note, at the start of its next chunk (n0): its motion carries on from the
// next control point of its grid (the grid's phase is kept), now on the new note's curve, gliding there.
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

// The pattern's notes in this chunk as a native instrument's events, on their exact frames, with the same rules a
// .caw voice pool follows: chance per repeat, ratchets, slides (the held note glides on, no new attack), the note's
// expression, and held notes carried across a pattern edit following their new note.
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

// Glides and expression as per-note pitch, pressure and timbre events, worked out every kExpressionStep frames (as a
// .caw voice works out its curves), sent only when a value changes. The grid runs on from the note's start (or its
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
    const ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), playing_ && !previewChunk_};
    if (s.instrumentIdle) {
        // It stopped running while silent: what it held is stale, so it starts from silence.
        for (ComponentChain* c : {s.instrument, s.instrumentFading})
            if (c) {
                c->reset();
                c->notes()->forget(false);
                c->notes()->clearEvents();
            }
        s.instrumentIdle = false;
    }
    if (s.instrument) {
        NoteEvents& notes = *s.instrument->notes();
        if (!previewChunk_) instrumentNotes(s, notes, m);
        if (midiPendingCount_ > 0) feedDeviceMidi(s, notes, m);
        instrumentMotion(notes, m);
        s.instrument->process(s.instL, s.instR, static_cast<uint32_t>(m), sr_, &time);
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
        s.instrumentFading->process(fadeL_, fadeR_, static_cast<uint32_t>(m), sr_, &time);
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
            retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.instrumentFading);
            s.instrumentFading = nullptr;
        } else {
            s.instrumentFadeLeft = 1;  // no room to hand it back yet: try again next block
        }
    }
}

void Engine::runVoices(Chain& c, const Pattern* pat, int64_t repeat, int64_t n0, int len, double* out, Slot* exportTo,
                       int offset, const BlockCtx& base) noexcept {
    std::fill_n(out, len, 0.0);
    auto sampleOf = [this](double step) { return static_cast<int64_t>(std::floor(step * stepLen_ + 0.5)); };
    const PatternEvent* ev = pat ? pat->events.data() : nullptr;
    const size_t ne = pat ? pat->events.size() : 0;
    size_t e = static_cast<size_t>(
        std::partition_point(ev, ev + ne, [&](const PatternEvent& x) { return sampleOf(x.step) < n0; }) - ev);
    for (int vi = 0; vi < c.voiceCount; ++vi)
        if (c.voices[vi].active && c.voices[vi].rebind) rebindVoice(c.voices[vi], pat, n0);
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
        // A pattern packed with notes can't split a block into slivers: past kMaxSplits they start together.
        if (++splits >= kMaxSplits)
            while (e < ne && sampleOf(ev[e].step) < end) noteEvent(c, *pat, ev[e++], repeat);
        const int64_t next = e < ne ? std::min(end, sampleOf(ev[e].step)) : end;
        const int n = static_cast<int>(next - pos), o = static_cast<int>(pos - n0);
        int newest = -1;
        for (int v = 0; v < c.voiceCount; ++v)
            if (c.voices[v].active && (newest < 0 || c.voices[v].started > c.voices[newest].started)) newest = v;
        if (exportTo && exportTo->hasExports())
            for (const auto& [reg, buf] : c.exportMap[0])
                if (exportTo->exportAt(buf))
                    std::fill_n(exportTo->exportAt(buf)->data() + offset + o, n, 0.0);
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
            if (exportTo && exportTo->hasExports() && vi == newest)
                for (const auto& [reg, buf] : c.exportMap[0])
                    if (exportTo->exportAt(buf))
                        std::copy_n(v.inst->reg(reg), n, exportTo->exportAt(buf)->data() + offset + o);
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
        if (!s.fresh && s.cur && (s.cur->voiced || s.cur->native)) {
            // A pattern layer restarts its pattern: held notes ring out, voices and effects carry on.
            releaseVoices(s.cur->voices, s.cur->voiceCount);
            if (s.instrument && !s.instrumentIdle) s.instrument->notes()->releaseAll(0, true);
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
        for (int k = 0; k < liveCount_; ++k) {
            Slot& s = slotAt(live_[k]);
            if (!s.active || (!s.bus && !s.cur)) { s.mode = Slot::Mode::Idle; continue; }
            if (s.bus) { s.mode = Slot::Mode::Bus; continue; }
            s.target = slotTarget(s);
            const bool silentMix = s.target == 0.0 && s.gain == 0.0;
            if (s.previewing && !silentMix && !playsNotes(s) && s.insertTail) {
                s.mode = Slot::Mode::Tail;  // a generator's loop would play on: only the inserts ring out
                continue;
            }
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
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        if (!s.active || (!s.bus && !s.cur)) { s.mode = Slot::Mode::Idle; continue; }
        if (s.bus) { s.mode = Slot::Mode::Bus; continue; }
        s.target = slotTarget(s);
        // A slot keying a component (a kick keying a ducker) keeps running while muted or soloed out, so its key
        // still sounds; its own output is silence.
        const bool keys = s.sends && s.sends->keys && !s.removing && !s.overloaded;
        if (s.target == 0.0 && s.gain == 0.0 && !keys) {
            // Silent (muted, soloed out or removed, and faded out): nothing runs; swaps and removal finish.
            s.mode = Slot::Mode::Silent;
            s.insertsIdle = true;
            s.instrumentIdle = s.instrumentIdle || s.instrument || s.instrumentFading;
            s.delayStale = true;
            s.routesStale = true;
            s.contiguous = false;
            if (s.pending && canRetire(1)) { swapIn(s, s.pending); s.pending = nullptr; routingDirty_ = true; }
            if (s.removing && canRetire(6)) {
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.instrument);
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.instrumentFading);
                s.instrument = s.instrumentFading = nullptr;
                s.instrumentFadeLeft = 0;
                {
                    Retired d;
                    d.delay = s.delayFading;
                    if (d.delay) retireEntry(d);
                    s.delayFading = nullptr;
                    s.delayFadeLeft = 0;
                }
                retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
                s.insertsFading = nullptr;
                s.insertsFadeLeft = 0;
                retire(s.cur, nullptr, s.pattern);
                s.pattern = nullptr;
                {
                    // One entry: the slot frees with its inserts and delay.
                    Retired r{s.old, &s, nullptr, nullptr, nullptr, nullptr, s.inserts};
                    r.delay = s.delay;
                    r.sends = s.sends;
                    retireEntry(r);
                }
                s.inserts = nullptr;
                s.delay = nullptr;
                s.sends = nullptr;
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
    // Only slots in use are visited (#133). A slot leaves the list once no loop has anything left to do
    // for it: inactive, exports cleared, not previewing and planned Idle (the scans it skips would only
    // set Idle again). Its routing scratch is reset, as updateRouting would have left it.
    int kept = 0;
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
        Slot& slot = slotAt(i);
        if (slot.hasExports() && slot.exportCount > 0 &&
            (!slot.active || !slot.cur || (slotTarget(slot) == 0.0 && slot.gain == 0.0))) {
            for (size_t b = 0; b < slot.exportCount; ++b)
                if (slot.exportAt(b)) std::fill_n(slot.exportAt(b)->data(), maxFrames, 0.0);
            if (!slot.active || (!slot.cur && !slot.pending)) slot.exportCount = 0;
        }
        if (!slot.active && slot.exportCount == 0 && !slot.previewing && slot.mode == Slot::Mode::Idle) {
            slot.listed = false;
            MixGraph& g = *mixGraph_;
            g.routable[i] = 0;
            g.modules[i] = 0;
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
    if (previewChunk_)
        // Stopped, a track that isn't previewing exports silence, not the last block it played.
        for (int k = 0; k < liveCount_; ++k) {
            Slot& slot = slotAt(live_[k]);
            if (slot.mode == Slot::Mode::Play || !slot.hasExports()) continue;
            for (size_t b = 0; b < slot.exportCount; ++b)
                if (slot.exportAt(b)) std::fill_n(slot.exportAt(b)->data(), m, 0.0);
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
        mixToneOnly(l, r, m);  // the master stage, last in the graph, did not run
    }
    return m;
}

// Routing as graph edges: a routable slot (active, and a bus or a track with a chain) goes to its parent when
// that parent is an active folder bus, is dropped when its parent is anything else, and goes to master at the
// root. Sends and sidechain keys add order but no edges (the source adds into its destination's input, runRoutes):
// a slot runs after every slot that feeds it, whether as a child, a send or a key. The order is the old pass order
// (processOrder_, then the remaining slots by index) with each slot held back until what feeds it has run, so a
// track always reaches its bus in the same chunk (issue #76). A track runs as its module nodes (enough for its
// current chain and the one fading out), chained lane by lane into its track node. Edges into buses follow that
// order, which is the old accumulation order. Idle slots are left out of the order, so they cost nothing.
void Engine::updateRouting() noexcept {
    MixGraph& g = *mixGraph_;
    const int master = g.master;
    // Only slots in use (live_, ascending); the rest are not routable, and processChunk reset their
    // scratch when they left the list (#133).
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
        const Slot& s = slotAt(i);
        int to = -1, modules = 0;
        bool routable = s.active && (s.bus || s.cur);
        if (routable && !s.bus) {
            modules = static_cast<int>(s.cur->main.size());
            if (s.old) modules = std::max(modules, static_cast<int>(s.old->main.size()));
            if (s.cur->native) modules = std::max(modules, 1);  // node 0 runs the instrument
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
    const bool instrument = s.cur->native || s.instrument || s.instrumentFading || (s.fade && s.old->native);
    if (index == 0 && instrument) runInstrument(s, m);
    auto lane = [&](Chain& c, int l, bool shadow, int len, int64_t n0, Slot* exportTo, const Pattern* pat,
                    int64_t repeat, int channel) noexcept {
        // A native instrument's chain: its .caw effects take the instrument's mid (they are mono).
        if (idx >= c.main.size()) {
            if (idx == 0 && c.native)
                for (int i = 0; i < len; ++i) out[channel][i] = 0.5f * (s.instL[i] + s.instR[i]);
            else
                std::copy_n(in[channel], len, out[channel]);
            return;
        }
        if (idx == 0) prepareLane(c, l, n0, len);
        const double* x = c.zero;
        if (idx > 0) {
            for (int i = 0; i < len; ++i) c.lanes[l].in[i] = static_cast<double>(in[channel][i]);
            x = c.lanes[l].in;
        } else if (c.native) {
            for (int i = 0; i < len; ++i) c.lanes[l].in[i] = 0.5 * (static_cast<double>(s.instL[i]) + s.instR[i]);
            x = c.lanes[l].in;
        }
        const double* y = runModule(c, l, shadow, idx, n0, gg, len, x, exportTo, pat, repeat);
        for (int i = 0; i < len; ++i) out[channel][i] = routeSample(y[i]);
    };
    lane(*s.cur, 0, false, m, s.n0, &s, s.pat, s.repeat, 0);
    if (s.seam) lane(*s.cur, 1, true, std::min(m, s.seamLeft), s.shadowN, nullptr, nullptr, s.k, 1);
    if (s.fade) lane(*s.old, 0, false, m, s.n0, nullptr, nullptr, s.k, 2);
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
    const ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), playing_ && !previewChunk_,
                         chunkId_};
    const ChainTime* t = &time;
    if (fading) {
        std::copy_n(L, m, fadeL_);
        std::copy_n(R, m, fadeR_);
        if (s.insertsFading) s.insertsFading->process(fadeL_, fadeR_, static_cast<uint32_t>(m), sr_, t);
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
            retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
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
        const double want = r.mute || (!key && silenced) ? 0.0 : r.level;
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
void Engine::runTrackNode(int slot, const float* const* in, float* outL, float* outR, int m) noexcept {
    Slot& s = slotAt(slot);
    if (s.mode != Slot::Mode::Play && s.mode != Slot::Mode::Tail) {
        std::fill_n(outL, m, 0.0f);
        std::fill_n(outR, m, 0.0f);
        return;
    }
    const bool tail = s.mode == Slot::Mode::Tail;  // stopped: silence into the inserts, which ring out
    const double target = s.target;
    if (!(trackGainCoef_ >= 0.0)) trackGainCoef_ = 1.0 - detExp(-1.0 / (kGainSeconds * sr_));  // once per Engine
    const double gainCoef = trackGainCoef_;
    const int seamLen = std::max(1, static_cast<int>(kSeamSeconds * sr_));
    const int swapLen = std::max(1, static_cast<int>(kSwapSeconds * sr_));
    const double pan = bitsToDouble(s.pan.load(std::memory_order_relaxed));
    if ((!s.automation || s.automation->pan.empty()) && pan != s.panCache) {
        s.panCache = pan;
        const lib::PanGains g = lib::constantPowerPan(pan);
        s.gl = g.left;
        s.gr = g.right;
    }
    // A native instrument with no .caw effects after it stays stereo into the inserts; the mono chain output
    // (y) is then not used, so it is not worked out.
    const bool instrumentStereo = !tail && s.cur->native && s.cur->main.empty() && !(s.fade && !s.old->main.empty());
    double* y = tmp_;
    if (!instrumentStereo)
        for (int i = 0; i < m; ++i) y[i] = tail ? 0.0 : static_cast<double>(in[0][i]);
    if (s.seam && !tail) {
        const int sl = std::min(m, s.seamLeft);
        if (!instrumentStereo)
            for (int i = 0; i < sl; ++i) {
                const double w = static_cast<double>(seamLen - s.seamLeft + i + 1) / (seamLen + 1);
                y[i] = static_cast<double>(in[1][i]) * (1.0 - w) + y[i] * w;
            }
        s.shadowN += sl;
        s.seamLeft -= sl;
    }
    if (s.fade && !tail) {
        const int sl = std::min(m, s.swapLeft);
        if (!instrumentStereo)
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
    // Native inserts (#17): the mono chain output enters as two equal channels; what the inserts
    // make of it stays stereo through volume and pan (the pan law then works per side, as balance).
    const bool stereo = s.inserts || s.insertsFadeLeft > 0 || instrumentStereo;  // stereo output, not the mono chain
    if (stereo) {
        if (instrumentStereo) {
            std::copy_n(s.instL, m, insertL_);
            std::copy_n(s.instR, m, insertR_);
        } else {
            for (int i = 0; i < m; ++i) insertL_[i] = insertR_[i] = routeSample(finiteOr0(y[i]));
        }
        runInserts(s, insertL_, insertR_, m);
    }
    float peakL = 0, peakR = 0, sig = 0;
    int sp = s.scopePos.load(std::memory_order_relaxed);
    const bool volumeAutomated = s.automation && !s.automation->volume.empty();
    const bool panAutomated = s.automation && !s.automation->pan.empty();
    const double settled = target > 0.0 ? target : 0.0;
    if (!volumeAutomated && !panAutomated && s.gain == settled) {
        // The usual case: volume settled, no lanes. The same sums as the loop below, without its per-sample
        // branches, and the scope written in at most two runs instead of a wrap test per sample.
        const double gain = s.gain, gl = s.gl, gr = s.gr;
        float mid[kBlock], level[kBlock];
        if (stereo) {
            for (int i = 0; i < m; ++i) {
                const double vl = static_cast<double>(insertL_[i]) * gain;
                const double vr = static_cast<double>(insertR_[i]) * gain;
                outL[i] = routeSample(vl * gl);
                outR[i] = routeSample(vr * gr);
                const double al = std::fabs(vl), ar = std::fabs(vr);
                level[i] = static_cast<float>(al < ar ? ar : al);
                mid[i] = static_cast<float>(0.5 * (vl + vr));
            }
        } else {
            for (int i = 0; i < m; ++i) {
                const double v = finiteOr0(y[i]) * gain;
                outL[i] = routeSample(v * gl);
                outR[i] = routeSample(v * gr);
                level[i] = static_cast<float>(std::fabs(v));
                mid[i] = static_cast<float>(v);
            }
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
        const double vl = (stereo ? static_cast<double>(insertL_[i]) : finiteOr0(y[i])) * s.gain;
        const double vr = stereo ? static_cast<double>(insertR_[i]) * s.gain : vl;
        const double v = stereo ? 0.5 * (vl + vr) : vl;  // the scope and tail test read the mid
        double gl = s.gl, gr = s.gr;
        if (panAutomated) {
            const double automatedPan = automationValue(s.automation->pan, step, pan);
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
    if (tail && s.tailFade != 0) {  // a capped tail fading out (or faded: silence until it is ended)
        const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
        for (int i = 0; i < m; ++i) {
            const float g = s.tailFade > 0 ? static_cast<float>(s.tailFade) / static_cast<float>(len) : 0.0f;
            if (s.tailFade > 0 && --s.tailFade == 0) s.tailFade = -1;
            outL[i] *= g;
            outR[i] *= g;
        }
    }
    if (s.sends && s.sends->count > 0) {
        const float* preL = insertL_;
        const float* preR = insertR_;
        if (!stereo) {
            for (int i = 0; i < m; ++i) preL_[i] = tail ? 0.0f : routeSample(finiteOr0(y[i]));
            preL = preR = preL_;
        }
        runRoutes(s, preL, preR, outL, outR, m, !(target > 0.0), false);
    }
    if (s.delay || s.delayFadeLeft > 0) runDelay(s, outL, outR, m);  // in time where it meets the others
    s.previewQuiet = sig > kPreviewQuiet ? 0 : s.previewQuiet + m;
    if (previewChunk_) {
        s.previewN += m;  // the transport isn't moving: its place in the loop stays; the preview's time runs on
        return;
    }
    s.lastN = s.n0 + m - 1;
    const int64_t next = g_ + m;
    s.expectG = after(next);
    s.contiguous = true;
    s.progress.store(static_cast<float>(static_cast<double>(s.n0 + m) / s.cur->layerLen), std::memory_order_relaxed);
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
    storeMax(s.peakL, peakL);  // a folder's meter: its mix after volume and pan
    storeMax(s.peakR, peakR);
    s.correlation.process(outL, outR, m);
    s.previewQuiet = std::max(peakL, peakR) > kPreviewQuiet ? 0 : s.previewQuiet + m;
    if (routes) runRoutes(s, insertL_, insertR_, outL, outR, m, !(target > 0.0), true);
    if (s.delay || s.delayFadeLeft > 0) runDelay(s, outL, outR, m);  // in time where it meets the others
    if (s.removing && s.gain == 0.0 && canRetire(3)) {
        // Faded out: the slot is free again, with its inserts, delay and routes.
        Retired r{nullptr, &s, nullptr, nullptr, nullptr, nullptr, s.inserts};
        r.delay = s.delay;
        r.sends = s.sends;
        retireEntry(r);
        retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, s.insertsFading);
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
        const ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), playing_ && !previewChunk_};
        const ChainTime* t = &time;
        const bool fading = masterFadeLeft_ > 0;
        if (fading) {
            std::copy_n(stageL, m, fadeL_);
            std::copy_n(stageR, m, fadeR_);
            if (masterFading_) masterFading_->process(fadeL_, fadeR_, static_cast<uint32_t>(m), sr_, t);
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
                    retire(nullptr, nullptr, nullptr, nullptr, nullptr, nullptr, masterFading_);
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
            const int m = processChunk(left + i, right + i, std::min(frames - i, kBlock));
            previewChunk_ = false;
            i += m;
            continue;
        }
        // The song loops at its end, or at the loop range's end while that is on (and before it).
        const int64_t wrap = wrapAt();
        const int maxM = static_cast<int>(std::min<int64_t>({static_cast<int64_t>(frames - i), kBlock, wrap - g_}));
        midiChunkFrom_ = i;
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
