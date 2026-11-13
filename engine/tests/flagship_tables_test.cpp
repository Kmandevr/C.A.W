// The flagship synth's warps against aliasing (FM, fold, Osc FM) and its user wavetable, taken in as its component state.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <complex>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "caw/instrument.hpp"
#include "analysis.h"
#include "engine.h"
#include "project.h"
#include "quality.h"
#include "test.h"

using namespace caw;

namespace {

constexpr const char* kId = "org.caw.synth.flagship";
using Values = std::vector<std::pair<std::string, double>>;
constexpr double kPi = 3.14159265358979323846;

int paramIndex(const ModuleDescriptor& d, const std::string& id) {
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == id) return static_cast<int>(k);
    cawtest::fail(__FILE__, __LINE__, "no parameter " + id);
    return -1;
}

// One sine copy into no filter and no effects, over the defaults, plus `extra`.
Values plain(Values extra = {}) {
    Values v = {{"osc1_frame", 0.0}, {"osc1_unison", 1},      {"flt1_on", 0},       {"fx_reverb_on", 0},
                {"mod1_src", 0},     {"env1_attack", 0.001}, {"env1_sustain", 1.0}, {"osc1_phase_rand", 0},
                {"osc1_spread", 0}};
    for (auto& e : extra) v.push_back(e);
    return v;
}

// Plays a note on through an activated flagship in 64-frame blocks, with `extra` events (at their frames from the
// start, in order) for it: the left side.
std::vector<float> play(ModuleProcessor& p, int note, uint32_t frames, const Values& values, uint32_t block = 64,
                        const std::vector<Event>& extra = {}) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = paramIndex(d, id);
        if (k >= 0) params[static_cast<size_t>(k)].value = v;
    }
    std::vector<float> out(frames);
    std::vector<float> l(block), r(block);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, block};
    for (uint32_t start = 0; start < frames; start += block) {
        const uint32_t n = std::min(block, frames - start);
        std::vector<Event> in;
        if (start == 0) in.push_back(notes::noteOn(0, 1, static_cast<uint8_t>(note), 1));
        for (Event x : extra)
            if (x.frame >= start && x.frame < start + n) x.frame -= start, in.push_back(x);
        const EventInput ev{in.data(), static_cast<uint32_t>(in.size())};
        ProcessBlock b;
        b.frames = n;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &ev;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p.processPorts(b));
        std::memcpy(out.data() + start, l.data(), n * sizeof(float));
    }
    return out;
}

std::unique_ptr<ModuleProcessor> make(Engine& e) {
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent(kId);
    CHECK(p != nullptr);
    if (p) CHECK(p->activate(48000, 512));
    return p;
}

// Power per bin of a Blackman-Harris-windowed segment (bin k is k * 48000 / n Hz; sidelobes below -92 dB, so a
// weak alias is not hidden under a strong harmonic's leakage).
std::vector<double> spectrum(const std::vector<float>& x, size_t from, size_t n) {
    std::vector<std::complex<double>> d(n);
    for (size_t i = 0; i < n; ++i) {
        const double u = 2.0 * kPi * static_cast<double>(i) / n;
        const double w = 0.35875 - 0.48829 * std::cos(u) + 0.14128 * std::cos(2 * u) - 0.01168 * std::cos(3 * u);
        d[i] = w * x[from + i];
    }
    analysis::fft(d, false);
    std::vector<double> p(n / 2);
    for (size_t k = 0; k < n / 2; ++k) p[k] = std::norm(d[k]);
    return p;
}

// The power between the harmonics of f0 (more than 40 Hz from every one: aliases land there) over the power at
// them, below 20 kHz.
double inharmonic(const std::vector<double>& sp, double f0, size_t n) {
    const double binHz = 48000.0 / n;
    double on = 1e-30, off = 0.0;
    for (size_t k = 1; k < sp.size(); ++k) {
        const double hz = k * binHz;
        if (hz > 20000.0) break;
        const double h = std::round(hz / f0), d = std::fabs(hz - h * f0);
        if (h >= 1 && d <= 40.0) on += sp[k];
        else if (d > 40.0) off += sp[k];
    }
    return off / on;
}

