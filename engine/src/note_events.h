// A native instrument's notes on the host side: the notes it holds and a bounded event list per block.
#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <vector>

#include "caw/instrument.hpp"
#include "pattern.h"

namespace caw {

// Audio thread only (except overflow(), which any thread may read). The storage is set aside when the
// instrument's chain is built (the constructor allocates, on the control thread); nothing after that does.
// The Engine turns a track's pattern notes and note previews into calls here; the instrument's
// ComponentChain passes events() to the component and clears them after each block.
//
// No practical polyphony cap (owner, 2026-11-10: a program sets its own polyphony): 1,024 notes held at
// once on one track and 4,096 events a block, enough for every held note to end and start again in one block
// with room to spare, in 360 KB per instrument track (4,096 notes and 16,384 events took 1.5 MB, about 94 MB at
// 64 tracks; second audio review, 2026-11-10). The held notes are kept packed, so the per-block work follows
// the notes actually held, not the capacity. Room for every held note's off is kept back from note-ons and
// per-note motion, so a full block can drop a pitch or pressure update but never an off (no stuck note).
class NoteEvents {
public:
    static constexpr uint32_t kCapacity = 4096;  // events per block; more are dropped and counted
    static constexpr uint32_t kMaxHeld = 1024;   // notes held at once; a new one past it ends the oldest
    static_assert(kCapacity >= 3 * kMaxHeld, "room for every held note's off, and as many ons again, in one block");

    enum class Source : uint8_t { Pattern, Orphan, Preview };
    struct Held {
        bool active = false;
        Source source = Source::Pattern;
        uint32_t note = 0;     // Pattern: the note's index in the pattern
        uint16_t sub = 0;      // Pattern: its ratchet repeat
        int32_t preview = -1;  // Preview: the caller's id
        uint32_t id = 0;       // the host note id the instrument sees
        uint8_t key = 60;      // the key its on was sent with (its off and per-note messages use it)
        uint64_t order = 0;    // note-on order
        double vel = 1;
        int64_t offAt = -1;    // Orphan: the sample in the layer pass where it ends
        // Pitch motion, sent at control rate by the Engine: a glide (a slide, a preview's new pitch)
        // and the note's expression (bend and vibrato, pressure, timbre).
        double pitch = 60;     // the pitch without expression
        double target = 60, glideStep = 0;
        int glideLeft = 0;
        const NoteExpression* ex = nullptr;  // the pattern's expression; null after the pattern is replaced
        double exLen = 1;      // the note's length in samples, for the curves' 0..1 time
        int64_t since = 0;     // samples since the note (or its expression) started
        uint32_t motionFrom = 0;  // the frame of this block its motion starts from (its on's frame)
        int motionWait = 0;       // frames from there to its next control point (the grid runs on across blocks)
        double sentPitch = 60, sentPress = 1, sentTimbre = 0;  // what the instrument last heard
    };

    NoteEvents() : events_(kCapacity), scratch_(kCapacity), held_(kMaxHeld) {}
    NoteEvents(const NoteEvents&) = delete;
    NoteEvents& operator=(const NoteEvents&) = delete;
    // What one costs in memory (for the Engine's project-state budget).
    static constexpr size_t kBytes = 2 * kCapacity * sizeof(Event) + kMaxHeld * sizeof(Held);

    // A new note at `frame`; the held note it replaces (same pattern note, or same preview id) ends first.
    Held& on(uint32_t frame, Source source, uint32_t note, uint16_t sub, int32_t preview, double pitch, double vel) noexcept {
        if (Held* same = source == Source::Preview ? findPreview(preview) : findPattern(note, sub)) off(frame, *same);
        if (used_ == kMaxHeld) compact();
        Held* pick = nullptr;
        if (used_ < kMaxHeld) {
            pick = &held_[used_++];
        } else {  // full: the oldest ends
            for (uint32_t i = 0; i < used_; ++i)
                if (!pick || held_[i].order < pick->order) pick = &held_[i];
            off(frame, *pick);
        }
        Held& h = *pick;
        h = Held{};
        h.active = true;
        ++active_;
        h.source = source;
        h.note = note;
        h.sub = sub;
        h.preview = preview;
        h.id = nextId();
        h.key = notes::keyOf(pitch);
        h.order = ++order_;
        h.vel = vel;
        h.pitch = h.target = h.sentPitch = pitch;
        // Room stays for every held note's off, this one's too. An on with no room is not held at all (the
        // instrument never heard it), so its slot keeps no off reserved and nothing can stick.
        if (!push(notes::noteOn(frame, h.id, pitch, vel))) {
            h.active = false;
            --active_;
        }
        return h;
    }
    void off(uint32_t frame, Held& h) noexcept {
        if (!h.active) return;
        h.active = false;
        --active_;
        push(notes::noteOff(frame, h.id, h.key), true);  // an off always has room
    }
    void pitch(uint32_t frame, Held& h, double pitch) noexcept {
        if (!h.active || pitch == h.sentPitch) return;
        if (push(notes::notePitch(frame, h.id, h.key, pitch))) h.sentPitch = pitch;
    }
    void pressure(uint32_t frame, Held& h, double value) noexcept {
        if (!h.active || value == h.sentPress) return;
        if (push(notes::notePressure(frame, h.id, h.key, value))) h.sentPress = value;
    }
    void timbre(uint32_t frame, Held& h, double value) noexcept {
        if (!h.active || value == h.sentTimbre) return;
        if (push(notes::noteTimbre(frame, h.id, h.key, value))) h.sentTimbre = value;
    }
    Held* findPattern(uint32_t note, uint16_t sub) noexcept {
        for (Held& h : held())
            if (h.active && h.source == Source::Pattern && h.note == note && h.sub == sub) return &h;
        return nullptr;
    }
    Held* findPreview(int32_t preview) noexcept {
        for (Held& h : held())
            if (h.active && h.source == Source::Preview && h.preview == preview) return &h;
        return nullptr;
    }
    // Ends the pattern's notes (and orphans) at `frame`; previews too unless keepPreviews.
    void releaseAll(uint32_t frame, bool keepPreviews) noexcept {
        for (Held& h : held())
            if (h.active && !(keepPreviews && h.source == Source::Preview)) off(frame, h);
    }
    void releasePreviews(uint32_t frame) noexcept {
        for (Held& h : held())
            if (h.active && h.source == Source::Preview) off(frame, h);
    }
    // Forgets every held note without telling the instrument (it was just reset, so it holds none).
    void forget(bool keepPreviews) noexcept {
        for (Held& h : held())
            if (h.active && !(keepPreviews && h.source == Source::Preview)) {
                h.active = false;
                --active_;
            }
        compact();
    }
    bool holdsPreview() const noexcept {
        for (const Held& h : held())
            if (h.active && h.source == Source::Preview) return true;
        return false;
    }
    bool holdsAny() const noexcept { return active_ > 0; }
    // A replaced instrument's held notes start again here, at frame 0 (a rebuild or a new instrument
    // keeps a sustained note sounding, with a new attack). The ids stay the same.
    void takeOver(const NoteEvents& from) noexcept {
        used_ = active_ = 0;
        for (const Held& f : from.held())
            if (f.active) {
                Held& h = held_[used_++];
                h = f;
                h.key = notes::keyOf(h.sentPitch);
                ++active_;
            }
        order_ = from.order_;
        nextId_ = from.nextId_;
        for (const Held& h : held()) push(notes::noteOn(0, h.id, h.sentPitch, h.vel));
    }

