// The pre-load scan's ELF64 little-endian reader: segments, sections, the dynamic table, imports and exports.
// The dynamic table and program headers are what the loader uses, so imports come from them; section
// headers (which a stripped file may lack) add names and the exact code ranges.
#include <algorithm>
#include <string>
#include <vector>

#include "parsed.h"

namespace caw::scan {
namespace {

constexpr uint32_t PT_LOAD = 1, PT_DYNAMIC = 2;
constexpr uint32_t PF_X = 1, PF_W = 2;
constexpr uint32_t SHT_NOBITS = 8, SHT_DYNSYM = 11;
constexpr uint64_t SHF_WRITE = 1, SHF_ALLOC = 2, SHF_EXECINSTR = 4;
constexpr int64_t DT_NULL = 0, DT_NEEDED = 1, DT_PLTRELSZ = 2, DT_HASH = 4, DT_STRTAB = 5, DT_SYMTAB = 6,
                  DT_RELA = 7, DT_RELASZ = 8, DT_RELAENT = 9, DT_STRSZ = 10, DT_SYMENT = 11, DT_INIT = 12,
                  DT_REL = 17, DT_RELSZ = 18, DT_RELENT = 19, DT_PLTREL = 20, DT_TEXTREL = 22, DT_JMPREL = 23,
                  DT_INIT_ARRAYSZ = 27, DT_FLAGS = 30, DT_PREINIT_ARRAYSZ = 33, DT_GNU_HASH = 0x6ffffef5;
constexpr uint64_t DF_TEXTREL = 4;

struct Segment {
    uint32_t type = 0, flags = 0;
    uint64_t offset = 0, vaddr = 0, filesz = 0;
};

class Elf {
public:
    Elf(const ByteReader& r, const Limits& l, WorkBudget& b, Parsed& o) : r_(r), L_(l), budget_(b), out_(o) {}

    void run() {
        if (!header() || !segments() || !sections() || !dynamic()) return;
        if (out_.execCode.empty()) out_.execCode = out_.execSegments;
    }

private:
    bool bad(const char* why) {
        if (out_.malformed.empty()) out_.malformed = why;
        return false;
    }
    bool spend(uint64_t n) { return budget_.spend(n) || bad("the scan's work budget ran out"); }

    // A virtual address range inside one loaded segment's file bytes: its file offset, and the bytes left there.
    bool map(uint64_t vaddr, uint64_t length, uint64_t& offset, uint64_t* left = nullptr) const {
        for (const Segment& s : segs_) {
            if (s.type != PT_LOAD || vaddr < s.vaddr) continue;
            const uint64_t into = vaddr - s.vaddr;
            if (into > s.filesz || length > s.filesz - into) continue;
            offset = s.offset + into;
            if (left) *left = s.filesz - into;
            return true;
        }
        return false;
    }

    bool header() {
        if (!r_.has(0, 64)) return bad("the ELF header is cut short");
        r_.u16(18, machine_);
        r_.u64(32, phoff_);
        r_.u64(40, shoff_);
        r_.u16(54, phentsize_);
        r_.u16(56, phnum_);
        r_.u16(58, shentsize_);
        r_.u16(60, shnum_);
        r_.u16(62, shstrndx_);
        out_.arch = machine_ == 183 ? "aarch64" : machine_ == 62 ? "x86_64" : "other";
        return true;
    }

    bool segments() {
        if (phnum_ == 0) return true;
        if (phentsize_ < 56) return bad("the program header entries are too small");
        if (phnum_ > L_.maxSegments) return bad("more program headers than the scan reads");
        if (!r_.has(phoff_, uint64_t(phnum_) * phentsize_)) return bad("the program headers lie outside the file");
        for (uint32_t i = 0; i < phnum_; ++i) {
            const uint64_t at = phoff_ + uint64_t(i) * phentsize_;
            Segment s;
            r_.u32(at, s.type);
            r_.u32(at + 4, s.flags);
            r_.u64(at + 8, s.offset);
            r_.u64(at + 16, s.vaddr);
            r_.u64(at + 32, s.filesz);
            if ((s.type == PT_LOAD || s.type == PT_DYNAMIC) && !r_.has(s.offset, s.filesz))
                return bad("a segment lies outside the file");
            const std::string name = "segment " + std::to_string(i);
            if (s.type == PT_LOAD && (s.flags & PF_X)) out_.execSegments.push_back({s.offset, s.filesz, name});
            if (s.type == PT_LOAD && (s.flags & PF_X) && (s.flags & PF_W)) out_.writableExecutable.push_back(name);
            if (s.type == PT_DYNAMIC) {
                if (hasDynamic_) return bad("more than one dynamic segment");
                hasDynamic_ = true;
                dynOffset_ = s.offset;
                dynSize_ = s.filesz;
            }
            segs_.push_back(s);
        }
        return true;
    }