// A 16-bit mono WAV of `samples` (-1..1) at 48 kHz.
std::vector<uint8_t> wav(const std::vector<float>& samples) {
    std::vector<uint8_t> b;
    auto u32 = [&](uint32_t v) { for (int k = 0; k < 4; ++k) b.push_back(static_cast<uint8_t>(v >> (8 * k))); };
    auto u16 = [&](uint16_t v) { b.push_back(static_cast<uint8_t>(v)), b.push_back(static_cast<uint8_t>(v >> 8)); };
    const uint32_t data = static_cast<uint32_t>(samples.size() * 2);
    b.insert(b.end(), {'R', 'I', 'F', 'F'});
    u32(36 + data);
    b.insert(b.end(), {'W', 'A', 'V', 'E', 'f', 'm', 't', ' '});
    u32(16), u16(1), u16(1), u32(48000), u32(96000), u16(2), u16(16);
    b.insert(b.end(), {'d', 'a', 't', 'a'});
    u32(data);
    for (const float v : samples) u16(static_cast<uint16_t>(static_cast<int16_t>(std::lround(std::clamp(v, -1.0f, 1.0f) * 32767.0f))));
    return b;
}

// The import form of the user wavetable: "CWTI", how to cut it (0: 2048-sample frames), then the WAV.
std::vector<uint8_t> import(const std::vector<uint8_t>& file, uint32_t split) {
    std::vector<uint8_t> b = {'C', 'W', 'T', 'I'};
    for (int k = 0; k < 4; ++k) b.push_back(static_cast<uint8_t>(split >> (8 * k)));
    b.insert(b.end(), file.begin(), file.end());
    return b;
}

// Two 2048-sample frames: a sine, then a square (odd harmonics), at half scale.
std::vector<float> sineThenSquare() {
    std::vector<float> s(4096);
    for (int i = 0; i < 2048; ++i) {
        s[static_cast<size_t>(i)] = static_cast<float>(0.5 * std::sin(2 * kPi * i / 2048));
        s[static_cast<size_t>(2048 + i)] = i < 1024 ? 0.5f : -0.5f;
    }
    return s;
}

std::vector<uint8_t> saved(const ModuleProcessor& p) {
    std::vector<uint8_t> out(p.descriptor().maxStateBytes);
    uint32_t written = 0;
    CHECK(p.saveState(out.data(), static_cast<uint32_t>(out.size()), written));
    out.resize(written);
    return out;
}

uint32_t le32(const uint8_t* p) { return p[0] | (p[1] << 8) | (p[2] << 16) | (static_cast<uint32_t>(p[3]) << 24); }

// Every sample finite, no subnormal, the peak within `most`.
void checkSane(const std::vector<float>& x, float most, const std::string& what) {
    float peak = 0.0f;
    for (const float v : x) {
        if (!std::isfinite(v)) return cawtest::fail(__FILE__, __LINE__, what + ": a sample is not finite");
        if (v != 0.0f && std::fabs(v) < 1.17549435e-38f) return cawtest::fail(__FILE__, __LINE__, what + ": a subnormal sample");
        peak = std::max(peak, std::fabs(v));
    }
    if (!(peak <= most)) cawtest::fail(__FILE__, __LINE__, what + ": peak " + std::to_string(peak));
}

}  // namespace

TEST(the_flagship_warps_stay_finite_bounded_and_free_of_subnormals) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // Every warp, light and full, on a wide 7-copy saw stack at a low and a very high note; Osc FM hears osc 3.
    for (int warp = 1; warp <= 7; ++warp)
        for (const double amount : {0.3, 1.0})
            for (const int note : {28, 108}) {
                p->reset();
                const std::vector<float> x = play(*p, note, 9600, {{"osc1_warp", warp}, {"osc1_warp_amt", amount}, {"osc1_unison", 7},
                    {"osc1_fm_ratio", 16}, {"osc3_on", 1}, {"osc3_unison", 5}, {"osc3_octave", 3}, {"fx_reverb_on", 0}});
                checkSane(x, 4.0f, "warp " + std::to_string(warp) + " amount " + std::to_string(amount) + " note " + std::to_string(note));
            }
}

