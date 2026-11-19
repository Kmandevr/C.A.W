// FX consolidation part B: Drive and Bit distortion never allocate on the audio thread, Drive's variant changed by project updates while playing.
#include <string>
#include <vector>

#include "alloc_counter.h"
#include "builtin_fx_racks.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {
constexpr const char* kDrive = "org.caw.drive";
constexpr const char* kBits = "org.caw.bits";
}  // namespace

TEST(drive_changes_variant_while_playing_without_allocating_on_the_audio_thread) {
    // Drive on a track cycling through its four variants, Bit distortion beside it, an old id migrated on the
    // master and a rack holding a Drive variant: each round is a rebuild, crossfaded in.
    auto project = [](int variant) {
        ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalLayer("t", cawtest::Shape::Saw, {{"freq", 110}})});
        ComponentSpec drive, bits, master, rack;
        drive.id = kDrive;
        drive.params = {{"variant", variant}, {"drive", variant == 3 ? 0.5 : 6.0}, {"mix", 0.8}};
        p.layers[0].components.push_back(drive);
        bits.id = kBits;
        bits.params = {{"bits", 6.0 + variant}};
        p.layers[0].components.push_back(bits);
        master.id = variant % 2 ? "org.caw.clipper" : "org.caw.saturator";
        master.params = {{"mix", 0.5}};
        p.masterComponents.push_back(master);
        rack.id = std::string(kFxRackId);
        rack.params = {{"s1_fx", static_cast<double>(rackChildHash(kDrive))}, {"s1.variant", 3.0 - variant}};
        p.layers[0].components.push_back(rack);
        return p;
    };
    Engine e(48000);
    CHECK(e.setProject(project(0)).find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> left(192), right(192);
    for (int k = 0; k < 100; ++k) e.process(left.data(), right.data(), 192);
    std::size_t operations = 0;
    float shown[1024];
    for (int round = 0; round < 8; ++round) {
        CHECK(e.setProject(project((round + 1) % 4)).find("\"ok\":true") != std::string::npos);
        e.setComponentParam("t", 0, "mix", 0.5 + 0.05 * round);
        cawtest::AllocationScope scope;
        for (int k = 0; k < 120; ++k) {
            e.process(left.data(), right.data(), 192);
            e.componentDisplay("t", 0, shown, 1024);
            e.componentDisplay("t", 1, shown, 1024);
            e.componentDisplay("t", 2, shown, 1024);
        }
        operations += scope.count();
    }
    CHECK_EQ(operations, 0u);
    CHECK(!e.setComponentParam("t", 0, "variant", 2));  // structural: a project update, not a value
}
