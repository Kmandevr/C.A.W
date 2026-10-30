// Portable, exact dependency resolution for project-local, global, factory and add-on assets.
#pragma once

#include <cstdint>
#include <string>\n#include <string_view>
#include <vector>

namespace caw {

enum class AssetScope : uint8_t { ProjectLocal, UserGlobal, Factory, AddOn };

struct DependencyRef {
    std::string stableId;
    std::string version;       // exact pinned version in v1
    std::string contentHash;   // optional exact content hash
    AssetScope scope = AssetScope::ProjectLocal;
    uint32_t interfaceVersion = 1;
    bool optional = false;
};

struct AssetRecord {
    std::string_view stableId;
    std::string_view version;
    std::string_view contentHash;
    AssetScope scope = AssetScope::ProjectLocal;
    uint32_t interfaceVersion = 1;
};

enum class DependencyStatus : uint8_t {
    Resolved,
    OptionalMissing,
    Missing,
    VersionMismatch,
    HashMismatch,
    InterfaceMismatch,
    Ambiguous,
    InvalidReference
};

struct DependencyResolution {
    DependencyStatus status = DependencyStatus::Missing;
    uint32_t assetIndex = UINT32_MAX;
};

struct DependencyReport {
    std::vector<DependencyResolution> entries;
    bool complete = true; // optional missing entries do not make a report incomplete
};

// Exact, scope-aware resolution. No silent cross-scope fallback or version substitution.
DependencyReport resolveDependencies(const std::vector<DependencyRef>& dependencies,
                                     const std::vector<AssetRecord>& available);

}  // namespace caw
