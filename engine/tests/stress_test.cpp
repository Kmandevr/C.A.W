// The Benchmark (beta plan C, #197): its scenarios (the ten unchanged by the move out of caw_bench, the feature ones), ramps, cancel, profiles, parts, shedding.
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <algorithm>
#include <vector>

#include "audio_clips.h"
#include "caw.h"
#include "capi_internal.h"
#include "device_render.h"
#include "component_chain.h"
#include "engine.h"
#include "json.h"
#include "mix_pool.h"
#include "stress_run.h"
#include "stress_scenarios.h"
#include "test.h"
#include "tolerance.h"

using namespace caw;
using namespace caw::stress;

namespace {

// A canonical text of everything a builder sets, with the work folder written as <dir>.
std::string describeComponent(const caw::ComponentSpec& c) {
    std::string o = c.id + "{";
    for (const auto& [k, v] : c.params) o += k + "=" + std::to_string(v) + ",";
    o += c.bypass ? "b" : "";
    if (c.hasState) o += "state:" + std::string(c.state.begin(), c.state.end());
    if (c.hasKey) o += "key:" + c.key.layer + (c.key.pre ? "pre" : "post") + std::to_string(c.key.level);
    if (c.audioTrack) o += "audio:" + c.audioTrack->signature();
    return o + "}";
}
std::string describeProject(const caw::ProjectSpec& p, const std::string& dir) {
    std::string o = p.name + "|" + std::to_string(p.bpm) + "|" + std::to_string(p.beatsPerBar) + "|" + std::to_string(p.loopBars) +
                    "|" + std::to_string(p.master) + "|" + std::to_string(p.seed) + "\n";
    for (const auto& m : p.modules) o += "module " + m.id + ":" + m.source + "\n";
    for (const auto& c : p.masterComponents) o += "master " + describeComponent(c) + "\n";
    for (const auto& l : p.layers) {
        o += "layer " + l.id + "/" + l.name + " parent=" + l.parentId + (l.folder ? " folder" : "") + " vol=" + std::to_string(l.volume) +
             " pan=" + std::to_string(l.pan) + " len=" + std::to_string(l.lengthSteps) + " voices=" + std::to_string(l.noteVoices) + "\n";
        if (l.hasInstrument) o += "  inst " + describeComponent(l.instrument) + "\n";
        for (const auto& c : l.components) o += "  fx " + describeComponent(c) + "\n";
        for (const auto& c : l.noteComponents) o += "  note " + describeComponent(c) + "\n";
        for (const auto& c : l.clips)
            o += "  clip " + c.id + " " + c.pattern + " " + std::to_string(c.startSteps) + " " + std::to_string(c.lengthSteps) + " " +
                 std::to_string(c.sourceOffsetSteps) + (c.loop ? " loop" : "") + "\n";
        for (const auto& s : l.sends) o += "  send " + s.to + " " + std::to_string(s.level) + (s.pre ? " pre" : "") + "\n";
        for (const auto& a : l.automation) {  // (added with the feature scenarios: none of the ten has a lane)
            o += "  lane " + a.target;
            for (const auto& pt : a.points) o += " " + std::to_string(pt.step) + ":" + std::to_string(pt.value);
            o += "\n";
        }
    }
    for (const auto& a : p.automation) {
        o += "lane " + a.targetType + "/" + a.moduleId + "/" + std::to_string(a.component) + "/" + a.target;
        for (const auto& pt : a.points) o += " " + std::to_string(pt.step) + ":" + std::to_string(pt.value);
        o += "\n";
    }
    for (const auto& m : p.modulators) o += "mod " + m.id + " " + describeComponent(m.component) + "\n";
    for (const auto& k : p.modulation)
        o += "link " + std::to_string(k.id) + " " + k.source + " " + k.target.type + "/" + k.target.layer + "/" + k.target.param + "/" +
             std::to_string(k.target.index) + " " + std::to_string(k.amount) + (k.bipolar ? " bi" : "") + "\n";
    // The folder, raw, with forward slashes, and as JSON escapes either (the sampler's zones).
    const std::string generic = std::filesystem::path(dir).generic_string();
    for (const std::string& d : {dir, caw::jsonEscape(dir), generic, caw::jsonEscape(generic)})
        if (!d.empty())
            for (size_t at = o.find(d); at != std::string::npos; at = o.find(d, at)) o.replace(at, d.size(), "<dir>");
    return o;
}
uint64_t fnv(const void* data, size_t n, uint64_t h = 1469598103934665603ull) {
    const auto* b = static_cast<const unsigned char*>(data);
    for (size_t i = 0; i < n; ++i) h = (h ^ b[i]) * 1099511628211ull;
    return h;
}

std::string hex(uint64_t v) {
    char b[17];
    std::snprintf(b, sizeof b, "%016llx", static_cast<unsigned long long>(v));
    return b;
}

std::string workDir() {
    const std::string d = (std::filesystem::temp_directory_path() / "caw_stress_test").string();
    std::filesystem::create_directories(d);
    return d;
}

// Every builder's project, as caw_bench built it before the move (stress_scenarios.cpp keeps the code verbatim).
std::vector<std::pair<std::string, ProjectSpec>> builtProjects(const std::string& dir) {
    std::vector<std::pair<std::string, ProjectSpec>> all;
    for (const SuiteScenario& s : suiteScenarios()) all.push_back({s.id, s.make(dir)});
    all.push_back({"manyTracks5", manyTracks(5)});
    all.push_back({"withSpace", withSpace()});
    all.push_back({"busyacid", busy("org.caw.synth.acid", {})});
    all.push_back({"firstLoopBass", firstLoop("Bass")});
    for (const SuiteScenario& s : featureScenarios()) {
        ProjectSpec p;
        std::string error;
        if (!makeScenario(s, dir, p, error)) cawtest::fail(__FILE__, __LINE__, std::string(s.id) + ": " + error);
        all.push_back({s.id, p});
    }
    return all;
}

// 1 s of a project at 256-frame callbacks after caw_bench's 0.25 s to apply it, then Play.
cawtest::Audio renderSecond(const ProjectSpec& p) {
    Engine e(48000);
    e.setProject(p);
    std::vector<float> l(256), r(256);
    for (int c = 0; c < 48000 / 4 / 256; ++c) e.process(l.data(), r.data(), 256);
    e.play();
    cawtest::Audio a;
    for (int c = 0; c < 48000 / 256; ++c) {
        e.process(l.data(), r.data(), 256);
        a.l.insert(a.l.end(), l.begin(), l.end());
        a.r.insert(a.r.end(), r.begin(), r.end());
    }
    return a;
}

}  // namespace

