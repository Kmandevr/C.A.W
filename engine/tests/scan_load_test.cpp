// The pre-load scan on real files: the engine's built test components and starter pass, the loader refuses a
// blocked file before opening it, the legacy grace, the verdict cache by SHA-256, tampering, and the C API JSON.
#include <cctype>
#include <chrono>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <iterator>
#include <random>
#include <string>

#include "caw.h"
#include "json.h"
#include "native_component_test_path.h"
#include "scan/declarations.h"
#include "scan/policy.h"
#include "scan/scan_file.h"
#include "scan_fixtures.h"
#include "test.h"
#include "utf8_path.h"

using namespace caw::scan;
using namespace caw::scantest;

namespace {

namespace fs = std::filesystem;

// A fresh folder under the system's temporary folder, unique per run (CTest runs each shard twice at once).
fs::path tempDir(const char* name) {
    std::random_device device;
    const auto stamp = std::chrono::steady_clock::now().time_since_epoch().count();
    const fs::path dir = fs::temp_directory_path() /
                         (std::string("caw_scan_") + name + "_" + std::to_string(stamp) + "_" + std::to_string(device()));
    std::error_code ec;
    fs::remove_all(dir, ec);
    fs::create_directories(dir);
    return dir;
}

void writeFile(const fs::path& path, const std::string& text) {
    std::ofstream f(path, std::ios::binary);
    f.write(text.data(), static_cast<std::streamsize>(text.size()));
}
void writeFile(const fs::path& path, const Bytes& bytes) {
    writeFile(path, std::string(bytes.begin(), bytes.end()));
}
std::string readFile(const fs::path& path) {
    std::ifstream f(path, std::ios::binary);
    return std::string(std::istreambuf_iterator<char>(f), std::istreambuf_iterator<char>());
}

Decision componentDecision(const FileScan& s, bool grace = false) { return decide(*s.report, {Host::Component, grace}); }

bool hasCapability(const Report& r, Capability c) {
    for (const Finding& f : r.findings)
        if (f.capability == c && f.strength == Strength::Certain) return true;
    return false;
}

// An ELF the scan blocks (it imports connect, declares nothing) and that no system loader would open
// (ET_EXEC; no constructors), so the grace test reaches the loader without running anything of it.
Bytes blockedFixture() {
    ElfSpec s;
    s.imports = {"connect", "memcpy"};
    s.initArrayBytes = 0;
    Bytes b = buildElf(s);
    put16(b, 16, 2);
    return b;
}

#if defined(__APPLE__)
constexpr bool kScannableHost = false;  // Mach-O is not a format the scan reads
#else
constexpr bool kScannableHost = true;
#endif

}  // namespace

TEST(scan_the_engines_built_test_components_pass_the_component_policy) {
    if (!kScannableHost) return;
    const char* paths[] = {caw::test::nativeComponentPath(), CAW_TEST_NO_ENTRY_COMPONENT_PATH, CAW_TEST_V30_COMPONENT_PATH,
                           CAW_TEST_MODULATOR_PATH, CAW_TEST_BENCH_COMPONENT_PATH, CAW_TEST_STARTER_PATH};
    for (const char* path : paths) {
        const FileScan s = scanFile(path);
        CHECK(s.ok);
        if (!s.ok) continue;
        CHECK(s.report->format != Format::Unknown);
        CHECK(!s.report->malformed);
        const Decision d = componentDecision(s);
        if (d.verdict == Verdict::Blocked) cawtest::fail(__FILE__, __LINE__, std::string(path) + ": " + d.reason);
    }
}

TEST(scan_the_starter_built_like_the_app_carries_an_empty_declaration_and_loads) {
    if (!kScannableHost) return;
    const FileScan s = scanFile(CAW_TEST_STARTER_PATH);
    CHECK(s.ok);
    if (!s.ok) return;
    CHECK(s.report->declarationState == Report::DeclarationState::Valid);
    CHECK(s.report->declarations.empty());
    CHECK(s.report->componentEntry || s.report->format == Format::Pe32Plus);
    CawEngine* engine = caw_engine_create(48000);
    char* loaded = caw_engine_load_component(engine, CAW_TEST_STARTER_PATH, "org.caw.starter.bass", CAW_NATIVE_TRUST_TRUSTED);
    const std::string json = loaded ? loaded : "";
    caw_free(loaded);
    CHECK(json.find(R"("ok":true)") != std::string::npos);
    CHECK(json.find(R"("sha256":")" + s.sha256 + "\"") != std::string::npos);
    CHECK(json.find(R"("scan_verdict":"blocked")") == std::string::npos);
    caw_engine_destroy(engine);
}