    bool sections() {
        if (shoff_ == 0) return true;
        if (shentsize_ < 64) return shnum_ == 0 ? true : bad("the section header entries are too small");
        uint64_t count = shnum_;
        uint32_t strIndex = shstrndx_;
        if (count == 0 || strIndex == 0xffff) {  // extended numbering: section 0 holds the real values
            if (!r_.has(shoff_, 64)) return bad("the section headers lie outside the file");
            uint64_t size0 = 0;
            uint32_t link0 = 0;
            r_.u64(shoff_ + 32, size0);
            r_.u32(shoff_ + 40, link0);
            if (count == 0) count = size0;
            if (strIndex == 0xffff) strIndex = link0;
        }
        if (count == 0) return true;
        if (count > L_.maxSections) return bad("more sections than the scan reads");
        if (!r_.has(shoff_, count * shentsize_)) return bad("the section headers lie outside the file");
        if (!spend(count)) return false;
        uint64_t strOffset = 0, strSize = 0;
        const bool hasNames = strIndex != 0 && strIndex < count;
        if (hasNames) {
            const uint64_t at = shoff_ + uint64_t(strIndex) * shentsize_;
            r_.u64(at + 24, strOffset);
            r_.u64(at + 32, strSize);
            if (!r_.has(strOffset, strSize)) return bad("the section name table lies outside the file");
        }
        for (uint64_t i = 0; i < count; ++i) {
            const uint64_t at = shoff_ + i * shentsize_;
            uint32_t nameOffset = 0, type = 0;
            uint64_t flags = 0, offset = 0, size = 0;
            r_.u32(at, nameOffset);
            r_.u32(at + 4, type);
            r_.u64(at + 8, flags);
            r_.u64(at + 24, offset);
            r_.u64(at + 32, size);
            if (type != SHT_NOBITS && size > 0 && !r_.has(offset, size)) return bad("a section lies outside the file");
            std::string name;
            if (hasNames && nameOffset > 0 && !r_.cstr(strOffset + nameOffset, strOffset + strSize, 64, name))
                return bad("a section name lies outside the name table");
            if (type == SHT_DYNSYM) sectionSymbols_ = std::max<uint64_t>(sectionSymbols_, size / 24);
            const bool data = type != SHT_NOBITS && size > 0;
            if (data && (flags & SHF_EXECINSTR)) out_.execCode.push_back({offset, size, name});
            else if (data && (flags & SHF_ALLOC)) out_.dataSections.push_back({offset, size, name});
            if ((flags & SHF_EXECINSTR) && (flags & SHF_WRITE)) out_.writableExecutable.push_back(name);
            if (name == kElfDeclarationSection) out_.declarationSections.push_back({offset, data ? size : 0, name});
            if (!name.empty() && out_.sectionNames.size() < 512) out_.sectionNames.push_back(std::move(name));
        }
        return true;
    }

