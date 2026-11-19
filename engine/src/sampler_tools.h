// The sampler's offline tools (C API 43): a sample's root note, drop-and-play key mapping, slicing a loop into zones, and cutting a recorded take into zones.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "builtin_sampler.h"

namespace caw {

struct AudioAsset;

// The pitch a sample sounds at: YIN (A. de Cheveigne and H. Kawahara, JASA 111(4), 2002) on the mono sum, 50 ms
// frames every 25 ms from just after the loudest attack, for up to 1 s; the median of the frames whose aperiodicity
// is under 0.2 and whose level is within 40 dB of the loudest. `sure` needs at least 3 such frames, half of those
// looked at, agreeing within half a semitone. Any thread but the audio thread (allocates).
struct RootResult {
    bool sure = false;
    double midi = 0;        // fractional (69 = 440 Hz); 0 when nothing was found
    int root = 60;          // midi rounded (60 when not sure)
    double cents = 0;       // midi - root in cents (0 when not sure)
    double confidence = 0;  // 0..1
};
RootResult detectRoot(const AudioAsset& asset, int64_t fromFrame = 0, int64_t toFrame = 0);

// Drop and play: how dropped samples spread over the keys.
//   Auto: one sample covers the whole keyboard; several cover it by their roots when every root is known, else
//   they spread evenly. Root: by root (split halfway between neighbours; samples sharing a root take turns as round
//   robins). Spread: equal key ranges over the whole keyboard, each sample's root at its range's middle. Keys: one key
//   each from startKey up (one-shots, drum hits).
enum class MapMode { Auto, Root, Spread, Keys };
struct MapInput {
    std::string path;
    int root = -1;       // -1: unknown
    double cents = 0;    // the detected pitch's offset from root (the zone is tuned by -cents)
};
std::vector<SamplerZone> mapSamples(const std::vector<MapInput>& in, MapMode mode, int startKey, MapMode* used = nullptr);

// Gives each zone a key range by its root: within each velocity layer (equal lovel..hivel), zones sorted by root,
// split halfway between neighbouring roots, the lowest from key 0 and the highest to key 127; zones sharing a root
// become round robins. Zone order is kept.
void spreadByRoot(std::vector<SamplerZone>& zones);

// Slices [cuts] (file frames, ascending, each inside 0..frames) of a file of `frames` frames to keys from startKey:
// slice i plays [cut i, cut i+1) on key startKey + i at its own pitch, one shot. The first slice starts at 0.
std::vector<SamplerZone> sliceZones(const std::string& path, const std::vector<int64_t>& cuts, int64_t frames,
                                    int startKey);

// A recorded take, note by note: each planned note's window of the take is searched for the note (its attack: the
// first frame within 26 dB of the window's peak, less 2 ms; its end: the last frame within 54 dB of it, plus 20 ms),
// and its pitch is checked. Notes quieter than -60 dBFS are missing. Zones span the keys by root (spreadByRoot).
struct TakeNote {
    int key = 60;
    double startSeconds = 0, endSeconds = 0;
    int lovel = 1, hivel = 127;
};
struct TakeNoteResult {
    int key = 60;
    bool found = false;
    bool sure = false;    // the pitch was found
    double midi = 0;      // the pitch found
    int64_t start = 0, end = 0;  // file frames
};
std::vector<SamplerZone> takeZones(const AudioAsset& asset, const std::vector<TakeNote>& notes,
                                   std::vector<TakeNoteResult>& results);

// The C API's JSON answers (docs/engine.md "Sampler tools"). Requests are at most 64 KiB; each fails closed with an
// error naming the key.
std::string samplerMapJson(const char* request, double engineRate);
std::string samplerSliceJson(const char* path, const char* options, double engineRate);
std::string samplerTakeJson(const char* request, double engineRate);

}  // namespace caw
