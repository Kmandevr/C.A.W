// The fx-space reverbs: a convolution reverb (generated or loaded impulse responses, partitioned FFT) and a shimmer reverb.
#include "builtin_fx_space.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <new>

#include "caw/library/convolver.hpp"
#include "caw/library/filter.hpp"
#include "caw/library/reverb.hpp"

// Original code (C.A.W. is Apache-2.0). The impulse responses are generated here from seeded noise, chirps,
// combs and grains, so there is nothing to license; a loaded WAV is the user's own.

namespace caw::fx {

// ---------- WAV impulse responses (untrusted bytes) ----------

namespace {

uint32_t le16(const uint8_t* p) noexcept { return static_cast<uint32_t>(p[0]) | static_cast<uint32_t>(p[1]) << 8; }
uint32_t le32(const uint8_t* p) noexcept { return le16(p) | le16(p + 2) << 16; }

// The frames a decoded IR keeps: 10 s, and at most 960,000 frames whatever its rate (so the saved state stays
// under 8 MB).
constexpr uint32_t kMaxIrFileFrames = 960000;
constexpr uint32_t kIrStateMagic = 0x31524943u;  // "CIR1"
constexpr uint32_t kIrStateHeader = 16;

}  // namespace

bool decodeIrWav(const uint8_t* bytes, size_t size, DecodedIr& out, const char*& error) {
    error = nullptr;
    out = DecodedIr{};
    if (!bytes || size < 12 || size > kMaxIrFileBytes) return error = "not a WAV file of a size an IR can be", false;
    if (std::memcmp(bytes, "RIFF", 4) != 0 || std::memcmp(bytes + 8, "WAVE", 4) != 0) return error = "not a RIFF WAVE file", false;
    uint32_t format = 0, channels = 0, rate = 0, bits = 0, align = 0;
    const uint8_t* data = nullptr;
    size_t dataSize = 0;
    size_t at = 12;
    for (int chunks = 0; at + 8 <= size && chunks < 64; ++chunks) {  // bounded: at most 64 chunks
        const uint8_t* c = bytes + at;
        const size_t len = le32(c + 4);
        if (len > size - at - 8) return error = "a chunk runs past the end of the file", false;
        if (std::memcmp(c, "fmt ", 4) == 0) {
            if (len < 16) return error = "the format chunk is too short", false;
            format = le16(c + 8);
            channels = le16(c + 10);
            rate = le32(c + 12);
            align = le16(c + 20);
            bits = le16(c + 22);
            if (format == 0xFFFE) {  // WAVE_FORMAT_EXTENSIBLE: the sub-format's first two bytes
                if (len < 40) return error = "the extensible format chunk is too short", false;
                format = le16(c + 32);
            }
        } else if (std::memcmp(c, "data", 4) == 0) {
            data = c + 8;
            dataSize = len;
        }
        at += 8 + len + (len & 1);
    }
    if (!data || !format) return error = "the file has no format or no data", false;
    const bool pcm = format == 1 && (bits == 16 || bits == 24 || bits == 32);
    const bool flt = format == 3 && (bits == 32 || bits == 64);
    if (!pcm && !flt) return error = "only 16, 24 or 32-bit PCM and 32 or 64-bit float WAVs are read", false;
    if (channels < 1 || channels > 16) return error = "the channel count is out of range", false;
    if (rate < 8000 || rate > 384000) return error = "the sample rate is out of range", false;
    const uint32_t bytesPer = bits / 8;
    if (align != channels * bytesPer) return error = "the block alignment does not match the format", false;
    size_t frames = dataSize / align;
    if (frames == 0) return error = "the file holds no frames", false;
    frames = std::min<size_t>(frames, std::min<size_t>(kMaxIrFileFrames, static_cast<size_t>(kMaxIrFileSeconds * rate)));
    try {
        out.left.resize(frames);
        out.right.resize(frames);
    } catch (...) {
        return error = "out of memory", false;
    }
    auto sample = [&](const uint8_t* p) -> float {
        double v = 0.0;
        if (flt && bits == 32) {
            float f;
            std::memcpy(&f, p, 4);
            v = f;
        } else if (flt) {
            double d;
            std::memcpy(&d, p, 8);
            v = d;
        } else if (bits == 16) {
            v = static_cast<int16_t>(le16(p)) / 32768.0;
        } else if (bits == 24) {
            int32_t s = static_cast<int32_t>(p[0] | p[1] << 8 | p[2] << 16);
            if (s & 0x800000) s -= 0x1000000;
            v = s / 8388608.0;
        } else {
            v = static_cast<int32_t>(le32(p)) / 2147483648.0;
        }
        if (!std::isfinite(v)) return 0.0f;
        return static_cast<float>(std::clamp(v, -8.0, 8.0));
    };
    for (size_t i = 0; i < frames; ++i) {
        const uint8_t* f = data + i * align;
        out.left[i] = sample(f);
        out.right[i] = channels > 1 ? sample(f + bytesPer) : out.left[i];
    }
    out.sampleRate = rate;
    out.channels = channels > 1 ? 2 : 1;
    return true;
}

namespace {

template <class T>
ModuleProcessor* make() noexcept {
    return new (std::nothrow) T();
}

// ---------- Convolution reverb ----------

enum ConvParam : uint32_t {
    kSource, kCDecay, kCSize, kCDamping, kCLength, kCReverse, kCPreDelay, kCLowCut, kCHighCut, kCWidth, kCMix, kConvCount
};
constexpr std::string_view kSources[] = {"Room",      "Hall",   "Plate",      "Spring", "Chamber",
                                         "Cathedral", "Gated",  "Metal tank", "Cloud",  "Loaded file"};
enum Source : int { kRoom, kHall, kPlate, kSpring, kChamber, kCathedral, kGated, kMetal, kCloud, kFile };
constexpr uint32_t kPartition = 512;          // frames: the head's partitions, and the latency
constexpr uint32_t kTailPartition = 4096;     // the tail's partitions
constexpr uint32_t kHeadFrames = kTailPartition - kPartition;  // the head covers the response up to here
constexpr double kMaxIrSeconds = 5.0;         // at High quality; Normal 3.5 s, Eco 2 s
constexpr double kConvMaxPreDelay = 0.5;
constexpr uint32_t kEnvPoints = 64;
constexpr uint32_t kGenPerStep = 4096;        // frames generated per control step while building
constexpr uint32_t kStagePerStep = 2;         // head partitions transformed per control step
constexpr uint32_t kTailStageEvery = 4;       // control steps per tail partition transformed (an 8,192-point FFT)

const ParamTable& convParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.pick("source", "Impulse", 1.0, kSources);
        p.expo("decay", "Decay", 2.2, 0.2, 10.0, "s");
        p.num("size", "Size / stretch", 0.5, 0.0, 1.0);
        p.num("damping", "Damping", 0.4, 0.0, 1.0);
        p.num("length", "Length", 1.0, 0.05, 1.0);
        p.pick("reverse", "Reverse", 0.0, kOffOn);
        p.num("predelay", "Pre-delay", 10.0, 0.0, 500.0, "ms");
        p.expo("low_cut", "Low cut", 80.0, 20.0, 2000.0, "Hz");
        p.expo("high_cut", "High cut", 14000.0, 1000.0, 20000.0, "Hz");
        p.num("width", "Width", 1.0, 0.0, 2.0);
        p.num("mix", "Mix", 0.3, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& convDescriptor() {
    static const ModuleDescriptor d = [] {
        ModuleDescriptor x = effectDescriptor("org.caw.convolver", "Convolver", convParams(), kPartition, kInfiniteTail);
        x.maxStateBytes = kIrStateHeader + 2u * 4u * kMaxIrFileFrames;
        return x;
    }();
    return d;
}

// What an impulse response is built from: a change to any of these builds a new one.
struct IrKey {
    int source = -1, reverse = 0, quality = -1;
    double decay = 0, size = 0, damping = 0, length = 0;
    uint32_t file = 0;
    bool operator==(const IrKey& o) const noexcept {
        return source == o.source && reverse == o.reverse && quality == o.quality && decay == o.decay && size == o.size &&
               damping == o.damping && length == o.length && file == o.file;
    }
};

// The generator of a built-in impulse response, one frame at a time (deterministic: seeded hashes, IEEE maths).
// A diffuse tail is decorrelated noise (left and right from different seeds) under an exponential decay (-60 dB
// at `decay` seconds) that builds up over the type's onset time, low-passed by a one-pole whose corner falls from
// the type's brightest frequency toward 600 Hz over the decay as `damping` says (highs die first, as in air);
// before it, a type's early reflections (seeded taps, falling in level). Spring is repeated rising chirps (a
// spring's dispersion: lows arrive first) over a little noise; Gated is a flat burst cut short; Metal tank is a
// short burst ringing through four combs; Cloud is a decaying shower of short sine grains on a pentatonic scale.
class IrGenerator {
public:
    static constexpr int kTaps = 24, kGrains = 16, kCombs = 4;
    bool prepare(double sr) noexcept {
        sr_ = sr;
        try {
            for (auto& c : comb_) c.assign(4096, 0.0f);
            while (comb_[0].size() < static_cast<size_t>(0.0154 * sr) + 4)
                for (auto& c : comb_) c.assign(c.size() * 2, 0.0f);
        } catch (...) {
            return false;
        }
        return true;
    }
    // Starts a response; returns its length in frames (at most `cap`).
    uint32_t start(const IrKey& k, const DecodedIr* file, uint32_t cap) noexcept {
        key_ = k;
        file_ = file;
        n_ = 0;
        stretch_ = detPow(2.0, 2.0 * (k.size - 0.5));  // 0.5 .. 2
        t60_ = std::clamp(k.decay, 0.2, 10.0);
        rng_ = 0x5eed0000u + static_cast<uint32_t>(k.source) * 7919u;
        double len = 0.0;
        // Per type: the brightest corner, the onset, the early reflections' window and count and level.
        switch (k.source) {
            case kRoom: fHi_ = 7000, build_ = 0.002, er0_ = 0.004, er1_ = 0.045, erCount_ = 14, erGain_ = 0.8; break;
            case kHall: fHi_ = 9000, build_ = 0.02, er0_ = 0.012, er1_ = 0.09, erCount_ = 10, erGain_ = 0.5; break;
            case kPlate: fHi_ = 16000, build_ = 0.0005, er0_ = er1_ = 0, erCount_ = 0, erGain_ = 0; break;
            case kChamber: fHi_ = 8000, build_ = 0.006, er0_ = 0.006, er1_ = 0.06, erCount_ = 20, erGain_ = 0.7; break;
            case kCathedral: fHi_ = 5000, build_ = 0.06, er0_ = 0.03, er1_ = 0.2, erCount_ = 8, erGain_ = 0.4; break;
            case kGated: fHi_ = 10000, build_ = 0.003, er0_ = er1_ = 0, erCount_ = 0, erGain_ = 0; break;
            case kSpring: fHi_ = 4500, build_ = 0.001, er0_ = er1_ = 0, erCount_ = 0, erGain_ = 0; break;
            case kMetal: fHi_ = 12000, build_ = 0.0, er0_ = er1_ = 0, erCount_ = 0, erGain_ = 0; break;
            default: fHi_ = 14000, build_ = 0.15, er0_ = er1_ = 0, erCount_ = 0, erGain_ = 0; break;  // Cloud, File
        }
        if (k.source == kFile) {
            len = file && file->sampleRate ? static_cast<double>(file->left.size()) * stretch_ / file->sampleRate : 0.0;
        } else if (k.source == kGated) {
            gate_ = 0.18 * stretch_;
            len = gate_ + 0.02;
        } else {
            len = t60_ + er1_ * stretch_ + 0.02;
        }
        uint32_t frames = static_cast<uint32_t>(std::min(len * std::clamp(k.length, 0.05, 1.0) * sr_, static_cast<double>(cap)));
        frames = std::max<uint32_t>(frames, k.source == kFile && len <= 0.0 ? 0u : 64u);
        len_ = frames;
        // Early reflections: seeded times in the window (scaled by size), sorted, different per side.
        for (int c = 0; c < 2; ++c) {
            for (int j = 0; j < erCount_; ++j) {
                const double u = unit(hash32(rng_ ^ (0x1000u + 97u * j + 13u * c)));
                tapAt_[c][j] = static_cast<uint32_t>((er0_ + (er1_ - er0_) * u * u) * stretch_ * sr_);
                const double sign = (hash32(rng_ ^ (0x2000u + 31u * j + c)) & 1u) ? 1.0 : -1.0;
                tapGain_[c][j] = sign * erGain_ * (1.0 - 0.6 * u);
            }
            for (int a = 1; a < erCount_; ++a)  // insertion sort by time
                for (int b = a; b > 0 && tapAt_[c][b] < tapAt_[c][b - 1]; --b) {
                    std::swap(tapAt_[c][b], tapAt_[c][b - 1]);
                    std::swap(tapGain_[c][b], tapGain_[c][b - 1]);
                }
            next_[c] = 0;
            lp_[c] = 0.0;
            chirp_[c] = 0.0;
            for (auto& g : grains_[c]) g.left = 0;
        }
        env_ = 1.0;
        envStep_ = detExp(-6.907755278982137 / (t60_ * sr_));
        buildLeft_ = 1.0;
        buildStep_ = build_ > 0.0 ? detExp(-1.0 / (build_ * stretch_ * sr_)) : 0.0;
        // Metal: four combs, their loop gains for the decay.
        static constexpr double kCombMs[kCombs] = {3.1, 4.3, 5.9, 7.7};
        for (int i = 0; i < kCombs; ++i) {
            combLen_[i] = std::max<size_t>(2, std::min(comb_[i].size() - 1, static_cast<size_t>(kCombMs[i] * 0.001 * stretch_ * sr_)));
            combGain_[i] = detPow(10.0, -3.0 * static_cast<double>(combLen_[i]) / (t60_ * sr_));
            std::fill(comb_[i].begin(), comb_[i].end(), 0.0f);
        }
        combPos_ = 0;
        lpK_ = 1.0;
        return len_;
    }
    uint32_t length() const noexcept { return len_; }

    // The next frame of the response.
    void next(float& outL, float& outR) noexcept {
        const double t = static_cast<double>(n_) / sr_;
        if ((n_ & 31u) == 0) {  // the damping corner, every 32 frames
            const double along = std::min(1.0, t / t60_);
            const double fc = fHi_ * detPow(600.0 / fHi_, along * std::clamp(key_.damping, 0.0, 1.0));
            lpK_ = 1.0 - detExp(-kTwoPi * std::min(fc, 0.45 * sr_) / sr_);
        }
        const double build = 1.0 - buildLeft_;
        buildLeft_ *= buildStep_;
        double v[2] = {0.0, 0.0};
        switch (key_.source) {
            case kSpring: spring(t, v); break;
            case kMetal: metal(v); break;
            case kCloud: cloud(build, v); break;
            case kFile: file(v); break;
            case kGated: {
                const double g = t < gate_ ? 1.0 : std::max(0.0, 1.0 - (t - gate_) / 0.015);
                for (int c = 0; c < 2; ++c) v[c] = noise(c) * g * build;
                break;
            }
            default:
                for (int c = 0; c < 2; ++c) v[c] = noise(c) * env_ * build;
                break;
        }
        for (int c = 0; c < 2; ++c) {
            if (key_.source != kFile || key_.damping > 0.0) v[c] = lp_[c] += (v[c] - lp_[c]) * lpK_;
            while (next_[c] < erCount_ && tapAt_[c][next_[c]] <= n_) {
                if (tapAt_[c][next_[c]] == n_) v[c] += tapGain_[c][next_[c]];
                ++next_[c];
            }
        }
        env_ *= envStep_;
        ++n_;
        outL = static_cast<float>(v[0]);
        outR = static_cast<float>(v[1]);
    }

private:
    static double unit(uint32_t h) noexcept { return static_cast<double>(h) * (1.0 / 4294967296.0); }
    double noise(int c) noexcept { return 2.0 * unit(hash32(rng_ ^ (n_ * 2u + static_cast<uint32_t>(c)) * 0x9E3779B1u)) - 1.0; }

    void spring(double t, double* v) noexcept {
        for (int c = 0; c < 2; ++c) {
            const double period = (0.028 + 0.009 * c) * stretch_;
            const double m = std::floor(t / period), tau = t - m * period, dur = 0.6 * period;
            double s = 0.0;
            if (tau < dur) {
                const double f = 150.0 + 3650.0 * tau / dur;  // rising: a spring's lows arrive first
                chirp_[c] += kTwoPi * f / sr_;
                if (chirp_[c] > kTwoPi) chirp_[c] -= kTwoPi;
                s = detSin(chirp_[c]) * detSin(kPi * tau / dur) * detExp(-6.907755278982137 * m * period / t60_);
            }
            v[c] = s + 0.15 * noise(c) * env_;
        }
    }
    void metal(double* v) noexcept {
        const double burst = n_ < static_cast<uint32_t>(0.005 * sr_) ? 1.0 : 0.0;
        for (int c = 0; c < 2; ++c) {
            const double x = burst * noise(c);
            double y = 0.0;
            for (int i = c; i < kCombs; i += 2) {  // left rings through combs 0 and 2, right through 1 and 3
                std::vector<float>& line = comb_[i];
                const size_t mask = line.size() - 1;
                const double d = line[(combPos_ - combLen_[i]) & mask];
                const double w = x + combGain_[i] * d;
                line[combPos_ & mask] = static_cast<float>(w < 1e-20 && w > -1e-20 ? 0.0 : w);
                y += d;
            }
            v[c] = 0.5 * y;
        }
        ++combPos_;
    }
    void cloud(double build, double* v) noexcept {
        static constexpr double kScale[5] = {0, 2, 4, 7, 9};
        const double density = 70.0 / sr_;  // grains a second
        for (int c = 0; c < 2; ++c) {
            if (unit(hash32(rng_ ^ (n_ * 4u + 1u + static_cast<uint32_t>(c)) * 0x85EBCA6Bu)) < density) {
                for (Grain& g : grains_[c])
                    if (g.left == 0) {
                        const uint32_t h = hash32(n_ * 3u + static_cast<uint32_t>(c) + 0x77u);
                        const double semis = kScale[h % 5] + 12.0 * ((h >> 3) % 3);
                        g.phase = 0.0;
                        g.inc = kTwoPi * 330.0 * detPow(2.0, semis / 12.0) / sr_;
                        g.len = g.left = static_cast<uint32_t>((0.03 + 0.09 * unit(hash32(h))) * stretch_ * sr_) + 1;
                        g.amp = 0.4 + 0.6 * unit(hash32(h ^ 0xABCDu));
                        break;
                    }
            }
            double s = 0.0;
            for (Grain& g : grains_[c]) {
                if (g.left == 0) continue;
                const double w = detSin(kPi * static_cast<double>(g.len - g.left) / g.len);
                s += detSin(g.phase) * w * g.amp;
                g.phase += g.inc;
                if (g.phase > kTwoPi) g.phase -= kTwoPi;
                --g.left;
            }
            v[c] = s * env_ * build;
        }
    }
    void file(double* v) noexcept {
        v[0] = v[1] = 0.0;
        if (!file_ || file_->left.empty() || !file_->sampleRate) return;
        const double pos = static_cast<double>(n_) * file_->sampleRate / (sr_ * stretch_);
        const size_t i = static_cast<size_t>(pos);
        if (i + 1 >= file_->left.size()) return;
        const double f = pos - static_cast<double>(i);
        v[0] = file_->left[i] + (file_->left[i + 1] - file_->left[i]) * f;
        v[1] = file_->right[i] + (file_->right[i + 1] - file_->right[i]) * f;
    }

    struct Grain {
        double phase = 0, inc = 0, amp = 0;
        uint32_t len = 1, left = 0;
    };
    IrKey key_;
    const DecodedIr* file_ = nullptr;
    double sr_ = 48000, stretch_ = 1, t60_ = 2, fHi_ = 9000, build_ = 0, er0_ = 0, er1_ = 0, erGain_ = 0, gate_ = 0.2;
    double env_ = 1, envStep_ = 1, buildLeft_ = 1, buildStep_ = 0, lpK_ = 1, lp_[2] = {}, chirp_[2] = {};
    int erCount_ = 0, next_[2] = {};
    uint32_t tapAt_[2][kTaps] = {}, n_ = 0, len_ = 0, rng_ = 0;
    double tapGain_[2][kTaps] = {};
    Grain grains_[2][kGrains];
    std::vector<float> comb_[kCombs];
    size_t combLen_[kCombs] = {}, combPos_ = 0;
    double combGain_[kCombs] = {};
};

// A convolution reverb: the input (after a pre-delay) convolved with an impulse response by two of the Library's
// partitioned FFT convolvers (the non-uniform partitioning of W. G. Gardner, "Efficient convolution without
// input-output delay", J. Audio Eng. Soc. 43(3), 1995, in its simplest two-size form): the first 3,584 frames of the
// response in 512-frame partitions (512 frames of latency, declared; the dry is delayed to match), the rest in
// 4,096-frame partitions, whose 4,096 frames of latency the head's span covers exactly, so the two join seamlessly
// and the long tail costs an eighth of the multiply-adds. The wet is then filtered (low and high cut), widened by
// mid/side and mixed. The response is one of the built-in generated ones or a loaded WAV, stretched by `size` (a
// file: its time and pitch, 0.5x .. 2x), trimmed to `length` (with a fade over its last tenth), optionally reversed
// and normalised to the same loudness. Changing what it is made of builds the new response in the background of the
// audio thread (every 16 frames: 4,096 frames generated, or two head partitions transformed, or every fourth step
// one tail partition: about a quarter of a second for a 5 s response) and crossfades to it over one partition, so
// turning a knob never clicks or blocks. Responses run up to 5 s at High quality, 3.5 s at Normal and 2 s at Eco.
class Convolver final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return convDescriptor(); }

