// Project description shared by the app, the CLI and exports: tempo, modules (source and param values) and layers.
#pragma once

#include <cstdint>
#include <map>
#include <memory>
#include <string>
#include <string_view>
#include <vector>

#include "component_samples.h"

#include "dependency.h"

namespace caw {

struct AudioTrackSpec;  // audio_clips.h

struct ModuleSpec {
    std::string id;
    std::string source;
    std::map<std::string, double> params;
    std::string name = {};  // how other modules refer to this one (module.export); falls back to the header name
};

// Where a component with a sidechain input (a ducker, a compressor or gate keyed by another track) hears its
// key: another layer's signal after its effects, before its fader (pre) or after volume and pan (post), times
// level. Notes the source layer plays also reach a component that takes key notes (the ducker's Notes mode).
struct KeySpec {
    std::string layer;   // the source layer's id (a track or a bus folder, never the component's own layer)
    bool pre = true;     // pre-fader (after the source's effects) or post-fader (after its volume and pan)
    double level = 1.0;  // linear gain, 0..kMaxMixGain
};

// One native component in a chain (a track's inserts or the master's): its id and the parameter
// values the project sets (the rest keep their defaults).
struct ComponentSpec {
    std::string id;
    std::vector<std::pair<std::string, double>> params;
    bool bypass = false;            // passes its input through (crossfaded) and stops processing
    bool hasState = false;          // `state` holds what the component's save_state wrote
    bool lenient = false;           // a rebuild: values the new build lacks and a state it refuses are dropped
    uint32_t stateVersion = 1;
    std::vector<uint8_t> state;
    bool hasKey = false;  // `key` names its sidechain source (a component with a sidechain input only)
    KeySpec key;
    // Audio for the component's sample slots (org.caw.drums: one per pad), decoded at build (component_samples.h).
    std::vector<SampleRefSpec> samples;
    // org.caw.audio-track only: the layer's audio clips and input (audio_clips.h), set from "audio_clips"/"input".
    std::shared_ptr<const AudioTrackSpec> audioTrack;
};

struct ClipSpec {
    std::string id;
    std::string pattern;
    int startSteps = 0;
    int lengthSteps = 64;
    int sourceOffsetSteps = 0;
    bool loop = true;
    bool mute = false;  // kept on the timeline (the layer stays arranged) but plays nothing
};

struct AutomationPointSpec { double step = 0, value = 0; };
struct AutomationLaneSpec { std::string target; std::vector<AutomationPointSpec> points; };

struct ProjectAutomationLaneSpec {
    std::string targetType;  // param, global, component or instrument
    std::string moduleId;    // param: the module; component: the layer (empty for the master chain); instrument: the layer
    int component = -1;      // component: its index in that chain
    std::string target;      // parameter/global name
    std::vector<AutomationPointSpec> points;
};

// The most a track or the master fader gains: +12 dB (owner, 2026-11-10: faders like REAPER's), 10^(12/20).
constexpr double kMaxMixGain = 3.9810717055349722;

// A send: a copy of a layer's signal into a bus folder's input, beside its normal route to its parent bus or
// the master. Pre-fader sends tap after the layer's effects, before volume and pan; post-fader sends after them.
// A muted or soloed-out layer sends nothing either way.
struct SendSpec {
    std::string to;      // a bus folder's layer id
    double level = 1.0;  // linear gain, 0..kMaxMixGain
    bool pre = false;
    bool mute = false;
};
constexpr int kMaxSends = 8;  // sends per layer

struct LayerSpec {
    std::string id, name;
    std::vector<std::string> chain;  // module ids: generator first, then effects
    int lengthSteps = 0;             // 16th notes per loop; 0 loops with the project
    std::string pattern;             // legacy single-pattern layer
    std::vector<ClipSpec> clips;      // arrangement instances, compiled before playback
    std::string parentId;
    bool folder = false, busEnabled = true;
    std::vector<AutomationLaneSpec> automation;
    std::vector<ComponentSpec> components;  // native stereo effects after the chain, before volume and pan
    std::vector<SendSpec> sends;            // at most kMaxSends; each to a bus folder
    // A native instrument (one event input, one stereo output) that plays the layer's notes instead of
    // a .caw generator; the chain's .caw effects, then `components`, follow it.
    bool hasInstrument = false;
    ComponentSpec instrument;
    double volume = 0.8, pan = 0.0;
    bool mute = false, solo = false;
};

// A song position is a 32-bit step count, so a song holds whole bars up to 2^31 - 1 steps (F7.2: no other
// length limit). beatsPerBar is 1..16, so a bar is 4..64 steps.
constexpr int maxLoopBars(int beatsPerBar) noexcept { return 2147483647 / (beatsPerBar * 4); }
constexpr int maxArrangementSteps(int beatsPerBar) noexcept { return maxLoopBars(beatsPerBar) * beatsPerBar * 4; }

struct ProjectSpec {
    std::string name;
    double bpm = 120.0;
    int beatsPerBar = 4;
    int loopBars = 4;
    // A loop range inside the song (REAPER's loop points): while on, playback that reaches loopEndSteps goes back to
    // loopStartSteps, and the song end goes back there too. Off (the default), the whole song loops.
    bool loopRange = false;
    int loopStartSteps = 0, loopEndSteps = 0;
    uint32_t seed = 0;
    double master = 0.7;
    bool seamCrossfade = true;
    int voices = 32;  // the most voices any pattern layer may use (1..32); light mode sends 4
    int swapMode = 0;  // when new code is heard while playing: 0 at once, 1 at the next beat, 2 at the next bar
    std::map<std::string, double> globals;  // project-wide control values by name
    int keyRoot = 9;                        // 0 = C … 11 = B; scale() and chord() default to this key
    int keyScale = 1;                       // a scale.* id (1 = minor)
    std::vector<DependencyRef> dependencies;
    std::vector<ModuleSpec> modules;
    std::vector<ComponentSpec> masterComponents;  // explicitly loaded native stereo effects, in master-chain order
    std::vector<LayerSpec> layers;
    std::vector<ProjectAutomationLaneSpec> automation;
    std::vector<std::string> auditionChain;  // the Builder's preview, if any
    int auditionSteps = 0;
    std::string auditionPattern;
    bool auditionOnly = false;

    int loopSteps() const { return loopBars * beatsPerBar * 4; }
    const ModuleSpec* module(const std::string& id) const;
};

// Parses the project JSON format (docs/architecture.md, "Project file").
// The bus folder a layer's audio goes to: its nearest ancestor folder with a bus ("" for the master).
std::string routeTarget(const ProjectSpec& p, const LayerSpec& layer);
// Sends go to bus folders, keys come from playing layers, and nothing hears itself through any mix of folder
// buses, sends and keys: false and a message naming the loop otherwise. parseProject calls it.
bool validateRouting(const ProjectSpec& p, std::string& error);
bool parseProject(std::string_view json, ProjectSpec& out, std::string& error);

// The name modules use to read another module's exports: lower case, other characters become '_'
// ("Kick" -> kick, "Bytebeat loop" -> bytebeat_loop).
std::string refName(const std::string& name);

// Wraps one module's source in a one-layer project, for the CLI and quick renders.
ProjectSpec singleModuleProject(const std::string& source, double bpm, int bars);

}  // namespace caw
