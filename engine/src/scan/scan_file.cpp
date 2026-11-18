// The pre-load scan of a file on disk (scan_file.h): read, hash, cache by hash, the manifest check, JSON.
#include "scan_file.h"

#include <cstdio>
#include <mutex>
#include <system_error>
#include <unordered_map>
#include <vector>

#include "declarations.h"
#include "json.h"
#include "sha256.h"
#include "utf8_path.h"

namespace caw::scan {
namespace {

constexpr size_t kMaxCachedReports = 256;
constexpr uint64_t kMaxManifestBytes = 64 * 1024;

std::mutex& cacheMutex() {
    static std::mutex m;
    return m;
}
std::unordered_map<std::string, std::shared_ptr<const Report>>& cache() {
    static std::unordered_map<std::string, std::shared_ptr<const Report>> c;
    return c;
}
uint64_t& scanCounter() {
    static uint64_t n = 0;
    return n;
}

// The whole file up to the cap (kept), hashed to its end either way. False if it cannot be read.
bool readHashed(const std::string& path, uint64_t cap, std::vector<uint8_t>& bytes, std::string& sha, uint64_t& size,
                bool& tooLarge, std::string& error) {
    std::FILE* f = openFile(utf8Path(path), "rb");
    if (!f) {
        error = "the file could not be opened";
        return false;
    }
    Sha256 hash;
    std::vector<uint8_t> chunk(1 << 16);
    size = 0;
    tooLarge = false;
    for (;;) {
        const size_t got = std::fread(chunk.data(), 1, chunk.size(), f);
        if (got == 0) break;
        hash.update(chunk.data(), got);
        size += got;
        if (size > cap) tooLarge = true;
        if (!tooLarge) bytes.insert(bytes.end(), chunk.begin(), chunk.begin() + static_cast<std::ptrdiff_t>(got));
    }
    const bool failed = std::ferror(f) != 0;
    std::fclose(f);
    if (failed) {
        error = "the file could not be read";
        return false;
    }
    if (tooLarge) bytes.clear();
    sha = toHex(hash.digest());
    return true;
}

// A caw-component.json beside the library, for the component `id`: what it declares. False when there is none
// for this id (or it is not readable JSON, so it is no authority); `invalid` holds why its declarations are bad.
bool siblingManifest(const std::string& path, std::string_view id, bool& hasList, std::vector<Declaration>& list,
                     std::string& invalid) {
    std::error_code ec;
    const std::filesystem::path manifest = utf8Path(path).parent_path() / "caw-component.json";
    const auto size = std::filesystem::file_size(manifest, ec);
    if (ec || size > kMaxManifestBytes) return false;
    std::FILE* f = openFile(manifest, "rb");
    if (!f) return false;
    std::string text(static_cast<size_t>(size), '\0');
    const size_t got = std::fread(text.data(), 1, text.size(), f);
    std::fclose(f);
    text.resize(got);
    Json root;
    std::string error;
    if (!parseJson(text, root, error) || root.type != Json::Type::Object) return false;
    const Json* component = root.get("component");
    if (!component || component->string("id") != id) return false;
    hasList = root.get("capabilities") != nullptr;
    if (!declarationsFromManifest(root, Limits{}.maxDeclarations, list, invalid) && invalid.empty())
        invalid = "invalid capabilities";
    return true;
}

}  // namespace

void clearScanCache() {
    std::lock_guard<std::mutex> lock(cacheMutex());
    cache().clear();
}

uint64_t scansRun() {
    std::lock_guard<std::mutex> lock(cacheMutex());
    return scanCounter();
}

FileScan scanFile(const std::string& path, std::string_view expectedId) {
    FileScan out;
    const Limits limits;
    std::vector<uint8_t> bytes;
    bool tooLarge = false;
    if (!readHashed(path, limits.maxFileBytes, bytes, out.sha256, out.size, tooLarge, out.error)) return out;
    out.ok = true;
    std::shared_ptr<const Report> report;
    {
        std::lock_guard<std::mutex> lock(cacheMutex());
        const auto it = cache().find(out.sha256);
        if (it != cache().end()) report = it->second;
    }
    out.cached = report != nullptr;
    if (!report) {
        Report fresh;
        if (tooLarge) {
            fresh.malformed = true;
            fresh.findings.push_back({Capability::Packed, FindingKind::Malformed,
                                      "the file is larger than the scan reads (256 MiB)", Strength::Certain,
                                      Severity::Warning});
        } else {
            fresh = scanBinary(bytes, limits);
        }
        report = std::make_shared<const Report>(std::move(fresh));
        std::lock_guard<std::mutex> lock(cacheMutex());
        ++scanCounter();
        if (cache().size() >= kMaxCachedReports) cache().clear();
        cache().emplace(out.sha256, report);
    }
    out.report = report;

    if (!expectedId.empty()) {
        bool hasList = false;
        std::vector<Declaration> manifest;
        std::string invalid;
        if (siblingManifest(path, expectedId, hasList, manifest, invalid)) {
            out.manifestChecked = true;
            std::string tamper;
            if (!invalid.empty()) {
                tamper = "the caw-component.json beside it has invalid capabilities: " + invalid;
            } else if (report->declarationState == Report::DeclarationState::Valid) {
                if (canonicalDeclarations(manifest) != report->declarationsCanonical)
                    tamper = "the capabilities in the caw-component.json beside it differ from the ones built in";
            } else if (report->declarationState == Report::DeclarationState::Absent && hasList && !manifest.empty()) {
                tamper = "the caw-component.json beside it declares capabilities the binary does not carry";
            }
            if (!tamper.empty()) {
                out.tampered = true;
                Report copy = *report;
                copy.findings.push_back({Capability::Packed, FindingKind::Declarations, tamper, Strength::Certain,
                                         Severity::Warning});
                out.report = std::make_shared<const Report>(std::move(copy));
            }
        }
    }
    return out;
}

std::string scanErrorJson(const std::string& error) {
    return "{\"ok\":false,\"error\":\"" + jsonEscape(error) + "\"}";
}

std::string scanJson(const FileScan& scan, const Decision& decision, const PolicyInput& input) {
    if (!scan.ok || !scan.report) return scanErrorJson(scan.error.empty() ? "no scan" : scan.error);
    const Report& r = *scan.report;
    auto q = [](std::string_view s) { return "\"" + jsonEscape(s) + "\""; };
    auto b = [](bool v) { return v ? "true" : "false"; };
    const char* format = r.format == Format::Elf64 ? "elf64" : r.format == Format::Pe32Plus ? "pe32+" : "unknown";
    const char* state = r.declarationState == Report::DeclarationState::Valid     ? "valid"
                        : r.declarationState == Report::DeclarationState::Invalid ? "invalid"
                                                                                   : "absent";
    std::string j = "{\"ok\":true,\"sha256\":" + q(scan.sha256) + ",\"size\":" + std::to_string(scan.size) +
                    ",\"format\":" + q(format) + ",\"arch\":" + q(r.arch) +
                    ",\"host\":" + q(input.host == Host::Component ? "component" : "plugin") +
                    ",\"verdict\":" + q(verdictId(decision.verdict)) + ",\"reason\":" + q(decision.reason) +
                    ",\"grace_applied\":" + b(decision.graceApplied) + ",\"cached\":" + b(scan.cached) +
                    ",\"manifest_checked\":" + b(scan.manifestChecked) + ",\"declarations\":" + q(state) +
                    ",\"declared\":[";
    for (size_t i = 0; i < r.declarations.size(); ++i) {
        const Declaration& d = r.declarations[i];
        j += std::string(i ? "," : "") + "{\"id\":" + q(capabilityId(d.capability)) +
             ",\"title\":" + q(capabilityTitle(d.capability)) + ",\"reason\":" + q(d.reason) + ",\"sites\":[";
        for (size_t k = 0; k < d.sites.size(); ++k) j += (k ? "," : "") + q(d.sites[k]);
        j += "]}";
    }
    j += "],\"blocked_by\":[";
    bool first = true;
    for (size_t c = 0; c < kCapabilityCount; ++c)
        if (decision.blockedBy & (1u << c)) {
            j += (first ? "" : ",") + q(capabilityId(static_cast<Capability>(c)));
            first = false;
        }
    j += "],\"summary\":{\"imports\":" + std::to_string(r.imports) + ",\"constructors\":" +
         std::to_string(r.constructors) + ",\"tls_callbacks\":" + std::to_string(r.tlsCallbacks) +
         ",\"component_entry\":" + b(r.componentEntry) + "},\"findings\":[";
    for (size_t i = 0; i < decision.findings.size(); ++i) {
        const Weighed& w = decision.findings[i];
        j += std::string(i ? "," : "") + "{\"capability\":" + q(capabilityId(w.finding.capability)) +
             ",\"title\":" + q(capabilityTitle(w.finding.capability)) + ",\"kind\":" + q(findingKindId(w.finding.kind)) +
             ",\"evidence\":" + q(w.finding.evidence) +
             ",\"strength\":" + q(w.finding.strength == Strength::Certain ? "certain" : "hint") +
             ",\"severity\":" + q(w.severity == Severity::Warning ? "warning" : "notice") +
             ",\"declared\":" + b(w.declared) + ",\"blocks\":" + b(w.blocks) + "}";
    }
    return j + "]}";
}

}  // namespace caw::scan
