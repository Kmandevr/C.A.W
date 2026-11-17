// Song renders: the mix equals playback, aligned stems add up to the mix, bounds, tails, normalise, dither, names;
// freeze and bounce (1.0.5, #209): pre-fader stems, latency-aligned, and a frozen track (its stem played as an audio
// clip in place of its instrument and effects) sounding as the live track does, tails and a tempo ramp included.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <memory>
#include <string>
#include <vector>

#include "audio_clips.h"
#include "caw.h"
#include "engine.h"
#include "meters.h"
#include "render_stems.h"
#include "stress_scenarios.h"
#include "test.h"
#include "test_signal.h"
#include "wav.h"

using namespace caw;

namespace {


std::string tempDir(const char* tag) {
    static int n = 0;
    const auto dir = std::filesystem::temp_directory_path() /
        ("caw_stems_" + std::string(tag) + "_" +
         std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + "_" + std::to_string(++n));
    std::filesystem::create_directories(dir);
    return dir.generic_string();  // forward slashes: it goes into JSON requests unescaped (Windows' \ would break it)
}

size_t fileCount(const std::string& dir) {
    size_t n = 0;
    for (const auto& e : std::filesystem::directory_iterator(dir)) n += e.is_regular_file() ? 1 : 0;
    return n;
}

std::vector<uint8_t> bytesOf(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    return std::vector<uint8_t>(std::istreambuf_iterator<char>(in), std::istreambuf_iterator<char>());
}

// A stereo WAV's samples, interleaved: 32-bit float, or 16/24-bit PCM scaled to -1..1.
std::vector<float> readWav(const std::string& path, int* bits = nullptr) {
    const std::vector<uint8_t> b = bytesOf(path);
    auto u16 = [&](size_t at) { return static_cast<uint32_t>(b[at] | (b[at + 1] << 8)); };
    auto u32 = [&](size_t at) { return u16(at) | (u16(at + 2) << 16); };
    std::vector<float> out;
    int depth = 0, format = 0;
    for (size_t at = 12; at + 8 <= b.size();) {
        const std::string tag(b.begin() + static_cast<long>(at), b.begin() + static_cast<long>(at) + 4);
        const uint32_t size = u32(at + 4);
        if (tag == "fmt ") {
            format = static_cast<int>(u16(at + 8));
            depth = static_cast<int>(u16(at + 22));
        } else if (tag == "data") {
            const size_t step = static_cast<size_t>(depth / 8);
            for (size_t i = at + 8; i + step <= at + 8 + size; i += step) {
                if (format == 3) {
                    float v;
                    std::memcpy(&v, &b[i], 4);
                    out.push_back(v);
                } else if (depth == 16) {
                    out.push_back(static_cast<float>(static_cast<int16_t>(u16(i))) / 32767.0f);
                } else {
                    int32_t v = static_cast<int32_t>(b[i] | (b[i + 1] << 8) | (b[i + 2] << 16));
                    if (v & 0x800000) v -= 0x1000000;
                    out.push_back(static_cast<float>(v) / 8388607.0f);
                }
            }
        }
        at += 8 + size + (size & 1);
    }
    if (bits) *bits = depth;
    return out;
}

// A track playing the test signal in Notes mode (its notes from its clips or pattern) at `level`.
LayerSpec track(const std::string& id, cawtest::Shape shape, double level, double volume) {
    LayerSpec l = cawtest::testSignalNotesLayer(id, shape, "", {{"level", level}});
    l.volume = volume;
    return l;
}

LayerSpec bus(const std::string& id) {
    LayerSpec l;
    l.id = id;
    l.name = id;
    l.folder = true;
    l.busEnabled = true;
    l.volume = 0.9;
    return l;
}

// Two top-level tracks, a third inside a reverb bus, and a send from the first into that bus: 2 bars at 120 BPM.
ProjectSpec band() {
    ProjectSpec p;
    p.name = "Band";
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 0.7;
    p.modules.push_back({"riff", "---\nkind: pattern\nlength: 8\n---\n0 A2 2 1\n4 C3 1 0.8\n6 E3 2 0.6\n"});
    p.modules.push_back({"hold", "---\nkind: pattern\nlength: 32\n---\n0 C4 32 1\n"});
    LayerSpec a = track("a", cawtest::Shape::Saw, 0.3, 0.8);
    a.name = "Bass";
    a.clips.push_back({"ca", "riff", 0, 32, 0, true});
    a.sends = {{"verb", 0.5, false, false}};
    LayerSpec b = track("b", cawtest::Shape::Noise, 1.0, 0.2);
    b.pattern = "hold";
    b.name = "Byte";
    b.pan = -0.4;
    LayerSpec c = track("c", cawtest::Shape::Sine, 0.3, 1.0);
    c.name = "Lead";
    c.parentId = "verb";
    c.clips.push_back({"cc", "riff", 8, 16, 0, true});
    LayerSpec v = bus("verb");
    v.name = "Verb";
    ComponentSpec reverb;
    reverb.id = "org.caw.reverb.pro";
    v.components = {reverb};
    p.layers = {a, b, c, v};
    return p;
}

SongRenderRequest floatRequest(const std::string& dir) {
    SongRenderRequest r;
    r.outDir = dir;
    r.project = "Band";
    r.bitDepth = 32;
    return r;
}

// Live playback from `fromStep`, as a device plays it with odd buffer sizes: interleaved stereo.
std::vector<float> live(const ProjectSpec& p, int64_t frames, double fromStep = 0) {
    Engine e(48000);
    e.setProject(p);
    e.play(fromStep);
    std::vector<float> l(static_cast<size_t>(frames)), r(static_cast<size_t>(frames)), out;
    static const int sizes[] = {441, 64, 37, 512, 1, 192};
    for (int64_t i = 0, k = 0; i < frames; ++k) {
        const int n = static_cast<int>(std::min<int64_t>(sizes[k % 6], frames - i));
        e.process(l.data() + i, r.data() + i, n);
        i += n;
    }
    for (int64_t i = 0; i < frames; ++i) {
        out.push_back(l[static_cast<size_t>(i)]);
        out.push_back(r[static_cast<size_t>(i)]);
    }
    return out;
}

const RenderedFile* fileFor(const SongRenderResult& r, const std::string& layer, const std::string& region = "") {
    for (const RenderedFile& f : r.files)
        if (f.layer == layer && f.region == region) return &f;
    return nullptr;
}

void same(const std::vector<float>& a, const std::vector<float>& b, int line) {
    if (a == b) return;
    size_t first = 0;
    double worst = 0;
    while (first < std::min(a.size(), b.size()) && a[first] == b[first]) ++first;
    for (size_t i = 0; i < std::min(a.size(), b.size()); ++i) worst = std::max(worst, std::fabs(static_cast<double>(a[i]) - b[i]));
    cawtest::fail(__FILE__, line, "differ: sizes " + std::to_string(a.size()) + "/" + std::to_string(b.size()) +
        ", first at frame " + std::to_string(first / 2) + ", worst " + std::to_string(worst));
}

double peakDb(const std::vector<float>& x) {
    double m = 0;
    for (float v : x) m = std::max(m, static_cast<double>(std::fabs(v)));
    return 20.0 * std::log10(m);
}

}  // namespace

