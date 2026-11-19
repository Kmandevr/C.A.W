// Preen's Denoise variant (org.caw.clean variant 0): learned or adaptive noise profile, Wiener gains on the shared STFT, latency by quality tier; and its offline clip pass.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <new>
#include <string>
#include <vector>

#include "builtin_effects.h"
#include "component_chain.h"
#include "fx_clean.h"
#include "fx_clean_denoise.h"

namespace caw::fx {

namespace {

using clean::Bins;
using clean::DenoiseCore;

enum Param : uint32_t {
    kReduction, kSensitivity, kSmoothing, kLow, kHigh, kTransient, kAdaptive, kLearn, kListen, kQuality, kMonitor, kCount
};
constexpr std::string_view kTiers[] = {"Eco", "Normal", "High"};

// A choice set by hand only (it sets the latency, or is an action): no lane, modulation or MIDI.
ParameterDescriptor& byHand(ParameterDescriptor& p) {
    p.automatable = p.modulatable = p.midiMappable = false;
    return p;
}

const ParamTable& denoiseParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("reduction", "Reduction", 12.0, 0.0, 40.0, "dB");
        p.num("sensitivity", "Sensitivity", 0.0, -12.0, 12.0, "dB");
        p.num("smoothing", "Smoothing", 0.5, 0.0, 1.0);
        p.expo("low", "Low protect", 20.0, 20.0, 2000.0, "Hz");
        p.expo("high", "High protect", 20000.0, 1000.0, 20000.0, "Hz");
        p.num("transient", "Transient keep", 0.3, 0.0, 1.0);
        p.pick("adaptive", "Adaptive", 1.0, kOffOn);
        byHand(p.pick("learn", "Learn", 0.0, kOffOn));
        p.pick("listen", "Listen to removed", 0.0, kOffOn);
        byHand(p.pick("quality", "Quality", 1.0, kTiers));
        byHand(p.pick("monitor", "Low-latency monitoring", 0.0, kOffOn));
        return p;
    }();
    return t;
}

constexpr uint32_t kMagic = 0x314e5250u;  // "PRN1"
constexpr uint32_t kMaxSavedBins = 8193;   // a 16,384-point window (High at 192 kHz)
constexpr uint32_t kDisplayPoints = 32;

// A saved profile (state bytes: magic, bins, bin width Hz as float bits, frames learned, then both sides' noise
// power density per bin, power / window) into `out` (both sides, `bins` points `binHz` apart). Untrusted: every
// size and value is checked.
bool loadProfile(const uint8_t* src, uint32_t size, float* const* out, uint32_t bins, double binHz, uint32_t& frames) {
    if (!src || size < 16) return false;
    uint32_t head[4];
    std::memcpy(head, src, 16);
    float hz;
    std::memcpy(&hz, &head[2], 4);
    const uint32_t n = head[1];
    if (head[0] != kMagic || n < 2 || n > kMaxSavedBins || !(hz > 0.0f && hz < 1e5f)) return false;
    if (size != 16 + 8ull * n) return false;
    std::vector<float> v(2ull * n);
    std::memcpy(v.data(), src + 16, 8ull * n);
    for (float x : v)
        if (!(x >= 0.0f && x < 1e30f)) return false;
    for (int c = 0; c < 2; ++c)
        for (uint32_t j = 0; j < bins; ++j) {
            const double pos = j * binHz / hz;
            const uint32_t a = static_cast<uint32_t>(pos);
            const double f = pos - a;
            const float* s = v.data() + c * n;
            out[c][j] = a + 1 < n ? static_cast<float>(s[a] + (s[a + 1] - s[a]) * f) : s[n - 1];
        }
    frames = head[3];
    return true;
}

