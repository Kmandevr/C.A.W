// The platform MIDI-out sender's portable part (caw.h API 48): the schedule, the channels used and the attach.
#include "midi_sender.h"

#include <algorithm>
#include <utility>

#include "engine.h"

namespace caw {

bool MidiSendSchedule::push(const MidiOutMessage& m) noexcept {
    if (size_ >= heap_.size()) return false;
    size_t i = size_++;
    heap_[i] = Item{m, seq_++};
    while (i > 0) {
        const size_t parent = (i - 1) / 2;
        if (!before(heap_[i], heap_[parent])) break;
        std::swap(heap_[i], heap_[parent]);
        i = parent;
    }
    return true;
}

bool MidiSendSchedule::popDue(int64_t until, MidiOutMessage& out) noexcept {
    if (!size_ || heap_[0].m.timeNs > until) return false;
    out = heap_[0].m;
    heap_[0] = heap_[--size_];
    for (size_t i = 0;;) {
        const size_t l = 2 * i + 1, r = l + 1;
        size_t least = i;
        if (l < size_ && before(heap_[l], heap_[least])) least = l;
        if (r < size_ && before(heap_[r], heap_[least])) least = r;
        if (least == i) break;
        std::swap(heap_[i], heap_[least]);
        i = least;
    }
    return true;
}

int MidiChannelsUsed::takeNotesOff(int port, int64_t timeNs, MidiOutMessage* out) noexcept {
    if (port < 0 || port >= kMidiOutPorts || !out) return 0;
    int n = 0;
    for (int ch = 0; ch < 16; ++ch) {
        if (!(mask_[port] & (1u << ch))) continue;
        MidiOutMessage& m = out[n++];
        m = MidiOutMessage{};
        m.timeNs = timeNs;
        m.port = static_cast<uint8_t>(port);
        m.size = 3;
        m.data[0] = static_cast<uint8_t>(0xB0 | ch);
        m.data[1] = 123;
        m.data[2] = 0;
    }
    mask_[port] = 0;
    return n;
}

int64_t qpcTicksToNs(int64_t ticks, int64_t freq) noexcept {
    if (freq <= 0) return 0;
    return ticks / freq * 1'000'000'000 + ticks % freq * 1'000'000'000 / freq;
}

int64_t nsToQpcTicks(int64_t ns, int64_t freq) noexcept {
    if (freq <= 0 || ns <= 0) return 0;
    // Whole seconds exactly, then the remainder rounded up; the remainder's product stays under 1e9 * freq, which fits
    // for any counter below 9 GHz.
    int64_t t = ns / 1'000'000'000 * freq + (ns % 1'000'000'000 * freq + 999'999'999) / 1'000'000'000;
    // The forward formula truncates too: step to the first tick at or after ns (at most one step either way).
    while (t > 0 && qpcTicksToNs(t - 1, freq) >= ns) --t;
    while (qpcTicksToNs(t, freq) < ns) ++t;
    return t;
}

MidiSendWait midiSendWait(int64_t nowNs, int64_t nextNs, int64_t pollNs) noexcept {
    if (nextNs != std::numeric_limits<int64_t>::max() && nextNs - nowNs <= pollNs) return {std::max(nowNs, nextNs), true};
    return {nowNs + pollNs, false};
}

bool MidiSender::attach(Engine* e) noexcept {
    if (!e) return false;
    std::lock_guard<std::mutex> g(lock_);
    if (engine_ == e) return true;
    if (engine_) return false;
    engine_ = e;
    // Notes-offs a detach left unsent go with the new attach's first pump; nothing else is held.
    e->setMidiOutActive(true);
    return true;
}

void MidiSender::detach() noexcept {
    std::lock_guard<std::mutex> g(lock_);
    if (!engine_) return;
    engine_->setMidiOutActive(false);
    engine_ = nullptr;
    schedule_.clear();
    MidiOutMessage off[16];
    for (int p = 0; p < kMidiOutPorts; ++p) {
        const int n = used_.takeNotesOff(p, 0, off);  // time 0: due at once
        for (int k = 0; k < n; ++k) schedule_.push(off[k]);
    }
}

void MidiSender::detachIf(Engine* e) noexcept {
    {
        std::lock_guard<std::mutex> g(lock_);
        if (!e || engine_ != e) return;
    }
    detach();
}

bool MidiSender::attached() const noexcept {
    std::lock_guard<std::mutex> g(lock_);
    return engine_ != nullptr;
}

bool MidiSender::attachedTo(const Engine* e) const noexcept {
    std::lock_guard<std::mutex> g(lock_);
    return e && engine_ == e;
}

int64_t MidiSender::pump(int64_t nowNs, int64_t leadNs, SendFn send, void* ctx, int maxSend) noexcept {
    std::lock_guard<std::mutex> g(lock_);
    if (engine_) {
        MidiOutMessage buf[64];
        while (schedule_.size() < schedule_.capacity()) {
            const int32_t n = engine_->midiOutDrain(
                buf, static_cast<int32_t>(std::min<size_t>(64, schedule_.capacity() - schedule_.size())));
            if (n <= 0) break;
            for (int32_t k = 0; k < n; ++k)
                if (!schedule_.push(buf[k])) ++dropped_;
        }
    }
    MidiOutMessage m;
    for (int sent = 0; sent < maxSend && schedule_.popDue(nowNs + leadNs, m); ++sent) {
        if (engine_) used_.note(m);  // a detach's own CC 123s are not a channel used
        if (send) send(ctx, m);
    }
    if (!engine_ && schedule_.empty()) {
        return kStopped;
    }
    return schedule_.nextTime();
}

int MidiSender::takeNotesOff(int port, int64_t nowNs, MidiOutMessage* out) noexcept {
    std::lock_guard<std::mutex> g(lock_);
    return used_.takeNotesOff(port, nowNs, out);
}

uint64_t MidiSender::dropped() const noexcept {
    std::lock_guard<std::mutex> g(lock_);
    return dropped_;
}

MidiSender& midiSender() {
    static MidiSender* s = new MidiSender();  // never destroyed: a sender thread may outlive static destruction
    return *s;
}

}  // namespace caw
