// Parses note patterns: a header, then one line per note or chord (`at  note(s)  len  vel  extras`).
#include "pattern.h"

#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstdio>
#include <stdexcept>

#include "compile.h"
#include "detmath.h"
#include "json.h"

namespace caw {

namespace {

struct PatternError : std::runtime_error {
    int line, col;
    PatternError(int l, int c, const std::string& m) : std::runtime_error(m), line(l), col(c) {}
};

struct Word {
    std::string text;
    int col;
};

std::string trimmed(std::string_view s) {
    size_t a = 0, b = s.size();
    while (a < b && std::isspace(static_cast<unsigned char>(s[a]))) ++a;
    while (b > a && std::isspace(static_cast<unsigned char>(s[b - 1]))) --b;
    return std::string(s.substr(a, b - a));
}

std::vector<Word> words(std::string_view line) {
    std::vector<Word> out;
    size_t i = 0;
    while (i < line.size()) {
        while (i < line.size() && std::isspace(static_cast<unsigned char>(line[i]))) ++i;
        if (i >= line.size()) break;
        const size_t start = i;
        while (i < line.size() && !std::isspace(static_cast<unsigned char>(line[i]))) ++i;
        out.push_back({std::string(line.substr(start, i - start)), static_cast<int>(start) + 1});
    }
    return out;
}

// A plain number, or a fraction such as 13/3 so triplets land exactly.
bool number(const std::string& s, double& out) {
    const size_t slash = s.find('/');
    if (slash != std::string::npos) {
        double a = 0, b = 0;
        if (!number(s.substr(0, slash), a) || !number(s.substr(slash + 1), b) || b == 0) return false;
        out = a / b;
        return true;
    }
    if (s.empty()) return false;
    char* end = nullptr;
    out = std::strtod(s.c_str(), &end);
    return end == s.c_str() + s.size() && std::isfinite(out);
}

double needNumber(const Word& w, int line, const char* what, double lo, double hi) {
    double v = 0;
    if (!number(w.text, v)) throw PatternError(line, w.col, std::string("expected ") + what + ", found '" + w.text + "'");
    if (v < lo || v > hi) {
        char msg[160];
        std::snprintf(msg, sizeof msg, "%s must be %g to %g", what, lo, hi);
        throw PatternError(line, w.col, msg);
    }
    return v;
}

// One note or a chord: C3, 48, 60.5, or C3,E3,G3.
std::vector<double> pitches(const Word& w, int line) {
    std::vector<double> out;
    size_t start = 0;
    while (start <= w.text.size()) {
        size_t comma = w.text.find(',', start);
        if (comma == std::string::npos) comma = w.text.size();
        const std::string part = w.text.substr(start, comma - start);
        double v = 0;
        if (!noteNumber(part, v) && !number(part, v))
            throw PatternError(line, w.col + static_cast<int>(start), "expected a note such as C3, F#2 or 48, found '" + part + "'");
        if (v < 0 || v > 127) throw PatternError(line, w.col + static_cast<int>(start), "notes must be 0 to 127");
        out.push_back(v);
        start = comma + 1;
    }
    return out;
}

// A curve's points: `t:v` or `t:v~k`, as many as follow (2..16), times rising from 0 to 1.
size_t curvePoints(const std::vector<Word>& w, size_t k, int line, const Word& key, double lo, double hi, NoteCurve& c) {
    c.count = 0;
    double last = -1;
    while (k < w.size()) {
        const std::string& s = w[k].text;
        const size_t colon = s.find(':');
        if (colon == std::string::npos) break;
        const size_t tilde = s.find('~', colon);
        double t = 0, v = 0, b = 0;
        const bool ok = number(s.substr(0, colon), t) &&
                        number(s.substr(colon + 1, tilde == std::string::npos ? std::string::npos : tilde - colon - 1), v) &&
                        (tilde == std::string::npos || number(s.substr(tilde + 1), b));
        if (!ok) throw PatternError(line, w[k].col, "a curve point looks like 0.5:2 or 0.5:2~0.3 (time:value~bend)");
        if (t < 0 || t > 1 || t < last) throw PatternError(line, w[k].col, "curve times go from 0 to 1, rising");
        if (v < lo || v > hi) {
            char msg[120];
            std::snprintf(msg, sizeof msg, "%s values must be %g to %g", key.text.c_str(), lo, hi);
            throw PatternError(line, w[k].col, msg);
        }
        if (b < -1 || b > 1) throw PatternError(line, w[k].col, "a bend (after ~) must be -1 to 1");
        if (c.count >= kMaxCurvePoints) throw PatternError(line, w[k].col, "a curve has at most 16 points");
        c.t[c.count] = static_cast<float>(t);
        c.v[c.count] = static_cast<float>(v);
        c.k[c.count] = static_cast<float>(b);
        ++c.count;
        last = t;
        ++k;
    }
    if (c.count == 0) throw PatternError(line, key.col, "'" + key.text + "' needs points such as 0:0 0.5:2 1:0");
    return k;
}

uint64_t mix64(uint64_t x) {
    x += 0x9E3779B97F4A7C15ull;
    x = (x ^ (x >> 30)) * 0xBF58476D1CE4E5B9ull;
    x = (x ^ (x >> 27)) * 0x94D049BB133111EBull;
    return x ^ (x >> 31);
}

}  // namespace

double NoteCurve::at(double u) const {
    if (count == 0) return 0;
    if (u <= t[0]) return v[0];
    for (int i = 0; i + 1 < count; ++i) {
        if (u <= t[i + 1]) {
            const double span = static_cast<double>(t[i + 1]) - t[i];
            double x = span > 0 ? (u - t[i]) / span : 1.0;
            if (k[i] != 0) x = detPow(x, detPow(4.0, k[i]));
            return v[i] + (static_cast<double>(v[i + 1]) - v[i]) * x;
        }
    }
    return v[count - 1];
}

int Pattern::steps(int beatsPerBar) const {
    const int bar = std::max(1, beatsPerBar) * 4;
    int s = lengthSteps;
    if (lengthBars > 0) s = lengthBars * bar;
    if (s <= 0) s = std::max(1, static_cast<int>(std::ceil(lastEnd / bar - 1e-9))) * bar;
    return std::min(s, kMaxPatternSteps);
}

bool notePlays(const PatternNote& n, uint32_t index, int64_t repeat, uint32_t seed) {
    if (n.prob >= 1.0) return true;
    if (n.prob <= 0.0) return false;
    const uint64_t h = mix64(mix64(mix64(seed) ^ index) ^ static_cast<uint64_t>(repeat));
    return static_cast<double>(h >> 11) * (1.0 / 9007199254740992.0) < n.prob;
}

PatternResult parsePattern(std::string_view src) {
    PatternResult r;
    auto p = std::make_shared<Pattern>();
    try {
        size_t i = 0;
        int lineNo = 0;
        auto nextLine = [&](std::string_view& line) {
            if (i >= src.size()) return false;
            size_t e = src.find('\n', i);
            if (e == std::string_view::npos) e = src.size();
            line = src.substr(i, e - i);
            i = e < src.size() ? e + 1 : e;
            ++lineNo;
            return true;
        };
        std::string_view line;
        bool isPattern = false;
        // Header.
        const size_t save = i;
        if (nextLine(line) && trimmed(line) == "---") {
            while (true) {
                if (!nextLine(line)) throw PatternError(1, 1, "header starts with '---' but never ends with '---'");
                std::string l = trimmed(line);
                if (l == "---") break;
                const size_t hash = l.find('#');
                if (hash != std::string::npos) l = trimmed(l.substr(0, hash));
                if (l.empty()) continue;
                const size_t colon = l.find(':');
                if (colon == std::string::npos) throw PatternError(lineNo, 1, "header lines look like 'key: value'");
                const std::string key = trimmed(l.substr(0, colon)), value = trimmed(l.substr(colon + 1));
                if (key == "caw" && value != "1") throw PatternError(lineNo, 1, "this app reads module format 1");
                if (key == "kind") isPattern = value == "pattern";
                if (key == "name") p->name = value;
                if (key == "summary") p->summary = value;
                if (key == "length") {
                    std::vector<Word> w = words(value);
                    const int col = static_cast<int>(line.find(value)) + 1;
                    const bool bars = w.size() == 2 && (w[1].text == "bars" || w[1].text == "bar");
                    if (w.empty() || w.size() > 2 || (w.size() == 2 && !bars))
                        throw PatternError(lineNo, col, "length is a number of steps (16) or bars (4 bars)");
                    const double n = needNumber(w[0], lineNo, "length", 1, bars ? 256 : kMaxPatternSteps);
                    if (n != std::floor(n)) throw PatternError(lineNo, col, "length must be a whole number");
                    (bars ? p->lengthBars : p->lengthSteps) = static_cast<int>(n);
                }
            }
        } else {
            i = save;
            lineNo = 0;
        }
        if (!isPattern) throw PatternError(1, 1, "a pattern's header needs 'kind: pattern'");
        // Notes.
        while (nextLine(line)) {
            std::string_view body = line;
            const size_t comment = body.find("//");
            if (comment != std::string_view::npos) body = body.substr(0, comment);
            std::vector<Word> w = words(body);
            if (w.empty()) continue;
            if (w[0].text[0] == '[')
                throw PatternError(lineNo, w[0].col, "kit rows ([kick] and so on) aren't supported yet");
            if (w.size() < 3) throw PatternError(lineNo, w[0].col, "a note line is: at  note  length  [velocity]  [extras]");
            PatternNote n;
            n.line = lineNo;
            n.at = needNumber(w[0], lineNo, "the start (in steps)", 0, kMaxPatternSteps);
            const std::vector<double> chord = pitches(w[1], lineNo);
            n.len = needNumber(w[2], lineNo, "the length (in steps)", 1e-3, kMaxPatternSteps);
            size_t k = 3;
            double v = 0;
            if (k < w.size() && number(w[k].text, v)) n.vel = needNumber(w[k++], lineNo, "velocity", 0, 1);
            NoteExpression ex;
            bool expressive = false;
            while (k < w.size()) {
                const Word& x = w[k++];
                if (x.text == "bend" || x.text == "press" || x.text == "timbre") {
                    NoteCurve& c = x.text == "bend" ? ex.bend : (x.text == "press" ? ex.press : ex.timbre);
                    k = x.text == "bend" ? curvePoints(w, k, lineNo, x, -kMaxBend, kMaxBend, c)
                                         : curvePoints(w, k, lineNo, x, 0, 1, c);
                    expressive = true;
                } else if (x.text == "vib") {
                    if (k + 1 >= w.size()) throw PatternError(lineNo, x.col, "vib needs depth and rate: vib 0.3 5.5 (and a fade-in, 0..1)");
                    ex.vibDepth = needNumber(w[k++], lineNo, "vib depth (semitones)", 0, 12);
                    ex.vibRate = needNumber(w[k++], lineNo, "vib rate (Hz)", 0.1, 30);
                    if (k < w.size() && number(w[k].text, v)) ex.vibDelay = needNumber(w[k++], lineNo, "vib fade-in", 0, 1);
                    expressive = true;
                } else if (x.text == "slide") {
                    n.slide = true;
                } else if (x.text == "prob" || x.text == "ratchet") {
                    if (k >= w.size()) throw PatternError(lineNo, x.col, "'" + x.text + "' needs a number after it");
                    if (x.text == "prob") {
                        n.prob = needNumber(w[k++], lineNo, "prob", 0, 1);
                    } else {
                        const double rv = needNumber(w[k], lineNo, "ratchet", 1, kMaxRatchet);
                        if (rv != std::floor(rv)) throw PatternError(lineNo, w[k].col, "ratchet must be a whole number");
                        n.ratchet = static_cast<int>(rv);
                        ++k;
                    }
                } else {
                    throw PatternError(lineNo, x.col,
                                       "unknown extra '" + x.text + "' (try prob 0.5, ratchet 3, slide, bend, vib, press or timbre)");
                }
            }
            if (expressive) {
                n.extra = static_cast<int>(p->expressions.size());
                p->expressions.push_back(ex);
            }
            for (double pitch : chord) {
                if (static_cast<int>(p->notes.size()) >= kMaxPatternNotes)
                    throw PatternError(lineNo, w[0].col, "a pattern holds at most 4096 notes");
                n.pitch = pitch;
                p->notes.push_back(n);
            }
        }
        // Sort by start (stable, so a chord keeps its written order) and link slides voice by voice.
        std::stable_sort(p->notes.begin(), p->notes.end(),
                         [](const PatternNote& a, const PatternNote& b) { return a.at < b.at; });
        for (size_t a = 0; a < p->notes.size(); ++a) {
            PatternNote& n = p->notes[a];
            p->lastEnd = std::max(p->lastEnd, n.at + n.len);
            if (!n.slide) continue;
            const double end = n.at + n.len;
            for (size_t b = a + 1; b < p->notes.size(); ++b) {
                PatternNote& m = p->notes[b];
                if (m.at > end + 1e-9) break;
                if (std::fabs(m.at - end) < 1e-9 && m.slideFrom < 0) {
                    n.slideTo = static_cast<int>(b);
                    m.slideFrom = static_cast<int>(a);
                    break;
                }
            }
        }
        for (size_t a = 0; a < p->notes.size(); ++a) {
            const PatternNote& n = p->notes[a];
            const double part = n.len / n.ratchet;
            for (int q = 0; q < n.ratchet; ++q) {
                p->events.push_back({n.at + part * q, static_cast<uint32_t>(a), static_cast<uint16_t>(q), true});
                p->events.push_back({n.at + part * (q + 1), static_cast<uint32_t>(a), static_cast<uint16_t>(q), false});
            }
        }
        std::stable_sort(p->events.begin(), p->events.end(), [](const PatternEvent& a, const PatternEvent& b) {
            if (a.step != b.step) return a.step < b.step;
            return a.on && !b.on;
        });
        r.pattern = std::move(p);
    } catch (const PatternError& e) {
        r.line = e.line;
        r.col = e.col;
        r.error = "line " + std::to_string(e.line) + ", col " + std::to_string(e.col) + ": " + e.what();
    }
    return r;
}

std::string describePattern(const Pattern& p) {
    char buf[64];
    std::string o = "\"kind\":\"pattern\",\"name\":\"" + jsonEscape(p.name) + "\",\"summary\":\"" + jsonEscape(p.summary) +
                    "\",\"length_steps\":" + std::to_string(p.lengthSteps) + ",\"length_bars\":" +
                    std::to_string(p.lengthBars);
    std::snprintf(buf, sizeof buf, ",\"last_end\":%.17g", p.lastEnd);
    o += buf;
    o += ",\"notes\":" + std::to_string(p.notes.size()) + ",\"params\":[],\"exports\":[],\"imports\":[],\"functions\":[]";
    return o;
}

}  // namespace caw
