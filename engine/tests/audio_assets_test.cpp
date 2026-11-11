// WP-J: the asset store (decoding, resampling, peaks), audio clips on tracks, time-stretch, the sampler, SFZ and input.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "asset_store.h"
#include "audio_clips.h"
#include "audio_input.h"
#include "builtin_sampler.h"
#include "caw.h"
#include "engine.h"
#include "json.h"
#include "project.h"
#include "render_stems.h"
#include "test.h"
#include "time_stretch.h"
#include "wav.h"

using namespace caw;

namespace {

std::string tempDir(const std::string& name) {
    const auto d = std::filesystem::temp_directory_path() / ("caw_wpj_" + name);
    std::filesystem::remove_all(d);
    std::filesystem::create_directories(d);
    return d.generic_string();
}

// A WAV file of `frames` frames; sample(i, c) gives each value.
template <class F>
std::string writeWav(const std::string& path, int rate, int channels, int64_t frames, F sample, bool float32 = true) {
    std::vector<float> x(static_cast<size_t>(frames * channels));
    for (int64_t i = 0; i < frames; ++i)
        for (int c = 0; c < channels; ++c) x[static_cast<size_t>(i * channels + c)] = sample(i, c);
    WavSpec s;
    s.sampleRate = rate;
    s.channels = channels;
    s.float32 = float32;
    s.pcmBits = 16;
    std::string error;
    CHECK(writeFile(path, encodeWav(s, x.data(), frames), error));
    return path;
}

float noiseAt(int64_t i, int c) {
    uint32_t x = static_cast<uint32_t>(i * 2654435761u + c * 40503u + 1u);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return static_cast<float>((x >> 8) / 8388608.0 - 1.0) * 0.5f;
}

// Renders `frames` of a project (master bypassed, so the track's sound is what comes out) in callbacks of `block`.
std::vector<float> render(const std::string& json, int64_t frames, int block = 512, double fromStep = 0,
                          std::vector<float>* right = nullptr) {
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string r = e.setProjectJson(json);
    CHECK(r.find("\"ok\":true") != std::string::npos);
    if (r.find("\"ok\":true") == std::string::npos) std::printf("%s\n", r.c_str());
    e.play(fromStep);
    std::vector<float> l(static_cast<size_t>(frames)), rr(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += block)
        e.process(l.data() + i, rr.data() + i, static_cast<int>(std::min<int64_t>(block, frames - i)));
    if (right) *right = rr;
    return l;
}

std::string clipProject(const std::string& path, const std::string& clipFields, int bars = 2, double bpm = 120,
                        const std::string& extraLayer = "") {
    return "{\"caw_project\":1,\"bpm\":" + std::to_string(bpm) + ",\"loop_bars\":" + std::to_string(bars) +
           ",\"master\":1,\"assets\":[{\"id\":\"a\",\"path\":\"" + jsonEscape(path) + "\",\"bpm\":120}],"
           "\"layers\":[{\"id\":\"t\",\"name\":\"T\",\"volume\":1,\"pan\":0" + extraLayer +
           ",\"audio_clips\":[{\"id\":\"c1\",\"asset\":\"a\"" + clipFields + "}]}]}";
}

// Zero crossings (rising) per second of x[from..to).
double risingPerSecond(const std::vector<float>& x, size_t from, size_t to, double rate) {
    int n = 0;
    for (size_t i = from + 1; i < to; ++i) n += x[i - 1] < 0 && x[i] >= 0;
    return n * rate / static_cast<double>(to - from);
}

}  // namespace

// ---------------------------------------------------------------- assets

TEST(assets_decode_wav_resample_and_keep_frequency) {
    const std::string dir = tempDir("decode");
    const std::string p = writeWav(dir + "/sine.wav", 44100, 2, 44100, [](int64_t i, int c) {
        return static_cast<float>(0.5 * std::sin(2 * 3.14159265358979 * 1000.0 * i / 44100.0) * (c ? -1 : 1));
    }, false);
    std::string error;
    auto a = AssetStore::global().load(p, 48000, error);
    CHECK(a != nullptr);
    if (!a) return;
    CHECK_EQ(a->channels, 2u);
    CHECK_EQ(a->sourceRate, 44100.0);
    CHECK_EQ(a->frames, int64_t{48000});
    std::vector<float> l(a->data[0].begin(), a->data[0].end());
    CHECK_NEAR(risingPerSecond(l, 1000, 47000, 48000), 1000.0, 2.0);
    float peak = 0;
    for (size_t i = 1000; i < 47000; ++i) peak = std::max(peak, std::fabs(l[i]));
    CHECK_NEAR(peak, 0.5, 0.01);
    CHECK_NEAR(a->data[1][5000], -a->data[0][5000], 1e-6);
    // Loaded once: the same object again.
    CHECK(AssetStore::global().load(p, 48000, error).get() == a.get());
    // Peaks: about +-0.5 over the whole file.
    float pk[8];
    CHECK_EQ(readPeaks(*a, 0, a->frames, 4, 0, pk), 4);
    CHECK_NEAR(pk[0], -0.5, 0.02);
    CHECK_NEAR(pk[1], 0.5, 0.02);
    std::filesystem::remove_all(dir);
}

