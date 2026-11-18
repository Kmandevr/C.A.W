// Call-site analysis of an imported syscall() (syscall_sites.h): find its PLT stub through its GOT slot, every
// call or tail jump to it, and the constant each one loads into the first argument.
#include "syscall_sites.h"

#include <algorithm>
#include <unordered_set>

namespace caw::scan {
namespace {

constexpr uint16_t kAArch64 = 183, kX86_64 = 62;
constexpr uint32_t kAArch64JumpSlot = 1026, kX86JumpSlot = 7;
constexpr uint64_t kPage = 64 * 1024;
constexpr int kWindow = 8;  // instructions looked back at, AArch64

// The executable pages, as the loader maps them (64 KiB-rounded), with their addresses.
struct Code {
    uint64_t file = 0, size = 0, vaddr = 0;  // vaddr of byte `file`
};

std::vector<Code> codeRanges(const ByteReader& r, const Parsed& p) {
    std::vector<Code> out;
    for (const LoadSegment& s : p.loadSegments) {
        if (!s.exec) continue;
        const uint64_t start = s.offset / kPage * kPage;
        const uint64_t end = std::min<uint64_t>(r.size(), (s.offset + s.filesz + kPage - 1) / kPage * kPage);
        if (end > start) out.push_back({start, end - start, s.vaddr - (s.offset - start)});
    }
    return out;
}

int64_t signExtend(uint64_t v, int bits) {
    const uint64_t m = uint64_t(1) << (bits - 1);
    v &= (uint64_t(1) << bits) - 1;
    return int64_t((v ^ m) - m);
}

std::string hexOf(uint64_t v) {
    static const char kHex[] = "0123456789abcdef";
    std::string s;
    do {
        s.insert(s.begin(), kHex[v & 15]);
        v >>= 4;
    } while (v);
    return "0x" + s;
}

class Analysis {
public:
    Analysis(const ByteReader& r, const Parsed& p, WorkBudget& b) : r_(r), p_(p), budget_(b), code_(codeRanges(r, p)) {}

    SyscallUse run() {
        for (const Relocation& rel : p_.syscallRelocations) {
            const uint32_t slot = p_.machine == kAArch64 ? kAArch64JumpSlot : kX86JumpSlot;
            if (rel.type != slot) return fail("its address is taken (relocation type " + std::to_string(rel.type) + ")");
            got_.insert(rel.offset);
        }
        if (got_.empty()) {
            out_.runtimeOnly = true;
            out_.detail = "never called";
            return out_;
        }
        // Only AArch64 (the shipped Android ABI) gets call-site analysis: its fixed-width instructions read
        // cleanly. On x86-64 the variable-length encoding makes a precise reader far larger, and no x86-64
        // component ships (Android is arm64-only, Windows uses the MSVC runtime, which has no syscall import),
        // so an x86-64 component that calls the imported syscall stays strict (certain).
        const bool ok = p_.machine == kAArch64 ? aarch64()
                                               : failed("x86-64 components are scanned strictly (a static C++ "
                                                        "runtime's syscall use is not analysed on x86-64)");
        if (!ok) return out_;
        if (sites_ == 0) {
            out_.runtimeOnly = true;
            out_.detail = "never called";
            return out_;
        }
        out_.runtimeOnly = true;
        out_.detail = "runtime only:";
        for (uint64_t n : out_.numbers) out_.detail += " " + std::to_string(n);
        return out_;
    }

private:
    SyscallUse fail(const std::string& why) {
        out_.runtimeOnly = false;
        if (out_.detail.empty()) out_.detail = why;
        return out_;
    }
    bool failed(const std::string& why) {
        fail(why);
        return false;
    }
    bool number(uint64_t n, uint64_t at) {
        if (std::find(out_.numbers.begin(), out_.numbers.end(), n) == out_.numbers.end()) out_.numbers.push_back(n);
        ++sites_;
        if (!runtimeSyscall(p_.machine, n))
            return failed("syscall(" + std::to_string(n) + ") at " + hexOf(at));
        return true;
    }

