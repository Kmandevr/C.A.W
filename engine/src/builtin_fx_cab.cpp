// The Convolver's 1.1.0 "Cab" variant: C.A.W's own small guitar and bass cabinet responses, with mic position and distance, at no latency.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <deque>
#include <memory>
#include <new>
#include <span>
#include <vector>

#include "caw/library/eq.hpp"
#include "caw/library/filter.hpp"
#include "fx_merged.h"
#include "fx_modes_kit.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0), C.A.W's own design (sound plan 2026-11-19: "Cab (C.A.W's own cabinets, mic
// position and distance, plus the user's IRs)"). Variant 1 of org.caw.convolver (variant 0 is the convolver as it
// was, which plays the user's IRs).
// Each cabinet is designed, not recorded: its mid and high voice (a cone's peaks and dips, its breakup region and
// roll-off, a short reflection inside the box) is a short impulse response, about 2.7 ms (128 taps at 48 kHz),
// rendered once at start-up for the common rates from the cabinet's table below (state-variable filters run on an
// impulse, then faded out), shared read-only by every instance; another rate renders its own at prepare. The
// cabinet's lows (its high-pass and box resonance, too long for the short response) are two filters after it. The
// mic: position moves from the cone's centre (bright) to its edge (dark: a high shelf and a presence bell),
// distance from close (the proximity lift of the lows) to far (less top, and a floor reflection 0.3..3 ms late).
// The response runs direct (no FFT): no latency, and at this length the cheapest way.

