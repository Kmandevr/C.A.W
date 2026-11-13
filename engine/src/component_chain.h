// A chain of native stereo components (a track's inserts or the master's), with their parameters.
#pragma once

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "module_registry.h"
#include "note_events.h"
#include "params.h"
#include "project.h"

namespace caw {

// A built-in whose latency depends on its parameters (the ducker's look-ahead, only while it is on): the chain asks
// it, with the control thread's values, instead of reading the descriptor. Engine-internal; not part of the SDK.
class VariableLatency {
public:
    virtual ~VariableLatency() = default;
    virtual uint32_t latencyFor(const double* values, uint32_t count) const noexcept = 0;
};

// Which automation lane drives each parameter of a chain. Immutable once made; a project update
// that changes the lanes makes a new one, and the audio thread swaps it in (the chain keeps playing).
struct ComponentAutomation {
    std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>> lanes;  // owns what `byParam` points into
    std::vector<std::vector<const ProjectAutomationLaneSpec*>> byParam;   // [component][parameter], null: none
    std::vector<uint8_t> anyLane;  // [component]: 1 when a lane drives any of its parameters
};

// Project modulation for one chain's block (#161, modulation_links.h): for each modulated parameter, its offset in
// normalized travel per frame, added to the resolved base value (mod_route.h's modulatedValue) without changing it.
// The scratch is the host's: the chain writes the modulated values there for the block (audio thread, one chain at
// a time). A component with more parameters than `valueCapacity`, or more modulated ones with per-frame values than
// `sampleBuffers`, plays the rest unmodulated.
struct ChainModulation {
    struct Binding {
        uint32_t entry = 0;  // the component's index in the chain
        uint32_t param = 0;  // its parameter index
        const float* offset = nullptr;  // `frames` floats
    };
    const Binding* bindings = nullptr;
    uint32_t count = 0;
    ParameterValue* values = nullptr;
    uint32_t valueCapacity = 0;
    double* samples = nullptr;  // sampleBuffers x ComponentChain::kMaxFrames
    uint32_t sampleBuffers = 0;
};

// Where the transport is for a block, so automation lanes can be read. Null while stopped.
struct ChainTime {
    int64_t start = 0;      // the block's first sample in the song
    double stepLength = 1;  // samples per sixteenth step
    uint64_t playEpoch = 0; // changes on every Play: touches end
    double tempo = 120;     // beats per minute, for the components' transport
    uint32_t beatsPerBar = 4;
    bool playing = true;    // false: stopped (lanes hold; components still learn the tempo)
    int64_t chunk = -1;     // the Engine's chunk counter: a key written for another chunk is stale (silence)
    const ChainModulation* modulation = nullptr;  // project modulation of this chain's parameters (null: none)
};

// Benchmark-only (caw_bench's profile mode): the time each component spends in a chain, per processor. Off (null)
// everywhere else, where it costs one relaxed load per chain per block. Fixed slots, so the audio thread never
// allocates; processors past kSlots are not counted.
struct ChainProfile {
    static constexpr uint32_t kSlots = 512;
    struct Slot {
        const void* processor = nullptr;
        const std::string* id = nullptr;  // the chain entry's id (lives as long as the chain)
        uint64_t ns = 0, calls = 0, ran = 0;  // calls: blocks seen; ran: blocks it actually processed
        bool modulator = false;
    };
    Slot slots[kSlots];
    uint32_t used = 0;
    Slot* slot(const void* processor, const std::string* id) noexcept;
    static void set(ChainProfile* profile) noexcept;
    static ChainProfile* current() noexcept;
};

// Built and configured on the control thread, then handed to the audio thread, which alone calls
// process() and reset(); destroyed on the control thread after the audio thread retires it. The
// control thread may change values (setValue, setValues, setBypass) and save state (saveStates)
// while the chain plays.
class ComponentChain {
public:
    static constexpr uint32_t kMaxFrames = 64;  // the Engine's block (checked in engine.cpp)

