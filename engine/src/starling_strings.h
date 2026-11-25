// Starling's plucked strings (1.1.3): the classical guitar and the concert harp, a recorded pluck carried on in phase by a measured waveguide string and a fitted body.
#pragma once

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <memory>
#include <new>

#include "body_bands.h"
#include "caw/library/fastmath.hpp"
#include "recorded_bank.h"
#include "timber_core.h"
#include "timber_piano_sim.h"  // psim::fitDispersion

namespace caw::starling {

using timber::clampd;
using timber::kControlFrames;
using timber::Shared;
using timber::VoiceBase;

inline constexpr int kInstruments = 2;
enum Which : int { kGuitar, kHarp };

// The measured tables (generated: tools/starling_strings_assets.py writes starling_strings_bank.inc from FreePats'
// Spanish Classical Guitar and VCSL's concert harp, both CC0). A zone: one recorded string; `key` its fundamental as
// recorded (MIDI, fractional: the guitar's A2 and C3 are 22 cents sharp, the harp's bass 22 cents flat), `B` its
// inharmonicity, `t60lo` the fundamental's decay and `t60hi` that of the partial at `fh` (near 2 kHz).
struct Zone {
    int instrument;
    float key, B, t60lo, t60hi, fh;
};
// A clip: one recorded pluck in the bank (normalised; `scale` its peak at the recorded level), `rms` its level over
// the crossfade, and its history: the same recording up to the end of its hold with the body taken off, where the
// model's string starts from.
struct Clip {
    int zone, layer;
    float vel;  // the layer's velocity (MIDI)
    float key;  // its pitch over the crossfade (MIDI, fractional: a plucked string starts sharp and settles)
    uint32_t first, frames;
    float scale, rms;
    uint32_t histFirst, histFrames;
    float histScale;
    float t60e0, t60eh;  // the string's first decay over the crossfade (the fundamental's, the partial at fh's)
};
// Each instrument's zones and clips (clip zone * layers + layer from firstClip), and its timing in the recording's
// own time: the recording alone for `hold` seconds, then the crossfade into the model over `fade`.
struct Layout {
    int firstZone, zones, firstClip, layers;
    float velSoft, velLoud;
    float hold, fade;
};
#include "starling_strings_bank.inc"
// The bodies (generated: tools/starling_strings_assets.py body, by instrument_bodies.py's method): each instrument's
// recorded partials over the model's string alone, as peaking bands.
#include "starling_bodies.inc"

// The range each instrument plays (MIDI, inclusive): the guitar's E2 to D6 (its recordings E2..C6), the pedal harp's
// C1 to G7 (its recordings E1..F7), as docs/engine.md says.
inline constexpr int kLow[kInstruments] = {40, 24}, kHigh[kInstruments] = {86, 103};
// [Assumption] where along the string (from the bridge) and how hard the recorded players plucked: a classical
// guitarist's right hand at the sound hole's rear edge, about a fifth of a 650 mm string; a harpist at about the
// middle of the string (the recordings' even partials are 10-20 dB under the odd ones in the middle register, as a
// pluck near the middle leaves them out) with the soft flesh of the finger (0.15: a contact cutoff near 2.3 kHz). They are the knobs' defaults: at them the
// recording plays as it is.
inline constexpr double kRecPosition[kInstruments] = {0.18, 0.45}, kRecHardness[kInstruments] = {0.5, 0.15};
// [Assumption] the strings a finger sliding along can be heard on (wound): the guitar's three bass strings (notes
// under G3 are mostly played on them), the harp's wire-wound bass strings (under C3).
inline constexpr double kWoundUnder[kInstruments] = {55.0, 48.0};
// [Assumption] the level of a single-layer recording at another velocity: (velocity / recorded)^1.6, 31 dB from
// MIDI 20 to 127, as a guitar's dynamics from pp to ff.
inline constexpr double kVelocityExponent = 1.6;

// A pluck's spectral envelope as the knobs move it away from the recording's, applied alike to the recorded attack
// and to the history the string starts from (so the two stay one sound): the pluck position's (a triangle's bridge
// force at a given finger force is pi position flat up to the n-th partial, n = 1 / (sqrt 2 pi position), then falls
// 6 dB an octave the same for any position: a first-order shelf, the recorded one undone, the new one applied, its
// level shared between the two ends so the note's loudness holds: nearer the bridge thinner and brighter, nearer the
// middle fuller and darker) and the finger's (a second-order low-pass at the contact's
// cutoff, Timber's dynamics filter: 300 + 9000 h v^1.3 + 1500 v Hz; the ratio of the new to the recorded). Bilinear,
// prewarped.
struct Tilt {
    float b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;
    float c0 = 1, c1 = 0, d1 = 0, s = 0;
    float run(float x) noexcept {
        const float y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        const float u = c0 * y + s;
        s = c1 * y - d1 * u;
        return u;
    }
    void clear() noexcept { z1 = z2 = s = 0; }
    static double warp(double hz, double sr) noexcept { return std::tan(timber::kPi * std::min(hz, 0.45 * sr) / sr); }
    void set(double f0, double pos, double posRec, double cutoff, double cutoffRec, double sr) noexcept {
        // Second order: (s^2/wr^2 + sqrt2 s/wr + 1) / (s^2/wn^2 + sqrt2 s/wn + 1), s = (1 - z^-1) / (1 + z^-1).
        const double wr = warp(cutoffRec, sr), wn = warp(cutoff, sr);
        const double nr = 1.0 / (wr * wr), mr = 1.4142135623730951 / wr, nn = 1.0 / (wn * wn), mn = 1.4142135623730951 / wn;
        const double B0 = nr + mr + 1, B1 = 2 - 2 * nr, B2 = nr - mr + 1, A0 = nn + mn + 1, A1 = 2 - 2 * nn, A2 = nn - mn + 1;
        b0 = static_cast<float>(B0 / A0), b1 = static_cast<float>(B1 / A0), b2 = static_cast<float>(B2 / A0);
        a1 = static_cast<float>(A1 / A0), a2 = static_cast<float>(A2 / A0);
        // First order: zero at the recorded position's corner, pole at the new one's.
        const double k = 1.0 / (1.4142135623730951 * timber::kPi);
        const double wz = warp(f0 * k / posRec, sr), wp = warp(f0 * k / pos, sr), level = std::sqrt(pos / posRec);
        const double g = level * wp / wz;
        c0 = static_cast<float>(g * (wz + 1) / (wp + 1)), c1 = static_cast<float>(g * (wz - 1) / (wp + 1));
        d1 = static_cast<float>((wp - 1) / (wp + 1));
        clear();
    }
};

// A recorded pluck playing: from the bank at the pitch ratio, through the voice's tilt (and its palm mute's decay),
// panned, held, then fading out as the string fades in.
struct Player {
    const float* data = nullptr;
    uint32_t frames = 0;
    double pos = 0, step = 1;
    float gl = 0, gr = 0, env = 1, envMul = 1;
    uint32_t hold = 0;
    float fadeT = 0, fadeStep = 0;
    Tilt tilt;
    bool on = false;
};

// The model (one class for both instruments; `which` picks the tables). Each voice is an extended Karplus-Strong
// string as Timber's plucked one (a delay loop, a tuning allpass and a loss from two decay times, after Jaffe and
// Smith; here the loss is linear phase, Smith's three-tap filter), with first-order dispersion allpasses for the string's measured inharmonicity (fitted per zone
// as Timber's piano does), its loss from the zone's measured decays. With a recording (every key in the range): the
// recording plays alone for the hold, and the loop is filled at that moment with the recording's own last samples,
// its body taken off (the history): the loop then predicts the string from its real past, so recording and model
// are the same partials in the same phase, and a complementary crossfade (smoothstep, the gains summing to 1)
// neither cancels nor bumps. The body after the voices' sum puts the body back on the string (the recordings carry
// their own; Body moves both alike). Without a recording (no bank, or the tests') the string is plucked from a
// triangle at `position`, as Timber's Simulated pluck. Fret buzz (the guitar at Normal and High, String noise over
// about 0.5): Timber's string-fret collision; slides on wound strings and the finger's touch on a damped string:
// Timber's handling noises.
struct Strings {
    static constexpr uint32_t kEcoCap = 12, kNormalCap = 24, kHighCap = 32, kPool = kHighCap + 8;
    static constexpr bool kRestrike = true, kHeldSilenceEnds = true;
    static constexpr double kMinLife = 0.3, kSpread = 0.35;
    enum P : uint32_t { kPosition, kHardness, kDamping, kNoise, kSustain, kTier, kModelParams };
    static constexpr int kPlayers = 32, kMaxStages = 4;
    // [Assumption] how long a plucked string's first, faster decay lasts before its slower one (the two
    // polarisations' handover: Weinreich, JASA 62(6), 1977, for the piano; not measured here): 0.25 s.
    static constexpr double kEarlyS = 0.25;
    static constexpr int kZoneCount = sizeof(kZones) / sizeof(kZones[0]);

