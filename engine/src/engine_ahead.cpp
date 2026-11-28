// Play-ahead on the Engine's side (play_ahead.h): which tracks go ahead, the chunk plan while one plays from its ring,
// parked commands, drains, underruns and drops.
#include "engine_impl.h"

namespace caw {

static_assert(AheadTrack::kBlock == kBlock, "an ahead track's chunks are the Engine's");

namespace {
std::atomic<int> gTestPlayAhead{-1};  // tests: every new Engine's sync play-ahead (setPlayAheadForTest)
constexpr double kAheadQuietSeconds = 3.0;  // a track goes ahead this long after the last edit or note aimed at it
constexpr double kAheadFadeSeconds = 0.005; // an underrun's fade out, and the fade back in live
constexpr int64_t kAheadLead = 4096;        // frames the callback renders ahead itself before the thread takes over
constexpr double kAheadDepthSeconds = 1.0;  // each ring (fixed in this slice)
}  // namespace

void Engine::setPlayAheadForTest(int extraFrames) noexcept { gTestPlayAhead.store(extraFrames, std::memory_order_relaxed); }
int Engine::playAheadForTest() noexcept { return gTestPlayAhead.load(std::memory_order_relaxed); }

// Control thread (or the constructor): the rings and, unless a test fills them on the callback, the thread.
void Engine::makePlayAhead(bool thread) {
    if (ahead_) return;
    const int64_t depth = std::max<int64_t>(8 * kBlock, static_cast<int64_t>(std::llround(kAheadDepthSeconds * sr_)));
    aheadInbox_.reset(new Cmd[static_cast<size_t>(PlayAhead::kTracks) * kAheadInbox]);
    ahead_ = std::make_unique<PlayAhead>(depth, thread, &Engine::aheadRender, this);
    aheadPtr_.store(ahead_.get(), std::memory_order_release);
}

void Engine::setPlayAhead(bool on) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (on) makePlayAhead(aheadSyncExtra_ < 0);
    aheadOn_.store(on, std::memory_order_release);
}

void Engine::stallPlayAheadForTest(bool on) noexcept {
    if (PlayAhead* a = aheadPtr_.load(std::memory_order_acquire)) a->stallForTest.store(on, std::memory_order_relaxed);
}

Engine::AheadStats Engine::aheadStats() const noexcept {
    AheadStats st;
    st.tracks = aheadTracks_.load(std::memory_order_relaxed);
    st.underruns = aheadUnderruns_.load(std::memory_order_relaxed);
    st.drops = aheadDrops_.load(std::memory_order_relaxed);
    if (const PlayAhead* a = aheadPtr_.load(std::memory_order_acquire)) {
        st.workNs = a->workNs.load(std::memory_order_relaxed);
        st.workFrames = a->workFrames.load(std::memory_order_relaxed);
    }
    return st;
}

// The producer's next chunk for track t (the ahead thread, or the callback building the lead or in tests): the
// track node's pre-fader half (planTrack, runInstrument, runInserts) on the track's own clock, into the ring.
int Engine::aheadRender(void* ctx, AheadTrack& t, int most) noexcept {
    Engine& e = *static_cast<Engine*>(ctx);
    if (!t.room()) return 0;
    Slot& s = *static_cast<Slot*>(t.slotRef);
    TrackClock& c = t.clock;
    int m = static_cast<int>(std::min<int64_t>({static_cast<int64_t>(most), kBlock, c.wrapAt() - c.g}));
    if (m <= 0) return 0;
    e.planTrack(s, m, c);
    if (!c.timeConstant) c.song->tempo.stepsAt(c.g, m, t.steps);
    e.runInstrument(s, m, c);
    std::copy_n(s.instL, m, t.bufL);
    std::copy_n(s.instR, m, t.bufR);
    e.runInserts(s, t.bufL, t.bufR, m, c);
    t.push(t.bufL, t.bufR, m, s.n0, s.layerLen);
    c.advance(m);
    return m;
}

// Whether the slot may stay ahead (or go ahead): the first slice's eligibility (docs/engine.md), and nothing that is
// intent (muted, soloed out, shed, removed, a preview or device note sounding on it).
bool Engine::aheadKeep(const Slot& s) noexcept {
    if (!aheadOn_.load(std::memory_order_relaxed) || chunkProfile_) return false;
    if (!s.active || !s.track || s.bus || s.removing || s.overloaded || s.previewing || s.midiOut) return false;
    if (!s.instrument || s.instrument->liveInput() || (s.inserts && s.inserts->liveInput()) || slotForeign(s) || s.instrumentFading || s.insertsFading || s.instrumentFadeLeft > 0 ||
        s.insertsFadeLeft > 0)
        return false;
    if (s.index == auditionSlot_ || samplePreview_->route() == s.index) return false;
    if (s.sends && s.sends->keys) return false;  // it keys another track's effect
    const MixGraph& g = *mixGraph_;
    if (g.inCount[s.index] > 0) return false;  // sends or keys arrive into it
    if (noteFx_->forSlot(s.index) || modulation_->listens(s.index) || modulation_->modulatesChains(s.index)) return false;
    if (s.tapL) return false;  // an offline stem render
    return slotTarget(s) > 0.0;
}

