// org.caw.test.osc: each shape's samples, seeded noise, notes mode, never listed, and the track helper in test_signal.h.
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "builtin_components.h"
#include "caw/detmath.hpp"
#include "component_test.h"
#include "engine.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;
using cawtest::Shape;

namespace {

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry m;
        registerBuiltinComponents(m);
        return m;
    }();
    return r;
}

// `frames` of the signal at 48 kHz in blocks of 64.
ComponentRender render(Shape shape, cawtest::Params params, size_t frames, std::vector<TestNote> notes = {}) {
    TestComponent c;
    c.id = std::string(kTestSignalId);
    c.params = cawtest::testSignal(shape, std::move(params)).params;
    const std::vector<float> silence(frames, 0.0f);
    ComponentRender out;
    std::string error;
    if (!renderComponent(registry(), c, 48000, 64, 120, silence, silence, false, out, error, notes))
        cawtest::fail(__FILE__, __LINE__, "render failed: " + error);
    return out;
}

int risingCrossings(const std::vector<float>& x, size_t from, size_t to) {
    int n = 0;
    for (size_t i = std::max<size_t>(from, 1); i < to && i < x.size(); ++i) n += x[i - 1] < 0 && x[i] >= 0;
    return n;
}

}  // namespace

TEST(test_signal_is_internal_never_listed) {
    CHECK(registry().find(kTestSignalId) != nullptr);
    for (const ModuleDescriptor* d : registry().builtinComponents()) CHECK(d->id != kTestSignalId);
    Engine e(48000);
    CHECK(e.nativeComponentsJson().find("org.caw.test") == std::string::npos);
    CHECK(e.createNativeComponent(std::string(kTestSignalId)) != nullptr);
}

TEST(test_signal_shapes_give_exact_samples) {
    const ComponentRender sine = render(Shape::Sine, {{"freq", 1000}, {"level", 0.5}}, 480);
    for (size_t i = 0; i < 480; ++i)
        CHECK_NEAR(sine.left[i], 0.5 * detSin(kTwoPi * std::fmod(1000.0 * i / 48000.0, 1.0)), 1e-6);
    CHECK(sine.left == sine.right);
    const ComponentRender saw = render(Shape::Saw, {{"freq", 480}}, 200);  // 100 frames a cycle
    CHECK_NEAR(saw.left[0], -1.0, 1e-6);
    CHECK_NEAR(saw.left[50], 0.0, 1e-6);
    CHECK_NEAR(saw.left[150], 0.0, 1e-6);
    const ComponentRender square = render(Shape::Square, {{"freq", 480}}, 200);
    CHECK_EQ(square.left[0], 1.0f);
    CHECK_EQ(square.left[49], 1.0f);
    CHECK_EQ(square.left[50], -1.0f);
    CHECK_EQ(square.left[100], 1.0f);
    const ComponentRender dc = render(Shape::Dc, {{"level", 0.25}, {"left", 1}, {"right", -2}}, 300);
    for (size_t i = 0; i < 300; ++i) CHECK(dc.left[i] == 0.25f && dc.right[i] == -0.5f);
    const ComponentRender one = render(Shape::Impulse, {}, 1000);
    CHECK_EQ(one.left[0], 1.0f);
    for (size_t i = 1; i < 1000; ++i) CHECK_EQ(one.left[i], 0.0f);
    const ComponentRender train = render(Shape::Impulse, {{"period", 0.01}}, 1500);  // every 480 frames
    for (size_t i = 0; i < 1500; ++i) CHECK_EQ(train.left[i], i % 480 == 0 ? 1.0f : 0.0f);
    // A note number sets the Free-mode pitch: A5 is 880 Hz, so 48000 frames hold 880 rising crossings.
    const ComponentRender a5 = render(Shape::Sine, {{"note", 81}, {"phase", 0.5}}, 48000);
    CHECK(std::abs(risingCrossings(a5.left, 0, 48000) - 880) <= 1);
}

