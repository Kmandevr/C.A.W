// The sampler's tools (API 43): root detection, drop-and-play mapping, slicing, recorded takes, and stretched zones.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <filesystem>
#include <string>
#include <vector>

#include "asset_store.h"
#include "caw.h"
#include "engine.h"
#include "json.h"
#include "presets.h"
#include "sampler_tools.h"
#include "test.h"
#include "utf8_path.h"
#include "wav.h"

using namespace caw;

namespace {

constexpr double kPi = 3.14159265358979323846;

std::string tempDir(const std::string& name) {
    static const std::filesystem::path root = std::filesystem::temp_directory_path() /
        ("caw_magpie_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    const auto d = root / utf8Path(name);
    std::filesystem::remove_all(d);
    std::filesystem::create_directories(d);
    return pathText(d);
}

template <class F>
std::string writeWav(const std::string& path, int rate, int64_t frames, F sample) {
    std::vector<float> x(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; ++i) x[static_cast<size_t>(i)] = sample(i);
    WavSpec s;
    s.sampleRate = rate;
    s.channels = 1;
    s.float32 = true;
    std::string error;
    CHECK(writeFile(path, encodeWav(s, x.data(), frames), error));
    return path;
}

double midiHz(double m) { return 440.0 * std::pow(2.0, (m - 69.0) / 12.0); }

// A decaying tone with a few harmonics (a plucked note) at `hz`, `seconds` long.
std::string tone(const std::string& path, double hz, double seconds = 1.0, int rate = 48000) {
    return writeWav(path, rate, static_cast<int64_t>(seconds * rate), [&](int64_t i) {
        const double t = static_cast<double>(i) / rate;
        const double env = std::min(1.0, t / 0.005) * std::exp(-1.5 * t);
        return static_cast<float>(0.4 * env * (std::sin(2 * kPi * hz * t) + 0.5 * std::sin(4 * kPi * hz * t) +
                                               0.25 * std::sin(6 * kPi * hz * t)));
    });
}

std::shared_ptr<const AudioAsset> load(const std::string& path) {
    std::string error;
    auto a = AssetStore::global().load(path, 48000, error);
    CHECK(a != nullptr);
    return a;
}

std::string b64(const std::string& s) { return base64Encode(reinterpret_cast<const uint8_t*>(s.data()), s.size()); }

// One note (a MIDI key) at step 0 held `steps` sixteenths, the sampler playing `state`; the left channel, in blocks.
std::vector<float> play(const std::string& state, int key, int64_t frames, int block = 512, double bpm = 120,
                        double steps = 2) {
    const std::string pattern = "---\\nkind: pattern\\nlength: 64\\n---\\n0 " + std::to_string(key) + " " +
                                std::to_string(steps) + " 1\\n";
    const std::string json = "{\"caw_project\":1,\"bpm\":" + std::to_string(bpm) +
        ",\"loop_bars\":4,\"master\":1,\"modules\":[{\"id\":\"p\",\"source\":\"" + pattern +
        "\"}],\"layers\":[{\"id\":\"s\",\"name\":\"S\",\"volume\":1,\"pattern\":\"p\",\"instrument\":{\"id\":\"org.caw.sampler\","
        "\"params\":{\"attack\":0,\"release\":0.01},\"state\":\"" + b64(state) + "\"}}]}";
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string r = e.setProjectJson(json);
    CHECK(r.find("\"ok\":true") != std::string::npos);
    e.play(0);
    std::vector<float> l(static_cast<size_t>(frames)), rr(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += block)
        e.process(l.data() + i, rr.data() + i, static_cast<int>(std::min<int64_t>(block, frames - i)));
    return l;
}

double risingPerSecond(const std::vector<float>& x, size_t from, size_t to) {
    int n = 0;
    for (size_t i = from + 1; i < to; ++i) n += x[i - 1] < 0 && x[i] >= 0;
    return n * 48000.0 / static_cast<double>(to - from);
}

// The last frame louder than -50 dBFS.
size_t lastLoud(const std::vector<float>& x) {
    for (size_t i = x.size(); i-- > 0;)
        if (std::fabs(x[i]) > 0.003f) return i;
    return 0;
}

Json parsed(char* text) {
    Json j;
    std::string error;
    CHECK(text != nullptr);
    if (text) {
        CHECK(parseJson(text, j, error));
        caw_free(text);
    }
    return j;
}

}  // namespace

TEST(sampler_root_detection_finds_the_note_and_says_when_unsure) {
    const std::string dir = tempDir("root");
    for (double m : {40.0, 45.0, 57.0, 60.0, 69.0, 84.0, 96.0}) {
        const RootResult r = detectRoot(*load(tone(dir + "/t" + std::to_string(static_cast<int>(m)) + ".wav", midiHz(m))));
        CHECK(r.sure);
        CHECK_EQ(r.root, static_cast<int>(m));
        CHECK_NEAR(r.cents, 0.0, 5.0);
    }
    // 30 cents sharp: the root is still the note, with the cents to tune it by.
    const RootResult sharp = detectRoot(*load(tone(dir + "/sharp.wav", midiHz(60.3))));
    CHECK(sharp.sure);
    CHECK_EQ(sharp.root, 60);
    CHECK_NEAR(sharp.cents, 30.0, 5.0);
    // Noise and silence have no root.
    uint32_t seed = 1;
    const RootResult noise = detectRoot(*load(writeWav(dir + "/noise.wav", 48000, 48000, [&](int64_t) {
        seed = seed * 1664525u + 1013904223u;
        return static_cast<float>((seed >> 8) / 8388608.0 - 1.0) * 0.5f;
    })));
    CHECK(!noise.sure);
    const RootResult quiet = detectRoot(*load(writeWav(dir + "/silence.wav", 48000, 48000, [](int64_t) { return 0.0f; })));
    CHECK(!quiet.sure);
    // A 44.1 kHz file is resampled first: the same note.
    const RootResult cd = detectRoot(*load(tone(dir + "/cd.wav", midiHz(64), 1.0, 44100)));
    CHECK(cd.sure);
    CHECK_EQ(cd.root, 64);
}

TEST(sampler_mapping_covers_the_keyboard_by_root_or_evenly) {
    // One sample: the whole keyboard, at its root (tuned by its cents).
    auto one = mapSamples({{"/a.wav", 62, 20}}, MapMode::Auto, 36);
    CHECK_EQ(one.size(), size_t{1});
    CHECK_EQ(one[0].lokey, 0);
    CHECK_EQ(one[0].hikey, 127);
    CHECK_EQ(one[0].root, 62);
    CHECK_NEAR(one[0].tune, -20.0, 1e-9);
    // An unknown root: still the whole keyboard, at C4.
    auto unknown = mapSamples({{"/a.wav", -1, 0}}, MapMode::Auto, 36);
    CHECK_EQ(unknown[0].lokey, 0);
    CHECK_EQ(unknown[0].hikey, 127);
    CHECK_EQ(unknown[0].root, 60);
    // Several roots: split halfway, the ends to the keyboard's ends, order kept, shared roots take turns.
    MapMode used = MapMode::Auto;
    auto by = mapSamples({{"/c5.wav", 72, 0}, {"/c3.wav", 48, 0}, {"/c4.wav", 60, 0}, {"/c4b.wav", 60, 0}},
                         MapMode::Auto, 36, &used);
    CHECK(used == MapMode::Root);
    CHECK_EQ(by[1].lokey, 0);
    CHECK_EQ(by[1].hikey, 53);
    CHECK_EQ(by[2].lokey, 54);
    CHECK_EQ(by[2].hikey, 65);
    CHECK_EQ(by[3].lokey, 54);
    CHECK_EQ(by[0].lokey, 66);
    CHECK_EQ(by[0].hikey, 127);
    CHECK_EQ(by[2].seqLength, 2);
    CHECK_EQ(by[3].seqPosition, 2);
    CHECK_EQ(by[0].seqLength, 1);
    // Any unknown root: spread evenly, each at its range's middle; no gaps or overlaps.
    auto spread = mapSamples({{"/k.wav", 40, 0}, {"/s.wav", -1, 0}, {"/h.wav", -1, 0}}, MapMode::Auto, 36, &used);
    CHECK(used == MapMode::Spread);
    CHECK_EQ(spread[0].lokey, 0);
    CHECK_EQ(spread[2].hikey, 127);
    for (size_t i = 1; i < spread.size(); ++i) CHECK_EQ(spread[i].lokey, spread[i - 1].hikey + 1);
    for (const auto& z : spread) CHECK(z.root >= z.lokey && z.root <= z.hikey);
    // Keys: one each from the start key.
    auto keys = mapSamples({{"/k.wav", -1, 0}, {"/s.wav", -1, 0}}, MapMode::Keys, 36);
    CHECK_EQ(keys[1].lokey, 37);
    CHECK_EQ(keys[1].hikey, 37);
    CHECK_EQ(keys[1].root, 37);
}

TEST(sampler_map_api_detects_roots_and_a_dropped_sample_plays_on_every_key) {
    const std::string dir = tempDir("map");
    const std::string a3 = tone(dir + "/a3.wav", midiHz(57));
    CawEngine* e = caw_engine_create(48000);
    Json j = parsed(caw_sampler_map(e, ("{\"samples\":[{\"path\":\"" + jsonEscape(a3) + "\"}]}").c_str()));
    CHECK(j.boolean("ok", false));
    CHECK_EQ(j.string("mode"), std::string("root"));
    const Json* zones = j.get("state") ? j.get("state")->get("zones") : nullptr;
    CHECK(zones && zones->arr.size() == 1);
    if (zones && zones->arr.size() == 1) {
        CHECK_EQ(zones->arr[0].number("lokey", -1), 0.0);
        CHECK_EQ(zones->arr[0].number("hikey", -1), 127.0);
        CHECK_EQ(zones->arr[0].number("pitch_keycenter", -1), 57.0);
    }
    // The state plays at once: an octave up sounds an octave up; far keys still sound.
    SamplerProgram p;
    p.zones = mapSamples({{a3, 57, 0}}, MapMode::Auto, 36);
    const std::string state = samplerStateJson(p);
    auto x = play(state, 69, 24000);
    CHECK_NEAR(risingPerSecond(x, 2000, 11000), 440.0, 8.0);
    x = play(state, 33, 24000);
    CHECK(*std::max_element(x.begin(), x.end()) > 0.05f);
    // Errors name the key.
    j = parsed(caw_sampler_map(e, "{\"samples\":[]}"));
    CHECK(!j.boolean("ok", true));
    j = parsed(caw_sampler_map(e, "{\"samples\":[{\"path\":\"/x.wav\",\"root\":200}]}"));
    CHECK(j.string("error").find("root") != std::string::npos);
    j = parsed(caw_sampler_map(e, "{\"samples\":[{\"path\":\"/x.wav\"}],\"mode\":\"zig\"}"));
    CHECK(j.string("error").find("mode") != std::string::npos);
    caw_engine_destroy(e);
}

TEST(sampler_slicing_by_transients_and_grid_maps_slices_to_keys) {
    const std::string dir = tempDir("slice");
    // Four hits a quarter second apart.
    const std::string loop = writeWav(dir + "/loop.wav", 48000, 48000, [](int64_t i) {
        const int64_t k = i % 12000;
        return static_cast<float>(0.8 * std::exp(-k / 600.0) * std::sin(2 * kPi * 180.0 * k / 48000.0));
    });
    CawEngine* e = caw_engine_create(48000);
    Json j = parsed(caw_sampler_slice(e, loop.c_str(), "{\"start_key\":48}"));
    CHECK(j.boolean("ok", false));
    const Json* slices = j.get("slices");
    CHECK(slices && slices->arr.size() == 4);
    if (slices && slices->arr.size() == 4) {
        for (size_t i = 0; i < 4; ++i) {
            CHECK_NEAR(slices->arr[i].number("start", -1), 12000.0 * i, 240.0);
            CHECK_EQ(slices->arr[i].number("key", -1), 48.0 + i);
        }
        CHECK_EQ(slices->arr[3].number("end", -1), 48000.0);
    }
    const Json* zones = j.get("state") ? j.get("state")->get("zones") : nullptr;
    CHECK(zones && zones->arr.size() == 4);
    if (zones && zones->arr.size() == 4) {
        CHECK_EQ(zones->arr[1].string("loop_mode"), std::string("one_shot"));
        CHECK_EQ(zones->arr[1].number("end", 0) + 1, zones->arr[2].number("offset", 0));
    }
    // A grid: equal parts.
    j = parsed(caw_sampler_slice(e, loop.c_str(), "{\"by\":\"grid\",\"divisions\":8}"));
    slices = j.get("slices");
    CHECK(slices && slices->arr.size() == 8);
    if (slices && slices->arr.size() == 8) CHECK_EQ(slices->arr[5].number("start", -1), 30000.0);
    j = parsed(caw_sampler_slice(e, loop.c_str(), "{\"by\":\"grid\",\"divisions\":0}"));
    CHECK(j.string("error").find("divisions") != std::string::npos);
    // A slice's key plays just that slice.
    SamplerProgram p;
    p.zones = sliceZones(loop, {12000, 24000, 36000}, 48000, 48);
    auto x = play(samplerStateJson(p), 49, 36000);
    CHECK(*std::max_element(x.begin(), x.begin() + 11000) > 0.3f);
    CHECK(lastLoud(x) < 12500);
    caw_engine_destroy(e);
}

TEST(sampler_take_is_cut_into_zones_note_by_note) {
    const std::string dir = tempDir("take");
    // Notes 48, 60 and 72 played at 0.6 s, 2.1 s and 3.5 s of the take (late, as a player is); 84 never played.
    const double at[3] = {0.6, 2.1, 3.5};
    const double notes[3] = {48, 60, 72};
    const std::string take = writeWav(dir + "/take.wav", 48000, 48000 * 6, [&](int64_t i) {
        const double t = i / 48000.0;
        double v = 0;
        for (int k = 0; k < 3; ++k)
            if (t >= at[k] && t < at[k] + 1.0) {
                const double u = t - at[k];
                v += 0.5 * std::min(1.0, u / 0.005) * std::exp(-2 * u) * std::sin(2 * kPi * midiHz(notes[k]) * u);
            }
        return static_cast<float>(v);
    });
    const std::string req = "{\"path\":\"" + jsonEscape(take) + "\",\"notes\":["
        "{\"key\":48,\"start_seconds\":0.5,\"end_seconds\":1.9},{\"key\":60,\"start_seconds\":2.0,\"end_seconds\":3.4},"
        "{\"key\":72,\"start_seconds\":3.4,\"end_seconds\":4.8},{\"key\":84,\"start_seconds\":4.8,\"end_seconds\":5.9}]}";
    CawEngine* e = caw_engine_create(48000);
    Json j = parsed(caw_sampler_take(e, req.c_str()));
    CHECK(j.boolean("ok", false));
    const Json* res = j.get("notes");
    CHECK(res && res->arr.size() == 4);
    if (res && res->arr.size() == 4) {
        for (int k = 0; k < 3; ++k) {
            CHECK(res->arr[k].boolean("found", false));
            CHECK(res->arr[k].boolean("in_tune", false));
            CHECK_NEAR(res->arr[k].number("start", 0), at[k] * 48000, 200.0);
        }
        CHECK(!res->arr[3].boolean("found", true));
    }
    const Json* zones = j.get("state") ? j.get("state")->get("zones") : nullptr;
    CHECK(zones && zones->arr.size() == 3);
    if (zones && zones->arr.size() == 3) {
        CHECK_EQ(zones->arr[0].number("lokey", -1), 0.0);
        CHECK_EQ(zones->arr[0].number("hikey", -1), 53.0);
        CHECK_EQ(zones->arr[2].number("hikey", -1), 127.0);
        CHECK_EQ(zones->arr[1].number("pitch_keycenter", -1), 60.0);
    }
    j = parsed(caw_sampler_take(e, "{\"path\":\"/x.wav\",\"notes\":[{\"key\":60,\"start_seconds\":2,\"end_seconds\":1}]}"));
    CHECK(!j.boolean("ok", true));
    caw_engine_destroy(e);
}

TEST(sampler_stretched_zone_keeps_its_length_on_every_key) {
    const std::string dir = tempDir("stretch");
    // A steady 440 Hz second.
    const std::string a4 = writeWav(dir + "/a4.wav", 48000, 48000, [](int64_t i) {
        return static_cast<float>(0.5 * std::sin(2 * kPi * 440.0 * i / 48000.0));
    });
    auto state = [&](const std::string& extra) {
        return "{\"zones\":[{\"path\":\"" + jsonEscape(a4) + "\",\"pitch_keycenter\":69,\"loop_mode\":\"one_shot\"" + extra + "}]}";
    };
    // Plain: an octave up plays twice as fast, half as long.
    auto plain = play(state(""), 81, 72000);
    CHECK_NEAR(static_cast<double>(lastLoud(plain)), 24000.0, 600.0);
    // Stretched: the octave up keeps the second, an octave down too, each at its pitch.
    for (int key : {81, 57, 69}) {
        auto x = play(state(",\"stretch\":true"), key, 72000);
        CHECK_NEAR(static_cast<double>(lastLoud(x)), 48000.0, 2400.0);
        CHECK_NEAR(risingPerSecond(x, 9600, 40000), 440.0 * std::pow(2.0, (key - 69) / 12.0), 440.0 * std::pow(2.0, (key - 69) / 12.0) * 0.02);
    }
    // With the sample's tempo: a 60 BPM sample in a 120 BPM song plays in half the time, at its pitch.
    auto fast = play(state(",\"stretch\":true,\"stretch_bpm\":60"), 69, 72000);
    CHECK_NEAR(static_cast<double>(lastLoud(fast)), 24000.0, 2400.0);
    CHECK_NEAR(risingPerSecond(fast, 4800, 20000), 440.0, 9.0);
    // The state keeps the keys and refuses a tempo below 20.
    SamplerProgram p;
    std::string error;
    CHECK(parseSamplerState(state(",\"stretch\":true,\"stretch_bpm\":96"), p, error));
    CHECK(p.zones[0].stretch);
    CHECK(samplerStateJson(p).find("\"stretch_bpm\":96") != std::string::npos);
    CHECK(!parseSamplerState(state(",\"stretch_bpm\":5"), p, error));
    CHECK(error.find("stretch_bpm") != std::string::npos);
}

TEST(sampler_stretched_zone_is_block_size_independent_and_finite) {
    const std::string dir = tempDir("stretch_blocks");
    const std::string a4 = tone(dir + "/a4.wav", 440.0);
    const std::string st = "{\"zones\":[{\"path\":\"" + jsonEscape(a4) + "\",\"pitch_keycenter\":69,\"stretch\":true}]}";
    const auto ref = play(st, 76, 48000, 512);
    for (int block : {1, 37, 64}) {
        const auto x = play(st, 76, 48000, block);
        double worst = 0;
        for (size_t i = 0; i < x.size(); ++i) {
            CHECK(std::isfinite(x[i]));
            worst = std::max(worst, static_cast<double>(std::fabs(x[i] - ref[i])));
        }
        CHECK(worst < 1e-4);
    }
}

TEST(sampler_presets_set_playback_envelope_and_filter_and_play) {
    // 1.1.0: 8 job-named presets (no sample paths: they set only knobs); each plays a zone finite and audible.
    const std::string dir = tempDir("presets");
    const std::string a3 = tone(dir + "/a3.wav", 220.0, 1.0);
    const std::string state = "{\"zones\":[{\"path\":\"" + a3 + "\",\"pitch_keycenter\":57}]}";
    const auto& presets = builtinPresets("org.caw.sampler");
    CHECK(presets.size() >= 8u);
    for (const BuiltinPreset& p : presets) {
        CHECK(!p.description.empty());
        std::string params;
        for (const auto& [k, v] : p.values) {
            CHECK(k.find("path") == std::string_view::npos);
            params += (params.empty() ? "\"" : ",\"") + std::string(k) + "\":" + std::to_string(v);
        }
        const std::string pattern = "---\\nkind: pattern\\nlength: 64\\n---\\n0 57 4 1\\n";
        const std::string json = "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":4,\"master\":1,\"modules\":[{\"id\":\"p\",\"source\":\"" +
            pattern + "\"}],\"layers\":[{\"id\":\"s\",\"name\":\"S\",\"volume\":1,\"pattern\":\"p\",\"instrument\":{\"id\":\"org.caw.sampler\","
            "\"params\":{" + params + "},\"state\":\"" + b64(state) + "\"}}]}";
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(e.setProjectJson(json).find("\"ok\":true") != std::string::npos);
        e.play(0);
        std::vector<float> l(48000), r(48000);
        for (size_t i = 0; i < l.size(); i += 512) e.process(l.data() + i, r.data() + i, static_cast<int>(std::min<size_t>(512, l.size() - i)));
        double sum = 0;
        bool finite = true;
        for (float x : l) finite &= std::isfinite(x) && std::fabs(x) < 4.0f, sum += double(x) * x;
        const double level = std::sqrt(sum / l.size());
        if (!finite || !(level > 1e-3)) cawtest::fail(__FILE__, __LINE__, std::string(p.name) + ": level " + std::to_string(level));
    }
}
