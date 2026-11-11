// Audio clips on tracks: their project JSON, and the built-in player (org.caw.audio-track) that plays them and the input.
#pragma once

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
    double pitch = 0;            // semitones, -48..48
    bool musical = false;        // false: "fixed" (file speed); true: "musical" (stretched to the tempo)
    bool varispeed = false;      // the stretch: false WSOLA (pitch kept), true resampling (pitch moves with speed)
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

void registerAudioTrack(ModuleRegistry& registry);

}  // namespace caw
