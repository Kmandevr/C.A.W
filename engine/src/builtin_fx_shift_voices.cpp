// Pitch/Shift's 1.1.0 variants (Soar): Harmonizer (1-4 in-key voices, pitch-synchronous grains that keep the formants) and Octaver (a sub-octave and an octave up for guitar and bass).
#include "builtin_effects.h"
#include "builtin_fx_voice.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <span>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/eq.hpp"
#include "component_chain.h"
#include "fx_pitchtrack.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0).
// Harmonizer: the input's mid is tracked (fx_pitchtrack.h: YIN, 70 Hz..1.2 kHz, an analysis about every 10 ms) and
// its nearest note in Key/Scale found (a hysteresis of 0.3 semitones, so a note between two doesn't flicker); each
// voice sounds the scale note `degree` steps away (+2 a third above in a major or minor scale, -3 a fourth below,
// +7 an octave; in Chromatic a step is a semitone), shifted from the input by that note's distance from the input's
// note, so the voice keeps the singer's own bends and vibrato; the shift glides over Glide. Unvoiced input (breath,
// consonants) keeps the last shifts. Each voice is pitch-synchronous overlap-add (the PSOLA principle: Moulines and
// Charpentier, Speech Communication 9, 1990): Hann grains two periods long, cut from the input at marks one period
// apart, laid down one new period apart; a grain read at the input's speed keeps the formants (Formant 1), one read
// faster or slower moves them with the pitch (Formant 0: the chipmunk), in between by Formant. The marks are a
// train one detected period apart (not epoch-picked), which every grain shares, so the grains add in phase. The
// latency is fixed at 1.5 periods of 70 Hz (about 21 ms; the dry is delayed to match) and reported per instance.
// Octaver: the input's mid, low-passed for tracking (Guitar 900 Hz, Bass 350 Hz). Mono: a flip-flop toggled by each
// rising zero crossing (with a hysteresis of a tenth of the level) is a square at half the pitch; times the tracked
// signal it gives the sub-octave (about 0.85 of its level), then the Sub tone low-pass (12 dB/octave); the octave up is the tracked
// signal full-wave rectified (twice the pitch) less its DC. No latency. Poly: two delay-line pitch shifters (0.5 and
// 2, two crossfaded taps, a 30 ms or 50 ms window), which take chords but blur and lag a little. Auto plays Mono while
// the crossings come at a steady period (their jitter under about 8 %) and fades to Poly when they don't (a chord, a
// noisy note), over 30 ms.

