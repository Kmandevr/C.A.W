// Audio clips on tracks: their project JSON, and the built-in player (org.caw.audio-track) that plays them and the input.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include "module_registry.h"

namespace caw {

struct Json;
struct LayerSpec;
struct ComponentSpec;

inline constexpr const char* kAudioTrackId = "org.caw.audio-track";
inline constexpr int kMaxAudioClipsPerTrack = 4096;
inline constexpr int kAudioClipVoices = 16;  // clips one track plays at once (more overlapping are skipped)

enum class FadeCurve : uint8_t { Linear, EqualPower, SCurve, Fast, Slow };

struct AudioClipSpec {
    std::string id;
    std::string path;            // the file (from the clip's "path" or its "asset"'s)
    double startSteps = 0;       // song position, sixteenths (fractions allowed: recorded takes land off the grid)
    double lengthSteps = 16;
    double offsetSeconds = 0;    // into the source (at the file's own speed; reversed: from the end)
    double gain = 1;             // linear, 0..+12 dB
    double fadeInSeconds = 0, fadeOutSeconds = 0;
    FadeCurve fadeInCurve = FadeCurve::Linear, fadeOutCurve = FadeCurve::Linear;
    bool reverse = false;
    bool loop = false;
    double loopStartSeconds = 0, loopEndSeconds = 0;  // 0 end: the source's end
    int64_t loopStartFrames = -1, loopEndFrames = -1;  // API 32: at the file's own rate; when >= 0 they replace the seconds
    double pitch = 0;            // semitones, -48..48 (with pitchCents / 100 added: the sum within +-48)
    double pitchCents = 0;       // API 32: -2400..2400
    double stretchRatio = 1;     // API 32: a fixed clip's output length / source length, 0.25..4
    bool musical = false;        // false: "fixed" (file speed); true: "musical" / follows_tempo (follows the tempo map)
    bool varispeed = false;      // the stretch: false WSOLA (pitch kept), true resampling (pitch moves with speed)
    bool hq = false;             // API 32: "signalsmith": Signalsmith Stretch instead of WSOLA
    double sourceBpm = 0;        // the source's tempo (musical clips need one)
    bool mute = false;
};

// An audio track's input: which device channels it records and monitors.
struct TrackInputSpec {
    bool present = false;
    int channel = 0;    // first device input channel, from 0
    int channels = 1;   // 1 (mono, heard in both sides) or 2
    int monitor = 2;    // 0 off, 1 on (always), 2 auto (armed, and stopped or recording)
    bool armed = false;
};

struct AudioTrackSpec {
    std::vector<AudioClipSpec> clips;
    TrackInputSpec input;
    std::string signature() const;
};

// The project's "assets" table: id -> {path, bpm}.
struct AssetRef {
    std::string path;
    double bpm = 0;
};
bool parseAssetTable(const Json& root, std::map<std::string, AssetRef>& out, std::string& error);
// A layer's "audio_clips" and "input": an audio track plays them through org.caw.audio-track as its instrument.
// `endSteps` grows to the last clip's end. False with `error`.
bool parseAudioTrack(const Json& layer, const std::map<std::string, AssetRef>& assets, const std::string& where,
                     double maxSteps, LayerSpec& spec, double& endSteps, std::string& error);

// Gives a built player its clips (assets loaded off the audio thread here); nothing for any other component.
// Control thread. Lines for files that fail to load go to `warnings`.
void applyAudioTrack(ModuleProcessor& processor, const ComponentSpec& spec, double sampleRate,
                     std::string* warnings = nullptr);
// What a component chain gives a built-in beyond its values (component_chain.cpp, at build and on every project
// update that keeps it): the player's clips, and a sampler's zones when the project's state changed.
void applyComponentHostData(ModuleProcessor& processor, const ComponentSpec& spec, double sampleRate);
// Engine-internal: whether a processor is the player and wants to keep running stopped (monitoring).
bool monitorsStopped(const ModuleProcessor& processor) noexcept;

// What a player is doing, for tests (read between blocks on the thread that processes it).
struct AudioTrackStats {
    int voices = 0;       // sounding or fading
    int hqVoices = 0;     // playing through Signalsmith Stretch (spares included)
    int wsolaVoices = 0;  // playing WSOLA (a Signalsmith clip over the cap or with no stretcher free, or a WSOLA clip)
    int spares = 0;       // pre-rolled for the loop's start
    int stretchers = 0;   // in the current timeline's pool
    double stretcherRate = 0;  // their sample rate (0: none)
};
AudioTrackStats audioTrackStats(const ModuleProcessor& processor) noexcept;

void registerAudioTrack(ModuleRegistry& registry);

}  // namespace caw
