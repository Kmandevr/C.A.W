// Rook 1.1.2: the Acoustic engine's realism checks (modes, contact, glide, wires, cymbal swell, hi-hat, rolls), its settings audit, block sizes, guards, and the three kinds' builders.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <string>
#include <vector>

#include "builtin_drums.h"
#include "builtin_drums_layout.h"
#include "caw.h"
#include "caw/instrument.hpp"
#include "drums_acoustic.h"
#include "drums_kits.h"
#include "engine.h"
#include "json.h"
#include "presets.h"
#include "quality.h"
#include "test.h"

using namespace caw;
using namespace caw::drums;

namespace {

using Values = std::vector<std::pair<std::string, double>>;
constexpr double kSr = 48000.0;

// ---------- The engine's own kit, driven directly (the physics) ----------

struct Hit {
    uint32_t frame;
    uint32_t piece;
    int artic;
    double velocity;
};
// Mono (left + right) / 2 of the kit, in 16-frame spans.
std::vector<float> kitRender(acoustic::AcousticKit& k, double seconds, const std::vector<Hit>& hits) {
    std::vector<float> out;
    const uint32_t frames = static_cast<uint32_t>(seconds * kSr);
    double l[16], r[16];
    for (uint32_t t = 0; t < frames; t += 16) {
        for (const Hit& h : hits)
            if (h.frame >= t && h.frame < t + 16) k.strike(h.piece, h.artic, h.velocity, 0.0, 1);
        std::fill(l, l + 16, 0.0), std::fill(r, r + 16, 0.0);
        if (k.awake()) k.process(l, r, nullptr, 16), k.endCell();
        for (int i = 0; i < 16; ++i) out.push_back(static_cast<float>(0.5 * (l[i] + r[i])));
    }
    return out;
}
acoustic::PieceSettings piece(int kind, double size) {
    acoustic::PieceSettings p;
    p.kind = kind;
    p.size = size;
    return p;
}

// The energy of x in [t0, t1) s between lo and hi Hz (a Hann-windowed DFT on a 50 Hz grid), per sample.
double band(const std::vector<float>& x, double t0, double t1, double lo, double hi) {
    const size_t a = static_cast<size_t>(t0 * kSr), b = std::min(x.size(), static_cast<size_t>(t1 * kSr));
    if (b <= a) return 0.0;
    const size_t n = b - a;
    double e = 0.0;
    for (double f = lo; f <= hi; f += 50.0) {
        double c = 0.0, s = 0.0;
        const double w0 = 6.283185307179586 * f / kSr;
        for (size_t i = 0; i < n; ++i) {
            const double w = 0.5 - 0.5 * std::cos(6.283185307179586 * i / n);
            c += x[a + i] * w * std::cos(w0 * i);
            s += x[a + i] * w * std::sin(w0 * i);
        }
        e += c * c + s * s;
    }
    return e / n;
}
// The strongest frequency of x in [t0, t1) s between lo and hi Hz (0.25 Hz steps).
double peakHz(const std::vector<float>& x, double t0, double t1, double lo, double hi) {
    const size_t a = static_cast<size_t>(t0 * kSr), n = static_cast<size_t>((t1 - t0) * kSr);
    double best = 0.0, at = 0.0;
    for (double f = lo; f <= hi; f += 0.25) {
        double c = 0.0, s = 0.0;
        const double w0 = 6.283185307179586 * f / kSr;
        for (size_t i = 0; i < n; ++i) {
            const double w = 0.5 - 0.5 * std::cos(6.283185307179586 * i / n);
            c += x[a + i] * w * std::cos(w0 * i);
            s += x[a + i] * w * std::sin(w0 * i);
        }
        if (c * c + s * s > best) best = c * c + s * s, at = f;
    }
    return at;
}
double db(double a, double b) { return 10.0 * std::log10((a + 1e-30) / (b + 1e-30)); }

// J_m(x) and its zeros, computed here on their own (not the engine's table): the ideal membrane's ratios.
double besselJ(int m, double x) {
    double t = 1.0, sum = 0.0;
    for (int k = 1; k <= m; ++k) t *= x * 0.5 / k;
    for (int k = 0; k < 120; ++k) {
        sum += t;
        t *= -x * x * 0.25 / ((k + 1.0) * (k + 1.0 + m));
    }
    return sum;
}
double firstZero(int m) {
    double a = m + 0.5;
    while ((besselJ(m, a) < 0.0) == (besselJ(m, a + 0.01) < 0.0)) a += 0.01;
    double lo = a, hi = a + 0.01;
    for (int i = 0; i < 80; ++i) {
        const double mid = 0.5 * (lo + hi);
        ((besselJ(m, mid) < 0.0) == (besselJ(m, lo) < 0.0) ? lo : hi) = mid;
    }
    return 0.5 * (lo + hi);
}

// The first contact's length (ms) of a stroke on piece 0.
double contactMs(acoustic::AcousticKit& k, int artic, double velocity, bool rim = false) {
    k.reset();
    k.strike(0, artic, velocity, 0.0, 1);
    double l[16], r[16];
    acoustic::Striker s{};
    for (uint32_t t = 0; t < 4800; t += 16) {
        k.process(l, r, nullptr, 16);
        k.endCell();
        if (t >= 2400 && s.bounces == 0) s = rim ? k.piece(0).rim : k.piece(0).stick[0];
    }
    return s.firstLength / kSr * 1000.0;
}

// ---------- The instrument (org.caw.drums), through the engine ----------

std::unique_ptr<ModuleProcessor> makeAt(int quality) {
    static Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent("org.caw.drums");
    CHECK(p != nullptr);
    if (!p) return p;
    static std::atomic<int> qualities[3] = {kQualityEco, kQualityNormal, kQualityHigh};
    const BuildingQuality building(&qualities[quality]);
    CHECK(p->activate(48000, 512));
    return p;
}
// Interleaved stereo of `events` with `values` over the defaults, in blocks of `block`.
std::vector<float> render(int quality, const Values& values, const std::vector<Event>& events, uint32_t frames,
                          uint32_t block = 64, bool* quietAtEnd = nullptr) {
    std::unique_ptr<ModuleProcessor> p = makeAt(quality);
    if (!p) return {};
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = parameterIndex(id);
        if (k < 0) cawtest::fail(__FILE__, __LINE__, "no parameter " + id);
        else params[static_cast<size_t>(k)].value = v;
    }
    std::vector<float> out, l(block), r(block);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, block};
    size_t next = 0;
    for (uint32_t start = 0; start < frames; start += block) {
        std::vector<Event> in;
        while (next < events.size() && events[next].frame < start + block) {
            Event e = events[next++];
            e.frame -= start;
            in.push_back(e);
        }
        const EventInput ev{in.data(), static_cast<uint32_t>(in.size())};
        ProcessBlock b;
        b.frames = std::min(block, frames - start);
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &ev;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p->processPorts(b));
        for (uint32_t i = 0; i < b.frames; ++i) out.push_back(l[i]), out.push_back(r[i]);
    }
    if (quietAtEnd) *quietAtEnd = p->quiet();
    return out;
}
double apart(const std::vector<float>& a, const std::vector<float>& b) {
    double d = 0, s = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
        d += std::fabs(static_cast<double>(a[i]) - b[i]);
        s += std::max(std::fabs(a[i]), std::fabs(b[i]));
    }
    return s > 0 ? d / s : 0.0;
}
float peakOf(const std::vector<float>& x) {
    float p = 0.0f;
    for (float v : x) p = std::max(p, std::fabs(v));
    return p;
}
bool finite(const std::vector<float>& x) {
    for (float v : x)
        if (!std::isfinite(v)) return false;
    return true;
}
std::string pc(uint32_t piece, const char* suffix) { return "pc" + std::to_string(piece + 1) + "_" + suffix; }
// Pad A1 an Acoustic pad on piece 1 (Single mode: every note plays it), the piece of `kind`.
Values onePiece(int kind, int artic = kArtHit) {
    return {{"mode", kModeSingle}, {"a1_engine", kEngineAcoustic}, {"a1_acou_piece", 0}, {"a1_acou_artic", artic},
            {pc(0, "kind"), kind}};
}
const std::vector<Event> kOneHit = {notes::noteOn(0, 1, 60, 0.8)};

}  // namespace

