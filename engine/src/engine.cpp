// Mixer implementation: the audio-thread render loop and the control-thread project diffing that feeds it.
#include "engine.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstdio>
#include <cmath>
#include <thread>

#include "compile.h"
#include "detmath.h"
#include "json.h"
#include "tables.h"

namespace caw {

// Per-layer audio and meter state. Fields above `vol` belong to the audio thread.
struct Engine::Slot {
    bool active = false;
    bool removing = false;
    bool fresh = true;       // the chain has not played yet since it was installed or play started
    bool contiguous = false; // the previous sample was processed, so a seam can crossfade
    bool overloaded = false;
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

    double exportBuf[kMaxExports][kBlock] = {};  // this layer's exported values for the current chunk
    int64_t visited = -1;                         // chunk id when last processed
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
};

constexpr uint32_t kOrphanNote = 0xFFFFFFFFu;  // a held note whose pattern was edited: ends at offAt

// One layer's modules: the main instances plus shadow copies that play the loop's tail across a seam. A layer
// with a pattern runs its generator as voiceCount voices instead (main[0], shadow[0] and extras), with no seams.
struct Engine::Chain {
    std::vector<std::unique_ptr<Instance>> main, shadow;
    bool voiced = false;
    std::vector<std::unique_ptr<Instance>> extraVoices;
    Voice voices[kMaxVoices];
    int voiceCount = 0;  // voices with an instance: the generator's voices: setting, 2..kMaxVoices
    int64_t noteCount = 0;
    double declick = 0;  // what voices cut short (stolen or ended) were playing; decays over about 2 ms
    double vtb[kBlock], vtime[kBlock], vphase[kBlock], vtrig[kBlock], vgate[kBlock], vnote[kBlock], vfreq[kBlock];
    double vvel[kBlock], vrel[kBlock], vout[kBlock], gen[kBlock];
    double dtrig[kBlock], ones[kBlock], dnote[kBlock], dfreq[kBlock];
    std::vector<std::string> moduleIds;
    // How each module takes over the running state of the chain it replaces, so unchanged calls play on.
    struct Migration {
        int from = -1;                    // module index in the replaced chain
        const Program* expect = nullptr;  // the program the plan was made against
        std::vector<std::array<uint32_t, 3>> ranges;  // (from offset, to offset, count)
    };
    std::vector<Migration> migrate;
    std::vector<std::vector<std::pair<uint16_t, int>>> exportMap;  // per module: (register, export buffer)
    std::vector<std::vector<const double*>> importPtrs;            // per module: one pointer per import
    uint32_t used = 0;
    double layerLen = 1;  // samples in this layer's loop, for pos and phase
    double nb[kBlock], tb[kBlock], stepb[kBlock], beatb[kBlock], barb[kBlock], posb[kBlock], timeb[kBlock];
    double srb[kBlock], rateb[kBlock], bpmb[kBlock], seedb[kBlock], zero[kBlock];
};

struct Engine::Cmd {
    enum Type { Install, SetSteps, SetPattern, Remove, Transport, Play, Stop, AuditionOnly, ClearOverload, SetOrder } type = Play;
    std::shared_ptr<const Pattern>* pattern = nullptr;
    int orderList[kSlots] = {};
    int orderCount = 0;
    int slot = 0;
    Chain* chain = nullptr;
    int steps = 0, order = 0;
    double bpm = 120, master = 0.7;
    int beatsPerBar = 4, loopSteps = 64, keyRoot = 9, keyScale = 1;
    uint32_t seed = 0;
    bool seamXf = true, flag = false;
    int swapMode = 0;
    int voices = kMaxVoices;
};

struct Engine::Retired {
    Chain* chain = nullptr;
    int freedSlot = -1;
    std::shared_ptr<const Pattern>* pattern = nullptr;
};

namespace {

constexpr double kSwapSeconds = 0.02;
constexpr double kSeamSeconds = 0.003;
constexpr double kStopSeconds = 0.01;
constexpr double kGainSeconds = 0.005;
constexpr double kLimitCeiling = 0.977;  // about -0.2 dBFS
constexpr int kPendingMax = 256;
constexpr double kVoiceQuietSeconds = 0.1;   // a released voice ends after this long below -90 dB
constexpr double kVoiceMaxRelease = 10.0;    // or this long after release, whatever its level
constexpr double kQuietLevel = 3.1622776601683795e-5;  // -90 dB
constexpr double kReleaseFade = 0.01;        // code that ignores gate and rel fades out this fast at note-off
constexpr double kDeclickSeconds = 0.002;
constexpr int kMaxSplits = 16;               // note changes that split one block; more start together
constexpr int64_t kMaxTakeOver = 262144;     // state numbers a code swap may copy (2 MB): beyond it, start fresh
constexpr double kC4 = 261.6255653005986;

double mtof(double note) { return 440.0 * detPow(2.0, (note - 69.0) / 12.0); }

// Lets every held note go into its release (at a layer restart, or when the pattern changes).
void releaseVoices(Voice* voices, int count) {
    for (int v = 0; v < count; ++v)
        if (voices[v].active && voices[v].gate) {
            voices[v].gate = false;
            voices[v].rel = 0;
            voices[v].quiet = 0;
        }
}

double bitsToDouble(uint64_t b) { return std::bit_cast<double>(b); }
uint64_t doubleToBits(double d) { return std::bit_cast<uint64_t>(d); }

void storeMax(std::atomic<float>& a, float v) {
    float cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
    }
}

}  // namespace

