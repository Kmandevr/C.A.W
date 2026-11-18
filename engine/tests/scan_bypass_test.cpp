// The pre-load scan against ways around it (security review of PR #254): the dynamic table read where the loader
// reads it, dependencies the scan never saw, raw system calls, segment and section layouts the loaders read
// differently, packed relocations, ordinals, file writes and the loader holding the scanned file.
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <random>
#include <string>
#include <vector>

#include "caw.h"
#include "scan/policy.h"
#include "scan/scan.h"
#include "scan/scan_file.h"
#include "scan_fixtures.h"
#include "test.h"
#include "utf8_path.h"

#if defined(__linux__)
#include <link.h>
#endif

using namespace caw::scan;
using namespace caw::scantest;

namespace {

const Finding* find(const Report& r, Capability c, FindingKind k, const std::string& evidence = {}) {
    for (const Finding& f : r.findings)
        if (f.capability == c && f.kind == k && (evidence.empty() || f.evidence.find(evidence) != std::string::npos))
            return &f;
    return nullptr;
}

Verdict componentVerdict(const Report& r, bool grace = false) { return decide(r, {Host::Component, grace}).verdict; }

Bytes caps() {
    const std::string json = R"({"format":"caw.capabilities","version":1,"capabilities":[]})";
    Bytes b(json.begin(), json.end());
    b.push_back(0);
    return b;
}

ElfSpec plain() {
    ElfSpec s;
    s.imports = {"memcpy"};
    s.extraSections = {{"caw_caps", caps()}};
    return s;
}

std::filesystem::path tempDir(const char* name) {
    std::random_device device;
    const auto dir = std::filesystem::temp_directory_path() /
                     (std::string("caw_bypass_") + name + "_" + std::to_string(device()) + std::to_string(device()));
    std::filesystem::create_directories(dir);
    return dir;
}

}  // namespace

// 1. glibc and bionic read the dynamic table at p_vaddr; a file whose p_offset points elsewhere showed the scan
// a harmless table.
TEST(scan_bypass_dynamic_table_offset_and_address_must_agree) {
    const Bytes good = buildElf(plain());
    CHECK(!scanBinary(good).malformed);
    Bytes b = good;
    const size_t dynamicPh = 64 + 2 * 56;
    uint64_t vaddr = 0;
    for (int i = 0; i < 8; ++i) vaddr |= uint64_t(b[dynamicPh + 16 + i]) << (8 * i);
    put64(b, dynamicPh + 16, vaddr - 64);  // the loader would read 64 bytes earlier
    const Report r = scanBinary(b);
    CHECK(r.malformed);
    CHECK(componentVerdict(r, true) == Verdict::Blocked);
}

