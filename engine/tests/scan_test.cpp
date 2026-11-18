// The pre-load scan on hand-built ELF64 and PE32+ files: findings, declarations, policy, and hostile input
// (every truncation, random byte flips, huge counts and offsets) that must never crash.
#include <cstdint>
#include <random>
#include <string>
#include <vector>

#include "scan/declarations.h"
#include "scan/policy.h"
#include "scan/scan.h"
#include "scan/sha256.h"
#include "scan_fixtures.h"
#include "test.h"

using namespace caw::scan;
using namespace caw::scantest;

namespace {

Report scan(const Bytes& b) { return scanBinary(b); }

const Finding* find(const Report& r, Capability c, FindingKind k, const std::string& evidence = {}) {
    for (const Finding& f : r.findings)
        if (f.capability == c && f.kind == k && (evidence.empty() || f.evidence.find(evidence) != std::string::npos))
            return &f;
    return nullptr;
}

const Finding* exact(const Report& r, const std::string& evidence) {
    for (const Finding& f : r.findings)
        if (f.evidence == evidence) return &f;
    return nullptr;
}

bool hasKind(const Report& r, FindingKind k) {
    for (const Finding& f : r.findings)
        if (f.kind == k) return true;
    return false;
}

Verdict componentVerdict(const Report& r, bool grace = false) { return decide(r, {Host::Component, grace}).verdict; }
Verdict pluginVerdict(const Report& r) { return decide(r, {Host::Plugin, false}).verdict; }

Bytes declarationBytes(const std::string& json) {
    Bytes b(json.begin(), json.end());
    b.push_back(0);
    return b;
}

constexpr const char* kEmptyDeclarations = R"({"format":"caw.capabilities","version":1,"capabilities":[]})";

}  // namespace

TEST(scan_sha256_matches_the_standard_vectors) {
    CHECK_EQ(sha256Hex({}), std::string("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"));
    const std::string abc = "abc";
    CHECK_EQ(sha256Hex({reinterpret_cast<const uint8_t*>(abc.data()), abc.size()}),
             std::string("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"));
    const std::string two = "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq";
    CHECK_EQ(sha256Hex({reinterpret_cast<const uint8_t*>(two.data()), two.size()}),
             std::string("248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"));
    Sha256 h;  // a million 'a', fed unevenly
    const std::string chunk(997, 'a');
    size_t left = 1000000;
    while (left) {
        const size_t n = left < chunk.size() ? left : chunk.size();
        h.update(reinterpret_cast<const uint8_t*>(chunk.data()), n);
        left -= n;
    }
    CHECK_EQ(toHex(h.digest()), std::string("cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"));
}

TEST(scan_a_plain_elf_component_is_clean) {
    ElfSpec s;
    s.imports = {"memcpy", "memset", "_Znwm", "__cxa_atexit", "pthread_mutex_lock", "sinf"};
    s.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}};
    const Report r = scan(buildElf(s));
    CHECK(r.format == Format::Elf64);
    CHECK_EQ(r.arch, std::string("x86_64"));
    CHECK(!r.malformed);
    CHECK_EQ(r.imports, uint64_t(6));
    CHECK(r.componentEntry);
    CHECK(r.declarationState == Report::DeclarationState::Valid);
    CHECK(r.findings.empty());
    CHECK(componentVerdict(r) == Verdict::Clean);
}

