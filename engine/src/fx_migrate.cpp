// The FX consolidation's migration (1.0.8): old effect ids to merged devices in entries, racks, lanes, links and presets.
#include "fx_migrate.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <deque>
#include <map>

#include "builtin_components.h"
#include "builtin_fx_racks.h"
#include "builtin_fx_voice.h"
#include "fx_merged.h"
#include "json.h"
#include "presets.h"

namespace caw {
namespace fx {

namespace {

using Values = std::vector<std::pair<std::string, double>>;

const ModuleRegistry& builtins() {
    static const ModuleRegistry registry = [] {
        ModuleRegistry r;
        registerBuiltinComponents(r);
        return r;
    }();
    return registry;
}

const LegacyEffect* legacyByHash(uint32_t hash) noexcept {
    for (const LegacyEffect* e : legacyEffects())
        if (rackChildHash(e->from) == hash) return e;
    return nullptr;
}

bool endsWith(std::string_view s, std::string_view tail) noexcept {
    return s.size() >= tail.size() && s.compare(s.size() - tail.size(), tail.size(), tail) == 0;
}

uint32_t hashValue(double v) noexcept { return std::isfinite(v) && v > 0.0 ? static_cast<uint32_t>(v + 0.5) : 0u; }

double* find(Values& values, std::string_view name) noexcept {
    for (auto& [k, v] : values)
        if (k == name) return &v;
    return nullptr;
}

double valueOf(const Values& values, std::string_view name, double fallback) noexcept {
    for (const auto& [k, v] : values)
        if (k == name) fallback = v;
    return fallback;
}

void set(Values& values, std::string_view name, double v) {
    if (double* at = find(values, name)) *at = v;
    else values.emplace_back(std::string(name), v);
}

// One old effect's values (under `prefix`: "" for an entry, "<slot>." for a rack's child) moved to its merged
// device's, and its renames recorded.
void moveParams(const LegacyEffect& e, Values& values, const std::string& prefix, ParamRenames& renames) {
    for (const ParamMove& m : e.params) {
        const std::string from = prefix + std::string(m.from);
        const std::string to = m.to.empty() ? std::string() : prefix + std::string(m.to);
        if (to != from || !m.lanes) renames.emplace_back(from, m.lanes ? to : std::string());
    }
    Values out;
    out.reserve(values.size() + e.sets.size() + 1);
    for (auto& [name, v] : values) {
        if (name.compare(0, prefix.size(), prefix) != 0) {  // another slot's, or the rack's own
            out.emplace_back(std::move(name), v);
            continue;
        }
        const std::string_view own = std::string_view(name).substr(prefix.size());
        if (own == kVariantParam) continue;  // set below
        const ParamMove* move = nullptr;
        for (const ParamMove& m : e.params)
            if (m.from == own) move = &m;
        if (!move) {
            out.emplace_back(std::move(name), v);
            continue;
        }
        if (move->to.empty()) continue;  // dropped
        out.emplace_back(prefix + std::string(move->to), move->value ? move->value(v) : v);
    }
    for (const ParamSet& s : e.sets)
        if (!find(out, prefix + std::string(s.id))) out.emplace_back(prefix + std::string(s.id), s.value);
    out.emplace_back(prefix + std::string(kVariantParam), static_cast<double>(e.variant));
    values = std::move(out);
}

const LayoutDevice* layoutDevice(std::string_view id) noexcept {
    for (const LayoutDevice& d : layoutDevices())
        if (d.id == id) return &d;
    return nullptr;
}

bool hasMarker(const LayoutDevice& d, const Values& values, const std::string& prefix) noexcept {
    return !std::isnan(valueOf(values, prefix + std::string(d.marker), NAN));
}

// An older entry's `variant` among the device's old variants (rounded and held, as variantIndex was then).
uint32_t oldVariant(const LayoutDevice& d, const Values& values, const std::string& prefix) noexcept {
    const double v = valueOf(values, prefix + std::string(kVariantParam), 0.0);
    if (!std::isfinite(v) || v < 0.0 || d.oldCount == 0) return 0;
    const double last = static_cast<double>(d.oldCount - 1);
    return static_cast<uint32_t>(std::floor((v > last ? last : v) + 0.5));
}

// The index of `variant` in a descriptor's list (its count when it has none).
uint32_t variantAt(const ModuleDescriptor& d) noexcept {
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == kVariantParam) return k;
    return d.parameterCount;
}

double rackLayoutOf(const Values& values) noexcept { return valueOf(values, kRackLayoutParam, 0.0); }

// A current rack child's descriptor: the built-in with that hash (a merged device's `variant`'s).
const ModuleDescriptor* currentChild(uint32_t hash, double variant) {
    for (const ModuleDescriptor* d : builtins().builtinComponents()) {
        if (rackChildHash(d->id) != hash) continue;
        if (const MergedDevice* m = findMergedDevice(d->id)) {
            const Values v{{std::string(kVariantParam), variant}};
            return &m->variants[variantIndex(*m, v)].descriptor();
        }
        return d;
    }
    return nullptr;
}

// Whether a rack entry carries today's layout version (builtin_fx_racks.h); one without it is older than the merged
// devices.
bool currentLayout(const Values& values) noexcept { return rackLayoutOf(values) >= kRackLayoutCurrent; }

// The slots of a rack older than the merged devices whose child is a merged device's own id (one reusing an old id,
// as org.caw.utility) with no `<slot>.variant`: that child was the old effect, whose list lacked `variant`.
std::vector<std::string> preVariantSlots(const ModuleDescriptor& rack, const Values& values) {
    std::vector<std::string> out;
    if (rackLayoutOf(values) >= 2.0) return out;  // layout 2 (1.0.8) on: its merged children list `variant`
    for (uint32_t k = 0; k < rack.parameterCount; ++k) {
        const std::string_view id = rack.parameters[k].id;
        if (!endsWith(id, "_fx")) continue;
        const std::string slot(id.substr(0, id.size() - 3));
        const uint32_t hash = hashValue(valueOf(values, id, 0.0));
        if (hash == 0 || legacyByHash(hash) || !std::isnan(valueOf(values, slot + "." + std::string(kVariantParam), NAN)))
            continue;
        for (const MergedDevice* m : mergedDevices())
            if (rackChildHash(m->id) == hash) out.push_back(slot);
    }
    return out;
}

// A rack's parameter ids in its flattened order (own parameters, then each slot's child's as "<slot>.<id>"), for
// `values`; `legacy`: children that are old ids read as the old effects (else as what their hash names now), and
// the `preVariant` slots' merged children without their trailing `variant`.
std::vector<std::string> rackLayout(std::string_view rackId, const Values& values, bool legacy,
                                    const std::vector<std::string>& preVariant = {}) {
    std::vector<std::string> ids;
    const ModuleDescriptor* d = builtins().find(rackId);
    if (!d) return ids;
    uint32_t own = d->parameterCount;
    for (uint32_t k = 0; k < d->parameterCount; ++k)
        if (d->parameters[k].id == "mod1_src") own = k;
    for (uint32_t k = 0; k < own; ++k) ids.emplace_back(d->parameters[k].id);
    for (uint32_t k = 0; k < own; ++k) {
        const std::string_view id = d->parameters[k].id;
        if (!endsWith(id, "_fx")) continue;
        const std::string slot(id.substr(0, id.size() - 3));
        const uint32_t hash = hashValue(valueOf(values, id, 0.0));
        if (hash == 0) continue;
        const ModuleDescriptor* child = nullptr;
        const std::string prefix = slot + ".";
        const double variant = valueOf(values, prefix + std::string(kVariantParam), 0.0);
        const bool older = legacy && rackLayoutOf(values) < kRackLayoutCurrent;  // before 1.1.0's split
        bool merged = false;
        if (const LegacyEffect* e = legacy ? legacyByHash(hash) : nullptr) {
            child = e->legacy ? &e->legacy() : builtins().find(e->from);
        } else {
            child = currentChild(hash, variant);
            merged = child && findMergedDevice(child->id);
            // A variant that left its device since: the one it is now (the same class and parameters).
            for (const LayoutDevice& d : layoutDevices()) {
                if (!older || rackChildHash(d.id) != hash) continue;
                const uint32_t v = oldVariant(d, values, prefix);
                if (v >= d.firstMove && v - d.firstMove < d.moves.size())
                    child = currentChild(rackChildHash(d.moves[v - d.firstMove].to), d.moves[v - d.firstMove].variant);
                else
                    child = currentChild(hash, static_cast<double>(v));
            }
        }
        if (!child) continue;
        uint32_t count = child->parameterCount;
        // Before 1.1.0 a merged child's list ended at `variant` (Talon's extras and marker came after); before 1.0.8
        // it had none.
        if (older && merged) count = std::min(count, variantAt(*child) + 1);
        if (legacy && std::find(preVariant.begin(), preVariant.end(), slot) != preVariant.end())
            count = std::min(count, variantAt(*child));
        for (uint32_t c = 0; c < count; ++c) ids.push_back(slot + "." + std::string(child->parameters[c].id));
    }
    for (uint32_t k = own; k < d->parameterCount; ++k) ids.emplace_back(d->parameters[k].id);
    return ids;
}

bool migrateRack(ComponentSpec& spec, ParamRenames& renames) {
    const ModuleDescriptor* d = builtins().find(spec.id);
    if (!d) return false;
    std::vector<std::pair<std::string, const LegacyEffect*>> slots;
    for (uint32_t k = 0; k < d->parameterCount; ++k) {
        const std::string_view id = d->parameters[k].id;
        if (!endsWith(id, "_fx")) continue;
        if (const LegacyEffect* e = legacyByHash(hashValue(valueOf(spec.params, id, 0.0))))
            slots.emplace_back(std::string(id.substr(0, id.size() - 3)), e);
    }
    if (slots.empty() && currentLayout(spec.params)) return false;
    const std::vector<std::string> preVariant = preVariantSlots(*d, spec.params);
    const std::vector<std::string> before = rackLayout(spec.id, spec.params, true, preVariant);
    const size_t first = renames.size();
    for (const auto& [slot, e] : slots) {
        set(spec.params, slot + "_fx", static_cast<double>(rackChildHash(e->to)));
        moveParams(*e, spec.params, slot + ".", renames);
        if (!e->keepsState) spec.hasState = false;  // the rack's state holds each child's
    }
    for (const std::string& slot : preVariant) set(spec.params, slot + "." + std::string(kVariantParam), 0.0);
    // 1.1.0's split: an older rack's Compressor child whose variant left becomes the device it is now.
    if (!currentLayout(spec.params)) {
        for (uint32_t k = 0; k < d->parameterCount; ++k) {
            const std::string_view id = d->parameters[k].id;
            if (!endsWith(id, "_fx")) continue;
            const std::string slot(id.substr(0, id.size() - 3));
            const uint32_t hash = hashValue(valueOf(spec.params, id, 0.0));
            for (const LayoutDevice& dev : layoutDevices()) {
                if (rackChildHash(dev.id) != hash) continue;
                if (const LayoutMove* m = findLayoutMove(dev.id, spec.params, slot + ".")) {
                    set(spec.params, id, static_cast<double>(rackChildHash(m->to)));
                    set(spec.params, slot + "." + std::string(kVariantParam), static_cast<double>(m->variant));
                }
            }
        }
    }
    set(spec.params, kRackLayoutParam, kRackLayoutCurrent);  // migrated once
    const std::vector<std::string> after = rackLayout(spec.id, spec.params, false);
    // The routes' destinations: an index + 1 into the flattened list, which the new children moved.
    for (auto& [name, v] : spec.params) {
        if (name.compare(0, 3, "mod") != 0 || !endsWith(name, "_dst")) continue;
        const double at = std::floor(v + 0.5);
        if (!(at >= 1.0 && at <= static_cast<double>(before.size()))) continue;
        std::string target = before[static_cast<size_t>(at) - 1];
        for (size_t r = first; r < renames.size(); ++r)
            if (renames[r].first == target) target = renames[r].second;
        const auto it = target.empty() ? after.end() : std::find(after.begin(), after.end(), target);
        v = it == after.end() ? 0.0 : static_cast<double>(it - after.begin()) + 1.0;
    }
    return true;
}

bool needsMigration(const ComponentSpec& spec) {
    if (findLegacyEffect(spec.id)) return true;
    if (const LayoutDevice* d = layoutDevice(spec.id)) return !hasMarker(*d, spec.params, {});
    if (!isRackId(spec.id)) return false;
    if (!currentLayout(spec.params)) return true;  // older than the merged devices: re-pointed and marked
    for (const auto& [name, v] : spec.params)
        if (endsWith(name, "_fx") && name.find('.') == std::string::npos && legacyByHash(hashValue(v))) return true;
    return false;
}

// Moves the lanes and links on component `index` of a list (targetType "component" or "noteComponent", `layer` ""
// for the master) to the renamed parameters, dropping those renamed to nothing.
void moveTargets(ProjectSpec& p, std::string_view targetType, std::string_view layer, int index, const ParamRenames& renames) {
    auto renamed = [&](std::string& param) {  // false: drop it
        for (const auto& [from, to] : renames)
            if (from == param) {
                if (to.empty()) return false;
                param = to;
                return true;
            }
        return true;
    };
    auto& lanes = p.automation;
    lanes.erase(std::remove_if(lanes.begin(), lanes.end(),
                               [&](ProjectAutomationLaneSpec& l) {
                                   return l.targetType == targetType && l.moduleId == layer && l.component == index &&
                                          !renamed(l.target);
                               }),
                lanes.end());
    auto& links = p.modulation;
    links.erase(std::remove_if(links.begin(), links.end(),
                               [&](ModLinkSpec& l) {
                                   return l.target.type == targetType && l.target.layer == layer &&
                                          l.target.index == index && !renamed(l.target.param);
                               }),
                links.end());
}

bool migrateList(ProjectSpec& p, std::vector<ComponentSpec>& list, std::string_view targetType, std::string_view layer) {
    bool changed = false;
    for (size_t i = 0; i < list.size(); ++i) {
        ParamRenames renames;
        if (!migrateLegacyEffect(list[i], &renames)) continue;
        changed = true;
        if (!targetType.empty()) moveTargets(p, targetType, layer, static_cast<int>(i), renames);
    }
    return changed;
}

std::string number(double v) {
    char buf[40];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    return buf;
}

}  // namespace

const std::vector<const LegacyEffect*>& legacyEffects() {
    static const std::vector<const LegacyEffect*> all = [] {
        std::vector<const LegacyEffect*> v;
        for (std::span<const LegacyEffect> family : {legacyDynamicsEffects(), legacyDriveEffects(), legacyEqFilterEffects(),
                                                     legacyStereoModEffects(), legacySpaceEffects()})
            for (const LegacyEffect& e : family) v.push_back(&e);
        return v;
    }();
    return all;
}

const LegacyEffect* findLegacyEffect(std::string_view id) noexcept {
    for (const LegacyEffect* e : legacyEffects())
        if (e->from == id) return e;
    return nullptr;
}

bool migrateLegacyEffect(ComponentSpec& spec, ParamRenames* renames) {
    ParamRenames own;
    ParamRenames& out = renames ? *renames : own;
    if (isRackId(spec.id)) return migrateRack(spec, out);
    if (const LayoutDevice* d = layoutDevice(spec.id)) {  // 1.1.0's split
        if (hasMarker(*d, spec.params, {})) return false;
        if (const LayoutMove* m = findLayoutMove(spec.id, spec.params)) {
            spec.id = std::string(m->to);
            set(spec.params, kVariantParam, static_cast<double>(m->variant));
        } else {
            set(spec.params, d->marker, d->current);
        }
        return true;
    }
    const LegacyEffect* e = findLegacyEffect(spec.id);
    if (!e) return false;
    spec.id = std::string(e->to);
    moveParams(*e, spec.params, std::string(), out);
    if (!e->keepsState) spec.hasState = false, spec.state.clear();
    return true;
}

bool migrateLegacyId(std::string& id, std::vector<std::pair<std::string, double>>& params) {
    const LayoutDevice* d = layoutDevice(id);
    if (!findLegacyEffect(id) && !(d && !hasMarker(*d, params, {}))) return false;
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    migrateLegacyEffect(c);
    id = std::move(c.id);
    params = std::move(c.params);
    return true;
}

bool hasLegacyEffects(const ProjectSpec& project) {
    auto any = [](const std::vector<ComponentSpec>& list) { return std::any_of(list.begin(), list.end(), needsMigration); };
    if (any(project.masterComponents) || any(project.auditionComponents)) return true;
    for (const LayerSpec& l : project.layers)
        if (any(l.components) || any(l.noteComponents)) return true;
    return false;
}

bool migrateLegacyEffects(ProjectSpec& project) {
    bool changed = migrateList(project, project.masterComponents, "component", "");
    changed = migrateList(project, project.auditionComponents, "", "") || changed;  // no lanes reach the audition
    for (LayerSpec& l : project.layers) {
        changed = migrateList(project, l.components, "component", l.id) || changed;
        changed = migrateList(project, l.noteComponents, "noteComponent", l.id) || changed;
    }
    return changed;
}

const LayoutMove* findLayoutMove(std::string_view id, const std::vector<std::pair<std::string, double>>& values,
                                 const std::string& prefix) noexcept {
    const LayoutDevice* d = layoutDevice(id);
    if (!d) return nullptr;
    const uint32_t v = oldVariant(*d, values, prefix);
    return v >= d->firstMove && v - d->firstMove < d->moves.size() ? &d->moves[v - d->firstMove] : nullptr;
}

bool applyMovedPreset(std::string_view id, std::string_view name, std::vector<std::pair<std::string, double>>& params) {
    const LayoutDevice* d = layoutDevice(id);
    if (!d) return false;
    for (size_t k = 0; k < d->moves.size(); ++k) {
        const LayoutMove& m = d->moves[k];
        const std::vector<BuiltinPreset>* list = mergedPresets(m.to);
        if (!list) continue;
        for (const BuiltinPreset& p : *list) {
            if (p.name != name) continue;
            double variant = 0.0;
            for (const auto& [key, v] : p.values)
                if (key == kVariantParam) variant = v;
            if (static_cast<uint32_t>(variant + 0.5) != m.variant) continue;
            Values out;
            for (const auto& [key, v] : p.values)
                if (key != kVariantParam) out.emplace_back(std::string(key), v);
            out.emplace_back(std::string(kVariantParam), static_cast<double>(d->firstMove + k));  // its 1.0.9 index
            for (const auto& [key, v] : params) set(out, key, v);
            params = std::move(out);
            return true;
        }
    }
    return false;
}

std::string migrateComponentJson(std::string_view entryJson) {
    Json j;
    std::string error;
    if (!parseJson(entryJson, j, error) || j.type != Json::Type::Object)
        return "{\"ok\":false,\"error\":\"" + jsonEscape(error.empty() ? "an entry must be an object" : error) + "\"}";
    ComponentSpec spec;
    spec.id = j.string("id");
    if (spec.id.empty()) return R"({"ok":false,"error":"an entry needs an \"id\""})";
    if (const Json* ps = j.get("params"); ps && ps->type == Json::Type::Object)
        for (const auto& [k, v] : ps->obj)
            if (v.type == Json::Type::Number && std::isfinite(v.num)) spec.params.emplace_back(k, v.num);
    if (const Json* named = j.get("preset"); named && named->type == Json::Type::String)
        if (!applyBuiltinPreset(spec.id, named->str, spec.params))
            return "{\"ok\":false,\"error\":\"" + jsonEscape("'" + spec.id + "' has no preset '" + named->str + "'") + "\"}";
    ParamRenames renames;
    spec.hasState = true;  // cleared when the variant can't read the old state
    const bool migrated = migrateLegacyEffect(spec, &renames);
    std::string json = std::string("{\"ok\":true,\"migrated\":") + (migrated ? "true" : "false") + ",\"id\":\"" +
                       jsonEscape(spec.id) + "\",\"params\":{";
    for (size_t i = 0; i < spec.params.size(); ++i)
        json += (i ? ",\"" : "\"") + jsonEscape(spec.params[i].first) + "\":" + number(spec.params[i].second);
    json += "},\"renamed\":{";
    bool first = true;
    for (const auto& [from, to] : renames)
        if (!to.empty()) json += (first ? "\"" : ",\"") + jsonEscape(from) + "\":\"" + jsonEscape(to) + "\"", first = false;
    json += "},\"dropped\":[";
    first = true;
    for (const auto& [from, to] : renames)
        if (to.empty()) json += (first ? "\"" : ",\"") + jsonEscape(from) + "\"", first = false;
    json += std::string("],\"keeps_state\":") + (spec.hasState ? "true" : "false");
    return json + "}";
}

