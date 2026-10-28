// Project description shared by the app, the CLI and exports: tempo, modules (source and param values) and layers.
#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <string_view>
#include <vector>

namespace caw {

constexpr int kMaxLayers = 64;
constexpr int kMaxChain = 9;  // a generator plus up to 8 effects

struct ModuleSpec {
    std::string id;
    std::string source;
    std::map<std::string, double> params;
};

struct LayerSpec {
    std::string id, name;
    std::vector<std::string> chain;  // module ids: generator first, then effects
    int lengthSteps = 0;             // 16th notes per loop; 0 loops with the project
    double volume = 0.8, pan = 0.0;
    bool mute = false, solo = false;
};

struct ProjectSpec {
    std::string name;
    double bpm = 120.0;
    int beatsPerBar = 4;
    int loopBars = 4;
    uint32_t seed = 0;
    double master = 0.7;
    bool seamCrossfade = true;
    std::vector<ModuleSpec> modules;
    std::vector<LayerSpec> layers;
    std::vector<std::string> auditionChain;  // the Builder's preview, if any
    int auditionSteps = 0;
    bool auditionOnly = false;

    int loopSteps() const { return loopBars * beatsPerBar * 4; }
    const ModuleSpec* module(const std::string& id) const;
};

// Parses the project JSON format (docs/architecture.md, "Project file").
bool parseProject(std::string_view json, ProjectSpec& out, std::string& error);

// Wraps one module's source in a one-layer project, for the CLI and quick renders.
ProjectSpec singleModuleProject(const std::string& source, double bpm, int bars);

}  // namespace caw