TEST(a_song_render_of_the_mix_equals_live_playback_bit_for_bit) {
    const ProjectSpec p = band();
    const std::string dir = tempDir("mix");
    SongRenderResult r;
    CHECK(renderSong(p, floatRequest(dir), r));
    CHECK_EQ(r.files.size(), size_t{1});
    CHECK_EQ(r.files[0].name, std::string("Band.wav"));
    const int64_t len = 2 * 4 * 4 * 6000;  // 2 bars of 16 steps at 6000 frames a step
    CHECK_EQ(r.files[0].frames, len);
    const std::vector<float> file = readWav(r.files[0].path);
    CHECK(file == live(p, len));
    std::filesystem::remove_all(dir);
}

TEST(a_selection_render_equals_playback_started_at_the_selection) {
    const ProjectSpec p = band();
    const std::string dir = tempDir("sel");
    SongRenderRequest q = floatRequest(dir);
    q.bounds = SongBounds::Selection;
    q.startSteps = 6;
    q.endSteps = 22;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    CHECK_EQ(r.files.at(0).frames, int64_t{16 * 6000});
    same(readWav(r.files[0].path), live(p, 16 * 6000, 6), __LINE__);
    std::filesystem::remove_all(dir);
}

TEST(a_loop_render_runs_once_through_the_loop_range) {
    ProjectSpec p = band();
    p.loopRange = true;
    p.loopStartSteps = 4;
    p.loopEndSteps = 20;
    const std::string dir = tempDir("loop");
    SongRenderRequest q = floatRequest(dir);
    q.bounds = SongBounds::Loop;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    CHECK_EQ(r.files.at(0).frames, int64_t{16 * 6000});
    // With the range off, playback from its start sounds the same through it.
    ProjectSpec straight = p;
    straight.loopRange = false;
    same(readWav(r.files[0].path), live(straight, 16 * 6000, 4), __LINE__);
    std::filesystem::remove_all(dir);
}