const std::vector<BuiltinPreset>* mergedPresets(std::string_view id) {
    static const std::map<std::string, std::vector<BuiltinPreset>, std::less<>> all = [] {
        static std::deque<std::string> strings;  // the presets' ids, for the program's life
        std::map<std::string, std::vector<BuiltinPreset>, std::less<>> m;
        // A reused id's own presets first (variant 0 is the old effect), then each old effect's, migrated.
        for (const MergedDevice* d : mergedDevices()) {
            std::vector<BuiltinPreset>& list = m[std::string(d->id)];
            for (const BuiltinPreset& p : ownBuiltinPresets(d->id)) {
                BuiltinPreset out = p;
                bool named = false;
                for (const auto& [k, v] : out.values) named = named || k == kVariantParam;
                if (!named) out.values.emplace_back(kVariantParam, 0.0);
                list.push_back(std::move(out));
            }
        }
        for (const LegacyEffect* e : legacyEffects()) {
            auto it = m.find(e->to);
            if (it == m.end()) continue;
            for (const BuiltinPreset& p : ownBuiltinPresets(e->from)) {
                ComponentSpec c;
                c.id = std::string(e->from);
                for (const auto& [k, v] : p.values) c.params.emplace_back(std::string(k), v);
                migrateLegacyEffect(c);
                BuiltinPreset out{p.name, p.description, {}};
                for (auto& [k, v] : c.params) out.values.emplace_back(strings.emplace_back(std::move(k)), v);
                it->second.push_back(std::move(out));
            }
        }
        // Then the presets of variants with new DSP, as they are (each names its `variant`).
        for (const MergedDevice* d : mergedDevices())
            for (const BuiltinPreset& p : newVariantPresets(d->id)) m[std::string(d->id)].push_back(p);
        for (const MergedDevice* d : mergedDevices())  // the EQ's and Filter's 1.1.0 modes (builtin_fx_eq_plume.cpp)
            for (const BuiltinPreset& p : newEqFilterVariantPresets(d->id)) m[std::string(d->id)].push_back(p);
        for (const MergedDevice* d : mergedDevices())  // Pitch/Shift's Harmonizer and Octaver (builtin_fx_voice.h)
            for (const BuiltinPreset& p : newVoiceVariantPresets(d->id)) m[std::string(d->id)].push_back(p);
        // A device with a layout marker: every preset carries it (so applying one never reads as an older entry).
        for (const LayoutDevice& d : layoutDevices())
            for (BuiltinPreset& p : m[std::string(d.id)]) {
                bool has = false;
                for (const auto& [k, v] : p.values) has = has || k == d.marker;
                if (!has) p.values.emplace_back(d.marker, d.current);
            }
        return m;
    }();
    const auto it = all.find(id);
    return it == all.end() ? nullptr : &it->second;
}

}  // namespace fx
}  // namespace caw
