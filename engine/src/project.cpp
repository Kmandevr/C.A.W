// Reads the project JSON into a ProjectSpec, clamping every value to a safe range.
#include "project.h"

#include <algorithm>
#include <cctype>
#include <cmath>

#include "json.h"

namespace caw {

namespace {

double clampd(double v, double lo, double hi) {
    if (!std::isfinite(v)) return lo;
    return std::min(hi, std::max(lo, v));
}

int clampi(double v, int lo, int hi) { return static_cast<int>(std::floor(clampd(v, lo, hi))); }

std::vector<std::string> idList(const Json* arr) {
    std::vector<std::string> out;
    if (!arr || arr->type != Json::Type::Array) return out;
    for (const Json& j : arr->arr)
        if (j.type == Json::Type::String) out.push_back(j.str);
    return out;
}

}  // namespace

const ModuleSpec* ProjectSpec::module(const std::string& id) const {
    for (const ModuleSpec& m : modules)
        if (m.id == id) return &m;
    return nullptr;
}

bool parseProject(std::string_view text, ProjectSpec& out, std::string& error) {
    Json root;
    if (!parseJson(text, root, error)) return false;
    if (root.type != Json::Type::Object) {
        error = "project must be a JSON object";
        return false;
    }
    if (root.number("caw_project", 1) != 1) {
        error = "this app reads project format 1";
        return false;
    }
    out = ProjectSpec{};
    out.name = root.string("name");
    out.bpm = clampd(root.number("bpm", 120), 20, 400);
    out.beatsPerBar = clampi(root.number("beats_per_bar", 4), 1, 16);
    out.voices = clampi(root.number("voices", 32), 1, 32);  // a cap: each generator plays its own voices: count
    out.loopBars = clampi(root.number("loop_bars", 4), 1, 64);
    const int maxArrangementSteps = 64 * out.beatsPerBar * 4;
    out.seed = static_cast<uint32_t>(clampd(root.number("seed", 0), 0, 4294967295.0));
    out.master = clampd(root.number("master", 0.7), 0, 1);
    out.seamCrossfade = root.boolean("seam_crossfade", true);
    {
        const std::string swap = root.string("swap", "now");
        out.swapMode = swap == "beat" ? 1 : swap == "bar" ? 2 : 0;
    }
    out.keyRoot = clampi(root.number("key_root", 9), 0, 11);
    out.keyScale = clampi(root.number("key_scale", 1), 0, 13);

    if (const Json* deps = root.get("dependencies"); deps && deps->type == Json::Type::Array) {
        if (deps->arr.size() > 4096) {
            error = "a project can reference at most 4096 dependencies";
            return false;
        }
        for (const Json& d : deps->arr) {
            if (d.type != Json::Type::Object) {
                error = "each project dependency must be an object";
                return false;
            }
            DependencyRef dep;
            dep.stableId = d.string("id");
            dep.version = d.string("version");
            dep.contentHash = d.string("hash");
            const std::string scope = d.string("scope", "project");
            if (scope == "project") dep.scope = AssetScope::ProjectLocal;
            else if (scope == "global") dep.scope = AssetScope::UserGlobal;
            else if (scope == "factory") dep.scope = AssetScope::Factory;
            else if (scope == "addon") dep.scope = AssetScope::AddOn;
            else {
                error = "dependency scope must be project, global, factory or addon";
                return false;
            }
            const double interfaceVersion = d.number("interface_version", 1);
            if (dep.stableId.empty() || dep.version.empty() || !std::isfinite(interfaceVersion) ||
                interfaceVersion < 1 || interfaceVersion > 65535 || std::floor(interfaceVersion) != interfaceVersion) {
                error = "each project dependency needs a stable id, exact version and positive integer interface_version";
                return false;
            }
            dep.interfaceVersion = static_cast<uint32_t>(interfaceVersion);
            dep.optional = d.boolean("optional", false);
            out.dependencies.push_back(std::move(dep));
        }
    }

    if (const Json* mods = root.get("modules"); mods && mods->type == Json::Type::Array) {
        for (const Json& m : mods->arr) {
            if (m.type != Json::Type::Object) continue;
            ModuleSpec spec;
            spec.id = m.string("id");
            spec.name = m.string("name");
            spec.source = m.string("source");
            // Ids with control characters are left out: the engine names its hidden modules with them.
            bool control = false;
            for (unsigned char ch : spec.id) control = control || ch < 0x20;
            if (spec.id.empty() || control) continue;
            if (const Json* ps = m.get("params"); ps && ps->type == Json::Type::Object)
                for (const auto& [k, v] : ps->obj)
                    if (v.type == Json::Type::Number && std::isfinite(v.num)) spec.params[k] = v.num;
            out.modules.push_back(std::move(spec));
        }
    }
    if (const Json* layers = root.get("layers"); layers && layers->type == Json::Type::Array) {
        for (const Json& l : layers->arr) {
            if (l.type != Json::Type::Object) continue;
            if (out.layers.size() >= static_cast<size_t>(kMaxLayers)) {
                error = "a project holds at most 64 layers";
                return false;
            }
            LayerSpec spec;
            spec.id = l.string("id");
            spec.name = l.string("name");
            if (spec.id.empty()) continue;
            spec.chain = idList(l.get("chain"));
            spec.lengthSteps = clampi(l.number("length_steps", 0), 0, maxArrangementSteps);
            spec.pattern = l.string("pattern");
            spec.parentId = l.string("parent");
            spec.folder = l.boolean("folder", false);
            spec.busEnabled = l.boolean("bus", true);
            if (const Json* clips = l.get("clips"); clips && clips->type == Json::Type::Array) {
                for (const Json& c : clips->arr) {
                    if (c.type != Json::Type::Object) continue;
                    ClipSpec clip;
                    clip.id = c.string("id");
                    clip.pattern = c.string("pattern");
                    clip.startSteps = clampi(c.number("start_steps", 0), 0, maxArrangementSteps - 1);
                    clip.lengthSteps = clampi(c.number("length_steps", 64), 1, maxArrangementSteps - clip.startSteps);
                    clip.sourceOffsetSteps = clampi(c.number("source_offset_steps", 0), 0, maxArrangementSteps);
                    clip.loop = c.boolean("loop", true);
                    if (!clip.pattern.empty()) spec.clips.push_back(std::move(clip));
                }
            }
            if (const Json* lanes = l.get("automation"); lanes && lanes->type == Json::Type::Array) {
                for (const Json& laneJson : lanes->arr) {
                    if (laneJson.type != Json::Type::Object) continue;
                    AutomationLaneSpec lane; lane.target = laneJson.string("target");
                    if (lane.target != "volume" && lane.target != "pan") continue;
                    if (const Json* points = laneJson.get("points"); points && points->type == Json::Type::Array) {
                        if (points->arr.size() > 128) {
                            error = "a layer volume/pan automation lane currently supports at most 128 points";
                            return false;
                        }
                        for (const Json& point : points->arr) {
                            if (point.type != Json::Type::Object) continue;
                            lane.points.push_back({clampd(point.number("step", 0), 0, maxArrangementSteps),
                                clampd(point.number("value", lane.target == "volume" ? 0.8 : 0), lane.target == "volume" ? 0 : -1, 1)});
                        }
                    }
                    std::stable_sort(lane.points.begin(), lane.points.end(), [](const auto& a, const auto& b) { return a.step < b.step; });
                    if (!lane.points.empty()) spec.automation.push_back(std::move(lane));
                }
            }
            spec.volume = clampd(l.number("volume", 0.8), 0, 1);
            spec.pan = clampd(l.number("pan", 0), -1, 1);
            spec.mute = l.boolean("mute", false);
            spec.solo = l.boolean("solo", false);
            out.layers.push_back(std::move(spec));
        }
    }
    if (const Json* lanes = root.get("automation"); lanes && lanes->type == Json::Type::Array) {
        for (const Json& laneJson : lanes->arr) {
            if (laneJson.type != Json::Type::Object) continue;
            ProjectAutomationLaneSpec lane;
            lane.targetType = laneJson.string("target_type");
            lane.target = laneJson.string("target");
            lane.moduleId = laneJson.string("module");
            if ((lane.targetType != "param" && lane.targetType != "global") || lane.target.empty() ||
                (lane.targetType == "param" && lane.moduleId.empty())) continue;
            if (const Json* points = laneJson.get("points"); points && points->type == Json::Type::Array) {
                for (const Json& point : points->arr) {
                    if (point.type != Json::Type::Object || lane.points.size() >= 128) continue;
                    lane.points.push_back({clampd(point.number("step", 0), 0, maxArrangementSteps),
                                           clampd(point.number("value", 0), -1000000, 1000000)});
                }
            }
            std::stable_sort(lane.points.begin(), lane.points.end(),
                [](const auto& a, const auto& b) { return a.step < b.step; });
            if (!lane.points.empty()) out.automation.push_back(std::move(lane));
        }
    }

    int automationEndStep = 0;
    for (const auto& lane : out.automation)
        for (const auto& point : lane.points)
            automationEndStep = std::max(automationEndStep, static_cast<int>(std::ceil(point.step)));
    const int stepsPerBar = out.beatsPerBar * 4;
    if (automationEndStep > 0 && stepsPerBar > 0)
        out.loopBars = std::min(64, std::max(out.loopBars, (automationEndStep + stepsPerBar - 1) / stepsPerBar));

    // Reject malformed parent references and cycles before the audio thread sees routing indices.
    for (const LayerSpec& layer : out.layers) {
        std::string parent = layer.parentId;
        std::vector<std::string> seen{layer.id};
        for (int depth = 0; !parent.empty() && depth < kMaxLayers; ++depth) {
            if (std::find(seen.begin(), seen.end(), parent) != seen.end()) {
                error = "folder hierarchy contains a cycle";
                return false;
            }
            seen.push_back(parent);
            const auto found = std::find_if(out.layers.begin(), out.layers.end(),
                [&](const LayerSpec& candidate) { return candidate.id == parent; });
            if (found == out.layers.end() || !found->folder) {
                error = "a layer parent must reference an existing folder";
                return false;
            }
            parent = found->parentId;
        }
    }
    if (const Json* g = root.get("globals"); g && g->type == Json::Type::Object)
        for (const auto& [k, v] : g->obj)
            if (v.type == Json::Type::Number && std::isfinite(v.num)) out.globals[k] = v.num;
    if (const Json* a = root.get("audition"); a && a->type == Json::Type::Object) {
        out.auditionChain = idList(a->get("chain"));
        out.auditionSteps = clampi(a->number("length_steps", 0), 0, 64 * 16 * 16);
        out.auditionPattern = a->string("pattern");
    }
    out.auditionOnly = root.boolean("audition_only", false) && !out.auditionChain.empty();
    return true;
}

std::string refName(const std::string& name) {
    std::string out;
    bool gap = false;
    for (const char ch : name) {
        const unsigned char c = static_cast<unsigned char>(ch);
        if (std::isalnum(c)) {
            if (gap && !out.empty()) out += '_';
            out += static_cast<char>(std::tolower(c));
            gap = false;
        } else {
            gap = true;
        }
    }
    return out;
}

ProjectSpec singleModuleProject(const std::string& source, double bpm, int bars) {
    ProjectSpec p;
    p.bpm = bpm;
    p.loopBars = bars;
    p.modules.push_back({"m", source, {}});
    LayerSpec l;
    l.id = "l";
    l.name = "module";
    l.chain = {"m"};
    l.volume = 1.0;
    p.layers.push_back(l);
    return p;
}

}  // namespace caw
