// The sample browser's engine side (API 33, #229): the key estimate and the preview voice (playback, seek, stop, stretch, beat sync).
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <string>
#include <vector>

#include "asset_store.h"
#include "audio_analysis.h"
#include "caw.h"
#include "engine.h"
#include "json.h"
#include "sample_preview.h"
#include "test.h"
#include "utf8_path.h"
#include "wav.h"

using namespace caw;

namespace {

constexpr double kPi = 3.14159265358979323846;

struct TempRoot {
    std::filesystem::path path = std::filesystem::temp_directory_path() /
        ("caw_samples_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    ~TempRoot() { std::error_code ec; std::filesystem::remove_all(path, ec); }
};
std::string tempDir(const std::string& name) {
    static TempRoot root;
    const auto d = root.path / utf8Path(name);
    std::filesystem::remove_all(d);
    std::filesystem::create_directories(d);
    return pathText(d);
}

template <class F>
std::string writeWav(const std::string& path, int rate, int64_t frames, F sample) {
    std::vector<float> x(static_cast<size_t>(frames * 2));
    for (int64_t i = 0; i < frames; ++i)
        for (int c = 0; c < 2; ++c) x[static_cast<size_t>(i * 2 + c)] = sample(i, c);
    WavSpec s;
    s.sampleRate = rate;
    s.channels = 2;
    s.float32 = true;
    std::string error;
    CHECK(writeFile(path, encodeWav(s, x.data(), frames), error));
    return path;
}

std::string cjson(char* p) {
    std::string s = p ? p : "";
    caw_free(p);
    return s;
}

// A chord progression (MIDI notes per chord, a second each) as an asset, each note with three falling harmonics.
std::shared_ptr<AudioAsset> chords(const std::vector<std::vector<int>>& progression, double seconds = 1.0) {
    auto a = std::make_shared<AudioAsset>();
    a->rate = a->sourceRate = 48000;
    a->channels = a->sourceChannels = 1;
    const int64_t per = static_cast<int64_t>(seconds * 48000);
    a->frames = a->sourceFrames = per * static_cast<int64_t>(progression.size());
    a->data[0].assign(static_cast<size_t>(a->frames), 0.0f);
    for (size_t c = 0; c < progression.size(); ++c)
        for (int note : progression[c]) {
            const double f = 440.0 * std::pow(2.0, (note - 69) / 12.0);
            for (int64_t i = 0; i < per; ++i) {
                const double t = static_cast<double>(i) / 48000.0;
                double v = 0;
                for (int h = 1; h <= 3; ++h) v += std::sin(2 * kPi * f * h * t) / (h * h);
                a->data[0][static_cast<size_t>(c * per + i)] += static_cast<float>(0.08 * v * std::exp(-t));
            }
        }
    return a;
}

double rmsOf(const std::vector<float>& x, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to; ++i) s += static_cast<double>(x[i]) * x[i];
    return std::sqrt(s / std::max<size_t>(1, to - from));
}

}  // namespace

TEST(key_estimate_finds_major_and_minor_progressions) {
    struct Case {
        std::vector<std::vector<int>> chords;
        int tonic;
        bool minor;
    };
    const Case cases[] = {
        {{{60, 64, 67}, {65, 69, 72}, {67, 71, 74}, {60, 64, 67}}, 0, false},   // C F G C
        {{{57, 60, 64}, {62, 65, 69}, {64, 68, 71}, {57, 60, 64}}, 9, true},    // Am Dm E Am
        {{{55, 59, 62}, {60, 64, 67}, {62, 66, 69}, {55, 59, 62}}, 7, false},   // G C D G
        {{{54, 57, 61}, {59, 62, 66}, {61, 65, 68}, {54, 57, 61}}, 6, true},    // F#m Bm C# F#m
    };
    for (const Case& c : cases) {
        const KeyResult r = detectKey(*chords(c.chords), KeyOptions{});
        if (r.tonic != c.tonic || r.minor != c.minor)
            std::printf("  expected %d%s, found %d%s (confidence %.2f)\n", c.tonic, c.minor ? "m" : "", r.tonic,
                        r.minor ? "m" : "", r.confidence);
        CHECK_EQ(r.tonic, c.tonic);
        CHECK(r.minor == c.minor);
        CHECK(r.sure);
        CHECK(r.confidence > 0.1 && r.confidence <= 1.0);
        CHECK_EQ(r.candidates.size(), 5u);
        CHECK_NEAR(*std::max_element(r.chroma, r.chroma + 12), 1.0, 1e-12);
    }
    // Silence and a file too short to read give no key.
    auto silent = chords({{}, {}});
    CHECK(!detectKey(*silent, KeyOptions{}).sure);
    auto blip = chords({{60}}, 0.05);
    CHECK(!detectKey(*blip, KeyOptions{}).sure);
}

