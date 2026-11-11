// The caw command-line tool: render projects to WAV, move patterns to and from MIDI files, test C++ components and
// make sample packs (used by CI and AI agents).
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "component_test.h"
#include "json.h"
#include "midifile.h"
#include "pattern.h"
#include "project.h"
#include "render.h"
#include "sample_pack.h"
#include "wav.h"

namespace {

const char* kUsage =
    "usage:\n"
    "  caw render PROJECT.json -o OUT.wav [options]  render a project\n"
    "      --loop (default)  one exact project loop      --seconds S   free length\n"
    "      --oneshot LAYER   one pass of a layer, trimmed; a C++ instrument layer with no notes plays one\n"
    "                        [--note N (60)] [--velocity 0..1 (1)] [--note-seconds S (0.5)] to its tail\n"
    "      --wavetable TARGET [--param P] [--frames N]  TARGET: a C++ instrument layer or a built-in\n"
    "                        instrument id; P is swept over its range across the frames\n"
    "      --rate 44100|48000   --float (32-bit float; default 24-bit)\n"
    "  caw midi import IN.mid -o OUT.caw     a MIDI file (.mid, or a MIDI 2.0 clip .midi2) as a pattern\n"
    "      --track N (0-based; default all)  --channel C (1-16; default all)  --name NAME\n"
    "      --no-bend (ignore pitch bend)     --no-slides (keep legato overlaps as notes)\n"
    "  caw midi export PATTERN.caw -o OUT.mid|OUT.midi2 [--bpm B] [--beats N] [--clip]\n"
    "      a pattern as a MIDI 1.0 file, or a MIDI 2.0 clip file with --clip or a .midi2 name\n"
    "      (default 120 BPM, 4 beats per bar)\n"

    "  caw test-component ID|LIBRARY [options]  render a C++ effect offline with a test signal and print its\n"
    "                                        measurements (JSON by default; docs/engine.md \"Component testing\")\n"
    "      --id ID --trust trusted|isolated|blocked   for a built LIBRARY (required: no default trust)\n"
    "      --signal impulse|sine|sweep|white|pink|silence|dc|wav (default sine)  --file IN.wav (wav)\n"
    "      --freq HZ --level DB --seconds S --seed N --decorrelated --from-freq HZ --to-freq HZ\n"
    "      --rate R --block N --tail S --tempo BPM --param NAME=VALUE (repeatable)\n"
    "      --sweep PARAM [--steps N] [--from A] [--to B]   render once per value of a parameter\n"
    "      --compare ID|LIBRARY [--compare-id ID --compare-trust T]   null test against another component or build\n"
    "      --bypass (null test against the dry input)  --align none|declared|measured (default declared)\n"
    "      --wav OUT.wav --input-wav IN.wav --no-cpu --fft N --request FILE.json (the request as JSON)\n"
    "      --report json|text  --strict (exit 1 when the result has warnings; a request's failed checks exit 1)\n"
    "  caw sample-pack [INSTRUMENT] --out DIR [options]  render an instrument over notes, velocities and parameter\n"
    "                                        steps to named WAV files plus a manifest (docs/engine.md \"Sample packs\")\n"
    "      --request FILE.json (the request as JSON; the options below override its keys)\n"
    "      --library PATH --trust trusted|isolated|blocked   for an instrument or effect in a built library\n"
    "      --effect ID (repeatable, in order)  --set NAME=VALUE (an instrument parameter; repeatable)\n"
    "      --notes C3,E3,60 | FROM:TO[:STEP]   --vel 64,127   --step NAME=V1,V2,... (repeatable)\n"
    "      --name NAME --pattern '{name}_{note}_{vel}_{param}'  --hold S --max S --tail-db DB\n"
    "      --rate R --bits 16|24|32 --mono --trim-db DB --no-trim --fade-in MS --fade-out MS\n"
    "      --normalize peak|rms [--target DB] [--group]  --loop  --loop-xfade MS  --rr N  --dither tpdf\n"
    "      --sfz  --max-files N  --overwrite\n";

bool readFile(const std::string& path, std::string& out) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return false;
    std::ostringstream ss;
    ss << f.rdbuf();
    out = ss.str();
    return true;
}

bool endsWith(const std::string& s, const char* suffix) {
    const size_t n = std::strlen(suffix);
    return s.size() >= n && s.compare(s.size() - n, n, suffix) == 0;
}

