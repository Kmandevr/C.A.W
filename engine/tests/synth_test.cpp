// Synth tests: wavetables (band-limiting, determinism, frames) and the wt oscillator (pitch, aliasing, morph, unison).
#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

#include "compile.h"
#include "detmath.h"
#include "engine.h"
#include "project.h"
#include "synth.h"
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

const std::string kPatch = "---\ncaw: 1\nkind: synth\nname: Test\n---\n";

std::string patchError(const std::string& body) { return translateSynth(kPatch + body).error; }

// Plays a synth module (plus any extra modules) from a held C3 note for `frames` samples; returns the left channel.
std::vector<double> playSynth(const std::string& patch, int64_t frames, std::vector<ModuleSpec> extra = {},
                              std::string* result = nullptr, Engine* reuse = nullptr) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 4;
    p.master = 1.0;
    p.modules.push_back({"s", patch, {}});
    p.modules.push_back({"p", "---\nkind: pattern\n---\n0 C3 4\n", {}});
    for (ModuleSpec& m : extra) p.modules.push_back(m);
    LayerSpec l;
    l.id = "l";
    l.chain = {"s"};
    l.pattern = "p";
    l.volume = 1.0;
    p.layers = {l};
    Engine local(48000);
    Engine& e = reuse ? *reuse : local;
    e.setMasterBypass(true);
    const std::string res = e.setProject(p);
    if (result) *result = res;
    e.play();
    std::vector<float> lf(static_cast<size_t>(frames)), rf(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += 64)
        e.process(lf.data() + i, rf.data() + i, static_cast<int>(std::min<int64_t>(64, frames - i)));
    return std::vector<double>(lf.begin(), lf.end());
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

TEST(synth_patches_report_errors_at_their_line) {
    CHECK(patchError("osc a level 2\n").find("line 6, col 13: level must be 0 to 1, not 2") == 0);
    CHECK(patchError("osc a\nosc d\n").find("line 7, col 1: osc needs its name: a, b or c") == 0);
    CHECK(patchError("osc a table nope\n").find("unknown table 'nope'") != std::string::npos);
    CHECK(patchError("osc a wobble 3\n").find("unknown setting 'wobble'") != std::string::npos);
    CHECK(patchError("filter 1 lowpass cutoff 5\n").find("cutoff must be 20 to 20000") != std::string::npos);
    CHECK(patchError("lfo 5 rate 2\\n").find("lfo needs its number") != std::string::npos);
    CHECK(patchError("mod env 1 -> filter 1 cutoff 0.4\\n").find("env 1 is the amplitude envelope") != std::string::npos);
    CHECK(patchError("macro 5 Bright 0.5\\n").find("macro syntax") != std::string::npos);
    CHECK(patchError("macro 1 Bad! 0.5\\n").find("macro name must use only") != std::string::npos);
    CHECK(translateSynth(kPatch + "mod lfo 1 -> volume 0.5\\n").error.find("lfo1 is used as a modulator") != std::string::npos);
    CHECK(translateSynth(kPatch + "mod macro 1 -> osc b pos 0.5\\n").error.find("destination oscillator is off") != std::string::npos);
    CHECK(patchError("bananas\n").find("unknown line 'bananas'") != std::string::npos);
    CHECK(patchError("voices 40\n").find("voices must be 1 to 32") != std::string::npos);
    CHECK(translateSynth("---\nkind: generator\n---\nosc a\n").error.find("kind: synth") != std::string::npos);
    // Comments and blank lines are fine; a patch with no sources gets one saw.
    SynthResult ok = translateSynth(kPatch + "// just a comment\n\nvoices 4 // four notes\n");
    CHECK(ok.ok);
    CHECK(ok.generator.find("wt(table.saw") != std::string::npos);
    CHECK(ok.generator.find("voices: 4") != std::string::npos);
}


