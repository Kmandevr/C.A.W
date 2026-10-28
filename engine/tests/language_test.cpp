// Language tests: JavaScript bytebeat semantics, defined edge cases, built-ins, params and compile errors.
#include <string>

#include "compile.h"
#include "detmath.h"
#include "test.h"
#include "vm.h"

using namespace caw;

namespace {

// Compiles `src` and returns the raw value of its output expression at the given t.
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

}  // namespace

TEST(bytebeat_precedence_matches_javascript) {
    // (t>>6) << (5%t), as JavaScript reads it.
    CHECK_EQ(eval("t>>6<<5%t", 1000), 480.0);
    CHECK_EQ(eval("t>>6<<5%t", 3), 0.0);
    CHECK_EQ(eval("t*(t>>5|t>>8)", 4000), 4000.0 * ((4000 >> 5) | (4000 >> 8)));
    CHECK_EQ(eval("1+2*3"), 7.0);
    CHECK_EQ(eval("1|2^3&4"), static_cast<double>(1 | (2 ^ (3 & 4))));
    CHECK_EQ(eval("1<2==1"), 1.0);
}

TEST(int32_wrapping_and_shifts) {
    CHECK_EQ(eval("2147483647+1|0"), -2147483648.0);
    CHECK_EQ(eval("-1>>>28"), 15.0);
    CHECK_EQ(eval("-16>>2"), -4.0);
    CHECK_EQ(eval("1<<33"), 2.0);  // shift counts are masked to 0..31
    CHECK_EQ(eval("1<<31"), -2147483648.0);
    CHECK_EQ(eval("4294967296+5|0"), 5.0);
    CHECK_EQ(eval("~5"), -6.0);
    CHECK_EQ(eval("0x10|0b11"), 19.0);
    CHECK_EQ(eval("1e3"), 1000.0);
    CHECK_EQ(eval(".5*4"), 2.0);
}

TEST(division_and_modulo_are_defined) {
    CHECK_EQ(eval("5/0"), 0.0);
    CHECK_EQ(eval("5%0"), 0.0);
    CHECK_EQ(eval("t/t", 0), 0.0);
    CHECK_EQ(eval("-7%3"), -1.0);  // sign of the left side
    CHECK_EQ(eval("7.5%2"), 1.5);
    CHECK_EQ(eval("7/2"), 3.5);
}

TEST(logic_and_ternary) {
    CHECK_EQ(eval("1?2:3"), 2.0);
    CHECK_EQ(eval("0?2:3"), 3.0);
    CHECK_EQ(eval("t?2:3", 5), 2.0);
    CHECK_EQ(eval("0?1:0?2:3"), 3.0);
    CHECK_EQ(eval("3&&4"), 4.0);
    CHECK_EQ(eval("0||7"), 7.0);
    CHECK_EQ(eval("!0"), 1.0);
    CHECK_EQ(eval("2**10"), 1024.0);
    CHECK_EQ(eval("2**-1"), 0.5);
    CHECK_EQ(eval("2**3**2"), 512.0);  // right-associative
}

TEST(note_names) {
    CHECK_EQ(eval("C4"), 60.0);
    CHECK_EQ(eval("A4"), 69.0);
    CHECK_EQ(eval("C#4"), 61.0);
    CHECK_EQ(eval("Bb2"), 46.0);
    CHECK_EQ(eval("C0"), 12.0);
    CHECK_NEAR(eval("mtof(A4)"), 440.0, 1e-9);
    CHECK_NEAR(eval("mtof(A5)"), 880.0, 1e-9);
}

TEST(bit_tools) {
    CHECK_EQ(eval("rotl(1,31)"), -2147483648.0);
    CHECK_EQ(eval("rotr(1,1)"), -2147483648.0);
    CHECK_EQ(eval("popcount(255)"), 8.0);
    CHECK_EQ(eval("clz(1)"), 31.0);
    CHECK_EQ(eval("ctz(8)"), 3.0);
    CHECK_EQ(eval("clz(0)"), 32.0);
    CHECK_EQ(eval("bitrev(1)"), -2147483648.0);
    CHECK_EQ(eval("bswap(1)"), 16777216.0);
    CHECK_EQ(eval("float(bits(1.5))"), 1.5);
    CHECK_EQ(eval("bits(1)"), 1065353216.0);
    CHECK_EQ(eval("hash(7)"), eval("hash(7)"));
    CHECK(eval("hash(7)") != eval("hash(8)"));
}

TEST(maths_is_accurate) {
    CHECK_NEAR(eval("sin(pi/2)"), 1.0, 1e-15);
    CHECK_NEAR(eval("sin(1)"), 0.8414709848078965, 1e-15);
    CHECK_NEAR(eval("sin(-100.5)"), 0.030959966783271346, 1e-13);
    CHECK_NEAR(eval("cos(0)"), 1.0, 1e-15);
    CHECK_NEAR(eval("exp(1)"), 2.718281828459045, 1e-15);
    CHECK_NEAR(eval("exp(-20)"), 2.061153622438558e-09, 1e-22);
    CHECK_NEAR(eval("log(10)"), 2.302585092994046, 1e-15);
    CHECK_NEAR(eval("pow(2,0.5)"), 1.4142135623730951, 1e-15);
    CHECK_NEAR(eval("tanh(0.5)"), 0.46211715726000974, 1e-15);
    CHECK_EQ(eval("log(0)"), 0.0);
    CHECK_EQ(eval("sqrt(-4)"), 0.0);
    CHECK_EQ(eval("clamp(5,0,1)"), 1.0);
    CHECK_EQ(eval("mix(2,4,0.5)"), 3.0);
    CHECK_EQ(eval("round(2.5)"), 3.0);
    CHECK_EQ(eval("fract(-0.25)"), 0.75);
}

