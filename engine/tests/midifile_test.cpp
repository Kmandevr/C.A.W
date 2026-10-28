// MIDI file tests: pattern round trips through .mid and MIDI 2.0 clips, hand-built files, and malformed input.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "caw.h"
#include "capi_internal.h"
#include "midifile.h"
#include "pattern.h"
#include "test.h"

using namespace caw;

namespace {

using Bytes = std::vector<uint8_t>;

std::string templateSource(const char* file) {
    for (int i = 0; i < kTemplateCount; ++i)
        if (std::strcmp(kTemplateFiles[i], file) == 0) return kTemplateSources[i];
    return "";
}

// A note as it sounds: ratchets expanded, probability ignored.
struct Heard {
    double at, len, pitch, vel;
    bool slide;
};

std::vector<Heard> heard(const Pattern& p) {
    std::vector<Heard> out;
    for (const PatternNote& n : p.notes) {
        const double part = n.len / n.ratchet;
        for (int q = 0; q < n.ratchet; ++q)
            out.push_back({n.at + part * q, part, n.pitch, n.vel, q == n.ratchet - 1 && n.slideTo >= 0});
    }
    std::stable_sort(out.begin(), out.end(), [](const Heard& a, const Heard& b) {
        return a.at != b.at ? a.at < b.at : a.pitch < b.pitch;
    });
    return out;
}

std::shared_ptr<const Pattern> parse(const std::string& text) {
    PatternResult r = parsePattern(text);
    if (!r.pattern) std::printf("pattern error: %s\n%s\n", r.error.c_str(), text.c_str());
    return r.pattern;
}

std::string import(const Bytes& b, std::string& err, MidiImportOptions o = {}) {
    return patternFromMidi(b.data(), b.size(), o, err);
}

void checkSameNotes(const Pattern& a, const Pattern& b) {
    const std::vector<Heard> x = heard(a), y = heard(b);
    CHECK_EQ(x.size(), y.size());
    for (size_t i = 0; i < x.size() && i < y.size(); ++i) {
        CHECK_NEAR(x[i].at, y[i].at, 1e-9);
        CHECK_NEAR(x[i].len, y[i].len, 1e-9);
        CHECK_NEAR(x[i].pitch, y[i].pitch, 1e-3);
        CHECK_NEAR(x[i].vel, y[i].vel, 0.5 / 127 + 1e-3);
        CHECK_EQ(x[i].slide, y[i].slide);
    }
}

// Standard MIDI File building blocks.
void vlq(Bytes& o, uint32_t v) {
    uint8_t buf[5];
    int n = 0;
    buf[n++] = v & 0x7F;
    while (v >>= 7) buf[n++] = static_cast<uint8_t>(0x80 | (v & 0x7F));
    while (n) o.push_back(buf[--n]);
}
void be(Bytes& o, uint32_t v, int bytes) {
    for (int k = bytes - 1; k >= 0; --k) o.push_back(static_cast<uint8_t>(v >> (8 * k)));
}
Bytes header(int format, int tracks, int ppq) {
    Bytes o = {'M', 'T', 'h', 'd', 0, 0, 0, 6};
    be(o, format, 2);
    be(o, tracks, 2);
    be(o, ppq, 2);
    return o;
}
void track(Bytes& o, const Bytes& body) {
    o.insert(o.end(), {'M', 'T', 'r', 'k'});
    be(o, static_cast<uint32_t>(body.size()), 4);
    o.insert(o.end(), body.begin(), body.end());
}

bool has(const std::string& s, const char* part) { return s.find(part) != std::string::npos; }

std::vector<uint32_t> words(const Bytes& b, size_t from) {
    std::vector<uint32_t> w;
    for (size_t i = from; i + 4 <= b.size(); i += 4)
        w.push_back((uint32_t(b[i]) << 24) | (uint32_t(b[i + 1]) << 16) | (uint32_t(b[i + 2]) << 8) | b[i + 3]);
    return w;
}

}  // namespace

TEST(midi_round_trip_keeps_the_example_patterns) {
    for (const char* file : {"acid-line.caw", "chords.caw"}) {
        const std::string src = templateSource(file);
        CHECK(!src.empty());
        auto p = parse(src);
        CHECK(p != nullptr);
        if (!p) continue;
        for (int clip = 0; clip < 2; ++clip) {
            const Bytes b = clip ? patternToMidiClip(*p, 120, 4) : patternToSmf(*p, 120, 4);
            std::string err;
            const std::string text = import(b, err);
            CHECK_EQ(err, std::string());
            auto q = parse(text);
            CHECK(q != nullptr);
            if (!q) continue;
            checkSameNotes(*p, *q);
            CHECK_EQ(q->name, p->name);
            CHECK_EQ(q->steps(4), p->steps(4));
        }
    }
}

