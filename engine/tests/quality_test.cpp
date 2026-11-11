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
    p.modules.push_back({"pat", "---\nkind: pattern\nname: P\nlength: 16\n---\n" + notes});
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

namespace {

// The loudest sample of a one-bar count-in at 120 BPM (4 clicks) with the click at [volume] and [sound].
float countInPeak(double volume, int sound, int* clickFrames = nullptr) {
    ProjectSpec p;
    p.bpm = 120;
    p.loopBars = 1;
    Engine e(48000);
    if (!ok(e.setProjectOffline(p))) return -1;
    e.setMetronomeSound(volume, sound);
    e.playCountIn(0, 1);
    std::vector<float> a(256), b(256);
    float peak = 0;
    int loud = 0;
    for (int done = 0; done < 24000; done += 256) {  // the first beat's click and its silence after
        e.process(a.data(), b.data(), 256);
        for (const float v : a) {
            peak = std::max(peak, std::fabs(v));
            if (std::fabs(v) > 1e-4f) ++loud;
        }
    }
    if (clickFrames) *clickFrames = loud;
    return peak;
}

}  // namespace

TEST(the_metronome_volume_and_sound_shape_the_click) {
    int classic = 0, tick = 0;
    const float full = countInPeak(1.0, CAW_CLICK_CLASSIC, &classic);
    const float half = countInPeak(0.5, CAW_CLICK_CLASSIC);
    CHECK(full > 0.3f);
    CHECK(std::fabs(half - full * 0.5f) < 0.02f);
    CHECK_EQ(countInPeak(0.0, CAW_CLICK_CLASSIC), 0.0f);
    countInPeak(1.0, CAW_CLICK_TICK, &tick);
    CHECK(tick > 0 && tick < classic / 2);  // the tick is far shorter
    // Out of range: the volume is clamped and an unknown sound is the classic click.
    CHECK(std::fabs(countInPeak(7.0, 99) - full) < 1e-6f);
    // Through the C API (no crash on NULL).
    caw_engine_set_metronome_sound(nullptr, 1, 0);
    CawEngine* c = caw_engine_create(48000);
    caw_engine_set_metronome_sound(c, 0.3, CAW_CLICK_WOOD);
    caw_engine_destroy(c);
}

TEST(the_test_tone_plays_while_stopped_and_ends) {
    Engine e(48000);
    CHECK(!e.testToneSounding());
    e.testTone(0.1);  // 4800 frames
    CHECK(e.testToneSounding());
    std::vector<float> a(512), b(512);
    float peak = 0;
    int crossings = 0;
    float last = 0;
    for (int done = 0; done < 4800; done += 512) {
        e.process(a.data(), b.data(), 512);
        for (size_t i = 0; i < a.size(); ++i) {
            peak = std::max(peak, std::fabs(a[i]));
            if (last < 0 && a[i] >= 0) ++crossings;
            last = a[i];
            CHECK_EQ(a[i], b[i]);
        }
    }
    CHECK(std::fabs(peak - 0.25f) < 0.01f);
    CHECK(crossings >= 42 && crossings <= 46);  // 440 Hz for 0.1 s
    e.process(a.data(), b.data(), 512);
    CHECK(!e.testToneSounding());
    for (const float v : a) CHECK_EQ(v, 0.0f);
    // Ended early: a 10 ms fade, then silence.
    e.testTone(5);
    e.process(a.data(), b.data(), 512);
    e.testTone(0);
    for (int i = 0; i < 2; ++i) e.process(a.data(), b.data(), 512);
    CHECK(!e.testToneSounding());
    CawEngine* c = caw_engine_create(48000);
    caw_engine_test_tone(c, 1);
    CHECK_EQ(caw_engine_test_tone_sounding(c), 1);
    caw_engine_test_tone(c, 0);
    caw_engine_destroy(c);
}

TEST(the_test_tone_flag_follows_what_the_audio_thread_plays) {
    std::vector<float> a(512), b(512);
    // Asked for and ended before the audio thread saw it: nothing sounds, and the flag says so (it used to stick).
    Engine e(48000);
    e.testTone(5);
    e.testTone(0);
    CHECK(!e.testToneSounding());
    e.process(a.data(), b.data(), 512);
    CHECK(!e.testToneSounding());
    for (const float v : a) CHECK_EQ(v, 0.0f);
    // Too short to be a sample at this rate: never sounding.
    e.testTone(1e-6);
    CHECK(!e.testToneSounding());
    e.process(a.data(), b.data(), 512);
    CHECK(!e.testToneSounding());
    // A new request while one still plays keeps it sounding through the old one's end.
    e.testTone(0.01);  // 480 frames: ends inside the next block
    e.process(a.data(), b.data(), 512);
    CHECK(!e.testToneSounding());
    e.testTone(0.01);
    e.process(a.data(), b.data(), 256);
    e.testTone(0.02);  // lands while the first still has frames left
    e.process(a.data(), b.data(), 256);  // the first ends here; the second is taken at the next callback
    CHECK(e.testToneSounding());
    e.process(a.data(), b.data(), 512);
    CHECK(e.testToneSounding());
    e.process(a.data(), b.data(), 512);
    CHECK(!e.testToneSounding());
}

TEST(the_device_choice_is_kept_without_a_device) {
    char* list = caw_audio_devices();
    CHECK(std::string(list).find("\"devices\":[") != std::string::npos);
    caw_free(list);
    CawEngine* c = caw_engine_create(48000);
    // Two identical interfaces share a name: the id tells them apart, the name is kept for when the id is gone.
    CHECK_EQ(caw_audio_configure(c, "{0.0.0.00000000}.{2}", "Speakers \"USB\"", 4, CAW_AUDIO_EXCLUSIVE | 8), 0);
    char* status = caw_audio_status(c);
    const std::string s = status;
    caw_free(status);
    CHECK(s.find("\"running\":false") != std::string::npos);
    CHECK(s.find("\"requested_device\":\"Speakers \\\"USB\\\"\"") != std::string::npos);
    CHECK(s.find("\"requested_device_id\":\"{0.0.0.00000000}.{2}\"") != std::string::npos);
    CHECK(s.find("\"requested_frames\":16") != std::string::npos);  // clamped to 16..8192
    CHECK(s.find("\"exclusive_requested\":true") != std::string::npos);
    CHECK_EQ(caw_audio_configure(c, nullptr, nullptr, 100000, 0), 0);
    status = caw_audio_status(c);
    CHECK(std::string(status).find("\"requested_frames\":8192") != std::string::npos);
    CHECK(std::string(status).find("\"requested_device_id\":\"\"") != std::string::npos);
    caw_free(status);
    CHECK_EQ(caw_audio_configure(nullptr, nullptr, nullptr, 0, 0), 1);
    caw_engine_destroy(c);
}