// The builders moved from caw_bench.cpp to stress_scenarios.cpp unchanged: each project's every field hashes as it
// did from caw_bench's own code (recorded 2026-11-12 from caw_bench.cpp at d932771), and 1 s of each sounds as it did
// (the "stress" references, recorded from the same code: its renders were bit-identical to the moved code's).
// The feature scenarios (#197, from "empty" on) were recorded 2026-11-13 from their own builders, appended to the
// same references (the first fifteen entries' bytes unchanged).
TEST(stress_scenarios_unchanged_by_the_move) {
    const std::map<std::string, std::string> specHash = {
        {"first_loop", "95af7abe9529a5b7"},
        {"three_tracks", "138135367d549e76"},
        {"song8", "15d792d19d6e7797"},
        {"song8_extras", "bb8186117af81007"},
        {"flagship_heavy", "099890fdaa158835"},
        {"flagship_heavy16", "6629a11687ad9115"},
        {"drums_kit", "d99771cb320e38ed"},
        {"song16", "3f828eefc4f690a6"},
        {"song32_heavy", "bdd53e8d44177b9d"},
        {"tail", "bb8af5685f8564fa"},
        {"tail_floor", "7cc406b8f2860fd7"},
        {"manyTracks5", "483240f8ef9c5df0"},
        {"withSpace", "51a08ceed5a4ce5f"},
        {"busyacid", "56a05e15c7080b28"},
        {"firstLoopBass", "783b4b03cfd42786"},
        // The feature scenarios (#197).
        {"empty", "3bd6649147d1cd83"},
        {"single_synth", "01a803348e8d8df4"},
        {"single_sampler", "1240f9b20fa27c38"},
        {"single_drums", "6a007724565d3f4a"},
        {"single_audio", "bd797f8a4ce972cd"},
        {"folders_shallow", "97b1cffe59128192"},
        {"folders_deep", "34feeac07c4f360c"},
        {"sends_few", "3c8afb928365ef9d"},
        {"sends_many", "77a6ff8095467b29"},
        {"sends_chained", "870762500fd64e2e"},
        {"automation_light", "ba27a4298478de80"},
        {"automation_dense", "8d2dfb7c4e9e49d0"},
        {"modulation_dense", "1f037b7a0a13381a"},
        {"voice_storm", "c6b85de3f1119515"},
        {"sample_stream", "cb17fda8f1472dea"},
        {"resample", "ae1e8b3fbd5f3ad7"},
        {"every_instrument", "3ab70624484ac6bd"},
        {"every_effect", "7d5715c05ce87eca"},
        {"metering_heavy", "010ff6dc9b02b7d9"},
        {"worst_all", "ab9ee5309dd9a638"},
    };
    const std::string dir = workDir();
    cawtest::References refs("stress");
    for (const auto& [id, p] : builtProjects(dir)) {
        const auto it = specHash.find(id);
        const std::string hash = hex(fnv(describeProject(p, dir).data(), describeProject(p, dir).size()));
        if (it == specHash.end()) cawtest::fail(__FILE__, __LINE__, id + ": no hash recorded (it is " + hash + ")");
        else if (hash != it->second) cawtest::fail(__FILE__, __LINE__, id + ": the project differs from its recorded one (" + hash + ")");
        CHECK_REFERENCE(refs, id, renderSecond(p), cawtest::Class::Chaotic);
    }
}