double db(double v) { return v > 0 ? 20.0 * std::log10(v) : -999.0; }

int render(int argc, char** argv) {
    if (argc < 3) {
        std::fputs(kUsage, stderr);
        return 2;
    }
    const std::string input = argv[2];
    std::string out;
    caw::ExportOptions o;
    bool floatOut = false;
    for (int i = 3; i < argc; ++i) {
        const std::string a = argv[i];
        auto val = [&](const char* name) -> std::string {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "%s needs a value\n", name);
                std::exit(2);
            }
            return argv[++i];
        };
        if (a == "-o") out = val("-o");
        else if (a == "--loop") o.kind = caw::ExportKind::Loop;
        else if (a == "--seconds") {
            o.kind = caw::ExportKind::Free;
            o.seconds = std::atof(val("--seconds").c_str());
        } else if (a == "--oneshot") {
            o.kind = caw::ExportKind::OneShot;
            o.target = val("--oneshot");
        } else if (a == "--wavetable") {
            o.kind = caw::ExportKind::Wavetable;
            o.target = val("--wavetable");
        } else if (a == "--param") o.param = val("--param");
        else if (a == "--note") o.note = std::atof(val("--note").c_str());
        else if (a == "--velocity") o.velocity = std::atof(val("--velocity").c_str());
        else if (a == "--note-seconds") o.noteSeconds = std::atof(val("--note-seconds").c_str());
        else if (a == "--frames") o.frames = std::atoi(val("--frames").c_str());
        else if (a == "--rate") o.sampleRate = std::atoi(val("--rate").c_str());
        else if (a == "--float") floatOut = true;
        else {
            std::fprintf(stderr, "unknown option %s\n%s", a.c_str(), kUsage);
            return 2;
        }
    }
    if (out.empty()) {
        std::fputs("render needs -o OUT.wav\n", stderr);
        return 2;
    }
    std::string text;
    if (!readFile(input, text)) {
        std::fprintf(stderr, "%s: can't read the file\n", input.c_str());
        return 1;
    }
    caw::ProjectSpec p;
    std::string err;
    if (!caw::parseProject(text, p, err)) {
        std::fprintf(stderr, "%s: %s\n", input.c_str(), err.c_str());
        return 1;
    }
    caw::RenderResult r;
    if (!caw::renderExport(p, o, r)) {
        std::fprintf(stderr, "%s: %s\n", input.c_str(), r.error.c_str());
        return 1;
    }
    caw::WavSpec spec;
    spec.sampleRate = r.sampleRate;
    spec.channels = r.channels;
    spec.float32 = floatOut || o.kind == caw::ExportKind::Wavetable;
    spec.loop = r.loop;
    if (!caw::writeFile(out, caw::encodeWav(spec, r.samples.data(), r.frames), err)) {
        std::fprintf(stderr, "%s\n", err.c_str());
        return 1;
    }
    double peak = 0, sum = 0;
    for (float v : r.samples) {
        peak = std::fmax(peak, std::fabs(v));
        sum += static_cast<double>(v) * v;
    }
    const double rms = r.samples.empty() ? 0 : std::sqrt(sum / r.samples.size());
    std::printf("%s: %lld frames (%.3f s) at %d Hz, peak %.1f dBFS, rms %.1f dBFS%s%s\n", out.c_str(),
                static_cast<long long>(r.frames), static_cast<double>(r.frames) / r.sampleRate, r.sampleRate, db(peak),
                db(rms), peak < 1e-4 ? ", SILENT" : "", peak >= 0.999 && o.kind != caw::ExportKind::Wavetable ? ", CLIPPING" : "");
    return 0;
}