namespace caw::fx {

namespace {

constexpr double kPi = 3.14159265358979323846;
constexpr std::string_view kId = "org.caw.shift";
constexpr std::string_view kName = "Pitch/Shift";
constexpr uint32_t kVoices = 4;
constexpr double kLowestHz = 70.0;

inline double finite0(float x) noexcept { return x == x && x - x == 0.0f ? static_cast<double>(x) : 0.0; }

// --- Shared: the Hann window, a table built at registration (read-only, shared by every instance) ---
constexpr uint32_t kWindow = 512;
const float* hann() noexcept {
    static const struct T {
        float w[kWindow + 2];
        T() noexcept {
            for (uint32_t i = 0; i <= kWindow; ++i) w[i] = static_cast<float>(0.5 - 0.5 * std::cos(2.0 * kPi * i / kWindow));
            w[kWindow + 1] = 0.0f;
        }
    } t;
    return t.w;
}
inline float window(double phase) noexcept {  // phase 0..1
    const float* w = hann();
    const double p = phase * kWindow;
    const uint32_t i = static_cast<uint32_t>(p);
    const float f = static_cast<float>(p - i);
    return w[i] + f * (w[i + 1] - w[i]);
}

// A float ring of a power-of-two size, read at a fractional absolute position (linear).
class Ring {
public:
    bool allocate(size_t atLeast) {
        size_t n = 1;
        while (n < atLeast) n <<= 1;
        try {
            data_.assign(n, 0.0f);
        } catch (...) {
            return false;
        }
        mask_ = n - 1;
        return true;
    }
    void clear() noexcept { std::fill(data_.begin(), data_.end(), 0.0f); }
    void write(int64_t at, float x) noexcept { data_[static_cast<size_t>(at) & mask_] = x; }
    float at(int64_t i) const noexcept { return data_[static_cast<size_t>(i) & mask_]; }
    float read(double pos) const noexcept {
        const double f = std::floor(pos);
        const int64_t i = static_cast<int64_t>(f);
        const float a = at(i), b = at(i + 1);
        return a + static_cast<float>(pos - f) * (b - a);
    }
    size_t bytes() const noexcept { return data_.size() * sizeof(float); }

private:
    std::vector<float> data_;
    size_t mask_ = 0;
};

// --- Harmonizer -----------------------------------------------------------------------------------------------------

constexpr std::string_view kKeys[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
constexpr std::string_view kScales[] = {"Major",      "Minor",      "Harmonic minor", "Melodic minor",  "Dorian",   "Phrygian",
                                        "Lydian",     "Mixolydian", "Major pentatonic", "Minor pentatonic", "Blues", "Chromatic"};
struct Scale {
    int count;
    int notes[12];
};
constexpr Scale kScaleTable[] = {
    {7, {0, 2, 4, 5, 7, 9, 11}}, {7, {0, 2, 3, 5, 7, 8, 10}}, {7, {0, 2, 3, 5, 7, 8, 11}}, {7, {0, 2, 3, 5, 7, 9, 11}},
    {7, {0, 2, 3, 5, 7, 9, 10}}, {7, {0, 1, 3, 5, 7, 8, 10}}, {7, {0, 2, 4, 6, 7, 9, 11}}, {7, {0, 2, 4, 5, 7, 9, 10}},
    {5, {0, 2, 4, 7, 9}},        {5, {0, 3, 5, 7, 10}},       {6, {0, 3, 5, 6, 7, 10}},     {12, {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11}},
};
constexpr int kScaleCount = static_cast<int>(sizeof(kScaleTable) / sizeof(kScaleTable[0]));
static_assert(kScaleCount == static_cast<int>(sizeof(kScales) / sizeof(kScales[0])));

// Harmonizer parameters: voices, then per voice degree, level, pan, then the rest.
enum HzParam : uint32_t { hzVoices, hzVoice0 = 1, hzKey = hzVoice0 + 3 * kVoices, hzScale, hzFormant, hzDetune, hzGlide, hzMix, hzOutput, hzCount };

const ParamTable& harmonizerParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("voices", "Voices", 2.0, 1.0, 4.0).step = 1.0;
        const double degree[kVoices] = {2, 4, -3, 7};
        const double pan[kVoices] = {-0.4, 0.4, -0.7, 0.7};
        for (uint32_t v = 0; v < kVoices; ++v) {
            const std::string n = std::to_string(v + 1);
            ParameterDescriptor& d = p.num("v" + n + "_degree", "Voice " + n + " interval", degree[v], -14.0, 14.0);
            d.step = 1.0;
            d.smoothingFrames = 0;
            p.num("v" + n + "_level", "Voice " + n + " level", 0.8, 0.0, 1.0);
            p.num("v" + n + "_pan", "Voice " + n + " pan", pan[v], -1.0, 1.0);
        }
        p.pick("key", "Key", 0.0, kKeys);
        p.pick("scale", "Scale", 0.0, kScales);
        p.num("formant", "Formant", 1.0, 0.0, 1.0);
        p.num("detune", "Detune", 5.0, 0.0, 30.0, "ct");
        p.expo("glide", "Glide", 20.0, 1.0, 300.0, "ms");
        p.num("mix", "Mix", 0.5, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}

const ModuleDescriptor& harmonizerBase() {
    // Latency 0 here: 1.5 periods of 70 Hz are reported per instance (VariableLatency).
    static const ModuleDescriptor d = withCpu(effectDescriptor(kId, kName, harmonizerParams(), 0, 0), CpuClass::Heavy);
    return d;
}

uint32_t harmonizerLatency(double sr) noexcept { return static_cast<uint32_t>(std::ceil(1.5 * sr / kLowestHz)) + 4; }

// One voice: its grains (at most kGrains sound at once).
struct Voice {
    static constexpr int kGrains = 8;
    struct Grain {
        double pos = 0, rate = 1, phase = 0, step = 0;
        bool on = false;
    };
    Grain g[kGrains];
    double next = 0;      // the output frame of the next grain's start
    double epoch = 0;     // the analysis mark train (an input frame)
    double shift = 0;     // semitones now (gliding)
    double target = 0;    // semitones it glides to
    double gainL = 0, gainR = 0;
    bool active = false;
    void clear() noexcept {
        for (Grain& x : g) x.on = false;
        next = 0, epoch = 0, shift = target = 0;
        active = false;
    }
};

class Harmonizer final : public EffectBase, public VariableLatency {
public:
    explicit Harmonizer(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }
    uint32_t latencyFor(const double*, uint32_t) const noexcept override { return harmonizerLatency(rate()); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        latency_ = harmonizerLatency(sr);
        maxPeriod_ = sr / kLowestHz;
        tracker_.setup(sr, kLowestHz, 1200.0);
        const size_t need = static_cast<size_t>(latency_ + 4 * maxPeriod_) + 64;
        return mid_.allocate(need) && dryL_.allocate(latency_ + 2) && dryR_.allocate(latency_ + 2);
    }
    void clearState() noexcept override {
        mid_.clear(), dryL_.clear(), dryR_.clear();
        tracker_.clear();
        for (Voice& v : voices_) v.clear();
        t_ = 0;
        period_ = rate() / 150.0;
        note_ = -1000;
        inMidi_ = 0;
        first_ = true;
        dry_.reset(), wet_.reset();
    }
    uint64_t idleFrames() const noexcept override { return latency_ + static_cast<uint64_t>(4 * maxPeriod_ + 0.05 * rate()); }

    void control(uint32_t at) noexcept override {
        tracker_.step();
        const double sr = rate();
        if (!knobsUnchanged(knobs_, hzCount, at) || first_) {
            count_ = std::clamp(static_cast<int>(param(hzVoices, at) + 0.5), 1, static_cast<int>(kVoices));
            key_ = std::clamp(choice(hzKey, at), 0, 11);
            scale_ = std::clamp(choice(hzScale, at), 0, kScaleCount - 1);
            keep_ = std::clamp(param(hzFormant, at), 0.0, 1.0);
            detune_ = std::clamp(param(hzDetune, at), 0.0, 30.0) * 0.01;
            glide_ = 1.0 - detExp(-static_cast<double>(kControlFrames) / (std::max(1.0, param(hzGlide, at)) * 0.001 * sr));
            const double mix = std::clamp(param(hzMix, at), 0.0, 1.0);
            dryTarget_ = std::min(1.0, 2.0 * (1.0 - mix));
            wetTarget_ = std::min(1.0, 2.0 * mix);
            outGain_ = lib::dbToGain(param(hzOutput, at));
            for (uint32_t v = 0; v < kVoices; ++v) {
                degree_[v] = static_cast<int>(std::lround(std::clamp(param(hzVoice0 + 3 * v, at), -14.0, 14.0)));
                const double level = std::clamp(param(hzVoice0 + 3 * v + 1, at), 0.0, 1.0);
                const double pan = std::clamp(param(hzVoice0 + 3 * v + 2, at), -1.0, 1.0);
                const double a = (pan + 1.0) * 0.25 * kPi;
                voices_[v].gainL = level * detCos(a) * 1.4142135623730951 * 0.5;
                voices_[v].gainR = level * detSin(a) * 1.4142135623730951 * 0.5;
                if (v < static_cast<uint32_t>(count_) && !voices_[v].active) {
                    voices_[v].clear();
                    voices_[v].next = static_cast<double>(t_);
                    voices_[v].epoch = static_cast<double>(t_ - latency_);
                }
                voices_[v].active = v < static_cast<uint32_t>(count_);
            }
            note_ = -1000;  // the scale may have changed: find the note again
        }
        // The input's note, and each voice's target shift (unvoiced: held).
        if (tracker_.voiced()) {
            const double hz = tracker_.hz();
            period_ += (std::clamp(sr / hz, sr / 1200.0, maxPeriod_) - period_) * 0.5;
            inMidi_ = 69.0 + 12.0 * std::log2(hz / 440.0);
            const Scale& s = kScaleTable[scale_];
            const int nearest = nearestDegree(inMidi_, s);
            if (note_ == -1000 || std::fabs(inMidi_ - noteOf(nearest, s)) + 0.3 < std::fabs(inMidi_ - noteOf(note_, s))) note_ = nearest;
            for (uint32_t v = 0; v < kVoices; ++v) voices_[v].target = noteOf(note_ + degree_[v], s) - noteOf(note_, s);
            voiced_ = true;
        } else {
            voiced_ = false;
        }
        const double det[kVoices] = {detune_, -detune_, 0.5 * detune_, -0.5 * detune_};
        for (uint32_t v = 0; v < kVoices; ++v) {
            Voice& x = voices_[v];
            if (first_) x.shift = x.target;
            x.shift += (x.target - x.shift) * glide_;
            ratio_[v] = detPow(2.0, (x.shift + det[v]) / 12.0);
            readRate_[v] = detPow(ratio_[v], 1.0 - keep_);
            norm_[v] = 1.0 / std::sqrt(ratio_[v] / readRate_[v]);
        }
        dry_.set(dryTarget_ * outGain_, kControlFrames);
        wet_.set(wetTarget_ * outGain_, kControlFrames);
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const double T = period_;
        const int64_t lat = latency_;
        for (uint32_t i = 0; i < n; ++i) {
            const double l = finite0(inL[i]), r = finite0(inR[i]);
            const float m = static_cast<float>(0.5 * (l + r));
            const int64_t t = t_;
            mid_.write(t, m);
            dryL_.write(t, static_cast<float>(l));
            dryR_.write(t, static_cast<float>(r));
            tracker_.push(m);
            double wl = 0.0, wr = 0.0;
            for (uint32_t v = 0; v < static_cast<uint32_t>(count_); ++v) {
                Voice& x = voices_[v];
                const double rr = readRate_[v];
                if (static_cast<double>(t) >= x.next) {  // a new grain: the train's mark nearest its centre, less the latency
                    const double centre = static_cast<double>(t) + T / rr - static_cast<double>(lat);
                    const double k = std::floor((centre - x.epoch) / T + 0.5);
                    x.epoch += k * T;
                    for (Voice::Grain& g : x.g)
                        if (!g.on) {
                            g.on = true, g.pos = x.epoch - T, g.rate = rr, g.phase = 0.0, g.step = rr / (2.0 * T);
                            break;
                        }
                    x.next += T / ratio_[v];
                    if (x.next < static_cast<double>(t)) x.next = static_cast<double>(t) + 1.0;  // never falls behind
                }
                double acc = 0.0;
                for (Voice::Grain& g : x.g) {
                    if (!g.on) continue;
                    acc += window(g.phase) * mid_.read(g.pos);
                    g.pos += g.rate;
                    g.phase += g.step;
                    if (g.phase >= 1.0) g.on = false;
                }
                acc *= norm_[v];
                wl += x.gainL * acc;
                wr += x.gainR * acc;
            }
            const double d = dry_.next(), w = wet_.next();
            outL[i] = static_cast<float>(d * dryL_.at(t - lat) + w * wl);
            outR[i] = static_cast<float>(d * dryR_.at(t - lat) + w * wr);
            ++t_;
        }
    }

    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = voiced_ ? 1.0f : 0.0f;
        out[3] = static_cast<float>(voiced_ ? tracker_.hz() : 0.0);
        out[4] = static_cast<float>(voiced_ ? inMidi_ : 0.0);
        out[5] = static_cast<float>(key_);
        out[6] = static_cast<float>(scale_);
        out[7] = static_cast<float>(count_);
        const Scale& s = kScaleTable[scale_];
        for (uint32_t v = 0; v < kVoices; ++v) {
            const bool on = v < static_cast<uint32_t>(count_);
            out[8 + v] = static_cast<float>(on ? voices_[v].shift : 0.0);
            out[12 + v] = static_cast<float>(on && note_ != -1000 ? noteOf(note_ + degree_[v], s) : -1.0);
        }
        out[16] = static_cast<float>(1000.0 * latency_ / rate());
        out[17] = static_cast<float>(tracker_.confidence());
        return 18;
    }

private:
    // The scale degree (counted from the key's C-octave 0) nearest a pitch, and a degree's MIDI note.
    int nearestDegree(double midi, const Scale& s) const noexcept {
        const double rel = midi - key_;
        const int oct = static_cast<int>(std::floor(rel / 12.0));
        int best = 0;
        double bestDist = 1e9;
        for (int o = oct - 1; o <= oct + 1; ++o)
            for (int j = 0; j < s.count; ++j) {
                const double dist = std::fabs(rel - (12.0 * o + s.notes[j]));
                if (dist < bestDist) bestDist = dist, best = o * s.count + j;
            }
        return best;
    }
    double noteOf(int degree, const Scale& s) const noexcept {
        const int o = degree >= 0 ? degree / s.count : -((-degree + s.count - 1) / s.count);
        return key_ + 12.0 * o + s.notes[degree - o * s.count];
    }

    const ModuleDescriptor& d_;
    double knobs_[hzCount] = {};
    PitchTracker tracker_;
    Ring mid_, dryL_, dryR_;
    Voice voices_[kVoices];
    int degree_[kVoices] = {};
    double ratio_[kVoices] = {1, 1, 1, 1}, readRate_[kVoices] = {1, 1, 1, 1}, norm_[kVoices] = {1, 1, 1, 1};
    int64_t t_ = 0;
    uint32_t latency_ = 0;
    int count_ = 2, key_ = 0, scale_ = 0, note_ = -1000;
    double maxPeriod_ = 700, period_ = 320, inMidi_ = 0, keep_ = 1, detune_ = 0, glide_ = 1;
    double dryTarget_ = 1, wetTarget_ = 1, outGain_ = 1;
    bool first_ = true, voiced_ = false;
    Ramp dry_, wet_;
};

// --- Octaver --------------------------------------------------------------------------------------------------------

constexpr std::string_view kTracking[] = {"Auto", "Mono", "Poly"};
constexpr std::string_view kRanges[] = {"Guitar", "Bass"};
enum OcParam : uint32_t { ocTracking, ocRange, ocSub, ocUp, ocDry, ocTone, ocOutput, ocCount };

const ParamTable& octaverParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("tracking", "Tracking", 0.0, kTracking);
        p.pick("range", "Range", 0.0, kRanges);
        p.num("sub", "Sub octave", 0.7, 0.0, 1.0);
        p.num("up", "Octave up", 0.0, 0.0, 1.0);
        p.num("dry", "Dry", 1.0, 0.0, 1.0);
        p.expo("tone", "Sub tone", 800.0, 80.0, 4000.0, "Hz");
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}
const ModuleDescriptor& octaverBase() {
    static const ModuleDescriptor d = withCpu(effectDescriptor(kId, kName, octaverParams(), 0, 0), CpuClass::Medium);  // Mono alone is light
    return d;
}

lib::SvfMix lowPassCoef(double hz, double sr, double k = 1.4142135623730951) {
    lib::SvfMix m;
    m.set(detTan(kPi * std::min(hz, 0.45 * sr) / sr), k, 0.0, 0.0, 1.0);
    return m;
}

// A delay-line pitch shifter of one fixed ratio: two taps half a cycle apart, each faded in and out by sin^2.
struct TapShifter {
    double phase = 0;  // 0..1 through the window
    double rate = 0;   // phase per frame: |1 - ratio| / window
    double window = 1;
    bool down = true;  // the delay grows (ratio < 1) or shrinks
    void set(double ratio, double windowFrames) noexcept {
        window = windowFrames;
        rate = std::fabs(1.0 - ratio) / windowFrames;
        down = ratio < 1.0;
    }
    double process(const Ring& r, int64_t t) noexcept {
        // The taps' fades are the shared Hann table (sin^2(pi p) = hann(p)).
        const double p0 = phase, p1 = phase < 0.5 ? phase + 0.5 : phase - 0.5;
        const double d0 = 2.0 + (down ? p0 : 1.0 - p0) * window, d1 = 2.0 + (down ? p1 : 1.0 - p1) * window;
        const double tt = static_cast<double>(t);
        const double y = caw::fx::window(p0) * r.read(tt - d0) + caw::fx::window(p1) * r.read(tt - d1);
        phase += rate;
        if (phase >= 1.0) phase -= 1.0;
        return y;
    }
};

class Octaver final : public EffectBase {
public:
    explicit Octaver(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        dc_ = 1.0 - detExp(-2.0 * kPi * 20.0 / sr);
        blend_ = 1.0 - detExp(-static_cast<double>(kControlFrames) / (0.030 * sr));
        envRel_ = detExp(-1.0 / (0.050 * sr));
        return ring_.allocate(static_cast<size_t>(0.05 * sr) + 16);
    }
    void clearState() noexcept override {
        ring_.clear();
        track_[0].clear(), track_[1].clear(), subLp_[0].clear(), subLp_[1].clear();
        flip_ = 1.0, armed_ = true, env_ = 0.0, dcState_ = 0.0;
        sinceCross_ = 0, period_ = 0, jitter_ = 1.0;
        down_.phase = up_.phase = 0.0;
        t_ = 0;
        first_ = true;
        sub_.reset(), up2_.reset(), dry_.reset(), mono_.reset();
    }
    void control(uint32_t at) noexcept override {
        const double sr = rate();
        if (!knobsUnchanged(knobs_, ocCount, at) || first_) {
            tracking_ = std::clamp(choice(ocTracking, at), 0, 2);
            bass_ = choice(ocRange, at) == 1;
            trackC_ = lowPassCoef(bass_ ? 350.0 : 900.0, sr);
            toneC_ = lowPassCoef(std::clamp(param(ocTone, at), 80.0, 4000.0), sr);
            const double window = (bass_ ? 0.050 : 0.030) * sr;
            down_.set(0.5, window);
            up_.set(2.0, window);
            const double out = lib::dbToGain(param(ocOutput, at));
            subT_ = std::clamp(param(ocSub, at), 0.0, 1.0) * out;
            upT_ = std::clamp(param(ocUp, at), 0.0, 1.0) * out;
            dryT_ = std::clamp(param(ocDry, at), 0.0, 1.0) * out;
        }
        // Mono's share: 1 in Mono, 0 in Poly; Auto follows how steady the crossings are.
        double want = tracking_ == 1 ? 1.0 : 0.0;
        if (tracking_ == 0) {
            if (confidence() > 0.6) wantMono_ = true;
            else if (confidence() < 0.4) wantMono_ = false;
            want = wantMono_ ? 1.0 : 0.0;
        }
        monoShare_ = tracking_ == 0 && !first_ ? monoShare_ + (want - monoShare_) * blend_ : want;
        if (std::fabs(monoShare_ - want) < 1e-4) monoShare_ = want;
        mono_.set(monoShare_, kControlFrames);
        sub_.set(subT_, kControlFrames), up2_.set(upT_, kControlFrames), dry_.set(dryT_, kControlFrames);
        first_ = false;
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const bool tracking = tracking_ != 2;                 // the flip-flop runs (Mono or Auto)
        const bool poly = tracking_ == 2 || monoShare_ < 1.0 || mono_.step != 0.0;  // the taps sound
        const double hyst = 0.1;
        double sp = subPeak_, upk = upPeak_;
        for (uint32_t i = 0; i < n; ++i) {
            const double l = finite0(inL[i]), r = finite0(inR[i]);
            const double m = 0.5 * (l + r);
            ring_.write(t_, static_cast<float>(m));
            const double mono = mono_.next(), sg = sub_.next(), ug = up2_.next(), dg = dry_.next();
            double sub = 0.0, up = 0.0;
            if (tracking) {
                const double x = track_[1].process(trackC_, track_[0].process(trackC_, m));
                const double a = std::fabs(x);
                env_ = a > env_ ? a : env_ * envRel_;
                const double th = std::max(1e-4, hyst * env_);
                ++sinceCross_;
                if (armed_ && x > th) {  // a rising crossing: the flip-flop toggles
                    armed_ = false;
                    flip_ = -flip_;
                    crossing(sinceCross_);
                    sinceCross_ = 0;
                } else if (!armed_ && x < -th) {
                    armed_ = true;
                }
                if (sinceCross_ > 4800) jitter_ = 1.0;  // nothing for 0.1 s: not a steady note
                const double s = subLp_[0].process(toneC_, flip_ * x);
                double u = 2.0 * a;
                dcState_ += dc_ * (u - dcState_);
                u -= dcState_;
                sub += mono * s * 1.18;  // 1 / 0.85: the sub-octave at the tracked signal's level
                up += mono * u * 2.36;   // a rectified sine's octave is 4 / (3 pi) of it
            }
            if (poly) {
                const double w = 1.0 - mono;
                sub += w * down_.process(ring_, t_);
                up += w * up_.process(ring_, t_);
            }
            sub *= sg, up *= ug;
            sp = std::max(sp, std::fabs(sub)), upk = std::max(upk, std::fabs(up));
            outL[i] = static_cast<float>(dg * l + sub + up);
            outR[i] = static_cast<float>(dg * r + sub + up);
            ++t_;
        }
        subPeak_ = sp, upPeak_ = upk;
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(tracking_);
        out[3] = static_cast<float>(tracking_ != 2 && period_ > 0 && jitter_ < 0.5 ? rate() / period_ : 0.0);
        out[4] = static_cast<float>(tracking_ != 2 ? confidence() : 0.0);
        out[5] = static_cast<float>(monoShare_);
        out[6] = static_cast<float>(lib::gainToDb(subPeak_));
        out[7] = static_cast<float>(lib::gainToDb(upPeak_));
        subPeak_ = upPeak_ = 0.0;
        return 8;
    }

private:
    // A new period between two rising crossings: its jitter against the last, followed.
    void crossing(uint64_t frames) noexcept {
        const double p = static_cast<double>(frames);
        if (period_ > 0.0) {
            const double j = std::fabs(p - period_) / std::max(p, period_);
            jitter_ += (j - jitter_) * 0.2;
        }
        period_ = p;
    }
    double confidence() const noexcept { return std::clamp(1.0 - jitter_ / 0.08, 0.0, 1.0); }

