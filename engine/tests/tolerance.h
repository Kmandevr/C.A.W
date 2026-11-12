// Tolerance tests against reference renders (owner, 2026-11-12): the stored references, the comparators, their limits.
#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace cawtest {

// A stereo render at 48 kHz, planar.
struct Audio {
    std::vector<float> l, r;
    size_t frames() const { return l.size(); }
};
// From an interleaved L, R, L, R ... render.
Audio fromInterleaved(const std::vector<float>& lr);

// How a reference is compared (docs/engine.md, "Reference renders"). Stable: the render nulls against the stored
// waveform. Chaotic: tiny float differences grow (feedback near self-oscillation, free-running phases), so only what
// a listener hears is compared: loudness over time, the spectrum, and the onsets exactly.
enum class Class : uint8_t { Stable = 0, Chaotic = 1 };

namespace tol {
// Stable: the peak of render - reference stays below -120 dBFS. The reference is stored in steps of 2^-21, at most
// 2^-22 (-132.4 dBFS) from the render it was recorded from: a render within -122.4 dBFS of that one always passes.
constexpr double kNullPeakDbfs = -120.0;
// Chaotic: short-term loudness (RMS of 50 ms windows) and the same of the first difference (where clicks and
// brightness show), per channel, within 0.1 dB; the mean power in each 1/3-octave band (25 Hz to 20 kHz) within
// 0.5 dB. Levels more than 60 dB below the reference's loudest window or band (and anything below -120 dBFS)
// count as that floor.
constexpr int kWindowFrames = 2400;
constexpr double kLoudnessDb = 0.1;
constexpr double kBandDb = 0.5;
constexpr double kFloorBelowLoudestDb = 60.0;
constexpr double kAbsoluteFloorDbfs = -120.0;
// An onset: the first frame above -60 dBFS after at least 10 ms at or below -80 dBFS (frame 0 counts as after
// silence). Onset frames must match exactly.
constexpr float kOnsetLevel = 1e-3f;
constexpr float kSilenceLevel = 1e-4f;
constexpr int kSilenceFrames = 480;
}  // namespace tol

// What a chaotic comparison looks at.
struct Features {
    uint32_t frames = 0;
    std::vector<float> loud[2], bright[2];  // dB per 50 ms window
    std::vector<float> bands[2];            // dB per 1/3-octave band
    std::vector<uint32_t> onsets[2];        // frames
};

Features measureFeatures(const Audio& a);
std::vector<uint32_t> onsets(const std::vector<float>& x);
// The peak of |render - reference| over both channels, in dBFS (+inf if not finite; -inf if they are equal).
double nullResidualDbfs(const Audio& reference, const Audio& render);
// Each returns "" when the render is accepted, else why it is not.
std::string compareStable(const Audio& reference, const Audio& render);
std::string compareChaotic(const Features& reference, const Features& render);
// Exact comparison of discrete results (event frames, chosen indices).
template <class T>
std::string compareExact(const std::vector<T>& reference, const std::vector<T>& now) {
    if (reference.size() != now.size())
        return "count " + std::to_string(reference.size()) + " vs " + std::to_string(now.size());
    for (size_t i = 0; i < reference.size(); ++i)
        if (!(reference[i] == now[i])) return "item " + std::to_string(i) + " differs";
    return {};
}

// The stored waveform: each sample rounded to a 2^-21 step, per-block linear prediction and Rice codes (lossless for
// the rounded samples). A reference depends on nothing the test regenerates (not even an effect's input), so a
// change to the test's own signals cannot move it.
Audio quantize(const Audio& a);
std::vector<uint8_t> encodeAudio(const Audio& a);
bool decodeAudio(const std::vector<uint8_t>& bytes, uint32_t frames, Audio& out);

// One suite's references, engine/tests/references/<suite>.cawref. check() compares a render with its reference, or,
// under `caw_tests --update-references` (or --update-golden), records it; the file is written when the set goes.
// CAW_REFERENCE_REPORT=1 prints each comparison's measurements (REF lines) for classifying cases.
class References {
public:
    explicit References(std::string suite);
    ~References();
    References(const References&) = delete;
    References& operator=(const References&) = delete;
    void check(const std::string& name, const Audio& render, Class c, const char* file, int line);
    std::string path() const;
    // Store only the first `frames` of each stable render's waveform (0: all of it); the whole render is then also
    // compared as heard (the chaotic comparison) against features recorded from it.
    void storeWaveformFrames(uint32_t frames);

private:
    struct Entry {
        std::string name;
        Class cls = Class::Stable;
        uint32_t frames = 0;
        uint32_t waveFrames = 0;    // Stable: how many of the frames the waveform holds
        std::vector<uint8_t> wave;  // Stable
        std::string alias;          // Stable, the same waveform as an earlier entry
        Features features;          // Chaotic, or a stable render longer than its waveform
    };
    const Entry* find(const std::string& name) const;
    bool load();
    bool save() const;
    std::string suite_;
    std::vector<Entry> entries_;
    bool loaded_ = false;
    bool updating_ = false;
    uint32_t waveFrames_ = 0;
};

}  // namespace cawtest

#define CHECK_REFERENCE(refs, name, render, cls) (refs).check((name), (render), (cls), __FILE__, __LINE__)