TEST(assets_refuse_garbage_truncated_and_missing_files) {
    const std::string dir = tempDir("bad");
    std::string error;
    const std::string garbage = dir + "/garbage.wav";
    {
        std::ofstream f(garbage, std::ios::binary);
        for (int i = 0; i < 1000; ++i) f.put(static_cast<char>(i * 37));
    }
    CHECK(AssetStore::global().load(garbage, 48000, error) == nullptr);
    CHECK(!error.empty());
    // A WAV cut off inside its data still loads the frames it has (or is refused); it never reads past the end.
    const std::string good = writeWav(dir + "/cut.wav", 48000, 1, 4800, [](int64_t i, int) { return noiseAt(i, 0); });
    std::filesystem::resize_file(good, 44 + 100 * 4 + 2);
    auto cut = AssetStore::global().load(good, 48000, error);
    CHECK(!cut || cut->frames <= 101);
    error.clear();
    CHECK(AssetStore::global().load(dir + "/none.wav", 48000, error) == nullptr);
    CHECK(error.find("can't be read") != std::string::npos);
    // Random bytes behind a RIFF header.
    std::vector<uint8_t> fuzz(4096);
    for (int round = 0; round < 50; ++round) {
        for (size_t i = 0; i < fuzz.size(); ++i) fuzz[i] = static_cast<uint8_t>(noiseAt(static_cast<int64_t>(i), round) * 255);
        std::memcpy(fuzz.data(), "RIFF", 4);
        std::memcpy(fuzz.data() + 8, "WAVEfmt ", 8);
        AudioAsset out;
        decodeAsset(fuzz.data(), fuzz.size(), 48000, "fuzz", out, error);
    }
    std::filesystem::remove_all(dir);
}

TEST(assets_share_by_refcount_and_the_budget_evicts_only_unused_ones) {
    const std::string dir = tempDir("budget");
    std::string error;
    AssetStore& s = AssetStore::global();
    const uint64_t was = s.budget();
    s.purge();
    const std::string a = writeWav(dir + "/a.wav", 48000, 1, 48000 * 4, [](int64_t i, int) { return noiseAt(i, 1); });
    const std::string b = writeWav(dir + "/b.wav", 48000, 1, 48000 * 4, [](int64_t i, int) { return noiseAt(i, 2); });
    auto held = s.load(a, 48000, error);
    CHECK(held != nullptr);
    s.setBudget(held->bytes() + held->bytes() / 2);  // room for one
    auto other = s.load(b, 48000, error);
    CHECK(other == nullptr);  // a is in use: b doesn't fit
    CHECK(error.find("budget") != std::string::npos);
    held.reset();
    other = s.load(b, 48000, error);  // a is unused now and makes room
    CHECK(other != nullptr);
    CHECK(s.find(a, 48000) == nullptr);
    s.setBudget(was);
    std::filesystem::remove_all(dir);
}

// ---------------------------------------------------------------- readers

TEST(time_stretch_wsola_keeps_pitch_and_follows_the_mapping) {
    AudioAsset a;
    a.rate = a.sourceRate = 48000;
    a.channels = 1;
    a.frames = 48000 * 3;
    a.data[0].resize(static_cast<size_t>(a.frames));
    for (int64_t i = 0; i < a.frames; ++i) a.data[0][static_cast<size_t>(i)] = static_cast<float>(0.5 * std::sin(2 * 3.14159265358979 * 440.0 * i / 48000.0));
    ClipSource src;
    src.asset = &a;
    std::vector<float> gain(48000, 1.0f);
    for (double slope : {0.5, 1.5}) {
        ClipReader r;
        CHECK(r.prepare(48000));
        r.start(src, ReadMode::Stretch, 1.0, 0, 0, slope);
        std::vector<float> l(48000, 0.0f), rr(48000, 0.0f);
        for (int i = 0; i < 48000; i += 64) r.render(i, 64, gain.data(), l.data() + i, rr.data() + i);
        CHECK_NEAR(risingPerSecond(l, 2000, 46000, 48000), 440.0, 4.0);  // pitch kept at any speed
    }
    // A pitch of 2 (an octave up) at the same speed: 880 Hz.
    ClipReader r;
    CHECK(r.prepare(48000));
    r.start(src, ReadMode::Stretch, 2.0, 0, 0, 1.0);
    std::vector<float> l(48000, 0.0f), rr(48000, 0.0f);
    for (int i = 0; i < 48000; i += 64) r.render(i, 64, gain.data(), l.data() + i, rr.data() + i);
    CHECK_NEAR(risingPerSecond(l, 2000, 46000, 48000), 880.0, 8.0);
    // Varispeed at 1.5: pitch and speed together.
    ClipReader v;
    v.start(src, ReadMode::Varispeed, 1.0, 0, 0, 1.5);
    std::fill(l.begin(), l.end(), 0.0f);
    for (int i = 0; i < 48000; i += 64) v.render(i, 64, gain.data(), l.data() + i, rr.data() + i);
    CHECK_NEAR(risingPerSecond(l, 2000, 46000, 48000), 660.0, 3.0);
}

// ---------------------------------------------------------------- clips in the engine