    struct Voice : VoiceBase {
        timber::Line line;
        uint32_t D = 2;
        float eta = 0, x1 = 0, y1 = 0, b = 0, p = 0, t1 = 0, t2 = 0;  // the loss: gain b, taps p (1 - 2p) p
        float bFree = 0, pFree = 0, bDamped = 0, pDamped = 0, damp = 0;
        // The first decay (a plucked string's prompt sound: the recording's, over its crossfade) and how much of it is
        // left (1 at the pluck, falling with a time constant of kEarlyS).
        float bEarly = 0, pEarly = 0, early = 0;
        double t60e0 = 1, t60eh = 1;
        float dispA = 0, dx[kMaxStages] = {}, dy[kMaxStages] = {};
        int stages = 0, zone = 0;
        double tunedPitch = -1, tunedFor = -1;
        int tunedStages = -1;
        // The pluck without a recording: the triangle's period, its position, the contact's low-pass.
        uint32_t excLeft = 0, shapeAt = 0, shapeLen = 1;
        float excGain = 0, hk = 1, h = 0, beta = 0.2f;
        // The fade-in under the recording.
        bool gated = false;
        uint32_t gateHold = 0;
        float gateT = 0, gateStep = 0;
        // Fret buzz, slides and the finger's touch (as timber::Pluck's).
        float gap = 0, slidePhase = 0, slideInc = 0, slideAmp = 0, slideStep = 0, touchAmp = 0;
        uint32_t touchLeft = 0, scrapeLeft = 0, scrapeLen = 1;
        float scrapeAmp = 0;
        double slideFrom = -1;
        bool wound = false;
        timber::Biquad longitudinal, scrapeBp;
        timber::Lp1 touchLp;
        timber::Noise noise;
    };

