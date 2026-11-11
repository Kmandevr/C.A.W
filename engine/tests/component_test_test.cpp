// Tests for the component testing suite: each measurement against known signals, built-in and loaded effects, determinism.
#include "test.h"

#include <chrono>
#include <cmath>
#include <complex>
#include <filesystem>
#include <limits>
#include <string>
#include <vector>

#include "analysis.h"
#include "caw.h"
#include "component_test.h"
#include "json.h"
#include "native_component_test_path.h"

using namespace caw;

namespace {

constexpr double kPi = 3.14159265358979323846;

Json run(const std::string& request) {
    Json j;
    std::string error;
    const std::string result = componentTestJson(request);
    if (!parseJson(result, j, error)) cawtest::fail(__FILE__, __LINE__, "result is not JSON: " + result);
    return j;
}

const Json& at(const Json& j, std::initializer_list<const char*> path) {
    static const Json kNull;
    const Json* p = &j;
    for (const char* k : path) {
        p = p->get(k);
        if (!p) return kNull;
    }
    return *p;
}

std::string library(const std::string& id, const std::string& params = "") {
    const char* path = caw::test::nativeComponentPath();
    return "{\"id\":\"" + id + "\",\"library\":\"" + jsonEscape(path ? path : "") + "\",\"trust\":\"trusted\"" +
           (params.empty() ? "" : ",\"params\":" + params) + "}";
}

bool hasWarning(const Json& r, const char* w) {
    for (const Json& x : at(r, {"warnings"}).arr)
        if (x.str == w) return true;
    return false;
}

std::vector<float> sine(std::size_t n, double f, double sr, double amp) {
    std::vector<float> x(n);
    for (std::size_t i = 0; i < n; ++i) x[i] = static_cast<float>(amp * std::sin(2 * kPi * f * i / sr));
    return x;
}

}  // namespace

TEST(analysis_fft_finds_a_bin_and_inverts) {
    const std::size_t n = 1024;
    std::vector<std::complex<double>> d(n);
    for (std::size_t i = 0; i < n; ++i) d[i] = std::cos(2 * kPi * 32 * i / n);
    const auto original = d;
    analysis::fft(d, false);
    CHECK_NEAR(std::abs(d[32]), n / 2.0, 1e-9);
    CHECK_NEAR(std::abs(d[n - 32]), n / 2.0, 1e-9);
    CHECK(std::abs(d[31]) < 1e-9 && std::abs(d[33]) < 1e-9);
    analysis::fft(d, true);
    for (std::size_t i = 0; i < n; ++i) CHECK_NEAR(d[i].real(), original[i].real(), 1e-12);
    CHECK_EQ(analysis::nextPowerOfTwo(1000), static_cast<std::size_t>(1024));
}

TEST(analysis_levels_of_known_signals) {
    const auto x = sine(48000, 1000, 48000, 1.0);
    const analysis::Levels l = analysis::levels(x.data(), x.size());
    CHECK_NEAR(l.peakDb, 0.0, 1e-6);
    CHECK_NEAR(l.rmsDb, -3.0103, 1e-3);
    CHECK_NEAR(l.crestDb, 3.0103, 1e-3);
    CHECK_NEAR(l.dc, 0.0, 1e-9);
    const std::vector<float> dc(100, 0.25f);
    const analysis::Levels d = analysis::levels(dc.data(), dc.size());
    CHECK_NEAR(d.dc, 0.25, 1e-12);
    CHECK_NEAR(d.crestDb, 0.0, 1e-9);
    std::vector<float> bad = {0.5f, std::numeric_limits<float>::quiet_NaN(), std::numeric_limits<float>::infinity(),
                              -std::numeric_limits<float>::infinity(), std::numeric_limits<float>::denorm_min(), 0.0f};
    const analysis::Levels b = analysis::levels(bad.data(), bad.size());
    CHECK_EQ(b.nan, 1u);
    CHECK_EQ(b.inf, 2u);
    CHECK_EQ(b.denormal, 1u);
    CHECK_NEAR(b.peak, 0.5, 1e-12);
    const std::vector<float> silent(10, 0.0f);
    CHECK(std::isinf(analysis::levels(silent.data(), silent.size()).peakDb));
}

