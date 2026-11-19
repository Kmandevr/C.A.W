// 1.1.0's voice devices' registration and preset lists: Glint (merged), Mimic, and Soar's appended variants' presets.
#include "builtin_fx_voice.h"

#include "presets.h"

namespace caw::fx {

void registerVoice(ModuleRegistry&) {}

const std::vector<BuiltinPreset>* voicePresets(std::string_view id) {
    if (id == "org.caw.exciter") return &exciterPresets();
    return nullptr;
}

std::span<const BuiltinPreset> newVoiceVariantPresets(std::string_view) { return {}; }

}  // namespace caw::fx
