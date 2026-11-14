// The plug-in benchmark (#197): a component's cost, its automatic checks (allocations, denormals, voices, scaling, parameters, silence), sections and curves.
#include "component_bench.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdio>
#include <exception>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "builtin_components.h"
#include "caw/instrument.hpp"
#include "component_chain.h"
#include "component_profile.h"
#include "fp_mode.h"
#include "json.h"
#include "params.h"

namespace caw::bench {

namespace {

// Plain ints shared with another thread. std::atomic_ref is missing from the Android NDK's libc++, so those builds
// use the compiler's atomic built-ins instead (as render.cpp does).
[[maybe_unused]] inline int32_t relaxedLoad(const int32_t* p) noexcept {
#if defined(__cpp_lib_atomic_ref)
    return std::atomic_ref<int32_t>(*const_cast<int32_t*>(p)).load(std::memory_order_relaxed);
#else
    return __atomic_load_n(p, __ATOMIC_RELAXED);
#endif
}
[[maybe_unused]] inline void relaxedStore(int32_t* p, int32_t v) noexcept {
#if defined(__cpp_lib_atomic_ref)
    std::atomic_ref<int32_t>(*p).store(v, std::memory_order_relaxed);
#else
    __atomic_store_n(p, v, __ATOMIC_RELAXED);
#endif
}


std::atomic<AllocationCounter> gCounter{nullptr};
// One bench at a time (the section table is the process's one): set by the job that starts one, cleared by the
// bench's own thread when it ends (an atomic, since the two are different threads).
std::atomic<bool> gBusy{false};
std::atomic<bool> gAbandoned{false};  // a bench thread was left behind in a process() that never returned

// What the bench's thread shows the job's thread, which watches it (run()): its progress, a cancel, and when the
// block it is in began (0: not in process()) with that block's deadline.
struct Watch {
    alignas(4) int32_t progress = 0;
    alignas(4) int32_t cancel = 0;
    std::atomic<int64_t> blockStartNs{0};
    std::atomic<int64_t> blockDeadlineNs{0};
    std::mutex mutex;
    std::condition_variable done;
    bool finished = false;  // under mutex
    std::string result;     // under mutex
};

using Clock = std::chrono::steady_clock;

int64_t steadyNs() noexcept {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(Clock::now().time_since_epoch()).count();
}

constexpr double kRate = 48000;
constexpr uint32_t kBlock = 64;  // the Engine's block: what a component gets in C.A.W
constexpr uint32_t kMaxBlock = 512;
constexpr uint32_t kEventCapacity = 512;
constexpr int kVoiceCounts[] = {1, 2, 4, 8, 16};
constexpr uint32_t kBlockSizes[] = {32, 64, 128, 256, 512};
constexpr double kRates[] = {44100, 48000, 96000};

double budgetUs(uint32_t frames, double rate) { return 1e6 * frames / rate; }

// How long one block may take before the component counts as stuck: 100 times its budget, at least a second.
int64_t deadlineNs(uint32_t frames, double rate) noexcept {
    return std::max<int64_t>(1000000000, static_cast<int64_t>(100.0 * 1000.0 * budgetUs(frames, rate)));
}

std::string num(double v) {
    if (!std::isfinite(v)) return "0";
    char b[32];
    std::snprintf(b, sizeof b, "%.9g", v);
    return b;
}
std::string str(const std::string& v) { return "\"" + jsonEscape(v) + "\""; }

bool isSubnormal(float x) noexcept { return x != 0.0f && std::fabs(x) < 1.17549435e-38f; }

// One instance with every buffer its ports need, set aside before any block (process never allocates here).
class Rig {
public:
    ~Rig() {
        if (active_) p_->deactivate();
    }

