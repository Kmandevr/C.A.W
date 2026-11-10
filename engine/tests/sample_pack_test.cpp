// Tests for the sample-pack maker: names, grid, trim/fades/normalise, smpl loops read back, SFZ, path safety, real renders.
#include "test.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "caw.h"
#include "json.h"
#include "native_component_test_path.h"
#include "sample_pack.h"

using namespace caw;
namespace fs = std::filesystem;

namespace {

constexpr double kPi = 3.14159265358979323846;

fs::path freshDir(const char* tag) {
    static int n = 0;
    const fs::path d = fs::temp_directory_path() /
                       (std::string("caw_pack_") + tag + "_" +
                        std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()) + "_" +
                        std::to_string(n++));
    fs::create_directories(d);
    return d;
}

std::string esc(const fs::path& p) { return jsonEscape(p.string()); }

Json run(const std::string& request, NativeModuleTrust trust = NativeModuleTrust::Blocked) {
    Json j;
    std::string error;
    const std::string result = samplePackJson(request, trust);
    if (!parseJson(result, j, error)) cawtest::fail(__FILE__, __LINE__, "result is not JSON: " + result);
    return j;
}

// A regular file only, at most 64 MB.
std::vector<uint8_t> readBytes(const fs::path& p) {
    if (!fs::is_regular_file(fs::symlink_status(p)) || fs::file_size(p) > (64u << 20)) return {};
    std::ifstream f(p, std::ios::binary);
    return std::vector<uint8_t>((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
}

uint32_t le(const uint8_t* p, int n) {
    uint32_t v = 0;
    for (int i = 0; i < n; ++i) v |= static_cast<uint32_t>(p[i]) << (8 * i);
    return v;
}

struct Wav {
    bool ok = false;
    uint32_t format = 0, channels = 0, rate = 0, bits = 0, frames = 0;
    bool hasSmpl = false;
    uint32_t unity = 0, loops = 0, loopStart = 0, loopEnd = 0;
    std::vector<float> left;
};

Wav parseWav(const std::vector<uint8_t>& b) {
    Wav w;
    if (b.size() < 12 || std::memcmp(b.data(), "RIFF", 4) != 0 || std::memcmp(b.data() + 8, "WAVE", 4) != 0) return w;
    if (le(&b[4], 4) + 8 != b.size()) return w;
    const uint8_t* data = nullptr;
    std::size_t dataSize = 0;
    for (std::size_t at = 12; at + 8 <= b.size();) {
        const uint32_t size = le(&b[at + 4], 4);
        const std::size_t body = at + 8;
        if (body + size > b.size()) return w;
        if (std::memcmp(&b[at], "fmt ", 4) == 0) {
            w.format = le(&b[body], 2);
            w.channels = le(&b[body + 2], 2);
            w.rate = le(&b[body + 4], 4);
            w.bits = le(&b[body + 14], 2);
        } else if (std::memcmp(&b[at], "smpl", 4) == 0 && size >= 36) {
            w.hasSmpl = true;
            w.unity = le(&b[body + 12], 4);
            w.loops = le(&b[body + 28], 4);
            if (w.loops >= 1 && size >= 60) {
                w.loopStart = le(&b[body + 36 + 8], 4);
                w.loopEnd = le(&b[body + 36 + 12], 4);
            }
        } else if (std::memcmp(&b[at], "data", 4) == 0) {
            data = &b[body];
            dataSize = size;
        }
        at = body + size + (size & 1u);
    }
    if (!data || !w.channels || !w.bits) return w;
    const uint32_t bytes = w.bits / 8;
    w.frames = static_cast<uint32_t>(dataSize / (bytes * w.channels));
    for (uint32_t i = 0; i < w.frames; ++i) {
        const uint8_t* p = data + static_cast<std::size_t>(i) * w.channels * bytes;
        float v;
        if (w.format == 3) {
            const uint32_t u = le(p, 4);
            std::memcpy(&v, &u, 4);
        } else {
            const uint32_t u = le(p, static_cast<int>(bytes)) << (32 - w.bits);
            v = static_cast<float>(static_cast<int32_t>(u) / 2147483648.0);
        }
        w.left.push_back(v);
    }
    w.ok = true;
    return w;
}

std::vector<std::string> wavFiles(const fs::path& d) {
    std::vector<std::string> out;
    for (const auto& e : fs::directory_iterator(d))
        if (e.path().extension() == ".wav") out.push_back(e.path().filename().string());
    std::sort(out.begin(), out.end());
    return out;
}

}  // namespace

TEST(sample_pack_note_names_round_trip) {
    CHECK_EQ(noteName(60), std::string("C4"));
    CHECK_EQ(noteName(66), std::string("F#4"));
    CHECK_EQ(noteName(48), std::string("C3"));
    CHECK_EQ(noteName(0), std::string("C-1"));
    CHECK_EQ(noteName(127), std::string("G9"));
    for (int n = 0; n <= 127; ++n) {
        int back = -1;
        CHECK(parseNoteName(noteName(n), back));
        CHECK_EQ(back, n);
    }
    int v = 0;
    CHECK(parseNoteName("Bb0", v) && v == 22);
    CHECK(parseNoteName("c4", v) && v == 60);
    CHECK(!parseNoteName("H4", v));
    CHECK(!parseNoteName("G#9", v));  // 128
    CHECK(!parseNoteName("C-2", v));
    CHECK(!parseNoteName("C44", v));
}

TEST(sample_pack_names_are_sanitised) {
    CHECK_EQ(sanitizeFileName("../../etc/passwd"), std::string("_._etc_passwd"));
    CHECK_EQ(sanitizeFileName("a/b\\c:d"), std::string("a_b_c_d"));
    CHECK_EQ(sanitizeFileName(".hidden"), std::string("hidden"));
    CHECK_EQ(sanitizeFileName(""), std::string("sample"));
    CHECK_EQ(sanitizeFileName("..."), std::string("sample"));
    CHECK_EQ(sanitizeFileName("CON"), std::string("_CON"));
    CHECK_EQ(sanitizeFileName("lpt1.wav"), std::string("_lpt1.wav"));
    CHECK_EQ(sanitizeFileName("Lead F#4 v100"), std::string("Lead_F#4_v100"));
    CHECK(sanitizeFileName(std::string(400, 'x')).size() <= 150);
    for (const char* bad : {"x/../y", "..\\..\\z", "a..b"}) {
        const std::string s = sanitizeFileName(bad);
        CHECK(s.find('/') == std::string::npos && s.find('\\') == std::string::npos && s.find("..") == std::string::npos);
    }
    CHECK_EQ(expandNamePattern("{name}_{note}_{vel}_{param}", "lead", 66, 100, "", 0), std::string("lead_F#4_100"));
    CHECK_EQ(expandNamePattern("{name}_{note}_{vel}_{param}", "lead", 60, 64, "cutoff-1200", 3),
             std::string("lead_C4_64_cutoff-1200"));
    CHECK_EQ(expandNamePattern("{index}-{midi}/{unknown}", "x", 61, 1, "", 7), std::string("7-61_unknown"));
    CHECK_EQ(expandNamePattern("../{name}", "../../x", 60, 1, "", 0).find(".."), std::string::npos);
    CHECK_EQ(paramLabel({{"cutoff", "1200"}, {"detune", "-7"}}), std::string("cutoff-1200_detune-m7"));
}

TEST(sample_pack_trim_and_fades_on_known_signals) {
    std::vector<float> l(100, 0.0f), r(100, 0.0f);
    for (int i = 20; i < 70; ++i) l[i] = 0.5f;
    r[75] = 0.0001f;  // -80 dB: kept at -100 dB, trimmed at -60 dB
    std::vector<float> l2 = l, r2 = r;
    CHECK_EQ(trimSilence(l, r, -100, true, true), static_cast<std::size_t>(20));
    CHECK_EQ(l.size(), static_cast<std::size_t>(56));
    CHECK_EQ(trimSilence(l2, r2, -60, false, true), static_cast<std::size_t>(0));
    CHECK_EQ(l2.size(), static_cast<std::size_t>(70));
    std::vector<float> sl(10, 0.0f), sr(10, 0.0f);
    trimSilence(sl, sr, -80, true, true);
    CHECK(sl.empty() && sr.empty());

    std::vector<float> a(10, 1.0f), b(10, 1.0f);
    applyFades(a, b, 4, 5);
    CHECK_EQ(a[0], 0.0f);
    CHECK_NEAR(a[2], 0.5, 1e-7);
    CHECK_EQ(a[4], 1.0f);
    CHECK_EQ(a[9], 0.0f);
    CHECK_NEAR(a[7], 0.4, 1e-7);
    CHECK_EQ(b[9], 0.0f);
    std::vector<float> c(3, 1.0f), d(3, 1.0f);
    applyFades(c, d, 100, 100);  // longer than the file: clamped
    CHECK_EQ(c[0], 0.0f);
}

TEST(sample_pack_finds_a_loop_at_matching_zero_crossings) {
    const double sr = 48000, f = 200;  // 240 frames a cycle
    std::vector<float> l(48000), r(48000);
    for (std::size_t i = 0; i < l.size(); ++i) l[i] = r[i] = static_cast<float>(0.5 * std::sin(2 * kPi * f * (i + 0.5) / sr));
    const PackLoop loop = findLoop(l, r, 12000, 40000, 2400);
    CHECK(loop.found);
    CHECK((loop.end + 1 - loop.start) % 240 == 0);  // whole cycles
    CHECK(loop.end <= 40000);
    CHECK(loop.end + 1 - loop.start >= 2400);
    CHECK(loop.matchDb < -60);
    CHECK_EQ(loop.start, static_cast<std::size_t>(12000));  // ties keep the longest loop
    std::vector<float> z(48000, 0.0f);
    CHECK(!findLoop(z, z, 1000, 40000, 2400).found);  // no crossings
}

TEST(sample_pack_wav_smpl_chunk_reads_back) {
    std::vector<float> l = {0.0f, 0.5f, -0.5f, 1.0f, -1.0f, 2.0f}, r(l.size(), 0.25f);
    PackWavSpec spec;
    spec.sampleRate = 44100;
    spec.bitDepth = 16;
    spec.channels = 2;
    spec.rootNote = 66;
    spec.loop = true;
    spec.loopStart = 1;
    spec.loopEnd = 4;
    const Wav w = parseWav(encodePackWav(spec, l, r));
    CHECK(w.ok);
    CHECK_EQ(w.format, 1u);
    CHECK_EQ(w.bits, 16u);
    CHECK_EQ(w.rate, 44100u);
    CHECK_EQ(w.frames, 6u);
    CHECK(w.hasSmpl);
    CHECK_EQ(w.unity, 66u);
    CHECK_EQ(w.loops, 1u);
    CHECK_EQ(w.loopStart, 1u);
    CHECK_EQ(w.loopEnd, 4u);
    CHECK_NEAR(w.left[1], 0.5, 1e-4);
    CHECK_NEAR(w.left[5], 32767.0 / 32768.0, 1e-9);  // clipped to full scale
    spec.bitDepth = 24;
    spec.loop = false;
    spec.channels = 1;
    const Wav m = parseWav(encodePackWav(spec, l, r));
    CHECK(m.ok && m.bits == 24 && m.channels == 1 && m.hasSmpl && m.loops == 0 && m.unity == 66);
    CHECK_NEAR(m.left[2], -0.5, 1e-6);
    spec.bitDepth = 32;
    const Wav fl = parseWav(encodePackWav(spec, l, r));
    CHECK(fl.ok && fl.format == 3 && fl.bits == 32);
    CHECK_EQ(fl.left[5], 2.0f);  // float keeps over-full-scale values
}

TEST(sample_pack_sfz_maps_keys_and_velocities) {
    std::vector<SfzRegion> regions;
    for (int note : {48, 60, 72})
        for (int vel : {64, 127}) {
            SfzRegion r;
            r.sample = "s_" + std::to_string(note) + "_" + std::to_string(vel) + ".wav";
            r.note = note;
            r.velocity = vel;
            r.loop = note == 60;
            r.loopStart = 100;
            r.loopEnd = 999;
            regions.push_back(r);
        }
    const std::string s = sfzText("pack", regions);
    CHECK(s.find("<region> sample=s_48_64.wav lokey=0 hikey=54 pitch_keycenter=48 lovel=1 hivel=64 loop_mode=no_loop\n") !=
          std::string::npos);
    CHECK(s.find("<region> sample=s_60_127.wav lokey=55 hikey=66 pitch_keycenter=60 lovel=65 hivel=127 "
                 "loop_mode=loop_continuous loop_start=100 loop_end=999\n") != std::string::npos);
    CHECK(s.find("sample=s_72_127.wav lokey=67 hikey=127 ") != std::string::npos);
    CHECK_EQ(s.rfind("// pack", 0), static_cast<std::size_t>(0));
}

TEST(sample_pack_renders_the_basic_synth) {
    // The retired basic synth: Flagship's Basic preset, its knobs (and the cutoff steps) mapped to Flagship's.
    const fs::path dir = freshDir("synth");
    const std::string req = "{\"instrument\":{\"id\":\"org.caw.synth.basic\",\"params\":{\"release\":0.05}},"
                            "\"output_dir\":\"" + esc(dir / "pack") + "\",\"name\":\"lead\","
                            "\"notes\":[\"C3\",64],\"velocities\":[64,127],"
                            "\"params\":[{\"id\":\"cutoff\",\"values\":[800,4000]}],"
                            "\"hold_seconds\":0.3,\"bit_depth\":24,\"loop\":true,\"sfz\":true,"
                            "\"normalize\":{\"mode\":\"peak\",\"target_db\":-3,\"scope\":\"group\"},\"fade_out_ms\":5}";
    const Json r = run(req);
    CHECK(r.boolean("ok", false));
    if (!r.boolean("ok", false)) std::printf("%s\n", r.string("error").c_str());
    CHECK_EQ(r.number("file_count", 0), 8.0);
    const std::vector<std::string> files = wavFiles(dir / "pack");
    CHECK_EQ(files.size(), static_cast<std::size_t>(8));
    CHECK(fs::exists(dir / "pack" / "lead_C3_64_flt1_cutoff-800.wav"));
    CHECK(fs::exists(dir / "pack" / "lead_E4_127_flt1_cutoff-4000.wav"));
    CHECK(fs::exists(dir / "pack" / "lead.json"));
    CHECK(fs::exists(dir / "pack" / "lead_flt1_cutoff-800.sfz"));
    CHECK(fs::exists(dir / "pack" / "lead_flt1_cutoff-4000.sfz"));
    double loudest = 0;
    for (const std::string& f : files) {
        const Wav w = parseWav(readBytes(dir / "pack" / f));
        CHECK(w.ok && w.bits == 24 && w.channels == 2 && w.rate == 48000);
        CHECK(w.frames > 0.3 * 48000 && w.frames < 1.5 * 48000);  // the hold plus a short release, trimmed
        double peak = 0;
        for (float x : w.left) peak = std::max(peak, static_cast<double>(std::fabs(x)));
        CHECK(peak > 0.01);  // not silent
        loudest = std::max(loudest, peak);
        CHECK(w.hasSmpl);
        CHECK(w.unity == 48 || w.unity == 64);
        CHECK_EQ(w.loops, 1u);
        CHECK(w.loopEnd > w.loopStart && w.loopEnd < w.frames);
    }
    CHECK(loudest > 0.6 && loudest < 0.72);  // the group peak: -3 dB on the loudest file (both channels)
    const Json* list = r.get("files");
    CHECK(list && list->arr.size() == 8);
    if (list && !list->arr.empty()) {
        const Json& f0 = list->arr[0];
        CHECK_EQ(f0.string("file"), std::string("lead_C3_64_flt1_cutoff-800.wav"));
        CHECK_EQ(f0.number("note", 0), 48.0);
        CHECK_EQ(f0.string("note_name"), std::string("C3"));
        CHECK(f0.get("loop") && f0.get("loop")->type == Json::Type::Object);
    }
    // Deterministic: the same request (in another directory) gives the same bytes.
    const fs::path dir2 = freshDir("synth2");
    std::string req2 = req;
    req2.replace(req2.find(esc(dir / "pack")), esc(dir / "pack").size(), esc(dir2));
    const Json r2 = run(req2);
    CHECK(r2.boolean("ok", false));
    for (const std::string& f : files) CHECK(readBytes(dir / "pack" / f) == readBytes(dir2 / f));
    CHECK(readBytes(dir / "pack" / "lead.json") == readBytes(dir2 / "lead.json"));
    // Again into the same directory: refused without overwrite, the same bytes with it.
    CHECK(!run(req).boolean("ok", true));
    std::string again = req;
    again.insert(again.size() - 1, ",\"overwrite\":true");
    CHECK(run(again).boolean("ok", false));
    for (const std::string& f : files) CHECK(readBytes(dir / "pack" / f) == readBytes(dir2 / f));
    std::string sfz;
    {
        std::ifstream in(dir / "pack" / "lead_flt1_cutoff-800.sfz");
        sfz.assign((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    }
    CHECK(sfz.find("sample=lead_C3_127_flt1_cutoff-800.wav lokey=0 hikey=56 pitch_keycenter=48 lovel=65 hivel=127 "
                   "loop_mode=loop_continuous") != std::string::npos);
    fs::remove_all(dir);
    fs::remove_all(dir2);
}

TEST(sample_pack_effects_mono_float_and_file_normalise) {
    const fs::path dir = freshDir("fx");
    const Json r = run("{\"instrument\":\"org.caw.synth.basic\",\"effects\":[{\"id\":\"org.caw.distortion\"},"
                       "\"org.caw.delay.pingpong\"],\"output_dir\":\"" + esc(dir) + "\",\"notes\":[60],"
                       "\"params\":[{\"id\":\"mix\",\"effect\":1,\"from\":0,\"to\":0.5,\"steps\":2}],"
                       "\"hold_seconds\":0.2,\"max_seconds\":1,\"bit_depth\":32,\"channels\":1,"
                       "\"normalize\":\"rms\",\"manifest\":false}");
    CHECK(r.boolean("ok", false));
    if (!r.boolean("ok", false)) std::printf("%s\n", r.string("error").c_str());
    const std::vector<std::string> files = wavFiles(dir);
    CHECK_EQ(files.size(), static_cast<std::size_t>(2));
    CHECK(!fs::exists(dir / "sample.json"));
    for (const std::string& f : files) {
        const Wav w = parseWav(readBytes(dir / f));
        CHECK(w.ok && w.format == 3 && w.channels == 1);
        double sum = 0;
        for (float x : w.left) sum += static_cast<double>(x) * x;
        CHECK_NEAR(20 * std::log10(std::sqrt(sum / w.frames)), -18.0, 0.01);
    }
    fs::remove_all(dir);
}

TEST(sample_pack_refuses_what_it_should) {
    const fs::path dir = freshDir("refuse");
    const std::string out = "\"output_dir\":\"" + esc(dir) + "\"";
    auto error = [&](const std::string& req, NativeModuleTrust t = NativeModuleTrust::Blocked) {
        const Json r = run(req, t);
        CHECK(!r.boolean("ok", true));
        return r.string("error");
    };
    const char* path = caw::test::nativeComponentPath();
    const std::string lib = jsonEscape(path ? path : "");
    const std::string echo = "{\"id\":\"org.caw.tests.native-loader.echo\",\"library\":\"" + lib + "\"}";
    // Trust comes from the caller only.
    CHECK(error("{\"instrument\":\"org.caw.synth.basic\",\"effects\":[" + echo + "]," + out + "}")
              .find("trusted") != std::string::npos);
    CHECK(!error("{\"instrument\":\"org.caw.synth.basic\",\"effects\":[" + echo + "]," + out + "}",
                 NativeModuleTrust::Isolated).empty());
    CHECK(error("{\"instrument\":\"org.caw.synth.basic\",\"effects\":[{\"id\":\"org.caw.tests.native-loader.echo\","
                "\"library\":\"" + lib + "\",\"trust\":\"trusted\"}]," + out + "}", NativeModuleTrust::Trusted)
              .find("'trust' is not read") != std::string::npos);
    // A trusted library effect does load and render.
    const Json ok = run("{\"instrument\":\"org.caw.synth.basic\",\"effects\":[" + echo + "]," + out +
                            ",\"hold_seconds\":0.05,\"max_seconds\":0.5}",
                        NativeModuleTrust::Trusted);
    CHECK(ok.boolean("ok", false));
    if (!ok.boolean("ok", false)) std::printf("%s\n", ok.string("error").c_str());
    CHECK(error("{\"instrument\":\"org.caw.synth.basic\"," + out + ",\"params\":[{\"id\":\"nope\",\"values\":[1]}]}")
              .find("nope") != std::string::npos);
    CHECK(error("{\"instrument\":{\"id\":\"org.caw.synth.flagship\",\"params\":{\"nope\":1}}," + out + "}")
              .find("nope") != std::string::npos);
    CHECK(error("{\"instrument\":\"org.caw.distortion\"," + out + "}").find("not an instrument") != std::string::npos);
    CHECK(error("{\"instrument\":\"org.example.missing\"," + out + "}").find("not built in") != std::string::npos);
    CHECK(error("{\"instrument\":\"org.caw.synth.basic\"," + out + ",\"notes\":{\"from\":0,\"to\":127},\"max_files\":64}")
              .find("max_files") != std::string::npos);
    CHECK(error("{\"instrument\":\"org.caw.synth.basic\"," + out + ",\"notes\":[60,61],\"name_pattern\":\"{name}\"}")
              .find("both be named") != std::string::npos);
    CHECK(error("{\"instrument\":\"org.caw.synth.basic\"," + out + ",\"bit_depth\":8}").find("bit_depth") !=
          std::string::npos);
    CHECK(error("{\"instrument\":\"org.caw.synth.basic\"," + out + ",\"velocity\":[1]}").find("velocity") !=
          std::string::npos);
    CHECK(!error("{\"instrument\":\"org.caw.synth.basic\"}").empty());  // no output_dir
    CHECK(!error("not json").empty());
    // Never outside the output directory: names are flattened, and a symlinked target is refused.
    const Json flat = run("{\"instrument\":\"org.caw.synth.basic\"," + out +
                          ",\"name\":\"../../escape\",\"name_pattern\":\"../{name}/{note}\",\"hold_seconds\":0.05}");
    CHECK(flat.boolean("ok", false));
    // Compared resolved: Windows can spell one folder two ways (a short 8.3 name and the long one).
    for (const auto& e : fs::directory_iterator(dir)) CHECK(fs::canonical(e.path()).parent_path() == fs::canonical(dir));
    CHECK(!fs::exists(dir.parent_path() / "escape.json"));
    const fs::path victim = freshDir("victim") / "target.wav";
    { std::ofstream(victim) << "keep"; }
    std::error_code ec;
    fs::create_symlink(victim, dir / "link_C4_100.wav", ec);
    if (!ec) {
        CHECK(error("{\"instrument\":\"org.caw.synth.basic\"," + out +
                    ",\"name\":\"link\",\"overwrite\":true,\"hold_seconds\":0.05}")
                  .find("symbolic link") != std::string::npos);
        std::ifstream in(victim);
        std::string kept;
        in >> kept;
        CHECK_EQ(kept, std::string("keep"));
    }
    fs::remove_all(dir);
    fs::remove_all(victim.parent_path());
}

TEST(sample_pack_c_api_trust_progress_and_cancel) {
    const fs::path dir = freshDir("capi");
    const std::string req = "{\"instrument\":\"org.caw.synth.basic\",\"output_dir\":\"" + esc(dir) +
                            "\",\"notes\":[60,67],\"hold_seconds\":0.05,\"max_seconds\":0.5}";
    int32_t progress = 0, cancel = 0;
    char* s = caw_sample_pack_render(req.c_str(), CAW_NATIVE_TRUST_BLOCKED, &progress, &cancel);
    Json j;
    std::string e;
    CHECK(parseJson(s, j, e) && j.boolean("ok", false));
    caw_free(s);
    CHECK_EQ(progress, 1000);
    CHECK_EQ(wavFiles(dir).size(), static_cast<std::size_t>(2));
    s = caw_sample_pack_render(req.c_str(), 7, nullptr, nullptr);
    CHECK(parseJson(s, j, e) && !j.boolean("ok", true));
    caw_free(s);
    cancel = 1;
    const std::string again = req.substr(0, req.size() - 1) + ",\"overwrite\":true}";
    s = caw_sample_pack_render(again.c_str(), CAW_NATIVE_TRUST_BLOCKED, &progress, &cancel);
    CHECK(parseJson(s, j, e) && !j.boolean("ok", true) && j.string("error") == "cancelled");
    caw_free(s);
    s = caw_sample_pack_render(nullptr, CAW_NATIVE_TRUST_BLOCKED, nullptr, nullptr);
    CHECK(parseJson(s, j, e) && !j.boolean("ok", true));
    caw_free(s);
    fs::remove_all(dir);
}
