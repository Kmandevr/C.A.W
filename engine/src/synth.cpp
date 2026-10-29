// Synth patches: reads each line, checks every value against its range, and writes the voice and effect code.
#include "synth.h"

#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>
#include <set>

#include "tables.h"

namespace caw {

namespace {

struct PatchError {
    int line, col;
    std::string message;
};

std::string trim(std::string_view s) {
    size_t a = 0, b = s.size();
    while (a < b && (s[a] == ' ' || s[a] == '\t' || s[a] == '\r')) ++a;
    while (b > a && (s[b - 1] == ' ' || s[b - 1] == '\t' || s[b - 1] == '\r')) --b;
    return std::string(s.substr(a, b - a));
}

// A number the way C.A.W writes it: shortest form that reads back the same.
// A number as a person writes it (1200, 0.25, -12): the fewest decimals that read back the same, never an exponent.
std::string num(double v) {
    char buf[64];
    for (int p = 0; p <= 12; ++p) {
        std::snprintf(buf, sizeof buf, "%.*f", p, v);
        if (std::strtod(buf, nullptr) == v) return std::string(buf) == "-0" ? "0" : buf;
    }
    std::snprintf(buf, sizeof buf, "%.12f", v);
    return buf;
}

struct Word {
    std::string text;
    int col;
};

// The words of one line, without its `// comment`.
std::vector<Word> words(const std::string& line) {
    std::vector<Word> out;
    size_t end = line.find("//");
    if (end == std::string::npos) end = line.size();
    size_t i = 0;
    while (i < end) {
        while (i < end && (line[i] == ' ' || line[i] == '\t' || line[i] == '\r')) ++i;
        const size_t s = i;
        while (i < end && line[i] != ' ' && line[i] != '\t' && line[i] != '\r') ++i;
        if (i > s) out.push_back({line.substr(s, i - s), static_cast<int>(s) + 1});
    }
    return out;
}

// Reads `key value key value …` after a line's leading words, checking each key is allowed and each value fits.
class Fields {
public:
    Fields(const std::vector<Word>& w, size_t from, int line) : w_(w), i_(from), line_(line) {}

    bool done() const { return i_ >= w_.size(); }
    const Word& peek() const { return w_[i_]; }
    const Word& take() { return w_[i_++]; }
    int line() const { return line_; }

    double number(const Word& key, double lo, double hi) {
        if (done()) throw PatchError{line_, key.col, key.text + " needs a value"};
        const Word& v = take();
        char* end = nullptr;
        double x;
        const size_t slash = v.text.find('/');
        if (slash != std::string::npos) {  // a fraction such as 1/4
            const double a = std::strtod(v.text.substr(0, slash).c_str(), &end);
            const double b = std::strtod(v.text.substr(slash + 1).c_str(), nullptr);
            x = b != 0 ? a / b : NAN;
            end = nullptr;
        } else {
            x = std::strtod(v.text.c_str(), &end);
            if (end && *end != '\0') x = NAN;
        }
        if (!std::isfinite(x)) throw PatchError{line_, v.col, "'" + v.text + "' is not a number"};
        if (x < lo || x > hi)
            throw PatchError{line_, v.col, key.text + " must be " + num(lo) + " to " + num(hi) + ", not " + v.text};
        return x;
    }

    std::string word(const Word& key) {
        if (done()) throw PatchError{line_, key.col, key.text + " needs a value"};
        return take().text;
    }