TEST(scan_elf_imports_fall_into_their_capabilities) {
    ElfSpec s;
    s.imports = {"connect", "getaddrinfo", "execve", "dlopen", "mprotect", "ptrace", "pthread_create", "fopen",
                 "unlink", "EVP_EncryptInit_ex", "JNI_GetCreatedJavaVMs", "XGrabKeyboard", "syscall", "open",
                 "_ZNSt6thread15_M_start_threadESt10unique_ptrINS_6_StateESt14default_deleteIS1_EEPFvvE",
                 "_ZNSt10filesystem6removeERKNS_7__cxx114pathE",
                 "_ZNKSt10filesystem7__cxx114path11parent_pathEv"};
    s.exports = {"caw_get_component_v3", "JNI_OnLoad"};
    const Report r = scan(buildElf(s));
    CHECK(!r.malformed);
    CHECK(find(r, Capability::Internet, FindingKind::Import, "connect"));
    CHECK(find(r, Capability::Internet, FindingKind::Import, "getaddrinfo"));
    CHECK(find(r, Capability::StartPrograms, FindingKind::Import, "execve"));
    CHECK(find(r, Capability::StartPrograms, FindingKind::Import, "ptrace"));
    CHECK(find(r, Capability::LoadCode, FindingKind::Import, "dlopen"));
    CHECK(find(r, Capability::Encryption, FindingKind::Import, "EVP_EncryptInit_ex"));
    CHECK(find(r, Capability::AndroidSystem, FindingKind::Import, "JNI_GetCreatedJavaVMs"));
    CHECK(find(r, Capability::AndroidSystem, FindingKind::Export, "JNI_OnLoad"));
    CHECK(find(r, Capability::InputSpying, FindingKind::Import, "XGrabKeyboard"));
    CHECK(find(r, Capability::BackgroundThreads, FindingKind::Import, "pthread_create"));
    CHECK(find(r, Capability::BackgroundThreads, FindingKind::Import, "_M_start_thread"));
    CHECK(find(r, Capability::ReadFiles, FindingKind::Import, "fopen"));
    CHECK(find(r, Capability::WriteFiles, FindingKind::Import, "unlink"));
    CHECK(find(r, Capability::WriteFiles, FindingKind::Import, "6remove"));
    CHECK(!find(r, Capability::ReadFiles, FindingKind::Import, "parent_path"));  // path text only
    const Finding* mp = find(r, Capability::MakeCode, FindingKind::Import, "mprotect");
    CHECK(mp && mp->strength == Strength::Hint);
    const Finding* sc = find(r, Capability::Packed, FindingKind::Import, "syscall");
    CHECK(sc && sc->severity == Severity::Notice && sc->strength == Strength::Hint);
    const Finding* op = exact(r, "open");
    CHECK(op && op->strength == Strength::Hint);
    const Finding* fo = find(r, Capability::ReadFiles, FindingKind::Import, "fopen");
    CHECK(fo && fo->severity == Severity::Notice && fo->strength == Strength::Certain);
    const Finding* net = find(r, Capability::Internet, FindingKind::Import, "connect");
    CHECK(net && net->severity == Severity::Warning && net->strength == Strength::Certain);
}

TEST(scan_policy_blocks_an_undeclared_component_capability_and_names_it) {
    ElfSpec s;
    s.imports = {"memcpy", "connect", "pthread_create", "mprotect"};
    s.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}};
    const Report r = scan(buildElf(s));
    const Decision d = decide(r, {Host::Component, false});
    CHECK(d.verdict == Verdict::Blocked);
    CHECK((d.blockedBy & capabilityBit(Capability::Internet)) != 0);
    CHECK((d.blockedBy & capabilityBit(Capability::BackgroundThreads)) != 0);
    CHECK((d.blockedBy & capabilityBit(Capability::MakeCode)) == 0);  // a hint never blocks
    CHECK(d.reason.find("internet") != std::string::npos);
    CHECK(d.reason.find("connect") != std::string::npos);
    CHECK(d.reason.find("background_threads") != std::string::npos);
    // A component that carries a declaration section can't take the legacy grace.
    CHECK(componentVerdict(r, true) == Verdict::Blocked);
    // The same findings for a CLAP/VST3 plug-in warn at most, and threads stay notices there.
    const Decision p = decide(r, {Host::Plugin, false});
    CHECK(p.verdict == Verdict::Warning);
    for (const Weighed& w : p.findings) {
        CHECK(!w.blocks);
        if (w.finding.capability == Capability::BackgroundThreads) CHECK(w.severity == Severity::Notice);
    }
}

TEST(scan_declared_capabilities_turn_their_findings_into_notices) {
    ElfSpec s;
    s.imports = {"connect", "pthread_create"};
    const std::string caps =
        R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"internet","reason":"Downloads presets",)"
        R"("sites":["presets.example.com"]},{"id":"background_threads","reason":"Loads samples"}]})";
    s.extraSections = {{"caw_caps", declarationBytes(caps)}};
    const Report r = scan(buildElf(s));
    CHECK(r.declarationState == Report::DeclarationState::Valid);
    CHECK_EQ(r.declarations.size(), size_t(2));
    CHECK_EQ(r.declarationsCanonical, caps);
    const Decision d = decide(r, {Host::Component, false});
    CHECK(d.verdict == Verdict::Notice);
    for (const Weighed& w : d.findings) CHECK(w.declared && w.severity == Severity::Notice);
}

