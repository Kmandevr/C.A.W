// MIDI effects' shared base: the event clock, the queue of later events, sorted output, seeded randomness and display.
#include "midi_fx.h"

#include <algorithm>
#include <cmath>
#include <new>

namespace caw::midifx {

bool isMidiEffect(const ModuleDescriptor& d) noexcept {
    if (d.portCount != 2 || !d.ports) return false;
    bool in = false, out = false;
    for (uint32_t k = 0; k < 2; ++k) {
        const PortDescriptor& p = d.ports[k];
        if (p.type != PortType::Event) return false;
        (p.input ? in : out) = true;
    }
    return in && out;
}

void setNoteIdBase(ModuleProcessor& p, uint32_t base) noexcept {
    if (auto* m = dynamic_cast<MidiEffect*>(&p)) m->setIdBase(base);
}

bool MidiEffect::activate(double sampleRate, uint32_t) noexcept {
    rate_ = sampleRate > 0.0 ? sampleRate : 48000.0;
    if (queueCap_ > 0 && !queue_) {
        queue_.reset(new (std::nothrow) Queued[queueCap_]);
        if (!queue_) return false;
    }
    clock_.prepare(rate_, 30.0);  // a MIDI effect's page moves slowly: 30 publishes a second
    display_.clear();
    reset();
    return true;
}

void MidiEffect::reset() noexcept {
    queued_ = 0;
    now_ = 0;
    idNext_ = 0;
    onsIn_ = onsOut_ = 0;
    clearState();
}

double MidiEffect::param(uint32_t k, uint32_t at) const noexcept {
    const double fallback = k < d_.parameterCount ? d_.parameters[k].defaultValue : 0.0;
    if (!block_) return fallback;
    const double v = parameterAt(*block_, k, at < frames_ ? at : (frames_ ? frames_ - 1 : 0), fallback);
    return std::isfinite(v) ? v : fallback;
}

uint32_t MidiEffect::newId() noexcept {
    idNext_ = (idNext_ + 1) & 0xFFFFFFu;
    if (idNext_ == 0) idNext_ = 1;
    return idBase_ | idNext_;
}

void MidiEffect::emit(uint32_t at, const Event& e) noexcept {
    if (!out_) return;
    const bool off = isOff(e);
    if (out_->count >= out_->capacity || (!off && out_->count + kOutKeep >= out_->capacity)) return;
    Event x = e;
    x.frame = at < frames_ ? at : frames_ - 1;
    out_->events[out_->count++] = x;
    if (x.kind == EventKind::Note && ((x.data[0] >> 20) & 0xF) == 0x9) ++onsOut_;
}

bool MidiEffect::schedule(int64_t at, Event e) noexcept {
    if (at < now_) at = now_;
    if (at < now_ + frames_) {
        emit(static_cast<uint32_t>(at - now_), e);
        return true;
    }
    const bool off = isOff(e);
    if (queued_ >= queueCap_ || (!off && queued_ + queueCap_ / 4 >= queueCap_)) return false;
    queue_[queued_++] = {at, e};
    return true;
}

bool MidiEffect::cancel(uint32_t id) noexcept {
    bool found = false;
    uint32_t keep = 0;
    for (uint32_t i = 0; i < queued_; ++i) {
        const Queued& q = queue_[i];
        if (q.e.noteId == id && (found || ((q.e.data[0] >> 20) & 0xF) == 0x9)) {
            found = true;
            continue;
        }
        queue_[keep++] = q;
    }
    queued_ = keep;
    return found;
}

double MidiEffect::unit(uint32_t seed, uint64_t a, uint64_t b, uint32_t salt) noexcept {
    // splitmix64 over the inputs: integer maths, the same bits on every device.
    uint64_t z = (static_cast<uint64_t>(seed) << 32 | salt) ^ (a * 0x9E3779B97F4A7C15ull) ^ (b * 0xD1B54A32D192ED03ull);
    z += 0x9E3779B97F4A7C15ull;
    z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9ull;
    z = (z ^ (z >> 27)) * 0x94D049BB133111EBull;
    z ^= z >> 31;
    return static_cast<double>(z >> 11) * (1.0 / 9007199254740992.0);
}

Event MidiEffect::withKey(Event e, uint8_t key) noexcept {
    e.data[0] = (e.data[0] & ~0x7F00u) | (static_cast<uint32_t>(key & 0x7F) << 8);
    return e;
}

// Stable, in place: the output is a few sorted runs (queued events, then what the effect wrote in order).
void MidiEffect::sortOut() noexcept {
    Event* ev = out_->events;
    const uint32_t n = out_->count;
    for (uint32_t i = 1; i < n; ++i) {
        if (ev[i].frame >= ev[i - 1].frame) continue;
        const Event x = ev[i];
        uint32_t j = i;
        while (j > 0 && ev[j - 1].frame > x.frame) ev[j] = ev[j - 1], --j;
        ev[j] = x;
    }
}

bool MidiEffect::processPorts(const ProcessBlock& b) noexcept {
    if (b.frames == 0 || b.eventInCount != 1 || b.eventOutCount != 1 || !b.eventIn || !b.eventOut ||
        !b.eventOut->events)
        return false;
    block_ = &b;
    out_ = b.eventOut;
    out_->count = 0;
    frames_ = b.frames;
    if (b.sampleRate > 0.0) rate_ = b.sampleRate;
    if (b.transport && std::isfinite(b.transport->tempo)) tempo_ = std::clamp(b.transport->tempo, 1.0, 999.0);
    playing_ = b.transport && b.transport->playing && std::isfinite(b.transport->beat);
    if (playing_) songStart_ = static_cast<int64_t>(std::floor(b.transport->beat * framesPerBeat() + 0.5));
    // What was scheduled for this block goes out first (it was asked for earlier), in the order it was asked.
    uint32_t keep = 0;
    for (uint32_t i = 0; i < queued_; ++i) {
        const Queued& q = queue_[i];
        if (q.at < now_ + frames_) emit(static_cast<uint32_t>(std::max<int64_t>(0, q.at - now_)), q.e);
        else queue_[keep++] = q;
    }
    queued_ = keep;
    const EventInput& in = b.eventIn[0];
    uint32_t from = 0;
    for (uint32_t i = 0; i < in.count && in.events; ++i) {
        const Event& e = in.events[i];
        const uint32_t f = std::min(e.frame, frames_ - 1);
        if (f > from) tick(from, f), from = f;
        NoteMessage m;
        if (e.kind == EventKind::Note && readNote(e, m) && m.type != NoteMessageType::Other) {
            m.frame = f;
            if (m.type == NoteMessageType::On) ++onsIn_;
            note(e, m);
        } else {
            emit(f, e);  // controllers, pitch bend, anything else: as it came
        }
    }
    tick(from, frames_);
    sortOut();
    now_ += frames_;
    if (clock_.tick(frames_)) {
        float shown[64];
        shown[0] = static_cast<float>(onsIn_);
        shown[1] = static_cast<float>(onsOut_);
        shown[2] = static_cast<float>(heldCount());
        const uint32_t n = kCommonDisplay + std::min<uint32_t>(fillDisplay(shown + kCommonDisplay), 64 - kCommonDisplay);
        display_.publish(shown, n);
        onsIn_ = onsOut_ = 0;
    }
    block_ = nullptr;
    out_ = nullptr;
    return true;
}

}  // namespace caw::midifx