TEST(analysis_stereo_correlation_and_width) {
    const auto l = sine(4800, 440, 48000, 0.5);
    std::vector<float> inv(l.size());
    for (std::size_t i = 0; i < l.size(); ++i) inv[i] = -l[i];
    const analysis::Stereo same = analysis::stereo(l.data(), l.data(), l.size());
    CHECK_NEAR(same.correlation, 1.0, 1e-12);
    CHECK_NEAR(same.width, 0.0, 1e-12);
    const analysis::Stereo opposite = analysis::stereo(l.data(), inv.data(), l.size());
    CHECK_NEAR(opposite.correlation, -1.0, 1e-12);
    CHECK_NEAR(opposite.width, 1.0, 1e-12);
    const auto q = sine(48000, 440, 48000, 0.5), s = sine(48000, 523, 48000, 0.5);  // unrelated tones
    const analysis::Stereo apart = analysis::stereo(q.data(), s.data(), q.size());
    CHECK(std::fabs(apart.correlation) < 0.01);
    CHECK_NEAR(apart.width, 0.5, 0.01);
}

TEST(analysis_thd_of_a_pure_and_a_distorted_sine) {
    const double sr = 48000;
    const auto pure = sine(48000, 1000, sr, 0.5);
    const analysis::SineDistortion p = analysis::sineDistortion(pure.data(), pure.size(), 1000, sr);
    CHECK(p.valid);
    CHECK_NEAR(p.fundamental, 0.5, 1e-6);
    CHECK(p.thd < 1e-6);
    CHECK(p.thdN < 1e-6);
    // 1 % third harmonic and 0.5 % fifth: THD = sqrt(1^2 + 0.5^2) %.
    std::vector<float> d(48000);
    for (std::size_t i = 0; i < d.size(); ++i) {
        const double w = 2 * kPi * 1000 * i / sr;
        d[i] = static_cast<float>(0.5 * std::sin(w) + 0.005 * std::sin(3 * w + 0.3) + 0.0025 * std::cos(5 * w));
    }
    const analysis::SineDistortion h = analysis::sineDistortion(d.data(), d.size(), 1000, sr);
    CHECK_NEAR(h.thd, std::sqrt(0.01 * 0.01 + 0.005 * 0.005), 1e-5);
    CHECK_NEAR(h.thdN, h.thd, 1e-5);  // no noise: THD+N is the harmonics
    const std::vector<float> silent(4800, 0.0f);
    CHECK(!analysis::sineDistortion(silent.data(), silent.size(), 1000, sr).valid);
}

TEST(analysis_ir_end_and_lag) {
    std::vector<float> x(1000, 0.0f);
    x[10] = 1.0f;
    x[400] = 0.001f;
    CHECK_EQ(analysis::endAbove(x.data(), x.size(), 1e-4), static_cast<std::size_t>(401));
    CHECK_EQ(analysis::endAbove(x.data(), x.size(), 0.01), static_cast<std::size_t>(11));
    CHECK_EQ(analysis::endAbove(x.data(), x.size(), 2.0), static_cast<std::size_t>(0));
    std::vector<float> ref(4096), late(4096, 0.0f);
    uint32_t s = 12345;
    for (float& v : ref) {
        s = s * 1664525u + 1013904223u;
        v = static_cast<float>(static_cast<int32_t>(s)) / 2147483648.0f;
    }
    for (std::size_t i = 0; i + 37 < late.size(); ++i) late[i + 37] = -0.5f * ref[i];  // inverted still matches
    CHECK_EQ(analysis::findLag(ref.data(), late.data(), ref.size(), 1000), static_cast<int64_t>(37));
    const std::vector<float> silent(4096, 0.0f);
    CHECK_EQ(analysis::findLag(ref.data(), silent.data(), ref.size(), 1000), static_cast<int64_t>(-1));
}

TEST(analysis_spectrum_reads_a_sine_at_its_level) {
    auto loudest = [](const std::vector<float>& x, double& hz) {
        double best = -1e9;
        for (const auto& b : analysis::spectrumBands(x.data(), x.size(), 8192, 48000, 6))
            if (b.db > best) best = b.db, hz = b.hz;
        return best;
    };
    double hz = 0;
    // On a bin (171 * 48000 / 8192 Hz) the Hann scaling reads the level exactly.
    CHECK_NEAR(loudest(sine(8192, 171 * 48000.0 / 8192, 48000, 0.5), hz), -6.0206, 1e-3);
    CHECK(hz > 900 && hz < 1100);
    // Between bins it reads low by the window's scalloping, at most 1.42 dB.
    const double off = loudest(sine(8192, 1000, 48000, 0.5), hz);
    CHECK(off <= -6.0206 + 1e-6 && off > -6.0206 - 1.43);
    // Shorter than the FFT (zero-padded): the window spans the signal, so the level still reads right (it read
    // 1.4 to 6 dB low while the window spanned the padded size).
    for (std::size_t n : {std::size_t(6000), std::size_t(4096), std::size_t(2000)}) {
        const double at = loudest(sine(n, 171 * 48000.0 / 8192, 48000, 0.5), hz);
        CHECK(at > -6.0206 - 1.43 && at < -6.0206 + 0.05);
    }
    CHECK_NEAR(loudest(sine(4096, 86 * 48000.0 / 8192, 48000, 0.5), hz), -6.0206, 0.05);  // on a bin of the 4096 frames
    const auto x = sine(8192, 1000, 48000, 0.5);
    const auto flat = analysis::frequencyResponse(x.data(), x.data(), x.size(), 48000, 6);
    CHECK(!flat.empty());
    for (const auto& b : flat) CHECK_NEAR(b.db, 0.0, 1e-9);
}

