// C.A.W. Library: music helpers (scales, quantize, chords, arpeggios, Euclidean rhythms, seeded choices); header-only.
#pragma once

#include <cmath>
#include <cstdint>

#include "../detmath.hpp"

namespace caw::lib {

// What a step sequencer or a generative pattern needs to stay in key, ported from the .caw music built-ins
// (`scale`, `quantize`, `chord`, `arp`, `euclid`, `rand`, `randi`, `chance`) with the same results: the .caw
// path's tests render both and compare (engine/tests/library_kernels_test.cpp). Notes are MIDI note numbers
// as doubles (60 = C4, 69 = A4; lib::noteHz turns one into Hz). Everything is a pure function: no state, no
// allocation, safe anywhere, the audio thread included. NaN and infinities read as 0, and large values are
// held to a range before any cast to an integer, so every device makes the same choice.

enum class Scale : int {
    Major, Minor, Dorian, Phrygian, Lydian, Mixolydian, Locrian,
    HarmonicMinor, MelodicMinor, Pentatonic, MinorPentatonic, Blues, Chromatic, WholeTone,
};
inline constexpr int kScaleCount = 14;

enum class Chord : int { Maj, Min, Dim, Aug, Sus2, Sus4, Maj7, Min7, Dom7, Maj9, Min9, Power };
inline constexpr int kChordCount = 12;

enum class ArpMode : int { Up, Down, UpDown, Random };

// A scale's notes as semitones above its root, in order.
struct ScaleShape {
    const char* name;  // as the .caw scale.* constants: "major", "minor", "harmonic", "minorpenta"...
    int count;
    int steps[12];
};
inline constexpr ScaleShape kScales[kScaleCount] = {
    {"major", 7, {0, 2, 4, 5, 7, 9, 11}},     {"minor", 7, {0, 2, 3, 5, 7, 8, 10}},
    {"dorian", 7, {0, 2, 3, 5, 7, 9, 10}},    {"phrygian", 7, {0, 1, 3, 5, 7, 8, 10}},
    {"lydian", 7, {0, 2, 4, 6, 7, 9, 11}},    {"mixolydian", 7, {0, 2, 4, 5, 7, 9, 10}},
    {"locrian", 7, {0, 1, 3, 5, 6, 8, 10}},   {"harmonic", 7, {0, 2, 3, 5, 7, 8, 11}},
    {"melodic", 7, {0, 2, 3, 5, 7, 9, 11}},   {"pentatonic", 5, {0, 2, 4, 7, 9}},
    {"minorpenta", 5, {0, 3, 5, 7, 10}},      {"blues", 6, {0, 3, 5, 6, 7, 10}},
    {"chromatic", 12, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}}, {"whole", 6, {0, 2, 4, 6, 8, 10}},
};

// A chord's tones as semitones above its root.
struct ChordShape {
    const char* name;  // as the .caw chord.* constants
    int count;
    int tones[5];
};
inline constexpr ChordShape kChords[kChordCount] = {
    {"maj", 3, {0, 4, 7}},      {"min", 3, {0, 3, 7}},          {"dim", 3, {0, 3, 6}},          {"aug", 3, {0, 4, 8}},
    {"sus2", 3, {0, 2, 7}},     {"sus4", 3, {0, 5, 7}},         {"maj7", 4, {0, 4, 7, 11}},     {"min7", 4, {0, 3, 7, 10}},
    {"dom7", 4, {0, 4, 7, 10}}, {"maj9", 5, {0, 4, 7, 11, 14}}, {"min9", 5, {0, 3, 7, 10, 14}}, {"power", 2, {0, 7}},
};

namespace music_detail {
inline double clampTo(double v, double lo, double hi) noexcept { return v < lo ? lo : (v > hi ? hi : v); }
inline long floorDiv(long a, long b) noexcept { return a >= 0 ? a / b : -((-a + b - 1) / b); }
inline const ScaleShape& scaleOf(Scale s) noexcept {
    const int i = static_cast<int>(s);
    return kScales[i >= 0 && i < kScaleCount ? i : 1];  // out of range: minor, as the .caw scale() does
}
inline const ChordShape& chordOf(Chord c) noexcept {
    const int i = static_cast<int>(c);
    return kChords[i >= 0 && i < kChordCount ? i : 0];
}
// A root note held to 0..1000 and rounded down (the .caw functions' root argument).
inline double rootOf(double root) noexcept {
    const double r = finiteOr0(root);
    return r < 0.0 ? 0.0 : std::floor(r < 1000.0 ? r : 1000.0);
}
inline int chordTone(const ChordShape& ch, long index) noexcept {
    const long oct = floorDiv(index, ch.count);
    return static_cast<int>(12 * oct + ch.tones[index - oct * ch.count]);
}
inline double unit(uint32_t h) noexcept { return static_cast<double>(h) * (1.0 / 4294967296.0); }
}  // namespace music_detail

// The MIDI note of a key's root in an octave (C4 = 60): pitchClass 0 = C .. 11 = B. keyRoot(9) = A4 = 69, the
// root the .caw functions use for the default key (A minor).
inline double keyRoot(int pitchClass, int octave = 4) noexcept {
    const int pc = ((pitchClass % 12) + 12) % 12;
    return 12.0 * (octave + 1) + pc;
}