TEST(the_flagship_fm_fold_and_osc_fm_warps_render_the_same_bits_at_any_block_size) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // Osc FM all round the ring (osc 1 hears osc 3 a period late), FM on osc 3 and fold on osc 2 feeding it.
    const Values v = {{"osc1_warp", 7}, {"osc1_warp_amt", 0.5}, {"osc2_on", 1}, {"osc2_warp", 6}, {"osc2_warp_amt", 0.7},
                      {"osc2_unison", 3}, {"osc3_on", 1}, {"osc3_warp", 5}, {"osc3_warp_amt", 0.4}, {"osc3_fm_ratio", 3},
                      {"osc2_dest", 3}, {"osc3_dest", 1}};
    std::vector<float> runs[3];
    const uint32_t blocks[3] = {64, 37, 1};
    for (int k = 0; k < 3; ++k) {
        p->reset();
        runs[k] = play(*p, 50, 9600, v, blocks[k]);
    }
    CHECK(runs[0] == runs[1]);
    CHECK(runs[0] == runs[2]);
    checkSane(runs[0], 4.0f, "the ring");
}

TEST(the_flagship_fm_fold_and_osc_fm_warps_keep_their_aliases_down) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // A sine (Classic, frame 0) at A6 (1760 Hz, about 13 harmonics below Nyquist): every partial a warp makes at a
    // whole ratio is a harmonic, and what folds back over Nyquist lands 480 Hz off the harmonics (48000 mod 1760).
    auto measure = [&](const Values& v) {
        p->reset();
        const std::vector<float> x = play(*p, 93, 8000 + 16384, plain(v));
        return inharmonic(spectrum(x, 8000, 16384), 1760.0, 16384);
    };
    // The reference: the plain sine, whose only inharmonic power is the table's interpolation images.
    const double clean = measure({{"osc1_table", 4}});
    CHECK(clean < 1e-6);
    const double fm = measure({{"osc1_table", 4}, {"osc1_warp", 5}, {"osc1_warp_amt", 1.0}, {"osc1_fm_ratio", 2}});
    // The fold at full drive (a sine folded about 8 times reaches far past Nyquist: drawn naively at the base
    // rate, its aliases come within about 33 dB of the harmonics: the reference below). The fold is a hybrid
    // (#197, owner 2026-11-13): ADAA at the sample rate for most notes, 2x oversampled above a crossover that
    // falls with the drive. A6 at full drive is above it, and must be at least as clean as the 2x design before
    // #197 (about -63 dB; ADAA alone gave -39). An octave lower it is below (ADAA, about -67 dB; the old 2x -62).
    // At 0.6 of the drive the crossover is near D6 (with the bend range), so A6 is 2x there too (about -80 dB;
    // the old 2x -73, ADAA alone -74). Measured 2026-11-13, docs/engine-performance.md.
    const double fold = measure({{"osc1_table", 4}, {"osc1_warp", 6}, {"osc1_warp_amt", 1.0}});
    const double foldOctaveDown = [&] {
        p->reset();
        const std::vector<float> x = play(*p, 81, 8000 + 16384, plain({{"osc1_table", 4}, {"osc1_warp", 6}, {"osc1_warp_amt", 1.0}}));
        return inharmonic(spectrum(x, 8000, 16384), 880.0, 16384);
    }();
    const double foldLighter = measure({{"osc1_table", 4}, {"osc1_warp", 6}, {"osc1_warp_amt", 0.6}});
    // A7 at full drive, the top of the measured range (2x: about -56 dB; the old 2x -55, ADAA alone -7).
    const double foldTop = [&] {
        p->reset();
        const std::vector<float> x = play(*p, 105, 8000 + 16384, plain({{"osc1_table", 4}, {"osc1_warp", 6}, {"osc1_warp_amt", 1.0}}));
        return inharmonic(spectrum(x, 8000, 16384), 3520.0, 16384);
    }();
    // Osc FM from osc 3, a sine an octave up, at level 0 (heard only as the modulator).
    const double osc = measure({{"osc1_table", 4}, {"osc1_warp", 7}, {"osc1_warp_amt", 0.6}, {"osc3_on", 1}, {"osc3_table", 4},
                                {"osc3_frame", 0}, {"osc3_unison", 1}, {"osc3_level", 0}, {"osc3_octave", 1}, {"osc3_phase_rand", 0}});
    CHECK(fm < 1e-6);    // below -60 dB (measured 2026-11-11: about -80 dB)
    CHECK(fold < 1e-6);            // below -60 dB (about -69 dB)
    CHECK(foldOctaveDown < 3e-7);  // below -65 dB (about -67 dB)
    CHECK(foldLighter < 1e-7);     // below -70 dB (about -80 dB)
    CHECK(foldTop < 1e-5);         // below -50 dB (about -56 dB)
    CHECK(osc < 1e-4);   // below -40 dB (about -51 dB)
    // The same fold drawn naively (each sample folded once, no anti-aliasing, the full table), measured here as
    // the reference the anti-aliased warp must beat.
    {
        std::vector<float> naive(8000 + 16384);
        const double drive = 8.0, f0 = 1760.0;
        // The Classic table's full-scale sine, folded as the warp folds it.
        for (size_t i = 0; i < naive.size(); ++i) {
            const double v = std::sin(2 * kPi * f0 * static_cast<double>(i) / 48000.0);
            naive[i] = static_cast<float>(std::sin(v * drive * kPi / 2.0));
        }
        const double reference = inharmonic(spectrum(naive, 8000, 16384), f0, 16384);
        CHECK(reference > 1e-4);
        CHECK(fold < 1e-3 * reference);  // 30 dB better at least (about 36 dB)
    }
    // Osc FM puts sidebands on the harmonics: with the modulator an octave up, the third harmonic (1 +- 2) is there.
    {
        p->reset();
        const std::vector<float> x = play(*p, 57, 24000, plain({{"osc1_table", 4}, {"osc1_warp", 7}, {"osc1_warp_amt", 0.6},
            {"osc3_on", 1}, {"osc3_table", 4}, {"osc3_frame", 0}, {"osc3_unison", 1}, {"osc3_level", 0}, {"osc3_octave", 1}}));
        const std::vector<double> sp = spectrum(x, 8000, 8192);
        auto at = [&](double hz) {
            double best = 0;
            for (int k = static_cast<int>(hz / (48000.0 / 8192)) - 2; k <= static_cast<int>(hz / (48000.0 / 8192)) + 2; ++k)
                best = std::max(best, sp[static_cast<size_t>(k)]);
            return best;
        };
        CHECK(at(660) > 1e-3 * at(220));
        // With osc 3 off there is nothing to hear: no sidebands.
        p->reset();
        const std::vector<float> y = play(*p, 57, 24000, plain({{"osc1_table", 4}, {"osc1_warp", 7}, {"osc1_warp_amt", 0.6}}));
        const std::vector<double> sq = spectrum(y, 8000, 8192);
        CHECK(sq[static_cast<size_t>(660 / (48000.0 / 8192))] < 1e-6 * sq[static_cast<size_t>(220 / (48000.0 / 8192))]);
    }
}

