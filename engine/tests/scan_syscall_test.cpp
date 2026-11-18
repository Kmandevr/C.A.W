// The pre-load scan's syscall rule on hand-built AArch64 ELF fixtures: a call site loading the futex number is a
// runtime notice; a disallowed number, a non-constant argument, or syscall's address taken is certain (blocks).
#include <cstdint>
#include <vector>

#include "scan/policy.h"
#include "scan/scan.h"
#include "scan_fixtures.h"
#include "test.h"

using namespace caw::scan;
using namespace caw::scantest;

namespace {

// How the one syscall call site passes its first argument, or how syscall is referenced.
enum class Site { Futex, Disallowed, NonConstant, AddressTaken };

// A minimal AArch64 shared object: a PLT stub that loads syscall's GOT slot, one call site, a RELA table with a
// JUMP_SLOT (or an ABS64 for "address taken") relocation for syscall. Everything's vaddr equals its file offset.
Bytes buildSyscallElf(Site site) {
    constexpr uint64_t kCode = 0x10000, kGot = 0x10100;
    Bytes b(0x10208, 0);
    const uint8_t ident[16] = {0x7f, 'E', 'L', 'F', 2, 1, 1};
    putBytes(b, 0, ident, 16);
    put16(b, 16, 3);           // ET_DYN
    put16(b, 18, 183);         // AArch64
    put32(b, 20, 1);
    put64(b, 32, 64);          // e_phoff
    put16(b, 52, 64);
    put16(b, 54, 56);
    put16(b, 56, 3);           // e_phnum
    const uint64_t dynstr = 0x100, dynsym = 0x120, hash = 0x160, rela = 0x180, dyn = 0x1c0;
    auto ph = [&](int i, uint32_t t, uint32_t fl, uint64_t off, uint64_t sz) {
        const uint64_t p = 64 + uint64_t(i) * 56;
        put32(b, p, t);
        put32(b, p + 4, fl);
        put64(b, p + 8, off);
        put64(b, p + 16, off);
        put64(b, p + 24, off);
        put64(b, p + 32, sz);
        put64(b, p + 40, sz);
        put64(b, p + 48, 8);
    };
    ph(0, 1, 4, 0, 0x10000);            // R: headers, dynamic
    ph(1, 1, 5, kCode, 0x208);          // R+X: code and GOT
    ph(2, 2, 6, dyn, 9 * 16);           // DYNAMIC
    const char str[] = "\0syscall";
    putBytes(b, dynstr, str, sizeof str);  // includes the trailing NUL
    put32(b, dynsym + 24 + 0, 1);          // symbol 1: name offset 1 ("syscall")
    b[dynsym + 24 + 4] = 0x12;             // GLOBAL FUNC, st_shndx 0 (undefined: an import)
    put32(b, hash, 1);                     // nbucket
    put32(b, hash + 4, 2);                 // nchain (two symbols)
    const int64_t dynTable[9][2] = {{5, int64_t(dynstr)}, {10, int64_t(sizeof str)}, {6, int64_t(dynsym)},
                                    {11, 24}, {4, int64_t(hash)}, {7, int64_t(rela)}, {8, 24}, {9, 24}, {0, 0}};
    for (int i = 0; i < 9; ++i) {
        put64(b, dyn + uint64_t(i) * 16, uint64_t(dynTable[i][0]));
        put64(b, dyn + uint64_t(i) * 16 + 8, uint64_t(dynTable[i][1]));
    }
    // RELA: one relocation for symbol 1 at the GOT slot. JUMP_SLOT (1026), or ABS64 (257) for "address taken".
    put64(b, rela, kGot);
    put64(b, rela + 8, (uint64_t(1) << 32) | (site == Site::AddressTaken ? 257u : 1026u));
    // The PLT stub: adrp x16, <code page>; ldr x17, [x16, #0x100]; br x17.
    put32(b, kCode + 0, 0x90000010u);
    put32(b, kCode + 4, 0xF9408211u);
    put32(b, kCode + 8, 0xD61F0220u);
    // The call site at kCode+0x20: set up w0, then bl to the stub.
    const uint64_t callSite = kCode + 0x20;
    if (site == Site::NonConstant)
        put32(b, callSite, 0xB94003E0u);            // ldr w0, [sp]
    else
        put32(b, callSite, 0x52800000u | (uint32_t(site == Site::Disallowed ? 203 : 98) << 5));  // movz w0, #n
    const int32_t rel = int32_t((kCode - (callSite + 4)) / 4);
    put32(b, callSite + 4, 0x94000000u | (uint32_t(rel) & 0x03FFFFFFu));  // bl stub
    return b;
}

const Finding* syscallFinding(const Report& r) {
    for (const Finding& f : r.findings)
        if (f.capability == Capability::Packed && f.kind == FindingKind::Import && f.evidence.rfind("syscall", 0) == 0)
            return &f;
    return nullptr;
}

Verdict componentVerdict(const Report& r) { return decide(r, {Host::Component, false}).verdict; }

}  // namespace

TEST(scan_syscall_futex_call_site_is_a_runtime_notice) {
    const Report r = scanBinary(buildSyscallElf(Site::Futex));
    CHECK(!r.malformed);
    const Finding* f = syscallFinding(r);
    CHECK(f != nullptr);
    if (f) {
        CHECK(f->strength == Strength::Hint);
        CHECK(f->severity == Severity::Notice);
        CHECK(f->evidence.find("runtime only") != std::string::npos);
        CHECK(f->evidence.find("98") != std::string::npos);
    }
    CHECK(componentVerdict(r) != Verdict::Blocked);
}

TEST(scan_syscall_disallowed_number_is_certain) {
    const Report r = scanBinary(buildSyscallElf(Site::Disallowed));
    const Finding* f = syscallFinding(r);
    CHECK(f != nullptr);
    if (f) {
        CHECK(f->strength == Strength::Certain);
        CHECK(f->evidence.find("203") != std::string::npos);
    }
    CHECK(componentVerdict(r) == Verdict::Blocked);
}

TEST(scan_syscall_non_constant_argument_blocks) {
    const Report r = scanBinary(buildSyscallElf(Site::NonConstant));
    const Finding* f = syscallFinding(r);
    CHECK(f && f->strength == Strength::Certain);
    if (f) CHECK(f->evidence.find("can't be read") != std::string::npos);
    CHECK(componentVerdict(r) == Verdict::Blocked);
}

TEST(scan_syscall_address_taken_blocks) {
    const Report r = scanBinary(buildSyscallElf(Site::AddressTaken));
    const Finding* f = syscallFinding(r);
    CHECK(f && f->strength == Strength::Certain);
    if (f) CHECK(f->evidence.find("address is taken") != std::string::npos);
    CHECK(componentVerdict(r) == Verdict::Blocked);
}