    [[noreturn]] void unknown(const Word& key, const std::string& allowed) const {
        throw PatchError{line_, key.col, "unknown setting '" + key.text + "' (this line takes " + allowed + ")"};
    }

private:
    const std::vector<Word>& w_;
    size_t i_;
    int line_;
};

struct Osc {
    bool on = false;
    std::string table = "saw";
    double level = 0.8, unison = 1, detune = 0.2, pos = 0, octave = 0, semi = 0, fine = 0;
};
struct Sub {
    bool on = false;
    double level = 0.5, octave = -1;
    std::string shape = "sine";
};
struct Noise {
    bool on = false;
    double level = 0.2, color = 1;
};
struct Filter {
    bool on = false;
    std::string type = "lowpass";
    double cutoff = 2000, res = 0.2, drive = 0, keytrack = 0.5;
    std::vector<std::string> from;  // empty: the default inputs
    bool fromSet = false;
};
struct Env {
    double attack = 0.005, decay = 0.3, sustain = 0.8, release = 0.3;
};
struct Fx {
    std::string kind;  // drive, crush, delay, reverb, comp, or "" for a user module
    std::string module;
    std::map<std::string, double> v;
    int line = 0;
};

struct Patch {
    std::string name = "Synth", summary;
    double voices = 8, glide = 0, volume = 0.8;
    Osc osc[3];
    Sub sub;
    Noise noise;
    Filter filter[2];
    bool parallel = false;
    Env env;
    std::vector<Fx> fx;
};

const char* const kFilterFns[][2] = {{"lowpass", "lpf"}, {"highpass", "hpf"}, {"bandpass", "bpf"}, {"notch", "notch"}};

std::string filterFn(const std::string& type) {
    for (const auto& f : kFilterFns)
        if (type == f[0]) return f[1];
    return "";
}

bool tableExists(const std::string& name) {
    const char* const* names = builtinTableNames();
    for (int i = 0; i < builtinTableCount(); ++i)
        if (name == names[i]) return true;
    return false;
}

std::string tableList() {
    std::string s;
    const char* const* names = builtinTableNames();
    for (int i = 0; i < builtinTableCount(); ++i) s += (i ? ", " : "") + std::string(names[i]);
    return s;
}

void parseLine(Patch& p, const std::vector<Word>& w, int line) {
    const Word& head = w[0];
    const std::string& k = head.text;
    auto later = [&](const std::string& what) {
        throw PatchError{line, head.col, what + " lines come in a later synth stage (docs/synth.md)"};
    };
    if (k == "voices" || k == "glide" || k == "volume") {
        Fields f(w, 0, line);
        const Word& key = f.take();
        if (k == "voices") {
            p.voices = f.number(key, 1, 32);
            if (p.voices != std::floor(p.voices)) throw PatchError{line, w[1].col, "voices must be a whole number"};
        } else if (k == "glide") {
            p.glide = f.number(key, 0, 2);
        } else {
            p.volume = f.number(key, 0, 1);
        }
        if (!f.done()) throw PatchError{line, f.peek().col, "unexpected '" + f.peek().text + "'"};
        return;
    }
    if (k == "osc") {
        if (w.size() < 2 || w[1].text.size() != 1 || w[1].text[0] < 'a' || w[1].text[0] > 'c')
            throw PatchError{line, head.col, "osc needs its name: a, b or c"};
        Osc& o = p.osc[w[1].text[0] - 'a'];
        o = Osc{};
        if (w.size() == 3 && w[2].text == "off") return;
        o.on = true;
        Fields f(w, 2, line);
        while (!f.done()) {
            const Word& key = f.take();
            if (key.text == "table") {
                o.table = f.word(key);
                if (!tableExists(o.table))
                    throw PatchError{line, key.col, "unknown table '" + o.table + "' (tables: " + tableList() + ")"};
            } else if (key.text == "level") o.level = f.number(key, 0, 1);
            else if (key.text == "unison") {
                o.unison = f.number(key, 1, 16);
                if (o.unison != std::floor(o.unison)) throw PatchError{line, key.col, "unison must be a whole number"};
            } else if (key.text == "detune") o.detune = f.number(key, 0, 1);
            else if (key.text == "pos") o.pos = f.number(key, 0, 1);
            else if (key.text == "octave") o.octave = f.number(key, -4, 4);
            else if (key.text == "semi") o.semi = f.number(key, -24, 24);
            else if (key.text == "fine") o.fine = f.number(key, -100, 100);
            else if (key.text == "warp") later("warp");
            else f.unknown(key, "table, level, unison, detune, pos, octave, semi and fine");
        }
        return;
    }
    if (k == "sub" || k == "noise") {
        Fields f(w, 1, line);
        if (k == "sub") {
            p.sub = Sub{};
            if (w.size() == 2 && w[1].text == "off") return;
            p.sub.on = true;
        } else {
            p.noise = Noise{};
            if (w.size() == 2 && w[1].text == "off") return;
            p.noise.on = true;
        }
        while (!f.done()) {
            const Word& key = f.take();
            if (key.text == "level") (k == "sub" ? p.sub.level : p.noise.level) = f.number(key, 0, 1);
            else if (k == "sub" && key.text == "octave") {
                p.sub.octave = f.number(key, -2, -1);
                if (p.sub.octave != std::floor(p.sub.octave)) throw PatchError{line, key.col, "octave must be -1 or -2"};
            } else if (k == "sub" && key.text == "shape") {
                p.sub.shape = f.word(key);
                if (p.sub.shape != "sine" && p.sub.shape != "tri" && p.sub.shape != "saw" && p.sub.shape != "square")
                    throw PatchError{line, key.col, "shape must be sine, tri, saw or square"};
            } else if (k == "noise" && key.text == "color") p.noise.color = f.number(key, 0, 1);
            else f.unknown(key, k == "sub" ? "level, shape and octave" : "level and color");
        }
        return;
    }
    if (k == "filter") {
        if (w.size() < 3 || (w[1].text != "1" && w[1].text != "2"))
            throw PatchError{line, head.col, "filter needs its number (1 or 2) and a type: lowpass, highpass, bandpass, notch or off"};
        Filter& fl = p.filter[w[1].text[0] - '1'];
        fl = Filter{};
        if (w[2].text == "off") {
            if (w.size() > 3) throw PatchError{line, w[3].col, "unexpected '" + w[3].text + "'"};
            return;
        }
        if (filterFn(w[2].text).empty())
            throw PatchError{line, w[2].col, "filter type must be lowpass, highpass, bandpass, notch or off"};
        fl.on = true;
        fl.type = w[2].text;
        Fields f(w, 3, line);
        while (!f.done()) {
            const Word& key = f.take();
            if (key.text == "cutoff") fl.cutoff = f.number(key, 20, 20000);
            else if (key.text == "res") fl.res = f.number(key, 0, 1);
            else if (key.text == "drive") fl.drive = f.number(key, 0, 1);
            else if (key.text == "keytrack") fl.keytrack = f.number(key, 0, 1);
            else if (key.text == "from") {
                fl.fromSet = true;
                while (!f.done()) {
                    const std::string& s = f.peek().text;
                    if (s != "a" && s != "b" && s != "c" && s != "sub" && s != "noise") break;
                    fl.from.push_back(f.take().text);
                }
                if (fl.from.empty()) throw PatchError{line, key.col, "from lists the sources: a, b, c, sub, noise"};
            } else f.unknown(key, "cutoff, res, drive, keytrack and from");
        }
        return;
    }
    if (k == "filters") {
        if (w.size() != 2 || (w[1].text != "serial" && w[1].text != "parallel"))
            throw PatchError{line, head.col, "filters must be serial or parallel"};
        p.parallel = w[1].text == "parallel";
        return;
    }
    if (k == "env") {
        if (w.size() < 2 || w[1].text != "1") {
            if (w.size() >= 2 && (w[1].text == "2" || w[1].text == "3")) later("env 2 and env 3 (modulation)");
            throw PatchError{line, head.col, "env needs its number; env 1 shapes the volume"};
        }
        Fields f(w, 2, line);
        while (!f.done()) {
            const Word& key = f.take();
            if (key.text == "attack") p.env.attack = f.number(key, 0, 20);
            else if (key.text == "decay") p.env.decay = f.number(key, 0, 20);
            else if (key.text == "sustain") p.env.sustain = f.number(key, 0, 1);
            else if (key.text == "release") p.env.release = f.number(key, 0, 20);
            else f.unknown(key, "attack, decay, sustain and release");
        }
        return;
    }
    if (k == "fx") {
        if (w.size() < 2) throw PatchError{line, head.col, "fx needs a type (drive, crush, delay, reverb, comp) or a module's name"};
        Fx x;
        x.line = line;
        const std::string& t = w[1].text;
        // Each built-in effect: its settings, their ranges and defaults.
        struct Setting {
            const char* name;
            double lo, hi, def;
        };
        static const std::map<std::string, std::vector<Setting>> kinds = {
            {"drive", {{"amount", 0, 1, 0.3}}},
            {"crush", {{"bits", 1, 24, 8}}},
            {"delay", {{"time", 0.0625, 4, 0.75}, {"feedback", 0, 0.98, 0.4}, {"mix", 0, 1, 0.3}}},
            {"reverb", {{"size", 0, 1, 0.6}, {"damp", 0, 1, 0.3}, {"mix", 0, 1, 0.25}}},
            {"comp", {{"threshold", -60, 0, -18}, {"ratio", 1, 40, 4}}},
        };
        auto it = kinds.find(t);
        if (it == kinds.end()) {
            if (w.size() > 2) throw PatchError{line, w[2].col, "an effect module takes no settings here; set them in the module"};
            x.module = t;
            p.fx.push_back(x);
            return;
        }
        x.kind = t;
        for (const Setting& s : it->second) x.v[s.name] = s.def;
        Fields f(w, 2, line);
        while (!f.done()) {
            const Word& key = f.take();
            const Setting* s = nullptr;
            for (const Setting& c : it->second)
                if (key.text == c.name) s = &c;
            if (!s) {
                std::string allowed;
                for (const Setting& c : it->second) allowed += (allowed.empty() ? "" : ", ") + std::string(c.name);
                f.unknown(key, allowed);
            }
            x.v[s->name] = f.number(key, s->lo, s->hi);
        }
        p.fx.push_back(x);
        return;
    }
    if (k == "lfo" || k == "macro" || k == "mod") later(k);
    if (k == "table") later("table");
    throw PatchError{line, head.col,
                     "unknown line '" + k + "' (a patch has voices, glide, volume, osc, sub, noise, filter, filters, env and fx lines)"};
}

std::string param(const std::string& name, double v, double lo, double hi, const std::string& tip, double step = 0) {
    return "param " + name + " = " + num(v) + " in " + num(lo) + ".." + num(hi) + (step > 0 ? " step " + num(step) : "") +
           " \"" + tip + "\"\n";
}

std::string generatorCode(const Patch& p) {
    std::string c;
    c += "---\ncaw: 1\nkind: generator\nname: " + p.name + "\n";
    if (!p.summary.empty()) c += "summary: " + p.summary + "\n";
    c += "mode: float\nvoices: " + num(p.voices) + "\n---\n";
    c += "// Generated from the synth patch; edit the patch, not this code.\n";
    std::vector<std::string> sources;  // the sound sources, by patch name
    const char names[3] = {'a', 'b', 'c'};
    for (int i = 0; i < 3; ++i) {
        const Osc& o = p.osc[i];
        if (!o.on) continue;
        const std::string n(1, names[i]);
        const std::string N(1, static_cast<char>(names[i] - 'a' + 'A'));
        c += "// --- Osc " + N + " ---\n";
        c += param(n + "_level", o.level, 0, 1, "Osc " + N + " level");
        c += param(n + "_pos", o.pos, 0, 1, "Osc " + N + " position in the table");
        c += param(n + "_detune", o.detune, 0, 1, "Osc " + N + " unison spread");
        c += param(n + "_pitch", o.octave * 12 + o.semi + o.fine / 100, -72, 72, "Osc " + N + " pitch in semitones", 0.01);
        c += "fn osc_" + n + "(f) = wt(table." + o.table + ", f * pow(2, " + n + "_pitch / 12), " + n + "_pos, " +
             num(o.unison) + ", " + n + "_detune) * " + n + "_level\n";
        sources.push_back(n);
    }
    if (p.sub.on) {
        c += "// --- Sub ---\n";
        c += param("sub_level", p.sub.level, 0, 1, "Sub level");
        c += "fn sub_osc(f) = " + p.sub.shape + "(f * " + num(std::pow(2.0, p.sub.octave)) + ") * sub_level\n";
        sources.push_back("sub");
    }
    if (p.noise.on) {
        c += "// --- Noise ---\n";
        c += param("noise_level", p.noise.level, 0, 1, "Noise level");
        c += param("noise_color", p.noise.color, 0, 1, "Noise brightness: dark 0 .. white 1");
        c += "fn noise_src() = lp1(noise(), 200 + 19800 * noise_color * noise_color) * noise_level\n";
        sources.push_back("noise");
    }
    auto srcCall = [](const std::string& s) {
        if (s == "sub") return std::string("sub_osc(pitch)");
        if (s == "noise") return std::string("noise_src()");
        return "osc_" + s + "(pitch)";
    };
    auto sum = [&](const std::vector<std::string>& list) {
        std::string e;
        for (const std::string& s : list) e += (e.empty() ? "" : " + ") + srcCall(s);
        return e.empty() ? std::string("0") : e;
    };
    for (int i = 0; i < 2; ++i) {
        const Filter& f = p.filter[i];
        if (!f.on) continue;
        const std::string n = "f" + std::to_string(i + 1), N = std::to_string(i + 1);
        c += "// --- Filter " + N + " ---\n";
        c += param(n + "_cutoff", f.cutoff, 20, 20000, "Filter " + N + " cutoff (Hz)", 1);
        c += param(n + "_res", f.res, 0, 1, "Filter " + N + " resonance");
        c += param(n + "_drive", f.drive, 0, 1, "Filter " + N + " drive");
        c += param(n + "_keytrack", f.keytrack, 0, 1, "How far filter " + N + " follows the note");
        c += "fn filt_" + N + "(x) = " + filterFn(f.type) + "(fx.drive(x, 1 + " + n + "_drive * 9), clamp(" + n +
             "_cutoff * pow(2, " + n + "_keytrack * (note - 60) / 12), 20, 20000), 0.5 + " + n + "_res * 19.5)\n";
    }
    c += "// --- Volume ---\n";
    c += param("attack", p.env.attack, 0, 20, "Seconds to full volume");
    c += param("decay", p.env.decay, 0, 20, "Seconds to fall to the sustain level");
    c += param("sustain", p.env.sustain, 0, 1, "Level while the note is held");
    c += param("release", p.env.release, 0, 20, "Seconds to fade after the note ends");
    c += param("volume", p.volume, 0, 1, "Synth volume");
    c += p.glide > 0 ? "let pitch = slew(freq, " + num(p.glide) + ")\n" : "let pitch = freq\n";
    // Routing: each filter takes its sources (by default filter 1 takes them all; in parallel, filter 2 too); in
    // series filter 2 also takes filter 1's output. Sources no filter takes go straight out.
    const Filter& f1 = p.filter[0];
    const Filter& f2 = p.filter[1];
    auto inputs = [&](const Filter& f, bool first) {
        if (f.fromSet) {
            std::vector<std::string> keep;
            for (const std::string& s : f.from)
                for (const std::string& have : sources)
                    if (s == have) keep.push_back(s);
            return keep;
        }
        if (first || p.parallel || !f1.on) return sources;
        return std::vector<std::string>{};
    };
    std::set<std::string> taken;
    std::string out;
    std::vector<std::string> in1 = f1.on ? inputs(f1, true) : std::vector<std::string>{};
    std::vector<std::string> in2 = f2.on ? inputs(f2, false) : std::vector<std::string>{};
    for (const auto& s : in1) taken.insert(s);
    for (const auto& s : in2) taken.insert(s);
    if (f1.on && f2.on && !p.parallel) {
        std::string inner = "filt_1(" + sum(in1) + ")";
        out = "filt_2(" + inner + (in2.empty() ? "" : " + " + sum(in2)) + ")";
    } else {
        if (f1.on) out = "filt_1(" + sum(in1) + ")";
        if (f2.on) out += (out.empty() ? "" : " + ") + std::string("filt_2(") + sum(in2) + ")";
    }
    std::vector<std::string> dry;
    for (const auto& s : sources)
        if (!taken.count(s)) dry.push_back(s);
    if (!dry.empty()) out += (out.empty() ? "" : " + ") + sum(dry);
    if (out.empty()) out = "0";
    c += "let amp = env.adsr(gate, attack, decay, sustain, release) * (0.5 + 0.5 * vel)\n";
    c += "(" + out + ") * amp * volume\n";
    return c;
}

std::string fxCode(const Patch& p, const std::vector<const Fx*>& group, int index) {
    std::string c = "---\ncaw: 1\nkind: effect\nname: " + p.name + " effects " + std::to_string(index) + "\n---\n";
    c += "// Generated from the synth patch; edit the patch, not this code.\n";
    std::map<std::string, int> seen;
    std::string last = "in";
    for (const Fx* x : group) {
        const std::string id = x->kind + "_" + std::to_string(++seen[x->kind]);
        auto v = [&](const char* k) { return x->v.at(k); };
        std::string call;
        if (x->kind == "drive") {
            c += param(id + "_amount", v("amount"), 0, 1, "Drive amount");
            call = "fx.drive(x, 1 + " + id + "_amount * 9)";
        } else if (x->kind == "crush") {
            c += param(id + "_bits", v("bits"), 1, 24, "Crush: bits kept", 1);
            call = "fx.crush(x, " + id + "_bits)";
        } else if (x->kind == "delay") {
            c += param(id + "_time", v("time"), 0.0625, 4, "Delay time in beats");
            c += param(id + "_feedback", v("feedback"), 0, 0.98, "Delay feedback");
            c += param(id + "_mix", v("mix"), 0, 1, "Delay mix");
            call = "fx.delay(x, beats(" + id + "_time), " + id + "_feedback, " + id + "_mix)";
        } else if (x->kind == "reverb") {
            c += param(id + "_size", v("size"), 0, 1, "Reverb size");
            c += param(id + "_damp", v("damp"), 0, 1, "Reverb damping");
            c += param(id + "_mix", v("mix"), 0, 1, "Reverb mix");
            call = "fx.reverb(x, " + id + "_size, " + id + "_damp, " + id + "_mix)";
        } else {
            c += param(id + "_threshold", v("threshold"), -60, 0, "Compressor threshold (dB)");
            c += param(id + "_ratio", v("ratio"), 1, 40, "Compressor ratio");
            call = "fx.comp(x, " + id + "_threshold, " + id + "_ratio)";
        }
        // Each effect is its own fn, named by its kind and count, so hot swap keeps its tail when others change.
        c += "fn fx_" + id + "(x) = " + call + "\n";
        last = "fx_" + id + "(" + last + ")";
    }
    c += last + "\n";
    return c;
}

}  // namespace

SynthResult translateSynth(std::string_view src) {
    SynthResult r;
    Patch p;
    try {
        // The header: like a module's, with kind: synth.
        std::vector<std::string> lines;
        size_t i = 0;
        while (i <= src.size()) {
            size_t e = src.find('\n', i);
            if (e == std::string_view::npos) e = src.size();
            lines.push_back(std::string(src.substr(i, e - i)));
            if (e == src.size()) break;
            i = e + 1;
        }
        size_t at = 0;
        bool isSynth = false;
        if (!lines.empty() && trim(lines[0]) == "---") {
            for (at = 1; at < lines.size() && trim(lines[at]) != "---"; ++at) {
                const std::string l = trim(lines[at]);
                const size_t colon = l.find(':');
                if (colon == std::string::npos) continue;
                const std::string key = trim(l.substr(0, colon)), value = trim(l.substr(colon + 1));
                if (key == "kind") isSynth = value == "synth";
                else if (key == "name") p.name = value;
                else if (key == "summary") p.summary = value;
                else if (key == "caw" && value != "1")
                    throw PatchError{static_cast<int>(at) + 1, 1, "this app reads patch format 1, the file says " + value};
            }
            if (at >= lines.size()) throw PatchError{1, 1, "header starts with '---' but never ends with '---'"};
            ++at;
        }
        if (!isSynth) throw PatchError{1, 1, "a synth patch has 'kind: synth' in its header"};
        // A name only letters, digits, spaces, - and _ keeps the generated header readable.
        for (char& ch : p.name)
            if (ch == '\n' || ch == '\r' || ch == '#') ch = ' ';
        for (char& ch : p.summary)
            if (ch == '\n' || ch == '\r' || ch == '#') ch = ' ';
        // Defaults when a patch says nothing: one saw oscillator into a low-pass filter.
        bool anySource = false;
        for (; at < lines.size(); ++at) {
            const std::vector<Word> w = words(lines[at]);
            if (w.empty()) continue;
            parseLine(p, w, static_cast<int>(at) + 1);
            anySource = anySource || w[0].text == "osc" || w[0].text == "sub" || w[0].text == "noise";
        }
        if (!anySource) p.osc[0].on = true;
        r.name = p.name;
        r.summary = p.summary;
        r.generator = generatorCode(p);
        // Effects in line order: consecutive built-in ones share one generated module; a project module stands alone.
        std::vector<const Fx*> group;
        int groups = 0;
        auto flush = [&] {
            if (group.empty()) return;
            r.fx.push_back({false, fxCode(p, group, ++groups), ""});
            group.clear();
        };
        for (const Fx& x : p.fx) {
            if (x.kind.empty()) {
                flush();
                r.fx.push_back({true, "", x.module});
            } else {
                group.push_back(&x);
            }
        }
        flush();
        r.ok = true;
    } catch (const PatchError& e) {
        r.ok = false;
        r.line = e.line;
        r.col = e.col;
        r.error = "line " + std::to_string(e.line) + ", col " + std::to_string(e.col) + ": " + e.message;
    }
    return r;
}

}  // namespace caw
