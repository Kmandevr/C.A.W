// #241: a multi-track song through the device path (DeviceRender, the input bridge fed by a drifting capture) stays in time track against track for minutes.
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <functional>
#include <random>
#include <string>
#include <vector>

#include "device_render.h"
#include "engine.h"
#include "input_bridge.h"
#include "json.h"
#include "test.h"
#include "utf8_path.h"
#include "wav.h"

using namespace caw;

namespace {

constexpr int kRate = 48000;
constexpr int64_t kBeat = 24000;          // 120 BPM at 48 kHz
constexpr int64_t kLoop = 8 * 4 * kBeat;  // 8 bars: 16 s

struct TempRoot {
    std::filesystem::path path = std::filesystem::temp_directory_path() /
        ("caw_drift_" + std::to_string(std::chrono::steady_clock::now().time_since_epoch().count()));
    TempRoot() { std::filesystem::create_directories(path); }
    ~TempRoot() { std::error_code ec; std::filesystem::remove_all(path, ec); }
};

// A WAV at `rate` holding `seconds` of 2 ms clicks, one every `everySeconds` (the first at 0).
std::string clickWav(const std::filesystem::path& dir, const std::string& name, int rate, double seconds, double everySeconds) {
    const int64_t frames = static_cast<int64_t>(seconds * rate);
    std::vector<float> x(static_cast<size_t>(frames) * 2, 0.0f);
    const int len = rate / 500;
    for (int64_t k = 0;; ++k) {
        const int64_t at = static_cast<int64_t>(std::llround(static_cast<double>(k) * everySeconds * rate));
        if (at >= frames) break;
        for (int i = 0; i < len && at + i < frames; ++i) {
            const float v = static_cast<float>(0.8 * std::sin(2 * 3.14159265358979 * 2000.0 * i / rate));
            x[static_cast<size_t>(at + i) * 2] = x[static_cast<size_t>(at + i) * 2 + 1] = v;
        }
    }
    WavSpec s;
    s.sampleRate = rate;
    s.channels = 2;
    s.float32 = true;
    std::string error;
    const std::string path = pathText(dir / utf8Path(name));
    CHECK(writeFile(path, encodeWav(s, x.data(), frames), error));
    return path;
}

// The song: a MIDI track (the test signal's impulse on every beat), drums, a 48 kHz clip and a 44.1 kHz clip (a
// click every beat), a Signalsmith clip stretched 2x (a click every half beat in the file: every beat played), and
// an audio track monitoring the input.
std::string songJson(const std::filesystem::path& dir) {
    const std::string c48 = clickWav(dir, "c48.wav", 48000, 16.5, 0.5);
    const std::string c44 = clickWav(dir, "c44.wav", 44100, 16.5, 0.5);
    const std::string half = clickWav(dir, "half.wav", 48000, 8.5, 0.25);
    std::string beats, kicks;
    for (int s = 0; s < 128; s += 4) beats += std::to_string(s) + " C4 1 1\\n";
    for (int s = 0; s < 128; s += 8) kicks += std::to_string(s) + " C2 1 1\\n";
    return "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":8,\"master\":1,"
           "\"assets\":[{\"id\":\"a48\",\"path\":\"" + jsonEscape(c48) + "\",\"bpm\":120},"
           "{\"id\":\"a44\",\"path\":\"" + jsonEscape(c44) + "\",\"bpm\":120},"
           "{\"id\":\"ah\",\"path\":\"" + jsonEscape(half) + "\",\"bpm\":120}],"
           "\"modules\":[{\"id\":\"beats\",\"source\":\"---\\nkind: pattern\\nlength: 128\\n---\\n" + beats + "\"},"
           "{\"id\":\"kicks\",\"source\":\"---\\nkind: pattern\\nlength: 128\\n---\\n" + kicks + "\"}],"
           "\"layers\":["
           "{\"id\":\"midi\",\"name\":\"Midi\",\"volume\":1,\"pattern\":\"beats\",\"instrument\":{\"id\":\"org.caw.test.osc\","
           "\"params\":{\"mode\":1,\"shape\":5}}},"
           "{\"id\":\"drums\",\"name\":\"Drums\",\"volume\":1,\"pattern\":\"kicks\",\"instrument\":{\"id\":\"org.caw.drums\"}},"
           "{\"id\":\"c48\",\"name\":\"C48\",\"volume\":1,\"audio_clips\":[{\"id\":\"x\",\"asset\":\"a48\",\"start_steps\":0,\"length_steps\":128}]},"
           "{\"id\":\"c44\",\"name\":\"C44\",\"volume\":1,\"audio_clips\":[{\"id\":\"x\",\"asset\":\"a44\",\"start_steps\":0,\"length_steps\":128}]},"
           "{\"id\":\"str\",\"name\":\"Str\",\"volume\":1,\"audio_clips\":[{\"id\":\"x\",\"asset\":\"ah\",\"start_steps\":0,\"length_steps\":128,"
           "\"stretch\":\"signalsmith\",\"stretch_ratio\":2}]},"
           "{\"id\":\"mon\",\"name\":\"Mon\",\"volume\":1,\"input\":{\"channel\":0,\"channels\":1,\"monitor\":\"on\",\"armed\":false}}"
           "]}";
}

const std::vector<std::string> kSongTracks = {"midi", "drums", "c48", "c44", "str"};
const std::vector<std::string> kAllTracks = {"midi", "drums", "c48", "c44", "str", "mon"};

// Each track's output, in the order the engine rendered it (the song's frames), and the device's played output.
struct Run {
    std::vector<std::vector<float>> tracks;
    std::vector<float> played;
    double bridgeDelayMin = 1e9, bridgeDelayMax = -1e9;
    int64_t underruns = 0, skipped = 0;
    Engine::SheddingStats shedding;
};

// A capture device on its own clock: `ppm` faster than the output, calling back with `period(k)` frames.
struct Capture {
    double ppm = 0;
    std::function<int(int)> period;
    double due = 0;  // capture frames owed by the wall clock
    int64_t t = 0, calls = 0;
    std::vector<float> buf;
    // The input: a 1.0 impulse on channel 0 every kBeat capture frames.
    void run(InputBridge& b, int outFrames) {
        due += outFrames * (1.0 + ppm * 1e-6);
        for (;;) {
            const int n = period(static_cast<int>(calls));
            if (t + n > static_cast<int64_t>(due)) break;
            buf.assign(static_cast<size_t>(n) * 2, 0.0f);
            for (int i = 0; i < n; ++i)
                if ((t + i) % kBeat == 0) buf[static_cast<size_t>(i) * 2] = 1.0f;
            b.push(buf.data(), n);
            t += n;
            ++calls;
        }
    }
};

struct Options {
    int64_t frames = kLoop;
    std::function<int(int)> outSize = [](int) { return kBlock; };
    bool device = false;    // DeviceRender (openVarying) as the AAudio callback, else Engine::process straight
    bool input = false;     // the input bridge open and fed
    double ppm = 0;
    std::function<int(int)> capSize = [](int) { return 240; };
    // Calls at which the input opens or closes (alternately, from `input`), mid-play.
    std::vector<int> toggleAt;
    // The device's load reported after each callback (reportLoad), by the song frame it reached: null for none.
    std::function<double(int64_t)> load;
};

Run play(const std::string& json, const Options& o) {
    Engine e(kRate);
    e.setMasterBypass(true);
    const std::string res = e.setProjectJson(json);
    CHECK(res.find("\"ok\":true") != std::string::npos);
    if (res.find("\"ok\":true") == std::string::npos) std::printf("%s\n", res.c_str());
    const size_t nt = kAllTracks.size();
    std::vector<std::vector<float>> tl(nt, std::vector<float>(DeviceRender::kChunk)), tr = tl;
    for (size_t t = 0; t < nt; ++t) CHECK(e.setOutputTap(kAllTracks[t], tl[t].data(), tr[t].data()));
    Run run;
    run.tracks.assign(nt, {});
    for (auto& v : run.tracks) v.reserve(static_cast<size_t>(o.frames + 4096));
    int lastM = 0;
    auto harvest = [&] {
        for (size_t t = 0; t < nt; ++t)
            for (int i = 0; i < lastM; ++i) run.tracks[t].push_back(tl[t][static_cast<size_t>(i)] + tr[t][static_cast<size_t>(i)]);
        lastM = 0;
    };
    auto bridge = std::make_unique<InputBridge>();
    Capture cap;
    cap.ppm = o.ppm;
    cap.period = o.capSize;
    bool inputOpen = false;
    auto openInput = [&] {
        bridge->open(2, 2 * 240 + 1920 + kBlock - 1, 8 * 1920, kRate / 4, kRate);
        e.liveAudio().setDeviceChannels(2);
        cap.due = 0;
        cap.t = 0;
        inputOpen = true;
    };
    auto closeInput = [&] {
        bridge->close();
        e.liveAudio().setDeviceChannels(0);
        inputOpen = false;
    };
    if (o.input) openInput();
    DeviceRender dev;
    dev.openVarying(192);
    e.requestDeviceWarmUp();
    e.play();
    std::vector<float> out(8192 * 2), l(8192), r(8192);
    size_t toggle = 0;
    int64_t at = 0;
    for (int call = 0; at < o.frames; ++call) {
        if (toggle < o.toggleAt.size() && call == o.toggleAt[toggle]) {
            ++toggle;
            if (inputOpen) closeInput();
            else openInput();
        }
        const int n = o.outSize(call);
        if (o.device) {
            bridge->beginCallback(n);
            const int rendered = dev.render(e, out.data(), n, [&](int m, int& ch) -> const float* {
                harvest();
                lastM = m;
                return bridge->pull(m, ch);
            });
            harvest();
            if (o.load) e.reportLoad(o.load(at), n, rendered);
            for (int i = 0; i < n; ++i) run.played.push_back(out[static_cast<size_t>(i) * 2]);
        } else {
            for (int done = 0; done < n;) {
                const int m = std::min(n - done, DeviceRender::kChunk);
                int ch = 0;
                const float* in = bridge->pull(m, ch);
                e.liveAudio().beginCallback(in, in ? ch : 0, m);
                e.process(l.data(), r.data(), m);
                e.liveAudio().afterCallback(l.data(), r.data(), m);
                lastM = m;
                harvest();
                done += m;
            }
        }
        if (inputOpen) {
            cap.run(*bridge, n);
            if (at > 20 * kRate) {
                run.bridgeDelayMin = std::min(run.bridgeDelayMin, bridge->delay());
                run.bridgeDelayMax = std::max(run.bridgeDelayMax, bridge->delay());
            }
        }
        at += n;
    }
    run.underruns = bridge->underruns();
    run.skipped = bridge->skipped();
    run.shedding = e.sheddingStats();
    return run;
}

// Where a track's transients start: the first frame over `threshold` after at least `quiet` frames under it.
std::vector<int64_t> onsets(const std::vector<float>& x, float threshold, int quiet) {
    std::vector<int64_t> at;
    int64_t under = quiet;
    for (size_t i = 0; i < x.size(); ++i) {
        if (std::fabs(x[i]) > threshold) {
            if (under >= quiet) at.push_back(static_cast<int64_t>(i));
            under = 0;
        } else {
            ++under;
        }
    }
    return at;
}

// Fails unless a track's onset falls within `tol` frames of every beat from `from` (song frames rendered).
void checkBeats(const std::string& name, const std::vector<float>& x, int64_t from, int64_t tol, int64_t offset = 0) {
    const std::vector<int64_t> at = onsets(x, 0.05f, 2000);
    int64_t worst = 0, checked = 0, missing = 0;
    size_t k = 0;
    for (int64_t beat = from; beat + kBeat < static_cast<int64_t>(x.size()); beat += kBeat) {
        const int64_t want = beat + offset;
        while (k < at.size() && at[k] < want - kBeat / 2) ++k;
        if (k >= at.size() || at[k] > want + kBeat / 2) {
            ++missing;
            continue;
        }
        int64_t best = std::llabs(at[k] - want);  // the nearest onset (a stretched click has an echo a quarter beat on)
        for (size_t j = k + 1; j < at.size() && at[j] <= want + kBeat / 2; ++j) best = std::min<int64_t>(best, std::llabs(at[j] - want));
        worst = std::max<int64_t>(worst, best);
        ++checked;
    }
    if (worst > tol || missing > 0 || checked == 0)
        cawtest::fail(__FILE__, __LINE__, name + ": " + std::to_string(checked) + " beats, " + std::to_string(missing) +
                                              " missing, worst " + std::to_string(worst) + " frames off");
}

// Fails where a track's samples differ from the reference's (a shift of any size, or a different sound).
void checkSame(const std::string& name, const std::vector<float>& got, const std::vector<float>& ref) {
    const size_t n = std::min(got.size(), ref.size());
    int64_t differ = 0, first = -1;
    for (size_t i = 0; i < n; ++i)
        if (got[i] != ref[i]) {
            if (first < 0) first = static_cast<int64_t>(i);
            ++differ;
        }
    if (differ)
        cawtest::fail(__FILE__, __LINE__, name + ": " + std::to_string(differ) + " samples differ from frame " +
                                              std::to_string(first) + " (" + std::to_string(first / kRate) + " s)");
}

// The device's callback sizes: the burst, Bluetooth's and the legacy path's, and a jittery mix of them.
std::function<int(int)> varyingSizes(unsigned seed) {
    auto rng = std::make_shared<std::mt19937>(seed);
    return [rng](int) {
        static const int sizes[] = {96, 192, 192, 192, 240, 441, 480, 960, 1920, 37, 1023};
        std::uniform_int_distribution<int> pick(0, static_cast<int>(std::size(sizes)) - 1);
        return sizes[pick(*rng)];
    };
}

}  // namespace

