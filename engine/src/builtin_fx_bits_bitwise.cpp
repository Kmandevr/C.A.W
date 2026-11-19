// Bit distortion's 1.1.0 "Bitwise" variant: each sample as a signed integer word, shifted, XORed and ANDed with masks, with its bit lanes for the display.
#include "builtin_effects.h"

#include <algorithm>
#include <cmath>
#include <deque>
#include <new>
#include <span>
#include <vector>

#include "fx_merged.h"
#include "presets.h"

// Original code (C.A.W. is Apache-2.0), C.A.W's own design (sound plan 2026-11-19: "Bitwise (shift, XOR, AND masks;
// lanes drawn flipping)"). Variant 1 of org.caw.bits, its own table plus `variant`.
// Each sample (held to -1..1) is rounded to a signed word of `bits` bits (2..16). The word is shifted (left: louder,
// wrapping round past full scale; right: coarser), wrapped back to its bits, XORed with `xor` and ANDed with `and`
// (both 16-bit masks, their top `bits` bits used, so a mask means the same at every word size), and read back as
// a sample; a word that rounds to 0 stays 0 (silence stays silence, with no offset from a mask). All of it integer
// arithmetic, the same on every platform. The display counts how often each of the
// left side's 16 lanes flipped since the last publish (its rate, 0..1) and shows the latest word's bits.

