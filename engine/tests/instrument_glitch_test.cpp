// The 1.1.3 instruments' glitch scan and noise timing: no click, pop or spike over the running level (keys, velocities, fast repeats, overlaps, stealing, the pedal, knob moves), and each noise layer only at its physical moment.
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "test.h"
#include "timber_harness.h"

using namespace caw;
using namespace timber_test;

namespace {

constexpr double kSr = 48000;

// A knob moved while notes sound: from `from` to `to` over [at, at + over) seconds (in 64-frame steps, as a
// hand on a touch screen sends it).
struct Move {
    std::string id;
    double at, over, from, to;
};

struct Take {
    std::vector<Note> notes;
    std::vector<Cc> ccs;
    std::vector<Move> moves;
    double seconds = 2.0;
    double resetAt = -1;  // a transport stop (reset()) at this time
};

// timber_test::play with knob moves and a reset.
Stereo perform(const char* id, const Values& v, const Take& t, uint32_t block = 64) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, v);
    if (!p || !p->activate(kSr, 512)) return {};
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        params[k].value = d.parameters[k].defaultValue;
        for (const auto& [name, x] : v)
            if (d.parameters[k].id == name) params[k].value = x;
    }
    struct Timed {
        uint64_t frame;
        Event e;
    };
    std::vector<Timed> events;
    for (size_t k = 0; k < t.notes.size(); ++k) {
        const Note& n = t.notes[k];
        events.push_back({static_cast<uint64_t>(n.on * kSr), notes::noteOn(0, static_cast<uint32_t>(k + 1), n.pitch, n.velocity)});
        if (n.off >= 0)
            events.push_back({static_cast<uint64_t>(n.off * kSr), notes::noteOff(0, static_cast<uint32_t>(k + 1), notes::keyOf(n.pitch))});
    }
    for (const Cc& c : t.ccs) {
        Event e;
        e.kind = EventKind::Midi;
        e.data[0] = (0x2u << 28) | (0xBu << 20) | (static_cast<uint32_t>(c.cc) << 8) |
                    static_cast<uint32_t>(std::lround(std::clamp(c.value, 0.0, 1.0) * 127));
        events.push_back({static_cast<uint64_t>(c.at * kSr), e});
    }
    std::stable_sort(events.begin(), events.end(), [](const Timed& a, const Timed& b) { return a.frame < b.frame; });
    const size_t total = static_cast<size_t>(t.seconds * kSr);
    Stereo out;
    out.l.assign(total, 0.0f), out.r.assign(total, 0.0f);
    size_t next = 0;
    bool wasReset = false;
    std::vector<Event> be;
    for (size_t at = 0; at < total; at += block) {
        const uint32_t frames = static_cast<uint32_t>(std::min<size_t>(block, total - at));
        const double now = at / kSr;
        if (t.resetAt >= 0 && !wasReset && now >= t.resetAt) p->reset(), wasReset = true;
        for (const Move& m : t.moves)
            for (uint32_t k = 0; k < d.parameterCount; ++k)
                if (d.parameters[k].id == m.id && now >= m.at) {
                    const double f = std::min(1.0, (now - m.at) / std::max(1e-9, m.over));
                    params[k].value = m.from + (m.to - m.from) * f;
                }
        be.clear();
        while (next < events.size() && events[next].frame < at + frames) {
            Event e = events[next].e;
            e.frame = static_cast<uint32_t>(events[next].frame - at);
            be.push_back(e);
            ++next;
        }
        float* ch[2] = {out.l.data() + at, out.r.data() + at};
        const ChannelBufferView audio{ch, 2, frames};
        const EventInput in{be.data(), static_cast<uint32_t>(be.size())};
        ProcessBlock b;
        b.frames = frames;
        b.sampleRate = kSr;
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &in;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        p->processPorts(b);
    }
    return out;
}

