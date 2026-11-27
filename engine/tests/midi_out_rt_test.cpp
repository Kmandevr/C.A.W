// MIDI out and the MIDI clock (API 47) on the audio thread: notes out, clock out, stop, locate and a port change
// never allocate or free in process().
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "test.h"

using namespace caw;
using cawtest::AllocationScope;

TEST(midi_out_and_clock_never_allocate_on_the_audio_thread) {
    Engine e(48000);
    const auto project = [](int port) {
        return std::string("{\"bpm\":140,\"loop_bars\":1,\"tempo_map\":[{\"beat\":0,\"bpm\":140},{\"beat\":2,\"bpm\":90,\"ramp\":true}],"
                           "\"modules\":[{\"id\":\"p\",\"source\":\"---\\nkind: pattern\\nname: p\\nlength: 16\\n---\\n"
                           "0 C4 1 1\\n1 D4 1 0.8\\n2 E4 2 0.6\\n4 C4 4 1\\n8 G4 1 1\\n12 A4 4 0.5\\n\"}],"
                           "\"layers\":[{\"id\":\"m\",\"pattern\":\"p\",\"midiOut\":{\"port\":") +
               std::to_string(port) + ",\"channel\":2,\"program\":1}}]}";
    };
    CHECK(e.setProjectJson(project(0)).find("\"ok\":true") != std::string::npos);
    e.setMidiClockOut(3);
    e.setMidiOutActive(true);
    std::vector<float> l(256), r(256);
    std::vector<MidiOutMessage> buf(4096);
    e.play();
    e.process(l.data(), r.data(), 256);  // the first callback takes the project
    size_t sent = 0;
    auto run = [&](int callbacks) {
        AllocationScope scope;
        for (int k = 0; k < callbacks; ++k) e.process(l.data(), r.data(), 256);
        CHECK_EQ(scope.count(), 0u);
        sent += static_cast<size_t>(e.midiOutDrain(buf.data(), static_cast<int32_t>(buf.size())));
    };
    run(400);  // through the tempo ramp and the loop's wrap
    e.play(5);
    run(50);
    e.setLayerMix("m", 0.8, 0, true, false);
    run(20);
    e.setLayerMix("m", 0.8, 0, false, false);
    run(20);
    CHECK(e.setProjectJson(project(4)).find("\"ok\":true") != std::string::npos);  // a port change
    run(50);
    e.stop();
    run(50);
    CHECK(sent > 100u);
    CHECK_EQ(e.midiOutDropped(), 0u);
}
