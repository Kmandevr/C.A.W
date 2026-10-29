// Synth tests: wavetables (band-limiting, determinism, frames) and the wt oscillator (pitch, aliasing, morph, unison).
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "compile.h"
#include "detmath.h"
#include "tables.h"
#include "test.h"
#include "vm.h"

using namespace caw;

namespace {

// Runs a module over `total` samples in blocks of `chunk` (as a device with that buffer size would).
std::vector<double> runChunks(const std::string& body, int total, int chunk, double sr = 48000) {
    CompileResult r = compileModule("---\nmode: float\n---\n" + body);
    if (!r.program) {
        cawtest::fail(__FILE__, __LINE__, "compile failed: " + body + " -> " + r.error);
        return {};
    }
    Instance inst(r.program);
    std::vector<double> out;
    double tb[kBlock], time[kBlock], zero[kBlock] = {};
    BlockCtx c;
    c.sr = sr;
    for (int at = 0; at < total; at += chunk) {
        c.n = std::min(chunk, total - at);
        for (int i = 0; i < c.n; ++i) {
            tb[i] = at + i;
            time[i] = tb[i] / sr;
        }
        for (int v = 0; v < static_cast<int>(Var::Count); ++v) c.vars[v] = zero;
        c.vars[static_cast<int>(Var::T)] = tb;
        c.vars[static_cast<int>(Var::Time)] = time;
        inst.process(c);
        const double* raw = inst.rawOutput();
        out.insert(out.end(), raw, raw + c.n);
    }
    return out;
}

std::vector<double> run(const std::string& body, int blocks, double sr = 48000) {
    CompileResult r = compileModule("---\nmode: float\n---\n" + body);
    if (!r.program) {
        cawtest::fail(__FILE__, __LINE__, "compile failed: " + body + " -> " + r.error);
        return {};
    }
    Instance inst(r.program);
    std::vector<double> out;
    double tb[kBlock], time[kBlock], zero[kBlock] = {};
    BlockCtx c;
    c.sr = sr;
    for (int b = 0; b < blocks; ++b) {
        for (int i = 0; i < kBlock; ++i) {
            tb[i] = b * kBlock + i;
            time[i] = tb[i] / sr;
        }
        c.n = kBlock;
        for (int v = 0; v < static_cast<int>(Var::Count); ++v) c.vars[v] = zero;
        c.vars[static_cast<int>(Var::T)] = tb;
        c.vars[static_cast<int>(Var::Time)] = time;
        inst.process(c);
        const double* raw = inst.rawOutput();
        out.insert(out.end(), raw, raw + kBlock);
    }
    return out;
}

// Magnitude of the DFT of x at `hz` (a plain correlation), normalized so a full-scale sine reads 1.
double amplitudeAt(const std::vector<double>& x, double hz, double sr = 48000) {
    double re = 0, im = 0;
    for (size_t i = 0; i < x.size(); ++i) {
        const double a = kTwoPi * hz * static_cast<double>(i) / sr;
        re += x[i] * std::cos(a);
        im += x[i] * std::sin(a);
    }
    return 2.0 * std::sqrt(re * re + im * im) / static_cast<double>(x.size());
}

double rms(const std::vector<double>& x) {
    double s = 0;
    for (double v : x) s += v * v;
    return std::sqrt(s / static_cast<double>(x.size()));
}

}  // namespace

TEST(tables_band_limit_by_octave_and_build_deterministically) {
    CHECK_EQ(Table::levelFor(20.0 / 48000), 0);            // the lowest notes keep every harmonic
    CHECK_EQ(Table::levelFor(110.0 / 48000), 3);           // 110 Hz: 128 harmonics, up to 14 kHz
    CHECK_EQ(Table::levelFor(0.25), kTableLevels - 1);      // 12 kHz: only the fundamental fits
    for (int l = 0; l < kTableLevels; ++l) CHECK(Table::levelSize(l) >= 4 * (1024 >> l) || Table::levelSize(l) == kTableSize);
    // The same cycles give the same bits.
    std::vector<double> c;
    for (int i = 0; i < 2 * kTableSize; ++i) c.push_back(std::fmod(i * 0.37, 1.0) - 0.5);
    auto a = buildTable(c, 2), b = buildTable(c, 2);
    CHECK(a->data == b->data);
    CHECK_EQ(a->frames, 2);
    // The top level of a saw is a plain sine: one harmonic, no DC.
    const Table& saw = *builtinTable(2);
    const float* top = saw.frame(kTableLevels - 1, 0);
    const int n = Table::levelSize(kTableLevels - 1);
    double sum = 0;
    for (int i = 0; i < n; ++i) sum += top[i];
    CHECK_NEAR(sum / n, 0.0, 1e-6);
    CHECK_NEAR(top[n], top[0], 0.0);  // the guard sample repeats the first
}

