// Project modulation (#161): parsing the modulators and links, their loop edges, and the host that runs modulators on a fixed grid and sums each target's offset.
#include "modulation_links.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <limits>
#include <set>

#include "mod_route.h"
#include "spsc.h"

namespace caw {

namespace {

constexpr uint32_t kRing = 256;  // frames of history and of modulator output kept (>= look-behind + 2 chunks)
static_assert(kRing % kModGridFrames == 0 && kRing >= kModLookBehindFrames + 2 * ComponentChain::kMaxFrames);
constexpr uint32_t kNoteRing = 256;
constexpr uint32_t kCellEvents = 64;
constexpr uint32_t kValueScratch = 8192;   // parameters of the largest component a link may move
constexpr uint32_t kSampleScratch = 32;    // modulated parameters with per-frame values, per component and block
constexpr int64_t kNever = std::numeric_limits<int64_t>::min();

const char* const kTargetTypes[] = {"component", "instrument", "volume", "pan", "send", "modulator", "noteComponent"};

bool targetHasLayer(const std::string& type) { return type != "modulator"; }

int64_t floor16(int64_t t) noexcept {
    const int64_t g = static_cast<int64_t>(kModGridFrames);
    return t >= 0 ? t / g * g : -((-t + g - 1) / g) * g;
}
uint32_t ringAt(int64_t t, uint32_t size) noexcept {
    const int64_t r = t % static_cast<int64_t>(size);
    return static_cast<uint32_t>(r < 0 ? r + size : r);
}

// Modulators in evaluation order: each after every modulator whose links move it (parseModulation refuses loops),
// otherwise in project order.
std::vector<size_t> modulatorOrder(const ProjectSpec& p) {
    const size_t n = p.modulators.size();
    std::map<std::string, size_t> at;
    for (size_t i = 0; i < n; ++i) at.emplace(p.modulators[i].id, i);
    std::vector<std::vector<size_t>> before(n);
    for (const ModLinkSpec& l : p.modulation) {
        if (l.target.type != "modulator") continue;
        auto s = at.find(l.source), t = at.find(l.target.layer);
        if (s != at.end() && t != at.end() && s->second != t->second) before[t->second].push_back(s->second);
    }
    std::vector<size_t> order;
    std::vector<bool> placed(n, false);
    for (bool progress = true; progress;) {
        progress = false;
        for (size_t i = 0; i < n; ++i) {
            if (placed[i]) continue;
            bool ready = true;
            for (size_t b : before[i]) ready = ready && placed[b];
            if (!ready) continue;
            placed[i] = true;
            order.push_back(i);
            progress = true;
        }
    }
    for (size_t i = 0; i < n; ++i)
        if (!placed[i]) order.push_back(i);  // a loop (never parsed): kept, a block late
    return order;
}

}  // namespace

// ---------------------------------------------------------------------------------------------------------------
// Project JSON

bool parseModulation(const Json& root, const ComponentEntryParser& entry, ProjectSpec& out, std::string& error) {
    out.modulators.clear();
    out.modulation.clear();
    if (const Json* mods = root.get("modulators"); mods && mods->type != Json::Type::Null) {
        if (mods->type != Json::Type::Array) {
            error = "modulators must be an array";
            return false;
        }
        if (mods->arr.size() > static_cast<size_t>(kMaxModulators)) {
            error = "a project holds at most " + std::to_string(kMaxModulators) + " modulators";
            return false;
        }
        std::set<std::string> ids;
        for (const Json& j : mods->arr) {
            if (j.type != Json::Type::Object) {
                error = "a modulator must be an object";
                return false;
            }
            ModulatorSpec m;
            m.id = j.string("id");
            if (m.id.empty() || !ids.insert(m.id).second) {
                error = m.id.empty() ? "a modulator needs an id" : "two modulators have the id '" + m.id + "'";
                return false;
            }
            m.name = j.string("name");
            m.layer = j.string("layer");
            m.input = j.string("input");
            const std::string hears = j.string("hears", "notes");
            if (hears != "notes" && hears != "audio" && hears != "both") {
                error = "modulator '" + m.id + "': hears must be \"notes\", \"audio\" or \"both\"";
                return false;
            }
            m.hearsNotes = hears != "audio";
            m.hearsAudio = hears != "notes";
            const std::string tap = j.string("tap", "pre");
            if (tap != "pre" && tap != "post") {
                error = "modulator '" + m.id + "': tap must be \"pre\" or \"post\"";
                return false;
            }
            m.inputPost = tap == "post";
            const Json* c = j.get("component");
            if (!c || (c->type != Json::Type::String && c->type != Json::Type::Object)) {
                error = "modulator '" + m.id + "' needs a component (an id or {\"id\": ...})";
                return false;
            }
            if (!entry(*c, "modulator '" + m.id + "'", m.component, error)) return false;
            out.modulators.push_back(std::move(m));
        }
    }
    if (const Json* links = root.get("modulation"); links && links->type != Json::Type::Null) {
        if (links->type != Json::Type::Array) {
            error = "modulation must be an array of links";
            return false;
        }
        if (links->arr.size() > static_cast<size_t>(kMaxModLinks)) {
            error = "a project holds at most " + std::to_string(kMaxModLinks) + " modulation links";
            return false;
        }
        std::set<uint32_t> ids;
        std::map<std::string, int> perTarget;
        for (const Json& j : links->arr) {
            if (j.type != Json::Type::Object) {
                error = "a modulation link must be an object";
                return false;
            }
            ModLinkSpec l;
            const double id = j.number("id", 0);
            if (!(id >= 1 && id <= 4294967295.0) || id != std::floor(id) || !ids.insert(static_cast<uint32_t>(id)).second) {
                error = "each modulation link needs its own whole-number id from 1";
                return false;
            }
            l.id = static_cast<uint32_t>(id);
            const std::string who = "modulation link " + std::to_string(l.id);
            l.source = j.string("source");
            NoteSource noteSource;
            const bool perNote = noteSourceNamed(l.source, noteSource);  // #127: the slot's own note
            const bool known = perNote || std::any_of(out.modulators.begin(), out.modulators.end(),
                                                      [&](const ModulatorSpec& m) { return m.id == l.source; });
            if (!known) {
                error = who + ": source '" + l.source + "' is not a modulator in the project or a note source";
                return false;
            }
            const double output = j.number("output", 0);
            if (!(output >= 0 && output < ComponentChain::kMaxModulatorOutputs) || output != std::floor(output)) {
                error = who + ": output must be a whole number from 0 to " + std::to_string(ComponentChain::kMaxModulatorOutputs - 1);
                return false;
            }
            l.output = static_cast<uint32_t>(output);
            const Json* t = j.get("target");
            if (!t || t->type != Json::Type::Object) {
                error = who + " needs a target object";
                return false;
            }
            l.target.type = t->string("type");
            l.target.layer = t->string("layer");
            l.target.param = t->string("param");
            const double index = t->number("index", -1);
            l.target.index = index >= 0 && index < 1e6 && index == std::floor(index) ? static_cast<int>(index) : -1;
            const std::string& type = l.target.type;
            if (std::none_of(std::begin(kTargetTypes), std::end(kTargetTypes), [&](const char* x) { return type == x; })) {
                error = who + ": target type must be component, instrument, noteComponent, volume, pan, send or modulator";
                return false;
            }
            if (perNote && type != "noteComponent") {
                error = who + ": a note source ('" + l.source + "') moves only a per-note component (target type noteComponent)";
                return false;
            }
            if (perNote && l.output != 0) {
                error = who + ": a note source has one output (0)";
                return false;
            }
            const bool needsParam = type == "component" || type == "instrument" || type == "modulator" || type == "noteComponent";
            if (needsParam && l.target.param.empty()) {
                error = who + ": its target needs a param";
                return false;
            }
            if ((type == "component" || type == "send" || type == "noteComponent") && l.target.index < 0) {
                error = who + ": its target needs an index";
                return false;
            }
            if (type == "send" && l.target.index >= kMaxSends) {
                error = who + ": a layer has at most " + std::to_string(kMaxSends) + " sends";
                return false;
            }
            if (type != "component" && l.target.layer.empty()) {
                error = who + ": its target needs a layer" + (type == "modulator" ? " (the modulator's id)" : "");
                return false;
            }
            if (targetHasLayer(type) && !l.target.layer.empty() &&
                std::none_of(out.layers.begin(), out.layers.end(), [&](const LayerSpec& x) { return x.id == l.target.layer; })) {
                error = who + ": layer '" + l.target.layer + "' is not in the project";
                return false;
            }
            if (type == "modulator" &&
                std::none_of(out.modulators.begin(), out.modulators.end(), [&](const ModulatorSpec& m) { return m.id == l.target.layer; })) {
                error = who + ": '" + l.target.layer + "' is not a modulator in the project";
                return false;
            }
            const double amount = j.number("amount", 0);
            l.amount = std::isfinite(amount) ? std::clamp(amount, -1.0, 1.0) : 0.0;
            l.bipolar = j.boolean("bipolar", false);
            const double curve = j.number("curve", 0);
            l.curve = std::isfinite(curve) ? std::clamp(curve, -1.0, 1.0) : 0.0;
            const std::string key = type + "\x1f" + l.target.layer + "\x1f" + std::to_string(l.target.index) + "\x1f" + l.target.param;
            if (++perTarget[key] > kMaxLinksPerTarget) {
                error = who + ": a target takes at most " + std::to_string(kMaxLinksPerTarget) + " links";
                return false;
            }
            out.modulation.push_back(std::move(l));
        }
    }
    // Modulators moving each other: refused in a loop (one would have to hear the other before it has run).
    const size_t n = out.modulators.size();
    std::map<std::string, size_t> at;
    for (size_t i = 0; i < n; ++i) at.emplace(out.modulators[i].id, i);
    std::vector<std::vector<size_t>> edges(n);
    for (const ModLinkSpec& l : out.modulation)
        if (l.target.type == "modulator") edges[at.at(l.source)].push_back(at.at(l.target.layer));
    std::vector<uint8_t> state(n, 0);
    std::function<bool(size_t, std::string&)> visit = [&](size_t x, std::string& path) {
        state[x] = 1;
        for (size_t y : edges[x]) {
            if (state[y] == 1) {
                path = "'" + out.modulators[x].id + "' -> '" + out.modulators[y].id + "'";
                return false;
            }
            if (state[y] == 0 && !visit(y, path)) return false;
        }
        state[x] = 2;
        return true;
    };
    for (size_t i = 0; i < n; ++i) {
        std::string path;
        if (state[i] == 0 && !visit(i, path)) {
            error = "modulation makes a loop: " + path + " (a modulator can't move itself, even through others)";
            return false;
        }
    }
    return true;
}

bool modulationEdges(const ProjectSpec& p, const std::map<std::string, size_t>& index,
                     std::vector<std::vector<size_t>>& edges, std::string& error) {
    std::map<std::string, size_t> at;
    for (size_t i = 0; i < p.modulators.size(); ++i) at.emplace(p.modulators[i].id, i);
    for (const ModulatorSpec& m : p.modulators) {
        if (m.input.empty()) continue;
        auto in = index.find(m.input);
        if (in == index.end()) {
            error = "modulator '" + m.id + "' hears '" + m.input + "', which is not in the project";
            return false;
        }
        if (!m.hearsAudio) continue;
        // Every layer this modulator's links reach, through other modulators too.
        std::set<std::string> seen{m.id};
        std::vector<std::string> todo{m.id};
        std::set<std::string> layers;
        while (!todo.empty()) {
            const std::string s = todo.back();
            todo.pop_back();
            for (const ModLinkSpec& l : p.modulation) {
                if (l.source != s) continue;
                if (l.target.type == "modulator") {
                    if (seen.insert(l.target.layer).second) todo.push_back(l.target.layer);
                } else if (!l.target.layer.empty()) {
                    layers.insert(l.target.layer);
                }
            }
        }
        for (const std::string& y : layers) {
            auto to = index.find(y);
            if (to == index.end()) continue;
            if (to->second == in->second) {
                error = "modulator '" + m.id + "' hears '" + m.input + "' and moves it: a layer can't hear itself";
                return false;
            }
            edges[in->second].push_back(to->second);
        }
    }
    return true;
}

// ---------------------------------------------------------------------------------------------------------------
// Per-note sources (#127 step 5).

bool noteSourceNamed(const std::string& source, NoteSource& out) noexcept {
    static const struct {
        const char* name;
        NoteSource source;
    } kNames[] = {{"note.pitch", NoteSource::Pitch},       {"note.velocity", NoteSource::Velocity},
                  {"note.pressure", NoteSource::Pressure}, {"note.timbre", NoteSource::Timbre},
                  {"note.gate", NoteSource::Gate},         {"note.age", NoteSource::Age}};
    for (const auto& n : kNames)
        if (source == n.name) {
            out = n.source;
            return true;
        }
    return false;
}

double noteSourceValue(NoteSource source, const NoteSourceState& s, double sampleRate) noexcept {
    double v = 0.0;
    switch (source) {
        case NoteSource::Pitch: v = s.pitch / 127.0; break;
        case NoteSource::Velocity: v = s.velocity; break;
        case NoteSource::Pressure: v = s.pressure; break;
        case NoteSource::Timbre: v = s.timbre; break;
        case NoteSource::Gate: v = s.gate ? 1.0 : 0.0; break;
        case NoteSource::Age: v = static_cast<double>(s.age) / (kNoteAgeSeconds * sampleRate); break;
    }
    return std::isfinite(v) ? std::clamp(v, 0.0, 1.0) : 0.0;
}

std::vector<NoteLink> noteLinksFor(const ProjectSpec& p, const std::string& layer, const ComponentChain& slot,
                                   std::vector<std::string>& warnings) {
    std::vector<NoteLink> out;
    for (const ModLinkSpec& l : p.modulation) {
        NoteSource source;
        if (l.target.type != "noteComponent" || l.target.layer != layer || !noteSourceNamed(l.source, source)) continue;
        const int param = l.target.index >= 0 ? slot.parameterIndexOf(static_cast<size_t>(l.target.index), l.target.param) : -1;
        const ModuleDescriptor* d = l.target.index >= 0 ? slot.descriptorOf(static_cast<size_t>(l.target.index)) : nullptr;
        if (param < 0 || !d) {
            warnings.push_back("modulation link " + std::to_string(l.id) + ": '" + layer + "' has no per-note component " +
                               std::to_string(l.target.index) + " with a parameter '" + l.target.param + "'");
            continue;
        }
        if (!d->parameters[param].modulatable) continue;
        NoteLink n;
        n.id = l.id;
        n.source = source;
        n.entry = static_cast<uint32_t>(l.target.index);
        n.param = static_cast<uint32_t>(param);
        n.amount = l.amount;
        n.bipolar = l.bipolar;
        n.curve = l.curve;
        out.push_back(n);
    }
    // Grouped by target, in id order within each (links into one target add up in id order).
    std::stable_sort(out.begin(), out.end(), [](const NoteLink& a, const NoteLink& b) {
        if (a.entry != b.entry) return a.entry < b.entry;
        if (a.param != b.param) return a.param < b.param;
        return a.id < b.id;
    });
    if (out.size() > static_cast<size_t>(kMaxNoteLinks)) {
        warnings.push_back("'" + layer + "': per-note FX take at most " + std::to_string(kMaxNoteLinks) + " note-source links");
        out.resize(static_cast<size_t>(kMaxNoteLinks));
    }
    return out;
}

// ---------------------------------------------------------------------------------------------------------------
// The volume fader's taper (app/lib/ui/volume_fader.dart VolumeTaper): dB = 20 k log10(p / 0.75), +12 dB at p = 1.

namespace {
constexpr double kZeroAt = 0.75;
const double kTaperK = 12.0 / (20.0 * std::log10(1.0 / kZeroAt));
}  // namespace

double faderPosition(double gain) noexcept {
    if (!(gain > 0.0) || !std::isfinite(gain)) return 0.0;
    return std::clamp(kZeroAt * detPow(std::min(gain, kMaxMixGain), 1.0 / kTaperK), 0.0, 1.0);
}

double faderGain(double position) noexcept {
    const double p = std::isfinite(position) ? std::clamp(position, 0.0, 1.0) : 0.0;
    return p <= 0.0 ? 0.0 : std::min(kMaxMixGain, detPow(p / kZeroAt, kTaperK));
}

// ---------------------------------------------------------------------------------------------------------------
// The host

// The modulators themselves and what they heard: kept across project updates that don't change which modulators
// there are, what they are and what they hear.
struct ModulationRuntime {
    std::string key;
    std::unique_ptr<ComponentChain> chain;
    std::vector<std::string> ids;
    std::vector<uint32_t> firstOut, outCount;
    std::vector<int> input;  // per modulator: its input record, -1 none
    std::vector<uint8_t> takesNotes, takesAudio;
    uint32_t totalOuts = 0;
    std::vector<float> ring;  // totalOuts x kRing, by the time the value applies
    struct Input {
        int slot = -1;
        bool post = false, notes = false, audio = false;
        std::vector<float> l, r;
        std::vector<int64_t> stamp;
        std::vector<Event> events;
        std::vector<int64_t> eventAt;
        uint32_t head = 0;
    };
    std::vector<Input> inputs;
    std::unique_ptr<std::atomic<float>[]> published;
    // Audio thread.
    bool started = false;
    int64_t clock0 = 0, nextCell = 0;