    // ---- AArch64: fixed 4-byte instructions.
    template <class F>
    bool words(F&& f) {
        for (const Code& c : code_) {
            if (!budget_.spend(c.size / 4)) return failed("the scan's work budget ran out");
            for (uint64_t off = 0; off + 4 <= c.size; off += 4) {
                uint32_t w = 0;
                r_.u32(c.file + off, w);
                if (!f(c, off, c.vaddr + off, w)) return false;
            }
        }
        return true;
    }
    bool wordAt(uint64_t vaddr, uint32_t& w) const {
        for (const Code& c : code_)
            if (vaddr >= c.vaddr && vaddr - c.vaddr + 4 <= c.size) return r_.u32(c.file + (vaddr - c.vaddr), w);
        return false;
    }
    static bool directBranch(uint32_t w, uint64_t pc, uint64_t& target, bool& call, bool& conditional) {
        call = conditional = false;
        if ((w & 0x7C000000u) == 0x14000000u) {  // B, BL
            call = (w & 0x80000000u) != 0;
            target = pc + uint64_t(signExtend(w & 0x03FFFFFFu, 26) * 4);
            return true;
        }
        conditional = true;
        if ((w & 0xFF000010u) == 0x54000000u || (w & 0x7E000000u) == 0x34000000u) {  // B.cond, CBZ/CBNZ
            target = pc + uint64_t(signExtend((w >> 5) & 0x7FFFFu, 19) * 4);
            return true;
        }
        if ((w & 0x7E000000u) == 0x36000000u) {  // TBZ/TBNZ
            target = pc + uint64_t(signExtend((w >> 5) & 0x3FFFu, 14) * 4);
            return true;
        }
        return false;
    }
    static bool adrpPage(uint32_t w, uint64_t pc, uint64_t& page) {
        if ((w & 0x9F000000u) != 0x90000000u) return false;
        const uint64_t imm = (uint64_t((w >> 5) & 0x7FFFFu) << 2) | ((w >> 29) & 3u);
        page = (pc & ~uint64_t(0xFFF)) + uint64_t(signExtend(imm, 21) * 4096);
        return true;
    }
    // The address an ADRP at pc forms with one of the next 4 instructions (LDR/ADD on its register), if any.
    bool adrpTarget(uint64_t pc, uint32_t w, uint64_t& address, bool& load) const {
        uint64_t page = 0;
        if (!adrpPage(w, pc, page)) return false;
        const uint32_t rd = w & 31;
        for (int k = 1; k <= 4; ++k) {
            uint32_t n = 0;
            if (!wordAt(pc + 4 * k, n)) return false;
            const uint32_t rn = (n >> 5) & 31;
            if (rn != rd) continue;
            if ((n & 0xFFC00000u) == 0xF9400000u) {  // LDR Xt, [Xn, #imm*8]
                address = page + ((n >> 10) & 0xFFFu) * 8;
                load = true;
                return true;
            }
            if ((n & 0xFFC00000u) == 0x91000000u) {  // ADD Xd, Xn, #imm
                address = page + ((n >> 10) & 0xFFFu);
                load = false;
                return true;
            }
        }
        return false;
    }

    // Whether an instruction may write x0 or w0, and the constant when it is MOVZ/MOVN.
    static bool writesX0(uint32_t w, bool& constant, uint64_t& value) {
        constant = false;
        if ((w & 0x7F800000u) == 0x52800000u || (w & 0x7F800000u) == 0x12800000u) {  // MOVZ, MOVN
            if ((w & 31) != 0) return false;
            const bool wide = (w & 0x80000000u) != 0;
            const uint32_t hw = (w >> 21) & 3;
            uint64_t v = uint64_t((w >> 5) & 0xFFFFu) << (16 * hw);
            if ((w & 0x7F800000u) == 0x12800000u) v = ~v;
            if (!wide) v &= 0xFFFFFFFFu;
            constant = true;
            value = v;
            return true;
        }
        if ((w & 0x0A000000u) == 0x08000000u) {  // loads and stores
            if ((w & 0x3B400000u) == 0x39000000u) return false;  // STR (unsigned offset, no writeback)
            if ((w & 0x3BC00000u) == 0x29000000u) return false;  // STP (signed offset, no writeback)
            return (w & 31) == 0 || ((w >> 5) & 31) == 0 || ((w >> 10) & 31) == 0 || ((w >> 16) & 31) == 0;
        }
        return (w & 31) == 0;  // data processing: Rd (also v0 for SIMD and FP, counted to fail closed)
    }

