// 1.1.0's voice devices' registration and preset lists: Glint (merged) and Mimic.
#include "builtin_fx_voice.h"

#include "presets.h"

namespace caw::fx {

void registerVoice(ModuleRegistry&) { warmShiftVoices(); }

const std::vector<BuiltinPreset>* voicePresets(std::string_view id) {
    if (id == "org.caw.exciter") return &exciterPresets();
    return nullptr;
}


}  // namespace caw::fx