TEST(audio_clip_plays_sample_accurately_through_the_track) {
    const std::string dir = tempDir("clip");
    const std::string p = writeWav(dir + "/n.wav", 48000, 2, 30000, [](int64_t i, int c) { return noiseAt(i, c); });
    // 120 BPM at 48 kHz: 6000 frames a step. Start 4 steps in, 4 steps long (24000 frames).
    std::vector<float> right;
    const auto l = render(clipProject(p, ",\"start_steps\":4,\"length_steps\":4"), 96000, 512, 0, &right);
    CHECK_EQ(l[23999], 0.0f);
    double k = l[24000] / noiseAt(0, 0);
    bool exact = true;
    for (int64_t i = 0; i < 24000; ++i)
        exact = exact && std::fabs(l[static_cast<size_t>(24000 + i)] - k * noiseAt(i, 0)) < 1e-6 &&
                std::fabs(right[static_cast<size_t>(24000 + i)] - k * noiseAt(i, 1)) < 1e-6;
    CHECK(exact);
    CHECK(k > 0.5 && k <= 1.0001);
    CHECK_EQ(l[48000], 0.0f);  // it ends where the clip ends
    std::filesystem::remove_all(dir);
}

TEST(audio_clip_edits_offset_gain_fade_reverse_loop_and_mute) {
    const std::string dir = tempDir("edits");
    const std::string p = writeWav(dir + "/n.wav", 48000, 1, 12000, [](int64_t i, int) { return noiseAt(i, 0); });
    const auto ref = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":2"), 12000);
    const double k = ref[0] / noiseAt(0, 0);
    // offset 0.1 s (4800 frames) and gain 0.5
    auto x = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":1,\"offset_seconds\":0.1,\"gain\":0.5"), 6000);
    CHECK_NEAR(x[10], 0.5 * k * noiseAt(4810, 0), 1e-6);
    // reverse: the first frame is the file's last
    x = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":1,\"reverse\":true"), 6000);
    CHECK_NEAR(x[0], k * noiseAt(11999, 0), 1e-6);
    // loop: 4 steps long over a 2-step file: the second pass repeats the first
    x = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":4,\"loop\":true"), 24000);
    CHECK_NEAR(x[12000 + 77], x[77], 1e-7);
    CHECK(std::fabs(x[12000 + 77]) > 0);
    // a linear fade in over 0.1 s: halfway is half
    x = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":2,\"fade_in_seconds\":0.1"), 12000);
    CHECK_NEAR(x[2400], 0.5 * k * noiseAt(2400, 0), 1e-6);
    CHECK_EQ(x[0], 0.0f);
    // muted: nothing
    x = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":2,\"mute\":true"), 12000);
    CHECK_EQ(*std::max_element(x.begin(), x.end()), 0.0f);
    std::filesystem::remove_all(dir);
}

TEST(audio_clips_render_the_same_at_every_block_size_and_from_a_seek) {
    const std::string dir = tempDir("blocks");
    const std::string p = writeWav(dir + "/n.wav", 48000, 2, 48000, [](int64_t i, int c) { return noiseAt(i, c); });
    for (const char* fields : {",\"start_steps\":1.5,\"length_steps\":6,\"fade_out_seconds\":0.05,\"fade_out_curve\":\"equal_power\"",
                               ",\"start_steps\":1,\"length_steps\":8,\"mode\":\"musical\",\"source_bpm\":100",
                               ",\"start_steps\":1,\"length_steps\":8,\"pitch\":3",
                               ",\"start_steps\":1,\"length_steps\":8,\"pitch\":-5,\"stretch\":\"varispeed\""}) {
        const std::string json = clipProject(p, fields);
        const auto a = render(json, 60000, 512), b = render(json, 60000, 37), c = render(json, 60000, 64);
        CHECK(a == b);
        CHECK(a == c);
        float peak = 0;
        for (float v : a) peak = std::max(peak, std::fabs(v));
        CHECK(peak > 0.1f);
    }
    // Played from step 3, a fixed clip sounds as it does at step 3 when played from the start.
    const std::string json = clipProject(p, ",\"start_steps\":1,\"length_steps\":8");
    const auto whole = render(json, 60000);
    const auto from = render(json, 30000, 512, 3);
    bool same = true;
    for (int i = 1000; i < 20000; ++i) same = same && whole[18000 + i] == from[i];  // past the Play fade-in
    CHECK(same);
    std::filesystem::remove_all(dir);
}

TEST(musical_clip_follows_the_tempo_and_fixed_does_not) {
    const std::string dir = tempDir("tempo");
    // One beat of 120 BPM at 48 kHz (24000 frames), a sine at 500 Hz.
    const std::string p = writeWav(dir + "/s.wav", 48000, 1, 24000, [](int64_t i, int) {
        return static_cast<float>(0.5 * std::sin(2 * 3.14159265358979 * 500.0 * i / 48000.0));
    });
    // At 60 BPM a musical clip of 4 steps (one beat, 48000 frames) stretches the beat over it: pitch kept.
    auto x = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":4,\"mode\":\"musical\",\"source_bpm\":120", 1, 60), 48000);
    float tail = 0;
    for (int i = 40000; i < 46000; ++i) tail = std::max(tail, std::fabs(x[static_cast<size_t>(i)]));
    CHECK(tail > 0.2f);  // still sounding near the end: stretched
    CHECK_NEAR(risingPerSecond(x, 2000, 44000, 48000), 500.0, 6.0);
    // Varispeed: half speed, an octave down.
    x = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":4,\"mode\":\"musical\",\"source_bpm\":120,\"stretch\":\"varispeed\"", 1, 60), 48000);
    CHECK_NEAR(risingPerSecond(x, 2000, 44000, 48000), 250.0, 3.0);
    // Fixed: the file at its own speed, done after 24000 frames.
    x = render(clipProject(p, ",\"start_steps\":0,\"length_steps\":4", 1, 60), 48000);
    CHECK_EQ(x[30000], 0.0f);
    std::filesystem::remove_all(dir);
}