void Engine::aheadRequestDrain(AheadTrack& t, bool fast) noexcept {
    t.drain.store(true, std::memory_order_release);
    if (fast && !t.underrun) {  // back now: what the ring holds fades out over 5 ms
        t.underrun = true;
        t.fadeLen = t.fadeLeft = static_cast<int>(std::min<int64_t>(
            t.fill(), std::max<int64_t>(1, std::llround(kAheadFadeSeconds * sr_))));
    }
    ahead_->wake();
}

// Before a command runs: where it goes while some track is ahead.
Engine::AheadRoute Engine::aheadRoute(const Cmd& c) noexcept {
    switch (c.type) {
        // The transport, the tempo map, touches: every ring is dropped first.
        case Cmd::Play:
        case Cmd::Stop:
        case Cmd::Transport:
        case Cmd::SetSong:
        case Cmd::ReleaseTouches:
            return aheadDropAll() ? AheadRoute::Apply : AheadRoute::Wait;
        case Cmd::Preview:
            if (c.previewOp == 3) return AheadRoute::Apply;  // previewCommand passes over ahead tracks (none preview)
            break;
        case Cmd::SetComponentAutomation:
            if (c.slot < 0) return AheadRoute::Apply;  // the master's
            break;
        case Cmd::Install:
        case Cmd::SetSteps:
        case Cmd::SetPattern:
        case Cmd::SetInserts:
        case Cmd::SetInstrument:
        case Cmd::SetMidiOut:
        case Cmd::ConfigureBus:
        case Cmd::SetValue:
        case Cmd::Remove:
        case Cmd::SetSends:
        case Cmd::SetSendLevel:
        case Cmd::SetDelay:
        case Cmd::SetAutomation:
        case Cmd::SetRouting:
            break;
        default:
            return AheadRoute::Apply;  // the master, order, VCA groups, the table: nothing an ahead render reads
    }
    if (c.slot < 0 || c.slot >= slotCount_) return AheadRoute::Apply;
    Slot& s = slotAt(c.slot);
    if (s.ahead < 0) return AheadRoute::Apply;
    AheadTrack& t = ahead_->track(s.ahead);
    // A mix move (sends, their levels, the latency delay, volume and pan lanes, its output) applies at once, unless
    // something for the slot already waits (the order stays). A removal is a mix move too (it fades the fader out),
    // and intent: the track comes back live at the ring's end.
    switch (c.type) {
        case Cmd::Remove:
        case Cmd::SetSends:
        case Cmd::SetSendLevel:
        case Cmd::SetDelay:
        case Cmd::SetAutomation:
        case Cmd::SetRouting:
            if (t.parked == 0) {
                if (c.type == Cmd::Remove || c.type == Cmd::SetSends) aheadRequestDrain(t, false);
                return AheadRoute::Apply;
            }
            return AheadRoute::Park;
        default:
            return AheadRoute::Park;
    }
}

// A seek, loop, tempo or project change: nothing more from any ring is heard, and every track comes back live now.
// False while some producer is still mid-chunk (the ahead thread lets go within one chunk; the command waits).
bool Engine::aheadDropAll() noexcept {
    bool all = true;
    PlayAhead& a = *ahead_;
    for (int i = 0; i < PlayAhead::kTracks; ++i) {
        AheadTrack& t = a.track(i);
        int st = t.state.load(std::memory_order_acquire);
        if (st == AheadTrack::Free) continue;
        if (!t.dropped) {
            t.dropped = true;
            aheadDrops_.fetch_add(1, std::memory_order_relaxed);
        }
        t.drain.store(true, std::memory_order_release);
        if (!a.threaded() && st == AheadTrack::Worker) {  // tests: no thread runs it now
            t.state.store(AheadTrack::Released, std::memory_order_relaxed);
            st = AheadTrack::Released;
        }
        if (st == AheadTrack::Lead) st = AheadTrack::Released;  // the callback was the producer
        if (st != AheadTrack::Released) {
            all = false;
            continue;
        }
        const int64_t w = t.written.load(std::memory_order_acquire);
        t.read.store(w, std::memory_order_relaxed);  // the rest is dropped
        t.metaRead.store(std::max<int64_t>(0, t.metaWritten.load(std::memory_order_relaxed) - 1), std::memory_order_relaxed);
        if (!aheadHandBack(slotAt(t.slot), t)) all = false;
    }
    if (!all) a.wake();
    return all;
}