// 2. A dependency that is not a system library, or a library search path, loads code the scan never saw.
TEST(scan_bypass_non_system_dependencies_and_search_paths_block) {
    ElfSpec s = plain();
    s.needed = {"libc.so", "libpayload.so"};
    Report r = scanBinary(buildElf(s));
    CHECK(find(r, Capability::LoadCode, FindingKind::Dependency, "libpayload.so"));
    CHECK(componentVerdict(r) == Verdict::Blocked);
    CHECK(decide(r, {Host::Plugin, false}).verdict == Verdict::Warning);
    s = plain();
    s.runpath = "$ORIGIN";
    r = scanBinary(buildElf(s));
    CHECK(find(r, Capability::LoadCode, FindingKind::Dependency, "$ORIGIN"));
    CHECK(componentVerdict(r) == Verdict::Blocked);
    // Even with the legacy grace (an old build may not bring along code the scan never saw).
    s = plain();
    s.extraSections.clear();
    s.needed = {"libpayload.so"};
    CHECK(componentVerdict(scanBinary(buildElf(s)), true) == Verdict::Blocked);
    // The system's own libraries are fine.
    s = plain();
    s.needed = {"libc.so.6", "libm.so.6", "libstdc++.so.6", "libgcc_s.so.1", "liblog.so", "libc++_shared.so"};
    CHECK(componentVerdict(scanBinary(buildElf(s))) == Verdict::Clean);
    // The sanitizer runtime counts as a system library only in a sanitizer build of the engine, so the sanitizer
    // and TSan CI jobs can scan their instrumented components.
    s = plain();
    s.needed = {"libc.so.6", "libasan.so.8"};
    r = scanBinary(buildElf(s));
#ifdef CAW_SCAN_ALLOW_SANITIZER
    CHECK(!find(r, Capability::LoadCode, FindingKind::Dependency, "libasan"));
    CHECK(componentVerdict(r) == Verdict::Clean);
#else
    CHECK(find(r, Capability::LoadCode, FindingKind::Dependency, "libasan"));
    CHECK(componentVerdict(r) == Verdict::Blocked);
#endif
    PeSpec pe;
    pe.imports = {{"KERNEL32.dll", {"GetCurrentThreadId"}}, {"payload.dll", {"Run"}},
                  {"api-ms-win-crt-runtime-l1-1-0.dll", {"_initterm"}}, {"VCRUNTIME140.dll", {"memcpy"}}};
    pe.extraSections = {{".cawcap", caps()}};
    r = scanBinary(buildPe(pe));
    CHECK(find(r, Capability::LoadCode, FindingKind::Dependency, "payload.dll"));
    CHECK(!find(r, Capability::LoadCode, FindingKind::Dependency, "vcruntime140.dll"));
    CHECK(!find(r, Capability::LoadCode, FindingKind::Dependency, "api-ms-win-crt"));
    CHECK(componentVerdict(r) == Verdict::Blocked);
}

// 3. syscall() reaches any system call by number (connect, execve). An imported syscall that this fixture never
// calls is a notice; a real call to it is analysed per site in scan_syscall_test.cpp (futex passes, anything else
// blocks). An x86-64 component that calls it stays strict (certain) whatever the number.
TEST(scan_bypass_the_syscall_function_without_a_call_is_a_notice) {
    ElfSpec s = plain();
    s.imports = {"syscall"};
    const Report r = scanBinary(buildElf(s));
    const Finding* f = find(r, Capability::Packed, FindingKind::Import, "syscall");
    CHECK(f && f->strength == Strength::Hint);
    CHECK(componentVerdict(r) != Verdict::Blocked);
}

// 4. svc with any immediate is a system call on Linux; 5. the loader maps whole pages, so bytes beside the
// executable segment run too.
TEST(scan_bypass_svc_with_any_immediate_and_in_the_rounded_pages) {
    ElfSpec s = plain();
    s.machine = 183;
    s.code = {0x01, 0x10, 0x00, 0xd4, 0xc0, 0x03, 0x5f, 0xd6};  // svc #0x80; ret
    Report r = scanBinary(buildElf(s));
    const Finding* f = find(r, Capability::Packed, FindingKind::Syscall, "svc");
    CHECK(f && f->strength == Strength::Certain);
    CHECK(componentVerdict(r) == Verdict::Blocked);
    s = plain();
    s.machine = 183;
    s.code = {0xc0, 0x03, 0x5f, 0xd6};               // ret
    s.data = std::string("\x01\x00\x00\xd4", 4);      // svc #0 in the read-only segment, in the same 64 KiB page
    r = scanBinary(buildElf(s));
    CHECK(find(r, Capability::Packed, FindingKind::Syscall, "svc"));
    CHECK(componentVerdict(r) == Verdict::Blocked);
}

// 15. x86-64: a system call made in the executable pages but outside the named .text section, and int 0x80.
TEST(scan_bypass_x86_system_calls_outside_text_and_int_0x80) {
    ElfSpec s = plain();
    s.data = std::string("\xb8\x3b\x00\x00\x00\x0f\x05", 7);  // mov eax, 59; syscall, beside the code
    Report r = scanBinary(buildElf(s));
    const Finding* f = find(r, Capability::Packed, FindingKind::Syscall, "call number");
    CHECK(f && f->strength == Strength::Certain);
    CHECK(componentVerdict(r) == Verdict::Blocked);
    s = plain();
    s.code = {0xb8, 0x0b, 0, 0, 0, 0xcd, 0x80, 0xc3};  // mov eax, 11; int 0x80
    r = scanBinary(buildElf(s));
    CHECK(componentVerdict(r) == Verdict::Blocked);
    s = plain();
    s.code = {0x90, 0xcd, 0x80, 0xc3};  // the bytes alone: a hint
    r = scanBinary(buildElf(s));
    f = find(r, Capability::Packed, FindingKind::Syscall);
    CHECK(f && f->strength == Strength::Hint);
    CHECK(componentVerdict(r) == Verdict::Notice);
}

