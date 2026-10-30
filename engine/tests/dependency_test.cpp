// Tests for pinned, scope-aware project dependency resolution.
#include "test.h"

#include "dependency.h"

using namespace caw;

TEST(dependencies_resolve_exact_version_scope_hash_and_interface) {
    const std::vector<DependencyRef> refs{{"caw.fx.delay", "2.1.0", "sha256:abc", AssetScope::AddOn, 1, false}};
    const std::vector<AssetRecord> assets{
        {"caw.fx.delay", "2.1.0", "sha256:abc", AssetScope::AddOn, 1},
        {"caw.fx.delay", "2.1.0", "sha256:abc", AssetScope::Factory, 1},
    };
    const auto report = resolveDependencies(refs, assets);
    CHECK(report.complete);
    CHECK_EQ(report.entries[0].status, DependencyStatus::Resolved);
    CHECK_EQ(report.entries[0].assetIndex, 0u);
}

TEST(dependencies_never_fall_back_across_scopes_or_versions) {
    const std::vector<DependencyRef> refs{
        {"caw.instrument.pad", "1.0.0", "", AssetScope::ProjectLocal, 1, false},
        {"caw.instrument.pad", "1.0.0", "", AssetScope::UserGlobal, 1, false},
    };
    const std::vector<AssetRecord> assets{
        {"caw.instrument.pad", "2.0.0", "h", AssetScope::ProjectLocal, 1},
        {"caw.instrument.pad", "1.0.0", "h", AssetScope::Factory, 1},
    };
    const auto report = resolveDependencies(refs, assets);
    CHECK(!report.complete);
    CHECK_EQ(report.entries[0].status, DependencyStatus::VersionMismatch);
    CHECK_EQ(report.entries[1].status, DependencyStatus::Missing);
}

TEST(dependencies_report_hash_and_interface_mismatches) {
    const std::vector<DependencyRef> refs{
        {"asset.one", "1.0", "wanted", AssetScope::Factory, 1, false},
        {"asset.two", "1.0", "", AssetScope::Factory, 2, false},
    };
    const std::vector<AssetRecord> assets{
        {"asset.one", "1.0", "different", AssetScope::Factory, 1},
        {"asset.two", "1.0", "hash", AssetScope::Factory, 1},
    };
    const auto report = resolveDependencies(refs, assets);
    CHECK_EQ(report.entries[0].status, DependencyStatus::HashMismatch);
    CHECK_EQ(report.entries[1].status, DependencyStatus::InterfaceMismatch);
}

TEST(dependencies_allow_optional_missing_and_reject_ambiguous_records) {
    const std::vector<DependencyRef> refs{
        {"optional.asset", "1", "", AssetScope::UserGlobal, 1, true},
        {"duplicate.asset", "1", "", AssetScope::AddOn, 1, false},
    };
    const std::vector<AssetRecord> assets{
        {"duplicate.asset", "1", "a", AssetScope::AddOn, 1},
        {"duplicate.asset", "1", "b", AssetScope::AddOn, 1},
    };
    const auto report = resolveDependencies(refs, assets);
    CHECK(!report.complete);
    CHECK_EQ(report.entries[0].status, DependencyStatus::OptionalMissing);
    CHECK_EQ(report.entries[1].status, DependencyStatus::Ambiguous);
}

TEST(dependencies_reject_empty_ids_and_unversioned_references) {
    const std::vector<DependencyRef> refs{
        {"", "1", "", AssetScope::Factory, 1, false},
        {"valid.id", "", "", AssetScope::Factory, 1, false},
    };
    const auto report = resolveDependencies(refs, {});
    CHECK_EQ(report.entries[0].status, DependencyStatus::InvalidReference);
    CHECK_EQ(report.entries[1].status, DependencyStatus::InvalidReference);
}
