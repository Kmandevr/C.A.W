// Woodpecker's tuned percussion (1.1.3): measured modal bars, tubes and drums with a recorded mallet attack crossfaded in phase, a tuned resonator, the vibraphone's motor and damper.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>

#include "caw/library/fastmath.hpp"
#include "recorded_bank.h"
#include "timber_core.h"

namespace caw::woodpecker {

using timber::clampd;
using timber::F4;
using timber::f4;
using timber::kControlFrames;
using timber::Shared;
using timber::VoiceBase;

inline constexpr int kInstruments = 6, kModes = 12, kBlocks = kModes / 4;
enum Which : int { kMarimba, kXylophone, kGlockenspiel, kVibraphone, kChimes, kTimpani };

// The measured tables (generated: tools/woodpecker_assets.py writes woodpecker_bank.inc from VCSL, CC0).
// A zone: one recorded key's modes. `key` is the pitch its reference mode stands for (MIDI, fractional: as recorded,
// the xylophone 12-21 cents sharp); `ratio` each mode's frequency over that pitch (the chime's 4th mode 2.0: its
// strike note is an octave under it; the timpani's (1,1) mode 1.0); `t60` each mode's decay. Modes in order of
// strength over the crossfade, the reference first.
struct Zone {
    int instrument;
    float key;
    int modes;
    float ratio[kModes], t60[kModes];
};
// A clip: one recorded attack in the bank, and the zone's modes as the recording holds them in the middle of the
// crossfade, ref = hold + fade / 2 (complex amplitudes at the recorded level, x = Im(c e^{i w (t - ref)})), so the
// model can carry on exactly where the
// recording is.
struct Clip {
    int zone, set, layer;
    float vel;  // the layer's velocity (MIDI)
    uint32_t first, frames;
    float scale;  // the clip's peak at the recorded level (the bank stores it normalised)
    float rms;    // its RMS over the crossfade at the recorded level
    float re[kModes], im[kModes];
};
// Each instrument's zones and clips: clip (set * zones + zone) * 2 + layer from firstClip; each mallet set's hardness.
struct Layout {
    int firstZone, zones, firstClip, sets;
    float hardness[3];
    float velSoft, velLoud;
    float hold, fade;  // seconds: the recording alone, then the crossfade (the clips' modes are measured in its middle)
};
#include "woodpecker_bank.inc"

// The range each instrument plays (MIDI, inclusive): the recordings' keys, a little either side (docs/engine.md).
inline constexpr int kLow[kInstruments] = {41, 65, 79, 53, 60, 38}, kHigh[kInstruments] = {96, 108, 108, 89, 77, 57};
// The tuned resonator's share of the fundamental at Resonator 1 (the tube over the bar: 1 doubles it). [Assumption]
// chosen, not measured (the recordings hold bar and tube together): a marimba's and xylophone's tube carries half of
// the fundamental, a vibraphone's three quarters (its motor's discs turn that part on and off). Its Q is 40.
inline constexpr double kTube[kInstruments] = {1.0, 1.0, 0.0, 3.0, 0.0, 0.0};
inline constexpr double kTubeQ = 40.0;
// Which instruments have dampers (a released key is damped unless the pedal is down): the vibraphone and the chimes.
inline constexpr bool kDampers[kInstruments] = {false, false, false, true, true, false};

// The smooth envelope of a mallet's force spectrum: the half-sine pulse of a Hertz contact (Hunt-Crossley, as
// timber_sim.h's Contact) lasting tc seconds is flat to about 1 / (2 tc) and falls as f^-2 above.
inline double contactEnvelope(double hz, double tc) noexcept {
    const double x = 2.0 * hz * tc;
    return 1.0 / std::sqrt(1.0 + x * x * x * x);
}
// The contact time of a mallet head of hardness h (0 yarn .. 1 hard plastic): 4 ms down to 0.25 ms, as Timber's.
inline double contactTime(double h) noexcept { return 0.004 * detPow(16.0, -clampd(h, 0, 1)); }

// A recorded attack playing: from the bank at a pitch ratio, panned, held, then fading out as the model fades in.
struct Player {
    const float* data = nullptr;
    uint32_t frames = 0;
    double pos = 0, step = 1;
    float gl = 0, gr = 0;
    uint32_t hold = 0;
    float fadeT = 0, fadeStep = 0;
    bool on = false;
};

// The model (one class for every instrument; `which` picks the tables). Each voice is up to 12 decaying modes
// (complex one-poles, 4 wide), at the zone's measured ratios and decays, tuned to equal temperament at A440: the
// recording is played at the pitch ratio that puts its reference mode there (so the xylophone's 15 cents sharp is
// taken off). With a recorded attack, every mode starts at the complex amplitude the recording has at `ref`
// (from the clip's table, carried back to the strike along the mode's own decay): recording and model are the same
// partials in the same phase, so a complementary crossfade (smoothstep, the two gains summing to 1) neither cancels
// nor bumps. Hardness picks the nearest recorded mallet and tilts the modes by the ratio of the contact envelopes
// (the reference mode kept). Without an attack (Attack 0, or a key far outside the recordings) the modes start from
// zero phase with a short contact click.
struct Bars {
    static constexpr uint32_t kEcoCap = 12, kNormalCap = 24, kHighCap = 32, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = true;
    // A voice is silent while its recording holds (up to 80 ms): it may not end for silence before 0.3 s.
    static constexpr double kMinLife = 0.3, kSpread = 0.5;
    // Every instrument's knobs; each variant's descriptor has its own subset (builtin_woodpecker.cpp maps them).
    enum P : uint32_t { kHardness, kDecay, kAttack, kTier, kResonator, kSustain, kMotor, kMotorDepth, kAll };
    static constexpr int kPlayers = 32;

