// Rook 1.1.3 as the owner plays it: the recorded parts (embedded, loaded on use, balanced against the model), the three kinds' default kits clearly apart, every control of those kits audible, Randomness and a type-keeping Randomize, and a glitch and noise-timing scan.
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <memory>
#include <string>
#include <vector>

#include "builtin_drums.h"
#include "builtin_drums_layout.h"
#include "caw/instrument.hpp"
#include "drums_kits.h"
#include "engine.h"
#include "json.h"
#include "presets.h"
#include "quality.h"
#include "recorded_bank.h"
#include "test.h"

using namespace caw;
using namespace caw::drums;

namespace caw::assets {
extern const std::size_t rook_kit_flac_size;
}

namespace {

using Values = std::vector<std::pair<std::string, double>>;
constexpr double kSr = 48000.0;

// The kinds' default kits: what a kind card switches to (the app's drumKindDefaults says the same).
constexpr const char* kKindDefaults[3] = {"Synth kit: 808-style", "Produced kit: Pop", "Acoustic kit: Studio"};

std::unique_ptr<ModuleProcessor> make(int quality = kQualityNormal) {
    static Engine e(48000);
    std::unique_ptr<ModuleProcessor> p = e.createNativeComponent("org.caw.drums");
    CHECK(p != nullptr);
    if (!p) return p;
    static std::atomic<int> qualities[3] = {kQualityEco, kQualityNormal, kQualityHigh};
    const BuildingQuality building(&qualities[quality]);
    CHECK(p->activate(48000, 512));
    return p;
}

// Interleaved stereo of `events` with `values` over the descriptor's defaults, in blocks of `block`.
std::vector<float> render(const Values& values, const std::vector<Event>& events, uint32_t frames, uint32_t block = 64,
                          int quality = kQualityNormal) {
    std::unique_ptr<ModuleProcessor> p = make(quality);
    if (!p) return {};
    const ModuleDescriptor& d = p->descriptor();
    std::vector<ParameterValue> params(d.parameterCount);
    for (uint32_t k = 0; k < d.parameterCount; ++k) params[k].value = d.parameters[k].defaultValue;
    for (const auto& [id, v] : values) {
        const int k = parameterIndex(id);
        if (k < 0) cawtest::fail(__FILE__, __LINE__, "no parameter " + id);
        else params[static_cast<size_t>(k)].value = v;
    }
    std::vector<float> out, l(block), r(block);
    float* channels[2] = {l.data(), r.data()};
    const ChannelBufferView audio{channels, 2, block};
    size_t next = 0;
    for (uint32_t start = 0; start < frames; start += block) {
        std::vector<Event> in;
        while (next < events.size() && events[next].frame < start + block) {
            Event e = events[next++];
            e.frame -= start;
            in.push_back(e);
        }
        const EventInput ev{in.data(), static_cast<uint32_t>(in.size())};
        ProcessBlock b;
        b.frames = std::min(block, frames - start);
        b.audioOut = &audio;
        b.audioOutCount = 1;
        b.eventIn = &ev;
        b.eventInCount = 1;
        b.parameters = params.data();
        b.parameterCount = d.parameterCount;
        CHECK(p->processPorts(b));
        for (uint32_t i = 0; i < b.frames; ++i) out.push_back(l[i]), out.push_back(r[i]);
    }
    return out;
}

Values presetValues(const std::string& name) {
    Values v;
    const BuiltinPreset* p = findBuiltinPreset("org.caw.drums", name);
    if (!p) cawtest::fail(__FILE__, __LINE__, "no preset " + name);
    else
        for (const auto& [id, x] : p->values) v.emplace_back(std::string(id), x);
    return v;
}

double apart(const std::vector<float>& a, const std::vector<float>& b) {
    double d = 0, s = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
        d += std::fabs(static_cast<double>(a[i]) - b[i]);
        s += std::max(std::fabs(a[i]), std::fabs(b[i]));
    }
    return s > 0 ? d / s : 0.0;
}
std::vector<float> mono(const std::vector<float>& st) {
    std::vector<float> m(st.size() / 2);
    for (size_t i = 0; i < m.size(); ++i) m[i] = 0.5f * (st[2 * i] + st[2 * i + 1]);
    return m;
}
float peakOf(const std::vector<float>& x, size_t from = 0, size_t to = ~size_t(0)) {
    float p = 0.0f;
    for (size_t i = from; i < x.size() && i < to; ++i) p = std::max(p, std::fabs(x[i]));
    return p;
}
double dbOf(double a) { return 20.0 * std::log10(a + 1e-12); }