Engine::Engine(double sampleRate)
    : sr_(sampleRate),
      slots_(new Slot[kSlots]),
      pending_(new Retired[kPendingMax]),
      cmds_(new Spsc<Cmd, 1024>()),
      retired_(new Spsc<Retired, 1024>()),
      masterScope_(new std::atomic<float>[kScopeSize]) {
    for (int i = 0; i < kScopeSize; ++i) masterScope_[i].store(0);
    for (int s = 0; s < kSlots; ++s)
        for (int i = 0; i < kScopeSize; ++i) slots_[s].scope[i].store(0);
    std::fill_n(mixL_, kBlock, 0.0);
    std::fill_n(mixR_, kBlock, 0.0);
    ctlSr_ = sampleRate;
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
    }
    Retired r;
    while (retired_->pop(r)) {
        delete r.chain;
        delete r.pattern;
    }
    for (int i = 0; i < pendingCount_; ++i) {
        delete pending_[i].chain;
        delete pending_[i].pattern;
    }
    for (int s = 0; s < kSlots; ++s) {
        delete slots_[s].cur;
        delete slots_[s].old;
        delete slots_[s].pending;
        delete slots_[s].pattern;
    }
    delete[] pending_;
}

// ===================== control thread =====================

void Engine::drainRetired() {
    Retired r;
    while (retired_->pop(r)) {
        delete r.chain;
        delete r.pattern;
        if (r.freedSlot >= 0) slotBusy_[r.freedSlot] = false;
    }
}

