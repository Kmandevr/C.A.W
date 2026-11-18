// Times a linear patch against today's chain of the same effects (routing plan step 3: within 5%); release builds.
#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "builtin_components.h"
#include "component_chain.h"
#include "patch.h"

using namespace caw;

namespace {

ComponentSpec component(const char* id) {
    ComponentSpec c;
    c.id = id;
    return c;
}

// Seconds of 64-frame blocks through `run`, best of `rounds`, as ns per block.
template <class Run>
double best(int rounds, int blocks, Run&& run) {
    double fastest = 1e300;
    for (int r = 0; r < rounds; ++r) {
        const auto t0 = std::chrono::steady_clock::now();
        for (int b = 0; b < blocks; ++b) run(b);
        const auto t1 = std::chrono::steady_clock::now();
        fastest = std::min(fastest, std::chrono::duration<double, std::nano>(t1 - t0).count() / blocks);
    }
    return fastest;
}

}  // namespace

int main(int argc, char** argv) {
    const int seconds = argc > 1 ? std::max(1, std::atoi(argv[1])) : 10;
    const int rounds = argc > 2 ? std::max(1, std::atoi(argv[2])) : 7;
    ModuleRegistry registry;
    registerBuiltinComponents(registry);
    const std::vector<ComponentSpec> effects = {component("org.caw.eq"),      component("org.caw.compressor"),
                                                component("org.caw.drive"),   component("org.caw.chorus"),
                                                component("org.caw.utility"), component("org.caw.delay"),
                                                component("org.caw.reverb")};
    std::string error;
    auto chain = ComponentChain::build(registry, effects, 48000, error);
    PatchSpec modules, wrapped;
    modules.nodes.push_back({"in", PatchNodeKind::Input, {}});
    std::string last = "in";
    for (size_t k = 0; k < effects.size(); ++k) {
        const std::string id = "fx" + std::to_string(k);
        modules.nodes.push_back({id, PatchNodeKind::Module, {effects[k]}});
        PatchWireSpec w;
        w.from = {last, "out"};
        w.to = {id, "in"};
        modules.wires.push_back(w);
        last = id;
    }
    modules.nodes.push_back({"out", PatchNodeKind::Output, {}});
    PatchWireSpec end;
    end.from = {last, "out"};
    end.to = {"out", "in"};
    modules.wires.push_back(end);
    wrapped.nodes = {{"in", PatchNodeKind::Input, {}}, {"inserts", PatchNodeKind::Chain, effects},
                     {"out", PatchNodeKind::Output, {}}};
    PatchWireSpec a, b;
    a.from = {"in", "out"};
    a.to = {"inserts", "in"};
    b.from = {"inserts", "out"};
    b.to = {"out", "in"};
    wrapped.wires = {a, b};
    auto modulePatch = compilePatch(registry, modules, 48000, nullptr, error);
    if (!chain || !modulePatch) {
        std::fprintf(stderr, "build failed: %s\n", error.c_str());
        return 1;
    }
    auto chainPatch = compilePatch(registry, wrapped, 48000, nullptr, error);
    if (!chainPatch) {
        std::fprintf(stderr, "build failed: %s\n", error.c_str());
        return 1;
    }
    // A busy input: a saw and a little noise, never silent (no effect sleeps).
    const int blocks = seconds * 48000 / 64;
    std::vector<float> inL(64 * 750), inR(64 * 750);
    uint32_t noise = 1;
    for (size_t i = 0; i < inL.size(); ++i) {
        noise ^= noise << 13; noise ^= noise >> 17; noise ^= noise << 5;
        const float n = static_cast<float>(noise) / 4294967296.0f - 0.5f;
        inL[i] = 0.4f * (static_cast<float>(i % 436) / 218.0f - 1.0f) + 0.05f * n;
        inR[i] = 0.4f * (static_cast<float>((i + 100) % 436) / 218.0f - 1.0f) - 0.05f * n;
    }
    std::vector<float> l(64), r(64);
    auto source = [&](int block) { return static_cast<size_t>(block % 750) * 64; };
    // Interleaved rounds, so drift (clock, heat) hits each the same.
    double tChain = 1e300, tModules = 1e300, tWrapped = 1e300;
    for (int r0 = 0; r0 < rounds; ++r0) {
        tChain = std::min(tChain, best(1, blocks, [&](int k) {
            std::copy_n(inL.data() + source(k), 64, l.data());
            std::copy_n(inR.data() + source(k), 64, r.data());
            chain->process(l.data(), r.data(), 64, 48000, nullptr);
        }));
        tModules = std::min(tModules, best(1, blocks, [&](int k) {
            modulePatch->process(inL.data() + source(k), inR.data() + source(k), l.data(), r.data(), 64);
        }));
        tWrapped = std::min(tWrapped, best(1, blocks, [&](int k) {
            chainPatch->process(inL.data() + source(k), inR.data() + source(k), l.data(), r.data(), 64);
        }));
    }
    std::printf("effects: %zu, %d s of 64-frame blocks, best of %d\n", effects.size(), seconds, rounds);
    std::printf("chain                 %8.1f ns/block\n", tChain);
    std::printf("patch, module nodes   %8.1f ns/block  %+6.2f%%\n", tModules, 100.0 * (tModules / tChain - 1.0));
    std::printf("patch, one chain node %8.1f ns/block  %+6.2f%%\n", tWrapped, 100.0 * (tWrapped / tChain - 1.0));
    return 0;
}
