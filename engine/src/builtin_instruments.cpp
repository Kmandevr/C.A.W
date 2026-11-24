// Built-in C++ instruments: Drums (builtin_drums.cpp) and Flagship (builtin_flagship.cpp), registered in every Engine.
#include "builtin_instruments.h"
#include "builtin_drums.h"
#include "builtin_flagship.h"
#include "builtin_timber.h"
#include "builtin_starling.h"
#include "builtin_nightingale.h"
#include "builtin_curlew.h"
#include "builtin_bittern.h"
#include "builtin_woodpecker.h"
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
    starling::registerStarling(registry);  // org.caw.starling (builtin_starling.cpp, 1.1.3)
    nightingale::registerNightingale(registry);  // org.caw.nightingale (builtin_nightingale.cpp, 1.1.3)
    curlew::registerCurlew(registry);  // org.caw.curlew (builtin_curlew.cpp, 1.1.3)
    bittern::registerBittern(registry);  // org.caw.bittern (builtin_bittern.cpp, 1.1.3)
    woodpecker::registerWoodpecker(registry);  // org.caw.woodpecker (builtin_woodpecker.cpp, 1.1.3)
    registerSampler(registry);        // org.caw.sampler (builtin_sampler.cpp)
    flock::registerFlock(registry);   // org.caw.flock (builtin_flock.cpp, 1.1.0)
    registerAudioTrack(registry);     // org.caw.audio-track: audio clips and input (audio_clips.cpp)
}

}  // namespace caw