// A bar at 120 BPM in General MIDI keys (every kind's default kit plays them): kick on 1 and 3, snare on 2 and 4,
// closed hats in eighths, a crash at the start, an open hat, the three toms in the last beat, a ride.
struct Hit {
    uint32_t frame;
    int note;
    double velocity;
};
std::vector<Hit> groove() {
    std::vector<Hit> h;
    const uint32_t beat = 24000;
    h.push_back({0, 49, 0.9});
    for (uint32_t b = 0; b < 4; ++b) {
        h.push_back({b * beat, b % 2 ? 38 : 36, b % 2 ? 0.9 : 1.0});
        h.push_back({b * beat, 42, 0.6});
        if (b < 3) h.push_back({b * beat + beat / 2, b == 2 ? 46 : 42, 0.5});
    }
    h.push_back({3 * beat + 6000, 50, 0.8});
    h.push_back({3 * beat + 12000, 47, 0.8});
    h.push_back({3 * beat + 18000, 43, 0.85});
    h.push_back({4 * beat, 51, 0.7});
    std::sort(h.begin(), h.end(), [](const Hit& a, const Hit& b) { return a.frame < b.frame; });
    return h;
}
std::vector<Event> eventsOf(const std::vector<Hit>& hits) {
    std::vector<Event> e;
    uint32_t id = 1;
    for (const Hit& h : hits) e.push_back(notes::noteOn(h.frame, id++, static_cast<uint8_t>(h.note), h.velocity));
    return e;
}
constexpr uint32_t kGrooveFrames = 5 * 24000;

// The long-term spectrum in third-octave bands (25 Hz .. 16 kHz), each band's share of the total power, in dB.
std::vector<double> thirdOctaves(const std::vector<float>& x) {
    std::vector<double> bands;
    constexpr size_t kN = 4096;
    std::vector<double> power(kN / 2 + 1, 0.0);
    for (size_t at = 0; at + kN <= x.size(); at += kN / 2) {
        // A plain DFT per window is too slow; the power per bin by Goertzel over the band centres would miss
        // energy between them, so a radix-2 FFT it is.
        std::vector<double> re(kN), im(kN, 0.0);
        for (size_t i = 0; i < kN; ++i) re[i] = x[at + i] * (0.5 - 0.5 * std::cos(6.283185307179586 * i / kN));
        for (size_t i = 1, j = 0; i < kN; ++i) {
            size_t bit = kN >> 1;
            for (; j & bit; bit >>= 1) j ^= bit;
            j ^= bit;
            if (i < j) std::swap(re[i], re[j]), std::swap(im[i], im[j]);
        }
        for (size_t len = 2; len <= kN; len <<= 1) {
            const double ang = -6.283185307179586 / len;
            for (size_t i = 0; i < kN; i += len)
                for (size_t k = 0; k < len / 2; ++k) {
                    const double wr = std::cos(ang * k), wi = std::sin(ang * k);
                    const double ur = re[i + k], ui = im[i + k];
                    const double vr = re[i + k + len / 2] * wr - im[i + k + len / 2] * wi;
                    const double vi = re[i + k + len / 2] * wi + im[i + k + len / 2] * wr;
                    re[i + k] = ur + vr, im[i + k] = ui + vi;
                    re[i + k + len / 2] = ur - vr, im[i + k + len / 2] = ui - vi;
                }
        }
        for (size_t k = 0; k <= kN / 2; ++k) power[k] += re[k] * re[k] + im[k] * im[k];
    }
    double total = 0.0;
    for (double p : power) total += p;
    for (double fc = 25.0; fc <= 16000.0; fc *= std::exp2(1.0 / 3.0)) {
        const double lo = fc * std::exp2(-1.0 / 6.0), hi = fc * std::exp2(1.0 / 6.0);
        double e = 0.0;
        for (size_t k = 0; k <= kN / 2; ++k) {
            const double f = k * kSr / kN;
            if (f >= lo && f < hi) e += power[k];
        }
        bands.push_back(10.0 * std::log10((e + 1e-20) / (total + 1e-20)));
    }
    return bands;
}
// How far two spectra are apart: the RMS of their bands' difference in dB (bands below -60 dB in both left out).
double spectralDistance(const std::vector<double>& a, const std::vector<double>& b) {
    double s = 0.0;
    int n = 0;
    for (size_t i = 0; i < a.size() && i < b.size(); ++i) {
        if (a[i] < -60.0 && b[i] < -60.0) continue;
        const double d = std::max(a[i], -60.0) - std::max(b[i], -60.0);
        s += d * d;
        ++n;
    }
    return n ? std::sqrt(s / n) : 0.0;
}

