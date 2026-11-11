// Song renders for the Export sheet: the mix and aligned stems (tracks, buses), over the song, the loop, a time
// selection or each region, with a tail, peak or loudness normalisation, 16-bit dither and file naming.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <vector>

#include "project.h"

namespace caw {

enum class SongBounds { Song, Loop, Selection, Regions };
enum class SongNormalize { None, Peak, Lufs };
enum class SongTail { None, Seconds, Silence };

struct SongRegion {
    std::string name;
    int startSteps = 0, endSteps = 0;  // [start, end) in sixteenth steps
};

struct SongRenderRequest {
    std::string outDir;                                // an existing directory; every file goes straight into it
    std::string project = "CAW";                       // {project} in the file names
    std::string pattern = "{project}_{region}_{stem}";  // also {kind}, {index}; empty tokens' separators collapse
    bool mix = true;                                    // the master output, exactly as playback sounds
    bool tracks = false, buses = false;                 // a stem per track and/or per folder bus
    std::vector<std::string> layers;                    // instead of all of them: these layers' stems, in this order
    SongBounds bounds = SongBounds::Song;
    int startSteps = 0, endSteps = 0;  // Selection
    std::vector<SongRegion> regions;   // Regions: one render (and set of files) each
    int sampleRate = 48000;
    int bitDepth = 24;   // 16, 24 (PCM) or 32 (float)
    bool dither = true;  // TPDF, at 16-bit only
    SongNormalize normalize = SongNormalize::None;
    double target = -1.0;          // dBFS (peak) or LUFS (loudness)
    double ceiling = -1.0;         // loudness: never louder than this true peak (dBTP); > 0 turns it off
    bool normalizeEach = false;    // stems: each to the target, instead of all by the mix's gain (keeps their sum)
    SongTail tail = SongTail::None;
    double tailSeconds = 2.0;      // Seconds: exactly this; Silence: at most this
    double silenceDb = -90.0;      // Silence: below this on every output for half a second ends the tail
    bool stemsThroughMaster = true;  // stems get the master's volume, DC filter and start fade (not its effects)
};

struct RenderedFile {
    std::string path, name, kind, layer, region;  // kind: mix, track or bus
    int64_t frames = 0;
    double gainDb = 0, peakDb = -200, lufs = -200;  // as written (after the gain); -200: silent or not measured
};

struct SongRenderResult {
    std::vector<RenderedFile> files;
    std::string error;
};

// The request JSON (docs/engine.md, "Song renders"): false and a message for anything malformed.
bool parseSongRenderRequest(std::string_view json, SongRenderRequest& out, std::string& error);
// {"ok":..., "error":..., "files":[{"path","name","kind","layer","region","frames","gain_db","peak_db","lufs"}]}
std::string songRenderResultJson(const SongRenderResult& r);

// Renders every file the request asks for. One engine pass per range renders the mix and all its stems at once, so
// they start on the same frame and have the same length; each output streams through a temporary float file, then is
// encoded with its gain. progress gets 0..1000 and a non-zero cancel stops it (either may be null, and both may be
// shared with another thread). On failure or cancel no file of the request is left behind. Never call it on the
// audio thread or the UI thread.
bool renderSong(const ProjectSpec& p, const SongRenderRequest& req, SongRenderResult& out, int32_t* progress = nullptr,
                int32_t* cancel = nullptr);

}  // namespace caw
