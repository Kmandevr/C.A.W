// The pre-load scan's PE32+ reader: sections, imports (normal and delay-loaded) and TLS callbacks.
#include <algorithm>
#include <cctype>
#include <string>

#include "parsed.h"

namespace caw::scan {
namespace {

constexpr uint32_t kExecute = 0x20000000, kWrite = 0x80000000;

struct Section {
    std::string name;
    uint32_t vsize = 0, va = 0, rawSize = 0, rawPtr = 0, flags = 0;
};

std::string lower(std::string s) {
    for (char& c : s) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return s;
}

class Pe {
public:
    Pe(const ByteReader& r, const Limits& l, WorkBudget& b, Parsed& o) : r_(r), L_(l), budget_(b), out_(o) {}

    void run(uint32_t peOffset) {
        if (!headers(peOffset)) return;
        if (!imports() || !delayImports() || !tls()) return;
    }

private:
    bool bad(const char* why) {
        if (out_.malformed.empty()) out_.malformed = why;
        return false;
    }
    bool spend(uint64_t n) { return budget_.spend(n) || bad("the scan's work budget ran out"); }

    // An RVA range inside one section's file bytes (or the headers): its file offset and where that region ends.
    bool map(uint64_t rva, uint64_t length, uint64_t& offset, uint64_t& end) const {
        for (const Section& s : sections_) {
            if (rva < s.va) continue;
            const uint64_t into = rva - s.va;
            if (into >= s.rawSize || length > s.rawSize - into) continue;
            offset = uint64_t(s.rawPtr) + into;
            end = uint64_t(s.rawPtr) + s.rawSize;
            return true;
        }
        if (rva < sizeOfHeaders_ && length <= sizeOfHeaders_ - rva && r_.has(rva, length)) {
            offset = rva;
            end = sizeOfHeaders_;
            return true;
        }
        return false;
    }
    bool mapString(uint64_t rva, std::string& out) const {
        uint64_t at = 0, end = 0;
        return map(rva, 1, at, end) && r_.cstr(at, end, L_.maxNameBytes, out);
    }
    uint64_t rvaOf(uint64_t value, bool virtualAddress) const {
        return virtualAddress && value >= imageBase_ ? value - imageBase_ : value;
    }

    bool headers(uint32_t pe) {
        const uint64_t coff = uint64_t(pe) + 4;
        if (!r_.has(coff, 20)) return bad("the PE header is cut short");
        uint16_t machine = 0, count = 0, optionalSize = 0;
        r_.u16(coff, machine);
        r_.u16(coff + 2, count);
        r_.u16(coff + 16, optionalSize);
        out_.arch = machine == 0x8664 ? "x86_64" : machine == 0xAA64 ? "aarch64" : "other";
        opt_ = coff + 20;
        if (optionalSize < 112 || !r_.has(opt_, optionalSize)) return bad("the PE optional header is cut short");
        r_.u64(opt_ + 24, imageBase_);
        r_.u32(opt_ + 60, sizeOfHeaders_);
        uint32_t directories = 0;
        r_.u32(opt_ + 108, directories);
        directories_ = std::min<uint32_t>(directories, 16);
        if (112 + uint64_t(directories_) * 8 > optionalSize) return bad("the PE data directories run past the optional header");
        if (count > 96) return bad("more PE sections than Windows loads");
        const uint64_t table = opt_ + optionalSize;
        if (!r_.has(table, uint64_t(count) * 40)) return bad("the PE section table lies outside the file");
        for (uint32_t i = 0; i < count; ++i) {
            const uint64_t at = table + uint64_t(i) * 40;
            Section s;
            for (int c = 0; c < 8; ++c) {
                uint8_t ch = 0;
                r_.u8(at + c, ch);
                if (ch == 0) break;
                s.name.push_back(static_cast<char>(ch));
            }
            r_.u32(at + 8, s.vsize);
            r_.u32(at + 12, s.va);
            r_.u32(at + 16, s.rawSize);
            r_.u32(at + 20, s.rawPtr);
            r_.u32(at + 36, s.flags);
            if (s.rawSize > 0 && !r_.has(s.rawPtr, s.rawSize)) return bad("a PE section lies outside the file");
            // The loader maps at most the virtual size of a section's raw bytes; the rest is file padding.
            const uint64_t mapped = s.vsize > 0 ? std::min(s.vsize, s.rawSize) : s.rawSize;
            if (mapped > 0 && (s.flags & kExecute)) {
                out_.execCode.push_back({s.rawPtr, mapped, s.name});
                out_.execSegments.push_back({s.rawPtr, mapped, s.name});
            } else if (mapped > 0) {
                out_.dataSections.push_back({s.rawPtr, mapped, s.name});
            }
            if ((s.flags & kExecute) && (s.flags & kWrite)) out_.writableExecutable.push_back(s.name);
            if (s.name == kPeDeclarationSection) out_.declarationSections.push_back({s.rawPtr, mapped, s.name});
            out_.sectionNames.push_back(s.name);
            sections_.push_back(std::move(s));
        }
        return true;
    }

