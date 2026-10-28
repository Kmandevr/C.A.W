// MIDI file import and export for note patterns: Standard MIDI Files (format 0/1) and MIDI 2.0 Clip Files (UMP).
#include "midifile.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <numeric>

namespace caw {

namespace {

// ---------------------------------------------------------------------------------------------------------------
// Import: both file kinds collect notes in ticks, then one writer turns them into pattern text.

struct RawNote {
    int64_t on = 0, off = -1;
    double pitch = 60;
    double vel = 1;
    int track = 0;
    bool slide = false;
};

struct Collected {
    std::vector<RawNote> notes;
    int64_t ppq = 0;
    int tsNum = 4, tsDenPow = 2;  // 4/4
    int64_t tsTick = -1;          // where the first time signature was found (-1 = none)
    std::string name;
};

struct Fail {
    std::string msg;
};

void noteTimeSignature(Collected& c, int64_t tick, int num, int denPow) {
    if (num < 1 || denPow < 0 || denPow > 6) return;  // 1/1 .. n/64; anything else is ignored
    if (c.tsTick >= 0 && c.tsTick <= tick) return;
    c.tsTick = tick;
    c.tsNum = num;
    c.tsDenPow = denPow;
}

void addNote(Collected& c, const MidiImportOptions& o, RawNote n) {
    if (static_cast<int>(c.notes.size()) >= o.maxNotes)
        throw Fail{"the file has more than " + std::to_string(o.maxNotes) + " notes, the most a pattern holds"};
    c.notes.push_back(n);
}

// Bounds-checked big-endian reads.
struct Bytes {
    const uint8_t* p;
    size_t n;
    size_t i = 0;
    uint8_t u8() {
        if (i >= n) throw Fail{"the file ends in the middle of an event"};
        return p[i++];
    }
    uint32_t be(int bytes) {
        uint32_t v = 0;
        for (int k = 0; k < bytes; ++k) v = (v << 8) | u8();
        return v;
    }
    uint32_t vlq() {
        uint32_t v = 0;
        for (int k = 0; k < 4; ++k) {
            const uint8_t b = u8();
            v = (v << 7) | (b & 0x7F);
            if (!(b & 0x80)) return v;
        }
        throw Fail{"a variable-length number is longer than 4 bytes"};
    }
};

std::string cleanName(const std::string& s) {
    std::string out;
    for (unsigned char ch : s)
        if (ch >= 0x20 && ch != 0x7F && ch != '#') out += static_cast<char>(ch);
    size_t a = 0, b = out.size();
    while (a < b && out[a] == ' ') ++a;
    while (b > a && out[b - 1] == ' ') --b;
    out = out.substr(a, b - a);
    if (out.size() > 64) {
        size_t cut = 64;
        while (cut > 0 && (static_cast<unsigned char>(out[cut]) & 0xC0) == 0x80) --cut;  // keep UTF-8 whole
        out.resize(cut);
    }
    return out;
}

void readSmf(const uint8_t* data, size_t size, const MidiImportOptions& o, Collected& c) {
    Bytes r{data, size};
    if (size < 14 || std::memcmp(data, "MThd", 4) != 0) throw Fail{"not a MIDI file (no MThd header)"};
    r.i = 4;
    const uint32_t hlen = r.be(4);
    if (hlen < 6 || hlen > size - 8) throw Fail{"the MIDI header chunk has a bad length"};
    const int format = static_cast<int>(r.be(2));
    const int ntracks = static_cast<int>(r.be(2));
    const uint32_t division = r.be(2);
    if (format > 1) throw Fail{"only MIDI file formats 0 and 1 can be imported (this is format " + std::to_string(format) + ")"};
    if (division & 0x8000) throw Fail{"MIDI files timed in SMPTE frames can't be imported, only ticks per quarter note"};
    if (division == 0) throw Fail{"the MIDI file has 0 ticks per quarter note"};
    c.ppq = division;
    r.i = 8 + hlen;

    int events = 0, track = -1;
    std::string firstName, noteTrackName;
    while (r.i + 8 <= size) {
        const bool isTrack = std::memcmp(data + r.i, "MTrk", 4) == 0;
        r.i += 4;
        const uint32_t len = r.be(4);
        if (len > size - r.i) throw Fail{"a track chunk is longer than the file (the file is truncated)"};
        const size_t end = r.i + len;
        if (!isTrack) {  // unknown chunks are skipped, as the format asks
            r.i = end;
            continue;
        }
        ++track;
        const bool wanted = o.track < 0 || o.track == track;
        Bytes t{data, end, r.i};
        int64_t tick = 0;
        uint8_t status = 0;
        int bend[16];
        std::fill(bend, bend + 16, 8192);
        std::map<int, std::vector<size_t>> open;  // channel * 128 + key -> notes still sounding, oldest first
        std::string name;
        bool hasNotes = false;
        while (t.i < end) {
            tick += t.vlq();
            if (++events > kMaxMidiEvents)
                throw Fail{"the file has more than " + std::to_string(kMaxMidiEvents) + " events"};
            if (t.i >= end) throw Fail{"track " + std::to_string(track + 1) + " ends after a delta time, with no event"};
            const uint8_t b = data[t.i];
            if (b == 0xFF) {
                ++t.i;
                const uint8_t type = t.u8();
                const uint32_t mlen = t.vlq();
                if (mlen > end - t.i) throw Fail{"a meta event is longer than its track"};
                const uint8_t* m = data + t.i;
                if (type == 0x03 && name.empty()) name.assign(reinterpret_cast<const char*>(m), mlen);
                if (type == 0x58 && mlen >= 2) noteTimeSignature(c, tick, m[0], m[1]);
                t.i += mlen;
                status = 0;
                if (type == 0x2F) break;
            } else if (b == 0xF0 || b == 0xF7) {
                ++t.i;
                const uint32_t slen = t.vlq();
                if (slen > end - t.i) throw Fail{"a system exclusive event is longer than its track"};
                t.i += slen;
                status = 0;
            } else if (b >= 0xF0) {
                throw Fail{"unexpected status byte in track " + std::to_string(track + 1)};
            } else {
                if (b & 0x80) {
                    status = b;
                    ++t.i;
                } else if (!status) {
                    throw Fail{"a data byte without a status byte in track " + std::to_string(track + 1)};
                }
                const int kind = status >> 4, ch = status & 15;
                const uint8_t d1 = t.u8();
                const uint8_t d2 = (kind == 0xC || kind == 0xD) ? 0 : t.u8();
                if ((d1 | d2) & 0x80) throw Fail{"a data byte above 127 in track " + std::to_string(track + 1)};
                if (!wanted || (o.channel >= 0 && o.channel != ch)) continue;
                if (kind == 0xE) bend[ch] = (d2 << 7) | d1;
                if (kind == 0x9 && d2 > 0) {
                    RawNote n;
                    n.on = tick;
                    n.pitch = d1 + (o.pitchBend ? (bend[ch] - 8192) / 4096.0 : 0.0);
                    n.vel = d2 / 127.0;
                    n.track = track;
                    open[ch * 128 + d1].push_back(c.notes.size());
                    addNote(c, o, n);
                    hasNotes = true;
                } else if (kind == 0x8 || kind == 0x9) {
                    auto it = open.find(ch * 128 + d1);
                    if (it != open.end() && !it->second.empty()) {
                        c.notes[it->second.front()].off = tick;
                        it->second.erase(it->second.begin());
                    }
                }
            }
        }
        for (auto& [key, list] : open)
            for (size_t k : list) c.notes[k].off = tick;  // notes never released end with their track
        if (firstName.empty()) firstName = name;
        if (hasNotes && noteTrackName.empty()) noteTrackName = name;
        r.i = end;
    }
    if (track < 0) throw Fail{"the MIDI file has no tracks"};
    if (o.track > track) throw Fail{"the file has " + std::to_string(track + 1) + " tracks, there is no track " + std::to_string(o.track)};
    (void)ntracks;
    c.name = cleanName(noteTrackName.empty() ? firstName : noteTrackName);
}

// A MIDI 2.0 Clip File: "SMF2CLIP", then UMPs (big endian), each timed by the latest Delta Clockstamp.
void readClip(const uint8_t* data, size_t size, const MidiImportOptions& o, Collected& c) {
    static const int kWords[16] = {1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4};  // UMP size by message type
    if ((size - 8) % 4) throw Fail{"the clip file ends in the middle of a message"};
    const size_t nw = (size - 8) / 4;
    auto word = [&](size_t k) {
        const uint8_t* p = data + 8 + k * 4;
        return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) | (uint32_t(p[2]) << 8) | p[3];
    };
    int64_t tick = 0;
    int events = 0;
    std::map<int, std::vector<size_t>> open;  // (group * 16 + channel) * 128 + note index
    std::string name;
    bool ended = false;
    for (size_t k = 0; k < nw && !ended;) {
        const uint32_t w0 = word(k);
        const int mt = static_cast<int>(w0 >> 28);
        const size_t len = kWords[mt];
        if (k + len > nw) throw Fail{"the clip file ends in the middle of a message"};
        const uint32_t w1 = len > 1 ? word(k + 1) : 0;
        if (++events > kMaxMidiEvents) throw Fail{"the file has more than " + std::to_string(kMaxMidiEvents) + " messages"};
        if (mt == 0x0) {
            const int st = (w0 >> 20) & 0xF;
            if (st == 0x3) c.ppq = w0 & 0xFFFF;
            if (st == 0x4) tick += w0 & 0xFFFFF;
        } else if (mt == 0x2 || mt == 0x4) {
            const int kind = (w0 >> 20) & 0xF, ch = (w0 >> 16) & 0xF, group = (w0 >> 24) & 0xF;
            const int key = (w0 >> 8) & 0x7F;
            if ((kind == 0x8 || kind == 0x9) && (o.channel < 0 || o.channel == ch)) {
                if (c.ppq <= 0) throw Fail{"the clip has notes before its ticks-per-quarter (DCTPQ) message"};
                double vel = 0;
                double pitch = key;
                if (mt == 0x2) {
                    vel = (w0 & 0x7F) / 127.0;
                } else {
                    vel = (w1 >> 16) / 65535.0;
                    if ((w0 & 0xFF) == 0x03) pitch = (w1 & 0xFFFF) / 512.0;  // attribute #3: Pitch 7.9
                }
                const int slot = (group * 16 + ch) * 128 + key;
                const bool on = kind == 0x9 && (mt == 0x4 || (w0 & 0x7F) > 0);
                if (on) {
                    RawNote n;
                    n.on = tick;
                    n.pitch = std::min(pitch, 127.0);
                    n.vel = vel;
                    open[slot].push_back(c.notes.size());
                    addNote(c, o, n);
                } else {
                    auto it = open.find(slot);
                    if (it != open.end() && !it->second.empty()) {
                        c.notes[it->second.front()].off = tick;
                        it->second.erase(it->second.begin());
                    }
                }
            }
        } else if (mt == 0xD) {
            const int form = (w0 >> 22) & 3, bank = (w0 >> 8) & 0xFF, st = w0 & 0xFF;
            if (bank == 0x00 && st == 0x01) noteTimeSignature(c, tick, static_cast<int>(w1 >> 24), static_cast<int>((w1 >> 16) & 0xFF));
            if (bank == 0x01 && st == 0x03) {  // MIDI Clip Name, 12 UTF-8 bytes per UMP
                if (form == 0 || form == 1) name.clear();
                for (size_t q = 1; q < 4; ++q) {
                    const uint32_t w = word(k + q);
                    for (int s = 24; s >= 0; s -= 8)
                        if ((w >> s) & 0xFF) name += static_cast<char>((w >> s) & 0xFF);
                }
            }
        } else if (mt == 0xF) {
            if (((w0 >> 16) & 0x3FF) == 0x21) ended = true;  // End of Clip
        }
        k += len;
    }
    for (auto& [slot, list] : open)
        for (size_t k : list) c.notes[k].off = tick;
    if (c.ppq <= 0) throw Fail{"the clip has no ticks-per-quarter (DCTPQ) message"};
    c.name = cleanName(name);
}

std::string trimNumber(char* buf) {
    std::string s = buf;
    if (s.find('.') != std::string::npos) {
        while (!s.empty() && s.back() == '0') s.pop_back();
        if (!s.empty() && s.back() == '.') s.pop_back();
    }
    if (s == "-0") s = "0";
    return s;
}

// Ticks as steps (16ths): whole numbers, small exact fractions (`13/3`), else decimals to 1/1000 step.
std::string stepsText(int64_t ticks, int64_t ppq) {
    int64_t num = ticks * 4, den = ppq;
    const int64_t g = std::gcd(num, den);
    num /= g;
    den /= g;
    if (den == 1) return std::to_string(num);
    if (den <= 64) return std::to_string(num) + "/" + std::to_string(den);
    char buf[48];
    std::snprintf(buf, sizeof buf, "%.3f", static_cast<double>(ticks) * 4.0 / static_cast<double>(ppq));
    std::string s = trimNumber(buf);
    return s == "0" && ticks > 0 ? "0.001" : s;
}

std::string velText(double v) {
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.3f", std::clamp(v, 0.0, 1.0));
    return trimNumber(buf);
}

std::string pitchText(double p) {
    p = std::clamp(std::round(p * 1000.0) / 1000.0, 0.0, 127.0);
    if (p == std::floor(p) && p >= 12) {
        static const char* const names[] = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"};
        const int n = static_cast<int>(p);
        return std::string(names[n % 12]) + std::to_string(n / 12 - 1);
    }
    char buf[32];
    std::snprintf(buf, sizeof buf, "%.3f", p);
    return trimNumber(buf);
}

std::string writePattern(Collected& c, const MidiImportOptions& o) {
    std::vector<RawNote>& v = c.notes;
    if (v.empty()) throw Fail{"the file has no notes" + std::string(o.track >= 0 || o.channel >= 0 ? " on that track or channel" : "")};
    for (RawNote& n : v)
        if (n.off < n.on) n.off = n.on;
    std::stable_sort(v.begin(), v.end(), [](const RawNote& a, const RawNote& b) {
        return a.on != b.on ? a.on < b.on : a.pitch < b.pitch;
    });
    // Legato overlaps (the usual way slides are stored in MIDI) become slides.
    if (o.legatoSlides) {
        const int64_t maxOverlap = std::max<int64_t>(1, c.ppq / 32);  // 1/8 step
        std::vector<char> used(v.size(), 0);
        for (size_t a = 0; a < v.size(); ++a) {
            for (size_t b = a + 1; b < v.size() && v[b].on < v[a].off; ++b) {
                if (used[b] || v[b].on <= v[a].on || v[b].track != v[a].track || v[b].pitch == v[a].pitch) continue;
                if (v[a].off - v[b].on > maxOverlap) continue;
                v[a].off = v[b].on;
                v[a].slide = true;
                used[b] = 1;
                break;
            }
        }
    }
    const int64_t limit = static_cast<int64_t>(kMaxPatternSteps) * c.ppq / 4;
    int64_t lastEnd = 0;
    for (const RawNote& n : v) lastEnd = std::max(lastEnd, n.off);
    if (lastEnd > limit) throw Fail{"the notes last longer than " + std::to_string(kMaxPatternSteps) + " steps, the most a pattern holds"};

    // Length: whole bars of the file's first time signature (4/4 without one), rounded up to a whole step.
    const double barSteps = c.tsNum * 16.0 / static_cast<double>(1 << c.tsDenPow);
    const double endSteps = static_cast<double>(lastEnd) * 4.0 / static_cast<double>(c.ppq);
    const double bars = std::max(1.0, std::ceil(endSteps / barSteps - 1e-9));
    const int length = static_cast<int>(std::min<double>(kMaxPatternSteps, std::ceil(bars * barSteps - 1e-9)));

    std::string name = o.name.empty() ? c.name : cleanName(o.name);
    if (name.empty()) name = "Imported MIDI";
    std::string out = "---\ncaw: 1\nkind: pattern\nname: " + name + "\nsummary: Imported from a MIDI file (" +
                      std::to_string(v.size()) + " notes, " + std::to_string(c.tsNum) + "/" +
                      std::to_string(1 << c.tsDenPow) + ")\nlength: " + std::to_string(length) + "\n---\n" +
                      "// at  note(s)  len  vel  extras\n";
    // One line per start, length, velocity and slide; notes that share all four make a chord.
    std::vector<char> done(v.size(), 0);
    for (size_t a = 0; a < v.size(); ++a) {
        if (done[a]) continue;
        const std::string len = stepsText(v[a].off - v[a].on, c.ppq), vel = velText(v[a].vel);
        std::string notes = pitchText(v[a].pitch);
        for (size_t b = a + 1; b < v.size() && v[b].on == v[a].on; ++b) {
            if (done[b] || v[b].slide != v[a].slide || v[b].off != v[a].off || velText(v[b].vel) != vel) continue;
            notes += "," + pitchText(v[b].pitch);
            done[b] = 1;
        }
        char line[512];
        std::snprintf(line, sizeof line, "%-7s %-11s %-6s %s%s\n", stepsText(v[a].on, c.ppq).c_str(), notes.c_str(),
                      len.c_str(), vel.c_str(), v[a].slide ? "  slide" : "");
        // A chord line can outgrow the buffer; write it unpadded then.
        if (std::strlen(line) + 1 >= sizeof line)
            out += stepsText(v[a].on, c.ppq) + " " + notes + " " + len + " " + vel + (v[a].slide ? " slide" : "") + "\n";
        else
            out += line;
    }
    return out;
}

// ---------------------------------------------------------------------------------------------------------------
// Export: the pattern's notes as tick segments (ratchets expanded), shared by both writers.

constexpr int64_t kStepTicks = kMidiExportPpq / 4;
constexpr int64_t kSlideOverlap = kStepTicks / 16;  // a slide overlaps the next note by 1/16 step

struct Segment {
    int64_t on, off;
    double pitch, vel;
};

std::vector<Segment> segments(const Pattern& p, int beatsPerBar, int64_t& lengthTicks) {
    const int steps = p.steps(beatsPerBar);
    lengthTicks = steps * kStepTicks;
    std::vector<Segment> out;
    for (const PatternNote& n : p.notes) {
        if (n.at >= steps - 1e-9) continue;  // playback never starts these
        const int r = std::max(1, n.ratchet);
        const double part = n.len / r;
        for (int q = 0; q < r; ++q) {
            Segment s;
            s.on = std::llround((n.at + part * q) * kStepTicks);
            s.off = std::llround((n.at + part * (q + 1)) * kStepTicks);
            s.pitch = std::clamp(n.pitch, 0.0, 127.0);
            s.vel = std::clamp(n.vel, 0.0, 1.0);
            if (q == r - 1 && n.slideTo >= 0 &&
                std::lround(p.notes[n.slideTo].pitch) != std::lround(n.pitch))
                s.off += kSlideOverlap;
            if (s.on >= lengthTicks) continue;
            s.off = std::min(std::max(s.off, s.on + 1), lengthTicks);  // released at the loop end, as in playback
            out.push_back(s);
        }
    }
    std::stable_sort(out.begin(), out.end(), [](const Segment& a, const Segment& b) { return a.on < b.on; });
    return out;
}

double safeBpm(double bpm) { return std::isfinite(bpm) ? std::clamp(bpm, 20.0, 400.0) : 120.0; }
int safeBeats(int beats) { return std::clamp(beats, 1, 16); }

void put16(std::vector<uint8_t>& o, uint32_t v) {
    o.push_back(static_cast<uint8_t>(v >> 8));
    o.push_back(static_cast<uint8_t>(v));
}
void put32(std::vector<uint8_t>& o, uint32_t v) {
    put16(o, v >> 16);
    put16(o, v & 0xFFFF);
}
void putVlq(std::vector<uint8_t>& o, uint32_t v) {
    uint8_t buf[5];
    int n = 0;
    buf[n++] = v & 0x7F;
    while (v >>= 7) buf[n++] = static_cast<uint8_t>(0x80 | (v & 0x7F));
    while (n) o.push_back(buf[--n]);
}

struct MidiEvent {
    int64_t tick;
    int order;  // at one tick: setup, note offs, pitch bends, note ons
    uint8_t b[3];
    int n;
};

std::vector<uint8_t> trackChunk(const std::string& name, std::vector<MidiEvent> ev, const std::vector<uint8_t>& head,
                                int64_t endTick) {
    std::stable_sort(ev.begin(), ev.end(), [](const MidiEvent& a, const MidiEvent& b) {
        return a.tick != b.tick ? a.tick < b.tick : a.order < b.order;
    });
    std::vector<uint8_t> body;
    if (!name.empty()) {
        body.insert(body.end(), {0x00, 0xFF, 0x03});
        putVlq(body, static_cast<uint32_t>(name.size()));
        body.insert(body.end(), name.begin(), name.end());
    }
    body.insert(body.end(), head.begin(), head.end());
    int64_t last = 0;
    for (const MidiEvent& e : ev) {
        putVlq(body, static_cast<uint32_t>(e.tick - last));
        last = e.tick;
        body.insert(body.end(), e.b, e.b + e.n);
    }
    putVlq(body, static_cast<uint32_t>(std::max<int64_t>(0, endTick - last)));
    body.insert(body.end(), {0xFF, 0x2F, 0x00});
    std::vector<uint8_t> chunk = {'M', 'T', 'r', 'k'};
    put32(chunk, static_cast<uint32_t>(body.size()));
    chunk.insert(chunk.end(), body.begin(), body.end());
    return chunk;
}

std::string exportName(const Pattern& p) {
    std::string n = p.name;
    if (n.size() > 96) {
        size_t cut = 96;
        while (cut > 0 && (static_cast<unsigned char>(n[cut]) & 0xC0) == 0x80) --cut;
        n.resize(cut);
    }
    return n;
}

}  // namespace