TEST(component_test_signals_are_as_asked) {
    std::vector<float> l, r;
    std::string error;
    TestSignal s;
    s.kind = TestSignalKind::Impulse;
    CHECK(generateTestSignal(s, 48000, l, r, error));
    CHECK_EQ(l.size(), static_cast<std::size_t>(1));
    CHECK_EQ(l[0], 1.0f);
    s.kind = TestSignalKind::Sine;
    s.seconds = 0.5;
    CHECK(generateTestSignal(s, 48000, l, r, error));
    CHECK_EQ(l.size(), static_cast<std::size_t>(24000));
    CHECK_NEAR(analysis::levels(l.data(), l.size()).peakDb, -6.0, 1e-3);
    CHECK(l == r);
    for (TestSignalKind k : {TestSignalKind::WhiteNoise, TestSignalKind::PinkNoise}) {
        s.kind = k;
        s.level = -20;
        s.levelSet = true;
        CHECK(generateTestSignal(s, 48000, l, r, error));
        CHECK_NEAR(analysis::levels(l.data(), l.size()).rmsDb, -20.0, 1e-3);  // noise level is RMS
        std::vector<float> l2, r2;
        CHECK(generateTestSignal(s, 48000, l2, r2, error));
        CHECK(l == l2);  // seeded: the same every time
        s.decorrelated = true;
        CHECK(generateTestSignal(s, 48000, l2, r2, error));
        CHECK(l2 != r2);
        // Pink noise is mostly low frequencies, so one second of it correlates more by chance.
        CHECK(std::fabs(analysis::stereo(l2.data(), r2.data(), l2.size()).correlation) <
              (k == TestSignalKind::WhiteNoise ? 0.02 : 0.3));
        s.decorrelated = false;
        s.seed = 2;
        CHECK(generateTestSignal(s, 48000, l2, r2, error));
        CHECK(l != l2);
        s.seed = 1;
    }
    s.kind = TestSignalKind::Sweep;
    s.levelSet = false;
    CHECK(generateTestSignal(s, 48000, l, r, error));
    CHECK_NEAR(analysis::levels(l.data(), l.size()).peakDb, -6.0, 0.01);
    s.kind = TestSignalKind::Dc;
    CHECK(generateTestSignal(s, 48000, l, r, error));
    CHECK_NEAR(analysis::levels(l.data(), l.size()).dc, std::pow(10.0, -6.0 / 20), 1e-6);
    s.kind = TestSignalKind::Silence;
    CHECK(generateTestSignal(s, 48000, l, r, error));
    CHECK_EQ(analysis::levels(l.data(), l.size()).peak, 0.0);
    s.kind = TestSignalKind::Sine;
    s.frequency = 30000;
    CHECK(!generateTestSignal(s, 48000, l, r, error));
}

TEST(component_test_clean_effect_has_near_zero_thd) {
    const Json r = run("{\"component\":\"org.caw.stereo.balance\",\"cpu\":false}");
    CHECK(r.boolean("ok", false));
    const Json& left = at(r, {"output", "thd", "left"});
    CHECK(left.number("thd_n_percent", 1) < 1e-4);
    CHECK(left.number("thd_percent", 1) < 1e-4);
    CHECK_NEAR(left.number("fundamental_db", 0), -6.0, 1e-3);
    const Json& ch = at(r, {"output", "channels"});
    CHECK_EQ(ch.arr.size(), static_cast<std::size_t>(2));
    CHECK_NEAR(ch.arr[0].number("gain_db", 1), 0.0, 1e-6);
    CHECK_NEAR(ch.arr[0].number("rms_db", 0), -9.0103, 1e-3);
    CHECK_NEAR(at(r, {"output", "stereo"}).number("correlation", 0), 1.0, 1e-9);
    CHECK(at(r, {"warnings"}).arr.empty());
    CHECK(r.get("cpu") == nullptr);  // asked for none
}