    bool open(const ModuleRegistry& registry, const std::string& id, double rate, uint32_t maxFrames, std::string& error) {
        p_ = registry.create(id);
        if (!p_) {
            error = "component '" + id + "' could not create an instance";
            return false;
        }
        const ModuleDescriptor& d = p_->descriptor();
        rate_ = rate;
        for (uint32_t k = 0; k < d.portCount; ++k) {
            const PortDescriptor& port = d.ports[k];
            const uint32_t ch = portChannelCount(port);
            switch (port.type) {
                case PortType::Audio:
                    (port.input ? audioInChannels_ : audioOutChannels_).push_back(ch);
                    break;
                case PortType::Event: ++(port.input ? eventIns_ : eventOuts_); break;
                case PortType::Modulation: ++(port.input ? modIns_ : modOuts_); break;
                case PortType::Control:
                    if (port.input) controlIn_.push_back(port.defaultValue);
                    else controlOut_.push_back(port.defaultValue);
                    break;
            }
        }
        instrument_ = audioInChannels_.empty() && eventIns_ > 0 && !audioOutChannels_.empty();
        if (audioOutChannels_.empty() || (audioInChannels_.empty() && !instrument_)) {
            error = "component '" + id + "' is neither an effect (audio in and out) nor an instrument (notes in, audio out)";
            return false;
        }
        const bool plain = audioInChannels_.size() <= 1 && audioOutChannels_.size() == 1 && !eventIns_ && !eventOuts_ &&
                           !modIns_ && !modOuts_ && controlIn_.empty() && controlOut_.empty();
        if (!p_->activate(rate, maxFrames)) {
            error = "component '" + id + "' refused to activate at " + std::to_string(static_cast<int>(rate)) + " Hz, blocks of " +
                    std::to_string(maxFrames);
            return false;
        }
        active_ = true;
        ports_ = p_->usesProcessPorts();
        if (!ports_ && !plain) {
            error = "component '" + id + "' has ports beyond one audio input and output but no processPorts()";
            return false;
        }
        // Buffers: every audio channel, modulation lane and event list, block-sized.
        auto channels = [&](const std::vector<uint32_t>& counts, std::vector<std::vector<float>>& store,
                            std::vector<std::vector<float*>>& ptrs) {
            for (uint32_t c : counts) {
                ptrs.emplace_back();
                for (uint32_t k = 0; k < c; ++k) {
                    store.emplace_back(maxFrames, 0.0f);
                    ptrs.back().push_back(store.back().data());
                }
            }
        };
        store_.reserve(64);
        channels(audioInChannels_, store_, inPtr_);
        channels(audioOutChannels_, store_, outPtr_);
        for (uint32_t k = 0; k < modIns_; ++k) store_.emplace_back(maxFrames, 0.0f), modInPtr_.push_back(store_.back().data());
        for (uint32_t k = 0; k < modOuts_; ++k) store_.emplace_back(maxFrames, 0.0f), modOutPtr_.push_back(store_.back().data());
        for (float& v : controlIn_) controlInPtr_.push_back(&v);
        for (float& v : controlOut_) controlOutPtr_.push_back(&v);
        for (size_t k = 0; k < inPtr_.size(); ++k) inViews_.push_back({nullptr, static_cast<uint32_t>(inPtr_[k].size()), 0});
        for (size_t k = 0; k < outPtr_.size(); ++k) outViews_.push_back({nullptr, static_cast<uint32_t>(outPtr_[k].size()), 0});
        constInPtr_.resize(inPtr_.size());
        for (size_t k = 0; k < inPtr_.size(); ++k) constInPtr_[k].assign(inPtr_[k].begin(), inPtr_[k].end());
        eventIn_.assign(eventIns_, EventInput{});
        eventOutStore_.assign(static_cast<size_t>(eventOuts_) * kEventCapacity, Event{});
        eventOut_.assign(eventOuts_, EventOutput{});
        events_.reserve(kEventCapacity);
        // Parameters at their defaults, each with a per-frame ramp buffer for the automation run.
        values_.resize(d.parameterCount);
        ramps_.assign(d.parameterCount, std::vector<double>(maxFrames, 0.0));
        for (uint32_t k = 0; k < d.parameterCount; ++k) values_[k].value = constrainParameter(d.parameters[k], d.parameters[k].defaultValue);
        transport_.tempo = 120;
        transport_.playing = true;
        return true;
    }

    const ModuleDescriptor& descriptor() const noexcept { return p_->descriptor(); }
    bool instrument() const noexcept { return instrument_; }
    double rate() const noexcept { return rate_; }
    // The main audio input's channels (an effect's signal goes here), the main output's.
    float* in(uint32_t ch) noexcept { return inPtr_.empty() || ch >= inPtr_[0].size() ? nullptr : inPtr_[0][ch]; }
    uint32_t inChannels() const noexcept { return inPtr_.empty() ? 0 : static_cast<uint32_t>(inPtr_[0].size()); }
    const float* out(uint32_t ch) const noexcept { return ch < outPtr_[0].size() ? outPtr_[0][ch] : outPtr_[0][0]; }
    uint32_t outChannels() const noexcept { return static_cast<uint32_t>(outPtr_[0].size()); }
    std::vector<Event>& events() noexcept { return events_; }  // the next block's notes (first event input)
    std::vector<ParameterValue>& values() noexcept { return values_; }
    std::vector<std::vector<double>>& ramps() noexcept { return ramps_; }
    bool quiet() const noexcept { return p_->quiet(); }