    void clearHistory() noexcept {
        std::fill(ring.begin(), ring.end(), 0.0f);
        for (Input& in : inputs) {
            std::fill(in.l.begin(), in.l.end(), 0.0f);
            std::fill(in.r.begin(), in.r.end(), 0.0f);
            std::fill(in.stamp.begin(), in.stamp.end(), kNever);
            std::fill(in.eventAt.begin(), in.eventAt.end(), kNever);
            in.head = 0;
        }
    }
};

struct ModulationPlan {
    std::shared_ptr<ModulationRuntime> rt;
    double sampleRate = 48000.0;
    struct Link {
        uint32_t id = 0, out = 0;
        bool bipolar = false;
        double curve = 0.0;
    };
    std::vector<Link> links;
    std::unique_ptr<std::atomic<double>[]> amounts;
    enum class Type : uint8_t { Param, Volume, Pan, Send };
    struct Dest {
        Type type = Type::Param;
        ModChainKind kind = ModChainKind::Inserts;
        int slot = -1;
        uint32_t entry = 0;
        std::string param;
        int paramIndex = -1;  // a modulator's parameter (resolved at update)
        int send = -1;
        uint32_t first = 0, count = 0;  // its links
        // Audio thread.
        const ComponentChain* cache[3] = {nullptr, nullptr, nullptr};
        int cacheParam[3] = {-1, -1, -1};
        float offset[ComponentChain::kMaxFrames] = {};
    };
    std::vector<Dest> dests;
    std::vector<uint32_t> chainDests, mixDests;          // indices into dests
    std::vector<std::vector<uint32_t>> modDests;         // per modulator (evaluation order)
    std::vector<uint32_t> linkDest;                      // per link
    std::unique_ptr<std::atomic<float>[]> destPublished;
    std::vector<ChainModulation::Binding> bindings[3];  // [2]: a layer's per-note FX (#127), read inside its instrument
    ChainModulation cm[3];
    std::vector<ParameterValue> values;
    std::vector<double> samples;
    float aL[kModGridFrames] = {}, aR[kModGridFrames] = {};
    Event cellEvents[kCellEvents] = {};

