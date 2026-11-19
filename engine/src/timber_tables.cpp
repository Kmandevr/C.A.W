// Timber's shared read-only tables: the piano's synthesised soundboard excitations, the organ's sine and the pluck noise, built once at registration.
#include "timber_dsp.h"

#include <memory>
#include <new>

namespace caw::timber {
namespace {

// One soundboard excitation: what a struck string's bridge would pass to the board and the case, as heard. It is
// designed here, not recorded (owner, 2026-11-19, allowed a CC-BY recording; none is used in this build): decaying
// noise in 18 third-octave-ish bands, the low bands ringing longer than the high ones (a board's modes are dense
// and damp fast with frequency), plus six low body resonances. The three characters differ in spectrum and length:
// Grand broad and long, Upright boxy (a peak around 250-600 Hz, shorter), Felt dark (the highs rolled off). Lower
// register zones ring longer and darker, higher ones shorter and brighter.
void buildExcitation(int character, int zone, int16_t* out) {
    constexpr int n = Tables::kExcLength;
    constexpr double sr = Tables::kExcRate;
    std::unique_ptr<float[]> acc(new float[n]());
    Noise noise;
    noise.s = 0x51A7u + 977u * static_cast<uint32_t>(character * 8 + zone);
    const double zoneTilt = 0.12 * (zone - 3.5);           // per octave: lower zones darker
    const double zoneTime = 1.35 - 0.09 * zone;            // and longer
    static constexpr double kTau[3] = {0.11, 0.075, 0.09};  // the 100 Hz band's time constant, s
    constexpr int kBands = 18;
    for (int b = 0; b < kBands; ++b) {
        const double fc = 70.0 * detPow(2.0, b * 0.42);  // 70 Hz .. about 10.5 kHz
        const double oct = detLog(fc / 300.0) / detLog(2.0);  // octaves from 300 Hz
        double db = oct > 0.0 ? -1.5 * oct : 0.0;
        db += 6.0 * zoneTilt * detLog(fc / 1000.0) / detLog(2.0);
        if (character == 1) {  // Upright: a box peak and less of the very low and the very high
            const double o = detLog(fc / 400.0) / detLog(2.0);
            db += 6.0 * detExp(-o * o) - (fc < 120.0 ? 5.0 : 0.0) - (fc > 5000.0 ? 4.0 : 0.0);
        } else if (character == 2) {  // Felt: the highs rolled off steeply
            if (fc > 1200.0) db -= 12.0 * detLog(fc / 1200.0) / detLog(2.0);
        }
        const double amp = detPow(10.0, db / 20.0);
        const double tau = kTau[character] * zoneTime * detPow(fc / 100.0, -0.6);
        Biquad bp;
        bp.band(fc, 1.4, sr);
        const double fall = detExp(-1.0 / (tau * sr));
        double env = amp;
        for (int i = 0; i < n; ++i) {
            acc[i] += static_cast<float>(env) * bp.run(noise.next());
            env *= fall;
        }
    }
    // The body's low resonances, struck once (an impulse into each): a board's lowest modes and the case.
    static constexpr double kBody[6] = {92.0, 138.0, 187.0, 246.0, 318.0, 409.0};
    static constexpr double kBodyAmp[3] = {0.5, 0.35, 0.45};
    for (int m = 0; m < 6; ++m) {
        Mode mode;
        mode.set(kBody[m] * (character == 1 ? 1.12 : 1.0), (0.16 - 0.015 * m) * zoneTime, sr);
        float x = static_cast<float>(kBodyAmp[character] * (1.0 - 0.1 * m));
        for (int i = 0; i < n; ++i) {
            acc[i] += mode.run(x);
            x = 0.0f;
        }
    }
    // A short fade at the end (the table stops there) and a peak of 0.9.
    float peak = 0.0f;
    for (int i = 0; i < n; ++i) peak = std::fmax(peak, std::fabs(acc[i]));
    const int fade = 1200;
    for (int i = 0; i < n; ++i) {
        float g = peak > 0 ? 0.9f / peak : 0.0f;
        if (i >= n - fade) g *= static_cast<float>(n - i) / fade;
        const float v = acc[i] * g * 32767.0f;
        out[i] = static_cast<int16_t>(v > 32767.0f ? 32767.0f : (v < -32767.0f ? -32767.0f : v));
    }
}

const Tables* build() {
    Tables* t = new (std::nothrow) Tables();
    if (!t) return nullptr;
    for (int c = 0; c < Tables::kCharacters; ++c)
        for (int z = 0; z < Tables::kZones; ++z) buildExcitation(c, z, t->excitation[c][z]);
    for (int i = 0; i <= Tables::kSine; ++i) t->sine[i] = static_cast<float>(detSin(kTwoPi * i / Tables::kSine));
    Noise n;
    n.s = 0xC0FFEEu;
    for (int i = 0; i < Tables::kPluck; ++i) t->pluck[i] = n.next();
    return t;
}

}  // namespace

const Tables& tables() noexcept {
    static const Tables* t = build();
    static const Tables empty{};  // only if the allocation failed: silence, never a crash
    return t ? *t : empty;
}

}  // namespace caw::timber
