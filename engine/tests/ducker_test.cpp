// The ducker (org.caw.ducker, #175) driven directly: retriggers, live look-ahead, bands, NaN keys, denormals, tempo grid.
#include <algorithm>
#include <cmath>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

#include "analysis.h"
#include "engine.h"
#include "test.h"

using namespace caw;

namespace {

constexpr double kPi = 3.14159265358979323846;

int paramIndex(const ModuleDescriptor& d, const std::string& id) {
    for (uint32_t k = 0; k < d.parameterCount; ++k)
        if (d.parameters[k].id == id) return static_cast<int>(k);
    cawtest::fail(__FILE__, __LINE__, "the ducker has no parameter " + id);
    return 0;
}

// A ducker with a main input, a key, the key's notes and (optionally) a playing transport, run in blocks.
struct Duck {
    Engine engine{48000};
    std::unique_ptr<ModuleProcessor> p;
    std::vector<ParameterValue> params;
    std::vector<float> inL, inR, keyL, keyR, outL, outR;
    std::vector<std::pair<int64_t, double>> notes;  // (frame, velocity)
    bool playing = false;
    double startBeat = 0.0, tempo = 120.0;
    // Called before each block with its first frame (a live knob move).
    std::function<void(int64_t)> before;

    explicit Duck(std::vector<std::pair<std::string, double>> values) {
        p = engine.createNativeComponent("org.caw.ducker");
        CHECK(p != nullptr);
        if (!p) return;
        CHECK(p->activate(48000, 512));
        const ModuleDescriptor& d = p->descriptor();
        params.resize(d.parameterCount);
        for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
        for (const auto& [id, v] : values) set(id, v);
    }
    void set(const std::string& id, double v) { params[static_cast<size_t>(paramIndex(p->descriptor(), id))].value = v; }
    void sized(size_t frames) {
        for (auto* v : {&inL, &inR, &keyL, &keyR}) v->resize(frames, 0.0f);
    }
    void run(uint32_t block = 64) {
        if (!p) return;
        const size_t frames = inL.size();
        outL.assign(frames, 0.0f);
        outR.assign(frames, 0.0f);
        Transport t;
        t.tempo = tempo;
        t.playing = playing;
        for (size_t start = 0; start < frames; start += block) {
            if (before) before(static_cast<int64_t>(start));
            const uint32_t n = static_cast<uint32_t>(std::min<size_t>(block, frames - start));
            std::vector<Event> events;
            for (const auto& [at, vel] : notes) {
                if (at < static_cast<int64_t>(start) || at >= static_cast<int64_t>(start + n)) continue;
                Event e;
                e.frame = static_cast<uint32_t>(at - static_cast<int64_t>(start));
                e.kind = EventKind::Note;
                e.data[0] = 0x40000000u | (0x9u << 20) | (60u << 8);
                e.data[1] = static_cast<uint32_t>(vel * 65535.0 + 0.5) << 16;
                events.push_back(e);
            }
            t.beat = startBeat + static_cast<double>(start) * tempo / (60.0 * 48000.0);
            const float* main[2] = {inL.data() + start, inR.data() + start};
            const float* key[2] = {keyL.data() + start, keyR.data() + start};
            float* out[2] = {outL.data() + start, outR.data() + start};
            ConstChannelBufferView ins[2] = {{main, 2, n}, {key, 2, n}};
            ChannelBufferView outs[1] = {{out, 2, n}};
            EventInput ev{events.data(), static_cast<uint32_t>(events.size())};
            ProcessBlock b;
            b.frames = n;
            b.sampleRate = 48000;
            b.audioIn = ins;
            b.audioInCount = 2;
            b.audioOut = outs;
            b.audioOutCount = 1;
            b.eventIn = &ev;
            b.eventInCount = 1;
            b.parameters = params.data();
            b.parameterCount = static_cast<uint32_t>(params.size());
            b.transport = &t;
            CHECK(p->processPorts(b));
        }
    }
};

// The largest sample-to-sample step of x over [from, to).
double maxStep(const std::vector<float>& x, size_t from, size_t to) {
    double m = 0;
    for (size_t i = std::max<size_t>(from, 1); i < std::min(to, x.size()); ++i)
        m = std::max(m, std::fabs(static_cast<double>(x[i]) - x[i - 1]));
    return m;
}

void fillSine(std::vector<float>& x, double hz, double amp) {
    for (size_t i = 0; i < x.size(); ++i) x[i] = static_cast<float>(amp * std::sin(2.0 * kPi * hz * i / 48000.0));
}

}  // namespace