TEST(scan_legacy_grace_turns_a_block_into_warnings_only_without_a_section) {
    ElfSpec s;
    s.imports = {"connect"};
    const Report r = scan(buildElf(s));
    CHECK(r.declarationState == Report::DeclarationState::Absent);
    CHECK(componentVerdict(r) == Verdict::Blocked);
    const Decision d = decide(r, {Host::Component, true});
    CHECK(d.verdict == Verdict::Warning);
    CHECK(d.graceApplied);
    // Never for a malformed file.
    Bytes bad = buildElf(s);
    put64(bad, 32, uint64_t(1) << 40);  // program headers far outside
    const Report m = scan(bad);
    CHECK(m.malformed);
    CHECK(componentVerdict(m, true) == Verdict::Blocked);
}

TEST(scan_invalid_declarations_block_whatever_else_they_say) {
    const std::vector<std::string> bad = {
        R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"network","reason":"x"}]})",  // unknown id
        R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"internet","reason":"a"},{"id":"internet","reason":"b"}]})",
        R"({"format":"caw.capabilities","version":2,"capabilities":[]})",
        R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"read_files","reason":""}]})",
        R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"read_files","reason":"x","sites":["a.com"]}]})",
        R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"internet","reason":"x","sites":["A.com"]}]})",
        R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"internet","reason":"x","extra":1}]})",
        R"({"version":1,"format":"caw.capabilities","capabilities":[]})",  // not canonical (key order)
        R"({"format":"caw.capabilities", "version":1,"capabilities":[]})",  // not canonical (space)
        R"({"format":"caw.capabilities","version":1,"capabilities":[)",
        std::string(R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"internet","reason":")") +
            std::string(201, 'x') + "\"}]}",
        std::string(R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"internet","reason":"a)") + "\x01" +
            "\"}]}"};
    for (const std::string& json : bad) {
        ElfSpec s;
        s.extraSections = {{"caw_caps", declarationBytes(json)}};
        const Report r = scan(buildElf(s));
        CHECK(r.declarationState == Report::DeclarationState::Invalid);
        CHECK(hasKind(r, FindingKind::Declarations));
        CHECK(componentVerdict(r) == Verdict::Blocked);
        CHECK(componentVerdict(r, true) == Verdict::Blocked);
    }
    // Two sections, or two declarations in one section, block too.
    ElfSpec two;
    two.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}, {"caw_caps", declarationBytes(kEmptyDeclarations)}};
    CHECK(componentVerdict(scan(buildElf(two))) == Verdict::Blocked);
    ElfSpec joined;
    Bytes both = declarationBytes(kEmptyDeclarations);
    const Bytes again = declarationBytes(kEmptyDeclarations);
    both.insert(both.end(), again.begin(), again.end());
    joined.extraSections = {{"caw_caps", both}};
    CHECK(componentVerdict(scan(buildElf(joined))) == Verdict::Blocked);
    // More than 16 entries.
    std::string many = R"({"format":"caw.capabilities","version":1,"capabilities":[)";
    for (int i = 0; i < 17; ++i) many += std::string(i ? "," : "") + R"({"id":"packed","reason":"x"})";
    std::vector<Declaration> out;
    std::string error;
    CHECK(!parseDeclarationSection(many + "]}", 16384, 16, out, error));
}

TEST(scan_the_canonical_form_round_trips) {
    std::vector<Declaration> list{{Capability::Internet, "Says \"hi\" \\ to caf\xc3\xa9", {"a.example.com"}},
                                  {Capability::ReadFiles, "Loads; samples", {}}};
    const std::string text = canonicalDeclarations(list);
    CHECK_EQ(text, std::string(R"({"format":"caw.capabilities","version":1,"capabilities":[{"id":"internet",)"
                               R"("reason":"Says \"hi\" \\ to caf)") + "\xc3\xa9" +
                       R"(","sites":["a.example.com"]},{"id":"read_files","reason":"Loads; samples"}]})");
    std::vector<Declaration> back;
    std::string error;
    CHECK(parseDeclarationSection(text + std::string(5, '\0'), 16384, 16, back, error));
    CHECK_EQ(back.size(), size_t(2));
    CHECK_EQ(back[0].reason, list[0].reason);
}

