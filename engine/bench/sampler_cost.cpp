// caw_bench's cost of the sampler's zones (`caw_bench SECONDS 300` and `308`): four held notes on a plain zone and on stretched ones, in µs per second of audio, each against a ceiling.
#include <cmath>
#include <cstdio>
#include <filesystem>
#include <string>
#include <vector>

#include "engine.h"
#include "json.h"
#include "reference_cost.h"
#include "wav.h"

using namespace caw;

namespace {

std::string b64(const std::string& s) { return base64Encode(reinterpret_cast<const uint8_t*>(s.data()), s.size()); }

// The engine playing a four-note chord held for the whole run on the sampler with `zoneExtra` on its one zone,
// in 64-frame callbacks, against the reference.
double chordCost(const std::string& wav, const std::string& zoneExtra, double seconds) {
    const std::string state = "{\"zones\":[{\"path\":\"" + jsonEscape(wav) + "\",\"pitch_keycenter\":60,"
                              "\"loop_mode\":\"loop_continuous\",\"loop_start\":4800,\"loop_end\":43200" + zoneExtra + "}]}";
    const std::string pattern = "---\\nkind: pattern\\nlength: 64\\n---\\n0 60 64 1\\n0 64 64 1\\n0 67 64 1\\n0 71 64 1\\n";
    const std::string json = "{\"caw_project\":1,\"bpm\":120,\"loop_bars\":4,\"master\":1,\"modules\":[{\"id\":\"p\","
        "\"source\":\"" + pattern + "\"}],\"layers\":[{\"id\":\"s\",\"name\":\"S\",\"volume\":1,\"pattern\":\"p\","
        "\"instrument\":{\"id\":\"org.caw.sampler\",\"state\":\"" + b64(state) + "\"}}]}";
    bench::RelativeCost rel;
    std::vector<float> l(64), r(64);
    for (int run = 0; run < bench::kRuns; ++run) {
        Engine e(48000);
        if (e.setProjectJson(json).find("\"ok\":true") == std::string::npos) return 1e30;
        e.play(0);
        for (int b = 0; b < 200; ++b) e.process(l.data(), r.data(), 64);  // past the stretch's start-up bridge
        const int64_t blocks = static_cast<int64_t>(seconds * 48000 / 64);
        rel.begin();
        for (int64_t b = 0; b < blocks; ++b) {
            rel.tick(b);
            e.process(l.data(), r.data(), 64);
        }
        rel.end();
    }
    return rel.us();
}

}  // namespace

// Prints each case and returns how many went over their ceilings. The costs include the engine around the sampler
// (about 5000 µs/s here). A stretched voice runs Signalsmith Stretch, a stereo phase vocoder: heavy, about 17000 µs/s
// a voice on the calibration box (WSOLA about 3500), so a sampler keeps 4 of them and plays further stretched voices
// with WSOLA. Ceilings sit about 20 % above the measured cost (2026-11-19).
int samplerCost(double seconds) {
    const std::string dir = (std::filesystem::temp_directory_path() / "caw_bench_sampler").string();
    std::filesystem::create_directories(dir);
    const std::string wav = dir + "/tone.wav";
    {
        std::vector<float> x(48000);
        for (int i = 0; i < 48000; ++i) x[static_cast<size_t>(i)] = static_cast<float>(0.3 * std::sin(2 * 3.14159265358979 * 261.63 * i / 48000.0));
        WavSpec s;
        s.sampleRate = 48000;
        s.channels = 1;
        s.float32 = true;
        std::string error;
        if (!writeFile(wav, encodeWav(s, x.data(), 48000), error)) return 1;
    }
    struct Case { const char* name; const char* extra; double ceilingUs; };
    const Case cases[] = {
        {"Sampler: 4 voices, plain zone", "", 9000},
        {"Sampler: 4 voices, stretched (Signalsmith)", ",\"stretch\":true", 90000},
        {"Sampler: 4 voices, stretched to the tempo", ",\"stretch\":true,\"stretch_bpm\":100", 90000},
    };
    int over = 0;
    std::printf("Sampler (µs of CPU per second of audio, the whole engine; ceiling µs/s):\n");
    for (const Case& c : cases) {
        const double us = chordCost(wav, c.extra, seconds);
        const bool bad = us > c.ceilingUs;
        over += bad;
        std::printf("  %-48s %8.0f  %6.0f%s\n", c.name, us, c.ceilingUs, bad ? "  OVER" : "");
    }
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);
    return over;
}