TEST(the_flagship_fold_keeps_its_path_through_a_bend_across_the_crossover_without_a_click) {
    Engine e(48000);
    std::atomic<int> quality{kQualityNormal};  // read by the flagship while it plays (as an Engine's)
    std::unique_ptr<ModuleProcessor> p;
    {
        const BuildingQuality building(&quality);
        p = make(e);
    }
    if (!p) return;
    // The hybrid fold (#197) chooses ADAA or 2x for a note when it starts; a bend across the crossover (about A#5 at
    // full drive with the default bend range) never switches it. F#5 (ADAA) bent up an octave, and F#6 (2x) bent down one, over a quarter of a
    // second (a pitch every 64 frames), in both fold modes.
    auto bend = [](double from, double to) {
        std::vector<Event> pitch;
        for (uint32_t k = 0; k <= 192; ++k)
            pitch.push_back(notes::notePitch(4800 + 64 * k, 1, static_cast<uint8_t>(from), from + (to - from) * k / 192.0));
        return pitch;
    };
    for (const double mode : {0.0, 1.0}) {
        const Values v = plain({{"osc1_table", 4}, {"osc1_warp", 6}, {"osc1_warp_amt", 1.0}, {"osc1_fold_mode", mode}});
        auto run = [&](int q, int note, const std::vector<Event>& events, double bendRange = 2) {
            quality.store(q);
            p->reset();
            Values w = v;
            w.push_back({"bend_range", bendRange});
            return play(*p, note, 24000, w, 64, events);
        };
        // Up: the note stays on ADAA, which Eco plays at every pitch: the same bits as Eco's.
        const std::vector<float> up = run(kQualityNormal, 78, bend(78, 90));
        CHECK(up == run(kQualityEco, 78, bend(78, 90)));
        // Down: the note stays on 2x (not Eco's ADAA), as a note does that a 4-octave bend range puts on 2x from
        // its start (the range moves nothing else here): the same bits.
        const std::vector<float> down = run(kQualityNormal, 90, bend(90, 78));
        CHECK(down != run(kQualityEco, 90, bend(90, 78)));
        CHECK(down == run(kQualityNormal, 90, bend(90, 78), 48));
        // The bits above are the proof that nothing switches. And no click: no step past the largest of the
        // steady note at the bend's top (going up the steps grow with the pitch: held after it; going down, held
        // before it). (A switch mid-note would be a timbre change more than a step: the 2x path keeps more of the
        // highest partials than ADAA, whose mean over a sample is a gentle low-pass.)
        auto largestStep = [](const std::vector<float>& x, size_t from, size_t to) {
            double most = 0;
            for (size_t i = from; i < to; ++i) most = std::max(most, static_cast<double>(std::fabs(x[i] - x[i - 1])));
            return most;
        };
        CHECK(largestStep(up, 4800, 17200) <= 1.05 * largestStep(up, 17200, 24000));
        CHECK(largestStep(down, 4800, 24000) <= 1.05 * largestStep(down, 2400, 4800));
        checkSane(up, 4.0f, "the bend up");
        checkSane(down, 4.0f, "the bend down");
    }
}

