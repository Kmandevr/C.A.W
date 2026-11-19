// Duck's new variants (1.1.0): Level (a slow rider toward a target loudness) and Carve (the key's spectrum dips the same bands here).
#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "builtin_effects.h"
#include "component_chain.h"
#include "fx_bandbank.h"
#include "fx_merged.h"

// Original code (C.A.W. is Apache-2.0).
// Level: the input's momentary loudness (BS.1770's K-weighting, its two filters designed at the rate from the
//   standard's analogue parameters, then the mean square of both sides over the last 400 ms, kept as 16-frame block
//   sums) is compared with Target every 16 frames. The gain moves toward Target - loudness, held within Max boost and
//   Max cut, with the Speed time constant; below Gate it holds still, so pauses and silence are not pulled up.
//   Optional look-ahead (50/100/200 ms, reported as latency) delays the audio so the gain moves ahead of a phrase.
// Carve: the key's spectrum in 16 (or 24) log-spaced bands, 40 Hz to 16 kHz (fx_bandbank.h: 4th-order band-passes
//   and followers with Attack and Release), sets a cascade of bell filters on the same centres here: each band dips
//   by Range x Amount x how far the key's band is above Threshold (full at 30 dB above; 0.05 dB steps), only inside the frequency
//   window (Low to High, half-octave edges). The bells overlap, so a key spanning neighbouring bands would add their
//   dips together: each band's summed dip (every bell's response at its centre) is held to Range. Linked dips both sides by the key's mid, Stereo each side by its own,
//   Mid/Side the mid and side by the key's. Listen plays what is dipped out. No latency.

namespace caw::fx {

namespace {

// ---------- Level ----------

enum LevelParam : uint32_t { kLTarget, kLBoost, kLCut, kLSpeed, kLGate, kLLookahead, kLOutput, kLCount };
constexpr std::string_view kLookaheads[] = {"Off", "50 ms", "100 ms", "200 ms"};
constexpr double kLookaheadSeconds[] = {0.0, 0.05, 0.1, 0.2};

const ParamTable& levelParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("target", "Target", -18.0, -40.0, 0.0, "LUFS");
        p.num("max_boost", "Max boost", 6.0, 0.0, 24.0, "dB");
        p.num("max_cut", "Max cut", 12.0, 0.0, 24.0, "dB");
        p.expo("speed", "Speed", 1.0, 0.1, 10.0, "s");
        p.num("gate", "Gate", -50.0, -80.0, -20.0, "LUFS");
        ParameterDescriptor& look = p.pick("lookahead", "Look-ahead", 0.0, kLookaheads);
        look.automatable = look.modulatable = false;  // sets the reported latency
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}

uint32_t levelLookahead(double choice, double sr) noexcept {
    const int k = std::isfinite(choice) ? std::clamp(static_cast<int>(choice + 0.5), 0, 3) : 0;
    return static_cast<uint32_t>(kLookaheadSeconds[k] * sr + 0.5);
}

// A biquad (transposed direct form II), double.
struct Biquad {
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    double run(double x) noexcept {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }
    void clear() noexcept { z1 = z2 = 0; }
    void flush() noexcept {  // no subnormal state
        if (z1 < 1e-30 && z1 > -1e-30) z1 = 0;
        if (z2 < 1e-30 && z2 > -1e-30) z2 = 0;
    }
};

}  // namespace

