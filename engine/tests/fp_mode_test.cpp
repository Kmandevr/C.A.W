// Speed phase 2 ("floating point"): the flush-to-zero guard (fp_mode.h) and the mix's NaN/Inf guards under the build's flags.
#include <algorithm>
#include <cmath>
#include <limits>
#include <string>
#include <vector>

#include "engine.h"
#include "fp_mode.h"
#include "native_component_test_path.h"
#include "project.h"
#include "test.h"
#include "test_signal.h"

using namespace caw;

namespace {

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

// A subnormal result, computed where the compiler can't fold it.
float halveSmallest() {
    volatile float x = std::numeric_limits<float>::min();  // the smallest normal float
    volatile float half = 0.5f;
    return x * half;
}

}  // namespace

TEST(the_flush_guard_flushes_subnormals_and_restores_the_threads_mode) {
    const bool before = ScopedFlushDenormals::flushing();
    {
        const ScopedFlushDenormals guard;
#if (defined(__SSE__) || defined(_M_X64) || defined(__aarch64__)) && !defined(_M_ARM64)
        CHECK(ScopedFlushDenormals::flushing());
        CHECK_EQ(halveSmallest(), 0.0f);
#endif
        {
            const ScopedFlushDenormals nested;  // a nested guard changes nothing, and leaves the outer one's mode
        }
#if (defined(__SSE__) || defined(_M_X64) || defined(__aarch64__)) && !defined(_M_ARM64)
        CHECK(ScopedFlushDenormals::flushing());
#endif
    }
    CHECK_EQ(ScopedFlushDenormals::flushing(), before);
    if (!before) CHECK(halveSmallest() != 0.0f);  // the caller's subnormals are back

    // Engine::process holds a guard and leaves the caller's thread as it found it.
    Engine e(48000);
    std::vector<float> l(256), r(256);
    e.process(l.data(), r.data(), 256);
    CHECK_EQ(ScopedFlushDenormals::flushing(), before);
}

TEST(nan_and_inf_from_a_track_leave_the_mix_finite_under_the_builds_flags) {
    constexpr const char* kPoison = "org.caw.tests.native-loader.poison";
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    if (!path) return;
    for (const bool masterOn : {true, false}) {
        Engine e(48000);
        CHECK(e.loadNativeComponent(path, kPoison, NativeModuleTrust::Trusted).success);
        e.setMasterBypass(!masterOn);
        ProjectSpec p;
        p.bpm = 120;
        p.loopBars = 1;
        p.master = 1.0;
        p.modules.push_back({"hold", "---\nkind: pattern\nlength: 16\n---\n0 C4 16 1\n"});
        // The poisoned track, and a clean one that must still be heard through the same mix.
        p.layers.push_back(cawtest::testSignalNotesLayer("bad", cawtest::Shape::Dc, "hold", {{"level", 0.5}}, {{kPoison, {}}}));
        p.layers.push_back(cawtest::testSignalNotesLayer("good", cawtest::Shape::Dc, "hold", {{"level", 0.25}}));
        CHECK(ok(e.setProject(p)));
        e.play();
        std::vector<float> l(256), r(256);
        bool finite = true;
        float loudest = 0.0f;
        for (int k = 0; k < 100; ++k) {
            e.process(l.data(), r.data(), 256);
            for (int i = 0; i < 256; ++i) {
                finite = finite && std::isfinite(l[static_cast<size_t>(i)]) && std::isfinite(r[static_cast<size_t>(i)]);
                loudest = std::max(loudest, std::fabs(l[static_cast<size_t>(i)]));
            }
        }
        CHECK(finite);
        CHECK(loudest > 0.05f);  // not muted to silence: the clean track still plays
        CHECK(loudest <= 1.0f);  // and the safety limit holds (the master's limiter, or the bypassed mix's clamp)
    }
}
