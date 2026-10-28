// Mixer implementation: the audio-thread render loop and the control-thread project diffing that feeds it.
#include "engine.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cmath>
#include <thread>

#include "compile.h"
#include "detmath.h"
#include "json.h"

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
};

// One layer's modules: the main instances plus shadow copies that play the loop's tail across a seam.
struct Engine::Chain {
    std::vector<std::unique_ptr<Instance>> main, shadow;
    std::vector<std::string> moduleIds;
    uint32_t used = 0;
    double layerLen = 1;  // samples in this layer's loop, for pos and phase
    double nb[kBlock], tb[kBlock], stepb[kBlock], beatb[kBlock], barb[kBlock], posb[kBlock], timeb[kBlock];
    double srb[kBlock], rateb[kBlock], bpmb[kBlock], seedb[kBlock], zero[kBlock];
};

struct Engine::Cmd {
    enum Type { Install, SetSteps, Remove, Transport, Play, Stop, AuditionOnly, ClearOverload } type = Play;
    int slot = 0;
    Chain* chain = nullptr;
    int steps = 0, order = 0;
    double bpm = 120, master = 0.7;
    int beatsPerBar = 4, loopSteps = 64;
    uint32_t seed = 0;
    bool seamXf = true, flag = false;
};

struct Engine::Retired {
    Chain* chain = nullptr;
    int freedSlot = -1;
};

namespace {

constexpr double kSwapSeconds = 0.02;
constexpr double kSeamSeconds = 0.003;
constexpr double kStopSeconds = 0.01;
constexpr double kGainSeconds = 0.005;
constexpr double kLimitCeiling = 0.977;  // about -0.2 dBFS
constexpr int kPendingMax = 256;

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
    updateTiming();
    ctlLoopLen_ = loopLen_;
    loopLenFlag_.store(loopLen_);
}

Engine::~Engine() {
    // No audio thread runs any more: free everything directly.
    Cmd c;
    while (cmds_->pop(c))
        if (c.type == Cmd::Install) delete c.chain;
    Retired r;
    while (retired_->pop(r)) delete r.chain;
    for (int i = 0; i < pendingCount_; ++i) delete pending_[i].chain;
    for (int s = 0; s < kSlots; ++s) {
        delete slots_[s].cur;
        delete slots_[s].old;
    }
    delete[] pending_;
}

// ===================== control thread =====================

void Engine::drainRetired() {
    Retired r;
    while (retired_->pop(r)) {
        delete r.chain;
        if (r.freedSlot >= 0) slotBusy_[r.freedSlot] = false;
    }
}