TEST(stems_start_together_have_the_same_length_and_add_up_to_the_mix) {
    const ProjectSpec p = band();
    const std::string dir = tempDir("stems");
    SongRenderRequest q = floatRequest(dir);
    q.tracks = true;
    q.buses = true;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    CHECK_EQ(r.files.size(), size_t{5});
    for (const RenderedFile& f : r.files) CHECK_EQ(f.frames, r.files[0].frames);
    CHECK_EQ(fileFor(r, "a")->name, std::string("Band_Bass.wav"));
    CHECK_EQ(fileFor(r, "verb")->kind, std::string("bus"));
    CHECK_EQ(fileFor(r, "c")->kind, std::string("track"));
    const std::vector<float> mix = readWav(fileFor(r, "")->path);
    const std::vector<float> a = readWav(fileFor(r, "a")->path), b = readWav(fileFor(r, "b")->path),
                             v = readWav(fileFor(r, "verb")->path), c = readWav(fileFor(r, "c")->path);
    // The stems that reach the master (the two top-level tracks and the bus, which carries the lead and the send)
    // add up to the mix: the master has no effects here and its limiter stays idle.
    double worst = 0, energyLead = 0, energyBus = 0;
    for (size_t i = 0; i < mix.size(); ++i) {
        worst = std::max(worst, std::fabs(static_cast<double>(a[i]) + b[i] + v[i] - mix[i]));
        energyLead += static_cast<double>(c[i]) * c[i];
        energyBus += static_cast<double>(v[i]) * v[i];
    }
    CHECK(worst < 1e-5);
    CHECK(energyLead > 1.0);  // the lead has a stem of its own, and the bus (the lead, the send and the reverb) sounds
    CHECK(energyBus > 1.0);
    // Each stem is what its layer sounds like in the mix: soloed, the mix is that stem.
    ProjectSpec solo = p;
    solo.layers[1].solo = true;
    const std::vector<float> soloed = live(solo, r.files[0].frames);
    double soloWorst = 0;
    for (size_t i = 0; i < soloed.size(); ++i) soloWorst = std::max(soloWorst, std::fabs(static_cast<double>(soloed[i]) - b[i]));
    CHECK(soloWorst < 1e-6);
    std::filesystem::remove_all(dir);
}

TEST(stems_without_the_master_are_what_each_layer_sends_on) {
    ProjectSpec p = band();
    p.master = 1.0;
    const std::string dir = tempDir("raw");
    SongRenderRequest q = floatRequest(dir);
    q.mix = false;
    q.layers = {"b"};
    q.stemsThroughMaster = false;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    CHECK_EQ(r.files.size(), size_t{1});
    // The byte track alone, at the master's input: playback with the master's DC filter and limiter bypassed.
    p.layers[1].solo = true;
    Engine e(48000);
    e.setMasterBypass(true);
    e.setProject(p);
    e.play();
    const int64_t len = r.files[0].frames;
    std::vector<float> l(static_cast<size_t>(len)), rr(static_cast<size_t>(len));
    for (int64_t i = 0; i < len; i += 512) e.process(l.data() + i, rr.data() + i, static_cast<int>(std::min<int64_t>(512, len - i)));
    const std::vector<float> stem = readWav(r.files[0].path);
    bool same = true;
    for (int64_t i = 0; i < len && same; ++i) same = stem[2 * i] == l[i] && stem[2 * i + 1] == rr[i];
    CHECK(same);
    std::filesystem::remove_all(dir);
}

TEST(a_fixed_tail_adds_its_seconds_and_until_silent_ends_once_everything_is_quiet) {
    ProjectSpec p = band();
    p.layers.erase(p.layers.begin() + 1);  // the byte track never stops on its own
    const std::string dir = tempDir("tail");
    SongRenderRequest q = floatRequest(dir);
    q.tracks = true;
    q.tail = SongTail::Seconds;
    q.tailSeconds = 1.5;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    const int64_t len = 2 * 16 * 6000;
    for (const RenderedFile& f : r.files) CHECK_EQ(f.frames, len + 72000);
    // The song's own frames are unchanged by the tail.
    const std::vector<float> withTail = readWav(fileFor(r, "")->path);
    const std::vector<float> plain = live(p, len);
    CHECK(std::equal(plain.begin(), plain.end(), withTail.begin()));
    double tailEnergy = 0;
    for (size_t i = static_cast<size_t>(2 * len); i < withTail.size(); ++i) tailEnergy += static_cast<double>(withTail[i]) * withTail[i];
    CHECK(tailEnergy > 1e-3);  // the reverb rings on past the end

    const std::string dir2 = tempDir("silent");
    q.outDir = dir2;
    q.tail = SongTail::Silence;
    q.tailSeconds = 30;
    q.silenceDb = -60;
    SongRenderResult s;
    CHECK(renderSong(p, q, s));
    const int64_t frames = s.files.at(0).frames;
    for (const RenderedFile& f : s.files) CHECK_EQ(f.frames, frames);
    CHECK(frames > len);
    CHECK(frames < len + 30 * 48000);
    const std::vector<float> mix = readWav(fileFor(s, "")->path);
    double end = 0;
    for (size_t i = mix.size() - 960; i < mix.size(); ++i) end = std::max(end, static_cast<double>(std::fabs(mix[i])));
    CHECK(end < 1e-3);  // -60 dB
    std::filesystem::remove_all(dir);
    std::filesystem::remove_all(dir2);
}

