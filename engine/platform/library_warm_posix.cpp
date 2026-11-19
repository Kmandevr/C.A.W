// Library warming on Linux and Android (glibc and bionic): the loaded object's segments from dl_iterate_phdr.
#include "library_warm.h"

#include <link.h>
#include <unistd.h>

#include <algorithm>
#include <cstdint>

namespace caw {
namespace {

struct Region {
    uintptr_t start = 0, end = 0;
    bool exec = false;
};

struct Search {
    uintptr_t address = 0;
    bool found = false;
    Region regions[32];
    uint32_t count = 0;
};

void add(Search& s, uintptr_t start, uintptr_t end, bool exec) {
    if (end <= start || s.count == 32) return;
    s.regions[s.count++] = {start, end, exec};
}

int visit(dl_phdr_info* info, size_t, void* data) {
    Search& s = *static_cast<Search*>(data);
    bool mine = false;
    for (int i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr)& p = info->dlpi_phdr[i];
        if (p.p_type != PT_LOAD) continue;
        const uintptr_t start = info->dlpi_addr + p.p_vaddr;
        if (s.address >= start && s.address < start + p.p_memsz) mine = true;
    }
    if (!mine) return 0;
    s.found = true;
    for (int i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr)& p = info->dlpi_phdr[i];
        const uintptr_t start = info->dlpi_addr + p.p_vaddr, end = start + p.p_memsz;
        if (p.p_type == PT_LOAD && (p.p_flags & PF_R) && (p.p_flags & PF_X)) add(s, start, end, true);
        else if (p.p_type == PT_LOAD && (p.p_flags & PF_R) && !(p.p_flags & PF_W)) add(s, start, end, false);
        else if (p.p_type == PT_GNU_RELRO) add(s, start, end, false);  // read-only after relocation (GOT, .data.rel.ro)
        // An execute-only segment (no PF_R) is never read: that would fault.
    }
    return 1;
}

}  // namespace

LibraryWarmStats warmLibrary(const void* address, std::size_t cap) noexcept {
    LibraryWarmStats stats;
    if (!address) return stats;
    Search s;
    s.address = reinterpret_cast<uintptr_t>(address);
    dl_iterate_phdr(visit, &s);
    if (!s.found) return stats;
    stats.found = true;
    const long pageSize = sysconf(_SC_PAGESIZE);
    const uintptr_t page = pageSize > 0 ? static_cast<uintptr_t>(pageSize) : 4096;
    uint64_t total = 0;
    for (uint32_t i = 0; i < s.count; ++i) total += s.regions[i].end - s.regions[i].start;
    stats.executableOnly = total > cap;
    volatile unsigned char sink = 0;
    for (uint32_t i = 0; i < s.count; ++i) {
        const Region& r = s.regions[i];
        if (stats.executableOnly && !r.exec) continue;
        ++stats.regions;
        for (uintptr_t a = r.start & ~(page - 1); a < r.end && stats.bytes < cap; a += page) {
            const uintptr_t at = std::max(a, r.start);  // the first page may begin before the segment
            sink = sink + *reinterpret_cast<const volatile unsigned char*>(at);
            ++stats.pages;
            stats.bytes += page;
        }
    }
    (void)sink;
    return stats;
}

}  // namespace caw
