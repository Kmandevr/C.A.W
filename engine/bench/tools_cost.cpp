// caw_bench's 1.1.0 tools cost (`caw_bench SECONDS 300` and `301`): MIDI effects, Meters, Lo-fi and Phase align, in µs per second of audio and bytes per instance, each against a ceiling.
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include "reference_cost.h"
#include "builtin_components.h"
#include "caw/instrument.hpp"
#include "fx_merged.h"
#include "module_registry.h"

// Bytes allocated while `g_counting` is set: an instance's activate and construction (its RAM), not its run.
namespace {
std::atomic<bool> g_counting{false};
std::atomic<size_t> g_bytes{0};
}  // namespace

void* operator new(std::size_t n) {
    if (g_counting.load(std::memory_order_relaxed)) g_bytes.fetch_add(n, std::memory_order_relaxed);
    if (void* p = std::malloc(n ? n : 1)) return p;
    throw std::bad_alloc();
}
void* operator new[](std::size_t n) { return operator new(n); }
void* operator new(std::size_t n, const std::nothrow_t&) noexcept {
    if (g_counting.load(std::memory_order_relaxed)) g_bytes.fetch_add(n, std::memory_order_relaxed);
    return std::malloc(n ? n : 1);
}
void* operator new[](std::size_t n, const std::nothrow_t& t) noexcept { return operator new(n, t); }
void operator delete(void* p) noexcept { std::free(p); }
void operator delete[](void* p) noexcept { std::free(p); }
void operator delete(void* p, std::size_t) noexcept { std::free(p); }
void operator delete[](void* p, std::size_t) noexcept { std::free(p); }

using namespace caw;
using Values = std::vector<std::pair<std::string, double>>;

namespace {

constexpr double kRate = 48000.0;
constexpr uint32_t kBlock = 64;

const ModuleRegistry& registry() {
    static const ModuleRegistry r = [] {
        ModuleRegistry x;
        registerBuiltinComponents(x);
        return x;
    }();
    return r;
}

struct Made {
    std::unique_ptr<ModuleProcessor> p;
    size_t bytes = 0;
};
Made make(const char* id, const Values& values) {
    Made m;
    registry();  // built before counting: the registry is not the instance's
    g_bytes.store(0);
    g_counting.store(true);
    m.p = createComponent(registry(), id, values);
    const bool ok = m.p && m.p->activate(kRate, kBlock);
    g_counting.store(false);
    if (!ok) m.p.reset();
    m.bytes = g_bytes.load();
    return m;
}

std::vector<ParameterValue> paramsOf(const ModuleDescriptor& d, const Values& values) {
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, v] : values)
            if (d.parameters[k].id == name) params[k].value = v;
    }
    return params;
}

// An audio effect on a busy stereo signal (noise bursts and tones, never silent), with a key when it has one.
double audioCost(ModuleProcessor& p, const Values& values, double seconds) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params = paramsOf(d, values);
    const int frames = static_cast<int>(kRate);
    std::vector<float> inL(frames), inR(frames), keyL(frames), keyR(frames), outL(kBlock), outR(kBlock);
    uint32_t seed = 1;
    for (int i = 0; i < frames; ++i) {
        seed = seed * 1664525u + 1013904223u;
        const double noise = (static_cast<double>(seed >> 8) / 8388608.0 - 1.0) * (0.05 + 0.3 * ((i / 6000) % 2));
        inL[i] = static_cast<float>(noise + 0.3 * std::sin(2 * 3.14159265358979 * 220 * i / kRate));
        inR[i] = static_cast<float>(0.8 * noise + 0.3 * std::sin(2 * 3.14159265358979 * 330 * i / kRate));
    }
    for (int i = 0; i < frames; ++i) keyL[i] = keyR[i] = i >= 37 ? inL[i - 37] : 0.0f;  // the key: 37 frames early
    bool keyed = false;
    for (uint32_t k = 0; k < d.portCount; ++k) keyed = keyed || (d.ports[k].input && d.ports[k].id == "sidechain");
    Transport tr;
    tr.playing = true;
    bench::RelativeCost rel;  // against the reference, interleaved (reference_cost.h)
    for (int run = 0; run < bench::kRuns; ++run) {
        p.reset();
        const int blocks = static_cast<int>(seconds * kRate / kBlock);
        rel.begin();
        for (int b = 0; b < blocks; ++b) {
            rel.tick(b);
            const int at = (b * static_cast<int>(kBlock)) % (frames - static_cast<int>(kBlock));
            const float* in[2] = {inL.data() + at, inR.data() + at};
            const float* key[2] = {keyL.data() + at, keyR.data() + at};
            float* out[2] = {outL.data(), outR.data()};
            if (keyed) {
                const ConstChannelBufferView audioIn[2] = {{in, 2, kBlock}, {key, 2, kBlock}};
                const ChannelBufferView audioOut{out, 2, kBlock};
                ProcessBlock pb;
                pb.frames = kBlock;
                pb.sampleRate = kRate;
                pb.audioIn = audioIn;
                pb.audioInCount = 2;
                pb.audioOut = &audioOut;
                pb.audioOutCount = 1;
                pb.parameters = params.data();
                pb.parameterCount = d.parameterCount;
                pb.transport = &tr;
                p.processPorts(pb);
            } else {
                AudioProcessBlock block;
                block.input = {in, 2, kBlock};
                block.output = {out, 2, kBlock};
                block.frames = kBlock;
                block.sampleRate = kRate;
                block.parameters = params.data();
                block.parameterCount = d.parameterCount;
                block.transport = &tr;
                p.process(block);
            }
            float sink[16];
            p.readDisplay(sink, 16);  // a page on screen: the display work runs (watched)
        }
        rel.end();
    }
    return rel.us();
}

