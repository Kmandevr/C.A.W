// Bittern's per-sample voice (each pipe's speech, tone and release, the recorded speech and the wind noise) and its swell box, compiled with strict floating point so any block size gives the same bits.
#include "bittern_organ.h"

namespace caw::bittern {

void Organ::render(Voice& v, float* out, uint32_t n) noexcept {
    float acc[kControlFrames] = {};
    constexpr int kShift = 32 - 11;  // kTableSize = 2^11
    constexpr float kFrac = 1.0f / static_cast<float>(1u << kShift);
    constexpr uint32_t kMask = (1u << kShift) - 1u;
    const float gk = gainK;
    for (int k = 0; k < kStops; ++k) {
        if (!v.on[k] && v.env[k] <= 0.0f) continue;
        const float target = v.on[k] ? 1.0f : 0.0f, ek = v.on[k] ? v.rise[k] : v.relK, gTo = v.gainTo[k];
        const float* s = v.steady[k];
        const float* e = v.speaking[k];
        const uint32_t inc = v.step[k];
        uint32_t ph = v.phase[k];
        float env = v.env[k], g = v.gain[k], spoke = v.spoke[k];
        if (spoke >= 1.0f) {
            for (uint32_t i = 0; i < n; ++i) {
                env += (target - env) * ek;
                g += (gTo - g) * gk;
                const uint32_t at = ph >> kShift;
                const float f = static_cast<float>(ph & kMask) * kFrac;
                acc[i] += (s[at] + (s[at + 1] - s[at]) * f) * (env * env * g);
                ph += inc;  // wraps at 2^32: a whole cycle
            }
        } else {
            // Speaking: the measured speaking spectrum, giving way to the steady one as the pipe comes up to speech.
            for (uint32_t i = 0; i < n; ++i) {
                env += (target - env) * ek;
                g += (gTo - g) * gk;
                spoke = std::max(spoke, env);
                const uint32_t at = ph >> kShift;
                const float f = static_cast<float>(ph & kMask) * kFrac;
                const float a = s[at] + (s[at + 1] - s[at]) * f, b = e[at] + (e[at + 1] - e[at]) * f;
                acc[i] += (b + (a - b) * spoke) * (env * env * g);
                ph += inc;
            }
        }
        v.phase[k] = ph, v.env[k] = env, v.gain[k] = g, v.spoke[k] = spoke;
    }
    const float nTo = v.nGainTo, pk = v.puffK;
    float ng = v.nGain, puff = v.puff;
    for (uint32_t i = 0; i < n; ++i) {
        // The breath: the noise through the key's harmonic bands, at the pipes' level and the valves' puffs.
        ng += (nTo - ng) * gk;
        puff *= pk;
        float w = 0;
        const float level = ng + puff;
        if (level > 1e-9f) {
            const float x = v.noise.next() * level;
            for (int b = 0; b < kBreathBands; ++b) {
                v.nLp[b] += v.nF[b] * v.nBp[b];
                const float hp = x - v.nLp[b] - kBreathDamp * v.nBp[b];
                v.nBp[b] += v.nF[b] * hp;
                w += v.nBp[b] * v.nW[b];
            }
        }
        out[i] = acc[i] * kOut + w;
    }
    v.nGain = ng, v.puff = puff;
    if (v.inFade < 1.0f) {
        for (uint32_t i = 0; i < n; ++i) {
            v.inFade = std::min(1.0f, v.inFade + v.inStep);
            out[i] *= v.inFade;
        }
    }
    // The recorded speech, faded with the pipes once the key is let go.
    if (v.playersOn > 0) {
        float sp = v.speech;
        const float rk = v.held ? 0.0f : v.relK;
        float add[kControlFrames] = {};
        for (int j = 0; j < v.playersOn; ++j) {
            Player& p = v.players[j];
            if (!p.data) continue;
            for (uint32_t i = 0; i < n; ++i) {
                const uint32_t at = static_cast<uint32_t>(p.pos);
                if (at + 1 >= p.frames) {
                    p.data = nullptr;
                    break;
                }
                const float f = static_cast<float>(p.pos - at);
                add[i] += (p.data[at] + (p.data[at + 1] - p.data[at]) * f) * p.gain;
                p.pos += p.step;
            }
        }
        for (uint32_t i = 0; i < n; ++i) {
            sp -= sp * rk;
            out[i] += add[i] * sp;
        }
        v.speech = sp;
        int live = 0;
        for (int j = 0; j < v.playersOn; ++j)
            if (v.players[j].data) v.players[live++] = v.players[j];
        v.playersOn = live;
    }
}

void Organ::post(float* l, float* r, uint32_t n, const Shared&) noexcept {
    constexpr float kEase = 0.002f;  // about 10 ms at 48 kHz: the box's shutters move, they do not jump
    for (uint32_t i = 0; i < n; ++i) {
        swellK += (swellKTo - swellK) * kEase;
        swellG += (swellGTo - swellG) * kEase;
        swellLp[0] += swellK * (l[i] - swellLp[0]);
        swellLp[1] += swellK * (r[i] - swellLp[1]);
        l[i] = swellLp[0] * swellG, r[i] = swellLp[1] * swellG;
    }
    swellFill += n;
    if (swellFill >= kControlFrames) {  // flushed on the control grid only, so any block size gives the same bits
        swellFill = 0;
        swellLp[0] = timber::flushf(swellLp[0]), swellLp[1] = timber::flushf(swellLp[1]);
    }
}

}  // namespace caw::bittern