TEST(stress_benchmark_has_the_ten_scenarios_section_h_names) {
    const char* const ids[] = {"first_loop", "three_tracks", "song8", "song8_extras", "flagship_heavy",
                               "flagship_heavy16", "drums_kit", "song16", "song32_heavy", "tail_floor"};
    const std::vector<SuiteScenario> b = benchmarkScenarios();
    CHECK(b.size() >= size_t{10});
    for (size_t k = 0; k < b.size() && k < 10; ++k) CHECK_EQ(std::string(b[k].id), std::string(ids[k]));  // first, as H2 has them
    CHECK(findScenario(b, "tail") == nullptr);  // caw_bench's tail phases only
    CHECK(findScenario(suiteScenarios(), "tail") != nullptr);
    CHECK(findScenario(suiteScenarios(), "empty") == nullptr);  // the feature scenarios aren't caw_bench's
    std::map<std::string, Tier> tier;
    for (const SuiteScenario& s : b) tier[s.id] = s.tier;
    CHECK(tier["song8"] == Tier::Normal && tier["song16"] == Tier::Heavy && tier["flagship_heavy"] == Tier::Extreme &&
          tier["song32_heavy"] == Tier::Extreme && tier["tail_floor"] == Tier::Idle && tier["drums_kit"] == Tier::Heavy);
}

// The feature scenarios (#197, the contract's table): ids, tiers and features in this order, after the ten; the
// ten's features too.
TEST(stress_benchmark_covers_every_feature) {
    struct Want { const char* id; Tier tier; const char* feature; };
    const Want want[] = {
        {"empty", Tier::Idle, "baseline"},           {"single_synth", Tier::Normal, "instrument"},
        {"single_sampler", Tier::Normal, "instrument"}, {"single_drums", Tier::Normal, "instrument"},
        {"single_audio", Tier::Normal, "audio"},     {"folders_shallow", Tier::Normal, "routing"},
        {"folders_deep", Tier::Heavy, "routing"},    {"sends_few", Tier::Normal, "sends"},
        {"sends_many", Tier::Heavy, "sends"},        {"sends_chained", Tier::Heavy, "sends"},
        {"automation_light", Tier::Normal, "automation"}, {"automation_dense", Tier::Heavy, "automation"},
        {"modulation_dense", Tier::Heavy, "modulation"}, {"voice_storm", Tier::Extreme, "voices"},
        {"sample_stream", Tier::Heavy, "samples"},   {"resample", Tier::Heavy, "samples"},
        {"every_instrument", Tier::Heavy, "instrument"}, {"every_effect", Tier::Heavy, "effect"},
        {"metering_heavy", Tier::Normal, "metering"}, {"worst_all", Tier::Extreme, "all"},
    };
    const std::vector<SuiteScenario> b = benchmarkScenarios();
    CHECK_EQ(b.size(), size_t{30});
    for (size_t k = 0; k < 20 && k + 10 < b.size(); ++k) {
        CHECK_EQ(std::string(b[k + 10].id), std::string(want[k].id));
        CHECK(b[k + 10].tier == want[k].tier);
        CHECK_EQ(std::string(b[k + 10].feature), std::string(want[k].feature));
    }
    std::map<std::string, std::string> feature;
    for (const SuiteScenario& s : b) feature[s.id] = s.feature;
    CHECK(feature["song8"] == "all" && feature["song32_heavy"] == "all" && feature["flagship_heavy"] == "instrument" &&
          feature["flagship_heavy16"] == "instrument" && feature["drums_kit"] == "instrument" && feature["tail_floor"] == "baseline");
    // The scenarios that write WAVs need the work folder, and say so without one.
    for (const char* id : {"single_sampler", "single_audio", "sample_stream", "resample", "every_instrument", "worst_all", "song8_extras"}) {
        ProjectSpec p;
        std::string error;
        CHECK(!makeScenario(*findScenario(b, id), "", p, error));
        CHECK(error.find("work folder") != std::string::npos);
    }
    // The structure each claims: folders 8 deep, 32 sends, voices past Flagship's 64.
    {
        const ProjectSpec p = folders(8, 4);
        int deepest = 0;
        for (const LayerSpec& l : p.layers) {
            int depth = 0;
            for (std::string at = l.parentId; !at.empty(); ++depth)
                for (const LayerSpec& q : p.layers)
                    if (q.id == at) { at = q.parentId; break; }
            deepest = std::max(deepest, depth);
        }
        CHECK_EQ(deepest, 8);  // a track under 8 nested folders
    }
    {
        const ProjectSpec p = sends(4, 4, false);
        size_t n = 0;
        for (const LayerSpec& l : p.layers) n += l.sends.size();
        CHECK_EQ(n, size_t{32});
    }
}

