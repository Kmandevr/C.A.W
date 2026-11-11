// fx-space: the Space, Modulation and Utility effects never allocate on the audio thread (knob moves, rebuilds, display reads).
#include <cstring>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "capi_internal.h"
#include "engine.h"
#include "test.h"

using namespace caw;

namespace {
std::string fxSpaceTemplate(const char* file) {
    for (int i = 0; i < kTemplateCount; ++i)
        if (std::strcmp(kTemplateFiles[i], file) == 0) return kTemplateSources[i];
    return {};
}
}  // namespace

TEST(fx_space_effects_never_allocate_on_the_audio_thread) {
    // Every fx-space effect on one track; the convolver changes its impulse (a rebuild and crossfade while playing),
    // the others move their knobs; display reads; a stop and a restart.
    const char* ids[] = {"org.caw.ensemble", "org.caw.doubler", "org.caw.vibrato", "org.caw.tremolo",
                         "org.caw.autopan",  "org.caw.rotary",  "org.caw.haas",    "org.caw.imager",
                         "org.caw.channelmixer", "org.caw.convolver", "org.caw.shimmer"};
    ProjectSpec p;
    p.bpm = 128;
    p.loopBars = 1;
    p.modules.push_back({"bass", fxSpaceTemplate("bass.caw"), {}});
    LayerSpec l;
    l.id = l.name = "b";
    l.chain = {"bass"};
    p.layers = {l};
    for (const char* id : ids) p.layers[0].components.push_back({id, {}});
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192);
    for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
    std::size_t operations = 0;
    float shown[1024];
    for (int round = 0; round < 6; ++round) {
        e.setComponentParam("b", 9, "source", round);
        e.setComponentParam("b", 9, "decay", 1 + round);
        e.setComponentParam("b", 0, "voices", round);
        e.setComponentParam("b", 5, "speed", round % 3);
        e.setComponentParam("b", 10, "shift", round);
        e.setComponentParam("b", 7, "low_width", 0.3 * round);
        if (round == 4) e.stop();
        if (round == 5) e.play();
        cawtest::AllocationScope scope;
        for (int k = 0; k < 120; ++k) {
            e.process(left.data(), right.data(), 192);
            for (uint32_t i = 0; i < 11; ++i) e.componentDisplay("b", i, shown, 1024);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
}