int midi(int argc, char** argv) {
    if (argc < 4 || (std::strcmp(argv[2], "import") != 0 && std::strcmp(argv[2], "export") != 0)) {
        std::fputs(kUsage, stderr);
        return 2;
    }
    const bool import = std::strcmp(argv[2], "import") == 0;
    const std::string input = argv[3];
    std::string out;
    caw::MidiImportOptions opts;
    double bpm = 120;
    int beats = 4;
    bool clip = false;
    for (int i = 4; i < argc; ++i) {
        const std::string a = argv[i];
        auto val = [&](const char* name) -> std::string {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "%s needs a value\n", name);
                std::exit(2);
            }
            return argv[++i];
        };
        if (a == "-o") out = val("-o");
        else if (import && a == "--track") opts.track = std::atoi(val("--track").c_str());
        else if (import && a == "--channel") opts.channel = std::atoi(val("--channel").c_str()) - 1;
        else if (import && a == "--name") opts.name = val("--name");
        else if (import && a == "--no-bend") opts.pitchBend = false;
        else if (import && a == "--no-slides") opts.legatoSlides = false;
        else if (!import && a == "--bpm") bpm = std::atof(val("--bpm").c_str());
        else if (!import && a == "--beats") beats = std::atoi(val("--beats").c_str());
        else if (!import && a == "--clip") clip = true;
        else {
            std::fprintf(stderr, "unknown option %s\n%s", a.c_str(), kUsage);
            return 2;
        }
    }
    if (out.empty()) {
        std::fputs(import ? "midi import needs -o OUT.caw\n" : "midi export needs -o OUT.mid\n", stderr);
        return 2;
    }
    std::string data;
    if (!readFile(input, data)) {
        std::fprintf(stderr, "%s: can't read the file\n", input.c_str());
        return 1;
    }
    std::string err;
    if (import) {
        const std::string text =
            caw::patternFromMidi(reinterpret_cast<const uint8_t*>(data.data()), data.size(), opts, err);
        if (text.empty()) {
            std::fprintf(stderr, "%s: %s\n", input.c_str(), err.c_str());
            return 1;
        }
        if (!caw::writeFile(out, std::vector<uint8_t>(text.begin(), text.end()), err)) {
            std::fprintf(stderr, "%s\n", err.c_str());
            return 1;
        }
        const caw::PatternResult pr = caw::parsePattern(text);
        std::printf("%s: %zu notes, %d steps\n", out.c_str(), pr.pattern ? pr.pattern->notes.size() : 0,
                    pr.pattern ? pr.pattern->lengthSteps : 0);
        return 0;
    }
    if (!(bpm >= 20 && bpm <= 400) || beats < 1 || beats > 16) {
        std::fputs("--bpm must be 20 to 400 and --beats 1 to 16\n", stderr);
        return 2;
    }
    const caw::PatternResult pr = caw::parsePattern(data);
    if (!pr.pattern) {
        std::fprintf(stderr, "%s: %s\n", input.c_str(), pr.error.c_str());
        return 1;
    }
    clip = clip || endsWith(out, ".midi2");
    const std::vector<uint8_t> bytes =
        clip ? caw::patternToMidiClip(*pr.pattern, bpm, beats) : caw::patternToSmf(*pr.pattern, bpm, beats);
    if (!caw::writeFile(out, bytes, err)) {
        std::fprintf(stderr, "%s\n", err.c_str());
        return 1;
    }
    std::printf("%s: %s, %zu notes, %zu bytes\n", out.c_str(), clip ? "MIDI 2.0 clip" : "MIDI file",
                pr.pattern->notes.size(), bytes.size());
    return 0;
}

}  // namespace

bool isLibraryPath(const std::string& s) {
    return s.find('/') != std::string::npos || s.find('\\') != std::string::npos || endsWith(s, ".so") ||
           endsWith(s, ".dll") || endsWith(s, ".dylib");
}

std::string componentJson(const std::string& target, const std::string& id, const std::string& trust,
                          const std::string& params) {
    std::string j = "{";
    if (isLibraryPath(target)) {
        // A bare file name would make the system loader search its library path, not this directory.
        const bool bare = target.find('/') == std::string::npos && target.find('\\') == std::string::npos;
        j += "\"id\":\"" + caw::jsonEscape(id) + "\",\"library\":\"" + caw::jsonEscape(bare ? "./" + target : target) + "\"";
        if (!trust.empty()) j += ",\"trust\":\"" + caw::jsonEscape(trust) + "\"";
    } else {
        j += "\"id\":\"" + caw::jsonEscape(target) + "\"";
    }
    if (!params.empty()) j += ",\"params\":{" + params + "}";
    return j + "}";
}