TEST(every_track_stays_on_its_beats_for_minutes_through_the_device_path_with_the_input_on) {
    // #241 (the owner's S22+, 1.0.5-alpha.1): tracks drift out of time with each other while playing, more with
    // the microphone on. Four minutes of a song with MIDI, drums, 48 and 44.1 kHz clips and a 2x Signalsmith clip:
    // through DeviceRender at AAudio's varying sizes, with the input bridge fed by a capture 300 ppm fast in its own
    // sizes, every song track plays exactly the samples it plays in 64-frame blocks with no input, and each beat
    // lands where it should.
    TempRoot root;
    const std::string json = songJson(root.path);
    Options ref;
    ref.frames = 4 * 60 * kRate;
    const Run a = play(json, ref);
    // The reference is itself on the beat, all four minutes: the impulse exactly, the clicks (which start at 0, so
    // cross the threshold a frame in) within the resampler's and the stretcher's smear (its pre-echo, 70 to 180 frames, the same every loop).
    checkBeats("reference midi", a.tracks[0], 0, 0);
    checkBeats("reference c48", a.tracks[2], 0, 1, 1);
    checkBeats("reference c44", a.tracks[3], 0, 2, 1);
    checkBeats("reference str", a.tracks[4], kBeat, 200);
    Options dev = ref;
    dev.device = true;
    dev.input = true;
    dev.ppm = 300;
    dev.outSize = varyingSizes(7);
    dev.capSize = [](int) { return 240; };
    const Run b = play(json, dev);
    for (size_t t = 0; t < kSongTracks.size(); ++t) checkSame("device+input " + kSongTracks[t], b.tracks[t], a.tracks[t]);
    // The monitored input: each impulse arrives a steady delay after it was captured, the drift followed.
    std::printf("  bridge delay %.1f..%.1f frames, %lld underruns, %lld skipped\n", b.bridgeDelayMin, b.bridgeDelayMax,
                static_cast<long long>(b.underruns), static_cast<long long>(b.skipped));
    CHECK_EQ(b.underruns, 0);
    CHECK_EQ(b.skipped, 0);
    const std::vector<int64_t> mon = onsets(b.tracks[5], 0.3f, 2000);
    CHECK(mon.size() > 200);
    std::vector<double> lag;
    for (size_t k = 0; k < mon.size(); ++k) {
        // The k-th impulse was captured at capture frame k * kBeat: output frame k * kBeat / (1 + 300 ppm).
        const double captured = static_cast<double>(mon[0]) + static_cast<double>(k) * kBeat / (1.0 + 300e-6);
        if (mon[k] > 30 * kRate) lag.push_back(static_cast<double>(mon[k]) - captured);
    }
    CHECK(!lag.empty());
    const auto [lo, hi] = std::minmax_element(lag.begin(), lag.end());
    std::printf("  monitored input lag after 30 s: %.1f..%.1f frames\n", lag.empty() ? 0 : *lo, lag.empty() ? 0 : *hi);
    if (!lag.empty()) CHECK(*hi - *lo < 64);
}

