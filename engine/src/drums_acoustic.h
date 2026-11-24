// Rook's Acoustic engine (1.1.2): up to 16 persistent, simulated drum pieces (modal heads, sticks, snare wires, cymbals, a hi-hat), mics and bleed.
#pragma once

#include <cstdint>
#include <vector>

#include "builtin_drums_layout.h"

namespace caw::drums::acoustic {

// One piece's settings (the pc<n>_* parameters) and the kit's (acou_*), as numbers the DSP reads.
struct PieceSettings {
    int kind = kPieceOff;
    double size = 14, depth = 6.5, tune = 0, reso = 0;
    int head = kHeadCoated, shell = kShellMaple;
    double damp = 0.2, decay = 1, glide = 0.5, wires = 0.6, wireLevel = 0;
    int beater = kBeaterFelt, port = 0;
    double air = 1;
    int alloy = kAlloyB20;
    double swell = 0.5, level = 0, pan = 0, dist = 1, shellLevel = 0.5;
    bool operator==(const PieceSettings&) const = default;
};
struct KitSettings {
    int mics = kMicsStudio, stick = kStickSticks;
    double hatPedal = 1, sympathy = 0.5, bleed = 0.5, noise = 0.25, level = 0, room = 0.3;
    bool operator==(const KitSettings&) const = default;
};

// A drum's batter (0,1) mode at tuning 0 (Hz): a kick near 58 Hz at 22", a snare near 190 Hz at 14", toms 1560 / size.
constexpr double naturalHz(int kind, double size) noexcept {
    return kind == kPieceKick ? 58.0 * 22.0 / size : (kind == kPieceSnare ? 190.0 * 14.0 / size : 1560.0 / size);
}

inline constexpr uint32_t kMaxModes = 128;  // per piece: a drum's batter + resonant head + shell, or a cymbal's plates
inline constexpr uint32_t kMaxWires = 16;
inline constexpr uint32_t kResoWireModes = 12;  // the snare-side head's modes the wires touch
inline constexpr uint32_t kRing = 32;           // the kit sum's history (sympathetic drive), a power of two
inline constexpr uint32_t kCell = 16;           // the longest span process() takes (frames): a control period

// A part of a piece that rings: a run of modes in the piece's arrays.
struct Segment {
    uint32_t at = 0, count = 0;
    float g = 0;       // dt^2 / modal mass
    float damp = 1;    // the pole radius' extra factor while a hand, a choke or the hat's pressure damps it (applyDamp)
};

// A stick, beater, mallet or brush: a mass held by a hand (or pedal) spring, touching the surface through a
// Hunt-Crossley contact (k [d]+^a (1 + lambda d')), stepped every sample while it moves.
struct Striker {
    bool active = false, touched = false, contact = false;
    float x = 0, v = 0, m = 0.05f, k = 1e7f, lambda = 0.1f;
    bool soft = false;              // a = 2.5 (felt, mallet, brush), else 1.5
    float handK = 50, handC = 3, handTarget = -0.03f;
    uint32_t pressFor = 0;          // samples the hand still presses (buzz, roll, dead stroke), then lifts
    uint32_t delay = 0;             // samples before the stroke starts (a flam's main stroke)
    float startV = 0;
    float dPrev = 0;
    float C = 0;                    // the contact's compliance: dt^2 (1/m + sum(phi^2) g)
    float pos = 0.25f;              // strike radius 0..1
    float ref = 0;                  // a hat's top-plate height when the stroke began (its surface moves with it)
    uint32_t contactFrames = 0, firstContact = 0, lastContact = 0, bounces = 0;  // measured (tests): frames since the
    uint32_t firstLength = 0, gap = 0;  // the first contact's length (gaps under 0.5 ms merged: a contact chatters)
    bool firstDone = false;
    float peakForce = 0;
};

// A piece: its modes (structure of arrays), sticks, wires and state. Plain data, no allocation.
struct Piece {
    PieceSettings set;
    int quality = 1;
    bool configured = false, awake = false;
    Segment seg[3];  // drum: batter, resonant head, shell; cymbal: plate (and a hat's bottom plate)
    float a1[kMaxModes] = {}, a2[kMaxModes] = {}, y1[kMaxModes] = {}, y2[kMaxModes] = {};  // a1, a2: with the damping
    float a1b[kMaxModes] = {}, a2b[kMaxModes] = {};  // the coefficients before a hand's or the hat's damping (with glide)
    float w[kMaxModes] = {};           // radiation weight
    float om[kMaxModes] = {};          // the mode's angular step (rad per sample) before glide
    float cs[kMaxModes] = {}, sn[kMaxModes] = {};  // its cos and sin (the glide re-tunes by angle addition)
    float a1n[kMaxModes] = {};         // a1 with no glide and no damping (sleep restores it)
    float rr[kMaxModes] = {};          // pole radius
    float phiA[kMaxModes] = {}, phiB[kMaxModes] = {};  // the two sticks' strike weights on segment 0
    float phiEdge[kMaxModes] = {};     // a hat's contact ring (both plates), a drum's bearing edge (segment 0)
    float strain[kMaxModes] = {};      // a drum's (j/a)^2 per mode: tension modulation's weights
    float hatEta[kMaxModes] = {}, hatPush[kMaxModes] = {};  // a hat: the plates' gap weights (+top, -bottom), the force's
    float ratio[kMaxModes] = {};       // the mode's frequency over the first (tests and display)
    int order[kMaxModes] = {};         // a membrane mode's m (angular order)
    Striker stick[2], rim;
    uint32_t nextStick = 0;
    uint8_t pairKind = 255, pairAlloy = 255, pairQuality = 255;  // what the cascade's pairs were found for
    // Snare wires (lumped, Ducceschi, Hamilton and Russo 2023): mass-spring each, colliding one-sidedly with the
    // resonant head, the force fed back to its lowest modes.
    uint32_t wires = 0;
    float psiT[kResoWireModes][kMaxWires] = {};  // wire w's weight on resonant-head mode k: psiT[k][w]
    float psiW[kMaxWires][kResoWireModes] = {};  // the same, by wire: psiW[w][k] (the force fed back, modes at once)
    float wx[kMaxWires] = {}, wv[kMaxWires] = {}, wC[kMaxWires] = {}, wDPrev[kMaxWires] = {};
    float wOm2 = 0, wDampK = 0, wRest = 0, wMass = 0.002f, wK = 1e6f;
    float rattleHp[4] = {}, rattleK = 0.3f, rattleGain = 0, lastF = 0, wireGate = 0;
    double rattleEnergy = 0;  // tests: the wires' collision energy since the piece last woke
    // Pitch glide (tension modulation, Avanzini, Marogna and Bank 2012): frequencies x (1 + glideK * strain energy).
    float glideK = 0, glideNow = 0;
    float airK = 0;                    // the heads' (0,1) modes coupled through the enclosed air
    // A cymbal's reduced nonlinear coupling: triplets (i, j, k), each a cubic potential c y_i y_j y_k.
    uint32_t triplets = 0;
    uint16_t ti[96] = {}, tj[96] = {}, tk[96] = {};
    float tc[96] = {};
    float satY = 1;
    // Eco cymbal: noise into the high band growing with the low modes' energy squared.
    float swellEnv = 0, swellK = 0, swellGain = 0, swellHp[2] = {}, swellLp = 0;
    // Hi-hat: the top plate's rigid height (the clutch on the rod), the pedal's target, and the plates' contact.
    float hatZ = 0, hatV = 0, hatTarget = 0, hatOm = 0, hatC = 0, hatK = 0, hatDPrev = 0, hatPressure = 0, hatPressureSum = 0;
    int hatOverride = -1;              // a Closed, Open or Foot articulation's pedal (0..1000), else -1: the pedal
    float hatFootBoost = 0;
    double lastPedal = -1;
    // Hand, choke and pedal noises (acou_noise).
    uint32_t noiseLeft = 0, noiseLength = 1;
    float noiseLevel = 0, noiseLp = 0, noiseK = 0.5f, noiseHp = 0;
    uint32_t rng = 1;
    uint32_t rollRng = 7;  // a roll's own draws (its strokes are planned a span ahead: they must not take the noise's)
    // Roll: alternating press strokes while its note is held.
    uint32_t rollNote = 0, rollEvery = 0, rollIn = 0, rollLeft = 0;
    bool rolling = false;
    float rollVel = 0, rollPos = 0.25f;
    uint32_t lastNote = 0;             // the note of the last strike (a pad's pressure chokes it)
    uint32_t quietFrames = 0;
    float peak = 0;                    // loudest output since the last control
    float gain = 1;                    // output scale for the kind
    float out[16] = {};                // this chunk's output (mono, before the mics)
    // Mics: close (level, pan), overheads (level and delay each side), room send, bleed send.
    float closeL = 0, closeR = 0, ohL = 0, ohR = 0, roomSend = 0, bleedSend = 0;
    uint32_t ohDelayL = 0, ohDelayR = 0;
    float symp = 0;                    // how much of the rest of the kit drives it
    float own[kRing] = {};             // its own output's history (the drive is the kit's sum without it)
};

class AcousticKit {
public:
    // Control thread: the delay lines (overheads, bleed) for `sampleRate`. False if out of memory.
    bool prepare(double sampleRate);
    void reset() noexcept;
    // Audio thread, at control rate: the kit's settings, and a piece's (it re-tunes only when they moved).
    void setKit(const KitSettings& k) noexcept;
    void setPiece(uint32_t piece, const PieceSettings& s, int quality) noexcept;
    const PieceSettings& pieceSettings(uint32_t piece) const noexcept { return pieces_[piece < kPieces ? piece : 0].set; }
    // A stroke on `piece` with articulation `artic` (articulationFor already applied or not), velocity 0..1 (more for
    // an accent), strike-position jitter -1..1, and the note that played it (its off ends a roll, its pressure chokes).
    void strike(uint32_t piece, int artic, double velocity, double jitter, uint32_t noteId) noexcept;
    void release(uint32_t noteId) noexcept;
    void pressure(uint32_t noteId, double value) noexcept;
    // The pedal moved: a configured hi-hat wakes so its plates can meet (the chick). True if it woke.
    bool wakeHat(uint32_t piece) noexcept;
    // Adds the kit's n (<= 16) frames into left/right (and its room send into `room`, when not null).
    void process(double* left, double* right, double* room, uint32_t n) noexcept;
    // Once a control period (16 frames, on the host's own grid, so a render is the same at any block size): the
    // glide, the hat's clamping, waking a snare the kit drove, and putting quiet pieces to sleep.
    void endCell() noexcept;
    bool awake() const noexcept { return awake_ != 0; }
    // Tests and display.
    const Piece& piece(uint32_t p) const noexcept { return pieces_[p < kPieces ? p : 0]; }
    // A configured piece's mode k frequency in Hz (segment s), with no glide.
    double modeHz(uint32_t piece, uint32_t s, uint32_t k) const noexcept;
    uint32_t awakeCount() const noexcept;

private:
    void configure(Piece& p) noexcept;
    void configureDrum(Piece& p) noexcept;
    void configureCymbal(Piece& p) noexcept;
    void mics(Piece& p) noexcept;
    void wake(Piece& p) noexcept;
    void startStroke(Piece& p, Striker& s, double velocity, float pos, int artic, bool press, bool dead, uint32_t delay) noexcept;
    void weights(Piece& p, float* phi, float pos, bool bell) noexcept;
    void runDrum(Piece& p, uint32_t n, uint64_t clock) noexcept;
    void ringDrum(Piece& p, uint32_t t0, uint32_t n, uint64_t clock, float* out, float* vel) noexcept;
    void runCymbal(Piece& p, uint32_t n, uint64_t clock) noexcept;
    void runHat(Piece& p, uint32_t n, uint64_t clock) noexcept;
    float noiseSample(Piece& p) noexcept;
    float stickForce(Striker& s, float uPred) noexcept;
    void control(Piece& p) noexcept;
    void span(double* left, double* right, double* room, uint32_t n) noexcept;
    void silence(uint32_t piece) noexcept;
    void quietState(Piece& p) noexcept;
    static void applyDamp(Piece& p, uint32_t segment, float d) noexcept;

    double sr_ = 48000, dt_ = 1.0 / 48000;
    KitSettings kit_;
    Piece pieces_[kPieces];
    uint32_t awake_ = 0;  // bit per piece
    // The overheads and the bleed bus as output-side rings: a piece adds each frame where it will be heard (now plus
    // its delay), and the kit reads one slot a frame. Power-of-two sizes.
    std::vector<float> ohL_, ohR_;
    uint32_t ohMask_ = 0, ohAt_ = 0;
    uint32_t bleedDelay_ = 72;
    float ring_[kRing] = {};  // the kit's raw sum, per sample (the sympathetic drive reads it kRing / 2 later)
    uint64_t clock_ = 0;
    uint32_t cellFrames_ = 0;  // frames since the last endCell
    float bleedGain_ = 0.5f, level_ = 1;
};

}  // namespace caw::drums::acoustic