    bool directory(uint32_t index, uint32_t& rva, uint32_t& size) const {
        if (index >= directories_) return false;
        r_.u32(opt_ + 112 + uint64_t(index) * 8, rva);
        r_.u32(opt_ + 112 + uint64_t(index) * 8 + 4, size);
        return rva != 0;
    }

    // One import name table: 8-byte thunks until a zero one.
    bool thunks(const std::string& library, uint64_t tableRva, bool virtualAddresses) {
        for (uint32_t j = 0;; ++j) {
            if (j >= L_.maxImportsPerLibrary) return bad("a PE library has more imports than the scan reads");
            if (!spend(1)) return false;
            uint64_t at = 0, end = 0, thunk = 0;
            if (!map(tableRva + uint64_t(j) * 8, 8, at, end)) return bad("a PE import table runs outside the file");
            r_.u64(at, thunk);
            if (thunk == 0) return true;
            if (thunk >> 63) {
                out_.imports.push_back({library, std::string()});  // by ordinal
                continue;
            }
            std::string name;
            if (!mapString(rvaOf(thunk & 0x7fffffffffffffffull, virtualAddresses) + 2, name))
                return bad("a PE import's name lies outside the file");
            out_.imports.push_back({library, std::move(name)});
        }
    }

    bool imports() {
        uint32_t rva = 0, size = 0;
        if (!directory(1, rva, size)) return true;
        for (uint32_t i = 0;; ++i) {
            if (i >= L_.maxImportLibraries) return bad("more PE import libraries than the scan reads");
            if (!spend(1)) return false;
            uint64_t at = 0, end = 0;
            if (!map(uint64_t(rva) + uint64_t(i) * 20, 20, at, end)) return bad("the PE import directory lies outside the file");
            uint32_t lookup = 0, nameRva = 0, first = 0;
            r_.u32(at, lookup);
            r_.u32(at + 12, nameRva);
            r_.u32(at + 16, first);
            if (lookup == 0 && nameRva == 0 && first == 0) return true;
            std::string library;
            if (!mapString(nameRva, library)) return bad("a PE import library's name lies outside the file");
            library = lower(library);
            out_.libraries.push_back(library);
            if (!thunks(library, lookup ? lookup : first, false)) return false;
        }
    }

    bool delayImports() {
        uint32_t rva = 0, size = 0;
        if (!directory(13, rva, size)) return true;
        for (uint32_t i = 0;; ++i) {
            if (i >= L_.maxImportLibraries) return bad("more delay-loaded PE libraries than the scan reads");
            if (!spend(1)) return false;
            uint64_t at = 0, end = 0;
            if (!map(uint64_t(rva) + uint64_t(i) * 32, 32, at, end)) return bad("the PE delay-import directory lies outside the file");
            uint32_t attributes = 0, nameRva = 0, nameTable = 0;
            r_.u32(at, attributes);
            r_.u32(at + 4, nameRva);
            r_.u32(at + 16, nameTable);
            if (nameRva == 0) return true;
            const bool virtualAddresses = (attributes & 1) == 0;  // the old form holds addresses, not RVAs
            std::string library;
            if (!mapString(rvaOf(nameRva, virtualAddresses), library))
                return bad("a delay-loaded PE library's name lies outside the file");
            library = lower(library);
            out_.libraries.push_back(library);
            if (nameTable && !thunks(library, rvaOf(nameTable, virtualAddresses), virtualAddresses)) return false;
        }
    }

    bool tls() {
        uint32_t rva = 0, size = 0;
        if (!directory(9, rva, size)) return true;
        uint64_t at = 0, end = 0, callbacks = 0;
        if (!map(rva, 40, at, end)) return bad("the PE TLS directory lies outside the file");
        r_.u64(at + 24, callbacks);
        if (callbacks == 0) return true;
        if (callbacks < imageBase_) return bad("the PE TLS callbacks lie before the image");
        const uint64_t table = callbacks - imageBase_;
        for (uint32_t i = 0;; ++i) {
            if (i >= L_.maxTlsCallbacks) return bad("more PE TLS callbacks than the scan reads");
            if (!spend(1)) return false;
            uint64_t entry = 0, entryEnd = 0, value = 0;
            if (!map(table + uint64_t(i) * 8, 8, entry, entryEnd)) return bad("the PE TLS callbacks run outside the file");
            r_.u64(entry, value);
            if (value == 0) return true;
            ++out_.tlsCallbacks;
        }
    }

    const ByteReader& r_;
    const Limits& L_;
    WorkBudget& budget_;
    Parsed& out_;
    std::vector<Section> sections_;
    uint64_t opt_ = 0, imageBase_ = 0;
    uint32_t sizeOfHeaders_ = 0, directories_ = 0;
};

}  // namespace

void parsePe(const ByteReader& r, const Limits& limits, WorkBudget& budget, Parsed& out) {
    out.format = Format::Pe32Plus;
    uint32_t pe = 0;
    r.u32(0x3c, pe);
    Pe(r, limits, budget, out).run(pe);
}

}  // namespace caw::scan