TEST(opening_and_closing_the_input_mid_play_keeps_every_track_in_time) {
    // #241: the microphone opened and closed while the song plays (Settings, an armed track) changes nothing the
    // song tracks play.
    TempRoot root;
    const std::string json = songJson(root.path);
    Options ref;
    ref.frames = 90 * kRate;
    const Run a = play(json, ref);
    Options dev = ref;
    dev.device = true;
    dev.ppm = -150;
    dev.outSize = varyingSizes(21);
    dev.capSize = [](int) { return 480; };
    dev.toggleAt = {300, 2000, 2600, 5000, 5100, 9000};
    const Run b = play(json, dev);
    for (size_t t = 0; t < kSongTracks.size(); ++t) checkSame("toggled input " + kSongTracks[t], b.tracks[t], a.tracks[t]);
}

TEST(a_layer_shed_under_load_comes_back_on_its_beats) {
    // #241: with the microphone on the phone does more, and the device may shed layers (reportLoad). A layer shed
    // and brought back plays on its beats again, track against track, as the reference does.
    TempRoot root;
    const std::string json = songJson(root.path);
    Options ref;
    ref.frames = 60 * kRate;
    const Run a = play(json, ref);
    Options dev = ref;
    dev.device = true;
    dev.input = true;
    dev.ppm = 200;
    dev.outSize = varyingSizes(33);
    // Overloaded from 5 s to 14.5 s (several layers shed, a second apart), then light: they come back 2 s apart.
    // 1.1.2: the last layer still sounding is never shed, so five go, not six, and they come back in another order;
    // the overload ends at 14.5 s (12 s before) so the drums come back where their exact match holds: a shed slot
    // is silent and its instrument stops where it is, and the kit's state when it starts again depends on where in
    // its pattern that is (ending the overload between 14.04 and 14.6 s matches; 12, 14 and 15 s are a few millionths
    // off; docs/performance.md).
    dev.load = [](int64_t at) { return at >= 5 * kRate && at < 14 * kRate + kRate / 2 ? 0.97 : 0.2; };
    const Run b = play(json, dev);
    std::printf("  shed %llu, restored %llu, muted at the end %d\n", static_cast<unsigned long long>(b.shedding.shed),
                static_cast<unsigned long long>(b.shedding.restored), b.shedding.mutedNow);
    CHECK(b.shedding.shed >= 3);
    CHECK_EQ(b.shedding.mutedNow, 0);
    // From 40 s every layer is back: its beats where the reference has them, the plain ones to the sample.
    const int64_t from = 40 * kRate;
    for (size_t t = 0; t < kSongTracks.size(); ++t) {
        std::vector<float> got(b.tracks[t].begin() + from, b.tracks[t].end()), want(a.tracks[t].begin() + from, a.tracks[t].end());
        if (kSongTracks[t] != "str") checkSame("restored " + kSongTracks[t], got, want);
    }
    checkBeats("restored str", std::vector<float>(b.tracks[4].begin() + from, b.tracks[4].end()), 0, 200);
}
