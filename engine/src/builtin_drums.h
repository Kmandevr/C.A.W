// The all-in-one drum instrument ("org.caw.drums"): registration, its sound library, randomize, explode and the old drums' migration.
#pragma once

#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "module_registry.h"

namespace caw {

inline constexpr std::string_view kDrumsId = "org.caw.drums";

// Registers "org.caw.drums" ("Drums"). registerBuiltinInstruments calls it.
void registerDrums(ModuleRegistry& registry);

// The retired drums (org.caw.drum.kick, .snare, .hats, .kit): loadable only through migration to org.caw.drums.
bool isLegacyDrum(std::string_view id);
// Turns an old drum's entry into org.caw.drums with equivalent values (`preset` gets the name it is closest to).
// False, nothing changed, for another id.
bool migrateLegacyDrum(std::string& id, std::vector<std::pair<std::string, double>>& params, std::string* preset = nullptr);
// The org.caw.drums parameter an automation lane on an old drum's `param` moves now (same units), or empty.
std::string migratedLegacyDrumParameter(std::string_view legacyId, std::string_view param);
// The old knobs migrateInstrumentJson reports lanes for.
const std::vector<std::string_view>& legacyDrumKnobs(std::string_view legacyId);

// The presets the component lists (sounds on pad A1 in Single mode, then whole kits).
struct BuiltinPreset;
const std::vector<BuiltinPreset>& drumsPresets();

// The C API's JSON (caw.h, API 11; docs/engine.md "Drums").
std::string drumsInfoJson();
std::string drumsRandomizeJson(int type, uint32_t seed, double amount, int pad, std::string_view currentJson);
std::string drumsExplodeJson(std::string_view entryJson);

// A built-in one-shot (a sound of the library rendered by the engine): mono at `sampleRate`. False for an unknown name.
bool renderBuiltinDrumSample(std::string_view name, double sampleRate, std::vector<float>& out);
// The names renderBuiltinDrumSample knows.
std::vector<std::string> builtinDrumSampleNames();

}  // namespace caw
