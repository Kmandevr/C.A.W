// Exercises explicit trust, stable-ID validation, dynamic loading and library lifetime.
#include <cstdlib>

#include "module_registry.h"
#include "test.h"

using namespace caw;

namespace {
constexpr const char* kComponentId = "org.caw.tests.native-loader";
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
    CHECK(mismatch.error == ModuleLoadError::ComponentIdMismatch);
    CHECK_EQ(registry.size(), 0u);

    const auto loaded = registry.loadSharedLibrary(path ? path : "", kComponentId, NativeModuleTrust::Trusted);
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