    uint32_t stateVersion() const noexcept override { return 1; }
    bool saveState(uint8_t* dst, uint32_t capacity, uint32_t& written) const noexcept override {
        written = 0;
        if (file_.left.empty()) return true;
        const uint32_t frames = static_cast<uint32_t>(file_.left.size()), ch = file_.channels > 1 ? 2 : 1;
        const uint64_t need = kIrStateHeader + static_cast<uint64_t>(frames) * ch * 4u;
        if (!dst || need > capacity) return false;
        auto put = [&](uint32_t at, uint32_t v) { for (int k = 0; k < 4; ++k) dst[at + k] = static_cast<uint8_t>(v >> (8 * k)); };
        put(0, kIrStateMagic);
        put(4, file_.sampleRate);
        put(8, frames);
        put(12, ch);
        uint8_t* p = dst + kIrStateHeader;
        for (uint32_t i = 0; i < frames; ++i) {
            std::memcpy(p, &file_.left[i], 4), p += 4;
            if (ch == 2) std::memcpy(p, &file_.right[i], 4), p += 4;
        }
        written = static_cast<uint32_t>(need);
        return true;
    }
    // On the control thread when the chain is built (before it plays): the IR's own saved form, or a WAV file's
    // bytes (decoded here, off the audio thread, every size checked). An empty state: no file.
    bool loadState(const uint8_t* src, uint32_t size, uint32_t version) noexcept override {
        if (version != 1) return false;
        DecodedIr ir;
        if (size == 0) {
            file_ = DecodedIr{};
            ++fileVersion_;
            return true;
        }
        if (!src) return false;
        if (size >= kIrStateHeader && le32(src) == kIrStateMagic) {
            const uint32_t rate = le32(src + 4), frames = le32(src + 8), ch = le32(src + 12);
            if (rate < 8000 || rate > 384000 || frames == 0 || frames > kMaxIrFileFrames || (ch != 1 && ch != 2)) return false;
            if (static_cast<uint64_t>(size) != kIrStateHeader + static_cast<uint64_t>(frames) * ch * 4u) return false;
            try {
                ir.left.resize(frames);
                ir.right.resize(frames);
            } catch (...) {
                return false;
            }
            const uint8_t* p = src + kIrStateHeader;
            for (uint32_t i = 0; i < frames; ++i) {
                float l, r;
                std::memcpy(&l, p, 4), p += 4;
                if (ch == 2) std::memcpy(&r, p, 4), p += 4;
                else r = l;
                ir.left[i] = std::isfinite(l) ? std::clamp(l, -8.0f, 8.0f) : 0.0f;
                ir.right[i] = std::isfinite(r) ? std::clamp(r, -8.0f, 8.0f) : 0.0f;
            }
            ir.sampleRate = rate;
            ir.channels = ch;
        } else {
            const char* error = nullptr;
            if (!decodeIrWav(src, size, ir, error)) return false;
        }
        file_ = std::move(ir);
        ++fileVersion_;
        return true;
    }

protected:
    bool prepare(double sr, uint32_t) noexcept override {
        try {
            maxFrames_ = static_cast<uint32_t>(kMaxIrSeconds * sr);
            conv_.prepare(kPartition, kHeadFrames);
            tail_.prepare(kTailPartition, maxFrames_ - kHeadFrames);
            irL_.assign(maxFrames_, 0.0f);
            irR_.assign(maxFrames_, 0.0f);
            stageL_.assign(kTailPartition, 0.0f);
            stageR_.assign(kTailPartition, 0.0f);
            tailL_.assign(kControlFrames, 0.0f);
            tailR_.assign(kControlFrames, 0.0f);
            dryL_.assign(kPartition, 0.0f);
            dryR_.assign(kPartition, 0.0f);
            wetL_.assign(kControlFrames, 0.0f);
            wetR_.assign(kControlFrames, 0.0f);
            if (!pre_[0].prepare(kConvMaxPreDelay + 0.01, sr) || !pre_[1].prepare(kConvMaxPreDelay + 0.01, sr)) return false;
            if (!gen_.prepare(sr)) return false;
        } catch (...) {
            return false;
        }
        conv_.silence();
        tail_.silence();
        built_ = IrKey{};
        phase_ = kIdle;
        return true;
    }
    void clearState() noexcept override {
        conv_.clear();
        tail_.clear();
        pre_[0].clear(), pre_[1].clear();
        std::fill(dryL_.begin(), dryL_.end(), 0.0f);
        std::fill(dryR_.begin(), dryR_.end(), 0.0f);
        dryPos_ = 0;
        for (auto& f : low_) f.clear();
        for (auto& f : high_) f.clear();
        pre_d_.reset(), mix_.reset(), width_.reset();
        wetPeak_ = 0.0;
    }
    uint64_t idleFrames() const noexcept override {
        return static_cast<uint64_t>((preDelay_ + 0.1) * rate()) + kPartition + irFrames_;
    }
    void control(uint32_t at) noexcept override {
        // Recursive states flushed once per control block (on the grid: the same at any block size).
        for (int c = 0; c < 2; ++c) low_[c].flushDenormals(), high_[c].flushDenormals();
        const double sr = rate();
        IrKey k;
        k.source = std::clamp(choice(kSource, at), 0, 9);
        k.decay = param(kCDecay, at);
        k.size = std::clamp(param(kCSize, at), 0.0, 1.0);
        k.damping = std::clamp(param(kCDamping, at), 0.0, 1.0);
        k.length = std::clamp(param(kCLength, at), 0.05, 1.0);
        k.reverse = on(kCReverse, at) ? 1 : 0;
        k.quality = quality();
        k.file = k.source == kFile ? fileVersion_ : 0;
        source_ = k.source;
        build(k);
        preDelay_ = std::clamp(param(kCPreDelay, at), 0.0, 500.0) * 0.001;
        pre_d_.set(preDelay_ * sr, kControlFrames);
        const double lowCut = param(kCLowCut, at), highCut = param(kCHighCut, at);
        useLow_ = lowCut > 20.5;
        useHigh_ = highCut < 19999.0;
        for (auto& f : low_) f.set(lowCut, 0.70710678118654752, sr);
        for (auto& f : high_) f.set(highCut, 0.70710678118654752, sr);
        width_.set(std::clamp(param(kCWidth, at), 0.0, 2.0), kControlFrames);
        mix_.set(std::clamp(param(kCMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        float pl[kControlFrames], pr[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) {
            pre_[0].write(inL[i]);
            pre_[1].write(inR[i]);
            const double d = pre_d_.next();
            pl[i] = d < 1.0 ? inL[i] : static_cast<float>(pre_[0].read(d));
            pr[i] = d < 1.0 ? inR[i] : static_cast<float>(pre_[1].read(d));
        }
        conv_.process(pl, pr, wetL_.data(), wetR_.data(), n);
        tail_.process(pl, pr, tailL_.data(), tailR_.data(), n);
        for (uint32_t i = 0; i < n; ++i) {
            // The dry, delayed by the convolver's latency so the two line up.
            const double xl = dryL_[dryPos_], xr = dryR_[dryPos_];
            dryL_[dryPos_] = inL[i];
            dryR_[dryPos_] = inR[i];
            dryPos_ = (dryPos_ + 1) % kPartition;
            double l = static_cast<double>(wetL_[i]) + tailL_[i], r = static_cast<double>(wetR_[i]) + tailR_[i];
            if (useLow_) l = low_[0].highpass(l), r = low_[1].highpass(r);
            if (useHigh_) l = high_[0].lowpass(l), r = high_[1].lowpass(r);
            const double mid = 0.5 * (l + r), side = 0.5 * (l - r) * width_.next();
            l = mid + side, r = mid - side;
            wetPeak_ = std::max(wetPeak_, std::max(std::fabs(l), std::fabs(r)));
            const double m = mix_.next();
            outL[i] = static_cast<float>(xl + (l - xl) * m);
            outR[i] = static_cast<float>(xr + (r - xr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(lib::gainToDb(wetPeak_));
        out[3] = static_cast<float>(kPartition * 1000.0 / rate());
        out[4] = static_cast<float>(irFrames_ / rate());
        out[5] = phase_ == kIdle ? 1.0f : static_cast<float>(progress());
        out[6] = static_cast<float>(source_);
        out[7] = file_.left.empty() ? 0.0f : 1.0f;
        out[8] = static_cast<float>(kEnvPoints);
        for (uint32_t j = 0; j < kEnvPoints; ++j) out[9 + j] = env_[j];
        wetPeak_ = 0.0;
        return 9 + kEnvPoints;
    }

private:
    enum Phase { kIdle, kGenerate, kStage };

    double progress() const noexcept {
        if (len_ == 0) return 1.0;
        const double total = 2.0 * len_;
        const double done = phase_ == kGenerate ? genAt_ : len_ + std::min<double>(len_, static_cast<double>(stageAt_) * kPartition +
                                                                                          static_cast<double>(tailAt_) * kTailPartition);
        return std::clamp(done / total, 0.0, 1.0);
    }
    uint32_t capFrames(int q) const noexcept {
        const double s = q == kQualityHigh ? kMaxIrSeconds : q == kQualityEco ? 2.0 : 3.5;
        return std::min(maxFrames_, static_cast<uint32_t>(s * rate()));
    }

    // One step of building the response for `k`: start (when it changed and nothing is mid-flight), generate,
    // then transform its partitions; the last commits it.
    void build(const IrKey& k) noexcept {
        if (phase_ == kIdle) {
            if (k == built_ || !conv_.canStage() || !tail_.canStage()) return;
            target_ = k;
            len_ = gen_.start(k, &file_, capFrames(k.quality));
            genAt_ = 0;
            energy_ = 0.0;
            phase_ = kGenerate;
        }
        if (phase_ == kGenerate) {
            const uint32_t to = std::min(len_, genAt_ + kGenPerStep);
            for (; genAt_ < to; ++genAt_) {
                gen_.next(irL_[genAt_], irR_[genAt_]);
                energy_ += static_cast<double>(irL_[genAt_]) * irL_[genAt_] + static_cast<double>(irR_[genAt_]) * irR_[genAt_];
            }
            if (genAt_ < len_) return;
            // Same loudness whatever the response: both sides' energy together to 0.5 (about -6 dB on noise).
            norm_ = energy_ > 1e-12 ? std::sqrt(0.5 / energy_) : 0.0;
            parts_ = (std::min(len_, kHeadFrames) + kPartition - 1) / kPartition;
            tailParts_ = len_ > kHeadFrames ? (len_ - kHeadFrames + kTailPartition - 1) / kTailPartition : 0;
            stageAt_ = tailAt_ = 0;
            stepCount_ = 0;
            for (float& e : peaks_) e = 0.0f;
            phase_ = kStage;
            return;
        }
        // The head's partitions two at a time, then the tail's, one every kTailStageEvery steps.
        for (uint32_t s = 0; s < kStagePerStep && stageAt_ < parts_; ++s, ++stageAt_) {
            fillStage(stageAt_ * kPartition, kPartition, kHeadFrames);
            conv_.stage(stageAt_, stageL_.data(), stageR_.data(), kPartition);
        }
        if (stageAt_ >= parts_ && tailAt_ < tailParts_ && ++stepCount_ % kTailStageEvery == 0) {
            fillStage(kHeadFrames + tailAt_ * kTailPartition, kTailPartition, len_);
            tail_.stage(tailAt_, stageL_.data(), stageR_.data(), kTailPartition);
            ++tailAt_;
        }
        if (stageAt_ < parts_ || tailAt_ < tailParts_) return;
        conv_.commit(parts_);
        tail_.commit(tailParts_);
        built_ = target_;
        irFrames_ = len_;
        for (uint32_t j = 0; j < kEnvPoints; ++j) env_[j] = static_cast<float>(lib::gainToDb(peaks_[j]));
        phase_ = kIdle;
    }
    // `count` frames of the normalised, faded (and maybe reversed) response from frame `from` into stageL_/R_,
    // nothing at or past `end`; their peaks into the envelope.
    void fillStage(uint32_t from, uint32_t count, uint32_t end) noexcept {
        {
            const uint32_t fadeFrom = len_ - len_ / 10;
            for (uint32_t i = 0; i < count; ++i) {
                const uint32_t at = from + i;
                if (at >= len_ || at >= end) {
                    stageL_[i] = stageR_[i] = 0.0f;
                    continue;
                }
                const uint32_t src = target_.reverse ? len_ - 1 - at : at;
                const double fade = at >= fadeFrom && len_ > 10 ? static_cast<double>(len_ - at) / (len_ - fadeFrom) : 1.0;
                const double g = norm_ * fade;
                stageL_[i] = static_cast<float>(irL_[src] * g);
                stageR_[i] = static_cast<float>(irR_[src] * g);
                const uint32_t j = static_cast<uint32_t>(static_cast<uint64_t>(at) * kEnvPoints / len_);
                peaks_[j] = std::max(peaks_[j], std::max(std::fabs(stageL_[i]), std::fabs(stageR_[i])));
            }
        }
    }

    lib::PartitionedConvolver conv_, tail_;  // the head (512-frame partitions) and the tail (4,096)
    IrGenerator gen_;
    DecodedIr file_;
    uint32_t fileVersion_ = 1, maxFrames_ = 0, len_ = 0, genAt_ = 0, parts_ = 0, stageAt_ = 0, irFrames_ = 0;
    uint32_t tailParts_ = 0, tailAt_ = 0, stepCount_ = 0;
    IrKey built_, target_;
    Phase phase_ = kIdle;
    double energy_ = 0.0, norm_ = 0.0, preDelay_ = 0.01, wetPeak_ = 0.0;
    std::vector<float> irL_, irR_, stageL_, stageR_, dryL_, dryR_, wetL_, wetR_, tailL_, tailR_;
    uint32_t dryPos_ = 0;
    ModLine pre_[2];
    lib::Svf low_[2], high_[2];
    Ramp pre_d_, mix_, width_;
    bool useLow_ = true, useHigh_ = true;
    int source_ = kHall;
    float peaks_[kEnvPoints] = {}, env_[kEnvPoints] = {};
};

// ---------- Shimmer reverb ----------

enum ShimmerParam : uint32_t {
    kSSize, kSDecay, kSPreDelay, kSDamping, kSShift, kSAmount, kSTone, kSLowCut, kSMod, kSWidth, kSMix, kShimmerCount
};
constexpr std::string_view kShifts[] = {"+12", "+7", "+5", "+19", "+24", "-12"};
constexpr double kShiftSemis[] = {12, 7, 5, 19, 24, -12};

const ParamTable& shimmerParams() {
    static const ParamTable t = [] {
        ParamTable p;
        p.num("size", "Size", 0.75, 0.0, 1.0);
        p.expo("decay", "Decay", 6.0, 0.5, 30.0, "s");
        p.num("predelay", "Pre-delay", 20.0, 0.0, 500.0, "ms");
        p.num("damping", "Damping", 0.4, 0.0, 1.0);
        p.pick("shift", "Shift", 0.0, kShifts);
        p.num("amount", "Shimmer", 0.5, 0.0, 1.0);
        p.expo("tone", "Shimmer tone", 7000.0, 1000.0, 16000.0, "Hz");
        p.expo("low_cut", "Shimmer low cut", 300.0, 50.0, 2000.0, "Hz");
        p.num("mod", "Modulation", 0.4, 0.0, 1.0);
        p.num("width", "Width", 1.0, 0.0, 2.0);
        p.num("mix", "Mix", 0.35, 0.0, 1.0);
        return p;
    }();
    return t;
}
const ModuleDescriptor& shimmerDescriptor() {
    static const ModuleDescriptor d = effectDescriptor("org.caw.shimmer", "Shimmer", shimmerParams(), 0, kInfiniteTail);
    return d;
}

// Shimmer: the Library's 8-line FDN reverb (as org.caw.reverb.pro) with its own wet fed back into its input
// through a pitch shifter (+12 or +7 semitones, ...; a two-tap delay-line shifter with a 70 ms window), band-limited
// (low cut, then `tone`) and gently saturated, so each round of the tail climbs an octave or a fifth and the
// highest rounds fade out above `tone`: the "angelic" pad trails of Eno and Lanois's records, after the Eventide
// H3000 patches. `amount` sets the loop gain (at most 0.6, scaled down for tails past 4 s, inside a tanh, so it
// can never run away).
class Shimmer final : public EffectBase {
public:
    const ModuleDescriptor& descriptor() const noexcept override { return shimmerDescriptor(); }

protected:
    bool prepare(double sr, uint32_t maxFrames) noexcept override {
        try {
            reverb_.prepare(sr, static_cast<int>(maxFrames), 0.5);
        } catch (...) {
            return false;
        }
        return shift_[0].prepare(0.07, sr) && shift_[1].prepare(0.07, sr);
    }
    void clearState() noexcept override {
        reverb_.clear();
        shift_[0].clear(), shift_[1].clear();
        for (auto& f : low_) f.clear();
        for (auto& f : high_) f.clear();
        fb_[0] = fb_[1] = 0.0;
        amount_.reset(), mix_.reset();
        wetPeak_ = loopPeak_ = 0.0;
    }
    uint64_t idleFrames() const noexcept override { return static_cast<uint64_t>((settings_.preDelay + 0.3) * rate()); }
    void control(uint32_t at) noexcept override {
        // Recursive states flushed once per control block (on the grid: the same at any block size).
        for (int c = 0; c < 2; ++c) low_[c].flushDenormals(), high_[c].flushDenormals();
        const double sr = rate();
        lib::ReverbSettings s;
        s.size = param(kSSize, at);
        s.decay = param(kSDecay, at);
        s.preDelay = std::clamp(param(kSPreDelay, at), 0.0, 500.0) * 0.001;
        s.damping = param(kSDamping, at);
        s.width = param(kSWidth, at);
        s.mix = 1.0;
        s.modulation = param(kSMod, at);
        s.modRate = 0.6;
        reverb_.setLight(quality() == kQualityEco);
        if (!set_ || s.size != settings_.size || s.decay != settings_.decay || s.preDelay != settings_.preDelay ||
            s.damping != settings_.damping || s.width != settings_.width || s.modulation != settings_.modulation) {
            reverb_.set(s);
            settings_ = s;
            set_ = true;
        }
        semis_ = kShiftSemis[std::clamp(choice(kSShift, at), 0, 5)];
        const double ratio = detPow(2.0, semis_ / 12.0);
        shift_[0].setRatio(ratio), shift_[1].setRatio(ratio);
        for (auto& f : low_) f.set(param(kSLowCut, at), 0.70710678118654752, sr);
        for (auto& f : high_) f.set(param(kSTone, at), 0.70710678118654752, sr);
        // The loop's gain: up to 0.6, less for tails past 4 s (a longer tail holds more energy per round), so even
        // the longest, fullest setting settles instead of swelling into the saturator.
        const double decayScale = settings_.decay > 4.0 ? std::sqrt(4.0 / settings_.decay) : 1.0;
        amount_.set(0.6 * decayScale * std::clamp(param(kSAmount, at), 0.0, 1.0), kControlFrames);
        mix_.set(std::clamp(param(kSMix, at), 0.0, 1.0), kControlFrames);
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        for (uint32_t i = 0; i < n; ++i) {
            const double xl = inL[i], xr = inR[i];
            const double a = amount_.next();
            double loop[2];
            for (int c = 0; c < 2; ++c) {
                const double band = high_[c].lowpass(low_[c].highpass(fb_[c]));
                loop[c] = lib::fastTanh(a * shift_[c].process(band));
                loopPeak_ = std::max(loopPeak_, std::fabs(loop[c]));
            }
            float wl = static_cast<float>(xl + loop[0]), wr = static_cast<float>(xr + loop[1]);
            reverb_.process(wl, wr);
            fb_[0] = wl, fb_[1] = wr;
            wetPeak_ = std::max(wetPeak_, std::max(std::fabs(static_cast<double>(wl)), std::fabs(static_cast<double>(wr))));
            const double m = mix_.next();
            outL[i] = static_cast<float>(xl + (wl - xl) * m);
            outR[i] = static_cast<float>(xr + (wr - xr) * m);
        }
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(lib::gainToDb(wetPeak_));
        out[3] = static_cast<float>(lib::gainToDb(loopPeak_));
        out[4] = static_cast<float>(semis_);
        out[5] = static_cast<float>(settings_.decay);
        out[6] = static_cast<float>(settings_.size);
        wetPeak_ = loopPeak_ = 0.0;
        return 7;
    }

private:
    lib::Reverb reverb_;
    lib::ReverbSettings settings_;
    bool set_ = false;
    GrainShifter shift_[2];
    lib::Svf low_[2], high_[2];
    Ramp amount_, mix_;
    double fb_[2] = {}, semis_ = 12.0, wetPeak_ = 0.0, loopPeak_ = 0.0;
};

}  // namespace

void registerFxSpaceReverb(ModuleRegistry& registry) {
    registry.add(convDescriptor(), &make<Convolver>);
    registry.add(shimmerDescriptor(), &make<Shimmer>);
}

}  // namespace caw::fx
