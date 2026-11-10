// Built-in presets (named parameter sets of built-in components) and the migration of the retired synths to Flagship presets.
#pragma once

#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace caw {

// A named set of parameter values for a built-in component. Parameters it doesn't name keep their defaults.
struct BuiltinPreset {
    std::string_view name;
    std::string_view description;
    std::vector<std::pair<std::string_view, double>> values;
};

// The presets of a built-in component, in display order (empty for one without presets).
const std::vector<BuiltinPreset>& builtinPresets(std::string_view componentId);

// The preset of that name, or null.
const BuiltinPreset* findBuiltinPreset(std::string_view componentId, std::string_view name);

// Puts the preset's values under `params`: a value `params` already names wins (an entry's own knobs over its
// preset). False (and `params` unchanged) when there is no such preset.
bool applyBuiltinPreset(std::string_view componentId, std::string_view name,
                        std::vector<std::pair<std::string, double>>& params);

// The presets as a JSON array: [{"name": ..., "description": ..., "params": {id: value}}].
std::string builtinPresetsJson(std::string_view componentId);

// The synths that became Flagship presets (2026-11-10, owner: "one synth"): org.caw.synth.morph ("Morph pad"),
// org.caw.bass ("Mono bass"), org.caw.synth.acid ("Acid 303") and org.caw.synth.basic ("Basic").
bool isLegacyInstrument(std::string_view id);

// Turns a retired synth's entry into Flagship's: `id` becomes org.caw.synth.flagship and `params` the preset's
// values with the old knobs mapped onto Flagship's (`preset`, if given, gets the preset's name). False, with
// nothing changed, for any other id.
bool migrateLegacyInstrument(std::string& id, std::vector<std::pair<std::string, double>>& params,
                             std::string* preset = nullptr);

// The Flagship parameter an automation lane on a retired synth's `param` moves now, when the old knob maps onto
// one Flagship knob in the same units (cutoff, attack, glide...); empty when it doesn't (the lane is dropped).
std::string migratedLegacyParameter(std::string_view legacyId, std::string_view param);

// The JSON result of caw_migrate_instrument: {"ok": true, "migrated": bool, "id": ..., "preset": ...,
// "params": {...}} for an entry {"id": ..., "params": {...}, "preset": ...}: a retired synth migrated, or an
// entry naming a preset with the preset's values under its params.
std::string migrateInstrumentJson(std::string_view entryJson);

}  // namespace caw
