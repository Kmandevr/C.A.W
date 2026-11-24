// Rook's kit builders (1.1.2): Synth kits from a seed and a style, Produced kits from role templates, Acoustic kits from a shelf of pieces, e-drum note maps and the finishing tools.
#include "drums_kits.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <deque>
#include <string>

#include "builtin_drums_layout.h"
#include "caw/detmath.hpp"
#include "drums_acoustic.h"
#include "json.h"
#include "presets.h"
#include "wav.h"

namespace caw {

namespace drums {

namespace {

using State = std::vector<double>;  // every parameter of the instrument, by descriptor index

State defaults() {
    State s(kParamCount);
    const ParameterDescriptor* t = parameterTable();
    for (uint32_t k = 0; k < kParamCount; ++k) s[k] = t[k].defaultValue;
    return s;
}
double& padAt(State& s, uint32_t pad, uint32_t p) { return s[padParam(pad, p)]; }
double& pieceAt(State& s, uint32_t pc, uint32_t p) { return s[pieceParam(pc, p)]; }
Voice voiceOf(const State& s, uint32_t pad) {
    Voice v;
    for (uint32_t k = 0; k < kPadParams; ++k) v[k] = s[padParam(pad, k)];
    return v;
}
void setVoice(State& s, uint32_t pad, const Voice& v) {
    for (uint32_t k = 0; k < kPadParams; ++k) s[padParam(pad, k)] = constrainPad(k, v[k]);
}
// Every pad stops answering its note (a built kit starts from an empty instrument).
void clearPads(State& s) {
    for (uint32_t pad = 0; pad < kPads; ++pad) padAt(s, pad, kNote) = kNoteOff;
}
std::vector<std::pair<uint32_t, double>> changed(const State& s) {
    const ParameterDescriptor* t = parameterTable();
    std::vector<std::pair<uint32_t, double>> out;
    for (uint32_t k = 0; k < kParamCount; ++k)
        if (s[k] != t[k].defaultValue) out.emplace_back(k, s[k]);
    return out;
}

// A deterministic stream of numbers in 0..1.
struct Rng {
    uint32_t state;
    double next() {
        state = hash32(state * 0x9E3779B1u + 0x7F4A7C15u);
        return state / 4294967296.0;
    }
};

// ---------- Pitch and key ----------

double midiOf(double hz) { return 69.0 + 12.0 * std::log2(hz / 440.0); }
double hzOf(double midi) { return 440.0 * std::exp2((midi - 69.0) / 12.0); }
// The nearest note to `hz` in `key`'s natural minor (0 = C), in Hz.
double nearestInKey(double hz, int key) {
    static constexpr bool kMinor[12] = {true, false, true, true, false, true, false, true, true, false, true, false};
    const double m = midiOf(hz);
    double best = std::round(m), err = 1e9;
    for (int n = static_cast<int>(std::floor(m)) - 6; n <= static_cast<int>(std::ceil(m)) + 6; ++n)
        if (kMinor[((n - key) % 12 + 12) % 12] && std::fabs(n - m) < err) err = std::fabs(n - m), best = n;
    return hzOf(best);
}
// The pitch (Hz) a Layers pad sounds, from its main pitched layer, or 0.
double padHz(const Voice& v) {
    double f = 0.0;
    if (v[kBodyOn] >= 0.5) f = v[kBodyFreq];
    else if (v[kFmOn] >= 0.5) f = v[kFmFreq];
    else if (v[kPhysOn] >= 0.5) f = v[kPhysFreq];
    else if (v[kResOn] >= 0.5) f = v[kResFreq];
    return f > 0.0 ? f * std::exp2(v[kTune] / 12.0) : 0.0;
}
bool pitched(int type) { return type == kTypeKick || type == kTypeTom || type == kTypeBass || type == kTypeSnare; }
// Moves a pitched Layers pad onto the key.
void tuneVoice(Voice& v, int key) {
    if (key < 0 || !pitched(static_cast<int>(v[kType]))) return;
    const double f = padHz(v);
    if (f <= 0.0) return;
    v[kTune] = constrainPad(kTune, v[kTune] + 12.0 * std::log2(nearestInKey(f, key) / f));
}

// A generated pad keeps only the per-pad dynamics its role needs: the randomizer's compressor, transient shaper,
// clipper and drive switch on per voice (and oversample), so a kit's character goes on its bus instead.
void lean(Voice& v, bool keepDrive) {
    const int type = static_cast<int>(v[kType]);
    const bool hit = type == kTypeKick || type == kTypeSnare || type == kTypeClap || type == kTypeBass;
    v[kComp] = 0.0;
    v[kClip] = kClipOff;
    if (!hit) v[kTrAttack] = 0.0, v[kTrSustain] = 0.0, v[kEqLow] = 0.0, v[kEqMid] = 0.0, v[kEqHigh] = 0.0;
    if (!keepDrive || !hit) v[kDriveType] = kDriveOff;
}

// ---------- Level matching (renders each pad: control thread) ----------

double targetPeakDb(int type) {
    switch (type) {
        case kTypeKick: case kTypeBass: return -1.0;
        case kTypeSnare: case kTypeClap: return -3.0;
        case kTypeTom: return -5.0;
        case kTypeClosedHat: case kTypeOpenHat: case kTypePedalHat: case kTypeShaker: return -9.0;
        default: return -8.0;
    }
}
void matchLevel(Voice& v) {
    std::vector<float> hit;
    Voice probe = v;
    probe[kLevel] = 0.0;
    if (!renderVoice(probe, 48000.0, 0.4, hit)) return;
    float peak = 0.0f;
    for (float x : hit) peak = std::max(peak, std::fabs(x));
    if (peak < 1e-5f) return;
    v[kLevel] = constrainPad(kLevel, targetPeakDb(static_cast<int>(v[kType])) - 20.0 * std::log10(peak));
}

// ---------- Synth kits ----------

// Bank A in General MIDI order: each slot's drum type.
constexpr int kSlotType[16] = {kTypeKick, kTypeRim,   kTypeSnare,   kTypeClap, kTypeSnare,  kTypeTom,
                               kTypeClosedHat, kTypeTom, kTypePedalHat, kTypeTom, kTypeOpenHat, kTypeTom,
                               kTypeTom,  kTypeCrash, kTypeTom, kTypeRide};
constexpr double kSlotTune[16] = {0, 0, 0, 0, 3, -7, 0, -5, 0, -3, 0, 0, 2, 0, 5, 0};

struct SynthStyle {
    std::string_view name, description;
    std::string_view row[16];
    double amount;  // how far each pad moves from its start
    int drive;      // one drive for the kit (DriveType)
    double driveAmount, dirt, tone, length;
    std::vector<std::pair<uint32_t, double>> globals;
};
const std::vector<SynthStyle>& synthStyles() {
    static const std::vector<SynthStyle> s = {
        {"808-style", "A boomy analogue kit: long kick, snappy snare, metal hats, sine toms and a cowbell",
         {"808 Kick", "Rim", "808 Snare", "Clap", "808 Snare", "808 Tom", "808 Closed Hat", "808 Tom", "Pedal Hat", "808 Tom",
          "808 Open Hat", "808 Tom", "808 Tom", "Crash", "808 Tom", "Cowbell"},
         0.35, kDriveSoft, 1.5, 0.0, 0.0, 0.0, {{kGlue, 0.2}}},
        {"909-style", "Punchy and bright: a hard kick, a noisy snare, crushed hats",
         {"909 Kick", "Rim", "909 Snare", "Clap", "Clap Snare", "Mid Tom", "909 Closed Hat", "Mid Tom", "Pedal Hat", "Mid Tom",
          "909 Open Hat", "Mid Tom", "Mid Tom", "Crash", "Mid Tom", "Ride"},
         0.35, kDriveOff, 1.0, 0.1, 0.2, 0.0, {{kGlue, 0.35}}},
        {"Noise", "Built from noise: filtered bursts, textures and a sub under it all",
         {"Sub Kick", "Snap", "Fat Snare", "Clap", "Clap Snare", "Acoustic Tom", "Trashy Hat", "Acoustic Tom", "Pedal Hat",
          "Acoustic Tom", "909 Open Hat", "Acoustic Tom", "Acoustic Tom", "China", "Acoustic Tom", "Ride"},
         0.7, kDriveSoft, 2.0, 0.3, 0.1, 0.0, {{kGlue, 0.3}, {kRoom, 0.1}}},
        {"Glitch", "Broken and digital: ring-modulated hats, decimated hits, short and odd",
         {"909 Kick", "Clave", "Tight Snare", "Snap", "Clap Snare", "808 Tom", "Trashy Hat", "808 Tom", "Pedal Hat", "808 Tom",
          "808 Open Hat", "808 Tom", "808 Tom", "Splash", "808 Tom", "Ride Bell"},
         0.8, kDriveDecimate, 3.0, 0.4, 0.3, -0.4, {{kGlue, 0.3}}},
        {"FM", "Two-operator tones throughout: bell toms, metallic hats, a pitched kick",
         {"808 Kick", "Rim", "909 Snare", "Clap", "Tight Snare", "808 Tom", "808 Closed Hat", "808 Tom", "Pedal Hat", "808 Tom",
          "808 Open Hat", "808 Tom", "808 Tom", "Crash", "808 Tom", "FM Bell"},
         0.5, kDriveOff, 1.0, 0.0, 0.2, 0.0, {{kGlue, 0.25}}},
        {"Lo-fi", "Dusty and crushed: a soft kick, a fat snare, a small taped room",
         {"Sub Kick", "Rim", "Fat Snare", "Snap", "Clap Snare", "Acoustic Tom", "Acoustic Hat", "Acoustic Tom", "Pedal Hat",
          "Acoustic Tom", "808 Open Hat", "Acoustic Tom", "Acoustic Tom", "Splash", "Acoustic Tom", "Ride"},
         0.4, kDriveTube, 2.0, 0.35, -0.4, 0.0, {{kKitDriveType, 4}, {kKitDrive, 4}, {kKitDriveMix, 0.5}, {kGlue, 0.45}, {kRoom, 0.15}}},
        {"Minimal", "Short and dry: clicks, ticks and a tight kick for sparse grooves",
         {"909 Kick", "Rim", "Tight Snare", "Snap", "Tight Snare", "Mid Tom", "909 Closed Hat", "Mid Tom", "Pedal Hat", "Mid Tom",
          "909 Open Hat", "Mid Tom", "Mid Tom", "Splash", "Mid Tom", "Ride Bell"},
         0.25, kDriveOff, 1.0, 0.0, 0.1, -0.5, {{kGlue, 0.2}}},
        {"Industrial", "Hard and metallic: a driven kick, clanging hats and a trashy, taped bus",
         {"Techno Kick", "Rim", "909 Snare", "Clap", "Clap Snare", "808 Tom", "Trashy Hat", "808 Tom", "Pedal Hat", "808 Tom",
          "909 Open Hat", "808 Tom", "808 Tom", "China", "808 Tom", "Ride"},
         0.55, kDriveHard, 4.0, 0.5, 0.2, 0.0, {{kGlue, 0.6}, {kGlueThreshold, -18}, {kKitDriveType, 3}, {kKitDrive, 3}}},
    };
    return s;
}

Voice soundFor(std::string_view name, int type, uint32_t seed) {
    if (const Sound* s = findSound(name)) return s->voice;
    std::vector<const Sound*> pool;
    for (const Sound& s : sounds())
        if (s.type == type) pool.push_back(&s);
    if (pool.empty()) return neutralVoice();
    return pool[hash32(seed) % pool.size()]->voice;
}

void synthKit(const SynthStyle& st, uint32_t seed, int key, bool match, State& s) {
    clearPads(s);
    Rng r{seed * 2654435761u + 17u};
    for (uint32_t slot = 0; slot < 16; ++slot) {
        const int type = kSlotType[slot];
        Voice v = soundFor(st.row[slot], type, seed + slot);
        v[kNote] = kNoteAuto;
        v[kTune] = constrainPad(kTune, v[kTune] + kSlotTune[slot]);
        v = randomizeVoice(type, seed * 977u + slot * 131u + 1u, st.amount, v, false);
        // the kit's shared character: one drive (on the hits; the rest share the bus), one tone range, one length
        lean(v, false);
        if (st.drive != kDriveOff && (type == kTypeKick || type == kTypeSnare || type == kTypeClap))
            v[kDriveType] = st.drive, v[kDrive] = st.driveAmount * (0.8 + 0.4 * r.next());
        v[kDirt] = constrainPad(kDirt, st.dirt + 0.1 * (r.next() - 0.5));
        v[kTone] = constrainPad(kTone, st.tone + 0.2 * (r.next() - 0.5));
        v[kLength] = constrainPad(kLength, st.length + 0.2 * (r.next() - 0.5));
        if (st.name == "FM" && type != kTypeClosedHat && type != kTypeOpenHat && type != kTypePedalHat) {
            v[kFmOn] = 1;
            v[kFmFreq] = constrainPad(kFmFreq, (padHz(v) > 0.0 ? padHz(v) : 300.0) * (1.0 + r.next()));
            v[kFmRatio] = constrainPad(kFmRatio, 1.0 + std::floor(r.next() * 6.0) * 0.5 + 0.41);
            v[kFmIndex] = constrainPad(kFmIndex, 1.0 + 5.0 * r.next());
            v[kFmLevel] = -6.0;
        }
        if (st.name == "Noise" && (type == kTypeSnare || type == kTypeClap || type == kTypeClosedHat || type == kTypeOpenHat)) {
            v[kTexOn] = 1;
            v[kTexFreq] = constrainPad(kTexFreq, 2000.0 + 6000.0 * r.next());
            v[kTexLevel] = -9.0;
        }
        if (st.name == "Glitch" && (type == kTypeClosedHat || type == kTypeOpenHat || type == kTypeRim))
            v[kRingMix] = 0.3 + 0.3 * r.next(), v[kRingFreq] = constrainPad(kRingFreq, 400.0 + 3000.0 * r.next());
        tuneVoice(v, key);
        if (match) matchLevel(v);
        setVoice(s, slot, v);
    }
    for (const auto& [p, x] : st.globals) s[p] = x;
}

// ---------- Produced kits ----------

// A kick from three roles: a top (the click and a breath of noise), a body (the tuned drop) and a sub (a clean
// sine under it, its attack and pitch following the body's so they start in phase: the 1.1.0 layering research).
struct KickRole {
    double freq, drop, dropTime, decay, subLevel, subDecay, click, drive;
    int driveType, clip;
};
struct ProducedStyle {
    std::string_view name, description;
    KickRole kick;
    std::string_view row[16];  // the other pads, from the library
    double swing, transient, glue;
    int kitClip;
    std::vector<std::pair<uint32_t, double>> globals;
};
const std::vector<ProducedStyle>& producedStyles() {
    static const std::vector<ProducedStyle> s = {
        {"House", "Four on the floor: a round kick, a clap on two and four, crisp swung hats",
         {50, 24, 0.04, 0.35, -6, 0.45, 0.4, 1.5, kDriveSoft, kClipSoft},
         {"", "Rim", "909 Snare", "Clap", "Clap Snare", "Mid Tom", "909 Closed Hat", "Mid Tom", "Pedal Hat", "Mid Tom",
          "909 Open Hat", "Mid Tom", "Mid Tom", "Crash", "Mid Tom", "Ride"},
         0.3, 0.3, 0.35, kClipSoft, {}},
        {"Techno", "Driven and tight: a long tube kick, a rim, trashy hats, a glued bus",
         {47, 28, 0.035, 0.55, -8, 0.6, 0.35, 3.0, kDriveTube, kClipSoft},
         {"", "Rim", "909 Snare", "Clap", "Clap Snare", "808 Tom", "Trashy Hat", "808 Tom", "Pedal Hat", "808 Tom",
          "909 Open Hat", "808 Tom", "808 Tom", "China", "808 Tom", "Ride"},
         0.0, 0.4, 0.55, kClipSoft, {{kKitDriveType, 2}, {kKitDrive, 2}}},
        {"Trap", "Long, tuned 808 kick with a hard click, crisp claps, fast hats",
         {45, 12, 0.06, 1.2, -4, 1.5, 0.5, 2.0, kDriveSoft, kClipHard},
         {"", "Rim", "Clap Snare", "Clap", "808 Snare", "808 Tom", "808 Closed Hat", "808 Tom", "Pedal Hat", "808 Tom",
          "808 Open Hat", "808 Tom", "808 Tom", "Crash", "808 Tom", "Ride Bell"},
         0.0, 0.5, 0.4, kClipHard, {}},
        {"Drum and bass", "Fast and punchy: a short kick, a cracking snare, bright rides",
         {55, 30, 0.025, 0.25, -10, 0.3, 0.6, 1.5, kDriveSoft, kClipSoft},
         {"", "Rim", "Tight Snare", "Snap", "Fat Snare", "Mid Tom", "909 Closed Hat", "Mid Tom", "Pedal Hat", "Mid Tom",
          "909 Open Hat", "Mid Tom", "Mid Tom", "Crash", "Mid Tom", "Ride"},
         0.0, 0.6, 0.45, kClipSoft, {{kRoom, 0.1}}},
        {"Future bass", "Big and wide: a deep kick, a huge clap-snare in a room, airy hats",
         {52, 20, 0.05, 0.5, -5, 0.6, 0.35, 1.5, kDriveSoft, kClipSoft},
         {"", "Rim", "Clap Snare", "Clap", "Fat Snare", "808 Tom", "808 Closed Hat", "808 Tom", "Pedal Hat", "808 Tom",
          "808 Open Hat", "808 Tom", "808 Tom", "Crash", "808 Tom", "Ride"},
         0.1, 0.3, 0.4, kClipSoft, {{kRoom, 0.25}, {kRoomSize, 0.7}, {kRoomDecay, 1.8}}},
        {"Hardstyle", "A distorted, pitched kick with a long tail, a hard clap",
         {55, 36, 0.05, 0.6, -10, 0.4, 0.6, 8.0, kDriveHard, kClipHard},
         {"", "Rim", "Clap Snare", "Clap", "909 Snare", "808 Tom", "909 Closed Hat", "808 Tom", "Pedal Hat", "808 Tom",
          "909 Open Hat", "808 Tom", "808 Tom", "Crash", "808 Tom", "Ride"},
         0.0, 0.5, 0.5, kClipHard, {}},
        {"UK garage", "Two-step: a punchy kick, rims and claps on a heavy shuffle",
         {52, 22, 0.04, 0.3, -8, 0.35, 0.45, 1.5, kDriveSoft, kClipSoft},
         {"", "Rim", "Tight Snare", "Clap", "Clap Snare", "Mid Tom", "909 Closed Hat", "Mid Tom", "Pedal Hat", "Mid Tom",
          "909 Open Hat", "Mid Tom", "Mid Tom", "Splash", "Mid Tom", "Ride"},
         0.55, 0.3, 0.4, kClipSoft, {}},
        {"Pop", "Clean and present: a tight kick, a polished snare, controlled cymbals",
         {58, 18, 0.03, 0.3, -9, 0.35, 0.45, 1.2, kDriveSoft, kClipSoft},
         {"", "Rim", "Acoustic Snare", "Clap", "Tight Snare", "Acoustic Tom", "Acoustic Hat", "Acoustic Tom", "Pedal Hat",
          "Acoustic Tom", "808 Open Hat", "Acoustic Tom", "Acoustic Tom", "Crash", "Acoustic Tom", "Ride"},
         0.1, 0.3, 0.35, kClipSoft, {{kRoom, 0.12}}},
    };
    return s;
}

Voice kickFromRoles(const KickRole& k) {
    Voice v = neutralVoice();
    v[kType] = kTypeKick;
    // body: the tuned drop
    v[kBodyOn] = 1, v[kBodyFreq] = k.freq, v[kBodyPitch] = k.drop, v[kBodyPTime] = k.dropTime, v[kBodyDecay] = k.decay;
    v[kBodyAttack] = 0.0005, v[kBodyPhase] = 0.25;  // a cosine start: the click of the body itself
    // sub: in phase with the body (same attack, following its pitch), a clean sine under the effects
    v[kSubOn] = 1, v[kSubWave] = kSubSine, v[kSubOct] = 0, v[kSubFollow] = 0.35, v[kSubAttack] = 0.0005;
    v[kSubDecay] = k.subDecay, v[kSubLevel] = k.subLevel, v[kSubRoute] = kSubClean;
    // top: a tick and a short burst of noise
    v[kClickOn] = 1, v[kClickType] = kClickTick, v[kClickLevel] = k.click, v[kClickTone] = 3500, v[kClickLength] = 0.006;
    v[kDriveType] = k.driveType, v[kDrive] = k.drive, v[kClip] = k.clip, v[kClipGain] = 2.0;
    v[kWidth] = 0.0;
    for (uint32_t p = 0; p < kPadParams; ++p) v[p] = constrainPad(p, v[p]);
    return v;
}

// A finishing chain (as presets): on one pad, or (pad < 0) the kit's bus.
enum Chain { kChainPunch, kChainGlue, kChainBright, kChainWarm, kChainCrush, kChainClean, kChainCount };
constexpr std::string_view kChainNames[kChainCount] = {"Punch", "Glue", "Bright", "Warm", "Crush", "Clean"};
void finish(State& s, int pad, int chain) {
    if (pad >= 0) {
        auto set = [&](uint32_t p, double x) { padAt(s, static_cast<uint32_t>(pad), p) = constrainPad(p, x); };
        switch (chain) {
            case kChainPunch: set(kTrAttack, 0.5), set(kTrSustain, -0.2), set(kComp, 0.4), set(kClip, kClipSoft), set(kClipGain, 3); break;
            case kChainGlue: set(kComp, 0.5), set(kCompAttack, 10), set(kCompRelease, 120); break;
            case kChainBright: set(kEqHigh, 4), set(kEqHighFreq, 8000), set(kTrAttack, 0.2); break;
            case kChainWarm: set(kDriveType, kDriveTube), set(kDrive, 2), set(kEqLow, 2), set(kEqHigh, -2); break;
            case kChainCrush: set(kDriveType, kDriveCrush), set(kDrive, 4), set(kDriveMix, 0.5); break;
            default:
                for (uint32_t p : {kTrAttack, kTrSustain, kComp, kClipGain, kEqLow, kEqMid, kEqHigh}) set(p, 0);
                set(kClip, kClipOff), set(kDriveType, kDriveOff);
                break;
        }
        return;
    }
    switch (chain) {
        case kChainPunch: s[kGlue] = 0.3, s[kKitClip] = kClipSoft, s[kKitClipGain] = 3; break;
        case kChainGlue: s[kGlue] = 0.6, s[kGlueThreshold] = -18, s[kGlueMakeup] = 3; break;
        case kChainBright: s[kKitHigh] = 3; break;
        case kChainWarm: s[kKitDriveType] = 2, s[kKitDrive] = 2, s[kKitDriveMix] = 0.6, s[kKitHigh] = -1.5; break;
        case kChainCrush: s[kKitDriveType] = 4, s[kKitDrive] = 4, s[kKitDriveMix] = 0.5; break;
        default: s[kGlue] = 0, s[kKitClip] = kClipOff, s[kKitDriveType] = 0, s[kKitHigh] = 0, s[kKitLow] = 0; break;
    }
}

void producedKit(const ProducedStyle& st, uint32_t seed, int key, bool match, State& s) {
    clearPads(s);
    for (uint32_t slot = 0; slot < 16; ++slot) {
        const int type = kSlotType[slot];
        Voice v = slot == 0 ? kickFromRoles(st.kick) : soundFor(st.row[slot], type, seed + slot);
        v[kNote] = kNoteAuto;
        if (slot) {
            v[kTune] = constrainPad(kTune, v[kTune] + kSlotTune[slot]);
            v = randomizeVoice(type, seed * 613u + slot * 37u + 5u, 0.12, v, false);  // a touch of the seed
            lean(v, true);
        }
        if (st.swing > 0.0 && (type == kTypeClosedHat || type == kTypeOpenHat || type == kTypeRim))
            v[kSwing] = st.swing, v[kHumanize] = 0.15;
        if (type == kTypeKick || type == kTypeSnare || type == kTypeClap) v[kTrAttack] = constrainPad(kTrAttack, st.transient);
        tuneVoice(v, key);
        if (match) matchLevel(v);
        setVoice(s, slot, v);
    }
    s[kGlue] = st.glue;
    s[kKitClip] = st.kitClip;
    s[kKitClipGain] = 2.0;
    for (const auto& [p, x] : st.globals) s[p] = x;
}

// ---------- Acoustic kits ----------

// The pieces an Acoustic kit holds, by role: piece index = role.
enum Role : uint32_t { kRoleKick, kRoleSnare, kRoleTom1, kRoleTom2, kRoleTom3, kRoleHat, kRoleCrash, kRoleRide, kRoleExtra, kRoleCount };

struct AcousticStyle {
    std::string_view name, description;
    double kickSize, kickDepth, kickDamp;
    int beater, port;
    double snareSize, snareDepth;
    int snareShell;
    double wires, snareTune;
    double toms[3];
    double tomInterval;  // semitones between toms (5: fourths, 4 or 3: thirds)
    int head;
    double hat, crash, ride;
    int extraKind;
    double extraSize;
    int alloy, stick, mics;
    double room, decay;
};
const std::vector<AcousticStyle>& acousticStyles() {
    static const std::vector<AcousticStyle> s = {
        {"Jazz", "A small, open kit tuned high: 18\" kick, a sensitive snare, toms in thirds, a dark ride, in a room",
         18, 14, 0.1, kBeaterFelt, 0, 14, 5.5, kShellMaple, 0.5, 3, {10, 12, 14}, 4, kHeadCoated, 14, 18, 20, kPieceOff, 0,
         kAlloyDark, kStickSticks, kMicsRoom, 0.5, 1.2},
        {"Rock", "A big kit hit hard: 22\" kick, a fat 6.5\" snare, toms in fourths, loud cymbals",
         22, 18, 0.35, kBeaterFelt, 1, 14, 6.5, kShellMaple, 0.6, 0, {12, 13, 16}, 5, kHeadCoated2, 14, 18, 22, kPieceCrash, 16,
         kAlloyB20, kStickSticks, kMicsStudio, 0.35, 1.0},
        {"Funk", "Tight and dry: a muffled kick, a cracking steel snare tuned up, a splash",
         20, 16, 0.45, kBeaterFelt, 1, 13, 5, kShellSteel, 0.7, 5, {10, 12, 14}, 5, kHeadCoated, 13, 16, 20, kPieceSplash, 10,
         kAlloyB20, kStickSticks, kMicsDry, 0.15, 0.8},
        {"Studio pop", "Controlled and polished: a damped kick, a birch snare, two-ply toms",
         22, 16, 0.5, kBeaterFelt, 1, 14, 5.5, kShellBirch, 0.55, 1, {10, 12, 16}, 4, kHeadCoated2, 14, 18, 21, kPieceCrash, 17,
         kAlloyB20, kStickSticks, kMicsStudio, 0.25, 0.9},
        {"Vintage", "Calfskin heads, a mahogany snare, dark lathed cymbals in a warm room",
         20, 14, 0.25, kBeaterFelt, 0, 14, 5, kShellMahogany, 0.5, 0, {12, 13, 16}, 4, kHeadCalf, 14, 16, 20, kPieceOff, 0,
         kAlloyDark, kStickSticks, kMicsRoom, 0.45, 0.8},
        {"Metal", "Fast and bright: a wood-beater kick, a brass snare, clear heads, a china",
         22, 20, 0.45, kBeaterWood, 1, 14, 6.5, kShellBrass, 0.65, 2, {10, 12, 16}, 5, kHeadClear2, 14, 19, 22, kPieceChina, 18,
         kAlloyB8, kStickSticks, kMicsDry, 0.2, 0.9},
        {"Brushes", "The jazz kit played with brushes: soft swishes, loose wires, a sizzling ride",
         18, 14, 0.15, kBeaterFleece, 0, 14, 5.5, kShellMaple, 0.45, 3, {10, 12, 14}, 4, kHeadCoated, 14, 18, 20, kPieceOff, 0,
         kAlloyDark, kStickBrushes, kMicsRoom, 0.5, 1.2},
        {"Big room", "A huge kit far from the overheads: 24\" kick, deep snare and toms, long cymbals",
         24, 18, 0.2, kBeaterFelt, 0, 14, 8, kShellBirch, 0.55, -1, {13, 16, 18}, 5, kHeadCoated, 15, 20, 22, kPieceCrash, 18,
         kAlloyB20, kStickSticks, kMicsOverheads, 0.8, 1.3},
    };
    return s;
}

// A pad of an Acoustic kit: its note, the piece's role and the articulation.
struct MapPad {
    int note;
    Role role;
    int artic;
};
// General MIDI's percussion keys (GM Level 1; the 35..81 names caw_drums_info lists), then the extras on 12..20
// (no GM, Roland or Alesis default uses them).
const std::vector<MapPad>& mapPads(int map) {
    static const std::vector<MapPad> extras = {
        {12, kRoleSnare, kArtRoll},      {13, kRoleSnare, kArtFlam},  {14, kRoleSnare, kArtBuzz},
        {15, kRoleSnare, kArtRimClick},  {16, kRoleSnare, kArtOffCenter}, {17, kRoleCrash, kArtChoke},
        {18, kRoleRide, kArtChoke},      {19, kRoleCrash, kArtEdge},  {20, kRoleHat, kArtEdge}};
    auto with = [&](std::vector<MapPad> v) {
        v.insert(v.end(), extras.begin(), extras.end());
        return v;
    };
    static const std::vector<MapPad> gm = with({
        {36, kRoleKick, kArtHit},   {35, kRoleKick, kArtHit},       {37, kRoleSnare, kArtCrossStick}, {38, kRoleSnare, kArtHit},
        {40, kRoleSnare, kArtRimshot}, {50, kRoleTom1, kArtHit},    {48, kRoleTom1, kArtHit},       {47, kRoleTom2, kArtHit},
        {45, kRoleTom2, kArtHit},   {43, kRoleTom3, kArtHit},       {41, kRoleTom3, kArtHit},       {42, kRoleHat, kArtClosed},
        {44, kRoleHat, kArtFoot},   {46, kRoleHat, kArtOpen},       {49, kRoleCrash, kArtHit},      {57, kRoleExtra, kArtHit},
        {51, kRoleRide, kArtHit},   {59, kRoleRide, kArtEdge},      {53, kRoleRide, kArtBell},      {52, kRoleExtra, kArtEdge},
        {55, kRoleExtra, kArtHit}});
    // Roland V-Drums (TD-17 and TD-27 default note maps; the hi-hat's open/closed bow and edge notes all play the
    // hat as the pedal, CC 4, sets it).
    static const std::vector<MapPad> roland = with({
        {36, kRoleKick, kArtHit},   {38, kRoleSnare, kArtHit},      {40, kRoleSnare, kArtRimshot},  {37, kRoleSnare, kArtCrossStick},
        {48, kRoleTom1, kArtHit},   {50, kRoleTom1, kArtRimshot},   {45, kRoleTom2, kArtHit},       {47, kRoleTom2, kArtRimshot},
        {43, kRoleTom3, kArtHit},   {58, kRoleTom3, kArtRimshot},   {41, kRoleTom3, kArtHit},       {39, kRoleTom3, kArtRimshot},
        {46, kRoleHat, kArtHit},    {26, kRoleHat, kArtEdge},       {42, kRoleHat, kArtHit},        {22, kRoleHat, kArtEdge},
        {44, kRoleHat, kArtFoot},   {49, kRoleCrash, kArtHit},      {55, kRoleCrash, kArtEdge},     {57, kRoleExtra, kArtHit},
        {52, kRoleExtra, kArtEdge}, {51, kRoleRide, kArtHit},       {59, kRoleRide, kArtEdge},      {53, kRoleRide, kArtBell}});
    // Alesis (Nitro module's user guide, "Pad MIDI Note Numbers"): discrete hat notes, the half-open one playing the
    // pedal's position (the map sets it half open).
    static const std::vector<MapPad> alesis = with({
        {36, kRoleKick, kArtHit},   {38, kRoleSnare, kArtHit},      {40, kRoleSnare, kArtRimshot},  {48, kRoleTom1, kArtHit},
        {50, kRoleTom1, kArtRimshot}, {45, kRoleTom2, kArtHit},     {47, kRoleTom2, kArtRimshot},   {43, kRoleTom3, kArtHit},
        {58, kRoleTom3, kArtRimshot}, {41, kRoleTom3, kArtHit},     {39, kRoleTom3, kArtRimshot},   {51, kRoleRide, kArtHit},
        {49, kRoleCrash, kArtHit},  {57, kRoleExtra, kArtHit},      {46, kRoleHat, kArtOpen},       {23, kRoleHat, kArtHit},
        {42, kRoleHat, kArtClosed}, {44, kRoleHat, kArtFoot},       {21, kRoleExtra, kArtHit}});
    return map == kMapRoland ? roland : (map == kMapAlesis ? alesis : gm);
}

int roleType(Role r, int artic) {
    switch (r) {
        case kRoleKick: return kTypeKick;
        case kRoleSnare: return artic == kArtCrossStick || artic == kArtRimClick ? kTypeRim : kTypeSnare;
        case kRoleTom1: case kRoleTom2: case kRoleTom3: return kTypeTom;
        case kRoleHat: return artic == kArtFoot ? kTypePedalHat : (artic == kArtOpen ? kTypeOpenHat : kTypeClosedHat);
        case kRoleCrash: return kTypeCrash;
        case kRoleRide: return kTypeRide;
        default: return kTypeCymbal;
    }
}

// Lays the pads out for `map` over the pieces present (a role with no piece gets no pad).
void mapAcoustic(State& s, int map) {
    clearPads(s);
    uint32_t pad = 0;
    for (const MapPad& m : mapPads(map)) {
        if (pad >= kPads) break;
        if (static_cast<int>(pieceAt(s, m.role, kPcKind)) == kPieceOff) continue;
        Voice v = neutralVoice();
        v[kNote] = kNoteFirst + m.note;
        v[kEngine] = kEngineAcoustic;
        v[kAcouPiece] = m.role;
        v[kAcouArtic] = m.artic;
        v[kType] = roleType(m.role, m.artic);
        v[kRndPos] = 0.35;   // humanize from the physics: the strike point moves from hit to hit
        v[kRndLevel] = 0.15;  // and the velocity a little
        setVoice(s, pad++, v);
    }
    s[acouParam(kAcouHatPedal)] = map == kMapAlesis ? 0.7 : 1.0;
}

// Tunes the drums: to the key (kick on the root, snare and toms on its notes, the toms keeping their intervals),
// or by tension (tom 1 at its natural pitch, the others `interval` semitones apart).
void tuneAcoustic(State& s, int key, double snareTune, double interval) {
    auto natural = [&](Role r) {
        return acoustic::naturalHz(static_cast<int>(pieceAt(s, r, kPcKind)), pieceAt(s, r, kPcSize));
    };
    if (static_cast<int>(pieceAt(s, kRoleSnare, kPcKind)) != kPieceOff) pieceAt(s, kRoleSnare, kPcTune) = snareTune;
    double tom1 = 0.0;
    for (uint32_t r = kRoleTom1; r <= kRoleTom3; ++r) {
        if (static_cast<int>(pieceAt(s, r, kPcKind)) == kPieceOff) continue;
        const double f = natural(static_cast<Role>(r));
        if (tom1 == 0.0) tom1 = f;
        const double want = tom1 * std::exp2(-interval * (r - kRoleTom1) / 12.0);
        pieceAt(s, r, kPcTune) = std::clamp(12.0 * std::log2(want / f), -24.0, 24.0);
    }
    if (key < 0) return;
    for (uint32_t r : {kRoleKick, kRoleSnare, kRoleTom1, kRoleTom2, kRoleTom3}) {
        if (static_cast<int>(pieceAt(s, r, kPcKind)) == kPieceOff) continue;
        const double f = natural(static_cast<Role>(r)), now = f * std::exp2(pieceAt(s, r, kPcTune) / 12.0);
        double target = nearestInKey(now, key);
        if (r == kRoleKick) {  // the kick on the root, the octave nearest its pitch
            const double m = midiOf(now);
            target = hzOf(std::round((m - key) / 12.0) * 12.0 + key);
        }
        pieceAt(s, r, kPcTune) = std::clamp(12.0 * std::log2(target / f), -24.0, 24.0);
    }
}

void acousticKit(const AcousticStyle& st, uint32_t seed, int key, int map, State& s) {
    Rng r{seed * 40503u + 3u};
    auto piece = [&](Role role, int kind, double size) {
        pieceAt(s, role, kPcKind) = kind;
        pieceAt(s, role, kPcSize) = size;
        pieceAt(s, role, kPcHead) = st.head;
        pieceAt(s, role, kPcDecay) = std::clamp(st.decay * (0.95 + 0.1 * r.next()), 0.25, 4.0);
        pieceAt(s, role, kPcAlloy) = st.alloy;
    };
    piece(kRoleKick, kPieceKick, st.kickSize);
    pieceAt(s, kRoleKick, kPcDepth) = st.kickDepth;
    pieceAt(s, kRoleKick, kPcDamp) = st.kickDamp;
    pieceAt(s, kRoleKick, kPcBeater) = st.beater;
    pieceAt(s, kRoleKick, kPcPort) = st.port;
    piece(kRoleSnare, kPieceSnare, st.snareSize);
    pieceAt(s, kRoleSnare, kPcDepth) = st.snareDepth;
    pieceAt(s, kRoleSnare, kPcShell) = st.snareShell;
    pieceAt(s, kRoleSnare, kPcWires) = st.wires;
    pieceAt(s, kRoleSnare, kPcReso) = 2.0;
    for (uint32_t t = 0; t < 3; ++t) {
        piece(static_cast<Role>(kRoleTom1 + t), kPieceTom, st.toms[t]);
        pieceAt(s, kRoleTom1 + t, kPcDepth) = std::max(6.0, st.toms[t] * 0.75);
    }
    piece(kRoleHat, kPieceHiHat, st.hat);
    piece(kRoleCrash, kPieceCrash, st.crash);
    piece(kRoleRide, kPieceRide, st.ride);
    if (st.extraKind != kPieceOff) piece(kRoleExtra, st.extraKind, st.extraSize);
    // Where they sit: from the drummer's seat (kick and snare in the middle, toms left to right, cymbals around).
    constexpr double kPan[kRoleCount] = {0.0, -0.15, -0.25, 0.1, 0.45, -0.55, -0.45, 0.55, 0.35};
    constexpr double kDist[kRoleCount] = {1.4, 1.0, 0.8, 0.8, 1.0, 0.7, 0.5, 0.6, 0.55};
    for (uint32_t role = 0; role < kRoleCount; ++role) {
        pieceAt(s, role, kPcPan) = kPan[role];
        pieceAt(s, role, kPcDist) = kDist[role];
    }
    tuneAcoustic(s, key, st.snareTune, st.tomInterval);
    s[acouParam(kKitKind)] = kKitAcoustic;
    s[acouParam(kAcouMics)] = st.mics;
    s[acouParam(kAcouStick)] = st.stick;
    s[acouParam(kAcouRoom)] = st.room;
    s[acouParam(kAcouNoise)] = 0.25;  // subtle: a listening position's mechanical noise (owner, 2026-11-20)
    s[kRoom] = std::min(1.0, 0.25 + 0.5 * st.room);
    s[kRoomSize] = 0.3 + 0.5 * st.room;
    s[kRoomDecay] = 0.6 + 1.2 * st.room;
    mapAcoustic(s, map);
}

}  // namespace

const std::vector<std::string_view>& buildStyles(int kind) {
    static const std::array<std::vector<std::string_view>, kBuildKindCount> styles = [] {
        std::array<std::vector<std::string_view>, kBuildKindCount> out;
        for (const SynthStyle& s : synthStyles()) out[kBuildSynth].push_back(s.name);
        for (const ProducedStyle& s : producedStyles()) out[kBuildProduced].push_back(s.name);
        for (const AcousticStyle& s : acousticStyles()) out[kBuildAcoustic].push_back(s.name);
        return out;
    }();
    static const std::vector<std::string_view> none;
    return kind >= 0 && kind < kBuildKindCount ? styles[kind] : none;
}

const std::vector<std::string_view>& edrumMapNames() {
    static const std::vector<std::string_view> n = {"General MIDI", "Roland V-Drums", "Alesis"};
    return n;
}

bool buildKit(int kind, int style, uint32_t seed, int key, int map, bool match, BuiltKit& out) {
    if (kind < 0 || kind >= kBuildKindCount || style < 0 || style >= static_cast<int>(buildStyles(kind).size())) return false;
    if (key < -1 || key > 11) key = -1;
    if (map < 0 || map >= kMapCount) map = kMapGeneralMidi;
    State s = defaults();
    s[kMode] = kModeKit;
    static constexpr std::string_view kPrefix[] = {"Synth kit: ", "Produced kit: ", "Acoustic kit: "};
    switch (kind) {
        case kBuildSynth: {
            const SynthStyle& st = synthStyles()[style];
            synthKit(st, seed, key, match, s);
            s[acouParam(kKitKind)] = kKitSynth;
            out.description = std::string(st.description);
            break;
        }
        case kBuildProduced: {
            const ProducedStyle& st = producedStyles()[style];
            producedKit(st, seed, key, match, s);
            s[acouParam(kKitKind)] = kKitProduced;
            out.description = std::string(st.description);
            break;
        }
        default: {
            const AcousticStyle& st = acousticStyles()[style];
            acousticKit(st, seed, key, map, s);
            out.description = std::string(st.description);
            break;
        }
    }
    out.name = std::string(kPrefix[kind]) + std::string(buildStyles(kind)[style]);
    out.values = changed(s);
    return true;
}

}  // namespace drums

using namespace drums;

namespace {

std::string error(const std::string& m) { return "{\"ok\":false,\"error\":\"" + jsonEscape(m) + "\"}"; }
std::string number(double v) {
    char buf[40];
    std::snprintf(buf, sizeof buf, "%.17g", v);
    return buf;
}
std::string valuesJson(const std::vector<std::pair<uint32_t, double>>& values) {
    const ParameterDescriptor* t = parameterTable();
    std::string j = "{";
    for (size_t i = 0; i < values.size(); ++i)
        j += (i ? ",\"" : "\"") + std::string(t[values[i].first].id) + "\":" + number(values[i].second);
    return j + "}";
}
std::string list(const std::vector<std::string_view>& v) {
    std::string j = "[";
    for (size_t i = 0; i < v.size(); ++i) j += (i ? ",\"" : "\"") + jsonEscape(v[i]) + "\"";
    return j + "]";
}

}  // namespace

std::string drumsBuildersJson() {
    std::string chains = "[";
    for (int c = 0; c < kChainCount; ++c) chains += (c ? ",\"" : "\"") + std::string(kChainNames[c]) + "\"";
    return "{\"synth\":" + list(buildStyles(kBuildSynth)) + ",\"produced\":" + list(buildStyles(kBuildProduced)) +
           ",\"acoustic\":" + list(buildStyles(kBuildAcoustic)) + ",\"maps\":" + list(edrumMapNames()) +
           ",\"chains\":" + chains + "]}";
}

std::string drumsKitBuildJson(int kind, int style, uint32_t seed, int key, int map) {
    BuiltKit k;
    if (!buildKit(kind, style, seed, key, map, true, k)) return error("unknown kit kind or style");
    return "{\"ok\":true,\"name\":\"" + jsonEscape(k.name) + "\",\"description\":\"" + jsonEscape(k.description) +
           "\",\"params\":" + valuesJson(k.values) + "}";
}

// The tools work on an entry's values ({"params": {id: value}} over the descriptor's defaults) and answer with every
// value the result moves from the defaults (the entry's new "params").
std::string drumsKitToolJson(std::string_view request) {
    if (request.size() > (8u << 20)) return error("request too large");
    Json j;
    std::string why;
    if (!parseJson(request, j, why) || j.type != Json::Type::Object) return error(why.empty() ? "request must be an object" : why);
    const std::string tool = j.string("tool");
    State s = defaults();
    if (const Json* e = j.get("entry")) {
        const Json* params = e->get("params");
        if (params && params->type == Json::Type::Object) {
            if (params->obj.size() > kParamCount) return error("too many params");
            for (const auto& [id, v] : params->obj) {
                const int k = parameterIndex(id);
                if (k < 0 || v.type != Json::Type::Number || !std::isfinite(v.num)) continue;
                const ParameterDescriptor& d = parameterTable()[k];
                s[static_cast<size_t>(k)] = std::clamp(v.num, d.minimum, d.maximum);
            }
        }
    }
    const int padArg = static_cast<int>(j.number("pad", -1));
    const bool padOk = padArg >= 0 && padArg < static_cast<int>(kPads);
    auto usedLayers = [&](uint32_t pad) {
        const Voice v = voiceOf(s, pad);
        return static_cast<int>(v[kNote]) != kNoteOff && v[kEngine] < 0.5 &&
               v[kBodyOn] + v[kSubOn] + v[kClickOn] + v[kNoiseOn] + v[kMetalOn] + v[kResOn] + v[kSmpOn] + v[kFmOn] + v[kPhysOn] + v[kTexOn] > 0.0;
    };
    if (tool == "mutate") {  // every Layers pad moved a little (per pad: randomize and mutate stay as they were)
        const double amount = std::clamp(j.number("amount", 0.15), 0.0, 1.0);
        const uint32_t seed = static_cast<uint32_t>(j.number("seed", 1));
        for (uint32_t pad = 0; pad < kPads; ++pad)
            if (usedLayers(pad)) {
                Voice v = voiceOf(s, pad);
                v = randomizeVoice(static_cast<int>(v[kType]), seed * 7919u + pad, amount, v, true);
                setVoice(s, pad, v);
            }
    } else if (tool == "tune_to_key") {
        const int key = static_cast<int>(j.number("key", -1));
        if (key < 0 || key > 11) return error("key must be 0..11");
        for (uint32_t pad = 0; pad < kPads; ++pad)
            if (usedLayers(pad)) {
                Voice v = voiceOf(s, pad);
                tuneVoice(v, key);
                setVoice(s, pad, v);
            }
        // the Acoustic pieces too: each drum onto the key's nearest note
        for (uint32_t pc = 0; pc < kPieces; ++pc) {
            const int kind = static_cast<int>(pieceAt(s, pc, kPcKind));
            if (!isDrumPiece(kind)) continue;
            const double f = acoustic::naturalHz(kind, pieceAt(s, pc, kPcSize)), now = f * std::exp2(pieceAt(s, pc, kPcTune) / 12.0);
            pieceAt(s, pc, kPcTune) = std::clamp(12.0 * std::log2(nearestInKey(now, key) / f), -24.0, 24.0);
        }
    } else if (tool == "match_loudness") {
        for (uint32_t pad = 0; pad < kPads; ++pad)
            if (usedLayers(pad)) {
                Voice v = voiceOf(s, pad);
                matchLevel(v);
                setVoice(s, pad, v);
            }
    } else if (tool == "layer") {  // a library sound dropped on a pad as a layer: its layers the pad lacks join it
        if (!padOk) return error("pad must be 0..63");
        const Sound* snd = findSound(j.string("sound"));
        if (!snd) return error("unknown sound");
        Voice v = voiceOf(s, static_cast<uint32_t>(padArg));
        const std::string_view layers[] = {"body", "penv", "sub", "click", "noise", "metal", "res", "fm", "phys", "tex"};
        const uint32_t power[] = {kBodyOn, kBodyOn, kSubOn, kClickOn, kNoiseOn, kMetalOn, kResOn, kFmOn, kPhysOn, kTexOn};
        int added = 0;
        for (size_t l = 0; l < std::size(layers); ++l) {
            if (snd->voice[power[l]] < 0.5 || v[power[l]] >= 0.5) continue;
            for (uint32_t k = 0; k < kPadParams; ++k) {
                const std::string_view g = padParamDescriptor(0, k).group;
                if (g.substr(g.find('/') + 1) == layers[l]) v[k] = snd->voice[k];
            }
            ++added;
        }
        if (!added) return error("the pad already has every layer that sound uses");
        v[kEngine] = kEngineLayers;
        setVoice(s, static_cast<uint32_t>(padArg), v);
    } else if (tool == "finish") {
        const std::string chain = j.string("chain");
        int c = -1;
        for (int k = 0; k < kChainCount; ++k)
            if (chain == kChainNames[k]) c = k;
        if (c < 0) return error("unknown chain");
        finish(s, padOk ? padArg : -1, c);
    } else if (tool == "map") {
        mapAcoustic(s, static_cast<int>(j.number("map", kMapGeneralMidi)));
    } else if (tool == "render_pad") {  // the pad bounced into its own sample slot (its layers off, the sample on)
        if (!padOk) return error("pad must be 0..63");
        const std::string path = j.string("path");
        if (path.empty() || path.size() > 4096) return error("path is required");
        const uint32_t pad = static_cast<uint32_t>(padArg);
        Voice v = voiceOf(s, pad);
        if (v[kEngine] >= 0.5) return error("an Acoustic pad renders as a piece: use the kit export");
        std::vector<float> mono;
        Voice dry = v;
        dry[kLevel] = 0.0;
        dry[kPan] = 0.0;
        if (!renderVoice(dry, 48000.0, 4.0, mono) || mono.empty()) return error("the pad is silent");
        WavSpec spec;
        spec.sampleRate = 48000;
        spec.channels = 1;
        spec.float32 = true;
        std::string err;
        if (!writeFile(path, encodeWav(spec, mono.data(), static_cast<int64_t>(mono.size())), err)) return error(err);
        for (uint32_t k : {kBodyOn, kSubOn, kClickOn, kNoiseOn, kMetalOn, kResOn, kFmOn, kPhysOn, kTexOn}) v[k] = 0;
        v[kSmpOn] = 1, v[kSmpStart] = 0, v[kSmpEnd] = 1, v[kSmpTune] = 0, v[kSmpDecay] = 30, v[kSmpLevel] = 0, v[kSmpReverse] = 0;
        v[kSmpPitch] = 0;
        // the effects are in the render: the pad's own chain goes flat so they don't apply twice
        for (uint32_t k : {kDrive, kEqLow, kEqMid, kEqHigh, kTrAttack, kTrSustain, kComp, kClipGain, kRingMix, kWidth}) v[k] = neutralVoice()[k];
        v[kDriveType] = kDriveOff, v[kFlt] = kVfOff, v[kClip] = kClipOff;
        setVoice(s, pad, v);
        return "{\"ok\":true,\"path\":\"" + jsonEscape(path) + "\",\"frames\":" + std::to_string(mono.size()) +
               ",\"sample\":{\"slot\":" + std::to_string(pad) + ",\"path\":\"" + jsonEscape(path) + "\"},\"params\":" +
               valuesJson(changed(s)) + "}";
    } else {
        return error("unknown tool");
    }
    return "{\"ok\":true,\"params\":" + valuesJson(changed(s)) + "}";
}

void appendBuiltKitPresets(std::vector<BuiltinPreset>& out) {
    static std::deque<std::string> text;
    for (int kind = 0; kind < kBuildKindCount; ++kind)
        for (int style = 0; style < static_cast<int>(buildStyles(kind).size()); ++style) {
            BuiltKit k;
            if (!buildKit(kind, style, 1, -1, kMapGeneralMidi, false, k)) continue;
            text.push_back(k.name);
            const std::string_view name = text.back();
            text.push_back(k.description);
            const std::string_view description = text.back();
            BuiltinPreset p{name, description, {}};
            for (const auto& [index, value] : k.values) p.values.emplace_back(parameterTable()[index].id, value);
            out.push_back(std::move(p));
        }
}

}  // namespace caw