// The ring has played out and its producer let go: the slot is live from this frame. Its parked commands run now,
// in order; a track that went silent (an underrun) or whose instrument ran ahead of the playhead (a drop) picks up
// the notes at the playhead (as after a loop back) and fades in over 5 ms.
bool Engine::aheadHandBack(Slot& s, AheadTrack& t) noexcept {
    const size_t base = static_cast<size_t>(s.ahead) * kAheadInbox;
    size_t need = 0;
    for (int k = 0; k < t.parked; ++k) need += retirementNeed(aheadInbox_[base + static_cast<size_t>(k)]);
    if (!canRetire(need)) return false;
    const int64_t written = t.written.load(std::memory_order_acquire);
    const bool aligned = t.pos == written;
    const bool fade = t.underrun || !aligned;
    t.state.store(AheadTrack::Free, std::memory_order_release);
    s.aheadOwned.store(false, std::memory_order_seq_cst);
    s.ahead = -1;
    s.mode = Slot::Mode::Play;  // as it was heard: a chain swap now crossfades
    if (!aligned) s.epoch = -1;  // planTrack starts the pass over at the playhead: held notes go, the rest is chased
    if (fade) {
        s.aheadFadeLen = s.aheadFadeIn = std::max(1, static_cast<int>(std::llround(kAheadFadeSeconds * sr_)));
    }
    const int parked = t.parked;
    t.parked = 0;
    t.slot = -1;
    t.slotRef = nullptr;
    aheadTracks_.fetch_sub(1, std::memory_order_relaxed);
    for (int k = 0; k < parked; ++k) {
        Cmd& c = aheadInbox_[base + static_cast<size_t>(k)];
        applyCommand(c);
        c = Cmd{};
    }
    routingDirty_ = true;
    updateSolo();
    return true;
}

// Callback start, after the commands: tracks that may go ahead do (with the transport running and no count-in or stop).
void Engine::aheadBegin(int frames) noexcept {
    PlayAhead* a = aheadPtr_.load(std::memory_order_acquire);
    if (!a) return;
    // Edits seen: a slot's quiet time starts again (control-thread edits bump aheadTouch).
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        const uint32_t touch = s.aheadTouch.load(std::memory_order_relaxed);
        if (touch != s.aheadTouchSeen) {
            s.aheadTouchSeen = touch;
            s.aheadQuiet = 0;
            if (s.ahead >= 0) aheadRequestDrain(a->track(s.ahead), false);  // an edit is intent
        } else {
            s.aheadQuiet += frames;
        }
    }
    if (!aheadOn_.load(std::memory_order_relaxed) || !playing_ || countInLeft_ > 0 || stopFade_ > 0 || chunkProfile_ ||
        previewing_)
        return;
    const int64_t quiet = a->threaded() ? static_cast<int64_t>(kAheadQuietSeconds * sr_) : 0;
    int free = 0;
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        if (s.ahead >= 0 || s.aheadBanned || s.mode != Slot::Mode::Play || s.aheadQuiet < quiet || !aheadKeep(s)) continue;
        while (free < PlayAhead::kTracks && (a->track(free).state.load(std::memory_order_acquire) != AheadTrack::Free ||
                                             a->track(free).parked > 0))
            ++free;
        if (free == PlayAhead::kTracks) break;
        // An edit on its way stops it (aheadEdit's other half).
        s.aheadOwned.store(true, std::memory_order_seq_cst);
        if (s.aheadTouch.load(std::memory_order_seq_cst) != s.aheadTouchSeen) {
            s.aheadOwned.store(false, std::memory_order_seq_cst);
            continue;
        }
        AheadTrack& t = a->track(free);
        t.clear();
        t.slot = live_[k];
        t.slotRef = &s;
        t.lastN0 = s.lastN;
        t.lastLayerLen = s.layerLen;
        syncClock();
        t.clock = clock_;
        t.clock.ahead = true;
        t.clock.profile = nullptr;
        t.clock.previewChunk = false;
        t.clock.chunk = -2;  // no key is ever stamped with it: a keyed effect hears silence, as with no key routed
        t.clock.steps = t.steps;
        s.ahead = free;
        aheadTracks_.fetch_add(1, std::memory_order_relaxed);
        t.state.store(a->threaded() ? AheadTrack::Lead : AheadTrack::Worker, std::memory_order_release);
    }
}

