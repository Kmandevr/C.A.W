// Murmur (org.caw.pack.granular, the AutoStacc beta pack): granular texture over a recorded buffer of the input: freeze, scan, scatter, pitch and spray, on the shared grain engine.
#include "builtin_effects.h"
#include "builtin_pack.h"

#include <algorithm>
#include <cmath>
#include <new>
#include <vector>

#include "caw/detmath.hpp"
#include "caw/library/fastmath.hpp"
#include "caw/library/grain.hpp"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0). The input is recorded into a ring of `buffer` seconds (frozen: no longer
// recorded, the ring loops as it was). Grains (caw/library/grain.hpp) start `position` of the ring back from the
// newest frame (frozen: plus the scan, which moves through the ring at `scan` times real time), moved by up to
// `spray` either way; each is `size` long, one starts every 1/`density` seconds (or each `sync` division) moved by
// up to `jitter` of that, at `pitch` plus up to `spread` semitones (quantised to `scale`), backwards by `reverse`
// chance, panned up to `pan` either way. The cap on grains alive is the quality tier's (16, 32, 64); Eco reads
// linearly, Normal and High cubic. Each grain's level is 1 / (overlap x window mean) for grains that line up, eased
// toward 1 / sqrt of it as spray, spread and jitter decorrelate them, so a cloud keeps about the input's level.
// `feedback` records the wet (soft-clipped, 32 frames late) back with the input. `glide` smooths the pitch knob;
// `width` scales the wet's side. Seeded by `seed`: at reset and each time the song starts, from the seed and the
// beat it starts on, so a song plays the same cloud from the same place. No latency (a grain reads only the past).

