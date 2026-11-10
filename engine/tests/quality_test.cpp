// Tests of the quality setting (Eco, Normal, High: what the built-ins do at each) and the device buffer mode's C API.
#include <cmath>
#include <cstring>
#include <string>
#include <vector>

#include "analysis.h"
#include "caw.h"
#include "engine.h"
#include "project.h"
#include "test.h"

using namespace caw;

namespace {

bool ok(const std::string& result) { return result.find("\"ok\":true") != std::string::npos; }

// One second of a track playing `notes` on `instrument` (with `effects`) at `quality`, interleaved.
std::vector<float> render(int quality, const std::string& instrument, const std::string& notes,
                          std::vector<std::pair<std::string, double>> params, std::vector<ComponentSpec> effects = {}) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n" + notes, {}});
    LayerSpec l;
    l.id = "t";
    l.name = "t";
    l.pattern = "pat";
    l.volume = 1.0;
    l.hasInstrument = true;
    l.instrument.id = instrument;
    l.instrument.params = std::move(params);
    l.components = std::move(effects);
    p.layers.push_back(l);
    Engine e(48000);
    e.setQuality(quality);
    std::vector<float> out;
    if (!ok(e.setProjectOffline(p))) return out;
    e.play();
    std::vector<float> a(256), b(256);
    for (int done = 0; done < 48000; done += 256) {
        e.process(a.data(), b.data(), 256);
        for (int i = 0; i < 256; ++i) out.push_back(a[static_cast<size_t>(i)]), out.push_back(b[static_cast<size_t>(i)]);
    }
    return out;
}

double difference(const std::vector<float>& a, const std::vector<float>& b) {
    double d = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) d += std::fabs(a[i] - b[i]);
    return d;
}

}  // namespace

TEST(the_quality_setting_is_clamped_and_reaches_the_c_api) {
    Engine e(48000);
    CHECK_EQ(e.quality(), 1);
    e.setQuality(7);
    CHECK_EQ(e.quality(), 2);
    e.setQuality(-3);
    CHECK_EQ(e.quality(), 0);
    CawEngine* c = caw_engine_create(48000);
    CHECK_EQ(caw_engine_quality(c), CAW_QUALITY_NORMAL);
    caw_engine_set_quality(c, CAW_QUALITY_ECO);
    CHECK_EQ(caw_engine_quality(c), CAW_QUALITY_ECO);
    // The buffer mode is kept with no device (this build has none) and reports no callback size.
    caw_audio_set_buffer_mode(c, CAW_BUFFER_BATTERY, 0);
    CHECK_EQ(caw_audio_buffer_frames(c), 0);
    caw_engine_destroy(c);
}

TEST(eco_quality_caps_flagship_unison_at_four_copies) {
    const std::string notes = "0 A3 8 1\n";
    // Eco plays 16 copies as 4, which is what 4 copies sound like at any quality.
    const std::vector<float> eco16 = render(0, "org.caw.synth.flagship", notes, {{"osc1_unison", 16}});
    const std::vector<float> normal4 = render(1, "org.caw.synth.flagship", notes, {{"osc1_unison", 4}});
    const std::vector<float> normal16 = render(1, "org.caw.synth.flagship", notes, {{"osc1_unison", 16}});
    CHECK(!eco16.empty());
    CHECK_EQ(difference(eco16, normal4), 0.0);
    CHECK(difference(eco16, normal16) > 1.0);
    // Fewer copies than the cap: Eco changes nothing.
    CHECK_EQ(difference(render(0, "org.caw.synth.flagship", notes, {{"osc1_unison", 3}}),
                        render(1, "org.caw.synth.flagship", notes, {{"osc1_unison", 3}})), 0.0);
}

TEST(the_saturator_oversamples_by_quality_and_the_reverb_thins_at_eco) {
    const std::string notes = "0 A4 4 1\n";
    const std::vector<std::pair<std::string, double>> bright = {{"osc1_unison", 1}, {"flt1_on", 0}, {"fx_reverb_on", 0}};
    auto sat = [&](int quality, double oversample) {
        return render(quality, "org.caw.synth.flagship", notes, bright,
                      {{"org.caw.saturator", {{"drive", 24}, {"oversample", oversample}}}});
    };
    // Eco: as the knob's Off. Normal: 2x. High: 4x, which aliases less still (less energy far from the harmonics).
    CHECK_EQ(difference(sat(0, 1), sat(1, 0)), 0.0);
    CHECK(difference(sat(1, 1), sat(1, 0)) > 1.0);
    const std::vector<float> high = sat(2, 1), normal = sat(1, 1);
    CHECK(difference(high, normal) > 0.1);
    for (float v : high) CHECK(std::isfinite(v) && std::fabs(v) <= 1.0f);
    // High with the knob off stays off.
    CHECK_EQ(difference(sat(2, 0), sat(1, 0)), 0.0);
    // The reverb: lighter at Eco (fewer all-passes, no modulation), the same at Normal and High.
    auto verb = [&](int quality) {
        return render(quality, "org.caw.synth.flagship", notes, bright, {{"org.caw.reverb.pro", {{"mix", 0.5}}}});
    };
    CHECK_EQ(difference(verb(1), verb(2)), 0.0);
    const std::vector<float> eco = verb(0), full = verb(1);
    CHECK(difference(eco, full) > 1.0);
    // Still a reverb at about the same level.
    CHECK_NEAR(analysis::levels(eco.data(), eco.size()).rmsDb, analysis::levels(full.data(), full.size()).rmsDb, 1.5);
}
