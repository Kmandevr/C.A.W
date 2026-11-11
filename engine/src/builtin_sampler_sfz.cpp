// SFZ import (the opcodes the sampler plays) and export for org.caw.sampler.
#include <algorithm>
#include <cctype>
#include <cmath>
#include <cstring>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <set>
#include <sstream>

#include "asset_store.h"
#include "builtin_sampler.h"
#include "json.h"
#include "sample_pack.h"
#include "utf8_path.h"

namespace caw {

namespace {

constexpr size_t kMaxSfzBytes = 4u << 20;

// SFZ note names: c4 = 60, sharps (#) and flats (b).
bool sfzNumber(const std::string& v, double& out) {
    if (v.empty()) return false;
    const char c0 = static_cast<char>(std::tolower(static_cast<unsigned char>(v[0])));
    if (c0 >= 'a' && c0 <= 'g') {
        static const int base[] = {9, 11, 0, 2, 4, 5, 7};  // a b c d e f g
        int n = base[c0 - 'a'];
        size_t i = 1;
        if (i < v.size() && v[i] == '#') { ++n; ++i; }
        else if (i < v.size() && (v[i] == 'b' || v[i] == 'B') && i + 1 < v.size()) { --n; ++i; }
        if (i >= v.size()) return false;
        char* end = nullptr;
        const long oct = std::strtol(v.c_str() + i, &end, 10);
        if (!end || *end) return false;
        out = static_cast<double>((oct + 1) * 12 + n);
        return true;
    }
    char* end = nullptr;
    out = std::strtod(v.c_str(), &end);
    return end && *end == '\0' && std::isfinite(out);
}

std::string stripComments(std::string_view in) {
    std::string out;
    out.reserve(in.size());
    for (size_t i = 0; i < in.size(); ++i) {
        if (in[i] == '/' && i + 1 < in.size() && in[i + 1] == '/') {
            while (i < in.size() && in[i] != '\n') ++i;
            out += '\n';
        } else if (in[i] == '/' && i + 1 < in.size() && in[i + 1] == '*') {
            i += 2;
            while (i + 1 < in.size() && !(in[i] == '*' && in[i + 1] == '/')) ++i;
            ++i;
            out += ' ';
        } else {
            out += in[i];
        }
    }
    return out;
}

using Opcodes = std::map<std::string, std::string>;

}  // namespace

bool importSfzText(std::string_view text, const std::string& baseDir, SamplerProgram& out,
                   std::vector<std::string>& warnings, std::string& error) {
    out = SamplerProgram{};
    if (text.size() > kMaxSfzBytes) {
        error = "the SFZ file is larger than 4 MB";
        return false;
    }
    std::string src = stripComments(text);
    // #define $NAME value, applied to the rest of the text in one pass: at each '$' the longest defined name there
    // is replaced, and what it is replaced by is not expanded again. The expanded text is capped.
    std::map<std::string, std::string> defines;
    {
        const size_t cap = 4 * kMaxSfzBytes;
        auto nameChar = [](char c) { return std::isalnum(static_cast<unsigned char>(c)) || c == '_'; };
        std::istringstream lines(src);
        std::string line, kept;
        while (std::getline(lines, line)) {
            size_t p = line.find_first_not_of(" \t\r");
            if (p != std::string::npos && line.compare(p, 7, "#define") == 0) {
                std::istringstream w(line.substr(p + 7));
                std::string name, value;
                w >> name >> value;
                if (!name.empty() && name[0] == '$') defines[name] = value;
                continue;
            }
            if (p != std::string::npos && line.compare(p, 8, "#include") == 0) {
                warnings.push_back("#include is not followed (the included file's regions are left out)");
                continue;
            }
            for (size_t i = 0; i < line.size();) {
                if (line[i] == '$' && !defines.empty()) {
                    size_t run = i + 1;
                    while (run < line.size() && nameChar(line[run])) ++run;
                    bool replaced = false;
                    for (size_t end = run; end > i + 1 && !replaced; --end) {
                        const auto it = defines.find(line.substr(i, end - i));
                        if (it == defines.end()) continue;
                        kept += it->second;
                        i = end;
                        replaced = true;
                    }
                    if (!replaced) kept += line[i++];
                } else {
                    kept += line[i++];
                }
                if (kept.size() > cap) {
                    error = "the SFZ file's #define values expand past " + std::to_string(cap >> 20) + " MB";
                    return false;
                }
            }
            kept += '\n';
        }
        src = std::move(kept);
    }
    // Tokens: <header> and opcode=value, where a value runs to the next opcode, header or line end (so
    // sample paths may hold spaces).
    Opcodes control, global, master, group, region;
    std::string level;
    std::map<std::string, int> unknown;
    int skipped = 0;
    bool inRegion = false;
    auto finishRegion = [&]() -> bool {
        if (!inRegion) return true;
        inRegion = false;
        Opcodes all = global;
        for (const auto& [k, v] : master) all[k] = v;
        for (const auto& [k, v] : group) all[k] = v;
        for (const auto& [k, v] : region) all[k] = v;
        if (!all.count("sample")) {
            ++skipped;
            return true;
        }
        if (auto t = all.find("trigger"); t != all.end() && t->second != "attack") {
            warnings.push_back("a region with trigger=" + t->second + " is left out (only attack triggers play)");
            return true;
        }
        if (out.zones.size() >= kMaxSamplerZones) {
            error = "the SFZ file has more than " + std::to_string(kMaxSamplerZones) + " regions";
            return false;
        }
        SamplerZone z;
        std::string sample = all["sample"];
        std::replace(sample.begin(), sample.end(), '\\', '/');
        std::string prefix = control.count("default_path") ? control["default_path"] : "";
        std::replace(prefix.begin(), prefix.end(), '\\', '/');
        std::filesystem::path p = utf8Path(sample);
        if (!p.is_absolute()) p = utf8Path(baseDir) / utf8Path(prefix) / utf8Path(sample);
        z.path = pathText(p.lexically_normal());
        bool keySet = false;
        for (const auto& [k, v] : all) {
            double x = 0;
            const bool isNum = sfzNumber(v, x);
            auto whole = [&](int lo, int hi) { return static_cast<int>(std::clamp(std::round(x), double(lo), double(hi))); };
            auto frames = [&]() { return static_cast<int64_t>(std::clamp(std::round(x), 0.0, 9e15)); };  // fits int64_t
            if (k == "sample" || k == "trigger") continue;
            if (k == "loop_mode" || k == "loopmode") {
                z.loopModeSet = true;
                if (v == "no_loop") z.loopMode = LoopMode::NoLoop;
                else if (v == "one_shot") z.loopMode = LoopMode::OneShot;
                else if (v == "loop_continuous") z.loopMode = LoopMode::Continuous;
                else if (v == "loop_sustain") z.loopMode = LoopMode::Sustain;
                else z.loopModeSet = false;
                continue;
            }
            if (!isNum) {
                ++unknown[k];
                continue;
            }
            if (k == "key") { z.lokey = z.hikey = z.root = whole(0, 127); keySet = true; }
            else if (k == "lokey") z.lokey = whole(0, 127);
            else if (k == "hikey") z.hikey = whole(0, 127);
            else if (k == "pitch_keycenter") { z.root = whole(0, 127); keySet = true; }
            else if (k == "lovel") z.lovel = whole(1, 127);
            else if (k == "hivel") z.hivel = whole(1, 127);
            else if (k == "tune") z.tune = std::clamp(x, -9600.0, 9600.0);
            else if (k == "transpose") z.transpose = whole(-127, 127);
            else if (k == "volume") z.volume = std::clamp(x, -144.0, 24.0);
            else if (k == "pan") z.pan = std::clamp(x, -100.0, 100.0);
            else if (k == "pitch_keytrack") z.keytrack = std::clamp(x, -1200.0, 1200.0);
            else if (k == "amp_veltrack") z.veltrack = std::clamp(x, -100.0, 100.0);
            else if (k == "offset") z.offset = frames();
            else if (k == "end") z.end = frames();
            else if (k == "loop_start" || k == "loopstart") z.loopStart = frames();
            else if (k == "loop_end" || k == "loopend") z.loopEnd = frames();
            else if (k == "loop_crossfade") z.loopCrossfade = std::clamp(x, 0.0, 10.0);
            else if (k == "seq_length") z.seqLength = whole(1, 100);
            else if (k == "seq_position") z.seqPosition = whole(1, 100);
            else if (k == "lorand") z.lorand = std::clamp(x, 0.0, 1.0);
            else if (k == "hirand") z.hirand = std::clamp(x, 0.0, 1.0);
            else if (k == "group") z.group = whole(0, 1000000);
            else if (k == "off_by") z.offBy = whole(0, 1000000);
            else if (k == "ampeg_attack") z.ampAttack = std::clamp(x, 0.0, 100.0);
            else if (k == "ampeg_decay") z.ampDecay = std::clamp(x, 0.0, 100.0);
            else if (k == "ampeg_sustain") z.ampSustain = std::clamp(x, 0.0, 100.0);
            else if (k == "ampeg_release") z.ampRelease = std::clamp(x, 0.0, 100.0);
            else ++unknown[k];
        }
        (void)keySet;
        if (z.seqPosition > z.seqLength) z.seqPosition = z.seqLength;
        if (z.lokey > z.hikey) std::swap(z.lokey, z.hikey);
        if (z.lovel > z.hivel) std::swap(z.lovel, z.hivel);
        if (z.lorand > z.hirand) std::swap(z.lorand, z.hirand);
        if (!z.loopModeSet && z.loopEnd > z.loopStart) z.loopMode = LoopMode::Continuous;
        out.zones.push_back(std::move(z));
        return true;
    };
    size_t i = 0;
    const size_t n = src.size();
    auto isName = [](char c) { return std::isalnum(static_cast<unsigned char>(c)) || c == '_'; };
    while (i < n) {
        while (i < n && std::isspace(static_cast<unsigned char>(src[i]))) ++i;
        if (i >= n) break;
        if (src[i] == '<') {
            const size_t close = src.find('>', i);
            if (close == std::string::npos) {
                error = "an SFZ header is not closed";
                return false;
            }
            const std::string h = src.substr(i + 1, close - i - 1);
            i = close + 1;
            if (!finishRegion()) return false;
            level = h;
            if (h == "region") { region.clear(); inRegion = true; }
            else if (h == "group") { group.clear(); }
            else if (h == "master") { master.clear(); group.clear(); }
            else if (h == "global") { global.clear(); master.clear(); group.clear(); }
            else if (h == "control") { control.clear(); }
            else if (h != "curve" && h != "effect" && h != "midi" && h != "sample") level = "?";
            else warnings.push_back("<" + h + "> sections are left out");
            continue;
        }
        size_t eq = i;
        while (eq < n && isName(src[eq])) ++eq;
        if (eq >= n || src[eq] != '=' || eq == i) {  // not an opcode: skip the word
            while (i < n && !std::isspace(static_cast<unsigned char>(src[i]))) ++i;
            continue;
        }
        const std::string key = src.substr(i, eq - i);
        size_t v = eq + 1, e = v;
        // The value ends at a line end, a header, or whitespace before the next name=.
        while (e < n && src[e] != '\n' && src[e] != '\r' && src[e] != '<') {
            if (std::isspace(static_cast<unsigned char>(src[e]))) {
                size_t k = e;
                while (k < n && (src[k] == ' ' || src[k] == '\t')) ++k;
                size_t m = k;
                while (m < n && isName(src[m])) ++m;
                if (m > k && m < n && src[m] == '=') break;
            }
            ++e;
        }
        std::string value = src.substr(v, e - v);
        while (!value.empty() && std::isspace(static_cast<unsigned char>(value.back()))) value.pop_back();
        i = e;
        Opcodes* target = level == "region" ? &region : level == "group" ? &group : level == "master" ? &master
                        : level == "global" ? &global : level == "control" ? &control : nullptr;
        if (target) (*target)[key] = value;
    }
    if (!finishRegion()) return false;
    for (const auto& [k, count] : unknown)
        if (k != "default_path")
            warnings.push_back("opcode " + k + " is not supported (" + std::to_string(count) + " use" +
                               (count == 1 ? "" : "s") + ")");
    if (skipped) warnings.push_back(std::to_string(skipped) + " region(s) without a sample are left out");
    return true;
}

std::string exportSfzText(const SamplerProgram& p, const std::string& sfzDir, const std::string& title) {
    namespace fs = std::filesystem;
    std::string s = "// " + title + " (made by C.A.W.)\n";
    auto num = [](double v) {
        char b[40];
        std::snprintf(b, sizeof b, "%.10g", v);
        return std::string(b);
    };
    for (const SamplerZone& z : p.zones) {
        std::string path = z.path;
        std::error_code ec;
        const fs::path rel = utf8Path(z.path).lexically_relative(utf8Path(sfzDir));
        if (!rel.empty() && pathText(rel).rfind("..", 0) != 0) path = pathText(rel);
        s += "<region> sample=" + path + " lokey=" + std::to_string(z.lokey) + " hikey=" + std::to_string(z.hikey) +
             " pitch_keycenter=" + std::to_string(z.root) + " lovel=" + std::to_string(z.lovel) +
             " hivel=" + std::to_string(z.hivel);
        if (z.tune != 0) s += " tune=" + num(z.tune);
        if (z.transpose != 0) s += " transpose=" + std::to_string(z.transpose);
        if (z.volume != 0) s += " volume=" + num(z.volume);
        if (z.pan != 0) s += " pan=" + num(z.pan);
        if (z.keytrack != 100) s += " pitch_keytrack=" + num(z.keytrack);
        if (z.veltrack != 100) s += " amp_veltrack=" + num(z.veltrack);
        if (z.offset) s += " offset=" + std::to_string(z.offset);
        if (z.end) s += " end=" + std::to_string(z.end);
        static const char* modes[] = {"no_loop", "one_shot", "loop_continuous", "loop_sustain"};
        s += std::string(" loop_mode=") + modes[static_cast<int>(z.loopMode)];
        if (z.loopStart || z.loopEnd)
            s += " loop_start=" + std::to_string(z.loopStart) + " loop_end=" + std::to_string(z.loopEnd);
        if (z.loopCrossfade > 0) s += " loop_crossfade=" + num(z.loopCrossfade);
        if (z.seqLength > 1) s += " seq_length=" + std::to_string(z.seqLength) + " seq_position=" + std::to_string(z.seqPosition);
        if (z.lorand > 0 || z.hirand < 1) s += " lorand=" + num(z.lorand) + " hirand=" + num(z.hirand);
        if (z.group) s += " group=" + std::to_string(z.group);
        if (z.offBy) s += " off_by=" + std::to_string(z.offBy);
        if (z.ampAttack >= 0) s += " ampeg_attack=" + num(z.ampAttack);
        if (z.ampDecay >= 0) s += " ampeg_decay=" + num(z.ampDecay);
        if (z.ampSustain >= 0) s += " ampeg_sustain=" + num(z.ampSustain);
        if (z.ampRelease >= 0) s += " ampeg_release=" + num(z.ampRelease);
        s += "\n";
    }
    return s;
}

namespace {
std::string listJson(const std::vector<std::string>& v) {
    std::string s = "[";
    for (size_t i = 0; i < v.size(); ++i) s += (i ? ",\"" : "\"") + jsonEscape(v[i]) + "\"";
    return s + "]";
}
std::string fail(const std::string& e) { return "{\"ok\":false,\"error\":\"" + jsonEscape(e) + "\"}"; }
std::string lowerAscii(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}
// Export copies only what a zone can play: a regular audio file (.wav, .flac or .mp3 whose first bytes say so)
// no larger than the asset limit. The state comes from a project, which may come from anyone: without this, a
// zone path could copy any readable file (a key, a database) into the folder being exported and shared.
bool copyableSample(const std::filesystem::path& src, std::string& why) {
    std::error_code ec;
    if (!std::filesystem::is_regular_file(src, ec)) {
        why = "not a file";
        return false;
    }
    const auto size = std::filesystem::file_size(src, ec);
    if (ec || size < 4 || size > kMaxAssetFileBytes) {
        why = "not a sample (empty, or larger than 1 GB)";
        return false;
    }
    const std::string ext = lowerAscii(pathText(src.extension()));
    unsigned char h[4] = {};
    std::ifstream f(src, std::ios::binary);
    f.read(reinterpret_cast<char*>(h), 4);
    const bool riff = std::memcmp(h, "RIFF", 4) == 0 || std::memcmp(h, "RF64", 4) == 0;
    const bool flac = std::memcmp(h, "fLaC", 4) == 0;
    const bool mp3 = std::memcmp(h, "ID3", 3) == 0 || (h[0] == 0xFF && (h[1] & 0xE0) == 0xE0);
    if (!f || !((ext == ".wav" && riff) || (ext == ".flac" && flac) || (ext == ".mp3" && mp3))) {
        why = "only WAV, FLAC and MP3 samples are copied";
        return false;
    }
    return true;
}
}  // namespace

std::string sfzImportJson(const std::string& path) {
    try {
        std::error_code ec;
        const auto size = std::filesystem::file_size(utf8Path(path), ec);
        if (ec) return fail(path + " can't be read");
        if (size > kMaxSfzBytes) return fail("the SFZ file is larger than 4 MB");
        std::ifstream f(utf8Path(path), std::ios::binary);
        std::string text((std::istreambuf_iterator<char>(f)), std::istreambuf_iterator<char>());
        SamplerProgram p;
        std::vector<std::string> warnings;
        std::string error;
        const std::string dir = pathText(utf8Path(path).parent_path());
        if (!importSfzText(text, dir, p, warnings, error)) return fail(error);
        for (const SamplerZone& z : p.zones)
            if (!std::filesystem::exists(utf8Path(z.path), ec)) warnings.push_back("missing sample: " + z.path);
        return "{\"ok\":true,\"error\":\"\",\"zones\":" + std::to_string(p.zones.size()) + ",\"warnings\":" +
               listJson(warnings) + ",\"state\":" + samplerStateJson(p) + "}";
    } catch (...) {
        return fail("the SFZ file could not be read");
    }
}

std::string sfzExportJson(std::string_view stateJson, const std::string& sfzPath, bool copySamples) {
    namespace fs = std::filesystem;
    try {
        SamplerProgram p;
        std::string error;
        if (!parseSamplerState(stateJson, p, error)) return fail(error);
        const fs::path out = utf8Path(sfzPath);
        const fs::path dir = out.parent_path();
        std::error_code ec;
        if (!fs::is_directory(dir, ec)) return fail("the folder for " + sfzPath + " doesn't exist");
        std::vector<std::string> files;
        if (copySamples) {
            const fs::path samples = dir / "samples";
            fs::create_directories(samples, ec);
            std::map<std::string, std::string> copied;  // source -> new path
            // Names already taken, compared without case (Windows and Android storage ignore it): files already in
            // samples/ are never overwritten, and two sources never share a name.
            std::set<std::string> names;
            for (const auto& e : fs::directory_iterator(samples, ec)) names.insert(lowerAscii(pathText(e.path().filename())));
            for (SamplerZone& z : p.zones) {
                auto it = copied.find(z.path);
                if (it == copied.end()) {
                    const fs::path src = utf8Path(z.path);
                    std::string why;
                    if (!copyableSample(src, why)) return fail("can't copy " + z.path + ": " + why);
                    std::string stem = sanitizeFileName(pathText(src.stem()));
                    const std::string dotted = pathText(src.extension());
                    const std::string ext = dotted.size() > 1 ? "." + sanitizeFileName(dotted.substr(1)) : "";
                    std::string name = stem + ext;
                    for (int k = 2; names.count(lowerAscii(name)); ++k) name = stem + "_" + std::to_string(k) + ext;
                    names.insert(lowerAscii(name));
                    const fs::path dst = samples / utf8Path(name);
                    fs::copy_file(src, dst, fs::copy_options::none, ec);  // never over a file (names are unique)
                    if (ec) return fail("can't copy " + z.path + ": " + ec.message());
                    files.push_back(pathText(dst));
                    it = copied.emplace(z.path, pathText(dst)).first;
                }
                z.path = it->second;
            }
        }
        const std::string text = exportSfzText(p, pathText(dir), pathText(out.stem()));
        std::ofstream f(out, std::ios::binary | std::ios::trunc);
        f << text;
        f.close();
        if (!f) return fail("can't write " + sfzPath);
        files.insert(files.begin(), pathText(out));
        return "{\"ok\":true,\"error\":\"\",\"files\":" + listJson(files) + "}";
    } catch (...) {
        return fail("the SFZ file could not be written");
    }
}

}  // namespace caw