    const ModuleDescriptor& d_;
    double knobs_[ocCount] = {};
    Ring ring_;
    lib::SvfMix trackC_, toneC_;
    lib::SvfState track_[2], subLp_[2];
    TapShifter down_, up_;
    Ramp sub_, up2_, dry_, mono_;
    int64_t t_ = 0;
    uint64_t sinceCross_ = 0;
    int tracking_ = 0;
    bool bass_ = false, armed_ = true, first_ = true, wantMono_ = true;
    double flip_ = 1, env_ = 0, envRel_ = 0.999, dc_ = 0.001, dcState_ = 0, period_ = 0, jitter_ = 1;
    double monoShare_ = 1, blend_ = 0.1, subT_ = 0, upT_ = 0, dryT_ = 1, subPeak_ = 0, upPeak_ = 0;
};

using V = std::vector<std::pair<std::string_view, double>>;

const std::vector<BuiltinPreset>& shiftVoicePresets() {
    static const std::vector<BuiltinPreset> p = {
        // Harmonizer (variant 2)
        {"Third above", "Vocals: one voice a third above, in C major", V{{"variant", 2}, {"voices", 1}, {"v1_degree", 2}, {"v1_pan", 0}, {"mix", 0.45}}},
        {"Thirds and fifths", "Vocals: a three-part stack (third and fifth above)", V{{"variant", 2}, {"voices", 2}, {"v1_degree", 2}, {"v2_degree", 4}}},
        {"Octave double", "Vocals: an octave below, tucked under", V{{"variant", 2}, {"voices", 1}, {"v1_degree", -7}, {"v1_level", 0.6}, {"v1_pan", 0}}},
        {"Choir wide", "Vocals: four voices around the lead, spread wide", V{{"variant", 2}, {"voices", 4}, {"v1_degree", 2}, {"v2_degree", 4}, {"v3_degree", -3}, {"v4_degree", -7}, {"detune", 12}, {"mix", 0.55}}},
        {"Minor harmony", "Vocals: a third and a fifth above in A minor", V{{"variant", 2}, {"voices", 2}, {"key", 9}, {"scale", 1}, {"v1_degree", 2}, {"v2_degree", 4}}},
        {"Sixth below", "Vocals: a sweet sixth under the melody", V{{"variant", 2}, {"voices", 1}, {"v1_degree", -2}, {"v1_pan", 0.2}}},
        {"Guitar harmony", "Guitar: twin lead in thirds, quick glide", V{{"variant", 2}, {"voices", 1}, {"v1_degree", 2}, {"v1_pan", 0.5}, {"glide", 8}, {"mix", 0.5}}},
        {"Power fifths", "Guitar: a fifth above and an octave below", V{{"variant", 2}, {"voices", 2}, {"scale", 11}, {"v1_degree", 7}, {"v2_degree", -12}, {"formant", 0.5}}},
        {"Chipmunk choir", "Sound design: an octave up without formant keep", V{{"variant", 2}, {"voices", 2}, {"v1_degree", 7}, {"v2_degree", 9}, {"formant", 0}, {"mix", 0.6}}},
        {"Pentatonic trio", "Vocals: in-key voices that can't clash (major pentatonic)", V{{"variant", 2}, {"voices", 2}, {"scale", 8}, {"v1_degree", 1}, {"v2_degree", 2}}},
        // Octaver (variant 3)
        {"Clean sub", "Guitar: a clean octave below, mono tracking", V{{"variant", 3}, {"tracking", 1}, {"sub", 0.7}, {"dry", 1}}},
        {"Bass sub octave", "Bass: an octave under the bass line", V{{"variant", 3}, {"range", 1}, {"tracking", 1}, {"sub", 0.8}, {"tone", 300}}},
        {"Synth bass", "Bass: sub only, a little up, like a synth", V{{"variant", 3}, {"range", 1}, {"sub", 0.9}, {"up", 0.2}, {"dry", 0.4}, {"tone", 400}}},
        {"Organ octaves", "Guitar: an octave below and above, for chords too (Auto)", V{{"variant", 3}, {"sub", 0.6}, {"up", 0.5}}},
        {"Octave up fuzz", "Guitar: the octave up alone, ringing", V{{"variant", 3}, {"tracking", 1}, {"sub", 0}, {"up", 0.8}}},
        {"12-string", "Guitar: an octave up for chords (Poly)", V{{"variant", 3}, {"tracking", 2}, {"sub", 0}, {"up", 0.45}}},
        {"Chord sub", "Guitar: a sub-octave under chords (Poly)", V{{"variant", 3}, {"tracking", 2}, {"sub", 0.6}}},
        {"Sub only", "Bass: just the octave below, the dry gone", V{{"variant", 3}, {"range", 1}, {"tracking", 1}, {"dry", 0}, {"sub", 1}, {"tone", 250}}},
        {"Doom octaves", "Sound design: thick sub and octave on a riff", V{{"variant", 3}, {"sub", 1}, {"up", 0.6}, {"tone", 1500}, {"output", -3}}},
    };
    return p;
}

}  // namespace