    int which = 0;
    double position = 0.2, hardness = 0.5, damping = 0, noises = 0.15, sustain = 0;
    int tier = kQualityNormal, stages = 2;
    bool buzz = true, ring = false;
    double sr = 48000;
    float earlyStep = 1;  // the first decay's share left after a control block
    std::shared_ptr<const recorded::Bank> bank;
    Player players[kPlayers];
    std::unique_ptr<float[]> memory, scratch;
    uint32_t lineLen = 0, scratchLen = 0;
    Voice* voices = nullptr;
    uint32_t count = 0;
    float dispersion[kZoneCount][3] = {};  // each zone's coefficient for 1, 2 and 4 stages, at this rate
    BodyFilter body, attackBody;  // the model's body (Body x 2: 1 as recorded); the recordings' change from theirs
    bool attackBodyOn = false;
    bool testMuteRecordings = false;  // the tests' A/B (never used for sound)
    bool testMuteModel = false;
    bool testUnfaded = false;  // the recording played to its end, never faded (the tests' measure of the real instrument)

    const Layout& layout() const noexcept { return kLayouts[which]; }
    BodyResponse bodyBands() const noexcept {
        return which == kGuitar ? BodyResponse{kGuitarBody, static_cast<uint32_t>(sizeof(kGuitarBody) / sizeof(kGuitarBody[0]))}
                                : BodyResponse{kHarpBody, static_cast<uint32_t>(sizeof(kHarpBody) / sizeof(kHarpBody[0]))};
    }
    size_t allocBytes() const noexcept { return (static_cast<size_t>(count) * lineLen + scratchLen) * sizeof(float); }
    static lib::ReverbSettings room() noexcept {
        lib::ReverbSettings r;
        r.size = 0.55, r.decay = 1.7, r.damping = 0.4, r.mix = 1.0, r.width = 1.0;
        return r;
    }
    bool prepare(double rate, Voice* v, uint32_t n) noexcept {
        sr = rate;
        voices = v, count = n;
        earlyStep = static_cast<float>(detExp(-static_cast<double>(kControlFrames) / (kEarlyS * sr)));
        // The loop holds a period of the lowest pitch a key plays (an octave under the range).
        lineLen = timber::pow2At(static_cast<uint32_t>(sr / timber::noteHz(kLow[which] - 12.0)) + 16);
        memory.reset(new (std::nothrow) float[static_cast<size_t>(n) * lineLen]());
        // The history, at most the hold at the slowest a recording plays (4.5 semitones under its zone).
        scratchLen = static_cast<uint32_t>(layout().hold * sr * detPow(2.0, 4.5 / 12.0)) + 16;
        scratch.reset(new (std::nothrow) float[scratchLen]());
        if (!memory || !scratch) return false;
        bindAll();
        if (!bank) bank = recorded::acquire(which == kGuitar ? recorded::BankId::StarlingGuitar : recorded::BankId::StarlingHarp);
        static constexpr int kStages[3] = {1, 2, 4};
        const Layout& lay = layout();
        for (int z = lay.firstZone; z < lay.firstZone + lay.zones; ++z)
            for (int s = 0; s < 3; ++s)
                dispersion[z][s] = timber::psim::fitDispersion(timber::noteHz(std::round(kZones[z].key)), kZones[z].B, kStages[s], sr);
        body.load(bodyBands(), 1.0f, sr);
        return true;
    }
    void bindAll() noexcept {
        for (uint32_t k = 0; k < count; ++k) voices[k].line.bind(memory.get() + static_cast<size_t>(k) * lineLen, lineLen);
    }
    void reset() noexcept {
        bindAll();
        clearPost();
    }