// The pads of a kit's values that play (their engine Simulated, or a Synthesized layer on), by index.
std::vector<uint32_t> usedPads(const Values& kit) {
    std::vector<uint32_t> out;
    for (uint32_t pad = 0; pad < kPads; ++pad) {
        Voice v = defaultVoice(pad);
        const std::string prefix = padId(pad) + "_";
        for (const auto& [id, x] : kit)
            if (id.rfind(prefix, 0) == 0) {
                const int k = padParamIndex(id.substr(prefix.size()));
                if (k >= 0) v[static_cast<uint32_t>(k)] = x;
            }
        const bool layers = v[kBodyOn] + v[kSubOn] + v[kClickOn] + v[kNoiseOn] + v[kMetalOn] + v[kResOn] + v[kSmpOn] +
                                v[kFmOn] + v[kPhysOn] + v[kTexOn] > 0.0;
        if ((v[kEngine] == kEngineAcoustic || layers) && v[kLevel] > -59.0 && v[kNote] != kNoteOff) out.push_back(pad);
    }
    return out;
}

}  // namespace

// ---------- The recorded parts ----------

TEST(rook_recorded_parts_are_small_embedded_and_loaded_with_rook) {
    CHECK(assets::rook_kit_flac_size > 100000);
    CHECK(assets::rook_kit_flac_size <= 3u << 20);  // the owner's budget: at most about 3 MB for the kit
    const size_t before = recorded::residentBytes();
    {
        std::unique_ptr<ModuleProcessor> p = make();
        CHECK(recorded::residentBytes() > before);  // decoded with the first Rook
    }
    CHECK(recorded::residentBytes() == before);  // and freed with the last
}

TEST(rook_recorded_parts_balance_against_the_model) {
    // Each kind's piece alone (studio mics), its recorded share off and on, at velocity 0.9. A drum's recording sits
    // on its heads: a transient layer -14..+2 dB from the model's peak. A hat's or cymbal's replaces its plate, set
    // against the recorded snare as a dry rock or pop mix sits [Assumption, common mixing practice, no primary
    // source]: a closed hat 8..16 dB under it, an open hat 4..12, a crash 3..11, a ride 6..14.
    struct Case {
        int kind;
        double size;
        int artic;
        double lo, hi;  // a cymbal's peak against the snare's (dB)
    };
    const Case cases[] = {{kPieceSnare, 14, kArtHit, 0, 0},       {kPieceKick, 22, kArtHit, 0, 0},
                          {kPieceTom, 12, kArtHit, 0, 0},         {kPieceTom, 16, kArtHit, 0, 0},
                          {kPieceHiHat, 14, kArtClosed, -16, -8}, {kPieceHiHat, 14, kArtOpen, -12, -4},
                          {kPieceCrash, 16, kArtHit, -11, -3},    {kPieceRide, 20, kArtHit, -14, -6},
                          {kPieceRide, 20, kArtBell, -14, -6}};
    double snare = 0.0;
    for (const Case& c : cases) {
        auto one = [&](double rec) {
            return mono(render({{"mode", kModeSingle}, {"a1_engine", kEngineAcoustic}, {"a1_acou_piece", 0}, {"a1_acou_artic", c.artic},
                                {"pc1_kind", c.kind}, {"pc1_size", c.size}, {"pc1_rec", rec}, {"acou_mics", kMicsStudio}},
                               {notes::noteOn(0, 1, 60, 0.9)}, 48000));
        };
        const std::vector<float> model = one(0.0), both = one(1.0);
        std::vector<float> rec(both.size());
        for (size_t i = 0; i < rec.size(); ++i) rec[i] = both[i] - model[i];
        const double ratio = dbOf(peakOf(rec)) - dbOf(peakOf(model));
        if (c.kind == kPieceSnare) snare = dbOf(peakOf(both));
        const double against = dbOf(peakOf(both)) - snare;
        std::printf("rook balance: kind %d size %g artic %d: model %.1f dBFS, recorded %.1f dBFS (%+.1f dB), together %.1f dBFS "
                    "(%+.1f dB against the snare)\n",
                    c.kind, c.size, c.artic, dbOf(peakOf(model)), dbOf(peakOf(rec)), ratio, dbOf(peakOf(both)), against);
        if (isDrumPiece(c.kind)) {
            if (ratio < -14.0 || ratio > 2.0) cawtest::fail(__FILE__, __LINE__, "a drum's recorded layer is out of balance");
        } else if (against < c.lo || against > c.hi) {
            cawtest::fail(__FILE__, __LINE__, "a cymbal's recording is out of balance with the snare");
        }
    }
}