    struct Voice : VoiceBase {
        F4 c[kBlocks], s[kBlocks], zr[kBlocks], zi[kBlocks];
        float hz[kModes] = {}, life[kModes] = {};
        int modes = 1, blocks = 1;
        double tunedPitch = -1, hzRef = 440;
        const Zone* zone = nullptr;
        bool damped = false;
        // The tuned resonator (a constant-peak band-pass at the fundamental, direct form I) and its share.
        float rb = 0, ra1 = 0, ra2 = 0, rx1 = 0, rx2 = 0, ry1 = 0, ry2 = 0, tube = 0;
        // The model's fade-in under a recorded attack.
        bool gated = false;
        uint32_t gateHold = 0;
        float gateT = 0, gateStep = 0;
        float gain = 1;  // Body
        uint32_t clickLeft = 0;
        float clickAmp = 0;
        timber::Noise noise;
    };

    int which = 0;
    double hardness = 0.5, decay = 1, attack = 1, resonator = 1, sustain = 0, motor = 0, depth = 0.6;
    int tier = kQualityNormal, modeCap = 8;
    bool pedal = false;
    double sr = 48000, tremPhase = 0;
    float tremStart = 1, tremEnd = 1, tremStep = 0;
    uint32_t tremAt = 0;
    std::shared_ptr<const recorded::Bank> bank;
    Player players[kPlayers];
    Voice* voices = nullptr;
    uint32_t count = 0;
    bool testMuteRecordings = false;  // the tests' A/B (never used for sound)
    bool testMuteModel = false;
    bool testUnfaded = false;  // the recording played to its end, never faded (the tests' measure of the real instrument)