namespace caw::fx {

namespace {

constexpr std::string_view kConvId = "org.caw.convolver";
constexpr std::string_view kConvName = "Convolver";
constexpr std::string_view kCabs[] = {"1x12 open", "2x12 closed", "4x12 closed", "1x10 small", "4x10 bass", "1x15 bass"};
constexpr int kCabCount = static_cast<int>(std::size(kCabs));
constexpr double kIrSeconds = 128.0 / 48000.0;  // the voice's peaks and roll-off ring out well inside 2.7 ms
constexpr uint32_t kMaxTaps = 256;  // 96 kHz
constexpr double kMaxReflection = 0.0031;

struct Peak {
    double hz, db, q;
};
struct CabDesign {
    double highpassHz, resonanceHz, resonanceDb;  // the lows, after the response
    Peak peaks[4];                                  // the voice: peaks and dips, in the response
    double lowpassHz;                               // the roll-off (24 dB/octave), in the response
    double boxDelayMs, boxGain;                     // a reflection inside the box
};
// C.A.W's own voicings (not measured from any product): open backs leaner and airier, closed 4x12s thick in the
// low mids, bass cabinets extended low with a later roll-off (the 4x10 with a tweeter-like top).
constexpr CabDesign kDesigns[kCabCount] = {
    {75, 110, 3, {{900, -2, 1.0}, {2200, 4, 1.4}, {3800, -5, 3.0}, {5200, 3, 2.0}}, 5600, 0.25, 0.15},
    {70, 100, 4, {{600, 1.5, 1.0}, {1900, 3, 1.2}, {3400, 5, 2.0}, {4600, -6, 3.0}}, 5200, 0.32, 0.22},
    {65, 95, 5, {{350, 2, 0.8}, {1600, -2, 1.5}, {2900, 5, 1.8}, {4200, -4, 2.5}}, 4800, 0.45, 0.25},
    {110, 160, 2, {{1200, 3, 1.2}, {2600, 5, 1.6}, {4100, -3, 2.5}, {5500, 2, 2.0}}, 6200, 0.18, 0.12},
    {45, 70, 4, {{250, 2, 0.8}, {900, -3, 1.0}, {2500, 3, 1.5}, {7000, 4, 1.2}}, 9500, 0.3, 0.15},
    {35, 60, 5, {{180, 2.5, 0.8}, {700, -2, 1.0}, {1800, 2, 1.4}, {3200, -4, 2.0}}, 3600, 0.4, 0.2},
};

// One cabinet's response at a rate: `taps` floats, stored reversed (the newest sample's tap last) for the FIR.
struct CabIr {
    uint32_t taps = 0;
    float reversed[kMaxTaps] = {};
    float interleaved[2 * kMaxTaps] = {};  // each tap twice (left, right), for the FIR
};

void render(const CabDesign& c, double sr, CabIr& out) {
    const uint32_t taps = std::min<uint32_t>(kMaxTaps, (static_cast<uint32_t>(kIrSeconds * sr + 0.5) + 7) / 8 * 8);  // whole groups of 8
    lib::EqBand peaks[4];
    for (int k = 0; k < 4; ++k) peaks[k].set(lib::EqBand::Kind::Bell, c.peaks[k].hz, c.peaks[k].db, c.peaks[k].q, sr);
    lib::Svf lp1, lp2;
    lp1.set(c.lowpassHz, 0.54, sr);  // two stages: a Butterworth-like 4th order
    lp2.set(c.lowpassHz, 1.31, sr);
    std::vector<double> h(taps, 0.0);
    const uint32_t box = static_cast<uint32_t>(c.boxDelayMs * 0.001 * sr);
    double energy = 0.0;
    for (uint32_t i = 0; i < taps; ++i) {
        double x = i == 0 ? 1.0 : 0.0;
        if (i == box) x -= c.boxGain;  // the box's reflection, inverted
        for (auto& p : peaks) x = p.process(x);
        x = lp2.lowpass(lp1.lowpass(x));
        const double fadeFrom = 0.75 * taps;  // the last quarter faded out (a half Hann)
        if (i >= fadeFrom) x *= 0.5 + 0.5 * std::cos(kPi * (i - fadeFrom) / (taps - fadeFrom));
        h[i] = x;
        energy += x * x;
    }
    // Normalised so a mid tone (its response near 1 kHz) passes at about unity: by the DC gain of the voice, which
    // the low filters (after) take care of.
    double dc = 0.0;
    for (double v : h) dc += v;
    const double norm = std::fabs(dc) > 1e-9 ? 1.0 / std::fabs(dc) : 1.0 / std::sqrt(energy);
    out.taps = taps;
    for (uint32_t i = 0; i < taps; ++i) out.reversed[taps - 1 - i] = static_cast<float>(h[i] * norm);
    for (uint32_t i = 0; i < taps; ++i) out.interleaved[2 * i] = out.interleaved[2 * i + 1] = out.reversed[i];
}

// The responses at the common rates, rendered once (from the cab's descriptor function, at registration).
struct SharedIrs {
    static constexpr double kRates[] = {44100.0, 48000.0, 88200.0, 96000.0};
    CabIr irs[std::size(kRates)][kCabCount];
    SharedIrs() {
        for (size_t r = 0; r < std::size(kRates); ++r)
            for (int c = 0; c < kCabCount; ++c) render(kDesigns[c], kRates[r], irs[r][c]);
    }
    const CabIr* find(double sr, int cab) const noexcept {
        for (size_t r = 0; r < std::size(kRates); ++r)
            if (kRates[r] == sr) return &irs[r][cab];
        return nullptr;
    }
};
const SharedIrs& sharedIrs() {
    static const SharedIrs s;
    return s;
}

// Eight partial sums of h[k] w[k] over `count` floats (a multiple of 8), lane j summing k = j, j + 8, ...: as two
// four-wide vectors on GCC and Clang (SSE2, NEON), the same sums in the same order as the scalar form.
inline void dot8(const float* h, const float* w, uint32_t count, float acc[8]) noexcept {
#if defined(__GNUC__)
    typedef float F4 __attribute__((vector_size(16)));
    F4 a = {0, 0, 0, 0}, b = {0, 0, 0, 0};
    for (uint32_t k = 0; k < count; k += 8) {
        F4 h0, h1, w0, w1;
        std::memcpy(&h0, h + k, 16), std::memcpy(&h1, h + k + 4, 16);
        std::memcpy(&w0, w + k, 16), std::memcpy(&w1, w + k + 4, 16);
        a += h0 * w0;
        b += h1 * w1;
    }
    for (int j = 0; j < 4; ++j) acc[j] = a[j], acc[4 + j] = b[j];
#else
    for (int j = 0; j < 8; ++j) acc[j] = 0.0f;
    for (uint32_t k = 0; k < count; k += 8)
        for (int j = 0; j < 8; ++j) acc[j] += h[k + j] * w[k + j];
#endif
}

enum CabParam : uint32_t { kKCab, kKPosition, kKDistance, kKOutput, kKMix, kKCount };

const ParamTable& cabParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("cab", "Cabinet", 2.0, kCabs);
        p.num("position", "Mic position", 0.3, 0.0, 1.0);
        p.num("distance", "Mic distance", 0.2, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

class Cab : public EffectBase {
public:
    explicit Cab(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

    // The Convolver's state (a user's IR) is kept as it came, so going back to variant 0 still has it.
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        written = 0;
        if (kept_.empty()) return true;
        if (!dst || kept_.size() > capacity) return false;
        std::memcpy(dst, kept_.data(), kept_.size());
        written = static_cast<uint32_t>(kept_.size());
        return true;
    }
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        if (version != 1 || (size && !src)) return false;
        try {
            kept_.assign(src, src + size);
        } catch (...) {
            return false;
        }
        return true;
    }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        shared_ = sharedIrs().find(sr, 0) != nullptr;
        if (!shared_) {  // an uncommon rate: this instance's own (at most 6 x 2 KiB)
            try {
                own_.reset(new CabIr[kCabCount]);
            } catch (...) {
                return false;
            }
            for (int c = 0; c < kCabCount; ++c) render(kDesigns[c], sr, own_[c]);
        }
        for (auto& l : reflect_) l.prepare(static_cast<size_t>(kMaxReflection * sr) + 4);
        return true;
    }
    void clearState() noexcept override {
        for (float& v : ring_) v = 0.0f;
        pos_ = 0;
        for (auto& l : reflect_) l.clear();
        high_.clear(), res_.clear(), shelf_.clear(), bell_.clear(), prox_.clear(), air_.clear();
        outRamp_.reset();
        mixRamp_.reset();
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>(0.05 * rate()); }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const int cab = std::clamp(choice(kKCab, at), 0, kCabCount - 1);
        if (cab != cab_ || !ir_) {
            cab_ = cab;
            ir_ = shared_ ? sharedIrs().find(sr, cab) : &own_[cab];
            // A new cabinet starts on a clear history (a choice, not a sweep).
            for (float& v : ring_) v = 0.0f;
            pos_ = 0;
        }
        const CabDesign& c = kDesigns[cab_];
        position_ = std::clamp(param(kKPosition, at), 0.0, 1.0);
        distance_ = std::clamp(param(kKDistance, at), 0.0, 1.0);
        using K = modes::PairEq;
        high_.set(c.highpassHz, 0.8, sr);
        res_.set(K::Bell, c.resonanceHz, c.resonanceDb, 1.6, sr);
        shelf_.set(K::HighShelf, 3000.0, 2.0 - 10.0 * position_, 0.7071, sr);
        bell_.set(K::Bell, 4500.0, 3.0 - 6.0 * position_, 1.0, sr);
        const double close = (1.0 - distance_) * (1.0 - distance_);
        prox_.set(K::LowShelf, 150.0, 6.0 * close, 0.7071, sr);
        air_.set(20000.0 * detPow(2.0, -1.15 * distance_), 0.7071, sr);
        reflectBack_ = static_cast<size_t>((0.0003 + 0.0027 * distance_) * sr) + 1;
        reflectGain_ = 0.35 * distance_;
        outRamp_.set(lib::dbToGain(param(kKOutput, at)), kControlFrames);
        mixRamp_.set(std::clamp(param(kKMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        // The response, direct: both sides' last `taps` inputs interleaved (L, R, L, R...) in a doubled ring, so the
        // window is one contiguous run of floats, dotted with the response interleaved alike; eight partial sums,
        // the even ones the left side's, the odd the right's (a fixed order: the same bits at any block size).
        const uint32_t taps = ir_->taps, span = 2 * taps;
        const float* h = ir_->interleaved;
        double fir[2][kControlFrames];
        uint32_t p = pos_;
        for (uint32_t i = 0; i < n; ++i) {
            const float l = std::isfinite(inL[i]) ? inL[i] : 0.0f, r = std::isfinite(inR[i]) ? inR[i] : 0.0f;
            ring_[2 * p] = ring_[2 * p + span] = l;
            ring_[2 * p + 1] = ring_[2 * p + 1 + span] = r;
            p = p + 1 == taps ? 0 : p + 1;
            const float* w = ring_ + 2 * p;  // oldest .. newest
            float acc[8];
            dot8(h, w, span, acc);
            fir[0][i] = (acc[0] + acc[2]) + (acc[4] + acc[6]);
            fir[1][i] = (acc[1] + acc[3]) + (acc[5] + acc[7]);
        }
        pos_ = p;
        // The cabinet's lows and the mic, both sides as one two-wide vector.
        for (uint32_t i = 0; i < n; ++i) {
            Pair y = pairOf(fir[0][i], fir[1][i]);
            y = res_.process(high_.high(y));
            y = air_.low(prox_.process(bell_.process(shelf_.process(y))));
            const Pair late = pairOf(reflect_[0].at(reflectBack_), reflect_[1].at(reflectBack_));
            reflect_[0].write(lane(y, 0));
            reflect_[1].write(lane(y, 1));
            y = y + late * splat(reflectGain_);
            const double o = outRamp_.next(), m = mixRamp_.next();
            outL[i] = static_cast<float>(inL[i] + (lane(y, 0) * o - inL[i]) * m);
            outR[i] = static_cast<float>(inR[i] + (lane(y, 1) * o - inR[i]) * m);
        }
        high_.flush(), res_.flush(), shelf_.flush(), bell_.flush(), prox_.flush(), air_.flush();
    }
    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(cab_);
        out[3] = static_cast<float>(position_);
        out[4] = static_cast<float>(distance_);
        out[5] = static_cast<float>(ir_ ? ir_->taps : 0);
        out[6] = static_cast<float>(ir_ ? ir_->taps / rate() * 1000.0 : 0.0);  // the response's length ms
        out[7] = static_cast<float>(kEnvPoints);
        // The response itself, 64 points (its taps averaged in groups), only when a UI reads it.
        for (uint32_t k = 0; k < kEnvPoints; ++k) {
            float v = 0.0f;
            if (watched && ir_) {
                const uint32_t per = ir_->taps / kEnvPoints;
                for (uint32_t j = 0; j < per; ++j) v += ir_->reversed[ir_->taps - 1 - (k * per + j)];
                v /= static_cast<float>(per);
            }
            out[8 + k] = v;
        }
        return 8 + kEnvPoints;
    }

private:
    static constexpr uint32_t kEnvPoints = 64;
    const ModuleDescriptor& d_;
    const CabIr* ir_ = nullptr;
    std::unique_ptr<CabIr[]> own_;
    bool shared_ = true;
    alignas(16) float ring_[4 * kMaxTaps] = {};  // both sides interleaved, doubled
    uint32_t pos_ = 0;
    modes::Line reflect_[2];
    modes::PairSvf high_, air_;
    modes::PairEq res_, shelf_, bell_, prox_;
    Ramp outRamp_, mixRamp_;
    int cab_ = -1;
    double position_ = 0.3, distance_ = 0.2, reflectGain_ = 0;
    size_t reflectBack_ = 1;
    std::vector<uint8_t> kept_;
};

using V = std::vector<std::pair<std::string_view, double>>;
BuiltinPreset preset(const char* name, const char* description, V values) {
    values.emplace_back("variant", 1.0);
    return {name, description, std::move(values)};
}

const std::vector<BuiltinPreset>& presets() {
    static const std::vector<BuiltinPreset> p = {
        preset("Rock 4x12 close", "Guitar: a thick closed 4x12, the mic near the cone's centre", {{"cab", 2}, {"position", 0.2}, {"distance", 0.1}}),
        preset("Rock 4x12 edge", "Guitar: the same cabinet, darker at the cone's edge", {{"cab", 2}, {"position", 0.8}, {"distance", 0.2}}),
        preset("Open back clean", "Guitar: an airy open-back 1x12 for clean tones", {{"cab", 0}, {"position", 0.35}, {"distance", 0.35}}),
        preset("2x12 lead", "Guitar: a focused closed 2x12 for leads", {{"cab", 1}, {"position", 0.3}, {"distance", 0.15}}),
        preset("Small practice amp", "Lo-fi: a boxy little 1x10", {{"cab", 3}, {"position", 0.5}, {"distance", 0.3}}),
        preset("Bass 4x10", "Bass: a punchy 4x10 with its tweeter's edge", {{"cab", 4}, {"position", 0.3}, {"distance", 0.2}}),
        preset("Bass 1x15 deep", "Bass: a warm, deep 1x15", {{"cab", 5}, {"position", 0.5}, {"distance", 0.15}}),
        preset("Room mic 4x12", "Mixing: the 4x12 heard from across the room", {{"cab", 2}, {"position", 0.5}, {"distance", 1.0}}),
        preset("Vocal through a cab", "Vocals: a voice re-amped through a small cabinet", {{"cab", 3}, {"position", 0.2}, {"distance", 0.4}, {"mix", 0.7}}),
        preset("Drum cab smash", "Drums: a kit through a 2x12, blended", {{"cab", 1}, {"position", 0.4}, {"distance", 0.5}, {"mix", 0.4}}),
    };
    return p;
}

}  // namespace

const ModuleDescriptor& convolverDescriptor();  // builtin_fx_space_reverb.cpp: the Convolver's own (its state limit)

const ModuleDescriptor& cabDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = [&]() -> const ModuleDescriptor& {
        sharedIrs();  // the responses, rendered once, at registration
        static ModuleDescriptor base = withCpu(effectDescriptor(kConvId, kConvName, cabParams(), 0, 1024), CpuClass::Medium);
        base.maxStateBytes = convolverDescriptor().maxStateBytes;  // a user's IR is kept across the variant
        return legacyVariantDescriptor(base, kConvId, kConvName, labels, index);
    }();
    return d;
}
ModuleProcessor* makeCabAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) Cab(v); }
std::span<const BuiltinPreset> cabPresets() { return presets(); }

}  // namespace caw::fx