namespace caw::fx {

namespace {

namespace grain = lib::grain;

constexpr double kMaxBuffer = 4.0;  // seconds
constexpr uint32_t kFeedbackDelay = 32, kFeedbackRing = 64;
constexpr uint32_t kOverview = 32;  // display: ring peaks

constexpr std::string_view kWindows[] = {"Hann", "Tukey", "Gaussian", "Expodec", "Rexpodec"};
constexpr std::string_view kScales[] = {"Off", "Chromatic", "Major", "Minor", "Pentatonic", "Octaves", "Fifths"};

enum MuParam : uint32_t {
    muBuffer, muPosition, muSpray, muSize, muDensity, muSync, muJitter, muPitch, muSpread, muScale, muReverse,
    muWindow, muPan, muGlide, muWidth, muFeedback, muFreeze, muScan, muSeed, muMix, muOutput, muCount
};

ParameterDescriptor& byHand(ParameterDescriptor& p) {
    p.automatable = p.modulatable = p.midiMappable = false;
    return p;
}

const ParamTable& murmurParams() {
    static const ParamTable t = [] {
        ParamTable p;
        byHand(p.num("buffer", "Buffer", 2.0, 0.5, kMaxBuffer, "s"));  // a new length starts the ring silent
        p.num("position", "Position", 0.1, 0.0, 1.0);
        p.num("spray", "Spray", 10.0, 0.0, 500.0, "ms");
        p.expo("size", "Size", 80.0, 1.0, 500.0, "ms");
        p.expo("density", "Density", 20.0, 0.5, 200.0, "Hz");
        p.pick("sync", "Sync", 0.0, kSyncDivisions);
        p.num("jitter", "Jitter", 0.2, 0.0, 1.0);
        p.num("pitch", "Pitch", 0.0, -24.0, 24.0, "st");
        p.num("spread", "Pitch spread", 0.0, 0.0, 24.0, "st");
        p.pick("scale", "Scale", 0.0, kScales);
        p.num("reverse", "Reverse", 0.0, 0.0, 1.0);
        p.pick("window", "Window", 0.0, kWindows);
        p.num("pan", "Pan spread", 0.3, 0.0, 1.0);
        p.num("glide", "Glide", 0.0, 0.0, 2000.0, "ms");
        p.num("width", "Width", 1.0, 0.0, 2.0);
        p.num("feedback", "Feedback", 0.0, 0.0, 0.95);
        p.pick("freeze", "Freeze", 0.0, kOffOn);
        p.num("scan", "Scan", 0.0, -2.0, 2.0);
        ParameterDescriptor& seed = p.num("seed", "Seed", 1.0, 0.0, 9999.0);
        seed.step = 1.0;
        seed.smoothingFrames = 0;
        p.num("mix", "Mix", 0.5, 0.0, 1.0);
        p.num("output", "Output", 0.0, -24.0, 24.0, "dB");
        return p;
    }();
    return t;
}

const ModuleDescriptor& murmurDescriptor() {
    static const ModuleDescriptor d = withCpu(
        effectDescriptor("org.caw.pack.granular", "Murmur", murmurParams(), 0, static_cast<uint32_t>((kMaxBuffer + 0.5) * 48000)),
        CpuClass::Medium);
    return d;
}

inline float finite0(float x) noexcept { return x == x && x - x == 0.0f ? x : 0.0f; }

class Murmur final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return murmurDescriptor(); }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        return ring_.prepare(static_cast<uint32_t>(std::ceil(kMaxBuffer * sr)) + 64);
    }
    void clearState() noexcept override {
        ring_.clear();
        filled_ = 0;
        held_ = false;
        eng_.clear();
        eng_.seed(seed_);
        for (float& f : fbL_) f = 0.0f;
        for (float& f : fbR_) f = 0.0f;
        t_ = 0;
        scan_ = 0.0;
        playing_ = false;
        first_ = true;
        dry_.reset(), wet_.reset();
    }
    uint64_t idleFrames() const noexcept override {
        if (freeze_) return ~0ull >> 2;  // a frozen cloud plays on over silence
        // The oldest frame a grain reads, and with feedback that many again for each pass to fall 110 dB.
        double frames = st_.position * ring_.length() + st_.sprayFrames + st_.sizeFrames + kFeedbackDelay + 0.05 * rate();
        if (feedback_ > 0.01) frames *= 1.0 + std::min(200.0, std::ceil(-5.5 / std::log10(feedback_)));
        return static_cast<uint64_t>(frames);
    }

    void control(uint32_t at) noexcept override {
        const double sr = rate();
        const int q = quality();
        eng_.setCap(grain::murmurCap(q));
        hermite_ = q > 0;
        if (first_ || !knobsUnchanged(knobs_, muCount, at)) {
            const uint32_t len = static_cast<uint32_t>(std::clamp(param(muBuffer, at), 0.5, kMaxBuffer) * sr);
            if (len != ring_.length()) ring_.setLength(len), filled_ = 0;
            position_ = std::clamp(param(muPosition, at), 0.0, 1.0);
            st_.sprayFrames = std::clamp(param(muSpray, at), 0.0, 500.0) * 0.001 * sr;
            st_.sizeFrames = std::clamp(param(muSize, at), 1.0, 500.0) * 0.001 * sr;
            const int sync = std::clamp(choice(muSync, at), 0, kSyncCount - 1);
            st_.interval = sync == 0 ? sr / std::clamp(param(muDensity, at), 0.5, 200.0)
                                     : std::max(1.0, syncSeconds(sync) * sr);
            st_.jitter = std::clamp(param(muJitter, at), 0.0, 1.0);
            pitchTarget_ = std::clamp(param(muPitch, at), -24.0, 24.0);
            st_.pitchSpread = std::clamp(param(muSpread, at), 0.0, 24.0);
            st_.scale = static_cast<uint32_t>(std::clamp(choice(muScale, at), 0, 6));
            st_.reverse = std::clamp(param(muReverse, at), 0.0, 1.0);
            st_.window = static_cast<uint32_t>(std::clamp(choice(muWindow, at), 0, 4));
            st_.panSpread = std::clamp(param(muPan, at), 0.0, 1.0);
            const double glide = std::clamp(param(muGlide, at), 0.0, 2000.0) * 0.001;
            glide_ = glide <= 0.0 ? 1.0 : 1.0 - detExp(-static_cast<double>(kControlFrames) / (glide * sr));
            width_ = static_cast<float>(std::clamp(param(muWidth, at), 0.0, 2.0));
            feedback_ = std::clamp(param(muFeedback, at), 0.0, 0.95);
            freeze_ = on(muFreeze, at);
            scanRate_ = std::clamp(param(muScan, at), -2.0, 2.0);
            seed_ = static_cast<uint32_t>(std::clamp(std::floor(param(muSeed, at) + 0.5), 0.0, 9999.0));
            const double mix = std::clamp(param(muMix, at), 0.0, 1.0), out = lib::dbToGain(param(muOutput, at));
            dryTarget_ = (1.0 - mix) * out, wetTarget_ = mix * out;
            // Each grain's level: grains that line up add as amplitudes, decorrelated ones as powers.
            const double overlap = std::max(1.0, grain::windows().mean[st_.window] * st_.sizeFrames / st_.interval);
            const double decor = std::clamp(2.0 * st_.sprayFrames / st_.sizeFrames + st_.pitchSpread / 6.0 + 0.5 * st_.jitter, 0.0, 1.0);
            st_.gain = static_cast<float>(detPow(overlap, -(1.0 - 0.5 * decor)));
            if (first_) eng_.seed(seed_), pitch_ = pitchTarget_;
        }
        // The song starting: a seed from the knob and the beat it starts on (to a 16th).
        double beat = 0.0;
        const bool playing = beatAt(at, beat);
        if (playing && !playing_)
            eng_.seed(hash32(seed_ * 0x9e3779b1u) ^ static_cast<uint32_t>(static_cast<int64_t>(std::floor(beat * 4.0 + 1e-6))));
        playing_ = playing;
        // Freeze holds the ring once it has been filled (a project or preset that starts frozen records it first).
        held_ = freeze_ && filled_ >= ring_.length();
        pitch_ += (pitchTarget_ - pitch_) * glide_;
        st_.pitch = pitch_;
        if (held_) {
            scan_ += scanRate_ * kControlFrames / std::max<uint32_t>(1, ring_.length());
            scan_ -= std::floor(scan_);
        } else {
            scan_ = 0.0;
        }
        double pos = position_ + scan_;
        if (held_ && (pos > 1.0 || pos < 0.0)) pos -= std::floor(pos);
        st_.position = std::clamp(pos, 0.0, 1.0);
        eng_.schedule(ring_.source(!held_), st_, kControlFrames);
        dry_.set(dryTarget_, kControlFrames), wet_.set(wetTarget_, kControlFrames);
        first_ = false;
    }

    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        float l[kControlFrames], r[kControlFrames], wl[kControlFrames] = {}, wr[kControlFrames] = {};
        const float fb = static_cast<float>(feedback_);
        for (uint32_t i = 0; i < n; ++i) {
            l[i] = finite0(inL[i]), r[i] = finite0(inR[i]);
            if (!held_) {
                const uint32_t k = static_cast<uint32_t>(t_ + i - kFeedbackDelay) & (kFeedbackRing - 1);
                ring_.write(l[i] + fb * fbL_[k], r[i] + fb * fbR_[k]);
            }
        }
        if (!held_) filled_ += n;
        const grain::Source src = ring_.source(!held_);
        if (hermite_) eng_.render<true>(src, wl, wr, n);
        else eng_.render<false>(src, wl, wr, n);
        const float side = width_;
        for (uint32_t i = 0; i < n; ++i) {
            const float m = 0.5f * (wl[i] + wr[i]), s = 0.5f * side * (wl[i] - wr[i]);
            const float a = m + s, b = m - s;
            const uint32_t k = static_cast<uint32_t>(t_ + i) & (kFeedbackRing - 1);
            fbL_[k] = static_cast<float>(lib::fastTanh(a)), fbR_[k] = static_cast<float>(lib::fastTanh(b));
            const double d = dry_.next(), w = wet_.next();
            outL[i] = static_cast<float>(d * l[i] + w * a);
            outR[i] = static_cast<float>(d * r[i] + w * b);
        }
        t_ += n;
    }

    uint32_t fillDisplay(float* out, bool watched) noexcept override {
        const uint32_t len = ring_.length();
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(eng_.alive());
        out[3] = static_cast<float>(eng_.cap());
        out[4] = static_cast<float>(eng_.takeDropped());
        out[5] = held_ ? 1.0f : 0.0f;
        out[6] = static_cast<float>(len / rate());
        out[7] = static_cast<float>(st_.position);
        out[8] = static_cast<float>(1000.0 * st_.sizeFrames / rate());
        out[9] = static_cast<float>(1000.0 * st_.interval / rate());
        const uint32_t shown = eng_.alive();
        out[10] = static_cast<float>(shown);
        // The ring's overview, oldest first: each of 32 stretches' peak, sampled every 64th frame (while watched).
        const uint32_t stretch = len / kOverview;
        for (uint32_t b = 0; b < kOverview; ++b) {
            float p = 0.0f;
            if (watched)
                for (uint32_t j = 0; j < stretch; j += 64) {
                    const uint32_t age = len - (b * stretch + j);
                    p = std::max({p, std::fabs(ring_.back(age, 0)), std::fabs(ring_.back(age, 1))});
                }
            out[11 + b] = p;
        }
        // Each grain: where it reads (0 newest .. 1 oldest), how far through its window, its pan and pitch.
        const uint32_t head = ring_.head();
        for (uint32_t g = 0; g < shown; ++g) {
            const grain::Grain& x = eng_.grain(g);
            double age = static_cast<double>(head) - x.pos;
            if (age < 0) age += len;
            float* o = out + 11 + kOverview + 4 * g;
            o[0] = static_cast<float>(std::clamp(age / len, 0.0, 1.0));
            o[1] = static_cast<float>(x.phase);
            o[2] = x.pan;
            o[3] = x.semitones;
        }
        return 11 + kOverview + 4 * shown;
    }

