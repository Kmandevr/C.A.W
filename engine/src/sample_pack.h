// Sample-pack maker: batch-renders an instrument (and effects) over notes, velocities and parameter steps to named WAV files.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "module_registry.h"

namespace caw {

// A component by registry id: a built-in (org.caw.*) or one from a built library. Trust is never part of
// the request: the caller passes it separately (caw_sample_pack_render's trust_level, the CLI's --trust).
struct PackComponent {
    std::string id;
    std::string library;
    std::vector<std::pair<std::string, double>> params;  // fixed values; unnamed parameters keep their defaults
};

// One axis of the grid: a parameter of the instrument (effect < 0) or of effects[effect].
struct PackParamAxis {
    std::string id;
    int effect = -1;
    std::vector<double> values;  // as requested; constrained (clamped, stepped) when rendered
};

enum class PackNormalize { None, Peak, Rms };
enum class PackDither { None, Tpdf };

// One parameter a round robin varies: each take after the first moves it by up to +-amount (deterministically).
struct PackVary {
    std::string id;
    int effect = -1;  // < 0: the instrument
    double amount = 0;
};

struct SamplePackRequest {
    PackComponent instrument;
    std::vector<PackComponent> effects;
    std::string outputDir;
    std::string name = "sample";
    std::string namePattern = "{name}_{note}_{vel}_{param}";
    std::vector<int> notes{60};        // MIDI note numbers (C4 = 60)
    std::vector<int> velocities{100};  // 1..127
    std::vector<PackParamAxis> params;
    double holdSeconds = 1.0;          // note on, held this long, then note off
    double maxSeconds = 10.0;          // the longest a file may be, tail included
    double tailThresholdDb = -80.0;    // the render ends once the output stays below this for 0.25 s
    double sampleRate = 48000;
    uint32_t blockSize = 64;
    double tempo = 120;
    int bitDepth = 24;                 // 16 or 24 (PCM) or 32 (float)
    int channels = 2;                  // 1: the mid, (L + R) / 2
    bool trimStart = true, trimEnd = true;
    double trimThresholdDb = -80.0;
    double fadeInMs = 0, fadeOutMs = 0;
    PackNormalize normalize = PackNormalize::None;
    double normalizeTargetDb = -1.0;   // peak default -1 dBFS; rms default -18 dBFS
    bool normalizeGroup = false;       // one gain for the whole pack (keeps the files' relative levels)
    bool loop = false;
    double loopMinSeconds = 0.05;
    double loopMaxSeconds = -1;        // < 0: half the hold
    double loopCrossfadeMs = 0;        // > 0: the loop's last part is crossfaded with the audio before its start
    bool loopCrossfadeEqualPower = true;  // false: linear
    int roundRobins = 1;               // takes of each cell (1..16), each a fresh render
    double roundRobinPrerollMs = 7.0;  // take k runs the chain k x this long, silent, before its note
    std::vector<PackVary> roundRobinVary;
    PackDither dither = PackDither::None;  // 16- and 24-bit PCM only
    bool sfz = false;
    bool manifest = true;
    uint32_t maxFiles = 256;
    bool overwrite = false;
};

// Parses the JSON request (keys in docs/engine.md, "Sample packs"). A "trust" key anywhere is refused.
bool parseSamplePackRequest(std::string_view json, SamplePackRequest& out, std::string& error);

// Renders the whole pack into request.outputDir and returns the result JSON ({"ok":false,"error":...} on
// failure). `trust` applies to every library the request names. Blocks the caller; never call it on the audio
// or UI thread. progress gets 0..1000 and a non-zero *cancel stops it (both may be shared with another
// thread). Never throws.
std::string renderSamplePack(const SamplePackRequest& request, NativeModuleTrust trust, int32_t* progress = nullptr,
                             int32_t* cancel = nullptr);
std::string samplePackJson(std::string_view requestJson, NativeModuleTrust trust, int32_t* progress = nullptr,
                           int32_t* cancel = nullptr);

// ---------------------------------------------------------------- pieces (exposed for tests)

// C4 = 60, sharps: 61 is "C#4", 0 is "C-1", 127 is "G9".
std::string noteName(int midi);
// "C4", "F#2", "Bb0", "C-1" (any case for the letter); false for anything else or outside 0..127.
bool parseNoteName(std::string_view text, int& midi);
// A plain file name: letters, digits and . _ - # + only (anything else becomes _), no "..", no leading dot,
// at most 150 characters, never empty and never a reserved Windows device name.
std::string sanitizeFileName(std::string_view name);
// Expands {name} {note} {midi} {vel} {param} {index} {rr} in `pattern`, collapses repeated or edge underscores
// left by empty tokens, and sanitises the result (without the extension).
std::string expandNamePattern(std::string_view pattern, std::string_view name, int note, int velocity,
                              std::string_view param, uint32_t index, int roundRobin = 0);
// "cutoff-1200_mix-0.5": each swept parameter as id-value (a choice parameter by its label; minus as "m").
std::string paramLabel(const std::vector<std::pair<std::string, std::string>>& idValue);

// Trims leading/trailing frames whose every channel is below thresholdDb. Returns the frames removed at the start.
std::size_t trimSilence(std::vector<float>& left, std::vector<float>& right, double thresholdDb, bool start, bool end);
// Linear fades over the first and last frames (each at most the file's length).
void applyFades(std::vector<float>& left, std::vector<float>& right, std::size_t fadeIn, std::size_t fadeOut);

struct PackLoop {
    bool found = false;
    std::size_t start = 0, end = 0;  // inclusive: the loop plays start..end, then start again
    double matchDb = 0;              // the seam's difference energy relative to the signal (lower is better)
};
// A sustained-section loop: its end at the rising zero crossing (of the mid) at or before `endTarget` + 1, its
// start at the rising zero crossing in [earliest, end + 1 - minLength] whose surroundings best match the end's.
PackLoop findLoop(const std::vector<float>& left, const std::vector<float>& right, std::size_t earliest,
                  std::size_t endTarget, std::size_t minLength);

// Crossfades a found loop's last `frames` frames with the frames just before its start, so the seam at the wrap
// continues smoothly whatever the match (equal power, sin/cos, or linear). `frames` is held to the loop's length and
// to the frames before its start. Returns the frames crossfaded.
std::size_t crossfadeLoop(std::vector<float>& left, std::vector<float>& right, const PackLoop& loop, std::size_t frames,
                          bool equalPower);

struct PackWavSpec {
    int sampleRate = 48000;
    int channels = 2;
    int bitDepth = 24;
    PackDither dither = PackDither::None;  // TPDF: +-1 LSB triangular noise before rounding (not for float)
    uint32_t ditherSeed = 1;
    int rootNote = 60;  // smpl unity note
    bool loop = false;
    uint32_t loopStart = 0, loopEnd = 0;
};
// A WAV file with a smpl chunk (root note, and the loop when there is one). Int formats clip to full scale;
// NaN and Inf become 0. `right` is ignored for one channel.
std::vector<uint8_t> encodePackWav(const PackWavSpec& spec, const std::vector<float>& left,
                                   const std::vector<float>& right);

struct SfzRegion {
    std::string sample;
    int note = 60, velocity = 100;
    int roundRobin = 0, roundRobins = 1;  // seq_position (from 1) and seq_length when more than one
    bool loop = false;
    uint32_t loopStart = 0, loopEnd = 0;
};
// SFZ text mapping the regions by note (each sample covers the keys to halfway to its neighbours) and velocity
// (each covers from the layer below it, exclusive, to its own velocity; the top layer up to 127), and round robins
// by seq_length and seq_position.
std::string sfzText(std::string_view title, const std::vector<SfzRegion>& regions);

}  // namespace caw
