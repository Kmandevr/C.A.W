// The Benchmark's C API (API 27): its scenarios, its jobs' runs (DSP on the worker, live through a muted device).
#include "capi_stress.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <thread>

#include "capi_internal.h"
#include "engine.h"
#include "json.h"
#include "thread_tuning.h"

namespace caw::stress {

namespace {

char* duplicate(const std::string& value) {
    auto* result = static_cast<char*>(std::malloc(value.size() + 1));
    if (result) std::memcpy(result, value.c_str(), value.size() + 1);
    return result;
}

const char* kindName(Kind k) {
    switch (k) {
        case Kind::Plain: return "plain";
        case Kind::RampTracks: return "ramp_tracks";
        case Kind::RampVoices: return "ramp_voices";
        case Kind::RampEffects: return "ramp_effects";
        case Kind::Sustained: return "sustained";
        case Kind::Profile: return "profile";
    }
    return "plain";
}

std::string num(double v) { return std::isfinite(v) ? std::to_string(v) : "0"; }
std::string str(const std::string& v) { return "\"" + jsonEscape(v) + "\""; }

std::string resultJson(const Job& j) {
    const RunResult& r = j.result;
    const bool live = j.mode == CAW_STRESS_LIVE;
    const int frames = live ? j.deviceFrames : j.request.frames;
    const int rate = live ? j.deviceRate : j.request.rate;
    const int64_t dropouts = live && j.xruns >= 0 ? j.xruns : r.overBudget;
    const double b = r.budgetUs > 0 ? r.budgetUs : 1.0;
    std::string o = "{\"ok\":" + std::string(r.ok || r.stopReason == "over_budget" ? "true" : "false") +
                    ",\"mode\":" + str(live ? "live" : "dsp") + ",\"kind\":" + str(kindName(j.request.kind)) +
                    ",\"scenario\":" + str(j.scenarioId) + ",\"frames\":" + std::to_string(frames) +
                    ",\"sample_rate\":" + std::to_string(rate) + ",\"budget_us\":" + num(r.budgetUs) +
                    ",\"mean_us\":" + num(r.meanUs) + ",\"p99_us\":" + num(r.p99Us) + ",\"worst_us\":" + num(r.worstUs) +
                    ",\"worst_at_s\":" + num(r.worstAtS) + ",\"mean_first_us\":" + num(r.meanFirstUs) +
                    ",\"mean_last_us\":" + num(r.meanLastUs) + ",\"mean_pct\":" + num(100 * r.meanUs / b) +
                    ",\"p99_pct\":" + num(100 * r.p99Us / b) + ",\"worst_pct\":" + num(100 * r.worstUs / b) +
                    ",\"callbacks\":" + std::to_string(r.callbacks) + ",\"over_budget\":" + std::to_string(r.overBudget) +
                    ",\"dropouts\":" + std::to_string(dropouts) + ",\"xruns\":" + std::to_string(j.xruns) +
                    ",\"limit\":" + std::to_string(r.limit) + ",\"first_failed\":" + std::to_string(r.firstFailed) +
                    ",\"steps\":" + std::to_string(r.steps) + ",\"seconds\":" + num(r.seconds) +
                    ",\"stop_reason\":" + str(r.stopReason) + ",\"error\":" + str(r.error) +
                    ",\"callback_core\":" + std::to_string(j.callbackCore) +
                    // Local only (not in H2): the warm-up, the first callback after Play, the trend, the core's
                    // clock at the timed span's start and end, the mix pool, what was asked, and what the budget is.
                    ",\"requested_frames\":" + std::to_string(j.request.frames) + ",\"warmup_s\":" + num(r.warmupS) +
                    ",\"first_callback_us\":" + num(r.firstCallbackUs) + ",\"slope_pct_per_min\":" + num(r.slopePctPerMin) +
                    ",\"core_start\":" + std::to_string(r.coreStart) + ",\"core_end\":" + std::to_string(r.coreEnd) +
                    ",\"core_khz_start\":" + std::to_string(r.khzStart) + ",\"core_khz_end\":" + std::to_string(r.khzEnd) +
                    ",\"core_max_khz\":" + std::to_string(r.maxKHz) + ",\"mix_workers\":" + std::to_string(r.mixWorkers) +
                    ",\"mix_active_workers\":" + std::to_string(r.mixActive) +
                    ",\"warmup_xruns\":" + std::to_string(live ? j.warmupXruns : -1) +
                    // Live: each callback's budget is its own length, not its real deadline (the frames the device
                    // has queued), so over_budget overstates; the platform's xruns are the dropouts heard.
                    ",\"budget_basis\":" + str(live ? "callback_length" : "callback") + ",\"costs\":[";
    for (size_t k = 0; k < r.costs.size(); ++k) {
        const CostRow& c = r.costs[k];
        o += std::string(k ? "," : "") + "{\"id\":" + str(c.id) + ",\"ns\":" + std::to_string(c.ns) + ",\"pct\":" + num(c.pct) +
             ",\"ran_pct\":" + num(c.ranPct) + ",\"instances\":" + std::to_string(c.instances) +
             ",\"modulator\":" + (c.modulator ? "true" : "false") + "}";
    }
    return o + "]}";
}

// Live: the scenario through the default output device, muted, its real callbacks timed. The device's callback
// stores each callback's time, load and size into preallocated stats; this thread reads them every 100 ms.
RunResult runLive(Job& j) {
    const RunRequest& r = j.request;
    RunResult out;
    auto failed = [&](const std::string& why) {
        out.ok = false;
        out.stopReason = "error";
        out.error = why;
        return out;
    };
    ProjectSpec p;
    {
        const std::vector<SuiteScenario> all = benchmarkScenarios();
        const SuiteScenario* s = findScenario(all, r.scenario);
        if (!s) return failed("no scenario '" + r.scenario + "'");
        std::string error;
        if (r.scenario == "song8_extras") {
            if (r.workDir.empty()) return failed("song8_extras needs a work folder");
            p = typicalSong(true, r.workDir, &error);
            if (!error.empty()) return failed(error);
        } else {
            p = s->make(r.workDir);
        }
    }
    // Room for every callback of the run at 16 frames or more; past that only the counts go on. Made before the
    // engine, so it outlives it: the guard below stops the device and unhooks it first, whatever happens.
    const size_t capacity = static_cast<size_t>(std::min(4.0e6, r.seconds * r.rate / 16.0 + 64));
    auto meter = std::make_unique<CawStressStats>(capacity);
    CawEngine* e = caw_engine_create(r.rate);
    if (!e) return failed("could not make the engine");
    struct Guard {
        CawEngine* e;
        ~Guard() {
            caw_audio_stop(e);  // the callback has stopped once this returns
            e->stress.store(nullptr, std::memory_order_release);
            caw_engine_destroy(e);
        }
    } guard{e};
    e->engine->setQuality(r.quality);
    e->engine->setShedding(false);
    const std::string warn = e->engine->setProject(p);
    if (warn.find("\"ok\":true") == std::string::npos) return failed("the project did not load: " + warn.substr(0, 300));
    // The low-latency profile at the size asked: 1024 frames is Auto while not recording (the app's playing buffer,
    // audio_miniaudio.cpp's kLargeBufferFrames), 0 Low latency (AAudio's own burst-sized callbacks).
    e->bufferMode = CAW_BUFFER_LOW_LATENCY;
    e->periodFrames = r.frames;
    e->muteOutput.store(true, std::memory_order_relaxed);
    e->stress.store(meter.get(), std::memory_order_release);
    char error[256] = {};
    if (caw_audio_start(e, error, sizeof error) != 0) return failed(std::string("the audio device did not start: ") + error);
    using Clock = std::chrono::steady_clock;
    auto cancelled = [&] { return j.cancel.load(std::memory_order_relaxed) != 0; };
    std::this_thread::sleep_for(std::chrono::milliseconds(250));  // the project applied, as the DSP runs give it
    const int32_t xrunsPlay = cawAudioXruns(e);
    const int64_t atPlay = meter->written.load(std::memory_order_acquire);
    e->engine->play();
    // The warm-up, untimed: as the DSP runs', with Auto's decision and settle (the device's mix pool is on Auto).
    const auto played = Clock::now();
    const double warmup = warmupSeconds(true);
    while (!cancelled() && std::chrono::duration<double>(Clock::now() - played).count() < warmup)
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    const int32_t xrunsFrom = cawAudioXruns(e);
    const int64_t from = meter->written.load(std::memory_order_acquire);
    int64_t usedFrom = meter->usedNs.load(std::memory_order_relaxed), budgetFrom = meter->budgetNs.load(std::memory_order_relaxed);
    const int64_t overFrom = meter->overBudget.load(std::memory_order_relaxed);
    const int64_t budgetStart = budgetFrom, framesStart = meter->framesSum.load(std::memory_order_relaxed);
    int64_t framesWarm = 0;  // the frames played after Play before the timed span
    for (int64_t c = atPlay; c < std::min<int64_t>(from, static_cast<int64_t>(capacity)); ++c) framesWarm += meter->frames[static_cast<size_t>(c)];
    out.warmupS = static_cast<double>(framesWarm) / r.rate;
    if (atPlay < from && atPlay < static_cast<int64_t>(capacity)) out.firstCallbackUs = meter->times[static_cast<size_t>(atPlay)];
    {
        const int32_t core = meter->core.load(std::memory_order_relaxed);
        const tuning::CoreClock c = tuning::coreClock(core);
        out.coreStart = core;
        out.khzStart = c.currentKHz;
        out.maxKHz = c.maxKHz;
    }
    const auto t0 = Clock::now();
    auto lastCallback = t0;
    int64_t seen = from;
    bool stopped = false, stalled = false;
    for (;;) {
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
        const auto now = Clock::now();
        const double elapsed = std::chrono::duration<double>(now - t0).count();
        const int64_t written = meter->written.load(std::memory_order_relaxed);
        if (written != seen) {
            seen = written;
            lastCallback = now;
        } else if (std::chrono::duration<double>(now - lastCallback).count() > 1.0) {
            stalled = true;  // no callback for a second: the device stopped or was taken away
            break;
        }
        const int64_t used = meter->usedNs.load(std::memory_order_relaxed), budget = meter->budgetNs.load(std::memory_order_relaxed);
        const float load = budget > budgetFrom ? static_cast<float>(static_cast<double>(used - usedFrom) / static_cast<double>(budget - budgetFrom)) : 0.0f;
        usedFrom = used;
        budgetFrom = budget;
        j.history.push(load);
        j.progress.load.store(load, std::memory_order_relaxed);
        j.progress.callbacks.store(written - from, std::memory_order_relaxed);
        j.progress.overBudget.store(meter->overBudget.load(std::memory_order_relaxed) - overFrom, std::memory_order_relaxed);
        j.progress.permille.store(static_cast<int32_t>(std::min(999.0, 1000.0 * elapsed / r.seconds)), std::memory_order_relaxed);
        if (cancelled()) {
            stopped = true;
            break;
        }
        if (elapsed >= r.seconds) break;
    }
    const int32_t xrunsTo = cawAudioXruns(e);
    const int32_t deviceFrames = caw_audio_buffer_frames(e);
    {
        const int32_t core = meter->core.load(std::memory_order_relaxed);
        const tuning::CoreClock c = tuning::coreClock(core);
        out.coreEnd = core;
        out.khzEnd = c.currentKHz;
        out.maxKHz = std::max(out.maxKHz, c.maxKHz);
    }
    out.mixWorkers = e->engine->mixWorkers();
    out.mixActive = e->engine->mixActiveWorkers();
    caw_audio_stop(e);  // the callback has stopped once this returns
    e->stress.store(nullptr, std::memory_order_release);
    const int64_t total = meter->written.load(std::memory_order_acquire);
    const int64_t to = std::min<int64_t>(total, static_cast<int64_t>(capacity));
    std::vector<double> us;
    std::vector<int64_t> startFrame;  // each timed callback's first frame, counted from Play
    us.reserve(static_cast<size_t>(std::max<int64_t>(0, to - from)));
    startFrame.reserve(us.capacity());
    int64_t at = 0;
    for (int64_t c = from; c < to; ++c) {
        us.push_back(meter->times[static_cast<size_t>(c)]);
        startFrame.push_back(at);
        at += meter->frames[static_cast<size_t>(c)];
    }
    {
        std::lock_guard<std::mutex> lock(j.mutex);
        j.deviceFrames = deviceFrames;
        j.deviceRate = r.rate;
        j.xruns = xrunsFrom >= 0 && xrunsTo >= xrunsFrom ? xrunsTo - xrunsFrom : -1;
        j.warmupXruns = xrunsPlay >= 0 && xrunsFrom >= xrunsPlay ? xrunsFrom - xrunsPlay : -1;
        j.callbackCore = meter->core.load(std::memory_order_relaxed);
    }
    out.callbacks = total - from;
    out.overBudget = meter->overBudget.load(std::memory_order_relaxed) - overFrom;
    // Callback sizes may vary: the budget is the mean of the callbacks' own, the audio the sum of their frames.
    const int64_t budgetNs = meter->budgetNs.load(std::memory_order_relaxed) - budgetStart;
    out.budgetUs = out.callbacks > 0 ? 1e-3 * static_cast<double>(budgetNs) / static_cast<double>(out.callbacks) : 0;
    out.seconds = static_cast<double>(meter->framesSum.load(std::memory_order_relaxed) - framesStart) / r.rate;
    if (!us.empty()) {
        const SuiteStats st = stats(us, 0, us.size());
        out.meanUs = st.meanUs;
        out.p99Us = st.p99Us;
        out.worstUs = st.maxUs;
        out.worstAtS = out.warmupS + static_cast<double>(startFrame[st.maxAt]) / r.rate;  // from Play
        if (us.size() >= 20) {
            const size_t tenth = us.size() / 10;
            out.meanFirstUs = caw::stress::stats(us, 0, tenth).meanUs;
            out.meanLastUs = caw::stress::stats(us, us.size() - tenth, us.size()).meanUs;
        }
        // The trend: each callback's share of its own budget (%) against its time (minutes).
        std::vector<double> x(us.size()), y(us.size());
        for (size_t c = 0; c < us.size(); ++c) {
            const int32_t f = meter->frames[static_cast<size_t>(from) + c];
            x[c] = static_cast<double>(startFrame[c]) / r.rate / 60.0;
            y[c] = f > 0 ? 100.0 * us[c] / (1e6 * f / r.rate) : 0.0;
        }
        out.slopePctPerMin = slope(x.data(), y.data(), x.size());
    }
    if (stalled) return failed("the audio device stopped calling back (another app or a route change took it)");
    out.ok = !stopped && out.callbacks > 0;
    out.stopReason = stopped ? "cancelled" : out.callbacks > 0 ? "done" : "error";
    if (!stopped && out.callbacks == 0) out.error = "the audio device ran no callback";
    return out;
}

}  // namespace

std::shared_ptr<Job> makeJob(const CawStressRequest* q, std::string& error) {
    constexpr size_t minimumSize = offsetof(CawStressRequest, work_dir) + sizeof(const char*);
    if (!q || q->struct_size < minimumSize) {
        error = "struct_size";
        return nullptr;
    }
    if (q->kind < CAW_STRESS_PLAIN || q->kind > CAW_STRESS_PROFILE || (q->mode != CAW_STRESS_DSP && q->mode != CAW_STRESS_LIVE) ||
        (q->mode == CAW_STRESS_LIVE && q->kind != CAW_STRESS_PLAIN && q->kind != CAW_STRESS_SUSTAINED) ||
        !(q->seconds >= 0.05 && q->seconds <= 600) || q->threads != 0 || q->quality < 0 || q->quality > 2 ||
        (q->mode == CAW_STRESS_DSP && q->frames != 0 && (q->frames < 16 || q->frames > 8192)) ||
        (q->mode == CAW_STRESS_LIVE && (q->frames < 0 || q->frames > 8192))) {
        error = "bad request";
        return nullptr;
    }
    const bool ramp = q->kind >= CAW_STRESS_RAMP_TRACKS && q->kind <= CAW_STRESS_RAMP_EFFECTS;
    const std::string scenario = q->scenario ? std::string(q->scenario).substr(0, 64) : std::string();
    if (!ramp && !findScenario(benchmarkScenarios(), scenario)) {
        error = "scenario";
        return nullptr;
    }
    auto j = std::make_shared<Job>();
    j->request.scenario = scenario;
    j->scenarioId = ramp ? std::string() : scenario;
    j->request.kind = static_cast<Kind>(q->kind);
    j->request.seconds = q->seconds;
    j->request.frames = q->mode == CAW_STRESS_DSP ? (q->frames ? q->frames : 256) : q->frames;
    j->request.quality = q->quality;
    j->request.workDir = q->work_dir ? std::string(q->work_dir).substr(0, 4096) : std::string();
    j->mode = q->mode;
    return j;
}

std::string runJob(Job& j) {
    RunResult r;
    if (j.mode == CAW_STRESS_LIVE) {
        r = runLive(j);
    } else {
        r = run(j.request, j.progress, &j.history, &j.cancel);
    }
    std::lock_guard<std::mutex> lock(j.mutex);
    j.result = std::move(r);
    if (j.mode == CAW_STRESS_DSP) {
        j.deviceFrames = j.request.frames;
        j.deviceRate = j.request.rate;
    }
    j.finished = true;
    return resultJson(j);
}

}  // namespace caw::stress