TEST(scan_aarch64_svc_blocks_and_x86_syscall_only_hints) {
    ElfSpec arm;
    arm.machine = 183;
    arm.code = {0x1f, 0x20, 0x03, 0xd5, 0x01, 0x00, 0x00, 0xd4, 0xc0, 0x03, 0x5f, 0xd6, 0, 0, 0, 0};  // nop; svc #0; ret
    arm.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}};
    const Report a = scan(buildElf(arm));
    CHECK_EQ(a.arch, std::string("aarch64"));
    const Finding* svc = find(a, Capability::Packed, FindingKind::Syscall, "svc #0");
    CHECK(svc && svc->strength == Strength::Certain);
    CHECK(componentVerdict(a) == Verdict::Blocked);
    // Misaligned, the same bytes are data.
    arm.code = {0x00, 0x01, 0x00, 0x00, 0xd4, 0, 0, 0};
    CHECK(!find(scan(buildElf(arm)), Capability::Packed, FindingKind::Syscall));

    ElfSpec x86;
    x86.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}};
    x86.code = {0xb8, 0x3b, 0, 0, 0, 0x0f, 0x05, 0xc3};  // mov eax, 59; syscall; ret
    const Report x = scan(buildElf(x86));
    const Finding* strong = find(x, Capability::Packed, FindingKind::Syscall, "system call number");
    CHECK(strong && strong->strength == Strength::Hint && strong->severity == Severity::Warning);
    CHECK(componentVerdict(x) == Verdict::Warning);
    x86.code = {0x90, 0x0f, 0x05, 0xc3};
    const Report w = scan(buildElf(x86));
    const Finding* weak = find(w, Capability::Packed, FindingKind::Syscall);
    CHECK(weak && weak->severity == Severity::Notice);
}

TEST(scan_writable_code_packers_entropy_and_load_time_code) {
    ElfSpec s;
    s.writableCode = true;
    s.initArrayBytes = 8 * 40;
    s.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}, {"UPX1", Bytes(16, 1)}};
    std::mt19937 rng(7);
    s.code.resize(8192);
    for (uint8_t& c : s.code) c = uint8_t(rng());
    const Report r = scan(buildElf(s));
    CHECK(find(r, Capability::Packed, FindingKind::Section, "writable and executable"));
    CHECK(find(r, Capability::Packed, FindingKind::Section, "packer section UPX1"));
    CHECK(find(r, Capability::Packed, FindingKind::Entropy, "executable code"));
    CHECK_EQ(r.constructors, uint64_t(40));
    const Finding* lt = find(r, Capability::Packed, FindingKind::LoadTime);
    CHECK(lt && lt->severity == Severity::Notice);
    CHECK(componentVerdict(r) == Verdict::Blocked);
}

TEST(scan_strings_flag_urls_shells_onion_and_wallets) {
    ElfSpec s;
    s.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}};
    for (const char* text : {"https://evil.example.com/x", "/system/bin/sh",
                             "abcdefghijklmnopqrstuvwxyz234567abcdefghijklmnopqrstuv.onion",
                             "C:\\Users\\a\\AppData\\Roaming\\Bitcoin\\wallet.dat", "ip 10.0.0.8 here"}) {
        s.data += text;
        s.data.push_back('\0');
    }
    // A UTF-16LE string, as Windows code keeps them.
    for (char c : std::string("powershell -enc")) {
        s.data.push_back(c);
        s.data.push_back('\0');
    }
    const Report r = scan(buildElf(s));
    const Finding* url = find(r, Capability::Internet, FindingKind::String, "https://evil.example.com/x");
    CHECK(url && url->severity == Severity::Notice);
    CHECK(find(r, Capability::StartPrograms, FindingKind::String, "/system/bin/sh"));
    CHECK(find(r, Capability::StartPrograms, FindingKind::String, "powershell"));
    CHECK(find(r, Capability::Internet, FindingKind::String, ".onion"));
    CHECK(find(r, Capability::ReadFiles, FindingKind::String, "wallet.dat"));
    CHECK(find(r, Capability::Internet, FindingKind::String, "10.0.0.8"));
    // Strings are hints: they warn, never block.
    CHECK(componentVerdict(r) == Verdict::Warning);
}

