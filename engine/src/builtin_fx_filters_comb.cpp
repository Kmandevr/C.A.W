// The comb filter ("org.caw.comb") and the resonator bank ("org.caw.resonator") of the EQ & Filter group.
#include "builtin_fx_filters.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

// Original code (C.A.W. is Apache-2.0). The comb is the textbook feedback/feedforward comb (Smith, "Physical Audio
// Signal Processing", CCRMA, "Feedback Comb Filters"; Zölzer, "DAFX", ch. 3) on a 4-point Hermite fractional delay;
// the resonator is a modal bank (Smith, ibid., "Modal Synthesis"): two-pole resonances tuned and damped per mode.

namespace caw::fx {

namespace {

using filters::lane;
using filters::noteHz;
using filters::Pair;
using filters::pairOf;

// ---------- Comb ----------

enum CombParam : uint32_t {
    kCTune, kCFreq, kCNote, kCFine, kCFeedback, kCDamping, kCPolarity, kCStereo, kCSpread, kCMix, kCOutput, kCCount
};
constexpr std::string_view kTunes[] = {"Hz", "Note"};
constexpr std::string_view kPolarities[] = {"Plus", "Minus"};
constexpr std::string_view kCombStereo[] = {"Same", "Flip right"};

const ParamTable& combParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("tune", "Tune by", 0.0, kTunes);
        p.expo("freq", "Frequency", 220.0, 20.0, 5000.0, "Hz");
        p.num("note", "Note", 57.0, 12.0, 108.0).step = 1.0;
        p.num("fine", "Fine", 0.0, -100.0, 100.0, "ct");
        p.num("feedback", "Feedback", 0.6, -0.99, 0.99);
        p.num("damping", "Damping", 0.2, 0.0, 1.0);
        p.pick("polarity", "Polarity", 0.0, kPolarities);
        p.pick("stereo", "Stereo", 0.0, kCombStereo);
        p.num("spread", "Spread", 0.0, 0.0, 1.0);
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& combDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.comb", "Comb filter", combParams(), 0, kInfiniteTail);
    return d;
}

// A delay line read between samples by 4-point, 3rd-order Hermite interpolation (smoother than linear: the comb's
// high peaks keep their height as it is swept).
struct HermiteLine {
    std::vector<float> line;
    size_t pos = 0;
    void prepare(size_t n) { line.assign(n, 0.0f), pos = 0; }
    void clear() noexcept { std::fill(line.begin(), line.end(), 0.0f); }
    // `back` samples ago (3 .. size - 3; 1 is the newest written).
    double read(double back) const noexcept {
        const size_t n = line.size();
        const double at = static_cast<double>(pos) + static_cast<double>(n) - back;  // in n + 2 .. 2n
        const size_t whole = static_cast<size_t>(at);
        const double f = at - static_cast<double>(whole);
        auto s = [&](size_t i) { return static_cast<double>(line[i % n]); };
        const double ym = s(whole + n - 1), y0 = s(whole), y1 = s(whole + 1), y2 = s(whole + 2);
        const double c1 = 0.5 * (y1 - ym), c2 = ym - 2.5 * y0 + 2.0 * y1 - 0.5 * y2, c3 = 0.5 * (y2 - ym) + 1.5 * (y0 - y1);
        return ((c3 * f + c2) * f + c1) * f + y0;
    }
    void write(double v) noexcept {
        line[pos] = static_cast<float>(filters::guard(v, 1e4));
        if (line[pos] < 1e-20f && line[pos] > -1e-20f) line[pos] = 0.0f;
        pos = pos + 1 == line.size() ? 0 : pos + 1;
    }
};

class CombEffect final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return combDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        try {
            for (auto& l : line_) l.prepare(static_cast<size_t>(sr / 15.0) + 8);
        } catch (...) {
            return false;
        }
        glide_ = 1.0 - detExp(-1.0 / (0.02 * sr));  // the delay glides over ~20 ms: a retune sweeps, never clicks
        return true;
    }
    void clearState() noexcept override {
        for (int c = 0; c < 2; ++c) line_[c].clear(), lp_[c] = 0.0, delay_[c] = -1.0;
        mix_.reset(), fb_.reset(), norm_.reset(), out_.reset(), polR_.reset(), polL_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        hz_ = choice(kCTune, at) == 1 ? noteHz(std::clamp(param(kCNote, at), 12.0, 108.0), std::clamp(param(kCFine, at), -100.0, 100.0))
                                      : std::clamp(param(kCFreq, at), 20.0, 5000.0) * detPow(2.0, std::clamp(param(kCFine, at), -100.0, 100.0) / 1200.0);
        hz_ = std::clamp(hz_, 20.0, 0.45 * sr);
        const double fb = std::clamp(param(kCFeedback, at), -0.99, 0.99);
        damping_ = std::clamp(param(kCDamping, at), 0.0, 1.0);
        damp_ = 1.0 - 0.95 * damping_;  // the loop low-pass's coefficient (1: open)
        // The loop low-pass delays low frequencies by (1 - a) / a samples: taken off the line so the comb stays in tune.
        const double lag = (1.0 - damp_) / damp_;
        const double spread = std::clamp(param(kCSpread, at), 0.0, 1.0);
        target_[0] = std::max(3.0, sr / hz_ - lag);
        target_[1] = std::max(3.0, sr / (hz_ * detPow(2.0, spread * 30.0 / 1200.0)) - lag);  // up to 30 cents apart
        for (int c = 0; c < 2; ++c) target_[c] = std::min(target_[c], static_cast<double>(line_[c].line.size()) - 4.0);
        const double pol = choice(kCPolarity, at) == 1 ? -1.0 : 1.0;
        polL_.set(pol, kControlFrames);
        polR_.set(choice(kCStereo, at) == 1 ? -pol : pol, kControlFrames);
        fb_.set(fb, kControlFrames);
        // (x + d) / 2 peaks at (2 - |fb|) / (2 (1 - |fb|)): brought most of the way down, so high feedback rings
        // louder than a dry signal but stays in reach (about +4.5 dB at 0.9).
        const double a = std::fabs(fb), peak = 0.5 * (2.0 - a) / (1.0 - a);
        norm_.set(detPow(peak, -0.7), kControlFrames);
        out_.set(lib::dbToGain(std::clamp(param(kCOutput, at), -24.0, 24.0)), kControlFrames);
        mix_.set(std::clamp(param(kCMix, at), 0.0, 1.0), kControlFrames);
        feedback_ = fb;
        for (int c = 0; c < 2; ++c)  // a fresh start lands on the delay; subnormal tails flushed at the grid
            if (delay_[c] < 0.0) delay_[c] = target_[c];
            else if (lp_[c] < 1e-20 && lp_[c] > -1e-20) lp_[c] = 0.0;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double fb = fb_.next(), norm = norm_.next(), out = out_.next(), mix = mix_.next();
            const double pol[2] = {polL_.next(), polR_.next()};
            const double x[2] = {finiteOr0(inL[i]), finiteOr0(inR[i])};
            double y[2];
            for (int c = 0; c < 2; ++c) {
                delay_[c] += (target_[c] - delay_[c]) * glide_;
                const double d = line_[c].read(delay_[c]);
                lp_[c] += (d - lp_[c]) * damp_;
                line_[c].write(x[c] + fb * pol[c] * lp_[c]);  // polarity flips the loop too: peaks become troughs
                const double wet = 0.5 * (x[c] + pol[c] * d) * norm * out;
                y[c] = x[c] + (wet - x[c]) * mix;
            }
            outL[i] = static_cast<float>(y[0]);
            outR[i] = static_cast<float>(y[1]);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(hz_);
        out[3] = static_cast<float>(feedback_);
        out[4] = static_cast<float>(damping_);
        return 5;
    }

