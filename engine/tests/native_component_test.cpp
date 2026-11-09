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
    CHECK_EQ(project.masterComponents[0].id, std::string("org.caw.fx.first"));
    CHECK_EQ(project.masterComponents[1].id, std::string("org.caw.fx.second"));
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
        CHECK(instance->activate(48000.0, 4));  // hosts prepare an instance before its first block
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

TEST(module_registry_refuses_a_library_without_the_v2_entry_point) {
    // A library built against the old C++ entry points (or not a component) exports no
    // caw_get_component_v3: refused before anything of it runs.
    ModuleRegistry registry;
    const ModuleLoadResult old =
        registry.loadSharedLibrary(CAW_TEST_NO_ENTRY_COMPONENT_PATH, kComponentId, NativeModuleTrust::Trusted);
    CHECK(!old.success);
    CHECK(old.error == ModuleLoadError::MissingEntryPoint);
    CHECK(registry.find(kComponentId) == nullptr);
}

TEST(module_registry_copies_the_c_descriptor_and_runs_the_component_through_it) {
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    if (!path) return;
    ModuleRegistry registry;
    const ModuleLoadResult loaded = registry.loadSharedLibrary(path, kComponentId, NativeModuleTrust::Trusted);
    CHECK(loaded.success);
    if (!loaded.success) return;
    const ModuleDescriptor* d = registry.find(kComponentId);
    CHECK(d != nullptr);
    if (!d) return;
    CHECK(d->id == kComponentId);
    CHECK_EQ(d->portCount, 2u);
    CHECK(d->ports[0].layout == ChannelLayout::Stereo && d->ports[0].input);
    CHECK(d->ports[1].layout == ChannelLayout::Stereo && !d->ports[1].input);
    CHECK(validateModuleDescriptor(*d) == ModuleValidation::Ok);

    std::unique_ptr<ModuleProcessor> processor = registry.create(kComponentId);
    CHECK(processor != nullptr);
    if (!processor) return;
    const float inL[4] = {0.1f, 0.2f, -0.3f, 0.4f}, inR[4] = {0.5f, -0.5f, 0.25f, 0.0f};
    float outL[4] = {}, outR[4] = {};
    const float* in[2] = {inL, inR};
    float* out[2] = {outL, outR};
    AudioProcessBlock block;
    block.input = {in, 2, 4};
    block.output = {out, 2, 4};
    block.frames = 4;
    CHECK(!processor->process(block));  // not activated yet: refused, never run
    CHECK(processor->activate(48000.0, 64));
    CHECK(processor->process(block));
    CHECK_EQ(outL[2], -0.6f);  // the fixture doubles its input
    CHECK_EQ(outR[0], 1.0f);
    const float* mono[1] = {inL};
    AudioProcessBlock wrongChannels = block;
    wrongChannels.input = {mono, 1, 4};  // one channel into a stereo port
    CHECK(!processor->process(wrongChannels));
    CHECK(processor->activate(48000.0, 2));  // prepared for 2-frame blocks now
    CHECK(!processor->process(block));        // a 4-frame block is refused, never run
    CHECK(!registry.unload(kComponentId));  // an instance still holds it
    processor->deactivate();
    processor.reset();
    CHECK(registry.unload(kComponentId));
}

TEST(c_api_lists_loaded_component_descriptors_as_json) {
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    CawEngine* engine = caw_engine_create(48000);
    CHECK(engine != nullptr);
    if (!engine || !path) return;
    char* empty = caw_engine_components(engine);
    CHECK(empty && std::string(empty) == "{\"ok\":true,\"components\":[]}");
    caw_free(empty);
    char* loaded = caw_engine_load_component(engine, path, kComponentId, CAW_NATIVE_TRUST_TRUSTED);
    caw_free(loaded);
    char* listed = caw_engine_components(engine);
    CHECK(listed != nullptr);
    const std::string json = listed ? listed : "";
    caw_free(listed);
    CHECK(json.find("\"id\":\"org.caw.tests.native-loader\"") != std::string::npos);
    CHECK(json.find("{\"id\":\"audio_in\",\"type\":\"audio\",\"input\":true,\"layout\":\"stereo\",\"channels\":2") != std::string::npos);
    CHECK(json.find("\"version\":1,\"role\":\"unspecified\"") != std::string::npos);
    caw_engine_destroy(engine);
}

TEST(module_registry_loads_a_component_from_a_bundle_by_id) {
    // The fixture library is a bundle (owner, 2026-11-09): the doubler at index 0, a halver at 1.
    const char* path = caw::test::nativeComponentPath();
    CHECK(path != nullptr);
    if (!path) return;
    ModuleRegistry registry;
    const ModuleLoadResult half = registry.loadSharedLibrary(path, "org.caw.tests.native-loader.half", NativeModuleTrust::Trusted);
    CHECK(half.success);
    CHECK(registry.find("org.caw.tests.native-loader") == nullptr);  // only what was asked for loads
    const ModuleLoadResult both = registry.loadSharedLibrary(path, kComponentId, NativeModuleTrust::Trusted);
    CHECK(both.success);
    CHECK_EQ(registry.size(), 2u);
    const ModuleLoadResult missing = registry.loadSharedLibrary(path, "org.caw.tests.absent", NativeModuleTrust::Trusted);
    CHECK(!missing.success);
    CHECK(missing.error == ModuleLoadError::ComponentIdMismatch);
    std::unique_ptr<ModuleProcessor> processor = registry.create("org.caw.tests.native-loader.half");
    CHECK(processor != nullptr);
    if (!processor) return;
    CHECK(processor->activate(48000.0, 4));
    const float inL[4] = {1.0f, -1.0f, 0.5f, 0.0f}, inR[4] = {0.25f, 0.0f, -0.5f, 2.0f};
    float outL[4] = {}, outR[4] = {};
    const float* in[2] = {inL, inR};
    float* out[2] = {outL, outR};
    AudioProcessBlock block;
    block.input = {in, 2, 4};
    block.output = {out, 2, 4};
    block.frames = 4;
    CHECK(processor->process(block));
    CHECK_EQ(outL[0], 0.5f);
    CHECK_EQ(outR[3], 1.0f);
}
