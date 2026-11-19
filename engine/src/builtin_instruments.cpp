// Built-in C++ instruments: Drums (builtin_drums.cpp) and Flagship (builtin_flagship.cpp), registered in every Engine.
#include "builtin_instruments.h"
#include "builtin_drums.h"
#include "builtin_flagship.h"
#include "builtin_timber.h"
#include "builtin_flock.h"
#include "audio_clips.h"
#include "builtin_sampler.h"

namespace caw {

// The old drums (org.caw.drum.kick, .snare, .hats, .kit) became org.caw.drums (2026-11-11, owner: "one drum
// instrument"); the retired synths are Flagship presets. Both load only through migration (presets.h).
void registerBuiltinInstruments(ModuleRegistry& registry) {
    registerDrums(registry);          // org.caw.drums
    registerFlagshipSynth(registry);  // org.caw.synth.flagship
    timber::registerTimber(registry);  // org.caw.timber (builtin_timber.cpp, 1.1.0)
    registerSampler(registry);        // org.caw.sampler (builtin_sampler.cpp)
    flock::registerFlock(registry);   // org.caw.flock (builtin_flock.cpp, 1.1.0)
    registerAudioTrack(registry);     // org.caw.audio-track: audio clips and input (audio_clips.cpp)
}

}  // namespace caw