// ---------- Realism ----------

TEST(acoustic_membrane_modes_follow_the_bessel_zeros_and_air_pulls_them_toward_harmonic) {
    acoustic::AcousticKit k;
    CHECK(k.prepare(kSr));
    acoustic::PieceSettings p = piece(kPieceTom, 12);
    p.air = 0.0;
    k.setPiece(0, p, kQualityNormal);
    // The first six modes in order: (0,1) (1,1) (2,1) (0,2) (3,1) (1,2), each within 1 % of the Bessel zeros' ratios.
    const int order[6][2] = {{0, 1}, {1, 1}, {2, 1}, {0, 2}, {3, 1}, {1, 2}};
    auto zero = [](int m, int n) {
        double z = firstZero(m);
        for (int i = 1; i < n; ++i) {  // the next zero of J_m after z
            double a = z + 0.5;
            while ((besselJ(m, a) < 0.0) == (besselJ(m, a + 0.01) < 0.0)) a += 0.01;
            double lo = a, hi = a + 0.01;
            for (int it = 0; it < 80; ++it) {
                const double mid = 0.5 * (lo + hi);
                ((besselJ(m, mid) < 0.0) == (besselJ(m, lo) < 0.0) ? lo : hi) = mid;
            }
            z = 0.5 * (lo + hi);
        }
        return z;
    };
    const double z01 = zero(0, 1), f01 = k.modeHz(0, 0, 0);
    CHECK(std::fabs(f01 - acoustic::naturalHz(kPieceTom, 12)) < 0.01);
    for (int i = 0; i < 6; ++i) {
        const double want = zero(order[i][0], order[i][1]) / z01, got = k.modeHz(0, 0, static_cast<uint32_t>(i)) / f01;
        if (std::fabs(got / want - 1.0) > 0.01) {
            char msg[120];
            std::snprintf(msg, sizeof msg, "mode %d: %.4f against the Bessel ratio %.4f", i, got, want);
            cawtest::fail(__FILE__, __LINE__, msg);
        }
    }
    // Rendered: the (1,1) mode is where the model says (within 1.5 %).
    const double f11 = k.modeHz(0, 0, 1);
    // (struck near the edge, where the (1,1) mode is strong and the (0,1) weak): a peak of its own, not a slope
    std::vector<float> x = kitRender(k, 0.5, {{0, 0, kArtEdge, 0.3}});
    const double seen = peakHz(x, 0.05, 0.35, f11 * 0.97, f11 * 1.03);
    if (!(std::fabs(seen / f11 - 1.0) < 0.015)) std::printf("  (1,1) at %.2f Hz, the model's %.2f\n", seen, f11);
    CHECK(std::fabs(seen / f11 - 1.0) < 0.015);
    CHECK(seen > f11 * 0.971 && seen < f11 * 1.029);
    // With the air loading, the (m,1) family moves toward harmonic (1 : 1.5 : 2 for (1,1), (2,1), (3,1)).
    const double r21 = k.modeHz(0, 0, 2) / f11, r31 = k.modeHz(0, 0, 4) / f11;
    p.air = 1.0;
    k.setPiece(0, p, kQualityNormal);
    const double g11 = k.modeHz(0, 0, 1), s21 = k.modeHz(0, 0, 2) / g11, s31 = k.modeHz(0, 0, 4) / g11;
    CHECK(std::fabs(s21 - 1.5) < std::fabs(r21 - 1.5));
    CHECK(std::fabs(s31 - 2.0) < std::fabs(r31 - 2.0));
}

