// VCA groups on the audio thread: their ramps, live moves, mute and solo, and a replaced table allocate nothing.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "engine.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

TEST(vca_groups_never_allocate_on_the_audio_thread) {
    using cawtest::Shape;
    LayerSpec f;
    f.id = f.name = "f";
    f.folder = f.busEnabled = true;
    LayerSpec a = cawtest::testSignalLayer("a", Shape::Saw, {{"level", 0.3}, {"freq", 110}});
    a.parentId = "f";
    SendSpec post{"f", 0.5, false, false};
    LayerSpec b = cawtest::testSignalLayer("b", Shape::Sine, {{"level", 0.3}, {"freq", 220}});
    b.sends = {post};
    b.outputId = kMasterOutput;
    b.automation = {AutomationLaneSpec{"volume", {{0, 1.0}, {32, 0.2}}}};
    ProjectSpec p = cawtest::testSignalProject({f, a, b});
    VcaGroupSpec v;
    v.id = v.name = "v";
    v.members = {"f", "b"};
    v.volumeLane = {{0, 1.0}, {16, 0.1}, {32, 1.0}};
    VcaGroupSpec w;
    w.id = w.name = "w";
    w.volume = 0.7;
    w.members = {"a"};
    p.vcaGroups = {v, w};
    Engine e(48000);
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(1024), r(1024);
    for (int i = 0; i < 100; ++i) e.process(l.data(), r.data(), 480);  // warm up: one second
    std::size_t operations = 0;
    float peak = 0;
    {
        cawtest::AllocationScope scope;
        for (int i = 0; i < 200; ++i) {
            e.process(l.data(), r.data(), i % 2 ? 480 : 37);
            for (float x : l) peak = x > peak ? x : peak;
        }
        operations = scope.count();
    }
    CHECK(e.setVca("w", 0.2, false, true));
    {
        cawtest::AllocationScope scope;
        for (int i = 0; i < 100; ++i) e.process(l.data(), r.data(), 128);
        operations += scope.count();
    }
    CHECK(e.setVca("w", 1.0, true, false));
    p.vcaGroups[0].volumeLane.clear();  // a replaced table: v carries on from its gain
    p.vcaGroups.push_back(w);
    p.vcaGroups.back().id = "x";
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    {
        cawtest::AllocationScope scope;
        for (int i = 0; i < 200; ++i) e.process(l.data(), r.data(), i % 3 ? 128 : 1024);
        operations += scope.count();
    }
    p.vcaGroups.clear();  // and none at all
    CHECK(e.setProject(p).find("\"ok\":true") != std::string::npos);
    {
        cawtest::AllocationScope scope;
        for (int i = 0; i < 50; ++i) e.process(l.data(), r.data(), 256);
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(peak > 0.01f);
}