TEST(scan_the_declared_fixture_embeds_the_golden_canonical_bytes) {
    // The manifest path (declarationsFromManifest) and the CMake build (caw_add_component) both give exactly the
    // bytes in engine/tests/references/capabilities.canonical; the app's in-app build must too.
    std::string golden = readFile(fs::path(CAW_ROOT) / "engine/tests/references/capabilities.canonical");
    while (!golden.empty() && (golden.back() == '\n' || golden.back() == '\r')) golden.pop_back();
    CHECK(!golden.empty());
    caw::Json manifest;
    std::string error;
    CHECK(caw::parseJson(readFile(fs::path(CAW_ROOT) / "engine/tests/fixtures/declared/caw-component.json"), manifest, error));
    std::vector<Declaration> list;
    CHECK(declarationsFromManifest(manifest, 16, list, error));
    CHECK_EQ(canonicalDeclarations(list), golden);
    if (!kScannableHost) return;
    const FileScan s = scanFile(CAW_TEST_DECLARED_PATH, "org.caw.tests.declared");
    CHECK(s.ok);
    if (!s.ok) return;
    CHECK(s.report->declarationState == Report::DeclarationState::Valid);
    CHECK_EQ(s.report->declarationsCanonical, golden);
    CHECK(hasCapability(*s.report, Capability::BackgroundThreads));  // std::thread, declared
    const Decision d = componentDecision(s);
    CHECK(d.verdict == Verdict::Notice || d.verdict == Verdict::Clean);
    for (const Weighed& w : d.findings)
        if (w.finding.capability == Capability::BackgroundThreads && w.finding.kind == FindingKind::Import) CHECK(w.declared);
    CawEngine* engine = caw_engine_create(48000);
    char* loaded = caw_engine_load_component(engine, CAW_TEST_DECLARED_PATH, "org.caw.tests.declared", CAW_NATIVE_TRUST_TRUSTED);
    const std::string json = loaded ? loaded : "";
    caw_free(loaded);
    CHECK(json.find(R"("ok":true)") != std::string::npos);
    caw_engine_destroy(engine);
}

TEST(scan_libcaw_itself_parses_and_shows_what_an_engine_does) {
    if (!kScannableHost) return;
    const FileScan s = scanFile(CAW_TEST_LIBCAW_PATH);
    CHECK(s.ok);
    if (!s.ok) return;
    CHECK(!s.report->malformed);
    CHECK(s.report->imports > 0);
    // The engine loads components and starts its mix pool: as a component it would have to declare both.
    CHECK(hasCapability(*s.report, Capability::LoadCode));
    CHECK(hasCapability(*s.report, Capability::BackgroundThreads));
    CHECK(componentDecision(s).verdict == Verdict::Blocked);
    CHECK(decide(*s.report, {Host::Plugin, false}).verdict != Verdict::Blocked);
}