const ModuleDescriptor& harmonizerDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(harmonizerBase(), kId, kName, labels, index);
    return d;
}
const ModuleDescriptor& octaverDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(octaverBase(), kId, kName, labels, index);
    return d;
}
ModuleProcessor* makeHarmonizerAs(const ModuleDescriptor& variant) noexcept {
    hann();
    return new (std::nothrow) Harmonizer(variant);
}
ModuleProcessor* makeOctaverAs(const ModuleDescriptor& variant) noexcept { return new (std::nothrow) Octaver(variant); }

std::span<const BuiltinPreset> newVoiceVariantPresets(std::string_view id) {
    if (id == kId) return shiftVoicePresets();
    return {};
}

void warmShiftVoices() noexcept { hann(); }

size_t harmonizerBytes(double sr) noexcept {
    const uint32_t lat = harmonizerLatency(sr);
    auto pow2 = [](size_t n) {
        size_t p = 1;
        while (p < n) p <<= 1;
        return p;
    };
    return sizeof(Harmonizer) + 4 * (pow2(static_cast<size_t>(lat + 4 * sr / kLowestHz) + 64) + 2 * pow2(lat + 2));
}
size_t octaverBytes(double sr) noexcept {
    size_t p = 1;
    while (p < static_cast<size_t>(0.05 * sr) + 16) p <<= 1;
    return sizeof(Octaver) + 4 * p;
}

}  // namespace caw::fx