TEST(midi_import_merges_chords_and_writes_fractions) {
    const std::string src = "---\nkind: pattern\nname: T\n---\n0 C3,E3,G3 4 0.8\n4 C3 1/3 1\n13/3 D3 1/3 1 slide\n14/3 E3 1/3 1\n";
    auto p = parse(src);
    CHECK(p != nullptr);
    std::string err;
    const std::string text = import(patternToSmf(*p, 120, 4), err);
    CHECK_EQ(err, std::string());
    CHECK(has(text, "C3,E3,G3"));
    CHECK(has(text, "13/3"));
    CHECK(has(text, "slide"));
    CHECK(has(text, "length: 16"));
    auto q = parse(text);
    CHECK(q != nullptr);
    if (q) checkSameNotes(*p, *q);
}

TEST(midi_microtones_round_trip_through_pitch_bend_and_pitch_7_9) {
    auto p = parse("---\nkind: pattern\n---\n0 60.5 4 1\n0 64 4 1\n4 61.25 4 1\n");
    CHECK(p != nullptr);
    if (!p) return;
    const Bytes smf = patternToSmf(*p, 120, 4);
    // The microtonal note plays on its own channel (2) after a pitch bend of -1/2 semitone (8192 - 2048 = 6144).
    const uint8_t bend[] = {0xE1, 6144 & 0x7F, 6144 >> 7};
    CHECK(std::search(smf.begin(), smf.end(), bend, bend + 3) != smf.end());
    const Bytes clip = patternToMidiClip(*p, 120, 4);
    const std::vector<uint32_t> w = words(clip, 8);
    // 60.5 is note index 61 (nearest) with attribute #3 = 60.5 * 512 = 0x7900.
    CHECK(std::find(w.begin(), w.end(), 0x40903D03u) != w.end());
    CHECK(std::find(w.begin(), w.end(), 0xFFFF7900u) != w.end());
    for (const Bytes& b : {smf, clip}) {
        std::string err;
        auto q = parse(import(b, err));
        CHECK_EQ(err, std::string());
        if (q) checkSameNotes(*p, *q);
    }
}

TEST(midi_clip_export_has_the_header_and_ump_words) {
    auto p = parse("---\nkind: pattern\nname: One\nlength: 16\n---\n4 C4 2 1\n");
    CHECK(p != nullptr);
    if (!p) return;
    const Bytes b = patternToMidiClip(*p, 120, 4);
    CHECK(b.size() > 8 && std::memcmp(b.data(), "SMF2CLIP", 8) == 0);
    CHECK_EQ((b.size() - 8) % 4, size_t(0));
    const std::vector<uint32_t> w = words(b, 8);
    const std::vector<uint32_t> expect = {
        0x00400000u, 0x003003C0u,                    // DCS 0, DCTPQ 960
        0x00400000u, 0xF0200000u, 0, 0, 0,           // DCS 0, Start of Clip
        0xD0100000u, 50000000u, 0, 0,                // Set Tempo: 120 BPM = 0.5 s in 10 ns units
        0xD0100001u, 0x04020800u, 0, 0,              // Set Time Signature 4/4, 8 32nds per quarter
        0xD0100103u, 0x4F6E6500u, 0, 0,              // MIDI Clip Name "One"
        0x00400000u | 960, 0x40903C00u, 0xFFFF0000u,  // one beat later: Note On C4 (60), velocity 0xFFFF
        0x00400000u | 480, 0x40803C00u, 0x80000000u,  // two steps later: Note Off
        0x00400000u | 2400, 0xF0210000u, 0, 0, 0,    // the rest of the bar, End of Clip
    };
    CHECK_EQ(w.size(), expect.size());
    for (size_t i = 0; i < w.size() && i < expect.size(); ++i)
        if (w[i] != expect[i]) {
            std::printf("word %zu: %08x, expected %08x\n", i, w[i], expect[i]);
            CHECK(w[i] == expect[i]);
        }
}

TEST(midi_smf_export_has_tempo_meter_and_name) {
    auto p = parse("---\nkind: pattern\nname: Bass\n---\n0 A1 2 1 ratchet 2\n");
    CHECK(p != nullptr);
    if (!p) return;
    const Bytes b = patternToSmf(*p, 140, 3);
    CHECK(std::memcmp(b.data(), "MThd\0\0\0\6\0\1\0\2\x03\xC0", 14) == 0);
    const uint32_t us = 428571;  // 60e6 / 140
    const uint8_t tempo[] = {0xFF, 0x51, 0x03, uint8_t(us >> 16), uint8_t(us >> 8), uint8_t(us)};
    const uint8_t meter[] = {0xFF, 0x58, 0x04, 3, 2, 24, 8};
    const uint8_t name[] = {0xFF, 0x03, 0x04, 'B', 'a', 's', 's'};
    CHECK(std::search(b.begin(), b.end(), tempo, tempo + 6) != b.end());
    CHECK(std::search(b.begin(), b.end(), meter, meter + 7) != b.end());
    CHECK(std::search(b.begin(), b.end(), name, name + 7) != b.end());
    std::string err;
    const std::string text = import(b, err);
    CHECK_EQ(err, std::string());
    CHECK(has(text, "name: Bass"));
    CHECK(has(text, "length: 12"));  // one bar of 3/4
    auto q = parse(text);
    CHECK(q != nullptr);
    if (q) CHECK_EQ(q->notes.size(), size_t(2));  // the ratchet comes back as two notes
}