    // DT_GNU_HASH: the symbol count is the end of the longest chain from the highest bucket.
    bool gnuHashCount(uint64_t address, uint64_t& count) {
        uint64_t at = 0;
        if (!map(address, 16, at)) return bad("the GNU hash table lies outside the file");
        uint32_t buckets = 0, symOffset = 0, bloomWords = 0;
        r_.u32(at, buckets);
        r_.u32(at + 4, symOffset);
        r_.u32(at + 8, bloomWords);
        if (buckets > L_.maxSymbols || bloomWords > L_.maxSymbols || symOffset > L_.maxSymbols)
            return bad("the GNU hash table is larger than the scan reads");
        const uint64_t bucketAddress = address + 16 + uint64_t(bloomWords) * 8;
        uint64_t bucketAt = 0;
        if (!map(bucketAddress, uint64_t(buckets) * 4, bucketAt)) return bad("the GNU hash buckets lie outside the file");
        if (!spend(buckets)) return false;
        uint32_t highest = 0;
        for (uint32_t i = 0; i < buckets; ++i) {
            uint32_t v = 0;
            r_.u32(bucketAt + uint64_t(i) * 4, v);
            highest = std::max(highest, v);
        }
        if (highest < symOffset) {
            count = symOffset;
            return true;
        }
        const uint64_t chainAddress = bucketAddress + uint64_t(buckets) * 4;
        for (uint64_t index = highest;; ++index) {
            if (index - symOffset >= L_.maxSymbols) return bad("a GNU hash chain is longer than the scan reads");
            if (!spend(1)) return false;
            uint64_t chainAt = 0;
            uint32_t v = 0;
            if (!map(chainAddress + (index - symOffset) * 4, 4, chainAt)) return bad("a GNU hash chain runs outside the file");
            r_.u32(chainAt, v);
            if (v & 1) {
                count = index + 1;
                return true;
            }
        }
    }

    // The highest symbol index a relocation table uses.
    bool relocations(uint64_t address, uint64_t size, uint64_t entry, uint64_t& maxSymbol) {
        if (size == 0) return true;
        if (entry != 16 && entry != 24) return bad("a relocation table has an unknown entry size");
        const uint64_t count = size / entry;
        if (count > L_.maxRelocations) return bad("more relocations than the scan reads");
        uint64_t at = 0;
        if (!map(address, size, at)) return bad("a relocation table lies outside the file");
        if (!spend(count)) return false;
        for (uint64_t i = 0; i < count; ++i) {
            uint64_t info = 0;
            r_.u64(at + i * entry + 8, info);
            maxSymbol = std::max<uint64_t>(maxSymbol, info >> 32);
        }
        return true;
    }