    void control(const double* p, const Shared& s) noexcept {
        position = clampd(p[kPosition], 0.04, 0.5);
        hardness = clampd(p[kHardness], 0, 1);
        damping = clampd(p[kDamping], 0, 1);
        noises = clampd(p[kNoise], 0, 1);
        sustain = clampd(p[kSustain], 0, 1);
        const int t = static_cast<int>(clampd(p[kTier], 0, 3) + 0.5);
        tier = t == 0 ? s.quality : t - 1;
        stages = tier == kQualityEco ? 1 : (tier == kQualityHigh ? 4 : 2);
        buzz = which == kGuitar && tier != kQualityEco;
        ring = std::max(sustain, s.pedal) >= 0.5;
        // Body 0.5 is the instrument as recorded: the string gets the body at twice the knob, the recordings (which
        // have it already) the change from 1.
        const float amount = static_cast<float>(2.0 * s.body);
        body.load(bodyBands(), amount, sr);
        const bool on = amount != 1.0f;
        if (on) attackBody.load(bodyBands(), amount - 1.0f, sr);
        else if (attackBodyOn) attackBody.clear();
        attackBodyOn = on;
        for (Player& pl : players)  // tiny values flushed on the control grid only, so any block size gives the same bits
            pl.tilt.z1 = timber::flushf(pl.tilt.z1), pl.tilt.z2 = timber::flushf(pl.tilt.z2), pl.tilt.s = timber::flushf(pl.tilt.s);
    }

    // The loss for decays t60lo at the fundamental and t60hi at the zone's fh (palm mute shortens both, the high one
    // more): its gain b and taps p.
    void loss(const Voice& v, double t60lo, double t60hi, float& b, float& p) const noexcept {
        const Zone& zn = kZones[v.zone];
        const double f0 = timber::noteHz(clampd(v.pitch, kLow[which] - 12.0, kHigh[which] + 12.0)), w0 = timber::kTwoPi * f0 / sr;
        const double mute = muteFactor(damping);
        const double tlo = std::max(0.05, t60lo * mute), thi = std::min(tlo, std::max(0.03, t60hi * mute * (1.0 - 0.6 * damping)));
        double fh = zn.fh * f0 / timber::noteHz(zn.key);
        if (fh < 1.5 * f0) fh = 2.0 * f0;  // the treble's measure was at the fundamental: the octave decays as fast
        const double g0 = detPow(10.0, -3.0 / (tlo * f0)), gh = detPow(10.0, -3.0 / (thi * f0));
        const double taps = fh < 0.45 * sr ? lossTaps(gh / g0, w0, timber::kTwoPi * fh / sr) : 0.0;
        p = static_cast<float>(taps);
        b = static_cast<float>(std::min(0.99999, g0 / lossMag(taps, w0)));
    }
    // The loop for the voice's pitch: its loss from the zone's two decays (and the recording's first decay, which the
    // voice's loss moves from to them: early), its dispersion, its delay and tuning allpass so the fundamental is at
    // the pitch (equal temperament, A440).
    void design(Voice& v) noexcept {
        const Zone& zn = kZones[v.zone];
        const double pitch = clampd(v.pitch, kLow[which] - 12.0, kHigh[which] + 12.0);
        const double f0 = timber::noteHz(pitch), w0 = timber::kTwoPi * f0 / sr;
        loss(v, zn.t60lo, zn.t60hi, v.bFree, v.pFree);
        loss(v, v.t60e0, v.t60eh, v.bEarly, v.pEarly);
        v.stages = stages;
        v.dispA = dispersion[v.zone][stages == 1 ? 0 : (stages == 2 ? 1 : 2)];
        // The loss is linear phase, one frame's delay at every frequency: it does not detune the upper partials (a
        // one-pole's phase put a treble string's second partial cents off, and the string drifted from the recording).
        const double rest = std::max(2.5, sr / f0 - 1.0 - stages * timber::allpassDelay(v.dispA, w0));
        uint32_t D = static_cast<uint32_t>(std::floor(rest - 0.5));
        D = std::min<uint32_t>(std::max<uint32_t>(D, 2), v.line.mask - 4);
        v.D = D;
        v.eta = static_cast<float>(timber::allpassFor(clampd(rest - D, 0.3, 1.7), w0));
        v.tunedPitch = v.pitch;
        v.tunedStages = stages;
    }
    // The loss (Smith's three-tap loop filter, p (1 - 2p) p): its gain at w over its gain at DC, and the p (0..0.25)
    // whose gain at wh is r times its gain at w0.
    static double lossMag(double p, double w) noexcept { return 1.0 - 2.0 * p * (1.0 - std::cos(w)); }
    static double lossTaps(double r, double w0, double wh) noexcept {
        const double c0 = 1.0 - std::cos(w0), ch = 1.0 - std::cos(wh), den = 2.0 * (ch - r * c0);
        return den > 0 ? clampd((1.0 - r) / den, 0.0, 0.25) : 0.0;
    }
    // A palm mute (or a hand on the harp's strings) shortens every decay: 25 times at 1 (the guitar's 8 s E3 to 0.3 s).
    static double muteFactor(double damping) noexcept { return detExp(-3.2188758248682006 * damping); }
    void dampedLoss(Voice& v, double release) noexcept {
        const double f0 = timber::noteHz(clampd(v.pitch, kLow[which] - 12.0, kHigh[which] + 12.0));
        const double p = 0.25;  // a finger on the string: the highs go first
        v.pDamped = static_cast<float>(p);
        v.bDamped = static_cast<float>(std::min(0.999, detPow(10.0, -3.0 / (release * f0)) / lossMag(p, timber::kTwoPi * f0 / sr)));
        v.tunedFor = release;
    }