std::string patternFromMidi(const uint8_t* data, size_t size, const MidiImportOptions& options, std::string& error) {
    error.clear();
    try {
        if (!data || size == 0) throw Fail{"the file is empty"};
        if (size > kMaxMidiFileBytes) throw Fail{"the file is bigger than 16 MB"};
        MidiImportOptions o = options;
        o.maxNotes = std::clamp(o.maxNotes, 1, kMaxPatternNotes);
        if (o.channel > 15) throw Fail{"MIDI channels are 0 to 15"};
        Collected c;
        if (size >= 8 && std::memcmp(data, "SMF2CLIP", 8) == 0)
            readClip(data, size, o, c);
        else
            readSmf(data, size, o, c);
        std::string text = writePattern(c, o);
        PatternResult check = parsePattern(text);
        if (!check.pattern) throw Fail{"the imported notes don't make a valid pattern: " + check.error};
        return text;
    } catch (const Fail& f) {
        error = f.msg;
        return "";
    }
}

std::vector<uint8_t> patternToSmf(const Pattern& p, double bpm, int beatsPerBar) {
    bpm = safeBpm(bpm);
    beatsPerBar = safeBeats(beatsPerBar);
    int64_t lengthTicks = 0;
    const std::vector<Segment> segs = segments(p, beatsPerBar, lengthTicks);
    const std::string name = exportName(p);

    // Conductor track: tempo and meter.
    std::vector<uint8_t> head;
    const uint32_t usPerQuarter = static_cast<uint32_t>(std::llround(60000000.0 / bpm));
    head.insert(head.end(), {0x00, 0xFF, 0x51, 0x03, static_cast<uint8_t>(usPerQuarter >> 16),
                             static_cast<uint8_t>(usPerQuarter >> 8), static_cast<uint8_t>(usPerQuarter)});
    head.insert(head.end(), {0x00, 0xFF, 0x58, 0x04, static_cast<uint8_t>(beatsPerBar), 0x02, 24, 8});
    std::vector<uint8_t> conductor = trackChunk(name, {}, head, lengthTicks);

    // Note track. Whole-number pitches play on channel 1. A microtonal pitch rounds to the nearest note and plays on
    // a channel of its own (2-9, 11-16), with a pitch bend just before the note on (bend range +-2 semitones, set
    // by RPN 0 on each such channel at the start).
    std::vector<MidiEvent> ev;
    static const int kPool[] = {1, 2, 3, 4, 5, 6, 7, 8, 10, 11, 12, 13, 14, 15};
    int64_t busyUntil[16] = {};
    int lastBend[16];
    std::fill(lastBend, lastBend + 16, 8192);
    bool used[16] = {};
    for (const Segment& s : segs) {
        const int key = static_cast<int>(std::lround(s.pitch));
        const double cents = s.pitch - key;
        int ch = 0;
        if (std::fabs(cents) > 1e-6) {
            const int bend = static_cast<int>(std::clamp<long>(std::lround(8192 + cents * 4096), 0, 16383));
            int pick = -1;
            for (int c : kPool)  // a free channel already at this bend, else any free one, else the soonest free
                if (busyUntil[c] <= s.on && lastBend[c] == bend) { pick = c; break; }
            if (pick < 0)
                for (int c : kPool)
                    if (busyUntil[c] <= s.on) { pick = c; break; }
            if (pick < 0) {
                pick = kPool[0];
                for (int c : kPool)
                    if (busyUntil[c] < busyUntil[pick]) pick = c;
            }
            ch = pick;
            used[ch] = true;
            if (lastBend[ch] != bend) {
                ev.push_back({s.on, 2, {static_cast<uint8_t>(0xE0 | ch), static_cast<uint8_t>(bend & 0x7F), static_cast<uint8_t>(bend >> 7)}, 3});
                lastBend[ch] = bend;
            }
        }
        busyUntil[ch] = std::max(busyUntil[ch], s.off);
        const uint8_t vel = static_cast<uint8_t>(std::clamp<long>(std::lround(s.vel * 127), 1, 127));
        ev.push_back({s.on, 3, {static_cast<uint8_t>(0x90 | ch), static_cast<uint8_t>(key), vel}, 3});
        ev.push_back({s.off, 1, {static_cast<uint8_t>(0x80 | ch), static_cast<uint8_t>(key), 64}, 3});
    }
    for (int ch = 0; ch < 16; ++ch) {
        if (!used[ch]) continue;
        const uint8_t cc = static_cast<uint8_t>(0xB0 | ch);
        const uint8_t rpn[][2] = {{101, 0}, {100, 0}, {6, 2}, {38, 0}, {101, 127}, {100, 127}};
        for (const auto& m : rpn) ev.push_back({0, 0, {cc, m[0], m[1]}, 3});
    }
    std::vector<uint8_t> notes = trackChunk(name, std::move(ev), {}, lengthTicks);

    std::vector<uint8_t> out = {'M', 'T', 'h', 'd', 0, 0, 0, 6, 0, 1, 0, 2};
    put16(out, kMidiExportPpq);
    out.insert(out.end(), conductor.begin(), conductor.end());
    out.insert(out.end(), notes.begin(), notes.end());
    return out;
}

