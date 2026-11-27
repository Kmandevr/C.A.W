// Drums' constants, small helpers and kernels: the envelope, metal sets and drive (hand-written; included by builtin_drums.cpp, not compiled alone).
constexpr uint32_t kControlFrames = 16;
constexpr uint32_t kVoices = 64;
constexpr double kLn2 = 0.69314718055994530942;
constexpr double kSixtyDb = 6.907755278982137;

double clampd(double v, double lo, double hi) noexcept {
    v = finiteOr0(v);
    return v < lo ? lo : (v > hi ? hi : v);
}
int clampi(double v, int lo, int hi) noexcept { return static_cast<int>(clampd(v + 0.5, lo, hi + 0.49)); }
double exp2d(double x) noexcept { return lib::fastExp(x * kLn2); }
double dbGain(double db) noexcept { return db <= -59.999 ? 0.0 : lib::dbToGain(db); }
// The per-sample factor that falls 60 dB in `seconds`.
double fall(double seconds, double sr) noexcept { return seconds > 0.0 ? lib::fastExp(-kSixtyDb / (seconds * sr)) : 0.0; }

// ---------- Kernels ----------

// Attack (linear), hold, then a decay of 60 dB in `decay` seconds whose curve blends the analog exponential (0)
// toward a quick drop with a long tail (+1: a second exponential 6 times as fast) or a straight line (-1: a
// gated, held sound). Ends below about -94 dB.
struct DrumEnv {
    int stage = 0;  // 0 off, 1 attack, 2 hold, 3 decay
    double level = 0, inc = 1, e = 1, ef = 1, lin = 1, coef = 0, coefFast = 0, linStep = 0, curve = 0;
    double was[4] = {-1, -1, -1, -1};  // what set() last worked out from
    uint32_t holdLeft = 0, holdFrames = 0;
    void set(double attack, double hold, double decay, double c, double sr) noexcept {
        if (attack == was[0] && hold == was[1] && decay == was[2] && c == was[3]) return;  // unchanged: no exps
        was[0] = attack, was[1] = hold, was[2] = decay, was[3] = c;
        inc = attack > 0.0 ? 1.0 / (attack * sr) : 2.0;
        holdFrames = static_cast<uint32_t>(clampd(hold, 0.0, 10.0) * sr);
        coef = fall(decay, sr);
        coefFast = fall(decay / 6.0, sr);
        linStep = decay > 0.0 ? 1.0 / (decay * sr) : 1.0;
        curve = clampd(c, -1.0, 1.0);
    }
    void trigger() noexcept {
        stage = 1;
        level = 0.0;
        e = ef = lin = 1.0;
        holdLeft = holdFrames;
    }
    // Straight into the decay at full level (a pitch envelope).
    void start() noexcept {
        stage = 3;
        level = 1.0;
        e = ef = lin = 1.0;
    }
    double next() noexcept {
        switch (stage) {
            case 1:
                level += inc;
                if (level >= 1.0) {
                    level = 1.0;
                    stage = holdLeft ? 2 : 3;
                }
                return level;
            case 2:
                if (--holdLeft == 0) stage = 3;
                return 1.0;
            case 3: {
                e *= coef;
                double out;
                if (curve >= 0.0) {
                    ef *= coefFast;
                    out = e + curve * (ef - e);
                } else {
                    lin = lin > linStep ? lin - linStep : 0.0;
                    out = e - curve * (lin - e);
                }
                if (out < 2e-5) {
                    stage = 0;
                    out = 0.0;
                }
                return level = out;
            }
            default: return 0.0;
        }
    }
    bool active() const noexcept { return stage != 0; }
};

// The six oscillator ratios and loudnesses of each metal set. 808: the TR-808 cymbal and hi-hat bank's six square
// oscillators (205.3, 304.4, 369.6, 522.7, 540 and 800 Hz, divided by the lowest; docs/engine.md); Cowbell: two
// of them (540 and 800 Hz). The rest are made up here, for their character.
struct MetalSet {
    double ratio[6];
    double amp[6];
};
constexpr MetalSet kMetalSets[kSetCount] = {
    {{1.0, 1.48271, 1.80029, 2.54603, 2.63030, 3.89674}, {1, 1, 1, 1, 1, 1}},           // 808
    {{1.0, 1.342, 1.759, 2.107, 2.533, 3.191}, {1, 0.9, 1, 0.8, 0.9, 0.7}},             // Bright
    {{1.0, 1.215, 1.797, 2.341, 3.106, 4.207}, {1, 0.9, 0.85, 0.8, 0.7, 0.6}},          // Cymbal
    {{1.0, 1.48148, 1.0, 1.0, 1.0, 1.0}, {1, 0.85, 0, 0, 0, 0}},                       // Cowbell (540 : 800)
    {{1.0, 1.5, 2.08, 2.84, 3.6, 4.42}, {1, 0.8, 0.6, 0.5, 0.35, 0.25}},                // Gong
    {{1.0, 2.0, 2.76, 3.0, 5.4, 6.0}, {1, 0.6, 0.8, 0.4, 0.5, 0.3}},                    // Bell
    {{1.0, 2.0, 3.0, 4.0, 5.0, 6.0}, {1, 0.5, 0.33, 0.25, 0.2, 0.17}},                  // Harmonic
};

