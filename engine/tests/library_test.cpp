// Standard library tests: envelopes, LFOs, effects, glitch and music helpers, library modules, and the docs check.
#include <cmath>
#include <string>
#include <vector>

#include "compile.h"
#include "detmath.h"
#include "docs.h"
#include "engine.h"
#include "render.h"
#include "test.h"
#include "vm.h"

using namespace caw;

namespace {

// Runs a float-mode module for `blocks` blocks with t = n and returns its raw output.
std::vector<double> runRaw(const std::string& body, int blocks, double bpm = 120, double sr = 48000) {
    CompileResult r = compileModule("---\nmode: float\n---\n" + body);
    if (!r.program) {
        cawtest::fail(__FILE__, __LINE__, "compile failed: " + body + " -> " + r.error);
        return {};
    }
    Instance inst(r.program);
    std::vector<double> out;
    double tb[kBlock], time[kBlock], step[kBlock], zero[kBlock] = {};
    BlockCtx c;
    c.sr = sr;
    c.bpm = bpm;
    for (int b = 0; b < blocks; ++b) {
        for (int i = 0; i < kBlock; ++i) {
            const double n = b * kBlock + i;
            tb[i] = n;
            time[i] = n / sr;
            step[i] = std::floor(n / (60.0 * sr / (bpm * 4)));
        }
        c.n = kBlock;
        for (int v = 0; v < static_cast<int>(Var::Count); ++v) c.vars[v] = zero;
        c.vars[static_cast<int>(Var::T)] = tb;
        c.vars[static_cast<int>(Var::Time)] = time;
        c.vars[static_cast<int>(Var::Step)] = step;
        inst.process(c);
        const double* raw = inst.rawOutput();
        out.insert(out.end(), raw, raw + kBlock);
    }
    return out;
}

double one(const std::string& body) {
    std::vector<double> v = runRaw(body, 1);
    return v.empty() ? -12345 : v[0];
}

}  // namespace

TEST(adsr_holds_and_releases) {
    // Gate on for the first 4800 samples (0.1 s), then off.
    std::vector<double> v = runRaw("env.adsr(t < 4800, 0.01, 0.02, 0.5, 0.05)", 200);
    CHECK_NEAR(v[480], 1.0, 0.01);        // end of the 10 ms attack
    CHECK_NEAR(v[4700], 0.5, 1e-3);       // holding at sustain
    CHECK(v[4800 + 2400] < 0.5 * 0.05);   // 50 ms into release: well below -20 dB
    CHECK(v[4800 + 2400] > 0.0);
}

TEST(lfos_follow_the_tempo) {
    // At 120 BPM a 1-beat LFO completes a cycle every 0.5 s (24000 samples).
    std::vector<double> v = runRaw("lfo.saw(1)", 400);
    CHECK_NEAR(v[0], -1.0, 1e-9);
    CHECK_NEAR(v[12000], 0.0, 1e-9);
    CHECK_NEAR(v[24000], -1.0, 1e-9);
    std::vector<double> r = runRaw("lfo.random(1)", 400);
    CHECK(r[100] == r[23000]);   // stepped: one value per cycle
    CHECK(r[100] != r[24100]);
}

TEST(modulation_helper_applies_signed_depth) {
    CHECK_NEAR(one("util.mod(100, 0.5, 20)"), 110.0, 1e-12);
    CHECK_NEAR(one("util.mod(100, 0.5, -20)"), 90.0, 1e-12);
    CHECK_NEAR(one("util.mod(100, -0.5, 20)"), 90.0, 1e-12);
}

TEST(music_helpers) {
    // Defaults use the project key (A minor): degree 0 = A4 (69 in octave 4 from C4 = 60 + 9).
    CHECK_EQ(one("scale(0)"), 69.0);
    CHECK_EQ(one("scale(2)"), 72.0);       // C5
    CHECK_EQ(one("scale(7)"), 81.0);       // an octave up
    CHECK_EQ(one("scale(-1)"), 67.0);      // G4
    CHECK_EQ(one("scale(2, scale.major, 60)"), 64.0);
    CHECK_EQ(one("quantize(61, scale.major, 60)"), 60.0);  // C# -> C (ties go down)
    CHECK_EQ(one("quantize(63, scale.major, 60)"), 62.0);  // D# -> D
    CHECK_EQ(one("chord(chord.min7, 3, 57)"), 67.0);
    CHECK_EQ(one("chord(chord.maj, 3, 60)"), 72.0);        // past the end climbs an octave
    CHECK_EQ(one("arp(chord.maj, 3, arp.updown, 60)"), 64.0);  // up-down over 3 notes: 60 64 67 64, then again
    CHECK_EQ(one("arp(chord.maj, 4, arp.updown, 60)"), 60.0);
    CHECK_EQ(one("arp(chord.maj, 5, arp.up, 60)"), 67.0);
    // euclid(3, 8): hits at steps 0, 3, 6 (with this formula: 0, 3, 6 -> x..x..x.)
    std::string hits;
    for (int s = 0; s < 8; ++s) hits += one("euclid(3, 8, " + std::to_string(s) + ")") > 0.5 ? 'x' : '.';
    CHECK_EQ(hits, std::string("x..x..x."));
    CHECK_EQ(one("rand(5)"), one("rand(5)"));
    CHECK(one("rand(5)") != one("rand(6)"));
    CHECK(one("randi(5, 4)") >= 0 && one("randi(5, 4)") < 4);
    CHECK_EQ(one("beats(2)"), 1.0);  // 2 beats at 120 BPM
}

