// Wavetables for the synth: frames of one cycle each, kept as band-limited copies per octave so high notes don't alias.
#pragma once

#include <cstdint>
#include <memory>
#include <vector>

namespace caw {

constexpr int kTableSize = 2048;      // samples in one source frame (Serum and Vital use the same)
constexpr int kTableMaxFrames = 256;
constexpr int kTableLevels = 11;      // level L keeps harmonics 1 .. 1024 >> L

// A read-only wavetable. Level L of each frame holds the frame with every harmonic above 1024 >> L removed, stored at
// levelSize(L) samples (4 per kept harmonic; 2 at level 0) plus one guard sample that repeats the first, for interpolation.
struct Table {
    int frames = 0;
    std::vector<float> data;
    size_t levelOffset[kTableLevels] = {};  // where each level starts in data (all its frames, one after another)

    static int levelSize(int level);
    const float* frame(int level, int f) const {
        return data.data() + levelOffset[level] + static_cast<size_t>(f) * static_cast<size_t>(levelSize(level) + 1);
    }
    // The finest level whose harmonics all stay under half the sample rate for a fundamental of `dt` cycles per sample.
    static int levelFor(double dt);
};

// Builds a table from `frames` cycles of kTableSize samples each (frames 1..kTableMaxFrames), removing DC.
// Deterministic: the same input gives the same bits on every platform. Never call it on the audio thread.
std::shared_ptr<const Table> buildTable(const std::vector<double>& cycles, int frames);

// The built-in shapes, named by the table.* constants (table.sine is 0). Built once, on first use; the engine calls
// warmTables() when it is created so the audio thread never builds them.
const Table* builtinTable(int id);
int builtinTableCount();
const char* const* builtinTableNames();
void warmTables();

}  // namespace caw