// The half-band filters' design, worked out once (a voice is reset on every hit).
const lib::HalfBandDesign& halfBand() {
    static const lib::HalfBandDesign d;
    return d;
}

// A drive stage, with its 2x oversampling (Normal and High quality) around the curve.
constexpr int kDriveClipSoft = 100;  // the clipper's soft curve (tanh, not level-matched: the ceiling is full scale)

struct Drive {
    int type = kDriveOff;
    double amount = 1, norm = 1, q = 1, tubeBias = 0, tubeNorm = 1, dcX = 0, dcY = 0, held = 0;
    uint32_t holdFrames = 1, holdLeft = 0;
    lib::Saturator sat;
    lib::Oversampler2x os{halfBand()}, os2a{halfBand()}, os2b{halfBand()};
    void set(int t, double a) noexcept {
        type = t;
        amount = clampd(a, 1.0, 20.0);
        if (type == kDriveSoft) sat.set(amount);
        if (type == kDriveCrush) {
            const double bits = 16.0 - 13.0 * (lib::fastLog(amount) / lib::fastLog(20.0));
            q = exp2d(std::floor(bits) - 1.0);
        }
        if (type == kDriveTube) {  // a biased tanh: even harmonics; the bias's offset taken out, held within +-1
            tubeBias = lib::tanhApprox(0.3);
            tubeNorm = 1.0 / (1.0 + tubeBias);
        }
        if (type == kDriveDecimate) holdFrames = static_cast<uint32_t>(amount + 0.5);  // hold every n-th sample
        if (type == kDriveRectify || type == kDriveAsym) norm = 1.0 / lib::tanhApprox(amount);
    }
    double curveAt(double x) const noexcept {
        switch (type) {
            case kDriveSoft: return sat.processApprox(x);
            case kDriveHard: return lib::hardClip(x, amount);
            case kDriveFold: return lib::fastSinCycles(x * amount * 0.25);
            case kDriveTube: return (lib::tanhApprox(amount * x + 0.3) - tubeBias) * tubeNorm;
            case kDriveRectify: {  // half the wave folded up: an octave of grit over the original
                const double t = lib::tanhApprox(amount * x) * norm;
                return (0.5 * t + (t < 0.0 ? -t : t)) * (2.0 / 3.0);
            }
            case kDriveAsym: {  // positive half driven harder than the negative: even harmonics
                const double y = amount * x;
                return (y > 0.0 ? lib::tanhApprox(y) : lib::tanhApprox(0.5 * y)) * norm;
            }
            case kDriveClipSoft: return lib::tanhApprox(amount * x);
            default: return x;
        }
    }
    // factor 1 (Eco), 2 (Normal) or 4 (High: two 2x stages).
    double process(double x, int factor) noexcept {
        if (type == kDriveOff) return x;
        if (type == kDriveCrush) return std::floor(x * q + 0.5) / q;
        if (type == kDriveDecimate) {
            if (holdLeft == 0) {
                held = x;
                holdLeft = holdFrames;
            }
            --holdLeft;
            return held;
        }
        if (type == kDriveRectify || type == kDriveAsym) return dcBlock(factor <= 1 ? curveAt(x) : over(x, factor));
        if (factor <= 1) return curveAt(x);
        return over(x, factor);
    }
    // A 7 Hz DC blocker after the curves that bend one side more (their offset would thump).
    double dcBlock(double x) noexcept {
        dcY = x - dcX + 0.9991 * dcY;
        dcX = x;
        return dcY;
    }
    double over(double x, int factor) noexcept {
        double up[2];
        os.up(x, up);
        if (factor == 2) {
            up[0] = curveAt(up[0]);
            up[1] = curveAt(up[1]);
        } else {
            double a[2], b[2];
            os2a.up(up[0], a);
            os2b.up(up[1], b);
            a[0] = curveAt(a[0]), a[1] = curveAt(a[1]), b[0] = curveAt(b[0]), b[1] = curveAt(b[1]);
            up[0] = os2a.down(a);
            up[1] = os2b.down(b);
        }
        return os.down(up);
    }
    void clear() noexcept {
        os.clear();
        os2a.clear();
        os2b.clear();
        dcX = dcY = held = 0.0;
        holdLeft = 0;
    }
};
