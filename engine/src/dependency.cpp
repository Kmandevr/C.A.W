// Deterministic dependency resolver. It runs while loading/preparing projects, never on the audio thread.
#include "dependency.h"

namespace caw {

DependencyReport resolveDependencies(const std::vector<DependencyRef>& dependencies,
                                     const std::vector<AssetRecord>& available) {
    DependencyReport report;
    report.entries.reserve(dependencies.size());
    for (const DependencyRef& dep : dependencies) {
        DependencyResolution result;
        if (dep.stableId.empty() || dep.version.empty() || dep.interfaceVersion == 0) {
            result.status = DependencyStatus::InvalidReference;
            report.complete = false;
            report.entries.push_back(result);
            continue;
        }

        uint32_t match = UINT32_MAX;
        uint32_t candidates = 0;
        bool idFound = false, versionFound = false, hashFound = false, interfaceFound = false;
        for (uint32_t i = 0; i < available.size(); ++i) {
            const AssetRecord& asset = available[i];
            if (asset.stableId != dep.stableId || asset.scope != dep.scope) continue;
            idFound = true;
            if (asset.version != dep.version) continue;
            versionFound = true;
            if (!dep.contentHash.empty() && asset.contentHash != dep.contentHash) continue;
            hashFound = true;
            if (asset.interfaceVersion != dep.interfaceVersion) continue;
            interfaceFound = true;
            match = i;
            ++candidates;
        }

        if (candidates > 1) result.status = DependencyStatus::Ambiguous;
        else if (candidates == 1) {
            result.status = DependencyStatus::Resolved;
            result.assetIndex = match;
        } else if (!idFound) result.status = dep.optional ? DependencyStatus::OptionalMissing : DependencyStatus::Missing;
        else if (!versionFound) result.status = DependencyStatus::VersionMismatch;
        else if (!hashFound) result.status = DependencyStatus::HashMismatch;
        else if (!interfaceFound) result.status = DependencyStatus::InterfaceMismatch;
        else result.status = DependencyStatus::Missing;

        if (result.status != DependencyStatus::Resolved && result.status != DependencyStatus::OptionalMissing)
            report.complete = false;
        report.entries.push_back(result);
    }
    return report;
}

}  // namespace caw
