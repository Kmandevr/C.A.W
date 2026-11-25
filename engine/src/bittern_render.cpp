// Bittern's per-sample voice (each pipe's speech, tone and release, the recorded speech and the wind noise) and the swell boxes, compiled with strict floating point so any block size gives the same bits.
#include "bittern_organ.h"

namespace caw::bittern {

void Organ::render(Voice& v, float* out, uint32_t n) noexcept {
    float acc[kControlFrames] = {}, box[kControlFrames] = {};  // the open divisions' pipes, the enclosed ones'
    constexpr int kShift = 32 - 11;  // kTableSize = 2^11
    constexpr float kFrac = 1.0f / static_cast<float>(1u << kShift);
    constexpr uint32_t kMask = (1u << kShift) - 1u;
    const float gk = gainK;
    // Each pipe's lines this render: from their start (lineAt) on the voice's clock.
    float steps[kControlFrames];
    for (uint32_t i = 0; i < n; ++i) steps[i] = static_cast<float>(i + 1);
    const uint32_t clock = v.clock;
    v.clock += n;
    for (int k = 0; k < kRanks; ++k) {
        if (v.env[k] <= 0.0f && v.envStep[k] <= 0.0f) continue;
        const float o = static_cast<float>(clock - v.lineAt[k]);
        const float es = v.envStep[k], gs = v.gStep[k], ws = v.spokeStep[k];
        const float e0 = v.env[k], g0 = v.gain[k], w0 = v.spoke[k];  // at the line's start: sample t = o + i + 1 of it
        const float* s = v.steady[k];
        const float* e = v.speaking[k];
        const uint32_t inc = v.step[k], ph = v.phase[k];
        float* to = enclosed(kDivisionOf[k]) ? box : acc;
        // The pipe's level each sample (its speech or release, squared, and its level: both lines; o + i + 1 is a
        // whole number, exact) times its table, in one pass.
        if (w0 >= 1.0f && ws == 0.0f && es == 0.0f && e0 == 1.0f) {
            for (uint32_t i = 0; i < n; ++i) {  // spoken and up: the common case
                const float t = o + steps[i];
                const uint32_t p = ph + i * inc;  // wraps at 2^32: a whole cycle
                const uint32_t at = (p >> kShift) * 2;
                const float f = static_cast<float>(p & kMask) * kFrac;
                to[i] += (s[at] + s[at + 1] * f) * (g0 + gs * t);
            }
        } else if (w0 >= 1.0f && ws == 0.0f) {
            for (uint32_t i = 0; i < n; ++i) {
                const float t = o + steps[i], x = e0 + es * t;
                const uint32_t p = ph + i * inc;
                const uint32_t at = (p >> kShift) * 2;
                const float f = static_cast<float>(p & kMask) * kFrac;
                to[i] += (s[at] + s[at + 1] * f) * (x * x * (g0 + gs * t));
            }
        } else {
            // Speaking: the measured speaking spectrum, giving way to the steady one as the pipe comes up to speech.
            for (uint32_t i = 0; i < n; ++i) {
                const float t = o + steps[i], x = e0 + es * t;
                const uint32_t p = ph + i * inc;
                const uint32_t at = (p >> kShift) * 2;
                const float f = static_cast<float>(p & kMask) * kFrac;
                const float a = s[at] + s[at + 1] * f, b = e[at] + e[at + 1] * f;
                to[i] += (b + (a - b) * (w0 + ws * t)) * (x * x * (g0 + gs * t));
            }
        }
        v.phase[k] = ph + n * inc;
    }
    // The Swell's and the Choir's pipes through their boxes' shutters (the mod wheel; their gain is in each pipe's
    // level): a one-pole low-pass, resting on the pipes' last sample while open, so closing it starts without a step.
    const float sk = swellK;
    if (sk < 0.999f) {
        for (uint32_t i = 0; i < n; ++i) {
            v.boxLp += sk * (box[i] - v.boxLp);
            acc[i] += v.boxLp;
        }
    } else {
        for (uint32_t i = 0; i < n; ++i) acc[i] += box[i];
        if (n > 0) v.boxLp = box[n - 1];
    }
    // Body: the pipes' scale (see Voice::bodyLp); at Body 0.5 the pipes as measured, bit for bit.
    // At Body 0.5 the filter rests on the pipes' last sample, so turning Body starts it without a step.
    const float bk = v.bodyK, bg = body > 0.0f ? 0.75f * body : body;
    if (bg != 0.0f) {
        for (uint32_t i = 0; i < n; ++i) {
            v.bodyLp += bk * (acc[i] - v.bodyLp);
            acc[i] += bg * (v.bodyLp - acc[i]);
        }
    } else if (n > 0) {
        v.bodyLp = acc[n - 1];
    }
    const float nTo = v.nGainTo, pk = v.puffK;
    const int bands = v.bands;
    float ng = v.nGain, puff = v.puff;
    for (uint32_t i = 0; i < n; ++i) {
        // The breath: the noise through the key's harmonic bands, at the pipes' level and the valves' puffs.
        ng += (nTo - ng) * gk;
        puff *= pk;
        float w = 0;
        const float level = ng + puff;
        if (level > 1e-9f) {
            const float x = v.noise.next() * level;
            for (int b = 0; b < bands; ++b) {
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
            // The frames left before its end, then those without a check each.
            const uint64_t last = static_cast<uint64_t>(p.frames - 1) << 32;
            const uint32_t m = p.pos >= last ? 0u : static_cast<uint32_t>(std::min<uint64_t>(n, (last - p.pos + p.step - 1) / p.step));
            constexpr float kTo = 1.0f / 4294967296.0f;
            for (uint32_t i = 0; i < m; ++i) {
                const uint64_t q = p.pos + i * p.step;
                const uint32_t at = static_cast<uint32_t>(q >> 32);
                const float f = static_cast<float>(static_cast<uint32_t>(q)) * kTo;
                add[i] += (p.data[at] + (p.data[at + 1] - p.data[at]) * f) * p.gain;
            }
            p.pos += m * p.step;
            if (m < n) p.data = nullptr;
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

}  // namespace caw::bittern