TEST(component_test_gain_change_shows_the_right_db) {
    // Distortion with mix 0 is its output level alone; the fixture's gain component sets each side.
    const Json r = run("{\"component\":{\"id\":\"org.caw.distortion\",\"params\":{\"mix\":0,\"output\":0.5}},\"cpu\":false}");
    CHECK_NEAR(at(r, {"output", "channels"}).arr[0].number("gain_db", 0), -6.0206, 1e-3);
    const Json g = run("{\"component\":" + library("org.caw.tests.native-loader.gain", "{\"left\":0.5,\"right\":2}") +
                       ",\"signal\":{\"type\":\"white\",\"level_db\":-20},\"cpu\":false}");
    CHECK(g.boolean("ok", false));
    CHECK_NEAR(at(g, {"output", "channels"}).arr[0].number("gain_db", 0), -6.0206, 1e-3);
    CHECK_NEAR(at(g, {"output", "channels"}).arr[1].number("gain_db", 0), 6.0206, 1e-3);
    CHECK_EQ(at(g, {"component", "params"}).number("left", 0), 0.5);
    CHECK_EQ(at(g, {"component", "source"}).str, std::string("library"));
}

TEST(component_test_hard_clip_distorts) {
    const Json r = run("{\"component\":{\"id\":\"org.caw.distortion\",\"params\":{\"shape\":1,\"drive\":10}},\"cpu\":false}");
    CHECK(at(r, {"output", "thd", "left"}).number("thd_percent", 0) > 10.0);
    CHECK(at(r, {"output", "thd", "left"}).number("thd_n_percent", 0) >=
          at(r, {"output", "thd", "left"}).number("thd_percent", 0) - 1e-6);
}

TEST(component_test_impulse_response_length_of_a_known_echo) {
    // 240-frame echo, feedback 0.5: the 14th repeat (0.5^14) is the last above -90 dB, at frame 3360.
    const Json r = run("{\"component\":" + library("org.caw.tests.native-loader.echo") +
                       ",\"signal\":\"impulse\",\"cpu\":false}");
    CHECK(r.boolean("ok", false));
    const Json& ir = at(r, {"output", "impulse_response"});
    CHECK_EQ(ir.number("length_frames", 0), 3361.0);
    CHECK(!ir.boolean("truncated", true));
    const Json& tail = at(r, {"output", "tail"});
    CHECK_EQ(tail.number("measured", 0), 3360.0);
    CHECK(tail.boolean("within_declared", false));
    CHECK_EQ(tail.number("declared", 0), 48000.0);
    CHECK_EQ(at(r, {"output", "latency"}).number("measured", -1), 0.0);
    // Its float feedback decays into subnormals: the suite says so.
    CHECK(at(r, {"output", "channels"}).arr[0].number("denormal", 0) > 0);
    CHECK(hasWarning(r, "denormals"));
    // The comb's response: +6 dB peaks (1 / (1 - 0.5)) and -3.5 dB dips (1 / 1.5), band-averaged between.
    for (const Json& b : at(r, {"output", "frequency_response", "bands"}).arr) {
        CHECK(b.arr[1].num < 6.03);
        CHECK(b.arr[1].num > -3.53);
    }
}

TEST(component_test_latency_measured_against_declared) {
    for (const char* signal : {"impulse", "white", "pink", "sweep"}) {
        const Json r = run("{\"component\":" + library("org.caw.tests.native-loader.late") + ",\"signal\":\"" + signal +
                           "\",\"cpu\":false,\"bypass\":true}");
        const Json& lat = at(r, {"output", "latency"});
        CHECK_EQ(lat.number("declared", 0), 100.0);
        CHECK_EQ(lat.number("measured", 0), 100.0);
        CHECK(lat.boolean("matches", false));
        CHECK(!hasWarning(r, "latency_mismatch"));
        // Against bypass, aligned by the declared latency, a pure delay nulls exactly.
        CHECK(at(r, {"bypass"}).boolean("exact", false));
        CHECK(at(r, {"bypass"}).get("difference_peak_db")->type == Json::Type::Null);  // minus infinity
        CHECK_EQ(at(r, {"bypass"}).number("offset_frames", 0), 100.0);
    }
    const Json unaligned = run("{\"component\":" + library("org.caw.tests.native-loader.late") +
                               ",\"signal\":\"white\",\"cpu\":false,\"bypass\":true,\"align\":\"none\"}");
    CHECK(!at(unaligned, {"bypass"}).boolean("exact", true));
    CHECK(at(unaligned, {"bypass"}).number("difference_rms_db", -999) > -20);
    // A sine can't show latency (every cycle matches): measured is null.
    const Json s = run("{\"component\":" + library("org.caw.tests.native-loader.late") + ",\"cpu\":false}");
    CHECK(at(s, {"output", "latency"}).get("measured")->type == Json::Type::Null);
}

