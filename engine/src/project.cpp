// Reads the project JSON into a ProjectSpec: values clamp to a safe range, song positions out of range are refused.
#include "project.h"

#include "modulation_links.h"

#include "presets.h"

#include <algorithm>
#include <cctype>
#include <cmath>

#include "audio_clips.h"
#include "json.h"

namespace caw {

namespace {

double clampd(double v, double lo, double hi) {
    if (!std::isfinite(v)) return lo;
    return std::min(hi, std::max(lo, v));
}

int clampi(double v, int lo, int hi) { return static_cast<int>(std::floor(clampd(v, lo, hi))); }

// A whole number in lo..hi, or false: song positions are refused with a message, never moved or shortened.
bool wholeIn(double v, int lo, int hi, int& out) {
    if (!std::isfinite(v) || v != std::floor(v) || v < lo || v > hi) return false;
    out = static_cast<int>(v);
    return true;
}

std::string range(int lo, int hi) { return std::to_string(lo) + " to " + std::to_string(hi); }

// One component entry: an id string, or {"id", "params": {name: number}, "bypass", "state", "state_version"}.
bool componentEntry(const Json& j, const std::string& where, ComponentSpec& c, std::string& error) {
    if (j.type == Json::Type::String) {
        c.id = j.str;
    } else if (j.type == Json::Type::Object) {
        c.id = j.string("id");
        c.bypass = j.boolean("bypass", false);
        if (const Json* st = j.get("state"); st && st->type == Json::Type::String) {
            constexpr size_t kMaxStateText = 16u << 20;  // 12 MB of state; a component's own limit is checked at build
            if (st->str.size() > kMaxStateText || !base64Decode(st->str, c.state)) {
                error = where + ": component '" + c.id + "' state must be base64 of at most 12 MB";
                return false;
            }
            c.hasState = true;
            const double version = j.number("state_version", 1);
            if (!std::isfinite(version) || version < 0 || version > 4294967295.0 || version != std::floor(version)) {
                error = where + ": component '" + c.id + "' state_version must be a whole number";
                return false;
            }
            c.stateVersion = static_cast<uint32_t>(version);
        }
        if (const Json* ps = j.get("params")) {
            if (ps->type != Json::Type::Object) {
                error = where + ": component '" + c.id + "' params must be an object of numbers";
                return false;
            }
            for (const auto& [k, v] : ps->obj) {
                if (v.type != Json::Type::Number || !std::isfinite(v.num)) {
                    error = where + ": component '" + c.id + "' param '" + k + "' must be a finite number";
                    return false;
                }
                c.params.emplace_back(k, v.num);
            }
        }
        // The sidechain key: {"layer": id, "tap": "pre" | "post", "level": gain} (null or absent: none).
        if (const Json* k = j.get("key"); k && k->type != Json::Type::Null) {
            if (k->type != Json::Type::Object || k->string("layer").empty()) {
                error = where + ": component '" + c.id + "' key must be {\"layer\": id, \"tap\": \"pre\"|\"post\", \"level\": n}";
                return false;
            }
            c.hasKey = true;
            c.key.layer = k->string("layer");
            const std::string tap = k->string("tap", "pre");
            if (tap != "pre" && tap != "post") {
                error = where + ": component '" + c.id + "' key tap must be \"pre\" or \"post\"";
                return false;
            }
            c.key.pre = tap == "pre";
            c.key.level = clampd(k->number("level", 1.0), 0.0, kMaxMixGain);
        }
        // Samples: [{"slot": n, "path": file} or {"slot": n, "builtin": name}] (docs/engine.md, "Drums", Samples).
        if (const Json* ss = j.get("samples"); ss && ss->type != Json::Type::Null) {
            constexpr size_t kMaxSamples = 256;
            if (ss->type != Json::Type::Array || ss->arr.size() > kMaxSamples) {
                error = where + ": component '" + c.id + "' samples must be an array of at most 256 entries";
                return false;
            }
            for (const Json& s : ss->arr) {
                const double slot = s.type == Json::Type::Object ? s.number("slot", -1) : -1;
                SampleRefSpec r;
                if (s.type == Json::Type::Object) {
                    r.path = s.string("path");
                    r.builtin = s.string("builtin");
                }
                if (!(slot >= 0 && slot < 65536 && slot == std::floor(slot)) || r.path.empty() == r.builtin.empty() ||
                    r.path.size() > 4096 || r.builtin.size() > 256) {
                    error = where + ": component '" + c.id + "' sample entries must be {\"slot\": n, \"path\": file} or {\"slot\": n, \"builtin\": name}";
                    return false;
                }
                r.slot = static_cast<uint32_t>(slot);
                c.samples.push_back(std::move(r));
            }
        }
        // A built-in preset's values under the entry's own params (docs/engine.md, Presets).
        if (const Json* pr = j.get("preset"); pr && pr->type != Json::Type::Null) {
            if (pr->type != Json::Type::String || !applyBuiltinPreset(c.id, pr->str, c.params)) {
                error = where + ": component '" + c.id + "' has no preset '" + (pr->type == Json::Type::String ? pr->str : "") + "'";
                return false;
            }
        }
    }
    if (c.id.empty()) {
        error = where + ": every component needs an id";
        return false;
    }
    return true;
}

// A component chain: each entry an id string, or {"id": ..., "params": {name: number}}.
bool componentList(const Json* arr, const std::string& where, std::vector<ComponentSpec>& out, std::string& error) {
    out.clear();
    if (!arr) return true;
    if (arr->type != Json::Type::Array) {
        error = where + " must be a list of components";
        return false;
    }
    if (arr->arr.size() > 64) {
        error = where + " holds more than 64 components";
        return false;
    }
    for (const Json& j : arr->arr) {
        ComponentSpec c;
        if (!componentEntry(j, where, c, error)) return false;
        out.push_back(std::move(c));
    }
    return true;
}

}  // namespace

std::string routeTarget(const ProjectSpec& p, const LayerSpec& layer) {
    std::string parent = layer.parentId;
    for (size_t depth = 0; !parent.empty() && depth < p.layers.size(); ++depth) {
        const LayerSpec* found = nullptr;
        for (const LayerSpec& l : p.layers)
            if (l.id == parent) found = &l;
        if (!found) return {};
        if (found->folder && found->busEnabled) return found->id;
        parent = found->parentId;
    }
    return {};
}

bool validateRouting(const ProjectSpec& p, std::string& error) {
    const size_t n = p.layers.size();
    std::map<std::string, size_t> index;
    for (size_t i = 0; i < n; ++i) index.emplace(p.layers[i].id, i);
    auto label = [&](size_t i) {
        const LayerSpec& l = p.layers[i];
        return "'" + (l.name.empty() ? l.id : l.name) + "'";
    };
    // Edges run from what is heard to what hears it: a layer to its bus (or nothing: the master), to the buses
    // it sends to, and a key's source to the layer whose component it keys.
    std::vector<std::vector<size_t>> edges(n);
    for (size_t i = 0; i < n; ++i) {
        const LayerSpec& l = p.layers[i];
        const bool plays = !(l.folder && !l.busEnabled);  // an organization-only folder carries no audio
        if (plays) {
            const std::string to = routeTarget(p, l);
            if (!to.empty()) edges[i].push_back(index.at(to));
        }
        for (const SendSpec& s : l.sends) {
            auto it = index.find(s.to);
            if (it == index.end()) {
                error = "layer " + label(i) + " sends to '" + s.to + "', which is not in the project";
                return false;
            }
            const LayerSpec& to = p.layers[it->second];
            if (!to.folder || !to.busEnabled) {
                error = "layer " + label(i) + " sends to " + label(it->second) + ", which is not a bus";
                return false;
            }
            if (it->second == i) {
                error = "layer " + label(i) + " sends to itself";
                return false;
            }
            if (!plays) {
                error = "folder " + label(i) + " has no bus, so it has nothing to send";
                return false;
            }
            edges[i].push_back(it->second);
        }
        for (const ComponentSpec& c : l.components) {
            if (!c.hasKey) continue;
            auto it = index.find(c.key.layer);
            if (it == index.end()) {
                error = "layer " + label(i) + ": component '" + c.id + "' is keyed by '" + c.key.layer + "', which is not in the project";
                return false;
            }
            if (it->second == i) {
                error = "layer " + label(i) + ": component '" + c.id + "' can't be keyed by its own layer";
                return false;
            }
            const LayerSpec& from = p.layers[it->second];
            if (from.folder && !from.busEnabled) {
                error = "layer " + label(i) + ": component '" + c.id + "' is keyed by folder " + label(it->second) +
                        ", which has no bus";
                return false;
            }
            edges[it->second].push_back(i);
        }
    }
    // A modulator that hears a layer's audio orders it before every layer its links move (#161).
    if (!modulationEdges(p, index, edges, error)) return false;
    // Depth-first search for a loop; the path to it names the layers in the message.
    std::vector<uint8_t> state(n, 0);  // 0 unseen, 1 on the path, 2 done
    std::vector<size_t> path, at;
    for (size_t start = 0; start < n; ++start) {
        if (state[start]) continue;
        path.assign(1, start);
        at.assign(1, 0);
        state[start] = 1;
        while (!path.empty()) {
            const size_t x = path.back();
            if (at.back() == edges[x].size()) {
                state[x] = 2;
                path.pop_back();
                at.pop_back();
                continue;
            }
            const size_t y = edges[x][at.back()++];
            if (state[y] == 1) {
                std::string loop;
                bool on = false;
                for (size_t k : path) {
                    on = on || k == y;
                    if (on) loop += label(k) + " -> ";
                }
                error = "routing makes a loop: " + loop + label(y) + " (a layer can't hear itself)";
                return false;
            }
            if (state[y] == 0) {
                state[y] = 1;
                path.push_back(y);
                at.push_back(0);
            }
        }
    }
    return true;
}

const ModuleSpec* ProjectSpec::module(const std::string& id) const {
    for (const ModuleSpec& m : modules)
        if (m.id == id) return &m;
    return nullptr;
}

bool parseProject(std::string_view text, ProjectSpec& out, std::string& error) {
    // A failed parse must never leave a caller's previous project looking valid.
    out = ProjectSpec{};
    error.clear();
    constexpr size_t kMaxProjectJsonBytes = 8u << 20;  // Bound hostile JSON parsing by input memory, not object counts.
    if (text.size() > kMaxProjectJsonBytes) {
        error = "project JSON exceeds the 8 MiB parser memory budget";
        return false;
    }
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
    if (const Json* tm = root.get("tempo_map"); tm && tm->type != Json::Type::Null) {
        if (!readTempoMap(*tm, out.tempoMap, error)) return false;
        out.bpm = out.tempoMap.front().bpm;
    }
    if (const Json* ts = root.get("time_signatures"); ts && ts->type != Json::Type::Null) {
        if (!readTimeSigs(*ts, out.timeSigs, error)) return false;
    }
    const int maxBars = maxLoopBars(out.beatsPerBar);
    const int maxSteps = maxArrangementSteps(out.beatsPerBar);
    if (!wholeIn(root.number("loop_bars", 4), 1, maxBars, out.loopBars)) {
        error = "loop_bars must be a whole number from " + range(1, maxBars) + " at " +
            std::to_string(out.beatsPerBar) + " beats per bar";
        return false;
    }
    out.loopRange = root.boolean("loop_range", false);
    if (out.loopRange) {
        if (!wholeIn(root.number("loop_start_steps", 0), 0, maxSteps - 1, out.loopStartSteps) ||
            !wholeIn(root.number("loop_end_steps", 0), 1, maxSteps, out.loopEndSteps) ||
            out.loopEndSteps <= out.loopStartSteps) {
            error = "loop_start_steps and loop_end_steps must be whole numbers from " + range(0, maxSteps) +
                ", the end after the start";
            return false;
        }
    }
    const auto pointStepsOk = [&](const Json* points, std::string& message, const std::string& owner) {
        if (!points || points->type != Json::Type::Array) return true;
        for (const Json& point : points->arr) {
            if (point.type != Json::Type::Object) continue;
            const double step = point.number("step", 0);
            if (!(step >= 0 && step <= maxSteps)) {
                message = owner + "automation point steps must be from " + range(0, maxSteps);
                return false;
            }
        }
        return true;
    };
    out.seed = static_cast<uint32_t>(clampd(root.number("seed", 0), 0, 4294967295.0));
    out.master = clampd(root.number("master", 0.7), 0, kMaxMixGain);

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

    if (!componentList(root.get("master_components"), "master_components", out.masterComponents, error)) return false;
    for (const ComponentSpec& c : out.masterComponents)
        if (c.hasKey) {
            error = "master_components: component '" + c.id + "' can't take a sidechain key on the master (put it on a bus)";
            return false;
        }
    if (const Json* mods = root.get("modules"); mods && mods->type == Json::Type::Array) {
        for (const Json& m : mods->arr) {
            if (m.type != Json::Type::Object) continue;
            ModuleSpec spec;
            spec.id = m.string("id");
            spec.source = m.string("source");
            // Ids with control characters are left out: the engine names its internal modules with them.
            bool control = false;
            for (unsigned char ch : spec.id) control = control || ch < 0x20;
            if (spec.id.empty() || control) continue;
            out.modules.push_back(std::move(spec));
        }
    }
    std::map<std::string, AssetRef> assets;  // the "assets" table audio clips name
    if (!parseAssetTable(root, assets, error)) return false;
    double audioEndSteps = 0;  // the last audio clip's end
    if (const Json* layers = root.get("layers"); layers && layers->type == Json::Type::Array) {
        for (const Json& l : layers->arr) {
            if (l.type != Json::Type::Object) continue;
            LayerSpec spec;
            spec.id = l.string("id");
            spec.name = l.string("name");
            if (spec.id.empty()) continue;
            const std::string layerName = "layer '" + spec.id + "'";
            if (!componentList(l.get("components"), layerName + " components", spec.components, error)) return false;
            if (!componentList(l.get("noteComponents"), layerName + " noteComponents", spec.noteComponents, error)) return false;
            for (const ComponentSpec& c : spec.noteComponents)
                if (c.hasKey) {
                    error = layerName + " noteComponents: component '" + c.id + "' can't take a sidechain key per note";
                    return false;
                }
            if (const Json* v = l.get("noteVoices"); v && v->type != Json::Type::Null &&
                                                      !wholeIn(l.number("noteVoices", 8), 1, 16, spec.noteVoices)) {
                error = layerName + ": noteVoices must be a whole number from 1 to 16";
                return false;
            }
            if (const Json* inst = l.get("instrument"); inst && inst->type != Json::Type::Null) {
                if (inst->type != Json::Type::String && inst->type != Json::Type::Object) {
                    error = layerName + " instrument must be a component id or {\"id\": ...}";
                    return false;
                }
                if (!componentEntry(*inst, layerName + " instrument", spec.instrument, error)) return false;
                spec.hasInstrument = true;
            }
            if (!wholeIn(l.number("length_steps", 0), 0, maxSteps, spec.lengthSteps)) {
                error = layerName + ": length_steps must be a whole number from " + range(0, maxSteps);
                return false;
            }
            spec.pattern = l.string("pattern");
            spec.parentId = l.string("parent");
            spec.folder = l.boolean("folder", false);
            spec.busEnabled = l.boolean("bus", true);
            if (!parseAudioTrack(l, assets, layerName, static_cast<double>(maxSteps), spec, audioEndSteps, error)) return false;
            if (const Json* sends = l.get("sends"); sends && sends->type != Json::Type::Null) {
                if (sends->type != Json::Type::Array) {
                    error = layerName + ": sends must be a list of {\"to\": bus id, \"level\", \"pre\", \"mute\"}";
                    return false;
                }
                if (sends->arr.size() > static_cast<size_t>(kMaxSends)) {
                    error = layerName + " has more than " + std::to_string(kMaxSends) + " sends";
                    return false;
                }
                for (const Json& sj : sends->arr) {
                    SendSpec send;
                    if (sj.type == Json::Type::Object) {
                        send.to = sj.string("to");
                        send.level = clampd(sj.number("level", 1.0), 0.0, kMaxMixGain);
                        send.pre = sj.boolean("pre", false);
                        send.mute = sj.boolean("mute", false);
                    }
                    if (send.to.empty()) {
                        error = layerName + ": every send needs a \"to\" bus";
                        return false;
                    }
                    spec.sends.push_back(std::move(send));
                }
            }
            if (const Json* clips = l.get("clips"); clips && clips->type == Json::Type::Array) {
                for (const Json& c : clips->arr) {
                    if (c.type != Json::Type::Object) continue;
                    ClipSpec clip;
                    clip.id = c.string("id");
                    clip.pattern = c.string("pattern");
                    const std::string clipName = "clip '" + clip.id + "' of " + layerName;
                    if (!wholeIn(c.number("start_steps", 0), 0, maxSteps - 1, clip.startSteps)) {
                        error = clipName + ": start_steps must be a whole number from " + range(0, maxSteps - 1);
                        return false;
                    }
                    if (!wholeIn(c.number("length_steps", 64), 1, maxSteps, clip.lengthSteps)) {
                        error = clipName + ": length_steps must be a whole number from " + range(1, maxSteps);
                        return false;
                    }
                    if (clip.lengthSteps > maxSteps - clip.startSteps) {
                        error = clipName + " ends after step " + std::to_string(maxSteps) + ", the longest song at " +
                            std::to_string(out.beatsPerBar) + " beats per bar";
                        return false;
                    }
                    if (!wholeIn(c.number("source_offset_steps", 0), 0, maxSteps, clip.sourceOffsetSteps)) {
                        error = clipName + ": source_offset_steps must be a whole number from " + range(0, maxSteps);
                        return false;
                    }
                    if (!wholeIn(c.number("loop_steps", 0), 0, maxSteps, clip.loopSteps)) {
                        error = clipName + ": loop_steps must be a whole number from " + range(0, maxSteps) +
                            " (0 loops at the pattern's length)";
                        return false;
                    }
                    clip.loop = c.boolean("loop", true);
                    clip.mute = c.boolean("mute", false);
                    if (!clip.pattern.empty()) spec.clips.push_back(std::move(clip));
                }
            }
            if (const Json* lanes = l.get("automation"); lanes && lanes->type == Json::Type::Array) {
                for (const Json& laneJson : lanes->arr) {
                    if (laneJson.type != Json::Type::Object) continue;
                    AutomationLaneSpec lane; lane.target = laneJson.string("target");
                    if (lane.target != "volume" && lane.target != "pan") continue;
                    if (!pointStepsOk(laneJson.get("points"), error, layerName + ": ")) return false;
                    if (const Json* points = laneJson.get("points"); points && points->type == Json::Type::Array) {
                        for (const Json& point : points->arr) {
                            if (point.type != Json::Type::Object) continue;
                            lane.points.push_back({point.number("step", 0),
                                clampd(point.number("value", lane.target == "volume" ? 0.8 : 0), lane.target == "volume" ? 0 : -1,
                                       lane.target == "volume" ? kMaxMixGain : 1)});  // volume: a gain to +12 dB, as the faders
                        }
                    }
                    std::stable_sort(lane.points.begin(), lane.points.end(), [](const auto& a, const auto& b) { return a.step < b.step; });
                    if (!lane.points.empty()) spec.automation.push_back(std::move(lane));
                }
            }
            spec.volume = clampd(l.number("volume", 0.8), 0, kMaxMixGain);
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
            if (lane.targetType == "instrument") {
                // {"target_type":"instrument","layer":id,"target":param}: the layer's native instrument
                lane.moduleId = laneJson.string("layer");
                lane.component = 0;
                if (lane.moduleId.empty()) continue;
            } else if (lane.targetType == "component" || lane.targetType == "noteComponent") {
                // {"target_type":"component","layer":id (absent: the master),"component":index,"target":param}
                lane.moduleId = laneJson.string("layer");
                const double index = laneJson.number("component", -1);
                if (!(index >= 0 && index < 64 && index == std::floor(index))) continue;
                lane.component = static_cast<int>(index);
            }
            if ((lane.targetType != "param" && lane.targetType != "global" && lane.targetType != "component" &&
                 lane.targetType != "instrument" && lane.targetType != "noteComponent") ||
                lane.target.empty() || (lane.targetType == "param" && lane.moduleId.empty())) continue;
            if (!pointStepsOk(laneJson.get("points"), error, "")) return false;
            if (const Json* points = laneJson.get("points"); points && points->type == Json::Type::Array) {
                for (const Json& point : points->arr) {
                    if (point.type != Json::Type::Object) continue;
                    lane.points.push_back({point.number("step", 0),
                                           clampd(point.number("value", 0), -1000000, 1000000)});
                }
            }
            std::stable_sort(lane.points.begin(), lane.points.end(),
                [](const auto& a, const auto& b) { return a.step < b.step; });
            if (!lane.points.empty()) out.automation.push_back(std::move(lane));
        }
    }

    // Project automation lengthens the loop to reach its last point (points are at most maxSteps, whole bars).
    int64_t automationEndStep = 0;
    for (const auto& lane : out.automation)
        for (const auto& point : lane.points)
            automationEndStep = std::max<int64_t>(automationEndStep, static_cast<int64_t>(std::ceil(point.step)));
    const int64_t stepsPerBar = out.beatsPerBar * 4;
    automationEndStep = std::max<int64_t>(automationEndStep, static_cast<int64_t>(std::ceil(audioEndSteps)));
    if (automationEndStep > 0)
        out.loopBars = std::max(out.loopBars, static_cast<int>((automationEndStep + stepsPerBar - 1) / stepsPerBar));
    // The song reaches the loop range's end, so playback gets there.
    if (out.loopRange)
        out.loopBars = std::max(out.loopBars, static_cast<int>((out.loopEndSteps + stepsPerBar - 1) / stepsPerBar));

    // Reject malformed parent references and cycles before the audio thread sees routing indices.
    // A chain has fewer ancestors than there are layers, so the walk is bounded by the layer count.
    const int maxDepth = static_cast<int>(out.layers.size());
    for (const LayerSpec& layer : out.layers) {
        std::string parent = layer.parentId;
        std::vector<std::string> seen{layer.id};
        for (int depth = 0; !parent.empty() && depth < maxDepth; ++depth) {
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
    // Project modulation (#161): modulators and links (modulation_links.cpp), before the routing check that orders them.
    if (!parseModulation(root, [](const Json& j, const std::string& where, ComponentSpec& c, std::string& e) {
            return componentEntry(j, where, c, e);
        }, out, error))
        return false;
    if (!validateRouting(out, error)) return false;
    if (const Json* a = root.get("audition"); a && a->type == Json::Type::Object) {
        if (!wholeIn(a->number("length_steps", 0), 0, maxSteps, out.auditionSteps)) {
            error = "audition length_steps must be a whole number from " + range(0, maxSteps);
            return false;
        }
        out.auditionPattern = a->string("pattern");
        if (!componentList(a->get("components"), "audition components", out.auditionComponents, error)) return false;
        if (const Json* inst = a->get("instrument"); inst && inst->type != Json::Type::Null) {
            if (inst->type != Json::Type::String && inst->type != Json::Type::Object) {
                error = "audition instrument must be a component id or {\"id\": ...}";
                return false;
            }
            if (!componentEntry(*inst, "audition instrument", out.auditionInstrument, error)) return false;
            out.hasAuditionInstrument = true;
        }
    }
    out.auditionOnly = root.boolean("audition_only", false) && out.hasAuditionInstrument;
    return true;
}

bool readTempoMap(const Json& a, std::vector<TempoPointSpec>& out, std::string& error) {
    if (a.type != Json::Type::Array || a.arr.empty() || a.arr.size() > static_cast<size_t>(kMaxTempoPoints)) {
        error = "tempo_map must be a list of 1 to " + std::to_string(kMaxTempoPoints) + " {\"beat\", \"bpm\", \"ramp\"}";
        return false;
    }
    std::vector<TempoPointSpec> pts;
    pts.reserve(a.arr.size());
    for (const Json& j : a.arr) {
        const Json* beat = j.type == Json::Type::Object ? j.get("beat") : nullptr;
        const Json* bpm = j.type == Json::Type::Object ? j.get("bpm") : nullptr;
        if (!beat || !bpm || beat->type != Json::Type::Number || bpm->type != Json::Type::Number) {
            error = "each tempo_map point needs a numeric \"beat\" and \"bpm\"";
            return false;
        }
        pts.push_back({beat->num, bpm->num, j.boolean("ramp", false)});
    }
    if (!checkTempoPoints(pts, error)) return false;
    out = std::move(pts);
    return true;
}

bool readTimeSigs(const Json& a, std::vector<TimeSigSpec>& out, std::string& error) {
    if (a.type != Json::Type::Array || a.arr.empty() || a.arr.size() > static_cast<size_t>(kMaxTimeSigs)) {
        error = "time_signatures must be a list of 1 to " + std::to_string(kMaxTimeSigs) +
                " {\"bar\", \"beat\", \"num\", \"den\"}";
        return false;
    }
    std::vector<TimeSigSpec> sigs;
    sigs.reserve(a.arr.size());
    for (const Json& j : a.arr) {
        const Json* bar = j.type == Json::Type::Object ? j.get("bar") : nullptr;
        const double n = j.type == Json::Type::Object ? j.number("num", -1) : -1;
        const double d = j.type == Json::Type::Object ? j.number("den", -1) : -1;
        if (!bar || bar->type != Json::Type::Number || bar->num != std::floor(bar->num) || !(bar->num >= 0 && bar->num <= 1e9) ||
            n != std::floor(n) || d != std::floor(d) || !(n >= 1 && n <= 32) || !(d >= 1 && d <= 32)) {
            error = "each time signature needs a whole \"bar\" (0 or more), \"num\" 1..32 and \"den\" 1..32";
            return false;
        }
        const Json* beat = j.get("beat");
        sigs.push_back({static_cast<int64_t>(bar->num), beat && beat->type == Json::Type::Number ? beat->num : std::nan(""),
                        static_cast<int>(n), static_cast<int>(d)});
    }
    if (!checkTimeSigs(sigs, error)) return false;
    out = std::move(sigs);
    return true;
}

std::vector<TempoPointSpec> tempoPointsOf(const ProjectSpec& p) {
    if (p.tempoMap.empty()) return {{0.0, p.bpm, false}};
    return p.tempoMap;
}

std::vector<TimeSigSpec> timeSigsOf(const ProjectSpec& p) {
    if (p.timeSigs.empty()) return {{0, 0.0, p.beatsPerBar, 4}};
    return p.timeSigs;
}

SongTime songTimeOf(const ProjectSpec& p, double sampleRate) {
    SongTime t;
    t.tempo.build(tempoPointsOf(p), sampleRate);
    t.sigs.build(timeSigsOf(p));
    return t;
}

}  // namespace caw