// The note of a scale degree: 0 is the root, 1 the next note up; degrees past the end climb into the next
// octave and negative degrees go down (degree -1 of A minor from A4 is G4). Degrees are held to -1000..1000.
inline double scaleNote(double degree, Scale scale, double root) noexcept {
    const ScaleShape& sc = music_detail::scaleOf(scale);
    const long d = static_cast<long>(std::floor(music_detail::clampTo(finiteOr0(degree), -1000.0, 1000.0)));
    const long oct = music_detail::floorDiv(d, sc.count);
    return music_detail::rootOf(root) + 12.0 * static_cast<double>(oct) + sc.steps[d - oct * sc.count];
}

// The scale's note nearest to `note` (any note of the key works as `root`); a tie goes to the lower note.
inline double quantizeNote(double note, Scale scale, double root) noexcept {
    const ScaleShape& sc = music_detail::scaleOf(scale);
    const double n = music_detail::clampTo(finiteOr0(note), -1000.0, 1000.0);
    const double r = music_detail::rootOf(root);
    double best = n, bestDist = 1e9;
    const long base = music_detail::floorDiv(static_cast<long>(std::floor(n - r)), 12);
    for (long o = base - 1; o <= base + 1; ++o)
        for (int k = 0; k < sc.count; ++k) {
            const double cand = r + 12.0 * static_cast<double>(o) + sc.steps[k];
            const double dist = std::fabs(cand - n);
            if (dist < bestDist || (dist == bestDist && cand < best)) {
                best = cand;
                bestDist = dist;
            }
        }
    return best;
}

// The index-th note of a chord: 0 is the root; indexes past the end climb octaves (index 3 of a major triad
// is the root an octave up), negative ones go down. Indexes are held to -1000..1000.
inline double chordNote(Chord chord, double index, double root) noexcept {
    const long i = static_cast<long>(std::floor(music_detail::clampTo(finiteOr0(index), -1000.0, 1000.0)));
    return music_detail::rootOf(root) + music_detail::chordTone(music_detail::chordOf(chord), i);
}

// The note an arpeggio plays on `step` (0, 1, 2...): through the chord's notes over `octaves` (1..4), going
// up, down, up and down (the top and bottom notes once each turn), or in a seeded random order (the same
// seed and step give the same note on every device; .caw passes the project seed).
inline double arpNote(Chord chord, double step, ArpMode mode, double root, int octaves = 1, uint32_t seed = 0) noexcept {
    const ChordShape& ch = music_detail::chordOf(chord);
    const long s = static_cast<long>(std::floor(music_detail::clampTo(finiteOr0(step), 0.0, 1e9)));
    const long n = static_cast<long>(ch.count) * (octaves < 1 ? 1 : (octaves > 4 ? 4 : octaves));
    long idx;
    switch (mode) {
        case ArpMode::Down: idx = n - 1 - s % n; break;
        case ArpMode::UpDown: {
            const long period = n > 1 ? 2 * n - 2 : 1;
            const long k = s % period;
            idx = k < n ? k : period - k;
            break;
        }
        case ArpMode::Random:
            idx = static_cast<long>(hash32(static_cast<uint32_t>(s) ^ hash32(seed ^ 0x27d4eb2dU)) % static_cast<uint32_t>(n));
            break;
        default: idx = s % n; break;
    }
    return music_detail::rootOf(root) + music_detail::chordTone(ch, idx);
}

// A Euclidean rhythm: true on the steps where `hits` notes spread as evenly as possible over `steps` (1..1024)
// fall, at step `pos` (any whole number; it wraps), shifted by `rotate`. euclid(3, 8) is x..x..x. and
// euclid(5, 16) is x...x..x..x..x.. (the first hit on step 0).
inline bool euclid(double hits, double steps, double pos, double rotate = 0.0) noexcept {
    const long n = static_cast<long>(music_detail::clampTo(std::floor(finiteOr0(steps)), 1.0, 1024.0));
    const long k = static_cast<long>(music_detail::clampTo(std::floor(finiteOr0(hits)), 0.0, static_cast<double>(n)));
    long p = static_cast<long>(std::floor(music_detail::clampTo(finiteOr0(pos) + finiteOr0(rotate), -1e9, 1e9))) % n;
    if (p < 0) p += n;
    return (p * k) % n < k;
}

// Seeded choices for generative patterns, the same for the same x and seed on every device (x is read as a
// 32-bit integer, so pass a step number). randomUnit: 0..1 (as .caw rand); randomIndex: a whole number
// 0..count-1, 0 for count below 1 (randi); chance: true with probability p (chance).
inline double randomUnit(double x, uint32_t seed = 0) noexcept {
    return music_detail::unit(hash32(toUint32(x) ^ hash32(seed ^ 0x5bd1e995U)));
}
inline int randomIndex(double x, double count, uint32_t seed = 0) noexcept {
    const double n = std::floor(finiteOr0(count));
    return n >= 1.0 ? static_cast<int>(std::floor(randomUnit(x, seed) * (n < 2147483647.0 ? n : 2147483647.0))) : 0;
}
inline bool chance(double x, double p, uint32_t seed = 0) noexcept { return randomUnit(x, seed) < p; }

}  // namespace caw::lib