// The result as a few readable lines (the JSON holds everything).
void printTextReport(const caw::Json& r) {
    const caw::Json* c = r.get("component");
    const caw::Json* out = r.get("output");
    std::printf("%s (%s)\n", c ? c->string("id").c_str() : "?", c ? c->string("role").c_str() : "?");
    auto db = [](const caw::Json* j, const char* k) {
        const caw::Json* v = j ? j->get(k) : nullptr;
        static char buf[4][32];
        static int at = 0;
        char* b = buf[at++ % 4];
        if (!v || v->type != caw::Json::Type::Number) std::snprintf(b, 32, "-inf");
        else std::snprintf(b, 32, "%.2f", v->num);
        return b;
    };
    if (out) {
        if (const caw::Json* ch = out->get("channels"))
            for (std::size_t i = 0; i < ch->arr.size(); ++i)
                std::printf("  %s: peak %s dBFS, rms %s dBFS, gain %s dB\n", i ? "right" : "left ",
                            db(&ch->arr[i], "peak_db"), db(&ch->arr[i], "rms_db"), db(&ch->arr[i], "gain_db"));
        if (const caw::Json* t = out->get("thd"); t && t->type == caw::Json::Type::Object)
            if (const caw::Json* l = t->get("left"); l && l->type == caw::Json::Type::Object)
                std::printf("  THD %.5f %%, THD+N %.5f %% (left)\n", l->number("thd_percent", 0),
                            l->number("thd_n_percent", 0));
        if (const caw::Json* ir = out->get("impulse_response"); ir && ir->type == caw::Json::Type::Object)
            std::printf("  impulse response %.0f frames (%.1f ms)%s\n", ir->number("length_frames", 0),
                        ir->number("length_ms", 0), ir->boolean("truncated", false) ? ", truncated" : "");
        if (const caw::Json* l = out->get("latency")) {
            const caw::Json* m = l->get("measured");
            if (m && m->type == caw::Json::Type::Number)
                std::printf("  latency %.0f frames measured, %.0f declared\n", m->num, l->number("declared", 0));
        }
        if (const caw::Json* t = out->get("tail"); t && t->type == caw::Json::Type::Object)
            std::printf("  tail %.0f frames measured%s\n", t->number("measured", 0),
                        t->boolean("within_declared", true) ? "" : " (longer than declared)");
    }
    if (const caw::Json* cpu = r.get("cpu"))
        std::printf("  cpu per block: median %.2f us (%.3f %%), worst %.2f us (%.3f %%)\n", cpu->number("median_us", 0),
                    cpu->number("median_percent", 0), cpu->number("worst_us", 0), cpu->number("worst_percent", 0));
    for (const char* k : {"bypass", "compare"})
        if (const caw::Json* n = r.get(k))
            std::printf("  %s null: %s, difference peak %s dB, rms %s dB\n", k,
                        n->boolean("exact", false) ? "exact" : "not exact", db(n, "difference_peak_db"),
                        db(n, "difference_rms_db"));
    if (const caw::Json* s = r.get("sweep"))
        if (const caw::Json* pts = s->get("points"))
            for (const caw::Json& p : pts->arr) {
                const caw::Json* ch = p.get("channels");
                std::printf("  %s = %g: peak %s dBFS, rms %s dBFS\n", s->string("param").c_str(), p.number("value", 0),
                            ch && !ch->arr.empty() ? db(&ch->arr[0], "peak_db") : "?",
                            ch && !ch->arr.empty() ? db(&ch->arr[0], "rms_db") : "?");
            }
    if (const caw::Json* w = r.get("warnings"))
        for (const caw::Json& x : w->arr) std::printf("  warning: %s\n", x.str.c_str());
    if (const caw::Json* c = r.get("checks")) {
        for (const caw::Json& x : c->arr) {
            const caw::Json* v = x.get("value");
            std::printf("  check %s: %s (%s)\n", x.string("path").c_str(), x.boolean("pass", false) ? "pass" : "FAIL",
                        v && v->type == caw::Json::Type::Number ? std::to_string(v->num).c_str()
                        : v && v->type == caw::Json::Type::Bool ? (v->b ? "true" : "false")
                                                                 : "missing");
        }
        std::printf("  %s\n", r.boolean("passed", false) ? "all checks passed" : "checks FAILED");
    }
}