TEST(peak_normalising_sets_the_peak_and_loudness_normalising_meets_its_target) {
    const ProjectSpec p = band();
    const std::string dir = tempDir("norm");
    SongRenderRequest q = floatRequest(dir);
    q.normalize = SongNormalize::Peak;
    q.target = -3.0;
    q.tracks = true;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    const std::vector<float> mix = readWav(fileFor(r, "")->path);
    CHECK_NEAR(peakDb(mix), -3.0, 1e-3);
    CHECK_NEAR(fileFor(r, "")->peakDb, -3.0, 1e-3);
    // Stems take the mix's gain, so they still add up to it.
    CHECK_NEAR(fileFor(r, "a")->gainDb, fileFor(r, "")->gainDb, 1e-12);

    const std::string dir2 = tempDir("lufs");
    q.outDir = dir2;
    q.normalize = SongNormalize::Lufs;
    q.target = -20.0;
    q.ceiling = 1.0;  // off
    q.tracks = false;
    SongRenderResult s;
    CHECK(renderSong(p, q, s));
    const std::vector<float> loud = readWav(s.files.at(0).path);
    LoudnessMeter m;
    m.prepare(48000);
    std::vector<float> l, rr;
    for (size_t i = 0; i < loud.size(); i += 2) l.push_back(loud[i]), rr.push_back(loud[i + 1]);
    m.process(l.data(), rr.data(), static_cast<int>(l.size()));
    CHECK_NEAR(m.read().integrated, -20.0, 0.02);
    CHECK_NEAR(s.files[0].lufs, -20.0, 0.02);

    // A ceiling holds a loud target back to the true peak it allows.
    const std::string dir3 = tempDir("ceil");
    q.outDir = dir3;
    q.target = -3.0;
    q.ceiling = -6.0;
    SongRenderResult c;
    CHECK(renderSong(p, q, c));
    CHECK(peakDb(readWav(c.files.at(0).path)) <= -6.0 + 1e-3);
    CHECK(c.files[0].lufs < -3.5);
    std::filesystem::remove_all(dir);
    std::filesystem::remove_all(dir2);
    std::filesystem::remove_all(dir3);
}

TEST(sixteen_bit_renders_dither_the_same_way_every_time_and_keep_silence_silent) {
    ProjectSpec p = band();
    const std::string dir = tempDir("dither");
    SongRenderRequest q = floatRequest(dir);
    q.bitDepth = 16;
    q.pattern = "{project}_one";
    SongRenderResult r1, r2, r3;
    CHECK(renderSong(p, q, r1));
    q.pattern = "{project}_two";
    CHECK(renderSong(p, q, r2));
    q.pattern = "{project}_plain";
    q.dither = false;
    CHECK(renderSong(p, q, r3));
    int bits = 0;
    const std::vector<float> d = readWav(r1.files.at(0).path, &bits);
    CHECK_EQ(bits, 16);
    CHECK(bytesOf(r1.files[0].path) == bytesOf(r2.files.at(0).path));
    CHECK(bytesOf(r1.files[0].path) != bytesOf(r3.files.at(0).path));
    // Dither moves samples by at most one step either way.
    const std::vector<float> plain = readWav(r3.files[0].path);
    double worst = 0;
    for (size_t i = 0; i < d.size(); ++i) worst = std::max(worst, std::fabs(static_cast<double>(d[i]) - plain[i]));
    CHECK(worst <= 1.0 / 32767.0 + 1e-6);
    CHECK(worst > 0);

    ProjectSpec quiet = p;
    for (LayerSpec& l : quiet.layers) l.mute = true;
    q.pattern = "{project}_quiet";
    q.dither = true;
    SongRenderResult s;
    CHECK(renderSong(quiet, q, s));
    bool silent = true;
    for (float v : readWav(s.files.at(0).path)) silent = silent && v == 0.0f;
    CHECK(silent);
    std::filesystem::remove_all(dir);
}

TEST(regions_render_a_set_each_with_unique_names) {
    const ProjectSpec p = band();
    const std::string dir = tempDir("regions");
    SongRenderRequest q = floatRequest(dir);
    q.bounds = SongBounds::Regions;
    q.regions = {{"Verse", 0, 8}, {"Verse", 8, 24}, {"Out", 16, 32}};
    q.layers = {"a"};
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    CHECK_EQ(r.files.size(), size_t{6});
    CHECK_EQ(r.files[0].name, std::string("Band_Verse.wav"));
    CHECK_EQ(r.files[1].name, std::string("Band_Verse_Bass.wav"));
    CHECK_EQ(r.files[2].name, std::string("Band_Verse_2.wav"));
    CHECK_EQ(r.files[4].name, std::string("Band_Out.wav"));
    CHECK_EQ(r.files[0].frames, int64_t{8 * 6000});
    CHECK_EQ(r.files[3].frames, int64_t{16 * 6000});
    same(readWav(r.files[4].path), live(p, 16 * 6000, 16), __LINE__);
    CHECK_EQ(fileCount(dir), size_t{6});
    std::filesystem::remove_all(dir);
}