// ---------- The three kinds ----------

TEST(rook_kinds_default_kits_are_far_apart_spectrally) {
    // The owner, after 1.1.2: "Rook: I see no difference." The same bar through each kind's default kit: every pair's
    // third-octave spectra (loudness-normalised) at least 4 dB RMS apart, and each kit sounds.
    std::vector<std::vector<double>> spectra;
    for (const char* name : kKindDefaults) {
        const std::vector<float> x = mono(render(presetValues(name), eventsOf(groove()), kGrooveFrames));
        CHECK(peakOf(x) > 0.05f);
        spectra.push_back(thirdOctaves(x));
    }
    for (int a = 0; a < 3; ++a)
        for (int b = a + 1; b < 3; ++b) {
            const double d = spectralDistance(spectra[a], spectra[b]);
            std::printf("rook kinds: %s vs %s: %.1f dB RMS apart\n", kKindDefaults[a], kKindDefaults[b], d);
            if (d < 4.0) cawtest::fail(__FILE__, __LINE__, std::string(kKindDefaults[a]) + " sounds too like " + kKindDefaults[b]);
        }
}

TEST(rook_every_control_of_each_kinds_default_kit_is_audible) {
    // As the owner uses it: each kind's default kit loaded, the bar played, and every setting it uses (the kit's,
    // the Acoustic kit's, each piece's, and every parameter of its kick and snare pads, GM 36 and 38) moved to its
    // ends: the render changes measurably (over -100 dB of the bar, L1); one that changes it less than -70 dB is
    // listed as weak. Settings their needs say are not heard in this kit (a layer that is off) are skipped; the
    // settings audits (drums_audit_test, drums_acoustic_test) hear each in a context where it is.
    const ParameterDescriptor* t = parameterTable();
    int failures = 0, checked = 0;
    for (const char* name : kKindDefaults) {
        const Values kit = presetValues(name);
        auto valueOf = [&](uint32_t index) {
            double x = t[index].defaultValue;
            for (const auto& [id, v] : kit)
                if (id == t[index].id) x = v;
            return x;
        };
        auto heard = [&](uint32_t index, uint32_t pad, bool global) {
            for (const NeedRule& r : needs()) {
                if (r.global != global) continue;
                if (r.param != index) continue;  // index: the global one, or the pad parameter (PadParam)
                for (const Need& n : r.all) {
                    const double x = valueOf(n.global ? n.param : padParam(pad, n.param));
                    const bool ok = n.in.empty() ? x != 0.0 : std::find(n.in.begin(), n.in.end(), static_cast<int>(std::lround(x))) != n.in.end();
                    if (!ok) return false;
                }
            }
            return true;
        };
        const std::vector<uint32_t> pads = usedPads(kit);
        CHECK(pads.size() >= 8);
        std::vector<int> keys;
        bool autoNotes = false;
        for (uint32_t pad : pads) {
            double note = defaultVoice(pad)[kNote];
            for (const auto& [id, x] : kit)
                if (id == padId(pad) + "_note") note = x;
            autoNotes = autoNotes || note == kNoteAuto;
            keys.push_back(note == kNoteAuto ? autoNote(pad, 36) : static_cast<int>(note) - kNoteFirst);
        }
        std::vector<uint32_t> main;  // the kick's and the snare's pads
        for (int want : {36, 38})
            for (size_t i = 0; i < pads.size(); ++i)
                if (keys[i] == want) {
                    main.push_back(static_cast<uint32_t>(i));
                    break;
                }
        CHECK(main.size() == 2);
        std::vector<uint32_t> ids;
        for (uint32_t k = 0; k < kGlobalCount; ++k) ids.push_back(k);
        bool anyPiece = false;  // the Acoustic kit's own settings are heard only through its pieces
        for (uint32_t pc = 0; pc < kPieces; ++pc) anyPiece = anyPiece || static_cast<int>(valueOf(pieceParam(pc, kPcKind))) != kPieceOff;
        if (anyPiece)
            for (uint32_t k = kAcouBase; k < kAcouBase + kAcouCount; ++k) ids.push_back(k);
        for (uint32_t pc = 0; pc < kPieces; ++pc)
            if (static_cast<int>(valueOf(pieceParam(pc, kPcKind))) != kPieceOff)
                for (uint32_t k = 0; k < kPieceParams; ++k) ids.push_back(pieceParam(pc, k));
        for (uint32_t i : main)
            for (uint32_t k = 0; k < kPadParams; ++k) ids.push_back(padParam(pads[i], k));
        // The bar's hits (kick and snare on every beat among them), then every playing pad once on its own note
        // (whatever map the kit uses).
        std::vector<Hit> hits = groove();
        for (uint32_t i = 0; i < pads.size(); ++i) hits.push_back({kGrooveFrames + i * 2400, keys[i], 0.85});
        const uint32_t frames = kGrooveFrames + static_cast<uint32_t>(pads.size()) * 2400 + 24000;
        std::sort(hits.begin(), hits.end(), [](const Hit& a, const Hit& b) { return a.frame < b.frame; });
        const std::vector<Event> events = eventsOf(hits);
        const std::vector<float> ref = render(kit, events, frames);
        for (uint32_t index : ids) {
            const ParameterDescriptor& d = t[index];
            const std::string id(d.id);
            const bool global = index < kGlobalCount || index >= kAcouBase;
            const uint32_t pad = global ? 0 : (index - kGlobalCount) / kPadParams;
            const uint32_t suffix = global ? 0 : (index - kGlobalCount) % kPadParams;
            // Display and metadata (no sound by design), Randomize's amount (checked below by what Randomize
            // does), a pad's type (a label), the shown pad.
            if (id == "view_pad" || id == "kit_kind" || id == "randomness" || (!global && suffix == kType)) continue;
            if (!heard(global ? index : suffix, pad, global)) continue;
            // What the bar cannot play: pressure, a playing transport (the groove), held or overlapping notes and
            // routing (note, channel, trigger, voices, choke, outputs), a sample slot, an echo no pad sends to, an
            // acoustic layer on a kit with no pieces. drums_audit_test hears each of these where it can sound.
            if (!global) {
                const std::string_view group = d.group.substr(d.group.find('/') + 1);
                if (group == "press" || group == "groove" || group == "smp") continue;
                static constexpr uint32_t kRouting[] = {kNote, kChan, kTrack, kRoot, kMono, kGlide, kTrig, kRelease, kPoly, kChoke, kOut};
                if (std::find(std::begin(kRouting), std::end(kRouting), suffix) != std::end(kRouting)) continue;
                if (suffix == kAcouLayer && !anyPiece) continue;
            }
            if (id == "base_note" && !autoNotes) continue;  // every pad on a note of its own: no Auto note to move
            if (id == "echo") {
                bool sends = false;
                for (const auto& [k, x] : kit) sends = sends || (k.size() > 10 && k.substr(k.size() - 10) == "_echo_send" && x > 0.0);
                if (!sends) continue;
            }
            const double was = valueOf(index);
            bool any = false;
            double best = 0.0;
            const bool cycle = id.size() > 10 && id.substr(id.size() - 10) == "body_phase";  // a cycle: its ends are one phase
            for (double m : cycle ? std::vector<double>{0.25, 0.5} : std::vector<double>{d.minimum, d.maximum}) {
                if (d.choiceCount > 0 && m == d.maximum) m = d.choiceCount - 1;
                if (std::fabs(m - was) < 1e-9) continue;
                Values moved = kit;
                moved.emplace_back(id, m);
                const double x = apart(ref, render(moved, events, frames));
                best = std::max(best, x);
                any = any || x >= 1e-5;  // -100 dB of the bar's level, L1
            }
            ++checked;
            if (any && best < 3e-4) std::printf("rook: weak in %s: %s (%.2g of the bar, L1)\n", name, id.c_str(), best);
            if (!any && best >= 0.0 && !(std::fabs(d.minimum - was) < 1e-9 && std::fabs(d.maximum - was) < 1e-9)) {
                char msg[240];
                std::snprintf(msg, sizeof msg, "%s: %s changes nothing at its ends (%.2g apart)", name, id.c_str(), best);
                cawtest::fail(__FILE__, __LINE__, msg);
                ++failures;
            }
        }
    }
    std::printf("rook: %d settings of the kinds' default kits checked, %d dead\n", checked, failures);
    CHECK(checked > 400);
}