// BS.1770's K-weighting at `sr`: the high shelf (about +4 dB above 1.5 kHz) and the high-pass (about 38 Hz), from the
// standard's analogue prototype (the widely published parameters; at 48 kHz they give the standard's tabled
// coefficients, which the tests check).
void kWeighting(double sr, double shelf[5], double hp[5]) noexcept {
    const double pi = 3.14159265358979323846;
    {
        const double f0 = 1681.974450955533, g = 3.999843853973347, q = 0.7071752369554196;
        const double k = std::tan(pi * f0 / sr), vh = std::pow(10.0, g / 20.0), vb = std::pow(vh, 0.4996667741545416);
        const double a0 = 1.0 + k / q + k * k;
        shelf[0] = (vh + vb * k / q + k * k) / a0;
        shelf[1] = 2.0 * (k * k - vh) / a0;
        shelf[2] = (vh - vb * k / q + k * k) / a0;
        shelf[3] = 2.0 * (k * k - 1.0) / a0;
        shelf[4] = (1.0 - k / q + k * k) / a0;
    }
    {
        const double f0 = 38.13547087602444, q = 0.5003270373238773;
        const double k = std::tan(pi * f0 / sr), a0 = 1.0 + k / q + k * k;
        hp[0] = 1.0, hp[1] = -2.0, hp[2] = 1.0;
        hp[3] = 2.0 * (k * k - 1.0) / a0;
        hp[4] = (1.0 - k / q + k * k) / a0;
    }
}

