// fx-racks: the racks never allocate or free on the audio thread (modulation, sleep and wake, a band count change).
#include <memory>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_components.h"
#include "builtin_fx_racks.h"
#include "component_chain.h"
#include "test.h"

using namespace caw;

TEST(the_racks_never_allocate_on_the_audio_thread) {
    ModuleRegistry reg;
    registerBuiltinComponents(reg);
    auto h = [](const char* id) { return static_cast<double>(rackChildHash(id)); };
    std::vector<ComponentSpec> specs(2);
    specs[0].id = "org.caw.rack.fx";
    specs[0].params = {{"s1_fx", h("org.caw.filter")}, {"s2_fx", h("org.caw.compressor")}, {"s3_fx", h("org.caw.reverb.pro")},
                       {"s4_fx", h("org.caw.ducker")}, {"mod1_src", 1}, {"mod1_dst", 100}, {"mod1_amt", 0.5},
                       {"mod2_src", 5}, {"mod2_dst", 120}, {"mod2_amt", 0.3}, {"mod3_src", 9}, {"mod3_dst", 130},
                       {"mod3_amt", -0.4}, {"lfo1_shape", 7}};
    specs[1].id = "org.caw.rack.multiband";
    specs[1].params = {{"bands", 5}, {"b1s1_fx", h("org.caw.compressor")}, {"b2s1_fx", h("org.caw.limiter")},
                       {"b3s1_fx", h("org.caw.saturator")}, {"b4s2_fx", h("org.caw.eq")}, {"b5s4_fx", h("org.caw.delay.pro")}};
    std::string error;
    auto chain = ComponentChain::build(reg, specs, 48000.0, error);
    CHECK(chain != nullptr);
    if (!chain) return;
    std::vector<float> l(64), r(64);
    float display[1024];
    uint32_t x = 1;
    ChainTime t;
    t.stepLength = 6000.0;
    std::size_t operations = 0;
    for (int round = 0; round < 3; ++round) {
        {
            cawtest::AllocationScope scope;
            for (int b = 0; b < 1500; ++b) {
                const bool gap = (b / 300) % 2 == 1;  // silence long enough to sleep, then wake
                for (uint32_t i = 0; i < 64; ++i) {
                    x = x * 1664525u + 1013904223u;
                    l[i] = r[i] = gap ? 0.0f : 0.3f * (static_cast<float>(x >> 8) / 8388608.0f - 1.0f);
                }
                t.start = static_cast<int64_t>(b) * 64;
                t.chunk = b;
                chain->process(l.data(), r.data(), 64, 48000.0, &t);
            }
            operations += scope.count();
        }
        // Control thread between rounds: knobs that change the band count and switch slots.
        chain->setValue(1, "bands", round == 0 ? 2 : 4);
        chain->setValue(0, "s2_on", round == 0 ? 0 : 1);
        chain->setValue(1, "band2_bypass", round == 0 ? 1 : 0);
        chain->readDisplay(0, display, 1024);
        chain->readDisplay(1 + 65536 * 2, display, 1024);
    }
    CHECK_EQ(operations, 0u);
}