int testComponent(int argc, char** argv) {
    if (argc < 3) {
        std::fputs(kUsage, stderr);
        return 2;
    }
    std::string target, id, trust, compare, compareId, compareTrust, params, requestFile, report = "json";
    std::string signal = "{\"type\":\"sine\"", top, sweep;
    bool strict = false;
    for (int i = 2; i < argc; ++i) {
        const std::string a = argv[i];
        auto val = [&](const char* name) -> std::string {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "%s needs a value\n", name);
                std::exit(2);
            }
            return argv[++i];
        };
        auto numberArg = [&](const char* name) {
            const std::string v = val(name);
            char* end = nullptr;
            const double d = std::strtod(v.c_str(), &end);
            if (v.empty() || *end != '\0' || !std::isfinite(d)) {
                std::fprintf(stderr, "%s needs a number\n", name);
                std::exit(2);
            }
            return v;
        };
        auto str = [](const std::string& v) { return "\"" + caw::jsonEscape(v) + "\""; };
        if (a == "--id") id = val("--id");
        else if (a == "--trust") trust = val("--trust");
        else if (a == "--signal") {
            const std::string t = val("--signal");
            signal = "{\"type\":" + str(t == "noise" ? "white" : t);
        } else if (a == "--freq") signal += ",\"frequency\":" + numberArg("--freq");
        else if (a == "--from-freq") signal += ",\"start_frequency\":" + numberArg("--from-freq");
        else if (a == "--to-freq") signal += ",\"end_frequency\":" + numberArg("--to-freq");
        else if (a == "--level") signal += ",\"level_db\":" + numberArg("--level");
        else if (a == "--seconds") signal += ",\"seconds\":" + numberArg("--seconds");
        else if (a == "--seed") signal += ",\"seed\":" + numberArg("--seed");
        else if (a == "--decorrelated") signal += ",\"decorrelated\":true";
        else if (a == "--file") signal += ",\"path\":" + str(val("--file"));
        else if (a == "--rate") top += ",\"sample_rate\":" + numberArg("--rate");
        else if (a == "--block") top += ",\"block_size\":" + numberArg("--block");
        else if (a == "--tail") top += ",\"tail_seconds\":" + numberArg("--tail");
        else if (a == "--tempo") top += ",\"tempo\":" + numberArg("--tempo");
        else if (a == "--fft") top += ",\"fft_size\":" + numberArg("--fft");
        else if (a == "--align") top += ",\"align\":" + str(val("--align"));
        else if (a == "--bypass") top += ",\"bypass\":true";
        else if (a == "--no-cpu") top += ",\"cpu\":false";
        else if (a == "--wav") top += ",\"write_wav\":" + str(val("--wav"));
        else if (a == "--input-wav") top += ",\"write_input_wav\":" + str(val("--input-wav"));
        else if (a == "--param") {
            const std::string p = val("--param");
            const size_t eq = p.find('=');
            char* end = nullptr;
            const std::string v = eq == std::string::npos ? "" : p.substr(eq + 1);
            const double d = std::strtod(v.c_str(), &end);
            if (eq == std::string::npos || eq == 0 || v.empty() || *end != '\0' || !std::isfinite(d)) {
                std::fprintf(stderr, "--param needs NAME=VALUE\n");
                return 2;
            }
            params += (params.empty() ? "" : ",") + str(p.substr(0, eq)) + ":" + v;
        } else if (a == "--sweep") sweep += (sweep.empty() ? "" : ",") + std::string("\"param\":") + str(val("--sweep"));
        else if (a == "--steps") sweep += (sweep.empty() ? "" : ",") + std::string("\"steps\":") + numberArg("--steps");
        else if (a == "--from") sweep += (sweep.empty() ? "" : ",") + std::string("\"from\":") + numberArg("--from");
        else if (a == "--to") sweep += (sweep.empty() ? "" : ",") + std::string("\"to\":") + numberArg("--to");
        else if (a == "--compare") compare = val("--compare");
        else if (a == "--compare-id") compareId = val("--compare-id");
        else if (a == "--compare-trust") compareTrust = val("--compare-trust");
        else if (a == "--request") requestFile = val("--request");
        else if (a == "--report") report = val("--report");
        else if (a == "--strict") strict = true;
        else if (target.empty() && a.rfind("--", 0) != 0) target = a;
        else {
            std::fprintf(stderr, "unknown option %s\n", a.c_str());
            return 2;
        }
    }
    if (report != "json" && report != "text") {
        std::fputs("--report must be json or text\n", stderr);
        return 2;
    }
    std::string request;
    if (!requestFile.empty()) {
        if (!readFile(requestFile, request)) {
            std::fprintf(stderr, "can't read %s\n", requestFile.c_str());
            return 1;
        }
    } else {
        if (target.empty()) {
            std::fputs("test-component needs a component id or library\n", stderr);
            return 2;
        }
        if (isLibraryPath(target) && id.empty()) {
            std::fputs("a library needs --id (the component's id) and --trust\n", stderr);
            return 2;
        }
        request = "{\"component\":" + componentJson(target, id, trust, params) + ",\"signal\":" + signal + "}" + top;
        if (!compare.empty())
            request += ",\"compare\":" + componentJson(compare, compareId.empty() ? id : compareId,
                                                       compareTrust.empty() ? trust : compareTrust, "");
        if (!sweep.empty()) request += ",\"sweep\":{" + sweep + "}";
        request += "}";
    }
    const std::string result = caw::componentTestJson(request);
    caw::Json parsed;
    std::string err;
    const bool parsedOk = caw::parseJson(result, parsed, err);
    const bool ok = parsedOk && parsed.boolean("ok", false);
    if (report == "json" || !ok) std::printf("%s\n", result.c_str());
    else printTextReport(parsed);
    if (!ok) return 1;
    if (!parsed.boolean("passed", true)) return 1;  // a request's checks (thresholds) failed
    const caw::Json* warnings = parsed.get("warnings");
    return strict && warnings && !warnings->arr.empty() ? 1 : 0;
}