TEST(test_signal_noise_is_seeded) {
    const ComponentRender a = render(Shape::Noise, {{"seed", 7}}, 4096);
    const ComponentRender b = render(Shape::Noise, {{"seed", 7}}, 4096);
    const ComponentRender c = render(Shape::Noise, {{"seed", 8}}, 4096);
    CHECK(a.left == b.left);
    CHECK(a.left != c.left);
    double sum = 0, sq = 0;
    for (float v : a.left) {
        CHECK(v >= -1.0f && v <= 1.0f);
        sum += v;
        sq += static_cast<double>(v) * v;
    }
    CHECK(std::fabs(sum / 4096) < 0.05);
    CHECK_NEAR(sq / 4096, 1.0 / 3.0, 0.03);  // uniform on -1..1
}

TEST(test_signal_sweep_rises) {
    // 100 Hz to 10 kHz over one second, then held.
    const ComponentRender s = render(Shape::Sweep, {{"freq", 100}, {"sweep_to", 10000}, {"sweep_time", 1}}, 96000);
    const int early = risingCrossings(s.left, 0, 4800), late = risingCrossings(s.left, 43200, 48000);
    CHECK(early >= 9 && early <= 13);    // about 100 * 1.26 Hz over the first 0.1 s
    CHECK(late >= 750 && late <= 900);   // about 8.3 kHz over the last 0.1 s of the sweep
    CHECK(std::abs(risingCrossings(s.left, 48000, 96000) - 10000) <= 2);  // held at 10 kHz
}

TEST(test_signal_notes_mode_plays_each_note) {
    // 0.1 s of A4 at velocity 127 from 0.05 s; nothing outside it.
    const ComponentRender r = render(Shape::Sine, {{"mode", 1}}, 14400, {{69, 127, 0.05, 0.1}});
    float before = 0, after = 0;
    for (size_t i = 0; i < 2400; ++i) before = std::max(before, std::fabs(r.left[i]));
    for (size_t i = 7200; i < 14400; ++i) after = std::max(after, std::fabs(r.left[i]));
    CHECK_EQ(before, 0.0f);
    CHECK_EQ(after, 0.0f);
    CHECK_EQ(risingCrossings(r.left, 2400, 7200), 43);  // 44 cycles of 440 Hz from phase 0: the first starts at 0
    // A chord: two voices sum.
    const ComponentRender dc = render(Shape::Dc, {{"mode", 1}, {"level", 0.25}}, 4800, {{60, 127, 0, 0.05}, {64, 127, 0, 0.05}});
    CHECK_EQ(dc.left[100], 0.5f);
}

TEST(test_signal_layer_helper_plays_on_a_track) {
    // A DC of 0.5 through volume 1 and the centre pan: 0.5 * cos(pi/4) on both sides, as a .caw `0.5` module gave.
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProject(cawtest::testSignalProject({cawtest::testSignalLayer("t", Shape::Dc, {{"level", 0.5}})}))
              .find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> l(256), r(256);
    for (int i = 0; i < 8; ++i) e.process(l.data(), r.data(), 256);
    CHECK_NEAR(l.back(), 0.5 * std::cos(kPi / 4), 1e-6);
    CHECK_NEAR(r.back(), 0.5 * std::cos(kPi / 4), 1e-6);

    // Notes mode from a pattern: silent until the note at step 4 (6000 frames a step at 120 BPM).
    ProjectSpec p = cawtest::testSignalProject({cawtest::testSignalNotesLayer("n", Shape::Dc, "pat")}, 120, 1);
    p.modules.push_back({"pat", "---\nkind: pattern\n---\n4 C4 2 1\n", {}});
    Engine notes(48000);
    notes.setMasterBypass(true);
    CHECK(notes.setProject(p).find("\"ok\":true") != std::string::npos);
    notes.play();
    std::vector<float> nl(48000), nr(48000);
    for (int i = 0; i < 48000; i += 64) notes.process(nl.data() + i, nr.data() + i, 64);
    CHECK_EQ(nl[23999], 0.0f);
    CHECK_NEAR(nl[24000 + 100], std::cos(kPi / 4), 1e-6);
    CHECK_EQ(nl[36000 + 100], 0.0f);
}
