// MIDI files for note patterns: import a Standard MIDI File (or a MIDI 2.0 Clip File) as pattern text, and export a
// pattern as a Standard MIDI File (.mid) or a MIDI 2.0 Clip File (.midi2).
#pragma once

#include <cstddef>
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

#include "pattern.h"
#include "tempo_map.h"

namespace caw {

constexpr size_t kMaxMidiFileBytes = 16u << 20;  // 16 MB
constexpr int kMaxMidiEvents = 65536;            // channel, meta and sysex events (or UMPs) in one file
constexpr int kMidiExportPpq = 960;              // ticks per quarter note in exported files

struct MidiImportOptions {
    int track = -1;            // Standard MIDI File track (0-based, in file order); -1 = all tracks merged
    int channel = -1;          // MIDI channel 0..15; -1 = all channels merged
    int maxNotes = std::numeric_limits<int>::max();
    std::string name;          // pattern name; empty = the file's track or clip name, else "Imported MIDI"
    bool pitchBend = true;     // a pitch bend sounding at a note's start becomes a microtonal pitch (+-2 semitones)
    bool legatoSlides = true;  // a note overlapping the start of the next one by at most 1/4 step becomes a slide
};

// A MIDI file's tempo and meter (1.0.3): its tempo meta events (Set Tempo in a clip file) as a stepped tempo map
// (120 BPM until the first; BPM 1..999) and its time signatures (4/4 until the first; changes off a bar line are
// left out), in quarter-note beats from the file's start.
struct MidiSongMeta {
    std::vector<TempoPointSpec> tempo{{0.0, 120.0, false}};
    std::vector<TimeSigSpec> sigs{{0, 0.0, 4, 4}};
};

// Reads a Standard MIDI File (format 0 or 1) or a MIDI 2.0 Clip File and returns pattern text (`kind: pattern`).
// On failure returns "" and sets `error`. Never throws except std::bad_alloc. `song` (optional) gets the file's
// tempo map and signatures (from every track, whatever options.track picks); more than kMaxTempoPoints tempo
// changes or kMaxTimeSigs signatures are an error.
std::string patternFromMidi(const uint8_t* data, size_t size, const MidiImportOptions& options, std::string& error,
                            MidiSongMeta* song = nullptr);

// A pattern as a format 1 Standard MIDI File: 960 ticks per quarter, a tempo/meter track and a note track.
std::vector<uint8_t> patternToSmf(const Pattern& pattern, double bpm, int beatsPerBar);

// A pattern as a MIDI 2.0 Clip File (M2-116-U): UMP MIDI 2.0 notes on group 0, channel 1.
std::vector<uint8_t> patternToMidiClip(const Pattern& pattern, double bpm, int beatsPerBar);

// The same with a tempo map and signatures (checked as checkTempoPoints and checkTimeSigs leave them): each tempo
// point and signature becomes a meta event at its tick. MIDI files have no tempo ramps, so a ramp is written as a
// tempo event every 1/16 note (at most 1024 a ramp), each holding the tempo that keeps that stretch's exact length,
// and a Standard MIDI File's tempo holds 0xFFFFFF us a quarter at most (about 3.6 BPM). The pattern's length in bars
// is taken at the first signature's beats per bar (1..16).
std::vector<uint8_t> patternToSmf(const Pattern& pattern, const MidiSongMeta& song);
std::vector<uint8_t> patternToMidiClip(const Pattern& pattern, const MidiSongMeta& song);

}  // namespace caw
