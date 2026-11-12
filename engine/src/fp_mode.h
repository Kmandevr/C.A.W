// Flush-to-zero for the audio thread: an RAII guard that makes subnormal floats read and compute as 0, then restores.
#pragma once

#include <cstdint>

#if defined(__SSE__) || defined(_M_X64) || (defined(_M_IX86_FP) && _M_IX86_FP >= 1)
#include <xmmintrin.h>
#define CAW_FP_MODE_SSE 1
#elif defined(__aarch64__) && (defined(__GNUC__) || defined(__clang__))
#define CAW_FP_MODE_A64 1
#endif

namespace caw {

// Subnormal numbers (below about 1.2e-38 in float, 2.2e-308 in double) appear as filters, reverbs and envelopes decay
// to silence, and many CPUs compute them tens of times slower. While a guard lives, the thread's floating-point unit
// flushes them to 0 (results and inputs: x86 MXCSR FTZ and DAZ, Arm64 FPCR.FZ); its destructor clears what it set
// (and only that), so a host's thread is left as it was. Every Engine::process call and every offline component
// render holds one. A change only below 1e-38 of full scale: far under the reference renders' −120 dBFS.
// Other targets (32-bit Arm, MSVC on Arm64) keep their mode: the code's own denormal guards still settle at 0.
// Reading and writing the control register costs a few cycles per callback, not per sample; the write is skipped
// when the mode is already set (a nested guard, or a host that already flushes).
class ScopedFlushDenormals {
public:
#if defined(CAW_FP_MODE_SSE)
    ScopedFlushDenormals() noexcept {
#if defined(__x86_64__) || defined(_M_X64)
        constexpr unsigned kWant = 0x8040u;  // FTZ (bit 15) | DAZ (bit 6); [assumption] every x86-64 CPU has DAZ
#else
        constexpr unsigned kWant = 0x8000u;  // FTZ only: the first SSE CPUs fault on DAZ
#endif
        const unsigned now = _mm_getcsr();
        added_ = kWant & ~now;
        if (added_) _mm_setcsr(now | added_);
    }
    // Clears only the bits this guard set: the sticky exception flags raised meanwhile stay as they are.
    ~ScopedFlushDenormals() { if (added_) _mm_setcsr(_mm_getcsr() & ~added_); }
#elif defined(CAW_FP_MODE_A64)
    ScopedFlushDenormals() noexcept {
        constexpr uint64_t kFz = uint64_t{1} << 24;  // FPCR.FZ: flush float and double subnormals (inputs and results)
        const uint64_t now = read();
        added_ = kFz & ~now;
        if (added_) write(now | added_);
    }
    ~ScopedFlushDenormals() { if (added_) write(read() & ~added_); }
#else
    ScopedFlushDenormals() noexcept = default;
#endif
    // Whether this thread flushes subnormal results to 0 now (false where the target has no guard).
    static bool flushing() noexcept {
#if defined(CAW_FP_MODE_SSE)
        return (_mm_getcsr() & 0x8000u) != 0;
#elif defined(CAW_FP_MODE_A64)
        return (read() & (uint64_t{1} << 24)) != 0;
#else
        return false;
#endif
    }
    ScopedFlushDenormals(const ScopedFlushDenormals&) = delete;
    ScopedFlushDenormals& operator=(const ScopedFlushDenormals&) = delete;

private:
#if defined(CAW_FP_MODE_SSE)
    unsigned added_ = 0;
#elif defined(CAW_FP_MODE_A64)
    static uint64_t read() noexcept { uint64_t v; __asm__ __volatile__("mrs %0, fpcr" : "=r"(v)); return v; }
    static void write(uint64_t v) noexcept { __asm__ __volatile__("msr fpcr, %0" : : "r"(v) : "memory"); }
    uint64_t added_ = 0;
#endif
};

}  // namespace caw
