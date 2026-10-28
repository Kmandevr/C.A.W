// MIDI files for note patterns: import a Standard MIDI File (or a MIDI 2.0 Clip File) as pattern text, and export a
// pattern as a Standard MIDI File (.mid) or a MIDI 2.0 Clip File (.midi2).
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

#include "pattern.h"

namespace caw {

constexpr size_t kMaxMidiFileBytes = 16u << 20;  // 16 MB
constexpr int kMaxMidiEvents = 65536;            // channel, meta and sysex events (or UMPs) in one file
constexpr int kMidiExportPpq = 960;              // ticks per quarter note in exported files

struct MidiImportOptions {
    int track = -1;            // Standard MIDI File track (0-based, in file order); -1 = all tracks merged
    int channel = -1;          // MIDI channel 0..15; -1 = all channels merged
    int maxNotes = kMaxPatternNotes;
    std::string name;          // pattern name; empty = the file's track or clip name, else "Imported MIDI"
    bool pitchBend = true;     // a pitch bend sounding at a note's start becomes a microtonal pitch (+-2 semitones)
    bool legatoSlides = true;  // a note overlapping the start of the next one by at most 1/4 step becomes a slide
};

// Reads a Standard MIDI File (format 0 or 1) or a MIDI 2.0 Clip File and returns pattern text (`kind: pattern`).
// On failure returns "" and sets `error`. Never throws except std::bad_alloc.
std::string patternFromMidi(const uint8_t* data, size_t size, const MidiImportOptions& options, std::string& error);

// A pattern as a format 1 Standard MIDI File: 960 ticks per quarter, a tempo/meter track and a note track.
std::vector<uint8_t> patternToSmf(const Pattern& pattern, double bpm, int beatsPerBar);

// A pattern as a MIDI 2.0 Clip File (M2-116-U): UMP MIDI 2.0 notes on group 0, channel 1.
std::vector<uint8_t> patternToMidiClip(const Pattern& pattern, double bpm, int beatsPerBar);

}  // namespace caw
