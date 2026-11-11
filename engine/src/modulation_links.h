// Project modulation (#161): the modulators list and links in the project JSON, their loop check, and the host that runs them and moves any knob, volume, pan or send.
#pragma once

#include <atomic>
#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "component_chain.h"
#include "json.h"
#include "module_registry.h"
#include "project.h"

namespace caw {

// Budgets (docs/engine.md, Modulation). A target takes up to kMaxLinksPerTarget links (the resolver's own links
// stop at 8; project links are summed by the host, so this is a CPU budget, not a format limit).
constexpr int kMaxModulators = 64;
constexpr int kMaxModLinks = 256;
constexpr int kMaxLinksPerTarget = 32;
// Modulators run in blocks of kModGridFrames on a grid counted from Play, and their output is applied
// kModLookBehindFrames later (2 ms at 48 kHz): by then every input they read (a track's notes or audio, which
// tracks play anywhere in the mix graph's order) is known, so the result is the same for every buffer size, live
// and offline, and never depends on which track runs first.
constexpr uint32_t kModGridFrames = 16;
constexpr uint32_t kModLookBehindFrames = 96;

// Parses "modulators" and "modulation" (docs/engine.md). `entry` parses a component entry as the project's own
// lists do. Refuses unknown sources, duplicate ids, budgets, and loops between modulators.
using ComponentEntryParser = std::function<bool(const Json&, const std::string&, ComponentSpec&, std::string&)>;
bool parseModulation(const Json& root, const ComponentEntryParser& entry, ProjectSpec& out, std::string& error);
// The routing edges modulation adds for validateRouting: a modulator that hears a layer's audio (a follower) makes
// that layer feed every layer its links reach (directly or through other modulators). Notes make none (a track's
// notes don't depend on its sound). False and a message for a link back to the layer it listens to.
bool modulationEdges(const ProjectSpec& p, const std::map<std::string, size_t>& index,
                     std::vector<std::vector<size_t>>& edges, std::string& error);

// Which chain a parameter link moves.
enum class ModChainKind : uint8_t { Inserts, Instrument, Master, Modulators };

struct ModulationPlan;
struct ModulationRuntime;

// Runs the project's modulators and works out every target's offset for each chunk. The control thread builds a
// plan (update) and hands it over lock-free; the audio thread swaps it in at the next chunk and hands the old one
// back to be freed here. Nothing on the audio thread allocates, locks or blocks.
class ModulationHost {
public:
    ModulationHost();
    ~ModulationHost();
    ModulationHost(const ModulationHost&) = delete;
    ModulationHost& operator=(const ModulationHost&) = delete;

    // What the Engine tells update about a layer (control thread): its slot (-1 not playing), whether it is a bus,
    // and the chains last sent to it (for checking parameter ids; null: none).
    struct LayerInfo {
        int slot = -1;
        bool bus = false;
        int sends = 0;
        const ComponentChain* inserts = nullptr;
        const ComponentChain* instrument = nullptr;
    };
    using LayerLookup = std::function<LayerInfo(const std::string& layerId)>;  // "" is the master

    // Control thread: builds the project's modulators and links and sends them. Modulators with the same ids,
    // components and inputs as the running ones keep running (their phase and state) and only take new values.
    // Problems that leave a link or modulator out are warnings; "" or an error that refuses the whole update.
    std::string update(const ModuleRegistry& registry, const ProjectSpec& p, double sampleRate,
                       const LayerLookup& layers, std::vector<std::string>& warnings);
    // Control thread: frees plans the audio thread handed back.
    void drain() noexcept;
    // Control thread: a knob of a running modulator (ramps; a later project update sets it again).
    bool setModulatorParam(const std::string& id, const std::string& param, double value);
    bool setModulatorBypass(const std::string& id, bool bypass);
    // Control thread: a link's amount while it plays (a ring drag), -1..1.
    bool setLinkAmount(uint32_t linkId, double amount);
    // Any thread: modulator `id`'s outputs at the last chunk (0..1), at most max; -1 for an unknown id.
    int32_t outputs(const std::string& id, float* out, int32_t max) const;
    // Any thread: the target's summed offset (normalized travel) at the last chunk for link target `linkId`'s
    // target; false for an unknown link.
    bool linkOffset(uint32_t linkId, float& out) const;

    // ---- audio thread ----
    // Before the mix graph runs a chunk of m frames (m <= ComponentChain::kMaxFrames): takes a new plan, restarts
    // the modulators at Play, runs every modulator block that is due and works out the chunk's offsets.
    void beginChunk(uint32_t m, int64_t songSample, double stepLength, double tempo, uint32_t beatsPerBar,
                    bool playing, uint64_t playEpoch, int64_t chunk) noexcept;
    // The modulation of chain `chain` of `slot` (-1 the master) for this chunk, or null. `which` (0 or 1) picks
    // the scratch, so a chain and the one it replaces (crossfading) can both be modulated in one chunk.
    const ChainModulation* forChain(int slot, ModChainKind kind, const ComponentChain* chain, int which) noexcept;
    // A layer's volume, pan or send `send` offset per frame this chunk (normalized travel), or null.
    const float* volume(int slot) const noexcept;
    const float* pan(int slot) const noexcept;
    const float* send(int slot, int index) const noexcept;
    // Whether anything listens to `slot` (cheap: call before tapping).
    bool listens(int slot) const noexcept;
    // What a layer played this chunk: its audio after its effects (pre) and after volume and pan (post).
    void tapAudio(int slot, const float* preL, const float* preR, const float* postL, const float* postR,
                  uint32_t m) noexcept;
    // The notes a layer's instrument got this chunk (frames in the chunk; any order).
    void tapNotes(int slot, const Event* events, uint32_t count) noexcept;

private:
    ModulationPlan* cur_ = nullptr;          // audio thread
    std::atomic<ModulationPlan*> next_{nullptr};
    struct Retire;
    std::unique_ptr<Retire> retire_;
    ModulationPlan* ctl_ = nullptr;          // control thread: the newest plan sent (alive until a newer replaces it)
    // Audio thread: the grid's clock (frames since the last Play) and the Play it counts from.
    int64_t clockNext_ = 0;
    uint64_t epoch_ = 0;
    bool epochSeen_ = false;
};

// The volume fader's travel (the app's VolumeTaper: 0 dB three quarters up, +12 dB at the top) for a gain, and back.
double faderPosition(double gain) noexcept;
double faderGain(double position) noexcept;

}  // namespace caw