    size_t allocBytes() const noexcept { return 0; }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.6, r.decay = 1.8, r.damping = 0.4, r.mix = 1.0, r.width = 1.0;
        return r;
    }
    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, count = n;
        if (!bank) bank = recorded::acquire(recorded::BankId::Woodpecker);
        return true;
    }
    void reset() noexcept { clearPost(); }

    // `p` holds every knob (kAll), in P's order.
    void control(const double* p, const Shared& s) noexcept {
        hardness = clampd(p[kHardness], 0, 1);
        decay = clampd(p[kDecay], 0.25, 4);
        attack = clampd(p[kAttack], 0, 1);
        const int t = static_cast<int>(clampd(p[kTier], 0, 3) + 0.5);
        tier = t == 0 ? s.quality : t - 1;
        modeCap = tier == kQualityHigh ? 12 : 8;  // Eco keeps Normal's modes (they carry the crossfade) and plays fewer voices
        resonator = clampd(p[kResonator], 0, 1);
        sustain = clampd(p[kSustain], 0, 1);
        motor = clampd(p[kMotor], 0, 8);
        depth = clampd(p[kMotorDepth], 0, 1);
        const bool down = std::max(sustain, s.pedal) >= 0.5;
        if (pedal && !down && kDampers[which])  // the pedal up: every released key still ringing is damped now
            for (uint32_t k = 0; k < count; ++k)
                if (voices[k].active && !voices[k].held && !voices[k].fading && !voices[k].damped) damp(voices[k], s);
        pedal = down;
        // The motor: the resonators' discs turn (a sine of the tube's share), as a gain ramped over each control block.
        tremStart = tremEnd;
        if (motor > 0 && kTube[which] > 0) {
            tremPhase += motor * kControlFrames / sr;
            tremPhase -= std::floor(tremPhase);
            tremEnd = static_cast<float>(1.0 - depth * (0.5 + 0.5 * lib::fastSinCycles(tremPhase)));
        } else {
            tremEnd = 1.0f;
        }
        tremStep = (tremEnd - tremStart) / static_cast<float>(kControlFrames);
        tremAt = 0;
    }

    // Each mode's one-pole at its frequency and life (seconds to -60 dB); off at or over 0.45 of the rate.
    void setModes(Voice& v) const noexcept {
        for (int k = 0; k < kModes; ++k) {
            double c = 0, s = 0;
            const double hz = v.hz[k];
            if (hz > 0 && hz < 0.45 * sr) {
                const double rr = detExp(-6.907755278982137 / (v.life[k] * sr));
                const double w = timber::kTwoPi * hz / sr;
                c = rr * detCos(w), s = rr * detSin(w);
            }
            v.c[k / 4][k % 4] = static_cast<float>(c), v.s[k / 4][k % 4] = static_cast<float>(s);
        }
    }
    void tuneResonator(Voice& v) const noexcept {
        const double f = v.hz[0] / std::max(1e-6, static_cast<double>(v.zone->ratio[0]));  // the fundamental
        const double w = timber::kTwoPi * std::min(f, 0.45 * sr) / sr, r = detExp(-timber::kPi * f / (kTubeQ * sr));
        v.ra1 = static_cast<float>(2.0 * r * detCos(w)), v.ra2 = static_cast<float>(-r * r);
        v.rb = static_cast<float>(0.5 * (1.0 - r * r));
    }
    void tune(Voice& v) noexcept {
        const double pitch = clampd(v.pitch, kLow[which] - 12.0, kHigh[which] + 12.0);
        v.hzRef = timber::noteHz(pitch);
        for (int k = 0; k < kModes; ++k) v.hz[k] = k < v.modes ? static_cast<float>(v.hzRef * v.zone->ratio[k]) : 0.0f;
        setModes(v);
        if (v.tube > 0) tuneResonator(v);
        v.tunedPitch = v.pitch;
    }

    Player* freePlayer() noexcept {
        Player* pick = nullptr;
        for (Player& p : players) {
            if (!p.on) return &p;
            if (!pick || p.pos > pick->pos) pick = &p;  // all busy: the one furthest through
        }
        return pick;
    }

    void start(Voice& v, const Shared& s) noexcept {
        const Layout& lay = kLayouts[which];
        const double pitch = clampd(v.pitch, kLow[which] - 12.0, kHigh[which] + 12.0);
        int zi = 0;
        for (int z = 1; z < lay.zones; ++z)
            if (std::fabs(pitch - kZones[lay.firstZone + z].key) < std::fabs(pitch - kZones[lay.firstZone + zi].key)) zi = z;
        const Zone& zone = kZones[lay.firstZone + zi];
        v.zone = &zone;
        v.damped = false;
        v.gain = static_cast<float>(2.0 * s.body);  // Body 0.5: the bar as recorded
        v.tube = static_cast<float>(kTube[which]);
        v.noise.s = 0x5EEDu + 131u * v.key;
        const int modes = std::min(zone.modes, modeCap);
        v.modes = modes;
        v.blocks = (modes + 3) / 4;
        for (int k = 0; k < kModes; ++k) v.life[k] = static_cast<float>(std::max(0.02, zone.t60[k] * decay));
        tune(v);
        // The mallet: the nearest recorded set by hardness, the layer by velocity; the level between the layers
        // log-linear in velocity (a layer past them, extrapolated), so velocity is continuous within a layer.
        int set = 0;
        for (int k = 1; k < lay.sets; ++k)
            if (std::fabs(hardness - lay.hardness[k]) < std::fabs(hardness - lay.hardness[set])) set = k;
        const double mv = 127.0 * v.velocity;
        const int layer = mv >= 0.5 * (lay.velSoft + lay.velLoud) ? 1 : 0;
        const Clip* clips = kClips + lay.firstClip + (set * lay.zones + zi) * 2;
        const Clip& clip = clips[layer];
        const double r0 = clips[0].rms, r1 = std::max(clips[1].rms, 1.25f * clips[0].rms);
        const double tv = clampd((mv - lay.velSoft) / (lay.velLoud - lay.velSoft), -1.5, 1.25);
        const double R = r0 * detPow(r1 / r0, tv);
        const double g = clip.rms > 0 ? R / clip.rms : 0.0;
        // The hardness away from the recorded mallet's: each mode by the ratio of the two contact envelopes.
        const double tcNow = contactTime(hardness), tcRec = contactTime(lay.hardness[set]);
        const double tilt0 = contactEnvelope(v.hz[0], tcNow) / contactEnvelope(v.hz[0], tcRec);
        const double ratio = detPow(2.0, (pitch - zone.key) / 12.0);  // the recording's speed: its pitch to the note's
        const bool recorded = bank && !testMuteRecordings && attack > 1e-3 && std::fabs(pitch - zone.key) <= 4.5 &&
                              static_cast<uint64_t>(clip.first) + clip.frames <= bank->frames;
        const double nRef = (lay.hold + 0.5 * lay.fade) * sr / ratio;  // the output frame where the recording is at ref
        double c1r = 0, c1i = 0;
        for (int k = 0; k < kModes; ++k) {
            double zr = 0, zim = 0;
            if (k < modes && v.c[k / 4][k % 4] != 0.0f) {
                const double tilt = clampd(contactEnvelope(v.hz[k], tcNow) / contactEnvelope(v.hz[k], tcRec) / tilt0, 0.25, 2.0);
                double cr = g * tilt * clip.re[k], ci = g * tilt * clip.im[k];
                // Carried back nRef + 1 frames along the mode (the render's first output is z0 times the pole).
                const double m = nRef + 1.0, a = 6.907755278982137 / v.life[k], w = timber::kTwoPi * v.hz[k];
                const double back = detExp(a * m / sr);
                if (recorded) {
                    const double ph = -w * m / sr, cs = detCos(ph), sn = detSin(ph);
                    zr = back * (cr * cs - ci * sn), zim = back * (cr * sn + ci * cs);
                } else {
                    zr = back * std::sqrt(cr * cr + ci * ci);  // zero phase: the bar starts from rest
                }
                if (k == 0) c1r = zr, c1i = zim;
            }
            v.zr[k / 4][k % 4] = static_cast<float>(zr), v.zi[k / 4][k % 4] = static_cast<float>(zim);
        }
        v.rx1 = v.rx2 = v.ry1 = v.ry2 = 0;
        if (v.tube > 0) startResonator(v, c1r, c1i);
        v.gated = false;
        v.clickLeft = 0;
        if (recorded) {
            const uint32_t hold = static_cast<uint32_t>(lay.hold * sr);
            const float step = static_cast<float>(1.0 / (lay.fade * sr));
            Player* p = freePlayer();
            *p = Player{};
            p->data = bank->pcm.get() + clip.first;
            p->frames = clip.frames;
            p->step = ratio * bank->rate / sr;
            const float a = static_cast<float>(g * attack * clip.scale);
            p->gl = a * v.panL, p->gr = a * v.panR;
            p->hold = testUnfaded ? 0xFFFFFFFFu : hold, p->fadeStep = step;
            p->on = true;
            v.gated = true, v.gateHold = hold, v.gateT = 0, v.gateStep = step;
        } else {
            // The head's contact: a short noise burst as long as the contact, its level the strike's.
            const double tc = contactTime(hardness);
            v.clickLeft = static_cast<uint32_t>(std::max(2.0, tc * sr));
            v.clickAmp = static_cast<float>(0.3 * R * (0.3 + 0.7 * hardness));
        }
    }
    // The resonator in its steady state for the fundamental from the first frame: the bar's share of it is cut so
    // bar and tube together are the recording's at Resonator 1 (at the band-pass's own gain and phase at that
    // decaying mode); Resonator 0 leaves the bar's share alone.
    void startResonator(Voice& v, double zr, double zi) noexcept {
        const double cr = v.c[0][0], ci = v.s[0][0];  // the pole p
        const double pn = cr * cr + ci * ci;
        if (pn <= 0) return;
        const double ir = cr / pn, ii = -ci / pn;          // p^-1
        const double i2r = ir * ir - ii * ii, i2i = 2 * ir * ii;  // p^-2
        // H(p) = b (1 - p^-2) / (1 - a1 p^-1 - a2 p^-2)
        const double nr = v.rb * (1.0 - i2r), ni = v.rb * (-i2i);
        const double dr = 1.0 - v.ra1 * ir - v.ra2 * i2r, di = -v.ra1 * ii - v.ra2 * i2i;
        const double dd = dr * dr + di * di;
        const double hr = (nr * dr + ni * di) / dd, hi = (ni * dr - nr * di) / dd;
        // The bar's mode z' with z' (1 + tube H) = z.
        const double er = 1.0 + v.tube * hr, ei = v.tube * hi, ee = er * er + ei * ei;
        const double zr2 = (zr * er + zi * ei) / ee, zi2 = (zi * er - zr * ei) / ee;
        v.zr[0][0] = static_cast<float>(zr2), v.zi[0][0] = static_cast<float>(zi2);
        // Its past: x[-1] = Im(z'), x[-2] = Im(z' p^-1); the band-pass's y = Im(H x).
        const double ar = zr2 * ir - zi2 * ii, ai = zr2 * ii + zi2 * ir;  // z' p^-1
        v.rx1 = static_cast<float>(zi2), v.rx2 = static_cast<float>(ai);
        v.ry1 = static_cast<float>(hr * zi2 + hi * zr2), v.ry2 = static_cast<float>(hr * ai + hi * ar);
    }

    void damp(Voice& v, const Shared& s) noexcept {
        v.damped = true;
        for (int k = 0; k < kModes; ++k) v.life[k] = static_cast<float>(std::min<double>(v.life[k], std::max(0.02, s.release)));
        setModes(v);
    }
    void release(Voice& v, const Shared& s) noexcept {
        if (kDampers[which] && !pedal) damp(v, s);
    }
    void voiceControl(Voice& v, const Shared&) noexcept {
        if (v.pitch != v.tunedPitch) tune(v);
        for (int b = 0; b < kBlocks; ++b)
            for (int k = 0; k < 4; ++k) v.zr[b][k] = timber::flushf(v.zr[b][k]), v.zi[b][k] = timber::flushf(v.zi[b][k]);
        v.rx1 = timber::flushf(v.rx1), v.rx2 = timber::flushf(v.rx2), v.ry1 = timber::flushf(v.ry1), v.ry2 = timber::flushf(v.ry2);
    }
    void render(Voice& v, float* out, uint32_t n) noexcept {
        const float gain = testMuteModel ? 0.0f : v.gain;
        const float tube = v.tube * static_cast<float>(resonator);
        for (uint32_t i = 0; i < n; ++i) {
            float y = 0;
            for (int b = 0; b < v.blocks; ++b) {
                const F4 r = v.c[b] * v.zr[b] - v.s[b] * v.zi[b], im = v.s[b] * v.zr[b] + v.c[b] * v.zi[b];
                v.zr[b] = r, v.zi[b] = im;
                y += im[0] + im[1] + im[2] + im[3];
            }
            if (v.tube > 0) {
                const float r = v.rb * (y - v.rx2) + v.ra1 * v.ry1 + v.ra2 * v.ry2;
                v.rx2 = v.rx1, v.rx1 = y, v.ry2 = v.ry1, v.ry1 = r;
                y += r * tube * (tremStart + tremStep * static_cast<float>(tremAt + i + 1));
            }
            if (v.clickLeft) --v.clickLeft, y += v.clickAmp * v.noise.next();
            if (v.gated) {  // silent while the recording holds, then in as it fades out: t^2 (3 - 2 t)
                if (v.gateHold) {
                    --v.gateHold;
                    y = 0;
                } else {
                    v.gateT = std::min(1.0f, v.gateT + v.gateStep);
                    const float t = v.gateT;
                    y *= t * t * (3.0f - 2.0f * t);
                    if (t >= 1.0f) v.gated = false;
                }
            }
            out[i] = y * gain;
        }
    }

    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
        tremAt += n;
        for (Player& p : players) {
            if (!p.on) continue;
            const float* d = p.data;
            const double last = static_cast<double>(p.frames) - 1.0;
            double pos = p.pos;
            const float gl = p.gl, gr = p.gr;
            bool ended = false;
            uint32_t i = 0;
            const uint32_t full = std::min(n, p.hold);
            for (; i < full; ++i) {
                if (pos >= last) {
                    ended = true;
                    break;
                }
                const uint32_t at = static_cast<uint32_t>(pos);
                const float f = static_cast<float>(pos - at);
                const float x = d[at] + (d[at + 1] - d[at]) * f;
                l[i] += x * gl, r[i] += x * gr;
                pos += p.step;
            }
            p.hold -= std::min(p.hold, full);
            float t = p.fadeT;
            for (; !ended && i < n; ++i) {  // out as the model comes in: 1 - t^2 (3 - 2 t)
                if (pos >= last || t >= 1.0f) {
                    ended = true;
                    break;
                }
                t = std::min(1.0f, t + p.fadeStep);
                const float u = 1.0f - t * t * (3.0f - 2.0f * t);
                const uint32_t at = static_cast<uint32_t>(pos);
                const float f = static_cast<float>(pos - at);
                const float x = (d[at] + (d[at + 1] - d[at]) * f) * u;
                l[i] += x * gl, r[i] += x * gr;
                pos += p.step;
            }
            p.fadeT = t, p.pos = pos;
            if (ended || t >= 1.0f) p.on = false;
        }
    }
    bool postQuiet() const noexcept {
        for (const Player& p : players)
            if (p.on) return false;
        return true;
    }
    void clearPost() noexcept {
        for (Player& p : players) p.on = false;
        tremPhase = 0, tremStart = tremEnd = 1, tremStep = 0, tremAt = 0;
        pedal = false;
    }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(which);
        out[1] = static_cast<float>(tremPhase);
        out[2] = static_cast<float>(motor);
    }
};

}  // namespace caw::woodpecker