// The engine parts (#197): a profile's parts add up to its callbacks' time, and each scenario's largest part is the
// feature it measures (sends_many: sends; folders_deep: routing). Every part is listed, in the contract's order.
TEST(stress_profile_parts_add_up_and_name_the_feature) {
    const std::pair<const char*, Part> want[] = {{"sends_many", Part::Sends}, {"folders_deep", Part::Routing}};
    for (const auto& [id, dominant] : want) {
        RunRequest r;
        r.scenario = id;
        r.kind = Kind::Profile;
        r.seconds = 1.0;
        Progress p;
        const RunResult o = run(r, p, nullptr, nullptr);
        CHECK(o.ok);
        // Which part is largest is judged on each part's least mean over three runs: another process on a loaded
        // machine only ever adds time to a part, so the minimum is the part's own cost.
        std::vector<double> least(kPartCount);
        for (size_t k = 0; k < o.parts.size() && k < least.size(); ++k) least[k] = o.parts[k].meanUs;
        for (int again = 0; again < 2; ++again) {
            Progress q;
            const RunResult more = run(r, q, nullptr, nullptr);
            CHECK(more.ok);
            for (size_t k = 0; k < more.parts.size() && k < least.size(); ++k)
                least[k] = std::min(least[k], more.parts[k].meanUs);
        }
        CHECK_EQ(o.parts.size(), static_cast<size_t>(kPartCount));
        double pct = 0, us = 0;
        Part top = Part::Other;
        double topPct = -1;
        for (size_t k = 0; k < o.parts.size(); ++k) {
            CHECK(o.parts[k].part == static_cast<Part>(k));
            pct += o.parts[k].pct;
            us += o.parts[k].meanUs;
            if (least[k] > topPct) topPct = least[k], top = o.parts[k].part;
            CHECK(o.parts[k].p99Us >= 0);
        }
        CHECK_NEAR(pct, 100.0, 0.01);
        // The parts are process()'s own time; the callback's timer adds only a clock read around it.
        CHECK(us <= o.meanUs * 1.001 && us >= o.meanUs * 0.97);
#ifdef NDEBUG
        if (top != dominant) cawtest::fail(__FILE__, __LINE__, std::string(id) + ": the largest part is " + partName(top));
#else
        // An unoptimized build (the sanitizer job) times unoptimized loops, so the shares shift (its meters' loops
        // cost the most there): the feature's part is still among the two largest. Optimized builds, which the
        // Benchmark measures, check the largest above.
        int above = 0;
        for (size_t k = 0; k < least.size(); ++k) above += least[k] > least[static_cast<int>(dominant)] ? 1 : 0;
        if (above > 1) cawtest::fail(__FILE__, __LINE__, std::string(id) + ": its part is not among the two largest");
        (void)top;
#endif
        CHECK_EQ(o.parts[static_cast<int>(Part::DeviceIo)].pct, 0.0);  // live only
        // A profile is serial: the pool's own part stays near zero (judged on its least time, as above).
        CHECK(least[static_cast<int>(Part::MixPool)] < o.meanUs * 0.01);
    }
    // A plain run has none (it isn't profiled).
    RunRequest r;
    r.scenario = "folders_shallow";
    r.seconds = 0.1;
    Progress p;
    CHECK(run(r, p, nullptr, nullptr).parts.empty());
}

// The C API's JSON: every scenario's feature, and a profile job's feature and parts.
TEST(stress_json_has_features_and_parts) {
    char* list = caw_stress_scenarios();
    Json j;
    std::string error;
    CHECK(list && parseJson(list, j, error));
    caw_free(list);
    const Json* scenarios = j.get("scenarios");
    CHECK(scenarios && scenarios->arr.size() == 30);
    for (const Json& s : scenarios->arr) CHECK(!s.string("feature").empty());
    CawWorkerPool* pool = caw_worker_pool_create(1);
    CawStressRequest q{};
    q.struct_size = sizeof q;
    q.scenario = "folders_shallow";
    q.kind = CAW_STRESS_PROFILE;
    q.mode = CAW_STRESS_DSP;
    q.seconds = 0.2;
    q.quality = 1;
    CawJob* job = caw_worker_pool_submit_stress(pool, &q, CAW_JOB_FOREGROUND);
    CHECK(job != nullptr);
    if (job) {
        CHECK_EQ(caw_job_wait(job, 120000), 0);
        char* text = caw_job_result(job);
        Json r;
        CHECK(text && parseJson(text, r, error));
        caw_free(text);
        CHECK_EQ(r.string("feature"), std::string("routing"));
        const Json* parts = r.get("parts");
        CHECK(parts && parts->arr.size() == static_cast<size_t>(kPartCount));
        if (parts && !parts->arr.empty()) {
            CHECK_EQ(parts->arr[0].string("id"), std::string("mix"));
            CHECK_EQ(parts->arr.back().string("id"), std::string("other"));
            CHECK(parts->arr[0].get("mean_us") && parts->arr[0].get("p99_us") && parts->arr[0].get("pct"));
        }
        caw_job_release(job);
    }
    caw_worker_pool_destroy(pool);
}