private:
    HermiteLine line_[2];
    double lp_[2] = {0, 0}, delay_[2] = {-1, -1}, target_[2] = {218, 218};
    double glide_ = 0.001, damp_ = 1.0, hz_ = 220.0, feedback_ = 0.6, damping_ = 0.2;
    Ramp mix_, fb_, norm_, out_, polL_, polR_;
};

ModuleProcessor* makeComb() noexcept { return new (std::nothrow) CombEffect(); }

// ---------- Resonator ----------

enum ResParam : uint32_t {
    kRMode, kRChord, kRScale, kRNote, kRFine, kRDecay, kRBright, kRSpread, kRMix, kROutput, kRCount
};
constexpr std::string_view kResModes[] = {"String", "Odd string", "Modal", "Chord", "Scale"};
enum ResMode : int { kString, kOdd, kModal, kChord, kScale };
constexpr std::string_view kChords[] = {"Major", "Minor", "Sus4", "Major 7", "Minor 7", "Power", "Octaves"};
constexpr int kChordNotes[7][4] = {{0, 4, 7, 12}, {0, 3, 7, 12}, {0, 5, 7, 12}, {0, 4, 7, 11},
                                   {0, 3, 7, 10}, {0, 7, 12, 19}, {0, 12, 24, 36}};
constexpr std::string_view kScales[] = {"Major", "Minor", "Major penta", "Minor penta", "Dorian", "Harmonic minor"};
constexpr int kScaleSteps[6][7] = {{0, 2, 4, 5, 7, 9, 11}, {0, 2, 3, 5, 7, 8, 10}, {0, 2, 4, 7, 9, -1, -1},
                                   {0, 3, 5, 7, 10, -1, -1}, {0, 2, 3, 5, 7, 9, 10}, {0, 2, 3, 5, 7, 8, 11}};