TEST(acoustic_stick_contact_lasts_half_to_five_ms_shorter_for_harder_sticks_and_faster_hits) {
    acoustic::AcousticKit k;
    CHECK(k.prepare(kSr));
    for (int kind : {kPieceSnare, kPieceTom}) {
        k.setPiece(0, piece(kind, kind == kPieceSnare ? 14 : 12), kQualityNormal);
        const double mf = contactMs(k, kArtHit, 0.4), ff = contactMs(k, kArtHit, 1.0);
        CHECK(mf >= 0.5 && mf <= 5.0);
        CHECK(ff >= 0.5 && ff <= 5.0);
        CHECK(ff < mf);
        std::printf("  contact on %s: %.2f ms (mf), %.2f ms (ff)\n", kind == kPieceSnare ? "snare" : "tom", mf, ff);
    }
    // Harder sticks: a stick's contact is shorter than a felt mallet's.
    k.setPiece(0, piece(kPieceSnare, 14), kQualityNormal);
    const double stick = contactMs(k, kArtHit, 0.7);
    acoustic::KitSettings ks;
    ks.stick = kStickMallets;
    k.setKit(ks);
    CHECK(contactMs(k, kArtHit, 0.7) > stick);
    // On the near-rigid rim, Hertz's law for a = 1.5: the contact falls as v^(-1/5) (the head's own compliance makes
    // a head stroke fall more slowly).
    k.setKit(acoustic::KitSettings{});
    const double slow = contactMs(k, kArtRimClick, 0.2, true), fast = contactMs(k, kArtRimClick, 1.0, true);
    const double vs = 0.3 + 6.0 * 0.2 * 0.8, vf = 0.3 + 6.0 * 1.0 * 0.8;  // the stroke's speeds (rim click: x 0.8)
    const double exponent = std::log(fast / slow) / std::log(vf / vs);
    std::printf("  rim contact: %.3f ms -> %.3f ms, exponent %.3f (Hertz: -0.2)\n", slow, fast, exponent);
    CHECK(exponent < -0.1 && exponent > -0.3);
}

TEST(acoustic_tom_pitch_glides_down_after_hard_hits_and_more_the_harder) {
    acoustic::AcousticKit k;
    CHECK(k.prepare(kSr));
    k.setPiece(0, piece(kPieceTom, 12), kQualityNormal);
    const double f = k.modeHz(0, 0, 0);
    double last = -1.0;
    for (double v : {0.15, 0.6, 1.0}) {
        k.reset();
        const std::vector<float> x = kitRender(k, 0.6, {{0, 0, kArtHit, v}});
        const double early = peakHz(x, 0.01, 0.06, f * 0.9, f * 1.2), late = peakHz(x, 0.3, 0.5, f * 0.9, f * 1.2);
        const double fall = early / late - 1.0;
        if (v < 0.2) CHECK(fall < 0.006);   // a soft hit: no glide to speak of (a tenth of a semitone)
        if (v > 0.9) CHECK(fall > 0.015);   // a hard one: a quarter tone and more
        CHECK(fall > last);
        last = fall;
    }
}

