// Test helpers for org.caw.test.osc (builtin_test_signal.h): a track playing a test signal in place of a .caw source.
#pragma once

#include <string>
#include <utility>
#include <vector>

#include "builtin_test_signal.h"
#include "project.h"

namespace cawtest {

enum class Shape { Sine = 0, Saw = 1, Square = 2, Noise = 3, Dc = 4, Impulse = 5, Sweep = 6 };

using Params = std::vector<std::pair<std::string, double>>;

// The test signal as a component: `shape`, then `params` (any of builtin_test_signal.h's ids; later ones win).
// Free mode unless params set "mode" to 1.
inline caw::ComponentSpec testSignal(Shape shape, Params params = {}) {
    caw::ComponentSpec c;
    c.id = std::string(caw::kTestSignalId);
    c.params.push_back({"shape", static_cast<double>(shape)});
    for (auto& p : params) c.params.push_back(std::move(p));
    return c;
}

// A track that plays the test signal as its instrument, volume 1 and centred (the mixer's centre pan gain,
// cos(pi/4), still applies). Free mode plays from the first block after Play, with no pattern needed.
inline caw::LayerSpec testSignalLayer(const std::string& id, Shape shape, Params params = {},
                                      std::vector<caw::ComponentSpec> components = {}) {
    caw::LayerSpec l;
    l.id = id;
    l.name = id;
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument = testSignal(shape, std::move(params));
    l.components = std::move(components);
    return l;
}

// The same in Notes mode, played by the pattern module `pattern` (pitch from each note, level times velocity).
inline caw::LayerSpec testSignalNotesLayer(const std::string& id, Shape shape, const std::string& pattern,
                                           Params params = {}, std::vector<caw::ComponentSpec> components = {}) {
    params.insert(params.begin(), {"mode", 1.0});
    caw::LayerSpec l = testSignalLayer(id, shape, std::move(params), std::move(components));
    l.pattern = pattern;
    return l;
}

// A project of the given layers at `bpm` and `bars`, master gain 1 (bypass the master chain with
// Engine::setMasterBypass for exact values).
inline caw::ProjectSpec testSignalProject(std::vector<caw::LayerSpec> layers, double bpm = 120, int bars = 4) {
    caw::ProjectSpec p;
    p.bpm = bpm;
    p.loopBars = bars;
    p.master = 1.0;
    p.layers = std::move(layers);
    return p;
}

}  // namespace cawtest