constexpr int kModes = 16;
// A mode's level: broadband input (noise, drums) comes out of the default bank about 6 dB down, held notes louder.
constexpr double kModeGain = 2.4;

// A free-free bar's mode frequencies over its first: (x_n / x_1)^2 with x_n the roots of cos x cosh x = 1
// (4.7300, 7.8532, 10.9956, then (2n + 1) pi / 2 to better than 1e-6). [Beam theory; Fletcher & Rossing, "The
// Physics of Musical Instruments", ch. 2, lists the same ratios 1, 2.756, 5.404, 8.933.]
double barRatio(int n) noexcept {
    const double x1 = 4.730040744862704;
    const double xs[3] = {4.730040744862704, 7.853204624095838, 10.995607838001671};
    const double x = n < 3 ? xs[n] : (2.0 * (n + 1) + 1.0) * kPi / 2.0;
    return (x / x1) * (x / x1);
}

const ParamTable& resParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("mode", "Mode", 0.0, kResModes);
        p.pick("chord", "Chord", 0.0, kChords);
        p.pick("scale", "Scale", 0.0, kScales);
        p.num("note", "Note", 48.0, 24.0, 96.0).step = 1.0;
        p.num("fine", "Fine", 0.0, -100.0, 100.0, "ct");
        p.expo("decay", "Decay", 1.0, 0.05, 10.0, "s");
        p.num("brightness", "Brightness", 0.5, 0.0, 1.0);
        p.num("spread", "Spread", 0.3, 0.0, 1.0);
        p.num("mix", "Mix", 0.5, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& resDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.resonator", "Resonator", resParams(), 0, kInfiniteTail);
    return d;
}

// One two-pole resonance: a TPT state-variable band-pass (stable at any Q and however fast it is retuned).
struct Mode {
    double a1 = 1, a2 = 0, a3 = 0, gain = 0, hz = -1, q = -1;
    void set(double f, double qq, double sr) noexcept {
        if (f == hz && qq == q) return;
        hz = f, q = qq;
        const double g = detTan(kPi * f / sr), k = 1.0 / qq;
        a1 = 1.0 / (1.0 + g * (g + k));
        a2 = g * a1;
        a3 = g * a2;
    }
};