// ---------- Randomize ----------

namespace {
Voice voiceOf(const std::string& json, uint32_t pad) {
    Json j;
    std::string why;
    Voice v = defaultVoice(pad);
    if (!parseJson(json, j, why)) return v;
    const Json* params = j.get("params");
    if (!params) return v;
    const std::string prefix = padId(pad) + "_";
    for (const auto& [k, x] : params->obj) {
        if (x.type != Json::Type::Number || k.rfind(prefix, 0) != 0) continue;
        const int p = padParamIndex(k.substr(prefix.size()));
        if (p >= 0) v[static_cast<uint32_t>(p)] = x.num;
    }
    return v;
}
// A pad's hit (Single mode, full velocity) as the randomizer left it: mono.
std::vector<float> hitOf(const Voice& v, uint32_t frames) {
    Values vals = {{"mode", kModeSingle}};
    for (uint32_t k = 0; k < kPadParams; ++k) vals.emplace_back("a1_" + std::string(padParamSuffix(k)), v[k]);
    return mono(render(vals, {notes::noteOn(0, 1, 60, 1.0)}, frames));
}
}  // namespace

TEST(rook_randomize_keeps_each_pad_clearly_its_type) {
    // The owner: "Randomize must keep each pad clearly its type: no endless sustain, no plain distortion." From a
    // pad pushed to the worst (every decay at its longest, holds, gated, hard drive and clipper), each type's
    // Randomize at full Randomness ends within its length, and its drive, clipper and compressor take at most 3 dB of
    // its crest (peak over RMS).
    Values worst;
    for (int type = 0; type < kTypeCount; ++type)
        for (uint32_t seed = 1; seed <= 6; ++seed) {
            Voice start = defaultVoice(0);
            for (uint32_t k : {kBodyDecay, kSubDecay, kNoiseDecay, kMetalDecay, kFmDecay, kTexDecay, kResDecay, kPhysDecay})
                start[k] = padParamDescriptor(0, k).maximum;
            start[kBodyHold] = start[kSubHold] = 2.0;
            start[kBodyDCurve] = start[kNoiseDCurve] = start[kMetalDCurve] = -1.0;
            start[kTrig] = kGate;
            start[kDriveType] = kDriveHard;
            start[kDrive] = 20;
            start[kClip] = kClipHard;
            start[kClipGain] = 24;
            start[kType] = type;
            std::string cur = "{\"params\":{";
            for (uint32_t k = 0; k < kPadParams; ++k) cur += (k ? ",\"" : "\"") + std::string(padParamSuffix(k)) + "\":" + std::to_string(start[k]);
            cur += "}}";
            const Voice v = voiceOf(drumsRandomizeJson(type, seed, 1.0, 0, cur), 0);
            CHECK(static_cast<int>(v[kType]) == type);
            const std::vector<float> x = hitOf(v, static_cast<uint32_t>(5.0 * kSr));
            const float peak = peakOf(x);
            if (!(peak > 1e-3f)) {
                cawtest::fail(__FILE__, __LINE__, "a randomized " + std::string(typeName(type)) + " is silent");
                continue;
            }
            // Its last second, against its peak: an endless sustain stays loud.
            const double tail = dbOf(peakOf(x, x.size() - static_cast<size_t>(kSr))) - dbOf(peak);
            // Crest over its first 200 ms against the same sound with its drive, clipper and compressor off: a plain
            // distortion squares the wave (a sine's crest is 3 dB, a square's 0), so its crest falls.
            auto crestOf = [](const std::vector<float>& y) {
                double e = 0.0;
                const size_t n = static_cast<size_t>(0.2 * kSr);
                for (size_t i = 0; i < n; ++i) e += static_cast<double>(y[i]) * y[i];
                return dbOf(peakOf(y, 0, n)) - 10.0 * std::log10(e / n + 1e-20);
            };
            Voice clean = v;
            clean[kDriveType] = kDriveOff, clean[kClip] = kClipOff, clean[kComp] = 0;
            const double crest = crestOf(x), cleanCrest = crestOf(hitOf(clean, static_cast<uint32_t>(0.3 * kSr)));
            if (tail > -40.0 && type != kTypeBass) {
                char msg[160];
                std::snprintf(msg, sizeof msg, "a randomized %s still sounds %.0f dB under its peak after 4 s (seed %u)",
                              std::string(typeName(type)).c_str(), tail, seed);
                cawtest::fail(__FILE__, __LINE__, msg);
            }
            if ((crest < cleanCrest - 3.0 && crest < 9.0) || crest < 2.0) {  // 9 dB and up: still a punchy hit
                char msg[160];
                std::snprintf(msg, sizeof msg, "a randomized %s is a plain distortion (crest %.1f dB, %.1f clean, seed %u)",
                              std::string(typeName(type)).c_str(), crest, cleanCrest, seed);
                cawtest::fail(__FILE__, __LINE__, msg);
            }
        }
}

