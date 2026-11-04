// Real-time checks on the whole Engine: the audio callback never allocates or frees, through seams and code swaps.
#include <cstring>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "capi_internal.h"
#include "engine.h"
#include "test.h"

using namespace caw;

namespace {
std::string templateSource(const char* file) {
    for (int i = 0; i < kTemplateCount; ++i)
        if (std::strcmp(kTemplateFiles[i], file) == 0) return kTemplateSources[i];
    return {};
}

LayerSpec layer(const std::string& id, std::vector<std::string> chain) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.chain = std::move(chain);
    return l;
}
}  // namespace

TEST(engine_process_never_allocates_through_seams_and_code_swaps) {
    ProjectSpec p;
    p.bpm = 140;
    p.loopBars = 1;
    for (const char* file : {"bass.caw", "acid-synth.caw", "bytebeat-loop.caw", "fold.caw", "glitch-fx.caw",
                             "bitcrush.caw", "acid-line.caw"}) {
        std::string id(file);
        id.resize(id.size() - 4);
        p.modules.push_back({id, templateSource(file), {}});
    }
    p.layers = {layer("b", {"bass", "fold", "glitch-fx"}), layer("a", {"acid-synth", "bitcrush"}),
                layer("y", {"bytebeat-loop", "fold"})};
    p.layers[1].pattern = "acid-line";
    p.layers[2].lengthSteps = 3;  // a seam crossfade every 3 sixteenths
    Engine e(48000);
    e.setProject(p);
    e.play();
    std::vector<float> l(192), r(192);
    for (int k = 0; k < 250; ++k) e.process(l.data(), r.data(), 192);  // warm up: one second
    // New code with different chain lengths, swapped in at once: the old chains fade on their lane.
    p.layers[0].chain = {"bass"};
    p.layers[1].chain = {"acid-synth", "glitch-fx", "fold"};
    p.layers[2].chain = {"bytebeat-loop", "bitcrush", "glitch-fx", "fold"};
    e.setProject(p);
    std::size_t operations = 0;
    float peak = 0.0f;
    {
        cawtest::AllocationScope scope;
        for (int k = 0; k < 500; ++k) {  // two seconds: loop wraps, seams, the swap and its retirement
            e.process(l.data(), r.data(), 192);
            for (float v : l) peak = v > peak ? v : peak;
        }
        operations = scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    CHECK_EQ(e.routingRejections(), 0u);
}