class Denoise final : public EffectBase, public VariableLatency, public ArmedFlag {
public:
    explicit Denoise(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        const int q = count > kQuality ? static_cast<int>(values[kQuality] + 0.5) : 1;
        const bool mon = armed() || (count > kMonitor && values[kMonitor] >= 0.5);
        return clean::tierWindow(q, mon, rate());
    }
    // Armed: the monitoring window, as `monitor` On.
    bool armedDiffers(const double* values, uint32_t count) const noexcept override {
        return !(count > kMonitor && values[kMonitor] >= 0.5);
    }
    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        written = 0;
        if (!hasProfile_.load(std::memory_order_acquire)) return true;  // nothing learned: no state
        const uint32_t bins = maxBins_;
        const uint32_t need = 16 + 8 * bins;
        if (!dst || capacity < need) return false;
        for (int attempt = 0; attempt < 4; ++attempt) {  // a seqlock: the audio thread publishes a new profile rarely
            const uint32_t g0 = gen_.load(std::memory_order_acquire);
            if (g0 & 1u) continue;
            const float hz = static_cast<float>(rate() / maxN_);
            uint32_t head[4] = {kMagic, bins, 0, learnedFrames_};
            std::memcpy(&head[2], &hz, 4);
            std::memcpy(dst, head, 16);
            std::memcpy(dst + 16, profile_[0].data(), 4ull * bins);
            std::memcpy(dst + 16 + 4ull * bins, profile_[1].data(), 4ull * bins);
            std::atomic_thread_fence(std::memory_order_acquire);
            if (gen_.load(std::memory_order_relaxed) == g0) {
                written = need;
                return true;
            }
        }
        return false;
    }
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        if (version != 1) return false;
        if (size == 0) return true;
        float* out[2] = {profile_[0].data(), profile_[1].data()};
        uint32_t frames = 0;
        bool ok = false;
        try {
            ok = loadProfile(src, size, out, maxBins_, rate() / maxN_, frames);
        } catch (...) {
            ok = false;
        }
        if (!ok) return false;
        learnedFrames_ = frames;
        hasProfile_.store(true, std::memory_order_release);
        gen_.fetch_add(2, std::memory_order_acq_rel);
        return true;
    }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        maxN_ = clean::maxWindow(sampleRate);
        maxBins_ = maxN_ / 2 + 1;
        if (!stft_.prepare(maxN_) || !core_.prepare(maxBins_)) return false;
        try {
            for (int c = 0; c < 2; ++c) {
                held_[c].assign(maxBins_, 1.0f);
                profile_[c].assign(maxBins_, 0.0f);
                mapped_[c].assign(maxBins_, 0.0f);
                learnSum_[c].assign(maxBins_, 0.0);
            }
        } catch (...) {
            return false;
        }
        n_ = 0;
        return true;
    }
    void clearState() noexcept override {
        stft_.clear();
        core_.clear();
        for (auto& h : held_) std::fill(h.begin(), h.end(), 1.0f);
    }
    // One window more than the default: the delayed output must leave too before it sleeps.
    uint64_t idleFrames() const noexcept override { return stft_.size() + static_cast<uint64_t>(0.05 * rate()); }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const uint32_t n = clean::tierWindow(choice(kQuality, at), on(kMonitor, at) || armed(), sr);
        if (n != n_) {
            n_ = n;
            stft_.setSize(n);
            core_.start(n, sr);
            for (auto& h : held_) std::fill(h.begin(), h.end(), 1.0f);
            smoothFor_ = -1;
            mappedFor_ = ~0u;
        }
        const double red = clean::clampd(param(kReduction, at), 0.0, 40.0);
        st_.floor = red <= 0.0 ? 1.0 : lib::dbToGain(-red);
        st_.sens = lib::dbToGain(2.0 * clean::clampd(param(kSensitivity, at), -12.0, 12.0));  // a power: 10^(dB / 10)
        const double s = clean::clampd(param(kSmoothing, at), 0.0, 1.0);
        st_.smoothing = s;
        if (s != smoothFor_) {
            smoothFor_ = s;
            const double hop = core_.hopSeconds();
            fall_ = s > 0.0 ? detExp(-hop / (0.06 * s)) : 0.0;  // a falling gain lingers (musical noise)
            rise_ = 0.0;                                         // a rising one is at once (onsets kept)
        }
        st_.low = param(kLow, at);
        st_.high = param(kHigh, at);
        st_.transient = clean::clampd(param(kTransient, at), 0.0, 1.0);
        st_.adaptive = on(kAdaptive, at);
        st_.listen = on(kListen, at);
        const bool learn = on(kLearn, at);
        if (learn && !learning_) {  // a new profile: start from nothing
            for (auto& v : learnSum_) std::fill(v.begin(), v.end(), 0.0);
            learnFrames_ = 0;
            learnN_ = n_;
        } else if (!learn && learning_ && learnFrames_ > 0) {
            publish();
        }
        learning_ = learn;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        stft_.process(inL, inR, outL, outR, n, [this](Bins& b) { frame(b); });
    }

    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = learning_ ? 1.0f : 0.0f;
        out[3] = static_cast<float>((learning_ ? learnFrames_ : learnedFrames_) * core_.hopSeconds());
        out[4] = hasProfile_.load(std::memory_order_relaxed) ? 1.0f : 0.0f;
        out[5] = static_cast<float>(1000.0 * n_ / rate());
        out[6] = static_cast<float>(n_);
        out[7] = static_cast<float>(meanGainDb_);
        out[8] = st_.adaptive ? 1.0f : 0.0f;
        out[9] = static_cast<float>(kDisplayPoints);
        // The noise estimate (dB, 0 = a full-scale sine's bin) and the gains (dB) on 32 log points, 20 Hz-20 kHz.
        const double ref = (n_ / kPi) * (n_ / kPi);
        for (uint32_t j = 0; j < kDisplayPoints; ++j) {
            float nz = -120.0f, g = 0.0f;
            if (watched && n_) {
                const double hz = 20.0 * std::pow(1000.0, j / (kDisplayPoints - 1.0));
                const uint32_t k = std::min<uint32_t>(core_.bins() - 1, static_cast<uint32_t>(hz * n_ / rate() + 0.5));
                const double p = 0.5 * (core_.noise(0)[k] + core_.noise(1)[k]);
                nz = static_cast<float>(std::max(-120.0, 10.0 * std::log10(p / ref + 1e-30)));
                g = static_cast<float>(lib::gainToDb(0.5 * (held_[0][k] + held_[1][k]), -120.0));
            }
            out[10 + j] = nz;
            out[10 + kDisplayPoints + j] = g;
        }
        return 10 + 2 * kDisplayPoints;
    }