// Live: the device callback's time outside Engine::process is its device I/O, per callback and summed.
TEST(stress_live_stats_split_device_io) {
    CawStressStats s(4);
    s.record(100e-6, 1e-3, 48, -1, 70000);   // 100 us, 70 in process: 30 device I/O
    s.record(50e-6, 1e-3, 48, -1, 60000);    // process longer than the callback (clock reads): none, never negative
    s.record(20e-6, 1e-3, 48, -1);           // not timed apart: none
    CHECK_NEAR(s.deviceIo[0], 30.0, 0.01);
    CHECK_EQ(s.deviceIo[1], 0.0f);
    CHECK_EQ(s.deviceIo[2], 0.0f);
    CHECK_EQ(s.deviceIoNs.load(), int64_t{30000});
    // The device's renderer times process() apart only while asked, and hands the time over once.
    Engine e(48000);
    e.setProject(firstLoop());
    e.play();
    DeviceRender render;
    render.open(256);
    std::vector<float> out(512);
    render.render(e, out.data(), 256);
    CHECK_EQ(render.takeProcessNs(), int64_t{0});
    render.timeProcess(true);
    const auto t0 = std::chrono::steady_clock::now();
    render.render(e, out.data(), 256);
    const int64_t wall = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now() - t0).count();
    const int64_t ns = render.takeProcessNs();
    CHECK(ns > 0 && ns <= wall);
    CHECK_EQ(render.takeProcessNs(), int64_t{0});
}

// The ramp stops at the first count over budget and searches only below it, reporting the last count that held.
TEST(stress_ramp_stops_at_the_first_step_over_budget) {
    std::vector<int32_t> tried;
    const RampOutcome o = rampSearch(rampCounts(Kind::RampTracks), [&](int32_t n) {
        tried.push_back(n);
        return n <= 23 ? 1 : 0;
    });
    CHECK_EQ(o.limit, 23);
    CHECK_EQ(o.firstFailed, 24);
    CHECK(!o.stopped);
    int32_t over = 0;
    for (int32_t n : tried) over += n > 23 ? 1 : 0;
    CHECK_EQ(over, 1);  // only the first failing step (24) ran above the limit
    for (int32_t n : tried) CHECK(n <= 24);
    // Nothing holds: 0. Everything holds: the cap, no failure.
    CHECK_EQ(rampSearch(rampCounts(Kind::RampVoices), [](int32_t) { return 0; }).limit, 0);
    const RampOutcome all = rampSearch(rampCounts(Kind::RampVoices), [](int32_t) { return 1; });
    CHECK_EQ(all.limit, 64);
    CHECK_EQ(all.firstFailed, -1);
    // A step that stops (cancel) ends the ramp there.
    int steps = 0;
    const RampOutcome stop = rampSearch(rampCounts(Kind::RampEffects), [&](int32_t) { return ++steps == 3 ? -1 : 1; });
    CHECK(stop.stopped);
    CHECK_EQ(steps, 3);
}

TEST(stress_ramp_projects_grow_with_the_count) {
    CHECK_EQ(rampProject(Kind::RampTracks, 23).layers.size(), size_t{23 + 2});  // and the reverb and delay buses
    CHECK_EQ(rampProject(Kind::RampEffects, 11).layers.front().components.size(), size_t{11});
    const ProjectSpec v = rampProject(Kind::RampVoices, 41);
    size_t notes = 0;
    for (char c : v.modules.front().source) notes += c == '\n' ? 1 : 0;
    CHECK(notes >= 41);
    CHECK_EQ(flagshipVoices(200).modules.front().source, flagshipVoices(64).modules.front().source);  // capped
}

// A real ramp, short steps: it ends at a limit consistent with what it saw, whatever the machine's speed (a
// sanitizer build holds fewer effects), and its numbers are filled.
TEST(stress_ramp_runs_on_a_real_engine) {
    RunRequest r;
    r.kind = Kind::RampEffects;
    r.seconds = 0.05;
    r.frames = 8192;  // a large budget, so a release build holds the whole ramp
    Progress p;
    LoadHistory h;
    const RunResult o = run(r, p, &h, nullptr);
    CHECK(o.ok);
    CHECK(o.limit >= 1 && o.limit <= 64);
    CHECK_EQ(p.held.load(), o.limit);
    if (o.firstFailed < 0) {
        CHECK_EQ(o.limit, 64);
        CHECK_EQ(o.stopReason, std::string("done"));
    } else {
        CHECK_EQ(o.firstFailed, o.limit + 1);  // the search closed the gap below the first failure
        CHECK_EQ(o.stopReason, std::string("over_budget"));
    }
    CHECK(o.meanUs > 0 && o.p99Us >= o.meanUs * 0.5 && o.worstUs >= o.p99Us);
    CHECK(o.p99Us <= o.budgetUs);  // the numbers are the last step that held
    CHECK_EQ(p.permille.load(), 1000);
    CHECK(h.written() > 0);
}