TEST(audio_clips_parse_errors_and_song_length) {
    ProjectSpec spec;
    std::string error;
    CHECK(!parseProject("{\"layers\":[{\"id\":\"t\",\"audio_clips\":[{\"id\":\"c\",\"asset\":\"missing\"}]}]}", spec, error));
    CHECK(error.find("missing") != std::string::npos);
    CHECK(!parseProject("{\"layers\":[{\"id\":\"t\",\"audio_clips\":[{\"id\":\"c\",\"path\":\"x.wav\",\"mode\":\"musical\"}]}]}", spec, error));
    CHECK(error.find("source_bpm") != std::string::npos);
    CHECK(!parseProject("{\"layers\":[{\"id\":\"t\",\"instrument\":\"org.caw.sampler\",\"audio_clips\":[]}]}", spec, error));
    CHECK(parseProject("{\"loop_bars\":1,\"layers\":[{\"id\":\"t\",\"audio_clips\":[{\"id\":\"c\",\"path\":\"x.wav\",\"start_steps\":30.5,\"length_steps\":10}]}]}", spec, error));
    CHECK_EQ(spec.loopBars, 3);  // reaches step 40.5
    CHECK(spec.layers[0].hasInstrument);
    CHECK_EQ(spec.layers[0].instrument.id, std::string(kAudioTrackId));
}

TEST(audio_clip_goes_through_inserts_and_buses_and_the_song_render_matches_playback) {
    const std::string dir = tempDir("stems");
    const std::string p = writeWav(dir + "/n.wav", 48000, 2, 48000, [](int64_t i, int c) { return noiseAt(i, c); });
    const std::string json =
        "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":1,\"master\":1,\"assets\":[{\"id\":\"a\",\"path\":\"" + jsonEscape(p) +
        "\"}],\"layers\":[{\"id\":\"bus\",\"name\":\"Bus\",\"folder\":true,\"bus\":true,\"volume\":1},"
        "{\"id\":\"t\",\"name\":\"T\",\"volume\":0.5,\"parent\":\"bus\",\"components\":[{\"id\":\"org.caw.utility\"}],"
        "\"audio_clips\":[{\"id\":\"c1\",\"asset\":\"a\",\"start_steps\":2,\"length_steps\":8,\"pitch\":2}]}]}";
    ProjectSpec spec;
    std::string error;
    CHECK(parseProject(json, spec, error));
    SongRenderRequest q;
    q.outDir = dir;
    q.mix = true;
    q.bitDepth = 32;
    SongRenderResult r;
    CHECK(renderSong(spec, q, r));
    CHECK_EQ(r.files.size(), size_t{1});
    if (r.files.size() != 1) return;
    auto file = AssetStore::global().load(r.files[0].path, 48000, error);
    CHECK(file != nullptr);
    if (!file) return;
    Engine e(48000);
    e.setProject(spec);
    e.play();
    const int64_t len = file->frames;
    std::vector<float> l(static_cast<size_t>(len)), rr(static_cast<size_t>(len));
    for (int64_t i = 0; i < len; i += 512) e.process(l.data() + i, rr.data() + i, static_cast<int>(std::min<int64_t>(512, len - i)));
    bool same = true;
    float peak = 0;
    for (int64_t i = 0; i < len; ++i) {
        same = same && file->data[0][static_cast<size_t>(i)] == l[static_cast<size_t>(i)];
        peak = std::max(peak, std::fabs(l[static_cast<size_t>(i)]));
    }
    CHECK(same);
    CHECK(peak > 0.05f);
    std::filesystem::remove_all(dir);
}

// ---------------------------------------------------------------- the sampler

namespace {
std::string b64(const std::string& s) { return base64Encode(reinterpret_cast<const uint8_t*>(s.data()), s.size()); }

std::vector<float> playSampler(const std::string& state, const std::string& params, std::vector<int> notes, int64_t frames,
                               double len = 2) {
    std::string pattern = "---\\nkind: pattern\\nlength: 16\\n---\\n";
    for (size_t i = 0; i < notes.size(); ++i)
        pattern += std::to_string(i * 4) + " " + std::to_string(notes[i]) + " " + std::to_string(len) + " 1\\n";
    const std::string json =
        "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":1,\"master\":1,\"modules\":[{\"id\":\"p\",\"source\":\"" + pattern +
        "\"}],\"layers\":[{\"id\":\"s\",\"name\":\"S\",\"volume\":1,\"pattern\":\"p\",\"instrument\":{\"id\":\"org.caw.sampler\"," +
        "\"params\":{" + params + "},\"state\":\"" + b64(state) + "\"}}]}";
    return render(json, frames);
}
}  // namespace