TEST(component_test_null_of_identical_components_is_exact_silence) {
    const std::string fx = "{\"id\":\"org.caw.distortion\",\"params\":{\"shape\":2,\"drive\":6}}";
    const Json r = run("{\"component\":" + fx + ",\"compare\":" + fx + ",\"signal\":\"pink\",\"cpu\":false}");
    CHECK(at(r, {"compare"}).boolean("exact", false));
    CHECK(at(r, {"compare"}).get("difference_rms_db")->type == Json::Type::Null);
    // Two builds of one id: the library's component against the same library, in separate registries.
    const Json b = run("{\"component\":" + library("org.caw.tests.native-loader.echo") +
                       ",\"compare\":" + library("org.caw.tests.native-loader.echo") + ",\"cpu\":false}");
    CHECK(b.boolean("ok", false));
    CHECK(at(b, {"compare"}).boolean("exact", false));
    // A different component does not null; measured alignment finds the late one's delay.
    const Json d = run("{\"component\":" + library("org.caw.tests.native-loader.late") +
                       ",\"compare\":\"org.caw.stereo.width\",\"signal\":\"white\",\"align\":\"measured\",\"cpu\":false}");
    CHECK(at(d, {"compare"}).boolean("exact", false));
    CHECK_EQ(at(d, {"compare"}).number("offset_frames", 0), 100.0);
    const Json e = run("{\"component\":\"org.caw.stereo.width\",\"compare\":{\"id\":\"org.caw.distortion\"},\"cpu\":false}");
    CHECK(!at(e, {"compare"}).boolean("exact", true));
    CHECK(at(e, {"compare"}).number("difference_rms_db", -999) > -40);
}

TEST(component_test_parameter_sweep_reports_each_value) {
    const Json r = run("{\"component\":{\"id\":\"org.caw.distortion\",\"params\":{\"mix\":0}},"
                       "\"sweep\":{\"param\":\"output\",\"steps\":3},\"cpu\":false}");
    const Json& pts = at(r, {"sweep", "points"});
    CHECK_EQ(pts.arr.size(), static_cast<std::size_t>(3));
    CHECK_EQ(pts.arr[0].number("value", -1), 0.0);
    CHECK(pts.arr[0].get("channels")->arr[0].get("gain_db")->type == Json::Type::Null);  // silent
    CHECK_NEAR(pts.arr[1].get("channels")->arr[0].number("gain_db", 9), 0.0, 1e-6);
    CHECK_NEAR(pts.arr[2].get("channels")->arr[0].number("gain_db", 0), 6.0206, 1e-3);
    CHECK(pts.arr[2].get("spectrum") == nullptr);  // points stay small
    // A choice parameter steps through its choices by default.
    const Json c = run("{\"component\":\"org.caw.distortion\",\"sweep\":{\"param\":\"shape\"},\"cpu\":false}");
    CHECK_EQ(at(c, {"sweep", "points"}).arr.size(), static_cast<std::size_t>(4));
    CHECK_EQ(at(c, {"sweep", "points"}).arr[3].number("value", 0), 3.0);
}

TEST(component_test_built_in_effects_pass_their_own_checks) {
    for (const char* id : {"org.caw.stereo.balance", "org.caw.stereo.width", "org.caw.distortion",
                           "org.caw.delay.pingpong", "org.caw.chorus"}) {
        for (const char* signal : {"impulse", "sine", "sweep", "pink", "silence", "dc"}) {
            const Json r = run(std::string("{\"component\":\"") + id + "\",\"signal\":\"" + signal +
                               "\",\"cpu\":false,\"block_size\":37}");
            CHECK(r.boolean("ok", false));
            CHECK(!hasWarning(r, "non_finite"));
            CHECK(!hasWarning(r, "failed_blocks"));
            CHECK(!hasWarning(r, "latency_mismatch"));
            CHECK(!hasWarning(r, "tail_exceeds_declared"));
        }
    }
    // The chorus makes a mono input wide; width and balance at their defaults leave it mono.
    const Json chorus = run("{\"component\":\"org.caw.chorus\",\"signal\":\"pink\",\"cpu\":false}");
    CHECK(at(chorus, {"output", "stereo"}).number("width", 0) > 0.05);
    const Json width = run("{\"component\":{\"id\":\"org.caw.stereo.width\",\"params\":{\"width\":2}},"
                           "\"signal\":{\"type\":\"pink\",\"decorrelated\":true},\"cpu\":false}");
    const Json narrow = run("{\"component\":{\"id\":\"org.caw.stereo.width\",\"params\":{\"width\":0}},"
                            "\"signal\":{\"type\":\"pink\",\"decorrelated\":true},\"cpu\":false}");
    CHECK(at(width, {"output", "stereo"}).number("width", 0) > 0.5);
    CHECK_NEAR(at(narrow, {"output", "stereo"}).number("width", 1), 0.0, 1e-6);
    CHECK_NEAR(at(narrow, {"output", "stereo"}).number("correlation", 0), 1.0, 1e-6);
}