TEST(delay_echoes_after_its_time) {
    // An impulse at t = 0 comes back 0.01 s (480 samples) later at the mix level.
    std::vector<double> v = runRaw("fx.delay(t == 0, 0.01, 0, 1)", 20);
    CHECK_NEAR(v[0], 0.0, 1e-12);
    CHECK_NEAR(v[480], 1.0, 1e-12);
    CHECK_NEAR(v[481], 0.0, 1e-12);
}

TEST(effects_and_glitch_tools) {
    CHECK_NEAR(one("fx.drive(1, 5)"), 1.0, 1e-12);
    CHECK_EQ(one("fx.crush(0.3, 2)"), 0.5);
    CHECK_NEAR(one("glitch.mask(0, 0)"), 0.0, 1e-12);
    CHECK_NEAR(one("glitch.wrap(0.5, 3)"), -0.5, 1e-12);  // 1.5 wraps to -0.5
    std::vector<double> h = runRaw("glitch.hold(t, 1000)", 2);
    CHECK_EQ(h[0], 0.0);
    CHECK_EQ(h[47], 0.0);
    CHECK_EQ(h[48], 48.0);  // a new value every 48 samples at 1 kHz
    std::vector<double> st = runRaw("glitch.stutter(t, 1, 0.001)", 3);  // 48-sample loop
    CHECK_EQ(st[47], 47.0);
    CHECK_EQ(st[48], 0.0);
    CHECK_EQ(st[100], 4.0);
    std::vector<double> rv = runRaw("fx.reverb(t == 0, 0.7, 0.3, 1)", 100);
    double tail = 0;
    for (size_t i = 2000; i < rv.size(); ++i) tail = std::fmax(tail, std::fabs(rv[i]));
    CHECK(tail > 1e-4);  // still ringing after 40 ms
}

TEST(library_functions_and_project_libraries) {
    CHECK(compileModule("---\nmode: float\n---\ndrum.kick(step % 4 == 0, 48, 0.3)").program != nullptr);
    CHECK(compileModule("drum.nope(1)").error.find("unknown function 'drum.nope'") != std::string::npos);
    // A project library: its functions are callable as ns.name from other modules.
    const std::string lib = "---\nkind: library\nnamespace: mine\n---\n/// Doubles.\n/// x: anything\n/// example: mine.twice(0.2)\nfn twice(x) = x * 2\n";
    CompileResult l = compileModule(lib);
    CHECK(l.program && l.program->kind == ModuleKind::Library && l.program->ns == "mine");
    CHECK(compileModule("mine.twice(1)").program == nullptr);
    CHECK(compileModule("mine.twice(1)", {{"mine", lib}}).program != nullptr);
    // A library's functions call each other by their full names, and its description lists them that way.
    CompileResult two = compileModule(lib + "fn quad(x) = mine.twice(mine.twice(x))\n");
    CHECK(two.program && two.program->functions.size() == 2 && two.program->functions[1].name == "mine.quad");
    // A project library can't hide a built-in or a built-in library's function.
    CHECK(compileModule("---\nkind: library\nnamespace: env\n---\nfn adsr(x) = x").error.find("'env.adsr' is a built-in name") != std::string::npos);
    CHECK(compileModule("---\nkind: library\nnamespace: drum\n---\nfn kick(x) = x").error.find("'drum.kick' is already defined") != std::string::npos);
    CHECK(compileModule("---\nkind: library\nnamespace: scale\n---\nfn minor(x) = x").error.find("built-in name") != std::string::npos);
    CHECK(compileModule("x", {{"env", "---\nkind: library\nnamespace: env\n---\nfn adsr(x) = x"}}).program == nullptr);
    std::vector<FnDoc> docs = libraryDocs({"", lib});
    CHECK(docs.size() == 1 && docs[0].name == "mine.twice" && docs[0].argDocs[0] == "anything" && docs[0].example == "mine.twice(0.2)");
    // In a project, the library doesn't play, and other modules can call it.
    ProjectSpec p;
    p.master = 1.0;
    p.modules.push_back({"lib", lib, {}});
    p.modules.push_back({"m", "---\nmode: float\n---\nmine.twice(0.2)", {}});
    LayerSpec layer;
    layer.id = "x";
    layer.chain = {"lib", "m"};
    layer.volume = 1.0;
    p.layers = {layer};
    Engine e(48000);
    e.setMasterBypass(true);
    std::string res = e.setProject(p);
    CHECK(res.find("\"ok\":true") != std::string::npos);
    e.play();
    float l0[64], r0[64];
    e.process(l0, r0, 64);
    CHECK_NEAR(l0[63], 0.4 * std::cos(kPi / 4.0), 1e-6);
    RenderResult out;
    CHECK(renderExport(p, ExportOptions{}, out));
}