    // Every component must be loaded, have one stereo audio input and one stereo audio output and
    // no other ports, every named parameter must exist, and a saved state must load. An empty
    // pointer and `error` otherwise.
    static std::unique_ptr<ComponentChain> build(const ModuleRegistry& registry,
                                                 const std::vector<ComponentSpec>& specs, double sampleRate,
                                                 std::string& error);
    // A track's instrument: one component with one event input and one stereo audio output (and no
    // other ports), played by the notes in notes(). Everything else (values, bypass, state,
    // automation, tails, latency, rebuilds) works as for an effect chain of one.
    static std::unique_ptr<ComponentChain> buildInstrument(const ModuleRegistry& registry, const ComponentSpec& spec,
                                                           double sampleRate, std::string& error);
    // Whether a descriptor has an instrument's ports (one event input, one stereo audio output).
    static bool isInstrument(const ModuleDescriptor& d) noexcept;
    // One slot of a layer's per-note FX (#127, note_fx_host.h): effects as build() takes them (keyed ones excepted),
    // each of which may also have one event input (its note's events, setEvents) and must declare kDomainPerNote
    // (or kDomainPerVoice, run per note). Automation lanes are the "noteComponent" ones.
    static std::unique_ptr<ComponentChain> buildNoteEffects(const ModuleRegistry& registry,
                                                            const std::vector<ComponentSpec>& specs, double sampleRate,
                                                            std::string& error);
    // Whether a descriptor can run per note: an effect's ports (one stereo audio input and output, at most one event
    // input) and the per-note (or per-voice) domain. `why` says what is missing when it can't.
    static bool runsPerNote(const ModuleDescriptor& d, std::string* why = nullptr) noexcept;
    // Audio thread, an instrument: the voice bus its next process() hands the component (null: none).
    void setVoices(const VoiceBus* voices) noexcept { voices_ = voices; }
    // Audio thread, per-note FX: the events its next process() hands components that have an event input (frames
    // within that call).
    void setEvents(const Event* events, uint32_t count) noexcept {
        noteEvents_ = events;
        noteEventCount_ = events ? count : 0;
    }
    // Audio thread: every component is asleep (said quiet() and has heard nothing since) or bypassed.
    bool quiet() const noexcept;
    // A modulator (#161): 1..kMaxModulatorOutputs modulation outputs, at most one event input and at most one audio
    // input (mono or stereo), no other ports. Chains of tracks refuse it; the project's modulators hold it.
    static constexpr uint32_t kMaxModulatorOutputs = 8;
    static bool isModulator(const ModuleDescriptor& d) noexcept;
    // The project's modulators as one chain of entries, in evaluation order: values, automation lanes ("modulator"
    // lanes are not built: knob moves and project values only), state and modulation of their own parameters work
    // as for any chain, but they run through runModulator, never process().
    static std::unique_ptr<ComponentChain> buildModulators(const ModuleRegistry& registry,
                                                           const std::vector<ComponentSpec>& specs, double sampleRate,
                                                           std::string& error);
    // Audio thread, modulators only: begin a block of runModulator calls (a Play ends knob overrides).
    void beginModulators(const ChainTime* time) noexcept;
    // Audio thread, modulators only: runs entry `index` over m frames with these notes (frames in the block) and audio
    // (null: silence; mono components read `inL`), writing its outputs (each m floats; outCount of them). False when
    // it failed the block (the outputs are then 0).
    bool runModulator(std::size_t index, uint32_t m, double sampleRate, const ChainTime* time, const Event* events,
                      uint32_t eventCount, const float* inL, const float* inR, float* const* outs,
                      uint32_t outCount) noexcept;
    // Its ports: how many modulation outputs, and whether it takes notes or audio.
    uint32_t modulatorOutputs(std::size_t index) const noexcept;
    bool modulatorTakesNotes(std::size_t index) const noexcept;
    bool modulatorTakesAudio(std::size_t index) const noexcept;
    // Any thread: parameter `id` of component `index` (-1: none). No allocation.
    int parameterIndexOf(std::size_t index, std::string_view id) const noexcept;
    const ModuleDescriptor* descriptorOf(std::size_t index) const noexcept {
        return index < entries_.size() ? &entries_[index]->processor->descriptor() : nullptr;
    }
    // A keyed effect: a stereo audio input, a second stereo audio input with the id "sidechain" (its key), at
    // most one event input (the key's notes) and one stereo audio output; the main input is the first audio
    // input. The host fills its key through keyInput(); with no key it hears silence and no notes.
    static bool isKeyedEffect(const ModuleDescriptor& d) noexcept;
    // What sidechain sources wrote into a keyed component this chunk (audio thread): their audio, summed, and
    // the note-ons of the layers keying it. begin() clears it the first time it is written in a chunk.
    static constexpr uint32_t kMaxKeyEvents = 64;
    struct KeyInput {
        float l[kMaxFrames] = {}, r[kMaxFrames] = {};
        Event events[kMaxKeyEvents] = {};
        uint32_t count = 0;
        int64_t chunk = -1;
        void begin(int64_t now) noexcept {
            if (chunk == now) return;
            for (uint32_t i = 0; i < kMaxFrames; ++i) l[i] = r[i] = 0.0f;
            count = 0;
            chunk = now;
        }
    };
    // Component `index`'s key, or null when it has no sidechain input. Audio thread (written by the sources).
    KeyInput* keyInput(std::size_t index) noexcept {
        return index < entries_.size() ? entries_[index]->key.get() : nullptr;
    }
    bool keyed(std::size_t index) const noexcept { return index < entries_.size() && entries_[index]->key != nullptr; }
    bool instrument() const noexcept { return notes_ != nullptr; }
    // Audio thread: an audio track monitoring its input wants to run while the transport is stopped.
    bool monitorsStopped() const noexcept;
    // The instrument's notes and this block's events (null for an effect chain). Audio thread.
    NoteEvents* notes() noexcept { return notes_.get(); }
    ~ComponentChain();