TEST(sampler_maps_zones_by_key_and_velocity_and_plays_at_pitch) {
    const std::string dir = tempDir("sampler");
    const std::string p = writeWav(dir + "/s.wav", 48000, 1, 48000, [](int64_t i, int) {
        return static_cast<float>(0.5 * std::sin(2 * 3.14159265358979 * 440.0 * i / 48000.0));
    });
    const std::string state = "{\"zones\":[{\"path\":\"" + jsonEscape(p) +
                              "\",\"lokey\":48,\"hikey\":72,\"pitch_keycenter\":69}]}";
    // A4 plays 440 Hz; A5 880; a note outside the zone is silent.
    auto x = playSampler(state, "", {69}, 12000);
    CHECK_NEAR(risingPerSecond(x, 1000, 11000, 48000), 440.0, 6.0);
    x = playSampler(state, "", {72}, 12000);
    CHECK_NEAR(risingPerSecond(x, 1000, 11000, 48000), 440.0 * std::pow(2.0, 3 / 12.0), 7.0);
    x = playSampler(state, "", {30}, 12000);
    CHECK_EQ(*std::max_element(x.begin(), x.end()), 0.0f);
    // The low-pass at 200 Hz takes most of it away.
    auto loud = playSampler(state, "", {69}, 12000);
    auto soft = playSampler(state, "\"filter\":1,\"cutoff\":200", {69}, 12000);
    double el = 0, es = 0;
    for (int i = 2000; i < 11000; ++i) {
        el += loud[i] * loud[i];
        es += soft[i] * soft[i];
    }
    CHECK(es < el * 0.2);
    std::filesystem::remove_all(dir);
}

TEST(sampler_round_robins_loops_and_one_shots) {
    const std::string dir = tempDir("rr");
    const std::string a = writeWav(dir + "/a.wav", 48000, 1, 48000, [](int64_t, int) { return 0.25f; });
    const std::string b = writeWav(dir + "/b.wav", 48000, 1, 48000, [](int64_t, int) { return -0.25f; });
    const std::string state = "{\"zones\":[{\"path\":\"" + jsonEscape(a) + "\",\"seq_length\":2,\"seq_position\":1},"
                              "{\"path\":\"" + jsonEscape(b) + "\",\"seq_length\":2,\"seq_position\":2}]}";
    auto x = playSampler(state, "\"attack\":0", {60, 60}, 30000, 1);
    CHECK(x[3000] > 0.1f);              // the first note: zone a
    CHECK(x[24000 + 3000] < -0.1f);     // the second: zone b
    // A short sample with a sustain loop keeps sounding while held.
    const std::string c = writeWav(dir + "/c.wav", 48000, 1, 1000, [](int64_t i, int) { return noiseAt(i, 3); });
    const std::string looped = "{\"zones\":[{\"path\":\"" + jsonEscape(c) +
                               "\",\"loop_mode\":\"loop_sustain\",\"loop_start\":200,\"loop_end\":799,\"loop_crossfade\":0.002}]}";
    x = playSampler(looped, "\"attack\":0,\"release\":0.01", {60}, 20000, 2);
    float late = 0;
    for (int i = 9000; i < 11000; ++i) late = std::max(late, std::fabs(x[static_cast<size_t>(i)]));
    CHECK(late > 0.1f);
    // Without the loop it ends after 1000 frames.
    const std::string plain = "{\"zones\":[{\"path\":\"" + jsonEscape(c) + "\"}]}";
    x = playSampler(plain, "\"attack\":0", {60}, 20000, 2);
    CHECK_EQ(x[5000], 0.0f);
    std::filesystem::remove_all(dir);
}

TEST(sfz_import_reads_headers_inheritance_note_names_and_warns) {
    const std::string sfz = R"(// test
#define $ROOT 60
<control> default_path=samples/
<global> ampeg_release=0.5
<group> lovel=1 hivel=64 seq_length=2
<region> sample=piano soft.wav lokey=c4 hikey=e4 pitch_keycenter=$ROOT seq_position=1
<region> sample=sub\b.wav key=a#3 seq_position=2 loop_mode=loop_continuous loopstart=10 loopend=500 fil_type=lpf_2p
<group> lovel=65
<region> sample=x.wav trigger=release
/* a comment <region> sample=no.wav */
)";
    SamplerProgram p;
    std::vector<std::string> warnings;
    std::string error;
    CHECK(importSfzText(sfz, "/kit", p, warnings, error));
    CHECK_EQ(p.zones.size(), size_t{2});
    if (p.zones.size() != 2) return;
    CHECK_EQ(p.zones[0].path, std::string("/kit/samples/piano soft.wav"));
    CHECK_EQ(p.zones[0].lokey, 60);
    CHECK_EQ(p.zones[0].hikey, 64);
    CHECK_EQ(p.zones[0].root, 60);
    CHECK_EQ(p.zones[0].hivel, 64);
    CHECK_EQ(p.zones[0].ampRelease, 0.5);
    CHECK_EQ(p.zones[1].path, std::string("/kit/samples/sub/b.wav"));
    CHECK_EQ(p.zones[1].lokey, 58);
    CHECK_EQ(p.zones[1].seqPosition, 2);
    CHECK(p.zones[1].loopMode == LoopMode::Continuous);
    CHECK_EQ(p.zones[1].loopEnd, int64_t{500});
    bool fil = false, trig = false;
    for (const std::string& w : warnings) {
        fil = fil || w.find("fil_type") != std::string::npos;
        trig = trig || w.find("trigger=release") != std::string::npos;
    }
    CHECK(fil);
    CHECK(trig);
    // Through the state JSON and back to SFZ and in again: the same zones.
    SamplerProgram q;
    CHECK(parseSamplerState(samplerStateJson(p), q, error));
    CHECK_EQ(samplerStateJson(q), samplerStateJson(p));
    const std::string text = exportSfzText(q, "/kit", "Kit");
    SamplerProgram r;
    warnings.clear();
    CHECK(importSfzText(text, "/kit", r, warnings, error));
    CHECK_EQ(samplerStateJson(r), samplerStateJson(p));
    CHECK(text.find("sample=samples/piano soft.wav") != std::string::npos);
}

