// Batch 1.0.4 (#208): clip stretch and pitch (Signalsmith Stretch), clip fields, tempo-following, tempo detection, slices.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <random>
#include <filesystem>
#include <string>
#include <thread>
#include <vector>

#include "asset_store.h"
#include "audio_clips.h"
#include "builtin_components.h"
#include "module_registry.h"
#include "audio_analysis.h"
#include "caw.h"
#include "clip_stretch.h"
#include "engine.h"
#include "json.h"
#include "tempo_map.h"
#include "test.h"
#include "tolerance.h"
#include "utf8_path.h"
#include "wav.h"
#include "signalsmith-stretch/signalsmith-stretch.h"

using namespace caw;

namespace {

constexpr double kPi = 3.14159265358979323846;

struct TempRoot {
    std::filesystem::path path = std::filesystem::temp_directory_path() /
        ("caw_stretch_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
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

float noiseAt(int64_t i, int c) {
    uint32_t x = static_cast<uint32_t>(i * 2654435761u + c * 40503u + 1u);
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return static_cast<float>((x >> 8) / 8388608.0 - 1.0) * 0.5f;
}

// A drum loop at 120 BPM (48 kHz): a kick on every beat (a falling sine), a snare on 2 and 4 (noise), closed hats on
// the eighths.
float drumsAt(int64_t i, int c) {
    const int64_t beat = 24000, eighth = 12000;
    const int64_t inBeat = i % beat, inEighth = i % eighth, b = (i / beat) % 4;
    const double tb = static_cast<double>(inBeat) / 48000.0, te = static_cast<double>(inEighth) / 48000.0;
    double v = 0.7 * std::sin(2 * kPi * (50.0 * tb + 60.0 * (1 - std::exp(-tb * 30)) / 30)) * std::exp(-tb * 12);
    if (b == 1 || b == 3) v += 0.5 * noiseAt(i, c) * std::exp(-tb * 25);
    v += 0.15 * noiseAt(i * 7 + 3, c) * std::exp(-te * 120);
    return static_cast<float>(v);
}

// A tonal loop: an A minor chord with a slow swell.
float tonalAt(int64_t i, int c) {
    const double t = static_cast<double>(i) / 48000.0;
    const double env = 0.6 + 0.4 * std::sin(2 * kPi * 0.5 * t);
    return static_cast<float>(env * (0.25 * std::sin(2 * kPi * 220.0 * t) + 0.2 * std::sin(2 * kPi * 261.63 * t + c) +
                                     0.2 * std::sin(2 * kPi * 329.63 * t)));
}

// A click (a 2 ms blip) at every multiple of `period` frames.
float clicksAt(int64_t i, int64_t period) {
    const int64_t k = i % period;
    return k < 96 ? static_cast<float>(0.8 * std::sin(2 * kPi * 2000.0 * static_cast<double>(k) / 48000.0)) : 0.0f;
}

std::string clipProject(const std::string& path, const std::string& clipFields, int bars = 2, double bpm = 120,
                        const std::string& top = "") {
    char b[32];
    std::snprintf(b, sizeof b, "%.17g", bpm);
    return "{\"caw_project\":1," + top + "\"bpm\":" + b + ",\"loop_bars\":" + std::to_string(bars) +
           ",\"master\":1,\"assets\":[{\"id\":\"a\",\"path\":\"" + jsonEscape(path) + "\",\"bpm\":120}],"
           "\"layers\":[{\"id\":\"t\",\"name\":\"T\",\"volume\":1,\"pan\":0,\"audio_clips\":[{\"id\":\"c1\",\"asset\":\"a\"" +
           clipFields + "}]}]}";
}

struct Render {
    std::vector<float> l, r;
};
Render render(const std::string& json, int64_t frames, int block = 512, double fromStep = 0) {
    Engine e(48000);
    e.setMasterBypass(true);
    const std::string res = e.setProjectJson(json);
    CHECK(res.find("\"ok\":true") != std::string::npos);
    if (res.find("\"ok\":true") == std::string::npos) std::printf("%s\n", res.c_str());
    e.play(fromStep);
    Render out;
    out.l.resize(static_cast<size_t>(frames));
    out.r.resize(static_cast<size_t>(frames));
    for (int64_t i = 0; i < frames; i += block)
        e.process(out.l.data() + i, out.r.data() + i, static_cast<int>(std::min<int64_t>(block, frames - i)));
    return out;
}

bool same(const Render& a, const Render& b) {
    if (a.l.size() != b.l.size()) return false;
    for (size_t i = 0; i < a.l.size(); ++i)
        if (a.l[i] != b.l[i] || a.r[i] != b.r[i]) return false;
    return true;
}

double rms(const std::vector<float>& x, size_t from, size_t to) {
    double s = 0;
    for (size_t i = from; i < to; ++i) s += static_cast<double>(x[i]) * x[i];
    return std::sqrt(s / static_cast<double>(std::max<size_t>(1, to - from)));
}

// Rising zero crossings per second of x[from..to).
double risingPerSecond(const std::vector<float>& x, size_t from, size_t to) {
    int n = 0;
    for (size_t i = from + 1; i < to; ++i) n += x[i - 1] < 0 && x[i] >= 0;
    return n * 48000.0 / static_cast<double>(to - from);
}

// The rendered audio as an asset, for the detectors.
AudioAsset assetOf(const std::vector<float>& l) {
    AudioAsset a;
    a.rate = a.sourceRate = 48000;
    a.channels = a.sourceChannels = 1;
    a.frames = a.sourceFrames = static_cast<int64_t>(l.size());
    a.data[0] = l;
    return a;
}

// A player driven directly (no Engine), for its voice counts: blocks of 64 at a steady tempo.
struct Player {
    ModuleRegistry reg;
    std::unique_ptr<ModuleProcessor> p;
    double beat = 0, tempo = 120;
    std::vector<float> out;
    explicit Player(double rate = 48000) {
        registerBuiltinComponents(reg);
        p = reg.create(kAudioTrackId);
        CHECK(p != nullptr);
        if (p) CHECK(p->activate(rate, 64));
    }
    void set(const std::vector<AudioClipSpec>& clips, double rate = 48000) {
        ComponentSpec cs;
        cs.id = kAudioTrackId;
        auto t = std::make_shared<AudioTrackSpec>();
        t->clips = clips;
        cs.audioTrack = t;
        applyAudioTrack(*p, cs, rate);
    }
    void run(int frames) {
        float l[64], r[64];
        float* ch[2] = {l, r};
        ChannelBufferView view{ch, 2, 64};
        Transport tr;
        tr.tempo = tempo;
        tr.playing = true;
        ProcessBlock b;
        b.frames = 64;
        b.audioOut = &view;
        b.audioOutCount = 1;
        b.transport = &tr;
        for (int i = 0; i < frames; i += 64) {
            tr.beat = beat;
            p->processPorts(b);
            out.insert(out.end(), l, l + 64);
            beat += 64.0 * tempo / 60.0 / 48000.0;
        }
    }
    AudioTrackStats stats() const { return audioTrackStats(*p); }
};

AudioClipSpec hqClip(const std::string& id, const std::string& path, double start, double length, double ratio = 1.2) {
    AudioClipSpec c;
    c.id = id;
    c.path = path;
    c.startSteps = start;
    c.lengthSteps = length;
    c.hq = true;
    c.stretchRatio = ratio;
    return c;
}

std::string cjson(char* p) {
    std::string s = p ? p : "";
    caw_free(p);
    return s;
}

}  // namespace

TEST(stretch_ratio_1_with_no_pitch_plays_the_samples_exactly_whatever_the_algorithm) {
    // The bypass: API 32's fields at their neutral values, under every algorithm, give the bits API 31 gave.
    const std::string dir = tempDir("bypass");
    const std::string p = writeWav(dir + "/n.wav", 48000, 72000, noiseAt);
    const std::string base = ",\"start_steps\":2,\"length_steps\":10,\"offset_seconds\":0.1,\"fade_in_seconds\":0.01";
    const Render ref = render(clipProject(p, base), 96000);
    CHECK(rms(ref.l, 12000, 60000) > 0.1);
    for (const char* extra :
         {",\"stretch\":\"signalsmith\"", ",\"stretch\":\"signalsmith\",\"stretch_ratio\":1,\"pitch_cents\":0,\"gain_db\":0",
          ",\"stretch\":\"wsola\",\"stretch_ratio\":1,\"pitch\":1,\"pitch_cents\":-100",
          ",\"stretch\":\"varispeed\",\"stretch_ratio\":1",
          // following the tempo at the clip's own tempo, with one tempo: the file's speed
          ",\"stretch\":\"signalsmith\",\"follows_tempo\":true,\"source_bpm\":120"})
        CHECK(same(render(clipProject(p, base + extra), 96000), ref));
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(signalsmith_pitch_changes_pitch_not_length_and_stretch_ratio_changes_length_not_pitch) {
    const std::string dir = tempDir("pitch");
    const std::string sine = writeWav(dir + "/s.wav", 48000, 96000, [](int64_t i, int) {
        return static_cast<float>(0.5 * std::sin(2 * kPi * 440.0 * static_cast<double>(i) / 48000.0));
    });
    // Up an octave and a fifth down, as cents: the frequency moves, the clip is as long as before.
    const Render up = render(clipProject(sine, ",\"length_steps\":16,\"stretch\":\"signalsmith\",\"pitch_cents\":1200"), 120000);
    CHECK_NEAR(risingPerSecond(up.l, 9600, 86400), 880.0, 6.0);
    const Render down = render(clipProject(sine, ",\"length_steps\":16,\"stretch\":\"signalsmith\",\"pitch\":-7,\"pitch_cents\":0"), 120000);
    CHECK_NEAR(risingPerSecond(down.l, 9600, 86400), 440.0 * std::pow(2.0, -7.0 / 12.0), 4.0);
    // Ratio 2: half speed, same pitch; the 2 s file fills a 4 s clip.
    const Render slow = render(clipProject(sine, ",\"length_steps\":32,\"stretch\":\"signalsmith\",\"stretch_ratio\":2", 3), 240000);
    CHECK_NEAR(risingPerSecond(slow.l, 9600, 182400), 440.0, 3.0);
    CHECK(rms(slow.l, 170000, 185000) > 0.2);   // still sounding at 3.6 s
    CHECK(rms(slow.l, 194000, 240000) < 1e-3);  // ended with the clip (4 s)

    // Clicks every 0.25 s at ratio 2 come every 0.5 s.
    const std::string clicks = writeWav(dir + "/c.wav", 48000, 96000, [](int64_t i, int) { return clicksAt(i, 12000); });
    const Render st = render(clipProject(clicks, ",\"length_steps\":32,\"stretch\":\"signalsmith\",\"stretch_ratio\":2", 3), 200000);
    SliceOptions so;
    so.minGapSeconds = 0.2;
    std::vector<Slice> found = detectSlices(assetOf(st.l), so);
    // The click at 0 starts the clip as playback starts: no pre-roll is possible, so the WSOLA bridge plays it,
    // faded in from the clip's start (a few ms late, if found at all). The rest come from Signalsmith.
    found.erase(std::remove_if(found.begin(), found.end(), [](const Slice& f) { return f.seconds < 0.25; }), found.end());
    CHECK(found.size() >= 6);
    for (size_t k = 0; k < found.size() && k < 7; ++k) CHECK_NEAR(found[k].seconds, 0.5 * static_cast<double>(k + 1), 0.010);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(signalsmith_drums_and_a_tonal_loop_match_their_reference_renders) {
    // Chaotic references (loudness, spectrum, onsets): a drum loop slowed and sped, a tonal loop pitched and stretched,
    // and a drum loop following a slower tempo, each 2 s through the master in 64-frame blocks. Re-record only for an
    // intended sound change (references/audio_stretch.cawref).
    const std::string dir = tempDir("refs");
    const std::string drums = writeWav(dir + "/d.wav", 48000, 192000, drumsAt);
    const std::string tonal = writeWav(dir + "/t.wav", 48000, 192000, tonalAt);
    struct Case {
        const char* name;
        std::string path, fields;
        double bpm;
    };
    const Case cases[] = {
        {"drums ratio 1.5", drums, ",\"length_steps\":16,\"stretch\":\"signalsmith\",\"stretch_ratio\":1.5", 120},
        {"drums ratio 0.75", drums, ",\"length_steps\":16,\"stretch\":\"signalsmith\",\"stretch_ratio\":0.75", 120},
        {"drums follow 96 bpm", drums, ",\"length_steps\":16,\"stretch\":\"signalsmith\",\"follows_tempo\":true", 96},
        {"tonal up 7 semitones", tonal, ",\"length_steps\":16,\"stretch\":\"signalsmith\",\"pitch\":7", 120},
        {"tonal ratio 1.25 down 300 cents", tonal,
         ",\"length_steps\":16,\"stretch\":\"signalsmith\",\"stretch_ratio\":1.25,\"pitch_cents\":-300", 120},
    };
    cawtest::References refs("audio_stretch");
    for (const Case& c : cases) {
        Engine e(48000);
        CHECK(e.setProjectJson(clipProject(c.path, c.fields, 2, c.bpm)).find("\"ok\":true") != std::string::npos);
        e.play();
        cawtest::Audio audio;
        float l[64], r[64];
        for (int k = 0; k < 2 * 48000 / 64; ++k) {
            e.process(l, r, 64);
            audio.l.insert(audio.l.end(), l, l + 64);
            audio.r.insert(audio.r.end(), r, r + 64);
        }
        CHECK(rms(audio.l, 0, audio.l.size()) > 0.02);
        CHECK_REFERENCE(refs, c.name, audio, cawtest::Class::Chaotic);
    }
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(a_clip_following_the_tempo_tracks_a_ramp_chunk_by_chunk) {
    // A click every beat at 120 BPM; the song holds 120 for two beats, then ramps to 60 by beat 10. A clip following
    // the tempo puts source beat k on song beat k: frameAt(4 k). Varispeed shows the placement to the detector's
    // precision; Signalsmith to a few milliseconds. (WSOLA follows the same mapping, but at half speed it can drop or
    // move a 2 ms click by up to a hop, so clicks don't test it.)
    const std::string dir = tempDir("ramp");
    const std::string clicks = writeWav(dir + "/c.wav", 48000, 300000, [](int64_t i, int) { return clicksAt(i, 24000); });
    const std::string top = "\"tempo_map\":[{\"beat\":0,\"bpm\":120},{\"beat\":2,\"bpm\":120},{\"beat\":10,\"bpm\":60,\"ramp\":true}],";
    TempoMap tm;
    tm.build({{0, 120, false}, {2, 120, false}, {10, 60, true}}, 48000);
    for (const char* algo : {"varispeed", "signalsmith"}) {
        const std::string fields = std::string(",\"length_steps\":44,\"follows_tempo\":true,\"stretch\":\"") + algo + "\"";
        const Render out = render(clipProject(clicks, fields, 4, 120, top), static_cast<int64_t>(tm.frameAt(44)) + 4800);
        SliceOptions so;
        so.minGapSeconds = 0.3;
        so.sensitivity = 0.7;
        std::vector<Slice> found = detectSlices(assetOf(out.l), so);
        // Source beat 11 lands on the clip's very end, where interpolation's look-ahead leaks its first samples.
        found.erase(std::remove_if(found.begin(), found.end(),
                                   [&](const Slice& f) { return f.seconds > tm.frameAt(42) / 48000.0; }),
                    found.end());
        const bool exact = std::string(algo) == "varispeed";
        const double tol = exact ? 0.0005 : 0.012;  // the detector places an onset to a fraction of a millisecond
        // Each click found near where the map puts it, and nothing else.
        size_t matched = 0;
        for (size_t k = 1; k < 11; ++k) {  // (click 0 is at the start: the range's start, never a slice)
            const double want = tm.frameAt(4.0 * static_cast<double>(k)) / 48000.0;
            double best = 1e9;
            for (const Slice& f : found) best = std::min(best, std::fabs(f.seconds - want));
            if (best > tol)
                std::printf("  %s: click %zu %.2f ms off (at %.5f s)\n", algo, k, best * 1000, want);
            CHECK(best <= tol);
            if (best <= tol) ++matched;
        }
        CHECK_EQ(found.size(), matched);  // nothing between the clicks
        if (found.size() != matched)
            for (const Slice& f : found) std::printf("  %s found %.5f (strength %.2f)\n", algo, f.seconds, f.strength);
    }
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(signalsmith_clips_start_on_time_from_a_preroll_and_join_mid_clip_through_a_bridge) {
    const std::string dir = tempDir("start");
    const std::string p = writeWav(dir + "/n.wav", 48000, 96000, tonalAt);
    const std::string fields = ",\"start_steps\":4,\"length_steps\":12,\"stretch\":\"signalsmith\",\"stretch_ratio\":1.2";
    // Played from the start: silent before the clip (frame 24000), sounding from its first milliseconds.
    const Render a = render(clipProject(p, fields), 96000);
    CHECK_EQ(rms(a.l, 0, 24000), 0.0);
    CHECK(rms(a.l, 24000, 24480) > 0.05);
    // The same at every block size (64-frame chunks aligned to the voice), and joined mid-clip: sounding at once.
    for (int block : {37, 64, 500}) CHECK(same(render(clipProject(p, fields), 96000, block), a));
    const Render mid = render(clipProject(p, fields), 48000, 512, 9);
    CHECK(rms(mid.l, 0, 1200) > 0.02);              // the WSOLA bridge
    CHECK(rms(mid.l, 9000, 20000) > 0.1);           // Signalsmith after the crossfade
    for (int block : {37, 64}) CHECK(same(render(clipProject(p, fields), 48000, block, 9), mid));
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(fades_gain_db_reverse_and_loop_frames_with_stretch) {
    const std::string dir = tempDir("edits");
    // A rising ramp of noise at 44.1 kHz (frames convert to the engine's rate).
    const std::string p = writeWav(dir + "/r.wav", 44100, 88200, [](int64_t i, int c) {
        return static_cast<float>(static_cast<double>(i) / 88200.0) * noiseAt(i, c);
    });
    const std::string base = ",\"length_steps\":16";
    // Loop points as frames of the file's own rate equal the same points as seconds, to the bit.
    CHECK(same(render(clipProject(p, base + ",\"loop\":true,\"loop_start_frames\":4410,\"loop_end_frames\":22050"), 96000),
               render(clipProject(p, base + ",\"loop\":true,\"loop_start_seconds\":0.1,\"loop_end_seconds\":0.5"), 96000)));
    // gain_db multiplies gain.
    const Render g0 = render(clipProject(p, base), 96000);
    const Render g6 = render(clipProject(p, base + ",\"gain_db\":-6.020599913279624"), 96000);
    CHECK_NEAR(rms(g6.l, 0, 96000) / rms(g0.l, 0, 96000), 0.5, 1e-4);
    // Reversed and stretched: the ramp falls, over 1.5 times the file's length.
    const Render rev = render(clipProject(p, ",\"length_steps\":24,\"stretch\":\"signalsmith\",\"stretch_ratio\":1.5,"
                                             "\"reverse\":true", 3), 144000);
    CHECK(rms(rev.l, 4800, 30000) > 2 * rms(rev.l, 100000, 125000));
    CHECK(rms(rev.l, 100000, 125000) > 0.005);
    // Fades on a stretched clip shape the output: quiet at the very start and end of the clip.
    const Render fd = render(clipProject(p, ",\"length_steps\":16,\"stretch\":\"signalsmith\",\"stretch_ratio\":1.1,"
                                            "\"loop\":true,\"loop_start_frames\":44100,\"fade_in_seconds\":0.2,"
                                            "\"fade_out_seconds\":0.2,\"fade_out_curve\":\"s_curve\""), 96000);
    CHECK(rms(fd.l, 0, 480) < 0.2 * rms(fd.l, 24000, 48000));
    CHECK(rms(fd.l, 95000, 96000) < 0.2 * rms(fd.l, 24000, 48000));
    CHECK(rms(fd.l, 60000, 80000) > 0.1);  // looping the file's second half fills the 2 s clip
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(the_new_clip_fields_are_parsed_with_limits) {
    const std::string dir = tempDir("parse");
    const std::string p = writeWav(dir + "/n.wav", 48000, 4800, noiseAt);
    Engine e(48000);
    for (const char* bad : {",\"stretch_ratio\":5", ",\"stretch_ratio\":0.2", ",\"stretch_ratio\":\"2\"",
                            ",\"pitch_cents\":2401", ",\"pitch\":40,\"pitch_cents\":900", ",\"gain_db\":37",
                            ",\"gain_db\":-97", ",\"loop_start_frames\":1.5", ",\"loop_end_frames\":-3",
                            ",\"loop_start_frames\":2000,\"loop_end_frames\":1000", ",\"loop_end_frames\":2e12",
                            ",\"stretch\":\"elastique\"", ",\"stretch\":3", ",\"follows_tempo\":1",
                            ",\"follows_tempo\":true,\"mode\":\"fixed\"", ",\"follows_tempo\":true,\"source_bpm\":0"}) {
        std::string json = clipProject(p, std::string(",\"length_steps\":4") + bad);
        if (std::string(bad).find("source_bpm") != std::string::npos) json.replace(json.find(",\"bpm\":120}"), 11, "}");
        const std::string r = e.setProjectJson(json);
        if (r.find("\"ok\":false") == std::string::npos) std::printf("  accepted: %s\n", bad);
        CHECK(r.find("\"ok\":false") != std::string::npos);
    }
    CHECK(e.setProjectJson(clipProject(p, ",\"follows_tempo\":true,\"mode\":\"musical\",\"pitch\":-48,\"pitch_cents\":0,"
                                          "\"stretch_ratio\":4,\"loop_end_frames\":0,\"gain_db\":36"))
              .find("\"ok\":true") != std::string::npos);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(tempo_detection_finds_click_tracks_at_known_tempos) {
    const std::string dir = tempDir("tempo");
    for (double bpm : {90.0, 120.0, 128.0, 140.0, 174.0, 97.5}) {
        const double period = 48000.0 * 60.0 / bpm;
        const std::string p = writeWav(dir + "/c" + std::to_string(static_cast<int>(bpm * 10)) + ".wav", 48000,
                                       48000 * 20, [&](int64_t i, int) {
            const double k = std::floor(static_cast<double>(i) / period);
            const int64_t at = i - static_cast<int64_t>(std::llround(k * period));
            const float accent = static_cast<int64_t>(k) % 4 == 0 ? 1.0f : 0.6f;
            return at >= 0 && at < 96 ? accent * static_cast<float>(0.8 * std::sin(2 * kPi * 2000.0 * at / 48000.0)) : 0.0f;
        });
        std::string error;
        const auto a = AssetStore::global().load(p, 48000, error);
        CHECK(a != nullptr);
        if (!a) continue;
        const TempoResult r = detectTempo(*a, TempoOptions{});
        if (std::fabs(r.bpm - bpm) > 0.5) std::printf("  %.1f BPM: found %.2f (confidence %.2f)\n", bpm, r.bpm, r.confidence);
        CHECK(r.sure);
        CHECK_NEAR(r.bpm, bpm, 0.5);
        CHECK(r.onsets >= 30);
    }
    // A drum loop at 120 (kicks, snares, hats on the eighths).
    const std::string d = writeWav(dir + "/d.wav", 48000, 48000 * 16, drumsAt);
    std::string error;
    const auto da = AssetStore::global().load(d, 48000, error);
    CHECK(da != nullptr);
    if (da) {
        const TempoResult r = detectTempo(*da, TempoOptions{});
        CHECK(r.sure);
        CHECK_NEAR(r.bpm, 120.0, 0.5);
    }
    // Steady noise and silence have no tempo.
    const std::string n = writeWav(dir + "/n.wav", 48000, 48000 * 10, noiseAt);
    const auto na = AssetStore::global().load(n, 48000, error);
    CHECK(na != nullptr);
    if (na) {
        const TempoResult r = detectTempo(*na, TempoOptions{});
        if (r.sure) std::printf("  noise: %.2f BPM, confidence %.2f\n", r.bpm, r.confidence);
        CHECK(!r.sure);
    }
    const std::string s = writeWav(dir + "/s.wav", 48000, 48000 * 4, [](int64_t, int) { return 0.0f; });
    const auto sa = AssetStore::global().load(s, 48000, error);
    CHECK(sa != nullptr);
    if (sa) CHECK(!detectTempo(*sa, TempoOptions{}).sure);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(slices_land_on_known_transients_and_sensitivity_finds_the_quiet_ones) {
    const std::string dir = tempDir("slices");
    const double times[] = {0.1, 0.37, 0.52, 0.9, 1.33, 1.71, 2.05};
    const double amps[] = {0.8, 0.6, 0.7, 0.015, 0.9, 0.5, 0.7};  // the fourth is quiet
    const std::string p = writeWav(dir + "/h.wav", 44100, 44100 * 5 / 2, [&](int64_t i, int c) {
        double v = 0;
        for (int k = 0; k < 7; ++k) {
            const double t = static_cast<double>(i) / 44100.0 - times[k];
            if (t >= 0 && t < 0.15) v += amps[k] * noiseAt(i, c) * std::exp(-t / 0.03);
        }
        return static_cast<float>(v + 0.002 * noiseAt(i * 3 + 1, c));
    });
    CawEngine* ce = caw_engine_create(48000);
    CHECK(ce != nullptr);
    Json j;
    std::string error;
    CHECK(parseJson(cjson(caw_asset_slices(ce, p.c_str(), "{\"sensitivity\":0.5}")), j, error));
    CHECK(j.boolean("ok", false));
    const Json* sl = j.get("slices");
    CHECK(sl && sl->arr.size() == 6);  // the quiet one missed
    if (sl)
        for (const Json& s : sl->arr) {
            double best = 1e9;
            for (double t : times) best = std::min(best, std::fabs(s.number("seconds", -1) - t));
            CHECK(best < 0.002);
            CHECK_NEAR(s.number("frame", -1), std::round(s.number("seconds", -1) * 44100), 1.0);
            CHECK(s.number("strength", -1) > 0 && s.number("strength", -1) <= 1);
        }
    CHECK(parseJson(cjson(caw_asset_slices(ce, p.c_str(), "{\"sensitivity\":0.95}")), j, error));
    sl = j.get("slices");
    CHECK(sl && sl->arr.size() >= 7);
    bool quiet = false;
    if (sl)
        for (const Json& s : sl->arr) quiet |= std::fabs(s.number("seconds", -1) - 0.9) < 0.002;
    CHECK(quiet);
    // max_slices keeps the strongest, in time order.
    std::vector<double> strengths;
    CHECK(parseJson(cjson(caw_asset_slices(ce, p.c_str(), nullptr)), j, error));
    if (const Json* all = j.get("slices"))
        for (const Json& s : all->arr) strengths.push_back(s.number("strength", 0));
    std::sort(strengths.rbegin(), strengths.rend());
    CHECK(parseJson(cjson(caw_asset_slices(ce, p.c_str(), "{\"max_slices\":2}")), j, error));
    sl = j.get("slices");
    CHECK(sl && sl->arr.size() == 2 && strengths.size() >= 3);
    if (sl && sl->arr.size() == 2 && strengths.size() >= 3) {
        CHECK(sl->arr[0].number("seconds", 0) < sl->arr[1].number("seconds", 0));
        for (const Json& s : sl->arr) CHECK(s.number("strength", 0) >= strengths[1]);
    }
    CHECK(parseJson(cjson(caw_asset_slices(ce, p.c_str(), "{\"start_seconds\":0.45,\"end_seconds\":1.5}")), j, error));
    sl = j.get("slices");
    CHECK(sl && sl->arr.size() == 2);
    CHECK_NEAR(j.number("seconds", 0), 1.05, 1e-6);
    // Tempo through the C API too.
    CHECK(parseJson(cjson(caw_asset_tempo(ce, p.c_str(), "{\"min_bpm\":60,\"max_bpm\":200}")), j, error));
    CHECK(j.boolean("ok", false));
    caw_engine_destroy(ce);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(analysis_options_are_parsed_with_limits) {
    const std::string dir = tempDir("options");
    const std::string p = writeWav(dir + "/n.wav", 48000, 4800, noiseAt);
    CawEngine* ce = caw_engine_create(48000);
    CHECK(ce != nullptr);
    const std::string big = "{\"sensitivity\":0.5,\"pad\":\"" + std::string(5000, 'x') + "\"}";
    for (const std::string& bad : {big, std::string("[1]"), std::string("{\"sensitivity\":2}"),
                                   std::string("{\"sensitivity\":\"high\"}"), std::string("{\"max_slices\":0}"),
                                   std::string("{\"max_slices\":257}"), std::string("{\"max_slices\":3.5}"),
                                   std::string("{\"min_gap_seconds\":0.001}"), std::string("{\"end_seconds\":0.2,\"start_seconds\":0.3}"),
                                   std::string("{\"start_seconds\":0,\"end_seconds\":700}"), std::string("{not json"),
                                   std::string("{\"start_seconds\":-1}")}) {
        const std::string r = cjson(caw_asset_slices(ce, p.c_str(), bad.c_str()));
        if (r.find("\"ok\":false") == std::string::npos) std::printf("  accepted: %.60s\n", bad.c_str());
        CHECK(r.find("\"ok\":false") != std::string::npos);
    }
    for (const char* bad : {"{\"min_bpm\":20}", "{\"max_bpm\":700}", "{\"min_bpm\":100,\"max_bpm\":100}",
                            "{\"min_bpm\":40,\"max_bpm\":200}", "{\"min_bpm\":null,\"max_bpm\":\"x\"}"}) {
        const std::string r = cjson(caw_asset_tempo(ce, p.c_str(), bad));
        if (r.find("\"ok\":false") == std::string::npos) std::printf("  accepted: %s\n", bad);
        CHECK(r.find("\"ok\":false") != std::string::npos);
    }
    CHECK(cjson(caw_asset_tempo(ce, (dir + "/missing.wav").c_str(), nullptr)).find("\"ok\":false") != std::string::npos);
    CHECK(cjson(caw_asset_slices(nullptr, p.c_str(), nullptr)).find("\"ok\":false") != std::string::npos);
    CHECK(cjson(caw_asset_tempo(ce, p.c_str(), "")).find("\"ok\":true") != std::string::npos);
    caw_engine_destroy(ce);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(signalsmith_prepares_once_and_a_voice_costs_this_much) {
    // The stretcher reports its latencies, and timing one prepared voice against plain playback (printed for
    // docs/engine.md; no threshold: CI machines vary).
    HqStretcher h;
    const auto p0 = std::chrono::steady_clock::now();
    CHECK(h.prepare(48000));
    std::printf("  prepare: %.2f ms\n", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - p0).count());
    CHECK_EQ(h.inputLatency(), 2880);
    CHECK_EQ(h.outputLatency(), 4320);
    const std::string dir = tempDir("cost");
    const std::string p = writeWav(dir + "/n.wav", 48000, 48000 * 12, tonalAt);
    auto time = [&](const std::string& fields) {
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(e.setProjectJson(clipProject(p, ",\"length_steps\":160" + fields, 10)).find("\"ok\":true") != std::string::npos);
        e.play();
        std::vector<float> l(256), r(256);
        const auto t0 = std::chrono::steady_clock::now();
        for (int k = 0; k < 48000 * 10 / 256; ++k) e.process(l.data(), r.data(), 256);
        return std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count() / 10.0 * 100.0;  // % of a core
    };
    const double plain = time(""), wsola = time(",\"stretch_ratio\":1.1"),
                 hq = time(",\"stretch\":\"signalsmith\",\"stretch_ratio\":1.1"),
                 hqPitch = time(",\"stretch\":\"signalsmith\",\"stretch_ratio\":1.1,\"pitch_cents\":300");
    std::printf("  one clip, %% of a core (whole engine, 256-frame blocks at 48 kHz): plain %.3f, WSOLA %.3f, "
                "Signalsmith %.3f, Signalsmith with pitch %.3f\n", plain, wsola, hq, hqPitch);
    CHECK(hq > 0);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(stretchers_arrive_while_the_audio_thread_plays) {
    // Project updates add Signalsmith clips (each update prepares more stretchers on this thread and publishes them)
    // while another thread plays: the audio thread only ever uses published, prepared ones (run under TSan in CI's
    // sanitizer job and here).
    const std::string dir = tempDir("arrive");
    const std::string p = writeWav(dir + "/n.wav", 48000, 48000, tonalAt);
    Engine e(48000);
    e.setMasterBypass(true);
    CHECK(e.setProjectJson(clipProject(p, ",\"length_steps\":32")).find("\"ok\":true") != std::string::npos);
    e.play();
    std::atomic<bool> stop{false};
    std::atomic<float> peak{0};
    std::thread audio([&] {
        std::vector<float> l(64), r(64);
        float pk = 0;
        while (!stop.load()) {
            e.process(l.data(), r.data(), 64);
            for (float v : l) pk = std::max(pk, std::fabs(v));
        }
        peak.store(pk);
    });
    int ok = 0;
    for (int k = 1; k <= 8; ++k) {
        std::string clips;
        for (int c = 0; c < k; ++c)
            clips += (c ? "," : "") + std::string("{\"id\":\"c") + std::to_string(c) + "\",\"asset\":\"a\",\"start_steps\":" +
                     std::to_string(c * 2) + ",\"length_steps\":8,\"stretch\":\"signalsmith\",\"stretch_ratio\":" +
                     std::to_string(1.0 + 0.1 * c) + "}";
        std::string json = clipProject(p, ",\"length_steps\":32");
        json.replace(json.find("[{\"id\":\"c1\""), json.size() - json.find("[{\"id\":\"c1\"") - 4, "[" + clips);
        const std::string r = e.setProjectJson(json);
        if (r.find("\"ok\":true") == std::string::npos) std::printf("%s\n%s\n", json.c_str(), r.c_str());
        ok += r.find("\"ok\":true") != std::string::npos;
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
    }
    stop.store(true);
    audio.join();
    CHECK_EQ(ok, 8);
    CHECK(peak.load() > 0.01f);
    std::filesystem::remove_all(utf8Path(dir));
}

// ---------------------------------------------------------------- the audio review's findings (2026-11-14)

TEST(the_bridge_into_signalsmith_keeps_its_level_through_the_crossfade) {
    // A voice joining mid-clip (play from step 9 inside a clip from step 4) plays WSOLA, then crossfades into
    // Signalsmith (good at 4320, the crossfade from 4576 to 5088), moved to WSOLA's phase, its gains keeping the sum's
    // power for the two signals' correlation. For steady sines every 128 frames from 4096 to 5632 stays within 1 dB
    // of the same song time played by Signalsmith alone (the clip reached from ahead, pre-rolled, at the lag); for a
    // tonal loop the level stays within 1 dB of the level on either side.
    const std::string dir = tempDir("bridge");
    struct Src {
        const char* name;
        std::function<float(int64_t, int)> f;
    };
    const Src srcs[] = {
        {"sine 440", [](int64_t i, int) { return 0.5f * static_cast<float>(std::sin(2 * kPi * 440.0 * static_cast<double>(i) / 48000)); }},
        {"sine 110", [](int64_t i, int) { return 0.5f * static_cast<float>(std::sin(2 * kPi * 110.0 * static_cast<double>(i) / 48000)); }},
        {"sine 3000", [](int64_t i, int) { return 0.5f * static_cast<float>(std::sin(2 * kPi * 3000.0 * static_cast<double>(i) / 48000)); }},
        {"tonal loop", tonalAt},
    };
    const std::string clip = ",\"start_steps\":4,\"length_steps\":12,\"stretch\":\"signalsmith\",\"stretch_ratio\":1.2";
    for (const Src& src : srcs) {
        const std::string p = writeWav(dir + "/" + std::string(src.name).substr(0, 4) + std::to_string(std::strlen(src.name)) + ".wav",
                                       48000, 96000, src.f);
        const Render mid = render(clipProject(p, clip), 12000, 512, 9);   // song time 54000 + t
        const Render ref = render(clipProject(p, clip), 54000 + 13000);  // pre-rolled: no bridge
        // The bridge moves Signalsmith by a lag to WSOLA's phase (taken back out later): find it after the crossfade.
        int lag = 0;
        double best = -1e300;
        for (int d = -300; d <= 300; ++d) {
            double c = 0;
            for (size_t i = 6000; i < 8000; ++i) c += static_cast<double>(mid.l[i]) * ref.l[static_cast<size_t>(54000 + static_cast<int>(i) + d)];
            if (c > best) best = c, lag = d;
        }
        auto db = [&](size_t a) {
            const size_t b = static_cast<size_t>(54000 + static_cast<int>(a) + lag);
            return 20 * std::log10(rms(mid.l, a, a + 128) / rms(ref.l, b, b + 128));
        };
        double worst = 0;
        const bool chord = std::string(src.name) == "tonal loop";
        if (!chord) {
            for (size_t a = 4096; a + 128 <= 5632; a += 128) worst = std::max(worst, std::fabs(db(a)));
        } else {
            // A chord: a phase vocoder's partials keep no common phase with WSOLA's, so no one lag lines them all up,
            // nor do two Signalsmith runs started apart agree on how the partials beat (here about 1.2 dB louder
            // throughout). So: 2048-frame windows (the partials beat over about 24 ms), against Signalsmith alone, less
            // that steady difference measured after the crossfade, within 1.5 dB (the dip before was 5 to 8 dB).
            auto db2 = [&](size_t a) {
                const size_t b = static_cast<size_t>(54000 + static_cast<int>(a) + lag);
                return 20 * std::log10(rms(mid.l, a, a + 2048) / rms(ref.l, b, b + 2048));
            };
            double base = 0;
            int n = 0;
            for (size_t a = 6400; a + 2048 <= 10000; a += 128, ++n) base += db2(a);
            base /= n;
            for (size_t a = 3584; a + 2048 <= 6656; a += 128) worst = std::max(worst, std::fabs(db2(a) - base));
        }
        const double limit = chord ? 1.5 : 1.0;
        if (worst > limit) {
            std::printf("  %s: %.2f dB off around the crossfade (lag %d):", src.name, worst, lag);
            for (size_t a = 3584; a + 128 <= 6144; a += 128) std::printf(" %.1f", db(a));
            std::printf("\n");
        }
        CHECK(worst <= limit);
    }
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(a_loop_wrap_starts_signalsmith_from_a_preroll_not_a_bridge) {
    // The clip at the loop's start gets a spare voice a pre-roll before each wrap, so its second pass plays exactly
    // as a clip reached from ahead of the playhead does (the same bits), not through the WSOLA bridge.
    const std::string dir = tempDir("wrap");
    const std::string p = writeWav(dir + "/t.wav", 48000, 192000, tonalAt);
    const std::string clip = ",\"length_steps\":32,\"stretch\":\"signalsmith\",\"stretch_ratio\":1.2";
    const Render looped = render(clipProject(p, ",\"start_steps\":0" + clip, 2), 192000 + 48000);  // a 4 s loop
    const Render ahead = render(clipProject(p, ",\"start_steps\":32" + clip, 4), 192000 + 48000);
    bool same = true;
    for (size_t i = 192000; i < 240000; ++i) same = same && looped.l[i] == ahead.l[i] && looped.r[i] == ahead.r[i];
    CHECK(same);
    CHECK(rms(looped.l, 192000, 192480) > 0.05);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(signalsmith_replays_bit_identical_past_a_2x_stretch) {
    // reset() reseeds the library's random phases (a local change to the vendored header), so a replay at ratio 3,
    // where it draws them, gives the same bits.
    const std::string dir = tempDir("replay");
    const std::string p = writeWav(dir + "/t.wav", 48000, 96000, tonalAt);
    for (const char* f : {",\"length_steps\":16,\"stretch\":\"signalsmith\",\"stretch_ratio\":3",
                          ",\"start_steps\":4,\"length_steps\":12,\"stretch\":\"signalsmith\",\"stretch_ratio\":3"}) {
        Engine e(48000);
        e.setMasterBypass(true);
        CHECK(e.setProjectJson(clipProject(p, f, 4)).find("\"ok\":true") != std::string::npos);
        std::vector<float> a(48000), b(48000), r(48000);
        e.play(0);
        for (int i = 0; i < 48000; i += 512) e.process(a.data() + i, r.data() + i, std::min(512, 48000 - i));
        e.stop();
        for (int i = 0; i < 4800; i += 512) e.process(r.data(), r.data() + 512, 512);  // the stop's fade
        e.play(0);
        for (int i = 0; i < 48000; i += 512) e.process(b.data() + i, r.data() + i, std::min(512, 48000 - i));
        CHECK(a == b);
        CHECK(rms(a, 24000, 48000) > 0.05);
    }
    // The draws themselves: raw minstd output mapped by fixed arithmetic, the same on every standard library.
    std::minstd_rand engine(0x00c0ffee);
    const signalsmith::stretch::_impl::FixedUniform<float> u{-1.0f, 3.0f};
    uint32_t bits[5];
    for (uint32_t& b : bits) {
        const float v = u(engine);
        std::memcpy(&b, &v, 4);
    }
    const uint32_t pinned[5] = {0x3e7837e0u, 0x403b1077u, 0x3eab5dccu, 0x401346b4u, 0x4030809fu};
    for (int i = 0; i < 5; ++i) {
        if (bits[i] != pinned[i]) std::printf("  draw %d: 0x%08x\n", i, bits[i]);
        CHECK_EQ(bits[i], pinned[i]);
    }
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(a_track_plays_at_most_eight_signalsmith_voices_and_upgrades_when_one_frees) {
    const std::string dir = tempDir("cap");
    const std::string p = writeWav(dir + "/t.wav", 48000, 96000, tonalAt);
    Player pl;
    std::vector<AudioClipSpec> clips;
    for (int k = 0; k < 10; ++k) clips.push_back(hqClip("c" + std::to_string(k), p, 0, k < 3 ? 4 : 16, 1.1 + 0.05 * k));
    pl.set(clips);
    pl.run(64 * 20);
    AudioTrackStats st = pl.stats();
    CHECK_EQ(st.stretchers, 10);  // the cap (8) plus a fading voice and a spare
    CHECK_EQ(st.hqVoices, 8);
    CHECK_EQ(st.wsolaVoices, 2);
    pl.run(48000 * 2 / 3);  // past step 4 (0.5 s): three clips ended
    st = pl.stats();
    CHECK_EQ(st.hqVoices, 7);  // the two on WSOLA took the stretchers the ended clips let go
    CHECK_EQ(st.wsolaVoices, 0);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(the_stretcher_pool_follows_the_overlap_and_the_sample_rate) {
    const std::string dir = tempDir("pool");
    const std::string p = writeWav(dir + "/t.wav", 48000, 96000, tonalAt);
    Player pl;
    // Four clips one after another: neighbours overlap only by a pre-roll, so two at once, plus two.
    std::vector<AudioClipSpec> clips;
    for (int k = 0; k < 4; ++k) clips.push_back(hqClip("c" + std::to_string(k), p, 4.0 * k, 4));
    pl.set(clips);
    pl.run(64 * 4);
    CHECK_EQ(pl.stats().stretchers, 4);
    // One clip: the pool shrinks (the rest are freed with the old timeline, on the control thread).
    pl.set({hqClip("c0", p, 0, 4)});
    pl.run(64 * 4);
    CHECK_EQ(pl.stats().stretchers, 3);
    // None: no stretchers.
    AudioClipSpec plain = hqClip("w", p, 0, 4);
    plain.hq = false;
    pl.set({plain});
    pl.run(64 * 4);
    CHECK_EQ(pl.stats().stretchers, 0);
    // A new rate: stretchers prepared again at it.
    Player pl2(44100);
    pl2.set({hqClip("c0", p, 0, 4)}, 48000);
    pl2.run(64);
    CHECK_EQ(pl2.stats().stretcherRate, 48000.0);
    pl2.set({hqClip("c0", p, 0, 4), hqClip("c1", p, 8, 4)}, 44100);
    pl2.run(64);
    CHECK_EQ(pl2.stats().stretcherRate, 44100.0);
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(a_clip_following_a_ramp_renders_the_same_at_every_block_size) {
    // Each 64-frame chunk's feed is worked out from the tempo map at its own frame, so the host's blocks don't matter.
    const std::string dir = tempDir("rampblocks");
    const std::string p = writeWav(dir + "/t.wav", 48000, 48000 * 8, tonalAt);
    const std::string top = "\"tempo_map\":[{\"beat\":0,\"bpm\":120},{\"beat\":1,\"bpm\":120},{\"beat\":12,\"bpm\":70,\"ramp\":true}],";
    for (const char* algo : {"signalsmith", "wsola", "varispeed"}) {
        const std::string f = std::string(",\"length_steps\":48,\"stretch\":\"") + algo +
                              "\",\"follows_tempo\":true,\"source_bpm\":120";
        const Render a = render(clipProject(p, f, 4, 120, top), 150000, 512);
        for (int b : {37, 441}) {
            const bool equal = same(render(clipProject(p, f, 4, 120, top), 150000, b), a);
            if (!equal) std::printf("  %s: block %d differs from 512\n", algo, b);
            CHECK(equal);
        }
    }
    std::filesystem::remove_all(utf8Path(dir));
}

TEST(slices_read_the_asset_in_place_at_any_offset) {
    // The analysis reads the asset where it lies (no copy of the range, so 600 s take about 2-3 MB: docs/engine.md):
    // the same hits 100 s into a file are found as at its start, moved by 100 s.
    const std::string dir = tempDir("inplace");
    const double times[] = {0.2, 0.55, 0.9, 1.4};
    auto hits = [&](double t0) {
        return [&, t0](int64_t i, int c) {
            double v = 0;
            for (double h : times) {
                const double t = static_cast<double>(i) / 48000.0 - t0 - h;
                if (t >= 0 && t < 0.1) v += 0.7 * noiseAt(i, c) * std::exp(-t / 0.02);
            }
            return static_cast<float>(v);
        };
    };
    const std::string early = writeWav(dir + "/a.wav", 48000, 48000 * 2, hits(0));
    const std::string late = writeWav(dir + "/b.wav", 48000, 48000 * 102, hits(100));
    std::string error;
    const auto a = AssetStore::global().load(early, 48000, error);
    const auto b = AssetStore::global().load(late, 48000, error);
    CHECK(a && b);
    if (!a || !b) return;
    SliceOptions o;
    const std::vector<Slice> sa = detectSlices(*a, o);
    o.startSeconds = 100;
    o.endSeconds = 102;
    const std::vector<Slice> sb = detectSlices(*b, o);
    CHECK_EQ(sa.size(), static_cast<size_t>(4));
    CHECK_EQ(sb.size(), sa.size());
    for (size_t k = 0; k < sa.size() && k < sb.size(); ++k) CHECK_NEAR(sb[k].seconds - 100.0, sa[k].seconds, 0.001);
    std::filesystem::remove_all(utf8Path(dir));
}