TEST(component_test_tail_longer_than_declared_is_flagged) {
    // The drone declares 0.1 s but never stops.
    const Json r = run("{\"component\":" + library("org.caw.tests.native-loader.drone") +
                       ",\"signal\":\"impulse\",\"cpu\":false}");
    CHECK(!at(r, {"output", "tail"}).boolean("within_declared", true));
    CHECK(at(r, {"output", "tail"}).boolean("truncated", false));
    CHECK(hasWarning(r, "tail_exceeds_declared"));
}

TEST(component_test_is_deterministic) {
    for (const char* req : {"{\"component\":\"org.caw.chorus\",\"signal\":\"pink\",\"cpu\":false,\"bypass\":true}",
                            "{\"component\":\"org.caw.delay.pingpong\",\"signal\":\"impulse\",\"cpu\":false,"
                            "\"sweep\":{\"param\":\"feedback\",\"steps\":2}}"}) {
        const std::string a = componentTestJson(req), b = componentTestJson(req);
        CHECK(a == b);
        CHECK(a.find("\"ok\":true") != std::string::npos);
    }
    // CPU timing is measured per block: the only part allowed to vary.
    const Json t = run("{\"component\":\"org.caw.stereo.width\",\"signal\":{\"type\":\"sine\",\"seconds\":0.1}}");
    CHECK_EQ(at(t, {"cpu"}).number("blocks", 0), 263.0);  // 0.1 s + 0.25 s of tail in 64-frame blocks, rounded up
    CHECK(at(t, {"cpu"}).number("worst_us", -1) >= at(t, {"cpu"}).number("median_us", 0));
}

TEST(component_test_refuses_what_it_should) {
    auto error = [](const std::string& req) {
        const Json r = run(req);
        CHECK(!r.boolean("ok", true));
        return r.string("error");
    };
    const char* path = caw::test::nativeComponentPath();
    const std::string lib = jsonEscape(path ? path : "");
    CHECK(error("{\"component\":{\"id\":\"org.caw.tests.native-loader.echo\",\"library\":\"" + lib + "\"}}")
              .find("explicit trust") != std::string::npos);
    CHECK(error("{\"component\":{\"id\":\"org.caw.tests.native-loader.echo\",\"library\":\"" + lib +
                "\",\"trust\":\"blocked\"}}").find("blocked") != std::string::npos);
    CHECK(!error("{\"component\":{\"id\":\"org.caw.tests.native-loader.echo\",\"library\":\"" + lib +
                 "\",\"trust\":\"isolated\"}}").empty());
    CHECK(error("{\"component\":\"org.example.missing\"}").find("not built in") != std::string::npos);
    CHECK(error("{\"component\":{\"id\":\"org.caw.distortion\",\"params\":{\"nope\":1}}}").find("nope") !=
          std::string::npos);
    CHECK(error("{\"component\":\"org.caw.distortion\",\"sigal\":\"sine\"}").find("sigal") != std::string::npos);
    CHECK(!error("{\"component\":\"org.caw.distortion\",\"block_size\":0}").empty());
    CHECK(!error("{\"component\":\"org.caw.distortion\",\"fft_size\":1000}").empty());
    CHECK(!error("{\"component\":\"org.caw.distortion\",\"signal\":\"square\"}").empty());
    CHECK(!error("{\"component\":\"org.caw.distortion\",\"sweep\":{\"param\":\"nope\"}}").empty());
    CHECK(!error("not json").empty());
    CHECK(!error("{\"component\":\"org.caw.distortion\",\"signal\":{\"type\":\"sine\",\"seconds\":500}}").empty());
}