    Player* freePlayer() noexcept {
        Player* pick = nullptr;
        for (Player& p : players) {
            if (!p.on) return &p;
            if (!pick || p.pos > pick->pos) pick = &p;  // all busy: the one furthest through
        }
        return pick;
    }
    // The contact's cutoff (Timber's dynamics filter) for hardness h at velocity vel (0..1).
    static double cutoff(double h, double vel) noexcept { return 300.0 + 9000.0 * h * detPow(vel, 1.3) + 1500.0 * vel; }

    void start(Voice& v, const Shared& s) noexcept {
        const Layout& lay = layout();
        const double pitch = clampd(v.pitch, kLow[which] - 12.0, kHigh[which] + 12.0);
        int zi = 0;
        for (int z = 1; z < lay.zones; ++z)
            if (std::fabs(pitch - kZones[lay.firstZone + z].key) < std::fabs(pitch - kZones[lay.firstZone + zi].key)) zi = z;
        v.zone = lay.firstZone + zi;
        const Zone& zone = kZones[v.zone];
        v.t60e0 = zone.t60lo, v.t60eh = zone.t60hi, v.early = 0;
        design(v);
        dampedLoss(v, s.release);
        v.x1 = v.y1 = v.t1 = v.t2 = v.h = 0;
        for (float& d : v.dx) d = 0;
        for (float& d : v.dy) d = 0;
        v.b = v.bFree, v.p = v.pFree, v.damp = 0;
        v.excLeft = 0, v.gated = false, v.gateHold = 0;
        // The layer by velocity and the level between the layers log-linear in velocity (a layer past them,
        // extrapolated); one layer: its level at the velocity by kVelocityExponent.
        const double mv = std::max(1.0, 127.0 * v.velocity);
        const Clip* clips = kClips + lay.firstClip + zi * lay.layers;
        int layer = 0;
        double R = 0;
        if (lay.layers == 2) {
            layer = mv >= 0.5 * (clips[0].vel + clips[1].vel) ? 1 : 0;
            const double r0 = clips[0].rms, r1 = std::max(clips[1].rms, 1.25f * clips[0].rms);
            const double span = std::max(1.0f, clips[1].vel - clips[0].vel);
            const double tv = clampd((mv - clips[0].vel) / span, -1.5, 1.25);
            R = r0 * detPow(r1 / r0, tv);
        } else {
            R = clips[0].rms * detPow(mv / clips[0].vel, kVelocityExponent);
        }
        const Clip& clip = clips[layer];
        const double g = clip.rms > 0 ? R / clip.rms : 0.0;
        const double f0 = timber::noteHz(pitch);
        // The recording's speed: its pitch over the crossfade to the note's, so the string carries on in tune with it.
        const double ratio = detPow(2.0, (pitch - clip.key) / 12.0);
        Tilt tilt;
        // The finger's cutoff held within a third and 2.5 times the recording's: the recording's own pluck can be
        // softened or sharpened that far before its noise and click are what is heard.
        const double cRec = cutoff(kRecHardness[which], clip.vel / 127.0);
        tilt.set(f0, position, kRecPosition[which], clampd(cutoff(hardness, v.velocity), cRec / 3.0, 2.5 * cRec), cRec, sr);
        // A palm mute or a damping hand on the recording too: the loop's extra loss at the fundamental, from the strike.
        const double t0 = std::max(0.05, static_cast<double>(zone.t60lo)), t1 = std::max(0.05, zone.t60lo * muteFactor(damping));
        const float envMul = static_cast<float>(detExp(-6.907755278982137 * (1.0 / t1 - 1.0 / t0) / sr));
        const double step = bank ? ratio * bank->rate / sr : 1.0;
        const uint32_t gateHold = static_cast<uint32_t>(lay.hold * sr / ratio);
        const bool recorded = bank && !testMuteRecordings && std::fabs(pitch - zone.key) <= 4.5 &&
                              static_cast<uint64_t>(clip.first) + clip.frames <= bank->frames &&
                              static_cast<uint64_t>(clip.histFirst) + clip.histFrames <= bank->frames &&
                              gateHold >= v.D + 2 && gateHold <= scratchLen &&
                              (gateHold - 1) * step + 2.0 < clip.histFrames;
        float peak = 0;
        if (recorded) {
            // The history at the output's rate and the note's pitch, as the player will play the recording: the same
            // interpolation, tilt and palm mute, so the loop starts on what the listener heard.
            const float* hd = bank->pcm.get() + clip.histFirst;
            const float hg = static_cast<float>(g * clip.histScale);
            Tilt ht = tilt;
            float env = 1;
            float* h = scratch.get();
            for (uint32_t j = 0; j < gateHold; ++j) {
                const double at = j * step;
                const uint32_t i = static_cast<uint32_t>(at);
                const float f = static_cast<float>(at - i);
                h[j] = ht.run((hd[i] + (hd[i + 1] - hd[i]) * f) * hg) * env;
                env *= envMul;
            }
            // The loop's filters run over the history's last samples (their memory is a few frames), the loss's
            // state the history itself; then the line holds the history's last period.
            const uint32_t H = gateHold, D = v.D;
            const uint32_t from = std::max(D, H > 96 ? H - 96 : 0u);
            for (uint32_t j = from; j < H; ++j) {
                float x = h[j - D];
                for (int m = 0; m < v.stages; ++m) {
                    const float u = v.dispA * (x - v.dy[m]) + v.dx[m];
                    v.dx[m] = x, v.dy[m] = u, x = u;
                }
                const float t = v.eta * (x - v.y1) + v.x1;
                v.x1 = x, v.y1 = t;
                v.t2 = v.t1, v.t1 = t;
            }
            for (uint32_t j = H - D - 1; j < H; ++j) v.line.push(h[j]), peak = std::max(peak, std::fabs(h[j]));
            Player* pl = freePlayer();
            *pl = Player{};
            pl->data = bank->pcm.get() + clip.first;
            pl->frames = clip.frames;
            pl->step = step;
            const float a = static_cast<float>(g * clip.scale);
            pl->gl = a * v.panL, pl->gr = a * v.panR;
            pl->envMul = envMul;
            pl->tilt = tilt;
            const float fade = static_cast<float>(ratio / (lay.fade * sr));
            pl->hold = testUnfaded ? 0xFFFFFFFFu : gateHold, pl->fadeStep = fade;
            pl->on = true;
            v.gated = true, v.gateHold = gateHold, v.gateT = 0, v.gateStep = fade;
            v.t60e0 = clip.t60e0, v.t60eh = clip.t60eh, v.early = 1;
            loss(v, v.t60e0, v.t60eh, v.bEarly, v.pEarly);
            v.b = v.bEarly, v.p = v.pEarly;
        } else {
            // Plucked from rest: a triangle with its corner at `position` (the round trip: out, then its inverted
            // mirror), through the contact's low-pass; its level the recording's at this velocity (a triangle's RMS
            // is its peak over sqrt 3).
            for (uint32_t d = 1; d <= v.D + 1; ++d) v.line.push(0.0f);
            const uint32_t period = v.D + 1;
            v.excLeft = period, v.shapeAt = 0, v.shapeLen = std::max<uint32_t>(4, period);
            v.beta = static_cast<float>(position);
            v.hk = static_cast<float>(1.0 - detExp(-timber::kTwoPi * std::min(cutoff(hardness, v.velocity), 0.45 * sr) / sr));
            v.excGain = static_cast<float>(R * 1.7320508075688772);
            peak = v.excGain;
        }
        // Fret buzz: the gap to the frets as a share of the string's swing, so String noise sets how hard a pluck
        // must be to reach them (none at the default).
        v.gap = buzz ? static_cast<float>(peak * std::max(0.08, 2.2 - 2.0 * noises)) : 0.0f;
        v.wound = pitch < kWoundUnder[which];
        v.slideFrom = v.pitch, v.slidePhase = 0, v.slideInc = 0, v.slideAmp = 0, v.slideStep = 0;
        // The longitudinal mode the windings ring: about 13x the transverse fundamental (timber::Pluck's).
        v.longitudinal.band(clampd(13.0 * f0, 600.0, 0.4 * sr), 6.0, sr);
        v.longitudinal.clear();
        v.touchLeft = 0, v.touchAmp = 0;
        // The finger or nail leaving the string: a scrape of 8 ms, an octave-wide band at the windings' mode (a wound
        // string) or 3 kHz (a plain one), its level String noise squared (quiet at the default, under -30 dB of the
        // note; the recordings hold their own) [Assumption: the levels and bands, by ear].
        v.scrapeLen = v.scrapeLeft = static_cast<uint32_t>(0.008 * sr);
        v.scrapeAmp = static_cast<float>(R * noises * noises * (v.wound ? 8.0 : 5.0));
        v.scrapeBp.band(v.wound ? clampd(13.0 * f0, 600.0, 0.4 * sr) : std::min(3000.0, 0.4 * sr), 1.4, sr);
        v.scrapeBp.clear();
        v.touchLp.set(900.0, sr);
        v.touchLp.clear();
        v.noise.s = 0x5EEDu + 131u * v.key + static_cast<uint32_t>(s.clock);
    }