// 8. Overlapping or unsorted loadable segments map differently than they read.
TEST(scan_bypass_overlapping_segments_are_malformed) {
    Bytes b = buildElf(plain());
    put64(b, 64 + 56 + 16, 0);  // the code segment's address inside the first segment
    CHECK(scanBinary(b).malformed);
}

// 9. Android's packed relocations can reach symbols the hash table does not count.
TEST(scan_bypass_imports_reached_only_by_packed_relocations) {
    ElfSpec s = plain();
    s.sectionHeaders = false;  // the section table would count them
    s.extraSections.clear();
    s.hiddenImports = {"connect"};
    const Report r = scanBinary(buildElf(s));
    CHECK(!r.malformed);
    CHECK(find(r, Capability::Internet, FindingKind::Import, "connect"));
    CHECK(componentVerdict(r) == Verdict::Blocked);
    // A stream that is not APS2 is malformed.
    Bytes bad = buildElf(s);
    for (size_t i = 0; i + 4 <= bad.size(); ++i)
        if (bad[i] == 'A' && bad[i + 1] == 'P' && bad[i + 2] == 'S' && bad[i + 3] == '2') bad[i + 3] = '9';
    CHECK(scanBinary(bad).malformed);
}

// 6, 7. PE sections must be laid out as Windows maps them.
TEST(scan_bypass_pe_layouts_windows_maps_differently_are_malformed) {
    PeSpec p;
    p.imports = {{"KERNEL32.dll", {"GetCurrentThreadId"}}};
    p.extraSections = {{".cawcap", caps()}};
    PeLayout layout;
    const Bytes good = buildPe(p, &layout);
    CHECK(!scanBinary(good).malformed);
    Bytes b = good;
    put32(b, layout.sectionTable + 40 + 12, 0x400);  // the second section at the first one's address
    CHECK(scanBinary(b).malformed);
    b = good;
    put32(b, layout.sectionTable + 20, 0x410);  // a raw pointer Windows would round down
    CHECK(scanBinary(b).malformed);
    b = good;
    put32(b, layout.optional + 36, 0x300);  // FileAlignment not a power of two
    CHECK(scanBinary(b).malformed);
    b = good;
    put32(b, layout.optional + 32, 0x1000);  // SectionAlignment a page, sections at 0x200 steps
    CHECK(scanBinary(b).malformed);
}

// 14. Imports by ordinal hide the function.
TEST(scan_bypass_imports_by_ordinal) {
    PeSpec p;
    p.imports = {{"WS2_32.dll", {"#4"}}, {"KERNEL32.dll", {"#123"}}};
    p.extraSections = {{".cawcap", caps()}};
    const Report r = scanBinary(buildPe(p));
    const Finding* net = find(r, Capability::Internet, FindingKind::Import, "ws2_32.dll!#ordinal");
    CHECK(net && net->strength == Strength::Certain);
    const Finding* hidden = find(r, Capability::Packed, FindingKind::Import, "kernel32.dll by ordinal");
    CHECK(hidden && hidden->strength == Strength::Hint);
}