// A MIDI effect on a busy part: a four-note chord every beat at 120 BPM plus a 16th-note line, while playing.
double midiCost(ModuleProcessor& p, const Values& values, double seconds) {
    const ModuleDescriptor& d = p.descriptor();
    std::vector<ParameterValue> params = paramsOf(d, values);
    std::vector<Event> in(512), out(4096);
    bench::RelativeCost rel;  // against the reference, interleaved (reference_cost.h)
    for (int run = 0; run < bench::kRuns; ++run) {
        p.reset();
        const int64_t blocks = static_cast<int64_t>(seconds * kRate / kBlock);
        uint32_t id = 0;
        int64_t heldUntil[8] = {}, ids[8] = {};
        rel.begin();
        for (int64_t b = 0; b < blocks; ++b) {
            rel.tick(b);
            const int64_t t = b * kBlock;
            uint32_t n = 0;
            for (uint32_t f = 0; f < kBlock; ++f) {
                const int64_t s = t + f;
                for (int v = 0; v < 8; ++v)
                    if (ids[v] && heldUntil[v] == s) in[n++] = notes::noteOff(f, static_cast<uint32_t>(ids[v]), 60), ids[v] = 0;
                if (s % 24000 == 0)
                    for (int v = 0; v < 4; ++v) ids[v] = ++id, heldUntil[v] = s + 20000, in[n++] = notes::noteOn(f, id, 48 + 4 * v, 0.8);
                if (s % 6000 == 0) ids[4] = ++id, heldUntil[4] = s + 3000, in[n++] = notes::noteOn(f, id, 60 + (s / 6000) % 12, 0.7);
            }
            const EventInput ein{in.data(), n};
            EventOutput eout{out.data(), 4096, 0};
            Transport tr;
            tr.playing = true;
            tr.beat = static_cast<double>(t) / 24000.0;
            ProcessBlock pb;
            pb.frames = kBlock;
            pb.sampleRate = kRate;
            pb.eventIn = &ein;
            pb.eventInCount = 1;
            pb.eventOut = &eout;
            pb.eventOutCount = 1;
            pb.parameters = params.data();
            pb.parameterCount = d.parameterCount;
            pb.transport = &tr;
            p.processPorts(pb);
        }
        rel.end();
    }
    return rel.us();
}

struct Case {
    const char* name;
    const char* id;
    Values values;
    double ceilingUs;  // µs per second of audio on the x86 CI machine; over it fails
};

}  // namespace

// Prints each case and returns how many went over their ceilings. Ceilings: the owner's budgets (light 0.5 %,
// medium 2 %, heavy 6 % of an S22+ core) over an assumed 2.5x slower phone core: 2000, 8000 and 24000 µs/s here.
int toolsCost(double seconds) {
    const Case cases[] = {
        {"MIDI: arpeggiator (random, 3 octaves)", "org.caw.midi.arp", {{"pattern", 5}, {"octaves", 3}}, 2000},
        {"MIDI: chords (ninths, strummed)", "org.caw.midi.chords", {{"type", 2}, {"strum", 20}}, 2000},
        {"MIDI: scale (snap, transpose)", "org.caw.midi.scale", {{"transpose", 2}}, 2000},
        {"MIDI: note echo (16 repeats)", "org.caw.midi.echo", {{"repeats", 16}, {"decay", 0.95}}, 2000},
        {"MIDI: humanize", "org.caw.midi.humanize", {{"timing", 30}}, 2000},
        {"Meters: Analyzer (on screen)", "org.caw.meters", {{"variant", 0}}, 2000},
        {"Meters: Tuner (on screen)", "org.caw.meters", {{"variant", 1}}, 2000},
        {"Meters: Loudness", "org.caw.meters", {{"variant", 2}}, 8000},
        {"Lo-fi: Age 1 (every section)", "org.caw.lofi", {{"age", 1.0}, {"band", 2}, {"wobble", 0.5}}, 8000},
        {"Lo-fi: cassette band and hiss", "org.caw.lofi", {{"band", 3}, {"hiss", 0.5}}, 8000},
        {"Phase align: manual 3.3 ms", "org.caw.phasealign", {{"delay", 3.3}}, 2000},
        {"Phase align: Auto, learning", "org.caw.phasealign", {{"mode", 1}, {"window", 10}}, 8000},
    };
    int over = 0;
    std::printf("1.1.0 tools (µs of CPU per second of audio; bytes per instance; ceiling µs/s):\n");
    for (const Case& c : cases) {
        Made m = make(c.id, c.values);
        if (!m.p) {
            std::printf("  %-44s  could not be made\n", c.name);
            ++over;
            continue;
        }
        const bool midi = m.p->descriptor().role == ModuleRole::EventProcessor;
        const double us = midi ? midiCost(*m.p, c.values, seconds) : audioCost(*m.p, c.values, seconds);
        const bool bad = us > c.ceilingUs;
        over += bad;
        std::printf("  %-44s %8.0f %9zu B  %6.0f%s\n", c.name, us, m.bytes, c.ceilingUs, bad ? "  OVER" : "");
    }
    return over;
}
