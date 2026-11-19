// The AutoStacc beta pack's registration, pack mark and preset lists (Murmur, Peck, Bend, Iris).
#include "builtin_pack.h"

#include "caw/library/grain.hpp"
#include "presets.h"

namespace caw::fx {

void registerPack(ModuleRegistry& registry) {
    (void)lib::grain::windows();  // the shared window tables, built here so no grain ever builds them
    registerMurmur(registry);
}

std::string_view packOf(std::string_view id) noexcept {
    if (id == "org.caw.pack.granular" || id == "org.caw.pack.glitch" || id == "org.caw.pack.warp" ||
        id == "org.caw.pack.spectral")
        return kAutoStaccBetaPack;
    return {};
}

const std::vector<BuiltinPreset>* packPresets(std::string_view id) {
    if (id == "org.caw.pack.granular") return &murmurPresets();
    return nullptr;
}

}  // namespace caw::fx
