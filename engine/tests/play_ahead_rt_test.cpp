// Play-ahead on the audio thread allocates nothing: rings, handovers, parked edits, an underrun and a drop.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(play_ahead_never_allocates_on_the_audio_thread) {
    ProjectSpec p = cawtest::testSignalProject({}, 128, 2);
    p.modules.push_back({"pad", "---\nkind: pattern\nlength: 12\n---\n0 C3 3.5 0.9\n4.3 D#3 2 0.7\n7.1 A#3 4.4 1\n"});
    LayerSpec pad;
    pad.id = pad.name = "pad";
    pad.hasInstrument = true;
    pad.pattern = "pad";
    pad.instrument.id = "org.caw.synth.flagship";
    for (const char* id : {"org.caw.drive", "org.caw.eq", "org.caw.compressor", "org.caw.tremolo"}) {
        ComponentSpec c;
        c.id = id;
        pad.components.push_back(c);
    }
    p.layers.push_back(pad);
    p.layers.push_back(cawtest::testSignalNotesLayer("sig", cawtest::Shape::Saw, "pad", {{"level", 0.3}}));
    const int was = Engine::playAheadForTest();
    Engine::setPlayAheadForTest(3000);  // the rings filled on this thread: the producer's work is counted too
    {
        Engine e(48000);
        CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
        e.play();
        std::vector<float> l(1024), r(1024);
        for (int i = 0; i < 100; ++i) e.process(l.data(), r.data(), 480);  // warm up: one second
        CHECK(e.aheadStats().tracks >= 1);
        std::size_t operations = 0;
        auto play = [&](int calls) {
            cawtest::AllocationScope scope;
            for (int i = 0; i < calls; ++i) e.process(l.data(), r.data(), i % 2 ? 480 : 37);
            operations += scope.count();
        };
        play(100);
        CHECK(e.setComponentParam("pad", 2, "threshold", -30.0));  // parked, lands at the ring's end
        CHECK(e.setComponentParam("pad", Engine::kInstrumentIndex, "osc1_unison", 2));
        play(100);
        e.stallPlayAheadForTest(true);  // an underrun: the fade, the drain, back live
        play(100);
        e.stallPlayAheadForTest(false);
        CHECK(e.aheadStats().underruns >= 1);
        CHECK(e.play(3));  // a seek drops the rings
        play(100);
        CHECK_EQ(operations, std::size_t{0});
    }
    Engine::setPlayAheadForTest(was);
}
