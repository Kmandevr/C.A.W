// Built-in C++ instruments: Drums (builtin_drums.cpp) and Flagship (builtin_flagship.cpp), registered in every Engine.
#include "builtin_instruments.h"
#include "builtin_drums.h"
#include "builtin_flagship.h"

namespace caw {

// The old drums (org.caw.drum.kick, .snare, .hats, .kit) became org.caw.drums (2026-11-11, owner: "one drum
// instrument"); the retired synths are Flagship presets. Both load only through migration (presets.h).
void registerBuiltinInstruments(ModuleRegistry& registry) {
    registerDrums(registry);          // org.caw.drums
    registerFlagshipSynth(registry);  // org.caw.synth.flagship
}

}  // namespace caw