TEST(sfz_export_copies_samples_and_the_c_api_round_trips) {
    const std::string dir = tempDir("sfzexport");
    const std::string a = writeWav(dir + "/src a.wav", 48000, 1, 100, [](int64_t i, int) { return noiseAt(i, 0); });
    std::filesystem::create_directories(dir + "/out");
    const std::string state = "{\"zones\":[{\"path\":\"" + jsonEscape(a) + "\",\"lokey\":10,\"hikey\":20}]}";
    char* r = caw_sfz_export(state.c_str(), (dir + "/out/kit.sfz").c_str(), 1);
    CHECK(std::string(r).find("\"ok\":true") != std::string::npos);
    if (std::string(r).find("src_a") == std::string::npos) std::printf("%s\n", r);
    caw_free(r);
    CHECK(std::filesystem::exists(dir + "/out/samples/src_a.wav"));
    r = caw_sfz_import((dir + "/out/kit.sfz").c_str());
    const std::string imported = r;
    caw_free(r);
    CHECK(imported.find("\"ok\":true") != std::string::npos);
    CHECK(imported.find("samples/src_a.wav") != std::string::npos);
    CHECK(imported.find("\"lokey\":10") != std::string::npos);
    CHECK(imported.find("missing sample") == std::string::npos);
    std::filesystem::remove_all(dir);
}

// ---------------------------------------------------------------- input, monitoring and recording

namespace {
std::string inputProject(const std::string& monitor, bool armed, const std::string& extra = "", int bars = 1) {
    return "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":" + std::to_string(bars) + ",\"master\":1" + extra +
           ",\"layers\":[{\"id\":\"t\",\"name\":\"T\",\"volume\":1,\"input\":{\"channel\":1,\"channels\":1,\"monitor\":\"" +
           monitor + "\",\"armed\":" + (armed ? "true" : "false") + "}}]}";
}

// One callback of `frames` frames whose input channel 1 is `value` (channel 0 is noise).
void callback(Engine& e, std::vector<float>& in, float value, int frames, float* l, float* r) {
    in.assign(static_cast<size_t>(frames) * 2, 0.0f);
    for (int i = 0; i < frames; ++i) {
        in[static_cast<size_t>(i) * 2] = noiseAt(i, 9);
        in[static_cast<size_t>(i) * 2 + 1] = value;
    }
    e.liveAudio().beginCallback(in.data(), 2, frames);
    e.process(l, r, frames);
    e.liveAudio().afterCallback(l, r, frames);
}
}  // namespace

TEST(input_monitoring_through_the_track_while_stopped_and_off) {
    std::vector<float> in, l(256), r(256);
    {
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(e.setProjectJson(inputProject("auto", true)).find("\"ok\":true") != std::string::npos);
        for (int k = 0; k < 4; ++k) callback(e, in, 0.25f, 256, l.data(), r.data());
        // Stopped, armed, auto: heard, in both sides, through the track's centred pan (-3 dB each side).
        CHECK_NEAR(l[200], 0.25 * std::sqrt(0.5), 1e-6);
        CHECK_NEAR(r[200], 0.25 * std::sqrt(0.5), 1e-6);
        // Playing and not recording, auto lets go of the input (the takes play back instead).
        e.play();
        for (int k = 0; k < 8; ++k) callback(e, in, 0.25f, 256, l.data(), r.data());
        CHECK_EQ(l[200], 0.0f);
    }
    {
        Engine e(48000);
        e.setMasterBypass(true);
        e.setProjectJson(inputProject("off", true));
        for (int k = 0; k < 4; ++k) callback(e, in, 0.25f, 256, l.data(), r.data());
        CHECK_EQ(l[200], 0.0f);
    }
    {
        Engine e(48000);  // "on" monitors unarmed, playing or not
        e.setMasterBypass(true);
        e.setProjectJson(inputProject("on", false));
        e.play();
        for (int k = 0; k < 4; ++k) callback(e, in, -0.5f, 256, l.data(), r.data());
        CHECK_NEAR(l[200], -0.5 * std::sqrt(0.5), 1e-6);
    }
}