private:
    grain::Ring ring_;
    grain::Engine eng_;
    grain::Settings st_;
    double knobs_[muCount] = {};
    float fbL_[kFeedbackRing] = {}, fbR_[kFeedbackRing] = {};
    uint64_t t_ = 0;
    double position_ = 0.1, scan_ = 0.0, scanRate_ = 0.0, pitch_ = 0.0, pitchTarget_ = 0.0, glide_ = 1.0;
    double feedback_ = 0.0, dryTarget_ = 0.5, wetTarget_ = 0.5;
    float width_ = 1.0f;
    uint32_t seed_ = 1;
    uint64_t filled_ = 0;  // frames recorded since the ring last started silent
    bool freeze_ = false, held_ = false, hermite_ = true, playing_ = false, first_ = true;
    Ramp dry_, wet_;
};

ModuleProcessor* makeMurmur() noexcept { return new (std::nothrow) Murmur(); }

using V = std::vector<std::pair<std::string_view, double>>;

}  // namespace

void registerMurmur(ModuleRegistry& registry) { registry.add(murmurDescriptor(), &makeMurmur); }
size_t murmurBytes(double sr) noexcept {
    return sizeof(Murmur) + 2 * sizeof(float) * (static_cast<size_t>(std::ceil(kMaxBuffer * sr)) + 67);
}

