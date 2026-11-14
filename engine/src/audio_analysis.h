// Offline analysis of audio assets for the app: onsets, tempo detection and transients for Slice to MIDI (API 32).
#pragma once

#include <cstdint>
#include <string>
#include <vector>

namespace caw {

struct AudioAsset;

constexpr double kMaxAnalysisSeconds = 600;  // the longest range one call reads
constexpr int kMaxSlices = 256;

struct TempoOptions {
    double minBpm = 70, maxBpm = 180;
    double startSeconds = 0, endSeconds = 0;  // 0 end: the file's end (at most kMaxAnalysisSeconds are read)
};
struct TempoCandidate {
    double bpm = 0, score = 0;
};
struct TempoResult {
    bool sure = false;       // false: too few onsets or a weak beat (the app asks the user)
    double bpm = 0;          // the best estimate, even when not sure (0 when there is nothing)
    double confidence = 0;   // 0..1
    int onsets = 0;
    std::vector<TempoCandidate> candidates;  // the best few, best first
};

struct SliceOptions {
    double sensitivity = 0.5;  // 0..1: higher finds more
    double startSeconds = 0, endSeconds = 0;
    double minGapSeconds = 0.05;
    int maxSlices = 64;
};
struct Slice {
    double seconds = 0;   // from the file's start (its own speed)
    int64_t frame = 0;    // at the file's own rate
    double strength = 0;  // 0..1
};

// Parses an options JSON (NULL or empty: the defaults) with its limits: at most 4096 bytes, an object, each key in
// range. False with an error that names the key.
bool parseTempoOptions(const char* json, TempoOptions& out, std::string& error);
bool parseSliceOptions(const char* json, SliceOptions& out, std::string& error);

// Onset-based tempo: a spectral-flux novelty curve (log-compressed magnitudes, 5.3 ms hops at 48 kHz), its
// autocorrelation scored at each candidate tempo with its first eight multiples, with a mild preference for tempos
// near 120 BPM between octaves, then refined on a 0.01 BPM grid. Any thread but the audio thread (allocates).
TempoResult detectTempo(const AudioAsset& asset, const TempoOptions& options);

// Transients: peaks of a finer spectral-flux curve (2.7 ms hops) above a moving median plus a threshold set by the
// sensitivity, at least minGapSeconds apart, each moved to the start of its attack in the samples. In time order; the
// strongest maxSlices kept; one within 5 ms of the range's start is left out (the range's start is a cut already).
std::vector<Slice> detectSlices(const AudioAsset& asset, const SliceOptions& options);

}  // namespace caw
