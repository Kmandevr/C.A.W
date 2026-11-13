// The plug-in benchmark (#197): its checks, sections, curves and refusals, on the test component, the bad fixture and built-ins.
#include <atomic>
#include <cstring>
#include <map>
#include <string>
#include <thread>

#include "builtin_components.h"
#include "caw.h"
#include "component_bench.h"
#include "json.h"
#include "native_component_test_path.h"
#include "test.h"

using namespace caw;

namespace {

Json benchJson(const bench::Request& r) {
    Json j;
    std::string error;
    const std::string text = bench::run(r, nullptr, nullptr);
    if (!parseJson(text, j, error)) cawtest::fail(__FILE__, __LINE__, "not JSON: " + text.substr(0, 200));
    return j;
}

bench::Request library(const char* path, const char* id, double seconds = 0.2) {
    bench::Request r;
    r.id = id;
    r.library = path ? path : "";
    r.trust = NativeModuleTrust::Trusted;
    r.seconds = seconds;
    return r;
}

std::map<std::string, const Json*> checksOf(const Json& j) {
    std::map<std::string, const Json*> out;
    if (const Json* c = j.get("checks"))
        for (const Json& x : c->arr) out[x.string("id")] = &x;
    return out;
}

}  // namespace

// The test component (doubles its input): an effect's checks, without the instrument's, and its curves.
TEST(component_bench_measures_an_effect) {
    const Json j = benchJson(library(caw::test::nativeComponentPath(), "org.caw.tests.native-loader"));
    CHECK(j.boolean("ok", false));
    CHECK_EQ(j.string("tool"), std::string("caw_component_bench"));
    CHECK_EQ(j.number("format", 0), 1.0);
    const Json* component = j.get("component");
    CHECK(component && component->string("kind") == "effect" && component->string("id") == "org.caw.tests.native-loader");
    CHECK(j.number("mean_us", -1) >= 0 && j.number("p99_us", -1) >= j.number("mean_us", -1) * 0.5);
    CHECK_NEAR(j.number("budget_us", 0), 1e6 * 64 / 48000, 1e-3);
    const auto checks = checksOf(j);
    for (const char* id : {"allocations", "denormals", "block_size_scaling", "sample_rate_scaling", "param_change_cost", "silence_cost"})
        CHECK(checks.count(id) == 1);
    CHECK(checks.count("cost_per_voice") == 0);  // instruments only
    for (const auto& [id, c] : checks) {
        const std::string s = c->string("status");
        CHECK(s == "pass" || s == "warn" || s == "fail");
        CHECK(!c->string("detail").empty());
    }
    // caw_tests counts no allocations (caw_rt_tests does): the check says so instead of passing.
    CHECK(checks.at("allocations")->string("status") == "warn" && !checks.at("allocations")->boolean("measured", true));
    // A gain is too cheap for any ratio to matter, and it makes no subnormals.
    CHECK_EQ(checks.at("denormals")->string("status"), std::string("pass"));
    CHECK_EQ(checks.at("block_size_scaling")->string("status"), std::string("pass"));
    const Json* curves = j.get("curves");
    CHECK(curves && curves->get("voices")->arr.empty() && curves->get("block_frames")->arr.size() == 5 &&
          curves->get("sample_rate")->arr.size() == 3);
    CHECK_EQ(curves->get("block_frames")->arr[0].arr[0].num, 32.0);
    CHECK_EQ(curves->get("sample_rate")->arr[2].arr[0].num, 96000.0);
    CHECK(j.get("sections")->arr.empty());  // it times no sections
}

// A built-in instrument: the voices curve and its per-voice check.
TEST(component_bench_measures_an_instrument_per_voice) {
    bench::Request r;
    r.id = "org.caw.synth.flagship";
    r.seconds = 0.2;
    const Json j = benchJson(r);
    CHECK(j.boolean("ok", false));
    CHECK_EQ(j.get("component")->string("kind"), std::string("instrument"));
    const auto checks = checksOf(j);
    CHECK(checks.count("cost_per_voice") == 1 && checks.at("cost_per_voice")->number("value", -1) > 0);
    const Json* voices = j.get("curves")->get("voices");
    CHECK(voices && voices->arr.size() == 5);
    if (voices && voices->arr.size() == 5) {
        CHECK_EQ(voices->arr[0].arr[0].num, 1.0);
        CHECK_EQ(voices->arr[4].arr[0].num, 16.0);
        CHECK(voices->arr[4].arr[1].num > voices->arr[0].arr[1].num);  // 16 held voices cost more than one
    }
}

// The bad fixture: subnormal output at silence without flush-to-zero, and its CAW_PROFILE_SCOPE sections.
TEST(component_bench_flags_denormals_and_times_sections) {
    const Json j = benchJson(library(CAW_TEST_BENCH_COMPONENT_PATH, "org.caw.tests.bench-bad"));
    CHECK(j.boolean("ok", false));
    const auto checks = checksOf(j);
    CHECK(checks.count("denormals") == 1);
    if (checks.count("denormals")) {
        CHECK(checks.at("denormals")->string("status") != "pass");
        CHECK(checks.at("denormals")->string("detail").find("subnormal output") != std::string::npos);
    }
    std::map<std::string, const Json*> sections;
    for (const Json& s : j.get("sections")->arr) sections[s.string("name")] = &s;
    CHECK(sections.count("decay") == 1 && sections.count("alloc") == 1);
    if (sections.count("decay")) {
        // Every block of the base run (0.2 s of 64-frame blocks, and the untimed start) entered it once.
        CHECK(sections.at("decay")->number("calls", 0) >= 150);
        CHECK(sections.at("decay")->number("pct", 0) > 0 && sections.at("decay")->number("pct", 0) <= 100.5);
        CHECK(sections.at("decay")->number("mean_ns", 0) > 0);
    }
}