    // Whether this chain was built from the same components, in the same order, at this rate, so a
    // project update keeps it (and its running state, such as a reverb's tail) and only sets values.
    bool sameComponents(const std::vector<ComponentSpec>& specs, double sampleRate) const noexcept;
    // Control thread. Sets every value and bypass the specs give, the rest of the values back to
    // their defaults, so a kept chain sounds as a freshly built one would (an export builds afresh).
    // These are restores: they ramp but don't override an automation lane.
    void setValues(const std::vector<ComponentSpec>& specs) noexcept;
    // Control thread: a knob move. It overrides the parameter's automation lane until the next Play.
    // False for an index or parameter id the chain does not have, or a non-finite value.
    bool setValue(std::size_t index, const std::string& parameterId, double value) noexcept;
    bool setBypass(std::size_t index, bool bypass) noexcept;
    // Control thread: each component's state as save_state writes it, in chain order. Components
    // must allow save_state while they process (the component interface's thread rule).
    struct SavedState {
        bool ok = false;
        uint32_t version = 1;
        std::vector<uint8_t> data;
    };
    std::vector<SavedState> saveStates() const;
    // Control thread: the chain as specs, with every current value, bypass and (optional) state, so a
    // rebuilt component can take over where this one is.
    std::vector<ComponentSpec> currentSpecs() const;
    bool uses(const std::string& id) const noexcept;
    // Any thread but the audio thread, while the chain plays: component `index`'s latest display block
    // (ModuleProcessor::readDisplay), at most `max` floats; -1 for an index the chain does not have. A rack's child
    // is index + (child + 1) * 65536 (fx-racks; docs/engine.md, Racks).
    int32_t readDisplay(std::size_t index, float* out, uint32_t max) const noexcept;
    // Control thread: the automation table for `lanes` (component lanes of this chain's `layer`;
    // empty for the master). Null when no lane targets the chain.
    // An instrument takes the lanes with target type "instrument" instead.
    std::unique_ptr<ComponentAutomation> automationFor(
        const std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>>& lanes, const std::string& layer) const;
    // A key for the lanes `automationFor` would pick, so an unchanged table is not resent.
    static std::string automationKey(const std::vector<ProjectAutomationLaneSpec>& lanes, const std::string& layer,
                                     const char* targetType = "component");
    std::size_t size() const noexcept { return entries_.size(); }
    // The longest tail any component declares, in frames (kInfiniteTail for an endless one); 0: none.
    uint32_t tailFrames() const noexcept;
    // The delay the components add, in frames: the sum of their declared latencies.
    uint64_t latencyFrames() const noexcept;
    // An estimate of the memory the chain holds, for the project-state budget.
    static uint64_t estimateBytes(std::size_t components, std::size_t parameters) noexcept;