TEST(component_test_wav_round_trip_and_c_api) {
    const auto dir = std::filesystem::temp_directory_path() /
                     ("caw_component_test_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    std::filesystem::create_directories(dir);
    const std::string in = (dir / "in.wav").string(), out = (dir / "out.wav").string();
    const Json a = run("{\"component\":\"org.caw.stereo.width\",\"signal\":\"pink\",\"tail_seconds\":0,\"cpu\":false,"
                       "\"write_input_wav\":\"" + jsonEscape(in) + "\",\"write_wav\":\"" + jsonEscape(out) + "\"}");
    CHECK(a.boolean("ok", false));
    CHECK(std::filesystem::exists(in) && std::filesystem::exists(out));
    // The written signal, played back from the file, gives the same result as the generated one.
    const Json b = run("{\"component\":\"org.caw.stereo.width\",\"signal\":{\"type\":\"wav\",\"path\":\"" +
                       jsonEscape(in) + "\"},\"tail_seconds\":0,\"cpu\":false}");
    CHECK(b.boolean("ok", false));
    CHECK_EQ(at(b, {"settings"}).number("sample_rate", 0), 48000.0);
    CHECK_EQ(at(a, {"output", "channels"}).arr[0].number("rms_db", 0), at(b, {"output", "channels"}).arr[0].number("rms_db", 1));
    const Json mismatch = run("{\"component\":\"org.caw.stereo.width\",\"sample_rate\":44100,\"signal\":{\"type\":\"wav\","
                              "\"path\":\"" + jsonEscape(in) + "\"}}");
    CHECK(!mismatch.boolean("ok", true));
    std::filesystem::remove_all(dir);

    char* result = caw_component_test("{\"component\":\"org.caw.stereo.balance\",\"cpu\":false}", CAW_NATIVE_TRUST_BLOCKED,
                                      nullptr, nullptr);
    CHECK(result != nullptr);
    CHECK(std::string(result).find("\"ok\":true") != std::string::npos);
    caw_free(result);
    // Through the C API the host gives the trust and the folders: a request can't choose them.
    result = caw_component_test("{\"component\":{\"id\":\"x\",\"library\":\"/tmp/x.so\",\"trust\":\"trusted\"}}",
                                CAW_NATIVE_TRUST_BLOCKED, nullptr, nullptr);
    CHECK(std::string(result).find("may not choose a trust") != std::string::npos);
    caw_free(result);
    result = caw_component_test("{\"component\":\"org.caw.stereo.balance\",\"write_wav\":\"../evil.wav\"}",
                                CAW_NATIVE_TRUST_BLOCKED, "/tmp", nullptr);
    CHECK(std::string(result).find("plain file name") != std::string::npos);
    caw_free(result);
    result = caw_component_test("{\"component\":\"org.caw.stereo.balance\",\"write_wav\":\"out.wav\"}",
                                CAW_NATIVE_TRUST_BLOCKED, nullptr, nullptr);
    CHECK(std::string(result).find("plain file name") != std::string::npos);
    caw_free(result);
    result = caw_component_test(nullptr, CAW_NATIVE_TRUST_BLOCKED, nullptr, nullptr);
    CHECK(std::string(result).find("\"ok\":false") != std::string::npos);
    caw_free(result);
}

TEST(component_test_plays_an_instrument_its_notes) {
    // An instrument (no audio input, an event input) is fed notes: its output, its tail after the last note off.
    const std::string req =
        "{\"component\":\"org.caw.synth.flagship\",\"cpu\":false,\"notes\":[{\"pitch\":57,\"velocity\":110,"
        "\"start\":0,\"length\":0.4},{\"pitch\":64.5,\"velocity\":60,\"start\":0.2,\"length\":0.3}],\"tail_seconds\":2}";
    const Json r = run(req);
    CHECK(r.boolean("ok", false));
    CHECK(at(r, {"settings"}).string("signal") == "notes");
    CHECK_EQ(at(r, {"settings"}).number("notes", 0), 2.0);
    CHECK_EQ(at(r, {"settings"}).number("signal_frames", 0), 24000.0);  // the last note ends at 0.5 s
    CHECK(at(r, {"output", "channels"}).arr[0].number("peak_db", -200) > -30);
    CHECK(at(r, {"output", "stereo"}).number("width", 0) > 0.01);  // its unison is spread across the sides
    const Json& tail = at(r, {"output", "tail"});
    CHECK(tail.type == Json::Type::Object);
    CHECK(tail.number("measured", 0) > 0);  // its release rings past the last note off
    CHECK(at(r, {"ports"}).number("audio_inputs", -1) == 0.0);
    CHECK(at(r, {"ports"}).number("event_inputs", -1) == 1.0);
    CHECK(at(r, {"output", "thd"}).type == Json::Type::Null);  // no sine went in
    CHECK(componentTestJson(req) == componentTestJson(req));
    // With no notes it plays one C4 for a second; a drum the same way.
    // (Drums in Single mode: pad A1, the 808 kick, answers every note, so the C4 plays it.)
    const Json kick = run("{\"component\":{\"id\":\"org.caw.drums\",\"params\":{\"mode\":1}},\"cpu\":false}");
    CHECK(kick.boolean("ok", false));
    CHECK_EQ(at(kick, {"settings"}).number("signal_frames", 0), 48000.0);
    const Json& kickChannels = at(kick, {"output", "channels"});
    CHECK(!kickChannels.arr.empty());
    if (!kickChannels.arr.empty()) CHECK(kickChannels.arr[0].number("peak_db", -200) > -20);
    CHECK(!run("{\"component\":\"org.caw.drums\",\"bypass\":true}").boolean("ok", true));
}

TEST(component_test_feeds_a_keyed_effect_its_sidechain_and_key_notes) {
    // The ducker: main input, a stereo sidechain and key notes. In Audio mode a loud key ducks the main signal; with
    // the key silent (no 'inputs'), nothing ducks. In Notes mode, the request's notes duck it.
    auto gain = [](const std::string& extra, const std::string& params) {
        const Json r = run("{\"component\":{\"id\":\"org.caw.ducker\",\"params\":{" + params +
                           "}},\"signal\":{\"type\":\"sine\",\"frequency\":200,\"seconds\":1},\"cpu\":false" + extra + "}");
        CHECK(r.boolean("ok", false));
        CHECK_EQ(at(r, {"ports"}).number("audio_inputs", 0), 2.0);
        CHECK_EQ(at(r, {"ports"}).number("event_inputs", 0), 1.0);
        return at(r, {"output", "channels"}).arr.empty() ? 0.0 : at(r, {"output", "channels"}).arr[0].number("gain_db", 0);
    };
    const std::string audio = "\"mode\":0,\"response\":1,\"depth\":1,\"threshold\":-40";
    CHECK_NEAR(gain("", audio), 0.0, 0.01);
    CHECK(gain(",\"inputs\":{\"sidechain\":{\"type\":\"dc\",\"level_db\":-6,\"seconds\":1}}", audio) < -20);
    const std::string notes = "\"mode\":1,\"depth\":0.9,\"release\":2000,\"hold\":500";
    CHECK_NEAR(gain("", notes), 0.0, 0.01);
    CHECK(gain(",\"notes\":[{\"pitch\":36,\"start\":0.1,\"length\":0.1},{\"pitch\":36,\"start\":0.6,\"length\":0.1}]", notes) < -3);
    // A port it doesn't have, and notes for an effect without an event input, are refused.
    CHECK(run("{\"component\":\"org.caw.ducker\",\"inputs\":{\"key\":\"sine\"}}").string("error").find("'key'") !=
          std::string::npos);
    CHECK(!run("{\"component\":\"org.caw.chorus\",\"notes\":[{\"pitch\":60}]}").boolean("ok", true));
}

TEST(component_test_checks_its_thresholds) {
    const Json r = run(
        "{\"component\":{\"id\":\"org.caw.distortion\",\"params\":{\"shape\":1,\"drive\":8}},\"signal\":\"sine\","
        "\"cpu\":false,\"bypass\":true,\"checks\":["
        "{\"path\":\"output.channels.0.peak_db\",\"max\":0.01},"            // hard clip holds full scale
        "{\"path\":\"output.thd.left.thd_percent\",\"min\":5},"                    // and distorts
        "{\"path\":\"output.channels.1.nan\",\"equals\":0},"
        "{\"path\":\"bypass.exact\",\"equals\":false},"
        "{\"path\":\"output.channels.0.peak_db\",\"min\":3},"               // fails: it is not over full scale
        "{\"path\":\"output.nothing_here\",\"max\":1}]}");                 // fails: missing
    CHECK(r.boolean("ok", false));
    const Json& checks = at(r, {"checks"});
    CHECK_EQ(checks.arr.size(), size_t{6});
    const bool expected[] = {true, true, true, true, false, false};
    for (size_t k = 0; k < 6 && k < checks.arr.size(); ++k) CHECK(checks.arr[k].boolean("pass", !expected[k]) == expected[k]);
    CHECK(checks.arr.size() < 6 || checks.arr[5].get("value")->type == Json::Type::Null);
    CHECK(!r.boolean("passed", true));
    const Json good = run("{\"component\":\"org.caw.stereo.width\",\"signal\":\"pink\",\"cpu\":false,"
                          "\"checks\":[{\"path\":\"output.stereo.correlation\",\"min\":0.999,\"max\":1.001}]}");
    CHECK(good.boolean("passed", false));
    CHECK(run("{\"component\":\"org.caw.chorus\"}").get("passed") == nullptr);  // no checks, no verdict
    CHECK(!run("{\"component\":\"org.caw.chorus\",\"checks\":[{\"path\":\"x\"}]}").boolean("ok", true));
    CHECK(!run("{\"component\":\"org.caw.chorus\",\"checks\":[{\"path\":\"x\",\"equals\":\"y\"}]}").boolean("ok", true));
}