TEST(the_flagship_2x_fold_renders_the_same_bits_at_any_block_size_in_both_modes) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // A6 at 0.9 drive (the 2x path): osc 1 a spread 5-copy stack, per copy and whole, played and heard by osc 2's
    // Osc FM (the mono path); osc 3 a centred whole stack (one decimator for both sides).
    for (const double mode : {0.0, 1.0}) {
        const Values v = {{"osc1_warp", 6}, {"osc1_warp_amt", 0.9}, {"osc1_unison", 5}, {"osc1_spread", 1}, {"osc1_fold_mode", mode},
                          {"osc2_on", 1}, {"osc2_warp", 7}, {"osc2_warp_amt", 0.5}, {"osc2_level", 0.5},
                          {"osc3_on", 1}, {"osc3_warp", 6}, {"osc3_warp_amt", 0.9}, {"osc3_unison", 3}, {"osc3_spread", 0},
                          {"osc3_fold_mode", 1}, {"osc3_level", 0.3}, {"osc3_frame", 0.6}};
        std::vector<float> runs[3];
        const uint32_t blocks[3] = {64, 37, 1};
        for (int k = 0; k < 3; ++k) {
            p->reset();
            runs[k] = play(*p, 93, 9600, v, blocks[k]);
        }
        CHECK(runs[0] == runs[1]);
        CHECK(runs[0] == runs[2]);
        checkSane(runs[0], 4.0f, "the 2x fold");
    }
}