    // One block of m frames. False: the component reported a failure. Not noexcept: a C++ exception that leaves
    // the component reaches the bench's catch (the job fails) rather than ending the app.
    bool process(uint32_t m) {
        for (size_t k = 0; k < outPtr_.size(); ++k)
            for (float* o : outPtr_[k]) std::fill_n(o, m, 0.0f);
        const ParameterValue* params = values_.empty() ? nullptr : values_.data();
        const uint32_t paramCount = static_cast<uint32_t>(values_.size());
        if (!ports_) {
            const AudioProcessBlock block{{inPtr_.empty() ? nullptr : constInPtr_[0].data(), inChannels(), m},
                                          {outPtr_[0].data(), outChannels(), m}, m, rate_, params, paramCount, &transport_};
            return p_->process(block);
        }
        for (size_t k = 0; k < inViews_.size(); ++k) inViews_[k] = {constInPtr_[k].data(), static_cast<uint32_t>(inPtr_[k].size()), m};
        for (size_t k = 0; k < outViews_.size(); ++k) outViews_[k] = {outPtr_[k].data(), static_cast<uint32_t>(outPtr_[k].size()), m};
        for (uint32_t k = 0; k < eventIns_; ++k)
            eventIn_[k] = k == 0 ? EventInput{events_.data(), static_cast<uint32_t>(events_.size())} : EventInput{};
        for (uint32_t k = 0; k < eventOuts_; ++k) eventOut_[k] = {eventOutStore_.data() + static_cast<size_t>(k) * kEventCapacity, kEventCapacity, 0};
        ProcessBlock b;
        b.frames = m;
        b.sampleRate = rate_;
        b.audioIn = inViews_.data();
        b.audioInCount = static_cast<uint32_t>(inViews_.size());
        b.audioOut = outViews_.data();
        b.audioOutCount = static_cast<uint32_t>(outViews_.size());
        b.modulationIn = modInPtr_.data();
        b.modulationInCount = static_cast<uint32_t>(modInPtr_.size());
        b.modulationOut = modOutPtr_.data();
        b.modulationOutCount = static_cast<uint32_t>(modOutPtr_.size());
        b.controlIn = controlInPtr_.data();
        b.controlInCount = static_cast<uint32_t>(controlInPtr_.size());
        b.controlOut = controlOutPtr_.data();
        b.controlOutCount = static_cast<uint32_t>(controlOutPtr_.size());
        b.eventIn = eventIn_.data();
        b.eventInCount = eventIns_;
        b.eventOut = eventOut_.data();
        b.eventOutCount = eventOuts_;
        b.parameters = params;
        b.parameterCount = paramCount;
        b.transport = &transport_;
        return p_->processPorts(b);
    }

private:
    std::unique_ptr<ModuleProcessor> p_;
    bool active_ = false, ports_ = false, instrument_ = false;
    double rate_ = kRate;
    std::vector<uint32_t> audioInChannels_, audioOutChannels_;
    uint32_t eventIns_ = 0, eventOuts_ = 0, modIns_ = 0, modOuts_ = 0;
    std::vector<float> controlIn_, controlOut_;
    std::vector<std::vector<float>> store_;
    std::vector<std::vector<float*>> inPtr_, outPtr_;
    std::vector<std::vector<const float*>> constInPtr_;
    std::vector<ConstChannelBufferView> inViews_;
    std::vector<ChannelBufferView> outViews_;
    std::vector<const float*> modInPtr_;
    std::vector<float*> modOutPtr_;
    std::vector<const float*> controlInPtr_;
    std::vector<float*> controlOutPtr_;
    std::vector<EventInput> eventIn_;
    std::vector<Event> eventOutStore_;
    std::vector<EventOutput> eventOut_;
    std::vector<Event> events_;
    std::vector<ParameterValue> values_;
    std::vector<std::vector<double>> ramps_;
    Transport transport_;
};

enum class Feed { Signal, Silence };

struct Plan {
    uint32_t block = kBlock;
    double untimedSeconds = 0.05;  // played first, not timed (a voice's start, a buffer's first fill)
    Feed untimedFeed = Feed::Signal;
    double seconds = 1.0;          // then timed
    Feed feed = Feed::Signal;
    int heldVoices = 0;            // instrument: this many notes held from the start (0: a chord every half second)
    bool automate = false;         // every continuous parameter moving every block
    bool keepDenormals = false;    // flush-to-zero off, as a host that doesn't flush
    bool sleep = false;            // skip process while it says quiet and nothing comes in, as the Engine does
};

struct Series {
    std::vector<double> us;  // per timed block (0 where it slept)
    double mean = 0, p99 = 0;
    double totalUs = 0;  // every block's, the untimed start's too (what a section's share is of)
    uint64_t allocations = 0;
    bool counted = false;
    uint64_t subnormals = 0;
    uint64_t failed = 0;
    uint64_t slept = 0;
};

// The signal an effect hears: noise and a low sine, about -10 dBFS.
float signalAt(uint64_t frame, uint32_t ch, double rate) noexcept {
    uint32_t x = static_cast<uint32_t>(frame * 2654435761u + ch * 40503u + 7u);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    const double noise = static_cast<double>(x >> 8) / 8388608.0 - 1.0;
    return static_cast<float>(0.2 * noise + 0.2 * std::sin(6.283185307179586 * 220.0 * static_cast<double>(frame) / rate));
}

// An instrument's notes for the block [at, at + m): `held` notes on at frame 0 and never off, or (held 0) a
// four-note chord every half second, each note off after 0.4 s.
void notesFor(std::vector<Event>& out, uint64_t at, uint32_t m, int held, double rate) {
    out.clear();
    if (held > 0) {
        if (at == 0)
            for (int k = 0; k < held; ++k) out.push_back(notes::noteOn(0, static_cast<uint32_t>(k + 1), 48 + (k * 7) % 36, 0.8));
        return;
    }
    const uint64_t period = static_cast<uint64_t>(0.5 * rate), length = static_cast<uint64_t>(0.4 * rate);
    static constexpr int kChord[] = {57, 60, 64, 67};
    for (uint32_t i = 0; i < m; ++i) {
        const uint64_t f = at + i, phase = f % period, n = f / period;
        if (phase == 0)
            for (int k = 0; k < 4; ++k) out.push_back(notes::noteOn(i, static_cast<uint32_t>(n * 4 + k + 1), kChord[k] + static_cast<int>(n % 3) * 2, 0.8));
        if (phase == length)
            for (int k = 0; k < 4; ++k)
                out.push_back(notes::noteOff(i, static_cast<uint32_t>(n * 4 + k + 1), static_cast<uint8_t>(kChord[k] + static_cast<int>(n % 3) * 2)));
    }
}

// Every continuous parameter moves this block: a ramp from where it is to its default's normalized position plus
// or minus 5% (alternating), so the cost measured is the change, not another setting's.
void automateBlock(Rig& rig, uint32_t m, uint64_t blockIndex) noexcept {
    const ModuleDescriptor& d = rig.descriptor();
    std::vector<ParameterValue>& values = rig.values();
    std::vector<std::vector<double>>& ramps = rig.ramps();
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        const ParameterDescriptor& p = d.parameters[k];
        if (p.step > 0 || p.choices || !p.automatable) continue;
        const double from = values[k].samples ? values[k].samples[m > 0 ? m - 1 : 0] : values[k].value;
        const double center = normalizeParameter(p, constrainParameter(p, p.defaultValue));
        const double n = std::clamp(center + ((blockIndex + k) % 2 ? 0.05 : -0.05), 0.0, 1.0);
        const double to = constrainParameter(p, denormalizeParameter(p, n));
        double* r = ramps[k].data();
        for (uint32_t i = 0; i < m; ++i) r[i] = from + (to - from) * static_cast<double>(i + 1) / m;
        values[k] = ParameterValue{r, r[0]};
    }
}

bool cancelled(const int32_t* cancel) noexcept {
    return cancel && relaxedLoad(cancel) != 0;
}

// Plays `plan` through the rig and times each timed block. Nothing in the loop allocates (the rig's buffers and
// `us` are set aside first), so an allocation counted is the component's.
Series measure(Rig& rig, const Plan& plan, const int32_t* cancel, Watch* watch) {
    Series s;
    const double rate = rig.rate();
    const uint64_t untimed = static_cast<uint64_t>(plan.untimedSeconds * rate / plan.block);
    const uint64_t timed = std::max<uint64_t>(4, static_cast<uint64_t>(plan.seconds * rate / plan.block));
    s.us.reserve(static_cast<size_t>(timed));
    const AllocationCounter counter = gCounter.load(std::memory_order_acquire);
    s.counted = counter != nullptr;
    std::unique_ptr<ScopedKeepDenormals> keep;
    std::unique_ptr<ScopedFlushDenormals> flush;
    if (plan.keepDenormals) keep = std::make_unique<ScopedKeepDenormals>();
    else flush = std::make_unique<ScopedFlushDenormals>();  // as Engine::process runs every component
    bool asleep = false;
    uint64_t frame = 0;
    for (uint64_t b = 0; b < untimed + timed; ++b) {
        if ((b & 63) == 0 && cancelled(cancel)) break;
        const bool isTimed = b >= untimed;
        const Feed feed = isTimed ? plan.feed : plan.untimedFeed;
        const uint32_t m = plan.block;
        bool input = false;
        if (!rig.instrument()) {
            for (uint32_t ch = 0; ch < rig.inChannels(); ++ch) {
                float* x = rig.in(ch);
                for (uint32_t i = 0; i < m; ++i) x[i] = feed == Feed::Signal ? signalAt(frame + i, ch, rate) : 0.0f;
            }
            input = feed == Feed::Signal;
        } else {
            if (feed == Feed::Signal) notesFor(rig.events(), frame, m, plan.heldVoices, rate);
            else rig.events().clear();
            input = !rig.events().empty();
        }
        if (plan.automate) automateBlock(rig, m, b);
        double took = 0;
        if (plan.sleep && asleep && !input) {
            ++s.slept;  // the host skips it: no time passes for it
        } else {
            const uint64_t a0 = counter ? counter() : 0;
            const auto t0 = Clock::now();
            // The job's thread watches this: a block past its deadline means the component never returned.
            watch->blockDeadlineNs.store(deadlineNs(m, rate), std::memory_order_relaxed);
            watch->blockStartNs.store(std::chrono::duration_cast<std::chrono::nanoseconds>(t0.time_since_epoch()).count(),
                                      std::memory_order_release);
            const bool ok = rig.process(m);
            watch->blockStartNs.store(0, std::memory_order_release);
            took = std::chrono::duration<double, std::micro>(Clock::now() - t0).count();
            s.totalUs += took;
            if (counter) s.allocations += counter() - a0;
            if (!ok) ++s.failed;
            asleep = ok && rig.quiet();
        }
        if (isTimed) {
            s.us.push_back(took);
            if (plan.keepDenormals)
                for (uint32_t ch = 0; ch < rig.outChannels(); ++ch)
                    for (uint32_t i = 0; i < m; ++i) s.subnormals += isSubnormal(rig.out(ch)[i]) ? 1 : 0;
        }
        frame += m;
    }
    if (!s.us.empty()) {
        // The first twentieth is left out of the figures (caches, a lazily built table).
        const size_t from = s.us.size() / 20;
        std::vector<double> v(s.us.begin() + static_cast<std::ptrdiff_t>(from), s.us.end());
        double sum = 0;
        for (double x : v) sum += x;
        s.mean = sum / static_cast<double>(v.size());
        std::sort(v.begin(), v.end());
        s.p99 = v[std::min(v.size() - 1, v.size() * 99 / 100)];
    }
    return s;
}

struct Check {
    std::string id, status, detail;
    double value = 0;
    bool measured = true;
};

const char* grade(double v, double warn, double fail) { return v > fail ? "fail" : v > warn ? "warn" : "pass"; }

std::string fixed(double v, int digits = 1) {
    char b[32];
    std::snprintf(b, sizeof b, "%.*f", digits, v);
    return b;
}

// Least-squares slope of y over x.
double slopeOf(const std::vector<std::pair<double, double>>& pts) {
    const size_t n = pts.size();
    if (n < 2) return 0;
    double mx = 0, my = 0;
    for (const auto& [x, y] : pts) mx += x, my += y;
    mx /= static_cast<double>(n);
    my /= static_cast<double>(n);
    double sxy = 0, sxx = 0;
    for (const auto& [x, y] : pts) sxy += (x - mx) * (y - my), sxx += (x - mx) * (x - mx);
    return sxx > 0 ? sxy / sxx : 0;
}

std::string failure(const std::string& error) {
    return "{\"ok\":false,\"tool\":\"caw_component_bench\",\"format\":1,\"error\":" + str(error) + "}";
}

std::string runLocked(const Request& r, int32_t* progress, const int32_t* cancel, Watch* watch) {
    auto step = [&](int permille) {
        if (progress) relaxedStore(progress, permille);
    };
    if (r.id.empty() || r.id.size() > 256) return failure("a component id is required");
    if (!(r.seconds >= 0.1 && r.seconds <= 10)) return failure("seconds must be 0.1..10");
    ModuleRegistry registry;
    registerBuiltinComponents(registry);
    if (!r.library.empty()) {
        // Only the user's own choice of Trusted opens a library here; the loader also refuses Blocked and Isolated.
        if (r.trust != NativeModuleTrust::Trusted)
            return failure("the plug-in benchmark runs only components you built or chose to trust (trust: Trusted)");
        const ModuleLoadResult loaded = registry.loadSharedLibrary(r.library, r.id, r.trust);
        if (!loaded.success) return failure("can't load '" + r.id + "': " + loaded.message);
    } else if (!registry.find(r.id)) {
        return failure("component '" + r.id + "' is not built in; give its library and trust");
    }
    std::string error;
    auto rig = [&](double rate, uint32_t maxFrames) -> std::unique_ptr<Rig> {
        auto x = std::make_unique<Rig>();
        if (!x->open(registry, r.id, rate, maxFrames, error)) return nullptr;
        return x;
    };
    const double S = r.seconds;
    // The base run: the component at work at 48 kHz in 64-frame blocks, its sections recorded.
    auto base = rig(kRate, kBlock);
    if (!base) return failure(error);
    const bool instrument = base->instrument();
    const ModuleDescriptor& d = base->descriptor();
    const std::string name = d.name.empty() ? std::string(d.id) : std::string(d.name);
    step(20);
    Plan plan;
    plan.seconds = S;
    std::vector<profile::Section> sections;
    Series baseRun;
    {
        const profile::Recording recording;  // stops on any way out, so the table never stays active
        baseRun = measure(*base, plan, cancel, watch);
    }
    sections = profile::sections();
    base.reset();
    if (cancelled(cancel)) return failure("cancelled");
    step(150);
    const double budget = budgetUs(kBlock, kRate);
    const double floorUs = Thresholds::kFloorPct / 100.0 * budget;
    uint64_t allocations = baseRun.allocations, failed = baseRun.failed;
    // A replaced global operator new reaches a loaded library's own allocations only where symbols interpose across
    // libraries (ELF: Linux, Android). On Windows a DLL calls its own CRT's new and malloc, and macOS's two-level
    // namespace binds the library's, so the count would miss them and wrongly pass: not counted there.
#if defined(_WIN32) || defined(__APPLE__)
    const bool counted = baseRun.counted && r.library.empty();
#else
    const bool counted = baseRun.counted;
#endif
    auto add = [&](const Series& s) {
        allocations += s.allocations;
        failed += s.failed;
    };
    // A curve's point: the plan measured kCurveRuns times on fresh instances, keeping the cheapest run, so another
    // process taking the core for a while can't flip a grade (each run's allocations and failures still count).
    constexpr int kCurveRuns = 3;
    auto leastOf = [&](double rate, uint32_t maxFrames, const Plan& plan, Series& out) -> bool {
        for (int k = 0; k < kCurveRuns; ++k) {
            auto v = rig(rate, maxFrames);
            if (!v) return false;
            Series sk = measure(*v, plan, cancel, watch);
            add(sk);
            if (k == 0 || sk.mean < out.mean) out = std::move(sk);
        }
        return true;
    };

    // Silence: a fresh instance hearing nothing (no notes), sleeping when it says quiet as the Engine lets it.
    auto quiet = rig(kRate, kBlock);
    if (!quiet) return failure(error);
    Plan silencePlan;
    silencePlan.seconds = S;
    silencePlan.untimedFeed = Feed::Silence;
    silencePlan.feed = Feed::Silence;
    silencePlan.sleep = true;
    const Series silent = measure(*quiet, silencePlan, cancel, watch);
    add(silent);
    quiet.reset();
    step(250);

    // Parameter changes: every continuous parameter ramping every block.
    auto moving = rig(kRate, kBlock);
    if (!moving) return failure(error);
    Plan paramPlan = plan;
    paramPlan.automate = true;
    const Series automated = measure(*moving, paramPlan, cancel, watch);
    add(automated);
    moving.reset();
    step(350);

    // Denormals: a quarter second of signal, then silence (a tail decaying), flushed (as C.A.W runs it) and not
    // (as a host that doesn't flush would).
    Plan tail;
    tail.untimedSeconds = 0.25;
    tail.seconds = S;
    tail.feed = Feed::Silence;
    auto flushed = rig(kRate, kBlock);
    if (!flushed) return failure(error);
    const Series tailFlushed = measure(*flushed, tail, cancel, watch);
    flushed.reset();
    auto raw = rig(kRate, kBlock);
    if (!raw) return failure(error);
    tail.keepDenormals = true;
    const Series tailRaw = measure(*raw, tail, cancel, watch);
    raw.reset();
    add(tailFlushed);
    add(tailRaw);
    step(450);
    if (cancelled(cancel)) return failure("cancelled");

    // Voices (instruments): 1 to 16 held notes.
    std::vector<std::pair<double, double>> voiceCurve;  // (voices, % of a block)
    if (instrument) {
        for (int n : kVoiceCounts) {
            Plan vp;
            vp.seconds = S / 2;
            vp.heldVoices = n;
            Series sv;
            if (!leastOf(kRate, kBlock, vp, sv)) return failure(error);
            voiceCurve.push_back({static_cast<double>(n), 100.0 * sv.mean / budget});
        }
    }
    step(600);

    // Block sizes: 32 to 512 frames.
    std::vector<std::pair<double, double>> blockCurve;  // (frames, % of that block's budget)
    std::vector<double> perFrameNs;
    for (uint32_t frames : kBlockSizes) {
        Plan bp;
        bp.block = frames;
        bp.seconds = S / 2;
        Series sb;
        if (!leastOf(kRate, kMaxBlock, bp, sb)) return failure(error);
        blockCurve.push_back({static_cast<double>(frames), 100.0 * sb.mean / budgetUs(frames, kRate)});
        perFrameNs.push_back(1000.0 * sb.mean / frames);
    }
    step(800);

    // Sample rates: 44.1, 48 and 96 kHz, 64-frame blocks.
    std::vector<std::pair<double, double>> rateCurve;  // (rate, % of a 64-frame block's budget at that rate)
    std::vector<double> rateMean;
    for (double rate : kRates) {
        Plan rp;
        rp.seconds = S / 2;
        Series sr;
        if (!leastOf(rate, kBlock, rp, sr)) return failure(error);
        rateCurve.push_back({rate, 100.0 * sr.mean / budgetUs(kBlock, rate)});
        rateMean.push_back(sr.mean);
    }
    step(950);
    if (cancelled(cancel)) return failure("cancelled");

    // ---------- The checks ----------
    std::vector<Check> checks;
    {
        Check c{"allocations", "pass", "", static_cast<double>(allocations), counted};
        if (!counted) {
            c.status = "warn";
            c.value = -1;
            c.detail = r.library.empty() ? "Allocations can't be counted in this build (C.A.W's test build counts them)"
                                       : "Allocations can't be counted for this plug-in here (C.A.W's Linux test build counts them)";
        } else if (allocations > 0) {
            c.status = "fail";
            c.detail = std::to_string(allocations) + " allocations or frees in the audio path";
        } else {
            c.detail = "No allocations in the audio path";
        }
        checks.push_back(c);
    }
    {
        const double slower = tailFlushed.mean > 0 ? 100.0 * (tailRaw.mean / tailFlushed.mean - 1.0) : 0.0;
        Check c{"denormals", "pass", "", std::max(0.0, slower)};
        const bool cheap = tailRaw.mean < floorUs && tailFlushed.mean < floorUs;
        c.status = cheap ? "pass" : grade(c.value, Thresholds::kDenormalWarnPct, Thresholds::kDenormalFailPct);
        c.detail = cheap ? "No slowdown that matters at silence" : fixed(c.value, 0) + "% slower at silence without flush-to-zero";
        if (tailRaw.subnormals > 0) {
            if (std::string(c.status) == "pass") c.status = "warn";
            c.detail += "; " + std::to_string(tailRaw.subnormals) + " subnormal output samples (C.A.W flushes them; other hosts may not)";
        }
        checks.push_back(c);
    }
    if (instrument) {
        const double perVoice = std::max(0.0, slopeOf(voiceCurve));
        Check c{"cost_per_voice", grade(perVoice, Thresholds::kVoiceWarnPct, Thresholds::kVoiceFailPct),
                fixed(perVoice, 2) + "% of a block per voice", perVoice};
        checks.push_back(c);
    }
    {
        const double small = perFrameNs.front(), large = perFrameNs.back();
        const double more = large > 0 ? 100.0 * (small / large - 1.0) : 0.0;
        Check c{"block_size_scaling", "pass", "", more};
        const bool cheap = blockCurve.front().second < Thresholds::kFloorPct;
        c.status = cheap ? "pass" : grade(more, Thresholds::kBlockWarnPct, Thresholds::kBlockFailPct);
        c.detail = cheap ? "Too cheap at 32 frames to matter" : fixed(more, 0) + "% more per frame at 32 frames than at 512";
        checks.push_back(c);
    }
    {
        const double ratio = rateMean[1] > 0 ? (rateMean[2] * kRates[2]) / (rateMean[1] * kRates[1]) : 0.0;
        Check c{"sample_rate_scaling", "pass", "", ratio};
        const bool cheap = rateMean[2] < floorUs;
        c.status = cheap ? "pass" : grade(ratio, Thresholds::kRateWarnRatio, Thresholds::kRateFailRatio);
        c.detail = cheap ? "Too cheap at 96 kHz to matter" : fixed(ratio, 2) + "x the 48 kHz cost at 96 kHz (2x is linear)";
        checks.push_back(c);
    }
    {
        // Graded by what the moving costs a project (the extra, as a share of a block), so a component with
        // hundreds of parameters isn't failed for its count; the detail also says how much more it is.
        const double more = baseRun.mean > 0 ? 100.0 * (automated.mean / baseRun.mean - 1.0) : 0.0;
        const double extra = std::max(0.0, 100.0 * (automated.mean - baseRun.mean) / budget);
        Check c{"param_change_cost", grade(extra, Thresholds::kParamWarnPct, Thresholds::kParamFailPct), "", extra};
        c.detail = "+" + fixed(extra, 2) + "% of a block with every parameter moving (" + fixed(std::max(0.0, more), 0) + "% more)";
        checks.push_back(c);
    }
    {
        const double share = baseRun.mean > 0 ? 100.0 * silent.mean / baseRun.mean : 0.0;
        Check c{"silence_cost", "pass", "", share};
        const bool sleeps = silent.us.size() > 0 && silent.slept * 2 >= silent.us.size();
        const bool cheap = silent.mean < floorUs;
        c.status = sleeps || cheap ? "pass" : share > Thresholds::kSilenceWarnPct ? "warn" : "pass";
        c.detail = sleeps ? "Sleeps when silent (says quiet)"
                          : fixed(share, 0) + "% of its working cost while silent" + (cheap ? " (too cheap to matter)" : "");
        checks.push_back(c);
    }
    if (failed > 0) checks.push_back({"process_failures", "fail", std::to_string(failed) + " blocks reported a failure", static_cast<double>(failed)});

    // ---------- The result ----------
    std::string o = "{\"ok\":true,\"error\":\"\",\"tool\":\"caw_component_bench\",\"format\":1,\"component\":{\"id\":" + str(r.id) +
                    ",\"name\":" + str(name) + ",\"kind\":" + str(instrument ? "instrument" : "effect") + "}" +
                    ",\"sample_rate\":" + num(kRate) + ",\"block_frames\":" + std::to_string(kBlock) +
                    ",\"seconds\":" + num(S) + ",\"cost_pct\":" + num(100.0 * baseRun.mean / budget) +
                    ",\"mean_us\":" + num(baseRun.mean) + ",\"p99_us\":" + num(baseRun.p99) + ",\"budget_us\":" + num(budget) +
                    ",\"checks\":[";
    for (size_t k = 0; k < checks.size(); ++k) {
        const Check& c = checks[k];
        o += std::string(k ? "," : "") + "{\"id\":" + str(c.id) + ",\"status\":" + str(c.status) + ",\"value\":" + num(c.value) +
             ",\"detail\":" + str(c.detail) + ",\"measured\":" + (c.measured ? "true" : "false") + "}";
    }
    o += "],\"sections\":[";
    const double baseNs = 1000.0 * baseRun.totalUs;  // the sections were recorded over the whole run
    for (size_t k = 0; k < sections.size(); ++k) {
        const profile::Section& s = sections[k];
        o += std::string(k ? "," : "") + "{\"name\":" + str(s.name) +
             ",\"pct\":" + num(baseNs > 0 ? 100.0 * static_cast<double>(s.ns) / baseNs : 0.0) +
             ",\"mean_ns\":" + num(s.calls ? static_cast<double>(s.ns) / static_cast<double>(s.calls) : 0.0) +
             ",\"calls\":" + std::to_string(s.calls) + "}";
    }
    auto curve = [&](const std::vector<std::pair<double, double>>& pts) {
        std::string c = "[";
        for (size_t k = 0; k < pts.size(); ++k) c += std::string(k ? "," : "") + "[" + num(pts[k].first) + "," + num(pts[k].second) + "]";
        return c + "]";
    };
    o += "],\"curves\":{\"voices\":" + curve(voiceCurve) + ",\"block_frames\":" + curve(blockCurve) +
         ",\"sample_rate\":" + curve(rateCurve) + "}";
    o += ",\"thresholds\":{\"floor_pct\":" + num(Thresholds::kFloorPct) + ",\"denormals_pct\":[" + num(Thresholds::kDenormalWarnPct) + "," +
         num(Thresholds::kDenormalFailPct) + "],\"cost_per_voice_pct\":[" + num(Thresholds::kVoiceWarnPct) + "," +
         num(Thresholds::kVoiceFailPct) + "],\"block_size_scaling_pct\":[" + num(Thresholds::kBlockWarnPct) + "," +
         num(Thresholds::kBlockFailPct) + "],\"sample_rate_scaling_ratio\":[" + num(Thresholds::kRateWarnRatio) + "," +
         num(Thresholds::kRateFailRatio) + "],\"param_change_cost_pct\":[" + num(Thresholds::kParamWarnPct) + "," +
         num(Thresholds::kParamFailPct) + "],\"silence_cost_pct\":[" + num(Thresholds::kSilenceWarnPct) + "]}";
    step(1000);
    return o + "}";
}

}  // namespace