std::vector<uint8_t> patternToMidiClip(const Pattern& p, double bpm, int beatsPerBar) {
    bpm = safeBpm(bpm);
    beatsPerBar = safeBeats(beatsPerBar);
    int64_t lengthTicks = 0;
    const std::vector<Segment> segs = segments(p, beatsPerBar, lengthTicks);
    std::vector<uint32_t> w;
    int64_t now = 0;
    // Delta Clockstamp (MT 0, status 4, 20-bit ticks); longer gaps are split with NOOPs, as M2-104-UM 7.2.3.2 asks.
    auto clock = [&](int64_t tick) {
        int64_t d = tick - now;
        while (d > 0xFFFFF) {
            w.push_back(0x00400000u | 0xFFFFFu);
            w.push_back(0x00000000u);  // NOOP
            d -= 0xFFFFF;
        }
        w.push_back(0x00400000u | static_cast<uint32_t>(d));
        now = tick;
    };
    // Clip Configuration Header: DCS 0, then Delta Clockstamp Ticks Per Quarter Note (MT 0, status 3).
    w.push_back(0x00400000u);
    w.push_back(0x00300000u | kMidiExportPpq);
    // Clip Sequence Data: Start of Clip (MT F, status 0x20) with tempo, meter and name sharing its clockstamp.
    w.push_back(0x00400000u);
    w.insert(w.end(), {0xF0200000u, 0, 0, 0});
    const uint32_t tenNs = static_cast<uint32_t>(std::llround(6.0e9 / bpm));
    w.insert(w.end(), {0xD0100000u, tenNs, 0, 0});                                          // Set Tempo
    w.insert(w.end(), {0xD0100001u, (uint32_t(beatsPerBar) << 24) | (2u << 16) | (8u << 8), 0, 0});  // 4ths, 8 32nds
    const std::string name = exportName(p);
    for (size_t at = 0; at < name.size(); at += 12) {  // MIDI Clip Name (Flex Data bank 1, status 3)
        const bool first = at == 0, last = at + 12 >= name.size();
        const uint32_t form = first && last ? 0 : first ? 1 : last ? 3 : 2;
        w.push_back(0xD0000000u | (form << 22) | (1u << 20) | 0x0103u);
        for (int q = 0; q < 3; ++q) {
            uint32_t v = 0;
            for (int b = 0; b < 4; ++b) {
                const size_t idx = at + q * 4 + b;
                v = (v << 8) | (idx < name.size() ? static_cast<uint8_t>(name[idx]) : 0);
            }
            w.push_back(v);
        }
    }
    // Notes: MIDI 2.0 Channel Voice (MT 4) on group 0, channel 1, 16-bit velocity. A microtonal pitch uses Note On
    // attribute #3 (Pitch 7.9); its note number is only an index, so it takes the nearest one not already sounding.
    struct Ev {
        int64_t tick;
        int order;
        uint32_t w0, w1;
    };
    std::vector<Ev> ev;
    int64_t busyUntil[128] = {};
    for (const Segment& s : segs) {
        int idx = static_cast<int>(std::lround(s.pitch));
        uint32_t attrType = 0, attr = 0;
        if (std::fabs(s.pitch - idx) > 1e-6) {
            attrType = 0x03;
            attr = static_cast<uint32_t>(std::min<long>(std::lround(s.pitch * 512.0), 0xFFFF));
            for (int d = 0; d < 128; ++d) {
                const int up = idx + d, down = idx - d;
                if (up <= 127 && busyUntil[up] <= s.on) { idx = up; break; }
                if (down >= 0 && busyUntil[down] <= s.on) { idx = down; break; }
            }
        }
        idx = std::clamp(idx, 0, 127);
        busyUntil[idx] = std::max(busyUntil[idx], s.off);
        const uint32_t vel = static_cast<uint32_t>(std::lround(s.vel * 65535.0));
        ev.push_back({s.on, 1, 0x40900000u | (uint32_t(idx) << 8) | attrType, (vel << 16) | attr});
        ev.push_back({s.off, 0, 0x40800000u | (uint32_t(idx) << 8), 0x8000u << 16});
    }
    std::stable_sort(ev.begin(), ev.end(), [](const Ev& a, const Ev& b) {
        return a.tick != b.tick ? a.tick < b.tick : a.order < b.order;
    });
    for (const Ev& e : ev) {
        if (e.tick != now) clock(e.tick);
        w.push_back(e.w0);
        w.push_back(e.w1);
    }
    clock(lengthTicks);
    w.insert(w.end(), {0xF0210000u, 0, 0, 0});  // End of Clip
    std::vector<uint8_t> out = {'S', 'M', 'F', '2', 'C', 'L', 'I', 'P'};
    out.reserve(8 + w.size() * 4);
    for (uint32_t v : w) put32(out, v);
    return out;
}

}  // namespace caw