    // The held notes (the ones still active have `active` set; ended ones are packed away after each block).
    struct Span {
        Held* first;
        Held* last;
        Held* begin() const noexcept { return first; }
        Held* end() const noexcept { return last; }
    };
    struct ConstSpan {
        const Held* first;
        const Held* last;
        const Held* begin() const noexcept { return first; }
        const Held* end() const noexcept { return last; }
    };
    Span held() noexcept { return {held_.data(), held_.data() + used_}; }
    ConstSpan held() const noexcept { return {held_.data(), held_.data() + used_}; }
    uint32_t activeCount() const noexcept { return active_; }

    // Adds an event: an off may use the room kept back for the held notes' offs; anything else leaves it.
    bool push(const Event& e, bool isOff = false) noexcept {
        const uint64_t keep = isOff ? 0 : static_cast<uint64_t>(active_);
        if (static_cast<uint64_t>(count_) + 1 + keep > kCapacity) {
            overflow_.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        if (count_ > 0 && e.frame < events_[count_ - 1].frame) unsorted_ = true;
        events_[count_++] = e;
        return true;
    }
    // Puts the block's events in frame order (stable), as the component interface requires: a natural
    // merge sort of the runs they arrive in (the pattern's notes, then each note's motion), O(n log runs).
    void sort() noexcept {
        if (!unsorted_) return;
        Event* src = events_.data();
        Event* dst = scratch_.data();
        const uint32_t n = count_;
        for (;;) {
            uint32_t runs = 0;
            for (uint32_t i = 0; i < n; ++runs) {
                uint32_t mid = i + 1;
                while (mid < n && src[mid - 1].frame <= src[mid].frame) ++mid;
                uint32_t end = mid;
                if (end < n) {
                    ++end;
                    while (end < n && src[end - 1].frame <= src[end].frame) ++end;
                }
                uint32_t a = i, b = mid, o = i;
                while (a < mid && b < end) dst[o++] = src[b].frame < src[a].frame ? src[b++] : src[a++];
                while (a < mid) dst[o++] = src[a++];
                while (b < end) dst[o++] = src[b++];
                i = end;
            }
            std::swap(src, dst);
            if (runs <= 1) break;
        }
        if (src != events_.data())
            for (uint32_t i = 0; i < n; ++i) events_[i] = src[i];
        unsorted_ = false;
    }
    const Event* events() const noexcept { return events_.data(); }
    uint32_t count() const noexcept { return count_; }
    // After a block: its events are gone and the ended notes are packed away.
    void clearEvents() noexcept {
        count_ = 0;
        unsorted_ = false;
        compact();
    }
    // Events dropped because a block had more than kCapacity (never expected in practice).
    uint32_t overflow() const noexcept { return overflow_.load(std::memory_order_relaxed); }

private:
    uint32_t nextId() noexcept {
        if (++nextId_ == 0) nextId_ = 1;  // 0 means "no note"
        return nextId_;
    }
    void compact() noexcept {
        uint32_t keep = 0;
        for (uint32_t i = 0; i < used_; ++i)
            if (held_[i].active) {
                if (keep != i) held_[keep] = held_[i];
                ++keep;
            }
        used_ = keep;
    }
    std::vector<Event> events_, scratch_;
    uint32_t count_ = 0;
    bool unsorted_ = false;
    std::vector<Held> held_;
    uint32_t used_ = 0, active_ = 0;  // held_ entries in use (packed after each block); of those, active
    uint64_t order_ = 0;
    uint32_t nextId_ = 0;
    std::atomic<uint32_t> overflow_{0};
};

}  // namespace caw
