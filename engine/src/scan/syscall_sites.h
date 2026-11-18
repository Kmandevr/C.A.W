// The pre-load scan's look at every call of an imported syscall(): which system call each one makes, so a C++
// runtime's own futex and thread-id calls pass and anything else (or anything it can't read) counts.
#pragma once

#include <cstdint>
#include <string>
#include <vector>

#include "parsed.h"

namespace caw::scan {

struct SyscallUse {
    bool runtimeOnly = false;      // every call passes a number the C++ runtimes use (futex, gettid, ...)
    std::string detail;            // why not, or which numbers
    std::vector<uint64_t> numbers; // the system call numbers seen, in order
};

// ELF on AArch64 or x86-64 with an imported syscall. Fails closed: a call it can't read, a number it doesn't
// allow, syscall's address taken, or its GOT entry read anywhere but its PLT stub makes runtimeOnly false.
SyscallUse analyzeSyscallCalls(const ByteReader& r, const Parsed& p, WorkBudget& budget);

// The numbers allowed (measured 2026-11-18 on the NDK r30 libc++abi/libunwind and GCC 13's libstdc++).
bool runtimeSyscall(uint16_t machine, uint64_t number) noexcept;

}  // namespace caw::scan
