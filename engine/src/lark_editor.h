// Lark's clip editor engine (1.1.0, one voice): an offline analysis of a clip into note objects and a non-destructive TD-PSOLA render of per-note edits; the C API (capi_pitch_clip.cpp) wraps it for the app's workers.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace caw::lark {

// Limits for untrusted input (the C API checks them; analyse() and render() refuse beyond them).
inline constexpr double kMinRate = 8000.0, kMaxRate = 192000.0;
inline constexpr double kMaxSeconds = 1800.0;   // 30 minutes a clip
inline constexpr size_t kMaxNotes = 100000;

struct AnalyseOptions {
    double lowHz = 60.0;    // 50..400
    double highHz = 1000.0; // 200..2000, above lowHz
};

struct Note {
    int64_t start = 0, end = 0;   // frames: [start, end)
    uint32_t firstHop = 0, endHop = 0;
    double pitch = 0.0;           // the centre: the energy-weighted median, MIDI
    double driftCents = 0.0;      // rms of the residual below 2 Hz
    double vibratoRate = 0.0;     // Hz (0: none found)
    double vibratoCents = 0.0;    // depth (peak) of the residual from 3 to 9 Hz
    double transitionInMs = 0.0, transitionOutMs = 0.0;  // while the pitch is over 50 cents off the centre
    double gainDb = -120.0;       // rms
};

struct Analysis {
    double sampleRate = 48000.0;
    int64_t frames = 0;
    uint32_t hopFrames = 256;  // hop k is centred on frame k * hopFrames
    std::vector<float> midi;     // per hop: the pitch (MIDI), 0 when unvoiced
    std::vector<float> voicing;  // per hop: the probability it is voiced, 0..1
    std::vector<float> rmsDb;    // per hop
    std::vector<float> low;      // per hop: the drift (semitones; 0 outside notes)
    std::vector<float> vib;      // per hop: the vibrato (semitones; 0 outside notes)
    std::vector<int32_t> noteOf; // per hop: its note, or -1
    std::vector<Note> notes;
    uint64_t checksum = 0;       // of the audio analysed (render refuses another)
};

// One note's edit; the defaults change nothing.
struct NoteEdit {
    double pitch = 0.0;         // semitones, -24..24
    double drift = 1.0;         // 0 flattens the drift, 1 keeps it (0..1)
    double vibrato = 1.0;       // depth scale, 0..2
    double formant = 0.0;       // semitones, -12..12
    bool formantKeep = true;    // false: the formant follows the pitch
    double timeFrames = 0.0;    // move, frames (at most 10 s either way)
    double stretch = 1.0;       // 0.25..4
    double gainDb = 0.0;        // -60..24
    double transitionMs = 30.0; // the ramps into and out of the note's changes, 0..500
    bool identity() const noexcept {
        return pitch == 0.0 && drift == 1.0 && vibrato == 1.0 && formant == 0.0 && formantKeep && timeFrames == 0.0 &&
               stretch == 1.0 && gainDb == 0.0;
    }
};

uint64_t audioChecksum(const float* left, const float* right, int64_t frames) noexcept;

// Analyses `frames` of left (and right, or null: mono). False with `error` on bad input. Deterministic.
bool analyse(const float* left, const float* right, int64_t frames, double sampleRate, const AnalyseOptions& options,
             Analysis& out, std::string& error);

// Renders the clip with `edits` (one per note, edits.size() == a.notes.size()) into outL (and outR when right is
// given). The output keeps the clip's length; where no edit reaches, it is the input bit for bit. Deterministic.
bool render(const Analysis& a, const float* left, const float* right, int64_t frames, const std::vector<NoteEdit>& edits,
            float* outL, float* outR, std::string& error);

}  // namespace caw::lark
