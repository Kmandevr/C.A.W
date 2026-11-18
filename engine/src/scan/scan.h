// The pre-load scan: a static look at a native library's bytes (ELF64, PE32+) before it is ever loaded.
// Every byte is hostile: sizes, counts, offsets and work are bounded, and a parse failure is a finding.
#pragma once

#include <cstddef>
#include <cstdint>
#include <span>
#include <string>
#include <string_view>
#include <vector>

namespace caw::scan {

// The capability list a finding belongs to and a component declares (docs/native-module-sdk.md).
enum class Capability : uint8_t {
    Internet,
    ReadFiles,
    WriteFiles,
    StartPrograms,
    LoadCode,
    MakeCode,
    AndroidSystem,
    BackgroundThreads,
    Encryption,
    InputSpying,
    Packed,
};
constexpr size_t kCapabilityCount = 11;
const char* capabilityId(Capability c) noexcept;     // "internet", "read_files", ...
const char* capabilityTitle(Capability c) noexcept;  // "Internet", "Reading files", ...
bool capabilityFromId(std::string_view id, Capability& out) noexcept;
constexpr uint32_t capabilityBit(Capability c) noexcept { return 1u << static_cast<uint32_t>(c); }

// Hint: the bytes suggest it (a byte pattern, a string, an ambiguous import). Certain: the binary has it.
enum class Strength : uint8_t { Hint, Certain };
// The finding's own weight, as a CLAP/VST3 plug-in sees it; the policy (policy.h) weighs it for a component.
enum class Severity : uint8_t { Notice, Warning };

// What kind of evidence a finding is.
enum class FindingKind : uint8_t {
    Import,         // an imported function (evidence: its name; on PE "dll!name")
    Library,        // a needed library (DT_NEEDED, a PE import DLL)
    Export,         // an exported symbol (JNI_OnLoad, Java_*)
    Syscall,        // a system-call instruction in executable code
    Section,        // a writable and executable section or segment, a packer's section name, text relocations
    Entropy,        // high-entropy code or data
    String,         // a URL, address, shell or wallet path in the bytes
    LoadTime,       // code that runs when the library is loaded (constructors, TLS callbacks): informational
    Malformed,      // the file could not be read as what it claims to be, or passed a limit
    Unsupported,    // not an ELF64 little-endian or PE32+ file
    Declarations,   // the embedded capability declarations are invalid, duplicated or tampered with
};
const char* findingKindId(FindingKind k) noexcept;

struct Finding {
    Capability capability = Capability::Packed;
    FindingKind kind = FindingKind::Import;
    std::string evidence;  // a symbol, a library, an offset or a string (at most 160 bytes)
    Strength strength = Strength::Certain;
    Severity severity = Severity::Warning;
};

// A capability the binary declares (its embedded caw.capabilities section).
struct Declaration {
    Capability capability = Capability::Packed;
    std::string reason;
    std::vector<std::string> sites;  // internet only
};

enum class Format : uint8_t { Unknown, Elf64, Pe32Plus };

struct Report {
    Format format = Format::Unknown;
    std::string arch;           // "aarch64", "x86_64", "other"
    bool malformed = false;     // a Malformed finding is in the list
    uint64_t imports = 0;       // imported functions seen
    uint64_t constructors = 0;  // DT_INIT_ARRAY entries (+ DT_INIT, DT_PREINIT_ARRAY)
    uint64_t tlsCallbacks = 0;  // PE TLS callbacks
    bool componentEntry = false;  // exports caw_get_component_v3 (ELF only; PE exports are not read)
    // The embedded declarations: absent (no section: a component built before 1.0.7), valid, or invalid
    // (a Declarations finding says why).
    enum class DeclarationState : uint8_t { Absent, Valid, Invalid } declarationState = DeclarationState::Absent;
    std::vector<Declaration> declarations;
    std::string declarationsCanonical;  // the section's JSON, when valid
    std::vector<Finding> findings;
};

// The limits every scan runs under.
struct Limits {
    uint64_t maxFileBytes = 256ull << 20;
    uint32_t maxSections = 4096;
    uint32_t maxSegments = 512;
    uint32_t maxDynamicEntries = 8192;
    uint32_t maxSymbols = 1u << 20;
    uint64_t maxRelocations = 1u << 22;
    uint32_t maxImportLibraries = 1024;
    uint32_t maxImportsPerLibrary = 65536;
    uint32_t maxNameBytes = 1024;        // a longer symbol name is read cut to this
    uint32_t maxTlsCallbacks = 1024;
    uint64_t maxStringScanBytes = 64ull << 20;
    uint64_t workBudget = 64ull << 20;   // table entries walked, all tables together
    uint32_t maxFindings = 256;
    uint32_t maxFindingsPerKind = 24;    // per capability and kind; the first of each is always kept
    uint32_t maxDeclarationBytes = 16384;
    uint32_t maxDeclarations = 16;
};

// Scans one file's bytes. Never throws for bad input (std::bad_alloc only); never reads outside `bytes`.
Report scanBinary(std::span<const uint8_t> bytes, const Limits& limits = {});

// The embedded declaration section's name: "caw_caps" on ELF, ".cawcap" on PE.
inline constexpr std::string_view kElfDeclarationSection = "caw_caps";
inline constexpr std::string_view kPeDeclarationSection = ".cawcap";

}  // namespace caw::scan