TEST(rook_randomness_sets_how_far_randomize_moves_a_pad) {
    // The Randomness knob is Randomize's amount: a Synthesized pad moves further from its type's library sound, and
    // a Simulated pad's piece further from where it was, the higher it is.
    auto meanApart = [&](double amount) {
        double sum = 0.0;
        const Sound* base = findSound("Acoustic Snare");
        CHECK(base != nullptr);
        if (!base) return 0.0;
        const std::vector<float> ref = hitOf(base->voice, 24000);
        std::string cur = "{\"params\":{";
        for (uint32_t k = 0; k < kPadParams; ++k) cur += (k ? ",\"" : "\"") + std::string(padParamSuffix(k)) + "\":" + std::to_string(base->voice[k]);
        cur += "}}";
        for (uint32_t seed = 1; seed <= 8; ++seed)
            sum += apart(ref, hitOf(voiceOf(drumsRandomizeJson(-1, seed, amount, 0, cur), 0), 24000));
        return sum / 8.0;
    };
    const double low = meanApart(0.15), high = meanApart(0.9);
    std::printf("rook randomness: a snare moved %.3f at 0.15, %.3f at 0.9\n", low, high);
    CHECK(low > 0.01);
    CHECK(high > 1.5 * low);
    // A Simulated pad: its piece's settings come back, more moved at more Randomness.
    const Values kit = presetValues(kKindDefaults[2]);
    std::string cur = "{\"params\":{\"a1_engine\":1,\"a1_acou_piece\":1,\"a1_type\":1";
    for (const auto& [id, x] : kit)
        if (id.rfind("pc2_", 0) == 0) cur += ",\"" + id + "\":" + std::to_string(x);
    cur += "}}";
    auto moved = [&](double amount) {
        Json j;
        std::string why;
        double sum = 0.0;
        for (uint32_t seed = 1; seed <= 8; ++seed) {
            CHECK(parseJson(drumsRandomizeJson(-1, seed, amount, 0, cur), j, why));
            const Json* params = j.get("params");
            CHECK(params != nullptr && params->get("pc2_tune") != nullptr);
            if (const Json* tune = params ? params->get("pc2_tune") : nullptr) {
                double was = 0.0;
                for (const auto& [id, x] : kit)
                    if (id == "pc2_tune") was = x;
                sum += std::fabs(tune->num - was);
            }
        }
        return sum / 8.0;
    };
    const double a = moved(0.15), b = moved(0.9);
    std::printf("rook randomness: the snare piece's tuning moved %.2f st at 0.15, %.2f at 0.9\n", a, b);
    CHECK(b > 2.0 * a);
}