// Cancel takes effect within one step: the step that sees it stops at its next callback, and no step follows.
TEST(stress_cancel_takes_effect_within_one_step) {
    RunRequest r;
    r.kind = Kind::RampTracks;
    r.seconds = 600;  // a step far longer than the test
    r.frames = 8192;
    Progress p;
    std::atomic<int32_t> cancel{0};
    RunResult o;
    std::thread t([&] { o = run(r, p, nullptr, &cancel); });
    while (p.callbacks.load() < 3) std::this_thread::yield();
    const auto t0 = std::chrono::steady_clock::now();
    cancel.store(1);
    t.join();
    const double took = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
    CHECK(took < 5.0);
    CHECK_EQ(o.stopReason, std::string("cancelled"));
    CHECK(!o.ok);
    CHECK(p.step.load() <= 1);
    // A plain run too.
    RunRequest plain;
    plain.scenario = "first_loop";
    plain.seconds = 600;
    Progress q;
    std::atomic<int32_t> stop{0};
    RunResult po;
    std::thread u([&] { po = run(plain, q, nullptr, &stop); });
    while (q.callbacks.load() < 3) std::this_thread::yield();
    stop.store(1);
    u.join();
    CHECK_EQ(po.stopReason, std::string("cancelled"));
    CHECK(po.callbacks >= 3 && po.callbacks < 600 * 48000 / 256);
}

TEST(stress_plain_run_counts_callbacks_and_history) {
    RunRequest r;
    r.scenario = "three_tracks";
    r.seconds = 1.0;
    Progress p;
    LoadHistory h;
    const RunResult o = run(r, p, &h, nullptr);
    CHECK(o.ok);
    CHECK_EQ(o.callbacks, int64_t{48000 / 256});
    CHECK_NEAR(o.budgetUs, 1e6 * 256 / 48000, 1e-9);
    CHECK_EQ(h.written(), 9u);  // a point per 100 ms of audio: 187 callbacks of 256 frames are 9.97 points
    float pts[16];
    uint32_t next = 0;
    CHECK_EQ(h.read(0, pts, 16, &next), static_cast<int32_t>(h.written()));
    CHECK_EQ(next, h.written());
    CHECK(pts[0] > 0);
    // Unknown scenarios and song8_extras without a work folder fail with a reason.
    RunRequest bad;
    bad.scenario = "nope";
    Progress q;
    CHECK_EQ(run(bad, q, nullptr, nullptr).stopReason, std::string("error"));
    bad.scenario = "song8_extras";
    CHECK(run(bad, q, nullptr, nullptr).error.find("work folder") != std::string::npos);
    bad.scenario = "song8_extras";
    bad.workDir = workDir();
    bad.seconds = 0.1;
    CHECK(run(bad, q, nullptr, nullptr).ok);
}

TEST(stress_history_ring_keeps_the_newest_points) {
    LoadHistory h;
    for (uint32_t k = 0; k < LoadHistory::kCapacity + 10; ++k) h.push(static_cast<float>(k));
    std::vector<float> out(LoadHistory::kCapacity + 10);
    uint32_t next = 0;
    const int32_t n = h.read(0, out.data(), static_cast<int32_t>(out.size()), &next);
    CHECK_EQ(n, static_cast<int32_t>(LoadHistory::kCapacity));
    CHECK_EQ(out[0], 10.0f);  // the 10 oldest were overwritten
    CHECK_EQ(next, LoadHistory::kCapacity + 10);
    CHECK_EQ(h.read(next, out.data(), 4, &next), 0);
}

// The profile is the engine's own: two engines profiling on two threads at once each get their own rows.
TEST(stress_profiles_are_per_engine) {
    RunResult a, b;
    std::thread ta([&] {
        RunRequest r;
        r.scenario = "song8";
        r.kind = Kind::Profile;
        r.seconds = 0.5;
        Progress p;
        a = run(r, p, nullptr, nullptr);
    });
    std::thread tb([&] {
        RunRequest r;
        r.scenario = "drums_kit";
        r.kind = Kind::Profile;
        r.seconds = 0.5;
        Progress p;
        b = run(r, p, nullptr, nullptr);
    });
    ta.join();
    tb.join();
    CHECK(a.ok && b.ok);
    auto ids = [](const RunResult& o) {
        std::map<std::string, double> m;
        double sum = 0;
        for (const CostRow& c : o.costs) m[c.id] = c.pct, sum += c.pct;
        CHECK(sum > 99.0 && sum < 101.0);
        return m;
    };
    const auto ma = ids(a), mb = ids(b);
    CHECK(ma.count("host") && mb.count("host"));
    CHECK(ma.count("org.caw.reverb.pro") == 1);   // the song's
    CHECK(mb.count("org.caw.reverb.pro") == 0);   // the kit has none: nothing of the song's leaked into its rows
    CHECK(mb.count("org.caw.drums") == 1);
    CHECK(ma.count("org.caw.mod.lfo") == 1);      // the song's LFOs: modulators get the profile too
}