    void release(Voice& v, const Shared&) noexcept {
        if (ring) return;  // let ring (the harp's default; the guitar's sustain pedal)
        v.touchLeft = static_cast<uint32_t>(0.012 * sr);
        v.touchAmp = static_cast<float>(0.25 * noises) * std::min(1.0f, v.level);
    }
    void voiceControl(Voice& v, const Shared& s) noexcept {
        if (std::fabs(v.pitch - v.tunedPitch) > 1e-4 || v.tunedStages != stages) design(v), v.tunedFor = -1;
        if (s.release != v.tunedFor) dampedLoss(v, s.release);
        const float target = (!v.held && !ring) ? 1.0f : 0.0f;
        v.damp += (target - v.damp) * 0.3f;
        if (std::fabs(target - v.damp) < 1e-4f) v.damp = target;
        v.early = timber::flushf(v.early * earlyStep);
        const float bf = v.bFree + (v.bEarly - v.bFree) * v.early, pf = v.pFree + (v.pEarly - v.pFree) * v.early;
        v.b = bf + (v.bDamped - bf) * v.damp;
        v.p = pf + (v.pDamped - pf) * v.damp;
        v.x1 = timber::flushf(v.x1), v.y1 = timber::flushf(v.y1), v.t1 = timber::flushf(v.t1), v.t2 = timber::flushf(v.t2), v.h = timber::flushf(v.h);
        for (int m = 0; m < kMaxStages; ++m) v.dx[m] = timber::flushf(v.dx[m]), v.dy[m] = timber::flushf(v.dy[m]);
        // The finger's slide over this control block along a 650 mm scale (timber::Pluck's), on a wound string.
        const double dt = kControlFrames / sr;
        const double from = 0.65 * (1.0 - detPow(2.0, -(v.slideFrom - 40.0) / 12.0));
        const double to = 0.65 * (1.0 - detPow(2.0, -(v.pitch - 40.0) / 12.0));
        const double speed = v.wound ? std::fabs(to - from) / dt : 0.0;
        v.slideFrom = v.pitch;
        v.slideInc = static_cast<float>(std::min(0.45, speed / 0.0008 / sr));
        const float amp = static_cast<float>(std::sqrt(std::min(1.0, speed / 0.4)) * 0.5 * noises * std::min(1.0f, 4.0f * v.level));
        v.slideStep = (amp - v.slideAmp) / kControlFrames;
        v.longitudinal.flush();
        v.scrapeBp.flush();
        v.touchLp.flush();
    }

