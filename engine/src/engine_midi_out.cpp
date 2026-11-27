// The Engine's MIDI out and MIDI clock (API 47): timed messages to the platform sender, clock out from the tempo
// map, and following an incoming clock on the control side.
#include "engine_impl.h"

#include <algorithm>
#include <cmath>

namespace caw {

// ---- audio thread ----

NoteEvents* Engine::notesOf(Slot& s) noexcept {
    if (s.instrument) return s.instrument->notes();
    return s.midiOut ? &s.midiOut->notes() : nullptr;
}

// One message at `frame` of this callback (a fraction: the clock's ticks fall between samples). Its time: the
// callback's frame 0 as heard (midiOutAnchorNs_: the callback's start on the MIDI clock, the output latency and the
// mix's delay) plus the frame, plus the port's own offset.
void Engine::midiOutEmit(int port, double frame, const uint8_t* data, int size, bool essential) noexcept {
    // Nothing while no sender is attached (setMidiOutActive): nobody would drain it.
    if (!midiOutActive_.load(std::memory_order_relaxed) || offline_.load(std::memory_order_relaxed) || port < 0 ||
        port >= kMidiOutPorts || size < 1 || size > 3)
        return;
    MidiOutMessage m;
    m.timeNs = midiOutAnchorNs_ + static_cast<int64_t>(std::llround(frame * 1e9 / sr_)) +
               midiOutOffsetNs_[port].load(std::memory_order_relaxed);
    m.port = static_cast<uint8_t>(port);
    m.size = static_cast<uint8_t>(size);
    m.reserved[0] = essential ? kMidiEssential : 0;
    for (int k = 0; k < size; ++k) m.data[k] = data[k];
    midiOutQ_->push(m);
}

void Engine::flushLane(MidiOutLane& lane, int baseFrame) noexcept {
    const MidiOutStaged* st = lane.staged();
    for (uint32_t k = 0; k < lane.stagedCount(); ++k)  // each to the port it was made for (a port change's offs)
        midiOutEmit(st[k].port, static_cast<double>(baseFrame) + st[k].frame, st[k].data, st[k].size, st[k].essential);
    lane.clearStaged();
    if (const uint64_t lost = lane.takeOverflow()) midiOutQ_->countDropped(lost);
}

void Engine::lanesOff(int frame, bool program) noexcept {
    for (int k = 0; k < liveCount_; ++k) {
        Slot& s = slotAt(live_[k]);
        if (!s.midiOut) continue;
        s.midiOut->allOff(0);
        if (program) s.midiOut->sendProgram(0);
        flushLane(*s.midiOut, frame);
    }
}

void Engine::clockSend(uint32_t ports, double frame, uint8_t a, int pos) noexcept {
    uint8_t d[3] = {a, 0, 0};
    int size = 1;
    if (pos >= 0) {
        d[0] = midibyte::kSongPosition;
        d[1] = static_cast<uint8_t>(pos & 0x7F);
        d[2] = static_cast<uint8_t>((pos >> 7) & 0x7F);
        size = 3;
    }
    for (int p = 0; p < kMidiOutPorts; ++p)
        if (ports & (1u << p)) midiOutEmit(p, frame, d, size, a == midibyte::kStop);
}

// Play (startPlay, g_ set): the clock starts where the playhead is. Per MIDI 1.0 the first tick after Start or
// Continue is the song position itself, and a Song Position Pointer counts whole sixteenths (6 ticks): so from the
// song's start, Start; from elsewhere, the next whole sixteenth as the position, Continue, and no tick until then.
// A Play while the clock runs (a locate) stops it first.
void Engine::clockStart(int frame) noexcept {
    const uint32_t want = clockOutMask_.load(std::memory_order_relaxed);
    if (clockPorts_) clockSend(clockPorts_, frame, midibyte::kStop);
    clockPorts_ = want;
    if (!want) return;
    const double step = song_->tempo.stepAt(static_cast<double>(g_));
    const int64_t target = std::max<int64_t>(0, static_cast<int64_t>(std::ceil(step - 1e-6)));
    clockTick_ = target * 6;
    if (target == 0) {
        clockSend(want, frame, midibyte::kStart);
    } else {
        clockSend(want, frame, 0, static_cast<int>(std::min<int64_t>(target, 16383)));  // 14 bits: 1,023 4/4 bars
        clockSend(want, frame, midibyte::kContinue);
    }
}

// A playing chunk [g_, g_ + m) at callback frame `frame`: the ticks that fall in it, at their exact times on the
// tempo map. A port taken off the mask stops at once. A jump (a tempo change that kept the sample, not the beat)
// relocates as a Play would.
void Engine::clockChunk(int frame, int m) noexcept {
    const uint32_t want = clockOutMask_.load(std::memory_order_relaxed);
    if (const uint32_t gone = clockPorts_ & ~want) {
        clockSend(gone, frame, midibyte::kStop);
        clockPorts_ &= want;
    }
    if (!clockPorts_) return;
    const TempoMap& tm = song_->tempo;
    const double from = static_cast<double>(g_), end = from + m;
    const double ticksNow = tm.stepAt(from) * 6.0;
    if (static_cast<double>(clockTick_) < ticksNow - 1.0 || static_cast<double>(clockTick_) > ticksNow + 6.5) {
        const uint32_t ports = clockPorts_;
        clockPorts_ = 0;  // so clockStart sends no Stop of its own
        clockSend(ports, frame, midibyte::kStop);
        clockStart(frame);
        clockPorts_ &= ports;
        if (!clockPorts_) return;
    }
    for (int n = 0; n < 64; ++n) {  // a chunk holds at most one or two (64 frames; 999 BPM is 400 ticks a second)
        const double at = tm.frameAt(static_cast<double>(clockTick_) / 6.0);
        if (!(at < end)) break;
        if (at >= from - 1.0) clockSend(clockPorts_, frame + std::max(0.0, at - from), midibyte::kClock);
        ++clockTick_;
    }
}

// The song (or the loop range) wrapped at callback frame `frame`: Stop, then Start (to the song's start) or the
// loop start's position and Continue, so the receiver jumps back with it.
void Engine::clockLoop(int frame) noexcept {
    const int64_t target = loopRange_ ? std::max(0, loopFromSteps_) : 0;
    clockSend(clockPorts_, frame, midibyte::kStop);
    clockTick_ = target * 6;
    if (target == 0) {
        clockSend(clockPorts_, frame, midibyte::kStart);
    } else {
        clockSend(clockPorts_, frame, 0, static_cast<int>(std::min<int64_t>(target, 16383)));
        clockSend(clockPorts_, frame, midibyte::kContinue);
    }
}

// ---- any thread but the audio thread ----

int32_t Engine::midiOutDrain(MidiOutMessage* out, int32_t cap) noexcept {
    if (!out || cap <= 0) return 0;
    const int64_t test = midiClockTest_.load(std::memory_order_relaxed);
    const int64_t now = test >= 0 ? test : midiClockNs();
    std::lock_guard<std::mutex> lock(midiOutDrainLock_);
    const int32_t n = midiOutQ_->drain(out, cap, now);
    for (int32_t k = 0; k < n; ++k) out[k].reserved[0] = 0;
    return n;
}

void Engine::setMidiOutActive(bool on) noexcept {
    std::lock_guard<std::mutex> lock(midiOutDrainLock_);
    if (on && !midiOutActive_.load(std::memory_order_relaxed)) midiOutQ_->clear();  // a new sender starts from now
    midiOutActive_.store(on, std::memory_order_release);
}

uint64_t Engine::midiOutDropped() const noexcept {
    return midiOutQ_->dropped();
}

void Engine::setMidiOutPortOffset(int port, int64_t offsetNs) noexcept {
    if (port < 0 || port >= kMidiOutPorts) return;
    midiOutOffsetNs_[port].store(std::clamp<int64_t>(offsetNs, -1'000'000'000, 1'000'000'000), std::memory_order_relaxed);
}

void Engine::setOutputLatencyNs(int64_t ns) noexcept {
    midiOutLatencyNs_.store(std::clamp<int64_t>(ns, 0, 2'000'000'000), std::memory_order_relaxed);
}

// Following (bpm > 0): the live tempo the follower's estimate gives, nudged toward the master's position, as a map
// that keeps the song's current timing up to just past the playhead and changes tempo only from there, so the
// playhead never jumps (SetSong's follow flag keeps the sample). At most three points: the time before the
// playhead's segment folded into one average tempo (its end lands on the same sample), that segment, and the new
// tempo from `kFollowLeadSteps` past the playhead. Stopped, the map is the one tempo. bpm 0: the project's map back.
void Engine::followTempo(double bpm, double masterStep, int64_t tickNs) {
    std::lock_guard<std::mutex> lock(ctl_);
    if (bpm > 0) {
        // Checked under ctl_: a follow turned off meanwhile (setMidiClockFollow) has already put the project's map
        // back, and a late estimate must not replace it.
        if (!follow_.load(std::memory_order_acquire)) return;
        const TempoMap& now = ctlSong_.tempo;
        const int64_t pos = positionAt(tickNs);
        double target = bpm;
        if (pos >= 0 && masterStep >= 0) {
            // The master's position at the tick against where the engine is heard then (its render position less
            // the output latency): the error, in steps, closes over kFollowCatchSeconds through the tempo, at most
            // kFollowMaxNudge either way. Errors of two steps or more (a wrap, a jump) are left to the transport.
            const double latency = static_cast<double>(midiOutLatencyNs_.load(std::memory_order_relaxed)) * ctlSr_ / 1e9;
            const double heard = now.stepAt(std::max(0.0, static_cast<double>(pos) - latency));
            const double err = masterStep - heard;
            if (std::fabs(err) < 2.0)
                target *= 1.0 + std::clamp(15.0 * err / (kFollowCatchSeconds * bpm), -kFollowMaxNudge, kFollowMaxNudge);
        }
        target = std::clamp(target, 1.0, 999.0);
        if (ctlFollowBpm_ > 0 && std::fabs(target - ctlFollowBpm_) <= kFollowHysteresisBpm) return;
        const double applied = ctlFollowBpm_ > 0 ? ctlFollowBpm_ + kFollowSmoothing * (target - ctlFollowBpm_) : target;
        if (ctlFollowBpm_ == 0) ctlProjectTempo_ = now.points();
        ctlFollowBpm_ = applied;
        std::vector<TempoPointSpec> points;
        if (pos < 0) {
            points.push_back({0, applied, false});
        } else {
            const double renderBeat = now.stepAt(static_cast<double>(pos)) / 4.0;
            const double changeBeat = renderBeat + kFollowLeadSteps / 4.0;
            const std::vector<TempoPointSpec>& old = now.points();
            size_t j = 0;  // the segment the playhead is in
            while (j + 1 < old.size() && old[j + 1].beat <= renderBeat) ++j;
            const double segBpm = old[j].bpm;  // [Assumption] a ramp into the next point is taken as its start tempo
            if (j == 0 || old[j].beat <= 0) {
                points.push_back({0, segBpm, false});
            } else {
                const double seconds = now.frameAt(old[j].beat * 4.0) / ctlSr_;
                const double avg = seconds > 0 ? std::clamp(60.0 * old[j].beat / seconds, 1.0, 999.0) : segBpm;
                points.push_back({0, avg, false});
                points.push_back({old[j].beat, segBpm, false});
            }
            points.push_back({changeBeat, applied, false});
        }
        SongTime next = ctlSong_;
        next.tempo.build(points, ctlSr_);
        sendSong(std::move(next), true);
    } else if (ctlFollowBpm_ > 0) {
        ctlFollowBpm_ = 0;
        SongTime next = ctlSong_;
        next.tempo.build(ctlProjectTempo_, ctlSr_);
        sendSong(std::move(next), true);
    }
}

void Engine::setMidiClockFollow(bool on) {
    {
        std::lock_guard<std::mutex> lock(clockInLock_);
        if (follow_.exchange(on, std::memory_order_acq_rel) == on) return;
        follower_.reset();
        followTicks_ = 0;
        clockInBpm_.store(0, std::memory_order_relaxed);
    }
    if (!on) followTempo(0, -1, 0);  // the project's tempo map again
}

int Engine::midiClockIn(const uint8_t* bytes, int count, int64_t timeNs) {
    if (!bytes || count <= 0) return 0;
    if (timeNs <= 0) timeNs = midiClockNs();
    int acted = 0;
    // What to do once the follower's lock is let go (play and stop take ctl_; never both locks at once).
    enum class Do { None, Play, Stop } todo = Do::None;
    double playFrom = 0, tempo = 0, master = -1;
    {
        std::lock_guard<std::mutex> lock(clockInLock_);
        const bool follow = follow_.load(std::memory_order_relaxed);
        for (int i = 0; i < count; ++i) {
            const ClockFollower::Action a = follower_.feed(bytes[i], timeNs);
            if (a == ClockFollower::Action::None) continue;
            ++acted;
            if (!follow) continue;
            switch (a) {
                case ClockFollower::Action::Start: todo = Do::Play; playFrom = 0; break;
                case ClockFollower::Action::Continue: todo = Do::Play; playFrom = follower_.songPosition(); break;
                case ClockFollower::Action::Stop: todo = Do::Stop; break;
                case ClockFollower::Action::Locate:
                    // A locate while running (some masters send one): play on from there.
                    if (follower_.running()) { todo = Do::Play; playFrom = follower_.songPosition(); }
                    break;
                case ClockFollower::Action::Tick:
                    // The live tempo, looked at every sixteenth (followTempo decides whether it moves).
                    if (follower_.locked() && ++followTicks_ >= 6) {
                        followTicks_ = 0;
                        tempo = follower_.bpm();
                        master = follower_.running() ? follower_.positionSteps() : -1;
                    }
                    break;
                default: break;
            }
        }
        clockInBpm_.store(follower_.bpm(), std::memory_order_relaxed);
    }
    // [Assumption, documented] no play-at-a-time exists: the Start reaches the audio thread at its next callback,
    // so the transport starts up to one callback (plus the output latency) after the byte arrived; the position
    // nudge (followTempo) then takes the rest out.
    if (todo != Do::None && follow_.load(std::memory_order_acquire)) {
        if (todo == Do::Play) play(playFrom);
        else stop();
    }
    if (tempo > 0) followTempo(tempo, todo == Do::None ? master : -1, timeNs);
    return acted;
}

}  // namespace caw
