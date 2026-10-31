// v2 language tests: functions, rich params (step, tips, toggles, dropdowns, headers, docs), globals, exports and imports.
#include <cmath>
#include <string>
#include <vector>

#include "compile.h"
#include "detmath.h"
#include "engine.h"
#include "render.h"
#include "test.h"
#include "vm.h"

using namespace caw;

namespace {

double eval(const std::string& src, double t = 0) {
    CompileResult r = compileModule(src);
    if (!r.program) {
        cawtest::fail(__FILE__, __LINE__, "compile failed: " + src + " -> " + r.error);
        return -12345;
    }
    Instance inst(r.program);
    double tb[kBlock], zero[kBlock] = {};
    for (double& v : tb) v = t;
    BlockCtx c;
    c.n = kBlock;
    c.vars[static_cast<int>(Var::T)] = tb;
    for (int v = 0; v < static_cast<int>(Var::Count); ++v)
        if (!c.vars[v]) c.vars[v] = zero;
    inst.process(c);
    return inst.rawOutput()[0];
}

std::string err(const std::string& src) { return compileModule(src).error; }
bool has(const std::string& s, const char* part) { return s.find(part) != std::string::npos; }

std::vector<float> run(Engine& e, int64_t frames) {
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += 64) e.process(l.data() + i, r.data() + i, static_cast<int>(std::min<int64_t>(64, frames - i)));
    return l;
}

const char* kFloat = "---\nmode: float\n---\n";

}  // namespace

TEST(user_functions) {
    CHECK_EQ(eval("fn twice(x) = x * 2\ntwice(t) + 1", 3), 7.0);
    CHECK_EQ(eval("fn add(a, b) = a + b\nfn sq(x) = x * x\nadd(sq(t), 1)", 3), 10.0);
    // A function sees names defined before it.
    CHECK_EQ(eval("let k = 10\nfn f(x) = x + k\nf(t)", 1), 11.0);
    CHECK(has(err("fn f(x) = f(x)\nf(1)"), "can't call themselves"));
    CHECK(has(err("fn f(x) = x\nf(1, 2)"), "takes 1 argument"));
    CHECK(has(err("fn f(x) = nope\n1"), "unknown name 'nope'"));  // errors show even if never called
    CHECK(has(err("fn f(x, x) = x\n1"), "listed twice"));
    // Each call gets its own oscillator state.
    CompileResult r = compileModule("---\nmode: float\n---\nfn o(f) = sine(f)\no(100) + o(100)");
    CHECK(r.program && r.program->stateSize == 2);
    CompileResult d = compileModule("/// Doubles x.\nfn twice(x) = x * 2\ntwice(1)");
    CHECK(d.program && d.program->functions.size() == 1 && d.program->functions[0].doc == "Doubles x.");
}

TEST(rich_params) {
    CompileResult r = compileModule(
        "// --- Tone ---\n"
        "/// How bright the bass is.\n"
        "param cutoff = 900 in 100..4000 step 10 \"Brightness\"\n"
        "param wave = saw in [sine, saw, square] \"Shape\"\n"
        "// --- Switches ---\n"
        "param filter = on\n"
        "wave == wave.square ? 1 : filter * cutoff");
    CHECK(r.program != nullptr);
    if (!r.program) return;
    const auto& ps = r.program->params;
    CHECK_EQ(ps.size(), size_t{3});
    CHECK_EQ(ps[0].step, 10.0);
    CHECK_EQ(ps[0].tip, std::string("Brightness"));
    CHECK_EQ(ps[0].header, std::string("Tone"));
    CHECK_EQ(ps[0].doc, std::string("How bright the bass is."));
    CHECK(ps[1].kind == ParamKind::Choice);
    CHECK_EQ(ps[1].def, 1.0);
    CHECK_EQ(ps[1].max, 2.0);
    CHECK_EQ(ps[1].choices.size(), size_t{3});
    CHECK(ps[2].kind == ParamKind::Toggle);
    CHECK_EQ(ps[2].def, 1.0);
    CHECK_EQ(ps[2].header, std::string("Switches"));
    CHECK_EQ(eval("param wave = saw in [sine, saw, square]\nwave.square"), 2.0);
    CHECK(has(err("param w = tri in [sine, saw]\n1"), "must be one of its choices"));
    CHECK(has(err("param w = foo\n1"), "isn't a number"));
    CHECK(has(err("param x = 1 step 0\n1"), "step must be above 0"));
    CHECK(has(err("param x = 1 \"tip\n1"), "never closed"));
    std::string json = describeProgram(*r.program);
    CHECK(has(json, "\"kind\":\"choice\"") && has(json, "\"tip\":\"Brightness\"") && has(json, "\"header\":\"Tone\""));
}