    double destAt(const Dest& d, int64_t t) const noexcept {
        const ModulationRuntime& r = *rt;
        const uint32_t at = ringAt(t, kRing);
        double sum = 0.0;
        for (uint32_t k = d.first; k < d.first + d.count; ++k) {
            const Link& l = links[k];
            const double u = r.ring[static_cast<size_t>(l.out) * kRing + at];
            sum += modRouteOffset(modCurve(u, l.curve), amounts[k].load(std::memory_order_relaxed), l.bipolar);
        }
        return sum;
    }
};

struct ModulationHost::Retire {
    Spsc<ModulationPlan*, 64> queue;
    ModulationPlan* waiting = nullptr;  // audio thread: a new plan held back while the queue was full
};

ModulationHost::ModulationHost() : retire_(std::make_unique<Retire>()) {}

ModulationHost::~ModulationHost() {
    drain();
    delete next_.exchange(nullptr);
    if (retire_->waiting != cur_) delete retire_->waiting;
    delete cur_;
}

void ModulationHost::drain() noexcept {
    ModulationPlan* p = nullptr;
    while (retire_->queue.pop(p)) delete p;
}

std::string ModulationHost::update(const ModuleRegistry& registry, const ProjectSpec& p, double sampleRate,
                                   const LayerLookup& layers, std::vector<std::string>& warnings) {
    drain();
    if (p.modulators.empty() && p.modulation.empty() && !ctl_) return "";
    auto plan = std::make_unique<ModulationPlan>();
    plan->sampleRate = sampleRate;
    // Which modulators run, in evaluation order (a missing or wrong component is left out with a warning).
    std::vector<size_t> order;
    for (size_t i : modulatorOrder(p)) {
        const ModulatorSpec& m = p.modulators[i];
        const ModuleDescriptor* d = registry.find(m.component.id);
        if (!d) {
            warnings.push_back("modulator '" + m.id + "': '" + m.component.id + "' is not loaded");
            continue;
        }
        if (!ComponentChain::isModulator(*d)) {
            warnings.push_back("modulator '" + m.id + "': '" + m.component.id + "' has no modulation outputs");
            continue;
        }
        order.push_back(i);
    }
    std::string key;
    std::vector<ComponentSpec> specs;
    std::vector<int> inputSlot;
    for (size_t i : order) {
        const ModulatorSpec& m = p.modulators[i];
        int slot = -1;
        if (!m.input.empty()) {
            slot = layers(m.input).slot;
            if (slot < 0) warnings.push_back("modulator '" + m.id + "': '" + m.input + "' isn't playing, so it hears nothing");
        }
        inputSlot.push_back(slot);
        key += m.id + "\x1f" + m.component.id + "\x1f" + std::to_string(slot) + (m.inputPost ? "p" : "") +
               (m.hearsNotes ? "n" : "") + (m.hearsAudio ? "a" : "") + "\x1e";
        specs.push_back(m.component);
    }
    std::shared_ptr<ModulationRuntime> rt;
    if (ctl_ && ctl_->rt && ctl_->rt->key == key) {
        rt = ctl_->rt;  // the same modulators: they keep running and take the new values
        rt->chain->setValues(specs);
    } else {
        rt = std::make_shared<ModulationRuntime>();
        rt->key = key;
        if (!specs.empty()) {
            std::string error;
            rt->chain = ComponentChain::buildModulators(registry, specs, sampleRate, error);
            if (!rt->chain) {
                warnings.push_back("modulators: " + error);
                rt->key.clear();
                order.clear();
                inputSlot.clear();
            }
        }
        for (size_t j = 0; j < order.size(); ++j) {
            const ModulatorSpec& m = p.modulators[order[j]];
            rt->ids.push_back(m.id);
            rt->firstOut.push_back(rt->totalOuts);
            const uint32_t outs = rt->chain->modulatorOutputs(j);
            rt->outCount.push_back(outs);
            rt->totalOuts += outs;
            rt->takesNotes.push_back(rt->chain->modulatorTakesNotes(j) && m.hearsNotes);
            rt->takesAudio.push_back(rt->chain->modulatorTakesAudio(j) && m.hearsAudio);
            int input = -1;
            if (inputSlot[j] >= 0 && (rt->takesNotes.back() || rt->takesAudio.back())) {
                for (size_t k = 0; k < rt->inputs.size(); ++k)
                    if (rt->inputs[k].slot == inputSlot[j] && rt->inputs[k].post == m.inputPost) input = static_cast<int>(k);
                if (input < 0) {
                    ModulationRuntime::Input in;
                    in.slot = inputSlot[j];
                    in.post = m.inputPost;
                    in.l.assign(kRing, 0.0f);
                    in.r.assign(kRing, 0.0f);
                    in.stamp.assign(kRing, kNever);
                    in.events.assign(kNoteRing, Event{});
                    in.eventAt.assign(kNoteRing, kNever);
                    rt->inputs.push_back(std::move(in));
                    input = static_cast<int>(rt->inputs.size() - 1);
                }
                rt->inputs[static_cast<size_t>(input)].notes |= rt->takesNotes.back() != 0;
                rt->inputs[static_cast<size_t>(input)].audio |= rt->takesAudio.back() != 0;
            }
            rt->input.push_back(input);
        }
        rt->ring.assign(static_cast<size_t>(rt->totalOuts) * kRing, 0.0f);
        rt->published = std::make_unique<std::atomic<float>[]>(std::max<uint32_t>(1, rt->totalOuts));
    }
    // Links, grouped by target, in id order within each.
    std::map<std::string, size_t> at;
    for (size_t j = 0; j < rt->ids.size(); ++j) at.emplace(rt->ids[j], j);
    struct Pending {
        ModulationPlan::Dest dest;
        std::vector<const ModLinkSpec*> links;
    };
    std::map<std::string, Pending> byTarget;
    for (const ModLinkSpec& l : p.modulation) {
        const std::string who = "modulation link " + std::to_string(l.id);
        auto s = at.find(l.source);
        if (s == at.end()) continue;  // its modulator was left out (warned above)
        if (l.output >= rt->outCount[s->second]) {
            warnings.push_back(who + ": '" + l.source + "' has no output " + std::to_string(l.output));
            continue;
        }
        ModulationPlan::Dest d;
        const std::string& type = l.target.type;
        if (type == "modulator") {
            auto t = at.find(l.target.layer);
            if (t == at.end()) continue;
            d.kind = ModChainKind::Modulators;
            d.entry = static_cast<uint32_t>(t->second);
            d.paramIndex = rt->chain->parameterIndexOf(t->second, l.target.param);
            if (d.paramIndex < 0) {
                warnings.push_back(who + ": '" + l.target.layer + "' has no parameter '" + l.target.param + "'");
                continue;
            }
        } else {
            const LayerInfo li = layers(l.target.layer);
            const bool master = l.target.layer.empty();
            if (!master && li.slot < 0) {
                warnings.push_back(who + ": '" + l.target.layer + "' isn't playing");
                continue;
            }
            d.slot = master ? -1 : li.slot;
            if (type == "component" || type == "instrument" || type == "noteComponent") {
                const bool note = type == "noteComponent";  // #127: every slot of the layer's per-note FX
                d.kind = type == "instrument" ? ModChainKind::Instrument : note ? ModChainKind::NoteFx
                       : master ? ModChainKind::Master : ModChainKind::Inserts;
                d.entry = type == "instrument" ? 0u : static_cast<uint32_t>(l.target.index);
                const ComponentChain* c = type == "instrument" ? li.instrument : note ? li.noteFx : li.inserts;
                if (!c || c->parameterIndexOf(d.entry, l.target.param) < 0) {
                    warnings.push_back(who + ": " + (master ? std::string("the master") : "'" + l.target.layer + "'") +
                                       " has no " + (type == "instrument" ? "instrument"
                                                     : (note ? "per-note component " : "component ") + std::to_string(d.entry)) +
                                       " with a parameter '" + l.target.param + "'");
                    continue;
                }
                d.param = l.target.param;
            } else if (type == "volume") {
                d.type = ModulationPlan::Type::Volume;
            } else if (type == "pan") {
                d.type = ModulationPlan::Type::Pan;
            } else {
                d.type = ModulationPlan::Type::Send;
                d.send = l.target.index;
                if (d.send >= li.sends) {
                    warnings.push_back(who + ": '" + l.target.layer + "' has no send " + std::to_string(d.send));
                    continue;
                }
            }
        }
        const std::string k = std::to_string(static_cast<int>(d.type)) + "\x1f" + std::to_string(static_cast<int>(d.kind)) +
                              "\x1f" + std::to_string(d.slot) + "\x1f" + std::to_string(d.entry) + "\x1f" +
                              std::to_string(d.send) + "\x1f" + l.target.param;
        Pending& pending = byTarget[k];
        if (pending.links.empty()) pending.dest = std::move(d);
        pending.links.push_back(&l);
    }
    plan->modDests.resize(rt->ids.size());
    for (auto& [k, pending] : byTarget) {
        std::sort(pending.links.begin(), pending.links.end(), [](const ModLinkSpec* a, const ModLinkSpec* b) { return a->id < b->id; });
        ModulationPlan::Dest d = std::move(pending.dest);
        d.first = static_cast<uint32_t>(plan->links.size());
        d.count = static_cast<uint32_t>(pending.links.size());
        const uint32_t di = static_cast<uint32_t>(plan->dests.size());
        for (const ModLinkSpec* l : pending.links) {
            const uint32_t src = static_cast<uint32_t>(at.at(l->source));
            plan->links.push_back({l->id, rt->firstOut[src] + l->output, l->bipolar, l->curve});
            plan->linkDest.push_back(di);
        }
        if (d.kind == ModChainKind::Modulators && d.type == ModulationPlan::Type::Param) plan->modDests[d.entry].push_back(di);
        else if (d.type == ModulationPlan::Type::Param) plan->chainDests.push_back(di);
        else plan->mixDests.push_back(di);
        plan->dests.push_back(std::move(d));
    }
    plan->amounts = std::make_unique<std::atomic<double>[]>(std::max<size_t>(1, plan->links.size()));
    for (size_t k = 0; k < plan->links.size(); ++k) {
        const uint32_t id = plan->links[k].id;
        for (const ModLinkSpec& l : p.modulation)
            if (l.id == id) plan->amounts[k].store(l.amount, std::memory_order_relaxed);
    }
    plan->destPublished = std::make_unique<std::atomic<float>[]>(std::max<size_t>(1, plan->dests.size()));
    for (auto& b : plan->bindings) b.resize(std::max<size_t>(1, plan->dests.size()));
    plan->values.resize(kValueScratch);
    plan->samples.resize(static_cast<size_t>(kSampleScratch) * ComponentChain::kMaxFrames);
    for (int w = 0; w < 3; ++w) {
        ChainModulation& cm = plan->cm[w];
        cm.bindings = plan->bindings[w].data();
        cm.values = plan->values.data();
        cm.valueCapacity = kValueScratch;
        cm.samples = plan->samples.data();
        cm.sampleBuffers = kSampleScratch;
    }
    plan->rt = std::move(rt);
    ModulationPlan* sent = plan.release();
    ctl_ = sent;
    // The audio thread takes it at its next chunk; one it never took is freed here.
    delete next_.exchange(sent, std::memory_order_acq_rel);
    return "";
}

bool ModulationHost::setModulatorParam(const std::string& id, const std::string& param, double value) {
    if (!ctl_ || !ctl_->rt->chain) return false;
    for (size_t j = 0; j < ctl_->rt->ids.size(); ++j)
        if (ctl_->rt->ids[j] == id) return ctl_->rt->chain->setValue(j, param, value);
    return false;
}

bool ModulationHost::setModulatorBypass(const std::string& id, bool bypass) {
    if (!ctl_ || !ctl_->rt->chain) return false;
    for (size_t j = 0; j < ctl_->rt->ids.size(); ++j)
        if (ctl_->rt->ids[j] == id) return ctl_->rt->chain->setBypass(j, bypass);
    return false;
}

bool ModulationHost::setLinkAmount(uint32_t linkId, double amount) {
    if (!ctl_ || !std::isfinite(amount)) return false;
    for (size_t k = 0; k < ctl_->links.size(); ++k)
        if (ctl_->links[k].id == linkId) {
            ctl_->amounts[k].store(std::clamp(amount, -1.0, 1.0), std::memory_order_relaxed);
            return true;
        }
    return false;
}

int32_t ModulationHost::outputs(const std::string& id, float* out, int32_t max) const {
    if (!ctl_) return -1;
    const ModulationRuntime& r = *ctl_->rt;
    for (size_t j = 0; j < r.ids.size(); ++j) {
        if (r.ids[j] != id) continue;
        const int32_t n = static_cast<int32_t>(r.outCount[j]);
        for (int32_t k = 0; k < n && k < max; ++k) out[k] = r.published[r.firstOut[j] + k].load(std::memory_order_relaxed);
        return std::min(n, max);
    }
    return -1;
}

bool ModulationHost::linkOffset(uint32_t linkId, float& out) const {
    if (!ctl_) return false;
    for (size_t k = 0; k < ctl_->links.size(); ++k)
        if (ctl_->links[k].id == linkId) {
            out = ctl_->destPublished[ctl_->linkDest[k]].load(std::memory_order_relaxed);
            return true;
        }
    return false;
}

// ---- audio thread ----

void ModulationHost::beginChunk(uint32_t m, int64_t songSample, double stepLength, double tempo, uint32_t beatsPerBar,
                                bool playing, uint64_t playEpoch, int64_t chunk) noexcept {
    if (m == 0 || m > ComponentChain::kMaxFrames) return;
    // A new plan: the old one goes back to the control thread (or, the queue full, the swap waits a chunk).
    ModulationPlan* incoming = retire_->waiting ? retire_->waiting : next_.exchange(nullptr, std::memory_order_acq_rel);
    retire_->waiting = nullptr;
    if (incoming) {
        if (!cur_ || retire_->queue.push(cur_)) cur_ = incoming;
        else retire_->waiting = incoming;
    }
    if (!cur_) return;
    ModulationPlan& p = *cur_;
    ModulationRuntime& r = *p.rt;
    const bool play = playing && (!epochSeen_ || playEpoch != epoch_);
    if (play) {  // Play: every modulator starts again from the grid's 0, so playback matches an export
        epoch_ = playEpoch;
        epochSeen_ = true;
        clockNext_ = 0;
        if (r.chain) r.chain->reset();
        r.clearHistory();
        r.started = false;
    }
    if (!r.started) {  // new modulators (or Play): they join the grid where it is
        r.started = true;
        r.nextCell = floor16(clockNext_) - static_cast<int64_t>(kModLookBehindFrames);
    }
    const int64_t clock0 = clockNext_;
    r.clock0 = clock0;
    clockNext_ += m;
    // Modulator blocks that are due: each heard what was played up to its end and applies a look-behind later.
    if (r.chain) {
        const int64_t due = clock0 - static_cast<int64_t>(kModGridFrames);
        if (due - r.nextCell > static_cast<int64_t>(kRing)) r.nextCell = floor16(due) - static_cast<int64_t>(kRing);  // never expected
        for (; r.nextCell <= due; r.nextCell += kModGridFrames) {
            const int64_t g = r.nextCell, tA = g + kModLookBehindFrames;
            ChainTime ct;
            ct.start = std::max<int64_t>(0, songSample + (tA - clock0));
            ct.stepLength = stepLength > 0 ? stepLength : 1.0;
            ct.playEpoch = playEpoch;
            ct.tempo = tempo;
            ct.beatsPerBar = beatsPerBar;
            ct.playing = playing;
            ct.chunk = chunk;
            r.chain->beginModulators(&ct);
            const uint32_t at = ringAt(tA, kRing);
            for (size_t j = 0; j < r.ids.size(); ++j) {
                ChainModulation& cm = p.cm[0];
                cm.count = 0;
                for (uint32_t di : p.modDests[j]) {
                    ModulationPlan::Dest& d = p.dests[di];
                    const float v = static_cast<float>(p.destAt(d, tA));
                    std::fill_n(d.offset, kModGridFrames, v);
                    p.bindings[0][cm.count++] = {static_cast<uint32_t>(j), static_cast<uint32_t>(d.paramIndex), d.offset};
                }
                ct.modulation = cm.count ? &cm : nullptr;
                const float* inL = nullptr;
                const float* inR = nullptr;
                const Event* events = nullptr;
                uint32_t eventCount = 0;
                if (const int ii = r.input[j]; ii >= 0) {
                    const ModulationRuntime::Input& in = r.inputs[static_cast<size_t>(ii)];
                    if (r.takesAudio[j]) {
                        for (uint32_t i = 0; i < kModGridFrames; ++i) {
                            const uint32_t k = ringAt(g + i, kRing);
                            const bool fresh = in.stamp[k] == g + static_cast<int64_t>(i);
                            p.aL[i] = fresh ? in.l[k] : 0.0f;
                            p.aR[i] = fresh ? in.r[k] : 0.0f;
                        }
                        inL = p.aL;
                        inR = p.aR;
                    }
                    if (r.takesNotes[j]) {
                        for (uint32_t k = 0; k < kNoteRing && eventCount < kCellEvents; ++k) {
                            const int64_t t = in.eventAt[k];
                            if (t < g || t >= g + static_cast<int64_t>(kModGridFrames)) continue;
                            Event e = in.events[k];
                            e.frame = static_cast<uint32_t>(t - g);
                            // In frame order, ties in the order they arrived.
                            uint32_t pos = eventCount;
                            while (pos > 0 && p.cellEvents[pos - 1].frame > e.frame) {
                                p.cellEvents[pos] = p.cellEvents[pos - 1];
                                --pos;
                            }
                            p.cellEvents[pos] = e;
                            ++eventCount;
                        }
                        events = p.cellEvents;
                    }
                }
                float* outs[ComponentChain::kMaxModulatorOutputs] = {};
                const uint32_t n = r.outCount[j];
                for (uint32_t k = 0; k < n; ++k) outs[k] = r.ring.data() + static_cast<size_t>(r.firstOut[j] + k) * kRing + at;
                r.chain->runModulator(j, kModGridFrames, p.sampleRate, &ct, events, eventCount, inL, inR, outs, n);
            }
        }
    }
    // Every target's offset per frame: worked out on the grid and drawn straight between its points.
    const int64_t g0 = floor16(clock0);
    const uint32_t points = static_cast<uint32_t>((clock0 + m - g0 + kModGridFrames - 1) / kModGridFrames) + 1;
    double grid[ComponentChain::kMaxFrames / kModGridFrames + 2];
    for (ModulationPlan::Dest& d : p.dests) {
        if (d.kind == ModChainKind::Modulators && d.type == ModulationPlan::Type::Param) continue;
        for (uint32_t k = 0; k < points; ++k) grid[k] = p.destAt(d, g0 + static_cast<int64_t>(k) * kModGridFrames);
        for (uint32_t i = 0; i < m; ++i) {
            const int64_t t = clock0 + i;
            const uint32_t k = static_cast<uint32_t>((t - g0) / kModGridFrames);
            const double w = static_cast<double>((t - g0) % kModGridFrames) / kModGridFrames;
            d.offset[i] = static_cast<float>(grid[k] + (grid[k + 1] - grid[k]) * w);
        }
    }
    const uint32_t now = ringAt(clock0, kRing);
    for (uint32_t o = 0; o < r.totalOuts; ++o)
        r.published[o].store(r.ring[static_cast<size_t>(o) * kRing + now], std::memory_order_relaxed);
    for (size_t k = 0; k < p.dests.size(); ++k) {
        p.destPublished[k].store(p.dests[k].offset[0], std::memory_order_relaxed);
    }
}

const ChainModulation* ModulationHost::forChain(int slot, ModChainKind kind, const ComponentChain* chain, int which) noexcept {
    if (!cur_ || !chain || which < 0 || which > 2 || cur_->chainDests.empty()) return nullptr;
    ModulationPlan& p = *cur_;
    ChainModulation& cm = p.cm[which];
    cm.count = 0;
    for (uint32_t di : p.chainDests) {
        ModulationPlan::Dest& d = p.dests[di];
        if (d.kind != kind || (kind != ModChainKind::Master && d.slot != slot)) continue;
        if (d.cache[which] != chain) {
            d.cache[which] = chain;
            d.cacheParam[which] = chain->parameterIndexOf(d.entry, d.param);
        }
        if (d.cacheParam[which] < 0) continue;
        p.bindings[which][cm.count++] = {d.entry, static_cast<uint32_t>(d.cacheParam[which]), d.offset};
    }
    return cm.count ? &cm : nullptr;
}

namespace {
const float* mixOffset(const ModulationPlan* p, int slot, ModulationPlan::Type type, int send) noexcept {
    if (!p) return nullptr;
    for (uint32_t di : p->mixDests) {
        const ModulationPlan::Dest& d = p->dests[di];
        if (d.type == type && d.slot == slot && (type != ModulationPlan::Type::Send || d.send == send)) return d.offset;
    }
    return nullptr;
}
}  // namespace

const float* ModulationHost::volume(int slot) const noexcept { return mixOffset(cur_, slot, ModulationPlan::Type::Volume, -1); }
const float* ModulationHost::pan(int slot) const noexcept { return mixOffset(cur_, slot, ModulationPlan::Type::Pan, -1); }
const float* ModulationHost::send(int slot, int index) const noexcept {
    return mixOffset(cur_, slot, ModulationPlan::Type::Send, index);
}

bool ModulationHost::listens(int slot) const noexcept {
    if (!cur_) return false;
    for (const ModulationRuntime::Input& in : cur_->rt->inputs)
        if (in.slot == slot) return true;
    return false;
}

void ModulationHost::tapAudio(int slot, const float* preL, const float* preR, const float* postL, const float* postR,
                              uint32_t m) noexcept {
    if (!cur_ || m > ComponentChain::kMaxFrames) return;
    ModulationRuntime& r = *cur_->rt;
    for (ModulationRuntime::Input& in : r.inputs) {
        if (in.slot != slot || !in.audio) continue;
        const float* l = in.post ? postL : preL;
        const float* rr = in.post ? postR : preR;
        if (!l || !rr) continue;
        for (uint32_t i = 0; i < m; ++i) {
            const int64_t t = r.clock0 + i;
            const uint32_t k = ringAt(t, kRing);
            in.l[k] = l[i];
            in.r[k] = rr[i];
            in.stamp[k] = t;
        }
    }
}

void ModulationHost::tapNotes(int slot, const Event* events, uint32_t count) noexcept {
    if (!cur_ || !events) return;
    ModulationRuntime& r = *cur_->rt;
    for (ModulationRuntime::Input& in : r.inputs) {
        if (in.slot != slot || !in.notes) continue;
        for (uint32_t e = 0; e < count; ++e) {
            const uint32_t k = in.head++ % kNoteRing;
            in.events[k] = events[e];
            in.eventAt[k] = r.clock0 + events[e].frame;
        }
    }
}

}  // namespace caw
