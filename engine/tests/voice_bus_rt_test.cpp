// The voice bus (#127) on the audio thread: instruments rendering into lanes never allocate or free.
#include <memory>
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "caw/instrument.hpp"
#include "engine.h"
#include "test.h"

using namespace caw;

namespace {
struct Host {
    float buffers[2][2][256] = {};
    VoiceLane lanes[2];
    VoiceBus bus;
    float gain = 0.5f;
    static void run(void* data, uint32_t offset, uint32_t frames) {
        Host& h = *static_cast<Host*>(data);
        for (auto& lane : h.buffers)
            for (auto& channel : lane)
                for (uint32_t i = offset; i < offset + frames; ++i) channel[i] *= h.gain;
    }
    Host() {
        bus.laneCount = 2;
        bus.lanes = lanes;
        bus.hostData = this;
        bus.run = &run;
    }
    void begin() {
        for (uint32_t k = 0; k < 2; ++k) {
            lanes[k] = VoiceLane{};
            lanes[k].noteId = k + 1;
            lanes[k].flags = kLaneAssigned;
            lanes[k].channels[0] = buffers[k][0];
            lanes[k].channels[1] = buffers[k][1];
        }
    }
};
}  // namespace

TEST(voice_bus_instruments_never_allocate_with_lanes) {
    Engine e(48000);
    for (const char* id : {"org.caw.synth.flagship", "org.caw.drums", "org.caw.test.osc"}) {
        std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(id);
        CHECK(p != nullptr);
        if (!p) continue;
        CHECK(p->activate(48000, 256));
        const ModuleDescriptor& d = p->descriptor();
        std::vector<ParameterValue> params(d.parameterCount);
        for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
        if (std::string(id) == "org.caw.test.osc") params[1].value = 1;  // Notes mode
        std::vector<float> l(256), r(256);
        float* channels[2] = {l.data(), r.data()};
        const ChannelBufferView audio{channels, 2, 256};
        const Event on[] = {notes::noteOn(0, 1, 36, 1.0), notes::noteOn(10, 2, 38, 1.0), notes::noteOn(20, 3, 40, 1.0)};
        Host host;
        std::size_t count = 0;
        for (int block = 0; block < 40; ++block) {
            const EventInput ev{on, block == 0 ? 3u : 0u};
            ProcessBlock b;
            b.frames = 256;
            b.audioOut = &audio;
            b.audioOutCount = 1;
            b.eventIn = &ev;
            b.eventInCount = 1;
            b.parameters = params.data();
            b.parameterCount = d.parameterCount;
            b.voices = &host.bus;
            host.begin();
            cawtest::AllocationScope scope;
            CHECK(p->processPorts(b));
            count += scope.count();
        }
        CHECK_EQ(count, 0u);
    }
}