// The JSON text of a parsed value (for the merged sample-pack request).
std::string jsonText(const caw::Json& j) {
    switch (j.type) {
        case caw::Json::Type::Null: return "null";
        case caw::Json::Type::Bool: return j.b ? "true" : "false";
        case caw::Json::Type::Number: {
            char buf[40];
            std::snprintf(buf, sizeof buf, "%.17g", j.num);
            return buf;
        }
        case caw::Json::Type::String: return "\"" + caw::jsonEscape(j.str) + "\"";
        case caw::Json::Type::Array: {
            std::string s = "[";
            for (std::size_t i = 0; i < j.arr.size(); ++i) s += (i ? "," : "") + jsonText(j.arr[i]);
            return s + "]";
        }
        case caw::Json::Type::Object: {
            std::string s = "{";
            bool first = true;
            for (const auto& [k, v] : j.obj) {
                s += (first ? "\"" : ",\"") + caw::jsonEscape(k) + "\":" + jsonText(v);
                first = false;
            }
            return s + "}";
        }
    }
    return "null";
}

caw::Json jsonNumber(double v) {
    caw::Json j;
    j.type = caw::Json::Type::Number;
    j.num = v;
    return j;
}
caw::Json jsonString(const std::string& v) {
    caw::Json j;
    j.type = caw::Json::Type::String;
    j.str = v;
    return j;
}
caw::Json jsonBool(bool v) {
    caw::Json j;
    j.type = caw::Json::Type::Bool;
    j.b = v;
    return j;
}

// "a,b,c" as JSON values: numbers where they parse, note names (strings) otherwise.
bool listArg(const std::string& text, caw::Json& out) {
    out = caw::Json{};
    out.type = caw::Json::Type::Array;
    std::size_t at = 0;
    while (at <= text.size()) {
        const std::size_t comma = std::min(text.find(',', at), text.size());
        const std::string item = text.substr(at, comma - at);
        if (item.empty()) return false;
        char* end = nullptr;
        const double d = std::strtod(item.c_str(), &end);
        out.arr.push_back(*end == '\0' && std::isfinite(d) ? jsonNumber(d) : jsonString(item));
        at = comma + 1;
    }
    return !out.arr.empty();
}