    // Audio thread: runs every component over left/right in place (m <= kMaxFrames). An instrument
    // writes left/right (their input is ignored) from the events in notes(), which it then clears. Lanes are read
    // only while `time->playing` (they hold while stopped); null time: no transport at all. A component that fails a block passes its input through;
    // non-finite output becomes 0. A bypassed component crossfades to its input over 5 ms, then
    // is not run at all. A component that says it has fallen silent (ModuleProcessor::quiet()) sleeps (is
    // not run) until an event or input that is not silent; a declared tail alone never puts one to sleep, so
    // the output doesn't depend on the block size. An instrument's input is its notes: no events, none held.
    void process(float* left, float* right, uint32_t m, double sampleRate, const ChainTime* time) noexcept;
    // Audio thread: clears every component's running state (tails, delay lines), as after activate; a no-op when
    // nothing has run since the last reset (an instrument is reset once when built, A3).
    void reset() noexcept;
    // Audio thread: swaps in a new automation table (or none) and returns the old one to retire.
    ComponentAutomation* swapAutomation(ComponentAutomation* next) noexcept {
        ComponentAutomation* old = automation_;
        automation_ = next;
        return old;
    }

private:
    struct Entry {
        std::string id;
        std::unique_ptr<ModuleProcessor> processor;
        std::vector<ParameterResolver> resolvers;
        std::unique_ptr<std::atomic<uint64_t>[]> held;    // control-thread values, as double bits
        std::unique_ptr<std::atomic<uint32_t>[]> touches; // bumped after `held` by a knob move
        std::vector<uint64_t> seenBits;                   // audio thread: the bits last applied
        std::vector<uint32_t> seenTouch;                  // audio thread: the touch count last applied
        std::vector<std::array<double, kMaxFrames>> samples;
        std::vector<ParameterValue> values;
        std::atomic<bool> bypass{false};
        // Bumped (release) after any value or touch is stored: while it, the lanes and the play state stand still
        // and no parameter ramps, the audio thread keeps last block's values instead of resolving each parameter
        // (Flagship has 209; 2026-11-10 performance pass).
        std::atomic<uint32_t> generation{0};
        uint32_t seenGeneration = ~0u;           // audio thread
        const void* seenLanes = nullptr;         // audio thread: the automation the values were resolved with
        bool seenPlaying = false, dynamic = true;  // audio thread: dynamic: a ramp or a lane moved a value
        bool anyTouched = false;  // audio thread: a resolver may hold a touch (a Play clears them)
        double mix = 1.0;  // audio thread: 1 processing, 0 bypassed, between while crossfading
        // Audio thread: asleep, the component is skipped (its output is silence) until an event or input that
        // is not silent (for an instrument: an event).
        bool asleep = false;
        std::string structure;          // a rack's children (rackStructure; empty for anything else)
        std::unordered_map<std::string_view, int> index;  // parameter id to index (ids live in the descriptor)
        std::unique_ptr<KeyInput> key;  // a keyed effect's sidechain (null: not keyed)
        bool keyEvents = false;         // ... and it takes the key's notes
        bool noteEvents = false;        // per-note FX: it has an event input (its note's events)
    };
    ComponentChain() = default;
    int parameterIndex(const Entry& e, const std::string& id) const noexcept { return parameterIndex(e, std::string_view(id)); }
    int parameterIndex(const Entry& e, std::string_view id) const noexcept;
    // Audio thread: entry `index`'s parameters for this block (lanes, ramps, touches), into e.values.
    void resolveEntry(Entry& e, std::size_t index, uint32_t m, const ChainTime* time, bool playing, bool newPlay) noexcept;
    // Audio thread: e.values with project modulation applied (time->modulation), or e.values itself.
    const ParameterValue* modulated(const Entry& e, std::size_t index, uint32_t m, const ChainTime* time) noexcept;

    enum class Kind : uint8_t { Effects, Instrument, Modulators, NoteEffects };
    static std::unique_ptr<ComponentChain> make(const ModuleRegistry& registry, const std::vector<ComponentSpec>& specs,
                                                double sampleRate, Kind kind, std::string& error);

    std::vector<std::unique_ptr<Entry>> entries_;
    std::unique_ptr<NoteEvents> notes_;  // an instrument's notes; null for an effect chain
    double sampleRate_ = 0;
    ComponentAutomation* automation_ = nullptr;  // owned; swapped and retired by the Engine
    uint64_t playEpoch_ = ~0ull;
    // Reset and not run since (reset() is then a no-op): set by reset(), cleared by process() and runModulator().
    // Owned by whichever thread owns the chain: the control thread while it is built, then the audio thread.
    bool clean_ = false;
    bool modulators_ = false;   // built by buildModulators
    bool modNewPlay_ = false;   // audio thread: beginModulators saw a new Play
    bool noteFx_ = false;       // built by buildNoteEffects
    const VoiceBus* voices_ = nullptr;   // audio thread: an instrument's voice bus for the next process()
    const Event* noteEvents_ = nullptr;  // audio thread: per-note FX events for the next process()
    uint32_t noteEventCount_ = 0;
    std::array<float, kMaxFrames> stageL_{}, stageR_{};
    std::array<double, kMaxFrames> lane_{};
};

}  // namespace caw
