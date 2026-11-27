// Shared helpers for the mixer tests (engine_*_test.cpp): test-signal projects, a block-wise render, the largest step.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <string>
#include <vector>

#include "engine.h"
#include "test_signal.h"

namespace engine_test {

using namespace caw;

using cawtest::Shape;

// A track's test signal (test_signal.h): its shape and values.
struct Signal {
    Shape shape;
    cawtest::Params params;
};
inline Signal dc(double level) { return {Shape::Dc, {{"level", level}}}; }
inline Signal sine(double hz, double level = 1.0) { return {Shape::Sine, {{"freq", hz}, {"level", level}}}; }

// One track per signal (l0, l1, ...), volume 1 and centred, in a project with master gain 1.
inline ProjectSpec project(std::vector<Signal> signals, int bars = 1, double bpm = 120) {
    std::vector<LayerSpec> layers;
    for (size_t i = 0; i < signals.size(); ++i)
        layers.push_back(cawtest::testSignalLayer("l" + std::to_string(i), signals[i].shape, signals[i].params));
    return cawtest::testSignalProject(std::move(layers), bpm, bars);
}

// A one-bar project whose one track (l0) holds a note through the loop on the test signal (Notes mode), so a Stop
// ends it: a free-running signal ignores notes and rings on after a Stop like any instrument still sounding.
inline ProjectSpec heldProject(Signal s) {
    ProjectSpec p = project({});
    p.modules.push_back({"hold", "---\nkind: pattern\nlength: 16\n---\n0 C4 16 1\n"});
    p.layers.push_back(cawtest::testSignalNotesLayer("l0", s.shape, "hold", s.params));
    return p;
}

inline std::vector<float> run(Engine& e, int64_t frames, int block = 64, std::vector<float>* right = nullptr) {
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += block) {
        const int n = static_cast<int>(std::min<int64_t>(block, frames - i));
        e.process(l.data() + i, r.data() + i, n);
    }
    if (right) *right = r;
    return l;
}

inline float maxStep(const std::vector<float>& v, size_t from, size_t to) {
    float m = 0;
    for (size_t i = from + 1; i < to && i < v.size(); ++i) m = std::max(m, std::fabs(v[i] - v[i - 1]));
    return m;
}

}  // namespace engine_test
