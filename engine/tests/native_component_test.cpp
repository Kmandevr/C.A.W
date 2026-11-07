// Exercises explicit trust, stable-ID validation, dynamic loading and library lifetime.
#include <cstdio>
#include <cstdlib>
#include <string>

#include "caw.h"
#include "project.h"
#include "native_component_test_path.h"

#include "module_registry.h"
#include "test.h"

using namespace caw;

namespace {
constexpr const char* kComponentId = "org.caw.tests.native-loader";
}

TEST(project_json_preserves_native_master_component_order) {
    ProjectSpec project;
    std::string error;
    CHECK(parseProject(
        R"({"caw_project":1,"master_components":["org.caw.fx.first","org.caw.fx.second"]})",
        project,
        error));
    CHECK_EQ(project.masterComponents.size(), 2u);
    CHECK_EQ(project.masterComponents[0], std::string("org.caw.fx.first"));
    CHECK_EQ(project.masterComponents[1], std::string("org.caw.fx.second"));
}

TEST(c_api_native_component_load_requires_an_explicit_trust_level) {
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    CHECK(path && path[0] != 0);
    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine || !path) return;

    char* blocked = caw_engine_load_component(engine, path, "org.caw.tests.native-loader", CAW_NATIVE_TRUST_BLOCKED);
    CHECK(blocked != nullptr);
    if (blocked) {
        const std::string json(blocked);
        caw_free(blocked);
        CHECK(json.find(R"("ok":false)") != std::string::npos);
        CHECK(json.find("blocked") != std::string::npos);
    }

    char* isolated = caw_engine_load_component(engine, path, "org.caw.tests.native-loader", CAW_NATIVE_TRUST_ISOLATED);
    CHECK(isolated != nullptr);
    if (isolated) {
        const std::string json(isolated);
        caw_free(isolated);
        CHECK(json.find(R"("ok":false)") != std::string::npos);
        CHECK(json.find("Isolated") != std::string::npos);
    }

    char* trusted = caw_engine_load_component(engine, path, "org.caw.tests.native-loader", CAW_NATIVE_TRUST_TRUSTED);
    CHECK(trusted != nullptr);
    if (trusted) {
        const std::string json(trusted);
        caw_free(trusted);
        if (json.find(R"("ok":true)") == std::string::npos)
            std::fprintf(stderr, "trusted C API component load returned: %s\n", json.c_str());
        CHECK(json.find(R"("ok":true)") != std::string::npos);
        CHECK(json.find("org.caw.tests.native-loader") != std::string::npos);
    }
    CHECK_EQ(caw_engine_unload_component(engine, "org.caw.tests.native-loader"), 1);
    caw_engine_destroy(engine);
}

TEST(module_registry_loads_native_components_only_after_explicit_trust) {
    const char* path = std::getenv("CAW_TEST_COMPONENT_PATH");
    CHECK(path != nullptr);
    CHECK(path && path[0] != '\0');

    ModuleRegistry registry;
    const auto blocked = registry.loadSharedLibrary(path ? path : "", kComponentId, NativeModuleTrust::Blocked);
    CHECK(!blocked.success);
    CHECK(blocked.error == ModuleLoadError::Blocked);
    CHECK_EQ(registry.size(), 0u);

    const auto isolated = registry.loadSharedLibrary(path ? path : "", kComponentId, NativeModuleTrust::Isolated);
    CHECK(!isolated.success);
    CHECK(isolated.error == ModuleLoadError::IsolationUnavailable);
    CHECK_EQ(registry.size(), 0u);

    const auto mismatch = registry.loadSharedLibrary(path ? path : "", "org.caw.wrong-id", NativeModuleTrust::Trusted);
    CHECK(!mismatch.success);
    if (mismatch.error != ModuleLoadError::ComponentIdMismatch)
        std::fprintf(stderr, "wrong-ID component load returned error %u: %s\n",
                     static_cast<unsigned>(mismatch.error), mismatch.message.c_str());
    CHECK(mismatch.error == ModuleLoadError::ComponentIdMismatch);
    CHECK_EQ(registry.size(), 0u);

    const auto loaded = registry.loadSharedLibrary(path ? path : "", kComponentId, NativeModuleTrust::Trusted);
    if (!loaded.success)
        std::fprintf(stderr, "trusted component load returned error %u: %s\n",
                     static_cast<unsigned>(loaded.error), loaded.message.c_str());
    CHECK(loaded.success);
    CHECK(loaded.error == ModuleLoadError::None);
    CHECK_EQ(loaded.componentId, std::string(kComponentId));
    CHECK(registry.find(kComponentId) != nullptr);
    CHECK_EQ(registry.size(), 1u);

    const auto duplicate = registry.loadSharedLibrary(path ? path : "", kComponentId, NativeModuleTrust::Trusted);
    CHECK(!duplicate.success);
    CHECK(duplicate.error == ModuleLoadError::DuplicateId);

    auto instance = registry.create(kComponentId);
    CHECK(instance != nullptr);
    if (instance) {
        const float inputLeft[] = {0.25f, -0.5f, 0.0f, 0.75f};
        const float inputRight[] = {-0.25f, 0.5f, 1.0f, -0.75f};
        float outputLeft[4] = {};
        float outputRight[4] = {};
        const StereoProcessBlock block{inputLeft, inputRight, outputLeft, outputRight, 4, 48000.0};
        instance->process(block);
        CHECK_NEAR(outputLeft[0], 0.5, 1e-7);
        CHECK_NEAR(outputLeft[1], -1.0, 1e-7);
        CHECK_NEAR(outputRight[2], 2.0, 1e-7);
        CHECK_NEAR(outputRight[3], -1.5, 1e-7);
    }

    CHECK(!registry.unload(kComponentId));  // a live processor keeps its library loaded
    instance.reset();
    CHECK(registry.unload(kComponentId));
    CHECK(registry.find(kComponentId) == nullptr);
    CHECK_EQ(registry.size(), 0u);
}