TEST(key_estimate_through_the_c_api_with_option_limits) {
    const std::string dir = tempDir("key");
    const std::string p = writeWav(dir + "/am.wav", 44100, 44100 * 3, [](int64_t i, int) {
        const double t = static_cast<double>(i) / 44100.0;
        double v = 0;
        for (double f : {220.0, 261.63, 329.63}) v += std::sin(2 * kPi * f * t);  // A minor
        return static_cast<float>(0.15 * v);
    });
    CawEngine* ce = caw_engine_create(48000);
    CHECK(ce != nullptr);
    Json j;
    std::string error;
    CHECK(parseJson(cjson(caw_asset_key(ce, p.c_str(), nullptr)), j, error));
    CHECK(j.boolean("ok", false));
    CHECK_EQ(static_cast<int>(j.number("tonic", -1)), 9);
    CHECK(j.string("mode") == "minor");
    CHECK(j.string("name") == "A minor");
    CHECK(j.get("chroma") && j.get("chroma")->arr.size() == 12);
    for (const char* bad : {"{\"start_seconds\":-1}", "{\"end_seconds\":1,\"start_seconds\":2}", "[1]", "{x",
                            "{\"end_seconds\":\"end\"}"}) {
        const std::string r = cjson(caw_asset_key(ce, p.c_str(), bad));
        if (r.find("\"ok\":false") == std::string::npos) std::printf("  accepted: %s\n", bad);
        CHECK(r.find("\"ok\":false") != std::string::npos);
    }
    CHECK(cjson(caw_asset_key(ce, (dir + "/missing.wav").c_str(), nullptr)).find("\"ok\":false") != std::string::npos);
    CHECK(cjson(caw_asset_key(nullptr, p.c_str(), nullptr)).find("\"ok\":false") != std::string::npos);
    caw_engine_destroy(ce);
}

TEST(preview_options_are_parsed_with_limits) {
    PreviewOptions o;
    std::string error;
    CHECK(parsePreviewOptions(nullptr, o, error));
    CHECK(parsePreviewOptions("{\"start_seconds\":1.5,\"stretch_ratio\":2,\"sync\":\"bar\",\"loop\":true,\"volume\":0.5}", o,
                              error));
    CHECK_NEAR(o.startSeconds, 1.5, 1e-12);
    CHECK_NEAR(o.ratio, 2.0, 1e-12);
    CHECK_EQ(o.sync, 2);
    CHECK(o.loop);
    CHECK_NEAR(o.volume, 0.5, 1e-12);
    const std::string big = "{\"pad\":\"" + std::string(5000, 'x') + "\"}";
    for (const std::string& bad : {big, std::string("{\"stretch_ratio\":5}"), std::string("{\"stretch_ratio\":0.1}"),
                                   std::string("{\"sync\":\"soon\"}"), std::string("{\"sync\":1}"),
                                   std::string("{\"loop\":1}"), std::string("{\"volume\":2}"),
                                   std::string("{\"start_seconds\":-0.5}"), std::string("[true]"), std::string("{")}) {
        PreviewOptions p;
        if (parsePreviewOptions(bad.c_str(), p, error)) std::printf("  accepted: %.60s\n", bad.c_str());
        CHECK(!parsePreviewOptions(bad.c_str(), p, error));
    }
}