class Resonator final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return resDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        release_ = detExp(-1.0 / (0.15 * sr));
        return true;
    }
    void clearState() noexcept override {
        for (int j = 0; j < kModes; ++j) ic1_[j] = ic2_[j] = pairOf(0.0, 0.0);
        env_ = 0.0;
        note_ = -1.0;
        mix_.reset(), out_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        for (int j = 0; j < kModes; ++j) ic1_[j] = filters::flushPair(ic1_[j]), ic2_[j] = filters::flushPair(ic2_[j]);  // at the grid
        mode_ = std::clamp(choice(kRMode, at), 0, 4);
        const int chord = std::clamp(choice(kRChord, at), 0, 6), scale = std::clamp(choice(kRScale, at), 0, 5);
        // The pitch glides over ~30 ms (a new note sweeps the bank there rather than jumping).
        const double note = std::clamp(param(kRNote, at), 24.0, 96.0) + std::clamp(param(kRFine, at), -100.0, 100.0) / 100.0;
        note_ = note_ < 0.0 ? note : note_ + (note - note_) * (1.0 - detExp(-static_cast<double>(kControlFrames) / (0.03 * sr)));
        const double root = noteHz(note_);
        decay_ = std::clamp(param(kRDecay, at), 0.05, 10.0);
        bright_ = std::clamp(param(kRBright, at), 0.0, 1.0);
        spread_ = std::clamp(param(kRSpread, at), 0.0, 1.0);
        const double detune = detPow(2.0, spread_ * 8.0 / 1200.0);  // the right bank up to 8 cents sharp
        for (int j = 0; j < kModes; ++j) {
            double f = root;
            int rank = j + 1;  // a partial's place in its series (sets its level)
            switch (mode_) {
                case kOdd: f = root * (2 * j + 1); rank = 2 * j + 1; break;
                case kModal: f = root * barRatio(j); break;
                case kChord: {
                    const int tone = j % 4, harmonic = j / 4 + 1;
                    f = root * detPow(2.0, kChordNotes[chord][tone] / 12.0) * harmonic;
                    rank = harmonic;
                    break;
                }
                case kScale: {
                    const int* steps = kScaleSteps[scale];
                    int count = 0;
                    while (count < 7 && steps[count] >= 0) ++count;
                    f = root * detPow(2.0, (12 * (j / count) + steps[j % count]) / 12.0);
                    rank = 1;
                    break;
                }
                default: f = root * (j + 1); break;
            }
            const bool audible = f < 0.45 * sr && f > 10.0;
            // A partial's T60: the decay at the root, shorter up the series unless it is bright; Q = pi f T60 / ln 1000.
            const double t60 = decay_ * detPow(root / f, 0.9 * (1.0 - bright_));
            const double level = audible ? detPow(static_cast<double>(rank), -(1.4 - 1.2 * bright_)) : 0.0;
            for (int c = 0; c < 2; ++c) {
                const double fc = std::min(c == 1 ? f * detune : f, 0.45 * sr);
                const double q = std::clamp(kPi * fc * t60 / 6.907755278982137, 0.5, 2e5);
                modes_[c][j].set(fc, q, sr);
                // Band output times sqrt(k): each mode's power from a broad input independent of its decay.
                const double pan = (j & 1) == c ? 1.0 : 1.0 - spread_;
                modes_[c][j].gain = level * pan * std::sqrt(1.0 / q) * kModeGain;
            }
        }
        // The bank packed for run(): the sounding modes, left and right side by side.
        live_ = 0;
        for (int j = 0; j < kModes; ++j) {
            const Mode &l = modes_[0][j], &r = modes_[1][j];
            if (l.gain == 0.0 && r.gain == 0.0) {
                ic1_[j] = ic2_[j] = pairOf(0.0, 0.0);
                continue;
            }
            pack_[live_++] = {pairOf(l.a1, r.a1), pairOf(l.a2, r.a2), pairOf(l.a3, r.a3), pairOf(l.gain, r.gain), j};
        }
        mix_.set(std::clamp(param(kRMix, at), 0.0, 1.0), kControlFrames);
        out_.set(lib::dbToGain(std::clamp(param(kROutput, at), -24.0, 24.0)), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double x[2] = {finiteOr0(inL[i]), finiteOr0(inR[i])};
            const Pair in = pairOf(x[0], x[1]), two = pairOf(2.0, 2.0);
            Pair sum = pairOf(0.0, 0.0);
            for (int a = 0; a < live_; ++a) {
                const Packed& m = pack_[a];
                Pair& s1 = ic1_[m.j];
                Pair& s2 = ic2_[m.j];
                const Pair v3 = in - s2;
                const Pair band = m.a1 * s1 + m.a2 * v3;
                const Pair low = s2 + m.a2 * s1 + m.a3 * v3;
                s1 = two * band - s1;
                s2 = two * low - s2;
                sum = sum + m.gain * band;
            }
            const double wet[2] = {lane(sum, 0), lane(sum, 1)};
            // A safety ceiling on the bank (a held note at a resonance can ring far above the input): instant
            // down, 150 ms back up.
            const double p = std::max(std::fabs(wet[0]), std::fabs(wet[1]));
            env_ = p > env_ ? p : p + (env_ - p) * release_;
            const double g = (env_ > 1.0 ? 1.0 / env_ : 1.0) * out_.next(), mix = mix_.next();
            outL[i] = static_cast<float>(x[0] + (wet[0] * g - x[0]) * mix);
            outR[i] = static_cast<float>(x[1] + (wet[1] * g - x[1]) * mix);
        }
        if (env_ < 1e-20) env_ = 0.0;
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(mode_);
        out[3] = static_cast<float>(note_ < 0 ? 48.0 : note_);
        out[4] = static_cast<float>(lib::gainToDb(env_ > 1.0 ? 1.0 / env_ : 1.0));  // the ceiling's reduction
        out[5] = static_cast<float>(kModes);
        for (int j = 0; j < kModes; ++j) {
            out[6 + j] = static_cast<float>(modes_[0][j].hz);
            out[6 + kModes + j] = static_cast<float>(lib::gainToDb(modes_[0][j].gain / kModeGain * std::sqrt(std::max(0.5, modes_[0][j].q))));
        }
        return 6 + 2 * kModes;
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>(0.1 * rate()); }

private:
    struct Packed {
        Pair a1, a2, a3, gain;
        int j;
    };
    Mode modes_[2][kModes];
    Pair ic1_[kModes], ic2_[kModes];  // each mode's two states, left and right side by side
    Packed pack_[kModes];
    int live_ = 0;
    int mode_ = 0;
    double note_ = -1.0, decay_ = 1.0, bright_ = 0.5, spread_ = 0.3, env_ = 0.0, release_ = 0.9999;
    Ramp mix_, out_;
};

ModuleProcessor* makeResonator() noexcept { return new (std::nothrow) Resonator(); }

}  // namespace

void registerCombAndResonator(ModuleRegistry& registry) {
    registry.add(combDescriptor(), &makeComb);
    registry.add(resDescriptor(), &makeResonator);
}

}  // namespace caw::fx