private:
    void frame(Bins& b) noexcept {
        core_.track(b);
        if (learning_) {  // learning: the noise passes through unchanged while its mean power is taken
            const double inv = 1.0 / b.n;
            for (int c = 0; c < 2; ++c)
                for (uint32_t k = 0; k < b.count; ++k) learnSum_[c][k] += DenoiseCore::power(b, c, k) * inv;
            ++learnFrames_;
            meanGainDb_ = 0.0;
            return;
        }
        const bool profile = hasProfile_.load(std::memory_order_relaxed);
        if (profile && mappedFor_ != n_ + gen_.load(std::memory_order_relaxed)) remap();
        const float* prof[2] = {mapped_[0].data(), mapped_[1].data()};
        core_.rawGains(b, st_, profile ? prof : nullptr);
        float* g[2] = {core_.gainsMutable(0), core_.gainsMutable(1)};
        for (int c = 0; c < 2; ++c) clean::smoothInTime(held_[c].data(), g[c], b.count, fall_, rise_);
        const double keep = st_.transient * core_.onset();
        const float* cg[2] = {g[0], g[1]};
        DenoiseCore::apply(b, cg, keep, st_.listen);
        double sum = 0.0;
        for (uint32_t k = 0; k < b.count; ++k) sum += g[0][k] * g[0][k] + g[1][k] * g[1][k];
        meanGainDb_ = 10.0 * std::log10(sum / (2.0 * b.count) + 1e-12);
    }
    // The learned frames' mean onto the largest window's grid (the saved grid), under the seqlock.
    void publish() noexcept {
        gen_.fetch_add(1, std::memory_order_acq_rel);
        const double inv = 1.0 / static_cast<double>(learnFrames_);
        const uint32_t from = learnN_ / 2 + 1;
        for (int c = 0; c < 2; ++c)
            for (uint32_t j = 0; j < maxBins_; ++j) {
                const double pos = static_cast<double>(j) * learnN_ / maxN_;
                const uint32_t a = static_cast<uint32_t>(pos);
                const double f = pos - a;
                const double* s = learnSum_[c].data();
                const double v = a + 1 < from ? s[a] + (s[a + 1] - s[a]) * f : s[from - 1];
                profile_[c][j] = static_cast<float>(v * inv);
            }
        learnedFrames_ = learnFrames_;
        hasProfile_.store(true, std::memory_order_release);
        gen_.fetch_add(1, std::memory_order_acq_rel);
    }
    // The profile for this window: its power per bin (density times the window), the mean of the bins it covers.
    void remap() noexcept {
        const uint32_t r = maxN_ / n_, bins = n_ / 2 + 1;
        for (int c = 0; c < 2; ++c)
            for (uint32_t k = 0; k < bins; ++k) {
                double s = 0.0;
                uint32_t m = 0;
                for (uint32_t j = k * r; j < k * r + r && j < maxBins_; ++j) s += profile_[c][j], ++m;
                mapped_[c][k] = static_cast<float>(m ? s / m * n_ : 0.0);
            }
        mappedFor_ = n_ + gen_.load(std::memory_order_relaxed);
    }

    const ModuleDescriptor& d_;
    clean::Stft stft_;
    DenoiseCore core_;
    DenoiseCore::Settings st_;
    std::vector<float> held_[2], profile_[2], mapped_[2];
    std::vector<double> learnSum_[2];
    uint32_t maxN_ = 4096, maxBins_ = 2049, n_ = 0, learnN_ = 2048, mappedFor_ = ~0u;
    uint64_t learnFrames_ = 0;
    uint32_t learnedFrames_ = 0;
    bool learning_ = false;
    std::atomic<bool> hasProfile_{false};
    std::atomic<uint32_t> gen_{0};
    double smoothFor_ = -1, fall_ = 0, rise_ = 0, meanGainDb_ = 0;
};

}  // namespace