// ---------- Glitches and noise timing ----------

namespace {
// The scan: sounds starting away from every hit (a 2 ms frame 9 dB over the loudest of the 30 ms before it, above
// -60 dBFS, not within 0..40 ms of a hit: a recorded pedal or a flam's stroke follows its hit) and clicks (outside the
// hits' first 40 ms, a sample whose second difference is over 6 times the RMS of the 10 ms around it, itself left
// out). Returns the frames of each.
struct Scan {
    std::vector<size_t> stray, clicks;
};
Scan scan(const std::vector<float>& x, const std::vector<Hit>& hits) {
    Scan out;
    auto nearHit = [&](size_t frame, double before, double after) {
        for (const Hit& h : hits)
            if (frame + static_cast<size_t>(before * kSr) >= h.frame && frame <= h.frame + static_cast<size_t>(after * kSr)) return true;
        return false;
    };
    const size_t f = static_cast<size_t>(0.002 * kSr);
    std::vector<double> rms;
    for (size_t at = 0; at + f <= x.size(); at += f) {
        double e = 0.0;
        for (size_t i = at; i < at + f; ++i) e += static_cast<double>(x[i]) * x[i];
        rms.push_back(std::sqrt(e / f));
    }
    for (size_t k = 15; k < rms.size(); ++k) {
        double before = 0.0;
        for (size_t j = k - 15; j < k; ++j) before = std::max(before, rms[j]);
        if (rms[k] > 1e-3 && dbOf(rms[k]) - dbOf(before) > 9.0 && !nearHit(k * f, 0.002, 0.04)) out.stray.push_back(k * f);
    }
    const size_t w = static_cast<size_t>(0.005 * kSr);
    std::vector<double> d2(x.size(), 0.0);
    for (size_t i = 2; i < x.size(); ++i) d2[i] = std::fabs(static_cast<double>(x[i]) - 2.0 * x[i - 1] + x[i - 2]);
    for (size_t i = w; i + w < x.size(); ++i) {
        if (d2[i] < 1e-4 || nearHit(i, 0.001, 0.04)) continue;
        double e = 0.0;
        for (size_t j = i - w; j < i + w; ++j)
            if (j + 3 < i || j > i + 3) e += d2[j] * d2[j];
        const double local = std::sqrt(e / (2 * w - 7));
        if (d2[i] > 6.0 * local) {
            out.clicks.push_back(i);
            i += w;
        }
    }
    return out;
}
}  // namespace

