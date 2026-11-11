// The stutter (fx-creative): "org.caw.stutter", a beat repeat: by chance (seeded) on the song's grid, a slice is caught and repeated, each repeat quieter and re-pitched.
#include <cmath>

#include "builtin_fx_creative.h"

// Original code (C.A.W. is Apache-2.0). A beat repeat: at each interval of the song's grid a seeded roll decides
// whether to repeat; if so the first `division` of audio plays through and is recorded, then repeats until
// `length` is over, repeat n read from the slice at a rate 2^(n x pitch / 12) (a resampled read, cubic between
// samples) and (1 - decay)^n as loud, gated to a share of the slice with 1.5 ms fades at its edges. The roll for
// interval i is a hash of (seed, i), so a song plays the same repeats every time, wherever playback starts.

namespace caw::fx {

namespace {

using creative::clampTo;

enum StutterParam : uint32_t {
    kInterval, kOffset, kDivision, kLength, kChance, kSeed, kDecayS, kPitch, kGate, kHold, kMixS, kStutterCount
};
constexpr std::string_view kIntervals[] = {"1/4", "1/2", "1 bar", "2 bars", "4 bars"};
constexpr double kIntervalBeats[] = {1, 2, 4, 8, 16};
constexpr std::string_view kDivisions[] = {"1/64", "1/32", "1/16 T", "1/16", "1/8 T", "1/8", "1/4", "1/2"};
constexpr double kDivisionBeats[] = {0.0625, 0.125, 0.25 * 2 / 3, 0.25, 0.5 * 2 / 3, 0.5, 1, 2};
constexpr std::string_view kLengths[] = {"1/16", "1/8", "1/4", "1/2", "1 bar", "2 bars"};
constexpr double kLengthBeats[] = {0.25, 0.5, 1, 2, 4, 8};
constexpr double kMaxSlice = 3.0;  // seconds: a half note at 40 BPM
constexpr double kEdge = 0.0015;   // seconds of fade at each repeat's edges and back to the dry sound

const ParamTable& stutterParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("interval", "Interval", 2.0, kIntervals);
        p.num("offset", "Offset", 12.0, 0.0, 15.0).step = 1.0;  // 16ths into the interval where a repeat may start
        p.pick("division", "Division", 3.0, kDivisions);
        p.pick("length", "Length", 2.0, kLengths);
        p.num("chance", "Chance", 0.5, 0.0, 1.0);
        ParameterDescriptor& seed = p.num("seed", "Seed", 1.0, 0.0, 9999.0);
        seed.step = 1.0;
        seed.smoothingFrames = 0;
        p.num("decay", "Decay", 0.15, 0.0, 1.0);
        p.num("pitch", "Pitch per repeat", 0.0, -12.0, 12.0, "st");
        p.num("gate", "Gate", 1.0, 0.1, 1.0);
        p.num("hold", "Hold", 0.0, 0.0, 1.0).smoothingFrames = 0;  // at or above 0.5: repeat now, for as long as held
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

const ModuleDescriptor& stutterDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.stutter", "Stutter", stutterParams(), 0, 0);
    return d;
}

class Stutter final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return stutterDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        const size_t n = static_cast<size_t>(std::ceil(kMaxSlice * sr)) + 4;
        try {
            sliceL_.assign(n, 0.0f);
            sliceR_.assign(n, 0.0f);
        } catch (const std::bad_alloc&) {
            return false;
        }
        edge_ = std::max(1.0, std::floor(kEdge * sr));
        return true;
    }
    void clearState() noexcept override {
        clock_.reset();
        lastInterval_ = INT64_MIN;
        active_ = held_ = false;
        elapsed_ = 0.0, wet_ = 0.0;
        repeat_ = 0;
        triggers_ = 0;
        mix_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const double beatFrames = 60.0 / tempo() * sr;
        interval_ = kIntervalBeats[std::clamp(choice(kInterval, at), 0, 4)];
        offset_ = std::fmod(clampTo(std::floor(param(kOffset, at) + 0.5), 0.0, 15.0) * 0.25, interval_);
        sliceWant_ = std::floor(clampTo(kDivisionBeats[std::clamp(choice(kDivision, at), 0, 7)] * beatFrames, 16.0,
                                        kMaxSlice * sr));
        lengthWant_ = std::floor(kLengthBeats[std::clamp(choice(kLength, at), 0, 5)] * beatFrames);
        chance_ = clampTo(param(kChance, at), 0.0, 1.0);
        seed_ = static_cast<uint32_t>(clampTo(std::floor(param(kSeed, at) + 0.5), 0.0, 9999.0));
        keep_ = 1.0 - clampTo(param(kDecayS, at), 0.0, 1.0);
        pitch_ = clampTo(param(kPitch, at), -12.0, 12.0);
        gate_ = clampTo(param(kGate, at), 0.1, 1.0);
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        clock_.control(playing, beat, 1.0, tempo(), sr);
        const bool hold = param(kHold, at) >= 0.5;
        if (hold && !held_) start(true);
        if (!hold && held_) active_ = false;  // let go: back to the dry sound (over the edge fade)
        held_ = hold;
        mix_.set(clampTo(param(kMixS, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double dl = inL[i], dr = inR[i];
            // The grid: interval i starts `offset` beats into it.
            const double at = clock_.pos - offset_;
            clock_.advance();
            const auto interval = static_cast<int64_t>(std::floor(at / interval_));
            if (interval != lastInterval_ && at >= 0.0) {
                lastInterval_ = interval;
                if (!held_ && creative::chanceOf(seed_, static_cast<uint64_t>(interval)) < chance_) start(false);
            }
            double wl = dl, wr = dr;
            if (active_) {
                const auto r = static_cast<int>(elapsed_ / slice_);
                const double t = elapsed_ - r * slice_;
                if (r != repeat_) {
                    repeat_ = r;
                    ratio_ = lib::fastExp(clampTo(r * pitch_, -48.0, 48.0) * 0.057762265046662105);  // ln 2 / 12
                    gain_ = gain_ * keep_;
                }
                // How long this repeat sounds: `gate` of the slice, read at `ratio_`.
                const double audible = std::min(slice_, gate_ * slice_ / ratio_);
                double w = t < audible ? std::min(1.0, (audible - t) / edge_) : 0.0;
                if (r == 0) {
                    const auto k = static_cast<size_t>(t);
                    sliceL_[k] = static_cast<float>(dl);
                    sliceR_[k] = static_cast<float>(dr);
                } else {
                    w = std::min(w, t / edge_);
                    const double p = t * ratio_;
                    wl = read(sliceL_, p);
                    wr = read(sliceR_, p);
                }
                wl *= w * gain_;
                wr *= w * gain_;
                elapsed_ += 1.0;
                if (!held_ && elapsed_ >= length_) active_ = false;
                last_[0] = wl, last_[1] = wr;
            }
            // In and out of a repeat: the first slice plays the input itself, so going in needs no fade; going
            // out crossfades from the last repeat back to the input over the edge time.
            wet_ = active_ ? 1.0 : std::max(0.0, wet_ - 1.0 / edge_);
            if (!active_ && wet_ > 0.0) wl = last_[0], wr = last_[1];
            const double m = mix_.next() * wet_;
            outL[i] = static_cast<float>(dl + (wl - dl) * m);
            outR[i] = static_cast<float>(dr + (wr - dr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = active_ ? 1.0f : 0.0f;
        out[3] = static_cast<float>(active_ ? repeat_ : 0);
        out[4] = static_cast<float>(active_ && !held_ ? clampTo(elapsed_ / std::max(1.0, length_), 0.0, 1.0) : 0.0);
        out[5] = static_cast<float>(sliceWant_ / rate() * 1000.0);
        out[6] = static_cast<float>(triggers_);
        out[7] = static_cast<float>(lengthWant_ / rate() * 1000.0);
        return 8;
    }

private:
    void start(bool hold) noexcept {
        active_ = true;
        elapsed_ = 0.0;
        repeat_ = 0;
        ratio_ = 1.0;
        gain_ = 1.0;
        slice_ = sliceWant_;
        length_ = hold ? 1e300 : std::max(slice_, lengthWant_);
        ++triggers_;
    }
    // The slice at position p (frames), cubic, held at its ends.
    double read(const std::vector<float>& x, double p) const noexcept {
        const double last = slice_ - 1.0;
        p = clampTo(p, 0.0, last);
        const auto k = static_cast<int64_t>(p);
        const double t = p - static_cast<double>(k);
        const auto at = [&](int64_t j) { return x[static_cast<size_t>(std::clamp<int64_t>(j, 0, static_cast<int64_t>(last)))]; };
        return creative::hermite(at(k - 1), at(k), at(k + 1), at(k + 2), t);
    }

    std::vector<float> sliceL_, sliceR_;
    creative::StepClock clock_;
    Ramp mix_;
    int64_t lastInterval_ = INT64_MIN;
    bool active_ = false, held_ = false;
    int repeat_ = 0;
    uint32_t seed_ = 1, triggers_ = 0;
    double elapsed_ = 0.0, slice_ = 12000.0, length_ = 24000.0, ratio_ = 1.0, gain_ = 1.0, wet_ = 0.0, edge_ = 72.0;
    double sliceWant_ = 6000.0, lengthWant_ = 24000.0, interval_ = 4.0, offset_ = 3.0, chance_ = 0.5, keep_ = 0.85;
    double pitch_ = 0.0, gate_ = 1.0, last_[2] = {0.0, 0.0};
};

}  // namespace

void registerStutter(ModuleRegistry& registry) { registry.add(stutterDescriptor(), &creative::make<Stutter>); }

}  // namespace caw::fx