TEST(the_flagship_fold_mode_is_per_copy_unless_set_and_whole_stack_folds_the_stacks_sum) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // #197: a project or preset without osc1_fold_mode plays Per copy.
    const Values stack = {{"osc1_warp", 6}, {"osc1_warp_amt", 0.7}, {"osc1_unison", 7}, {"fx_reverb_on", 0}};
    auto with = [&](Values v, Values extra) {
        for (auto& x : extra) v.push_back(x);
        p->reset();
        return play(*p, 45, 9600, v);
    };
    const std::vector<float> unset = with(stack, {}), perCopy = with(stack, {{"osc1_fold_mode", 0}});
    CHECK(unset == perCopy);
    // Whole stack folds the sum of the 7 copies (a rougher sound): not the same signal, finite and bounded.
    const std::vector<float> whole = with(stack, {{"osc1_fold_mode", 1}});
    double diff = 0;
    for (size_t i = 0; i < whole.size(); ++i) diff = std::max(diff, static_cast<double>(std::fabs(whole[i] - perCopy[i])));
    CHECK(diff > 0.01);
    checkSane(whole, 4.0f, "whole stack");
    // One centred copy: its sum is itself, so the two modes are the same bits.
    p->reset();
    const std::vector<float> one = play(*p, 57, 4800, plain({{"osc1_warp", 6}, {"osc1_warp_amt", 0.8}}));
    p->reset();
    const std::vector<float> oneWhole = play(*p, 57, 4800, plain({{"osc1_warp", 6}, {"osc1_warp_amt", 0.8}, {"osc1_fold_mode", 1}}));
    CHECK(one == oneWhole);
    // The level comes after the fold in both modes: half the level is half the signal, not a lighter fold (no
    // filter: the ladder is not linear).
    for (const double mode : {0.0, 1.0}) {
        const std::vector<float> full = with(stack, {{"osc1_fold_mode", mode}, {"osc1_level", 0.8}, {"flt1_on", 0}});
        const std::vector<float> half = with(stack, {{"osc1_fold_mode", mode}, {"osc1_level", 0.4}, {"flt1_on", 0}});
        double worst = 0, peak = 0;
        for (size_t i = 0; i < full.size(); ++i) {
            worst = std::max(worst, std::fabs(0.5 * full[i] - half[i]));
            peak = std::max(peak, static_cast<double>(std::fabs(full[i])));
        }
        CHECK(peak > 0.05);
        CHECK(worst < 1e-5 * peak);
    }
}

TEST(the_flagship_whole_stack_fold_renders_the_same_bits_at_any_block_size_spread_and_heard_by_osc_fm) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // osc 3 a spread 5-copy stack folded whole, heard and played; osc 1's Osc FM hears it (the mono path).
    const Values v = {{"osc1_warp", 7}, {"osc1_warp_amt", 0.5}, {"osc3_on", 1}, {"osc3_warp", 6}, {"osc3_warp_amt", 0.9},
                      {"osc3_unison", 5}, {"osc3_spread", 1}, {"osc3_fold_mode", 1}, {"osc3_level", 0.5}, {"osc3_frame", 0.6}};
    std::vector<float> runs[3];
    const uint32_t blocks[3] = {64, 37, 1};
    for (int k = 0; k < 3; ++k) {
        p->reset();
        runs[k] = play(*p, 50, 9600, v, blocks[k]);
    }
    CHECK(runs[0] == runs[1]);
    CHECK(runs[0] == runs[2]);
    checkSane(runs[0], 4.0f, "whole stack, spread");
}

