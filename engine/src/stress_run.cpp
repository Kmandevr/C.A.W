// The Benchmark's timed runs: each on its own Engine (shedding off, its own profile, the mix pool on Auto as the app's), timed like caw_bench's suite.
#include "stress_run.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <map>

#include "component_chain.h"
#include "engine.h"
#include "mix_pool.h"
#include "thread_tuning.h"

namespace caw::stress {

namespace {

using Clock = std::chrono::steady_clock;

bool cancelled(const std::atomic<int32_t>* cancel) noexcept {
    return cancel && cancel->load(std::memory_order_relaxed) != 0;
}

// A scenario's project; false (and `error`) when it can't be made.
bool scenarioProject(const std::string& id, const std::string& dir, ProjectSpec& out, std::string& error) {
    const std::vector<SuiteScenario> all = benchmarkScenarios();
    const SuiteScenario* s = findScenario(all, id);
    if (!s) {
        error = "no scenario '" + id + "'";
        return false;
    }
    if (id == "song8_extras") {  // writes two WAVs into the work folder
        if (dir.empty()) {
            error = "song8_extras needs a work folder";
            return false;
        }
        out = typicalSong(true, dir, &error);
        return error.empty();
    }
    out = s->make(dir);
    return true;
}

// A fresh engine set up as the Benchmark measures: the quality asked, nothing shed, the mix pool as the app's live
// device has it (MixPool::defaultWorkers(), Auto) unless `serial` (Profile), the project applied (0.25 s stopped,
// as caw_bench's suite does), then playing, and the warm-up played untimed (warmUp below).
bool prepare(Engine& e, const ProjectSpec& p, const RunRequest& r, bool serial, std::vector<float>& l,
             std::vector<float>& rr, std::string& error) {
    e.setQuality(r.quality);
    e.setShedding(false);
    if (serial) {
        e.setMixParallel(Engine::MixParallel::Never);
    } else {
        e.startMixPool(MixPool::defaultWorkers(), false);  // offline workers (none on a machine of 1 or 2 cores: serial)
        e.setMixParallel(Engine::MixParallel::Auto);
    }
    const std::string warn = e.setProject(p);
    if (warn.find("\"ok\":true") == std::string::npos) {
        error = "the project did not load: " + warn.substr(0, 300);
        return false;
    }
    for (int c = 0; c < r.rate / 4 / r.frames; ++c) e.process(l.data(), rr.data(), r.frames);
    e.play();
    return true;
}

// After Play, untimed: the warm-up's callbacks, each reported as a device callback's load (so Auto decides and
// settles before the timed span), the first one's time kept apart. Returns false when cancelled.
bool warmUp(Engine& e, const RunRequest& r, bool pool, std::vector<float>& l, std::vector<float>& rr, RunResult& out,
            const std::atomic<int32_t>* cancel) {
    const double budgetUs = 1e6 * r.frames / r.rate;
    const int64_t calls = std::max<int64_t>(1, static_cast<int64_t>(warmupSeconds(pool) * r.rate / r.frames));
    for (int64_t c = 0; c < calls; ++c) {
        if (cancelled(cancel)) return false;
        const auto t0 = Clock::now();
        e.process(l.data(), rr.data(), r.frames);
        const double took = std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
        if (c == 0) out.firstCallbackUs = took;
        e.reportLoad(took / budgetUs, r.frames, r.frames);
    }
    out.warmupS = static_cast<double>(calls) * r.frames / r.rate;
    return true;
}

// The calling thread's core and its clock, before or after the timed span.
void readCore(int32_t& core, int64_t& khz, int64_t& maxKHz) {
    core = tuning::currentCpu();
    const tuning::CoreClock c = tuning::coreClock(core);
    khz = c.currentKHz;
    if (c.maxKHz > maxKHz) maxKHz = c.maxKHz;
}

void fill(RunResult& out, const std::vector<double>& us, int64_t n, const RunRequest& r) {
    const SuiteStats s = stats(us, 0, static_cast<size_t>(n));
    out.meanUs = s.meanUs;
    out.p99Us = s.p99Us;
    out.worstUs = s.maxUs;
    out.worstAtS = out.warmupS + static_cast<double>(s.maxAt) * r.frames / r.rate;  // from Play
    out.callbacks = n;
    out.overBudget = 0;
    for (int64_t c = 0; c < n; ++c)
        if (us[static_cast<size_t>(c)] > out.budgetUs) ++out.overBudget;
    out.seconds = static_cast<double>(n) * r.frames / r.rate;
    if (n >= 20) {
        const size_t tenth = static_cast<size_t>(n) / 10;
        out.meanFirstUs = stats(us, 0, tenth).meanUs;
        out.meanLastUs = stats(us, static_cast<size_t>(n) - tenth, static_cast<size_t>(n)).meanUs;
    }
    // The trend: each callback's share of the budget (%) against its time (minutes).
    std::vector<double> x(static_cast<size_t>(n)), y(static_cast<size_t>(n));
    for (int64_t c = 0; c < n; ++c) {
        x[static_cast<size_t>(c)] = static_cast<double>(c) * r.frames / r.rate / 60.0;
        y[static_cast<size_t>(c)] = out.budgetUs > 0 ? 100.0 * us[static_cast<size_t>(c)] / out.budgetUs : 0.0;
    }
    out.slopePctPerMin = slope(x.data(), y.data(), x.size());
}

int64_t callsFor(double seconds, const RunRequest& r) {
    return std::max<int64_t>(1, static_cast<int64_t>(seconds * r.rate / r.frames));
}

void setSpan(Progress& p, int32_t from, int32_t to) {
    p.spanFrom = from;
    p.spanTo = to;
    p.permille.store(from, std::memory_order_relaxed);
}

}  // namespace

double warmupSeconds(bool pool) noexcept {
    return kWarmupSeconds + (pool ? Engine::kMixParallelSeconds + Engine::kMixSettleSeconds : 0.0);
}

double slope(const double* x, const double* y, size_t n) noexcept {
    if (n < 2) return 0;
    double mx = 0, my = 0;
    for (size_t i = 0; i < n; ++i) mx += x[i], my += y[i];
    mx /= static_cast<double>(n);
    my /= static_cast<double>(n);
    double sxy = 0, sxx = 0;
    for (size_t i = 0; i < n; ++i) {
        sxy += (x[i] - mx) * (y[i] - my);
        sxx += (x[i] - mx) * (x[i] - mx);
    }
    return sxx > 0 && std::isfinite(sxy / sxx) ? sxy / sxx : 0.0;
}

void LoadHistory::push(float load) noexcept {
    const uint32_t at = written_.load(std::memory_order_relaxed);
    points_[at % kCapacity].store(load, std::memory_order_relaxed);
    written_.store(at + 1, std::memory_order_release);
}

int32_t LoadHistory::read(uint32_t from, float* out, int32_t max, uint32_t* next) const noexcept {
    const uint32_t end = written();
    if (from > end) from = end;
    if (end - from > kCapacity) from = end - kCapacity;  // overwritten: the oldest still kept
    int32_t n = 0;
    while (from < end && n < max) out[n++] = points_[from++ % kCapacity].load(std::memory_order_relaxed);
    if (next) *next = from;
    return n;
}

int64_t timeCallbacks(Engine& e, int frames, int64_t calls, double* us, float* l, float* r, Progress* progress,
                      LoadHistory* history, const std::atomic<int32_t>* cancel) noexcept {
    const double budgetUs = 1e6 * frames / e.sampleRate();
    const int64_t pointFrames = std::max<int64_t>(1, static_cast<int64_t>(e.sampleRate() / 10));  // a history point per 100 ms of audio
    int64_t framesInPoint = 0;
    double usInPoint = 0;
    int64_t c = 0;
    for (; c < calls; ++c) {
        if (cancelled(cancel)) break;
        const auto t0 = Clock::now();
        e.process(l, r, frames);
        const double took = std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
        us[c] = took;
        e.reportLoad(took / budgetUs, frames, frames);  // as a device callback (caw_bench --mode auto)
        framesInPoint += frames;
        usInPoint += took;
        if (progress) {
            progress->callbacks.fetch_add(1, std::memory_order_relaxed);
            if (took > budgetUs) progress->overBudget.fetch_add(1, std::memory_order_relaxed);
        }
        if (framesInPoint >= pointFrames) {
            const float load = static_cast<float>(usInPoint / (1e6 * static_cast<double>(framesInPoint) / e.sampleRate()));
            if (history) history->push(load);
            if (progress) {
                progress->load.store(load, std::memory_order_relaxed);
                const int64_t span = progress->spanTo - progress->spanFrom;
                progress->permille.store(static_cast<int32_t>(progress->spanFrom + span * (c + 1) / calls), std::memory_order_relaxed);
            }
            framesInPoint = 0;
            usInPoint = 0;
        }
    }
    return c;
}

RampOutcome rampSearch(const std::vector<int32_t>& counts, const std::function<int(int32_t)>& step) {
    RampOutcome o;
    for (const int32_t n : counts) {
        ++o.steps;
        const int held = step(n);
        if (held < 0) {
            o.stopped = true;
            return o;
        }
        if (!held) {
            o.firstFailed = n;
            break;
        }
        o.limit = n;
    }
    // Between the last count that held and the first that didn't, halve the gap (never above the failed one).
    while (o.firstFailed > 0 && o.firstFailed - o.limit > 1) {
        const int32_t n = o.limit + (o.firstFailed - o.limit) / 2;
        ++o.steps;
        const int held = step(n);
        if (held < 0) {
            o.stopped = true;
            return o;
        }
        if (held) o.limit = n;
        else o.firstFailed = n;
    }
    return o;
}

std::vector<int32_t> rampCounts(Kind kind) {
    switch (kind) {
        case Kind::RampTracks: return {1, 2, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96, 128};
        case Kind::RampVoices: return {1, 2, 4, 8, 12, 16, 24, 32, 48, 64};
        case Kind::RampEffects: return {1, 2, 4, 8, 12, 16, 24, 32, 48, 64};
        default: return {};
    }
}

ProjectSpec rampProject(Kind kind, int32_t n) {
    if (kind == Kind::RampTracks) return bigSong(n, false);  // the typical song's tracks, buses, master and LFOs
    if (kind == Kind::RampVoices) return flagshipVoices(n);
    return effectsChain(n);
}

std::vector<CostRow> profileCosts(const ChainProfile& profile, uint64_t totalNs, int64_t callbacks) {
    struct Sum { uint64_t ns = 0, ran = 0, calls = 0; int n = 0; bool modulator = false; };
    std::map<std::string, Sum> byId;
    uint64_t inComponents = 0;
    for (uint32_t s = 0; s < profile.used; ++s) {
        const ChainProfile::Slot& x = profile.slots[s];
        Sum& g = byId[x.id ? *x.id : std::string("?")];
        g.ns += x.ns;
        g.ran += x.ran;
        g.calls += x.calls;
        g.n += 1;
        g.modulator = g.modulator || x.modulator;
        inComponents += x.ns;
    }
    const double per = callbacks > 0 ? 1.0 / static_cast<double>(callbacks) : 0.0;
    const double total = totalNs > 0 ? static_cast<double>(totalNs) : 1.0;
    std::vector<CostRow> rows;
    const uint64_t host = totalNs - std::min(totalNs, inComponents);
    rows.push_back({"host", static_cast<uint64_t>(host * per), 100.0 * host / total, 100.0, 1, false});
    for (const auto& [id, g] : byId)
        rows.push_back({id, static_cast<uint64_t>(g.ns * per), 100.0 * g.ns / total, g.calls ? 100.0 * g.ran / g.calls : 0.0, g.n,
                        g.modulator});
    std::sort(rows.begin(), rows.end(), [](const CostRow& a, const CostRow& b) { return a.ns > b.ns; });
    return rows;
}

RunResult run(const RunRequest& r, Progress& progress, LoadHistory* history, const std::atomic<int32_t>* cancel) {
    RunResult out;
    out.budgetUs = 1e6 * r.frames / r.rate;
    if (r.frames < 16 || r.frames > 8192 || !(r.seconds >= 0.05 && r.seconds <= 600) || r.rate < 8000 || r.rate > 192000 ||
        r.quality < 0 || r.quality > 2) {
        out.stopReason = "error";
        out.error = "bad request: frames 16..8192, seconds 0.05..600, quality 0..2";
        return out;
    }
    std::vector<float> l(static_cast<size_t>(r.frames)), rr(static_cast<size_t>(r.frames));
    auto failed = [&](const std::string& why) {
        out.ok = false;
        out.stopReason = "error";
        out.error = why;
        return out;
    };

    if (r.kind == Kind::RampTracks || r.kind == Kind::RampVoices || r.kind == Kind::RampEffects) {
        const std::vector<int32_t> counts = rampCounts(r.kind);
        const int64_t calls = callsFor(r.seconds, r);
        std::vector<double> us(static_cast<size_t>(calls)), heldUs;
        int64_t heldN = 0;
        RunResult heldStep;  // the last step that held: its warm-up, first callback, core and pool
        const int32_t expected = static_cast<int32_t>(counts.size()) + 4;
        std::string error;
        const RampOutcome o = rampSearch(counts, [&](int32_t n) -> int {
            if (cancelled(cancel)) return -1;
            const int32_t s = progress.step.load(std::memory_order_relaxed);
            setSpan(progress, std::min(990, 1000 * s / expected), std::min(990, 1000 * (s + 1) / expected));
            progress.count.store(n, std::memory_order_relaxed);
            Engine e(r.rate);
            if (!prepare(e, rampProject(r.kind, n), r, false, l, rr, error)) return -1;
            RunResult step;
            if (!warmUp(e, r, true, l, rr, step, cancel)) return -1;
            readCore(step.coreStart, step.khzStart, step.maxKHz);
            const int64_t done = timeCallbacks(e, r.frames, calls, us.data(), l.data(), rr.data(), &progress, history, cancel);
            readCore(step.coreEnd, step.khzEnd, step.maxKHz);
            step.mixWorkers = e.mixWorkers();
            step.mixActive = e.mixActiveWorkers();
            progress.step.fetch_add(1, std::memory_order_relaxed);
            if (done < calls) return -1;  // cancelled mid-step
            const SuiteStats st = stats(us, 0, static_cast<size_t>(done));
            const bool held = st.p99Us <= out.budgetUs * kHoldP99;
            if (held) {
                heldUs = us;
                heldN = done;
                heldStep = step;
                progress.held.store(std::max(progress.held.load(std::memory_order_relaxed), n), std::memory_order_relaxed);
            }
            return held ? 1 : 0;
        });
        if (!error.empty()) return failed(error);
        out.limit = o.limit;
        out.firstFailed = o.firstFailed;
        out.steps = o.steps;
        if (heldN > 0) {
            out.firstCallbackUs = heldStep.firstCallbackUs;
            out.warmupS = heldStep.warmupS;
            out.coreStart = heldStep.coreStart, out.coreEnd = heldStep.coreEnd;
            out.khzStart = heldStep.khzStart, out.khzEnd = heldStep.khzEnd, out.maxKHz = heldStep.maxKHz;
            out.mixWorkers = heldStep.mixWorkers, out.mixActive = heldStep.mixActive;
            fill(out, heldUs, heldN, r);
        }
        out.ok = !o.stopped;
        out.stopReason = o.stopped ? "cancelled" : o.firstFailed > 0 ? "over_budget" : "done";
        progress.permille.store(1000, std::memory_order_relaxed);
        return out;
    }

    ProjectSpec p;
    std::string error;
    if (!scenarioProject(r.scenario, r.workDir, p, error)) return failed(error);
    Engine e(r.rate);
    const bool serial = r.kind == Kind::Profile;
    if (!prepare(e, p, r, serial, l, rr, error)) return failed(error);
    const int64_t calls = callsFor(r.seconds, r);
    std::vector<double> us(static_cast<size_t>(calls));
    std::unique_ptr<ChainProfile> profile;
    setSpan(progress, 0, 1000);
    if (!warmUp(e, r, !serial, l, rr, out, cancel)) {
        out.stopReason = "cancelled";
        return out;
    }
    if (r.kind == Kind::Profile) {
        // 1 s in all before the profile starts, as before the warm-up was every run's.
        const int extra = static_cast<int>((1.0 - out.warmupS) * r.rate / r.frames);
        for (int c = 0; c < extra && !cancelled(cancel); ++c) e.process(l.data(), rr.data(), r.frames);
        out.warmupS += std::max(0, extra) * static_cast<double>(r.frames) / r.rate;
        profile = std::make_unique<ChainProfile>();
        e.setProfile(profile.get());
    }
    readCore(out.coreStart, out.khzStart, out.maxKHz);
    const int64_t n = timeCallbacks(e, r.frames, calls, us.data(), l.data(), rr.data(), &progress, history, cancel);
    readCore(out.coreEnd, out.khzEnd, out.maxKHz);
    out.mixWorkers = e.mixWorkers();
    out.mixActive = e.mixActiveWorkers();
    e.setProfile(nullptr);
    if (n > 0) fill(out, us, n, r);
    if (profile && n > 0) {
        uint64_t totalNs = 0;
        for (int64_t c = 0; c < n; ++c) totalNs += static_cast<uint64_t>(us[static_cast<size_t>(c)] * 1000.0);
        out.costs = profileCosts(*profile, totalNs, n);
    }
    out.ok = n == calls;
    out.stopReason = n == calls ? "done" : "cancelled";
    progress.permille.store(1000, std::memory_order_relaxed);
    return out;
}

}  // namespace caw::stress