TEST(preview_plays_a_file_stopped_seeks_and_fades_out_on_stop) {
    const std::string dir = tempDir("preview");
    const std::string p = writeWav(dir + "/s.wav", 48000, 48000, [](int64_t i, int) {
        return static_cast<float>(0.25 * std::sin(2 * kPi * 1000.0 * static_cast<double>(i) / 48000.0));
    });
    CawEngine* ce = caw_engine_create(48000);
    CHECK(ce != nullptr);
    std::vector<float> l(4800), r(4800);
    caw_engine_process(ce, l.data(), r.data(), 4800);
    CHECK(rmsOf(l, 0, l.size()) == 0.0);
    Json j;
    std::string error;
    CHECK(parseJson(cjson(caw_engine_preview_sample(ce, p.c_str(), nullptr)), j, error));
    CHECK(j.boolean("ok", false));
    CHECK_NEAR(j.number("seconds", 0), 1.0, 1e-9);
    CHECK_NEAR(j.number("stretch_ratio", 0), 1.0, 1e-12);
    CHECK_EQ(static_cast<int>(j.number("seq", 0)), 1);
    caw_engine_process(ce, l.data(), r.data(), 4800);
    // After the 256-sample fade in, the file at the preview's volume (0.8), the same on both sides.
    double worst = 0;
    for (size_t i = 300; i < l.size(); ++i) {
        const double want = 0.8 * 0.25 * std::sin(2 * kPi * 1000.0 * static_cast<double>(i) / 48000.0);
        worst = std::max({worst, std::fabs(l[i] - want), std::fabs(r[i] - want)});
    }
    CHECK(worst < 1e-5);
    CawSamplePreviewState st{};
    CHECK_EQ(caw_engine_preview_sample_state(ce, &st), 0);
    CHECK_EQ(st.playing, 1);
    CHECK_EQ(st.waiting, 0);
    CHECK_NEAR(st.seconds, 0.1, 1e-9);
    CHECK_NEAR(st.length, 1.0, 1e-9);
    CHECK_EQ(st.seq, 1);
    caw_engine_preview_sample_seek(ce, 0.5);
    caw_engine_process(ce, l.data(), r.data(), 480);
    CHECK_EQ(caw_engine_preview_sample_state(ce, &st), 0);
    CHECK_NEAR(st.seconds, 0.51, 1e-9);
    // Volume: half after the smoothing settles.
    caw_engine_preview_sample_volume(ce, 0.4);
    caw_engine_process(ce, l.data(), r.data(), 4800);
    CHECK_NEAR(rmsOf(l, 4000, 4800), 0.4 * 0.25 / std::sqrt(2.0), 2e-3);
    caw_engine_preview_sample_stop(ce);
    caw_engine_process(ce, l.data(), r.data(), 480);
    CHECK(rmsOf(l, 0, 64) > 0.01);   // it fades, it does not cut
    CHECK(rmsOf(l, 300, 480) == 0.0);
    CHECK_EQ(caw_engine_preview_sample_state(ce, &st), 0);
    CHECK_EQ(st.playing, 0);
    // A one-shot ends by itself; a loop goes on.
    CHECK(cjson(caw_engine_preview_sample(ce, p.c_str(), "{\"start_seconds\":0.9}")).find("\"ok\":true") != std::string::npos);
    for (int k = 0; k < 2; ++k) caw_engine_process(ce, l.data(), r.data(), 4800);
    CHECK_EQ(caw_engine_preview_sample_state(ce, &st), 0);
    CHECK_EQ(st.playing, 0);
    CHECK(cjson(caw_engine_preview_sample(ce, p.c_str(), "{\"start_seconds\":0.9,\"loop\":true}")).find("\"ok\":true") !=
          std::string::npos);
    for (int k = 0; k < 2; ++k) caw_engine_process(ce, l.data(), r.data(), 4800);
    CHECK_EQ(caw_engine_preview_sample_state(ce, &st), 0);
    CHECK_EQ(st.playing, 1);
    CHECK_EQ(st.seq, 3);
    CHECK(rmsOf(l, 0, l.size()) > 0.05);
    // A missing file and bad options fail with their reason; nothing changes.
    CHECK(cjson(caw_engine_preview_sample(ce, (dir + "/none.wav").c_str(), nullptr)).find("\"ok\":false") != std::string::npos);
    CHECK(cjson(caw_engine_preview_sample(ce, p.c_str(), "{\"sync\":\"later\"}")).find("sync") != std::string::npos);
    CHECK_EQ(caw_engine_preview_sample_state(nullptr, &st), -1);
    caw_engine_destroy(ce);
}