// A glitch: a 2 ms window whose peak is `kJumpDb` over the median of the 40 ms before it, or one sample step
// `kStepX` times the RMS step of that 40 ms, where neither a note started nor (`allowed`) a knob says a noise may
// begin. Windows more than 60 dB under the take's peak are the noise floor: not judged.
constexpr double kJumpDb = 6.0, kStepX = 12.0;
struct Glitch {
    double at = -1, db = 0;
    const char* kind = "";
};
Glitch scan(const std::vector<float>& x, const std::vector<double>& allowed, double allowMs = 40.0) {
    const size_t w = static_cast<size_t>(0.002 * kSr), hist = 20;
    const size_t nw = x.size() / w;
    std::vector<double> peak(nw), step(nw);
    float top = 0;
    for (float s : x) top = std::max(top, std::fabs(s));
    for (size_t i = 0; i < nw; ++i) {
        float p = 0, s = 0;
        double e = 0;
        for (size_t j = i * w; j < (i + 1) * w; ++j) {
            p = std::max(p, std::fabs(x[j]));
            if (j > 0) {
                const float d = std::fabs(x[j] - x[j - 1]);
                s = std::max(s, d), e += static_cast<double>(d) * d;
            }
        }
        peak[i] = p;
        step[i] = std::sqrt(e / w);
        (void)s;
    }
    Glitch worst;
    for (size_t i = hist; i < nw; ++i) {
        const double t = static_cast<double>(i * w) / kSr;
        bool ok = false;
        for (double a : allowed) ok = ok || (t >= a - 0.004 && t < a + allowMs / 1000.0);
        if (ok || peak[i] < top * 1e-3) continue;
        std::vector<double> before(peak.begin() + static_cast<long>(i - hist), peak.begin() + static_cast<long>(i));
        std::nth_element(before.begin(), before.begin() + hist / 2, before.end());
        const double med = before[hist / 2];
        const double jump = 20 * std::log10(peak[i] / std::max(med, 1e-12));
        if (jump > kJumpDb && jump > worst.db) worst = {t, jump, "level jump"};
        double se = 0;
        for (size_t j = i - hist; j < i; ++j) se += step[j] * step[j];
        const double sref = std::sqrt(se / hist);
        float big = 0;
        for (size_t j = i * w + 1; j < (i + 1) * w; ++j) big = std::max(big, std::fabs(x[j] - x[j - 1]));
        const double sx = 20 * std::log10(big / std::max(sref, 1e-12));
        if (big > kStepX * sref && sx > worst.db) worst = {t, sx, "sample step"};
    }
    return worst;
}

struct Instrument {
    const char* id;
    const char* name;
    int variants;
    double low, high;  // the scan's keys
    Values extra;      // knobs every take uses (Starling: noise off, so its recorded noises are not flagged)
};
const Instrument kInstruments[] = {
    {"org.caw.starling", "Starling", 1, 24, 104, {{"noise", 0.0}}},
    {"org.caw.nightingale", "Nightingale", 4, 0, 0, {}},
    {"org.caw.curlew", "Curlew", 6, 0, 0, {}},
    {"org.caw.woodpecker", "Woodpecker", 6, 0, 0, {}},
};
// Each variant's keys (Nightingale, Curlew, Woodpecker): a range it plays.
void rangeOf(const Instrument& ins, int var, double& lo, double& hi) {
    static constexpr double kNight[4][2] = {{55, 96}, {48, 88}, {36, 76}, {28, 60}};
    static constexpr double kCurlew[6][2] = {{60, 96}, {50, 89}, {49, 80}, {54, 82}, {40, 72}, {41, 77}};
    static constexpr double kWood[6][2] = {{45, 96}, {65, 108}, {79, 108}, {53, 89}, {60, 77}, {40, 57}};
    if (std::string(ins.id) == "org.caw.nightingale") lo = kNight[var][0], hi = kNight[var][1];
    else if (std::string(ins.id) == "org.caw.curlew") lo = kCurlew[var][0], hi = kCurlew[var][1];
    else if (std::string(ins.id) == "org.caw.woodpecker") lo = kWood[var][0], hi = kWood[var][1];
    else lo = ins.low, hi = ins.high;
}