TEST(the_flagship_fold_stays_smooth_where_samples_are_nearly_equal) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // ADAA divides by the step from one sample to the next; at 8 Hz (MIDI 0) the steps are about 1e-3 and many
    // round to almost nothing. The fold there is the plain fold of a slow sine: finite, no spikes (the largest
    // step from a sample to the next is about drive pi / 2 x the sine's), and as loud as the same fold an octave
    // up (a slow sine folded 8 times is the same shape slower).
    for (const double mode : {0.0, 1.0}) {
        auto run = [&](int note) {
            p->reset();
            return play(*p, note, 48000, plain({{"osc1_warp", 6}, {"osc1_warp_amt", 1.0}, {"osc1_fold_mode", mode}}));
        };
        const std::vector<float> slow = run(0), faster = run(12);
        checkSane(slow, 4.0f, "the fold at 8 Hz");
        double step = 0, a = 0, b = 0;
        for (size_t i = 24000; i < slow.size(); ++i) {
            step = std::max(step, static_cast<double>(std::fabs(slow[i] - slow[i - 1])));
            a += static_cast<double>(slow[i]) * slow[i];
            b += static_cast<double>(faster[i]) * faster[i];
        }
        CHECK(step < 0.02);
        CHECK(a > 0.0 && std::fabs(10.0 * std::log10(a / b)) < 0.5);
    }
}

TEST(the_flagship_takes_a_user_wavetable_as_its_state_and_saves_it_back) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    // No table: nothing saved, and User plays a sine.
    CHECK(saved(*p).empty());
    const Values user = {{"osc1_table", 5}, {"osc1_frame", 0.0}};
    checkSane(play(*p, 57, 4800, plain(user)), 2.0f, "the empty user table");
    // An import of two 2048-sample frames (the usual single-cycle export) becomes its own form: "CWT1", 2 frames,
    // 2048 samples each, 16-bit, normalised.
    const std::vector<uint8_t> file = wav(sineThenSquare());
    CHECK(p->loadState(import(file, 0).data(), static_cast<uint32_t>(import(file, 0).size()), 1));
    const std::vector<uint8_t> own = saved(*p);
    CHECK_EQ(own.size(), 12u + 2u * 2048u * 2u);
    if (own.size() < 12) return;
    CHECK_EQ(le32(own.data()), 0x31545743u);
    CHECK_EQ(le32(own.data() + 4), 2u);
    CHECK_EQ(le32(own.data() + 8), 2048u);
    int16_t peak = 0;
    for (size_t i = 12; i + 1 < own.size(); i += 2) peak = std::max<int16_t>(peak, static_cast<int16_t>(own[i] | (own[i + 1] << 8)));
    CHECK_EQ(peak, 32767);  // half scale in, full scale kept
    // Frame 0 plays a sine, frame 1 a square: its third harmonic at about a third of the fundamental.
    auto third = [&](double frame) {
        p->reset();
        const std::vector<float> x = play(*p, 57, 24000, plain({{"osc1_table", 5}, {"osc1_frame", frame}}));
        const std::vector<double> sp = spectrum(x, 8000, 8192);
        return std::sqrt(sp[static_cast<size_t>(std::lround(660 / (48000.0 / 8192)))] /
                         sp[static_cast<size_t>(std::lround(220 / (48000.0 / 8192)))]);
    };
    CHECK(third(0.0) < 1e-3);
    CHECK_NEAR(third(1.0), 1.0 / 3.0, 0.08);
    // Its own form loads back into another instance and plays the same bits.
    std::unique_ptr<ModuleProcessor> q = make(e);
    if (!q) return;
    CHECK(q->loadState(own.data(), static_cast<uint32_t>(own.size()), 1));
    CHECK(saved(*q) == own);
    p->reset();
    q->reset();
    const Values morph = plain({{"osc1_table", 5}, {"osc1_frame", 0.4}});
    CHECK(play(*p, 60, 4800, morph) == play(*q, 60, 4800, morph));
    // Cut by a frame count: 3000 samples into 3 frames; a short single cycle (600 samples) is one frame.
    std::vector<float> three(3000), one(600);
    for (size_t i = 0; i < three.size(); ++i) three[i] = static_cast<float>(std::sin(2 * kPi * (i % 1000) / 1000.0 * (1 + i / 1000)));
    for (size_t i = 0; i < one.size(); ++i) one[i] = static_cast<float>(std::sin(2 * kPi * i / 600.0));
    CHECK(q->loadState(import(wav(three), 3).data(), static_cast<uint32_t>(import(wav(three), 3).size()), 1));
    CHECK_EQ(le32(saved(*q).data() + 4), 3u);
    CHECK(q->loadState(import(wav(one), 0).data(), static_cast<uint32_t>(import(wav(one), 0).size()), 1));
    CHECK_EQ(le32(saved(*q).data() + 4), 1u);
    checkSane(play(*q, 57, 4800, plain(user)), 2.0f, "a one-cycle table");
    // An empty state takes the table away.
    CHECK(q->loadState(nullptr, 0, 1));
    CHECK(saved(*q).empty());
}

