// Warms a just-loaded native library on the control thread: one byte read per page of its code and read-only data.
#pragma once

#include <cstddef>
#include <cstdint>

namespace caw {

struct LibraryWarmStats {
    bool found = false;           // the library's segments (sections on Windows) were found
    bool executableOnly = false;  // over the cap: only the executable ones were touched
    uint32_t regions = 0;         // segments or sections touched
    uint64_t pages = 0;           // pages read
    uint64_t bytes = 0;           // their size
};

constexpr std::size_t kLibraryWarmCap = 8u << 20;  // about 8 MiB

// After dlopen / android_dlopen_ext / LoadLibraryExW, before the audio thread can run the library: reads one byte
// per page of the executable and read-only segments (.text, .rodata, and the relocated read-only .data.rel.ro and
// GOT, PT_GNU_RELRO) of the library containing `address` (any symbol of it), so its first callback does not fault
// them in. No mlock (the pages may still be evicted later) and no MADV_WILLNEED alone (a hint, not a fault). Over
// `cap` bytes in all, only the executable ones, themselves up to `cap`. Never fails a load: a library it cannot find
// is left as it is. Platform code (engine/platform/library_warm_*.cpp).
LibraryWarmStats warmLibrary(const void* address, std::size_t cap = kLibraryWarmCap) noexcept;

// What the module registry's last native load warmed (module_registry.cpp; tests read it).
LibraryWarmStats lastLibraryWarmForTest() noexcept;

}  // namespace caw