TEST(midi_import_reads_hand_built_format_1_with_running_status) {
    // Track 1: tempo, 3/4, then a tempo change mid-way (which must not move notes: steps come from ticks).
    Bytes t1 = {0x00, 0xFF, 0x51, 0x03, 0x07, 0xA1, 0x20, 0x00, 0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08};
    vlq(t1, 192);
    t1.insert(t1.end(), {0xFF, 0x51, 0x03, 0x03, 0xD0, 0x90});
    t1.insert(t1.end(), {0x00, 0xFF, 0x2F, 0x00});
    // Track 2 (96 ticks per quarter, so a step is 24 ticks): name, then notes with running status and note-on
    // velocity 0 as note off, a sysex in between, and a controller.
    Bytes t2 = {0x00, 0xFF, 0x03, 0x04, 'L', 'e', 'a', 'd'};
    t2.insert(t2.end(), {0x00, 0x90, 60, 127});   // C4 on at 0
    t2.insert(t2.end(), {0x00, 64, 64});          // E4 on (running status)
    vlq(t2, 48);
    t2.insert(t2.end(), {60, 0});                 // C4 off at 2 steps
    t2.insert(t2.end(), {0x00, 64, 0});           // E4 off
    t2.insert(t2.end(), {0x00, 0xF0, 0x03, 0x7E, 0x00, 0xF7});
    t2.insert(t2.end(), {0x00, 0xB0, 7, 100});
    vlq(t2, 8);                                   // 56 ticks = 7/3 steps
    t2.insert(t2.end(), {0x80 | 0, 62, 0});       // stray note off (no note): ignored
    t2.insert(t2.end(), {0x00, 0x91, 62, 100});   // D4 on, channel 2
    vlq(t2, 200);
    t2.insert(t2.end(), {0x81, 62, 0});
    t2.insert(t2.end(), {0x00, 0xFF, 0x2F, 0x00});
    Bytes f = header(1, 2, 96);
    track(f, t1);
    track(f, t2);
    std::string err;
    const std::string text = import(f, err);
    CHECK_EQ(err, std::string());
    CHECK(has(text, "name: Lead"));
    CHECK(has(text, "length: 12"));
    auto q = parse(text);
    CHECK(q != nullptr);
    if (!q) return;
    CHECK_EQ(q->notes.size(), size_t(3));
    if (q->notes.size() == 3) {
        CHECK_EQ(q->notes[0].pitch, 60.0);
        CHECK_EQ(q->notes[1].pitch, 64.0);
        CHECK_NEAR(q->notes[1].vel, 0.504, 1e-9);
        CHECK_NEAR(q->notes[0].len, 2, 1e-9);
        CHECK_NEAR(q->notes[2].at, 7.0 / 3.0, 1e-9);
        CHECK_NEAR(q->notes[2].len, 200.0 / 24.0, 1e-9);
    }
    CHECK(has(text, "C4,E4") == false);  // different velocities stay on separate lines
    // Filters: only channel 2, or only the first track (which has no notes).
    MidiImportOptions o;
    o.channel = 1;
    auto r = parse(import(f, err, o));
    CHECK(r != nullptr);
    if (r) CHECK_EQ(r->notes.size(), size_t(1));
    o = {};
    o.track = 0;
    CHECK(import(f, err, o).empty());
    CHECK(has(err, "no notes"));
    o.track = 5;
    CHECK(import(f, err, o).empty());
    // Format 0 with the same notes reads the same.
    Bytes f0 = header(0, 1, 96);
    track(f0, t2);
    auto s = parse(import(f0, err));
    CHECK(s != nullptr);
    if (s) CHECK_EQ(s->notes.size(), size_t(3));
}