int samplePack(int argc, char** argv) {
    caw::Json req;
    req.type = caw::Json::Type::Object;
    std::string requestFile, instrument, library, trust;
    std::vector<std::string> effects;
    std::vector<std::pair<std::string, double>> sets;
    std::vector<std::pair<std::string, caw::Json>> steps;
    caw::Json normalize;
    normalize.type = caw::Json::Type::Object;
    std::vector<std::pair<const char*, caw::Json>> top;
    for (int i = 2; i < argc; ++i) {
        const std::string a = argv[i];
        auto val = [&](const char* name) -> std::string {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "%s needs a value\n", name);
                std::exit(2);
            }
            return argv[++i];
        };
        auto num = [&](const char* name) {
            const std::string v = val(name);
            char* end = nullptr;
            const double d = std::strtod(v.c_str(), &end);
            if (v.empty() || *end != '\0' || !std::isfinite(d)) {
                std::fprintf(stderr, "%s needs a number\n", name);
                std::exit(2);
            }
            return jsonNumber(d);
        };
        if (a == "--request") requestFile = val("--request");
        else if (a == "--out") top.emplace_back("output_dir", jsonString(val("--out")));
        else if (a == "--library") library = val("--library");
        else if (a == "--trust") trust = val("--trust");
        else if (a == "--effect") effects.push_back(val("--effect"));
        else if (a == "--name") top.emplace_back("name", jsonString(val("--name")));
        else if (a == "--pattern") top.emplace_back("name_pattern", jsonString(val("--pattern")));
        else if (a == "--hold") top.emplace_back("hold_seconds", num("--hold"));
        else if (a == "--max") top.emplace_back("max_seconds", num("--max"));
        else if (a == "--tail-db") top.emplace_back("tail_threshold_db", num("--tail-db"));
        else if (a == "--rate") top.emplace_back("sample_rate", num("--rate"));
        else if (a == "--bits") top.emplace_back("bit_depth", num("--bits"));
        else if (a == "--mono") top.emplace_back("channels", jsonNumber(1));
        else if (a == "--fade-in") top.emplace_back("fade_in_ms", num("--fade-in"));
        else if (a == "--fade-out") top.emplace_back("fade_out_ms", num("--fade-out"));
        else if (a == "--max-files") top.emplace_back("max_files", num("--max-files"));
        else if (a == "--loop") top.emplace_back("loop", jsonBool(true));
        else if (a == "--loop-xfade") {  // a loop whose seam is crossfaded over MS
            caw::Json l;
            l.type = caw::Json::Type::Object;
            l.obj["crossfade_ms"] = num("--loop-xfade");
            top.emplace_back("loop", l);
        } else if (a == "--rr") top.emplace_back("round_robins", num("--rr"));
        else if (a == "--dither") top.emplace_back("dither", jsonString(val("--dither")));
        else if (a == "--sfz") top.emplace_back("sfz", jsonBool(true));
        else if (a == "--overwrite") top.emplace_back("overwrite", jsonBool(true));
        else if (a == "--no-trim") top.emplace_back("trim", jsonBool(false));
        else if (a == "--trim-db") {
            caw::Json t;
            t.type = caw::Json::Type::Object;
            t.obj["threshold_db"] = num("--trim-db");
            top.emplace_back("trim", t);
        } else if (a == "--normalize") normalize.obj["mode"] = jsonString(val("--normalize"));
        else if (a == "--target") normalize.obj["target_db"] = num("--target");
        else if (a == "--group") normalize.obj["scope"] = jsonString("group");
        else if (a == "--vel" || a == "--notes") {
            const std::string v = val(a.c_str());
            caw::Json list;
            const std::size_t colon = v.find(':');
            if (a == "--notes" && colon != std::string::npos) {
                list.type = caw::Json::Type::Object;
                caw::Json parts;
                std::string range = v;
                for (char& c : range)
                    if (c == ':') c = ',';
                if (!listArg(range, parts) || parts.arr.size() < 2 || parts.arr.size() > 3) {
                    std::fputs("--notes needs FROM:TO[:STEP]\n", stderr);
                    return 2;
                }
                list.obj["from"] = parts.arr[0];
                list.obj["to"] = parts.arr[1];
                if (parts.arr.size() == 3) list.obj["step"] = parts.arr[2];
            } else if (!listArg(v, list)) {
                std::fprintf(stderr, "%s needs a comma-separated list\n", a.c_str());
                return 2;
            }
            top.emplace_back(a == "--vel" ? "velocities" : "notes", list);
        } else if (a == "--set" || a == "--step") {
            const std::string p = val(a.c_str());
            const std::size_t eq = p.find('=');
            caw::Json list;
            if (eq == std::string::npos || eq == 0 || !listArg(p.substr(eq + 1), list)) {
                std::fprintf(stderr, "%s needs NAME=VALUE%s\n", a.c_str(), a == "--step" ? "[,VALUE...]" : "");
                return 2;
            }
            for (const caw::Json& x : list.arr)
                if (x.type != caw::Json::Type::Number) {
                    std::fprintf(stderr, "%s values must be numbers\n", a.c_str());
                    return 2;
                }
            if (a == "--set") {
                if (list.arr.size() != 1) {
                    std::fputs("--set takes one value (use --step for several)\n", stderr);
                    return 2;
                }
                sets.emplace_back(p.substr(0, eq), list.arr[0].num);
            } else {
                steps.emplace_back(p.substr(0, eq), list);
            }
        } else if (instrument.empty() && a.rfind("--", 0) != 0) instrument = a;
        else {
            std::fprintf(stderr, "unknown option %s\n", a.c_str());
            return 2;
        }
    }
    if (!requestFile.empty()) {
        std::string text, err;
        if (!readFile(requestFile, text)) {
            std::fprintf(stderr, "can't read %s\n", requestFile.c_str());
            return 1;
        }
        if (!caw::parseJson(text, req, err) || req.type != caw::Json::Type::Object) {
            std::fprintf(stderr, "%s: %s\n", requestFile.c_str(), err.empty() ? "not a JSON object" : err.c_str());
            return 1;
        }
    }
    for (auto& [k, v] : top) req.obj[k] = v;
    if (!instrument.empty() || !library.empty() || !sets.empty()) {
        caw::Json inst;
        if (const caw::Json* old = req.get("instrument")) inst = *old;
        if (inst.type == caw::Json::Type::String) {
            const std::string id = inst.str;
            inst = caw::Json{};
            inst.type = caw::Json::Type::Object;
            inst.obj["id"] = jsonString(id);
        }
        inst.type = caw::Json::Type::Object;
        if (!instrument.empty()) inst.obj["id"] = jsonString(instrument);
        if (!library.empty()) {  // a bare file name would make the system loader search its path, not this directory
            const bool bare = library.find('/') == std::string::npos && library.find('\\') == std::string::npos;
            inst.obj["library"] = jsonString(bare ? "./" + library : library);
        }
        if (!sets.empty()) {
            caw::Json& params = inst.obj["params"];
            params.type = caw::Json::Type::Object;
            for (const auto& [k, v] : sets) params.obj[k] = jsonNumber(v);
        }
        req.obj["instrument"] = inst;
    }
    if (!effects.empty()) {
        caw::Json fx;
        fx.type = caw::Json::Type::Array;
        for (const std::string& e : effects) fx.arr.push_back(jsonString(e));
        req.obj["effects"] = fx;
    }
    if (!steps.empty()) {
        caw::Json axes;
        axes.type = caw::Json::Type::Array;
        for (const auto& [id, values] : steps) {
            caw::Json axis;
            axis.type = caw::Json::Type::Object;
            axis.obj["id"] = jsonString(id);
            axis.obj["values"] = values;
            axes.arr.push_back(axis);
        }
        req.obj["params"] = axes;
    }
    if (!normalize.obj.empty()) req.obj["normalize"] = normalize;
    caw::NativeModuleTrust level = caw::NativeModuleTrust::Blocked;  // no --trust: no library loads
    if (trust == "trusted") level = caw::NativeModuleTrust::Trusted;
    else if (trust == "isolated") level = caw::NativeModuleTrust::Isolated;
    else if (!trust.empty() && trust != "blocked") {
        std::fputs("--trust must be trusted, isolated or blocked\n", stderr);
        return 2;
    }
    if (!req.get("instrument") || !req.get("output_dir")) {
        std::fputs("sample-pack needs an instrument and --out DIR (or a --request file with them)\n", stderr);
        return 2;
    }
    const std::string result = caw::samplePackJson(jsonText(req), level);
    std::printf("%s\n", result.c_str());
    caw::Json parsed;
    std::string err;
    return caw::parseJson(result, parsed, err) && parsed.boolean("ok", false) ? 0 : 1;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fputs(kUsage, stderr);
        return 2;
    }
    const std::string cmd = argv[1];
    if (cmd == "render") return render(argc, argv);
    if (cmd == "midi") return midi(argc, argv);
    if (cmd == "test-component") return testComponent(argc, argv);
    if (cmd == "sample-pack") return samplePack(argc, argv);
    std::fputs(kUsage, stderr);
    return 2;
}
