// Hand-built minimal ELF64 and PE32+ files for the pre-load scan's tests: chosen imports, exports, code,
// sections and declarations, laid out with every virtual address equal to its file offset.
#pragma once

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <string>
#include <utility>
#include <vector>

namespace caw::scantest {

using Bytes = std::vector<uint8_t>;

inline void put16(Bytes& b, size_t at, uint16_t v) {
    if (b.size() < at + 2) b.resize(at + 2);
    b[at] = uint8_t(v);
    b[at + 1] = uint8_t(v >> 8);
}
inline void put32(Bytes& b, size_t at, uint32_t v) {
    if (b.size() < at + 4) b.resize(at + 4);
    for (int i = 0; i < 4; ++i) b[at + i] = uint8_t(v >> (8 * i));
}
inline void put64(Bytes& b, size_t at, uint64_t v) {
    if (b.size() < at + 8) b.resize(at + 8);
    for (int i = 0; i < 8; ++i) b[at + i] = uint8_t(v >> (8 * i));
}
inline size_t align(size_t v, size_t a) { return (v + a - 1) / a * a; }
inline void putBytes(Bytes& b, size_t at, const void* data, size_t n) {
    if (b.size() < at + n) b.resize(at + n);
    if (n) std::memcpy(b.data() + at, data, n);
}

struct ElfSpec {
    uint16_t machine = 62;  // 62 x86-64, 183 AArch64
    std::vector<std::string> imports;
    std::vector<std::string> exports{"caw_get_component_v3"};
    Bytes code = Bytes(64, 0x90);
    bool writableCode = false;
    bool sectionHeaders = true;
    std::vector<std::pair<std::string, Bytes>> extraSections;  // named allocated data sections
    uint64_t initArrayBytes = 16;
    std::string data;  // raw bytes in the read-only part (strings)
    std::vector<std::string> needed{"libc.so"};  // DT_NEEDED
    std::string runpath;                          // DT_RUNPATH, when not empty
    // Imports after the symbols DT_HASH counts, reached only through Android packed relocations
    // (DT_ANDROID_RELA, "APS2"), which the fixture writes when this is not empty.
    std::vector<std::string> hiddenImports;
};

inline void putSleb(Bytes& b, int64_t v) {
    for (;;) {
        const uint8_t byte = uint8_t(v & 0x7f);
        v >>= 7;
        if ((v == 0 && !(byte & 0x40)) || (v == -1 && (byte & 0x40))) {
            b.push_back(byte);
            return;
        }
        b.push_back(byte | 0x80);
    }
}

// Offsets the robustness tests poke at.
struct ElfLayout {
    size_t dynamic = 0, hash = 0, dynsym = 0, shoff = 0;
};

inline Bytes buildElf(const ElfSpec& s, ElfLayout* layout = nullptr) {
    Bytes b(64, 0);
    // dynstr
    std::string dynstr(1, '\0');
    std::vector<uint32_t> names;
    std::vector<std::string> symbols = s.imports;
    symbols.insert(symbols.end(), s.exports.begin(), s.exports.end());
    const size_t countedSymbols = symbols.size() + 1;
    symbols.insert(symbols.end(), s.hiddenImports.begin(), s.hiddenImports.end());
    for (const std::string& n : symbols) {
        names.push_back(uint32_t(dynstr.size()));
        dynstr += n;
        dynstr.push_back('\0');
    }
    std::vector<uint32_t> neededNames;
    for (const std::string& n : s.needed) {
        neededNames.push_back(uint32_t(dynstr.size()));
        dynstr += n;
        dynstr.push_back('\0');
    }
    const uint32_t runpathName = uint32_t(dynstr.size());
    dynstr += s.runpath;
    dynstr.push_back('\0');
    // Packed relocations: one group, each with its own offset delta and info (symbol << 32 | type 1).
    Bytes packed;
    if (!s.hiddenImports.empty()) {
        packed = {'A', 'P', 'S', '2'};
        putSleb(packed, int64_t(s.hiddenImports.size()));
        putSleb(packed, 0x1000);
        putSleb(packed, int64_t(s.hiddenImports.size()));
        putSleb(packed, 0);  // flags: nothing grouped, no addend
        for (size_t i = 0; i < s.hiddenImports.size(); ++i) {
            putSleb(packed, 8);
            putSleb(packed, int64_t((uint64_t(countedSymbols + i) << 32) | 1));
        }
    }
    const size_t phoff = 64, phnum = 3;
    const size_t dynstrOff = align(phoff + phnum * 56, 8);
    const size_t dynsymOff = align(dynstrOff + dynstr.size(), 8);
    const size_t symCount = symbols.size() + 1;
    const size_t hashOff = dynsymOff + symCount * 24;
    const size_t hashSize = 8 + 4 + 4 * symCount;
    const size_t dynOff = align(hashOff + hashSize, 8);
    std::vector<std::pair<int64_t, int64_t>> dyn;
    for (uint32_t n : neededNames) dyn.push_back({1, n});
    const size_t dynCount = dyn.size() + 6 + (s.runpath.empty() ? 0 : 1) + (packed.empty() ? 0 : 2);
    const size_t dataOff = dynOff + dynCount * 16;
    const size_t packedOff = align(dataOff + s.data.size(), 8);
    size_t at = packedOff + packed.size();
    std::vector<size_t> extraOff;
    for (const auto& [name, bytes] : s.extraSections) {
        at = align(at, 8);
        extraOff.push_back(at);
        at += bytes.size();
    }
    const size_t codeOff = align(at, 16);
    const size_t codeEnd = codeOff + s.code.size();
    b.resize(codeEnd, 0);
    // ELF header
    const uint8_t ident[16] = {0x7f, 'E', 'L', 'F', 2, 1, 1};
    putBytes(b, 0, ident, 16);
    put16(b, 16, 3);  // ET_DYN
    put16(b, 18, s.machine);
    put32(b, 20, 1);
    put64(b, 32, phoff);
    put16(b, 52, 64);
    put16(b, 54, 56);
    put16(b, 56, uint16_t(phnum));
    // program headers: R [0, codeOff), R+X (W) code, DYNAMIC
    auto ph = [&](size_t i, uint32_t type, uint32_t flags, uint64_t off, uint64_t size) {
        const size_t p = phoff + i * 56;
        put32(b, p, type);
        put32(b, p + 4, flags);
        put64(b, p + 8, off);
        put64(b, p + 16, off);
        put64(b, p + 24, off);
        put64(b, p + 32, size);
        put64(b, p + 40, size);
        put64(b, p + 48, 8);
    };
    ph(0, 1, 4, 0, codeOff);
    ph(1, 1, 5 | (s.writableCode ? 2 : 0), codeOff, s.code.size());
    ph(2, 2, 6, dynOff, dynCount * 16);
    putBytes(b, dynstrOff, dynstr.data(), dynstr.size());
    for (size_t i = 0; i < symbols.size(); ++i) {
        const size_t p = dynsymOff + (i + 1) * 24;
        const bool imported = i < s.imports.size() || i >= s.imports.size() + s.exports.size();
        put32(b, p, names[i]);
        b[p + 4] = 0x12;  // GLOBAL FUNC
        put16(b, p + 6, imported ? 0 : 1);
        put64(b, p + 8, imported ? 0 : codeOff);
    }
    put32(b, hashOff, 1);
    put32(b, hashOff + 4, uint32_t(countedSymbols));
    dyn.push_back({5, int64_t(dynstrOff)});
    dyn.push_back({10, int64_t(dynstr.size())});
    if (!s.runpath.empty()) dyn.push_back({29, runpathName});
    dyn.push_back({6, int64_t(dynsymOff)});
    dyn.push_back({4, int64_t(hashOff)});
    dyn.push_back({27, int64_t(s.initArrayBytes)});
    if (!packed.empty()) {
        dyn.push_back({0x60000011, int64_t(packedOff)});
        dyn.push_back({0x60000012, int64_t(packed.size())});
    }
    dyn.push_back({0, 0});
    for (size_t i = 0; i < dynCount; ++i) {
        put64(b, dynOff + i * 16, uint64_t(dyn[i].first));
        put64(b, dynOff + i * 16 + 8, uint64_t(dyn[i].second));
    }
    putBytes(b, packedOff, packed.data(), packed.size());
    putBytes(b, dataOff, s.data.data(), s.data.size());
    for (size_t i = 0; i < s.extraSections.size(); ++i)
        putBytes(b, extraOff[i], s.extraSections[i].second.data(), s.extraSections[i].second.size());
    putBytes(b, codeOff, s.code.data(), s.code.size());
    if (layout) *layout = {dynOff, hashOff, dynsymOff, 0};
    if (!s.sectionHeaders) return b;
    // section headers: null, .dynstr, .dynsym, .text, extras, .shstrtab
    std::string shstr(1, '\0');
    auto nameOf = [&](const std::string& n) {
        const uint32_t o = uint32_t(shstr.size());
        shstr += n;
        shstr.push_back('\0');
        return o;
    };
    struct Sh { uint32_t name, type; uint64_t flags, off, size; };
    std::vector<Sh> sh{{0, 0, 0, 0, 0}};
    sh.push_back({nameOf(".dynstr"), 3, 2, dynstrOff, dynstr.size()});
    sh.push_back({nameOf(".dynsym"), 11, 2, dynsymOff, symCount * 24});
    sh.push_back({nameOf(".text"), 1, 6 | (s.writableCode ? 1u : 0u), codeOff, s.code.size()});
    for (size_t i = 0; i < s.extraSections.size(); ++i)
        sh.push_back({nameOf(s.extraSections[i].first), 1, 2, extraOff[i], s.extraSections[i].second.size()});
    const uint32_t shstrName = nameOf(".shstrtab");
    const size_t shstrOff = b.size();
    putBytes(b, shstrOff, shstr.data(), shstr.size());
    sh.push_back({shstrName, 3, 0, shstrOff, shstr.size()});
    const size_t shoff = align(b.size(), 8);
    b.resize(shoff + sh.size() * 64, 0);
    for (size_t i = 0; i < sh.size(); ++i) {
        const size_t p = shoff + i * 64;
        put32(b, p, sh[i].name);
        put32(b, p + 4, sh[i].type);
        put64(b, p + 8, sh[i].flags);
        put64(b, p + 16, sh[i].off);
        put64(b, p + 24, sh[i].off);
        put64(b, p + 32, sh[i].size);
        put64(b, p + 56, sh[i].type == 11 ? 24 : 0);
    }
    put64(b, 40, shoff);
    put16(b, 58, 64);
    put16(b, 60, uint16_t(sh.size()));
    put16(b, 62, uint16_t(sh.size() - 1));
    if (layout) layout->shoff = shoff;
    return b;
}

struct PeImport {
    std::string dll;
    std::vector<std::string> names;  // "#7" imports by ordinal 7
};

struct PeSpec {
    std::vector<PeImport> imports;
    Bytes code = Bytes(64, 0xCC);
    bool writableCode = false;
    uint32_t tlsCallbacks = 0;
    std::vector<std::pair<std::string, Bytes>> extraSections;
};

struct PeLayout {
    size_t sectionTable = 0, optional = 0, idata = 0;
};

inline Bytes buildPe(const PeSpec& s, PeLayout* layout = nullptr) {
    constexpr uint64_t kImageBase = 0x180000000ull;
    constexpr size_t kFileAlign = 0x200;
    Bytes b(0x400, 0);
    b[0] = 'M';
    b[1] = 'Z';
    put32(b, 0x3c, 0x40);
    putBytes(b, 0x40, "PE\0\0", 4);
    const size_t coff = 0x44, opt = coff + 20;
    struct Sec { std::string name; Bytes data; uint32_t flags; size_t va = 0; };
    std::vector<Sec> secs;
    secs.push_back({".text", s.code, s.writableCode ? 0xE0000020u : 0x60000020u});
    // .idata: descriptors, then per DLL its name table, hint/names and name
    Bytes idata;
    size_t idataIndex = 0, tlsIndex = 0;
    if (!s.imports.empty()) {
        idataIndex = secs.size();
        secs.push_back({".idata", {}, 0x40000040u});
    }
    for (const auto& [name, bytes] : s.extraSections) secs.push_back({name, bytes, 0x40000040u});
    if (s.tlsCallbacks) {
        tlsIndex = secs.size();
        secs.push_back({".tls", {}, 0x40000040u});
    }
    // Assign addresses: sizes of .idata/.tls are known before their content needs addresses.
    size_t idataSize = (s.imports.size() + 1) * 20;
    for (const PeImport& im : s.imports) {
        idataSize += (im.names.size() + 1) * 8 + im.dll.size() + 1;
        for (const std::string& n : im.names) idataSize += n.size() + 3;
    }
    if (!s.imports.empty()) secs[idataIndex].data.resize(idataSize + 8, 0);
    if (s.tlsCallbacks) secs[tlsIndex].data.resize(40 + (s.tlsCallbacks + 1) * 8, 0);
    size_t at = 0x400;
    for (Sec& sec : secs) {
        sec.va = at;
        at += align(sec.data.size() ? sec.data.size() : 1, kFileAlign);
    }
    if (!s.imports.empty()) {
        Bytes& d = secs[idataIndex].data;
        const size_t base = secs[idataIndex].va;
        size_t cursor = (s.imports.size() + 1) * 20;
        for (size_t i = 0; i < s.imports.size(); ++i) {
            const PeImport& im = s.imports[i];
            const size_t table = cursor;
            cursor += (im.names.size() + 1) * 8;
            for (size_t k = 0; k < im.names.size(); ++k) {
                const std::string& n = im.names[k];
                if (n[0] == '#') {
                    put64(d, table + k * 8, (1ull << 63) | std::stoul(n.substr(1)));
                    continue;
                }
                put64(d, table + k * 8, base + cursor);
                cursor += 2;
                putBytes(d, cursor, n.data(), n.size());
                cursor += n.size() + 1;
            }
            const size_t dllName = cursor;
            putBytes(d, cursor, im.dll.data(), im.dll.size());
            cursor += im.dll.size() + 1;
            put32(d, i * 20, uint32_t(base + table));
            put32(d, i * 20 + 12, uint32_t(base + dllName));
            put32(d, i * 20 + 16, uint32_t(base + table));
        }
        d.resize(std::max(d.size(), cursor), 0);
    }
    if (s.tlsCallbacks) {
        Bytes& d = secs[tlsIndex].data;
        const size_t base = secs[tlsIndex].va;
        put64(d, 24, kImageBase + base + 40);
        for (uint32_t k = 0; k < s.tlsCallbacks; ++k) put64(d, 40 + k * 8, kImageBase + secs[0].va + k);
    }
    // headers
    put16(b, coff, 0x8664);
    put16(b, coff + 2, uint16_t(secs.size()));
    put16(b, coff + 16, 240);
    put16(b, coff + 18, 0x2022);
    put16(b, opt, 0x20B);
    put64(b, opt + 24, kImageBase);
    put32(b, opt + 32, kFileAlign);
    put32(b, opt + 36, kFileAlign);
    put32(b, opt + 56, uint32_t(at));
    put32(b, opt + 60, 0x400);
    put32(b, opt + 108, 16);
    if (!s.imports.empty()) {
        put32(b, opt + 112 + 1 * 8, uint32_t(secs[idataIndex].va));
        put32(b, opt + 112 + 1 * 8 + 4, uint32_t(idataSize));
    }
    if (s.tlsCallbacks) {
        put32(b, opt + 112 + 9 * 8, uint32_t(secs[tlsIndex].va));
        put32(b, opt + 112 + 9 * 8 + 4, 40);
    }
    const size_t table = opt + 240;
    for (size_t i = 0; i < secs.size(); ++i) {
        const size_t p = table + i * 40;
        putBytes(b, p, secs[i].name.data(), std::min<size_t>(8, secs[i].name.size()));
        const size_t raw = align(secs[i].data.size() ? secs[i].data.size() : 1, kFileAlign);
        put32(b, p + 8, uint32_t(secs[i].data.size()));
        put32(b, p + 12, uint32_t(secs[i].va));
        put32(b, p + 16, uint32_t(raw));
        put32(b, p + 20, uint32_t(secs[i].va));
        put32(b, p + 36, secs[i].flags);
        b.resize(secs[i].va + raw, 0);
        putBytes(b, secs[i].va, secs[i].data.data(), secs[i].data.size());
    }
    if (layout) *layout = {table, opt, s.imports.empty() ? 0 : secs[idataIndex].va};
    return b;
}

}  // namespace caw::scantest
