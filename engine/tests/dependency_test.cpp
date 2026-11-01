// Tests for pinned, scope-aware project dependency resolution.
#include "test.h"

#include "dependency.h"
#include "project.h"

using namespace caw;

TEST(dependencies_resolve_exact_version_scope_hash_and_interface) {
    const std::vector<DependencyRef> refs{{"caw.fx.delay", "2.1.0", "sha256:abc", AssetScope::AddOn, 1, false}};
    const std::vector<AssetRecord> assets{
        {"caw.fx.delay", "2.1.0", "sha256:abc", AssetScope::AddOn, 1},
        {"caw.fx.delay", "2.1.0", "sha256:abc", AssetScope::Factory, 1},
    };
    const auto report = resolveDependencies(refs, assets);
    CHECK(report.complete);
    CHECK(report.entries[0].status == DependencyStatus::Resolved);
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
    CHECK(report.entries[0].status == DependencyStatus::VersionMismatch);
    CHECK(report.entries[1].status == DependencyStatus::Missing);
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
    CHECK(report.entries[0].status == DependencyStatus::HashMismatch);
    CHECK(report.entries[1].status == DependencyStatus::InterfaceMismatch);
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
    CHECK(report.entries[0].status == DependencyStatus::OptionalMissing);
    CHECK(report.entries[1].status == DependencyStatus::Ambiguous);
}

TEST(dependencies_reject_empty_ids_and_unversioned_references) {
    const std::vector<DependencyRef> refs{
        {"", "1", "", AssetScope::Factory, 1, false},
        {"valid.id", "", "", AssetScope::Factory, 1, false},
    };
    const auto report = resolveDependencies(refs, {});
    CHECK(report.entries[0].status == DependencyStatus::InvalidReference);
    CHECK(report.entries[1].status == DependencyStatus::InvalidReference);
}

TEST(project_json_loads_pinned_asset_dependencies) {
    const char* json = R"({"caw_project":1,"dependencies":[
        {"id":"caw.fx.delay","version":"2.1.0","hash":"sha256:abc","scope":"addon","interface_version":1},
        {"id":"factory.wavetable.saw","version":"1.0","scope":"factory","interface_version":1,"optional":true}
    ]})";
    ProjectSpec project;
    std::string error;
    CHECK(parseProject(json, project, error));
    CHECK_EQ(project.dependencies.size(), 2u);
    CHECK_EQ(project.dependencies[0].stableId, std::string("caw.fx.delay"));
    CHECK(project.dependencies[0].scope == AssetScope::AddOn);
    CHECK_EQ(project.dependencies[0].contentHash, std::string("sha256:abc"));
    CHECK(project.dependencies[1].optional);
    CHECK(project.dependencies[1].scope == AssetScope::Factory);
}

TEST(project_json_rejects_invalid_dependency_scope_and_unpinned_versions) {
    ProjectSpec project;
    std::string error;
    CHECK(!parseProject(R"({"caw_project":1,"dependencies":[{"id":"asset","version":"1","scope":"somewhere"}]})", project, error));
    CHECK(error.find("scope must be") != std::string::npos);
    error.clear();
    CHECK(!parseProject(R"({"caw_project":1,"dependencies":[{"id":"asset","scope":"project"}]})", project, error));
    CHECK(error.find("stable id, exact version") != std::string::npos);
}