// The profile travels in each chain's ChainTime, not in thread state: an engine without one, run on the same
// thread between a profiling engine's callbacks, adds nothing to it.
TEST(stress_profile_travels_with_its_engine_only) {
    Engine a(48000), b(48000);
    a.setProject(drumsBusy());
    b.setProject(typicalSong(false));
    auto profile = std::make_unique<ChainProfile>();
    a.setProfile(profile.get());
    a.play();
    b.play();
    std::vector<float> l(256), r(256);
    for (int c = 0; c < 100; ++c) {
        a.process(l.data(), r.data(), 256);
        b.process(l.data(), r.data(), 256);
    }
    a.setProfile(nullptr);
    bool drums = false, reverb = false;
    for (uint32_t k = 0; k < profile->used; ++k) {
        const std::string id = profile->slots[k].id ? *profile->slots[k].id : "";
        drums = drums || id == "org.caw.drums";
        reverb = reverb || id == "org.caw.reverb.pro";
    }
    CHECK(drums);
    CHECK(!reverb);
}

// The Benchmark's engine sheds nothing; any other sheds a layer when the device runs out of time.
TEST(stress_shedding_can_be_switched_off) {
    for (const bool on : {true, false}) {
        Engine e(48000);
        e.setShedding(on);
        e.setProject(firstLoop());
        std::vector<float> l(512), r(512);
        e.process(l.data(), r.data(), 512);
        e.play();
        for (int c = 0; c < 400; ++c) {
            e.process(l.data(), r.data(), 512);
            e.reportLoad(2.0, 512);
        }
        CHECK_EQ(e.meters().overloaded > 0, on);
    }
}

// Live mode's callback record: each callback's size kept (devices may vary it), the core read only on the first
// callback and every kCoreEvery-th, never a stale -1 over a known core.
TEST(stress_live_stats_sum_frames_and_sample_the_core) {
    CawStressStats s(8);
    int reads = 0;
    for (int c = 0; c < 130; ++c) {
        const int32_t frames = c % 2 ? 96 : 192;
        int32_t cpu = -1;
        if (s.coreDue()) {
            cpu = 3;
            ++reads;
        }
        s.record(frames / 48000.0 * (c == 5 ? 2.0 : 0.5), frames / 48000.0, frames, cpu);
    }
    CHECK_EQ(reads, 3);  // callbacks 0, 64 and 128
    CHECK_EQ(s.core.load(), 3);
    CHECK_EQ(s.framesSum.load(), int64_t{65 * 192 + 65 * 96});
    CHECK_EQ(s.written.load(), int64_t{130});
    CHECK_EQ(s.overBudget.load(), int64_t{1});
    CHECK_EQ(s.frames[1], 96);  // kept per callback while there is room
    CHECK_NEAR(s.loads[5], 2.0, 1e-6);
}

// Turning shedding off restores what was shed (bt-clicks' shedding reset) and sheds nothing after; on again starts
// clean.
TEST(stress_shedding_off_restores_shed_layers) {
    Engine e(48000);
    e.setProject(firstLoop());
    std::vector<float> l(512), r(512);
    e.process(l.data(), r.data(), 512);
    e.play();
    for (int c = 0; c < 400; ++c) {
        e.process(l.data(), r.data(), 512);
        e.reportLoad(2.0, 512);
    }
    CHECK(e.meters().overloaded > 0);
    e.setShedding(false);
    for (int c = 0; c < 400; ++c) {
        e.process(l.data(), r.data(), 512);
        e.reportLoad(2.0, 512);
    }
    CHECK_EQ(e.meters().overloaded, 0);
    e.setShedding(true);
    e.process(l.data(), r.data(), 512);
    CHECK_EQ(e.meters().overloaded, 0);  // clean: no history carried over
}

// A profiling engine's mix stays serial even with a pool on Always (its profile is filled by one thread), and goes
// back to the pool once the profile is off.
TEST(stress_profiling_keeps_the_mix_serial) {
    Engine e(48000);
    CHECK(e.startMixPool(2));
    e.setMixParallel(Engine::MixParallel::Always);
    e.setProject(bigSong(8, false));
    std::vector<float> l(256), r(256);
    e.process(l.data(), r.data(), 256);
    e.play();
    for (int c = 0; c < 20; ++c) e.process(l.data(), r.data(), 256);
    CHECK(e.mixParallelForTest());
    auto profile = std::make_unique<ChainProfile>();
    e.setProfile(profile.get());
    for (int c = 0; c < 50; ++c) {
        e.process(l.data(), r.data(), 256);
        CHECK(!e.mixParallelForTest());
    }
    e.setProfile(nullptr);
    CHECK(profile->used > 8);
    e.process(l.data(), r.data(), 256);
    CHECK(e.mixParallelForTest());
    e.stopMixPool();
}