namespace {

class DuckLevel final : public EffectBase, public VariableLatency {
public:
    explicit DuckLevel(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double* values, uint32_t count) const noexcept override {
        return count > kLLookahead ? levelLookahead(values[kLLookahead], rate()) : 0;
    }
    // Asleep only once the look-ahead line has emptied too.
    uint64_t idleFrames() const noexcept override { return look_ + static_cast<uint64_t>(0.05 * rate()); }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        double s[5], h[5];
        kWeighting(sampleRate, s, h);
        for (auto& f : shelf_) f.b0 = s[0], f.b1 = s[1], f.b2 = s[2], f.a1 = s[3], f.a2 = s[4];
        for (auto& f : hp_) f.b0 = h[0], f.b1 = h[1], f.b2 = h[2], f.a1 = h[3], f.a2 = h[4];
        window_ = std::max<uint32_t>(1, static_cast<uint32_t>(0.4 * sampleRate / kControlFrames + 0.5));
        try {
            blocks_.assign(window_, 0.0);
            const uint32_t size = levelLookahead(3, sampleRate) + kControlFrames + 1;  // 200 ms and a grid step
            for (auto& d : delay_) d.assign(size, 0.0f);
        } catch (...) {
            return false;
        }
        stepCoefRate_ = sampleRate / kControlFrames;
        return true;
    }
    void clearState() noexcept override {
        for (auto& f : shelf_) f.clear();
        for (auto& f : hp_) f.clear();
        std::fill(blocks_.begin(), blocks_.end(), 0.0);
        for (auto& d : delay_) std::fill(d.begin(), d.end(), 0.0f);
        sum_ = acc_ = 0.0;
        accFrames_ = 0;
        at_ = 0;
        pos_ = 0;
        gainDb_ = 0.0;
        gainFor_ = 1e300;
        loudness_ = -120.0;
        ramp_.reset();
    }
    void control(uint32_t at) noexcept override {
        target_ = param(kLTarget, at);
        boost_ = std::max(0.0, param(kLBoost, at));
        cut_ = std::max(0.0, param(kLCut, at));
        const double speed = param(kLSpeed, at);
        if (speed != speedFor_) speedFor_ = speed, speedCoef_ = lib::timeCoefficient(speed, stepCoefRate_);
        gate_ = param(kLGate, at);
        look_ = levelLookahead(param(kLLookahead, at), rate());
        // The momentary loudness of the last 400 ms (the block sums so far), and the gain's step toward the target.
        const double ms = sum_ / (static_cast<double>(window_) * kControlFrames);
        loudness_ = ms > 1e-12 ? -0.691 + 10.0 * std::log10(ms) : -120.0;
        if (loudness_ >= gate_) {
            const double want = std::clamp(target_ - loudness_, -cut_, boost_);
            gainDb_ = want + (gainDb_ - want) * speedCoef_;
        }
        const double o = param(kLOutput, at);
        const double db = gainDb_ + o;
        if (db != gainFor_) gainFor_ = db, gainOf_ = lib::dbToGain(db);
        ramp_.set(gainOf_, kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const uint32_t size = static_cast<uint32_t>(delay_[0].size());
        float* dl = delay_[0].data();
        float* dr = delay_[1].data();
        double acc = 0.0;
        for (uint32_t i = 0, w = pos_; i < n; ++i, w = w + 1 == size ? 0 : w + 1) {
            const double l = hp_[0].run(shelf_[0].run(caw::finiteOr0(inL[i]))), r = hp_[1].run(shelf_[1].run(caw::finiteOr0(inR[i])));
            acc += l * l + r * r;
            dl[w] = inL[i];
            dr[w] = inR[i];
        }
        uint32_t a = pos_ >= look_ ? pos_ - look_ : pos_ + size - look_;
        for (uint32_t i = 0; i < n; ++i, a = a + 1 == size ? 0 : a + 1) {
            const double g = ramp_.next();
            outL[i] = static_cast<float>(dl[a] * g);
            outR[i] = static_cast<float>(dr[a] * g);
        }
        pos_ = (pos_ + n) % size;
        for (Biquad* f : {&shelf_[0], &shelf_[1], &hp_[0], &hp_[1]}) f->flush();
        acc_ += acc;
        accFrames_ += n;
        if (accFrames_ >= kControlFrames) {  // a whole grid step: into the 400 ms window
            sum_ += acc_ - blocks_[at_];
            if (sum_ < 0.0) sum_ = 0.0;
            blocks_[at_] = acc_;
            at_ = at_ + 1 == window_ ? 0 : at_ + 1;
            acc_ = 0.0;
            accFrames_ = 0;
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(loudness_);  // momentary loudness, LUFS
        out[3] = static_cast<float>(target_);
        out[4] = static_cast<float>(gainDb_);    // the ride now, dB (positive: boost)
        out[5] = static_cast<float>(boost_);
        out[6] = static_cast<float>(-cut_);
        out[7] = static_cast<float>(gate_);
        out[8] = loudness_ >= gate_ ? 1.0f : 0.0f;  // riding (0: held under the gate)
        out[9] = static_cast<float>(look_ * 1000.0 / rate());
        return 10;
    }

private:
    const ModuleDescriptor& d_;
    Biquad shelf_[2], hp_[2];
    std::vector<double> blocks_;
    std::vector<float> delay_[2];
    uint32_t window_ = 1, at_ = 0, pos_ = 0, look_ = 0, accFrames_ = 0;
    double sum_ = 0, acc_ = 0, stepCoefRate_ = 3000;
    double target_ = -18, boost_ = 6, cut_ = 12, gate_ = -50, speedFor_ = -1, speedCoef_ = 0;
    double gainDb_ = 0, gainFor_ = 1e300, gainOf_ = 1, loudness_ = -120;
    Ramp ramp_;
};

// ---------- Carve ----------

enum CarveParam : uint32_t {
    kCAmount, kCRange, kCThreshold, kCLow, kCHigh, kCAttack, kCRelease, kCBands, kCStereo, kCListen, kCOutput, kCCount
};
constexpr std::string_view kBandCounts[] = {"16", "24 (High)"};
constexpr std::string_view kStereoModes[] = {"Linked", "Stereo", "Mid/Side"};
constexpr uint32_t kMaxBands = 24;
constexpr double kLowest = 40.0, kHighest = 16000.0;
constexpr double kAnalysisQ = 3.0, kBellQ = 2.5;

const ParamTable& carveParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("amount", "Amount", 0.6, 0.0, 1.0);
        p.num("range", "Range", 9.0, 0.0, 24.0, "dB");
        p.num("threshold", "Threshold", -50.0, -80.0, -10.0, "dB");
        p.expo("low", "Low", 100.0, 20.0, 20000.0, "Hz");
        p.expo("high", "High", 8000.0, 20.0, 20000.0, "Hz");
        p.expo("attack", "Attack", 10.0, 0.5, 200.0, "ms");
        p.expo("release", "Release", 120.0, 10.0, 2000.0, "ms");
        p.pick("bands", "Bands", 0.0, kBandCounts);
        p.pick("stereo", "Stereo", 0.0, kStereoModes);
        p.pick("listen", "Listen", 0.0, kOffOn);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        return p;
    }();
    return t;
}