const std::vector<BuiltinPreset>& murmurPresets() {
    static const std::vector<BuiltinPreset> p = {
        {"Soft cloud", "Sound design: a gentle cloud of the last moments, half wet", V{{"size", 120}, {"density", 25}, {"spray", 40}, {"pan", 0.5}}},
        {"Frozen pad", "Sound design: freeze a moment and hold it as a pad", V{{"freeze", 1}, {"size", 250}, {"density", 30}, {"spray", 80}, {"mix", 0.8}, {"window", 2}}},
        {"Shimmer up", "Sound design: an octave up, spread and fed back", V{{"pitch", 12}, {"size", 150}, {"density", 30}, {"feedback", 0.4}, {"spray", 30}, {"mix", 0.4}}},
        {"Octave scatter", "Sound design: grains spread over octaves", V{{"spread", 12}, {"scale", 5}, {"size", 90}, {"density", 35}, {"pan", 0.8}}},
        {"Reverse rain", "Sound design: short grains, mostly backwards", V{{"reverse", 0.8}, {"size", 40}, {"density", 60}, {"spray", 150}, {"position", 0.3}}},
        {"Vocal choir", "Vocals: the voice smeared into a soft choir", V{{"size", 180}, {"density", 22}, {"spread", 0.3}, {"spray", 25}, {"pan", 0.7}, {"mix", 0.4}}},
        {"Stutter grains", "Drums: sixteenth-note grains of the beat", V{{"sync", 3}, {"size", 60}, {"window", 3}, {"jitter", 0}, {"spray", 1}, {"mix", 0.6}}},
        {"Major sparkle", "Sound design: grains on a major scale, up an octave", V{{"spread", 12}, {"scale", 2}, {"pitch", 12}, {"size", 70}, {"density", 40}, {"mix", 0.5}}},
        {"Tape scan", "Sound design: a frozen buffer read slowly forward", V{{"freeze", 1}, {"scan", 0.25}, {"size", 200}, {"density", 15}, {"spray", 5}, {"mix", 1}}},
        {"Lo-fi dust", "Lo-fi: tiny, sparse, scattered grains", V{{"size", 8}, {"density", 120}, {"spray", 300}, {"jitter", 1}, {"window", 3}, {"mix", 0.35}}},
        {"Deep drone", "Sound design: two octaves down, long and wide", V{{"pitch", -24}, {"size", 400}, {"density", 12}, {"width", 1.6}, {"spray", 60}, {"mix", 0.7}}},
        {"Crow flock", "Sound design: high, quick, scattered chirps from the buffer", V{{"pitch", 19}, {"spread", 5}, {"size", 25}, {"density", 70}, {"window", 4}, {"pan", 1}, {"spray", 200}}},
    };
    return p;
}

}  // namespace caw::fx
