// The caw command-line tool: check modules and render modules or projects to WAV (used by CI and AI agents).
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "capi_internal.h"
#include "compile.h"
#include "docs.h"
#include "project.h"
#include "render.h"
#include "wav.h"

namespace {

const char* kUsage =
    "usage:\n"
    "  caw check FILE.caw...                 compile modules; prints errors, exits 1 if any fail\n"
    "  caw render INPUT -o OUT.wav [options] render a module (.caw) or project (.json)\n"
    "      --loop (default)  one exact project loop      --seconds S   free length\n"
    "      --oneshot LAYER   one pass of a layer, trimmed --wavetable MODULE [--param P] [--frames N]\n"
    "      --rate 44100|48000   --float (32-bit float; default 24-bit)\n"
    "      --bpm B --bars N  tempo and loop length when rendering a single module (default 120, 4)\n"
    "      --steps N         a single module's layer length in 16ths (default: the whole loop)\n"
    "  caw templates                         list the bundled starter templates\n"
    "  caw docs [--check] [--dir DIR]        write DIR/library.md and DIR/agent-guide.md (default DIR: docs);\n"
    "                                        --check fails if they're stale, a function is undocumented, or an\n"
    "                                        example doesn't compile or is silent\n";

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

int check(int argc, char** argv) {
    int failed = 0;
    for (int i = 2; i < argc; ++i) {
        std::string src;
        if (!readFile(argv[i], src)) {
            std::printf("%s: can't read the file\n", argv[i]);
            ++failed;
            continue;
        }
        caw::CompileResult r = caw::compileModule(src);
        if (r.program) {
            if (r.program->kind == caw::ModuleKind::Library)
                std::printf("%s: ok (library %s, %zu functions)\n", argv[i], r.program->ns.c_str(),
                            r.program->functions.size());
            else
                std::printf("%s: ok (%s, %zu params)\n", argv[i],
                            r.program->kind == caw::ModuleKind::Effect ? "effect" : "generator",
                            r.program->params.size());
        } else {
            std::printf("%s: %s\n", argv[i], r.error.c_str());
            ++failed;
        }
    }
    if (argc < 3) std::fputs(kUsage, stderr);
    return failed || argc < 3 ? 1 : 0;
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
    double bpm = 120;
    int bars = 4;
    int steps = 0;
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
        else if (a == "--frames") o.frames = std::atoi(val("--frames").c_str());
        else if (a == "--rate") o.sampleRate = std::atoi(val("--rate").c_str());
        else if (a == "--float") floatOut = true;
        else if (a == "--bpm") bpm = std::atof(val("--bpm").c_str());
        else if (a == "--bars") bars = std::atoi(val("--bars").c_str());
        else if (a == "--steps") steps = std::atoi(val("--steps").c_str());
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
    if (endsWith(input, ".json")) {
        std::string err;
        if (!caw::parseProject(text, p, err)) {
            std::fprintf(stderr, "%s: %s\n", input.c_str(), err.c_str());
            return 1;
        }
    } else {
        p = caw::singleModuleProject(text, bpm, bars);
        p.layers[0].lengthSteps = steps;
        if (o.kind == caw::ExportKind::Wavetable || o.kind == caw::ExportKind::OneShot)
            o.target = o.kind == caw::ExportKind::Wavetable ? "m" : "l";
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
    std::string err;
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

}  // namespace

std::string today() {
    const auto days = std::chrono::floor<std::chrono::days>(std::chrono::system_clock::now());
    const std::chrono::year_month_day ymd{days};
    char buf[16];
    std::snprintf(buf, sizeof buf, "%04d-%02u-%02u", static_cast<int>(ymd.year()), static_cast<unsigned>(ymd.month()),
                  static_cast<unsigned>(ymd.day()));
    return buf;
}

// A generated note keeps its `updated:` date unless its content changes.
std::string updatedOf(const std::string& text) {
    const size_t p = text.find("\nupdated: ");
    return p == std::string::npos ? "" : text.substr(p + 10, 10);
}

int docs(int argc, char** argv) {
    bool check = false;
    std::string dir = "docs";
    for (int i = 2; i < argc; ++i) {
        const std::string a = argv[i];
        if (a == "--check") check = true;
        else if (a == "--dir" && i + 1 < argc) dir = argv[++i];
        else {
            std::fputs(kUsage, stderr);
            return 2;
        }
    }
    int bad = 0;
    for (const std::string& problem : caw::checkLibrary()) {
        std::printf("FAIL %s\n", problem.c_str());
        ++bad;
    }
    struct Out {
        const char* file;
        std::string (*make)(const std::string&);
    };
    for (const Out& out : {Out{"library.md", caw::libraryReference}, Out{"agent-guide.md", caw::agentGuide}}) {
        const std::string path = dir + "/" + out.file;
        std::string old;
        readFile(path, old);
        const std::string keep = updatedOf(old);
        const bool same = !keep.empty() && out.make(keep) == old;
        if (same) {
            std::printf("ok   %s is up to date\n", path.c_str());
            continue;
        }
        if (check) {
            std::printf("FAIL %s is stale: run caw docs and commit it\n", path.c_str());
            ++bad;
            continue;
        }
        std::string err;
        const std::string text = out.make(today());
        if (!caw::writeFile(path, std::vector<uint8_t>(text.begin(), text.end()), err)) {
            std::fprintf(stderr, "%s\n", err.c_str());
            return 1;
        }
        std::printf("wrote %s\n", path.c_str());
    }
    return bad ? 1 : 0;
}

int main(int argc, char** argv) {
    if (argc < 2) {
        std::fputs(kUsage, stderr);
        return 2;
    }
    const std::string cmd = argv[1];
    if (cmd == "check") return check(argc, argv);
    if (cmd == "render") return render(argc, argv);
    if (cmd == "docs") return docs(argc, argv);
    if (cmd == "templates") {
        for (int i = 0; i < caw::kTemplateCount; ++i) std::printf("%s\n", caw::kTemplateFiles[i]);
        return 0;
    }
    std::fputs(kUsage, stderr);
    return 2;
}