void setAllocationCounter(AllocationCounter counter) noexcept { gCounter.store(counter, std::memory_order_release); }

std::string run(const Request& request, int32_t* progress, const int32_t* cancel) {
    try {
        bool idle = false;
        if (!gBusy.compare_exchange_strong(idle, true))
            return failure(gAbandoned.load() ? "a plug-in in an earlier benchmark never returned from process(); restart the app to "
                                               "run another"
                                             : "a benchmark is running");
        gAbandoned.store(false);
        // The measurements run on a thread of their own, which this one watches: a component whose process() never
        // returns is left behind there (the job fails, the worker and the pool go on), never waited for.
        auto watch = std::make_shared<Watch>();
        std::thread bench;
        try {
            bench = std::thread([watch, request]() {
                std::string text;
                try {
                    text = runLocked(request, &watch->progress, &watch->cancel, watch.get());
                } catch (const std::exception& e) {
                    text = failure(std::string("the component threw: ") + e.what());
                } catch (...) {
                    text = failure("the component threw an exception");
                }
                gBusy.store(false);
                {
                    const std::lock_guard<std::mutex> g(watch->mutex);
                    watch->result = std::move(text);
                    watch->finished = true;
                }
                watch->done.notify_all();
            });
        } catch (...) {
            gBusy.store(false);
            throw;
        }
        std::unique_lock<std::mutex> g(watch->mutex);
        for (;;) {
            if (watch->done.wait_for(g, std::chrono::milliseconds(20), [&] { return watch->finished; })) {
                std::string text = std::move(watch->result);
                g.unlock();
                bench.join();
                if (progress) relaxedStore(progress, relaxedLoad(&watch->progress));
                return text;
            }
            if (progress) relaxedStore(progress, relaxedLoad(&watch->progress));
            if (cancelled(cancel)) relaxedStore(&watch->cancel, 1);
            const int64_t start = watch->blockStartNs.load(std::memory_order_acquire);
            const int64_t deadline = watch->blockDeadlineNs.load(std::memory_order_relaxed);
            if (start != 0 && steadyNs() - start > deadline) {
                // Stuck in the component: stop waiting. Its thread keeps the bench's lock until (if ever) it returns,
                // then stops at its next check (cancel) and lets the next benchmark run.
                relaxedStore(&watch->cancel, 1);
                gAbandoned.store(true);
                g.unlock();
                bench.detach();
                return failure("the component did not return from process() within " + fixed(1e-9 * static_cast<double>(deadline), 1) +
                               " s; it was left running and its benchmark failed");
            }
        }
    } catch (const std::exception& e) {
        return failure(std::string("the benchmark failed: ") + e.what());
    } catch (...) {
        return failure("the benchmark failed");
    }
}

}  // namespace caw::bench
