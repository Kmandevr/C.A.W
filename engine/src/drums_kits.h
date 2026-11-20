// Rook's kit builders (1.1.2): Synth kits from a seed and a style, Produced kits from role templates, Acoustic kits from a shelf of pieces, e-drum note maps and the finishing tools.
#pragma once

#include <cstdint>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

namespace caw {

struct BuiltinPreset;

namespace drums {

enum BuildKind : int { kBuildSynth, kBuildProduced, kBuildAcoustic, kBuildKindCount };
enum EdrumMap : int { kMapGeneralMidi, kMapRoland, kMapAlesis, kMapCount };

// The styles each kind's builder offers (8 each), and the e-drum maps an Acoustic kit can follow.
const std::vector<std::string_view>& buildStyles(int kind);
const std::vector<std::string_view>& edrumMapNames();

// A kit's values: every parameter it moves from the descriptor's defaults (index, value), as a preset holds them.
struct BuiltKit {
    std::string name, description;
    std::vector<std::pair<uint32_t, double>> values;
};
// Builds a kit (pure: the same arguments give the same kit). key: 0..11 (C..B) tunes it to that key's natural minor,
// -1 leaves it. map: an Acoustic kit's note layout (EdrumMap). match: level-match every pad by rendering it (the C API
// does; presets don't, so listing them stays cheap). False for an unknown kind or style.
bool buildKit(int kind, int style, uint32_t seed, int key, int map, bool match, BuiltKit& out);

}  // namespace drums

// The C API's JSON (caw.h, API 46): caw_drums_kit_build and caw_drums_kit_tool.
std::string drumsKitBuildJson(int kind, int style, uint32_t seed, int key, int map);
std::string drumsKitToolJson(std::string_view requestJson);
// The built-in kit presets of 1.1.2 (8 Synth, 8 Produced, 8 Acoustic), appended after the older presets.
void appendBuiltKitPresets(std::vector<BuiltinPreset>& out);
// The builders' choices for caw_drums_info: {"synth": [...], "produced": [...], "acoustic": [...], "maps": [...]}.
std::string drumsBuildersJson();

}  // namespace caw
