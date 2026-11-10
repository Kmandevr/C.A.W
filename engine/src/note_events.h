// A native instrument's notes on the host side: the notes it holds and a bounded event list per block.
#pragma once

#include <array>
#include <atomic>
#include <cstdint>

#include "caw/instrument.hpp"
#include "pattern.h"

namespace caw {

// Audio thread only (except overflow(), which any thread may read). Fixed storage: nothing here
// allocates. The Engine turns a track's pattern notes and note previews into calls here; the
// instrument's ComponentChain passes events() to the component and clears them after each block.
class NoteEvents {
public:
    static constexpr uint32_t kCapacity = 2048;  // events per block; more are dropped and counted
    static constexpr uint32_t kMaxHeld = 128;    // notes held at once; a new one past it ends the oldest

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

    // A new note at `frame`; the held note it replaces (same pattern note, or same preview id) ends first.
    Held& on(uint32_t frame, Source source, uint32_t note, uint16_t sub, int32_t preview, double pitch, double vel) noexcept {
        if (Held* same = source == Source::Preview ? findPreview(preview) : findPattern(note, sub)) off(frame, *same);
        Held* pick = nullptr;
        for (Held& h : held_)
            if (!h.active) { pick = &h; break; }
        if (!pick) {  // full: the oldest ends
            for (Held& h : held_)
                if (!pick || h.order < pick->order) pick = &h;
            off(frame, *pick);
        }
        Held& h = *pick;
        h = Held{};
        h.active = true;
        h.source = source;
        h.note = note;
        h.sub = sub;
        h.preview = preview;
        h.id = nextId();
        h.key = notes::keyOf(pitch);
        h.order = ++order_;
        h.vel = vel;
        h.pitch = h.target = h.sentPitch = pitch;
        push(notes::noteOn(frame, h.id, pitch, vel));
        return h;
    }
    void off(uint32_t frame, Held& h) noexcept {
        if (!h.active) return;
        push(notes::noteOff(frame, h.id, h.key));
        h.active = false;
    }
    void pitch(uint32_t frame, Held& h, double pitch) noexcept {
        if (!h.active || pitch == h.sentPitch) return;
        h.sentPitch = pitch;
        push(notes::notePitch(frame, h.id, h.key, pitch));
    }
    void pressure(uint32_t frame, Held& h, double value) noexcept {
        if (!h.active || value == h.sentPress) return;
        h.sentPress = value;
        push(notes::notePressure(frame, h.id, h.key, value));
    }
    void timbre(uint32_t frame, Held& h, double value) noexcept {
        if (!h.active || value == h.sentTimbre) return;
        h.sentTimbre = value;
        push(notes::noteTimbre(frame, h.id, h.key, value));
    }
    Held* findPattern(uint32_t note, uint16_t sub) noexcept {
        for (Held& h : held_)
            if (h.active && h.source == Source::Pattern && h.note == note && h.sub == sub) return &h;
        return nullptr;
    }
    Held* findPreview(int32_t preview) noexcept {
        for (Held& h : held_)
            if (h.active && h.source == Source::Preview && h.preview == preview) return &h;
        return nullptr;
    }
    // Ends the pattern's notes (and orphans) at `frame`; previews too unless keepPreviews.
    void releaseAll(uint32_t frame, bool keepPreviews) noexcept {
        for (Held& h : held_)
            if (h.active && !(keepPreviews && h.source == Source::Preview)) off(frame, h);
    }
    void releasePreviews(uint32_t frame) noexcept {
        for (Held& h : held_)
            if (h.active && h.source == Source::Preview) off(frame, h);
    }
    // Forgets every held note without telling the instrument (it was just reset, so it holds none).
    void forget(bool keepPreviews) noexcept {
        for (Held& h : held_)
            if (!(keepPreviews && h.source == Source::Preview)) h.active = false;
    }
    bool holdsPreview() const noexcept {
        for (const Held& h : held_)
            if (h.active && h.source == Source::Preview) return true;
        return false;
    }
    bool holdsAny() const noexcept {
        for (const Held& h : held_)
            if (h.active) return true;
        return false;
    }
    // A replaced instrument's held notes start again here, at frame 0 (a rebuild or a new instrument
    // keeps a sustained note sounding, with a new attack). The ids stay the same.
    void takeOver(const NoteEvents& from) noexcept {
        held_ = from.held_;
        order_ = from.order_;
        nextId_ = from.nextId_;
        for (Held& h : held_)
            if (h.active) {
                h.key = notes::keyOf(h.sentPitch);
                push(notes::noteOn(0, h.id, h.sentPitch, h.vel));
            }
    }

    std::array<Held, kMaxHeld>& held() noexcept { return held_; }
    bool push(const Event& e) noexcept {
        if (count_ >= kCapacity) {
            overflow_.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
        if (count_ > 0 && e.frame < events_[count_ - 1].frame) unsorted_ = true;
        events_[count_++] = e;
        return true;
    }
    // Puts the block's events in frame order (stable), as the component interface requires.
    void sort() noexcept {
        if (!unsorted_) return;
        for (uint32_t i = 1; i < count_; ++i) {
            const Event e = events_[i];
            uint32_t j = i;
            for (; j > 0 && events_[j - 1].frame > e.frame; --j) events_[j] = events_[j - 1];
            events_[j] = e;
        }
        unsorted_ = false;
    }
    const Event* events() const noexcept { return events_.data(); }
    uint32_t count() const noexcept { return count_; }
    void clearEvents() noexcept {
        count_ = 0;
        unsorted_ = false;
    }
    // Events dropped because a block had more than kCapacity (never expected in practice).
    uint32_t overflow() const noexcept { return overflow_.load(std::memory_order_relaxed); }

private:
    uint32_t nextId() noexcept {
        if (++nextId_ == 0) nextId_ = 1;  // 0 means "no note"
        return nextId_;
    }
    std::array<Event, kCapacity> events_{};
    uint32_t count_ = 0;
    bool unsorted_ = false;
    std::array<Held, kMaxHeld> held_{};
    uint64_t order_ = 0;
    uint32_t nextId_ = 0;
    std::atomic<uint32_t> overflow_{0};
};

}  // namespace caw