TEST(acoustic_snare_wires_buzz_grow_with_velocity_and_answer_the_kick) {
    for (int q : {kQualityEco, kQualityNormal, kQualityHigh}) {
        acoustic::AcousticKit k;
        CHECK(k.prepare(kSr));
        acoustic::PieceSettings sn = piece(kPieceSnare, 14);
        k.setPiece(0, sn, q);
        const std::vector<float> on = kitRender(k, 0.4, {{0, 0, kArtHit, 0.8}});
        sn.wires = 0.0;
        k.setPiece(0, sn, q);
        const std::vector<float> off = kitRender(k, 0.4, {{0, 0, kArtHit, 0.8}});
        const double buzz = db(band(on, 0.02, 0.2, 5000, 12000), band(off, 0.02, 0.2, 5000, 12000));
        if (!(buzz > 10.0)) std::printf("  wires on/off at quality %d: %.1f dB\n", q, buzz);
        CHECK(buzz > 10.0);  // the wires' buzz
        sn.wires = 0.6;
        k.setPiece(0, sn, q);
        double last = 0.0;
        for (double v : {0.3, 0.6, 1.0}) {
            k.reset();
            const double e = band(kitRender(k, 0.4, {{0, 0, kArtHit, v}}), 0.02, 0.2, 5000, 12000);
            CHECK(e > last);
            last = e;
        }
        // Only the kick played: the snare (sympathetic drive) buzzes, its 5-12 kHz energy rising.
        k.setPiece(1, piece(kPieceKick, 22), q);
        k.reset();
        const std::vector<float> kickWithSnare = kitRender(k, 0.4, {{0, 1, kArtHit, 1.0}});
        k.setPiece(0, piece(kPieceOff, 14), q);
        k.reset();
        const std::vector<float> kickAlone = kitRender(k, 0.4, {{0, 1, kArtHit, 1.0}});
        CHECK(db(band(kickWithSnare, 0.02, 0.2, 5000, 12000), band(kickAlone, 0.02, 0.2, 5000, 12000)) > 10.0);
    }
}

TEST(acoustic_crash_swell_rises_with_velocity_and_soft_hits_stay_linear) {
    acoustic::AcousticKit k;
    CHECK(k.prepare(kSr));
    auto share = [&](double swell, double v) {
        acoustic::PieceSettings c = piece(kPieceCrash, 18);
        c.swell = swell;
        k.setPiece(0, c, kQualityNormal);
        k.reset();
        const std::vector<float> x = kitRender(k, 0.35, {{0, 0, kArtHit, v}});
        const double early = band(x, 0.0, 0.02, 8000, 16000) / band(x, 0.0, 0.02, 100, 16000),
                     late = band(x, 0.1, 0.3, 8000, 16000) / band(x, 0.1, 0.3, 100, 16000);
        return db(late, early);  // the share of energy above 8 kHz at 100-300 ms against the first 20 ms
    };
    const double soft = share(0.5, 0.15), medium = share(0.5, 0.5), hard = share(0.5, 1.0);
    std::printf("  crash: high share late/early %.2f, %.2f, %.2f dB (soft, medium, hard)\n", soft, medium, hard);
    CHECK(medium > soft);
    CHECK(hard > medium + 1.0);
    CHECK(std::fabs(soft - share(0.0, 0.15)) < 1.0);   // a soft hit is linear: the cascade adds under 1 dB
    CHECK(hard - share(0.0, 1.0) > 2.0);               // a hard one swells
}

TEST(acoustic_hihat_pedal_moves_decay_and_brightness_monotonically_and_closing_chicks) {
    acoustic::AcousticKit k;
    CHECK(k.prepare(kSr));
    k.setPiece(0, piece(kPieceHiHat, 14), kQualityNormal);
    double lastDecay = 1e9, lastCentroid = 0.0, openDecay = 0.0, closedDecay = 0.0;
    for (double pedal : {0.0, 0.5, 0.65, 0.8, 0.9, 1.0}) {
        acoustic::KitSettings ks;
        ks.hatPedal = pedal;
        k.setKit(ks);
        k.reset();
        const std::vector<float> x = kitRender(k, 1.5, {{4800, 0, kArtHit, 0.7}});
        const float pk = peakOf(x);
        size_t last = 0;
        for (size_t i = 0; i < x.size(); ++i)
            if (std::fabs(x[i]) > pk * 0.01f) last = i;
        const double decay = (static_cast<double>(last) - 4800.0) / kSr;  // to -40 dB
        double num = 0.0, den = 0.0;
        for (double f = 200; f < 16000; f += 400) {
            const double e = band(x, 0.1, 0.16, f, f);
            num += f * e, den += e;
        }
        const double centroid = num / den;
        CHECK(decay <= lastDecay + 1e-9);
        CHECK(centroid >= lastCentroid - 50.0);
        lastDecay = decay, lastCentroid = centroid;
        if (pedal == 0.0) openDecay = decay;
        if (pedal == 1.0) closedDecay = decay;
    }
    CHECK(closedDecay < openDecay / 4.0);
    // Open, then the foot closes the pedal fast: the plates meet (the chick) with no stick at all.
    k.setKit(acoustic::KitSettings{});
    k.reset();
    const std::vector<float> chick = kitRender(k, 0.3, {{0, 0, kArtFoot, 0.8}});
    CHECK(peakOf(chick) > 0.003f);
    CHECK(finite(chick));
}