TEST(the_flagship_refuses_a_bad_user_wavetable_whole_and_keeps_its_table) {
    Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = make(e);
    if (!p) return;
    const std::vector<uint8_t> good = import(wav(sineThenSquare()), 0);
    CHECK(p->loadState(good.data(), static_cast<uint32_t>(good.size()), 1));
    const std::vector<uint8_t> kept = saved(*p);
    auto refused = [&](std::vector<uint8_t> b, uint32_t version, const char* what) {
        if (p->loadState(b.data(), static_cast<uint32_t>(b.size()), version))
            cawtest::fail(__FILE__, __LINE__, std::string("took ") + what);
        if (saved(*p) != kept) cawtest::fail(__FILE__, __LINE__, std::string("a refused state changed the table: ") + what);
    };
    refused(kept, 2, "another state version");
    refused({'C', 'W', 'T', '1'}, 1, "a short header");
    refused({'N', 'O', 'P', 'E', 0, 0, 0, 0, 0, 8, 0, 0}, 1, "an unknown form");
    std::vector<uint8_t> b = kept;
    b.pop_back();
    refused(b, 1, "a truncated table");
    b = kept;
    b.push_back(0);
    refused(b, 1, "a table with extra bytes");
    b = kept;
    b[4] = 0;
    refused(b, 1, "zero frames");
    b = kept;
    b[4] = 1, b[5] = 1;  // 257 frames
    refused(b, 1, "too many frames");
    b = kept;
    b[9] = 4;  // a 1024-sample frame size
    refused(b, 1, "another frame size");
    refused(import(wav(sineThenSquare()), 257), 1, "a split into 257 frames");
    refused(import(wav(std::vector<float>(1000, 0.5f)), 100), 1, "frames under 16 samples");
    refused(import({'R', 'I', 'F', 'F', 0, 0, 0, 0, 'W', 'A', 'V', 'E'}, 0), 1, "a WAV with no data");
    refused(import(wav(std::vector<float>(4096, 0.0f)), 0), 1, "a silent file");
    refused(import(wav(std::vector<float>(8, 0.5f)), 0), 1, "an 8-sample file");
    refused(import(wav(std::vector<float>(257 * 2048, 0.5f)), 0), 1, "257 frames of 2048");
    refused(import(std::vector<uint8_t>((8u << 20) + 1, 0), 0), 1, "a WAV over 8 MiB");
    // The Engine: a state for a playing flagship is taken and saved back; a bad one changes nothing.
    ProjectSpec spec;
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.hasInstrument = true;
    l.instrument.id = kId;
    spec.layers.push_back(l);
    CHECK(e.setProject(spec).find("\"ok\":true") != std::string::npos);
    CHECK(!e.setComponentState("t", Engine::kInstrumentIndex, b.data(), b.size(), 1));
    CHECK(e.componentStatesJson("t").find("\"state\"") == std::string::npos ||
          e.componentStatesJson("t").find("\"state\":\"\"") != std::string::npos);
    CHECK(e.setComponentState("t", Engine::kInstrumentIndex, good.data(), good.size(), 1));
    CHECK(e.componentStatesJson("t").find("\"state\":\"Q1dUMQ") != std::string::npos);  // base64 of "CWT1"
}
