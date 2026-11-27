// Mixer audio thread: the render loop, its commands and every numeric audio-path function (the control side is engine_pool.cpp, engine_project.cpp and engine_control.cpp).
#include "engine_impl.h"

namespace caw {

namespace {

constexpr double kSwapSeconds = 0.02;
constexpr double kStopSeconds = 0.01;
constexpr double kPlayTailSeconds = 0.005;   // Play after Stop: a ringing instrument fades out over this
constexpr double kPlayTailQuietSeconds = 0.1;  // ... if its track sounded within the last 0.1 s
constexpr double kPreviewGlideSeconds = 0.005;  // a held preview glides to a new pitch this fast (a bend being drawn)
constexpr float kPreviewQuiet = 1e-4f;          // -80 dB: a preview's effect tail below this has died away
constexpr double kPreviewQuietSeconds = 0.25;   // ... once it has stayed below it this long
constexpr double kPreviewTailSeconds = 30.0;    // the longest a tail (or a self-oscillating effect) keeps running
constexpr double kLimitCeiling = 0.977;  // about -0.2 dBFS

double automationValue(const std::vector<AutomationPointSpec>& points, double at, double fallback) noexcept {
    return automationLaneValue(points.data(), points.size(), at, fallback);  // the one lane rule (params.h)
}

void storeMax(std::atomic<float>& a, float v) {
    float cur = a.load(std::memory_order_relaxed);
    while (v > cur && !a.compare_exchange_weak(cur, v, std::memory_order_relaxed)) {
    }
}

}  // namespace

// ===================== audio thread =====================

int Engine::liveDevices() noexcept { return gLiveDevices.load(std::memory_order_relaxed); }

// Audio thread, once per callback: whether this callback's chunks run the graph with the pool. The caller also
// leaves a profiling engine serial (process(): `wantsMixPool() && !chunkProfile_`): a ChainProfile's slots are filled by
// one thread at a time.
bool Engine::wantsMixPool() const noexcept {
    if (!pool_) return false;
    // An offline render's pool leaves the cores to a live device that started meanwhile (checked every callback).
    if (offlinePool_ && liveDevices() != 0) return false;
    switch (static_cast<MixParallel>(mixMode_.load(std::memory_order_relaxed))) {
        case MixParallel::Always: return true;
        case MixParallel::Never: return false;
        case MixParallel::Auto: break;
    }
    return mixAuto_;
}

bool Engine::slotForeign(const Slot& s) noexcept {
    for (const ComponentChain* c : {s.instrument, s.instrumentFading, s.inserts, s.insertsFading})
        if (c && c->foreign()) return true;
    const NoteFxHost* fx = noteFx_->forSlot(s.index);
    return fx && fx->foreign();
}

// Audio thread: slot i joins the in-use list (kept ascending, so loops over it run in index order as
// the full scans did). It leaves in processChunk once nothing is left for a loop to do there.
// Stopped: an audio track monitoring its input runs as a held preview would, so its input is heard through its chain.
void Engine::wakeMonitors() noexcept {
    // Each stopped callback while monitoring is wanted: only the slots in use (an active slot is listed, A4/#133).
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
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

int64_t Engine::midiClockNs() noexcept {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch())
        .count();
}

// The preview's commands, with the frames to the song's next beat and bar for a start in time with it (while the
// song plays past any count-in; a loop's wrap before the beat is not looked at: the start then lands off the beat).
void Engine::takePreview() noexcept {
    SamplePreview::SongClock clock;
    if (playing_ && countInLeft_ == 0 && stopFade_ == 0) {
        const double step = songStep(g_);
        const double beat = step / 4.0;
        const double nextBeat = std::ceil(beat - 1e-9);
        clock.toBeat = static_cast<int64_t>(std::max(0.0, std::ceil(song_->tempo.frameAt(nextBeat * 4.0) - static_cast<double>(g_))));
        int64_t bar = 0;
        double inBar = 0;
        song_->sigs.barAt(beat, bar, inBar);
        const TimeSigSpec& sig = song_->sigs.sigs()[song_->sigs.indexAt(beat)];
        const double barBeats = sig.num * 4.0 / std::max(1, sig.den);
        const double toNext = inBar < 1e-9 ? 0.0 : barBeats - inBar;
        clock.toBar = static_cast<int64_t>(std::max(0.0, std::ceil(song_->tempo.frameAt((beat + toNext) * 4.0) - static_cast<double>(g_))));
    }
    samplePreview_->take(clock);
    // Through a track's effects (the browser's toggle): stopped, its slot is woken as a monitoring track is, so
    // the preview runs through its inserts and mix; a muted or soloed-out track doesn't run and the preview goes
    // to the master as usual (runMasterNode, mixToneOnly).
    const int rs = samplePreview_->route();
    if (rs >= 0 && rs < slotCount_ && !playing_) {
        Slot& s = slotAt(rs);
        if (s.active && s.track && !s.previewing) {
            if (s.instrument && s.instrumentIdle) {
                s.instrument->reset();
                s.instrument->notes()->forget(false);
                s.instrument->notes()->clearEvents();
                s.instrumentIdle = false;
            }
            s.previewing = true;
            s.previewQuiet = s.previewTail = 0;
            previewing_ = true;
            markLive(rs);
        }
    }
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

void Engine::mixToneOnly(float* left, float* right, int frames, bool previewTaken) noexcept {
    SamplePreview& pv = *samplePreview_;
    const bool preview = pv.active() && !previewTaken;  // a track that took it already played it
    if (toneLeft_ <= 0 && !preview) return;
    const double rel = detExp(-1.0 / (0.1 * sr_));
    const bool bypass = bypass_.load(std::memory_order_relaxed);
    for (int j = 0; j < frames && (toneLeft_ > 0 || (preview && pv.active())); ++j) {
        const double t = toneLeft_ > 0 ? nextTone() : 0.0;
        double yl = static_cast<double>(left[j]) + t, yr = static_cast<double>(right[j]) + t;
        if (preview && pv.active()) pv.next(yl, yr);
        const double env = std::max(std::fabs(yl), std::fabs(yr));
        limEnv_ = env > limEnv_ ? env : env + (limEnv_ - env) * rel;
        const double gain = bypass ? 1.0 : (limEnv_ > kLimitCeiling ? kLimitCeiling / limEnv_ : 1.0);
        left[j] = static_cast<float>(yl * gain);
        right[j] = static_cast<float>(yr * gain);
    }
}

void Engine::startPlay(double fromStep, uint64_t playCount, uint32_t touchStamp) noexcept {
    playing_ = true;
    // Ringing tails play on into the new pass (state kept), as the effects would have.
    masterTailLeft_ = 0;
    masterTailFade_ = 0;
    // Only the slots in use (live_, A4/#133): a slot leaves the list with no tail (processChunk).
    for (int k = 0; k < liveCount_; ++k) {
        slotAt(live_[k]).insertTail = false;
        slotAt(live_[k]).tailFade = 0;
    }
    // Feedback sends start from silence at each Play, as an export does (between chunks: no node reads them now).
    for (int k = 0; k < liveCount_; ++k)
        if (SendTable* t = slotAt(live_[k]).sends)
            for (int j = 0; j < t->count; ++j)
                if (t->routes[j].ring) t->routes[j].ring->clear();
    touchEpoch_ = playCount;  // chains from before this Play drop their touches at their next chunk
    touchPlayStamp_ = touchStamp;
    ++modPlays_;  // project modulators restart at the next chunk (#161)
    // Resuming starts mid-loop: each track works out its own loop pass from g_ at its next chunk. Code
    // there may be far from zero, and a Play during a stop fade cuts it short, so both fade in.
    // In steps, converted with the tempo the Transport commands before it set, so a tempo change made
    // while paused still resumes on the same beat.
    {
        const double at = std::isfinite(fromStep) && fromStep > 0 ? song_->tempo.roundFrame(fromStep) : 0.0;
        g_ = at > 0 && at < static_cast<double>(loopLen_) ? static_cast<int64_t>(at) : 0;
    }
    playRampIn_ = g_ > 0 || stopFade_ > 0 ? std::max(1, static_cast<int>(kStopSeconds * sr_)) : 0;
    stopFade_ = 0;
    lanesOff(midiFrame_, true);  // MIDI-out layers: what sounds ends, and each one's program goes out (API 47)
    clockStart(midiFrame_);
    epoch_ = 0;
    dcL_[0] = dcL_[1] = dcR_[0] = dcR_[1] = 0;
    limEnv_ = 0;
    // The instruments still ringing share the play-tail budget, so Play's callback stays bounded.
    {
        // An active slot is always in live_ (Install and ConfigureBus list it), so these visit the same slots, in
        // the same order, as a scan of the capacity.
        int ringing = 0;
        for (int k = 0; k < liveCount_; ++k)
            if (ringsAtPlay(slotAt(live_[k]))) ++ringing;
        const int tailLen = ringing > 0 ? std::max(1, kPlayTailBudgetFrames / ringing) : 0;
        updateSolo();  // the loop changes no slot's activity, removal or solo, so once is enough
        for (int k = 0; k < liveCount_; ++k) {
            Slot& s = slotAt(live_[k]);
            if (!s.active) continue;
            s.playTailLen = s.playTailAt = 0;
            if (s.midiOut) {  // a MIDI-out layer (API 47): what it played ends, the new pass starts from silence
                NoteEvents& notes = s.midiOut->notes();
                notes.releaseAll(0, true);
                if (!notes.holdsPreview()) {
                    notes.forget(false);
                    notes.clearEvents();
                }
            }
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

// Audio thread, at the end of each callback: where the transport is on the map it plays by, for position() (a
// sequence lock: the reader retries while a write is under way; never blocks the audio thread).
void Engine::publishSongPos() noexcept {
    const double step = songStep(g_);
    const double beat = step / 4.0;
    int64_t bar = 0;
    double inBar = 0;
    song_->sigs.barAt(beat, bar, inBar);
    const TimeSigSpec& sig = song_->sigs.sigs()[song_->sigs.indexAt(beat)];
    const uint32_t seq = posSeq_.load(std::memory_order_relaxed);
    posSeq_.store(seq + 1, std::memory_order_relaxed);
    std::atomic_thread_fence(std::memory_order_release);
    pos_.frame.store(g_, std::memory_order_relaxed);
    pos_.beat.store(beat, std::memory_order_relaxed);
    pos_.bpm.store(song_->tempo.bpmAtStep(step), std::memory_order_relaxed);
    pos_.bar.store(bar, std::memory_order_relaxed);
    pos_.inBar.store(inBar, std::memory_order_relaxed);
    pos_.sig.store(sig.num * 64 + sig.den, std::memory_order_relaxed);
    posSeq_.store(seq + 2, std::memory_order_release);
}

void Engine::updateTiming() noexcept {
    // Every step-to-sample position goes through the tempo map; with one tempo it is roundFrames(step, stepLen_).
    const TempoMap& tm = song_->tempo;
    stepLen_ = tm.stepFrames();
    timeConstant_ = tm.constant();
    simpleClicks_ = timeConstant_ && song_->sigs.simple(beatsPerBar_);
    loopLen_ = static_cast<int64_t>(tm.roundFrame(loopSteps_));
    if (loopLen_ < 1) loopLen_ = 1;
    loopFrom_ = loopRange_ ? std::clamp<int64_t>(static_cast<int64_t>(tm.roundFrame(loopFromSteps_)), 0, loopLen_ - 1) : 0;
    loopTo_ = loopRange_ ? std::clamp<int64_t>(static_cast<int64_t>(tm.roundFrame(loopToSteps_)), loopFrom_ + 1, loopLen_) : loopLen_;
}

// Audio thread: a new tempo map and signatures (Transport, SetSong). The one it replaces goes back to the control
// thread. Held notes end when the tempo changes (every note moves in time). While playing, a change of one tempo to
// another keeps the sample position, as before the map; any change involving a tempo map keeps the beat instead.
void Engine::takeSong(SongTime* next, bool follow) noexcept {
    if (!next) return;
    SongTime* old = song_;
    const bool changed = old->tempo.points() != next->tempo.points();
    // Following a MIDI clock (API 47) moves the tempo a little at a time: the beat and the held notes stay.
    if (changed && !follow)
        for (int i = 0; i < slotCount_; ++i)
            if (NoteEvents* n = notesOf(slotAt(i))) n->releaseAll(0, true);
    const bool keepBeat = changed && (follow || !(old->tempo.constant() && next->tempo.constant()));
    const double beat = keepBeat ? old->tempo.stepAt(static_cast<double>(g_)) : 0.0;
    // Inside the loop range, playback stays inside it (keepInRange, after the new timing is worked out): the kept
    // beat rounded could land on the new range's end, where wrapAt() would no longer wrap.
    keptInRange_ = keepBeat && loopRange_ && g_ >= loopFrom_ && g_ < loopTo_;
    song_ = next;
    bpm_ = next->tempo.points().front().bpm;
    audioIn_->setSongTime(next);
    if (keepBeat) {
        const double at = next->tempo.frameAt(beat);
        // Following a clock (API 47) the new map keeps the timing up to past the playhead: the sample stays (a
        // round trip through beats may land a hair under it, which floor would turn into a one-sample jump).
        if (!(follow && std::fabs(at - static_cast<double>(g_)) < 1.0))
            g_ = std::max<int64_t>(0, static_cast<int64_t>(std::floor(at)));
    }
    Retired r;
    r.song = old;
    retireEntry(r);
}

void Engine::keepInRange() noexcept {
    if (keptInRange_ && loopRange_) g_ = std::clamp<int64_t>(g_, loopFrom_, loopTo_ - 1);
    keptInRange_ = false;
}

double Engine::songStep(int64_t frame) const noexcept {
    // The chunk's frames come from chunkSteps_ (worked out once a chunk; per-sample lanes read them).
    if (timeConstant_) return static_cast<double>(frame) / stepLen_;
    const int64_t k = frame - chunkStepsAt_;
    return k >= 0 && k < chunkStepsLen_ ? chunkSteps_[k] : song_->tempo.stepAt(static_cast<double>(frame));
}

int64_t Engine::passFrame(const Slot& s, double step) const noexcept {
    if (timeConstant_) return static_cast<int64_t>(sampletime::roundFrames(step, stepLen_));
    return static_cast<int64_t>(song_->tempo.roundFrame(s.passStep + step)) - s.passStart;
}

double Engine::passStepLen(const Slot& s, double step) const noexcept {
    return timeConstant_ ? stepLen_ : song_->tempo.stepFramesAt(s.passStep + step);
}

int64_t Engine::wrapAt() const noexcept { return loopRange_ && g_ < loopTo_ ? loopTo_ : loopLen_; }

size_t Engine::retireRoom() const noexcept {
    // The callback may use the queue plus its preallocated overflow list. When
    // overflow is already in use, retire() appends there until the control thread
    // drains the queue and a later callback can move the pending entries across.
    const size_t pendingFree = static_cast<size_t>(pendingMax_ - pendingCount_);
    if (pendingCount_ != 0) return pendingFree;
    return retired_->writable() + pendingFree;
}

// Outside the graph (the callback thread; the node lists are empty there: flushRetires).
bool Engine::canRetire(size_t count) const noexcept { return count <= retireRoom(); }

// Inside the graph: what fits in the node's own list and its share of the room (assignRetireBudgets).
bool Engine::canRetireNode(const RetireList& list, int count) noexcept {
    return count >= 0 && list.count + count <= list.budget;
}

// Audio thread, before the graph runs: each list's share of the queue's free room, in the order flushRetires
// pushes them (the live slots by index, the master's last), so what any node may retire this chunk is fixed
// before any of them runs, on whichever thread (speed phase 5c).
// When the room is short, every list first gets an even share, and what is left goes round from a starting list
// that moves on each chunk, so no slot is always last (5c's greedy order starved the higher slots).
void Engine::assignRetireBudgets() noexcept {
    const size_t room = retireRoom();
    const int lists = liveCount_ + 1;  // the live slots, then the master's
    auto list = [this](int k) noexcept -> RetireList& { return k < liveCount_ ? slotAt(live_[k]).retires : *masterRetires_; };
    constexpr size_t cap = RetireList::kCapacity;
    if (room >= cap * static_cast<size_t>(lists)) {
        for (int k = 0; k < lists; ++k) list(k).budget = static_cast<int>(cap);
        return;
    }
    const size_t even = room / static_cast<size_t>(lists);
    size_t left = room - even * static_cast<size_t>(lists);
    for (int k = 0; k < lists; ++k) list(k).budget = static_cast<int>(even);
    retireStart_ = retireStart_ % lists;
    for (int i = 0; i < lists && left > 0; ++i) {
        RetireList& l = list((retireStart_ + i) % lists);
        const size_t more = std::min(left, cap - static_cast<size_t>(l.budget));
        l.budget += static_cast<int>(more);
        left -= more;
    }
    retireStart_ = (retireStart_ + 1) % lists;
}

// Audio thread, inside the graph: a node hands something back into its own list (never the shared queue, which
// another node may be using: speed phase 5c). The callers asked canRetireNode first, so it always fits; if one
// didn't, the item stays with its owner's caller unretired this chunk (a leak at worst, never a free while the
// graph may still read it).
bool Engine::nodeRetire(RetireList& list, const Retired& r) noexcept {
    if (list.count < list.budget && list.count < RetireList::kCapacity) {
        list.items[list.count++] = r;
        return true;
    }
    assert(!"a graph node retired more than canRetireNode allowed");
    return false;
}

bool Engine::nodeRetireChain(RetireList& list, ComponentChain* chain) noexcept {
    if (!chain) return true;
    Retired r;
    r.masterChain = chain;
    return nodeRetire(list, r);
}

// Audio thread, once the graph has run a chunk: every node's retirements into the queue, slot by slot, the master's
// last. Each fits its share of the room (assignRetireBudgets, canRetireNode), so the queue takes them all.
// The nodes' routing flags too (a bus freed inside the graph re-derives the routing before the next chunk).
void Engine::flushRetires() noexcept {
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        RetireList& list = s.retires;
        for (int j = 0; j < list.count; ++j) retireEntry(list.items[j]);
        list.count = 0;
        list.budget = 0;
        if (s.routingChanged) {
            s.routingChanged = false;
            routingDirty_ = true;
        }
    }
    RetireList& master = *masterRetires_;
    for (int j = 0; j < master.count; ++j) retireEntry(master.items[j]);
    master.count = 0;
    master.budget = 0;
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
            case Cmd::Transport:
            case Cmd::SetSong: retirementNeed = c.song ? 1 : 0; break;  // the tempo map replaced
            case Cmd::SetAutomation:
            case Cmd::SetComponentAutomation:
            case Cmd::SetPattern:
            case Cmd::Remove:
            case Cmd::SetOrder:
            case Cmd::Grow:
            case Cmd::SetVca: retirementNeed = 1; break;
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
                    setShed(s, false);
                    s.restoreDelay = 0;
                    s.bus = false;
                    s.k = -1;
                    s.epoch = -1;
                    s.resetVca();
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
                if (s.midiOut) {
                    s.midiOut->allOff(0);
                    flushLane(*s.midiOut, midiFrame_);
                    s.midiOut->notes().forget(false);
                    s.midiOut->notes().clearEvents();
                    s.midiOut = nullptr;
                }
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
                s.resetVca();
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
                if (NoteEvents* held = notesOf(s)) {
                    // None keeps pointing into the old pattern.
                    NoteEvents& notes = *held;
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
                if (s.midiOut) {  // a removed MIDI-out layer's notes end now; the slot sends nothing more
                    s.midiOut->allOff(0);
                    flushLane(*s.midiOut, midiFrame_);
                    s.midiOut->notes().forget(false);
                    s.midiOut->notes().clearEvents();
                    s.midiOut = nullptr;
                }
                retire(nullptr, nullptr, s.automation);
                s.automation = nullptr;
                break;
            }
            case Cmd::SetSong:
                takeSong(c.song, c.flag);
                updateTiming();
                keepInRange();
                if (g_ >= loopLen_) g_ = 0;
                loopLenFlag_.store(loopLen_, std::memory_order_relaxed);
                break;
            case Cmd::Transport:
                // A tempo change moves every note in time: takeSong lets held notes go so none is left hanging.
                takeSong(c.song);
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
                keepInRange();
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
                        const bool stays = was && was->dest == r.dest && was->key == r.key && was->feedback == r.feedback;
                        r.gain = stays ? was->gain : 0.0;
                        r.ok = stays && was->ok;
                        if (stays && r.gain > 0.0) r.tapPre = was->tapPre;
                        if (r.delay && stays && !s.routesStale) r.delay->takeHistory(was->delay);
                        if (r.ring && stays && was->ring) r.ring->takeHistory(*was->ring);  // a feedback send carries on
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
                    if (r.gain == 0.0) r.tapPre = r.pre;
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
            case Cmd::SetMidiOut: {
                Slot& s = slotAt(c.slot);
                if (s.midiOut && s.midiOut != c.midiLane) {  // not one any more (or another lane): its notes end
                    s.midiOut->allOff(0);
                    flushLane(*s.midiOut, midiFrame_);
                    s.midiOut->notes().forget(false);
                    s.midiOut->notes().clearEvents();
                }
                if (c.midiLane) {
                    const int program = c.midiLane->config().program;
                    c.midiLane->configure(c.midiSpec);  // a new port or channel ends the old one's notes first
                    // The program goes at each Play (startPlay); here only a change, or a new layer while playing.
                    const bool fresh = c.midiLane != s.midiOut;
                    if (c.midiSpec.program >= 0 && (fresh ? playing_ : program != c.midiSpec.program))
                        c.midiLane->sendProgram(0);
                    flushLane(*c.midiLane, midiFrame_);
                }
                s.midiOut = c.midiLane;
                break;
            }
            case Cmd::Play:
                countInLeft_ = 0;
                if (c.countInBeats > 0 && stepLen_ > 0 && !playing_) {
                    // Count-in: clicks first; process() starts the playback when they end. Its beats are the
                    // metronome's ticks (1/den notes) at the tempo and signature where the playback starts.
                    const double from = std::isfinite(c.fromStep) && c.fromStep > 0 && c.fromStep < loopSteps_ ? c.fromStep : 0.0;
                    const TimeSigSpec& sig = song_->sigs.sigs()[song_->sigs.indexAt(from / 4.0)];
                    const double unit = 4.0 / sig.den;
                    countInBar_ = sig.num;
                    countInBeat_ = std::max<int64_t>(1, static_cast<int64_t>(std::llround(unit * 4.0 * song_->tempo.stepFramesAt(from))));
                    countInLeft_ = countInBeat_ * (c.countInBars ? c.countInBeats * sig.num : c.countInBeats);
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
                if (playing_ && stopFade_ == 0) {  // MIDI out (API 47): notes end and the clock stops at once
                    lanesOff(midiFrame_, false);
                    if (clockPorts_) clockSend(clockPorts_, midiFrame_, midibyte::kStop);
                    clockPorts_ = 0;
                }
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
            case Cmd::ClearOverload: resetShedding(); break;
            case Cmd::SetVca: {
                // The project's VCA groups: groups that stay carry on from their gain; the one replaced is freed on
                // the control thread. Every slot ramps from the VCA gain it had to its new groups' (runVca), and
                // updateSolo refreshes their mute and solo.
                if (c.vca && vca_) c.vca->takeHistory(*vca_);
                if (vca_) {
                    Retired r;
                    r.vca = vca_;
                    retireEntry(r);
                }
                vca_ = c.vca;
                for (int i = 0; i <= capacity_; ++i) {
                    Slot& s = slotAt(i);
                    s.vcaMute = s.vcaSolo = false;
                    s.vcaDirty = true;
                    s.vcaFresh = false;  // what played before this table played at its VCA gain (an Install after it is fresh)
                }
                vcaActive_ = true;
                updateSolo();
                break;
            }
        }
    }
}

double Engine::slotTarget(const Slot& s) const noexcept {
    if (s.removing || s.overloaded) return 0.0;
    if (auditionOnly_) return s.index == auditionSlot_ ? bitsToDouble(s.vol.load(std::memory_order_relaxed)) : 0.0;
    if (s.index == auditionSlot_) return 0.0;
    if (s.mute.load(std::memory_order_relaxed) || s.vcaMute) return 0.0;  // its own mute, or a VCA group's
    if (anySolo_ && !s.solo.load(std::memory_order_relaxed) && !s.vcaSolo) return 0.0;
    return s.automation && !s.automation->volume.empty() ? 1.0 : bitsToDouble(s.vol.load(std::memory_order_relaxed));
}

void Engine::updateSolo() noexcept {
    if (vca_) {  // the slots' VCA mute and solo first: a group's solo counts as its members'
        for (int k = 0; k < liveCount_; ++k) {
            Slot& s = slotAt(live_[k]);
            vca_->flags(live_[k], s.vcaMute, s.vcaSolo);
        }
    }
    bool any = false;
    for (int k = 0; k < liveCount_ && !any; ++k) {
        const int i = live_[k];
        if (i >= capacity_) break;  // the audition, always last
        const Slot& s = slotAt(i);
        any = s.active && !s.removing && (s.solo.load(std::memory_order_relaxed) || s.vcaSolo);
    }
    anySolo_ = any;
}

// Once a chunk, before the graph runs: each group's gain per frame, then each slot's product of its groups' gains,
// which its track or bus node and its post keys multiply after its own volume (and volume lane). A slot whose groups
// changed (a new table, or none) ramps from the gain it had by an offset that decays with the faders' pole, so
// joining, leaving, a new or deleted group, or a lane added or taken away never jumps. A slot whose VCA gain is
// exactly 1 throughout (in no group, or settled at unity) is off (vcaOn false) and takes the nodes' plain paths.
void Engine::runVca(int m) noexcept {
    const double coef = trackGainCoef_;
    if (vca_) {
        double steps[kBlock];
        if (vca_->hasLane)
            for (int i = 0; i < m; ++i) steps[i] = songStep(g_ + i);
        vca_->advance(vca_->hasLane ? steps : nullptr, m, coef);
    }
    bool active = false;
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        const bool member = vca_ && vca_->product(live_[k], m, s.vca);
        if (s.vcaDirty) {
            s.vcaOffset = s.vcaFresh ? 0.0 : s.vcaLast - (member ? s.vca[0] : 1.0);
            s.vcaDirty = s.vcaFresh = false;
        }
        if (!member) {
            if (s.vcaOffset == 0.0) {
                s.vcaOn = false;
                s.vcaLast = 1.0;
                continue;
            }
            std::fill_n(s.vca, m, 1.0);
        }
        bool unity = s.vcaOffset == 0.0;
        for (int i = 0; i < m; ++i) {
            if (s.vcaOffset != 0.0) {
                s.vca[i] = std::max(0.0, s.vca[i] + s.vcaOffset);
                s.vcaOffset -= s.vcaOffset * coef;
                if (std::fabs(s.vcaOffset) < 1e-6) s.vcaOffset = 0.0;
            }
            unity = unity && s.vca[i] == 1.0;
        }
        s.vcaOn = !unity;
        s.vcaLast = m > 0 ? s.vca[m - 1] : s.vcaLast;
        active = active || s.vcaOn || s.vcaOffset != 0.0;
    }
    vcaActive_ = active;
}

int64_t Engine::loopStart(const Slot& s, int64_t k) const noexcept {
    if (timeConstant_) return static_cast<int64_t>(sampletime::roundRepeat(k, s.steps, stepLen_));
    return static_cast<int64_t>(song_->tempo.roundFrame(static_cast<double>(k) * s.steps));
}

// The note's expression `into` samples after it took the voice: bend (curve + vibrato), press and timbre.
// A cut note (#226: a clip's end, loop point or source offset) plays its part [from, from + span] of the written
// note's curves and vibrato, as the written note had them there.
static void expressionAt(const NoteExpression& x, double into, double len, double sr, double& bend, double& press, double& timbre) {
    const bool whole = x.from == 0 && x.span == 1;
    const double u = whole ? std::clamp(into / len, 0.0, 1.0) : std::clamp(x.from + x.span * std::clamp(into / len, 0.0, 1.0), 0.0, 1.0);
    bend = !x.bend.points.empty() ? x.bend.at(u) : 0.0;
    if (x.vibDepth > 0) {
        const double fade = x.vibDelay > 0 ? std::clamp(u / x.vibDelay, 0.0, 1.0) : 1.0;
        const double t = whole ? into : into + x.from * len / x.span;  // samples since the written note's start
        bend += x.vibDepth * fade * detSin(kTwoPi * x.vibRate * t / sr);
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
    // A full list leaves the rest in the queue for a later callback (the producer drops or merges, never here).
    Midi2Event e;
    while (midiPendingCount_ < Midi2InputQueue::kCapacity && midiIn_.pop(e)) {
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
                if (NoteEvents* n = notesOf(s)) s.deviceNotes.apply(*n, p.e, 0, o);  // its notes, then reset
                else s.deviceNotes.reset();
            }
            p.done = true;
            p.frame = 0;
            continue;
        }
        p.frame = deviceMidiFrame(p.e.timeNs, now, frames, sr_, delay);
    }
    // Lower frame first, then lower sequence (a value merged under pressure arrives late with its own). Insertion
    // sort: bounded by the list, and the list is nearly in order already.
    for (uint32_t k = 1; k < midiPendingCount_; ++k) {
        const PendingMidi x = midiPending_[k];
        uint32_t j = k;
        for (; j > 0; --j) {
            const PendingMidi& y = midiPending_[j - 1];
            if (y.frame < x.frame || (y.frame == x.frame && static_cast<int32_t>(y.e.seq - x.e.seq) < 0)) break;
            midiPending_[j] = y;
        }
        midiPending_[j] = x;
    }
    for (uint32_t k = 0; k < midiPendingCount_; ++k) {
        PendingMidi& p = midiPending_[k];
        if (p.done || p.frame >= frames) continue;  // an AllOff already applied, or a later callback's
        if (p.e.target < 0 || p.e.target >= slotCount_) {
            p.done = true;
            continue;
        }
        Slot& s = slotAt(p.e.target);
        if (!s.active || !s.track || !notesOf(s)) {
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
        // Its own messages only (target first): another slot's node may be marking its own done at the same time.
        if (p.e.target != s.index || p.done || p.frame >= end) continue;
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
            if (NoteEvents* n = notesOf(s)) n->releasePreviews(0, kDevicePreviewBase);
        }
        return;
    }
    if (c.slot < 0 || c.slot >= slotCount_) return;
    Slot& s = slotAt(c.slot);
    if (!s.active || !s.track || !notesOf(s)) return;
    NoteEvents& notes = *notesOf(s);
    if (s.instrument && s.instrumentIdle) {  // it hasn't run since it fell silent: start it from silence now
        s.instrument->reset();
        notes.forget(false);
        notes.clearEvents();
        s.instrumentIdle = false;
    }
    NoteEvents::Held* held = notes.findPreview(c.previewId);
    if (c.previewOp == 1) {
        if (!held) return;
        held->target = c.pitch;
        held->glideLeft = std::max(1, static_cast<int>(sampletime::roundFrames(kPreviewGlideSeconds, sr_)));
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
        if (!silent && samplePreview_->route() == live_[k]) voices = true;  // the sample preview plays through it
        if (s.midiOut && s.midiOut->notes().holdsPreview()) {  // a MIDI-out layer's held previews (API 47)
            if (silent) {
                s.midiOut->notes().releasePreviews(0);
                s.midiOut->allOff(0);
                flushLane(*s.midiOut, frames);
            } else {
                voices = true;
            }
        }
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
        // Feedback sends stop with the song (a stopped preview never brings back a loop held since the stop).
        if (s.sends)
            for (int j = 0; j < s.sends->count; ++j)
                if (s.sends->routes[j].ring) s.sends->routes[j].ring->clear();
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
        if (s.midiOut) {  // its notes ended at the Stop (lanesOff); what the pattern held is forgotten
            s.midiOut->notes().releaseAll(0, true);
            if (!s.midiOut->notes().holdsPreview()) {
                s.midiOut->notes().forget(false);
                s.midiOut->notes().clearEvents();
            }
        }
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
bool Engine::noteSpan(const Slot& slot, const PatternNote& n, uint32_t sub, int64_t& start, int64_t& stop) const noexcept {
    const int ratchet = std::max(1, n.ratchet);
    if (sub >= static_cast<uint32_t>(ratchet)) return false;
    const int s = static_cast<int>(sub);
    start = passFrame(slot, sampletime::ratchetStep(n.at, n.len, ratchet, s));
    stop = passFrame(slot, sampletime::ratchetStep(n.at, n.len, ratchet, s + 1));
    return true;
}

// A held note carried across a pattern edit, at the start of its next chunk (n0): if its new note still covers the
// playhead it sounds on and its motion carries on from the next control point of its grid (the grid's phase is
// kept), now on the new note's curve, gliding there over kRebindGlideSeconds; otherwise it is released.
void Engine::rebindNote(const Slot& s, NoteEvents& notes, NoteEvents::Held& h, const Pattern* pat, int64_t n0) noexcept {
    h.rebind = false;
    int64_t start = 0, stop = 0;
    const PatternNote* n = pat && h.note < pat->notes.size() ? &pat->notes[h.note] : nullptr;
    if (!n || !noteSpan(s, *n, h.sub, start, stop) || n0 < start || n0 >= stop) {
        notes.off(0, h);
        return;
    }
    const bool expressive = n->extra >= 0 && static_cast<size_t>(n->extra) < pat->expressions.size();
    h.ex = expressive ? &pat->expressions[static_cast<size_t>(n->extra)] : nullptr;
    // Its sub-note's length in samples (one tempo: len / ratchet steps at that tempo, as before the map; on a map,
    // the span the tempo map gives it, so a note across a tempo change takes its real length).
    h.exLen = timeConstant_ ? std::max(1.0, n->len / std::max(1, n->ratchet) * stepLen_)
                            : std::max(1.0, static_cast<double>(stop - start));
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

// Chasing (#226): play, a loop back, a layer's new pass or an unmute that lands inside pattern notes starts them at
// frame 0, as if they had been playing: each pattern note whose on is before n0 (events [0, e)) and whose off is
// after it, unless it already sounds. Its expression (bend, vibrato, pressure, timbre) and glide-free pitch are the
// note's own at n0, and its motion grid carries on from the note's start, so a chased note sounds as the same note
// played through would from there, at any block size, live and in export. The instrument starts its voice there with
// its own attack (a sampler from the sample's start: docs/decisions.md). One pass over the events before n0 with
// a fixed list of the notes still open (kChaseMost; past it the oldest are dropped): no allocation, bounded by the
// pattern, and only at those moments.
void Engine::chaseNotes(Slot& s, NoteEvents& notes, const Pattern* pat, size_t e, int64_t n0) noexcept {
    constexpr int kChaseMost = 128;
    struct Open { uint32_t note; uint16_t sub; int64_t start; };
    Open open[kChaseMost];
    int count = 0;
    const PatternEvent* ev = pat->events.data();
    for (size_t i = 0; i < e; ++i) {
        const PatternEvent& pe = ev[i];
        if (pe.on) {
            if (count == kChaseMost) {
                std::move(open + 1, open + count, open);
                --count;
            }
            open[count++] = {pe.note, pe.sub, passFrame(s, pe.step)};
            continue;
        }
        for (int k = count - 1; k >= 0; --k)
            if (open[k].note == pe.note && open[k].sub == pe.sub) {
                std::move(open + k + 1, open + count, open + k);
                --count;
                break;
            }
    }
    // A note ending exactly at n0 does not sound.
    const size_t ne = pat->events.size();
    for (size_t i = e; i < ne && count > 0 && passFrame(s, ev[i].step) <= n0; ++i) {
        if (ev[i].on) continue;
        for (int k = count - 1; k >= 0; --k)
            if (open[k].note == ev[i].note && open[k].sub == ev[i].sub) {
                std::move(open + k + 1, open + count, open + k);
                --count;
                break;
            }
    }
    for (int k = 0; k < count; ++k) {
        const Open& o = open[k];
        if (o.note >= pat->notes.size() || notes.findPattern(o.note, o.sub)) continue;
        const PatternNote& n = pat->notes[o.note];
        if (!notePlays(n, o.note, s.repeat, seed_)) continue;
        const bool expressive = n.extra >= 0 && static_cast<size_t>(n.extra) < pat->expressions.size();
        const NoteExpression* x = expressive ? &pat->expressions[static_cast<size_t>(n.extra)] : nullptr;
        int64_t start = 0, stop = 0;
        const double exLen = timeConstant_ || !noteSpan(s, n, o.sub, start, stop)
                                 ? std::max(1.0, n.len / std::max(1, n.ratchet) * stepLen_)
                                 : std::max(1.0, static_cast<double>(stop - start));
        const int64_t since = std::max<int64_t>(0, n0 - o.start);
        double bend = 0, press = 1, timbre = 0;
        if (x) expressionAt(*x, static_cast<double>(since), exLen, sr_, bend, press, timbre);
        NoteEvents::Held& h = notes.on(0, NoteEvents::Source::Pattern, o.note, o.sub, -1, safePitch(n.pitch + bend), n.vel);
        if (!h.active) continue;
        h.pitch = h.target = n.pitch;
        h.ex = x;
        h.exLen = exLen;
        if (x && !x->press.points.empty()) notes.pressure(0, h, std::clamp(press, 0.0, 1.0));
        if (x && !x->timbre.points.empty()) notes.timbre(0, h, std::clamp(timbre, 0.0, 1.0));
        // The note's control grid runs on from its start: its next point is this many frames on.
        const int64_t wait = (kExpressionStep - since % kExpressionStep) % kExpressionStep;
        h.since = since + wait;
        h.motionFrom = 0;
        h.motionWait = static_cast<int>(wait);
    }
}

// The pattern's notes in this chunk as the instrument's events, on their exact frames: chance per repeat, ratchets,
// slides (the held note glides on, no new attack), the note's expression, and held notes carried across a pattern
// edit following their new note.
void Engine::instrumentNotes(Slot& s, NoteEvents& notes, int m) noexcept {
    const int64_t n0 = s.n0, end = n0 + m;
    const Pattern* pat = s.pat;
    auto sampleOf = [this, &s](double step) { return passFrame(s, step); };
    for (NoteEvents::Held& h : notes.held())
        if (h.active && h.rebind) rebindNote(s, notes, h, pat, n0);
    if (!pat) {
        s.chase = false;
        return;
    }
    const PatternEvent* ev = pat->events.data();
    const size_t ne = pat->events.size();
    size_t e = static_cast<size_t>(
        std::partition_point(ev, ev + ne, [&](const PatternEvent& x) { return sampleOf(x.step) < n0; }) - ev);
    if (s.chase) {
        s.chase = false;
        if (e > 0) chaseNotes(s, notes, pat, e, n0);
    }
    auto express = [&](NoteEvents::Held& h, const PatternNote& n, uint32_t frame, uint32_t sub) noexcept {
        const bool expressive = n.extra >= 0 && static_cast<size_t>(n.extra) < pat->expressions.size();
        h.ex = expressive ? &pat->expressions[static_cast<size_t>(n.extra)] : nullptr;
        int64_t start = 0, stop = 0;
        h.exLen = timeConstant_ || !noteSpan(s, n, sub, start, stop)
                      ? std::max(1.0, n.len / std::max(1, n.ratchet) * stepLen_)
                      : std::max(1.0, static_cast<double>(stop - start));
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
        if (n.ratchet > 1) {  // a repeat shorter than a sample is not played: at most the note's samples sound
            int64_t start = 0, stop = 0;
            if (noteSpan(s, n, pe.sub, start, stop) && stop <= start) continue;
        }
        if (pe.sub == 0 && n.slideFrom >= 0) {
            const PatternNote& from = pat->notes[static_cast<size_t>(n.slideFrom)];
            if (NoteEvents::Held* h = notes.findPattern(static_cast<uint32_t>(n.slideFrom), static_cast<uint16_t>(from.ratchet - 1))) {
                noteMotion(notes, *h, static_cast<int>(frame));  // its glide and expression up to the slide
                h->note = pe.note;
                h->sub = 0;
                h->pitch = h->sentPitch;  // from the pitch being heard, bend included
                h->target = n.pitch;
                h->glideLeft = std::max(1, static_cast<int>(sampletime::roundFrames(passStepLen(s, n.at), 0.5)));
                h->glideStep = (h->target - h->pitch) / h->glideLeft;
                express(*h, n, frame, 0);
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
        express(h, n, frame, pe.sub);
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
        notes.pitch(frame, h, safePitch(h.pitch + bend));
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
    const int len = std::min({Slot::kPlayTailMax, std::max(1, most), std::max(1, static_cast<int>(sampletime::roundFrames(kPlayTailSeconds, sr_)))});
    ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), false};
    time.song = song_;  // the tempo map at the playhead (1.0.3)
    time.profile = chunkProfile_;
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
    time.song = song_;  // the tempo map at the playhead (1.0.3)
    time.steps = timeConstant_ ? nullptr : chunkSteps_;  // the chunk's song steps (from g_)
    time.modulation = modulation_->forChain(s.index, ModChainKind::Instrument, s.instrument, 0);  // #161
    time.profile = chunkProfile_;  // the Benchmark (setProfile)
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
        s.chase = true;  // unmuted (or back from silence) inside a note: it sounds from here (#226)
    }
    if (s.instrument) {
        NoteEvents& notes = *s.instrument->notes();
        NoteFxHost* noteFx = noteFx_->forSlot(s.index);
        {
            const PartScope voices(parts(), Part::Voices);  // the Benchmark's parts (engine_parts.h)
            if (!previewChunk_) instrumentNotes(s, notes, m);
            if (midiPendingCount_ > 0) feedDeviceMidi(s, notes, m);
            instrumentMotion(notes, m);
            // MIDI effects (1.1.0): the notes as they shape them, before the taps, the per-note FX and the instrument.
            if (s.instrument->midiEffects()) s.instrument->runMidiEffects(static_cast<uint32_t>(m), sr_, &time);
            if (modulation_->listens(s.index)) modulation_->tapNotes(s.index, notes.events(), notes.count());  // #161
            // Per-note FX (#127, note_fx_host.cpp): the host places this block's notes in slots and hands the
            // instrument its voice bus; each lane runs through its slot inside the instrument's block.
            if (noteFx) {
                notes.sort();
                s.instrument->setVoices(noteFx->begin(notes.events(), notes.count(), static_cast<uint32_t>(m), &time,
                    modulation_->forChain(s.index, ModChainKind::NoteFx, noteFx->modChain(), 2), quality()));
            }
        }
        {
            const PartScope devices(parts(), Part::Devices);
            s.instrument->process(s.instL, s.instR, static_cast<uint32_t>(m), sr_, &time);
        }
        if (noteFx) {
            const PartScope voices(parts(), Part::Voices);
            s.instrument->setVoices(nullptr);
            noteFx->end(static_cast<uint32_t>(m));
        }
    } else if (s.midiOut) {
        // A MIDI-out layer (API 47): where an instrument would play its notes, they become MIDI 1.0 bytes, staged
        // in its lane for the end of the chunk (processChunk queues them; the mix pool may run nodes at once).
        MidiOutLane& lane = *s.midiOut;
        NoteEvents& notes = lane.notes();
        const bool stopping = stopFade_ > 0;
        const bool muted = s.target <= 0.0 || offline_.load(std::memory_order_relaxed);
        const bool sends = !muted && !stopping;
        if (muted && !stopping) {
            // Muted or soloed out (while its fader fades): what it sent ends, and it holds nothing, so unmuted it
            // picks up the notes sounding there (chaseNotes) and sends them again.
            if (lane.sounding()) lane.allOff(0);
            notes.forget(false);
            notes.clearEvents();
            s.chase = true;
        } else {
            const PartScope voices(parts(), Part::Voices);
            if (!previewChunk_ && !stopping) instrumentNotes(s, notes, m);
            if (midiPendingCount_ > 0) feedDeviceMidi(s, notes, m);
            instrumentMotion(notes, m);
            notes.sort();
            if (!sends && lane.sounding()) lane.allOff(0);
            lane.convert(notes.events(), notes.count(), sends);
            notes.clearEvents();
        }
        std::fill_n(s.instL, m, 0.0f);
        std::fill_n(s.instR, m, 0.0f);
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
        const PartScope devices(parts(), Part::Devices);
        s.instrumentFading->process(s.fadeL, s.fadeR, static_cast<uint32_t>(m), sr_, &fadeTime);
    } else {
        std::fill_n(s.fadeL, m, 0.0f);
        std::fill_n(s.fadeR, m, 0.0f);
    }
    const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
    for (int i = 0; i < m; ++i) {
        const float w = s.instrumentFadeLeft > 0
            ? static_cast<float>(len - s.instrumentFadeLeft + 1) / static_cast<float>(len + 1) : 1.0f;
        if (s.instrumentFadeLeft > 0) --s.instrumentFadeLeft;
        s.instL[i] = s.fadeL[i] + (s.instL[i] - s.fadeL[i]) * w;
        s.instR[i] = s.fadeR[i] + (s.instR[i] - s.fadeR[i]) * w;
    }
    if (s.instrumentFadeLeft == 0 && s.instrumentFading) {
        if (canRetireNode(s.retires, 1) && nodeRetireChain(s.retires, s.instrumentFading)) {
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
    double layerLen = free ? static_cast<double>(loopLen_) : s.steps * stepLen_;
    const int64_t gg = g_;
    int64_t k = 0, st = 0, nx = loopLen_;
    if (!free) {
        if (timeConstant_) {
            const double S = s.steps * stepLen_;
            k = static_cast<int64_t>(std::floor(static_cast<double>(gg) / S));
        } else {
            k = static_cast<int64_t>(std::floor(song_->tempo.stepAt(static_cast<double>(gg)) / s.steps));
        }
        while (loopStart(s, k + 1) <= gg) ++k;
        while (k > 0 && loopStart(s, k) > gg) --k;
        st = loopStart(s, k);
        nx = std::min<int64_t>(loopStart(s, k + 1), loopLen_);
        if (!timeConstant_) layerLen = static_cast<double>(std::max<int64_t>(1, loopStart(s, k + 1) - st));
    }
    s.passStep = free ? 0.0 : static_cast<double>(k) * s.steps;
    s.passStart = st;
    if (k != s.k || epoch_ != s.epoch) {
        // The layer restarts its pattern: held notes ring out, the instrument and its effects carry on.
        if (!s.fresh && s.instrument && !s.instrumentIdle) s.instrument->notes()->releaseAll(0, true);
        if (!s.fresh && s.midiOut) s.midiOut->notes().releaseAll(0, true);
        s.fresh = false;
        s.chase = true;  // play, a loop back or a new pass may start inside notes: they sound from here (#226)
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
            const double layerLen = s.steps <= 0 ? static_cast<double>(loopLen_)
                                    : timeConstant_ ? s.steps * stepLen_ : song_->tempo.frameAt(s.steps);
            const int64_t len = std::max<int64_t>(1, s.steps <= 0 ? static_cast<int64_t>(std::floor(layerLen + 0.5))
                                                                  : static_cast<int64_t>(song_->tempo.roundFrame(s.steps)));
            s.passStep = 0;
            s.passStart = 0;
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
            if (s.midiOut && s.midiOut->sounding()) {  // muted or soloed out: what it sent ends (API 47)
                s.midiOut->allOff(0);
                flushLane(*s.midiOut, tapAt_);
                s.midiOut->notes().forget(false);
                s.midiOut->notes().clearEvents();
                s.chase = true;
            }
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
                setShed(s, false);  // a removed layer is no longer one the device shed
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
            slot.insertTail = false;  // already so once it stopped previewing; startPlay no longer clears it here
            slot.tailFade = 0;
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
    previewTaken_.store(false, std::memory_order_relaxed);  // a track node that plays the sample preview sets it
    const int m = planChunk(maxFrames);
    if (!timeConstant_) {  // the song step at each of the chunk's frames, for per-sample lanes (songStep)
        song_->tempo.stepsAt(g_, m, chunkSteps_);
        chunkStepsAt_ = g_;
        chunkStepsLen_ = m;
    }
    if (vca_ || vcaActive_) runVca(m);
    audioIn_->chunk(tapAt_, m, g_, playing_ && !previewChunk_);  // monitoring frames and the recorder's input
    audioIn_->setLoopWrap(wrapAt(), loopRange_ ? loopFrom_ : 0);  // audio tracks pre-roll the loop's start
    ++chunkId_;
    // Project modulation (#161): due modulator blocks and every target's offsets, before any target runs.
    {
        const PartScope automation(parts(), Part::Automation);
        modulation_->beginChunk(static_cast<uint32_t>(m), g_, stepLen_, bpm_, static_cast<uint32_t>(beatsPerBar_),
                                playing_ && !previewChunk_, modPlays_, chunkId_, chunkProfile_, song_);
    }
    {
        const PartScope voices(parts(), Part::Voices);
        noteFx_->beginChunk();  // per-note FX (#127): a new plan
    }
    // One graph runs the mix: each track's node, each folder bus after its children (and after every send and
    // key into it), then the master stage. Routing changes only between chunks.
    if (routingDirty_) {
        const PartScope routing(parts(), Part::Routing);
        routingDirty_ = false;
        updateRouting();
    }
    assignRetireBudgets();  // what each node may hand back this chunk, fixed before any of them runs
    // Speed phase 5c: the pool runs each level's nodes at once, but a node holding third-party native code stays on
    // this thread (the serial lane: such code may not be safe to run twice at once; docs/decisions.md), and so does
    // one with nothing to run this chunk (silent or idle: it only writes zeros), so a level with one busy node isn't
    // handed to the pool for nothing.
    if (mixParallel_) {
        const PartScope pool(parts(), Part::MixPool);
        MixGraph& g = *mixGraph_;
        for (int k = 0; k < liveCount_; ++k) {
            const int i = live_[k];
            const Slot& s = slotAt(i);
            const bool serial = (s.mode != Slot::Mode::Play && s.mode != Slot::Mode::Bus) || slotForeign(s);
            g.executor.setNodeSerial(g.trackNode(i), serial);
            g.executor.setNodeSerial(g.busNode(i), serial);
        }
        g.executor.setParallelRunner(pool_.get());
    } else {
        mixGraph_->executor.setParallelRunner(nullptr);
    }
    float* outputs[2] = {l, r};
    bool ran;
    {
        const PartScope mix(parts(), Part::Mix);  // the graph's sums; each node claims its own parts
        if (PartProfile* p = parts()) p->mark = p->last;  // a folder bus first in the graph claims from here
        ran = mixGraph_->executor.process(ConstChannelBufferView{}, ChannelBufferView{outputs, 2, static_cast<uint32_t>(m)},
                                          static_cast<uint32_t>(m));
    }
    if (mixGraph_->executor.parallelLevelsRun() != 0) poolUsed_ = true;
    routeFrame_ += m;  // the route clock: feedback sends' rings move on by the frames just run
    flushRetires();  // what the nodes handed back, now that nothing in the graph reads it
    // MIDI-out layers' bytes (API 47), in slot order, now that no node writes them.
    for (int k = 0; k < liveCount_; ++k)
        if (MidiOutLane* lane = slotAt(live_[k]).midiOut; lane && lane->stagedCount() > 0) flushLane(*lane, tapAt_);
    if (!ran) {
        std::fill_n(l, m, 0.0f);
        std::fill_n(r, m, 0.0f);
        mixToneOnly(l, r, m, previewTaken_.load(std::memory_order_relaxed));  // the master stage did not run
    }
    return m;
}

// Routing as graph edges: a routable slot (active, and a bus or a track) goes to its output bus (parentSlot: the
// project's "output", else its folder's bus) when that is an active folder bus, is dropped when it is anything
// else, and goes to master at the root. Sends (into buses or tracks) and sidechain keys add order but no edges (the source writes the route's own buffer, runRoutes, and the
// destination sums its routes when it runs, pullRoutes; each is a dependency for the executor's levels): a slot runs
// after every slot that feeds it, whether as a child, a send or a key; a feedback send orders nothing (its
// destination reads the chunk before from the route's ring), so it may close a loop. The order is the old pass order
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
    // A route counts when both ends run: into a bus's or a track's input, or a key into a slot with inserts. Only a
    // feedback send may come back to its own slot.
    auto routeDest = [&](const Slot& s, int k) noexcept {
        const SendTable::Route& r = s.sends->routes[k];
        if (r.dest < 0 || r.dest >= slotCount_ || (r.dest == s.index && !r.feedback) || !g.routable[r.dest]) return -1;
        if (r.key >= 0 && !slotAt(r.dest).inserts) return -1;
        return r.dest;
    };
    // What a route orders: its destination after its source; a feedback send orders nothing (it reads the chunk
    // before, from its ring), so it may close a loop.
    auto orderDest = [&](const Slot& s, int k) noexcept { return s.sends->routes[k].feedback ? -1 : routeDest(s, k); };
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
                if (const int d = orderDest(s, k); d >= 0) ++g.pending[d];
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
                for (int k = s.sends->count - 1; k >= 0; --k) release(orderDest(s, k), top);
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
            s.sends->routes[k].ok = d >= 0 && (s.sends->routes[k].feedback || g.position[i] < g.position[d]);
        }
    }
    // Each destination's routes (pullRoutes), in the order the sources used to add into it: the sources in the
    // order they run, each one's routes by index. Each is also a dependency of the destination's node on the
    // source's for the executor's levels (the edges carry only children into their buses).
    auto nodeOf = [&](int x) noexcept { return slotAt(x).bus ? g.busNode(x) : g.trackNode(x); };
    // Into the staging tables (swapped in once the executor accepts): every live slot's count, so slots that don't
    // run this chunk pull nothing.
    for (int j = 0; j < liveCount_; ++j) g.inCountNext[live_[j]] = 0;
    for (int k = 0; k < count; ++k) {
        const Slot& s = slotAt(g.slotOrder[k]);
        if (s.sends)
            for (int j = 0; j < s.sends->count; ++j)
                if (s.sends->routes[j].ok) ++g.inCountNext[s.sends->routes[j].dest];
    }
    int routed = 0;
    for (int k = 0; k < count; ++k) {
        const int x = g.slotOrder[k];
        g.inFirstNext[x] = routed;
        routed += g.inCountNext[x];
        g.inCountNext[x] = 0;  // refilled below
    }
    uint32_t dependencyCount = 0;
    for (int k = 0; k < count; ++k) {
        const int x = g.slotOrder[k];
        const Slot& s = slotAt(x);
        if (!s.sends) continue;
        for (int j = 0; j < s.sends->count; ++j) {
            if (!s.sends->routes[j].ok) continue;
            const int d = s.sends->routes[j].dest;
            g.inRoutesNext[static_cast<size_t>(g.inFirstNext[d] + g.inCountNext[d]++)] = MixGraph::InRoute{s.sends, j};
            if (!s.sends->routes[j].feedback) g.dependencies[dependencyCount++] = GraphDependency{nodeOf(x), nodeOf(d)};
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
    if (g.executor.setRouting(g.edges.data(), edgeCount, g.order.data(), nodeCount, g.dependencies.data(),
                              dependencyCount)) {
        // Accepted: the pull tables made for this order go live (swapping vectors never allocates).
        g.inFirst.swap(g.inFirstNext);
        g.inCount.swap(g.inCountNext);
        g.inRoutes.swap(g.inRoutesNext);
        return;
    }
    routingRejections_.fetch_add(1, std::memory_order_relaxed);
    assert(!"mix graph rejected a derived route");
    // The old order keeps running, but its pull tables may name route tables freed since (a SetSends retired them),
    // so nothing is pulled and no route is written until a routing update is accepted.
    std::fill(g.inCount.begin(), g.inCount.end(), 0);
    for (int j = 0; j < liveCount_; ++j)
        if (SendTable* t = slotAt(live_[j]).sends)
            for (int k = 0; k < t->count; ++k) t->routes[k].ok = false;
}

// A track's latency compensation, with the crossfade of a delay change.
void Engine::runDelay(Slot& s, float* outL, float* outR, int m) noexcept {
    const PartScope routing(parts(), Part::Routing);  // latency compensation (engine_parts.h)
    if (s.delayStale) {  // it held the song's last frames from before a stop or a silence
        if (s.delay) s.delay->clear();
        Retired r;
        r.delay = s.delayFading;
        // A change that was still crossfading is over: the new timing holds.
        if (s.delayFading && canRetireNode(s.retires, 1) && nodeRetire(s.retires, r)) {
            s.delayFading = nullptr;
            s.delayFadeLeft = 0;
        } else if (s.delayFading) {
            s.delayFading->clear();
        }
        s.delayStale = false;
    }
    const bool fading = s.delayFadeLeft > 0;
    if (fading) {
        std::copy_n(outL, m, s.fadeL);
        std::copy_n(outR, m, s.fadeR);
        if (s.delayFading) s.delayFading->run(s.fadeL, s.fadeR, m);
    }
    if (s.delay) s.delay->run(outL, outR, m);
    if (!fading) return;
    const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
    for (int i = 0; i < m; ++i) {
        const float w = s.delayFadeLeft > 0 ? static_cast<float>(len - s.delayFadeLeft + 1) / static_cast<float>(len + 1) : 1.0f;
        if (s.delayFadeLeft > 0) --s.delayFadeLeft;
        outL[i] = s.fadeL[i] + (outL[i] - s.fadeL[i]) * w;
        outR[i] = s.fadeR[i] + (outR[i] - s.fadeR[i]) * w;
    }
    if (s.delayFadeLeft == 0 && s.delayFading) {
        Retired r;
        r.delay = s.delayFading;
        if (canRetireNode(s.retires, 1) && nodeRetire(s.retires, r)) {
            s.delayFading = nullptr;
        } else {
            s.delayFadeLeft = 1;  // no room to hand it back yet: try again next block
        }
    }
}

// A slot's native inserts in place, crossfading from a replaced chain (or the dry signal) over 20 ms.
void Engine::runInserts(Slot& s, float* L, float* R, int m) noexcept {
    const PartScope devices(parts(), Part::Devices);
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
    time.song = song_;  // the tempo map at the playhead (1.0.3)
    time.steps = timeConstant_ ? nullptr : chunkSteps_;  // the chunk's song steps (from g_)
    time.modulation = modulation_->forChain(s.index, ModChainKind::Inserts, inserts, 0);  // #161
    time.profile = chunkProfile_;  // the Benchmark (setProfile)
    const ChainTime* t = &time;
    if (fading) {
        std::copy_n(L, m, s.fadeL);
        std::copy_n(R, m, s.fadeR);
        ChainTime fadeTime = time;
        fadeTime.modulation = modulation_->forChain(s.index, ModChainKind::Inserts, s.insertsFading, 1);
        if (s.insertsFading) s.insertsFading->process(s.fadeL, s.fadeR, static_cast<uint32_t>(m), sr_, &fadeTime);
    }
    if (inserts) inserts->process(L, R, static_cast<uint32_t>(m), sr_, t);
    if (fading) {
        const int len = std::max(1, static_cast<int>(kSwapSeconds * sr_));
        for (int i = 0; i < m; ++i) {
            const float w = s.insertsFadeLeft > 0
                ? static_cast<float>(len - s.insertsFadeLeft + 1) / static_cast<float>(len + 1) : 1.0f;
            if (s.insertsFadeLeft > 0) --s.insertsFadeLeft;
            L[i] = s.fadeL[i] + (L[i] - s.fadeL[i]) * w;
            R[i] = s.fadeR[i] + (R[i] - s.fadeR[i]) * w;
        }
        if (s.insertsFadeLeft == 0 && s.insertsFading && canRetireNode(s.retires, 1) &&
            nodeRetireChain(s.retires, s.insertsFading)) {
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
    const PartScope sends(parts(), Part::Sends);
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
            const double step = songStep(g_ + i);
            double v = volumeLane ? automationValue(s.automation->volume, step, 1.0) : vol;
            if (s.vcaOn) v *= s.vca[i];  // its VCA groups scale its post keys as they scale its fader
            if (panLane) gains(automationValue(s.automation->pan, step, pan), pl, pr);
            faderL[i] = v * pl;
            faderR[i] = v * pr;
        }
    };
    // The notes the slot plays this chunk, for components keyed by it (the ducker's Notes mode): its key routes'
    // destinations take them from here (pullRoutes).
    t.keyEventCount = t.keys ? keyNotes(s, m, t.keyEvents, ComponentChain::kMaxKeyEvents) : 0;
    if (s.routesStale) {
        for (int k = 0; k < t.count; ++k)
            if (t.routes[k].delay) t.routes[k].delay->clear();
        s.routesStale = false;
    }
    // A feedback send's frames on the route clock in its ring: written every chunk the slot runs (zeros unless it
    // sounds), and read kBlock frames later by its destination, which never reads these frames this chunk.
    assert(m <= kBlock);  // a ring holds two chunks: the source's and the reader's frames never meet
    const int64_t ringAt = routeFrame_;
    auto ringWrite = [&](const SendTable::Route& r, bool sound) noexcept {
        FeedbackRing& f = *r.ring;
        for (int i = 0; i < m; ++i) {
            const int p = static_cast<int>((ringAt + i) & (FeedbackRing::kSize - 1));
            f.l[p] = sound ? r.outL[i] : 0.0f;
            f.r[p] = sound ? r.outR[i] : 0.0f;
        }
    };
    for (int k = 0; k < t.count; ++k) {
        SendTable::Route& r = t.routes[k];
        const bool key = r.key >= 0;
        if (r.ring) ringWrite(r, false);  // silence, unless it sounds below
        const float* levelMod = key ? nullptr : modulation_->send(s.index, k);  // project modulation (#161)
        const double level = levelMod ? faderGain(faderPosition(r.level) + levelMod[m - 1]) : r.level;
        const double want = r.mute || (!key && silenced) ? 0.0 : level;
        const double from = r.gain;
        if (!r.ok) {
            r.gain = 0.0;  // its destination doesn't run: it starts from silence when it does
            continue;
        }
        if (from == 0.0 && want == 0.0 && !r.delay) {
            r.tapPre = r.pre;  // silent: the tap can change at once
            continue;
        }
        if (key) {
            // Only read here: the destination runs after this slot (routeOk) and takes the key itself (pullRoutes).
            const Slot& d = slotAt(r.dest);
            if (!d.inserts || !d.inserts->keyInput(static_cast<size_t>(r.key))) {
                r.gain = want;
                continue;
            }
        }
        // It reaches its destination this chunk (a bus's input then counts as received, a key takes the notes),
        // with or without audio.
        r.chunk = chunkId_;
        r.audio = false;
        const bool postKey = key && (!r.pre || !r.tapPre);
        if (postKey) faderGains();
        const float* xl = r.tapPre || key ? preL : postL;
        const float* xr = r.tapPre || key ? preR : postR;
        // A level change glides at a fixed rate per sample (full scale in 5 ms), so it is the same at any block size.
        const double most = 1.0 / std::max(1.0, kGainSeconds * sr_);
        double g = from;
        if (g == want && r.tapPre == r.pre && !(key && !r.tapPre) && !r.delay && peakAbs(xl, m) == 0.0f &&
            peakAbs(xr, m) == 0.0f) {
            // Settled and silent: every routed sample is a zero, and adding a zero leaves the destination's sum as
            // it was (it starts at +0 and is never -0), so nothing is added.
            continue;
        }
        if (g == want && r.tapPre == r.pre && !(key && !r.tapPre)) {
            // Settled (the usual case): the loop below with nothing gliding, switching or faded, which vectorizes
            // (x g times 1.0 is x g: the same bits). The gain stays double: rounded to float it moves a crusher's
            // steps downstream (speed phase 4, as the track's gains).
            for (int i = 0; i < m; ++i) {
                r.outL[i] = routeSample(static_cast<double>(xl[i]) * g);
                r.outR[i] = routeSample(static_cast<double>(xr[i]) * g);
            }
        } else
        for (int i = 0; i < m; ++i) {
            const double aim = r.tapPre == r.pre ? want : 0.0;  // changing tap: through silence
            if (g != aim) g = aim > g ? std::min(aim, g + most) : std::max(aim, g - most);
            if (g == 0.0 && r.tapPre != r.pre) {
                r.tapPre = r.pre;
                xl = r.tapPre || key ? preL : postL;
                xr = r.tapPre || key ? preR : postR;
            }
            const bool faded = key && !r.tapPre;
            r.outL[i] = routeSample(static_cast<double>(xl[i]) * g * (faded ? faderL[i] : 1.0));
            r.outR[i] = routeSample(static_cast<double>(xr[i]) * g * (faded ? faderR[i] : 1.0));
        }
        r.gain = g;
        if (r.delay) r.delay->run(r.outL, r.outR, m);
        r.audio = true;
        if (r.ring) ringWrite(r, true);
    }
}

// A destination's sends and keys, when it runs (speed phase 5a: pulled, where the sources used to add into it): its
// routes in the fixed order updateRouting gave them (the order the sources ran, each one's routes by index, as the
// sources added before), so every sum keeps its bits. A send adds into the bus's input, zeroed by the first that
// arrives; a key into its component's key, with the source's notes merged by frame. Returns whether a send arrived.
bool Engine::pullRoutes(Slot& d, int m) noexcept {
    const MixGraph& g = *mixGraph_;
    if (g.inCount[d.index] == 0) return false;  // nothing routed in (the usual case)
    const PartScope sends(parts(), Part::Sends);
    bool received = false;
    for (int j = g.inFirst[d.index], end = j + g.inCount[d.index]; j < end; ++j) {
        const SendTable& t = *g.inRoutes[j].table;
        const SendTable::Route& r = t.routes[g.inRoutes[j].k];
        if (r.feedback) {
            // A feedback send (its source may run after this, or at once on the mix pool): only its ring's frames
            // from kBlock before on the route clock (-kBlock is +kBlock in a ring of 2 kBlock), zeroed once read,
            // then its DC block and soft clip.
            FeedbackRing& f = *r.ring;
            assert(m <= kBlock);
            if (!received) {
                std::fill_n(d.recvL, m, 0.0f);
                std::fill_n(d.recvR, m, 0.0f);
                received = true;
            }
            for (int i = 0; i < m; ++i) {
                const int p = static_cast<int>((routeFrame_ + kBlock + i) & (FeedbackRing::kSize - 1));
                double xl = f.l[p], xr = f.r[p];
                f.l[p] = f.r[p] = 0.0f;
                if (f.limiter) {
                    double yl = xl - f.xl + f.pole * f.yl, yr = xr - f.xr + f.pole * f.yr;
                    yl = yl == yl ? yl : 0.0;  // never: its input is finite (routeSample)
                    yr = yr == yr ? yr : 0.0;
                    if (std::fabs(yl) < 1e-20) yl = 0.0;  // its decay on silence never sits on subnormals
                    if (std::fabs(yr) < 1e-20) yr = 0.0;
                    f.xl = xl; f.yl = yl; f.xr = xr; f.yr = yr;
                    xl = feedbackClip(yl);
                    xr = feedbackClip(yr);
                } else {  // no limiter: a loop above unity still stops at +/-kUnlimited, never near FLT_MAX
                    xl = std::clamp(xl, -FeedbackRing::kUnlimited, FeedbackRing::kUnlimited);
                    xr = std::clamp(xr, -FeedbackRing::kUnlimited, FeedbackRing::kUnlimited);
                }
                d.recvL[i] = routeAdd(d.recvL[i], routeSample(xl));
                d.recvR[i] = routeAdd(d.recvR[i], routeSample(xr));
            }
            continue;
        }
        if (r.chunk != chunkId_) continue;  // it didn't reach here this chunk (its source was silent or didn't run)
        float* dl = nullptr;
        float* dr = nullptr;
        if (r.key >= 0) {
            ComponentChain::KeyInput* in = d.inserts ? d.inserts->keyInput(static_cast<size_t>(r.key)) : nullptr;
            if (!in) continue;  // never: the source checked it this chunk
            in->begin(chunkId_);
            dl = in->l;
            dr = in->r;
            // Merged by frame with what earlier sources gave (each list is in frame order).
            for (uint32_t k2 = 0; k2 < t.keyEventCount && in->count < ComponentChain::kMaxKeyEvents; ++k2) {
                uint32_t at = in->count++;
                while (at > 0 && in->events[at - 1].frame > t.keyEvents[k2].frame) {
                    in->events[at] = in->events[at - 1];
                    --at;
                }
                in->events[at] = t.keyEvents[k2];
            }
        } else {
            if (!received) {
                std::fill_n(d.recvL, m, 0.0f);
                std::fill_n(d.recvR, m, 0.0f);
                received = true;
            }
            dl = d.recvL;
            dr = d.recvR;
        }
        if (!r.audio) continue;  // settled and silent: adding its zeros would leave the sum as it is
        // A float sum (two floats' sum rounded once to float: the bits of the double sum's rounding), saturating.
        for (int i = 0; i < m; ++i) {
            dl[i] = routeAdd(dl[i], r.outL[i]);
            dr[i] = routeAdd(dr[i], r.outR[i]);
        }
    }
    return received;
}

// The notes a playing slot's pattern starts and ends in this chunk, as MIDI 2.0 note-ons and note-offs at their
// frames, at most `max`. Ons: those that play (chance, ratchets); a slide is legato and starts none. Offs: one for
// each on sent, with the on's id and key: a note that slides on sends none (the slide carries it), and a slide's end
// sends its first note's. At one frame an off comes before the ons, so a ratchet's next repeat is not let go.
uint32_t Engine::keyNotes(const Slot& s, int m, Event* out, uint32_t max) const noexcept {
    if (s.mode != Slot::Mode::Play || previewChunk_ || !s.pat) return 0;
    const Pattern& pat = *s.pat;
    auto sampleOf = [this, &s](double step) { return passFrame(s, step); };
    // The note whose on the key path sent for note k's sound (a slide's chain back to its first note), or -1 when
    // none was sent; bounded by the pattern's notes.
    auto voiceOf = [&](size_t k) noexcept -> int64_t {
        for (size_t guard = 0; guard <= pat.notes.size(); ++guard) {
            const PatternNote& n = pat.notes[k];
            if (!notePlays(n, static_cast<uint32_t>(k), s.repeat, seed_)) return -1;
            if (n.slideFrom < 0) return static_cast<int64_t>(k);
            k = static_cast<size_t>(n.slideFrom);
        }
        return -1;
    };
    auto midiKey = [](const PatternNote& n) {
        return static_cast<uint32_t>(std::clamp(std::lround(n.pitch), 0L, 127L));
    };
    const PatternEvent* ev = pat.events.data();
    const size_t ne = pat.events.size();
    const int64_t n0 = s.n0, end = n0 + m;
    size_t e = static_cast<size_t>(
        std::partition_point(ev, ev + ne, [&](const PatternEvent& x) { return sampleOf(x.step) < n0; }) - ev);
    uint32_t count = 0;
    for (; e < ne && count < max && sampleOf(ev[e].step) < end; ++e) {
        const PatternEvent& pe = ev[e];
        const PatternNote& n = pat.notes[pe.note];
        const uint32_t frame = static_cast<uint32_t>(std::max<int64_t>(0, sampleOf(pe.step) - n0));
        if (!pe.on) {
            const bool last = pe.sub + 1 >= n.ratchet;
            if (last && n.slideTo >= 0 && voiceOf(static_cast<size_t>(n.slideTo)) >= 0) continue;  // slides on
            const int64_t voice = pe.sub == 0 && n.slideFrom >= 0 ? voiceOf(pe.note)
                                  : notePlays(n, pe.note, s.repeat, seed_) ? static_cast<int64_t>(pe.note)
                                                                           : -1;
            if (voice < 0) continue;
            uint32_t at = count;  // before this frame's ons
            while (at > 0 && out[at - 1].frame == frame && ((out[at - 1].data[0] >> 20) & 0xFu) == 0x9u) --at;
            std::move_backward(out + at, out + count, out + count + 1);
            ++count;
            Event& x = out[at];
            x = Event{};
            x.frame = frame;
            x.kind = EventKind::Note;
            x.noteId = static_cast<uint32_t>(voice) + 1;
            x.data[0] = 0x40000000u | (0x8u << 20) | (midiKey(pat.notes[static_cast<size_t>(voice)]) << 8);  // off
            continue;
        }
        if (pe.sub == 0 && n.slideFrom >= 0) continue;
        if (!notePlays(n, pe.note, s.repeat, seed_)) continue;
        Event& x = out[count++];
        x = Event{};
        x.frame = frame;
        x.kind = EventKind::Note;
        x.noteId = pe.note + 1;
        const uint32_t vel = static_cast<uint32_t>(std::clamp(n.vel, 0.0, 1.0) * 65535.0 + 0.5);
        x.data[0] = 0x40000000u | (0x9u << 20) | (midiKey(n) << 8);  // MIDI 2.0 note on, group 0, channel 0
        x.data[1] = vel << 16;
    }
    return count;
}

// A playing track's output: the seam and swap crossfades of its lanes, then gain and pan.
void Engine::runTrackNode(int slot, float* outL, float* outR, int m) noexcept {
    const NodeMark node(parts());  // the Benchmark's parts: the graph's work after this node is the next node's
    Slot& s = slotAt(slot);
    if (s.mode != Slot::Mode::Play) {
        std::fill_n(outL, m, 0.0f);
        std::fill_n(outR, m, 0.0f);
        return;
    }
    const double target = s.target;
    const double gainCoef = trackGainCoef_;
    const bool received = pullRoutes(s, m);  // sends into its input (after its instrument), keys into its inserts
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
    if (samplePreview_->route() == slot) {  // the sample preview through this track's effects (API 33)
        samplePreview_->render(s.instL, s.instR, m);
        previewTaken_.store(true, std::memory_order_relaxed);
    }
    if (received) {  // sends into the track sum with its instrument, before its inserts
        for (int i = 0; i < m; ++i) {
            s.insL[i] = routeSample(static_cast<double>(s.instL[i]) + s.recvL[i]);
            s.insR[i] = routeSample(static_cast<double>(s.instR[i]) + s.recvR[i]);
        }
    } else {
        std::copy_n(s.instL, m, s.insL);
        std::copy_n(s.instR, m, s.insR);
    }
    runInserts(s, s.insL, s.insR, m);
    float peakL = 0, peakR = 0, sig = 0;
    int sp = s.scopePos.load(std::memory_order_relaxed);
    const bool volumeAutomated = s.automation && !s.automation->volume.empty();
    const bool panAutomated = s.automation && !s.automation->pan.empty();
    const double settled = target > 0.0 ? target : 0.0;
    // Project modulation of the fader (#161): offsets in its travel (the app's taper) and in pan's, per frame.
    const float* volumeMod = modulation_->volume(slot);
    const float* panMod = modulation_->pan(slot);
    const double* vca = s.vcaOn ? s.vca : nullptr;  // its VCA groups' gain per frame (null: in none)
    const bool steady = !volumeAutomated && !panAutomated && s.gain == settled && !volumeMod && !panMod && !vca;
    if (steady && allPositiveZero(s.insL, m) && allPositiveZero(s.insR, m) && !std::signbit(s.gain) &&
        !std::signbit(s.gl) && !std::signbit(s.gr)) {
        // Silence from the instrument and inserts (an asleep track): what the loop below gives, +0 everywhere
        // (+0 times gains that are not negative), without its sums.
        std::fill_n(outL, m, 0.0f);
        std::fill_n(outR, m, 0.0f);
        const PartScope metering(parts(), Part::Metering);  // the scope
        for (int i = 0; i < m;) {
            const int run = std::min(m - i, kScopeSize - sp);
            for (int k = 0; k < run; ++k) s.scope[sp + k].store(0.0f, std::memory_order_relaxed);
            i += run;
            sp = (sp + run) % kScopeSize;
        }
    } else if (steady) {
        // The usual case: volume settled, no lanes. The same sums as the loop below, without its per-sample
        // branches, and the scope written in at most two runs instead of a wrap test per sample. Double, not float
        // lanes: the gains rounded to float (6e-8) move a bit crusher's steps downstream (the mix reference's
        // master crusher, -77 dBFS; speed phase 4).
        const double gain = s.gain, gl = s.gl, gr = s.gr;
        float mid[kBlock], level[kBlock];
        for (int i = 0; i < m; ++i) {
            const double vl = static_cast<double>(s.insL[i]) * gain;
            const double vr = static_cast<double>(s.insR[i]) * gain;
            outL[i] = routeSample(vl * gl);
            outR[i] = routeSample(vr * gr);
            const double al = std::fabs(vl), ar = std::fabs(vr);
            level[i] = static_cast<float>(al < ar ? ar : al);
            mid[i] = static_cast<float>(0.5 * (vl + vr));
        }
        const PartScope metering(parts(), Part::Metering);  // the meter's peaks and the scope
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
        const double step = volumeAutomated || panAutomated ? songStep(g_ + i) : 0.0;
        const double desired = target > 0.0
            ? (volumeAutomated ? automationValue(s.automation->volume, step, target) : target) : 0.0;
        if (volumeAutomated) {
            // The interpolated automation curve is already continuous; don't add lag on top.
            s.gain = desired;
        } else if (s.gain != desired) {
            s.gain += (desired - s.gain) * gainCoef;
            if (std::fabs(desired - s.gain) < 1e-6) s.gain = desired;
        }
        double gain = volumeMod && s.gain > 0.0 ? faderGain(faderPosition(s.gain) + volumeMod[i]) : s.gain;  // muted stays silent
        if (vca) gain *= vca[i];  // after the fader, its lane and modulation: an automated track follows its VCA
        const double vl = static_cast<double>(s.insL[i]) * gain;
        const double vr = static_cast<double>(s.insR[i]) * gain;
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
    {
        const PartScope metering(parts(), Part::Metering);
        storeMax(s.peakL, peakL);
        storeMax(s.peakR, peakR);
        s.correlation.process(outL, outR, m);
    }
    // A modulator hears this track (#161): after its effects, and after the fader.
    if (modulation_->listens(slot)) {
        const PartScope automation(parts(), Part::Automation);
        modulation_->tapAudio(slot, s.insL, s.insR, outL, outR, static_cast<uint32_t>(m));
    }
    if (s.sends && s.sends->count > 0) runRoutes(s, s.insL, s.insR, outL, outR, m, !(target > 0.0), false);
    if (s.delay || s.delayFadeLeft > 0) runDelay(s, outL, outR, m);  // in time where it meets the others
    if (s.tapL) {  // an offline stem: what the track sends on, as it meets the others (or before its fader)
        std::copy_n(s.tapPre ? s.insL : outL, m, s.tapL + tapAt_);
        std::copy_n(s.tapPre ? s.insR : outR, m, s.tapR + tapAt_);
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
// input (pullRoutes). Then its inserts, volume and pan, its sends, and its latency compensation.
void Engine::runBusNode(int slot, const float* inL, const float* inR, float* outL, float* outR, int m) noexcept {
    const NodeMark node(parts());  // the Benchmark's parts: the graph's work after this node is the next node's
    Slot& s = slotAt(slot);
    if (s.mode != Slot::Mode::Bus) {
        std::fill_n(outL, m, 0.0f);
        std::fill_n(outR, m, 0.0f);
        return;
    }
    // A folder bus (engine_parts.h), with its children's sum into its input; its effects, sends and meters apart.
    const PartScope routing(parts(), Part::Routing, true);
    const double target = slotTarget(s);
    const bool received = pullRoutes(s, m);  // sends into its input, keys into its inserts
    const bool inserts = s.inserts || s.insertsFadeLeft > 0;
    if (received || inserts) {
        for (int j = 0; j < m; ++j) {
            s.insL[j] = received ? routeSample(static_cast<double>(inL[j]) + s.recvL[j]) : inL[j];
            s.insR[j] = received ? routeSample(static_cast<double>(inR[j]) + s.recvR[j]) : inR[j];
        }
        if (inserts) runInserts(s, s.insL, s.insR, m);
        for (int j = 0; j < m; ++j) {
            s.outL[j] = s.insL[j];
            s.outR[j] = s.insR[j];
        }
    } else {
        for (int j = 0; j < m; ++j) {
            s.outL[j] = inL[j];
            s.outR[j] = inR[j];
        }
    }
    const bool routes = s.sends && s.sends->count > 0;
    if (routes && !received && !inserts) {  // the pre tap, when it isn't in insL already
        std::copy_n(inL, m, s.insL);
        std::copy_n(inR, m, s.insR);
    }
    const double pan = bitsToDouble(s.pan.load(std::memory_order_relaxed));
    const double gainCoef = trackGainCoef_;
    const float* volumeMod = modulation_->volume(slot);  // project modulation (#161)
    const float* panMod = modulation_->pan(slot);
    const bool laneFree = !s.automation || (s.automation->volume.empty() && s.automation->pan.empty());
    const double* vca = s.vcaOn ? s.vca : nullptr;  // its VCA groups' gain per frame (null: in none)
    if (laneFree && !volumeMod && !panMod && !vca && s.gain == (target > 0.0 ? target : 0.0)) {
        // Settled, no lanes, no modulation (the usual case): the loop below with every frame's gains the same.
        const double leftPan = pan > 0.0 ? 1.0 - pan : 1.0;
        const double rightPan = pan < 0.0 ? 1.0 + pan : 1.0;
        const double gain = s.gain;
        for (int j = 0; j < m; ++j) {
            s.outL[j] *= gain * leftPan;
            s.outR[j] *= gain * rightPan;
        }
    } else
    for (int j = 0; j < m; ++j) {
        const double step = songStep(g_ + j);
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
        double gain = volumeMod && s.gain > 0.0 ? faderGain(faderPosition(s.gain) + volumeMod[j]) : s.gain;  // muted stays silent
        if (vca) gain *= vca[j];  // a folder bus in a VCA group: its fader scaled (its children too, if also members)
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
    if (modulation_->listens(slot)) {  // a modulator hears this bus (#161)
        const PartScope automation(parts(), Part::Automation);
        modulation_->tapAudio(slot, received || inserts || routes ? s.insL : inL, received || inserts || routes ? s.insR : inR,
                              outL, outR, static_cast<uint32_t>(m));
    }
    {
        const PartScope metering(parts(), Part::Metering);
        storeMax(s.peakL, peakL);  // a folder's meter: its mix after volume and pan
        storeMax(s.peakR, peakR);
        s.correlation.process(outL, outR, m);
    }
    s.previewQuiet = std::max(peakL, peakR) > kPreviewQuiet ? 0 : s.previewQuiet + m;
    if (routes) runRoutes(s, s.insL, s.insR, outL, outR, m, !(target > 0.0), true);
    if (s.delay || s.delayFadeLeft > 0) runDelay(s, outL, outR, m);  // in time where it meets the others
    if (s.tapL) {  // an offline stem: the bus's output, as it meets the others (or after its effects, pre-fader)
        const bool inIns = received || inserts || routes;
        std::copy_n(!s.tapPre ? outL : inIns ? s.insL : inL, m, s.tapL + tapAt_);
        std::copy_n(!s.tapPre ? outR : inIns ? s.insR : inR, m, s.tapR + tapAt_);
    }
    if (s.removing && s.gain == 0.0 && canRetireNode(s.retires, 3)) {
        // Faded out: the slot is free again, with its inserts, delay and routes.
        // Held until the graph has run (flushRetires): a destination of its routes still reads their outputs.
        // canRetireNode(3) leaves room for all three, so none is refused (nodeRetire asserts it).
        Retired r{&s, nullptr, nullptr, nullptr, nullptr, s.inserts};
        r.delay = s.delay;
        r.sends = s.sends;
        nodeRetire(s.retires, r);
        nodeRetireChain(s.retires, s.insertsFading);
        if (s.delayFading) {
            Retired d;
            d.delay = s.delayFading;
            nodeRetire(s.retires, d);
        }
        s.inserts = s.insertsFading = nullptr;
        s.insertsFadeLeft = 0;
        s.delay = s.delayFading = nullptr;
        s.delayFadeLeft = 0;
        s.sends = nullptr;
        s.active = false;
        s.bus = false;
        s.removing = false;
        setShed(s, false);  // a removed bus is no longer one the device shed (as planChunk does for a track)
        s.previewing = false;
        s.insertTail = false;
        s.routingChanged = true;  // the callback thread re-derives the routing after the graph (flushRetires)
    }
}

// The master DC blocker's state after a sample: with silence coming in, its decay settles at 0 once below -240 dB
// instead of running on for seconds through ever smaller values; its output is then exactly 0, so the master
// chain's effects fall asleep about 2.5 s sooner after a song's tail (speed phase 1). Per sample, so it settles on
// the same frame at any block size.
static inline double settleDc(double x, double y) noexcept { return x == 0.0 && std::fabs(y) < 1e-12 ? 0.0 : y; }

void Engine::runMasterNode(const float* inL, const float* inR, float* outL, float* outR, int m) noexcept {
    const PartScope master(parts(), Part::Master);  // the master stage (engine_parts.h); its meters apart
    // Master order: gain/DC block, trusted native stereo effects, safety limiter last.
    const double R = 1.0 - kTwoPi * 5.0 / sr_;
    const double rel = detExp(-1.0 / (0.1 * sr_));
    double fade = 1.0;
    float pl = 0, pr = 0;
    const bool bypass = bypass_.load(std::memory_order_relaxed);
    int sp = masterScopePos_.load(std::memory_order_relaxed);
    // The sample preview joins here unless a track's node played it through its effects this chunk.
    const bool previewHere = !previewTaken_.load(std::memory_order_relaxed);

    // The metronome, while the song plays: a click as the playhead crosses each beat.
    const bool clicks = metronome_ && playing_ && !previewChunk_ && stepLen_ > 0;
    const double beatLen = 4.0 * stepLen_;
    // With one tempo and one signature of the project's beats per bar, a click as the playhead crosses each beat
    // (as before the map). Otherwise the ticks of the signatures (1/den notes, the accent on each bar), each on the
    // first sample at or after its exact time on the tempo map, worked out for this chunk first.
    int tickFrame[kBlock];
    bool tickAccent[kBlock];
    int ticks = 0, tickNext = 0;
    if (clicks && !simpleClicks_) {
        const TempoMap& tm = song_->tempo;
        const TimeSigMap& sigs = song_->sigs;
        const double end = static_cast<double>(g_ + m);
        bool accent = false;
        double tick = sigs.nextTick(tm.stepAt(static_cast<double>(g_) - 2.0) / 4.0, accent);
        for (int guard = 0; guard < kBlock + 4 && ticks < kBlock; ++guard) {
            const double at = std::ceil(tm.frameAt(tick * 4.0));
            if (at >= end) break;
            if (at >= static_cast<double>(g_)) {
                tickFrame[ticks] = static_cast<int>(at - static_cast<double>(g_));
                tickAccent[ticks++] = accent;
            }
            tick = sigs.tickAfter(tick, accent);
        }
    }
    auto finishSample = [&](int frame, double yl, double yr) noexcept {
        if (clicks && simpleClicks_) {
            const double pos = static_cast<double>(g_ + frame);
            const double beat = std::floor(pos / beatLen);
            if (sampletime::beatOffset(pos, beat, beatLen) < 1.0) startClick(static_cast<int64_t>(beat) % std::max(1, beatsPerBar_) == 0);
        } else if (tickNext < ticks && tickFrame[tickNext] == frame) {
            startClick(tickAccent[tickNext++]);
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
        if (toneLeft_ > 0 || (previewHere && samplePreview_->active())) {
            // The test tone and the sample preview join after the transport's fades (they sound stopped too) and
            // before the limiter, which follows the louder of the song's own level and the sum, so the sum stays
            // under the ceiling.
            const double t = toneLeft_ > 0 ? nextTone() : 0.0;
            double sl = yl * fade + t, sr = yr * fade + t;
            if (previewHere && samplePreview_->active()) samplePreview_->next(sl, sr);
            const double env = std::max({std::fabs(yl), std::fabs(yr), std::fabs(sl), std::fabs(sr)});
            limEnv_ = env > limEnv_ ? env : env + (limEnv_ - env) * rel;
            limEnv_ = limEnv_ < 1e-30 ? 0.0 : limEnv_;  // far below the ceiling (gain 1 either way): no subnormals
            const double gain = bypass ? 1.0 : (limEnv_ > kLimitCeiling ? kLimitCeiling / limEnv_ : 1.0);
            ol = static_cast<float>(sl * gain);
            orr = static_cast<float>(sr * gain);
        } else {
            const double env = std::max(std::fabs(yl), std::fabs(yr));
            limEnv_ = env > limEnv_ ? env : env + (limEnv_ - env) * rel;
            limEnv_ = limEnv_ < 1e-30 ? 0.0 : limEnv_;  // far below the ceiling (gain 1 either way): no subnormals
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
            dcL_[1] = settleDc(xl, yl);
            const double yr = xr - dcR_[0] + R * dcR_[1];
            dcR_[0] = xr;
            dcR_[1] = settleDc(xr, yr);
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
            dcL_[1] = settleDc(xl, yl);
            const double yr = xr - dcR_[0] + R * dcR_[1];
            dcR_[0] = xr;
            dcR_[1] = settleDc(xr, yr);
            stageL[i] = static_cast<float>(bypass ? xl : yl);
            stageR[i] = static_cast<float>(bypass ? xr : yr);
        }
        ChainTime time{g_, stepLen_, touchEpoch_, bpm_, static_cast<uint32_t>(beatsPerBar_), playing_ && !previewChunk_};
        time.song = song_;  // the tempo map at the playhead (1.0.3)
        time.steps = timeConstant_ ? nullptr : chunkSteps_;  // the chunk's song steps (from g_)
        time.modulation = modulation_->forChain(-1, ModChainKind::Master, masterChain_, 0);  // #161
        time.profile = chunkProfile_;  // the Benchmark (setProfile)
        const ChainTime* t = &time;
        const bool fading = masterFadeLeft_ > 0;
        if (fading) {
            std::copy_n(stageL, m, masterFadeL_);
            std::copy_n(stageR, m, masterFadeR_);
            ChainTime fadeTime = time;
            fadeTime.modulation = modulation_->forChain(-1, ModChainKind::Master, masterFading_, 1);
            if (masterFading_) masterFading_->process(masterFadeL_, masterFadeR_, static_cast<uint32_t>(m), sr_, &fadeTime);
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
                stageL[i] = masterFadeL_[i] + (stageL[i] - masterFadeL_[i]) * w;
                stageR[i] = masterFadeR_[i] + (stageR[i] - masterFadeR_[i]) * w;
            }
            if (masterFadeLeft_ == 0 && masterFading_) {
                if (canRetireNode(*masterRetires_, 1) && nodeRetireChain(*masterRetires_, masterFading_)) {
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
    const PartScope metering(parts(), Part::Metering);
    storeMax(peakL_, pl);
    storeMax(peakR_, pr);
    masterCorrelation_.process(outL, outR, m);
    loudness_->process(outL, outR, m);  // K-weighting and true peak per sample; the rest each 100 ms
}

void Engine::setShed(Slot& s, bool shed) noexcept {
    if (s.overloaded == shed) return;
    s.overloaded = shed;
    s.overloadFlag.store(shed, std::memory_order_relaxed);
    overloadedFlag_.fetch_add(shed ? 1 : -1, std::memory_order_relaxed);
}

void Engine::pickOverloadVictim() noexcept {
    int best = -1, audible = 0;
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
        const Slot& s = slotAt(i);
        if (!s.active || s.overloaded || slotTarget(s) == 0.0) continue;
        ++audible;
        if (best < 0 || s.order > slotAt(best).order) best = i;
    }
    // Load never silences the song (owner, 1.1.2: "playback must never stop because of load or heat"): the last
    // layer still sounding is never shed; a device that cannot carry even that one drops out, and says so.
    if (best < 0 || audible <= 1) return;
    Slot& s = slotAt(best);
    setShed(s, true);
    s.shedSeq = ++shedSeq_;
    s.shedCost = shedLoad_ / audible;  // until measured: an equal share
    // Shed again soon after it came back: it waits twice as long next time (2 s, 4 s ... 32 s), so a layer the
    // device can only just not carry settles out instead of coming and going.
    s.restoreDelay = loadClock_ - s.restoredAt < kReshedSeconds ? std::min(kRestoreMaxSeconds, 2.0 * std::max(s.restoreDelay, kRestoreSeconds))
                                                                 : kRestoreSeconds;
    measureSlot_ = best;
    measureFrom_ = shedLoad_;
    shedTotal_.fetch_add(1, std::memory_order_relaxed);
}

void Engine::restoreOne() noexcept {
    // The newest shed first (shedding takes the newest layer, so this brings back the oldest layer first in time).
    int best = -1;
    for (int k = 0; k < liveCount_; ++k) {
        const int i = live_[k];
        const Slot& s = slotAt(i);
        if (!s.active || !s.overloaded) continue;
        if (best < 0 || s.shedSeq > slotAt(best).shedSeq) best = i;
    }
    if (best < 0) return;
    Slot& s = slotAt(best);
    // Back once it has waited its delay, if the load now plus what it was seen to cost stays under kRestoreCeiling;
    // else, after kTrialSeconds more of quiet, back on trial all the same: a cost seen while the device was
    // throttled reads high, and a song shed to silence must not stay silent. A trial that overloads again is shed
    // within 10 s of coming back, which doubles its delay, so trials grow rarer (at most one every 40 s).
    if (underSeconds_ < s.restoreDelay) return;
    if (loadAvg_ + s.shedCost > kRestoreCeiling && underSeconds_ < s.restoreDelay + kTrialSeconds) return;
    setShed(s, false);  // its gain fades back in as a mute's does (slotTarget)
    s.restoredAt = loadClock_;
    if (measureSlot_ == best) measureSlot_ = -1;
    restoredTotal_.fetch_add(1, std::memory_order_relaxed);
    underSeconds_ = 0;  // the next one waits for another quiet stretch with this one playing
}

void Engine::resetShedding() noexcept {
    for (int i = 0; i < slotCount_; ++i) {
        setShed(slotAt(i), false);
        slotAt(i).restoreDelay = 0;
        slotAt(i).shedCost = 0;
    }
    overloadedFlag_.store(0, std::memory_order_relaxed);
    overShare_ = 0;
    coolSeconds_ = underSeconds_ = 0;
    // Every per-callback average and the time since a shed or restore, the mix pool's Auto included (its wait and
    // work averages and the times it has spent over or under its loads; whether it is on, its workers and its
    // retry wait stay).
    loadAvg_ = 0;
    waitAvg_ = workAvg_ = 0;
    waitShare_.store(0.0f, std::memory_order_relaxed);
    mixOverSeconds_ = mixUnderSeconds_ = mixLosingSeconds_ = mixGrowSeconds_ = 0;
    // A pool left on runs a settle again: its wait average starts from zero, so without one it would add workers
    // (and count the pool's restart toward shedding) before the average shows what they cost.
    if (mixAuto_) mixSettleSeconds_ = kMixSettleSeconds;
    tailPool_ = tailPoolWeight_ = tailPoolSeconds_ = tailOverSeconds_ = 0;  // the serial tail is kept: it is not the pool's
    shedLoad_ = measureFrom_ = 0;
    cpu_.store(0.0f, std::memory_order_relaxed);
    measureSlot_ = -1;
    overloadPending_ = restorePending_ = false;
}

void Engine::process(float* left, float* right, int frames) noexcept {
    const ScopedFlushDenormals flushDenormals;  // live callbacks, exports and renders alike (fp_mode.h)
    // This engine's profile (null: none) for this call; every chain gets it in its ChainTime (setProfile).
    chunkProfile_ = profile_.load(std::memory_order_acquire);
    if (PartProfile* p = parts()) p->begin();  // the Benchmark's parts: from here to the end of this call
    // Speed phase 5d: this call's own time, which Auto splits into the wait for workers and the rest (reportLoad).
    const auto processStart = pool_ ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    // Whether any layer is soloed, worked out once per callback rather than once per layer and block.
    updateSolo();
    // MIDI out (API 47): frame 0 of this callback as it will be heard, on the MIDI clock, before any command can
    // send a message (a Stop's note-offs, a Play's Start).
    {
        const int64_t test = midiClockTest_.load(std::memory_order_relaxed);
        const int64_t now = test >= 0 ? test : midiClockNs();
        // Smoothed over the callbacks (CallbackClock), so the wake-up's own jitter isn't in the messages' times.
        midiOutAnchorNs_ = midiOutClock_.anchor(now, frames, sr_) + midiOutLatencyNs_.load(std::memory_order_relaxed) +
            static_cast<int64_t>(std::llround(static_cast<double>(midiOutDelayFrames_.load(std::memory_order_relaxed)) * 1e9 / sr_));
        midiOutQ_->beginCallback();
        midiFrame_ = 0;
    }
    applyCommands();
    updateSolo();
    // The pool for this callback (speed phase 5c); idle workers sleep at once while nothing plays. Speed phase 5d:
    // a wake goes out now, so sleeping workers are up by the first level (the chunk's planning runs meanwhile).
    if (mixRestart_.exchange(false, std::memory_order_acq_rel)) {  // a new device (startLiveMixPool)
        mixAuto_ = false;
        mixActive_ = pool_ ? pool_->workers() : 0;
        mixOverSeconds_ = mixUnderSeconds_ = mixLosingSeconds_ = mixGrowSeconds_ = mixSettleSeconds_ = 0;
        waitAvg_ = workAvg_ = 0;
        peakCount_ = peakOffCount_ = 0;
        tailPool_ = tailPoolWeight_ = tailSerial_ = tailSerialWeight_ = tailPoolSeconds_ = tailOverSeconds_ = 0;
    }
    // The Benchmark's profile: serial (setProfile), by the profile this call read, so a profile set or cleared
    // meanwhile never has workers filling it.
    mixParallel_ = wantsMixPool() && !chunkProfile_;
    mixOn_.store(mixParallel_, std::memory_order_relaxed);
    if (pool_) {
        const PartScope pool(parts(), Part::MixPool);
        const bool idle = !mixParallel_ || (!playing_ && !previewing_ && countInLeft_ == 0);
        pool_->park(idle);
        // Only when the last callback handed the pool a level: a project whose levels have one busy node each
        // (one heavy instrument) never has idle workers spinning beside the callback (on a hyperthreaded core they
        // slow it). Otherwise the first level published wakes them.
        pool_->beginCallback(!idle && poolUsedLast_);
    }
    takeDeviceMidi(frames);
    takeToneRequest();
    takePreview();
    if (!playing_ && monitorWanted_.load(std::memory_order_relaxed)) wakeMonitors();
    // A device (re)start or the app going to the background: a throttled stretch must not thin the song for good.
    if (sheddingReset_.exchange(false, std::memory_order_acq_rel)) resetShedding();
    if (overloadPending_) {
        overloadPending_ = false;
        if (shedding_.load(std::memory_order_relaxed)) pickOverloadVictim();  // off: the Benchmark's engine (setShedding)
    }
    if (restorePending_) {
        restorePending_ = false;
        restoreOne();
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
                if (countInAt_ % countInBeat_ == 0) startClick((countInAt_ / countInBeat_) % std::max(1, countInBar_) == 0);
                ++countInAt_;
                const float v = static_cast<float>(nextClick());
                left[i + j] = std::clamp(left[i + j] + v, -1.0f, 1.0f);
                right[i + j] = std::clamp(right[i + j] + v, -1.0f, 1.0f);
            }
            countInLeft_ -= done;
            i += done;
            midiFrame_ = i;  // a Play here sends its clock and programs from this frame
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
        if (clockPorts_) clockChunk(i, m);  // MIDI clock out (API 47): this chunk's ticks
        if (stopEnded_) {
            stopEnded_ = false;
            endPlayback();
        }
        g_ += m;
        if (g_ >= wrap) {
            g_ = loopRange_ ? loopFrom_ : 0;
            ++epoch_;
            if (clockPorts_) clockLoop(i + m);
        }
        i += m;
    }
    if (midiPendingCount_ > 0) endDeviceMidi(frames);
    if (previewing_) updatePreviewing(frames);
    toneActive_.store(toneLeft_ > 0, std::memory_order_release);
    samplePreview_->publish();
    playingFlag_.store(playing_, std::memory_order_relaxed);
    posFlag_.store(g_, std::memory_order_relaxed);
    publishSongPos();
    if (pool_) {
        {
            const PartScope pool(parts(), Part::MixPool);
            pool_->endCallback();  // the workers spin a little longer, then sleep until the next callback
        }
        processNs_ += std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - processStart).count();
    }
    if (poolUsed_) pooledCallbacks_.fetch_add(1, std::memory_order_relaxed);  // one writer: the audio thread
    poolUsedLast_ = poolUsed_;
    poolUsed_ = false;
    if (PartProfile* p = parts()) p->end();
    chunkProfile_ = nullptr;  // only this call fills it: nothing after (a stray scope) can reach a profile now unset
}

// Shedding (the device ran out of time) and its recovery, by time rather than callbacks, so any callback size
// behaves the same. The meter: an average of each callback's load that keeps 0.9 of itself per 10.7 ms (512
// frames at 48 kHz). Shedding: the share of the last ~0.25 s spent in callbacks over 0.85 of their budget (an
// average with a 0.25 s time constant, weighted by each callback's length) passing 0.7, which takes about 0.3 s
// of nearly all-over callbacks, with the meter itself over 0.75 then: one stalled callback, however late (the
// first after Play, a device restart or reroute, a background burst), is its own length's share and sheds nothing;
// and the last layer still sounding is never shed (1.1.2, pickOverloadVictim). After a shed, 1.07 s before the
// next. Recovery: the meter under 0.6 for 2 s brings back one layer (the newest shed), only if the load now plus
// what that layer was seen to cost when shed (the meter's drop in the second after, at most an equal share of
// the load then) stays under 0.75, or on trial after 8 s more of quiet; then another 2 s for the next. Hysteresis: shed
// over 0.85, back under 0.6 and only to under 0.75, so a returning layer does not cross 0.85 again; and one shed
// again within 10 s of coming back waits twice as long each time (up to 32 s). Never in an offline engine.
void Engine::reportLoad(double load, int frames, int rendered) noexcept {
    constexpr double kTick = 512.0 / 48000.0;
    constexpr double kCoolSeconds = 100 * kTick;
    constexpr double kOverLoad = 0.85, kOverShare = 0.7, kShareSeconds = 0.25;
    // The mix pool's timing first, before every early return below (no frames, an offline engine, a shed), so it
    // sees every callback: what the callback spent waiting for workers and what the workers ran (speed phase 5d),
    // and the callback's time to the performance hint (atomics; the hint's own thread reports it), against the
    // frames played, the deadline the device sets.
    int64_t waitNs = 0, workerNs = 0;
    const double proc = static_cast<double>(processNs_);
    processNs_ = 0;
    if (pool_) {
        pool_->takeTimes(waitNs, workerNs);
        const double played = frames > 0 ? static_cast<double>(frames) / sr_ : 0.0;
        const double used = std::isfinite(load) ? std::max(0.0, load) * played : 0.0;
        pool_->reportWork(static_cast<int64_t>(used * 1e9), static_cast<int64_t>(played * 1e9));
    }
    if (frames <= 0) return;
    // A new device's first callbacks (requestDeviceWarmUp): the stream starting, left out of every average here.
    if (deviceWarmUp_.load(std::memory_order_relaxed) && deviceWarmUp_.exchange(false, std::memory_order_acq_rel))
        warmSeconds_ = kDeviceWarmSeconds;
    if (warmSeconds_ > kSlackSeconds) {
        warmSeconds_ -= static_cast<double>(frames) / sr_;
        return;
    }
    if (!std::isfinite(load)) load = 0.0;
    // The callback's time against the frames it played: their deadline, which a callback over 1 missed.
    const double raw = std::max(0.0, load);
    // Through the device's FIFO a callback renders more or fewer frames than it plays (128 and 64 by turns at 96
    // frames): the load per frame rendered is the engine's real load, without those alternating peaks.
    if (rendered > 0 && rendered != frames) load *= static_cast<double>(frames) / static_cast<double>(rendered);
    const double dt = static_cast<double>(frames) / sr_;
    if (dt != loadDt_) {  // pow and exp only for a length not among the last few (loadWeights_)
        loadDt_ = dt;
        const LoadWeights* w = nullptr;
        for (const LoadWeights& c : loadWeights_)
            if (c.dt == dt) w = &c;
        if (!w) {
            LoadWeights& n = loadWeights_[loadWeightsNext_];
            loadWeightsNext_ = (loadWeightsNext_ + 1) % kLoadWeights;
            n.dt = dt;
            n.load = std::pow(0.9, dt / kTick);
            n.share = std::exp(-dt / kShareSeconds);
            n.tail = std::exp(-dt / kMixTailSeconds);
            n.peak = std::exp(-dt / kMixPeakSeconds);
            w = &n;
        }
        loadKeep_ = w->load;
        shareKeep_ = w->share;
        tailKeep_ = w->tail;
        peakKeep_ = w->peak;
    }
    loadClock_ += dt;
    loadAvg_ = loadKeep_ * loadAvg_ + (1.0 - loadKeep_) * load;
    cpu_.store(static_cast<float>(loadAvg_), std::memory_order_relaxed);
    // While Auto's pool settles (kMixSettleSeconds): no worker added, and shedding (below) holds off.
    const bool settling = mixSettleSeconds_ > kSlackSeconds;
    mixSettleSeconds_ = std::max(0.0, mixSettleSeconds_ - dt);
    // The pool's Auto works per frame rendered, as the meter does (load above), so the FIFO's alternating render
    // sizes don't swing it. The wait's and the workers' shares of the load: their time against the process() time
    // they were part of, times that load (the callback's whole time over its frames' budget).
    const double measured = std::max(0.0, load);
    const double waitShare = proc > 0 ? measured * std::min(1.0, static_cast<double>(waitNs) / proc) : 0.0;
    const double workShare = proc > 0 ? measured * (static_cast<double>(workerNs) / proc) : 0.0;
    waitAvg_ = loadKeep_ * waitAvg_ + (1.0 - loadKeep_) * waitShare;
    workAvg_ = loadKeep_ * workAvg_ + (1.0 - loadKeep_) * workShare;
    waitShare_.store(static_cast<float>(waitAvg_), std::memory_order_relaxed);
    // The pool's Auto mode (speed phase 5c), with hysteresis: on after a while above kMixParallelLoad, off only
    // after longer below kMixSerialLoad (the load measured while parallel is lower: it must not flip straight back).
    // The off test leaves out the wait (time the callback spun for workers, not work of its own).
    mixRetrySeconds_ = std::max(0.0, mixRetrySeconds_ - dt);
    const double work = loadAvg_ - waitAvg_;
    // The peaks (2026-11-27): a count of callbacks over kMixPeakLoad (and over kMixPeakOffLoad), each decaying
    // with kMixPeakSeconds. Per frame rendered, as the mean.
    peakCount_ = peakKeep_ * peakCount_ + (measured > kMixPeakLoad ? 1.0 : 0.0);
    peakOffCount_ = peakKeep_ * peakOffCount_ + (measured > kMixPeakOffLoad ? 1.0 : 0.0);
    // The count needs three peaks already (one or two stalled callbacks are not enough), so it turns the pool on at once: a
    // song's bursts (a bar's first callbacks, a kick waking a drum chain) are too short and far apart to hold it
    // over kMixPeakCount for kMixParallelSeconds.
    const bool peaky = peakCount_ > kMixPeakCount;
    if (loadAvg_ > kMixParallelLoad || peaky) {
        mixUnderSeconds_ = 0;
        mixOverSeconds_ += dt;
        if ((mixOverSeconds_ >= kMixParallelSeconds - kSlackSeconds || peaky) && !mixAuto_ && mixRetrySeconds_ <= kSlackSeconds) {
            mixAuto_ = true;
            // A pool starting on Auto: shedding holds off while it settles (below).
            if (pool_ && static_cast<MixParallel>(mixMode_.load(std::memory_order_relaxed)) == MixParallel::Auto)
                mixSettleSeconds_ = kMixSettleSeconds;
            mixActive_ = pool_ ? pool_->workers() : 0;
            mixLosingSeconds_ = mixGrowSeconds_ = 0;
            tailPool_ = tailPoolWeight_ = tailPoolSeconds_ = tailOverSeconds_ = 0;  // the pool's tail from now
        }
    } else if (work < kMixSerialLoad && peakOffCount_ < kMixPeakOffCount) {
        mixOverSeconds_ = 0;
        mixUnderSeconds_ += dt;
        if (mixUnderSeconds_ >= kMixSerialSeconds - kSlackSeconds) mixAuto_ = false;
    } else {
        mixOverSeconds_ = mixUnderSeconds_ = 0;
    }
    // The tail guard's samples: this callback used the pool (it handed a level to the workers) or ran serial.
    const double late = raw >= kMixTailLoad ? 1.0 : 0.0;
    if (poolUsedLast_ && mixParallel_) {
        if (!settling) {
            tailPool_ = tailKeep_ * tailPool_ + (1.0 - tailKeep_) * late;
            tailPoolWeight_ = tailKeep_ * tailPoolWeight_ + (1.0 - tailKeep_);
            tailPoolSeconds_ += dt;
        }
    } else {
        tailSerial_ = tailKeep_ * tailSerial_ + (1.0 - tailKeep_) * late;
        tailSerialWeight_ = tailKeep_ * tailSerialWeight_ + (1.0 - tailKeep_);
    }
    // Auto's workers: one fewer while the pool costs the callback more than it gives, one more while it waits little.
    const bool autoOn = static_cast<MixParallel>(mixMode_.load(std::memory_order_relaxed)) == MixParallel::Auto;
    if (pool_ && autoOn && mixAuto_ && mixParallel_) {
        const uint32_t all = pool_->workers();
        // The tail guard: late callbacks more often on the pool than serial, for a while: one thread again.
        const bool tailWorse = tailPoolSeconds_ >= kMixTailSeconds - kSlackSeconds && tailSerialWeight_ > 0 &&
                               tailPoolWeight_ > 0 &&
                               tailPool_ / tailPoolWeight_ > tailSerial_ / tailSerialWeight_ + kMixTailMargin;
        tailOverSeconds_ = tailWorse ? tailOverSeconds_ + dt : 0.0;
        if (tailOverSeconds_ >= kMixTailHoldSeconds - kSlackSeconds) {
            mixAuto_ = false;
            mixActive_ = all;
            mixRetrySeconds_ = kMixRetrySeconds;
            mixLosingSeconds_ = mixGrowSeconds_ = 0;
            waitAvg_ = workAvg_ = 0;
            tailPool_ = tailPoolWeight_ = tailPoolSeconds_ = tailOverSeconds_ = 0;
            tailFallbacks_.fetch_add(1, std::memory_order_relaxed);
        }
        if (waitAvg_ > kMixWaitShare && waitAvg_ > workAvg_) {
            mixGrowSeconds_ = 0;
            mixLosingSeconds_ += dt;
            if (mixLosingSeconds_ >= kMixWaitSeconds - kSlackSeconds) {
                mixLosingSeconds_ = 0;
                if (mixActive_ > 0) --mixActive_;
                if (mixActive_ == 0) {  // one thread does better: stay there a while
                    mixAuto_ = false;
                    mixActive_ = all;
                    mixRetrySeconds_ = kMixRetrySeconds;
                    waitAvg_ = workAvg_ = 0;
                }
            }
        } else if (!settling && waitAvg_ < kMixWaitShare / 4 && mixActive_ < all) {
            mixLosingSeconds_ = 0;
            mixGrowSeconds_ += dt;
            if (mixGrowSeconds_ >= kMixGrowSeconds - kSlackSeconds) {
                mixGrowSeconds_ = 0;
                ++mixActive_;
            }
        } else {
            mixLosingSeconds_ = mixGrowSeconds_ = 0;
        }
    }
    if (pool_) pool_->setActive(autoOn ? mixActive_ : pool_->workers());
    if (offline_.load(std::memory_order_relaxed)) return;  // an export renders as fast as it can: it never sheds
    // While the pool's Auto settles, its callbacks' cost is the pool starting, not the song: they don't count
    // toward the over-budget share, and nothing is shed. A callback is over when its load per frame rendered
    // passes kOverLoad, or when it missed its played frames' deadline: through the FIFO a callback that renders a
    // block more than it plays can miss it at a per-frame load under kOverLoad.
    const bool over = load > kOverLoad || raw >= 1.0;
    if (!settling) overShare_ = shareKeep_ * overShare_ + (1.0 - shareKeep_) * (over ? 1.0 : 0.0);
    const bool wasCooling = coolSeconds_ > 0;
    coolSeconds_ = std::max(0.0, coolSeconds_ - dt);
    if (wasCooling && coolSeconds_ <= 0 && measureSlot_ >= 0) {
        // A second after a shed the meter shows the load without that layer: what it cost.
        Slot& s = slotAt(measureSlot_);
        if (s.overloaded) s.shedCost = std::clamp(measureFrom_ - loadAvg_, 0.0, s.shedCost);
        measureSlot_ = -1;
    }
    // And over now (the meter's ~0.1 s average over kRestoreCeiling): the 0.8 s share remembers a stretch after its
    // load is gone, and a layer must not go for load that has already passed.
    // And over now (1.1.2: the meter's ~0.1 s average over kRestoreCeiling): a layer never goes for load that has
    // already passed.
    if (!settling && overShare_ > kOverShare && loadAvg_ > kRestoreCeiling && coolSeconds_ <= kSlackSeconds) {
        if (pool_ && autoOn && mixAuto_ && waitAvg_ > kMixWaitShare) {
            // The pool itself may be the overload (the callback waiting on its workers): one thread first, for
            // kMixRetrySeconds, and the share starts again; a song still over on one thread then sheds.
            mixAuto_ = false;
            mixActive_ = pool_->workers();
            mixRetrySeconds_ = kMixRetrySeconds;
            mixLosingSeconds_ = mixGrowSeconds_ = 0;
            waitAvg_ = workAvg_ = 0;
            overShare_ = 0;
            pool_->setActive(mixActive_);
            return;
        }
        overloadPending_ = true;
        shedLoad_ = loadAvg_;
        coolSeconds_ = kCoolSeconds;
        underSeconds_ = 0;
        return;
    }
    underSeconds_ = loadAvg_ < kRestoreLoad ? underSeconds_ + dt : 0.0;
    if (overloadedFlag_.load(std::memory_order_relaxed) > 0 && coolSeconds_ <= 0 && underSeconds_ >= kRestoreSeconds - kSlackSeconds)
        restorePending_ = true;  // process() brings one back, if it fits (restoreOne)
}

}  // namespace caw