    bool aarch64() {
        // Labels (every direct branch target) and the PLT stubs that load syscall's GOT slot.
        std::unordered_set<uint64_t> stubs;
        if (!words([&](const Code&, uint64_t, uint64_t pc, uint32_t w) {
                uint64_t target = 0;
                bool call = false, conditional = false;
                if (directBranch(w, pc, target, call, conditional)) labels_.insert(target);
                uint64_t address = 0;
                bool load = false;
                if ((w & 31) == 16 && adrpTarget(pc, w, address, load) && load && got_.count(address)) stubs.insert(pc);
                return true;
            }))
            return false;
        // Every other way to reach syscall: its GOT slot read elsewhere, the stub's address formed, ADR or LDR
        // (literal) to either, a conditional branch to a stub. Then each call or tail branch to a stub.
        return words([&](const Code&, uint64_t, uint64_t pc, uint32_t w) {
            uint64_t address = 0;
            bool load = false;
            if (adrpTarget(pc, w, address, load) && ((got_.count(address) && !stubs.count(pc)) || stubs.count(address)))
                return failed("syscall reached without its PLT stub at " + hexOf(pc));
            if ((w & 0x9F000000u) == 0x10000000u) {  // ADR
                const uint64_t imm = (uint64_t((w >> 5) & 0x7FFFFu) << 2) | ((w >> 29) & 3u);
                const uint64_t a = pc + uint64_t(signExtend(imm, 21));
                if (got_.count(a) || stubs.count(a)) return failed("syscall's address formed at " + hexOf(pc));
            }
            if ((w & 0xBF000000u) == 0x18000000u) {  // LDR (literal)
                const uint64_t a = pc + uint64_t(signExtend((w >> 5) & 0x7FFFFu, 19) * 4);
                if (got_.count(a)) return failed("syscall's GOT slot read at " + hexOf(pc));
            }
            uint64_t target = 0;
            bool call = false, conditional = false;
            if (!directBranch(w, pc, target, call, conditional) || !stubs.count(target)) return true;
            if (conditional) return failed("a conditional branch to syscall at " + hexOf(pc));
            return aarch64Site(pc);
        });
    }

    bool aarch64Site(uint64_t pc) {
        if (labels_.count(pc)) return failed("a call to syscall at a branch target, " + hexOf(pc));
        for (int k = 1; k <= kWindow; ++k) {
            const uint64_t a = pc - 4 * uint64_t(k);
            uint32_t w = 0;
            if (!wordAt(a, w)) break;
            const bool hint = (w & 0xFFFFF01Fu) == 0xD503201Fu;  // NOP, BTI and other hints
            if (!hint && (w & 0x1C000000u) == 0x14000000u) break;  // a branch or system instruction
            bool constant = false;
            uint64_t value = 0;
            if (!hint && writesX0(w, constant, value)) {
                if (!constant) break;
                return number(value, pc);
            }
            if (labels_.count(a)) break;
        }
        return failed("a call to syscall whose number can't be read at " + hexOf(pc));
    }

    // ---- x86-64: byte patterns of the exact forms compilers emit.
    bool byteAt(uint64_t vaddr, uint8_t& b) const {
        for (const Code& c : code_)
            if (vaddr >= c.vaddr && vaddr - c.vaddr < c.size) return r_.u8(c.file + (vaddr - c.vaddr), b);
        return false;
    }
    bool bytesAre(uint64_t vaddr, std::initializer_list<uint8_t> expected) const {
        uint64_t i = 0;
        for (uint8_t e : expected) {
            uint8_t b = 0;
            if (!byteAt(vaddr + i++, b) || b != e) return false;
        }
        return true;
    }
    bool u32At(uint64_t vaddr, uint32_t& v) const {
        for (const Code& c : code_)
            if (vaddr >= c.vaddr && vaddr - c.vaddr + 4 <= c.size) return r_.u32(c.file + (vaddr - c.vaddr), v);
        return false;
    }