namespace caw::fx {

namespace {

constexpr std::string_view kBitsId = "org.caw.bits";
constexpr std::string_view kBitsName = "Bit distortion";
enum BitwiseParam : uint32_t { kWBits, kWShift, kWXor, kWAnd, kWOutput, kWMix, kWCount };

const ParamTable& bitwiseParams() {
    static const ParamTable t = [] {
        ParamTable p;
        auto whole = [&](const char* id, const char* name, double def, double lo, double hi) {
            ParameterDescriptor& d = p.num(id, name, def, lo, hi);
            d.step = 1.0;
            d.smoothingFrames = 0;  // whole numbers jump
        };
        whole("bits", "Bits", 12.0, 2.0, 16.0);
        whole("shift", "Shift", 0.0, -8.0, 8.0);
        whole("xor", "XOR mask", 0.0, 0.0, 65535.0);
        whole("and", "AND mask", 65535.0, 0.0, 65535.0);
        p.num("output", "Output", 0.0, -24.0, 12.0, "dB");
        p.num("mix", "Mix", 1.0, 0.0, 1.0);
        return p;
    }();
    return t;
}

class Bitwise : public EffectBase {
public:
    explicit Bitwise(const ModuleDescriptor& d) noexcept : d_(d) {}
    const ModuleDescriptor& descriptor() const noexcept override { return d_; }

protected:
    bool prepare(double, uint32_t) noexcept override { return true; }
    void clearState() noexcept override {
        outRamp_.reset();
        mixRamp_.reset();
        for (uint32_t& f : flips_) f = 0;
        frames_ = 0;
        prev_ = last_ = 0;
    }
    void control(uint32_t at) noexcept override {
        bits_ = std::clamp(static_cast<int>(param(kWBits, at) + 0.5), 2, 16);
        shift_ = std::clamp(static_cast<int>(std::lround(param(kWShift, at))), -8, 8);
        xor16_ = static_cast<uint32_t>(std::clamp(param(kWXor, at), 0.0, 65535.0) + 0.5);
        and16_ = static_cast<uint32_t>(std::clamp(param(kWAnd, at), 0.0, 65535.0) + 0.5);
        const int drop = 16 - bits_;
        mask_ = (1u << bits_) - 1u;
        sign_ = 1u << (bits_ - 1);
        xor_ = (xor16_ >> drop) & mask_;
        and_ = (and16_ >> drop) & mask_;
        left_ = shift_ > 0 ? shift_ : 0;
        right_ = shift_ < 0 ? -shift_ : 0;
        scale_ = static_cast<double>(sign_ - 1u);
        inv_ = 1.0 / scale_;  // full scale back to 1
        outRamp_.set(lib::dbToGain(param(kWOutput, at)), kControlFrames);
        mixRamp_.set(std::clamp(param(kWMix, at), 0.0, 1.0), kControlFrames);
    }
    // One sample through the word: its integer value after the shift and masks, as a signed bits_-bit number.
    int32_t word(double x) const noexcept {
        x = x == x ? std::clamp(x, -1.0, 1.0) : 0.0;
        const double t = x * scale_;
        const int32_t q = static_cast<int32_t>(t + (t >= 0.0 ? 0.5 : -0.5));
        uint32_t u = (static_cast<uint32_t>(q) << left_);
        u = static_cast<uint32_t>(static_cast<int32_t>(u) >> right_);  // arithmetic (C++20)
        u = ((u & mask_) ^ xor_) & and_;
        u = q == 0 ? 0u : u;  // silence stays silence (a XOR mask would make it a constant): it sleeps
        return static_cast<int32_t>((u ^ sign_) - sign_);  // sign-extended from bits_
    }
    void run(const float* inL, const float* inR, float* outL, float* outR, uint32_t n) noexcept override {
        const int up = 16 - bits_;  // the lanes are counted on the 16-bit word (a coarser word's top lanes)
        for (uint32_t i = 0; i < n; ++i) {
            const int32_t wl = word(inL[i]), wr = word(inR[i]);
            const uint32_t lanes = (static_cast<uint32_t>(wl) << up) & 0xffffu;
            const uint32_t changed = lanes ^ prev_;
            for (int b = 0; b < 16; ++b) flips_[b] += (changed >> b) & 1u;
            prev_ = lanes;
            const double o = outRamp_.next(), m = mixRamp_.next();
            const double yl = wl * inv_ * o, yr = wr * inv_ * o;
            outL[i] = static_cast<float>(inL[i] + (yl - inL[i]) * m);
            outR[i] = static_cast<float>(inR[i] + (yr - inR[i]) * m);
        }
        last_ = prev_;
        frames_ += n;
    }
    uint32_t fillDisplay(float* out, bool) noexcept override {
        out[0] = inPeakDb();
        out[1] = outPeakDb();
        out[2] = static_cast<float>(bits_);
        out[3] = static_cast<float>(shift_);
        out[4] = static_cast<float>(xor16_);
        out[5] = static_cast<float>(and16_);
        const double per = frames_ ? 1.0 / static_cast<double>(frames_) : 0.0;
        for (int b = 0; b < 16; ++b) {  // lane 0 the least significant
            out[6 + b] = static_cast<float>(flips_[b] * per);   // how often it flipped (0..1 a frame)
            out[22 + b] = static_cast<float>((last_ >> b) & 1u);  // the latest word's bit
            flips_[b] = 0;
        }
        frames_ = 0;
        return 38;
    }

private:
    const ModuleDescriptor& d_;
    int bits_ = 12, shift_ = 0, left_ = 0, right_ = 0;
    uint32_t xor16_ = 0, and16_ = 65535, mask_ = 4095, sign_ = 2048, xor_ = 0, and_ = 4095;
    double scale_ = 2047, inv_ = 1.0 / 2047;
    Ramp outRamp_, mixRamp_;
    uint32_t flips_[16] = {}, frames_ = 0, prev_ = 0, last_ = 0;
};

using V = std::vector<std::pair<std::string_view, double>>;
BuiltinPreset preset(const char* name, const char* description, V values) {
    values.emplace_back("variant", 1.0);
    return {name, description, std::move(values)};
}

const std::vector<BuiltinPreset>& presets() {
    static const std::vector<BuiltinPreset> p = {
        preset("Sign flip grit", "Lo-fi: the low bits inverted, a buzzy fizz under the sound", {{"bits", 12}, {"xor", 0x000f << 4}}),
        preset("Wrap around", "Sound design: shifted up past full scale, folding round", {{"bits", 16}, {"shift", 2}, {"output", -6}}),
        preset("Coarse steps", "Lo-fi: shifted down into a few big steps", {{"bits", 10}, {"shift", -4}}),
        preset("Top bits only", "Drums: only the top six bits kept, a gated crunch", {{"bits", 16}, {"and", 0xfc00}}),
        preset("Bit mangle bass", "Bass: the middle bits flipped, blended under the clean", {{"bits", 14}, {"xor", 0x0ff0}, {"mix", 0.35}}),
        preset("Broken radio", "Vocals: a narrow word with odd lanes masked", {{"bits", 8}, {"and", 0xaaff}, {"mix", 0.6}}),
        preset("Glitch lead", "Sound design: XOR on the upper lanes, a squealing edge", {{"bits", 12}, {"xor", 0x3000}, {"output", -6}}),
        preset("Mix bus 8-bit", "Mixing: a faint 8-bit layer under the mix", {{"bits", 8}, {"mix", 0.15}}),
        preset("Square maker", "Guitar: two bits, nearly a square, blended", {{"bits", 2}, {"mix", 0.3}, {"output", -12}}),
    };
    return p;
}

const ModuleDescriptor& bitwiseBase() {
    static const ModuleDescriptor d = withCpu(effectDescriptor(kBitsId, kBitsName, bitwiseParams(), 0, 0), CpuClass::Light);
    return d;
}

}  // namespace

const ModuleDescriptor& bitwiseDescriptor(std::span<const std::string_view> labels, uint32_t index) {
    static const ModuleDescriptor& d = legacyVariantDescriptor(bitwiseBase(), kBitsId, kBitsName, labels, index);
    return d;
}
ModuleProcessor* makeBitwiseAs(const ModuleDescriptor& v) noexcept { return new (std::nothrow) Bitwise(v); }
std::span<const BuiltinPreset> bitwisePresets() { return presets(); }

}  // namespace caw::fx
