// What the ELF and PE readers of the pre-load scan hand to its analysis (internal to engine/src/scan/).
#pragma once

#include <cstdint>
#include <span>
#include <string>
#include <vector>

#include "byte_reader.h"
#include "scan.h"

namespace caw::scan {

struct FileRange {
    uint64_t offset = 0;
    uint64_t size = 0;
    std::string name;  // the section's name, or "segment N"
};

struct Import {
    std::string library;  // the PE DLL (lowercase); empty on ELF
    std::string name;     // empty for a PE import by ordinal
};

struct Parsed {
    Format format = Format::Unknown;
    std::string arch = "other";
    std::vector<Import> imports;
    std::vector<std::string> libraries;  // DT_NEEDED names, PE import DLLs (lowercase)
    std::vector<std::string> exports;    // ELF only: defined global dynamic symbols worth a look
    bool componentEntry = false;
    std::vector<FileRange> execCode;     // executable code: sections where named, else segments
    std::vector<FileRange> execSegments; // what the loader maps executable (ELF PT_LOAD with PF_X; PE as execCode)
    std::vector<FileRange> dataSections; // named non-executable sections with file bytes
    std::vector<std::string> sectionNames;
    std::vector<std::string> writableExecutable;  // names of W+X sections or segments
    bool textRelocations = false;
    uint64_t constructors = 0;
    uint64_t tlsCallbacks = 0;
    std::vector<FileRange> declarationSections;  // caw_caps / .cawcap
    std::string malformed;                       // why the file is malformed (empty: it parsed)
};

// Each reader fills `out`, setting `malformed` (and stopping) on the first inconsistency or limit.
void parseElf(const ByteReader& r, const Limits& limits, WorkBudget& budget, Parsed& out);
void parsePe(const ByteReader& r, const Limits& limits, WorkBudget& budget, Parsed& out);

}  // namespace caw::scan
