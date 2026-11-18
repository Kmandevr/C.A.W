// General mixer routing on the audio thread: outputs, sends into tracks, feedback sends and their changes allocate nothing.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(general_routing_and_feedback_sends_never_allocate_on_the_audio_thread) {
    using cawtest::Shape;
    LayerSpec x, y;
    x.id = x.name = "x";
    y.id = y.name = "y";
    x.folder = y.folder = x.busEnabled = y.busEnabled = true;
    SendSpec xy{"y", 0.7, false, false};
    SendSpec back{"x", 0.6, false, false};
    back.feedback = true;
    x.sends = {xy};
    y.sends = {back};
    LayerSpec a = cawtest::testSignalLayer("a", Shape::Saw, {{"level", 0.3}, {"freq", 110}});
    a.parentId = "y";
    a.outputId = "x";  // its folder is y, its output x
    LayerSpec k = cawtest::testSignalLayer("k", Shape::Dc, {{"level", 0.0}});
    k.mute = true;
    SendSpec intoK{"k", 1.0, true, false};
    a.sends = {intoK};
    SendSpec self{"t", 0.5, false, false};
    self.feedback = true;
    LayerSpec t = cawtest::testSignalLayer("t", Shape::Sine, {{"level", 0.3}, {"freq", 220}});
    t.sends = {self};
    ComponentSpec duck;
    duck.id = "org.caw.ducker";
    duck.hasKey = true;
    duck.key.layer = "k";  // keyed by a track that only hears a send
    t.components = {duck};
    t.lengthSteps = 3;
    ProjectSpec p = cawtest::testSignalProject({x, y, a, k, t});
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(1024), r(1024);
    for (int i = 0; i < 100; ++i) e.process(l.data(), r.data(), 480);  // warm up: one second
    // Changes while it plays: live send levels, then a rebuilt route table (the limiter off, a new destination).
    p.layers[1].sends[0].limiter = false;
    p.layers[4].sends[0].to = "x";
    std::size_t operations = 0;
    float peak = 0;
    {
        cawtest::AllocationScope scope;
        for (int i = 0; i < 200; ++i) {
            e.process(l.data(), r.data(), i % 2 ? 480 : 37);
            for (float v : l) peak = v > peak ? v : peak;
        }
        operations = scope.count();
    }
    CHECK(e.setSend("y", 0, 0.3, true, false));
    CHECK(e.setSend("a", 0, 0.5, false, false));
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    {
        cawtest::AllocationScope scope;
        for (int i = 0; i < 200; ++i) e.process(l.data(), r.data(), i % 3 ? 128 : 1024);
        operations += scope.count();
    }
    e.stop();
    e.play();
    {
        cawtest::AllocationScope scope;
        for (int i = 0; i < 50; ++i) e.process(l.data(), r.data(), 256);
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
    CHECK_EQ(e.routingRejections(), 0u);
}