TEST(acoustic_press_rolls_bounce_every_ten_to_forty_ms_and_a_held_roll_keeps_going) {
    acoustic::AcousticKit k;
    CHECK(k.prepare(kSr));
    k.setPiece(0, piece(kPieceSnare, 14), kQualityNormal);
    k.strike(0, kArtBuzz, 0.6, 0.0, 1);
    double l[16], r[16];
    uint32_t seen = 0;
    std::vector<double> at;  // the start of each bounce more than 2 ms after the previous one
    for (uint32_t t = 0; t < 24000; t += 16) {
        k.process(l, r, nullptr, 16);
        k.endCell();
        const acoustic::Striker& s = k.piece(0).stick[0];
        if (s.bounces != seen) {
            seen = s.bounces;
            const double ms = t / 48.0;
            if (at.empty() || ms - at.back() > 2.0) at.push_back(ms);
        }
    }
    CHECK(at.size() >= 3);
    for (size_t i = 1; i < 3 && i < at.size(); ++i) {
        CHECK(at[i] - at[i - 1] >= 10.0);
        CHECK(at[i] - at[i - 1] <= 40.0);
    }
    // A roll: strokes while its note is held, its energy kept up; the note off ends it.
    k.reset();
    k.strike(0, kArtRoll, 0.6, 0.0, 7);
    std::vector<float> x;
    for (uint32_t t = 0; t < 48000; t += 16) {
        if (t == 24000) k.release(7);
        std::fill(l, l + 16, 0.0), std::fill(r, r + 16, 0.0);
        if (k.awake()) k.process(l, r, nullptr, 16), k.endCell();
        for (int i = 0; i < 16; ++i) x.push_back(static_cast<float>(l[i] + r[i]));
    }
    const double first = band(x, 0.0, 0.1, 200, 8000), held = band(x, 0.35, 0.5, 200, 8000), after = band(x, 0.85, 1.0, 200, 8000);
    CHECK(db(held, first) > -6.0);
    CHECK(db(after, held) < -20.0);
}

// ---------- Settings, articulations and the instrument ----------

TEST(acoustic_every_articulation_a_piece_takes_sounds_its_own) {
    const int kinds[] = {kPieceKick, kPieceSnare, kPieceTom, kPieceHiHat, kPieceCrash, kPieceRide, kPieceSplash, kPieceChina};
    int failures = 0;
    for (int q : {kQualityEco, kQualityNormal}) {
        for (int kind : kinds) {
            std::vector<std::vector<float>> outs;
            std::vector<int> artics;
            for (int a = 0; a < kArtCount; ++a) {
                if (!articulationApplies(kind, a)) continue;
                Values v = onePiece(kind, a);
                v.push_back({"acou_hat_pedal", 0.85});  // half-closed: a Hit is neither the Open nor the Closed one
                outs.push_back(render(q, v, {notes::noteOn(0, 1, 60, 0.8), notes::noteOff(12000, 1, 60)}, 24000));
                artics.push_back(a);
                CHECK(finite(outs.back()));
            }
            for (size_t i = 0; i < outs.size(); ++i)
                for (size_t j = i + 1; j < outs.size(); ++j)
                    if (apart(outs[i], outs[j]) < 2e-3 && ++failures <= 20) {
                        char msg[160];
                        std::snprintf(msg, sizeof msg, "kind %d: articulations %d and %d sound the same (quality %d)", kind,
                                      artics[i], artics[j], q);
                        cawtest::fail(__FILE__, __LINE__, msg);
                    }
        }
    }
    // One a piece does not take plays as the nearest it does (a rimshot on a cymbal is its edge).
    CHECK_EQ(articulationFor(kPieceCrash, kArtRimshot), static_cast<int>(kArtEdge));
    CHECK_EQ(articulationFor(kPieceKick, kArtBell), static_cast<int>(kArtHit));
}

TEST(acoustic_every_kit_and_piece_setting_changes_the_sound_and_its_needs_are_honest) {
    const ParameterDescriptor* t = parameterTable();
    auto moves = [](const ParameterDescriptor& d) {
        std::vector<double> v;
        if (d.choiceCount > 0) {
            for (uint32_t c = 0; c < d.choiceCount; ++c) v.push_back(c);
            return v;
        }
        const double span = d.maximum - d.minimum;
        for (double x : {d.minimum, d.maximum, d.minimum + 0.3 * span}) {
            if (d.step > 0) x = std::round(x);
            if (std::fabs(x - d.defaultValue) > 0.05 * span) v.push_back(x);
        }
        return v;
    };
    int failures = 0;
    auto heard = [&](const std::string& id, const Values& base, const std::vector<Event>& events, bool choice) {
        const ParameterDescriptor& d = t[parameterIndex(id)];
        std::vector<std::vector<float>> outs;
        Values b = base;
        b.push_back({id, d.defaultValue});
        outs.push_back(render(kQualityNormal, b, events, 24000));
        for (double m : moves(d)) {
            if (m == d.defaultValue) continue;
            Values x = base;
            x.push_back({id, m});
            outs.push_back(render(kQualityNormal, x, events, 24000));
        }
        for (size_t i = 0; i < outs.size(); ++i)
            for (size_t j = i + 1; j < outs.size(); ++j) {
                if (!choice && i > 0) continue;
                if (apart(outs[i], outs[j]) < 2e-3 && ++failures <= 30)
                    cawtest::fail(__FILE__, __LINE__, id + " moved changes nothing");
            }
    };
    // Each piece setting on a kind it belongs to (needs()), piece 1 hit on its own.
    for (const NeedRule& r : needs()) {
        if (!r.global || r.param < pieceParam(0, 0) || r.param >= pieceParam(1, 0)) continue;
        const std::vector<int>& kinds = r.all.front().in;
        const int kind = kinds.front() == kPieceKick && kinds.size() > 1 && r.param != pieceParam(0, kPcBeater) &&
                                 r.param != pieceParam(0, kPcPort)
                             ? kinds[1]  // a snare where kick, snare and tom all take it (wires and shell show more)
                             : kinds.front();
        const std::string id(t[r.param].id);
        Values base = onePiece(kind);
        base.push_back({"room", 0.5});
        heard(id, base, kOneHit, t[r.param].choiceCount > 0);
        // Honest needs: on a played kind outside its list, moving it changes nothing at all.
        for (int other = kPieceKick; other < kPieceKindCount; ++other) {
            if (std::find(kinds.begin(), kinds.end(), other) != kinds.end()) continue;
            Values o = onePiece(other);
            const std::vector<float> ref = render(kQualityNormal, o, kOneHit, 12000);
            for (double m : moves(t[r.param])) {
                Values x = o;
                x.push_back({id, m});
                if (apart(ref, render(kQualityNormal, x, kOneHit, 12000)) > 1e-9 && ++failures <= 30)
                    cawtest::fail(__FILE__, __LINE__, id + " is heard on kind " + std::to_string(other) + ", which its needs exclude");
            }
            break;
        }
    }
    // The kit's own: a kick, a snare (it buzzes with the kick), a hat and a crash, hit in turn, the room on.
    Values kit = {{"mode", kModeKit}, {"room", 0.5}, {pc(0, "kind"), kPieceKick}, {pc(1, "kind"), kPieceSnare},
                  {pc(2, "kind"), kPieceHiHat}, {pc(3, "kind"), kPieceCrash}};
    const int notesOf[4] = {36, 38, 42, 49};
    for (uint32_t pad = 0; pad < 4; ++pad) {
        const std::string a = "a" + std::to_string(pad + 1) + "_";
        kit.push_back({a + "engine", kEngineAcoustic});
        kit.push_back({a + "acou_piece", pad});
        kit.push_back({a + "note", kNoteFirst + notesOf[pad]});
    }
    kit.push_back({"a5_note", kNoteOff});
    kit.push_back({"a2_acou_artic", kArtHit});
    const std::vector<Event> pattern = {notes::noteOn(0, 1, 36, 1.0), notes::noteOn(4800, 2, 42, 0.7),
                                        notes::noteOn(9600, 3, 38, 0.9), notes::noteOn(14400, 4, 49, 0.8)};
    for (uint32_t k = 0; k < kAcouCount; ++k) {
        const std::string id(t[acouParam(k)].id);
        if (id == "kit_kind") continue;  // which builder made the kit: metadata
        heard(id, kit, pattern, t[acouParam(k)].choiceCount > 0);
    }
    if (failures) std::printf("acoustic audit: %d settings changed nothing\n", failures);
}