void Engine::send(const Cmd& c) {
    // The audio thread empties the queue every callback; wait briefly if it is full.
    for (int tries = 0; !cmds_->push(c); ++tries) {
        drainRetired();
        if (tries > 2000) {
            if (c.type == Cmd::Install) delete c.chain;  // audio stalled; drop rather than hang the app
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

Engine::Chain* Engine::buildChain(const std::vector<std::string>& ids) {
    auto* c = new Chain();
    for (size_t i = 0; i < ids.size(); ++i) {
        const ModuleState& m = modules_.at(ids[i]);
        c->main.push_back(std::make_unique<Instance>(m.program));
        c->shadow.push_back(std::make_unique<Instance>(m.program));
        c->moduleIds.push_back(ids[i]);
        c->used |= m.program->usedVars;
    }
    std::fill_n(c->zero, kBlock, 0.0);
    writeParams(*c);
    return c;
}

void Engine::writeParams(Chain& c) {
    for (size_t i = 0; i < c.main.size(); ++i) {
        const ModuleState& m = modules_.at(c.moduleIds[i]);
        const Program& p = c.main[i]->program();
        for (size_t k = 0; k < p.params.size(); ++k) {
            double v = p.params[k].def;
            auto it = m.params.find(p.params[k].name);
            if (it != m.params.end()) v = std::min(p.params[k].max, std::max(p.params[k].min, it->second));
            c.main[i]->setParam(static_cast<int>(k), v);
            c.shadow[i]->setParam(static_cast<int>(k), v);
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
    send(t);
    const double stepLen = 60.0 * ctlSr_ / (p.bpm * 4.0);
    ctlLoopLen_ = static_cast<int64_t>(std::floor(p.loopSteps() * stepLen + 0.5));

    // Compile changed modules. A module that fails keeps its last good program, so the old sound plays on.
    bool allOk = true;
    std::string mods;
    std::map<std::string, ModuleState> next;
    for (const ModuleSpec& m : p.modules) {
        ModuleState st;
        auto it = modules_.find(m.id);
        if (it != modules_.end()) st = it->second;
        if (it == modules_.end() || st.source != m.source || (!st.program && st.error.empty())) {
            CompileResult r = compileModule(m.source);
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
        if (!st.error.empty()) allOk = false;
        if (!mods.empty()) mods += ",";
        mods += "\"" + jsonEscape(m.id) + "\":{\"ok\":" + (st.error.empty() ? "true" : "false");
        if (!st.error.empty())
            mods += ",\"error\":\"" + jsonEscape(st.error) + "\",\"line\":" + std::to_string(st.line) +
                    ",\"col\":" + std::to_string(st.col);
        if (st.program) {
            const Program& pr = *st.program;
            mods += std::string(",\"kind\":\"") + (pr.kind == ModuleKind::Effect ? "effect" : "generator") +
                    "\",\"mode\":\"" + (pr.mode == OutputMode::Byte ? "byte" : "float") + "\",\"name\":\"" +
                    jsonEscape(pr.name) + "\",\"summary\":\"" + jsonEscape(pr.summary) + "\",\"params\":[";
            for (size_t i = 0; i < pr.params.size(); ++i) {
                const ParamDef& d = pr.params[i];
                char buf[160];
                std::snprintf(buf, sizeof buf, "%s{\"name\":\"%s\",\"default\":%.17g,\"min\":%.17g,\"max\":%.17g}",
                              i ? "," : "", jsonEscape(d.name).c_str(), d.def, d.min, d.max);
                mods += buf;
            }
            mods += "]";
        }
        mods += "}";
        next[m.id] = std::move(st);
    }
    modules_ = std::move(next);

    // Layers: diff against what the audio thread has, sending only what changed.
    struct Want {
        std::string id;
        std::vector<std::string> chain;
        int steps;
        double vol, pan;
        bool mute, solo;
        int order;
    };
    std::vector<Want> wants;
    int order = 0;
    if (p.auditionOnly) {
        wants.push_back({"\x01audition", p.auditionChain, p.auditionSteps, 0.8, 0.0, false, false, 100000});
    }
    order_.clear();
    for (const LayerSpec& l : p.layers) {
        order_.push_back(l.id);
        wants.push_back({l.id, l.chain, l.lengthSteps, l.volume, l.pan, l.mute, l.solo, ++order});
    }

    std::map<std::string, LayerState> nextLayers;
    for (Want& w : wants) {
        std::vector<std::string> ids;
        std::vector<const Program*> sig;
        for (const std::string& id : w.chain) {
            auto it = modules_.find(id);
            if (it == modules_.end() || !it->second.program) continue;
            ids.push_back(id);
            sig.push_back(it->second.program.get());
        }
        LayerState ls;
        auto it = layers_.find(w.id);
        if (it != layers_.end()) {
            ls = it->second;
            layers_.erase(it);
        }
        const bool isAudition = w.id[0] == '\x01';
        if (ids.empty()) {
            if (ls.slot >= 0) {
                Cmd c;
                c.type = Cmd::Remove;
                c.slot = ls.slot;
                send(c);
            }
            continue;
        }
        if (ls.slot < 0) {
            ls.slot = isAudition ? kAuditionSlot : freeSlot();
            if (isAudition) slotBusy_[kAuditionSlot] = true;
            if (ls.slot < 0) continue;  // all slots busy (removals still fading)
            ls.sig.clear();
            ls.chain = nullptr;
            ls.steps = -1;
            ls.volume = -1;
        }
        if (w.vol != ls.volume || w.pan != ls.pan || w.mute != ls.mute || w.solo != ls.solo) {
            writeMix(ls.slot, w.vol, w.pan, w.mute, w.solo);
            ls.volume = w.vol;
            ls.pan = w.pan;
            ls.mute = w.mute;
            ls.solo = w.solo;
        }
        if (sig != ls.sig) {
            Chain* c = buildChain(ids);
            Cmd cmd;
            cmd.type = Cmd::Install;
            cmd.slot = ls.slot;
            cmd.chain = c;
            cmd.steps = w.steps;
            cmd.order = w.order;
            send(cmd);
            ls.chain = c;
            ls.sig = sig;
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

    Cmd a;
    a.type = Cmd::AuditionOnly;
    a.flag = p.auditionOnly;
    send(a);

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

void Engine::retire(Chain* c, int freedSlot) noexcept {
    if (!c && freedSlot < 0) return;
    Retired r{c, freedSlot};
    if (pendingCount_ == 0 && retired_->push(r)) return;
    if (pendingCount_ < kPendingMax) pending_[pendingCount_++] = r;
    // If even the pending list is full the chain leaks; that needs 1280 swaps without the app reading meters.
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
                    s.gain = slotTarget(s);
                } else {
                    retire(s.old, -1);
                    s.old = s.cur;
                    s.cur = c.chain;
                    s.swapLeft = static_cast<int>(kSwapSeconds * sr_);
                    s.seamLeft = 0;
                }
                break;
            }
            case Cmd::SetSteps:
                slots_[c.slot].steps = c.steps;
                break;
            case Cmd::Remove:
                slots_[c.slot].removing = true;
                break;
            case Cmd::Transport:
                bpm_ = c.bpm;
                beatsPerBar_ = c.beatsPerBar;
                loopSteps_ = c.loopSteps;
                seed_ = c.seed;
                master_ = c.master;
                seamXf_ = c.seamXf;
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
                    s.swapLeft = 0;
                    s.seamLeft = 0;
                    if (s.cur)
                        for (auto& inst : s.cur->main) inst->reset();
                    s.fresh = true;
                    s.contiguous = false;
                    s.k = -1;
                    s.epoch = -1;
                    s.gain = slotTarget(s);
                }
                break;
            case Cmd::Stop:
                if (playing_ && stopFade_ == 0) stopFade_ = std::max(1, static_cast<int>(kStopSeconds * sr_));
                break;
            case Cmd::AuditionOnly:
                auditionOnly_ = c.flag;
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
    bool anySolo = false;
    for (int i = 0; i < kMaxLayers && !anySolo; ++i)
        anySolo = slots_[i].active && !slots_[i].removing && slots_[i].solo.load(std::memory_order_relaxed);
    if (anySolo && !s.solo.load(std::memory_order_relaxed)) return 0.0;
    return bitsToDouble(s.vol.load(std::memory_order_relaxed));
}

int64_t Engine::loopStart(const Slot& s, int64_t k) const noexcept {
    return static_cast<int64_t>(std::floor(static_cast<double>(k) * (s.steps * stepLen_) + 0.5));
}

void Engine::runChain(Chain& c, bool shadow, int64_t n0, int len, double* out) noexcept {
    auto& insts = shadow ? c.shadow : c.main;
    BlockCtx ctx;
    ctx.n = len;
    ctx.sr = sr_;
    ctx.bpm = bpm_;
    ctx.seed = seed_;
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
    const double* input = c.zero;
    for (auto& inst : insts) {
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
    }
    std::copy_n(input, len, out);
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
            if (!s.fresh) {
                const bool cont = s.contiguous && s.expectG == gg;
                if (seamXf_ && cont && !s.old && s.cur) {
                    for (size_t i = 0; i < s.cur->main.size(); ++i) s.cur->shadow[i]->copyStateFrom(*s.cur->main[i]);
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
        const int len = static_cast<int>(std::min<int64_t>(m - j, nx - gg));
        const int64_t n0 = gg - st;
        double* y = tmp_;
        s.cur->layerLen = layerLen;
        runChain(*s.cur, false, n0, len, y);
        if (s.seamLeft > 0) {
            const int sl = std::min(len, s.seamLeft);
            double z[kBlock];
            runChain(*s.cur, true, s.shadowN, sl, z);
            for (int i = 0; i < sl; ++i) {
                const double w = static_cast<double>(seamLen - s.seamLeft + i + 1) / (seamLen + 1);
                y[i] = z[i] * (1.0 - w) + y[i] * w;
            }
            s.shadowN += sl;
            s.seamLeft -= sl;
        }
        if (s.old) {
            s.old->layerLen = layerLen;
            runChain(*s.old, false, n0, len, tmp2_);
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
    for (int i = 0; i < kSlots; ++i) {
        Slot& s = slots_[i];
        if (!s.active || !s.cur) continue;
        const double target = slotTarget(s);
        if (target == 0.0 && s.gain == 0.0) {
            s.contiguous = false;
            if (s.removing) {
                retire(s.cur, -1);
                retire(s.old, i);
                s.cur = s.old = nullptr;
                s.active = false;
                s.removing = false;
            }
            continue;
        }
        processSlot(s, m, target);
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
    applyCommands();
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