TEST(synth_supports_three_envelopes_four_lfos_macros_and_modulation_routes) {
    const std::string patch = kPatch +
        "osc a table saw\\n"
        "filter 1 lowpass cutoff 1200\\n"
        "env 2 attack 0.1 decay 0.4 sustain 0.3 release 0.2\\n"
        "env 3 attack 0.01 decay 0.2 sustain 0.8 release 0.3\\n"
        "lfo 1 shape sine rate 2 phase 0.25\\n"
        "lfo 2 shape tri rate 1/4\\n"
        "lfo 3 shape saw rate 4\\n"
        "lfo 4 shape random rate 0.5\\n"
        "macro 1 Bright 0.5\\n"
        "macro 2 Width 0.7\\n"
        "mod env 2 -> filter 1 cutoff 0.4\\n"
        "mod lfo 1 -> osc a pos 0.3\\n"
        "mod macro 1 -> osc a pitch 0.2\\n"
        "mod vel -> volume 0.5\\n";
    SynthResult translated = translateSynth(patch);
    CHECK(translated.ok);
    if (!translated.ok) return;
    CHECK(translated.generator.find("let env2 = env.adsr") != std::string::npos);
    CHECK(translated.generator.find("let env3 = env.adsr") != std::string::npos);
    CHECK(translated.generator.find("lfo.sine") != std::string::npos);
    CHECK(translated.generator.find("lfo.tri") != std::string::npos);
    CHECK(translated.generator.find("lfo.saw") != std::string::npos);
    CHECK(translated.generator.find("lfo.random") != std::string::npos);
    CHECK(translated.generator.find("macro1") != std::string::npos);
    CHECK(translated.generator.find("macro2") != std::string::npos);
    CHECK(translated.generator.find("env2 * 0.4") != std::string::npos);
    CHECK(translated.generator.find("lfo1 * 0.3") != std::string::npos);
    CHECK(translated.generator.find("macro1 * 0.2") != std::string::npos);
    CHECK(translated.generator.find("vel * 0.5") != std::string::npos);
    CHECK(compileModule(translated.generator).program != nullptr);
}

TEST(a_synth_patch_compiles_to_a_voice_with_its_effects) {
    CompileResult r = compileModule(kPatch +
                                    "osc a table basic unison 5 detune 0.3\nsub level 0.3\nfilter 1 lowpass cutoff 900\n"
                                    "fx drive amount 0.5\nfx crushfx\nfx reverb mix 0.4\n");
    CHECK(r.program != nullptr);
    if (!r.program) return;
    CHECK(r.program->synth);
    CHECK_EQ(r.program->voices, 8);
    CHECK_EQ(r.program->synthFx.size(), size_t{3});
    CHECK(r.program->synthFx[1] == "@crushfx");
    bool fxParam = false;
    for (const ParamDef& d : r.program->params) fxParam = fxParam || (d.name == "reverb_1_mix" && d.header == "Effects");
    CHECK(fxParam);
    CHECK(describeProgram(*r.program).find("\"kind\":\"synth\"") != std::string::npos);
    // The same patch always gives the same code.
    CHECK(translateSynth(kPatch + "osc a\nfx reverb\n").generator == translateSynth(kPatch + "osc a\nfx reverb\n").generator);
}

TEST(a_synth_plays_notes_through_its_effects_and_project_modules) {
    const std::string patch = kPatch + "osc a table saw\nenv 1 attack 0.001 release 0.05\n";
    auto dry = playSynth(patch, 48000);
    CHECK(rms(std::vector<double>(dry.begin() + 1000, dry.begin() + 20000)) > 0.05);
    // The note lasts 4 steps (24000 samples at 120 BPM); without effects it is silent soon after.
    CHECK(rms(std::vector<double>(dry.begin() + 30000, dry.end())) < 1e-4);
    // A delay keeps sounding after the note ends.
    auto wet = playSynth(patch + "fx delay time 0.25 feedback 0.5 mix 0.5\n", 48000);
    CHECK(rms(std::vector<double>(wet.begin() + 30000, wet.end())) > 0.01);
    // A project effect module named in an fx line runs where its line is: this one silences everything.
    auto muted = playSynth(patch + "fx silence\n", 48000, {{"m", "---\nkind: effect\nname: silence\n---\nin * 0\n", {}}});
    CHECK(rms(muted) < 1e-9);
    // A missing one is a warning, and the synth still plays.
    std::string res;
    auto still = playSynth(patch + "fx nothere\n", 24000, {}, &res);
    CHECK(res.find("no effect module called 'nothere'") != std::string::npos);
    CHECK(rms(still) > 0.05);
}

