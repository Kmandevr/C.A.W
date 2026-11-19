// The patch model on the audio thread: running, swapping (kept nodes, new feedback) and Play allocate nothing.
#include <string>
#include <vector>

#include <caw/instrument.hpp>

#include "alloc_counter.h"
#include "builtin_components.h"
#include "patch.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

ComponentSpec component(std::string id) {
    ComponentSpec c;
    c.id = std::move(id);
    return c;
}

PatchWireSpec wire(std::string fromNode, std::string fromPort, std::string toNode, std::string toPort, double gain = 1.0,
                   bool feedback = false) {
    PatchWireSpec w;
    w.from = {std::move(fromNode), std::move(fromPort)};
    w.to = {std::move(toNode), std::move(toPort)};
    w.gain = gain;
    w.feedback = feedback;
    return w;
}

// Two versions of one patch: the second keeps every node and adds a feedback wire, a gain and an optional output.
PatchSpec version(bool second) {
    PatchSpec s;
    s.nodes = {{"in", PatchNodeKind::Input, {}},
               {"lim", PatchNodeKind::Module, {component("org.caw.limiter")}},
               {"u", PatchNodeKind::Module, {component("org.caw.utility")}},
               {"bus", PatchNodeKind::Chain, {component("org.caw.chorus"), component("org.caw.reverb")}},
               {"synth", PatchNodeKind::Module, {cawtest::testSignal(cawtest::Shape::Saw, {{"mode", 1}})}},
               {"out", PatchNodeKind::Output, {}}};
    s.wires = {wire("in", "out", "lim", "in"), wire("lim", "out", "u", "in"), wire("u", "out", "bus", "in"),
               wire("synth", "out", "bus", "in", 0.3), wire("bus", "out", "out", "in")};
    if (second) {
        s.wires.push_back(wire("bus", "out", "bus", "in", 0.5, true));
        s.wires.push_back(wire("u", "side", "out", "in", 0.25));
        s.wires.push_back(wire("in", "out", "out", "in", 0.5));
    }
    return s;
}

}  // namespace

TEST(a_patch_runs_swaps_and_plays_without_allocating_on_the_audio_thread) {
    std::string error;
    auto first = compilePatch(registry(), version(false), 48000, nullptr, error);
    CHECK(first != nullptr);
    if (!first) return;
    PatchRuntime runtime;
    CHECK(runtime.publish(first.get()));
    std::vector<float> inL(1024, 0.1f), inR(1024, -0.1f), outL(1024), outR(1024);
    const Event on[] = {notes::noteOn(0, 1, 48, 0.8)}, off[] = {notes::noteOff(0, 1, 48)};
    const EventInput notes[] = {{on, 1}, {off, 1}};
    for (int k = 0; k < 20; ++k)
        CHECK(runtime.process(inL.data(), inR.data(), outL.data(), outR.data(), 256, k % 4 < 2 ? &notes[k % 2] : nullptr));
    // The second version, compiled on this (control) thread from the first one, which plays on meanwhile.
    auto second = compilePatch(registry(), version(true), 48000, first.get(), error);
    CHECK(second != nullptr);
    if (!second) return;
    CHECK_EQ(second->keptNodes(), 4u);
    CHECK(runtime.publish(second.get()));
    std::size_t operations = 0;
    {
        cawtest::AllocationScope scope;
        runtime.markPlay();
        const uint32_t sizes[] = {1, 7, 64, 333, 1024, 16, 5};
        for (int k = 0; k < 40; ++k) {
            const uint32_t n = sizes[k % 7];
            CHECK(runtime.process(inL.data(), inR.data(), outL.data(), outR.data(), n, k % 3 ? nullptr : &notes[k % 2]));
            if (k == 20) second->reset();
        }
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(runtime.collectRetired() == first.get());
    first.reset();  // destroyed off the audio thread; the kept instances live on in `second`
    CHECK(runtime.process(inL.data(), inR.data(), outL.data(), outR.data(), 64));
    CHECK(runtime.takeActiveAfterStop() == second.get());
}