TEST(wt_sine_matches_sine_and_saw_has_its_harmonics) {
    auto w = run("wt(table.sine, 375)", 375);  // 0.5 s; 375 Hz fits a whole number of cycles
    auto s = run("sine(375)", 375);
    double worst = 0;
    for (size_t i = 0; i < w.size(); ++i) worst = std::max(worst, std::fabs(w[i] - s[i]));
    CHECK(worst < 2e-4);
    auto saw = run("wt(table.saw, 375)", 375);
    CHECK_NEAR(amplitudeAt(saw, 375), 2.0 / kPi, 0.01);   // a saw's harmonics fall as 2 / (pi h)
    CHECK_NEAR(amplitudeAt(saw, 750), 1.0 / kPi, 0.01);
    CHECK_NEAR(amplitudeAt(saw, 1125), 2.0 / (3 * kPi), 0.01);
}

TEST(wt_does_not_alias_at_high_notes) {
    // A 9 kHz saw at 48 kHz: only 9 and 18 kHz may sound. A naive saw would fold 27 kHz back to 21 kHz, 36 to 12 and
    // 45 to 3 kHz.
    auto x = run("wt(table.saw, 9000)", 375);
    CHECK(amplitudeAt(x, 9000) > 0.5);
    CHECK(amplitudeAt(x, 18000) > 0.2);
    for (double hz : {3000.0, 12000.0, 21000.0, 6000.0, 15000.0}) CHECK(amplitudeAt(x, hz) < 0.002);
}

TEST(wt_morphs_through_frames_with_pos) {
    // table.basic: frame 0 is a sine, frame 3 a square (odd harmonics, 4 / (pi h)).
    auto first = run("wt(table.basic, 375, 0)", 375);
    auto last = run("wt(table.basic, 375, 1)", 375);
    CHECK(amplitudeAt(first, 1125) < 0.001);
    CHECK_NEAR(amplitudeAt(last, 375), 4.0 / kPi, 0.02);
    CHECK_NEAR(amplitudeAt(last, 1125), 4.0 / (3 * kPi), 0.02);
    // Halfway sits between frame 1 (triangle) and frame 2 (saw): it has the saw's even harmonics, at half strength.
    auto mid = run("wt(table.basic, 375, 0.5)", 375);
    CHECK_NEAR(amplitudeAt(mid, 750), 0.5 / kPi, 0.01);
}

TEST(wt_unison_detunes_and_keeps_the_level) {
    auto one = run("wt(table.saw, 220)", 750);
    auto seven = run("wt(table.saw, 220, 0, 7, 0.3)", 750);
    CHECK(seven != one);
    const double r1 = rms(one), r7 = rms(seven);
    CHECK(r7 > r1 * 0.5 && r7 < r1 * 1.5);  // 1 / sqrt(voices) keeps a wide stack about as loud as one voice
    // The outer voices sit 0.3 semitones away: energy appears off the centre pitch.
    CHECK(amplitudeAt(seven, 220 * std::pow(2.0, 0.3 / 12)) > 0.02);
    // The same code gives the same samples.
    CHECK(run("wt(table.saw, 220, 0, 7, 0.3)", 750) == seven);
}

TEST(wt_gives_the_same_samples_whatever_the_block_size) {
    // Detune, pos and pitch move every sample, and the unison count and table come from expressions: a device with
    // 17-sample buffers and an export in 64-sample blocks must agree exactly.
    const std::string body = "wt(t > 100 ? table.saw : table.basic, 200 + t * 0.01, fract(t / 3000), 3 + (t > 50) * 4, fract(t / 777))";
    CHECK(runChunks(body, 6000, 64) == runChunks(body, 6000, 17));
    CHECK(runChunks(body, 6000, 64) == runChunks(body, 6000, 1));
}

TEST(wt_unknown_table_and_bad_values_stay_safe) {
    auto x = run("wt(99, 0 / 0, 2, 50, -3)", 10);
    auto huge = run("wt(1e30, 1e300, -1e30, 1e30, 1e30)", 10);
    for (double v : huge) CHECK(std::isfinite(v));
    for (double v : x) CHECK(std::isfinite(v));
    CompileResult bad = compileModule("---\nmode: float\n---\nwt(table.nothing, 220)\n");
    CHECK(!bad.program);
    CHECK(bad.error.find("table names: sine, tri, saw") != std::string::npos);
    // scale.x, chord.x and arp.x with an unknown x still read another module's value, as they always did.
    CHECK(compileModule("---\nmode: float\n---\nscale.mine * 0.1\n").program != nullptr);
}