TEST(setting_a_synth_param_reaches_its_voice_and_its_effects) {
    const std::string patch = kPatch + "osc a table saw\nenv 1 attack 0.001\nfx drive amount 0\n";
    Engine e(48000);
    auto before = playSynth(patch, 12000, {}, nullptr, &e);
    e.setParam("s", "volume", 0.0);
    std::vector<float> lf(4800), rf(4800);
    for (int i = 0; i < 4800; i += 64) e.process(lf.data() + i, rf.data() + i, 64);
    double tail = 0;
    for (int i = 2400; i < 4800; ++i) tail = std::max(tail, std::fabs(static_cast<double>(lf[static_cast<size_t>(i)])));
    CHECK(tail < 1e-6);
    // The effect's param: full drive squashes the saw, so its crest factor (peak over RMS) drops.
    auto crest = [&] {
        for (int i = 0; i < 4800; i += 64) e.process(lf.data() + i, rf.data() + i, 64);
        std::vector<double> seg(lf.begin() + 2400, lf.end());
        double peak = 0;
        for (double v : seg) peak = std::max(peak, std::fabs(v));
        return peak / std::max(1e-12, rms(seg));
    };
    e.setParam("s", "volume", 0.8);
    const double clean = crest();
    e.setParam("s", "drive_1_amount", 1.0);
    const double driven = crest();
    CHECK(clean > 1.3);
    CHECK(driven < clean * 0.9);
    CHECK(rms(before) > 0.0);
}

TEST(a_patch_cannot_grow_the_chain_or_params_past_the_limits) {
    // At most 8 fx lines: more is an error at its line, so a patch can't make the engine build thousands of modules.
    std::string many = kPatch + "osc a\n";
    for (int i = 0; i < 9; ++i) many += (i % 2 ? "fx drive\n" : "fx zz\n");
    CHECK(translateSynth(many).error.find("line 15, col 1: a patch can have at most 8 fx lines") == 0);
    // A full patch with 8 effects stays under the 64-value limit and compiles.
    std::string full = kPatch + "osc a\nosc b\nosc c\nsub\nnoise\nfilter 1 lowpass\nfilter 2 highpass\n";
    for (int i = 0; i < 8; ++i) full += "fx delay\n";
    CompileResult r = compileModule(full);
    CHECK(r.program != nullptr);
    if (r.program) CHECK(r.program->params.size() <= static_cast<size_t>(kMaxSynthParams));
    // Ids with control characters never reach the engine (it names hidden modules with them).
    ProjectSpec p;
    std::string err;
    CHECK(parseProject("{\"caw_project\":1,\"modules\":[{\"id\":\"s\\u001f0\",\"source\":\"t\"},{\"id\":\"ok\",\"source\":\"t\"}]}", p, err));
    CHECK_EQ(p.modules.size(), size_t{1});
}

TEST(effects_are_numbered_across_the_patch_and_mono_patches_steal) {
    // fx delay, a project module, fx delay: two delays with their own params (delay_1, delay_2).
    CompileResult r = compileModule(kPatch + "osc a\nfx delay\nfx mine\nfx delay mix 0.1\n");
    CHECK(r.program != nullptr);
    if (r.program) {
        int d1 = 0, d2 = 0;
        for (const ParamDef& d : r.program->params) {
            d1 += d.name == "delay_1_mix";
            d2 += d.name == "delay_2_mix";
        }
        CHECK(d1 == 1 && d2 == 1);
        CHECK(r.program->synthFxKeys.size() == 3 && r.program->synthFxKeys[2] == "delay_2");
    }
    // voices 1: a 3-note chord plays one note, not two.
    ProjectSpec p;
    p.bpm = 120;
    p.master = 1.0;
    p.modules.push_back({"s", "---\nmode: float\nvoices: 1\n---\ngate * 0.1\n", {}});
    p.modules.push_back({"p", "---\nkind: pattern\n---\n0 C3,E3,G3 4\n", {}});
    LayerSpec l;
    l.id = "l";
    l.chain = {"s"};
    l.pattern = "p";
    l.volume = 1.0;
    p.layers = {l};
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    std::vector<float> lf(1024), rf(1024);
    for (int i = 0; i < 1024; i += 64) e.process(lf.data() + i, rf.data() + i, 64);
    CHECK_NEAR(lf[500] / std::cos(kPi / 4.0), 0.1, 1e-6);
}


TEST(synth_oscillator_phase_warp_is_exposed_and_changes_the_waveform) {
    const std::string plain = kPatch + "osc a table saw warp 0\n";
    const std::string warped = kPatch + "osc a table saw warp 0.8\n";
    const SynthResult a = translateSynth(plain);
    const SynthResult b = translateSynth(warped);
    CHECK(a.ok);
    CHECK(b.ok);
    CHECK(b.generator.find("a_warp") != std::string::npos);
    CHECK(!translateSynth(kPatch + "osc a warp 1\n").ok);
    const auto dry = playSynth(plain, 4096);
    const auto shaped = playSynth(warped, 4096);
    CHECK_EQ(dry.size(), shaped.size());
    double difference = 0;
    for (size_t i = 0; i < dry.size(); ++i)
        difference = std::max(difference, std::fabs(dry[i] - shaped[i]));
    CHECK(difference > 1e-4);
}