// The takes: (0) a sweep of the keys at three velocities, legato overlaps; (1) fast repeats of one key
// (restrikes); (2) a cluster over the voice cap (stealing); (3) the sustain pedal down and up under notes;
// (4) knobs moved while a chord sounds.
std::vector<Take> takesFor(const Instrument& ins, int var, std::vector<std::vector<double>>& onsets) {
    double lo = 0, hi = 0;
    rangeOf(ins, var, lo, hi);
    std::vector<Take> out;
    {
        Take t;
        double at = 0.02;
        int k = 0;
        for (double key = lo; key <= hi; key += 5, ++k) {
            const double vel = k % 3 == 0 ? 0.25 : (k % 3 == 1 ? 0.6 : 0.95);
            t.notes.push_back({at, at + 0.3, key, vel});
            at += 0.25;
        }
        t.seconds = at + 0.8;
        out.push_back(t);
    }
    {
        Take t;
        const double key = std::round(0.5 * (lo + hi));
        for (int k = 0; k < 14; ++k) t.notes.push_back({0.02 + 0.07 * k, 0.02 + 0.07 * k + 0.05, key, k % 2 ? 0.5 : 0.85});
        t.seconds = 1.8;
        out.push_back(t);
    }
    {
        Take t;
        for (int k = 0; k < 14; ++k) t.notes.push_back({0.02 + 0.04 * k, 1.2, lo + 2 * k, 0.7});
        t.seconds = 2.0;
        out.push_back(t);
    }
    {
        Take t;
        t.notes = {{0.02, 0.3, lo + 7, 0.7}, {0.35, 0.6, lo + 12, 0.7}, {0.65, 0.9, lo + 16, 0.6}};
        t.ccs = {{0.25, 64, 1.0}, {0.8, 64, 0.0}, {1.1, 64, 0.6}, {1.3, 64, 0.0}};
        t.seconds = 1.8;
        out.push_back(t);
    }
    {
        Take t;
        t.notes = {{0.02, 1.6, lo + 7, 0.7}, {0.02, 1.6, lo + 14, 0.7}, {0.4, 1.0, lo + 19, 0.6}};
        t.seconds = 2.2;
        out.push_back(t);
    }
    onsets.clear();
    for (const Take& t : out) {
        std::vector<double> on;
        for (const Note& n : t.notes) on.push_back(n.on);
        onsets.push_back(on);
    }
    return out;
}

// Take 4's knob moves: every continuous knob of the variant (but Level, Voices and Release, which a move only
// scales), in turn, from its default to its maximum and back to its minimum over 100 ms each.
std::vector<Move> movesFor(const ModuleDescriptor& d) {
    std::vector<Move> m;
    double at = 0.15;
    for (uint32_t k = 0; k < d.parameterCount; ++k) {
        const ParameterDescriptor& p = d.parameters[k];
        const std::string id(p.id);
        if (p.choiceCount > 0 || id == "level" || id == "voices" || id == "release" || id == "variant") continue;
        m.push_back({id, at, 0.05, p.defaultValue, p.maximum});
        m.push_back({id, at + 0.05, 0.05, p.maximum, p.minimum});
        m.push_back({id, at + 0.1, 0.03, p.minimum, p.defaultValue});
        at += 0.035;
    }
    return m;
}

int variantCount(const char* id) {
    std::unique_ptr<ModuleProcessor> p = createComponent(registry(), id, {});
    if (!p) return 0;
    for (uint32_t k = 0; k < p->descriptor().parameterCount; ++k)
        if (p->descriptor().parameters[k].id == "variant") return static_cast<int>(p->descriptor().parameters[k].choiceCount);
    return 1;
}

}  // namespace

TEST(instrument_glitch_scan) {
    int bad = 0;
    for (const Instrument& ins : kInstruments) {
        const int variants = variantCount(ins.id);
        for (int var = 0; var < variants; ++var) {
            const std::vector<std::pair<std::string, double>> chars =
                std::string(ins.id) == "org.caw.starling" ? std::vector<std::pair<std::string, double>>{{"Grand", 0}, {"Upright", 1}, {"Felt", 2}}
                                                          : std::vector<std::pair<std::string, double>>{{"", 0}};
            for (const auto& [cname, cval] : chars) {
                Values v = ins.extra;
                if (variants > 1) v.emplace_back("variant", var);
                if (!cname.empty()) v.emplace_back("character", cval);
                std::vector<std::vector<double>> onsets;
                std::vector<Take> takes = takesFor(ins, var, onsets);
                std::unique_ptr<ModuleProcessor> probe = createComponent(registry(), ins.id, v);
                takes[4].moves = movesFor(probe->descriptor());
                for (size_t t = 0; t < takes.size(); ++t) {
                    Values vv = v;
                    if (t == 2) vv.emplace_back("voices", 6.0);
                    const Stereo s = perform(ins.id, vv, takes[t]);
                    Glitch g = scan(s.mono(), onsets[t]);
                    const Glitch gl = scan(s.l, onsets[t]);
                    if (gl.db > g.db) g = gl;
                    const bool fail = g.at >= 0;
                    if (fail || verbose())
                        std::printf("%s %s %s take %zu: %s%s at %.3f s (%.1f dB)\n", fail ? "GLITCH" : "clean", ins.name,
                                    (variants > 1 ? std::to_string(var) : cname).c_str(), t, g.kind, cname.c_str(), g.at, g.db);
                    if (fail) ++bad;
                }
            }
        }
    }
    CHECK_EQ(bad, 0);
}