TEST(globals_reach_every_module) {
    ProjectSpec p;
    p.master = 1.0;
    p.modules.push_back({"a", std::string(kFloat) + "global level = 0.2 \"Shared\"\nlevel", {}});
    p.modules.push_back({"b", std::string(kFloat) + "global level = 0.2\nlevel", {}});
    for (const char* id : {"a", "b"}) {
        LayerSpec l;
        l.id = std::string("l") + id;
        l.chain = {id};
        l.volume = 1.0;
        p.layers.push_back(l);
    }
    p.globals["level"] = 0.3;
    Engine e(48000);
    e.setMasterBypass(true);
    std::string res = e.setProject(p);
    CHECK(has(res, "\"global\":true"));
    e.play();
    const double g = std::cos(kPi / 4.0);
    std::vector<float> out = run(e, 100);
    CHECK_NEAR(out[99], 0.6 * g, 1e-6);
    e.setGlobal("level", 0.1);
    out = run(e, 100);
    CHECK_NEAR(out[99], 0.2 * g, 1e-6);
}

TEST(exports_feed_other_layers_in_either_order) {
    // The bass layer reads the kick's envelope (a sidechain). It works whichever layer comes first.
    for (int readerFirst = 0; readerFirst < 2; ++readerFirst) {
        ProjectSpec p;
        p.master = 1.0;
        p.seamCrossfade = false;
        p.modules.push_back({"k", std::string(kFloat) + "export let env = pos\n0", {}, "Kick"});
        p.modules.push_back({"b", std::string(kFloat) + "kick.env * 0.5", {}});
        LayerSpec kick, bass;
        kick.id = "kick";
        kick.chain = {"k"};
        bass.id = "bass";
        bass.chain = {"b"};
        kick.volume = bass.volume = 1.0;
        p.layers = readerFirst ? std::vector<LayerSpec>{bass, kick} : std::vector<LayerSpec>{kick, bass};
        Engine e(48000);
        e.setMasterBypass(true);
        std::string res = e.setProject(p);
        CHECK(has(res, "\"ref\":\"kick\""));
        CHECK(!has(res, "nothing exports"));
        e.play();
        std::vector<float> out = run(e, 10000);
        const double g = std::cos(kPi / 4.0);
        const double len = e.loopLength();
        // Same sample, no block of delay: the exporter runs first.
        CHECK_NEAR(out[9999], 9999.0 / len * 0.5 * g, 1e-6);
    }
}

TEST(exports_within_a_chain_and_missing_sources) {
    ProjectSpec p;
    p.master = 1.0;
    p.modules.push_back({"g", std::string(kFloat) + "export let half = 0.25\n0.5", {}, "Gen"});
    p.modules.push_back({"fx", "---\nkind: effect\n---\nin * gen.half * 4 + nobody.here", {}});
    LayerSpec l;
    l.id = "l";
    l.chain = {"g", "fx"};
    l.volume = 1.0;
    p.layers = {l};
    Engine e(48000);
    e.setMasterBypass(true);
    std::string res = e.setProject(p);
    CHECK(has(res, "nothing exports 'nobody.here'"));
    e.play();
    std::vector<float> out = run(e, 200);
    CHECK_NEAR(out[199], 0.5 * std::cos(kPi / 4.0), 1e-6);
}