TEST(rook_kits_have_no_clicks_and_no_noise_off_their_hits) {
    // Each kind's default kit (and the Studio kit at Eco and High) plays the bar; the scan (above) finds no sound away
    // from its hits and no click. The scan itself is checked first: a click and a burst put into a render are found.
    struct Run {
        const char* name;
        int quality;
    };
    const Run runs[] = {{kKindDefaults[0], kQualityNormal}, {kKindDefaults[1], kQualityNormal}, {kKindDefaults[2], kQualityNormal},
                        {kKindDefaults[2], kQualityEco}, {kKindDefaults[2], kQualityHigh}};
    const std::vector<Hit> hits = groove();
    bool checkedScan = false;
    for (const Run& run : runs) {
        const std::vector<float> x = mono(render(presetValues(run.name), eventsOf(hits), kGrooveFrames, 64, run.quality));
        const Scan found = scan(x, hits);
        for (size_t i = 0; i < found.stray.size() && i < 5; ++i) {
            char msg[160];
            std::snprintf(msg, sizeof msg, "%s (quality %d): a sound starts at %.3f s, away from every hit", run.name, run.quality,
                          found.stray[i] / kSr);
            cawtest::fail(__FILE__, __LINE__, msg);
        }
        for (size_t i = 0; i < found.clicks.size() && i < 5; ++i) {
            char msg[160];
            std::snprintf(msg, sizeof msg, "%s (quality %d): a click at %.4f s", run.name, run.quality, found.clicks[i] / kSr);
            cawtest::fail(__FILE__, __LINE__, msg);
        }
        std::printf("rook scan: %s (quality %d): %zu stray sounds, %zu clicks, peak %.1f dBFS\n", run.name, run.quality,
                    found.stray.size(), found.clicks.size(), dbOf(peakOf(x)));
        if (!checkedScan && run.name == kKindDefaults[2]) {  // the scan finds what it looks for: a 1-sample click, a 10 ms burst
            checkedScan = true;
            std::vector<float> y = x;
            const size_t click = 24000 + 7000, burst = 48000 + 9000;
            y[click] += 0.15f;
            uint32_t r = 1;
            for (size_t i = burst; i < burst + 480; ++i) r = r * 1664525u + 1013904223u, y[i] += 0.5f * ((r >> 9) / 4194304.0f - 1.0f);
            const Scan planted = scan(y, hits);
            bool clickFound = false;
            for (size_t at : planted.clicks) clickFound = clickFound || (at + 3 >= click && at <= click + 3);
            CHECK(clickFound);
            bool burstFound = false;
            for (size_t at : planted.stray) burstFound = burstFound || (at + 960 >= burst && at <= burst + 960);
            CHECK(burstFound);
        }
    }
}
