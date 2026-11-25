// Starling's piano model (Timber's Simulated piano, 1.1.2): its per-sample parts (the strings with the hammer and the contacts, then the board, banks and noises after the sum), compiled with strict floating point so any block size gives the same bits.
#include "starling_piano_model.h"

namespace caw::timber {
namespace {

// The hammer's force at table frame y (the zones' and speeds' pulses blended), normalised to its peak.
float pulseAt(const Piano::Voice& v, double y) noexcept {
    if (y < 0.0) return 0.0f;
    const int i = static_cast<int>(y);
    if (i + 1 >= piano_curves::kPulseFrames) return 0.0f;
    const float f = static_cast<float>(y - i);
    float r = 0;
    for (int k = 0; k < 4; ++k) r += v.pw[k] * (v.pulse[k][i] + (v.pulse[k][i + 1] - v.pulse[k][i]) * f);
    return r * (1.0f / 32767.0f);
}

// Mode::run's arithmetic, local to this strict file (Mode itself is shared with code built with the fast flags).
inline float modeRun(Mode& m, float x) noexcept {
    const float r = m.c * m.zr - m.s * m.zi + x;
    const float i = m.s * m.zr + m.c * m.zi;
    m.zr = r, m.zi = i;
    return i;
}

}  // namespace

void Piano::renderSimFrames(Voice& v, float* out, uint32_t n, uint32_t at) noexcept {
    const int ns = v.strings, M = v.disp;
    const F4 a = f4(v.a), b = f4(v.b), p = f4(v.p);
    const float c = v.c, gain = v.out, dt = static_cast<float>(1.0 / sr);
    const float noiseK = static_cast<float>(noise);
    float e[kControlFrames], hs[kControlFrames];
    // Once the hammer has left and the key has settled (most of a note's life), this voice is its strings alone.
    const bool busy = v.wait > 0 || v.exciting || v.keybedPending || v.keybed.on || v.fingerPending || v.finger.on;
    for (uint32_t i = 0; i < n; ++i) e[i] = 0.0f;
    for (uint32_t i = 0; busy && i < n; ++i) {
        // The hammer: its force pulse, minus its reflection from the near end (the strike point's comb).
        float x = 0;
        if (v.wait > 0) {
            --v.wait;
        } else if (v.exciting) {
            const float F0 = pulseAt(v, v.ppos), F = F0 - pulseAt(v, v.ppos - v.tap);
            v.feltY += v.felt * (F - v.feltY);
            x = v.feltY * v.pgain;
            busBoard[at + i] += F0 * v.thump * noiseK;
            v.ppos += v.pstep;
            if (v.ppos - v.tap >= piano_curves::kPulseFrames) v.exciting = false;
        }
        e[i] = x;
        // The contacts: the key's front on the keybed, the finger on the key (into the key frame).
        const uint64_t f = v.simFrames + i;
        if (v.keybedPending && f >= v.keybedAt) v.keybedPending = false, v.keybed.on = noiseK > 0 && !testMuteKeys;
        if (v.fingerPending && f >= v.fingerAt) v.fingerPending = false, v.finger.on = noiseK > 0 && !testMuteKeys;
        if (v.keybed.on) busFrame[at + i] += v.keybed.step(dt) * v.keybedGain * noiseK;
        if (v.finger.on) busFrame[at + i] += v.finger.step(dt) * v.fingerGain * noiseK;
    }
    // A silently held key's strings listen to the bridge (the struck strings' sum), 16 frames late.
    if (v.sympC != 0.0f)
        for (uint32_t i = 0; i < n; ++i) hs[i] = v.sympC * bridge[static_cast<uint32_t>(simPos + at + i - kControlFrames) & 31u];
    else
        for (uint32_t i = 0; i < n; ++i) hs[i] = 0.0f;
    const bool glides = v.glideScale > 0, drives = bridgeNeeded && v.sympC == 0.0f;
    v.simFrames += n;
    F4 Y[kControlFrames];
    for (uint32_t i = 0; i < n; ++i) Y[i] = f4(0.0f);
    for (int s = 0; s < ns; ++s) {
        const Line& l = v.line[s];
        const uint32_t from = l.w - v.D[s];
        for (uint32_t i = 0; i < n; ++i) Y[i][s] = l.buf[(from + i) & l.mask];
    }
    F4 x1, y1, eta;
    for (int k = 0; k < 4; ++k) x1[k] = v.apx[k], y1[k] = v.apy[k], eta[k] = v.eta[k];
    for (uint32_t i = 0; i < n; ++i) {
        const F4 t = eta * (Y[i] - y1) + x1;
        x1 = Y[i], y1 = t, Y[i] = t;
    }
    for (int k = 0; k < 4; ++k) v.apx[k] = x1[k], v.apy[k] = y1[k];
    for (int m = 0; m < M; ++m) {
        for (int k = 0; k < 4; ++k) x1[k] = v.dx[m][k], y1[k] = v.dy[m][k];
        for (uint32_t i = 0; i < n; ++i) {
            const F4 t = a * (Y[i] - y1) + x1;
            x1 = Y[i], y1 = t, Y[i] = t;
        }
        for (int k = 0; k < 4; ++k) v.dx[m][k] = x1[k], v.dy[m][k] = y1[k];
    }
    F4 z;
    for (int k = 0; k < 4; ++k) z[k] = v.z[k];
    for (uint32_t i = 0; i < n; ++i) {
        z = b * Y[i] + p * z;
        Y[i] = z;
    }
    for (int k = 0; k < 4; ++k) v.z[k] = z[k];
    const bool mute = testMuteStrings;
    for (uint32_t i = 0; i < n; ++i) {
        const float S = Y[i][0] + Y[i][1] + Y[i][2] + Y[i][3];
        float w[3], o = 0;
        for (int s = 0; s < ns; ++s) o += w[s] = Y[i][s] - c * S + v.strike[s] * e[i] + hs[i];
        if (v.landing) {  // the landing felt against the string's own motion: a one-sided contact
            const float ex = std::fabs(o) - v.landGap;
            if (ex > 0) {
                const float Fb = (o > 0 ? 1.0f : -1.0f) * ex * std::sqrt(ex) * 4.0f;
                for (int s = 0; s < ns; ++s) w[s] -= kBuzzAbsorb * Fb / ns;
                o -= kBuzzAbsorb * Fb;
                busBoard[at + i] += Fb * kBuzzGain * noiseK * buzzSound;
                buzzEnergy += static_cast<double>(Fb) * Fb;
            }
        }
        if (mute) o = 0, w[0] = w[1] = w[2] = 0;
        for (int s = 0; s < ns; ++s) v.line[s].push(w[s]);
        if (glides) v.energy += o * o;
        float y = o * gain;
        if (v.gated) {  // Starling: the model fades in under the recorded attack (sin over the crossfade, power-complementary)
            float g = 0;
            if (v.gateHold > 0) {
                --v.gateHold;
            } else {
                v.gateT += v.gateStep;
                if (v.gateT >= 1.0f) v.gateT = 1.0f, v.gated = false;
                const float t = v.gateT;
                g = t * (1.5704f + t * t * (0.0723f * t * t - 0.6427f));  // sin(pi t / 2) within 0.02 %, exactly 1 at t = 1
            }
            y *= g;
        }
        if (v.phantomGain > 0) {  // High: longitudinal modes driven by the transverse motion squared
            const float d = o * o;
            y += (modeRun(v.phantom[0], d) + 0.5f * modeRun(v.phantom[1], d)) * v.phantomGain;
        }
        out[i] = y;
        if (drives) busBridge[at + i] += y * (v.panL + v.panR);
    }
}

void Piano::postSim(float* l, float* r, uint32_t n, const Shared& s) noexcept {
    float x[kControlFrames], bin[kControlFrames], ro[kControlFrames] = {}, kf[kControlFrames] = {};
    float tw[kControlFrames] = {}, ti[kControlFrames] = {}, li[kControlFrames] = {}, rail[kControlFrames] = {};
    float bl[kControlFrames] = {}, br[kControlFrames] = {};
    for (uint32_t i = 0; i < n; ++i) {
        x[i] = l[i] + r[i];
    }
    if (bridgeNeeded)
        for (uint32_t i = 0; i < n; ++i) bridge[static_cast<uint32_t>(simPos + i) & 31u] = busBridge[i];
    // The register bank (pedal down), fed by the strings alone: no noise ever reaches it.
    const float drive = static_cast<float>(kResDrive * resonance * pedal);
    if (resRun) {
        float rin[kControlFrames];
        for (uint32_t i = 0; i < n; ++i) rin[i] = x[i] * drive, resInputEnergy += static_cast<double>(rin[i]) * rin[i];
        res.process(rin, ro, nullptr, n);
    }
    // The resonators run while they ring or are struck; idle, their state is exactly zero (controlSim), so
    // skipping them changes no bit.
    auto any = [n](const float* x) {
        bool a = false;
        for (uint32_t i = 0; i < n; ++i) a = a || x[i] != 0.0f;
        return a;
    };
    if (!keyFrameIdle || any(busFrame)) keyFrame.process(busFrame, kf, nullptr, n), keyFrameIdle = false;
    // The pedal: the trapwork's contact into its wood, the dampers' felts into the rail.
    if (trap.on || liftNext < liftCount || !pedalIdle) {
        for (uint32_t i = 0; i < n; ++i) {
            ti[i] = trap.on ? trap.step(static_cast<float>(1.0 / sr)) * kPedalGain * static_cast<float>(noise) : 0.0f;
            while (liftNext < liftCount && lifts[liftNext].at <= liftClock) li[i] += lifts[liftNext++].amp * kLiftGain * static_cast<float>(noise);
            ++liftClock;
        }
        trapwork.process(ti, tw, nullptr, n);
        damperRail.process(li, rail, nullptr, n);
        pedalIdle = false;
    }
    for (uint32_t i = 0; i < n; ++i) bin[i] = x[i] + ro[i] + busBoard[i] + 0.5f * kf[i];
    board.process(bin, bl, br, n);
    const float wet = static_cast<float>(clampd(s.body, 0, 1)) * kBoardGain, dry = 1.0f - static_cast<float>(clampd(s.body, 0, 1));
    float peak = 0;
    for (uint32_t i = 0; i < n; ++i) {
        const float direct = 0.5f * kf[i] + tw[i] + rail[i];
        l[i] = bl[i] * wet + l[i] * dry + direct;
        r[i] = br[i] * wet + r[i] * dry + direct;
        peak = std::max(peak, std::fabs(bin[i]) + std::fabs(direct));
        busBoard[i] = busFrame[i] = busBridge[i] = 0;
    }
    simPos += n;
    simPeak = std::max(simPeak, peak);
    gridPeak = std::max(gridPeak, peak);
    gridFill += n;
    if (gridFill < kControlFrames) return;  // the banks' energies are read once a control block, at its end
    resEnergy = resRun ? res.energy() : 0.0f;
    keyFrameEnergy = keyFrameIdle ? 0.0f : keyFrame.energy();
    pedalEnergy = pedalIdle ? 0.0f : trapwork.energy() + damperRail.energy();
    simQuiet = gridPeak < 1e-7f && !trap.on && liftNext >= liftCount && board.energy() < 1e-12f && resEnergy < 1e-12f &&
               keyFrameEnergy < 1e-12f && pedalEnergy < 1e-12f;
    gridPeak = 0;
}

}  // namespace caw::timber