TEST(cross_module_modulation_reaches_a_parameter_in_live_and_offline_render) {
    ProjectSpec p;
    p.master = 1.0;
    p.seamCrossfade = false;
    p.modules.push_back({"k", std::string(kFloat) + "export let env = 0.5\\n0", {}, "Kick"});
    p.modules.push_back({"g", std::string(kFloat) +
        "param level = 0.5 in 0..1\\nmod level = util.mod(level, kick.env, 0.4)\\nlevel", {}, "Bass"});
    LayerSpec kick, bass;
    kick.id = "kick";
    kick.chain = {"k"};
    kick.volume = 1.0;
    bass.id = "bass";
    bass.chain = {"g"};
    bass.volume = 1.0;
    p.layers = {kick, bass};

    Engine e(48000);
    e.setMasterBypass(true);
    const std::string result = e.setProject(p);
    CHECK(!has(result, "nothing exports"));
    e.play();
    const std::vector<float> live = run(e, 256);
    RenderResult rendered;
    CHECK(renderExport(p, ExportOptions{}, rendered));
    const double expected = 0.7 * std::cos(kPi / 4.0);
    CHECK_NEAR(live[200], expected, 1e-6);
    CHECK_NEAR(rendered.samples[static_cast<size_t>(200) * 2], expected, 1e-6);
}

TEST(sidechain_import_ducks_in_live_and_offline_render_deterministically) {
    ProjectSpec p;
    p.master = 1.0;
    p.seamCrossfade = false;
    p.modules.push_back({"k", std::string(kFloat) + "export let env = 0.5\n0", {}, "Kick"});
    p.modules.push_back({"g", std::string(kFloat) + "1", {}, "Bass"});
    p.modules.push_back({"duck", "---\nmode: float\nkind: effect\n---\nutil.duck(in, kick.env, 0.8)", {}, "Duck"});
    LayerSpec kick, bass;
    kick.id = "kick";
    kick.chain = {"k"};
    kick.volume = 1.0;
    bass.id = "bass";
    bass.chain = {"g", "duck"};
    bass.volume = 1.0;
    p.layers = {kick, bass};

    Engine e(48000);
    e.setMasterBypass(true);
    const std::string result = e.setProject(p);
    CHECK(!has(result, "nothing exports"));
    e.play();
    const std::vector<float> live = run(e, 256);
    RenderResult first, second;
    CHECK(renderExport(p, ExportOptions{}, first));
    CHECK(renderExport(p, ExportOptions{}, second));
    CHECK(first.samples == second.samples);
    CHECK(first.frames >= 256);
    const double expected = 0.6 * std::cos(kPi / 4.0);
    CHECK_NEAR(live[200], expected, 1e-6);
    CHECK_NEAR(first.samples[static_cast<size_t>(200) * 2], expected, 1e-6);
}

TEST(export_cycles_still_play) {
    ProjectSpec p;
    p.master = 1.0;
    p.modules.push_back({"a", std::string(kFloat) + "export let x = 0.1\nb.y", {}, "A"});
    p.modules.push_back({"b", std::string(kFloat) + "export let y = 0.2\na.x", {}, "B"});
    for (const char* id : {"a", "b"}) {
        LayerSpec l;
        l.id = id;
        l.chain = {id};
        l.volume = 1.0;
        p.layers.push_back(l);
    }
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string result = e.setProject(p);
    CHECK(has(result, "signal dependency cycle"));
    e.play();
    std::vector<float> out = run(e, 512);
    // One side reads the other a block late, so after the first block both values are there.
    CHECK_NEAR(out[511], 0.3 * std::cos(kPi / 4.0), 1e-6);
}