TEST(scan_the_loader_refuses_a_blocked_file_before_opening_it_and_grace_lets_it_through) {
    const fs::path dir = tempDir("blocked");
    const fs::path file = dir / "blocked_component.so";
    writeFile(file, blockedFixture());
    const std::string path = caw::pathText(file);
    CawEngine* engine = caw_engine_create(48000);
    char* refused = caw_engine_load_component(engine, path.c_str(), "org.caw.tests.blocked", CAW_NATIVE_TRUST_TRUSTED);
    std::string json = refused ? refused : "";
    caw_free(refused);
    CHECK(json.find(R"("ok":false)") != std::string::npos);
    CHECK(json.find(R"("errorCode":11)") != std::string::npos);
    CHECK(json.find("internet") != std::string::npos);
    CHECK(json.find("connect") != std::string::npos);
    CHECK(json.find(R"("scan_verdict":"blocked")") != std::string::npos);
    // The same file with the legacy grace: the scan lets it through as a warning (the system loader then refuses
    // this fixture, which is no loadable library).
    // The grace is for the exact file the user trusted: its SHA-256 (any case).
    std::string sha = scanFile(path).sha256;
    for (char& c : sha) c = static_cast<char>(std::toupper(static_cast<unsigned char>(c)));
    char* graced = caw_engine_load_component_ex(engine, path.c_str(), "org.caw.tests.blocked", CAW_NATIVE_TRUST_TRUSTED,
                                                CAW_LOAD_LEGACY_GRACE, sha.c_str());
    json = graced ? graced : "";
    caw_free(graced);
    CHECK(json.find(R"("errorCode":11)") == std::string::npos);
    CHECK(json.find(R"("scan_verdict":"warning")") != std::string::npos);
    CHECK(json.find(R"("grace_applied":true)") != std::string::npos);
    // No hash: an invalid argument. Another file's hash: refused.
    char* noHash = caw_engine_load_component_ex(engine, path.c_str(), "org.caw.tests.blocked", CAW_NATIVE_TRUST_TRUSTED,
                                                CAW_LOAD_LEGACY_GRACE, nullptr);
    json = noHash ? noHash : "";
    caw_free(noHash);
    CHECK(json.find(R"("errorCode":3)") != std::string::npos);
    const std::string other(64, 'a');
    char* wrongHash = caw_engine_load_component_ex(engine, path.c_str(), "org.caw.tests.blocked",
                                                   CAW_NATIVE_TRUST_TRUSTED, CAW_LOAD_LEGACY_GRACE, other.c_str());
    json = wrongHash ? wrongHash : "";
    caw_free(wrongHash);
    CHECK(json.find(R"("errorCode":11)") != std::string::npos);
    CHECK(json.find(R"("grace_applied":true)") == std::string::npos);
    CHECK(json.find("differs") != std::string::npos);
    char* badFlags = caw_engine_load_component_ex(engine, path.c_str(), "org.caw.tests.blocked", CAW_NATIVE_TRUST_TRUSTED,
                                                  0x80, nullptr);
    json = badFlags ? badFlags : "";
    caw_free(badFlags);
    CHECK(json.find(R"("errorCode":3)") != std::string::npos);
    // Blocked trust still wins before any scan.
    char* blocked = caw_engine_load_component(engine, path.c_str(), "org.caw.tests.blocked", CAW_NATIVE_TRUST_BLOCKED);
    json = blocked ? blocked : "";
    caw_free(blocked);
    CHECK(json.find(R"("errorCode":1)") != std::string::npos);
    caw_engine_destroy(engine);
    std::error_code ec;
    fs::remove_all(dir, ec);
}

TEST(scan_verdicts_are_cached_by_hash_and_a_changed_file_is_scanned_again) {
    const fs::path dir = tempDir("cache");
    const fs::path file = dir / "component.so";
    ElfSpec s;
    s.imports = {"memcpy"};
    Bytes bytes = buildElf(s);
    writeFile(file, bytes);
    const std::string path = caw::pathText(file);
    clearScanCache();
    const uint64_t before = scansRun();
    const FileScan first = scanFile(path);
    CHECK(first.ok && !first.cached);
    CHECK_EQ(scansRun(), before + 1);
    const FileScan second = scanFile(path);
    CHECK(second.ok && second.cached);
    CHECK_EQ(second.sha256, first.sha256);
    CHECK_EQ(scansRun(), before + 1);
    bytes.push_back(0);
    writeFile(file, bytes);
    const FileScan third = scanFile(path);
    CHECK(third.ok && !third.cached);
    CHECK(third.sha256 != first.sha256);
    CHECK_EQ(scansRun(), before + 2);
    const FileScan missing = scanFile(caw::pathText(dir / "missing.so"));
    CHECK(!missing.ok);
    std::error_code ec;
    fs::remove_all(dir, ec);
}