    bool x86() {
        // Stubs: jmp *[rip+disp] (FF 25) at the GOT slot, entered at the jmp, a bnd prefix or an endbr64.
        std::unordered_set<uint64_t> stubs, stubDisp;
        for (const Code& c : code_) {
            if (!budget_.spend(c.size)) return failed("the scan's work budget ran out");
            const uint8_t* b = r_.data() + c.file;
            for (uint64_t i = 0; i + 6 <= c.size; ++i) {
                if (b[i] != 0xFF || b[i + 1] != 0x25) continue;
                uint32_t disp = 0;
                r_.u32(c.file + i + 2, disp);
                const uint64_t v = c.vaddr + i;
                if (!got_.count(v + 6 + uint64_t(int64_t(int32_t(disp))))) continue;
                stubDisp.insert(v + 2);
                uint64_t entry = v;
                if (i >= 1 && b[i - 1] == 0xF2) entry = v - 1;  // bnd jmp
                stubs.insert(v);
                stubs.insert(entry);
                if (entry >= 4 && bytesAre(entry - 4, {0xF3, 0x0F, 0x1E, 0xFA})) stubs.insert(entry - 4);  // endbr64
            }
        }
        // Branch targets of every rel32 branch, for the "jumped into" check.
        for (const Code& c : code_) {
            const uint8_t* b = r_.data() + c.file;
            for (uint64_t i = 0; i + 5 <= c.size; ++i) {
                uint32_t rel = 0;
                if (b[i] == 0xE8 || b[i] == 0xE9) {
                    r_.u32(c.file + i + 1, rel);
                    labels_.insert(c.vaddr + i + 5 + uint64_t(int64_t(int32_t(rel))));
                } else if (b[i] == 0x0F && i + 6 <= c.size && b[i + 1] >= 0x80 && b[i + 1] <= 0x8F) {
                    r_.u32(c.file + i + 2, rel);
                    labels_.insert(c.vaddr + i + 6 + uint64_t(int64_t(int32_t(rel))));
                }
            }
        }
        for (const Code& c : code_) {
            const uint8_t* b = r_.data() + c.file;
            for (uint64_t i = 0; i + 4 <= c.size; ++i) {
                const uint64_t v = c.vaddr + i;
                uint32_t disp = 0;
                r_.u32(c.file + i, disp);
                const uint64_t ripTarget = v + 4 + uint64_t(int64_t(int32_t(disp)));
                // A rip-relative operand ending here that names syscall's GOT slot or a stub.
                if (got_.count(ripTarget) && !stubDisp.count(v)) {
                    if (i >= 2 && b[i - 2] == 0xFF && b[i - 1] == 0x15) {  // call *[rip+slot]
                        if (!x86Site(v - 2)) return false;
                        continue;
                    }
                    return failed("syscall's GOT slot used at " + hexOf(v));
                }
                if (stubs.count(ripTarget) && i >= 1) {
                    if (b[i - 1] == 0xE8 || b[i - 1] == 0xE9) {  // call / tail jmp rel32
                        if (!x86Site(v - 1)) return false;
                        continue;
                    }
                    return failed("syscall's PLT stub reached at " + hexOf(v));
                }
                // Short or conditional branches to a stub.
                if (i + 2 <= c.size && (b[i] == 0xEB || (b[i] >= 0x70 && b[i] <= 0x7F)) &&
                    stubs.count(v + 2 + uint64_t(int64_t(int8_t(b[i + 1])))))
                    return failed("a short branch to syscall at " + hexOf(v));
            }
        }
        return true;
    }

    // The forms seen: mov edi, imm32 (BF) or mov rdi, imm32 (48 C7 C7), optionally followed by xor eax, eax
    // (31 C0), right before the call. Nothing may jump in between.
    bool x86Site(uint64_t at) {
        uint64_t start = 0;
        uint32_t value = 0;
        const bool xorBefore = at >= 2 && bytesAre(at - 2, {0x31, 0xC0});
        const uint64_t end = xorBefore ? at - 2 : at;
        if (end >= 5 && bytesAre(end - 5, {0xBF}) && u32At(end - 4, value)) start = end - 5;
        else if (end >= 7 && bytesAre(end - 7, {0x48, 0xC7, 0xC7}) && u32At(end - 4, value)) start = end - 7;
        else return failed("a call to syscall whose number can't be read at " + hexOf(at));
        for (uint64_t a = start + 1; a <= at; ++a)
            if (labels_.count(a)) return failed("a call to syscall that can be jumped into at " + hexOf(at));
        // Short branches (rel8) from up to 130 bytes around that land inside.
        for (uint64_t from = start >= 130 ? start - 130 : 0; from < at + 130; ++from) {
            uint8_t op = 0, rel = 0;
            if (!byteAt(from, op) || !(op == 0xEB || (op >= 0x70 && op <= 0x7F)) || !byteAt(from + 1, rel)) continue;
            const uint64_t t = from + 2 + uint64_t(int64_t(int8_t(rel)));
            if (t > start && t <= at && (from < start || from >= at))
                return failed("a call to syscall that can be jumped into at " + hexOf(at));
        }
        const uint64_t n = (value & 0x80000000u) && bytesAre(start, {0x48}) ? uint64_t(int64_t(int32_t(value))) : value;
        return number(n, at);
    }

    const ByteReader& r_;
    const Parsed& p_;
    WorkBudget& budget_;
    std::vector<Code> code_;
    std::unordered_set<uint64_t> got_, labels_;
    SyscallUse out_;
    uint64_t sites_ = 0;
};

}  // namespace

bool runtimeSyscall(uint16_t machine, uint64_t number) noexcept {
    // AArch64: futex 98 (libstdc++'s guards and atomic waits), gettid 178 (libc++abi's guards), rt_sigprocmask
    // 135 (the NDK's libunwind, probing memory). x86-64: futex 202, gettid 186.
    if (machine == kAArch64) return number == 98 || number == 178 || number == 135;
    if (machine == kX86_64) return number == 202 || number == 186;
    return false;
}

SyscallUse analyzeSyscallCalls(const ByteReader& r, const Parsed& p, WorkBudget& budget) {
    return Analysis(r, p, budget).run();
}

}  // namespace caw::scan