TEST(a_cancelled_or_failed_song_render_leaves_no_file) {
    const ProjectSpec p = band();
    const std::string dir = tempDir("cancel");
    SongRenderRequest q = floatRequest(dir);
    q.tracks = true;
    int32_t cancel = 1, progress = 0;
    SongRenderResult r;
    CHECK(!renderSong(p, q, r, &progress, &cancel));
    CHECK_EQ(r.error, std::string("cancelled"));
    CHECK_EQ(fileCount(dir), size_t{0});
    // The second region is empty: the first one's files go too.
    q.bounds = SongBounds::Regions;
    q.regions = {{"A", 0, 8}, {"B", 8, 8}};
    CHECK(!renderSong(p, q, r));
    CHECK(r.error.find("'B'") != std::string::npos);
    CHECK_EQ(fileCount(dir), size_t{0});
    q.outDir = dir + "/missing";
    CHECK(!renderSong(p, q, r));
    std::filesystem::remove_all(dir);
}

TEST(the_song_render_request_is_checked) {
    SongRenderRequest r;
    std::string err;
    CHECK(parseSongRenderRequest(R"({"out_dir":"/x","tracks":true,"bounds":"regions","regions":[{"name":"A",
        "start_steps":0,"end_steps":16}],"bit_depth":16,"normalize":"lufs","tail":"silence"})", r, err));
    CHECK(r.tracks && r.bitDepth == 16 && r.normalize == SongNormalize::Lufs && r.target == -14.0);
    CHECK(r.tail == SongTail::Silence && r.tailSeconds == 30.0 && r.regions.size() == 1);
    CHECK(!parseSongRenderRequest(R"({"bit_depth":20})", r, err));
    CHECK(!parseSongRenderRequest(R"({"bounds":"forever"})", r, err));
    CHECK(!parseSongRenderRequest(R"({"stems":true})", r, err));
    CHECK(err.find("stems") != std::string::npos);
    CHECK(!parseSongRenderRequest(R"({"start_steps":-1})", r, err));
    CHECK(!parseSongRenderRequest(R"({"layers":"a"})", r, err));
}

TEST(song_renders_run_through_the_c_api_and_the_worker_pool) {
    const std::string dir = tempDir("capi");
    const std::string project = R"js({"bpm":120,"loop_bars":1,"modules":[{"id":"m","source":"---\nkind: pattern\n---\n0 C4 16 1\n"}],
        "layers":[{"id":"l","name":"Loop","pattern":"m","instrument":{"id":"org.caw.test.osc","params":{"mode":1,"shape":1}}}]})js";
    const std::string request = R"({"out_dir":")" + dir + R"(","project":"Song","tracks":true,"bit_depth":24})";
    char* out = caw_render_song(project.c_str(), request.c_str(), nullptr, nullptr);
    const std::string text = out;
    caw_free(out);
    CHECK(text.find("\"ok\":true") != std::string::npos);
    CHECK(text.find("Song_Loop.wav") != std::string::npos);
    CHECK_EQ(fileCount(dir), size_t{2});

    CawWorkerPool* pool = caw_worker_pool_create(2);
    const std::string request2 = R"({"out_dir":")" + dir + R"(","project":"Pool"})";
    CawJob* job = caw_worker_pool_submit_song(pool, project.c_str(), request2.c_str(), CAW_JOB_OFFLINE);
    CHECK(job != nullptr);
    CHECK_EQ(caw_job_wait(job, 0xffffffffu), 0);
    CawJobStatus st{};
    st.struct_size = sizeof st;
    caw_job_get_status(job, &st);
    CHECK_EQ(st.state, int32_t{CAW_JOB_SUCCEEDED});
    char* result = caw_job_result(job);
    CHECK(result != nullptr && std::string(result).find("Pool.wav") != std::string::npos);
    if (result) caw_free(result);
    caw_job_release(job);
    const std::string bad = R"({"out_dir":")" + dir + R"(/none"})";
    job = caw_worker_pool_submit_song(pool, project.c_str(), bad.c_str(), CAW_JOB_OFFLINE);
    caw_job_wait(job, 0xffffffffu);
    caw_job_get_status(job, &st);
    CHECK_EQ(st.state, int32_t{CAW_JOB_FAILED});
    char* error = caw_job_error(job);
    CHECK(error != nullptr && std::string(error).find("doesn't exist") != std::string::npos);
    if (error) caw_free(error);
    caw_job_release(job);
    caw_worker_pool_destroy(pool);
    std::filesystem::remove_all(dir);
}