TEST(scan_a_manifest_beside_the_binary_that_disagrees_is_tampering) {
    const fs::path dir = tempDir("tamper");
    const fs::path file = dir / "declared.so";
    ElfSpec s;
    s.imports = {"pthread_create"};
    const std::string caps = R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"background_threads",)"
                             R"("reason":"Loads samples"}]})";
    Bytes section(caps.begin(), caps.end());
    section.push_back(0);
    s.extraSections = {{"caw_caps", section}};
    writeFile(file, buildElf(s));
    const std::string path = caw::pathText(file);
    const std::string id = "org.caw.tests.tamper";
    auto manifest = [&](const std::string& capabilities) {
        writeFile(dir / "caw-component.json", R"({"format":"caw.component","version":1,"component":{"id":")" + id +
                                                  R"("},"sources":["a.cpp"])" + capabilities + "}");
    };
    manifest(R"(,"capabilities":[{"id":"background_threads","reason":"Loads samples"}])");
    FileScan ok = scanFile(path, id);
    CHECK(ok.manifestChecked && !ok.tampered);
    CHECK(componentDecision(ok).verdict != Verdict::Blocked);
    manifest(R"(,"capabilities":[{"id":"background_threads","reason":"Something else"}])");
    FileScan changed = scanFile(path, id);
    CHECK(changed.tampered);
    CHECK(componentDecision(changed).verdict == Verdict::Blocked);
    CHECK(componentDecision(changed, true).verdict == Verdict::Blocked);
    manifest(R"(,"capabilities":[{"id":"nonsense","reason":"x"}])");
    CHECK(scanFile(path, id).tampered);
    // Another component's manifest, or none, is no evidence either way.
    writeFile(dir / "caw-component.json", R"({"format":"caw.component","version":1,"component":{"id":"other"}})");
    const FileScan other = scanFile(path, id);
    CHECK(!other.manifestChecked && !other.tampered);
    // The loader applies it: the id it is asked for picks the manifest.
    manifest(R"(,"capabilities":[])");
    CawEngine* engine = caw_engine_create(48000);
    char* refused = caw_engine_load_component(engine, path.c_str(), id.c_str(), CAW_NATIVE_TRUST_TRUSTED);
    const std::string json = refused ? refused : "";
    caw_free(refused);
    CHECK(json.find(R"("errorCode":11)") != std::string::npos);
    CHECK(json.find("differ") != std::string::npos);
    caw_engine_destroy(engine);
    std::error_code ec;
    fs::remove_all(dir, ec);
}

TEST(scan_c_api_returns_the_trust_sheets_json) {
    const fs::path dir = tempDir("capi");
    const fs::path file = dir / "blocked.so";
    writeFile(file, blockedFixture());
    const std::string path = caw::pathText(file);
    char* raw = caw_engine_scan_component(nullptr, path.c_str(), nullptr, 0);
    caw::Json j;
    std::string error;
    CHECK(raw && caw::parseJson(raw, j, error));
    caw_free(raw);
    CHECK(j.boolean("ok", false));
    CHECK_EQ(j.string("verdict"), std::string("blocked"));
    CHECK_EQ(j.string("host"), std::string("component"));
    CHECK_EQ(j.string("format"), std::string("elf64"));
    CHECK_EQ(j.string("declarations"), std::string("absent"));
    CHECK_EQ(j.string("sha256").size(), size_t(64));
    CHECK(j.string("reason").find("internet") != std::string::npos);
    const caw::Json* blockedBy = j.get("blocked_by");
    CHECK(blockedBy && blockedBy->arr.size() == 1 && blockedBy->arr[0].str == "internet");
    const caw::Json* findings = j.get("findings");
    CHECK(findings && !findings->arr.empty());
    bool sawConnect = false;
    for (const caw::Json& f : findings ? findings->arr : std::vector<caw::Json>{}) {
        CHECK(f.get("capability") && f.get("title") && f.get("kind") && f.get("strength") && f.get("severity") &&
              f.get("declared") && f.get("blocks"));
        if (f.string("evidence") == "connect") {
            sawConnect = true;
            CHECK(f.boolean("blocks", false));
            CHECK_EQ(f.string("severity"), std::string("warning"));
        }
    }
    CHECK(sawConnect);
    char* plugin = caw_engine_scan_component(nullptr, path.c_str(), nullptr, CAW_SCAN_PLUGIN);
    CHECK(plugin && std::string(plugin).find(R"("verdict":"warning")") != std::string::npos);
    caw_free(plugin);
    char* grace = caw_engine_scan_component(nullptr, path.c_str(), nullptr, CAW_LOAD_LEGACY_GRACE);
    CHECK(grace && std::string(grace).find(R"("grace_applied":true)") != std::string::npos);
    caw_free(grace);
    char* missing = caw_engine_scan_component(nullptr, caw::pathText(dir / "none.so").c_str(), nullptr, 0);
    CHECK(missing && std::string(missing).find(R"("ok":false)") != std::string::npos);
    caw_free(missing);
    char* none = caw_engine_scan_component(nullptr, nullptr, nullptr, 0);
    CHECK(none && std::string(none).find(R"("ok":false)") != std::string::npos);
    caw_free(none);
    std::error_code ec;
    fs::remove_all(dir, ec);
}
