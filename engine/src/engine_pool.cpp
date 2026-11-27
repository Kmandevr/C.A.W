// Mixer set-up: the mix pool's start and stop, the test hooks, and the Engine's constructors and destructor.
#include "engine_impl.h"

namespace caw {

namespace {

// Retirements the retired queue has no room for wait in the pending list: 2 * (maxLayers() + 1) entries
// plus this slack (256 at 64 layers), so every slot can hand back a chain and its fading one at once.
constexpr int kPendingSlack = 126;
// Grows above this many layers are not considered (node counts stay far inside uint32_t).
constexpr int kLayerCeiling = 1 << 20;

std::atomic<int> gTestMixThreads{-1};  // tests: every new Engine's pool (setMixThreadsForTest)

}  // namespace

uint32_t Engine::mixGraphNodesRun() const noexcept { return mixGraph_->executor.runCount(); }

bool Engine::mixLayerSerialForTest(const std::string& layerId) const {
    const auto it = layers_.find(layerId);
    if (it == layers_.end() || it->second.slot < 0) return false;
    return mixGraph_->executor.nodeSerial(mixGraph_->trackNode(it->second.slot)) ||
           mixGraph_->executor.nodeSerial(mixGraph_->busNode(it->second.slot));
}

uint32_t Engine::mixParallelLevelsForTest() const noexcept { return mixGraph_->executor.parallelLevelsRun(); }

bool Engine::startMixPool(uint32_t workers) { return startMixPool(workers, false); }

bool Engine::startMixPool(uint32_t workers, bool live) {
    if (!pool_) pool_ = std::make_unique<MixPool>();
    const bool ok = pool_->start(workers, live ? MixPool::Kind::Live : MixPool::Kind::Offline);
    mixActive_ = pool_->workers();
    pool_->setActive(mixActive_);
    return ok;
}

uint32_t Engine::mixActiveWorkers() const noexcept { return pool_ ? pool_->active() : 0; }

bool Engine::hintOn() const noexcept { return pool_ && pool_->hintActive(); }

void Engine::setCallbackMmcss(bool mmcss) noexcept {
    if (pool_) pool_->setCallbackMmcss(mmcss);
}

std::string Engine::audioThreadsJson() const {
    const tuning::Topology& t = tuning::topology();
    const int cpu = pool_ ? pool_->callbackCpu() : -1;
    const tuning::CoreClock clock = tuning::coreClock(cpu);
    const uint32_t tuned = pool_ ? pool_->workerTuning() : 0;
    const uint32_t cbTuned = pool_ ? pool_->callbackTuning() : 0;
    auto flags = [](uint32_t bits) {
        std::string f = "[";
        const std::pair<uint32_t, const char*> names[] = {
            {tuning::kAppliedPriority, "priority"}, {tuning::kAppliedRealtime, "realtime"},
            {tuning::kAppliedAffinity, "fast_cores"}, {tuning::kAppliedMmcss, "mmcss"},
            {tuning::kAppliedNoThrottle, "no_power_throttling"}};
        for (const auto& [bit, name] : names)
            if (bits & bit) f += std::string(f.size() > 1 ? "," : "") + "\"" + name + "\"";
        return f + "]";
    };
    std::string j = "{\"callback_cpu\":" + std::to_string(cpu);
    j += ",\"core_kind\":\"" + std::string(tuning::coreKindName(tuning::coreKind(cpu))) + "\"";
    j += ",\"clock_khz\":" + std::to_string(clock.currentKHz) + ",\"max_khz\":" + std::to_string(clock.maxKHz);
    j += ",\"hint\":" + std::string(pool_ && pool_->hintActive() ? "true" : "false");
    j += ",\"hint_state\":\"" + std::string(tuning::hintStateName(pool_ ? pool_->hintState() : tuning::HintState::None)) + "\"";
    {
        const tuning::HintDiagnostics d = pool_ ? pool_->hintDiagnostics() : tuning::hintDiagnostics(nullptr);
        j += ",\"hint_diag\":{\"sdk\":" + std::to_string(d.sdk) + ",\"is_feature_supported_call\":" +
             (d.featureCall ? "true" : "false") + ",\"is_feature_supported\":" + std::to_string(d.feature) +
             ",\"preferred_rate_ns\":" + std::to_string(d.preferredRateNs) + "}";
    }
    j += ",\"mmcss\":" + std::string(pool_ && pool_->callbackMmcss() ? "true" : "false");
    // The callback's scheduling policy (POSIX SCHED_*: 0 time-sharing, 1 FIFO, 2 RR) and nice, as it last described
    // itself: a shared or Bluetooth AAudio stream's is time-sharing, a low-latency (MMAP) one's FIFO (#234).
    j += ",\"callback_policy\":" + std::to_string(pool_ ? pool_->callbackPolicy() : 0) +
         ",\"callback_nice\":" + std::to_string(pool_ ? pool_->callbackNice() : 0);
    j += ",\"callback_tuning\":" + flags(cbTuned) + ",\"worker_tuning\":" + flags(tuned);
    j += ",\"workers\":" + std::to_string(mixWorkers()) + ",\"active_workers\":" + std::to_string(mixActiveWorkers());
    j += ",\"wait_share\":" + std::to_string(waitShare_.load(std::memory_order_relaxed));
    // The callback's synthetic load (load_stabilizer.h; Android, no hint session): "off", "idle" or "on", and the
    // smoothed share of each period it kept the core busy beyond the callback's own work, and the smoothed share
    // that work took (it idles while that is too small for the clock to matter).
    j += ",\"stabilizer\":\"" +
         std::string(stabilizerStateName(static_cast<StabilizerState>(stabilizerState_.load(std::memory_order_relaxed)))) +
         "\",\"stabilizer_share\":" + std::to_string(stabilizerShare_.load(std::memory_order_relaxed)) +
         ",\"stabilizer_work\":" + std::to_string(stabilizerWork_.load(std::memory_order_relaxed));
    j += ",\"cores\":" + std::to_string(t.cores) + ",\"fast_cores\":" + std::to_string(t.fast);
    j += ",\"hybrid\":" + std::string(t.hybrid ? "true" : "false") + ",\"core_source\":\"" + t.source + "\"}";
    return j;
}

void Engine::stopMixPool() noexcept { pool_.reset(); }

uint32_t Engine::mixWorkers() const noexcept { return pool_ ? pool_->workers() : 0; }

void Engine::startLiveMixPool() {
    if (!liveDevice_) {
        liveDevice_ = true;
        gLiveDevices.fetch_add(1, std::memory_order_relaxed);
    }
    if (gTestMixThreads.load(std::memory_order_relaxed) >= 0) return;  // a test's pool stays
    offlinePool_ = false;
    startMixPool(MixPool::defaultWorkers(), true);
    setMixParallel(MixParallel::Auto);
    // A new device (a reopen keeps the Engine): Auto starts serial again and decides from this device's load,
    // rather than carrying an earlier device's choice into callbacks it has no averages for.
    mixRestart_.store(true, std::memory_order_release);
}

void Engine::stopLiveMixPool() noexcept {
    stopMixPool();
    if (liveDevice_) {
        liveDevice_ = false;
        gLiveDevices.fetch_sub(1, std::memory_order_relaxed);
    }
}


void Engine::useOfflineMixPool() {
    if (gTestMixThreads.load(std::memory_order_relaxed) >= 0 || liveDevices() != 0) return;
    startMixPool(MixPool::defaultWorkers(), false);
    offlinePool_ = true;
    setMixParallel(MixParallel::Always);
}

bool Engine::useBenchmarkMixPool() {
    if (gTestMixThreads.load(std::memory_order_relaxed) >= 0) return false;  // a test's pool stays
    if (liveDevices() != 0) {
        setMixParallel(MixParallel::Never);
        return false;
    }
    startMixPool(MixPool::defaultWorkers(), false);
    setMixParallel(MixParallel::Auto);
    return true;
}

int Engine::mixThreadsForTest() noexcept { return gTestMixThreads.load(std::memory_order_relaxed); }

void Engine::setMixThreadsForTest(int workers) noexcept {
    gTestMixThreads.store(std::min(workers, static_cast<int>(MixPool::kMaxWorkers)), std::memory_order_relaxed);
}

void Engine::setMixLevelsForTest(bool on) noexcept {
    mixGraph_->executor.setLevelOrderForTest(on);
    routingDirty_ = true;
}
uint32_t Engine::mixGraphLevelsForTest() const noexcept { return mixGraph_->executor.levelCount(); }
int Engine::slotsScannedPerChunk() const noexcept { return liveCount_; }

Engine::Slot& Engine::ctlSlot(int i) noexcept { return *ctlTable_->slots[i]; }

Engine::Engine(double sampleRate)
    : Engine(sampleRate, makeEngineResourceBudget(detectHardwareProfile())) {}

Engine::Engine(double sampleRate, EngineResourceBudget resourceBudget)
    : sr_(sampleRate),
      trackGainCoef_(1.0 - detExp(-1.0 / (kGainSeconds * sampleRate))),
      nyquistPitch_(69.0 + 12.0 * detLog(std::max(1.0, sampleRate) / 880.0) / detLog(2.0)),
      resourceBudget_(resourceBudget),
      cmds_(new Spsc<Cmd, 1024>()),
      retired_(new Spsc<Retired, 1024>()),
      masterScope_(new std::atomic<float>[kScopeSize]),
      loudness_(std::make_unique<LoudnessMeter>()) {
    samplePreview_ = std::make_unique<SamplePreview>(sampleRate);
    for (int i = 0; i < kScopeSize; ++i) masterScope_[i].store(0);
    midiPending_.reset(new PendingMidi[Midi2InputQueue::kCapacity]);
    masterRetires_ = std::make_unique<RetireList>();
    loudness_->prepare(sampleRate);
    loudness_->sleepWhenUnread(true);  // it measures while something reads it (meters.h)
    audioIn_ = std::make_unique<LiveAudio>(sampleRate);
    masterCorrelation_.prepare(sampleRate);
    registerBuiltinComponents(nativeModules_);  // the Library's stereo tools, ready in every chain
    ctlSr_ = sampleRate;
    constexpr int initial = kInitialLayerCapacity;
    auto first = std::make_unique<SlotTable>();
    first->capacity = initial;
    first->slots.reset(new Slot*[static_cast<size_t>(initial + 1)]);
    first->processOrder.reset(new int[static_cast<size_t>(initial + 1)]());
    first->live.reset(new int[static_cast<size_t>(initial + 1)]());
    slotStore_.reserve(static_cast<size_t>(initial + 1));
    for (int s = 0; s <= initial; ++s) {
        slotStore_.push_back(std::make_unique<Slot>());
        slotStore_.back()->correlation.prepare(sr_);
        Slot& slot = *slotStore_.back();
        slot.index = s;
        for (int i = 0; i < kScopeSize; ++i) slot.scope[i].store(0);
        first->slots[s] = &slot;
    }
    first->graph.reset(new MixGraph(*this, initial, sampleRate, resourceBudget_));

    // maxLayers(): the largest capacity a grow can reach inside the graph-working budget. A grow
    // keeps the old table and graph alive until the audio thread retires them, so the peak is the
    // old graph + the new graph + the slots: bounded by twice the new graph. The graph's cost is
    // measured, from the executor's own working-memory estimate, at three capacities; it grows
    // with the square of the capacity (every bus and the master reserve room for every slot as a
    // source), so the three fix a quadratic exactly.
    {
        const double g1 = static_cast<double>(MixGraph(*this, 1, sampleRate, resourceBudget_).bytes());
        const double g2 = static_cast<double>(MixGraph(*this, 2, sampleRate, resourceBudget_).bytes());
        const double g64 = static_cast<double>(first->graph->bytes());
        const double d = g2 - g1;
        const double q = ((g64 - g2) - 62.0 * d) / 3906.0;  // (64^2 - 2^2) - 62 * (2^2 - 1^2)
        const double b = d - 3.0 * q;
        const double a = g1 - b - q;
        const double perSlot = static_cast<double>(sizeof(Slot) + sizeof(std::unique_ptr<Slot>) + sizeof(Slot*) +
                                                   2 * sizeof(int) + 2 * sizeof(Retired));
        const double budget = static_cast<double>(resourceBudget_.graphWorkingBytes);
        auto fits = [&](int c) {
            const double cap = c;
            return 2.0 * std::max(0.0, a + b * cap + q * cap * cap) + perSlot * (cap + 1.0) <= budget;
        };
        int lo = initial;  // fits, or is the floor every Engine keeps (the mix graph's own budget floor)
        if (fits(initial)) {
            int hi = initial * 2;  // the first capacity found not to fit
            while (hi < kLayerCeiling && fits(hi)) { lo = hi; hi *= 2; }
            if (hi >= kLayerCeiling) {
                hi = kLayerCeiling;
                if (fits(hi)) lo = hi;
            }
            while (hi - lo > 1) {
                const int mid = lo + (hi - lo) / 2;
                (fits(mid) ? lo : hi) = mid;
            }
        }
        maxLayers_ = lo;
    }
    // The pending list holds two retirements per slot at the largest capacity, so the slots can hand back what
    // they replaced (the retired queue is an Spsc fixed at 1024) while the control thread is slow to drain.
    pendingMax_ = 2 * (maxLayers_ + 1) + kPendingSlack;
    if (pendingMax_ < 2 * (maxLayers_ + 1)) throw std::logic_error("pending list cannot hold two retirements per slot");
    pending_.reset(new Retired[static_cast<size_t>(pendingMax_)]);
    table_ = std::move(first);
    bindTable();
    ctlTable_ = table_.get();
    ctlCapacity_.store(initial, std::memory_order_relaxed);
    ctlSong_ = SongTime{TempoMap::single(bpm_, sr_), TimeSigMap::single(beatsPerBar_), 0};
    song_ = new SongTime(ctlSong_);
    audioIn_->setSongTime(song_);
    updateTiming();
    ctlLoopLen_ = loopLen_;
    loopLenFlag_.store(loopLen_);
    if (const int n = gTestMixThreads.load(std::memory_order_relaxed); n > 0) {
        startMixPool(static_cast<uint32_t>(n));
        setMixParallel(MixParallel::Always);
    } else if (n == 0) {
        setMixParallel(MixParallel::Never);
    }
}

Engine::~Engine() {
    stopLiveMixPool();  // the workers first: they could run nodes that read what is freed below
    // No audio thread runs any more: free everything directly.
    Cmd c;
    while (cmds_->pop(c)) {
        delete c.pattern;
        delete c.automation;
        delete c.orderList;
        delete c.table;
        delete c.masterChain;
        delete c.componentAutomation;
        delete c.delay;
        delete c.sends;
        delete c.song;
        delete c.vca;
    }
    Retired r;
    while (retired_->pop(r)) {
        delete r.pattern;
        delete r.automation;
        delete r.order;
        delete r.table;
        delete r.masterChain;
        delete r.componentAutomation;
        delete r.delay;
        delete r.sends;
        delete r.song;
        delete r.vca;
    }
    for (int i = 0; i < pendingCount_; ++i) {
        delete pending_[i].pattern;
        delete pending_[i].automation;
        delete pending_[i].order;
        delete pending_[i].table;
        delete pending_[i].masterChain;
        delete pending_[i].componentAutomation;
        delete pending_[i].delay;
        delete pending_[i].sends;
        delete pending_[i].song;
        delete pending_[i].vca;
    }
    delete song_;
    delete vca_;
    delete masterChain_;
    masterChain_ = nullptr;
    delete masterFading_;
    masterFading_ = nullptr;
    for (const auto& slot : slotStore_) {
        delete slot->inserts;
        delete slot->insertsFading;
        delete slot->instrument;
        delete slot->instrumentFading;
        delete slot->delayFading;
        delete slot->delay;
        delete slot->sends;
        delete slot->pattern;
        delete slot->automation;
    }
}

}  // namespace caw
