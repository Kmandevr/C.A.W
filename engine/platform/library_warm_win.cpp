// Library warming on Windows: the loaded module's PE sections, from its headers in memory.
#include "library_warm.h"

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <algorithm>
#include <cstdint>

namespace caw {

LibraryWarmStats warmLibrary(const void* address, std::size_t cap) noexcept {
    LibraryWarmStats stats;
    HMODULE module = nullptr;
    if (!address || !GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                        static_cast<LPCWSTR>(address), &module) || !module)
        return stats;
    const auto* base = reinterpret_cast<const unsigned char*>(module);
    const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos->e_magic != IMAGE_DOS_SIGNATURE) return stats;
    const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE) return stats;
    stats.found = true;
    const IMAGE_SECTION_HEADER* sections = IMAGE_FIRST_SECTION(nt);
    const unsigned count = nt->FileHeader.NumberOfSections;
    auto wanted = [](const IMAGE_SECTION_HEADER& h, bool execOnly) {
        const DWORD c = h.Characteristics;
        if (!(c & IMAGE_SCN_MEM_READ)) return false;
        if (c & IMAGE_SCN_MEM_EXECUTE) return true;
        return !execOnly && !(c & IMAGE_SCN_MEM_WRITE);
    };
    uint64_t total = 0;
    for (unsigned i = 0; i < count; ++i)
        if (wanted(sections[i], false)) total += sections[i].Misc.VirtualSize;
    stats.executableOnly = total > cap;
    SYSTEM_INFO info;
    GetSystemInfo(&info);
    const uintptr_t page = info.dwPageSize ? info.dwPageSize : 4096;
    volatile unsigned char sink = 0;
    for (unsigned i = 0; i < count; ++i) {
        const IMAGE_SECTION_HEADER& h = sections[i];
        if (!wanted(h, stats.executableOnly)) continue;
        ++stats.regions;
        const uintptr_t start = reinterpret_cast<uintptr_t>(base) + h.VirtualAddress, end = start + h.Misc.VirtualSize;
        for (uintptr_t a = start & ~(page - 1); a < end && stats.bytes < cap; a += page) {
            sink = sink + *reinterpret_cast<const volatile unsigned char*>(std::max(a, start));
            ++stats.pages;
            stats.bytes += page;
        }
    }
    (void)sink;
    return stats;
}

}  // namespace caw