const ModuleDescriptor& preenDenoiseBaseDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor x = withDomains(withCpu(effectDescriptor("org.caw.clean", "Preen", denoiseParams(),
                                                                  clean::tierWindow(1, false, 48000), 4096),
                                                 CpuClass::Heavy),
                                         kDomainWhole);
        x.maxStateBytes = 16 + 8 * kMaxSavedBins;
        return x;
    }();
    return d;
}
ModuleProcessor* makePreenDenoiseAs(const ModuleDescriptor& variant) noexcept {
    return new (std::nothrow) Denoise(variant);
}

// ---- The clip pass ------------------------------------------------------------------------------------------------

bool denoiseClip(const float* inL, const float* inR, float* outL, float* outR, size_t frames, double sampleRate,
                 const DenoiseClipSettings& s, std::string* error) {
    auto fail = [&](const char* why) {
        if (error) *error = why;
        return false;
    };
    if (!inL || !outL || !outR) return fail("denoiseClip: a buffer is null");
    if (!inR) inR = inL;
    if (!(sampleRate >= 8000.0 && sampleRate <= 384000.0)) return fail("denoiseClip: the sample rate is outside 8-384 kHz");
    if (frames > (1ull << 31)) return fail("denoiseClip: the clip is longer than 2^31 frames");
    if (frames == 0) return true;
    try {
        const uint32_t n = clean::maxWindow(sampleRate), hop = n / 4, bins = n / 2 + 1;
        clean::SharedTables& tables = *clean::sharedTables(n);
        // The clip with a window of silence before and after: every sample of it under four whole frames.
        const size_t padded = frames + 2ull * n;
        std::vector<float> pl(padded, 0.0f), pr(padded, 0.0f), ol(padded, 0.0f), orr(padded, 0.0f);
        for (size_t i = 0; i < frames; ++i) {
            pl[n + i] = static_cast<float>(finiteOr0(inL[i]));
            pr[n + i] = static_cast<float>(finiteOr0(inR[i]));
        }
        const size_t count = (padded - n) / hop + 1;
        std::vector<double> re(n), im(n);
        DenoiseCore core;
        if (!core.prepare(bins)) return fail("denoiseClip: out of memory");
        core.start(n, sampleRate);
        DenoiseCore::Settings st;
        st.floor = s.reduction <= 0.0 ? 1.0 : lib::dbToGain(-clean::clampd(s.reduction, 0.0, 40.0));
        st.sens = lib::dbToGain(2.0 * clean::clampd(s.sensitivity, -12.0, 12.0));
        st.smoothing = clean::clampd(s.smoothing, 0.0, 1.0);
        st.low = s.low;
        st.high = s.high;
        st.adaptive = false;
        // The noise: the profile given, else the tracker's estimate averaged over the clip (after its first 1.5 s,
        // when the clip is long enough).
        std::vector<float> noise[2] = {std::vector<float>(bins, 0.0f), std::vector<float>(bins, 0.0f)};
        std::vector<double> lr(bins), li(bins), rr(bins), ri(bins);
        Bins b{lr.data(), li.data(), rr.data(), ri.data(), bins, n};
        if (s.profile) {
            std::vector<float> grid[2] = {std::vector<float>(bins), std::vector<float>(bins)};
            float* out[2] = {grid[0].data(), grid[1].data()};
            uint32_t learned = 0;
            if (!loadProfile(s.profile, s.profileBytes, out, bins, sampleRate / n, learned))
                return fail("denoiseClip: the noise profile does not parse");
            for (int c = 0; c < 2; ++c)
                for (uint32_t k = 0; k < bins; ++k) noise[c][k] = grid[c][k] * static_cast<float>(n);
        } else {
            std::vector<double> sum[2] = {std::vector<double>(bins, 0.0), std::vector<double>(bins, 0.0)};
            const size_t warm = static_cast<size_t>(1.5 / core.hopSeconds());
            size_t used = 0;
            for (size_t f = 0; f < count; ++f) {
                clean::analyzeFrame(tables, n, pl.data() + f * hop, pr.data() + f * hop, re.data(), im.data(), b);
                core.track(b);
                if (f < warm && count > 2 * warm) continue;
                for (int c = 0; c < 2; ++c)
                    for (uint32_t k = 0; k < bins; ++k) sum[c][k] += core.tracked(c, k);
                ++used;
            }
            for (int c = 0; c < 2; ++c)
                for (uint32_t k = 0; k < bins; ++k) noise[c][k] = static_cast<float>(used ? sum[c][k] / used : 0.0);
        }
        const float* prof[2] = {noise[0].data(), noise[1].data()};
        // Raw gains run K frames ahead of the frame synthesized, which takes a triangle-weighted mean of the raw
        // gains K before to K after it (Smoothing sets the triangle's width): smoothed both ways in time.
        constexpr size_t K = 3;
        const double width = 1.0 + 3.0 * st.smoothing;
        std::vector<float> ring(2 * (2 * K + 1) * bins), onset(2 * K + 1);
        std::vector<double> spectra(4 * (K + 1) * bins);
        std::vector<float> g(2 * bins);
        for (size_t f = 0; f < count + K; ++f) {
            if (f < count) {
                const size_t slot = f % (K + 1);
                Bins sb{spectra.data() + (4 * slot) * bins, spectra.data() + (4 * slot + 1) * bins,
                        spectra.data() + (4 * slot + 2) * bins, spectra.data() + (4 * slot + 3) * bins, bins, n};
                clean::analyzeFrame(tables, n, pl.data() + f * hop, pr.data() + f * hop, re.data(), im.data(), sb);
                core.rawGains(sb, st, prof);
                const size_t r = f % (2 * K + 1);
                for (int c = 0; c < 2; ++c)
                    std::memcpy(ring.data() + (2 * r + c) * bins, core.gains(c), 4ull * bins);
                onset[r] = static_cast<float>(core.onset());
            }
            if (f < K) continue;
            const size_t t = f - K;
            for (size_t k = 0; k < 2 * bins; ++k) g[k] = 0.0f;
            double total = 0.0, keep = 0.0;
            for (size_t u = t >= K ? t - K : 0; u <= t + K && u < count; ++u) {
                const double d = u > t ? static_cast<double>(u - t) : static_cast<double>(t - u);
                const double w = std::max(0.0, 1.0 - d / width);
                if (w <= 0.0) continue;
                const size_t r = u % (2 * K + 1);
                for (size_t k = 0; k < 2 * bins; ++k) g[k] += static_cast<float>(w * ring[2 * r * bins + k]);
                total += w;
                if (u == t) keep = onset[r];
            }
            for (size_t k = 0; k < 2 * bins; ++k) g[k] = static_cast<float>(g[k] / total);
            const size_t slot = t % (K + 1);
            Bins sb{spectra.data() + (4 * slot) * bins, spectra.data() + (4 * slot + 1) * bins,
                    spectra.data() + (4 * slot + 2) * bins, spectra.data() + (4 * slot + 3) * bins, bins, n};
            const float* cg[2] = {g.data(), g.data() + bins};
            DenoiseCore::apply(sb, cg, clean::clampd(s.transient, 0.0, 1.0) * keep, false);
            clean::synthesizeFrame(tables, n, sb, re.data(), im.data());
            for (uint32_t j = 0; j < n; ++j) {
                ol[t * hop + j] += static_cast<float>(re[j]);
                orr[t * hop + j] += static_cast<float>(im[j]);
            }
        }
        for (size_t i = 0; i < frames; ++i) outL[i] = ol[n + i], outR[i] = orr[n + i];
    } catch (...) {
        return fail("denoiseClip: out of memory");
    }
    return true;
}

}  // namespace caw::fx
