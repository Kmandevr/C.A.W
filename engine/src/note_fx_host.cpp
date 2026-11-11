// Per-note FX (#127 step 4): the slot racks, the audio-thread host behind each instrument's voice bus, and the manager that hands them over lock-free.
#include "note_fx_host.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>

#include "caw/instrument.hpp"
#include "mod_route.h"
#include "quality.h"

namespace caw {

namespace {

constexpr uint32_t kFrames = ComponentChain::kMaxFrames;
constexpr uint32_t kSampleScratch = 32;  // modulated parameters with per-frame values, per component and call
constexpr int kRest = kMaxNoteSlots;     // the overflow lane's index

// Tagged pointers on the retire queue: what the control thread must free.
enum Tag : uintptr_t { kTagRack = 1, kTagHost = 2, kTagPlan = 3 };
void* tagged(const void* p, Tag t) noexcept { return reinterpret_cast<void*>(reinterpret_cast<uintptr_t>(p) | t); }

}  // namespace

int noteFxBudget(int voices, int quality) noexcept {
    const int b = std::clamp(voices, 1, kMaxNoteVoices);
    switch (quality) {
        case kQualityEco: return std::min(b, 4);
        case kQualityHigh: return std::min(b, 16);
        default: return b;
    }
}

// ---------------------------------------------------------------------------------------------------------------
// The rack.

std::unique_ptr<NoteFxRack> NoteFxRack::build(const ModuleRegistry& registry, const std::vector<ComponentSpec>& specs,
                                              int voices, double sampleRate, std::string& error) {
    std::unique_ptr<NoteFxRack> rack(new NoteFxRack());
    rack->voices_ = std::clamp(voices, 1, kMaxNoteVoices);
    rack->sampleRate_ = sampleRate;
    const int chains = noteFxSlots(rack->voices_) + 1;  // the slots, then the overflow chain
    rack->chains_.reserve(static_cast<size_t>(chains));
    for (int k = 0; k < chains; ++k) {
        auto chain = ComponentChain::buildNoteEffects(registry, specs, sampleRate, error);
        if (!chain) return nullptr;
        rack->chains_.push_back(std::move(chain));
    }
    const ComponentChain& first = *rack->chains_.front();
    const uint32_t cap = static_cast<uint32_t>(kNoteFxMaxTailSeconds * sampleRate);
    const uint32_t tail = first.tailFrames();
    rack->tail_ = tail == kInfiniteTail ? cap : std::min(tail, cap);
    for (size_t i = 0; i < first.size(); ++i) {
        const ModuleDescriptor* d = first.descriptorOf(i);
        rack->maxParams_ = std::max(rack->maxParams_, d->parameterCount);
        for (uint32_t k = 0; k < d->portCount; ++k)
            rack->events_ = rack->events_ || (d->ports[k].type == PortType::Event && d->ports[k].input);
    }
    return rack;
}

bool NoteFxRack::sameComponents(const std::vector<ComponentSpec>& specs, int voices, double sampleRate) const noexcept {
    return voices_ == std::clamp(voices, 1, kMaxNoteVoices) && sampleRate == sampleRate_ &&
           slot(0).sameComponents(specs, sampleRate);
}

void NoteFxRack::setValues(const std::vector<ComponentSpec>& specs) noexcept {
    for (auto& c : chains_) c->setValues(specs);
}

bool NoteFxRack::setValue(std::size_t index, const std::string& param, double value) noexcept {
    bool ok = true;
    for (auto& c : chains_) ok = c->setValue(index, param, value) && ok;
    return ok;
}

bool NoteFxRack::setBypass(std::size_t index, bool bypass) noexcept {
    bool ok = true;
    for (auto& c : chains_) ok = c->setBypass(index, bypass) && ok;
    return ok;
}

// ---------------------------------------------------------------------------------------------------------------
// The host (audio thread, except the constructor and stats()).

NoteFxHost::NoteFxHost(double sampleRate) : sr_(sampleRate > 0 ? sampleRate : 48000.0) {
    fadeLen_ = std::max(1, static_cast<int>(kNoteFxFadeSeconds * sr_ + 0.5));
    swapLen_ = std::max(1, static_cast<int>(0.020 * sr_ + 0.5));  // as a replaced chain's crossfade (kSwapSeconds)
    // Every lane's two channels, then the crossfade scratch and the leaving notes' dry signal.
    const size_t lanes = kMaxNoteSlots + 1;
    buffers_ = std::make_unique<float[]>((lanes * 2 + 4) * kFrames);
    for (size_t k = 0; k < lanes; ++k) {
        VoiceLane& lane = lanes_[k];
        lane = VoiceLane{};
        lane.channels[0] = buffers_.get() + (2 * k) * kFrames;
        lane.channels[1] = buffers_.get() + (2 * k + 1) * kFrames;
    }
    scratchL_ = buffers_.get() + (lanes * 2) * kFrames;
    scratchR_ = scratchL_ + kFrames;
    dryL_ = scratchR_ + kFrames;
    dryR_ = dryL_ + kFrames;
    bus_.laneCount = static_cast<uint32_t>(lanes);
    bus_.lanes = lanes_;
    bus_.hostData = this;
    bus_.run = &NoteFxHost::runThunk;
    values_.resize(8192);  // the largest component a link may move (ModulationHost's kValueScratch)
    samples_.resize(static_cast<size_t>(kSampleScratch) * kFrames);
    offsets_ = std::make_unique<float[]>(static_cast<size_t>(kNoteFxMaxBindings) * kFrames);
    mod_.bindings = bindings_;
    mod_.values = values_.data();
    mod_.valueCapacity = static_cast<uint32_t>(values_.size());
    mod_.samples = samples_.data();
    mod_.sampleBuffers = kSampleScratch;
}

NoteFxStats NoteFxHost::stats() const noexcept {
    NoteFxStats s;
    s.voices = statVoices_.load(std::memory_order_relaxed);
    s.budget = statBudget_.load(std::memory_order_relaxed);
    s.active = statActive_.load(std::memory_order_relaxed);
    s.activeMask = statMask_.load(std::memory_order_relaxed);
    s.overflowing = statOverflowing_.load(std::memory_order_relaxed);
    s.overflowed = statOverflowed_.load(std::memory_order_relaxed);
    s.stolen = statStolen_.load(std::memory_order_relaxed);
    s.newestSlot = statNewest_.load(std::memory_order_relaxed);
    return s;
}

void NoteFxHost::freeSlot(int k) noexcept {
    slots_[k] = Slot{};
    if (rack_ && k < rack_->slots()) rack_->slot(k).reset();
    if (fading_ && k < fading_->slots()) fading_->slot(k).reset();
}

void NoteFxHost::reset() noexcept {
    for (int k = 0; k < kMaxNoteSlots; ++k)
        if (slots_[k].use != Use::Free) freeSlot(k);
    if (rack_) rack_->overflow().reset();
    if (fading_) fading_->overflow().reset();
    restLive_ = false;
}

bool NoteFxHost::swapRack(NoteFxRack* next) noexcept {
    if (next == rack_) return false;
    bool retired = false;
    if (fading_) {  // a swap still crossfading: keep whichever side is heard more now
        if (swapLeft_ * 2 > swapLen_) std::swap(rack_, fading_);
        if (fading_ && retire_ && retire_->push(tagged(fading_, kTagRack))) retired = true;
        fading_ = nullptr;
    }
    if (!rack_ && !fading_) {
        startup_ = true;  // notes it never saw start play in the overflow lane
        for (int k = 0; k < kMaxNoteSlots; ++k) slots_[k] = Slot{};
    }
    fading_ = rack_;
    swapLeft_ = fading_ ? swapLen_ : 0;
    rack_ = next;
    if (rack_) rack_->installed.store(true, std::memory_order_relaxed);
    // Slots the new rack doesn't have (fewer voices) leave: their notes fade into the overflow chain.
    const int have = rack_ ? rack_->slots() : 0;
    for (int k = have; k < kMaxNoteSlots; ++k) {
        Slot& s = slots_[k];
        if (s.use == Use::Free || s.use == Use::Leaving) continue;
        if (fading_ && k < fading_->slots()) leave(s, clock_, s.use == Use::Held || s.use == Use::Released);
        else s = Slot{};
    }
    return retired;
}

float NoteFxHost::swapWeight(uint32_t frame) const noexcept {
    const int left = swapLeft_ - static_cast<int>(frame);
    if (!fading_ || left <= 0) return 1.0f;
    return static_cast<float>(swapLen_ - left + 1) / static_cast<float>(swapLen_ + 1);
}

uint64_t NoteFxHost::tailMin() const noexcept {
    const NoteFxRack* rack = rack_ ? rack_ : fading_;
    return std::max<uint64_t>(kNoteFxMinTail, rack ? rack->tailFrames() : 0);
}

float NoteFxHost::fadeWeight(uint64_t fadeAt, uint64_t t) const noexcept {
    if (fadeAt == kNever || t < fadeAt) return 1.0f;
    const uint64_t d = t - fadeAt;
    if (d >= static_cast<uint64_t>(fadeLen_)) return 0.0f;
    return static_cast<float>(static_cast<uint64_t>(fadeLen_) - d) / static_cast<float>(fadeLen_ + 1);
}

void NoteFxHost::leave(Slot& s, uint64_t at, bool fromReleased) noexcept {
    s.use = Use::Leaving;
    s.fromReleased = fromReleased;
    s.fadeAt = std::min(s.fadeAt, at);
}

void NoteFxHost::assign(uint32_t noteId, uint32_t frame) noexcept {
    const NoteFxRack* rack = rack_ ? rack_ : fading_;
    const int have = rack->slots();
    const uint64_t t = clock_ + frame;
    int inUse = 0, freeAt = -1;
    for (int k = 0; k < kMaxNoteSlots; ++k) {
        Slot& s = slots_[k];
        // A slot whose fade has ended by now is free, whichever block the Engine learnt it in.
        if ((s.use == Use::Ended || s.use == Use::Leaving) && expired(s.fadeAt, t)) freeSlot(k);
        const Use u = s.use;
        inUse += u == Use::Held || u == Use::Released || u == Use::Ended;
        if (u == Use::Free && k < have && freeAt < 0) freeAt = k;
    }
    auto rest = [&]() noexcept {
        bool leavingIn = false;
        for (const Slot& s : slots_) leavingIn = leavingIn || (s.use == Use::Leaving && s.fromReleased && !expired(s.fadeAt, t));
        if (restOn_ && !leavingIn && t >= restFadeAt() + static_cast<uint64_t>(fadeLen_)) {
            // The overflow chain has rung out: it starts again, clean, on this frame.
            if (rack_) rack_->overflow().reset();
            if (fading_) fading_->overflow().reset();
            restOn_ = false;
            restFrom_ = UINT32_MAX;
        }
        if (!restOn_) {
            restFrom_ = std::min(restFrom_, frame);
            restLastSound_ = t;
        }
        restOn_ = true;
    };
    auto overflow = [&]() noexcept {
        statOverflowed_.fetch_add(1, std::memory_order_relaxed);
        rest();
    };
    if (inUse >= budget_) {
        // Over budget: the oldest ended slot (its tail fades out), else the oldest released note (its sound
        // crossfades into the overflow chain); held notes are never stolen.
        int victim = -1;
        for (int k = 0; k < kMaxNoteSlots; ++k)
            if (slots_[k].use == Use::Ended && (victim < 0 || slots_[k].endOrder < slots_[victim].endOrder)) victim = k;
        if (victim < 0)
            for (int k = 0; k < kMaxNoteSlots; ++k)
                if (slots_[k].use == Use::Released && (victim < 0 || slots_[k].order < slots_[victim].order)) victim = k;
        if (victim < 0 || freeAt < 0) return overflow();
        Slot& v = slots_[victim];
        const bool released = v.use == Use::Released;
        leave(v, t, released);
        if (released) rest();
        statStolen_.fetch_add(1, std::memory_order_relaxed);
    }
    if (freeAt < 0) return overflow();  // every free chain is still fading out
    Slot& s = slots_[freeAt];
    s = Slot{};
    s.use = Use::Held;
    s.noteId = noteId;
    s.order = ++order_;
    s.startFrame = frame;
    s.lastSound = t;
    statNewest_.store(static_cast<uint32_t>(freeAt), std::memory_order_relaxed);
}

void NoteFxHost::release(uint32_t noteId) noexcept {
    for (Slot& s : slots_)
        if (s.use == Use::Held && s.noteId == noteId) {
            s.use = Use::Released;
            return;
        }
}

const VoiceBus* NoteFxHost::begin(const Event* events, uint32_t count, uint32_t m, const ChainTime* time,
                                  const ChainModulation* global, int quality) noexcept {
    if ((!rack_ && !fading_) || m == 0 || m > kFrames) return nullptr;
    events_ = events;
    eventCount_ = events ? count : 0;
    m_ = m;
    covered_ = 0;
    hasTime_ = time != nullptr;
    if (time) time_ = *time;
    globalCount_ = 0;
    for (uint32_t b = 0; global && b < global->count && globalCount_ < kNoteFxMaxBindings; ++b)
        global_[globalCount_++] = global->bindings[b];
    const NoteFxRack* rack = rack_ ? rack_ : fading_;
    budget_ = noteFxBudget(rack->voices(), quality);
    if (startup_ && !restLive_) restLastSound_ = clock_;
    const bool restWas = restLive_ || startup_;
    startup_ = false;
    restOn_ = restWas;
    restFrom_ = restWas ? 0u : UINT32_MAX;
    for (Slot& s : slots_) {
        s.startFrame = 0;
        s.cursor = 0;
    }
    for (uint32_t e = 0; e < eventCount_; ++e) {
        NoteMessage msg;
        if (!readNote(events_[e], msg) || msg.noteId == 0) continue;
        if (msg.type == NoteMessageType::On) assign(msg.noteId, msg.frame);
        else if (msg.type == NoteMessageType::Off) release(msg.noteId);
    }
    if (!restOn_ || restFrom_ > m) restFrom_ = 0;
    for (int k = 0; k < kMaxNoteSlots; ++k) {
        VoiceLane& lane = lanes_[k];
        lane.noteId = slots_[k].noteId;
        lane.flags = slots_[k].use != Use::Free ? kLaneAssigned : 0u;
    }
    lanes_[kRest].noteId = 0;
    lanes_[kRest].flags = restOn_ ? (kLaneAssigned | kLaneRest) : 0u;
    // Which global binding (if any) each note-link group adds to.
    if (links_)
        for (size_t g = 0; g < links_->groups.size() && g < static_cast<size_t>(kMaxNoteLinks); ++g) {
            groupGlobal_[g] = -1;
            for (uint32_t b = 0; b < globalCount_; ++b)
                if (global_[b].entry == links_->groups[g].entry && global_[b].param == links_->groups[g].param)
                    groupGlobal_[g] = static_cast<int>(b);
        }
    statBudget_.store(static_cast<uint32_t>(budget_), std::memory_order_relaxed);
    statVoices_.store(static_cast<uint32_t>(rack->voices()), std::memory_order_relaxed);
    return &bus_;
}

void NoteFxHost::runThunk(void* host, uint32_t offset, uint32_t frames) noexcept {
    static_cast<NoteFxHost*>(host)->run(offset, frames);
}

void NoteFxHost::walk(Slot& s, uint32_t from, uint32_t end, uint32_t& count, uint32_t ageAt) noexcept {
    for (; s.cursor < eventCount_ && events_[s.cursor].frame < end; ++s.cursor) {
        const Event& e = events_[s.cursor];
        if (e.noteId != s.noteId || e.kind != EventKind::Note) continue;
        NoteMessage msg;
        if (readNote(e, msg)) {
            switch (msg.type) {
                case NoteMessageType::On:
                    s.note = NoteSourceState{};
                    s.note.pitch = msg.pitch;
                    s.note.velocity = msg.velocity;
                    s.note.gate = true;
                    s.note.age = static_cast<int64_t>(ageAt) - static_cast<int64_t>(e.frame);  // 0 at its frame
                    break;
                case NoteMessageType::Off: s.note.gate = false; break;
                case NoteMessageType::Pitch: s.note.pitch = msg.pitch; break;
                case NoteMessageType::Pressure: s.note.pressure = msg.value; break;
                case NoteMessageType::Timbre: s.note.timbre = msg.value; break;
                default: break;
            }
        }
        if (count < kNoteFxMaxEvents && e.frame >= from) {
            slotEvents_[count] = e;
            slotEvents_[count].frame = e.frame - from;
            ++count;
        }
    }
}

const ChainModulation* NoteFxHost::slotModulation(Slot* s, uint32_t from, uint32_t len) noexcept {
    const size_t groups = s && links_ ? std::min<size_t>(links_->groups.size(), kMaxNoteLinks) : 0;
    uint32_t n = 0;
    // Global links alone: the chunk's offsets from this stretch's frame.
    for (uint32_t b = 0; b < globalCount_ && n < kNoteFxMaxBindings; ++b) {
        bool grouped = false;
        for (size_t g = 0; g < groups; ++g) grouped = grouped || groupGlobal_[g] == static_cast<int>(b);
        if (!grouped) bindings_[n++] = {global_[b].entry, global_[b].param, global_[b].offset + from};
    }
    // Note sources (and any global offset into the same parameter), per frame from the slot's note.
    uint32_t events = 0;
    if (groups) {
        for (uint32_t i = 0; i < len; ++i) {
            walk(*s, from, from + i + 1, events, from + i);
            for (size_t g = 0; g < groups && n + g < kNoteFxMaxBindings; ++g) {
                const NoteFxLinks::Group& G = links_->groups[g];
                double sum = groupGlobal_[g] >= 0 ? global_[groupGlobal_[g]].offset[from + i] : 0.0;
                for (uint32_t k = G.first; k < G.first + G.count; ++k) {
                    const NoteLink& l = links_->links[k];
                    const double u = noteSourceValue(l.source, s->note, sr_);
                    sum += modRouteOffset(modCurve(u, l.curve), links_->amounts[k].load(std::memory_order_relaxed), l.bipolar);
                }
                offsets_[g * kFrames + i] = static_cast<float>(sum);
            }
            ++s->note.age;
        }
        for (size_t g = 0; g < groups && n < kNoteFxMaxBindings; ++g)
            bindings_[n++] = {links_->groups[g].entry, links_->groups[g].param, offsets_.get() + g * kFrames};
    } else if (s) {
        walk(*s, from, from + len, events, from);
        s->note.age += len;
    }
    eventsThisCall_ = events;
    mod_.count = n;
    return n ? &mod_ : nullptr;
}

void NoteFxHost::process(int k, float* l, float* r, uint32_t from, uint32_t len, const ChainModulation* mod) noexcept {
    const bool rest = k == kRest;
    auto chainOf = [&](NoteFxRack* rk) noexcept -> ComponentChain* {
        if (!rk) return nullptr;
        if (rest) return &rk->overflow();
        return k < rk->slots() ? &rk->slot(k) : nullptr;
    };
    ComponentChain* now = chainOf(rack_);
    ComponentChain* old = swapLeft_ > static_cast<int>(from) ? chainOf(fading_) : nullptr;  // still crossfading
    ChainTime t = time_;
    t.start += from;
    t.modulation = mod;
    const ChainTime* tp = hasTime_ ? &t : nullptr;
    const Event* ev = rest ? nullptr : slotEvents_;
    const uint32_t evn = rest ? 0 : eventsThisCall_;
    if (old) {
        std::copy_n(l, len, scratchL_);
        std::copy_n(r, len, scratchR_);
        old->setEvents(ev, evn);
        old->process(scratchL_, scratchR_, len, sr_, tp);
    }
    if (now) {
        now->setEvents(ev, evn);
        now->process(l, r, len, sr_, tp);
    } else if (!old) {
        return;  // neither rack has the chain: the dry signal
    }
    if (old) {  // the swap's crossfade: a missing new chain is the dry signal (per-note FX turned off)
        for (uint32_t i = 0; i < len; ++i) {
            const float w = swapWeight(from + i);
            l[i] = scratchL_[i] + (l[i] - scratchL_[i]) * w;
            r[i] = scratchR_[i] + (r[i] - scratchR_[i]) * w;
        }
    }
}

void NoteFxHost::run(uint32_t offset, uint32_t frames) noexcept {
    if (frames == 0 || offset + frames > m_) return;
    covered_ = std::max(covered_, offset + frames);
    const uint32_t end = offset + frames;
    float* restL = lanes_[kRest].channels[0];
    float* restR = lanes_[kRest].channels[1];
    for (int k = 0; k < kMaxNoteSlots; ++k) {
        Slot& s = slots_[k];
        if (s.use == Use::Free) continue;
        const uint32_t from = std::max(offset, s.startFrame);  // a note starting here: its chain starts on its frame
        if (from >= end) continue;
        const uint32_t len = end - from;
        float* l = lanes_[k].channels[0] + from;
        float* r = lanes_[k].channels[1] + from;
        const uint64_t t0 = clock_ + from;
        for (uint32_t i = 0; i < len; ++i)  // its note's sound (the dry lane), for when its tail may end
            if (l[i] != 0.0f || r[i] != 0.0f) s.lastSound = t0 + i + 1;
        const bool fading = s.fadeAt != kNever && t0 + len > s.fadeAt;
        const bool toRest = s.use == Use::Leaving && s.fromReleased && restOn_;
        if (fading && toRest) {
            std::copy_n(l, len, dryL_);
            std::copy_n(r, len, dryR_);
        }
        const ChainModulation* mod = slotModulation(&s, from, len);
        process(k, l, r, from, len, mod);
        if (!fading) continue;
        for (uint32_t i = 0; i < len; ++i) {
            const float w = fadeWeight(s.fadeAt, t0 + i);
            l[i] *= w;
            r[i] *= w;
            if (toRest) {  // its note's sound moves into the overflow chain
                restL[from + i] += dryL_[i] * (1.0f - w);
                restR[from + i] += dryR_[i] * (1.0f - w);
            }
        }
    }
    if (restOn_) {
        const uint32_t from = std::max(offset, restFrom_);
        if (from < end) {
            float* l = restL + from;
            float* r = restR + from;
            const uint32_t len = end - from;
            const uint64_t t0 = clock_ + from;
            for (uint32_t i = 0; i < len; ++i)
                if (l[i] != 0.0f || r[i] != 0.0f) restLastSound_ = t0 + i + 1;
            process(kRest, l, r, from, len, slotModulation(nullptr, from, len));
            // Rung out (its input silent for its tail): it fades, then stops at a block's end.
            if (t0 + len > restFadeAt())
                for (uint32_t i = 0; i < len; ++i) {
                    const float w = fadeWeight(restFadeAt(), t0 + i);
                    l[i] *= w;
                    r[i] *= w;
                }
        }
    }
}

void NoteFxHost::end(uint32_t m) noexcept {
    if (!rack_ && !fading_) return;
    const uint64_t tEnd = clock_ + m;
    if (covered_ == 0) {  // the instrument didn't run its lanes (bypassed, failed): nothing rings on
        reset();
    } else {
        for (int k = 0; k < kMaxNoteSlots; ++k) {
            Slot& s = slots_[k];
            switch (s.use) {
                case Use::Free: break;
                case Use::Held:
                case Use::Released:
                    if (lanes_[k].flags & kLaneEnded) {
                        // It rings on for its tail past its last sound, then fades out.
                        s.use = Use::Ended;
                        s.endOrder = ++endOrder_;
                        s.fadeAt = std::max(s.lastSound + tailMin(), tEnd);
                    }
                    break;
                case Use::Ended:
                case Use::Leaving:
                    if (expired(s.fadeAt, tEnd)) freeSlot(k);
                    break;
            }
        }
        if (restOn_) {
            bool leavingIn = false;
            for (const Slot& s : slots_) leavingIn = leavingIn || (s.use == Use::Leaving && s.fromReleased);
            restLive_ = leavingIn || tEnd < restFadeAt() + static_cast<uint64_t>(fadeLen_);
            if (!restLive_) {
                if (rack_) rack_->overflow().reset();
                if (fading_) fading_->overflow().reset();
            }
        }
    }
    clock_ = tEnd;
    if (fading_) {
        swapLeft_ -= static_cast<int>(m);
        if (swapLeft_ <= 0) {
            swapLeft_ = 0;
            if (retire_ && retire_->push(tagged(fading_, kTagRack))) fading_ = nullptr;
        }
    }
    if (!rack_ && !fading_) reset();  // per-note FX turned off and faded: back to the plain instrument
    uint32_t active = 0, mask = 0;
    for (int k = 0; k < kMaxNoteSlots; ++k) {
        const Use u = slots_[k].use;
        if (u == Use::Held || u == Use::Released || u == Use::Ended) {
            ++active;
            mask |= 1u << k;
        }
    }
    statActive_.store(active, std::memory_order_relaxed);
    statMask_.store(mask, std::memory_order_relaxed);
    statOverflowing_.store(restLive_ ? 1u : 0u, std::memory_order_relaxed);
}

// ---------------------------------------------------------------------------------------------------------------
// The manager.

struct NoteFxManager::Plan {
    struct Entry {
        int slot = -1;
        NoteFxHost* host = nullptr;
        NoteFxRack* rack = nullptr;
        std::unique_ptr<NoteFxLinks> links;
        // A kept rack's new automation tables (one per chain; after the swap, the old ones, freed with the plan).
        std::vector<std::unique_ptr<ComponentAutomation>> automation;
    };
    std::vector<Entry> entries;
    std::vector<int> bySlot;      // slot to entry (-1: none)
    std::vector<void*> orphans;   // racks and hosts the control thread dropped; retired here unless played
};

NoteFxManager::NoteFxManager() : retire_(std::make_unique<Spsc<void*, 1024>>()) {}

NoteFxManager::~NoteFxManager() {
    drain();
    for (Plan* p : plans_) delete p;
    for (NoteFxHost* h : hosts_) delete h;
    for (NoteFxRack* r : racks_) delete r;
}

void NoteFxManager::free(void* p) noexcept {
    const uintptr_t bits = reinterpret_cast<uintptr_t>(p);
    const Tag tag = static_cast<Tag>(bits & 3u);
    void* ptr = reinterpret_cast<void*>(bits & ~static_cast<uintptr_t>(3));
    auto dropRack = [&](NoteFxRack* r) {
        if (r && racks_.erase(r)) delete r;
    };
    if (tag == kTagRack) {
        dropRack(static_cast<NoteFxRack*>(ptr));
    } else if (tag == kTagHost) {
        auto* h = static_cast<NoteFxHost*>(ptr);
        if (hosts_.erase(h)) {
            dropRack(h->rack_);
            dropRack(h->fading_);
            delete h;
        }
    } else if (tag == kTagPlan) {
        auto* plan = static_cast<Plan*>(ptr);
        if (plans_.erase(plan)) delete plan;
    }
}

void NoteFxManager::drain() noexcept {
    void* p = nullptr;
    while (retire_->pop(p)) free(p);
}

size_t NoteFxManager::instances(const ProjectSpec& p) {
    size_t n = 0;
    for (const LayerSpec& l : p.layers)
        if (!l.folder && !l.noteComponents.empty())
            n += l.noteComponents.size() * static_cast<size_t>(noteFxSlots(l.noteVoices) + 1);
    return n;
}

std::string NoteFxManager::prepare(const ModuleRegistry& registry, const ProjectSpec& p, double sampleRate) {
    drain();
    sr_ = sampleRate;
    auto referenced = [&](NoteFxRack* r) {
        for (const auto& [id, l] : layers_)
            if (l.rack == r) return true;
        return false;
    };
    for (auto& [id, r] : pending_)  // left from a prepare whose project was refused later
        if (!referenced(r) && racks_.erase(r)) delete r;
    pending_.clear();
    std::vector<NoteFxRack*> built;
    auto fail = [&](const std::string& why) {
        for (NoteFxRack* r : built)
            if (racks_.erase(r)) delete r;
        pending_.clear();
        return why;
    };
    for (const LayerSpec& l : p.layers) {
        if (l.folder || l.noteComponents.empty()) continue;
        const std::string who = "layer '" + l.id + "'";
        if (!l.hasInstrument) return fail(who + ": per-note FX need a native instrument that has a voice bus");
        const ModuleDescriptor* d = registry.find(l.instrument.id);
        if (d && !(d->domains & (kDomainPerNote | kDomainPerVoice)))
            return fail(who + ": instrument '" + l.instrument.id +
                        "' has no voice bus (it doesn't declare the per-note domain), so it can't run per-note FX");
        auto it = layers_.find(l.id);
        if (it != layers_.end() && it->second.rack && it->second.rack->sameComponents(l.noteComponents, l.noteVoices, sampleRate)) {
            pending_[l.id] = it->second.rack;
            continue;
        }
        std::string error;
        auto rack = NoteFxRack::build(registry, l.noteComponents, l.noteVoices, sampleRate, error);
        if (!rack) return fail(who + " noteComponents: " + error);
        NoteFxRack* r = rack.release();
        racks_.insert(r);
        built.push_back(r);
        pending_[l.id] = r;
    }
    return "";
}

void NoteFxManager::commit(const ProjectSpec& p, const std::function<int(const std::string&)>& slotOf,
                           const std::shared_ptr<const std::vector<ProjectAutomationLaneSpec>>& lanes,
                           std::vector<std::string>& warnings) {
    drain();
    auto plan = std::make_unique<Plan>();
    auto orphan = [&](NoteFxRack* r) {
        if (r && !r->installed.load(std::memory_order_relaxed)) plan->orphans.push_back(tagged(r, kTagRack));
    };
    auto dropLayer = [&](Layer& L) {
        orphan(L.rack);
        if (L.host && !L.host->installed.load(std::memory_order_relaxed)) plan->orphans.push_back(tagged(L.host, kTagHost));
    };
    std::set<std::string> seen;
    for (const LayerSpec& l : p.layers) {
        if (l.folder) continue;
        auto pend = pending_.find(l.id);
        NoteFxRack* rack = pend != pending_.end() ? pend->second : nullptr;
        auto it = layers_.find(l.id);
        if (!rack && it == layers_.end()) continue;
        const int slot = slotOf(l.id);
        if (slot < 0) {
            if (it != layers_.end()) {
                dropLayer(it->second);
                layers_.erase(it);
            }
            if (rack && it == layers_.end() && racks_.erase(rack)) delete rack;  // built for nothing
            continue;
        }
        seen.insert(l.id);
        Layer& L = layers_[l.id];
        if (L.rack && L.rack != rack) orphan(L.rack);  // replaced (one that played fades out in its host)
        if (!L.host) {
            L.host = new NoteFxHost(sr_);
            hosts_.insert(L.host);
        }
        Plan::Entry entry;
        entry.slot = slot;
        entry.host = L.host;
        entry.rack = rack;
        if (rack) {
            const std::string key = ComponentChain::automationKey(p.automation, l.id, "noteComponent");
            if (rack != L.rack) {
                for (int k = 0; k < rack->chains(); ++k)
                    delete rack->chain(k).swapAutomation(rack->chain(k).automationFor(lanes, l.id).release());
            } else {
                rack->setValues(l.noteComponents);
                if (key != L.automationKey)
                    for (int k = 0; k < rack->chains(); ++k) entry.automation.push_back(rack->chain(k).automationFor(lanes, l.id));
            }
            L.automationKey = key;
            auto links = std::make_unique<NoteFxLinks>();
            links->links = noteLinksFor(p, l.id, rack->slot(0), warnings);
            links->amounts = std::make_unique<std::atomic<double>[]>(std::max<size_t>(1, links->links.size()));
            for (size_t k = 0; k < links->links.size(); ++k) {
                links->amounts[k].store(links->links[k].amount, std::memory_order_relaxed);
                const NoteLink& n = links->links[k];
                if (links->groups.empty() || links->groups.back().entry != n.entry || links->groups.back().param != n.param)
                    links->groups.push_back({n.entry, n.param, static_cast<uint32_t>(k), 0});
                ++links->groups.back().count;
            }
            entry.links = std::move(links);
        }
        L.rack = rack;
        plan->entries.push_back(std::move(entry));
    }
    for (auto it = layers_.begin(); it != layers_.end();) {
        if (seen.count(it->first)) {
            ++it;
            continue;
        }
        dropLayer(it->second);
        it = layers_.erase(it);
    }
    pending_.clear();
    int maxSlot = -1;
    for (const Plan::Entry& e : plan->entries) maxSlot = std::max(maxSlot, e.slot);
    plan->bySlot.assign(static_cast<size_t>(maxSlot + 1), -1);
    for (size_t i = 0; i < plan->entries.size(); ++i) plan->bySlot[static_cast<size_t>(plan->entries[i].slot)] = static_cast<int>(i);
    // A plan the audio thread never took: its automation tables and orphans carry over into this one.
    if (Plan* untaken = next_.exchange(nullptr, std::memory_order_acq_rel)) {
        for (Plan::Entry& old : untaken->entries) {
            if (old.automation.empty()) continue;
            for (Plan::Entry& e : plan->entries)
                if (e.host == old.host && e.rack == old.rack && e.automation.empty()) e.automation = std::move(old.automation);
        }
        for (void* o : untaken->orphans) plan->orphans.push_back(o);
        plans_.erase(untaken);
        delete untaken;
    }
    Plan* sent = plan.release();
    plans_.insert(sent);
    ctl_ = sent;
    next_.store(sent, std::memory_order_release);
}

bool NoteFxManager::setParam(const std::string& layer, uint32_t index, const std::string& param, double value) {
    auto it = layers_.find(layer);
    return it != layers_.end() && it->second.rack && it->second.rack->setValue(index, param, value);
}

bool NoteFxManager::setBypass(const std::string& layer, uint32_t index, bool bypass) {
    auto it = layers_.find(layer);
    return it != layers_.end() && it->second.rack && it->second.rack->setBypass(index, bypass);
}

int32_t NoteFxManager::readDisplay(const std::string& layer, uint32_t index, float* out, uint32_t max) const {
    auto it = layers_.find(layer);
    if (it == layers_.end() || !it->second.rack || !it->second.host) return -1;
    const uint32_t newest = it->second.host->stats().newestSlot;
    NoteFxRack& r = *it->second.rack;
    return r.slot(static_cast<int>(std::min<uint32_t>(newest, static_cast<uint32_t>(r.slots() - 1)))).readDisplay(index, out, max);
}

bool NoteFxManager::setLinkAmount(uint32_t linkId, double amount) {
    if (!ctl_ || !std::isfinite(amount)) return false;
    bool found = false;
    for (Plan::Entry& e : ctl_->entries) {
        if (!e.links) continue;
        for (size_t k = 0; k < e.links->links.size(); ++k)
            if (e.links->links[k].id == linkId) {
                e.links->amounts[k].store(std::clamp(amount, -1.0, 1.0), std::memory_order_relaxed);
                found = true;
            }
    }
    return found;
}

uint64_t NoteFxManager::latencyFrames(const std::string& layer) const noexcept {
    auto it = layers_.find(layer);
    return it != layers_.end() && it->second.rack ? it->second.rack->latencyFrames() : 0;
}

const ComponentChain* NoteFxManager::chainFor(const std::string& layer) const noexcept {
    auto it = layers_.find(layer);
    if (it != layers_.end() && it->second.rack) return &it->second.rack->slot(0);
    auto p = pending_.find(layer);
    return p != pending_.end() && p->second ? &p->second->slot(0) : nullptr;
}

bool NoteFxManager::stats(const std::string& layer, NoteFxStats& out) const {
    auto it = layers_.find(layer);
    if (it == layers_.end() || !it->second.host || !it->second.rack) return false;
    out = it->second.host->stats();
    if (out.voices == 0) {  // not played yet
        out.voices = static_cast<uint32_t>(it->second.rack->voices());
        out.budget = out.voices;
    }
    return true;
}

void NoteFxManager::beginChunk() noexcept {
    Plan* in = waiting_ ? waiting_ : next_.exchange(nullptr, std::memory_order_acq_rel);
    waiting_ = nullptr;
    if (!in) return;
    // Room to hand back everything this swap may retire: the old plan, each host it drops (with two racks), each
    // rack a swap displaces, and the orphans.
    size_t need = 1 + in->entries.size() + in->orphans.size();
    if (cur_) need += 3 * cur_->entries.size();
    if (retire_->writable() < need) {
        waiting_ = in;
        return;
    }
    for (Plan::Entry& e : in->entries) {
        NoteFxHost& h = *e.host;
        h.installed.store(true, std::memory_order_relaxed);
        h.retire_ = retire_.get();
        h.links_ = e.links.get();
        h.swapRack(e.rack);
        if (e.rack)
            for (size_t k = 0; k < e.automation.size() && static_cast<int>(k) < e.rack->chains(); ++k)
                e.automation[k].reset(e.rack->chain(static_cast<int>(k)).swapAutomation(e.automation[k].release()));
    }
    if (cur_)
        for (const Plan::Entry& old : cur_->entries) {
            bool kept = false;
            for (const Plan::Entry& e : in->entries) kept = kept || e.host == old.host;
            if (!kept) retire_->push(tagged(old.host, kTagHost));  // its racks go with it
        }
    for (void* o : in->orphans) {
        const uintptr_t bits = reinterpret_cast<uintptr_t>(o);
        void* ptr = reinterpret_cast<void*>(bits & ~static_cast<uintptr_t>(3));
        const bool played = (bits & 3u) == kTagRack ? static_cast<NoteFxRack*>(ptr)->installed.load(std::memory_order_relaxed)
                                                    : static_cast<NoteFxHost*>(ptr)->installed.load(std::memory_order_relaxed);
        if (!played) retire_->push(o);  // one that played goes back through its host
    }
    in->orphans.clear();
    if (cur_) retire_->push(tagged(cur_, kTagPlan));
    cur_ = in;
}

NoteFxHost* NoteFxManager::forSlot(int slot) noexcept {
    if (!cur_ || slot < 0 || static_cast<size_t>(slot) >= cur_->bySlot.size()) return nullptr;
    const int i = cur_->bySlot[static_cast<size_t>(slot)];
    return i < 0 ? nullptr : cur_->entries[static_cast<size_t>(i)].host;
}

}  // namespace caw