TEST(acoustic_kit_renders_the_same_at_any_block_size_stays_finite_and_sleeps) {
    Values v = {{"mode", kModeKit}, {"room", 0.3}};
    const int kinds[] = {kPieceKick, kPieceSnare, kPieceTom, kPieceHiHat, kPieceCrash, kPieceRide};
    for (uint32_t i = 0; i < 6; ++i) {
        v.push_back({pc(i, "kind"), kinds[i]});
        const std::string a = "a" + std::to_string(i + 1) + "_";
        v.push_back({a + "engine", kEngineAcoustic});
        v.push_back({a + "acou_piece", i});
        v.push_back({a + "rnd_pos", 0.4});
        v.push_back({pc(i, "decay"), 0.4});  // short: asleep inside the 6 s
    }
    v.push_back({"a2_acou_artic", kArtRoll});
    v.push_back({"a3_acou_artic", kArtFlam});
    const std::vector<Event> ev = {notes::noteOn(0, 1, 36, 1.0),     notes::noteOn(100, 2, 37, 0.7),
                                   notes::noteOff(9000, 2, 37),      notes::noteOn(3001, 3, 38, 0.9),
                                   notes::noteOn(5003, 4, 39, 0.6),  notes::noteOn(7000, 5, 40, 1.0),
                                   notes::noteOn(11111, 6, 41, 0.8), notes::notePressure(20000, 5, 40, 1.0),
                                   notes::noteOn(30000, 7, 36, 0.5)};
    std::vector<Event> sorted = ev;
    std::sort(sorted.begin(), sorted.end(), [](const Event& a, const Event& b) { return a.frame < b.frame; });
    for (int q : {kQualityEco, kQualityNormal, kQualityHigh}) {
        bool quiet = false;
        const std::vector<float> ref = render(q, v, sorted, 6 * 48000, 64, &quiet);
        CHECK(finite(ref));
        if (!(peakOf(ref) > 0.05f && peakOf(ref) < 4.0f)) std::printf("  peak %g at quality %d\n", peakOf(ref), q);
        CHECK(peakOf(ref) > 0.05f && peakOf(ref) < 4.0f);
        CHECK(quiet);  // everything asleep again (and the room's tail gone) by 6 s
        for (uint32_t block : {1u, 37u, 512u}) {
            const std::vector<float> x = render(q, v, sorted, 6 * 48000, block);
            CHECK(x == ref);
            for (size_t i = 0; i < x.size() && i < ref.size(); ++i)
                if (x[i] != ref[i]) { std::printf("  TMP q %d block %u diff at %zu: %g vs %g\n", q, block, i / 2, x[i], ref[i]); break; }
        }
    }
}