    void render(Voice& v, float* out, uint32_t n) noexcept {
        const float mute = testMuteModel ? 0.0f : 1.0f;
        for (uint32_t i = 0; i < n; ++i) {
            if (v.gateHold) {  // the recording alone: the string waits where its history ends
                --v.gateHold;
                out[i] = 0;
                continue;
            }
            float e = 0;
            if (v.excLeft) {
                --v.excLeft;
                const float u = 2.0f * static_cast<float>(v.shapeAt++) / static_cast<float>(v.shapeLen);
                const float x = u < 1.0f ? u : 2.0f - u;
                const float tri = x < v.beta ? x / v.beta : (1.0f - x) / (1.0f - v.beta);
                v.h += v.hk * ((u < 1.0f ? tri : -tri) - v.h);
                e = v.h * v.excGain;
            }
            float x = v.line.at(v.D);
            for (int m = 0; m < v.stages; ++m) {
                const float u = v.dispA * (x - v.dy[m]) + v.dx[m];
                v.dx[m] = x, v.dy[m] = u, x = u;
            }
            const float t = v.eta * (x - v.y1) + v.x1;
            v.x1 = x, v.y1 = t;
            const float z = v.b * (v.p * (t + v.t2) + (1.0f - 2.0f * v.p) * v.t1);
            v.t2 = v.t1, v.t1 = t;
            float w = z + e;
            if (v.gap > 0.0f && w < -v.gap) w = -v.gap - 0.7f * (w + v.gap);  // the fret: the string bounces off it, losing some
            v.line.push(w);
            if (v.gated) {  // in as the recording fades out: t^2 (3 - 2 t)
                v.gateT = std::min(1.0f, v.gateT + v.gateStep);
                const float g = v.gateT;
                w *= g * g * (3.0f - 2.0f * g);
                if (g >= 1.0f) v.gated = false;
            }
            out[i] = w * mute;
        }
        if (v.slideAmp > 0.0f || v.slideStep != 0.0f) {
            for (uint32_t i = 0; i < n; ++i) {
                v.slideAmp = std::max(0.0f, v.slideAmp + v.slideStep);
                v.slidePhase += v.slideInc;
                float pulse = 0;
                if (v.slidePhase >= 1.0f) v.slidePhase -= 1.0f, pulse = 1.0f;
                out[i] += v.longitudinal.run(v.slideAmp * (pulse + 0.15f * v.noise.next()));
            }
            if (v.slideAmp < 1e-6f && v.slideStep <= 0.0f) v.slideAmp = 0, v.slideStep = 0;
        }
        if (v.scrapeLeft) {
            const uint32_t m = std::min(n, v.scrapeLeft);
            for (uint32_t i = 0; i < m; ++i) {
                const float env = static_cast<float>(v.scrapeLeft - i) / static_cast<float>(v.scrapeLen);
                out[i] += v.scrapeBp.run(v.scrapeAmp * env * v.noise.next());
            }
            v.scrapeLeft -= m;
        }
        if (v.touchLeft) {
            const uint32_t m = std::min(n, v.touchLeft);
            for (uint32_t i = 0; i < m; ++i) out[i] += v.touchAmp * v.touchLp.run(v.noise.next());
            v.touchLeft -= m;
        }
    }