// The S22+ Benchmark review (2026-11-13): Plain, Sustained and ramp runs measure the app's figure (the mix pool on
// Auto, each callback's load reported as a device's), after an untimed warm-up that covers Auto's decision and
// settle; the first callback after Play is kept apart, the worst's time counts from Play, and the trend is a
// least-squares slope. Profile stays on one thread.
TEST(stress_dsp_runs_use_the_pool_on_auto_after_a_warm_up) {
    CHECK_NEAR(warmupSeconds(false), kWarmupSeconds, 1e-12);
    CHECK_NEAR(warmupSeconds(true), kWarmupSeconds + Engine::kMixParallelSeconds + Engine::kMixSettleSeconds, 1e-12);
    const double x[] = {0, 1, 2, 3}, y[] = {1, 3, 5, 7}, flat[] = {2, 2, 2, 2};
    CHECK_NEAR(slope(x, y, 4), 2.0, 1e-12);
    CHECK_NEAR(slope(x, flat, 4), 0.0, 1e-12);
    CHECK_NEAR(slope(x, y, 1), 0.0, 1e-12);

    RunRequest r;
    r.scenario = "three_tracks";
    r.seconds = 0.5;
    Progress p;
    const RunResult o = run(r, p, nullptr, nullptr);
    CHECK(o.ok);
    CHECK_EQ(o.callbacks, int64_t{48000 / 2 / 256});  // the warm-up is not timed
    CHECK_EQ(p.callbacks.load(), o.callbacks);
    CHECK_NEAR(o.warmupS, warmupSeconds(true), 256.0 / 48000);
    CHECK(o.firstCallbackUs > 0);
    CHECK(o.worstAtS >= o.warmupS && o.worstAtS <= o.warmupS + o.seconds);
    // The run's own pool, unless a test's pool stays (caw_tests --mix-threads N: N workers, 0 none).
    const uint32_t want = Engine::mixThreadsForTest() >= 0 ? Engine(48000).mixWorkers() : MixPool::defaultWorkers();
    CHECK_EQ(o.mixWorkers, want);
    CHECK(o.mixActive <= o.mixWorkers);
    CHECK(std::isfinite(o.slopePctPerMin));

    RunRequest prof = r;
    prof.kind = Kind::Profile;
    Progress q;
    const RunResult po = run(prof, q, nullptr, nullptr);
    CHECK(po.ok);
    const uint32_t own = Engine(48000).mixWorkers();  // 0, or a parallel shard's test pool (setMixThreadsForTest)
    CHECK_EQ(po.mixWorkers, own);           // no pool of the run's own: a profile is filled by one thread
    CHECK_NEAR(po.warmupS, 1.0, 256.0 / 48000);  // 1 s before the profile, as before
    CHECK(!po.costs.empty());

    // A ramp's numbers are its last held step's, warm-up included.
    RunRequest ramp;
    ramp.kind = Kind::RampVoices;
    ramp.seconds = 0.05;
    ramp.frames = 8192;
    Progress s;
    const RunResult ro = run(ramp, s, nullptr, nullptr);
    CHECK(ro.ok);
    CHECK(ro.limit >= 1);
    CHECK(ro.warmupS >= warmupSeconds(true) - 8192.0 / 48000);
    CHECK(ro.firstCallbackUs > 0);
}

// The audio review of the polish (2026-11-13): a Benchmark run starts no pool of its own while a live device runs
// (it would take the cores from the live audio), as offline renders don't; a test's pool stays as the test set it.
TEST(stress_dsp_runs_stay_serial_while_a_live_device_runs) {
    const uint32_t own = Engine(48000).mixWorkers();  // 0, or a parallel shard's test pool
    Engine live(48000);
    live.startLiveMixPool();
    CHECK(Engine::liveDevices() > 0);
    RunRequest r;
    r.scenario = "three_tracks";
    r.seconds = 0.2;
    Progress p;
    const RunResult o = run(r, p, nullptr, nullptr);
    live.stopLiveMixPool();
    CHECK(o.ok);
    CHECK_EQ(o.mixWorkers, own);
    Engine e(48000);
    if (Engine::mixThreadsForTest() < 0) {
        CHECK(e.useBenchmarkMixPool());
        CHECK_EQ(e.mixWorkers(), MixPool::defaultWorkers());
    } else {
        CHECK(!e.useBenchmarkMixPool());  // the test's pool stays
        CHECK_EQ(e.mixWorkers(), own);
    }
}

// A device that calls back with its own sizes varies the length every callback; the load's weights for each length
// are the same as for a steady size (kept for the last few lengths, not recomputed), so the meter reads the load.
TEST(stress_varying_callback_lengths_meter_the_load) {
    Engine e(48000);
    e.setShedding(false);
    for (int k = 0; k < 4000; ++k) {
        const int frames = (k % 3 == 0) ? 96 : (k % 3 == 1) ? 192 : 144;
        e.reportLoad(0.5, frames, frames);
    }
    CHECK_NEAR(e.meters().cpu, 0.5, 1e-6);
}