class DuckCarve final : public EffectBase {
public:
    explicit DuckCarve(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sampleRate, uint32_t) noexcept override {
        count_ = 0;  // set up on the first control()
        sr_ = sampleRate;
        return true;
    }
    void clearState() noexcept override {
        an_.clear();
        bells_.clear();
        out_.reset();
        for (auto& s : dip_) std::fill(std::begin(s), std::end(s), 0.0f);
        keyMax_ = 0.0;
    }
    void control(uint32_t at) noexcept override {
        const uint32_t count = choice(kCBands, at) == 1 ? 24u : 16u;
        if (count != count_) {
            count_ = count;
            an_.setup(count, kLowest, kHighest, kAnalysisQ, sr_);
            bells_.setup(count, kLowest, kHighest, kBellQ, sr_);
            an_.clear();
            bells_.clear();
            for (uint32_t b = 0; b < count; ++b) {
                const double fc = bands::centre(b, count, kLowest, kHighest);
                logCentre_[b] = std::log2(fc);
            }
            setupCoupling();
        }
        const double a = param(kCAttack, at) * 0.001, r = param(kCRelease, at) * 0.001;
        if (a != attackFor_ || r != releaseFor_) attackFor_ = a, releaseFor_ = r, an_.setTimes(a, r, sr_);
        const double amount = std::clamp(param(kCAmount, at), 0.0, 1.0), range = std::clamp(param(kCRange, at), 0.0, 24.0);
        const double thr = param(kCThreshold, at);
        const double lo = std::log2(std::max(20.0, param(kCLow, at))), hi = std::log2(std::max(20.0, param(kCHigh, at)));
        mode_ = std::clamp(choice(kCStereo, at), 0, 2);
        listen_ = on(kCListen, at);
        const int sides = mode_ == 0 ? 1 : 2;
        // Only the bands inside the window are measured (with half an octave either side for the edges).
        uint32_t first = count_, last = 0;
        for (uint32_t b = 0; b < count_; ++b)
            if (logCentre_[b] > lo - 0.5 && logCentre_[b] < hi + 0.5) first = std::min(first, b), last = b + 1;
        an_.setActive(first, last);
        const double scale = range * amount / 30.0;
        double want[2][kMaxBands];
        for (uint32_t b = 0; b < count_; ++b) {
            // The window, with half-octave edges.
            const double w = std::clamp((logCentre_[b] - lo) * 2.0 + 1.0, 0.0, 1.0) * std::clamp((hi - logCentre_[b]) * 2.0 + 1.0, 0.0, 1.0);
            for (int s = 0; s < sides; ++s) {
                double d = 0.0;
                if (w > 0.0 && scale > 0.0) {
                    const double over = lib::gainToDb(an_.env(s, b), -200.0) - thr;  // the key's band above Threshold
                    d = over <= 0.0 ? 0.0 : -scale * std::min(over, 30.0) * w;
                }
                want[s][b] = d;
            }
        }
        for (int s = 0; s < sides; ++s) holdToRange(want[s], range);
        for (uint32_t b = 0; b < count_; ++b) {
            double db[2] = {0.0, 0.0};
            for (int s = 0; s < sides; ++s) {
                const double d = want[s][b];
                db[s] = d > -0.05 ? 0.0 : std::floor(d * 20.0 + 0.5) * 0.05;  // 0.05 dB steps: few coefficient updates
            }
            if (sides == 1) db[1] = db[0];
            for (int s = 0; s < 2; ++s) dip_[s][b] = static_cast<float>(db[s]);
            bells_.setGain(0, b, db[0]);
            if (sides == 1) bells_.copyGain(1, 0, b);
            else bells_.setGain(1, b, db[1]);
        }
        const double o = param(kCOutput, at);
        if (o != outDb_) outDb_ = o, outGain_ = lib::dbToGain(o);
        out_.set(outGain_, kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const float* kl = keyLeft();
        const float* kr = keyRight();
        // The key's bands (no key: silence, so nothing dips).
        for (uint32_t i = 0; i < n; ++i) {
            const float l = kl ? static_cast<float>(caw::finiteOr0(kl[i])) : 0.0f, r = kr ? static_cast<float>(caw::finiteOr0(kr[i])) : 0.0f;  // a NaN never sticks
            const float m = std::max(l < 0 ? -l : l, r < 0 ? -r : r);
            keyMax_ = m > keyMax_ ? m : keyMax_;
            if (mode_ == 0) an_.side(0, 0.5f * (l + r));
            else if (mode_ == 1) an_.process(l, r);
            else an_.process(0.5f * (l + r), 0.5f * (l - r));
        }
        float a[kControlFrames], b[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            const float l = static_cast<float>(caw::finiteOr0(inL[i])), r = static_cast<float>(caw::finiteOr0(inR[i]));
            if (mode_ == 2) a[i] = 0.5f * (l + r), b[i] = 0.5f * (l - r);
            else a[i] = l, b[i] = r;
        }
        bells_.run(a, b, n);
        for (uint32_t i = 0; i < n; ++i) {
            float l = a[i], r = b[i];
            if (mode_ == 2) l = a[i] + b[i], r = a[i] - b[i];
            if (listen_) l = inL[i] - l, r = inR[i] - r;  // what the dips take out
            const float o = static_cast<float>(out_.next());
            outL[i] = l * o;
            outR[i] = r * o;
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        // [0] in peak, [1] out peak, [2] the key's peak, [3] band count, [4] the stereo mode, then each band's
        // centre (Hz) and its dip on side 0 and side 1 (dB, 0 or less): 5 + 3 x count floats.
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(lib::gainToDb(keyMax_));
        out[3] = static_cast<float>(count_);
        out[4] = static_cast<float>(mode_);
        for (uint32_t b = 0; b < count_; ++b) {
            out[5 + 3 * b] = static_cast<float>(bands::centre(b, count_, kLowest, kHighest));
            out[6 + 3 * b] = dip_[0][b];
            out[7 + 3 * b] = dip_[1][b];
        }
        keyMax_ = 0.0;
        return 5 + 3 * count_;
    }

private:
    // The bells' coupling: bell j's dB response at band i's centre per dB of its own dip, worked out exactly (the
    // SVF bell is the bilinear image of the analogue one, so at the warped frequency its response is the analogue
    // H(jW) = 1 + (A^2 - 1) k jW / (1 - W^2 + jkW)) at dips of kRefDb, between which control() interpolates.
    static constexpr int kRefs = 4;
    static constexpr double kRefDb[kRefs] = {3.0, 6.0, 12.0, 24.0};
    void setupCoupling() noexcept {
        const double top = 0.49 * sr_;
        double warped[kMaxBands];
        for (uint32_t b = 0; b < count_; ++b) {
            const double fc = bands::centre(b, count_, kLowest, kHighest);
            warped[b] = std::tan(bands::kPi * (fc > top ? top : fc) / sr_);
        }
        for (int r = 0; r < kRefs; ++r) {
            const double a = lib::dbToGain(-0.5 * kRefDb[r]), k = 1.0 / (kBellQ * a), m = (a * a - 1.0) * k;
            for (uint32_t j = 0; j < kMaxBands; ++j)
                for (uint32_t i = 0; i < kMaxBands; ++i) {
                    if (i >= count_ || j >= count_) {  // past the count: 0, so the sums run the full width
                        coupling_[r][j][i] = 0.0f;
                        continue;
                    }
                    const double w = warped[i] / warped[j];
                    // H = 1 + m jw / ((1 - w^2) + jkw) = ((1 - w^2) + j(k + m)w) / ((1 - w^2) + jkw)
                    const double re = 1.0 - w * w, num = re * re + (k + m) * (k + m) * w * w, den = re * re + k * k * w * w;
                    coupling_[r][j][i] = static_cast<float>(-10.0 * std::log10(num / den) / kRefDb[r]);
                }
        }
    }
    // Scales the wanted dips (dB, 0 or less) down so that no band's summed dip passes Range: each pass works out
    // every band's sum, and a band over Range scales itself and its two neighbours on each side (their bells carry
    // most of what it hears) by Range over its sum; a few passes settle what the far bells add.
    void holdToRange(double* d, double range) const noexcept {
        for (int pass = 0; pass < 4; ++pass) {
            float sum[kMaxBands] = {};
            bool any = false;
            for (uint32_t j = 0; j < count_; ++j) {
                const double x = -d[j];
                if (x <= 0.0) continue;
                any = true;
                int r = 0;
                while (r < kRefs - 2 && x > kRefDb[r + 1]) ++r;
                const double t = std::clamp((x - kRefDb[r]) / (kRefDb[r + 1] - kRefDb[r]), 0.0, 1.0);
                const float* c0 = coupling_[r][j];
                const float* c1 = coupling_[r + 1][j];
                const float w0 = static_cast<float>((1.0 - t) * d[j]), w1 = static_cast<float>(t * d[j]);
                for (uint32_t i = 0; i < kMaxBands; ++i) sum[i] += c0[i] * w0 + c1[i] * w1;  // the rows' tails are 0
            }
            if (!any) return;
            double f[kMaxBands];
            bool over = false;
            for (uint32_t i = 0; i < count_; ++i) {
                f[i] = sum[i] < -range ? -range / sum[i] : 1.0;
                over = over || f[i] < 1.0;
            }
            if (!over) return;
            for (uint32_t j = 0; j < count_; ++j) {
                double m = 1.0;
                for (uint32_t i = j < 2 ? 0 : j - 2; i < count_ && i <= j + 2; ++i) m = f[i] < m ? f[i] : m;
                d[j] *= m;
            }
        }
    }

    const ModuleDescriptor& d_;
    bands::Analyzer<kMaxBands> an_;
    bands::BellCascade<kMaxBands> bells_;
    float coupling_[kRefs][kMaxBands][kMaxBands] = {};
    double logCentre_[kMaxBands] = {};
    float dip_[2][kMaxBands] = {};
    uint32_t count_ = 0;
    double sr_ = 48000, attackFor_ = -1, releaseFor_ = -1, outDb_ = 1e300, outGain_ = 1, keyMax_ = 0;
    Ramp out_;
    int mode_ = 0;
    bool listen_ = false;
};

const ModuleDescriptor& levelBase() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.duck", "Duck", levelParams(), 0, 0);
    return d;
}
const ModuleDescriptor& carveBase() {
    static const ModuleDescriptor d = keyedEffectDescriptor("org.caw.duck", "Duck", carveParams(), 0, 0, false);
    return d;
}

}  // namespace

const ModuleDescriptor& duckLevelBaseDescriptor() { return levelBase(); }
const ModuleDescriptor& duckCarveBaseDescriptor() { return carveBase(); }
ModuleProcessor* makeDuckLevelAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) DuckLevel(v); }
ModuleProcessor* makeDuckCarveAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) DuckCarve(v); }
size_t duckLevelBytes(double sr) noexcept {
    return sizeof(DuckLevel) + static_cast<size_t>(0.4 * sr / 16 + 1) * sizeof(double) +
           2 * sizeof(float) * (levelLookahead(3, sr) + 17);
}
size_t duckCarveBytes() noexcept { return sizeof(DuckCarve); }

}  // namespace caw::fx