void Engine::send(const Cmd& c) {
    // The audio thread empties the queue every callback; wait briefly if it is full.
    for (int tries = 0; !cmds_->push(c); ++tries) {
        drainRetired();
        if (tries > 2000) {
            if (c.type == Cmd::Install) delete c.chain;  // audio stalled; drop rather than hang the app
            delete c.pattern;
            return;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

int Engine::freeSlot() {
    for (int s = 0; s < kMaxLayers; ++s)
        if (!slotBusy_[s]) {
            slotBusy_[s] = true;
            return s;
        }
    return -1;
}

Engine::Chain* Engine::buildChain(const std::vector<std::string>& ids, const std::vector<const double*>& wiring,
                                  bool voiced, const Chain* prev) {
    auto* c = new Chain();
    c->voiced = voiced;
    int buf = 0;
    size_t w = 0;
    for (size_t i = 0; i < ids.size(); ++i) {
        const ModuleState& m = modules_.at(ids[i]);
        c->main.push_back(std::make_unique<Instance>(m.program));
        c->shadow.push_back(std::make_unique<Instance>(m.program));
        c->moduleIds.push_back(ids[i]);
        c->used |= m.program->usedVars;
        // Export buffers are numbered in chain order; setProject uses the same numbering.
        std::vector<std::pair<uint16_t, int>> exports;
        for (const ExportDef& e : m.program->exports)
            if (buf < kMaxExports) exports.emplace_back(e.reg, buf++);
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
        for (int v = 2; v < c->voiceCount; ++v)
            c->extraVoices.push_back(std::make_unique<Instance>(c->main[0]->programPtr()));
        c->voices[0].inst = c->main[0].get();
        c->voices[1].inst = c->shadow[0].get();
        for (int v = 2; v < c->voiceCount; ++v) c->voices[v].inst = c->extraVoices[static_cast<size_t>(v - 2)].get();
    }
    writeParams(*c);
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
    Slot& s = slots_[slot];
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

std::string Engine::setProject(const ProjectSpec& p) {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();

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
    send(t);
    const double stepLen = 60.0 * ctlSr_ / (p.bpm * 4.0);
    ctlLoopLen_ = static_cast<int64_t>(std::floor(p.loopSteps() * stepLen + 0.5));

    globals_ = p.globals;

    // Project libraries (kind: library) compile first; every other module can call their functions.
    std::vector<std::string_view> moduleSources;
    for (const ModuleSpec& m : p.modules) moduleSources.push_back(m.source);
    const std::vector<LibrarySource> libs = projectLibraries(moduleSources);
    std::string libSig;
    for (const LibrarySource& l : libs) libSig += l.ns + "\x1f" + l.source + "\x1e";

    // Compile changed modules. A module that fails keeps its last good program, so the old sound plays on.
    bool allOk = true;
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
    };
    std::vector<Want> wants;
    int order = 0;
    if (p.auditionOnly) {
        wants.push_back({"\x01audition", p.auditionChain, p.auditionPattern, p.auditionSteps, 0.8, 0.0, false, false, 100000});
    }
    order_.clear();
    for (const LayerSpec& l : p.layers) {
        order_.push_back(l.id);
        wants.push_back({l.id, l.chain, l.pattern, l.lengthSteps, l.volume, l.pan, l.mute, l.solo, ++order});
    }

    // Pass 1: which modules each layer plays, and its slot.
    struct Planned {
        Want w;
        LayerState ls;
        std::vector<std::string> ids;
        std::vector<const Program*> sig;
        std::shared_ptr<const Pattern> pattern;
    };
    std::vector<Planned> plan;
    std::map<std::string, std::vector<std::string>> warnings;
    for (const auto& [id, st] : modules_) {
        if (!st.pattern) continue;
        const int steps = st.pattern->steps(p.beatsPerBar);
        int late = 0;
        for (const PatternNote& n : st.pattern->notes) late += n.at >= steps;
        if (late > 0)
            warnings[id].push_back(std::to_string(late) + " note" + (late == 1 ? " starts" : "s start") +
                                   " after the pattern's length and never play" + (late == 1 ? "s" : ""));
    }
    int64_t projectState = 0;
    for (Want& w : wants) {
        Planned pl{w, {}, {}, {}, nullptr};
        int64_t layerState = 0;
        for (const std::string& id : w.chain) {
            auto it = modules_.find(id);
            if (it == modules_.end() || !it->second.program || it->second.program->kind == ModuleKind::Library) continue;
            pl.ids.push_back(id);
            pl.sig.push_back(it->second.program.get());
            layerState += it->second.program->stateSize;
        }
        // A pattern plays the generator as voices and sets the layer's loop length.
        if (!w.pattern.empty() && !pl.ids.empty()) {
            auto it = modules_.find(w.pattern);
            if (it != modules_.end() && it->second.pattern) {
                pl.pattern = it->second.pattern;
                pl.w.steps = pl.pattern->steps(p.beatsPerBar);
                const Program& gen = *modules_.at(pl.ids.front()).program;
                layerState += static_cast<int64_t>(std::clamp(gen.voices, 2, kMaxVoices) - 1) * gen.stateSize;
            } else {
                warnings[pl.ids.front()].push_back("pattern '" + w.pattern + "' is missing or has an error, so it plays without one");
            }
        }
        // Memory is bounded for the whole project: a layer that would pass the budget stays silent.
        if (!pl.ids.empty() && projectState + layerState > kMaxProjectStateDoubles) {
            warnings[pl.ids.front()].push_back("layer left silent: the project's delays, reverbs and other effects need more than 64 MB");
            pl.ids.clear();
            pl.sig.clear();
        }
        projectState += layerState * !pl.ids.empty();
        auto it = layers_.find(w.id);
        if (it != layers_.end()) {
            pl.ls = it->second;
            layers_.erase(it);
        }
        const bool isAudition = w.id[0] == '\x01';
        if (pl.ids.empty()) {
            if (pl.ls.slot >= 0) {
                Cmd c;
                c.type = Cmd::Remove;
                c.slot = pl.ls.slot;
                send(c);
            }
            continue;
        }
        if (pl.ls.slot < 0) {
            pl.ls.slot = isAudition ? kAuditionSlot : freeSlot();
            if (isAudition) slotBusy_[kAuditionSlot] = true;
            if (pl.ls.slot < 0) continue;  // all slots busy (removals still fading)
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

    // Pass 2: where each exported value lives. The first layer (in project order) playing a module provides it.
    struct Source {
        int slot;
        const double* buf;
    };
    std::map<std::string, Source> sources;
    for (const Planned& pl : plan) {
        if (pl.w.id[0] == '\x01') continue;
        int buf = 0;
        for (const std::string& id : pl.ids) {
            const ModuleState& m = modules_.at(id);
            for (const ExportDef& e : m.program->exports) {
                if (buf >= kMaxExports) break;
                sources.emplace(m.ref + "." + e.name, Source{pl.ls.slot, slots_[pl.ls.slot].exportBuf[buf]});
                ++buf;
            }
        }
    }

    // Pass 3: wire imports, install changed chains, and order layers so exporters run before their readers.
    std::vector<std::vector<int>> readsFrom(kSlots);
    std::map<std::string, LayerState> nextLayers;
    std::vector<int> projectOrder;
    for (Planned& pl : plan) {
        std::vector<const double*> wiring;
        for (const std::string& id : pl.ids)
            for (const std::string& imp : modules_.at(id).program->imports) {
                auto src = sources.find(imp);
                if (src == sources.end()) {
                    wiring.push_back(nullptr);
                    warnings[id].push_back("nothing exports '" + imp + "' (it reads 0)");
                } else {
                    wiring.push_back(src->second.buf);
                    if (src->second.slot != pl.ls.slot) readsFrom[pl.ls.slot].push_back(src->second.slot);
                }
            }
        LayerState& ls = pl.ls;
        const Want& w = pl.w;
        const bool voiced = pl.pattern != nullptr;
        if (w.vol != ls.volume || w.pan != ls.pan || w.mute != ls.mute || w.solo != ls.solo) {
            writeMix(ls.slot, w.vol, w.pan, w.mute, w.solo);
            ls.volume = w.vol;
            ls.pan = w.pan;
            ls.mute = w.mute;
            ls.solo = w.solo;
        }
        if (pl.pattern != ls.pattern) {
            Cmd cmd;
            cmd.type = Cmd::SetPattern;
            cmd.slot = ls.slot;
            cmd.pattern = pl.pattern ? new std::shared_ptr<const Pattern>(pl.pattern) : nullptr;
            send(cmd);
            ls.pattern = pl.pattern;
        }
        if (pl.sig != ls.sig || wiring != ls.wiring || voiced != ls.voiced) {
            Chain* c = buildChain(pl.ids, wiring, voiced, ls.chain);
            Cmd cmd;
            cmd.type = Cmd::Install;
            cmd.slot = ls.slot;
            cmd.chain = c;
            cmd.steps = w.steps;
            cmd.order = w.order;
            send(cmd);
            ls.chain = c;
            ls.voiced = voiced;
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
                send(cmd);
                ls.steps = w.steps;
            }
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
        send(c);
    }
    layers_ = std::move(nextLayers);

    // Dependency order: repeatedly take the first layer (in project order) whose sources are all placed. Layers
    // in a loop are placed last in project order; one side of the loop then hears the other a block late.
    {
        Cmd oc;
        oc.type = Cmd::SetOrder;
        std::vector<bool> placed(kSlots, false);
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
                oc.orderList[oc.orderCount++] = slot;
                progress = true;
            }
        }
        for (int slot : projectOrder)
            if (!placed[slot]) oc.orderList[oc.orderCount++] = slot;
        send(oc);
    }

    Cmd a;
    a.type = Cmd::AuditionOnly;
    a.flag = p.auditionOnly;
    send(a);

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
    return std::string("{\"ok\":") + (allOk ? "true" : "false") + ",\"modules\":{" + mods + "}}";
}

void Engine::setParam(const std::string& moduleId, const std::string& name, double value) {
    std::lock_guard<std::mutex> lock(ctl_);
    auto it = modules_.find(moduleId);
    if (it == modules_.end()) return;
    it->second.params[name] = value;
    for (auto& [id, ls] : layers_)
        if (ls.chain)
            for (const std::string& m : ls.chain->moduleIds)
                if (m == moduleId) {
                    writeParams(*ls.chain);
                    break;
                }
}

void Engine::setGlobal(const std::string& name, double value) {
    std::lock_guard<std::mutex> lock(ctl_);
    globals_[name] = value;
    for (auto& [id, ls] : layers_)
        if (ls.chain) writeParams(*ls.chain);
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

void Engine::play() {
    std::lock_guard<std::mutex> lock(ctl_);
    drainRetired();
    Cmd c;
    c.type = Cmd::Play;
    send(c);
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
    Slot& s = slots_[it->second.slot];
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
    if (index >= 0) {
        int slot = -1;
        if (index == kAuditionSlot) {
            slot = kAuditionSlot;
        } else if (index < static_cast<int>(order_.size())) {
            auto it = layers_.find(order_[index]);
            if (it != layers_.end()) slot = it->second.slot;
        }
        if (slot < 0) {
            std::fill_n(out, n, 0.0f);
            return n;
        }
        ring = slots_[slot].scope;
        pos = slots_[slot].scopePos.load(std::memory_order_acquire);
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

void Engine::retire(Chain* c, int freedSlot, std::shared_ptr<const Pattern>* pattern) noexcept {
    if (!c && freedSlot < 0 && !pattern) return;
    Retired r{c, freedSlot, pattern};
    if (pendingCount_ == 0 && retired_->push(r)) return;
    if (pendingCount_ < kPendingMax) pending_[pendingCount_++] = r;
    // If even the pending list is full the chain leaks; that needs 1280 swaps without the app reading meters.
}

void Engine::swapIn(Slot& s, Chain* c) noexcept {
    retire(s.old, -1);
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
            t.tacc = t.phase = t.lastY = 0;
        }
}

void Engine::applyCommands() noexcept {
    while (pendingCount_ > 0 && retired_->push(pending_[0])) {
        for (int i = 1; i < pendingCount_; ++i) pending_[i - 1] = pending_[i];
        --pendingCount_;
    }
    Cmd c;
    while (cmds_->pop(c)) {
        switch (c.type) {
            case Cmd::Install: {
                Slot& s = slots_[c.slot];
                s.steps = c.steps;
                s.order = c.order;
                if (!s.active || s.removing || !s.cur) {
                    retire(s.cur, -1);
                    retire(s.old, -1);
                    s.cur = c.chain;
                    s.old = nullptr;
                    s.swapLeft = 0;
                    s.seamLeft = 0;
                    s.active = true;
                    s.removing = false;
                    s.fresh = true;
                    s.contiguous = false;
                    s.overloaded = false;
                    s.overloadFlag.store(false, std::memory_order_relaxed);
                    s.k = -1;
                    s.epoch = -1;
                    updateSolo();
                    s.gain = slotTarget(s);
                } else if (swapMode_ > 0 && playing_ && stopFade_ == 0) {
                    // Wait for the next beat or bar; newer code replaces code still waiting.
                    retire(s.pending, -1);
                    s.pending = c.chain;
                } else {
                    retire(s.pending, -1);
                    s.pending = nullptr;
                    swapIn(s, c.chain);
                }
                break;
            }
            case Cmd::SetSteps:
                slots_[c.slot].steps = c.steps;
                break;
            case Cmd::SetPattern: {
                Slot& s = slots_[c.slot];
                // A sounding note finishes as the old pattern had it; the edit is heard from its next start.
                if (s.cur && s.cur->voiced) {
                    const Pattern* old = s.pattern ? s.pattern->get() : nullptr;
                    for (Voice& v : s.cur->voices) {
                        if (!v.active || !v.gate || v.note == kOrphanNote) continue;
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
                retire(nullptr, -1, s.pattern);
                s.pattern = c.pattern;
                break;
            }
            case Cmd::Remove:
                slots_[c.slot].removing = true;
                break;
            case Cmd::Transport:
                // A tempo change moves every note in time: let held notes go so none is left hanging.
                if (c.bpm != bpm_)
                    for (int i = 0; i < kSlots; ++i) {
                        if (slots_[i].cur && slots_[i].cur->voiced) releaseVoices(slots_[i].cur->voices, slots_[i].cur->voiceCount);
                        if (slots_[i].old && slots_[i].old->voiced) releaseVoices(slots_[i].old->voices, slots_[i].old->voiceCount);
                    }
                bpm_ = c.bpm;
                beatsPerBar_ = c.beatsPerBar;
                loopSteps_ = c.loopSteps;
                seed_ = c.seed;
                master_ = c.master;
                seamXf_ = c.seamXf;
                keyRoot_ = c.keyRoot;
                keyScale_ = c.keyScale;
                swapMode_ = c.swapMode;
                voiceLimit_ = c.voices;
                updateTiming();
                if (g_ >= loopLen_) g_ = 0;
                loopLenFlag_.store(loopLen_, std::memory_order_relaxed);
                break;
            case Cmd::Play:
                playing_ = true;
                stopFade_ = 0;
                g_ = 0;
                epoch_ = 0;
                dcL_[0] = dcL_[1] = dcR_[0] = dcR_[1] = 0;
                limEnv_ = 0;
                for (int i = 0; i < kSlots; ++i) {
                    Slot& s = slots_[i];
                    if (!s.active) continue;
                    retire(s.old, -1);
                    s.old = nullptr;
                    if (s.pending) {
                        retire(s.cur, -1);
                        s.cur = s.pending;
                        s.pending = nullptr;
                    }
                    s.swapLeft = 0;
                    s.seamLeft = 0;
                    if (s.cur) {
                        for (auto& inst : s.cur->main) inst->reset();
                        for (Voice& v : s.cur->voices) v.active = false;
                    }
                    s.fresh = true;
                    s.contiguous = false;
                    s.k = -1;
                    s.epoch = -1;
                    updateSolo();
                    s.gain = slotTarget(s);
                }
                break;
            case Cmd::Stop:
                if (playing_ && stopFade_ == 0) stopFade_ = std::max(1, static_cast<int>(kStopSeconds * sr_));
                break;
            case Cmd::AuditionOnly:
                auditionOnly_ = c.flag;
                break;
            case Cmd::SetOrder:
                std::copy_n(c.orderList, c.orderCount, processOrder_);
                processCount_ = c.orderCount;
                break;
            case Cmd::ClearOverload:
                for (int i = 0; i < kSlots; ++i) {
                    slots_[i].overloaded = false;
                    slots_[i].overloadFlag.store(false, std::memory_order_relaxed);
                }
                overloadedFlag_.store(0, std::memory_order_relaxed);
                break;
        }
    }
}

double Engine::slotTarget(const Slot& s) const noexcept {
    if (s.removing || s.overloaded) return 0.0;
    const int idx = static_cast<int>(&s - slots_.get());
    if (auditionOnly_) return idx == kAuditionSlot ? bitsToDouble(s.vol.load(std::memory_order_relaxed)) : 0.0;
    if (idx == kAuditionSlot) return 0.0;
    if (s.mute.load(std::memory_order_relaxed)) return 0.0;
    if (anySolo_ && !s.solo.load(std::memory_order_relaxed)) return 0.0;
    return bitsToDouble(s.vol.load(std::memory_order_relaxed));
}

void Engine::updateSolo() noexcept {
    bool any = false;
    for (int i = 0; i < kMaxLayers && !any; ++i)
        any = slots_[i].active && !slots_[i].removing && slots_[i].solo.load(std::memory_order_relaxed);
    anySolo_ = any;
}

int64_t Engine::loopStart(const Slot& s, int64_t k) const noexcept {
    return static_cast<int64_t>(std::floor(static_cast<double>(k) * (s.steps * stepLen_) + 0.5));
}

void Engine::runChain(Chain& c, bool shadow, int64_t n0, int len, double* out, Slot* exportTo, int offset,
                      const Pattern* pat, int64_t repeat) noexcept {
    auto& insts = shadow ? c.shadow : c.main;
    BlockCtx ctx;
    ctx.n = len;
    ctx.sr = sr_;
    ctx.bpm = bpm_;
    ctx.seed = seed_;
    ctx.keyRoot = keyRoot_;
    ctx.keyScale = keyScale_;
    const uint32_t u = c.used;
    auto uses = [u](Var v) { return (u >> static_cast<int>(v)) & 1u; };
    for (int i = 0; i < len; ++i) c.nb[i] = static_cast<double>(n0 + i);
    if (uses(Var::Step) || uses(Var::Beat) || uses(Var::Bar)) {
        for (int i = 0; i < len; ++i) {
            const double st = std::floor(c.nb[i] / stepLen_);
            c.stepb[i] = st;
            c.beatb[i] = std::floor(st / 4.0);
            c.barb[i] = std::floor(c.beatb[i] / beatsPerBar_);
        }
    }
    if (uses(Var::Pos) || uses(Var::Phase)) {
        // pos counts through this layer's loop; layers that follow the project count through the project loop.
        for (int i = 0; i < len; ++i) c.posb[i] = c.nb[i] / c.layerLen;
    }
    if (uses(Var::Time))
        for (int i = 0; i < len; ++i) c.timeb[i] = c.nb[i] / sr_;
    std::fill_n(c.srb, len, sr_);
    std::fill_n(c.bpmb, len, bpm_);
    std::fill_n(c.seedb, len, static_cast<double>(seed_));
    ctx.vars[static_cast<int>(Var::Sr)] = c.srb;
    ctx.vars[static_cast<int>(Var::Bpm)] = c.bpmb;
    ctx.vars[static_cast<int>(Var::Seed)] = c.seedb;
    ctx.vars[static_cast<int>(Var::Step)] = c.stepb;
    ctx.vars[static_cast<int>(Var::Beat)] = c.beatb;
    ctx.vars[static_cast<int>(Var::Bar)] = c.barb;
    ctx.vars[static_cast<int>(Var::Pos)] = c.posb;
    ctx.vars[static_cast<int>(Var::Phase)] = c.posb;
    ctx.vars[static_cast<int>(Var::Time)] = c.timeb;
    // Without a pattern, the note variables describe one note held through the layer's loop (C4, full velocity).
    if (uses(Var::Trig))
        for (int i = 0; i < len; ++i) c.dtrig[i] = c.nb[i] == 0.0 ? 1.0 : 0.0;
    ctx.vars[static_cast<int>(Var::Trig)] = uses(Var::Trig) ? c.dtrig : c.zero;
    ctx.vars[static_cast<int>(Var::Gate)] = c.ones;
    ctx.vars[static_cast<int>(Var::Note)] = c.dnote;
    ctx.vars[static_cast<int>(Var::Freq)] = c.dfreq;
    ctx.vars[static_cast<int>(Var::Vel)] = c.ones;
    ctx.vars[static_cast<int>(Var::Rel)] = c.zero;
    ctx.vars[static_cast<int>(Var::Bend)] = c.zero;
    const double* input = c.zero;
    ctx.importOffset = offset;
    for (size_t idx = 0; idx < insts.size(); ++idx) {
        auto& inst = insts[idx];
        if (idx == 0 && c.voiced) {
            runVoices(c, pat, repeat, n0, len, c.gen, exportTo, offset, ctx);
            input = c.gen;
            continue;
        }
        ctx.imports = c.importPtrs[idx].empty() ? nullptr : c.importPtrs[idx].data();
        const Program& p = inst->program();
        if (p.mode == OutputMode::Byte) {
            const double ratio = p.rate / sr_;
            for (int i = 0; i < len; ++i) c.tb[i] = std::floor(c.nb[i] * ratio);
            std::fill_n(c.rateb, len, p.rate);
        } else {
            std::copy_n(c.nb, len, c.tb);
            std::fill_n(c.rateb, len, sr_);
        }
        ctx.vars[static_cast<int>(Var::T)] = c.tb;
        ctx.vars[static_cast<int>(Var::Rate)] = c.rateb;
        ctx.vars[static_cast<int>(Var::In)] = input;
        input = inst->process(ctx);
        if (exportTo)
            for (const auto& [reg, buf] : c.exportMap[idx]) std::copy_n(inst->reg(reg), len, exportTo->exportBuf[buf] + offset);
    }
    std::copy_n(input, len, out);
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
                v.target = n.pitch;
                v.glideLeft = std::max(1, static_cast<int>(std::floor(stepLen_ * 0.5 + 0.5)));
                v.glideStep = (v.target - v.pitch) / v.glideLeft;
                return;
            }
    }
    // A free voice, else the oldest released one, else the oldest.
    Voice* pick = nullptr;
    // Only the project's first `voices` voices take new notes (light mode plays fewer).
    const int limit = std::min(voiceLimit_, c.voiceCount);
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
        if (exportTo)
            for (const auto& [reg, buf] : c.exportMap[0]) std::fill_n(exportTo->exportBuf[buf] + offset + o, n, 0.0);
        BlockCtx ctx = base;
        ctx.n = n;
        for (int k = 0; k < static_cast<int>(Var::Count); ++k)
            if (ctx.vars[k]) ctx.vars[k] += o;
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
        ctx.vars[static_cast<int>(Var::Bend)] = c.zero;
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
                c.vnote[i] = v.pitch;
                c.vfreq[i] = v.freq;
                c.vvel[i] = v.vel;
                c.vrel[i] = v.gate ? 0.0 : static_cast<double>(v.rel++);
                c.vtb[i] = byteMode ? std::floor(v.tacc) : static_cast<double>(v.since);
                v.tacc += tPerHz * v.freq;
                c.vtime[i] = static_cast<double>(v.since++) / sr_;
                c.vphase[i] = v.phase;
                v.phase += v.freq / sr_;
                v.phase -= std::floor(v.phase);
            }
            const double* y = v.inst->process(ctx);
            for (int i = 0; i < n; ++i) {
                double s = y[i];
                if (engineFade && !v.gate) s *= std::max(0.0, 1.0 - c.vrel[i] / fadeLen);
                out[o + i] += s;
                v.lastY = s;
                if (!v.gate) v.quiet = std::fabs(s) < kQuietLevel ? v.quiet + 1 : 0;
            }
            if (exportTo && vi == newest)
                for (const auto& [reg, buf] : c.exportMap[0]) std::copy_n(v.inst->reg(reg), n, exportTo->exportBuf[buf] + offset + o);
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

void Engine::processSlot(Slot& s, int m, double target) noexcept {
    const bool free = s.steps <= 0;
    const double layerLen = free ? static_cast<double>(loopLen_) : s.steps * stepLen_;
    const double gainCoef = 1.0 - detExp(-1.0 / (kGainSeconds * sr_));
    const int seamLen = std::max(1, static_cast<int>(kSeamSeconds * sr_));
    const int swapLen = std::max(1, static_cast<int>(kSwapSeconds * sr_));
    const double pan = bitsToDouble(s.pan.load(std::memory_order_relaxed));
    if (pan != s.panCache) {
        s.panCache = pan;
        const double th = (pan + 1.0) * (kPi / 4.0);
        s.gl = detCos(th);
        s.gr = detSin(th);
    }
    float peak = 0;
    int j = 0;
    while (j < m) {
        const int64_t gg = g_ + j;
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
        int len = static_cast<int>(std::min<int64_t>(m - j, nx - gg));
        // New code waiting for the next beat or bar goes in on that exact sample.
        if (s.pending) {
            const double unit = (swapMode_ == 1 ? 4.0 : 4.0 * beatsPerBar_) * stepLen_;
            int64_t kb = static_cast<int64_t>(std::floor(static_cast<double>(gg) / unit));
            int64_t at = static_cast<int64_t>(std::floor(kb * unit + 0.5));
            if (at < gg) at = static_cast<int64_t>(std::floor(++kb * unit + 0.5));
            if (at == gg || swapMode_ == 0) {
                swapIn(s, s.pending);
                s.pending = nullptr;
            } else {
                len = static_cast<int>(std::min<int64_t>(len, at - gg));
            }
        }
        const int64_t n0 = gg - st;
        double* y = tmp_;
        s.cur->layerLen = layerLen;
        const Pattern* pat = s.pattern ? s.pattern->get() : nullptr;
        runChain(*s.cur, false, n0, len, y, &s, j, pat, k);
        if (s.seamLeft > 0) {
            const int sl = std::min(len, s.seamLeft);
            double z[kBlock];
            runChain(*s.cur, true, s.shadowN, sl, z, nullptr, j, nullptr, k);
            for (int i = 0; i < sl; ++i) {
                const double w = static_cast<double>(seamLen - s.seamLeft + i + 1) / (seamLen + 1);
                y[i] = z[i] * (1.0 - w) + y[i] * w;
            }
            s.shadowN += sl;
            s.seamLeft -= sl;
        }
        if (s.old) {
            s.old->layerLen = layerLen;
            runChain(*s.old, false, n0, len, tmp2_, nullptr, j, nullptr, k);
            const int sl = std::min(len, s.swapLeft);
            for (int i = 0; i < len; ++i) {
                double w = 1.0;
                if (i < sl) w = static_cast<double>(swapLen - s.swapLeft + i + 1) / (swapLen + 1);
                y[i] = tmp2_[i] * (1.0 - w) + y[i] * w;
            }
            s.swapLeft -= sl;
            if (s.swapLeft <= 0) {
                retire(s.old, -1);
                s.old = nullptr;
            }
        }
        int sp = s.scopePos.load(std::memory_order_relaxed);
        for (int i = 0; i < len; ++i) {
            if (s.gain != target) {
                s.gain += (target - s.gain) * gainCoef;
                if (std::fabs(target - s.gain) < 1e-6) s.gain = target;
            }
            const double v = finiteOr0(y[i]) * s.gain;
            mixL_[j + i] += v * s.gl;
            mixR_[j + i] += v * s.gr;
            const float av = static_cast<float>(std::fabs(v));
            if (av > peak) peak = av;
            s.scope[sp].store(static_cast<float>(v), std::memory_order_relaxed);
            sp = (sp + 1) % kScopeSize;
        }
        s.scopePos.store(sp, std::memory_order_release);
        s.lastN = n0 + len - 1;
        s.expectG = gg + len >= loopLen_ ? 0 : gg + len;
        s.contiguous = true;
        s.progress.store(static_cast<float>(static_cast<double>(n0 + len) / layerLen), std::memory_order_relaxed);
        j += len;
    }
    storeMax(s.peak, peak);
}

void Engine::processChunk(float* l, float* r, int m) noexcept {
    std::fill_n(mixL_, m, 0.0);
    std::fill_n(mixR_, m, 0.0);
    ++chunkId_;
    // Layers in dependency order first, then any others (for example a layer installed before its order arrived).
    for (int pass = 0; pass < 2; ++pass) {
        const int count = pass == 0 ? processCount_ : kSlots;
        for (int k = 0; k < count; ++k) {
            const int i = pass == 0 ? processOrder_[k] : k;
            Slot& s = slots_[i];
            if (s.visited == chunkId_) continue;
            s.visited = chunkId_;
            if (!s.active || !s.cur) continue;
            const double target = slotTarget(s);
            if (target == 0.0 && s.gain == 0.0) {
                s.contiguous = false;
                for (auto& b : s.exportBuf) std::fill_n(b, m, 0.0);  // a silent layer shares zeros
                if (s.pending) {  // nobody hears this layer: no need to wait for the beat
                    swapIn(s, s.pending);
                    s.pending = nullptr;
                }
                if (s.removing) {
                    retire(s.cur, -1, s.pattern);
                    s.pattern = nullptr;
                    retire(s.old, i);
                    s.cur = s.old = nullptr;
                    s.active = false;
                    s.removing = false;
                }
                continue;
            }
            processSlot(s, m, target);
        }
    }
    // Master: gain, DC blocker, then the safety limiter, always last.
    const double R = 1.0 - kTwoPi * 5.0 / sr_;
    const double rel = detExp(-1.0 / (0.1 * sr_));
    double fade = 1.0;
    float pl = 0, pr = 0;
    const bool bypass = bypass_.load(std::memory_order_relaxed);
    int sp = masterScopePos_.load(std::memory_order_relaxed);
    for (int i = 0; i < m; ++i) {
        const double xl = finiteOr0(mixL_[i]) * master_;
        const double xr = finiteOr0(mixR_[i]) * master_;
        double yl = xl - dcL_[0] + R * dcL_[1];
        dcL_[0] = xl;
        dcL_[1] = yl;
        double yr = xr - dcR_[0] + R * dcR_[1];
        dcR_[0] = xr;
        dcR_[1] = yr;
        const double env = std::max(std::fabs(yl), std::fabs(yr));
        limEnv_ = env > limEnv_ ? env : env + (limEnv_ - env) * rel;
        double gain = limEnv_ > kLimitCeiling ? kLimitCeiling / limEnv_ : 1.0;
        if (bypass) {
            yl = xl;
            yr = xr;
            gain = 1.0;
        }
        if (stopFade_ > 0) {
            fade = static_cast<double>(stopFade_) / (kStopSeconds * sr_);
            if (--stopFade_ == 0) playing_ = false;
        } else if (!playing_) {
            fade = 0.0;
        }
        const float ol = static_cast<float>(yl * gain * fade);
        const float orr = static_cast<float>(yr * gain * fade);
        l[i] = ol;
        r[i] = orr;
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
    for (int i = 0; i < kSlots; ++i) {
        const Slot& s = slots_[i];
        if (!s.active || s.overloaded || slotTarget(s) == 0.0) continue;
        if (best < 0 || s.order > slots_[best].order) best = i;
    }
    if (best >= 0) {
        slots_[best].overloaded = true;
        slots_[best].overloadFlag.store(true, std::memory_order_relaxed);
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
            std::fill(left + i, left + frames, 0.0f);
            std::fill(right + i, right + frames, 0.0f);
            break;
        }
        const int m = static_cast<int>(std::min<int64_t>({static_cast<int64_t>(frames - i), kBlock, loopLen_ - g_}));
        processChunk(left + i, right + i, m);
        g_ += m;
        if (g_ >= loopLen_) {
            g_ = 0;
            ++epoch_;
        }
        i += m;
    }
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
