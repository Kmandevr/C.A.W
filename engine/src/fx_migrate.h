// The FX consolidation's migration (1.0.8): an effect id a merged device replaces becomes that device, its variant and its parameters.
#pragma once

#include <span>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "module.h"
#include "project.h"

namespace caw {

struct BuiltinPreset;

namespace fx {

// An old value as the merged device's (both in their parameters' own units).
using ValueMap = double (*)(double) noexcept;

// One parameter of an old effect that changes on the way: renamed, its value mapped, or dropped. A parameter the
// table doesn't list keeps its id and value (old ids are kept verbatim where they don't collide).
struct ParamMove {
    std::string_view from;       // the old effect's parameter id
    std::string_view to;         // its id in the merged device; empty: dropped (and a lane on it with it)
    ValueMap value = nullptr;    // old value to new; null: the same value
    bool lanes = true;           // false: a lane or modulation link on it is dropped (the units or the curve differ)
};

// A fixed value the merged device needs to sound as the old effect did (a new shared parameter whose default
// doesn't, as an "output" the old effect lacked). A value the entry already names wins.
struct ParamSet {
    std::string_view id;
    double value;
};

// One old effect id: the merged device it becomes and how.
struct LegacyEffect {
    std::string_view from;                // the old id ("org.caw.pitchshift")
    std::string_view to;                  // the merged device's id (fx_merged.h)
    uint32_t variant = 0;                 // its `variant` there
    std::span<const ParamMove> params{};  // the parameters that change (any other keeps its id)
    std::span<const ParamSet> sets{};     // values added so it sounds the same
    bool keepsState = true;               // the variant's class reads the old saved state (else it is dropped)
    // The old effect's own descriptor (its parameter list, for a rack's route destinations), so the migration needs
    // no registration of the old id once it is retired; null: looked up in the built-in registry.
    const ModuleDescriptor& (*legacy)() = nullptr;
};

// The families' tables (each family file defines its own; empty until its part is built).
std::span<const LegacyEffect> legacyDynamicsEffects();   // fx_migrate_dynamics.cpp
std::span<const LegacyEffect> legacyDriveEffects();      // fx_migrate_drive.cpp
std::span<const LegacyEffect> legacyEqFilterEffects();   // fx_migrate_eqfilter.cpp
std::span<const LegacyEffect> legacyStereoModEffects();  // fx_migrate_stereomod.cpp
std::span<const LegacyEffect> legacySpaceEffects();      // fx_migrate_space.cpp

// The table entry for an old id, or null (an id no merged device replaces).
const LegacyEffect* findLegacyEffect(std::string_view id) noexcept;

// How the parameters of one entry were renamed: {old id, new id} for every parameter whose id changed or that was
// dropped (new id empty: drop a lane or link on it). A rack's children appear as "<slot>.<id>".
using ParamRenames = std::vector<std::pair<std::string, std::string>>;

// Migrates one entry in place: an old id becomes its merged device (`variant` set, parameters moved, fixed values
// added, the state kept or dropped), and a rack's children that are old ids become theirs (`<slot>_fx`,
// `<slot>.variant`, `<slot>.<param>` and the routes' destinations). `renames`, if given, gets the parameter
// renames for its lanes. A rack without today's layout version (kRackLayoutParam, builtin_fx_racks.h) is older than
// the merged devices: a child that is a merged device's own id with no `<slot>.variant` (an old effect whose id was
// reused, as org.caw.utility) gets `<slot>.variant` 0, the routes are re-pointed past its new `variant`, and the
// version is added. False, with nothing changed, when there was nothing to migrate (a current rack: never twice).
bool migrateLegacyEffect(ComponentSpec& spec, ParamRenames* renames = nullptr);

// Whether any component list of the project (master, layers' components and noteComponents, the audition's)
// holds an old id, directly or in a rack.
bool hasLegacyEffects(const ProjectSpec& project);

// Migrates every component list of the project, and moves the automation lanes and modulation links on those
// components to the renamed parameters (dropping those whose parameter has no counterpart in the same units).
// Engine::setProjectImpl calls it. True when anything changed.
bool migrateLegacyEffects(ProjectSpec& project);

// The JSON result of caw_migrate_component for an entry {"id", "params", "preset"}: {"ok": true, "migrated": bool,
// "id", "params": {...}, "renamed": {old: new}, "dropped": [old...], "keeps_state": bool}. A lane or link on a
// parameter in neither list keeps its target.
std::string migrateComponentJson(std::string_view entryJson);

// A merged device's presets: every old effect's it replaces, migrated (null for an id that isn't merged). The
// names stay the old ones.
const std::vector<BuiltinPreset>* mergedPresets(std::string_view id);

}  // namespace fx
}  // namespace caw