TEST(scan_pe_imports_ordinals_tls_and_writable_code) {
    PeSpec s;
    s.imports = {{"KERNEL32.dll", {"CreateProcessW", "LoadLibraryExW", "GetCurrentThreadId", "CreateFileW", "VirtualProtect"}},
                 {"WS2_32.dll", {"#4"}},
                 {"ADVAPI32.dll", {"RegSetValueExW", "CryptEncrypt"}},
                 {"api-ms-win-crt-stdio-l1-1-0.dll", {"fopen"}}};
    s.tlsCallbacks = 2;
    s.writableCode = true;
    s.extraSections = {{".cawcap", declarationBytes(kEmptyDeclarations)}};
    const Report r = scan(buildPe(s));
    CHECK(r.format == Format::Pe32Plus);
    CHECK_EQ(r.arch, std::string("x86_64"));
    CHECK(!r.malformed);
    CHECK(r.declarationState == Report::DeclarationState::Valid);
    CHECK(find(r, Capability::StartPrograms, FindingKind::Import, "kernel32.dll!CreateProcessW"));
    CHECK(find(r, Capability::LoadCode, FindingKind::Import, "LoadLibraryExW"));
    CHECK(find(r, Capability::ReadFiles, FindingKind::Import, "CreateFileW"));
    CHECK(find(r, Capability::MakeCode, FindingKind::Import, "VirtualProtect"));
    CHECK(find(r, Capability::Internet, FindingKind::Library, "ws2_32.dll"));
    CHECK(find(r, Capability::InputSpying, FindingKind::Import, "RegSetValueExW"));
    CHECK(find(r, Capability::Encryption, FindingKind::Import, "CryptEncrypt"));
    CHECK(find(r, Capability::ReadFiles, FindingKind::Import, "fopen"));
    CHECK(!find(r, Capability::BackgroundThreads, FindingKind::Import, "GetCurrentThreadId"));
    CHECK_EQ(r.tlsCallbacks, uint64_t(2));
    const Finding* tls = find(r, Capability::Packed, FindingKind::LoadTime, "TLS");
    CHECK(tls && tls->severity == Severity::Notice);
    CHECK(find(r, Capability::Packed, FindingKind::Section, "writable and executable: .text"));
    CHECK(componentVerdict(r) == Verdict::Blocked);
    CHECK(pluginVerdict(r) == Verdict::Warning);
    // A plain one is clean.
    PeSpec plain;
    plain.imports = {{"KERNEL32.dll", {"GetCurrentThreadId", "IsDebuggerPresent", "QueryPerformanceCounter"}},
                     {"VCRUNTIME140.dll", {"memcpy", "__C_specific_handler"}}};
    plain.extraSections = {{".cawcap", declarationBytes(kEmptyDeclarations)}};
    const Report p = scan(buildPe(plain));
    CHECK(!p.malformed);
    CHECK(componentVerdict(p) == Verdict::Clean);
}

TEST(scan_unknown_formats_and_32_bit_files_are_unsupported) {
    for (const Bytes& b : {Bytes{}, Bytes{0x7f}, Bytes{0xcf, 0xfa, 0xed, 0xfe, 7, 0, 0, 1}, Bytes(100, 'a')}) {
        const Report r = scan(b);
        CHECK(r.format == Format::Unknown);
        CHECK(hasKind(r, FindingKind::Unsupported));
        CHECK(componentVerdict(r) == Verdict::Blocked);
        CHECK(pluginVerdict(r) == Verdict::Warning);
    }
    Bytes elf32 = buildElf({});
    elf32[4] = 1;
    CHECK(hasKind(scan(elf32), FindingKind::Unsupported));
    Bytes pe32 = buildPe({});
    put16(pe32, 0x44 + 20, 0x10B);
    CHECK(hasKind(scan(pe32), FindingKind::Unsupported));
}

TEST(scan_survives_every_truncation_of_its_fixtures) {
    ElfSpec e;
    e.imports = {"connect", "memcpy"};
    e.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}};
    PeSpec p;
    p.imports = {{"KERNEL32.dll", {"CreateProcessW"}}, {"WS2_32.dll", {"#4", "connect"}}};
    p.tlsCallbacks = 1;
    p.extraSections = {{".cawcap", declarationBytes(kEmptyDeclarations)}};
    for (const Bytes& full : {buildElf(e), buildPe(p)}) {
        CHECK(!scan(full).malformed);
        for (size_t n = 0; n < full.size(); ++n) {
            const Bytes cut(full.begin(), full.begin() + static_cast<std::ptrdiff_t>(n));
            const Report r = scan(cut);
            // Malformed, unsupported or (when only the tail went) still readable: never a crash, and a component
            // cut so it parses no longer is never let through on a clean verdict.
            if (r.malformed || hasKind(r, FindingKind::Unsupported)) CHECK(componentVerdict(r) == Verdict::Blocked);
        }
    }
}