TEST(params_borrow_the_docs_of_the_arguments_they_feed) {
    CompileResult r = compileModule("---\nmode: float\n---\nparam cut = 800 in 100..4000\nparam mine = 2 \"my own\"\nlpf(saw(110), cut) * mine");
    CHECK(r.program && r.program->params[0].tip == "Hz" && r.program->params[1].tip == "my own");
    CompileResult k = compileModule("---\nmode: float\n---\nparam d = 0.3\ndrum.kick(1, 50, d)");
    CHECK(k.program && k.program->params[0].tip == "seconds until it fades out");
}

TEST(every_function_is_documented_and_its_example_plays) {
    for (const std::string& problem : checkLibrary()) cawtest::fail(__FILE__, __LINE__, problem);
    const std::string json = libraryJson();
    CHECK(json.find("\"name\":\"env.adsr\"") != std::string::npos);
    CHECK(json.find("\"name\":\"drum.kick\"") != std::string::npos);
    CHECK(json.find("\"scale.minor\"") != std::string::npos);
}

TEST(nested_function_calls_hit_a_budget_instead_of_hanging) {
    // Each level calls the one below twice: 2^22 expansions without a budget.
    std::string src = "fn f0(x) = x\n";
    for (int k = 1; k <= 22; ++k)
        src += "fn f" + std::to_string(k) + "(x) = f" + std::to_string(k - 1) + "(0) + f" + std::to_string(k - 1) + "(0)\n";
    src += "f22(1)\n";
    CHECK(compileModule(src).error.find("functions expand to too much code") != std::string::npos);
}

TEST(effect_buffers_start_silent_on_every_loop) {
    // A long, loud echo tail would leak into the next loop if the delay weren't cleared at the loop start.
    const std::string src = "---\nmode: float\n---\nfx.delay(saw(110) * ad(t == 0, 0.001, 0.05), 0.4, 0.9, 1) * 0.5\n";
    ProjectSpec p = singleModuleProject(src, 120, 1);
    p.seamCrossfade = false;
    ExportOptions free;
    free.kind = ExportKind::Free;
    free.seconds = 4.0;  // two loops of 2 s
    RenderResult out;
    CHECK(renderExport(p, free, out));
    const size_t half = out.samples.size() / 2;
    double diff = 0, peak = 0;
    for (size_t i = 0; i < half; ++i) {
        diff = std::fmax(diff, std::fabs(out.samples[i] - out.samples[half + i]));
        peak = std::fmax(peak, std::fabs(out.samples[i]));
    }
    CHECK(peak > 0.05);
    CHECK(diff < 1e-6);  // only the master DC blocker carries over; a leaking echo would differ by about 0.1
}

TEST(projects_have_a_memory_budget) {
    // Each module holds five delay lines (about 7.3 MB); nine such layers pass the 64 MB budget.
    std::string body = "---\nmode: float\n---\nlet x = saw(110) * 0.1\n";
    for (int k = 0; k < 5; ++k) body += "let d" + std::to_string(k) + " = fx.delay(x, 0.1)\n";
    body += "(d0 + d1 + d2 + d3 + d4) * 0.1\n";
    ProjectSpec p;
    for (int k = 0; k < 9; ++k) {
        const std::string id = "m" + std::to_string(k);
        p.modules.push_back({id, body, {}});
        LayerSpec l;
        l.id = "l" + std::to_string(k);
        l.chain = {id};
        p.layers.push_back(l);
    }
    Engine e(48000);
    const std::string res = e.setProject(p);
    CHECK(res.find("layer left silent") != std::string::npos);
    CHECK(res.find("\"m7\":{\"ok\":true") == std::string::npos || res.find("layer left silent") > res.find("\"m7\""));
}

TEST(music_helpers_treat_nan_the_same_everywhere) {
    // inf - inf is NaN: it picks the major scale on every platform (degree 2 of C major is E).
    CHECK_EQ(one("scale(2, exp(1000) - exp(1000), 60)"), 64.0);
    CHECK_EQ(one("chord(exp(1000) - exp(1000), 1, 60)"), 64.0);
    CHECK_EQ(one("scale(0, scale.major, exp(1000))"), 1000.0);
}

TEST(a_clashing_project_library_fails_alone) {
    const std::string good = "---\nkind: library\nnamespace: mine\n---\nfn twice(x) = x * 2\n";
    const std::string clash = "---\nkind: library\nnamespace: mine\n---\nfn twice(x) = x * 3\n";
    const std::vector<LibrarySource> libs = projectLibraries(std::vector<std::string_view>{good, clash});
    CHECK(libs.size() == 1);
    CHECK(compileModule("mine.twice(1)", libs).program != nullptr);
    CHECK(compileModule(clash, libs).error.find("already defined") != std::string::npos);
}