using caw::stress::jobOf;

extern "C" {

char* caw_stress_scenarios(void) try {
    std::string o = "{\"version\":1,\"scenarios\":[";
    const std::vector<caw::stress::SuiteScenario> all = caw::stress::benchmarkScenarios();
    for (size_t k = 0; k < all.size(); ++k)
        o += std::string(k ? "," : "") + "{\"id\":\"" + all[k].id + "\",\"name\":\"" + caw::jsonEscape(all[k].name) +
             "\",\"tier\":\"" + caw::stress::tierName(all[k].tier) + "\",\"memory_mib\":" + std::to_string(all[k].memoryMiB) + "}";
    o += "],\"ramps\":[";
    const std::pair<const char*, caw::stress::Kind> ramps[] = {{"tracks", caw::stress::Kind::RampTracks},
                                                              {"voices", caw::stress::Kind::RampVoices},
                                                              {"effects", caw::stress::Kind::RampEffects}};
    for (size_t k = 0; k < 3; ++k) {
        o += std::string(k ? "," : "") + "{\"kind\":\"" + ramps[k].first + "\",\"counts\":[";
        const std::vector<int32_t> counts = caw::stress::rampCounts(ramps[k].second);
        for (size_t c = 0; c < counts.size(); ++c) o += (c ? "," : "") + std::to_string(counts[c]);
        o += "]}";
    }
    o += "],\"hold_p99\":" + std::to_string(caw::stress::kHoldP99) + "}";
    return caw::stress::duplicate(o);
} catch (...) {
    return nullptr;
}

int32_t caw_stress_progress(CawJob* job, CawStressProgress* out) try {
    const auto j = jobOf(job);
    if (!j || !out) return 1;
    if (out->struct_size < offsetof(CawStressProgress, over_budget) + sizeof(int64_t)) return 2;
    const caw::stress::Progress& p = j->progress;
    out->permille = p.permille.load(std::memory_order_relaxed);
    out->step = p.step.load(std::memory_order_relaxed);
    out->count = p.count.load(std::memory_order_relaxed);
    out->held = p.held.load(std::memory_order_relaxed);
    out->load = p.load.load(std::memory_order_relaxed);
    out->callbacks = p.callbacks.load(std::memory_order_relaxed);
    out->over_budget = p.overBudget.load(std::memory_order_relaxed);
    return 0;
} catch (...) {
    return 1;
}

int32_t caw_stress_history(CawJob* job, uint32_t from, float* out, int32_t max, uint32_t* next) try {
    const auto j = jobOf(job);
    if (!j) return -1;
    if (!out || max <= 0) {
        if (next) *next = std::min(from, j->history.written());
        return 0;
    }
    return j->history.read(from, out, max, next);
} catch (...) {
    return -1;
}

int32_t caw_stress_result(CawJob* job, CawStressResult* out) try {
    const auto j = jobOf(job);
    if (!j || !out) return 1;
    if (out->struct_size < offsetof(CawStressResult, error) + sizeof(out->error)) return 2;
    std::lock_guard<std::mutex> lock(j->mutex);
    if (!j->finished) return 3;
    const caw::stress::RunResult& r = j->result;
    const bool live = j->mode == CAW_STRESS_LIVE;
    out->ok = r.ok || r.stopReason == "over_budget" ? 1 : 0;
    out->mode = j->mode;
    out->frames = j->deviceFrames;
    out->sample_rate = j->deviceRate;
    out->limit = r.limit;
    out->first_failed = r.firstFailed;
    out->steps = r.steps;
    out->xruns = j->xruns;
    out->callback_core = j->callbackCore;
    out->budget_us = r.budgetUs;
    out->mean_us = r.meanUs;
    out->p99_us = r.p99Us;
    out->worst_us = r.worstUs;
    out->worst_at_s = r.worstAtS;
    out->mean_first_us = r.meanFirstUs;
    out->mean_last_us = r.meanLastUs;
    out->seconds = r.seconds;
    out->callbacks = r.callbacks;
    out->over_budget = r.overBudget;
    out->dropouts = live && j->xruns >= 0 ? j->xruns : r.overBudget;
    std::memset(out->stop_reason, 0, sizeof out->stop_reason);
    std::strncpy(out->stop_reason, r.stopReason.c_str(), sizeof out->stop_reason - 1);
    std::memset(out->error, 0, sizeof out->error);
    std::strncpy(out->error, r.error.c_str(), sizeof out->error - 1);
    return 0;
} catch (...) {
    return 1;
}

int32_t caw_stress_costs(CawJob* job, CawStressCost* out, int32_t max) try {
    const auto j = jobOf(job);
    if (!j) return -1;
    std::lock_guard<std::mutex> lock(j->mutex);
    if (!j->finished) return -1;
    const std::vector<caw::stress::CostRow>& rows = j->result.costs;
    for (int32_t k = 0; out && k < max && k < static_cast<int32_t>(rows.size()); ++k) {
        CawStressCost& c = out[k];
        std::memset(c.id, 0, sizeof c.id);
        std::strncpy(c.id, rows[static_cast<size_t>(k)].id.c_str(), sizeof c.id - 1);
        c.ns = rows[static_cast<size_t>(k)].ns;
        c.pct = static_cast<float>(rows[static_cast<size_t>(k)].pct);
        c.ran_pct = static_cast<float>(rows[static_cast<size_t>(k)].ranPct);
        c.instances = rows[static_cast<size_t>(k)].instances;
        c.modulator = rows[static_cast<size_t>(k)].modulator ? 1 : 0;
    }
    return static_cast<int32_t>(rows.size());
} catch (...) {
    return -1;
}

}  // extern "C"
