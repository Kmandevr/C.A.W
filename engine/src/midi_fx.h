// MIDI effects (1.1.0): event processors a track runs on its notes before its instrument (arpeggiator, chords, scale, note echo, humanize).
#pragma once

#include <cstdint>
#include <memory>
#include <span>
#include <string_view>
#include <vector>

#include "caw/display.hpp"
#include "caw/instrument.hpp"
#include "module_registry.h"

namespace caw {
struct BuiltinPreset;  // presets.h

namespace midifx {

// A track's MIDI effects ("midiComponents" in the project, docs/engine.md "MIDI effects"): at most this many.
inline constexpr uint32_t kMaxPerTrack = 16;

// Whether a descriptor is a MIDI effect: one event input, one event output, no other port.
bool isMidiEffect(const ModuleDescriptor& d) noexcept;

// Registers org.caw.midi.arp, .chords, .scale, .echo and .humanize (registerBuiltinComponents calls it).
void registerMidiEffects(ModuleRegistry& registry);

// Their presets (null for another id).
const std::vector<BuiltinPreset>* presets(std::string_view id);

// The note ids a built-in MIDI effect gives the notes it makes: `base` | a 24-bit counter, so effects in one chain
// (and the Engine's own ids, which count up from 1) never collide. The chain sets it (position p: 0x80000000 +
// p << 24); a loaded MIDI effect picks its own. Control thread, before it runs.
void setNoteIdBase(ModuleProcessor& p, uint32_t base) noexcept;

// What every built-in MIDI effect shares. It sees the block's events (its input) and writes its output events,
// sorted by frame, to the event output. Note messages it does not own pass through, as do other MIDI messages
// (controllers, pitch bend). Its own clock counts the frames since its last reset, so the events it schedules
// later (an echo, a strum, a humanized delay, an arpeggio's gate) land on the same samples whatever the block
// size. Randomness is a hash of the effect's seed and the note's place in the song (while playing) or a running
// count (while stopped): the same from every Play. Nothing allocates after activate.
class MidiEffect : public ModuleProcessor {
public:
    static constexpr uint32_t kOutKeep = 256;  // output room kept for note-offs

    // `queue`: how many events it may schedule for later blocks (sized to what the effect needs: none for Scale,
    // a strum's for Chords, 16 repeats' for Note echo); a quarter of it is kept for note-offs.
    MidiEffect(const ModuleDescriptor& d, uint32_t queue) noexcept : d_(d), queueCap_(queue) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    bool activate(double sampleRate, uint32_t maxFrames) noexcept override;
    void reset() noexcept override;
    bool quiet() const noexcept override { return queued_ == 0 && !busy(); }
    bool usesProcessPorts() const noexcept override { return true; }
    bool processPorts(const ProcessBlock& b) noexcept override;
    uint32_t readDisplay(float* out, uint32_t max) const noexcept override { return display_.read(out, max); }
    void setIdBase(uint32_t base) noexcept { idBase_ = base & 0xFF000000u; }

protected:
    static constexpr uint32_t kCommonDisplay = 3;  // 0 notes in (ons since the last publish), 1 notes out, 2 held

    virtual void clearState() noexcept = 0;
    // Holds notes (an arpeggio's keys): it must keep running even with no input.
    virtual bool busy() const noexcept { return false; }
    // One input note message at m.frame (a decoded note event; e is the raw event).
    virtual void note(const Event& e, const NoteMessage& m) noexcept = 0;
    // Clock-driven work in frames [from, to) of the block, before the input events at `to` (an arpeggio's steps).
    virtual void tick(uint32_t, uint32_t) noexcept {}
    // Floats after the common ones (at most 61); returns how many.
    virtual uint32_t fillDisplay(float*) noexcept { return 0; }
    // How many input notes it holds now (display).
    virtual uint32_t heldCount() const noexcept { return 0; }

    // Parameter k at frame `at` (its default when none is given).
    double param(uint32_t k, uint32_t at) const noexcept;
    int choice(uint32_t k, uint32_t at) const noexcept { return static_cast<int>(param(k, at) + 0.5); }
    bool on(uint32_t k, uint32_t at) const noexcept { return param(k, at) >= 0.5; }
    double rate() const noexcept { return rate_; }
    double tempo() const noexcept { return tempo_; }
    uint32_t frames() const noexcept { return frames_; }
    int64_t now() const noexcept { return now_; }  // the block's first frame on the effect's clock
    bool playing() const noexcept { return playing_; }
    // While playing: the song's sample at frame `at` of the block (its beat at the block's tempo).
    int64_t songSample(uint32_t at) const noexcept { return songStart_ + at; }
    double framesPerBeat() const noexcept { return 60.0 * rate_ / tempo_; }
    // A note id of its own.
    uint32_t newId() noexcept;
    // Writes an event at frame `at` of this block (a note-on is dropped when the output is nearly full).
    void emit(uint32_t at, const Event& e) noexcept;
    // An event at `at` on the clock (now() or later): this block's are written now, later ones queued. False when
    // it was dropped (a full queue refuses note-ons first).
    bool schedule(int64_t at, Event e) noexcept;
    // Removes a queued note-on for `id` (and anything queued after it for that note); true when one was queued.
    bool cancel(uint32_t id) noexcept;
    // A seeded unit value 0..1 for (seed, a, b, salt).
    static double unit(uint32_t seed, uint64_t a, uint64_t b, uint32_t salt) noexcept;
    // A note-on, off or per-note message re-addressed (key, pitch) for output.
    static Event withKey(Event e, uint8_t key) noexcept;
    uint32_t queuedCount() const noexcept { return queued_; }

private:
    struct Queued {
        int64_t at = 0;
        Event e;
    };
    void sortOut() noexcept;
    bool isOff(const Event& e) const noexcept { return ((e.data[0] >> 20) & 0xF) == 0x8; }

    const ModuleDescriptor& d_;
    const ProcessBlock* block_ = nullptr;
    EventOutput* out_ = nullptr;
    double rate_ = 48000.0, tempo_ = 120.0;
    uint32_t frames_ = 0;
    int64_t now_ = 0, songStart_ = 0;
    bool playing_ = false;
    uint32_t idBase_ = 0xF0000000u, idNext_ = 0;
    std::unique_ptr<Queued[]> queue_;
    uint32_t queueCap_ = 0, queued_ = 0;
    uint32_t onsIn_ = 0, onsOut_ = 0;
    DisplayClock clock_;
    DisplayBuffer<64> display_;
};

}  // namespace midifx
}  // namespace caw