// Only the bench's own thread records sections: the same library playing elsewhere meanwhile adds nothing.
TEST(component_bench_sections_ignore_other_threads) {
    ModuleRegistry registry;
    registerBuiltinComponents(registry);
    CHECK(registry.loadSharedLibrary(CAW_TEST_BENCH_COMPONENT_PATH, "org.caw.tests.bench-bad", NativeModuleTrust::Trusted).success);
    std::unique_ptr<ModuleProcessor> p = registry.create("org.caw.tests.bench-bad");
    CHECK(p && p->activate(48000, 64));
    std::atomic<bool> stop{false};
    std::atomic<int> blocks{0};
    std::thread other([&] {
        float l[64] = {}, r[64] = {}, ol[64], orr[64];
        const float* in[2] = {l, r};
        float* out[2] = {ol, orr};
        while (!stop.load()) {
            const AudioProcessBlock b{{in, 2, 64}, {out, 2, 64}, 64, 48000.0, nullptr, 0, nullptr};
            p->process(b);
            blocks.fetch_add(1);
        }
    });
    while (blocks.load() < 10) std::this_thread::yield();
    bench::Request r;
    r.id = "org.caw.eq";
    r.seconds = 0.1;
    const Json j = benchJson(r);
    stop = true;
    other.join();
    p->deactivate();
    CHECK(j.boolean("ok", false));
    CHECK(j.get("sections")->arr.empty());
}

// Never an untrusted library: Blocked and Isolated are refused before anything is loaded, by run() and the C API.
TEST(component_bench_refuses_untrusted_libraries) {
    for (NativeModuleTrust t : {NativeModuleTrust::Blocked, NativeModuleTrust::Isolated}) {
        bench::Request r = library(caw::test::nativeComponentPath(), "org.caw.tests.native-loader");
        r.trust = t;
        const Json j = benchJson(r);
        CHECK(!j.boolean("ok", true));
        CHECK(j.string("error").find("Trusted") != std::string::npos);
    }
    bench::Request unknown;
    unknown.id = "org.example.not-built-in";
    CHECK(!benchJson(unknown).boolean("ok", true));
    CawWorkerPool* pool = caw_worker_pool_create(1);
    CawComponentBenchRequest q{};
    q.struct_size = sizeof q;
    q.component_id = "org.caw.tests.native-loader";
    q.library = caw::test::nativeComponentPath();
    for (int32_t t : {CAW_NATIVE_TRUST_BLOCKED, CAW_NATIVE_TRUST_ISOLATED}) {
        q.trust_level = t;
        CHECK(caw_worker_pool_submit_component_bench(pool, &q) == nullptr);
    }
    q.trust_level = CAW_NATIVE_TRUST_TRUSTED;
    q.seconds = 20;  // past 10
    CHECK(caw_worker_pool_submit_component_bench(pool, &q) == nullptr);
    q.struct_size = 8;
    q.seconds = 0;
    CHECK(caw_worker_pool_submit_component_bench(pool, &q) == nullptr);
    caw_worker_pool_destroy(pool);
}

// The C API job: a built-in benched on a worker, its JSON the job's result; progress reaches 1000.
TEST(component_bench_runs_as_a_job) {
    CawWorkerPool* pool = caw_worker_pool_create(1);
    CawComponentBenchRequest q{};
    q.struct_size = sizeof q;
    q.component_id = "org.caw.chorus";
    q.seconds = 0.1;
    CawJob* job = caw_worker_pool_submit_component_bench(pool, &q);
    CHECK(job != nullptr);
    if (job) {
        CHECK_EQ(caw_job_wait(job, 120000), 0);
        CawJobStatus st{};
        st.struct_size = sizeof st;
        CHECK_EQ(caw_job_get_status(job, &st), 0);
        CHECK_EQ(st.state, int32_t{2});  // succeeded
        CHECK_EQ(st.progress, int32_t{1000});
        char* text = caw_job_result(job);
        Json j;
        std::string error;
        CHECK(text && parseJson(text, j, error) && j.boolean("ok", false) && j.get("component")->string("id") == "org.caw.chorus");
        caw_free(text);
        caw_job_release(job);
    }
    // Cancelled before it ran or while it runs: it ends cancelled (or, if it was quicker, succeeded).
    q.seconds = 10;
    CawJob* slow = caw_worker_pool_submit_component_bench(pool, &q);
    CHECK(slow != nullptr);
    if (slow) {
        caw_job_cancel(slow);
        CHECK_EQ(caw_job_wait(slow, 120000), 0);
        CawJobStatus st{};
        st.struct_size = sizeof st;
        caw_job_get_status(slow, &st);
        CHECK(st.state == 4 || st.state == 2);
        caw_job_release(slow);
    }
    caw_worker_pool_destroy(pool);
}