TEST(preview_stretches_to_a_tempo_and_starts_on_the_next_beat_while_playing) {
    const std::string dir = tempDir("sync");
    const std::string p = writeWav(dir + "/s.wav", 48000, 48000, [](int64_t i, int) {
        return static_cast<float>(0.25 * std::sin(2 * kPi * 440.0 * static_cast<double>(i) / 48000.0));
    });
    std::string error;
    auto asset = AssetStore::global().load(p, 48000, error);
    CHECK(asset != nullptr);
    if (!asset) return;
    // Stretched: twice as long, the same pitch region (its level holds up through the middle).
    {
        Engine e(48000);
        PreviewOptions o;
        o.ratio = 2;
        double ratio = 0;
        CHECK(e.samplePreview().start(asset, o, error, &ratio));
        CHECK_NEAR(ratio, 2.0, 1e-12);
        std::vector<float> l(48000), r(48000);
        e.process(l.data(), r.data(), 48000);
        e.process(l.data(), r.data(), 24000);
        CHECK(rmsOf(l, 4000, 20000) > 0.1);
        SamplePreview::State st = e.samplePreview().state();
        CHECK(st.playing);
        CHECK_NEAR(st.length, 1.0, 1e-9);
        CHECK_NEAR(st.seconds, 0.75, 1e-9);  // 1.5 s of output are 0.75 s of the file
        e.process(l.data(), r.data(), 24000);
        e.process(l.data(), r.data(), 4800);
        CHECK(!e.samplePreview().state().playing);
    }
    // In time with the song: at 120 BPM a beat is 24000 samples; asked 1000 samples in, it starts at 24000.
    {
        Engine e(48000);
        CHECK(e.setProjectJson("{\"caw_project\":1,\"bpm\":120,\"loop_bars\":4,\"master\":1,\"layers\":[]}")
                  .find("\"ok\":true") != std::string::npos);
        std::vector<float> l(1000), r(1000);
        e.play();
        e.process(l.data(), r.data(), 1000);
        PreviewOptions o;
        o.sync = 1;
        CHECK(e.samplePreview().start(asset, o, error));
        std::vector<float> out(48000), right(48000);
        e.process(out.data(), right.data(), 48000);
        size_t first = out.size();
        for (size_t i = 0; i < out.size(); ++i)
            if (std::fabs(out[i]) > 1e-7) {
                first = i;
                break;
            }
        CHECK_EQ(first, 23001u);  // frame 24000 of the song; its first sample is 0 (sin 0), the next one sounds
        // On the next bar instead: 4/4 at 120 is 96000 samples.
        Engine b(48000);
        CHECK(b.setProjectJson("{\"caw_project\":1,\"bpm\":120,\"loop_bars\":4,\"master\":1,\"layers\":[]}")
                  .find("\"ok\":true") != std::string::npos);
        b.play();
        b.process(l.data(), r.data(), 1000);
        o.sync = 2;
        CHECK(b.samplePreview().start(asset, o, error));
        b.process(out.data(), right.data(), 48000);
        CHECK(b.samplePreview().state().waiting);
        CHECK(rmsOf(out, 0, out.size()) == 0.0);
    }
    // Stopped, a synced start plays at once.
    {
        Engine e(48000);
        PreviewOptions o;
        o.sync = 2;
        CHECK(e.samplePreview().start(asset, o, error));
        std::vector<float> l(4800), r(4800);
        e.process(l.data(), r.data(), 4800);
        CHECK(rmsOf(l, 0, l.size()) > 0.05);
    }
}