TEST(let_and_param) {
    CHECK_EQ(eval("let a = t*2\na+1", 3), 7.0);
    CHECK_EQ(eval("let a = 2; let b = a*a; b+t", 1), 5.0);
    CHECK_EQ(eval("param shift = 6 in 1..12\nt>>shift", 640), 10.0);
    CHECK_EQ(eval("t *\n  2", 4), 8.0);  // a line break after an operator continues the line
    CHECK_EQ(eval("(t\n+1)", 4), 5.0);
    CompileResult r = compileModule("param a = 0.5\nparam b = 6 in 1..12\na*b");
    CHECK(r.program != nullptr);
    if (r.program) {
        CHECK_EQ(r.program->params.size(), size_t{2});
        CHECK_EQ(r.program->params[0].min, 0.0);
        CHECK_EQ(r.program->params[0].max, 1.0);
        CHECK_EQ(r.program->params[1].def, 6.0);
    }
}

TEST(header_sets_kind_mode_and_rate) {
    CompileResult r = compileModule("---\ncaw: 1\nkind: effect\nname: Crush\nsummary: test\n---\nin*0.5");
    CHECK(r.program != nullptr);
    if (!r.program) return;
    CHECK(r.program->kind == ModuleKind::Effect);
    CHECK(r.program->mode == OutputMode::Float);
    CHECK_EQ(r.program->name, std::string("Crush"));
    CompileResult g = compileModule("---\nrate: 11025\n---\nt");
    CHECK(g.program && g.program->mode == OutputMode::Byte && g.program->rate == 11025.0);
}

TEST(byte_output_mapping) {
    CompileResult r = compileModule("t");
    Instance inst(r.program);
    double tb[kBlock];
    for (int i = 0; i < kBlock; ++i) tb[i] = i;
    tb[1] = 255;
    tb[2] = 256;
    BlockCtx c;
    c.n = kBlock;
    c.vars[static_cast<int>(Var::T)] = tb;
    const double* o = inst.process(c);
    CHECK_EQ(o[0], -1.0);           // 0
    CHECK_EQ(o[1], 1.0);            // 255
    CHECK_EQ(o[2], -1.0);           // 256 wraps to 0
}

TEST(compile_errors_are_clear) {
    CHECK(has(err("foo"), "unknown name 'foo'"));
    CHECK(has(err("1 +"), "line ends too early"));
    CHECK(has(err("let t = 1\nt"), "built-in name"));
    CHECK(has(err("1\n2"), "only the last line"));
    CHECK(has(err("let a = 1"), "no output"));
    CHECK(has(err("sin(1,2)"), "takes 1 argument"));
    CHECK(has(err("t $ 2"), "unexpected character"));
    CHECK(has(err("param p = 5 in 1..2\np"), "outside its range"));
    CHECK(has(err("---\nkind: blah\n---\nt"), "kind must be"));
    CHECK(has(err("---\nkind: effect\n"), "never ends"));
    CHECK(has(err("---\ncaw: 2\n---\nt"), "format 1"));
    CHECK(has(err("sin"), "is a function"));
    // Positions count the header lines.
    CHECK(has(err("---\nname: x\n---\nlet a = 1\na + nope"), "line 5, col 5"));
}

TEST(limits_fail_closed) {
    std::string deep(500, '(');
    deep += "1" + std::string(500, ')');
    CHECK(has(err(deep), "nested too deeply"));
    std::string big = "0";
    while (big.size() < kMaxSourceBytes + 10) big += "+1";
    CHECK(has(err(big), "longer than 64 KB"));
    std::string many;
    for (int i = 0; i < 1100; ++i) many += "let v" + std::to_string(i) + " = t + " + std::to_string(i) + "\n";
    many += "v1";
    CHECK(has(err(many), "too big"));
    std::string oscs = "0";
    for (int i = 0; i < 1100; ++i) oscs += "+lpf(t,100)";
    CHECK(!err(oscs).empty());
}

TEST(stateful_builtins_make_sound) {
    // A 1 kHz sine at 48 kHz crosses zero every 24 samples.
    CompileResult r = compileModule("---\nmode: float\n---\nsine(1000)");
    Instance inst(r.program);
    BlockCtx c;
    c.n = kBlock;
    c.sr = 48000;
    const double* o = inst.process(c);
    CHECK_EQ(o[0], 0.0);
    CHECK_NEAR(o[12], 1.0, 1e-12);
    CHECK_NEAR(o[24], 0.0, 1e-12);
    // ad() rises on a trigger and decays.
    CompileResult e = compileModule("---\nmode: float\n---\nad(1, 0, 0.001)");
    Instance env(e.program);
    const double* eo = env.process(c);
    CHECK_EQ(eo[0], 1.0);
    CHECK(eo[40] < 0.01);
    // noise() is repeatable for the same t and seed.
    CompileResult n = compileModule("---\nmode: float\n---\nnoise()");
    Instance n1(n.program), n2(n.program);
    double tb[kBlock];
    for (int i = 0; i < kBlock; ++i) tb[i] = i;
    c.vars[static_cast<int>(Var::T)] = tb;
    const double* a = n1.process(c);
    const double* b = n2.process(c);
    bool same = true, varied = false;
    for (int i = 0; i < kBlock; ++i) {
        same = same && a[i] == b[i];
        varied = varied || a[i] != a[0];
    }
    CHECK(same);
    CHECK(varied);
}