// planChunk for an ahead slot: how many frames this chunk can take from its ring (the chunk is cut at the ring's
// end, so the slot comes back live on a chunk boundary), its lead, underruns. False: it is live again (plan it so).
bool Engine::planAhead(Slot& s, int& m) noexcept {
    PlayAhead& a = *ahead_;
    AheadTrack& t = a.track(s.ahead);
    s.target = slotTarget(s);
    if (!t.drain.load(std::memory_order_relaxed) && !aheadKeep(s)) aheadRequestDrain(t, false);
    // Tests (no thread): a drain lets go now; the ring is filled in the track's node (aheadPull), so this chunk
    // will find m + aheadSyncExtra_ frames there unless the producer is stalled.
    const bool sync = !a.threaded();
    if (sync && t.drain.load(std::memory_order_relaxed)) a.serviceSync(t, 0);
    int st = t.state.load(std::memory_order_acquire);
    if (st == AheadTrack::Lead && t.drain.load(std::memory_order_relaxed)) {
        t.state.store(AheadTrack::Released, std::memory_order_relaxed);  // the callback was the producer
        st = AheadTrack::Released;
    }
    int64_t fill = t.fill();
    if (sync && st == AheadTrack::Worker && !a.stallForTest.load(std::memory_order_relaxed))
        fill = std::max<int64_t>(fill, std::min<int64_t>(t.size, m + aheadSyncExtra_));
    if (st == AheadTrack::Released) {
        if (t.dropped) {
            t.read.store(t.written.load(std::memory_order_relaxed), std::memory_order_relaxed);
            fill = 0;
        }
        if (fill == 0) {
            if (aheadHandBack(s, t)) return false;
        } else {
            m = static_cast<int>(std::min<int64_t>(m, fill));  // the handover lands on a chunk boundary
        }
    } else if (st == AheadTrack::Lead) {
        // The callback renders the lead itself: this chunk's frames, and one chunk more while short of the lead.
        const int64_t want = m + std::min<int64_t>(kAheadLead, fill + kBlock);
        while (fill < want) {
            const int n = aheadRender(this, t, static_cast<int>(std::min<int64_t>(kBlock, want - fill)));
            if (n <= 0) break;
            fill += n;
        }
        if (fill < m) m = static_cast<int>(std::max<int64_t>(1, fill));  // [Assumption] a full ring never starts short
        if (fill - m >= kAheadLead) {
            t.state.store(AheadTrack::Worker, std::memory_order_release);
            a.wake();
        }
    } else if (!t.underrun) {
        // Short of this chunk plus a fade's worth (a test's ring holds only what it was filled past the chunk).
        int64_t fadeFrames = std::max<int64_t>(1, std::llround(kAheadFadeSeconds * sr_));
        if (!a.threaded()) fadeFrames = std::min<int64_t>(fadeFrames, std::max(0, aheadSyncExtra_));
        if (fill < m + fadeFrames) {
            // An underrun: the producer fell behind. What is left fades out, and the track plays live from then on.
            aheadUnderruns_.fetch_add(1, std::memory_order_relaxed);
            s.aheadBanned = true;
            aheadRequestDrain(t, true);
        }
    }
    s.mode = Slot::Mode::Ahead;
    return true;
}

// The track node's pre-fader half for an ahead slot: its ring's frames (faded out by an underrun, silence after it or a
// drop) into insL/insR, and the last frame's place in its layer's loop for the progress meter.
void Engine::aheadPull(Slot& s, int m, int64_t& n0Last, double& layerLen) noexcept {
    AheadTrack& t = ahead_->track(s.ahead);
    if (!ahead_->threaded() && t.state.load(std::memory_order_relaxed) == AheadTrack::Worker)
        ahead_->serviceSync(t, m + aheadSyncExtra_);  // tests: the producer's work, here in the node (as live)
    const int64_t fill = t.fill();
    const int take = static_cast<int>(std::min<int64_t>(m, fill));
    n0Last = t.lastN0 + m;
    layerLen = t.lastLayerLen;
    if (take > 0) {
        t.pop(t.dropped ? nullptr : s.insL, s.insR, take, n0Last, layerLen);
        if (take < m) n0Last += m - take;
        t.lastN0 = n0Last;
        t.lastLayerLen = layerLen;
    } else {
        t.lastN0 = n0Last;
    }
    const int heard = t.dropped ? 0 : take;
    if (t.underrun) {
        int i = 0;
        for (; i < heard && t.fadeLeft > 0; ++i, --t.fadeLeft) {
            const float w = static_cast<float>(t.fadeLeft) / static_cast<float>(t.fadeLen + 1);
            s.insL[i] *= w;
            s.insR[i] *= w;
        }
        std::fill(s.insL + i, s.insL + m, 0.0f);
        std::fill(s.insR + i, s.insR + m, 0.0f);
    } else if (heard < m) {
        std::fill(s.insL + heard, s.insL + m, 0.0f);
        std::fill(s.insR + heard, s.insR + m, 0.0f);
    }
    t.pos += m;
    // The thread sleeps while the ring is nearly full; it is worth waking once there is room for a batch.
    if (ahead_->threaded() && t.size - (fill - take) >= t.size / 16) ahead_->wake();
}

}  // namespace caw