TEST(scan_survives_random_byte_flips) {
    ElfSpec e;
    e.imports = {"connect", "memcpy", "pthread_create"};
    e.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}};
    PeSpec p;
    p.imports = {{"KERNEL32.dll", {"CreateProcessW", "GetProcAddress"}}, {"WS2_32.dll", {"#4", "connect"}}};
    p.tlsCallbacks = 3;
    const std::vector<Bytes> fixtures{buildElf(e), buildPe(p)};
    std::mt19937 rng(20261118);
    size_t malformed = 0;
    for (const Bytes& base : fixtures) {
        for (int round = 0; round < 3000; ++round) {
            Bytes b = base;
            const int flips = 1 + int(rng() % 8);
            for (int i = 0; i < flips; ++i) {
                const size_t at = rng() % b.size();
                b[at] = (rng() % 3 == 0) ? uint8_t(0xff) : uint8_t(rng());
            }
            const Report r = scan(b);
            if (r.malformed) {
                ++malformed;
                CHECK(componentVerdict(r) == Verdict::Blocked);
            }
        }
    }
    CHECK(malformed > 0);
}

TEST(scan_refuses_huge_counts_and_offsets_without_reading_them) {
    ElfLayout layout;
    ElfSpec e;
    e.imports = {"memcpy"};
    const Bytes base = buildElf(e, &layout);
    auto malformedAfter = [&](auto change) {
        Bytes b = base;
        change(b);
        const Report r = scan(b);
        return r.malformed && componentVerdict(r) == Verdict::Blocked;
    };
    CHECK(malformedAfter([](Bytes& b) { put16(b, 56, 0xffff); }));                           // e_phnum
    CHECK(malformedAfter([](Bytes& b) { put64(b, 32, ~uint64_t(0) - 8); }));                 // e_phoff near 2^64
    CHECK(malformedAfter([&](Bytes& b) { put16(b, 60, 0xfff0); }));                          // e_shnum
    CHECK(malformedAfter([&](Bytes& b) { put64(b, 40, ~uint64_t(0) - 63); }));               // e_shoff
    CHECK(malformedAfter([&](Bytes& b) { put32(b, layout.hash + 4, 0xffffffffu); }));        // nchain
    CHECK(malformedAfter([&](Bytes& b) { put64(b, layout.dynamic + 16 + 8, ~uint64_t(0)); }));  // DT_STRTAB
    CHECK(malformedAfter([&](Bytes& b) { put64(b, layout.dynamic + 32 + 8, uint64_t(1) << 62); }));  // DT_STRSZ
    CHECK(malformedAfter([&](Bytes& b) { put64(b, 64 + 2 * 56 + 32, uint64_t(1) << 60); }));  // PT_DYNAMIC size
    // A dynamic table of a million entries in a small file.
    CHECK(malformedAfter([&](Bytes& b) {
        put64(b, 64 + 2 * 56 + 32, 16ull << 20);
    }));

    PeLayout pl;
    PeSpec p;
    p.imports = {{"KERNEL32.dll", {"CreateProcessW"}}};
    const Bytes pe = buildPe(p, &pl);
    auto peMalformedAfter = [&](auto change) {
        Bytes b = pe;
        change(b);
        const Report r = scan(b);
        return r.malformed && componentVerdict(r) == Verdict::Blocked;
    };
    CHECK(peMalformedAfter([](Bytes& b) { put16(b, 0x44 + 2, 0xffff); }));                    // sections
    CHECK(peMalformedAfter([&](Bytes& b) { put32(b, pl.sectionTable + 20, 0xfffffff0u); }));  // raw pointer
    CHECK(peMalformedAfter([&](Bytes& b) { put32(b, pl.optional + 112 + 8, 0x7ffffff0u); }));  // import RVA
    CHECK(peMalformedAfter([&](Bytes& b) { put32(b, pl.idata + 12, 0xfffffff0u); }));          // DLL name RVA
    // A name table outside the file.
    CHECK(peMalformedAfter([&](Bytes& b) { put32(b, pl.idata, 0x7ffffff0u); }));
    Bytes ok = pe;
    put32(ok, 0x3c, 0xfffffff0u);  // e_lfanew outside: not a PE at all
    CHECK(hasKind(scan(ok), FindingKind::Unsupported));
}

TEST(scan_findings_of_one_kind_cannot_push_out_another) {
    ElfSpec s;
    s.extraSections = {{"caw_caps", declarationBytes(kEmptyDeclarations)}};
    for (int i = 0; i < 400; ++i) s.imports.push_back("EVP_EncryptInit_" + std::to_string(i));
    s.imports.push_back("connect");
    const Report r = scan(buildElf(s));
    CHECK(find(r, Capability::Internet, FindingKind::Import, "connect"));
    CHECK(r.findings.size() <= Limits{}.maxFindings);
}