namespace {
std::vector<float> readFloatWav(const std::string& path, int& channels) {
    std::ifstream f(path, std::ios::binary);
    std::vector<uint8_t> b((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
    channels = b.size() >= 44 ? b[22] : 1;
    std::vector<float> out;
    for (size_t i = 44; i + 4 <= b.size(); i += 4) {
        float v;
        std::memcpy(&v, &b[i], 4);
        out.push_back(v);
    }
    return out;
}
}  // namespace

TEST(recording_writes_takes_on_the_grid_with_latency_compensation) {
    const std::string dir = tempDir("record");
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProjectJson(inputProject("off", true));
    e.liveAudio().setDeviceChannels(2);
    e.liveAudio().setLatencyOverride(1000);
    const std::string req = "{\"dir\":\"" + jsonEscape(dir) + "\",\"bpm\":120,\"tracks\":[{\"layer\":\"t\",\"channel\":1}]}";
    CHECK(e.liveAudio().startRecording(req).find("\"ok\":true") != std::string::npos);
    e.play();
    // The input's channel 1 counts input frames: frame n of the recording holds n.
    std::vector<float> in, l(480), r(480);
    int64_t n = 0;
    for (int k = 0; k < 100; ++k) {  // 48000 frames, one second; the song (one bar) is 96000
        in.assign(480 * 2, 0.0f);
        for (int i = 0; i < 480; ++i) in[static_cast<size_t>(i) * 2 + 1] = static_cast<float>(n++);
        e.liveAudio().beginCallback(in.data(), 2, 480);
        e.process(l.data(), r.data(), 480);
    }
    const std::string done = e.liveAudio().stopRecording();
    CHECK(done.find("\"ok\":true") != std::string::npos);
    Json j;
    std::string error;
    CHECK(parseJson(done, j, error));
    const Json* takes = j.get("takes");
    CHECK(takes && takes->arr.size() == 1);
    if (!takes || takes->arr.size() != 1) return;
    const Json& t = takes->arr[0];
    // Played from 0 with 1000 frames of latency: the take begins 1000 frames before the song (frame -1000).
    CHECK_EQ(t.number("start_frame", 0), -1000.0);
    CHECK_EQ(t.number("frames", 0), 48000.0);
    int ch = 0;
    const auto data = readFloatWav(t.string("path"), ch);
    CHECK_EQ(ch, 1);
    CHECK_EQ(data.size(), size_t{48000});
    CHECK_EQ(data[1234], 1234.0f);
    CHECK(std::filesystem::exists(t.string("path") + ".json"));
    std::filesystem::remove_all(dir);
}

TEST(recording_loops_into_takes_and_punches_in_and_out) {
    const std::string dir = tempDir("takes");
    Engine e(48000);
    e.setMasterBypass(true);
    // A one-bar song (96000 frames): three passes make three takes.
    e.setProjectJson(inputProject("off", true));
    e.liveAudio().setDeviceChannels(2);
    e.liveAudio().setLatencyOverride(0);
    CHECK(e.liveAudio().startRecording("{\"dir\":\"" + jsonEscape(dir) +
                                       "\",\"bpm\":120,\"punch_in_steps\":4,\"punch_out_steps\":8,\"tracks\":[{\"layer\":\"t\",\"channel\":0,\"channels\":2}]}")
              .find("\"ok\":true") != std::string::npos);
    e.play();
    std::vector<float> in(512 * 2, 0.1f), l(512), r(512);
    for (int k = 0; k < 96000 * 3 / 512 + 1; ++k) {
        e.liveAudio().beginCallback(in.data(), 2, 512);
        e.process(l.data(), r.data(), 512);
    }
    const std::string done = e.liveAudio().stopRecording();
    Json j;
    std::string error;
    CHECK(parseJson(done, j, error));
    const Json* takes = j.get("takes");
    CHECK(takes && takes->arr.size() == 3);
    if (takes)
        for (const Json& t : takes->arr) {
            CHECK_EQ(t.number("start_frame", 0), 24000.0);  // step 4
            CHECK_EQ(t.number("frames", 0), 24000.0);       // to step 8
            CHECK_EQ(t.number("channels", 0), 2.0);
        }
    std::filesystem::remove_all(dir);
}

TEST(recovery_finalises_a_take_left_by_a_crash) {
    const std::string dir = tempDir("recover");
    // A take as the writer leaves it mid-recording: a header that counts nothing yet, and frames after it.
    const std::string part = dir + "/t-take1.wav.part";
    {
        // The writer's own layout: a 44-byte float header whose sizes still say 0, then the frames.
        std::vector<uint8_t> b(44, 0);
        std::memcpy(b.data(), "RIFF", 4);
        std::memcpy(b.data() + 8, "WAVEfmt ", 8);
        b[16] = 16;
        b[20] = 3;   // IEEE float
        b[22] = 1;   // mono
        b[24] = 0x80; b[25] = 0xBB;  // 48000
        b[28] = 0x00; b[29] = 0xEE; b[30] = 0x02;  // 192000 bytes a second
        b[32] = 4;
        b[34] = 32;
        std::memcpy(b.data() + 36, "data", 4);
        for (int i = 0; i < 1000; ++i) {
            const float v = noiseAt(i, 0);
            uint8_t q[4];
            std::memcpy(q, &v, 4);
            b.insert(b.end(), q, q + 4);
        }
        std::string error;
        CHECK(writeFile(part, b, error));
        std::ofstream side(dir + "/t-take1.wav.json");
        side << "{\"layer\":\"t\",\"start_frame\":5000,\"start_steps\":0.8333,\"take\":1,\"bpm\":120}";
    }
    char* r = caw_record_recover(dir.c_str());
    const std::string out = r;
    caw_free(r);
    CHECK(out.find("\"frames\":1000") != std::string::npos);
    CHECK(out.find("\"start_frame\":5000") != std::string::npos);
    CHECK(out.find("\"recovered\":true") != std::string::npos);
    std::string error;
    auto a = AssetStore::global().load(dir + "/t-take1.wav", 48000, error);
    CHECK(a != nullptr);
    if (a) CHECK_EQ(a->frames, int64_t{1000});
    CHECK(!std::filesystem::exists(part));
    std::filesystem::remove_all(dir);
}

TEST(latency_ping_finds_a_simulated_loopback) {
    Engine e(48000);
    e.setProjectJson(inputProject("off", false));
    e.liveAudio().setDeviceChannels(1);
    CHECK(e.liveAudio().startPing());
    // A loopback with 733 frames of round trip: what was played comes back that much later, quieter.
    const int delay = 733;
    std::vector<float> history(200000, 0.0f), in(256), l(256), r(256);
    int64_t t = 0;
    for (int k = 0; k < 400; ++k) {
        for (int i = 0; i < 256; ++i) in[static_cast<size_t>(i)] = t + i >= delay ? 0.5f * history[static_cast<size_t>(t + i - delay)] : 0.0f;
        e.liveAudio().beginCallback(in.data(), 1, 256);
        e.process(l.data(), r.data(), 256);
        e.liveAudio().afterCallback(l.data(), r.data(), 256);
        for (int i = 0; i < 256; ++i) history[static_cast<size_t>(t + i)] = l[static_cast<size_t>(i)];
        t += 256;
    }
    const std::string res = e.liveAudio().pingResult();
    CHECK(res.find("\"ok\":true") != std::string::npos);
    CHECK(res.find("\"frames\":733") != std::string::npos);
    CHECK_EQ(e.liveAudio().latency(), int64_t{733});
}

// ---------------------------------------------------------------- golden

TEST(audio_clips_and_the_sampler_match_their_golden_render) {
    // Every clip mode (direct with fades, musical WSOLA with pitch and a loop, reversed varispeed) and the sampler
    // (a looped zone, a filter, a chord) through the master, 1.5 s in 64-frame blocks. Change the hash only for an
    // intended sound change (the failure prints the new one).
    constexpr uint64_t kGolden = 0x6dde60ef58cef603ull;  // recorded 2026-11-11, GCC 13
    const std::string dir = tempDir("golden");
    const std::string p = writeWav(dir + "/n.wav", 44100, 2, 44100, [](int64_t i, int c) {
        return static_cast<float>(0.4 * std::sin(2 * 3.14159265358979 * (220.0 + 110 * c) * i / 44100.0) + 0.2 * noiseAt(i, c));
    }, false);
    const std::string zones = "{\"zones\":[{\"path\":\"" + jsonEscape(p) +
                              "\",\"pitch_keycenter\":57,\"loop_mode\":\"loop_sustain\",\"loop_start\":1000,\"loop_end\":20000,"
                              "\"loop_crossfade\":0.01,\"pan\":-30}]}";
    const std::string json =
        "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":1,\"master\":0.5,\"assets\":[{\"id\":\"a\",\"path\":\"" + jsonEscape(p) +
        "\",\"bpm\":100}],\"modules\":[{\"id\":\"pt\",\"source\":\"---\\nkind: pattern\\nlength: 16\\n---\\n0 C4,E4,G4 3 1\\n4 A3 6 0.7\\n\"}],"
        "\"layers\":[{\"id\":\"d\",\"name\":\"D\",\"audio_clips\":["
        "{\"id\":\"1\",\"asset\":\"a\",\"start_steps\":0,\"length_steps\":5,\"fade_in_seconds\":0.01,\"fade_out_seconds\":0.1,\"fade_out_curve\":\"s_curve\"},"
        "{\"id\":\"2\",\"asset\":\"a\",\"start_steps\":3.3,\"length_steps\":6,\"mode\":\"musical\",\"pitch\":2,\"loop\":true,\"gain\":0.7},"
        "{\"id\":\"3\",\"asset\":\"a\",\"start_steps\":7,\"length_steps\":9,\"stretch\":\"varispeed\",\"pitch\":-7,\"reverse\":true}]},"
        "{\"id\":\"s\",\"name\":\"S\",\"pattern\":\"pt\",\"instrument\":{\"id\":\"org.caw.sampler\",\"params\":{\"filter\":1,\"cutoff\":1200,"
        "\"filter_env\":2,\"release\":0.3},\"state\":\"" + b64(zones) + "\"}}]}";
    Engine e(48000);
    CHECK(e.setProjectJson(json).find("\"ok\":true") != std::string::npos);
    e.play();
    uint64_t h = 1469598103934665603ull;
    float l[64], r[64], peak = 0;
    for (int k = 0; k < 48000 * 3 / 2 / 64; ++k) {
        e.process(l, r, 64);
        for (int i = 0; i < 64; ++i) {
            peak = std::max(peak, std::fabs(l[i]));
            for (float v : {l[i], r[i]}) {
                uint32_t bits;
                std::memcpy(&bits, &v, 4);
                h = (h ^ bits) * 1099511628211ull;
            }
        }
    }
    CHECK(peak > 0.05f);
    if (h != kGolden) {
        char buf[64];
        std::snprintf(buf, sizeof buf, "golden 0x%016llxull", static_cast<unsigned long long>(h));
        cawtest::fail(__FILE__, __LINE__, buf);
    }
    std::filesystem::remove_all(dir);
}

TEST(the_sampler_is_listed_and_the_audio_track_player_is_not) {
    Engine e(48000);
    const std::string list = e.nativeComponentsJson();
    CHECK(list.find("\"org.caw.sampler\"") != std::string::npos);
    CHECK(list.find("org.caw.audio-track") == std::string::npos);
}