TEST(preview_plays_through_a_tracks_effects_when_asked) {
    // The browser's "through the track" toggle: the preview joins the track after its instrument, so its volume and
    // pan (and inserts) shape it, stopped or playing; muted, or for an unknown id, it goes to the master as before.
    const std::string dir = tempDir("through");
    const std::string p = writeWav(dir + "/s.wav", 48000, 48000, [](int64_t i, int) {
        return static_cast<float>(0.25 * std::sin(2 * kPi * 500.0 * static_cast<double>(i) / 48000.0));
    });
    const char* project = R"({"caw_project":1,"bpm":120,"master":1,
        "layers":[{"id":"t","volume":0.5,"pan":-1,"input":{"channel":0,"channels":1,"monitor":"off"}},
                  {"id":"m","volume":1,"mute":true,"input":{"channel":0,"channels":1,"monitor":"off"}}]})";
    CawEngine* ce = caw_engine_create(48000);
    CHECK(ce != nullptr);
    if (!ce) return;
    const std::string set = cjson(caw_engine_set_project(ce, project));
    CHECK(set.find("\"ok\":true") != std::string::npos);
    std::vector<float> l(4800), r(4800);
    caw_engine_process(ce, l.data(), r.data(), 4800);
    auto play = [&](const char* options) { return cjson(caw_engine_preview_sample(ce, p.c_str(), options)); };
    auto settle = [&] {
        for (int k = 0; k < 3; ++k) caw_engine_process(ce, l.data(), r.data(), 4800);
    };
    // Stopped, through "t": hard left at half volume, nothing on the right.
    CHECK(play(R"({"layer":"t","loop":true})").find("\"layer\":true") != std::string::npos);
    settle();
    CawSamplePreviewState st{};
    CHECK_EQ(caw_engine_preview_sample_state(ce, &st), 0);
    CHECK_EQ(st.through, 1);
    CHECK_NEAR(rmsOf(l, 2400, 4800), 0.5 * 0.8 * 0.25 / std::sqrt(2.0), 3e-3);
    CHECK(rmsOf(r, 2400, 4800) < 1e-6);
    // Playing, the same.
    caw_engine_play(ce);
    settle();
    CHECK_NEAR(rmsOf(l, 2400, 4800), 0.5 * 0.8 * 0.25 / std::sqrt(2.0), 3e-3);
    CHECK(rmsOf(r, 2400, 4800) < 1e-6);
    caw_engine_stop(ce);
    settle();
    // A muted track doesn't run: the preview plays straight, on both sides.
    CHECK(play(R"({"layer":"m","loop":true})").find("\"layer\":true") != std::string::npos);
    settle();
    CHECK_EQ(caw_engine_preview_sample_state(ce, &st), 0);
    CHECK_EQ(st.through, 0);
    CHECK_NEAR(rmsOf(r, 2400, 4800), 0.8 * 0.25 / std::sqrt(2.0), 3e-3);
    // An unknown track: straight too, and the answer says so.
    CHECK(play(R"({"layer":"nope","loop":true})").find("\"layer\":false") != std::string::npos);
    settle();
    CHECK_NEAR(rmsOf(r, 2400, 4800), 0.8 * 0.25 / std::sqrt(2.0), 3e-3);
    // Without a layer, as before.
    play(R"({"loop":true})");
    settle();
    CHECK_NEAR(rmsOf(l, 2400, 4800), 0.8 * 0.25 / std::sqrt(2.0), 3e-3);
    CHECK(cjson(caw_engine_preview_sample(ce, p.c_str(), R"({"layer":7})")).find("layer must be") != std::string::npos);
    caw_engine_destroy(ce);
}