TEST(sixteen_bit_wav_encoding_rounds_and_clips) {
    WavSpec spec;
    spec.channels = 1;
    spec.pcmBits = 16;
    const float x[] = {0.0f, 1.0f, -1.0f, 0.5f, 2.0f};
    const std::vector<uint8_t> b = encodeWav(spec, x, 5);
    CHECK_EQ(b.size(), size_t{44 + 10});
    auto at = [&](int i) { return static_cast<int16_t>(b[44 + 2 * i] | (b[45 + 2 * i] << 8)); };
    CHECK_EQ(at(0), int16_t{0});
    CHECK_EQ(at(1), int16_t{32767});
    CHECK_EQ(at(2), int16_t{-32767});
    CHECK_EQ(at(3), int16_t{16384});
    CHECK_EQ(at(4), int16_t{32767});
    CHECK_EQ(b[34], uint8_t{16});  // bits per sample
}

// ---------- freeze and bounce (1.0.5, #209) ----------

namespace freeze {

// A 32-bit float stereo WAV's samples, interleaved.
std::vector<float> readFloatWav(const std::string& path) {
    std::ifstream in(path, std::ios::binary);
    const std::vector<uint8_t> b((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    auto u32 = [&](size_t at) {
        return static_cast<uint32_t>(b[at] | (b[at + 1] << 8) | (b[at + 2] << 16) | (static_cast<uint32_t>(b[at + 3]) << 24));
    };
    std::vector<float> out;
    for (size_t at = 12; at + 8 <= b.size();) {
        const std::string tag(b.begin() + static_cast<long>(at), b.begin() + static_cast<long>(at) + 4);
        const uint32_t size = u32(at + 4);
        if (tag == "data")
            for (size_t i = at + 8; i + 4 <= at + 8 + size; i += 4) {
                float v;
                std::memcpy(&v, &b[i], 4);
                out.push_back(v);
            }
        at += 8 + size + (size & 1);
    }
    return out;
}

ComponentSpec effect(const std::string& id, std::vector<std::pair<std::string, double>> params = {}) {
    ComponentSpec c;
    c.id = id;
    c.params = std::move(params);
    return c;
}

// A synth-like track (the test signal's saw under notes) through a delay that rings past its last note, with a
// fader, pan and a post-fader send into a reverb bus that stay live; a second track and the bus beside it.
ProjectSpec song(bool ramp) {
    ProjectSpec p;
    p.name = "Freeze";
    p.bpm = 120;
    p.loopBars = 2;
    p.master = 0.7;
    if (ramp) p.tempoMap = {{0, 120, true}, {4, 90, false}};  // 120 down to 90 over the first bar, then 90
    p.modules.push_back({"riff", "---\nkind: pattern\nlength: 8\n---\n0 A2 2 1\n4 C3 1 0.8\n6 E3 2 0.6\n"});
    LayerSpec a = cawtest::testSignalNotesLayer("a", cawtest::Shape::Saw, "", {{"level", 0.3}},
                                                {effect("org.caw.delay.pro")});
    a.name = "Synth";
    a.clips.push_back({"ca", "riff", 0, 24, 0, true});  // ends at step 24 of 32: the delay rings on
    a.volume = 0.6;
    a.pan = 0.35;
    a.sends = {{"verb", 0.4, false, false}};
    LayerSpec b = cawtest::testSignalNotesLayer("b", cawtest::Shape::Sine, "riff", {{"level", 0.2}});
    b.name = "Other";
    LayerSpec v;
    v.id = v.name = "verb";
    v.folder = true;
    v.busEnabled = true;
    v.components = {effect("org.caw.reverb.pro")};
    p.layers = {a, b, v};
    return p;
}

SongRenderRequest request(const std::string& dir) {
    SongRenderRequest r;
    r.outDir = dir;
    r.project = "Freeze";
    r.bitDepth = 32;
    return r;
}

// Freeze's render of layer `id`: its pre-fader stem over the song, with a tail until it is quiet.
std::string freezeRender(const ProjectSpec& p, const std::string& id, const std::string& dir, int64_t* frames = nullptr) {
    SongRenderRequest q = request(dir);
    q.mix = false;
    q.layers = {id};
    q.stemsPreFader = true;
    q.stemsThroughMaster = false;
    q.pattern = "frozen_{stem}";
    q.tail = SongTail::Silence;
    q.tailSeconds = 30;
    q.silenceDb = -150;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    CHECK_EQ(r.files.size(), size_t{1});
    if (frames) *frames = r.files.empty() ? 0 : r.files[0].frames;
    return r.files.empty() ? std::string() : r.files[0].path;
}

// The project with layer `id` frozen as the app sends it: an audio track playing `path` from step 0 at the file's
// speed in place of its instrument and effects; its notes, fader, pan and sends stay.
ProjectSpec frozen(ProjectSpec p, const std::string& id, const std::string& path) {
    for (LayerSpec& l : p.layers) {
        if (l.id != id) continue;
        auto track = std::make_shared<AudioTrackSpec>();
        AudioClipSpec c;
        c.id = "frozen";
        c.path = path;
        c.startSteps = 0;
        c.lengthSteps = 4096;  // past the file's end: the clip ends with it
        track->clips.push_back(c);
        l.instrument = ComponentSpec{};
        l.instrument.id = kAudioTrackId;
        l.instrument.audioTrack = std::move(track);
        l.components.clear();
        l.noteComponents.clear();
    }
    return p;
}

std::vector<float> mixRender(const ProjectSpec& p, const std::string& dir, double tailSeconds) {
    SongRenderRequest q = request(dir);
    q.pattern = "mix_{index}";
    q.tail = SongTail::Seconds;
    q.tailSeconds = tailSeconds;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    return r.files.empty() ? std::vector<float>{} : readFloatWav(r.files[0].path);
}

// The largest difference between two renders, in dBFS (-400 for identical ones).
double residualDb(const std::vector<float>& a, const std::vector<float>& b) {
    double worst = 0;
    for (size_t i = 0; i < std::max(a.size(), b.size()); ++i) {
        const double x = i < a.size() ? a[i] : 0.0, y = i < b.size() ? b[i] : 0.0;
        worst = std::max(worst, std::fabs(x - y));
    }
    return worst > 0 ? 20.0 * std::log10(worst) : -400.0;
}

double energy(const std::vector<float>& x, size_t from = 0) {
    double e = 0;
    for (size_t i = from; i < x.size(); ++i) e += static_cast<double>(x[i]) * x[i];
    return e;
}

}  // namespace freeze

using namespace freeze;

TEST(a_frozen_track_renders_the_same_as_the_live_track_with_its_tail) {
    const ProjectSpec p = song(false);
    const std::string dir = tempDir("same");
    int64_t frames = 0;
    const std::string path = freezeRender(p, "a", dir, &frames);
    CHECK(frames > 2 * 16 * 6000);  // past the song's end: the delay's tail
    const std::vector<float> live = mixRender(p, dir, 4.0);
    const std::vector<float> ice = mixRender(frozen(p, "a", path), dir, 4.0);
    CHECK_EQ(live.size(), ice.size());
    CHECK(energy(live, 2 * 2 * 16 * 6000) > 1e-4);  // the tail sounds past the song's end
    // Bit for bit: the stem is float, the clip plays it at the file's own speed and rate, and the fader, pan and
    // send then do the same arithmetic on the same samples.
    const double db = residualDb(live, ice);
    if (db > -400) std::printf("  frozen vs live residual %.1f dBFS\n", db);
    CHECK(live == ice);
    std::filesystem::remove_all(dir);
}

TEST(a_frozen_track_follows_a_tempo_ramp) {
    const ProjectSpec p = song(true);
    const std::string dir = tempDir("ramp");
    const std::string path = freezeRender(p, "a", dir);
    const std::vector<float> live = mixRender(p, dir, 3.0);
    const std::vector<float> ice = mixRender(frozen(p, "a", path), dir, 3.0);
    CHECK_EQ(live.size(), ice.size());
    CHECK(energy(live) > 1.0);
    const double db = residualDb(live, ice);
    if (db > -400) std::printf("  frozen vs live on a ramp: residual %.1f dBFS\n", db);
    CHECK(live == ice);
    std::filesystem::remove_all(dir);
}

TEST(a_pre_fader_stem_skips_the_fader_pan_and_the_track_s_own_latency) {
    // The same notes through a transparent compressor (240 frames of declared latency) and without it: the pre-fader
    // stems line up, and neither has the fader's or the pan's gain.
    ProjectSpec p = song(false);
    p.layers[0].components = {effect("org.caw.compressor", {{"ratio", 1.0}, {"auto_makeup", 0.0}, {"makeup", 0.0},
                                                            {"threshold", 0.0}})};
    p.layers[0].volume = 0.25;
    p.layers[0].pan = -0.8;
    ProjectSpec plain = p;
    plain.layers[0].components.clear();
    const std::string dir = tempDir("latency");
    SongRenderRequest q = request(dir);
    q.mix = false;
    q.layers = {"a"};
    q.stemsPreFader = true;
    q.stemsThroughMaster = false;
    SongRenderResult withComp, without;
    q.pattern = "comp_{stem}";
    CHECK(renderSong(p, q, withComp));
    q.pattern = "plain_{stem}";
    CHECK(renderSong(plain, q, without));
    const std::vector<float> a = readFloatWav(withComp.files.at(0).path), b = readFloatWav(without.files.at(0).path);
    CHECK_EQ(a.size(), b.size());
    CHECK_EQ(withComp.files[0].frames, int64_t{2 * 16 * 6000});
    CHECK(residualDb(a, b) < -90.0);
    // The saw at level 0.3, before the fader: its peak is the instrument's, not 0.25 times it.
    double peak = 0;
    for (float v : b) peak = std::max(peak, static_cast<double>(std::fabs(v)));
    CHECK(peak > 0.2);
    CHECK(peak < 0.31);
    std::filesystem::remove_all(dir);
}

TEST(the_stem_tap_request_key_is_checked) {
    SongRenderRequest r;
    std::string error;
    CHECK(parseSongRenderRequest("{\"out_dir\":\"x\",\"stem_tap\":\"pre\"}", r, error));
    CHECK(r.stemsPreFader);
    CHECK(parseSongRenderRequest("{\"out_dir\":\"x\"}", r, error));
    CHECK(!r.stemsPreFader);
    CHECK(!parseSongRenderRequest("{\"out_dir\":\"x\",\"stem_tap\":\"middle\"}", r, error));
    CHECK(error.find("stem_tap") != std::string::npos);
}

TEST(a_bounce_of_a_clip_range_renders_just_that_range) {
    // Bounce to audio of a selection: the range's frames, from its first step, and nothing of the track before it.
    const ProjectSpec p = song(false);
    const std::string dir = tempDir("bounce");
    SongRenderRequest q = request(dir);
    q.mix = false;
    q.layers = {"a"};
    q.stemsPreFader = true;
    q.stemsThroughMaster = false;
    q.bounds = SongBounds::Selection;
    q.startSteps = 8;
    q.endSteps = 16;
    SongRenderResult r;
    CHECK(renderSong(p, q, r));
    CHECK_EQ(r.files.at(0).frames, int64_t{8 * 6000});
    CHECK(energy(readFloatWav(r.files[0].path)) > 1e-3);
    std::filesystem::remove_all(dir);
}

TEST(a_frozen_track_runs_no_instrument_or_effects_and_costs_about_an_audio_clip) {
    // The Benchmark's one busy Flagship with a reverb after it, live and frozen: frozen, the engine holds no insert of
    // the track (only the clip player as its instrument), and a second of audio costs a fraction of the live one's.
    ProjectSpec p = stress::singleSynth();
    p.layers.back().components = {effect("org.caw.reverb.pro")};
    const std::string id = p.layers.back().id;
    const std::string dir = tempDir("cpu");
    const std::string path = freezeRender(p, id, dir);
    const ProjectSpec ice = frozen(p, id, path);
    auto seconds = [](const ProjectSpec& q, std::string* states) {
        Engine e(48000);
        CHECK(e.setProject(q).find("\"ok\":true") != std::string::npos);
        if (states) *states = e.componentStatesJson(q.layers.back().id);
        e.play();
        std::vector<float> l(256), r(256);
        for (int k = 0; k < 188; ++k) e.process(l.data(), r.data(), 256);  // warm up: one second
        double best = 1e9;
        for (int run = 0; run < 3; ++run) {
            const auto t0 = std::chrono::steady_clock::now();
            for (int k = 0; k < 375; ++k) e.process(l.data(), r.data(), 256);  // two seconds of audio
            best = std::min(best, std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count());
        }
        return best / 2.0;  // per second of audio
    };
    std::string liveStates, frozenStates;
    const double live = seconds(p, &liveStates), cold = seconds(ice, &frozenStates);
    std::printf("  CPU per second of audio: live %.2f ms, frozen %.2f ms\n", live * 1e3, cold * 1e3);
    CHECK(liveStates.find("\"index\":0,") != std::string::npos);    // live: the reverb at insert 0
    CHECK(frozenStates.find("\"index\":0,") == std::string::npos);  // frozen: no insert runs
    std::filesystem::remove_all(dir);
}

TEST(a_frozen_clip_with_lengthens_song_false_keeps_the_song_s_length) {
    // The app sends a frozen track's clip with its tail past the song's end and "lengthens_song": false.
    ProjectSpec spec;
    std::string error;
    CHECK(parseProject("{\"loop_bars\":1,\"layers\":[{\"id\":\"t\",\"audio_clips\":[{\"id\":\"c\",\"path\":\"x.wav\","
                       "\"length_steps\":40,\"lengthens_song\":false}]}]}", spec, error));
    CHECK_EQ(spec.loopBars, 1);
    CHECK(parseProject("{\"loop_bars\":1,\"layers\":[{\"id\":\"t\",\"audio_clips\":[{\"id\":\"c\",\"path\":\"x.wav\","
                       "\"length_steps\":40}]}]}", spec, error));
    CHECK_EQ(spec.loopBars, 3);
}
