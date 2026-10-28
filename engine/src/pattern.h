// Note patterns (`kind: pattern`): the text format, its parser, and the note events the mixer plays.
#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

namespace caw {

constexpr int kMaxPatternNotes = 4096;
constexpr int kMaxPatternSteps = 4096;  // 64 bars of 16/4; whole bars are checked against the project's meter
constexpr int kMaxRatchet = 8;

// One note. Times are in steps (16ths) from the pattern start and may be fractions (off the grid, triplets).
// Pitch is a MIDI note number kept as a float, MIDI 2.0 style, so fractions are microtones.
struct PatternNote {
    double at = 0, len = 1;
    double pitch = 60;
    double vel = 1;       // 0..1
    double prob = 1;      // chance it plays, decided per repeat from the project seed
    int ratchet = 1;      // equal repeats inside the note
    bool slide = false;   // glides into the note that starts where this one ends
    int slideTo = -1;     // index of that note, or -1
    int slideFrom = -1;   // index of the note sliding into this one, or -1
    int row = 0;          // kit row; kit patterns are not built yet, so always 0
    int extra = -1;       // reserved: index of this note's curves and custom values
    int line = 0;         // where it was written, for messages
};

// A note starting or ending. `sub` counts ratchet repeats.
struct PatternEvent {
    double step = 0;
    uint32_t note = 0;
    uint16_t sub = 0;
    bool on = true;
};

struct Pattern {
    std::string name, summary;
    int lengthSteps = 0;  // set by `length: N`
    int lengthBars = 0;   // set by `length: N bars`; both 0 = the whole bars that cover the notes
    double lastEnd = 0;   // where the last note ends, in steps
    std::vector<PatternNote> notes;    // sorted by start; same start keeps the written order
    std::vector<PatternEvent> events;  // sorted by step, starts before ends at the same step

    // The pattern's length in steps for a meter of `beatsPerBar` beats.
    int steps(int beatsPerBar) const;
};

struct PatternResult {
    std::shared_ptr<const Pattern> pattern;
    std::string error;
    int line = 0, col = 0;
};

PatternResult parsePattern(std::string_view source);

// JSON fields describing a pattern (no braces), for caw_check and the project result.
std::string describePattern(const Pattern& p);

// Whether a note plays on a given repeat of its layer, from its probability and the seed. Same answer every time.
bool notePlays(const PatternNote& n, uint32_t index, int64_t repeat, uint32_t seed);

}  // namespace caw