TEST(midi_import_rejects_malformed_files_without_crashing) {
    std::string err;
    auto fails = [&](const Bytes& b, const char* part) {
        const std::string text = import(b, err);
        CHECK(text.empty());
        if (!has(err, part)) std::printf("error was: %s (wanted %s)\n", err.c_str(), part);
        CHECK(has(err, part));
    };
    fails({}, "empty");
    fails({'R', 'I', 'F', 'F', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0}, "not a MIDI file");
    fails(header(2, 1, 96), "formats 0 and 1");
    fails(header(1, 1, 0xE728), "SMPTE");
    fails(header(1, 0, 96), "no tracks");
    Bytes huge = header(0, 1, 96);
    huge.insert(huge.end(), {'M', 'T', 'r', 'k', 0x7F, 0xFF, 0xFF, 0xFF, 0x00, 0x90, 60, 100});
    fails(huge, "truncated");
    Bytes meta = header(0, 1, 96);
    track(meta, {0x00, 0xFF, 0x03, 0x8F, 0xFF, 0xFF, 0x7F, 'x'});
    fails(meta, "longer than its track");
    Bytes vl = header(0, 1, 96);
    track(vl, {0xFF, 0xFF, 0xFF, 0xFF, 0x7F, 0x90, 60, 100});
    fails(vl, "longer than 4 bytes");
    Bytes nostatus = header(0, 1, 96);
    track(nostatus, {0x00, 60, 100});
    fails(nostatus, "without a status");
    Bytes clip = {'S', 'M', 'F', '2', 'C', 'L', 'I', 'P', 0x40, 0x90};
    fails(clip, "middle of a message");
    // A note past 4096 steps, and more notes than allowed.
    Bytes longf = header(0, 1, 4);
    Bytes body = {0x00, 0x90, 60, 100};
    vlq(body, 5000);
    body.insert(body.end(), {0x80, 60, 0, 0x00, 0xFF, 0x2F, 0x00});
    track(longf, body);
    fails(longf, "4096 steps");
    Bytes many = header(0, 1, 96);
    Bytes mb;
    for (int i = 0; i < 20; ++i) mb.insert(mb.end(), {0x00, 0x90, uint8_t(40 + i), 100});
    track(many, mb);
    MidiImportOptions o;
    o.maxNotes = 10;
    CHECK(import(many, err, o).empty());
    CHECK(has(err, "more than 10 notes"));

    // Every truncation of a good file, and seeded random corruption, gives a pattern or an error, never a crash.
    auto p = parse(templateSource("acid-line.caw"));
    CHECK(p != nullptr);
    if (!p) return;
    for (const Bytes& good : {patternToSmf(*p, 120, 4), patternToMidiClip(*p, 120, 4)}) {
        for (size_t n = 0; n < good.size(); ++n) {
            Bytes cut(good.begin(), good.begin() + n);
            const std::string text = import(cut, err);
            CHECK(!text.empty() || !err.empty());
        }
        uint32_t seed = 12345;
        for (int round = 0; round < 2000; ++round) {
            Bytes bad = good;
            for (int k = 0; k < 4; ++k) {
                seed = seed * 1664525u + 1013904223u;
                bad[8 + (seed >> 8) % (bad.size() - 8)] = static_cast<uint8_t>(seed >> 24);
            }
            const std::string text = import(bad, err);
            CHECK(!text.empty() || !err.empty());
            if (!text.empty()) CHECK(parsePattern(text).pattern != nullptr);
        }
    }
}

TEST(midi_c_api_imports_and_exports) {
    auto p = parse(templateSource("chords.caw"));
    CHECK(p != nullptr);
    if (!p) return;
    const Bytes b = patternToSmf(*p, 120, 4);
    char* json = caw_pattern_from_midi(b.data(), static_cast<int32_t>(b.size()));
    CHECK(json != nullptr);
    if (json) {
        CHECK(has(json, "\"ok\":true"));
        CHECK(has(json, "kind: pattern"));
        caw_free(json);
    }
    json = caw_pattern_from_midi(b.data(), 10);
    CHECK(json && has(json, "\"ok\":false"));
    caw_free(json);

    const std::string path = (std::filesystem::temp_directory_path() / "caw_midi_test.midi2").string();
    char error[256] = {};
    const std::string src = templateSource("chords.caw");
    CHECK_EQ(caw_pattern_export(src.c_str(), 120, 4, CAW_MIDI_CLIP, path.c_str(), error, sizeof error), 0);
    std::ifstream f(path, std::ios::binary);
    std::string head(8, '\0');
    f.read(head.data(), 8);
    CHECK_EQ(head, std::string("SMF2CLIP"));
    f.close();
    std::remove(path.c_str());
    CHECK_EQ(caw_pattern_export("not a pattern", 120, 4, CAW_MIDI_SMF, path.c_str(), error, sizeof error), 1);
    CHECK(has(error, "kind: pattern"));
    CHECK_EQ(caw_pattern_export(src.c_str(), 1000, 4, CAW_MIDI_SMF, path.c_str(), error, sizeof error), 1);
}
