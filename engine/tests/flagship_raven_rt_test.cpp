// Flagship's 1.1.0 synthesis (Raven) on the audio thread: its new warps, banks, filters, LFO 4 and macros never allocate there.
#include <chrono>
#include <string>
#include <thread>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"

using namespace caw;

TEST(flagship_raven_s_modes_never_allocate_on_the_audio_thread) {
    // A live engine (banks built by the worker thread, never on the audio thread): every new warp in turn, a new
    // filter model each round, LFO 4 and a macro on slots, while notes play. No allocation or free in process().
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n0 C3 4 1\n0 G3 4 0.8\n4 E3 4 1\n8 A2 8 0.9\n"});
    LayerSpec l;
    l.id = l.name = "raven";
    l.pattern = "pat";
    l.hasInstrument = true;
    l.instrument.id = "org.caw.synth.flagship";
    l.instrument.params = {{"osc2_on", 1}, {"osc2_semi", 7}, {"osc1_unison", 3}, {"mod2_src", 15}, {"mod2_dst", 3},
                           {"mod2_amt", 0.3}, {"mod3_src", 16}, {"mod3_dst", 12}, {"mod3_amt", 0.3}, {"macro1", 0.5}};
    p.layers.push_back(l);
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> L(256), R(256);
    for (int k = 0; k < 100; ++k) e.process(L.data(), R.data(), 256);  // warm up
    std::size_t operations = 0;
    float peak = 0.0f;
    const char* id = "raven";
    for (int warp = 8; warp <= 18; ++warp) {
        e.setComponentParam(id, Engine::kInstrumentIndex, "osc1_warp", warp);
        e.setComponentParam(id, Engine::kInstrumentIndex, "osc1_warp_amt", 0.3 + 0.05 * (warp % 5));
        e.setComponentParam(id, Engine::kInstrumentIndex, "osc1_mod_src", warp % 5);
        e.setComponentParam(id, Engine::kInstrumentIndex, "osc1_table", warp % 7);
        e.setComponentParam(id, Engine::kInstrumentIndex, "flt1_type", 9 + warp % 5);
        e.setComponentParam(id, Engine::kInstrumentIndex, "lfo4_rate", 1.0 + warp);
        e.setComponentParam(id, Engine::kInstrumentIndex, "macro1", (warp % 3) / 2.0);
        {
            cawtest::AllocationScope scope;
            for (int k = 0; k < 40; ++k) {
                e.process(L.data(), R.data(), 256);
                for (float v : L) peak = v > peak ? v : peak;
            }
            operations += scope.count();
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(60));  // the worker builds what was asked for
        cawtest::AllocationScope scope;
        for (int k = 0; k < 40; ++k) e.process(L.data(), R.data(), 256);  // now reading the bank
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
}