    void post(float* l, float* r, uint32_t n, const Shared&) noexcept {
        body.process(l, r, n);
        float pl[kControlFrames] = {}, pr[kControlFrames] = {};
        for (Player& p : players) {
            if (!p.on) continue;
            const float* d = p.data;
            const double last = static_cast<double>(p.frames) - 1.0;
            double pos = p.pos;
            bool ended = false;
            float t = p.fadeT, env = p.env;
            for (uint32_t i = 0; i < n; ++i) {
                if (pos >= last) {
                    ended = true;
                    break;
                }
                float u = 1.0f;
                if (p.hold) {
                    --p.hold;
                } else {  // out as the string comes in: 1 - t^2 (3 - 2 t)
                    if (t >= 1.0f) {
                        ended = true;
                        break;
                    }
                    t = std::min(1.0f, t + p.fadeStep);
                    u = 1.0f - t * t * (3.0f - 2.0f * t);
                }
                const uint32_t at = static_cast<uint32_t>(pos);
                const float f = static_cast<float>(pos - at);
                const float x = p.tilt.run(d[at] + (d[at + 1] - d[at]) * f) * env * u;
                env *= p.envMul;
                pl[i] += x * p.gl, pr[i] += x * p.gr;
                pos += p.step;
            }
            p.fadeT = t, p.pos = pos, p.env = env;
            if (ended || t >= 1.0f) p.on = false;
        }
        if (attackBodyOn) attackBody.process(pl, pr, n);
        for (uint32_t i = 0; i < n; ++i) l[i] += pl[i], r[i] += pr[i];
    }
    bool postQuiet() const noexcept {
        for (const Player& p : players)
            if (p.on) return false;
        return true;
    }
    void clearPost() noexcept {
        for (Player& p : players) p.on = false;
        body.clear();
        attackBody.clear();
    }
    void display(float* out) const noexcept {
        out[0] = static_cast<float>(which);
        out[1] = static_cast<float>(position);
        out[2] = static_cast<float>(damping);
    }
};

}  // namespace caw::starling