TEST(acoustic_extreme_settings_and_hits_stay_finite_and_recover) {
    // Every piece setting at an end, the hardest hits in every articulation: finite, bounded, and a plain hit after
    // still sounds.
    const ParameterDescriptor* t = parameterTable();
    for (int kind = kPieceKick; kind < kPieceKindCount; ++kind)
        for (int end = 0; end < 2; ++end) {
            Values v = onePiece(kind);
            for (uint32_t p = 1; p < kPieceParams; ++p) {
                if (p == kPcLevel) continue;  // its bottom is silence
                const ParameterDescriptor& d = t[pieceParam(0, p)];
                v.push_back({std::string(d.id), end ? d.maximum : d.minimum});
            }
            v.push_back({"a1_level", 12});
            std::vector<Event> ev;
            for (uint32_t a = 0; a < kArtCount; ++a) {
                ev.push_back(notes::noteOn(a * 2000, a + 1, 60, 1.0));
                ev.push_back(notes::noteOff(a * 2000 + 1500, a + 1, 60));
            }
            ev.push_back(notes::noteOn(40000, 99, 60, 0.7));
            Values all = v;
            for (uint32_t a = 0; a < kArtCount; ++a) {
                all = v;
                all.push_back({"a1_acou_artic", a});
                const std::vector<float> x = render(kQualityHigh, all, ev, 48000);
                CHECK(finite(x));
                CHECK(peakOf(x) < 50.0f);  // loud at these ends, but inside the guard's bound
                CHECK(peakOf(std::vector<float>(x.begin() + 80000, x.end())) > 1e-4f);
            }
        }
}

// ---------- The builders ----------

TEST(rook_builds_eight_kits_of_each_kind_deterministically_and_they_sound) {
    for (int kind = 0; kind < kBuildKindCount; ++kind) {
        CHECK(buildStyles(kind).size() >= 8);
        for (int style = 0; style < static_cast<int>(buildStyles(kind).size()); ++style) {
            BuiltKit a, b;
            CHECK(buildKit(kind, style, 7, 3, kMapGeneralMidi, false, a));
            CHECK(buildKit(kind, style, 7, 3, kMapGeneralMidi, false, b));
            CHECK(a.values == b.values);
            BuiltKit c;
            CHECK(buildKit(kind, style, 8, 3, kMapGeneralMidi, false, c));
            if (kind != kBuildAcoustic) CHECK(c.values != a.values);  // another seed, another kit
        }
    }
    BuiltKit none;
    CHECK(!buildKit(kBuildKindCount, 0, 1, -1, 0, false, none));
    // Every new preset (8 of each kind) loads, plays its GM bar and sounds.
    int seen[3] = {};
    for (const BuiltinPreset& p : builtinPresets("org.caw.drums")) {
        const std::string name(p.name);
        int kind = -1;
        if (name.rfind("Synth kit: ", 0) == 0) kind = 0;
        if (name.rfind("Produced kit: ", 0) == 0) kind = 1;
        if (name.rfind("Acoustic kit: ", 0) == 0) kind = 2;
        if (kind < 0) continue;
        ++seen[kind];
        Values v;
        for (const auto& [id, x] : p.values) v.emplace_back(std::string(id), x);
        const std::vector<float> x = render(kQualityNormal, v,
                                            {notes::noteOn(0, 1, 36, 1.0), notes::noteOn(6000, 2, 38, 0.9),
                                             notes::noteOn(12000, 3, 42, 0.7), notes::noteOn(18000, 4, 49, 0.8)},
                                            36000);
        CHECK(finite(x));
        if (peakOf(x) < 0.05f || peakOf(x) > 4.0f) cawtest::fail(__FILE__, __LINE__, name + " is silent or too loud");
    }
    for (int k = 0; k < 3; ++k) CHECK(seen[k] >= 8);
}

TEST(rook_acoustic_kits_follow_gm_roland_and_alesis_note_maps_and_tune_to_a_key) {
    auto value = [](const BuiltKit& k, const std::string& id, double fallback) {
        const int i = parameterIndex(id);
        for (const auto& [p, v] : k.values)
            if (static_cast<int>(p) == i) return v;
        return fallback;
    };
    // The pad playing `note`, its piece and articulation.
    auto padFor = [&](const BuiltKit& k, int note, int& pieceOut, int& articOut) {
        for (uint32_t pad = 0; pad < kPads; ++pad) {
            const std::string a = padId(pad) + "_";
            if (value(k, a + "note", -1) != kNoteFirst + note) continue;
            pieceOut = static_cast<int>(value(k, a + "acou_piece", 0));
            articOut = static_cast<int>(value(k, a + "acou_artic", 0));
            return value(k, a + "engine", 0) == kEngineAcoustic;
        }
        return false;
    };
    BuiltKit gm, roland, alesis;
    CHECK(buildKit(kBuildAcoustic, 1, 1, -1, kMapGeneralMidi, false, gm));
    CHECK(buildKit(kBuildAcoustic, 1, 1, -1, kMapRoland, false, roland));
    CHECK(buildKit(kBuildAcoustic, 1, 1, -1, kMapAlesis, false, alesis));
    int piece = -1, artic = -1;
    CHECK(padFor(gm, 38, piece, artic) && value(gm, pc(static_cast<uint32_t>(piece), "kind"), 0) == kPieceSnare && artic == kArtHit);
    CHECK(padFor(gm, 37, piece, artic) && artic == kArtCrossStick);
    CHECK(padFor(gm, 44, piece, artic) && value(gm, pc(static_cast<uint32_t>(piece), "kind"), 0) == kPieceHiHat && artic == kArtFoot);
    CHECK(padFor(roland, 26, piece, artic) && artic == kArtEdge);       // open hat, edge
    CHECK(padFor(roland, 58, piece, artic) && artic == kArtRimshot);    // tom 3's rim
    CHECK(padFor(alesis, 23, piece, artic) && artic == kArtHit);        // half-open: the pedal's place
    CHECK(value(alesis, "acou_hat_pedal", 1.0) == 0.7);
    CHECK(padFor(alesis, 21, piece, artic));                            // the splash
    // Tuned to a key: the kick sits on its root (here A = 9), the snare and toms on the key's notes.
    BuiltKit inA;
    CHECK(buildKit(kBuildAcoustic, 1, 1, 9, kMapGeneralMidi, false, inA));
    const double kick = acoustic::naturalHz(kPieceKick, value(inA, pc(0, "size"), 14)) * std::exp2(value(inA, pc(0, "tune"), 0) / 12.0);
    const double m = 69.0 + 12.0 * std::log2(kick / 440.0);
    CHECK(std::fabs(m - std::round(m)) < 1e-6 && (static_cast<int>(std::round(m)) % 12) == 9);
}