// 13. Writes through an opened file, threads and loaders below the usual names, ntdll.
TEST(scan_bypass_file_writes_clone_r_debug_and_ntdll) {
    ElfSpec s = plain();
    s.imports = {"fopen", "fwrite", "clone", "_r_debug", "dl_iterate_phdr"};
    Report r = scanBinary(buildElf(s));
    CHECK(find(r, Capability::WriteFiles, FindingKind::Import, "fopen + fwrite"));
    CHECK(find(r, Capability::BackgroundThreads, FindingKind::Import, "clone"));
    CHECK(find(r, Capability::LoadCode, FindingKind::Import, "_r_debug"));
    const Finding* unwinder = find(r, Capability::LoadCode, FindingKind::Import, "dl_iterate_phdr");
    CHECK(unwinder && unwinder->strength == Strength::Hint);  // every exception walks the libraries
    s = plain();
    s.imports = {"_ZNSt14basic_ofstreamIcSt11char_traitsIcEEC1EPKcSt13_Ios_Openmode"};
    CHECK(find(scanBinary(buildElf(s)), Capability::WriteFiles, FindingKind::Import, "basic_ofstream"));
    PeSpec p;
    p.imports = {{"ntdll.dll", {"NtCreateFile", "ZwDeviceIoControlFile", "NtCreateThreadEx"}}};
    r = scanBinary(buildPe(p));
    CHECK(find(r, Capability::ReadFiles, FindingKind::Import, "NtCreateFile"));
    CHECK(find(r, Capability::Internet, FindingKind::Import, "ZwDeviceIoControlFile"));
    CHECK(find(r, Capability::BackgroundThreads, FindingKind::Import, "NtCreateThreadEx"));
}

// Windows threads: std::thread goes through the UCRT's _beginthreadex or the STL's _Thrd_* (PR #254's Windows CI),
// the system thread pool through its own calls; another process's threads are starting programs.
TEST(scan_windows_thread_entry_points) {
    PeSpec p;
    p.imports = {{"api-ms-win-crt-runtime-l1-1-0.dll", {"_beginthreadex", "_beginthread"}},
                 {"MSVCP140.dll", {"_Thrd_create", "_Thrd_start"}},
                 {"KERNEL32.dll", {"CreateThreadpoolWork", "QueueUserWorkItem", "CreateRemoteThreadEx"}}};
    const Report r = scanBinary(buildPe(p));
    for (const char* name : {"_beginthreadex", "_beginthread", "_Thrd_create", "_Thrd_start", "CreateThreadpoolWork",
                             "QueueUserWorkItem"}) {
        const Finding* f = find(r, Capability::BackgroundThreads, FindingKind::Import, std::string("!") + name);
        if (!f || f->strength != Strength::Certain) cawtest::fail(__FILE__, __LINE__, std::string("not a thread: ") + name);
    }
    CHECK(find(r, Capability::StartPrograms, FindingKind::Import, "CreateRemoteThreadEx"));
}

// 12. Only regular files are read, and never past the cap (a device or pipe would never end).
TEST(scan_bypass_only_regular_files_are_read) {
    const auto dir = tempDir("regular");
    CHECK(!scanFile(caw::pathText(dir)).ok);
#if defined(__linux__)
    const FileScan zero = scanFile("/dev/zero");
    CHECK(!zero.ok);
    CawEngine* engine = caw_engine_create(48000);
    char* json = caw_engine_load_component(engine, "/dev/zero", "org.caw.tests.zero", CAW_NATIVE_TRUST_TRUSTED);
    CHECK(json && std::string(json).find("not a regular file") != std::string::npos);
    caw_free(json);
    caw_engine_destroy(engine);
#endif
    std::error_code ec;
    std::filesystem::remove_all(dir, ec);
}

#if defined(__linux__)
namespace {
int findByDescriptor(dl_phdr_info* info, size_t, void* found) {
    if (info->dlpi_name && std::string(info->dlpi_name).rfind("/proc/self/fd/", 0) == 0) *static_cast<bool*>(found) = true;
    return 0;
}
}  // namespace

// 10. The loader loads the very file it scanned: on Linux through the descriptor the scan read.
TEST(scan_bypass_the_loader_loads_the_descriptor_it_scanned) {
    CawEngine* engine = caw_engine_create(48000);
    char* json = caw_engine_load_component(engine, CAW_TEST_STARTER_PATH, "org.caw.starter.bass", CAW_NATIVE_TRUST_TRUSTED);
    const std::string text = json ? json : "";
    caw_free(json);
    CHECK(text.find(R"("ok":true)") != std::string::npos);
    bool found = false;
    dl_iterate_phdr(findByDescriptor, &found);
    CHECK(found);
    caw_engine_destroy(engine);
}
#endif
