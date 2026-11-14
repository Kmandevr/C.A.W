// The plug-in benchmark's allocation check (#197), with caw_rt_tests' counter of the global operator new and delete.
#include <map>
#include <string>

#include "alloc_counter.h"
#include "component_bench.h"
#include "json.h"
#include "native_component_test_path.h"
#include "test.h"

using namespace caw;

namespace {

uint64_t counted() noexcept { return cawtest::threadAllocationsAndFrees(); }

std::string allocationStatus(const bench::Request& r, bool& measured, double& value) {
    bench::setAllocationCounter(&counted);
    const std::string text = bench::run(r, nullptr, nullptr);
    bench::setAllocationCounter(nullptr);
    Json j;
    std::string error;
    if (!parseJson(text, j, error) || !j.boolean("ok", false)) {
        cawtest::fail(__FILE__, __LINE__, "bench failed: " + text.substr(0, 300));
        return "";
    }
    for (const Json& c : j.get("checks")->arr)
        if (c.string("id") == "allocations") {
            measured = c.boolean("measured", false);
            value = c.number("value", -1);
            return c.string("status");
        }
    return "";
}

}  // namespace

// A component that allocates in process() fails; the test component and a built-in pass, counted.
TEST(component_bench_counts_allocations_in_the_audio_path) {
    bool measured = false;
    double value = -1;
    bench::Request bad;
    bad.id = "org.caw.tests.bench-bad";
    bad.library = CAW_TEST_BENCH_COMPONENT_PATH;
    bad.trust = NativeModuleTrust::Trusted;
    bad.seconds = 0.1;
#if defined(_WIN32) || defined(__APPLE__)
    // A loaded library's allocations can't be seen by the host's operator new here (see component_bench.cpp): the
    // check must say it didn't count them, never pass a library that allocates.
    CHECK(allocationStatus(bad, measured, value) != std::string("pass"));
    CHECK(!measured);
#else
    CHECK_EQ(allocationStatus(bad, measured, value), std::string("fail"));
    CHECK(measured && value >= 2);  // a new and a delete every block

    bench::Request good = bad;
    good.id = "org.caw.tests.native-loader";
    good.library = caw::test::nativeComponentPath();
    CHECK_EQ(allocationStatus(good, measured, value), std::string("pass"));
    CHECK(measured && value == 0);
#endif

    bench::Request builtin;
    builtin.id = "org.caw.reverb.pro";
    builtin.seconds = 0.1;
    CHECK_EQ(allocationStatus(builtin, measured, value), std::string("pass"));
    CHECK(measured && value == 0);
}