TEST(the_ducker_keeps_its_gain_continuous_when_a_softer_note_retriggers_it) {
    // Audio review fix 1: Velocity 1, a full note then a soft one in the hold. The soft one's shallower depth used
    // to apply at once (gain 0.1 to 0.82 in one sample); it now glides in over the attack.
    Duck d({{"mode", 1.0}, {"velocity", 1.0}, {"depth", 0.9}, {"attack", 1.0}, {"hold", 100.0}, {"release", 200.0}});
    d.sized(12000);
    std::fill(d.inL.begin(), d.inL.end(), 0.5f);
    std::fill(d.inR.begin(), d.inR.end(), 0.5f);
    d.notes = {{0, 1.0}, {2400, 0.1}};
    d.run();
    CHECK_NEAR(d.outL[2000], 0.5 * 0.1, 1e-3);  // the full duck
    CHECK(maxStep(d.outL, 2300, 2700) < 0.02);
    CHECK_NEAR(d.outL[3000], 0.5 * (1.0 - 0.9 * 0.1), 1e-3);  // then the soft note's depth
}

TEST(the_ducker_survives_a_nan_or_infinite_key_in_follow_mode) {
    // Audio review fix 8: a NaN in the key stuck in the follower (and the key filters) and the output went NaN.
    for (double hpf : {20.0, 100.0}) {
        Duck d({{"mode", 0.0}, {"response", 1.0}, {"key_hpf", hpf}, {"attack", 1.0}, {"release", 50.0}});
        d.sized(24000);
        std::fill(d.inL.begin(), d.inL.end(), 0.25f);
        std::fill(d.inR.begin(), d.inR.end(), 0.25f);
        fillSine(d.keyL, 200.0, 0.5);
        fillSine(d.keyR, 200.0, 0.5);
        d.keyL[1000] = std::nanf("");
        d.keyR[2000] = INFINITY;
        d.keyL[3000] = -INFINITY;
        d.run();
        bool finite = true;
        for (size_t i = 0; i < d.outL.size(); ++i) finite = finite && std::isfinite(d.outL[i]) && std::isfinite(d.outR[i]);
        CHECK(finite);
        CHECK(d.outL[23000] < 0.25f * 0.5f);  // still ducking to the key
        CHECK(d.outL[23000] > 0.0f);
    }
}

TEST(the_ducker_flushes_denormals_in_its_key_and_band_filters) {
    // Audio review fix 7: after a burst, the key filters (heard with Key listen) and the band split decayed
    // through denormal numbers. A tiny constant on one main side keeps the ducker awake meanwhile.
    Duck d({{"mode", 0.0}, {"key_hpf", 100.0}, {"key_lpf", 2000.0}, {"listen", 1.0}});
    d.sized(48000 * 2);
    std::fill(d.inL.begin(), d.inL.end(), 1e-30f);
    for (size_t i = 0; i < 480; ++i) d.keyL[i] = d.keyR[i] = static_cast<float>(std::sin(i * 0.05));
    d.run();
    CHECK_EQ(analysis::levels(d.outL.data(), d.outL.size()).denormal, 0u);
    CHECK_EQ(d.outL.back(), 0.0f);

    Duck b({{"mode", 0.0}, {"bands", 1.0}});
    b.sized(48000 * 2);
    std::fill(b.inL.begin(), b.inL.end(), 1e-30f);
    for (size_t i = 0; i < 480; ++i) b.inR[i] = static_cast<float>(std::sin(i * 0.05));
    b.run();
    CHECK_EQ(analysis::levels(b.outR.data(), b.outR.size()).denormal, 0u);
    CHECK_EQ(b.outR.back(), 0.0f);
}

TEST(the_ducker_in_tempo_mode_waits_for_the_grid_when_play_starts_mid_beat) {
    // Audio review fix 9: Play from half a beat in ducked at once, off the grid. It now waits for the next beat.
    Duck d({{"mode", 2.0}, {"rate", 5.0}, {"depth", 1.0}, {"attack", 1.0}, {"hold", 10.0}, {"release", 100.0}});
    d.sized(36000);
    std::fill(d.inL.begin(), d.inL.end(), 0.25f);
    std::fill(d.inR.begin(), d.inR.end(), 0.25f);
    d.playing = true;
    d.startBeat = 0.5;  // a beat is 24000 frames at 120 bpm: the next one is at frame 12000
    d.run();
    CHECK_NEAR(d.outL[300], 0.25, 1e-6);
    CHECK(std::fabs(d.outL[12300]) < 1e-3);

    // From the top, the first frame is on the grid: it ducks at once.
    Duck e({{"mode", 2.0}, {"rate", 5.0}, {"depth", 1.0}, {"attack", 1.0}, {"hold", 10.0}, {"release", 100.0}});
    e.sized(4800);
    std::fill(e.inL.begin(), e.inL.end(), 0.25f);
    std::fill(e.inR.begin(), e.inR.end(), 0.25f);
    e.playing = true;
    e.run();
    CHECK(std::fabs(e.outL[300]) < 1e-3);
}