TEST(rook_kit_tools_tune_layer_finish_map_and_render_a_pad) {
    auto call = [](const std::string& req) {
        char* r = caw_drums_kit_tool(req.c_str());
        Json j;
        std::string err;
        CHECK(parseJson(r, j, err));
        caw_free(r);
        return j;
    };
    char* built = caw_drums_kit_build(kBuildProduced, 0, 3, 5, 0);
    Json kit;
    std::string err;
    CHECK(parseJson(built, kit, err));
    caw_free(built);
    CHECK(kit.boolean("ok", false));
    std::string params;
    {
        const Json* p = kit.get("params");
        CHECK(p && p->obj.size() > 100);
        params = "{";
        for (const auto& [id, v] : p->obj) params += (params.size() > 1 ? ",\"" : "\"") + id + "\":" + std::to_string(v.num);
        params += "}";
    }
    const std::string entry = "\"entry\":{\"params\":" + params + "}";
    // Layer from the library: a snare's noise joins the produced kick (a1), which had none.
    Json layer = call("{\"tool\":\"layer\",\"pad\":0,\"sound\":\"909 Snare\"," + entry + "}");
    CHECK(layer.boolean("ok", false));
    CHECK(layer.get("params") && layer.get("params")->number("a1_noise_on", 0) == 1.0);
    CHECK(layer.get("params")->number("a1_body_on", 1) == 1.0);  // the kick's own layers stay (on is A1's default)
    // Finishing chains, per pad and on the bus.
    Json punch = call("{\"tool\":\"finish\",\"chain\":\"Punch\",\"pad\":2," + entry + "}");
    CHECK(punch.get("params") && punch.get("params")->number("a3_tr_attack", 0) == 0.5);
    Json glue = call("{\"tool\":\"finish\",\"chain\":\"Glue\",\"pad\":-1," + entry + "}");
    CHECK(glue.get("params") && glue.get("params")->number("glue", 0) == 0.6);
    // Tune to key and mutate answer with whole params; bad requests fail closed with a reason.
    CHECK(call("{\"tool\":\"tune_to_key\",\"key\":2," + entry + "}").boolean("ok", false));
    CHECK(call("{\"tool\":\"mutate\",\"amount\":0.2,\"seed\":4," + entry + "}").boolean("ok", false));
    CHECK(!call("{\"tool\":\"tune_to_key\",\"key\":12," + entry + "}").boolean("ok", true));
    CHECK(!call("{\"tool\":\"nope\"}").boolean("ok", true));
    CHECK(!call("[1]").boolean("ok", true));
    // Render a pad to a sample: a WAV written, the pad now plays it.
    const std::string path = "rook_render_pad_test.wav";
    Json r = call("{\"tool\":\"render_pad\",\"pad\":0,\"path\":\"" + path + "\"," + entry + "}");
    CHECK(r.boolean("ok", false));
    CHECK(r.number("frames", 0) > 1000);
    CHECK(r.get("params") && r.get("params")->number("a1_smp_on", 0) == 1.0 && r.get("params")->number("a1_body_on", 1) == 0.0);
    FILE* f = std::fopen(path.c_str(), "rb");
    CHECK(f != nullptr);
    if (f) std::fclose(f);
    std::remove(path.c_str());
    // An Acoustic kit's map again (Roland), from its own values.
    char* ac = caw_drums_kit_build(kBuildAcoustic, 0, 1, -1, 0);
    Json acj;
    CHECK(parseJson(ac, acj, err));
    caw_free(ac);
    std::string ap = "{";
    for (const auto& [id, v] : acj.get("params")->obj) ap += (ap.size() > 1 ? ",\"" : "\"") + id + "\":" + std::to_string(v.num);
    ap += "}";
    Json mapped = call("{\"tool\":\"map\",\"map\":1,\"entry\":{\"params\":" + ap + "}}");
    CHECK(mapped.boolean("ok", false));
    bool edge = false;
    for (const auto& [id, v] : mapped.get("params")->obj)
        if (id.size() > 5 && id.substr(id.size() - 5) == "_note" && v.num == kNoteFirst + 26) edge = true;
    CHECK(edge);
}