    bool dynamic() {
        if (!hasDynamic_) return true;
        const uint64_t entries = dynSize_ / 16;
        if (entries > L_.maxDynamicEntries) return bad("the dynamic table is larger than the scan reads");
        if (!spend(entries)) return false;
        uint64_t strtab = 0, strsz = 0, symtab = 0, syment = 24, hash = 0, gnuHash = 0, rela = 0, relasz = 0,
                 relaent = 24, rel = 0, relsz = 0, relent = 16, jmprel = 0, pltrelsz = 0, pltrel = 0;
        bool haveStrtab = false, haveSymtab = false, haveHash = false, haveGnuHash = false;
        std::vector<uint64_t> needed;
        for (uint64_t i = 0; i < entries; ++i) {
            uint64_t tagBits = 0, value = 0;
            r_.u64(dynOffset_ + i * 16, tagBits);
            r_.u64(dynOffset_ + i * 16 + 8, value);
            const int64_t tag = static_cast<int64_t>(tagBits);
            if (tag == DT_NULL) break;
            switch (tag) {
                case DT_NEEDED: if (needed.size() < L_.maxImportLibraries) needed.push_back(value); break;
                case DT_STRTAB: strtab = value; haveStrtab = true; break;
                case DT_STRSZ: strsz = value; break;
                case DT_SYMTAB: symtab = value; haveSymtab = true; break;
                case DT_SYMENT: syment = value; break;
                case DT_HASH: hash = value; haveHash = true; break;
                case DT_GNU_HASH: gnuHash = value; haveGnuHash = true; break;
                case DT_RELA: rela = value; break;
                case DT_RELASZ: relasz = value; break;
                case DT_RELAENT: relaent = value; break;
                case DT_REL: rel = value; break;
                case DT_RELSZ: relsz = value; break;
                case DT_RELENT: relent = value; break;
                case DT_JMPREL: jmprel = value; break;
                case DT_PLTRELSZ: pltrelsz = value; break;
                case DT_PLTREL: pltrel = value; break;
                case DT_INIT: out_.constructors += 1; break;
                case DT_INIT_ARRAYSZ: out_.constructors += value / 8; break;
                case DT_PREINIT_ARRAYSZ: out_.constructors += value / 8; break;
                case DT_TEXTREL: out_.textRelocations = true; break;
                case DT_FLAGS: if (value & DF_TEXTREL) out_.textRelocations = true; break;
                default: break;
            }
        }
        if (!haveStrtab && !needed.empty()) return bad("the dynamic table names libraries but has no string table");
        if (haveSymtab && !haveStrtab) return bad("the dynamic table has symbols but no string table");
        uint64_t strAt = 0;
        if (haveStrtab && !map(strtab, strsz, strAt)) return bad("the dynamic string table lies outside the file");
        auto name = [&](uint64_t offset, std::string& out) {
            return offset < strsz && r_.cstr(strAt + offset, strAt + strsz, L_.maxNameBytes, out);
        };
        for (uint64_t offset : needed) {
            std::string library;
            if (!name(offset, library)) return bad("a needed library's name lies outside the string table");
            out_.libraries.push_back(std::move(library));
        }
        if (!haveSymtab) return true;
        if (syment != 24) return bad("the dynamic symbols have an unknown entry size");

        uint64_t count = sectionSymbols_;
        if (haveHash) {
            uint64_t at = 0;
            uint32_t nchain = 0;
            if (!map(hash, 8, at)) return bad("the hash table lies outside the file");
            r_.u32(at + 4, nchain);
            count = std::max<uint64_t>(count, nchain);
        }
        if (haveGnuHash) {
            uint64_t gnuCount = 0;
            if (!gnuHashCount(gnuHash, gnuCount)) return false;
            count = std::max(count, gnuCount);
        }
        uint64_t maxSymbol = 0;
        if (!relocations(rela, relasz, relaent, maxSymbol) || !relocations(rel, relsz, relent, maxSymbol) ||
            !relocations(jmprel, pltrelsz, pltrel == static_cast<uint64_t>(DT_REL) ? 16 : 24, maxSymbol))
            return false;
        if (maxSymbol > 0) count = std::max(count, maxSymbol + 1);
        if (count > L_.maxSymbols) return bad("more dynamic symbols than the scan reads");
        uint64_t symAt = 0;
        if (count > 0 && !map(symtab, count * 24, symAt)) return bad("the dynamic symbols lie outside the file");
        if (!spend(count)) return false;
        for (uint64_t i = 1; i < count; ++i) {
            const uint64_t at = symAt + i * 24;
            uint32_t nameOffset = 0;
            uint8_t info = 0;
            uint16_t shndx = 0;
            r_.u32(at, nameOffset);
            r_.u8(at + 4, info);
            r_.u16(at + 6, shndx);
            const uint8_t bind = info >> 4;
            if (nameOffset == 0 || bind == 0) continue;  // unnamed or local
            std::string symbol;
            if (!name(nameOffset, symbol)) return bad("a symbol's name lies outside the string table");
            if (shndx == 0) {
                out_.imports.push_back({std::string(), std::move(symbol)});
            } else if (symbol == "caw_get_component_v3") {
                out_.componentEntry = true;
            } else if (symbol == "JNI_OnLoad" || symbol.rfind("Java_", 0) == 0 || symbol == "JNI_OnUnload") {
                if (out_.exports.size() < 64) out_.exports.push_back(std::move(symbol));
            }
        }
        return true;
    }

    const ByteReader& r_;
    const Limits& L_;
    WorkBudget& budget_;
    Parsed& out_;
    uint16_t machine_ = 0, phentsize_ = 0, phnum_ = 0, shentsize_ = 0, shnum_ = 0, shstrndx_ = 0;
    uint64_t phoff_ = 0, shoff_ = 0;
    std::vector<Segment> segs_;
    bool hasDynamic_ = false;
    uint64_t dynOffset_ = 0, dynSize_ = 0;
    uint64_t sectionSymbols_ = 0;
};

}  // namespace

void parseElf(const ByteReader& r, const Limits& limits, WorkBudget& budget, Parsed& out) {
    out.format = Format::Elf64;
    Elf(r, limits, budget, out).run();
}

}  // namespace caw::scan
